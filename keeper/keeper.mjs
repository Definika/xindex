#!/usr/bin/env node
// Xindex keeper: starts and fills `WeightedHub` auctions through its own `KeeperExecutor`. It holds no role in the
// protocol (starting and filling are open to anyone); its key is a dedicated hot key that can only fill. See README.md.
//
// No contract reads a price (since 2026-11-10): a fill names the units the index settles at, and the index accepts them
// when a weighted gain in units clears the auction's bar, which falls with time. The keeper prices its own trades, off
// chain, at Pyth's prices from Hermes, each confirmed by Pyth's contract before anything is valued at it.
//
// Every block L, with T = L's timestamp + 12, the one block a fill sent now can land in:
//   1. for each open auction the bot names, at its prices, the units that clear the bar at T while leaving the index
//      the least (bot/units.mjs), and simulates its executor's fill of them exactly as block L+1 would run it (eth_call
//      with block overrides), with the routes quoted for each leg and the executor's stock;
//   2. the most profitable fill whose profit, after gas and valued stock, reaches MIN_PROFIT_USD is sent with a USDC
//      floor at least what that decision needs, a supply bound, and a deadline of T; an auction whose fills revert
//      on chain is backed off, and left after MAX_REVERTED_FILLS. The bar falls, so a fill that does not pay yet pays
//      later if the index is far enough from its weights, and the first keeper it pays fills it;
//   3. every 25 blocks, an index anyone may restart is started only when a simulation of its auction at its last
//      second, where the bar is lowest, would pay;
//   4. with FILL_REQUESTS on and nothing else to send, each open `MintRequests` request is simulated the same way and
//      the most profitable fill sent: a mint request at exactly its limit in shares, a redeem request at exactly its
//      limit in its stablecoin.

import { renameSync, writeFileSync } from "node:fs";
import { encodeFunctionData, getAddress } from "viem";
import { FRESH_SECONDS, HUB_SLOTS, MAX_CONF_BPS, NO_QUOTE_PROPOSAL, SHARE_PRICED_IDS, TX_GAS_CAP, parseConfig } from "./bot/config.mjs";
import { MAX_REVERTED_FILLS, MAX_REVERTED_REQUEST_FILLS, revertedFills } from "./bot/backoff.mjs";
import { ABI, createChain, revertReason } from "./bot/chain.mjs";
import { createHermes, priceKey } from "./bot/hermes.mjs";
import * as M from "./bot/math.mjs";
import { createNeeds } from "./bot/needs.mjs";
import { TxTracker } from "./bot/nonce.mjs";
import { createRequestFiller } from "./bot/requests.mjs";
import { createRoutes, marketOf } from "./bot/routes.mjs";
import * as U from "./bot/units.mjs";

const START_EVERY_BLOCKS = 25n;
const START_COOLDOWN = 86_400n; // a start of ours that nobody filled is not repeated for a day
const NOT_ASKED = " (not asked of the restock: at its best price it cannot pay MIN_PROFIT_USD, RY-8)";
const HERMES_MS = 5_000;
const MAX_FILL_CHECKS = 8; // open auctions simulated per block, richest first (CF-7)
const MAX_START_CHECKS = 4; // ready indexes whose start is simulated per round, richest first (RX-34)
const DAY = 86_400n;
const INT256_MIN = -(2n ** 255n);
const ONCE = process.argv.includes("--once");

const log = (...args) => console.log(new Date().toISOString(), ...args);
const cfg = parseConfig(process.env);
const chain = createChain(cfg);
const hermes = createHermes({ url: cfg.hermesUrl, apiKey: cfg.pythApiKey });
const routes = createRoutes(chain, cfg, ABI, marketOf(cfg.chain));
const tip = M.gweiToWei(cfg.priorityFeeGwei);
const feeCap = M.gweiToWei(cfg.maxFeeGwei);
const tracker = new TxTracker(chain.txIo, log, { feeCap });
const reverted = revertedFills(); // `index:proposal` -> fills that reverted on chain (XS-4)
// The coins fills are short of, for the restock service, written whole to a temporary file and renamed into place.
const needs = cfg.needsFile
  ? createNeeds({
      write: (text) => {
        writeFileSync(`${cfg.needsFile}.tmp`, text);
        renameSync(`${cfg.needsFile}.tmp`, cfg.needsFile);
      },
    })
  : createNeeds({ write: () => {} });
