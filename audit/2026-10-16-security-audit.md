# Security audit of 2026-10-16

An orchestrated, read-only audit of the Xindex smart contracts on `v5-custom-weights` at `f8058b7` ("Build the
website's engine: fees, cadence, gates, a streaming fee, a basket builder and a request filler"), the commit that
landed the issue and redeem fees, the streaming fee, the per-index rebalance interval, the mint gate, `BasketBuilder`
and the keeper's request filler. The scope was `src/`, `script/`, the keeper (`keeper/src/`, `keeper/bot/`,
`keeper/keeper.mjs`), the tests, and the records the code is held against (`AGENTS.md`, `README.md`,
`ARCHITECTURE.md`, the design records).

Edited on 2026-10-25: paths on the author's machine became paths from the repository root; nothing else changed. The PoC
files this record names were never committed.

## Method

- **Hunters by lens, two rounds.** Fifteen hunters in the first round, one lens each: hub fees, hub streaming, hub
  settlement, hub oracle, factory, builder, swaps and zap, requests, keeper, token behaviour, economic, doc versus
  code, access and initialization, gas and denial of service, scripts and configuration. Eight in the second round on
  the leads the first left open: auction liveness griefing, the streaming clock trap, scale-fold stranding at scale,
  listed tokens' admin powers against the paths, test adequacy through mutants, factory listing and creator lifecycle,
  keeper bot trust boundaries, integration notes versus code. They produced 128 candidates.
- **Dedup** folded the candidates into 66 findings, `F-01` to `F-66`, each with a reporter count.
- **Four verifiers per finding**, each reading the code afresh rather than the finding's quotes: two code-truth
  verifiers, which trace the mechanism and work the numbers; an exploitability verifier, which asks who gains, who
  loses, and under what precondition on mainnet; and a prior-knowledge verifier, which searches every audit record,
  triage, retirement record, known limitation, design record, NatSpec and test for the same mechanism. A finding
  survives when at least one code-truth verifier confirms it, the exploitability verifier does not refute it, and the
  prior-knowledge verifier finds no record of it. A finding both code-truth verifiers confirm but the exploitability
  verifier refutes is listed under Contested; one the prior-knowledge verifier matches to a record is listed under
  Already recorded; one both code-truth verifiers refute is listed under Refuted.
- **Proofs of concept**, one at a time, for every surviving finding of medium severity or above, as Foundry tests under
  `test/poc/` against the repository's own mocks (`WeightedTest`, `MockPyth`, `MockSwapRouter`, mock tokens), each
  run with `forge test --match-path test/poc/F-NN.t.sol -vv` and nothing else. A test is written to pass while the
  defect is present and to fail once it is fixed; where a mutant of the fix was cheap to apply, it was applied and the
  test seen to fail, then reverted. Two files (`F-05`, `F-10`) carry a verbatim copy of `keeper/src/KeeperExecutor.sol`
  because the keeper's `xindex/` remapping is its own and its `keeper/out/` artifact was stale against the source.
- **Not done.** No RPC was contacted, so no fork suite ran and no mainnet token, pool, Pyth contract or Hermes response
  was read; no Hermes key was used; no external auditor took part; the five fork suites and the keeper's end-to-end
  test, which `f8058b7`'s own message says were not run, stay unrun. `forge fmt`, `forge lint`, `forge coverage`,
  Aderyn, Wake and the Node tests were not run. The PoC files are untracked, not formatted, and not part of the gates.

Hunters' claims are reported as the verifiers left them: a confirmed finding is stated as confirmed, a PoC's output is
quoted where it is decisive, and a claim nobody ran is marked unproven.

**Result.** No path takes index funds from a holder outside the documented bounds in `WeightedHub`,
`WeightedIndexFactory`, `IndexZap`, `BasketBuilder` or `MintRequests`. Eighteen findings survive. One is high: the
streaming fee's clock, kept on a dust supply, charges the next minter for the whole idle period, a silent 5-6% a year
of the first deposit at the rate caps, which a creator can arm on purpose. Seven are medium: the settlement folds the
streaming scale by flooring every leg's units and strands up to `totalSupply / 1e18` raw units per leg per fill,
owned by nobody; a guardian's sliver fill now restarts the index's own interval, up to 91 days, where every document
still says a week; and five defects in the keeper, which holds no role, one of which stops it from starting at all
against this commit. All eight were confirmed by a proof of concept. Ten are low or informational and were traced by
reading only. Twenty-four findings are contested, twenty-three were already recorded, one was refuted.

Each surviving id is `XS-…`, the audit of 2026-10-16. The workflow's `F-` id follows each in parentheses.

| Id | Severity | Finding | Evidence |
|---|---|---|---|
| XS-1 | High | A streaming-fee clock kept on a dust supply charges the next real minter for the whole idle period; a creator can arm it | PoC confirmed |
| XS-2 | Medium | A settlement floors every leg's scaled units, kept legs included, and strands up to `totalSupply / 1e18` raw units per leg per fill | PoC confirmed |
| XS-3 | Medium | A guardian keep-mask sliver fill restarts the index's own interval, up to 91 days; the documents say a week | PoC confirmed |
| XS-4 | Medium | A bounded fill pays Pyth's parse before `RebalanceMovedOn`, a 0.11% front-run issue trips it every block, and the keeper retries without a cap | PoC confirmed |
| XS-5 | Medium | The keeper values a kept incoming coin at Pyth with no market check; the route-loss filter selects for exactly the coins trading below Pyth | PoC confirmed |
| XS-6 | Medium | A keeper request fill checks the request only after every swap and the issue, so a requester's cancel burns the whole fill | PoC confirmed |
| XS-7 | Medium | The request filter ranks escrows by raw size across 6- and 18-decimal units and keeps eight; dust redeems crowd every mint out, and gated indexes are never pre-filtered | PoC confirmed |
| XS-8 | Medium | The keeper's `HUB_SLOTS` are stale after `f8058b7`; its storage self-check throws and no keeper can start | PoC confirmed |
| XS-9 | Low | No view exposes `_lastAccrual`; `pendingStreamingFee` reports zero at dust supply while the next accrual will charge | Unproven |
| XS-10 | Low | `BasketBuilder` is one custody point for every user's escrow: an issuer blacklist or burn on the builder freezes or destroys them all, and nothing probes before escrowing | Unproven |
| XS-11 | Low | A failed request scan advances the cursor before the read, so a request in a failed chunk is never seen again | Unproven |
| XS-12 | Low | `clearStuck` trusts the RPC's pending nonce and runs every idle block, so a lying RPC makes the bot mine a cancel each block | Unproven |
| XS-13 | Low | Replacement fees grow 12.5% per block with no ceiling; `MAX_FEE_GWEI` is never applied to cancels | Unproven |
| XS-14 | Low | Mutant survives: `_redeem` skipping `_feeTerms` when the exit fee is zero would pay the streaming fee to the redeemer | Unproven |
| XS-15 | Low | Mutant survives: `BasketBuilder.redeem` crediting the balance instead of the delta would let one user withdraw others' escrows | Unproven |
| XS-16 | Info | The invariant handler models none of the engine's new surfaces and copies the dust-clock rule, so XS-1 is invisible to it | Unproven |
| XS-17 | Info | `test_I09_theKnownLimitationsAreDocumented` pins only the section heading | Unproven |
| XS-18 | Info | The hub's header, README and ARCHITECTURE state the invariant without the streaming scale, and several hub facts are stale | Unproven |

## Status of the fixes (2026-10-17)

Every finding is fixed on `v5-custom-weights`, uncommitted on top of `f8058b7`. Each fix's test is named after its id,
as `AGENTS.md` gate 6 requires, and each was checked against a mutant that removes the fix: every mutant failed its
test. The proofs of concept under `test/poc/` were ported into the suites as these tests, asserting the fixed
behaviour, and deleted.

| Id | Fix | Tests |
|---|---|---|
| XS-1 | `_accrue` restarts the clock on every accrual, one that mints nothing included | `test_XS1_anAccrualThatMintsNothingRestartsTheClock`, `test_XS1_aDustSupplyChargesTheNextMinterNothingForTheIdleTime`, `test_XS16_handlerReachesEveryPath` (fees and invariant suites) |
| XS-2 | No fold: `WeightedMath.settlement` takes the scale and moves recorded units, `_checkBacking` works at the scale, `_applyRebalance` keeps it; a fee that would shrink the scale to zero is not charged | `test_XS2_aSettlementAccruesFirstAndKeepsTheScale`, `test_XS2_aKeepMaskFillLeavesTheKeptLegsUnitsExactly`, `test_XS2_aFillOfAStreamingIndexStrandsNothing`, `test_XS2_aFeeThatWouldLeaveTheScaleAtZeroIsNotCharged`, `invariant_everyComponentBackedAtTheExactScale` |
| XS-3 | A keep-mask fill restarts only `MIN_REBALANCE_INTERVAL`, for any start, so a keep can be renewed a week on; `earliestRebalance()`; the docs corrected | `test_XS3_aKeepMaskFillRestartsOnlyTheMinimumIntervalForStrangers`, `test_XS3_theGuardianCanRenewAKeepAWeekOn` |
| XS-4 | `KeeperExecutor.fill` takes `maxSupply` and reverts `SupplyMovedOn` before the hub; the bot backs off an auction whose fills revert on chain and leaves it after three | `test_XS4_aSupplyAboveTheQuoteRevertsBeforeTheHub`; node `XS-4: ...` |
| XS-5 | A kept coin is valued at the lower of Pyth and its best quote, on the auction and request paths; the quote follows the amount and is refreshed after 25 blocks; pools that quote nothing count as nothing, and an RPC failure is not a quote | node `XS-5: ...` (three) |
| XS-6 | `_mintFor` and `_redeemFor` check the request open and in time, and `_mintFor` the gate, before any swap | `test_XS6_aClosedMintRequestRevertsBeforeAnySwap`, `test_XS6_aClosedRedeemRequestRevertsBeforeAnySwap`, `test_XS6_aGatedIndexRefusesTheExecutorBeforeAnySwap` |
| XS-7 | Requests ranked by dollars per side, the gate read with them, unmeetable limits skipped, failed simulations and fills that revert on chain backed off | node `XS-7: ...` (four) |
| XS-8 | `HUB_SLOTS = { eta: 6n, keepMask: 7n }`, pinned against a real clone | `test_XS8_theBotsHubSlotsAreTheHubs` |
| XS-9 | `lastAccrual()`; with XS-1 fixed, a zero `pendingStreamingFee` means an accrual now mints nothing | `test_XS9_theClockIsVisible` |
| XS-10 | The builder sends itself one unit of each token it credits, measured, so a builder already blocked takes no escrow by deposit, buy or redeem; a known limitation added | `test_XS10_aBlacklistedBuilderTakesNoNewEscrow`, `test_XS10_aBlockedBuilderBuysNothing`, `test_XS10_aTokenWhoseSelfTransferCostsTheBuilderIsRefused` |
| XS-11 | A failed read keeps what was known; the cursor advances only past ids read without a gap | node `XS-11: ...` |
| XS-12 | A pending nonce is cleared only once per start or for the bot's own send of unknown outcome | node `XS-12: ...` (two) |
| XS-13 | Replacement fees capped at `MAX_FEE_GWEI`, at most `MAX_REPLACEMENTS` bumps | node `XS-13: ...` (two) |
| XS-14 | Tests now pin the recipients of a dust redeem's and a fee-free redeem's streaming fee | `test_XS14_aDustRedeemStillAccruesTheStreamingFeeToTheRecipients`, `test_XS14_aRedeemWithoutAnExitFeeAccruesTheStreamingFeeToTheRecipients` |
| XS-15 | A test redeems while another user holds an escrow of every component | `test_XS15_aRedeemCreditsOnlyWhatItDelivered` |
| XS-16 | The handler models the clock and the scale from the spec, keeps the recorded units, and drives dust, lifetimes, creator and policy changes, a gated index and the builder; three invariants added | `test_XS16_handlerReachesEveryPath` and the `invariant_*` functions of `test/WeightedHub.invariant.t.sol` |
| XS-17 | Every limitation pinned inside its section; `README.md:449` corrected; streaming-fee and builder limitations added | `test_I09_XS17_theKnownLimitationsAreDocumented` |
| XS-18 | Invariant stated with the scale in the hub header, README and ARCHITECTURE; stale ARCHITECTURE and `IIndexZap` lines fixed; the R11 probe covers ten entry points | `test_R11_everyEntryPointIsGuardedDuringTheCallback`, by documentation otherwise |

