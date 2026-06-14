//! `RideSession` — the per-ride PDA state.
//!
//! Byte-for-byte identical to the Anchor `#[account(zero_copy)] #[repr(C)]` layout: a 264-byte dense
//! struct (descending alignment, explicit tail pad, no implicit padding) preceded by an 8-byte
//! account discriminator = 272 total. Pinned by the tests below + the cross-language Dart decoder.

use bytemuck::{Pod, Zeroable};
use pinocchio::account::{Ref, RefMut};
use pinocchio::error::ProgramError;
use pinocchio::AccountView;

use crate::constants::{ACCOUNT_DISCRIMINATOR, ID};

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct RideSession {
    // ── 8-byte aligned (10 × 8 = 80) ──
    pub session_id: u64,
    pub expires_at: i64,
    pub fuel_usd_6: u64,
    pub notional_usd_6: i64,
    pub entry_vwap_e9: u64,
    pub realized_pnl_6: i64,
    pub last_mark_e9: u64,
    pub last_mark_ts: i64,
    pub loss_floor_6: i64,
    pub tick_count: u64,

    // ── 4-byte (4 × 4 = 16) ──
    pub max_lev_bps: u32,
    pub target_exp_bps: i32,
    pub virt_exp_bps: i32,
    pub flags: u32,

    // ── 2-byte ──
    pub market_id: u16,

    // ── 1-byte (4) ──
    pub version: u8,
    pub bump: u8,
    pub status: u8,
    pub grip_mode: u8,

    // ── byte arrays (align 1) ──
    pub owner: [u8; 32],
    pub session_key: [u8; 32],
    pub feed_id: [u8; 32],

    /// Migration headroom — only widened, never repurposed.
    pub _reserved: [u8; 64],
    /// Tail pad → exactly 264 bytes (multiple of 8, no implicit padding).
    pub _pad_tail: [u8; 2],
}

impl RideSession {
    /// Struct length, excluding the 8-byte discriminator.
    pub const LEN: usize = core::mem::size_of::<RideSession>();
    /// Full account length (disc + struct).
    pub const ACCOUNT_LEN: usize = 8 + Self::LEN;
    /// Current schema version.
    pub const VERSION: u8 = 1;

    /// Borrow the struct immutably from an account (validates length + discriminator).
    pub fn load<'a>(account: &'a AccountView) -> Result<Ref<'a, RideSession>, ProgramError> {
        Self::check(account)?;
        let data = account.try_borrow()?;
        Ok(Ref::map(data, |d| {
            bytemuck::from_bytes::<RideSession>(&d[8..8 + RideSession::LEN])
        }))
    }

    /// Borrow the struct mutably from an account (validates length + discriminator).
    pub fn load_mut<'a>(account: &'a AccountView) -> Result<RefMut<'a, RideSession>, ProgramError> {
        Self::check(account)?;
        let data = account.try_borrow_mut()?;
        Ok(RefMut::map(data, |d| {
            bytemuck::from_bytes_mut::<RideSession>(&mut d[8..8 + RideSession::LEN])
        }))
    }

    /// Write the 8-byte discriminator into a freshly-created account (init only).
    pub fn write_discriminator(account: &AccountView) -> Result<(), ProgramError> {
        let mut data = account.try_borrow_mut()?;
        if data.len() < RideSession::ACCOUNT_LEN {
            return Err(ProgramError::AccountDataTooSmall);
        }
        data[..8].copy_from_slice(&ACCOUNT_DISCRIMINATOR);
        Ok(())
    }

    /// Borrow the struct mutably right after init (skips the discriminator check — it was just written).
    pub fn load_mut_unchecked<'a>(
        account: &'a AccountView,
    ) -> Result<RefMut<'a, RideSession>, ProgramError> {
        if account.data_len() < RideSession::ACCOUNT_LEN {
            return Err(ProgramError::AccountDataTooSmall);
        }
        let data = account.try_borrow_mut()?;
        Ok(RefMut::map(data, |d| {
            bytemuck::from_bytes_mut::<RideSession>(&mut d[8..8 + RideSession::LEN])
        }))
    }

    fn check(account: &AccountView) -> Result<(), ProgramError> {
        // Owner check (Anchor's `AccountLoader` does this): the account must be one of OUR PDAs.
        // Guards against type confusion — a look-alike owned by another program is rejected here,
        // before any field is read.
        if !account.owned_by(&ID) {
            return Err(ProgramError::InvalidAccountOwner);
        }
        if account.data_len() < RideSession::ACCOUNT_LEN {
            return Err(ProgramError::AccountDataTooSmall);
        }
        let data = account.try_borrow()?;
        if data[..8] != ACCOUNT_DISCRIMINATOR {
            return Err(ProgramError::InvalidAccountData);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_is_dense_264_aligned_8() {
        assert_eq!(core::mem::size_of::<RideSession>(), 264, "RideSession size drifted");
        assert_eq!(core::mem::align_of::<RideSession>(), 8, "RideSession alignment drifted");
        assert_eq!(RideSession::ACCOUNT_LEN, 272);
    }

    /// Pin the exact field offsets the Dart decoder reads (absolute, incl. the 8-byte disc).
    #[test]
    fn field_offsets_match_dart_decoder() {
        let base = core::mem::offset_of!(RideSession, session_id);
        assert_eq!(base, 0);
        let off = |o: usize| 8 + o; // Dart offsets include the discriminator
        assert_eq!(off(core::mem::offset_of!(RideSession, session_id)), 8);
        assert_eq!(off(core::mem::offset_of!(RideSession, expires_at)), 16);
        assert_eq!(off(core::mem::offset_of!(RideSession, fuel_usd_6)), 24);
        assert_eq!(off(core::mem::offset_of!(RideSession, notional_usd_6)), 32);
        assert_eq!(off(core::mem::offset_of!(RideSession, entry_vwap_e9)), 40);
        assert_eq!(off(core::mem::offset_of!(RideSession, realized_pnl_6)), 48);
        assert_eq!(off(core::mem::offset_of!(RideSession, last_mark_e9)), 56);
        assert_eq!(off(core::mem::offset_of!(RideSession, last_mark_ts)), 64);
        assert_eq!(off(core::mem::offset_of!(RideSession, loss_floor_6)), 72);
        assert_eq!(off(core::mem::offset_of!(RideSession, tick_count)), 80);
        assert_eq!(off(core::mem::offset_of!(RideSession, max_lev_bps)), 88);
        assert_eq!(off(core::mem::offset_of!(RideSession, target_exp_bps)), 92);
        assert_eq!(off(core::mem::offset_of!(RideSession, virt_exp_bps)), 96);
        assert_eq!(off(core::mem::offset_of!(RideSession, flags)), 100);
        assert_eq!(off(core::mem::offset_of!(RideSession, market_id)), 104);
        assert_eq!(off(core::mem::offset_of!(RideSession, version)), 106);
        assert_eq!(off(core::mem::offset_of!(RideSession, bump)), 107);
        assert_eq!(off(core::mem::offset_of!(RideSession, status)), 108);
        assert_eq!(off(core::mem::offset_of!(RideSession, grip_mode)), 109);
        assert_eq!(off(core::mem::offset_of!(RideSession, owner)), 110);
        assert_eq!(off(core::mem::offset_of!(RideSession, session_key)), 142);
        assert_eq!(off(core::mem::offset_of!(RideSession, feed_id)), 174);
    }
}
