import { test } from "node:test";
import assert from "node:assert/strict";
import { attestToken } from "../../restock/attest.mjs";

const hex = (n, bytes) => BigInt(n).toString(16).padStart(bytes * 2, "0");
const text32 = (s) => Buffer.from(s.padEnd(32, "\0")).toString("hex");
/// The guardians' signed attestation of a token of Wormhole chain `chain` at `address` (a word).
function attestation({ chain = 1, address = "5a".repeat(32), symbol = "RAY", name = "Raydium" } = {}) {
  const payload = `02${address}${hex(chain, 2)}${hex(6, 1)}${text32(symbol)}${text32(name)}`;
  const body = `${hex(1_700_000_000, 4)}${hex(0, 4)}${hex(chain, 2)}${"ec".repeat(32)}${hex(9, 8)}${hex(32, 1)}${payload}`;
  return `0x01${hex(4, 4)}${hex(1, 1)}${"ab".repeat(66)}${body}`;
}
const ZERO = `0x${"0".repeat(40)}`;

/// The flow around `existing` (the Token Bridge's copy before), with the guardians signing after `unsigned` polls.
function rig({ existing = ZERO, after = "0xC0pyC0pyC0pyC0pyC0pyC0pyC0pyC0pyC0pyC0py", unsigned = 1, vaa = attestation() } = {}) {
  const did = [];
  let polls = 0;
  let copy = existing;
  return {
    did,
    args: {
      home: { emitter: `0x${"ec".repeat(32)}`, attest: async (token) => (did.push(["attest", token]), { signature: "sig", sequence: "9" }) },
      wormholeChain: 1,
      token: "4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R",
      wormholescan: { vaa: async (chain, emitter, sequence) => (did.push(["vaa", chain, sequence]), polls++ < unsigned ? null : vaa) },
      verifyVaa: async () => ({ valid: true }),
      wrappedAsset: async (chain, address) => (did.push(["wrappedAsset", chain, address]), copy),
      submit: async (fn, v) => {
        did.push([fn, v === vaa]);
        copy = after;
      },
      log: () => {},
      wait: async () => {},
    },
  };
}

test("PD-7: a token is attested on its home chain through the signer's SDK, and its copy created on Ethereum from the signed attestation", async () => {
  const r = rig();
  const out = await attestToken(r.args);
  assert.deepEqual(out, { copy: "0xC0pyC0pyC0pyC0pyC0pyC0pyC0pyC0pyC0pyC0py", created: true, symbol: "RAY", name: "Raydium", decimals: 6 });
  assert.deepEqual(r.did, [
    ["attest", "4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R"],
    ["vaa", 1, "9"],
    ["vaa", 1, "9"],
    ["wrappedAsset", 1, `0x${"5a".repeat(32)}`],
    ["createWrapped", true],
    ["wrappedAsset", 1, `0x${"5a".repeat(32)}`],
  ]);
});

test("PD-7: a copy that exists has its name and symbol updated (RAY's updateWrapped)", async () => {
  const r = rig({ existing: "0xE1157E1157E1157E1157E1157E1157E1157E115" , after: "0xE1157E1157E1157E1157E1157E1157E1157E115" });
  const out = await attestToken(r.args);
  assert.equal(out.created, false);
  assert.ok(r.did.some((d) => d[0] === "updateWrapped"));
  assert.ok(!r.did.some((d) => d[0] === "createWrapped"));
});

test("PD-7: an attestation of another chain's token, or none signed in time, stops the flow before anything is submitted", async () => {
  const other = rig({ vaa: attestation({ chain: 21 }) });
  await assert.rejects(attestToken(other.args), /token of chain 21, not 1/);
  assert.ok(!other.did.some((d) => d[0] === "createWrapped" || d[0] === "updateWrapped"));
  const late = rig({ unsigned: 1_000 });
  await assert.rejects(attestToken({ ...late.args, pollMs: 1, timeoutMs: 5 }), /no signed attestation for sequence 9/);
});
