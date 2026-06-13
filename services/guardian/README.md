# Throtl Guardian

Server-side safety/ops service for Throtl, deployed on Railway. **Holds no user keys.**
See [FEASIBILITY.md DR-8](../../docs/FEASIBILITY.md) and [ARCHITECTURE.md §3.4](../../docs/ARCHITECTURE.md).

## What it does (and the trust boundary)

| Responsibility | Status | Notes |
|---|---|---|
| Off-phone loss-floor watcher | ✅ V1 | Subscribes to the RideSession on the ER, recomputes effective equity against an **independent** Pyth mark every update, and on a floor breach with an open position submits the user's pre-signed **close-only** flatten. Cannot open/resize-up/withdraw. |
| Health | ✅ V1 | `GET /healthz` — Railway healthcheck. |
| FCM push relay | M5 | Secondary alert channel (WS telemetry already broadcasts breaches today). |
| RPC-key proxy | M5 | Hides the Helius key from the web bundle. |
| Incident sink | M5 | Money-path `Fatal` events (events only, never balances). |
| Contract-drift canary | M5 | Nightly Flash OpenAPI shape check. |

**Trust boundary:** guardian compromise ⇒ it can flatten positions + spam pushes; it can **never** drain
funds. Trading does not depend on it — if Railway is down, the client trades directly against the ER +
Flash (CORS-open) and the venue-native stop-loss still protects (degrades to the prior serverless posture).

## The watcher (DR-5 / DR-8)

The loss-floor math is a **bit-for-bit TypeScript mirror** of the on-chain Rust (`math.rs`) and the Dart
client (`accounting.dart`) — BigInt reproduces the i128 intermediates, results saturate to i64. The
RideSession decoder is golden-tested against the **same real program bytes** the Dart suite uses
(`test/ride.test.ts`), so the byte layout is pinned across all three languages. The breach predicate
(`equity ≤ lossFloor`) is exactly the on-chain `tick` check.

Crucially the guardian uses its **own independent mark** (Pyth Hermes mainnet SOL/USD), never the ER's
reported price — a compromised ER cannot hide a breach. With no independent price it records the gap and
**refuses to fire blind** (the venue-native stop remains the hard bound).

### Endpoints

```text
POST /guard/arm     { ridePubkey, erRpcUrl, erWsUrl, flattenTxBase64, marketSymbol? } → RideState
POST /guard/disarm  { ridePubkey } → { removed }
GET  /guard/status  → RideState[]   (bigint amounts serialized as strings)
WS   /ws            → { type: 'check' | 'breach', payload }   live telemetry + alerts
```

**`flattenTxBase64` must be a durable-nonce transaction** (client-built, session- or owner-signed,
close-only). The guardian holds it opaque and submits it verbatim on breach — the durable nonce is what
lets it stay valid for the whole ride instead of expiring with a recent blockhash.

## Dev

```bash
pnpm install
cp .env.example .env
pnpm dev          # tsx watch
pnpm typecheck    # tsc --noEmit
pnpm test         # vitest
curl localhost:8080/healthz
```

## Stack

web3.js **v1** (not Kit — forced by flash-sdk + MagicBlock TS SDK), Hono + @hono/node-server, `ws`
(Node 24 has no native WS server), zod, pino, firebase-admin. Exact pins in
[docs/VERSIONS.md](../../docs/VERSIONS.md).
