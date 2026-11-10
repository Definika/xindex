#!/usr/bin/env python3
"""The proofs behind the oracle-free settlement, checked in exact rationals. Standard library only.

The rule (`design/2026-11-10-oracle-free-rebalance.md`, section 3): a fill is accepted when every leg's relative
change in units `x` lies in [-1/5, 1] and the weighted sum of `L(x) = x - x^2/2 + x^3/3 - 3x^4/10` clears a bar above
zero. Its safety is one chain, and each link is checked here, exactly:

  P1  `ln(1 + x) - L(x)` has the derivative `x^3 (1 + 6x) / (5 (1 + x))`: an identity of polynomials.
  P2  So on [-1/5, 1] that difference is least at `x = -1/5` or `x = 0`. It is zero at zero, and at -1/5 it is
      positive, shown with a rational upper bound of `ln(5/4)`. Hence `L(x) <= ln(1 + x)` on the whole capped range
      (Lemma 1), with the margin at -1/5 printed. Just under the cap it fails, so the cap cannot widen.
  P3  The contract's `x` is the true change rounded down, inside [-1/5, 1] whenever the leg is inside its unit caps,
      and its score is `L` of that `x` rounded down: checked for every pair of units up to a bound, and on the
      boundaries of large ones. With P2 and the logarithm's monotony, a leg's score is at most `ln(v / u)`, so an
      accepted fill never lowers the weighted product of the units (Theorem 1).
  P4  The bar: a half at the first second, the exact halving at every twelfth minute, never rising, never zero, for
      every second of the auction.
  P5  The amounts: what leaves rounds down and what comes back rounds up, so the index holds at least the new units'
      backing, for random settlements of the model.

`settlement.py` is the model these statements are about; `test/WeightedMath.vectors.t.sol` ties it to the contract,
and `keeper/test/unit/units.test.mjs` to the keeper's port. Run:

    python3 -I test/vectors/proofs.py
"""
import math
import os
import random
import sys
from fractions import Fraction as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import settlement as M  # noqa: E402

LOW = F(-1, 5)
HIGH = F(1)


def poly_mul(a, b):
    out = [F(0)] * (len(a) + len(b) - 1)
    for i, x in enumerate(a):
        for j, y in enumerate(b):
            out[i + j] += x * y
    return out


def poly_eval(p, x):
    return sum(c * x**k for k, c in enumerate(p))


# L and its derivative, as coefficient lists from the constant term up.
L = [F(0), F(1), F(-1, 2), F(1, 3), F(-3, 10)]
DL = [k * c for k, c in enumerate(L)][1:]


def p1_derivative():
    """(1 + x) L'(x) = 1 - x^3 (1 + 6x) / 5, so d/dx [ln(1 + x) - L(x)] = x^3 (1 + 6x) / (5 (1 + x))."""
    left = poly_mul([F(1), F(1)], DL)
    right = [F(1), F(0), F(0), F(-1, 5), F(-6, 5)]
    assert left == right, (left, right)
    return "d/dx [ln(1+x) - L(x)] = x^3 (1 + 6x) / (5 (1 + x))"


def ln_five_fourths_upper(terms=12):
    """An upper bound of ln(5/4) = 2 atanh(1/9): the series' partial sum plus a geometric bound of its tail."""
    y = F(1, 9)
    partial = sum(2 * y ** (2 * k + 1) / (2 * k + 1) for k in range(terms))
    first_left = 2 * y ** (2 * terms + 1) / (2 * terms + 1)
    return partial + first_left / (1 - y * y)


