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

/// A chain's Uniswap V3, from its entry in `CHAINS`: the market the keeper's fills trade on there, its float in the
/// chain's own decimals (eighteen on BNB Chain), and `blockScale`, how many of the chain's blocks span one of
/// Ethereum's, by which the re-quote and pool windows below are stretched to last the same time.
export const marketOf = (chain) =>
  Object.freeze({
    usdc: chain.usdc,
    usdcDecimals: chain.usdcDecimals ?? 6,
    blockScale: chain.blockMs ? BigInt(Math.max(1, Math.ceil(12_000 / chain.blockMs))) : 1n,
    weth: chain.weth,
    v3Factory: chain.v3Factory,
    quoterV2: chain.quoterV2,
    directFees: [100, 500, 3000, 10000],
    viaWethFees: [500, 3000, 10000],
    wethUsdcFee: 500,
  });

/// Ethereum's Uniswap V3.
export const ETHEREUM_MARKET = marketOf(MAINNET);

/// A chain's own DEX beside Uniswap, from its entry's `localDex`, or null where it has none: a market like Uniswap's
/// over that DEX's factory, quoter and fees (PancakeSwap's V3 on BNB Chain) or tick spacings (Aero's concentrated pools
/// on Base, `aero`, whose factory, pools and Metaquoter take other calls). Every route through it, direct or through the
/// wrapped gas coin, is a path of its own pools; the hop from the gas coin to the float is the pool at `hubStep`.
export function localMarketOf(chain) {
  const dex = chain.localDex;
  if (!dex) return null;
  return Object.freeze({
    ...marketOf(chain),
    v3Factory: dex.factory,
    quoterV2: dex.quoter,
    directFees: dex.steps,
    viaWethFees: dex.steps,
    wethUsdcFee: dex.hubStep,
    aero: dex.kind === AERO_KIND,
  });
}

/// The executor's `LocalKind` for Aero's router (KeeperExecutor.sol).
const AERO_KIND = 2;

/// The byte a route through the chain's own DEX starts with: the executor's `LOCAL_ROUTE`.
export const LOCAL_ROUTE = "01";

/// The hops of a packed path, `[{a, step, b}]`, each step a fee or a tick spacing.
export function hopsOf(route) {
  const hex = route.slice(2);
  const hops = [];
  for (let i = 0; i + 86 <= hex.length; i += 46) {
    hops.push({ a: `0x${hex.slice(i, i + 40)}`, step: parseInt(hex.slice(i + 40, i + 46), 16), b: `0x${hex.slice(i + 46, i + 86)}` });
  }
  return hops;
}

