import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_REQUEST_CHECKS, MAX_SCAN_READS, applyScan, fillableRequests, requestUsd, scanIds, stableLeg } from "../../bot/math.mjs";
import { parseConfig } from "../../bot/config.mjs";

const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
const INDEX = `0x${"aa".repeat(20)}`;
const OTHER = `0x${"bb".repeat(20)}`;
const request = (over) => ({
  requester: `0x${"cc".repeat(20)}`,
  deadline: 2_000n,
  isMint: true,
  open: true,
  index: INDEX,
  stable: USDC,
  escrow: 100n * 10n ** 6n,
  limit: 10n ** 18n,
  ...over,
});

/// One share of INDEX worth `shareUsd`, its gate open to the executor unless `mintAllowed` says otherwise.
const infoOf = (shareUsd = 50, mintAllowed = true, index = INDEX) => new Map([[index.toLowerCase(), { shareUsd, mintAllowed }]]);
const ids = (picked) => picked.chosen.map((e) => e.id);

test("fillable requests are open, not past their deadline, on a served index, largest first, capped", () => {
  const usd = (x) => BigInt(x) * 10n ** 6n;
  const entries = [
    { id: 1n, request: request({ escrow: usd(50) }) },
    { id: 2n, request: request({ escrow: usd(300) }) },
    { id: 3n, request: request({ open: false, escrow: usd(900) }) },
    { id: 4n, request: request({ deadline: 999n, escrow: usd(900) }) },
    { id: 5n, request: request({ index: OTHER, escrow: usd(900) }) },
    { id: 6n, request: request({ escrow: usd(200), index: INDEX.toUpperCase().replace("0X", "0x") }) },
  ];
  const picked = fillableRequests(entries, 1_000n, [INDEX], infoOf());
  assert.deepEqual(ids(picked), [2n, 6n, 1n]);
  assert.deepEqual(picked.skipped, []);
  assert.deepEqual(ids(fillableRequests(entries, 1_000n, [INDEX], infoOf(), 2)), [2n, 6n]);
  assert.deepEqual(ids(fillableRequests(entries, 2_001n, [INDEX], infoOf())), [], "a deadline before the fill's block");
  assert.equal(MAX_REQUEST_CHECKS, 8);
});

test("XS-7: requests are ranked by dollars, not raw escrow, each side keeping its share of the checks", () => {
  // The audit's griefing: eight redemptions of 0.001 share ($0.10) asking 2^200 of USDC, against a $10M mint.
  const griefers = Array.from({ length: 8 }, (_, k) => ({
    id: BigInt(k + 1),
    request: request({ isMint: false, escrow: 10n ** 15n, limit: 2n ** 200n }),
  }));
  const mint = { id: 100n, request: request({ escrow: 10n ** 13n, limit: 99_000n * 10n ** 18n }) };
  const picked = fillableRequests([...griefers, mint], 1_000n, [INDEX], infoOf(100));
  assert.deepEqual(ids(picked), [100n], "the $10M mint is simulated, and no griefer");
  assert.equal(picked.skipped.length, 8);
  assert.ok(picked.skipped.every((s) => /limit/.test(s.reason)), "each griefer's limit is above its escrow's worth");
  assert.deepEqual(requestUsd(mint.request, 100), { escrowUsd: 10_000_000, limitUsd: 9_900_000 });

  // A share of the dearer index outranks ten of the cheaper one, though its raw escrow is smaller.
  const cheap = { id: 1n, request: request({ isMint: false, index: OTHER, escrow: 10n * 10n ** 18n, limit: 1n }) };
  const dear = { id: 2n, request: request({ isMint: false, escrow: 10n ** 18n, limit: 1n }) };
  const two = new Map([...infoOf(1_000), [OTHER.toLowerCase(), { shareUsd: 1, mintAllowed: true }]]);
  assert.deepEqual(ids(fillableRequests([cheap, dear], 1_000n, [INDEX, OTHER], two, 1)), [2n]);

  // Eight genuine redemptions worth more than the mint still leave the mint a slot.
  const big = Array.from({ length: 8 }, (_, k) => ({
    id: BigInt(k + 1),
    request: request({ isMint: false, escrow: 200_000n * 10n ** 18n, limit: 10n ** 6n }),
  }));
  const mixed = fillableRequests([...big, mint], 1_000n, [INDEX], infoOf(100));
  assert.ok(ids(mixed).includes(100n), "a mint keeps a slot");
  assert.equal(mixed.chosen.length, 8);
  assert.deepEqual(ids(fillableRequests(big, 1_000n, [INDEX], infoOf(100))).length, 8, "a side alone takes every slot");
});

