/// Pure mapping from a bounded [ReconcilerAction] to the concrete Flash Trade v2 tx-builder calls
/// that realize it — the subtle, money-critical part of the production gateway (notional→collateral,
/// side strings, stop-trigger price → UI decimal), kept free of any network or signer so it is unit
/// tested deterministically. The live adapter is a thin shell: build these calls, sign, submit.
///
/// Conventions (see research/flash.md): open/increase takes collateral `inputAmountUi` + `leverage`
/// (notional = collateral × leverage), so we divide notional by leverage to get collateral. Close
/// takes USD-notional `inputUsdUi` ("0" ⇒ full close). A position that stays open MUST carry a
/// floor-derived `stopLoss`; a flip closes then opens-with-inline-stop in one plan.
library;

import 'package:meta/meta.dart';
import 'package:throtl_core/throtl_core.dart';

/// Symbols for a market: the perp output token and the collateral input token.
@immutable
class MarketSpec {
  const MarketSpec({required this.outputSymbol, this.collateralSymbol = 'USDC'});
  final String outputSymbol;
  final String collateralSymbol;

  /// Default static table (extend as markets are added). marketId 0 = SOL-PERP / USDC.
  static const _table = {0: MarketSpec(outputSymbol: 'SOL')};

  static MarketSpec forMarketId(int marketId) =>
      _table[marketId] ?? (throw ArgumentError('unknown marketId $marketId'));
}

enum FlashCallKind {
  /// `/transaction-builder/open-position` (open or increase, with an inline stopLoss).
  open,

  /// `/transaction-builder/close-position` (partial via inputUsdUi, or full via "0").
  close,

  /// Re-place the stop on an unchanged position. The wrapped REST surface has no standalone
  /// modify-stop, so the live adapter handles this out-of-band (set-tpsl); flagged here explicitly
  /// rather than silently dropped.
  replaceStop,
}

@immutable
class FlashCall {
  const FlashCall.open({
    required this.inputTokenSymbol,
    required this.outputTokenSymbol,
    required this.inputAmountUi,
    required this.leverage,
    required this.tradeType,
    required this.stopLoss,
  }) : kind = FlashCallKind.open,
       marketSymbol = null,
       side = null,
       inputUsdUi = null,
       withdrawTokenSymbol = null;

  const FlashCall.close({
    required this.marketSymbol,
    required this.side,
    required this.inputUsdUi,
    required this.withdrawTokenSymbol,
  }) : kind = FlashCallKind.close,
       inputTokenSymbol = null,
       outputTokenSymbol = null,
       inputAmountUi = null,
       leverage = null,
       tradeType = null,
       stopLoss = null;

  const FlashCall.replaceStop({required this.side, required this.stopLoss})
    : kind = FlashCallKind.replaceStop,
      inputTokenSymbol = null,
      outputTokenSymbol = null,
      inputAmountUi = null,
      leverage = null,
      tradeType = null,
      marketSymbol = null,
      inputUsdUi = null,
      withdrawTokenSymbol = null;

  final FlashCallKind kind;
  // open
  final String? inputTokenSymbol;
  final String? outputTokenSymbol;
  final String? inputAmountUi;
  final num? leverage;
  final String? tradeType;
  final String? stopLoss;
  // close
  final String? marketSymbol;
  final String? side;
  final String? inputUsdUi;
  final String? withdrawTokenSymbol;
}

/// The ordered calls that realize one action (1 for most; 2 for a flip: close then open).
@immutable
class FlashOrderPlan {
  const FlashOrderPlan(this.calls);
  final List<FlashCall> calls;
}

String _sideStr(Side s) => s == Side.long ? 'LONG' : 'SHORT';

/// Format a fixed-point integer ([value] at 10^[scaleDigits]) as a trimmed decimal UI string.
/// BigInt-based so it is byte-identical on the VM and the web. e.g. (250000000, 6) ⇒ "250".
String scaledToUi(int value, int scaleDigits) {
  final neg = value < 0;
  final v = BigInt.from(value.abs());
  final scale = BigInt.from(10).pow(scaleDigits);
  final whole = v ~/ scale;
  final frac = (v % scale).toString().padLeft(scaleDigits, '0').replaceAll(RegExp(r'0+$'), '');
  final s = frac.isEmpty ? '$whole' : '$whole.$frac';
  return neg ? '-$s' : s;
}

