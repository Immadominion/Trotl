use anchor_lang::prelude::*;

/// PDA seed for a ride session: `["ride", owner, session_id_le]`.
pub const RIDE_SEED: &[u8] = b"ride";

/// Leverage hard ceiling enforced by the program (10x). UI defaults far lower.
pub const MAX_LEV_BPS_CEILING: u32 = 100_000; // 10.0000x
/// Minimum leverage (1x) — below this the analog control is meaningless.
pub const MIN_LEV_BPS: u32 = 10_000; // 1.0000x

/// Signed exposure deflection bounds.
pub const MAX_EXP_BPS: i32 = 10_000; // full long
pub const MIN_EXP_BPS: i32 = -10_000; // full short

/// Oracle staleness gate (seconds). Marks older than this freeze the needle honestly.
pub const MAX_ORACLE_STALENESS_SECS: i64 = 2;

/// MagicBlock real-time pricing oracle program (Pyth Lazer feeds, in the ER).
/// Account layout is `PriceUpdateV2`; parsed by byte offset in `oracle.rs`.
pub const ORACLE_PROGRAM_ID: Pubkey = pubkey!("PriCems5tHihc6UDXDjzjeawomAwBduWMGAi8ZUjppd");

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
