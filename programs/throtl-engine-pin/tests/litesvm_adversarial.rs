//! Adversarial security suite — runs the **real compiled `.so`** inside litesvm and proves the
//! program's security properties by *executing the attacks* and asserting they are rejected (or, for
//! the oracle, that the needle honestly freezes). This is the audit's evidence layer: every check in
//! `instructions.rs` / `state.rs` / `oracle.rs` has a test that breaks it on purpose.
//!
//! Run `cargo build-sbf` first (litesvm loads the prebuilt `.so`), then `cargo test`.
//!
//! Coverage:
//!   C1  process_undelegation forged-buffer (account-forgery) — REJECTED by the DLP-owner gate.
//!   init_ride arg guards: leverage hi/lo, zero fuel, non-neg loss floor, bad grip, expired, bad PDA.
//!   tick guards: exposure bounds, expired session, type confusion (foreign-owned ride).
//!   oracle honesty: wrong owner / wrong feed / stale → needle FREEZES (ORACLE_STALE), notional held.
//!   close guards: before-settle, non-owner, while-delegated; and the positive owner-settling close.
//!   freeze guards: imposter rejected; frozen ride can no longer tick.

#![allow(clippy::result_large_err)]

use bytemuck::Zeroable;
use litesvm::LiteSVM;
use solana_account::Account;
use solana_clock::Clock;
use solana_instruction::{AccountMeta, Instruction};
use solana_keypair::Keypair;
use solana_pubkey::{pubkey, Pubkey};
use solana_signer::Signer;
use solana_transaction::Transaction;

use throtl_engine_pin::constants::{flags, grip, ix, status};
use throtl_engine_pin::state::RideSession;

const ID: Pubkey = pubkey!("YSaqfuc753DkHZoaEvdNMSTQTf4hEuTtP65hszuvJy9");
const ORACLE_PROGRAM_ID: Pubkey = pubkey!("PriCems5tHihc6UDXDjzjeawomAwBduWMGAi8ZUjppd");
const DELEGATION_PROGRAM_ID: Pubkey = pubkey!("DELeGGvXpWV2fqJUhqcF5ZSYMS4JTLjteaAMARRSaeSh");
const SYSTEM_PROGRAM_ID: Pubkey = pubkey!("11111111111111111111111111111111");
const RIDE_SEED: &[u8] = b"ride";
const SO_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/target/deploy/throtl_engine_pin.so");

const NOW: i64 = 1_800_000_000;

// ── harness ──────────────────────────────────────────────────────────────────
fn setup() -> (LiteSVM, Keypair) {
    let mut svm = LiteSVM::new();
    svm.add_program_from_file(ID, SO_PATH)
        .expect("load throtl_engine_pin.so — run `cargo build-sbf` first");
    set_clock(&mut svm, NOW);
    let owner = Keypair::new();
    svm.airdrop(&owner.pubkey(), 10_000_000_000).unwrap();
    (svm, owner)
}

fn set_clock(svm: &mut LiteSVM, ts: i64) {
    svm.set_sysvar(&Clock {
        unix_timestamp: ts,
        ..Default::default()
    });
}

fn ride_pda(owner: &Pubkey, session_id: u64) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[RIDE_SEED, owner.as_ref(), &session_id.to_le_bytes()], &ID)
}

#[allow(clippy::too_many_arguments)]
fn init_data(
    session_id: u64,
    session_key: &Pubkey,
    market_id: u16,
    feed_id: [u8; 32],
    grip_mode: u8,
    fuel_usd_6: u64,
    max_lev_bps: u32,
    loss_floor_6: i64,
    expires_at: i64,
) -> Vec<u8> {
    let mut d = Vec::with_capacity(8 + 103);
    d.extend_from_slice(&ix::INIT_RIDE);
    d.extend_from_slice(&session_id.to_le_bytes());
    d.extend_from_slice(session_key.as_ref());
    d.extend_from_slice(&market_id.to_le_bytes());
    d.extend_from_slice(&feed_id);
    d.push(grip_mode);
    d.extend_from_slice(&fuel_usd_6.to_le_bytes());
    d.extend_from_slice(&max_lev_bps.to_le_bytes());
    d.extend_from_slice(&loss_floor_6.to_le_bytes());
    d.extend_from_slice(&expires_at.to_le_bytes());
    d
}

