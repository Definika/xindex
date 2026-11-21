import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_RATE_MOVE_BPS, RATE_LOOKBACK_BLOCKS, SHARE_PRICED_IDS } from "../../bot/config.mjs";
import { MAINNET_PRICE_IDS, MAINNET_WRAPPED } from "../../bot/price-ids.mjs";
import { assetDecimalsOf, createRates, sharePricedLegs } from "../../bot/rates.mjs";

const addr = (byte) => `0x${byte.repeat(20)}`;
const [PLAIN, WRAPPER, OTHER, XSTOCK, SIX] = [addr("01"), addr("aa"), addr("bb"), addr("0c"), addr("0d")];
const WAD = 10n ** 18n;
const NOW = 1_000n;
const BEFORE = NOW - RATE_LOOKBACK_BLOCKS;

/// A chain of wrappers, each of `decimalsOf(wrapper)` over an asset of `assetDecimalsOf(wrapper)`, worth
/// `rate(wrapper, blockNumber)` of it in 1e18, or unread where that is undefined. It answers `convertToAssets` for the
/// shares it is asked about, as a vault does, and counts every call.
function fake(rate, { decimalsOf = () => 18, assetDecimals = () => 18, assetOf = () => XSTOCK, throws = () => false } = {}) {
  const calls = [];
  const multicall = async (contracts, blockNumber) => {
    if (throws(blockNumber)) throw new Error("the node is down");
    return contracts.map((c) => {
      calls.push({ ...c, blockNumber });
      try {
        if (c.functionName === "asset") return { status: "success", result: assetOf(c.address) };
        if (c.functionName === "decimals") return { status: "success", result: c.address === SIX ? 6 : 18 };
        const r = rate(c.address, blockNumber);
        if (r === undefined) return { status: "failure" };
        // shares, in the wrapper's decimals, times the rate, in the asset's decimals
        return { status: "success", result: (c.args[0] * r * 10n ** BigInt(assetDecimals(c.address))) / (WAD * 10n ** BigInt(decimalsOf(c.address))) };
      } catch {
        return { status: "failure" };
      }
    });
  };
  return { chain: { multicall }, calls };
}
const st = { tokens: [PLAIN, WRAPPER], decimals: [8, 18], assetDecimals: [null, 18] };

test("a wrapped coin's statics hold the decimals of what it wraps, and a plain coin's nothing", async () => {
  const { chain, calls } = fake(() => WAD, { assetOf: (a) => (a === OTHER ? SIX : XSTOCK) });
  const wrapped = new Set([WRAPPER, OTHER]);
  assert.deepEqual(await assetDecimalsOf({ chain, wrapped }, [PLAIN, WRAPPER, OTHER], NOW), [null, 18, 6]);
  assert.deepEqual(calls.map((c) => c.functionName), ["asset", "asset", "decimals", "decimals"]);
  assert.deepEqual(await assetDecimalsOf({ chain, wrapped: new Set() }, [PLAIN, WRAPPER], NOW), [null, null], "a chain without wrapped coins reads nothing");
  assert.equal(calls.length, 4);
  // The set holds lowercased addresses, and an index names its tokens in checksum case.
  assert.deepEqual(await assetDecimalsOf({ chain, wrapped }, [WRAPPER.toUpperCase().replace("0X", "0x")], NOW), [18]);
});

test("a wrapper whose asset, or whose asset's decimals, cannot be read stops its index's statics", async () => {
  const wrapped = new Set([WRAPPER]);
  const noAsset = fake(() => WAD, { assetOf: () => { throw new Error(); } });
  await assert.rejects(assetDecimalsOf({ chain: noAsset.chain, wrapped }, [WRAPPER], NOW), /asset read failed/);
  const noDecimals = { multicall: async (contracts) => contracts.map((c) => (c.functionName === "asset" ? { status: "success", result: XSTOCK } : { status: "failure" })) };
  await assert.rejects(assetDecimalsOf({ chain: noDecimals, wrapped }, [WRAPPER], NOW), /decimals read failed/);
});

