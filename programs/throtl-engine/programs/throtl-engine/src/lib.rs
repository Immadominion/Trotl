//! Throtl Engine — the on-chain virtual-exposure layer for the analog exchange.
//!
//! A per-ride `RideSession` PDA is delegated to a MagicBlock Ephemeral Rollup; the in-app session
//! key writes signed target exposure at 20–33 Hz via gasless `tick`s, marking PnL against the in-ER
//! Pyth Lazer oracle. This program holds **no funds** — real money lives in the user's wallet and
//! their Flash Trade Basket; the client reconciler mirrors this virtual state into real Flash
//! positions (ARCHITECTURE §§1–3). The program is the loss-floor + PnL authority, so every handler
//! is constraint-checked and arithmetic is checked/saturating (DR-1 discipline contract).

use anchor_lang::prelude::*;
use ephemeral_rollups_sdk::anchor::ephemeral;

pub mod constants;
pub mod error;
pub mod instructions;
pub mod math;
pub mod oracle;
pub mod state;

use instructions::*;

declare_id!("YSaqfuc753DkHZoaEvdNMSTQTf4hEuTtP65hszuvJy9");

#[ephemeral]
#[program]
pub mod throtl_engine {
    use super::*;

    /// Create the ride session PDA on L1 (status = Armed).
    #[allow(clippy::too_many_arguments)]
    pub fn init_ride(
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
        instructions::init_ride::handler(
            ctx,
            session_id,
            session_key,
            market_id,
            feed_id,
            grip_mode,
            fuel_usd_6,
            max_lev_bps,
            loss_floor_6,
            expires_at,
        )
    }

    /// Delegate the ride PDA to the ER (explicit commit frequency).
    pub fn delegate_ride(
        ctx: Context<DelegateRide>,
        session_id: u64,
        commit_frequency_ms: u32,
    ) -> Result<()> {
        instructions::delegate_ride::handler(ctx, session_id, commit_frequency_ms)
    }

    /// Hot path (ER, session-signed): move virtual exposure toward `target_exp_bps`.
    pub fn tick(ctx: Context<Tick>, target_exp_bps: i32) -> Result<()> {
        instructions::tick::handler(ctx, target_exp_bps)
    }

    /// Ripcord (ER): flatten the virtual position (target 0).
    pub fn flatten(ctx: Context<Tick>) -> Result<()> {
        instructions::tick::handler(ctx, 0)
    }

    /// Guardian freeze (ER): stop-adding + mark floor breach.
    pub fn freeze(ctx: Context<Freeze>) -> Result<()> {
        instructions::freeze::handler(ctx)
    }

    /// End the ride (ER): commit final state to L1 and undelegate.
    pub fn request_settle(ctx: Context<RequestSettle>) -> Result<()> {
        instructions::request_settle::handler(ctx)
    }

    /// Close the ride PDA on L1 after undelegation (rent → owner).
    pub fn close_ride(ctx: Context<CloseRide>) -> Result<()> {
        instructions::close_ride::handler(ctx)
    }
}
