import { test } from "node:test";
import assert from "node:assert/strict";
import * as M from "../../bot/math.mjs";

test("withTolerance rounds up", () => {
  assert.equal(M.withTolerance(10_000n, 10), 10_010n);
  assert.equal(M.withTolerance(1n, 10), 2n);
  assert.equal(M.withTolerance(0n, 10), 0n);
  assert.equal(M.withTolerance(12_345n, 0), 12_345n);
});

test("usdToUsdcCeil rounds toward +infinity and refuses non-numbers", () => {
  assert.equal(M.usdToUsdcCeil(5), 5_000_000n);
  assert.equal(M.usdToUsdcCeil(-2.5), -2_500_000n);
  assert.equal(M.usdToUsdcCeil(0.0000001), 1n);
  assert.equal(M.usdToUsdcCeil(-0.0000001), 0n);
  assert.throws(() => M.usdToUsdcCeil(NaN));
  assert.throws(() => M.usdToUsdcCeil(Infinity));
});

test("prices and values", () => {
  const eth = { price: 250_000_000_000n, expo: -8 };
  assert.equal(M.priceUsd(eth), 2500);
  assert.equal(M.amountUsd(10n ** 18n, 18, eth), 2500);
  assert.equal(M.amountUsd(5n * 10n ** 5n, 6, { price: 1n, expo: 0 }), 0.5);
});

test("tvlUsd values supply times units at Pyth prices, a missing price as nothing", () => {
  const eth = { price: 2000_00000000n, expo: -8 };
  const btc = { price: 60_000_00000000n, expo: -8 };
  const units = [25n * 10n ** 15n, 50_000n]; // 0.025 ETH and 0.0005 BTC per index token
  const decimals = [18, 8];
  assert.equal(M.tvlUsd({ supply: 2n * 10n ** 18n, units, decimals, prices: [eth, btc] }), 160);
  assert.equal(M.tvlUsd({ supply: 2n * 10n ** 18n, units, decimals, prices: [eth, undefined] }), 100);
  assert.equal(M.tvlUsd({ supply: 0n, units, decimals, prices: [eth, btc] }), 0);
});

test("CF-7: auctionsToEvaluate drops empty and small indexes, keeps the richest, caps the count", () => {
  const a = (index, supply, tvl) => ({ index, supply, tvl });
  const all = [a("empty", 0n, 0), a("dust", 1n, 0.01), a("mid", 10n, 5_000), a("big", 10n, 90_000), a("min", 10n, 1_000)];
  assert.deepEqual(M.auctionsToEvaluate(all, 1_000, 8).map((c) => c.index), ["big", "mid", "min"]);
  assert.deepEqual(M.auctionsToEvaluate(all, 1_000, 2).map((c) => c.index), ["big", "mid"]);
  assert.deepEqual(M.auctionsToEvaluate(all, 0, 8).map((c) => c.index), ["big", "mid", "min", "dust"], "an empty index never, even at no minimum");
  assert.deepEqual(M.auctionsToEvaluate([], 1_000, 8), []);
});

test("auctionOpen is the hub's rule at the fill's own timestamp", () => {
  const d = 86_400n;
  assert.equal(M.auctionOpen(0n, 5000n, d), false);
  assert.equal(M.auctionOpen(1000n, 999n, d), false);
  assert.equal(M.auctionOpen(1000n, 1000n, d), true);
  assert.equal(M.auctionOpen(1000n, 1000n + d, d), true);
  assert.equal(M.auctionOpen(1000n, 1001n + d, d), false);
});

test("inventoryDelta: routed sales leave stock, unrouted ones add to it, needs come from stock first", () => {
  assert.equal(M.inventoryDelta({ out: 7n, in: 0n, held: 3n, routed: true }), 0n);
  assert.equal(M.inventoryDelta({ out: 7n, in: 0n, held: 3n, routed: false }), 7n);
  assert.equal(M.inventoryDelta({ out: 0n, in: 5n, held: 9n, routed: false }), -5n);
  assert.equal(M.inventoryDelta({ out: 0n, in: 5n, held: 2n, routed: true }), -2n);
});

