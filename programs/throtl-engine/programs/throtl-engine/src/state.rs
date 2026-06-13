use anchor_lang::prelude::*;

/// Per-ride session state.
///
/// `zero_copy` + `repr(C)`: no per-tick (de)serialization cost (DR-1). The layout is **fully dense**
/// (no implicit padding — required for `bytemuck::Pod`) and pinned by the test below. Fields are
/// ordered by descending alignment (8-byte → 4 → 2 → 1 → byte arrays) with an explicit tail pad so
/// `size_of` is a multiple of 8 with zero implicit padding.
#[account(zero_copy)]
#[repr(C)]
pub struct RideSession {
    // ── 8-byte aligned (10 × 8 = 80 bytes) ─────────────────────────────────
    /// Client-chosen ride id; part of the PDA seeds.
    pub session_id: u64,
    /// Unix seconds; ticks rejected at/after this.
    pub expires_at: i64,
    /// Collateral budget deposited to the Flash Basket for this ride (usd_6).
    pub fuel_usd_6: u64,
    /// Signed virtual notional in USD (usd_6). Sign = side (+long / −short).
    pub notional_usd_6: i64,
    /// Entry VWAP of the open notional (price_e9).
    pub entry_vwap_e9: u64,
    /// Cumulative realized PnL (usd_6, saturating).
    pub realized_pnl_6: i64,
    /// Last oracle mark used (price_e9).
    pub last_mark_e9: u64,
    /// Unix seconds of last mark.
    pub last_mark_ts: i64,
    /// Loss floor — a negative bound on effective equity (usd_6).
    pub loss_floor_6: i64,
    /// Monotonic tick counter.
    pub tick_count: u64,

    // ── 4-byte aligned (4 × 4 = 16 bytes) ──────────────────────────────────
    /// Program-capped max leverage (bps; 20_000 = 2x … 100_000 = 10x).
    pub max_lev_bps: u32,
    /// Thumb target exposure (signed bps).
    pub target_exp_bps: i32,
    /// Confirmed settled virtual exposure (signed bps) — the needle.
    pub virt_exp_bps: i32,
    /// Bitfield (see `constants::flags`).
    pub flags: u32,

    // ── 2-byte ─────────────────────────────────────────────────────────────
    /// Index into the static market table (0 = SOL).
    pub market_id: u16,

    // ── 1-byte (4) ──────────────────────────────────────────────────────────
    pub version: u8,
    pub bump: u8,
    pub status: u8,
    pub grip_mode: u8,

    // ── byte arrays (align 1) ────────────────────────────────────────────────
    /// Parent wallet (authority).
    pub owner: Pubkey,
    /// In-app ephemeral session signer (DR-2 own-scheme).
    pub session_key: Pubkey,
    /// Pyth Lazer feed id; integrity-checked against the oracle PDA.
    pub feed_id: [u8; 32],

    /// Migration headroom — only widened, never repurposed (ARCHITECTURE §5).
    pub _reserved: [u8; 64],
    /// Tail pad so the struct is exactly 264 bytes (multiple of 8, no implicit padding).
    pub _pad_tail: [u8; 2],
}

impl RideSession {
    /// Account data length, excluding Anchor's 8-byte discriminator.
    pub const LEN: usize = core::mem::size_of::<RideSession>();
    /// Current state schema version.
    pub const VERSION: u8 = 1;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_is_dense_264_aligned_8() {
        // Pinned layout — a change here is a migration event (ARCHITECTURE §5).
        assert_eq!(
            core::mem::size_of::<RideSession>(),
            264,
            "RideSession size drifted"
        );
        assert_eq!(
            core::mem::align_of::<RideSession>(),
            8,
            "RideSession alignment drifted"
        );
        // 8(disc) + 264 = 272 bytes total account; sanity floor on rent expectations.
        assert_eq!(8 + RideSession::LEN, 272);
    }
}
