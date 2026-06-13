//! Instruction-level hardening suite for throtl-engine, run against the **real compiled `.so`**
//! inside litesvm (an in-process SVM). No mocks, no network, no funds — CI-deterministic.
//!
//! litesvm 0.12 is built on the granular solana-* 3.x crates, the same major the program's
//! anchor-lang 1.0.2 uses (`solana_pubkey::Pubkey` is literally `solana_address::Address`), so the
//! harness and the program share one `Pubkey`/`Instruction`/`Account` type set — no byte-bridging.
//!
//! Coverage:
//!   * `init_ride` happy path → every RideSession field is asserted against the inputs.
//!   * `init_ride` every guard (6000–6007), each isolated so the *targeted* `require!` is the one
//!     that fires (validation order in the handler matters — see comments).
//!   * `tick` full mark path with a **fabricated valid in-ER oracle account** → PnL/needle update,
//!     ORACLE_STALE cleared, status ARMED→RIDING; plus the staleness path with a non-oracle feed.
//!   * `tick` guards: out-of-bounds target (6004), wrong session signer (6006).
//!   * `flatten` (target→0) and `freeze` (→FROZEN + breach flag) happy + unauthorized.
//!   * `close_ride` rejects a non-settled ride (6008).
//!   * Compute-units regression: the real mark-path `tick` CU is printed and bounded — this is the
//!     empirical baseline for the DR-1 Phase-2 (Pinocchio) trigger.
//!
//! Anchor custom error codes start at 6000 in declaration order (error.rs):
//!   6000 LeverageTooHigh · 6001 LeverageTooLow · 6002 InvalidFuel · 6003 InvalidLossFloor
//!   6004 ExposureOutOfBounds · 6005 InvalidGripMode · 6006 UnauthorizedSigner · 6007 SessionExpired
//!   6008 InvalidStatus · 6009 PdaMismatch · 6010 OracleOwnerMismatch · …

// litesvm's `TransactionResult` Err variant (FailedTransactionMetadata) is intentionally large
// (it carries full logs); we can't shrink a third-party type, so allow it across this test crate.
#![allow(clippy::result_large_err)]

use anchor_lang::InstructionData;
use litesvm::types::TransactionResult;
use litesvm::LiteSVM;
use solana_account::Account;
use solana_clock::Clock;
use solana_instruction::{AccountMeta, Instruction};
use solana_keypair::Keypair;
use solana_pubkey::Pubkey;
use solana_signer::Signer;
use solana_transaction::Transaction;

use throtl_engine::constants::{flags, grip, status, ORACLE_PROGRAM_ID, RIDE_SEED};
use throtl_engine::state::RideSession;
use throtl_engine::{instruction as ix, ID};

const SO_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../target/deploy/throtl_engine.so"
);

// The clock sysvar data layout is fixed: unix_timestamp is an i64 at offset 32.
const CLOCK_SYSVAR_ID: Pubkey =
    solana_pubkey::pubkey!("SysvarC1ock11111111111111111111111111111111");
const SYSTEM_PROGRAM_ID: Pubkey = anchor_lang::solana_program::system_program::ID;

// A representative valid ride: $500 fuel, 10x ceiling, −$200 loss floor.
const FUEL_6: u64 = 500_000_000;
const LEV_10X: u32 = 100_000;
const FLOOR_6: i64 = -200_000_000;
const FEED: [u8; 32] = [7u8; 32];
// Live devnet SOL feed sample: mantissa 6_786_596_052 @ Lazer expo 8 ⇒ price_e9 = ×10 = $67.866.
const ORACLE_MANTISSA: i64 = 6_786_596_052;
const ORACLE_EXPO: i32 = 8;
const EXPECTED_MARK_E9: u64 = 67_865_960_520;

// ─────────────────────────────────────────── harness ───────────────────────────────────────────

