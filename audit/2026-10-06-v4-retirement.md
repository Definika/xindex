# Retirement of v4's market-cap hub (v5)

On 2026-10-06 v4's market-cap index left the tree: `src/IndexHub.sol`, `src/IndexFactory.sol` and their ABIs are
deleted, and with them the reference supplies, the weekly supply batches, the λ band and its auction. v5 replaces them
(the owner's calls on 2026-10-05, `design/2026-10-05-custom-weights.md`): `WeightedIndexFactory` lists a token with a
Pyth price id, a creator fixes each component's units and weight, and `WeightedHub` rebalances back to the weights at
Pyth prices, through an auction on a multiplier μ. The hybrid index had already moved to v5 (2026-10-06, still a draft,
its suites in `foundry.toml`'s skip list), so nothing used the two contracts any more. v4's last commit with them is
`8e6148b`; v3 is tagged `v3.0.0`.

`IndexZap` and `MintRequests` ship unchanged against the weighted factory. Their suites now build `WeightedHub`
indexes, through `test/XindexTest.sol`, which deploys a weighted factory over a stand-in Pyth. The interfaces they type
their calls with, `IIndexHub` and `IIndexFactory`, stay: a weighted index answers every function they name.

This file says which past findings went with v4's hub and factory and what happened to the property each one
protected, in the form of `audit/2026-09-30-v4-stage-a-retirement.md`. It does not restate the findings; the reports
named in `AGENTS.md` gate 6 hold the originals.

- **RETIRED:** the mechanism the finding lived in is gone. The evidence names the tests that were removed and the
  property, if any, that survives elsewhere.
- **RETIRED (in part):** part of the finding's mechanism is gone and its tests with it; the rest stands, tested under
  the same id.
- **RE-TARGETED:** the finding still binds, against `WeightedHub` or `WeightedIndexFactory`, which keep `IndexHub`'s and
  `IndexFactory`'s code for it. The evidence names where its test is now and what changed inside it.
- **UNAFFECTED:** everything not listed. The mechanism, the fix and the test are untouched.

A retired id is not free to reuse and its test must not be restored against the new design. If the property matters
here, it gets a new id from the review of this surface, as V5-L2 did for R19's.

The check behind this file: the audit ids that name a test at `8e6148b`, less the ids that name a test after this
change, are exactly the tested ids retired in full below, 13 of them. Every re-targeted id names a test in a v5 suite.

## Retired

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| R19 | — | A rebalance with nothing to trade cannot start | RETIRED | `BandTooNarrow` and `MIN_BAND` are gone. `test_R19_aStepThatTradesNothingIsRefused` and `testFuzz_R19_CRI33_theBandGateIsExactlyMinBand` removed with `test/IndexHub.rebalance.t.sol`. The property is back under its own id: a fill that releases less than `MIN_TRADE` reverts `NothingToRebalance`, so it cannot restart the interval (V5-L2, `test_V5L2_aFillThatTradesNothingCannotRestartTheInterval`). |
| R17 | — | An issuer inflating supply moves a target at most so far | RETIRED | No supply is read anywhere. `test_R04_R17_theBandIsTheClampsHoweverManyBatchesLanded` removed. What bounds a fill now is the unit cap, `MAX_TURNOVER` of each component's units (V5-M2), and μ (R04, re-targeted below). |
| R22 | — | Nothing moves a pending settlement | RETIRED | There are no batches to land during the notice. `test_R22_aBatchDuringTheNoticeDoesNotMoveThePendingSettlement` removed. A v5 settlement is fixed by the prices at the second the hub names, one slot back (V5-L1). |
| XA-23 | INFO | Overflow at extreme units and supplies reverted rebalances | RETIRED | The band's arithmetic is gone. `test_XA23_theBandHoldsAtTheExtremesOfUnitsAndSupplies` removed. v5's extremes are refused by name: a price scaled past `MAX_PRICE` (`test_theHubRefusesAPriceItCannotUse`), and units past `uint96`, which stop the fill (V5-L3). |
| CR-I03 | INFO | A component held at one raw unit could settle at three times itself | RETIRED | The `⌈λ · u / r⌉` growth is gone. `test_CRI03_aSmallHoldingMovesAtMostTheBandPlusOneRawUnit` and `testFuzz_DA01_R08_CRI03_aFillIsBoundedByTheBandAtAnyPrice` removed. A v5 leg moves a share of the way to its target, at most `MAX_TURNOVER` of its units, and a growing step rounds up by at most a raw unit (`test_DA01_aGrowingStepRoundsUp`). |
| R07 | — | Wrapped assets carry a reference supply | RETIRED | There are no reference supplies. `test_R07_CRL07_everyTokenCarriesAReferenceSupplyAndMintingMovesNothing` removed from `test/Security.t.sol`. A token's own mint moves nothing a v5 hub reads: units, the decimals recorded at listing and Pyth's prices. |
| CR-L07 | LOW | R07's on-chain guard was deleted and its test re-pointed | RETIRED | With R07, in the same test. |
| DA-18 | LOW | No sanity bound on `referenceSupply` | RETIRED | There are no reference supplies. `test_DA18_CRL03_SA02_aRelistingKeepsTheSupplyInForce` removed with `test/IndexFactory.t.sol`. A v5 relisting takes a price id and reaches only indexes created after it (`test_aRelistingReachesOnlyNewIndexes`). |
| CR-L03 | LOW | DA-18's bound was skipped when either side was zero | RETIRED | With DA-18, in the same test. |
| SA-02 | LOW | A relisting could split a uniform supply revision into halves that each opened a band | RETIRED | With DA-18, and `test_SA02_aUniformRevisionOfDelistedComponentsCannotBeSplit` removed from the rebalance suite. |
| CR-I29 | INFO | The supply step bound was unpinned | RETIRED | `MAX_SUPPLY_STEP` is gone. `test_CRI29_theStepIsExactlyHalfAPercent` removed. |
| SA-03 | INFO | `MAX_BATCH` did not fit a cold first batch in one transaction | RETIRED | There are no batches. `test_SA03_aFullBatchFitsOneTransactionCold` removed. |
| SA-04 | INFO | Nothing on chain made supply batches weekly | RETIRED | There are no batches. `test_SA04_batchesComeDueAtMostWeekly` removed. |

## Retired in part

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| CR-M01 | MEDIUM | A live `totalSupply()` could be moved inside a permissionless start | RETIRED (in part) | There is no band for a wrap to move. `test_CRM01_wrappingEtherAroundAStartMovesNothing` removed from `test/fork/Security.fork.t.sol`. `test_CRM01_everyDefaultEntryCarriesAReferenceSupply` stands, on `ConfigureWhitelist`'s list, in `test/Scripts.t.sol`, which the skip list sets aside as before this change. |
| LR-04 | LOW | The fork executor's `fill` could be pointed at a fake index | RETIRED (in part) | `test/fork/RebalanceExecutorV3.sol` is deleted with the v4 rebalance fork suite. `test_LR04_weightedExecutorV3_fillCannotBePointedAtAFakeIndex` in `test/mocks/Mocks.t.sol` pins its v5 twin, `WeightedExecutorV3`: only its deployer starts a fill, and a callback outside one is refused. The twin has no factory, so the second guard, `NotIndex`, is gone: only the deployer can point a fill at anything. |
| LR-05 | LOW | Seven mutants passed the whole suite | RETIRED (in part) | The restart that kept an expired snapshot is gone with snapshots: `test_LR05_aRestartAfterAnUnfilledAuctionTakesAFreshSnapshot` removed. The factory's three moved to `test/WeightedIndexFactory.t.sol`: `test_LR05_theAddressCommitsToEveryField` varies every field the address commits to, one at a time, and `test_LR05_aGuardianChangeExecutesAtTheLastMomentOfItsWindow` and `test_LR05_aTokenMovedBySwapAndPopCanStillBeDelisted` were ported. The zap's, `test_LR05_aRebalanceSettledDuringTheRefundStopsTheMint`, settles a weighted rebalance in the middle of a mint. |
| RT-15 | INFO | Caller and recipient event arguments, and `RebalanceStarted`'s keep mask, were unpinned | RETIRED (in part) | The hub's two tests removed. The zap's, `test_RT15_*` in `test/IndexZap.t.sol`, stand. `WeightedHub`'s `Redeemed` is pinned with caller and recipient apart by `test_redeemSendsTheBasketRoundedDown`. |

## Re-targeted

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| R04 | — | A lone executor keeps at most a bounded share | RE-TARGETED | The bound is μ's, not the band's: at the settling prices an executor delivers at least μ times the value it takes, and μ falls no lower than `MU_MIN` (0.98). `testFuzz_R04_theExecutorDeliversMuTimesWhatItTakes` in `test/WeightedHub.rebalance.t.sol`. |
| R08 | — | A keep mask keeps the rule's proportions | RE-TARGETED | A kept component keeps its units, and the rest re-anchor to their own weights: `test_R08_DA14_RT01_aKeptComponentIsNeitherPricedNorRead`. |
| DA-14 | LOW | A keep mask could not route around a component whose `balanceOf` reverts | RE-TARGETED | The same test: the kept component's reads are broken, and the fill neither prices nor reads it. |
| RT-01 | Low | A keep mask could not route around a component that stopped answering | RE-TARGETED | The same test. |
| R10 | — | An underfunded fill never settles | RE-TARGETED | `test_R10_aShortDeliveryReverts`. |
| R11 | — | The executor callback cannot re-enter | RE-TARGETED | `test_R11_everyEntryPointIsGuardedDuringTheCallback`: all eight entry points, both `executeRebalance` overloads among them. |
| R14 | — | An empty index rebalances at the top of the auction | RE-TARGETED | A settlement that sends nothing out is taken at `MU_MAX`: `test_R14_XA27_anEmptyIndexSettlesAtMuMax`. |
| XA-27 | INFO | The parity rule for an empty index was skipped on a dust supply | RE-TARGETED | The same test. Its second test, a supply that still moves units, went with the supplies; μ's decay in a fill that sends something out is `test_muFallsFromMaxToMinRoundedUp`. |
| R15 | — | A cancel's cooldown binds strangers only | RE-TARGETED | `test_R15_VR04_cancelHoldsStrangersOff`. |
| VR-04 | INFO | Cancelling an expired auction re-armed the cooldown | RE-TARGETED | A live cancel arms the full hold-off (`test_R15_VR04_cancelHoldsStrangersOff`), and a cancel of an expired proposal neither shortens nor extends the expiry's (`test_XA02_XA16_VR04_anExpiredAuctionHoldsStrangersOffUntilItsDelayPasses`). |
| XA-02 | LOW | A stranger could keep a rebalance from clearing by restarting it | RE-TARGETED | `test_XA02_XA16_VR04_anExpiredAuctionHoldsStrangersOffUntilItsDelayPasses`: after an expiry strangers wait out `REBALANCE_DELAY`. |
| XA-16 | LOW | The "rebalance due" condition hid the trigger after an unfilled auction | RE-TARGETED | The same test: `canStartRebalance` is false through the hold-off and true after it. |
| R16 | — | Only the owner or guardian keeps components | RE-TARGETED | `test_R16_onlyTheOwnerOrGuardianPassesAKeepMask`. |
| R21 | — | Donations before a fill stay in the index | RE-TARGETED | `test_R21_XA28_aDonationDoesNotPayForTheFill`. |
| XA-28 | INFO | An executor could deliver less and keep the index's surplus | RE-TARGETED | The same test. |
| VR-03 | INFO | A fill could pay an executor without a discount | RE-TARGETED | `test_VR03_aNoopExecutorReverts`: an executor that delivers nothing cannot settle a fill that buys anything. Its other half, that a fill at the open never pays, was λ's; at the open μ is `MU_MAX`, so an executor delivers 1.02 times what it takes. |
| DA-01 | HIGH | A floored target paid the executor the dropped value | RE-TARGETED | A growing leg's step rounds up, even where μ makes it fractional: `test_DA01_aGrowingStepRoundsUp`. |
| RT-12 | Info | A settlement's rounding was unpinned | RE-TARGETED | `test_RT12_SA07_anEmptyExecutorIsPaidNothingOnASubTokenSupply`, ported to `WeightedHub`, which rounds each leg as `IndexHub` did. |
| SA-07 | INFO | Settlement amounts were differences of floored backings | RE-TARGETED | The same test: forty wei of shares hold exactly one raw unit of ETH, a tenth of it leaves, and nothing is released; it fails with the growing leg floored and with the shrinking leg as a difference of floored backings. |
| CR-I30 | INFO | Two `_checkBacking` terms were unpinned | RE-TARGETED | `test_CRI30_aSettlementStillDemandsTheBackingItOwes`, `test_VR06_CRI30_theBackingTermCountsOpenClaims` and `test_CRI30_aSoldLegIsCheckedAgainAfterTheCallback`, ported to `test/WeightedHub.rebalance.t.sol`. The last fails with only the bought legs re-read. |
| VR-06 | INFO | Two load-bearing expressions survived the suite | RE-TARGETED | `test_VR06_CRI30_theBackingTermCountsOpenClaims`, which fails with the claims dropped from the backing term. |
| DA-13 | LOW | A fill was bound to nothing the executor simulated | RE-TARGETED | `test_DA13_theBoundedFill`. |
| DA-17 | LOW | `redeemSkipping` booked the claim to the caller | RE-TARGETED | `test_DA17_redeemSkippingBooksTheClaimToTheRecipient` in `test/WeightedHub.t.sol`. |
| DA-22 | INFO | Test gaps, the uninitialized clone among them | RE-TARGETED | `test_DA22_CRI25_CRI33_anUninitializedCloneDoesNothing`: issue, redeem, `redeemSkipping`, start, cancel and both fills revert `NotInitialized` on a clone. |
| CR-I25 | INFO | DA-22's `canStartRebalance` check was unpinned | RE-TARGETED | The same test: `canStartRebalance` is false for the clone and the implementation at a mainnet timestamp. |
| CR-I33 | INFO | Smaller hub and factory controls were unpinned | RE-TARGETED | The same test holds the bounded fill on an uninitialized clone, and `test_CRI33_aListingIsPendingAtTheLastMomentItCanExecute`, ported to `test/WeightedIndexFactory.t.sol`, the listing view at its window's last second. Of the rest, the band gate and the λ before the auction went with the band, and the permit domain is exercised by `test_I07_burnWithPermitInOneTransaction`. |
| CR-I01 | INFO | A share transfer to the index itself was accepted | RE-TARGETED | `test_CRI01_RT21_sharesCannotBeSentToTheIndexOrItsFactory`. |
| RT-21 | INFO | Shares sent to the factory were locked | RE-TARGETED | The same test, and the zap's half in `test/IndexZap.t.sol`. |
| RT-05 | Low | `issue`'s fee check was tested only on an empty index | RE-TARGETED | `test_RT05_theFeeCheckMeasuresTheChangeWhenTheIndexAlreadyHoldsTheToken`, ported to `test/WeightedHub.t.sol`; it fails with the check reading the balance alone. |
| DA-09 | LOW | No floor on an index's starting units | RE-TARGETED | A creator names the units; each must lie in `[MIN_RAW_UNITS, MAX_UNITS]`: `test_DA09_createIndexChecksTheUnits`. |
| DA-16 | LOW | An expired guardian change still showed as pending | RE-TARGETED | `test_DA16_guardianChangeExpires`. |
| XA-60 | INFO | A replaced guardian change emitted no cancellation | RE-TARGETED | `test_XA60_aNewProposalReplacesThePendingOne`. |
| XA-61 | INFO | The guardian's standing was misdescribed | RE-TARGETED | `test_XA61_whoMayCancelAGuardianChange`: the guardian cancels its own removal, never its replacement. |

## Moved onto weighted indexes in place

These ids keep their tests in the same files; each test now builds a `WeightedHub` index. Where the change went past
the setup, it is named here.

- **The zap** (`test/IndexZap.t.sol`, `test/fork/IndexZap.fork.t.sol`) and **`MintRequests`** (`test/MintRequests.t.sol`,
  `test/MintRequests.invariant.t.sol`): every id unchanged but for the index. An index holds two components at least,
  so the partial-fill tests (the zap's, CR-I27's, I12's and XA-08's) add USDC's smallest holding, `MIN_RAW_UNITS`, as a
  second component a burn to USDC passes through, and each payout grows by those 10,000 raw units. CR-I31's budget
  boundary: a budget that exactly covers the pass-through leg passes the check and runs out at the swap that buys the
  other component, with the pool's own error, while a raw unit less is `InsufficientBudget`.
- **`test/Security.t.sol`:** the v1 and XA tests of the zap, the factory and the hub's exits, unchanged but for the
  index. L02 loses its supply-batch half: a v5 creator names the units, so no batch can change them. R09, R12, R13, R20
  and XA-59 run on a weighted auction: five components at a fifth each, the first priced at 90 cents. XA-62's combined
  interface is `IWeightedIndexFactory` with `IWeightedHub`. The λ tests whose ids are re-targeted above moved to the
  weighted hub's suites, and `test_control_aFrozenComponentNeedsTheGuardianEachRebalance` with them, as R08's test.
- **XA-12** (`test/mocks/Mocks.t.sol`): on `WeightedExecutorV3`, which takes a callback only from the index it is
  filling.
- **XA-13, XA-24, CR-I22** (`test/fork/MainnetAddresses.fork.t.sol`): the reference supplies `ConfigureWhitelist`
  records are still bounded, since `CheckToken` reads its lists, and the lists are listed on a fresh
  `WeightedIndexFactory` over Pyth's proxy, with their price ids and the tokens' own decimals.
- **M01, I02, I03, FR01, CR-L02, CR-I36, SA-01, XA-07** (`test/fork/Security.fork.t.sol`): unchanged but for the index.
- **XA-44, DA-10** (`test/Repo.t.sol`): the ABI list and CI's loop drop `IndexFactory` and `IndexHub`, and DA-10 reads
  the weighted and hybrid factories' ABIs.

## Removed with no id

- `test/IndexHub.invariant.t.sol`: `test/WeightedHub.invariant.t.sol` holds the backing, claims and bookkeeping
  invariants for v5.
- `test/IndexFactory.invariant.t.sol`: the listing and supply-batch bookkeeping. v5's factory has no supplies; its
  listings and guardian are covered by `test/WeightedIndexFactory.t.sol`, with no invariant suite of their own.
- `test/fork/Rebalance.fork.t.sol` and `test/mocks/MockRebalanceExecutor.sol`: v5's fills on a fork, through Uniswap,
  are `test/fork/WeightedHub.fork.t.sol`.
- `IHybridHubTypes.BandTooNarrow`, the λ band's error, which nothing has raised since the hybrid hub moved to v5; it
  leaves `abi/IHybridIndex.json` with it.

## Kept on purpose

- `src/interfaces/IIndexHub.sol` and `src/interfaces/IIndexFactory.sol`: `IndexZap` and `MintRequests` type their calls
  with them. Their errors and events went with the contracts that raised and emitted them, since Aderyn and Wake
  report an error or event nothing uses; their functions stay, as `ConfigureWhitelist` still calls the factory's.
- `script/ConfigureWhitelist.s.sol`: `CheckToken` and the fork tests read its lists and reference supplies. Its listing
  and supply-batch modes drive v4's interface, which no v5 factory answers; `script/ConfigureWeighted.s.sol` lists for
  v5.
- The suites in `foundry.toml`'s skip list (the hybrid hub's and `test/Scripts.t.sol`): they were written for v4 and
  still import its contracts, and are rewritten for v5 in the safety pass.
