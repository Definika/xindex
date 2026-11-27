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
  b.fail(key, 116);
  b.fail("0xindex:2", 116);
  assert.equal(b.blocked(key, 117), true, "a fresh strike holds the auction");
  b.keep(["0xindex:2"]);
  assert.equal(b.blocked(key, 117), false, "an auction that closed is forgotten");
  assert.equal(b.failures(key), 0);
  assert.equal(b.blocked("0xindex:2", 117), true, "and one still open is kept");
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

test("a request short of stock is checked again within the life of its report on the restock's board", async () => {
  const { SHORT_RECHECK_BLOCKS, shortRequests } = await import("../../bot/backoff.mjs");
  const { NEEDS_MAX_AGE_SECONDS } = await import("../../bot/needs.mjs");
  const b = shortRequests();
  let block = 100;
  let longest = 0;
  for (let k = 0; k < 12; k++) {
    const { until, stopped } = b.fail("request:1", block);
    assert.equal(stopped, false, "it is never given up: the coins may land");
    longest = Math.max(longest, until - block);
    block = until;
  }
  assert.equal(longest, SHORT_RECHECK_BLOCKS, "the wait doubles up to its cap");
  // Twelve-second blocks: the report is renewed before it lapses, so the need never leaves the board while it waits.
  assert.ok(SHORT_RECHECK_BLOCKS * 12 < NEEDS_MAX_AGE_SECONDS);
  // The decline of a request that pays too little may wait far longer: it asks the restock for nothing it must keep.
  assert.ok(skippedRequests().fail("request:1", 0).until < SHORT_RECHECK_BLOCKS);
});
