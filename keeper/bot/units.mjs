// The units a fill names. Since 2026-11-10 no contract reads a price: `executeRebalance(newUnits, data)` settles at
// the units its caller names, and `WeightedMath` accepts them when every leg is inside its unit caps and a weighted
// gain in units clears the auction's bar (design/2026-11-10-oracle-free-rebalance.md). This file is the keeper's side
// of that rule, pure and dependency-free:
//   - the hub's arithmetic, word for word (`barAt`, `gainOf`), so the bot knows what the index will accept before it
//     asks; `test/unit/units.test.mjs` replays the contracts' own vectors (test/vectors/settlement.json) through it;
//   - `nameUnits`, which picks, at the keeper's own prices, the units that clear the bar while giving the index the
//     least: the keeper's best fill at that second.
// Amounts and units are BigInt; prices are floats, used only to choose, and whatever they choose is checked in exact
// integers before it is returned.

const WAD = 10n ** 18n;
const TOTAL_WEIGHT = 10_000n;
const SCORE_DENOMINATOR = 30n * 10n ** 54n;
const UINT96_MAX = 2n ** 96n - 1n;

/// WeightedMath's constants, which `test/unit/units.test.mjs` pins against src/WeightedMath.sol.
export const MAX_TURNOVER = 2n * 10n ** 17n;
export const MAX_GROWTH = WAD;
export const BAR_MAX = 5n * 10n ** 17n;
export const BAR_HALF_LIFE = 720n;
export const AUCTION_DURATION = 14_400n;

/// The most the keeper grows a leg: 1.9 times its units. The hub allows twice, but the score `L` peaks near 1.92 and
/// falls after, so past it a leg costs more and scores less; under it the gain only rises with the units named.
const GROWTH_USED = 9n * 10n ** 17n;

const ceilDiv = (a, b) => (a + b - 1n) / b;
/// a / b rounded toward minus infinity, for b > 0: BigInt division truncates toward zero.
const floorDiv = (a, b) => (a % b < 0n ? a / b - 1n : a / b);

/// The bar `elapsed` seconds into an auction, as `WeightedMath.barAt`: a half, halving every twelve minutes along a
/// straight line, rounded up. Null once the auction is over, where the hub reverts.
export function barAt(elapsed) {
  const e = BigInt(elapsed);
  if (e < 0n || e > AUCTION_DURATION) return null;
  const halvings = e / BAR_HALF_LIFE;
  const intoThisOne = e % BAR_HALF_LIFE;
  return ceilDiv(BAR_MAX * (2n * BAR_HALF_LIFE - intoThisOne), (2n * BAR_HALF_LIFE) << halvings);
}

/// The fewest and the most units a fill may leave a leg that holds `current`: four fifths, rounded up, and twice.
export const lowestOf = (current) => ceilDiv(current * (WAD - MAX_TURNOVER), WAD);
export const highestOf = (current) => current + (current * MAX_GROWTH) / WAD;

/// A leg's relative change in units, in 1e18ths, rounded toward minus infinity (`WeightedMath._change`).
export function changeOf(current, next) {
  if (next >= current) return ((next - current) * WAD) / current;
  return -ceilDiv((current - next) * WAD, current);
}

/// `L(x) = x − x²/2 + x³/3 − 3x⁴/10` in 1e18ths, rounded toward minus infinity (`WeightedMath._score`).
export function scoreOf(x) {
  const square = x * x;
  const numerator = 30n * x * WAD * WAD * WAD - 15n * square * WAD * WAD + 10n * square * x * WAD - 9n * square * square;
  return floorDiv(numerator, SCORE_DENOMINATOR);
}

/// The gain of moving `units` to `newUnits` at `weights` (basis points summing to 10,000), as `WeightedMath._gain`:
/// `{gain}`, or `{error}` naming what the hub would revert with (`LengthMismatch`, `LegOutOfBounds`, `Overflow`). A
/// kept leg must keep its units exactly.
export function gainOf(units, newUnits, weights, keepMask = 0n) {
  if (newUnits.length !== units.length) return { error: "LengthMismatch" };
  let total = 0n;
  for (let i = 0; i < units.length; i++) {
    const current = units[i];
    const next = newUnits[i];
    const kept = ((keepMask >> BigInt(i)) & 1n) === 1n;
    const lowest = kept ? current : lowestOf(current);
    const highest = kept ? current : highestOf(current);
    if (next < lowest || next > highest) return { error: "LegOutOfBounds", leg: i, units: next, lowest, highest };
    if (next > UINT96_MAX) return { error: "Overflow", leg: i, units: next };
    total += BigInt(weights[i]) * scoreOf(changeOf(current, next));
  }
  return { gain: floorDiv(total, TOTAL_WEIGHT) };
}

