# The rebalance state machine (2026-10-29)

Step 1 of the logic-hardening plan agreed on 2026-10-29: write down the state machine `WeightedHub`'s rebalance
follows, as the contract defines it, and test every cell of its transition matrix, each test checked against mutants
of the hub. This record is the specification; `test/WeightedHub.states.t.sol` is the matrix. The hub is unchanged:
the record describes the code at `ccf1da4` (the review branch of 2026-10-28, after the RX-3 change of 2026-10-26), and
a later change to the rebalance must change this record and the suite in the same commit.

The spec (`design/2026-10-05-custom-weights.md`, section 5) and ARCHITECTURE.md (section 3.1) describe the lifecycle
in prose. What was missing is one table that names every state, every action from it and the exact result, so a
reviewer can see that no cell is unspecified and no test is missing.

## 1. The state

The rebalance keeps eight words of storage, and only these calls move them:

| Storage | Written by | Meaning |
|---|---|---|
| `_eta` | `startRebalance` (`now + REBALANCE_DELAY`); cleared by a fill or a cancel | When the auction opens; zero while no proposal exists |
| `_keepMask` | `startRebalance`; cleared with `_eta` | The components the proposal keeps |
| `lastRebalance` | `initialize` (creation); a fill (`now`) | When the last fill settled |
| `_maskedFill` | a fill | Whether that fill had a keep mask (XS-3) |
| `restartAllowedAt` | `cancelRebalance` | Until when only the owner or guardian may start |
| `proposalCount` | `startRebalance` | Starts ever made, cancelled and expired ones included |
| `rebalanceNonce` | a fill | Fills ever settled |
| the initialized version | `initialize` | 1 for a clone the factory made; the implementation and a stray clone are not 1 |

Three quantities derive from them and the clock:

- `earliest = lastRebalance + (_maskedFill ? MIN_REBALANCE_INTERVAL : rebalanceInterval)`: the interval's end
  (`earliestRebalance()`).
- `end = _eta + AUCTION_DURATION`: the auction's last fillable second.
- `permissionlessAt = max(restartAllowedAt, _eta == 0 ? 0 : end + REBALANCE_DELAY)`: from when a stranger may start
  (`_permissionlessAt`).

The constants: `REBALANCE_DELAY` 2 hours, `AUCTION_DURATION` 4 hours, `MIN_REBALANCE_INTERVAL` 7 days, and the
index's own `rebalanceInterval` in [7, 91] days.

## 2. The eight states

A state is a predicate on the storage and the clock. The eight below partition every reachable configuration: an
index is always in exactly one of them, and `_stateOf` in the suite classifies an index from its public views alone.

| State | Condition | Who may start | `canStartRebalance` | `currentMu` | `pendingRebalance` |
|---|---|---|---|---|---|
| Uninitialized | the initialized version is not 1 | nobody | false | 0 | (0, 0) |
| Interval | `_eta == 0`, `now < earliest` | nobody, the owner and guardian included | false | 0 | (0, 0) |
| Cooldown | `_eta == 0`, `earliest <= now < restartAllowedAt` | the owner or guardian | false | 0 | (0, 0) |
| Open | `_eta == 0`, `earliest <= now`, `restartAllowedAt <= now` | anyone without a mask, the owner or guardian with one | true | 0 | (0, 0) |
| Notice | `_eta != 0`, `now < _eta` | nobody | false | 0 | (eta, mask) |
| Auction | `_eta <= now <= end` | nobody; a fill settles | false | `MU_MAX` falling to `MU_MIN` | (eta, mask) |
| Expired, held | `end < now < end + REBALANCE_DELAY` | the owner or guardian | false | 0 | (eta, mask), stale |
| Expired, open | `_eta != 0`, `end + REBALANCE_DELAY <= now` | anyone without a mask, the owner or guardian with one | true | 0 | (eta, mask), stale |

The two expired states are one proposal nobody filled. No event marks the expiry and nothing clears it: the next
start replaces it, a cancel clears it, and `pendingRebalance` reports it until then (the interface says so).
"Settled" and "cancelled" are not states: a fill lands in Interval and a cancel in Cooldown or Open, and what
distinguishes them afterwards is which hold runs, the interval or the cooldown.

## 3. The transition matrix

Every action from every state. The columns are the hub's five mutating rebalance calls, split by the caller
(a stranger, or the owner or guardian, whom `isOwnerOrGuardian` treats alike) and by the keep mask; "holders" is
`issue`, `redeem`, `redeemSkipping` and `accrueFees`, which read none of the eight words. A cell names the error the
call reverts with, or the state it lands in. `start` is `startRebalance`; `fill` is either `executeRebalance`
overload.