test("XS-7: a mint on a gated index, or on an index not yet valued, is skipped before any simulation", () => {
  const mint = { id: 7n, request: request() };
  const redeem = { id: 8n, request: request({ isMint: false, escrow: 10n ** 18n, limit: 10n ** 6n }) };
  const gated = fillableRequests([mint, redeem], 1_000n, [INDEX], infoOf(50, false));
  assert.deepEqual(ids(gated), [8n], "a redemption reads no gate");
  assert.deepEqual(gated.skipped, [{ id: 7n, reason: "its index is gated and does not issue to the executor" }]);
  assert.deepEqual(ids(fillableRequests([mint], 1_000n, [INDEX], infoOf(50, null))), [], "a gate not read");
  assert.deepEqual(ids(fillableRequests([mint, redeem], 1_000n, [INDEX], infoOf(null))), [], "no Pyth value");
  assert.deepEqual(ids(fillableRequests([mint, redeem], 1_000n, [INDEX], new Map())), []);
});

test("XS-11: a failed read keeps what was known and holds the scan before it", () => {
  const open = (over) => ({ ok: { status: "success", result: request(over) } }).ok;
  const failure = { status: "failure", error: new Error("rate limited") };
  const known = new Map([[1n, request()]]);
  // Requests 1 (known), 4, 5 and 6 (new since id 3) are read; the reads of 1 and 5 fail.
  const first = applyScan({ known, scanned: 3n, count: 6n, ids: [1n, 4n, 5n, 6n], results: [failure, open(), failure, open()], T: 1_000n });
  assert.deepEqual(first, { scanned: 4n, failed: [1n, 5n], closed: [] });
  assert.ok(known.has(1n), "a known request whose read failed stays known");
  assert.deepEqual([...known.keys()], [1n, 4n, 6n]);

  // The next scan reads 5 again; request 1 was filled meanwhile.
  const second = applyScan({
    known,
    scanned: first.scanned,
    count: 6n,
    ids: [1n, 4n, 6n, 5n],
    results: [open({ open: false }), open(), open(), open()],
    T: 1_000n,
  });
  assert.deepEqual(second, { scanned: 6n, failed: [], closed: [1n] });
  assert.deepEqual([...known.keys()].sort(), [4n, 5n, 6n]);

  // An expired request is dropped like a closed one.
  const third = applyScan({ known, scanned: 6n, count: 6n, ids: [4n], results: [open({ deadline: 999n })], T: 1_000n });
  assert.deepEqual(third.closed, [4n]);
});

test("RZ-10: a scan reads at most MAX_SCAN_READS requests, and every known one again within a few scans", () => {
  const range = (from, to) => Array.from({ length: Number(to - from) + 1 }, (_, k) => from + BigInt(k));
  // Few requests: everything is read, the forgotten one first, then the new ids, then the known ones.
  const few = new Map([[1n, request()], [2n, request()]]);
  assert.deepEqual(scanIds({ known: few, recheck: new Set([7n]), scanned: 4n, count: 6n }).ids, [7n, 5n, 6n, 1n, 2n]);
  assert.deepEqual(scanIds({ known: few, recheck: new Set([2n]), scanned: 2n, count: 2n }).ids, [1n, 2n], "a recheck still known is read as known");

  // A stranger's 5,000 new requests: the scan stops at the budget, the known ones keeping their share of it, and the
  // frontier moves over what it read, in order.
  const known = new Map(range(1n, 10n).map((id) => [id, request()]));
  const flood = scanIds({ known, scanned: 10n, count: 5_010n });
  assert.equal(flood.ids.length, MAX_SCAN_READS, "never past the budget");
  assert.deepEqual(flood.ids.slice(0, 990), range(11n, 1_000n), "the new ids from the frontier, in order");
  assert.deepEqual(flood.ids.slice(990), range(1n, 10n), "and every known one");
  // With more known requests than half the budget, the new ones get the other half.
  const crowd = new Map(range(1n, 2_000n).map((id) => [id, request()]));
  const half = scanIds({ known: crowd, scanned: 2_000n, count: 9_000n });
  assert.deepEqual(half.ids.slice(0, 500), range(2_001n, 2_500n));
  assert.equal(half.ids.length, MAX_SCAN_READS);

  // 5,000 of them open and known, with ten new: the new ten, then the known ones round their list, scan after scan.
  const many = new Map(range(1n, 5_000n).map((id) => [id, request()]));
  let cursor = 0;
  const reread = new Set();
  for (let scan = 0; scan < 6; scan++) {
    const s = scanIds({ known: many, scanned: 5_000n + BigInt(10 * scan), count: 5_010n + BigInt(10 * scan), cursor });
    assert.ok(s.ids.length <= MAX_SCAN_READS, "never past the budget");
    assert.deepEqual(s.ids.slice(0, 10), range(5_001n + BigInt(10 * scan), 5_010n + BigInt(10 * scan)), "the new requests first");
    for (const id of s.ids.slice(10)) reread.add(id);
    cursor = s.cursor;
  }
  assert.equal(reread.size, 5_000, "every known request read again within six scans");
});