An independent review of these fixes (six reviewers by area, a skeptic per finding) confirmed eleven defects in
them, all fixed the same day. In the hub, XS-3's first form made a start with a keep mask wait the index's whole
interval, so the guardian could not renew a keep around a frozen component; any start now waits
`MIN_REBALANCE_INTERVAL` after a keep-mask fill. In the builder, the probe is now measured and the buy path tested.
In the keeper, the kept-coin quote now follows the amount, a pool that quotes nothing counts as nothing, and a gated
index's creator can no longer make every request fill burn its swaps. The rest were docs: ARCHITECTURE's settlement
formulas and `units_i`, `previewRebalance`'s units, and the rounding-drift sentence, all now with the scale.

Run on 2026-10-17 against Tenderly's public archive (`gateway.tenderly.co/public/mainnet`):
- The five fork suites, at their pinned block 26,033,838: 40 passed, 0 failed, 0 skipped.
- The keeper's end-to-end test, on an anvil fork at block 26,212,940: 20 passed, 0 failed. It runs `keeper.mjs`
  against the real Pyth contract, Uniswap's pools and the protocol's own factory and hubs.

The end-to-end run first failed for two reasons in the test's driver, neither in the contracts or the bot:
- The driver gave the executor NVDAon stock without the owner's `stockAllowance`, which CF-1 added on 2026-10-13 and
  which the driver had not been run against since. It now grants it.
- Its MIX index sold Wormhole SOL at a fake Pyth price of $180 while SOL's own Ethereum pool paid $103.79, and
  expected the keeper to keep that SOL at Pyth. That is the adverse selection XS-5 refuses, so the keeper rightly
  declined. MIX now sells JUP, which has no pool, and a fifth index, ADV, keeps the SOL setup and asserts that it is
  never started, the XS-5 regression on mainnet state.

Still unproven: the builder's probe on the 92 listed tokens, since the builder has no fork test (a token that refused
a one-unit self-transfer would refuse the builder). `KeeperExecutor.fill`'s ABI changed.

## XS-1: the streaming clock kept at dust supply (F-01, high, PoC confirmed)

**Claim.** `_accrue` keeps `_lastAccrual` whenever the fee rounds to zero on a non-zero supply, and `_issue` accrues
before it mints. A large mint onto a dust supply therefore inherits the whole elapsed period, and the next accrual,
anyone's `accrueFees()` or the victim's own redeem, charges `rate × elapsed` on the new supply. Every preview reports
zero at dust supply and nothing exposes the clock. `AGENTS.md`'s "the first minter owes nothing for the time before
it" holds only at supply zero.

**Evidence.** `src/WeightedHub.sol:395-404`:

```solidity
(uint256 scale, uint256 feeShares) = _pending(rate);
if (feeShares == 0) {
    if (totalSupply() == 0) _lastAccrual = SafeCast.toUint40(block.timestamp);
    return;
}
```

`_pending` (`:423-432`) computes `part = rate * (block.timestamp - _lastAccrual)`, `whole = YEAR * BPS` and
`feeShares = Math.mulDiv(supply, part, whole - part)`, rounded down; `_issue` calls `_accrue` at `:252` and
`_mint(to, shares)` at `:258`; `_redeem` accrues at `:317` before `_amounts` at `:319`; `_lastAccrual` is written
nowhere else. The numbers: `whole = 315,360,000,000`; one year at the 600 bps cap gives `part = 18,921,600,000`; on
supply 1 `feeShares = floor(18,921,600,000 / 296,438,400,000) = 0`, so the clock is kept; after a mint of `1e24`
shares the next accrual mints `6.383e22` shares, 6.0% of the index, and sets the scale to `0.94e18`. The clock stays
kept while `part < whole / (supply + 1)`: 8.3 years on 1 wei (a take of up to 50%), about a year on 15 wei, about 60
days on 99 wei; a one-block stall needs a supply under `4.38e7` wei. `test/WeightedHub.fees.t.sol:735`
(`test_aSupplyTooSmallForAFeeShareKeepsTheClock`) pins the kept clock on a constant 5,000-wei supply only;
`test/WeightedHub.invariant.t.sol:85-87` (`_clock`) copies the hub's rule, so the suite models the trap. `createIndex`
(`src/WeightedIndexFactory.sol:133`) is permissionless and `creatorStreamingBps` goes up to 500.

**Attack path.** A creator (or anyone; the creator and the platform collect) creates an index with
`creatorStreamingBps = 500`, issues one share to itself (one raw unit per component), and waits. A victim mints
through `issue`, the zap, the builder or a `MintRequests` fill: `previewIssue`, `components()` and
`pendingStreamingFee()` all report scale `1e18` and fee 0, the victim pays the full basket. Next block the creator
calls `accrueFees()` and takes 5/6 of `rate × idle` of the victim's deposit; the victim cannot exit first, since
`_redeem` accrues before paying. The creator re-arms by redeeming down to dust. No path can disarm it: `accrueFees()`
at dust supply keeps the clock, and a settlement's `_applyRebalance` resets `_scale` (`:715`), never the clock.

**Impact.** A bounded, deterministic, silent take of `rate × idle time` from the first deposit after any dust period:
5% a year at today's zero platform policy, 6% at the caps, up to `1/(supply+1)` of the deposit (50% on 1 wei after 8.3
years). The invariant holds throughout (only shares move), so no suite can see it. Honest residues are barely exposed:
a 30-day stall at 500 bps needs under about 243 wei, a deliberate leftover. The exploitability verifier rated it high
(an untrusted role, a stated property that fails for the first real minter); both code-truth verifiers rated it
medium on the lead time per index. It is kept at high.

**PoC.** `test/poc/F-01.t.sol`, three tests, all pass while the defect is present.
Creator issues 1 share at the caps (creator 500, platform 100), `vm.warp(+365 days)`; `pendingStreamingFee()` is
`(0, 1e18)` and `previewIssue(1e24)` is the unscaled basket; alice mints `1e24` and pays exactly 25,000 ETH, 50,000,000,000
raw BTC and 20,000,000,000,000 raw USD; a stranger's `accrueFees()` one block later mints:

```
fee minted by accrueFees (shares): 63829813072714783656727
of it to the creator: 53191510893928986380606
of it to the platform: 10638302178785797276121
one block's fee would have been: 22831050749567368
scale after the accrual (1e18 = one): 939999977168949771
victim paid: 25000000000000000000000
victim got back: 23499999429223744275000
```

A same-block exit returns 23,500 of 25,000 ETH (`test_F01_theVictimCannotExitBeforeTheCharge`); the control with no
dust seed charges one block's fee, `2.28e16` shares (`test_F01_control_anEmptyIndexDoesNotChargeTheFirstMinter`).

