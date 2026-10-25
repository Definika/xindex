#!/usr/bin/env node
// Xindex restock: keeps the keeper's executor stocked with the coins Ethereum has only as Wormhole copies, which no
// Ethereum pool sells. It holds no role in the protocol; its key is the treasury's, a hot key the executor's owner
// pins, which can only bridge stock in and out of the executor and draw or repay USDC within the owner's allowance.
// See README.md, "Restock".
//
// Every RESTOCK_INTERVAL_SECONDS:
//   1. every move in the journal is taken one step further: a transaction mined, a transfer signed by Wormhole's
//      guardians or attested by Circle, then redeemed or received on the other side;
//   2. it reads what the keeper's fills are short of (NEEDS_FILE), the executor's stock, the treasury's USDC, each home
//      wallet's coins, float and gas, and Pyth's prices, and plans (`restock/plan.mjs`): buy a short coin on its home
//      chain and bridge it in, sell and bring home what nobody needs, and move USDC where the buys wait for it;
//   3. it runs the plan, each move recorded in the journal (JOURNAL_FILE) before it is broadcast.

import { decodeFunctionResult, encodeFunctionData } from "viem";
import { MAINNET } from "./bot/config.mjs";
import { isRevert, revertReason } from "./bot/chain.mjs";
import { createHermes, priceKey } from "./bot/hermes.mjs";
import { readNeeds } from "./bot/needs.mjs";
import { createRoutes } from "./bot/routes.mjs";
import { createIris, createWormholescan } from "./restock/attestations.mjs";
import { CHAINS, PRICE_IDS } from "./restock/coins.mjs";
import { parseRestockConfig } from "./restock/config.mjs";
import { ABI, EVM_CHAINS, createEvm, word } from "./restock/evm.mjs";
import { createJournal, fileStore } from "./restock/journal.mjs";
import { plan } from "./restock/plan.mjs";

const ONCE = process.argv.includes("--once");
const FRESH_SECONDS = 120;
const log = (...args) => console.log(new Date().toISOString(), ...args);
const cfg = parseRestockConfig(process.env);

const journal = createJournal(fileStore(cfg.journalFile));
const hermes = createHermes({ url: cfg.hermesUrl, apiKey: cfg.pythApiKey });
const wormholescan = createWormholescan({ url: process.env.WORMHOLESCAN_URL });
const iris = createIris({ url: process.env.IRIS_URL });
const eth = createEvm({ name: "ethereum", rpcUrl: cfg.rpcUrl, key: cfg.treasuryKey, journal });

const homes = {};
const routes = {};
for (const [name, chain] of Object.entries(cfg.chains)) {
  if (chain.platform !== "evm") {
    throw new Error(`${name}'s coins (${cfg.coins.filter((c) => c.chain === name).map((c) => c.symbol).join(", ")}) need their ${chain.platform} adapter; leave them out of RESTOCK_COINS`);
  }
  homes[name] = createEvm({ name, rpcUrl: chain.rpcUrl, key: chain.key, journal });
  routes[name] = createRoutes(reader(homes[name].client), { routeMaxLossBps: cfg.plan.maxLossBps }, ABI, EVM_CHAINS[name].market);
}
const coinOf = (symbol) => cfg.coins.find((c) => c.symbol === symbol);
const same = (a, b) => a.toLowerCase() === b.toLowerCase();

/// The route search's view of a chain: multicall, eth_call, and which errors are reverts.
function reader(client) {
  return {
    multicall: (contracts, blockNumber) => client.multicall({ contracts, blockNumber, allowFailure: true }),
    call: async ({ to, abi, functionName, args }, blockNumber) => {
      const { data } = await client.call({ to, data: encodeFunctionData({ abi, functionName, args }), blockNumber });
      return decodeFunctionResult({ abi, functionName, data });
    },
    isRevert,
  };
}

