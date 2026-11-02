import { test } from "node:test";
import assert from "node:assert/strict";
import { createJournal } from "../../restock/journal.mjs";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSignerHome, evmWord, startSigner } from "../../restock/signer-home.mjs";

/// A journal in memory, and a signer that answers from `script` (op -> function of args), recording every request.
function rig(script) {
  let text = null;
  const journal = createJournal({ load: () => text, save: (t) => (text = t) });
  const asked = [];
  const ask = async (op, args = {}) => {
    asked.push({ op, args, journalled: Object.keys(JSON.parse(text ?? '{"moves":{}}').moves).length });
    if (!script[op]) throw new Error(`unexpected request ${op}`);
    return script[op](args);
  };
  const home = createSignerHome({
    name: "sui",
    def: { wormhole: 21, cctpDomain: 8 },
    coins: [{ symbol: "SUI", home: "0x2::sui::SUI", decimals: 9 }],
    floatId: "USDC",
    journal,
    cfg: { minUsd: 100 },
    verifyVaa: async () => ({ valid: true }),
    ask,
  });
  return { home, journal, asked };
}

const SIGNED = { raw: "raw-bytes", signature: "digest-1", expiry: '{"epoch":"9"}' };
const INFO = { wallet: "0xab", walletWord: `0x${"ab".repeat(32)}`, emitter: `0x${"cc".repeat(32)}`, accounts: { "0x2::sui::SUI": { address: "0xab", word: `0x${"ab".repeat(32)}` } } };

test("a signer home reads the signer's addresses; without a token account the wallet is the CCTP recipient", async () => {
  const { home } = rig({ info: () => INFO });
  await home.check();
  assert.equal(home.address, "0xab");
  assert.equal(home.emitter, INFO.emitter);
  assert.equal(home.cctpSender, INFO.walletWord);
  assert.equal(home.cctpRecipient, INFO.walletWord, "Sui and Aptos mint to the wallet itself");
  assert.equal(home.recipientFor({ home: "0x2::sui::SUI" }), INFO.walletWord);
});

test("a move is journalled before the signer is asked to send it, and lands as sent", async () => {
  const { home, journal, asked } = rig({
    buildBridgeIn: () => SIGNED,
    send: () => "digest-1",
    status: () => ({ state: "landed", at: "77" }),
    sequenceOf: () => "42",
  });
  await home.bridgeIn({ kind: "bridgeIn", coin: "SUI", copy: "0xcopy", chain: "sui", amount: 1_000n, usd: 5 }, { home: "0x2::sui::SUI" }, `0x${"ee".repeat(32)}`);
  const send = asked.find((a) => a.op === "send");
  assert.equal(send.journalled, 1, "the journal held the move when it was sent");
  assert.equal(send.args.raw, "raw-bytes");
  const [move] = journal.find(() => true);
  assert.equal(move.stage, "sent");
  assert.equal(move.data.status, "success");
  assert.equal(move.data.expiry, SIGNED.expiry, "the signer's expiry is kept for its next look");
  assert.equal(move.data.sequence, "42");
});

test("resume: an expired move is dropped, a pending one sent again, a reverted one marked so", async () => {
  for (const [state, expect] of [
    ["expired", (m) => assert.equal(m.stage, "dropped")],
    ["pending", (m) => assert.equal(m.stage, "signed")],
    ["reverted", (m) => assert.equal(m.data.status, "reverted")],
  ]) {
    const { home, journal, asked } = rig({ send: () => null, status: () => ({ state, reason: "why" }) });
    const id = journal.open({ kind: "sweep", chain: "sui", amount: 5n }, { chain: "sui", raw: "r", hash: "d", expiry: "e" });
    await home.resume(journal.get(id));
    expect(journal.get(id));
    const resent = asked.filter((a) => a.op === "send").length;
    assert.equal(resent, state === "pending" ? 1 : 0, `${state}: sent again only while it may still land`);
  }
});

