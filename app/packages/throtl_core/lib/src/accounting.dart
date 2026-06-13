/// Fixed-point virtual-position accounting — the Dart mirror of the `throtl-engine` Rust `math`
/// module. **These two implementations MUST agree**; the shared test vectors in
/// `test/accounting_test.dart` are the parity check (ARCHITECTURE §2.2).
///
/// Conventions:
///   * USD amounts: 1e6 fixed-point (`*_6`), held in Dart `int` (64-bit), range = i64.
///   * Prices:      1e9 fixed-point (`*E9`).
///   * Exposure:    signed basis points, sign = side (+long / −short).
///
/// Wide intermediates use [BigInt] to reproduce Rust's `i128` exactly, then saturate to i64 — so
/// there is no platform divergence between Dart VM (64-bit int) and the web (where `int` is a
/// JS double); correctness is identical to the on-chain program by construction.
library;

import 'package:meta/meta.dart';

const int bpsScale = 10000; // 1e4
const int usdScale = 1000000; // 1e6
const int priceScale = 1000000000; // 1e9

// Bounds via shifts — NOT hex int literals. `0x8000000000000000` overflows Dart's signed 64-bit
// int and would make `_i64Min` positive (saturation would then fire on every value).
final BigInt _i64Max = (BigInt.one << 63) - BigInt.one; // 2^63 − 1
final BigInt _i64Min = -(BigInt.one << 63); // −2^63
final BigInt _i32Max = (BigInt.one << 31) - BigInt.one; // 2^31 − 1
final BigInt _i32Min = -(BigInt.one << 31); // −2^31
final BigInt _u64Max = (BigInt.one << 64) - BigInt.one;

int _satI64(BigInt x) {
  if (x > _i64Max) return _i64Max.toInt();
  if (x < _i64Min) return _i64Min.toInt();
  return x.toInt();
}

int _satI32(BigInt x) {
  if (x > _i32Max) return _i32Max.toInt();
  if (x < _i32Min) return _i32Min.toInt();
  return x.toInt();
}

int _clampU64(BigInt x) {
  if (x < BigInt.zero) return 0;
  if (x > _u64Max) return _u64Max.toInt();
  return x.toInt();
}

/// +1 long, −1 short, 0 flat.
int signInt(int x) => x > 0
    ? 1
    : x < 0
    ? -1
    : 0;

/// Unrealized PnL (usd_6) of open signed [notionalUsd6] entered at [vwapE9], marked at [markE9].
/// `pnl = notional * (mark - vwap) / vwap`.
int unrealizedPnl6(int notionalUsd6, int vwapE9, int markE9) {
  if (vwapE9 == 0 || notionalUsd6 == 0) return 0;
  final diff = BigInt.from(markE9) - BigInt.from(vwapE9);
  final num = BigInt.from(notionalUsd6) * diff;
  return _satI64(num ~/ BigInt.from(vwapE9));
}

/// Effective collateral for sizing (usd_6) = max(0, fuel + realized). Non-circular (excludes
/// unrealized).
int effectiveCollateral6(int fuelUsd6, int realizedPnl6) {
  final c = BigInt.from(fuelUsd6) + BigInt.from(realizedPnl6);
  return c < BigInt.zero ? 0 : _satI64(c);
}

/// Effective equity (usd_6) = fuel + realized + unrealized. The loss-floor predicate quantity.
int effectiveEquity6(int fuelUsd6, int realizedPnl6, int unrealized6) =>
    _satI64(BigInt.from(fuelUsd6) + BigInt.from(realizedPnl6) + BigInt.from(unrealized6));

/// Signed target notional (usd_6): `collateral * (lev/1e4) * (exp/1e4)`, signed by [targetExpBps].
int targetNotional6(int effectiveCollateral6, int maxLevBps, int targetExpBps) {
  if (effectiveCollateral6 <= 0 || targetExpBps == 0 || maxLevBps == 0) return 0;
  final c = BigInt.from(effectiveCollateral6);
  var n = c * BigInt.from(maxLevBps) ~/ BigInt.from(bpsScale);
  n = n * BigInt.from(targetExpBps) ~/ BigInt.from(bpsScale);
  return _satI64(n);
}

