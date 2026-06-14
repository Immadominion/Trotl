//! Instruction handlers. Every account check Anchor did automatically is hand-coded here per the
//! security checklist: program-owner, `is_signer`, account-type discriminator, PDA seeds+bump,
//! the oracle's owner+feed+slice-bounds, and `mut`/writable expectations. The hot path (`tick`)
//! reuses the verbatim `math` + `oracle` modules, so the accounting is identical to the Anchor build.

use ephemeral_rollups_pinocchio::consts::{DELEGATION_PROGRAM_ID, MAGIC_CONTEXT_ID, MAGIC_PROGRAM_ID};
use ephemeral_rollups_pinocchio::instruction::{
    commit_and_undelegate_accounts, delegate_account, undelegate,
};
use ephemeral_rollups_pinocchio::types::DelegateConfig;
use pinocchio::cpi::{Seed, Signer};
use pinocchio::error::ProgramError;
use pinocchio::sysvars::clock::Clock;
use pinocchio::sysvars::rent::Rent;
use pinocchio::sysvars::Sysvar;
use pinocchio::{AccountView, Address, ProgramResult};
use pinocchio_system::instructions::CreateAccount;

use crate::constants::*;
use crate::error::ThrotlError;
use crate::state::RideSession;
use crate::{math, oracle, require};

// ── little-endian instruction-data readers (bounds-checked) ──────────────────
#[inline]
fn rd_u16(d: &[u8], o: usize) -> Result<u16, ProgramError> {
    d.get(o..o + 2)
        .and_then(|s| s.try_into().ok())
        .map(u16::from_le_bytes)
        .ok_or(ProgramError::InvalidInstructionData)
}
#[inline]
fn rd_u32(d: &[u8], o: usize) -> Result<u32, ProgramError> {
    d.get(o..o + 4)
        .and_then(|s| s.try_into().ok())
        .map(u32::from_le_bytes)
        .ok_or(ProgramError::InvalidInstructionData)
}
#[inline]
fn rd_i32(d: &[u8], o: usize) -> Result<i32, ProgramError> {
    d.get(o..o + 4)
        .and_then(|s| s.try_into().ok())
        .map(i32::from_le_bytes)
        .ok_or(ProgramError::InvalidInstructionData)
}
#[inline]
fn rd_u64(d: &[u8], o: usize) -> Result<u64, ProgramError> {
    d.get(o..o + 8)
        .and_then(|s| s.try_into().ok())
        .map(u64::from_le_bytes)
        .ok_or(ProgramError::InvalidInstructionData)
}
#[inline]
fn rd_i64(d: &[u8], o: usize) -> Result<i64, ProgramError> {
    d.get(o..o + 8)
        .and_then(|s| s.try_into().ok())
        .map(i64::from_le_bytes)
        .ok_or(ProgramError::InvalidInstructionData)
}
#[inline]
fn rd_pubkey(d: &[u8], o: usize) -> Result<[u8; 32], ProgramError> {
    d.get(o..o + 32)
        .and_then(|s| s.try_into().ok())
        .ok_or(ProgramError::InvalidInstructionData)
}

