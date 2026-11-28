import { test } from "node:test";
import assert from "node:assert/strict";
import { MAINNET } from "../../bot/config.mjs";
import { stockChangeUsd } from "../../bot/math.mjs";
import { CHAINS } from "../../bot/config.mjs";
import {
  LOCAL_ROUTE,
  POOL_REFRESH_BLOCKS,
  REQUOTE_BLOCKS,
  ROUTE_REQUOTE_BLOCKS,
  createRoutes,
  createVenues,
  hopsOf,
  localMarketOf,
  path,
} from "../../bot/routes.mjs";

const Z = `0x${"5a".repeat(20)}`;
const KEY = "0xindex:1";
const POOL = `0x${"99".repeat(20)}`;
const ZERO = `0x${"00".repeat(20)}`;
const E18 = 10n ** 18n;
const pyth = { price: 2_00000000n, expo: -8 }; // Z at $2

/// One Uniswap pool for Z (direct to USDC at 1 bp) whose quoter pays `px` USDC raw units per whole Z; `quoter` may
/// instead throw. `isRevert` is the chain's rule: a revert, not an RPC failure.
function fakeChain({ pools = true } = {}) {
  const chain = {
    px: 1_000_000n,
    quotes: 0,
    poolReads: 0,
    quoter: null,
    poolsFail: false,
    pools,
    initialized: true,
    isRevert: (error) => error.revert === true,
    multicall: async (contracts) => {
      if (contracts[0]?.functionName === "slot0") {
        return contracts.map(() => ({ status: "success", result: [chain.initialized ? 1n << 96n : 0n, 0, 0, 0, 0, 0, true] }));
      }
      chain.poolReads += 1;
      return contracts.map((c, i) =>
        chain.poolsFail ? { status: "failure", error: new Error("chunk") } : { status: "success", result: chain.pools && i === 0 ? POOL : ZERO },
      );
    },
    call: async ({ args: [route, amount] }) => {
      chain.quotes += 1;
      assert.equal(route, path(Z, 100, MAINNET.usdc));
      if (chain.quoter) chain.quoter();
      return [(amount * chain.px) / E18, [], [], 0n];
    },
  };
  return chain;
}

const cfg = { routeMaxLossBps: 100 };
const sell = (routes, amount, blockNumber) =>
  routes.best({ key: KEY, token: Z, side: "sell", amount, fairUsd: (Number(amount) / 1e18) * 2, blockNumber });
const kept = (routes, amount) =>
  stockChangeUsd({ out: amount, in: 0n, held: 0n, routed: false, decimals: 18, price: pyth, quoteUsdc: routes.quoteOf({ key: KEY, token: Z, side: "sell", amount }) });

test("XS-5: a kept leg's quote follows its amount and its age, not the first look", async () => {
  const chain = fakeChain();
  const routes = createRoutes(chain, cfg, { v3Factory: [], v3Pool: [], quoter: [] });
  // Z's pool pays $1 against Pyth's $2: no route, so the index's Z is kept.
  assert.equal(await sell(routes, 2_000n * E18, 100n), null);
  assert.equal(chain.quotes, 1);
  assert.equal(kept(routes, 2_000n * E18), 2_000, "2,000 Z at the pool's $1");

  // The kept amount shrinks within the block: the first look's quote, scaled down, not its whole 2,000 USDC.
  assert.equal(await sell(routes, 500n * E18, 100n), null);
  assert.equal(chain.quotes, 1, "a smaller amount reuses the quote");
  assert.equal(routes.quoteOf({ key: KEY, token: Z, side: "sell", amount: 500n * E18 }), 500n * 10n ** 6n);
  assert.equal(kept(routes, 500n * E18), 500, "500 Z at $1, not their $1,000 at Pyth");

  // It grows: quoted again at the new amount.
  await sell(routes, 3_000n * E18, 100n);
  assert.equal(chain.quotes, 2);
  assert.equal(kept(routes, 3_000n * E18), 3_000);

  // The pool falls to $0.50: the quote stands for its block, and the next block quotes the leg again (RX-13).
  chain.px = 500_000n;
  assert.equal(REQUOTE_BLOCKS, 1n);
  await sell(routes, 3_000n * E18, 100n);
  assert.equal(chain.quotes, 2);
  await sell(routes, 3_000n * E18, 101n);
  assert.equal(chain.quotes, 3);
  assert.equal(kept(routes, 3_000n * E18), 1_500, "at the pool's new $0.50");

  // A routed leg keeps its route for ROUTE_REQUOTE_BLOCKS, then is quoted again along it (RX-13).
  const other = fakeChain();
  other.px = 2_000_000n;
  const r = createRoutes(other, cfg, { v3Factory: [], v3Pool: [], quoter: [] });
  assert.equal(await sell(r, 2_000n * E18, 100n), path(Z, 100, MAINNET.usdc));
  await sell(r, 1_500n * E18, 100n + ROUTE_REQUOTE_BLOCKS - 1n);
  assert.equal(other.quotes, 1, "an amount it quoted, or less, is not quoted again within the period");
  assert.equal(await sell(r, 2_000n * E18, 100n + ROUTE_REQUOTE_BLOCKS), path(Z, 100, MAINNET.usdc));
  assert.equal(other.quotes, 2, "one quote along the chosen route");
});

