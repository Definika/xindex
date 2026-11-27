import { test } from "node:test";
import assert from "node:assert/strict";
import { createAdvance, NOT_COMPLETED, REATTEST_EVERY_SECONDS } from "../../restock/advance.mjs";
import { createJournal } from "../../restock/journal.mjs";
import { EXPIRY_MARGIN_SECONDS } from "../../restock/uniswapx.mjs";

const hex = (n, bytes) => BigInt(n).toString(16).padStart(bytes * 2, "0");
/// A CCTP V2 burn message with expiration block `expirationBlock`, distinguished by `tag` (its nonce).
const message = (tag, expirationBlock) => {
  const w = (n) => hex(n, 32);
  return `0x${hex(1, 4)}${hex(0, 4)}${hex(8, 4)}${w(tag)}${w(1)}${w(2)}${w(0)}${hex(2000, 4)}${hex(2000, 4)}${hex(1, 4)}${w(3)}${w(4)}${w(5)}${w(6)}${w(0)}${w(0)}${w(expirationBlock)}`;
};

/// The service around one move: an in-memory journal, Ethereum and a Sui home whose answers the test sets, and the two
/// attestation services, each recording what it was asked.
function rig({ verifiesCctp = () => true, verifiesVaa = () => true, irisAnswers = [], vaaAnswers = [], lands = () => true, posts = () => true, filled = () => false, chainTime = null } = {}) {
  let text = null;
  let clock = 1_000_000;
  const journal = createJournal({ load: () => text, save: (t) => (text = t), now: () => clock });
  const did = [];
  // What each side shows completed: a redeem or a receive lands there unless `lands()` says its transaction was
  // replaced on its nonce by one that did something else.
  const completed = { ethereum: new Set(), avalanche: new Set() };
  const complete = (name, what) => lands() && completed[name].add(what);
  const side = (name) => ({
    def: { wormhole: name === "ethereum" ? 2 : 21 },
    emitter: `0x${"cc".repeat(32)}`,
    cctpSender: `0x${"aa".repeat(32)}`,
    cctpRecipient: `0x${"bb".repeat(32)}`,
    cctpReceived: async (m) => completed[name].has(m),
    verifyCctp: async (m) => ({ valid: verifiesCctp(m), reason: "Message expired and must be re-signed" }),
    receive: async (m) => (did.push(["receive", name, m]), complete(name, m)),
    verifyVaa: async (v) => ({ valid: verifiesVaa(v), reason: "guardian set expired" }),
    transferCompleted: async (v) => completed[name].has(v),
    redeem: async (v) => (did.push(["redeem", name, v]), complete(name, v)),
    sequenceOfTx: async () => 9n,
    resume: async () => null,
  });
  const eth = side("ethereum");
  const homes = { avalanche: side("avalanche") };
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
    redeemIn: async (v, copy) => (did.push(["redeemIn", v, copy]), complete("ethereum", v)),
    orders: {
      post: async (move) => {
        did.push(["post", move.data.signature]);
        if (!posts()) throw new Error("HTTP 503: Failed to post order");
      },
      filled: async () => filled(),
      chainTime: async () => chainTime ?? clock,
    },
    coinOf: () => ({ copy: "0xcopy" }),
    log: () => {},
    now: () => clock,
  });
  return { journal, advance, did, tick: (s) => (clock += s) };
}

/// A fund move (Ethereum to Sui) whose burn landed.
function fund(journal) {
  const id = journal.open({ kind: "fund", chain: "avalanche", amount: 5n }, { chain: "ethereum", hash: "0xburn" });
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
  assert.deepEqual(r.did.at(-1), ["receive", "avalanche", fresh.message]);
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
  assert.deepEqual(r.did.at(-1), ["receive", "avalanche", fresh.message]);
});

