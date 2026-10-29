# Proofs of the settlement arithmetic (2026-10-29)

Step 2 of the logic-hardening plan agreed on 2026-10-29. The plan named two tools: Halmos on `WeightedMath` (the `μ`
bound, the unit caps, the rounding directions, for four to eight legs) and Certora on the hub's backing invariant.
Certora needs paid access the project does not have and was not run. Halmos was run and could not finish the
narrowest case within its budget (section 2). The properties were then proven on the exact model of the settlement
(`test/vectors/settlement.py`, step 3's) in z3 over unbounded integers, every statement for two legs and all but
the `μ` bound's last step for three, each rounding pinned as an integer and each property reduced to lemmas the
solver closes, most in seconds (section 3). The contract is
unchanged.

What the chain proves, stated plainly: the model's properties hold for every integer within the hub's bounds, by
proof; the contract agrees with the model, by the 375-vector replay and the nineteen mutants of step 3, which is
evidence, not proof. A reader who wants the contract itself proven needs a symbolic tool that models `Math.mulDiv`,
or the hours section 2 did not have.

## 1. The files

- `test/vectors/proofs.py`: the model in z3 and the proofs. `python3 -I test/vectors/proofs.py 2 120` proves two legs
  with two minutes per property; `3 300` three legs. It needs a Python with the `z3` package; Halmos's has one
  (`~/.local/share/uv/tools/halmos/bin/python` on the machine that ran it), the system's does not.
- `test/WeightedMath.halmos.t.sol`: the Halmos harness, four rungs. forge compiles it and runs nothing in it, since
  its functions start with `check_`. It stays so the attempt can be repeated with more time or a later Halmos.

## 2. Halmos

Halmos 0.3.3, the bundled solvers (no `z3`, `yices` or `bitwuzla` on the machine's path). Two runs:

| Run | Symbolic | Options | Outcome |
|---|---|---|---|
| first | two 96-bit units, two 128-bit prices, the multiplier, one weight | defaults (`--solver-timeout-branching 1`), `--loop 3` | 24 minutes of path exploration at full CPU, no solver started, no output; killed |
| rung 1 | two 64-bit units; prices, weights and the multiplier fixed | `--solver-timeout-branching 3000`, `--width 100000`, `--loop 3` | timed out at the ten-minute cap, still exploring |

The cause is structural. The settlement makes about eleven `Math.mulDiv` calls, each a 512-bit multiplication with
two or three branches on symbolic values, and every call to `_backing`, every target, cap, step and the minimum
trade is one. Halmos follows every branch it cannot refute, and a branch query here is a nonlinear bit-vector
problem the default one-millisecond budget never answers; with three seconds it answers some, and the tree is still
thousands of paths before the first assertion is checked. Narrowing to 64-bit units at fixed prices did not change
that. Rungs 2 to 4 were not run.

## 3. The model in z3

`proofs.py` builds the settlement of `settlement.py` for `n` legs as z3 terms over unbounded integers: `u_i`, `p_i`,
`w_i`, `μ` are integer unknowns with the hub's bounds (`1 <= u_i <= 2^96 − 1`, `p_i >= 1`, `w_i >= 1` summing to
10,000, `MU_MIN <= μ <= MU_MAX`); every floor and ceiling is a fresh integer pinned by two inequalities
(`q · b <= a < (q + 1) · b`, or `(q − 1) · b < a <= q · b`), so no step depends on how a division is computed; the
share is the minimum of the bounds as an `If` chain; the new units are bounded by 96 bits, since the contract reverts
past them; and the fill proceeds, `⌊R · s / 1e18⌋ >= ⌈V · MIN_TRADE / 1e18⌉`. Nothing is kept: a kept leg is a
smaller settlement with the same proof.

Each statement is asserted negated with a time budget; `unsat` is a proof for every integer the assumptions allow.
The properties need the solver to combine several nonlinear facts, which z3 did not manage directly (P3 and P4 were
`unknown` after a minute), so each is reduced to lemmas that are proven first, from the model alone, and then
assumed:

| Lemma | Statement | 2 legs |
|---|---|---|
| L0 | the release is at most the moving value | proved, 0.0 s |
| L1 | the targets are worth at least the moving value: they round up | proved, 0.1 s |
| L2 | a growing step is at least `μ · s` times its gap | proved, 0.0 s |
| L3 | a shrinking step is at most `s` times its gap | proved, 0.0 s |
| L4 | `s` times a growing gap is at most the leg's units (the growth cap) | proved, 0.0 s |
| L5 | a growing step is under `μ · s` times its gap, plus the gap over 1e18, plus one | proved, 0.0 s |
| L6 | a fill that proceeds has `s >= MIN_TRADE`: the release is at most the value, so the minimum forces the share | proved, 0.0 s |

| Property | Statement | 2 legs |
|---|---|---|
| P1 | a shrinking leg gives up at most `MAX_TURNOVER` of its own units (V5-M2) | proved, 0.1 s |
| P2 | a shrinking leg never passes its target | proved, 0.1 s |
| P3 | a growing leg adds at most `μ · MAX_GROWTH` of its own units, plus a quadrillionth of them, plus one raw unit (RX-15; section 4) | proved, 0.1 s |
| P4 | at the settling prices, what comes in is worth at least `μ` times what leaves (R04, SA-07) | proved, 2.0 s |
| P5 | a leg on its target does not move | proved, 0.0 s |
| P6 | a fill that proceeds moves some leg | proved, 0.0 s |

For three legs, the same tree with four more lemmas for the `μ` bound (L7 to L12 below, `k = μ · s` pinned as
one unknown, every sum a sum of the per-leg terms the lemma before it bounds, so each step is linear in them):

| Statement | 3 legs |
|---|---|
| L0, L2, L3, L4, L5, L8, L10, L11, P2, P5, P6 | proved, each under a second |
| L1 the targets are worth at least the moving value | proved, 0.2 s (10.4 s in another run) |
| L6 a fill that proceeds has `s >= MIN_TRADE` | proved, 48.8 s (116.5 s in another run) |
| L7 the growing gaps are worth at least the shrinking gaps (from L1) | proved, 0.1 s |
| L9 each shrinking step, priced and times `μ`, is at most `k` times its priced gap | proved, 2.0 s |
| P1 the turnover cap | proved, 540.6 s on the third seed (2.1 s in another run) |
| P3 the growth cap | proved, 2.0 s |
| L12 `k` carries L7: `Σ_grow gap · p · k >= Σ_shrink gap · p · k` | unknown: 600 s over three seeds, and 180 s on the first of 27 sign patterns |
| P4 the `μ` bound (from L10, L11, L12) | not closed: it depends on L12 |

Seventeen of nineteen statements are proven for three legs. The two left are one step: L12 multiplies L7, a proven
inequality between two sums, by `k >= 0`, which is a line by hand and which z3 did not close for three legs in any
of the forms tried (the sums as `If` terms, `k` as a product or as a pinned unknown, split by which legs grow,
shrink or stay). With L12 the `μ` bound follows linearly, as it does for two legs in two seconds. The record keeps
P4 at three legs as proven up to that hand step, not as proven.

The times are one run's each. z3's search depends on the order terms were built in: P1 took 2 seconds in one run
and 540 in another, L1 ten seconds and then a fifth of one. The script therefore gives every statement its own
dependency list rather than the pool of everything proven before it (the pool slowed the solver), retries an
unknown under three random seeds, pins `k` only for the statements that use it, and can split a statement by sign
pattern. `python3 -I test/vectors/proofs.py 3 200 L12,P4` repeats the open two.

P4 is the `μ` bound the fuzz test `testFuzz_R04_theExecutorDeliversMuTimesWhatItTakes` and the invariant suite's
`muBoundBroken` sample; it is now proven for two legs with no slack, from L1 (the targets' value covers the moving
value), L2 and L3, and for three legs up to the hand step above. P1 is the turnover cap, exact. P3 is the growth cap, and its exact statement is a
finding.

## 4. Findings

- **The growth cap's exact bound depends on the minimum trade.** The rule says a growing leg adds at most
  `μ · MAX_GROWTH` of its own units. The step is `⌈(t − u) · ⌈μ · s / 1e18⌉ / 1e18⌉`, and the inner ceiling adds up
  to `(t − u) / 1e18` raw units, which L4 bounds by `u / s`. At a share of one wei that is the leg's units once over:
  a leg could double and a bit, twice the rule. What keeps the slack negligible is the minimum trade: a fill that
  proceeds has released at least `MIN_TRADE` of the moving value, and the release is at most that value, so
  `s >= MIN_TRADE` (L6) and the slack is at most `u / 1e15`, a quadrillionth of the leg, plus one raw unit (P3). The
  rule in AGENTS.md now says so. Nothing to change in the contract: the bound holds as the design means it, and the
  dependency was unwritten, not broken.
- **The `μ` bound holds exactly**, with the roundings as they are: the targets rounding up is what makes it so (L1).
  Flip that rounding and P4 fails, which is what mutant V1 of step 3 showed from the other side. Proven for two
  legs; for three, z3 closes every step but the multiplication of L7 by `k`, a line by hand (section 3).
- **Halmos is not the tool for this function as it stands.** A symbolic tool that models `Math.mulDiv` as one
  operation, or a harness that exposes the steps one at a time, would be; the latter means `internal` functions in
  `WeightedMath`, a contract change this step did not make.
- **Certora was not run.** The hub's backing invariant stays with the invariant suite and the deterministic walks
  (XS-16) until the project pays for it or an auditor brings it.