**Fix.** Reset `_lastAccrual` whenever an accrual mints nothing. The rounding loss the design feared is under one
wei-share per call, and dodging it by calling every block needs a supply under `4.38e7` wei, which is worthless. The
narrower fix, resetting in `_issue` before `_mint`, closes the mint path alone. Either way: add a `lastAccrual()`
view, update the handler's `_clock`, rewrite `test_aSupplyTooSmallForAFeeShareKeepsTheClock`, `AGENTS.md` and the
NatSpec at `:391-394`, and add the regression (dust supply, warp 365 days, mint `1e24`, `accrueFees()` must mint one
block's fee, not `6.38e22`).

## XS-2: the settlement's fold strands the scale's fraction (F-03, medium, PoC confirmed)

**Claim.** `_priced` runs the settlement on `_unitsAt(_scale)`, which floors `units × scale / 1e18` for every component,
kept legs included, and `_applyRebalance` writes the result with `_scale = SCALE_ONE`. The fraction dropped per `1e18`
shares is multiplied by the whole supply, so the required backing falls by up to `totalSupply / 1e18` raw units per
leg, and nothing can ever pay the surplus out. The hub header's "at most one raw unit per call" is false for the
settlement, and a kept leg's stored units change, against `AGENTS.md`'s "its units stay exactly as they were".

**Evidence.** `src/WeightedHub.sol:922`:

```solidity
units[i] = scale == WAD ? _components[i].units : Math.mulDiv(_components[i].units, scale, WAD);
```

`_settle` accrues first (`:573`), `_priced` passes `_unitsAt(_scale)` (`:616-617`), `_applyRebalance` writes the units
and `_scale = SCALE_ONE` (`:713-715`), `_checkBacking` requires `max(floor(S·u/1e18) + claims, held − out + in)` and
skips a leg that moved nothing (`:738-742`). `src/WeightedMath.sol:129-132` sets a kept leg's target to its already
floored `current`. `_backing` (`:947`) keeps full precision for issue and redeem, and before `f8058b7` `_priced` ran
on stored units, so the drift is new with the streaming fee. The numbers: weekly at 600 bps, `part = 362,880,000`,
scale `998,849,315,068,493,150`; a WBTC leg at 10,000 sat per share folds to `9,988.49`, stored `9,988`; at
`S = 1e24` the leg's required backing falls by about `493,150` sat per fill. The bound is `< S / 1e18` raw units per
leg per fill, i.e. less than `1 / units` of the leg: at most 1 bp at `MIN_RAW_UNITS` (`1e4`), about 26 bps a year on
weekly fills, more once a rally sells a leg's units below `1e4`, nil for 18-decimal legs.
`test/WeightedHub.fees.t.sol:715-731` (`_assertSettledAtScale`) models the same floor, and every backing check in
the suites is a `>=`.

**Attack path.** None. Every fill of every streaming-fee index does this, and a guardian keep-mask fill strands the
same on a leg nobody touched. No actor gains: the executor cannot take the surplus, and minting more only strands more
pro rata.

**Impact.** A permanent, beneficiary-less loss of holder funds, of the same order as the platform's 100 bps streaming
cap on low-decimal legs (WBTC, XAUT, the 6- to 9-decimal copies). The invariant holds (surplus only), so no suite sees
it, and `Rebalanced.units` and the stored units of a kept leg change, so a monitor diffing them misfires. All four
verifiers rated it medium; the argument for high is the broken stated bound and that the leak grows with supply.

**PoC.** `test/poc/F-03.t.sol`, three tests. A three-leg index with BTC at 10,000 raw
units (`MIN_RAW_UNITS`, 8 decimals), `1e24` shares, 600 bps, a fill 7 days after creation at `mu = 1`. The keep-mask
fill on BTC moves nothing in or out of BTC, yet:

```
BTC units stored before the fill: 10000
BTC units stored after the keep-mask fill: 9988
BTC owned by no share (sat): 493719
BTC left in the index after every holder redeemed (sat): 493720
```

The maskless fill strands 754,293 wei of ETH, 493,720 sat and 260,575 raw USD, each still in the index after every
holder redeems; the control without a streaming fee strands 0 on every leg.

**Fix.** Do not fold at settlement: keep `_scale` across fills, run `WeightedMath` on the stored units (the settlement
is homogeneous in units) and apply the scale only in `_amount` as `mulDiv(shares, delta × scale, 1e36)`, with
`_checkBacking` at `_scale` and no `_scale = SCALE_ONE`; kept legs then stay bit-exact. Otherwise document the bound
(`1 / units` per leg per fill), raise `MIN_RAW_UNITS`, and correct the keep-mask sentence. Regression: after a fill at
scale below `1e18`, the surplus over `floor(S·u·s/1e36) + claims` per leg must stay at or under 2 raw units.

## XS-3: the sliver stall is the index's interval, not a week (F-04, medium, PoC confirmed)

**Claim.** `startRebalance` gates every caller on `lastRebalance + _config.rebalanceInterval`, 7 to 91 days, and any
fill sets `lastRebalance`, a two-leg keep-mask sliver included. `MIN_TRADE` is measured on the moving legs' value only,
so the sliver is tiny. README, ARCHITECTURE and `AGENTS.md` still bound the stall at `MIN_REBALANCE_INTERVAL`, "up to a
week".

**Evidence.** `src/WeightedHub.sol:484-485`:

```solidity
uint256 earliest = lastRebalance + _config.rebalanceInterval;
if (block.timestamp < earliest) revert RebalanceTooSoon(earliest);
```

`:716-717` sets `lastRebalance = block.timestamp` on every fill; `:491` requires only two legs moving; `:492-499`
restricts a non-zero mask to the owner or guardian and never holds them off; `src/WeightedIndexFactory.sol:65`
`MAX_REBALANCE_INTERVAL = 91 days`, enforced at `:182-183`; `src/WeightedMath.sol:119-123` and `:141-143` sum `value`
and check `MIN_TRADE` over the moving legs only. `README.md:459-462`, `ARCHITECTURE.md:251` and `AGENTS.md:354` name
`MIN_REBALANCE_INTERVAL`; `README.md:240` and `:659` tell the app and the runbook to show
`lastRebalance + MIN_REBALANCE_INTERVAL` as the due date, wrong for any non-weekly index.

**Attack path.** A hostile or compromised guardian keeps all but the two smallest legs, its executor fills a two-feed
update at `MU_MAX` at `eta`, and strangers get `RebalanceTooSoon` for the full interval. The owner's only counter is
`cancelRebalance` inside each 2-hour notice; the guardian restarts in the same block, so the owner must land about 84
Safe cancels over `GUARDIAN_DELAY`, and one miss on a quarterly index stalls it 84 days past the replacement. On a
$100M index with two 1 bp legs the sliver costs under a dollar plus gas.

**Impact.** Drift from the weights for up to a quarter while the streaming fee accrues; a compromised guardian reaches
every index. No funds move, holders redeem throughout. The mechanism is the accepted RT-07 and DA-12 trust; what is new
is the bound, 13 times the documented week, and the app's wrong due date. Two verifiers rated it low on that ground
and two medium; it is kept at medium because the stated trust bound no longer holds.

**PoC.** `test/poc/F-04.t.sol`, two tests. A three-leg index with a 91-day interval,
BTC at 9,998 bps and ETH and USD at 1 bp each, 1,000,000 shares:

```
index value, USD: 99999850
ETH sold, USD: 24
USD bought, USD: 26
days locked after the replacement: 84
```

The guardian's keep-mask fill advances the nonce and sets `lastRebalance`; at `lastRebalance + 7 days` the stranger,
the owner and the newly executed guardian all revert `RebalanceTooSoon(earliest)`, with `earliest` 13 times
`MIN_REBALANCE_INTERVAL`; the second test shows the owner's cancel never holds the guardian off, which restarts in the
same block.

**Fix.** Documentation first: state the stall bound as `config().rebalanceInterval` (at most 91 days) in
`README.md:461`, `ARCHITECTURE.md:525`, `AGENTS.md:354`, the hub header (`:76`) and `IWeightedHub.sol:175`; change
`README.md:240` and `:659` to `lastRebalance + config().rebalanceInterval`; keep the RT-07 monitor on a non-zero
`keepMask`. A code change is the owner's call: let a keep-mask fill restart only `MIN_REBALANCE_INTERVAL`, which keeps
the documented bound true at no liveness cost; `MIN_TRADE` against the whole index was considered and rejected in
RT-07 because kept feeds are not read.

## XS-4: a bounded fill pays the parse before its bound, and the keeper retries without a cap (F-09, medium, PoC confirmed)

**Claim.** `_settle` runs `_priced`, Pyth's parse included, before `_checkBounds`, so a bounded fill griefed by a
supply change pays the parse before `RebalanceMovedOn`. The keeper bounds at `amountsIn × 1.001`; an issue of 0.11% of
supply ahead of the fill trips it; the bot ignores a reverted receipt and re-sends next block, with no attempt count or
ETH budget.

**Evidence.** `src/WeightedHub.sol:575-576`:

```solidity
Settlement memory settlement = _priced(priceUpdate);
_checkBounds(settlement.amountsIn, maxAmountsIn);
```

`_checkBounds` (`:623-632`) reverts `RebalanceMovedOn` on `amountsIn[i] > maxAmountsIn[i]`; `WeightedMath._amounts`
(`src/WeightedMath.sol:98-99`) is linear in the supply; `issue` has no auction gate. `keeper/bot/config.mjs:30`
`SUPPLY_TOLERANCE_BPS: "10"`; `keeper/keeper.mjs:263` `M.withTolerance(x, cfg.supplyToleranceBps)`; `:354-364` reads
only `status === "success"` and records nothing on a revert; `:386-398` re-evaluates and re-sends;
`keeper/bot/nonce.mjs` counts no failures. The numbers: a preview of 1,000,000 bounds at 1,001,000; an issue of 0.11%
makes it 1,001,100.

**Attack path.** A griefer holding 0.11% of the basket issues ahead of the public-mempool fill each block, lets the
fill revert after the parse, and redeems in the same block; on a zero-fee index its capital is recycled whole. At 93
legs the keeper burns about 3.2M gas per attempt (2.34M of it the parse, by the anvil measurement of 2026-10-12)
against the griefer's about 8.5M for its issue and redeem; at 3 legs the ratio is near 1:1. A rival executor that
holds the bounded keeper off and fills alone keeps up to 2% of the traded value. A lying RPC simulation has the same
effect with no griefer.

**Impact.** The keeper's hot key, kept at "a few days of gas", can be emptied within hours; the index does not
rebalance through this keeper while the griefing persists; holders' exposure stays inside the documented 2% of traded
value. Two sub-claims were refuted: the streaming accrual cannot breach the bound, because `previewRebalance` folds the
pending accrual at the same timestamp and the accrual is supply-neutral in `amountsIn`, and this keeper's one-block
`deadline` makes a stale quote revert `Expired` before the parse. The exploitability verifier rated the finding low
(operator gas only, configuration workarounds); the other three medium for the uncapped automatic retry. It is kept at
medium as a keeper finding; the hub's ordering is inherent, since the bound is in amounts that need prices.

**PoC.** `test/poc/F-09.t.sol`, one test on the default three-leg index with
`MockPyth`:

```
BTC amountIn quoted: 625000
BTC bound (10 bps): 625625
BTC amountIn after the 0.11% issue: 625688
gas: griefer's issue (3 legs): 137200
gas: bounded fill reverting RebalanceMovedOn (after the parse): 278764
gas: bounded fill reverting NoPendingRebalance (before the parse): 59303
gas: griefer's redeem (3 legs): 163732
```

With Pyth's fee set to 1 and no value sent, the griefed fill reverts inside the parse (`InsufficientFee`) although the
bound is already breached, which pins the order. Six consecutive griefed blocks leave the auction live, the nonce at 0
and the griefer holding six baskets back. Two probes of the accrual sub-claim, a quote with exact bounds at the fill's
timestamp and one 12 s earlier on an index at both streaming caps, both settled, and were removed.

**Fix.** In the executor: a `maxSupply` argument to `KeeperExecutor.fill`, reverting before the hub call when
`index.totalSupply() > maxSupply`, which turns the griefed revert into about one cold read. In the bot: count reverted
fills per `index:proposal` and back off or stop after a few; a daily ETH budget and a balance check before
`tracker.send`; treat a revert after a successful simulation as RPC distrust; a private relay, as DA-13 already
advised; a README line that `SUPPLY_TOLERANCE_BPS` is the griefing threshold. A hub-side supply bound before
`_readPrices` is an owner's option against the hub's size (23.8 KB of 24.6).

## XS-5: kept incoming coins are booked at Pyth, and the route filter selects for the bad ones (F-10, medium, PoC confirmed)

**Claim.** `routes.best` returns `null` when the best route loses more than `ROUTE_MAX_LOSS_BPS` (100) against Pyth; a
`null` route makes a sold leg kept as stock and `inventoryDelta` books it as profit at Pyth. The worse a coin's
on-chain price, the more surely the bot values it at full Pyth and spends USDC to complete the fill. `stockAllowance`
bounds deliveries only, not receipts.

**Evidence.** `keeper/bot/routes.mjs:67`:

```js
const result = pick !== null && routeLossBps(side, pickUsdc, fairUsd) <= cfg.routeMaxLossBps ? pick : null;
```

`keeper/keeper.mjs:157` adds `M.inventoryDelta({ out, in: need, held: h, routed: route !== null })` at the Hermes
price; `keeper/bot/math.mjs:50` makes that `out` when unrouted; `:112` folds it into the floor
(`decision = usdToUsdcCeil(minProfitUsd + gasUsd - inventoryUsd)`); `keeper/bot/requests.mjs:89-91` does the same
for a redeemed basket; `keeper/src/KeeperExecutor.sol:292-306` `_sell` keeps a coin whose route is empty, and
`stockAllowance` is read only in `_acquire` (`:318-321`).

**Attack path.** A creator makes `{Z 50%, ETH 50%}` with `Z` a Wormhole or Binance-Peg copy trading more than 1% under
its coin's feed, with units skewed toward `Z`. After the interval the keeper's own key starts the auction (the start
check also values the kept leg at Pyth); at the fill `Z`'s route is `null`, `Z` is kept at Pyth, the bot buys ETH with
the float, and the creator redeems ETH bought with keeper USDC; up to 20% of `Z` per interval. On the request path a
`requestRedeem` with `minOut` just under Pyth NAV has no turnover cap and no interval. The passive form is a bridge
incident that makes the copy worthless while Pyth prices the coin.

**Impact.** The operator's float is converted into depegged or illiquid coins at feed value, bounded per fill by the
float and, on the auction path, `MAX_TURNOVER` of the attacker's own leg; never index funds (the hub trades at Pyth
either way). `keeper/README.md` does say stock is valued at Pyth; what it does not say is that the quote which rejected
the route is discarded, so the inversion is undocumented. All four verifiers rated it medium.

