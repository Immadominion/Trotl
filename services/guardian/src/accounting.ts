/**
 * The loss-floor math — TypeScript mirror of `throtl_core/accounting.dart` and the on-chain Rust
 * `math` module (ARCHITECTURE §2.2 / §3.4). The guardian recomputes effective equity against its OWN
 * independent guard mark and fires the pre-signed flatten when it breaches the floor — this is the
 * off-phone safety net (DR-5), independent of whatever the ER reports.
 *
 * Parity is enforced by `test/accounting.test.ts` against the same vectors the Dart/Rust suites use.
 */

import { satI64 } from './fixedpoint.js';

/**
 * Unrealized PnL (usd_6) of open signed [notionalUsd6] entered at [vwapE9], marked at [markE9]:
 * `pnl = notional * (mark - vwap) / vwap`. BigInt division truncates toward zero, matching Rust i128
 * and Dart `~/`.
 */
export function unrealizedPnl6(notionalUsd6: bigint, vwapE9: bigint, markE9: bigint): bigint {
  if (vwapE9 === 0n || notionalUsd6 === 0n) return 0n;
  const diff = markE9 - vwapE9;
  const num = notionalUsd6 * diff;
  return satI64(num / vwapE9);
}

/** Effective equity (usd_6) = fuel + realized + unrealized — the loss-floor predicate quantity. */
export function effectiveEquity6(
  fuelUsd6: bigint,
  realizedPnl6: bigint,
  unrealized6: bigint,
): bigint {
  return satI64(fuelUsd6 + realizedPnl6 + unrealized6);
}

/** Outcome of the floor check at a given mark. */
export interface FloorCheck {
  readonly markE9: bigint;
  readonly unrealized6: bigint;
  readonly equity6: bigint;
  readonly breached: boolean;
  /** True when equity has gone non-positive (bankruptcy) — strictly worse than a floor breach. */
  readonly bankrupt: boolean;
}

/**
 * Recompute the floor predicate from committed RideSession fields + an INDEPENDENT [markE9].
 * `breached` ⇔ `equity <= lossFloor6` — exactly the on-chain `tick` predicate (constants mirror).
 */
export function checkFloor(args: {
  fuelUsd6: bigint;
  realizedPnl6: bigint;
  notionalUsd6: bigint;
  entryVwapE9: bigint;
  lossFloor6: bigint;
  markE9: bigint;
}): FloorCheck {
  const unrealized6 = unrealizedPnl6(args.notionalUsd6, args.entryVwapE9, args.markE9);
  const equity6 = effectiveEquity6(args.fuelUsd6, args.realizedPnl6, unrealized6);
  return {
    markE9: args.markE9,
    unrealized6,
    equity6,
    breached: equity6 <= args.lossFloor6,
    bankrupt: equity6 <= 0n,
  };
}
