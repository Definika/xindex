import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { failedRequests, revertedFills, revertedRequestFills, shortRequests, skippedRequests } from "../../bot/backoff.mjs";
import { CHAINS, MAINNET, parseConfig } from "../../bot/config.mjs";
import * as M from "../../bot/math.mjs";
import { TxTracker } from "../../bot/nonce.mjs";
import { ROUTE_REQUOTE_BLOCKS, createRoutes, marketOf, path } from "../../bot/routes.mjs";

const read = (file) => readFileSync(new URL(`../../../script/${file}`, import.meta.url), "utf8");
const constants = (file) =>
  new Map([...read(file).matchAll(/(?:address|bytes32) internal constant (\w+) = (0x[0-9a-fA-F]{40,64});/g)].map((m) => [m[1], m[2].toLowerCase()]));
const BNB = CHAINS[56];
const BASE = CHAINS[8453];
const lower = (x) => x.toLowerCase();

const VALID = {
  RPC_URL: "https://rpc.example",
  KEEPER_KEY: `0x${"11".repeat(32)}`,
  FACTORY: `0x${"22".repeat(20)}`,
  EXECUTOR: `0x${"33".repeat(20)}`,
  PYTH_API_KEY: "key",
};

test("BNB Chain's and Base's entries are their address books' tokens, Uniswap V3 factory and Pyth", () => {
  const bnb = constants("BnbChainAddresses.sol");
  assert.equal(lower(BNB.usdc), bnb.get("USDC"));
  assert.equal(lower(BNB.weth), bnb.get("WBNB"), "WBNB is the routing hub");
  assert.equal(lower(BNB.v3Factory), bnb.get("UNISWAP_V3_FACTORY"));
  assert.equal(lower(BNB.pyth), bnb.get("PYTH"));
  const base = constants("BaseAddresses.sol");
  assert.equal(lower(BASE.usdc), base.get("USDC"));
  assert.equal(lower(BASE.weth), base.get("WETH"));
  assert.equal(lower(BASE.v3Factory), base.get("UNISWAP_V3_FACTORY"));
  assert.equal(lower(BASE.pyth), base.get("PYTH"));
  // Gas is valued at the gas coin's own Pyth price: BNB's on BNB Chain, ETH's on Base.
  const ids = constants("PythIds.sol");
  assert.equal(BNB.ethPriceId, ids.get("BNB"));
  assert.equal(BASE.ethPriceId, MAINNET.ethPriceId);
  // The float's decimals: BNB Chain's Binance-Peg USDC has eighteen (the address book's note), Base's six.
  assert.equal(BNB.usdcDecimals, 18);
  assert.equal(BASE.usdcDecimals, 6);
  for (const c of [BNB, BASE]) {
    assert.equal(c.feedsFromFactory, true, `${c.name} takes each token's feed from the factory`);
    assert.deepEqual(c.priceIds, {});
  }
  assert.equal(BASE.l1FeeOracle, "0x420000000000000000000000000000000000000F", "OP Stack's GasPriceOracle predeploy");
  assert.equal(BNB.l1FeeOracle, null);
  assert.equal(MAINNET.l1FeeOracle, null);
  assert.equal(MAINNET.feedsFromFactory, false);
});

test("each chain's gas defaults are its own, and an operator's setting still wins", () => {
  const at = (id, extra = {}) => parseConfig({ ...VALID, CHAIN_ID: id, ...extra });
  assert.deepEqual([at("1").maxFeeGwei, at("1").priorityFeeGwei], [100, 2]);
  assert.deepEqual([at("56").maxFeeGwei, at("56").priorityFeeGwei], [1, 0.1]);
  assert.deepEqual([at("8453").maxFeeGwei, at("8453").priorityFeeGwei], [1, 0.01]);
  assert.deepEqual([at("56", { MAX_FEE_GWEI: "3", PRIORITY_FEE_GWEI: "0.2" }).maxFeeGwei, at("56", { PRIORITY_FEE_GWEI: "0.2" }).priorityFeeGwei], [3, 0.2]);
  assert.equal(M.gweiToWei(0.01), 10_000_000n, "a hundredth of a gwei is ten million wei");
  assert.equal(at("56").chain, BNB);
  assert.equal(at("8453").chain, BASE);
});

test("a fill is priced at the earliest second it can land and has its chain's window to land in", () => {
  const T = 1_800_000_000n;
  // Ethereum: the next block, twelve seconds on, is both the second it is priced at and its deadline, as always.
  assert.deepEqual(M.landing(T, MAINNET), { at: T + 12n, by: T + 12n });
  assert.equal(M.blocksIn(MAINNET.fillWindowSeconds, MAINNET), 1n);
  assert.equal(M.blockScale(MAINNET), 1n);
  // BNB Chain and Base: the next block may carry the same second; three seconds to land, in 7 and 15 blocks.
  assert.deepEqual(M.landing(T, BNB), { at: T, by: T + 3n });
  assert.deepEqual(M.landing(T, BASE), { at: T, by: T + 3n });
  assert.equal(M.blocksIn(BNB.fillWindowSeconds, BNB), 7n);
  assert.equal(M.blocksIn(BASE.fillWindowSeconds, BASE), 15n);
  // One of Ethereum's blocks spans 27 of BNB Chain's and 60 of Base's.
  assert.equal(M.blockScale(BNB), 27n);
  assert.equal(M.blockScale(BASE), 60n);
  assert.equal(M.blocksIn(0.1, BASE), 1n, "never less than one block");
});

