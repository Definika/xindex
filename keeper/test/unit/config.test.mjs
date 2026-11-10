import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { CHAINS, MAINNET, parseConfig } from "../../bot/config.mjs";
import { ETHEREUM_MARKET, marketOf } from "../../bot/routes.mjs";

const VALID = {
  RPC_URL: "https://rpc.example",
  KEEPER_KEY: `0x${"ab".repeat(32)}`,
  FACTORY: `0x${"11".repeat(20)}`,
  EXECUTOR: `0x${"22".repeat(20)}`,
  PYTH_API_KEY: "secret",
};

test("defaults fill the optional settings", () => {
  const c = parseConfig(VALID);
  assert.equal(c.hermesUrl, "https://pyth.dourolabs.app/hermes");
  assert.equal(c.minProfitUsd, 5);
  assert.equal(c.minTvlUsd, 1000);
  assert.equal(c.slippageBps, 30);
  assert.equal(c.supplyToleranceBps, 10);
  assert.equal(c.routeMaxLossBps, 100);
  assert.equal(c.maxFeeGwei, 100);
  assert.equal(c.priorityFeeGwei, 2);
  assert.equal(c.indexes, null);
  assert.equal(c.chain, MAINNET);
  assert.equal(c.fillAuctions, true);
  assert.ok(Object.isFrozen(c));
});

test("CHAIN_ID picks the chain's addresses, and the Sepolia keeper can serve requests alone", () => {
  const c = parseConfig({ ...VALID, CHAIN_ID: "11155111", FILL_AUCTIONS: "0" });
  assert.equal(c.chain, CHAINS[11155111]);
  assert.equal(c.chain.name, "Sepolia");
  assert.equal(c.fillAuctions, false);
  assert.equal(c.fillRequests, true);
  assert.equal(marketOf(c.chain).usdc, CHAINS[11155111].usdc);
  assert.deepEqual(ETHEREUM_MARKET, marketOf(MAINNET));
  assert.throws(() => parseConfig({ ...VALID, CHAIN_ID: "56" }), /CHAIN_ID must be one of 1, 11155111/);
  assert.throws(() => parseConfig({ ...VALID, FILL_AUCTIONS: "yes" }), /FILL_AUCTIONS must be 0 or 1/);
  assert.throws(
    () => parseConfig({ ...VALID, FILL_AUCTIONS: "0", FILL_REQUESTS: "0" }),
    /FILL_AUCTIONS and FILL_REQUESTS are both off/,
  );
});

test("Sepolia's entry is the test deployment's market in docs/deployment.md", async () => {
  const docs = await readFile(new URL("../../../docs/deployment.md", import.meta.url), "utf8");
  const sepolia = CHAINS[11155111];
  const rows = {
    "Uniswap SwapRouter02": sepolia.swapRouter02,
    "Uniswap QuoterV2": sepolia.quoterV2,
    "Uniswap V3 factory": sepolia.v3Factory,
    WETH: sepolia.weth,
    "Wormhole Token Bridge": sepolia.tokenBridge,
    "tUSDC (FaucetToken, 6 decimals)": sepolia.usdc,
  };
  for (const [row, address] of Object.entries(rows)) assert.ok(docs.includes(`| ${row} | \`${address}\` |`), row);
});

test("a trailing slash on HERMES_URL is dropped, and a negative minimum profit is a subsidy", () => {
  const c = parseConfig({ ...VALID, HERMES_URL: "http://127.0.0.1:8790/", MIN_PROFIT_USD: "-10" });
  assert.equal(c.hermesUrl, "http://127.0.0.1:8790");
  assert.equal(c.minProfitUsd, -10);
});

test("every missing requirement is named at once", () => {
  assert.throws(
    () => parseConfig({}),
    (e) => ["RPC_URL", "KEEPER_KEY", "FACTORY", "EXECUTOR", "PYTH_API_KEY"].every((n) => e.message.includes(`${n} is required`)),
  );
});

