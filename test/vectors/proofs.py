#!/usr/bin/env python3
"""Proofs of the settlement model's properties in z3, over unbounded integers, for two and three legs.

The model is `settlement.py`'s, step for step: targets rounded up, the share bounded by the turnover and growth caps,
the growth factor rounded up, a shrinking step rounded down and a growing one up. Every floor and ceiling is a fresh
integer pinned by two inequalities, so no property depends on how a division is computed. Each statement is asserted
negated, with the lemmas it names assumed (DEPENDS), each proven before it, so the whole is a proof tree; `unsat` is a proof for every integer the assumptions allow, `sat` prints a counterexample, `unknown` means
the solver gave up within its budget. `test/WeightedMath.vectors.t.sol` ties the model to the contract.

On 2026-10-29 every statement was proven for two legs, and for three legs all but L12 and P4, which depend on it:
`design/2026-10-29-settlement-proofs.md` has the table and the one hand step left.

Run with a Python that has z3 (Halmos's does):

    python3 -I test/vectors/proofs.py [legs] [seconds per property] [statements]
"""
import sys
import time

from z3 import And, If, Implies, Int, Not, Or, Solver, sat, unknown, unsat

WAD = 10**18
MU_MAX = 1_020_000_000_000_000_000
MU_MIN = 980_000_000_000_000_000
MAX_TURNOVER = 200_000_000_000_000_000
MAX_GROWTH = WAD
MIN_TRADE = 1_000_000_000_000_000
TOTAL_WEIGHT = 10_000
UINT96_MAX = 2**96 - 1


def z_min(a, b):
    return If(a < b, a, b)


class Model:
    """The settlement for `n` legs, every quantity a z3 term and every rounding a pinned integer."""

    def __init__(self, n):
        self.s = Solver()
        self.n = n
        self.fresh = 0
        s = self.s
        self.u = [Int(f"u{i}") for i in range(n)]
        self.p = [Int(f"p{i}") for i in range(n)]
        self.w = [Int(f"w{i}") for i in range(n)]
        self.mu = Int("mu")
        for i in range(n):
            s.add(self.u[i] >= 1, self.u[i] <= UINT96_MAX, self.p[i] >= 1, self.w[i] >= 1)
        s.add(sum(self.w) == TOTAL_WEIGHT, self.mu >= MU_MIN, self.mu <= MU_MAX)

        self.value = sum(self.u[i] * self.p[i] for i in range(n))
        # targets round up
        self.t = [self.ceil_div(self.w[i] * self.value, TOTAL_WEIGHT * self.p[i], f"t{i}") for i in range(n)]
        # the share: 1e18 lowered to each leg's bound, rounded down
        share = WAD
        for i in range(n):
            grow = self.floor_div(self.u[i] * MAX_GROWTH, self.t[i] - self.u[i], f"g{i}", self.t[i] > self.u[i])
            shrink = self.floor_div(self.u[i] * MAX_TURNOVER, self.u[i] - self.t[i], f"l{i}", self.t[i] < self.u[i])
            share = If(self.t[i] > self.u[i], z_min(share, grow), If(self.t[i] < self.u[i], z_min(share, shrink), share))
        self.share = Int("share")
        s.add(self.share == share)
        self.released = sum(If(self.t[i] < self.u[i], (self.u[i] - self.t[i]) * self.p[i], 0) for i in range(n))
        # the fill proceeds: the capped release is worth the minimum
        self.release = self.floor_div(self.released * self.share, WAD, "release")
        self.minimum = self.ceil_div(self.value * MIN_TRADE, WAD, "minimum")
        s.add(self.release >= self.minimum)
        # the steps
        self.growth = self.ceil_div(self.mu * self.share, WAD, "growth")
        # mu times the share as one unknown, so the sum lemmas multiply by a single term; pinned only for the
        # statements that use it (USES_K), since an extra product slows the solver on the others
        self.k = Int("k")
        self.after = []
        for i in range(n):
            down = self.u[i] - self.floor_div((self.u[i] - self.t[i]) * self.share, WAD, f"down{i}", self.t[i] < self.u[i])
            up = self.u[i] + self.ceil_div((self.t[i] - self.u[i]) * self.growth, WAD, f"up{i}", self.t[i] > self.u[i])
            a = Int(f"after{i}")
            s.add(a == If(self.t[i] < self.u[i], down, If(self.t[i] > self.u[i], up, self.u[i])))
            s.add(a <= UINT96_MAX)  # the contract reverts past 96 bits; the properties are of a settlement that returns
            self.after.append(a)

    def floor_div(self, a, b, name, when=True):
        q = Int(name)
        self.s.add(Implies(when, And(q * b <= a, a < (q + 1) * b)))
        return q

    def ceil_div(self, a, b, name, when=True):
        q = Int(name)
        self.s.add(Implies(when, And((q - 1) * b < a, a <= q * b)))
        return q


