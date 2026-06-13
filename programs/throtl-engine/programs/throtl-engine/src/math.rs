//! Fixed-point virtual-position accounting — pure integer math, host-testable, no Anchor deps.
//!
//! Conventions (also implemented identically in `throtl_core` Dart; cross-checked by shared
//! test vectors — see ARCHITECTURE §2.2):
//!   * USD amounts: 1e6 fixed-point  (`*_6`)
//!   * Prices:      1e9 fixed-point  (`*_e9`)
//!   * Exposure:    signed basis points (`*_bps`), sign = side (+long / −short)
//!
//! Every function is **total** — no panics. Intermediates use i128; results saturate to range.

/// 1e4 — basis points.
pub const BPS_SCALE: i128 = 10_000;
/// 1e6 — USD fixed-point.
pub const USD_SCALE: i128 = 1_000_000;
/// 1e9 — price fixed-point.
pub const PRICE_SCALE: i128 = 1_000_000_000;

#[inline]
fn sat_i64(x: i128) -> i64 {
    if x > i64::MAX as i128 {
        i64::MAX
    } else if x < i64::MIN as i128 {
        i64::MIN
    } else {
        x as i64
    }
}

/// +1 long, −1 short, 0 flat.
#[inline]
pub fn sign_i64(x: i64) -> i64 {
    (x > 0) as i64 - (x < 0) as i64
}

/// Unrealized PnL (usd_6) of an open signed `notional` entered at `vwap`, marked at `mark`.
/// `pnl = notional * (mark - vwap) / vwap` — sign carried by `notional`. i128 intermediate.
pub fn unrealized_pnl_6(notional_usd_6: i64, vwap_e9: u64, mark_e9: u64) -> i64 {
    if vwap_e9 == 0 || notional_usd_6 == 0 {
        return 0;
    }
    let diff = mark_e9 as i128 - vwap_e9 as i128;
    let num = (notional_usd_6 as i128).saturating_mul(diff);
    sat_i64(num / vwap_e9 as i128)
}

/// Effective collateral for sizing (usd_6) = max(0, fuel + realized).
/// Excludes unrealized to keep sizing non-circular (ARCHITECTURE §2.2).
pub fn effective_collateral_6(fuel_usd_6: u64, realized_pnl_6: i64) -> i64 {
    let c = fuel_usd_6 as i128 + realized_pnl_6 as i128;
    if c < 0 {
        0
    } else {
        sat_i64(c)
    }
}

/// Effective equity (usd_6) = fuel + realized + unrealized. The loss-floor predicate quantity.
pub fn effective_equity_6(fuel_usd_6: u64, realized_pnl_6: i64, unrealized_6: i64) -> i64 {
    sat_i64(fuel_usd_6 as i128 + realized_pnl_6 as i128 + unrealized_6 as i128)
}

/// Signed target notional (usd_6) for a deflection:
/// `notional = effective_collateral * (lev_bps/1e4) * (exp_bps/1e4)`, signed by `exp_bps`.
pub fn target_notional_6(
    effective_collateral_6: i64,
    max_lev_bps: u32,
    target_exp_bps: i32,
) -> i64 {
    if effective_collateral_6 <= 0 || target_exp_bps == 0 || max_lev_bps == 0 {
        return 0;
    }
    let c = effective_collateral_6 as i128;
    let n = c.saturating_mul(max_lev_bps as i128) / BPS_SCALE;
    let n = n.saturating_mul(target_exp_bps as i128) / BPS_SCALE;
    sat_i64(n)
}

/// Inverse of [`target_notional_6`] — settled notional expressed as signed bps for display.
pub fn notional_to_bps(notional_6: i64, effective_collateral_6: i64, max_lev_bps: u32) -> i32 {
    if effective_collateral_6 <= 0 || max_lev_bps == 0 {
        return 0;
    }
    let num = (notional_6 as i128) * BPS_SCALE * BPS_SCALE;
    let den = (effective_collateral_6 as i128) * (max_lev_bps as i128);
    if den == 0 {
        return 0;
    }
    let b = num / den;
    if b > i32::MAX as i128 {
        i32::MAX
    } else if b < i32::MIN as i128 {
        i32::MIN
    } else {
        b as i32
    }
}

/// Outcome of moving the virtual position toward a target notional at `mark`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Settle {
    pub new_notional_6: i64,
    pub new_vwap_e9: u64,
    pub realized_delta_6: i64,
}

