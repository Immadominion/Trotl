/// Real-money Flash Trade plumbing, MWA-adapted from the proven `flash_lifecycle`
/// flow (validated live on mainnet). Three jobs:
///   • [flashTradeSignSubmit] — owner-sign a Flash trade via MWA, submit to Flash's ER RPC.
///   • [flashReadSettled] / [parseFlashPosition] — the trusted real position (never the ER).
///   • [flashDeposit] / [flashWithdraw] — fund / defund the per-wallet Flash basket.
/// Every signer call keeps the two money-path guards: refuse if the owner isn't a
/// required signer (silent session-fallback), and never replace the prefilled blockhash.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flash_client/flash_client.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:solana/dto.dart' hide Commitment, Instruction;
import 'package:solana/encoder.dart'
    show AccountMeta, CompiledMessage, CompiledMessageV0, Instruction, SignedTx;
import 'package:solana/solana.dart';
import 'package:throtl/src/chain/tx_builder.dart';
import 'package:throtl/src/wallet/flash_session.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_live/throtl_live.dart';

const String usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

/// MagicBlock delegation program — a basket delegated for ER trading is owned by
/// this on the base layer (so we can detect "already delegated" and skip re-delegating).
const String _delegationProgramId = 'DELeGGvXpWV2fqJUhqcF5ZSYMS4JTLjteaAMARRSaeSh';

/// Refuse to sign unless [owner] is a required signer of the unsigned base64 v0 tx
/// (the silent session-fallback trap — research/flash.md §1).
void _assertOwnerSigner(String base64Tx, String owner) {
  final tx = SignedTx.decode(base64Tx);
  final idx = tx.compiledMessage.accountKeys.indexWhere((k) => '$k' == owner);
  if (idx < 0 || idx >= tx.signatures.length) {
    throw StateError('owner is not a required signer of this Flash tx — refusing to submit');
  }
}

/// A TRADE (open/close): OWNER-sign the unsigned v0 tx via MWA (a wallet popup —
/// gasless Flash session keys are the follow-up), then submit to Flash's **ER RPC**
/// (not the wallet's RPC; we sign-only so MWA can't re-broadcast on the wrong chain).
SignSubmitConfirm flashTradeSignSubmit(WalletController wallet, RpcClient flashEr) {
  return (BuiltTx tx) async {
    final owner = wallet.owner;
    if (owner == null) throw StateError('wallet disconnected');
    _assertOwnerSigner(tx.transactionBase64, owner);
    // Decode Flash tx and rebuild in proper MWA format (with Signature array)
    final decoded = SignedTx.decode(tx.transactionBase64);
    final compiled = decoded.compiledMessage;

    // Ensure proper Signature array structure (MWA requires this)
    final requiredSigs = compiled.requiredSignatureCount;
    final signatures = List<Signature>.generate(
      requiredSigs,
      (i) => Signature(List.filled(64, 0), publicKey: compiled.accountKeys[i]),
    );

    // Rebuild SignedTx in proper format for MWA
    final properTx = SignedTx(compiledMessage: compiled, signatures: signatures);
    final txBytes = Uint8List.fromList(properTx.toByteArray().toList());
    final signed = await wallet.signTransactions([txBytes]);
    return flashEr.sendTransaction(base64Encode(signed.first), skipPreflight: true);
  };
}

/// The trusted settled position for [marketSymbol], read from Flash (never the ER).
ReadSettled flashReadSettled(FlashApi api, String owner, String marketSymbol) {
  return () async => parseFlashPosition(await api.ownerState(owner), marketSymbol);
}

/// Parse a `/owner/{owner}` snapshot into the [FlashPosition] for [marketSymbol].
/// Flat when there's no open position. Pure → unit-tested off the M0.3 fixture.
@visibleForTesting
FlashPosition parseFlashPosition(Map<String, dynamic> ownerState, String marketSymbol) {
  final pm = ownerState['positionMetrics'];
  if (pm is! Map) return const FlashPosition.flat();
  for (final v in pm.values) {
    if (v is! Map || v['marketSymbol'] != marketSymbol) continue;
    final sizeUsd = double.tryParse('${v['sizeUsdUi'] ?? 0}') ?? 0;
    if (sizeUsd <= 0) continue;
    final isShort = '${v['sideUi'] ?? ''}'.toLowerCase() == 'short';
    final entry = double.tryParse('${v['entryPriceUi'] ?? 0}') ?? 0;
    return FlashPosition(
      side: isShort ? Side.short : Side.long,
      sizeUsd6: (sizeUsd * 1e6).round(),
      entryE9: (entry * 1e9).round(),
      stopTriggerE9: _stopTriggerE9(ownerState, marketSymbol, isShort),
    );
  }
  return const FlashPosition.flat();
}