**PoC.** `test/poc/F-10.t.sol`, two tests, the bot's arithmetic replicated in integer
micro-dollars line for line from `math.mjs`, `routes.mjs`, `keeper.mjs` and `requests.mjs`. `Z` at Pyth $2, on the
mock router $1; 10,000 Z and 1 ETH in the index; a 30,000 USDC float:

```
evaluateStart, best case at MU_MIN, profit (micro-USD): 76999998
bot: inventoryUsd (micro-USD): 3999999999
bot: usdcFloor sent as minUsdcDelta (micro-USD): -3991999999
executor: USDC spent (micro-USD): 3991111112
executor: market value of the kept Z (micro-USD): 1999999999
executor: loss at market (micro-USD): 1991111113
```

The request path loses 9,780 USD at market in one `fillRedeem`. With the kept receipt valued at `min(Pyth, quote)`
in the replicated bot, both tests fail (`evaluateStart` profit `-1923000002 < 5000000`; `inventoryUsd` `10000000000
!= 20000000000`), then reverted.

**Fix.** Value a kept incoming coin at `min(Pyth, best quote)` where a quote exists, or with an operator haircut per
token; a per-token cap on kept value per fill, the receipt-side twin of `stockAllowance`; a relative profit floor so
a large kept leg does not fill at `mu` near 1; refuse a fill whose profit depends on kept inventory above a configured
share; name the adverse selection in `keeper/README.md`'s "Keys and risk".

## XS-6: a cancelled request burns the whole mint fill (F-05, medium, PoC confirmed)

**Claim.** `_mintFor` buys the basket, approves and issues before `REQUESTS.fill`, the first and only place `open` and
`deadline` are checked, so a request closed between simulation and inclusion reverts at the very end. `keeper/README.md`'s
"revert cheaply" holds for auction fills, not request fills.

**Evidence.** `keeper/src/KeeperExecutor.sol:214-232`: `getRequest` at `:215` checks only `isMint`; `_acquire` at
`:223`, the approvals at `:224-226`, `index.issue(shares, address(this))` at `:227`, and only then
`REQUESTS.fill(id, shares)` at `:230`. `src/MintRequests.sol:81-83` checks `open` and the deadline in `fill` alone;
`cancel` (`:100-107`) is the requester's at any time. `keeper/bot/chain.mjs:118` sends through
`eth_sendRawTransaction` with no relay; `keeper/README.md:58-59` says a copier "leaves this bot's transaction to
revert cheaply".

**Attack path.** A requester posts a generous mint request, watches the mempool for the bot's `fillMint`, and lands
`cancel(id)` ahead of it with a higher tip; the bot's transaction runs every swap, every approval and the issue, then
reverts `RequestNotOpen`. The bot does not resend for that id; the attacker posts a fresh request for the next
25-block scan.

**Impact.** A repeatable asymmetric gas drain of the operator's hot key, about 10:1 on ten real V3 legs, up to 60:1
at thirty, bounded by the key's ETH and by switching `FILL_REQUESTS` off; no index or escrow funds. The redeem side is
far cheaper to grief: `_redeemFor` does only `_buyStable` (nothing for USDC), one approve and the balance reads
before `fill` at `:278`. All four verifiers rated it medium.

**PoC.** `test/poc/F-05.t.sol`, three tests on a ten-leg mock index:

```
gas: fillMint after the requester's cancel (burned): 1152018
gas: fillMint of the identical open request (succeeds): 957143
gas: fillMint refused at the executor's first check (Expired): 39350
gas: requester's requestMint: 206149
gas: requester's cancel: 63563
gas: fillRedeem after the requester's cancel (USDC request): 201300
```

The revert data is exactly `RequestNotOpen(id)`, and the trace shows the ten swaps, ten approvals and the issue running
first. Mock swaps are two transfers each, so the mainnet ratio is larger.

**Fix.** At the top of `_mintFor` and `_redeemFor`, revert when `!request.open || block.timestamp > request.deadline`
(the struct is already in memory), which makes a cancel already mined cost about 30-40k; send request fills through a
private relay (they carry no Pyth update); back off a requester whose request closed mid-flight; correct
`keeper/README.md:59`.

## XS-7: the request filter ranks raw escrows across units and reads no gate (F-06, medium, PoC confirmed)

**Claim.** `fillableRequests` sorts on `request.escrow` as a bare integer, stablecoin raw units (6 decimals) for a
mint and shares (18 decimals) for a redeem, and slices to eight before any pricing; escrows are cancellable at any
time, so size is free to fake. Nothing in the bot reads `isGated` or `isAllowedMinter`, so a mint request on a gated
index reverts `NotAllowedMinter(executor)` in every block's simulation while holding a slot.

**Evidence.** `keeper/bot/math.mjs:135-141`:

```js
.filter(({ request: r }) => r.open && BigInt(r.deadline) >= T && served.has(r.index.toLowerCase()))
.sort((a, b) => (b.request.escrow > a.request.escrow ? 1 : b.request.escrow < a.request.escrow ? -1 : 0))
.slice(0, cap);
```

`src/interfaces/IMintRequests.sol:11-13` defines the escrow "in `stable` for a mint and in `index` shares for a
redemption"; `src/MintRequests.sol:130` requires only non-zero amounts and `:24` a deadline within 30 days;
`keeper/src/KeeperExecutor.sol:227` issues to the executor itself, which `src/WeightedHub.sol:249-250` refuses on a
gated index.

**Attack path.** Eight `requestRedeem(index, 1e15, USDC, minOut 2^200, 30 days)` for about 0.008 share and eight
transactions a month; each outranks any mint under `1e15` raw USDC, and every block the bot simulates exactly those
eight and skips them. Without an attacker, any eight open redeems of a whole share starve every mint request, since
`1e18 > 999,999e6`.

**Impact.** The site's first-party filler stops serving `MintRequests` for under $100 a month of gas, and the
operator's Hermes quota is spent on dead requests, the class CF-7 fixed on the auction path; no funds at risk,
requesters keep `cancel`, any other filler may fill. All four verifiers rated it medium.

**PoC.** `test/poc/F-06.t.sol`, four tests. The ranking is pinned verbatim from
`math.mjs` by `vm.readFile` and ported to Solidity over requests the real `MintRequests` recorded:

```
gas of one griefing requestRedeem, at most: 201457
value of one griefing escrow, USD with 6 decimals: 100000
value of the genuine escrow, USD with 6 decimals: 10000000000000
```

Eight redeems worth $0.10 each fill the slice and the $10M mint is absent; each slot's simulated `fillRedeem` reverts
inside `MintRequests.fill` and stays open; the attacker cancels and gets its shares back. On a gated index the real
`KeeperExecutor`'s `fillMint` reverts exactly `NotAllowedMinter(executor)` until the creator allowlists it.

**Fix.** Rank by estimated dollar value (`stable / 1e6`; a redeem via `previewRedeem` at Pyth) with a cap per side;
skip a request whose limit the current preview cannot meet before simulating; remember unfillable ids with a backoff;
pre-read `feeTerms(index, executor).allowed` in the same multicall as `getRequest`; cap `known`; log the requests left
past the cap as `worthChecking` does for auctions.

## XS-8: the keeper's hub slots are stale (F-02, medium, PoC confirmed)

**Claim.** `HUB_SLOTS = {eta: 4n, keepMask: 5n}` names the slots before `f8058b7`, which inserted `Config _config`
(slot 2) and `uint128 _scale; uint40 _lastAccrual` (slot 3) before `claimOf`; `_eta` is now slot 6 and `_keepMask`
slot 7. `checkSetup` overrides slots 4 and 5 (two mapping bases), reads `pendingRebalance()` as `(0, 0)` and throws
before the loop.

**Evidence.** `src/WeightedHub.sol:139-155` orders `_components`, `_terms`, `_config`, `_scale` with `_lastAccrual`,
`claimOf`, `totalClaims`, `_eta`, `_keepMask`; every parent is ERC-7201 namespaced, OpenZeppelin 5.7.0's
`ReentrancyGuard` included. `keeper/bot/config.mjs:17`:

```js
export const HUB_SLOTS = Object.freeze({ eta: 4n, keepMask: 5n });
```

`keeper/bot/chain.mjs:164-168` overrides those slots on the implementation and throws "WeightedHub's storage layout is
not the one the keeper knows" unless `pendingRebalance()` answers `(1234, 5)`; `keeper/keeper.mjs:424`
`setup = await chain.checkSetup();` runs at top level before the loop; `:109` and `:284` use the same slots for the
start simulation, where `previewRebalance` would revert `NoPendingRebalance` from `_openMu` (`:752`).

**Attack path.** None. `npm start` against a factory from `f8058b7` exits at startup.

**Impact.** The shipped auction starter and request filler cannot run; rebalancing and request fills rest on third
parties. Fail-closed, no funds, no on-chain effect. The exploitability verifier rated it low (off-chain tooling, two
constants, caught at first startup); the other three medium as the project's only operational path. It is kept at
medium. The user's memory note on the keeper also records the stale "eta 4, keepMask 5".

**PoC.** `test/poc/F-02.t.sol`, three tests, `vm.store` and `vm.load` standing in for
the `eth_call` state override: `(1234, 5)` written to slots 4 and 5 of `factory.IMPLEMENTATION()` reads back as
`(0, 0)` from `pendingRebalance()`, and as `(1234, 5)` from slots 6 and 7; a live auction sits in slots 6 and 7 with
slots 4 and 5 at zero; the `atMuMax` override on slots 4 and 5 makes `previewRebalance` revert `NoPendingRebalance`,
on slots 6 and 7 it answers `mu == MU_MAX`.

**Fix.** `HUB_SLOTS = Object.freeze({ eta: 6n, keepMask: 7n })`, plus a pin so the next layout change fails a test
rather than the bot: a forge test writing slots 6 and 7 of a clone and reading `pendingRebalance()` (the second PoC
test is one), or `forge inspect WeightedHub storageLayout` compared in CI; then the keeper's end-to-end run before
merging.

## XS-9: the clock has no view and the preview understates it (F-15, low, unproven)

**Claim.** `_lastAccrual` is `uint40 private` with no getter and no ABI entry; `pendingStreamingFee()` evaluates
`_pending` at the current supply, so at dust supply it answers `(0, _scale)` while the clock is stale and the next
accrual will charge. README's valuation note and the request-limit notes inherit the blindness.

