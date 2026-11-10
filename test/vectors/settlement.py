#!/usr/bin/env python3
"""The exact model of an oracle-free settlement, and the vectors `test/WeightedMath.vectors.t.sol` replays.

The model is written from the spec (`design/2026-11-10-oracle-free-rebalance.md`, section 4), in exact rationals, not
from `src/WeightedMath.sol`: it never chains a `mulDiv`, it rounds each quantity once, where the spec says to. The test
compares the contract's answer with the model's, word for word, on every vector.

No price enters a settlement. The executor names each leg's new units; the index accepts them when every leg stays
inside its unit caps and the weighted gain clears the auction's bar:

    gain = floor( sum_i w_i * L(x_i) / TOTAL_WEIGHT ) >= bar(elapsed),   x_i = floor( (v_i - u_i) * 1e18 / u_i )
    L(x) = floor( x - x^2/2 + x^3/3 - 3 x^4/10 ),  in 1e18 fixed point

L is a lower bound of ln(1 + x) on the capped range, so an accepted fill never lowers the weighted product of the
units (section 3 of the record).

Run from the repository root, with no dependency beyond the standard library:

    python3 -I test/vectors/settlement.py > test/vectors/settlement.json

The generator is deterministic (SEED), so a rerun reproduces the committed file. Change the arithmetic, this model or
the vectors together, and commit the three in one change.
"""
import json
import math
import random
from fractions import Fraction

WAD = 10**18
UNIT_SCALE = 10**36  # shares · units · scale / 1e36
TOTAL_WEIGHT = 10_000
MAX_TURNOVER = 200_000_000_000_000_000  # a fill takes at most 20% of a leg's own units
MAX_GROWTH = WAD  # and adds at most 100% of them
BAR_MAX = 500_000_000_000_000_000  # the bar at the auction's first second
BAR_HALF_LIFE = 720  # seconds in which the bar halves
AUCTION_DURATION = 14_400  # twenty half-lives
UINT96_MAX = 2**96 - 1
MIN_RAW_UNITS = 10**4
MAX_UNITS = UINT96_MAX >> 10  # the factory's bound at creation; a fill may grow a leg up to UINT96_MAX
SEED = 20261110

SETTLES, EMPTY, BOUNDS, OVERFLOW, BELOW, LENGTH, ELAPSED = 0, 1, 2, 3, 4, 5, 6


def floor(x):
    return math.floor(Fraction(x))


def ceil(x):
    return math.ceil(Fraction(x))


def bar_at(elapsed):
    """The bar `elapsed` seconds into the auction: BAR_MAX halved once per BAR_HALF_LIFE, a straight line within each
    half-life, rounded up once. None past the auction's end."""
    if elapsed > AUCTION_DURATION:
        return None
    k, r = divmod(elapsed, BAR_HALF_LIFE)
    return ceil(Fraction(BAR_MAX * (2 * BAR_HALF_LIFE - r), 2 * BAR_HALF_LIFE * 2**k))


def change(u, v):
    """A leg's relative change in units, (v - u) / u at 1e18, rounded down (toward minus infinity)."""
    return floor(Fraction((v - u) * WAD, u))


def score(x):
    """L(x) = x - x^2/2 + x^3/3 - 3x^4/10 at 1e18, rounded down: a lower bound of ln(1 + x) on [-0.2, 1]."""
    return floor(Fraction(30 * x * WAD**3 - 15 * x**2 * WAD**2 + 10 * x**3 * WAD - 9 * x**4, 30 * WAD**3))


def bounds(u, kept):
    """The least and most units a fill may leave a leg with: its own units if kept, else what MAX_TURNOVER leaves,
    rounded up, and what MAX_GROWTH adds, rounded down."""
    if kept:
        return u, u
    return ceil(Fraction(u * (WAD - MAX_TURNOVER), WAD)), u + floor(Fraction(u * MAX_GROWTH, WAD))


def gain_of(units, new_units, weights):
    return floor(Fraction(sum(w * score(change(u, v)) for u, v, w in zip(units, new_units, weights)), TOTAL_WEIGHT))


