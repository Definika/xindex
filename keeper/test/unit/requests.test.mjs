import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_REQUEST_CHECKS, fillableRequests, stableLeg } from "../../bot/math.mjs";
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

test("fillable requests are open, not past their deadline, on a served index, largest escrow first, capped", () => {
  const entries = [
    { id: 1n, request: request({ escrow: 50n }) },
    { id: 2n, request: request({ escrow: 300n }) },
    { id: 3n, request: request({ open: false, escrow: 900n }) },
    { id: 4n, request: request({ deadline: 999n, escrow: 900n }) },
    { id: 5n, request: request({ index: OTHER, escrow: 900n }) },
    { id: 6n, request: request({ escrow: 200n, index: INDEX.toUpperCase().replace("0X", "0x") }) },
  ];
  const picked = fillableRequests(entries, 1_000n, [INDEX]);
  assert.deepEqual(picked.map((e) => e.id), [2n, 6n, 1n]);
  assert.deepEqual(fillableRequests(entries, 1_000n, [INDEX], 2).map((e) => e.id), [2n, 6n]);
  assert.deepEqual(fillableRequests(entries, 2_001n, [INDEX]), [], "a deadline before the fill's block");
  assert.equal(MAX_REQUEST_CHECKS, 8);
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
