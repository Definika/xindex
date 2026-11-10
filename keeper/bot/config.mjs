// The keeper's settings, read from the environment and checked before anything runs. No dependencies, so the unit
// tests run without `npm install`.

import { MAINNET_PRICE_IDS } from "./price-ids.mjs";

const WETH_ID = "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace";

/// The chains the keeper runs on, by chain id (`CHAIN_ID`): the addresses it trades through on each, and the keeper's
/// own price source there. No contract reads a price (since 2026-11-10): `pyth` is Pyth's contract, which the keeper
/// alone asks to confirm that a price Hermes served is the signed one (RX-9, RY-7), and `priceIds` maps each coin the
/// keeper can value to its Pyth id. A coin without an entry is one the keeper leaves alone.
export const CHAINS = Object.freeze({
  1: Object.freeze({
    name: "Ethereum",
    chainId: 1,
    swapRouter02: "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
    quoterV2: "0x61fFE014bA17989E743c5F6cB21bF9697530B21e",
    v3Factory: "0x1F98431c8aD98523631AE4a59f267346ea31F984",
    weth: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    usdc: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    // Wormhole's Token Bridge, through which the restock service bridges the copies in and out.
    tokenBridge: "0x3ee18B2214AFF97000D974cf647E7C347E8fa585",
    ethPriceId: WETH_ID,
    pyth: "0x4305FB66699C3B2702D4d05CF36551390A4c69C6",
    priceIds: MAINNET_PRICE_IDS,
  }),
  // The test deployment's market (docs/deployment.md, "Testnet (Sepolia)"): Uniswap V3 pools against tUSDC, the
  // FaucetToken the deployment mints with. Read on chain on 2026-10-31: SwapRouter02 and QuoterV2 answer factory()
  // with the V3 factory, SwapRouter02's WETH9() is WETH, and the Token Bridge's chainId() is Sepolia's Wormhole id,
  // 10002. Its hub is the build of 07aeae1, which rebalances at Pyth's prices, so until a deployment of the
  // oracle-free build replaces it the keeper serves it with FILL_AUCTIONS=0: requests only. The test tokens are priced
  // at their mainnet counterparts' ids, as that deployment listed them.
  11155111: Object.freeze({
    name: "Sepolia",
    chainId: 11155111,
    swapRouter02: "0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E",
    quoterV2: "0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3",
    v3Factory: "0x0227628f3F023bb0B980b67D528571c95c6DaC1c",
    weth: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
    usdc: "0xD1aF4223B129071f7a1a27ED367E4D72cd7cF8D3",
    tokenBridge: "0xDB5492265f6038831E89f495670FF909aDe94bd9",
    ethPriceId: WETH_ID,
    pyth: "0xDd24F84d36BF92C65F92307595335bdFab5Bbd21",
    priceIds: Object.freeze({
      "0xfff9976782d46cc05630d1f6ebab18b2324d6b14": WETH_ID, // WETH
      "0x656c9999ad6092f813996c30a2dbe89ff2f670a9": "0xc9d8b075a5c69303365ae23633d4e085199bf5c520a3b90fed1322a0342ffc33", // tWBTC
      "0xc02f993785fc45cf48bf61c24dcbb11f9085a4e4": "0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221", // tLINK
      "0xc34fe6c23897ae506368cf3acb0db96d6d63bf85": "0x78d185a741d07edb3412b09008b7c5cfb9bbbd7d568bf00ba737b456ba171501", // tUNI
    }),
  }),
});

/// Ethereum's entry, which the restock service, mainnet-only, uses throughout.
export const MAINNET = CHAINS[1];

/// WeightedHub's storage slots for the pending auction (`forge inspect WeightedHub storageLayout`), which the start
/// check overrides to simulate an auction before opening one; `quoteProposal` is zeroed there, since a start of the
/// keeper's posts no quote and a past proposal's must not bind the simulation. The keeper verifies them at startup, and
/// `test_XS8_theBotsHubSlotsAreTheHubs` (keeper/test/KeeperExecutor.t.sol) pins them against a real hub.
export const HUB_SLOTS = Object.freeze({ eta: 6n, keepMask: 7n, quoteProposal: 14n });

