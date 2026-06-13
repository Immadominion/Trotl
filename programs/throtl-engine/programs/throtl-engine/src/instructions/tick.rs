use anchor_lang::prelude::*;

use crate::constants::*;
use crate::error::ThrotlError;
use crate::state::RideSession;
use crate::{math, oracle};

/// The hot path. Runs inside the ER, signed by the session key. Moves the virtual position toward
/// `target_exp_bps`, marking PnL against the in-ER Pyth Lazer oracle. Reused by `flatten` (target 0).
#[derive(Accounts)]
pub struct Tick<'info> {
    #[account(mut)]
    pub ride: AccountLoader<'info, RideSession>,
    /// CHECK: validated inside `oracle::read_oracle` (owner + feed + staleness).
    pub price_feed: UncheckedAccount<'info>,
    pub session_signer: Signer<'info>,
}

pub(crate) fn handler(ctx: Context<Tick>, target_exp_bps: i32) -> Result<()> {
    require!(
        (MIN_EXP_BPS..=MAX_EXP_BPS).contains(&target_exp_bps),
        ThrotlError::ExposureOutOfBounds
    );
    let now = Clock::get()?.unix_timestamp;
    let ride_key = ctx.accounts.ride.key();
    let mut ride = ctx.accounts.ride.load_mut()?;

    // ── authz: only the registered session key may tick ──────────────────────
    require_keys_eq!(
        ctx.accounts.session_signer.key(),
        ride.session_key,
        ThrotlError::UnauthorizedSigner
    );

    // ── PDA integrity: re-derive from stored owner/session_id/bump ────────────
    let expected = Pubkey::create_program_address(
        &[
            RIDE_SEED,
            ride.owner.as_ref(),
            &ride.session_id.to_le_bytes(),
            &[ride.bump],
        ],
        &crate::ID,
    )
    .map_err(|_| ThrotlError::PdaMismatch)?;
    require_keys_eq!(expected, ride_key, ThrotlError::PdaMismatch);

    // ── status + expiry ───────────────────────────────────────────────────────
    require!(
        ride.status == status::ARMED || ride.status == status::RIDING,
        ThrotlError::InvalidStatus
    );
    require!(now < ride.expires_at, ThrotlError::SessionExpired);

    // ── oracle read (honest needle-freeze on staleness) ──────────────────────
    let feed_id = ride.feed_id;
    let mark = match oracle::read_oracle(&ctx.accounts.price_feed.to_account_info(), &feed_id, now)
    {
        Ok(p) => {
            ride.flags &= !flags::ORACLE_STALE;
            p.price_e9
        }
        Err(_) => {
            // Record the thumb target but do not mark PnL or move real-derived state: the needle
            // freezes honestly until a fresh price arrives.
            ride.flags |= flags::ORACLE_STALE;
            ride.target_exp_bps = target_exp_bps;
            ride.tick_count = ride.tick_count.saturating_add(1);
            return Ok(());
        }
    };

    // ── effective equity / floor gating ───────────────────────────────────────
    let unreal = math::unrealized_pnl_6(ride.notional_usd_6, ride.entry_vwap_e9, mark);
    let eff_eq = math::effective_equity_6(ride.fuel_usd_6, ride.realized_pnl_6, unreal);
    let eff_coll = math::effective_collateral_6(ride.fuel_usd_6, ride.realized_pnl_6);

    let breached = eff_eq <= ride.loss_floor_6;
    let bankrupt = eff_eq <= 0;
    if breached {
        ride.flags |= flags::FLOOR_BREACHED;
    }
    if bankrupt {
        ride.flags |= flags::BANKRUPT;
    }

    let mut target_notional = math::target_notional_6(eff_coll, ride.max_lev_bps, target_exp_bps);

    // When breached/bankrupt, only reductions are allowed: clamp an increase to the current notional.
    if breached || bankrupt {
        let cur_abs = ride.notional_usd_6.unsigned_abs();
        if target_notional.unsigned_abs() > cur_abs {
            target_notional = ride.notional_usd_6;
        }
    }

    // ── settle the virtual position ───────────────────────────────────────────
    let s = math::settle_to_target(
        ride.notional_usd_6,
        ride.entry_vwap_e9,
        target_notional,
        mark,
    );
    ride.realized_pnl_6 = ride.realized_pnl_6.saturating_add(s.realized_delta_6);
    ride.notional_usd_6 = s.new_notional_6;
    ride.entry_vwap_e9 = s.new_vwap_e9;
    ride.target_exp_bps = target_exp_bps;
    ride.virt_exp_bps = math::notional_to_bps(s.new_notional_6, eff_coll, ride.max_lev_bps);
    ride.last_mark_e9 = mark;
    ride.last_mark_ts = now;
    ride.tick_count = ride.tick_count.saturating_add(1);
    if ride.status == status::ARMED {
        ride.status = status::RIDING;
    }
    Ok(())
}
