# Consolidated audit of 2026-11-21

An audit of `main` at `5b7635f`, handed to us on 2026-11-21 as five reports that one of them consolidates: a baseline
of the protocol and the keeper (33 findings), an independent second pass (20), a line-by-line reading of the 22
files under `src/` (8), and a follow-up by twenty reviewers that confirmed the two rated High and added a restock
blocker and twelve defensive findings. It covers the contracts, the keeper's executor and bot, the restock service,
the invariant checker and the deployment tooling. It is not the external audit `CLAUDE.md` asks for before any
mainnet: an agent ran it on the working copy. The reports stay outside the repository, since every link in them
names a path on the machine they were written on.

**The ids.** The reports number their findings `H1`, `H2`, `M1` to `M19`, `L1` to `L12`, `R2-01` to `R2-20` and `S01`
to `S08`. Several of those names are already v1 ids here (`M01`, `L06` and their neighbours), so this record and
every test carry the reports' ids under the prefix `CA`, as the review of 2026-09-23 keeps `CR`: `CA-H1`, a test
named `test_CAH1_...`; `CA-R2-15`, a test named `test_CAR215_...`; a node test named `CA-M7: ...`.

**Method.** Every finding was read against the code at its lines before anything was changed, and rated again where
the report's rating did not hold. `CA-H1` was reproduced first, as an executed test against the unmodified executor:
a batch that named a redeem request and paid it nothing delivered four shares of stock to a mint request for one
dollar, with the stock allowance at zero. The owner's call the same day was to fix everything confirmed, the four
changes to `src/` among them. Each fix came with its test, and each test with the mutant it must kill.

**Result.** The reports found no path that takes holders' funds from an index, and neither did the triage. Of the
two rated High, one is a real break of a bound this repository states (`CA-H1`, the keeper's own share stock, with a
stolen keeper key), and one is real and conditional on an issuer destroying a pooled balance (`CA-H2`, rated medium
here). Most of the mediums are faults of the keeper's bot, the restock service and the invariant checker that cost
their operator money or leave him blind, not the holders. Thirty-three of the sixty-one were fixed in code that day,
seven by documentation, and twenty-one were left as they are, each with its reason below. Four of those, the non-EVM
signers' (CA-M14, CA-R2-12, CA-R2-13, CA-L7), were fixed in code on 2026-11-24, before those signers have run:
thirty-seven are fixed in code now, and seventeen left as they are.

## The findings

"Report" is the rating the reports gave. "Here" is the rating after the triage, where it differs.

### Contracts under `src/`