fn setup() -> (LiteSVM, Keypair) {
    let mut svm = LiteSVM::new();
    svm.add_program_from_file(ID, SO_PATH)
        .expect("load throtl_engine.so — run `anchor build` / cargo-build-sbf first");
    // Pin a known, plausible wall clock (2027-ish) so expiry/staleness windows are deterministic.
    svm.set_sysvar(&Clock {
        unix_timestamp: 1_800_000_000,
        ..Default::default()
    });
    let owner = Keypair::new();
    svm.airdrop(&owner.pubkey(), 10_000_000_000).unwrap();
    (svm, owner)
}

fn clock_now(svm: &LiteSVM) -> i64 {
    let acc = svm.get_account(&CLOCK_SYSVAR_ID).expect("clock sysvar");
    i64::from_le_bytes(acc.data[32..40].try_into().unwrap())
}

fn ride_pda(owner: &Pubkey, session_id: u64) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[RIDE_SEED, owner.as_ref(), &session_id.to_le_bytes()], &ID)
}

#[allow(clippy::too_many_arguments)]
fn init_ride_ix(
    owner: &Pubkey,
    session_id: u64,
    session_key: Pubkey,
    grip_mode: u8,
    fuel_usd_6: u64,
    max_lev_bps: u32,
    loss_floor_6: i64,
    expires_at: i64,
) -> Instruction {
    let (ride, _) = ride_pda(owner, session_id);
    let data = ix::InitRide {
        session_id,
        session_key,
        market_id: 0,
        feed_id: FEED,
        grip_mode,
        fuel_usd_6,
        max_lev_bps,
        loss_floor_6,
        expires_at,
    }
    .data();
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

fn tick_ix(
    ride: Pubkey,
    price_feed: Pubkey,
    session_signer: Pubkey,
    target_exp_bps: i32,
) -> Instruction {
    Instruction {
        program_id: ID,
        accounts: vec![
            AccountMeta::new(ride, false),
            AccountMeta::new_readonly(price_feed, false),
            AccountMeta::new_readonly(session_signer, true),
        ],
        data: ix::Tick { target_exp_bps }.data(),
    }
}

fn flatten_ix(ride: Pubkey, price_feed: Pubkey, session_signer: Pubkey) -> Instruction {
    Instruction {
        program_id: ID,
        accounts: vec![
            AccountMeta::new(ride, false),
            AccountMeta::new_readonly(price_feed, false),
            AccountMeta::new_readonly(session_signer, true),
        ],
        data: ix::Flatten {}.data(),
    }
}

fn freeze_ix(ride: Pubkey, authority: Pubkey) -> Instruction {
    Instruction {
        program_id: ID,
        accounts: vec![
            AccountMeta::new(ride, false),
            AccountMeta::new_readonly(authority, true),
        ],
        data: ix::Freeze {}.data(),
    }
}

fn close_ride_ix(ride: Pubkey, owner: Pubkey) -> Instruction {
    Instruction {
        program_id: ID,
        accounts: vec![AccountMeta::new(ride, false), AccountMeta::new(owner, true)],
        data: ix::CloseRide {}.data(),
    }
}

fn send(
    svm: &mut LiteSVM,
    ixs: &[Instruction],
    payer: &Keypair,
    signers: &[&Keypair],
) -> TransactionResult {
    let bh = svm.latest_blockhash();
    let tx = Transaction::new_signed_with_payer(ixs, Some(&payer.pubkey()), signers, bh);
    svm.send_transaction(tx)
}

/// Fabricate a valid MagicBlock ephemeral-oracle `PriceUpdateV3` account (owned by PriCems…),
/// matching the byte layout `oracle::read_oracle` parses.
fn oracle_account(feed_id: [u8; 32], mantissa: i64, expo: i32, publish_time: i64) -> Account {
    let mut data = vec![0u8; 101];
    // [0..8] discriminator (cosmetic — read_oracle keys off owner + feed, not disc).
    data[0..8].copy_from_slice(&[0xea, 0xa1, 0x0e, 0x24, 0xac, 0xef, 0x0f, 0xe8]);
    // [8..40] write_authority, [40] verification_level — zeros are fine.
    data[41..73].copy_from_slice(&feed_id); // feed_id
    data[73..81].copy_from_slice(&mantissa.to_le_bytes()); // price i64
                                                           // [81..89] conf u64 — zeros.
    data[89..93].copy_from_slice(&expo.to_le_bytes()); // exponent i32
    data[93..101].copy_from_slice(&publish_time.to_le_bytes()); // publish_time i64
    Account {
        // Comfortably rent-exempt (101 bytes ⇒ ~1.59M min); a sub-rent-exempt account is dropped on load.
        lamports: 10_000_000,
        data,
        owner: ORACLE_PROGRAM_ID,
        executable: false,
        rent_epoch: u64::MAX, // marks the account rent-exempt to the runtime
    }
}

fn load_ride(svm: &LiteSVM, ride: &Pubkey) -> RideSession {
    let acc = svm.get_account(ride).expect("ride account exists");
    // Skip the 8-byte Anchor discriminator; unaligned read (Vec<u8> slice isn't 8-aligned).
    bytemuck::pod_read_unaligned::<RideSession>(&acc.data[8..8 + RideSession::LEN])
}

#[track_caller]
fn assert_custom(res: TransactionResult, code: u32) {
    match res {
        Ok(meta) => panic!(
            "expected custom error {code}, but tx succeeded: {:?}",
            meta.logs
        ),
        Err(failed) => {
            let dbg = format!("{:?}", failed.err);
            assert!(
                dbg.contains(&format!("Custom({code})")),
                "expected Custom({code}), got {dbg}\nlogs: {:?}",
                failed.meta.logs
            );
        }
    }
}

// ──────────────────────────────────────── init_ride ────────────────────────────────────────────

#[test]
fn init_ride_happy_writes_every_field() {
    let (mut svm, owner) = setup();
    let session = Keypair::new();
    let sid = 42;
    let now = clock_now(&svm);
    let expires = now + 3600;
    let (ride_pk, bump) = ride_pda(&owner.pubkey(), sid);

    let res = send(
        &mut svm,
        &[init_ride_ix(
            &owner.pubkey(),
            sid,
            session.pubkey(),
            grip::CRUISE,
            FUEL_6,
            LEV_10X,
            FLOOR_6,
            expires,
        )],
        &owner,
        &[&owner],
    );
    assert!(
        res.is_ok(),
        "init_ride failed: {:?}",
        res.err().map(|e| e.meta.logs)
    );

    let r = load_ride(&svm, &ride_pk);
    assert_eq!(r.version, RideSession::VERSION);
    assert_eq!(r.bump, bump);
    assert_eq!(r.status, status::ARMED);
    assert_eq!(r.grip_mode, grip::CRUISE);
    assert_eq!(r.market_id, 0);
    assert_eq!(r.owner, owner.pubkey());
    assert_eq!(r.session_key, session.pubkey());
    assert_eq!(r.feed_id, FEED);
    assert_eq!(r.session_id, sid);
    assert_eq!(r.expires_at, expires);
    assert_eq!(r.fuel_usd_6, FUEL_6);
    assert_eq!(r.max_lev_bps, LEV_10X);
    assert_eq!(r.loss_floor_6, FLOOR_6);
    // Fresh ride: no exposure, no ticks, no flags.
    assert_eq!(r.notional_usd_6, 0);
    assert_eq!(r.tick_count, 0);
    assert_eq!(r.target_exp_bps, 0);
    assert_eq!(r.virt_exp_bps, 0);
    assert_eq!(r.flags, 0);
}

#[test]
fn init_ride_rejects_zero_fuel() {
    // First guard in the handler: fuel must be > 0. All other fields valid.
    let (mut svm, owner) = setup();
    let now = clock_now(&svm);
    let res = send(
        &mut svm,
        &[init_ride_ix(
            &owner.pubkey(),
            1,
            Keypair::new().pubkey(),
            grip::HOLD,
            0,
            LEV_10X,
            FLOOR_6,
            now + 3600,
        )],
        &owner,
        &[&owner],
    );
    assert_custom(res, 6002); // InvalidFuel
}

#[test]
fn init_ride_rejects_leverage_above_ceiling() {
    let (mut svm, owner) = setup();
    let now = clock_now(&svm);
    let res = send(
        &mut svm,
        &[init_ride_ix(
            &owner.pubkey(),
            2,
            Keypair::new().pubkey(),
            grip::HOLD,
            FUEL_6,
            100_001,
            FLOOR_6,
            now + 3600,
        )],
        &owner,
        &[&owner],
    );
    assert_custom(res, 6000); // LeverageTooHigh
}

#[test]
fn init_ride_rejects_leverage_below_minimum() {
    // 5_000 bps (0.5x): below MIN (10_000) but ≤ ceiling, so LeverageTooLow is the guard that fires.
    let (mut svm, owner) = setup();
    let now = clock_now(&svm);
    let res = send(
        &mut svm,
        &[init_ride_ix(
            &owner.pubkey(),
            3,
            Keypair::new().pubkey(),
            grip::HOLD,
            FUEL_6,
            5_000,
            FLOOR_6,
            now + 3600,
        )],
        &owner,
        &[&owner],
    );
    assert_custom(res, 6001); // LeverageTooLow
}

#[test]
fn init_ride_rejects_nonnegative_loss_floor() {
    // loss_floor must be a strictly negative bound; 0 is invalid.
    let (mut svm, owner) = setup();
    let now = clock_now(&svm);
    let res = send(
        &mut svm,
        &[init_ride_ix(
            &owner.pubkey(),
            4,
            Keypair::new().pubkey(),
            grip::HOLD,
            FUEL_6,
            LEV_10X,
            0,
            now + 3600,
        )],
        &owner,
        &[&owner],
    );
    assert_custom(res, 6003); // InvalidLossFloor
}

#[test]
fn init_ride_rejects_invalid_grip_mode() {
    // grip must be ≤ CRUISE (1); 2 is invalid.
    let (mut svm, owner) = setup();
    let now = clock_now(&svm);
    let res = send(
        &mut svm,
        &[init_ride_ix(
            &owner.pubkey(),
            5,
            Keypair::new().pubkey(),
            2,
            FUEL_6,
            LEV_10X,
            FLOOR_6,
            now + 3600,
        )],
        &owner,
        &[&owner],
    );
    assert_custom(res, 6005); // InvalidGripMode
}

#[test]
fn init_ride_rejects_already_expired() {
    // expires_at must be strictly in the future relative to the on-chain clock.
    let (mut svm, owner) = setup();
    let now = clock_now(&svm);
    let res = send(
        &mut svm,
        &[init_ride_ix(
            &owner.pubkey(),
            6,
            Keypair::new().pubkey(),
            grip::HOLD,
            FUEL_6,
            LEV_10X,
            FLOOR_6,
            now - 1,
        )],
        &owner,
        &[&owner],
    );
    assert_custom(res, 6007); // SessionExpired
}

// ───────────────────────────────────────────── tick ────────────────────────────────────────────

/// Arm a ride and return (ride_pk, session keypair). The clock is left set to `setup`'s value.
fn arm(svm: &mut LiteSVM, owner: &Keypair, sid: u64) -> (Pubkey, Keypair) {
    let session = Keypair::new();
    let now = clock_now(svm);
    let (ride_pk, _) = ride_pda(&owner.pubkey(), sid);
    let res = send(
        svm,
        &[init_ride_ix(
            &owner.pubkey(),
            sid,
            session.pubkey(),
            grip::HOLD,
            FUEL_6,
            LEV_10X,
            FLOOR_6,
            now + 3600,
        )],
        owner,
        &[owner],
    );
    assert!(
        res.is_ok(),
        "arm/init failed: {:?}",
        res.err().map(|e| e.meta.logs)
    );
    (ride_pk, session)
}

#[test]
fn tick_full_mark_path_updates_needle_and_clears_stale() {
    let (mut svm, owner) = setup();
    let (ride_pk, session) = arm(&mut svm, &owner, 100);

    // Fabricate a fresh, valid oracle (publish_time == now) for this ride's feed.
    let oracle_pk = Pubkey::new_unique();
    let now = clock_now(&svm);
    svm.set_account(
        oracle_pk,
        oracle_account(FEED, ORACLE_MANTISSA, ORACLE_EXPO, now),
    )
    .unwrap();

    let res = send(
        &mut svm,
        &[tick_ix(ride_pk, oracle_pk, session.pubkey(), 5_000)],
        &owner,
        &[&owner, &session],
    );
    let meta = res.expect("mark-path tick should succeed");

    let r = load_ride(&svm, &ride_pk);
    assert_eq!(r.tick_count, 1);
    assert_eq!(
        r.status,
        status::RIDING,
        "ARMED→RIDING on first marked tick"
    );
    assert_eq!(r.target_exp_bps, 5_000);
    assert_eq!(
        r.last_mark_e9, EXPECTED_MARK_E9,
        "Lazer expo-8 normalization"
    );
    assert_eq!(r.flags & flags::ORACLE_STALE, 0, "fresh oracle ⇒ not stale");
    assert!(r.notional_usd_6 > 0, "long target opened positive notional");
    // 5_000 bps of a 10x-capped book ⇒ needle near +5_000 (allow rounding slack).
    assert!(
        (r.virt_exp_bps - 5_000).abs() <= 1,
        "needle ≈ +5000, got {}",
        r.virt_exp_bps
    );

    // CU regression guard + DR-1 Phase-2 (Pinocchio) trigger baseline. Observed ~4.6k for the full
    // mark+settle path; the 20k ceiling catches a real regression without flaking on toolchain CU
    // drift. Per the latency spike, the hot path is RTT-bound, not CU-bound — so headroom is ample.
    let cu = meta.compute_units_consumed;
    println!("TICK_CU mark-path = {cu} compute units (budget 200_000; guard < 20_000)");
    assert!(
        cu < 20_000,
        "mark-path tick CU regressed to {cu} (>20k) — investigate before Phase-2"
    );
}

#[test]
fn tick_staleness_path_records_target_without_marking() {
    let (mut svm, owner) = setup();
    let (ride_pk, session) = arm(&mut svm, &owner, 101);

    // A non-oracle feed (system program, owner != PriCems) ⇒ read_oracle errors ⇒ honest freeze.
    let res = send(
        &mut svm,
        &[tick_ix(
            ride_pk,
            SYSTEM_PROGRAM_ID,
            session.pubkey(),
            -5_000,
        )],
        &owner,
        &[&owner, &session],
    );
    assert!(
        res.is_ok(),
        "staleness path must still succeed: {:?}",
        res.err().map(|e| e.meta.logs)
    );

    let r = load_ride(&svm, &ride_pk);
    assert_eq!(r.tick_count, 1, "tick still counts");
    assert_eq!(r.target_exp_bps, -5_000, "thumb target recorded");
    assert_ne!(r.flags & flags::ORACLE_STALE, 0, "ORACLE_STALE set");
    assert_eq!(
        r.status,
        status::ARMED,
        "no status advance on a frozen needle"
    );
    assert_eq!(r.notional_usd_6, 0, "no PnL/exposure change while stale");
}

#[test]
fn tick_rejects_target_out_of_bounds() {
    let (mut svm, owner) = setup();
    let (ride_pk, session) = arm(&mut svm, &owner, 102);
    // 20_000 > MAX_EXP_BPS — the bounds check runs before any account load, so 6004 dominates.
    let res = send(
        &mut svm,
        &[tick_ix(
            ride_pk,
            SYSTEM_PROGRAM_ID,
            session.pubkey(),
            20_000,
        )],
        &owner,
        &[&owner, &session],
    );
    assert_custom(res, 6004); // ExposureOutOfBounds
}

#[test]
fn tick_rejects_wrong_session_signer() {
    let (mut svm, owner) = setup();
    let (ride_pk, _session) = arm(&mut svm, &owner, 103);
    // An imposter that actually signs the tx but is not the registered session key.
    let imposter = Keypair::new();
    svm.airdrop(&imposter.pubkey(), 1_000_000_000).unwrap();
    let res = send(
        &mut svm,
        &[tick_ix(
            ride_pk,
            SYSTEM_PROGRAM_ID,
            imposter.pubkey(),
            5_000,
        )],
        &imposter,
        &[&imposter],
    );
    assert_custom(res, 6006); // UnauthorizedSigner
}

// ──────────────────────────────────────── flatten / freeze ─────────────────────────────────────

#[test]
fn flatten_zeroes_target() {
    let (mut svm, owner) = setup();
    let (ride_pk, session) = arm(&mut svm, &owner, 200);

    // First take a real long, then flatten via the fresh oracle.
    let oracle_pk = Pubkey::new_unique();
    let now = clock_now(&svm);
    svm.set_account(
        oracle_pk,
        oracle_account(FEED, ORACLE_MANTISSA, ORACLE_EXPO, now),
    )
    .unwrap();
    send(
        &mut svm,
        &[tick_ix(ride_pk, oracle_pk, session.pubkey(), 6_000)],
        &owner,
        &[&owner, &session],
    )
    .expect("open long");

    // Refresh the oracle publish_time so it's still fresh for the flatten tick.
    let now2 = clock_now(&svm);
    svm.set_account(
        oracle_pk,
        oracle_account(FEED, ORACLE_MANTISSA, ORACLE_EXPO, now2),
    )
    .unwrap();
    let res = send(
        &mut svm,
        &[flatten_ix(ride_pk, oracle_pk, session.pubkey())],
        &owner,
        &[&owner, &session],
    );
    assert!(
        res.is_ok(),
        "flatten failed: {:?}",
        res.err().map(|e| e.meta.logs)
    );

    let r = load_ride(&svm, &ride_pk);
    assert_eq!(r.target_exp_bps, 0, "flatten sets target to 0");
    assert_eq!(r.notional_usd_6, 0, "flat ⇒ zero notional");
    assert!(
        (r.virt_exp_bps).abs() <= 1,
        "needle settled to ~0, got {}",
        r.virt_exp_bps
    );
}

#[test]
fn freeze_by_owner_sets_frozen_and_breach() {
    let (mut svm, owner) = setup();
    let (ride_pk, _session) = arm(&mut svm, &owner, 201);
    let res = send(
        &mut svm,
        &[freeze_ix(ride_pk, owner.pubkey())],
        &owner,
        &[&owner],
    );
    assert!(
        res.is_ok(),
        "owner freeze failed: {:?}",
        res.err().map(|e| e.meta.logs)
    );

    let r = load_ride(&svm, &ride_pk);
    assert_eq!(r.status, status::FROZEN);
    assert_eq!(r.target_exp_bps, 0);
    assert_ne!(r.flags & flags::FLOOR_BREACHED, 0, "FLOOR_BREACHED flagged");
}

#[test]
fn freeze_by_session_key_is_allowed() {
    let (mut svm, owner) = setup();
    let (ride_pk, session) = arm(&mut svm, &owner, 202);
    svm.airdrop(&session.pubkey(), 1_000_000_000).unwrap();
    let res = send(
        &mut svm,
        &[freeze_ix(ride_pk, session.pubkey())],
        &session,
        &[&session],
    );
    assert!(
        res.is_ok(),
        "session freeze failed: {:?}",
        res.err().map(|e| e.meta.logs)
    );
    assert_eq!(load_ride(&svm, &ride_pk).status, status::FROZEN);
}

#[test]
fn freeze_by_stranger_is_rejected() {
    let (mut svm, owner) = setup();
    let (ride_pk, _session) = arm(&mut svm, &owner, 203);
    let stranger = Keypair::new();
    svm.airdrop(&stranger.pubkey(), 1_000_000_000).unwrap();
    let res = send(
        &mut svm,
        &[freeze_ix(ride_pk, stranger.pubkey())],
        &stranger,
        &[&stranger],
    );
    assert_custom(res, 6006); // UnauthorizedSigner
}

// ──────────────────────────────────────────── close ────────────────────────────────────────────

#[test]
fn close_ride_rejects_unsettled() {
    // close_ride requires SETTLING/CLOSED; a freshly armed ride is ARMED ⇒ InvalidStatus.
    let (mut svm, owner) = setup();
    let (ride_pk, _session) = arm(&mut svm, &owner, 300);
    let res = send(
        &mut svm,
        &[close_ride_ix(ride_pk, owner.pubkey())],
        &owner,
        &[&owner],
    );
    assert_custom(res, 6008); // InvalidStatus
}
