# The oracle-free rebalance

2026-11-10. The owner's call: "we have to cut off oracles somehow and keep rebalance safely", then "yes build oracle
free rebalance". It overturns two recorded calls: "Pyth is the only oracle" (2026-10-05) and "leave rebalance as it
is" (2026-11-10, the same day). This record is the spec the exact model (`test/vectors/settlement.py`) and the suites
are written from.

## 1. What changed, in one paragraph

An index still rebalances back toward the percentages its creator chose, through a permissionless auction. But no
contract reads a price any more. The executor names the units each coin is to have. The index checks only units: each
coin inside its caps, and a weighted gain at or above a bar that falls with time. Whoever clears the bar first
settles. Pyth, its contract, its five keys, its Hermes service and every price id are gone from the protocol.

## 2. What goes and what stays

Gone:

- Pyth's contract and every read of it; the vendored Pyth interfaces; every price id, in listings, indexes and the
  CREATE2 salt; the scaling of prices by recorded decimals.
- The price window (`priceTime`, `PRICE_LAG`), the confidence and moving-average checks (`MAX_CONFIDENCE`,
  `MAX_EMA_DEVIATION`), `MAX_PRICE`, `MIN_EXPO`.
- The multiplier `μ`, `MU_MAX`, `MU_MIN` and `MIN_TRADE`.
- Every payable entry point of the hub: nobody is paid for a price.
- The start's read of every moving feed (RX-3): no feed can be shut.
- `GuardianRelay` (RZ-26). It existed because a start carried a Pyth update valid for one slot, which a Safe cannot
  land. A start is a plain call now, so the guardian's Safe holds the role itself.

Stays:

- The state machine: interval, start, notice of `REBALANCE_DELAY`, auction of `AUCTION_DURATION`, cancel, expiry and
  the hold-offs (`design/2026-10-29-rebalance-state-machine.md`). `test/WeightedHub.states.t.sol` still takes every
  cell.
- The unit caps: a fill sends out at most `MAX_TURNOVER` (20%) of each coin's own units and adds at most `MAX_GROWTH`
  (100%) of them.
- The keep mask, as the guardian's way to forbid any fill from moving a coin.
- The backing post-check, each amount's rounding, the callback, the bounded fill, the probe that a bought coin can
  leave (RX-12), and everything about issue, redeem, claims and fees.

New:

- `executeRebalance(uint256[] newUnits, bytes data)`, its bounded overload, and `previewRebalance(newUnits)`.
- `currentBar()`, `recordedUnits()`, `componentWeights()`.
- A listing is a token and its decimals, which only bound the units an index may start with.

## 3. Why it is safe

Write `u_i` for a coin's units before a fill, `v_i` after, `w_i` for its weight (the weights sum to one), and
`x_i = (v_i − u_i) / u_i`.

**The rule.** A fill is accepted when every `x_i` lies in `[−0.2, 1]` and

    Σ w_i · L(x_i) ≥ bar > 0,    L(x) = x − x²/2 + x³/3 − 3x⁴/10.

**Lemma 1: `L(x) ≤ ln(1 + x)` on `[−0.2, 1]`.**

- For `0 ≤ x ≤ 1` the series `ln(1 + x) = x − x²/2 + x³/3 − x⁴/4 + …` alternates with shrinking terms, so stopping
  after a negative term is a lower bound: `ln(1 + x) ≥ x − x²/2 + x³/3 − x⁴/4 ≥ L(x)`, since `3/10 > 1/4`.
- For `x = −y`, `0 < y ≤ 0.2`: `ln(1 − y) = −Σ y^k / k`. The claim is `Σ_{k≥4} y^k / k ≤ 3y⁴/10`, that is
  `Σ_{k≥4} y^(k−4) / k ≤ 3/10`. The left side is at most `1/4 + (1/5) · y / (1 − y) ≤ 1/4 + (1/5)(0.2 / 0.8) = 3/10`.