test("RX-2: a leg is share-priced when its feed prices a share and the bot reads no rate for it", () => {
  const [tsm, googl] = ["0x083283fafd9cec6145ce6a4a50f020a01737de52", "0x1630f08370917e79df0b7572395a5e907508bbbc"]; // wTSMx, wGOOGLx
  const ids = [MAINNET_PRICE_IDS[tsm], MAINNET_PRICE_IDS[googl], MAINNET_PRICE_IDS["0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"], null];
  // wTSMx takes the feed TSMon took, and wGOOGLx its xStock's own: read as wrappers, neither is share-priced.
  assert.deepEqual(sharePricedLegs(ids, [18, 18, null, null], SHARE_PRICED_IDS), [false, false, false, false]);
  // The same feeds under a token the bot reads no rate for, an Ondo leg or a wrapper the catalogue does not hold: both
  // are, so neither is ever valued at its feed as if it were one share. A plain coin and a coin without an id are not.
  assert.deepEqual(sharePricedLegs(ids, [null, null, null, null], SHARE_PRICED_IDS), [true, true, false, false]);
  assert.deepEqual(sharePricedLegs([ids[0].toUpperCase().replace("0X", "0x")], [null], SHARE_PRICED_IDS), [true], "whatever the id's case");
  // Every wrapper of the catalogue is covered, so none depends on its address alone.
  for (const token of MAINNET_WRAPPED) assert.ok(SHARE_PRICED_IDS.includes(MAINNET_PRICE_IDS[token]), token);
});

test("a wrapper's rate is read at the round's block and RATE_LOOKBACK_BLOCKS before it; a plain coin has none", async () => {
  const rate = (WAD * 1_002n) / 1_000n;
  const { chain, calls } = fake(() => rate);
  const rates = createRates({ chain });
  assert.deepEqual(await rates.of(st, NOW), [undefined, rate]);
  assert.deepEqual(calls.map((c) => [c.address, c.functionName, c.args[0], c.blockNumber]), [
    [WRAPPER, "convertToAssets", WAD, NOW],
    [WRAPPER, "convertToAssets", WAD, BEFORE],
  ]);
});

test("the rate is asked for one whole wrapper, in the wrapper's decimals, and read in the asset's", async () => {
  // A wrapper of eight decimals over an asset of six, worth 2.5 of it: 1e8 raw redeems for 2,500,000 raw.
  const { chain, calls } = fake(() => (WAD * 5n) / 2n, { decimalsOf: () => 8, assetDecimals: () => 6 });
  const rates = createRates({ chain });
  assert.deepEqual(await rates.of({ tokens: [WRAPPER], decimals: [8], assetDecimals: [6] }, NOW), [(WAD * 5n) / 2n]);
  assert.equal(calls[0].args[0], 10n ** 8n);
  // And the other way: eighteen decimals over an asset of six.
  const wide = fake(() => (WAD * 5n) / 2n, { decimalsOf: () => 18, assetDecimals: () => 6 });
  assert.deepEqual(await createRates({ chain: wide.chain }).of({ tokens: [WRAPPER], decimals: [18], assetDecimals: [6] }, NOW), [(WAD * 5n) / 2n]);
});

test("a rate that moved more than MAX_RATE_MOVE_BPS within the look-back values nothing, and is said once", async () => {
  const lines = [];
  const was = WAD;
  const bound = was + (was * MAX_RATE_MOVE_BPS) / 10_000n;
  for (const [now, steady] of [[bound, true], [bound + 1n, false], [was * 10n, false], [was / 10n, false], [0n, false]]) {
    const { chain } = fake((_, block) => (block === NOW ? now : was));
    const rates = createRates({ chain, log: (...a) => lines.push(a.join(" ")) });
    assert.deepEqual(await rates.of(st, NOW), [undefined, steady ? now : null], `${now}`);
  }
  assert.equal(lines.length, 4);
  assert.match(lines[0], /not valued: its rate moved from 1000000000000000000 to 1010000000000000001 within 100 blocks/);

  // Said once while it lasts, and again only after the rate was steady in between.
  let now = was * 2n;
  const { chain } = fake((_, block) => (block >= NOW ? now : was));
  const said = [];
  const rates = createRates({ chain, log: (...a) => said.push(a.join(" ")) });
  await rates.of(st, NOW);
  await rates.of(st, NOW + 1n);
  assert.equal(said.length, 1);
  now = was;
  assert.deepEqual(await rates.of(st, NOW + 2n), [undefined, was]);
  now = was * 2n;
  await rates.of(st, NOW + 3n);
  assert.equal(said.length, 2);
});

