// The rates of the wrapped coins the keeper values: a wrapped xStock is worth `convertToAssets` xStocks, and its feed
// prices one xStock (script/PythIds.sol, design/2026-11-21-xstocks.md). Nothing here is a price: a rate is read from
// the wrapper itself, at the block every other read of the round is pinned to, and again some blocks earlier, and a
// rate that has moved further between the two than a dividend moves it values nothing (math.mjs, `rateSteady`). No
// dependency: the chain and the wrapper's ABI are handed in, so the unit tests run without `npm install`.

import { MAX_RATE_MOVE_BPS, RATE_LOOKBACK_BLOCKS } from "./config.mjs";
import * as M from "./math.mjs";

/// Which legs are share-priced (RX-2): a leg whose id is one of `sharePricedIds`, the feeds that price a share or an
/// xStock rather than a token, and that wraps nothing the bot reads a rate for (`assetDecimals[i]` null). A wrapped
/// coin is never one, though six wrappers take a feed an Ondo leg takes too; a token at a wrapper's feed that the
/// bot does not know as a wrapper always is, so it is left alone rather than valued as one xStock.
export const sharePricedLegs = (ids, assetDecimals, sharePricedIds) =>
  ids.map((id, i) => id !== null && assetDecimals[i] === null && sharePricedIds.includes(id.toLowerCase()));

/// What an index's statics hold of each leg's wrapping (keeper.mjs, `staticsOf`): for every token of `tokens` that
/// `wrapped` names, the decimals of the asset it wraps, read through `asset()`, and null for a plain coin. A wrapper
/// whose asset cannot be read throws: its index waits, as one whose decimals cannot be read does (CA-R2-04).
export async function assetDecimalsOf({ chain, abi, erc20, wrapped }, tokens, blockNumber) {
  const at = tokens.map((t, i) => (wrapped.has(t.toLowerCase()) ? i : -1)).filter((i) => i >= 0);
  const out = tokens.map(() => null);
  if (at.length === 0) return out;
  const assets = await chain.multicall(at.map((i) => ({ address: tokens[i], abi, functionName: "asset" })), blockNumber);
  if (assets.some((r) => r.status !== "success")) throw new Error("a wrapper's asset read failed");
  const decimals = await chain.multicall(assets.map((r) => ({ address: r.result, abi: erc20, functionName: "decimals" })), blockNumber);
  if (decimals.some((r) => r.status !== "success")) throw new Error("a wrapped asset's decimals read failed");
  at.forEach((i, k) => (out[i] = Number(decimals[k].result)));
  return out;
}

export function createRates({ chain, abi, log = () => {} }) {
  let block = null; // the block the cache below is of
  let cache = new Map(); // lowercased wrapper -> a promise of its rate at `block`, or of null
  const said = new Map(); // lowercased wrapper -> the last reason logged, so a wrapper left alone is not logged every block

  function say(token, reason) {
    if (said.get(token) === reason) return;
    said.set(token, reason);
    if (reason) log(token, reason);
  }

  /// The rates of `wrappers` ({key, decimals, assetDecimals}) at `blockNumber`, by key, each in 1e18 or null: a read
  /// that failed, at that block or at the one RATE_LOOKBACK_BLOCKS before it, a rate of zero, or one that moved more
  /// than MAX_RATE_MOVE_BPS between the two. Two calls to the node, whatever the number of wrappers. A chain not yet
  /// older than the look-back has no earlier block to read, and values no wrapper.
  async function readAll(wrappers, blockNumber) {
    const none = (reason) => new Map(wrappers.map((w) => (say(w.key, reason), [w.key, null])));
    if (blockNumber <= RATE_LOOKBACK_BLOCKS) return none(`not valued: the chain is not ${RATE_LOOKBACK_BLOCKS} blocks old, so its rate has nothing to be compared with`);
    const calls = wrappers.map((w) => ({ address: w.key, abi, functionName: "convertToAssets", args: [10n ** BigInt(w.decimals)] }));
    let now;
    let before;
    try {
      [now, before] = await Promise.all([chain.multicall(calls, blockNumber), chain.multicall(calls, blockNumber - RATE_LOOKBACK_BLOCKS)]);
    } catch (error) {
      return none(`not valued: its rate could not be read: ${error?.shortMessage ?? error?.message ?? error}`);
    }
    const rates = new Map();
    wrappers.forEach((w, k) => {
      rates.set(w.key, null);
      if (now[k].status !== "success" || before[k].status !== "success") {
        return say(w.key, `not valued: its rate could not be read ${now[k].status !== "success" ? "now" : `${RATE_LOOKBACK_BLOCKS} blocks back`}`);
      }
      const rate = M.rateWad(now[k].result, w.assetDecimals);
      const was = M.rateWad(before[k].result, w.assetDecimals);
      if (!M.rateSteady(rate, was, MAX_RATE_MOVE_BPS)) {
        return say(w.key, `not valued: its rate moved from ${was} to ${rate} within ${RATE_LOOKBACK_BLOCKS} blocks, more than ${MAX_RATE_MOVE_BPS} bps`);
      }
      say(w.key, null);
      rates.set(w.key, rate);
    });
    return rates;
  }

  /// The rate of each leg of `st` at `blockNumber`, in the order of its tokens: undefined for a plain coin, which has
  /// none, and for a wrapped one its rate in 1e18, or null when it cannot be valued now ({readAll}). One round reads a
  /// wrapper once, however many indexes hold it and however many checks ask.
  async function of(st, blockNumber) {
    if (block !== blockNumber) {
      block = blockNumber;
      cache = new Map();
    }
    const unread = new Map(); // the wrapped legs of `st` nobody has asked for at this block yet
    st.tokens.forEach((token, i) => {
      const key = token.toLowerCase();
      if (st.assetDecimals[i] !== null && !cache.has(key)) unread.set(key, { key, decimals: st.decimals[i], assetDecimals: st.assetDecimals[i] });
    });
    if (unread.size) {
      const read = readAll([...unread.values()], blockNumber);
      for (const key of unread.keys()) cache.set(key, read.then((rates) => rates.get(key)));
    }
    return Promise.all(st.tokens.map((token, i) => (st.assetDecimals[i] === null ? undefined : cache.get(token.toLowerCase()))));
  }

  /// The feed prices `feeds`, one per leg of `st`, as each token's own price at `blockNumber` (math.mjs, `atRate`).
  async function priced(st, feeds, blockNumber) {
    const rate = await of(st, blockNumber);
    return feeds.map((p, i) => M.atRate(p, rate[i]));
  }

  return { of, priced };
}