The margin is thinnest at the turnover cap: `L(−0.2) = −0.2231467` against `ln 0.8 = −0.2231436`.

**Theorem 1: an accepted fill never lowers the weighted product of the units.** By Lemma 1,
`Σ w_i · ln(v_i / u_i) ≥ Σ w_i · L(x_i) ≥ bar > 0`, so `Π v_i^w_i ≥ e^bar · Π u_i^w_i`. That product is the invariant of
a constant-weight pool.

**Theorem 2: at any prices whatever, value after ≥ `e^(bar − D)` × value before.** Take any positive prices `q`. Let
`f_i` be coin `i`'s share of the index's value at `q` before the fill, and `D = Σ w_i · ln(w_i / f_i)`, which is zero
when the index sits on its weights at `q` and positive otherwise. By the weighted inequality of arithmetic and
geometric means,

    Σ v_i q_i = Σ w_i (v_i q_i / w_i) ≥ Π (v_i q_i / w_i)^w_i = Π (v_i / u_i)^w_i · Π (u_i q_i / w_i)^w_i
              ≥ e^bar · V · Π (f_i / w_i)^w_i = e^(bar − D) · V,

with `V = Σ u_i q_i`. Nobody has to say what `q` is: the bound holds for every `q` at once.

So:

- On its weights at the market's prices, an index cannot lose value to any fill.
- Off them, the most any fill can take is the distance `D`. It comes out of the holders' value: section 6 and
  section 8 have its size, for drift and for an index created off its weights.
- Forever, whoever fills and however, the holders own at least what a fee-less constant-weight pool with the same
  weights would hold.

**The rounding keeps the theorems.** The contract computes `x` rounded down and `L` rounded down. Since the logarithm
grows with `x`, the computed score of a leg is at most `L(x̃) ≤ ln(1 + x̃) ≤ ln(v_i / u_i)` for the rounded `x̃ ≤ x`.
`L` need not be monotone for this. The gain is the weighted sum floored once more.

**What is checked how.**

- Lemma 1: by hand, above, and again in exact rationals by `test/vectors/proofs.py` (standard library only), from
  the identity `d/dx [ln(1 + x) − L(x)] = x³(1 + 6x) / (5(1 + x))`. The difference therefore falls on `(−1/6, 0)`
  and rises on either side, so on `[−0.2, 1]` it is least at `0`, where it is zero, or at `−0.2`, where a rational
  bound of `ln(5/4)` shows it is `3.1e-6` above zero. The same script checks that `x` and the score round down
  inside the lemma's range for every leg up to 399 units and at the boundaries of large ones, every second of the
  bar, and that the amounts keep the backing.
- The two theorems: by hand, above.
- That the contract computes exactly this rule: the exact model and its 426 vectors, replayed word for word
  (`test/WeightedMath.vectors.t.sol`).
- Theorem 2 on its weights: `testFuzz_R04_onItsWeightsNoFillTakesValue`, any units, any second.
- Theorem 2 off them: `test_aLoneExecutorKeepsAtMostTheDistanceFromTheWeights`, the greediest fill at the auction's
  last second against the bound.
- The caps: `testFuzz_V5M2_noFillTakesMoreThanAFifthOfALeg`.
- The Halmos harness (`test/WeightedMath.halmos.t.sol`) states the integer properties; not run yet.

## 4. The settlement, as the model implements it

Inputs: seconds `elapsed` since the auction opened, the supply, the scale, the recorded units `u`, the units the
executor names `v`, the weights `w` in basis points, the keep mask. In this order:

1. `elapsed > AUCTION_DURATION`: `AuctionOver`. The hub refuses an expired auction first.
2. `v` is not one entry per coin: `LengthMismatch`.
3. The supply is zero: `NothingToRebalance`.
4. For each coin, in order:
   - its bounds are `lowest = ⌈u · (1 − MAX_TURNOVER)⌉` and `highest = u + ⌊u · MAX_GROWTH⌋`, or both `u` if kept;
   - `v < lowest` or `v > highest`: `LegOutOfBounds(i, v, lowest, highest)`;
   - `v` above 96 bits: `SafeCastOverflowedUintDowncast(96, v)` (RX-61).
