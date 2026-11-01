import { test } from "node:test";
import assert from "node:assert/strict";
import { checkAggregator, missingObject, missingTransaction, payWithFloor, suiFate } from "../../restock/sui/checks.mjs";

const DIGEST = "Dig3st";
const coin = (version, read) => ({ objectId: "0xgas", version: String(version), read });

test("PD-5: only a gas coin that is gone or at another version counts a Sui transaction expired; a read error is no evidence", () => {
  const at = (coins, epochNow = 5n, epoch = "6") => suiFate({ digest: DIGEST, found: null, coins, epochNow, epoch });
  assert.deepEqual(suiFate({ digest: DIGEST, found: { success: true, checkpoint: 9 }, coins: [], epochNow: 0n, epoch: "6" }), { state: "landed", at: "9" });
  assert.deepEqual(suiFate({ digest: DIGEST, found: { success: false, checkpoint: 9 }, coins: [], epochNow: 0n, epoch: "6" }), { state: "reverted", at: "9" });
  assert.deepEqual(at([coin(3, { version: "3", previousTransaction: "Other" })]), { state: "pending" }, "its coins untouched, its epoch open");
  assert.deepEqual(at([coin(3, { version: "4", previousTransaction: DIGEST })]), { state: "pending" }, "a coin it moved: it executed");
  assert.match(at([coin(3, { version: "4", previousTransaction: "Other" })]).reason, /moved to another version/);
  assert.match(at([coin(3, null)]).reason, /no longer exists/);
  assert.match(at([coin(3, { version: "3", previousTransaction: "x" })], 7n).reason, /epoch 6 ended/);
  // The SDK's errors, by their fields: a missing object or transaction, and nothing else.
  assert.equal(missingObject({ code: "notExists", reason: "notFound" }), true);
  assert.equal(missingObject({ code: "UNAVAILABLE", message: "upstream connect error" }), false, "a transport failure is no evidence");
  assert.equal(missingObject({ code: "RESOURCE_EXHAUSTED" }), false, "nor is a rate limit");
  assert.equal(missingObject(new Error("timeout")), false);
  assert.equal(missingTransaction({ reason: "notFound" }), true);
  assert.equal(missingTransaction({ code: "DEADLINE_EXCEEDED" }), false);
});

test("PD-3: the swap's input goes only to Cetus's own aggregator package, or an upgrade of it", async () => {
  const PINNED = "0xffd4";
  const originals = new Map([[PINNED, "0xorig"], ["0xupgrade", "0xorig"], ["0xattacker", "0xevil"]]);
  const originalOf = async (id) => originals.get(id);
  await checkAggregator(undefined, PINNED, originalOf);
  await checkAggregator(new Map(), PINNED, originalOf);
  await checkAggregator(new Map([["aggregator_v3", PINNED]]), PINNED, originalOf);
  await checkAggregator(new Map([["aggregator_v3", "0xupgrade"]]), PINNED, originalOf);
  await checkAggregator({ aggregator_v3: "0xupgrade" }, PINNED, originalOf);
  await assert.rejects(checkAggregator(new Map([["aggregator_v3", "0xattacker"]]), PINNED, originalOf), /0xattacker, which is not an upgrade of 0xffd4/);
  await assert.rejects(checkAggregator({ aggregator_v3: "0xattacker" }, PINNED, originalOf), /not an upgrade/);
});

test("PD-3: the floor is split off the swap's output inside the transaction before both coins go to the wallet", () => {
  const calls = [];
  const tx = {
    pure: { u64: (v) => ({ u64: v }) },
    splitCoins: (from, amounts) => (calls.push(["split", from, amounts]), [{ coin: "floor" }]),
    transferObjects: (objects, to) => calls.push(["transfer", objects, to]),
  };
  payWithFloor(tx, { coin: "output" }, 4_950n, "0xme");
  assert.deepEqual(calls, [
    ["split", { coin: "output" }, [{ u64: 4_950n }]],
    ["transfer", [{ coin: "floor" }, { coin: "output" }], "0xme"],
  ]);
});