/// Refuses to run unless the executor names this treasury, this bridge and USDC, and every served chain's recipient is
/// this service's wallet there: without them every move would revert, or bridge to someone else.
async function checkSetup() {
  if ((await eth.client.getChainId()) !== MAINNET.chainId) throw new Error("RPC_URL is not Ethereum");
  const ex = (fn, args) => eth.read(cfg.executor, ABI.executor, fn, args);
  const [treasury, bridge, usdc] = await Promise.all([ex("treasury"), ex("TOKEN_BRIDGE"), ex("USDC")]);
  if (!same(treasury, eth.address)) throw new Error(`the executor's treasury is ${treasury}, not this service's ${eth.address}`);
  if (!same(bridge, MAINNET.tokenBridge)) throw new Error(`the executor bridges through ${bridge}, not Wormhole's Token Bridge`);
  if (!same(usdc, MAINNET.usdc)) throw new Error(`the executor's float is ${usdc}, not USDC`);
  for (const [name, home] of Object.entries(homes)) {
    const chainId = await home.client.getChainId();
    if (chainId !== CHAINS[name].evmChainId) throw new Error(`${name}'s RPC serves chain ${chainId}`);
    const pinned = await ex("homeRecipient", [CHAINS[name].wormhole]);
    if (!same(pinned, word(home.address))) {
      throw new Error(`the executor's recipient on ${name} is ${pinned}: the owner must call setHomeRecipient(${CHAINS[name].wormhole}, ${word(home.address)})`);
    }
  }
}

// ---------------------------------------------------------------------
// Moving the journal on
// ---------------------------------------------------------------------

const chainOf = (move) => (move.data.chain === "ethereum" ? eth : homes[move.data.chain]);

/// Takes `move` one step further, as far as its chains and the attestation services allow this round.
async function advance(move) {
  if (move.stage === "signed") {
    const adapter = chainOf(move);
    if (!adapter) return log(`move ${move.id}`, `waits: ${move.data.chain} is not served now`);
    if (!(await adapter.resume(move))) return;
    move = journal.get(move.id);
    if (move.stage !== "sent") return;
  }
  if (move.stage === "sent" && move.data.status === "reverted") {
    journal.drop(move.id, "its transaction reverted");
    return log(`move ${move.id}`, `${move.kind} reverted on ${move.data.chain}; dropped`);
  }
  if (["buy", "sell", "draw", "repay"].includes(move.kind)) return journal.advance(move.id, "done");

  if (move.kind === "bridgeIn" || move.kind === "bridgeOut") {
    const into = move.kind === "bridgeIn";
    const from = into ? homes[move.chain] : eth;
    const to = into ? eth : homes[move.chain];
    if (!from || !to) return log(`move ${move.id}`, `waits: ${move.chain} is not served now`);
    if (move.stage === "sent") {
      if (move.data.sequence === undefined) {
        const receipt = await from.client.getTransactionReceipt({ hash: move.data.hash });
        journal.note(move.id, { sequence: (await from.sequenceOf(receipt, from.def.tokenBridge)).toString() });
      }
      const vaa = await wormholescan.vaa(from.def.wormhole, from.def.tokenBridge, journal.get(move.id).data.sequence, to.verifyVaa);
      if (!vaa) return;
      journal.advance(move.id, "attested", { vaa });
    }
    const { vaa } = journal.get(move.id).data;
    if (!(await to.transferCompleted(vaa))) {
      const request = into
        ? { to: cfg.executor, abi: ABI.executor, functionName: "redeemBridged", args: [vaa, coinOf(move.coin).copy] }
        : { to: to.def.tokenBridge, abi: ABI.tokenBridge, functionName: "completeTransfer", args: [vaa] };
      await to.complete(request);
    }
    journal.advance(move.id, "redeemed");
    return log(`move ${move.id}`, `${move.kind} of ${move.coin} landed`);
  }

  // A CCTP move: burned on one side, attested by Circle, received on the other.
  const funding = move.kind === "fund";
  const from = funding ? eth : homes[move.chain];
  const to = funding ? homes[move.chain] : eth;
  if (!from || !to) return log(`move ${move.id}`, `waits: ${move.chain} is not served now`);
  if (move.stage === "sent") {
    const [fromDomain, toDomain] = funding ? [0, CHAINS[move.chain].cctpDomain] : [CHAINS[move.chain].cctpDomain, 0];
    const expect = { destinationDomain: toDomain, recipient: to.address, sender: from.address, amount: BigInt(move.amount) };
    const m = await iris.message(fromDomain, move.data.hash, expect, to.verifyCctp);
    if (!m) return;
    journal.advance(move.id, "attested", m);
  }
  const { message, attestation } = journal.get(move.id).data;
  if (!(await to.cctpReceived(message))) await to.complete(to.receiveRequest(message, attestation));
  journal.advance(move.id, "received");
  log(`move ${move.id}`, `${move.kind} of ${Number(move.amount) / 1e6} USDC landed on ${funding ? move.chain : "ethereum"}`);
}

