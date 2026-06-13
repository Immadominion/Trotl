// The pure Flash order-planner — the money-math of the production gateway, tested without network:
// notional→collateral conversion, side strings, full/partial close semantics, flip = close+open,
// and the open-without-stop invariant (every open/flip carries a non-zero stopLoss).
import 'package:test/test.dart';
import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_runtime/throtl_runtime.dart';

const _mark = 67865960520; // $67.866 priceE9

const _ride = RideConfig(
  fuelUsd6: 500000000,
  maxLevBps: 100000, // 10x
  lossFloor6: -200000000,
  marketId: 0,
);

void main() {
  group('scaledToUi', () {
    test('usd6 → trimmed decimal', () {
      expect(scaledToUi(250000000, 6), '250');
      expect(scaledToUi(1250000000, 6), '1250');
      expect(scaledToUi(250500000, 6), '250.5');
      expect(scaledToUi(1, 6), '0.000001');
      expect(scaledToUi(0, 6), '0');
    });
    test('priceE9 → trimmed decimal', () {
      expect(scaledToUi(_mark, 9), '67.86596052');
      expect(scaledToUi(1000000000, 9), '1');
    });
    test('negative', () {
      expect(scaledToUi(-200000000, 6), '-200');
    });
  });

  group('collateralUsd6For', () {
    test('notional / leverage', () {
      // $2500 notional at 10x ⇒ $250 collateral.
      expect(collateralUsd6For(2500000000, _ride), 250000000);
      // $5000 notional at 10x ⇒ $500 collateral (full fuel).
      expect(collateralUsd6For(5000000000, _ride), 500000000);
    });
  });

  group('planFlashOrder', () {
    test('OpenIncrease from flat → one open call, collateral + leverage + inline stop', () {
      final plan = planFlashOrder(
        const OpenIncrease(Side.long, 2500000000),
        ride: _ride,
        markE9: _mark,
        settled: const FlashPosition.flat(),
      );
      expect(plan.calls.length, 1);
      final c = plan.calls.single;
      expect(c.kind, FlashCallKind.open);
      expect(c.tradeType, 'LONG');
      expect(c.inputTokenSymbol, 'USDC');
      expect(c.outputTokenSymbol, 'SOL');
      expect(c.inputAmountUi, '250');
      expect(c.leverage, 10);
      expect(c.stopLoss, isNot('0'), reason: 'open must carry a floor stop');
      // long stop is below entry.
      expect(double.parse(c.stopLoss!), lessThan(_mark / 1e9));
    });

    test('FullClose → close with inputUsdUi "0"', () {
      final plan = planFlashOrder(
        const FullClose(Side.long),
        ride: _ride,
        markE9: _mark,
        settled: const FlashPosition(side: Side.long, sizeUsd6: 5000000000, entryE9: _mark),
      );
      final c = plan.calls.single;
      expect(c.kind, FlashCallKind.close);
      expect(c.side, 'LONG');
      expect(c.inputUsdUi, '0');
      expect(c.marketSymbol, 'SOL');
      expect(c.withdrawTokenSymbol, 'USDC');
    });

    test('ReducePartial → close with USD-notional inputUsdUi', () {
      final plan = planFlashOrder(
        const ReducePartial(Side.long, 1250000000),
        ride: _ride,
        markE9: _mark,
        settled: const FlashPosition(side: Side.long, sizeUsd6: 5000000000, entryE9: _mark),
      );
      final c = plan.calls.single;
      expect(c.kind, FlashCallKind.close);
      expect(c.inputUsdUi, '1250');
      expect(c.side, 'LONG');
    });

    test('Flip → close the old side then open the new WITH a stop (2 calls, ordered)', () {
      final plan = planFlashOrder(
        const Flip(Side.short, 2500000000),
        ride: _ride,
        markE9: _mark,
        settled: const FlashPosition(side: Side.long, sizeUsd6: 5000000000, entryE9: _mark),
      );
      expect(plan.calls.length, 2);
      expect(plan.calls[0].kind, FlashCallKind.close);
      expect(plan.calls[0].side, 'LONG');
      expect(plan.calls[0].inputUsdUi, '0');
      expect(plan.calls[1].kind, FlashCallKind.open);
      expect(plan.calls[1].tradeType, 'SHORT');
      expect(plan.calls[1].inputAmountUi, '250');
      expect(plan.calls[1].stopLoss, isNot('0'));
      // short stop is above entry.
      expect(double.parse(plan.calls[1].stopLoss!), greaterThan(_mark / 1e9));
    });

    test('ReplaceStop → an explicit replaceStop call (REST gap surfaced, not dropped)', () {
      final plan = planFlashOrder(
        const ReplaceStop(Side.long),
        ride: _ride,
        markE9: _mark,
        settled: const FlashPosition(side: Side.long, sizeUsd6: 2500000000, entryE9: _mark),
      );
      final c = plan.calls.single;
      expect(c.kind, FlashCallKind.replaceStop);
      expect(c.side, 'LONG');
      expect(c.stopLoss, isNot('0'));
    });

    test('NoOp → no calls', () {
      final plan = planFlashOrder(
        const NoOp(),
        ride: _ride,
        markE9: _mark,
        settled: const FlashPosition.flat(),
      );
      expect(plan.calls, isEmpty);
    });
  });
}
