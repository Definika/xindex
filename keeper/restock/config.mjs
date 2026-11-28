// The restock service's settings, read from the environment and checked before anything runs. No dependencies, so
// the unit tests run without `npm install`.

import { ADDRESS, KEY, envReader } from "../bot/config.mjs";
import { CHAINS, coinsOf } from "./coins.mjs";

const URL = /^https?:\/\/\S+$/;

/// Each home chain's RPC setting. The home chains sign with the treasury's key, as Ethereum does.
const CHAIN_SETTINGS = Object.freeze({
  avalanche: { rpc: "AVALANCHE_RPC_URL" },
  optimism: { rpc: "OPTIMISM_RPC_URL" },
  base: { rpc: "BASE_RPC_URL" },
});

/// The least gas each home chain's wallet keeps, in its gas coin's units: below it nothing is sent there.
export const GAS_MIN = Object.freeze({
  avalanche: 10n ** 17n, // 0.1 AVAX
  optimism: 2n * 10n ** 15n, // 0.002 ETH
  base: 2n * 10n ** 15n, // 0.002 ETH
});

const DEFAULTS = {
  HERMES_URL: "https://pyth.dourolabs.app/hermes",
  UNISWAP_API_URL: "https://trade-api.gateway.uniswap.org/v1",
  RESTOCK_BUFFER_BPS: "1000",
  RESTOCK_MIN_USD: "200",
  RESTOCK_DAILY_USD: "20000",
  RESTOCK_KEEP_USD: "1000",
  RESTOCK_MAX_TRANSFER_USD: "25000",
  RESTOCK_FLOAT_TARGET_USD: "5000",
  RESTOCK_TREASURY_TARGET_USD: "10000",
  ROUTE_MAX_LOSS_BPS: "100",
  RESTOCK_INTERVAL_SECONDS: "60",
};

/// Parses and checks `env`. Throws one Error naming every problem, so a misconfigured service never starts. Only the
/// chains of the coins served (`RESTOCK_COINS`, the default coins when unset) need their settings, and only the local
/// coins, which UniswapX alone sells, Uniswap's API key (UNISWAP_API_KEY); with that key set and RESTOCK_COINS unset,
/// every local coin is served besides the default ones.
export function parseRestockConfig(env) {
  const { problems, get, required, number, bps } = envReader(env, DEFAULTS);
  let coins = [];
  const list = get("RESTOCK_COINS");
  try {
    coins = coinsOf(list ? list.split(",").map((s) => s.trim().toUpperCase()).filter(Boolean) : null, { uniswapx: Boolean(get("UNISWAP_API_KEY")) });
    if (coins.length === 0) problems.push("RESTOCK_COINS is set but names no coin");
  } catch (error) {
    problems.push(error.message);
  }
  const local = coins.filter((c) => c.local);

  const config = {
    rpcUrl: required("RPC_URL", URL, "an http(s) URL"),
    executor: required("EXECUTOR", ADDRESS, "an address"),
    treasuryKey: required("TREASURY_KEY", KEY, "a 32-byte hex private key"),
    pythApiKey: required("PYTH_API_KEY", /^\S+$/, "Pyth's Hermes API key"),
    hermesUrl: required("HERMES_URL", URL, "an http(s) URL")?.replace(/\/+$/, ""),
    needsFile: required("NEEDS_FILE", /^\S+$/, "the keeper's NEEDS_FILE"),
    journalFile: required("JOURNAL_FILE", /^\S+$/, "a file path"),
    coins,
    chains: {},
    uniswapx: local.length
      ? {
          apiKey: required("UNISWAP_API_KEY", /^\S+$/, `Uniswap's Trading API key, for ${local.map((c) => c.symbol).join(", ")}`),
          url: required("UNISWAP_API_URL", URL, "an http(s) URL")?.replace(/\/+$/, ""),
        }
      : null,
    intervalSeconds: number("RESTOCK_INTERVAL_SECONDS", { min: 10, integer: true }),
    plan: {
      bufferBps: bps("RESTOCK_BUFFER_BPS"),
      minUsd: number("RESTOCK_MIN_USD", { min: 0 }),
      dailyUsd: number("RESTOCK_DAILY_USD", { min: 0 }),
      keepUsd: number("RESTOCK_KEEP_USD", { min: 0 }),
      maxTransferUsd: number("RESTOCK_MAX_TRANSFER_USD", { positive: true }),
      floatTargetUsd: number("RESTOCK_FLOAT_TARGET_USD", { min: 0 }),
      treasuryTargetUsd: number("RESTOCK_TREASURY_TARGET_USD", { min: 0 }),
      maxLossBps: bps("ROUTE_MAX_LOSS_BPS"),
      gasMin: new Map(),
    },
  };

  for (const chain of [...new Set(coins.filter((c) => !c.local).map((c) => c.chain))]) {
    const s = CHAIN_SETTINGS[chain];
    config.chains[chain] = {
      ...CHAINS[chain],
      rpcUrl: required(s.rpc, URL, "an http(s) URL"),
      key: config.treasuryKey,
    };
    config.plan.gasMin.set(chain, GAS_MIN[chain]);
  }

  // The keeper's key fills every block; a second sender on it would fight the keeper over its nonces.
  const keeperKey = get("KEEPER_KEY");
  if (keeperKey && config.treasuryKey && keeperKey.toLowerCase() === config.treasuryKey.toLowerCase()) {
    problems.push("TREASURY_KEY must not be the keeper's KEEPER_KEY");
  }

  // Every trade is at least RESTOCK_MIN_USD and at most RESTOCK_MAX_TRANSFER_USD: the second must allow the first.
  if (config.plan.maxTransferUsd < config.plan.minUsd) {
    problems.push("RESTOCK_MAX_TRANSFER_USD must be at least RESTOCK_MIN_USD");
  }

  if (problems.length) throw new Error(`restock configuration:\n  ${problems.join("\n  ")}`);
  return Object.freeze(config);
}
