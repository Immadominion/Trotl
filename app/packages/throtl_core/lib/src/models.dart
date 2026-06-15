/// Domain models shared by the tick / reconciler / guardian state machines.
/// All amounts use the fixed-point conventions of `accounting.dart` (usd6 / priceE9 / bps).
library;

import 'package:meta/meta.dart';
import 'package:throtl_core/src/accounting.dart';

/// Position side. Sign convention: long = +, short = −, flat = 0.
enum Side {
  long,
  short,
  flat;

  int get sign => switch (this) {
    Side.long => 1,
    Side.short => -1,
    Side.flat => 0,
  };

  static Side ofSigned(int signed) => signed > 0
      ? Side.long
      : signed < 0
      ? Side.short
      : Side.flat;
}

enum GripMode { hold, cruise }

/// Mirrors Flash's `marketSession`. The thumb input is hard-gated on this per-symbol.
enum MarketSession { regular, preMarket, postMarket, overNight, closed }

/// Whether the in-ER mark and the independent (Hermes/L1) mark agree closely enough to trust the
/// ER state for a real settlement (the ER-advisory bound, ARCHITECTURE §3.3 / R2).
enum PriceTrust { ok, diverged }

/// Immutable per-ride configuration (set at ride start, mirrors the on-chain `RideSession`).
@immutable
class RideConfig {
  const RideConfig({
    required this.fuelUsd6,
    required this.maxLevBps,
    required this.lossFloor6,
    required this.marketId,
    this.gripMode = GripMode.hold,
    this.bandBps = 250,
  }) : assert(fuelUsd6 > 0, 'fuel must be positive'),
       assert(maxLevBps >= 10000 && maxLevBps <= 100000, 'lev in [1x,10x]'),
       assert(lossFloor6 < 0, 'floor must be a negative bound');

  final int fuelUsd6;
  final int maxLevBps;
  final int lossFloor6;
  final int marketId;
  final GripMode gripMode;

  /// Reconciler hysteresis band (bps of fuel×lev) — how far the settled position
  /// must drift from the lever target before a trade fires. The pit-bay "GRIP"
  /// control sets this: tighter = more trades (more settlement txs), looser = fewer.
  final int bandBps;

  /// Maximum absolute notional this ride can ever hold = fuel × maxLev. The hard local cap the
  /// reconciler clamps to regardless of what the (operator-trusted-only-for-feel) ER reports.
  int get maxNotionalAbs6 => targetNotional6(fuelUsd6, maxLevBps, bpsScale).abs();
}

/// Advisory virtual state echoed from our ER `RideSession` (signed notional + VWAP + realized).
/// "Advisory" — never an authorization to trade; the reconciler bounds every action (ARCHITECTURE §3.3).
@immutable
class VirtualState {
  const VirtualState({
    required this.notionalUsd6,
    required this.entryVwapE9,
    required this.realizedPnl6,
    required this.tickCount,
    this.floorBreached = false,
  });

  const VirtualState.flat()
    : notionalUsd6 = 0,
      entryVwapE9 = 0,
      realizedPnl6 = 0,
      tickCount = 0,
      floorBreached = false;

  /// Signed: + long, − short.
  final int notionalUsd6;
  final int entryVwapE9;
  final int realizedPnl6;
  final int tickCount;
  final bool floorBreached;

  Side get side => Side.ofSigned(notionalUsd6);
}

/// A real, settled Flash position (read from the owner WS, with PnL recomputed client-side).
@immutable
class FlashPosition {
  const FlashPosition({
    required this.side,
    required this.sizeUsd6,
    required this.entryE9,
    this.stopTriggerE9,
  }) : assert(sizeUsd6 >= 0, 'size is unsigned'),
       assert(
         side != Side.flat || sizeUsd6 == 0,
         'flat implies zero size',
       );

  const FlashPosition.flat() : side = Side.flat, sizeUsd6 = 0, entryE9 = 0, stopTriggerE9 = null;

  final Side side;
  final int sizeUsd6;
  final int entryE9;

  /// Trigger price of the venue-native stop-loss currently attached, if any. `null` = NO stop
  /// (a state the reconciler must never leave an open position in — ARCHITECTURE §3.3 flip safety).
  final int? stopTriggerE9;

  /// Signed notional (+long / −short).
  int get signedUsd6 => side.sign * sizeUsd6;

  bool get isFlat => side == Side.flat || sizeUsd6 == 0;
  bool get hasStop => stopTriggerE9 != null;

  FlashPosition copyWith({Side? side, int? sizeUsd6, int? entryE9, int? stopTriggerE9}) =>
      FlashPosition(
        side: side ?? this.side,
        sizeUsd6: sizeUsd6 ?? this.sizeUsd6,
        entryE9: entryE9 ?? this.entryE9,
        stopTriggerE9: stopTriggerE9 ?? this.stopTriggerE9,
      );
}

/// A price observation with its source and freshness.
@immutable
class Mark {
  const Mark({required this.priceE9, required this.tsMicros});
  final int priceE9;
  final int tsMicros;
}
