/// Flash Trade **gasless session keys** (gum `gpl_session` `create_session_v2`).
/// One owner approval per ride mints a SessionTokenV2 that authorizes an ephemeral
/// key the app holds in-memory to sign Flash trades on the ER — no further wallet
/// popups. Self-custodial: scoped to the Flash program, time-boxed (`valid_until`),
/// and revocable. This replaces owner-signed trades (the aura "backend bot keypair"
/// model is custodial; we never hold the user's funds).
///
/// Encoding sourced from flash-trade/examples-v2 `SESSION-KEYS.md`:
///   program  KeyspM2ss…           target  FTv2Rx… (Flash v2)
///   disc     sha256("global:create_session_v2")[..8]
///   args     top_up(bool) | valid_until(u64 LE) | top_up_lamports(u64 LE)
///   pda      ["session_token_v2", target_program, session_signer, authority]
///   accounts [sessionToken(w), sessionSigner, feePayer(owner,signer,w), authority(owner,signer),
///            targetProgram, systemProgram]
/// NOTE: the exact v2 account-signer flags are best-effort from the docs — a failed
/// `create_session_v2` is non-fatal (no funds move; iterate on the layout).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flash_client/flash_client.dart';
import 'package:solana/dto.dart' as soldto;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:throtl_live/throtl_live.dart';

const String sessionKeysProgramId = 'KeyspM2ssCJbqUhQ4k7sveSiY4WjnYsrXkC8oDbwde5';
const String flashV2ProgramId = 'FTv2RxXarPfNta45HTTMVaGvjzsGg27FXJ3hEKWBhrzV';
const String _systemProgramId = '11111111111111111111111111111111';

/// Anchor discriminator for `create_session_v2` (sha256("global:create_session_v2")[..8]).
const List<int> _createSessionV2Disc = [223, 233, 108, 7, 65, 194, 235, 38];

/// The SessionTokenV2 PDA: `["session_token_v2", target_program, session_signer, authority]`.
Future<Ed25519HDPublicKey> sessionTokenV2Pda({
  required Ed25519HDPublicKey sessionSigner,
  required Ed25519HDPublicKey authority,
}) => Ed25519HDPublicKey.findProgramAddress(
  seeds: [
    'session_token_v2'.codeUnits,
    Ed25519HDPublicKey.fromBase58(flashV2ProgramId).bytes,
    sessionSigner.bytes,
    authority.bytes,
  ],
  programId: Ed25519HDPublicKey.fromBase58(sessionKeysProgramId),
);

/// Build the owner-signed `create_session_v2` instruction (one wallet popup per ride).
Future<Instruction> createSessionV2Ix({
  required Ed25519HDPublicKey owner, // fee payer + authority
  required Ed25519HDPublicKey sessionSigner, // the ephemeral key
  required int validUntilUnix,
  int topUpLamports = 10000000, // 0.01 SOL, reclaimed on revoke
}) async {
  final token = await sessionTokenV2Pda(sessionSigner: sessionSigner, authority: owner);
  // The gum `create_session_v2` args are three Anchor `Option`s, NOT bare values
  // (verified against the on-chain program source: `top_up: Option<bool>,
  // valid_until: Option<i64>, lamports: Option<u64>`). Borsh encodes `Some(x)` as a
  // `1` presence byte then `x`. The old "best-effort" layout wrote bare values, so
  // the program read the low byte of `valid_until` as the bool (rarely 0/1) and
  // Borsh threw `InstructionDidNotDeserialize` (0x66) — aborting the whole arming
  // tx on every wallet. Three `Some`s, byte-aligned (proven via mainnet sim):
  final data = <int>[
    ..._createSessionV2Disc,
    1, 1, // Option<bool>  top_up      = Some(true)
    1, ..._u64le(validUntilUnix), // Option<i64>  valid_until = Some(validUntilUnix)
    1, ..._u64le(topUpLamports), // Option<u64>  lamports    = Some(topUpLamports)
  ];
  return Instruction(
    programId: Ed25519HDPublicKey.fromBase58(sessionKeysProgramId),
    accounts: [
      AccountMeta.writeable(pubKey: token, isSigner: false),
      // session_signer is `Signer<'info>` + `#[account(mut)]` in CreateSessionTokenV2
      // — a writable signer (it receives the top-up lamports). The owner signs via
      // MWA; this ephemeral key co-signs the SAME tx in-memory ([coSignSessionKey]).
      AccountMeta.writeable(pubKey: sessionSigner, isSigner: true),
      AccountMeta.writeable(pubKey: owner, isSigner: true), // fee payer
      AccountMeta.readonly(pubKey: owner, isSigner: true), // authority
      AccountMeta.readonly(
        pubKey: Ed25519HDPublicKey.fromBase58(flashV2ProgramId),
        isSigner: false,
      ),
      AccountMeta.readonly(
        pubKey: Ed25519HDPublicKey.fromBase58(_systemProgramId),
        isSigner: false,
      ),
    ],
    data: ByteArray(data),
  );
}

