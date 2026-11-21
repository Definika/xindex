#!/usr/bin/env node
// Xindex invariant checker: reads every index of a factory, and MintRequests and the BasketBuilder when named, at one
// block per round, and reports any property of theirs that does not hold (invariants/check.mjs). It holds no key and
// sends nothing. See README.md, "Invariant checker".
//
// Every POLL_SECONDS, at the latest block:
//   1. every index: the backing invariant on the recorded supply, units and scale (slots HUB_STATE_SLOTS, which no
//      view returns, cross-checked against the views first), the pending auction's clock (the state machine's I1 to
//      I4), and against the last round, that the components never change, the units move only at a fill and the
//      scale only shrinks;
//   2. MintRequests: its balance of each token covers the open requests' escrows;
//   3. the BasketBuilder: its balance of each token covers its users' escrows, the pairs found from its events;
//   4. the admin events monitors watch (RT-07): every start, the quote posted with one, a cancel, and the factory's
//      guardian, owner, listing, creator-approval and fee-policy events, as notices.
// Each finding prints as one JSON line when raised and when cleared; breaches and reader findings also go to
// ALERT_WEBHOOK, queued until it has taken them. A finding on something a round could not read stands until a read
// shows it gone. A round the RPC could not serve, or served from a head that has stopped moving, is a reader finding
// too. With --once it runs one round and exits 1 if anything but a notice stands.

import { readFileSync } from "node:fs";
import { createPublicClient, http, keccak256, numberToHex, pad, parseAbi, toHex } from "viem";
import { mainnet, sepolia } from "viem/chains";
import { HUB_STATE_SLOTS } from "./bot/config.mjs";
import {
  FACTORY_NOTICES,
  HUB_NOTICES,
  checkEscrows,
  checkHead,
  checkIndex,
  checkProgress,
  componentWord,
  createAlerts,
  createCursor,
  diffFindings,
  lower,
  requestEscrow,
  scaleWord,
} from "./invariants/check.mjs";
import { parseInvariantsConfig } from "./invariants/config.mjs";

const ONCE = process.argv.includes("--once");
const cfg = parseInvariantsConfig(process.env);
const load = (path) => JSON.parse(readFileSync(new URL(path, import.meta.url), "utf8"));
const ABI = {
  hub: load("../abi/WeightedHub.json"),
  factory: load("../abi/WeightedIndexFactory.json"),
  requests: load("../abi/MintRequests.json"),
  builder: load("../abi/BasketBuilder.json"),
  erc20: parseAbi(["function balanceOf(address) view returns (uint256)"]),
};
const client = createPublicClient({
  chain: { 1: mainnet, 11155111: sepolia }[cfg.chain.chainId],
  transport: http(cfg.rpcUrl, { batch: { batchSize: 50 }, retryCount: 3 }),
});

const events = (abi, names) => abi.filter((x) => x.type === "event" && names.includes(x.name));
const COMPONENTS_BASE = BigInt(keccak256(pad(toHex(HUB_STATE_SLOTS.components), { size: 32 })));

const print = (record) => console.log(JSON.stringify(record, (_, v) => (typeof v === "bigint" ? v.toString() : v)));

// ---------------------------------------------------------------------------------------------------------------------
// Reads, all at one block
// ---------------------------------------------------------------------------------------------------------------------

/// The results of `calls`, each { address, abi, functionName, args }; a failed call is null where `optional`.
async function multicall(calls, blockNumber, { optional = false } = {}) {
  if (calls.length === 0) return [];
  const results = await client.multicall({ contracts: calls, blockNumber, allowFailure: true });
  return results.map((r, i) => {
    if (r.status === "success") return r.result;
    if (optional) return null;
    throw new Error(`${calls[i].functionName} on ${calls[i].address} failed: ${r.error?.shortMessage ?? r.error}`);
  });
}

async function storage(address, slot, blockNumber) {
  const word = await client.getStorageAt({ address, slot: numberToHex(slot, { size: 32 }), blockNumber });
  return BigInt(word ?? 0);
}