test("calldata tokens and EIP-7623 gas", () => {
  assert.equal(M.calldataTokens("0x"), 0n);
  assert.equal(M.calldataTokens("0x00ff"), 5n);
  assert.equal(M.calldataTokens("00ff10"), 9n);
  assert.throws(() => M.calldataTokens("0x0"));
  const zeros = `0x${"00".repeat(100)}`;
  assert.equal(M.txGasUsed(1000n, zeros), 21_000n + 400n + 1000n + 30_000n);
  const heavy = `0x${"ff".repeat(1000)}`;
  assert.equal(M.txGasUsed(0n, heavy, 0n), 21_000n + 40_000n, "the floor wins on calldata-heavy transactions");
  assert.equal(M.gasLimitFor(100n), 120n);
  assert.equal(M.gasLimitFor(101n), 122n);
});

test("nextBaseFee follows EIP-1559", () => {
  const block = (gasUsed, baseFeePerGas = 8_000_000_000n) => ({ baseFeePerGas, gasUsed, gasLimit: 30_000_000n });
  assert.equal(M.nextBaseFee(block(15_000_000n)), 8_000_000_000n);
  assert.equal(M.nextBaseFee(block(30_000_000n)), 9_000_000_000n);
  assert.equal(M.nextBaseFee(block(0n)), 7_000_000_000n);
  assert.equal(M.nextBaseFee(block(30_000_000n, 7n)), 8n, "a rise is at least one wei");
});

test("fees and replacements", () => {
  assert.deepEqual(M.feesFor(10_000_000_000n, 2), { maxFeePerGas: 22_000_000_000n, maxPriorityFeePerGas: 2_000_000_000n });
  assert.deepEqual(M.replacementFees({ maxFeePerGas: 100n, maxPriorityFeePerGas: 10n }, 1n), {
    maxFeePerGas: 113n,
    maxPriorityFeePerGas: 12n,
  });
  assert.deepEqual(M.replacementFees({ maxFeePerGas: 10n, maxPriorityFeePerGas: 0n }, 50n), {
    maxFeePerGas: 101n,
    maxPriorityFeePerGas: 1n,
  });
  assert.equal(M.gweiToWei(2), 2_000_000_000n);
  assert.equal(M.gweiToWei(0.5), 500_000_000n);
  assert.throws(() => M.gweiToWei(-1));
});

test("profit and the float's floor", () => {
  assert.equal(M.profitUsd({ usdcDelta: 5_000_000n, inventoryUsd: 1.5, gasUsd: 2 }), 4.5);
  const base = { minProfitUsd: 5, gasUsd: 2, inventoryUsd: 0, slippageBps: 30 };
  assert.equal(
    M.usdcFloor({ ...base, simDelta: 10_000_000n, routedVolumeUsdc: 100_000_000_000n }),
    7_000_000n,
    "slippage on a large volume never lowers the floor below the decision",
  );
  assert.equal(M.usdcFloor({ ...base, simDelta: 20_000_000n, routedVolumeUsdc: 1_000_000_000n }), 17_000_000n);
  assert.equal(
    M.usdcFloor({ ...base, inventoryUsd: 4, simDelta: 1_000_000n, routedVolumeUsdc: 0n }),
    3_000_000n,
    "stock the fill adds lowers what the float must earn",
  );
  assert.equal(
    M.usdcFloor({ ...base, minProfitUsd: -10, simDelta: -9_000_000n, routedVolumeUsdc: 0n }),
    -8_000_000n,
    "a negative minimum is an accepted subsidy",
  );
});

test("routeLossBps", () => {
  assert.ok(Math.abs(M.routeLossBps("sell", 990_000n, 1) - 100) < 1e-9);
  assert.ok(Math.abs(M.routeLossBps("buy", 1_010_000n, 1) - 100) < 1e-9);
  assert.ok(M.routeLossBps("sell", 1_010_000n, 1) < 0, "a route that beats Pyth loses nothing");
  assert.equal(M.routeLossBps("sell", 1n, 0), Infinity);
});

test("XS-5: a kept coin counts at the lower of Pyth and its best quote", () => {
  // The audit's Z: $2 at Pyth, $1 in its pools, so no route takes it; the index sells 2,000 of it.
  const z = { price: 2_00000000n, expo: -8 };
  const out = 2_000n * 10n ** 18n;
  const leg = { out, in: 0n, held: 0n, decimals: 18, price: z };
  assert.equal(M.stockChangeUsd({ ...leg, routed: false, quoteUsdc: 2_000n * 10n ** 6n }), 2_000, "at its pools' $1, not Pyth's $2");
  assert.equal(M.stockChangeUsd({ ...leg, routed: false, quoteUsdc: 9_000n * 10n ** 6n }), 4_000, "never above Pyth");
  assert.equal(M.stockChangeUsd({ ...leg, routed: false }), 4_000, "with no pool to quote, at Pyth");
  assert.equal(M.stockChangeUsd({ ...leg, routed: true, quoteUsdc: 2_000n * 10n ** 6n }), 0, "a routed sale leaves stock");
  const eth = { price: 2_000_00000000n, expo: -8 };
  assert.equal(
    M.stockChangeUsd({ out: 0n, in: 5n * 10n ** 18n, held: 2n * 10n ** 18n, routed: true, decimals: 18, price: eth }),
    -4_000,
    "a delivery from stock costs its Pyth value",
  );
  assert.equal(M.keptUsd(10, null), 10);
  assert.equal(M.keptUsd(10, 4_000_000n), 4);
});