test("malformed values are refused", () => {
  const cases = [
    [{ FACTORY: "0x1234" }, "FACTORY must be an address"],
    [{ KEEPER_KEY: "0xabc" }, "KEEPER_KEY must be a 32-byte hex private key"],
    [{ RPC_URL: "ws://x" }, "RPC_URL must be an http(s) URL"],
    [{ MIN_PROFIT_USD: " " }, "MIN_PROFIT_USD must be a number"],
    [{ MIN_PROFIT_USD: "five" }, "MIN_PROFIT_USD must be a number"],
    [{ SLIPPAGE_BPS: "1.5" }, "SLIPPAGE_BPS must be an integer"],
    [{ SLIPPAGE_BPS: "20000" }, "SLIPPAGE_BPS must be at most 10000"],
    [{ ROUTE_MAX_LOSS_BPS: "-1" }, "ROUTE_MAX_LOSS_BPS must be at least 0"],
    [{ MIN_TVL_USD: "-1" }, "MIN_TVL_USD must be at least 0"],
    [{ MAX_FEE_GWEI: "0" }, "MAX_FEE_GWEI must be positive"],
    [{ INDEXES: "0x12,nope" }, "INDEXES has entries that are not addresses"],
    [{ INDEXES: " , " }, "INDEXES is set but names no index"],
  ];
  for (const [over, message] of cases) {
    assert.throws(() => parseConfig({ ...VALID, ...over }), (e) => e.message.includes(message), message);
  }
});

test("INDEXES is lowercased and deduplicated", () => {
  const a = `0x${"Aa".repeat(20)}`;
  const c = parseConfig({ ...VALID, INDEXES: `${a}, ${a.toLowerCase()}` });
  assert.deepEqual(c.indexes, [a.toLowerCase()]);
});

test("RX-2: the share-priced ids are PythIds.sol's", async () => {
  const { SHARE_PRICED_IDS } = await import("../../bot/config.mjs");
  const { readFileSync } = await import("node:fs");
  const source = readFileSync(new URL("../../../script/PythIds.sol", import.meta.url), "utf8");
  const share = [...source.matchAll(/\((Equity\.(?:US|Index)\.)[^)]*\)[^\n]*\n\s*bytes32 internal constant \w+ = (0x[0-9a-f]{64})/g)].map((m) => m[2]);
  assert.equal(share.length, 12);
  assert.deepEqual([...SHARE_PRICED_IDS].sort(), share.sort());
});

test("the keeper values a chain's own coins, and PRICE_IDS adds to them or changes one", () => {
  const token = `0x${"Cd".repeat(20)}`;
  const id = `0x${"ab".repeat(32)}`;
  const weth = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";
  assert.equal(Object.keys(parseConfig(VALID).priceIds).length, 91);
  assert.equal(parseConfig(VALID).priceIds[weth], "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace");
  const c = parseConfig({ ...VALID, PRICE_IDS: `${token}=${id}, ${weth}=${id}` });
  assert.equal(c.priceIds[token.toLowerCase()], id);
  assert.equal(c.priceIds[weth], id, "an entry replaces the catalogue's");
  assert.equal(Object.keys(c.priceIds).length, 92);
  assert.equal(Object.keys(parseConfig({ ...VALID, CHAIN_ID: "11155111" }).priceIds).length, 4, "Sepolia's test tokens");
  for (const bad of ["junk", `${token}`, `${token}=0x12`, `${token}=${id}=${id}`, `0x12=${id}`]) {
    assert.throws(() => parseConfig({ ...VALID, PRICE_IDS: bad }), /PRICE_IDS has an entry that is not token=id/, bad);
  }
});

test("TRADE_COST_BPS defaults to 30 and is a count of basis points", () => {
  assert.equal(parseConfig(VALID).tradeCostBps, 30);
  assert.equal(parseConfig({ ...VALID, TRADE_COST_BPS: "0" }).tradeCostBps, 0);
  assert.throws(() => parseConfig({ ...VALID, TRADE_COST_BPS: "10001" }), /TRADE_COST_BPS must be at most 10000/);
});

test("every chain names Pyth's contract, which the keeper alone asks", async () => {
  const { CHAINS } = await import("../../bot/config.mjs");
  assert.equal(CHAINS[1].pyth, "0x4305FB66699C3B2702D4d05CF36551390A4c69C6");
  assert.equal(CHAINS[11155111].pyth, "0xDd24F84d36BF92C65F92307595335bdFab5Bbd21");
});

test("RX-16: SUBSIDY_BUDGET_USD defaults to none and cannot be negative", () => {
  assert.equal(parseConfig(VALID).subsidyBudgetUsd, 0);
  assert.equal(parseConfig({ ...VALID, SUBSIDY_BUDGET_USD: "250" }).subsidyBudgetUsd, 250);
  assert.throws(() => parseConfig({ ...VALID, SUBSIDY_BUDGET_USD: "-1" }), /SUBSIDY_BUDGET_USD must be at least 0/);
});
