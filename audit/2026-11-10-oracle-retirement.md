# What went with the oracle

2026-11-10. The oracle-free rebalance (`design/2026-11-10-oracle-free-rebalance.md`, the owner's call of that day)
removed Pyth from the protocol: no contract reads a price, a listing carries no price id, and the executor names the
units a rebalance settles at. This record lists the review ids whose mechanism is gone, with the test that went and
the property, if any, that survives. Do not restore a retired id's test against the new design; a property that
matters here gets a new id from a review of this surface.

## 1. Retired in full

The ids tested before the change, less those tested after it, are exactly these ten: nine went with the contracts,
and RX-18 with the keeper's bot (section 6).

| Id | What it fixed | The tests that went | What survives |
|---|---|---|---|
| V5-L1 | The hub fixes the second its prices belong to, one slot back | `test_V5L1_priceTimeIsOneSlotBack`, `test_V5L1_theHubAsksPythForTheLastSlot` | Nothing: no price, no window |
| V5-M1 | No two components on one price id | `test_V5M1_initializeRefusesTwoComponentsOnOneFeed`, `test_V5M1_twoComponentsOnOneFeedAreRefused`, `test_V5M1_pythNeverFillsOneIdTwice`, and the id half of `test_RT24_V5M1_aListNamingATokenOrAnIdTwiceIsRefused` | A token named twice is still refused, by the hub, the factory and the listing script (RT-24) |
| V5R-1 | The minimum trade is measured after the turnover cap | `test_V5R1_theMinimumTradeIsMeasuredAfterTheCap` | No `MIN_TRADE`: a fill must gain at least the bar, on the fill as named (V5-L2's tests) |
| DA-01 | A growing leg's new units round up | `test_DA01_aGrowingStepRoundsUp` | The hub computes no units. Each amount still rounds the holders' way (SA-07, `test_RT12_SA07_...`) |
| RB-3 | An update published before the pinned second is refused | `test_RB3_anUpdateBeforeThePinnedSecondIsRefused` | Nothing |
| RX-3 | A start reads every moving feed, and the auction is four hours | `test_RX3_aStartNeedsEveryMovingFeedToPublish`, `test_RX3_noAuctionRunsIntoTheNextOpen`, `test_RX3_aStartPaysPythItsFee` | No feed to be shut. The auction stays four hours for the bar's twenty halvings |
| RX-27 | A price far from its moving average is refused | `test_RX27_aPriceFarFromItsAverageIsRefused` | Nothing |
| AU-2 | The preview makes the fill's price checks | `test_AU2_thePreviewRefusesAPriceFarFromItsAverage` | The preview runs the fill's own check (`test_previewMatchesTheFill`, `test_theBarDecidesWhenAFillClears`) |
| RZ-26 | The guardian is a relay its Safe controls | The twelve `test_RZ26_...` of `test/GuardianRelay.t.sol` and `test/Scripts.t.sol`, and the keeper's two node tests named `RZ-26: ...` | `GuardianRelay` is deleted: a start carries no update, so the Safe holds the role itself |
| RX-18 | Pyth's update fee counts against a fill's profit, as gas | The node test `RX-18: Pyth's update fee counts against a fill like its gas` | The keeper pays no fee: no call of the hub takes ether (`test_aFillTakesNoEther`, `a fill costs its gas ... and nothing else`) |

Recorded by documentation alone, and retired with them: V5-I1 (that an update is the first of its second is Pyth's
to keep), RX-25 (`PYTH` cannot be repointed), RX-31 and RX-59 (the share feeds' sessions and the one-second window),
RX-65 (a block builder seeing past `PRICE_LAG`), RZ-4 (a collapsed leg stopping the fills under `MIN_TRADE`), RZ-17 (a
start's gas limit calibrated per feed) and RZ-27 (the moving average's sign and exponent), both open and untested,
and the
known limitations "A wrong price costs at most the turnover cap", "Rebalancing needs Pyth's Hermes", "Price ids are
data the owner maintains" and "A start must land in one slot". `docs/known-limitations.md` now has "A lone executor
keeps the index's distance from its weights", "No contract reads a price", "One fill may not land on the weights"
and "A dust index's units can be walked" in their place.

## 2. Retired in part, or re-targeted

| Id | What went | The test now |
|---|---|---|
| V5-I4 | "Only the hub reads a price" | Nobody does: `test_V5I4_noContractNamesPyth` |
| V5-M2 | A wrong price takes at most a fifth of each leg | No price can be wrong. The cap on units stands: `test_V5M2_aFillTakesAtMostAFifthOfALegsUnits`, `testFuzz_V5M2_noFillTakesMoreThanAFifthOfALeg` |
| V5-L2 | A fill under `MIN_TRADE` reverts | A fill without a gain reverts: `test_V5L2_aFillThatChangesNothingCannotRestartTheInterval`, `test_V5L2_aKeepMaskMustLeaveTwoMoving` |
| V5-L3, RX-61 | Units beyond 96 bits stop the fill | Unchanged in substance: `test_V5L3_RX61_unitsBeyondUint96StopTheFill` |
| RX-15 | A growing leg adds at most `μ · MAX_GROWTH` | It adds at most `MAX_GROWTH`, with no `μ`: `test_RX15_aFillAtMostDoublesALeg` |
| R04 | The executor delivers `μ` times what it takes at the settling prices | On its weights no fill takes value, at any prices: `testFuzz_R04_onItsWeightsNoFillTakesValue` |
| R14, XA-27 | An empty index settles at `MU_MAX` | An empty index does not rebalance: `test_R14_XA27_anEmptyIndexDoesNotRebalance` |
| R08, DA-14, RT-01 | A kept component is neither priced nor read | A component left alone is not read, kept or not: `test_R08_DA14_RT01_aComponentLeftAloneIsNotRead`. RT-01's "prices are scaled from recorded decimals" is gone with the prices |
| RX-33 | Pyth's address and the router's are pinned independently | The router's: `test_RX33_theRouterIsPinnedIndependently` |
| CR-L08 | The lists are pinned, address and price id | The addresses: `test_CRL08_theListsAreTheReleaseRecord` |
| XA-06 | `execute` runs only the entry's pending id | `execute` runs what is due: `test_XA06_executeRunsOnlyWhatIsDue` |
| XA-44 | Six ABIs are committed | Five: the relay's went |

## 3. Tests without an id that went

`test_issueAndRedeemNeverCallPyth`, `test_theFeeGoesToPyth`, `test_pythCannotReenter`,
`test_onlyTheFirstUpdateOfThePinnedSecondCounts`, `test_theHubChecksWhatPythReturns`,
`test_theHubRefusesAPriceItCannotUse`, `test_thePriceAtTheCeilingIsAccepted`,
`test_aKeptComponentsPriceEntryIsIgnoredInThePreview`, `test_previewRebalanceNeedsOnePricePerComponent`,
`test_muFallsFromMaxToMinRoundedUp`, `test_aMidpointFillIsExact`, `test_theAuctionEndsScaleTheBoughtLegs`,
`test_theGrowthFactorRoundsUp`, `test_theBoundedFillTakesValue`, `testFuzz_aMidpointFillLandsOnTheWeights`,
`test_constructorRefusesAPythWithoutCode`, `test_hubConstructorRefusesAZeroPyth`,
`test_deployWeighted_resolvePyth`, `test_everyListedCoinHasItsOwnPriceId`, `test_malformedEntriesAreRefused`,
`test_proposeListingRefusesAZeroPriceId`, and on the fork `testFork_pythIsPyths`,
`testFork_drill_aFeedGoesSilent` and `testFork_drill_aWrongPriceTakesAtMostAFifth`.

Their successors: `test_noRebalanceEntryPointTakesEther`, `test_theBarHalvesEveryTwelveMinutesRoundedUp`,
`test_aFairFillSettlesToTheUnit`, `test_theBarDecidesWhenAFillClears`, `test_onlyAGiftClearsTheBarsFirstSecond`,
`test_aFillNamesEveryComponent`, `test_aLoneExecutorKeepsAtMostTheDistanceFromTheWeights`,
`test_DA13_aMintBeforeTheFillMovesItPastTheBound`, and on the fork `testFork_drill_anExecutorLeavesACoinAlone` and
`testFork_drill_noFillTakesMoreThanAFifth`.

## 4. Mutants

Gone from `test/mutants/mutants.json`: the old arithmetic's V1 to V8 and V11 to V17, the hub's price mutants H2 to
H8, H14, H15 and H17, and the relay's G1 to G6. In their place: the new arithmetic's V1 to V8, V11 to V17 and V21 to
V24 (each rounding flipped, each cap dropped, the bar's rounding, start and half-life, the score's terms, the empty
supply, the length and the clock), and the hub's H2 to H4, H7 and H8.

## 5. The keeper's executor, and two temporary tests

`KeeperExecutor.fill` takes the units the keeper names in place of a Pyth update, and is no longer payable. Its
`test_pythFeeIsForwarded` went; `test_aFillTakesNoEther`, `test_aFairFillSellsAndBuysAtTheRoutesQuotes`,
`test_aLoneFillAtTheAuctionsEndKeepsTheDistance`, `test_aFillAtTheAuctionsStartCostsTheKeeperAGift` and
`test_aFillUnderTheBarIsRefusedByTheIndex` replace the two fills at `MU_MIN` and `MU_MAX`. CF-1, XS-4 and AU-3 keep
their tests.

`audit/poc/2026-10-31-Rogue.t.sol` and `audit/poc/2026-10-31-RedTeam.t.sol`, the red teams' temporary fuzzers of the
Pyth-priced hub ("Delete after the review"), are deleted: they imported the Pyth mock and cannot compile against a hub
that reads no price. `audit/2026-10-31-red-team.md` still cites them; they are in git before this change.

## 6. The keeper's bot

Converted the same day (`keeper/keeper.mjs`, `keeper/bot/`). The bot names the units of its own fills
(`keeper/bot/units.mjs`: the hub's arithmetic ported word for word, replayed against the contracts' 426 vectors, and
`nameUnits`, which picks the units that clear the bar while leaving the index the least), sends plain starts, and pays
no fee. Pyth stays the keeper's own price source, off chain: Hermes' prices, each confirmed by Pyth's contract before
anything is valued at it, with the coin-to-id catalogue now the keeper's (`keeper/bot/price-ids.mjs`, pinned against
`script/Listings.sol`, `script/MainnetAddresses.sol` and `script/PythIds.sol`).

- Gone: the relay's starts (`relayStarts`, `liveAuthorizations`, `relayStartGasLimit`) with RZ-26's two node tests
  and mutant G7; the Pyth fee in a fill's cost, with RX-18's node test; the US-session timing of a start and the
  quiet-feed hold (`inSchedule`, `sessionStartOk`, `SESSION_IDS`, `US_EQUITY_SCHEDULE`), with the node tests
  `RX-3, RX-31: ...` and `RX-3: a start's gas limit ...`. No session bounds a fill any more: the bot names no units
  for a leg it cannot value, a share-priced Ondo leg and a leg whose price is stale among them, and leaves it alone.
- Kept, as the keeper's own safeguards: RX-1, RX-2, RX-9, RX-10, RX-13, RX-16, RX-34, RY-6, RY-7, RY-8, RZ-1 and
  their tests, and mutants Y1 and Y2.
- New: the node suites `keeper/test/unit/units.test.mjs` and `keeper/test/unit/price-ids.test.mjs`, and mutants U1
  to U4 (each rounding of the port flipped, the exact check dropped).
- The end-to-end test (`keeper/test/e2e/run.mjs`) deploys no relay and lists no price id; its guardian starts an
  auction with a keep mask in a plain call, and the keeper's fill leaves the kept coin's units alone.
