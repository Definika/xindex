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
import { revertReason } from "./bot/chain.mjs";
import { createHermes, priceKey } from "./bot/hermes.mjs";
import { readNeeds } from "./bot/needs.mjs";
import { createIris, createWormholescan } from "./restock/attestations.mjs";
import { CHAINS, PRICE_IDS } from "./restock/coins.mjs";
import { parseRestockConfig } from "./restock/config.mjs";
import { ABI, createEvm, createEvmHome, word } from "./restock/evm.mjs";
import { createSolanaHome } from "./restock/solana.mjs";
import { createSuiHome } from "./restock/sui.mjs";
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

/// Each home chain's adapter, in the same terms whatever the chain (`restock/evm.mjs` createEvmHome): `check`,
/// `recipientFor`, `forgetRoutes`, `balance`, `buy`, `sell`, `bridgeIn`, `sequenceOfTx`, `redeem`, `transferCompleted`,
/// `sweep`, `receive`, `cctpReceived`, `verifyVaa`, `verifyCctp`, `resume`, with `emitter`, `cctpSender` and
/// `cctpRecipient`.
const homes = {};
for (const [name, chain] of Object.entries(cfg.chains)) {
  const coins = cfg.coins.filter((c) => c.chain === name);
  if (chain.platform === "evm") homes[name] = createEvmHome({ name, rpcUrl: chain.rpcUrl, key: chain.key, journal, cfg: cfg.plan });
  else if (chain.platform === "solana") homes[name] = createSolanaHome({ settings: chain, coins, journal, cfg: cfg.plan, verifyVaa: eth.verifyVaa });
  else if (chain.platform === "sui") homes[name] = createSuiHome({ settings: chain, coins, journal, cfg: cfg.plan, verifyVaa: eth.verifyVaa });
  else throw new Error(`${name}'s coins (${coins.map((c) => c.symbol).join(", ")}) need their ${chain.platform} adapter; leave them out of RESTOCK_COINS`);
}
const coinOf = (symbol) => cfg.coins.find((c) => c.symbol === symbol);
const same = (a, b) => a.toLowerCase() === b.toLowerCase();

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
    await home.check();
    // One recipient per coin and chain: Solana's bridge pays a token account per mint, so the executor pins each coin.
    for (const c of cfg.coins.filter((x) => x.chain === name)) {
      const pinned = await ex("homeRecipient", [CHAINS[name].wormhole, c.copy]);
      const wanted = await home.recipientFor(c);
      if (!same(pinned, wanted)) {
        throw new Error(`the executor's recipient for ${c.symbol} on ${name} is ${pinned}: the owner must call setHomeRecipient(${CHAINS[name].wormhole}, ${c.copy}, ${wanted})`);
      }
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
      if (move.data.sequence === undefined) journal.note(move.id, { sequence: (await from.sequenceOfTx(move.data.hash)).toString() });
      const vaa = await wormholescan.vaa(from.def.wormhole, from.emitter, journal.get(move.id).data.sequence, to.verifyVaa);
      if (!vaa) return;
      journal.advance(move.id, "attested", { vaa });
    }
    const { vaa } = journal.get(move.id).data;
    if (!(await to.transferCompleted(vaa))) {
      // The copy the journal recorded when the move opened, so a coin dropped from RESTOCK_COINS while its transfer
      // was on its way is still redeemed (RZ-18).
      if (into) await eth.complete({ to: cfg.executor, abi: ABI.executor, functionName: "redeemBridged", args: [vaa, move.copy ?? coinOf(move.coin).copy] });
      else await to.redeem(vaa);
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
    const expect = { destinationDomain: toDomain, recipient: to.cctpRecipient, sender: from.cctpSender, amount: BigInt(move.amount) };
    const m = await iris.message(fromDomain, move.data.hash, expect, to.verifyCctp, CHAINS[move.chain].cctpVersion);
    if (!m) return;
    journal.advance(move.id, "attested", m);
  }
  const { message, attestation } = journal.get(move.id).data;
  if (!(await to.cctpReceived(message))) await to.receive(message, attestation);
  journal.advance(move.id, "received");
  log(`move ${move.id}`, `${move.kind} of ${Number(move.amount) / 1e6} USDC landed on ${funding ? move.chain : "ethereum"}`);
}