/// Logs of `abiEvents` from `address` over [from, to], in chunks of LOG_CHUNK blocks.
async function logs(address, abiEvents, from, to) {
  const found = [];
  for (let start = from; start <= to; start += cfg.logChunk) {
    const end = start + cfg.logChunk - 1n < to ? start + cfg.logChunk - 1n : to;
    found.push(...(await client.getLogs({ address, events: abiEvents, fromBlock: start, toBlock: end, strict: true })));
  }
  return found;
}

const indexes = [];
const componentsOf = new Map();

async function readIndexes(blockNumber) {
  const [count] = await multicall([{ address: cfg.factory, abi: ABI.factory, functionName: "allIndexesLength" }], blockNumber);
  const ids = [];
  for (let i = BigInt(indexes.length); i < count; ++i) ids.push(i);
  const added = await multicall(
    ids.map((i) => ({ address: cfg.factory, abi: ABI.factory, functionName: "allIndexes", args: [i] })),
    blockNumber,
  );
  indexes.push(...added.map(lower));
}

/// Everything `checkIndex` reads of `index` at `blockNumber`.
async function snapshot(index, blockNumber, now) {
  const hub = (functionName, args = []) => ({ address: index, abi: ABI.hub, functionName, args });
  const [tokens, [, viewUnits], [, pendingScale], lastAccrual, supply, [eta, keepMask], earliest, restartAllowedAt, proposalCount, rebalanceNonce, lastRebalance, rebalanceDelay] =
    await multicall(
      [
        hub("componentTokens"),
        hub("components"),
        hub("pendingStreamingFee"),
        hub("lastAccrual"),
        hub("totalSupply"),
        hub("pendingRebalance"),
        hub("earliestRebalance"),
        hub("restartAllowedAt"),
        hub("proposalCount"),
        hub("rebalanceNonce"),
        hub("lastRebalance"),
        hub("REBALANCE_DELAY"),
      ],
      blockNumber,
    );
  componentsOf.set(index, tokens.map(lower));
  const [length, word3, ...words] = await Promise.all([
    storage(index, HUB_STATE_SLOTS.components, blockNumber),
    storage(index, HUB_STATE_SLOTS.scale, blockNumber),
    ...tokens.map((_, i) => storage(index, COMPONENTS_BASE + BigInt(i), blockNumber)),
  ]);
  const claims = await multicall(tokens.map((t) => hub("totalClaims", [t])), blockNumber);
  const balances = await multicall(
    tokens.map((t) => ({ address: t, abi: ABI.erc20, functionName: "balanceOf", args: [index] })),
    blockNumber,
    { optional: true },
  );
  return {
    index,
    now,
    rebalanceDelay,
    tokens,
    viewUnits,
    pendingScale,
    lastAccrual: BigInt(lastAccrual),
    length,
    words,
    word3,
    supply,
    claims,
    balances,
    eta,
    keepMask,
    earliest,
    restartAllowedAt,
    proposalCount,
    rebalanceNonce,
    lastRebalance,
  };
}

// ---------------------------------------------------------------------------------------------------------------------
// The checks
// ---------------------------------------------------------------------------------------------------------------------

const recorded = new Map();

async function indexFindings(blockNumber, now) {
  const findings = [];
  for (const index of indexes) {
    let s;
    try {
      s = await snapshot(index, blockNumber, now);
    } catch (error) {
      findings.push({ level: "reader", code: "read", index, why: error.shortMessage ?? error.message });
      continue;
    }
    const found = checkIndex(s);
    findings.push(...found);
    if (found.some((f) => f.level === "reader")) continue;
    const state = {
      tokens: s.tokens.map(lower),
      units: s.words.map((w) => componentWord(w).units),
      scale: scaleWord(s.word3).scale,
      proposalCount: s.proposalCount,
      rebalanceNonce: s.rebalanceNonce,
      lastRebalance: s.lastRebalance,
    };
    if (recorded.has(index)) findings.push(...checkProgress(index, recorded.get(index), state));
    recorded.set(index, state);
  }
  return findings;
}

const openRequests = new Map();
/// The request ids not read yet, from the first: moved on only once their reads are in (CA-M16).
const newRequests = createCursor(1n);

