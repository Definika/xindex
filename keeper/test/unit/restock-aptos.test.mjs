import { test } from "node:test";
import assert from "node:assert/strict";
import { aptosFate, checkPanoraArgs, normAddress, PANORA_NO_FEE } from "../../restock/aptos/checks.mjs";

const base = { sequence: "7", expire: "1000", sentVersion: "500" };
/// The account as one answer gave it: its sequence number, and that answer's ledger version and time.
const account = (sequence, ledgerVersion = 900, ledgerSeconds = 900) => ({ sequence: String(sequence), ledgerVersion: String(ledgerVersion), ledgerTimestamp: String(BigInt(ledgerSeconds) * 1_000_000n) });
/// The hash lookup as one answer gave it, with that node's ledger version and oldest version kept.
const byHash = (found, ledgerVersion = 950, oldestVersion = 100) => ({ found, ledgerVersion: String(ledgerVersion), oldestVersion: String(oldestVersion) });

test("PD-4: a passed sequence number expires a move only from a hash lookup at or past the account read's version, on a node that keeps the history", () => {
  assert.deepEqual(aptosFate({ ...base, account: account(7), byHash: byHash({ pending: true }) }), { state: "pending" });
  assert.deepEqual(aptosFate({ ...base, account: account(8), byHash: byHash({ success: true, version: 42 }) }), { state: "landed", at: "42" });
  assert.deepEqual(aptosFate({ ...base, account: account(8), byHash: byHash({ success: false, version: 42 }) }), { state: "reverted", at: "42" });
  // The sequence number was used, and a node at or past the account's version, keeping the versions since the build,
  // has no such hash: another transaction took the number.
  assert.match(aptosFate({ ...base, account: account(8, 900), byHash: byHash(null, 900) }).reason, /sequence number 7 went to another transaction/);
  // The hash lookup reached a node a moment behind the account read: ours may be what took the number. Wait.
  assert.deepEqual(aptosFate({ ...base, account: account(8, 900), byHash: byHash(null, 899) }), { state: "pending" });
  // A node that pruned the versions since the build, or an expiry naming no build version, proves nothing.
  assert.match(aptosFate({ ...base, account: account(8), byHash: byHash(null, 950, 501) }).reason, /keeps versions from 501 only, not from 500/);
  assert.equal(aptosFate({ ...base, sentVersion: null, account: account(8), byHash: byHash(null) }).state, "unknown");
  // The sequence number unused: expired only once the same answer's ledger clock passed the expiry.
  assert.deepEqual(aptosFate({ ...base, account: account(7, 900, 999), byHash: byHash(null) }), { state: "pending" });
  assert.match(aptosFate({ ...base, account: account(7, 900, 1000), byHash: byHash(null) }).reason, /expired at 1000/);
});

/// A Panora answer's `router_entry` arguments for 10 USDC to APT, as read on 2026-11-02: five splits.
const PANORA_ARGS = [
  null,
  "0x9b5e4d0bd7b0d8a5c1f6e63b7e2b3e0c4a1d2f3e5b6c7d8e9f0a1b2c3d4e5f60",
  ...Array(13).fill([]),
  "0xa",
  ["400000", "1316200", "800000", "7283799", "200001"],
  "1580978528",
  10000000000000000,
  "0x90c588d22ee7dd42d55d73e63b50f0f9dfe7113952374040ae8c4adfd137176d",
];
const ASK = { address: "0x9b5e4d0bd7b0d8a5c1f6e63b7e2b3e0c4a1d2f3e5b6c7d8e9f0a1b2c3d4e5f60", to: `0x${"0".repeat(63)}a`, amountIn: 10_000_000n };

test("PD-13: Panora's swap spends exactly the amount across its splits and pays no integrator fee", () => {
  checkPanoraArgs(PANORA_ARGS, ASK);
  const with_ = (i, v) => PANORA_ARGS.map((x, k) => (k === i ? v : x));
  assert.throws(() => checkPanoraArgs(with_(16, ["400000", "1316200", "800000", "7283799", "200000"]), ASK), /spends 9999999, not 10000000/);
  assert.throws(() => checkPanoraArgs(with_(16, []), ASK), /names no amount/);
  assert.throws(() => checkPanoraArgs(with_(1, `0x${"ee".repeat(32)}`), ASK), /pays someone else/);
  assert.throws(() => checkPanoraArgs(with_(15, "0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b"), ASK), /buys another token/);
  // Asking for a 0.1% fee to an address set these two to about 1.1e16 and that address (read on 2026-11-02).
  assert.throws(() => checkPanoraArgs(with_(18, 11000000000001000), ASK), /integrator fee/);
  assert.throws(() => checkPanoraArgs(with_(19, ASK.address), ASK), /integrator fee/);
  assert.throws(() => checkPanoraArgs(PANORA_ARGS.slice(0, 19), ASK), /19 arguments/);
  assert.equal(normAddress("0xA"), `0x${"0".repeat(63)}a`);
  assert.equal(PANORA_NO_FEE.amount, String(PANORA_ARGS[18]));
});
