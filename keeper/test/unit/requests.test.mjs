import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_REQUEST_CHECKS, applyScan, fillableRequests, requestUsd, stableLeg } from "../../bot/math.mjs";
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
