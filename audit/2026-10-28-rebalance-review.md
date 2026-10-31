# Review of the rebalance surface, 2026-10-28

The rebalance surface on `main` at `9d70837` (the build after the RX-3 fix of 2026-10-26 and the license change of
2026-10-28) was reviewed for bugs: `WeightedHub`'s start, cancel, settlement, price read, backing post-check and
timing; `WeightedMath`'s targets, caps, steps and amounts; the keeper executor's fill path (`KeeperExecutor.fill`,
`_sell`, `_acquire`, `_checkRoutes`); the zap's and the builder's nonce checks; the bot's start call and the committed
ABI. Each path was traced against the design rules of `AGENTS.md`, then probed with eight scratch tests (auction-end
boundaries, a stale keep mask after an expiry, a streaming accrual inside a fill, the math at a hundred legs near the
unit ceiling at `MAX_PRICE`, a growing leg at `MU_MAX`, two tokens that refuse or lose a self-transfer) and with four
mutants outside the list `AGENTS.md` keeps: the auction's last second refused (`>=` in `_openMu`), a start allowed in
that second (`<` in `startRebalance`), the probe's balance re-read dropped, and the hub's own `published < time`
check dropped. The scratch tests were deleted; the hub was restored byte-exact after each mutant. The same day the
other five contracts of `src/` (`WeightedIndexFactory`, `MintRequests`, `UniversalRouterSwaps`, `IndexZap`,
`BasketBuilder`) and the three libraries were read line by line against the same rules: the creator's two steps, the
listing and guardian windows, the salt's contents and the unit caps; the escrow invariant and the measured fills; the
command and action layouts, the direction each V4 path is walked, the hookless rule and the sweep's measuring; the
nonce checks, the pass-through legs' limits, the refunds, the escrow credits and the builder's probe.

**Result.** No change to a contract in `src/`. No path moves funds from holders or escrows outside the documented
bounds, and no revert blocks an exit. The rounding chain (targets up, a shrinking step down, a growing step up by
`μ · share` rounded up) delivers at least `μ` times what it takes at the settling prices; the turnover and growth caps
bound `share` on units alone, and a `share` of zero reverts `NothingToRebalance` (V5-L3); one hundred legs at 2^96
units and `MAX_PRICE` cannot overflow the moving value. The last second of an auction fills at `MU_MIN`, a start that
second is refused, the guardian may restart one second later and a stranger `REBALANCE_DELAY` after; a start writes its
keep mask before it reads the feeds, so a stale mask is never read; a fill's streaming accrual pays the creator, never
the executor, and `creatorOf` can never be zero, the factory or an index. The keeper's one route per component serves
both `exactInput` and `exactOutput`, both encoded component to USDC. The first two mutants fail existing tests. Four
findings follow, none in the hub's logic: one gap in the admission check, two belts the suite did not pin, and one
stale line of documentation.

Each id is `RB-…`. A fixed finding's test carries its id, as `AGENTS.md` gate 6 requires, and the two mutants that
passed before now fail their tests.

| Id | Verdict | Finding | Status |
|---|---|---|---|
| RB-1 | Confirmed, low | `CheckToken`'s transfer simulation never tried a transfer to oneself, which the hub's RX-12 probe is, so a token that refuses one passed admission and could never be bought by a fill | Fixed: `_simulate` sends one raw unit from `RECIPIENT` to itself after the exact check. `test_RB1_aTokenThatCannotTransferToItselfIsRefused` in `test/CheckToken.t.sol` |
| RB-2 | Confirmed, test gap | The probe's balance re-read after its transfer (`WeightedHub._checkBacking`) had no test: dropped, every hub test passed | Fixed: `test_RB2_RX12_theProbeReadsTheBalanceAfterItsTransfer` in `test/WeightedHub.rebalance.t.sol`, on `MockSelfLosingToken` |
| RB-3 | Confirmed, test gap | The hub's own `published < time` check (`WeightedHub._readPrices`) had no test: `MockPyth` tampered a late time, never an early one | Fixed: `Tamper.EarlyTime` in `test/mocks/MockPyth.sol`; `test_RB3_anUpdateBeforeThePinnedSecondIsRefused` |
| RB-4 | Confirmed, documentation | `ARCHITECTURE.md` still named `startRebalance(keepMask)`; the signature takes the price update since RX-3 | Fixed in the line. No test |
| RB-5 | Informational | The zap refuses as `to` only the index it mints or burns; the builder refuses every factory index (`FACTORY.isIndex(to)`), since no index can move a token or a share it receives (RT-21) | Open, the owner's call: a one-line hardening of `IndexZap._checkIndexCall` that moves the CF-5 release hashes. No test |