# What each statement assumes: the lemmas it is closed from, proven before it.
DEPENDS = {
    "L0": [], "L1": [], "L2": [], "L3": [], "L4": [], "L5": [], "L6": ["L0"], "L7": ["L1"], "L8": ["L2"], "L9": ["L3"],
    "L10": ["L8"], "L11": ["L9"], "L12": ["L7"],
    "P1": [], "P2": [], "P3": ["L4", "L5", "L6"], "P4": ["L10", "L11", "L12"], "P5": [], "P6": [],
}
USES_K = {"L8", "L9", "L10", "L11", "L12", "P4"}
# Statements the solver closes only one sign pattern at a time: which legs grow, shrink or stay. The patterns
# partition the space, so a statement unsat under each of them is proven.
SPLIT = {"L12", "P4"}


def lemmas(m):
    """Steps a solver can take one at a time, each a pinned rounding multiplied through by a positive term. Every
    lemma is proven from the model on its own before any property assumes it."""
    n = m.n
    shrinks = [m.t[i] < m.u[i] for i in range(n)]
    grows = [m.t[i] > m.u[i] for i in range(n)]
    yield "L0 the release is at most the moving value", m.released <= m.value
    yield "L1 the targets are worth at least the moving value (they round up)", (
        sum(m.t[i] * m.p[i] for i in range(n)) >= m.value)
    yield "L2 a growing step is at least mu times the share of its gap", And(
        *[Implies(grows[i], (m.after[i] - m.u[i]) * WAD * WAD >= (m.t[i] - m.u[i]) * m.mu * m.share) for i in range(n)])
    yield "L3 a shrinking step is at most the share of its gap", And(
        *[Implies(shrinks[i], (m.u[i] - m.after[i]) * WAD <= (m.u[i] - m.t[i]) * m.share) for i in range(n)])
    yield "L4 the share times a growing gap is at most the leg's units", And(
        *[Implies(grows[i], m.share * (m.t[i] - m.u[i]) <= m.u[i] * MAX_GROWTH) for i in range(n)])
    yield "L5 a growing step is under mu times the share of its gap, plus the gap, plus one", And(
        *[Implies(grows[i], (m.after[i] - m.u[i]) * WAD * WAD
                  < (m.t[i] - m.u[i]) * m.mu * m.share + (m.t[i] - m.u[i]) * WAD + WAD * WAD) for i in range(n)])
    yield "L6 a fill that proceeds moves at least MIN_TRADE of the way (the release is at most the value)", (
        m.share >= MIN_TRADE)
    # The mu bound, one multiplication at a time. Every sum below is a sum of the per-leg terms the lemma before it
    # bounds, so the step from one to the next is linear in those terms; k is mu times the share.
    grow_gaps = [If(grows[i], (m.t[i] - m.u[i]) * m.p[i], 0) for i in range(n)]
    shrink_gaps = [If(shrinks[i], (m.u[i] - m.t[i]) * m.p[i], 0) for i in range(n)]
    grow_gaps_k = [If(grows[i], (m.t[i] - m.u[i]) * m.p[i] * m.k, 0) for i in range(n)]
    shrink_gaps_k = [If(shrinks[i], (m.u[i] - m.t[i]) * m.p[i] * m.k, 0) for i in range(n)]
    grow_steps = [If(grows[i], (m.after[i] - m.u[i]) * m.p[i] * WAD * WAD, 0) for i in range(n)]
    shrink_steps_mu = [If(shrinks[i], (m.u[i] - m.after[i]) * m.p[i] * WAD * m.mu, 0) for i in range(n)]
    yield "L7 the growing gaps are worth at least the shrinking gaps (from L1)", sum(grow_gaps) >= sum(shrink_gaps)
    yield "L8 each growing step, priced, is at least k times its priced gap (from L2)", And(
        *[Implies(grows[i], grow_steps[i] >= grow_gaps_k[i]) for i in range(n)])
    yield "L9 each shrinking step, priced and times mu, is at most k times its priced gap (from L3)", And(
        *[Implies(shrinks[i], shrink_steps_mu[i] <= shrink_gaps_k[i]) for i in range(n)])
    yield "L10 the priced growing steps sum to at least k times the priced growing gaps (from L8)", (
        sum(grow_steps) >= sum(grow_gaps_k))
    yield "L11 the priced shrinking steps times mu sum to at most k times the priced shrinking gaps (from L9)", (
        sum(shrink_steps_mu) <= sum(shrink_gaps_k))
    yield "L12 k carries L7", sum(grow_gaps_k) >= sum(shrink_gaps_k)