def settle(elapsed, supply, scale, units, new_units, weights, keep):
    """The settlement `elapsed` seconds into the auction: (SETTLES, bar, gain, amounts out, amounts in), or a refusal.

    Refusals, in the order the spec checks them: (ELAPSED,) past the auction; (LENGTH,) a list of another length;
    (EMPTY,) no supply; (BOUNDS, i, v, lowest, highest) the first leg outside its caps; (OVERFLOW, v) the first leg
    above uint96; (BELOW, gain, bar) a gain under the bar.
    """
    bar = bar_at(elapsed)
    if bar is None:
        return (ELAPSED,)
    n = len(units)
    if len(new_units) != n:
        return (LENGTH,)
    if supply == 0:
        return (EMPTY,)
    for i in range(n):
        u, v = units[i], new_units[i]
        lowest, highest = bounds(u, (keep >> i) & 1)
        if v < lowest or v > highest:
            return (BOUNDS, i, v, lowest, highest)
        if v > UINT96_MAX:
            return (OVERFLOW, v)
    gain = gain_of(units, new_units, weights)
    if gain < bar:
        return (BELOW, gain, bar)
    # Each amount is the leg's change in backing, shares · Δunits · scale / 1e36, rounded down when it leaves and up
    # when it comes back.
    out = [floor(Fraction(supply * (u - v) * scale, UNIT_SCALE)) if v < u else 0 for u, v in zip(units, new_units)]
    inn = [ceil(Fraction(supply * (v - u) * scale, UNIT_SCALE)) if v > u else 0 for u, v in zip(units, new_units)]
    return (SETTLES, bar, gain, out, inn)


# ---------------------------------------------------------------------------------------------------------------------
# The generator
# ---------------------------------------------------------------------------------------------------------------------


def log_uniform(rng, lo, hi):
    """An integer whose magnitude is uniform between `lo` and `hi`, exclusive of `hi`."""
    return int(math.exp(rng.uniform(math.log(lo), math.log(hi))))


def partition(rng, n):
    cuts = sorted(rng.sample(range(1, TOTAL_WEIGHT), n - 1))
    return [b - a for a, b in zip([0] + cuts, cuts + [TOTAL_WEIGHT])]


def mask_leaving_two(rng, n):
    while True:
        mask = rng.randrange(1, 1 << n)
        if n - bin(mask).count("1") >= 2:
            return mask


def first_second(units, new_units, weights):
    """The first second of the auction at which this fill clears the bar, or None if it never does."""
    gain = gain_of(units, new_units, weights)
    if gain < bar_at(AUCTION_DURATION):
        return None
    lo, hi = -1, AUCTION_DURATION  # the bar falls with time: bisect on it
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if gain >= bar_at(mid):
            hi = mid
        else:
            lo = mid
    return hi


def trade(rng, units, weights, keep, spread):
    """A fill an executor might send: legs priced above their weight shrink, the others grow, by up to `spread`."""
    new_units = []
    for i, u in enumerate(units):
        if (keep >> i) & 1:
            new_units.append(u)
            continue
        lowest, highest = bounds(u, 0)
        factor = math.exp(rng.gauss(0.01, spread))
        new_units.append(min(max(int(u * factor), lowest), min(highest, UINT96_MAX)))
    return new_units


