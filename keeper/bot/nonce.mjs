// One transaction in flight, and a way out when it is stuck. A fill is valid in a single block, so one that misses it
// must not linger: the next block replaces it on the same nonce with a 0-value transfer to the bot itself, bumping
// the fees each block until some transaction on that nonce is mined. Chain access is injected (`io`), so this file
// has no dependencies and is unit-tested on its own.
//
// io: { address, latestNonce(), pendingNonce(), receipt(hash) -> {status, blockNumber} | null,
//       send(tx) -> hash, where tx = {nonce, to, data, value, gas, maxFeePerGas, maxPriorityFeePerGas};
//       a send that fails throws, with `.hash` set when the node already holds the transaction }

import { feesFor, max, replacementFees } from "./math.mjs";

const CANCEL_GAS = 21_000n;

export class TxTracker {
  constructor(io, log = () => {}) {
    this.io = io;
    this.log = log;
    this.inFlight = null;
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
    const hash = await this._submit(full);
    if (hash === null) return null;
    this.inFlight = { label, nonce, tx: full, hashes: [hash], targetBlock, cancelling: false };
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
      const fees = replacementFees(f.tx, nextBase);
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

  /// At startup, and whenever idle: a nonce the node holds but has not mined (a send from before a restart) is
  /// replaced like a missed fill. Returns true when one is being cleared.
  async clearStuck(blockNumber, nextBase, priorityWei) {
    if (this.inFlight) return true;
    const latest = await this.io.latestNonce();
    const pending = await this.io.pendingNonce();
    if (pending <= latest) return false;
    // The stuck transaction's fees are unknown: start well above what the next block needs.
    const start = feesFor(nextBase, 0);
    const seed = { maxFeePerGas: max(start.maxFeePerGas * 2n, 1n), maxPriorityFeePerGas: max(priorityWei * 2n, 1n) };
    this.inFlight = {
      label: "clear stuck nonce",
      nonce: latest,
      tx: seed,
      hashes: [],
      targetBlock: blockNumber,
      cancelling: true,
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