test("XS-13: replacement fees never pass MAX_FEE_GWEI", () => {
  assert.deepEqual(M.replacementFees({ maxFeePerGas: 100n, maxPriorityFeePerGas: 10n }, 50n, 105n), {
    maxFeePerGas: 105n,
    maxPriorityFeePerGas: 12n,
  });
  assert.deepEqual(M.replacementFees({ maxFeePerGas: 105n, maxPriorityFeePerGas: 100n }, 50n, 105n), {
    maxFeePerGas: 105n,
    maxPriorityFeePerGas: 105n,
  }, "the tip stops at the cap too, and never above the ceiling");
  let fees = { maxFeePerGas: 100n, maxPriorityFeePerGas: 10n };
  for (let i = 0; i < 100; i++) fees = M.replacementFees(fees, 50n, 150n);
  assert.deepEqual(fees, { maxFeePerGas: 150n, maxPriorityFeePerGas: 150n }, "a hundred bumps stay at the cap");
});

test("RX-1: a price values anything only while fresh and narrow", () => {
  const p = { price: 100_00000000n, conf: 2_00000000n, expo: -8, publishTime: 1_000 };
  assert.equal(M.freshPrice(p, 1_060, 60n, 200n), true, "60 s old, conf at 2%");
  assert.equal(M.freshPrice(p, 1_061, 60n, 200n), false, "a closed feed's last close is refused");
  assert.equal(M.freshPrice({ ...p, conf: 2_00000001n }, 1_000, 60n, 200n), false, "a wider interval is refused");
  assert.equal(M.freshPrice({ ...p, price: 0n }, 1_000, 60n, 200n), false);
  assert.equal(M.freshPrice(undefined, 1_000, 60n, 200n), false);
});

test("RX-2: share-priced Ondo stock is never delivered, and counts as nothing when kept", () => {
  const price = { price: 170_00000000n, expo: -8 };
  const kept = M.stockChangeUsd({ out: 100n * 10n ** 18n, in: 0n, held: 0n, routed: false, decimals: 18, price, quoteUsdc: null, sharePriced: true });
  assert.equal(kept, 0, "a token worth sValue shares is not booked at the share's price");
  const plain = M.stockChangeUsd({ out: 100n * 10n ** 18n, in: 0n, held: 0n, routed: false, decimals: 18, price, quoteUsdc: null });
  assert.equal(plain, 17_000);
  assert.equal(M.deliversSharePricedStock({ need: 1n, held: 1n, sharePriced: true }), true);
  assert.equal(M.deliversSharePricedStock({ need: 1n, held: 0n, sharePriced: true }), false, "bought, not delivered");
  assert.equal(M.deliversSharePricedStock({ need: 1n, held: 5n, sharePriced: false }), false);
});