**Evidence.** `src/WeightedHub.sol:145` `uint40 private _lastAccrual;`; `:865-867` `pendingStreamingFee()` returns
`_pending(_storedStreaming())`, which reads `totalSupply()` at `:425`; `grep lastAccrual abi/WeightedHub.json` finds
nothing. The window exists only at wei-level supply (about 6,083 wei over a day, 17 wei over a year at 600 bps). The
reset at supply zero (`:400`) emits no event, so event history gives an upper bound only.

**Attack path.** XS-1's setup; the app quotes a zap mint or a `requestMint` limit from `components()` and sees no
pending dilution.

**Impact.** The app cannot warn or price pending dilution. The economic loss is XS-1's; this is the integration gap.
All four verifiers rated it low; raise it to medium if XS-1 is accepted as design, since the getter then becomes the
only defence. Not run: below the PoC threshold.

**Fix.** `function lastAccrual() external view returns (uint40)` in `IWeightedHub` and the hub, `abi/WeightedHub.json`
regenerated and CF-5's hashes updated in the same commit, the hub's size rechecked, and a README note that the app
computes `rate × (now − lastAccrual) / YEAR` as the fee the next accrual takes from the supply it is about to join.

## XS-10: the builder is one custody point with no probe (F-20, low, unproven)

**Claim.** `escrowOf` pools every user's pre-mint and post-redeem baskets in one address. An issuer that blacklists the
builder stops `withdraw`, `sell`'s router pre-fund and `mint`'s pull of that token for everyone; an issuer burn breaks
"the builder's balance covers the sum of the escrows". `deposit` and `buy` have no SA-01-style zero self-transfer
probe, unlike `MintRequests.requestMint`.

**Evidence.** `src/BasketBuilder.sol:44` `mapping(address user => mapping(address token => uint256 amount)) public
escrowOf;`; `:74` `safeTransfer(to, amount)`; `:172-175` `forceApprove` then `issue`; `src/UniversalRouterSwaps.sol:231`
`token.safeTransfer(address(ROUTER), amountIn);`; `:56-63` `deposit` with no probe against
`src/MintRequests.sol:57-60`. README's "Known limitations" name the index and `MintRequests`, never the builder;
`test/BasketBuilder.t.sol` has no blacklist, pause or destroy case.

**Attack path.** Tether blacklists `address(builder)` while XAUT escrows are parked (Tether's `transferFrom` checks
only `from`, so deposits still land and are then stuck); `destroyBlackFunds` then zeroes every XAUT escrow at once.
An Ondo-style recipient check refuses the deposit itself. A `redeem` through the builder of a Tether-pattern leg still
succeeds and lands the leg in the trap.

**Impact.** All escrows of that token frozen for the blacklist's duration; on a burn, lost outright for Tether's code
(whole balance) or first-come-first-served for a partial burn. Only the named token is affected; no attacker profit;
the same issuer trust the owner accepted for the index, but the index has `redeemSkipping` and `claim` as recourse and
the builder has none. All four verifiers rated it low. Not run.

**Fix.** A README "Known limitations" entry for the builder beside the `MintRequests` one; a zero self-transfer probe
in `deposit` and on `buy`'s pass-through leg, checked first against the 92 listed tokens for any that refuse a
zero-value transfer; the app checks `isBlackListed(address(builder))` on XAUT and USDT before offering those paths and
tells a blacklisted builder's user to exit through `redeemSkipping` plus `claim` on the hub.

## XS-11: a failed scan drops a chunk of requests for good (F-28, low, unproven)

**Claim.** `scan()` sets `scanned = count` before the multicall; a request whose read fails is never requested again
until restart.

**Evidence.** `keeper/bot/requests.mjs:28-37`: `scanned = count;` at `:32` precedes `await chain.multicall(...)` at
`:34`. The verifiers corrected the mechanism: viem 2.21.54's `multicall` with `allowFailure: true` does not throw on a
rejected chunk (about 28 `getRequest` calls per 1,024-byte chunk), it returns `{status: 'failure'}` for each id, and
`:40-45` treat any non-success as closed and `known.delete(id)`, with no log line. So nothing reaches the main loop's
catch at `keeper/keeper.mjs:434-438`, and the dropped set is every id in a failed chunk, already known open requests
included, not only `old+1..count`.

**Attack path.** Plain RPC flakiness; a flood of 1-raw-unit requests only adds parallel chunks and a chance of rate
limits, for no gain.

**Impact.** The keeper silently stops serving a set of requests until restart; no funds; requesters keep `cancel` and
`refund`. All four verifiers rated it low. Not run; no unit test covers `scan`.

**Fix.** Treat a `failure` entry as unknown, not closed: keep the known entry, advance `scanned` only to the highest
contiguous id read successfully, log the failed chunk. "Advance after the multicall resolves" alone is not enough,
since the multicall resolves even when every chunk failed; chunking is already viem's.

## XS-12: `clearStuck` trusts the RPC's pending nonce every block (F-37, low, unproven)

**Claim.** `clearStuck` runs on every idle block and sends a real self-transfer whenever `pendingNonce() > latestNonce()`;
an RPC reporting `pending = latest + 1` persistently makes the bot mine a cancel each block and never evaluate a fill.

**Evidence.** `keeper/bot/nonce.mjs:75-93`: `if (pending <= latest) return false;` at `:79` is the only gate, then
`inFlight = { label: "clear stuck nonce", nonce: latest, ... }` and `onBlock`, which sends a 21,000-gas 0-value
self-transfer at the next valid nonce; `keeper/keeper.mjs:365-366`:

```js
if (tracker.busy()) return;
if (await tracker.clearStuck(Number(L.number), nextBase, tip)) return;
```

At 20 gwei base and the default 2 gwei tip, seeded at 2x and bumped 12.5%, a cancel costs about 0.0005 ETH, about
3.7 ETH a day. `keeper/README.md:32-34` describes the clearing as a startup action; `config.mjs:66` accepts an `http://`
RPC. The verifiers added that the cancel path ignores `MAX_FEE_GWEI` (XS-13), so a withholding RPC can raise each
version's price without bound.

**Attack path.** A malicious or intercepted RPC; nothing else can raise the key's pending nonce.

**Impact.** The hot key's gas ETH and a silenced bot; no protocol funds. The bot already trusts the same RPC for every
fill simulation, a larger lever. All four verifiers rated it low. Not run; the unit test's fake chain never models a
persistent lie.

**Fix.** Clear a stuck nonce at most once per process start or per N minutes, and only when the bot remembers an
unmined send; stop and log if a cleared nonce reappears; apply `feeCap` to cancels; require `https://`.

## XS-13: replacement fees have no ceiling (F-38, low, unproven)

**Claim.** `replacementFees` bumps tip and max fee by at least 12.5% every block a cancel is unmined and never caps at
`feeCap`, though `MAX_FEE_GWEI` is documented as a global bound and the fill path honours it.

**Evidence.** `keeper/bot/math.mjs:93-97`:

```js
const bump = (x) => max(ceilDiv(x * 1125n, 1000n), x + 1n);
const tip = bump(prev.maxPriorityFeePerGas);
return { maxFeePerGas: max(bump(prev.maxFeePerGas), 2n * nextBase + tip), maxPriorityFeePerGas: tip };
```

`keeper/bot/nonce.mjs:59-69` sets `f.tx = cancel` even when `_submit` returned `null` on "underpriced", so the next
bump compounds on the refused version; `feeCap` is applied only at `keeper.mjs:182, 203, 342, 345` and
`requests.mjs:136, 154`; `keeper/README.md:90` says "No transaction while the base fee and tip exceed this". After
100 unmined blocks the tip is about 261,000 gwei; the version at that height costs about 5.5 ETH if the key holds it,
and EIP-1559's balance check caps the loss at roughly `balance × tip / maxFee`.

**Attack path.** A withholding RPC that accepts each cancel, propagates none, and forwards the dearest signed version.
On an honest network a 21k self-transfer mines within a block or two of clearing market.

**Impact.** Bounded by the hot key's ETH; no protocol funds. The 2026-10-13 audit listed "a cap on replacement fees"
among unchecked hand-offs, not acted on; the exponential growth and the withholding path are new. All four verifiers
rated it low. Not run.

**Fix.** Pass `feeCap` into `replacementFees`, cap both fields, stop bumping after N blocks and alert; treat
"insufficient funds" as a halt rather than a per-block retry; a unit test with a ceiling (the existing ones pin
"bumped again" only).

## XS-14: a redeem-fee mutant the suite does not kill (F-29, low, unproven)

**Claim.** With `_redeem`'s `_feeTerms` call reduced to `if (feeShares != 0)`, a redeem whose exit fee rounds to zero
leaves `creator = platform = address(0)` and `_mintFeeShares` falls back to `to`, so the whole streaming fee goes to
the redeemer. `test_aDustRedeemStillAccruesTheStreamingFee` asserts only the event and the supply, both unchanged.

**Evidence.** The shipped `src/WeightedHub.sol:316` is correct:

```solidity
if (feeShares != 0 || _streaming(cfg) != 0) (, creator, platform) = _feeTerms(to);
```

`test/WeightedHub.fees.t.sol:791-802` redeems 10 shares at 125 bps (fee 0) and asserts `StreamingFeeAccrued` and
`totalSupply() == supply + feeShares - 10`, identical under the mutant. The invariant suite would catch it only when
the fuzzer draws a redeem under 80 shares after a warp. Under a zero exit fee with a streaming rate, every redeem of
any size would misroute the fee, and no test redeems on such an index.

**Attack path.** Verification only; no live defect.

**Impact.** A regression of this shape would hand up to 6% a year of an index to whoever redeems dust, undetected by
the deterministic suite; the coverage gate would not notice, since dropping a disjunct removes no line. All four
verifiers rated it low or informational. Not run.

**Fix.** In the dust test, also expect `FeeSharesMinted(address(0), creator, platform, ...)` and assert the creator's,
the platform's and alice's exact balance deltas; add the same on a zero-exit-fee streaming index.

## XS-15: a builder-redeem mutant the suite does not kill (F-30, low, unproven)

**Claim.** Mutating `src/BasketBuilder.sol:203` to credit `balanceOf(address(this))` instead of the delta survives:
every redeem test starts from a builder holding none of the components, and the one second redeem with LINK still
escrowed asserts nothing about LINK afterwards.

**Evidence.** The shipped line is correct:

```solidity
escrowOf[msg.sender][tokens[i]] += IERC20(tokens[i]).balanceOf(address(this)) - before[i];
```

`test/BasketBuilder.t.sol:621` (`test_redeemCreditsEveryComponentAsItArrives`) issues through `_issueTo`, so the
builder holds zero before; the second `_redeemFor` at `:701` would credit LINK `3e18` against `2e18` held, and the
lines that follow assert only two reverts on other legs; `_assertCovered` is never called after a redeem. Under the
mutant bob's deposit of 1 WETH is credited to alice's next redeem and `withdraw` pays it out.

**Attack path.** Verification only; no live defect.

**Impact.** A theft-class regression would pass CI. All four verifiers rated it low. Not run.

**Fix.** Have bob hold an escrow of each component before alice redeems; assert `escrowOf(alice, token) == got[i]`,
bob's unchanged, and `_assertCovered` per token; assert LINK equals `2 × got[2]` after the second redeem.

