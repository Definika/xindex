// Xindex v5 rebalancer bot. DRAFT, untested (2026-10-06).
//
// Each pass, for every index of the factory:
//   1. starts a rebalance when anyone may (canStartRebalance);
//   2. during an auction, previews the fill at Pyth's latest prices and fills it through KeeperExecutor when the
//      expected profit, after gas and swap costs, reaches MIN_PROFIT_USD, or the loss stays within MAX_SUBSIDY_USD
//      (for small indexes nobody else would fill).
// Run one per deployment: on Ethereum and on BNB Chain, each with its own RPC_URL, FACTORY and EXECUTOR.
//
// Env:
//   RPC_URL            Ethereum JSON-RPC.
//   KEEPER_KEY         The bot's own key: a dedicated, low-balance hot key. It holds no role in the protocol; anyone can
//                      start and fill. Never the factory owner's or the guardian's.
//   FACTORY            The v5 factory.
//   EXECUTOR           The bot's KeeperExecutor, funded with a small USDC float and with a route for every coin.
//   PYTH_API_KEY       Pyth's Hermes key (Hermes refuses requests without one since 2026-08-26).
//   HERMES_URL         Optional, default https://hermes.pyth.network.
//   MIN_PROFIT_USD     Optional, default 5.
//   MAX_SUBSIDY_USD    Optional, default 0: how much the bot may lose on one fill to keep a small index on its weights.
//   SWAP_COST_BPS      Optional, default 30: Uniswap fees and slippage assumed on the traded value.
//   POLL_SECONDS       Optional, default 300.
//   ETH_PRICE_ID       Optional, Pyth's ETH/USD id, to value gas.

