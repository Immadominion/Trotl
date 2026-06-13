# THROTL — Feasibility Study

**Version:** 1.0 · June 13, 2026
**Status:** Complete — verdict: **GO, with conditions**
**Method:** 5 parallel research tracks, 25 load-bearing claims adversarially verified against primary sources (live endpoint probes, registry APIs, on-chain constants, source code, local builds). Full briefs with citations: [research/flash.md](research/flash.md), [research/flutter.md](research/flutter.md), [research/program.md](research/program.md), [research/magicblock.md](research/magicblock.md), [research/web.md](research/web.md).
**Companion docs:** [PRODUCT.md](PRODUCT.md) (what we're building), [ARCHITECTURE.md](ARCHITECTURE.md) (how), [ROADMAP.md](ROADMAP.md) (when).

---

## 1. Verdict Summary

| Question | Verdict | Confidence |
|---|---|---|
| Can Flutter carry a production Solana perps app? | **Yes** — `package:solana` 0.32.x covers v0 txs + ALTs, base64 re-sign, WS subscriptions, web+wasm | High (source-verified) |
| Can we integrate MagicBlock ER **without Anchor** (Pinocchio)? | **Yes — first-class** (official `ephemeral-rollups-pinocchio` 0.15.4, 4 examples incl. undelegation callback). But *should* we for v1? **No — Anchor+zero_copy for v1, Pinocchio as a measured Phase-2 optimization** (DR-1). | High (crate verified; decision deliberate) |
| Is the Flash Trade v2 API sufficient from Dart (no SDK port)? | **Yes** — REST builder returns unsigned base64 v0 txs with chain-correct blockhash; one ed25519 signature + submit. No auth. | High (live-probed) |
| Does the analog tick loop still need our own ER program? | **Yes** — Flash REST is 10 req/s + 2 HTTP round-trips per adjustment; 20–33Hz continuous control is only possible against our own delegated PDA | High |
| Can the same logic ship to web? | **Yes, conditionally** — CORS is open everywhere; wallet bridge must be hand-rolled (~300–600 LOC js_interop); no isolates on web ⇒ hot path must be single-threaded-by-design | Medium (perf spike required) |
| Can we test properly? | **Mostly** — our program: mollusk/litesvm + devnet ER. Flash: **no devnet exists** ⇒ recorded fixtures + tiny-stake mainnet integration tests | Medium |
| Revenue (builder code) wired at launch? | **Not yet** — v2 request DTOs expose no builder-code fields; requires Flash team onboarding. Not a launch blocker. | High (OpenAPI-verified) |

**The conditions attached to GO:**
1. M0 spikes must confirm: ed25519 sign p99 < 2ms under dart2js/dart2wasm (web hot path); and tick round-trip (send→WS-echo) p95 < 80ms WiFi / < 150ms LTE against the nearest devnet ER from a real phone. *(This is the send→echo segment only; the product's touch→needle budget in PRODUCT §14 adds input + render segments — see the latency-budget note in §5.)*
2. **The loss floor is enforced on the REAL settled Flash position, via a venue stop whose trigger price is derived from the user's dollar floor on the *current* real size and re-placed atomically on every reconciler action** (DR-5). The ER crank cannot close a Flash position (separate execution domain), so it is a secondary "stop-adding + alert" guard, never the money-protecting layer. The promised number is `floor + slippage + 8–10s keeper-hold + virtual-vs-settled band gap`, not the nominal floor — and it is shown at Pre-flight.
3. Flash integration budget assumes mainnet testing with real (tiny) funds from day one (no Flash devnet exists).
4. The session key's honest blast radius is **the ride's deposited fuel** (not the wallet): deposit only fuel into the Basket, short per-ride TTL, revoke on ride end. Consent copy must say so (no "never touches your funds" — the ride session can remove the committed fuel's collateral).

---

## 2. Findings by Domain

### 2.1 Flash Trade v2 ([full brief](research/flash.md))

**The architecture-changing discovery: Flash v2 ("magic-trade") is itself a MagicBlock ER product.** The per-wallet **Basket** PDA is delegated to a Flash ER validator (server-fixed at delegation time; research lists the `MAS1Dt9…` validator family) and trading txs are submitted to the ER RPC `https://flash.magicblock.xyz` (whose `getIdentity` returns the *node* identity `FLAshCJGr4SWk23bDVy7yeZecfND8h5Cingy1u2XE6HQ` — note: the node identity and the delegation-target validator are distinct values; we submit to the RPC regardless). Execution is ~30–50ms, gasless; state auto-commits to L1 every 10s. Consequence: **our reconciler settles into Flash at ER speed** — sub-second fills, not L1-commit-bound.

Integration surface (all live-verified):
- **API:** `https://flashapi.trade/v2`, no auth, REST 10 req/s, WS 5 conn/owner. OpenAPI spec vendored in `flash-trade/examples-v2`.
- **Tx builders** (open/close/reverse/add-remove-collateral/triggers/limits) return **base64 v0 `VersionedTransaction`, UNSIGNED, with chain-correct blockhash pre-filled** (ER blockhash for trades, base for setup/withdrawals). Client adds one signature, must not replace the blockhash, submits to the matching RPC. *(Initial research said "partially signed" — refuted by live probe; they are unsigned today.)*
- **Session keys for Flash:** optional `signer` + `sessionToken` on all 11 trading DTOs; sessions minted client-side via `create_session_v2` on MagicBlock's `KeyspM2ssCJbqUhQ4k7sveSiY4WjnYsrXkC8oDbwde5`. **Trap:** malformed session fields silently fall back to owner-signing.
- **Position model:** one Basket per wallet, **one position per (market, side)** — maps perfectly to Throtl's signed-exposure-per-symbol. Gotchas the reconciler must encode: partial close ≥97% of size silently becomes a full close; `reverse-position` takes a 2% haircut (prefer close+open); open with ≥$11 collateral or TP/SL placement fails; shorts are always USDC; v2 does not support collateral auto-swap (use USDC for everything); max 5 TP + 5 SL + 5 limit orders per market+side.
- **Account lifecycle (strict order):** `init-deposit-ledger → init-basket → delegate-basket → deposit-direct → trade → request-withdrawal → [execute-withdrawal]`. Withdrawals are **two-phase, 30–90s** (settlement receipt crosses to L1) — product must show a "settling" state.
- **Market data:** `/v2/prices` (Pyth Lazer, 200ms), `marketSession` field gates non-24/7 markets; **indexer PnL is spread-priced and can be wildly wrong (−229% vs −4%)** — compute mark-price PnL client-side.
- **No devnet.** v2 API, ER, and prices are mainnet-only. Plan: fixture tests against the OpenAPI shapes + tiny-stake mainnet integration ($11 minimum makes ~$15 positions viable).
- **Builder codes:** 10% rebate tier exists but is manually assigned AND not yet exposed in v2 request DTOs — contact Flash team during M2 (see roadmap); v1 API shows the intended shape.

### 2.2 MagicBlock from Dart ([full brief](research/magicblock.md))

- **Magic Router** (`router.magicblock.app` / devnet) is JSON-RPC with CORS `*` and working WSS — but **NOT a full Solana RPC** (no `simulateTransaction`, `getMinimumBalanceForRentExemption`, `getProgramAccounts`, …). Pointing espresso-cash's `SolanaClient` at it alone breaks. Custom methods that matter: `getDelegationStatus`, `getBlockhashForAccounts`, `getRoutes`, `getIdentity` — each a 10-line raw POST in Dart.
- **Recommended topology (per MagicBlock's own dev-skill):** base RPC for init/delegate; **direct ER fqdn** (fuller RPC + WS subs; espresso `SubscriptionClient` *should* work unmodified against `wss://<er-fqdn>` — research-hedged, **to be confirmed in M0.1**, which already exercises exactly this) for delegated ops; router for discovery. Region chosen at delegation time via validator pubkey (`MAS1`/`MEUG`/`MUS3`, all `baseFee: 0, blockTimeMs: 50`).
- **ER rejects v0 transactions with address lookup tables** (pinned by validator unit test) ⇒ **legacy txs for all ER operations**. Send with `skipPreflight: true`.
- **Session keys: roll our own for throtl-engine.** The official program (`Keysp…`) validates exactly `signer == session_signer && now < valid_until` — replicating that inside our own session PDA (ephemeral pubkey + expiry + scope) drops a dependency, saves an account per tick, and lets us scope by parameters (loss floor, max exposure). Prior art: Drift's `User.delegate`. *(For Flash trades we still use their `Keysp…` program — that's what Flash's program validates.)*
- **Cranks** (`ScheduleTask` CPI to `Magic1111…`, min interval 10ms, validator-signed free executions): persistence is **node-local SQLite only** *(docs' "on-chain TaskContext" is stale — corrected by verification)*, no cross-node failover, no SLA ⇒ cranks are a *primary* guardian, never the *only* one.
- **Fees (on-chain constants):** 0/tx base; 0.0003 SOL/session (at undelegation); 0.0001 SOL/commit after 10 sponsored; 10% of PDA rent at closure. **`commit_frequency_ms` defaults to `u32::MAX` (never)** — we must set it explicitly.
- **Trust assumption stated honestly:** undelegation requires the ER validator's signature; uncommitted state since the last commit is at the operator's mercy; last-committed L1 state is always safe. Mitigation = commit frequency + bounded per-session exposure + Flash-side SL.

### 2.3 Program framework — Pinocchio vs Anchor ([full brief](research/program.md))

The question you asked ("can we use Pinocchio?") has two distinct answers. **CAN we — yes, officially.** **SHOULD we for v1 — no; the research's weighted recommendation is Anchor-with-zero_copy, and we accept it (DR-1).**
- `ephemeral-rollups-pinocchio` **0.15.4** (published 2026-06-12, version-locked to the main SDK) provides delegate/undelegate/commit/`MagicIntentBundleBuilder`/ACL/VRF/crank — `no_std`, with **four official examples**; `pinocchio-counter` hand-implements the undelegation callback against the verified discriminator `sha256("global:process_undelegation")[..8] = [196,28,41,206,48,37,51,167]`. So the ER-without-Anchor blocker is genuinely gone.
- **But the research did not stop at feasibility — it recommended Anchor anyway** (program.md §5, verbatim): *"For a solo dev shipping a production perps app where the on-chain program guards real money, Anchor's constraint system is cheap insurance; Pinocchio is the optimization you do once the tick CU budget inside the ER measurably matters. A pragmatic middle: Anchor with `zero_copy` state … with mollusk CU benches to know exactly when/if a Pinocchio port pays."* The "state-only ⇒ low blast radius" counter-argument is **materially weaker than it first appears**: the on-chain state IS the loss-floor authority and the realized-PnL ledger the reconciler trusts to move real Flash money — a missed owner/signer/overflow check in `tick`/`freeze` is a money-moving bug class even with zero token custody.
- **Pinocchio production status (for the Phase-2 case):** p-token passed two Zellic audits + Neodyme replay + formal verification and **went live on mainnet May 13, 2026, replacing SPL Token**; MagicBlock's own e-token is built on `ephemeral-rollups-pinocchio`. Caveat that decides v1: Zellic explicitly warns the unsafe-heavy style makes it easy for *consumers* to reintroduce UB.
- **Deploy cost (locally reproduced, identical ER counter):** Anchor 311,632B → **2.171 SOL (~$146)**; Pinocchio 57,128B → **0.400 SOL (~$27)** at SOL=$67.15. The real throtl-engine (larger than a counter) is estimated ~$165–210 (Anchor) per the brief. The delta (~$120–180) is **one-time and recoverable** via `solana program close` — not decision-grade against ~2 weeks of solo-dev time + permanent security burden.
- **CU:** tick-equivalent instruction ~5–15k (Anchor) vs <500 (Pinocchio). Fees in the ER are zero either way; CU only matters for ER throughput **headroom** at 20–33Hz — a Phase-2 concern we measure with mollusk benches, not a v1 driver.
- **Pyth Lazer in the ER needs no Anchor** either way: read MagicBlock's oracle PDAs (`PriCems…`, seeds `["price_feed","pyth-lazer",feed_id]`, `PriceUpdateV2` layout) by raw offset — price i64@73, conf u64@81, exponent i32@89, publish_time i64@93. 50ms/200ms cadence per asset.
- **Effort (solo dev, 8 instructions, 1 delegated PDA):** Anchor+zero_copy ~3–5 days; Pinocchio ~2–3 weeks first time. **Anchor collapses the M1 schedule and removes R1's highest-impact risk.**

### 2.4 Flutter × Solana ([full brief](research/flutter.md))

- **`package:solana` 0.32.0+1** (Espresso Cash → Brij, Apr 2026) is the load-bearing SDK and it genuinely covers the hard parts (verified in published archive source): v0 + ALT compile/decompile, **`SignedTx.decode(base64)` → sign → re-encode** (the exact Flash path), ~51 RPC methods, WS subscriptions as Dart Streams, web + wasm-ready, pure-Dart deps. Known sharp edge: a `FIXME` on signature ordering — signature index must match the pubkey's position in `accountKeys`; we pin this with a deterministic test. Missing: `getRecentPrioritizationFees` (raw JSON-RPC, trivial).
- **MWA from Flutter — a fork in the road:**
  - `solana_mobile_client` 0.1.2 (Espresso) — battle-tested but **MWA 1.x** (clientlib 1.1.0): no native SIWS, no `cloneAuthorization`. v0 txs pass through fine (opaque bytes); MWA 2.0 wallets (incl. Seeker's) retain legacy-session support by default.
  - `solana_kit_mobile_wallet_adapter` 0.4.1 (June 2026) — **real MWA 2.0 incl. `sign_in_payload` (SIWS)** but near-zero adoption (bus factor 1) ⇒ usable only if **vendored/forked**.
  - Decision: see DR-3.
- **Single-vendor risk acknowledged:** the whole Dart-Solana stack rests on one pivoting company (Brij) + one 4-month-old port (`solana_kit`). Mitigation: pin exact versions, vendor critical packages, maintain a fork-ready mirror.
- **Ecosystem-author edge (disclosure surfaced by research):** web3flutter.dev and `coral_xyz`/`coral_xyz_codegen` (IDL→Dart, advertises Anchor *and Pinocchio* support) are maintained by this project's owner. Throtl is the forcing function to mature them — but the baseline plan budgets **hand-written instruction encoders** (~2h for 6 instructions) so nothing critical depends on beta tooling.
- **No Dart SDK exists for MagicBlock, Pyth Lazer, or Flash** (pub.dev verified) — the porting tax is enumerated and small: 4 router RPC calls, delegate/undelegate ix building, `create_session_v2` ix, Lazer WS client, Flash REST client.
- **dApp Store:** any release-signed APK, no framework restriction, crypto perps explicitly within policy (jurisdiction docs required for regulated services). Background guardian (while the app lives): `flutter_foreground_task` (specialUse FGS) — dApp Store distribution sidesteps Play's FGS review. *Note: `flutter_foreground_task` + FCM exist as libraries, but in a serverless V1 there is no actor to **send** an FCM wake-up to a dead app, so FCM is not a guardian layer — the dead-app bound is the venue stop only (DR-5).*

### 2.5 Web target ([full brief](research/web.md))

- **Flutter 3.44:** HTML renderer is gone; ship `--wasm` (skwasm) with dart2js fallback. COOP/COEP headers required only for multithreaded rendering. Default service worker is now a no-op — PWA caching is DIY (and should be network-first for a trading app).
- **The hard constraint: no isolates on web.** `compute()` runs on the main thread. The tick hot path (sign → send → decode → reconcile) shares one thread with rendering ⇒ `throtl_core` must be **single-threaded-by-design** (allocation-light, frame-budgeted); isolates become a mobile-only optimization injected at the edge. Adaptive tick degradation (50→100ms) is a UX nicety the hysteresis design already tolerates.
- **Wallet on web:** every packaged option is dead or rejected (merigo = 2.5y stale + legacy `package:js` which **breaks wasm builds**; reown = web `not_planned`). The only path is a **hand-rolled `dart:js_interop` Wallet Standard bridge** (~300–600 LOC) — delivers Phantom/Solflare/Backpack connect, versioned-tx signing, and native SIWS.
- **CORS: no proxy needed anywhere** (live-verified `*` on flashapi.trade, api.prod.flash.trade, flash.magicblock.xyz, MagicBlock routers, Helius). A thin proxy remains justified only to hide a Helius key / future Lazer token.
- **Web session-key custody:** no Keystore on web — hold the session key as a **non-extractable WebCrypto Ed25519 CryptoKey** (XSS can use, not exfiltrate), short TTL, on-chain scope as the real bound.

---

## 3. Decision Records

### DR-1 · Program framework: **Anchor + `#[zero_copy]` for v1; Pinocchio as a measured Phase-2 optimization** (accepted by the user, 2026-06-13)
**Decision:** build `throtl-engine` in Anchor (1.0.2), with the hot `RideSession` PDA declared `#[zero_copy]` (the research's "pragmatic middle"). Wire mollusk CU benches into CI from day one. **Port to Pinocchio only later, and only if measured tick CU actually threatens ER throughput at 20–33Hz** — at which point the port is mechanical (the instruction set is small and the ER plumbing is identical via `ephemeral-rollups-sdk`'s Anchor vs Pinocchio crates).
**Why this overrides the original Pinocchio lean:** the keystone fact is that this program's state is the **loss-floor + realized-PnL authority the reconciler trusts to move real money** — so the "state-only ⇒ Anchor's safety net doesn't matter" argument fails; Anchor's declarative owner/signer/PDA/overflow checks are exactly the insurance a solo dev wants on money-adjacent code. The supposed Pinocchio wins are weak for v1: deploy savings (~$120–180) are one-time and recoverable; CU headroom is a throughput optimization with zero fee impact (ER base fee = 0); and Pinocchio costs ~2 extra weeks plus a permanent, Zellic-flagged UB-surface burden. Anchor collapses M1 to ~3–5 days and removes R1's highest-impact risk.
**What we keep from the Pinocchio analysis:** zero_copy state (no per-tick (de)serialization cost), the mollusk CU regression budget (so the Phase-2 trigger is *data*, not vibes), and offset-based oracle reads (no `pyth-solana-receiver-sdk` Anchor dep needed even in an Anchor program).
**Phase-2 trigger (explicit, measured):** if mollusk shows the `tick` instruction's CU, multiplied by realistic concurrent rides on one ER node, approaches a throughput ceiling that degrades the 20–33Hz feel, *then* port `tick`/`freeze`/`mark` to Pinocchio. Nothing client-side changes except discriminators/encoders.
**Discipline contract (still binding even on Anchor, see ARCHITECTURE §2.3):** explicit constraint annotations reviewed per instruction; checked arithmetic; zero_copy layout pinned by static tests; mollusk happy/adversarial + CU suite in CI; security review before mainnet.

### DR-2 · Two session-key schemes, deliberately
**Our program:** own scheme — `session_key: Pubkey` + `expires_at: i64` + scope (max exposure, loss floor) inside the session PDA. **Flash:** their required `Keysp…` `create_session_v2` (hand-built ix in Dart). One wallet approval bundles both at ride start.

### DR-3 · MWA: ship on `solana_mobile_client`, vendor `solana_kit`'s MWA when SIWS matters
0.1.2 is battle-tested and sufficient (authorize/sign flows negotiate fine on Seeker; SIWS approximated via `signMessages`). Native SIWS + MWA 2.0 arrives by **vendoring** `solana_kit_mobile_wallet_adapter` behind our `wallet_api` interface — never as a bare pub dependency.

### DR-4 · Dual-connection RPC topology (not router-only)
Base RPC (Helius) + direct ER fqdn (ticks, WS subscription on session PDA) + Flash ER RPC (settlement) + router (discovery: `getDelegationStatus`, `getBlockhashForAccounts`). Legacy txs on ER paths.

### DR-5 · Loss-floor: the venue stop is the bound; the crank is an alert (redesigned after review)
The floor is enforced **on the real settled Flash position**, full stop. The two guards do *not* measure the same quantity and must not be sold as interchangeable layers of one guarantee:
1. **Flash-native stop-loss order (the actual money bound).** Placed at ride start and **re-derived + re-placed atomically on every reconciler action** so its trigger price always yields the user's chosen dollar floor *on the current real position size* (not the size at ride start). Executed by Flash's keeper independent of our ER, our app, and the user's phone — the only layer that survives a dead app. Honest limit: an 8–10s price-hold before it fires (research flash.md §7 explicitly says do not *rely* on SL latency — so we bound, disclose, and never call it instantaneous).
2. **ER crank (100ms) — alert + stop-adding, NOT a money bound.** Marks virtual PnL vs Lazer; on floor breach it `freeze`s the session (zeroes virtual target, rejects further ticks) and emits an alert. It **cannot close the Flash position** (separate execution domain — Correction #5). Reliability is single-ER-node (no failover, no SLA — Correction #3), so it is explicitly secondary. Whether a crank-scheduled ix can also carry the L1 commit is **unverified (OEQ-4)** and must not be assumed in any user-facing bound.
3. **App-layer reconciler** (Android foreground service) — the graceful real-time path during normal operation; the working guard while the app lives.

**No FCM "wake-up" layer in V1.** A serverless app cannot send itself a push — there is no actor to trigger it when the app is dead (review blocker). The dead-app case is protected **only** by layer 1. A minimal push relay is a V1.5 candidate if/when a server component is justified. The Pre-flight worst-case loss line therefore reads `floor + slippage + 8–10s keeper-hold + virtual-vs-settled band gap` and is the number we promise — never the nominal floor.

### DR-6 · Testing strategy under "no Flash devnet"
- `throtl-engine`: mollusk (instruction-level + CU regression) + litesvm/solana-program-test with committed `dlp.so` fixture; **devnet ER** for live delegation/tick/commit integration (devnet router exists for *us* — only Flash lacks devnet).
- Flash client: recorded-fixture tests against the vendored OpenAPI spec; **tiny-stake mainnet smoke suite** (~$15 positions, $11 min rule) run manually + pre-release, never in CI secrets-free runs.
- `throtl_core` (reconciler/tick FSMs): pure-Dart property + simulation tests — zero network.

### DR-7 · Monorepo: melos 7.x / pub workspaces, pure-Dart core
`throtl_core` (zero Flutter imports) / `throtl_chain` / `flash_client` / `magicblock_client` / `price_guard` / `wallet_api` + `wallet_mwa` + `wallet_web` / `app`. CI gate: `flutter build web --wasm` on every PR (catches legacy-interop and ffi regressions); `dart test` on core in seconds.

### DR-8 · Server-side guardian on Railway (NEW — 2026-06-13, user enabled Railway)
**Decision:** add a small TypeScript backend service (`services/guardian`) deployed on Railway. This reverses the V1 "serverless" stance of DR-5 *for the safety layer specifically* — and it is the right reversal: the original research (flutter.md §4) explicitly recommended *"a server-side guardian as the real safety net — the phone must never be the only thing protecting the loss floor,"* and the docs-review's #1 and #4 blockers were both consequences of not having one.
**What the guardian does (and only this — it is a safety/ops service, never custody, never required for trading):**
1. **Off-phone loss-floor watcher (the real layer-1 → now layer-0).** Holds NO user keys. It watches each active ride's settled Flash position + an independent Pyth price, and when the floor is breached it does the one thing it *can* do without keys: fires the **FCM push** (now it has a sender — fixes review blocker #4) AND, if the user opted in by **pre-signing a guarded close** at ride start (a transaction the guardian may submit only to flatten, never to open or withdraw), submits that close. The venue-native SL remains the keyless backstop; the guardian closes the 8–10s-keeper-hold gap when it can.
2. **Push relay (FCM).** The actor that was missing in the serverless design.
3. **RPC-key proxy.** Hides the Helius key and any Pyth Lazer token from the client bundle (web especially).
4. **Incident sink + contract-drift canary.** Receives money-path `Fatal` events (no balances); runs the nightly Flash OpenAPI shape canary; surfaces ops alerts. A solo operator stops being blind to production.
**Trust boundary (non-negotiable):** the guardian **never holds the user's wallet key or an open-scoped session key.** Its only money-moving capability is a *user-pre-signed, close-only* transaction the user explicitly authorizes per ride (scoped to flatten that ride's position) — declinable, and the app works (with venue SL only) if declined. Compromise of the guardian = it can flatten positions (annoying, not draining) + spam pushes; it cannot open, resize-up, or withdraw.
**Why TS:** the guardian must build/sign/submit Solana + MagicBlock ER + read Flash; the mature SDKs there are TypeScript (`@solana/*`, MagicBlock TS SDK, Flash examples-v2 are TS), so the backend reuses audited libraries instead of re-porting them to Dart. Stack locked in VERSIONS.md.
**Scope guard:** the guardian is **not** in the trading hot path (the client talks directly to ER + Flash, CORS-open). If Railway is down, trading still works and the venue SL still protects — the guardian degrades to "no off-phone push, venue-SL-only," exactly the prior serverless posture. So it is an *upgrade* to safety, not a *dependency* of trading.

---

## 4. Corrections That Changed the Plan (from adversarial verification)

1. **"Flash txs are partially signed" → REFUTED.** They are **unsigned** with a server-chosen, chain-specific blockhash. Simpler for us (no foreign-signature preservation), same rule: don't touch the blockhash.
2. **"solana_mobile_client is the only maintained Flutter MWA client" → REFUTED.** `solana_kit_mobile_wallet_adapter` 0.4.1 implements real MWA 2.0 + SIWS (June 2026) — too young to depend on, good enough to vendor (DR-3).
3. **"Crank tasks persist in an on-chain TaskContext" → stale docs.** Persistence is node-local SQLite only ⇒ guardian hierarchy (DR-5) treats the crank as primary-but-not-sole.
4. **p-token went mainnet-live May 2026** — strengthens the Pinocchio *Phase-2* case (not the v1 case; v1 is Anchor per DR-1).
5. **The on-chain guardian cannot close Flash positions** (Flash's ER is a separate delegation domain; trades are REST-built) — this single fact forced DR-5's redesign: the venue stop is the bound, the crank is only an alert. *(Surfaced in synthesis, then sharpened by the design-review blocker on guardian-quantity mismatch.)*

**Corrections from the docs-review pass (2026-06-13):**
6. **Loss-floor guardians measured different quantities** (virtual-PnL crank vs venue price-SL) ⇒ the promised dollar floor wasn't actually bounded. Fixed in DR-5 + ARCHITECTURE §3.4: SL price derived from the dollar floor on *current real size*, re-placed on every action; crank demoted to alert.
7. **The flip (close→open) left a naked, stopless window** on real money. Fixed in ARCHITECTURE §3.3: open the new side **with an inline SL in the same builder call**; crash between close and open-with-SL is treated as terminal-flatten; simulation invariant added.
8. **Session-key consent was dishonest** ("never withdraw" — but the Flash session can `remove-collateral`). Fixed: deposit only the ride's fuel into the Basket (blast radius = fuel, not wallet), short TTL, revoke on end; consent copy rewritten (PRODUCT F1.2/§9.2).
9. **FCM "wake-up" guardian had no sender** in a serverless app. Fixed: removed from the V1 guarantee (DR-5); dead-app protection is the venue stop only.
10. **DR-1 contradicted its own research** (chose Pinocchio; research recommended Anchor). Resolved: reversed to Anchor+zero_copy for v1 per the brief, Pinocchio as a measured Phase-2 optimization (user-confirmed).
11. **Double-settle on crash-resume** (re-derived drift acts on lagging WS state). Fixed in ARCHITECTURE §4.1: persist in-flight signature+intent *before* submit; on resume reconcile that signature's status and the freeze flag *before* deriving new actions.
12. **ER-reported exposure drove real trades** with the operator untrusted for uncommitted state. Fixed in ARCHITECTURE §3.3 + R2: ER `virt_exp_bps` is advisory; every reconciler action is hard-bounded by client-side invariants (local fuel×lev cap, independent Hermes price cross-check, per-action max-delta) the operator can't forge.

## 5. Risk Register

| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| R1 | On-chain program bug moves money (missed check, overflow) — state is the floor/PnL authority | L–M | **H** | **Anchor+zero_copy (DR-1)** = declarative constraint checks; checked arithmetic; mollusk happy+adversarial+CU suite; security review gate. Lowered from the Pinocchio-era M by the framework choice |
| R2 | MagicBlock operator dependency — two vectors: (a) undelegation needs validator sig + uncommitted state at operator's mercy; (b) **ER-reported exposure/price drives real Flash trades**, so a malicious/buggy operator could forge `virt_exp_bps` or the in-ER Lazer mark to provoke unwanted real positions | M | H | (a) commit_frequency set explicitly; per-ride exposure bounded by deposited fuel; status API monitoring; self-hosted ER possible later (OSS). (b) **ER state is advisory only** — every reconciler action hard-capped by client-side fuel×lev, cross-checked against an independent Hermes/L1 Pyth read, per-action max-delta, ≤2 act/s; large settlements require consistency across N frames or an L1 commit |
| R3 | Flash v2 API surface changes without notice (no auth/versioning contract, hackathon-fresh reference client) | M | M | Vendor OpenAPI spec; fixture tests pinned to it; contract-drift smoke test in CI (shape-only, no funds); abstraction behind `flash_client` |
| R4 | Dart-Solana single-vendor risk (Brij pivot; solana_kit bus-factor 1) | M | M | Pin + vendor critical packages; fork-ready mirrors; `wallet_api` abstraction makes swaps local |
| R5 | Web hot path misses frame budget (no isolates; dart2js ed25519 unbenchmarked) | M | M | Week-1 spike (<2ms p99 bar); wasm-first; WebCrypto signer fallback; adaptive tick rate |
| R6 | No Flash devnet ⇒ integration bugs reach mainnet | H | M | DR-6 fixture discipline; tiny-stake pilot phase in roadmap before any real-size exposure; kill-switch config |
| R7 | Builder-code revenue not wired in v2 | H | L | Contact Flash team early (M2); v1 shape shows intent; revenue is rebate-only until then |
| R8 | Remote-region ER latency (~2×RTT floor) degrades the analog feel | M | M | Region-nearest validator at delegation; latency shown honestly (product principle); ghost-needle decoupling UX already specced |
| R9 | Regulatory exposure (consumer perps) | M | H | dApp-Store-first distribution; geo-gating capability reserved; counsel review before Play Store (flagged in PRODUCT.md §13, unresolved by design) |

## 6. What We Are Explicitly NOT Doing (scope guards)
- Not porting flash-sdk to Dart (REST suffices). Not building our own perps venue, oracle, or liquidation engine (Flash's). Not depending on MagicBlock's session-keys program for our own program (DR-2). Not running servers in V1 (serverless; the optional web proxy in R5 is dumb/stateless; a push relay is V1.5-only). Not supporting iOS until MWA-on-iOS exists. Not using ALTs on ER paths (rejected by validator). Not shipping web in the V1 launch (architecture is web-ready; web ships post-mobile as ROADMAP M6 — supersedes PRODUCT's earlier "no web app"). Not building throtl-engine in Pinocchio for v1 (Anchor+zero_copy now; Pinocchio is a measured Phase-2 port).

## 7. The Three Things to Prove Before Building (de-risking gate)
Surfaced as the highest-leverage unknowns; all live in ROADMAP M0:
1. **The product bet:** tick send→WS-echo p95 < 80ms WiFi / 150ms LTE from a real phone to the nearest devnet ER, with zero dropped echoes (and the espresso `SubscriptionClient`-on-ER assumption confirmed). If this fails, the analog feel is a lie and the architecture changes.
2. **The web bet:** ed25519 sign p99 < 2ms under dart2js *and* dart2wasm. If it fails, web needs the WebCrypto signer or ships read-only first.
3. **The Flash reality:** a full hand-rolled Dart lifecycle round-trip on mainnet with ~$25 (ledger→basket→delegate→deposit→open→partial-close→full-close→tp-sl→withdraw), capturing fixtures and confirming the unsigned-tx + session-signer + 97%/$11/two-phase-withdrawal behaviors. This is the only way to validate against an API with no devnet and no versioning contract.
