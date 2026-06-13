// Cross-language golden: the SAME real program bytes the Dart suite decodes (produced by the compiled
// throtl-engine in the litesvm mark-path test). Decoding them here pins the TS layout to the Rust
// #[repr(C)] struct — three languages, one layout.
import { describe, expect, it } from 'vitest';

import { decodeRideSession, RideStatus } from '../src/ride.js';

// prettier-ignore — the exact 272-byte account (544 hex chars) produced by the compiled program.
const GOLDEN_HEX =
  'c0b8cca158d74e79640000000000000010e0496b000000000065cd1d0000000000f9029500000000486020cd0f0000000000000000000000486020cd0f00000000d2496b00000000003e14f4ffffffff0100000000000000a0860100881300008813000000000000000001ff02003d8e79fc237ec84bac82328b0b0ca4d5cde4976d5061aa420002629df3d11beaa70bcd7ebfec1b836acb4efe2acf4562901f6244c0b4827bb7f16ae55b5cd1170707070707070707070707070707070707070707070707070707070707070707070000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000';

function hex(s: string): Uint8Array {
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.slice(i * 2, i * 2 + 2), 16);
  return out;
}

describe('decodeRideSession (golden vs real program bytes)', () => {
  const buf = hex(GOLDEN_HEX);

  it('is exactly one account', () => {
    expect(buf.length).toBe(272);
  });

  it('decodes every field to the program-computed value', () => {
    const r = decodeRideSession(buf);
    expect(r.sessionId).toBe(100n);
    expect(r.expiresAt).toBe(1_800_003_600n);
    expect(r.fuelUsd6).toBe(500_000_000n);
    expect(r.notionalUsd6).toBe(2_500_000_000n); // $2500 long
    expect(r.entryVwapE9).toBe(67_865_960_520n);
    expect(r.realizedPnl6).toBe(0n);
    expect(r.lastMarkE9).toBe(67_865_960_520n);
    expect(r.lossFloor6).toBe(-200_000_000n); // negative i64 two's-complement
    expect(r.tickCount).toBe(1n);
    expect(r.maxLevBps).toBe(100_000);
    expect(r.targetExpBps).toBe(5000);
    expect(r.virtExpBps).toBe(5000);
    expect(r.flags).toBe(0);
    expect(r.marketId).toBe(0);
    expect(r.version).toBe(1);
    expect(r.status).toBe(RideStatus.RIDING);
    expect([...r.feedId]).toEqual(Array<number>(32).fill(7));
    expect(r.owner.length).toBe(32);
    expect(r.sessionKey.length).toBe(32);
  });

  it('rejects a short buffer', () => {
    expect(() => decodeRideSession(buf.subarray(0, 100))).toThrow();
  });
});
