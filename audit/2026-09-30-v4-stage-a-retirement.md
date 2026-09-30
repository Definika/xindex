# Retirement of the price findings (v4 Stage A)

On 2026-09-30 Stage A of Xindex v4 took every price out of the contracts. `IndexRule`, `CompositeFeed`, the Chainlink
feed interface and the methodology library are deleted, and with them the capped 30/20 methodology, the settlement
value gate (`MIN_SETTLEMENT_RATIO`), the turnover gate (`MIN_TURNOVER` and the shortfall that bypassed it) and the
factory's record of token decimals. An index's units now follow its components' reference supplies, set at creation
as `units = ⌊k · supply / 1e36⌋`, and a rebalance is the units-anchored λ auction of
`design/2026-09-29-v4-hybrid-architecture.md` §6.6: every moving component's new units are `⌈λ · units / r⌉`, where
`r` is its clamped ratio of units to supply, and λ falls from the largest ratio to the smallest over the auction.
Supplies change only through weekly atomic batches of at most `MAX_SUPPLY_STEP` (0.5%) each. The contract spec is
`design/2026-09-30-v4-stage-a-spec.md`; v3 is tagged `v3.0.0` at `4b4dbe4`.

That is a change of mechanism, so some past findings no longer describe anything in the repository. This file says
which, and what happened to the property each one protected, in the form of `audit/2026-09-22-v3-retirement.md`. It
does not restate the findings; the reports named in `AGENTS.md` gate 6 hold the originals.

- **RETIRED:** the mechanism the finding lived in is gone. The evidence names the tests that were removed and the
  property, if any, that survives elsewhere.
- **RETIRED (in part):** part of the finding's mechanism is gone and its tests with it; the rest stands, tested under
  the same id.
- **RE-TARGETED:** the finding still binds, against the new mechanism. The evidence names where its test is now and
  what changed inside it.
- **UNAFFECTED:** everything not listed. The mechanism, the fix and the test are untouched.

A retired id is not free to reuse and its test must not be restored against the new design. If the property matters
here, it gets a new id from the review of this surface.

The check behind this file: the audit ids that name a test at `v3.0.0`, less the ids that name a test at the Stage A
commit, are exactly the tested ids retired in full below, 31 of them. XA-45, RT-03 and CR-I11 are retired too, but
never had a test of their own.

## The bound that replaces the price gates

Three retired findings (DA-05, CR-L06, CR-I28) were about how much a lone executor can take when prices move between
a rebalance's start and its fill. v3 bounded that by valuing both sides of a fill at feed prices in the settling block.
The λ band bounds it without a price. A fill at λ sets every moving component's units to `λ · u / r` with
`λmin ≤ r ≤ λmax`. So at any prices the moving value after the fill lies between `λ / λmax` and `λ / λmin` of what it
was. Holders keep at least `λmin / λmax` of it; the clamp puts both ends within `MAX_SUPPLY_STEP` of parity, so they
lose at most 0.995%. The break-even λ, where a fill gives up exactly what it takes at the prices of the moment, is a
weighted average of the ratios, so it lies inside the band whatever the prices did. Tests:
`testFuzz_DA01_R08_CRI03_aFillIsBoundedByTheBandAtAnyPrice` draws the prices per run, the invariant suite moves a
shadow price between start and fill and records any breach in `worstCaseBroken`, and
`testFork_breakEvenLiesInsideTheBandAtRealQuotes` finds the break-even from real Uniswap quotes and settles there to
within rounding.

The bound is on the moving value, not the traded value, so a small revision can expose more than it trades: a 0.5%
revision of a 1% component trades 0.005% of the index and opens a 0.5% band. That is inherent to a price-free scalar
auction, and the README states it among the known limitations.

