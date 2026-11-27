# Attack replay (HK-1 to HK-20)

The owner's ask that day: "i want you to see every hack that happend in crypto and than attack our contract and test
our code against that kind of attacks". This record is the answer: the classes of attack that have taken funds from
on-chain protocols from 2016 to June 2026, each aimed at the contract of this build it would hit, with the test that
replays it. Ids are `HK-1` to `HK-20`; a test is named `test_HK01_...`, and a node test `HK-01: ...`.

It is one more internal review, by the author of the code it reviews. It is not the external audit, which is still
owed before any mainnet, and it reads the contracts, the keeper's executor and nothing off chain.

## 1. Result

- **One finding, low, fixed: HK-16.** A creator's proposal of new weights stayed pending when the creator role moved
  on, so the outgoing creator's weights took effect under the incoming one, who had seven days to notice and cancel
  them. `acceptCreator` now cancels a pending change of weights (`WeightsCancelled`). No funds were at risk: a change
  of weights moves no token, and a fill after it is held to Pyth's tolerance.
- **No other class took anything.** Thirteen more were replayed here and refused. Five were already replayed by
  earlier suites and are named with those tests. One, a vote bought with a flash loan, does not apply: there is no
  vote.
- **One bound is shown instead of asserted (HK-4).** No key moves a token at rest. Through an index's own auction,
  the owner's key, the guardian's and the index's creator's together take up to a fifth of a leg per week, and only
  after seven days of public notice during which every holder can leave whole. Section 3 says exactly what it takes.
- **Two of the replay's own tests were wrong at first**, and the mutation gate caught one: Foundry clears transient
  storage between a test's own calls, so a test that makes two calls proves nothing about one transaction. Both now
  run inside one call (section 5).

## 2. The classes

"Where it would hit" is the contract an attacker of that class would aim at here. "Result" is what the replay found.

