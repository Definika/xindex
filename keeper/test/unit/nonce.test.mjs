import { test } from "node:test";
import assert from "node:assert/strict";
import { TxTracker } from "../../bot/nonce.mjs";

const ME = "0x000000000000000000000000000000000000beef";

/// A chain with one account: what it has mined (`latest`), what its mempool holds (`pending`), and receipts.
function fakeChain() {
  const chain = {
    address: ME,
    latest: 5n,
    pending: 5n,
    sent: [],
    receipts: new Map(),
    failNext: null,
    latestNonce: async () => chain.latest,
    pendingNonce: async () => chain.pending,
    receipt: async (hash) => chain.receipts.get(hash) ?? null,
    send: async (tx) => {
      if (chain.failNext) {
        const error = chain.failNext;
        chain.failNext = null;
        throw error;
      }
      chain.sent.push(tx);
      const hash = `0x${chain.sent.length.toString(16).padStart(64, "0")}`;
      if (tx.nonce + 1n > chain.pending) chain.pending = tx.nonce + 1n;
      return hash;
    },
    mine(hash, status = "success") {
      chain.latest += 1n;
      chain.receipts.set(hash, { status, transactionHash: hash });
    },
  };
  return chain;
}

const FILL = { to: "0x1", data: "0xabcd", value: 0n, gas: 500_000n, maxFeePerGas: 100n, maxPriorityFeePerGas: 10n };

test("a sent fill that lands is reported and frees the tracker", async () => {
  const chain = fakeChain();
  const t = new TxTracker(chain);
  const hash = await t.send(FILL, { label: "fill", targetBlock: 11 });
  assert.equal(chain.sent[0].nonce, 5n);
  assert.ok(t.busy());
  await assert.rejects(t.send(FILL, { label: "again", targetBlock: 11 }), /already in flight/);
  assert.equal(await t.onBlock(10, 50n), null, "nothing to do before the target block");
  chain.mine(hash);
  assert.deepEqual(await t.onBlock(11, 50n), { label: "fill", receipt: { status: "success", transactionHash: hash }, replaced: false });
  assert.equal(t.busy(), false);
});

test("a fill that misses its block is replaced by a self-transfer, bumped every block until mined", async () => {
  const chain = fakeChain();
  const t = new TxTracker(chain);
  await t.send(FILL, { label: "fill", targetBlock: 11 });
  assert.equal(await t.onBlock(12, 50n), null);
  const cancel = chain.sent[1];
  assert.deepEqual(
    { nonce: cancel.nonce, to: cancel.to, data: cancel.data, value: cancel.value, gas: cancel.gas },
    { nonce: 5n, to: ME, data: "0x", value: 0n, gas: 21_000n },
  );
  assert.ok(cancel.maxPriorityFeePerGas * 1000n >= FILL.maxPriorityFeePerGas * 1100n, "tip up at least 10%");
  assert.ok(cancel.maxFeePerGas * 1000n >= FILL.maxFeePerGas * 1100n, "ceiling up at least 10%");

  assert.equal(await t.onBlock(13, 50n), null);
  const again = chain.sent[2];
  assert.ok(again.maxPriorityFeePerGas > cancel.maxPriorityFeePerGas, "bumped again");
  assert.ok(again.maxFeePerGas >= 2n * 50n + again.maxPriorityFeePerGas, "above the next base fee");

  chain.mine(`0x${(3).toString(16).padStart(64, "0")}`);
  const outcome = await t.onBlock(14, 50n);
  assert.equal(outcome.replaced, true);
  assert.equal(t.busy(), false);
});

test("a refused replacement is retried higher at the next block", async () => {
  const chain = fakeChain();
  const t = new TxTracker(chain);
  await t.send(FILL, { label: "fill", targetBlock: 11 });
  chain.failNext = new Error("replacement transaction underpriced");
  await t.onBlock(12, 50n);
  assert.equal(chain.sent.length, 1, "the refused one was not sent");
  await t.onBlock(13, 50n);
  assert.equal(chain.sent.length, 2);
  assert.ok(chain.sent[1].maxPriorityFeePerGas >= 13n, "two bumps above the fill's tip");
});

test("a nonce already used means nothing was sent; an already known one counts as sent", async () => {
  const chain = fakeChain();
  const t = new TxTracker(chain);
  chain.failNext = new Error("nonce too low");
  assert.equal(await t.send(FILL, { label: "fill", targetBlock: 11 }), null);
  assert.equal(t.busy(), false);

  const known = Object.assign(new Error("already known"), { hash: "0xknown" });
  chain.failNext = known;
  assert.equal(await t.send(FILL, { label: "fill", targetBlock: 11 }), "0xknown");
  assert.ok(t.busy());
});

test("other send errors propagate", async () => {
  const chain = fakeChain();
  const t = new TxTracker(chain);
  chain.failNext = new Error("insufficient funds for gas");
  await assert.rejects(t.send(FILL, { label: "fill", targetBlock: 11 }), /insufficient funds/);
  assert.equal(t.busy(), false);
});

test("a nonce stuck from before a restart is cleared, one at a time", async () => {
  const chain = fakeChain();
  chain.pending = 7n;
  const t = new TxTracker(chain);
  assert.equal(await t.clearStuck(20, 50n, 2_000_000_000n), true);
  assert.equal(chain.sent[0].nonce, 5n);
  assert.equal(chain.sent[0].to, ME);
  assert.ok(chain.sent[0].maxPriorityFeePerGas > 4_000_000_000n, "well above the configured tip");
  chain.mine(`0x${(1).toString(16).padStart(64, "0")}`);
  assert.equal((await t.onBlock(21, 50n)).label, "clear stuck nonce");
  assert.equal(await t.clearStuck(22, 50n, 2_000_000_000n), true);
  assert.equal(chain.sent[1].nonce, 6n);
  chain.mine(`0x${(2).toString(16).padStart(64, "0")}`);
  await t.onBlock(23, 50n);
  assert.equal(await t.clearStuck(24, 50n, 2_000_000_000n), false, "nothing left");
});
