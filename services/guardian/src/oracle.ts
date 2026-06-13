/**
 * Guard-mark sources. The guardian's whole value is an INDEPENDENT price: it must not trust the ER's
 * own mark, so the floor check runs against a separately-sourced SOL price. Two readers:
 *
 *   1. parseErOracle — decode a MagicBlock ephemeral-oracle PriceUpdateV3 account (Pyth Lazer, in the
 *      ER): POSITIVE exponent, `price_e9 = mantissa × 10^(9 - expo)` (mirrors magicblock_client +
 *      the on-chain oracle.rs). Used when the only live feed is the ER (devnet).
 *   2. fetchHermesPriceE9 — Pyth Hermes REST, the STANDARD Pyth convention (NEGATIVE expo):
 *      `price_e9 = price × 10^(9 + expo)`. The truly independent production guard (mainnet).
 */

const ER_OFF_PRICE = 73;
const ER_OFF_EXPO = 89;
const ER_OFF_PUBLISH = 93;
const ER_MIN_LEN = ER_OFF_PUBLISH + 8; // 101

export interface GuardPrice {
  readonly priceE9: bigint;
  readonly publishTime: number;
}

/** `price × 10^shift` (shift may be negative ⇒ integer divide), via BigInt. Returns null on overflow. */
function scaleToE9(price: bigint, shift: number): bigint | null {
  const v = shift >= 0 ? price * 10n ** BigInt(shift) : price / 10n ** BigInt(-shift);
  if (v <= 0n || v > (1n << 63n) - 1n) return null;
  return v;
}

/** Decode an in-ER PriceUpdateV3 account → priceE9 (Lazer POSITIVE-expo convention: 9 − expo). */
export function parseErOracle(data: Uint8Array): GuardPrice | null {
  if (data.length < ER_MIN_LEN) return null;
  const dv = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const price = dv.getBigInt64(ER_OFF_PRICE, true);
  const expo = dv.getInt32(ER_OFF_EXPO, true);
  const publishTime = Number(dv.getBigInt64(ER_OFF_PUBLISH, true));
  if (price <= 0n) return null;
  const priceE9 = scaleToE9(price, 9 - expo);
  return priceE9 === null ? null : { priceE9, publishTime };
}

/**
 * Fetch the latest independent SOL price from Pyth Hermes (mainnet). [feedId] is the hex Pyth price
 * feed id (no 0x). Standard Pyth convention: real = price × 10^expo (expo negative) ⇒ 9 + expo.
 * Returns null on any transport/shape error — the caller treats "no independent price" as a reason
 * to refuse, never to assume safety.
 */
export async function fetchHermesPriceE9(
  hermesUrl: string,
  feedId: string,
  fetchImpl: typeof fetch = fetch,
): Promise<GuardPrice | null> {
  const url = `${hermesUrl.replace(/\/$/, '')}/v2/updates/price/latest?ids[]=${feedId}&encoding=hex`;
  try {
    const res = await fetchImpl(url);
    if (!res.ok) return null;
    const body = (await res.json()) as {
      parsed?: { price?: { price?: string; expo?: number; publish_time?: number } }[];
    };
    const p = body.parsed?.[0]?.price;
    if (!p || p.price === undefined || p.expo === undefined) return null;
    const priceE9 = scaleToE9(BigInt(p.price), 9 + p.expo);
    return priceE9 === null ? null : { priceE9, publishTime: p.publish_time ?? 0 };
  } catch {
    return null;
  }
}

/** Pyth mainnet SOL/USD feed id (hex, no 0x) — the independent guard feed for the SOL market. */
export const PYTH_SOL_USD_FEED_ID =
  'ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d';