| Id | Class, and where it took funds | Where it would hit | Result | Test |
| --- | --- | --- | --- | --- |
| HK-1 | A callback that does not ask who is calling: Augustus V6 (March 2024), arbitrage bots baited through their swap callbacks, and SIR.trading (March 2025), whose check read a transient slot a later step had overwritten | `KeeperExecutor.onXindexRebalance`, the one callback that pays out | Refused. The callback answers the index being filled and nothing else, and its mark is cleared when the fill ends | `test_HK01_aSwapInsideAFillCannotCallTheCallbackAsTheIndex`, `test_HK01_theCallbackClosesWhenItsFillEnds`, node `HK-01: ...`; mutants HK1, HK2 |
| HK-2 | Transient storage left behind for a later step of the same transaction: SIR.trading | The factory's duplicate check, which marks each token in transient storage | No residue. A refused creation's marks die with its revert, an accepted one's are cleared, and the marks are the factory's only transient storage | `test_HK02_noMarkOfOneCreationReachesTheNext`; mutant PY26 |
| HK-3 | A standing approval spent by someone else, through a call whose target or payer a caller chose: SwapNet and Aperture (January 2026), Ekubo's extension (May 2026), the approvals of an arbitrage bot (June 2026) | Every contract a user approves: an index (an issue, and a creation's first issue at an address predicted before it exists), the zap, the builder, the request escrow, the executor | Every pull names its caller as payer. An index's address commits to its creator, so nobody else can take the address an approval was given to | `test_HK03_anApprovalGivenToAnIndexToBeIsSpentByItsOwnCreationAlone`, `test_HK03_everyPullIsFromTheCaller`, node `HK-03: ...`; mutant HK7; earlier: `test_control_approvalsToZapCannotBeSpentByOthers` |
| HK-4 | A stolen key that upgrades a contract or mints without a bound: Ronin (2022), Radiant (2024), Bybit (February 2025), Resolv, IoTeX and Step (2026), KelpDAO and Drift (April 2026) | The owner, the guardian, an index's creator | No key moves a token, changes an index's terms or blocks an exit. Nothing can be upgraded. The bound through an auction is section 3 | `test_HK04_everyStolenKeyTogetherMovesNoTokenAndBlocksNoExit`, `test_HK04_theWorstEveryKeyTogetherTakesIsAFifthOfALegAfterAWeeksNotice`, `test_HK04_noContractCanBeUpgradedOrAimed`, node `HK-03, HK-04: ...` |
| HK-5 | Rounding that pays the trader on a few wei, repeated: KyberSwap Elastic (2023), Cetus (May 2025), Balancer V2 (November 2025), Thetanuts (June 2026) | Issue, redeem, `redeemSkipping` and `claim`, under a streaming fee that moves the scale | Nothing. Two hundred rounds of dust through every rounding, with and without fees: the attacker never ends a round a wei up, the index never a wei down | `test_HK05_cyclingDustThroughEveryRoundingTakesNothing`; earlier: the settlement vectors, the invariant suite |
| HK-6 | The first depositor's inflation: Hundred (2023), Onyx (2023), Sonne (2024) | A creation that is its own first buy | Nothing. A share's price is its units, never a balance: after a first mint of one wei and a donation, the next minter pays the same and leaves whole | `test_HK06_aFirstMintOfOneWeiAndADonationTakeNothingFromTheNextMinter`; earlier: `test_control_donationsCannotMoveRedemptionValue` |
| HK-7 | A price moved for one block: bZx and Harvest (2020), Cream (2021), Mango (2022) | A fill's check against Pyth; nothing else reads a price | Already replayed. No mint, redeem or claim reads a price, and a price can only refuse a fill | `test_aWrongPriceCannotPassAFillTheUnitsRefuse`, `test_exitsAndMintsReadNoPrice`, `test_A713_noContractReadsAPrice`, `test_R12_flashIssuingAroundAFillExtractsNothing`, `test_L03_legLimitStopsASandwichOnOneLeg` |
| HK-8 | Reentrancy, through a callback, across contracts and through views: The DAO (2016), Cream (2021), Curve's pools (2023), Penpie (2024) | The executor's callback, when the index has paid out and not yet been paid | Refused. From inside a fill the factory's two calls back into the index hit its guard, the request escrow refuses a request made on the basket the fill replaced, and the views say what they say after | `test_HK08_fromInsideAFillNoOtherDoorOpens`; mutants HK3, HK4; earlier: the R11 test's thirteen entry points, `test_I01_...`, `test_CRI26_...` |
| HK-9 | A default that passes for a real value: Parity's library (2017), Nomad's zero root (August 2022) | Request ids, proposal ids, creator slots, an uninitialized index | Refused. The request never made is not open even to the hash of nothing; proposal zero is no rebalance | `test_HK09_noEmptySlotPassesForARealOne`; earlier: `test_theImplementationCannotBeInitialized`, `test_initializeIsFactoryOnly`, `test_DA22_CRI25_CRI33_...` |
| HK-10 | A signed message accepted a second time, by another contract or chain | A share's permit: every index runs the same code and two can carry one name | Good once, on one index, on one chain | `test_HK10_aPermitIsGoodOnceOnOneIndexOnOneChain` |
| HK-11 | A permit that a token without one accepts in silence: Multichain (January 2022) | The zap's permit entry points | Already replayed. The zap pulls from its caller alone, so a permit that did nothing leaves only the caller's own allowance | `test_mintWithPermit_aTokenWithoutPermitMintsOnItsApproval`, `test_mintWithPermit_invalidSignatureWithoutAllowanceReverts` |
| HK-12 | A function anyone could call: Poly Network (2021), and most of what was taken in April 2026 | Every state-changing function of the factory (25) and of an index (19) | Refused, each with the error that names why. The tables are held to the ABIs, so a new function fails the test until it has a row | `test_HK12_aStrangerOpensNoDoor` |
| HK-13 | Shares minted that nothing backs: Resolv (March 2026), TesseraDAO (June 2026) | An index's three mints: an issue, a redeem's fee, the streaming fee | Every share is backed by a deposit or by a scale lowered with it, at every fee's cap, over sixty idle years | `test_HK13_noShareIsMintedThatADepositOrTheScaleDoesNotBack` |
| HK-14 | Ether pushed into a contract that counts its balance | A creation's fee, the only ether in the protocol | Nothing. The call's own value is checked and forwarded, never a balance | `test_HK14_etherForcedIntoAContractChangesNothing`; mutant HK6 |
| HK-15 | A vault's rate raised by a donation: the ERC-4626 class of 2023 to 2025 | Pyth's check, which values a wrapped stock at its rate | The raised rate passes Pyth's check and the fill is refused on units, where no rate is read | `test_HK15_aVaultRateRaisedByADonationPassesNoFillTheUnitsRefuse` |
| HK-16 | A pending change that outlives the role that made it | A creator's proposal of weights across a handover | **Found and fixed** | `test_HK16_aHandoverClearsTheOutgoingCreatorsWeights`; mutant HK5 |
| HK-17 | A forged bridge message: Wormhole (February 2022), Nomad (2022) | No protocol contract bridges. The keeper's executor credits what Wormhole's bridge delivered | Already replayed. A credit is the balance that arrived, within the owner's restock allowance | The `test_RS..` tests of `keeper/test/KeeperExecutor.t.sol` |
| HK-18 | A vote bought with a flash loan: Beanstalk (April 2022) | Nothing. There is no governance token and no vote | Does not apply. The owner is a Safe behind timelocks, with no power over funds | None |
| HK-19 | A token that does not behave as an ERC-20: a fee on transfer, a rebase, a hook, two addresses on one ledger, a freeze | A listed component | Already replayed, and the whitelist is the first answer | `test_I01_...`, `test_I02_...`, `test_RW8_...`, `test_RW10_...`, `test_RX8_...`, `test_RB2_RX12_...`, `test_M01_...`, `test_SA01_...` |
| HK-20 | An exit made too dear or impossible | Redeem with a frozen leg, a fill sized from a stale simulation, gas at the widest index | Already replayed | `test_M01_frozenComponentNoLongerLocksTheBasket`, the DA-13 tests, `test_theMostComponentsFitOneTransaction` |

