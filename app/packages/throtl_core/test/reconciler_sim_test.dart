// Simulation harness + safety-invariant property tests. The SAME `Reconciler.step` that production
// runs is driven here against a deterministic market and a faithful fake Flash venue. These
// invariants are the ones a money bug would violate (ARCHITECTURE §3.3/§3.4, ROADMAP G3).
import 'dart:math';

import 'package:test/test.dart';
import 'package:throtl_core/throtl_core.dart';

int usd(num x) => (x * usdScale).round();
int px(num x) => (x * priceScale).round();

/// A faithful fake of the Flash venue: applies actions, ALWAYS attaches the floor-derived stop on a
/// resulting open position (the executor's contract), and runs a keeper that closes the position
/// when the mark crosses the stop and holds for [keeperHoldSteps].
class FakeFlash {
  FakeFlash(this.lossFloor6, {this.keeperHoldSteps = 2, this.slippageBps = 20});

  final int lossFloor6;
  final int keeperHoldSteps;
  final int slippageBps;

  FlashPosition pos = const FlashPosition.flat();
  int realizedLoss6 = 0; // accumulated realized loss magnitude (>=0)
  int _holdCounter = 0;

  int _vwap(int aSize, int aPx, int bSize, int bPx) {
    final num = BigInt.from(aSize) * BigInt.from(aPx) + BigInt.from(bSize) * BigInt.from(bPx);
    return (num ~/ BigInt.from(aSize + bSize)).toInt();
  }

  int? _stopFor(Side side, int entry, int size) =>
      stopTriggerE9(side: side, entryE9: entry, sizeUsd6: size, lossFloor6: lossFloor6);

  /// Apply a reconciler action at the current [mark]. Flip is atomic (close + open + inline stop).
  void apply(ReconcilerAction action, int mark) {
    switch (action) {
      case NoOp():
        break;
      case ReplaceStop(:final side):
        if (!pos.isFlat) {
          pos = pos.copyWith(stopTriggerE9: _stopFor(side, pos.entryE9, pos.sizeUsd6));
        }
      case OpenIncrease(:final side, :final addUsd6):
        if (pos.isFlat) {
          pos = FlashPosition(
            side: side,
            sizeUsd6: addUsd6,
            entryE9: mark,
            stopTriggerE9: _stopFor(side, mark, addUsd6),
          );
        } else {
          final newSize = pos.sizeUsd6 + addUsd6;
          final newEntry = _vwap(pos.sizeUsd6, pos.entryE9, addUsd6, mark);
          pos = pos.copyWith(
            sizeUsd6: newSize,
            entryE9: newEntry,
            stopTriggerE9: _stopFor(side, newEntry, newSize),
          );
        }
      case ReducePartial(:final side, :final reduceUsd6):
        final newSize = pos.sizeUsd6 - reduceUsd6;
        pos = pos.copyWith(sizeUsd6: newSize, stopTriggerE9: _stopFor(side, pos.entryE9, newSize));
      case FullClose():
        pos = const FlashPosition.flat();
        _holdCounter = 0;
      case Flip(:final toSide, :final openUsd6):
        // atomic: close old, open opposite WITH inline stop — never stopless mid-flip.
        pos = FlashPosition(
          side: toSide,
          sizeUsd6: openUsd6,
          entryE9: mark,
          stopTriggerE9: _stopFor(toSide, mark, openUsd6),
        );
        _holdCounter = 0;
    }
  }

  /// Keeper: when mark crosses the stop and holds, close at mark (with slippage) and book the loss.
  void keeperTick(int mark) {
    if (pos.isFlat || pos.stopTriggerE9 == null) {
      _holdCounter = 0;
      return;
    }
    final crossed = pos.side == Side.long ? mark <= pos.stopTriggerE9! : mark >= pos.stopTriggerE9!;
    if (!crossed) {
      _holdCounter = 0;
      return;
    }
    if (++_holdCounter < keeperHoldSteps) return;
    // Realize loss at mark, plus slippage in the adverse direction.
    final slip = BigInt.from(mark) * BigInt.from(slippageBps) ~/ BigInt.from(bpsScale);
    final fill = pos.side == Side.long ? mark - slip.toInt() : mark + slip.toInt();
    final pnl = unrealizedPnl6(pos.signedUsd6, pos.entryE9, fill);
    if (pnl < 0) realizedLoss6 += -pnl;
    pos = const FlashPosition.flat();
    _holdCounter = 0;
  }
}

/// Deterministic price walk (seeded — no wall-clock randomness).
class Walk {
  Walk(int seed, int startE9) : _r = Random(seed), pxE9 = startE9;
  final Random _r;
  int pxE9;

  int step({double driftBps = 0, double volBps = 30}) {
    final shock = (_r.nextDouble() * 2 - 1) * volBps + driftBps;
    final deltaE9 = (pxE9 * shock / 10000).round();
    return pxE9 = max(1, pxE9 + deltaE9);
  }
}

