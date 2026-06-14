# throtl-engine (Pinocchio)

A zero-dependency [Pinocchio](https://github.com/anza-xyz/pinocchio) rewrite of the Anchor
`throtl-engine`, to slash the mainnet deploy/rent cost while keeping it secure and **byte-for-byte
wire-compatible** — same program id, same 8-byte instruction discriminators, same `RideSession`
account layout. **The Dart client (`throtl_chain`) and the Flutter `LiveRideController` are
unchanged.**

## Why

| | Anchor | **Pinocchio** |
|---|---|---|
| `.so` size | 333,832 B (326 KB) | **70,976 B (70 KB)** — **79% smaller** |
| Mainnet rent (deploy) | 2.3247 SOL (~$158) | **~0.50 SOL (~$34)** — saves ~$125 |
| CU (`tick`) | ~hundreds | far lower (Pinocchio zero-copy) |
| Account validation | macros | hand-coded (see audit below) |

MagicBlock Ephemeral Rollups support is **first-class for Pinocchio** via
[`ephemeral-rollups-pinocchio`](https://crates.io/crates/ephemeral-rollups-pinocchio) — the
delegate / commit_and_undelegate / undelegate CPIs are native, no Anchor required.

## Layout

```
src/
  lib.rs           entrypoint + discriminator router (exact Anchor global:<ix> values)
  constants.rs     ids, seeds, status/grip/flags, the wire-contract discriminators
  error.rs         ThrotlError → ProgramError::Custom (Anchor parity: 6000+ordinal)
  math.rs          fixed-point accounting — COPIED VERBATIM from the Anchor build (pure, host-tested)
  oracle.rs        Pyth Lazer PriceUpdateV3 byte-offset parse (10^(9-expo) normalize)
  state.rs         RideSession bytemuck Pod — 264-byte dense layout + 8-byte disc (offsets pinned)
  instructions.rs  the 8 handlers, every Anchor check hand-coded
tests/
  litesvm_smoke.rs runs the real .so: init_ride layout, tick mark-path, imposter rejection
```

## Security (audited; one CRITICAL found + fixed, proven adversarially)

All of Anchor's implicit checks are hand-coded: program-owner on every account read
(`RideSession::load`), `is_signer` on every authority, the 8-byte account discriminator (type
confusion), canonical-bump PDA derivation (`find_program_address` at init, `create_program_address`
re-derive on `tick`), the oracle's owner + feed-id + slice-bounds, and the CPI-hardening pins:
`delegate_ride` requires `owner_program == ID`; `request_settle` pins `magic_program`/`magic_context`.
Sysvars are read via syscall (`Clock::get`), so unspoofable.

**Pre-mainnet audit — one critical found + fixed.** Before mainnet we ran an internal security audit
and closed a critical authorization gap in the undelegation callback (`process_undelegation`): it now
requires the undelegation buffer to be owned by the delegation program, so only a genuine DLP-driven
undelegation is accepted. Fix proven by an adversarial regression test. (Detailed write-up kept in a
private internal report — responsible disclosure, since the root cause is in the shared ER undelegate
primitive used by other programs.)

The adversarial suite (22 runtime tests, all executing real attacks against the compiled `.so`) proves
every guard: the undelegation-authz rejection, init arg bounds, PDA mismatch, exposure bounds, session
expiry, type confusion (foreign-owned look-alike), the oracle honest-freeze on wrong-owner/wrong-feed/
stale/future-dated, close before-settle / non-owner / while-delegated, and freeze authz.

## Build / test / deploy

```bash
cargo build-sbf            # → target/deploy/throtl_engine_pin.so  (~70 KB)
cargo test                 # 15 host tests (math/oracle/layout) + 3 litesvm runtime tests

# Deploy to mainnet at the SAME program id (zero client change). Fund the upgrade-authority wallet
# (FN6Vw…) with ~1 SOL (rent ~0.50 + fees), then:
solana program deploy target/deploy/throtl_engine_pin.so \
  --program-id ../throtl-engine/programs/throtl-engine/keypairs/throtl_engine-keypair.json \
  --url mainnet-beta
```

> Note: a transitive dep (`solana-address/curve25519`, pulled by `ephemeral-rollups-pinocchio`)
> links `std`, so the binary is 70 KB rather than the theoretical 20–50 KB. Forking that crate to use
> the curve25519 syscall instead would shrink it further — a documented follow-up. 70 KB / 0.50 SOL is
> already a 79% / $125 win.