// ---------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------

/// Pyth's latest price of every served coin, in USD, fresh and narrow; a coin without one is left out.
async function prices() {
  const ids = cfg.coins.map((c) => PRICE_IDS[c.symbol]);
  const latest = await hermes.latest(ids, Date.now() + 5_000);
  const now = Math.floor(Date.now() / 1000);
  const out = new Map();
  for (const c of cfg.coins) {
    const p = latest.get(priceKey(PRICE_IDS[c.symbol]));
    if (!p || p.price <= 0n || now - p.publishTime > FRESH_SECONDS || p.conf * 50n > p.price) continue;
    out.set(c.symbol, Number(p.price) * 10 ** p.expo);
  }
  return out;
}

async function readState() {
  const now = Math.floor(Date.now() / 1000);
  const needs = readNeeds(cfg.needsFile, now);
  const stockReads = await eth.client.multicall({
    allowFailure: false,
    contracts: cfg.coins.flatMap((c) => [
      { address: c.copy, abi: ABI.erc20, functionName: "balanceOf", args: [cfg.executor] },
      { address: cfg.executor, abi: ABI.executor, functionName: "stockAllowance", args: [c.copy] },
      { address: cfg.executor, abi: ABI.executor, functionName: "restockAllowance", args: [c.copy] },
    ]),
  });
  const stock = new Map(cfg.coins.map((c, i) => [c.copy, { balance: stockReads[3 * i], allowance: stockReads[3 * i + 1] }]));
  const restockAllowance = new Map(cfg.coins.map((c, i) => [c.copy, stockReads[3 * i + 2]]));
  const [treasuryUsdc, treasuryAllowance] = await Promise.all([
    eth.balance(MAINNET.usdc),
    eth.read(cfg.executor, ABI.executor, "treasuryUsdcAllowance"),
  ]);
  const home = { coins: new Map(), floats: new Map(), gas: new Map(), funding: journal.funding() };
  for (const [name, h] of Object.entries(homes)) {
    home.floats.set(name, await h.balance(CHAINS[name].float.id));
    home.gas.set(name, await h.balance(null));
    for (const c of cfg.coins.filter((x) => x.chain === name)) home.coins.set(c.symbol, await h.balance(c.home));
  }
  return { needs, stock, restockAllowance, home, treasury: { usdc: treasuryUsdc, allowance: treasuryAllowance } };
}

// ---------------------------------------------------------------------
// Acting
// ---------------------------------------------------------------------

/// The best route for `side` of `amount` of `c` on its home chain, halving the amount, down to RESTOCK_MIN_USD, while
/// none stays within ROUTE_MAX_LOSS_BPS: a thin pool takes the restock in smaller batches rather than none.
async function routeFor(c, side, amount, price) {
  const r = routes[c.chain];
  const block = await homes[c.chain].client.getBlockNumber();
  for (let a = amount; a > 0n; a /= 2n) {
    const usd = (Number(a) / 10 ** c.decimals) * price;
    if (usd < cfg.plan.minUsd) break;
    const route = await r.best({ key: `restock:${block}`, token: c.home, side, amount: a, fairUsd: usd, blockNumber: block });
    if (route) return { route, amount: a, usd };
  }
  return null;
}

