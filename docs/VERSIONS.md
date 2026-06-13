# THROTL — Locked Versions

**Verified live against crates.io / pub.dev / npm / official release manifests on 2026-06-13.**
Pin exactly as written. Floating to `latest` is forbidden where a ⚠️ note explains why.
Re-run the version-lock sweep before each milestone start.

---

## Local toolchain (this machine, 2026-06-13)

| tool | local | required | action |
|------|-------|----------|--------|
| rustc / cargo | 1.95.0 | ≥1.89 | ✅ |
| solana-cli (Agave) | 3.1.10 | 3.1.x | ✅ |
| anchor-cli | 1.0.2 | 1.0.2 | ✅ (via avm) |
| node | 24.5.0 | 24.x | ✅ (Railway runtime = Node 24) |
| pnpm | 10.33.1 | 10.x | ✅ (backend package manager) |
| **flutter** | **3.41.1** | **3.44.2** | ⚠️ **`flutter upgrade` before Dart work** — pub workspaces (Melos 7.8) + `--wasm` stabilized in 3.42–3.44 |
| **dart** | **3.11.0** | **3.12.2** | ⚠️ ships with Flutter 3.44.2; codegen toolchain needs sdk `^3.12.0` |
| melos | 7.8.1 | 7.8.2 | ⚠️ bump for CI parity |
| docker | 29.2.1 | any | ✅ |
| railway | 4.66.0 | any | ✅ |

> The Rust program (M1) needs **none** of Flutter — build it first while the Flutter upgrade is pending.

---

## On-chain program — `programs/throtl-engine` (Rust / Anchor)

```toml
[dependencies]
anchor-lang = { version = "1.0.2", features = ["init-if-needed"] }   # "derive" on by default; add "event-cpi" only if we emit CPI events
ephemeral-rollups-sdk = { version = "0.15.4", features = ["anchor"] } # "anchor" => anchor-modern => anchor-lang ^1.0 (matches 1.0.2). NOT "anchor-compat".
# cranks (layer-2 guardian, M1.5):
magicblock-magic-program-api = "0.12.2"
```

**⚠️ The one thing that will break the build — `solana-program` majors.** Anchor 1.0.2 dropped the
monolithic `solana-program` crate; it depends on **granular `solana-*` crates at major `3.x`**
(`solana-account-info ^3.1`, `solana-pubkey ^3.0`, `solana-cpi ^3.0`, `solana-instruction ^3.0`,
`solana-sysvar ^3.1`, …). `ephemeral-rollups-sdk 0.15.4` also pins `solana-program ^3.0` + granular
`solana-* ^3`. **Do NOT add `solana-program = "4"`** (latest is 4.0.0) — it's a conflicting major.
Use `anchor_lang::solana_program` re-exports; if a CPI target forces the monolithic crate, pin `"3"`.

- We do **not** need `anchor-spl` (state-only program — no token CPIs).
- `anchor-cli` install: `avm install 1.0.2 && avm use 1.0.2`. **Install avm from git, not crates.io**
  (`cargo install --git https://github.com/solana-foundation/anchor avm --force`) — the crates.io `avm`
  is a squatted, unrelated package.
- Repo moved: **`github.com/solana-foundation/anchor`** (coral-xyz 301-redirects). Update CI/avm URLs.
- `Anchor.toml`: `anchor_version = "1.0.2"`.
- ER feature must be `"anchor"` (→ `anchor-modern` → anchor-lang-current ^1.0). **Never `"anchor-compat"`** (legacy 0.28–0.31 path).
- Testing: `mollusk-svm` (instruction-level + CU bench) and `litesvm` (fuzz) — versions confirmed at M1 start (framework-agnostic, execute the compiled `.so`).

---

## Client — `app/` (Flutter / Dart, melos workspace)

```yaml
environment:
  sdk: ^3.12.0          # Dart 3.12.2 (Flutter 3.44.2)
# --- runtime deps ---
dependencies:
  solana: ^0.32.0                       # the load-bearing SDK (v0+ALT, SignedTx.decode/re-sign, WS)
  cryptography: ^2.9.0                  # ed25519 sign/verify; wasm-ready pure Dart
  borsh: ^0.3.3                         # account/struct (de)serialization
  borsh_annotation: ^0.3.2              # (lags borsh by a patch — normal)
  http: ^1.6.0
  web_socket_channel: ^3.0.3            # 3.x = wasm-safe (package:web) — do NOT downgrade to 2.x
  freezed_annotation: ^3.1.0            # in deps (runtime); generator in dev
  json_annotation: ^4.12.0             # MANDATORY 4.12.x (json_serializable 6.14 pins >=4.12 <4.13)
  riverpod: ^3.3.2                      # pure-Dart layers
# --- Flutter app only ---
  flutter_riverpod: ^3.3.2             # MUST match riverpod 3.3.2 exactly
  solana_mobile_client: ^0.1.2          # MWA 1.x (Android) — DR-3 baseline
  flutter_foreground_task: ^9.2.2       # background guardian (FGS, specialUse)
  firebase_messaging: ^16.3.0           # FCM (align firebase_core from same wave)
# --- vendored / flagged ---
  # solana_kit_mobile_wallet_adapter: ^0.4.1   # MWA 2.0 + native SIWS — VENDOR/FORK (bus-factor 1), behind a flag (DR-3)
dev_dependencies:
  melos: ^7.8.2
  build_runner: ^2.15.0
  freezed: ^3.2.5                       # STABLE — do NOT use 4.0.0-dev.1 / 3.2.6-dev.1
  json_serializable: ^6.14.0
  very_good_analysis: ^10.2.0           # strict lint set — pick THIS, not `lints` (mutually exclusive)
```