async function requestFindings(blockNumber) {
  const request = (id) => ({ address: cfg.requests, abi: ABI.requests, functionName: "getRequest", args: [id] });
  const fold = (ids, read) => ids.forEach((id, i) => (read[i].open ? openRequests.set(id, read[i]) : openRequests.delete(id)));
  const [count] = await multicall([{ address: cfg.requests, abi: ABI.requests, functionName: "requestCount" }], blockNumber);
  const known = [...openRequests.keys()];
  fold(known, await multicall(known.map(request), blockNumber));
  await newRequests(count, async (from, to) => {
    const ids = [];
    for (let id = from; id <= to; ++id) ids.push(id);
    fold(ids, await multicall(ids.map(request), blockNumber));
  });
  const escrows = [...openRequests.values()].map(requestEscrow);
  return checkEscrows("requests-escrow", cfg.requests, escrows, await balancesOf(cfg.requests, escrows, blockNumber));
}

/// The builder's (user, token) pairs that ever held an escrow: every credit names its user, and its token or its index,
/// whose components it credits.
const builderPairs = new Map();
/// The builder's blocks not read yet, from FROM_BLOCK: moved on only once their logs are in (CA-M16).
const builderBlocks = createCursor(cfg.fromBlock);

async function builderFindings(blockNumber) {
  const credits = events(ABI.builder, ["Deposited", "Bought", "Redeemed", "Unsold"]);
  await builderBlocks(blockNumber, async (from, to) => {
    for (const log of await logs(cfg.builder, credits, from, to)) {
      const user = lower(log.args.user);
      const tokens = log.args.token ? [lower(log.args.token)] : await componentsAt(lower(log.args.index), blockNumber);
      if (!builderPairs.has(user)) builderPairs.set(user, new Set());
      for (const token of tokens) builderPairs.get(user).add(token);
    }
  });
  const pairs = [...builderPairs].flatMap(([user, tokens]) => [...tokens].map((token) => ({ user, token })));
  const amounts = await multicall(
    pairs.map(({ user, token }) => ({ address: cfg.builder, abi: ABI.builder, functionName: "escrowOf", args: [user, token] })),
    blockNumber,
  );
  const escrows = pairs.map(({ token }, i) => ({ token, amount: amounts[i] }));
  return checkEscrows("builder-escrow", cfg.builder, escrows, await balancesOf(cfg.builder, escrows, blockNumber));
}

async function componentsAt(index, blockNumber) {
  if (!componentsOf.has(index)) {
    const [tokens] = await multicall([{ address: index, abi: ABI.hub, functionName: "componentTokens" }], blockNumber);
    componentsOf.set(index, tokens.map(lower));
  }
  return componentsOf.get(index);
}

/// `holder`'s balance of every token `escrows` names, by lowercase token; null where the read failed (CA-L9).
async function balancesOf(holder, escrows, blockNumber) {
  const tokens = [...new Set(escrows.map((e) => lower(e.token)))];
  const read = await multicall(
    tokens.map((t) => ({ address: t, abi: ABI.erc20, functionName: "balanceOf", args: [holder] })),
    blockNumber,
    { optional: true },
  );
  return new Map(tokens.map((t, i) => [t, read[i]]));
}

/// The blocks whose admin events are not read yet, from FROM_BLOCK, or from the checker's first block: moved on only
/// once both reads are in (CA-M16).
const noticeBlocks = createCursor(cfg.fromBlock);

async function notices(blockNumber) {
  const found = await noticeBlocks(blockNumber, async (from, to) => {
    const read = [];
    for (const log of await logs(cfg.factory, events(ABI.factory, FACTORY_NOTICES), from, to)) {
      read.push({ level: "notice", code: log.eventName, block: log.blockNumber, tx: log.transactionHash, ...log.args });
    }
    if (indexes.length === 0) return read;
    for (const log of await logs(indexes, events(ABI.hub, HUB_NOTICES), from, to)) {
      const { eventName, address, blockNumber: block, transactionHash: tx, args } = log;
      read.push({ level: "notice", code: eventName, index: lower(address), block, tx, ...args });
    }
    return read;
  });
  return found ?? [];
}

// ---------------------------------------------------------------------------------------------------------------------
// Rounds and alerts
// ---------------------------------------------------------------------------------------------------------------------

