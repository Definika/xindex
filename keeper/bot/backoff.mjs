// Failures remembered per key, so the bot stops spending gas, Hermes requests and simulations on what keeps failing:
// a fill that reverted on chain after its simulation passed (XS-4), keyed by auction, and a request whose simulation
// reverts (XS-7), keyed by request. No dependencies, so it is unit-tested on its own.

/// Fills of one auction that may revert on chain before the bot leaves that auction (XS-4).
export const MAX_REVERTED_FILLS = 3;

/// How long a strike lasts: a key whose last failure is this many blocks old starts afresh (RX-26), so three reverts
/// an attacker induced, for instance with issues bundled ahead of each fill, cost the bot an hour of an auction, not
/// the rest of it.
export const STRIKE_LAPSE_BLOCKS = 300;

/// A fill that reverts on chain after its simulation passed was front-run (an issue past SUPPLY_TOLERANCE_BPS, a
/// rival fill) or simulated by an RPC that cannot be trusted, and each one costs gas: its auction (`index:proposal`)
/// waits 5, then 10 blocks, and after the third the bot leaves it until the strikes lapse (XS-4, RX-26).
export const revertedFills = () => new Backoff({ blocks: 5, limit: MAX_REVERTED_FILLS, lapseBlocks: STRIKE_LAPSE_BLOCKS });

/// Fills of one request that may revert on chain before the bot leaves that request (XS-7).
export const MAX_REVERTED_REQUEST_FILLS = 3;

/// A request fill that reverts on chain after its simulation passed was front-run (a cancel, a rival fill, a creator
/// closing the gate for the block) or simulated by an RPC that cannot be trusted, and each one can cost a whole
/// basket's swaps: the request (`request:id`) waits 5, then 10 blocks, and after the third the bot leaves it (XS-7).
/// Its requester (`requester:address`) and index (`index:address`) are struck too, so new request ids from the same
/// requester or on the same index do not start over (RX-10).
export const revertedRequestFills = () =>
  new Backoff({ blocks: 5, limit: MAX_REVERTED_REQUEST_FILLS, lapseBlocks: STRIKE_LAPSE_BLOCKS });

/// A request (`request:id`) whose simulation reverts is simulated again 2, 4, 8... blocks later, at most 200 (about
/// 40 minutes), until it closes (XS-7): requests last up to 30 days, and what made one fail can pass.
export const failedRequests = () => new Backoff({ blocks: 2, maxBlocks: 200 });

/// A request whose check keeps declining it without a revert (it pays too little, needs restock, has no preview) is
/// checked again 2, 4, 8... blocks later, at most 200, so a decoy that never pays cannot hold a check slot every
/// block for 30 days (RX-24).
export const skippedRequests = () => new Backoff({ blocks: 2, maxBlocks: 200 });

export class Backoff {
  /// After its n-th failure at block B a key is tried again from block B + `blocks · 2^(n-1)`, at most B +
  /// `maxBlocks`; after `limit` failures it is stopped. A key whose last failure is `lapseBlocks` old is forgotten.
  constructor({ blocks, maxBlocks = Infinity, limit = Infinity, lapseBlocks = Infinity }) {
    this.blocks = blocks;
    this.maxBlocks = maxBlocks;
    this.limit = limit;
    this.lapseBlocks = lapseBlocks;
    this.entries = new Map(); // key -> {failures, until, stopped, last}
  }

  /// The entry of `key` at block `block`, or undefined once its strikes have lapsed.
  #live(key, block) {
    const e = this.entries.get(key);
    if (e !== undefined && Number(block) - e.last >= this.lapseBlocks) {
      this.entries.delete(key);
      return undefined;
    }
    return e;
  }

  /// Records a failure of `key` at block `block`; returns `{failures, until, stopped}`.
  fail(key, block) {
    const failures = (this.#live(key, block)?.failures ?? 0) + 1;
    const wait = Math.min(this.blocks * 2 ** (failures - 1), this.maxBlocks);
    const entry = { failures, until: Number(block) + wait, stopped: failures >= this.limit };
    this.entries.set(key, { ...entry, last: Number(block) });
    return entry;
  }

  /// Whether `key` must not be tried at block `block`.
  blocked(key, block) {
    const e = this.#live(key, block);
    return e !== undefined && (e.stopped || Number(block) < e.until);
  }

  failures(key) {
    return this.entries.get(key)?.failures ?? 0;
  }

  forget(key) {
    this.entries.delete(key);
  }

  /// Forgets every key whose strikes have lapsed by block `block`.
  prune(block) {
    for (const key of [...this.entries.keys()]) this.#live(key, block);
  }

  /// Forgets every key not in `keys`: the auctions that closed, the requests no longer open.
  keep(keys) {
    const live = new Set(keys);
    for (const key of this.entries.keys()) if (!live.has(key)) this.entries.delete(key);
  }
}