**⚠️ Codegen toolchain pin (the only real Dart conflict):** `freezed 3.2.5` caps `analyzer <11.0.0`
while `json_serializable 6.14.0` needs `analyzer >=10.0.0` ⇒ resolver lands on `analyzer >=10 <11`
(satisfiable, pub resolves automatically). You will **not** get analyzer 11/12/13 until freezed 4.0
ships stable. Lock the four codegen deps exactly as above.
**No MagicBlock / Pyth-Lazer / Flash Dart SDK exists** (pub.dev confirmed) — `magicblock_client`,
`price_guard`, and `flash_client` are hand-rolled over `package:solana` RPC + `http`/`web_socket_channel`.

---

## Backend — `services/guardian` (TypeScript on Railway, Node 24)

```jsonc
// package.json (pnpm)
{
  "engines": { "node": ">=24" },
  "dependencies": {
    "@solana/web3.js": "1.98.2",            // ⚠️ v1, NOT @solana/kit — see note. Pin EXACT to match flash-sdk
    "flash-sdk": "15.16.16",                // hard-pins @solana/web3.js =1.98.2
    "@solana/spl-token": "0.4.14",
    "hono": "4.12.25",                      // small typed API
    "@hono/node-server": "2.0.4",           // serve() exposes the Node http.Server for ws
    "ws": "8.21.0",                         // Node 24 has a WS *client* only — need ws for the server
    "zod": "4.4.3",                         // v4 (breaking vs 3.x error API)
    "pino": "10.3.1",
    "firebase-admin": "14.0.0",             // FCM push relay; requires node>=22 (ok)
    "ioredis": "5.11.1"                     // only if a Railway Redis service is added (WS fan-out / pub-sub)
  },
  "devDependencies": {
    "typescript": "6.0.3",                  // TS 6 (strict:true greenfield)
    "tsx": "4.22.4",
    "tsup": "8.5.1",
    "vitest": "4.1.8",
    "pino-pretty": "13.1.3",
    "@types/node": "24.13.2",               // ⚠️ pin 24.x to match runtime, NOT 25.x latest
    "@types/ws": "8.18.1"
  }
}
```

**⚠️ web3.js v1, not Kit (decisive):** `flash-sdk@15.16.16` pins `@solana/web3.js =1.98.2` (exact) and
`@magicblock-labs/ephemeral-rollups-sdk@0.15.4` needs `^1.98.0`. Pin the root to **`1.98.2`** to avoid a
duplicate nested install. Kit (`@solana/kit` 6.9.0) would force type-bridging at every SDK boundary — avoid.

**⚠️ Unresolved cross-agent discrepancy to verify at guardian-ER wiring time:** one research agent
reported the MagicBlock **TS** ER SDK depends on `@solana/kit ^4` (+ `@phala/dcap-qvl` TEE), another
reported `@solana/web3.js ^1.98`. **Resolution for V1: the guardian does not need the MagicBlock TS SDK
at all** — it reads Flash position via the Flash v2 REST API, watches price via Pyth Hermes, and submits
the user's pre-signed close-only tx with plain `@solana/web3.js` `Connection.sendRawTransaction` to
`flash.magicblock.xyz`. Only revisit the kit-vs-v1 question if/when we add server-side ER
delegation-watching (post-V1). Keep the guardian's dependency surface minimal.

**Railway deploy:** Node 24 service; nixpacks auto-detects pnpm + `build`/`start` scripts (or use a
Dockerfile for full control — decide at guardian scaffold). Healthcheck on `/healthz`. Env via Railway
variables; Redis (if used) over private networking (`REDIS_URL`). No mainnet keys in any CI job.

---

## Live endpoints (re-confirmed 2026-06-13)

| service | url | note |
|---------|-----|------|
| Flash v2 REST | `https://flashapi.trade/v2` | openapi 3.1.0, build `2a91067…` @ 2026-06-12; 92 markets / 1 pool / 47 tokens; **no auth** |
| Flash ER RPC | `https://flash.magicblock.xyz` | validator identity `FLAshCJGr4SWk23bDVy7yeZecfND8h5Cingy1u2XE6HQ` |
| MagicBlock router (mainnet) | `https://router.magicblock.app` | + WSS same host; CORS `*` |
| MagicBlock router (devnet) | `https://devnet-router.magicblock.app` | our dev target |
| Pyth Hermes | `https://hermes.pyth.network` | independent price cross-check (`price_guard`) |
| Helius RPC | `https://mainnet.helius-rpc.com/?api-key=…` | base L1; domain-lock the key (proxy via guardian on web) |

**Builder-code attribution — still NOT in v2 (re-confirmed):** all 27 v2 `Mb*` DTOs lack any
builder/referral/partner/affiliate field; only legacy v1 DTOs carry `userReferralAccount`. Rebate
revenue requires Flash-team onboarding (FEASIBILITY R7 / PRODUCT §12.1). Non-blocking.

**MagicBlock validator core:** v0.12.3 (hotfix over 0.12.2: more CU for Commit/Finalize/Undelegate).
On-chain API matches the `magicblock-magic-program-api 0.12.2` crate.