test("the float's dollars use its own decimals: eighteen on BNB Chain lose nothing to a float", () => {
  assert.equal(M.usdToUsdcCeil(5), 5_000_000n);
  assert.equal(M.usdToUsdcCeil(5, 18), 5n * 10n ** 18n);
  assert.equal(M.usdToUsdcCeil(1.0000001, 18), 1_000_001n * 10n ** 12n, "rounded up to a millionth, then scaled exactly");
  assert.equal(M.usdToUsdcCeil(0.5, 2), 50n);
  assert.equal(M.usdcUsd(7n * 10n ** 18n, 18), 7);
  assert.equal(M.profitUsd({ usdcDelta: 12n * 10n ** 18n, inventoryUsd: 1, gasUsd: 0.5, decimals: 18 }), 12.5);
  assert.equal(M.profitUsd({ usdcDelta: 12n * 10n ** 18n, inventoryUsd: 1, gasUsd: 0.5 }) > 1e12, true, "the 6-decimal default would count it a trillion times");
  assert.equal(M.keptUsd(10, 4n * 10n ** 18n, 18), 4, "a kept coin at its quote in eighteen decimals");
  const floor = M.usdcFloor({ simDelta: 20n * 10n ** 18n, minProfitUsd: 5, gasUsd: 1, inventoryUsd: 0, routedVolumeUsdc: 10n * 10n ** 18n, slippageBps: 30, decimals: 18 });
  assert.equal(floor, 20n * 10n ** 18n - 3n * 10n ** 16n, "the simulated delta less 30 bps of the routed volume, above the $6 decision");
  assert.equal(M.worstProfitUsd({ simDelta: 20n * 10n ** 18n, minProfitUsd: 5, gasUsd: 1, inventoryUsd: 0, routedVolumeUsdc: 10n * 10n ** 18n, slippageBps: 30, decimals: 18 }), 18.97);
});

test("a request's stablecoin is counted in its own decimals: BNB Chain's USDT and USDC have eighteen", () => {
  const mint = { isMint: true, escrow: 101n * 10n ** 18n, limit: 10n ** 18n };
  assert.deepEqual(M.requestUsd(mint, 100, 18), { escrowUsd: 101, limitUsd: 100 });
  const redeem = { isMint: false, escrow: 10n ** 18n, limit: 99n * 10n ** 18n };
  assert.deepEqual(M.requestUsd(redeem, 100, 18), { escrowUsd: 100, limitUsd: 99 });
  // Ranked with the stablecoin's decimals, the mint is worth $101 and pays $1 over its limit; at six it would rank as
  // a trillion dollars.
  const INDEX = `0x${"44".repeat(20)}`;
  const info = new Map([[INDEX, { shareUsd: 100, mintAllowed: true, nonce: 0n }]]);
  const entry = { id: 1n, request: { ...mint, index: INDEX, stable: BNB.usdc, open: true, deadline: 10n ** 12n, rebalanceNonce: 0n } };
  const { chosen } = M.fillableRequests([entry], 1n, [INDEX], info, 8, 0, () => 18);
  assert.equal(chosen.length, 1);
  assert.equal(chosen[0].usd, 101);
  const groups = M.batchGroups([entry, { ...entry, id: 2n }], 1n, [INDEX], info, { decimalsOf: () => 18 });
  assert.equal(groups[0].members[0].surplusUsd, 1);
});

test("gas on Base counts the L1 data fee on top, in the gas coin's wei", () => {
  const base = M.fillCostUsd({ used: 100_000n, nextBase: 10_000_000n, tip: 1_000_000n, ethUsd: 3000 });
  const withL1 = M.fillCostUsd({ used: 100_000n, nextBase: 10_000_000n, tip: 1_000_000n, ethUsd: 3000, l1Fee: 10n ** 13n });
  assert.equal(base, 0.0033);
  assert.equal(Math.round((withL1 - base) * 1e6) / 1e6, 0.03, "1e13 wei of L1 fee at $3,000 an ether");
});

