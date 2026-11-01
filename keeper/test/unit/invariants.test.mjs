import { test } from "node:test";
import assert from "node:assert/strict";
import {
  checkEscrows,
  checkIndex,
  checkProgress,
  componentWord,
  diffFindings,
  popcount,
  requestEscrow,
  required,
  scaleWord,
} from "../../invariants/check.mjs";
import { parseInvariantsConfig } from "../../invariants/config.mjs";

const WAD = 10n ** 18n;
const A = `0x${"aa".repeat(20)}`;
const B = `0x${"bb".repeat(20)}`;
const C = `0x${"cc".repeat(20)}`;
const INDEX = `0x${"11".repeat(20)}`;

const word = (token, units) => (units << 160n) | BigInt(token);
const word3 = (scale, lastAccrual, maskedFill = false) => scale | (lastAccrual << 128n) | ((maskedFill ? 1n : 0n) << 168n);

/// A healthy two-leg index at the recorded scale 0.9, 1,000 shares, a claim on A, and one raw unit of surplus on B.
function healthy(overrides = {}) {
  const scale = 9n * 10n ** 17n;
  const supply = 1_000n * WAD;
  const units = [3n * 10n ** 18n + 7n, 5n * 10n ** 8n];
  const claims = [11n, 0n];
  return {
    index: INDEX,
    now: 10_000n,
    rebalanceDelay: 7_200n,
    tokens: [A.toUpperCase().replace("0X", "0x"), B],
    viewUnits: units.map((u) => (u * scale) / WAD),
    pendingScale: scale,
    lastAccrual: 9_000n,
    length: 2n,
    words: units.map((u, i) => word([A, B][i], u)),
    word3: word3(scale, 9_000n),
    supply,
    claims,
    balances: units.map((u, i) => required(supply, u, scale) + claims[i] + BigInt(i)),
    eta: 0n,
    keepMask: 0n,
    earliest: 9_500n,
    restartAllowedAt: 0n,
    proposalCount: 3n,
    rebalanceNonce: 2n,
    lastRebalance: 1_000n,
    ...overrides,
  };
}
const codes = (findings) => findings.map((f) => `${f.level}:${f.code}`);

test("the words decode as WeightedHub packs them", () => {
  assert.deepEqual(componentWord(word(A, 12345n)), { token: A, units: 12345n });
  assert.deepEqual(componentWord(word(A, (1n << 96n) - 1n)).units, (1n << 96n) - 1n, "units fill the 12 high bytes");
  assert.deepEqual(scaleWord(word3(WAD, 77n, true)), { scale: WAD, lastAccrual: 77n, maskedFill: true });
  assert.equal(popcount(0b1011n), 3n);
});

test("a healthy index has no finding, exactly at the backing too", () => {
  assert.deepEqual(checkIndex(healthy()), []);
  const s = healthy();
  assert.equal(s.balances[0], required(s.supply, componentWord(s.words[0]).units, 9n * 10n ** 17n) + 11n, "A sits at the line");
});

test("a balance one raw unit below the backing plus claims is a breach, measured at the recorded scale", () => {
  const s = healthy();
  s.balances[0] -= 1n;
  const [f] = checkIndex(s);
  assert.equal(f.code, "backing");
  assert.equal(f.token, A, "lowercased");
  assert.equal(f.shortfall, 1n);
  // The same index read at a pending scale below the recorded one stays in breach: the check never uses components().
  const pending = (9n * 10n ** 17n * 99n) / 100n;
  const later = healthy({ pendingScale: pending, viewUnits: healthy().words.map((w) => (componentWord(w).units * pending) / WAD) });
  later.balances[0] -= 1n;
  assert.deepEqual(codes(checkIndex(later)), ["breach:backing"]);
});

test("claims count: a balance that covers the backing but not the claims is a breach", () => {
  const s = healthy();
  s.balances[0] -= 11n;
  assert.deepEqual(codes(checkIndex(s)), ["breach:backing"]);
});

test("a component whose balanceOf reverts is a notice, and the others are still checked", () => {
  const s = healthy();
  s.balances[0] = null;
  s.balances[1] -= 2n;
  assert.deepEqual(codes(checkIndex(s)), ["notice:unreadable", "breach:backing"]);
});

test("storage that does not reproduce the views is a reader finding, and nothing else is evaluated", () => {
  const cases = {
    length: healthy({ length: 3n }),
    token: healthy({ words: [word(C, 1n), healthy().words[1]] }),
    units: healthy({ viewUnits: [healthy().viewUnits[0] + 1n, healthy().viewUnits[1]] }),
    lastAccrual: healthy({ lastAccrual: 9_001n }),
    scale: healthy({ pendingScale: 9n * 10n ** 17n + 1n }),
    zero: healthy({ word3: word3(0n, 9_000n) }),
  };
  for (const [name, s] of Object.entries(cases)) {
    s.balances = [0n, 0n];
    assert.deepEqual(codes(checkIndex(s)), ["reader:layout"], name);
  }
});

