//! Runtime smoke suite for the Pinocchio build — runs the **real compiled `.so`** inside litesvm.
//! Proves the entrypoint routes by discriminator, the handlers parse args + create/write the account
//! in the exact wire layout, and the `tick` hot path executes the oracle parse + accounting on-chain.
//!
//! Run `cargo build-sbf` first (litesvm loads the prebuilt `.so`), then `cargo test`.

#![allow(clippy::result_large_err)]

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
const SYSTEM_PROGRAM_ID: Pubkey = pubkey!("11111111111111111111111111111111");
const RIDE_SEED: &[u8] = b"ride";
const SO_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/target/deploy/throtl_engine_pin.so");

const NOW: i64 = 1_800_000_000;

fn setup() -> (LiteSVM, Keypair) {
    let mut svm = LiteSVM::new();
    svm.add_program_from_file(ID, SO_PATH)
        .expect("load throtl_engine_pin.so — run `cargo build-sbf` first");
    svm.set_sysvar(&Clock {
        unix_timestamp: NOW,
        ..Default::default()
    });
    let owner = Keypair::new();
    svm.airdrop(&owner.pubkey(), 10_000_000_000).unwrap();
    (svm, owner)
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

/// Fabricate a valid in-ER `PriceUpdateV3` oracle account (owned by PriCems…). The program keys off
/// owner + feed_id, parsing price@73 / expo@89 / publish_time@93.
fn oracle_account(feed_id: [u8; 32], mantissa: i64, expo: i32, publish_time: i64) -> Account {
    let mut data = vec![0u8; 101];
    data[41..73].copy_from_slice(&feed_id);
    data[73..81].copy_from_slice(&mantissa.to_le_bytes());
    data[89..93].copy_from_slice(&expo.to_le_bytes());
    data[93..101].copy_from_slice(&publish_time.to_le_bytes());
    Account {
        lamports: 10_000_000,
        data,
        owner: ORACLE_PROGRAM_ID,
        executable: false,
        rent_epoch: u64::MAX,
    }
}

fn decode(data: &[u8]) -> RideSession {
    *bytemuck::from_bytes::<RideSession>(&data[8..8 + RideSession::LEN])
}

fn send(svm: &mut LiteSVM, ixs: &[Instruction], signers: &[&Keypair], payer: &Pubkey) {
    let tx = Transaction::new_signed_with_payer(ixs, Some(payer), signers, svm.latest_blockhash());
    svm.send_transaction(tx).expect("tx");
}

#[test]
fn init_ride_writes_exact_wire_layout() {
    let (mut svm, owner) = setup();
    let session_id = 42u64;
    let (ride, _) = ride_pda(&owner.pubkey(), session_id);
    let sk = Keypair::new();
    let feed = [7u8; 32];

    let data = init_data(
        session_id,
        &sk.pubkey(),
        0,
        feed,
        grip::HOLD,
        500_000_000,
        100_000,
        -200_000_000,
        NOW + 3600,
    );
    send(&mut svm, &[init_ix(&owner.pubkey(), ride, data)], &[&owner], &owner.pubkey());

    let acc = svm.get_account(&ride).expect("ride account exists");
    assert_eq!(acc.owner, ID, "ride owned by the program");
    assert_eq!(acc.data.len(), RideSession::ACCOUNT_LEN, "272-byte account");

    let r = decode(&acc.data);
    assert_eq!(r.session_id, session_id);
    assert_eq!(r.fuel_usd_6, 500_000_000);
    assert_eq!(r.max_lev_bps, 100_000);
    assert_eq!(r.loss_floor_6, -200_000_000);
    assert_eq!(r.owner, owner.pubkey().to_bytes());
    assert_eq!(r.session_key, sk.pubkey().to_bytes());
    assert_eq!(r.feed_id, feed);
    assert_eq!(r.status, status::ARMED);
    assert_eq!(r.version, 1);
    assert_eq!(r.notional_usd_6, 0);
}

#[test]
fn tick_marks_pnl_and_sets_the_needle() {
    let (mut svm, owner) = setup();
    let session_id = 7u64;
    let (ride, _) = ride_pda(&owner.pubkey(), session_id);
    let sk = Keypair::new();
    let feed = [9u8; 32];

    // init
    let data = init_data(
        session_id,
        &sk.pubkey(),
        0,
        feed,
        grip::HOLD,
        500_000_000,
        100_000,
        -200_000_000,
        NOW + 3600,
    );
    send(&mut svm, &[init_ix(&owner.pubkey(), ride, data)], &[&owner], &owner.pubkey());

    // a fresh, valid oracle for this feed: mantissa 6_786_596_052 @ expo 8 ⇒ $67.866 (price_e9 ×10)
    let price_feed = Pubkey::new_unique();
    svm.set_account(price_feed, oracle_account(feed, 6_786_596_052, 8, NOW)).unwrap();

    // tick to +5000 bps (half long) — session-signed
    let mut tdata = Vec::with_capacity(12);
    tdata.extend_from_slice(&ix::TICK);
    tdata.extend_from_slice(&5000i32.to_le_bytes());
    let tick = Instruction {
        program_id: ID,
        accounts: vec![
            AccountMeta::new(ride, false),
            AccountMeta::new_readonly(price_feed, false),
            AccountMeta::new_readonly(sk.pubkey(), true),
        ],
        data: tdata,
    };
    send(&mut svm, &[tick], &[&owner, &sk], &owner.pubkey());

    let r = decode(&svm.get_account(&ride).unwrap().data);
    assert_eq!(r.last_mark_e9, 67_865_960_520, "oracle parse + normalize");
    assert_eq!(r.status, status::RIDING, "ARMED → RIDING on first tick");
    assert_eq!(r.target_exp_bps, 5000);
    // notional = effective_collateral(500e6) × 10x × 0.5 deflection = $2,500
    assert_eq!(r.notional_usd_6, 2_500_000_000, "target_notional math");
    assert_eq!(r.entry_vwap_e9, 67_865_960_520, "VWAP = entry mark");
    assert_eq!(r.flags & flags::ORACLE_STALE, 0, "fresh oracle clears the stale flag");
    assert_eq!(r.tick_count, 1);
}

#[test]
fn tick_rejects_wrong_session_signer() {
    let (mut svm, owner) = setup();
    let session_id = 9u64;
    let (ride, _) = ride_pda(&owner.pubkey(), session_id);
    let sk = Keypair::new();
    let imposter = Keypair::new();
    svm.airdrop(&imposter.pubkey(), 1_000_000_000).unwrap();
    let feed = [3u8; 32];

    let data = init_data(
        session_id, &sk.pubkey(), 0, feed, grip::HOLD, 500_000_000, 100_000, -200_000_000, NOW + 3600,
    );
    send(&mut svm, &[init_ix(&owner.pubkey(), ride, data)], &[&owner], &owner.pubkey());

    let price_feed = Pubkey::new_unique();
    svm.set_account(price_feed, oracle_account(feed, 6_786_596_052, 8, NOW)).unwrap();

    let mut tdata = Vec::with_capacity(12);
    tdata.extend_from_slice(&ix::TICK);
    tdata.extend_from_slice(&3000i32.to_le_bytes());
    let tick = Instruction {
        program_id: ID,
        accounts: vec![
            AccountMeta::new(ride, false),
            AccountMeta::new_readonly(price_feed, false),
            AccountMeta::new_readonly(imposter.pubkey(), true), // NOT the session key
        ],
        data: tdata,
    };
    let tx = Transaction::new_signed_with_payer(
        &[tick],
        Some(&imposter.pubkey()),
        &[&imposter],
        svm.latest_blockhash(),
    );
    assert!(svm.send_transaction(tx).is_err(), "imposter tick must be rejected");
}
