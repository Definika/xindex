#!/usr/bin/env node
// Xindex keeper: starts and fills `WeightedHub` auctions through its own `KeeperExecutor`. It holds no role in the
// protocol (starting and filling are open to anyone); its key is a dedicated hot key that can only fill. See README.md.
//
// Every block L, with T = L's timestamp + 12, the one block a fill sent now can land in:
//   1. each open auction is simulated exactly as block L+1 would run it (eth_call with block overrides), with Hermes'
//      update for second t_L, the routes quoted for each leg, and the executor's stock;
//   2. the most profitable fill whose profit, after gas and valued stock, reaches MIN_PROFIT_USD is sent with a USDC
//      floor at least what that decision needs, and a deadline of T;
//   3. every 25 blocks, an index anyone may restart is started only when a simulation of its auction at its best
//      price (μ = MU_MIN) would pay.

import { encodeFunctionData, getAddress } from "viem";
import { HUB_SLOTS, MAINNET, TX_GAS_CAP, parseConfig } from "./bot/config.mjs";
import { ABI, createChain, revertReason } from "./bot/chain.mjs";
import { createHermes, priceKey } from "./bot/hermes.mjs";
import * as M from "./bot/math.mjs";
import { TxTracker } from "./bot/nonce.mjs";
import { createRoutes } from "./bot/routes.mjs";

const START_EVERY_BLOCKS = 25n;
const START_COOLDOWN = 86_400n; // a start of ours that nobody filled is not repeated for a day
const FRESH_SECONDS = 60n; // a feed quieter than this is closed (US-hours stock feeds): no start
const HERMES_MS = 5_000;
const MAX_FILL_CHECKS = 8; // open auctions simulated per block, richest first (CF-7)
const INT256_MIN = -(2n ** 255n);
const ONCE = process.argv.includes("--once");

const log = (...args) => console.log(new Date().toISOString(), ...args);
const cfg = parseConfig(process.env);
const chain = createChain(cfg);
const hermes = createHermes({ url: cfg.hermesUrl, apiKey: cfg.pythApiKey });
const routes = createRoutes(chain, cfg);
const tracker = new TxTracker(chain.txIo, log);
const tip = M.gweiToWei(cfg.priorityFeeGwei);
const feeCap = M.gweiToWei(cfg.maxFeeGwei);
const isUsdc = (token) => token.toLowerCase() === MAINNET.usdc.toLowerCase();

const statics = new Map(); // index -> {tokens, ids, decimals}
const started = new Map(); // index -> timestamp of a start of ours not yet filled
const said = new Map(); // index -> the last reason logged, so a waiting index is not logged every block
const worth = new Map(); // `index:proposal` -> {supply, tvl, block}: an open auction's index, valued every 25 blocks
let setup;
let indexes = [];
let lastRefresh = null;
let lastStartCheck = null;
let ethUsd = null;
let stopping = false;

function say(index, reason) {
  if (said.get(index) === reason) return;
  said.set(index, reason);
  log(index, reason);
}

async function staticsOf(index, blockNumber) {
  if (!statics.has(index)) {
    const tokens = await chain.read(index, ABI.hub, "componentTokens", [], blockNumber);
    const [, ids, decimals] = await chain.read(index, ABI.hub, "componentTerms", [], blockNumber);
    statics.set(index, { tokens, ids, decimals });
  }
  return statics.get(index);
}

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
  const eth = await hermes.latest([MAINNET.ethPriceId], Date.now() + HERMES_MS);
  const p = eth.get(priceKey(MAINNET.ethPriceId));
  if (p) ethUsd = M.priceUsd(p);
  lastRefresh = L.number;
}

/// The auction of `index` as block L+1 would settle it, at Hermes' update for second t_L. `eta`, when given, is
/// written into the hub for the call, to see an auction that is not open yet.
async function preview(index, st, L, keepMask, eta) {
  const T = L.timestamp + 12n;
  const moving = st.ids.map((_, i) => i).filter((i) => ((keepMask >> BigInt(i)) & 1n) === 0n);
  const { updates, prices } = await hermes.at(
    moving.map((i) => st.ids[i]),
    Number(L.timestamp),
    Date.now() + HERMES_MS,
  );
  const priceOf = (i) => prices.get(priceKey(st.ids[i]));
  const structs = st.ids.map((_, i) => {
    if (!moving.includes(i)) return { price: 0n, conf: 0n, expo: 0, publishTime: 0n };
    const p = priceOf(i);
    return { price: p.price, conf: p.conf, expo: p.expo, publishTime: BigInt(p.publishTime) };
  });
  const over = { block: { number: L.number + 1n, time: T } };
  if (eta !== undefined) over.state = { [index]: { [HUB_SLOTS.eta]: eta, [HUB_SLOTS.keepMask]: keepMask } };
  const at = (o) =>
    chain.call({ to: index, abi: ABI.hub, functionName: "previewRebalance", args: [structs] }, L.number, o);
  const [mu, , out, need] = await at(over);
  return { T, moving, updates, priceOf, over, mu, out, in: need, again: at };
}

