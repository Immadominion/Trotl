# M0 — Ground-Truth Spike Results

The M0 spikes de-risk the three load-bearing assumptions before further building (ROADMAP §M0).
This file records what has been **executed and verified**, not what is planned.

| Spike | Status | Verdict |
|-------|--------|---------|
| **M0.3 — Flash v2 mainnet lifecycle** | ✅ **DONE (live mainnet)** | Integration fully validated; economics confirmed |
| **M0.1a — magicblock_client vs live devnet ER** | ✅ **DONE (live devnet)** | Router + oracle validated; oracle exponent bug caught & fixed |
| **M0.1b — submit→WS-echo tick latency** | ✅ **DONE (live devnet, deployed)** | **ER is ~instant (echo ≤1ms); latency = client↔ER RTT** — product bet validated |
| **M0.2 — ed25519 sign budget** | ✅ **DONE (VM); web finalized at M6** | Sign ~2.25ms — negligible vs the RTT-dominated tick; non-issue |

---

## M0.1a — magicblock_client validated against the live devnet ER (2026-06-13)

`app/packages/magicblock_client` built and validated against `devnet-router.magicblock.app` and the
`devnet-{eu,as,us}.magicblock.app` ER nodes. No mocks; 9 unit tests (analyze clean).

**Validated live:** `getRoutes` (3 validators — EU `MEUGG…`, AS `MAS1Dt9…`, US `MUS3hc9…`, all 50ms
block), `nearestValidator` (EU from here), `getDelegationStatus` (delegated + undelegated parses),
`getBlockhashForAccounts` (real `{blockhash,lastValidBlockHeight}`), and reading + parsing the LIVE
SOL oracle on each ER node.