/// WeightedHub's slots for the recorded units and scale, which no view returns: `components()` reports units at the
/// scale an accrual now would leave. The invariant checker (invariants.mjs) reads them to evaluate the backing
/// invariant exactly, cross-checks them against the views every round, and `test_theCheckersHubSlotsAreTheHubs`
/// (keeper/test/KeeperExecutor.t.sol) pins them against a real hub. Slot 0 holds the length of `_components`, whose
/// element `i` is the word at keccak256(slot 0) + i: the token in its low 20 bytes, the units in the 12 above. Slot 3
/// holds `_scale` (uint128), then `_lastAccrual` (uint40) and `_maskedFill` (bool).
export const HUB_STATE_SLOTS = Object.freeze({ components: 0n, scale: 3n });

/// EIP-7825's cap on a transaction's gas.
export const TX_GAS_CAP = 16_777_216n;

/// A price older than this many seconds is a closed or quiet feed (US-hours stock feeds): the keeper values nothing at
/// it, so it moves no such leg and fills no request priced at it (RX-1).
export const FRESH_SECONDS = 60n;

/// The widest confidence interval a price the bot values anything at may carry, in basis points of the price (RX-1).
export const MAX_CONF_BPS = 200n;

/// The twelve Ondo legs whose Pyth feed prices the share, while each token is worth sValue shares (script/PythIds.sol,
/// CF-3). The bot cannot read sValue, so it never values these at Pyth: it names no new units for them, delivers none
/// from stock and counts any it keeps as nothing (RX-2). `test/unit/config.test.mjs` pins the list against PythIds.sol.
export const SHARE_PRICED_IDS = Object.freeze(
  [
    "0x329635cf9e705e01ed2d842fafbb6c426d7e5630e75847740d89957222fd68b8", // AMZNon, Equity.Index.AMZN/USD
    "0xe722560a66e4ab00522ef20a38fa2ba5d1b41f1c5404723ed895d202a7af7cc4", // TSMon, Equity.US.TSM/USD
    "0x2dbfb1791e75725227a90dbd23c6bdd83b80cc9d13011973c948b6aeacdf17b9", // SPCXon, Equity.Index.SPCX/USD
    "0x2cc0c022f7f37920485a5947f3cea8633783b6cb7fff6d94ee52f48687b7783d", // METAon, Equity.Index.META/USD
    "0xd0c9aef79b28308b256db7742a0a9b08aaa5009db67a52ea7fa30ed6853f243b", // AVGOon, Equity.US.AVGO/USD
    "0xb196587ca694ea231cd8710321f4f62ed08794c6a096759d5c63616730042ae0", // SKHYon, Equity.Index.SKHY/USD
    "0x27e65b49e4572601374c5bde284411c20f49eb74845cc7f7801f9d27fba2b4b2", // MUon, Equity.Index.MU/USD
    "0x70dcf5fd56553d0023693e4b590336a8c9bcfd0d98dd9f093b1f697820d98325", // LLYon, Equity.US.LLY/USD
    "0xfa1a3697811ac1b36846b4de42ad1b4d3c7b50b556eed405dbefbf4e4a0c7c07", // AMDon, Equity.Index.AMD/USD
    "0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e", // JPMon, Equity.US.JPM/USD
    "0x327ae981719058e6fb44e132fb4adbf1bd5978b43db0661bfdaefd9bea0c82dc", // WMTon, Equity.US.WMT/USD
    "0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90", // Von, Equity.US.V/USD
  ].map((id) => id.toLowerCase()),
);

export const ID = /^0x[0-9a-fA-F]{64}$/;
export const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
export const KEY = /^0x[0-9a-fA-F]{64}$/;