| State | start, stranger | start, owner or guardian | start with mask, stranger | start with mask, owner or guardian | cancel, stranger | cancel, owner or guardian | fill | holders |
|---|---|---|---|---|---|---|---|---|
| Uninitialized | `NotInitialized` | `NotInitialized` | `NotInitialized` | `NotInitialized` | `NotInitialized` | `NotInitialized` | `NotInitialized` | `NotInitialized` |
| Interval | `RebalanceTooSoon` | `RebalanceTooSoon` | `RebalanceTooSoon` | `RebalanceTooSoon` | `NoPendingRebalance` | `NoPendingRebalance` | `NoPendingRebalance` | ok, Interval |
| Cooldown | `Unauthorized` | Notice | `Unauthorized` | Notice | `NoPendingRebalance` | `NoPendingRebalance` | `NoPendingRebalance` | ok, Cooldown |
| Open | Notice | Notice | `Unauthorized` | Notice | `NoPendingRebalance` | `NoPendingRebalance` | `NoPendingRebalance` | ok, Open |
| Notice | `RebalancePending` | `RebalancePending` | `RebalancePending` | `RebalancePending` | `Unauthorized` | Cooldown | `RebalanceNotReady` | ok, Notice |
| Auction | `RebalancePending` | `RebalancePending` | `RebalancePending` | `RebalancePending` | `Unauthorized` | Cooldown | Interval (see below) | ok, Auction |
| Expired, held | `Unauthorized` | Notice | `Unauthorized` | Notice | `Unauthorized` | Cooldown | `RebalanceExpired` | ok, Expired, held |
| Expired, open | Notice | Notice | `Unauthorized` | Notice | `Unauthorized` | Open | `RebalanceExpired` | ok, Expired, open |

What each landing writes:

- **Notice**, from a start: `_eta = now + REBALANCE_DELAY`, `_keepMask` the mask, `proposalCount + 1`, and
  `RebalanceStarted(proposalCount, rebalanceNonce + 1, caller, mask, eta)`. A start over an expired proposal writes
  nothing else: `restartAllowedAt` stays, so no cooldown follows it.
- **Cooldown or Open**, from a cancel: `_eta` and `_keepMask` cleared, and `restartAllowedAt = now + REBALANCE_DELAY`
  when the proposal was in its notice or auction, else `permissionlessAt` of the expired proposal (VR-04: a cancel
  of an expiry neither shortens nor extends the hold the expiry set). The event is
  `RebalanceCancelled(proposalCount, caller, restartAllowedAt)`. The landing is Cooldown while that time is ahead,
  Open once it has passed, which is the case for a cancel in Expired, open.
- **Interval**, from a fill: the new units, `_maskedFill = (_keepMask != 0)`, `rebalanceNonce + 1`,
  `lastRebalance = now`, `_eta` and `_keepMask` cleared, then `Rebalanced`. `restartAllowedAt` is untouched, and it is
  at or before `now` (invariant I3 below), so the interval is the only hold that follows a fill.
- **Auction, unchanged**, from a fill that reverts after the clock: `NothingToRebalance` when the index is on its
  weights (V5-L2), `RebalanceMovedOn` when the settlement outgrew the caller's bound (DA-13), `LengthMismatch` on a
  bound of the wrong length, `RebalanceUnderfunded` or `CannotSendOut` after the callback, and every price refusal.
  A revert writes nothing, so the proposal stands and the auction goes on.

A keep mask that names a component the index does not have, or leaves fewer than `MIN_COMPONENTS` moving, is
`InvalidKeepMask` for any caller, in every state where a start reaches the mask check: Cooldown, Open and both
expired states. In Interval it is `RebalanceTooSoon` and in Notice and Auction `RebalancePending`, because those
checks come first.

## 4. The clock

The clock moves the state at these exact seconds, and nothing else does:

| From | To | At | Pinned by |
|---|---|---|---|
| Interval | Open | `earliest` | a start at `earliest - 1` is `RebalanceTooSoon(earliest)`, at `earliest` it succeeds |
| Cooldown | Open | `restartAllowedAt` | a stranger's start a second before is `Unauthorized`, at it succeeds |
| Notice | Auction | `_eta` | a fill at `_eta - 1` is `RebalanceNotReady(eta)`, at `_eta` it settles at `MU_MAX` |
| Auction | Expired, held | `end + 1` | a fill at `end` settles at `MU_MIN`; a start at `end` is `RebalancePending(end)`; at `end + 1` a fill is `RebalanceExpired(end)` |
| Expired, held | Expired, open | `end + REBALANCE_DELAY` | a stranger's start a second before is `Unauthorized`, at it succeeds |