test("RX-3, RX-31: Pyth's schedule decides when a share feed publishes, holidays and half days included", async () => {
  const { US_EQUITY_SCHEDULE: S } = await import("../../bot/config.mjs");
  // Eastern Standard Time is UTC-5, Eastern Daylight Time UTC-4.
  const est = (y, mo, d, h, m) => Date.UTC(y, mo - 1, d, h + 5, m, 0) / 1000;
  const edt = (y, mo, d, h, m) => Date.UTC(y, mo - 1, d, h + 4, m, 0) / 1000;
  assert.equal(M.inSchedule(est(2027, 2, 16, 9, 30), S), true, "a Tuesday's open");
  assert.equal(M.inSchedule(est(2027, 2, 16, 15, 59), S), true);
  assert.equal(M.inSchedule(est(2027, 2, 16, 16, 0), S), false, "the close is excluded");
  assert.equal(M.inSchedule(est(2027, 2, 16, 9, 29), S), false);
  assert.equal(M.inSchedule(est(2027, 2, 13, 12, 0), S), false, "a Saturday");
  assert.equal(M.inSchedule(est(2027, 2, 15, 12, 0), S), false, "Presidents' Day");
  assert.equal(M.inSchedule(est(2026, 11, 26, 12, 0), S), false, "Thanksgiving");
  assert.equal(M.inSchedule(est(2026, 11, 27, 12, 59), S), true, "the half day after it");
  assert.equal(M.inSchedule(est(2026, 11, 27, 13, 0), S), false);
  assert.equal(M.inSchedule(edt(2027, 6, 1, 10, 0), S), true, "summer time");
  // 2 h of notice and a 24 h auction: μ reaches 1 at the start plus 14 h.
  assert.equal(M.sessionStartOk(est(2027, 2, 16, 0, 0), 7_200, 86_400, S), true, "a 00:00 start puts μ = 1 at 14:00");
  assert.equal(M.sessionStartOk(est(2027, 2, 16, 9, 35), 7_200, 86_400, S), false, "an in-session start puts μ = 1 at 23:35");
  assert.equal(M.sessionStartOk(est(2026, 11, 26, 0, 0), 7_200, 86_400, S), false, "μ = 1 on Thanksgiving");
});

test("RX-16: a subsidised fill fits only what is left of the day's budget", () => {
  const spent = [{ at: 100n, usd: 40 }, { at: 90_000n, usd: 30 }];
  assert.deepEqual(M.subsidyFits(spent, 5, 90_100n, 50), { ok: true, window: [spent[1]] }, "profit needs no budget");
  assert.equal(M.subsidyFits(spent, -20, 90_100n, 50).ok, true, "30 of the last day and 20 more is 50");
  assert.equal(M.subsidyFits(spent, -21, 90_100n, 50).ok, false);
  assert.equal(M.subsidyFits(spent, -21, 86_499n, 90).ok, false, "the first is still inside the day");
  assert.equal(M.subsidyFits([], -0.01, 0n, 0).ok, false, "with no budget, no subsidy");
});

test("RX-10: a reverted request fill strikes the request, its requester and its index", () => {
  const r = { requester: "0xABcd000000000000000000000000000000000001", index: "0xEF00000000000000000000000000000000000002" };
  assert.deepEqual(M.requestStrikeKeys(7n, r), [
    "request:7",
    "requester:0xabcd000000000000000000000000000000000001",
    "index:0xef00000000000000000000000000000000000002",
  ]);
  assert.deepEqual(M.requestStrikeKeys(7n, undefined), ["request:7"], "a request no longer known strikes only itself");
});

test("RX-34: the start checks take the richest ready indexes, at most the cap", () => {
  const ready = [{ index: "a", tvl: 5 }, { index: "b", tvl: 50 }, { index: "c", tvl: 20 }];
  const { chosen, rest } = M.startsToCheck(ready, 2);
  assert.deepEqual(chosen.map((r) => r.index), ["b", "c"]);
  assert.deepEqual(rest.map((r) => r.index), ["a"]);
});

test("RX-18: Pyth's update fee counts against a fill like its gas", () => {
  const gwei = 1_000_000_000n;
  const base = M.fillCostUsd({ used: 1_000_000n, nextBase: 10n * gwei, tip: 2n * gwei, ethUsd: 3_000 });
  assert.equal(base, 36, "1M gas at 12 gwei and $3,000");
  assert.equal(M.fillCostUsd({ used: 1_000_000n, nextBase: 10n * gwei, tip: 2n * gwei, ethUsd: 3_000, pythFee: 10n ** 15n }), 39);
});

test("RX-9: only prices Pyth's contract returned identically from the signed update are kept", () => {
  const key = (id) => id.toLowerCase().replace(/^0x/, "");
  const p = { price: 300_00000000n, conf: 10n, expo: -8, publishTime: 1_000 };
  const prices = new Map([
    ["aa", p],
    ["bb", { ...p, price: 999_00000000n }],
  ]);
  const feed = (id, price) => ({ id, price: { price, conf: 10n, expo: -8, publishTime: 1_000n } });
  const kept = M.verifiedPrices(prices, [feed("0xAA", 300_00000000n), feed("0xbb", 282_00000000n)], key);
  assert.deepEqual([...kept.keys()], ["aa"], "a price Hermes inflated is dropped");
  assert.equal(M.verifiedPrices(prices, [], key).size, 0, "nothing Pyth did not return is kept");
});