import { createPublicClient, createWalletClient, http, parseAbi, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const env = (name, fallback) => {
  const value = process.env[name] ?? fallback;
  if (value === undefined) throw new Error(`${name} is required`);
  return value;
};

const RPC_URL = env("RPC_URL");
const FACTORY = env("FACTORY");
const EXECUTOR = env("EXECUTOR");
const PYTH_API_KEY = env("PYTH_API_KEY");
const HERMES_URL = env("HERMES_URL", "https://hermes.pyth.network");
const MIN_PROFIT_USD = Number(env("MIN_PROFIT_USD", "5"));
const MAX_SUBSIDY_USD = Number(env("MAX_SUBSIDY_USD", "0"));
const SWAP_COST_BPS = Number(env("SWAP_COST_BPS", "30"));
const POLL_SECONDS = Number(env("POLL_SECONDS", "300"));
const ETH_PRICE_ID = env("ETH_PRICE_ID", "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace");
const PRICE_LAG = 12n; // WeightedHub.PRICE_LAG: the hub reads the first update at or after one slot before its block
const SLOT = 12n;

const factoryAbi = parseAbi([
  "function allIndexesLength() view returns (uint256)",
  "function allIndexes(uint256) view returns (address)",
  "function PYTH() view returns (address)",
  "function indexSalt(address) view returns (bytes32)",
]);
const hubAbi = parseAbi([
  "function canStartRebalance() view returns (bool)",
  "function startRebalance(uint256 keepMask)",
  "function pendingRebalance() view returns (uint256 eta, uint256 keepMask)",
  "function AUCTION_DURATION() view returns (uint256)",
  "function components() view returns (address[] tokens, uint256[] units)",
  "function componentTerms() view returns (uint256[] weights, bytes32[] priceIds, uint8[] decimals)",
  "function totalSupply() view returns (uint256)",
  "struct Price { int64 price; uint64 conf; int32 expo; uint256 publishTime; }",
  "function previewRebalance(Price[] prices) view returns (uint256 mu, uint256[] units, uint256[] amountsOut, uint256[] amountsIn)",
]);
const pythAbi = parseAbi(["function getUpdateFee(bytes[] updateData) view returns (uint256)"]);
const executorAbi = parseAbi(["function fill(address index, bytes[] priceUpdate, uint256 maxCost) payable"]);

const account = privateKeyToAccount(env("KEEPER_KEY"));
const chain = { id: 0, name: "xindex", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: {} };
const publicClient = createPublicClient({ transport: http(RPC_URL) });
const chainId = await publicClient.getChainId();
chain.id = chainId;
const wallet = createWalletClient({ account, chain, transport: http(RPC_URL) });

const log = (...args) => console.log(new Date().toISOString(), ...args);

// ---------------------------------------------------------------------
// Hermes
// ---------------------------------------------------------------------

async function hermes(path) {
  const response = await fetch(`${HERMES_URL}${path}`, { headers: { Authorization: `Bearer ${PYTH_API_KEY}` } });
  if (!response.ok) throw new Error(`Hermes ${response.status} on ${path}: ${await response.text()}`);
  return response.json();
}

const idsQuery = (ids) => ids.map((id) => `ids[]=${id}`).join("&");

/// Latest parsed prices, by id without 0x.
async function latestPrices(ids) {
  const body = await hermes(`/v2/updates/price/latest?${idsQuery(ids)}&parsed=true`);
  const byId = new Map();
  for (const p of body.parsed) byId.set(p.id.replace(/^0x/, ""), p.price);
  return byId;
}

/// The signed update of `ids` at `publishTime`: each feed's first update at or after it.
async function updateAt(ids, publishTime) {
  const body = await hermes(`/v2/updates/price/${publishTime}?${idsQuery(ids)}&encoding=hex`);
  return body.binary.data.map((hex) => (hex.startsWith("0x") ? hex : `0x${hex}`));
}

// ---------------------------------------------------------------------
// One index
// ---------------------------------------------------------------------

async function tryStart(index) {
  const canStart = await publicClient.readContract({ address: index, abi: hubAbi, functionName: "canStartRebalance" });
  if (!canStart) return false;
  const hash = await wallet.writeContract({ address: index, abi: hubAbi, functionName: "startRebalance", args: [0n] });
  log("started", index, hash);
  await publicClient.waitForTransactionReceipt({ hash });
  return true;
}

/// USD value of `amounts[i]` raw units at `prices[i]` (Pyth price objects), as a float.
function usd(amounts, prices, decimals) {
  let total = 0;
  amounts.forEach((amount, i) => {
    if (amount === 0n || !prices[i]) return;
    const units = Number(formatUnits(amount, decimals[i]));
    total += units * Number(prices[i].price) * 10 ** Number(prices[i].expo);
  });
  return total;
}

async function tryFill(index) {
  const [eta, keepMask] = await publicClient.readContract({ address: index, abi: hubAbi, functionName: "pendingRebalance" });
  if (eta === 0n) return;
  const duration = await publicClient.readContract({ address: index, abi: hubAbi, functionName: "AUCTION_DURATION" });
  const block = await publicClient.getBlock();
  if (block.timestamp < eta || block.timestamp > eta + duration) return;

  const [, priceIds, decimals] = await publicClient.readContract({ address: index, abi: hubAbi, functionName: "componentTerms" });
  const moving = priceIds.filter((_, i) => ((keepMask >> BigInt(i)) & 1n) === 0n);
  const latest = await latestPrices([...new Set([...moving, ETH_PRICE_ID])]);
  const prices = priceIds.map((id, i) => {
    if (((keepMask >> BigInt(i)) & 1n) === 1n) return { price: 0n, conf: 0n, expo: 0, publishTime: 0n };
    const p = latest.get(id.replace(/^0x/, ""));
    if (!p) throw new Error(`no Hermes price for ${id}`);
    return { price: BigInt(p.price), conf: BigInt(p.conf), expo: Number(p.expo), publishTime: BigInt(p.publish_time) };
  });

  let preview;
  try {
    preview = await publicClient.readContract({ address: index, abi: hubAbi, functionName: "previewRebalance", args: [prices] });
  } catch (error) {
    log("no fill for", index, error.shortMessage ?? error.message); // NothingToRebalance, a refused price, ...
    return;
  }
  const [mu, , amountsOut, amountsIn] = preview;
  const valueOut = usd(amountsOut, prices, decimals);
  const valueIn = usd(amountsIn, prices, decimals);
  const swapCost = (valueOut + valueIn) * (SWAP_COST_BPS / 10_000);
  const gasPrice = await publicClient.getGasPrice();
  const eth = latest.get(ETH_PRICE_ID.replace(/^0x/, ""));
  const ethUsd = Number(eth.price) * 10 ** Number(eth.expo);
  const gasUsd = Number(formatUnits(gasPrice * 3_000_000n * BigInt(priceIds.length), 18)) * ethUsd / 4; // rough
  const profit = valueOut - valueIn - swapCost - gasUsd;
  log(index, `mu ${formatUnits(mu, 18)}`, `out $${valueOut.toFixed(2)}`, `in $${valueIn.toFixed(2)}`, `profit $${profit.toFixed(2)}`);
  if (profit < MIN_PROFIT_USD && -profit > MAX_SUBSIDY_USD) return;

  // The hub prices one slot before its block: aim at the next block.
  const next = block.timestamp + SLOT;
  const updates = await updateAt(moving, Number(next - PRICE_LAG));
  const pyth = await publicClient.readContract({ address: FACTORY, abi: factoryAbi, functionName: "PYTH" });
  const fee = await publicClient.readContract({ address: pyth, abi: pythAbi, functionName: "getUpdateFee", args: [updates] });
  // Allow the subsidy, or nothing beyond the swap costs, in USDC (6 decimals).
  const maxCost = BigInt(Math.max(0, Math.ceil((MAX_SUBSIDY_USD + swapCost) * 1e6)));
  try {
    const hash = await wallet.writeContract({
      address: EXECUTOR,
      abi: executorAbi,
      functionName: "fill",
      args: [index, updates, maxCost],
      value: fee,
    });
    log("filled", index, hash);
    await publicClient.waitForTransactionReceipt({ hash });
  } catch (error) {
    // Most often the block came a slot later than aimed, so the update was not the first of its second: next pass.
    log("fill failed", index, error.shortMessage ?? error.message);
  }
}

async function pass() {
  const count = await publicClient.readContract({ address: FACTORY, abi: factoryAbi, functionName: "allIndexesLength" });
  for (let i = 0n; i < count; i++) {
    const index = await publicClient.readContract({ address: FACTORY, abi: factoryAbi, functionName: "allIndexes", args: [i] });
    try {
      await tryStart(index);
      await tryFill(index);
    } catch (error) {
      log("error on", index, error.shortMessage ?? error.message);
    }
  }
}

log("keeper", account.address, "factory", FACTORY, "executor", EXECUTOR, "chain", chainId);
do {
  await pass();
  if (process.argv.includes("--once")) break;
  await new Promise((resolve) => setTimeout(resolve, POLL_SECONDS * 1000));
} while (true);