// ── 0. init_ride (L1) ────────────────────────────────────────────────────────
// accounts: [ride(w), owner(w, signer), system]
// data: session_id u64 | session_key 32 | market_id u16 | feed_id 32 | grip_mode u8
//       | fuel_usd_6 u64 | max_lev_bps u32 | loss_floor_6 i64 | expires_at i64
pub fn init_ride(accounts: &[AccountView], data: &[u8]) -> ProgramResult {
    let [ride, owner, system] = accounts else {
        return Err(ProgramError::NotEnoughAccountKeys);
    };

    let session_id = rd_u64(data, 0)?;
    let session_key = rd_pubkey(data, 8)?;
    let market_id = rd_u16(data, 40)?;
    let feed_id = rd_pubkey(data, 42)?;
    let grip_mode = *data.get(74).ok_or(ProgramError::InvalidInstructionData)?;
    let fuel_usd_6 = rd_u64(data, 75)?;
    let max_lev_bps = rd_u32(data, 83)?;
    let loss_floor_6 = rd_i64(data, 87)?;
    let expires_at = rd_i64(data, 95)?;

    // ── arg validation (Anchor `require!`s) ──
    require!(fuel_usd_6 > 0, ThrotlError::InvalidFuel);
    require!(max_lev_bps <= MAX_LEV_BPS_CEILING, ThrotlError::LeverageTooHigh);
    require!(max_lev_bps >= MIN_LEV_BPS, ThrotlError::LeverageTooLow);
    require!(loss_floor_6 < 0, ThrotlError::InvalidLossFloor);
    require!(grip_mode <= grip::CRUISE, ThrotlError::InvalidGripMode);
    let now = Clock::get()?.unix_timestamp;
    require!(expires_at > now, ThrotlError::SessionExpired);
    // Cap the session lifetime so a client can't mint a never-expiring gasless key (L2).
    require!(
        expires_at <= now.saturating_add(MAX_SESSION_TTL_SECS),
        ThrotlError::SessionTtlTooLong
    );

    // ── account checks (Anchor: Signer / mut / Program<System>) ──
    require!(owner.is_signer(), ThrotlError::UnauthorizedSigner);
    require!(owner.is_writable(), ThrotlError::InvalidStatus);
    require!(ride.is_writable(), ThrotlError::InvalidStatus);
    require!(system.address() == &pinocchio_system::ID, ThrotlError::InvalidStatus);

    // ── PDA derivation + canonical bump (Anchor `seeds`/`bump`) ──
    let session_le = session_id.to_le_bytes();
    let (pda, bump) =
        Address::find_program_address(&[RIDE_SEED, owner.address().as_ref(), &session_le], &ID);
    require!(&pda == ride.address(), ThrotlError::PdaMismatch);

    // ── create the account (Anchor `init`) ──
    let rent = Rent::get()?;
    let lamports = rent.try_minimum_balance(RideSession::ACCOUNT_LEN)?;
    let bump_arr = [bump];
    let create_seeds = [
        Seed::from(RIDE_SEED),
        Seed::from(owner.address().as_ref()),
        Seed::from(session_le.as_ref()),
        Seed::from(bump_arr.as_ref()),
    ];
    CreateAccount {
        from: owner,
        to: ride,
        lamports,
        space: RideSession::ACCOUNT_LEN as u64,
        owner: &ID,
    }
    .invoke_signed(&[Signer::from(&create_seeds)])?;

    // ── write the discriminator + initialize state ──
    RideSession::write_discriminator(ride)?;
    let mut r = RideSession::load_mut_unchecked(ride)?;
    r.version = RideSession::VERSION;
    r.bump = bump;
    r.status = status::ARMED;
    r.grip_mode = grip_mode;
    r.market_id = market_id;
    r.owner = *owner.address().as_array();
    r.session_key = session_key;
    r.feed_id = feed_id;
    r.session_id = session_id;
    r.expires_at = expires_at;
    r.fuel_usd_6 = fuel_usd_6;
    r.max_lev_bps = max_lev_bps;
    r.loss_floor_6 = loss_floor_6;
    Ok(())
}

// ── 1. delegate_ride (L1) ────────────────────────────────────────────────────
// accounts (client order): [owner(w,signer), buffer(w), delegation_record(w), delegation_metadata(w),
//   ride(w), owner_program(=ID), dlp, system, validator?]
// data: session_id u64 | commit_frequency_ms u32
pub fn delegate_ride(accounts: &[AccountView], data: &[u8]) -> ProgramResult {
    let [owner, buffer, delegation_record, delegation_metadata, ride, owner_program, _dlp, system, rest @ ..] =
        accounts
    else {
        return Err(ProgramError::NotEnoughAccountKeys);
    };

    let session_id = rd_u64(data, 0)?;
    let commit_frequency_ms = rd_u32(data, 8)?;

    require!(owner.is_signer(), ThrotlError::UnauthorizedSigner);

    let session_le = session_id.to_le_bytes();
    let (pda, bump) =
        Address::find_program_address(&[RIDE_SEED, owner.address().as_ref(), &session_le], &ID);
    require!(&pda == ride.address(), ThrotlError::PdaMismatch);
    // The delegated account's new owner-program MUST be us (Anchor's `#[delegate]` hardcoded this).
    // Otherwise undelegation would route to an attacker-supplied program.
    require!(owner_program.address() == &ID, ThrotlError::PdaMismatch);

    let validator = rest.first().map(|a| *a.address());
    delegate_account(
        &[owner, ride, owner_program, buffer, delegation_record, delegation_metadata, system],
        &[RIDE_SEED, owner.address().as_ref(), &session_le],
        bump,
        DelegateConfig {
            commit_frequency_ms,
            validator,
        },
    )
}

