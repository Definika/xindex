import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as U from "../../bot/units.mjs";

const read = (path) => readFileSync(new URL(`../../../${path}`, import.meta.url), "utf8");
/// The vectors hold integers past 2^53: every bare integer is read as a BigInt.
const model = JSON.parse(read("test/vectors/settlement.json").replace(/([:[,]\s*)(-?\d+)(?=\s*[,\]}])/g, '$1"$2"'));
const vectors = model.vectors;
const big = (xs) => xs.map(BigInt);
const [SETTLES, EMPTY, BOUNDS, OVERFLOW, BELOW, LENGTH, ELAPSED] = [0, 1, 2, 3, 4, 5, 6];

/// The outcome of a settlement in the hub's order of checks: the clock, the length, the supply, each leg's caps, the bar.
function outcomeOf(v) {
  const bar = U.barAt(BigInt(v.elapsed));
  if (bar === null) return { outcome: ELAPSED };
  const g = U.gainOf(big(v.units), big(v.newUnits), v.weights.map(Number), BigInt(v.keepMask));
  if (g.error === "LengthMismatch") return { outcome: LENGTH };
  if (BigInt(v.supply) === 0n) return { outcome: EMPTY };
  if (g.error === "LegOutOfBounds") return { outcome: BOUNDS, ...g };
  if (g.error === "Overflow") return { outcome: OVERFLOW };
  return { outcome: g.gain < bar ? BELOW : SETTLES, bar, gain: g.gain };
}

test("the bot's arithmetic is WeightedMath's: every settlement vector, outcome, bar and gain", () => {
  assert.equal(vectors.length, 426);
  const seen = new Set();
  for (const v of vectors) {
    const got = outcomeOf(v);
    const outcome = Number(v.outcome);
    seen.add(outcome);
    assert.equal(got.outcome, outcome, `${v.kind} at ${v.elapsed}s`);
    if (outcome === SETTLES || outcome === BELOW) {
      assert.equal(got.bar, BigInt(v.bar));
      assert.equal(got.gain, BigInt(v.gain));
    }
    if (outcome === BOUNDS) {
      assert.equal(got.leg, Number(v.badLeg));
      assert.equal(got.units, BigInt(v.badUnits));
      assert.equal(got.lowest, BigInt(v.lowest));
      assert.equal(got.highest, BigInt(v.highest));
    }
  }
  assert.equal(seen.size, 7, "every outcome is among the vectors");
});

test("the bot's quote check is WeightedMath's: both sums, the floor and the verdict of every quote vector", () => {
  assert.equal(model.quotes.length, 77);
  let held = 0;
  for (const q of model.quotes) {
    const got = U.quoteOf(big(q.units), big(q.newUnits), big(q.prices), BigInt(q.tolerance));
    assert.equal(got.valueOut, BigInt(q.valueOut));
    assert.equal(got.valueIn, BigInt(q.valueIn));
    assert.equal(got.floor, BigInt(q.floor));
    assert.equal(got.holds, q.holds === "1");
    if (got.holds) held++;
  }
  assert.ok(held >= 15 && model.quotes.length - held >= 15, "both verdicts are among the vectors");
});

test("the bot's unit constants are WeightedMath's", () => {
  const source = read("src/WeightedMath.sol");
  const constant = (name) => source.match(new RegExp(`uint256 public constant ${name} = ([^;]+);`))[1];
  assert.equal(constant("MAX_TURNOVER"), "0.2e18");
  assert.equal(U.MAX_TURNOVER, 2n * 10n ** 17n);
  assert.equal(constant("MAX_GROWTH"), "1e18");
  assert.equal(U.MAX_GROWTH, 10n ** 18n);
  assert.equal(constant("BAR_MAX"), "0.5e18");
  assert.equal(U.BAR_MAX, 5n * 10n ** 17n);
  assert.equal(constant("BAR_HALF_LIFE"), "12 minutes");
  assert.equal(U.BAR_HALF_LIFE, 720n);
  assert.equal(constant("AUCTION_DURATION"), "4 hours");
  assert.equal(U.AUCTION_DURATION, 14_400n);
});

test("the bar starts at a half, halves every twelve minutes, never reaches zero, and ends with the auction", () => {
  assert.equal(U.barAt(0n), 5n * 10n ** 17n);
  assert.equal(U.barAt(720n), 25n * 10n ** 16n);
  assert.equal(U.barAt(360n), 375n * 10n ** 15n, "a straight line inside a half-life");
  assert.equal(U.barAt(14_400n), 476_837_158_204n);
  assert.equal(U.barAt(14_401n), null);
});

