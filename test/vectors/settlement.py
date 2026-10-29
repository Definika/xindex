#!/usr/bin/env python3
"""The exact model of a weighted settlement, and the vectors `test/WeightedMath.vectors.t.sol` replays.

The model is written from the spec (`design/2026-10-05-custom-weights.md`, section 5, steps 4 to 7, and the rounding
rules of `design/2026-10-29-settlement-vectors.md`), in exact rationals, not from `src/WeightedMath.sol`: it never
chains a `mulDiv`, it rounds each quantity once, where the spec says to. The test compares the contract's answer with
the model's, word for word, on every vector.

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
MU_MAX = 1_020_000_000_000_000_000
MU_MIN = 980_000_000_000_000_000
MAX_TURNOVER = 200_000_000_000_000_000  # 20% of a shrinking leg's own units
MAX_GROWTH = WAD  # 100% of a growing leg's own units, before mu
MIN_TRADE = 1_000_000_000_000_000  # 0.1% of the moving value
TOTAL_WEIGHT = 10_000
UINT96_MAX = 2**96 - 1
MIN_RAW_UNITS = 10**4
MAX_UNITS = UINT96_MAX >> 10  # the factory's bound at creation; a fill may grow a leg up to UINT96_MAX
MAX_PRICE = 10**45
SEED = 20261029

SETTLES, NOTHING, OVERFLOW = 0, 1, 2


def floor(x):
    return math.floor(Fraction(x))


def ceil(x):
    return math.ceil(Fraction(x))


def trade_terms(value, prices, units, targets, moving):
    """Step 5: the share every leg moves, the capped release and the minimum trade, as exact fractions.

    Every leg moves the same share of the way, at most all of it, so that no shrinking leg gives up more than
    MAX_TURNOVER of its own units and no growing leg takes in more than MAX_GROWTH of its own, each bound rounded down
    at 1e18 (the spec's ⌊MAX_TURNOVER · u / (u − t)⌋). The release is what the shrinking legs give up at that share,
    in value; the minimum is MIN_TRADE of the moving value.
    """
    share = WAD
    released = 0
    for i in moving:
        u, t = units[i], targets[i]
        if t > u:
            share = min(share, floor(Fraction(u * MAX_GROWTH, t - u)))
        elif t < u:
            released += (u - t) * prices[i]
            share = min(share, floor(Fraction(u * MAX_TURNOVER, u - t)))
    return share, Fraction(released * share, WAD), Fraction(value * MIN_TRADE, WAD)


def settle(mu, prices, supply, scale, units, weights, keep):
    """The settlement at `mu`: (muUsed, units after, amounts out, amounts in), or a revert.

    Returns (SETTLES, muUsed, units, out, in), (NOTHING,) or (OVERFLOW, value): the first new units above uint96.
    """
    n = len(units)
    moving = [i for i in range(n) if not (keep >> i) & 1]
    value = sum(units[i] * prices[i] for i in moving)
    weight = sum(weights[i] for i in moving)

    # Step 4: a moving leg's target is w · V / (W · p), rounded up; a kept leg's is its current units.
    targets = list(units)
    for i in moving:
        targets[i] = ceil(Fraction(weights[i] * value, weight * prices[i]))

    share, release, minimum = trade_terms(value, prices, units, targets, moving)
    # The release the fill makes, after the cap, must be worth MIN_TRADE of the moving value: the release rounds down
    # and the minimum up, both against the fill.
    if floor(release) < ceil(minimum):
        return (NOTHING,)

    def step(mu_):
        # Step 6: a shrinking leg moves ⌊s · (u − t)⌋, a growing leg ⌈(μ · s) · (t − u)⌉ with μ · s rounded up.
        growth = ceil(Fraction(mu_ * share, WAD))
        after = []
        for i in range(n):
            u, t = units[i], targets[i]
            if t < u:
                after.append(u - floor(Fraction((u - t) * share, WAD)))
            elif t > u:
                grown = u + ceil(Fraction((t - u) * growth, WAD))
                if grown > UINT96_MAX:
                    return (OVERFLOW, grown)
                after.append(grown)
            else:
                after.append(u)
        # Step 7: each amount is the leg's change in backing, shares · Δunits · scale / 1e36, rounded down when it
        # leaves and up when it comes back.
        out = [floor(Fraction(supply * (u - a) * scale, UNIT_SCALE)) if a < u else 0 for u, a in zip(units, after)]
        inn = [ceil(Fraction(supply * (a - u) * scale, UNIT_SCALE)) if a > u else 0 for u, a in zip(units, after)]
        return (SETTLES, mu_, after, out, inn)

    result = step(mu)
    # A fill that would send nothing out settles at MU_MAX: nobody is paid for an empty or dust index.
    if result[0] == SETTLES and mu != MU_MAX and not any(result[3]):
        result = step(MU_MAX)
    return result


# ---------------------------------------------------------------------------------------------------------------------
# The generator
# ---------------------------------------------------------------------------------------------------------------------


def log_uniform(rng, lo, hi):
    """An integer whose magnitude is uniform between `lo` and `hi`, exclusive of `hi`."""
    return int(math.exp(rng.uniform(math.log(lo), math.log(hi))))


def partition(rng, n):
    cuts = sorted(rng.sample(range(1, TOTAL_WEIGHT), n - 1))
    parts = [b - a for a, b in zip([0] + cuts, cuts + [TOTAL_WEIGHT])]
    return parts


def on_weights(prices, weights, per_share):
    """Units on the weights at `prices`, for an index worth `per_share` (scaled by 1e36) per 1e18 shares."""
    return [max(MIN_RAW_UNITS, ceil(Fraction(w * per_share, TOTAL_WEIGHT * p))) for w, p in zip(weights, prices)]


def mask_leaving_two(rng, n):
    while True:
        mask = rng.randrange(1, 1 << n)
        if n - bin(mask).count("1") >= 2:
            return mask


def listed(rng, n):
    """Prices and a value per share within what the list holds, so units on the weights fit the factory's bounds:
    USD per raw unit scaled by 1e36 between 1e15 (a $1,000 coin with 18 decimals) and 1e30 (a $1 coin with 6), and
    an index worth $100 to $10,000 per whole token."""
    prices = [log_uniform(rng, 10**15, 10**30) for _ in range(n)]
    per_share = log_uniform(rng, 10**38, 10**40)
    return prices, per_share


def make(rng, kind):
    n = rng.choice([2, 2, 3, 3, 3, 4, 5, 6, 8, 12])
    weights = partition(rng, n)
    prices, per_share = listed(rng, n)
    units = on_weights(prices, weights, per_share)
    supply = log_uniform(rng, 10**15, 10**30)
    scale = WAD
    mu = rng.randrange(MU_MIN, MU_MAX + 1)
    keep = 0

    if kind == "random":
        # Any units and any price the hub accepts, most of them far from the weights: a leg that must grow past
        # 1e18 times its units makes the share zero and the fill NothingToRebalance (V5-L3, a known limitation).
        prices = [log_uniform(rng, 10**12, MAX_PRICE) for _ in range(n)]
        units = [log_uniform(rng, MIN_RAW_UNITS, MAX_UNITS) for _ in range(n)]
    elif kind == "near":
        for i in rng.sample(range(n), max(1, n // 2)):
            units[i] = ceil(units[i] * Fraction(rng.randrange(990, 1011), 1000))
    elif kind == "far":
        for i in range(n):
            units[i] = ceil(units[i] * Fraction(rng.randrange(30, 301), 100))
    elif kind == "collapsed":
        # One leg's price falls to a fiftieth or less: the growth cap, not the turnover cap, bounds the fill (RX-15).
        # A fall past 1e18 times its units would make the share zero and stall the fill (V5-L3).
        prices[rng.randrange(n)] //= rng.randrange(2, 51)
    elif kind == "flat":
        pass  # on the weights: nothing to rebalance, or a release under MIN_TRADE from the rounding of the targets
    elif kind == "kept":
        keep = mask_leaving_two(rng, n) if n > 2 else 0
        for i in range(n):
            units[i] = ceil(units[i] * Fraction(rng.randrange(50, 201), 100))
    elif kind == "dust":
        # A supply so small that every amount out rounds to zero, so the fill settles at MU_MAX.
        supply = rng.randrange(0, 3)
        for i in range(n):
            units[i] = ceil(units[i] * Fraction(rng.randrange(50, 201), 100))
    elif kind == "scaled":
        scale = log_uniform(rng, 10**10, WAD)
        for i in range(n):
            units[i] = ceil(units[i] * Fraction(rng.randrange(50, 201), 100))
    elif kind == "huge":
        # A growing leg near the 96-bit ceiling: the step overflows, and the fill must say so (RX-61). The leg is
        # priced so that its target is well above its units while the other legs hold most of the value.
        i = rng.randrange(n)
        weights[i] = rng.randrange(2000, 5001)
        rest = partition(rng, n - 1) if n > 2 else [TOTAL_WEIGHT - weights[i]]
        scale_rest = Fraction(TOTAL_WEIGHT - weights[i], TOTAL_WEIGHT)
        others = [max(1, floor(r * scale_rest)) for r in rest]
        others[-1] += TOTAL_WEIGHT - weights[i] - sum(others)
        weights = others[:i] + [weights[i]] + others[i:]
        units = on_weights(prices, weights, per_share)
        units[i] = rng.randrange((UINT96_MAX * 9) // 10, UINT96_MAX + 1)
        value_others = sum(u * p for k, (u, p) in enumerate(zip(units, prices)) if k != i)
        prices[i] = max(1, floor(Fraction(weights[i] * value_others, 2 * units[i] * (12 * TOTAL_WEIGHT // 10 - weights[i]))))
    elif kind == "edges":
        mu = rng.choice([MU_MIN, WAD, MU_MAX])
        supply = rng.choice([1, 10**18, 10**30])
        for i in range(n):
            units[i] = ceil(units[i] * Fraction(rng.randrange(50, 201), 100))
    else:
        raise ValueError(kind)
    units = [min(max(u, 1), UINT96_MAX) for u in units]
    return dict(kind=kind, mu=mu, prices=prices, supply=supply, scale=scale, units=units, weights=weights, keepMask=keep)


def boundary(rng):
    """Two vectors a raw unit apart, on either side of the minimum trade, found by bisection on one leg's units."""
    while True:
        n = rng.choice([2, 3, 4])
        weights = partition(rng, n)
        prices, per_share = listed(rng, n)
        units = on_weights(prices, weights, per_share)
        supply = log_uniform(rng, 10**15, 10**30)
        mu = rng.randrange(MU_MIN, MU_MAX + 1)
        j = rng.randrange(n)
        base = settle(mu, prices, supply, WAD, units, weights, 0)
        lo, hi = 0, units[j]  # at lo: on the weights; at hi: twice the units, which trades
        if base[0] != NOTHING:
            continue
        probe = list(units)
        probe[j] = units[j] + hi
        if settle(mu, prices, supply, WAD, probe, weights, 0)[0] != SETTLES:
            continue
        while hi - lo > 1:
            mid = (lo + hi) // 2
            probe[j] = units[j] + mid
            if settle(mu, prices, supply, WAD, probe, weights, 0)[0] == NOTHING:
                lo = mid
            else:
                hi = mid
        pair = []
        for delta in (lo, hi):
            probe = list(units)
            probe[j] = units[j] + delta
            pair.append(dict(kind="boundary", mu=mu, prices=prices, supply=supply, scale=WAD, units=probe,
                             weights=weights, keepMask=0))
        return pair


def quantum(rng, flavour):
    """Three legs priced at one quantum of value each, so the release and the minimum are small numbers and the
    roundings of the minimum-trade check decide the outcome. `release`: the release floors to one below the minimum's
    ceiling, so rounding the release up would let the fill through. `minimum`: the minimum is fractional and its floor
    equals the release's floor, so rounding the minimum down would. No listed price gets within a quantum of the
    minimum, so these are the one way to observe the two roundings."""
    while True:
        weights = partition(rng, 3)
        j = rng.randrange(3)
        weights[j] = rng.randrange(20, 41)
        rest = TOTAL_WEIGHT - weights[j]
        k = (j + 1) % 3
        weights[k] = rng.randrange(1, rest)
        weights[3 - j - k] = rest - weights[k]
        prices = [1, 1, 1]
        per_share = rng.randrange(10**5, 10**6)
        units = [ceil(Fraction(w * per_share, TOTAL_WEIGHT)) for w in weights]
        units[j] = ceil(units[j] * Fraction(rng.randrange(125, 251), 100))
        value = sum(units)
        targets = [ceil(Fraction(w * value, TOTAL_WEIGHT)) for w in weights]
        _, release, minimum = trade_terms(value, prices, units, targets, [0, 1, 2])
        refused = floor(release) < ceil(minimum)
        if not refused:
            continue
        if flavour == "release" and ceil(release) >= ceil(minimum):
            break
        if flavour == "minimum" and minimum.denominator != 1 and floor(release) >= floor(minimum):
            break
    return dict(kind="quantum-" + flavour, mu=rng.randrange(MU_MIN, MU_MAX + 1), prices=prices,
                supply=log_uniform(rng, 10**15, 10**30), scale=WAD, units=units, weights=weights, keepMask=0)


def with_outcome(v):
    r = settle(v["mu"], v["prices"], v["supply"], v["scale"], v["units"], v["weights"], v["keepMask"])
    v = dict(v)
    v["outcome"] = r[0]
    v["muUsed"] = r[1] if r[0] == SETTLES else 0
    v["unitsAfter"] = r[2] if r[0] == SETTLES else []
    v["amountsOut"] = r[3] if r[0] == SETTLES else []
    v["amountsIn"] = r[4] if r[0] == SETTLES else []
    v["overflowValue"] = r[1] if r[0] == OVERFLOW else 0
    return v


def main():
    rng = random.Random(SEED)
    plan = [("random", 20), ("near", 70), ("far", 60), ("collapsed", 30), ("flat", 20), ("kept", 40), ("dust", 20),
            ("scaled", 30), ("huge", 15), ("edges", 30)]
    vectors = [with_outcome(make(rng, kind)) for kind, count in plan for _ in range(count)]
    for _ in range(15):
        vectors.extend(with_outcome(v) for v in boundary(rng))
    for flavour in ("release", "minimum"):
        vectors.extend(with_outcome(quantum(rng, flavour)) for _ in range(5))
    counts = dict(
        settles=sum(v["outcome"] == SETTLES for v in vectors),
        nothing=sum(v["outcome"] == NOTHING for v in vectors),
        overflow=sum(v["outcome"] == OVERFLOW for v in vectors),
        redoneAtMuMax=sum(v["outcome"] == SETTLES and v["muUsed"] != v["mu"] for v in vectors),
        kept=sum(v["keepMask"] != 0 for v in vectors),
        scaled=sum(v["scale"] != WAD for v in vectors),
        emptySupply=sum(v["supply"] == 0 for v in vectors),
        turnoverBound=sum(v["outcome"] == SETTLES and any(
            (u - a) * 10_000 >= u * 1_999 for u, a in zip(v["units"], v["unitsAfter"])) for v in vectors),
    )
    by_kind = {}
    for v in vectors:
        by_kind.setdefault(v["kind"], [0, 0, 0])[v["outcome"]] += 1
    import sys
    print({k: tuple(c) for k, c in by_kind.items()}, file=sys.stderr)
    assert counts["settles"] >= 250 and counts["nothing"] >= 30 and counts["overflow"] >= 10, counts
    assert counts["redoneAtMuMax"] >= 10 and counts["kept"] >= 30 and counts["scaled"] >= 20, counts
    out = dict(seed=SEED, count=len(vectors), counts=counts, vectors=vectors)
    print(json.dumps(out, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
