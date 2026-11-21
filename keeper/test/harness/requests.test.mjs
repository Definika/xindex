// The request filler itself (bot/requests.mjs) against a fake chain: its planning, pricing and back-off, with the
// executor's real ABI encoding every call it would send. The unit suites cover the arithmetic it uses; this covers
// how it is wired. It imports viem, so it needs the keeper's dependencies (`npm ci` in keeper/) and the executor's
// build (`forge build --root keeper`); CI's unit step, which installs nothing, does not run it:
//   node --test keeper/test/harness/*.test.mjs
// The fake executor answers a fill with the float change a fair market would give: escrows in, payments out, a basket
// bought or sold at the prices the fake Hermes serves.

import { test } from "node:test";
import assert from "node:assert/strict";
import { decodeFunctionData } from "viem";
import { ABI } from "../../bot/chain.mjs";
import { priceKey } from "../../bot/hermes.mjs";
import { createRates } from "../../bot/rates.mjs";
import { batchHash, createRequestFiller, requestHash } from "../../bot/requests.mjs";

const addr = (byte) => `0x${byte.repeat(20)}`;
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
const INDEX = addr("a1");
const EXECUTOR = addr("e0");
const REQUESTS = addr("f0");
const [ETH, BTC] = [addr("01"), addr("02")];
const IDS = [`0x${"11".repeat(32)}`, `0x${"22".repeat(32)}`];
const SHARE = 10n ** 18n;
const usd = (x) => BigInt(Math.round(x * 1e6));
// A share holds 0.01 ETH at $2,000 and 0.0005 BTC at $60,000: $50.
const UNITS = [10n ** 16n, 50_000n];
const DECIMALS = [18, 8];
const PRICES = [2000, 60_000];