test("PD-10: a signature refused for another reason, with no expiry in its message, is an error, not a re-attestation", async () => {
  const r = rig({ verifiesCctp: () => false, irisAnswers: [{ message: message(3, 0n), attestation: "0xbad" }] });
  const id = fund(r.journal);
  await assert.rejects(r.advance(r.journal.get(id)), /does not verify on the receiving chain/);
  assert.deepEqual(r.did, []);
});

test("PD-10: a VAA signed by a replaced guardian set is fetched again and the new one redeemed; with none newer, the move waits with the reason", async () => {
  const r = rig({ verifiesVaa: (v) => v === "0xnewvaa", vaaAnswers: ["0xnewvaa"] });
  const id = r.journal.open({ kind: "bridgeIn", coin: "AVAX", copy: "0xcopy", chain: "avalanche", amount: 10n }, { chain: "avalanche", hash: "d1" });
  r.journal.advance(id, "sent", { status: "success", sequence: "9" });
  r.journal.advance(id, "attested", { vaa: "0xoldvaa" });
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).stage, "redeemed");
  assert.deepEqual(r.did, [["redeemIn", "0xnewvaa", "0xcopy"]]);

  const stuck = rig({ verifiesVaa: () => false, vaaAnswers: ["0xoldvaa"] });
  const id2 = stuck.journal.open({ kind: "bridgeIn", coin: "AVAX", copy: "0xcopy", chain: "avalanche", amount: 10n }, { chain: "avalanche", hash: "d2" });
  stuck.journal.advance(id2, "sent", { status: "success", sequence: "9" });
  stuck.journal.advance(id2, "attested", { vaa: "0xoldvaa" });
  await assert.rejects(stuck.advance(stuck.journal.get(id2)), /no longer verifies \(guardian set expired\) and Wormholescan has no newer one/);
  assert.equal(stuck.journal.get(id2).stage, "attested");
});

test("a bridge-in is attested, then redeemed by the executor with the copy recorded when the move opened", async () => {
  const r = rig({ vaaAnswers: ["0xvaa"] });
  const id = r.journal.open({ kind: "bridgeIn", coin: "AVAX", copy: "0xrecorded", chain: "avalanche", amount: 10n }, { chain: "avalanche", hash: "d1" });
  r.journal.advance(id, "sent", { status: "success" });
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).data.sequence, "9");
  assert.equal(r.journal.get(id).stage, "redeemed");
  assert.deepEqual(r.did, [["redeemIn", "0xvaa", "0xrecorded"]]);
});

test("CA-M10: a completing transaction that was mined proves nothing: the other side is read back", async () => {
  // The operator cancelled a stuck redeem on its nonce. The cancel is mined, with success, and the waiter hands back
  // its receipt: the transfer is not completed, and the move must not settle on it.
  let replaced = true;
  const r = rig({ vaaAnswers: ["0xvaa"], lands: () => !replaced });
  const out = r.journal.open({ kind: "bridgeOut", coin: "AVAX", copy: "0xcopy", chain: "avalanche", amount: 5n }, { chain: "ethereum", hash: "0xout", sequence: "9" });
  r.journal.advance(out, "sent", { status: "success" });
  await assert.rejects(r.advance(r.journal.get(out)), new RegExp(NOT_COMPLETED));
  assert.equal(r.journal.get(out).stage, "attested", "the transfer is still to redeem");
  assert.deepEqual(r.did.map((d) => d[0]), ["redeem"]);

  // The next round sends the redeem again, and it lands.
  replaced = false;
  await r.advance(r.journal.get(out));
  assert.equal(r.journal.get(out).stage, "redeemed");
  assert.deepEqual(r.did.map((d) => d[0]), ["redeem", "redeem"]);

  // Into the executor, and a CCTP receive, the same way.
  replaced = true;
  const into = r.journal.open({ kind: "bridgeIn", coin: "AVAX", copy: "0xcopy", chain: "avalanche", amount: 5n }, { chain: "avalanche", hash: "0xin", sequence: "9" });
  r.journal.advance(into, "sent", { status: "success" });
  await assert.rejects(r.advance(r.journal.get(into)), new RegExp(NOT_COMPLETED));
  assert.equal(r.journal.get(into).stage, "attested");

  const cctp = rig({ irisAnswers: [{ message: message(1, 0), attestation: "0xsig" }], lands: () => false });
  const id = fund(cctp.journal);
  await assert.rejects(cctp.advance(cctp.journal.get(id)), new RegExp(NOT_COMPLETED));
  assert.equal(cctp.journal.get(id).stage, "attested", "the burn's USDC is still to receive");
});

