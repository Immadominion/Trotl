# Throtl · [throtl.fun](https://throtl.fun)

**The first analog exchange.** Hold the market in your hand — a thumb-driven control where your live
perp exposure follows your finger at ~30ms on a MagicBlock Ephemeral Rollup, settled into real
Flash Trade positions, self-custodied on Solana.

This is a **production** monorepo, not a demo. The on-chain engine, the client logic, and the
off-phone safety guardian are built, tested, and proven live end-to-end on devnet.

![Throtl architecture](docs/diagrams/architecture.png)

> The system is two domains bridged by a bounded reconciler. The **Ephemeral Rollup** holds *advisory*
> virtual exposure (gasless session-signed ticks, marked against an in-ER Pyth Lazer oracle). The
> **reconciler** mirrors that into *real* Flash Trade positions under hard local bounds, always with a
> floor-derived stop. A **Railway guardian** independently watches the loss floor off-phone. The ER can
> never directly authorize a trade. See [docs/diagrams/](docs/diagrams/) for the editable sources.

## What's live right now

| Thing | Where | Status |
|---|---|---|
| `throtl-engine` program | devnet `YSaqfuc753DkHZoaEvdNMSTQTf4hEuTtP65hszuvJy9` | deployed from HEAD, **sha256-verified** == local build |
| Guardian (loss-floor watcher) | [guardian-production-a23a.up.railway.app](https://guardian-production-a23a.up.railway.app/healthz) | live on Railway |
| End-to-end ride | devnet ER | **proven**: program → ER → oracle → WS → decode → reconciler (open / increase / hold / flip / flatten, stop always attached) |

## Layout

```text
programs/throtl-engine/       Anchor program — zero_copy RideSession PDA on a MagicBlock ER   [Rust]
app/                          Dart pub/melos workspace                                        [Dart]
  packages/
    throtl_core/              pure FSMs (reconciler), fixed-point accounting, guardian math, sim
    throtl_chain/             throtl-engine ix encoders + PDA derivation + RideSession decoder
    magicblock_client/        Magic Router + ER RPC/WS + in-ER Pyth Lazer oracle parser
    flash_client/             Flash Trade v2 REST tx-builder + unsigned-v0 signer + lifecycle
    throtl_runtime/           the ride executor + sim gateway + Flash order-planner
    throtl_live/              live adapters: ER RideSession feed + RealFlashGateway + live_ride bin
services/guardian/            off-phone loss-floor watcher on Railway — holds no keys           [TS]
docs/                         PRD, feasibility, architecture, roadmap, research, diagrams
.github/workflows/            CI — Rust (host + litesvm + CU regression) · Dart (6 pkgs) · TS
```

The Flutter app shell (the cockpit UI) is the next track and intentionally not in this repo yet.
Planned packages (`wallet_api`/`wallet_mwa`/`wallet_web`, `price_guard`) land with the UI per the roadmap.

## Engineering invariants (enforced by tests)

A PR that breaks one fails CI. See [ARCHITECTURE](docs/ARCHITECTURE.md) for why.

- **No open position without an attached stop-loss** — across any crash point, including mid-flip.
- **No double-open for one drift** across a crash-after-submit-before-confirm.
- **ER state is advisory** — every real trade is bounded by local `fuel×lev`, an independent Pyth
  cross-check, and a per-action max-delta. The chain never directly authorizes a trade.
- **The loss floor is enforced on the real settled position** via a venue stop re-derived from the
  dollar floor on the current size every action; the promised bound is `floor + slippage +
  keeper-hold + band-gap`, never the nominal floor.
- **Session-key blast radius = the ride's deposited fuel**, never the wallet balance.
- **Flash builder txs are UNSIGNED** — add exactly one signature at the correct index, never swap the blockhash.
- **Legacy (not v0+ALT) transactions on all ER paths** — the ER validator rejects ALTs.
- **Three-language parity** — the loss-floor math is identical in the Rust program, the Dart client,
  and the TS guardian; the RideSession byte layout is golden-tested against real program output in all three.

## Build & test

```bash
# Rust program (host unit tests; SBF build + litesvm adversarial/CU suite needs the Solana toolchain)
cd programs/throtl-engine && cargo test --lib && cargo build-sbf && cargo test

# Dart workspace (6 packages)
cd app && dart pub get && dart analyze --fatal-infos packages
for p in throtl_core flash_client magicblock_client throtl_chain throtl_runtime throtl_live; do
  (cd packages/$p && dart test); done

# Guardian (TypeScript)
cd services/guardian && pnpm install && pnpm typecheck && pnpm test
```

Test coverage: **33 Rust** (17 host + 16 litesvm) · **98 Dart** · **18 TS guardian**. All green; CI gates every PR.

## Docs

| Doc | What |
|-----|------|
| [docs/PRODUCT.md](docs/PRODUCT.md) | Product requirements (designer-facing) |
| [docs/FEASIBILITY.md](docs/FEASIBILITY.md) | Verified feasibility study + decision records DR-1…DR-8 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Phased engineering plan (M0…M6) |
| [docs/VERSIONS.md](docs/VERSIONS.md) | Locked dependency versions (registry-verified) |
| [docs/diagrams/](docs/diagrams/) | Architecture / reconciler-FSM / ride-lifecycle (mermaid + excalidraw + svg/png) |
| [docs/research/](docs/research/) | Source research briefs with citations |

## License

MIT.