## XS-16: the invariant handler's gaps for the engine (F-58, info, unproven)

**Claim.** The handler never uses a gated index, never calls `transferCreator` or `setFeePolicy` mid-run, never settles
after a capped accrual, never drives the builder or `MintRequests` with the hub, and never leaves the supply at a few
wei before a long warp; `_clock` copies the dust rule, so XS-1 is invisible.

**Evidence.** `test/WeightedHub.invariant.t.sol:85-87` `if (feeShares != 0 || supplyBefore == 0) _lastAccrual =
block.timestamp;`; `:133` the referrer toggle; `:510-514` a 20-year warp ending at `accrueFees`, never a fill; the
index is created `gated: false`; `warp` is bounded to 7 days per call at depth 32, so a capped accrual (16.7 years at
600 bps) is unreachable under fuzzing. One correction: the pending fee at the walk's bounded fill is about `1.46e13`
shares on about `1.06e18`, not `4.2e13` on `3e18`.

**Attack path.** None.

**Impact.** Unseen regression classes: fee misrouting after a creator transfer, scale handling after a capped accrual,
builder escrows across a real settlement. Each surface has a unit test; none has random-interleaving coverage, and
`ARCHITECTURE.md:564-569` and the engine record claim more of the suite than it does. Not run.

**Fix.** Actions for `setAllowedMinter` and `openMinting` on a second, gated index; `transferCreator` and
`setFeePolicy` with the ghost recipients updated; `warpLifetime` then `executeRebalance`; a builder handler asserting
`balanceOf(builder) >= Σ escrows`; a redeem-to-dust action before a long warp with a clock model independent of the
hub's rule.

## XS-17: the known-limitations test pins only the heading (F-63, info, unproven)

**Claim.** `test_I09_theKnownLimitationsAreDocumented` asserts `_contains(readme, "Known limitations")` and nothing
else, so every bullet can disappear or go stale unnoticed.

**Evidence.** `test/Repo.t.sol:92-95`:

```solidity
assertTrue(_contains(readme, "Known limitations"), "the README keeps its known limitations section");
```