const isUsdc = (token) => token.toLowerCase() === cfg.chain.usdc.toLowerCase();
const sharePriced = (id) => SHARE_PRICED_IDS.includes(id.toLowerCase());
const kept = (keepMask, i) => ((keepMask >> BigInt(i)) & 1n) === 1n;
const tokensOf = (short) => short.map((s) => s.token).join(", ");
let subsidies = []; // {at, usd}: fills sent below zero profit, for SUBSIDY_BUDGET_USD's rolling day (RX-16)
let startKeys = []; // route keys of the last start round, kept until the next (RX-34)

const statics = new Map(); // index -> {tokens, ids, decimals, weights}: `ids` null where the keeper has no price id
const started = new Map(); // index -> timestamp of a start of ours not yet filled
const said = new Map(); // index -> the last reason logged, so a waiting index is not logged every block
const worth = new Map(); // `index:proposal` -> {supply, tvl, block}: an open auction's index, valued every 25 blocks
let setup;
let filler = null;
let indexes = [];
let lastRefresh = null;
let lastStartCheck = null;
let lastRequestScan = null;
let ethUsd = null;
let stopping = false;

function say(index, reason) {
  if (said.get(index) === reason) return;
  said.set(index, reason);
  log(index, reason);
}

/// What never changes about `index`: its tokens, each one's decimals, read from the token, and the Pyth id the keeper
/// values it at, null for a coin outside its catalogue, which it leaves alone.
async function staticsOf(index, blockNumber) {
  if (!statics.has(index)) {
    const tokens = await chain.read(index, ABI.hub, "componentTokens", [], blockNumber);
    const decimals = await chain.multicall(
      tokens.map((t) => ({ address: t, abi: ABI.erc20, functionName: "decimals" })),
      blockNumber,
    );
    if (decimals.some((r) => r.status !== "success")) throw new Error("a decimals read failed");
    const ids = tokens.map((t) => cfg.priceIds[t.toLowerCase()] ?? null);
    statics.set(index, { tokens, ids, decimals: decimals.map((r) => Number(r.result)), weights: null });
  }
  return statics.get(index);
}

/// The weights of `index`, fixed at its creation, in basis points.
async function weightsOf(index, st, blockNumber) {
  if (st.weights === null) st.weights = await chain.read(index, ABI.hub, "componentWeights", [], blockNumber);
  return st.weights;
}

/// The Hermes prices of `ids`, with none for a coin without an id.
const pricesFrom = (latest, ids) => ids.map((id) => (id ? latest.get(priceKey(id)) : undefined));

async function refresh(L) {
  if (cfg.indexes) indexes = cfg.indexes.map((a) => getAddress(a));
  else {
    const n = await chain.read(cfg.factory, ABI.factory, "allIndexesLength", [], L.number);
    const found = await chain.multicall(
      Array.from({ length: Number(n) }, (_, i) => ({
        address: cfg.factory,
        abi: ABI.factory,
        functionName: "allIndexes",
        args: [BigInt(i)],
      })),
      L.number,
    );
    indexes = found.filter((r) => r.status === "success").map((r) => r.result);
  }
  // ETH's price values every fill's gas: Pyth's, confirmed by its contract, and fresh, or none, which fills nothing
  // until the next refresh finds one (RY-7).
  const eth = await hermes.trusted([cfg.chain.ethPriceId], Date.now() + HERMES_MS, pythChain(L));
  const p = eth.get(priceKey(cfg.chain.ethPriceId));
  ethUsd = M.freshPrice(p, L.timestamp, FRESH_SECONDS, MAX_CONF_BPS) ? M.priceUsd(p) : null;
  lastRefresh = L.number;
}

/// Pyth's contract on Ethereum as of block L, for {hermes.verified} and {hermes.trusted}.
const pythChain = (L) => ({ read: chain.read, call: chain.call, pyth: setup.pyth, abi: ABI.pyth, blockNumber: L.number });

/// The keeper's price of each leg of `st` it may move, as Pyth's {price, expo}, and null for the rest: a kept leg, a
/// coin without an id, a share-priced Ondo leg, which the bot cannot value (RX-2), and a price that is not Hermes'
/// signed one as Pyth's contract parses it, or is stale or wide (RX-1, RX-9, RY-7).
async function pricesOf(st, L, keepMask) {
  const wanted = st.ids.map((id, i) => (id && !sharePriced(id) && !kept(keepMask, i) ? id : null));
  const ids = wanted.filter(Boolean);
  const trusted = ids.length ? await hermes.trusted(ids, Date.now() + HERMES_MS, pythChain(L)) : new Map();
  return wanted.map((id) => {
    const p = id ? trusted.get(priceKey(id)) : null;
    return p && M.freshPrice(p, L.timestamp, FRESH_SECONDS, MAX_CONF_BPS) ? p : null;
  });
}