## 3. What a stolen key takes (HK-4)

`test_HK04_everyStolenKeyTogetherMovesNoTokenAndBlocksNoExit` gives a thief the owner's key, the guardian's and the
index's creator's, and uses every power of the three: the fee policy at its caps, a paused mint, every token
delisted, a planted listing, a planted price feed, a new guardian, a new owner, new weights. Not one token leaves the
index, its fees, units and interval are what they were, and its holder redeems the whole basket. What changed: nobody
can mint, and the weights are the thief's, seven days after they were proposed in public.

`test_HK04_theWorstEveryKeyTogetherTakesIsAFifthOfALegAfterAWeeksNotice` then shows the one way value leaves: the
index's own auction. With weights of 99.98%, 0.01% and 0.01% and a feed that calls one ETH twenty billion dollars,
the thief fills its own auction at the last second and takes a fifth of the two small legs, a tenth of the index's
value, for five thousandths of a percent of the large one. A fifth is the cap on units (`MAX_TURNOVER`), which no key
and no price widens: one unit more reverts `LegOutOfBounds`. The owner or guardian may start again a week after a
fill, so it is a fifth of those legs a week.

What that needs, in full:

- **The creator's key**, to change the weights. Alone it does little: the fill after it is held to Pyth's
  tolerance, at most 2% of what it trades, and the owner or the guardian can cancel the proposal for seven days.
- **The owner's key**, to plant a feed, behind two days in which the guardian can cancel it. Alone it cannot change
  an index's weights: a lone fill then takes the index's distance from its weights, which is the known limitation
  "A lone executor keeps the index's distance from its weights" and no more.
- **The guardian's silence**: an honest guardian cancels the weights, the feed and each auction. The owner replaces
  a guardian in seven days, which the guardian cannot stop, so the owner's key outlasts it.

So the full case is the owner's Safe and one index's creator key, about two weeks, in public, with every exit open
throughout. Nothing in it is new: it is the design rule "An index is created on its weights" with every defence
removed, and it is why the app shows a pending change of weights and why the owner is a Safe of three signatures and
the guardian another of two. The keeper's own keys are the keeper's record: a stolen keeper key delivers from stock
only what the owner allowed and can trade the USDC float badly within the floor it names (CF-1, RS-1,
`keeper/README.md`), which is the operator's working capital and never a holder's coin.

## 4. HK-16, the finding

`proposeWeights` records a proposal against the index, not against who made it. `transferCreator` and `acceptCreator`
moved the role and left the proposal, so it could be executed, by anyone, under a creator who never proposed it. The
new creator could cancel it and had the seven days to do so, and a change of weights moves no token, so this is low.
But a role's pending change should not outlive the role: a partner taking over an index the team made, or buying one
from another partner, would have to know to look.

Fixed in `WeightedIndexFactory.acceptCreator`: a pending change of weights is deleted and `WeightsCancelled` emitted.
The factory is 19,096 bytes, and its init code 48,024, 1,128 under EIP-3860. No ABI changed; the factory's release
hash moved. The same shape exists for the owner, whose pending listings, feeds and guardian change survive a transfer
of ownership: left as it is, since the owner is one organisation moving between its own Safes and each proposal is
public and cancellable.

## 5. What the replay got wrong about itself

- `test_HK01_theCallbackClosesWhenItsFillEnds` first sent the fill and then the late callback as two calls of the
  test. Mutant HK1, which never clears the mark, survived it: Foundry clears transient storage between a test's own
  calls, so the mark was gone whether the executor cleared it or not. The test now sends both from one contract call
  (`FillThenCallBack`), and HK1 is killed.
- `test_HK02_noMarkOfOneCreationReachesTheNext` had the same fault and said "one test is one transaction", which is
  false for transient storage. It runs its three creations from one call now (`BatchCreator`), and fails under
  PY26 as the factory's own test does.