The substring also appears in a cross-reference at `README.md:187`, so even deleting the whole section leaves the test
green. Stale today: `README.md:449` "a fresh index cannot rebalance until 7 days after its creation" (the gate is the
index's own interval, `src/WeightedHub.sol:484`); no bullet on the dust clock, the capped accrual, or the referrer and
gate rules the design records carry.

**Attack path.** None.

**Impact.** The one test for user-facing limitations enforces nothing about their content. Not run.

**Fix.** Pin each limitation's anchor phrase with one `assertTrue(_contains(...))` per bullet, as the other Repo tests
pin configuration lines, after correcting `README.md:449` and adding a streaming-fee bullet.

## XS-18: the invariant is stated without the scale, and hub facts are stale (F-64, info, unproven)

**Claim.** `ARCHITECTURE.md:396`, `README.md:139` and `src/WeightedHub.sol:40` give
`balanceOf >= floor(totalSupply × units_i / 1e18) + totalClaims` while `_backing` is
`mulDiv(shares, units * scale, SHARE_UNIT * WAD, rounding)` (`:947`). Also stale: `ARCHITECTURE.md:79` (`initialize`
without `config`), `:151` (`MintParams` without `referrer`), `:219` ("No filler is built yet"), `:529` ("eight entry
points", now ten), its backlog (the builder and the fees exist); `IIndexZap.sol:19`, `:30`, `:52` name "the rule",
retired at Stage A.

**Evidence.** As cited, each line verified. `ARCHITECTURE.md:72-74` does define `units_i` as the raw amount "times
`_scale`", so its formula holds under its own definition; the hub header and README define no such thing, and read
with stored units the header's bound is false after any accrual (a 1% accrual on 100e18 shares demands 101.01e18
against a balance of 100e18, while the code demands 100e18). The "eight" matches `test_R11_everyEntryPointIsGuardedDuringTheCallback`
(`test/WeightedHub.rebalance.t.sol:780`), whose probe (`test/mocks/MockWeightedExecutor.sol:86-95`) omits
`accrueFees()` and `issue(uint256,address,address)`, both guarded in code (`:440`, `:241`): a coverage gap behind a
correctly named claim (F-59, under Contested).

**Attack path.** None; a reviewer verifies a bound that is too strong after an accrual, not too weak.

**Impact.** Documentation drift that misleads verification. Not run.

**Fix.** Write the invariant with `scale / 1e36` in the hub header and README, as `AGENTS.md` does, or define `units_i`
as `components()`'s scaled units; fix the five ARCHITECTURE lines and the backlog; drop "the rule" from the three
`IIndexZap` lines (the 2026-10-13 audit already noted two of them); extend the R11 probe to ten and the sentence to
"ten".

## Contested

Findings both code-truth verifiers confirmed and the exploitability verifier refuted. Each stands as a fact about the
code; none is exploitable on this commit as the verifier read it. The counter-view is given where the refutation
leans on something weaker than the code.

- **F-08, the zap and the builder never pre-check the gate (low).** True: `BasketBuilder.buy` (`:82-86`) and
  `IndexZap._checkCommon` (`:207-218`) never read `isGated` or `isAllowedMinter`; the gate is read once, in
  `WeightedHub._issue` (`:249-250`), after every swap; `setAllowedMinter` (`src/WeightedIndexFactory.sol:217-221`) is
  creator-only with no delay, so a creator can revoke between a user's `buy` calls and its `mint`. Not exploitable: the
  only actor is the creator against a minter it chose to admit, it earns nothing (swap fees go to pool LPs), the
  escrow stays intact and leaves in kind through `withdraw`, and the zap variant costs one reverted transaction's gas,
  zero if simulated first. Counter-view: a pre-check in `_checkCommon` via `feeTerms(index, to)` would still save up
  to 35 legs of swap gas on a never-allowed `to` and costs one STATICCALL; the README's frontend notes carry no
  basket-builder section at all, and should say the allowance is revocable without delay.
- **F-11, the gate binds only `issue`'s `to` (low).** True: `_mintFeeShares` (`:461-472`) mints to the creator, the
  platform and a minter-chosen referrer with only `_isTrap` as a filter, and `MintRequests.fill` transfers shares with
  no gate, while `README.md:80` and `AGENTS.md:323` say a gated index "issues only to allowed recipients". Not
  exploitable: transfers are ungated by design (the engine record, `:329-331`), an allowed minter can hand shares to
  anyone anyway, every fee share is backed by the minter's deposit, and the keeper's executor must itself be allowed
  or its `issue` reverts. The residue is wording: the gate was never membership control, and the records should say
  that fee recipients, a referrer, request fills and transfers sit outside it.
- **F-12, `setFeePolicy` is instant and its recipient is read live (low).** True: `setFeePolicy` (`:247-266`) has no
  eta and no window, `feeTerms` (`:238-244`) returns `platformFeeRecipient` live, `createIndex` reverts
  `WrongCreationFee` on any fee change (`:143`), and `referralShareBps` sits in the salted `Config` with no creator
  bound, so a policy change between `predictIndexAddress` and `createIndex` lands the index elsewhere; the engine record
  (`:309-310`, `:340`) promises a timelock the build did not add. Not exploitable: the only actor is the owner Safe, the
  redirected shares are the platform's own fee, a timelock would protect nobody against the owner, and nothing in the
  repository pre-funds a predicted address. Counter-view: the ADR divergence is real and `IWeightedIndexFactory.sol:28-30`'s
  "a policy change cannot land on an index between its quote and its creation" is false for the referral share; a
  `maxReferralShareBps` or `maxCreationFee` in `IndexParams` and a corrected record close it cheaply.
- **F-13, recipient checks diverge across the three entry points (low).** True: `IndexZap._checkCommon` (`:214-216`)
  refuses the zap, `p.index`, the router, the PoolManager and the factory but not another factory index;
  `WeightedHub._isTrap` (`:797-799`) refuses only the index itself and the factory; `BasketBuilder._checkRecipient`
  (`:286-292`) adds `FACTORY.isIndex(to)`; shares or a payout sent to another index can never leave it. Not
  exploitable: `to` is chosen only by the caller, a hostile front-end that can set it to an index can set it to itself,
  and nobody can collect the stranded value. The one-line fix (`FACTORY.isIndex(to)` in `_checkCommon`) is still worth
  taking; `IIndexZap`'s "the rule" text should go with it.
- **F-14, the invariant suites check a weaker bound than `AGENTS.md` states (low).** True: both suites check
  `mulDiv(supply, components()[i], 1e18)`, and `components()` floors at the pending scale, so the checked bound sits
  below `floor(S·u·s/1e36)` by up to `S/1e18` raw units per leg, exactly XS-2's magnitude, and transiently by
  `S/(S+F)` while a fee is pending; no view returns the raw units. Not exploitable: the hub maintains the exact bound
  on every path, the gap is dust against a persistent under-backing, and the transient part cannot hide a shortfall
  that never heals. `_assertBackedWithin` (`fees.t.sol:615-624`) already checks the full-precision form once; the
  suites should check it everywhere, which a test can do with `vm.load` on `_scale` and the stored units.
- **F-16, README and ARCHITECTURE still describe the cadence as 7 days (low).** True at `README.md:76, 166, 240, 449,
  659` and `ARCHITECTURE.md:251, 435`, contradicting `README.md:80`. Not exploitable: the chain enforces the right
  interval and `RebalanceTooSoon(earliest)` names the true date; the keeper reads `canStartRebalance` and is
  unaffected. Folded into XS-3's fix.
- **F-17, README's struct, event and error listings omit the engine's additions (low).** True: `README.md:266` and
  `ARCHITECTURE.md:151` list eight `MintParams` fields where `IIndexZap.sol:33-43` has nine, and the events and
  errors notes omit six events and eleven errors the committed ABIs carry. Not exploitable: README tells the app to
  decode with the committed ABIs, which CI regenerates and checks; an eight-field encoding of the nine-field struct
  even decodes, with `referrer` read from the tail. The prior-knowledge verifier found the same class fixed twice
  (XA-44, CR-I15) with no test on the prose, which is why it recurred; a Repo test grepping each ABI's names against
  the notes would stop the third recurrence.
- **F-18, the flow notes say nothing of fees, the streaming fee, the referrer, the gate or the creation fee (low).**
  True: `README.md:75` and `:144` still give `createIndex(name, symbol, components)`, `:224` values from `components()`
  with no word that `previewIssue` is gross (`ceil(shares × 10000 / (10000 − fee))`) and `previewRedeem` net, and
  `:356` suggests a request limit 1% under value with no word that an in-kind filler pays up to 1.266% gross. Not
  exploitable: every consequence is a revert or a fee the index legitimately charges, `cancel` returns an unfillable
  request at once, and a share holder can still fill it. Documentation only, but the Create, Mint and Frontend sections
  need rewriting before any app ships against them.
- **F-19, `IndexCreated` carries `listed` but not `gated` (low).** True: `src/WeightedIndexFactory.sol:153` sets
  `isGated[index] = true` with no event and `:156` emits `listed` only, so a log-only indexer cannot tell a gated index
  at creation; `MinterAllowed` does not even imply gating, since `setAllowedMinter` has no `isGated` check. Not
  exploitable: the zap mint reverts atomically, the request's escrow is cancellable at any time, the keeper simulates
  and skips, and the allowlist is mutable after creation so a state read at mint time is required regardless. Adding
  `bool gated` to the event is harmless hygiene; the real rule for the app is `feeTerms(index, to)` before any mint
  path.
- **F-22, the creator role is a single key with a one-step transfer (low).** True: `transferCreator` (`:206-213`)
  refuses only zero, the factory and an index and writes `creatorOf` at once; every later creator fee share is minted
  to an address that cannot move them, and on a gated index nobody can call `setAllowedMinter` or `openMinting`
  again; the factory itself is `Ownable2Step` for its owner. Not exploitable: self-inflicted, holders unharmed,
  already-allowed minters keep minting, and an owner reset would be a power over fee recipients the design refuses.
  A `pendingCreatorOf` plus `acceptCreator` handshake and a documented no-recovery note are cheap.
- **F-26, `BasketBuilder.redeem` reads every component's balance before and after (low).** True: `:193-196` and
  `:202-204` call `balanceOf` on all n components, so a token whose `balanceOf` reverts while `transfer` works blocks
  the builder's redeem where `hub.redeem` (`WeightedHub.sol:345-348`) succeeds. Not exploitable: the revert lands before
  the shares move, the user exits through the hub, and in the realistic break (a withdrawn implementation) `transfer`
  reverts too and the documented `redeemSkipping` route applies; the proposed skip mask would need the builder to call
  `redeemSkipping`, which the design forbids. One NatSpec line on `redeem` naming the exit suffices.
- **F-31, `fillRedeem` selling the full balance would survive the keeper suite (low).** True: `keeper/src/KeeperExecutor.sol:282`
  sells `got[i] = balanceOf − held[i]`, and the mutant selling `balanceOf` passes `keeper/test/KeeperExecutor.t.sol:753`
  and `:774` because neither gives the executor prior stock of a routed coin; `_sell` never reads `stockAllowance`, so
  the dump would not be bounded by CF-1's allowance. Not exploitable: the shipped code is correct and the only party a
  regression would hurt is the operator. Worth the test the finding proposes.
- **F-36, `CheckToken` has no class for a transfer-fee switch (low).** True: `script/CheckToken.s.sol:565-661` names
  no `setParams`, `basisPointsRate` or `maximumFee`, the transfer simulation runs at today's parameters, a fee
  switched on later makes every mint path of every index holding the token revert `TransferAmountMismatch`
  (`WeightedHub.sol:277-279`), the keeper delivers exactly `amountsIn` (`KeeperExecutor.sol:176`) so a growing leg
  reverts `RebalanceUnderfunded`, and redeem pays gross. Not exploitable: only the issuer can switch a fee on, and the
  owner accepted strictly larger powers (blacklist and destroy) on XAUT and Ondo's tokens on 2026-10-10; exits still
  work and the keep mask routes around the leg. Whether XAUT's implementation carries `setParams` could not be read
  without an RPC; a FEE class routed to review, a README sentence, and a padding or refusing keeper leg are the
  hygiene.
- **F-39, Hermes' `parsed` prices are trusted for sizing, inventory value and route fairness (low).** True:
  `keeper/bot/hermes.mjs:68-83` returns `body.parsed` beside the signed `binary` with no comparison, and `keeper.mjs`
  and `requests.mjs` size, value and gate routes on `parsed` while only `binary` is verified on chain. Not exploitable:
  the liar must be Pyth's own Hermes or a TLS break, and the fill's `usdcDelta` and floor come from an `eth_call` with
  the signed update, so the executed outcome is bounded by the real pools and the real prices; a lie only defeats the
  route-loss and profit decisions. The 2026-10-13 audit listed this hand-off as unchecked; the fix is an `eth_call` to
  Pyth's `parsePriceFeedUpdates` with `sim.updates` and a rejection of a differing `parsed`.
- **F-41, `previewIssue` can exceed `issue`'s pull inside one zap transaction (low).** True: the zap sizes from
  `previewIssue` (`IndexZap.sol:90`), approves `need[i]` (`:112`) and issues last (`:81`); if a callback during the
  swaps mints onto a dust supply whose clock was kept, the issue's `_accrue` lowers `_scale` and pulls less than
  `need[i]`, and the difference stays in the zap, which never pays out an unmeasured balance; the builder's `mint` has
  the same shape through `forceApprove`. Not exploitable: nobody can reach the stranded surplus, the minter loses no
  more than XS-1 would have taken, callback tokens are refused by `CheckToken` and absent from the list, and XS-1's fix
  removes the trigger. Measuring what `issue` pulled and refunding the surplus is a cheap hardening to take with that
  fix.
- **F-44, a capped lifetime accrual floors low-unit legs to zero (low).** True: `_pending` (`:429-431`) caps
  `part = whole − 1`, which divides the scale by `315,360,000,000` (to `3,170,979`; a second gap floors it to 0); at
  that scale `_unitsAt` floors any leg under about `3.15e11` raw units to zero, `_targets` values it at zero and buys
  it from scratch, the old balance is stranded, an all-zero settlement passes `MIN_TRADE` (`0 < 0` is false), and at
  `_scale == 0` every `_backing` is zero; the empty-index restart never resets `_scale`. Not exploitable: it needs 16.7
  idle years at the 600 bps cap with no issue, redeem, settlement or anyone's `accrueFees()`, and after the cap the fee
  recipients own all but `1/whole` of the index anyway. A clamp of the scale at 1, a `value == 0` revert in
  `_targets`, and `_scale = SCALE_ONE` on the empty-index restart cost nothing and close an unguarded extreme.
- **F-45, the factory NatSpec says the salt commits to the gate (info).** True: `src/WeightedIndexFactory.sol:29-32`
  and `:372-373` list "its gate" among the salt's terms; `_contents` (`:374-380`) hashes `inits` and a `Config` with
  no gate field; `AGENTS.md:261` and two tests pin the opposite, and a gated and an open twin collide with
  `IndexAlreadyExists`. Not exploitable: the salt binds the creator, the collision reverts before any state, and the
  gate is mutable so a salt term for it would be wrong. Fix the two comments.
- **F-46, fee recipients are validated only against the index and the factory (info).** True: `_mintFeeShares`
  (`:461-468`) neutralises a referrer only when `_isTrap`; the zap and the builder forward `referrer` unscreened;
  `setFeePolicy` and `transferCreator` refuse zero, the factory and `isIndex` at set time only, not the implementation,
  `WeightedMath`, the periphery or a predicted index; shares minted to the router are swept by the next `SWEEP`
  caller, and the creation fee to a clone or the implementation reverts `FailedCall`. Not exploitable: the referrer's
  shares come from the platform's part the minter may already direct anywhere, and the owner or creator who names a
  bad recipient loses only its own fee. Screening `referrer` with the `to` set in the zap and the builder, and
  `IMPLEMENTATION` in the factory setters, is cheap; `FACTORY.isIndex` in `_mintFeeShares` costs a STATICCALL on a hub
  near its size limit.
- **F-47, the streaming rate is realised in full only on a single accrual (info).** True: each accrual mints `f` of the
  index as of that moment, so n equal accruals give recipients `1 − (1 − r/n)^n`: 6.00% on one, 5.91% on two, 5.82%
  continuous at 600 bps, and more than the nominal on a multi-year gap. Not exploitable: holders never pay more than
  the nominal rate per year, recipients cannot suppress accruals, and the per-gap simple-interest form is the Set
  Protocol convention the engine record cites. One NatSpec sentence on `Config` that the rate is per accrual and an
  upper bound per year.
- **F-48, spec section 6 describes a pricing library the code no longer has (info).** True:
  `design/2026-10-05-custom-weights.md:163-167` cites `WeightedPricing`, a negative-power refusal, NEAR's 24 decimals
  and V5R-I1; the hub refuses `expo` outside `[−18, 0]` (`:692`) and decimals above 18 at listing and at `initialize`,
  so the power at `:702` is always in `[0, 36]`. Not exploitable: prose in a design record. Rewrite the bullet to the
  current rule and sweep the record's section 9 with it.
- **F-56, five mutants that survive by construction (info).** True and equivalent as the code stands:
  `_checkBacking` at `_scale` instead of `WAD` (`_applyRebalance` sets `_scale = SCALE_ONE` at `:715` before the check
  at `:740`, under the guard); the builder's escrow debit moved after `issue`; `_unsold` crediting `msg.sender` instead
  of `ctx`; the keeper's allowance decremented after the swap; `_filling` left set. Not exploitable. Record them as
  equivalent, with a comment at `:740` that `WAD` is load-bearing only if the order of `_applyRebalance` and
  `_checkBacking` ever changes.
- **F-57, the gate test does not exercise "allowed payer, disallowed recipient" (info).** True:
  `test/WeightedHub.fees.t.sol:407-413` disallows alice before she mints to the stranger, so both are disallowed and a
  `_feeTerms(msg.sender)` mutant passes; only `test/BasketBuilder.t.sol:609-612` kills it. Not exploitable: the
  shipped gate reads `to`. Keep alice allowed for that block and add the mirror case.
- **F-59, the reentrancy probe omits `accrueFees` and the referrer `issue` overload (info).** True:
  `test/mocks/MockWeightedExecutor.sol:86-95` tries eight entry points; the hub has ten `nonReentrant` functions, so
  dropping the guard from `accrueFees()` or `issue(uint256,address,address)` survives
  `test_R11_everyEntryPointIsGuardedDuringTheCallback` (`:780` asserts 8). Not exploitable: both carry the guard, and
  even unguarded a nested `accrueFees` inside the callback would mint nothing (the settlement accrued in the same
  block). Add the two calls and expect ten; update `ARCHITECTURE.md:529` and the R11 row of the v4 retirement record.
- **F-61, a late or front-run keeper fill is not cheap for a wide update (info).** True: `Expired` and `_openMu`'s
  reverts precede the parse, but EIP-7623's floor is paid on a revert, and a 30.9 KB update carries about 117k calldata
  tokens, a floor of about 1.2M gas (1.35-1.4M with the call's ABI), against the e2e's `late.gasUsed < 150_000n`
  (`keeper/test/e2e/run.mjs:463`), which holds only for its four-feed index; `keeper/README.md:19` and `:59` say
  "reverts cheaply". Not exploitable: a competitor pays a full fill to cause one wasted send, the bot's own `txGasUsed`
  (`math.mjs:67-70`) prices the floor correctly for a successful fill, and a late slot is usually replaced by a 21k
  self-transfer. State the floor in the README and scale the e2e bound to the update's size.

## Already recorded

Findings the prior-knowledge verifier matched to an existing record with the same mechanism and the same or a wider
impact, the code matching the record. Each line names the record.

- **F-07**, an issuer burn makes a leg unrebalanceable, keeps issue open into the hole and turns claims into a race:
  CF-3 (`audit/2026-10-13-security-audit.md:62-73`), README "Issuers can freeze components, and some can burn them",
  `AGENTS.md`'s corporate-action rule, `test_CRI30_aSettlementStillDemandsTheBackingItOwes`. Residue: `IWeightedHub.sol:289`
  "Always covered by the index's balance" is unconditional and should be qualified.
- **F-21**, a relisting needs `delist` first and the guardian can veto it: XA-03 (`test_XA03_relistingAlwaysTakesAFreshProposal`),
  XA-11, DA-12, `README.md:386-388`, `ConfigureWeighted`'s RT-06 header.
- **F-23**, `MintRequests` accepts a request on a gated index that only an allowed filler or a holder can fill:
  `AGENTS.md:325` and the engine record (`:329-331`), which place transfers and fills outside the gate by design;
  the escrow returns on `cancel` or `refund`.
- **F-24**, `CheckToken` refuses blacklist+destroy only and lets single-key upgrade or mint powers pass: the owner's
  decision of 2026-10-06 (`design/2026-10-05-wide-asset-support.md`, section 6 item 3), `test_verdictOf`, the
  per-token notes in `script/MainnetAddresses.sol`.
- **F-25**, `CheckToken` does not follow SNX's `setTarget`: `audit/2026-10-13-security-audit.md:153`, a hardening note
  not acted on; the owed source reading of the 2026-10-10 cohort is its compensating control.
- **F-27**, Wormhole copies of Binance-Peg coins carry a mint key one chain away: `AGENTS.md`'s XRP decision of
  2026-10-14, the admission report's hand-read mint keys, `audit/2026-10-13-security-audit.md:135`, CR-L05.
- **F-32**, an empty or dust index's auction can be filled by any contract with a non-reverting fallback: R14 and
  XA-27 (`test_R14_XA27_anEmptyIndexSettlesAtMuMax`), `README.md:451`, CF-7's filter in the keeper.
- **F-33**, listing decimals are read once at proposal and never re-read: RT-01's trade-off, the retirement of RT-23's
  `DecimalsChanged` at Stage A, `test_executeListingKeepsTheDecimalsReadAtProposal`, the runbook's veto row.
- **F-35**, `BasketBuilder.redeem` carries no `expectedNonce` or deadline: RT-02 (`README.md` "An exit sent during the
  auction can be overtaken by the fill"); `redeem` chooses no route or limit, and `sell` carries its own.
- **F-40**, a `null` route is cached for a whole auction: `audit/2026-10-13-security-audit.md:144`, a hardening note
  not acted on; the start decision is not parked, since `forget` runs every block.
- **F-42**, request fills carry no per-leg bound: CF-1's allowance as the stated bound, `keeper/README.md:52-56`
  ("which a request fill spends like an auction fill"), `test_fillMintDeliversFromStockFirstWithinTheAllowance`.
- **F-43**, legs priced at a feed for another asset than the token held: the admission report's feed rule for the six
  share-priced Ondo tokens, CF-3, README "Price id" and "A wrong price costs at most the turnover cap", the
  Bridged tier for CRO and RENDER.
- **F-49**, an exhausted budget pre-funds the router with zero and surfaces the pool's error: CR-I31
  (`test_CRI31_aBudgetExactlyCoveringThePassThroughLegIsEnough`), `AGENTS.md`'s "Swap failures reach the caller
  unchanged".
- **F-50**, `checkOwner` accepts any non-Safe contract on mainnet: XA-39 and XA-07 (`audit/triage.md`), the
  `checkOwner` NatSpec, `test_XA39_rolesCannotBeMarketContracts`.
- **F-51**, a stranger's maskless start on a frozen-leg or closed-feed index costs 26 h only while the guardian
  sleeps: README "Known limitations" and the runbook's "Rebalance around a frozen component" row,
  `testFork_drill_aFeedGoesSilent`, XA-02.
- **F-52**, `MIN_TRADE` has no supply term and a redeem front-run shrinks both amount arrays: DA-13, RT-02, V5-L2,
  V5R-1, R14 and XA-27; a confirmation, no fix required.
- **F-53**, a transfer that returns true and moves nothing pays redeem, claim and `amountsOut` nothing: the recorded
  issuer trust (README "Wrapped legs rest on Wormhole", the trust tables, design decision 3 of 2026-10-06), whose
  reach is the whole leg.
- **F-54**, the executor's one-slot price option spans clock skew and late proposal: V5-L1, the spec's sections 5.6
  to 8, README "A lone executor can take up to 2% of what it trades"; the replay study before launch is already
  planned.
- **F-55**, `CheckToken`'s beacon-proxy wording hides Wormhole's upgrade power: `audit/2026-10-13-security-audit.md:149`,
  a hardening note not acted on; README "Wrapped legs rest on Wormhole".
- **F-60**, `proposeGuardian` accepts any address: XA-61 (an owner may install any guardian after `GUARDIAN_DELAY`),
  DA-12, the deploy script as the home of the role checks (XA-39, CR-I37, SA-06, FR06); a guardian set to zero is
  allowed on purpose.
- **F-62**, `fillMint`'s `shares` is unbounded above the request's limit and `_acquire` spends the whole float:
  `keeper/README.md:52-57` ("or request a mint of one"; "trade the USDC float badly within the floor it sets
  itself"), CF-1.
- **F-65**, an uncaught startup error prints the RPC URL: `audit/2026-10-13-security-audit.md:143`, a hardening note
  not acted on.
- **F-66**, the hub cannot receive ether, so a Pyth refund of excess would brick every fill: `AGENTS.md` "Every payable
  path forwards the whole of `msg.value` to Pyth", `test_theFeeGoesToPyth`, the recorded trust in Pyth's governance;
  the on-chain fee is zero today.

## Refuted

- **F-34**, `createIndex` copies the terms in force at inclusion and an executable relisting can be executed just
  before the creator's transaction. Both code-truth verifiers refuted it: `_proposeListing` accepts a proposal only
  for a token that is not whitelisted (`src/WeightedIndexFactory.sol:400`, `AlreadyListed`), `delist` clears only the
  whitelist, so a pending relisting implies the token is delisted now, and `createIndex` with that token reverts
  `TokenNotWhitelisted` in `_validateComponents` before any terms are read. A stranger's `executeListing` can only turn
  a creation that would have reverted into one that succeeds on terms the owner proposed and anyone could read for two
  days; it never swaps the terms of a transaction that would otherwise have created an index
  (`test_createIndexRefusesAnUnlistedOrDelistedToken`, `test_aRelistingReachesOnlyNewIndexes`).

## What this audit could not settle

All eight proofs of concept ran and confirmed their findings on mocks; none was infeasible. The ten findings below
medium were traced by reading and not run. Beyond that, without an RPC, a fork or external sources:

1. The deployed Pyth proxy's `parsePriceFeedUpdatesUnique` semantics (uniqueness on `prevPublishTime`, behaviour with
   no update in the window, fee and excess handling, accumulator updates) and Hermes' at-time endpoint, which the
   vendored interface at `2bb0eb54` and `MockPyth` only model.
2. Universal Router 2.0.0, v4-periphery and v4-core internals the engine's comments assert (a `SWEEP` of the whole
   balance, `OPEN_DELTA` settle and take, the per-hop `amountInMaximum` of upstream #564, the dynamic-fee flag on a
   hookless key), none vendored in `lib/`.
3. The verified source of the 92 listed tokens: whether XAUT carries Tether's fee switch, what Ondo's compliance and
   corporate-action mechanisms do to an index address (CF-3), the Wormhole beacon owners, SNX's `TokenState`, and the
   44 tokens `CheckToken` alone admitted whose source the owner has yet to read (CF-4). Look-alike addresses are
   pinned only by symbol and decimals in a fork test nobody ran at `f8058b7`.
4. The five fork suites and the keeper's end-to-end test after the engine refactor, the accrual in `_settle` and the
   deploy script change. The fork suites hold no fee, streaming, gate or builder scenario on real tokens, the builder
   has no fork test at all, and gas at 100 components with fees, a gate and a streaming fee is unmeasured (the 13.1M,
   5.1M and 4.8M figures use zero-fee parameters).
5. The size of XS-1's charge and XS-2's strand on mainnet depends on the app's share sizing (wei-shares per index),
   which lives in the other repository.
6. Product calls only the owner can make: whether `setFeePolicy` is meant to be instant (F-12), whether fee recipients
   and referrers may sit outside a gated index's allowlist (F-11), whether XS-1 and XS-2 are fixed or accepted before
   mainnet, whether a keep-mask fill should restart the index's interval (XS-3), and section 9 of the engine record.
7. The installed viem 2.21.54 `multicall` and block-override behaviour against a live RPC, and Pythnet versus Ethereum
   clock skew.
8. The supply chain was read and found pinned (actions by SHA, Foundry v1.8.1, locks checked both ways, ABIs
   regenerated by CI, OpenZeppelin 5.7.0's `ReentrancyGuard` on a namespaced slot); what a read-only pass cannot
   confirm is the `evm_version = cancun` target against the chain's fork at deploy time, the duplicated Wake config in
   `.vscode/settings.json`, and the reproducibility of CF-5's release hashes across machines.

## Next steps

1. Fix XS-1 in `_accrue` (reset the clock on an accrual that mints nothing), add `lastAccrual()` (XS-9), update the
   handler's `_clock`, the fees test, `AGENTS.md` and the NatSpec, and move `test/poc/F-01.t.sol`'s assertions into
   the fees suite as the regression.
2. Decide XS-2 with the owner: keep `_scale` across settlements and apply it in `_amount`, or document the bound and
   raise `MIN_RAW_UNITS`; either way add the surplus regression after a fill at scale below `1e18` and correct the
   keep-mask sentence.
3. Correct the stall bound and the due-date formula in README, ARCHITECTURE, `AGENTS.md`, the hub header and
   `IWeightedHub` (XS-3, F-16); the owner decides whether a keep-mask fill restarts only `MIN_REBALANCE_INTERVAL`.
4. In the keeper: `HUB_SLOTS` to 6 and 7 with a pin (XS-8); an early `open`/`deadline` check in `_mintFor` and
   `_redeemFor` (XS-6); dollar-valued, per-side request ranking with a gate pre-read and a backoff (XS-7); a
   `maxSupply` argument on `fill`, an attempt cap and an ETH budget (XS-4); a haircut or receipt cap on kept coins
   (XS-5); a cursor that advances only past reads that succeeded (XS-11); `clearStuck` once per start and `feeCap` on
   cancels (XS-12, XS-13). Then run the keeper's end-to-end test.
5. Add the test-adequacy fixes (XS-14, XS-15, XS-16, XS-17, F-57, F-59, F-31) and the documentation fixes under
   Contested, including a basket-builder section and a builder known-limitation entry (XS-10, F-08, F-18), the
   regenerated struct, event and error listings with a Repo test (F-17), and the two factory NatSpec comments
   (F-45).
6. Run the full gate: `forge fmt --check`, `forge build --sizes`, `forge lint -D notes`, `forge test`,
   `forge coverage`, Aderyn, Wake, the Node tests, and the five fork suites on an archive RPC; then update CF-5's
   release hashes in the same commit.
7. Before any mainnet, as `AGENTS.md` already lists: Pyth's parameter replay, a settlement on a real Hermes update, the
   OP-PIP-132 reading, Ondo's corporate-action mechanism, the owner's reading of the 44 tokens' verified source, and an
   external audit; this record's items 1 to 4 above belong in that external audit's scope.