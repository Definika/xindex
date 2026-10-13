// Pyth's Hermes, as the keeper uses it: the signed update for one second, and the latest prices. Native fetch only.
//
// Since 2026-08-26 Hermes serves at https://pyth.dourolabs.app/hermes and needs `Authorization: Bearer <key>`; routes
// and response shapes are unchanged. `/v2/updates/price/{t}` returns each feed's first update published at or after t,
// which is exactly what the hub's parse accepts for a block at t + 12.

export class HermesError extends Error {
  constructor(message, { status, permanent = false } = {}) {
    super(message);
    this.name = "HermesError";
    this.status = status;
    this.permanent = permanent;
  }
}

const key = (id) => id.toLowerCase().replace(/^0x/, "");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function parsePrice(entry) {
  const p = entry.price;
  return {
    price: BigInt(p.price),
    conf: BigInt(p.conf),
    expo: Number(p.expo),
    publishTime: Number(p.publish_time),
  };
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

  /// The update a fill at block time `t + 12` needs: each of `ids`' first update at or after `t`, checked to fall in
  /// the hub's window [t, t + 11]. Returns the update bytes (0x hex) and the prices it carries, by id.
  async function at(ids, t, deadline) {
    const body = await get(`/v2/updates/price/${t}?${query(ids)}&encoding=hex&parsed=true`, deadline);
    const prices = new Map();
    for (const entry of body.parsed ?? []) prices.set(key(entry.id), parsePrice(entry));
    for (const id of ids) {
      const p = prices.get(key(id));
      if (!p) throw new HermesError(`Hermes left out ${id}`);
      if (p.publishTime < t || p.publishTime > t + 11) {
        throw new HermesError(`Hermes gave ${id} at ${p.publishTime}, outside [${t}, ${t + 11}]`);
      }
    }
    const data = body.binary?.data;
    if (!Array.isArray(data) || data.length === 0) throw new HermesError("Hermes returned no update data");
    const updates = data.map((hex) => (hex.startsWith("0x") ? hex : `0x${hex}`));
    return { updates, prices };
  }

  /// The latest price of each of `ids`, by id, in chunks of 50 to keep each URL short.
  async function latest(ids, deadline) {
    const prices = new Map();
    for (let i = 0; i < ids.length; i += 50) {
      const chunk = ids.slice(i, i + 50);
      const body = await get(`/v2/updates/price/latest?${query(chunk)}&parsed=true`, deadline);
      for (const entry of body.parsed ?? []) prices.set(key(entry.id), parsePrice(entry));
    }
    return prices;
  }

  return { at, latest, key };
}

export const priceKey = key;