/// The fill of `index` the keeper would send for block L+1: the units it names at its own prices to clear the bar
/// then, and the settlement the hub previews for them. `eta`, when given, is written into the hub for the call, to see
/// an auction that is not open yet. `maxSupply` is the most shares the fill accepts: the supply now, plus the streaming
/// fee an accrual would mint by T, which leaves the settlement unchanged, plus SUPPLY_TOLERANCE_BPS (XS-4).
async function preview(index, st, L, keepMask, eta) {
  const T = L.timestamp + 12n;
  const over = { block: { number: L.number + 1n, time: T } };
  // A start of the keeper's posts no quote: the simulated auction is bound to no proposal's, an earlier one's or,
  // on an index never started, the empty one zero would name.
  if (eta !== undefined) {
    over.state = { [index]: { [HUB_SLOTS.eta]: eta, [HUB_SLOTS.keepMask]: keepMask, [HUB_SLOTS.quoteProposal]: NO_QUOTE_PROPOSAL } };
  }
  // The quote the owner or guardian posted with this proposal, if any: prices of theirs that a fill must also hold.
  const [quotePrices, quoteTolerance] = await chain.call({ to: index, abi: ABI.hub, functionName: "rebalanceQuote", args: [] }, L.number, over);
  const quote = quotePrices.length ? { prices: quotePrices, tolerance: quoteTolerance } : null;
  const [units, weights, bar, prices] = await Promise.all([
    chain.read(index, ABI.hub, "recordedUnits", [], L.number),
    weightsOf(index, st, L.number),
    chain.call({ to: index, abi: ABI.hub, functionName: "currentBar", args: [] }, L.number, over),
    pricesOf(st, L, keepMask),
  ]);
  if (bar === 0n) throw new Error("no auction is open at the next block");
  // Dollars per raw unit: only their ratios decide the units named.
  const perUnit = prices.map((p, i) => (p ? M.priceUsd(p) / 10 ** st.decimals[i] : null));
  const named = U.nameUnits({ units, weights, keepMask, prices: perUnit, bar, costBps: cfg.tradeCostBps, quote });
  if (!named) throw new Error(quote ? "no units the keeper can price clear the bar and hold the quote" : "no units the keeper can price clear the bar");
  const at = { to: index, abi: ABI.hub, functionName: "previewRebalance", args: [named.newUnits] };
  const [, gain, out, need] = await chain.call(at, L.number, over);
  const moving = out.map((_, i) => i).filter((i) => out[i] > 0n || need[i] > 0n);
  const supply = await chain.read(index, ABI.hub, "totalSupply", [], L.number);
  const [feeShares] = await chain.call({ to: index, abi: ABI.hub, functionName: "pendingStreamingFee", args: [] }, L.number, over);
  const maxSupply = M.withTolerance(supply + feeShares, cfg.supplyToleranceBps);
  return { T, moving, newUnits: named.newUnits, bar, gain, priceOf: (i) => prices[i], over, out, in: need, maxSupply };
}

