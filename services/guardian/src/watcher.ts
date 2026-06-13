/**
 * The off-phone loss-floor watcher (FEASIBILITY DR-5 / DR-8). For each armed ride it subscribes to
 * the RideSession PDA on its Ephemeral Rollup, recomputes effective equity against an INDEPENDENT
 * guard mark on every update, and — on a floor breach with an open position — submits the user's
 * pre-signed, close-only (flatten) transaction. It holds NO user keys and can do nothing but submit
 * that exact opaque transaction: it cannot open, increase, or withdraw (the trust boundary).
 *
 * All I/O (subscription, guard price, submit) is injected, so the breach decision is unit-tested
 * deterministically; production wiring (Connection.onAccountChange / Hermes / sendRawTransaction)
 * lives in index.ts.
 */

import { EventEmitter } from 'node:events';

import { checkFloor, type FloorCheck } from './accounting.js';
import type { GuardPrice } from './oracle.js';
import { decodeRideSession, RideStatus } from './ride.js';

/** A live subscription that can be torn down. */
export interface RideSubscription {
  close(): void | Promise<void>;
}

/** Open an account subscription; `onData` gets the raw account bytes on every confirmed update. */
export type Subscribe = (
  req: ArmRequest,
  onData: (buf: Uint8Array) => void,
  onError: (err: unknown) => void,
) => RideSubscription;

/** Independent SOL price for a market (priceE9). null ⇒ unavailable (never assume safety). */
export type GuardMarkSource = (marketSymbol: string) => Promise<GuardPrice | null>;

/** Submit the opaque pre-signed flatten tx; resolves to the signature. */
export type SubmitFlatten = (txBase64: string, erRpcUrl: string) => Promise<string>;

export interface ArmRequest {
  readonly ridePubkey: string;
  readonly erRpcUrl: string;
  readonly erWsUrl: string;
  /** User-pre-signed, close-only (flatten) tx, base64. MUST be durable-nonce based (client-built) so
   * it survives the ride duration — the guardian only ever submits it verbatim. */
  readonly flattenTxBase64: string;
  readonly marketSymbol: string;
}

export interface RideState {
  readonly ridePubkey: string;
  readonly marketSymbol: string;
  readonly armedAt: number;
  fired: boolean;
  firedSig?: string;
  lastCheck?: FloorCheck & { at: number; tickCount: string; status: number; notional6: string };
  lastError?: string;
}

interface ArmedRide {
  req: ArmRequest;
  state: RideState;
  sub: RideSubscription;
}

export interface BreachEvent {
  readonly ridePubkey: string;
  readonly check: FloorCheck;
  readonly signature: string;
}

export interface CheckEvent {
  readonly ridePubkey: string;
  readonly check: FloorCheck;
}

/**
 * Emits:
 *   'check'    (CheckEvent)  — every recomputation (for the WS telemetry channel)
 *   'breach'   (BreachEvent) — a floor breach that fired the flatten
 *   'incident' ({ ridePubkey, error }) — a recoverable per-ride error (NOT the reserved 'error'
 *              event, which EventEmitter throws on when unlistened)
 */
export class GuardianWatcher extends EventEmitter {
  private readonly rides = new Map<string, ArmedRide>();

  constructor(
    private readonly subscribe: Subscribe,
    private readonly guardMark: GuardMarkSource,
    private readonly submitFlatten: SubmitFlatten,
    private readonly now: () => number = Date.now,
  ) {
    super();
  }

  /** Register a ride and begin watching. Idempotent per ridePubkey (re-arm replaces). */
  arm(req: ArmRequest): RideState {
    this.disarm(req.ridePubkey);
    const state: RideState = {
      ridePubkey: req.ridePubkey,
      marketSymbol: req.marketSymbol,
      armedAt: this.now(),
      fired: false,
    };
    const sub = this.subscribe(
      req,
      (buf) => void this.onUpdate(req.ridePubkey, buf),
      (err) => this.onError(req.ridePubkey, err),
    );
    this.rides.set(req.ridePubkey, { req, state, sub });
    return state;
  }

  async disarm(ridePubkey: string): Promise<boolean> {
    const armed = this.rides.get(ridePubkey);
    if (!armed) return false;
    await armed.sub.close();
    this.rides.delete(ridePubkey);
    return true;
  }

  status(): RideState[] {
    return [...this.rides.values()].map((r) => r.state);
  }

  async closeAll(): Promise<void> {
    await Promise.all([...this.rides.keys()].map((k) => this.disarm(k)));
  }

  /** One account update → recompute the floor against the independent guard mark → maybe fire. */
  async onUpdate(ridePubkey: string, buf: Uint8Array): Promise<void> {
    const armed = this.rides.get(ridePubkey);
    if (!armed) return;
    let ride;
    try {
      ride = decodeRideSession(buf);
    } catch (e) {
      this.onError(ridePubkey, e);
      return;
    }

    // The ride is over — stop watching (nothing left to protect).
    if (ride.status === RideStatus.CLOSED || ride.status === RideStatus.SETTLING) {
      await this.disarm(ridePubkey);
      return;
    }

    const guard = await this.guardMark(armed.req.marketSymbol);
    if (!guard) {
      // No independent price ⇒ we cannot verify a breach. Record it; do NOT fire blind, do NOT
      // assume safety — the venue-native stop remains the hard bound (DR-5).
      armed.state.lastError = 'no-guard-price';
      return;
    }

    const check = checkFloor({
      fuelUsd6: ride.fuelUsd6,
      realizedPnl6: ride.realizedPnl6,
      notionalUsd6: ride.notionalUsd6,
      entryVwapE9: ride.entryVwapE9,
      lossFloor6: ride.lossFloor6,
      markE9: guard.priceE9,
    });
    delete armed.state.lastError; // exactOptionalPropertyTypes: clear by removal, not `= undefined`
    armed.state.lastCheck = {
      ...check,
      at: this.now(),
      tickCount: ride.tickCount.toString(),
      status: ride.status,
      notional6: ride.notionalUsd6.toString(),
    };
    this.emit('check', { ridePubkey, check } satisfies CheckEvent);

    // Fire once: a real breach with an open position to close. (Flat ⇒ nothing to flatten.)
    if (check.breached && ride.notionalUsd6 !== 0n && !armed.state.fired) {
      armed.state.fired = true;
      try {
        const signature = await this.submitFlatten(armed.req.flattenTxBase64, armed.req.erRpcUrl);
        armed.state.firedSig = signature;
        this.emit('breach', { ridePubkey, check, signature } satisfies BreachEvent);
      } catch (e) {
        // Submit failed — re-arm so the next update retries (the breach hasn't been handled).
        armed.state.fired = false;
        this.onError(ridePubkey, e);
      }
    }
  }

  private onError(ridePubkey: string, error: unknown): void {
    const armed = this.rides.get(ridePubkey);
    if (armed) armed.state.lastError = error instanceof Error ? error.message : String(error);
    this.emit('incident', { ridePubkey, error });
  }
}