| Id | Report | Finding | Verdict and what was done |
|---|---|---|---|
| CA-H2 | High | `MintRequests` and `BasketBuilder` hold every user's escrow of a token in one balance and compared it with nothing. After an issuer destroyed part of it and let transfers resume, a newcomer's deposit passed every check and paid an earlier user's refund or withdrawal | Confirmed, medium here: it takes an issuer's burn of the pooled balance. It is RX-8's rule, which the hub has had since 2026-10-19, missing on the two escrows. Fixed: both keep `totalEscrow[token]`, and a request, a deposit, a bought leg or a redeemed leg reverts `Underbacked` while the balance is below it. `Underbacked` moved to `IXindexErrors` |
| CA-M1 | Medium | A request records the nonce the index reads when its transaction lands. A settlement between the requester's quote and inclusion opened it on the new basket at the old limit, and the fill's own nonce check let it fill: the gap RW-2 left before inclusion | Confirmed, low here: a few blocks wide and bounded by the settlement's haircut. Fixed: `requestMint(..., expectedNonce)` and `requestRedeem(..., expectedNonce)` revert `StaleRebalanceNonce` before anything is escrowed. The unbound two stay, as `fill(id, amount)` stayed for RW-7 |
| CA-M2 | Medium | The builder's `mint` takes the basket at the call from the whole escrow, with no nonce | Not changed. It is the documented rule ("a buy repeated after a rebalance buys only what the new units add"), and nothing is lost: the minter receives exactly the shares asked for, backed by what was debited, and a leg left short is named by `InsufficientEscrow` |
| CA-M3 | Medium | After an issuer burned part of an index's balance of a component, ordinary redeems are paid from the same coins as the claims recorded before the burn | Confirmed as described, and not changed. The hub pays amounts, never a share of a balance ("Value-bearing amounts are in-kind"), so after a burn it pays first come, first served, shares and claims alike; setting the claims' part aside would only move the race to the claims. Fixed by documentation: `IWeightedHub.totalClaims` no longer says "always covered", and "Issuers can freeze components" says who bears a burn |
| CA-S01 | Medium | `claim` paid a claim whole or reverted. A claimant owed more than an issuer's burn had left could collect none of it, with nobody else owed anything | Confirmed, low here. Fixed: `claim(token, to, amount)` pays part and keeps the rest recorded. A request's escrow in `MintRequests` is still refunded whole or not at all, which is recorded under CA-H2 |
| CA-S02 | Medium | `cancelRebalance()` names no proposal. A Safe's cancel lands hours after it is signed; if the other role had cancelled that proposal and started its own meanwhile, the late cancel removed the newer one, and a batch behind it posted an older quote | Confirmed, low here: it takes the owner and the guardian acting on one index at once. Fixed: `cancelRebalance(proposalId)` reverts `StaleProposal` unless the index's latest proposal is still that one. The runbook's Safe batches use it. The factory's `cancelListing` and `cancelGuardianChange` name no instance either and are not changed: each is behind days of delay, and a wrong cancel there loses a proposal that is proposed again |
| CA-S03 | Low | A settlement during the builder's `buy` or `mint` would size the work for another basket | Not changed. It needs a callback from the paying stablecoin, a route's pool or a component into a settlement of the same index, and the caller would have to be the auction's executor too. The listing rule excludes a component that calls back |
| CA-S04 | Low | After a re-org a `cancel(id)` can close another open request of the same requester | Not changed. The escrow closed returns to the requester either way, and the request meant is still theirs to cancel |
| CA-S05 | Low | A direct caller of `issue` or `redeem` cannot bind the amounts it previewed | Not changed, as documented: an allowance bounds each leg of a direct issue, and the zap and the builder name a nonce for callers that price |
| CA-S06 | Low | `ComponentReturned.amount` is what the zap sent, not what its recipient received | Fixed by documentation: the event says so. A middle token that charges on transfer is the only case, and no listed route has one |
| CA-S07 | Low | "The fill that clears the highest bar is the one that puts the index on its weights" is not exactly true: `L` runs under the logarithm, so of two fills worth the same, one a little short of the weights can score more | Confirmed on the report's own figures (0.02696 at the target against 0.02699 beside it). Fixed by documentation: the hub's and `IWeightedHub`'s headers, and the architecture's line on the opening bar, which also said that only doubling every component clears the first second (`L(0.9)` is 0.5412) |
| CA-S08 | Low | "The index then holds every component's new backing" overstates the settlement's check, which reads only the legs that moved (DA-14) | Fixed by documentation: `IWeightedHub.executeRebalance` and `IRebalanceExecutor` |
| CA-R2-15 | Low | The builder paid a withdrawal or a sale to the paid token's own contract, which the zap refuses (RY-1) | Fixed: both revert `InvalidRecipient` |
| CA-R2-16 | Low | A deposit that delivered nothing succeeded, credited zero and announced it | Fixed: it reverts `TransferShortfall`, as `MintRequests` reverts `NothingEscrowed` |
| CA-L1 | Low | The README called a permit mint "one signature" and said no contract takes ether | Fixed by documentation: one transaction after the permit's signature, and the factory's creation fee is the one place ether enters |
| CA-L5 | Low | This build's decoder rejects the eight-field `Request` of the Sepolia deployment of 2026-11-03 | Not changed: `docs/deployment.md` already says so, and this change set means a new deployment again |

The reports' other observations on `src/`, none numbered: `WeightedMath.settlement` and `quoteCheck` leave their
array lengths to the caller, which `IWeightedMath` now says; the engine's `closing + sent - opening` can overflow
for a balance near `2^256`, which no listed token approaches, not changed; `FeePolicySet`'s description now says the
recipient is read by every index at each call; the factory's header no longer says units are fixed at creation; and
`predictIndexAddress` answers for a basket `createIndex` would refuse, which an app checks by simulating the creation.

### The keeper's executor

