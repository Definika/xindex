// The keeper's settings, read from the environment and checked before anything runs. No dependencies, so the unit
// tests run without `npm install`.

/// Ethereum's addresses the keeper trades through, and the protocol's fixed parameters it relies on.
export const MAINNET = Object.freeze({
  chainId: 1,
  swapRouter02: "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
  quoterV2: "0x61fFE014bA17989E743c5F6cB21bF9697530B21e",
  v3Factory: "0x1F98431c8aD98523631AE4a59f267346ea31F984",
  weth: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  usdc: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  ethPriceId: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
});

/// WeightedHub's storage slots for the pending auction (`forge inspect WeightedHub storageLayout`), which the start
/// check overrides to simulate an auction before opening one. The keeper verifies them at startup.
export const HUB_SLOTS = Object.freeze({ eta: 4n, keepMask: 5n });

/// EIP-7825's cap on a transaction's gas.
export const TX_GAS_CAP = 16_777_216n;

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const KEY = /^0x[0-9a-fA-F]{64}$/;

const DEFAULTS = {
  HERMES_URL: "https://pyth.dourolabs.app/hermes",
  MIN_PROFIT_USD: "5",
  MIN_TVL_USD: "1000",
  SLIPPAGE_BPS: "30",
  SUPPLY_TOLERANCE_BPS: "10",
  ROUTE_MAX_LOSS_BPS: "100",
  MAX_FEE_GWEI: "100",
  PRIORITY_FEE_GWEI: "2",
  FILL_REQUESTS: "1",
};

/// Parses and checks `env`. Throws one Error naming every problem, so a misconfigured keeper never starts.
export function parseConfig(env) {
  const problems = [];
  const get = (name) => {
    const raw = env[name] ?? DEFAULTS[name];
    return typeof raw === "string" ? raw.trim() : raw;
  };
  const required = (name, pattern, what) => {
    const value = get(name);
    if (!value) problems.push(`${name} is required`);
    else if (!pattern.test(value)) problems.push(`${name} must be ${what}`);
    return value;
  };
  const number = (name, { min = -Infinity, integer = false, positive = false } = {}) => {
    const raw = get(name);
    const value = raw === "" || raw === undefined ? NaN : Number(raw);
    if (!Number.isFinite(value)) problems.push(`${name} must be a number`);
    else if (integer && !Number.isInteger(value)) problems.push(`${name} must be an integer`);
    else if (value < min) problems.push(`${name} must be at least ${min}`);
    else if (positive && value <= 0) problems.push(`${name} must be positive`);
    return value;
  };
  const bps = (name) => {
    const value = number(name, { min: 0, integer: true });
    if (value > 10_000) problems.push(`${name} must be at most 10000`);
    return value;
  };

  const config = {
    rpcUrl: required("RPC_URL", /^https?:\/\/\S+$/, "an http(s) URL"),
    keeperKey: required("KEEPER_KEY", KEY, "a 32-byte hex private key"),
    factory: required("FACTORY", ADDRESS, "an address"),
    executor: required("EXECUTOR", ADDRESS, "an address"),
    pythApiKey: required("PYTH_API_KEY", /^\S+$/, "Pyth's Hermes API key"),
    hermesUrl: required("HERMES_URL", /^https?:\/\/\S+$/, "an http(s) URL")?.replace(/\/+$/, ""),
    indexes: null,
    minProfitUsd: number("MIN_PROFIT_USD"),
    minTvlUsd: number("MIN_TVL_USD", { min: 0 }),
    slippageBps: bps("SLIPPAGE_BPS"),
    supplyToleranceBps: bps("SUPPLY_TOLERANCE_BPS"),
    routeMaxLossBps: bps("ROUTE_MAX_LOSS_BPS"),
    maxFeeGwei: number("MAX_FEE_GWEI", { positive: true }),
    priorityFeeGwei: number("PRIORITY_FEE_GWEI", { min: 0 }),
    fillRequests: get("FILL_REQUESTS") === "1",
  };
  if (!["0", "1"].includes(get("FILL_REQUESTS"))) problems.push("FILL_REQUESTS must be 0 or 1");

  const list = get("INDEXES");
  if (list) {
    const entries = list.split(",").map((s) => s.trim()).filter(Boolean);
    const bad = entries.filter((s) => !ADDRESS.test(s));
    if (bad.length) problems.push(`INDEXES has entries that are not addresses: ${bad.join(", ")}`);
    else if (entries.length === 0) problems.push("INDEXES is set but names no index");
    else config.indexes = [...new Set(entries.map((s) => s.toLowerCase()))];
  }

  if (problems.length) throw new Error(`keeper configuration:\n  ${problems.join("\n  ")}`);
  return Object.freeze(config);
}