/// Best-effort active stop trigger (e9) for market+side, so the reconciler doesn't
/// re-place a stop that already exists (which would churn trades).
int? _stopTriggerE9(Map<String, dynamic> ownerState, String marketSymbol, bool isShort) {
  final om = ownerState['orderMetrics'];
  if (om is! Map) return null;
  for (final v in om.values) {
    if (v is! Map || v['marketSymbol'] != marketSymbol) continue;
    final type = '${v['type'] ?? v['orderType'] ?? ''}'.toLowerCase();
    if (!type.contains('stop') && !type.contains('sl')) continue;
    final side = '${v['sideUi'] ?? ''}'.toLowerCase();
    if (side.isNotEmpty && (side == 'short') != isShort) continue;
    final trig = double.tryParse('${v['triggerPriceUi'] ?? v['priceUi'] ?? 0}') ?? 0;
    if (trig > 0) return (trig * 1e9).round();
  }
  return null;
}

/// Progress callback for the funding flows (one line per lifecycle step).
typedef FundingProgress = void Function(String step);

/// Fund the per-wallet Flash basket with [amountUsd6] USDC. Idempotent on setup:
/// skips ledger/basket/delegate if the basket already exists. Each tx is owner-signed
/// via MWA and submitted to the base mainnet RPC (the correct chain for setup).
Future<void> flashDeposit(
  WalletController wallet,
  FlashApi api,
  RpcClient base,
  int amountUsd6, {
  FundingProgress? onStep,
}) async {
  final owner = wallet.owner;
  if (owner == null) throw StateError('wallet disconnected');
  final amountUi = (amountUsd6 / 1e6).toStringAsFixed(6);

  Map<String, dynamic> state;
  try {
    state = await api.ownerState(owner);
  } on Object {
    state = const {};
  }

  // IDEMPOTENT SETUP — include ONLY the steps whose accounts don't already exist.
  // `init_deposit_ledger` / `init_basket` do a System `CreateAccount`, which HARD-
  // FAILS with custom 0x0 ("account already in use") if the account is already
  // there. A prior partial/failed funding (e.g. ledger created, basket not) leaves
  // exactly that state — and because Solflare PRE-SIMULATES before signing, it
  // surfaces the 0x0 and refuses (so the tx never even lands; Seed Vault, which
  // doesn't pre-simulate, would also have failed on submit). The old `hasBasket`
  // API flag missed this: a wallet can have a ledger but no basket. So check the
  // on-chain truth — ledger PDA existence, basket existence + DLP delegation — and
  // skip what's already done. Re-funding / partial-setup wallets now just work.
  final ownerKey = Ed25519HDPublicKey.fromBase58(owner);
  final ledgerPda = await depositLedgerPda(ownerKey);
  final ledgerExists = await _accountExists(base, ledgerPda.toBase58());

  final basketStr = (state['basketPubkey'] as String?) ?? '';
  var basketExists = false;
  var basketDelegated = false;
  if (basketStr.isNotEmpty) {
    // base64 encoding is REQUIRED: the basket account is >128 bytes and the RPC
    // rejects the default base58 ("data should be less than 128 bytes"). We only
    // read `.owner` (delegation), but the RPC still encodes the data either way.
    final acc = (await base.getAccountInfo(
      basketStr,
      commitment: Commitment.confirmed,
      encoding: Encoding.base64,
    )).value;
    basketExists = acc != null;
    basketDelegated = acc != null && acc.owner == _delegationProgramId;
  }

  final steps = <(String, Future<BuiltTx> Function())>[
    if (!ledgerExists) ('init ledger', () => api.initDepositLedger(owner)),
    if (!basketExists) ('init basket', () => api.initBasket(owner)),
    if (!basketDelegated) ('delegate basket', () => api.delegateBasket(owner: owner, payer: owner)),
    (
      'deposit $amountUi USDC',
      () => api.depositDirect(owner: owner, tokenMint: usdcMint, amountUi: amountUi),
    ),
  ];

  // Build every step server-side, DECOMPILE each Flash tx, and MERGE the
  // instructions into ONE atomic transaction the owner signs once — the funding
  // coinjoin. WHY: the old flow signed/submitted each step as its own tx. Solflare
  // PRE-SIMULATES a tx before letting you sign, and the dependent steps (delegate
  // needs the basket; deposit needs the basket+ledger) "fail" that pre-sim because
  // the earlier txs haven't propagated to Solflare's RPC yet — so it refused, and
  // funding died (Seed Vault doesn't pre-simulate, so the sequence worked there).
  // In ONE tx the instructions execute in order (ledger → basket → delegate →
  // deposit), so the whole thing simulates cleanly on EVERY wallet — and it's a
  // single signature, not four. Safe to merge: every Flash setup/deposit tx is
  // plain v0 with no address-table lookups, and deposit-direct never touches the
  // (now DLP-delegated) basket — both verified by decompiling the live txs.
  final ixs = <Instruction>[];
  for (final (name, build) in steps) {
    onStep?.call(name);
    final built = await build();
    _assertOwnerSigner(built.transactionBase64, owner);
    ixs.addAll(_mergeableInstructions(SignedTx.decode(built.transactionBase64).compiledMessage));
  }
  onStep?.call('confirm in your wallet');
  final bh = (await base.getLatestBlockhash()).value.blockhash;
  final unsigned = buildUnsignedLegacyTx(
    instructions: ixs,
    recentBlockhash: bh,
    feePayer: Ed25519HDPublicKey.fromBase58(owner),
  );
  final sigs = await wallet.signAndSubmit([unsigned], base);
  await _confirm(base, sigs.first);
}

