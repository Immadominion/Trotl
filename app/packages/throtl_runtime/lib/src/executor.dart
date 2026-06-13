/// The ride executor. Per ER observation it builds a [ReconcileInput] from the trusted settled
/// position (the gateway) + the advisory ER snapshot + the independent guard mark, runs one pure
/// [Reconciler.step], advances its state, and — for any non-[NoOp] action — executes it through the
/// [FlashGateway]. This is the only place the FSM meets I/O; it adds nothing the FSM doesn't sanction.
library;

import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_runtime/src/ports.dart';

/// Orchestrates one ride. Single-threaded by design (the web has no isolates): callers must not
/// invoke [onObservation] re-entrantly — await each call before the next (the executor asserts this).
class RideExecutor {
  RideExecutor({
    required this.ride,
    required this.gateway,
    ReconcileConfig? config,
    ReconcilerState initial = const Synced(),
  }) : _reconciler = Reconciler(ride, config ?? const ReconcileConfig()),
       _state = initial;

  final RideConfig ride;
  final FlashGateway gateway;
  final Reconciler _reconciler;

  ReconcilerState _state;
  bool _busy = false;

  /// Current FSM state (after the last completed observation).
  ReconcilerState get state => _state;

  /// Feed one observation. Returns the action the reconciler emitted (already executed if non-[NoOp]).
  /// The trusted [FlashGateway.settled] is read at decision time and again is what the next step sees.
  Future<ReconcilerAction> onObservation(RideObservation obs) async {
    assert(!_busy, 'onObservation is not re-entrant — await each call');
    _busy = true;
    try {
      final input = ReconcileInput(
        virtualNotionalUsd6: obs.ride.notionalUsd6,
        settled: gateway.settled,
        erMarkE9: obs.ride.lastMarkE9,
        guardMarkE9: obs.guardMarkE9,
        session: obs.session,
        nowMicros: obs.nowMicros,
        linkOk: obs.linkOk,
        oracleStale: obs.ride.flags.isOracleStale,
      );
      final result = _reconciler.step(_state, input);
      _state = result.state;
      final action = result.action;
      if (action is! NoOp) {
        await gateway.apply(
          action,
          ride: ride,
          markE9: obs.ride.lastMarkE9,
          nowMicros: obs.nowMicros,
        );
      }
      return action;
    } finally {
      _busy = false;
    }
  }
}