/// The units the keeper names for a fill that must clear `bar`: for every leg it may move, `λ · weight / price`, with
/// `λ` the smallest that clears the bar. That is the fill that leaves the index the least value at `prices` among
/// those the index accepts (the first-order condition of maximising what is taken under a gain of logarithms), so it
/// is the keeper's best at that second; whether it pays is the simulation's to say, not this function's.
///
/// `prices[i]` is dollars per raw unit of leg `i`, or null for a leg the keeper cannot value, which it leaves alone,
/// as it does a kept one. `costBps` is what trading a leg is taken to cost: a leg is grown only past its target at the
/// price plus that cost, shrunk only past it at the price less that cost, and otherwise left, so a leg within the
/// cost of its weight is not traded for nothing. Returns `{newUnits, gain}`, checked in the hub's exact arithmetic, or
/// null when fewer than two legs can move or nothing this function can name clears the bar.
export function nameUnits({ units, weights, keepMask = 0n, prices, bar, costBps = 0 }) {
  const free = [];
  for (let i = 0; i < units.length; i++) {
    const kept = ((keepMask >> BigInt(i)) & 1n) === 1n;
    if (!kept && Number.isFinite(prices[i]) && prices[i] > 0 && units[i] > 0n) free.push(i);
  }
  if (free.length < 2 || bar === null || bar === undefined) return null;
  const cost = costBps / 10_000;
  const u = units.map(Number);
  const w = weights.map(Number);
  const ask = (i) => prices[i] * (1 + cost);
  const bid = (i) => prices[i] * (1 - cost);

  const at = (lambda) => {
    const named = [...units];
    for (const i of free) {
      const grown = (lambda * w[i]) / ask(i);
      const shrunk = (lambda * w[i]) / bid(i);
      const target = grown > u[i] ? grown : shrunk < u[i] ? shrunk : null;
      if (target === null || !Number.isFinite(target)) continue;
      const lowest = lowestOf(units[i]);
      const top = units[i] + (units[i] * GROWTH_USED) / WAD;
      const highest = top > UINT96_MAX ? UINT96_MAX : top;
      let next = BigInt(Math.floor(target));
      if (next < lowest) next = lowest;
      if (next > highest) next = highest;
      named[i] = next;
    }
    return named;
  };
  const clears = (named) => {
    const g = gainOf(units, named, weights, keepMask);
    return g.error === undefined && g.gain >= bar ? g.gain : null;
  };

  // Every leg sits at its lower cap below `low` and at its upper one above `high`; the gain rises with λ between.
  let low = Infinity;
  let high = 0;
  for (const i of free) {
    low = Math.min(low, Math.log((0.8 * u[i] * bid(i)) / w[i]));
    high = Math.max(high, Math.log((1.9 * u[i] * ask(i)) / w[i]));
  }
  low -= 1e-6;
  high += 1e-6;
  let best = at(Math.exp(high));
  let bestGain = clears(best);
  if (bestGain === null) return null;
  for (let step = 0; step < 200 && high - low > 1e-15; step++) {
    const mid = (low + high) / 2;
    const named = at(Math.exp(mid));
    const gain = clears(named);
    if (gain === null) low = mid;
    else {
      high = mid;
      best = named;
      bestGain = gain;
    }
  }
  return { newUnits: best, gain: bestGain };
}

/// What `newUnits` leaves the keeper, in dollars per 1e18 shares at `prices` (dollars per raw unit): the value of the
/// units the index gives up less the value of those it gains, before routes and gas. Legs without a price count as
/// nothing, and the keeper never moves them.
export function takeUsd(units, newUnits, prices) {
  let usd = 0;
  for (let i = 0; i < units.length; i++) {
    if (!(prices[i] > 0)) continue;
    usd += (Number(units[i]) - Number(newUnits[i])) * prices[i];
  }
  return usd;
}
