import 'package:test/test.dart';
import 'package:throtl_core/throtl_core.dart';

int usd(num x) => (x * usdScale).round();
int px(num x) => (x * priceScale).round();

// $500 fuel, 10x, floor −$200. maxNotional = $5000; band = max(2.5%·$5000, $12) = $125.
final _ride = RideConfig(fuelUsd6: usd(500), maxLevBps: 100000, lossFloor6: usd(-200), marketId: 0);

FlashPosition _long(num size, {num entry = 100, num? stop}) => FlashPosition(
  side: Side.long,
  sizeUsd6: usd(size),
  entryE9: px(entry),
  stopTriggerE9: stop == null ? null : px(stop),
);

/// Drive two steps so the debounce is satisfied, returning the emitted action.
ReconcilerAction _actNow(
  Reconciler r, {
  required int virtual,
  required FlashPosition settled,
  int erMark = 100000000000, // $100
  int? guardMark,
  MarketSession session = MarketSession.regular,
}) {
  final g = guardMark ?? erMark;
  ReconcileInput at(int now) => ReconcileInput(
    virtualNotionalUsd6: virtual,
    settled: settled,
    erMarkE9: erMark,
    guardMarkE9: g,
    session: session,
    nowMicros: now,
  );
  final s1 = r.step(const Synced(), at(0));
  return r.step(s1.state, at(r.cfg.debounceMicros)).action;
}

