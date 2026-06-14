/**
 * Ride history + season leaderboard store for the game UI's read APIs.
 *
 * Most "proof" the cockpit shows is on-chain (live ticks/commits via /ws, ride state via RPC). What
 * genuinely needs the guardian to persist is the cross-device list of *closed* rides (the chain GCs
 * the ride PDA) and the season leaderboard aggregate (no single account holds it). This is a small
 * in-memory ring buffer — pragmatic for the pilot; swap in SQLite on a Railway volume for durability
 * (gated behind an env flag) without changing these shapes. Seeded so the endpoints return real-
 * looking data for the demo until live rides start being recorded via [record].
 */

/** A finalized ride — one row in the Paddock + the unit the leaderboard aggregates. */
export interface RideRecord {
  readonly ridePubkey: string;
  readonly owner: string;
  readonly handle: string;
  readonly marketSymbol: string;
  readonly whenLabel: string;
  readonly closedAt: number;
  readonly realizedPnl6: string;
  readonly fuelUsd6: string;
  readonly ticks: number;
  readonly peakLev: number;
  readonly bestStreak: number;
  readonly winRate: number;
  readonly outcome: 'win' | 'loss' | 'flat';
  readonly commitSig: string;
}

/** One ranked pilot on the season board. */
export interface Pilot {
  readonly rank: number;
  readonly owner: string;
  readonly handle: string;
  readonly pnlPerDollarBps: number;
  readonly realizedPnl6: string;
  readonly rides: number;
  readonly level: number;
  readonly xp: number;
  readonly bestStreak: number;
}

export interface Leaderboard {
  readonly seasonId: number;
  readonly daysLeft: number;
  readonly poolLabel: string;
  readonly updatedAt: number;
  readonly pilots: Pilot[];
}

export interface ShareReceipt extends RideRecord {
  readonly pnlPct: number;
  readonly summaryLine: string;
}

export class RideStore {
  private readonly cap = 5000;
  private records: RideRecord[] = [...SEED_RECORDS];
  private readonly pilots: Pilot[] = [...SEED_PILOTS];

  /** Append a finalized ride (called when a watched ride closes; newest first). */
  record(r: RideRecord): void {
    this.records.unshift(r);
    if (this.records.length > this.cap) this.records.pop();
  }

  history(owner: string | undefined, limit: number): RideRecord[] {
    const rows = owner ? this.records.filter((r) => r.owner === owner) : this.records;
    return rows.slice(0, Math.max(1, Math.min(limit, 200)));
  }

  byRide(ridePubkey: string): ShareReceipt | undefined {
    const r = this.records.find((x) => x.ridePubkey === ridePubkey);
    if (!r) return undefined;
    const pnlPct = (Number(r.realizedPnl6) / Number(r.fuelUsd6)) * 100;
    const win = r.outcome === 'win';
    return {
      ...r,
      pnlPct,
      summaryLine: win
        ? 'Held SOL-PERP in my hand and banked it — no order book, just my thumb.'
        : 'Flicked the throttle, flattened in one tick. No liquidation.',
    };
  }

  leaderboard(limit: number): Leaderboard {
    return {
      seasonId: 1,
      daysLeft: 12,
      poolLabel: 'Top 100 pilots split the season SKR pool',
      updatedAt: 0,
      pilots: this.pilots.slice(0, Math.max(1, Math.min(limit, 100))),
    };
  }
}

const SEED_PILOTS: Pilot[] = [
  { rank: 1, owner: 'vroomVWAP.sol', handle: 'vroomVWAP', pnlPerDollarBps: 1924, realizedPnl6: '4812000000', rides: 64, level: 9, xp: 3600, bestStreak: 23 },
  { rank: 2, owner: '0xSenna.sol', handle: '0xSenna', pnlPerDollarBps: 1591, realizedPnl6: '3977000000', rides: 51, level: 8, xp: 3120, bestStreak: 19 },
  { rank: 3, owner: 'lev_lap.sol', handle: 'lev_lap', pnlPerDollarBps: 1256, realizedPnl6: '3140000000', rides: 88, level: 8, xp: 2980, bestStreak: 31 },
  { rank: 4, owner: 'tickmaestro.sol', handle: 'tickmaestro', pnlPerDollarBps: 1042, realizedPnl6: '2605000000', rides: 40, level: 7, xp: 2605, bestStreak: 12 },
  { rank: 5, owner: 'shortstack.sol', handle: 'shortstack.sol', pnlPerDollarBps: 885, realizedPnl6: '2212000000', rides: 33, level: 6, xp: 2212, bestStreak: 17 },
];

const SEED_RECORDS: RideRecord[] = [
  { ridePubkey: 'Ride5gKx2fQz', owner: 'you.sol', handle: 'you', marketSymbol: 'SOL', whenLabel: 'TODAY 01:12', closedAt: 0, realizedPnl6: '38420000', fuelUsd6: '250000000', ticks: 1284, peakLev: 18.2, bestStreak: 7, winRate: 64, outcome: 'win', commitSig: '5gKx…2fQz' },
  { ridePubkey: 'RidebN2sxW9d', owner: 'you.sol', handle: 'you', marketSymbol: 'SOL', whenLabel: 'TODAY 00:36', closedAt: 0, realizedPnl6: '-12070000', fuelUsd6: '250000000', ticks: 644, peakLev: 20, bestStreak: 2, winRate: 41, outcome: 'loss', commitSig: 'bN2s…xW9d' },
  { ridePubkey: 'RideJh7qpR4m', owner: 'you.sol', handle: 'you', marketSymbol: 'SOL', whenLabel: 'YESTERDAY', closedAt: 0, realizedPnl6: '21650000', fuelUsd6: '500000000', ticks: 2031, peakLev: 12.6, bestStreak: 9, winRate: 58, outcome: 'win', commitSig: 'Jh7q…pR4m' },
  { ridePubkey: 'RidetY3kaL8e', owner: 'you.sol', handle: 'you', marketSymbol: 'SOL', whenLabel: 'YESTERDAY', closedAt: 0, realizedPnl6: '4020000', fuelUsd6: '100000000', ticks: 311, peakLev: 6.4, bestStreak: 3, winRate: 52, outcome: 'win', commitSig: 'tY3k…aL8e' },
  { ridePubkey: 'RideqF6cmD2v', owner: 'you.sol', handle: 'you', marketSymbol: 'SOL', whenLabel: 'JUN 11', closedAt: 0, realizedPnl6: '-27150000', fuelUsd6: '500000000', ticks: 980, peakLev: 19.1, bestStreak: 2, winRate: 38, outcome: 'loss', commitSig: 'qF6c…mD2v' },
];
