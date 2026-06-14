//! Reads a MagicBlock ephemeral-oracle `PriceUpdateV3` PDA (Pyth Lazer feeds) by raw byte offset.
//!
//! Layout (after the 8-byte account discriminator): `8 disc | 32 write_authority |
//! 1 verification_level | 32 feed_id | i64 price@73 | u64 conf@81 | i32 exponent@89 |
//! i64 publish_time@93 | …`.
//!
//! EXPONENT CONVENTION (the M0.1-spike trap): this oracle stores the **Pyth Lazer** exponent — a
//! POSITIVE decimals count where `real = mantissa × 10^(-exponent)` — so normalize with
//! `10^(9 - exponent)`, NOT `10^(9 + exponent)`. Live SOL: mantissa 6_786_596_052, expo 8 → $67.866.

use pinocchio::error::ProgramError;
use pinocchio::AccountView;

use crate::constants::{MAX_ORACLE_STALENESS_SECS, ORACLE_PROGRAM_ID};
use crate::error::ThrotlError;

const OFF_FEED_ID: usize = 8 + 32 + 1; // 41
const OFF_PRICE: usize = 73;
const OFF_EXPO: usize = 89;
const OFF_PUBLISH_TIME: usize = 93;
const MIN_LEN: usize = OFF_PUBLISH_TIME + 8; // 101

pub struct OraclePrice {
    pub price_e9: u64,
    pub publish_time: i64,
}

/// Validate ownership + feed + staleness, then return the mark normalized to price_e9.
pub fn read_oracle(
    acc: &AccountView,
    expected_feed_id: &[u8; 32],
    now: i64,
) -> Result<OraclePrice, ProgramError> {
    if !acc.owned_by(&ORACLE_PROGRAM_ID) {
        return Err(ThrotlError::OracleOwnerMismatch.into());
    }

    let data = acc.try_borrow()?;
    if data.len() < MIN_LEN {
        return Err(ThrotlError::OracleInvalidPrice.into());
    }
    if data[OFF_FEED_ID..OFF_FEED_ID + 32] != expected_feed_id[..] {
        return Err(ThrotlError::OracleFeedMismatch.into());
    }

    let price_raw = i64::from_le_bytes(data[OFF_PRICE..OFF_PRICE + 8].try_into().unwrap());
    let expo = i32::from_le_bytes(data[OFF_EXPO..OFF_EXPO + 4].try_into().unwrap());
    let publish_time =
        i64::from_le_bytes(data[OFF_PUBLISH_TIME..OFF_PUBLISH_TIME + 8].try_into().unwrap());

    if price_raw <= 0 {
        return Err(ThrotlError::OracleInvalidPrice.into());
    }
    // Reject both stale AND future-dated prices (I3): a negative age means publish_time > now
    // (clock skew / manipulation), which we must not treat as fresh. checked_sub avoids i64 overflow.
    let age = now.checked_sub(publish_time).ok_or(ThrotlError::OracleStale)?;
    if !(0..=MAX_ORACLE_STALENESS_SECS).contains(&age) {
        return Err(ThrotlError::OracleStale.into());
    }

    let price_e9 = normalize_to_e9(price_raw as u128, expo).ok_or(ThrotlError::MathOverflow)?;
    if price_e9 == 0 {
        return Err(ThrotlError::OracleInvalidPrice.into());
    }

    Ok(OraclePrice {
        price_e9,
        publish_time,
    })
}

/// `price * 10^(9 - expo)` → u64 (price_e9). `expo` is the POSITIVE Lazer exponent (decimals).
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
        assert_eq!(normalize_to_e9(6_786_596_052, 8), Some(67_865_960_520));
    }

    #[test]
    fn normalize_expo_9_identity() {
        assert_eq!(normalize_to_e9(147_123_456_789, 9), Some(147_123_456_789));
    }

    #[test]
    fn normalize_expo_10_divides() {
        assert_eq!(normalize_to_e9(1_471_234_567_890, 10), Some(147_123_456_789));
    }
}
