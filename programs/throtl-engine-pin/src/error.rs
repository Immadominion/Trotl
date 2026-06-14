//! Domain errors → `ProgramError::Custom(code)`. Codes mirror the Anchor `ThrotlError` ordinal order
//! (Anchor errors start at 6000; we keep the same offsets so logs/clients read identically).

use pinocchio::error::ProgramError;

/// Custom error codes (Anchor parity: 6000 + ordinal).
#[derive(Clone, Copy)]
#[repr(u32)]
pub enum ThrotlError {
    LeverageTooHigh = 6000,
    LeverageTooLow = 6001,
    InvalidFuel = 6002,
    InvalidLossFloor = 6003,
    ExposureOutOfBounds = 6004,
    InvalidGripMode = 6005,
    UnauthorizedSigner = 6006,
    SessionExpired = 6007,
    InvalidStatus = 6008,
    PdaMismatch = 6009,
    OracleOwnerMismatch = 6010,
    OracleFeedMismatch = 6011,
    OracleStale = 6012,
    OracleInvalidPrice = 6013,
    MathOverflow = 6014,
    SessionTtlTooLong = 6015,
}

impl From<ThrotlError> for ProgramError {
    #[inline]
    fn from(e: ThrotlError) -> Self {
        ProgramError::Custom(e as u32)
    }
}

/// `require!(cond, err)` — return the error if the condition is false.
#[macro_export]
macro_rules! require {
    ($cond:expr, $err:expr) => {
        if !($cond) {
            return Err($err.into());
        }
    };
}