async function act(a, price) {
  const c = a.coin ? coinOf(a.coin) : null;
  const h = a.chain ? homes[a.chain] : null;
  if (a.kind === "buy") {
    const pick = await routeFor(c, "buy", a.amountOut, price);
    if (!pick) return log(a.coin, `no route on ${a.chain} within ROUTE_MAX_LOSS_BPS for ${a.usd.toFixed(0)} USD or less`);
    const maxIn = (a.maxIn * pick.amount) / a.amountOut;
    await h.allow(h.def.market.usdc, h.def.router, maxIn);
    const params = { path: pick.route, recipient: h.address, amountOut: pick.amount, amountInMaximum: maxIn };
    await h.commit({ ...a, usd: pick.usd, amountIn: maxIn }, { to: h.def.router, abi: ABI.router, functionName: "exactOutput", args: [params] });
    return log(a.coin, `bought ${pick.usd.toFixed(0)} USD on ${a.chain}`);
  }
  if (a.kind === "sell") {
    const pick = await routeFor(c, "sell", a.amount, price);
    if (!pick) return log(a.coin, `no route on ${a.chain} to sell within ROUTE_MAX_LOSS_BPS`);
    const minOut = (a.minOut * pick.amount) / a.amount;
    await h.allow(c.home, h.def.router, pick.amount);
    const params = { path: pick.route, recipient: h.address, amountIn: pick.amount, amountOutMinimum: minOut };
    await h.commit({ ...a, amount: pick.amount }, { to: h.def.router, abi: ABI.router, functionName: "exactInput", args: [params] });
    return log(a.coin, `sold ${pick.usd.toFixed(0)} USD on ${a.chain}`);
  }
  if (a.kind === "bridgeIn") {
    await h.allow(c.home, h.def.tokenBridge, a.amount);
    const value = await h.messageFee();
    const args = [c.home, a.amount, 2, word(cfg.executor), 0, "0x01"];
    const { id, receipt } = await h.commit(a, { to: h.def.tokenBridge, abi: ABI.tokenBridge, functionName: "transferTokensWithPayload", args, value });
    if (receipt?.status === "success") journal.note(id, { sequence: (await h.sequenceOf(receipt, h.def.tokenBridge)).toString() });
    return log(a.coin, `bridging ${a.usd.toFixed(0)} USD in from ${a.chain}`);
  }
  if (a.kind === "bridgeOut") {
    const value = await eth.messageFee();
    const args = [c.copy, a.amount, CHAINS[a.chain].wormhole];
    const { id, receipt } = await eth.commit(a, { to: cfg.executor, abi: ABI.executor, functionName: "bridgeOut", args, value });
    if (receipt?.status === "success") journal.note(id, { sequence: (await eth.sequenceOf(receipt, eth.def.tokenBridge)).toString() });
    return log(a.coin, `bridging ${a.usd.toFixed(0)} USD out to ${a.chain}`);
  }
  if (a.kind === "fund") {
    await eth.allow(MAINNET.usdc, eth.tokenMessenger, a.amount);
    await eth.commit(a, eth.burnRequest(a.amount, CHAINS[a.chain].cctpDomain, h.address));
    return log(a.chain, `funding its float with ${Number(a.amount) / 1e6} USDC`);
  }
  if (a.kind === "sweep") {
    await h.allow(h.def.market.usdc, h.tokenMessenger, a.amount);
    await h.commit(a, h.burnRequest(a.amount, 0, eth.address));
    return log(a.chain, `bringing ${Number(a.amount) / 1e6} USDC home to the treasury`);
  }
  if (a.kind === "draw") {
    await eth.commit(a, { to: cfg.executor, abi: ABI.executor, functionName: "drawUsdc", args: [a.amount] });
    return log("treasury", `drew ${Number(a.amount) / 1e6} USDC from the executor`);
  }
  if (a.kind === "repay") {
    await eth.allow(MAINNET.usdc, cfg.executor, a.amount);
    await eth.commit(a, { to: cfg.executor, abi: ABI.executor, functionName: "repayUsdc", args: [a.amount] });
    return log("treasury", `repaid ${Number(a.amount) / 1e6} USDC to the executor`);
  }
}

async function round() {
  for (const r of Object.values(routes)) r.forget([]); // each round searches its routes afresh
  for (const move of journal.pending()) {
    await advance(move).catch((error) => log(`move ${move.id}`, `not moved on: ${revertReason(error)}`));
  }
  const p = await prices();
  const state = await readState();
  const { actions, notes } = plan({
    coins: cfg.coins,
    ...state,
    inflight: journal.inflight(),
    prices: p,
    spentUsd: journal.spentUsd(),
    busy: journal.busy(),
    cfg: cfg.plan,
  });
  for (const n of notes) log("plan", n);
  for (const a of actions) {
    await act(a, p.get(a.coin)).catch((error) => log(a.coin ?? a.chain ?? "treasury", `${a.kind} failed: ${revertReason(error)}`));
  }
  journal.prune();
}

let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => (stopping = true));
await checkSetup();
log(`restock ${eth.address}, executor ${cfg.executor}, coins ${cfg.coins.map((c) => c.symbol).join(", ")}`);
while (!stopping) {
  await round().catch((error) => log("round failed:", revertReason(error)));
  if (ONCE) break;
  for (let s = 0; s < cfg.intervalSeconds && !stopping; s++) await new Promise((r) => setTimeout(r, 1000));
}
