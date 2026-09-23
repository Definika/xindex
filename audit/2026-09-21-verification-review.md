# Verification review of 2026-09-21

A review of the whole repository for logic and architectural errors, at `main` `9116cb8`, after the 2026-09-16 whole-repo
audit (`audit/triage.md`) and the 2026-09-18 logic review (`audit/2026-09-18-logic-review.md`). It read the four core
contracts end to end, mutation-tested the offline suite (34 hand-picked mutants of `src/`), and then put every finding
through twelve adversarial refuters (three lenses each: code correctness, prior art, exploitability) and eight
executable proof-of-concept suites, each in its own copy of the repository. Findings are `VR-01` to `VR-06`; their
regression tests carry the id.

Each fix was checked the way `audit/triage.md` asks: the test fails on the old code (or on the mutant it is meant to
catch) and passes on the new. VR-01 was first recorded as DOCUMENTED and reclassified to FIXED on 2026-09-21, after
reading the Numbers model workbook resolved whether its 30% is an allocation or a ceiling. Four of the review's own
claims were wrong and are corrected in place rather than quietly dropped: two first-pass claims the verification stage
caught (the direction VR-02 moves turnover, and VR-03's one-unit bound), and two the closing pass of 2026-09-21 caught
(that VR-06's mutant (e) was a harmless boundary, and that the fork suites had not run -- see the paragraphs below the
table).

The fork suites cannot run in the review environment: it reaches no mainnet RPC, every endpoint tried being refused at
the network policy rather than by the node. They do run in CI, which holds the `MAINNET_RPC_URL` secret and passes it
to `forge test` on *every* push, not only where the workflow additionally *requires* it (`main` and pull requests into
it from this repository). They are green: run 35620787118 on `b8b734b` reports 17 suites, 355 tests, 0 failed, 0
skipped, the extra 20 over the offline count being the four fork suites. Earlier notes in this review and in the commit
messages that the fork suites were unrun describe the review environment only; CI had been running them all along and
they were not checked there until 2026-09-21.

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| VR-01 | INFO | The capped methodology's top weight was a step function of the caps | FIXED | `_cappedWeights` assigned rank 1 a flat `CAPPED_TOP_WEIGHT` rather than capping it there, and `_top` breaks a tie by position, so the top weight jumped discontinuously when the two largest caps crossed: 12.5 percentage points between two of five otherwise equal components, and 10 points even at a 2x gap. It also *promoted*: twenty equal components gave the largest 30% against a natural 5%. Measured end to end: an index sitting exactly on its methodology reported turnover 0 and `startRebalance(0)` reverted `TurnoverTooLow(0)`; one tick (0.01%) on one pool then produced turnover 124994750091873392, 25x `MIN_TURNOVER`, claimable by any address at the next 28-day boundary. Reading the Numbers model workbook settled the intent: it writes rank 1 as the constant `0.3`, but every constituent it ships sits far above that (top 1 is 64.7% of its basket), rank 2 is written as an explicit `MIN(prelim, 0.2)`, and the scale factor `s = 0.7 / (1 - top1)` exists only to stretch the other constituents up to 70% while the largest is cut down -- at top1 = 20% it would shrink them to make room for a promotion, which is the opposite of what the sheet does. The workbook never exercises top1 below 30%, so the constant is a ceiling that always bound, not a decision about that regime. Both figures are now ceilings: a constituent that does not reach its ceiling keeps its own market-cap weight, and the excess a ceiling holds back is redistributed through the same pass loop. The step is now proportional to the gap that has to be crossed -- 0 at a tie, 0.1pp at 1%, 1.5pp at 10%, and 10pp only at a 2x gap where both are past the 20% cap, which no longer makes it cheap to trigger. The change is a no-op on the model's own data (`min(64.7%, 30%) = 30%`) and on any top-heavy basket: caps 3/1/1/1/1 still give 30/17.5/17.5/17.5/17.5. `MIN_CAPPED_COMPONENTS` still holds, because the ceilings sum to 1.1 for five components. Tests: `test_VR01_theModelsWorkedExampleIsUnchanged` (the workbook's worked example as a real top-heavy shape that both ceilings bind on, passing before and after -- its tokens and scenario figures are illustrative, so only the methodology, not the sheet's numbers, is treated as the requirement), `test_VR01_theCeilingStillBindsOnATopHeavyBasket` (also passing before and after), and `test_VR01_aTieNoLongerMovesTheTopWeight` and `test_VR01_aOneTickMoveNoLongerClearsMinTurnover`, both of which fail on the old rule. `ARCHITECTURE.md`, `README.md`, `Methodology.sol` and the AGENTS.md product decisions record the change. |
| VR-02 | INFO | A kept component's unchecked price reshapes the components that do trade | DOCUMENTED | `_snapshotMarket` prices a kept component with `_price` (`src/IndexRule.sol:366`), which applies neither the `minLiquidity` floor nor `MAX_TICK_DEVIATION` that `_snapshotPrice` applies to every component that moves. The docs said the capped methodology "only ranks it". That understates it: the kept cap also picks rank 1 through `_top` and sits in the `pool` denominator (`:408`) that every non-top weight divides by, while rank 1's weight was then a constant, so it reshapes the free components' targets. Measured: caps 50/20/15/10/5, units 100e18 each, `keepMask = 1 << 4`; moving only the kept pool's tick to 40,000 takes weights from (0.30, 0.20, 0.20, 0.20, 0.10) to (0.20, 0.20, 0.18, 0.12, 0.30) and targets from 133.33/88.89/88.89/88.89 to 114.29/114.29/102.86/68.57, about a tenth of the basket re-targeted. The contract's own `turnover` *falls* over the same move (8.3333% to 7.8571%), so `MIN_TURNOVER` cannot see the distortion -- the review's first pass had this backwards and said turnover rose. Reachable only by the owner or guardian (`keepMask != 0`, `src/IndexToken.sol:234-237`), bounded by the half-to-double clip, and cancellable during the notice period. Not fixed in code: excluding kept components from the capped weights, as the uncapped methodology already does (`:364`), would leave fewer than `MIN_CAPPED_COMPONENTS` ranks to place the remainder in, which is the feasibility condition the capped rule needs -- the accepted residue of XA-05 stands, now documented as more than ranking in the `IndexRule` header, `IIndexRule.targetUnits`, ARCHITECTURE sections 2 and 5. The VR-01 fix narrows this substantially: with both figures now ceilings, every weight is the component's own market-cap weight while no ceiling binds, so the kept cap divides out of the active set exactly as under the uncapped methodology and cannot move anything -- `test_VR02_noCeilingBindingLeavesNoLever` pins six equal caps where no ceiling binds and the kept price moves nothing. What remains is the case a ceiling binds, where the kept cap still decides who carries the larger ceiling and who the excess is redistributed to. The reason for not fixing it is now executed rather than argued: `test_VR02_excludingAKeptComponentWouldBreakTheCappedRule` gives `weightsFromCaps` the cap vector excluding a kept component would produce and shows the rule revert `DegenerateBasket` -- one of five excluded leaves four ranks whose ceilings sum to 30% + 3 x 20% = 90%, and the last 10% has nowhere to go -- so a five-component capped index, the smallest the methodology allows, could never be rebalanced with a keep mask at all, which is the guardian's safety valve for exactly the component whose pool cannot be trusted. The same test pins the six-component case, where the exclusion *is* feasible: excluding only when enough ranks remain would buy the lever off with a step at the keep count, which is the shape of bug VR-01 was. Note also that `_bound` already zeroes a kept component's weight and `_fill` renormalises by `activeWeight` (`src/IndexRule.sol:487,510`), so a uniform rescaling of the capped weights cancels out; what does not cancel is a ceiling, which is an absolute figure, and that is exactly the surviving case. Tests: `test_VR02_aKeptComponentsPriceReshapesTheActiveTargets`, `test_VR02_noCeilingBindingLeavesNoLever`, `test_VR02_theUncappedMethodologyIsImmune`, `test_VR02_excludingAKeptComponentWouldBreakTheCappedRule`. |
| VR-03 | INFO | The rule's targets bought back less value than the shrinking legs released | FIXED | `_clip` turned a component's share of value into units with a flooring `mulDiv`, losing up to one raw unit per component. The component that value came from was already pinned at its floor, so LR-02's rule that a floor-pinned component is never handed value back meant nothing reallocated the residue: the index sent it out as `amountsOut` with no matching `amountsIn`, and `_checkBacking` verifies backing, not value. Two consequences, both measured. An executor whose `onXindexRebalance` body is empty settled a rebalance and kept 1.979882832792812656 raw units per growing component -- 1.98x the one-raw-unit bound the rounding of `amountsIn` alone implies, because the two truncations stack; the review's first pass asserted the one-unit bound and was wrong. And with an honest executor at multiplier exactly 1.0 (no auction discount at all) a coarse-unit basket paid out 39,555,418,500,000,000,000,000 wei of value against 19,780,857,560,236,165,042,936 received, a 49.99% gift. `_clip` now rounds the share back into units upwards, clamped to the ceiling the arithmetic already guarantees, so the residue sits on the executor's side of the trade where every other rounding in the system already sits. After the fix the same basket receives 39,561,715,120,472,330,085,875 against 39,555,418,500,000,000,000,000 paid out, and the free take is 0 across the whole swept tick range. Absolute exposure before the fix was governed by how coarse an index's per-share units are: a realistic control (18-decimal, WBTC-like 8-decimal, 6-decimal) measured the whole take at 1,250,352,879 wei, a fraction of a cent, which is why this is INFO; `createIndex` only checks `units[i] != 0`, so coarse-unit indexes are reachable. README's claim that such a settlement "moves no holder's value" was measurably false (1.276% of that basket) and is corrected. Tests: `test_VR03_anHonestFillAtParityNeverPaysTheExecutor`, `test_VR03_anEmptyExecutorCannotSettleADustRebalance`; both fail on the old rule with the numbers above. |
| VR-04 | INFO | Cancelling an expired auction re-armed the restart cooldown from scratch | FIXED | `cancelRebalance` checked only `_pending.eta == 0`, so it accepted a proposal whose auction had already expired and set `restartAllowedAt = block.timestamp + REBALANCE_DELAY`. An expiry already holds strangers off until its own deadline plus `REBALANCE_DELAY`, so the cancel pushed that out again -- by one second just after the expiry, and by a full `REBALANCE_DELAY` when timed at the moment strangers were about to be let in (172,800 seconds, measured). The cancel is still allowed, because it clears the stale proposal the views report, but it now takes the later of the hold-off already in force and the one the expiry granted, and arms a fresh `REBALANCE_DELAY` only while the auction is live. This grants the owner and guardian no power they lacked -- they can cancel any live proposal, and chaining start and cancel holds strangers off at one transaction per two days either way -- and moves no holder value, hence INFO. Tests: `test_VR04_cancellingAnExpiredAuctionDoesNotExtendTheHoldOff` (fails on the old code with 3196801 against 3024001), `test_VR04_anExpiredCancelReportsTheExpirysOwnHoldOff`, `test_VR04_cancellingALiveAuctionStillArmsTheFullCooldown`. |
| VR-05 | INFO | The executor callback observes an intermediate unbacked state | DOCUMENTED | `executeRebalance` writes the new units and bumps `rebalanceNonce` before it moves any token, so for the length of the payout loop and the callback an outside reader sees units the index does not yet back. This is deliberate checks-effects-interactions and no value is at risk: every function that mints, burns, pays a claim or touches a rebalance shares the index's guard for the whole call, which a probe covering all twelve nonpayable ABI functions confirmed. `IRebalanceExecutor.onXindexRebalance` now says so, next to the existing instruction never to price an index off `balanceOf(index)`. No test of its own: fixed by documentation, and `test_R11_theExecutorCallbackCannotReenter` already covers the guard. |
| VR-06 | INFO (tests) | Two load-bearing expressions in the rule survived the whole suite | FIXED | Mutation-testing 34 hand-picked mutants of `src/` against the committed suite left six alive. Three are not test gaps: `IndexToken.sol:332`'s `+ totalClaims[token]` is a provably equivalent mutant (given the backing invariant, `held - amountsOut + amountsIn` always dominates `backing + claims`, so the term can never bind in normal operation -- it is a real safety net against a component that can seize balances, and is kept); `_share`'s `below >= above` is an unreachable tie (0 occurrences in 400,000 randomised baskets, and identical targets when forced); and `_fill`'s `Math.saturatingSub` was never reached in 110,000 runs across three searches plus a `pinnedValue > value` probe, so it is better described as unreachable defensive code than as untested. The other three are genuine and now have kill-tests. `_clip`'s `Math.max(..., basket.lo[i])` (`src/IndexRule.sol:567`) is what stops a component on the WAD value scale, whose weight and whole holding both round away, from being targeted at zero units -- backing the index would no longer owe on a component it still holds, and which no later rebalance could restore, since every target is bounded by half to double of zero. `_bound`'s `Math.max(..., 1)` (`:482`) is what keeps such a basket's `activeValue` non-zero instead of reverting `DegenerateBasket`. The third, `_cappedWeights`' `weight < ceiling`, was first recorded here as differing "only at exact equality" and therefore harmless. That was wrong, and settling it on 2026-09-21 showed why: at exact equality the component is assigned its ceiling but *not* counted as pinned, so neither its ceiling leaves `share` nor its cap leaves `pool`, while the next pass skips it anyway on `w[i] == ceiling`. Its weight is handed out and its cap still divides everything else. Caps of 5, 2, 1, 1, 1 out of ten -- the first overshooting 30%, the second landing on 20% to the wei -- take the three smallest from 16.67% each to 14% each and the whole basket from 100% to 92%. It is not an equivalent mutant; only the sub-case where *nothing else* pins is (there the shortcut and the second pass agree exactly, and caps of 3, 2, 2, 2, 1 show it). The suite did kill it, but only through `test_VR02_aKeptComponentsPriceReshapesTheActiveTargets`, which is about something else and pins the boundary by accident; and `testFuzz_cappedWeights` already asserts the tight lower bound `sum >= WAD - n` that the mutant breaks by 8e16, yet random caps drawn from `[1, 1e50]` essentially never land a share on a ceiling to the wei, so the property was asserted and the witness unreachable. `test_VR06_aShareExactlyOnTheCeilingStillPins` now supplies the witness by hand and pins both sub-cases. Tests: `test_VR06_theClipFloorKeepsAZeroShareAtItsFloor`, `test_VR06_theBoundValueFloorKeepsADustBasketAlive`, `test_VR06_aShareExactlyOnTheCeilingStillPins`; each fails under exactly its own mutant. The `Math.min(basket.hi[i], ...)` added with VR-03 never bound in 20,000 fuzz runs and is the bound the arithmetic already gives (`share <= ceilingValue` implies `ceil(share * scale / p) <= hi`); it is kept as insurance against a later change to `hi`. |

Reviewed and found sound, each with an executed proof-of-concept rather than by argument: flash-mint neutrality around
a fill, at multipliers 1.5, mid-auction and 0.9, with tiny and very large flash amounts, a separate executor, open
claims and an empty index (15 tests, including a 512-run fuzz); the backing invariant and the exact sum of `claimOf`
against `totalClaims`, under an independent stateful harness at 64 runs by depth 300 plus two scripted torture tests;
the `held` bound in `_checkBacking` against donations; the water-filling's bounds, value conservation and absence of
panics over 60,000 fuzz runs across the full tick range with units to `uint96` max, every keep mask and both
methodologies, plus 3,000 swept baskets; the zap's hop-by-hop accounting, cross-leg paths through another component,
budget algebra, leftover allowances and permit front-running (11 tests); and the reentrancy guard's coverage of all
twelve nonpayable entry points, called both from the executor callback and from a component transfer hook.

Two of the four areas this review left uninspected were closed on 2026-09-21. The factory's listing and guardian
timelocks and the swap-and-pop whitelist array now have a stateful invariant campaign,
`test/IndexFactory.invariant.t.sol`: six invariants over 64 runs of 2,048 calls with no reverts, comparing the factory
against a ghost account of the rules kept independently of it. The handler attempts every execution whatever the clock
says and records which way it went, because a handler that checked the window before calling could never observe a
timelock failure -- the first draft did exactly that, and four of five mutants survived it. It now kills all six:
`executeListing` and `executeGuardianChange` each accepting an early or an expired proposal, `executeListing` never
whitelisting, and `delist` losing a swapped token's position (`test_delistingAMovedTokenKeepsTheArrayConsistent`, a
deterministic sequence, because a random campaign rarely lines four listings up against two delists in that order).
`ConfigureWhitelist._action` now has a state matrix, `test_action_matchesEveryListingState`, asserting the branch taken
for each of the twelve states it distinguishes -- never configured, listed with and without a change, delisted with and
without a change and with and without RELIST, a live proposal carrying the entry's own config and carrying another, an
expired proposal, a mint currency, decimals outside the policy, and a config the rule rejects. It kills five branch
mutants of `_action`, each by its own assertion. The individual paths were already covered by the tests around it; what
was missing was one place where a state that stops being distinguished shows up rather than silently taking a
neighbour's branch.

