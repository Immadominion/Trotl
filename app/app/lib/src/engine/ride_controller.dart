import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:throtl/src/audio/sfx.dart';
import 'package:throtl/src/engine/price_feed.dart';
import 'package:throtl_chain/throtl_chain.dart';
import 'package:throtl_core/throtl_core.dart';
import 'package:throtl_runtime/throtl_runtime.dart';

/// One row in the lap ticker — a streamed ER tick or a settlement.
@immutable
class TickRow {
  const TickRow.tick({
    required this.n,
    required this.sig,
    required this.lev,
    required this.ms,
  }) : settle = false,
       pnl6 = 0,
       panic = false;

  const TickRow.settle({
    required this.sig,
    required this.pnl6,
    required this.panic,
  }) : settle = true,
       n = 0,
       lev = 0,
       ms = 0;

  final int n;
  final String sig;
  final double lev;
  final int ms;
  final bool settle;
  final int pnl6;
  final bool panic;
}

/// Immutable per-tick view of the ride, rendered by the cockpit.
@immutable
class RideSnapshot {
  const RideSnapshot({
    required this.throttle,
    required this.markE9,
    required this.position,
    required this.fsm,
    required this.openPnl6,
    required this.realizedPnl6,
    required this.equity6,
    required this.floorBreached,
    required this.ticks,
    required this.xp,
    required this.streak,
    required this.bestStreak,
    required this.peakLev,
    required this.panicActive,
    required this.maxLevBps,
    required this.feed,
  });

  final double throttle; // -1..1
  final int markE9;
  final FlashPosition position;
  final ReconcilerState fsm;
  final int openPnl6;
  final int realizedPnl6;
  final int equity6;
  final bool floorBreached;
  final int ticks;
  final double xp;
  final int streak;
  final int bestStreak;
  final double peakLev;
  final bool panicActive;
  final int maxLevBps;
  final List<TickRow> feed;

  int get totalPnl6 => openPnl6 + realizedPnl6;
  Side get side => position.side;

  /// Signed leverage currently expressed (e.g. +3.4x / −2.0x).
  double get levDisplay => throttle * (maxLevBps / bpsScale);
  int get level => (xp / 400).floor() + 1;
  double get levelFrac => (xp % 400) / 400;
}

/// Final tallies for the Results + Share receipt.
@immutable
class SessionStats {
  const SessionStats({
    required this.realized6,
    required this.ticks,
    required this.bestStreak,
    required this.peakLev,
    required this.winRate,
  });

  final int realized6;
  final int ticks;
  final int bestStreak;
  final double peakLev;
  final int winRate;
}

/// Where a ride's settle/teardown is, surfaced to the Results screen. A live ride
/// walks `flattening → committing → undelegating → closing → settled`; a practice
/// ride has no chain teardown so it reports [done] immediately (the sim Flash
/// position closed during the ride).
enum SettlePhase {
  none, // still riding (no teardown yet)
  flattening, // draining the virtual position to flat on the ER
  committing, // request_settle: commit final ER state to L1 + undelegate
  undelegating, // waiting for the delegation program to return the PDA to L1
  closing, // close_ride: owner confirms in the wallet, rent → owner
  settled, // fully closed on-chain, rent reclaimed
  done, // money settled; rent not reclaimed (close skipped/declined) — non-fatal
  failed, // settle could not complete
}

extension SettlePhaseX on SettlePhase {
  bool get isBusy =>
      this == SettlePhase.flattening ||
      this == SettlePhase.committing ||
      this == SettlePhase.undelegating ||
      this == SettlePhase.closing;
  bool get isOk => this == SettlePhase.settled || this == SettlePhase.done;

  String get label => switch (this) {
    SettlePhase.none => 'Settling…',
    SettlePhase.flattening => 'Closing position…',
    SettlePhase.committing => 'Committing to Solana L1…',
    SettlePhase.undelegating => 'Returning from the rollup…',
    SettlePhase.closing => 'Confirm settle in your wallet…',
    SettlePhase.settled => 'SETTLED ON-CHAIN · RENT RECLAIMED',
    SettlePhase.done => 'SETTLED ON FLASH · SELF-CUSTODIAL',
    SettlePhase.failed => 'SETTLE INCOMPLETE',
  };
}