// ── 2/3. tick / flatten (ER, session-signed) ─────────────────────────────────
// accounts: [ride(w), price_feed, session_signer(signer)]
pub fn tick(accounts: &[AccountView], data: &[u8]) -> ProgramResult {
    let target_exp_bps = rd_i32(data, 0)?;
    tick_inner(accounts, target_exp_bps)
}
pub fn flatten(accounts: &[AccountView]) -> ProgramResult {
    tick_inner(accounts, 0)
}

fn tick_inner(accounts: &[AccountView], target_exp_bps: i32) -> ProgramResult {
    let [ride, price_feed, session_signer] = accounts else {
        return Err(ProgramError::NotEnoughAccountKeys);
    };

    require!(
        (MIN_EXP_BPS..=MAX_EXP_BPS).contains(&target_exp_bps),
        ThrotlError::ExposureOutOfBounds
    );
    let now = Clock::get()?.unix_timestamp;
    let mut r = RideSession::load_mut(ride)?;

    // authz: only the registered session key may tick
    require!(session_signer.is_signer(), ThrotlError::UnauthorizedSigner);
    require!(
        session_signer.address().as_array() == &r.session_key,
        ThrotlError::UnauthorizedSigner
    );

    // PDA integrity: re-derive from stored owner/session_id/bump
    let session_le = r.session_id.to_le_bytes();
    let bump_arr = [r.bump];
    let expected =
        Address::create_program_address(&[RIDE_SEED, &r.owner, &session_le, &bump_arr], &ID)
            .map_err(|_| ThrotlError::PdaMismatch)?;
    require!(&expected == ride.address(), ThrotlError::PdaMismatch);

    require!(
        r.status == status::ARMED || r.status == status::RIDING,
        ThrotlError::InvalidStatus
    );
    require!(now < r.expires_at, ThrotlError::SessionExpired);

    // oracle read (honest needle-freeze on staleness)
    let feed_id = r.feed_id;
    let mark = match oracle::read_oracle(price_feed, &feed_id, now) {
        Ok(p) => {
            r.flags &= !flags::ORACLE_STALE;
            p.price_e9
        }
        Err(_) => {
            r.flags |= flags::ORACLE_STALE;
            r.target_exp_bps = target_exp_bps;
            r.tick_count = r.tick_count.saturating_add(1);
            return Ok(());
        }
    };

    // effective equity / floor gating
    let unreal = math::unrealized_pnl_6(r.notional_usd_6, r.entry_vwap_e9, mark);
    let eff_eq = math::effective_equity_6(r.fuel_usd_6, r.realized_pnl_6, unreal);
    let eff_coll = math::effective_collateral_6(r.fuel_usd_6, r.realized_pnl_6);

    if eff_eq <= r.loss_floor_6 {
        r.flags |= flags::FLOOR_BREACHED;
    }
    if eff_eq <= 0 {
        r.flags |= flags::BANKRUPT;
    }
    let breached = eff_eq <= r.loss_floor_6;
    let bankrupt = eff_eq <= 0;

    let mut target_notional = math::target_notional_6(eff_coll, r.max_lev_bps, target_exp_bps);
    if breached || bankrupt {
        let cur_abs = r.notional_usd_6.unsigned_abs();
        if target_notional.unsigned_abs() > cur_abs {
            target_notional = r.notional_usd_6;
        }
    }

    let s = math::settle_to_target(r.notional_usd_6, r.entry_vwap_e9, target_notional, mark);
    r.realized_pnl_6 = r.realized_pnl_6.saturating_add(s.realized_delta_6);
    r.notional_usd_6 = s.new_notional_6;
    r.entry_vwap_e9 = s.new_vwap_e9;
    r.target_exp_bps = target_exp_bps;
    r.virt_exp_bps = math::notional_to_bps(s.new_notional_6, eff_coll, r.max_lev_bps);
    r.last_mark_e9 = mark;
    r.last_mark_ts = now;
    r.tick_count = r.tick_count.saturating_add(1);
    if r.status == status::ARMED {
        r.status = status::RIDING;
    }
    Ok(())
}

