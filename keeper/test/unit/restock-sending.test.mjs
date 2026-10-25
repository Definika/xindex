import { test } from "node:test";
import assert from "node:assert/strict";
import { createJournal } from "../../restock/journal.mjs";
import { ORPHAN_SECONDS, allowExactly, noPendingTransaction, resumeMove, settleCommit, withFeeHeadroom } from "../../restock/sending.mjs";

const TREASURY = `0x${"aa".repeat(20)}`;
/// What viem throws when a node has no receipt for a hash.
const notFound = () => Object.assign(new Error("Transaction receipt could not be found."), { name: "TransactionReceiptNotFoundError" });

/// A journal holding one draw, signed at nonce 7 and left unsettled by a restart, on a clock the test turns, and a
/// client whose nonce is 8 (spent) and which serves no receipt, until a test says otherwise.
function setup() {
  const clock = { t: 1_000 };
  let text = null;
  const journal = createJournal({ load: () => text, save: (s) => (text = s), now: () => clock.t });
  const id = journal.open({ kind: "draw", amount: 5n }, { chain: "ethereum", raw: "0xsigned", hash: "0xh", nonce: 7 });
  const client = {
    nonce: 8,
    sent: [],
    getTransactionReceipt: async () => {
      throw notFound();
    },
    getTransactionCount: async () => client.nonce,
    sendRawTransaction: async ({ serializedTransaction }) => client.sent.push(serializedTransaction),
  };
  const look = () => resumeMove({ client, address: TREASURY, journal, move: journal.get(id), now: () => clock.t });
  return { clock, journal, id, client, look, stage: () => journal.get(id).stage };
}

test("a signed move whose nonce is still free is broadcast again, the same bytes", async () => {
  const s = setup();
  s.client.nonce = 7;
  assert.equal(await s.look(), null);
  assert.deepEqual(s.client.sent, ["0xsigned"]);
  assert.equal(s.stage(), "signed");
});

test("RS-5: a receipt lookup that fails is not taken for a missing receipt: the move stays signed", async () => {
  const s = setup();
  s.client.getTransactionReceipt = async () => {
    throw new Error("HTTP request failed. Status: 429");
  };
  await assert.rejects(s.look(), /429/, "the round logs it and looks again");
  assert.equal(s.stage(), "signed", "a move that may have been mined is never dropped on a failed lookup");
});

test("RS-5: a move whose nonce is spent, its receipt served by no node, is dropped only ORPHAN_SECONDS after", async () => {
  const s = setup();
  assert.equal(await s.look(), null);
  assert.equal(s.stage(), "signed", "a node behind the one that counted the nonce may not have the block yet");
  s.clock.t += ORPHAN_SECONDS - 1;
  await s.look();
  assert.equal(s.stage(), "signed");
  s.clock.t += 1;
  await s.look();
  assert.equal(s.stage(), "dropped");
  assert.deepEqual(s.client.sent, [], "and never broadcast again");
});

test("RS-5: a receipt that a node serves meanwhile settles the move", async () => {
  const s = setup();
  await s.look();
  s.clock.t += 10;
  s.client.getTransactionReceipt = async () => ({ blockNumber: 99n, status: "success" });
  assert.equal((await s.look()).status, "success");
  assert.equal(s.stage(), "sent");
  assert.equal(s.journal.get(s.id).data.block, "99");
});

test("RS-12: an approval is for exactly what the next call takes, and none when it may already", async () => {
  const approved = [];
  const at = (current) => allowExactly({ allowance: async () => current, approve: async (x) => approved.push(x), amount: 500n });
  assert.equal(await at(499n), true);
  assert.deepEqual(approved, [500n], "not the most a uint256 holds, which any flaw in the spender could take whole");
  assert.equal(await at(500n), false);
  assert.deepEqual(approved, [500n], "no second approval");
});

/// A commit signed and recorded as move `id`, its call `CALL`, and a client that serves `tx` for any hash.
function committed(tx) {
  const s = setup();
  return { ...s, getTransaction: async ({ hash }) => ({ hash, ...tx }) };
}
const CALL = { to: `0x${"ee".repeat(20)}`, data: "0xabcdef", value: 0n };
const receiptOf = (hash) => ({ transactionHash: hash, blockNumber: 42n, status: "success" });

test("RS-15: a commit whose own transaction was mined goes on to sent", async () => {
  const s = committed({ to: CALL.to, input: CALL.data, value: 0n });
  const r = await settleCommit({ journal: s.journal, id: s.id, hash: "0xh", request: CALL, receipt: receiptOf("0xh"), getTransaction: s.getTransaction });
  assert.equal(r.transactionHash, "0xh");
  assert.equal(s.stage(), "sent");
  assert.equal(s.journal.get(s.id).data.block, "42");
});

test("RS-15: a commit repriced on its nonce, the same call, goes on under the hash that was mined", async () => {
  const s = committed({ to: CALL.to.toUpperCase().replace("0X", "0x"), input: CALL.data, value: 0n });
  await settleCommit({ journal: s.journal, id: s.id, hash: "0xh", request: CALL, receipt: receiptOf("0xh2"), getTransaction: s.getTransaction });
  assert.equal(s.stage(), "sent");
  assert.equal(s.journal.get(s.id).data.hash, "0xh2", "Iris and the sequence are read from the transaction mined");
});

test("RS-15: a commit whose nonce went to another call is dropped, never taken for done", async () => {
  for (const other of [{ to: `0x${"aa".repeat(20)}`, input: "0x", value: 0n }, { to: CALL.to, input: "0x1234", value: 0n }, { to: CALL.to, input: CALL.data, value: 1n }]) {
    const s = committed(other);
    await assert.rejects(
      settleCommit({ journal: s.journal, id: s.id, hash: "0xh", request: CALL, receipt: receiptOf("0xc"), getTransaction: s.getTransaction }),
      /went to another transaction/,
    );
    assert.equal(s.stage(), "dropped", "a cancel's or another call's receipt is not the move's");
  }
});

test("RS-15: a commit without its receipt in time stays signed, for the next look", async () => {
  const s = committed({});
  assert.equal(await settleCommit({ journal: s.journal, id: s.id, hash: "0xh", request: CALL, receipt: null, getTransaction: s.getTransaction }), null);
  assert.equal(s.stage(), "signed");
});

test("RS-15: nothing is sent on a chain while a transaction of the treasury's is still pending there", async () => {
  const client = { getTransactionCount: async ({ blockTag }) => (blockTag === "pending" ? 8 : 7) };
  await assert.rejects(noPendingTransaction({ client, address: TREASURY, name: "ethereum" }), /still pending/);
  client.getTransactionCount = async () => 7;
  await noPendingTransaction({ client, address: TREASURY, name: "ethereum" });
});

test("RS-15: fees allow twice the base fee, as the keeper's, where a chain has one", async () => {
  const chain = withFeeHeadroom({ id: 1, name: "x", fees: { estimateFeesPerGas: "kept" } });
  assert.equal(chain.id, 1);
  assert.equal(chain.fees.estimateFeesPerGas, "kept", "the chain's own fee settings stay");
  assert.equal(await chain.fees.baseFeeMultiplier({ block: { baseFeePerGas: 7n } }), 2);
  assert.equal(await chain.fees.baseFeeMultiplier({ block: {} }), 1.2, "a legacy gas price pays in full: viem's own margin");
});