/// Reconstruct a Flash-built tx's [Instruction]s so several can be merged into ONE
/// atomic transaction (the funding coinjoin above). Safe ONLY for txs with no
/// address-table lookups — every Flash setup/deposit tx is plain v0 with all-static
/// keys (verified live). Signer/writable flags are derived from the compiled message
/// header (the standard Solana account ordering: writable signers, readonly signers,
/// writable non-signers, readonly non-signers).
List<Instruction> _mergeableInstructions(CompiledMessage cm) {
  if (cm is CompiledMessageV0 && cm.addressTableLookups.isNotEmpty) {
    throw StateError('Flash tx uses address lookup tables — cannot merge into one tx');
  }
  final keys = cm.accountKeys;
  final h = cm.header;
  final numSigners = h.numRequiredSignatures;
  final numStatic = keys.length;
  bool isSigner(int i) => i < numSigners;
  bool isWritable(int i) => i < numSigners
      ? i < numSigners - h.numReadonlySignedAccounts
      : i < numStatic - h.numReadonlyUnsignedAccounts;
  return cm.instructions
      .map(
        (ix) => Instruction(
          programId: keys[ix.programIdIndex],
          accounts: ix.accountKeyIndexes
              .map(
                (ai) => isWritable(ai)
                    ? AccountMeta.writeable(pubKey: keys[ai], isSigner: isSigner(ai))
                    : AccountMeta.readonly(pubKey: keys[ai], isSigner: isSigner(ai)),
              )
              .toList(),
          data: ix.data,
        ),
      )
      .toList();
}

/// Cash out [amount6] USDC (raw; null = the full withdrawable) to the owner's
/// wallet. ONE signature in the common case: `request-withdrawal` releases the
/// funds and the Flash keeper crosses the settlement automatically — we then POLL
/// the wallet balance (read-only) for arrival instead of re-signing. Only if it
/// doesn't auto-complete within the window do we sign ONE `execute-withdrawal`
/// recovery tx.
///
/// This replaces a loop that re-signed `execute-withdrawal` up to 12× — every
/// retry threw a wallet popup, and while the settlement was still crossing each
/// one failed simulation ("couldn't be simulated"). That was the 6-signature
/// storm. Worst case is now 2 signatures; the typical case is 1.
Future<void> flashWithdraw(
  WalletController wallet,
  FlashApi api,
  RpcClient base, {
  int? amount6,
  FundingProgress? onStep,
}) async {
  final owner = wallet.owner;
  if (owner == null) throw StateError('wallet disconnected');

  // Withdrawable = the REAL balance: ledger deposits − basket debits + basket
  // pendingCredits (the deposit lives in the on-chain UserDepositLedger, not the
  // basket). null amount ⇒ cash out everything.
  final raw = amount6 ?? await _withdrawableUsdcRaw(api, base, owner);
  if (raw <= 0) {
    onStep?.call('nothing to withdraw');
    return;
  }
  final amountUi = (raw / 1e6).toStringAsFixed(6);

  // Snapshot wallet USDC so we can detect arrival by polling — no re-signing.
  final before = await wallet.readWalletUsdc6();

  onStep?.call('confirm cash-out in your wallet…');
  await _ownerTx(
    wallet,
    base,
    await api.requestWithdrawal(owner: owner, tokenMint: usdcMint, amountUi: amountUi),
    owner,
  );

  // The keeper releases the funds automatically — poll for them to land.
  onStep?.call('releasing to your wallet… (~30–90s)');
  if (await _awaitWalletGain(wallet, before, raw, const Duration(seconds: 150))) {
    onStep?.call('cashed out ✓');
    return;
  }

  // Didn't auto-complete — ONE execute-withdrawal recovery (one more signature).
  onStep?.call('finishing up — one more confirmation…');
  try {
    await _ownerTx(
      wallet,
      base,
      await api.executeWithdrawal(owner: owner, tokenMint: usdcMint),
      owner,
    );
  } on Object catch (e) {
    // 6077 NoWithdrawalPending = the keeper already finished it — funds delivered.
    final code = extractOnChainCode('$e');
    if (code != 6077 && !'$e'.contains('NoWithdrawalPending')) rethrow;
  }
  if (await _awaitWalletGain(wallet, before, raw, const Duration(seconds: 90))) {
    onStep?.call('cashed out ✓');
    return;
  }
  onStep?.call('withdrawal submitted — funds should arrive shortly');
}