/// Posts `record` to the webhook; true once it answered 2xx. A webhook that fails, hangs past ten seconds or answers
/// anything else has not taken the alert, which stays queued (CA-M18).
async function post(record) {
  const text = `Xindex invariant checker: ${JSON.stringify(record, (_, v) => (typeof v === "bigint" ? v.toString() : v))}`;
  try {
    const answer = await fetch(cfg.alertWebhook, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text, content: text }),
      signal: AbortSignal.timeout(10_000),
    });
    if (answer.ok) return true;
    print({ level: "reader", code: "webhook", why: `the webhook answered ${answer.status}` });
  } catch (error) {
    print({ level: "reader", code: "webhook", why: error.message });
  }
  return false;
}
const alerts = createAlerts({ send: post });
const alert = (record) => cfg.alertWebhook && alerts.push(record);

/// A part of the round that reads on its own: its findings, or, when its reads failed, one reader finding naming the
/// contract it could not look at, so the other parts are still reported and what stood on this one stands.
async function section(holder, read) {
  try {
    return await read();
  } catch (error) {
    return [{ level: "reader", code: "read", holder, why: error.shortMessage ?? error.message }];
  }
}

let standing = new Set();

async function round() {
  const block = await client.getBlock();
  const blockNumber = block.number;
  await readIndexes(blockNumber);
  const findings = checkHead(block.timestamp, Math.floor(Date.now() / 1000), cfg.maxHeadAgeSeconds);
  findings.push(...(await indexFindings(blockNumber, block.timestamp)));
  if (cfg.requests) findings.push(...(await section(cfg.requests, () => requestFindings(blockNumber))));
  if (cfg.builder) findings.push(...(await section(cfg.builder, () => builderFindings(blockNumber))));

  const diff = diffFindings(standing, findings);
  standing = diff.standing;
  for (const f of diff.raised) {
    print({ block: blockNumber, raised: true, ...f });
    if (f.level !== "notice") alert({ block: blockNumber, ...f });
  }
  for (const key of diff.cleared) {
    print({ block: blockNumber, cleared: key });
    if (!key.startsWith("unreadable:")) alert({ block: blockNumber, cleared: key });
  }
  for (const n of await notices(blockNumber)) print(n);
  const failing = findings.filter((f) => f.level !== "notice").length;
  print({ block: blockNumber, indexes: indexes.length, findings: findings.length, failing });
  return failing;
}

/// One round; a round the RPC could not serve is itself a reader finding, so it counts as failing, and is alerted
/// once when the rounds start failing and once when they are served again (CA-M18). The queued alerts are sent after
/// every round, served or not.
let unserved = false;
async function guardedRound() {
  let failing = 1;
  try {
    failing = await round();
    if (unserved) alert({ cleared: "round" });
    unserved = false;
  } catch (error) {
    const record = { level: "reader", code: "round", why: `${error.shortMessage ?? error.message} ${error.details ?? ""}`.trim() };
    print(record);
    if (!unserved) alert(record);
    unserved = true;
  }
  const { queued, dropped } = await alerts.flush();
  if (queued || dropped) print({ level: "reader", code: "webhook", queued, dropped, why: "alerts the webhook has not taken" });
  return failing;
}

/// Refuses to run against another chain or another deployment than the one configured: either would answer every
/// read, and an empty registry there reads as a healthy one here (CA-L12).
async function checkSetup() {
  const chainId = await client.getChainId();
  if (chainId !== cfg.chain.chainId) throw new Error(`RPC_URL serves chain ${chainId}, not CHAIN_ID ${cfg.chain.chainId}`);
  for (const [name, address, abi] of [["REQUESTS", cfg.requests, ABI.requests], ["BUILDER", cfg.builder, ABI.builder]]) {
    if (!address) continue;
    const factory = lower(await client.readContract({ address, abi, functionName: "FACTORY" }));
    if (factory !== cfg.factory) throw new Error(`${name} ${address} serves the factory ${factory}, not FACTORY ${cfg.factory}`);
  }
}

await checkSetup();
if (ONCE) process.exit((await guardedRound()) === 0 ? 0 : 1);
for (;;) {
  await guardedRound();
  await new Promise((resolve) => setTimeout(resolve, cfg.pollSeconds * 1000));
}
