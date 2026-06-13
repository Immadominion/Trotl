use anchor_lang::prelude::*;

use crate::constants::{flags, status};
use crate::error::ThrotlError;
use crate::state::RideSession;

/// Stop-adding + alert. Zeroes the target and marks the floor breach so further increases are
/// rejected. Callable manually by the owner or session key; in M1.5 a 100ms ER crank calls this
/// automatically on a floor breach (the crank is layer-2 in the guardian model — it freezes the
/// *virtual* position; it cannot touch the real Flash position, ARCHITECTURE §3.4).
#[derive(Accounts)]
pub struct Freeze<'info> {
    #[account(mut)]
    pub ride: AccountLoader<'info, RideSession>,
    pub authority: Signer<'info>,
}

pub(crate) fn handler(ctx: Context<Freeze>) -> Result<()> {
    let mut ride = ctx.accounts.ride.load_mut()?;
    require!(
        ctx.accounts.authority.key() == ride.owner
            || ctx.accounts.authority.key() == ride.session_key,
        ThrotlError::UnauthorizedSigner
    );
    require!(
        ride.status == status::RIDING || ride.status == status::ARMED,
        ThrotlError::InvalidStatus
    );
    ride.status = status::FROZEN;
    ride.target_exp_bps = 0;
    ride.flags |= flags::FLOOR_BREACHED;
    Ok(())
}