The hold after an expiry runs from the last fillable second, so it ends one second earlier than a cancel's at the
same moment would (CR-I02, documented in 2026-09-23's triage; the second moves no value).

## 5. Invariants the matrix implies

- **I1. A proposal exists only after the interval.** `_eta != 0` implies `earliest <= now`: a start checks the
  interval first, and `earliest` moves only at a fill, which clears `_eta`. So no state has both a proposal and the
  interval running, and the matrix has no such row.
- **I2. A proposal never starts before the cooldown ends.** `_eta != 0` implies `restartAllowedAt <= _eta`: a start
  after a cancel is by the owner or guardian, at `s >= cancel`, so `_eta = s + REBALANCE_DELAY >= restartAllowedAt`;
  after a cancel of an expiry, `restartAllowedAt = end + REBALANCE_DELAY` and the next `_eta` is at least
  `end + 1 + REBALANCE_DELAY`. Hence inside `_permissionlessAt` the `max` only matters while nothing is pending, where
  the expiry term is zero: with a proposal, `permissionlessAt` is `end + REBALANCE_DELAY`, always.
- **I3. The cooldown and the interval never hold at once.** `restartAllowedAt > now` implies `earliest <= now` (by
  I1 at the cancel, and `earliest` does not move until a fill), and a fill happens at or after `_eta`, so after it
  `restartAllowedAt <= lastRebalance` (by I2). An idle index is held by the interval, or by the cooldown, or by
  nothing.
- **I4. The counters count one thing each.** `proposalCount` rises only at a start, by one; `rebalanceNonce` only at
  a fill, by one; a cancel and an expiry move neither.
- **I5. Holders never read the rebalance.** `issue`, `redeem`, `redeemSkipping`, `claim` and `accrueFees` succeed in
  every initialized state and leave the eight words as they were. Nothing in the rebalance can freeze an exit.
- **I6. The order of a start's checks** is the interval, then the proposal, then the mask, then the caller, then the
  price read; **of a cancel's**, the proposal, then the caller; **of a fill's**, the streaming accrual, then the
  clock (`NoPendingRebalance`, `RebalanceNotReady`, `RebalanceExpired`), then the price read, the settlement
  (`NothingToRebalance`), the caller's bounds, and the backing after the callback. The order decides which error a
  caller sees, and the cells where two checks would fire pin it.

## 6. What was already pinned, and what the suite adds

About a third of the cells had a test before this record, each under the id of the finding that put it there:

- the Uninitialized row: `test_DA22_CRI25_CRI33_anUninitializedCloneDoesNothing` (`test/WeightedHub.t.sol`);
- the interval's end and a stranger's start: `test_startWaitsForTheInterval`; a start at the auction's last second:
  `test_startRefusesWhileAnAuctionIsLive`; the mask's two refusals: `test_startChecksTheKeepMask` and
  `test_V5L2_aKeepMaskMustLeaveTwoMoving`; a stranger's mask: `test_R16_onlyTheOwnerOrGuardianPassesAKeepMask`;
- the cancel cells and the cooldown: `test_R15_VR04_cancelHoldsStrangersOff`; the expiry's hold and the cancel of
  an expiry: `test_XA02_XA16_VR04_anExpiredAuctionHoldsStrangersOffUntilItsDelayPasses`; the owner's restart over
  it: `test_theOwnerRestartsAtOnceAfterAnExpiry`;
- the fill's clock: `test_executeChecksTheAuctionIsOpen` and `test_muFallsFromMaxToMinRoundedUp`; a fill that
  trades nothing: `test_V5L2_aFillThatTradesNothingCannotRestartTheInterval`; the bound: `test_DA13_theBoundedFill`;
  the interval after a masked fill: the two `test_XS3_` tests (all in `test/WeightedHub.rebalance.t.sol`);
- the invariant handler models the start rule for strangers and the guardian (`holdOffMisjudged`,
  `restartMisjudged` in `test/WeightedHub.invariant.t.sol`) under random interleavings.

`test/WeightedHub.states.t.sol` adds the whole matrix in one place, eleven tests:

- one test per row (`test_uninitialized_nothingMoves` to `test_expiredOpen_anyoneRestartsOverTheStaleProposal`),
  each driving a fresh index into its state, trying every column, reading the three views, letting a holder issue,
  redeem, redeem skipping a leg and accrue fees, and then taking each transition that leaves the state, with its
  event and what it writes;
- `test_theClockMovesTheStateAtExactSeconds`: section 4, each boundary a second either side;
- `test_theCooldownAndTheIntervalNeverHoldAtOnce`: I2 and I3 along both paths, a cancel in the notice and a cancel of
  an expiry, each followed by a restart and a fill;
- `test_aFillStartsTheIntervalItsMaskDecides`: the two intervals a fill can start, on a 30-day index.

The suite's `_stateOf` classifies an index from `pendingRebalance`, `earliestRebalance`, `restartAllowedAt` and the
clock exactly as section 2 does, and every assertion of a state also asserts `canStartRebalance`, so the view and
the table cannot drift apart unnoticed.

## 7. The mutants

Each mutant is one edit to `src/WeightedHub.sol`, applied to a byte copy and restored after the run of the suite
alone (`forge test --match-path test/WeightedHub.states.t.sol`). A mutant is killed when at least one test fails.

| Mutant | Edit in `src/WeightedHub.sol` | Result | Killed by |
|---|---|---|---|
| M1 | `_permissionlessAt` returns the expiry term alone, ignoring `restartAllowedAt` | killed | the cooldown, notice and auction rows, the clock, the holds |
| M2 | `_permissionlessAt` returns `restartAllowedAt` alone, ignoring the expiry | killed | the expired-and-held row, the clock, the holds |
| M3 | a start is refused only while `now < end`, so the auction's last second lets one in | killed | the clock |
| M4 | a fill is refused from `end` on, instead of after it | killed | the auction row, the clock |
| M5 | a fill is refused at `eta`, instead of before it | killed | the auction row, the clock, the holds, the mask's interval |
| M6 | a cancel always sets `restartAllowedAt = now + REBALANCE_DELAY`, an expiry's cancel included (VR-04 undone) | killed | both expired rows |
| M7 | a start checks the caller before the mask | killed | the cooldown, open and both expired rows |
| M8 | a cancel checks the caller before the proposal | killed | the interval, cooldown and open rows |
| M9 | a fill does not write `lastRebalance` | killed | the auction row, the holds, the mask's interval |
| M10 | a fill does not clear the proposal | killed | the auction row, the holds, the mask's interval |
| M11 | `canStartRebalance` drops its `RebalancePending` check | survived | equivalent: see section 8 |
| M12 | `canStartRebalance` drops its interval check | killed | the interval and auction rows, the clock, the holds, the mask's interval |
| M13 | a stranger may pass a keep mask once nothing holds | killed | the open and expired-and-open rows |
| M14 | a masked fill does not record `_maskedFill`, so the index's own interval follows it | killed | the mask's interval |
| M15 | `currentMu` reports 0 at the auction's last second | killed | the auction row, the clock |
| M16 | `canStartRebalance` drops its initialized check | killed | the uninitialized row |
| M17 | a start at `earliest` is too soon (`<=` for `<`) | killed | every row from the cooldown on, the clock, the holds, the mask's interval |

Sixteen of the seventeen are killed. The first run reported M4, M5, M6 and M17 as survivors because the runner's
pattern for a failing test stopped at the first `]` and those failures print a bracketed number
(`RebalanceTooSoon(1801123200 [1.801e9])`); run by hand, M17 failed nine of the eleven tests, and the four were run
again with the pattern fixed. The runner is not committed: it is a dozen lines of Python that apply one edit to a
byte copy, run the suite and restore the copy, and `AGENTS.md`'s rule to restore from a byte copy, never from git,
holds.

## 8. Findings

- **M11 is an equivalent mutant.** In `canStartRebalance`, the line that returns false while a proposal is in its
  notice or auction is implied by the line after it: with a proposal pending, `_permissionlessAt` is at least
  `end + REBALANCE_DELAY`, which is after the auction, so the last line already answers false. The check is kept for
  the reader; it costs nothing and it is what the interface's comment says. No change.
- **The `max` in `_permissionlessAt` is only load-bearing while nothing is pending** (I2). With a proposal, the
  expiry term always wins, since `restartAllowedAt <= _eta` holds for every proposal. M1 and M2 show both terms are
  still needed, in different states. No change.
- **No cell was unspecified and none behaved otherwise than the record says.** Every cell of section 3 and every
  boundary of section 4 passes as written, and the sixteen killed mutants show the suite reads each of them. The hub
  is unchanged; the four release hashes stand.
- **Two things a reader could expect and the hub does not do**, both by design and already documented: no event
  marks an expiry (`RebalanceStarted`'s comment), and a cancel has no window or rate limit (DA-12, in AGENTS.md's
  rule on admin power). Neither is a state-machine gap: the first is observable from `pendingRebalance` and the
  clock, the second is the guardian's trust assumption.
