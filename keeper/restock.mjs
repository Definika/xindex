#!/usr/bin/env node
// Xindex restock: keeps the keeper's executor stocked with the coins Ethereum has only as Wormhole copies, which no
// Ethereum pool sells, and with the Ondo stocks the keeper values, which few pools sell and UniswapX's fillers do. It
// holds no role in the protocol; its key is the treasury's, a hot key the executor's owner pins, which can only bridge
// stock in and out of the executor, deposit stock it bought, and draw or repay USDC within the owner's allowance.
// See README.md, "Restock".
//
// Every RESTOCK_INTERVAL_SECONDS:
//   1. every move in the journal is taken one step further: a transaction mined, a transfer signed by Wormhole's
//      guardians or attested by Circle, then redeemed or received on the other side;
//   2. it reads what the keeper's fills are short of (NEEDS_FILE), the executor's stock, the treasury's USDC, each home
//      wallet's coins, float and gas, and Pyth's prices, and plans (`restock/plan.mjs`): buy a short coin on its home
//      chain and bridge it in, or, for a coin Ethereum issues, buy it through UniswapX and deposit it
//      (`restock/uniswapx.mjs`), sell and bring home what nobody needs, and move USDC where the buys wait for it;
//   3. it runs the plan, each move recorded in the journal (JOURNAL_FILE) before it is broadcast.
//
// Its home chains are EVM chains: the signers of Solana, Sui, Aptos and Algorand went on 2026-11-25 with the coins they
// served, which had left Ethereum's list (audit/2026-11-25-non-evm-restock-retirement.md).

import { decodeFunctionResult, encodeFunctionData } from "viem";
import { MAINNET } from "./bot/config.mjs";
import { revertReason } from "./bot/chain.mjs";
import { createHermes, priceKey } from "./bot/hermes.mjs";
import { readNeeds } from "./bot/needs.mjs";
import { createAdvance } from "./restock/advance.mjs";
import { cctpMaxFee, createIris, createWormholescan } from "./restock/attestations.mjs";
import { CHAINS, PRICE_IDS } from "./restock/coins.mjs";
import { parseRestockConfig } from "./restock/config.mjs";
import { ABI, createEvm, createEvmHome, word } from "./restock/evm.mjs";
import { createJournal, fileStore, lockJournal, movedOn, resumeOrder } from "./restock/journal.mjs";
import { plan } from "./restock/plan.mjs";
import { PERMIT2, REACTOR, ROUTING, createUniswapXApi, inputMax, nonceSlot, nonceUsed, outputMin, permitTypedData, refusal } from "./restock/uniswapx.mjs";
import { decodeV2Order, orderHash } from "./restock/uniswapx-chain.mjs";

const ONCE = process.argv.includes("--once");
const FRESH_SECONDS = 120;
const log = (...args) => console.log(new Date().toISOString(), ...args);
const cfg = parseRestockConfig(process.env);

// One writer at a time: a second process stops here, before it loads the journal (CA-M12).
process.on("exit", lockJournal(cfg.journalFile));
const journal = createJournal(fileStore(cfg.journalFile));
const hermes = createHermes({ url: cfg.hermesUrl, apiKey: cfg.pythApiKey });
const wormholescan = createWormholescan({ url: process.env.WORMHOLESCAN_URL });
const iris = createIris({ url: process.env.IRIS_URL });
const eth = createEvm({ name: "ethereum", rpcUrl: cfg.rpcUrl, key: cfg.treasuryKey, journal });
const uniswapx = cfg.uniswapx ? createUniswapXApi(cfg.uniswapx) : null;

