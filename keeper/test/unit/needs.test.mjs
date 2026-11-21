import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { NEEDS_MAX_AGE_SECONDS, createNeeds, readNeeds, totalNeeds } from "../../bot/needs.mjs";

const XRP = `0x${"c7".repeat(20)}`;
const ADA = `0x${"8e".repeat(20)}`;

function board() {
  const b = { t: 1_000, text: "" };
  b.needs = createNeeds({ write: (text) => (b.text = text), now: () => b.t });
  return b;
}

test("one stock serves every fill, so a coin's needs are summed whole, not as shortfalls", () => {
  const b = board();
  b.needs.report("0xa:1", "fill", [{ token: XRP.toUpperCase().replace("0X", "0x"), amount: 150n }]);
  b.needs.report("request:7", "request", [
    { token: XRP, amount: 120n },
    { token: ADA, amount: 5n },
  ]);
  b.needs.flush();
  const total = totalNeeds(b.text, b.t);
  assert.equal(total.get(XRP), 270n, "both fills' XRP, lowercased into one entry");
  assert.equal(total.get(ADA), 5n);
});

test("a report replaces the last for its key, and an empty one clears it", () => {
  const b = board();
  b.needs.report("0xa:1", "fill", [{ token: XRP, amount: 150n }]);
  b.needs.report("0xa:1", "fill", [{ token: XRP, amount: 90n }]);
  b.needs.flush();
  assert.equal(totalNeeds(b.text, b.t).get(XRP), 90n);
  b.needs.report("0xa:1", "fill", []);
  b.needs.flush();
  assert.equal(totalNeeds(b.text, b.t).size, 0, "covered now: nothing to bring in");
});

test("a report nobody renews goes stale and is dropped, on both sides of the file", () => {
  const b = board();
  b.needs.report("0xa:1", "start", [{ token: XRP, amount: 150n }]);
  b.t += 800; // the keeper still writing the board, the report no longer renewed
  b.needs.flush();
  const written = b.text;
  assert.equal(totalNeeds(written, b.t + 100).get(XRP), 150n, "fresh up to the limit");
  assert.equal(totalNeeds(written, b.t + 101).size, 0, "the reader drops a fresh board's stale report");
  b.t += NEEDS_MAX_AGE_SECONDS + 1;
  b.needs.flush();
  assert.deepEqual(JSON.parse(b.text).needs, [], "and the writer drops it from the board");
});

test("RS-8: a board that is unreadable, or that the keeper stopped writing, is unknown, not empty", () => {
  assert.equal(totalNeeds("", 0), null);
  assert.equal(totalNeeds("{not json", 0), null);
  assert.equal(totalNeeds("null", 0), null);
  assert.equal(totalNeeds('{"needs":[]}', 0), null, "a board without the time it was written");
  const b = board();
  b.needs.flush();
  assert.equal(totalNeeds(b.text, b.t + NEEDS_MAX_AGE_SECONDS).size, 0, "written within the limit: nothing needed");
  assert.equal(totalNeeds(b.text, b.t + NEEDS_MAX_AGE_SECONDS + 1), null, "not written since: unknown");
});

test("RS-8: a board the keeper never wrote is unknown too", () => {
  const dir = mkdtempSync(join(tmpdir(), "needs-"));
  const file = join(dir, "needs.json");
  assert.equal(readNeeds(file, 1_000), null, "no file: the keeper has not written it, or writes it elsewhere");
  const b = board();
  b.needs.report("0xa:1", "fill", [{ token: XRP, amount: 7n }]);
  b.needs.flush();
  writeFileSync(file, b.text);
  assert.equal(readNeeds(file, b.t).get(XRP), 7n);
});

test("CA-R2-02: the board is dated by the last round that looked, not by the last write", () => {
  const b = board();
  b.needs.report("0xa:1", "fill", [{ token: XRP, amount: 150n }]);
  b.needs.flush();
  assert.equal(JSON.parse(b.text).updatedAt, 1_000);

  // Fifteen minutes of rounds that failed, or stopped behind a transaction in flight: each still flushes.
  for (let k = 0; k < 91; k++) {
    b.t += 10;
    b.needs.flush({ observed: false });
  }
  assert.equal(b.t, 1_910);
  assert.deepEqual(JSON.parse(b.text).needs, [], "the report of the last round that looked has lapsed");
  assert.equal(JSON.parse(b.text).updatedAt, 1_000, "and the board still carries that round's date");
  assert.equal(totalNeeds(b.text, b.t), null, "so it reads as unknown, not as nothing needed");

  // A round that looks again dates it again: nothing needed is then a finding.
  b.t += 10;
  b.needs.flush({ observed: true });
  assert.equal(totalNeeds(b.text, b.t).size, 0);
});

test("CA-R2-02: a keeper that has not looked yet writes no board over the one before it", () => {
  const b = board();
  b.text = "the board an earlier run left";
  b.needs.report("0xa:1", "fill", [{ token: XRP, amount: 150n }]);
  b.needs.flush({ observed: false });
  assert.equal(b.text, "the board an earlier run left");
  b.needs.flush({ observed: true });
  assert.equal(totalNeeds(b.text, b.t).get(XRP), 150n, "its first look writes what it found");
});

test("CA-L6: a board that is not what the keeper writes is unknown, never read in part", () => {
  const entry = { key: "0xa:1", source: "fill", token: XRP, amount: "150", seenAt: 1_000 };
  const read = (over, updatedAt = 1_000) => totalNeeds(JSON.stringify({ updatedAt, needs: [{ ...entry, ...over }] }), 1_000);
  assert.equal(read({}).get(XRP), 150n, "the keeper's own entry");
  assert.equal(read({ token: XRP.toUpperCase().replace("0X", "0x") }).get(XRP), 150n, "a token in any case is one token");

  assert.equal(read({}, 1_061), null, "a board dated ahead of the clock");
  assert.equal(read({}, 1_060).get(XRP), 150n, "within a minute of it, two clocks that keep time");
  assert.equal(read({}, 999.5), null, "a date that is no whole second");
  assert.equal(read({}, -1), null);
  assert.equal(read({ seenAt: undefined }), null, "a report with no time, which no age could drop");
  assert.equal(read({ seenAt: 1_061 }), null, "a report from the future");
  assert.equal(read({ seenAt: "1000" }), null);
  assert.equal(read({ token: "0x1234" }), null, "a token that is no address");
  assert.equal(read({ token: 7 }), null);
  assert.equal(read({ amount: 150 }), null, "an amount that is not the string the keeper writes");
  assert.equal(read({ amount: "-150" }), null);
  assert.equal(read({ amount: "1.5" }), null);
  assert.equal(read({ amount: "0x96" }), null);
  assert.equal(read({ amount: "" }), null);
  assert.equal(totalNeeds(JSON.stringify({ updatedAt: 1_000, needs: [entry, null] }), 1_000), null, "one bad entry spoils the board");
});