test("RZ-11: a chosen route is quoted again when its amount grows, so a purchase's bound covers what it costs", async () => {
  const c = fakeChain();
  c.px = 2_000_000n; // the pool sells Z at $2, Pyth's price
  const r = createRoutes(c, cfg, { v3Factory: [], v3Pool: [], quoter: [] });
  const buy = (amount, blockNumber) =>
    r.best({ key: KEY, token: Z, side: "buy", amount, fairUsd: (Number(amount) / 1e18) * 2, blockNumber });
  const cost = (amount) => r.quoteOf({ key: KEY, token: Z, side: "buy", amount });
  assert.equal(await buy(100n * E18, 100n), path(Z, 100, MAINNET.usdc));
  assert.equal(cost(100n * E18), 200n * 10n ** 6n);
  assert.equal(cost(50n * E18), 100n * 10n ** 6n, "a smaller purchase costs at most its share");

  // Two blocks on, the stock has shrunk and the shortfall is 150 Z: the route is quoted again at 150, within the
  // period, and its cost covers 150 Z. Answered from the 100's cost, the fill's bound was $200 for $300 of Z.
  assert.equal(await buy(150n * E18, 102n), path(Z, 100, MAINNET.usdc));
  assert.equal(c.quotes, 2, "quoted again for the larger amount");
  assert.equal(cost(150n * E18), 300n * 10n ** 6n);

  // A sale that grows is quoted again too, so its floor is the larger sale's and not the smaller one's proceeds.
  assert.equal(await sell(r, 10n * E18, 103n), path(Z, 100, MAINNET.usdc));
  assert.equal(await sell(r, 40n * E18, 104n), path(Z, 100, MAINNET.usdc));
  assert.equal(r.quoteOf({ key: KEY, token: Z, side: "sell", amount: 40n * E18 }), 80n * 10n ** 6n);
});

test("RX-13: a chosen route the pool no longer supports is dropped, and a reverted fill drops it at once", async () => {
  const c = fakeChain();
  c.px = 2_000_000n;
  const r = createRoutes(c, cfg, { v3Factory: [], v3Pool: [], quoter: [] });
  assert.equal(await sell(r, 2_000n * E18, 100n), path(Z, 100, MAINNET.usdc));
  // The attacker empties the pool after the bot chose it: at the re-quote the route loses too much and is dropped.
  c.px = 1_000_000n;
  assert.equal(await sell(r, 2_000n * E18, 100n + ROUTE_REQUOTE_BLOCKS), null);
  // forgetKey: the next look searches again, whatever the age.
  c.px = 2_000_000n;
  assert.equal(await sell(r, 2_000n * E18, 100n + ROUTE_REQUOTE_BLOCKS), null, "the same block's answer stands");
  r.forgetKey(KEY);
  assert.equal(await sell(r, 2_000n * E18, 100n + ROUTE_REQUOTE_BLOCKS), path(Z, 100, MAINNET.usdc));
});