void main() {
  final r = Reconciler(_ride);

  test('band and cap derive from fuel × leverage', () {
    expect(_ride.maxNotionalAbs6, usd(5000));
    expect(r.band6, usd(125));
  });

  group('decisions', () {
    test('open from flat', () {
      final a = _actNow(r, virtual: usd(1000), settled: const FlashPosition.flat());
      expect(a, isA<OpenIncrease>());
      expect((a as OpenIncrease).side, Side.long);
      expect(a.addUsd6, usd(1000));
    });

    test(r'snap-to-flat: virtual below $12 ⇒ no position opened', () {
      final a = _actNow(r, virtual: usd(5), settled: const FlashPosition.flat());
      expect(a, isA<NoOp>());
    });

    test('clamp advisory virtual to the local cap (operator cannot exceed fuel×lev)', () {
      final a = _actNow(r, virtual: usd(999999), settled: const FlashPosition.flat());
      expect(a, isA<OpenIncrease>());
      // capped per-action to 50% of max ($2500), and target itself clamped to $5000.
      expect((a as OpenIncrease).addUsd6, usd(2500));
    });

    test('increase same side beyond band', () {
      final a = _actNow(r, virtual: usd(1500), settled: _long(1000, stop: 95.4));
      expect(a, isA<OpenIncrease>());
      expect((a as OpenIncrease).addUsd6, usd(500));
    });

    test('within band ⇒ NoOp when stop is correct', () {
      // $1000 long, floor −$200 ⇒ correct stop = 100×(1 − 0.2×0.92) = $81.60.
      // Target $1050 (diff $50 ≤ $125 band) ⇒ nothing to do.
      final a = _actNow(r, virtual: usd(1050), settled: _long(1000, stop: 81.6));
      expect(a, isA<NoOp>());
    });

    test('within band but missing stop ⇒ ReplaceStop', () {
      final a = _actNow(r, virtual: usd(1050), settled: _long(1000));
      expect(a, isA<ReplaceStop>());
    });

    test('reduce partial', () {
      final a = _actNow(r, virtual: usd(500), settled: _long(1000, stop: 90.8));
      expect(a, isA<ReducePartial>());
      expect((a as ReducePartial).reduceUsd6, usd(500));
    });

    test('97% rule: a reduce leaving dust becomes a full close', () {
      // $1000 long, target $20 ⇒ remaining $20 < 3%·$1000 = $30 ⇒ full close.
      final a = _actNow(r, virtual: usd(20), settled: _long(1000, stop: 90.8));
      expect(a, isA<FullClose>());
    });

    test('flat target full-closes any open position', () {
      final a = _actNow(r, virtual: usd(2), settled: _long(1000, stop: 90.8));
      expect(a, isA<FullClose>());
    });

    test('sign flip ⇒ Flip (close then open opposite)', () {
      final a = _actNow(r, virtual: usd(-800), settled: _long(1000, stop: 90.8));
      expect(a, isA<Flip>());
      expect((a as Flip).toSide, Side.short);
    });
  });

  group('degraded gates', () {
    ReconcileInput at(
      int erMark,
      int guardMark,
      MarketSession s, {
      bool link = true,
      bool stale = false,
    }) => ReconcileInput(
      virtualNotionalUsd6: usd(1000),
      settled: const FlashPosition.flat(),
      erMarkE9: erMark,
      guardMarkE9: guardMark,
      session: s,
      nowMicros: 0,
      linkOk: link,
      oracleStale: stale,
    );

    test('price divergence > 1% refuses to settle', () {
      final res = r.step(const Synced(), at(px(100), px(98), MarketSession.regular));
      expect(res.state, isA<Degraded>());
      expect((res.state as Degraded).reason, DegradeReason.priceDivergence);
      expect(res.action, isA<NoOp>());
    });

    test('market closed refuses to settle', () {
      final res = r.step(const Synced(), at(px(100), px(100), MarketSession.closed));
      expect((res.state as Degraded).reason, DegradeReason.marketClosed);
    });

    test('lost link refuses to settle', () {
      final res = r.step(const Synced(), at(px(100), px(100), MarketSession.regular, link: false));
      expect((res.state as Degraded).reason, DegradeReason.linkLost);
    });

    test('stale oracle refuses to settle', () {
      final res = r.step(const Synced(), at(px(100), px(100), MarketSession.regular, stale: true));
      expect((res.state as Degraded).reason, DegradeReason.oracleStale);
    });
  });

  group('settling gate (FSM-level double-settle guard)', () {
    ReconcileInput at(int now, FlashPosition settled) => ReconcileInput(
      virtualNotionalUsd6: usd(1000),
      settled: settled,
      erMarkE9: px(100),
      guardMarkE9: px(100),
      session: MarketSession.regular,
      nowMicros: now,
    );

    test('does not re-emit while waiting for a fill', () {
      // Reach Settling, then step again with the fill NOT yet reflected and no timeout.
      final s1 = r.step(const Synced(), at(0, const FlashPosition.flat()));
      final s2 = r.step(s1.state, at(r.cfg.debounceMicros, const FlashPosition.flat()));
      expect(s2.state, isA<Settling>());
      expect(s2.action, isA<OpenIncrease>());

      final s3 = r.step(s2.state, at(r.cfg.debounceMicros + 1000, const FlashPosition.flat()));
      expect(s3.action, isA<NoOp>(), reason: 'must not re-open before the fill lands');
    });

    test('re-acts after the settle timeout if the fill never lands', () {
      final s1 = r.step(const Synced(), at(0, const FlashPosition.flat()));
      final s2 = r.step(s1.state, at(r.cfg.debounceMicros, const FlashPosition.flat()));
      final late = r.cfg.debounceMicros + r.cfg.settleTimeoutMicros + 1;
      final s3 = r.step(s2.state, at(late, const FlashPosition.flat()));
      expect(s3.action, isA<OpenIncrease>(), reason: 'timed-out fill ⇒ retry');
    });
  });

  group('freeze after stop-out (defense-in-depth, layer 3)', () {
    ReconcileInput at(FlashPosition settled, {int virtual = 1000000000}) => ReconcileInput(
      virtualNotionalUsd6: virtual, // default $1000 long
      settled: settled,
      erMarkE9: px(100),
      guardMarkE9: px(100),
      session: MarketSession.regular,
      nowMicros: 0,
    );

    test('an established position that vanishes ⇒ Frozen, does NOT re-open', () {
      // We were Synced to a $1000 long; the venue stop fires → settled goes flat; thumb still long.
      final res = r.step(const Synced(1000000000), at(const FlashPosition.flat()));
      expect(res.state, isA<Frozen>());
      expect(res.action, isA<NoOp>(), reason: 'must not re-open into the adverse move');
    });

    test('stays frozen while the thumb is still pinned', () {
      final res = r.step(const Frozen(), at(const FlashPosition.flat()));
      expect(res.state, isA<Frozen>());
      expect(res.action, isA<NoOp>());
    });

    test('re-arms once the user releases the throttle (target → flat)', () {
      final res = r.step(const Frozen(), at(const FlashPosition.flat(), virtual: usd(2)));
      expect(res.state, isA<Synced>());
      expect(res.action, isA<NoOp>());
    });

    test('a never-established open that times out is a retry, NOT a freeze', () {
      // prior = 0 (opening from flat) ⇒ a flat settled at timeout means the open never landed.
      final timedOut = Settling(0, usd(1000), 0);
      final res = r.step(
        timedOut,
        ReconcileInput(
          virtualNotionalUsd6: usd(1000),
          settled: const FlashPosition.flat(),
          erMarkE9: px(100),
          guardMarkE9: px(100),
          session: MarketSession.regular,
          nowMicros: r.cfg.settleTimeoutMicros + 1,
        ),
      );
      expect(
        res.action,
        isA<OpenIncrease>(),
        reason: 'failed open retries; only a vanished established position freezes',
      );
    });
  });
}
