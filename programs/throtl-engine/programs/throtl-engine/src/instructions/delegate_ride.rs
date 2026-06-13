use anchor_lang::prelude::*;
use ephemeral_rollups_sdk::anchor::delegate;
use ephemeral_rollups_sdk::cpi::DelegateConfig;

use crate::constants::RIDE_SEED;

/// Delegate the ride PDA to the chosen ER validator. The `#[delegate]` macro adds the
/// `delegate_ride(...)` helper to the accounts struct (named `delegate_<field>`).
///
/// `commit_frequency_ms` is set explicitly — the SDK default is "never" (u32::MAX), which would
/// leave uncommitted ER state unbounded (research §2.2 / R2).
#[delegate]
#[derive(Accounts)]
#[instruction(session_id: u64)]
pub struct DelegateRide<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    /// CHECK: the PDA to delegate; ownership/seeds enforced by the delegate CPI below.
    #[account(mut, del)]
    pub ride: UncheckedAccount<'info>,
}

pub(crate) fn handler(
    ctx: Context<DelegateRide>,
    session_id: u64,
    commit_frequency_ms: u32,
) -> Result<()> {
    let owner_key = ctx.accounts.owner.key();
    let session_le = session_id.to_le_bytes();
    ctx.accounts.delegate_ride(
        &ctx.accounts.owner,
        &[RIDE_SEED, owner_key.as_ref(), &session_le],
        DelegateConfig {
            commit_frequency_ms,
            validator: ctx.remaining_accounts.first().map(|a| a.key()),
        },
    )?;
    Ok(())
}
