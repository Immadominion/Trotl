# THROTL — System Architecture

**Version:** 1.1 · June 13, 2026 (revised after docs-review: Anchor decision + 4 blocker redesigns)
**Scope:** logic only — programs, clients, state machines, data flows. UI is out of scope (designer-owned; see [PRODUCT.md](PRODUCT.md)).
**Grounding:** every external fact is verified in [FEASIBILITY.md](FEASIBILITY.md) / [research/](research/). Decision records DR-1…DR-7 are binding. Changes in v1.1 are flagged `[REV]`.

---

## 1. System Overview

Throtl is **two execution domains plus a client**, deliberately decoupled:

1. **The virtual layer (ours):** `throtl-engine`, an **Anchor program with a `#[zero_copy]` per-ride `RideSession` PDA** `[REV: was Pinocchio]` delegated to a user-nearest MagicBlock ER. The thumb writes *signed target exposure* into this PDA at 20–33Hz via gasless legacy txs signed by an in-app session key. PnL is marked against MagicBlock's Pyth Lazer oracle PDAs inside the same ER. This layer is the product's feel; **it never holds funds and its reported state is advisory, not an authorization to move money** (see §3.3 trust bounds).
2. **The settlement layer (Flash's):** the user's real money lives in their wallet and a per-ride **Flash Basket** funded with **only the ride's fuel** `[REV]`. The **reconciler** (client-side state machine) translates sustained virtual-exposure drift into real Flash position changes via Flash's REST tx-builder → one signature → `flash.magicblock.xyz`. A Flash-native stop-loss, re-derived on every action, is the real loss bound.
3. **The client (Flutter, melos monorepo):** pure-Dart core logic shared verbatim across Android and web; platform-specific only at the wallet/signing edge.

```
                ┌────────────────────────  PHONE / BROWSER  ───────────────────────┐
                │  app (Flutter)                                                   │
                │   ├── throtl_core   tick FSM · reconciler FSM · guardian FSM   │
                │   │                   VWAP/PnL math · hysteresis band · sim       │
                │   ├── throtl_chain  throtl-engine codecs · delegation ixs    │
                │   ├── magicblock_client  router calls · ER RPC/WS · oracle parse │
                │   ├── flash_client    REST builder · session_v2 · lifecycle FSM  │
                │   └── wallet_api ◄── wallet_mwa (Android) / wallet_web (js_interop)
                └───────┬──────────────────┬───────────────────────┬───────────────┘
            session-key │ legacy txs       │ REST + signed v0 txs  │ one-time MWA sigs
              20-33 Hz  │ (gasless)        │  (+ inline SL)         │ (ride start/end)
                ┌───────▼────────┐  ┌──────▼──────────┐  ┌─────────▼─────────┐
                │ OUR ER (region │  │ FLASH ER        │  │ SOLANA L1 (Helius)│
                │ -nearest node) │  │ flash.magicblock│  │  delegation ·     │
                │ RideSession PDA│  │ .xyz — Basket   │  │  fuel deposit ·   │
                │ Lazer PDAs     │  │ trades ~50ms    │  │  withdrawal ·     │
                │ crank (alert)  │  │ SL keeper       │  │  commits land here│
                └───────┬────────┘  └──────┬──────────┘  └─────────▲─────────┘
                        └── commit / undelegate ───────────────────┘
   independent price cross-check: Hermes/L1 Pyth (NOT the in-ER oracle) ── reconciler guard
```

**Why the two-domain split is irreducible:** Flash's REST builder costs ~2 HTTP round-trips per adjustment under a 10 req/s cap — physically incompatible with 20–33Hz continuous control. Conversely our ER program cannot CPI into Flash's Basket (separate delegation domains). The hysteresis band is the deliberate, visible seam between "what your thumb says" and "what is settled" — surfaced in the product as the Sync instrument. **Critically, the seam is also a trust boundary:** the virtual side is fast but operator-trusted-only-for-feel; the real side moves money and is governed by client-side invariants (§3.3).

---

## 2. On-Chain: `throtl-engine` (Anchor + zero_copy, DR-1)

### 2.1 Account

**`RideSession` PDA** — seeds `["ride", owner, session_id_le]`, owned by throtl-engine, `#[account(zero_copy)]` (no per-tick (de)serialization cost), fixed size (~256B), **delegated to the ER for the ride's duration**. Field layout pinned by a static test (`size_of` + offset asserts):

```rust
#[account(zero_copy)]
#[repr(C)]
pub struct RideSession {
    pub version: u8,          // migration gate (see §5)
    pub bump: u8,
    pub status: u8,           // 0 Init,1 Armed,2 Riding,3 Frozen,4 Settling,5 Closed
    pub grip_mode: u8,        // 0 Hold, 1 Cruise
    pub market_id: u16,       // index into static market table (0=SOL)
    pub _pad0: [u8; 2],
    pub owner: Pubkey,        // parent wallet
    pub session_key: Pubkey,  // in-app ephemeral signer (DR-2: our own scheme)
    pub feed_id: [u8; 32],    // Lazer feed id; integrity-checked vs oracle PDA
    pub expires_at: i64,      // ticks rejected after expiry
    pub fuel_usd_6: u64,      // collateral budget, 1e6 fixed USD (= deposited to Basket)
    pub max_lev_bps: u32,     // 20_000=2x … 100_000=10x (program-capped)
    pub _pad1: [u8; 4],
    pub target_exp_bps: i32,  // thumb: signed, -10_000..10_000 of (fuel×lev)
    pub virt_exp_bps: i32,    // confirmed virtual exposure (the needle)
    pub entry_vwap_e9: u64,   // virtual entry VWAP, 1e9 fixed
    pub realized_pnl_6: i64,  // virtual realized PnL, 1e6 USD (saturating, see §2.2)
    pub last_mark_e9: u64,
    pub last_mark_ts: i64,
    pub loss_floor_6: i64,    // negative; effective-equity breach => freeze
    pub tick_count: u64,
    pub flags: u32,           // bit0 floor_breached, bit1 oracle_stale, bit2 bankrupt
    pub _reserved: [u8; 64],  // migration headroom (§5)
}
```

Rules: **no token accounts, no lamport custody beyond rent** (state-only — DR-1's reduced-blast-radius argument, with the honest caveat that this state *authorizes nothing on its own*; the reconciler, not the chain, gates real trades — §3.3). All USD 1e6, prices 1e9, exposure signed `i32` bps (flat = exactly 0, sign = side). All arithmetic `checked_*`; `realized_pnl_6` updates **saturate to `i64::MIN`/`MAX`** rather than panic (a panic would freeze a ride at an arbitrary tick).

### 2.2 The accounting invariant (specified to remove review ambiguity) `[REV]`

```
unrealized_6   = signed_qty_e* × (mark_e9 − entry_vwap_e9) / SCALE     // wide i128 intermediate
effective_eq_6 = fuel_usd_6 + realized_pnl_6 + unrealized_6
floor_breached = effective_eq_6 ≤ loss_floor_6                         // THE floor predicate
bankrupt       = effective_eq_6 ≤ 0
```

- The **exposure-quantity denominator uses `effective_eq_6`, not original `fuel`**, once realized PnL is negative — otherwise the virtual position overstates size vs the real Flash position the reconciler must mirror. `qty = effective_eq × (lev_bps/10_000) × (bps/10_000) / mark`.
- `tick` **rejects exposure increases** when `effective_eq_6 ≤ loss_floor_6` or `bankrupt`; only reductions/flatten allowed thereafter.
- `closed_qty × price` is computed in a **widened i128 intermediate** before scaling back — prevents both round-to-zero on a sub-cent close at a $100k mark and i64 overflow on a long max-lev BTC Cruise ride.
- The **identical formula** is implemented in `throtl_core` (Dart) and exercised by **shared Rust↔Dart test vectors**, including: cross-through-zero with sub-cent `closed_qty`; realized within 1 ulp of `−fuel`; saturation at `i64::MIN`; bankrupt-then-increase rejection.

### 2.3 Instructions (8) + security checklist

| # | ix | signer | where | notes |
|---|---|---|---|---|
| 0 | `init_ride` | owner (MWA) | L1 | create PDA, validate `max_lev_bps ≤ 100_000`, `fuel > 0`, set session_key/expiry/floor, status=Armed |
| 1 | `delegate_ride` | owner (MWA) | L1 | `#[delegate]` CPI with chosen validator + **explicit `commit_frequency_ms`** (default is *never* — research §2.2); bundled with #0 |
| 2 | `tick` | session_key | ER | hot path: signer==session_key, !expired, status Riding|Armed→Riding; read Lazer PDA (owner==`PriCems…`, feed match, staleness ≤2s gate); settle PnL per §2.2; write target→virt; update mark. zero_copy load; mollusk CU budget tracked |
| 3 | `flatten` | session_key OR owner | ER | target=0, settle realized, status stays Riding |
| 4 | `freeze` | crank (validator) OR owner | ER | sets `flags.0`, zeroes target, status=Frozen, rejects further increases — **alert/stop-adding only; does not and cannot touch Flash** |
| 5 | `request_settle` | session_key OR owner | ER | status=Settling; `MagicIntentBundleBuilder.commit_and_undelegate(&[ride])` |
| 6 | `process_undelegation` | DLP (buffer signer) | L1 | Anchor `#[ephemeral]` injects this (discriminator `[196,28,41,206,48,37,51,167]`) — free with the macro |
| 7 | `close_ride` | owner (MWA) | L1 | requires Settling ∧ undelegated; rent→owner; emits final ride record |

**Crank:** registered on first ER touch — `ScheduleTask{interval: 100ms, instructions: [freeze-if-breached]}` to `Magic1111…`; `CancelTask` in `request_settle`. The freeze re-checks the floor predicate (§2.2) on-chain. Whether a crank-scheduled ix can *also* carry the commit is **OEQ-4 — unverified; not assumed in any loss bound.** Single-node reliability accepted because the crank is layer 2 (alert), not the money bound.

**Oracle read (Anchor, no receiver-sdk dep):** Lazer PDA at seeds `["price_feed","pyth-lazer",feed_id]` of `PriCems5tHihc6UDXDjzjeawomAwBduWMGAi8ZUjppd`; parse by offset (price i64@73, conf u64@81, expo i32@89, publish_time i64@93). Staleness: `now − publish_time > 2s` ⇒ set `flags.1`, tick writes target only (needle freezes honestly), no PnL mark.

**Security checklist (DR-1 discipline contract — binding even on Anchor):** `#[account]` constraints (`has_one = owner`, `seeds`/`bump`, `address = …` on the oracle program) reviewed per instruction; signer table above enforced; `checked_*`/saturating arithmetic everywhere; zero_copy layout pinned by static test; oracle owner+feed+staleness validated; mollusk suite covers every ix happy + adversarial path (wrong oracle owner, stale price, expired/lost session, overflow inputs, status violations, bankrupt) with a CU regression budget; litesvm fuzz of tick/flatten/freeze sequences vs a Rust reference model; **security review before mainnet.**

---

## 3. Settlement: Flash integration (`flash_client`)

### 3.1 Account lifecycle FSM (strict order; server does NOT enforce — we do)
`NoLedger → LedgerInit → BasketInit → BasketDelegated → FuelDeposited → … → WithdrawRequested → WithdrawSettling(30–90s) → Withdrawn`
Transitions = REST builders (`init-deposit-ledger`, `init-basket`, `delegate-basket`, `deposit-direct`, `request-withdrawal`, `execute-withdrawal`) → **unsigned v0 tx returned, add one owner signature, do not touch the blockhash** `[REV: unsigned, not partially-signed]` → submit to **base RPC**. **`deposit-direct` deposits exactly `fuel_usd_6`, never the wallet balance** `[REV]` (this is what bounds the session-key blast radius). Withdrawal settling detected by polling unsigned `simulateTransaction({sigVerify:false, replaceRecentBlockhash:true})` until `execute-withdrawal` stops failing `0xbc4`; SOL arrives as WSOL → unwrap. Balance truth: `ledger.deposits − basket.debits + basket.pendingCredits`, Basket read via **Flash ER RPC** (invisible to L1 `getProgramAccounts`).

### 3.2 Flash session keys (blast radius bounded by fuel, not scope) `[REV]`
At ride start one MWA-signed L1 tx bundles `create_session_v2` on `KeyspM2s…` (PDA `["session_token_v2", FTv2Rx…, session_signer, owner]`, validity = **ride TTL (minutes, not the 1-week max)**, ~0.01 SOL top-up recovered on revoke) using the SAME in-app ephemeral keypair as throtl-engine ticks (one key, two registrations, DR-2). **The honest scope:** Flash's program validates only `signer == session_signer + expiry + PDA derivation` — it does **not** scope per-instruction, so this key can sign `open/close/reverse/add-collateral/remove-collateral` on the Basket. We bound the damage the only way available: **the Basket only ever holds the ride's fuel**, the TTL is per-ride, and we `revoke_session_v2` (free, no wallet sig) on ride end. **Silent-fallback detector:** if the API ignored our `signer`/`sessionToken` fields, the returned tx's required signer is `owner`, not the session key — detect this before submit and **fail loudly** rather than submit an unsignable/owner-requiring tx. (M0.3 must verify which endpoints actually honor session signing — `remove-collateral`/withdrawal especially.)

### 3.3 Reconciler FSM (the heart of `throtl_core`) `[REV throughout]`
**Inputs:** `virt_exp_bps` stream (ER WS on RideSession), settled Flash position (owner WS, `metrics`+`basket` frames merged; **PnL recomputed client-side** — indexer PnL is spread-priced garbage, research §2.1), mark price, market session.

**ER state is ADVISORY, not authorization** `[REV — R2 vector b]`. Before any real settlement action, every input from our ER is bounded by invariants the operator cannot forge:
- **Local cap:** settled size can never exceed the locally-known `fuel × lev`, regardless of what the PDA claims.
- **Independent price cross-check:** the ER's in-rollup Lazer mark is cross-checked against an **independent Hermes/L1 Pyth read**; divergence beyond a threshold ⇒ refuse to settle (`Degraded(price_divergence)`).
- **Per-action max-delta + rate:** ≤2 settlement actions/sec (token bucket on the 10 req/s cap; **a flip counts as 2 actions** — debounce/band prevent flip-thrashing from starving the cap), and a single action's size change is capped so a forged exposure swing can't open a max position in one step.
- **Consistency gate for large settlements:** a large settle requires `virt_exp_bps` consistent across N consecutive WS frames (or an L1-committed value).

**Invariant target:** `|virtual_usd − settled_usd| ≤ band`, `band = max(250 bps × fuel×lev, $12)` (floor > Flash's $11 min so we never command a dust trade).

**Quantization & the bottom dead-zone** `[REV]`: settled exposure quantizes to `{0} ∪ [$11, …]`. A virtual target in `(0, band_floor)` **snaps to flat** — the analog control has a flat dead-zone at the bottom (this IS the detent, PRODUCT §15 Q2), so the Sync instrument shows *synced* instead of a permanent sub-$11 residual.

States: `Synced → Drifting(t₀) → Settling(action) → Synced | Degraded(reason)`. Drift must persist **debounce = 400ms** before acting.

**Action selection (encodes Flash gotchas as policy):**
- increase same side → `open-position` (market), **with inline `stopLoss` derived from the dollar floor on the NEW real size** (never open exposure without an attached stop) `[REV]`.
- reduce → `close-position` with `inputUsdUi`; **if remaining < band_floor or target snaps to flat → full close (`"0"`)**; explicitly handle the **97% overshoot** (a reduce leaving 3–4% silently becomes a full close — tested, not surprising).
- sign flip → **close (full) then open-the-opposite-side-WITH-inline-SL in one builder call** `[REV]`. This collapses the old naked-window: there is never an open position without an SL. A crash between the close and the open-with-SL is **terminal-flatten** (resume verifies no naked stopless position exists; if found, immediately attach SL or flatten). Simulation invariant: *no persisted state across any crash point yields an open position without an SL.*
- **every action that changes size/entry re-derives and re-places the SL** so the venue floor always equals the user's dollar floor on the *current* real size (cancel-all `255` on flatten; ≤5-slot budget respected).

**The loss-floor SL price (made explicit)** `[REV]`: for the current real `size_usd` and side, `sl_trigger = entry × (1 ∓ |loss_floor_6| / size_usd × 0.92)` (the 0.92 mirrors Flash's liq haircut; sign per side). This is the testable invariant the review demanded: the SL is a function of the dollar floor and the live size, recomputed on every action — not a static price set once at ride start.

**Keeper-race handling** `[REV]`: on any close action that errors, **re-read the actual Basket size before retrying**; if already flat/smaller than expected, treat as success (Flash's SL keeper beat us) — **never retry a close into an already-closed position** (which would open a new one).

**Market-session gating** `[REV]`: the thumb input is hard-gated per-symbol on `marketSession` at the input layer; SOL/BTC/ETH are 24/7 so V1 is unaffected, but the gate must exist before any non-24/7 market ships, and an open virtual position when a market closes is force-flattened-or-frozen with input disabled (never left drifting un-settleably; `6005 StaleOraclePrice` ⇒ `Degraded(market_closed)`).

**Error channels** normalized: HTTP 200+`err` (trading) / 400 `{error}` (triggers) / bare 500 (setup) → typed `FlashError`; on-chain codes mapped (6020 slippage → one retry widened; 6005 → market closed). Blockhash TTL: a builder response older than 5s is discarded and rebuilt (~45s server expiry).

### 3.4 Guardian model (redesigned — venue stop is the keyless bound; Railway guardian closes the gap) `[REV — DR-8]`
| layer | lives | watches | acts | survives | money bound? |
|---|---|---|---|---|---|
| 0 **Flash SL** | Flash keeper | mark vs trigger (re-derived per action, §3.3) | **closes the real position** | everything incl. Railway/app/our-ER death | **YES (keyless)** — 8–10s keeper hold is the honest caveat |
| 1 **Railway guardian** `[NEW]` | `services/guardian` | settled Flash pos + independent Pyth | FCM push **and**, if user pre-signed a close-only tx, submits it to flatten (closes the 8–10s gap) | app death, phone death, our-ER death; degrades to push-only if user declined the pre-signed close; absent if Railway down | **partially** — only via the user's pre-signed close-only tx; never opens/withdraws |
| 2 ER crank 100ms | our ER node | effective_eq vs floor | `freeze` (stop adding) + alert; commit *pending OEQ-4* | app death; dies with ER node | **NO** — cannot touch Flash |
| 3 reconciler | app (FGS Android) | drift + floor | settle/flatten gracefully | normal operation only | the working guard while alive |

**Layering logic:** the **venue SL (layer 0) is the only guarantee that survives a total Throtl outage** (Railway down + app dead) — so it is always placed and always the floor of the promise. The **Railway guardian (layer 1)** is the upgrade DR-8 buys: it gives us the off-phone *actor* the serverless design lacked, so the dead-app case gets a push **and** (with the user's pre-signed, close-only, flatten-scoped tx) an active close that closes the keeper-hold gap — without the guardian ever holding an open-capable key. Trust boundary in DR-8: guardian compromise can flatten + spam, never drain.

**Worst-case loss bound shown at Pre-flight** = `realized_loss_at_SL + slippage + 8–10s keeper-hold drift + virtual-vs-settled band gap` — computed against **layer 0 alone** (we never promise better than the keyless guarantee). The Railway guardian improves the *typical* outcome; it does not change the *promised* bound. The leverage/hold-time combinations where even the SL can overshoot the nominal floor are computed and surfaced.

---

## 4. Client Architecture (melos monorepo, DR-7)

```
packages/
  throtl_core/      # PURE Dart. FSMs (tick, reconciler, guardian, flash lifecycle),
                      # VWAP/PnL math (§2.2 vectors), hysteresis policy, simulation harness.
                      # Zero Flutter/network deps. Single-threaded-by-design (web: no isolates).
  throtl_chain/     # throtl-engine ix encoders + RideSession zero_copy reader
                      # (hand-written; coral_xyz codegen may replace later — never a launch dep),
                      #  delegation ixs, session-key mgmt. Depends: package:solana.
  magicblock_client/  # router custom RPCs (getDelegationStatus, getBlockhashForAccounts,
                      #  getRoutes), ER RPC/WS wrappers (legacy-tx enforcement, skipPreflight),
                      #  Lazer PDA parser, region picker.
  flash_client/       # REST tx-builder (vendored OpenAPI), lifecycle FSM, create_session_v2 ix,
                      #  silent-fallback detector, owner-WS merger, typed FlashError, token bucket,
                      #  client-side PnL/SL/liq math.
  price_guard/        # independent Hermes/L1 Pyth reader for the §3.3 cross-check [REV]
  wallet_api/         # abstract: connect(), signTx(bytes), signMessage(), siws()
  wallet_mwa/         # Android (solana_mobile_client 0.1.2; SIWS via signMessages;
                      #  vendored solana_kit MWA-2.0 behind a flag — DR-3)
  wallet_web/         # dart:js_interop Wallet Standard bridge (~300–600 LOC); non-extractable
                      #  WebCrypto Ed25519 session key  [post-mobile, M6]
  app/                # Flutter shell: DI, routing, foreground service, crash-resume. UI separate.
```

**Dependency rule (CI-enforced):** `throtl_core` imports nothing above it; only `app` imports Flutter; `wallet_*` only via `wallet_api`. **Web gate:** `flutter build web --wasm` on every PR (kills legacy `package:js`/ffi/`Isolate.spawn` in shared code).

**Threading:** hot path (sign tick → send → WS echo → FSM step) is allocation-light and frame-budgeted; on Android it *may* move to an isolate as an optimization at the `app` edge; on web it must fit the frame budget (M0 bar: ed25519 sign p99 < 2ms; adaptive degradation 50→100ms is built into the tick FSM).

**RPC topology (DR-4):** `base` = Helius (domain-locked key) · `er` = region-nearest fqdn at delegation (WS: RideSession subscribe — the needle is this echo) · `flashEr` = flash.magicblock.xyz · `router` = discovery · `priceGuard` = Hermes (independent). Behind one `ChainEndpoints` config. Environments: `local` (litesvm/test-validator + dlp.so) / `devnet` (our program full-stack; Flash mocked by fixture server) / `mainnet`.

### 4.1 Key sequences

**Ride start (one MWA interaction):** detect SOL sufficiency `[REV: F2.1a]` → generate session keypair → tx A (L1, legacy): `init_ride` + `delegate_ride` + Flash `init/delegate-basket` + `deposit-direct(fuel only)` + `create_session_v2` → MWA sign+send via base → router `getDelegationStatus` until delegated → ER WS subscribe → place inline-SL-bearing baseline (or place-tp-sl at flat for the floor) → Riding.
**Tick loop (per input frame, 30–50ms):** clamp/quantize thumb (snap-to-flat dead-zone) → if Δtarget ≥ 10 bps: build legacy `tick` ix → **blockhash from `getBlockhashForAccounts`, tracking `lastValidBlockHeight` and refreshing before expiry (NOT a 20s wall-clock — ER block time 50ms means ~7.5s validity if 150-block; M0.1 measures the real window)** `[REV]` → session-key sign → send `skipPreflight` → WS echo updates `virt_exp_bps`. **Missed echo > 250ms ⇒ first retry with a fresh blockhash, then Degraded(link)** `[REV]` (don't jump straight to Degraded — a stale blockhash is the likely cause).
**Ride end:** `flatten` → reconciler drains to flat (full-close) → `cancel-trigger-order(255)` → `request_settle` (commit+undelegate) → poll L1 → `close_ride` → `revoke_session_v2` → withdraw fuel+PnL → Black Box assembled.
**Crash with open position (Cruise):** FGS keeps the reconciler alive; if killed → layer-1 venue SL bounds loss. **On restart, before deriving any new action** `[REV — double-settle fix]`: (1) read the persisted in-flight action's signature + intended delta (written to the Black Box append-log *before* submit) and resolve it via `getSignatureStatuses` (landed/dropped); (2) read `flags.0` (freeze) from RideSession; (3) read the actual Basket size via ER one-shot (not the lagging WS) — *then* resume the FSM from `Drifting`. Simulation property: *no Flash open is issued twice for one drift across crash-after-submit-before-confirm.*

---

## 5. Cross-Cutting

**Error taxonomy:** typed errors in 4 classes — `Transient` (retry w/ jittered backoff: blockhash expiry, 429, WS drop), `Degraded` (visible mode: oracle stale, link latency, market closed, price_divergence), `Fatal(ride)` (freeze + settle: floor breach, session expiry, delegation lost), `Fatal(funds)` (stop-the-world + surface: withdrawal stuck, basket mismatch). No silent retries on anything that moves money; reconciler actions are idempotent **against a persisted in-flight signature** (§4.1), not merely re-derived.

**Observability** `[REV]`: per-user Black Box (every tick, action, error, latency — the debug artifact). **Plus minimal opt-in remote incident reporting for money-path `Fatal` states** (events, never balances — decoupled from the "no analytics on amounts" privacy rule) so a solo operator is not blind to production `Fatal(funds)`/floor-breach incidents (the contract-drift canary catches API shape changes, not runtime incidents). MagicBlock status API polled on Degraded. This is the one sanctioned deviation from strict serverlessness — a write-only error sink (e.g. a managed Sentry-class endpoint), not a guardian.

**RideSession version migration** `[REV]`: `tick` rejects sessions whose `version < program_min_version`, forcing `request_settle` (settle-before-use); upgrades only **widen via `_reserved`** bytes, never repurpose a field; **a program upgrade is gated on zero live delegated rides** (or a forced settle window) since a delegated PDA's ER state can't be touched by the upgraded L1 program until undelegation.

**Config/feature flags:** market table, band params, tick rate, leverage caps, **kill-switch** (disable new rides; existing rides settle-only) as **signed static JSON on a CDN** with embedded defaults — works with zero servers, signature verified in-app.

**Latency budget (named segments, reconciles the three docs' numbers)** `[REV]`: `touch→sign` + `sign→submit` + `submit→WS-echo` + `echo→render` = the PRODUCT §14 `touch→needle` target (p50 ≤ 60ms, p95 ≤ 150ms). **M0.1 measures `submit→WS-echo` only** (bar: p95 < 80ms WiFi / 150ms LTE); the other segments are budgeted separately (touch→sign ≤ 2ms from M0.2; echo→render is the UI track's frame budget). FEASIBILITY conditions and ROADMAP M0 cite the `submit→WS-echo` segment specifically.

**Fees ledger:** per ride accumulate Flash open/close fees (from builder responses) + borrow accrual + ER session 0.0003 + commits 0.0001×(n−10) + rent deltas → Debrief line items (PRODUCT honesty requirement).

**Security model:** parent wallet key never leaves the wallet app (MWA) / extension (web). Session key: Android Keystore-backed / memory-only non-extractable WebCrypto on web, TTL ≤ ride, scope = one RideSession + one Flash session **bounded by deposited fuel**, revocation = `freeze` + `revoke_session_v2` + expiry. The user can always exit through Flash's own UI even if Throtl vanishes — no lock-in by construction.

---

## 6. Open Engineering Questions (tracked in ROADMAP M0/M1)
1. Devnet ER tick echo (WS) p95 < 80ms WiFi from a real phone? espresso `SubscriptionClient` works against `wss://<er-fqdn>`? (M0.1 — the product bet.)
2. ER blockhash validity window via `getBlockhashForAccounts` — empirical (likely ~7.5s at 50ms blocks, not L1's assumed 20s) (M0.1).
3. Which v2 endpoints honor the Flash session signer — esp. `remove-collateral`/withdrawal (M0.3, security-relevant to the §3.2 blast-radius claim).
4. Can a crank-scheduled ix carry `commit_and_undelegate`? If not, the crank stays freeze-only (it's already only an alert — no loss-bound impact) (M1).
5. coral_xyz codegen vs hand-written codecs — decide after M1 IDL; never blocks.
