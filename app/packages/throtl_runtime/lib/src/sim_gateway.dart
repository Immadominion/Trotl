/// A deterministic, in-memory [FlashGateway] for the executor harness. It applies each reconciler
/// action to a simulated [FlashPosition] exactly as the live venue would in the happy path — and,
/// critically, attaches the floor-derived stop inline on every action that leaves a position open, so
/// the open-without-stop invariant is observable in tests. It can defer fills (to exercise the FSM's
/// settling gate) and inject a stop-out (to exercise the freeze-after-stop-out path). No randomness.
library;

import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_runtime/src/ports.dart';

/// A recorded action with the position it produced (for assertions on the executor's behavior).
class AppliedAction {
  AppliedAction(this.action, this.resulting);
  final ReconcilerAction action;
  final FlashPosition resulting;
}

class SimGateway implements FlashGateway {
  SimGateway({FlashPosition initial = const FlashPosition.flat()}) : _pos = initial;

  FlashPosition _pos;
  FlashPosition? _pendingFill;

  /// When true, the next [apply] computes the resulting position but does NOT reflect it in [settled]
  /// until [completePendingFill] is called — modeling fill latency the settling gate must wait out.
  bool deferNextFill = false;

  final List<AppliedAction> applied = [];

  @override
  FlashPosition get settled => _pos;

  /// Materialize a deferred fill into [settled] (no-op if none pending).
  void completePendingFill() {
    if (_pendingFill != null) {
      _pos = _pendingFill!;
      _pendingFill = null;
    }
  }

  /// Simulate the venue stop firing (or an external close): the position vanishes to flat. The
  /// executor must treat this as a stop-out and refuse to re-open while the thumb still wants size.
  void injectStopOut() {
    _pos = const FlashPosition.flat();
    _pendingFill = null;
  }

  @override
  Future<void> apply(
    ReconcilerAction action, {
    required RideConfig ride,
    required int markE9,
    required int nowMicros,
  }) async {
    final next = _resultOf(action, ride, markE9);
    applied.add(AppliedAction(action, next));
    if (deferNextFill) {
      _pendingFill = next;
      deferNextFill = false;
    } else {
      _pos = next;
    }
  }

  FlashPosition _resultOf(ReconcilerAction action, RideConfig ride, int markE9) {
    int? stopFor(Side side, int entryE9, int sizeUsd6) => stopTriggerE9(
      side: side,
      entryE9: entryE9,
      sizeUsd6: sizeUsd6,
      lossFloor6: ride.lossFloor6,
    );

    switch (action) {
      case OpenIncrease(:final side, :final addUsd6):
        if (_pos.isFlat) {
          return FlashPosition(
            side: side,
            sizeUsd6: addUsd6,
            entryE9: markE9,
            stopTriggerE9: stopFor(side, markE9, addUsd6),
          );
        }
        final newSize = _pos.sizeUsd6 + addUsd6;
        // Size-weighted blended entry (BigInt to stay exact on web).
        final blended =
            (BigInt.from(_pos.entryE9) * BigInt.from(_pos.sizeUsd6) +
                BigInt.from(markE9) * BigInt.from(addUsd6)) ~/
            BigInt.from(newSize);
        final entry = blended.toInt();
        return FlashPosition(
          side: side,
          sizeUsd6: newSize,
          entryE9: entry,
          stopTriggerE9: stopFor(side, entry, newSize),
        );
      case ReducePartial(:final side, :final reduceUsd6):
        final newSize = _pos.sizeUsd6 - reduceUsd6;
        if (newSize <= 0) return const FlashPosition.flat();
        return FlashPosition(
          side: side,
          sizeUsd6: newSize,
          entryE9: _pos.entryE9,
          stopTriggerE9: stopFor(side, _pos.entryE9, newSize),
        );
      case FullClose():
        return const FlashPosition.flat();
      case Flip(:final toSide, :final openUsd6):
        // Close the old side and open the opposite WITH the stop in the same logical step.
        return FlashPosition(
          side: toSide,
          sizeUsd6: openUsd6,
          entryE9: markE9,
          stopTriggerE9: stopFor(toSide, markE9, openUsd6),
        );
      case ReplaceStop(:final side):
        return FlashPosition(
          side: side,
          sizeUsd6: _pos.sizeUsd6,
          entryE9: _pos.entryE9,
          stopTriggerE9: stopFor(side, _pos.entryE9, _pos.sizeUsd6),
        );
      case NoOp():
        return _pos;
    }
  }
}
