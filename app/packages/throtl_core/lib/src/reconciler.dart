/// The reconciler — translates advisory virtual exposure (from our ER) into real Flash position
/// changes, bounded so the operator-trusted-only-for-feel ER can never directly authorize a trade.
///
/// Pure and resumable: [Reconciler.step] takes the previous state + a fresh observation and returns
/// the next state and at most one action. No I/O, no timers — the caller supplies `nowMicros` and
/// executes the returned action (rate-limited) and the venue stop. This is what the simulation
/// harness drives and what production runs verbatim (no test-only fork). See ARCHITECTURE §3.3.
library;

import 'package:meta/meta.dart';
import 'package:throtl_core/src/accounting.dart';
import 'package:throtl_core/src/guardian.dart';
import 'package:throtl_core/src/models.dart';

/// Why the reconciler is not settling right now.
enum DegradeReason { linkLost, oracleStale, priceDivergence, marketClosed }

@immutable
sealed class ReconcilerState {
  const ReconcilerState();
}

/// Settled position is within band of the (clamped) virtual target; nothing to do.
/// Carries the signed notional it is synced to, so a sudden disappearance of the position (a venue
/// stop firing, or an external close) is detectable as a stop-out on the next step.
@immutable
class Synced extends ReconcilerState {
  const Synced([this.syncedSigned6 = 0]);
  final int syncedSigned6;
}

/// Entered after a venue stop fired (or the position vanished) while the thumb still wanted exposure.
/// The reconciler refuses to re-open into the adverse move — the user must release the throttle
/// (target → flat) to re-arm. Defense-in-depth: layer-3 of the guardian, independent of the on-chain
/// freeze that should already have zeroed the virtual target (ARCHITECTURE §3.4).
@immutable
class Frozen extends ReconcilerState {
  const Frozen();
}

/// Drift detected; waiting out the debounce before acting (thumb pass-through, not churn).
@immutable
class Drifting extends ReconcilerState {
  const Drifting(this.sinceMicros, this.targetSigned6);
  final int sinceMicros;
  final int targetSigned6;
}

/// An action was emitted; waiting for the fill to reflect (or time out) before acting again.
/// This is the FSM-level double-settle guard, complementary to the crash-resume signature check.
@immutable
class Settling extends ReconcilerState {
  const Settling(this.sinceMicros, this.expectedSettled6, this.priorSettled6);
  final int sinceMicros;
  final int expectedSettled6;

  /// Settled signed notional at the moment the action was emitted. Lets us tell a stop-out (a
  /// non-flat position that vanished) from a failed open (a position that was never established).
  final int priorSettled6;
}

/// A visible degraded mode; no real settlement happens here.
@immutable
class Degraded extends ReconcilerState {
  const Degraded(this.reason);
  final DegradeReason reason;
}

@immutable
sealed class ReconcilerAction {
  const ReconcilerAction();

  /// Whether executing this action leaves a non-flat position that MUST carry a floor-derived stop.
  bool get leavesPositionOpen => switch (this) {
    OpenIncrease() => true,
    ReducePartial() => true,
    Flip() => true,
    ReplaceStop() => true,
    FullClose() => false,
    NoOp() => false,
  };
}

class NoOp extends ReconcilerAction {
  const NoOp();
}

/// Open from flat, or increase the same side. Executor places/updates the floor stop after the fill.
@immutable
class OpenIncrease extends ReconcilerAction {
  const OpenIncrease(this.side, this.addUsd6);
  final Side side;
  final int addUsd6;
}

/// Partial close toward (but not to) flat. Executor re-derives the floor stop on the smaller size.
@immutable
class ReducePartial extends ReconcilerAction {
  const ReducePartial(this.side, this.reduceUsd6);
  final Side side;
  final int reduceUsd6;
}

/// Close to flat (full close). Executor cancels all stops.
@immutable
class FullClose extends ReconcilerAction {
  const FullClose(this.side);
  final Side side;
}

/// Sign flip: full-close the current side, then open the opposite side **with an inline stop in the
/// same builder call** — never an open position without a stop (ARCHITECTURE §3.3 flip safety).
@immutable
class Flip extends ReconcilerAction {
  const Flip(this.toSide, this.openUsd6);
  final Side toSide;
  final int openUsd6;
}

/// No size change, but the existing position's stop is missing or no longer matches the floor on the
/// current size — re-place it.
@immutable
class ReplaceStop extends ReconcilerAction {
  const ReplaceStop(this.side);
  final Side side;
}

@immutable
class ReconcileResult {
  const ReconcileResult(this.state, this.action);
  final ReconcilerState state;
  final ReconcilerAction action;
}

/// A fresh observation fed to the reconciler each step.
@immutable
class ReconcileInput {
  const ReconcileInput({
    required this.virtualNotionalUsd6,
    required this.settled,
    required this.erMarkE9,
    required this.guardMarkE9,
    required this.session,
    required this.nowMicros,
    this.linkOk = true,
    this.oracleStale = false,
  });

