#!/usr/bin/env node
// Xindex keeper: starts and fills `WeightedHub` auctions through its own `KeeperExecutor`. It holds no role in the
// protocol (starting and filling are open to anyone); its key is a dedicated hot key that can only fill. See README.md.
//
// A fill names the units the index settles at, and the index accepts them when a weighted gain in units clears the
// auction's bar, which falls with time. On a factory with an oracle the index then checks the fill against Pyth's
// prices of the last minute, a check that can only refuse, so the fill carries Pyth's signed update and the executor
// posts it first. The keeper prices its own trades, off chain, at Pyth's prices from Hermes, each confirmed by Pyth's
// contract before anything is valued at it.
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
import { FRESH_SECONDS, HUB_SLOTS, MAX_CONF_BPS, NO_QUOTE_PROPOSAL, TX_GAS_CAP, parseConfig } from "./bot/config.mjs";
import { MAX_REVERTED_FILLS, MAX_REVERTED_REQUEST_FILLS, revertedFills } from "./bot/backoff.mjs";
import { ABI, createChain, revertReason } from "./bot/chain.mjs";
import { createHermes, priceKey } from "./bot/hermes.mjs";
import * as M from "./bot/math.mjs";
import { createNeeds } from "./bot/needs.mjs";
import { createPythFor } from "./bot/pyth.mjs";
import { TxTracker } from "./bot/nonce.mjs";
import { createRequestFiller } from "./bot/requests.mjs";
import { createRoutes, marketOf } from "./bot/routes.mjs";
import { createSValues } from "./bot/svalues.mjs";
import * as U from "./bot/units.mjs";

const START_COOLDOWN = 86_400n; // a start of ours that nobody filled is not repeated for a day
const NOT_ASKED = " (not asked of the restock: at its best price it cannot pay MIN_PROFIT_USD, RY-8)";
const HERMES_MS = 5_000;
const MAX_FILL_CHECKS = 8; // open auctions simulated per block, richest first (CF-7)
const MAX_START_CHECKS = 4; // ready indexes whose start is simulated per round, richest first (RX-34)
const DAY = 86_400n;
const INT256_MIN = -(2n ** 255n);
// Pyth's tolerance grows by 2% over an auction's four hours. The keeper names its units as if the auction were this
// many seconds younger, a tenth of a percent of tolerance, so a newer Pyth update that lands ahead of its fill, by a
// hair off the prices it simulated, does not push a fill named at the very edge over it. A fill that reverts on
// chain is a strike against its auction (XS-4), so a rival that could knock fills out this way would keep the keeper
// off an auction for an hour: the margin is what makes that take a real move in prices, not a newer timestamp.
const ORACLE_LAG = 720n;
const ONCE = process.argv.includes("--once");
const ONCE_HEAD_WAIT_MS = 60_000; // how long --once waits for a block it can read

const log = (...args) => console.log(new Date().toISOString(), ...args);
const cfg = parseConfig(process.env);
// Windows kept in blocks are Ethereum's: on a chain whose blocks come faster they span as many more blocks and the
// same time (M.blockScale). Every 25 of Ethereum's blocks, five minutes, the starts and the requests are looked at.
const SCALE = M.blockScale(cfg.chain);
const START_EVERY_BLOCKS = 25n * SCALE;
// How many blocks a transaction sent now may take to land, its deadline's worth: one on Ethereum (M.landing).
const LAND_BLOCKS = M.blocksIn(cfg.chain.fillWindowSeconds, cfg.chain);
/// The earliest second a fill sent at block L can land at, which it is priced at, and its deadline.
const land = (L) => M.landing(L.timestamp, cfg.chain);
/// Whether the head has moved on from L by as many blocks as a fill priced at L may take to land: then that fill would
/// land past its deadline, and is priced again instead of sent.
const passed = async (L) => (await chain.blockNumber()) - L.number >= LAND_BLOCKS;
const chain = createChain(cfg);
const hermes = createHermes({ url: cfg.hermesUrl, apiKey: cfg.pythApiKey });
const routes = createRoutes(chain, cfg, ABI, marketOf(cfg.chain));
// Ondo's sValues, read from its oracle on this chain, at which a share-priced Ondo leg is valued (bot/svalues.mjs).
const svalues = createSValues({ chain, oracle: cfg.chain.ondoOracle, log });
const tip = M.gweiToWei(cfg.priorityFeeGwei);
const feeCap = M.gweiToWei(cfg.maxFeeGwei);
const tracker = new TxTracker(chain.txIo, log, { feeCap, landBlocks: Number(LAND_BLOCKS) });
const reverted = revertedFills(SCALE); // `index:proposal` -> fills that reverted on chain (XS-4)
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
const kept = (keepMask, i) => ((keepMask >> BigInt(i)) & 1n) === 1n;
const tokensOf = (short) => short.map((s) => s.token).join(", ");
let subsidies = []; // {at, usd}: fills sent below zero profit, for SUBSIDY_BUDGET_USD's rolling day (RX-16)
let startKeys = []; // route keys of the last start round, kept until the next (RX-34)

