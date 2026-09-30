// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexHub} from "../../src/IndexHub.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice (a) Nothing makes supply batches weekly: one can execute every LISTING_DELAY, so a supply can move three
///         full steps in six days. (b) Once one component's gap exceeds the band, the centred clamp saturates every
///         other moving component at the opposite bound, so their own revisions are invisible to the fill and wait.
contract BatchCadencePoC is Test {
    uint256 constant WAD = 1e18;
    uint256 constant SUPPLY = 100e18;
    IndexFactory factory;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address[] tokens;
    IndexHub idx;

    function setUp() public {
        factory = new IndexFactory(owner, guardian);
        for (uint256 i = 0; i < 4; ++i) {
            tokens.push(address(new MockERC20("C", "C", 18)));
            vm.prank(owner);
            factory.proposeListing(tokens[i], SUPPLY);
        }
        vm.warp(block.timestamp + 2 days);
        for (uint256 i = 0; i < 4; ++i) {
            factory.executeListing(tokens[i]);
        }
        idx = IndexHub(factory.createIndex("I", "I", tokens, 1e36));
        uint256[] memory need = idx.previewIssue(10e18);
        for (uint256 i = 0; i < 4; ++i) {
            MockERC20(tokens[i]).mint(alice, need[i]);
            vm.prank(alice);
            MockERC20(tokens[i]).approve(address(idx), need[i]);
        }
        vm.prank(alice);
        idx.issue(10e18, alice);
    }

    function _revise(address token, uint256 supply) internal {
        address[] memory t = new address[](1);
        t[0] = token;
        uint256[] memory s = new uint256[](1);
        s[0] = supply;
        vm.prank(owner);
        factory.proposeSupplies(t, s);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeSupplies();
    }

    function test_fourStepsInEightDaysAndTheHiddenRevision() public {
        uint256 t0 = block.timestamp;
        // (a) Four back-to-back batches on the first component: +2% in eight days, not one step a week.
        uint256 s = SUPPLY;
        for (uint256 i = 0; i < 4; ++i) {
            s += s * factory.MAX_SUPPLY_STEP() / WAD;
            _revise(tokens[0], s);
        }
        assertEq(block.timestamp - t0, 8 days);
        assertGt(factory.referenceSupply(tokens[0]) * 1000, SUPPLY * 1020, "four full steps in force");

        // A genuine revision of the second component, down one step.
        _revise(tokens[1], SUPPLY - SUPPLY * factory.MAX_SUPPLY_STEP() / WAD);

        // (b) The band: the first component alone sits at the bottom and the three others, the revised second one
        // included, are all clamped to the same top ratio.
        if (block.timestamp < idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL()) {
            vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        }
        (uint256[] memory r, uint256 lambdaMin, uint256 lambdaMax) = idx.previewBand(0);
        assertEq(r[0], lambdaMin);
        assertEq(r[1], lambdaMax);
        assertEq(r[2], lambdaMax);
        assertEq(r[3], lambdaMax, "the second component's own revision is invisible");

        idx.startRebalance(0);
        (uint256 eta,,,,) = idx.pendingRebalance();
        vm.warp(eta + 12 hours);
        (, uint256[] memory before) = idx.components();
        new MockRebalanceExecutor().execute(idx, "");
        (, uint256[] memory afterwards) = idx.components();
        // The second component's units moved exactly like the third's: its 0.5% revision was not applied.
        assertEq(afterwards[1], afterwards[2], "the revised component moved like an unrevised one");
        assertEq(before[1], before[2]);
    }
}