## RB-1: the admission check never tried a self-transfer (confirmed, low)

`WeightedHub._checkBacking` proves a leg a fill bought can leave the index by sending itself one raw unit of it and
reading the balance again (RX-12). `CheckToken._simulate` moved the token `SENDER` to `RECIPIENT`, approved `SPENDER`
and moved `SENDER` to `PAYEE`, and compared every balance exactly; no call sent a token to its own holder. A token
with `require(from != to)`, or one whose self-transfer answers false, therefore reported `Exact` and could be listed,
and every fill that grew it would revert `CannotSendOut`: the leg could only shrink or be kept. Liveness of that leg,
no loss.

Reproduced on two mock tokens (`test/mocks/MockSelfTransferTokens.sol`): a fill buying either leg reverts
`CannotSendOut`, and `_simulate`, read line by line, had no self-transfer.

**Fix.** After the exact-balance check, `RECIPIENT`, which holds `half`, sends itself one raw unit; a call that fails
is `Failed`, and a balance the unit left is `Inexact`, so both refuse. The unit goes from `RECIPIENT` and last: a
first attempt sent it from `SENDER` after `transferFrom`, where `SENDER` holds `funded − 2·half`, zero for an even
balance, and failed on every standard token. The header of `script/CheckToken.s.sol` names the step.

**Pending.** `testFork_everyWideTokenPassesTheCheck` (`test/fork/CheckToken.fork.t.sol`) runs the simulation on the
91 listed tokens; it was not rerun here. A listed token that refuses a self-transfer would now read `Refused` there,
which is the finding's point. Run it before the next push, as gate 4 requires for a `CheckToken` change.

## RB-2: the probe's balance re-read was not pinned (confirmed, test gap)

The probe is `trySafeTransfer(address(this), 1) || balanceOf(address(this)) < balance`. The first half catches a token
that reverts or answers false (`MockSenderBlockToken`, `test_RX12_aFillCannotBuyALegTheIndexCannotSend`); the second
catches one that answers true and loses the unit, as a fee or burn on a self-transfer would. With the second half
removed, the 95 tests of the three hub suites passed.

**Fix.** `MockSelfLosingToken` answers true and burns the unit. `test_RB2_RX12_theProbeReadsTheBalanceAfterItsTransfer`
builds a two-leg index on it, has a fill buy the leg, which reverts `CannotSendOut`, then has a fill sell it, which
settles. Checked against the mutant: `next call did not revert as expected`.

## RB-3: the hub's own early-time check was not pinned (confirmed, test gap)

`_readPrices` requires every feed Pyth returns to be published at or after `priceTime()` and before the block. Pyth's
`parsePriceFeedUpdatesUnique` enforces the same window, so the hub's check is a belt; `AGENTS.md` and the function's
comment say the hub checks it "rather than trusting" Pyth. `MockPyth` could tamper a late time (`Tamper.LateTime`) but
not an early one, so the `published < time` term had no test and could be dropped unnoticed.

**Fix.** `Tamper.EarlyTime` sets the first feed's publish time to `minPublishTime − 1`;
`test_RB3_anUpdateBeforeThePinnedSecondIsRefused` expects `PriceMismatch(ETH_ID, time − 1)`. Checked against the
mutant: the fill settles instead.