const statics = new Map(); // index -> {tokens, ids, decimals, reader, pyth}: `ids` null where the keeper has no price id
const started = new Map(); // index -> timestamp of a start of ours not yet filled
const said = new Map(); // index -> the last reason logged, so a waiting index is not logged every block
const worth = new Map(); // `index:proposal` -> {supply, tvl, block}: an open auction's index, valued every 25 blocks
let setup;
let filler = null;
let indexes = [];
let lastRefresh = null;
let lastStartCheck = null;
let lastRequestScan = null;
let ethUsd = null; // the gas coin's price: ETH's, or BNB's on BNB Chain
let stopping = false;

function say(index, reason) {
  if (said.get(index) === reason) return;
  said.set(index, reason);
  log(index, reason);
}

/// What never changes about `index`: its tokens, each one's decimals, read from the token, and the Pyth id the keeper
/// values it at, null for a coin outside its catalogue, which it leaves alone. Where the chain's catalogue is the
/// factory's (`feedsFromFactory`, BNB Chain and Base), a token's id is its feed there, the very one its hubs check a
/// fill against, and only a token's own price (`FeedKind.Token`) counts: a vault's or a multiplier token's feed prices
/// a share the bot cannot turn into the token's value, so such a leg is left alone, as a share-priced one is (RX-2).
async function staticsOf(index, blockNumber) {
  if (!statics.has(index)) {
    const tokens = await chain.read(index, ABI.hub, "componentTokens", [], blockNumber);
    const decimals = await chain.multicall(
      tokens.map((t) => ({ address: t, abi: ABI.erc20, functionName: "decimals" })),
      blockNumber,
    );
    if (decimals.some((r) => r.status !== "success")) throw new Error("a decimals read failed");
    let feeds = tokens.map(() => null);
    if (cfg.chain.feedsFromFactory) {
      const read = await chain.multicall(
        tokens.map((t) => ({ address: cfg.factory, abi: ABI.factory, functionName: "priceFeedOf", args: [t] })),
        blockNumber,
      );
      if (read.some((r) => r.status !== "success")) throw new Error("a price feed read failed");
      feeds = read.map((r) => (r.result.kind === M.TOKEN_FEED ? r.result.id.toLowerCase() : null));
    }
    const ids = tokens.map((t, i) => cfg.priceIds[t.toLowerCase()] ?? feeds[i]);
    // On a factory with an oracle, the reader a fill's legs are valued through and Pyth's contract behind it: both
    // immutable. Zero where the factory has none, and then no fill is checked against a price.
    const reader = await chain.read(index, ABI.hub, "PRICES", [], blockNumber);
    const checked = BigInt(reader) !== 0n;
    const pyth = checked ? await chain.read(reader, ABI.prices, "PYTH", [], blockNumber) : null;
    if (checked && pyth.toLowerCase() !== setup.pyth.toLowerCase()) {
      throw new Error(`${index} is checked against Pyth at ${pyth}, not the ${setup.pyth} this keeper is set up for`);
    }
    statics.set(index, { tokens, ids, decimals: decimals.map((r) => Number(r.result)), reader: checked ? reader : null, pyth });
  }
  return statics.get(index);
}