/// A UniswapX order signed for a deadline 120 s away.
function signedOrder(journal, clock) {
  return journal.open({ kind: "order", coin: "NVDAON", copy: "0xnvda", chain: "ethereum", amountIn: 1_980_000_000n, usd: 1_980 }, { nonce: "7", deadline: clock + 120, signature: "0xsig" });
}

test("a UniswapX order is posted, then done once Permit2 shows its nonce spent", async () => {
  let spent = false;
  const r = rig({ filled: () => spent });
  const id = signedOrder(r.journal, 1_000_000);
  await r.advance(r.journal.get(id));
  assert.deepEqual(r.did, [["post", "0xsig"]]);
  assert.equal(r.journal.get(id).stage, "sent");
  assert.equal(r.journal.get(id).data.posted, true);
  await r.advance(r.journal.get(id));
  assert.equal(r.did.length, 1, "posted once");
  assert.equal(r.journal.get(id).stage, "sent", "waiting for a filler");
  spent = true;
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).stage, "done");
});

test("an order the API did not take is posted again, and is held until its deadline and finality pass, a filler may have it", async () => {
  let up = false;
  const r = rig({ posts: () => up });
  const id = signedOrder(r.journal, 1_000_000);
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).stage, "sent", "its signature left the service");
  assert.equal(r.journal.get(id).data.posted, false);
  assert.match(r.journal.get(id).data.postError, /HTTP 503/);
  up = true;
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).data.posted, true, "posted on the next round");
  await r.advance(r.journal.get(id));
  assert.equal(r.did.filter(([k]) => k === "post").length, 2, "and not again");

  r.tick(120 + EXPIRY_MARGIN_SECONDS);
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).stage, "sent", "at the margin's last second it may still be in a block a re-org undoes");
  r.tick(1);
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).stage, "dropped");
  assert.equal(r.journal.get(id).data.status, "expired");
});

test("an order is given up by the chain's clock, not the service's, and one filled at the last moment is done, not dropped", async () => {
  const behind = rig({ chainTime: 1_000_000 });
  const id = signedOrder(behind.journal, 1_000_000);
  behind.tick(10_000);
  await behind.advance(behind.journal.get(id));
  assert.equal(behind.journal.get(id).stage, "sent", "the chain has not passed the deadline");

  const late = rig({ filled: () => true });
  const filled = signedOrder(late.journal, 1_000_000);
  late.tick(10_000);
  await late.advance(late.journal.get(filled));
  assert.equal(late.journal.get(filled).stage, "done");
});

test("a deposit into the executor settles once its transaction is mined, as a draw does", async () => {
  const r = rig();
  const id = r.journal.open({ kind: "deposit", coin: "NVDAON", copy: "0xnvda", chain: "ethereum", amount: 5n, usd: 900 }, { chain: "ethereum", hash: "0xd" });
  r.journal.advance(id, "sent", { status: "success" });
  await r.advance(r.journal.get(id));
  assert.equal(r.journal.get(id).stage, "done");
  const reverted = r.journal.open({ kind: "deposit", coin: "NVDAON", copy: "0xnvda", chain: "ethereum", amount: 5n, usd: 900 }, { chain: "ethereum", hash: "0xe" });
  r.journal.advance(reverted, "sent", { status: "reverted" });
  await r.advance(r.journal.get(reverted));
  assert.equal(r.journal.get(reverted).stage, "dropped", "the coins never left the treasury");
});
