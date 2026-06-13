// Cross-language PARITY suite. Every case here mirrors a test in the Rust `throtl-engine`
// `math` module (programs/throtl-engine/.../src/math.rs). If these two diverge, the reconciler
// would settle real Flash positions off a virtual position the chain computed differently —
// a money bug. Keep them in lock-step (ARCHITECTURE §2.2).
import 'package:test/test.dart';
import 'package:throtl_core/throtl_core.dart';

void main() {
  const p1 = 100 * priceScale; // $100.000000000
  const p110 = 110 * priceScale; // $110
  const p90 = 90 * priceScale; // $90

  group('unrealized pnl', () {
    test('long profit', () {
      expect(unrealizedPnl6(1000 * usdScale, p1, p110), 100 * usdScale);
    });
    test('short profit', () {
      expect(unrealizedPnl6(-1000 * usdScale, p1, p90), 100 * usdScale);
    });
  });

  group('settleToTarget', () {
    test('open from flat sets vwap to mark', () {
      expect(settleToTarget(0, 0, 500 * usdScale, p1), const Settle(500 * usdScale, p1, 0));
    });
    test(r'increase reweights vwap to $105', () {
      expect(
        settleToTarget(1000 * usdScale, p1, 2000 * usdScale, p110),
        const Settle(2000 * usdScale, 105 * priceScale, 0),
      );
    });
    test('reduce realizes proportional pnl, vwap unchanged', () {
      expect(
        settleToTarget(2000 * usdScale, p1, 1000 * usdScale, p110),
        const Settle(1000 * usdScale, p1, 100 * usdScale),
      );
    });
    test('full close realizes all', () {
      expect(settleToTarget(1000 * usdScale, p1, 0, p110), const Settle(0, 0, 100 * usdScale));
    });
    test('cross through zero realizes old, reopens at mark', () {
      expect(
        settleToTarget(1000 * usdScale, p1, -500 * usdScale, p110),
        const Settle(-500 * usdScale, p110, 100 * usdScale),
      );
    });
  });

  group('sizing', () {
    test('sub-cent close at huge mark does not round to zero', () {
      const big = 100000 * priceScale;
      const entry = 99000 * priceScale;
      expect(unrealizedPnl6(1 * usdScale, entry, big) > 0, isTrue);
    });
    test('target notional scales with collateral, lev, bps', () {
      expect(targetNotional6(500 * usdScale, 100000, 10000), 5000 * usdScale);
      expect(targetNotional6(500 * usdScale, 100000, -5000), -2500 * usdScale);
    });
    test('bps round-trips through notional', () {
      const coll = 500 * usdScale;
      final n = targetNotional6(coll, 100000, 7500);
      expect(notionalToBps(n, coll, 100000), 7500);
    });
    test('effective collateral clamps at zero', () {
      expect(effectiveCollateral6(100 * usdScale, -200 * usdScale), 0);
      expect(effectiveCollateral6(100 * usdScale, 50 * usdScale), 150 * usdScale);
    });
  });
}
