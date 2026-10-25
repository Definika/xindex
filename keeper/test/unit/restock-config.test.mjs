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
  RESTOCK_COINS: "XRP,ADA",
  BSC_RPC_URL: "https://bsc.example",
};

test("the defaults, and only the served coins' chains need settings", () => {
  const { RESTOCK_COINS, ...unset } = VALID;
  assert.throws(() => parseRestockConfig(unset), /AVALANCHE_RPC_URL is required/, "by default, the seven served coins' chains");
  const cfg = parseRestockConfig(VALID);
  assert.deepEqual(cfg.coins.map((c) => c.symbol), ["XRP", "ADA"]);
  assert.deepEqual(Object.keys(cfg.chains), ["bsc"]);
  assert.equal(cfg.chains.bsc.key, VALID.TREASURY_KEY, "an EVM home chain signs with the treasury's key");
  assert.equal(cfg.chains.bsc.wormhole, 4);
  assert.equal(cfg.plan.gasMin.get("bsc"), GAS_MIN.bsc);
  assert.deepEqual(
    { ...cfg.plan, gasMin: undefined },
    { bufferBps: 1000, minUsd: 200, dailyUsd: 20000, keepUsd: 1000, maxTransferUsd: 25000, floatTargetUsd: 5000, treasuryTargetUsd: 10000, maxLossBps: 100, gasMin: undefined },
  );
  assert.equal(cfg.intervalSeconds, 60);
  assert.equal(cfg.hermesUrl, "https://pyth.dourolabs.app/hermes");
});

test("every coin's chain needs its RPC and, off EVM, its own key", () => {
  const all = { ...VALID, RESTOCK_COINS: "XRP,AVAX,OP,AERO,JUP,SUI,APT,ALGO" };
  assert.throws(
    () => parseRestockConfig(all),
    (error) => {
      for (const name of ["AVALANCHE_RPC_URL", "OPTIMISM_RPC_URL", "BASE_RPC_URL", "SOLANA_RPC_URL", "SOLANA_KEY", "SUI_RPC_URL", "SUI_KEY", "APTOS_RPC_URL", "APTOS_KEY", "ALGORAND_ALGOD_URL", "ALGORAND_MNEMONIC"]) {
        assert.match(error.message, new RegExp(`${name} is required`));
      }
      assert.doesNotMatch(error.message, /BSC_RPC_URL/);
      return true;
    },
  );
  const sui = parseRestockConfig({ ...VALID, RESTOCK_COINS: "sui", SUI_RPC_URL: "https://sui.example", SUI_KEY: `suiprivkey1${"q".repeat(59)}` });
  assert.equal(sui.chains.sui.key, `suiprivkey1${"q".repeat(59)}`);
  assert.throws(() => parseRestockConfig({ ...VALID, RESTOCK_COINS: "APT", APTOS_RPC_URL: "https://a.example", APTOS_KEY: "nope" }), /APTOS_KEY must be a 32-byte hex Ed25519 key/);
});

test("an unknown coin, a missing setting and the keeper's own key are all refused at once", () => {
  assert.throws(
    () => parseRestockConfig({ ...VALID, RESTOCK_COINS: "XRP,DOGE", EXECUTOR: "0x1", KEEPER_KEY: VALID.TREASURY_KEY, RESTOCK_BUFFER_BPS: "20000" }),
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