5. `x = ⌊(v − u) · 1e18 / u⌋`, toward minus infinity.
6. `L = ⌊(30x·W³ − 15x²·W² + 10x³·W − 9x⁴) / (30·W³)⌋` with `W = 1e18`, toward minus infinity: the four terms over
   one denominator, divided once.
7. `gain = ⌊Σ w_i · L_i / 10,000⌋`, toward minus infinity.
8. `gain < bar(elapsed)`: `GainBelowBar(gain, bar)`.
9. Each amount is the coin's change in backing, `supply · |v − u| · scale / 1e36`, rounded down when it leaves and up
   when it comes back (SA-07).

Every rounding goes against the executor.

## 5. The auction

    bar(e) = ⌈ BAR_MAX · (2H − e mod H) / (2H · 2^⌊e/H⌋) ⌉,   BAR_MAX = 0.5,  H = BAR_HALF_LIFE = 12 minutes.

The bar starts at a half, halves every twelve minutes along a straight line within each, and after the twenty
halvings of the four-hour auction ends at 4.77e-7. It never reaches zero.

- It starts above what any trade offers. Only a fill that doubles every coin, a gift, clears the first second
  (`L(1) = 0.5333`).
- It falls about 1.1% of itself per block, so the price of a fill is found to a hundredth of what is at stake.
- A fill that changes nothing has no gain. So none can restart the rebalance interval for free (V5-L2), and
  `MIN_TRADE` is not needed.

**Why the bar is on the whole index, not a premium on what is traded.** With the executor choosing the trade, a
premium on the traded amount is won by the smallest trade: the first profitable fill would move a sliver, restart the
interval and leave the index where it was. A bar on the whole index's gain can only be paid out of the whole
distance from the weights, so the first fill that can afford it is the one that closes that distance.

**Why competition matters, and where.** The distance `D` is the prize. Executors compete by filling earlier, at a
higher bar, which leaves more with the holders. With an honest executor bidding, ours first, the holders keep all of
it but the executor's costs. With none, a lone executor waits for the last second and takes it, out of the holders'
value. Competition decides how much of the distance the holders keep. Theorem 2 bounds what they can lose either
way: the distance, which is what a fee-less constant-weight pool loses to arbitrage.

## 6. What a fill can take: the numbers

The default index (ETH 50%, BTC 30%, USD 20%), with ETH up 25%:

| | |
|---|---|
| Distance from the weights | 0.62% of the index |
| The fair fill's gain | 0.6201%, which the bar reaches 4,618 seconds in |
| A lone executor at the last second keeps | 0.6166% of the index, and no more |
| An executor on an index that sits on its weights takes | nothing, whatever it names |

Against the design it replaces:

| Case | With Pyth | Oracle-free |
|---|---|---|
| Price keys stolen or wrong | up to 20% of each coin per fill | cannot happen |
| An honest executor bidding | fair price | fair price, less the executor's costs |
| No honest executor bids | about 0.1% of the index a week (2% of what trades) | the whole distance: 0.3 to 0.6% in an ordinary week, up to 1.8% in a crash week, 5.0% in one fill after one coin of two doubles |
| A 10% coin turns worthless and free to mint | about its own weight of the rest, per fill | at most 5.8% of the rest, per fill |

A simulation of the executor's best fill (20 equal coins, each moving 11% a week on its own) lands the index 96% of
the way to its weights; `L` is a little under the logarithm, so the last few percent are not worth an executor's
while. After a quarter's drift (each coin moving 40%) the unit caps bind and one fill goes about half the way.

Gas, a hundred coins, mock tokens, each account cold (`test_aHundredComponentsFitOneTransaction`):

