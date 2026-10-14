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
