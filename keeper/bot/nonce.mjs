// One transaction in flight, and a way out when it is stuck. A fill is valid in a single block, so one that misses it
// must not linger: the next block replaces it on the same nonce with a 0-value transfer to the bot itself, bumping
// the fees each block, never above MAX_FEE_GWEI and at most MAX_REPLACEMENTS times (XS-13), until some transaction on
// that nonce is mined. A pending nonce the bot did not send in this process is cleared only at startup (XS-12). Chain
// access is injected (`io`), so this file has no dependencies and is unit-tested on its own.
//
// io: { address, latestNonce(), pendingNonce(), receipt(hash) -> {status, blockNumber} | null,
//       send(tx) -> hash, where tx = {nonce, to, data, value, gas, maxFeePerGas, maxPriorityFeePerGas};
//       a send that fails throws, with `.hash` set when the node already holds the transaction }

import { feesFor, max, min, replacementFees } from "./math.mjs";

const CANCEL_GAS = 21_000n;
/// Replacements sent on one nonce before the tracker stops bumping and only waits for it (XS-13).
export const MAX_REPLACEMENTS = 10;
/// The most nonces the startup clear takes: the bot keeps one transaction in flight, so a restart leaves one.
export const MAX_STARTUP_CLEARS = 4;

export class TxTracker {
  /// `feeCap`, in wei, bounds every replacement's fees (MAX_FEE_GWEI); null leaves them unbounded.
  constructor(io, log = () => {}, { feeCap = null, maxReplacements = MAX_REPLACEMENTS } = {}) {
    this.io = io;
    this.log = log;
    this.feeCap = feeCap;
    this.maxReplacements = maxReplacements;
    this.inFlight = null;
    // Nonces below this may be cleared when the node reports them pending: those it held at startup, and one whose
    // send failed in a way that leaves its outcome unknown. Null when there are none (XS-12).
    this.clearBelow = null;
    this.startupChecked = false;
    this.warned = false;
  }

  _cap(x) {
    return this.feeCap === null ? x : min(x, this.feeCap);
  }

  _mayClear(below) {
    this.clearBelow = this.clearBelow === null ? below : max(this.clearBelow, below);
  }

  busy() {
    return this.inFlight !== null;
  }

  /// Sends `tx` (no nonce) on the next nonce, to land in block `targetBlock`. Returns the hash, or null when the nonce
  /// turned out to be taken.
  async send(tx, { label, targetBlock }) {
    if (this.inFlight) throw new Error("a transaction is already in flight");
    const nonce = await this.io.latestNonce();
    const full = { ...tx, nonce };
    let hash;
    try {
      hash = await this._submit(full);
    } catch (error) {
      // The node may hold it all the same (a timeout after it arrived), so a pending nonce of it may be cleared.
      this._mayClear(nonce + 1n);
      throw error;
    }
    if (hash === null) return null;
    this.inFlight = { label, nonce, tx: full, hashes: [hash], targetBlock, cancelling: false, replacements: 0 };
    this.log(`sent ${label} nonce ${nonce} ${hash}`);
    return hash;
  }

  /// Called once per new block. Returns `{label, receipt, replaced}` when the nonce in flight was used, else null.
  async onBlock(blockNumber, nextBase) {
    const f = this.inFlight;
    if (!f) return null;
    if ((await this.io.latestNonce()) > f.nonce) {
      let receipt = null;
      let mined = null;
      for (const hash of f.hashes) {
        receipt = await this.io.receipt(hash);
        if (receipt) {
          mined = hash;
          break;
        }
      }
      this.inFlight = null;
      // Replaced: what landed on the nonce is not the transaction first sent (a replacement, or one sent elsewhere).
      const replaced = mined !== f.hashes[0];
      this.log(`${f.label} nonce ${f.nonce}: ${receipt ? receipt.status : "used by another transaction"}${replaced ? " (replaced)" : ""}`);
      return { label: f.label, receipt, replaced };
    }
    // Block `targetBlock` exists without the transaction: it missed.
    if (blockNumber >= f.targetBlock) {
      if (f.replacements >= this.maxReplacements) {
        if (!f.gaveUp) {
          f.gaveUp = true;
          this.log(`${f.label} nonce ${f.nonce} unmined after ${f.replacements} replacements: no more bumps, waiting for it (check the RPC and the key's ETH)`);
        }
        return null;
      }
      f.replacements += 1;
      const fees = replacementFees(f.tx, nextBase, this.feeCap);
      const cancel = { nonce: f.nonce, to: this.io.address, data: "0x", value: 0n, gas: CANCEL_GAS, ...fees };
      const hash = await this._submit(cancel);
      // The fees rise either way, so a refused replacement is retried higher at the next block.
      f.tx = cancel;
      f.cancelling = true;
      f.targetBlock = blockNumber + 1;
      if (hash !== null && !f.hashes.includes(hash)) f.hashes.push(hash);
      this.log(`${f.label} nonce ${f.nonce} missed its block: replacing at ${fees.maxPriorityFeePerGas} wei tip`);
    }
    return null;
  }

  /// Whenever idle: a nonce the node holds but has not mined is replaced like a missed fill, but only one the bot may
  /// clear (XS-12): one the node held when this process started (a send from before a restart, at most
  /// MAX_STARTUP_CLEARS of them), or one whose send failed with its outcome unknown. A pending nonce reported beyond
  /// those, a cleared one reappearing included, is logged and left alone, so an RPC that misreports the pending nonce
  /// cannot make the bot cancel every block. Returns true when one is being cleared.
  async clearStuck(blockNumber, nextBase, priorityWei) {
    if (this.inFlight) return true;
    const latest = await this.io.latestNonce();
    const pending = await this.io.pendingNonce();
    if (!this.startupChecked) {
      this.startupChecked = true;
      if (pending > latest) this._mayClear(min(pending, latest + BigInt(MAX_STARTUP_CLEARS)));
    }
    if (pending <= latest) {
      this.warned = false;
      return false;
    }
    if (this.clearBelow === null || latest >= this.clearBelow) {
      this.clearBelow = null;
      if (!this.warned) {
        this.warned = true;
        this.log(`nonce ${latest} is reported pending, but this bot did not send it or has cleared it already: not clearing it (check the RPC)`);
      }
      return false;
    }
    // The stuck transaction's fees are unknown: start well above what the next block needs.
    const start = feesFor(nextBase, 0);
    const seed = {
      maxFeePerGas: this._cap(max(start.maxFeePerGas * 2n, 1n)),
      maxPriorityFeePerGas: this._cap(max(priorityWei * 2n, 1n)),
    };
    this.inFlight = {
      label: "clear stuck nonce",
      nonce: latest,
      tx: seed,
      hashes: [],
      targetBlock: blockNumber,
      cancelling: true,
      replacements: 0,
    };
    await this.onBlock(blockNumber, nextBase);
    return true;
  }

  async _submit(tx) {
    try {
      return await this.io.send(tx);
    } catch (error) {
      const message = String(error?.message ?? error);
      if (/nonce too low|nonce has already been used/i.test(message)) return null;
      if (/already known/i.test(message) && error.hash) return error.hash;
      if (/underpriced|fee too low/i.test(message)) {
        this.log(`nonce ${tx.nonce}: replacement refused as underpriced; retrying higher next block`);
        return null;
      }
      throw error;
    }
  }
}
