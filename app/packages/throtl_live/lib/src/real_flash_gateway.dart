/// The production `FlashGateway`: turns a bounded reconciler action into real Flash Trade v2 calls.
/// It runs `throtl_runtime`'s pure `planFlashOrder` (notional→collateral, side, inline floor-stop),
/// builds each unsigned tx via `flash_client`, hands it to a caller-supplied sign+submit+confirm, and
/// then RE-READS the trusted settled position from the venue (never the ER) into `settled`.
///
/// The sign/submit and the position read are injected (typedefs below) so this orchestration is
/// unit-tested with fakes; the live wiring (WalletSigner + RpcClient + owner-WS parse) lives in the
/// binaries / app. The executor calls this exactly as it calls the SimGateway — no test-only fork.
library;

import 'package:flash_client/flash_client.dart';
import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_runtime/throtl_runtime.dart';

/// Sign an unsigned [BuiltTx], submit it, and return when confirmed (the signature). Production:
/// `WalletSigner.signBase64` (session key) + `RpcClient.sendTransaction` against the Flash submit RPC.
typedef SignSubmitConfirm = Future<String> Function(BuiltTx tx);

/// Read the CURRENT trusted real position from the venue (owner WS / `rawBasket`), PnL recomputed
/// client-side. This is the ONLY source of [RealFlashGateway.settled].
typedef ReadSettled = Future<FlashPosition> Function();

/// Raised when an action maps to a Flash capability the wrapped REST surface doesn't expose — surfaced
/// (never silently no-op'd) so a missing stop adjustment can't masquerade as success.
class FlashGatewayUnsupported implements Exception {
  FlashGatewayUnsupported(this.message);
  final String message;
  @override
  String toString() => 'FlashGatewayUnsupported: $message';
}

class RealFlashGateway implements FlashGateway {
  RealFlashGateway({
    required this.api,
    required this.signSubmit,
    required this.readSettled,
    required this.owner,
    this.signer,
    this.sessionToken,
    this.slippagePercentage = '0.5',
    FlashPosition initial = const FlashPosition.flat(),
  }) : _settled = initial;

  final FlashApi api;
  final SignSubmitConfirm signSubmit;
  final ReadSettled readSettled;

  /// Parent wallet (base58). Trades are session-signed when [signer]+[sessionToken] are set.
  final String owner;
  final String? signer;
  final String? sessionToken;
  final String slippagePercentage;

  FlashPosition _settled;

  /// Signatures of the txs submitted so far (newest last) — for the ride log / debugging.
  final List<String> submittedSignatures = [];

  @override
  FlashPosition get settled => _settled;

  @override
  Future<void> apply(
    ReconcilerAction action, {
    required RideConfig ride,
    required int markE9,
    required int nowMicros,
  }) async {
    final plan = planFlashOrder(action, ride: ride, markE9: markE9, settled: _settled);
    for (final call in plan.calls) {
      final tx = await _build(call);
      submittedSignatures.add(await signSubmit(tx));
    }
    // Re-read the trusted position only if we actually moved (a flip = close+open is one re-read).
    if (plan.calls.isNotEmpty) {
      _settled = await readSettled();
    }
  }

  Future<BuiltTx> _build(FlashCall call) {
    switch (call.kind) {
      case FlashCallKind.open:
        return api.openPosition(
          inputTokenSymbol: call.inputTokenSymbol!,
          outputTokenSymbol: call.outputTokenSymbol!,
          inputAmountUi: call.inputAmountUi!,
          leverage: call.leverage!,
          tradeType: call.tradeType!,
          stopLoss: call.stopLoss,
          owner: signer == null ? owner : null,
          signer: signer,
          sessionToken: sessionToken,
          slippagePercentage: slippagePercentage,
        );
      case FlashCallKind.close:
        return api.closePosition(
          owner: owner,
          marketSymbol: call.marketSymbol!,
          side: call.side!,
          inputUsdUi: call.inputUsdUi!,
          withdrawTokenSymbol: call.withdrawTokenSymbol!,
          signer: signer,
          sessionToken: sessionToken,
          slippagePercentage: slippagePercentage,
        );
      case FlashCallKind.replaceStop:
        throw FlashGatewayUnsupported(
          'ReplaceStop needs the Flash set-tpsl endpoint (absent from the v2 tx-builder REST surface). '
          'Wire it here when available; until then the stop re-tightens on the next size change.',
        );
    }
  }
}