/// The routes, stock change and routed volume of a settlement, or `short` naming coins the executor can neither buy
/// nor deliver from stock, each with the whole of it the fill may need. `maxIn` is the most of each coin the fill may
/// be asked for.
async function legs(index, st, sim, maxIn, L, key) {
  const held = await chain.multicall(
    st.tokens.map((t) => ({ address: t, abi: ABI.erc20, functionName: "balanceOf", args: [cfg.executor] })),
    L.number,
  );
  // The executor delivers from stock only within the owner's allowance, so stock beyond it is bought like a shortfall.
  const allowed = await chain.multicall(
    st.tokens.map((t) => ({ address: cfg.executor, abi: ABI.executor, functionName: "stockAllowance", args: [t] })),
    L.number,
  );
  // A stock read that failed is not an empty stock: valued as one, the fill would deliver stock it never counted
  // and overstate its profit by that stock's value. The check is made again next block (RY-9).
  if ([...held, ...allowed].some((r) => r.status !== "success")) throw new Error("a stock read failed");
  const routeOf = st.tokens.map(() => "0x");
  const short = [];
  const stocked = []; // every leg stock serves, for the restock's board (RZ-3)
  let inventoryUsd = 0;
  let routedUsd = 0;
  // Every moving leg has a price: the bot names new units only for the legs it can value.
  for (const i of sim.moving) {
    const token = st.tokens[i];
    const out = sim.out[i];
    const need = sim.in[i];
    if ((out === 0n && need === 0n) || isUsdc(token)) continue; // a USDC leg is the float itself
    const h = M.min(held[i].result, allowed[i].result);
    const p = sim.priceOf(i);
    const dec = st.decimals[i];
    let route = null;
    if (out > 0n) {
      route = await routes.best({ key, token, side: "sell", amount: out, fairUsd: M.amountUsd(out, dec, p), blockNumber: L.number });
      if (route) routedUsd += M.amountUsd(out, dec, p);
    } else {
      if (maxIn[i] > h) {
        const shortfall = maxIn[i] - h;
        route = await routes.best({ key, token, side: "buy", amount: shortfall, fairUsd: M.amountUsd(shortfall, dec, p), blockNumber: L.number });
        if (route) routedUsd += M.amountUsd(M.max(need - h, 0n), dec, p);
      }
      if (!route) {
        // Stock serves this leg: the board carries all of it, whether stock covers it yet or not, so the need stays
        // while the fill waits for its price, rather than leaving the moment the restock's coins land (RZ-3).
        stocked.push({ token, amount: maxIn[i] });
        if (maxIn[i] > h) {
          short.push({ token, amount: maxIn[i] });
          continue;
        }
      }
    }
    if (route) routeOf[i] = route;
    // A kept coin counts at no more than its best quote (XS-5).
    const quoteUsdc = out > 0n ? routes.quoteOf({ key, token, side: "sell", amount: out }) : null;
    inventoryUsd += M.stockChangeUsd({ out, in: need, held: h, routed: route !== null, decimals: dec, price: p, quoteUsdc });
  }
  return { routes: routeOf, inventoryUsd, routedVolumeUsdc: M.usdToUsdcCeil(routedUsd), short, stocked };
}

/// Simulates the executor's fill of `sim` and prices it: profit after gas, and the transaction that would send it.
async function priceFill(index, sim, leg, maxIn, L) {
  if (ethUsd === null) return { skip: "no ETH price to value gas" };
  const args = [index, sim.newUnits, leg.routes, maxIn, sim.maxSupply, INT256_MIN, sim.T];
  let usdcDelta;
  let inner;
  try {
    [usdcDelta, inner] = await chain.call(
      { to: cfg.executor, abi: ABI.executor, functionName: "fill", args },
      L.number,
      sim.over,
    );
  } catch (error) {
    return { skip: `fill would revert: ${revertReason(error)}` };
  }
  const used = M.txGasUsed(inner, encodeFunctionData({ abi: ABI.executor, functionName: "fill", args }));
  if (used > TX_GAS_CAP) return { skip: `fill needs ${used} gas, above EIP-7825's cap` };
  const gas = M.min(M.gasLimitFor(used), TX_GAS_CAP);
  const nextBase = M.nextBaseFee(L);
  if (nextBase + tip > feeCap) return { skip: `base fee ${M.weiToGwei(nextBase)} gwei above MAX_FEE_GWEI` };
  const gasUsd = M.fillCostUsd({ used, nextBase, tip, ethUsd });
  const profit = M.profitUsd({ usdcDelta, inventoryUsd: leg.inventoryUsd, gasUsd });
  const floor = M.usdcFloor({
    simDelta: usdcDelta,
    minProfitUsd: cfg.minProfitUsd,
    gasUsd,
    inventoryUsd: leg.inventoryUsd,
    routedVolumeUsdc: leg.routedVolumeUsdc,
    slippageBps: cfg.slippageBps,
  });
  const data = encodeFunctionData({
    abi: ABI.executor,
    functionName: "fill",
    args: [index, sim.newUnits, leg.routes, maxIn, sim.maxSupply, floor, sim.T],
  });
  const tx = {
    to: cfg.executor,
    data,
    value: 0n,
    gas,
    maxFeePerGas: M.min(2n * nextBase + tip, feeCap),
    maxPriorityFeePerGas: tip,
  };
  return { profit, usdcDelta, gasUsd, inventoryUsd: leg.inventoryUsd, tx, over: sim.over };
}

/// Whether `tx` runs within its own gas limit: the call again, with that limit, at L, as block L+1. A fill that fits
/// only the node's default limit, or whose 1/64 reserve at the hub runs out, is not sent (RX-21, RX-36).
async function fitsItsGas(tx, L, over) {
  try {
    await chain.client.request({
      method: "eth_call",
      params: [
        { from: chain.account.address, to: tx.to, data: tx.data, value: `0x${tx.value.toString(16)}`, gas: `0x${tx.gas.toString(16)}` },
        `0x${L.number.toString(16)}`,
        {},
        { number: `0x${over.block.number.toString(16)}`, time: `0x${over.block.time.toString(16)}` },
      ],
    });
    return true;
  } catch {
    return false;
  }
}

