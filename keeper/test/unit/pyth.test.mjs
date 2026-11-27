import { test } from "node:test";
import assert from "node:assert/strict";
import { createPythFor } from "../../bot/pyth.mjs";

const FACTORY = `0x${"fa".repeat(20)}`;
const READER = `0x${"4e".repeat(20)}`;
const PYTH = `0x${"97".repeat(20)}`;
const [A, B, C, D] = ["a1", "b2", "c3", "d4"].map((x) => `0x${x.repeat(20)}`);
const X = `0x${"11".repeat(32)}`;
const Y = `0x${"22".repeat(32)}`;
const ABI = { factory: "factory-abi", pyth: "pyth-abi", prices: "prices-abi" };
const L = { number: 100n };
const OVER = { block: { number: 101n, time: 1_000n } };

/// A chain and a Hermes that answer from `world` and record what they were asked.
function fakes(world) {
  const asked = { multicall: [], read: [], callAfter: [], hermes: [] };
  const chain = {
    multicall: async (contracts, blockNumber) => {
      asked.multicall.push({ contracts, blockNumber });
      return contracts.map((c) => world.feeds[c.args[0]] ?? { status: "failure" });
    },
    read: async (...args) => {
      asked.read.push(args);
      return world.fee;
    },
    callAfter: async (calls, blockNumber, over) => {
      asked.callAfter.push({ calls, blockNumber, over });
      return [world.posted ?? { ok: true, result: undefined }, ...calls.slice(1).map((c) => world.values[`${c.args[0]}:${c.args[1]}`])];
    },
  };
  const hermes = {
    latestSigned: async (ids, deadline) => {
      asked.hermes.push({ ids, deadline });
      return { prices: new Map(), updates: world.updates };
    },
  };
  const pythFor = createPythFor({
    chain,
    hermes,
    factory: FACTORY,
    abi: ABI,
    hermesMs: 5_000,
    revertReason: (error) => `reason:${error.data}`,
    now: () => 1_000_000,
  });
  return { pythFor, asked };
}

const feed = (id, kind) => ({ status: "success", result: { id, kind } });
const ST = { tokens: [A, B, C, D], reader: READER, pyth: PYTH };
const ok = (result) => ({ ok: true, result });
const refused = { ok: false, error: { data: "0xdead" } };

test("a factory without an oracle posts nothing and asks nothing", async () => {
  const { pythFor, asked } = fakes({});
  assert.equal(await pythFor({ tokens: [A, B], reader: null, pyth: null }, L, OVER, [true, true]), null);
  assert.deepEqual(asked, { multicall: [], read: [], callAfter: [], hermes: [] });
});

test("the update is for the feeds of the legs the keeper may move, once each, and every leg is valued after it, both ways", async () => {
  const world = {
    // A and C share a feed; B has none; D is not the keeper's to move and is never asked about.
    feeds: { [A]: feed(X, 1), [B]: feed(`0x${"00".repeat(32)}`, 0), [C]: feed(X, 2) },
    updates: ["0xaa"],
    fee: 7n,
    values: { [`${A}:true`]: ok(11n), [`${A}:false`]: ok(10n), [`${C}:true`]: ok(31n), [`${C}:false`]: ok(30n) },
  };
  const { pythFor, asked } = fakes(world);
  const got = await pythFor(ST, L, OVER, [true, true, true, false]);

  assert.deepEqual(asked.multicall[0].contracts.map((c) => [c.address, c.abi, c.functionName, c.args[0]]), [
    [FACTORY, ABI.factory, "priceFeedOf", A],
    [FACTORY, ABI.factory, "priceFeedOf", B],
    [FACTORY, ABI.factory, "priceFeedOf", C],
  ]);
  assert.equal(asked.multicall[0].blockNumber, 100n);
  assert.deepEqual(asked.hermes, [{ ids: [X], deadline: 1_005_000 }], "one feed, asked once, within the Hermes budget");
  assert.deepEqual(asked.read, [[PYTH, ABI.pyth, "getUpdateFee", [["0xaa"]], 100n]]);

  const post = { to: PYTH, abi: ABI.pyth, functionName: "updatePriceFeeds", args: [["0xaa"]], value: 7n };
  assert.deepEqual(got.post, post, "the update is posted to the index's own Pyth, for exactly its fee");
  const { calls, blockNumber, over } = asked.callAfter[0];
  assert.deepEqual(calls[0], post, "the update goes first");
  assert.deepEqual(
    calls.slice(1).map((c) => [c.to, c.abi, c.functionName, ...c.args]),
    [
      [READER, ABI.prices, "valueOf", A, true],
      [READER, ABI.prices, "valueOf", A, false],
      [READER, ABI.prices, "valueOf", C, true],
      [READER, ABI.prices, "valueOf", C, false],
    ],
    "then each fed leg, leaving and arriving",
  );
  assert.equal(blockNumber, 100n);
  assert.equal(over, OVER, "under the overrides the fill is simulated with");

  assert.deepEqual(got.updates, ["0xaa"]);
  assert.equal(got.fee, 7n);
  assert.deepEqual(got.leaving, [11n, null, 31n, null], "a leg without a feed, and one not asked about, has no value");
  assert.deepEqual(got.arriving, [10n, null, 30n, null]);
});

test("a leg the reader cannot value one way has no value either way", async () => {
  const world = {
    feeds: { [A]: feed(X, 1), [C]: feed(Y, 1) },
    updates: ["0xaa", "0xbb"],
    fee: 14n,
    values: { [`${A}:true`]: ok(11n), [`${A}:false`]: refused, [`${C}:true`]: ok(31n), [`${C}:false`]: ok(30n) },
  };
  const { pythFor, asked } = fakes(world);
  const got = await pythFor({ tokens: [A, C], reader: READER, pyth: PYTH }, L, OVER, [true, true]);
  assert.deepEqual(asked.hermes[0].ids, [X, Y]);
  assert.deepEqual(got.leaving, [null, 31n], "the first leg is left alone, the second keeps its own values");
  assert.deepEqual(got.arriving, [null, 30n]);
  assert.equal(got.post.value, 14n);
});

test("with no fed leg nothing is fetched or posted", async () => {
  const { pythFor, asked } = fakes({ feeds: { [A]: feed(`0x${"00".repeat(32)}`, 0) } });
  const got = await pythFor({ tokens: [A, B], reader: READER, pyth: PYTH }, L, OVER, [true, false]);
  assert.deepEqual(got, { updates: [], fee: 0n, post: null, leaving: [null, null], arriving: [null, null] });
  assert.deepEqual([asked.hermes, asked.read, asked.callAfter], [[], [], []]);
});

test("a feed that cannot be read, a Hermes that serves nothing and a Pyth that refuses each stop the round", async () => {
  const unread = fakes({ feeds: {} });
  await assert.rejects(unread.pythFor(ST, L, OVER, [true, false, false, false]), /a price feed read failed/);

  const silent = fakes({ feeds: { [A]: feed(X, 1) }, updates: [], fee: 0n, values: {} });
  await assert.rejects(silent.pythFor(ST, L, OVER, [true, false, false, false]), /Hermes served no update/);
  assert.deepEqual(silent.asked.callAfter, [], "nothing is posted without an update");

  const refusing = fakes({ feeds: { [A]: feed(X, 1) }, updates: ["0xaa"], fee: 7n, posted: refused, values: {} });
  await assert.rejects(refusing.pythFor(ST, L, OVER, [true, false, false, false]), /Pyth refused the update Hermes served: reason:0xdead/);
});
