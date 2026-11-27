# Changeable weights

## The ask

On 2026-11-23 the owner, told that an index's coins and percentages are fixed at creation: "index is unchangable after
deployment even bitcoin is changable so that unchangeability is very bad". Offered changes in the contracts behind a
notice period, a migration to a new index in the app, or both, the owner said: "fix both".

Asked the three choices below, the owner chose: the index's creator proposes; a notice of 7 days; and, of a coin the
index does not hold, "lets not do that adding new coin after creationg that index dosnot holds". So an index's weights
can change after creation, its coins cannot. It amends the design rule "Weights and constituents are fixed at creation"
(the constituents stay fixed) and the owner's "fixed constituents" (unchanged), and the backlog's "Constituent changes
(a new list is a new index)" stays as it is.

## What Bitcoin's case teaches

Bitcoin's rules change, but by upgrades announced long ahead that every holder can see coming, and never by a key that
moves anyone's coins. An index can change the same way: a change is announced, waits, and holders who disagree leave
at full value before it applies. No key gains a power over funds: the change moves no coin by itself, and the coins
move only through the rebalance auction, under the checks every fill passes today.

## New percentages for the coins an index holds

- **Who proposes.** The index's creator (`creatorOf`), the role that named the weights. The creator, the owner and the
  guardian can cancel a pending change; nobody else can propose one, and a new proposal replaces the pending one.
- **The notice.** A change applies no earlier than `WEIGHTS_DELAY` after it is proposed (7 days, the guardian
  change's delay) and no later than `PROPOSAL_WINDOW` after that, by anyone. Holders exit throughout; the app
  shows every pending change on the index's page.
- **What changes.** The weights, and nothing else: the units stay until a rebalance moves them. The new weights obey
  creation's rule: each at least one basis point, all summing to `TOTAL_WEIGHT`. A coin is phased out by a weight of
  one basis point, and its units then shrink by at most a fifth a rebalance.
- **Where it lives.** The pending change in the factory, and one function in the hub that only the factory calls, to
  write the weights. A change cannot apply while a rebalance is pending.
- **How the units follow.** The next rebalance moves the units toward the new weights, under the bar and Pyth's check,
  as any rebalance does. The math takes the weights as an input, so nothing in the units' check, its model, its
  vectors or its proofs changes.
- **Why no weight of zero.** A coin at weight zero earns nothing in the units' check, whatever happens to its units, so
  the units would no longer protect its value at all: only Pyth's price would, and a wrong price could hand the coin
  away. That is the weakness a new coin has (below). At one basis point the units still guard the leg, as they guard
  every small weight today.
- **Only on a factory with an oracle.** A change of weights opens a distance between the units and the weights. On
  units alone a creator could reweight sharply and take that distance through its own auction, the drain the design
  rule "An index is created on its weights" closes at creation; Pyth's check bounds it to the tolerance per fill. A
  factory without an oracle (Sepolia, tests) takes no proposal.
- **What it costs.** A change of weights opens a distance between the units and the weights, the gap the design rule
  "A fair price needs a bidder" describes. Under Pyth's check a lone executor keeps at most the tolerance of what it
  trades, up to 2% at the last second. A creator who proposes a large change and fills its own auction is bounded the
  same way, and holders had the notice to leave. With the caps a large change takes several rebalances: a leg moves at
  most a fifth down and double up per fill.

## A coin the index does not hold (refused by the owner)

The units' check scores each leg by its change relative to what the index holds: `x = (new − current) / current`. A new
coin starts at zero units, so it cannot be scored, and a fill that sells the index's coins to buy one lowers every
other leg and so scores below the bar. A new coin can enter in one of two ways:

1. **Pyth prices the entry.** For a coin the index does not yet hold, the fill's value check at Pyth's prices decides,
   and the units' check judges the other legs alone. This is the one place a price would accept a trade rather than
   only refuse one: an executor would keep up to the tolerance of the new coin's value against a correct price, and a
   wrong price could let a fill take more. It breaks "A price can only refuse" for that leg.
2. **No entry in the contracts.** A new coin means a new index, and holders move with one click in the app (below).

The owner refused both on 2026-11-23: an index's coins are fixed at creation.

## The app's migration (both parts)

- The creator of an index names another index as its successor, on the site, after creating it; the old index's page
  then shows the successor and a "Move to the new version" button.
- The button sells the old shares and buys the new ones through the zap or the builder, in two plans a holder signs in
  turn, or redeems in kind and issues in kind where the baskets overlap. Each plan is checked by the site as every plan
  is (`scripts/plan.ts`).
- Nothing in the contracts changes for it, and it is the answer for an index the owner will not reweight.

## The owner's calls of 2026-11-23

1. The creator alone proposes; the owner and the guardian cancel.
2. The notice is 7 days.
3. No coin is added after creation.

## What was built (2026-11-23)

- **The factory.** `proposeWeights(index, weights)` (`NotIndex`, `Unauthorized` for anyone but the creator, `NoOracle`,
  `InvalidWeights`), `cancelWeights(index)` (`NoPendingWeights`), `executeWeights(index)` (`WeightsNotReady`,
  `WeightsExpired`), `pendingWeights(index)`, `weightsEta(index)`, `WEIGHTS_DELAY`, and the events `WeightsProposed`
  and `WeightsCancelled`.
- **The hub.** `setWeights(weights)`, which only the factory calls (`NotFactory`), refuses a live rebalance, from its
  start through its auction (`RebalancePending`), and a wrong length (`InvalidComponents`), and emits
  `WeightsChanged(weights)`. `componentWeights()` reports the weights now in force. Nothing else in the hub reads the
  weights' history: the next start and fill read the weights as they stand, as they did the creator's.
- **The math, on its own.** With `setWeights` the factory's init code, which carries the hub's, reached 50,693 bytes,
  past EIP-3860's 49,152. `WeightedMath` is therefore deployed before the factory, which takes its address and
  refuses one without code (`NotAContract`); `DeployWeighted` deploys it, records its release hash
  (`MATH_INITCODE_HASH`) and checks its code in `checkDeployment`. The factory's init code is 46,867 bytes, its
  runtime 18,259 (6,317 under EIP-170), the hub's runtime 22,568 (2,008 under).
- **Tests.** In `test/WeightedHub.oracle.t.sol`: a change applied after the notice and filled toward the new weights
  under Pyth's check; who may propose and which weights are valid; a proposal replaced, cancelled by each role, and
  expired; no change while a rebalance is pending, and one once its auction has ended; only the factory writes the weights; and a factory
  without an oracle taking no proposal. Mutants CW1 to CW12, each killed.
- **Not built.** The app: the pending change on the index's page, the creator's form to propose one, and the move to a
  successor index (above). A weight of zero and a new coin stay refused.