/// The routes, stock change and routed volume of a settlement, or `short` naming coins the executor can neither buy
/// nor deliver from stock. `maxIn` is the most of each coin the fill may be asked for.
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
  const routeOf = st.tokens.map(() => "0x");
  const short = [];
  let inventoryUsd = 0;
  let routedUsd = 0;
  for (const i of sim.moving) {
    const token = st.tokens[i];
    const out = sim.out[i];
    const need = sim.in[i];
    if ((out === 0n && need === 0n) || isUsdc(token)) continue; // a USDC leg is the float itself
    const h = M.min(
      held[i].status === "success" ? held[i].result : 0n,
      allowed[i].status === "success" ? allowed[i].result : 0n,
    );
    const p = sim.priceOf(i);
    const dec = st.decimals[i];
    let route = null;
    if (out > 0n) {
      route = await routes.best({ key, token, side: "sell", amount: out, fairUsd: M.amountUsd(out, dec, p), blockNumber: L.number });
      if (route) routedUsd += M.amountUsd(out, dec, p);
    } else if (maxIn[i] > h) {
      const shortfall = maxIn[i] - h;
      route = await routes.best({ key, token, side: "buy", amount: shortfall, fairUsd: M.amountUsd(shortfall, dec, p), blockNumber: L.number });
      if (!route) {
        short.push(token);
        continue;
      }
      routedUsd += M.amountUsd(M.max(need - h, 0n), dec, p);
    }
    if (route) routeOf[i] = route;
    inventoryUsd += M.amountUsd(M.inventoryDelta({ out, in: need, held: h, routed: route !== null }), dec, p);
  }
  return { routes: routeOf, inventoryUsd, routedVolumeUsdc: M.usdToUsdcCeil(routedUsd), short };
}

/// Simulates the executor's fill of `sim` and prices it: profit after gas, and the transaction that would send it.
async function priceFill(index, sim, leg, maxIn, L) {
  if (ethUsd === null) return { skip: "no ETH price to value gas" };
  const fee = await chain.read(setup.pyth, ABI.pyth, "getUpdateFee", [sim.updates], L.number);
  const args = [index, sim.updates, leg.routes, maxIn, INT256_MIN, sim.T];
  let usdcDelta;
  let inner;
  try {
    [usdcDelta, inner] = await chain.call(
      { to: cfg.executor, abi: ABI.executor, functionName: "fill", args, value: fee },
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
  const gasUsd = (Number(used * (nextBase + tip)) / 1e18) * ethUsd;
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
    args: [index, sim.updates, leg.routes, maxIn, floor, sim.T],
  });
  const tx = {
    to: cfg.executor,
    data,
    value: fee,
    gas,
    maxFeePerGas: M.min(2n * nextBase + tip, feeCap),
    maxPriorityFeePerGas: tip,
  };
  return { profit, usdcDelta, gasUsd, inventoryUsd: leg.inventoryUsd, tx };
}