test("the back-offs last the same time on every chain: their blocks scale with the chain's", () => {
  const fill = revertedFills(27n);
  assert.deepEqual(fill.fail("a", 1_000), { failures: 1, until: 1_000 + 135, stopped: false }, "5 of Ethereum's blocks are 135 of BNB Chain's");
  assert.equal(fill.fail("a", 1_000).until, 1_000 + 270);
  assert.equal(fill.fail("a", 1_000 + 299 * 27).stopped, true, "a third strike within an hour's blocks stops the auction");
  const fresh = revertedFills(27n);
  fresh.fail("b", 1_000);
  fresh.fail("b", 1_000);
  assert.equal(fresh.fail("b", 1_000 + 300 * 27).failures, 1, "after 8,100 blocks, an hour, the strikes have lapsed");
  assert.equal(revertedRequestFills(60n).fail("r", 0).until, 300);
  assert.equal(failedRequests(60n).fail("f", 0).until, 120);
  assert.equal(skippedRequests(27n).fail("s", 0).until, 54);
  const short = shortRequests(27n);
  for (let k = 0; k < 10; k++) short.fail("w", 0);
  assert.equal(short.fail("w", 0).until, 50 * 27, "capped at SHORT_RECHECK_BLOCKS of Ethereum's blocks");
  // NEEDS_MAX_AGE_SECONDS is 900: that cap, in BNB Chain's 450 ms blocks, stays under it.
  assert.ok((50 * 27 * BNB.blockMs) / 1000 < 900);
  assert.equal(revertedFills().fail("e", 0).until, 5, "Ethereum's are unchanged");
  assert.throws(() => revertedFills(0n), /not a block scale/);
});

test("the route cache's windows scale with the chain's blocks, and the float takes the chain's decimals", async () => {
  assert.equal(marketOf(BNB).usdcDecimals, 18);
  assert.equal(marketOf(BNB).blockScale, 27n);
  assert.equal(marketOf(BASE).blockScale, 60n);
  assert.equal(marketOf(MAINNET).blockScale, 1n);
  // A routed leg keeps its route for ROUTE_REQUOTE_BLOCKS of Ethereum's blocks: 675 of BNB Chain's.
  const Z = `0x${"5a".repeat(20)}`;
  let quotes = 0;
  const fake = {
    isRevert: () => false,
    multicall: async (contracts) =>
      contracts[0]?.functionName === "slot0"
        ? contracts.map(() => ({ status: "success", result: [1n << 96n, 0, 0, 0, 0, 0, true] }))
        : contracts.map((_, i) => ({ status: "success", result: i === 0 ? `0x${"99".repeat(20)}` : `0x${"00".repeat(20)}` })),
    call: async ({ args: [, amount] }) => {
      quotes += 1;
      return [(amount * 2n * 10n ** 18n) / 10n ** 18n, [], [], 0n];
    },
  };
  const routes = createRoutes(fake, { routeMaxLossBps: 100 }, { v3Factory: [], v3Pool: [], quoter: [] }, marketOf(BNB));
  const sell = (blockNumber) => routes.best({ key: "k", token: Z, side: "sell", amount: 10n ** 18n, fairUsd: 2, blockNumber });
  assert.equal(await sell(1_000n), path(Z, 100, BNB.usdc));
  await sell(1_000n + ROUTE_REQUOTE_BLOCKS * 27n - 1n);
  assert.equal(quotes, 1, "not quoted again within 675 blocks, five minutes");
  await sell(1_000n + ROUTE_REQUOTE_BLOCKS * 27n);
  assert.equal(quotes, 2, "quoted again after them");
  assert.equal(routes.quoteOf({ key: "k", token: Z, side: "sell", amount: 10n ** 18n }), 2n * 10n ** 18n, "a quote in the float's eighteen decimals");
  assert.equal(M.routeLossBps("sell", 2n * 10n ** 18n, 2, marketOf(BNB).usdcDecimals), 0);
});

test("a transaction is given its chain's blocks to land before it is replaced, and so is each replacement", async () => {
  const chain = {
    address: `0x${"be".repeat(20)}`,
    latest: 5n,
    pending: 5n,
    sent: [],
    latestNonce: async () => chain.latest,
    pendingNonce: async () => chain.pending,
    receipt: async () => null,
    send: async (tx) => {
      chain.sent.push(tx);
      chain.pending = tx.nonce + 1n;
      return `0x${chain.sent.length.toString(16).padStart(64, "0")}`;
    },
  };
  const t = new TxTracker(chain, () => {}, { landBlocks: 7 });
  const FILL = { to: "0x1", data: "0xab", value: 0n, gas: 300_000n, maxFeePerGas: 100n, maxPriorityFeePerGas: 10n };
  await t.send(FILL, { label: "fill", targetBlock: 100 + 7 });
  for (let b = 101; b < 107; b++) assert.equal(await t.onBlock(b, 50n), null);
  assert.equal(chain.sent.length, 1, "not replaced while its seven blocks run");
  await t.onBlock(107, 50n);
  assert.equal(chain.sent.length, 2, "replaced once they have passed");
  for (let b = 108; b < 114; b++) await t.onBlock(b, 50n);
  assert.equal(chain.sent.length, 2, "and the replacement gets seven blocks too");
  await t.onBlock(114, 50n);
  assert.equal(chain.sent.length, 3);
  assert.throws(() => new TxTracker(chain, () => {}, { landBlocks: 0 }), /not a number of blocks/);
});
