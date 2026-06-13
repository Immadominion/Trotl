// The off-phone watcher's breach decision, driven through injected fakes (no network): a floor
// breach with an open position fires the pre-signed flatten exactly once; everything else does not.
import { describe, expect, it, vi } from 'vitest';

import type { GuardPrice } from '../src/oracle.js';
import { RIDE_ACCOUNT_LEN, RideStatus } from '../src/ride.js';
import {
  GuardianWatcher,
  type ArmRequest,
  type GuardMarkSource,
  type RideSubscription,
  type Subscribe,
} from '../src/watcher.js';

const RIDE = '11111111111111111111111111111111';
const ARM: ArmRequest = {
  ridePubkey: RIDE,
  erRpcUrl: 'https://er.example',
  erWsUrl: 'wss://er.example',
  flattenTxBase64: 'FLATTEN_TX',
  marketSymbol: 'SOL',
};

/** A RideSession buffer with the floor-relevant fields set at their real offsets. */
function buildRide(o: {
  fuelUsd6: bigint;
  notionalUsd6: bigint;
  entryVwapE9: bigint;
  lossFloor6: bigint;
  realizedPnl6?: bigint;
  status?: number;
}): Uint8Array {
  const buf = new Uint8Array(RIDE_ACCOUNT_LEN);
  const dv = new DataView(buf.buffer);
  dv.setBigUint64(24, o.fuelUsd6, true);
  dv.setBigInt64(32, o.notionalUsd6, true);
  dv.setBigUint64(40, o.entryVwapE9, true);
  dv.setBigInt64(48, o.realizedPnl6 ?? 0n, true);
  dv.setBigInt64(72, o.lossFloor6, true);
  buf[108] = o.status ?? RideStatus.RIDING;
  return buf;
}

const LONG_5K = {
  fuelUsd6: 500_000_000n,
  notionalUsd6: 5_000_000_000n,
  entryVwapE9: 68_000_000_000n,
  lossFloor6: -200_000_000n,
};

function harness(guard: GuardPrice | null, submitImpl?: () => Promise<string>) {
  let onData: ((buf: Uint8Array) => void) | undefined;
  let closed = false;
  const subscribe: Subscribe = (_req, cb): RideSubscription => {
    onData = cb;
    return { close: () => void (closed = true) };
  };
  const guardMark: GuardMarkSource = async () => guard;
  const submit = vi.fn(submitImpl ?? (async () => 'flatsig'));
  const watcher = new GuardianWatcher(subscribe, guardMark, submit, () => 1000);
  return { watcher, submit, push: (b: Uint8Array) => onData?.(b), isClosed: () => closed };
}

describe('GuardianWatcher', () => {
  it('fires the flatten ONCE on a breach with an open position', async () => {
    const h = harness({ priceE9: 50_000_000_000n, publishTime: 0 }); // $50 ⇒ breach
    h.watcher.arm(ARM);
    await h.watcher.onUpdate(RIDE, buildRide(LONG_5K));
    await h.watcher.onUpdate(RIDE, buildRide(LONG_5K)); // still breaching — must NOT re-fire
    expect(h.submit).toHaveBeenCalledTimes(1);
    expect(h.submit).toHaveBeenCalledWith('FLATTEN_TX', 'https://er.example');
    const st = h.watcher.status()[0]!;
    expect(st.fired).toBe(true);
    expect(st.firedSig).toBe('flatsig');
  });

  it('does NOT fire when equity is above the floor', async () => {
    const h = harness({ priceE9: 67_000_000_000n, publishTime: 0 }); // ~flat, no breach
    h.watcher.arm(ARM);
    await h.watcher.onUpdate(RIDE, buildRide(LONG_5K));
    expect(h.submit).not.toHaveBeenCalled();
    expect(h.watcher.status()[0]!.lastCheck?.breached).toBe(false);
  });

  it('does NOT fire on a breach when the position is already flat (nothing to flatten)', async () => {
    const h = harness({ priceE9: 50_000_000_000n, publishTime: 0 });
    h.watcher.arm(ARM);
    await h.watcher.onUpdate(
      RIDE,
      buildRide({ ...LONG_5K, notionalUsd6: 0n, realizedPnl6: -300_000_000n }), // breached via realized, flat
    );
    expect(h.submit).not.toHaveBeenCalled();
  });

  it('refuses to act with no independent guard price (records, never fires blind)', async () => {
    const h = harness(null);
    h.watcher.arm(ARM);
    await h.watcher.onUpdate(RIDE, buildRide(LONG_5K));
    expect(h.submit).not.toHaveBeenCalled();
    expect(h.watcher.status()[0]!.lastError).toBe('no-guard-price');
  });

  it('disarms when the ride reaches SETTLING/CLOSED', async () => {
    const h = harness({ priceE9: 50_000_000_000n, publishTime: 0 });
    h.watcher.arm(ARM);
    await h.watcher.onUpdate(RIDE, buildRide({ ...LONG_5K, status: RideStatus.CLOSED }));
    expect(h.submit).not.toHaveBeenCalled();
    expect(h.watcher.status()).toHaveLength(0);
    expect(h.isClosed()).toBe(true);
  });

  it('retries on the next update if the flatten submit throws (breach not handled)', async () => {
    let calls = 0;
    const h = harness({ priceE9: 50_000_000_000n, publishTime: 0 }, async () => {
      calls += 1;
      if (calls === 1) throw new Error('rpc down');
      return 'flatsig2';
    });
    h.watcher.arm(ARM);
    await h.watcher.onUpdate(RIDE, buildRide(LONG_5K)); // submit throws → fired reset
    expect(h.watcher.status()[0]!.fired).toBe(false);
    await h.watcher.onUpdate(RIDE, buildRide(LONG_5K)); // retry succeeds
    expect(h.submit).toHaveBeenCalledTimes(2);
    expect(h.watcher.status()[0]!.firedSig).toBe('flatsig2');
  });

  it('emits a breach event with the signature', async () => {
    const h = harness({ priceE9: 50_000_000_000n, publishTime: 0 });
    const events: { ridePubkey: string; signature: string }[] = [];
    h.watcher.on('breach', (e) => events.push(e));
    h.watcher.arm(ARM);
    await h.watcher.onUpdate(RIDE, buildRide(LONG_5K));
    expect(events).toHaveLength(1);
    expect(events[0]!.signature).toBe('flatsig');
  });
});
