import { test } from "node:test";
import assert from "node:assert/strict";
import { parseConfig } from "../../bot/config.mjs";

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
  assert.ok(Object.isFrozen(c));
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

test("RX-2, RX-3: the share-priced and session-limited ids are PythIds.sol's", async () => {
  const { SESSION_IDS, SHARE_PRICED_IDS } = await import("../../bot/config.mjs");
  const { readFileSync } = await import("node:fs");
  const source = readFileSync(new URL("../../../script/PythIds.sol", import.meta.url), "utf8");
  const idsOf = (pattern) =>
    [...source.matchAll(new RegExp(`\\((${pattern})[^)]*\\)[^\\n]*\\n\\s*bytes32 internal constant \\w+ = (0x[0-9a-f]{64})`, "g"))].map((m) => m[2]);
  const share = idsOf("Equity\\.(?:US|Index)\\.");
  const us = idsOf("Equity\\.US\\.");
  assert.equal(share.length, 12);
  assert.equal(us.length, 6);
  assert.deepEqual([...SHARE_PRICED_IDS].sort(), share.sort());
  // Pyth's catalogue gives all twelve the regular-hours schedule, the six named 24/7 included (RX-31).
  assert.deepEqual([...SESSION_IDS].sort(), share.sort());
});

test("RX-16: SUBSIDY_BUDGET_USD defaults to none and cannot be negative", () => {
  assert.equal(parseConfig(VALID).subsidyBudgetUsd, 0);
  assert.equal(parseConfig({ ...VALID, SUBSIDY_BUDGET_USD: "250" }).subsidyBudgetUsd, 250);
  assert.throws(() => parseConfig({ ...VALID, SUBSIDY_BUDGET_USD: "-1" }), /SUBSIDY_BUDGET_USD must be at least 0/);
});
