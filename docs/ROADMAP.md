# THROTL — Engineering Roadmap

**Version:** 1.1 · June 13, 2026 (revised after docs-review: Anchor M1, web→post-launch, added line items)
**Scope:** logic only. UI lands in parallel from the designer track ([PRODUCT.md](PRODUCT.md) §16) and binds to interfaces defined here.
**Inputs:** [FEASIBILITY.md](FEASIBILITY.md) (decisions DR-1…DR-7, risks R1…R9), [ARCHITECTURE.md](ARCHITECTURE.md).
**Sequencing:** milestone-relative. Effort tags for a solo dev: S (≤2 days) · M (≤1 week) · L (1–3 weeks). Milestones are gates, not calendar. `[REV]` = changed in v1.1.

---

## Milestone 0 — Ground Truth Spikes
*Goal: kill the assumptions that could invalidate the architecture before writing real code. Throwaway-grade. Maps to FEASIBILITY §7.*

| # | Spike | Proves | Bar | Effort |
|---|---|---|---|---|
| 0.1 | Dart tick round-trip: bare Dart CLI + `package:solana`; delegate the official `anchor-counter` PDA on **devnet ER** `[REV: anchor not pinocchio]`; spam increment txs (legacy, session-keypair-signed, `skipPreflight`) at 30Hz; measure **submit→WS-echo** latency from a real Android phone (WiFi + LTE), nearest region | The product bet (R8); espresso `SubscriptionClient` works against `wss://<er-fqdn>` (OEQ-1); **ER blockhash validity window** via `getBlockhashForAccounts` (OEQ-2) | p95 < 80ms WiFi, < 150ms LTE submit→echo; zero dropped echoes over 5-min run | M |
| 0.2 | ed25519 sign bench: ~200B legacy tx message under dart2js AND dart2wasm (Chrome/Safari) + Android release | Web hot path (R5); the `touch→sign` latency segment | p99 < 2ms web; < 0.5ms Android | S |
| 0.3 | Flash mainnet hand-shake: burner wallet + ~$25 USDC, full lifecycle in hand-rolled Dart: ledger→basket→delegate→deposit($15 fuel)→open SOL long→partial close→full close→tp-sl place/cancel→request+execute withdrawal. **Record every request/response as fixtures.** Also verify: unsigned-tx + single-signature; **which endpoints honor the session signer (esp. remove-collateral/withdrawal — OEQ-3)**; the silent-fallback detector; 97%/$11/two-phase-withdrawal | API behaves as documented (R3/R6); §3.2 blast-radius claim; session_v2 from Dart | Complete round trip; fixtures committed; < $5 fees | M |
| 0.4 | Anchor ER hello `[REV]`: build + deploy `anchor-counter` to devnet ER; run delegate→tick→commit→undelegate; wire **mollusk + CU bench** into the repo | Toolchain (solana-cli 3.x, anchor 1.0.2, ephemeral-rollups-sdk pin, dlp.so fixture); the Phase-2 CU baseline | Green mollusk + devnet cycle; CU number recorded | S |

**Gate G0:** all four bars met → proceed. Pre-agreed fallbacks: 0.1 fail ⇒ adaptive 100ms base tick; 0.2 fail ⇒ WebCrypto signer or web ships read-only Black Box first; 0.3 reveals session can't sign trades ⇒ owner-signs-each (kills the popup-free feel — escalate before building).

---

## Milestone 1 — `throtl-engine` (Anchor + zero_copy) `[REV — was Pinocchio, now ~3–5 days not 2–3 weeks]`
*Scaffold from `anchor-counter` (ephemeral-rollups-sdk anchor example), not from scratch.*