def make(rng, kind):
    n = rng.choice([2, 2, 3, 3, 3, 4, 5, 6, 8, 12])
    weights = partition(rng, n)
    units = [log_uniform(rng, MIN_RAW_UNITS, MAX_UNITS) for _ in range(n)]
    supply = log_uniform(rng, 10**15, 10**30)
    scale = WAD
    keep = 0
    elapsed = rng.randrange(0, AUCTION_DURATION + 1)
    new_units = trade(rng, units, weights, keep, 0.05)

    if kind == "trade":
        # A fill at the first second it clears the bar, the second before, or any later one.
        first = first_second(units, new_units, weights)
        if first is not None:
            elapsed = rng.choice([first, max(first - 1, 0), rng.randrange(first, AUCTION_DURATION + 1)])
    elif kind == "wide":
        new_units = trade(rng, units, weights, keep, 0.25)
    elif kind == "gift":
        # Every leg grows: the executor gives and takes nothing.
        new_units = [min(u + max(1, u * rng.randrange(1, 60) // 1000), UINT96_MAX) for u in units]
        first = first_second(units, new_units, weights)
        elapsed = first if first is not None else AUCTION_DURATION
    elif kind == "caps":
        # Each leg on a cap, or one raw unit beyond it.
        new_units = []
        for u in units:
            lowest, highest = bounds(u, 0)
            new_units.append(rng.choice([lowest, highest, lowest, highest, lowest - 1, highest + 1, u]))
        elapsed = AUCTION_DURATION
    elif kind == "tiny":
        # A few raw units a leg: the caps and the change round visibly.
        units = [rng.randrange(1, 60) for _ in range(n)]
        new_units = []
        for u in units:
            lowest, highest = bounds(u, 0)
            new_units.append(rng.randrange(max(lowest - 1, 0), highest + 2))
        elapsed = AUCTION_DURATION
    elif kind == "kept":
        keep = mask_leaving_two(rng, n) if n > 2 else 0
        new_units = trade(rng, units, weights, keep, 0.05)
        if rng.random() < 0.3 and keep:
            i = rng.choice([i for i in range(n) if (keep >> i) & 1])
            new_units[i] += rng.choice([-1, 1])  # a kept leg moved by one raw unit
        first = first_second(units, new_units, weights)
        elapsed = first if first is not None else AUCTION_DURATION
    elif kind == "dust":
        supply = rng.choice([0, 0, 1, 2])
        elapsed = AUCTION_DURATION
        new_units = [min(u + max(1, u // 100), UINT96_MAX) for u in units]
    elif kind == "scaled":
        scale = log_uniform(rng, 10**10, WAD)
        first = first_second(units, new_units, weights)
        elapsed = first if first is not None else AUCTION_DURATION
    elif kind == "huge":
        # A growing leg at the 96-bit ceiling: inside its growth cap, beyond what the hub can record (RX-61).
        i = rng.randrange(n)
        units[i] = rng.randrange((UINT96_MAX * 6) // 10, UINT96_MAX + 1)
        new_units = list(units)
        new_units[i] = rng.randrange(UINT96_MAX + 1, 2 * units[i] + 1)
        elapsed = AUCTION_DURATION
    elif kind == "clock":
        # The bar's own corners: each half-life, the seconds beside it, the last second, and past the end.
        k = rng.randrange(0, AUCTION_DURATION // BAR_HALF_LIFE + 1)
        elapsed = min(max(k * BAR_HALF_LIFE + rng.choice([-1, 0, 1]), 0), AUCTION_DURATION)
        if rng.random() < 0.25:
            elapsed = AUCTION_DURATION + rng.randrange(1, 10**6)
        new_units = [min(u + max(1, u // 3), UINT96_MAX) for u in units]
    elif kind == "length":
        new_units = new_units[:-1] if rng.random() < 0.5 else new_units + [units[0]]
    else:
        raise ValueError(kind)
    return dict(kind=kind, elapsed=elapsed, supply=supply, scale=scale, units=units, newUnits=new_units,
                weights=weights, keepMask=keep)


def boundary(rng):
    """Two fills a raw unit apart on one growing leg, on either side of the bar, found by bisection on its units."""
    while True:
        n = rng.choice([2, 3, 4])
        weights = partition(rng, n)
        units = [log_uniform(rng, MIN_RAW_UNITS, MAX_UNITS) for _ in range(n)]
        supply = log_uniform(rng, 10**15, 10**30)
        elapsed = rng.randrange(0, AUCTION_DURATION + 1)
        bar = bar_at(elapsed)
        new_units = list(units)
        j, k = rng.sample(range(n), 2)
        new_units[k] = bounds(units[k], 0)[0] + (units[k] - bounds(units[k], 0)[0]) * rng.randrange(0, 100) // 100
        lo, hi = units[j], bounds(units[j], 0)[1]  # at lo: no gain from leg j; at hi: twice the units
        probe = list(new_units)
        probe[j] = lo
        if gain_of(units, probe, weights) >= bar:
            continue
        probe[j] = hi
        if gain_of(units, probe, weights) < bar:
            continue
        while hi - lo > 1:
            mid = (lo + hi) // 2
            probe[j] = mid
            if gain_of(units, probe, weights) >= bar:
                hi = mid
            else:
                lo = mid
        pair = []
        for v in (lo, hi):
            probe = list(new_units)
            probe[j] = v
            pair.append(dict(kind="boundary", elapsed=elapsed, supply=supply, scale=WAD, units=units, newUnits=probe,
                             weights=weights, keepMask=0))
        return pair


def with_outcome(v):
    r = settle(v["elapsed"], v["supply"], v["scale"], v["units"], v["newUnits"], v["weights"], v["keepMask"])
    v = dict(v)
    v["outcome"] = r[0]
    v["bar"] = r[1] if r[0] == SETTLES else (r[2] if r[0] == BELOW else 0)
    # A gain is signed: the test reads it as an int256.
    v["gain"] = r[2] if r[0] == SETTLES else (r[1] if r[0] == BELOW else 0)
    v["amountsOut"] = r[3] if r[0] == SETTLES else []
    v["amountsIn"] = r[4] if r[0] == SETTLES else []
    v["badLeg"] = r[1] if r[0] == BOUNDS else 0
    v["badUnits"] = r[2] if r[0] == BOUNDS else (r[1] if r[0] == OVERFLOW else 0)
    v["lowest"] = r[3] if r[0] == BOUNDS else 0
    v["highest"] = r[4] if r[0] == BOUNDS else 0
    return v


def main():
    rng = random.Random(SEED)
    plan = [("trade", 110), ("wide", 40), ("gift", 20), ("caps", 40), ("tiny", 30), ("kept", 40), ("dust", 15),
            ("scaled", 30), ("huge", 15), ("clock", 40), ("length", 6)]
    vectors = [with_outcome(make(rng, kind)) for kind, count in plan for _ in range(count)]
    for _ in range(20):
        vectors.extend(with_outcome(v) for v in boundary(rng))
    counts = dict(
        settles=sum(v["outcome"] == SETTLES for v in vectors),
        empty=sum(v["outcome"] == EMPTY for v in vectors),
        bounds=sum(v["outcome"] == BOUNDS for v in vectors),
        overflow=sum(v["outcome"] == OVERFLOW for v in vectors),
        below=sum(v["outcome"] == BELOW for v in vectors),
        length=sum(v["outcome"] == LENGTH for v in vectors),
        elapsed=sum(v["outcome"] == ELAPSED for v in vectors),
        negativeGain=sum(v["outcome"] == BELOW and v["gain"] < 0 for v in vectors),
        kept=sum(v["keepMask"] != 0 for v in vectors),
        scaled=sum(v["scale"] != WAD for v in vectors),
        onTheBar=sum(v["outcome"] == SETTLES and v["gain"] == v["bar"] for v in vectors),
        turnoverBound=sum(v["outcome"] == SETTLES and any(
            v2 == bounds(u, 0)[0] and v2 < u for u, v2 in zip(v["units"], v["newUnits"])) for v in vectors),
        growthBound=sum(v["outcome"] == SETTLES and any(
            v2 == bounds(u, 0)[1] for u, v2 in zip(v["units"], v["newUnits"])) for v in vectors),
    )
    by_kind = {}
    for v in vectors:
        by_kind.setdefault(v["kind"], [0] * 7)[v["outcome"]] += 1
    import sys
    print({k: tuple(c) for k, c in by_kind.items()}, file=sys.stderr)
    print(counts, file=sys.stderr)
    assert counts["settles"] >= 150 and counts["below"] >= 60 and counts["bounds"] >= 40, counts
    assert counts["overflow"] >= 10 and counts["empty"] >= 3 and counts["length"] >= 4 and counts["elapsed"] >= 5, counts
    assert counts["kept"] >= 30 and counts["scaled"] >= 20 and counts["negativeGain"] >= 10, counts
    assert counts["turnoverBound"] >= 10 and counts["growthBound"] >= 10, counts
    out = dict(seed=SEED, count=len(vectors), counts=counts, vectors=vectors)
    print(json.dumps(out, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
