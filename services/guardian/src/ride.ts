/**
 * RideSession account decoder — TypeScript mirror of `throtl_chain`'s `RideSessionAccount` and the
 * on-chain Rust `state.rs` (#[account(zero_copy)] #[repr(C)], dense, 264 bytes after the 8-byte
 * Anchor discriminator = 272 total). Read by fixed little-endian offset; 64-bit fields use
 * DataView BigInt accessors (Node), so there is no precision loss on large usd6/priceE9 values.
 */

export const RIDE_ACCOUNT_LEN = 272;

export const RideFlag = {
  FLOOR_BREACHED: 1 << 0,
  ORACLE_STALE: 1 << 1,
  BANKRUPT: 1 << 2,
} as const;

export const RideStatus = {
  INIT: 0,
  ARMED: 1,
  RIDING: 2,
  FROZEN: 3,
  SETTLING: 4,
  CLOSED: 5,
} as const;

export interface RideSession {
  readonly sessionId: bigint;
  readonly expiresAt: bigint;
  readonly fuelUsd6: bigint;
  readonly notionalUsd6: bigint;
  readonly entryVwapE9: bigint;
  readonly realizedPnl6: bigint;
  readonly lastMarkE9: bigint;
  readonly lastMarkTs: bigint;
  readonly lossFloor6: bigint;
  readonly tickCount: bigint;
  readonly maxLevBps: number;
  readonly targetExpBps: number;
  readonly virtExpBps: number;
  readonly flags: number;
  readonly marketId: number;
  readonly version: number;
  readonly bump: number;
  readonly status: number;
  readonly gripMode: number;
  readonly owner: Uint8Array;
  readonly sessionKey: Uint8Array;
  readonly feedId: Uint8Array;
}

/** Decode a full account buffer (>= 272 bytes). Throws if too short. */
export function decodeRideSession(buf: Uint8Array): RideSession {
  if (buf.length < RIDE_ACCOUNT_LEN) {
    throw new Error(`RideSession too short: ${buf.length} < ${RIDE_ACCOUNT_LEN}`);
  }
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  return {
    sessionId: dv.getBigUint64(8, true),
    expiresAt: dv.getBigInt64(16, true),
    fuelUsd6: dv.getBigUint64(24, true),
    notionalUsd6: dv.getBigInt64(32, true),
    entryVwapE9: dv.getBigUint64(40, true),
    realizedPnl6: dv.getBigInt64(48, true),
    lastMarkE9: dv.getBigUint64(56, true),
    lastMarkTs: dv.getBigInt64(64, true),
    lossFloor6: dv.getBigInt64(72, true),
    tickCount: dv.getBigUint64(80, true),
    maxLevBps: dv.getUint32(88, true),
    targetExpBps: dv.getInt32(92, true),
    virtExpBps: dv.getInt32(96, true),
    flags: dv.getUint32(100, true),
    marketId: dv.getUint16(104, true),
    version: buf[106]!,
    bump: buf[107]!,
    status: buf[108]!,
    gripMode: buf[109]!,
    owner: buf.subarray(110, 142),
    sessionKey: buf.subarray(142, 174),
    feedId: buf.subarray(174, 206),
  };
}

export function isOracleStale(flags: number): boolean {
  return (flags & RideFlag.ORACLE_STALE) !== 0;
}
