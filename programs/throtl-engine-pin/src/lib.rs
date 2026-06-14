//! Throtl Engine (Pinocchio) — the on-chain virtual-exposure layer, rewritten zero-dependency.
//!
//! Byte-for-byte wire-compatible with the Anchor build: the same program id, the same 8-byte
//! instruction discriminators, and the same `RideSession` account layout — so the Dart client
//! (`throtl_chain`) and the Flutter `LiveRideController` are unchanged. A per-ride PDA is delegated
//! to a MagicBlock Ephemeral Rollup; the in-app session key writes signed target exposure via
//! gasless `tick`s, marking PnL against the in-ER Pyth Lazer oracle. Holds no funds.
//!
//! The accounting (`math`) and oracle parse (`oracle`) are host-testable; the instruction handlers +
//! entrypoint do PDA derivation + CPIs (syscalls) and so are compiled only for the BPF target.

#![cfg_attr(target_os = "solana", no_std)]

pub mod constants;
pub mod error;
pub mod math;
pub mod oracle;
pub mod state;

#[cfg(target_os = "solana")]
pub mod instructions;

#[cfg(target_os = "solana")]
mod entrypoint {
    use crate::constants::ix;
    use crate::instructions;
    use pinocchio::error::ProgramError;
    use pinocchio::{AccountView, Address, ProgramResult};

    // A transitive dep (solana-address/curve25519, pulled by ephemeral-rollups-pinocchio) links
    // `std`, so std already provides the global allocator + panic handler — we only emit the
    // program entrypoint (defining our own would collide with std's `panic_impl` lang item).
    pinocchio::program_entrypoint!(process_instruction);

    /// Route by the leading 8-byte (Anchor) discriminator — identical values to the Anchor build.
    pub fn process_instruction(
        _program_id: &Address,
        accounts: &[AccountView],
        instruction_data: &[u8],
    ) -> ProgramResult {
        let (disc, data) = instruction_data
            .split_at_checked(8)
            .ok_or(ProgramError::InvalidInstructionData)?;
        // `disc` is exactly 8 bytes (the split point), so the array conversion can't fail.
        let disc: [u8; 8] = disc.try_into().map_err(|_| ProgramError::InvalidInstructionData)?;

        match disc {
            ix::INIT_RIDE => instructions::init_ride(accounts, data),
            ix::DELEGATE_RIDE => instructions::delegate_ride(accounts, data),
            ix::TICK => instructions::tick(accounts, data),
            ix::FLATTEN => instructions::flatten(accounts),
            ix::FREEZE => instructions::freeze(accounts),
            ix::REQUEST_SETTLE => instructions::request_settle(accounts),
            ix::PROCESS_UNDELEGATION => instructions::process_undelegation(accounts, data),
            ix::CLOSE_RIDE => instructions::close_ride(accounts),
            _ => Err(ProgramError::InvalidInstructionData),
        }
    }
}