/// Move signed notional from `cur` (entered at `cur_vwap`) to `target` at `mark`.
/// Handles: open-from-flat, same-side increase (re-weight VWAP), same-side reduce
/// (realize on the closed portion), full close, and cross-through-zero.
pub fn settle_to_target(
    cur_notional_6: i64,
    cur_vwap_e9: u64,
    target_notional_6: i64,
    mark_e9: u64,
) -> Settle {
    // No price → cannot mark; hold.
    if mark_e9 == 0 {
        return Settle {
            new_notional_6: cur_notional_6,
            new_vwap_e9: cur_vwap_e9,
            realized_delta_6: 0,
        };
    }
    // Open from flat.
    if cur_notional_6 == 0 {
        return Settle {
            new_notional_6: target_notional_6,
            new_vwap_e9: if target_notional_6 == 0 { 0 } else { mark_e9 },
            realized_delta_6: 0,
        };
    }
    let cur_side = sign_i64(cur_notional_6);
    let tgt_side = sign_i64(target_notional_6);

    // Target flat → full close.
    if tgt_side == 0 {
        let realized = realize_close(
            cur_notional_6,
            cur_vwap_e9,
            mark_e9,
            abs_i64(cur_notional_6),
        );
        return Settle {
            new_notional_6: 0,
            new_vwap_e9: 0,
            realized_delta_6: realized,
        };
    }

    if tgt_side == cur_side {
        let cur_abs = cur_notional_6.unsigned_abs() as i128;
        let tgt_abs = target_notional_6.unsigned_abs() as i128;
        if tgt_abs >= cur_abs {
            // Increase same side → re-weight VWAP by the added notional.
            let dn = tgt_abs - cur_abs;
            if dn == 0 {
                return Settle {
                    new_notional_6: cur_notional_6,
                    new_vwap_e9: cur_vwap_e9,
                    realized_delta_6: 0,
                };
            }
            let new_vwap = weighted_vwap(cur_abs, cur_vwap_e9, dn, mark_e9);
            Settle {
                new_notional_6: target_notional_6,
                new_vwap_e9: new_vwap,
                realized_delta_6: 0,
            }
        } else {
            // Reduce toward zero → realize on the closed portion; VWAP unchanged.
            let closed = sat_i64(cur_abs - tgt_abs);
            let realized = realize_close(cur_notional_6, cur_vwap_e9, mark_e9, closed);
            Settle {
                new_notional_6: target_notional_6,
                new_vwap_e9: cur_vwap_e9,
                realized_delta_6: realized,
            }
        }
    } else {
        // Cross through zero → fully close current at mark, re-open remainder on new side at mark.
        let realized = realize_close(
            cur_notional_6,
            cur_vwap_e9,
            mark_e9,
            abs_i64(cur_notional_6),
        );
        Settle {
            new_notional_6: target_notional_6,
            new_vwap_e9: mark_e9,
            realized_delta_6: realized,
        }
    }
}

#[inline]
fn abs_i64(x: i64) -> i64 {
    sat_i64((x as i128).abs())
}

/// Realized PnL (usd_6) from closing `closed_abs_6` (≥0) of a position whose sign is `signed_ref`.
/// `pnl = closed_abs * (mark - vwap)/vwap * side`. Wide i128 intermediate (no round-to-zero / overflow).
fn realize_close(signed_ref_6: i64, vwap_e9: u64, mark_e9: u64, closed_abs_6: i64) -> i64 {
    if vwap_e9 == 0 || closed_abs_6 == 0 {
        return 0;
    }
    let side = sign_i64(signed_ref_6) as i128;
    let diff = mark_e9 as i128 - vwap_e9 as i128;
    let pnl = (closed_abs_6 as i128).saturating_mul(diff) / vwap_e9 as i128 * side;
    sat_i64(pnl)
}