/// Whether a fill below zero profit, a subsidy only a negative MIN_PROFIT_USD allows, still fits SUBSIDY_BUDGET_USD
/// over the last day at second `t` (RX-16).
function subsidyFits(profit, t) {
  const { ok, window } = M.subsidyFits(subsidies, profit, t, cfg.subsidyBudgetUsd, DAY);
  subsidies = window;
  return ok;
}

/// The open auctions to simulate this block (CF-7): each index's supply and worth, read once per auction and again
/// every 25 blocks with one multicall and one Hermes request for all of them, then M.auctionsToEvaluate. An auction
/// on an empty or small index costs no Hermes request and no simulation per block. A coin the keeper has no price for
/// counts as nothing.
async function worthChecking(open, L) {
  const keyOf = (index) => `${index}:${open.get(index).proposal}`;
  // An auction backed off after fills reverted on chain gives up its check slot (RX-24).
  open = new Map(
    [...open].filter(([index]) => {
      const key = keyOf(index);
      if (!reverted.blocked(key, L.number)) return true;
      say(index, `no fill check: ${reverted.failures(key)} fills of this auction reverted on chain`);
      return false;
    }),
  );
  const openKeys = new Set([...open.keys()].map(keyOf));
  for (const key of worth.keys()) if (!openKeys.has(key)) worth.delete(key);
  const stale = [...open.keys()].filter((index) => {
    const w = worth.get(keyOf(index));
    return !w || L.number - w.block >= START_EVERY_BLOCKS;
  });
  if (stale.length) {
    const reads = await chain.multicall(
      stale.flatMap((address) => [
        { address, abi: ABI.hub, functionName: "totalSupply" },
        { address, abi: ABI.hub, functionName: "components" },
      ]),
      L.number,
    );
    const live = [];
    stale.forEach((index, k) => {
      const [supply, comps] = [reads[2 * k], reads[2 * k + 1]];
      const ok = supply.status === "success" && comps.status === "success" && supply.result > 0n;
      if (ok) live.push({ index, supply: supply.result, units: comps.result[1] });
      else worth.set(keyOf(index), { supply: 0n, tvl: 0, block: L.number });
    });
    if (live.length) {
      const ids = new Set();
      for (const r of live) for (const id of (await staticsOf(r.index, L.number)).ids) if (id) ids.add(id);
      const latest = ids.size ? await hermes.latest([...ids], Date.now() + HERMES_MS) : new Map();
      for (const r of live) {
        const st = statics.get(r.index);
        const prices = pricesFrom(latest, st.ids);
        worth.set(keyOf(r.index), { supply: r.supply, tvl: M.tvlUsd({ supply: r.supply, units: r.units, decimals: st.decimals, prices }), block: L.number });
      }
    }
  }
  const candidates = [...open.keys()].map((index) => ({ index, ...worth.get(keyOf(index)) }));
  const chosen = M.auctionsToEvaluate(candidates, cfg.minTvlUsd, MAX_FILL_CHECKS);
  for (const c of candidates) {
    if (!chosen.includes(c)) say(c.index, `no fill check: worth ${c.tvl.toFixed(0)} USD, below MIN_TVL_USD or past the ${MAX_FILL_CHECKS} richest`);
  }
  return chosen;
}

/// An open auction of `index`, as a fill this bot could send now.
async function evaluateFill(index, keepMask, proposal, L) {
  const st = await staticsOf(index, L.number);
  let sim;
  try {
    sim = await preview(index, st, L, keepMask);
  } catch (error) {
    return say(index, `no fill: ${revertReason(error)}`);
  }
  const maxIn = sim.in.map((x) => M.withTolerance(x, cfg.supplyToleranceBps));
  const leg = await legs(index, st, sim, maxIn, L, `${index}:${proposal}`);
  const pays = await mayPay(index, st, L, keepMask, leg.stocked, sim);
  needs.report(`${index}:${proposal}`, "fill", pays ? leg.stocked : []);
  if (leg.short.length) return say(index, `restock${pays ? "" : NOT_ASKED}: no route and too little stock of ${tokensOf(leg.short)}`);
  const priced = await priceFill(index, sim, leg, maxIn, L);
  if (priced.skip) {
    routes.forgetKey(`${index}:${proposal}`); // a simulation that reverts searches its routes again (RX-13)
    return say(index, priced.skip);
  }
  const bar = Number(sim.bar) / 1e18;
  if (priced.profit < cfg.minProfitUsd) return say(index, `waiting: profit below ${cfg.minProfitUsd} USD at a bar of ${bar.toFixed(6)}`);
  return { index, proposal, bar, ...priced };
}