// An index of three coins at weights of 50%, 30% and 20%, worth $100 a share on its weights at $2,000, $60,000 and
// $20: 0.025 of the first (18 decimals), 0.0005 of the second (8) and 1 of the third (6).
const WEIGHTS = [5000, 3000, 2000];
const PRICES = [2000 / 1e18, 60_000 / 1e8, 20 / 1e6];
const ON_WEIGHTS = [25n * 10n ** 15n, 50_000n, 1_000_000n];
const worth = (units, prices = PRICES) => units.reduce((usd, x, i) => usd + Number(x) * prices[i], 0);

test("nameUnits clears the bar exactly and no further than a unit's grain", () => {
  // The first coin rose a quarter since the index was last on its weights.
  const prices = [2500 / 1e18, PRICES[1], PRICES[2]];
  for (const elapsed of [3600n, 7200n, 14_400n]) {
    const bar = U.barAt(elapsed);
    const named = U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices, bar });
    assert.ok(named, `a fill exists at ${elapsed}s`);
    const { gain } = U.gainOf(ON_WEIGHTS, named.newUnits, WEIGHTS);
    assert.equal(gain, named.gain);
    assert.ok(gain >= bar, "what it names, the hub accepts");
    // The second coin moves in steps of one raw unit in 50,000, each worth 6e-6 of gain at its weight: the fill cannot
    // sit closer to the bar than that.
    assert.ok(gain - bar < 2n * 10n ** 13n, `it gives ${gain - bar} more than the bar asks`);
    assert.ok(named.newUnits[0] < ON_WEIGHTS[0], "the coin that rose is sold");
    assert.ok(named.newUnits[1] > ON_WEIGHTS[1] && named.newUnits[2] > ON_WEIGHTS[2], "the others are bought");
  }
});

test("nameUnits takes more the later it fills, and the distance from the weights at the auction's end", () => {
  const prices = [2500 / 1e18, PRICES[1], PRICES[2]];
  const take = (elapsed) => {
    const named = U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices, bar: U.barAt(elapsed) });
    return U.takeUsd(ON_WEIGHTS, named.newUnits, prices) / worth(ON_WEIGHTS, prices);
  };
  assert.ok(take(3600n) < take(7200n) && take(7200n) < take(14_400n));
  assert.ok(take(3600n) < 0, "an hour in, the bar is above the distance: clearing it is a gift");
  // The distance: Σ w ln(w / share of value), 0.62% here. A lone fill at the last second keeps just under it.
  const value = worth(ON_WEIGHTS, prices);
  const distance = WEIGHTS.reduce((d, w, i) => d + (w / 1e4) * Math.log(w / 1e4 / ((Number(ON_WEIGHTS[i]) * prices[i]) / value)), 0);
  const last = take(14_400n);
  assert.ok(last > 0.9 * (1 - Math.exp(-distance)) && last < 1 - Math.exp(-distance), `${last} against ${distance}`);
});

test("nameUnits finds nothing to take from an index on its weights", () => {
  const named = U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices: PRICES, bar: U.barAt(14_400n) });
  assert.ok(named);
  assert.ok(U.takeUsd(ON_WEIGHTS, named.newUnits, PRICES) < 0, "clearing any bar from the weights costs the keeper");
});

test("nameUnits leaves a kept leg and a leg without a price alone, and needs two it can move", () => {
  const prices = [2500 / 1e18, PRICES[1], PRICES[2]];
  const bar = U.barAt(14_400n);
  const kept = U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, keepMask: 0b100n, prices, bar });
  assert.equal(kept.newUnits[2], ON_WEIGHTS[2]);
  assert.ok(U.gainOf(ON_WEIGHTS, kept.newUnits, WEIGHTS, 0b100n).gain >= bar);
  const unpriced = U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices: [prices[0], null, prices[2]], bar });
  assert.equal(unpriced.newUnits[1], ON_WEIGHTS[1]);
  assert.ok(U.gainOf(ON_WEIGHTS, unpriced.newUnits, WEIGHTS).gain >= bar);
  assert.equal(U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, keepMask: 0b110n, prices, bar }), null);
  assert.equal(U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices: [prices[0], null, undefined], bar }), null);
  assert.equal(U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices: [prices[0], 0, NaN], bar }), null);
});