// ---------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------

/// Pyth's contract, read once from the executor's factory, as the keeper reads it.
let pythContract;
async function pyth() {
  if (!pythContract) {
    const factory = await eth.read(cfg.executor, ABI.executor, "FACTORY");
    pythContract = await eth.read(factory, ABI.factory, "PYTH");
  }
  return pythContract;
}

/// An `eth_call` from the treasury on Ethereum, with `value`, decoded; what Pyth's parse needs its fee sent as.
async function ethCall({ to, abi, functionName, args, value = 0n }) {
  const data = encodeFunctionData({ abi, functionName, args });
  const { data: result } = await eth.client.call({ account: eth.address, to, data, value });
  return decodeFunctionResult({ abi, functionName, data: result });
}

/// Pyth's latest price of every served coin, in USD, verified by Pyth's contract on Ethereum, fresh and narrow; a coin
/// without one is left out. Verified, not taken from Hermes' JSON (RX-9, RY-6): the plan sizes every buy's
/// `amountInMaximum` and every sale's `amountOutMinimum` at these prices and judges each route against them, so a
/// forged price would have set the bounds a sandwich takes to.
async function prices() {
  const ids = cfg.coins.map((c) => PRICE_IDS[c.symbol]);
  const latest = await hermes.trusted(ids, Date.now() + 5_000, { read: eth.read, call: ethCall, pyth: await pyth(), abi: ABI.pyth });
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

async function act(a, price) {
  const c = a.coin ? coinOf(a.coin) : null;
  const h = a.chain ? homes[a.chain] : null;
  if (a.kind === "buy") {
    const done = await h.buy(a, c, price);
    if (!done) return log(a.coin, `no route on ${a.chain} within ROUTE_MAX_LOSS_BPS for ${a.usd.toFixed(0)} USD or less`);
    return log(a.coin, `bought ${done.usd.toFixed(0)} USD on ${a.chain}`);
  }
  if (a.kind === "sell") {
    const done = await h.sell(a, c, price);
    if (!done) return log(a.coin, `no route on ${a.chain} to sell within ROUTE_MAX_LOSS_BPS`);
    return log(a.coin, `sold ${done.usd.toFixed(0)} USD on ${a.chain}`);
  }
  if (a.kind === "bridgeIn") {
    await h.bridgeIn(a, c, word(cfg.executor));
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
    const version = CHAINS[a.chain].cctpVersion;
    await eth.allow(MAINNET.usdc, eth.tokenMessengerFor(version), a.amount);
    await eth.commit(a, eth.burnRequest(a.amount, CHAINS[a.chain].cctpDomain, h.cctpRecipient, version));
    return log(a.chain, `funding its float with ${Number(a.amount) / 1e6} USDC`);
  }
  if (a.kind === "sweep") {
    await h.sweep(a, eth.address);
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

/// CCTP V2 lets a Solana burn's event account be closed for its rent five days after the burn; the journal keeps a
/// received burn seven days, so the reclaim lands in between, with the burn's message and attestation.
const RECLAIM_AFTER_SECONDS = 5 * 86_400 + 600;

async function reclaimRent() {
  const now = Math.floor(Date.now() / 1000);
  const due = (m) => m.kind === "sweep" && m.stage === "received" && m.data.eventAccount && !m.data.reclaimed && now - m.at >= RECLAIM_AFTER_SECONDS;
  for (const m of journal.find(due)) {
    const h = homes[m.chain];
    if (!h?.reclaim) continue;
    await h
      .reclaim(m.data.eventAccount, m.data.message, m.data.attestation)
      .then(() => journal.note(m.id, { reclaimed: true }))
      .catch((error) => log(`move ${m.id}`, `rent not reclaimed: ${revertReason(error)}`));
  }
}

async function round() {
  for (const h of Object.values(homes)) h.forgetRoutes(); // each round searches its routes afresh
  for (const move of journal.pending()) {
    await advance(move).catch((error) => log(`move ${move.id}`, `not moved on: ${revertReason(error)}`));
  }
  await reclaimRent();
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
