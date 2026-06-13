# Diagrams

Each diagram ships as a quad: `.mmd` (mermaid source, the single source of truth), `.excalidraw`
(editable scene — open at [excalidraw.com](https://excalidraw.com) → File → Open), and `.svg` / `.png`
(rendered). Edit the `.mmd` and re-render, or move boxes in the `.excalidraw`. Mermaid also renders
inline on GitHub from the fenced sources below.

## System architecture

The two-domain design: the mobile client + reconciler, the MagicBlock Ephemeral Rollup (advisory
virtual exposure), the Flash Trade mainnet venue (real positions), and the off-phone Railway guardian.

![architecture](architecture.png)

Source: [`architecture.mmd`](architecture.mmd) · editable: [`architecture.excalidraw`](architecture.excalidraw)

## Reconciler state machine

How the executor decides when to touch the real position: hysteresis debounce (don't chase the thumb),
a single bounded action per drift, the settling gate (no double-submit), the freeze-after-stop-out
latch, and the degraded gates (link / oracle / price-divergence / market).

![reconciler FSM](reconciler-fsm.png)

Source: [`reconciler-fsm.mmd`](reconciler-fsm.mmd) (stateDiagram — SVG/PNG only; the upstream
mermaid→excalidraw converter supports flowcharts).

## Ride lifecycle

End-to-end: `init_ride` + `delegate_ride` on L1 → the gasless tick loop on the ER (marked against the
in-ER oracle) → the reconcile decision per WS echo → `flatten` → `request_settle` (commit + undelegate)
→ `close_ride`.

![ride lifecycle](ride-lifecycle.png)

Source: [`ride-lifecycle.mmd`](ride-lifecycle.mmd) · editable: [`ride-lifecycle.excalidraw`](ride-lifecycle.excalidraw)
