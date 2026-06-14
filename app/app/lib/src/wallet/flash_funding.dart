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
import 'package:solana/dto.dart' hide Commitment;
import 'package:solana/encoder.dart' show SignedTx;
import 'package:solana/solana.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_live/throtl_live.dart';

const String usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

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
  final hasBasket = ((state['basketPubkey'] as String?) ?? '').isNotEmpty;

  final steps = <(String, Future<BuiltTx> Function())>[
    if (!hasBasket) ...[
      ('init ledger', () => api.initDepositLedger(owner)),
      ('init basket', () => api.initBasket(owner)),
      ('delegate basket', () => api.delegateBasket(owner: owner, payer: owner)),
    ],
    (
      'deposit $amountUi USDC',
      () => api.depositDirect(owner: owner, tokenMint: usdcMint, amountUi: amountUi),
    ),
  ];

  for (final (name, build) in steps) {
    onStep?.call(name);
    await _ownerTx(wallet, base, await build(), owner);
  }
}

/// Withdraw the full withdrawable USDC back to the owner. Two-phase: request →
/// wait for the settlement receipt to cross to base (~30–90s) → execute with retry.
Future<void> flashWithdraw(
  WalletController wallet,
  FlashApi api,
  RpcClient base, {
  FundingProgress? onStep,
}) async {
  final owner = wallet.owner;
  if (owner == null) throw StateError('wallet disconnected');

  final state = await api.ownerState(owner);
  final basketPubkey = state['basketPubkey'] as String?;
  final raw = basketPubkey == null ? 0 : await api.withdrawableRaw(basketPubkey, usdcMint);
  if (raw <= 0) {
    onStep?.call('nothing to withdraw');
    return;
  }
  final amountUi = (raw / 1e6).toStringAsFixed(6);

  onStep?.call('request withdrawal $amountUi USDC');
  await _ownerTx(
    wallet,
    base,
    await api.requestWithdrawal(owner: owner, tokenMint: usdcMint, amountUi: amountUi),
    owner,
  );

  onStep?.call('waiting for settlement (~45s)…');
  await Future<void>.delayed(const Duration(seconds: 45));

  // Execute, retrying while the receipt is still crossing (0xbc4 / AccountNotInitialized).
  for (var attempt = 1; attempt <= 12; attempt++) {
    try {
      onStep?.call('execute withdrawal (try $attempt)');
      await _ownerTx(
        wallet,
        base,
        await api.executeWithdrawal(owner: owner, tokenMint: usdcMint),
        owner,
      );
      return;
    } on Object catch (e) {
      final s = '$e';
      final notReady =
          s.contains('0xbc4') || s.contains('AccountNotInitialized') || s.contains('3012');
      if (notReady) {
        final pend = basketPubkey == null ? 0 : await api.withdrawableRaw(basketPubkey, usdcMint);
        if (pend <= 0) return; // keeper already finalized it
        if (attempt < 12) {
          await Future<void>.delayed(const Duration(seconds: 15));
          continue;
        }
      }
      rethrow;
    }
  }
}

/// Owner-sign + submit a base-chain Flash tx via MWA, then confirm.
Future<void> _ownerTx(WalletController wallet, RpcClient base, BuiltTx tx, String owner) async {
  _assertOwnerSigner(tx.transactionBase64, owner);
  final sigs = await wallet.signAndSend([base64Decode(tx.transactionBase64)]);
  await _confirm(base, sigs.first);
}

Future<void> _confirm(RpcClient rpc, String sig) async {
  final stop = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(stop)) {
    final st = await rpc.getSignatureStatuses([sig], searchTransactionHistory: true);
    final s = st.value.isEmpty ? null : st.value.first;
    if (s != null) {
      if (s.err != null) throw StateError('Flash tx failed: ${s.err}');
      if (s.confirmationStatus == ConfirmationStatus.confirmed ||
          s.confirmationStatus == ConfirmationStatus.finalized) {
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  throw StateError('Flash tx $sig not confirmed in time');
}
