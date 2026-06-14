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
  final data = <int>[
    ..._createSessionV2Disc,
    1, // top_up = true
    ..._u64le(validUntilUnix),
    ..._u64le(topUpLamports),
  ];
  return Instruction(
    programId: Ed25519HDPublicKey.fromBase58(sessionKeysProgramId),
    accounts: [
      AccountMeta.writeable(pubKey: token, isSigner: false),
      AccountMeta.readonly(pubKey: sessionSigner, isSigner: false),
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