Both of the items this review closed as still unverified were settled on 2026-09-21, neither of them by argument.

`ISwapRouter02`'s struct layouts were the highest residual risk on the list, because a layout slip misroutes funds
while every local gate passes, and no local mock can catch it: `test/mocks/` is written against the same struct
definition `IndexZap` uses, so a wrong definition is simply agreed with on both sides. It turns out not to need a
fork. Uniswap's canonical `IV3SwapRouter.sol` was read from source and both structs are field-for-field identical to
ours, and `test_routerCalldataMatchesUniswaps` now pins the full `abi.encodeCall` output of `exactInput` and
`exactOutput` against ground truth encoded from Uniswap's own signatures. A selector on its own is not enough and the
first version of this test made that mistake: a selector covers a tuple's field *types*, not their order, so swapping
`amountIn` with `amountOutMinimum` -- both `uint256`, and a swap that turns a minimum received into an exact input --
leaves `0xb858183f` untouched. Pinning the calldata catches it: the check was verified against that exact mutation, and
against the matching swap of `amountOut` with `amountInMaximum`, and fails on each.

The fork suites then confirmed the same thing from the other direction. `test/fork/IndexZap.fork.t.sol` drives eight
end-to-end mints and burns through the real SwapRouter02 at `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` --
`testFork_mintWithUSDC`, `testFork_mintWithUSDT`, `testFork_burnToUSDT`, `testFork_burnToWBTC`,
`testFork_mintAndBurnWithPerLegLimits`, `testFork_btcBasketWithTBTC_mintAndBurn` and the two limit reverts -- so a
field-order slip in either struct would misroute or revert there rather than pass. All eight are green on `b8b734b`,
alongside `RebalanceForkTest`, `SecurityForkTest` and `MainnetAddressesForkTest` (four each, the last checking
`script/MainnetAddresses.sol` against the chain by symbol and by the Uniswap factory's `getPool`). The layouts are
therefore verified twice, statically against Uniswap's source and dynamically against the deployed router.

VR-06's mutant (e) needed a hand-built cap vector rather than fuzzing, as recorded. It was built, it showed the mutant
is a real divergence rather than the harmless boundary this review first called it, and the correction is written into
the VR-06 row above rather than dropped.

Gate 5 was also run rather than assumed: `wake detect all src` under eth-wake 4.22.1, with the config generated the way
CI generates it (`wake init config --force`, then `audit/` added to `exclude_paths`), reports no detections. The
generated `wake.toml` and `.wake/` are now in `.gitignore`: CI rebuilds the config from `foundry.toml` on every run, so
a committed copy would be the second, silently diverging set of remappings the Wake step exists to avoid.

## Corrections of 2026-09-23

The security audit of 2026-09-23 (`audit/2026-09-23-security-audit.md`, ids `CR-..`) checked this review's claims
against the code as merged into v3 at `855e41b`. Five were wrong or had gone stale; they are corrected here rather than
in the table, so the table still says what this review found at the time.

- **VR-01 was incomplete (CR-L01).** Making both figures ceilings left the top ceiling itself a step: 30% went to
  whichever cap ranked first. Wherever both leaders sit above 20% — any five-component basket whose two leaders each
  hold more than a third of the rest, not only a top-heavy one — two near-tied leaders swapped the full ten points on a
  one-wei move, so "0 at a tie" and "10pp only at a 2x gap" were false in that regime, and a one-basis-point price move
  still took an on-methodology index from under `MIN_TURNOVER` to 10% turnover. The top ceiling now follows the lead:
  20% at a tie, rising linearly to 30% once the largest cap is twice the second's. At a tie the five ceilings sum to
  exactly 100%, so `MIN_CAPPED_COMPONENTS` still holds; the row's "sum to 1.1" is true only at a lead of 2x or more.
  Every capped subset of the launch list has leaders at least 4.9x apart and is unchanged. Tests:
  `test_CRL01_aTieBetweenLeadersPastTheirCeilingsMovesNothing`, `test_CRL01_theTopCeilingRisesWithTheLead`,
  `test_CRL01_aBasisPointMoveOnATopHeavyTieCannotStartARebalance` and `testFuzz_CRL01_theCappedWeightsAreContinuous`
  in `test/IndexRule.t.sol`. The row's `test_VR01_aOneTickMoveNoLongerClearsMinTurnover` has been
  `test_VR01_aBasisPointMoveNoLongerClearsMinTurnover` since the move to Chainlink, and still kills the VR-01 mutant.
- **VR-03's second test stopped pinning VR-03 (CR-I36).** The merge that carried this review into v3 (`8fab3ba`)
  pointed `test_VR03_anEmptyExecutorCannotSettleADustRebalance` at DA-05's `SettlementValueTooLow`, which an executor
  delivering nothing trips however `_clip` rounds, so the test passed with VR-03's rounding reverted. It now also
  asserts that every growing leg of the dust rebalance asks for at least one raw unit, which the flooring rule did not.
- **VR-05's count is thirteen (CR-I20).** DA-13 added `executeRebalance(bytes, uint256[])`, so the probe's "twelve
  nonpayable ABI functions", here and in the paragraph below the table, are thirteen. The guard covers both
  settlement entry points: `MockRebalanceExecutor` re-enters through each.
- **VR-06's three survivors were not what it said (CR-I04, CR-I30).** `_fill`'s `Math.saturatingSub` is not
  unreachable defensive code: since VR-03 rounds a share up onto its ceiling, a ceilings pass can pin up to one raw
  unit's value more than the share, and at value scale 1 that can exceed everything still to place, where a checked
  subtraction would make the snapshot, and `startRebalance` with it, panic. `_share`'s `below >= above` tie is reachable
  too, and it decides which side is pinned. Random baskets never landed on either.
  `test_CRI04_theFillsSaturatingSubtractionIsLoadBearingAtScaleOne` and
  `test_CRI04_aClippingTieIsReachableAndPinsTheFloors` in `test/IndexRule.t.sol` pin both through the real listing
  flow. And `+ totalClaims[token]` in `_checkBacking` is equivalent only under the backing invariant's own premise; a
  component that can seize balances breaks that premise, which is why the term is kept, and
  `test_VR06_CRI30_theBackingTermCountsOpenClaims` in `test/IndexToken.rebalance.t.sol` now kills the mutant with a
  clawback during the callback while a claim is open.
- **The router layouts were no longer verified twice (CR-I36).** `test_routerCalldataMatchesUniswaps` moved to
  `test/mocks/Mocks.t.sol` with the merge, where it pins `ISwapRouter02`, which no contract in `src/` uses any more. Its
  v3 replacement decoded the zap's V4 parameters with the zap's own structs, which is the circular check this section
  warned about: swapping `amountOut` with `amountInMaximum`, or `amountIn` with `amountOutMinimum`, passed every offline
  test, and only the fork suites caught it. `test_CRI36_*` in `test/IndexZap.t.sol` restore the static layer: they
  decode the zap's V3 command inputs and V4 parameters with layouts written from universal-router `3663f6db` and
  v4-periphery `444c526b` rather than from `UniswapV4Types`.

VR-02's row describes the price path as it was: a kept component then skipped the pool checks a traded one got. Since
the move to Chainlink there is one price path, so a kept component's price is checked like every other (CR-I13).