/// Whether to start `index`: its auction, simulated at its last second, where the bar is lowest, must pay.
async function evaluateStart(index, proposal, L) {
  const st = await staticsOf(index, L.number);
  const T = L.timestamp + 12n;
  let best;
  try {
    best = await preview(index, st, L, 0n, T - setup.duration);
  } catch (error) {
    return say(index, `not starting: ${revertReason(error)}`);
  }
  const maxIn = best.in.map((x) => M.withTolerance(x, cfg.supplyToleranceBps));
  const leg = await legs(index, st, best, maxIn, L, `${index}:${proposal + 1n}`);
  const pays = await mayPay(index, st, L, 0n, leg.stocked, best, best);
  needs.report(`${index}:${proposal + 1n}`, "start", pays ? leg.stocked : []);
  if (leg.short.length) return say(index, `not starting: restock${pays ? "" : NOT_ASKED} ${tokensOf(leg.short)}`);
  const priced = await priceFill(index, best, leg, maxIn, L);
  if (priced.skip) return say(index, `not starting: ${priced.skip}`);
  // The start is this bot's own transaction: its gas, at the limit it is sent with, comes off what the fill it opens
  // would pay (RZ-14).
  const startUsd = M.fillCostUsd({ used: M.START_GAS_LIMIT, nextBase: M.nextBaseFee(L), tip, ethUsd });
  const profit = priced.profit - startUsd;
  if (profit < cfg.minProfitUsd) {
    return say(index, `not starting: best case pays ${profit.toFixed(2)} USD after the start's ${startUsd.toFixed(2)}`);
  }
  return { index, profit, T: best.T };
}

/// Whether the auction of `index` could pay MIN_PROFIT_USD at its last second, where the bar is lowest, so that the
/// stock its fill would deliver is worth bringing in (RY-8): M.settlementMarginUsd of the settlement then, at the
/// keeper's prices.
/// `best` is that settlement when already simulated; otherwise it is, with `sim`, the settlement now, as the fallback
/// should the best case not simulate. Nothing is asked when stock serves no leg.
async function mayPay(index, st, L, keepMask, stocked, sim, best) {
  if (stocked.length === 0) return false;
  const atBest = best ?? (await preview(index, st, L, keepMask, L.timestamp + 12n - setup.duration).catch(() => sim));
  const prices = st.ids.map((_, i) => atBest.priceOf(i));
  return M.settlementMarginUsd({ out: atBest.out, need: atBest.in, decimals: st.decimals, prices }) >= cfg.minProfitUsd;
}