/// The entries of `list`, each naming an `index`, whose tokens could be read, their statics now cached. An index
/// whose own tokens cannot be read, as when one of them no longer answers `decimals`, is left out and said so, and
/// `onUnread(entry)` is told: it waits, and does not stop the round for every other index (CA-R2-04).
async function withStatics(list, L, what, onUnread = () => {}) {
  const read = [];
  for (const r of list) {
    try {
      await staticsOf(r.index, L.number);
      read.push(r);
    } catch (error) {
      onUnread(r);
      say(r.index, `${what}: its tokens could not be read: ${revertReason(error)}`);
    }
  }
  return read;
}

/// The weights of `index`, in basis points, read every time. Its creator may change them behind a notice
/// (`proposeWeights`, since 2026-11-23): kept from the first read, a fill would be named against weights the index no
/// longer has, and the hub scores it at the ones it does, so the keeper would be absent from exactly the auction a
/// change of weights opens.
const weightsOf = (index, blockNumber) => chain.read(index, ABI.hub, "componentWeights", [], blockNumber);

/// The Hermes prices of `st`'s legs as each token's own price at block L, with none for a coin without an id: a
/// share-priced Ondo leg at its share's price times Ondo's settled sValue, or at its share's price where there is
/// none, as before (bot/svalues.mjs).
const pricesFrom = async (latest, st, L) =>
  (await svalues.legs(st, st.ids.map((id) => (id ? latest.get(priceKey(id)) : undefined)), L)).map((leg) => leg.price ?? undefined);

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
  // The gas coin's price values every fill's gas (ETH's, or BNB's on BNB Chain): Pyth's, confirmed by its contract,
  // and fresh, or none, which fills nothing until the next refresh finds one (RY-7).
  const eth = await hermes.trusted([cfg.chain.ethPriceId], Date.now() + HERMES_MS, pythChain(L));
  const p = eth.get(priceKey(cfg.chain.ethPriceId));
  ethUsd = M.freshPrice(p, L.timestamp, FRESH_SECONDS, MAX_CONF_BPS) ? M.priceUsd(p) : null;
  lastRefresh = L.number;
}

/// Pyth's contract on this chain as of block L, for {hermes.verified} and {hermes.trusted}.
const pythChain = (L) => ({ read: chain.read, call: chain.call, pyth: setup.pyth, abi: ABI.pyth, blockNumber: L.number });

/// The keeper's price of each leg of `st` it may move, as Pyth's {price, expo}, and null for the rest: a kept leg, a
/// coin without an id, a price that is not Hermes' signed one as Pyth's contract parses it, or is stale or wide (RX-1,
/// RX-9, RY-7), and a share-priced Ondo leg without a settled sValue, which the bot cannot value (RX-2). A share-priced
/// leg with one is priced at its share's price times that sValue (bot/svalues.mjs).
async function pricesOf(st, L, keepMask) {
  const wanted = st.ids.map((id, i) => (id && !kept(keepMask, i) ? id : null));
  const ids = wanted.filter(Boolean);
  const trusted = ids.length ? await hermes.trusted(ids, Date.now() + HERMES_MS, pythChain(L)) : new Map();
  const feeds = wanted.map((id) => {
    const p = id ? trusted.get(priceKey(id)) : null;
    return p && M.freshPrice(p, L.timestamp, FRESH_SECONDS, MAX_CONF_BPS) ? p : null;
  });
  return (await svalues.legs(st, feeds, L)).map((leg) => (leg.shared ? null : leg.price));
}

/// What a fill on a factory with an oracle posts to Pyth and what Pyth's check will make of its legs: bot/pyth.mjs.
const pythFor = createPythFor({ chain, hermes, factory: cfg.factory, abi: ABI, hermesMs: HERMES_MS, revertReason });