test("RX-14, RX-17: an uninitialized pool is no candidate, and pools are read again every POOL_REFRESH_BLOCKS", async () => {
  const c = fakeChain();
  c.initialized = false;
  const r = createRoutes(c, cfg, { v3Factory: [], v3Pool: [], quoter: [] });
  assert.equal(await sell(r, 2_000n * E18, 100n), null);
  assert.equal(r.quoteOf({ key: KEY, token: Z, side: "sell", amount: 2_000n * E18 }), null, "an empty new pool is no market");
  assert.equal(kept(r, 2_000n * E18), 4_000, "so the coin counts at Pyth, not at nothing");

  // A pool initialized later is seen once the candidates are read again.
  c.initialized = true;
  c.px = 2_000_000n;
  assert.equal(await sell(r, 2_000n * E18, 101n), null, "within the refresh, the old reading stands");
  assert.equal(c.poolReads, 1);
  assert.equal(await sell(r, 2_000n * E18, 100n + POOL_REFRESH_BLOCKS), path(Z, 100, MAINNET.usdc));
  assert.equal(c.poolReads, 2);
});

test("XS-5: pools that quote nothing count as nothing; only a coin with no pool counts at Pyth; RPC failures are not quotes", async () => {
  const empty = fakeChain();
  empty.quoter = () => {
    throw Object.assign(new Error("execution reverted"), { revert: true });
  };
  const routes = createRoutes(empty, cfg, { v3Factory: [], v3Pool: [], quoter: [] });
  assert.equal(await sell(routes, 2_000n * E18, 100n), null);
  assert.equal(routes.quoteOf({ key: KEY, token: Z, side: "sell", amount: 2_000n * E18 }), 0n);
  assert.equal(kept(routes, 2_000n * E18), 0, "a pool whose sell side is empty pays nothing");

  const none = createRoutes(fakeChain({ pools: false }), cfg, { v3Factory: [], v3Pool: [], quoter: [] });
  assert.equal(await sell(none, 2_000n * E18, 100n), null);
  assert.equal(none.quoteOf({ key: KEY, token: Z, side: "sell", amount: 2_000n * E18 }), null);
  assert.equal(kept(none, 2_000n * E18), 4_000, "no pool at all: Pyth, as README's keys and risk say");

  // A quote the RPC failed to answer is no quote: the evaluation fails and nothing is cached.
  const flaky = fakeChain();
  flaky.quoter = () => {
    throw new Error("The request took too long to respond.");
  };
  const f = createRoutes(flaky, cfg, { v3Factory: [], v3Pool: [], quoter: [] });
  await assert.rejects(sell(f, 2_000n * E18, 100n), /too long/);
  flaky.quoter = null;
  assert.equal(await sell(f, 2_000n * E18, 100n), null);
  assert.equal(f.quoteOf({ key: KEY, token: Z, side: "sell", amount: 2_000n * E18 }), 2_000n * 10n ** 6n);

  // A pool read that failed is not taken for no pool.
  const blind = fakeChain();
  blind.poolsFail = true;
  const b = createRoutes(blind, cfg, { v3Factory: [], v3Pool: [], quoter: [] });
  await assert.rejects(sell(b, 2_000n * E18, 100n), /pools/);
  blind.poolsFail = false;
  await sell(b, 2_000n * E18, 100n);
  assert.equal(b.quoteOf({ key: KEY, token: Z, side: "sell", amount: 2_000n * E18 }), 2_000n * 10n ** 6n);
});

