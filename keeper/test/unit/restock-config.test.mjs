import { test } from "node:test";
import assert from "node:assert/strict";
import { GAS_MIN, parseRestockConfig } from "../../restock/config.mjs";

const VALID = {
  RPC_URL: "https://eth.example",
  EXECUTOR: `0x${"11".repeat(20)}`,
  TREASURY_KEY: `0x${"22".repeat(32)}`,
  PYTH_API_KEY: "key",
  NEEDS_FILE: "/var/keeper/needs.json",
  JOURNAL_FILE: "/var/keeper/restock.json",
  RESTOCK_COINS: "OP",
  OPTIMISM_RPC_URL: "https://op.example",
};

test("the defaults, and only the served coins' chains need settings", () => {
  const { RESTOCK_COINS, ...unset } = VALID;
  assert.throws(() => parseRestockConfig(unset), /AVALANCHE_RPC_URL is required/, "by default, the three served coins' chains");
  const cfg = parseRestockConfig(VALID);
  assert.deepEqual(cfg.coins.map((c) => c.symbol), ["OP"]);
  assert.deepEqual(Object.keys(cfg.chains), ["optimism"]);
  assert.equal(cfg.chains.optimism.key, VALID.TREASURY_KEY, "a home chain signs with the treasury's key");
  assert.equal(cfg.chains.optimism.wormhole, 24);
  assert.equal(cfg.plan.gasMin.get("optimism"), GAS_MIN.optimism);
  assert.deepEqual(
    { ...cfg.plan, gasMin: undefined },
    { bufferBps: 1000, minUsd: 200, dailyUsd: 20000, keepUsd: 1000, maxTransferUsd: 25000, floatTargetUsd: 5000, treasuryTargetUsd: 10000, maxLossBps: 100, gasMin: undefined },
  );
  assert.equal(cfg.intervalSeconds, 60);
  assert.equal(cfg.hermesUrl, "https://pyth.dourolabs.app/hermes");
});

test("every coin's chain needs its RPC, and no other chain's", () => {
  const all = { ...VALID, RESTOCK_COINS: "AVAX,AERO", OPTIMISM_RPC_URL: undefined };
  assert.throws(
    () => parseRestockConfig(all),
    (error) => {
      for (const name of ["AVALANCHE_RPC_URL", "BASE_RPC_URL"]) assert.match(error.message, new RegExp(`${name} is required`));
      assert.doesNotMatch(error.message, /OPTIMISM_RPC_URL/);
      return true;
    },
  );
});

test("an unknown coin, a missing setting and the keeper's own key are all refused at once", () => {
  assert.throws(
    () => parseRestockConfig({ ...VALID, RESTOCK_COINS: "OP,DOGE", EXECUTOR: "0x1", KEEPER_KEY: VALID.TREASURY_KEY, RESTOCK_BUFFER_BPS: "20000" }),
    (error) => {
      assert.match(error.message, /unknown restock coins: DOGE/);
      assert.match(error.message, /EXECUTOR must be an address/);
      assert.match(error.message, /TREASURY_KEY must not be the keeper's KEEPER_KEY/);
      assert.match(error.message, /RESTOCK_BUFFER_BPS must be at most 10000/);
      return true;
    },
  );
});

test("RS-7: a transfer cap below the smallest trade is refused, since every buy is cut to it", () => {
  assert.throws(
    () => parseRestockConfig({ ...VALID, RESTOCK_MIN_USD: "500", RESTOCK_MAX_TRANSFER_USD: "400" }),
    /RESTOCK_MAX_TRANSFER_USD must be at least RESTOCK_MIN_USD/,
  );
  assert.equal(parseRestockConfig({ ...VALID, RESTOCK_MIN_USD: "500", RESTOCK_MAX_TRANSFER_USD: "500" }).plan.maxTransferUsd, 500);
});

test("a local coin, which only UniswapX sells, needs Uniswap's API key and no home chain", () => {
  const local = { ...VALID, RESTOCK_COINS: "NVDAON,AAPLON" };
  assert.throws(() => parseRestockConfig(local), /UNISWAP_API_KEY is required/, "named without the key");
  const cfg = parseRestockConfig({ ...local, UNISWAP_API_KEY: "ux-key" });
  assert.deepEqual(cfg.coins.map((c) => c.symbol), ["NVDAON", "AAPLON"]);
  assert.deepEqual(Object.keys(cfg.chains), [], "no home chain: Ethereum is its home");
  assert.deepEqual(cfg.uniswapx, { apiKey: "ux-key", url: "https://trade-api.gateway.uniswap.org/v1" });
  assert.equal(parseRestockConfig(VALID).uniswapx, null, "no local coin, no UniswapX");

  // Unset RESTOCK_COINS: the default coins, and with the key every local coin besides.
  const { RESTOCK_COINS, ...unset } = VALID;
  const defaults = { ...unset, AVALANCHE_RPC_URL: "https://avax.example", BASE_RPC_URL: "https://base.example" };
  assert.deepEqual(parseRestockConfig(defaults).coins.map((c) => c.symbol), ["AVAX", "AERO"]);
  const withKey = parseRestockConfig({ ...defaults, UNISWAP_API_KEY: "ux-key", UNISWAP_API_URL: "https://ux.example/v1/" });
  assert.equal(withKey.coins.filter((c) => c.local).length, 9);
  assert.equal(withKey.uniswapx.url, "https://ux.example/v1", "its trailing slash dropped");
});