test("the keep mask and the clock: I1 to I4", () => {
  const live = { eta: 9_500n + 7_200n, keepMask: 0n };
  assert.deepEqual(checkIndex(healthy(live)), [], "a proposal started at the interval's end");
  assert.deepEqual(codes(checkIndex(healthy({ keepMask: 1n }))), ["breach:keep-mask"], "a mask with no proposal");
  assert.deepEqual(codes(checkIndex(healthy({ ...live, keepMask: 0b100n }))), ["breach:keep-mask"], "past the components");
  assert.deepEqual(codes(checkIndex(healthy({ ...live, keepMask: 0b01n }))), ["breach:keep-mask"], "one left moving");
  assert.deepEqual(codes(checkIndex(healthy({ ...live, eta: live.eta - 1n }))), ["breach:clock"], "I1");
  assert.deepEqual(codes(checkIndex(healthy({ ...live, restartAllowedAt: live.eta + 1n }))), ["breach:clock"], "I2");
  assert.deepEqual(codes(checkIndex(healthy({ restartAllowedAt: 10_001n, earliest: 10_001n }))), ["breach:clock"], "I3");
  assert.deepEqual(checkIndex(healthy({ restartAllowedAt: 10_001n })), [], "a cooldown alone");
  assert.deepEqual(codes(checkIndex(healthy({ rebalanceNonce: 4n }))), ["breach:counters"], "I4");
});

test("a recorded scale above 1e18 is a breach", () => {
  const scale = WAD + 1n;
  const s = healthy({ word3: word3(scale, 9_000n), pendingScale: scale, viewUnits: healthy().words.map((w) => (componentWord(w).units * scale) / WAD) });
  s.balances = s.words.map((w, i) => required(s.supply, componentWord(w).units, scale) + s.claims[i]);
  assert.deepEqual(codes(checkIndex(s)), ["breach:scale"]);
});

test("from round to round: the units move only with the nonce, the scale only falls, the counters never go back", () => {
  const prev = { tokens: [A, B], units: [5n, 6n], scale: WAD, proposalCount: 2n, rebalanceNonce: 1n, lastRebalance: 100n };
  assert.deepEqual(checkProgress(INDEX, prev, { ...prev, scale: WAD - 1n }), [], "an accrual");
  assert.deepEqual(checkProgress(INDEX, prev, { ...prev, units: [4n, 7n], rebalanceNonce: 2n, lastRebalance: 200n }), [], "a fill");
  assert.deepEqual(codes(checkProgress(INDEX, prev, { ...prev, units: [4n, 7n] })), ["breach:units"]);
  assert.deepEqual(codes(checkProgress(INDEX, prev, { ...prev, tokens: [B, A] })), ["breach:components"]);
  assert.deepEqual(codes(checkProgress(INDEX, prev, { ...prev, scale: WAD + 1n })), ["breach:scale"]);
  assert.deepEqual(codes(checkProgress(INDEX, prev, { ...prev, proposalCount: 1n, lastRebalance: 99n })), ["breach:counters", "breach:counters"]);
});

test("escrows are summed per token and must be covered by the holder's balance", () => {
  const escrows = [
    { token: A, amount: 5n },
    { token: A.toUpperCase().replace("0X", "0x"), amount: 7n },
    { token: B, amount: 1n },
  ];
  assert.deepEqual(checkEscrows("x", INDEX, escrows, new Map([[A, 12n], [B, 1n]])), []);
  const [f] = checkEscrows("x", INDEX, escrows, new Map([[A, 11n], [B, 9n]]));
  assert.equal(f.token, A);
  assert.equal(f.owed, 12n);
  assert.equal(f.shortfall, 1n);
  assert.deepEqual(codes(checkEscrows("x", INDEX, [{ token: C, amount: 1n }], new Map())), ["breach:x"], "no balance read");
});

test("a mint request escrows its stablecoin, a redeem request the index's shares, and a closed one nothing", () => {
  const r = { isMint: true, open: true, stable: A, index: B, escrow: 9n };
  assert.deepEqual(requestEscrow(r), { token: A, amount: 9n });
  assert.deepEqual(requestEscrow({ ...r, isMint: false }), { token: B, amount: 9n });
  assert.equal(requestEscrow({ ...r, open: false }).amount, 0n);
});

test("a standing finding is raised once and cleared once", () => {
  const breach = { level: "breach", code: "backing", index: INDEX, token: A, shortfall: 1n };
  let d = diffFindings(new Set(), [breach]);
  assert.equal(d.raised.length, 1);
  d = diffFindings(d.standing, [{ ...breach, shortfall: 2n }]);
  assert.equal(d.raised.length, 0, "the same breach, deeper: not raised again");
  d = diffFindings(d.standing, []);
  assert.deepEqual(d.cleared.length, 1);
  assert.equal(d.standing.size, 0);
});

test("the checker's configuration", () => {
  const base = { RPC_URL: "https://rpc.example", FACTORY: A };
  const cfg = parseInvariantsConfig(base);
  assert.equal(cfg.chain.chainId, 1);
  assert.equal(cfg.pollSeconds, 60);
  assert.equal(cfg.builder, null);
  assert.equal(cfg.fromBlock, null);
  assert.throws(() => parseInvariantsConfig({ ...base, BUILDER: B }), /BUILDER needs FROM_BLOCK/);
  assert.equal(parseInvariantsConfig({ ...base, BUILDER: B, FROM_BLOCK: "123" }).fromBlock, 123n);
  assert.throws(() => parseInvariantsConfig({ FACTORY: "nope", CHAIN_ID: "5" }), (e) =>
    ["RPC_URL is required", "FACTORY must be an address", "CHAIN_ID must be one of"].every((p) => e.message.includes(p)),
  );
  assert.throws(() => parseInvariantsConfig({ ...base, ALERT_WEBHOOK: "ftp://x" }), /ALERT_WEBHOOK must be an http\(s\) URL/);
});
