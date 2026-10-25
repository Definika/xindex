import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as nodeFs from "node:fs";
import { createJournal, fileStore } from "../../restock/journal.mjs";

const XRP = `0x${"c7".repeat(20)}`;

/// A journal over an in-memory store, which a "restart" reads back.
function store() {
  const s = { text: null, t: 1_000 };
  s.open = () => createJournal({ load: () => s.text, save: (text) => (s.text = text), now: () => s.t });
  return s;
}

test("a move is saved as signed before it is sent, and a restart finds it there, to send that same transaction", () => {
  const s = store();
  const j = s.open();
  const id = j.open({ kind: "bridgeIn", coin: "XRP", copy: XRP, chain: "bsc", amount: 5n }, { raw: "0xsigned", hash: "0xh" });
  const again = s.open();
  assert.deepEqual(again.pending().map((m) => [m.id, m.stage, m.data.hash]), [[id, "signed", "0xh"]]);
  assert.equal(again.inflight().get(XRP).in, 5n, "counted as crossing from the moment it is signed");
  assert.ok(again.busy().has("XRP"), "and its coin is held until the transaction is out");
  again.advance(id, "sent", { sequence: "17" });
  assert.ok(!again.busy().has("XRP"), "out: now only in flight");
  again.advance(id, "attested", { vaa: "0xvaa" });
  again.advance(id, "redeemed");
  assert.deepEqual(s.open().pending(), [], "settled");
  assert.equal(s.open().inflight().size, 0);
  assert.equal(s.open().get(id).data.sequence, "17", "each stage's data kept");
  const other = again.open({ kind: "sell", coin: "XRP", chain: "bsc", amount: 1n }, { hash: "0x1" });
  again.note(other, { block: "9" });
  assert.deepEqual(s.open().get(other).data, { hash: "0x1", block: "9" });
  assert.equal(s.open().get(other).stage, "signed", "a note moves nothing on");
});

test("a move only moves forward, never past its settlement, and only an unsent one is dropped", () => {
  const j = store().open();
  const id = j.open({ kind: "buy", coin: "XRP", chain: "bsc", usd: 200, amountIn: 9n }, {});
  assert.throws(() => j.advance(id, "signed"), /cannot go from signed to signed/);
  j.advance(id, "sent");
  assert.throws(() => j.drop(id, "expired"), /only an unsent or reverted move is dropped/);
  j.advance(id, "done");
  assert.throws(() => j.advance(id, "done"), /has settled/);
  const unsent = j.open({ kind: "sell", coin: "XRP", chain: "bsc", amount: 1n }, {});
  j.drop(unsent, "blockhash expired");
  assert.equal(j.get(unsent).stage, "dropped");
  assert.equal(j.pending().length, 0);
  assert.throws(() => j.open({ kind: "swap" }, {}), /unknown move kind swap/);
  const reverted = j.open({ kind: "buy", coin: "XRP", chain: "bsc", usd: 1, amountIn: 1n }, {});
  j.advance(reverted, "sent", { status: "reverted" });
  j.drop(reverted, "the swap reverted");
  assert.equal(j.get(reverted).stage, "dropped");
});

test("buys count against the day's budget until a day has passed, dropped ones never", () => {
  const s = store();
  const j = s.open();
  j.open({ kind: "buy", coin: "XRP", chain: "bsc", usd: 300, amountIn: 1n }, {});
  const dropped = j.open({ kind: "buy", coin: "XRP", chain: "bsc", usd: 900, amountIn: 1n }, {});
  j.drop(dropped, "expired");
  assert.equal(j.spentUsd(), 300);
  s.t += 86_400 + 1;
  assert.equal(j.spentUsd(), 0);
});

test("funding, sweeps and the treasury's moves hold their chain or the treasury", () => {
  const j = store().open();
  const fund = j.open({ kind: "fund", chain: "sui", amount: 8_000n }, {});
  j.open({ kind: "draw", amount: 3n }, {});
  assert.deepEqual([...j.busy()].sort(), ["sui", "treasury"]);
  assert.equal(j.funding().get("sui"), 8_000n);
  j.advance(fund, "sent");
  j.advance(fund, "attested");
  j.advance(fund, "received");
  assert.equal(j.funding().size, 0);
});

test("settled moves are forgotten after a week, a bridge out counts as leaving until then", () => {
  const s = store();
  const j = s.open();
  const out = j.open({ kind: "bridgeOut", coin: "XRP", copy: XRP, chain: "bsc", amount: 4n }, {});
  assert.equal(j.inflight().get(XRP).out, 4n);
  for (const stage of ["sent", "attested", "redeemed"]) j.advance(out, stage);
  s.t += 7 * 86_400 - 1;
  j.prune();
  assert.ok(j.get(out), "kept for the week");
  s.t += 2;
  j.prune();
  assert.equal(j.get(out), undefined);
});

test("RS-13: an empty or unreadable journal stops the service, never starts it afresh", () => {
  const save = () => {};
  for (const text of ["", "{", "null"]) {
    assert.throws(() => createJournal({ load: () => text, save }), /journal is empty or unreadable/, `${JSON.stringify(text)}`);
  }
  assert.deepEqual(createJournal({ load: () => null, save }).pending(), [], "no journal at all: the first start");
});

test("RS-13: a change whose save fails is not kept, so no move the disk does not hold is ever sent", () => {
  let fail = true;
  let text = null;
  const j = createJournal({ load: () => text, save: (t) => { if (fail) throw new Error("ENOSPC"); text = t; } });
  assert.throws(() => j.open({ kind: "draw", amount: 5n }, { raw: "0xsigned", hash: "0xh", nonce: 7 }), /ENOSPC/);
  assert.deepEqual(j.pending(), [], "the round that resumes signed moves finds none");
  fail = false;
  const id = j.open({ kind: "draw", amount: 5n }, { raw: "0xsigned", hash: "0xh", nonce: 7 });
  assert.equal(id, "1", "the id the failed save took is given again");
  fail = true;
  assert.throws(() => j.advance(id, "sent", { status: "success" }), /ENOSPC/);
  assert.equal(j.get(id).stage, "signed", "a stage not saved is not taken");
  assert.equal(JSON.parse(text).moves[id].stage, "signed");
});

/// An fs that records every call it gets, over a real folder.
function recordingFs() {
  const calls = [];
  const real = { ...nodeFs };
  const fs = new Proxy(real, {
    get: (target, name) => (...args) => {
      calls.push([name, ...args.map((a, i) => (name === "writeFileSync" && i === 1 ? "<text>" : a))]);
      return target[name](...args);
    },
  });
  return { fs, calls };
}

test("RS-13: the journal reaches the disk before the transaction it records is sent", () => {
  const dir = mkdtempSync(join(tmpdir(), "journal-"));
  const path = join(dir, "restock.json");
  const { fs, calls } = recordingFs();
  const store = fileStore(path, fs);
  store.save(`${JSON.stringify({ next: 2, moves: { 1: { id: "1", kind: "draw", stage: "signed" } } })}\n`);
  const names = calls.map((c) => c[0]).filter((n) => n !== "existsSync");
  assert.deepEqual(names, ["openSync", "writeFileSync", "fsyncSync", "closeSync", "renameSync", "openSync", "fsyncSync", "closeSync"],
    "written to a temporary file and flushed, renamed into place, then the folder flushed, which makes the rename last");
  assert.equal(calls[0][1], `${path}.tmp`);
  assert.equal(calls[4][2], path);
  assert.equal(calls[5][1], dir);
  assert.match(store.load(), /"draw"/);
  assert.deepEqual(readdirSync(dir), ["restock.json"], "no temporary file left");
});