async function startChecks(L, open) {
  const candidates = indexes.filter((i) => !open.has(i));
  if (candidates.length === 0) return;
  const reads = await chain.multicall(
    candidates.flatMap((address) => [
      { address, abi: ABI.hub, functionName: "canStartRebalance" },
      { address, abi: ABI.hub, functionName: "totalSupply" },
      { address, abi: ABI.hub, functionName: "components" },
      { address, abi: ABI.hub, functionName: "proposalCount" },
    ]),
    L.number,
  );
  const ready = [];
  for (let k = 0; k < candidates.length; k++) {
    const four = reads.slice(4 * k, 4 * k + 4);
    if (four.some((r) => r.status !== "success")) continue;
    const [can, supply, comps, proposal] = four;
    if (!can.result || supply.result === 0n) continue;
    const since = started.get(candidates[k]);
    if (since !== undefined && L.timestamp - since < START_COOLDOWN) continue;
    ready.push({ index: candidates[k], supply: supply.result, units: comps.result[1], proposal: proposal.result });
  }
  if (ready.length === 0) return;

  const ids = new Set();
  for (const r of ready) for (const id of (await staticsOf(r.index, L.number)).ids) if (id) ids.add(id);
  const latest = ids.size ? await hermes.latest([...ids], Date.now() + HERMES_MS) : new Map();
  const worthy = [];
  for (const r of ready) {
    const st = statics.get(r.index);
    const tvl = M.tvlUsd({ supply: r.supply, units: r.units, decimals: st.decimals, prices: pricesFrom(latest, st.ids) });
    if (tvl < cfg.minTvlUsd) {
      say(r.index, `not starting: worth ${tvl.toFixed(0)} USD, below MIN_TVL_USD`);
      continue;
    }
    worthy.push({ ...r, tvl });
  }
  // The richest few, simulated side by side, their routes kept until the next round, so the start checks cannot hold
  // the main loop for blocks every 25 (RX-34).
  const { chosen, rest } = M.startsToCheck(worthy, MAX_START_CHECKS);
  for (const r of rest) say(r.index, `not starting this round: past the ${MAX_START_CHECKS} richest ready indexes`);
  startKeys = chosen.map((r) => `${r.index}:${r.proposal + 1n}`);
  const verdicts = await Promise.all(
    chosen.map((r) => evaluateStart(r.index, r.proposal, L).catch((error) => say(r.index, `start check failed: ${revertReason(error)}`))),
  );
  const go = verdicts.filter(Boolean).sort((a, b) => b.profit - a.profit)[0];
  if (!go) return;
  // A start is a plain call: it reads no feed and takes no ether. It is checked at block L+1 with the limit it is sent
  // with.
  const data = encodeFunctionData({ abi: ABI.hub, functionName: "startRebalance", args: [0n] });
  const nextBase = M.nextBaseFee(L);
  if (nextBase + tip > feeCap) return;
  const tx = {
    to: go.index,
    data,
    value: 0n,
    gas: M.START_GAS_LIMIT,
    maxFeePerGas: M.min(2n * nextBase + tip, feeCap),
    maxPriorityFeePerGas: tip,
  };
  if (!(await fitsItsGas(tx, L, { block: { number: L.number + 1n, time: go.T } }))) {
    say(go.index, "not starting: the start would not run within its gas limit in the next block");
    return;
  }
  // The start was priced for block L+1: once the head has moved on, the checks run again at the next block rather
  // than START_EVERY_BLOCKS later.
  if ((await chain.blockNumber()) !== L.number) {
    lastStartCheck = null;
    return log(go.index, "block passed before sending; next block");
  }
  log(go.index, `starting: best case pays ${go.profit.toFixed(2)} USD`);
  await tracker.send(tx, { label: `start ${go.index}`, targetBlock: Number(L.number) + 1 });
}

async function onBlock(L) {
  const nextBase = M.nextBaseFee(L);
  const done = await tracker.onBlock(Number(L.number), nextBase);
  if (done) {
    const [kind, index, proposal] = done.label.split(" ");
    const ok = done.receipt?.status === "success" && !done.replaced;
    if (kind === "start" && ok) started.set(index, L.timestamp);
    if (kind === "fill" && ok) {
      started.delete(index);
      said.delete(index);
    }
    if (kind === "fill" && done.receipt?.status === "reverted" && !done.replaced) {
      const b = reverted.fail(`${index}:${proposal}`, L.number);
      routes.forgetKey(`${index}:${proposal}`); // its routes are searched again (RX-13)
      log(
        index,
        b.stopped
          ? `fill reverted on chain after its simulation passed, ${b.failures} times this auction: leaving it until the strikes lapse (a front-run, or an RPC whose simulation cannot be trusted)`
          : `fill reverted on chain after its simulation passed (${b.failures} of ${MAX_REVERTED_FILLS}): backing off until block ${b.until}`,
      );
    }
    if (kind === "request" && ok) filler?.forget(BigInt(index));
    if (kind === "request" && filler && done.receipt?.status === "reverted" && !done.replaced) {
      const b = filler.reverted(BigInt(index), L.number);
      log(
        `request ${index}`,
        b.stopped
          ? `fill reverted on chain after its simulation passed, ${b.failures} times: leaving it (a front-run, or an RPC whose simulation cannot be trusted)`
          : `fill reverted on chain after its simulation passed (${b.failures} of ${MAX_REVERTED_REQUEST_FILLS}): backing off until block ${b.until}`,
      );
    }
  }
  if (tracker.busy()) return;
  if (await tracker.clearStuck(Number(L.number), nextBase, tip)) return;
  if (lastRefresh === null || L.number - lastRefresh >= START_EVERY_BLOCKS) await refresh(L);

  const T = L.timestamp + 12n;
  // With FILL_AUCTIONS off the bot neither fills nor starts an auction, so no auction is read as open.
  const pending = cfg.fillAuctions
    ? await chain.multicall(
        indexes.flatMap((address) => [
          { address, abi: ABI.hub, functionName: "pendingRebalance" },
          { address, abi: ABI.hub, functionName: "proposalCount" },
        ]),
        L.number,
      )
    : [];
  const open = new Map();
  if (cfg.fillAuctions) {
    indexes.forEach((index, k) => {
      const p = pending[2 * k];
      if (p.status === "success" && M.auctionOpen(p.result[0], T, setup.duration)) {
        open.set(index, { keepMask: p.result[1], proposal: pending[2 * k + 1].result });
      }
    });
  }
  const auctions = [...open].map(([index, a]) => `${index}:${a.proposal}`);
  routes.forget([...auctions, ...startKeys, ...(filler ? filler.keys() : [])]);
  reverted.keep(auctions);

  const checks = await worthChecking(open, L);
  const fills = await Promise.all(
    checks.map(({ index }) => {
      const a = open.get(index);
      return evaluateFill(index, a.keepMask, a.proposal, L).catch((error) => say(index, `fill check failed: ${revertReason(error)}`));
    }),
  );
  const best = fills.filter(Boolean).sort((a, b) => b.profit - a.profit)[0];
  if (best && !subsidyFits(best.profit, L.timestamp)) {
    say(best.index, `waiting: a fill at ${best.profit.toFixed(2)} USD would pass SUBSIDY_BUDGET_USD for the day`);
  } else if (best && !(await fitsItsGas(best.tx, L, best.over))) {
    say(best.index, `not filling: the fill does not run within its gas limit of ${best.tx.gas}`);
  } else if (best) {
    if ((await chain.blockNumber()) !== L.number) return log(best.index, "block passed before sending; next block");
    if (best.profit < 0) subsidies.push({ at: L.timestamp, usd: -best.profit });
    log(best.index, `filling at a bar of ${best.bar.toFixed(6)}: profit ${best.profit.toFixed(2)} USD (float ${(Number(best.usdcDelta) / 1e6).toFixed(2)}, stock ${best.inventoryUsd.toFixed(2)}, gas ${best.gasUsd.toFixed(2)})`);
    await tracker.send(best.tx, { label: `fill ${best.index} ${best.proposal}`, targetBlock: Number(L.number) + 1 });
    return;
  }
  if (cfg.fillAuctions && (lastStartCheck === null || L.number - lastStartCheck >= START_EVERY_BLOCKS)) {
    lastStartCheck = L.number;
    await startChecks(L, open);
  }
  if (filler && !tracker.busy()) await requestChecks(L);
}

