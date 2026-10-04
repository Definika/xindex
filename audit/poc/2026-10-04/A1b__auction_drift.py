import random
from model import *
rng = random.Random(7)
# Two/three components, supplies FIXED (no batch ever again). Does a fill leave a band >= MIN_BAND from rounding alone?
for ub in [200, 500, 900, 1000, 1500, 3000, 10000]:
    reopen = 0; trials = 3000; cycles_total = 0
    for t in range(trials):
        fa = 10**27 + rng.randint(0, 10**26); fb = 21 * 10**14 + rng.randint(0, 10**13)  # 18-dec token, WBTC-like sats
        k = ub * 10**36 // fb
        ua = k * fa // 10**36; ubb = k * fb // 10**36
        units = [ua, ubb]
        # open a band once with a single 0.5% supply step on b, then freeze supplies
        sup = [fa, fb + fb * STEP // WAD]
        cycles = 0
        while cycles < 20:
            ratios, lmin, lmax = band(units, sup, 0)
            if too_narrow(lmin, lmax):
                break
            l = lam(lmax, lmin, rng.randint(0, D))
            S = 10**24
            _, units, _, _ = settle(l, lmax, S, units, ratios, 0)
            cycles += 1
        if cycles > 1: reopen += 1
        cycles_total += cycles
    print(f"units~{ub}: trials where the band reopened from rounding alone after the first fill: {reopen}/{trials}, mean fills {cycles_total/trials:.2f}")