/// Gasless TRADE sign+submit: the unsigned v0 tx (built with `signer`+`sessionToken`)
/// requires the ephemeral session key, which we hold in memory — sign it (no popup,
/// blockhash untouched) and submit to Flash's ER. Refuses if the session key isn't a
/// required signer (the silent-fallback trap).
SignSubmitConfirm flashSessionSignSubmit(Ed25519HDKeyPair sessionKey, RpcClient flashEr) {
  return (BuiltTx tx) async {
    final decoded = SignedTx.decode(tx.transactionBase64);
    final me = sessionKey.publicKey.toBase58();
    final idx = decoded.compiledMessage.accountKeys.indexWhere((k) => '$k' == me);
    if (idx < 0 || idx >= decoded.signatures.length) {
      throw StateError('session key is not a required signer of this Flash trade');
    }
    final sig = await sessionKey.sign(decoded.compiledMessage.toByteArray().toList());
    final sigs = [...decoded.signatures]..[idx] = sig;
    final signed = SignedTx(signatures: sigs, compiledMessage: decoded.compiledMessage).encode();
    return flashEr.sendTransaction(signed, skipPreflight: true);
  };
}

/// Inject the in-memory Flash **session_signer** signature into an owner-signed
/// arming tx. The arming tx requires two signers — the wallet owner (filled by MWA)
/// and the ephemeral Flash key — but MWA only fills the owner slot, leaving the
/// session_signer slot zeroed (a gap the `sigVerify:false` simulation can't catch,
/// so this never surfaced until real submission). Decode the MWA-signed tx, sign
/// the SAME compiled message with the ephemeral key, drop it into its slot, and
/// re-encode to wire bytes ready to submit. Throws if the ephemeral key isn't a
/// required signer — so a silently-unsigned tx can never reach the chain.
Future<Uint8List> coSignSessionKey(
  Uint8List ownerSignedTx,
  Ed25519HDKeyPair sessionKey,
) async {
  final decoded = SignedTx.decode(base64Encode(ownerSignedTx));
  final me = sessionKey.publicKey.toBase58();
  final idx = decoded.compiledMessage.accountKeys.indexWhere((k) => '$k' == me);
  if (idx < 0 || idx >= decoded.signatures.length) {
    throw StateError('Flash session key is not a required signer of the arming tx');
  }
  final sig = await sessionKey.sign(decoded.compiledMessage.toByteArray().toList());
  final sigs = [...decoded.signatures]..[idx] = sig;
  final signed = SignedTx(signatures: sigs, compiledMessage: decoded.compiledMessage);
  return Uint8List.fromList(base64Decode(signed.encode()));
}

/// Encode an unsigned [Instruction] (e.g. `create_session_v2`) to base64 for MWA to
/// owner-sign — so it submits through the same wallet path as init/delegate.
Future<Uint8List> messageBytesForMwa(
  List<Instruction> ixs,
  Ed25519HDPublicKey feePayer,
  String recentBlockhash,
) async {
  final msg = Message(instructions: ixs);
  final compiled = msg.compile(recentBlockhash: recentBlockhash, feePayer: feePayer);
  // One empty signature slot for the fee payer; MWA fills it.
  final tx = SignedTx(
    signatures: [Signature(List.filled(64, 0), publicKey: feePayer)],
    compiledMessage: compiled,
  );
  return Uint8List.fromList(base64Decode(tx.encode()));
}

List<int> _u64le(int v) => (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();

/// The Flash v2 **deposit-ledger** PDA for [owner]: `["user_deposit_ledger", owner]`
/// under the Flash program. This account holds the collateral `deposit-direct`
/// moves in — the spendable "fuel" balance — which lives HERE, not in the basket
/// (positions/debits/pendingCredits) and not in a wallet ATA. Seeds verified
/// against a live mainnet ledger (owner 3hqiC… → ledger TVPZ…, research/flash.md §3).
Future<Ed25519HDPublicKey> depositLedgerPda(Ed25519HDPublicKey owner) =>
    Ed25519HDPublicKey.findProgramAddress(
      seeds: ['user_deposit_ledger'.codeUnits, owner.bytes],
      programId: Ed25519HDPublicKey.fromBase58(flashV2ProgramId),
    );

/// Deposited balance (raw token units) of [mint] in [owner]'s Flash deposit
/// ledger, or 0 if the ledger account doesn't exist / holds none of [mint]. Reads
/// the account via [rpc] (base chain) and parses the zero-copy layout:
/// `8 disc | 1 bump | 7 pad | 32 owner | u32 count | count×{32 mint, u64 amount}`.
Future<int> flashLedgerBalanceRaw(RpcClient rpc, Ed25519HDPublicKey owner, String mint) async {
  final pda = await depositLedgerPda(owner);
  final res = await rpc.getAccountInfo(pda.toBase58(), encoding: soldto.Encoding.base64);
  final data = res.value?.data;
  if (data is! soldto.BinaryAccountData) return 0; // no ledger yet
  final bytes = data.data;
  if (bytes.length < 52) return 0;
  final count = _readU32le(bytes, 48);
  final mintBytes = Ed25519HDPublicKey.fromBase58(mint).bytes;
  for (var i = 0; i < count && i < 20; i++) {
    final off = 52 + 40 * i;
    if (off + 40 > bytes.length) break;
    var hit = true;
    for (var j = 0; j < 32; j++) {
      if (bytes[off + j] != mintBytes[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return _readU64le(bytes, off + 32);
  }
  return 0;
}

int _readU32le(List<int> b, int off) =>
    b[off] + b[off + 1] * 256 + b[off + 2] * 65536 + b[off + 3] * 16777216;

/// Little-endian u64 by multiplication (web-safe — avoids dart2js 32-bit shifts
/// and unsupported `ByteData.getUint64`; Flash balances stay well under 2^53).
int _readU64le(List<int> b, int off) {
  var v = 0;
  var mul = 1;
  for (var i = 0; i < 8; i++) {
    v += b[off + i] * mul;
    mul *= 256;
  }
  return v;
}