/// Every 25 blocks the open requests are read again; every block, with nothing else in flight, the most profitable
/// of them is filled, if any pays.
async function requestChecks(L) {
  if (lastRequestScan === null || L.number - lastRequestScan >= START_EVERY_BLOCKS) {
    lastRequestScan = L.number;
    await filler.scan(L, indexes);
  }
  const pick = await filler.best(L, indexes, ethUsd, tip, feeCap);
  if (!pick) return;
  if ((await chain.blockNumber()) !== L.number) return log(`request ${pick.id}`, "block passed before sending; next block");
  log(`request ${pick.id}`, `filling: profit ${pick.profit.toFixed(2)} USD (float ${(Number(pick.usdcDelta) / 1e6).toFixed(2)}, stock ${pick.inventoryUsd.toFixed(2)}, gas ${pick.gasUsd.toFixed(2)})`);
  await tracker.send(pick.tx, { label: `request ${pick.id}`, targetBlock: Number(L.number) + 1 });
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => (stopping = true));

setup = await chain.checkSetup();
if (cfg.fillRequests) {
  filler = createRequestFiller({ chain, cfg, hermes, routes, requests: setup.requests, pyth: setup.pyth, staticsOf, log, needs });
}
log(`keeper ${chain.account.address} on ${cfg.chain.name}, executor ${cfg.executor}, factory ${cfg.factory}, auctions ${cfg.fillAuctions ? "on" : "off"}, requests ${cfg.fillRequests ? setup.requests : "off"}`);
let last = -1n;
while (!stopping) {
  const n = await chain.blockNumber().catch(() => last);
  if (n > last) {
    last = n;
    try {
      await onBlock(await chain.block(n));
    } catch (error) {
      log("block", n, "failed:", revertReason(error));
    }
    try {
      needs.flush();
    } catch (error) {
      log("needs file", cfg.needsFile, "not written:", error.message);
    }
    if (process.env.KEEPER_DEBUG) log(`block ${n} done`);
    if (ONCE) {
      for (let i = 0; i < 60 && tracker.busy(); i++) {
        await sleep(1000);
        const L = await chain.block(await chain.blockNumber());
        await tracker.onBlock(Number(L.number), M.nextBaseFee(L));
      }
      break;
    }
  }
  await sleep(1000);
}
