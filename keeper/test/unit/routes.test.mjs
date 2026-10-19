import { test } from "node:test";
import assert from "node:assert/strict";
import { MAINNET } from "../../bot/config.mjs";
import { stockChangeUsd } from "../../bot/math.mjs";
import { POOL_REFRESH_BLOCKS, REQUOTE_BLOCKS, ROUTE_REQUOTE_BLOCKS, createRoutes, path } from "../../bot/routes.mjs";

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
  await sell(r, 9_000n * E18, 100n + ROUTE_REQUOTE_BLOCKS - 1n);
  assert.equal(other.quotes, 1);
  assert.equal(await sell(r, 9_000n * E18, 100n + ROUTE_REQUOTE_BLOCKS), path(Z, 100, MAINNET.usdc));
  assert.equal(other.quotes, 2, "one quote along the chosen route");
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