  /// Advisory signed notional echoed from our ER (NOT an authorization — see clamps below).
  final int virtualNotionalUsd6;
  final FlashPosition settled;
  final int erMarkE9;

  /// Independent (Hermes/L1) price for the divergence cross-check.
  final int guardMarkE9;
  final MarketSession session;
  final int nowMicros;
  final bool linkOk;
  final bool oracleStale;
}

/// Tuning thresholds. Defaults from ARCHITECTURE §3.3.
@immutable
class ReconcileConfig {
  const ReconcileConfig({
    this.debounceMicros = 400000, // 400ms — thumb pass-through, not churn
    this.bandBps = 250, // 2.5% of fuel×lev hysteresis band
    this.bandFloorUsd6 = 12000000, // $12 — > Flash $11 min, the snap-to-flat dead-zone
    this.fullCloseRemainingBps = 300, // a reduce leaving <3% becomes a full close (97% rule)
    this.priceDivergenceBps = 100, // 1% ER-vs-Hermes divergence ⇒ refuse to settle
    this.maxActionDeltaBps = 5000, // a single action moves at most 50% of fuel×lev
    this.settleTimeoutMicros = 3000000, // 3s to see a fill before re-acting
    this.stopToleranceBps = 100, // re-place the stop if it drifts >1% from the floor-derived price
  });

  final int debounceMicros;
  final int bandBps;
  final int bandFloorUsd6;
  final int fullCloseRemainingBps;
  final int priceDivergenceBps;
  final int maxActionDeltaBps;
  final int settleTimeoutMicros;
  final int stopToleranceBps;
}

class Reconciler {
  Reconciler(this.ride, [this.cfg = const ReconcileConfig()]);

  final RideConfig ride;
  final ReconcileConfig cfg;

  /// Hysteresis band in usd6 = max(bandBps × fuel×lev, bandFloor).
  int get band6 {
    final pct =
        (BigInt.from(ride.maxNotionalAbs6) * BigInt.from(cfg.bandBps) ~/ BigInt.from(bpsScale))
            .toInt();
    return pct > cfg.bandFloorUsd6 ? pct : cfg.bandFloorUsd6;
  }

  int get _maxActionDelta6 =>
      (BigInt.from(ride.maxNotionalAbs6) *
              BigInt.from(cfg.maxActionDeltaBps) ~/
              BigInt.from(bpsScale))
          .toInt();

  int _capDelta(int x) => x > _maxActionDelta6 ? _maxActionDelta6 : x;

  /// Clamp advisory virtual notional to the hard local cap (±fuel×lev) — the operator cannot push
  /// us past this no matter what the ER reports.
  int _clampTarget(int virtual6) {
    final cap = ride.maxNotionalAbs6;
    if (virtual6 > cap) return cap;
    if (virtual6 < -cap) return -cap;
    return virtual6;
  }

  bool _priceDiverged(int erMarkE9, int guardMarkE9) {
    if (guardMarkE9 <= 0) return true; // no independent price ⇒ do not trust the ER
    final diff = (erMarkE9 - guardMarkE9).abs();
    final ratioBps = BigInt.from(diff) * BigInt.from(bpsScale) ~/ BigInt.from(guardMarkE9);
    return ratioBps > BigInt.from(cfg.priceDivergenceBps);
  }

  bool _stopNeedsReplace(FlashPosition pos) {
    if (pos.isFlat) return false;
    final expected = stopTriggerE9(
      side: pos.side,
      entryE9: pos.entryE9,
      sizeUsd6: pos.sizeUsd6,
      lossFloor6: ride.lossFloor6,
    );
    if (expected == null) return false;
    if (pos.stopTriggerE9 == null) return true;
    final tol = BigInt.from(expected) * BigInt.from(cfg.stopToleranceBps) ~/ BigInt.from(bpsScale);
    return BigInt.from(pos.stopTriggerE9! - expected).abs() > tol;
  }

  /// The desired action ignoring debounce/settling timing.
  ReconcilerAction _decide(int target6, FlashPosition pos) {
    final settled6 = pos.signedUsd6;

    // Flat target → full close any open position (never tolerate a residual; the snap-to-flat
    // dead-zone already mapped tiny virtual targets to 0).
    if (target6 == 0) {
      return pos.isFlat ? const NoOp() : FullClose(pos.side);
    }
    final tSide = Side.ofSigned(target6);

    // Open from flat.
    if (pos.isFlat) {
      return OpenIncrease(tSide, _capDelta(target6.abs()));
    }

    // Sign flip → close-then-open-with-inline-stop (one logical action).
    if (tSide != pos.side) {
      return Flip(tSide, _capDelta(target6.abs()));
    }

    // Same side: act only outside the band (the open/close transitions above ignore the band).
    final diff = target6.abs() - settled6.abs(); // + increase, − reduce
    if (diff.abs() <= band6) {
      return _stopNeedsReplace(pos) ? ReplaceStop(pos.side) : const NoOp();
    }
    if (diff > 0) {
      return OpenIncrease(pos.side, _capDelta(diff));
    }
    final reduce = -diff;
    final remaining = settled6.abs() - reduce;
    final remThreshold = _maxInt(
      cfg.bandFloorUsd6,
      (BigInt.from(settled6.abs()) *
              BigInt.from(cfg.fullCloseRemainingBps) ~/
              BigInt.from(bpsScale))
          .toInt(),
    );
    // 97% rule: a reduce that would leave a dust position becomes a full close.
    if (remaining < remThreshold) {
      return FullClose(pos.side);
    }
    return ReducePartial(pos.side, _capDelta(reduce));
  }