/// The open auctions to simulate this block (CF-7): each index's supply and worth, read once per auction and again
/// every 25 blocks with one multicall and one Hermes request for all of them, then M.auctionsToEvaluate. An auction
/// on an empty or small index costs no Hermes request and no simulation per block.
async function worthChecking(open, L) {
  const keyOf = (index) => `${index}:${open.get(index).proposal}`;
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
      for (const r of live) for (const id of (await staticsOf(r.index, L.number)).ids) ids.add(id);
      const latest = await hermes.latest([...ids], Date.now() + HERMES_MS);
      for (const r of live) {
        const st = statics.get(r.index);
        const prices = st.ids.map((id) => latest.get(priceKey(id)));
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
  if (leg.short.length) return say(index, `restock: no route and too little stock of ${leg.short.join(", ")}`);
  const priced = await priceFill(index, sim, leg, maxIn, L);
  if (priced.skip) return say(index, priced.skip);
  const mu = Number(sim.mu) / 1e18;
  if (priced.profit < cfg.minProfitUsd) return say(index, `waiting: profit below ${cfg.minProfitUsd} USD at mu ${mu.toFixed(4)}`);
  return { index, mu, ...priced };
}

/// Whether to start `index`: its auction, simulated at its best price, must pay.
async function evaluateStart(index, proposal, L) {
  const st = await staticsOf(index, L.number);
  const T = L.timestamp + 12n;
  let best;
  try {
    best = await preview(index, st, L, 0n, T - setup.duration);
  } catch (error) {
    return say(index, `not starting: ${revertReason(error)}`);
  }
  // Inventory must cover the most an auction can ask: amounts in at MU_MAX, from an eta of T.
  const atMuMax = { ...best.over, state: { [index]: { [HUB_SLOTS.eta]: T, [HUB_SLOTS.keepMask]: 0n } } };
  const [, , , needMax] = await best.again(atMuMax);
  const maxIn = needMax.map((x) => M.withTolerance(x, cfg.supplyToleranceBps));
  const leg = await legs(index, st, best, maxIn, L, `${index}:${proposal + 1n}`);
  if (leg.short.length) return say(index, `not starting: restock ${leg.short.join(", ")}`);
  const priced = await priceFill(index, best, leg, maxIn, L);
  if (priced.skip) return say(index, `not starting: ${priced.skip}`);
  if (priced.profit < cfg.minProfitUsd) return say(index, `not starting: best case pays ${priced.profit.toFixed(2)} USD`);
  return { index, profit: priced.profit };
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
  for (const r of ready) for (const id of (await staticsOf(r.index, L.number)).ids) ids.add(id);
  const latest = await hermes.latest([...ids], Date.now() + HERMES_MS);
  for (const r of ready) {
    const st = statics.get(r.index);
    const quiet = st.ids.filter((id) => {
      const p = latest.get(priceKey(id));
      return !p || BigInt(p.publishTime) < L.timestamp - FRESH_SECONDS;
    });
    if (quiet.length) {
      say(r.index, `not starting: feed closed or quiet: ${quiet.join(", ")}`);
      continue;
    }
    const tvl = M.tvlUsd({ supply: r.supply, units: r.units, decimals: st.decimals, prices: st.ids.map((id) => latest.get(priceKey(id))) });
    if (tvl < cfg.minTvlUsd) {
      say(r.index, `not starting: worth ${tvl.toFixed(0)} USD, below MIN_TVL_USD`);
      continue;
    }
    const go = await evaluateStart(r.index, r.proposal, L).catch((error) => say(r.index, `start check failed: ${revertReason(error)}`));
    if (!go) continue;
    const data = encodeFunctionData({ abi: ABI.hub, functionName: "startRebalance", args: [0n] });
    const used = await chain.client.estimateGas({ account: chain.account.address, to: r.index, data });
    const nextBase = M.nextBaseFee(L);
    if (nextBase + tip > feeCap) return;
    log(r.index, `starting: best case pays ${go.profit.toFixed(2)} USD`);
    await tracker.send(
      { to: r.index, data, value: 0n, gas: M.gasLimitFor(used), maxFeePerGas: M.min(2n * nextBase + tip, feeCap), maxPriorityFeePerGas: tip },
      { label: `start ${r.index}`, targetBlock: Number(L.number) + 3 },
    );
    return; // one transaction at a time
  }
}

async function onBlock(L) {
  const nextBase = M.nextBaseFee(L);
  const done = await tracker.onBlock(Number(L.number), nextBase);
  if (done) {
    const [kind, index] = done.label.split(" ");
    const ok = done.receipt?.status === "success" && !done.replaced;
    if (kind === "start" && ok) started.set(index, L.timestamp);
    if (kind === "fill" && ok) {
      started.delete(index);
      said.delete(index);
    }
  }
  if (tracker.busy()) return;
  if (await tracker.clearStuck(Number(L.number), nextBase, tip)) return;
  if (lastRefresh === null || L.number - lastRefresh >= START_EVERY_BLOCKS) await refresh(L);

  const T = L.timestamp + 12n;
  const pending = await chain.multicall(
    indexes.flatMap((address) => [
      { address, abi: ABI.hub, functionName: "pendingRebalance" },
      { address, abi: ABI.hub, functionName: "proposalCount" },
    ]),
    L.number,
  );
  const open = new Map();
  indexes.forEach((index, k) => {
    const p = pending[2 * k];
    if (p.status === "success" && M.auctionOpen(p.result[0], T, setup.duration)) {
      open.set(index, { keepMask: p.result[1], proposal: pending[2 * k + 1].result });
    }
  });
  routes.forget([...open].map(([index, a]) => `${index}:${a.proposal}`));

  const checks = await worthChecking(open, L);
  const fills = await Promise.all(
    checks.map(({ index }) => {
      const a = open.get(index);
      return evaluateFill(index, a.keepMask, a.proposal, L).catch((error) => say(index, `fill check failed: ${revertReason(error)}`));
    }),
  );
  const best = fills.filter(Boolean).sort((a, b) => b.profit - a.profit)[0];
  if (best) {
    if ((await chain.blockNumber()) !== L.number) return log(best.index, "block passed before sending; next block");
    log(best.index, `filling at mu ${best.mu.toFixed(4)}: profit ${best.profit.toFixed(2)} USD (float ${(Number(best.usdcDelta) / 1e6).toFixed(2)}, stock ${best.inventoryUsd.toFixed(2)}, gas ${best.gasUsd.toFixed(2)})`);
    await tracker.send(best.tx, { label: `fill ${best.index}`, targetBlock: Number(L.number) + 1 });
    return;
  }
  if (lastStartCheck === null || L.number - lastStartCheck >= START_EVERY_BLOCKS) {
    lastStartCheck = L.number;
    await startChecks(L, open);
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => (stopping = true));

setup = await chain.checkSetup();
log(`keeper ${chain.account.address}, executor ${cfg.executor}, factory ${cfg.factory}`);
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