test("a stablecoin other than USDC is sold for a mint and bought for a redeem", () => {
  assert.equal(stableLeg(request(), USDC), null);
  assert.equal(stableLeg(request({ stable: USDC.toLowerCase() }), USDC), null);
  assert.deepEqual(stableLeg(request({ stable: USDT, escrow: 7n }), USDC), { token: USDT, side: "sell", amount: 7n });
  assert.deepEqual(stableLeg(request({ stable: USDT, isMint: false, limit: 9n }), USDC), {
    token: USDT,
    side: "buy",
    amount: 9n,
  });
});

test("FILL_REQUESTS is on by default and must be 0 or 1", () => {
  const VALID = {
    RPC_URL: "https://rpc.example",
    KEEPER_KEY: `0x${"ab".repeat(32)}`,
    FACTORY: `0x${"11".repeat(20)}`,
    EXECUTOR: `0x${"22".repeat(20)}`,
    PYTH_API_KEY: "secret",
  };
  assert.equal(parseConfig(VALID).fillRequests, true);
  assert.equal(parseConfig({ ...VALID, FILL_REQUESTS: "0" }).fillRequests, false);
  assert.throws(() => parseConfig({ ...VALID, FILL_REQUESTS: "yes" }), /FILL_REQUESTS must be 0 or 1/);
});

test("RY-8: a request whose escrow over its limit cannot pay MIN_PROFIT_USD is not simulated, so it asks no stock", () => {
  // One share worth $50: a mint escrowing $100 for 1.98 shares leaves $1 over its limit, one for 1.9 shares $5.
  const thin = { id: 1n, request: request({ escrow: 100n * 10n ** 6n, limit: 198n * 10n ** 16n }) };
  const fat = { id: 2n, request: request({ escrow: 100n * 10n ** 6n, limit: 190n * 10n ** 16n }) };
  // A redemption of 2 shares ($100) asking $99.50, and one asking $90.
  const thinRedeem = { id: 3n, request: request({ isMint: false, escrow: 2n * 10n ** 18n, limit: 99_500_000n }) };
  const fatRedeem = { id: 4n, request: request({ isMint: false, escrow: 2n * 10n ** 18n, limit: 90n * 10n ** 6n }) };
  const entries = [thin, fat, thinRedeem, fatRedeem];
  const picked = fillableRequests(entries, 1_000n, [INDEX], infoOf(50), MAX_REQUEST_CHECKS, 2);
  assert.deepEqual(new Set(ids(picked)), new Set([2n, 4n]));
  assert.deepEqual(
    picked.skipped.map((s) => s.id),
    [1n, 3n],
  );
  assert.ok(picked.skipped.every((s) => /cannot pay MIN_PROFIT_USD/.test(s.reason)));
  assert.equal(fillableRequests(entries, 1_000n, [INDEX], infoOf(50)).chosen.length, 4, "with no minimum all four pay something");
});

test("a request made before its index's last settlement is not simulated, alone or in a batch", async () => {
  const { batchGroups, movingReadFailed, settledSince } = await import("../../bot/math.mjs");
  const at = (nonce) => new Map([[INDEX.toLowerCase(), { shareUsd: 50, mintAllowed: true, nonce }]]);
  const made = (id, rebalanceNonce) => ({ id, request: { requester: `0x${"cc".repeat(20)}`, deadline: 2_000n, isMint: true, open: true, rebalanceNonce, index: INDEX, stable: USDC, escrow: 60_000_000n, limit: 10n ** 18n } });
  const entries = [made(1n, 6), made(2n, 7), made(3n, 7)];

  const alone = fillableRequests(entries, 1_000n, [INDEX], at(7n));
  assert.deepEqual(alone.chosen.map((e) => e.id).sort(), [2n, 3n]);
  assert.deepEqual(alone.skipped, [{ id: 1n, reason: "its index settled a rebalance since it was made: it can only be cancelled or refunded" }]);
  assert.deepEqual(batchGroups(entries, 1_000n, [INDEX], at(7n))[0].members.map((m) => m.id).sort(), [2n, 3n]);

  // A nonce that could not be read, or was never asked for, says nothing: the request is checked as before.
  assert.equal(fillableRequests(entries, 1_000n, [INDEX], at(null)).chosen.length, 3);
  assert.equal(batchGroups(entries, 1_000n, [INDEX], at(undefined))[0].members.length, 3);
  assert.equal(settledSince({ rebalanceNonce: 7 }, { nonce: 7n }), false);
  assert.equal(settledSince({ rebalanceNonce: 7n }, { nonce: 8n }), true);

  // CA-R2-03: only a failed read of a leg the fill moves stops it.
  const ok = { status: "success", result: 1n };
  const bad = { status: "failure" };
  assert.equal(movingReadFailed([0, 2], [ok, bad, ok], [ok, bad, ok]), false, "the leg left alone answers nothing, and nothing reads it");
  assert.equal(movingReadFailed([0, 2], [ok, ok, ok], [ok, ok, bad]), true, "a moving leg's allowance");
  assert.equal(movingReadFailed([1], [ok, bad, ok], [ok, ok, ok]), true, "a moving leg's balance");
  assert.equal(movingReadFailed([], [bad], [bad]), false);
});
