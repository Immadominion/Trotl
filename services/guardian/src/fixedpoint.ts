/**
 * Fixed-point constants + i64 saturation — the TypeScript mirror of the throtl-engine Rust `math`
 * module and the Dart `accounting.dart`. All three MUST agree bit-for-bit; the guardian recomputes
 * the loss-floor predicate off-phone, so a divergence here would mean it fires (or fails to fire) at
 * a different price than the chain. BigInt reproduces Rust's i128 intermediates exactly; results
 * saturate to i64 just as the program does.
 */

export const BPS_SCALE = 10_000n; // 1e4
export const USD_SCALE = 1_000_000n; // 1e6
export const PRICE_SCALE = 1_000_000_000n; // 1e9

export const I64_MAX = (1n << 63n) - 1n; // 2^63 − 1
export const I64_MIN = -(1n << 63n); // −2^63
const U64_MAX = (1n << 64n) - 1n;

/** Saturate a wide intermediate to i64 (matches Rust `saturating` + Dart `_satI64`). */
export function satI64(x: bigint): bigint {
  if (x > I64_MAX) return I64_MAX;
  if (x < I64_MIN) return I64_MIN;
  return x;
}

/** Clamp to u64 (for prices/vwap that are never negative). */
export function clampU64(x: bigint): bigint {
  if (x < 0n) return 0n;
  if (x > U64_MAX) return U64_MAX;
  return x;
}
