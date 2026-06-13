# THROTL — Product Requirements Document

**Domain:** [throtl.fun](https://throtl.fun)
**Version:** 1.0 · June 12, 2026
**Status:** Approved for design
**Audience:** Product designer (primary), engineering, future contributors
**Companion docs (to follow):** `ARCHITECTURE.md` (engineering), `BRAND.md` (visual identity deep-dive)

---

## 0. One Page Summary

**Throtl is the first analog exchange.** Every trading product ever made is discrete — type a size, pick a leverage, press a button, wait. Throtl makes market exposure *continuous*: a thumb-driven control column where your live perpetual-futures position follows your finger in real time. Push up to lever long, pull down to flip short, ease back to the center detent to go flat. The needle on the gauge isn't UI animation — it's slaved to on-chain tick confirmations arriving every 30–50 milliseconds.

- **Tagline:** *Orders are dead. Hold the market in your hand.*
- **Category:** Self-custodial mobile perps trading (Solana)
- **Platform:** Android-first (Solana Mobile Seeker flagship, Solana dApp Store), Google Play follow-on
- **Execution stack:** MagicBlock Ephemeral Rollups (real-time tick engine) + Flash Trade (settlement venue) + Pyth Lazer (prices)
- **Business model:** Flash Trade builder-code fee rebates (10% of trading fees generated) + Pro subscription
- **What this is not:** not a casino game, not a paper-trading toy, not another order-form-on-a-small-screen. Real positions, real collateral, user-custodied throughout.

The product's soul: **trading as a motor skill, not a form submission.** Everything in this document serves that.

---

## 1. The Problem

### 1.1 The order form has not changed in 30 years

From E*Trade 1996 to Jupiter Mobile 2026, the interaction is identical: choose instrument → enter size → enter leverage → confirm → wait → repeat. On a 6-inch screen this is worse than on desktop: fat-finger errors, confirmation modals stacked three deep, position management buried two tabs away. Mobile perps apps (Jupiter, Phantom Perps, Drift, MetaMask×Hyperliquid) all shipped in the last 18 months and all ported the desktop form factor down. None designed for the hand.

### 1.2 Discrete orders are the wrong abstraction for a continuous instrument

A perp position is a continuous quantity — exposure over time. Traders constantly resize: scale in, trim, flip, flatten. Each adjustment today costs a full order round-trip (10–30 seconds of taps). In fast markets that latency is money. The workaround pros use — hotkeys, ladder click-trading — is desktop-only and still discrete.

### 1.3 Self-custody made it worse, until now

On-chain perps added wallet popups and gas to every adjustment. The result: self-custodial traders adjust *less* often than CEX traders, carrying more unwanted risk. The technology to fix this — gasless, sub-50ms on-chain execution with session keys (MagicBlock Ephemeral Rollups) — only became production-real in the last year (Flash Trade is the proof). **Nobody has built the interface this technology actually makes possible.** Everyone is still drawing order forms on top of a real-time engine.

### 1.4 Why now

- MagicBlock ERs in production: gasless 10–50ms ticks, session keys, Pyth Lazer feeds in-rollup.
- Flash Trade: asset-backed perps on Solana with a transaction-builder API and partner builder codes — settlement is an integration, not a build.
- Solana Mobile: Seeker in users' hands, dApp Store at 160+ apps with zero store fees, SKR developer rewards, an audience that buys phones to use crypto apps.
- Mobile perps demand proven by Jupiter/Phantom launches; differentiation is now pure UX.

---

## 2. The Product Thesis

> **If exposure is continuous, the control should be analog.**

Throtl replaces the order ticket with a **control column** (think: aircraft throttle quadrant, racing pedal, fader on a mixing desk). The position *is* wherever your thumb is. The app's job is to make that mapping feel mechanical, trustworthy, and safe:

1. **Mechanical** — the control has weight, detents, resistance, and haptic texture. It feels like hardware, not a slider.
2. **Trustworthy** — the needle moves only when the chain confirms. Latency is displayed, not hidden. The sync between your virtual (rollup) position and settled (Flash) position is always visible.
3. **Safe** — analog control of leverage is power; the product wraps it in deliberate guardrails (caps, dead-man mode, the Ripcord, loss limits) that are features, not fine print.

---

## 3. Positioning & Brand Posture

| | |
|---|---|
| **Name** | Throtl |
| **Tagline** | Orders are dead. Hold the market in your hand. |
| **Secondary lines** | "The first analog exchange." · "Trading at the speed of touch." · "Fly the market." |
| **Category creation** | *Analog trading.* We never call Throtl "a perps DEX app." We are an instrument, a cockpit, a control surface. |
| **Personality** | Precision instrument, not casino. Aviation/motorsport calm, not memecoin chaos. Confident, terse, mechanical. Think Porsche gauge cluster, B&O remote, flight-sim HOTAS — engineered objects that respect the operator. |
| **What we never do** | Confetti on wins. Slot-machine dopamine patterns. Fake urgency. Hidden fees. Dark-pattern leverage pushes. The brand earns trust by treating leverage like the heavy machinery it is. |

**Vocabulary system** (used consistently in UI, marketing, and this doc):

| Term | Meaning |
|---|---|
| **Ride** | A continuous trading session on one market (open → flat). The unit of use. |
| **Throtl / Column** | The analog control. Up = long, down = short, center détente = flat. |
| **Tick** | One on-chain state update of your virtual position (~30–50ms). |
| **Band** | The hysteresis tolerance between virtual exposure and settled Flash position. |
| **Sync** | The reconciliation state between rollup position and Flash settlement. |
| **Flatten** | Close to zero exposure. |
| **Ripcord** | The emergency flatten-everything gesture/control. |
| **Hold mode** | Dead-man throttle: position exists only while thumb is on the column. |
| **Cruise mode** | Position persists where you leave the column. |
| **Black Box** | Per-ride flight recorder: full tick history, replayable and shareable. |
| **Hangar** | Home screen: markets, balances, past rides. |
| **Cockpit** | The live trading screen. |

---

## 4. Market & Competition

### 4.1 Demand signals
- Jupiter shipped native perps to 1M+ mobile users; Phantom Perps and MetaMask Perps launched within a year — mobile self-custodial leverage is a consensus race.
- Flash Trade does meaningful daily volume as the flagship MagicBlock-powered venue; its builder-code program exists precisely because third-party order flow is valuable.
- Hyperliquid demonstrated that *execution-feel* alone (fast, cheap, responsive) wins billions in volume from incumbents.

### 4.2 Competitive map

| Player | Shape | Why they don't do this |
|---|---|---|
| Jupiter Mobile / Phantom Perps / Drift | Order form on phone | Mainnet/CEX-style stacks can't tick at 30ms gaslessly; form-factor thinking |
| CEX apps (Binance, Bybit, Kraken) | Order form on phone, custodial | Custody model; no incentive to expose ms-granularity consumer control; regulatory surface |
| Flash Trade's own UI | Web terminal | They're a venue; we're a control surface *on top of* their venue — symbiotic, not competitive (we pay them flow) |
| BananaZone, Blitz-alumni trading games | Gamified trading | Games with trading inside; Throtl is real execution with game-grade *feel* |
| Robinhood | The gamified order | Gamified the *order*, can't gamify the *position* — no broker API permits continuous consumer control |

**Moat honesty:** the throttle interaction is copyable in concept. The durable edges are (a) being first and owning the "analog trading" category language, (b) the tick-engine + reconciliation architecture which is genuinely hard to retrofit onto a mainnet stack, (c) mobile-native craft depth (haptics, motion, hardware feel) that takes taste and time, (d) Seeker-flagship distribution position.

---

## 5. Users & Personas

### P1 — "Dami" · The Mobile Scalper (primary)
- 24–35, crypto-native, trades perps daily on Jupiter/Drift mobile or a CEX app; phone is the primary trading device.
- Pain: resizing positions is slow; mobile order UIs cause errors; wallet popups break flow.
- Wants: speed, feel, control, flex-worthy PnL shares.
- Success: Throtl becomes the default for intraday SOL/BTC/meme leverage; opens Throtl 5+ times a day for short rides.

### P2 — "Lena" · The Curious Holder (growth)
- 22–40, holds SOL/USDC in Phantom, has never traded perps — intimidated by order tickets, leverage math, liquidation jargon.
- Pain: existing perps UIs assume expertise; fear of irreversible mistakes.
- Wants: to *feel* what leverage is before committing real size; obvious safety rails.
- Success: completes Flight School (interactive tutorial with practice mode), takes first 2x ride with $25, retains because the control is satisfying and the guardrails are visible.
- **Design implication:** the analog metaphor is itself the teaching tool — "push further = more leverage" is graspable in a way "set margin and leverage multiplier" never was. Onboarding must exploit this.

### P3 — "Kenji" · The Seeker Early Adopter (distribution)
- Bought a Seeker to live on-chain; browses the dApp Store for "only possible here" apps; holds SKR; active in Solana Mobile communities.
- Wants: apps that justify the device — Seed Vault custody, double-tap-to-sign, genuinely mobile-native UX.
- Success: Throtl is his demo app when showing off the phone; reviews it in the dApp Store; evangelizes in community channels.

### Anti-persona
- The "max leverage casino" user seeking 100x lottery tickets. We cap defaults conservatively and never market degenerate leverage. They can go elsewhere; serving them poisons brand and regulatory posture.

---

## 6. Product Principles (designer's north stars)

1. **The needle never lies.** Every gauge reflects confirmed on-chain state. If latency spikes, show it. If sync drifts, show it. Truth is the brand.
2. **One thumb, one decision.** The entire core loop is operable one-handed. Anything requiring two hands or a second screen is secondary UX.
3. **Weight over flash.** Motion conveys mass, resistance, and consequence — not delight for its own sake. No bounce on money.
4. **Safety is a visible feature, not a disclaimer.** Guardrails get first-class UI: beautiful, prominent, satisfying to use. The Ripcord should be the most lovingly designed control in the app.
5. **Earn the first dollar slowly.** Practice mode is free, instant, and unlimited. Real collateral is requested only after the user has felt the instrument.
6. **Respect the operator.** Terse copy, real numbers, no infantilizing. The user is a pilot, not a player.

---

## 7. Feature Specification

### 7.1 Release map

| Tier | Scope | Definition of done |
|---|---|---|
| **V1.0 — "First Flight"** | Everything in §7.2 | A P2 user can install from dApp Store, learn in practice mode, fund, ride SOL-PERP with real money, flatten, and share a Black Box card — with zero confusion and zero custody. |
| **V1.5 — "Instrument Rating"** | §7.3 | Pro subscription live; multi-market; advanced cockpit |
| **V2.0 — "Squadron"** | §7.4 | Social layer (The Pit), Ripcord standalone widget, iOS investigation |

### 7.2 V1.0 — Core feature set

#### F1. Onboarding & Flight School
- **F1.1 Wallet connect:** Mobile Wallet Adapter + Sign-In-With-Solana. On Seeker: Seed Vault wallet with biometric/double-tap signing. Fallback: any MWA wallet (Phantom, Solflare). No email, no password, no KYC form (see §13 compliance). *Engineering note (ARCHITECTURE DR-3): V1 ships on the maintained MWA-1.x Flutter client with SIWS approximated via `signMessages`; native MWA-2.0 SIWS arrives by vendoring `solana_kit`'s adapter — the on-screen sign-in moment is identical either way, so this is invisible to the user but must be reflected in the design's auth copy.*
- **F1.2 Session key provisioning:** explained in one screen of human language, and the copy must be **literally true** (the honesty principle, §6.1). The session key signs two things: (a) throtl-engine position adjustments — scoped on-chain to one ride's exposure and loss floor; (b) Flash Trade trade instructions on the **ride's Basket** — which Flash's program does *not* scope per-instruction, so the key can resize **and remove collateral** on that Basket until expiry/revoke. The blast radius is bounded **not by the key's scope but by what's in the Basket**: we deposit **only the ride's fuel** into the Basket, never the wallet's whole balance (see F2.2). Therefore the honest guarantee is: *"This key can open, resize, and close positions with the fuel you've committed to this ride — up to that fuel, never your wallet's other funds, and never a transfer to anyone else. It expires when the ride ends and is revoked immediately after."* Do **not** display "can never touch your funds" — display the bounded-to-fuel truth, the expiry countdown, and a one-tap revoke. Re-provisioned per ride; revocable in Settings.
- **F1.3 Flight School:** mandatory-but-fast interactive tutorial (≤90 seconds) in practice mode: push, feel the haptic ticks, see PnL move, pull the Ripcord. Teaches the three gestures (push/pull, center detent, ripcord-flick) by doing, not reading. Ends with a "license" moment (subtle, classy — not a gamification badge wall).
- **F1.4 Practice mode:** full cockpit against **live mainnet Pyth Lazer prices** (read-only) with simulated $10,000 collateral. *Engineering reality (ARCHITECTURE §3.5, ROADMAP M3): Flash has no devnet and Lazer prices are mainnet-only, so practice runs the real tick/PnL engine against a **mocked settlement layer** — there is no real Basket and no Flash calls. The Sync instrument shows a simulated reconciler. This is honest (watermarked "PRACTICE") and is the source of the install→first-practice-ride activation KPI.* Watermarked "PRACTICE" across gauges. Always accessible later from the Hangar. No time limit, no nag — but a persistent, quiet "go live" affordance.

#### F2. Funding & balances
- **F2.1 Deposit:** USDC on Solana into the user's own wallet (we never custody). In-app: receive address + QR, plus deep-links to on-ramp options. Detect zero-USDC wallets holding SOL and offer in-flow swap (Jupiter route) with one confirmation.
- **F2.1a Gas/SOL prerequisite:** starting and settling a ride requires a small amount of **SOL** in the wallet (L1 tx fees + RideSession rent + ~0.01 SOL Flash session top-up + ER session/commit fees — typically well under 0.05 SOL/ride; exact figure surfaced at Pre-flight). The funding flow must **detect a SOL shortfall** (USDC-funded wallet with ~zero SOL — the common on-ramp case) and offer a one-confirmation USDC→SOL top-up before the first ride, mirroring F2.1's reverse swap. A ride must never be started that cannot be settled for lack of gas.
- **F2.2 Collateral allocation ("fuel") — the core safety primitive:** before entering the Cockpit the user commits a per-ride budget. Throtl deposits **exactly this fuel** into the Flash Basket for the ride — never the wallet's whole balance — which is what bounds the session key's blast radius (F1.2). The throttle's full deflection maps to fuel × max leverage, so physical thumb range always equals a known, bounded risk. Default suggestion: ≤20% of wallet USDC. On ride end, fuel + PnL is withdrawn back and the Flash session is revoked.
- **F2.3 Balance display:** wallet USDC, allocated fuel, in-position margin, unrealized PnL — one consolidated readout in the Hangar; abbreviated cluster in the Cockpit.

#### F3. The Cockpit (core screen — see §9.4 for full spec)
- **F3.1 The Column:** vertical analog control, center detent = flat, up = long, down = short. Deflection maps to *signed target exposure* as % of (fuel × leverage cap). Non-linear response curve (fine control near center, coarser at extremes) — exact curve tuned in design/eng collaboration.
- **F3.2 Grip modes:**
  - **Hold (dead-man) mode** — position exists only while thumb is on the column; release = auto-flatten. Default for new users. The purest expression of the product.
  - **Cruise mode** — position persists where set; tap-and-drag to adjust. Unlocked after first 5 completed rides or explicit settings change.
- **F3.3 Tick engine readout:** needle gauge for current confirmed exposure; ghost needle for thumb target; the gap between them *is* the latency made visible (should be nearly invisible at 30–50ms — that's the wow).
- **F3.4 PnL instrumentation:** unrealized PnL (number + analog gauge), entry VWAP, liquidation proximity arc with escalating haptic warning zones.
- **F3.5 Sync indicator:** small dedicated instrument showing virtual-vs-settled drift within the Band, and reconciliation events ("SYNC" pulse when a Flash settlement lands). Tapping it explains the two-layer architecture in one sentence.
- **F3.6 The Ripcord:** emergency flatten. Two activations: (a) hard downward flick anywhere on the column, (b) dedicated pull-handle control (drag-down past threshold with haptic ratchet). Always reachable, never confirm-dialoged — confirmation is the gesture's deliberateness itself. Flattens virtual position instantly (next tick) and force-settles the real Flash position to flat immediately (full-close). *Note: "instant" applies to the virtual needle; the real close is a market order subject to venue latency — the Debrief shows the actual fill, never a fabricated one (§6.1).*
- **F3.7 Leverage cap dial:** pre-ride setting: 2x / 5x / 10x (10x behind an "I understand liquidation" comprehension check, one time). Flash supports far more; we deliberately don't expose it in V1.
- **F3.8 Market status:** funding rate, 24h range, oracle price age. For non-24/7 markets (equities/forex later): market-hours state.

#### F4. Rides, history & the Black Box
- **F4.1 Ride lifecycle:** enter (allocate fuel, pick market, pick grip mode) → ride → flatten/Ripcord/release → debrief.
- **F4.2 Debrief screen:** ride duration, max exposure, realized PnL, fee breakdown (Flash fees + ER session/commit fees, in plain numbers), tick count, max drawdown.
- **F4.3 Black Box replay:** scrubbing replay of the full ride — price line, your exposure ribbon, PnL trace, every tick. This is both the retention feature (improving as a skill loop) and the viral feature.
- **F4.4 Share card:** designed, watermarked image/short video export of a ride replay (no balance amounts unless user opts in — % terms by default). This is the growth engine; design it like a movie poster, not a screenshot. *Engineering note: this needs a runtime render-and-export pipeline (offscreen gauge/trace render → image; video deferred per §15.5), not just a designer asset — it has its own line item (ROADMAP M4.x).*

#### F5. Markets (V1 scope)
- SOL-PERP at launch-quality polish; BTC-PERP and ETH-PERP at parity within V1.0. (One market done perfectly beats five done adequately — the instrument feel is per-market tuned: tick haptics scale with volatility.)

#### F6. Notifications & background safety
- **In-app & foreground-service alerts:** while the app runs (foreground or as an Android foreground service with a live ride), liquidation-proximity, sync-anomaly, and funding-flip alerts fire locally. These do **not** require a server.
- **Background/dead-app honesty (revised — see ARCHITECTURE DR-5):** Throtl V1 is serverless, so when the app is fully killed there is **no actor that can push you a notification** — a serverless app cannot send FCM to itself. We do not pretend otherwise. What protects an open position when the app is dead is the **venue-side stop**: at ride start (and on every resize) Throtl places a Flash-native stop-loss order, derived from your dollar floor on the *current real position size*, executed by Flash's keeper independent of your phone. Its honest limit (an 8–10s price-hold before it fires) is shown in the Pre-flight worst-case loss line, not buried. The on-chain ER crank is a **secondary** guard that freezes virtual exposure and stops adding risk; it cannot itself close a Flash position (separate execution domain), so it is never sold as the money-protecting layer.
- **Optional push backstop (post-V1):** a minimal notification relay that can wake the app/user when the venue stop fires is a candidate for V1.5 once a server component is justified — explicitly out of V1.

#### F6a. The loss floor — what it actually guarantees (honesty requirement)
- The floor is enforced on the **real settled Flash position**, via a stop order whose trigger price is recomputed to yield your chosen dollar floor on the live position size, re-placed atomically on every reconciler action. The worst-case loss shown at Pre-flight is `floor + slippage + 8–10s keeper-hold drift + the virtual-vs-settled band gap` — and that number, not the nominal floor, is what we promise. The design never displays a floor the architecture cannot honor.

#### F7. Settings & account
- Session key management (view scope/expiry, revoke), grip-mode defaults, leverage cap, loss-floor configuration, haptic intensity (off/low/standard/strong), left/right-hand layout mirror, reduced-motion mode, practice-mode reset, export black-box data (JSON/CSV), legal & risk disclosures.

### 7.3 V1.5 — Pro tier ("Instrument Rating")
- **Multi-throttle:** two simultaneous columns (e.g., SOL + BTC) in a split cockpit.
- **Advanced instruments:** funding-rate gauge cluster, open-interest, depth-weighted price, custom gauge layouts.
- **Custom response curves:** adjust the column's sensitivity curve, detent width, haptic texture packs.
- **Extended markets:** Flash's meme pool (BONK/WIF/PENGU…), gold/silver, forex — each with market-hours UX where applicable.
- **Black Box Pro:** frame-accurate video export, side-by-side ride comparison, personal analytics (win rate by hour, hold-duration distributions).
- Pricing hypothesis: $12/mo or annual; free tier remains fully functional for core trading (we monetize flow rebates regardless — Pro is for power, never for safety: **safety features are never paywalled**).

### 7.4 V2.0 — Roadmap themes (design awareness only, no specs yet)
- **The Pit:** scheduled multiplayer floors — shared ephemeral rooms, live flow visibility, session leaderboards (the runner-up hackathon concept becomes the social layer).
- **Ripcord widget:** home-screen/lock-screen widget + wearable companion to flatten from outside the app.
- **Copy-the-hands:** subscribe to a pilot's live column movements (ghost needle of someone you follow) — social without custody.
- **iOS:** pending MWA/iOS landscape; architecture keeps client portable.

### 7.5 Explicit non-goals (V1)
- No spot trading, no swaps-as-a-feature (only as funding convenience), no portfolio tracker ambitions, no chat, no token, no points program, no leverage >10x, no order types (that's the point), no iOS, no tablet layouts.
- **Web: architecture-ready in V1, ships post-mobile-launch (not a launch blocker).** The codebase is built web-capable from day one (pure-Dart logic core, single-threaded-by-design hot path, `--wasm` CI gate — see ARCHITECTURE) so web is never a rewrite. But the web wallet bridge and dApp-Store/PWA distribution are sequenced as ROADMAP M6, *after* the mobile mainnet launch. Mobile is the flagship; the best experience is mobile by design. *(This supersedes the earlier "no web app" line — the requirement is mobile-first, web-soon, not web-never.)*

---

## 8. Information Architecture

```
ROOT
├── Onboarding (first run only)
│   ├── Welcome / thesis (1 screen)
│   ├── Connect wallet (MWA / Seed Vault)
│   ├── Session key explainer + provision
│   └── Flight School (interactive, practice cockpit)
│
├── HANGAR (home tab)
│   ├── Balance cluster (USDC / fuel / in-position)
│   ├── Market cards (SOL · BTC · ETH) → Pre-flight
│   ├── Active ride banner (if open position) → Cockpit
│   ├── Recent rides strip → Black Box
│   └── Practice mode entry
│
├── PRE-FLIGHT (modal sequence)
│   ├── Fuel allocation
│   ├── Leverage cap + grip mode
│   └── Confirm → COCKPIT
│
├── COCKPIT (full-screen, immersive)
│   ├── The Column + gauges (§9.4)
│   ├── Ripcord
│   └── Exit → Debrief
│
├── DEBRIEF → Black Box replay → Share card
│
├── LOGBOOK (history tab)
│   ├── Ride list (filter: market, live/practice)
│   └── Black Box detail/replay
│
└── SETTINGS tab (§7.2 F7)
```

Navigation: 3-tab bar (Hangar · Logbook · Settings) everywhere *except* the Cockpit, which is full-screen immersive with a deliberate exit affordance. The Cockpit is a *place* — entering and leaving it should feel like a state change (motion + haptic + audio cue).

---

## 9. Screen-by-Screen Specification

> For every screen: purpose, content, primary interactions, states. All screens must define: loading, empty, error, offline, and success states. Numbers shown follow the number-formatting spec in §11.4.

### 9.1 Welcome (first run)
- **Purpose:** land the thesis in 5 seconds; one screen, not a carousel.
- **Content:** wordmark, tagline, a *live* miniature throttle the user can immediately touch (price feed live, no wallet needed) — the product demos itself before any signup. Primary CTA: "Enter Flight School." Secondary: "Connect wallet."
- **States:** offline → static rendering of the column with copy "Live feed waits for a connection."

### 9.2 Connect Wallet
- **Purpose:** custody established, identity = wallet.
- **Content:** MWA wallet picker (Seed Vault prioritized on Seeker), SIWS message, what-we-can/can't-do table — copy must match F1.2's bounded-to-fuel truth: "✓ build transactions for you to sign · ✓ open/resize/close positions with the fuel you commit to a ride (per-ride, expiring key) · ✗ move funds to anyone else, ever · ✗ touch wallet funds you haven't committed as fuel". Do not use "withdraw — ever" phrasing (the ride session can remove the committed fuel's collateral; it just can't reach the rest of the wallet or send externally).
- **States:** no wallet installed → store deep-links; rejected auth → calm retry, never guilt.

### 9.3 Pre-flight (fuel / leverage / mode)
- **Purpose:** bound the risk before any market exposure; make config feel like strapping in, not form-filling.
- **Content:** fuel amount (slider + numeric, % of wallet shortcuts: 5/10/20%), leverage cap dial (2x default), grip mode toggle with one-line explanations, computed plain-English consequence line: *"Full deflection = $500 long or short. Liquidation cannot occur above $X price move."* Confirm = single MWA signature (delegation + session key, bundled).
- **States:** insufficient USDC → funding sheet; signature pending → cockpit "spool-up" loader (instrument self-test animation: needles sweep, lights check — this loading state is a brand moment); market closed (future) → hold screen.

### 9.4 THE COCKPIT (the product)
- **Purpose:** the entire core loop lives here. Designer: budget 60%+ of total design effort on this screen and its feel.
- **Layout (portrait, one-handed):**
  - **Right 40% (mirrorable):** the Column — full-height vertical track, center detent, thumb puck. Haptic detent click at zero-crossing. Resistance curve visualized by track markings.
  - **Left 60%:** instrument cluster, vertical stack:
    1. **Exposure gauge** — primary dial; confirmed-position needle + ghost target needle; long sweeps up/right (green-spectrum), short down/left (red-spectrum) — but verify color-blind-safe encoding (redundant: needle texture/labels).
    2. **PnL readout** — large numeric (the only big number on screen) + trend micro-gauge.
    3. **Price strip** — mark price, entry VWAP tick-marked on a mini-range.
    4. **Liquidation arc** — proximity from safe→amber→critical zones; haptic warning ramps from 60% proximity.
    5. **Sync instrument** — band drift + settlement pulses.
  - **Bottom edge:** Ripcord handle (pull-down). **Top corner:** exit (requires flat position or explicit "leave with position open" confirm — the ONE confirmation dialog in the app, because leaving an open position is the one decision that deserves friction).
- **Interactions:** push/pull (exposure), release (Hold mode: flatten), flick-down hard (Ripcord), tap any instrument (1-line explainer overlay), long-press PnL (toggle % / absolute / hidden).
- **Haptic spec (work with eng on Android haptic API limits):** tick = 8–12ms light transient per confirmed tick (rate-limited to feel like texture, not buzzing); detent = medium click; PnL direction = subtle asymmetric texture (rising vs falling pattern); liquidation zones = escalating periodic pulse; Ripcord = heavy ratchet-and-release; settlement sync = double-tap pulse.
- **Audio (optional, default on, ducked):** low instrument-room ambience, needle-sweep transients, Ripcord mechanical release. No "win" sounds.
- **States:**
  - *Nominal* — as above.
  - *Degraded latency* (>250ms tick confirmation): gauges dim slightly, "LINK" indicator amber, ghost needle decouples visibly; Column input still accepted but consequence-honest.
  - *Link lost*: full amber state; auto-flatten countdown if Hold mode (visible, cancelable within grace window); Cruise mode → loss-floor guardian banner ("Your on-chain floor at –$X remains armed").
  - *Liquidated* (we failed the user; design with care): instrument blackout sweep, factual debrief, no shame copy, prominent path to Black Box ("see what happened") and practice mode.
  - *Settlement pending*: sync instrument active state.

### 9.5 Debrief
- **Purpose:** close the loop; convert emotion into reflection (and a share).
- **Content:** result headline (absolute + %), ride stats grid (duration, ticks, max exposure, max drawdown, fees paid — Flash fee + ER fees, honestly itemized), mini replay auto-playing, CTAs: "Black Box" / "Share" / "Ride again."
- **States:** profitable / loss / flat / liquidated variants — same layout, different tone (see copy §11.3); practice rides watermarked.

### 9.6 Hangar (home)
- **Purpose:** glanceable status + fast path to a ride (target: cold start → riding in <15 seconds for a funded returning user).
- **Content:** balance cluster, ACTIVE RIDE banner (live PnL, tap → Cockpit) pinned when position open, market cards (price sparkline, funding, 24h range, "RIDE" affordance), recent rides strip, practice entry.
- **States:** new user (no funds) → practice-forward layout with single funding CTA; funded-no-rides → "first flight" framing; degraded feeds → stale-price treatment (age badges).

### 9.7 Logbook & Black Box
- **Logbook:** reverse-chron ride cards (market, date, duration, result %), filterable; practice rides visually distinct.
- **Black Box detail:** full-screen replay — price curve, exposure ribbon under it, PnL trace, scrubber with haptic detents at key events (entry, max exposure, flatten, Ripcord). Stats panel. Export/share.
- **States:** empty logbook (great copy opportunity: "No flight history. The sky's open."), replay-data fetch failure → stats-only fallback.

### 9.8 Settings
- Standard grouped list per F7. Session-key panel deserves design attention: this is where trust is inspectable (active key, scope, expiry countdown, revoke button with immediate effect).

### 9.9 System sheets (design once, reuse)
- Funding sheet (receive/QR/swap), signature-pending sheet, error sheet (human cause + one action), risk-disclosure sheet (first real-money ride; clear, non-wall-of-text, scrollable summary + link to full), market-info sheet.

---

## 10. Key User Flows (happy paths + the two ugly ones)

1. **First launch → first practice ride:** Welcome → touch live mini-throttle → Flight School (3 guided gestures) → practice cockpit → first practice flatten → Debrief (watermarked) → Hangar. Target: <3 minutes, zero wallet interaction possible throughout.
2. **Practice → first funded ride:** Hangar funding CTA → deposit/swap → Pre-flight (suggested conservative defaults) → one bundled signature → Cockpit. Target: <2 minutes post-deposit-confirmation.
3. **Returning scalper loop:** open app → Hangar ACTIVE/market card → Pre-flight (remembered settings, single confirm) → ride → release/flatten → glance Debrief → out. Target: whole loop possible in under 60 seconds.
4. **Ugly path — connectivity loss mid-ride (Hold mode):** link lost → cockpit amber state + countdown → on-chain auto-flatten executes regardless of app state → push notification with result → reopened app lands on Debrief with plain explanation. *The user must come away trusting the system MORE after a failure.*
5. **Ugly path — liquidation:** escalating haptic/visual warnings → liquidation → blackout sweep → factual debrief → Black Box → gentle practice suggestion. Never a popup ad to re-deposit. Never.

---

## 11. Design Language Direction

> Full identity in `BRAND.md` after designer exploration; these are the constraints.

### 11.1 Aesthetic thesis
**Analog instrument panel, modern execution.** Reference universe: aircraft cockpit gauge clusters (Garmin G1000 restraint, not WWII skeuomorphism), motorsport dash displays, Teenage Engineering hardware, Braun instruments, HOTAS throttle quadrants. Dark by default (OLED, glanceability, battery). Light mode: not in V1.
**Anti-references (explicitly avoid):** Robinhood's toy minimalism, casino-app neon chaos, generic DeFi glassmorphism, AI-gradient slop, terminal-cosplay (we're an instrument, not a Bloomberg).

### 11.2 System hints
- **Color:** near-black instrument housing; one signal accent (suggest amber/phosphor family — aviation heritage, distinct from every green/purple DeFi app); long/short encoded redundantly (hue + form + label) for color-blind safety; reds reserved exclusively for risk states.
- **Type:** engineered grotesk for UI + a true monospaced/tabular face for ALL numerals (gauge heritage; numbers never reflow). Display sizes only for PnL and share cards.
- **Form:** instrument bezels via subtle depth, hairline ticks and scale markings as a decorative system, real gauge geometry (needles rotate around true centers). Texture earns its place only where it aids affordance (the Column puck should *look* grippable).
- **Motion:** physics with mass — needles have inertia and overshoot-damping; nothing "eases" generically; 60fps minimum on the Cockpit, every animation interruptible. Reduced-motion mode swaps sweeps for fades and keeps haptics.
- **The share card** is a first-class brand artifact: dark, cinematic, gauge-iconography, ride trace as hero graphic — designed to look great in an X feed at thumbnail size.

### 11.3 Voice
Terse, mechanical, calm. Pilot-to-pilot.
- ✅ "Link lost. Floor armed at –$42." · "Flat. Ride logged." · "Full deflection = $500 short."
- ❌ "Oops! Something went wrong 😅" · "Congrats on your epic gains!! 🚀" · "Are you sure? This action cannot be undone."
Errors state cause + consequence + one action. Risk copy is honest and specific, never legal-mumbling, never minimizing.

### 11.4 Numbers
Follow the project number-formatting spec: tabular numerals everywhere; PnL signed with explicit +/–; sub-cent prices with subscript-zero notation; abbreviations (K/M) only in compact contexts, never on the primary PnL readout; fees always in absolute USDC.

---

## 12. Business Model & Economics

### 12.1 Revenue
1. **Flow rebates — contingent, NOT day one (corrected, see FEASIBILITY R7):** the Flash Trade builder code (10% of trading fees our order flow generates, settled on-chain every 12h) is the intended primary revenue line. **But verification found the v2 API request shape exposes no builder/referral fields today — only v1 does — so attribution must be wired by the Flash team before any rebate accrues.** Until that onboarding completes (ROADMAP M2.6, started early, non-blocking), day-one rebate revenue is **$0**. Once live, the math: at Flash's ~0.051% open/close, a cohort doing $10M monthly notional ≈ $10.2K fees ≈ **$1.02K/mo rebate per $10M notional**, linear in volume, zero pricing friction to users (they pay Flash's standard fees regardless of UI). Treat this as an external dependency with a real blocker, not booked revenue.
2. **Throtl Pro (V1.5):** $12/mo hypothesis for power features (§7.3). Safety features never paywalled. *Given (1) is contingent, Pro is the first revenue line we control.*
3. **Explicitly rejected:** payment for order flow games, token launch, spread markup, paid leverage unlocks.

### 12.2 Cost structure (high level)
ER session/commit fees (0.0003/0.0001 SOL — subsidize-able as CAC at ~fractions of a cent per ride), dedicated ER node at scale, RPC/indexing (Helius), push infra, devnet practice-mode costs (~free). Unit economics work as long as rebate-per-active-trader exceeds infra-cents-per-ride — overwhelmingly true for any active trader.

### 12.3 KPIs
- **Activation:** install → first practice ride (target >60%); practice → first funded ride (target >15%).
- **The metric:** weekly funded rides per active user (depth of the loop).
- **Volume:** monthly settled notional (drives revenue); rebate revenue.
- **Retention:** D7 / D30 of funded users (benchmark vs mobile trading apps ~D30 20–25%).
- **Safety health (we report these internally like uptime):** % rides ending in liquidation (want LOW), Ripcord usage rate, loss-floor saves.
- **Virality:** share cards per 100 rides; installs attributed to share links.

---

## 13. Trust, Safety & Compliance

- **Custody:** never. Session keys are scoped (position adjustments only, no withdrawals), expiring, user-revocable. This must be inspectable in-product (§9.8).
- **Leverage posture:** conservative defaults (2x), capped ceiling (10x V1), comprehension gate for the cap raise, fuel-bounded risk by construction (full physical deflection = pre-chosen bounded loss).
- **Responsible-use features:** loss floors (on-chain guardian), optional daily loss limit with cooldown, practice mode parity, no engagement-bait notifications (we never push "SOL is pumping! 🚀").
- **Disclosures:** first-funded-ride risk acknowledgment (designed, readable); per-ride consequence line in Pre-flight; fees always itemized post-ride.
- **Geo/regulatory:** derivatives access is jurisdiction-sensitive. V1: dApp Store distribution (crypto-native channel), geo-awareness per legal counsel review pre-Play-Store; architecture keeps a geo-gating capability ready. (Open item for counsel — flagged, not solved, in this doc.)
- **Age gate:** 18+ assertion at onboarding.

---

## 14. Non-Functional Requirements (product-level)

| Dimension | Requirement |
|---|---|
| Tick latency | p50 ≤ 60ms touch→confirmed-needle; p95 ≤ 150ms; degraded-mode UX at >250ms (§9.4) |
| Cockpit rendering | 60fps sustained on Seeker hardware; gauge updates never block input |
| Cold start | ≤2.5s to interactive Hangar |
| Reliability | Loss-floor guardian functions with app dead (on-chain crank); reconciler idempotent across crashes |
| Battery | A 10-min ride ≤3% battery on Seeker (haptics + wakelock budget) |
| Accessibility | One-handed reach for ALL core controls; left-hand mirror; reduced motion; color-blind-safe encodings; TalkBack coverage on non-cockpit screens + accessible numeric fallback mode for the cockpit |
| Localization | V1 English; string architecture localization-ready; numerals locale-aware |
| Privacy | No analytics on amounts without opt-in; share cards default to %-only; minimal PII (we hold none — wallet is identity) |

---

## 15. Open Questions for Design

1. **Column ergonomics:** full-height track vs thumb-arc track (radial, matching natural thumb sweep)? Prototype both — this is THE decision. Test on Seeker physical hardware early.
2. **Detent feel:** how wide is the flat detent dead-zone? Too wide = sluggish flips; too narrow = accidental exposure. Needs haptic prototyping with eng.
3. **Exposure mapping:** linear vs exponential response curve as default? (Product lean: gentle exponential — precision near flat.)
4. **Gauge density:** can the full instrument cluster (§9.4) breathe on a 6.36" display, or does the sync instrument collapse into the exposure gauge?
5. **Share card identity:** static image vs 3–5s video loop as default export?
6. **Brand name of practice mode:** "Practice" vs "Sim" vs "Wind tunnel" — pick one and commit across copy.
7. **Audio:** ship V1 with the ambient layer, or haptics-only? (Product lean: haptics-only V1, audio behind a flag.)

## 16. Deliverables Requested from Design

1. **Moodboard / direction deck** (instrument-panel thesis interpreted) — checkpoint before screens.
2. **Design system foundations:** color, type (incl. tabular numeral face), spacing, gauge component family, haptic-event vocabulary table.
3. **Hi-fi screens, all states:** Welcome, Connect, Flight School (key beats), Pre-flight, **Cockpit (all 6 states — the centerpiece)**, Debrief variants, Hangar variants, Logbook, Black Box replay, Settings, system sheets.
4. **Motion spec:** needle physics, cockpit enter/exit, spool-up loader, Ripcord sequence, liquidation blackout. Lottie/video refs where words fail.
5. **Share card template family.**
6. **dApp Store asset kit:** icon, feature graphic, screenshots narrative.
7. Figma file organized for dev handoff (component variants per state, named per the vocabulary in §3).

---

## Appendix A — Glossary
See vocabulary table (§3). Technical glossary (ER, delegation, session keys, PDA, Pyth Lazer, FLP) lives in `ARCHITECTURE.md`.

## Appendix B — Source Research
- Blitz V5 + v0–v4 landscape, MagicBlock ER/session-key/oracle docs, Flash Trade SDK/API/builder-code docs, Solana Mobile MWA 2.0/Seed Vault/dApp Store docs: full citation list in `.superstack/idea-context.md`.
- Competitive scan (June 2026): Jupiter Mobile Perps, Phantom Perps, MetaMask×Hyperliquid, Drift — all discrete-order UIs; no analog/continuous-control trading product found in app stores or on-chain ecosystems.
