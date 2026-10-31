// Uniswap V3 routes between a component and USDC, chosen by quoting each leg at its own size. The market is Ethereum's
// by default; the restock service passes a home chain's (its float in place of USDC, its wrapped gas coin in place of
// WETH, and a Uniswap V3 fork's factory, quoter and fee tiers). A route is an
// exact-input path from the component to USDC; read as an exact-output path, the same bytes buy the component. A leg
// whose best route loses more than ROUTE_MAX_LOSS_BPS against Pyth gets none, and the executor's inventory serves it;
// its best quote is kept all the same, to value a coin kept as stock at no more than its pools pay (XS-5). Chain access
// and the two ABIs are injected, so this file has no dependencies and is unit-tested on its own.

import { MAINNET } from "./config.mjs";
import { routeLossBps } from "./math.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";

/// A chain's Uniswap V3, from its entry in `CHAINS`: the market the keeper's fills trade on there.
export const marketOf = (chain) =>
  Object.freeze({
    usdc: chain.usdc,
    usdcDecimals: 6,
    weth: chain.weth,
    v3Factory: chain.v3Factory,
    quoterV2: chain.quoterV2,
    directFees: [100, 500, 3000, 10000],
    viaWethFees: [500, 3000, 10000],
    wethUsdcFee: 500,
  });

/// Ethereum's Uniswap V3.
export const ETHEREUM_MARKET = marketOf(MAINNET);
/// How long a leg without a route keeps its quote: a quote that values a kept coin is from the block that uses it
/// (XS-5, RX-13).
export const REQUOTE_BLOCKS = 1n;
/// How long a chosen route serves before it is quoted again, and dropped if it now loses too much: one block of fake
/// depth pins the bot to a pool for at most this long (RX-13).
export const ROUTE_REQUOTE_BLOCKS = 25n;
/// How long the candidate pools found for a token stand: a pool created later, as arbitrageurs make one after a copy
/// depegs, is seen within this many blocks (RX-17).
export const POOL_REFRESH_BLOCKS = 25n;

/// A packed Uniswap V3 path: token, fee, token, ... (20 bytes, 3 bytes, 20 bytes ...).
export const path = (...hops) =>
  `0x${hops.map((h, i) => (i % 2 ? h.toString(16).padStart(6, "0") : h.slice(2).toLowerCase())).join("")}`;

/// `chain` needs `multicall(contracts, blockNumber)`, `call({to, abi, functionName, args}, blockNumber)` and
/// `isRevert(error)`; `abi` is `{v3Factory, v3Pool, quoter}`; `market` names the pools and the quoter, and "USDC" below
/// is its `usdc`, in `usdcDecimals`.
export function createRoutes(chain, cfg, abi, market = ETHEREUM_MARKET) {
  const candidatesOf = new Map(); // token -> {paths, block}: paths whose pools exist and are initialized, read at block
  // `${index}:${proposal}:${token}:${side}` -> {route, amount, usdc, block}, for one auction or request: the route
  // chosen (null when none), and the best quote at `amount`, in USDC's raw units, at `block`; `usdc` is null when no
  // pool exists for the token, and 0n when pools exist but none quoted.
  const chosen = new Map();

  async function candidates(token, blockNumber) {
    const t = token.toLowerCase();
    const known = candidatesOf.get(t);
    if (known && BigInt(blockNumber) - known.block < POOL_REFRESH_BLOCKS) return known.paths;
    const options = market.directFees.map((fee) => ({ pool: [token, market.usdc, fee], path: path(token, fee, market.usdc) }));
    if (t !== market.weth.toLowerCase()) {
      for (const fee of market.viaWethFees) {
        options.push({ pool: [token, market.weth, fee], path: path(token, fee, market.weth, market.wethUsdcFee, market.usdc) });
      }
    }
    const pools = await chain.multicall(
      options.map((o) => ({ address: market.v3Factory, abi: abi.v3Factory, functionName: "getPool", args: o.pool })),
      blockNumber,
    );
    // A pool read that failed is not known to be absent: nothing is cached, and the leg is not valued as poolless.
    if (pools.some((p) => p.status !== "success")) throw new Error(`could not read ${token}'s pools`);
    const existing = options.map((o, i) => ({ ...o, address: pools[i].result })).filter((o) => o.address !== ZERO);
    // A pool nobody initialized has no price and anyone can create one, so it is no candidate: otherwise one empty pool
    // would make a coin with no market count as worth nothing (RX-14). An initialized pool whose liquidity is gone still
    // counts, and quotes nothing, as a depegged copy's does (XS-5).
    const slots = existing.length
      ? await chain.multicall(existing.map((o) => ({ address: o.address, abi: abi.v3Pool, functionName: "slot0" })), blockNumber)
      : [];
    if (slots.some((p) => p.status !== "success")) throw new Error(`could not read ${token}'s pools`);
    const found = existing.filter((_, k) => slots[k].result[0] !== 0n).map((o) => o.path);
    candidatesOf.set(t, { paths: found, block: BigInt(blockNumber) });
    return found;
  }

  /// The quote along `route`, or null when the quoter reverts: no liquidity along it, in that direction. Any other
  /// failure (a timeout, a rate limit) throws, so it is never taken for an empty pool, nor cached.
  async function quote(side, route, amount, blockNumber) {
    const functionName = side === "sell" ? "quoteExactInput" : "quoteExactOutput";
    try {
      const [usdc] = await chain.call({ to: market.quoterV2, abi: abi.quoter, functionName, args: [route, amount] }, blockNumber);
      return usdc;
    } catch (error) {
      if (chain.isRevert(error)) return null;
      throw error;
    }
  }

  /// The route for selling (`side` "sell") or buying ("buy") `amount` of `token`, worth `fairUsd` at Pyth, in the
  /// auction or request `key`; null when none loses at most ROUTE_MAX_LOSS_BPS. A chosen route serves the auction for
  /// ROUTE_REQUOTE_BLOCKS, then is quoted again and kept only if it still passes; {forgetKey} drops it at once, after
  /// a simulation or a fill that reverted (RX-13). A leg without one is quoted again whenever its amount grows past the
  /// one quoted, or in each new block, so the quote {quoteOf} reads is the block's and covers the amount it values.
  async function best({ key, token, side, amount, fairUsd, blockNumber }) {
    const k = `${key}:${token.toLowerCase()}:${side}`;
    const c = chosen.get(k);
    const age = c ? BigInt(blockNumber) - c.block : 0n;
    if (c && c.route !== null && age < ROUTE_REQUOTE_BLOCKS) return c.route;
    if (c && c.route === null && amount <= c.amount && age < REQUOTE_BLOCKS) return null;
    if (c && c.route !== null) {
      const usdc = await quote(side, c.route, amount, blockNumber);
      if (usdc !== null && routeLossBps(side, usdc, fairUsd, market.usdcDecimals) <= cfg.routeMaxLossBps) {
        chosen.set(k, { route: c.route, amount, usdc, block: BigInt(blockNumber) });
        return c.route;
      }
    }
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
    const result = pick !== null && routeLossBps(side, pickUsdc, fairUsd, market.usdcDecimals) <= cfg.routeMaxLossBps ? pick : null;
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

  /// Forgets the routes of auction or request `key`, so the next look searches again (RX-13).
  function forgetKey(key) {
    for (const k of chosen.keys()) if (k.startsWith(`${key}:`)) chosen.delete(k);
  }

  return { best, quoteOf, forget, forgetKey };
}
