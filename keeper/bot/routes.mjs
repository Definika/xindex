// Uniswap V3 routes between a component and USDC, chosen by quoting each leg at its own size. A route is an
// exact-input path from the component to USDC; read as an exact-output path, the same bytes buy the component. A leg
// whose best route loses more than ROUTE_MAX_LOSS_BPS against Pyth gets none, and the executor's inventory serves it;
// its best quote is kept all the same, to value a coin kept as stock at no more than its pools pay (XS-5). Chain access
// and the two ABIs are injected, so this file has no dependencies and is unit-tested on its own.

import { MAINNET } from "./config.mjs";
import { routeLossBps } from "./math.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const DIRECT_FEES = [100, 500, 3000, 10000];
const VIA_WETH_FEES = [500, 3000, 10000];
const WETH_USDC_FEE = 500;
/// How long a leg without a route keeps its quote: a quote that values a kept coin is never older than this (XS-5).
export const REQUOTE_BLOCKS = 25n;

/// A packed Uniswap V3 path: token, fee, token, ... (20 bytes, 3 bytes, 20 bytes ...).
export const path = (...hops) =>
  `0x${hops.map((h, i) => (i % 2 ? h.toString(16).padStart(6, "0") : h.slice(2).toLowerCase())).join("")}`;

/// `chain` needs `multicall(contracts, blockNumber)`, `call({to, abi, functionName, args}, blockNumber)` and
/// `isRevert(error)`; `abi` is `{v3Factory, quoter}`.
export function createRoutes(chain, cfg, abi) {
  const candidatesOf = new Map(); // token -> paths whose pools exist (pools are never removed)
  // `${index}:${proposal}:${token}:${side}` -> {route, amount, usdc, block}, for one auction or request: the route
  // chosen (null when none), and the best quote at `amount`, in USDC's raw units, at `block`; `usdc` is null when no
  // pool exists for the token, and 0n when pools exist but none quoted.
  const chosen = new Map();

  async function candidates(token, blockNumber) {
    const t = token.toLowerCase();
    if (candidatesOf.has(t)) return candidatesOf.get(t);
    const options = DIRECT_FEES.map((fee) => ({ pool: [token, MAINNET.usdc, fee], path: path(token, fee, MAINNET.usdc) }));
    if (t !== MAINNET.weth.toLowerCase()) {
      for (const fee of VIA_WETH_FEES) {
        options.push({ pool: [token, MAINNET.weth, fee], path: path(token, fee, MAINNET.weth, WETH_USDC_FEE, MAINNET.usdc) });
      }
    }
    const pools = await chain.multicall(
      options.map((o) => ({ address: MAINNET.v3Factory, abi: abi.v3Factory, functionName: "getPool", args: o.pool })),
      blockNumber,
    );
    // A pool read that failed is not known to be absent: nothing is cached, and the leg is not valued as poolless.
    if (pools.some((p) => p.status !== "success")) throw new Error(`could not read ${token}'s pools`);
    const found = options.filter((_, i) => pools[i].result !== ZERO).map((o) => o.path);
    candidatesOf.set(t, found);
    return found;
  }

  /// The quote along `route`, or null when the quoter reverts: no liquidity along it, in that direction. Any other
  /// failure (a timeout, a rate limit) throws, so it is never taken for an empty pool, nor cached.
  async function quote(side, route, amount, blockNumber) {
    const functionName = side === "sell" ? "quoteExactInput" : "quoteExactOutput";
    try {
      const [usdc] = await chain.call({ to: MAINNET.quoterV2, abi: abi.quoter, functionName, args: [route, amount] }, blockNumber);
      return usdc;
    } catch (error) {
      if (chain.isRevert(error)) return null;
      throw error;
    }
  }

  /// The route for selling (`side` "sell") or buying ("buy") `amount` of `token`, worth `fairUsd` at Pyth, in the
  /// auction or request `key`; null when none loses at most ROUTE_MAX_LOSS_BPS. A route, once chosen, serves the whole
  /// auction. A leg without one is quoted again whenever its amount grows past the one quoted, or its quote is
  /// REQUOTE_BLOCKS old, so the quote {quoteOf} reads is recent and covers at least the amount it values (XS-5).
  async function best({ key, token, side, amount, fairUsd, blockNumber }) {
    const k = `${key}:${token.toLowerCase()}:${side}`;
    const c = chosen.get(k);
    if (c && (c.route !== null || (amount <= c.amount && BigInt(blockNumber) - c.block < REQUOTE_BLOCKS))) return c.route;
    const paths = await candidates(token, blockNumber);
    let pick = null;
    let pickUsdc = null;
    for (const route of paths) {
      const usdc = await quote(side, route, amount, blockNumber);
      if (usdc === null) continue;
      if (pickUsdc === null || (side === "sell" ? usdc > pickUsdc : usdc < pickUsdc)) {
        pick = route;
        pickUsdc = usdc;
      }
    }
    const result = pick !== null && routeLossBps(side, pickUsdc, fairUsd) <= cfg.routeMaxLossBps ? pick : null;
    chosen.set(k, { route: result, amount, usdc: paths.length === 0 ? null : (pickUsdc ?? 0n), block: BigInt(blockNumber) });
    return result;
  }

  /// What selling `amount` of `token` in `key` would return at the best quote {best} found, used or not, in USDC's raw
  /// units: null when the token has no pool at all, 0n when it has pools but none quoted, and otherwise the quote,
  /// scaled down pro rata (rounded down) to an `amount` below the one quoted. Each is a floor on what the pools pay:
  /// a smaller sale gets at least its share of a larger one's proceeds, and a larger one at least the smaller's.
  function quoteOf({ key, token, side, amount }) {
    const c = chosen.get(`${key}:${token.toLowerCase()}:${side}`);
    if (!c) return 0n;
    if (c.usdc === null) return null;
    return amount < c.amount ? (c.usdc * amount) / c.amount : c.usdc;
  }

  /// Forgets the routes of auctions and requests that are over.
  function forget(keepKeys) {
    for (const k of chosen.keys()) if (!keepKeys.some((key) => k.startsWith(`${key}:`))) chosen.delete(k);
  }

  return { best, quoteOf, forget };
}
