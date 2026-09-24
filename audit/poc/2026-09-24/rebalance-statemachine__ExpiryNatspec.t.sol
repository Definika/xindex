// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RebalanceSM} from "./RebalanceSM.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {IXindexErrors} from "../../src/interfaces/IXindexErrors.sol";

/// @notice The interface NatSpec of three getters says a new rebalance "can be started" once an auction has expired
///         (`AUCTION_DURATION`: "Afterwards the pending rebalance has expired and a new one can be started";
///         `pendingRebalance`: "an auction nobody filled keeps its eta after eta + AUCTION_DURATION, and a new
///         rebalance can then be started"), and `restartAllowedAt` is documented as the only hold-off ("After
///         cancelRebalance, only the factory owner or guardian can start a rebalance before this time"). After an
///         expiry, `restartAllowedAt` stays in the past and does not describe the REBALANCE_DELAY - 1 second hold-off
///         the expiry imposes, so an integrator that reads these three getters as their NatSpec says shows a start
///         that reverts `Unauthorized` for everyone but the owner and the guardian. `canStartRebalance` and the README
///         are right; only these interface descriptions are not.
contract ExpiryNatspecTest is RebalanceSM {
    function setUp() public {
        _deploySystem(1);
    }

    function test_expiredAuctionViewsSayStartableButStrangersAreHeldOff() public {
        // A stranger starts the first rebalance and nobody fills it.
        vm.warp(mLast + MRI);
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();

        // One second after the auction's last fillable second.
        vm.warp(eta + index.AUCTION_DURATION() + 1);

        // What the three getters' NatSpec reads as "a new rebalance can be started now":
        (uint256 pendingEta,,) = index.pendingRebalance();
        assertLt(pendingEta + index.AUCTION_DURATION(), block.timestamp, "the auction has expired");
        assertLt(index.restartAllowedAt(), block.timestamp, "restartAllowedAt is not holding anyone off");

        // ...but a stranger's start is refused, and stays refused for REBALANCE_DELAY - 1 more seconds.
        assertFalse(index.canStartRebalance());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        index.startRebalance(0);

        vm.warp(eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY() - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        index.startRebalance(0);
        assertLt(index.restartAllowedAt(), block.timestamp, "still nothing in restartAllowedAt says so");

        // Only the next second lets strangers in.
        vm.warp(eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY());
        assertTrue(index.canStartRebalance());
        vm.prank(stranger);
        index.startRebalance(0);
    }
}
