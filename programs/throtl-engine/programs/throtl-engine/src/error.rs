use anchor_lang::prelude::*;

#[error_code]
pub enum ThrotlError {
    #[msg("Leverage exceeds program ceiling")]
    LeverageTooHigh,
    #[msg("Leverage below minimum")]
    LeverageTooLow,
    #[msg("Fuel must be positive")]
    InvalidFuel,
    #[msg("Loss floor must be a negative bound")]
    InvalidLossFloor,
    #[msg("Target exposure out of bounds")]
    ExposureOutOfBounds,
    #[msg("Invalid grip mode")]
    InvalidGripMode,
    #[msg("Signer is not the authorized session key")]
    UnauthorizedSigner,
    #[msg("Ride session has expired")]
    SessionExpired,
    #[msg("Invalid ride status for this instruction")]
    InvalidStatus,
    #[msg("Ride PDA does not match stored owner/session derivation")]
    PdaMismatch,
    #[msg("Oracle account owner mismatch")]
    OracleOwnerMismatch,
    #[msg("Oracle feed id mismatch")]
    OracleFeedMismatch,
    #[msg("Oracle price is stale")]
    OracleStale,
    #[msg("Oracle price is non-positive or unreadable")]
    OracleInvalidPrice,
    #[msg("Arithmetic overflow")]
    MathOverflow,
}