| Id | Report | Finding | Verdict and what was done |
|---|---|---|---|
| CA-H1 | High | `fillBatch` spent the share stock's allowance on a count of the shares it was to bring in, made before any arrived, and a redeem side paid nothing is never filled. A batch that named anyone's open redeem request and paid it zero delivered the whole share stock to a mint request, or redeemed it and sold the basket, with the allowance at zero | Confirmed by an executed test, and high for what it breaks: the bound CF-1 states ("a stolen keeper key takes no more of the share stock than the owner's figure"). The bot never builds such a batch. Fixed: the count is held against the shares the executor holds once the batch's last step has run, and the batch reverts `ShareStockShort` if more left than was spent |
| CA-M6 | Medium | A fill named its request by id alone and read it in the same call, which does not bind it to the terms the keeper priced: after a re-org another request can stand behind the id. RW-7 recorded the residual | Confirmed, low here: the float's floor still catches what the routes sell. Fixed: `RequestFill.expected` is the request's hash and `BatchFill.expected` the fold of its requests' hashes, redeem side first; another request behind an id reverts `RequestChanged` or `RequestsChanged` before any swap. The bot hashes the struct it priced |

Also in the executor: its header no longer says anyone can create a factory index.

### The keeper's bot

| Id | Report | Finding | Verdict and what was done |
|---|---|---|---|
| CA-M7 | Medium | `nameUnits` solved for the logarithm's optimum, and the hub scores `L`, which runs under it | Confirmed, low here: every fill it named was accepted, it only took less than it could. With two legs moving inside their caps the old rule took an eighth less (0.1516 against 0.1715 of an index's value, forty minutes into the auction of an index one of whose three coins had doubled and another halved), so the keeper waited for a lower bar than it needed. Fixed: each leg is named where `L'(x) = price · units / (λ · weight)`, checked against an exhaustive search |
| CA-M8 | Medium | A batch and each of its requests reported the same need to the restock's board, which adds its reports up | Confirmed. Fixed: a request reports under its batch while it is in one, and alone otherwise. A batch that no longer forms leaves its report to lapse, since clearing it at once could leave the request off the board |
| CA-M9 | Medium | The ETH price behind a fill's gas estimate is checked fresh at a refresh and then used for up to 25 blocks | Not changed, informational here: five minutes of ETH's price move the gas estimate by a fraction of a percent, and the base fee is read at every block |
| CA-R2-01 | Medium | With `SHARE_STOCK_USD` set, a share kept as stock is valued at its basket's Pyth prices, whether or not each leg could be sold | Not changed: `SHARE_STOCK_USD` is zero by default, an index with a share-priced leg is never stocked, and `keeper/README.md` already calls the share stock's price the operator's risk |
| CA-R2-02 | Medium | The keeper flushed the needs board after every block, a failed one and one stopped behind a transaction included, with a fresh date. Once the reports of the blocks before had lapsed, the restock read "nothing is needed" and could send the stock home | Confirmed: it is RS-8's rule defeated from the writer's side. Fixed: the board is dated by the last block that looked at everything it reports on, and is not written before the first such block |
| CA-R2-03 | Medium | A fill was refused when the stock read of any component failed, a kept or unmoved one included, which is exactly the auction a guardian starts around a coin that no longer answers | Confirmed. Fixed: only the legs the fill moves must be read |
| CA-R2-04 | Medium | One index whose tokens could not be read (`decimals`) threw out of the round for every index | Confirmed. Fixed: such an index is left unvalued and read again later, in the fill checks, the start checks and the request scan |
| CA-R2-05 | Low | A matched buyer and seller on a gated index are left out of a batch, though the batch would issue nothing | Not changed: the conservative rule is the documented one (`keeper/README.md`, `design/2026-11-11-batch-fills.md`) |
| CA-L3 | Low | A batch's back-off is forgotten at each scan | Not changed: the design resets it there on purpose |
| CA-L4 | Low | The restock-ahead simulation ignores a posted quote | Not changed: documented policy; the quote still binds the fill |
| CA-L6 | Low | The restock read a needs board loosely: a date ahead of the clock, a report with no time, a token in another form or an amount that is no number each read as fresh, or dropped a need | Fixed: a board any part of which is not what the keeper writes is unknown |
| CA-R2-20 | Low | `--once` exited 0 after a failed round, and waited for ever for a block it could not read | Fixed in the keeper and the restock: a failed round exits 1, and the keeper gives up on a head after a minute |

Found on the way, in the same code: a request declined for want of stock was checked again up to 200 blocks later,
and its report lasts 75, so the need of a lone request left the board between checks and the restock could send the
coins home. Such a request is now checked again within 50 blocks (`shortRequests`). And a request made before its
index's last settlement, which `MintRequests` can never fill again, is no longer simulated and asks the restock for
nothing: the follow-up's "request demand can outlive viability".

### The restock service