/// Each home chain's adapter, in the same terms whatever the chain (`restock/evm.mjs` createEvmHome): `check`,
/// `recipientFor`, `forgetRoutes`, `balance`, `buy`, `sell`, `bridgeIn`, `sequenceOfTx`, `redeem`, `transferCompleted`,
/// `sweep`, `receive`, `cctpReceived`, `verifyVaa`, `verifyCctp`, `resume`, with `emitter`, `cctpSender` and
/// `cctpRecipient`.
const homes = {};
for (const [name, chain] of Object.entries(cfg.chains)) {
  const coins = cfg.coins.filter((c) => c.chain === name);
  if (chain.platform === "evm") homes[name] = createEvmHome({ name, rpcUrl: chain.rpcUrl, key: chain.key, journal, cfg: cfg.plan });
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
  if (cfg.coins.some((c) => c.local)) {
    // The reactor every order is signed for, on this chain: its Permit2 is the one the orders' permits name.
    const permit2 = await eth.read(REACTOR, ABI.reactor, "permit2");
    if (!same(permit2, PERMIT2)) throw new Error(`UniswapX's reactor ${REACTOR} answers Permit2 ${permit2}: not the reactor the service signs for`);
    // An executor built before depositStock refuses every deposit with no reason; this one names USDC no stock.
    const refused = await ethCall({ to: cfg.executor, abi: ABI.executor, functionName: "depositStock", args: [MAINNET.usdc, 0n] }).then(
      () => "",
      (error) => revertReason(error),
    );
    if (!refused.includes("NotStock")) throw new Error(`the executor takes no deposit (depositStock answered "${refused}"): it predates the local coins' restock`);
  }
  for (const [name, home] of Object.entries(homes)) {
    await home.check();
    // One recipient per coin and chain, as the executor pins it.
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
  orders: {
    post: (move) => {
      if (!uniswapx) return Promise.reject(new Error("UNISWAP_API_KEY is unset: the order waits for its deadline"));
      return uniswapx.post({ signature: move.data.signature, quote: move.data.quote, routing: move.data.routing });
    },
    filled: async (move) => {
      const { word, bit } = nonceSlot(BigInt(move.data.nonce));
      return nonceUsed(await eth.read(PERMIT2, ABI.permit2, "nonceBitmap", [eth.address, word]), bit);
    },
    chainTime: async () => Number((await eth.client.getBlock()).timestamp),
  },
  coinOf,
  log,
});