const DEFAULTS = {
  HERMES_URL: "https://pyth.dourolabs.app/hermes",
  MIN_PROFIT_USD: "5",
  MIN_TVL_USD: "1000",
  SLIPPAGE_BPS: "30",
  SUPPLY_TOLERANCE_BPS: "10",
  ROUTE_MAX_LOSS_BPS: "100",
  TRADE_COST_BPS: "30",
  MAX_FEE_GWEI: "100",
  PRIORITY_FEE_GWEI: "2",
  FILL_REQUESTS: "1",
  FILL_AUCTIONS: "1",
  CHAIN_ID: "1",
  SUBSIDY_BUDGET_USD: "0",
};

/// The checks every setting of `env` goes through, with `defaults` for the ones left unset. Each records what is wrong
/// in `problems` rather than throwing, so a caller can name every problem at once.
export function envReader(env, defaults) {
  const problems = [];
  const get = (name) => {
    const raw = env[name] ?? defaults[name];
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

  return { problems, get, required, number, bps };
}

/// Parses and checks `env`. Throws one Error naming every problem, so a misconfigured keeper never starts.
export function parseConfig(env) {
  const { problems, get, required, number, bps } = envReader(env, DEFAULTS);

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
    // What trading a leg is taken to cost when the bot names a fill's units: a leg within this of its weight is left
    // alone rather than traded for nothing (bot/units.mjs).
    tradeCostBps: bps("TRADE_COST_BPS"),
    priceIds: null,
    maxFeeGwei: number("MAX_FEE_GWEI", { positive: true }),
    priorityFeeGwei: number("PRIORITY_FEE_GWEI", { min: 0 }),
    chain: CHAINS[get("CHAIN_ID")] ?? null,
    fillRequests: get("FILL_REQUESTS") === "1",
    fillAuctions: get("FILL_AUCTIONS") === "1",
    // What fills below zero profit may cost in all, per rolling day, when MIN_PROFIT_USD is negative; requests are never
    // subsidised (RX-16).
    subsidyBudgetUsd: number("SUBSIDY_BUDGET_USD", { min: 0 }),
    // Where to write the coins fills are short of, for the restock service; unset, nothing is written.
    needsFile: get("NEEDS_FILE") || null,
  };
  if (!["0", "1"].includes(get("FILL_REQUESTS"))) problems.push("FILL_REQUESTS must be 0 or 1");
  if (!["0", "1"].includes(get("FILL_AUCTIONS"))) problems.push("FILL_AUCTIONS must be 0 or 1");
  else if (get("FILL_AUCTIONS") === "0" && get("FILL_REQUESTS") === "0") problems.push("FILL_AUCTIONS and FILL_REQUESTS are both off: nothing to do");
  if (!config.chain) problems.push(`CHAIN_ID must be one of ${Object.keys(CHAINS).join(", ")}`);

  const list = get("INDEXES");
  if (list) {
    const entries = list.split(",").map((s) => s.trim()).filter(Boolean);
    const bad = entries.filter((s) => !ADDRESS.test(s));
    if (bad.length) problems.push(`INDEXES has entries that are not addresses: ${bad.join(", ")}`);
    else if (entries.length === 0) problems.push("INDEXES is set but names no index");
    else config.indexes = [...new Set(entries.map((s) => s.toLowerCase()))];
  }

  // The coins the keeper can value: the chain's own, and PRICE_IDS, `token=id` pairs, for a deployment whose coins
  // the catalogue does not hold (a testnet's) or to change one's feed.
  const priceIds = { ...(config.chain?.priceIds ?? {}) };
  for (const pair of (get("PRICE_IDS") ?? "").split(",").map((s) => s.trim()).filter(Boolean)) {
    const [token, id, ...rest] = pair.split("=").map((s) => s.trim());
    if (rest.length || !ADDRESS.test(token ?? "") || !ID.test(id ?? "")) problems.push(`PRICE_IDS has an entry that is not token=id: ${pair}`);
    else priceIds[token.toLowerCase()] = id.toLowerCase();
  }
  config.priceIds = Object.freeze(priceIds);

  if (problems.length) throw new Error(`keeper configuration:\n  ${problems.join("\n  ")}`);
  return Object.freeze(config);
}