/// The fill of `index` the keeper would send at block L: the units it names at its own prices to clear the bar at the
/// earliest second it can land (`land(L).at`), and the settlement the hub previews for them; its deadline is
/// `land(L).by`. `eta`, when given, is written into the hub for the call, to see
/// an auction that is not open yet. `maxSupply` is the most shares the fill accepts: the supply now, plus the streaming
/// fee an accrual would mint by T, which leaves the settlement unchanged, plus SUPPLY_TOLERANCE_BPS (XS-4).
async function preview(index, st, L, keepMask, eta) {
  const { at: T, by: deadline } = land(L);
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
    weightsOf(index, L.number),
    chain.call({ to: index, abi: ABI.hub, functionName: "currentBar", args: [] }, L.number, over),
    pricesOf(st, L, keepMask),
  ]);
  if (bar === 0n) throw new Error("no auction is open at the next block");
  // On a factory with an oracle the fill must also hold Pyth's check, at the tolerance of the auction's second, with
  // each leg valued as the hub's reader values it once the fill's own update is posted. A leg the reader cannot
  // value is left alone, as one the keeper cannot price is.
  const pyth = await pythFor(st, L, over, prices.map((p) => p !== null));
  let oracle = null;
  if (pyth !== null) {
    const opened = eta ?? (await chain.read(index, ABI.hub, "pendingRebalance", [], L.number))[0];
    for (let i = 0; i < prices.length; i++) if (pyth.leaving[i] === null) prices[i] = null;
    const elapsed = T - opened;
    oracle = { leaving: pyth.leaving, arriving: pyth.arriving, elapsed: elapsed > ORACLE_LAG ? elapsed - ORACLE_LAG : 0n };
  }
  // Dollars per raw unit: only their ratios decide the units named.
  const perUnit = prices.map((p, i) => (p ? M.priceUsd(p) / 10 ** st.decimals[i] : null));
  const named = U.nameUnits({ units, weights, keepMask, prices: perUnit, bar, costBps: cfg.tradeCostBps, quote, oracle });
  if (!named) {
    const held = [quote ? "hold the quote" : null, oracle ? "hold Pyth's check" : null].filter(Boolean);
    throw new Error(`no units the keeper can price clear the bar${held.length ? ` and ${held.join(" and ")}` : ""}`);
  }
  // The hub's own preview of those units. Where Pyth checks the fill, it is asked after the update the fill will
  // post: asked alone it would meet whatever stale price Pyth's contract holds, and revert.
  const at = { to: index, abi: ABI.hub, functionName: "previewRebalance", args: [named.newUnits] };
  let previewed;
  if (pyth?.post) {
    const [posted, answer] = await chain.callAfter([pyth.post, at], L.number, over);
    if (!posted.ok) throw new Error(`Pyth refused the update Hermes served: ${revertReason(posted.error)}`);
    if (!answer.ok) throw answer.error;
    previewed = answer.result;
  } else {
    previewed = await chain.call(at, L.number, over);
  }
  const [, gain, out, need] = previewed;
  const moving = out.map((_, i) => i).filter((i) => out[i] > 0n || need[i] > 0n);
  const supply = await chain.read(index, ABI.hub, "totalSupply", [], L.number);
  const [feeShares] = await chain.call({ to: index, abi: ABI.hub, functionName: "pendingStreamingFee", args: [] }, L.number, over);
  const maxSupply = M.withTolerance(supply + feeShares, cfg.supplyToleranceBps);
  // What the fill posts and pays Pyth, or nothing on a factory without an oracle.
  const update = pyth?.post ? { updates: pyth.updates, fee: pyth.fee } : { updates: [], fee: 0n };
  return { T, deadline, moving, newUnits: named.newUnits, bar, gain, priceOf: (i) => prices[i], over, out, in: need, maxSupply, update };
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
  // and overstate its profit by that stock's value. The check is made again next block (RY-9). Only the legs the fill
  // moves count: the hub and the executor read no other, so a coin that answers no balance, which the guardian keeps
  // or the fill leaves at its units, does not stop the fill of the rest (CA-R2-03, DA-14).
  if (M.movingReadFailed(sim.moving, held, allowed)) throw new Error("a stock read failed");
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
    inventoryUsd += M.stockChangeUsd({ out, in: need, held: h, routed: route !== null, decimals: dec, price: p, quoteUsdc, usdcDecimals: cfg.chain.usdcDecimals });
  }
  return { routes: routeOf, inventoryUsd, routedVolumeUsdc: M.usdToUsdcCeil(routedUsd, cfg.chain.usdcDecimals), short, stocked };
}