void main() {
  final ride = RideConfig(
    fuelUsd6: usd(500),
    maxLevBps: 100000,
    lossFloor6: usd(-200),
    marketId: 0,
  );
  const cfg = ReconcileConfig();
  final band = Reconciler(ride).band6;

  // A scripted thumb over `n` steps: ramp long → hold → flip short → back to flat.
  int thumb(int i, int n) {
    final maxN = ride.maxNotionalAbs6;
    if (i < n * 0.2) return (maxN * (i / (n * 0.2))).round(); // ramp long to full
    if (i < n * 0.4) return maxN; // hold full long
    if (i < n * 0.6) return (-maxN * ((i - n * 0.4) / (n * 0.2))).round(); // flip toward full short
    if (i < n * 0.8) return -maxN; // hold short
    return (-maxN * (1 - (i - n * 0.8) / (n * 0.2))).round(); // ease back to flat
  }

  test('INVARIANT: an open position always carries a floor-derived stop (incl. across flips)', () {
    final r = Reconciler(ride);
    final flash = FakeFlash(ride.lossFloor6);
    final walk = Walk(7, px(100));
    ReconcilerState state = const Synced();
    const n = 400;
    const tick = 50000; // 50ms

    for (var i = 0; i < n; i++) {
      final mark = walk.step(volBps: 8);
      flash.keeperTick(mark);
      final input = ReconcileInput(
        virtualNotionalUsd6: thumb(i, n),
        settled: flash.pos,
        erMarkE9: mark,
        guardMarkE9: mark,
        session: MarketSession.regular,
        nowMicros: i * tick,
      );
      final res = r.step(state, input);
      state = res.state;
      flash.apply(res.action, mark);

      // The invariant: never an open position without a stop.
      if (!flash.pos.isFlat) {
        expect(flash.pos.hasStop, isTrue, reason: 'open position without a stop at step $i ($res)');
      }
      // No dust: a non-flat position is never microscopic.
      if (!flash.pos.isFlat) {
        expect(
          flash.pos.sizeUsd6 >= usd(11),
          isTrue,
          reason: 'dust position at step $i: ${flash.pos.sizeUsd6}',
        );
      }
    }
  });

  test('INVARIANT: settled exposure converges within band of a stable target', () {
    final r = Reconciler(ride);
    final flash = FakeFlash(ride.lossFloor6);
    ReconcilerState state = const Synced();
    const tick = 50000;
    const mark = 100000000000; // $100, stable
    final target = (ride.maxNotionalAbs6 * 0.6).round(); // stable $3000 long

    var i = 0;
    // Run long enough for the multi-step convergence (capped per action) + debounce + fills.
    for (; i < 200; i++) {
      final input = ReconcileInput(
        virtualNotionalUsd6: target,
        settled: flash.pos,
        erMarkE9: mark,
        guardMarkE9: mark,
        session: MarketSession.regular,
        nowMicros: i * tick,
      );
      final res = r.step(state, input);
      state = res.state;
      flash.apply(res.action, mark);
    }
    expect(
      (flash.pos.signedUsd6 - target).abs() <= band,
      isTrue,
      reason: 'did not converge: settled ${flash.pos.signedUsd6} vs target $target (band $band)',
    );
  });

  test('INVARIANT: no double-open across a crash-after-submit-before-fill', () {
    final r = Reconciler(ride);
    const mark = 100000000000;
    ReconcileInput at(int now, FlashPosition settled) => ReconcileInput(
      virtualNotionalUsd6: usd(1000),
      settled: settled,
      erMarkE9: mark,
      guardMarkE9: mark,
      session: MarketSession.regular,
      nowMicros: now,
    );
    // Reach Settling (an open was emitted) but the fill has NOT reflected.
    final s1 = r.step(const Synced(), at(0, const FlashPosition.flat()));
    final s2 = r.step(s1.state, at(cfg.debounceMicros, const FlashPosition.flat()));
    expect(s2.action, isA<OpenIncrease>());
    expect(s2.state, isA<Settling>());

    // "Crash": a brand-new Reconciler resumes from the persisted Settling state with the OLD (flat)
    // settled view (fill still in flight). It must NOT open a second position.
    final resumed = Reconciler(ride);
    final r3 = resumed.step(s2.state, at(cfg.debounceMicros + 1000, const FlashPosition.flat()));
    expect(
      r3.action,
      isA<NoOp>(),
      reason: 'resume must not re-open before reconciling the in-flight fill',
    );
  });

  test('INVARIANT: a keeper stop fire keeps realized loss within the promised worst-case bound', () {
    final r = Reconciler(ride);
    final flash = FakeFlash(ride.lossFloor6);
    ReconcilerState state = const Synced();
    const tick = 50000;

    // Open a steady long, let it settle, then crash the price straight down through the stop.
    var pxNow = px(100);
    for (var i = 0; i < 80; i++) {
      // first 40 steps: hold price; last 40: crash down 1.5%/step.
      if (i >= 40) pxNow = max(1, (pxNow * 0.985).round());
      flash.keeperTick(pxNow);
      final input = ReconcileInput(
        virtualNotionalUsd6: (ride.maxNotionalAbs6 * 0.8).round(), // strong long
        settled: flash.pos,
        erMarkE9: pxNow,
        guardMarkE9: pxNow,
        session: MarketSession.regular,
        nowMicros: i * tick,
      );
      final res = r.step(state, input);
      state = res.state;
      flash.apply(res.action, pxNow);
    }

    // Worst-case promise = floor + slippage + keeper-hold drift + band gap. Model generous allowances.
    final bound = worstCaseLossBound6(
      lossFloor6: ride.lossFloor6,
      slippageUsd6: usd(40),
      keeperHoldDriftUsd6: usd(120),
      bandGapUsd6: band,
    ).abs();
    expect(flash.realizedLoss6 > 0, isTrue, reason: 'the stop should have fired on the crash');
    expect(
      flash.realizedLoss6 <= bound,
      isTrue,
      reason: 'realized loss ${flash.realizedLoss6} exceeded promised bound $bound',
    );
  });
}
