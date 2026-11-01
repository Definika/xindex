import { test } from "node:test";
import assert from "node:assert/strict";
import { createInflight, refusedOutright } from "../../restock/inflight.mjs";

test("PD-6: a signed transaction holds nothing until it is sent; once sent, nothing is built while it may still execute", async () => {
  let state = "pending";
  const asked = [];
  const inflight = createInflight(async (e) => (asked.push(e.id), { state }));
  // The parent signed a move, gave up waiting for the answer, and never journalled or sent it: the signer is free.
  await inflight.idle();
  assert.deepEqual(asked, [], "nothing sent, nothing asked");
  inflight.sent({ id: "tx1" });
  await assert.rejects(inflight.idle(), /tx1 may still execute \(pending\)/);
  state = "unknown";
  await assert.rejects(inflight.idle(), /tx1 may still execute \(unknown\)/, "an answer that cannot tell holds it too");
  state = "expired";
  await inflight.idle();
  assert.equal(inflight.current(), null, "settled: forgotten");
  await inflight.idle();
  assert.deepEqual(asked, ["tx1", "tx1", "tx1"]);
});

test("PD-6: a completing step is sent again while it may still execute; a move is not, being the parent's to send", async () => {
  const sent = [];
  const inflight = createInflight(async () => ({ state: "pending" }));
  inflight.sent({ id: "redeem", resend: async () => sent.push("redeem") });
  await assert.rejects(inflight.idle());
  assert.deepEqual(sent, ["redeem"]);
  inflight.sent({ id: "move" });
  await assert.rejects(inflight.idle());
  assert.deepEqual(sent, ["redeem"], "the move is not sent from here");
  inflight.clear("other");
  assert.equal(inflight.current().id, "move", "clearing another transaction leaves this one");
  inflight.clear("move");
  assert.equal(inflight.current(), null);
});

test("PD-6: refused outright is a 4xx or a gRPC status naming the transaction invalid; a timeout, 5xx or rate limit may have sent it", () => {
  for (const e of [{ code: "INVALID_ARGUMENT" }, { code: "FAILED_PRECONDITION" }, { status: 400 }, { response: { status: 400 } }, { statusCode: 403 }]) {
    assert.equal(refusedOutright(e), true, JSON.stringify(e));
  }
  for (const e of [{ code: "UNAVAILABLE" }, { code: "DEADLINE_EXCEEDED" }, { status: 429 }, { status: 408 }, { status: 503 }, { status: 404 }, new Error("socket hang up"), null]) {
    assert.equal(refusedOutright(e), false, JSON.stringify(e));
  }
});