/// With `wrapped`, BTC is a wrapper of eight decimals over an asset of eight, worth `rate(blockNumber)` of it, in 1e18.
function world({ shareStockUsd = 0, minProfitUsd = 5, stock = () => 0n, unrouted = [], unreadable = [], indexes = [INDEX], wrapped = false, rate = () => 10n ** 18n } = {}) {
  const requests = new Map();
  const state = { shares: 0n, shareAllowance: 0n, reverting: new Set(), calls: [], now: 1_000_000n };
  // A chain past the rates' look-back when a leg is wrapped: a younger one values no wrapper.
  const L = () => ({ number: wrapped ? 1_000n : 100n, timestamp: state.now, baseFeePerGas: 10n ** 8n, gasUsed: 15_000_000n, gasLimit: 30_000_000n });
  const basket = (shares) => UNITS.map((u) => (shares * u) / SHARE);
  const worth = (shares) => (Number(shares) / 1e18) * 50;

  const answer = ({ address, functionName, args = [] }, blockNumber) => {
    if (functionName === "convertToAssets") return (args[0] * rate(blockNumber)) / 10n ** 18n;
    if (functionName === "getRequest") return { ...requests.get(args[0]) }; // a read is a copy, as a node's is
    if (functionName === "requestCount") return BigInt(requests.size);
    if (functionName === "feeTerms") return [true];
    if (functionName === "components") return [[ETH, BTC], UNITS];
    if (functionName === "rebalanceNonce") return 7n;
    if (functionName === "previewIssue" || functionName === "previewRedeem") return basket(args[0]);
    if (functionName === "stockAllowance") return address === EXECUTOR && args[0] === INDEX ? state.shareAllowance : 0n;
    if (functionName === "balanceOf") return address === INDEX ? state.shares : stock(address);
    throw new Error(`the fake chain has no ${functionName}`);
  };
  const revert = (message) => Object.assign(new Error(message), { reverted: true });
  /// The float change of a fill, in a market that trades at the served prices, and its gas.
  const settle = (functionName, [f]) => {
    state.calls.push({ functionName, f });
    if (functionName === "fillBatch") {
      const ids = [...f.mintIds, ...f.redeemIds];
      const bad = ids.find((id) => state.reverting.has(id));
      if (bad !== undefined) throw revert(`request ${bad} cannot be paid`);
      const taken = f.mintIds.reduce((sum, id) => sum + requests.get(id).escrow, 0n);
      const paid = f.redeemPay.reduce((sum, x) => sum + x, 0n);
      const traded = usd(worth(f.redeem)) - usd(worth(f.issue));
      const swaps = (f.issue > 0n ? 1n : 0n) + (f.redeem > 0n ? 1n : 0n);
      return [taken - paid + traded, 60_000n + 80_000n * BigInt(ids.length) + 400_000n * swaps];
    }
    if (state.reverting.has(f.id)) throw revert(`request ${f.id} cannot be paid`);
    const r = requests.get(f.id);
    const delta = r.isMint ? r.escrow - usd(worth(f.amount)) : usd(worth(r.escrow)) - f.amount;
    return [delta, 500_000n];
  };

  const chain = {
    read: async (address, abi, functionName, args) => answer({ address, functionName, args }),
    multicall: async (calls, blockNumber) => calls.map((c) => ({ status: "success", result: answer(c, blockNumber) })),
    call: async ({ functionName, args }) => settle(functionName, args),
    isRevert: (error) => error?.reverted === true,
  };
  const hermes = {
    trusted: async (ids) =>
      new Map(ids.map((id) => [priceKey(id), { price: BigInt(PRICES[IDS.indexOf(id)]) * 10n ** 8n, expo: -8, conf: 1n, publishTime: state.now }])),
  };
  const routes = {
    best: async ({ token }) => (unrouted.includes(token) ? null : `${token}0001f4${USDC.slice(2)}`.toLowerCase()),
    quoteOf: ({ token, amount }) => {
      const i = [ETH, BTC].indexOf(token);
      return i < 0 ? amount : usd((Number(amount) / 10 ** DECIMALS[i]) * PRICES[i]);
    },
    forgetKey: () => {},
  };
  const logs = [];
  // The restock's board, as the filler writes it: what each key last reported.
  const board = new Map();
  const needs = { report: (key, source, coins) => (coins.length === 0 ? board.delete(key) : board.set(key, coins)) };
  const filler = createRequestFiller({
    chain,
    cfg: { executor: EXECUTOR, factory: addr("fa"), chain: { usdc: USDC }, slippageBps: 30, minProfitUsd, shareStockUsd },
    hermes,
    routes,
    rates: createRates({ chain, abi: ABI.vault }),
    requests: REQUESTS,
    pyth: addr("b7"),
    staticsOf: async (index) => {
      if (unreadable.includes(index)) throw new Error("a decimals read failed");
      return { tokens: [ETH, BTC], ids: IDS, decimals: DECIMALS, assetDecimals: wrapped ? [null, 8] : [null, null], shared: [false, false] };
    },
    log: (...line) => logs.push(line.join(" ")),
    needs,
  });
  let next = 0n;
  const open = (over) => {
    next += 1n;
    requests.set(next, { requester: addr("c0"), deadline: state.now + 3600n, open: true, rebalanceNonce: 7, index: INDEX, stable: USDC, ...over });
    return next;
  };
  return {
    state,
    logs,
    board,
    requests,
    mint: (dollars, shares, over = {}) => open({ isMint: true, escrow: usd(dollars), limit: BigInt(shares) * SHARE, ...over }),
    redeem: (shares, dollars, over = {}) => open({ isMint: false, escrow: BigInt(shares) * SHARE, limit: usd(dollars), ...over }),
    scan: () => filler.scan(L(), indexes),
    best: () => filler.best(L(), indexes, 2000, 10n ** 8n, 100n * 10n ** 9n),
    filler,
  };
}

const sent = (pick) => decodeFunctionData({ abi: ABI.executor, data: pick.tx.data });

test("requests too small to pay for a basket each are filled together, in one basket", async () => {
  const w = world();
  // Each escrow is worth $2 over its limit: none pays MIN_PROFIT_USD of $5 alone, the three together do.
  const ids = [w.mint(52, 1), w.mint(52, 1), w.mint(52, 1)];
  await w.scan();
  const pick = await w.best();
  assert.deepEqual(pick.ids, ids);
  const { functionName, args } = sent(pick);
  assert.equal(functionName, "fillBatch");
  const f = args[0];
  assert.deepEqual([...f.mintIds], ids);
  assert.deepEqual([...f.mintShares], [SHARE, SHARE, SHARE], "each at exactly its limit");
  assert.equal(f.issue, 3n * SHARE, "one basket for the three");
  assert.equal(f.redeem, 0n);
  assert.equal(f.index.toLowerCase(), INDEX);
  assert.equal(f.expectedNonce, 7n);
  assert.equal(f.maxIn.length, 2, "each bought leg carries its bound");
  assert.equal(f.minOut.length, 0);
  assert.ok(pick.profit >= 5 && pick.profit < 6, `the $6 of surplus less gas: ${pick.profit}`);
  assert.ok(f.minUsdcDelta > 0n, "the floor keeps the batch's profit");
  assert.ok(!w.state.calls.some((c) => c.functionName === "fillMint"), "none was simulated alone: none could pay alone");
});

