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

test("at(): the update and its prices, with the key as a Bearer token", async () => {
  reset((req, res, url) => {
    assert.equal(url.pathname, "/hermes/v2/updates/price/1000");
    assert.deepEqual(url.searchParams.getAll("ids[]"), [A, B]);
    assert.equal(url.searchParams.get("encoding"), "hex");
    assert.equal(url.searchParams.get("parsed"), "true");
    json(res, { binary: { encoding: "hex", data: ["504e4155"] }, parsed: [entry(A, 1000), entry(B, 1011, "-5")] });
  });
  const { updates, prices } = await hermes().at([A, B], 1000, soon());
  assert.deepEqual(updates, ["0x504e4155"]);
  assert.equal(seen[0].auth, "Bearer k3y");
  assert.deepEqual(prices.get(A.slice(2)), {
    price: 250000000000n,
    conf: 100000n,
    expo: -8,
    publishTime: 1000,
    ema: { price: 250000000000n, conf: 90000n, expo: -8, publishTime: 1000 },
  });
  assert.equal(prices.get(B.slice(2)).price, -5n);
});

test("AU-2: at() carries each price's moving average, which the hub's preview checks the price against", async () => {
  reset((req, res) => json(res, { binary: { encoding: "hex", data: ["504e4155"] }, parsed: [entry(A, 1000, "250000000000", "200000000000")] }));
  const { prices } = await hermes().at([A], 1000, soon());
  assert.equal(prices.get(A.slice(2)).price, 250000000000n);
  assert.deepEqual(prices.get(A.slice(2)).ema, { price: 200000000000n, conf: 90000n, expo: -8, publishTime: 1000 });
});

test("at(): an update outside [t, t + 11] or missing a feed is refused", async () => {
  for (const [parsed, message] of [
    [[entry(A, 999)], "outside"],
    [[entry(A, 1012)], "outside"],
    [[], "left out"],
  ]) {
    reset((req, res) => json(res, { binary: { data: ["00"] }, parsed }));
    await assert.rejects(hermes().at([A], 1000, soon()), (e) => e instanceof HermesError && e.message.includes(message));
  }
  reset((req, res) => json(res, { binary: { data: [] }, parsed: [entry(A, 1000)] }));
  await assert.rejects(hermes().at([A], 1000, soon()), /no update data/);
});

test("at(): 404 and 5xx are retried until the update exists", async () => {
  let n = 0;
  reset((req, res) => {
    n++;
    if (n === 1) return json(res, { error: "no update yet" }, 404);
    if (n === 2) return json(res, { error: "busy" }, 503);
    json(res, { binary: { data: ["00"] }, parsed: [entry(A, 1000)] });
  });
  await hermes().at([A], 1000, soon());
  assert.equal(seen.length, 3);
});

test("at(): retries stop at the deadline", async () => {
  reset((req, res) => json(res, { error: "no update yet" }, 404));
  const started = Date.now();
  await assert.rejects(hermes().at([A], 1000, soon(600)), (e) => e instanceof HermesError && !e.permanent);
  assert.ok(Date.now() - started < 1500, "gave up near the deadline");
});

test("400 and 401 are permanent: no retry", async () => {
  for (const status of [400, 401]) {
    reset((req, res) => json(res, { error: "no" }, status));
    await assert.rejects(hermes().at([A], 1000, soon()), (e) => e.permanent === true && e.status === status);
    assert.equal(seen.length, 1);
  }
});

test("429 waits at least a second, and gives up when the deadline comes first", async () => {
  reset((req, res) => json(res, { error: "slow down" }, 429, { "retry-after": "1" }));
  await assert.rejects(hermes().at([A], 1000, soon(500)), /429 until the deadline/);
  assert.equal(seen.length, 1);

  let n = 0;
  reset((req, res) => {
    if (n++ === 0) return json(res, { error: "slow down" }, 429, { "retry-after": "1" });
    json(res, { binary: { data: ["00"] }, parsed: [entry(A, 1000)] });
  });
  const started = Date.now();
  await hermes().at([A], 1000, soon(3000));
  assert.ok(Date.now() - started >= 1000, "honoured Retry-After");
});

test("an unreachable Hermes fails at the deadline", async () => {
  const dead = createHermes({ url: "http://127.0.0.1:1", apiKey: "k" });
  await assert.rejects(dead.at([A], 1000, soon(500)), /unreachable/);
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
