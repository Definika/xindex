import { test } from "node:test";
import assert from "node:assert/strict";
import { CHAINS, SHARE_PRICED_IDS, SVALUE_SETTLE_SECONDS } from "../../bot/config.mjs";
import * as M from "../../bot/math.mjs";
import { createSValues, sharePricedLegs } from "../../bot/svalues.mjs";

const ORACLE = `0x${"0d".repeat(20)}`;
const [A, B, C] = ["a1", "b2", "c3"].map((x) => `0x${x.repeat(20)}`);
const SHARE = SHARE_PRICED_IDS[0]; // a share's feed: an Ondo leg priced at it is worth sValue shares
const OWN = `0x${"11".repeat(32)}`; // a token's own feed
const WAD = 10n ** 18n;
const NOW = 1_000_000n;
const L = { number: 500n, timestamp: NOW };
const SETTLED = NOW - SVALUE_SETTLE_SECONDS;
const price = (p, conf = 10n) => ({ price: p, conf, expo: -8, publishTime: NOW });

/// `assetData` as Ondo's oracle answers it: (sValue, pendingSValue, lastUpdate, pauseStartTime, drift, cooldown).
const asset = ({ sValue = WAD, lastUpdate = SETTLED, pauseStartTime = 0n, pending = 0n } = {}) => ({
  status: "success",
  result: [sValue, pending, lastUpdate, pauseStartTime, 100, 86_400],
});

/// A chain that answers each `assetData` from `world` by token, and records every multicall it was asked.
function fakeChain(world) {
  const asked = [];
  const chain = {
    multicall: async (contracts, blockNumber) => {
      asked.push({ contracts, blockNumber });
      if (world.throws) throw new Error("node down");
      return contracts.map((c) => world[c.args[0].toLowerCase()] ?? { status: "failure" });
    },
  };
  return { chain, asked };
}

test("an sValue is usable only when held, with no corporate action scheduled, and settled", () => {
  const ok = { sValue: WAD, lastUpdate: SETTLED, pauseStartTime: 0n };
  assert.equal(M.sValueUsable(ok, NOW, SVALUE_SETTLE_SECONDS), true, "settled exactly SVALUE_SETTLE_SECONDS ago");
  assert.equal(M.sValueUsable({ ...ok, lastUpdate: SETTLED + 1n }, NOW, SVALUE_SETTLE_SECONDS), false, "a second short of settled");
  assert.equal(M.sValueUsable({ ...ok, sValue: 0n }, NOW, SVALUE_SETTLE_SECONDS), false, "not held");
  assert.equal(M.sValueUsable({ ...ok, pauseStartTime: NOW + 3_600n }, NOW, SVALUE_SETTLE_SECONDS), false, "a pause scheduled ahead");
  assert.equal(M.sValueUsable({ ...ok, pauseStartTime: NOW - 1n }, NOW, SVALUE_SETTLE_SECONDS), false, "a pause under way");
});

test("a share's price at a rate is the token's: the price rounded down, the confidence up", () => {
  assert.deepEqual(M.atRate(price(5_800_000_000n, 3n), 10n * WAD), { price: 58_000_000_000n, conf: 30n, expo: -8, publishTime: NOW }, "NFLXon, ten shares");
  const p = M.atRate(price(1_000n, 1n), 1_073_295_574_329_814_516n); // STRCon's sValue when read
  assert.equal(p.price, 1_073n, "rounded down");
  assert.equal(p.conf, 2n, "rounded up");
  assert.equal(M.atRate(price(1n), WAD / 2n), null, "a price that rounds to nothing is none");
  assert.equal(M.atRate(null, WAD), null);
  assert.equal(M.atRate(undefined, WAD), null);
});

test("a share-priced leg is one at a share's feed; a leg at its own feed or with no id is not", () => {
  assert.deepEqual(sharePricedLegs([SHARE, OWN, null, SHARE.toUpperCase().replace("0X", "0x")]), [true, false, false, true]);
});

