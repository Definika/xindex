// Pyth's Hermes, as the keeper uses it: the latest prices, with the signed update that carries them. Native fetch
// only. No contract of the protocol reads a price: these are the keeper's own, to value its own trades.
//
// Since 2026-08-26 Hermes serves at https://pyth.dourolabs.app/hermes and needs `Authorization: Bearer <key>`; routes
// and response shapes are unchanged.

import { verifiedPrices } from "./math.mjs";

export class HermesError extends Error {
  constructor(message, { status, permanent = false } = {}) {
    super(message);
    this.name = "HermesError";
    this.status = status;
    this.permanent = permanent;
  }
}

const key = (id) => id.toLowerCase().replace(/^0x/, "");
const UINT64_MAX = 2n ** 64n - 1n;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const parseOne = (p) => ({
  price: BigInt(p.price),
  conf: BigInt(p.conf),
  expo: Number(p.expo),
  publishTime: Number(p.publish_time),
});

/// An entry's price, with `ema` the moving average Hermes publishes beside it, which Pyth's contract returns with it:
/// the bot keeps a price only when both are the signed update's (RY-7).
function parsePrice(entry) {
  return { ...parseOne(entry.price), ema: parseOne(entry.ema_price) };
}

/// A Hermes client. `fetchImpl` and `now` are injectable for tests.
export function createHermes({ url, apiKey, fetchImpl = fetch, now = Date.now, requestTimeoutMs = 3000 }) {
  const base = url.replace(/\/+$/, "");

  /// GETs `path`, retrying what may succeed later (no update yet, a busy or failing server, a network error) until
  /// `deadline` (ms since the epoch). 400 and 401/403 are permanent.
  async function get(path, deadline) {
    let wait = 200;
    for (;;) {
      let response;
      try {
        response = await fetchImpl(`${base}${path}`, {
          headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json" },
          signal: AbortSignal.timeout(Math.max(1, Math.min(requestTimeoutMs, deadline - now()))),
        });
      } catch (error) {
        if (now() + wait >= deadline) throw new HermesError(`Hermes unreachable: ${error.message}`);
        await sleep(wait);
        wait = Math.min(wait * 2, 1000);
        continue;
      }
      if (response.ok) return response.json();
      const status = response.status;
      const text = (await response.text().catch(() => "")).slice(0, 200);
      if (status === 400 || status === 401 || status === 403) {
        throw new HermesError(`Hermes ${status} on ${path.split("?")[0]}: ${text}`, { status, permanent: true });
      }
      const retryAfter = Number(response.headers?.get?.("retry-after"));
      const pause = status === 429 ? Math.max(1000, Number.isFinite(retryAfter) ? retryAfter * 1000 : 0) : wait;
      if (now() + pause >= deadline) throw new HermesError(`Hermes ${status} until the deadline: ${text}`, { status });
      await sleep(pause);
      wait = Math.min(wait * 2, 1000);
    }
  }

  const query = (ids) => ids.map((id) => `ids[]=${encodeURIComponent(id)}`).join("&");

  /// The latest price of each of `ids`, by id, in chunks of 50 to keep each URL short. An id Hermes does not serve is
  /// left out of the map, rather than failing every id asked with it (RX-30): callers treat it as unpriced.
  async function latest(ids, deadline) {
    return (await latestSigned(ids, deadline)).prices;
  }

  /// {latest}, with the signed update bytes Hermes served for them (0x hex), so a caller can have Pyth's contract
  /// verify the prices before it values anything at them (RX-9).
  async function latestSigned(ids, deadline) {
    const prices = new Map();
    const updates = [];
    for (let i = 0; i < ids.length; i += 50) {
      const chunk = ids.slice(i, i + 50);
      const body = await get(
        `/v2/updates/price/latest?${query(chunk)}&parsed=true&encoding=hex&ignore_invalid_price_ids=true`,
        deadline,
      );
      for (const entry of body.parsed ?? []) prices.set(key(entry.id), parsePrice(entry));
      for (const hex of body.binary?.data ?? []) updates.push(hex.startsWith("0x") ? hex : `0x${hex}`);
    }
    return { prices, updates };
  }

  /// The prices of `prices` (by key) for `ids` that Pyth's contract, parsing the signed `updates` Hermes served with
  /// them, returns unchanged, its moving average included (RX-9, RY-7): a price Hermes, or anyone between the bot and
  /// Hermes, changed is left out, so a forged or tampered `parsed` body values nothing. Pyth's parse reverts when the
  /// updates lack one of the ids served or carry it outside [minPublishTime, maxPublishTime], and that error is thrown:
  /// a mismatch fails the caller's round rather than leaving one coin out (RZ-7). `read(address, abi, functionName,
  /// args, blockNumber)` and `call({to, abi, functionName, args, value}, blockNumber)` are the chain's, as
  /// `createChain` and the restock's Ethereum client make them; `pyth` is Pyth's contract and `abi` its ABI.
  async function verified(prices, updates, ids, { read, call, pyth, abi, blockNumber, minPublishTime = 0n, maxPublishTime = UINT64_MAX }) {
    if (prices.size === 0 || updates.length === 0) return new Map();
    const served = ids.filter((id) => prices.has(key(id)));
    const fee = await read(pyth, abi, "getUpdateFee", [updates], blockNumber);
    // viem returns a function's single output unwrapped: the parse's answer is the PriceFeed[] itself (RZ-1).
    const feeds = await call(
      {
        to: pyth,
        abi,
        functionName: "parsePriceFeedUpdates",
        args: [updates, served, BigInt(minPublishTime), BigInt(maxPublishTime)],
        value: fee,
      },
      blockNumber,
    );
    return verifiedPrices(prices, feeds, key);
  }

  /// {latest}, {verified}: kept only where Pyth's contract confirms them (RX-9, RY-6). Freshness and width are the
  /// caller's checks, as for {latest}.
  async function trusted(ids, deadline, chain) {
    const { prices, updates } = await latestSigned(ids, deadline);
    return verified(prices, updates, ids, chain);
  }

  return { latest, latestSigned, verified, trusted, key };
}

export const priceKey = key;