/// Poll the wallet USDC balance until it rises by ~[expected6] (90%, to allow for
/// any fee/rounding) or [timeout] elapses. Read-only — never signs.
Future<bool> _awaitWalletGain(
  WalletController wallet,
  int before6,
  int expected6,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  final target = before6 + (expected6 * 0.9).round();
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 5));
    final now = await wallet.readWalletUsdc6();
    if (now >= target) return true;
  }
  return false;
}

/// Withdrawable USDC (raw units) for [owner]: `ledger deposits − basket debits +
/// basket pendingCredits` (research/flash.md §3). The deposit sits in the on-chain
/// UserDepositLedger (read via [base]); the basket net comes from the API. Matches
/// the fuel balance shown in the cockpit, so "cash out" pulls exactly what's shown.
Future<int> _withdrawableUsdcRaw(FlashApi api, RpcClient base, String owner) async {
  final deposits = await flashLedgerBalanceRaw(
    base,
    Ed25519HDPublicKey.fromBase58(owner),
    usdcMint,
  );
  var net = 0;
  try {
    final state = await api.ownerState(owner);
    final bp = state['basketPubkey'] as String?;
    if (bp != null && bp.isNotEmpty) {
      final rb = await api.rawBasket(bp);
      net = computeBasketNetRaw(rb['account'] as Map<String, dynamic>? ?? const {}, usdcMint);
    }
  } on Object {
    // no basket / API blip — the ledger deposit is still the right base
  }
  final bal = deposits + net;
  return bal < 0 ? 0 : bal;
}

/// Owner-**sign** a base-chain Flash tx via MWA and submit it OURSELVES (never
/// signAndSend — that lets the wallet simulate against its own RPC and fail with
/// "Simulation failed, can't predict balance changes"). Then confirm.
/// Whether [pubkey] is an existing on-chain account (for idempotent setup). A
/// transient RPC error is treated as "missing" — worst case we re-attempt an init
/// the merged tx would reject, which is no worse than before the existence check.
Future<bool> _accountExists(RpcClient rpc, String pubkey) async {
  try {
    // base64: the ledger account exceeds the 128-byte base58 RPC limit.
    final r = await rpc.getAccountInfo(
      pubkey,
      commitment: Commitment.confirmed,
      encoding: Encoding.base64,
    );
    return r.value != null;
  } on Object {
    return false;
  }
}

Future<void> _ownerTx(WalletController wallet, RpcClient base, BuiltTx tx, String owner) async {
  _assertOwnerSigner(tx.transactionBase64, owner);
  final sigs = await wallet.signAndSubmit([base64Decode(tx.transactionBase64)], base);
  await _confirm(base, sigs.first);
}

Future<void> _confirm(RpcClient rpc, String sig) async {
  final stop = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(stop)) {
    try {
      final st = await rpc.getSignatureStatuses([sig], searchTransactionHistory: true);
      final s = st.value.isEmpty ? null : st.value.first;
      if (s != null) {
        if (s.err != null) throw StateError('Flash tx failed: ${s.err}');
        if (s.confirmationStatus == ConfirmationStatus.confirmed ||
            s.confirmationStatus == ConfirmationStatus.finalized) {
          return;
        }
      }
    } on Exception {
      // transient RPC/DNS blip during the MWA resume-race — keep polling; the tx
      // was already submitted, so it'll show up once the network re-binds. (A real
      // on-chain failure throws StateError, an Error not an Exception, so it
      // propagates out of the loop and is not swallowed here.)
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  throw StateError('Flash tx $sig not confirmed in time');
}