/// Inverse of [targetNotional6] — settled notional as signed bps (display metric).
int notionalToBps(int notional6, int effectiveCollateral6, int maxLevBps) {
  if (effectiveCollateral6 <= 0 || maxLevBps == 0) return 0;
  final num = BigInt.from(notional6) * BigInt.from(bpsScale) * BigInt.from(bpsScale);
  final den = BigInt.from(effectiveCollateral6) * BigInt.from(maxLevBps);
  if (den == BigInt.zero) return 0;
  return _satI32(num ~/ den);
}

/// Outcome of moving the virtual position toward a target notional at `mark`.
@immutable
class Settle {
  const Settle(this.newNotional6, this.newVwapE9, this.realizedDelta6);
  final int newNotional6;
  final int newVwapE9;
  final int realizedDelta6;

  @override
  bool operator ==(Object other) =>
      other is Settle &&
      other.newNotional6 == newNotional6 &&
      other.newVwapE9 == newVwapE9 &&
      other.realizedDelta6 == realizedDelta6;

  @override
  int get hashCode => Object.hash(newNotional6, newVwapE9, realizedDelta6);

  @override
  String toString() => 'Settle(n=$newNotional6, vwap=$newVwapE9, realized=$realizedDelta6)';
}

/// Move signed notional from [curNotional6] (at [curVwapE9]) toward [targetNotional6] at [markE9].
Settle settleToTarget(int curNotional6, int curVwapE9, int targetNotional6, int markE9) {
  if (markE9 == 0) return Settle(curNotional6, curVwapE9, 0);
  if (curNotional6 == 0) {
    return Settle(targetNotional6, targetNotional6 == 0 ? 0 : markE9, 0);
  }
  final curSide = signInt(curNotional6);
  final tgtSide = signInt(targetNotional6);

  if (tgtSide == 0) {
    final realized = _realizeClose(curNotional6, curVwapE9, markE9, curNotional6.abs());
    return Settle(0, 0, realized);
  }

  if (tgtSide == curSide) {
    final curAbs = BigInt.from(curNotional6.abs());
    final tgtAbs = BigInt.from(targetNotional6.abs());
    if (tgtAbs >= curAbs) {
      final dn = tgtAbs - curAbs;
      if (dn == BigInt.zero) return Settle(curNotional6, curVwapE9, 0);
      final newVwap = _weightedVwap(curAbs, curVwapE9, dn, markE9);
      return Settle(targetNotional6, newVwap, 0);
    } else {
      final closed = _satI64(curAbs - tgtAbs);
      final realized = _realizeClose(curNotional6, curVwapE9, markE9, closed);
      return Settle(targetNotional6, curVwapE9, realized);
    }
  }

  // Cross through zero.
  final realized = _realizeClose(curNotional6, curVwapE9, markE9, curNotional6.abs());
  return Settle(targetNotional6, markE9, realized);
}

int _realizeClose(int signedRef6, int vwapE9, int markE9, int closedAbs6) {
  if (vwapE9 == 0 || closedAbs6 == 0) return 0;
  final side = BigInt.from(signInt(signedRef6));
  final diff = BigInt.from(markE9) - BigInt.from(vwapE9);
  final pnl = (BigInt.from(closedAbs6) * diff ~/ BigInt.from(vwapE9)) * side;
  return _satI64(pnl);
}

int _weightedVwap(BigInt a0, int p0E9, BigInt a1, int p1E9) {
  final denom = a0 + a1;
  if (denom == BigInt.zero) return 0;
  final num = a0 * BigInt.from(p0E9) + a1 * BigInt.from(p1E9);
  return _clampU64(num ~/ denom);
}