| | With Pyth | Oracle-free |
|---|---|---|
| `createIndex` | 10.7M | 5.3M |
| `executeRebalance` | 4.8M, plus 2.3M for Pyth's real parse | 4.2M |
| `startRebalance` | a parse | 94k |

The hub is 19,861 bytes, 4,715 under EIP-170 (it was 98 under).

## 7. What it costs, plainly

- **A fair price needs a bidder.** With Pyth the price was fair whoever filled. Now it is fair when executors compete
  or ours bids. A lone greedy executor keeps the distance from the weights, several times what `MU_MIN` let it keep.
  The keeper's liveness is now the holders' performance: what a lone executor takes comes out of their value.
- **One fill may not land on the weights.** The unit caps bound a fill as before, and `L`'s slack under the
  logarithm makes the last few percent unattractive. The next rebalance takes the rest.
- **The keeper needs prices of its own.** The protocol reads none, but an executor must know what the market says to
  name its units. The keeper's own valuation, at its own risk, is the keeper's stage.

## 8. Known limitations this adds

- **A dust index's units can be walked.** Each fill must gain, but on a supply worth nothing a gain costs nothing.
  An executor that holds the only shares can move the units off the weights over several intervals, and a later
  minter deposits at those units. The mint is in kind and fair; the next auction pays the distance to whoever fills
  first. An index without shares does not rebalance at all. The app shows an index's coins against its weights.
- **An index created off its weights can be drained by its creator.** `createIndex` takes units and weights, and
  nothing compares them: that would need a price. A creator can name units far from the weights, let others mint in
  kind at those units, and fill its own auction at the last second. On the exact model, one such fill takes 15.5% of
  a 50/50 index created 90/10 by value, and 19.8% of a 99/1 index created 1/99: the turnover cap, a fifth of a leg,
  is the only bound, and the interval the only delay. The same arithmetic prices drift: 0.48% after one coin of four
  rose a quarter, 5.0% in one fill after one coin of two doubled (its whole distance is 5.7%), 8.7% after it tripled
  (13.4%). The app, which has prices, creates on the weights and is the only check on an index someone else
  created: it shows each index's coins against its weights and must not offer a mint of one far from them. Found
  on 2026-11-10, after the first version of this record called the distance "the rebalance's proceeds".
- **A fill near the weights can be forced.** When the distance is under an executor's costs, nobody honest fills,
  and anyone may fill at the last second with a gift of at least the bar's floor, 4.77e-7 of the index, restarting
  the interval. It costs the filler and pays the holders, and delays the next rebalance by the interval.
- **A collapsing coin** is still bought by fixed weights, at most doubling per fill (V5-L3, RX-15). The guardian's
  keep mask stops it, as before.

## 9. What is built and what is left

Built on `feat/oracle-free-rebalance`: `WeightedMath`, `WeightedHub`, the factory's listings, the scripts
(`DeployWeighted`, `ConfigureWeighted`, `Listings`, `SetupTestMarket`), the exact model and vectors, every unit, fuzz
and invariant suite, the state-machine suite, the mutants, and the ABIs. `GuardianRelay` and the Pyth interfaces are
deleted. `audit/2026-11-10-oracle-retirement.md` records the review ids that went with Pyth.

Left:

- The keeper's bot (`keeper/keeper.mjs`, `keeper/bot/`): it still builds the retired calls. It needs to name units
  (an optimiser) from its own price source. The executor contract is converted: `fill` takes the units and no ether.
- The fork suites are rewritten and compile, and have not run: they need an archive RPC.
- The web app and its backend, which read `previewRebalance` and the listings.
- A red team of this mechanism, by reviewers who did not design it.
- The Halmos harness, not run yet. (`test/vectors/proofs.py` was rewritten for this arithmetic on 2026-11-10: it
  checks the proof's chain in exact rationals, and needs no solver.)
- A new Sepolia deployment.
