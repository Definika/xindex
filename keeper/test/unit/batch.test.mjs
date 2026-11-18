import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_BATCH_REQUESTS, batchGroups, batchKey, planBatch, shareStockUsd, sharesFor } from "../../bot/math.mjs";
import { parseConfig } from "../../bot/config.mjs";

const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
const INDEX = `0x${"aa".repeat(20)}`;
const OTHER = `0x${"bb".repeat(20)}`;
const SHARE = 10n ** 18n;
const usd = (x) => BigInt(Math.round(x * 1e6));
const request = (over) => ({
  requester: `0x${"cc".repeat(20)}`,
  deadline: 2_000n,
  isMint: true,
  open: true,
  index: INDEX,
  stable: USDC,
  escrow: usd(100),
  limit: SHARE,
  ...over,
});
/// A mint request escrowing `dollars` for `shares` shares, and a redeem request escrowing `shares` for `dollars`.
const mint = (id, dollars, shares = 1, over = {}) => ({ id, request: request({ escrow: usd(dollars), limit: BigInt(shares) * SHARE, ...over }) });
const redeem = (id, shares, dollars, over = {}) => ({
  id,
  request: request({ isMint: false, escrow: BigInt(shares) * SHARE, limit: usd(dollars), ...over }),
});
/// One share worth $50 at Pyth, the gate open to the executor.
const info = (shareUsd = 50, mintAllowed = true) =>
  new Map([
    [INDEX.toLowerCase(), { shareUsd, mintAllowed }],
    [OTHER.toLowerCase(), { shareUsd, mintAllowed }],
  ]);
const idsOf = (group) => group.members.map((m) => m.id);

test("a batch groups the open requests of one index in one stablecoin, the largest surplus first", () => {
  const entries = [
    mint(1n, 51),
    mint(2n, 56),
    redeem(3n, 1, 48),
    mint(4n, 60, 1, { index: OTHER }),
    mint(5n, 60, 1, { stable: USDT }),
    mint(6n, 60, 1, { open: false }),
    mint(7n, 60, 1, { deadline: 999n }),
    mint(8n, 49), // its limit is worth more than its escrow: it could only take from the batch
    mint(9n, 60, 1, { index: `0x${"dd".repeat(20)}` }), // an index this bot does not serve
  ];
  const groups = batchGroups(entries, 1_000n, [INDEX, OTHER], info());
  assert.equal(groups.length, 1, "the other index and the other stablecoin have one request each: left to single fills");
  assert.deepEqual(idsOf(groups[0]), [2n, 3n, 1n]);
  assert.equal(groups[0].key, `batch:${INDEX.toLowerCase()}:${USDC.toLowerCase()}`);
  assert.equal(groups[0].index, INDEX);
  assert.equal(groups[0].stable, USDC);
  assert.ok(Math.abs(groups[0].surplusUsd - 9) < 1e-9, "6 + 2 + 1 dollars over the limits");
  assert.deepEqual(groups[0].members.map((m) => Math.round(m.surplusUsd)), [6, 2, 1]);

  // With a share stock to deliver from, one request is a batch too.
  const alone = batchGroups(entries, 1_000n, [INDEX, OTHER], info(), { minSize: 1 });
  assert.deepEqual(alone.map(idsOf), [[2n, 3n, 1n], [4n], [5n]]);
  // At the fill's own second the deadline still holds; a second later it does not.
  assert.equal(batchGroups([mint(1n, 51), mint(2n, 52)], 2_000n, [INDEX], info()).length, 1);
  assert.equal(batchGroups([mint(1n, 51), mint(2n, 52)], 2_001n, [INDEX], info()).length, 0);
});

test("RY-8: a batch must pay MIN_PROFIT_USD as a whole, not request by request", () => {
  const entries = [mint(1n, 52), mint(2n, 52), mint(3n, 52)];
  // No request pays $5 alone; together their escrows are worth $6 over their limits.
  assert.equal(batchGroups(entries, 1_000n, [INDEX], info(), { minProfitUsd: 5 }).length, 1);
  assert.equal(batchGroups(entries, 1_000n, [INDEX], info(), { minProfitUsd: 6.5 }).length, 0, "below it, nothing is simulated");
});