/// Routes over several venues, each searched by a {createRoutes} of its own: Uniswap's, and the chain's own DEX's, whose
/// routes carry `tag`, the executor's LOCAL_ROUTE byte, in front of their path. A leg takes the route of the venue that
/// quotes it best among those within ROUTE_MAX_LOSS_BPS, a sale the most and a purchase the least, the first venue on a
/// tie; {quoteOf} answers the best quote any venue found, used or not, so a kept coin is valued at the most any of its
/// pools pay (XS-5).
export function createVenues(venues) {
  const better = (side, a, b) => (side === "sell" ? a > b : a < b);
  async function best(args) {
    let pick = null;
    let pickQuote = null;
    for (const v of venues) {
      const route = await v.routes.best(args);
      if (route === null) continue;
      const q = v.routes.quoteOf(args);
      if (pick === null || better(args.side, q, pickQuote)) {
        pick = v.tag ? `0x${v.tag}${route.slice(2)}` : route;
        pickQuote = q;
      }
    }
    return pick;
  }
  /// The best quote of any venue: null when no venue has a pool for the token, 0n when pools exist but none quoted.
  function quoteOf(args) {
    const quotes = venues.map((v) => v.routes.quoteOf(args));
    const priced = quotes.filter((q) => q !== null && q > 0n);
    if (priced.length) return priced.reduce((a, b) => (better(args.side, b, a) ? b : a));
    return quotes.some((q) => q === 0n) ? 0n : null;
  }
  return {
    best,
    quoteOf,
    forget: (keys) => venues.forEach((v) => v.routes.forget(keys)),
    forgetKey: (key) => venues.forEach((v) => v.routes.forgetKey(key)),
  };
}
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
/// `isRevert(error)`; `abi` is `{v3Factory, v3Pool, quoter}`, and on Aero `{aeroFactory, aeroPool, metaquoter}`; `market`
/// names the pools and the quoter, and "USDC" below is its `usdc`, in `usdcDecimals`.
export function createRoutes(chain, cfg, abi, market = ETHEREUM_MARKET) {
  const factoryAbi = market.aero ? abi.aeroFactory : abi.v3Factory;
  const poolAbi = market.aero ? abi.aeroPool : abi.v3Pool;
  const poolOf = new Map(); // `${a}:${b}:${step}` -> the pool's address, for quoting along Aero's pools
  const routeRequote = ROUTE_REQUOTE_BLOCKS * (market.blockScale ?? 1n);
  const poolRefresh = POOL_REFRESH_BLOCKS * (market.blockScale ?? 1n);
  const candidatesOf = new Map(); // token -> {paths, block}: paths whose pools exist and are initialized, read at block
  // `${index}:${proposal}:${token}:${side}` -> {route, amount, usdc, block}, for one auction or request: the route
  // chosen (null when none), and the best quote at `amount`, in USDC's raw units, at `block`; `usdc` is null when no
  // pool exists for the token, and 0n when pools exist but none quoted.
  const chosen = new Map();

  async function candidates(token, blockNumber) {
    const t = token.toLowerCase();
    const known = candidatesOf.get(t);
    if (known && BigInt(blockNumber) - known.block < poolRefresh) return known.paths;
    const options = market.directFees.map((fee) => ({ pool: [token, market.usdc, fee], path: path(token, fee, market.usdc) }));
    if (t !== market.weth.toLowerCase()) {
      for (const fee of market.viaWethFees) {
        options.push({ pool: [token, market.weth, fee], path: path(token, fee, market.weth, market.wethUsdcFee, market.usdc) });
      }
    }
    const pools = await chain.multicall(
      options.map((o) => ({ address: market.v3Factory, abi: factoryAbi, functionName: "getPool", args: o.pool })),
      blockNumber,
    );
    // A pool read that failed is not known to be absent: nothing is cached, and the leg is not valued as poolless.
    if (pools.some((p) => p.status !== "success")) throw new Error(`could not read ${token}'s pools`);
    const existing = options.map((o, i) => ({ ...o, address: pools[i].result })).filter((o) => o.address !== ZERO);
    // A pool nobody initialized has no price and anyone can create one, so it is no candidate: otherwise one empty pool
    // would make a coin with no market count as worth nothing (RX-14). An initialized pool whose liquidity is gone still
    // counts, and quotes nothing, as a depegged copy's does (XS-5).
    const slots = existing.length
      ? await chain.multicall(existing.map((o) => ({ address: o.address, abi: poolAbi, functionName: "slot0" })), blockNumber)
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
    const call = market.aero
      ? { to: market.quoterV2, abi: abi.metaquoter, functionName, args: await poolsArgs(side, route, amount, blockNumber) }
      : { to: market.quoterV2, abi: abi.quoter, functionName, args: [route, amount] };
    try {
      const [usdc] = await chain.call(call, blockNumber);
      return usdc;
    } catch (error) {
      if (chain.isRevert(error)) return null;
      throw error;
    }
  }

  /// Aero's Metaquoter takes a route as its pools, in order from the token paid, with that token: the component's for
  /// a sale, the float's for a purchase, whose pools are the route's read backwards. Each hop's pool is read once.
  async function poolsArgs(side, route, amount, blockNumber) {
    const hops = hopsOf(route);
    const unknown = hops.filter((h) => !poolOf.has(`${h.a}:${h.b}:${h.step}`));
    if (unknown.length) {
      const read = await chain.multicall(
        unknown.map((h) => ({ address: market.v3Factory, abi: factoryAbi, functionName: "getPool", args: [h.a, h.b, h.step] })),
        blockNumber,
      );
      if (read.some((r) => r.status !== "success")) throw new Error("could not read a route's pools");
      unknown.forEach((h, k) => poolOf.set(`${h.a}:${h.b}:${h.step}`, read[k].result));
    }
    const pools = hops.map((h) => poolOf.get(`${h.a}:${h.b}:${h.step}`));
    return side === "sell" ? [pools, hops[0].a, amount] : [pools.reverse(), hops[hops.length - 1].b, amount];
  }

  /// The route for selling (`side` "sell") or buying ("buy") `amount` of `token`, worth `fairUsd` at Pyth, in the
  /// auction or request `key`; null when none loses at most ROUTE_MAX_LOSS_BPS. A chosen route serves the auction for
  /// ROUTE_REQUOTE_BLOCKS, then is quoted again and kept only if it still passes; {forgetKey} drops it at once, after
  /// a simulation or a fill that reverted (RX-13). Either way a leg is quoted again whenever its amount grows past the
  /// one quoted, and a leg without a route in each new block too, so the quote {quoteOf} reads covers the amount it is
  /// asked for. A chosen route answered a larger purchase from its smaller one's cost, which a fill took as its most to
  /// spend: the fill reverted, and its request was struck for it (RZ-11).
  async function best({ key, token, side, amount, fairUsd, blockNumber }) {
    const k = `${key}:${token.toLowerCase()}:${side}`;
    const c = chosen.get(k);
    const age = c ? BigInt(blockNumber) - c.block : 0n;
    if (c && c.route !== null && amount <= c.amount && age < routeRequote) return c.route;
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

  /// What selling (or buying) `amount` of `token` in `key` would return (or cost) at the best quote {best} found, used
  /// or not, in USDC's raw units: null when the token has no pool at all, 0n when it has pools but none quoted, and
  /// otherwise the quote, scaled down pro rata (rounded down) to an `amount` below the one quoted. A sale's is a floor
  /// on what the pools pay, a smaller sale getting at least its share of a larger one's proceeds; a purchase's is a
  /// ceiling, a smaller purchase costing at most its share of a larger one's cost. Asked for more than it quoted, it
  /// answers the smaller quote, which bounds neither side: {best} quotes a larger amount again first (RZ-11).
  function quoteOf({ key, token, side, amount }) {
    const c = chosen.get(`${key}:${token.toLowerCase()}:${side}`);
    if (!c) return 0n;
    if (c.usdc === null) return null;
    return amount < c.amount ? (c.usdc * amount) / c.amount : c.usdc;
  }

  /// {best} for `amount` of `token`, worth `price` USD a whole token of `decimals`, halving the amount, down to `minUsd`,
  /// while no route stays within ROUTE_MAX_LOSS_BPS: a thin pool takes a restock in smaller batches rather than none.
  /// Returns the route with the amount and USD value it was found for, or null. Each amount is looked up under a key of
  /// its own: under one key, {best} answers null without quoting for any amount below one it refused in the block, so
  /// every halving after the first was never quoted (RZ-2).
  async function bestBatch({ key, token, side, amount, decimals, price, minUsd, blockNumber }) {
    for (let a = amount; a > 0n; a /= 2n) {
      const usd = (Number(a) / 10 ** decimals) * price;
      // The plan sized `amount` at the minimum or more, in integers; recomputed in floats it can land an ulp under,
      // so only the halvings are held to it (RZ-22).
      if (a !== amount && usd < minUsd) break;
      const route = await best({ key: `${key}:${a}`, token, side, amount: a, fairUsd: usd, blockNumber });
      if (route) return { route, amount: a, usd };
    }
    return null;
  }

  /// Forgets the routes of auctions and requests that are over.
  function forget(keepKeys) {
    for (const k of chosen.keys()) if (!keepKeys.some((key) => k.startsWith(`${key}:`))) chosen.delete(k);
  }

  /// Forgets the routes of auction or request `key`, so the next look searches again (RX-13).
  function forgetKey(key) {
    for (const k of chosen.keys()) if (k.startsWith(`${key}:`)) chosen.delete(k);
  }

  return { best, bestBatch, quoteOf, forget, forgetKey };
}
