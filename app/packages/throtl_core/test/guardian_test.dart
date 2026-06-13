import 'package:test/test.dart';
import 'package:throtl_core/throtl_core.dart';

void main() {
  int usd(num x) => (x * usdScale).round();
  int px(num x) => (x * priceScale).round();

  group('stopTriggerE9', () {
    test('long stop sits below entry by |floor|/size × haircut', () {
      // $1000 long @ $100, floor −$50 → 50/1000 = 5%, ×0.92 = 4.6% → $95.40.
      final t = stopTriggerE9(
        side: Side.long,
        entryE9: px(100),
        sizeUsd6: usd(1000),
        lossFloor6: usd(-50),
      );
      expect(t, px(95.4));
    });

    test('short stop sits above entry', () {
      final t = stopTriggerE9(
        side: Side.short,
        entryE9: px(100),
        sizeUsd6: usd(1000),
        lossFloor6: usd(-50),
      );
      expect(t, px(104.6));
    });

    test('flat / zero size has no stop', () {
      expect(
        stopTriggerE9(side: Side.flat, entryE9: px(100), sizeUsd6: 0, lossFloor6: usd(-50)),
        isNull,
      );
      expect(
        stopTriggerE9(side: Side.long, entryE9: px(100), sizeUsd6: 0, lossFloor6: usd(-50)),
        isNull,
      );
    });

    test('tighter stop on a larger position (same floor)', () {
      // Larger size ⇒ a smaller price move hits the dollar floor ⇒ trigger closer to entry.
      final small = stopTriggerE9(
        side: Side.long,
        entryE9: px(100),
        sizeUsd6: usd(500),
        lossFloor6: usd(-50),
      )!;
      final big = stopTriggerE9(
        side: Side.long,
        entryE9: px(100),
        sizeUsd6: usd(2000),
        lossFloor6: usd(-50),
      )!;
      expect(big > small, isTrue, reason: 'bigger size → stop nearer entry');
    });
  });

  group('floorBreached', () {
    test('not breached on a small drawdown', () {
      // $500 fuel, $2500 long @ $100, mark $96 → −$100 unreal, equity $400 > floor −$200.
      expect(
        floorBreached(
          fuelUsd6: usd(500),
          realizedPnl6: 0,
          notionalUsd6: usd(2500),
          entryVwapE9: px(100),
          markE9: px(96),
          lossFloor6: usd(-200),
        ),
        isFalse,
      );
    });

    test('breached when equity falls to/below the floor', () {
      // mark $70 → −$750 unreal, equity −$250 ≤ floor −$200.
      expect(
        floorBreached(
          fuelUsd6: usd(500),
          realizedPnl6: 0,
          notionalUsd6: usd(2500),
          entryVwapE9: px(100),
          markE9: px(70),
          lossFloor6: usd(-200),
        ),
        isTrue,
      );
    });
  });

  test('worstCaseLossBound is always worse than the nominal floor', () {
    final bound = worstCaseLossBound6(
      lossFloor6: usd(-200),
      slippageUsd6: usd(5),
      keeperHoldDriftUsd6: usd(15),
      bandGapUsd6: usd(10),
    );
    expect(bound, usd(-230));
    expect(bound < usd(-200), isTrue, reason: 'promise is never better than nominal floor');
  });
}
