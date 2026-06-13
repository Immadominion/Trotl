/// The I/O boundary the executor depends on. Two implementations exist: SimGateway (deterministic,
/// in-memory — the CI harness) and the production adapter built on `flash_client` (live, manual). The
/// executor is written against these interfaces only, so the simulation runs the SAME executor code
/// path that production does — no test-only fork (ARCHITECTURE §3.3).
library;

import 'package:meta/meta.dart';
import 'package:throtl_chain/throtl_chain.dart';
import 'package:throtl_core/throtl_core.dart';

/// One reconciliation observation: a decoded ER `RideSession` snapshot plus the venue/market context
/// the reconciler needs that does not come from the (trusted) settled position or the clock.
@immutable
class RideObservation {
  const RideObservation({
    required this.ride,
    required this.session,
    required this.guardMarkE9,
    required this.nowMicros,
    this.linkOk = true,
  });

  /// The decoded ER account — its `notionalUsd6` is the advisory virtual target, `lastMarkE9` the
  /// in-ER mark, and `flags.isOracleStale` the honest needle-freeze signal.
  final RideSessionAccount ride;

  /// Market session for the symbol (from Flash `marketSession`). Thumb input is hard-gated on this.
  final MarketSession session;

  /// Independent (Hermes/L1) mark for the ER-vs-truth divergence cross-check. Non-positive ⇒ no
  /// independent price ⇒ the reconciler refuses to settle (treated as divergence).
  final int guardMarkE9;

  /// Monotonic clock in microseconds (debounce / settling timing).
  final int nowMicros;

  /// Whether the ER link is alive (a stalled subscription ⇒ degraded, no settlement).
  final bool linkOk;
}

/// The trusted settled-position boundary. `settled` MUST reflect the real Flash position (read from
/// the owner WS / last confirmed fill) — never the ER's advisory virtual state. [apply] executes a
/// single bounded reconciler action, attaching the floor-derived stop inline wherever the action
/// leaves a position open (the open-without-stop invariant, ARCHITECTURE §3.3 flip safety).
abstract interface class FlashGateway {
  /// The current trusted settled position.
  FlashPosition get settled;

  /// Execute [action] (never [NoOp]). [markE9] is the current mark used to derive entry + the stop
  /// trigger; [ride] supplies fuel/leverage/floor for collateral and stop math. Completes when the
  /// resulting state is reflected in [settled] (or, for the live adapter, when the fill confirms).
  Future<void> apply(
    ReconcilerAction action, {
    required RideConfig ride,
    required int markE9,
    required int nowMicros,
  });
}