test("RZ-2, RZ-22: bestBatch quotes each halving, so a pool that passes only at half the size is used", async () => {
  const chain = fakeChain();
  // Z sells at Pyth's $2 up to 1,000 Z and at $1 beyond: a thin pool.
  chain.call = async ({ args: [, amount] }) => {
    chain.quotes += 1;
    return [(amount * (amount <= 1_000n * E18 ? 2_000_000n : 1_000_000n)) / E18, [], [], 0n];
  };
  const routes = createRoutes(chain, cfg, { v3Factory: [], v3Pool: [], quoter: [] });
  const pick = await routes.bestBatch({ key: "restock:100", token: Z, side: "sell", amount: 4_000n * E18, decimals: 18, price: 2, minUsd: 100, blockNumber: 100n });
  assert.deepEqual(pick, { route: path(Z, 100, MAINNET.usdc), amount: 1_000n * E18, usd: 2_000 });
  assert.equal(chain.quotes, 3, "4,000 and 2,000 refused, 1,000 taken");

  // Below the minimum the halving stops: nothing is quoted under 100 USD.
  chain.call = async () => {
    chain.quotes += 1;
    return [0n, [], [], 0n];
  };
  chain.quotes = 0;
  assert.equal(await routes.bestBatch({ key: "restock:101", token: Z, side: "sell", amount: 200n * E18, decimals: 18, price: 2, minUsd: 100, blockNumber: 101n }), null);
  assert.equal(chain.quotes, 3, "400, 200 and 100 USD quoted; 50 USD is below the minimum and never quoted");

  // RZ-22: the amount the plan sized at the minimum is quoted even when floats put it an ulp under.
  chain.quotes = 0;
  await routes.bestBatch({ key: "restock:102", token: Z, side: "sell", amount: 50n * E18, decimals: 18, price: 2, minUsd: 100.00000000000001, blockNumber: 102n });
  assert.equal(chain.quotes, 1, "the first amount is quoted; its halving is not");
});

/// A venue that answers `route` (or null) for every leg, at `quote` USDC raw units, and records what it was told.
function fakeVenue(route, quote) {
  const told = [];
  return {
    told,
    best: async () => route,
    quoteOf: () => quote,
    forget: (keys) => told.push(["forget", keys]),
    forgetKey: (key) => told.push(["forgetKey", key]),
  };
}

test("venues: each leg takes the venue that quotes it best, a local route behind the executor's LOCAL_ROUTE byte", async () => {
  const uni = path(Z, 500, MAINNET.usdc);
  const pancake = path(Z, 2500, MAINNET.usdc);
  const local = (q) => ({ routes: fakeVenue(pancake, q), tag: LOCAL_ROUTE });
  const args = { key: KEY, token: Z, amount: E18, fairUsd: 2, blockNumber: 1n };
  const tagged = `0x01${pancake.slice(2)}`;

  let venues = createVenues([{ routes: fakeVenue(uni, 1_990_000n), tag: "" }, local(1_995_000n)]);
  assert.equal(await venues.best({ ...args, side: "sell" }), tagged, "a sale takes the most");
  assert.equal(venues.quoteOf({ ...args, side: "sell" }), 1_995_000n);
  assert.equal(await venues.best({ ...args, side: "buy" }), uni, "a purchase the least");
  assert.equal(venues.quoteOf({ ...args, side: "buy" }), 1_990_000n);

  venues = createVenues([{ routes: fakeVenue(uni, 1_990_000n), tag: "" }, local(1_990_000n)]);
  assert.equal(await venues.best({ ...args, side: "sell" }), uni, "on a tie, the first venue");

  // A venue without a route within the loss bound is passed over, its quote still counted for a kept coin.
  venues = createVenues([{ routes: fakeVenue(null, 1_500_000n), tag: "" }, local(1_000_000n)]);
  assert.equal(await venues.best({ ...args, side: "sell" }), tagged);
  assert.equal(venues.quoteOf({ ...args, side: "sell" }), 1_500_000n, "the most any pool pays values a kept coin");
  venues = createVenues([{ routes: fakeVenue(null, null), tag: "" }, { routes: fakeVenue(null, null), tag: LOCAL_ROUTE }]);
  assert.equal(await venues.best({ ...args, side: "sell" }), null);
  assert.equal(venues.quoteOf({ ...args, side: "sell" }), null, "no pool on any venue");
  venues = createVenues([{ routes: fakeVenue(null, null), tag: "" }, { routes: fakeVenue(null, 0n), tag: LOCAL_ROUTE }]);
  assert.equal(venues.quoteOf({ ...args, side: "buy" }), 0n, "pools that quote nothing");

  const a = fakeVenue(uni, 1n);
  const b = fakeVenue(pancake, 1n);
  venues = createVenues([{ routes: a, tag: "" }, { routes: b, tag: LOCAL_ROUTE }]);
  venues.forget(["k"]);
  venues.forgetKey("j");
  assert.deepEqual(a.told, [["forget", ["k"]], ["forgetKey", "j"]]);
  assert.deepEqual(b.told, a.told, "every venue forgets alike (RX-13)");
});