test("nameUnits names nothing when no units it may name clear the bar", () => {
  // At the auction's first second the bar is a half: two legs of 30% and 20%, doubled, cannot score it.
  const bar = U.barAt(0n);
  assert.equal(U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, keepMask: 0b001n, prices: PRICES, bar }), null);
  assert.equal(U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices: PRICES, bar: null }), null);
});

test("nameUnits does not trade a leg that sits within its trading cost of its weight", () => {
  const prices = [2500 / 1e18, PRICES[1], PRICES[2]];
  const bar = U.barAt(14_400n);
  const free = U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices, bar });
  assert.ok(free.newUnits.every((x, i) => x !== ON_WEIGHTS[i]), "without a cost every leg moves");
  // The first coin up 3% leaves every leg within 2% of its weight: at a cost of 2% a leg, nothing is worth trading
  // for its own sake, and the fill moves only what the bar asks.
  const near = [2060 / 1e18, PRICES[1], PRICES[2]];
  const banded = U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices: near, bar, costBps: 200 });
  const moved = banded.newUnits.filter((x, i) => x !== ON_WEIGHTS[i]).length;
  assert.ok(moved < 3, "a leg inside the band is left alone");
  assert.ok(U.gainOf(ON_WEIGHTS, banded.newUnits, WEIGHTS).gain >= bar);
});

test("under a quote, nameUnits gives the index what the quote asks, where alone it would keep the distance", () => {
  const prices = [2500 / 1e18, PRICES[1], PRICES[2]];
  const bar = U.barAt(14_400n);
  // The quote: the same prices, per raw unit at one scale (1e18 a dollar), and half a percent of tolerance.
  const quote = { prices: [2500n, 60_000n * 10n ** 10n, 20n * 10n ** 12n], tolerance: 5n * 10n ** 15n };
  const alone = U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices, bar });
  const quoted = U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices, bar, quote });
  assert.equal(U.quoteOf(ON_WEIGHTS, alone.newUnits, quote.prices, quote.tolerance).holds, false, "the lone fill fails the quote");
  const held = U.quoteOf(ON_WEIGHTS, quoted.newUnits, quote.prices, quote.tolerance);
  assert.ok(held.holds, "what it names under a quote holds it");
  assert.ok(U.gainOf(ON_WEIGHTS, quoted.newUnits, WEIGHTS).gain >= bar);
  const kept = Number(held.valueOut - held.valueIn) / Number(held.valueOut);
  assert.ok(kept > 0.004 && kept <= 0.005, `it keeps ${kept} of what it trades: the tolerance, no more`);
  assert.ok(U.takeUsd(ON_WEIGHTS, quoted.newUnits, prices) < U.takeUsd(ON_WEIGHTS, alone.newUnits, prices));
  // A wrong quote, the first coin posted at a thousand times its price: a sale of it must be paid a thousand times
  // over, so the only units that hold it are a gift, which the keeper's simulation then refuses to send.
  const wrong = { prices: [2_500_000n, quote.prices[1], quote.prices[2]], tolerance: 0n };
  const gift = U.nameUnits({ units: ON_WEIGHTS, weights: WEIGHTS, prices, bar, quote: wrong });
  assert.ok(U.quoteOf(ON_WEIGHTS, gift.newUnits, wrong.prices, wrong.tolerance).holds);
  assert.ok(U.takeUsd(ON_WEIGHTS, gift.newUnits, prices) < 0, "holding a wrong quote costs the keeper");
});

test("whatever nameUnits returns is inside every cap and clears its bar", () => {
  let seed = 20261110;
  const random = () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  let named = 0;
  for (let round = 0; round < 400; round++) {
    const n = 2 + Math.floor(random() * 7);
    let left = 10_000;
    const weights = Array.from({ length: n }, (_, i) => {
      const w = i === n - 1 ? left : Math.max(1, Math.floor(random() * (left - (n - 1 - i))));
      left -= w;
      return w;
    });
    const units = weights.map(() => BigInt(Math.floor(10 ** (3 + random() * 20))));
    const prices = units.map(() => 10 ** (-20 + random() * 12));
    const keepMask = random() < 0.2 ? 1n << BigInt(Math.floor(random() * n)) : 0n;
    const bar = U.barAt(BigInt(Math.floor(random() * 14_401)));
    const out = U.nameUnits({ units, weights, keepMask, prices, bar, costBps: Math.floor(random() * 100) });
    if (!out) continue;
    named++;
    const g = U.gainOf(units, out.newUnits, weights, keepMask);
    assert.equal(g.error, undefined);
    assert.ok(g.gain >= bar);
  }
  assert.ok(named > 100, `only ${named} of 400 rounds named a fill`);
});
