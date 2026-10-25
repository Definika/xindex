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
