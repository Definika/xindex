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
import { createRequestFiller } from "../../bot/requests.mjs";

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

function world({ shareStockUsd = 0, minProfitUsd = 5 } = {}) {
  const requests = new Map();
  const state = { shares: 0n, shareAllowance: 0n, reverting: new Set(), calls: [], now: 1_000_000n };
  const L = () => ({ number: 100n, timestamp: state.now, baseFeePerGas: 10n ** 8n, gasUsed: 15_000_000n, gasLimit: 30_000_000n });
  const basket = (shares) => UNITS.map((u) => (shares * u) / SHARE);
  const worth = (shares) => (Number(shares) / 1e18) * 50;

  const answer = ({ address, functionName, args = [] }) => {
    if (functionName === "getRequest") return { ...requests.get(args[0]) }; // a read is a copy, as a node's is
    if (functionName === "requestCount") return BigInt(requests.size);
    if (functionName === "feeTerms") return [true];
    if (functionName === "components") return [[ETH, BTC], UNITS];
    if (functionName === "rebalanceNonce") return 7n;
    if (functionName === "previewIssue" || functionName === "previewRedeem") return basket(args[0]);
    if (functionName === "stockAllowance") return address === EXECUTOR && args[0] === INDEX ? state.shareAllowance : 0n;
    if (functionName === "balanceOf") return address === INDEX ? state.shares : 0n;
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
    multicall: async (calls) => calls.map((c) => ({ status: "success", result: answer(c) })),
    call: async ({ functionName, args }) => settle(functionName, args),
    isRevert: (error) => error?.reverted === true,
  };
  const hermes = {
    trusted: async (ids) =>
      new Map(ids.map((id) => [priceKey(id), { price: BigInt(PRICES[IDS.indexOf(id)]) * 10n ** 8n, expo: -8, conf: 1n, publishTime: state.now }])),
  };
  const routes = {
    best: async ({ token }) => `${token}0001f4${USDC.slice(2)}`.toLowerCase(),
    quoteOf: ({ token, amount }) => {
      const i = [ETH, BTC].indexOf(token);
      return i < 0 ? amount : usd((Number(amount) / 10 ** DECIMALS[i]) * PRICES[i]);
    },
    forgetKey: () => {},
  };
  const logs = [];
  const filler = createRequestFiller({
    chain,
    cfg: { executor: EXECUTOR, factory: addr("fa"), chain: { usdc: USDC }, slippageBps: 30, minProfitUsd, shareStockUsd },
    hermes,
    routes,
    requests: REQUESTS,
    pyth: addr("b7"),
    staticsOf: async () => ({ tokens: [ETH, BTC], ids: IDS, decimals: DECIMALS }),
    log: (...line) => logs.push(line.join(" ")),
    needs: null,
  });
  let next = 0n;
  const open = (over) => {
    next += 1n;
    requests.set(next, { requester: addr("c0"), deadline: state.now + 3600n, open: true, index: INDEX, stable: USDC, ...over });
    return next;
  };
  return {
    state,
    logs,
    requests,
    mint: (dollars, shares, over = {}) => open({ isMint: true, escrow: usd(dollars), limit: BigInt(shares) * SHARE, ...over }),
    redeem: (shares, dollars, over = {}) => open({ isMint: false, escrow: BigInt(shares) * SHARE, limit: usd(dollars), ...over }),
    scan: () => filler.scan(L(), [INDEX]),
    best: () => filler.best(L(), [INDEX], 2000, 10n ** 8n, 100n * 10n ** 9n),
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
