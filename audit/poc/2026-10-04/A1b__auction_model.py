#!/usr/bin/env python3
"""Exact-integer model of IndexHub's band, lambda and settlement (src/IndexHub.sol at 6149aab)."""
import random
from fractions import Fraction as F

WAD = 10**18
STEP = 5 * 10**15
MIN_BAND = 10**15
D = 86400
U96 = 2**96 - 1
MAX_UNITS = U96 >> 10
MAX_SUPPLY = 2**128 - 1
MIN_RAW = 10**4


def muldiv(a, b, c, up=False):
    if c == 0:
        raise ZeroDivisionError
    q, r = divmod(a * b, c)
    if up and r:
        q += 1
    if q >= 2**256:
        raise OverflowError("mulDiv overflow")
    return q


def band(units, supplies, keep):
    n = len(units)
    rel = [0] * n
    low, high = 2**256 - 1, 0
    au = asup = 0
    for i in range(n):
        if keep >> i & 1:
            continue
        u = units[i]
        if au == 0:
            au, asup = u, supplies[i]
        r = muldiv(u * asup, WAD, supplies[i] * au)
        rel[i] = r
        low = min(low, r)
        high = max(high, r)
    centre = (low + high) // 2
    lmin, lmax = 2**256 - 1, 0
    ratios = [0] * n
    for i in range(n):
        if keep >> i & 1:
            continue
        r = muldiv(rel[i], WAD, centre)
        r = max(WAD - STEP, min(WAD + STEP, r))
        ratios[i] = r
        lmin = min(lmin, r)
        lmax = max(lmax, r)
    return ratios, lmin, lmax


def too_narrow(lmin, lmax):
    return lmax * WAD < lmin * (WAD + MIN_BAND)


def lam(lmax, lmin, dt):
    return lmax - muldiv(lmax - lmin, dt, D)


def settlement_at(lmbda, S, units, ratios, keep):
    n = len(units)
    nu, out, inn = [0] * n, [0] * n, [0] * n
    sells = False
    for i in range(n):
        cur = units[i]
        if keep >> i & 1:
            nu[i] = cur
            continue
        nxt = muldiv(lmbda, cur, ratios[i], up=True)
        nu[i] = nxt
        if nxt < cur:
            o = muldiv(S, cur - nxt, WAD)
            out[i] = o
            if o:
                sells = True
        else:
            inn[i] = muldiv(S, nxt - cur, WAD, up=True)
    return nu, out, inn, sells


def settle(lmbda, lmax, S, units, ratios, keep):
    nu, out, inn, sells = settlement_at(lmbda, S, units, ratios, keep)
    if not sells and lmbda != lmax:
        lmbda = lmax
        nu, out, inn, _ = settlement_at(lmbda, S, units, ratios, keep)
    for x in nu:
        if x > U96:
            raise OverflowError("toUint96")
    return lmbda, nu, out, inn


def check_bound(units, nu, ratios, keep, lmin, lmax, prices):
    v = sum(F(units[i]) * prices[i] for i in range(len(units)) if not keep >> i & 1)
    v2 = sum(F(nu[i]) * prices[i] for i in range(len(units)) if not keep >> i & 1)
    if v == 0:
        return True
    return v2 / v >= F(lmin, lmax)


def run_random(trials=20000, seed=1):
    rng = random.Random(seed)
    fails = 0
    narrow = 0
    for t in range(trials):
        n = rng.randint(2, 8)
        # supplies over a wide range; units within [MIN_RAW, MAX_UNITS] from a common k
        sup = [rng.choice([rng.randint(1, 10**6), rng.randint(1, 10**30), rng.randint(1, MAX_SUPPLY)]) for _ in range(n)]
        # pick k so that every unit lands in range if possible
        lo = max(-(-MIN_RAW * 10**36 // s) for s in sup)
        hi = min(MAX_UNITS * 10**36 // s for s in sup)
        if lo > hi:
            continue
        k = rng.randint(lo, hi) if rng.random() < 0.5 else rng.choice([lo, hi])
        units = [k * s // 10**36 for s in sup]
        # apply several batches of +-STEP steps
        for _ in range(rng.randint(1, 30)):
            for i in range(n):
                if rng.random() < 0.6:
                    a = sup[i] * STEP // WAD
                    sup[i] = max(1, min(MAX_SUPPLY, sup[i] + rng.randint(-a, a)))
        keep = 0
        if n > 2 and rng.random() < 0.3:
            keep = rng.randint(1, (1 << n) - 2)
        ratios, lmin, lmax = band(units, sup, keep)
        if too_narrow(lmin, lmax):
            narrow += 1
            continue
        S = rng.choice([0, 1, rng.randint(1, 10**18), rng.randint(1, 10**30)])
        dt = rng.randint(0, D)
        l = lam(lmax, lmin, dt)
        assert lmin <= l <= lmax
        lmbda, nu, out, inn = settle(l, lmax, S, units, ratios, keep)
        prices = [F(rng.randint(1, 10**12), rng.randint(1, 10**12)) for _ in range(n)]
        if not check_bound(units, nu, ratios, keep, lmin, lmax, prices):
            fails += 1
            print("BOUND FAIL", units, nu, ratios, lmin, lmax)
        # honest executor: balances start at exactly the invariant, claims 0
        held = [S * u // WAD for u in units]
        for i in range(n):
            if out[i] == 0 and inn[i] == 0:
                continue
            req = S * nu[i] // WAD
            bal = held[i] - out[i] + inn[i]
            if bal < req:
                fails += 1
                print("BACKING FAIL", i, bal, req)
        # an executor delivering nothing can only settle when nothing is asked
        # executor value take bounded by band
        if S > 0:
            take = sum(F(out[i]) * prices[i] for i in range(n)) - sum(F(inn[i]) * prices[i] for i in range(n))
            mv = sum(F(S * units[i], WAD) * prices[i] for i in range(n) if not keep >> i & 1)
            if mv > 0 and take > mv * (1 - F(lmin, lmax)):
                fails += 1
                print("TAKE FAIL", take / mv)
    print("random trials done; fails", fails, "narrow", narrow)


if __name__ == "__main__":
    run_random()
