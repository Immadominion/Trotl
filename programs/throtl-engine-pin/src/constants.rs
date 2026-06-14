//! Program constants — IDs, seeds, status/grip/flags, and the **wire-contract discriminators**.
//!
//! The instruction + account discriminators are the exact Anchor `sha256("global:<ix>")[..8]` /
//! `sha256("account:RideSession")[..8]` values, so the Dart client (`throtl_chain`) is byte-for-byte
//! compatible with this Pinocchio build — no client change needed.

use pinocchio::Address;
use pinocchio_pubkey::pubkey;

/// This program's id (same as the Anchor build → deploys to the same address).
pub const ID: Address =
    Address::new_from_array(pubkey!("YSaqfuc753DkHZoaEvdNMSTQTf4hEuTtP65hszuvJy9"));

/// MagicBlock real-time pricing oracle program (Pyth Lazer feeds, in the ER).
pub const ORACLE_PROGRAM_ID: Address =
    Address::new_from_array(pubkey!("PriCems5tHihc6UDXDjzjeawomAwBduWMGAi8ZUjppd"));

/// PDA seed for a ride session: `["ride", owner, session_id_le]`.
pub const RIDE_SEED: &[u8] = b"ride";

/// Leverage hard ceiling (10x) / floor (1x).
pub const MAX_LEV_BPS_CEILING: u32 = 100_000;
pub const MIN_LEV_BPS: u32 = 10_000;

/// Signed exposure deflection bounds.
pub const MAX_EXP_BPS: i32 = 10_000;
pub const MIN_EXP_BPS: i32 = -10_000;

/// Oracle staleness gate (seconds).
pub const MAX_ORACLE_STALENESS_SECS: i64 = 2;

/// Max gasless session lifetime (seconds) — caps `expires_at` so a client can't mint a
/// never-expiring session key. The live client uses 1h; 24h is a generous ceiling.
pub const MAX_SESSION_TTL_SECS: i64 = 86_400;

/// Ride lifecycle status byte.
pub mod status {
    pub const INIT: u8 = 0;
    pub const ARMED: u8 = 1;
    pub const RIDING: u8 = 2;
    pub const FROZEN: u8 = 3;
    pub const SETTLING: u8 = 4;
    pub const CLOSED: u8 = 5;
}

/// Grip mode byte.
pub mod grip {
    pub const HOLD: u8 = 0;
    pub const CRUISE: u8 = 1;
}

/// `flags` bitfield.
pub mod flags {
    pub const FLOOR_BREACHED: u32 = 1 << 0;
    pub const ORACLE_STALE: u32 = 1 << 1;
    pub const BANKRUPT: u32 = 1 << 2;
}

/// Instruction discriminators — Anchor `sha256("global:<name>")[..8]`, verified against `throtl_chain`.
pub mod ix {
    pub const INIT_RIDE: [u8; 8] = [105, 93, 93, 113, 45, 198, 67, 138];
    pub const DELEGATE_RIDE: [u8; 8] = [120, 181, 14, 35, 87, 76, 219, 155];
    pub const TICK: [u8; 8] = [92, 79, 44, 8, 101, 80, 63, 15];
    pub const FLATTEN: [u8; 8] = [168, 198, 178, 236, 15, 112, 146, 10];
    pub const FREEZE: [u8; 8] = [255, 91, 207, 84, 251, 194, 254, 63];
    pub const REQUEST_SETTLE: [u8; 8] = [90, 16, 38, 40, 222, 168, 193, 70];
    pub const CLOSE_RIDE: [u8; 8] = [200, 238, 85, 191, 109, 87, 100, 89];
    /// Injected by the delegation program (DLP) on undelegation. Matches
    /// `ephemeral_rollups_pinocchio::consts::EXTERNAL_UNDELEGATE_DISCRIMINATOR`.
    pub const PROCESS_UNDELEGATION: [u8; 8] = [196, 28, 41, 206, 48, 37, 51, 167];
}

/// `sha256("account:RideSession")[..8]` — written as the 8-byte account prefix so the on-chain
/// account is byte-identical to the Anchor build (the Dart decoder reads the struct at offset 8).
pub const ACCOUNT_DISCRIMINATOR: [u8; 8] = [192, 184, 204, 161, 88, 215, 78, 121];
