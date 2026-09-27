// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GapBase} from "./GapBase.sol";
import {IXindexErrors} from "../../src/interfaces/IXindexErrors.sol";

/// @notice README "Frontend integration notes" > "Rebalance status" says the stranger hold-off after an unfilled auction
///         is "`REBALANCE_DELAY` less one second from an auction's last fillable second, `eta + AUCTION_DURATION`".
///         The code (IndexToken._permissionlessAt, canStartRebalance) lets strangers in at exactly
///         `eta + AUCTION_DURATION + REBALANCE_DELAY`: a full REBALANCE_DELAY after the last fillable second, and
///         REBALANCE_DELAY less one second after the first *expired* second. ARCHITECTURE.md ("After an expiry that
///         cooldown runs from the auction's last fillable second") and the runbook ("anyone after REBALANCE_DELAY
///         more") agree with the code; only the frontend note is off by one.
contract ReadmeRestartTimingTest is GapBase {
    function test_readmeRestartFormulaIsOneSecondEarly() public {
        // A stranger starts at the interval; nobody fills; the auction expires.
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        _refreshFeeds();
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        uint256 lastFillable = eta + index.AUCTION_DURATION();

        // The instant the README tells an app to show "rebalance due": RD less one second from the last fillable second.
        uint256 readmeDue = lastFillable + index.REBALANCE_DELAY() - 1;
        vm.warp(readmeDue);
        _refreshFeeds();
        assertFalse(index.canStartRebalance(), "README's due time: the view still says no");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        index.startRebalance(0);

        // One second later, i.e. a full REBALANCE_DELAY after the last fillable second, a stranger can start.
        vm.warp(readmeDue + 1);
        _refreshFeeds();
        assertTrue(index.canStartRebalance(), "code's due time: RD after eta + AUCTION_DURATION");
        vm.prank(stranger);
        index.startRebalance(0);
    }

    /// @dev The same note's other formula, "REBALANCE_DELAY from a cancel", holds only for a live auction. Cancelling
    ///      an auction that already expired keeps the expiry's hold-off (VR-04, README step 4), so an app counting
    ///      REBALANCE_DELAY from that cancel shows strangers locked out for up to REBALANCE_DELAY longer than they are.
    function test_readmeCancelFormulaIsWrongAfterAnExpiry() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        _refreshFeeds();
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        uint256 strangersFrom = eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY();

        // The guardian clears the stale proposal a day and a half before strangers may restart.
        uint256 cancelAt = strangersFrom - 36 hours;
        vm.warp(cancelAt);
        vm.prank(guardian);
        index.cancelRebalance();
        assertEq(index.restartAllowedAt(), strangersFrom, "the expiry's hold-off stands");

        // README: strangers wait REBALANCE_DELAY from the cancel, i.e. until cancelAt + 2 days. They do not.
        vm.warp(strangersFrom);
        _refreshFeeds();
        assertTrue(index.canStartRebalance(), "due 36 hours before the README's cancel formula says");
        assertLt(block.timestamp, cancelAt + index.REBALANCE_DELAY());
        vm.prank(stranger);
        index.startRebalance(0);
    }

    /// @dev IIndexToken.canStartRebalance: "...the factory owner and guardian can start when it is false." They can
    ///      only in the hold-off case; before MIN_REBALANCE_INTERVAL and during a live auction the view is false and
    ///      the privileged start reverts too, so an app that shows the owner or guardian a start button whenever the
    ///      view is false offers a call that reverts.
    function test_canStartRebalanceNatSpecOverclaimsThePrivilegedStart() public {
        assertFalse(index.canStartRebalance(), "before the interval");
        uint256 earliest = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSignature("RebalanceTooSoon(uint256)", earliest));
        index.startRebalance(0);

        vm.warp(earliest);
        _refreshFeeds();
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        vm.warp(eta + 1 hours);
        _refreshFeeds();
        assertFalse(index.canStartRebalance(), "live auction");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("RebalancePending(uint256)", eta + index.AUCTION_DURATION()));
        index.startRebalance(0);
    }
}