test("a seller's shares go to a buyer, and nothing is issued or redeemed", async () => {
  const w = world();
  const sell = w.redeem(2, 94);
  const buy = w.mint(106, 2);
  await w.scan();
  const pick = await w.best();
  assert.deepEqual(new Set(pick.ids), new Set([sell, buy]));
  const f = sent(pick).args[0];
  assert.deepEqual([...f.redeemIds], [sell]);
  assert.deepEqual([...f.redeemPay], [usd(94)]);
  assert.deepEqual([...f.mintIds], [buy]);
  assert.equal(f.issue, 0n);
  assert.equal(f.redeem, 0n);
  assert.ok(f.routes.every((r) => r === "0x"), "no leg is traded");
  assert.equal(pick.usdcDelta, usd(12), "the buyer's escrow less the seller's payment");
});

test("with a share stock, one request is filled from it without a basket, within the owner's allowance", async () => {
  const w = world({ shareStockUsd: 1000 });
  w.state.shares = 10n * SHARE;
  w.state.shareAllowance = 3n * SHARE;
  const buy = w.mint(270, 5);
  await w.scan();
  const pick = await w.best();
  assert.deepEqual(pick.ids, [buy]);
  const f = sent(pick).args[0];
  assert.equal(f.issue, 2n * SHARE, "three shares from stock, as far as the allowance goes, two issued");
  // The three delivered count against the bot at what issuing them again would cost.
  assert.ok(pick.inventoryUsd < -150 && pick.inventoryUsd > -152, String(pick.inventoryUsd));

  // A seller's shares are kept up to the target instead of being redeemed.
  const k = world({ shareStockUsd: 1000 });
  const sell = k.redeem(4, 180);
  await k.scan();
  const kept = await k.best();
  assert.deepEqual(kept.ids, [sell]);
  const g = sent(kept).args[0];
  assert.equal(g.redeem, 0n, "four shares, $200, under the $1,000 target: all kept");
  assert.equal(kept.usdcDelta, -usd(180));
  assert.ok(kept.inventoryUsd > 199 && kept.inventoryUsd < 200, "counted at what redeeming them would bring, less slippage");
});

test("a request whose own fill reverts is found, backed off, and the batch forms again without it", async () => {
  const w = world();
  const good = [w.mint(53, 1), w.mint(53, 1)];
  const bad = w.mint(53, 1);
  w.state.reverting.add(bad);
  await w.scan();
  assert.equal(await w.best(), null, "the batch's simulation reverts, and no request pays alone");
  assert.ok(w.logs.some((l) => l.includes("fillBatch would revert")), w.logs.join("\n"));
  assert.ok(w.state.calls.some((c) => c.functionName === "fillMint" && c.f.id === bad), "each request was then checked alone");

  const pick = await w.best();
  assert.deepEqual(pick.ids, good, "the two that fill form the batch");
  assert.ok(pick.profit >= 5);
});

test("a request closed since the scan is dropped, and the batch forms again without it", async () => {
  const w = world();
  const ids = [w.mint(53, 1), w.mint(53, 1), w.mint(53, 1)];
  await w.scan();
  w.requests.get(ids[2]).open = false; // filled by another filler, or cancelled
  assert.equal(await w.best(), null);
  assert.ok(w.logs.some((l) => l.includes(`request ${ids[2]} closed since the last scan`)), w.logs.join("\n"));
  assert.ok(!w.state.calls.some((c) => c.functionName === "fillBatch"), "nothing was simulated with it");
  const pick = await w.best();
  assert.deepEqual(pick.ids, ids.slice(0, 2));
});

test("a request alone is still filled alone, and a batch that reverted on chain strikes its requests", async () => {
  const w = world();
  const id = w.mint(120, 2);
  await w.scan();
  const pick = await w.best();
  assert.equal(pick.id, id);
  assert.equal(sent(pick).functionName, "fillMint");
  assert.ok(pick.profit > 5);

  const b = world();
  const ids = [b.mint(53, 1), b.mint(53, 1)];
  await b.scan();
  assert.deepEqual((await b.best()).ids, ids);
  const strike = b.filler.revertedBatch(ids, 100n);
  assert.equal(strike.until, 105, "each request, their requester and their index wait five blocks");
  assert.equal(await b.best(), null, "and are not checked while they wait");
});