  int _expectedSettledAfter(ReconcilerAction action, int settled6, int target6) => switch (action) {
    OpenIncrease(:final side, :final addUsd6) => settled6 + side.sign * addUsd6,
    ReducePartial(:final side, :final reduceUsd6) => settled6 - side.sign * reduceUsd6,
    Flip(:final toSide, :final openUsd6) => toSide.sign * openUsd6,
    FullClose() => 0,
    ReplaceStop() => settled6,
    NoOp() => settled6,
  };

  bool _reached(int settled6, int expected6) => (settled6 - expected6).abs() <= band6;

  bool _sameBucket(int a6, int b6) =>
      Side.ofSigned(a6) == Side.ofSigned(b6) && (a6 - b6).abs() <= band6;

  /// One reconciliation step. Returns the next state and at most one action.
  ReconcileResult step(ReconcilerState prev, ReconcileInput input) {
    // ── hard gates (no settlement in any degraded mode) ──────────────────────
    if (!input.linkOk) return const ReconcileResult(Degraded(DegradeReason.linkLost), NoOp());
    if (input.session == MarketSession.closed) {
      return const ReconcileResult(Degraded(DegradeReason.marketClosed), NoOp());
    }
    if (input.oracleStale) {
      return const ReconcileResult(Degraded(DegradeReason.oracleStale), NoOp());
    }
    if (_priceDiverged(input.erMarkE9, input.guardMarkE9)) {
      return const ReconcileResult(Degraded(DegradeReason.priceDivergence), NoOp());
    }

    // ── advisory target → clamped → snap-to-flat ──────────────────────────────
    var target6 = _clampTarget(input.virtualNotionalUsd6);
    if (target6.abs() < cfg.bandFloorUsd6) target6 = 0;

    final settled6 = input.settled.signedUsd6;

    // ── Frozen: refuse to re-open after a stop-out until the user releases the throttle ──────────
    if (prev is Frozen) {
      if (!input.settled.isFlat) {
        return ReconcileResult(const Frozen(), FullClose(input.settled.side));
      }
      return target6 == 0
          ? const ReconcileResult(Synced(), NoOp()) // released → re-armed
          : const ReconcileResult(Frozen(), NoOp()); // still pinned → stay flat
    }

    // Stop-out / external-close detection: a position that was ESTABLISHED is now gone while the
    // thumb still wants exposure → do NOT re-open into the move (the cause of stacked stop-out
    // losses). Distinguished from a failed open (never established) via priorSettled6 / syncedSigned6.
    final establishedBefore =
        (prev is Synced && prev.syncedSigned6 != 0) ||
        (prev is Settling && prev.priorSettled6 != 0);
    if (input.settled.isFlat && target6 != 0 && establishedBefore) {
      return const ReconcileResult(Frozen(), NoOp());
    }

    final desired = _decide(target6, input.settled);

    // Stop maintenance and no-ops settle the state immediately (no debounce — a missing stop is a
    // safety gap to close promptly; a no-op means we're synced).
    if (desired is NoOp) return ReconcileResult(Synced(settled6), const NoOp());
    if (desired is ReplaceStop) return ReconcileResult(Synced(settled6), desired);

    // ── Settling gate: don't re-act until the prior fill reflects or times out ──
    var readyToAct = false;
    if (prev is Settling) {
      final timedOut = input.nowMicros - prev.sinceMicros >= cfg.settleTimeoutMicros;
      final reached = _reached(settled6, prev.expectedSettled6);
      if (!reached && !timedOut) {
        return ReconcileResult(prev, const NoOp()); // keep waiting for the fill
      }
      // Fill landed (keep converging toward target) or timed out (retry): act promptly — the drift
      // already cleared the debounce once, so we don't re-debounce mid-convergence.
      readyToAct = true;
    }

    // ── debounce (only for fresh drift from Synced/Drifting) ─────────────────────
    if (!readyToAct) {
      final since = prev is Drifting && _sameBucket(prev.targetSigned6, target6)
          ? prev.sinceMicros
          : input.nowMicros;
      if (input.nowMicros - since < cfg.debounceMicros) {
        return ReconcileResult(Drifting(since, target6), const NoOp());
      }
    }

    final expected = _expectedSettledAfter(desired, settled6, target6);
    return ReconcileResult(Settling(input.nowMicros, expected, settled6), desired);
  }
}

int _maxInt(int a, int b) => a > b ? a : b;