## Retired

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| DA-05 | MEDIUM | The auction band bounds the multiplier, not the price drift | RETIRED | `IndexToken._checkSettlementValue` is gone with the feeds. `test_DA05_aSettlementTheMarketMovedPastIsRefused`, `test_DA05_aMarketWideMoveIsNotDrift` and `test_DA05_CRI28_theSettlementFloorSitsExactlyOnTheRatio` removed from the rebalance suite. The drift the finding was about cannot enlarge a fill beyond the band: see the section above. |
| CR-L06 | LOW | DA-05's "15% worst case" executor take was exceeded at market prices | RETIRED | `MIN_SETTLEMENT_RATIO` is gone. `test_CRL06_aDriftTheOldRatioLetThroughIsRefusedAtTheFloor` removed. A lone executor at the floor keeps at most `1 − λmin / λmax` of the moving value, at most 0.995%, at any prices, where the ratio allowed 12.5% of the traded value at feed prices. |
| CR-I28 | INFO | The DA-05 floor and the rule's valuation rounding were unpinned | RETIRED | Both are gone. `test_CRI28_eachLegOfASettlementIsValuedRoundedDown` removed, and the shared DA-05 test with it. |
| DA-08 | LOW | `MIN_TURNOVER` gates gross outflow only | RETIRED | There is no turnover gate. A start is refused `BandTooNarrow` when `λmax < λmin · (1 + MIN_BAND)`, which covers nothing changed, every supply changed alike and a single moving component. `test_DA08_turnoverCountsOnlyWhatIsActuallyTraded` (`test/Security.t.sol`), `test_RT04_DA08_theDistanceGateAtItsEdges` and `test_DA08_CRI24_*` removed. What survives is the refusal of a step that trades nothing: `test_R19_aStepThatTradesNothingIsRefused` and `testFuzz_R19_CRI33_theBandGateIsExactlyMinBand`. |
| CR-I24 | INFO | DA-08's `min(sold, bought)` turnover gate was unpinned | RETIRED | With DA-08. `test_DA08_CRI24_turnoverIsTheSmallerSideWhenRoundingSplitsThem` removed from `test/IndexRule.t.sol`. |
| RT-04 | LOW | `MIN_TURNOVER` measured the band-clipped step, so an index far from its rule in a small holding never started the rebalance that corrects it | RETIRED | The shortfall and the gate it bypassed are gone. The band is centred before it is clamped, so however far the supplies moved it is exactly `[1 − STEP, 1 + STEP]` and never collapses, and every fill re-anchors the units to the supplies. The eight `test_RT04_*` tests removed from the rebalance suite. The property survives as `test_R04_R17_theBandIsTheClampsHoweverManyBatchesLanded` and `testFuzz_repeatedFillsConvergeToTheSupplies`. |
| DA-06 | MEDIUM | A kept component's unchecked price reshapes every trading target | RETIRED | Nothing is priced. A kept component is not read at all: the hub asks the factory only for the moving components' supplies, and a settlement touches a kept component's token neither to transfer nor to read a balance. `test_DA06_aKeptComponentIsSnapshotCheckedUnderCapped` removed from `test/IndexRule.t.sol`. The routing survives, broader, as `test_RT01_aKeepMaskRoutesAroundAComponentThatNoLongerAnswers` and `test_DA14_aKeptComponentWithBrokenReadsDoesNotBlockSettlement`. |
| XA-05 | LOW | Keep mask cannot route around an unreadable component | RETIRED | Its v3 form was that uncapped snapshots never priced a kept component; nothing is priced now. `test_XA05_keptComponentsNeedNoSnapshotPriceUnderUncapped` removed. The property survives as the RT-01 and DA-14 tests named in the row above. |
| VR-02 | INFO | A kept component's unchecked price reshapes the components that do trade | RETIRED | A documented limitation of the capped rule, gone with it. A kept component's ratio takes no part in the band's centre, so it moves nothing about the others: `test_R08_aKeepMaskKeepsItsComponentAndAnchorsTheRest`. The four `test_VR02_*` tests removed from `test/IndexRule.t.sol`. |
| VR-01 | INFO | The capped methodology's top weight was a step function of the caps | RETIRED | Capped is gone. The four `test_VR01_*` tests removed from `test/IndexRule.t.sol`. |
| CR-L01 | LOW | VR-01's fix left the top ceiling a step | RETIRED | Capped is gone. The three `test_CRL01_*` tests and `testFuzz_CRL01_theCappedWeightsAreContinuous` removed. |
| XA-04 | LOW | Capped rule does not cap ranks 3+ | RETIRED | Capped is gone. `test_XA04_cappedCapsEveryRankBelowTheFirst` removed. |
| R06 | — | The capped methodology needs five components | RETIRED | Capped is gone, and with it `InvalidMethodology` and `TooFewComponentsForCapped` from `IXindexErrors`. `test_R06_cappedMethodologyNeedsFiveComponents` removed from `test/Security.t.sol`. |
| LR-02 | LOW | Clipped value was handed back to components pinned at the opposite bound | RETIRED | There is no water-filling: units move by `⌈λ · u / r⌉`. The three `test_LR02_*` tests removed from `test/IndexRule.t.sol`. |
| CR-I04 | INFO | `_fill`'s saturating subtraction and `_share`'s tie are reachable at value scale 1 | RETIRED | `_fill` and `_share` are gone with the rule. The two `test_CRI04_*` tests removed. |
| R05 | — | Clipped targets keep the basket value | RETIRED | There are no targets. What a fill does to the basket's value is bounded by the band (the section above). `test_R05_clippedTargetsKeepTheBasketValue` removed from `test/Security.t.sol`. |
| R18 | — | Price readings shape targets only within bounds | RETIRED | Nothing reads a price. Supplies shape units only within the clamp, however many batches landed: `test_R04_R17_theBandIsTheClampsHoweverManyBatchesLanded`. `test_R18_priceReadingsOnlyShapeTargetsWithinBounds` removed. |
| R23 | — | A zero-weight component cannot hand the first executor a windfall | RETIRED | There are no weights, and no unit can reach zero: a component's new units are a ceiling of a positive product, so a component at one raw unit stays at one or more (`test_CRI03_aSmallHoldingMovesAtMostTheBandPlusOneRawUnit`). `test_R23_aZeroWeightComponentCannotHandTheFirstExecutorAWindfall` removed. |
| LR-09 | LOW | A price near zero next to one above `MAX_EXACT_PRICE` still panicked the snapshot | RETIRED | There are no prices. The band's own extremes are pinned by XA-23, re-targeted below. `test_LR09_aNearZeroPriceNextToAnExtremeOneDoesNotOverflow` removed. |
| CR-I32 | INFO | Rule rounding directions beyond scale 1, and the feed-decimals half of the 18-decimal cap, were unpinned | RETIRED | The nine `test_CRI32_*` golden tests removed with `test/IndexRule.t.sol`. The hub's own rounding directions are pinned by `test_executeRebalance_lambdaFallsLinearlyAndRoundsUp`, `test_RT12_aFillMovesExactlyTheChangeInBackingWhenTheProductsHaveRemainders` and `test_CRI03_aSmallHoldingMovesAtMostTheBandPlusOneRawUnit`. |
| RT-13 | INFO | `MAX_PRICE`'s scaled bound was tested only at scale 1 | RETIRED | `MAX_PRICE` is gone. `test_RT13_thePriceCeilingIsAppliedAfterScaling` removed. |
| RT-17 | INFO | The rule's one-wei floors were pinned against removal, not their value | RETIRED | The floors are gone with the rule. The two `test_RT17_*` tests removed. |
| CR-I10 | INFO | `InvalidFeed` was promised for a feed that does not answer as an aggregator | RETIRED | There are no feeds. `test_CRI10_aFeedThatIsNotAnAggregatorIsRefusedWithoutAName` removed. |
| CR-I34 | INFO | `CompositeFeed` had the weakest mutation kill rate | RETIRED | `CompositeFeed` is deleted. The four `test_CRI34_compositeFeed_*` tests removed from `test/mocks/Mocks.t.sol`. |
| RT-14 | INFO | `CompositeFeed`'s leg decimals were untested | RETIRED | With CR-I34. `test_RT14_compositeFeed_keepsTheFirstLegsDecimalsWhenTheLegsDiffer` removed. |
| CR-L04 | LOW | `checkWbtcFeed` read four getters, so a lookalike passed | RETIRED | There is no WBTC adapter to check. The two `test_CRL04_*` tests removed from `test/Scripts.t.sol`. |
| CR-I41 | INFO | The Sepolia test feeds assumed ETH at $3,000 against pools priced at 2,400 | RETIRED | `SetupTestMarket` creates no feeds and `TestAggregator` is deleted. `test_CRI41_everyTestFeedAnswersItsPoolsPriceAtOneEtherPrice` removed. |
| DA-11 | LOW | `executeListing` never re-checks the config | RETIRED | A listing carries one number, checked at proposal against the range and, for a relisting, against the step from the supply in force. Nothing it was checked against can change during the notice: a live listing and a live batch exclude each other (`ListingPending` in `proposeSupplies`, `TokenInBatch` in `proposeListing`), and there is no feed to go stale. `test_DA11_executeListingRevalidatesTheConfig` removed. |
| RT-19 | INFO | RT-01's "a proposal records nothing" assertion passed either way | RETIRED | Nothing records decimals. `test_RT01_RT19_aListedTokenIsPricedWithTheDecimalsRecordedAtListing` removed. |
| RT-22 | INFO | The listing script could not carry out RT-01's decimals recourse | RETIRED | With the decimals record. The three `test_RT22_*` tests removed from `test/Scripts.t.sol`. |
| RT-23 | INFO | An executed refresh re-recorded decimals nobody reviewed, with no event | RETIRED | `tokenDecimals`, `TokenDecimalsRecorded` and `DecimalsChanged` are deleted. `test_RT23_decimalsArePinnedAtTheProposalAndAnnouncedWhenTheyChange` removed. |
| CR-I36 | INFO | Several `ConfigureWhitelist` branches, among others, were untested | RETIRED (in part) | The three feed branches went with the feeds, and `test_CRI36_aFeedOnlyChangeIsAChange`, `test_CRI36_aFeedThatCannotNameItsPairIsSkipped` and `test_CRI36_anOversizedStalenessIsRefusedNotWrapped` with them. The Safe, `Deploy` and policy halves stand under the same id, `test_XA07_CRI36_aRealSafeWithAModuleIsRefused` on the fork among them. |
| CR-L08 | LOW | Nothing checked which feed and staleness bound each default entry uses | RETIRED (in part) | The feed half is gone and `testFork_CRL08_eachDefaultEntryPricesItsOwnToken` with it. `test_CRL08_theDefaultListIsTheReleaseRecord` still pins every default entry's token and supply against a table written independently of the list. |
| VR-06 | INFO (tests) | Two load-bearing expressions in the rule survived the whole suite | RETIRED (in part) | The rule half went with the rule: `test_VR06_aShareExactlyOnTheCeilingStillPins`, `test_VR06_theBoundValueFloorKeepsADustBasketAlive` and `test_VR06_theClipFloorKeepsAZeroShareAtItsFloor`. The calldata pin in `test/mocks/Mocks.t.sol` and `test_VR06_CRI30_theBackingTermCountsOpenClaims` in the rebalance suite stand. |
| XA-45 | INFO | Cross-constant relationships enforced only by comments | RETIRED | Its last assertion, the target cap against the auction's multiplier, went with `test_constants` in `test/IndexRule.t.sol`. The one relationship Stage A has, the hub clamping to the factory's step, is asserted in `test_constantsAndIdleViews`. |
| RT-03 | INFO | Rounding on small legs can fail the settlement ratio (documented) | RETIRED | There is no ratio to fail. Rounding goes the holders' way everywhere: new units round up and amounts are differences of floored backing. So rounding can make an executor deliver more, never make a fill fail. The paragraph in `AGENTS.md` goes. |
| CR-I11 | INFO | A stale feed blocks a settlement (documented) | RETIRED | A settlement reads no feed. The paragraph in `AGENTS.md` goes. |

