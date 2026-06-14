import type { Server } from 'node:http';

import { serve } from '@hono/node-server';
import { Connection, PublicKey } from '@solana/web3.js';
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { WebSocketServer, type WebSocket } from 'ws';
import { z } from 'zod';

import { loadConfig } from './config.js';
import { logger } from './logger.js';
import { fetchHermesPriceE9, PYTH_SOL_USD_FEED_ID, type GuardPrice } from './oracle.js';
import { RideStore } from './store.js';
import {
  GuardianWatcher,
  type GuardMarkSource,
  type SubmitFlatten,
  type Subscribe,
} from './watcher.js';

/**
 * Throtl guardian entrypoint.
 *
 *   GET  /healthz        — liveness/readiness (Railway healthcheck)
 *   POST /guard/arm      — register a ride + user-pre-signed close-only tx; begin watching
 *   POST /guard/disarm   — stop watching a ride
 *   GET  /guard/status   — armed rides + last floor check (bigints serialized as strings)
 *   WS   /ws             — live telemetry: floor checks + breach alerts
 *
 *   Game UI read APIs (cockpit Season / Paddock / Share / live price proxy):
 *   GET  /price/sol            — CORS-safe independent SOL/USD mark (for the web cockpit feed)
 *   GET  /season/leaderboard   — ranked pilots by realized PnL per $ staked
 *   GET  /paddock/history      — finalized ride records (?owner=&limit=)
 *   GET  /share/:ridePubkey    — one ride record + receipt summary
 *
 * Trust boundary (DR-8): the guardian holds NO user keys. Its only money-moving capability is to
 * submit the exact pre-signed, flatten-scoped transaction on a floor breach — never open/withdraw.
 */
const config = loadConfig();

function isPubkey(s: string): boolean {
  try {
    void new PublicKey(s);
    return true;
  } catch {
    return false;
  }
}

// ── watcher collaborators (production wiring; injected so the watcher stays unit-testable) ─────────

const subscribe: Subscribe = (req, onData, onError) => {
  const conn = new Connection(req.erRpcUrl, { wsEndpoint: req.erWsUrl, commitment: 'confirmed' });
  let id: number | undefined;
  try {
    id = conn.onAccountChange(new PublicKey(req.ridePubkey), (info) => onData(info.data), 'confirmed');
  } catch (err) {
    onError(err);
  }
  return {
    close: async () => {
      if (id !== undefined) await conn.removeAccountChangeListener(id);
    },
  };
};

const guardMark: GuardMarkSource = (marketSymbol): Promise<GuardPrice | null> => {
  // V1: SOL only. The independent guard is Pyth Hermes (mainnet SOL/USD) — never the ER's own mark.
  if (marketSymbol !== 'SOL') return Promise.resolve(null);
  return fetchHermesPriceE9(config.PYTH_HERMES_URL, PYTH_SOL_USD_FEED_ID);
};

const submitFlatten: SubmitFlatten = async (txBase64, erRpcUrl) => {
  const conn = new Connection(erRpcUrl, 'confirmed');
  return conn.sendRawTransaction(Buffer.from(txBase64, 'base64'), { skipPreflight: true });
};

const watcher = new GuardianWatcher(subscribe, guardMark, submitFlatten);

// ── HTTP ───────────────────────────────────────────────────────────────────────────────────────

const app = new Hono();

app.use(
  '*',
  cors({ origin: config.ALLOWED_ORIGINS === '*' ? '*' : config.ALLOWED_ORIGINS.split(',') }),
);

/** Serialize a response that may contain BigInt fields (floor-check amounts) → strings. */
function jsonBig(data: unknown, status = 200): Response {
  const body = JSON.stringify(data, (_k, v) => (typeof v === 'bigint' ? v.toString() : v));
  return new Response(body, { status, headers: { 'content-type': 'application/json' } });
}