| Id | Report | Finding | Verdict and what was done |
|---|---|---|---|
| Restock blocker | Medium | On `main` the restock read `PYTH()` from the factory, which has had none since 2026-11-10, so no round could price | Confirmed. Fixed by the change that waited on the branch `fix/restock-pyth-address`: Pyth's address comes from the keeper's own book |
| CA-M10 | Medium | A transfer was settled once a transaction was mined on its completing nonce. A cancel mined there, which the README tells the operator to send for a stuck transaction, completes nothing, and the coins stayed at the bridge with the move closed | Confirmed. Fixed: the receiving side is read back, and a transfer it does not show completed stays to be completed |
| CA-M11 | Medium | A mined transaction is recorded at one confirmation and no block hash is kept, so a re-org that removes it leaves its move waiting for an attestation that never comes | Not changed: it holds a coin or a chain until its operator looks, and moves nothing. Recorded here as open |
| CA-M12 | Medium | Two restock processes each load the journal once and save it whole, so each erased the other's moves | Confirmed. Fixed: a lock file beside the journal, taken before it is loaded |
| CA-M13 | Medium | `RESTOCK_DAILY_USD` was charged with what a buy was worth, and its swap may lose `ROUTE_MAX_LOSS_BPS` on top: $20,200 where the README said $20,000 at most | Confirmed, low here. Fixed: the budget bounds what the buys may cost, and the journal counts each at that |
| CA-M14 | Medium | A native coin's gas reserve is not held back from what the plan may sell | Confirmed: the plan's input said the home balance left the reserve out, and nothing did. Sui's, Aptos's and Algorand's coins are their chains' gas coins, so a sale or a bridge transfer could take a wallet's whole balance and leave it no gas for the redeem, the sale or the buy that follow. Fixed on 2026-11-24, before those signers have run: the plan sells or bridges only what is above twice the chain's `GAS_MIN` (2 SUI, 1 APT and 4 ALGO stay), and none of it for a chain with no minimum (`spendable`, `keeper/restock/plan.mjs`); the signer home refuses a sale or a transfer of the gas coin that would leave the wallet under the minimum itself, read when it acts (`signer-home.mjs`) |
| CA-M15 | Medium | Two CCTP burns alike in amount and endpoints could be told apart only by Iris answering for the right transaction | Not changed: it needs Circle's service to answer one transaction's hash with another's message. Recorded |
| CA-R2-06 | Medium | A round's prices are checked fresh once and used for every action of the round, some of which wait minutes for an approval | Not changed, open: each trade is still held to its loss bound against that price |
| CA-R2-07 | Medium | A buy counts against the day from its signing, and ages out while still pending | Not changed: the window is by signing on purpose, and its test says so |
| CA-R2-08 | Medium | A CCTP move in flight is checked against the wallets configured now, so rotating the treasury's key strands it | Not changed: do not rotate a restock key while its journal holds a pending move. The follow-up's same point on signed EVM moves stands with it |
| CA-R2-09 | Medium | Spare stock was bridged out to a chain whose wallet had no gas to redeem it | Confirmed. Fixed: the bridge-out waits for gas, as every other move to that chain does |
| CA-R2-10 | Medium | A funding was planned as what the buys wait for plus the float's whole target. A treasury that could pay for the buy and not for the target got a funding nothing could pay, every round | Confirmed. Fixed: a funding is planned out of what the treasury holds and may draw, the buys' part first |
| CA-R2-11 | Medium | One home chain whose node did not answer stopped the plan for every chain | Confirmed. Fixed: that chain is left out of the round |
| CA-R2-12 | Low | The non-EVM signer refuses a minimum-size buy that rounds a millionth of a dollar under the minimum | Confirmed: the plan sizes a buy in the coin's units, rounded down, and the signer home held its value, recomputed in floats, to `RESTOCK_MIN_USD`, so a buy at the minimum was never tried, as RZ-22 had found on EVM. Fixed on 2026-11-24: a trade's whole is held to the minimum in the coin's units, as the plan sizes it, and only its halvings by their value; a buy one unit under the minimum, or with no price, is still refused |
| CA-R2-13 | Low | The journal can prune a received Solana burn before its rent is reclaimed | Confirmed: a received burn was pruned a week after its receipt, so a reclaim that failed until then, or a service down past it, lost the record that reclaims the event account's rent. Fixed on 2026-11-24: a received burn whose rent is still to reclaim is not pruned until it is reclaimed (`rentToReclaim`, `keeper/restock/journal.mjs`), and `restock.mjs` reclaims by the same rule |
| CA-L7 | Low | A signer subprocess keeps a `--once` run alive | Confirmed: a signer's open pipes hold the parent's event loop and nothing ended them, so a `--once` run never exited, nor a service stopped by a signal. Fixed on 2026-11-24: after its loop `restock.mjs` closes every home's signer, which exits once its input closes and is killed if it still runs ten seconds on; the exit code is the round's (CA-R2-20) |
| CA-L8 | Low | The four signer launchers took a URL's pathname for a file's path, which a folder with a space or an accent breaks | Fixed: `fileURLToPath` |

