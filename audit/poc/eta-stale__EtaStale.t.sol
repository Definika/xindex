// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IndexTokenRebalanceTest} from "../IndexToken.rebalance.t.sol";
contract EtaStalePoc is IndexTokenRebalanceTest {
    function test_poc_etaStaysAfterExpiry() public {
        uint256 eta = _start(index);
        vm.warp(eta + index.AUCTION_DURATION() + 30 days);
        (uint256 e,, uint256[] memory t) = index.pendingRebalance();
        emit log_named_uint("eta after expiry", e);
        emit log_named_uint("targets len", t.length);
        emit log_named_uint("currentMultiplier", index.currentMultiplier());
        assertEq(e, eta);
        assertGe(block.timestamp, index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        assertGe(block.timestamp, index.restartAllowedAt());
        vm.prank(stranger);
        index.startRebalance(0); // contract allows restart even though README condition says "not due"
    }
}
