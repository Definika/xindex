import { test } from "node:test";
import assert from "node:assert/strict";
import {
  Backoff,
  MAX_REVERTED_FILLS,
  MAX_REVERTED_REQUEST_FILLS,
  failedRequests,
  revertedFills,
  revertedRequestFills,
} from "../../bot/backoff.mjs";

test("XS-4: an auction whose fills revert on chain waits, then is left after three", () => {
  const b = revertedFills();
  const key = "0xindex:1";
  assert.equal(b.blocked(key, 100), false);
  assert.deepEqual(b.fail(key, 100), { failures: 1, until: 105, stopped: false });
  assert.equal(b.blocked(key, 104), true, "five blocks after the first");
  assert.equal(b.blocked(key, 105), false);
  assert.deepEqual(b.fail(key, 105), { failures: 2, until: 115, stopped: false });
  assert.equal(b.blocked(key, 114), true, "ten after the second");
  assert.equal(b.fail(key, 115).stopped, true);
  assert.equal(MAX_REVERTED_FILLS, 3);
  assert.equal(b.blocked(key, 1_000_000), true, "after the third, never again for that auction");
  assert.equal(b.blocked("0xindex:2", 116), false, "the index's next auction starts afresh");
  b.keep(["0xindex:2"]);
  assert.equal(b.blocked(key, 116), false, "an auction that closed is forgotten");
});

test("XS-7: a request whose simulation failed waits 2, 4, 8... blocks, at most 200, and is never stopped", () => {
  const b = failedRequests();
  const key = "request:9";
  const waits = [];
  for (let n = 0; n < 12; n++) {
    const e = b.fail(key, 1_000);
    waits.push(e.until - 1_000);
    assert.equal(e.stopped, false);
  }
  assert.deepEqual(waits, [2, 4, 8, 16, 32, 64, 128, 200, 200, 200, 200, 200]);
  assert.equal(b.blocked(key, 1_199), true);
  assert.equal(b.blocked(key, 1_200), false);
  assert.equal(b.failures(key), 12);
  b.forget(key);
  assert.equal(b.failures(key), 0);
  assert.ok(new Backoff({ blocks: 1 }) instanceof Backoff);
});

test("XS-7: a request whose fills revert on chain waits, then is left after three", () => {
  const b = revertedRequestFills();
  const key = "request:4";
  assert.deepEqual(b.fail(key, 100), { failures: 1, until: 105, stopped: false });
  assert.equal(b.blocked(key, 104), true);
  assert.equal(b.blocked(key, 105), false);
  b.fail(key, 105);
  assert.equal(b.blocked(key, 114), true);
  assert.equal(b.fail(key, 115).stopped, true);
  assert.equal(MAX_REVERTED_REQUEST_FILLS, 3);
  assert.equal(b.blocked(key, 1_000_000), true, "after the third, never again for that request");
  b.keep([]);
  assert.equal(b.blocked(key, 1_000_000), false, "a request no longer open is forgotten");
});
