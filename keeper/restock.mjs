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
//
// `node restock.mjs --attest <chain> <token>` instead attests one token on a served home chain for its Wormhole copy on
// Ethereum, the owner's step before a copy can be listed (restock/attest.mjs, PD-7), and exits.

import { decodeFunctionResult, encodeFunctionData } from "viem";
import { MAINNET } from "./bot/config.mjs";
import { revertReason } from "./bot/chain.mjs";
import { createHermes, priceKey } from "./bot/hermes.mjs";
import { readNeeds } from "./bot/needs.mjs";
import { createAdvance } from "./restock/advance.mjs";
import { attestToken } from "./restock/attest.mjs";
import { cctpMaxFee, createIris, createWormholescan } from "./restock/attestations.mjs";
import { CHAINS, PRICE_IDS } from "./restock/coins.mjs";
import { parseRestockConfig } from "./restock/config.mjs";
import { ABI, createEvm, createEvmHome, word } from "./restock/evm.mjs";
import { createSolanaHome } from "./restock/solana.mjs";
import { createSuiHome } from "./restock/sui.mjs";
import { createAptosHome } from "./restock/aptos.mjs";
import { createAlgorandHome } from "./restock/algorand.mjs";
import { createJournal, fileStore, resumeOrder } from "./restock/journal.mjs";
import { plan } from "./restock/plan.mjs";

const ONCE = process.argv.includes("--once");
const ATTEST = process.argv.indexOf("--attest");
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
  else if (chain.platform === "aptos") homes[name] = createAptosHome({ settings: chain, coins, journal, cfg: cfg.plan, verifyVaa: eth.verifyVaa });
  else if (chain.platform === "algorand") homes[name] = createAlgorandHome({ settings: chain, coins, journal, cfg: cfg.plan, verifyVaa: eth.verifyVaa });
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

/// Takes a move one step further, as far as its chains and the attestation services allow this round
/// (restock/advance.mjs).
const advance = createAdvance({
  journal,
  eth,
  homes,
  wormholescan,
  iris,
  redeemIn: (vaa, copy) => eth.complete({ to: cfg.executor, abi: ABI.executor, functionName: "redeemBridged", args: [vaa, copy] }),
  coinOf,
  log,
});

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
    // The route's standard fee, from Circle's table, within MAX_CCTP_FEE_BPS (PD-12).
    const maxFee = cctpMaxFee(a.amount, await iris.fees(0, CHAINS[a.chain].cctpDomain));
    await eth.allow(MAINNET.usdc, eth.tokenMessenger, a.amount);
    await eth.commit(a, eth.burnRequest(a.amount, CHAINS[a.chain].cctpDomain, h.cctpRecipient, maxFee));
    return log(a.chain, `funding its float with ${Number(a.amount) / 1e6} USDC`);
  }
  if (a.kind === "sweep") {
    await h.sweep(a, eth.address, cctpMaxFee(a.amount, await iris.fees(CHAINS[a.chain].cctpDomain, 0)));
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
  for (const move of resumeOrder(journal.pending())) {
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

if (ATTEST >= 0) {
  const [chain, token] = process.argv.slice(ATTEST + 1);
  const home = homes[chain];
  if (!home?.attest) throw new Error(`--attest needs a served chain whose signer attests (${Object.keys(homes).filter((n) => homes[n].attest).join(", ") || "none served"}), then a token`);
  if (!token) throw new Error("--attest needs the token to attest after the chain");
  await home.check();
  await attestToken({
    home,
    wormholeChain: CHAINS[chain].wormhole,
    token,
    wormholescan,
    verifyVaa: eth.verifyVaa,
    wrappedAsset: (tokenChain, tokenAddress) => eth.read(MAINNET.tokenBridge, ABI.tokenBridge, "wrappedAsset", [tokenChain, tokenAddress]),
    submit: (functionName, vaa) => eth.complete({ to: MAINNET.tokenBridge, abi: ABI.tokenBridge, functionName, args: [vaa] }),
    log,
  });
  process.exit(0);
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
