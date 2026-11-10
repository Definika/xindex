import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { createHermes, HermesError } from "../../bot/hermes.mjs";

const A = `0x${"aa".repeat(32)}`;
const B = `0x${"bb".repeat(32)}`;
let server;
let base;
let handler = () => {};
const seen = [];

before(async () => {
  server = http.createServer((req, res) => {
    seen.push({ url: req.url, auth: req.headers.authorization });
    handler(req, res, new URL(req.url, "http://x"));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${server.address().port}/hermes/`;
});
after(() => server.close());

const reset = (h) => {
  seen.length = 0;
  handler = h;
};
const json = (res, body, status = 200, headers = {}) =>
  res.writeHead(status, { "content-type": "application/json", ...headers }).end(JSON.stringify(body));
const entry = (id, publishTime, price = "250000000000", ema = price) => ({
  id: id.slice(2),
  price: { price, conf: "100000", expo: -8, publish_time: publishTime },
  ema_price: { price: ema, conf: "90000", expo: -8, publish_time: publishTime },
});
const hermes = () => createHermes({ url: base, apiKey: "k3y" });
const soon = (ms = 2000) => Date.now() + ms;

test("latestSigned(): the latest prices and their signed update, with the key as a Bearer token", async () => {
  reset((req, res, url) => {
    assert.equal(url.pathname, "/hermes/v2/updates/price/latest");
    assert.deepEqual(url.searchParams.getAll("ids[]"), [A, B]);
    assert.equal(url.searchParams.get("encoding"), "hex");
    assert.equal(url.searchParams.get("parsed"), "true");
    json(res, { binary: { encoding: "hex", data: ["504e4155"] }, parsed: [entry(A, 1000, "250000000000", "200000000000"), entry(B, 1011, "-5")] });
  });
  const { updates, prices } = await hermes().latestSigned([A, B], soon());
  assert.deepEqual(updates, ["0x504e4155"]);
  assert.equal(seen[0].auth, "Bearer k3y");
  // Each price comes with the moving average Hermes publishes beside it: Pyth's contract returns both, and the bot
  // keeps a price only when both are the signed update's (RY-7).
  assert.deepEqual(prices.get(A.slice(2)), {
    price: 250000000000n,
    conf: 100000n,
    expo: -8,
    publishTime: 1000,
    ema: { price: 200000000000n, conf: 90000n, expo: -8, publishTime: 1000 },
  });
  assert.equal(prices.get(B.slice(2)).price, -5n);
});

test("404 and 5xx are retried until Hermes answers", async () => {
  let n = 0;
  reset((req, res) => {
    n++;
    if (n === 1) return json(res, { error: "no update yet" }, 404);
    if (n === 2) return json(res, { error: "busy" }, 503);
    json(res, { binary: { data: ["00"] }, parsed: [entry(A, 1000)] });
  });
  await hermes().latest([A], soon());
  assert.equal(seen.length, 3);
});

test("retries stop at the deadline", async () => {
  reset((req, res) => json(res, { error: "no update yet" }, 404));
  const started = Date.now();
  await assert.rejects(hermes().latest([A], soon(600)), (e) => e instanceof HermesError && !e.permanent);
  assert.ok(Date.now() - started < 1500, "gave up near the deadline");
});

test("400 and 401 are permanent: no retry", async () => {
  for (const status of [400, 401]) {
    reset((req, res) => json(res, { error: "no" }, status));
    await assert.rejects(hermes().latest([A], soon()), (e) => e.permanent === true && e.status === status);
    assert.equal(seen.length, 1);
  }
});

test("429 waits at least a second, and gives up when the deadline comes first", async () => {
  reset((req, res) => json(res, { error: "slow down" }, 429, { "retry-after": "1" }));
  await assert.rejects(hermes().latest([A], soon(500)), /429 until the deadline/);
  assert.equal(seen.length, 1);

  let n = 0;
  reset((req, res) => {
    if (n++ === 0) return json(res, { error: "slow down" }, 429, { "retry-after": "1" });
    json(res, { binary: { data: ["00"] }, parsed: [entry(A, 1000)] });
  });
  const started = Date.now();
  await hermes().latest([A], soon(3000));
  assert.ok(Date.now() - started >= 1000, "honoured Retry-After");
});

test("an unreachable Hermes fails at the deadline", async () => {
  const dead = createHermes({ url: "http://127.0.0.1:1", apiKey: "k" });
  await assert.rejects(dead.latest([A], soon(500)), /unreachable/);
});

test("latest(): chunks of 50 ids, merged", async () => {
  const ids = Array.from({ length: 120 }, (_, i) => `0x${i.toString(16).padStart(64, "0")}`);
  reset((req, res, url) => {
    assert.equal(url.pathname, "/hermes/v2/updates/price/latest");
    json(res, { parsed: url.searchParams.getAll("ids[]").map((id) => entry(id, 7)) });
  });
  const prices = await hermes().latest(ids, soon());
  assert.equal(seen.length, 3);
  assert.equal(prices.size, 120);
  assert.equal(prices.get(ids[119].slice(2)).publishTime, 7);
});

test("RX-9, RX-30: latestSigned() returns the signed update, and asks Hermes to leave out ids it does not serve", async () => {
  reset((req, res, url) => {
    assert.equal(url.searchParams.get("ignore_invalid_price_ids"), "true");
    assert.equal(url.searchParams.get("encoding"), "hex");
    json(res, { parsed: [entry(A, 9)], binary: { data: ["abcd"] } });
  });
  const { prices, updates } = await hermes().latestSigned([A, `0x${"ee".repeat(32)}`], soon());
  assert.equal(prices.size, 1, "the unserved id is simply absent");
  assert.deepEqual(updates, ["0xabcd"]);
});

const feedOf = (id, price, publishTime, conf = 100000n) => ({ id, price: { price, conf, expo: -8, publishTime: BigInt(publishTime) }, emaPrice: { price, conf: 90000n, expo: -8, publishTime: BigInt(publishTime) } });

test("RY-6, RZ-1: trusted() keeps only the prices Pyth's contract confirms from the signed update", async () => {
  reset((req, res) => json(res, { parsed: [entry(A, 9), entry(B, 9, "999900000000")], binary: { data: ["abcd", "ef01"] } }));
  const calls = [];
  const chain = {
    read: async (address, abi, functionName, args, blockNumber) => {
      calls.push({ functionName, address, args, blockNumber });
      assert.equal(functionName, "getUpdateFee");
      assert.deepEqual(args, [["0xabcd", "0xef01"]]);
      return 7n;
    },
    call: async ({ to, functionName, args, value }, blockNumber) => {
      calls.push({ functionName, to, args, blockNumber, value });
      assert.equal(functionName, "parsePriceFeedUpdates");
      assert.equal(value, 7n, "the fee the read returned is sent");
      assert.deepEqual(args.slice(0, 2), [["0xabcd", "0xef01"], [A, B]]);
      // Pyth's view: A as Hermes said it, B at a different price than the JSON claimed. Shaped as viem decodes it: a
      // function's single output comes back unwrapped, so the parse answers the PriceFeed[] itself (RZ-1).
      return [feedOf(A, 250000000000n, 9), feedOf(B, 250000000000n, 9)];
    },
  };
  const prices = await hermes().trusted([A, B], soon(), { ...chain, pyth: "0x" + "12".repeat(20), abi: [], blockNumber: 42n });
  assert.deepEqual([...prices.keys()], [A.slice(2)], "the forged B is left out");
  assert.equal(prices.get(A.slice(2)).price, 250000000000n);
  assert.deepEqual(calls.map((c) => [c.functionName, c.blockNumber]), [["getUpdateFee", 42n], ["parsePriceFeedUpdates", 42n]]);
  assert.equal(calls[0].address, "0x" + "12".repeat(20));
  assert.equal(calls[1].to, "0x" + "12".repeat(20));
});

test("RY-6: trusted() values nothing when Hermes serves prices without a signed update", async () => {
  reset((req, res) => json(res, { parsed: [entry(A, 9)], binary: { data: [] } }));
  const chain = {
    read: async () => assert.fail("no chain call without an update"),
    call: async () => assert.fail("no chain call without an update"),
  };
  const prices = await hermes().trusted([A], soon(), { ...chain, pyth: "0x" + "12".repeat(20), abi: [] });
  assert.equal(prices.size, 0);
});
