// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {WeightedTest} from "./WeightedTest.sol";
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";

/// @notice The rebalance state machine of `design/2026-10-29-rebalance-state-machine.md`: one test per state, taking
///         every action from it, then the clock's transitions and the invariants the matrix implies.
/// @dev The default index (ETH 50%, BTC 30%, USD 20%, $100 a token) with 100 tokens issued. A fill prices ETH at
///      $2,500, so it has a tenth of the ETH units to sell. Each row test drives a fresh index into its state, tries
///      every start (with and without a keep mask, by a stranger and by the guardian or owner), both cancels and both
///      fills, reads the views, lets a holder issue and redeem, and then takes each transition that leaves the state.
///      The order of a start's checks (the interval, then the proposal, then the mask, then the caller) and of a
///      fill's (the clock before its bounds) is pinned by the cells where two checks would fire.
contract WeightedHubStatesTest is WeightedTest {
    /// @dev The eight states, as the record defines them from `pendingRebalance`, `earliestRebalance`,
    ///      `restartAllowedAt` and the clock.
    enum State {
        Uninitialized,
        Interval,
        Cooldown,
        Open,
        Notice,
        Auction,
        ExpiredHeld,
        ExpiredOpen
    }

    WeightedHub index;
    MockWeightedExecutor executor;

    uint256 constant SHARES = 100e18;
    /// @dev Keeps the dollar leg: two components still move, so the mask is valid.
    uint256 constant KEEP_USD = 4;
    /// @dev Keeps ETH and BTC: one component left moving, refused (V5-L2).
    uint256 constant KEEP_TWO = 3;
    /// @dev Names a fourth component the index does not have, refused.
    uint256 constant KEEP_BEYOND = 8;

    uint256 delay;
    uint256 auction;
    /// @dev How many indexes `_fresh` made: each gets its own units, so its own CREATE2 salt.
    uint256 created;

    function setUp() public {
        _deploy();
        _listAll();
        executor = new MockWeightedExecutor();
        _fresh(_params());
        delay = index.REBALANCE_DELAY();
        auction = index.AUCTION_DURATION();
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev A new index with 100 tokens issued. The ETH units differ by a wei per index, so each salt is new.
    function _fresh(IWeightedIndexFactory.IndexParams memory params) internal {
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        specs[0].units += created++;
        index = _create(specs, params);
        _issue(index, alice, SHARES);
    }

    /// @dev Drives the fresh `index` into `s` by the shortest path: the interval, a start by a stranger, the clock,
    ///      and a guardian's cancel for the cooldown.
    function _enter(State s) internal {
        if (s == State.Uninitialized) {
            index = WeightedHub(Clones.clone(factory.IMPLEMENTATION()));
            return;
        }
        if (s == State.Interval) return;
        vm.warp(index.earliestRebalance());
        if (s == State.Open) return;
        if (s == State.Cooldown) {
            _start(guardian, 0);
            vm.prank(guardian);
            index.cancelRebalance();
            return;
        }
        _start(stranger, 0);
        (uint256 eta,) = index.pendingRebalance();
        if (s == State.Notice) return;
        if (s == State.Auction) {
            vm.warp(eta);
            return;
        }
        vm.warp(eta + auction + 1);
        if (s == State.ExpiredHeld) return;
        vm.warp(eta + auction + delay);
    }

    /// @dev Classifies `index` by its views and the clock, as the record's table does.
    function _stateOf() internal view returns (State) {
        if (index.componentTokens().length == 0) return State.Uninitialized;
        (uint256 eta,) = index.pendingRebalance();
        if (eta == 0) {
            if (block.timestamp < index.earliestRebalance()) return State.Interval;
            if (block.timestamp < index.restartAllowedAt()) return State.Cooldown;
            return State.Open;
        }
        if (block.timestamp < eta) return State.Notice;
        if (block.timestamp <= eta + auction) return State.Auction;
        if (block.timestamp < Math.max(index.restartAllowedAt(), eta + auction + delay)) return State.ExpiredHeld;
        return State.ExpiredOpen;
    }

    /// @dev The index is in `s`, and `canStartRebalance` says so: true in the two open states alone.
    function _assertState(State s) internal view {
        assertEq(uint256(_stateOf()), uint256(s), "state");
        assertEq(index.canStartRebalance(), s == State.Open || s == State.ExpiredOpen, "canStartRebalance");
    }

    function _assertViews(uint256 mu, uint256 eta, uint256 keepMask) internal view {
        assertEq(index.currentMu(), mu, "currentMu");
        (uint256 pendingEta, uint256 pendingMask) = index.pendingRebalance();
        assertEq(pendingEta, eta, "eta");
        assertEq(pendingMask, keepMask, "keepMask");
    }

    function _start(address who, uint256 keepMask) internal {
        bytes[] memory live = pyth.liveUpdates(index, keepMask);
        vm.prank(who);
        index.startRebalance(keepMask, live);
    }

    function _startEmits(address who, uint256 keepMask, uint256 proposalId, uint256 id) internal {
        bytes[] memory live = pyth.liveUpdates(index, keepMask);
        vm.expectEmit(address(index));
        emit IWeightedHub.RebalanceStarted(proposalId, id, who, keepMask, block.timestamp + delay);
        vm.prank(who);
        index.startRebalance(keepMask, live);
    }

    function _startReverts(address who, uint256 keepMask, bytes memory err) internal {
        bytes[] memory live = pyth.liveUpdates(index, keepMask);
        vm.expectRevert(err);
        vm.prank(who);
        index.startRebalance(keepMask, live);
    }

    function _cancelEmits(address who, uint256 proposalId, uint256 restartAt) internal {
        vm.expectEmit(address(index));
        emit IWeightedHub.RebalanceCancelled(proposalId, who, restartAt);
        vm.prank(who);
        index.cancelRebalance();
    }

    function _cancelReverts(address who, bytes memory err) internal {
        vm.expectRevert(err);
        vm.prank(who);
        index.cancelRebalance();
    }

    /// @dev Prices ETH at $2,500, so a fill has a tenth of the ETH units to sell. A kept leg's update is ignored.
    function _fillData() internal view returns (bytes[] memory) {
        return _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
    }

    function _fill() internal {
        executor.execute(index, "", _fillData());
    }

    /// @dev Both overloads revert `err`. The bounded one is given bounds of the wrong length, which it would refuse
    ///      (LengthMismatch) if it read them before the clock.
    function _fillReverts(bytes memory err) internal {
        bytes[] memory data = _fillData();
        vm.expectRevert(err);
        executor.execute(index, "", data);
        vm.expectRevert(err);
        executor.executeBounded(index, "", data, new uint256[](1));
    }

    /// @dev A holder issues, redeems, redeems skipping a leg and accrues the fees: none of them reads the rebalance.
    function _holdersMove() internal {
        _issue(index, alice, 1e18);
        vm.prank(alice);
        index.redeem(0.5e18, alice);
        vm.prank(alice);
        index.redeemSkipping(0.5e18, alice, 1);
        index.accrueFees();
    }

    function _unauthorized(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, who);
    }

    function _invalidMask(uint256 keepMask) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IWeightedHub.InvalidKeepMask.selector, keepMask);
    }

    function _noPending() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IWeightedHub.NoPendingRebalance.selector);
    }

    // ---------------------------------------------------------------------
    // The rows: every action from every state
    // ---------------------------------------------------------------------

    /// @dev Row 1. The implementation, or a clone the factory did not initialize: nothing moves (DA-22).
    function test_uninitialized_nothingMoves() public {
        _enter(State.Uninitialized);
        _assertState(State.Uninitialized);
        bytes memory err = abi.encodeWithSelector(IWeightedHub.NotInitialized.selector);
        _startReverts(stranger, 0, err);
        _startReverts(guardian, 0, err);
        _startReverts(stranger, KEEP_USD, err);
        _startReverts(guardian, KEEP_USD, err);
        _cancelReverts(stranger, err);
        _cancelReverts(guardian, err);
        _fillReverts(err);
        vm.expectRevert(err);
        index.issue(1, alice);
        vm.expectRevert(err);
        index.redeem(1, alice);
        vm.expectRevert(err);
        index.redeemSkipping(1, alice, 1);
        vm.expectRevert(err);
        index.accrueFees();
        _assertViews(0, 0, 0);
    }

    /// @dev Row 2. Inside the interval nobody starts, the owner and guardian included, and the interval is checked
    ///      before the mask and the caller. Nothing is pending, so a cancel or a fill finds nothing, whoever calls.
    function test_interval_theIntervalHoldsEveryone() public {
        uint256 earliest = index.earliestRebalance();
        vm.warp(earliest - 1);
        _assertState(State.Interval);
        bytes memory tooSoon = abi.encodeWithSelector(IWeightedHub.RebalanceTooSoon.selector, earliest);
        _startReverts(stranger, 0, tooSoon);
        _startReverts(owner, 0, tooSoon);
        _startReverts(guardian, 0, tooSoon);
        _startReverts(stranger, KEEP_USD, tooSoon);
        _startReverts(guardian, KEEP_USD, tooSoon);
        _startReverts(guardian, KEEP_BEYOND, tooSoon);
        _cancelReverts(stranger, _noPending());
        _cancelReverts(guardian, _noPending());
        _fillReverts(_noPending());
        _assertViews(0, 0, 0);
        _holdersMove();
        _assertState(State.Interval);
        assertEq(index.proposalCount(), 0);
        assertEq(index.rebalanceNonce(), 0);
    }

    /// @dev Row 3. After a cancel, the cooldown holds strangers off and nobody else (R15), and the mask is checked
    ///      before the caller. The owner or guardian starts, with a mask or without; the cancelled proposal counted.
    function test_cooldown_onlyTheOwnerOrGuardianStarts() public {
        _enter(State.Cooldown);
        _assertState(State.Cooldown);
        assertEq(index.restartAllowedAt(), block.timestamp + delay);
        _startReverts(stranger, 0, _unauthorized(stranger));
        _startReverts(stranger, KEEP_USD, _unauthorized(stranger));
        _startReverts(stranger, KEEP_BEYOND, _invalidMask(KEEP_BEYOND));
        _startReverts(guardian, KEEP_TWO, _invalidMask(KEEP_TWO));
        _cancelReverts(stranger, _noPending());
        _cancelReverts(guardian, _noPending());
        _fillReverts(_noPending());
        _assertViews(0, 0, 0);
        _holdersMove();
        _assertState(State.Cooldown);

        uint256 snap = vm.snapshotState();
        _startEmits(owner, 0, 2, 1);
        _assertState(State.Notice);
        _assertViews(0, block.timestamp + delay, 0);
        vm.revertToState(snap);

        _startEmits(guardian, KEEP_USD, 2, 1);
        _assertState(State.Notice);
        _assertViews(0, block.timestamp + delay, KEEP_USD);
        assertEq(index.proposalCount(), 2, "the cancelled proposal counted");
        assertEq(index.rebalanceNonce(), 0);
    }

    /// @dev Row 4. Nothing holds: anyone starts without a mask, the owner or guardian with one.
    function test_open_anyoneStartsWithoutAMask() public {
        _enter(State.Open);
        _assertState(State.Open);
        _assertViews(0, 0, 0);
        _startReverts(stranger, KEEP_USD, _unauthorized(stranger));
        _startReverts(stranger, KEEP_BEYOND, _invalidMask(KEEP_BEYOND));
        _startReverts(guardian, KEEP_TWO, _invalidMask(KEEP_TWO));
        _cancelReverts(stranger, _noPending());
        _cancelReverts(guardian, _noPending());
        _fillReverts(_noPending());
        _holdersMove();
        _assertState(State.Open);

        uint256 snap = vm.snapshotState();
        _startEmits(stranger, 0, 1, 1);
        _assertState(State.Notice);
        _assertViews(0, block.timestamp + delay, 0);
        vm.revertToState(snap);

        snap = vm.snapshotState();
        _startEmits(owner, 0, 1, 1);
        _assertState(State.Notice);
        vm.revertToState(snap);

        _startEmits(guardian, KEEP_USD, 1, 1);
        _assertState(State.Notice);
        _assertViews(0, block.timestamp + delay, KEEP_USD);
        assertEq(index.proposalCount(), 1);
    }

    /// @dev Row 5. During the notice only a cancel changes the state: every start sees the proposal, before the mask
    ///      and the caller; a fill is not ready, before its bounds; a stranger cannot cancel.
    function test_notice_onlyACancelChangesTheState() public {
        _enter(State.Notice);
        _assertState(State.Notice);
        (uint256 eta,) = index.pendingRebalance();
        assertEq(eta, block.timestamp + delay);
        bytes memory pending = abi.encodeWithSelector(IWeightedHub.RebalancePending.selector, eta + auction);
        _startReverts(stranger, 0, pending);
        _startReverts(guardian, 0, pending);
        _startReverts(stranger, KEEP_USD, pending);
        _startReverts(guardian, KEEP_USD, pending);
        _startReverts(guardian, KEEP_BEYOND, pending);
        _cancelReverts(stranger, _unauthorized(stranger));
        _fillReverts(abi.encodeWithSelector(IWeightedHub.RebalanceNotReady.selector, eta));
        _assertViews(0, eta, 0);
        _holdersMove();
        _assertState(State.Notice);

        _cancelEmits(guardian, 1, block.timestamp + delay);
        _assertState(State.Cooldown);
        _assertViews(0, 0, 0);
        assertEq(index.restartAllowedAt(), block.timestamp + delay);
        assertEq(index.proposalCount(), 1);
        assertEq(index.rebalanceNonce(), 0);
    }

    /// @dev Row 6. The auction ends by a fill or a cancel. A fill that trades nothing (V5-L2), or asks more than its
    ///      bound (DA-13), leaves the state as it was. The last second still fills, at MU_MIN, into the interval.
    function test_auction_aFillOrACancelEndsIt() public {
        _enter(State.Auction);
        _assertState(State.Auction);
        (uint256 eta,) = index.pendingRebalance();
        assertEq(block.timestamp, eta);
        bytes memory pending = abi.encodeWithSelector(IWeightedHub.RebalancePending.selector, eta + auction);
        _startReverts(stranger, 0, pending);
        _startReverts(guardian, 0, pending);
        _startReverts(stranger, KEEP_USD, pending);
        _startReverts(guardian, KEEP_USD, pending);
        _startReverts(guardian, KEEP_BEYOND, pending);
        _cancelReverts(stranger, _unauthorized(stranger));
        _assertViews(index.MU_MAX(), eta, 0);
        _holdersMove();
        _assertState(State.Auction);

        bytes[] memory flat = _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE));
        vm.expectRevert(IWeightedHub.NothingToRebalance.selector);
        executor.execute(index, "", flat);
        _assertState(State.Auction);

        bytes[] memory data = _fillData();
        vm.expectPartialRevert(IWeightedHub.RebalanceMovedOn.selector);
        executor.executeBounded(index, "", data, new uint256[](3));
        _assertState(State.Auction);

        uint256 snap = vm.snapshotState();
        _cancelEmits(guardian, 1, block.timestamp + delay);
        _assertState(State.Cooldown);
        assertEq(index.restartAllowedAt(), block.timestamp + delay);
        vm.revertToState(snap);

        vm.warp(eta + auction);
        _assertState(State.Auction);
        assertEq(index.currentMu(), index.MU_MIN());
        _fill();
        _assertState(State.Interval);
        _assertViews(0, 0, 0);
        assertEq(index.rebalanceNonce(), 1);
        assertEq(index.lastRebalance(), block.timestamp);
        assertEq(index.earliestRebalance(), block.timestamp + 7 days);
        assertEq(index.proposalCount(), 1);
    }

    /// @dev Row 7. After an auction nobody filled, the owner and guardian get the first move (XA-02, XA-16, CR-I02):
    ///      a restart replaces the stale proposal and sets no cooldown; a cancel only clears it, and the hold-off the
    ///      expiry set stands (VR-04). The stale proposal is still what `pendingRebalance` reports.
    function test_expiredHeld_onlyTheOwnerOrGuardianRestarts() public {
        _enter(State.ExpiredHeld);
        _assertState(State.ExpiredHeld);
        (uint256 eta,) = index.pendingRebalance();
        uint256 end = eta + auction;
        assertEq(block.timestamp, end + 1);
        _startReverts(stranger, 0, _unauthorized(stranger));
        _startReverts(stranger, KEEP_USD, _unauthorized(stranger));
        _startReverts(stranger, KEEP_BEYOND, _invalidMask(KEEP_BEYOND));
        _startReverts(guardian, KEEP_TWO, _invalidMask(KEEP_TWO));
        _cancelReverts(stranger, _unauthorized(stranger));
        _fillReverts(abi.encodeWithSelector(IWeightedHub.RebalanceExpired.selector, end));
        _assertViews(0, eta, 0);
        _holdersMove();
        _assertState(State.ExpiredHeld);

        uint256 snap = vm.snapshotState();
        _cancelEmits(guardian, 1, end + delay);
        _assertState(State.Cooldown);
        assertEq(index.restartAllowedAt(), end + delay, "the expiry's hold-off stands, not a new one (VR-04)");
        _assertViews(0, 0, 0);
        vm.revertToState(snap);

        snap = vm.snapshotState();
        _startEmits(owner, 0, 2, 1);
        _assertState(State.Notice);
        vm.revertToState(snap);

        _startEmits(guardian, KEEP_USD, 2, 1);
        _assertState(State.Notice);
        _assertViews(0, block.timestamp + delay, KEEP_USD);
        assertEq(index.restartAllowedAt(), 0, "a restart over an expiry sets no cooldown");
        assertEq(index.rebalanceNonce(), 0);
    }

    /// @dev Row 8. REBALANCE_DELAY after the expiry anyone restarts over the stale proposal; a cancel now leaves the
    ///      index open, since the hold-off it keeps has passed.
    function test_expiredOpen_anyoneRestartsOverTheStaleProposal() public {
        _enter(State.ExpiredOpen);
        _assertState(State.ExpiredOpen);
        (uint256 eta,) = index.pendingRebalance();
        uint256 end = eta + auction;
        assertEq(block.timestamp, end + delay);
        _assertViews(0, eta, 0);
        _startReverts(stranger, KEEP_USD, _unauthorized(stranger));
        _startReverts(stranger, KEEP_BEYOND, _invalidMask(KEEP_BEYOND));
        _startReverts(guardian, KEEP_TWO, _invalidMask(KEEP_TWO));
        _cancelReverts(stranger, _unauthorized(stranger));
        _fillReverts(abi.encodeWithSelector(IWeightedHub.RebalanceExpired.selector, end));
        _holdersMove();
        _assertState(State.ExpiredOpen);

        uint256 snap = vm.snapshotState();
        _cancelEmits(guardian, 1, end + delay);
        _assertState(State.Open);
        _assertViews(0, 0, 0);
        vm.revertToState(snap);

        snap = vm.snapshotState();
        _startEmits(guardian, KEEP_USD, 2, 1);
        _assertState(State.Notice);
        vm.revertToState(snap);

        _startEmits(stranger, 0, 2, 1);
        _assertState(State.Notice);
        _assertViews(0, block.timestamp + delay, 0);
        assertEq(index.proposalCount(), 2);
    }

    // ---------------------------------------------------------------------
    // The clock
    // ---------------------------------------------------------------------

    /// @dev Every transition the clock makes, at its exact second: the interval's end, the auction's first and last
    ///      seconds, the end of the hold-off after an expiry and of the cooldown after a cancel.
    function test_theClockMovesTheStateAtExactSeconds() public {
        uint256 earliest = index.earliestRebalance();
        vm.warp(earliest - 1);
        _assertState(State.Interval);
        vm.warp(earliest);
        _assertState(State.Open);

        _start(stranger, 0);
        (uint256 eta,) = index.pendingRebalance();
        uint256 end = eta + auction;
        vm.warp(eta - 1);
        _assertState(State.Notice);
        _fillReverts(abi.encodeWithSelector(IWeightedHub.RebalanceNotReady.selector, eta));
        vm.warp(eta);
        _assertState(State.Auction);
        assertEq(index.currentMu(), index.MU_MAX());
        vm.warp(end);
        _assertState(State.Auction);
        assertEq(index.currentMu(), index.MU_MIN());
        _startReverts(guardian, 0, abi.encodeWithSelector(IWeightedHub.RebalancePending.selector, end));
        vm.warp(end + 1);
        _assertState(State.ExpiredHeld);
        assertEq(index.currentMu(), 0);
        _fillReverts(abi.encodeWithSelector(IWeightedHub.RebalanceExpired.selector, end));
        vm.warp(end + delay - 1);
        _assertState(State.ExpiredHeld);
        _startReverts(stranger, 0, _unauthorized(stranger));
        vm.warp(end + delay);
        _assertState(State.ExpiredOpen);

        _start(stranger, 0);
        vm.prank(guardian);
        index.cancelRebalance();
        uint256 restartAt = index.restartAllowedAt();
        assertEq(restartAt, block.timestamp + delay);
        vm.warp(restartAt - 1);
        _assertState(State.Cooldown);
        _startReverts(stranger, 0, _unauthorized(stranger));
        vm.warp(restartAt);
        _assertState(State.Open);
        _start(stranger, 0);
        _assertState(State.Notice);
    }

    // ---------------------------------------------------------------------
    // The invariants
    // ---------------------------------------------------------------------

    /// @dev A proposal's eta is never before `restartAllowedAt`, and a fill leaves `restartAllowedAt` at or before
    ///      `lastRebalance`: the cooldown and the interval never hold at once, after a cancel during the notice and
    ///      after a cancel of an expired proposal alike.
    function test_theCooldownAndTheIntervalNeverHoldAtOnce() public {
        _enter(State.Cooldown);
        _start(guardian, 0);
        (uint256 eta,) = index.pendingRebalance();
        assertGe(eta, index.restartAllowedAt());
        vm.warp(eta);
        _fill();
        assertLe(index.restartAllowedAt(), index.lastRebalance());
        _assertState(State.Interval);

        vm.warp(index.earliestRebalance());
        _assertState(State.Open);
        _start(stranger, 0);
        (eta,) = index.pendingRebalance();
        vm.warp(eta + auction + 1);
        vm.prank(guardian);
        index.cancelRebalance();
        _assertState(State.Cooldown);
        _start(owner, 0);
        (eta,) = index.pendingRebalance();
        assertGe(eta, index.restartAllowedAt());
        vm.warp(eta);
        executor.execute(index, "", _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE)));
        assertLe(index.restartAllowedAt(), index.lastRebalance());
        _assertState(State.Interval);
    }

    /// @dev The interval a fill starts is the index's own, or MIN_REBALANCE_INTERVAL after a fill with a keep mask
    ///      (XS-3), whoever starts next and with whatever mask.
    function test_aFillStartsTheIntervalItsMaskDecides() public {
        IWeightedIndexFactory.IndexParams memory params = _params();
        params.rebalanceInterval = 30 days;
        _fresh(params);
        _enter(State.Open);
        assertEq(block.timestamp, index.lastRebalance() + 30 days);

        _start(guardian, KEEP_USD);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta);
        _fill();
        _assertState(State.Interval);
        assertEq(index.earliestRebalance(), block.timestamp + 7 days, "a masked fill: the floor");

        vm.warp(index.earliestRebalance());
        _start(stranger, 0);
        (eta,) = index.pendingRebalance();
        vm.warp(eta);
        executor.execute(index, "", _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE)));
        _assertState(State.Interval);
        assertEq(index.earliestRebalance(), block.timestamp + 30 days, "an unmasked fill: the index's own");
    }
}