/// Collateral (usd6) needed to open [notionalAbsUsd6] at the ride's leverage.
int collateralUsd6For(int notionalAbsUsd6, RideConfig ride) =>
    (BigInt.from(notionalAbsUsd6) * BigInt.from(bpsScale) ~/ BigInt.from(ride.maxLevBps)).toInt();

/// Resulting (size, entry) after applying an open/increase to [settled] at [markE9].
({int size, int entry}) _afterOpen(FlashPosition settled, int addUsd6, int markE9) {
  if (settled.isFlat) return (size: addUsd6, entry: markE9);
  final newSize = settled.sizeUsd6 + addUsd6;
  final blended =
      (BigInt.from(settled.entryE9) * BigInt.from(settled.sizeUsd6) +
          BigInt.from(markE9) * BigInt.from(addUsd6)) ~/
      BigInt.from(newSize);
  return (size: newSize, entry: blended.toInt());
}

/// Build the Flash calls that realize [action]. [settled] is the current real position; [markE9] the
/// mark used for entry + stop derivation.
FlashOrderPlan planFlashOrder(
  ReconcilerAction action, {
  required RideConfig ride,
  required int markE9,
  required FlashPosition settled,
}) {
  final spec = MarketSpec.forMarketId(ride.marketId);
  int? stopFor(Side side, int entryE9, int sizeUsd6) => stopTriggerE9(
    side: side,
    entryE9: entryE9,
    sizeUsd6: sizeUsd6,
    lossFloor6: ride.lossFloor6,
  );

  FlashCall openCall(Side side, int addUsd6, int resSize, int resEntry) {
    final stop = stopFor(side, resEntry, resSize);
    return FlashCall.open(
      inputTokenSymbol: spec.collateralSymbol,
      outputTokenSymbol: spec.outputSymbol,
      inputAmountUi: scaledToUi(collateralUsd6For(addUsd6, ride), 6),
      leverage: ride.maxLevBps / bpsScale,
      tradeType: _sideStr(side),
      // Stop derived on the RESULTING position (Flash sets the whole-position stop at open).
      stopLoss: stop == null ? '0' : scaledToUi(stop, 9),
    );
  }

  switch (action) {
    case OpenIncrease(:final side, :final addUsd6):
      final r = _afterOpen(settled, addUsd6, markE9);
      return FlashOrderPlan([openCall(side, addUsd6, r.size, r.entry)]);

    case ReducePartial(:final side, :final reduceUsd6):
      return FlashOrderPlan([
        FlashCall.close(
          marketSymbol: spec.outputSymbol,
          side: _sideStr(side),
          inputUsdUi: scaledToUi(reduceUsd6, 6),
          withdrawTokenSymbol: spec.collateralSymbol,
        ),
      ]);

    case FullClose(:final side):
      return FlashOrderPlan([
        FlashCall.close(
          marketSymbol: spec.outputSymbol,
          side: _sideStr(side),
          inputUsdUi: '0', // ⇒ full close (research/flash.md §2)
          withdrawTokenSymbol: spec.collateralSymbol,
        ),
      ]);

    case Flip(:final toSide, :final openUsd6):
      // Close the current side fully, then open the opposite WITH its inline stop — never an open
      // position without a stop (ARCHITECTURE §3.3 flip safety).
      return FlashOrderPlan([
        FlashCall.close(
          marketSymbol: spec.outputSymbol,
          side: _sideStr(settled.side),
          inputUsdUi: '0',
          withdrawTokenSymbol: spec.collateralSymbol,
        ),
        openCall(toSide, openUsd6, openUsd6, markE9),
      ]);

    case ReplaceStop(:final side):
      final stop = stopFor(side, settled.entryE9, settled.sizeUsd6);
      return FlashOrderPlan([
        FlashCall.replaceStop(
          side: _sideStr(side),
          stopLoss: stop == null ? '0' : scaledToUi(stop, 9),
        ),
      ]);

    case NoOp():
      return const FlashOrderPlan([]);
  }
}