test("a batch in USDT sells what it takes along the stablecoin's route", async () => {
  const w = world();
  const ids = [w.mint(53, 1, { stable: USDT }), w.mint(53, 1, { stable: USDT })];
  await w.scan();
  const pick = await w.best();
  assert.deepEqual(pick.ids, ids);
  const f = sent(pick).args[0];
  assert.equal(f.stable.toLowerCase(), USDT.toLowerCase());
  assert.ok(f.stableRoute.toLowerCase().startsWith(USDT.toLowerCase()), "a path from USDT");
  assert.ok(f.stableMinOut > 0n && f.stableMinOut < usd(106), "bounded below the quote by the slippage");
  assert.equal(f.stableMaxIn, 0n);
});

test("a request declined alone still joins the batch a later request makes pay", async () => {
  const w = world();
  // Worth $5.20 over its limit: checked alone, it pays less than MIN_PROFIT_USD after gas, and is backed off.
  const first = w.mint(55.2, 1);
  await w.scan();
  assert.equal(await w.best(), null);
  assert.ok(w.logs.some((l) => l.includes(`request ${first} waiting: profit`)), w.logs.join("\n"));

  const second = w.mint(52, 1);
  await w.scan();
  const pick = await w.best();
  assert.deepEqual(pick?.ids, [first, second], "the back-off of its single check does not keep it out of a batch");
});

// The two hashes below were computed outside this code, by Foundry's `cast`, from the ABI encoding of the structs:
//   cast keccak $(cast abi-encode "f((address,uint40,bool,bool,uint40,address,address,uint256,uint256))" "(...)")
// and, for the batch, cast keccak $(cast abi-encode "f(bytes32,bytes32)" <running> <hash>), from zero, redeem first.
const MINT_HASH = "0x3238a81f329e77848d3f121b208aeebf119715dce16ce4568e5bdb15c802352f";
const BATCH_HASH = "0x68f7ed55998c91b33a4700d05bd1a94c91ad29af54352f61f6b85eaa07b35849";

test("CA-M6: a fill names the request it priced by its hash, as MintRequests computes it", async () => {
  const w = world();
  const id = w.mint(60, 1);
  assert.equal(requestHash(w.requests.get(id)), MINT_HASH, "the struct's ABI encoding, hashed");
  await w.scan();
  const pick = await w.best();
  assert.equal(sent(pick).functionName, "fillMint");
  assert.equal(sent(pick).args[0].expected, MINT_HASH, "and the fill carries it");

  // Another request behind the same id is another hash: the executor would refuse the fill.
  assert.notEqual(requestHash({ ...w.requests.get(id), escrow: usd(59) }), MINT_HASH);
});

test("CA-M6: a batch names its requests as one hash, the redeem requests first", async () => {
  const w = world();
  const buy = w.mint(60, 1);
  const sell = w.redeem(1, 40);
  assert.equal(batchHash([w.requests.get(sell), w.requests.get(buy)]), BATCH_HASH);
  assert.notEqual(batchHash([w.requests.get(buy), w.requests.get(sell)]), BATCH_HASH, "the order is part of it");
  await w.scan();
  const pick = await w.best();
  assert.deepEqual(pick.ids, [buy, sell]);
  const f = sent(pick).args[0];
  assert.deepEqual([f.redeemIds, f.mintIds], [[sell], [buy]]);
  assert.equal(f.expected, BATCH_HASH, "folded in the order the executor reads them");
});

test("CA-M8: a request is on the restock's board once, under its batch while it is in one", async () => {
  // BTC has no route, so stock serves it, and there is none: every check ends short and reports what it needs.
  const w = world({ unrouted: [BTC] });
  const ids = [w.mint(60, 1), w.mint(60, 1)];
  await w.scan();
  assert.equal(await w.best(), null, "nothing can be filled without the coin");
  const batch = `batch:${INDEX}:${USDC.toLowerCase()}`;
  assert.deepEqual([...w.board.keys()], [batch], "the batch's one basket, and no request of it alone beside it");
  assert.deepEqual(w.board.get(batch), [{ token: BTC, amount: 2n * UNITS[1] }], "what the two requests need together");

  // A request no batch holds reports for itself.
  const alone = world({ unrouted: [BTC] });
  const id = alone.mint(60, 1);
  await alone.scan();
  assert.equal(await alone.best(), null);
  assert.deepEqual([...alone.board.keys()], [`request:${id}`]);
  assert.deepEqual(alone.board.get(`request:${id}`), [{ token: BTC, amount: UNITS[1] }]);
});