/// A sane default init payload; per-test overrides via the closure.
#[allow(clippy::too_many_arguments)]
fn init_ix(owner: &Pubkey, ride: Pubkey, data: Vec<u8>) -> Instruction {
    Instruction {
        program_id: ID,
        accounts: vec![
            AccountMeta::new(ride, false),
            AccountMeta::new(*owner, true),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
        data,
    }
}

fn oracle_account(feed_id: [u8; 32], mantissa: i64, expo: i32, publish_time: i64, owner: Pubkey) -> Account {
    let mut data = vec![0u8; 101];
    data[41..73].copy_from_slice(&feed_id);
    data[73..81].copy_from_slice(&mantissa.to_le_bytes());
    data[89..93].copy_from_slice(&expo.to_le_bytes());
    data[93..101].copy_from_slice(&publish_time.to_le_bytes());
    Account {
        lamports: 10_000_000,
        data,
        owner,
        executable: false,
        rent_epoch: u64::MAX,
    }
}

fn decode(data: &[u8]) -> RideSession {
    *bytemuck::from_bytes::<RideSession>(&data[8..8 + RideSession::LEN])
}

/// Build a 272-byte program-owned RideSession account in a chosen state (for close/freeze/type tests).
#[allow(clippy::too_many_arguments)]
fn fabricated_ride(owner: Pubkey, account_owner: Pubkey, session_id: u64, bump: u8, status_byte: u8) -> Account {
    let mut r = RideSession::zeroed();
    r.session_id = session_id;
    r.version = RideSession::VERSION;
    r.bump = bump;
    r.status = status_byte;
    r.owner = owner.to_bytes();
    r.session_key = owner.to_bytes();
    r.fuel_usd_6 = 500_000_000;
    r.max_lev_bps = 100_000;
    r.loss_floor_6 = -200_000_000;
    r.expires_at = NOW + 3600;
    let mut data = vec![0u8; RideSession::ACCOUNT_LEN];
    data[..8].copy_from_slice(&throtl_engine_pin::constants::ACCOUNT_DISCRIMINATOR);
    data[8..].copy_from_slice(bytemuck::bytes_of(&r));
    Account {
        lamports: 5_000_000,
        data,
        owner: account_owner,
        executable: false,
        rent_epoch: u64::MAX,
    }
}

fn tx(svm: &mut LiteSVM, ixs: &[Instruction], signers: &[&Keypair], payer: &Pubkey) -> bool {
    let t = Transaction::new_signed_with_payer(ixs, Some(payer), signers, svm.latest_blockhash());
    svm.send_transaction(t).is_ok()
}

/// Init a normal ARMED ride; returns its PDA.
fn init_ride(svm: &mut LiteSVM, owner: &Keypair, session_id: u64, session_key: &Pubkey, feed: [u8; 32]) -> Pubkey {
    let (ride, _) = ride_pda(&owner.pubkey(), session_id);
    let data = init_data(session_id, session_key, 0, feed, grip::HOLD, 500_000_000, 100_000, -200_000_000, NOW + 3600);
    assert!(tx(svm, &[init_ix(&owner.pubkey(), ride, data)], &[owner], &owner.pubkey()), "init should succeed");
    ride
}

fn tick_ix(ride: Pubkey, price_feed: Pubkey, session: &Pubkey, target_bps: i32) -> Instruction {
    let mut d = Vec::with_capacity(12);
    d.extend_from_slice(&ix::TICK);
    d.extend_from_slice(&target_bps.to_le_bytes());
    Instruction {
        program_id: ID,
        accounts: vec![
            AccountMeta::new(ride, false),
            AccountMeta::new_readonly(price_feed, false),
            AccountMeta::new_readonly(*session, true),
        ],
        data: d,
    }
}

// ── C1: process_undelegation account-forgery — the headline finding ───────────
//
// An attacker calls `process_undelegation` directly on L1 with their OWN keypair as `buffer`
// (is_signer = true, but system-owned), valid ride seeds, and a crafted 272-byte RideSession in the
// buffer claiming i64::MAX realized PnL. Pre-fix this minted a program-owned, authentic-looking ride
// that bypassed every init guard. The DLP-owner gate now rejects it.
#[test]
fn c1_process_undelegation_rejects_forged_buffer() {
    let (mut svm, attacker) = setup();
    let session_id = 1234u64;
    let (ride, _bump) = ride_pda(&attacker.pubkey(), session_id);

    // Crafted forge payload: a RideSession claiming a massive payout, owner = attacker.
    let mut forged = RideSession::zeroed();
    forged.version = RideSession::VERSION;
    forged.status = status::SETTLING;
    forged.owner = attacker.pubkey().to_bytes();
    forged.session_key = attacker.pubkey().to_bytes();
    forged.realized_pnl_6 = i64::MAX; // "I made all the money"
    forged.fuel_usd_6 = 500_000_000;
    let mut buf_data = vec![0u8; RideSession::ACCOUNT_LEN];
    buf_data[..8].copy_from_slice(&throtl_engine_pin::constants::ACCOUNT_DISCRIMINATOR);
    buf_data[8..].copy_from_slice(bytemuck::bytes_of(&forged));

    // Attacker-owned buffer: a keypair they can SIGN for, but system-owned (NOT the DLP's PDA).
    let buffer = Keypair::new();
    svm.set_account(
        buffer.pubkey(),
        Account { lamports: 5_000_000, data: buf_data, owner: SYSTEM_PROGRAM_ID, executable: false, rent_epoch: u64::MAX },
    )
    .unwrap();

    // callback_args = serialized seeds ["ride", attacker, session_le] in the SDK's u32-len framing.
    let mut data = Vec::new();
    data.extend_from_slice(&ix::PROCESS_UNDELEGATION);
    data.extend_from_slice(&3u32.to_le_bytes());
    data.extend_from_slice(&(RIDE_SEED.len() as u32).to_le_bytes());
    data.extend_from_slice(RIDE_SEED);
    data.extend_from_slice(&32u32.to_le_bytes());
    data.extend_from_slice(attacker.pubkey().as_ref());
    data.extend_from_slice(&8u32.to_le_bytes());
    data.extend_from_slice(&session_id.to_le_bytes());

    let forge = Instruction {
        program_id: ID,
        accounts: vec![
            AccountMeta::new(ride, false),
            AccountMeta::new(buffer.pubkey(), true), // forged buffer, signed
            AccountMeta::new(attacker.pubkey(), true),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
        data,
    };

    let ok = tx(&mut svm, &[forge], &[&attacker, &buffer], &attacker.pubkey());
    assert!(!ok, "forged-buffer process_undelegation MUST be rejected (DLP-owner gate)");
    assert!(svm.get_account(&ride).map(|a| a.data.is_empty() || a.owner == SYSTEM_PROGRAM_ID).unwrap_or(true),
        "no program-owned ride may exist after a rejected forge");
}

// ── init_ride argument guards ─────────────────────────────────────────────────
fn try_init(svm: &mut LiteSVM, owner: &Keypair, sid: u64, mut_data: impl FnOnce(&mut (u64, u32, i64, u8, i64))) -> bool {
    let (ride, _) = ride_pda(&owner.pubkey(), sid);
    let sk = Keypair::new();
    // (fuel, max_lev, loss_floor, grip, expires)
    let mut p = (500_000_000u64, 100_000u32, -200_000_000i64, grip::HOLD, NOW + 3600);
    mut_data(&mut p);
    let data = init_data(sid, &sk.pubkey(), 0, [1u8; 32], p.3, p.0, p.1, p.2, p.4);
    tx(svm, &[init_ix(&owner.pubkey(), ride, data)], &[owner], &owner.pubkey())
}

#[test]
fn init_rejects_leverage_too_high() {
    let (mut svm, o) = setup();
    assert!(!try_init(&mut svm, &o, 1, |p| p.1 = 100_001), "max_lev > 10x must reject");
}
#[test]
fn init_rejects_leverage_too_low() {
    let (mut svm, o) = setup();
    assert!(!try_init(&mut svm, &o, 2, |p| p.1 = 9_999), "max_lev < 1x must reject");
}
#[test]
fn init_rejects_zero_fuel() {
    let (mut svm, o) = setup();
    assert!(!try_init(&mut svm, &o, 3, |p| p.0 = 0), "zero fuel must reject");
}
#[test]
fn init_rejects_nonneg_loss_floor() {
    let (mut svm, o) = setup();
    assert!(!try_init(&mut svm, &o, 4, |p| p.2 = 0), "loss_floor >= 0 must reject");
}
#[test]
fn init_rejects_bad_grip() {
    let (mut svm, o) = setup();
    assert!(!try_init(&mut svm, &o, 5, |p| p.3 = 99), "grip > CRUISE must reject");
}
#[test]
fn init_rejects_expired() {
    let (mut svm, o) = setup();
    assert!(!try_init(&mut svm, &o, 6, |p| p.4 = NOW - 1), "expires_at <= now must reject");
}

#[test]
fn init_rejects_wrong_pda() {
    let (mut svm, owner) = setup();
    // Pass a random account that is NOT the derived ride PDA.
    let wrong = Pubkey::new_unique();
    let sk = Keypair::new();
    let data = init_data(7, &sk.pubkey(), 0, [1u8; 32], grip::HOLD, 500_000_000, 100_000, -200_000_000, NOW + 3600);
    assert!(!tx(&mut svm, &[init_ix(&owner.pubkey(), wrong, data)], &[&owner], &owner.pubkey()),
        "init with a non-canonical ride account must reject (PdaMismatch)");
}

// ── tick guards ───────────────────────────────────────────────────────────────
#[test]
fn tick_rejects_exposure_out_of_bounds() {
    let (mut svm, owner) = setup();
    let sk = Keypair::new();
    let feed = [9u8; 32];
    let ride = init_ride(&mut svm, &owner, 10, &sk.pubkey(), feed);
    let pf = Pubkey::new_unique();
    svm.set_account(pf, oracle_account(feed, 6_786_596_052, 8, NOW, ORACLE_PROGRAM_ID)).unwrap();
    assert!(!tx(&mut svm, &[tick_ix(ride, pf, &sk.pubkey(), 20_000)], &[&owner, &sk], &owner.pubkey()),
        "target_exp_bps out of [-10000,10000] must reject");
}

#[test]
fn tick_rejects_expired_session() {
    let (mut svm, owner) = setup();
    let sk = Keypair::new();
    let feed = [9u8; 32];
    let ride = init_ride(&mut svm, &owner, 11, &sk.pubkey(), feed);
    let pf = Pubkey::new_unique();
    set_clock(&mut svm, NOW + 4000); // past expires_at (NOW + 3600)
    svm.set_account(pf, oracle_account(feed, 6_786_596_052, 8, NOW + 4000, ORACLE_PROGRAM_ID)).unwrap();
    assert!(!tx(&mut svm, &[tick_ix(ride, pf, &sk.pubkey(), 5000)], &[&owner, &sk], &owner.pubkey()),
        "tick after expires_at must reject (SessionExpired)");
}

#[test]
fn tick_rejects_type_confusion_foreign_owned_ride() {
    let (mut svm, owner) = setup();
    let (ride, bump) = ride_pda(&owner.pubkey(), 12);
    // A look-alike RideSession (right discriminator) but owned by a DIFFERENT program.
    let foreign = Pubkey::new_unique();
    svm.set_account(ride, fabricated_ride(owner.pubkey(), foreign, 12, bump, status::RIDING)).unwrap();
    let pf = Pubkey::new_unique();
    svm.set_account(pf, oracle_account([9u8; 32], 6_786_596_052, 8, NOW, ORACLE_PROGRAM_ID)).unwrap();
    assert!(!tx(&mut svm, &[tick_ix(ride, pf, &owner.pubkey(), 5000)], &[&owner], &owner.pubkey()),
        "a foreign-owned look-alike must reject (InvalidAccountOwner)");
}

// ── oracle honesty: bad reads FREEZE the needle, they do not corrupt PnL ───────
fn assert_needle_frozen(svm: &mut LiteSVM, owner: &Keypair, sk: &Keypair, ride: Pubkey, pf: Pubkey) {
    let ok = tx(svm, &[tick_ix(ride, pf, &sk.pubkey(), 5000)], &[owner, sk], &owner.pubkey());
    assert!(ok, "tick with a bad oracle should NOT fail the tx — it freezes the needle");
    let r = decode(&svm.get_account(&ride).unwrap().data);
    assert_ne!(r.flags & flags::ORACLE_STALE, 0, "ORACLE_STALE must be set");
    assert_eq!(r.notional_usd_6, 0, "notional must be held (no settle on a frozen needle)");
    assert_eq!(r.last_mark_e9, 0, "no mark recorded from a bad oracle");
}

#[test]
fn tick_freezes_on_wrong_oracle_owner() {
    let (mut svm, owner) = setup();
    let sk = Keypair::new();
    let feed = [9u8; 32];
    let ride = init_ride(&mut svm, &owner, 20, &sk.pubkey(), feed);
    let pf = Pubkey::new_unique();
    // Correct feed/price but owned by a random program → owner check fails → stale.
    svm.set_account(pf, oracle_account(feed, 6_786_596_052, 8, NOW, Pubkey::new_unique())).unwrap();
    assert_needle_frozen(&mut svm, &owner, &sk, ride, pf);
}

#[test]
fn tick_freezes_on_wrong_feed() {
    let (mut svm, owner) = setup();
    let sk = Keypair::new();
    let feed = [9u8; 32];
    let ride = init_ride(&mut svm, &owner, 21, &sk.pubkey(), feed);
    let pf = Pubkey::new_unique();
    // Right owner, WRONG feed_id → feed check fails → stale.
    svm.set_account(pf, oracle_account([0xAB; 32], 6_786_596_052, 8, NOW, ORACLE_PROGRAM_ID)).unwrap();
    assert_needle_frozen(&mut svm, &owner, &sk, ride, pf);
}

#[test]
fn tick_freezes_on_stale_oracle() {
    let (mut svm, owner) = setup();
    let sk = Keypair::new();
    let feed = [9u8; 32];
    let ride = init_ride(&mut svm, &owner, 22, &sk.pubkey(), feed);
    let pf = Pubkey::new_unique();
    // Right owner+feed, but publish_time 10s in the past (> 2s gate) → stale.
    svm.set_account(pf, oracle_account(feed, 6_786_596_052, 8, NOW - 10, ORACLE_PROGRAM_ID)).unwrap();
    assert_needle_frozen(&mut svm, &owner, &sk, ride, pf);
}

// ── close guards ──────────────────────────────────────────────────────────────
fn close_ix(ride: Pubkey, owner: &Pubkey) -> Instruction {
    Instruction {
        program_id: ID,
        accounts: vec![AccountMeta::new(ride, false), AccountMeta::new(*owner, true)],
        data: ix::CLOSE_RIDE.to_vec(),
    }
}

#[test]
fn close_rejects_before_settle() {
    let (mut svm, owner) = setup();
    let sk = Keypair::new();
    let ride = init_ride(&mut svm, &owner, 30, &sk.pubkey(), [9u8; 32]); // status ARMED
    assert!(!tx(&mut svm, &[close_ix(ride, &owner.pubkey())], &[&owner], &owner.pubkey()),
        "close before SETTLING must reject (InvalidStatus)");
}

#[test]
fn close_rejects_non_owner() {
    let (mut svm, owner) = setup();
    let (ride, bump) = ride_pda(&owner.pubkey(), 31);
    // Fabricate a SETTLING ride owned by the program (a real one needs the full DLP undelegation cycle).
    svm.set_account(ride, fabricated_ride(owner.pubkey(), ID, 31, bump, status::SETTLING)).unwrap();
    let imposter = Keypair::new();
    svm.airdrop(&imposter.pubkey(), 1_000_000_000).unwrap();
    assert!(!tx(&mut svm, &[close_ix(ride, &imposter.pubkey())], &[&imposter], &imposter.pubkey()),
        "close by a non-owner must reject (UnauthorizedSigner)");
}

#[test]
fn close_rejects_while_delegated() {
    let (mut svm, owner) = setup();
    let (ride, bump) = ride_pda(&owner.pubkey(), 32);
    // Account currently owned by the delegation program (i.e. still delegated) → not closable.
    svm.set_account(ride, fabricated_ride(owner.pubkey(), DELEGATION_PROGRAM_ID, 32, bump, status::SETTLING)).unwrap();
    assert!(!tx(&mut svm, &[close_ix(ride, &owner.pubkey())], &[&owner], &owner.pubkey()),
        "close while delegated (DLP-owned) must reject (InvalidAccountOwner)");
}

#[test]
fn close_succeeds_for_owner_when_settling() {
    let (mut svm, owner) = setup();
    let (ride, bump) = ride_pda(&owner.pubkey(), 33);
    svm.set_account(ride, fabricated_ride(owner.pubkey(), ID, 33, bump, status::SETTLING)).unwrap();
    let before = svm.get_account(&owner.pubkey()).unwrap().lamports;
    let rent = svm.get_account(&ride).unwrap().lamports;
    assert!(tx(&mut svm, &[close_ix(ride, &owner.pubkey())], &[&owner], &owner.pubkey()),
        "owner close of a SETTLING ride must succeed");
    let after = svm.get_account(&owner.pubkey()).map(|a| a.lamports).unwrap_or(0);
    assert!(after >= before + rent - 10_000, "rent must be refunded to the owner (minus tx fee)");
    assert!(svm.get_account(&ride).map(|a| a.data.is_empty() || a.lamports == 0).unwrap_or(true),
        "closed ride must be emptied");
}

// ── freeze guards ─────────────────────────────────────────────────────────────
fn freeze_ix(ride: Pubkey, authority: &Pubkey) -> Instruction {
    Instruction {
        program_id: ID,
        accounts: vec![AccountMeta::new(ride, false), AccountMeta::new_readonly(*authority, true)],
        data: ix::FREEZE.to_vec(),
    }
}

#[test]
fn freeze_rejects_imposter() {
    let (mut svm, owner) = setup();
    let sk = Keypair::new();
    let ride = init_ride(&mut svm, &owner, 40, &sk.pubkey(), [9u8; 32]);
    let imposter = Keypair::new();
    svm.airdrop(&imposter.pubkey(), 1_000_000_000).unwrap();
    assert!(!tx(&mut svm, &[freeze_ix(ride, &imposter.pubkey())], &[&imposter], &imposter.pubkey()),
        "freeze by a non-owner/non-session key must reject");
}

#[test]
fn freeze_by_owner_then_tick_is_rejected() {
    let (mut svm, owner) = setup();
    let sk = Keypair::new();
    let feed = [9u8; 32];
    let ride = init_ride(&mut svm, &owner, 41, &sk.pubkey(), feed);
    assert!(tx(&mut svm, &[freeze_ix(ride, &owner.pubkey())], &[&owner], &owner.pubkey()),
        "owner may freeze");
    let r = decode(&svm.get_account(&ride).unwrap().data);
    assert_eq!(r.status, status::FROZEN, "status must be FROZEN");
    // A frozen ride can no longer tick.
    let pf = Pubkey::new_unique();
    svm.set_account(pf, oracle_account(feed, 6_786_596_052, 8, NOW, ORACLE_PROGRAM_ID)).unwrap();
    assert!(!tx(&mut svm, &[tick_ix(ride, pf, &sk.pubkey(), 5000)], &[&owner, &sk], &owner.pubkey()),
        "tick on a FROZEN ride must reject (InvalidStatus)");
}

// ── L2 / I3 hardening ─────────────────────────────────────────────────────────
#[test]
fn init_rejects_expiry_too_far() {
    let (mut svm, o) = setup();
    // 2 days out — beyond the 24h MAX_SESSION_TTL_SECS cap.
    assert!(!try_init(&mut svm, &o, 8, |p| p.4 = NOW + 2 * 86_400),
        "expires_at beyond max session TTL must reject (SessionTtlTooLong)");
}

#[test]
fn tick_freezes_on_future_dated_oracle() {
    let (mut svm, owner) = setup();
    let sk = Keypair::new();
    let feed = [9u8; 32];
    let ride = init_ride(&mut svm, &owner, 23, &sk.pubkey(), feed);
    let pf = Pubkey::new_unique();
    // publish_time 100s in the FUTURE relative to the clock → negative age → not fresh → freeze.
    svm.set_account(pf, oracle_account(feed, 6_786_596_052, 8, NOW + 100, ORACLE_PROGRAM_ID)).unwrap();
    assert_needle_frozen(&mut svm, &owner, &sk, ride, pf);
}
