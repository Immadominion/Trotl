// Parity: the guardian's loss-floor math must agree bit-for-bit with the Rust program (math.rs) and
// the Dart client (accounting.dart). These vectors are computed by hand and cross-checked; any drift
// here means the guardian would fire at a different price than the chain.
import { describe, expect, it } from 'vitest';

import { checkFloor, effectiveEquity6, unrealizedPnl6 } from '../src/accounting.js';

describe('unrealizedPnl6 = notional * (mark - vwap) / vwap (trunc toward zero)', () => {
  it('long, price down 68→50: −$1,323.529411', () => {
    expect(unrealizedPnl6(5_000_000_000n, 68_000_000_000n, 50_000_000_000n)).toBe(-1_323_529_411n);
  });

  it('long, price down 68→60: −$588.235294', () => {
    expect(unrealizedPnl6(5_000_000_000n, 68_000_000_000n, 60_000_000_000n)).toBe(-588_235_294n);
  });

  it('short (negative notional), price up 68→80 ⇒ loss', () => {
    // −5000 notional, (80−68)/68 ⇒ −5000 * 0.17647 = −$882.352941
    expect(unrealizedPnl6(-5_000_000_000n, 68_000_000_000n, 80_000_000_000n)).toBe(-882_352_941n);
  });

  it('mark == vwap ⇒ zero; flat ⇒ zero', () => {
    expect(unrealizedPnl6(2_500_000_000n, 67_865_960_520n, 67_865_960_520n)).toBe(0n);
    expect(unrealizedPnl6(0n, 68_000_000_000n, 50_000_000_000n)).toBe(0n);
  });
});

describe('effectiveEquity6 = fuel + realized + unrealized', () => {
  it('sums', () => {
    expect(effectiveEquity6(500_000_000n, 0n, -1_323_529_411n)).toBe(-823_529_411n);
    expect(effectiveEquity6(500_000_000n, 100_000_000n, -50_000_000n)).toBe(550_000_000n);
  });
});

describe('checkFloor (equity <= lossFloor) — the on-chain tick predicate', () => {
  const base = {
    fuelUsd6: 500_000_000n, // $500 fuel
    realizedPnl6: 0n,
    notionalUsd6: 5_000_000_000n, // $5000 long
    entryVwapE9: 68_000_000_000n, // entered $68
    lossFloor6: -200_000_000n, // −$200 floor
  };

  it('breaches at $50 (equity −$823.53 ≤ −$200), and is bankrupt', () => {
    const r = checkFloor({ ...base, markE9: 50_000_000_000n });
    expect(r.unrealized6).toBe(-1_323_529_411n);
    expect(r.equity6).toBe(-823_529_411n);
    expect(r.breached).toBe(true);
    expect(r.bankrupt).toBe(true);
  });

  it('does NOT breach at $60 (equity −$88.24 > −$200)', () => {
    const r = checkFloor({ ...base, markE9: 60_000_000_000n });
    expect(r.equity6).toBe(-88_235_294n);
    expect(r.breached).toBe(false);
    expect(r.bankrupt).toBe(true); // negative equity but not past the floor
  });

  it('healthy long in profit is neither breached nor bankrupt', () => {
    const r = checkFloor({ ...base, markE9: 70_000_000_000n });
    expect(r.equity6).toBeGreaterThan(0n);
    expect(r.breached).toBe(false);
    expect(r.bankrupt).toBe(false);
  });
});
