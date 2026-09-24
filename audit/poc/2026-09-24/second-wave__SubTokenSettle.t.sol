// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {TestAggregator} from "../../script/testnet/TestAggregator.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice AGENTS.md ("Fixed constituents, rule-rebalanced units") states: "An index with less than one whole token
///         outstanding cannot settle at all, because every growing leg rounds to zero while a shrinking one does not."
///         With realistic units that is false: half a token of a WETH/UNI/LINK index settles normally.
contract SubTokenSettleTest is Test {
    function test_halfTokenIndexSettles() public {
        address owner = makeAddr("owner");
        IndexFactory factory = new IndexFactory(owner, makeAddr("guardian"));
        address[] memory t = new address[](3);
        int256[3] memory px = [int256(4_000e8), 10e8, 20e8];
        uint256[3] memory sup = [uint256(122_070_499e18), 620_716_422e18, 748_099_970e18];
        for (uint256 i = 0; i < 3; ++i) {
            t[i] = address(new MockERC20("C", "C", 18));
            TestAggregator f = new TestAggregator("X / USD", 8, px[i]);
            vm.prank(owner);
            factory.proposeListing(
                t[i], IIndexFactory.TokenConfig({feed: address(f), maxStaleness: 5400, referenceSupply: sup[i]})
            );
        }
        vm.warp(block.timestamp + 2 days);
        for (uint256 i = 0; i < 3; ++i) {
            factory.executeListing(t[i]);
        }
        // Equal-weighted $30 index, off its (uncapped, ETH-dominated) rule, so a rebalance has turnover.
        uint256[] memory units = new uint256[](3);
        (units[0], units[1], units[2]) = (0.0025e18, 1e18, 0.5e18);
        IndexToken index = IndexToken(factory.createIndex("Half", "HALF", t, units, 0));

        // Only half an index token outstanding.
        uint256 shares = 0.5e18;
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 i = 0; i < 3; ++i) {
            MockERC20(t[i]).mint(address(this), need[i]);
            MockERC20(t[i]).approve(address(index), need[i]);
        }
        index.issue(shares, address(this));
        assertLt(index.totalSupply(), 1e18);

        vm.warp(block.timestamp + 28 days);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        vm.warp(eta + 12 hours);

        (,,, uint256[] memory amountsIn) = index.previewRebalance();
        uint256 growingNonZero = 0;
        for (uint256 i = 0; i < 3; ++i) {
            if (amountsIn[i] != 0) ++growingNonZero;
        }
        assertGt(growingNonZero, 0, "a growing leg does not round to zero");

        MockRebalanceExecutor ex = new MockRebalanceExecutor();
        ex.execute(IIndexToken(address(index)), "");
        assertEq(index.rebalanceNonce(), 1, "a sub-one-token index settled");
    }
}