test("a request its index has settled a rebalance since is not simulated and holds no stock", async () => {
  const w = world({ unrouted: [BTC] });
  // The index reads nonce 7; this request was made at 6, so MintRequests would never fill it again (RW-2).
  const stale = w.mint(60, 1, { rebalanceNonce: 6 });
  await w.scan();
  assert.equal(await w.best(), null);
  assert.equal(w.board.size, 0, "it asks the restock for nothing");
  assert.ok(w.logs.some((l) => l.includes(`request ${stale} not simulated: its index settled a rebalance`)), w.logs.join("\n"));
  assert.equal(w.state.calls.length, 0, "and no fill of it was simulated");
});

test("CA-R2-04: an index whose tokens cannot be read is left unpriced, and the others' requests are still filled", async () => {
  const broken = addr("b2");
  const w = world({ indexes: [broken, INDEX], unreadable: [broken] });
  const stuck = w.mint(60, 1, { index: broken });
  const fine = w.mint(60, 1);
  await w.scan();
  assert.ok(w.logs.some((l) => l.includes(`request scan: ${broken} left unpriced`)), w.logs.join("\n"));
  const pick = await w.best();
  assert.equal(pick?.id, fine, "the healthy index's request is priced and picked");
  assert.ok(w.logs.some((l) => l.includes(`request ${stuck} not simulated: no Pyth value for its index yet`)), w.logs.join("\n"));
});

test("a wrapped leg is valued at its feed times the wrapper's rate, read from the wrapper", async () => {
  // One share redeemed: its ETH is sold and its BTC, which has no route, is kept as stock, at $30 of the feed.
  const plain = world({ unrouted: [BTC] });
  plain.redeem(1, 10);
  await plain.scan();
  assert.equal((await plain.best()).inventoryUsd.toFixed(6), "30.000000");

  // The same leg as a wrapper worth half of what its feed prices: the stock kept is worth $15.
  const half = () => 5n * 10n ** 17n;
  const w = world({ unrouted: [BTC], wrapped: true, rate: half });
  w.redeem(1, 10);
  await w.scan();
  assert.equal((await w.best()).inventoryUsd.toFixed(6), "15.000000");

  // And a share of it is worth $35, not the $50 of its feeds: a redeem request asking $40 a share is not worth filling.
  const cheap = world({ wrapped: true, rate: half });
  const id = cheap.redeem(1, 40);
  await cheap.scan();
  assert.equal(await cheap.best(), null);
  assert.ok(cheap.logs.some((l) => l.includes(`request ${id} not simulated: its limit, worth 40.00 USD, is above its escrow's 35.00 USD`)), cheap.logs.join("\n"));
});

test("a wrapper whose rate has just moved prices nothing: its index's requests wait", async () => {
  // The rate reads 1.5 at the round's block, 1,000, and 1 a hundred blocks before it.
  const w = world({ wrapped: true, rate: (blockNumber) => (blockNumber === 1_000n ? 15n * 10n ** 17n : 10n ** 18n) });
  const id = w.redeem(1, 10);
  await w.scan();
  assert.equal(await w.best(), null);
  assert.ok(w.logs.some((l) => l.includes(`request ${id} not simulated: no Pyth value for its index yet`)), w.logs.join("\n"));
  assert.equal(w.state.calls.length, 0, "and no fill of it was simulated");
});

test("the share stock of an index holding a wrapper is counted at the wrapper's rate", async () => {
  // A share is worth $35 with its wrapped leg at half its feed, not $50: four shares kept are $140 of stock, less
  // slippage, where the feeds alone would have booked $200 against the $120 paid for them.
  const w = world({ shareStockUsd: 1000, wrapped: true, rate: () => 5n * 10n ** 17n });
  const sell = w.redeem(4, 120);
  await w.scan();
  const kept = await w.best();
  assert.deepEqual(kept.ids, [sell]);
  assert.equal(sent(kept).args[0].redeem, 0n, "under the target: all kept");
  assert.equal(kept.usdcDelta, -usd(120));
  assert.ok(kept.inventoryUsd > 139 && kept.inventoryUsd < 140, String(kept.inventoryUsd));

  // While the wrapper's rate has just moved the index's shares have no value: none is kept or delivered.
  const moved = world({ shareStockUsd: 1000, wrapped: true, rate: (blockNumber) => (blockNumber === 1_000n ? 5n * 10n ** 17n : 10n ** 18n) });
  moved.redeem(4, 120);
  await moved.scan();
  assert.equal(await moved.best(), null);
});