1. **1.1** Repo + toolchain: Anchor 1.0.2, `ephemeral-rollups-sdk` (anchor feature), CI (build, clippy `-D warnings`, mollusk, litesvm, **CU budget assert**). — S
2. **1.2** `RideSession` `#[zero_copy]` per ARCHITECTURE §2.1; static layout test; fixed-point module (§2.2) with the **accounting invariant + shared Rust↔Dart test vectors** (cross-zero sub-cent, ±1 ulp of −fuel, i64 saturation, bankrupt-then-increase). — M
3. **1.3** ix 0/1/7 (`init_ride`, `delegate_ride` with explicit `commit_frequency_ms`, `close_ride`) + constraints + `#[ephemeral]` (gives #6 `process_undelegation` free). — S
4. **1.4** ix 2 (`tick`): oracle offset-parse (owner/feed/staleness gates), effective-equity floor predicate, VWAP settle, status FSM. Mollusk adversarial cases (wrong oracle owner, stale, expired/wrong signer, overflow, status/ bankrupt violations) + **CU bench recorded** (the Phase-2 trigger baseline). — M
5. **1.5** ix 3/4/5 (`flatten`, `freeze`, `request_settle` with `MagicIntentBundleBuilder`) + crank `ScheduleTask`/`CancelTask`. **Resolve OEQ-4** (crank-carries-commit?) by experiment; fall back to freeze-only crank (no loss-bound impact — crank is alert-only). — M
6. **1.6** Fuzz: litesvm random tick/flatten/freeze sequences vs a Rust reference model — state equivalence each step. — S
7. **1.7** IDL artifact (Anchor emits it free); devnet ER deploy; full lifecycle integration test (nightly CI vs devnet). — S
8. **1.8** **Security pass #1 (self):** §2.3 checklist instruction-by-instruction → `docs/security/checklist-m1.md`. — S

**Gate G1:** mollusk+litesvm green, CU bench recorded, fuzz clean, devnet lifecycle green, checklist signed. *(Phase-2 note: a Pinocchio port is triggered ONLY if measured `tick` CU × realistic concurrent rides threatens ER throughput — DR-1. Not a v1 task.)*

## Milestone 2 — Dart chain layer (`magicblock_client`, `flash_client`, `throtl_chain`, `price_guard`) `[REV: +price_guard]`
*Pure logic; no Flutter. Runs against fixtures + devnet + the M0.3 burner.*

1. **2.1** Monorepo: melos/pub-workspace, package skeletons, dependency-rule lint, CI matrix (`dart test` per package; `flutter build web --wasm` gate). — S
2. **2.2** `magicblock_client`: 4 router RPCs, ER RPC wrapper (legacy-only guard, skipPreflight), WS subscription manager (reconnect, gap detection), Lazer parser (+staleness), region picker, **blockhash tracker keyed on `lastValidBlockHeight`** (not wall-clock). — M
3. **2.3** `throtl_chain`: ix encoders for all 8 (hand-written, golden-byte tests vs Rust fixtures from M1), `RideSession` zero_copy reader (offset-pinned), session keypair lifecycle (Keystore-backed interface). — M
4. **2.4** `flash_client`: typed REST client checked against the **vendored OpenAPI**; lifecycle FSM (§3.1, **fuel-only deposit**); `create_session_v2` ix + **silent-fallback detector**; owner-WS merger; client-side PnL/SL/liq math (golden tests vs M0.3 reality); token bucket; typed `FlashError`. — L
5. **2.5** `price_guard` `[REV]`: independent Hermes/L1 Pyth reader for the §3.3 cross-check; divergence-threshold logic. — S
6. **2.6** Contract-drift canary: nightly CI replays shape-only fixture checks vs live API (no funds; preview-mode + `/health` + `/tokens` schema). — S
7. **2.7** **External (start NOW, non-blocking):** contact Flash team — builder-code onboarding + **v2 attribution wiring** (R7) + production rate-limit headroom. — S

**Gate G2:** every package ≥90% branch coverage on FSMs/codecs; golden tests green; one scripted e2e (devnet ER + mainnet-Flash $15): init→delegate→tick storm→reconcile-open(+SL)→flatten→settle→withdraw→revoke.

## Milestone 3 — `throtl_core` (the brain)
1. **3.1** Tick FSM: input quantization, **bottom snap-to-flat dead-zone**, Δ-threshold, adaptive cadence (50→100ms), missed-echo→retry-fresh-blockhash→Degraded(link). — M
2. **3.2** Reconciler FSM per ARCHITECTURE §3.3: band/debounce; action selection (**inline-SL on every open**, flip = close→open-with-inline-SL, 97% overshoot, $12 floor, snap-to-flat); **SL price re-derivation from dollar floor on current real size**; **ER-advisory trust bounds** (local fuel×lev cap, price_guard cross-check, per-action max-delta, N-frame consistency); ≤2 act/s (**flip = 2 actions**); keeper-race re-read-before-retry; market-session input gate. — L
3. **3.3** Guardian FSM: effective-equity floor math (shared §2.2 vectors), layer-3 responsibilities, alert emission. — M
4. **3.4** **Simulation harness** (crown jewel): deterministic virtual market (replayed Lazer traces + synthetic trend/chop/gap/halt), fake Flash with recorded latencies + error/keeper injection, fake ER echo (+ **forged-exposure / price-divergence operator-attack scenarios**). Properties: band invariant never violated beyond debounce+latency; never commands dust; never exceeds rate budget; **no open without an SL across any crash point in a flip**; **no double-open across crash-after-submit-before-confirm**; guardian bounds loss ≤ the §3.4 worst-case formula; crash-resume converges. 10⁴ randomized runs in CI. — L
5. **3.5** Black Box: append-only ride log (ticks, actions, **in-flight signatures written pre-submit**, fills, errors, latencies), replay reader, fee ledger. — M

**Gate G3:** simulation suite green incl. adversarial scenarios (API 500 storms, WS gaps, oracle stalls, floor breach mid-flip, operator forgery, keeper race). Same binary FSMs drive sim and production (no test-only forks).

## Milestone 4 — Platform integration (Android-first)
1. **4.1a** `wallet_api` + `wallet_mwa` **(MWA-1.x path)** `[REV: split]`: `solana_mobile_client` + SIWS-via-`signMessages`; real-device auth matrix (Seed Vault/Seeker, Phantom, Solflare). — M
2. **4.1b** Native MWA-2.0 + SIWS via **vendored/forked** `solana_kit_mobile_wallet_adapter` behind a flag (bus-factor-1 — treat as its own risk, not a toggle). — M
3. **4.2** Ride orchestration in `app`: one-signature ride-start bundle (**incl. SOL-sufficiency check**), FGS guardian (`flutter_foreground_task`, specialUse), **crash-resume flow (in-flight-sig + freeze-flag reconcile first)**. — L
4. **4.3** Funding flows: USDC deposit (QR/address + Jupiter swap), **SOL top-up flow for USDC-only wallets (F2.1a)** `[REV]`, withdrawal two-phase UX, WSOL unwrap. — M
5. **4.4** **Practice mode** `[REV — was missing]`: full tick/PnL engine against **read-only mainnet Lazer prices** with a **mocked settlement layer** (no Flash, simulated Sync instrument); "PRACTICE" watermark; the install→first-practice-ride activation KPI source. — M
6. **4.5** **Share-card render/export** `[REV — was missing]`: offscreen gauge/trace → watermarked image (video deferred, PRODUCT §15.5); %-only by default. — M
7. **4.6** Headless e2e on devnet + tiny-mainnet from a physical Seeker + one mid-range Android: full ride incl. **kill -9 mid-ride** (force a real breach on a $15 position → verify layer-1 SL bounds loss) and **mid-flip crash** (verify no naked stopless position). — M
8. **4.7** Remote-config + kill-switch (signed static JSON), diagnostics screen, structured logging, **opt-in money-path incident sink** (ARCHITECTURE §5). — M

**Gate G4:** scripted device e2e green 10/10; kill -9 demonstrably bounded by venue SL; mid-flip crash leaves no stopless position; session-key revocation verified on-chain.

## Milestone 5 — Hardening & mainnet pilot
1. **5.1** **Security pass #2 (external):** structured peer review of the program against the checklist + the reconciler's money-moving paths; fix-and-rerun. Budget a paid review if possible (R1). — M
2. **5.2** Failure-mode game days: ER node unreachable mid-ride · Flash API down · oracle stale 60s · **price-divergence/operator forgery** · delegation stuck · withdrawal stuck → each lands in the designed Degraded/Fatal state with the documented outcome. — M
3. **5.3** Pilot: 2–4 weeks personal real-money use (fuel ≤ $100, lev ≤ 5x) + 5–10 invited testers; Black Box + incident sink reviewed weekly; band/debounce/SL defaults tuned from data. — L
4. **5.4** Mainnet deploy: upgrade authority → multisig or hardware key; **RideSession migration policy enforced (gate upgrades on zero live delegated rides)**; program close/upgrade runbook. — S
5. **5.5** Ops runbook: status monitoring, drift canary alerts, incident playbooks per drill, **incident-sink triage**. — S

**Gate G5:** pilot exits with zero `Fatal(funds)` incidents, loss bounds honored in every floor event (within the §3.4 formula), signed go/no-go.

## Milestone 6 — Web target + distribution `[REV: explicitly post-mobile-launch, not a launch blocker]`
*Architecture has been web-ready since M3 (single-threaded core, `--wasm` gate). This milestone adds the web wallet + distribution; mobile has already launched.*
1. **6.1** `wallet_web`: js_interop Wallet Standard bridge (connect/signTx/SIWS, Phantom+Solflare+Backpack); non-extractable WebCrypto session key. — L
2. **6.2** Web build: `--wasm` primary + dart2js fallback; network-first SW; adaptive tick verified on mid-tier laptop + Safari. — M
3. **6.3** dApp Store: publisher + app NFTs, signing-key ceremony, listing assets (designer track), submission (2–5 day review). — M
4. **6.4** Launch checklist: kill-switch rehearsal, support channel, PRODUCT §13 geo posture reviewed with counsel before any Play Store step. — S

**Gate G6 = web launch** (mobile launched at G5).

---

## Engineering Process (standing rules)

- **Branching:** trunk-based; short-lived branches; every merge green on the full matrix (cargo suite, `dart test` all packages, wasm build gate, lint/deps rules).
- **Test pyramid:** program (mollusk unit + CU + litesvm fuzz) → codecs (golden bytes Rust↔Dart) → FSMs (property + simulation) → integration (devnet nightly; mainnet-tiny manual/pre-release) → device e2e (per milestone). **Money-path code requires a test that fails if the gotcha regresses** (97% rule, blockhash-untouched, unsigned-tx single-sig, silent-session-fallback, two-phase withdrawal, no-open-without-SL, no-double-open-on-resume).
- **Solo-dev review discipline:** no same-day merge of program or money-path code — write, sleep, re-review against the checklist; security-relevant diffs get a written self-review note.
- **Versioning:** program `version` field + client min-version in remote config from day one; migration policy (ARCHITECTURE §5) enforced.
- **Docs as code:** ARCHITECTURE/FEASIBILITY updated in the same PR as any decision change; corrections logged like FEASIBILITY §4.
- **Spend guards:** burner wallets per environment; mainnet test wallet hard-capped; no CI job ever holds mainnet keys.

## Dependency / parallelization map
M1 (Anchor/Rust) and M2.2–2.5 (Dart) parallelize after G0. M3 needs M2 interfaces only (can start against fixtures). Designer track (PRODUCT §16) runs fully parallel, binding at M4. **External long poles to start NOW:** Flash team contact (2.7), dApp Store publisher NFT (6.3 prereq), counsel question (6.4). **Web (M6) starts only after the mobile launch (G5).**

## Standing risk watch (FEASIBILITY §5)
R1 → Anchor+zero_copy (DR-1) + 1.8/5.1 reviews · R2 → §3.3 ER-advisory bounds + price_guard + 5.2 drills + status monitoring · R3 → 2.6 canary · R4 → vendoring policy · R5 → G0 bars · R6 → fixture discipline + 5.3 pilot · R7 → 2.7 · R8 → 0.1 + region pinning · R9 → 6.4.