test("a batch leaves out what it could not fill, and takes at most its cap", () => {
  const unpriced = new Map([[INDEX.toLowerCase(), { shareUsd: null, mintAllowed: true }]]);
  assert.equal(batchGroups([mint(1n, 60), mint(2n, 60)], 1_000n, [INDEX], unpriced).length, 0, "an index with no value");
  assert.equal(batchGroups([mint(1n, 60), mint(2n, 60)], 1_000n, [INDEX], new Map()).length, 0, "an index never read");

  // A gate that refuses the executor: the mint requests are left out, the redeem requests stay.
  const gated = batchGroups([mint(1n, 60), redeem(2n, 1, 45), redeem(3n, 1, 46)], 1_000n, [INDEX], info(50, false));
  assert.deepEqual(gated.map(idsOf), [[2n, 3n]]);
  assert.equal(batchGroups([mint(1n, 60), redeem(2n, 1, 45)], 1_000n, [INDEX], info(50, null)).length, 0, "a gate not read");

  const many = Array.from({ length: MAX_BATCH_REQUESTS + 3 }, (_, k) => mint(BigInt(k + 1), 51 + k));
  const [capped] = batchGroups(many, 1_000n, [INDEX], info());
  assert.equal(capped.members.length, MAX_BATCH_REQUESTS);
  assert.equal(capped.members[0].id, BigInt(MAX_BATCH_REQUESTS + 3), "the largest surplus first");
  assert.ok(!idsOf(capped).includes(1n), "the smallest are the ones left out");
  assert.equal(batchGroups(many, 1_000n, [INDEX], info(), { cap: 2 })[0].members.length, 2);
});

test("a batch's back-off key names its group and exactly its requests", () => {
  const [g] = batchGroups([mint(1n, 51), mint(2n, 56)], 1_000n, [INDEX], info());
  assert.equal(batchKey(g), `batch:${INDEX.toLowerCase()}:${USDC.toLowerCase()}:2,1`);
  const [more] = batchGroups([mint(1n, 51), mint(2n, 56), mint(3n, 53)], 1_000n, [INDEX], info());
  assert.notEqual(batchKey(more), batchKey(g), "a request that joins makes it another batch");
});

test("a batch passes the sellers' shares to the buyers and issues only the rest", () => {
  const plan = planBatch({ mints: [mint(1n, 110, 2), mint(2n, 60, 1)], redeems: [redeem(3n, 1, 45)] });
  assert.deepEqual(plan, {
    mintIds: [1n, 2n],
    mintShares: [2n * SHARE, SHARE],
    redeemIds: [3n],
    redeemPay: [usd(45)],
    issue: 2n * SHARE,
    redeem: 0n,
    stockDelta: 0n,
  });
});

test("a batch redeems only what its sellers bring beyond what its buyers take", () => {
  const plan = planBatch({ mints: [mint(1n, 60, 1)], redeems: [redeem(2n, 3, 140), redeem(3n, 1, 45)] });
  assert.equal(plan.issue, 0n);
  assert.equal(plan.redeem, 3n * SHARE);
  assert.equal(plan.stockDelta, 0n, "with no stock target nothing is kept");

  const even = planBatch({ mints: [mint(1n, 110, 2)], redeems: [redeem(2n, 2, 90)] });
  assert.deepEqual([even.issue, even.redeem, even.stockDelta], [0n, 0n, 0n], "a cross trades no basket at all");
});