/// The interface the cockpit binds to — implemented by both [RideController]
/// (practice: local engine + synthetic price) and `LiveRideController`
/// (a real on-chain devnet/mainnet ride). The race screen, hill scene and
/// throttle rail depend only on this, so they're identical either way.
abstract interface class RideEngine implements Listenable {
  RideSnapshot get snapshot;
  PriceFeed get feed;
  void setThrottle(double value);
  void release();
  void spinOut();
  void start();
  void stop();
  SessionStats finish();

  /// Live settle state for the Results screen. Practice rides report [SettlePhase.done].
  SettlePhase get settlePhase;

  /// A human note for the current settle phase (errors / next steps), or null.
  String? get settleNote;

  /// A real on-chain signature to surface once a step lands (e.g. the close tx), or null.
  String? get settleSig;

  void dispose();
}

/// Drives a practice ride against the REAL engine: each tick it builds a
/// [RideObservation] from the live mark + the throttle target, runs the real
/// [RideExecutor] (reconciler FSM + [SimGateway] with the floor-derived stop),
/// and recomputes PnL via the engine's [unrealizedPnl6]. No fake sim of the
/// trade — only the price + the venue fills are simulated.
class RideController extends ChangeNotifier implements RideEngine {
  RideController({
    required this.feed,
    required this.config,
    ReconcileConfig? reconcile,
  }) {
    _gateway = SimGateway();
    _executor = RideExecutor(
      ride: config,
      gateway: _gateway,
      config: reconcile ?? ReconcileConfig(bandBps: config.bandBps),
    );
  }

  @override
  final PriceFeed feed;
  final RideConfig config;

  late final SimGateway _gateway;
  late final RideExecutor _executor;
  final math.Random _rng = math.Random();
  final Stopwatch _clock = Stopwatch();

  bool _running = false;
  bool _busy = false;

  double _throttle = 0;
  bool _coasting = false;
  double _coastFrom = 0;
  int _coastStartMs = 0;
  int _panicAtMs = -10000;

  int _realized6 = 0;
  int _openPnl6 = 0;
  int _ticks = 0;
  double _xp = 0;
  int _streak = 0;
  int _bestStreak = 0;
  int _trades = 0;
  int _wins = 0;
  double _peakLev = 0;
  final List<TickRow> _feed = [];

  static const _b58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  bool get panicActive => _panicAtMs > 0 && _clock.elapsedMilliseconds - _panicAtMs < 900;

  @override
  RideSnapshot get snapshot => RideSnapshot(
    throttle: _throttle,
    markE9: feed.priceE9,
    position: _gateway.settled,
    fsm: _executor.state,
    openPnl6: _openPnl6,
    realizedPnl6: _realized6,
    equity6: effectiveEquity6(config.fuelUsd6, _realized6, _openPnl6),
    floorBreached: effectiveEquity6(config.fuelUsd6, _realized6, _openPnl6) <= config.lossFloor6,
    ticks: _ticks,
    xp: _xp,
    streak: _streak,
    bestStreak: _bestStreak,
    peakLev: _peakLev,
    panicActive: panicActive,
    maxLevBps: config.maxLevBps,
    feed: List.unmodifiable(_feed),
  );

  @override
  void start() {
    if (_running) return;
    _running = true;
    _clock.start();
    feed.start();
    unawaited(_loop());
  }

  @override
  void stop() {
    _running = false;
  }

  /// Drag input from the throttle rail (cancels any coast). Notifies so the
  /// whole gauge tree (leverage, PnL, combo) tracks the finger live, not just
  /// on the 90ms engine step.
  @override
  void setThrottle(double value) {
    _coasting = false;
    _throttle = value.clamp(-1.0, 1.0);
    notifyListeners();
  }

  /// Release → coast smoothly to flat (the reconciler closes over a few ticks).
  @override
  void release() {
    _coasting = true;
    _coastFrom = _throttle;
    _coastStartMs = _clock.elapsedMilliseconds;
  }

  /// Panic flick → eject: snap target to flat now, latch the spin-out stamp.
  @override
  void spinOut() {
    _throttle = 0;
    _coasting = false;
    _panicAtMs = _clock.elapsedMilliseconds;
    sfx
      ..skid()
      ..eject();
  }

  @override
  SessionStats finish() {
    stop();
    return SessionStats(
      realized6: _realized6,
      ticks: _ticks,
      bestStreak: _bestStreak,
      peakLev: _peakLev,
      winRate: _trades > 0 ? (100 * _wins / _trades).round() : 0,
    );
  }

