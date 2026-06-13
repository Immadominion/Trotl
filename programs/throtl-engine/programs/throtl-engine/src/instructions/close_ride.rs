use anchor_lang::prelude::*;

use crate::constants::status;
use crate::error::ThrotlError;
use crate::state::RideSession;

/// Close the ride PDA on L1 after undelegation, returning rent to the owner. Requires the ride to
/// have been settled (status = Settling/Closed) and to be owned by this program again (i.e. the
/// undelegation callback has run — otherwise the account is still delegated and not closable here).
#[derive(Accounts)]
pub struct CloseRide<'info> {
    #[account(mut, close = owner, has_one = owner)]
    pub ride: AccountLoader<'info, RideSession>,
    #[account(mut)]
    pub owner: Signer<'info>,
}

pub(crate) fn handler(ctx: Context<CloseRide>) -> Result<()> {
    let ride = ctx.accounts.ride.load()?;
    require!(
        ride.status == status::SETTLING || ride.status == status::CLOSED,
        ThrotlError::InvalidStatus
    );
    Ok(())
}