### The invariant checker

| Id | Report | Finding | Verdict and what was done |
|---|---|---|---|
| CA-M16 | Medium | The request and event cursors moved before their reads, so a failed read skipped its requests or events for good | Confirmed. Fixed: a cursor passes a range only once it has been read |
| CA-M17 | Medium | A round that could not read an index, or one component's balance, dropped its standing breach, which was then announced as cleared | Confirmed. Fixed: a finding on something a round could not read stands until a read shows it gone |
| CA-M18 | Medium | A webhook's answer was not read, so an alert it refused counted as sent, and a breach is raised once. A round the RPC could not serve was only printed | Confirmed. Fixed: alerts are queued until the webhook takes them, and a run of unserved rounds is alerted when it starts and when it ends |
| CA-M19 | Medium | The checker reads the latest block and never rewinds, so a re-org can leave it on an index or an event that is gone | Not changed, documented: run it beside a node you trust and restart it after a deep re-org |
| CA-R2-14 | Medium | A node that had stopped following the chain served the same healthy block for ever | Confirmed. Fixed: a head older than `MAX_HEAD_AGE_SECONDS` is a reader finding |
| CA-L9 | Low | An escrow balance that could not be read counted as zero | Fixed: it is a reader finding |
| CA-L10 | Low | The notices left out plain starts and quotes, which the guardian's runbook acts on, named an event the factory no longer has, and omitted creator approvals | Fixed, and the names are held against the committed ABIs |
| CA-L12 | Low | Nothing checked the RPC's chain or that `REQUESTS` and `BUILDER` belong to `FACTORY` | Fixed: the checker refuses to start |

Also: `MintRequests` and the builder are read apart from the indexes, so one that cannot be read no longer hides the
others' findings.

### Deployment, admission and CI

| Id | Report | Finding | Verdict and what was done |
|---|---|---|---|
| CA-M4 | Medium | The deploy script took any address for the guardian. A single key has no signers to compare with the owner's, so it passed every check | Confirmed. Fixed: on chains 1 and 56 the guardian is a Safe of at least two signatures (`MIN_GUARDIAN_THRESHOLD`). The figure is this record's reading of "the guardian's Safe", and the owner's to change |
| CA-M5 | Medium | The quote's tolerance was described as what a lone executor keeps. It is counted at the quote's prices, fixed at the start: after the market moves, an accepted fill can cost the index the tolerance and that move | Fixed by documentation: `docs/known-limitations.md` |
| CA-L2 | Low | The deployment guide said the wide list is "the other 87" and left `bnb` out of the reference | Fixed by documentation: 76, 80 in all, and `bnb` |
| CA-L11 | Low | CI's coverage gate compared whatever counts a row carried, so a row cut short passed | Fixed: a row without its four counts fails, and `test/Repo.t.sol` pins the step |
| CA-R2-17 | Low | `CheckToken` printed the first holder of `DEFAULT_ADMIN_ROLE` as the role's | Fixed: the report says how many hold it, or that the token does not say |
| CA-R2-18 | Low | A Safe whose owners could not be read was printed "2 of 0", and an owner list cut short at its announced length | Fixed: "its owners unread" |
| CA-R2-19 | Low | The Sepolia test market seeds its pools with no minimum amounts | Not changed: `script/testnet/` never deploys to a mainnet, and its coins are test coins |