  // Practice has no chain teardown — the sim Flash position closed during the ride.
  @override
  SettlePhase get settlePhase => SettlePhase.done;
  @override
  String? get settleNote => null;
  @override
  String? get settleSig => null;

  Future<void> _loop() async {
    while (_running) {
      await _step();
      await Future<void>.delayed(const Duration(milliseconds: 90));
    }
  }

  Future<void> _step() async {
    if (_busy || !_running) return;
    _busy = true;
    try {
      if (_coasting) {
        final dt = _clock.elapsedMilliseconds - _coastStartMs;
        final k = (dt / 500).clamp(0.0, 1.0);
        _throttle = _coastFrom * (1 - k);
        if (k >= 1) {
          _throttle = 0;
          _coasting = false;
        }
      }

      final mark = feed.priceE9;
      final t = _throttle.abs() < 0.05 ? 0.0 : _throttle;
      final target6 = (config.maxNotionalAbs6 * t).round();

      final before = _gateway.settled;
      await _executor.onObservation(
        RideObservation(
          ride: _observationAccount(target6, mark),
          session: MarketSession.regular,
          guardMarkE9: mark,
          nowMicros: _clock.elapsedMicroseconds,
        ),
      );
      final after = _gateway.settled;

      final realizedDelta = _realizedBetween(before, after, mark);
      if (realizedDelta != 0) {
        _realized6 += realizedDelta;
        _trades++;
        if (realizedDelta > 5000) {
          _wins++;
          _streak++;
          _bestStreak = math.max(_bestStreak, _streak);
        } else if (realizedDelta < -5000) {
          _streak = 0;
        }
        _feed.insert(
          0,
          TickRow.settle(sig: _sig(), pnl6: realizedDelta, panic: panicActive),
        );
      }

      _openPnl6 = unrealizedPnl6(after.signedUsd6, after.entryE9, mark);

      if (t != 0 || !after.isFlat) {
        _ticks++;
        _xp += 1 + t.abs() * 2;
        final levMag = t.abs() * (config.maxLevBps / bpsScale);
        _peakLev = math.max(_peakLev, levMag);
        _feed.insert(
          0,
          TickRow.tick(
            n: _ticks,
            sig: _sig(),
            lev: t * (config.maxLevBps / bpsScale),
            ms: 28 + _rng.nextInt(22),
          ),
        );
      }
      if (_feed.length > 24) {
        _feed.removeRange(24, _feed.length);
      }

      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  int _realizedBetween(FlashPosition before, FlashPosition after, int mark) {
    if (before.isFlat) return 0;
    int closedAbs;
    if (after.isFlat || after.side != before.side) {
      closedAbs = before.sizeUsd6;
    } else if (after.sizeUsd6 < before.sizeUsd6) {
      closedAbs = before.sizeUsd6 - after.sizeUsd6;
    } else {
      return 0;
    }
    if (closedAbs <= 0) return 0;
    return unrealizedPnl6(before.side.sign * closedAbs, before.entryE9, mark);
  }

  /// Build the advisory ER snapshot the executor reads (only `notionalUsd6`,
  /// `lastMarkE9`, and `flags.isOracleStale` matter to the reconciler).
  RideSessionAccount _observationAccount(int target6, int markE9) {
    final zero = List<int>.filled(32, 0);
    return RideSessionAccount(
      sessionId: 0,
      expiresAt: 0,
      fuelUsd6: config.fuelUsd6,
      notionalUsd6: target6,
      entryVwapE9: 0,
      realizedPnl6: _realized6,
      lastMarkE9: markE9,
      lastMarkTs: _clock.elapsedMicroseconds,
      lossFloor6: config.lossFloor6,
      tickCount: _ticks,
      maxLevBps: config.maxLevBps,
      targetExpBps: 0,
      virtExpBps: 0,
      flags: const RideFlags(0),
      marketId: config.marketId,
      version: 1,
      bump: 0,
      status: RideStatus.riding,
      gripMode: 0,
      owner: zero,
      sessionKey: zero,
      feedId: zero,
    );
  }

  String _sig() => '${_chunk(4)}…${_chunk(4)}';

  String _chunk(int n) => String.fromCharCodes(
    List.generate(n, (_) => _b58.codeUnitAt(_rng.nextInt(_b58.length))),
  );

  @override
  void dispose() {
    _running = false;
    super.dispose();
  }
}