test("a rate that cannot be read, now or at the look-back, values nothing; it is not a rate of one", async () => {
  for (const missing of [NOW, BEFORE]) {
    const { chain } = fake((_, block) => (block === missing ? undefined : WAD));
    assert.deepEqual(await createRates({ chain }).of(st, NOW), [undefined, null], `unread at ${missing}`);
  }
  const lines = [];
  const down = fake(() => WAD, { throws: (block) => block === BEFORE });
  assert.deepEqual(await createRates({ chain: down.chain, log: (...a) => lines.push(a.join(" ")) }).of(st, NOW), [undefined, null]);
  assert.match(lines[0], /its rate could not be read: the node is down/);
  // One wrapper's failed read leaves the others of the same round their rates.
  const two = { tokens: [WRAPPER, OTHER], decimals: [18, 18], assetDecimals: [18, 18] };
  const one = fake((token) => (token === OTHER ? undefined : WAD));
  assert.deepEqual(await createRates({ chain: one.chain }).of(two, NOW), [WAD, null]);
});

test("a chain not yet older than the look-back values no wrapper, and asks the node nothing", async () => {
  // A client that reads block zero as "latest" would compare the rate with itself.
  for (const young of [1n, RATE_LOOKBACK_BLOCKS]) {
    const lines = [];
    const { chain, calls } = fake(() => WAD);
    assert.deepEqual(await createRates({ chain, log: (...a) => lines.push(a.join(" ")) }).of(st, young), [undefined, null]);
    assert.equal(calls.length, 0);
    assert.match(lines[0], /the chain is not 100 blocks old/);
  }
  const { chain, calls } = fake(() => WAD);
  assert.deepEqual(await createRates({ chain }).of(st, RATE_LOOKBACK_BLOCKS + 1n), [undefined, WAD]);
  assert.deepEqual(calls.map((c) => c.blockNumber), [RATE_LOOKBACK_BLOCKS + 1n, 1n]);
});

test("one round reads a wrapper once, in two calls for all of an index's, and the next block reads again", async () => {
  let multicalls = 0;
  const { chain, calls } = fake(() => WAD);
  const counted = { multicall: (...a) => (multicalls++, chain.multicall(...a)) };
  const rates = createRates({ chain: counted });
  const other = { tokens: [WRAPPER, OTHER, PLAIN], decimals: [18, 18, 8], assetDecimals: [18, 18, null] };
  await Promise.all([rates.of(st, NOW), rates.of(st, NOW), rates.of(other, NOW)]);
  assert.equal(calls.filter((c) => c.address === WRAPPER).length, 2, "now and before, once each");
  assert.equal(calls.length, 4, "and the other wrapper's two");
  assert.equal(multicalls, 4, "two calls to the node for the first index, two for what the second adds");
  // An index of many wrappers is still two calls.
  const many = { tokens: [OTHER, WRAPPER, addr("cc"), addr("dd")], decimals: [18, 18, 18, 18], assetDecimals: [18, 18, 18, 18] };
  multicalls = 0;
  await createRates({ chain: counted }).of(many, NOW);
  assert.equal(multicalls, 2);
  multicalls = 0;
  await rates.of(st, NOW + 1n);
  assert.equal(multicalls, 2, "the next block reads again");
});

test("priced: a plain coin at its feed, a wrapper at its feed times its rate, and none without a steady rate", async () => {
  const p = { price: 100_00000n, conf: 10n, expo: -5, publishTime: 1n };
  const steady = createRates({ chain: fake(() => 2n * WAD).chain });
  assert.deepEqual(await steady.priced(st, [p, p], NOW), [p, { price: 200_00000n, conf: 20n, expo: -5, publishTime: 1n }]);
  assert.deepEqual(await steady.priced(st, [undefined, null], NOW), [null, null], "no feed price is no price");
  const moved = createRates({ chain: fake((_, block) => (block === NOW ? 2n * WAD : WAD)).chain });
  assert.deepEqual(await moved.priced(st, [p, p], NOW), [p, null]);
});