// ---------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------

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
  const latest = await hermes.trusted(ids, Date.now() + 5_000, { read: eth.read, call: ethCall, pyth: MAINNET.pyth, abi: ABI.pyth });
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
  // Each home chain is read on its own. One whose node does not answer is left out of this round's plan, its coins
  // neither bought, sold nor bridged, and the others are planned as usual: read in one go, an outage on one chain
  // stopped new work on every chain (CA-R2-11). What is already on its way there stays in the journal.
  const home = { coins: new Map(), floats: new Map(), gas: new Map(), funding: journal.funding() };
  const down = new Set();
  for (const [name, h] of Object.entries(homes)) {
    try {
      const float = await h.balance(CHAINS[name].float.id);
      const gas = await h.balance(null);
      const held = [];
      for (const c of cfg.coins.filter((x) => x.chain === name)) held.push([c.symbol, await h.balance(c.home)]);
      home.floats.set(name, float);
      home.gas.set(name, gas);
      for (const [symbol, balance] of held) home.coins.set(symbol, balance);
    } catch (error) {
      down.add(name);
      log(name, `left out of this round, its balances could not be read: ${revertReason(error)}`);
    }
  }
  // A local coin's home wallet is the treasury, on Ethereum: what it holds of the coin, bought and not yet deposited.
  for (const c of cfg.coins.filter((x) => x.local)) home.coins.set(c.symbol, await eth.balance(c.copy));
  const coins = cfg.coins.filter((c) => !down.has(c.chain));
  return { coins, needs, stock, restockAllowance, home, treasury: { usdc: treasuryUsdc, allowance: treasuryAllowance } };
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
  if (a.kind === "order") return placeOrder(a, c);
  if (a.kind === "deposit") {
    await eth.allow(c.copy, cfg.executor, a.amount);
    await eth.commit(a, { to: cfg.executor, abi: ABI.executor, functionName: "depositStock", args: [c.copy, a.amount] });
    return log(a.coin, `deposited ${a.usd.toFixed(0)} USD of it into the executor`);
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

/// Buys `a.amountIn` of USDC's worth of local coin `c` through UniswapX: asks the API for an order, refuses it unless
/// every field the signature commits to is what the plan allows (`uniswapx.mjs` refusal) and its Permit2 nonce is
/// unspent, lets Permit2 take exactly what the open orders and this one may spend (RS-12), signs typed data built from
/// the checked fields, records the order, and posts it. Its filler pays the coin to the treasury; a later round deposits
/// it.
async function placeOrder(a, c) {
  const offer = await uniswapx.quote({ tokenIn: MAINNET.usdc, tokenOut: c.copy, amount: a.amountIn, swapper: eth.address, chainId: MAINNET.chainId });
  if (!offer) return log(a.coin, `no UniswapX order offered for ${a.usd.toFixed(0)} USD`);
  if (offer.routing !== ROUTING) return log(a.coin, `UniswapX offered a ${offer.routing} route, not a ${ROUTING} order: nothing signed`);
  const order = decodeV2Order(offer.quote.encodedOrder);
  const open = journal.pending().filter((m) => m.kind === "order");
  const now = Number((await eth.client.getBlock()).timestamp);
  const why = refusal(order, {
    swapper: eth.address,
    tokenIn: MAINNET.usdc,
    tokenOut: c.copy,
    maxIn: a.maxIn,
    minOut: a.minOut,
    now,
    openNonces: open.map((m) => BigInt(m.data.nonce)),
  });
  if (why) return log(a.coin, `UniswapX's order refused, nothing signed: ${why}`);
  const { word, bit } = nonceSlot(order.info.nonce);
  if (nonceUsed(await eth.read(PERMIT2, ABI.permit2, "nonceBitmap", [eth.address, word]), bit)) {
    return log(a.coin, "UniswapX's order reuses a spent Permit2 nonce: nothing signed");
  }
  const committed = open.reduce((sum, m) => sum + BigInt(m.data.maxIn), inputMax(order));
  if ((await eth.read(MAINNET.usdc, ABI.erc20, "allowance", [eth.address, PERMIT2])) !== committed) {
    await eth.complete({ to: MAINNET.usdc, abi: ABI.erc20, functionName: "approve", args: [PERMIT2, committed] });
  }
  const signature = await eth.signTypedData(permitTypedData(order, MAINNET.chainId));
  const id = journal.open(a, {
    chain: "ethereum",
    nonce: order.info.nonce.toString(),
    deadline: Number(order.info.deadline),
    maxIn: inputMax(order).toString(),
    minOut: outputMin(order).toString(),
    orderHash: orderHash(order, MAINNET.chainId),
    signature,
    quote: offer.quote,
    routing: offer.routing,
  });
  await advance(journal.get(id));
  const posted = journal.get(id).data.posted ? "posted" : `not yet posted (${journal.get(id).data.postError})`;
  return log(a.coin, `UniswapX order ${id} signed and ${posted}: at most ${Number(inputMax(order)) / 1e6} USDC for at least ${(Number(outputMin(order)) / 10 ** c.decimals).toFixed(6)} of it`);
}

async function round() {
  for (const h of Object.values(homes)) h.forgetRoutes(); // each round searches its routes afresh
  const pending = resumeOrder(journal.pending());
  for (const move of pending) {
    await advance(move).catch((error) => log(`move ${move.id}`, `not moved on: ${revertReason(error)}`));
  }
  // What moved on just now is left out of this round's plan: the state below may be read from a node a block
  // behind the one that mined it (RZ-19).
  const moved = movedOn(pending, (id) => journal.get(id)?.stage);
  const p = await prices();
  const state = await readState();
  const { actions, notes } = plan({
    ...state,
    inflight: journal.inflight(),
    prices: p,
    spentUsd: journal.spentUsd(),
    busy: new Set([...journal.busy(), ...moved]),
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
  await round().catch((error) => {
    log("round failed:", revertReason(error));
    // A one-shot run answers for its round: a scheduler must not record one that planned nothing as a success
    // (CA-R2-20).
    if (ONCE) process.exitCode = 1;
  });
  if (ONCE) break;
  for (let s = 0; s < cfg.intervalSeconds && !stopping; s++) await new Promise((r) => setTimeout(r, 1000));
}