app.get('/healthz', (c) =>
  c.json({
    status: 'ok',
    service: 'throtl-guardian',
    env: config.NODE_ENV,
    armed: watcher.status().length,
    upstreams: {
      flashApi: config.FLASH_API_URL,
      flashEr: config.FLASH_ER_RPC_URL,
      baseRpc: config.BASE_RPC_URL,
      hermes: config.PYTH_HERMES_URL,
    },
  }),
);

const ArmBody = z.object({
  ridePubkey: z.string().refine(isPubkey, 'invalid base58 pubkey'),
  erRpcUrl: z.string().url(),
  erWsUrl: z.string(),
  flattenTxBase64: z.string().min(1),
  marketSymbol: z.string().default('SOL'),
});

app.post('/guard/arm', async (c) => {
  const parsed = ArmBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.flatten() }, 400);
  const state = watcher.arm(parsed.data);
  logger.info({ ride: parsed.data.ridePubkey, market: parsed.data.marketSymbol }, 'armed');
  return jsonBig(state);
});

app.post('/guard/disarm', async (c) => {
  const body = (await c.req.json().catch(() => null)) as { ridePubkey?: string } | null;
  if (!body?.ridePubkey) return c.json({ error: 'ridePubkey required' }, 400);
  const removed = await watcher.disarm(body.ridePubkey);
  return c.json({ removed });
});

app.get('/guard/status', () => jsonBig(watcher.status()));

// ── Game UI read APIs ────────────────────────────────────────────────────────────────────────────

const store = new RideStore();

/** CORS-safe independent SOL/USD mark, so the web cockpit can drive a live price without RPC CORS. */
app.get('/price/sol', async (c) => {
  const p = await guardMark('SOL');
  if (!p) return c.json({ error: 'price unavailable' }, 503);
  return jsonBig({ symbol: 'SOL', priceE9: p.priceE9, publishTime: p.publishTime });
});

app.get('/season/leaderboard', (c) =>
  jsonBig(store.leaderboard(Number(c.req.query('limit') ?? '50'))),
);

app.get('/paddock/history', (c) =>
  jsonBig({
    owner: c.req.query('owner') ?? null,
    sessions: store.history(c.req.query('owner'), Number(c.req.query('limit') ?? '20')),
  }),
);

app.get('/share/:ridePubkey', (c) => {
  const rec = store.byRide(c.req.param('ridePubkey'));
  return rec ? jsonBig(rec) : c.json({ error: 'ride not found' }, 404);
});

const server = serve({ fetch: app.fetch, port: config.PORT }, (info) => {
  logger.info({ port: info.port }, 'guardian listening');
});

// ── WS telemetry: broadcast every floor check + breach alert to connected clients ────────────────

const wss = new WebSocketServer({ server: server as unknown as Server, path: '/ws' });
const clients = new Set<WebSocket>();
wss.on('connection', (socket) => {
  clients.add(socket);
  socket.on('close', () => clients.delete(socket));
  socket.on('error', () => clients.delete(socket));
});

function broadcast(type: string, payload: unknown): void {
  const msg = JSON.stringify({ type, payload }, (_k, v) =>
    typeof v === 'bigint' ? v.toString() : v,
  );
  for (const ws of clients) {
    if (ws.readyState === ws.OPEN) ws.send(msg);
  }
}

watcher.on('check', (e) => broadcast('check', e));
watcher.on('breach', (e: { ridePubkey: string; signature: string }) => {
  logger.warn({ ride: e.ridePubkey, sig: e.signature }, 'FLOOR BREACH — flatten submitted');
  broadcast('breach', e);
});
watcher.on('incident', (e: { ridePubkey: string; error: unknown }) => {
  logger.error({ ride: e.ridePubkey, err: String(e.error) }, 'watcher incident');
});

function shutdown(signal: string): void {
  logger.info({ signal }, 'shutting down');
  void watcher.closeAll();
  wss.close();
  server.close(() => process.exit(0));
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
