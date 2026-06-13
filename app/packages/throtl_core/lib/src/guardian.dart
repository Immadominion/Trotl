/// The loss-floor math (DR-5). The floor is enforced on the REAL settled position via a venue stop
/// whose trigger price is derived from the user's dollar floor on the *current* real size, and
/// re-derived on every reconciler action. The promised worst-case bound is
/// `floor + slippage + keeper-hold + band-gap` — never the nominal floor (ARCHITECTURE §3.4).
library;

import 'package:throtl_core/src/accounting.dart';
import 'package:throtl_core/src/models.dart';

/// Flash applies a haircut/buffer (fees + liquidation maintenance) before a stop realizes the full
/// nominal loss. We place the trigger slightly tighter so the *realized* loss lands near the floor
/// rather than past it. 0.92 mirrors the liq-haircut factor used in the on-chain liq estimate.
const double stopHaircut = 0.92;

final BigInt _u64Max = (BigInt.one << 64) - BigInt.one;

int _clampU64(BigInt x) {
  if (x < BigInt.zero) return 0;
  if (x > _u64Max) return _u64Max.toInt();
  return x.toInt();
}

/// Stop-loss trigger price (priceE9) that yields ≈ [lossFloor6] (a negative usd6) on a position of
/// [sizeUsd6] entered at [entryE9].
///
///   long  loses as price falls →  trigger = entry × (1 − |floor|/size × haircut)
///   short loses as price rises →  trigger = entry × (1 + |floor|/size × haircut)
///
/// Returns null for a flat/zero position (nothing to protect).
int? stopTriggerE9({
  required Side side,
  required int entryE9,
  required int sizeUsd6,
  required int lossFloor6,
}) {
  if (side == Side.flat || sizeUsd6 <= 0 || entryE9 <= 0) return null;
  final floorAbs = lossFloor6.abs();
  // fraction = |floor| / size, in priceE9 ratio space, times the haircut.
  // delta = entry × fraction × haircut  (computed in BigInt at price scale).
  // Use a 1e9 ratio: ratioE9 = |floor| * 1e9 / size  (dimensionless × 1e9).
  final ratioE9 = BigInt.from(floorAbs) * BigInt.from(priceScale) ~/ BigInt.from(sizeUsd6);
  // apply haircut as 92/100 to keep integer math deterministic across platforms.
  final hairRatioE9 = ratioE9 * BigInt.from(92) ~/ BigInt.from(100);
  final deltaE9 = BigInt.from(entryE9) * hairRatioE9 ~/ BigInt.from(priceScale);
  final trigger = side == Side.long
      ? BigInt.from(entryE9) - deltaE9
      : BigInt.from(entryE9) + deltaE9;
  return _clampU64(trigger);
}

/// True when effective equity has breached the floor. Equity = fuel + realized + unrealized,
/// unrealized marked at [markE9]. Mirrors the on-chain predicate exactly (shared with `tick`).
bool floorBreached({
  required int fuelUsd6,
  required int realizedPnl6,
  required int notionalUsd6,
  required int entryVwapE9,
  required int markE9,
  required int lossFloor6,
}) {
  final unreal = unrealizedPnl6(notionalUsd6, entryVwapE9, markE9);
  final equity = effectiveEquity6(fuelUsd6, realizedPnl6, unreal);
  return equity <= lossFloor6;
}

/// Worst-case realized loss (usd6, negative) we PROMISE at Pre-flight — computed against the keyless
/// venue stop alone (we never promise better than what survives a total Throtl outage):
///   floor + slippage(model) + keeper-hold drift + virtual-vs-settled band gap.
/// All inputs are positive magnitudes (usd6); result is negative.
int worstCaseLossBound6({
  required int lossFloor6,
  required int slippageUsd6,
  required int keeperHoldDriftUsd6,
  required int bandGapUsd6,
}) {
  final magnitude =
      lossFloor6.abs() + slippageUsd6.abs() + keeperHoldDriftUsd6.abs() + bandGapUsd6.abs();
  return -magnitude;
}