A test that passes with its property broken is worth nothing; every test here that guards a line was run against the
mutant of that line.

## 6. What this does not cover

- **Anything off chain.** Bybit's loss began on a developer's machine and ended in a signing screen that showed
  another transaction. No contract answers that: the Safes' signers check the calldata they sign
  (`ConfigureWeighted.safeCalldata`), and the deploy checks refuse a Safe below its threshold or with a module.
- **The app and its hosting**: a replaced front end, a hijacked domain, a poisoned dependency.
- **The keeper's bot, the restock service and Hermes**: their own reviews are `audits/internal/red-team-rz.md` and
  `audits/internal/protocol-docs-review-pd.md`. The bot's Pyth wiring has still not been executed.
- **The compiler and the libraries**, pinned and unread here.
- **Economics**: a market that moves against every index at once, an issuer that fails.
- **What nobody has thought of yet.** A replay tests the past.

## 7. Status of the fixes

| Id | Status | Test | Mutants |
| --- | --- | --- | --- |
| HK-1 | Replayed, refused | `keeper/test/KeeperExecutor.attacks.t.sol` (two tests); `keeper/test/unit/executor-source.test.mjs` | HK1, HK2 |
| HK-2 | Replayed, refused | `test/Attacks.t.sol` | PY26 |
| HK-3 | Replayed, refused | `test/Attacks.t.sol` (two tests); `keeper/test/unit/executor-source.test.mjs` | HK7 |
| HK-4 | Replayed; the bound shown | `test/Attacks.t.sol` (three tests); `keeper/test/unit/executor-source.test.mjs` | The caps' own (V and H) |
| HK-5 | Replayed, refused | `test/Attacks.t.sol` | The rounding's own (V) |
| HK-6 | Replayed, refused | `test/Attacks.t.sol` | None new |
| HK-8 | Replayed, refused | `test/Attacks.t.sol` | HK3, HK4 |
| HK-9 | Replayed, refused | `test/Attacks.t.sol` | None new |
| HK-10 | Replayed, refused | `test/Attacks.t.sol` | None: OpenZeppelin's code |
| HK-12 | Replayed, refused | `test/Attacks.t.sol` | The roles' own |
| HK-13 | Replayed, refused | `test/Attacks.t.sol` | The fees' own |
| HK-14 | Replayed, refused | `test/Attacks.t.sol` | HK6 |
| HK-15 | Replayed, refused | `test/Attacks.t.sol` | None new |
| HK-16 | **Fixed** | `test/Attacks.t.sol` | HK5 |
| HK-7, HK-11, HK-17, HK-19, HK-20 | Replayed by earlier suites | The tests section 2 names | Theirs |
| HK-18 | Does not apply | None | None |

Gates on the change: 634 tests without an RPC, coverage 100% on all 59 files, Aderyn and Wake silent, the keeper's
88 contract tests and 250 unit tests, and the mutation gate's 298 mutants, the seven new ones among them.

## 8. Sources

The incidents of 2025 and 2026 as their post-mortems report them; the older ones are the public record.

- Q1 2026: https://dev.to/ohmygod/the-q1-2026-defi-exploit-autopsy-137m-lost-15-protocols-breached-the-5-root-cause-patterns-and-3o92
- April 2026: https://thehackernews.com/expert-insights/2026/09/aprils-621-million-in-defi-hacks-traced.html
- May 2026: https://halborn.com/blog/post/month-in-review-top-defi-hacks-of-may-2026
- June 2026: https://www.halborn.com/blog/post/month-in-review-top-defi-hacks-of-june-2026
- 2025: https://www.halborn.com/blog/post/year-in-review-the-biggest-defi-hacks-of-2025 and
  https://blocksec.com/blog/top-10-awesome-security-incidents-in-2025
- Balancer V2: https://blog.trailofbits.com/2025/11/07/balancer-hack-analysis-and-guidance-for-the-defi-ecosystem/
- Augustus V6: https://lancershield.github.io/docs/hacks-db/high/ParaSwap.html
- Baited arbitrage bots: https://eigenphi.substack.com/p/anatomy-of-baiting-attack-on-mev-arb-bots
- SwapNet and Aperture: https://dev.to/ohmygod/the-17m-swapnet-arbitrary-call-exploit-why-your-dex-aggregator-approve-is-a-ticking-time-bomb-3n5a
- SIR.trading: https://slowmist.medium.com/fatal-residue-an-on-chain-heist-triggered-by-transient-storage-10909e4a255a
  and https://rekt.news/sirtrading-rekt
