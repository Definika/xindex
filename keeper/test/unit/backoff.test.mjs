import { test } from "node:test";
import assert from "node:assert/strict";
import {
  Backoff,
  MAX_REVERTED_FILLS,
  MAX_REVERTED_REQUEST_FILLS,
  STRIKE_LAPSE_BLOCKS,
  failedRequests,
  skippedRequests,
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
  assert.equal(b.blocked(key, 115 + 299), true, "after the third, left while the strikes last");
  assert.equal(b.blocked(key, 115 + STRIKE_LAPSE_BLOCKS), false, "RX-26: the strikes lapse, and the auction is open again");
  assert.equal(b.failures(key), 0, "afresh");
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
  assert.equal(b.blocked(key, 115 + STRIKE_LAPSE_BLOCKS - 1), true, "after the third, left while the strikes last");
  b.keep([]);
  assert.equal(b.blocked(key, 116), false, "a request no longer open is forgotten");
});

test("RX-26: three induced reverts cost the bot an hour of the auction, then each strike starts afresh", () => {
  const b = revertedFills();
  const key = "0xindex:7";
  b.fail(key, 1000);
  b.fail(key, 1005);
  assert.equal(b.fail(key, 1015).stopped, true);
  assert.equal(b.blocked(key, 1314), true);
  assert.equal(b.blocked(key, 1315), false);
  assert.deepEqual(b.fail(key, 1400), { failures: 1, until: 1405, stopped: false }, "a new strike counts from one");
});

test("RX-24: a request that keeps being declined without a revert waits longer each time", () => {
  const b = skippedRequests();
  assert.deepEqual(b.fail("request:1", 10), { failures: 1, until: 12, stopped: false });
  assert.deepEqual(b.fail("request:1", 12), { failures: 2, until: 16, stopped: false });
  for (let i = 0; i < 10; i++) b.fail("request:1", 100);
  assert.equal(b.blocked("request:1", 299), true, "at most 200 blocks");
  assert.equal(b.blocked("request:1", 300), false);
});