The follow-up's other defensive findings, none numbered, are not changed: the transaction tracker counts a failed send
as a replacement; only the top-ranked fill reaches the final gas check; a request's slippage bound can come from a
cached quote at another amount; the executor's three roles may share an address; removing a chain's last coin stops
its adapter while a move there is pending (RZ-18's neighbour); a signer call that never returns blocks its queue; a
`FROM_BLOCK` after the builder's deployment hides earlier escrows; the checker reads the hub's storage slots, which
is deliberate and pinned (`test_theCheckersHubSlotsAreTheHubs`); the guardian's signer comparison reads a Safe's
first sixteen modules; and `CheckToken`'s ERC-1363 probe takes a failed ERC-165 call for a negative answer.

Found on the way and fixed: `docs/deployment.md` still called a lone executor's take "the rebalance's proceeds, never
the holders' principal", the wording `CLAUDE.md` withdrew on 2026-11-10.

## Status of the fixes

A mutant's suite is the suite of the test that kills it. The node tests are in `keeper/test/unit/`; "harness" is
`keeper/test/harness/requests.test.mjs`, which needs the keeper's dependencies and is not in CI.

| Id | Tests | Mutants |
|---|---|---|
| CA-H1 | `test_CAH1_aRedeemSidePaidNothingBringsNoSharesIn` in `keeper/test/KeeperExecutor.t.sol` | C15; B1 and B2 follow the rewritten line |
| CA-H2 | `test_CAH2_noRequestIsTakenIntoAnUncoveredEscrow` and `test_CAH2_theTotalIsTheOpenEscrows` in `test/MintRequests.t.sol`, and the total in `invariant_theBalanceIsTheOpenEscrowsPlusDonations`; `test_CAH2_nothingIsCreditedIntoAnUncoveredEscrow`, `test_CAH2_theTotalIsTheEscrows` and `test_CAH2_aPassThroughLegIsCheckedOnceTheRefundHasLeft` in `test/BasketBuilder.t.sol` | C1, C2, C3; C6, C7, C8 |
| CA-M1 | `test_CAM1_aBoundRequestIsRefusedAfterASettlement`, `test_CAM1_aBoundRequestChecksItsArgumentsFirst` and `test_CAM1_theBoundRequestsShareTheGuard` in `test/MintRequests.t.sol` | C4, C5 |
| CA-M4 | `test_CAM4_onAMainnetTheGuardianIsASafeOfMoreThanOneKey` in `test/Scripts.t.sol` | C19, C20 |
| CA-M6 | `test_CAM6_aFillRefusesARequestItsKeeperDidNotPrice` and `test_CAM6_aBatchRefusesRequestsItsKeeperDidNotPrice` in `keeper/test/KeeperExecutor.t.sol`; the harness's two `CA-M6: ...` tests, whose hashes were computed by `cast` | C16, C17, C18 |
| CA-M7 | `CA-M7: nameUnits takes what the hub's own score allows, against an exhaustive search` in `units.test.mjs` | C29 |
| CA-M8 | the harness's `CA-M8: ...` test | none: the wiring has no unit suite |
| CA-M10 | `CA-M10: a completing transaction that was mined proves nothing: the other side is read back` in `restock-advance.test.mjs` | C40, C41 |
| CA-M12 | `CA-M12: the journal has one writer at a time, and a lock nobody holds is taken over` in `restock-journal.test.mjs` | C42 |
| CA-M13 | `CA-M13: a day of buys may cost RESTOCK_DAILY_USD at most, each one's loss bound included` in `restock-plan.test.mjs`, and the journal's budget test | C38, C39 |
| CA-M14 | `CA-M14: a chain's own gas coin keeps twice the chain's gas minimum at home, never sold or bridged` in `restock-plan.test.mjs`; `CA-M14: a chain's own gas coin is sold or bridged only while the wallet keeps the chain's gas minimum` in `restock-signer-home.test.mjs` | C44, C45; C46 |
| CA-M16 | `CA-M16: a cursor moves past a range only once it has been read` in `invariants.test.mjs` | C31 |
| CA-M17 | `CA-M17: a finding stands while what it is about cannot be read` in `invariants.test.mjs` | C30 |
| CA-M18 | `CA-M18: an alert the webhook did not take stays queued, in order, until it does` in `invariants.test.mjs` | C32 |
| CA-S01 | `test_CAS01_aClaimCanBeCollectedInPart` and `test_CAS01_aPartialClaimChecksItsArguments` in `test/WeightedHub.t.sol` | C12, C13 |
| CA-S02 | `test_CAS02_aCancelBoundToItsProposalSparesTheNext` in `test/WeightedHub.rebalance.t.sol`; the row `test_aBoundCancelIsTheCancelOfTheProposalItNames` in `test/WeightedHub.states.t.sol` | C14 |
| CA-R2-02 | the two `CA-R2-02: ...` tests in `needs.test.mjs` | C23 |
| CA-R2-03 | the last test of `requests.test.mjs` (`movingReadFailed`) | C26 |
| CA-R2-04 | the harness's `CA-R2-04: ...` test, for the request scan; the keeper's loop has no unit suite | none |
| CA-R2-09 | `CA-R2-09: spare stock is not sent to a chain whose wallet is short of gas` in `restock-plan.test.mjs` | C37 |
| CA-R2-10 | `CA-R2-10: what a buy waits for is funded first, and the float's target with what the treasury has left` in `restock-plan.test.mjs` | C36 |
| CA-R2-11 | none: the restock's own loop has no unit suite | none |
| CA-R2-12 | `CA-R2-12: a buy the plan sized at RESTOCK_MIN_USD is tried, though its worth in floats is a millionth under it; one below it is not` in `restock-signer-home.test.mjs` | C47, C48 |
| CA-R2-13 | `CA-R2-13: a received burn whose event account holds its rent is kept until the rent is reclaimed` in `restock-journal.test.mjs` | C49 |
| CA-R2-14 | `CA-R2-14: a head that has stopped moving is a reader finding, raised once however old it grows` in `invariants.test.mjs` | C34 |
| CA-R2-15 | `test_CAR215_theTokenPaidOutIsNoRecipient` in `test/BasketBuilder.t.sol` | C9, C10 |
| CA-R2-16 | `test_CAR216_aDepositThatDeliversNothingIsRefused` in `test/BasketBuilder.t.sol` | C11 |
| CA-R2-17 | `test_CAR217_theReportSaysHowManyHoldTheAdminRole` in `test/CheckToken.t.sol` | C22 |
| CA-R2-18 | `test_classify` in `test/CheckToken.t.sol` | C21 |
| CA-R2-20 | none: the two services' loops have no unit suite | none |
| CA-L6 | `CA-L6: a board that is not what the keeper writes is unknown, never read in part` in `needs.test.mjs` | C24, C25 |
| CA-L7 | `CA-L7: the signer ends when the run does, so a one-shot run exits once its round is over` in `restock-signer-home.test.mjs`, which runs a signer and a run of its own and reads `restock.mjs` for the close after its loop | C50, C51 |
| CA-L8 | `CA-L8: a signer is launched by its file's path, which a URL's pathname is not` in `restock-signer-home.test.mjs` | C43 |
| CA-L9 | the escrow test of `invariants.test.mjs` | C33 |
| CA-L10 | `CA-L10: every event the checker watches is an event of the committed ABIs, plain starts and quotes among them` in `invariants.test.mjs` | C35 |
| CA-L11 | the coverage step's pin in `test_XA10_A712_A717_ciRunsEveryGate`, `test/Repo.t.sol` | none |
| CA-L12 | none: the checker's start-up has no unit suite | none |
| The request short of stock, and the request its index has moved on from | the last tests of `backoff.test.mjs` and `requests.test.mjs`, and the harness's test of the stale request | C28, C27 |

Fixed by documentation alone, with no test: CA-M3, CA-M5, CA-S06, CA-S07, CA-S08, CA-L1, CA-L2. Not changed, with no
test: CA-M2, CA-M9, CA-M11, CA-M15, CA-M19, CA-S03, CA-S04, CA-S05, CA-L3, CA-L4, CA-L5, CA-R2-01, CA-R2-05,
CA-R2-06, CA-R2-07, CA-R2-08, CA-R2-19.

The hub's R11 test re-enters thirteen entry points now, the partial claim and the bound cancel among them.

## What changed for integrators

- **A new deployment is a whole one.** `src/` changed, so all four release hashes moved.
- **`MintRequests`**: `requestMint` and `requestRedeem` each have an overload ending in `expectedNonce`; a new view,
  `totalEscrow(token)`; a new revert of both request calls, `Underbacked`. `Request` and `fill` are unchanged.
- **`BasketBuilder`**: a new view, `totalEscrow(token)`; `Underbacked` from `deposit`, `buy` and `redeem`;
  `InvalidRecipient` when a withdrawal or a sale is paid to the paid token itself; `TransferShortfall` from a
  deposit that delivered nothing.
- **`WeightedHub`**: `claim(token, to, amount)` and `cancelRebalance(proposalId)`, with `ClaimTooLarge` and
  `StaleProposal`. Both names are overloaded now, so a caller names the signature. `Underbacked` is declared in
  `IXindexErrors`; its selector is the same.
- **`KeeperExecutor`**: `RequestFill` and `BatchFill` each carry `expected`; `ShareStockShort` and `RequestsChanged`.
  An executor of the build before does not serve this bot.
- **The restock's journal** records `maxUsd` with each buy; an older entry counts at its worth.

## Gates

Run on the working tree of 2026-11-21, on the branch `fix/audit-2026-11-21`:

- `forge fmt --check`, `forge build --sizes --deny warnings` and `forge lint -D notes`: clean, for the repository
  and for `keeper/`. The hub is 21,627 bytes, 2,949 under EIP-170.
- `forge test`, fork suites aside: 555 passing, none failing. `forge coverage`: 100% of lines, statements, branches
  and functions on all 51 files.
- `forge test --root keeper`, its fork test aside: 83 passing.
- `node --test keeper/test/unit/*.test.mjs`: 232 passing. The harness: 13 passing.
- The mutation gate, `python3 -I test/mutants/run.py`: 196 of 196 mutants killed, the 45 this change adds or
  rewrites among them (C1 to C43, B1, B2).
- Aderyn: no finding. `wake detect all src`: no detection.
- The fork suites, on public RPCs pinned eight blocks under the head on 2026-11-21 (Ethereum near block 26,463,960,
  BNB Chain at 134,900,245): `Security.fork` 9 of 9, `MainnetAddresses.fork` 8 of 8, `WeightedHub.fork`'s four
  drills, BNB Chain's suite 13 of 13 with a Safe for its guardian, and the executor's fork test 3 of 3.
  `IndexZap.fork` 11 of 12: `testFork_mintWithUSDC` misses its sanity floor of $100, the basket being worth $86.54 at
  the head, as on 2026-11-18 (price, not code).
- On 2026-11-24, for the four non-EVM fixes: `node --test keeper/test/unit/*.test.mjs` 269 passing, none failing;
  mutants C44 to C51 killed, and every mutant of the table still applies (`--check`).

## Open

**Note of the same day, on the release candidate** (`release/2026-11-21-candidate`, which holds these fixes and the
xStocks listing). The first two items below are settled, and the third in part:

- The fork suites ran on archive RPCs at their pinned blocks: Ethereum's five and BNB Chain's, 62 tests, none failed
  or skipped, `WeightedHub.fork`'s two whole-list tests, `CheckToken.fork` and `testFork_mintWithUSDC` among them,
  and the executor's 3 of 3.
- Two fork tests now drive the escrow rule and the bound request on mainnet Tether, whose owner destroys the
  contract's USDT on the fork: `test_CAH2_CAM1_noRequestPaysForAnEscrowTetherDestroyed` and
  `test_CAH2_noDepositPaysForAnEscrowTetherDestroyed` (`test/fork/Security.fork.t.sol`, 11 of 11). The partial
  claim and the bound cancel are still covered by the unit suites alone.
- The keeper's end-to-end test ran, 42 of 42 on a mainnet fork at block 26,441,062: the bot's solver and the fills' `expected` on four auctions,
  and a bound mint and a bound redeem request filled in one `fillBatch` against real pools, the first requests any
  run of it has filled.
- The restock's end-to-end test ran on Base and on Avalanche, 29 of 29 each: the planner's funding order, the
  budget, the completion read back and the journal, with real CCTP and Wormhole contracts on the forks. On Optimism
  it stopped at the buy, 17 of 29: no route bought $1,430 of OP within `ROUTE_MAX_LOSS_BPS`, on the depth of OP's
  pools that day and not on this change (`keeper/README.md`, Restock).

- **An archive run of the fork suites.** What a public node served passed (Gates, above). Left for an archive RPC at
  the pinned block: `WeightedHub.fork`'s two whole-list tests, `CheckToken.fork`, and `IndexZap.fork`'s
  `testFork_mintWithUSDC`, whose floor the head's prices miss. No fork test drives the new paths themselves: the
  bound request, `Underbacked` on Tether's and Circle's real contracts, the partial claim and the bound cancel are
  covered by the unit suites alone.
- **The keeper's end-to-end tests have not run on this change**: the fills' new `expected` field, the bot's solver,
  the board's dating and the restock's planner are covered by unit and harness tests only.
- **A new Sepolia deployment**, the executor included, before the bot of this build serves anything there.
- **The app and the backend**: the bound request calls, `cancelRebalance(proposalId)` in the Safe batches, and
  `Underbacked` as a state to show.
- **Before the non-EVM signers run**: a live run of each, with funded wallets. Their four findings of this audit,
  CA-M14, CA-R2-12, CA-R2-13 and CA-L7, are fixed since 2026-11-24, by unit tests and mutants C44 to C51 alone.
- **Left as they are**, each with its reason above: CA-M11, CA-M15, CA-M19, CA-R2-01, CA-R2-06, CA-R2-08, and the
  follow-up's unnumbered findings.
