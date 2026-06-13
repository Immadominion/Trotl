use anchor_lang::prelude::*;
use ephemeral_rollups_sdk::anchor::commit;
use ephemeral_rollups_sdk::ephem::{FoldableIntentBuilder, MagicIntentBundleBuilder};

use crate::constants::status;
use crate::error::ThrotlError;
use crate::state::RideSession;

/// End the ride: mark status = Settling, then commit the final ER state to L1 and undelegate.
/// The `#[commit]` macro injects the `magic_context` and `magic_program` accounts.
#[commit]
#[derive(Accounts)]
pub struct RequestSettle<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(mut)]
    pub ride: AccountLoader<'info, RideSession>,
}

pub(crate) fn handler(ctx: Context<RequestSettle>) -> Result<()> {
    {
        let mut ride = ctx.accounts.ride.load_mut()?;
        require!(
            ctx.accounts.payer.key() == ride.owner || ctx.accounts.payer.key() == ride.session_key,
            ThrotlError::UnauthorizedSigner
        );
        ride.status = status::SETTLING;
        // RefMut dropped here so the account buffer is free for the commit CPI below.
    }

    MagicIntentBundleBuilder::new(
        ctx.accounts.payer.to_account_info(),
        ctx.accounts.magic_context.to_account_info(),
        ctx.accounts.magic_program.to_account_info(),
    )
    .commit_and_undelegate(&[ctx.accounts.ride.to_account_info()])
    .build_and_invoke()?;
    Ok(())
}