test("localMarketOf: the chain's own DEX where it has one, Aero's told apart; a path read back as its hops", () => {
  assert.equal(localMarketOf(CHAINS[1]), null);
  const pancake = localMarketOf(CHAINS[56]);
  assert.equal(pancake.v3Factory, CHAINS[56].localDex.factory);
  assert.equal(pancake.quoterV2, CHAINS[56].localDex.quoter);
  assert.deepEqual(pancake.directFees, [100, 500, 2500, 10000]);
  assert.equal(pancake.wethUsdcFee, 100);
  assert.equal(pancake.usdc, CHAINS[56].usdc);
  assert.equal(pancake.aero, false);
  const aero = localMarketOf(CHAINS[8453]);
  assert.equal(aero.aero, true);
  assert.deepEqual(aero.viaWethFees, [1, 50, 100, 200, 2000]);
  const W = `0x${"77".repeat(20)}`;
  assert.deepEqual(hopsOf(path(Z, 100, W, 50, MAINNET.usdc)), [
    { a: Z, step: 100, b: W },
    { a: W, step: 50, b: MAINNET.usdc.toLowerCase() },
  ]);
});

test("Aero: a route is quoted along its pools from the token paid, each hop's pool read once", async () => {
  const W = `0x${"77".repeat(20)}`;
  const U = MAINNET.usdc;
  const P1 = `0x${"11".repeat(20)}`;
  const P2 = `0x${"22".repeat(20)}`;
  const calls = [];
  let poolReads = 0;
  const chain = {
    isRevert: () => false,
    multicall: async (contracts) => {
      if (contracts[0].functionName === "slot0") return contracts.map(() => ({ status: "success", result: [1n << 96n, 0, 0, 0, 0, true] }));
      poolReads += 1;
      return contracts.map((c) => {
        const [a, b, step] = c.args.map((x) => (typeof x === "string" ? x.toLowerCase() : x));
        const [z, w, u] = [Z, W, U].map((x) => x.toLowerCase());
        const pool = a === z && b === w && step === 100 ? P1 : a === w && b === u && step === 100 ? P2 : ZERO;
        return { status: "success", result: pool };
      });
    },
    call: async (c) => {
      calls.push(c);
      return [2_000_000n, [], []];
    },
  };
  const abi = { aeroFactory: "AF", aeroPool: "AP", metaquoter: "MQ", v3Factory: "V3F", v3Pool: "V3P", quoter: "Q" };
  const market = { ...localMarketOf(CHAINS[8453]), usdc: U, weth: W, directFees: [100], viaWethFees: [100], wethUsdcFee: 100 };
  const routes = createRoutes(chain, cfg, abi, market);
  const args = { key: KEY, token: Z, amount: E18, fairUsd: 2, blockNumber: 1n };
  const viaHub = path(Z, 100, W, 100, U);
  assert.equal(await routes.best({ ...args, side: "sell" }), viaHub);
  assert.equal(calls[0].abi, "MQ");
  assert.deepEqual(calls[0].args, [[P1, P2], Z, E18], "a sale: the pools from the component, which it pays");
  assert.equal(await routes.best({ ...args, side: "buy" }), viaHub);
  assert.equal(calls[1].functionName, "quoteExactOutput");
  assert.deepEqual(calls[1].args, [[P2, P1], U.toLowerCase(), E18], "a purchase: the pools from the float, which it pays");
  assert.equal(poolReads, 2, "the candidates' pools once, the route's hops once");
});