def properties(m):
    n = m.n
    shrinks = [m.t[i] < m.u[i] for i in range(n)]
    grows = [m.t[i] > m.u[i] for i in range(n)]
    yield "P1 a shrinking leg gives up at most MAX_TURNOVER of its units", And(
        *[Implies(shrinks[i], (m.u[i] - m.after[i]) * WAD <= m.u[i] * MAX_TURNOVER) for i in range(n)])
    yield "P2 a shrinking leg never passes its target", And(*[Implies(shrinks[i], m.after[i] >= m.t[i]) for i in range(n)])
    # The slack is the growth factor's rounding: at most (t - u) / 1e18, which is at most u / share raw units (L4).
    # A fill that proceeds has a share of at least MIN_TRADE (L6), so the slack is at most a quadrillionth of the
    # leg: MAX_GROWTH / MIN_TRADE = 1000 per 1e18.
    yield "P3 a growing leg adds at most mu times MAX_GROWTH of its units, plus a quadrillionth of them, plus one", And(
        *[Implies(grows[i], (m.after[i] - m.u[i]) * WAD
                  <= m.u[i] * m.mu * (MAX_GROWTH // WAD) + m.u[i] * (MAX_GROWTH * 1000 // WAD) + WAD) for i in range(n)])
    yield "P4 at the settling prices what comes in is worth at least mu times what leaves", (
        sum(If(grows[i], (m.after[i] - m.u[i]) * m.p[i], 0) for i in range(n)) * WAD
        >= m.mu * sum(If(shrinks[i], (m.u[i] - m.after[i]) * m.p[i], 0) for i in range(n)))
    yield "P5 a leg on its target does not move", And(*[Implies(m.t[i] == m.u[i], m.after[i] == m.u[i]) for i in range(n)])
    yield "P6 something moves", Or(*[m.after[i] != m.u[i] for i in range(n)])


def check_seeds(s, budget):
    """Checks `s` under up to three random seeds: z3's search is sensitive to term order, and a statement it cannot
    close in one order it often closes in another."""
    for seed in range(3):
        s.set("timeout", budget * 1000)
        s.set("random_seed", seed)
        r = s.check()
        if r != unknown:
            return r
    return unknown


def check_split(m, budget):
    """Checks `m` once per sign pattern of the legs (each growing, shrinking or on its target), the pattern asserted.
    The result is unsat only if every pattern is; a pattern that is sat or unknown decides the whole."""
    import itertools
    for pattern in itertools.product((-1, 0, 1), repeat=m.n):
        m.s.push()
        for i, sign in enumerate(pattern):
            m.s.add(m.t[i] > m.u[i] if sign > 0 else m.t[i] < m.u[i] if sign < 0 else m.t[i] == m.u[i])
        r = check_seeds(m.s, budget)
        m.s.pop()
        if r != unsat:
            return r
    return unsat


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    budget = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    # an optional third argument names the statements to run, comma-separated, e.g. L1,L7,L12,P4; the rest are
    # assumed proven, so use it only to repeat statements a full run proved
    only = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else None
    proven = set()
    for group in (lemmas, properties):
        for name in [name for name, _ in group(Model(n))]:
            m = Model(n)
            # a statement assumes the lemmas it names, each proven before it, so the order is a proof tree; assuming
            # more than it needs only slows the solver, and an unproven dependency leaves it unproven too
            needed = DEPENDS[name.split()[0]]
            if only is not None and name.split()[0] not in only:
                proven.add(name.split()[0])
                continue
            if any(d not in proven for d in needed):
                print(f"{n} legs | {name} | SKIPPED, a dependency is unproven | 0.0s", flush=True)
                continue
            if name.split()[0] in USES_K or any(d in USES_K for d in needed):
                m.s.add(m.k == m.mu * m.share)
            for lname, lemma in lemmas(m):
                if lname.split()[0] in needed:
                    m.s.add(lemma)
            for name2, prop2 in group(m):
                if name2 == name:
                    m.s.add(Not(prop2))
            start = time.time()
            r = check_split(m, budget) if name.split()[0] in SPLIT else check_seeds(m.s, budget)
            took = time.time() - start
            verdict = "PROVED" if r == unsat else "COUNTEREXAMPLE" if r == sat else "UNKNOWN"
            if r == unsat:
                proven.add(name.split()[0])
            print(f"{n} legs | {name} | {verdict} | {took:.1f}s", flush=True)
            if r == sat:
                mdl = m.s.model()
                names = ["mu"] + [f"{k}{i}" for k in ("u", "p", "w", "t", "after") for i in range(n)] + ["share", "growth"]
                print("   ", {k: mdl.eval(Int(k), model_completion=True) for k in names}, flush=True)


if __name__ == "__main__":
    main()
