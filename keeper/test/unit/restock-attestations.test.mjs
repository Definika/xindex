import { test } from "node:test";
import assert from "node:assert/strict";
import { createIris, createWormholescan, sequenceIn } from "../../restock/attestations.mjs";

/// A fetch that answers each URL from `routes` (status and body) and records what was asked.
function fakeFetch(routes) {
  const asked = [];
  const impl = async (url) => {
    asked.push(url);
    const [status, body] = routes[url] ?? [404, { error: "not found" }];
    return { status, ok: status >= 200 && status < 300, json: async () => body };
  };
  return { impl, asked };
}

const BSC_BRIDGE = "0xB6F6D86a8f9879A9c87f643768d9efc38c1Da6E7";
const ID = `4/${"0".repeat(24)}b6f6d86a8f9879a9c87f643768d9efc38c1da6e7/17`;
const URL_17 = `https://api.wormholescan.io/api/v1/vaas/${ID}`;
const hex = (n, bytes) => BigInt(n).toString(16).padStart(bytes * 2, "0");
const word = (address) => address.toLowerCase().replace(/^0x/, "").padStart(64, "0");

/// A VAA as the guardians sign one: version, guardian set, `sigs` signatures of 66 bytes, then the body: time, nonce,
/// emitter chain, emitter, sequence, consistency and payload.
function vaa({ chain = 4, emitter = BSC_BRIDGE, sequence = 17, sigs = 2 } = {}) {
  const header = `01${hex(3, 4)}${hex(sigs, 1)}${"ab".repeat(66 * sigs)}`;
  const body = `${hex(1_700_000_000, 4)}${hex(0, 4)}${hex(chain, 2)}${word(emitter)}${hex(sequence, 8)}${hex(1, 1)}0301`;
  return `0x${header}${body}`;
}
const b64 = (h) => Buffer.from(h.slice(2), "hex").toString("base64");

test("a signed transfer comes back as hex, under the emitter's 32-byte form; until then, null", async () => {
  const f = fakeFetch({ [URL_17]: [200, { data: { vaa: b64(vaa()) } }] });
  const w = createWormholescan({ fetchImpl: f.impl });
  assert.equal(await w.vaa(4, BSC_BRIDGE, 17n), vaa());
  assert.equal(await w.vaa(4, BSC_BRIDGE, 18), null, "not signed yet");
});

test("Wormholescan failing, or answering without a VAA, throws rather than passing for not yet", async () => {
  const f = fakeFetch({
    [URL_17]: [503, {}],
    [URL_17.replace(/17$/, "19")]: [200, { data: {} }],
  });
  const w = createWormholescan({ fetchImpl: f.impl });
  await assert.rejects(w.vaa(4, BSC_BRIDGE, 17), /Wormholescan 503/);
  await assert.rejects(w.vaa(4, BSC_BRIDGE, 19), /gave no VAA/);
});

test("RS-14: a signed transfer of another emitter, chain or sequence is refused, never stored for the move", async () => {
  for (const other of [{ sequence: 18 }, { chain: 6 }, { emitter: `0x${"11".repeat(20)}` }]) {
    const w = createWormholescan({ fetchImpl: fakeFetch({ [URL_17]: [200, { data: { vaa: b64(vaa(other)) } }] }).impl });
    await assert.rejects(w.vaa(4, BSC_BRIDGE, 17), /another message/, JSON.stringify(other));
  }
  for (const cut of ["0x0100000007", vaa().slice(0, -6)]) {
    const short = createWormholescan({ fetchImpl: fakeFetch({ [URL_17]: [200, { data: { vaa: b64(cut) } }] }).impl });
    await assert.rejects(short.vaa(4, BSC_BRIDGE, 17), /not a VAA/, "too short for a header, or for a body");
  }
});

test("RS-14: a signed transfer that does not verify on the receiving chain is refused, to be fetched again", async () => {
  const w = createWormholescan({ fetchImpl: fakeFetch({ [URL_17]: [200, { data: { vaa: b64(vaa()) } }] }).impl });
  const asked = [];
  const verify = (valid) => async (v) => (asked.push(v), { valid, reason: valid ? "" : "invalid guardian set" });
  await assert.rejects(w.vaa(4, BSC_BRIDGE, 17, verify(false)), /does not verify.*invalid guardian set/);
  assert.equal(await w.vaa(4, BSC_BRIDGE, 17, verify(true)), vaa());
  assert.deepEqual(asked, [vaa(), vaa()], "the receiving chain's core is asked of the very VAA");
});