test("a swap halves while no route pays its share of the floor, down to the minimum trade, and journals what was spent", async () => {
  const tried = [];
  const { home, journal } = rig({
    buildSwap: ({ amount, minOut }) => {
      tried.push([amount, minOut]);
      return BigInt(amount) > 300n ? { refused: "loss", outAmount: "0" } : { ...SIGNED, spent: String(BigInt(amount) - 1n) };
    },
    send: () => null,
    status: () => ({ state: "landed" }),
  });
  const a = { kind: "buy", coin: "SUI", copy: "0xcopy", chain: "sui", usd: 400, amountIn: 1_200n, maxIn: 1_212n, amountOut: 9n, minOut: 800n };
  const done = await home.buy(a, { home: "0x2::sui::SUI" });
  assert.deepEqual(tried, [["1200", "800"], ["600", "400"], ["300", "200"]]);
  const [move] = journal.find(() => true);
  assert.equal(move.amount, "299", "the amount the route spent");
  assert.ok(Math.abs(done.usd - (100 * 299) / 300) < 1e-9, "and its value");
  const { home: thin } = rig({ buildSwap: () => ({ refused: "loss", outAmount: "0" }) });
  assert.equal(await thin.buy(a, { home: "0x2::sui::SUI" }), null, "none pays above the minimum trade: no buy");
});

test("a sweep names the treasury as a word, and keeps the burn's event account for the rent's reclaim", async () => {
  let treasury = null;
  const { home, journal } = rig({
    buildSweep: (args) => ((treasury = args.treasury), { ...SIGNED, eventAccount: "Ev3nt" }),
    send: () => null,
    status: () => ({ state: "landed" }),
  });
  await home.sweep({ kind: "sweep", chain: "sui", amount: 7n }, "0x88A5b9350c722D25579a5EF1C5C613f923460c04");
  assert.equal(treasury, evmWord("0x88A5b9350c722D25579a5EF1C5C613f923460c04"));
  assert.equal(journal.find(() => true)[0].data.eventAccount, "Ev3nt");
});

test("PD-6: a move goes to the signer with its digest and expiry, so the signer holds it in flight from the moment it is sent", async () => {
  const { home, asked } = rig({
    buildSweep: () => SIGNED,
    send: () => null,
    status: () => ({ state: "landed" }),
  });
  await home.sweep({ kind: "sweep", chain: "sui", amount: 7n }, "0x88A5b9350c722D25579a5EF1C5C613f923460c04", 3n);
  const send = asked.find((a) => a.op === "send");
  assert.deepEqual(send.args, { raw: SIGNED.raw, signature: SIGNED.signature, expiry: SIGNED.expiry });
  assert.equal(asked.find((a) => a.op === "buildSweep").args.maxFee, "3", "the route's fee bound goes with the sweep (PD-12)");
});

test("PD-8: a move whose fate the node cannot show stays signed, is not sent again, and the reason is reported", async () => {
  const { home, journal, asked } = rig({ send: () => null, status: () => ({ state: "unknown", reason: "the node keeps slots from 401 only" }) });
  const id = journal.open({ kind: "sweep", chain: "sui", amount: 5n }, { chain: "sui", raw: "r", hash: "d", expiry: "e" });
  await assert.rejects(home.resume(journal.get(id)), /whether it landed is unknown: the node keeps slots from 401 only/);
  assert.equal(journal.get(id).stage, "signed");
  assert.equal(asked.filter((a) => a.op === "send").length, 0);
});

test("PD-11: a signer whose input closed under a write fails what is waiting, and the service goes on", async () => {
  const dir = mkdtempSync(join(tmpdir(), "signer-"));
  const path = join(dir, "closes-input.mjs");
  writeFileSync(path, 'import { closeSync } from "node:fs";\ncloseSync(0);\nsetTimeout(() => {}, 3000);\n');
  const ask = startSigner({ env: { PATH: process.env.PATH ?? "" }, path, label: "test", timeoutMs: 10_000 });
  const first = ask("info");
  await new Promise((r) => setTimeout(r, 500)); // the signer has closed its input by now
  const second = ask("info");
  // Unheard, the EPIPE of the second write would end this process here.
  await assert.rejects(second, /the test signer failed: .*EPIPE|the test signer (failed|exited)/);
  await assert.rejects(first, /the test signer/);
});
