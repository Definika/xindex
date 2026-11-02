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
//   4. the admin events monitors watch (RT-07): a keep-mask start, a cancel, and the factory's guardian, owner,
//      listing and fee-policy events, as notices.
// Each finding prints as one JSON line when raised and when cleared; breaches and reader findings also go to
// ALERT_WEBHOOK. With --once it runs one round and exits 1 if anything but a notice stands.

import { readFileSync } from "node:fs";
import { createPublicClient, http, keccak256, numberToHex, pad, parseAbi, toHex } from "viem";
import { mainnet, sepolia } from "viem/chains";
import { HUB_STATE_SLOTS } from "./bot/config.mjs";
import { checkEscrows, checkIndex, checkProgress, componentWord, diffFindings, lower, requestEscrow, scaleWord } from "./invariants/check.mjs";
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

/// What the factory's admin events and the hubs' auction events say, as notices (RT-07).
const FACTORY_NOTICES = new Set([
  "GuardianProposed",
  "GuardianChangeCancelled",
  "GuardianSet",
  "OwnershipTransferStarted",
  "OwnershipTransferred",
  "ListingProposed",
  "ListingCancelled",
  "TokenWhitelisted",
  "TokenTermsSet",
  "FeePolicySet",
]);
const events = (abi, names) => abi.filter((x) => x.type === "event" && names.has(x.name));
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
let requestsSeen = 0n;

async function requestFindings(blockNumber) {
  const request = (id) => ({ address: cfg.requests, abi: ABI.requests, functionName: "getRequest", args: [id] });
  const [count] = await multicall([{ address: cfg.requests, abi: ABI.requests, functionName: "requestCount" }], blockNumber);
  const ids = [...openRequests.keys()];
  for (let id = requestsSeen + 1n; id <= count; ++id) ids.push(id);
  requestsSeen = count;
  const read = await multicall(ids.map(request), blockNumber);
  ids.forEach((id, i) => (read[i].open ? openRequests.set(id, read[i]) : openRequests.delete(id)));
  const escrows = [...openRequests.values()].map(requestEscrow);
  return checkEscrows("requests-escrow", cfg.requests, escrows, await balancesOf(cfg.requests, escrows, blockNumber));
}

/// The builder's (user, token) pairs that ever held an escrow: every credit names its user, and its token or its index,
/// whose components it credits.
const builderPairs = new Map();
let builderLogsTo = null;

async function builderFindings(blockNumber) {
  const credits = events(ABI.builder, new Set(["Deposited", "Bought", "Redeemed", "Unsold"]));
  const from = builderLogsTo === null ? cfg.fromBlock : builderLogsTo + 1n;
  for (const log of await logs(cfg.builder, credits, from, blockNumber)) {
    const user = lower(log.args.user);
    const tokens = log.args.token ? [lower(log.args.token)] : await componentsAt(lower(log.args.index), blockNumber);
    if (!builderPairs.has(user)) builderPairs.set(user, new Set());
    for (const token of tokens) builderPairs.get(user).add(token);
  }
  builderLogsTo = blockNumber;
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

/// `holder`'s balance of every token `escrows` names, by lowercase token.
async function balancesOf(holder, escrows, blockNumber) {
  const tokens = [...new Set(escrows.map((e) => lower(e.token)))];
  const read = await multicall(
    tokens.map((t) => ({ address: t, abi: ABI.erc20, functionName: "balanceOf", args: [holder] })),
    blockNumber,
    { optional: true },
  );
  return new Map(tokens.map((t, i) => [t, read[i] ?? 0n]));
}

let noticesTo = null;

async function notices(blockNumber) {
  const from = noticesTo === null ? (cfg.fromBlock ?? blockNumber) : noticesTo + 1n;
  noticesTo = blockNumber;
  if (from > blockNumber) return [];
  const found = [];
  for (const log of await logs(cfg.factory, events(ABI.factory, FACTORY_NOTICES), from, blockNumber)) {
    found.push({ level: "notice", code: log.eventName, block: log.blockNumber, tx: log.transactionHash, ...log.args });
  }
  if (indexes.length === 0) return found;
  const auction = events(ABI.hub, new Set(["RebalanceStarted", "RebalanceCancelled"]));
  for (const log of await logs(indexes, auction, from, blockNumber)) {
    if (log.eventName === "RebalanceStarted" && log.args.keepMask === 0n) continue;
    const { eventName, address, blockNumber: block, transactionHash: tx, args } = log;
    found.push({ level: "notice", code: eventName, index: lower(address), block, tx, ...args });
  }
  return found;
}

// ---------------------------------------------------------------------------------------------------------------------
// Rounds and alerts
// ---------------------------------------------------------------------------------------------------------------------

async function alert(record) {
  if (!cfg.alertWebhook) return;
  const text = `Xindex invariant checker: ${JSON.stringify(record, (_, v) => (typeof v === "bigint" ? v.toString() : v))}`;
  try {
    await fetch(cfg.alertWebhook, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ text, content: text }) });
  } catch (error) {
    print({ level: "reader", code: "webhook", why: error.message });
  }
}

let standing = new Set();

async function round() {
  const block = await client.getBlock();
  const blockNumber = block.number;
  await readIndexes(blockNumber);
  const findings = await indexFindings(blockNumber, block.timestamp);
  if (cfg.requests) findings.push(...(await requestFindings(blockNumber)));
  if (cfg.builder) findings.push(...(await builderFindings(blockNumber)));

  const diff = diffFindings(standing, findings);
  standing = diff.standing;
  for (const f of diff.raised) {
    print({ block: blockNumber, raised: true, ...f });
    if (f.level !== "notice") await alert({ block: blockNumber, ...f });
  }
  for (const key of diff.cleared) {
    print({ block: blockNumber, cleared: key });
    if (!key.startsWith("unreadable:")) await alert({ block: blockNumber, cleared: key });
  }
  for (const n of await notices(blockNumber)) print(n);
  const failing = findings.filter((f) => f.level !== "notice").length;
  print({ block: blockNumber, indexes: indexes.length, findings: findings.length, failing });
  return failing;
}

/// One round; a round the RPC could not serve is itself a reader finding, so it counts as failing.
async function guardedRound() {
  try {
    return await round();
  } catch (error) {
    print({ level: "reader", code: "round", why: `${error.shortMessage ?? error.message} ${error.details ?? ""}`.trim() });
    return 1;
  }
}

if (ONCE) process.exit((await guardedRound()) === 0 ? 0 : 1);
for (;;) {
  await guardedRound();
  await new Promise((resolve) => setTimeout(resolve, cfg.pollSeconds * 1000));
}