test("a batch delivers from the share stock within the owner's allowance before it issues", () => {
  const mints = [mint(1n, 260, 5)];
  // Five shares wanted, four held, three allowed: three come from stock, two are issued.
  const plan = planBatch({ mints, redeems: [], held: 4n * SHARE, allowed: 3n * SHARE });
  assert.deepEqual([plan.issue, plan.redeem, plan.stockDelta], [2n * SHARE, 0n, -3n * SHARE]);
  // An allowance beyond what is held delivers only what is held.
  const all = planBatch({ mints, redeems: [], held: 4n * SHARE, allowed: 9n * SHARE });
  assert.deepEqual([all.issue, all.stockDelta], [SHARE, -4n * SHARE]);
  // Stock that covers the buyers: nothing is issued, and only what they take leaves.
  const covered = planBatch({ mints, redeems: [], held: 8n * SHARE, allowed: 8n * SHARE });
  assert.deepEqual([covered.issue, covered.redeem, covered.stockDelta], [0n, 0n, -5n * SHARE]);
  // A seller's shares are used before the stock is.
  const mixed = planBatch({ mints, redeems: [redeem(2n, 4, 180)], held: 8n * SHARE, allowed: 8n * SHARE });
  assert.deepEqual([mixed.issue, mixed.redeem, mixed.stockDelta], [0n, 0n, -SHARE]);
});

test("a batch keeps the sellers' shares as stock up to the target and redeems the rest", () => {
  const redeems = [redeem(1n, 6, 270)];
  const kept = planBatch({ mints: [], redeems, held: SHARE, allowed: 0n, target: 4n * SHARE });
  assert.deepEqual([kept.issue, kept.redeem, kept.stockDelta], [0n, 3n * SHARE, 3n * SHARE], "one held, three more kept, three redeemed");
  const under = planBatch({ mints: [], redeems, held: 0n, allowed: 0n, target: 10n * SHARE });
  assert.deepEqual([under.redeem, under.stockDelta], [0n, 6n * SHARE], "under the target everything is kept");
  // Stock already above the target is the owner's doing: the batch redeems what it brought in, never the stock.
  const above = planBatch({ mints: [], redeems, held: 9n * SHARE, allowed: 9n * SHARE, target: 4n * SHARE });
  assert.deepEqual([above.redeem, above.stockDelta], [6n * SHARE, 0n]);
});

test("the stock target in shares, and the share stock's worth each way", () => {
  assert.equal(sharesFor(1000, 50), 20n * SHARE);
  assert.equal(sharesFor(100, 3), 33_333_333n * 10n ** 12n, "rounded down to a millionth of a share");
  assert.equal(sharesFor(0, 50), 0n);
  assert.equal(sharesFor(1000, 0), 0n);
  assert.equal(sharesFor(1000, null), 0n);

  const worth = { buyUsd: 51, sellUsd: 49 };
  // Kept shares count at what redeeming them brings, less slippage; delivered ones at what issuing costs, plus it.
  assert.ok(Math.abs(shareStockUsd(2n * SHARE, worth, 100n) - 2 * 49 * 0.99) < 1e-9);
  assert.ok(Math.abs(shareStockUsd(-2n * SHARE, worth, 100n) + 2 * 51 * 1.01) < 1e-9);
  assert.equal(shareStockUsd(0n, worth, 100n), 0);
  // So a share bought from a seller and sold to a buyer is worth less coming in than it costs going out.
  assert.ok(shareStockUsd(SHARE, worth, 30n) + shareStockUsd(-SHARE, worth, 30n) < 0);
});

test("SHARE_STOCK_USD is off unless set, and never negative", () => {
  const env = {
    RPC_URL: "http://localhost:8545",
    KEEPER_KEY: `0x${"11".repeat(32)}`,
    FACTORY: `0x${"22".repeat(20)}`,
    EXECUTOR: `0x${"33".repeat(20)}`,
    PYTH_API_KEY: "key",
  };
  assert.equal(parseConfig(env).shareStockUsd, 0);
  assert.equal(parseConfig({ ...env, SHARE_STOCK_USD: "2500" }).shareStockUsd, 2500);
  assert.throws(() => parseConfig({ ...env, SHARE_STOCK_USD: "-1" }), /SHARE_STOCK_USD must be at least 0/);
});
