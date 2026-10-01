// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexHub} from "../../src/IndexHub.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice Settlement amounts are differences of floored backing. On a supply below one whole index token, a shrinking
///         leg's floor can drop by a whole raw unit for a sub-unit change while every growing leg's floor stays put, so
///         an executor that delivers nothing settles and is paid a raw unit of every shrinking leg: all of that
///         component's backing, at a λ inside a 0.5% band.
contract DustRoundingPoC is Test {
    uint256 constant WAD = 1e18;
    uint256 constant SUPPLY = 100e18;
    IndexFactory factory;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");
    address[] tokens;

    function setUp() public {
        factory = new IndexFactory(owner, guardian);
        for (uint256 i = 0; i < 5; ++i) {
            tokens.push(address(new MockERC20("C", "C", 18)));
            vm.prank(owner);
            factory.proposeListing(tokens[i], SUPPLY);
        }
        vm.warp(block.timestamp + 2 days);
        for (uint256 i = 0; i < 5; ++i) {
            factory.executeListing(tokens[i]);
        }
    }

    IndexHub idx;
    uint256 constant SHARES = 1e14;

    function test_noopExecutorIsPaidOnASubTokenSupply() public {
        // Every component at MIN_RAW_UNITS (10,000 raw units per whole token).
        uint256 k = factory.MIN_RAW_UNITS() * 1e36 / SUPPLY;
        idx = IndexHub(factory.createIndex("Dust", "DUST", tokens, k));

        // Alice holds 1e14 shares: exactly one raw unit of each component.
        uint256[] memory need = idx.previewIssue(SHARES);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(need[i], 1);
            MockERC20(tokens[i]).mint(alice, 1);
            vm.prank(alice);
            MockERC20(tokens[i]).approve(address(idx), 1);
        }
        vm.prank(alice);
        idx.issue(SHARES, alice);

        // An honest supply batch: the first component's supply up the full 0.5% step.
        address[] memory one = new address[](1);
        one[0] = tokens[0];
        uint256[] memory sup = new uint256[](1);
        sup[0] = SUPPLY + SUPPLY / 200;
        vm.prank(owner);
        factory.proposeSupplies(one, sup);
        vm.warp(block.timestamp + 2 days);
        factory.executeSupplies();

        vm.warp(idx.lastRebalance() + 7 days);
        vm.prank(stranger);
        idx.startRebalance(0);
        (uint256 eta,, uint256 lambdaMin, uint256 lambdaMax,) = idx.pendingRebalance();
        assertLe((lambdaMax - lambdaMin) * 1000, lambdaMax * 6, "a band of about 0.5%");
        emit log_named_uint("lambdaMin", lambdaMin);
        emit log_named_uint("lambdaMax", lambdaMax);

        _checkAndFill(eta, lambdaMax);
    }

    function _checkAndFill(uint256 eta, uint256 lambdaMax) internal {
        // Two hours into the auction λ has fallen only ~0.04%, yet the four shrinking legs each owe their whole backing.
        vm.warp(eta + 2 hours);
        (uint256 lambda, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn) =
            idx.previewRebalance();
        assertLt(lambda, lambdaMax, "not the lambdaMax fallback: something sells");
        for (uint256 i = 1; i < 5; ++i) {
            assertGe(units[i], 9_995, "each shrinking leg moves by at most 0.05% of its units");
            assertLt(units[i], 10_000);
            assertEq(amountsOut[i], 1, "yet its whole backing is paid out");
        }
        assertGt(units[0], 10_000, "the first component grows");
        assertEq(amountsIn[0], 0, "and its floor does not move, so nothing is asked back");

        // An executor that delivers nothing settles and keeps four raw units.
        MockRebalanceExecutor noop = new MockRebalanceExecutor();
        noop.setMode(MockRebalanceExecutor.Mode.Noop);
        noop.execute(idx, "");
        assertEq(idx.rebalanceNonce(), 1, "settled");
        for (uint256 i = 1; i < 5; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(address(noop)), 1, "paid a raw unit");
            assertEq(MockERC20(tokens[i]).balanceOf(address(idx)), 0, "the index holds none of it any more");
        }

        // Alice's redemption returns one of five raw units: 80% of the basket gone at a lambda 0.04% below the top.
        vm.prank(alice);
        idx.redeem(SHARES, alice);
        uint256 back = 0;
        for (uint256 i = 0; i < 5; ++i) {
            back += MockERC20(tokens[i]).balanceOf(alice);
        }
        assertEq(back, 1, "alice gets one raw unit back of the five she paid");
    }
}
