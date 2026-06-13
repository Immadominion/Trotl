use anchor_lang::prelude::*;

use crate::constants::*;
use crate::error::ThrotlError;
use crate::state::RideSession;

/// Create the ride session PDA on L1 (status = Armed). Bundled with `delegate_ride` in one tx
/// by the client at ride start.
#[derive(Accounts)]
#[instruction(session_id: u64)]
pub struct InitRide<'info> {
    #[account(
        init,
        payer = owner,
        space = 8 + RideSession::LEN,
        seeds = [RIDE_SEED, owner.key().as_ref(), &session_id.to_le_bytes()],
        bump
    )]
    pub ride: AccountLoader<'info, RideSession>,
    #[account(mut)]
    pub owner: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn handler(
    ctx: Context<InitRide>,
    session_id: u64,
    session_key: Pubkey,
    market_id: u16,
    feed_id: [u8; 32],
    grip_mode: u8,
    fuel_usd_6: u64,
    max_lev_bps: u32,
    loss_floor_6: i64,
    expires_at: i64,
) -> Result<()> {
    require!(fuel_usd_6 > 0, ThrotlError::InvalidFuel);
    require!(
        max_lev_bps <= MAX_LEV_BPS_CEILING,
        ThrotlError::LeverageTooHigh
    );
    require!(max_lev_bps >= MIN_LEV_BPS, ThrotlError::LeverageTooLow);
    require!(loss_floor_6 < 0, ThrotlError::InvalidLossFloor);
    require!(grip_mode <= grip::CRUISE, ThrotlError::InvalidGripMode);
    let now = Clock::get()?.unix_timestamp;
    require!(expires_at > now, ThrotlError::SessionExpired);

    let mut ride = ctx.accounts.ride.load_init()?;
    ride.version = RideSession::VERSION;
    ride.bump = ctx.bumps.ride;
    ride.status = status::ARMED;
    ride.grip_mode = grip_mode;
    ride.market_id = market_id;
    ride.owner = ctx.accounts.owner.key();
    ride.session_key = session_key;
    ride.feed_id = feed_id;
    ride.session_id = session_id;
    ride.expires_at = expires_at;
    ride.fuel_usd_6 = fuel_usd_6;
    ride.max_lev_bps = max_lev_bps;
    ride.loss_floor_6 = loss_floor_6;
    Ok(())
}