## RB-4: a stale signature in the architecture record (confirmed, documentation)

`ARCHITECTURE.md`'s contract map wrote `startRebalance(keepMask)`; since RX-3 the function is
`startRebalance(uint256 keepMask, bytes[] priceUpdate)`, payable, and reads every moving feed. The bot
(`keeper/keeper.mjs`) and `abi/WeightedHub.json` already carry the new signature. Fixed in the line.

## RB-5: the zap's recipient check admits another index (informational, open)

`IndexZap._checkIndexCall` refuses as `to` the zap, the index of the call, the router, the pool manager and the
factory (RT-21). `BasketBuilder._checkRecipient` refuses the same and, in place of the one index, every index the
factory made. A hub's `_update` refuses only its own address and the factory, so shares of index A sent to index B
stay there for good, and a burn paid to an index is a donation to its holders at best. Only the caller's own funds and
only on a `to` the caller chose, as with any wrong address, so this is not a loss path. The two contracts differ where
`AGENTS.md` says the builder's recipients "are checked as the zap's"; the stricter check is the builder's, and the
zap could take it in one line, at the cost of moving the CF-5 release hashes and a fork run. Left to the owner.

## What was checked and found sound

For the next reviewer, the questions this review closed, with where the answer is:

- A growing leg's step at `MU_MAX` with `share` at the growth cap: at most about 2.02 times its units, plus two raw
  units of rounding (the target and the step both round up). `test_RX15_*`, `test_theGrowthFactorRoundsUp`.
- A fill whose shrinking steps all floor to zero on a dust supply settles at `MU_MAX` and is paid nothing; one where
  only some floor to zero keeps the zero legs' units as stepped, their value staying with the holders. `test_R14_*`,
  `test_RT12_SA07_*`.
- A streaming accrual inside `_settle` passes `msg.sender` as the fallback creator; the fallback is reached only for
  a creator that is zero, the factory or an index, which `createIndex`, `transferCreator` and `acceptCreator` never
  allow.
- The keeper's `_acquire` uses `exactOutput` with the same path `_sell` gives `exactInput`: both start at the
  component and end at USDC, which is the order each needs.
- A stranger's mask-free starts while a leg is frozen cannot be filled and expire; the guardian cancels and starts a
  keep-mask one in the same block at any time during the proposal, or in the `REBALANCE_DELAY` after its expiry. The
  trust that the guardian is on call is DA-12's.
- The factory: a listing proposal is refused while the token is listed or another proposal of it is live, and only
  `executeListing` lists, clearing the proposal as it does, so a token is never listed twice; `delist` keeps the
  token's terms, which the next listing overwrites; the guardian can veto only its own removal, never a replacement;
  `_contentsHash` covers every term the salt must commit to.
- `MintRequests`: every request is closed before a token moves, a fill measures the requester's balance so a self-fill
  or a fee cannot pass the limit, and the whole escrow is paid, so the contract's balance of each token is its open
  escrows plus donations.
- The swap engine: the V3 exact-output path and the V3 exact-input path both start at the component and end at the
  user's token, which is the order each command reads; a V4 exact-output route is walked from its last key, so its
  far end is key 0, and an exact-input route's is its last key; a hookless key cannot be a dynamic-fee pool, since V4
  refuses that combination at initialization; the sweep's minimum of zero never fails an `execute`; a sale hop's
  unsold input is what the sweep brought back, so a balance the router already held cannot underflow it.
- The zap and the builder: `previewIssue` and the `issue` that follows in the same transaction accrue the same
  streaming fee and compute the same basket, so a mint pulls exactly what was approved; a buy's pre-fund never
  exceeds the call's own budget, so another user's escrow of `tokenIn` is never spent; a component named twice in one
  `buy` is bought once, and a token named twice in one `sell` is sold once; the pass-through legs honour their limits
  on both sides; a builder probe failing after a redeem reverts every credit, so a leg the builder could not send out
  is left to `redeemSkipping` on the hub.
