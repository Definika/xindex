import { test } from "node:test";
import assert from "node:assert/strict";
import { createAdvance, REATTEST_EVERY_SECONDS } from "../../restock/advance.mjs";
import { createJournal } from "../../restock/journal.mjs";

const hex = (n, bytes) => BigInt(n).toString(16).padStart(bytes * 2, "0");
/// A CCTP V2 burn message with expiration block `expirationBlock`, distinguished by `tag` (its nonce).
const message = (tag, expirationBlock) => {
  const w = (n) => hex(n, 32);
  return `0x${hex(1, 4)}${hex(0, 4)}${hex(8, 4)}${w(tag)}${w(1)}${w(2)}${w(0)}${hex(2000, 4)}${hex(2000, 4)}${hex(1, 4)}${w(3)}${w(4)}${w(5)}${w(6)}${w(0)}${w(0)}${w(expirationBlock)}`;
};

/// The service around one move: an in-memory journal, Ethereum and a Sui home whose answers the test sets, and the two
/// attestation services, each recording what it was asked.
function rig({ verifiesCctp = () => true, verifiesVaa = () => true, irisAnswers = [], vaaAnswers = [] } = {}) {
  let text = null;
  let clock = 1_000_000;
  const journal = createJournal({ load: () => text, save: (t) => (text = t), now: () => clock });
  const did = [];
  const side = (name) => ({
    def: { wormhole: name === "ethereum" ? 2 : 21 },
    emitter: `0x${"cc".repeat(32)}`,
    cctpSender: `0x${"aa".repeat(32)}`,
    cctpRecipient: `0x${"bb".repeat(32)}`,
    cctpReceived: async () => false,
    verifyCctp: async (m) => ({ valid: verifiesCctp(m), reason: "Message expired and must be re-signed" }),
    receive: async (m) => did.push(["receive", name, m]),
    verifyVaa: async (v) => ({ valid: verifiesVaa(v), reason: "guardian set expired" }),
    transferCompleted: async () => false,
    redeem: async (v) => did.push(["redeem", name, v]),
    sequenceOfTx: async () => 9n,
    resume: async () => null,
  });
  const eth = side("ethereum");
  const homes = { sui: side("sui") };
  const iris = {
    message: async () => (irisAnswers.length > 1 ? irisAnswers.shift() : irisAnswers[0] ?? null),
    reattest: async (nonce) => did.push(["reattest", nonce]),
  };
  const wormholescan = { vaa: async () => (vaaAnswers.length > 1 ? vaaAnswers.shift() : vaaAnswers[0] ?? null) };
  const advance = createAdvance({
    journal,
    eth,
    homes,
    wormholescan,
    iris,
    redeemIn: async (v, copy) => did.push(["redeemIn", v, copy]),
    coinOf: () => ({ copy: "0xcopy" }),
    log: () => {},
    now: () => clock,
  });
  return { journal, advance, did, tick: (s) => (clock += s) };
}

/// A fund move (Ethereum to Sui) whose burn landed.
function fund(journal) {
  const id = journal.open({ kind: "fund", chain: "sui", amount: 5n }, { chain: "ethereum", hash: "0xburn" });
  journal.advance(id, "sent", { status: "success" });
  return id;
}

test("PD-10: a Circle signature past its expiry is never stored; Circle is asked to sign again, at most once an hour, and the fresh one is received", async () => {
  const stale = { message: message(1, 24_000_000n), attestation: "0xold" };
  const fresh = { message: message(1, 24_100_000n), attestation: "0xnew" };
  const r = rig({ verifiesCctp: (m) => m === fresh.message, irisAnswers: [stale, stale, stale, fresh] });
  const id = fund(r.journal);
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).stage, "sent", "the stale signature is not stored");
  assert.deepEqual(r.did, [["reattest", `0x${hex(1, 32)}`]]);
  await r.advance(r.journal.get(id));
  assert.equal(r.did.length, 1, "within the hour, not asked again");
  r.tick(REATTEST_EVERY_SECONDS);
  await r.advance(r.journal.get(id));
  assert.equal(r.did.length, 2, "an hour on, asked again");
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).stage, "received");
  assert.deepEqual(r.did.at(-1), ["receive", "sui", fresh.message]);
});

test("PD-10: a stored signature that went stale before its receipt is replaced by the fresh one Circle signs", async () => {
  const stored = { message: message(2, 24_000_000n), attestation: "0xold" };
  const fresh = { message: message(2, 24_100_000n), attestation: "0xnew" };
  const r = rig({ verifiesCctp: (m) => m === fresh.message, irisAnswers: [stored, fresh] });
  const id = fund(r.journal);
  r.journal.advance(id, "attested", stored);
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).stage, "attested", "stale, and Circle still answers with it: asked to sign again");
  assert.deepEqual(r.did, [["reattest", `0x${hex(2, 32)}`]]);
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).stage, "received");
  assert.equal(r.journal.get(id).data.attestation, "0xnew", "the journal holds the signature that was received");
  assert.deepEqual(r.did.at(-1), ["receive", "sui", fresh.message]);
});

test("PD-10: a signature refused for another reason, with no expiry in its message, is an error, not a re-attestation", async () => {
  const r = rig({ verifiesCctp: () => false, irisAnswers: [{ message: message(3, 0n), attestation: "0xbad" }] });
  const id = fund(r.journal);
  await assert.rejects(r.advance(r.journal.get(id)), /does not verify on the receiving chain/);
  assert.deepEqual(r.did, []);
});

test("PD-10: a VAA signed by a replaced guardian set is fetched again and the new one redeemed; with none newer, the move waits with the reason", async () => {
  const r = rig({ verifiesVaa: (v) => v === "0xnewvaa", vaaAnswers: ["0xnewvaa"] });
  const id = r.journal.open({ kind: "bridgeIn", coin: "SUI", copy: "0xcopy", chain: "sui", amount: 10n }, { chain: "sui", hash: "d1" });
  r.journal.advance(id, "sent", { status: "success", sequence: "9" });
  r.journal.advance(id, "attested", { vaa: "0xoldvaa" });
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).stage, "redeemed");
  assert.deepEqual(r.did, [["redeemIn", "0xnewvaa", "0xcopy"]]);

  const stuck = rig({ verifiesVaa: () => false, vaaAnswers: ["0xoldvaa"] });
  const id2 = stuck.journal.open({ kind: "bridgeIn", coin: "SUI", copy: "0xcopy", chain: "sui", amount: 10n }, { chain: "sui", hash: "d2" });
  stuck.journal.advance(id2, "sent", { status: "success", sequence: "9" });
  stuck.journal.advance(id2, "attested", { vaa: "0xoldvaa" });
  await assert.rejects(stuck.advance(stuck.journal.get(id2)), /no longer verifies \(guardian set expired\) and Wormholescan has no newer one/);
  assert.equal(stuck.journal.get(id2).stage, "attested");
});

test("a bridge-in is attested, then redeemed by the executor with the copy recorded when the move opened", async () => {
  const r = rig({ vaaAnswers: ["0xvaa"] });
  const id = r.journal.open({ kind: "bridgeIn", coin: "SUI", copy: "0xrecorded", chain: "sui", amount: 10n }, { chain: "sui", hash: "d1" });
  r.journal.advance(id, "sent", { status: "success" });
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).data.sequence, "9");
  assert.equal(r.journal.get(id).stage, "redeemed");
  assert.deepEqual(r.did, [["redeemIn", "0xvaa", "0xrecorded"]]);
});