test("a share-priced leg with a settled sValue is priced at the share's price times it, and is share-priced no more", async () => {
  const { chain, asked } = fakeChain({ [A]: asset({ sValue: 10n * WAD }) });
  const sv = createSValues({ chain, oracle: ORACLE });
  const st = { tokens: [A, B, C], ids: [SHARE, OWN, null] };
  const legs = await sv.legs(st, [price(5_800_000_000n), price(7n), undefined], L);
  assert.deepEqual(legs[0], { price: M.atRate(price(5_800_000_000n), 10n * WAD), shared: false });
  assert.deepEqual(legs[1], { price: price(7n), shared: false }, "a leg at its own feed keeps the feed's price");
  assert.deepEqual(legs[2], { price: null, shared: false }, "a coin with no id has no price");
  assert.equal(asked.length, 1, "one call for the round");
  assert.deepEqual(asked[0].contracts.map((c) => [c.address, c.functionName, c.args[0]]), [[ORACLE, "assetData", A]], "only the share-priced leg is read");
  assert.equal(asked[0].blockNumber, L.number, "at the round's block");
});

test("a share-priced leg without a settled sValue keeps its share's price and stays share-priced", async () => {
  const cases = [
    ["not held by Ondo's oracle on this chain", asset({ sValue: 0n })],
    ["a corporate action scheduled", asset({ pauseStartTime: NOW + 60n, pending: 10n * WAD })],
    ["a corporate action under way", asset({ pauseStartTime: NOW - 60n, pending: 10n * WAD })],
    ["changed less than the settle time ago", asset({ lastUpdate: NOW - 60n })],
    ["a read that failed", { status: "failure" }],
  ];
  for (const [what, answer] of cases) {
    const logged = [];
    const { chain } = fakeChain({ [A]: answer });
    const sv = createSValues({ chain, oracle: ORACLE, log: (token, reason) => logged.push([token, reason]) });
    const [leg] = await sv.legs({ tokens: [A], ids: [SHARE] }, [price(100n)], L);
    assert.deepEqual(leg, { price: price(100n), shared: true }, what);
    assert.equal(logged.length, 1, `${what}: said once`);
    assert.match(logged[0][1], /^not valued/, what);
  }
});

test("a node that cannot answer values no share-priced leg, and a chain without Ondo's oracle reads nothing", async () => {
  const down = createSValues({ chain: fakeChain({ throws: true }).chain, oracle: ORACLE });
  assert.deepEqual(await down.legs({ tokens: [A], ids: [SHARE] }, [price(100n)], L), [{ price: price(100n), shared: true }]);
  const { chain, asked } = fakeChain({ [A]: asset() });
  const none = createSValues({ chain, oracle: null });
  assert.deepEqual(await none.legs({ tokens: [A, B], ids: [SHARE, OWN] }, [price(100n), price(7n)], L), [
    { price: price(100n), shared: true },
    { price: price(7n), shared: false },
  ]);
  assert.equal(asked.length, 0, "no oracle, no call");
});

test("a round reads a token once, however many indexes hold it, and a new block reads it again", async () => {
  const { chain, asked } = fakeChain({ [A]: asset({ sValue: 2n * WAD }), [B]: asset({ sValue: 3n * WAD }) });
  const sv = createSValues({ chain, oracle: ORACLE });
  const one = { tokens: [A, B], ids: [SHARE, SHARE] };
  const two = { tokens: [A.toUpperCase().replace("0X", "0x")], ids: [SHARE] };
  assert.deepEqual(await sv.of(one, L), [2n * WAD, 3n * WAD]);
  assert.deepEqual(await sv.of(two, L), [2n * WAD], "the same token, written otherwise");
  assert.equal(asked.length, 1);
  await sv.of(two, { number: L.number + 1n, timestamp: NOW + 1n });
  assert.equal(asked.length, 2, "read again at the next block");
});

test("Ondo's oracle is named on Ethereum and BNB Chain, and on no other chain", () => {
  assert.equal(CHAINS[1].ondoOracle, "0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6");
  assert.equal(CHAINS[56].ondoOracle, "0xF4Fd8a1B412633e10527454137A29Db7Aa35F15e");
  assert.equal(CHAINS[8453].ondoOracle, null);
  assert.equal(CHAINS[11155111].ondoOracle, null);
  assert.equal(SVALUE_SETTLE_SECONDS, 1200n);
});