## Re-targeted

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| DA-01 | HIGH | A target rounded down pays the dropped value to the executor | RE-TARGETED | New units still round up, now as `⌈λ · u / r⌉`. `testFuzz_DA01_R08_CRI03_aFillIsBoundedByTheBandAtAnyPrice` asserts at arbitrary prices that the settled basket is worth at least `λmin / λmax` of the one it replaces; `test_DA01_aResidueIsBoughtBackInsteadOfBeingHandedToTheExecutor` removed from `test/Security.t.sol`. |
| R04 | — | A lone executor keeps at most a bounded share | RE-TARGETED | Bounded by the band rather than by the settlement ratio. `test_R04_aLoneExecutorKeepsAtMostTheBand` in `test/Security.t.sol` and `test_R04_R17_theBandIsTheClampsHoweverManyBatchesLanded`. |
| R08 | — | A keep mask keeps the rule's proportions | RE-TARGETED | A kept component keeps its units and the rest re-anchor to their supplies: `test_R08_aKeepMaskKeepsItsComponentAndAnchorsTheRest` and the fuzz named under DA-01. |
| R14 / XA-27 | — | An empty index, or a settlement that sends nothing out, rebalances at a fixed point | RE-TARGETED | That point is `λmax`, where no executor is paid: `test_R14_anEmptyIndexRebalancesAtTheTopOfTheBand`, `test_XA27_aSettlementThatSendsNothingOutIsTakenAtTheTopOfTheBand`, `test_R14_XA27_anEmptyIndexSettlesAtLambdaMaxAtAnyTime` and `test_R14_aDustSupplyWhoseSoldLegsRoundToZeroSettlesAtLambdaMax`. |
| R17 | — | An issuer inflating supply moves a target at most to double | RE-TARGETED | A supply moves at most one step per batch and a rebalance at most the clamp, whatever the batches did: `test_R04_R17_theBandIsTheClampsHoweverManyBatchesLanded`. |
| R19 | — | A rebalance with nothing to trade cannot start | RE-TARGETED | `BandTooNarrow` at `MIN_BAND`: `test_R19_aStepThatTradesNothingIsRefused` and `testFuzz_R19_CRI33_theBandGateIsExactlyMinBand`, which pins the gate to one wei. |
| R22 | — | No price reading changes issue, redeem or settlement amounts | RE-TARGETED | No price is read. What could move a pending settlement is a supply batch, and it cannot: `test_R22_aBatchDuringTheNoticeDoesNotMoveThePendingSettlement`. `test/Repo.t.sol` asserts that `src/` and `abi/` name no price interface (`test_noContractReadsAPrice`). |
| R07 / CR-L07 | LOW | Every token carries a reference supply | RE-TARGETED | `SupplyOutOfRange` for zero, and an issuer's mint moves nothing the hub reads: `test_R07_CRL07_everyTokenCarriesAReferenceSupplyAndMintingMovesNothing`. |
| CR-M01 | MEDIUM | A token's live supply could be moved around a start (wstETH's, with a flash loan) | RE-TARGETED | The hub reads only the factory's reference supplies. The wstETH fork test is replaced by `test_CRM01_wrappingEtherAroundAStartMovesNothing` in `test/fork/Security.fork.t.sol`: wrapping a million ether around a start moves WETH's own supply and not a wei of the band. The rule's two tests went with the rule. The script's zero-supply skip is asserted in `test_XA40_proposeSkipsTokensOutsideTheWhitelistPolicy`, and `test_CRM01_theScriptSkipsAnEntryWithoutASupply` removed; `test_CRM01_everyDefaultEntryCarriesAReferenceSupply` stands. |
| DA-09 | LOW | No floor on the index start price | RE-TARGETED | Units are computed at creation now, and each must lie in `[MIN_RAW_UNITS, MAX_UNITS]`: `test_DA09_unitsMustStartBetweenTheFloorAndTheHeadroom` in `test/IndexFactory.t.sol`. |
| DA-18 / CR-L03 | LOW | No sanity bound on `referenceSupply`, and the bound's gap at zero | RE-TARGETED | The bound is `MAX_SUPPLY_STEP`, half a percent, in every batch and every relisting: `test_DA18_CRL03_aRelistingMovesTheSupplyAtMostOneStep`. A first listing is the only unbounded supply, as before. |
| CR-I29 | INFO | The supply bound's edge was unpinned | RE-TARGETED | `test_CRI29_theStepIsExactlyHalfAPercent`. |
| CR-I38 / RT-25 | INFO | A revision past the bound is skipped with its reason | RE-TARGETED | Batched rather than proposed per token: `test_CRI38_RT25_aRevisionOfExactlyOneStepIsBatchedAndOnePastIsSkipped`. |
| XA-06 | LOW | Execute mode ignores the entry's config | RE-TARGETED | `test_XA06_executeSkipsAPendingSupplyThatDiffersFromTheEntry`. |
| XA-03 | LOW | A pending config change relists a delisted token | RE-TARGETED | There is no config refresh to test against: `test_XA03_relistingAlwaysTakesAFreshProposal`. |
| DA-20 | LOW | `ConfigureWhitelist`: RELIST silently ignored | RE-TARGETED | The pending config change is gone, but a live supply batch blocks a relisting the same way. At the Stage A draft the script still proposed that relisting, so the whole run reverted on `TokenInBatch`, and safe mode handed the Safe a batch whose call fails. Fixed here: the script skips it with the reason logged until the batch is gone. `test_DA20_aRelistIsNotProposedIntoALiveBatch` failed against the draft. |
| DA-22 | INFO | Test gaps | RE-TARGETED (in part) | The rule's value fuzz and the turnover-threshold tests went. The surviving half, `canStartRebalance` answering false on an uninitialized instance, was an unnamed assertion inside DA-17's test; it now carries the id: `test_DA22_uninitializedInstancesCannotIssueRedeemOrRebalance`. |
| XA-23 | INFO | Overflow in products at extreme inputs | RE-TARGETED | The inputs are units and supplies now, which the band multiplies across components. `test_XA23_theBandHoldsAtTheExtremesOfUnitsAndSupplies` starts and settles one index with a component at `MAX_UNITS` and a supply of `MAX_SUPPLY` beside one at the unit floor, and one with a supply of a single raw unit beside a component at `MAX_UNITS`. It fails with the band's `mulDiv` replaced by plain arithmetic. |
| CR-I03 | INFO | A holding at one raw unit settles at up to three | RE-TARGETED | A small holding moves at most the band plus one raw unit: `test_CRI03_aSmallHoldingMovesAtMostTheBandPlusOneRawUnit`. |
| CR-I33 | INFO | Edges of the start and settlement predicates | RE-TARGETED | `test_CRI33_lambdaIsZeroTheSecondBeforeTheAuction`, `test_CRI33_anExecutedListingLeavesNothingPending` and the `MIN_BAND` fuzz under R19. |
| VR-03 | — | An honest fill at parity never pays the executor | RE-TARGETED | At the open, λ is `λmax`, and nothing is sold: `test_VR03_aFillAtTheOpenNeverPaysTheExecutor`, `test_VR03_anEmptyExecutorCannotSettleAFillThatBuysAnything`. |
| RT-01 | LOW | A keep mask cannot route around a component whose contract stops answering | RE-TARGETED | Under every index now, since nothing is priced: `test_RT01_aKeepMaskRoutesAroundAComponentThatNoLongerAnswers`. |
| RT-21 / XA-62 / LR-05 | — | Trap recipients, the shared interface, and the salt | RE-TARGETED | The rule is no longer an address anyone can paste: `test_RT21_sharesAndComponentsCannotBeSentToTheFactory`, `test_RT21_theFactoryIsNotAValidZapRecipient`, `test_XA62_oneInterfaceExtendsTheFactoryAndTheHub`. The salt covers the computed units instead of the methodology: `test_LR05_addressCommitsToEveryPartOfTheBasket`. |
| XA-13 | LOW | Mainnet addresses are verified on-chain before they ship | RE-TARGETED (narrowed) | The feed half is gone. `test/fork/MainnetAddresses.fork.t.sol` checks the tokens by symbol and decimals, the router and PoolManager by code hash, and the default list on a fresh factory. |

## Documented findings

DA-12 and RT-07, the guardian's two ways to stall rebalancing, still hold. A keep-mask rebalance that leaves a pair of
components moving can clear `MIN_BAND` on a sliver of the index as it cleared `MIN_TURNOVER`, and its fill restarts
`MIN_REBALANCE_INTERVAL`, now a week rather than a month, for everyone. The bound on the stall shrinks with the
interval. RT-02, an executor ordering its fill ahead of a redeem, is unaffected. `AGENTS.md` restates all three
against the λ auction.

## Unaffected

Everything not listed above: issue, redeem, `redeemSkipping`, claims, the fee-on-transfer check, the backing invariant
and the post-settlement check, `cancelRebalance` and the restart hold-offs, `onlyInitialized`, the guardian and listing
timelocks, and the whole of `IndexZap` apart from its recipient check, which no longer names the rule.

## What this does not cover

The new surface is the λ band, supply batches, `createIndex(k)` and its unit bounds, and the scripts' batch mode. It
has had no review of its own. That review comes before the external audit, and before any deployment beyond Sepolia.