/// Weighted average price (e9): existing (abs `a0` @ `p0`) blended with added (abs `a1` @ `p1`).
fn weighted_vwap(a0: i128, p0_e9: u64, a1: i128, p1_e9: u64) -> u64 {
    let denom = a0 + a1;
    if denom == 0 {
        return 0;
    }
    let num = a0.saturating_mul(p0_e9 as i128) + a1.saturating_mul(p1_e9 as i128);
    let v = num / denom;
    if v < 0 {
        0
    } else if v > u64::MAX as i128 {
        u64::MAX
    } else {
        v as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const P1: u64 = 100 * PRICE_SCALE as u64; // $100.000000000
    const P110: u64 = 110 * PRICE_SCALE as u64; // $110
    const P90: u64 = 90 * PRICE_SCALE as u64; // $90

    #[test]
    fn long_profit_unrealized() {
        // $1,000 notional long entered at $100, marked $110 → +$100 = +10%.
        let pnl = unrealized_pnl_6(1_000 * USD_SCALE as i64, P1, P110);
        assert_eq!(pnl, 100 * USD_SCALE as i64);
    }

    #[test]
    fn short_profit_unrealized() {
        // −$1,000 notional (short) entered $100, marked $90 → +$100.
        let pnl = unrealized_pnl_6(-1_000 * USD_SCALE as i64, P1, P90);
        assert_eq!(pnl, 100 * USD_SCALE as i64);
    }

    #[test]
    fn open_from_flat_sets_vwap_to_mark() {
        let s = settle_to_target(0, 0, 500 * USD_SCALE as i64, P1);
        assert_eq!(s.new_notional_6, 500 * USD_SCALE as i64);
        assert_eq!(s.new_vwap_e9, P1);
        assert_eq!(s.realized_delta_6, 0);
    }

    #[test]
    fn increase_reweights_vwap() {
        // $1000 @ $100, add $1000 @ $110 → vwap $105.
        let s = settle_to_target(1_000 * USD_SCALE as i64, P1, 2_000 * USD_SCALE as i64, P110);
        assert_eq!(s.new_notional_6, 2_000 * USD_SCALE as i64);
        assert_eq!(s.new_vwap_e9, 105 * PRICE_SCALE as u64);
        assert_eq!(s.realized_delta_6, 0);
    }

    #[test]
    fn reduce_realizes_proportional_pnl() {
        // $2000 long @ $100, reduce to $1000 at $110 → realize on closed $1000 = +$100.
        let s = settle_to_target(2_000 * USD_SCALE as i64, P1, 1_000 * USD_SCALE as i64, P110);
        assert_eq!(s.new_notional_6, 1_000 * USD_SCALE as i64);
        assert_eq!(s.new_vwap_e9, P1); // unchanged on reduce
        assert_eq!(s.realized_delta_6, 100 * USD_SCALE as i64);
    }

    #[test]
    fn full_close_realizes_all() {
        let s = settle_to_target(1_000 * USD_SCALE as i64, P1, 0, P110);
        assert_eq!(s.new_notional_6, 0);
        assert_eq!(s.new_vwap_e9, 0);
        assert_eq!(s.realized_delta_6, 100 * USD_SCALE as i64);
    }

    #[test]
    fn cross_through_zero_realizes_old_and_reopens_at_mark() {
        // $1000 long @ $100 → flip to −$500 short at $110: realize +$100, new short @ $110.
        let s = settle_to_target(1_000 * USD_SCALE as i64, P1, -500 * USD_SCALE as i64, P110);
        assert_eq!(s.new_notional_6, -500 * USD_SCALE as i64);
        assert_eq!(s.new_vwap_e9, P110);
        assert_eq!(s.realized_delta_6, 100 * USD_SCALE as i64);
    }

    #[test]
    fn sub_cent_close_at_huge_mark_does_not_round_to_zero() {
        // tiny notional, large price — verify i128 intermediate preserves signal.
        let big = 100_000 * PRICE_SCALE as u64; // $100k mark
        let entry = 99_000 * PRICE_SCALE as u64; // $99k entry
                                                 // $1.000000 notional long, +~1.01% → ~+0.0101 USD = ~10101 in usd_6.
        let pnl = unrealized_pnl_6(USD_SCALE as i64, entry, big);
        assert!(pnl > 0, "sub-cent pnl must be non-zero: {pnl}");
    }

    #[test]
    fn target_notional_scales_with_collateral_lev_and_bps() {
        // $500 collateral, 10x (100_000 bps), full long (10_000 bps) → $5,000.
        let n = target_notional_6(500 * USD_SCALE as i64, 100_000, 10_000);
        assert_eq!(n, 5_000 * USD_SCALE as i64);
        // half deflection short → −$2,500.
        let n = target_notional_6(500 * USD_SCALE as i64, 100_000, -5_000);
        assert_eq!(n, -2_500 * USD_SCALE as i64);
    }

    #[test]
    fn bps_round_trips_through_notional() {
        let coll = 500 * USD_SCALE as i64;
        let n = target_notional_6(coll, 100_000, 7_500);
        assert_eq!(notional_to_bps(n, coll, 100_000), 7_500);
    }

    #[test]
    fn effective_collateral_clamps_at_zero() {
        assert_eq!(
            effective_collateral_6(100 * USD_SCALE as u64, -200 * USD_SCALE as i64),
            0
        );
        assert_eq!(
            effective_collateral_6(100 * USD_SCALE as u64, 50 * USD_SCALE as i64),
            150 * USD_SCALE as i64
        );
    }

    #[test]
    fn saturation_does_not_panic_on_extremes() {
        // realized at i64::MIN region must saturate, never panic.
        let pnl = unrealized_pnl_6(i64::MIN, 1, u64::MAX);
        let _ = pnl; // no panic == pass
        let s = settle_to_target(i64::MAX, 1, i64::MIN, u64::MAX);
        let _ = s;
    }
}