// ── 4. freeze (ER) ───────────────────────────────────────────────────────────
// accounts: [ride(w), authority(signer)]
pub fn freeze(accounts: &[AccountView]) -> ProgramResult {
    let [ride, authority] = accounts else {
        return Err(ProgramError::NotEnoughAccountKeys);
    };
    let mut r = RideSession::load_mut(ride)?;
    require!(authority.is_signer(), ThrotlError::UnauthorizedSigner);
    require!(
        authority.address().as_array() == &r.owner
            || authority.address().as_array() == &r.session_key,
        ThrotlError::UnauthorizedSigner
    );
    require!(
        r.status == status::RIDING || r.status == status::ARMED,
        ThrotlError::InvalidStatus
    );
    r.status = status::FROZEN;
    r.target_exp_bps = 0;
    r.flags |= flags::FLOOR_BREACHED;
    Ok(())
}

// ── 5. request_settle (ER) — commit + undelegate ─────────────────────────────
// accounts: [payer(w,signer), ride(w), magic_program, magic_context(w)]
pub fn request_settle(accounts: &[AccountView]) -> ProgramResult {
    let [payer, ride, magic_program, magic_context] = accounts else {
        return Err(ProgramError::NotEnoughAccountKeys);
    };

    // Pin the MagicBlock accounts (Anchor's `#[commit]` injected fixed ones): a forged magic_program
    // would otherwise receive a CPI carrying the payer's signature.
    require!(magic_program.address() == &MAGIC_PROGRAM_ID, ThrotlError::InvalidStatus);
    require!(magic_context.address() == &MAGIC_CONTEXT_ID, ThrotlError::InvalidStatus);

    {
        let mut r = RideSession::load_mut(ride)?;
        require!(payer.is_signer(), ThrotlError::UnauthorizedSigner);
        require!(
            payer.address().as_array() == &r.owner || payer.address().as_array() == &r.session_key,
            ThrotlError::UnauthorizedSigner
        );
        r.status = status::SETTLING;
        // RefMut dropped here so the buffer is free for the commit CPI.
    }

    commit_and_undelegate_accounts(
        payer,
        core::slice::from_ref(ride),
        magic_context,
        magic_program,
        None,
        None,
    )
}

// ── 6. process_undelegation (DLP-injected) ───────────────────────────────────
// The delegation program calls this on undelegation. accounts: [delegated_pda(w), buffer, payer(w), system]
// data: the serialized seeds (callback args).
pub fn process_undelegation(accounts: &[AccountView], data: &[u8]) -> ProgramResult {
    let [delegated, buffer, payer, _system] = accounts else {
        return Err(ProgramError::NotEnoughAccountKeys);
    };

    // AUTHORIZATION — this callback may ONLY be driven by the MagicBlock delegation program (DLP).
    // The ER SDK's `undelegate` gates solely on `buffer.is_signer()`, which an attacker satisfies
    // with their OWN keypair; `undelegate` then `CreateAccount`s the caller-named `delegated` PDA
    // from caller-supplied seeds and copies the caller-controlled `buffer` bytes in — forging a
    // program-owned RideSession with arbitrary fields at any not-yet-existing ride PDA, bypassing
    // every `init_ride` invariant. The genuine undelegation buffer is the DLP's `undelegate-buffer`
    // PDA, which is OWNED BY the delegation program; a system-owned forged buffer is rejected here.
    require!(buffer.owned_by(&DELEGATION_PROGRAM_ID), ThrotlError::UnauthorizedSigner);

    undelegate(delegated, &ID, buffer, payer, data)
}

// ── 7. close_ride (L1, after undelegation) ───────────────────────────────────
// accounts: [ride(w), owner(w, signer)]
pub fn close_ride(accounts: &[AccountView]) -> ProgramResult {
    let [ride, owner] = accounts else {
        return Err(ProgramError::NotEnoughAccountKeys);
    };
    require!(owner.is_signer(), ThrotlError::UnauthorizedSigner);

    {
        let r = RideSession::load(ride)?;
        require!(&r.owner == owner.address().as_array(), ThrotlError::UnauthorizedSigner);
        require!(
            r.status == status::SETTLING || r.status == status::CLOSED,
            ThrotlError::InvalidStatus
        );
    }
    // Must be owned by this program again (i.e. undelegation ran) to be closable here.
    require!(ride.owned_by(&ID), ThrotlError::InvalidStatus);

    // Close: rent → owner, zero data, hand back to the system program.
    let refund = ride.lamports();
    owner.set_lamports(owner.lamports().saturating_add(refund));
    ride.set_lamports(0);
    {
        let mut d = ride.try_borrow_mut()?;
        for b in d.iter_mut() {
            *b = 0;
        }
    }
    ride.resize(0)?;
    unsafe { ride.assign(&pinocchio_system::ID) };
    Ok(())
}