const TREASURY = `0x${"7e".repeat(20)}`;
const MESSENGER = "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d";
/// A CCTP V2 message as Iris returns one: the header (version, domains, nonce, sender, recipient, destination caller,
/// finality), then the burn message (version, token, mint recipient, amount, sender, fees, expiry, hook data).
function cctp({ source = 0, destination = 6, recipient = TREASURY, sender = TREASURY, amount = 1_944_299_998n } = {}) {
  const header = `${hex(1, 4)}${hex(source, 4)}${hex(destination, 4)}${"5a".repeat(32)}${word(MESSENGER)}${word(MESSENGER)}${"00".repeat(32)}${hex(2000, 4)}${hex(2000, 4)}`;
  const burn = `${hex(1, 4)}${word(`0x${"a0".repeat(20)}`)}${word(recipient)}${hex(amount, 32)}${word(sender)}${hex(0, 32)}${hex(0, 32)}${hex(0, 32)}`;
  return `0x${header}${burn}`;
}
const MOVE = { destinationDomain: 6, recipient: TREASURY, sender: TREASURY, amount: 1_944_299_998n };

test("Circle's attestation comes back once complete, and is null while pending or unknown", async () => {
  const base = "https://iris-api.circle.com/v2/messages/0?transactionHash=";
  const f = fakeFetch({
    [`${base}0xaa`]: [200, { messages: [{ status: "complete", message: cctp(), attestation: "0x02" }] }],
    [`${base}0xbb`]: [200, { messages: [{ status: "pending_confirmations", message: cctp(), attestation: "PENDING" }] }],
    [`${base}0xcc`]: [500, {}],
  });
  const iris = createIris({ fetchImpl: f.impl });
  assert.deepEqual(await iris.message(0, "0xaa", MOVE), { message: cctp(), attestation: "0x02" });
  assert.equal(await iris.message(0, "0xbb", MOVE), null);
  assert.equal(await iris.message(0, "0xdd", MOVE), null, "not indexed yet");
  await assert.rejects(iris.message(0, "0xcc", MOVE), /Iris 500/);
});

test("RS-14: Circle's attestation is taken only for a message of this move", async () => {
  const base = "https://iris-api.circle.com/v2/messages/0?transactionHash=";
  for (const other of [{ amount: 1n }, { recipient: `0x${"11".repeat(20)}` }, { sender: `0x${"11".repeat(20)}` }, { destination: 2 }, { source: 6 }]) {
    const iris = createIris({ fetchImpl: fakeFetch({ [`${base}0xaa`]: [200, { messages: [{ status: "complete", message: cctp(other), attestation: "0x02" }] }] }).impl });
    await assert.rejects(iris.message(0, "0xaa", MOVE), /no message of this move/, JSON.stringify(other, (k, v) => (typeof v === "bigint" ? `${v}` : v)));
  }
  const two = createIris({
    fetchImpl: fakeFetch({
      [`${base}0xaa`]: [200, { messages: [{ status: "complete", message: cctp({ amount: 5n }), attestation: "0x01" }, { status: "complete", message: cctp(), attestation: "0x02" }] }],
    }).impl,
  });
  assert.deepEqual(await two.message(0, "0xaa", MOVE), { message: cctp(), attestation: "0x02" }, "the move's among others");
});

test("RS-14: an attestation that would not be received on the other chain is refused, to be fetched again", async () => {
  const base = "https://iris-api.circle.com/v2/messages/0?transactionHash=";
  const iris = createIris({ fetchImpl: fakeFetch({ [`${base}0xaa`]: [200, { messages: [{ status: "complete", message: cctp(), attestation: "0x02" }] }] }).impl });
  const asked = [];
  const verify = (valid) => async (m, a) => (asked.push([m, a]), { valid, reason: valid ? "" : "Invalid signature" });
  await assert.rejects(iris.message(0, "0xaa", MOVE, verify(false)), /does not verify.*Invalid signature/);
  assert.deepEqual(await iris.message(0, "0xaa", MOVE, verify(true)), { message: cctp(), attestation: "0x02" });
  assert.deepEqual(asked, [[cctp(), "0x02"], [cctp(), "0x02"]]);
});

test("RS-14: the sequence is read only from the Wormhole core's own log", () => {
  const CORE = "0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B";
  const decode = (log) => log.decoded;
  const event = (address, sequence) => ({ address, decoded: { eventName: "LogMessagePublished", args: { sender: BSC_BRIDGE, sequence } } });
  const forged = event(`0x${"66".repeat(20)}`, 99n); // a token in the transfer, emitting the core's event as its own
  assert.equal(sequenceIn([forged, event(CORE.toLowerCase(), 17n)], { core: CORE, emitter: BSC_BRIDGE, decode }), 17n);
  assert.equal(sequenceIn([forged], { core: CORE, emitter: BSC_BRIDGE, decode }), null);
});