/// Simulates the executor's fill of `sim` and prices it: profit after gas, and the transaction that would send it.
async function priceFill(index, sim, leg, maxIn, L) {
  if (ethUsd === null) return { skip: "no price of the gas coin to value gas" };
  // The executor's fill, floored at `floor`: it posts Pyth's update first, for the fee the call carries.
  const fillOf = (floor) => [
    {
      index,
      newUnits: sim.newUnits,
      routes: leg.routes,
      maxAmountsIn: maxIn,
      maxSupply: sim.maxSupply,
      minUsdcDelta: floor,
      deadline: sim.deadline,
      pythUpdate: sim.update.updates,
    },
  ];
  const args = fillOf(INT256_MIN);
  let usdcDelta;
  let inner;
  try {
    [usdcDelta, inner] = await chain.call(
      { to: cfg.executor, abi: ABI.executor, functionName: "fill", args, value: sim.update.fee },
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
  // Pyth's fee is counted with the gas: both are the gas coin the fill spends, and so is Base's L1 data fee.
  const l1Fee = await chain.l1Fee(encodeFunctionData({ abi: ABI.executor, functionName: "fill", args }), L.number);
  const gasUsd = M.fillCostUsd({ used, nextBase, tip, ethUsd, value: sim.update.fee, l1Fee });
  const decimals = cfg.chain.usdcDecimals;
  const profit = M.profitUsd({ usdcDelta, inventoryUsd: leg.inventoryUsd, gasUsd, decimals });
  const bounds = {
    simDelta: usdcDelta,
    minProfitUsd: cfg.minProfitUsd,
    gasUsd,
    inventoryUsd: leg.inventoryUsd,
    routedVolumeUsdc: leg.routedVolumeUsdc,
    slippageBps: cfg.slippageBps,
    decimals,
  };
  const floor = M.usdcFloor(bounds);
  const data = encodeFunctionData({ abi: ABI.executor, functionName: "fill", args: fillOf(floor) });
  const tx = {
    to: cfg.executor,
    data,
    value: sim.update.fee,
    gas,
    maxFeePerGas: M.min(2n * nextBase + tip, feeCap),
    maxPriorityFeePerGas: tip,
  };
  // `worst` is what the fill pays if the float ends at that floor: what a subsidy is charged at (RZ-16).
  return { profit, worst: M.worstProfitUsd(bounds), usdcDelta, gasUsd, inventoryUsd: leg.inventoryUsd, tx, over: sim.over, deadline: sim.deadline };
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
    // An index left out is valued at nothing here, and read again with the others in 25 blocks.
    const readable = await withStatics(live, L, "no fill check", (r) => worth.set(keyOf(r.index), { supply: 0n, tvl: 0, block: L.number }));
    if (readable.length) {
      const ids = new Set();
      for (const r of readable) for (const id of statics.get(r.index).ids) if (id) ids.add(id);
      const latest = ids.size ? await hermes.latest([...ids], Date.now() + HERMES_MS) : new Map();
      for (const r of readable) {
        const st = statics.get(r.index);
        const prices = await pricesFrom(latest, st, L);
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

/// An auction of `index` that is not open, seen at its last second, where the bar is lowest: the one a start would
/// open now, or, with `keepMask`, the proposal waiting out its notice. Returns its settlement, the most it may ask of
/// each coin and its legs, or null with the reason logged. What stock would serve, when that fill could pay
/// MIN_PROFIT_USD (RY-8), goes on the board under `key`, the key its fill carries, so the need stands unbroken from
/// before the start to the fill (RZ-3). A proposal's quote, if one was posted, is left out, as {mayPay} leaves it out.
async function bestCase(index, key, source, L, keepMask = 0n) {
  const st = await staticsOf(index, L.number);
  let best;
  try {
    best = await preview(index, st, L, keepMask, land(L).at - setup.duration);
  } catch (error) {
    say(index, `${source === "start" ? "not starting" : "no restock ahead"}: ${revertReason(error)}`);
    return null;
  }
  const maxIn = best.in.map((x) => M.withTolerance(x, cfg.supplyToleranceBps));
  const leg = await legs(index, st, best, maxIn, L, key);
  const pays = await mayPay(index, st, L, keepMask, leg.stocked, best, best);
  needs.report(key, source, pays ? leg.stocked : []);
  return { best, maxIn, leg, pays };
}

/// Whether to start `index`: its auction, simulated at its last second, where the bar is lowest, must pay.
async function evaluateStart(index, proposal, L) {
  const seen = await bestCase(index, `${index}:${proposal + 1n}`, "start", L);
  if (!seen) return;
  const { best, maxIn, leg, pays } = seen;
  if (leg.short.length) return say(index, `not starting: restock${pays ? "" : NOT_ASKED} ${tokensOf(leg.short)}`);
  const priced = await priceFill(index, best, leg, maxIn, L);
  if (priced.skip) return say(index, `not starting: ${priced.skip}`);
  // The start is this bot's own transaction: its gas, at the limit it is sent with, comes off what the fill it opens
  // would pay (RZ-14).
  const startData = encodeFunctionData({ abi: ABI.hub, functionName: "startRebalance", args: [0n] });
  const startUsd = M.fillCostUsd({ used: M.START_GAS_LIMIT, nextBase: M.nextBaseFee(L), tip, ethUsd, l1Fee: await chain.l1Fee(startData, L.number) });
  const profit = priced.profit - startUsd;
  if (profit < cfg.minProfitUsd) {
    return say(index, `not starting: best case pays ${profit.toFixed(2)} USD after the start's ${startUsd.toFixed(2)}`);
  }
  return { index, profit, T: best.T };
}

/// The key a start check of `r` reports and searches routes under: its own proposal's in the notice, which the fill
/// will carry, and otherwise the proposal a start would open.
const stageKey = (r) => `${r.index}:${r.stage === "notice" ? r.proposal : r.proposal + 1n}`;

/// The board's need for an auction that is not open yet (`r.stage`, {M.startStage}): a proposal in its notice, or the
/// one a start could open within PRESTOCK_LEAD_SECONDS. Nothing is sent.
async function prestock(r, L) {
  const seen = await bestCase(r.index, stageKey(r), r.stage, L, r.stage === "notice" ? r.keepMask : 0n);
  if (seen?.leg.short.length) say(r.index, `restock ahead of the auction${seen.pays ? "" : NOT_ASKED}: ${tokensOf(seen.leg.short)}`);
}

/// Whether the auction of `index` could pay MIN_PROFIT_USD at its last second, where the bar is lowest, so that the
/// stock its fill would deliver is worth bringing in (RY-8): M.settlementMarginUsd of the settlement then, at the
/// keeper's prices.
/// `best` is that settlement when already simulated; otherwise it is, with `sim`, the settlement now, as the fallback
/// should the best case not simulate. Nothing is asked when stock serves no leg.
async function mayPay(index, st, L, keepMask, stocked, sim, best) {
  if (stocked.length === 0) return false;
  const atBest = best ?? (await preview(index, st, L, keepMask, land(L).at - setup.duration).catch(() => sim));
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
      { address, abi: ABI.hub, functionName: "pendingRebalance" },
      { address, abi: ABI.hub, functionName: "earliestRebalance" },
    ]),
    L.number,
  );
  const T = land(L).at;
  const lead = BigInt(cfg.prestockLeadSeconds);
  const ready = [];
  const ahead = []; // auctions not open yet, whose needs go on the restock's board before they open
  for (let k = 0; k < candidates.length; k++) {
    const six = reads.slice(6 * k, 6 * k + 6);
    if (six.some((r) => r.status !== "success")) continue;
    const [can, supply, comps, proposal, pending, earliest] = six;
    if (supply.result === 0n) continue;
    const stage = M.startStage({ can: can.result, eta: pending.result[0], earliest: earliest.result, T, lead });
    const r = { index: candidates[k], supply: supply.result, units: comps.result[1], proposal: proposal.result, keepMask: pending.result[1], stage };
    if (stage === "ready") {
      const since = started.get(candidates[k]);
      if (since === undefined || L.timestamp - since >= START_COOLDOWN) ready.push(r);
    } else if (stage !== null && cfg.needsFile) {
      ahead.push(r);
    }
  }
  if (ready.length === 0 && ahead.length === 0) return;

  const readable = await withStatics([...ready, ...ahead], L, "no start check");
  const ids = new Set();
  for (const r of readable) for (const id of statics.get(r.index).ids) if (id) ids.add(id);
  const latest = ids.size ? await hermes.latest([...ids], Date.now() + HERMES_MS) : new Map();
  const worthy = [];
  const worthyAhead = [];
  for (const r of readable) {
    const st = statics.get(r.index);
    const tvl = M.tvlUsd({ supply: r.supply, units: r.units, decimals: st.decimals, prices: await pricesFrom(latest, st, L) });
    if (tvl < cfg.minTvlUsd) {
      if (r.stage === "ready") say(r.index, `not starting: worth ${tvl.toFixed(0)} USD, below MIN_TVL_USD`);
      continue;
    }
    (r.stage === "ready" ? worthy : worthyAhead).push({ ...r, tvl });
  }
  // The richest few, simulated side by side, their routes kept until the next round, so the start checks cannot hold
  // the main loop for blocks every 25 (RX-34). The auctions ahead get as many checks again.
  const { chosen, rest } = M.startsToCheck(worthy, MAX_START_CHECKS);
  for (const r of rest) say(r.index, `not starting this round: past the ${MAX_START_CHECKS} richest ready indexes`);
  const early = M.startsToCheck(worthyAhead, MAX_START_CHECKS);
  for (const r of early.rest) say(r.index, `no restock ahead this round: past the ${MAX_START_CHECKS} richest auctions ahead`);
  startKeys = [...chosen, ...early.chosen].map(stageKey);
  await Promise.all(early.chosen.map((r) => prestock(r, L).catch((error) => say(r.index, `restock-ahead check failed: ${revertReason(error)}`))));
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
  if (await passed(L)) {
    lastStartCheck = null;
    return log(go.index, "block passed before sending; next block");
  }
  log(go.index, `starting: best case pays ${go.profit.toFixed(2)} USD`);
  await tracker.send(tx, { label: `start ${go.index}`, targetBlock: Number(L.number + LAND_BLOCKS) });
}

/// One block's work. Returns whether it looked at everything the needs board reports on: every open auction, the
/// starts when their round is due, and the requests. A block that stopped short of that, behind a transaction in
/// flight or a block that passed, observed nothing the board can be dated by (CA-R2-02).
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
    // A fill mined past its own deadline reverted on it: no strike (RZ-15). When the block it was mined in cannot be
    // read, it counts as before.
    let late = false;
    if (done.receipt?.status === "reverted" && !done.replaced && done.deadline !== null) {
      const mined = await chain.block(done.receipt.blockNumber).catch(() => null);
      late = mined !== null && M.minedLate(mined.timestamp, done.deadline);
      if (late) log(done.label, "mined past its deadline and reverted on it: not counted against it");
    }
    if (kind === "fill" && done.receipt?.status === "reverted" && !done.replaced && !late) {
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
    if (kind === "batch" && ok) for (const id of index.split(",")) filler?.forget(BigInt(id));
    if (kind === "batch" && filler && done.receipt?.status === "reverted" && !done.replaced && !late) {
      const b = filler.revertedBatch(index.split(",").map(BigInt), L.number);
      log(
        `batch ${index}`,
        b.stopped
          ? `fill reverted on chain after its simulation passed: leaving its requests until the strikes lapse (a front-run, or an RPC whose simulation cannot be trusted)`
          : `fill reverted on chain after its simulation passed: backing off until block ${b.until}`,
      );
    }
    if (kind === "request" && filler && done.receipt?.status === "reverted" && !done.replaced && !late) {
      const b = filler.reverted(BigInt(index), L.number);
      log(
        `request ${index}`,
        b.stopped
          ? `fill reverted on chain after its simulation passed, ${b.failures} times: leaving it (a front-run, or an RPC whose simulation cannot be trusted)`
          : `fill reverted on chain after its simulation passed (${b.failures} of ${MAX_REVERTED_REQUEST_FILLS}): backing off until block ${b.until}`,
      );
    }
  }
  if (tracker.busy()) return false;
  if (await tracker.clearStuck(Number(L.number), nextBase, tip)) return false;
  if (lastRefresh === null || L.number - lastRefresh >= START_EVERY_BLOCKS) await refresh(L);

  const T = land(L).at;
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
  if (best && !subsidyFits(best.worst, L.timestamp)) {
    say(best.index, `waiting: a fill that may pay as little as ${best.worst.toFixed(2)} USD would pass SUBSIDY_BUDGET_USD for the day`);
  } else if (best && !(await fitsItsGas(best.tx, L, best.over))) {
    say(best.index, `not filling: the fill does not run within its gas limit of ${best.tx.gas}`);
  } else if (best) {
    if (await passed(L)) {
      log(best.index, "block passed before sending; next block");
      return false;
    }
    log(best.index, `filling at a bar of ${best.bar.toFixed(6)}: profit ${best.profit.toFixed(2)} USD (float ${M.usdcUsd(best.usdcDelta, cfg.chain.usdcDecimals).toFixed(2)}, stock ${best.inventoryUsd.toFixed(2)}, gas ${best.gasUsd.toFixed(2)})`);
    const sent = await tracker.send(best.tx, { label: `fill ${best.index} ${best.proposal}`, targetBlock: Number(L.number + LAND_BLOCKS), deadline: best.deadline });
    // The budget is charged for a fill that went out, at what its floor lets it lose: one the node refused costs
    // nothing (RZ-9, RZ-16).
    if (sent === null) log(best.index, "not sent (the tracker's line says why); checked again at the next block");
    else if (best.worst < 0) subsidies.push({ at: L.timestamp, usd: -best.worst });
    return false;
  }
  if (cfg.fillAuctions && (lastStartCheck === null || L.number - lastStartCheck >= START_EVERY_BLOCKS)) {
    lastStartCheck = L.number;
    await startChecks(L, open);
  }
  if (!filler) return true;
  if (tracker.busy()) return false;
  await requestChecks(L);
  return true;
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
  // A batch is named by its requests' ids, joined without a space: the label is read back word by word.
  const name = pick.ids ? `batch ${pick.ids.join(",")}` : `request ${pick.id}`;
  if (await passed(L)) return log(name, "block passed before sending; next block");
  log(name, `filling: profit ${pick.profit.toFixed(2)} USD (float ${M.usdcUsd(pick.usdcDelta, cfg.chain.usdcDecimals).toFixed(2)}, stock ${pick.inventoryUsd.toFixed(2)}, gas ${pick.gasUsd.toFixed(2)})`);
  await tracker.send(pick.tx, { label: name, targetBlock: Number(L.number + LAND_BLOCKS), deadline: pick.deadline });
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => (stopping = true));

setup = await chain.checkSetup();
if (cfg.fillRequests) {
  filler = createRequestFiller({ chain, cfg, hermes, routes, svalues, requests: setup.requests, pyth: setup.pyth, stableDecimals: setup.stableDecimals, staticsOf, log, needs });
}
log(`keeper ${chain.account.address} on ${cfg.chain.name}, executor ${cfg.executor}, factory ${cfg.factory}, auctions ${cfg.fillAuctions ? "on" : "off"}, requests ${cfg.fillRequests ? setup.requests : "off"}`);
let last = -1n;
// With --once the process answers for its one block: a block it could not read in a minute, or whose round failed,
// exits non-zero, so a scheduler that runs it does not record a run that did nothing as a success (CA-R2-20).
const headBy = Date.now() + ONCE_HEAD_WAIT_MS;
while (!stopping) {
  const n = await chain.blockNumber().catch(() => last);
  if (n <= last && ONCE && Date.now() > headBy) {
    log(`no block read within ${ONCE_HEAD_WAIT_MS / 1000} s`);
    process.exitCode = 1;
    break;
  }
  if (n > last) {
    last = n;
    let observed = false;
    try {
      observed = await onBlock(await chain.block(n));
    } catch (error) {
      log("block", n, "failed:", revertReason(error));
      if (ONCE) process.exitCode = 1;
    }
    try {
      needs.flush({ observed });
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
