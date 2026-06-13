//! Reads a MagicBlock ephemeral-oracle `PriceUpdateV3` PDA (Pyth Lazer feeds, in the ER) by raw
//! byte offset — no `pyth-solana-receiver-sdk` / Anchor dependency on the consumer side.
//!
//! Layout (Borsh, after the 8-byte Anchor account discriminator; verified live on the devnet SOL
//! feed `ENYweb…`): `8 disc | 32 write_authority | 1 verification_level | 32 feed_id |
//! i64 price@73 | u64 conf@81 | i32 exponent@89 | i64 publish_time@93 | …`.
//!
//! EXPONENT CONVENTION (the trap that the M0.1 spike caught): this oracle stores the **Pyth Lazer**
//! exponent — a POSITIVE number of decimals where `real = mantissa × 10^(-exponent)` — NOT the
//! standard Pyth signed exponent. Live SOL: mantissa 6_786_596_052, exponent 8 → $67.866. So we
//! normalize with `10^(9 - exponent)`, not `10^(9 + exponent)`.

use anchor_lang::prelude::*;

use crate::constants::{MAX_ORACLE_STALENESS_SECS, ORACLE_PROGRAM_ID};
use crate::error::ThrotlError;

const OFF_FEED_ID: usize = 8 + 32 + 1; // 41
const OFF_PRICE: usize = 73;
const OFF_EXPO: usize = 89;
const OFF_PUBLISH_TIME: usize = 93;
const MIN_LEN: usize = OFF_PUBLISH_TIME + 8; // 101

pub struct OraclePrice {
    /// Price normalized to 1e9 fixed-point.
    pub price_e9: u64,
    pub publish_time: i64,
}

/// Validate ownership + feed + staleness, then return the mark normalized to price_e9.
pub fn read_oracle(
    acc: &AccountInfo,
    expected_feed_id: &[u8; 32],
    now: i64,
) -> Result<OraclePrice> {
    require_keys_eq!(
        *acc.owner,
        ORACLE_PROGRAM_ID,
        ThrotlError::OracleOwnerMismatch
    );

    let data = acc.try_borrow_data()?;
    require!(data.len() >= MIN_LEN, ThrotlError::OracleInvalidPrice);

    require!(
        data[OFF_FEED_ID..OFF_FEED_ID + 32] == expected_feed_id[..],
        ThrotlError::OracleFeedMismatch
    );

    let price_raw = i64::from_le_bytes(data[OFF_PRICE..OFF_PRICE + 8].try_into().unwrap());
    let expo = i32::from_le_bytes(data[OFF_EXPO..OFF_EXPO + 4].try_into().unwrap());
    let publish_time = i64::from_le_bytes(
        data[OFF_PUBLISH_TIME..OFF_PUBLISH_TIME + 8]
            .try_into()
            .unwrap(),
    );

    require!(price_raw > 0, ThrotlError::OracleInvalidPrice);
    require!(
        now - publish_time <= MAX_ORACLE_STALENESS_SECS,
        ThrotlError::OracleStale
    );

    let price_e9 = normalize_to_e9(price_raw as u128, expo).ok_or(ThrotlError::MathOverflow)?;
    require!(price_e9 > 0, ThrotlError::OracleInvalidPrice);

    Ok(OraclePrice {
        price_e9,
        publish_time,
    })
}

/// `price * 10^(9 - expo)` → u64 (price_e9). `expo` is the POSITIVE Lazer exponent (decimals);
/// `real = mantissa × 10^(-expo)`. See the module header.
fn normalize_to_e9(price: u128, expo: i32) -> Option<u64> {
    let target = 9i32 - expo;
    let v = if target >= 0 {
        price.checked_mul(10u128.checked_pow(target as u32)?)?
    } else {
        price.checked_div(10u128.checked_pow((-target) as u32)?)?
    };
    if v > u64::MAX as u128 {
        None
    } else {
        Some(v as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_lazer_expo_8() {
        // Live devnet SOL: mantissa 6_786_596_052, Lazer exponent 8 → price_e9 = raw * 10.
        assert_eq!(normalize_to_e9(6_786_596_052, 8), Some(67_865_960_520));
    }

    #[test]
    fn normalize_expo_9_identity() {
        assert_eq!(normalize_to_e9(147_123_456_789, 9), Some(147_123_456_789));
    }

    #[test]
    fn normalize_expo_10_divides() {
        assert_eq!(
            normalize_to_e9(1_471_234_567_890, 10),
            Some(147_123_456_789)
        );
    }
}