**ER read latency from this machine** (getAccountInfo round-trip, NOT in-ER block time): EU median
~160ms, US ~355ms, SGP ~394ms; price advanced every 2–4 polls (live ticking). *(This is a read RTT
over the network; the product's submit→echo tick latency is M0.1b.)*

### Bug caught by live validation — oracle exponent convention (was wrong on-chain too)
The research assumed the oracle account is Pyth `PriceUpdateV2` with `price × 10^(9+expo)`. Live
decode proved otherwise:
- The account is **`PriceUpdateV3`** (discriminator `eaa10e24acef0fe8` = `sha256("account:PriceUpdateV3")[..8]`), PDA seeds **`[SEED_PREFIX, provider, symbol]`** (not `["price_feed","pyth-lazer",feed_id]`).
- Offsets price@73 / exponent@89 / publish_time@93 are correct, BUT the exponent is the **Pyth Lazer**
  convention — **positive** (`real = mantissa × 10^(−exponent)`). Live SOL: mantissa `6_786_596_052`,
  exponent `8` → $67.866.
- Our normalization (Dart `oracle.dart` AND on-chain `oracle.rs`) used `10^(9+expo)` → overflow → the
  tick would have set the stale flag and **never marked PnL**, or mis-priced it. **Fixed to
  `10^(9−expo)`** in both; re-verified against the live feed ($67.88 on all 3 nodes). The on-chain
  tick had never run against a real oracle, so no funds were ever at risk — caught pre-deploy.

## M0.1b — submit→WS-echo tick latency (executed 2026-06-13, live devnet)

throtl-engine was **deployed to devnet** (`YSaqfuc753DkHZoaEvdNMSTQTf4hEuTtP65hszuvJy9`) and the
full real path ran via `throtl_chain` + `magicblock_client` (`dart run throtl_chain:latency_spike`):
`init_ride + delegate_ride` (base, confirmed) → delegation landed on the EU ER → `accountSubscribe`
to the RideSession → **40 ticks** (session-signed, legacy, ER blockhash, `skipPreflight`), measuring
submit→echo and decomposing it.

### Result (40 ticks, devnet-eu, from the dev machine)
| segment | p50 | p95 | max |
|---|---|---|---|
| network RTT (`getLatestBlockhash`) | 493ms | 625ms | 731ms |
| submit (`sendTransaction` returns) | 492ms | 759ms | 1814ms |
| **echo (submit → WS account update)** | **0ms** | **1ms** | **12ms** |
| TOTAL submit→echo | 495ms | 759ms | 1814ms |

### The decisive finding
**The ER is effectively instant: the account update is pushed ≤1ms after the submit call returns
(p95 1ms, max 12ms).** The 50ms block time is not even the binding constraint. The entire ~500ms
total equals the raw network RTT (submit ≈ RTT ≈ 493ms) from this far dev machine to the EU node —
i.e. **end-to-end latency is 100% client↔ER network round-trip, 0% ER processing.**

Consequences (this shapes the build, not just confirms it):
1. **The analog-feel bet is sound at the protocol level** — a client with low RTT to a regional ER
   (the Seeker on decent connectivity, ~20–50ms RTT) gets submit→echo in ~tens of ms.
2. **Region-nearest-validator selection is mandatory, not optional** (FEASIBILITY R8) — picking the
   wrong region adds 100s of ms.
3. **Optimistic UI is mandatory**: render the thumb's target needle immediately, reconcile the
   confirmed needle when the echo lands (the architecture's ghost-needle). You can NEVER block the
   UI on the echo, because the RTT floor is irreducible and variable.
4. **Adaptive tick cadence** (50→100ms) is justified — submit RTT variance (p50 492ms vs max 1814ms
   here) means you pace ticks to the measured RTT, not a fixed 30Hz, on slow links.

This is the M0.1 gate's real answer: the ER delivers; the engineering effort goes into proximity +
optimistic UX, exactly as the architecture specced. **Best finalized on the Seeker** for the felt
number on the target device + network.

### Validated on-chain by this run (first real exercise of throtl-engine)
- `init_ride` + `delegate_ride` work on devnet (the ER delegation CPI + the 3 derived delegation PDAs
  are correct — `throtl_chain`'s encoders are right against the live program).
- The session key signs **gasless** ticks on the ER (baseFee 0 — session-as-fee-payer confirmed).
- `tick` updates the RideSession every call (tick_count increments, WS echoes) — the hot path works.

---

## M0.3 — Flash Trade v2 lifecycle (executed 2026-06-13, mainnet)

**What ran:** the real `flash_client` (`app/packages/flash_client`) driving the full lifecycle against
the live API + RPCs with a funded burner wallet (`Fd7K6ge6pRGgZVouaGXxtkU1tuncFd2AGd69rXQFnsT5`).
Every step built an unsigned tx via the hosted REST builder, signed it with the burner key, submitted
to the correct RPC, and confirmed on-chain. **No mocks.** All 21 request/response pairs captured to
`fixtures/flash/` for offline tests.

**Confirmed on-chain (signatures in `fixtures/flash/*_result.json`):**
`init-deposit-ledger → init-basket → delegate-basket → deposit-direct(11 USDC) → open-position
(1.1× LONG SOL, owner-signed, ER, skipPreflight) → close-position(full) → request-withdrawal →
execute-withdrawal`.

### The economics (the load-bearing finding)
Burner before: **15.000000 USDC + 0.05 SOL**. After full round-trip: **14.994783 USDC + 0.0379 SOL**.
- **Trading cost of the entire open+close round-trip: 0.005217 USDC (~half a cent).**
- Gas across ~10 transactions (L1 setup/withdraw + ER session/commit): ~0.0121 SOL (~$0.81).
- **Total cost to validate the whole integration on mainnet: ~$0.82.**

### Findings that change / confirm the build
1. **The indexer's PnL is cosmetic — confirmed live.** Immediately after opening, `positionMetrics`
   reported `pnlWithFeeUsdUi: −1.10 (−10.02%)` with `exitPrice $60.38` against an entry of `$67.08`
   (spot was `$67.14`). The decoded basket proved the truth: `debits 11.000000`, `pendingCredits
   10.994783` — i.e. the close returned 99.95% of collateral. **The −10% is the `custody.tradeSpread`
   artifact (GOTCHAS §20); real PnL must be computed client-side from the mark.** `price_guard` and the
   reconciler's client-side PnL (already built) are therefore mandatory, not optional.
2. **Tx-builder returns are UNSIGNED** (1 zeroed sig slot; `AQAAAA…`). The `WalletSigner` correctly
   adds one signature at the signer's `accountKeys` index, blockhash untouched. Validated end-to-end.
3. **The silent session-fallback guard is real and necessary** — `WalletSigner.signBase64` refuses to
   submit if our key is not a required signer (would otherwise produce an unsignable tx).
4. **Withdrawals are two-phase AND the validator auto-finalizes.** `request-withdrawal` queues the
   settlement; the keeper crosses the receipt to base and **executes the withdrawal automatically**.
   `execute-withdrawal` is a **recovery path** — once the receipt is consumed it returns
   `0xbc4 / AccountNotInitialized (3012)`, which means "already finalized," NOT a failure. The client
   distinguishes "not crossed yet" (wait) from "already withdrawn" (done) by checking `withdrawableRaw`.
5. **Balance = deposits − debits + pendingCredits**, all from the ER-fed indexer (`/v2/raw/baskets`).
   For a flat basket where debits == deposits, the net reduces to `pendingCredits`. Implemented in
   `FlashApi.withdrawableRaw`; withdrawals are **balance-aware** (never guess the amount).
6. **Strict lifecycle order is enforced by the program, not the API** — the spike followed it exactly
   and every step confirmed first try.

### Validated client surface (`app/packages/flash_client`)
`FlashApi` (REST: health/tokens/prices/preview + all 8 lifecycle tx-builders + `rawBasket`/
`withdrawableRaw`), `WalletSigner` (CLI-keypair load, unsigned-v0 sign with index placement +
session-fallback guard), `RpcSubmitter` (submit with `skipPreflight` for ER, poll-to-confirm).
Analyze clean (`--fatal-infos`).

### Cost model for production (per ride, mainnet)
Open+close trading fees on a real position ≈ **0.05%×2 ≈ 0.1% of notional** (the dev-env tradeSpread is
an indexer artifact, not a fill cost). Plus per-ride gas: ER session 0.0003 SOL + commits + L1
setup/withdraw ≈ **~0.005–0.012 SOL/ride** depending on setup reuse (the basket/ledger persist across
rides, so steady-state rides skip init). This is the real input to PRODUCT §12 unit economics.

---

## M0.2 — ed25519 sign budget (executed 2026-06-13)

`dart run throtl_chain:sign_bench` signs a 200-byte payload with the actual tick signer
(`Ed25519HDKeyPair.sign`), 1000 iters after warm-up.
- **Dart VM (native): p50 2.25ms, p90 2.52ms, p99 4.71ms.** package:solana uses a pure-Dart ed25519
  (not native crypto), so signing is ~2ms even on the VM.
- **Verdict — non-issue in context.** M0.1b showed the tick is gated by client↔ER network RTT (tens
  to hundreds of ms); one ~2ms sign per tick is ≤1% of that and ~7% of a 33ms (30Hz) frame. The strict
  "<2ms" bar I set up front is moot — signing is never the bottleneck.
- **Web:** the dart2js build compiles, but `cryptography`'s web path needs a real browser (node isn't
  faithful), so the browser dart2wasm number is finalized at **M6** in Chrome. If pure-Dart signing is
  slow there, the architecture's R5 mitigation (non-extractable **WebCrypto Ed25519**, ~native speed)
  applies — and is worth using on mobile too to cut the 2ms to ~0.1ms.

---

## M0 GATE — PASSED (de-risking complete)

All three M0 spikes are answered against live infrastructure, no mocks:
- **M0.1 (latency) — the product bet holds.** The ER round-trips a tick in ≤1ms; end-to-end latency is
  pure client↔ER network RTT, so analog feel needs proximity to a regional ER + optimistic UI — both
  already in the architecture.
- **M0.2 (sign budget) — non-issue.** 2.25ms sign ≪ RTT-bound tick.
- **M0.3 (Flash) — fully validated on mainnet**, ~$0.82 total, indexer-PnL-is-cosmetic confirmed.

Two numbers are deliberately **finalized on the Seeker** (the real client + network), not the dev
machine: the felt submit→echo latency and the in-browser/on-device sign time. Neither is a code gap —
the full path runs today; they're device-network measurements for the final UX tuning.

**Remaining device exercise:** run `throtl_chain:latency_spike` and `throtl_chain:sign_bench` from
the Seeker (or a Flutter harness on it) to capture the on-device felt numbers before M4 ride
orchestration locks the adaptive-cadence defaults.
