// Ondo's shares multipliers, for the Ondo legs the keeper values: a leg priced at its share's feed (SHARE_PRICED_IDS,
// script/PythIds.sol) is worth sValue shares, and Ondo's SyntheticSharesOracle on the keeper's chain holds each
// token's sValue, "intended to be combined with a stock price oracle" (its own notes): the token's price is the share's
// times sValue. Nothing here is a price: the sValue is read from Ondo's oracle at the block every other read of the
// round is pinned to, and a leg is valued at it only when the oracle says it is settled (math.mjs, `sValueUsable`). No
// dependency: the chain and the oracle's ABI are handed in, so the unit tests run without `npm install`.

import { SHARE_PRICED_IDS, SVALUE_SETTLE_SECONDS } from "./config.mjs";
import * as M from "./math.mjs";

/// The ABI of the one call this reads: `SyntheticSharesOracle.assetData`, verified on Ethereum and BNB Chain.
export const ONDO_ORACLE_ABI = Object.freeze([
  {
    type: "function",
    name: "assetData",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [
      { name: "sValue", type: "uint128" },
      { name: "pendingSValue", type: "uint128" },
      { name: "lastUpdate", type: "uint256" },
      { name: "pauseStartTime", type: "uint256" },
      { name: "allowedDriftBps", type: "uint16" },
      { name: "driftCooldown", type: "uint48" },
    ],
  },
]);

/// Which legs of `ids` are share-priced: a leg whose feed prices a share rather than the token (RX-2).
export const sharePricedLegs = (ids, sharePricedIds = SHARE_PRICED_IDS) =>
  ids.map((id) => id !== null && id !== undefined && sharePricedIds.includes(id.toLowerCase()));

/// `oracle` is the chain's SyntheticSharesOracle (`cfg.chain.ondoOracle`), or null where Ondo has none, and then no
/// share-priced leg is valued.
export function createSValues({ chain, oracle, abi = ONDO_ORACLE_ABI, settleSeconds = SVALUE_SETTLE_SECONDS, sharePricedIds = SHARE_PRICED_IDS, log = () => {} }) {
  let block = null; // the block the cache below is of
  let cache = new Map(); // lowercased token -> a promise of its sValue at `block`, or of null
  const said = new Map(); // lowercased token -> the last reason logged, so a leg left alone is not logged every block

  function say(token, reason) {
    if (said.get(token) === reason) return;
    said.set(token, reason);
    if (reason) log(token, reason);
  }

  /// The sValues of `tokens` (lowercased) at block L, by token, each in 1e18 or null: a read that failed, a token the
  /// oracle does not hold, or one it holds but has not settled ({M.sValueUsable}). One call to the node, whatever the
  /// number of tokens.
  async function readAll(tokens, L) {
    const none = (reason) => new Map(tokens.map((t) => (say(t, reason), [t, null])));
    if (!oracle) return none("not valued: Ondo has no shares-multiplier oracle on this chain");
    let read;
    try {
      read = await chain.multicall(tokens.map((t) => ({ address: oracle, abi, functionName: "assetData", args: [t] })), L.number);
    } catch (error) {
      return none(`not valued: Ondo's sValue could not be read: ${error?.shortMessage ?? error?.message ?? error}`);
    }
    const out = new Map();
    tokens.forEach((t, k) => {
      out.set(t, null);
      if (read[k].status !== "success") return say(t, "not valued: Ondo's sValue could not be read");
      const [sValue, , lastUpdate, pauseStartTime] = read[k].result;
      const asset = { sValue: BigInt(sValue), lastUpdate: BigInt(lastUpdate), pauseStartTime: BigInt(pauseStartTime) };
      if (asset.sValue === 0n) return say(t, "not valued: Ondo's oracle on this chain does not hold its sValue");
      if (asset.pauseStartTime !== 0n) return say(t, `not valued: Ondo has scheduled or begun a corporate action on it (pause from ${asset.pauseStartTime})`);
      if (!M.sValueUsable(asset, BigInt(L.timestamp), settleSeconds)) {
        return say(t, `not valued: Ondo changed its sValue at ${asset.lastUpdate}, less than ${settleSeconds} s ago`);
      }
      say(t, null);
      out.set(t, asset.sValue);
    });
    return out;
  }

  /// The sValue of each leg of `st` at block L, in the order of its tokens: undefined for a leg that is not
  /// share-priced, which needs none, and for a share-priced one its sValue in 1e18, or null when it cannot be valued
  /// now ({readAll}). One round reads a token once, however many indexes hold it and however many checks ask.
  async function of(st, L) {
    if (block !== L.number) {
      block = L.number;
      cache = new Map();
    }
    const shared = sharePricedLegs(st.ids, sharePricedIds);
    const unread = [...new Set(st.tokens.filter((_, i) => shared[i]).map((t) => t.toLowerCase()))].filter((t) => !cache.has(t));
    if (unread.length) {
      const read = readAll(unread, L);
      for (const t of unread) cache.set(t, read.then((values) => values.get(t)));
    }
    return Promise.all(st.tokens.map((token, i) => (shared[i] ? cache.get(token.toLowerCase()) : undefined)));
  }

  /// Each leg of `st` as the keeper prices it, from `feeds`, one Pyth price per leg: `price`, and `shared`, true for a
  /// share-priced leg with no settled sValue. A leg priced at its own feed keeps the feed's price; a share-priced leg
  /// with a settled sValue is priced at the share's times sValue (M.atRate) and is no longer share-priced; one without
  /// keeps the feed's price, the share's, and stays share-priced, which every caller treats as it did before
  /// any: a leg the bot names no units for, delivers no stock of and counts none of as stock (RX-2).
  async function legs(st, feeds, L) {
    const sv = await of(st, L);
    return feeds.map((p, i) => {
      if (sv[i] === undefined) return { price: p ?? null, shared: false };
      if (sv[i] === null) return { price: p ?? null, shared: true };
      return { price: M.atRate(p, sv[i]), shared: false };
    });
  }

  return { of, legs };
}