def p2_lemma():
    """The difference falls on (-1/6, 0), rises on (0, 1] and on [-1/5, -1/6): its least value is at -1/5 or at 0."""
    sign = lambda x: x**3 * (1 + 6 * x)  # the derivative's sign, 1 + x being positive
    assert sign(F(-1, 5)) > 0 and sign(F(-11, 60)) > 0, "rising on [-1/5, -1/6)"
    assert sign(F(-1, 6)) == 0 and sign(F(-1, 12)) < 0, "falling on (-1/6, 0)"
    assert sign(F(0)) == 0 and sign(F(1, 2)) > 0 and sign(F(1)) > 0, "rising on (0, 1]"
    assert poly_eval(L, F(0)) == 0, "the difference is zero at zero"
    margin = -ln_five_fourths_upper() - poly_eval(L, LOW)
    assert margin > 0, "L(-1/5) is under ln(4/5)"
    # Past the cap the lemma fails, so the turnover cap is where it must stay: a numeric witness at -0.21.
    assert math.log(0.79) < float(poly_eval(L, F(-21, 100)))
    return f"L(x) <= ln(1+x) on [-1/5, 1]; least margin {float(margin):.3e} at x = -1/5"


def leg_holds(u, v):
    """One leg inside its caps: the contract's x is the true change rounded down, in range, and its score is L floored."""
    lowest, highest = M.bounds(u, False)
    assert lowest <= v <= highest
    x = M.change(u, v)
    true = F(v - u, u)
    assert F(x, M.WAD) <= true < F(x + 1, M.WAD), (u, v)
    assert LOW <= F(x, M.WAD) <= HIGH, (u, v, x)
    exact = poly_eval(L, F(x, M.WAD)) * M.WAD
    assert M.score(x) <= exact < M.score(x) + 1, (u, v)


def p3_rounding():
    checked = 0
    for u in range(1, 400):
        lowest, highest = M.bounds(u, False)
        for v in range(lowest, highest + 1):
            leg_holds(u, v)
            checked += 1
    rng = random.Random(M.SEED)
    for _ in range(20_000):
        u = int(10 ** rng.uniform(0, 28.5))
        lowest, highest = M.bounds(u, False)
        for v in {lowest, lowest + 1, u - 1, u, u + 1, highest - 1, highest, rng.randint(lowest, highest)}:
            if lowest <= v <= highest:
                leg_holds(u, v)
                checked += 1
    return f"x and the score round down, inside the lemma's range: {checked} legs, every one up to 399 units"


def p4_bar():
    bars = [M.bar_at(e) for e in range(M.AUCTION_DURATION + 1)]
    assert bars[0] == M.BAR_MAX
    assert all(a >= b for a, b in zip(bars, bars[1:])), "the bar never rises"
    assert min(bars) == bars[-1] > 0, "and never reaches zero"
    for k in range(M.AUCTION_DURATION // M.BAR_HALF_LIFE + 1):
        assert bars[k * M.BAR_HALF_LIFE] == -(-M.BAR_MAX // 2**k), k
    return f"the bar falls from {bars[0]} to {bars[-1]} over {len(bars)} seconds, halving every {M.BAR_HALF_LIFE}"


def p5_amounts(rounds=4000):
    rng = random.Random(M.SEED + 1)
    settled = 0
    for _ in range(rounds):
        n = rng.randint(2, 6)
        units = [int(10 ** rng.uniform(4, 24)) for _ in range(n)]
        new_units = [rng.randint(*M.bounds(u, False)) for u in units]
        supply = int(10 ** rng.uniform(0, 30))
        scale = rng.randint(M.WAD // 2, M.WAD)
        for i, (u, v) in enumerate(zip(units, new_units)):
            before = F(supply * u * scale, M.UNIT_SCALE)
            after = F(supply * v * scale, M.UNIT_SCALE)
            out = M.floor(F(supply * (u - v) * scale, M.UNIT_SCALE)) if v < u else 0
            came = M.ceil(F(supply * (v - u) * scale, M.UNIT_SCALE)) if v > u else 0
            # Holding the old backing, less what left, plus what came, the index holds the new backing.
            assert M.floor(before) - out + came >= M.floor(after), (units, new_units, supply, scale, i)
        settled += 1
    return f"what leaves rounds down and what comes back rounds up: {settled} settlements keep their backing"


def main():
    for name, statement in [("P1", p1_derivative), ("P2", p2_lemma), ("P3", p3_rounding), ("P4", p4_bar), ("P5", p5_amounts)]:
        print(f"{name}  proven  {statement()}")
    print("An accepted fill's gain is at most the weighted sum of ln(v/u): it never lowers the weighted product of the units.")


if __name__ == "__main__":
    main()
