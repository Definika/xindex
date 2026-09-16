// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IndexTokenRebalanceTest} from "../IndexToken.rebalance.t.sol";
import {IndexToken} from "../../src/IndexToken.sol";

contract RoundUpPoc is IndexTokenRebalanceTest {
    function test_poc_growingUnitsRoundUp_nonDivisible() public {
        uint256[] memory u = new uint256[](5);
        (u[0], u[1], u[2], u[3], u[4]) = (100e18 + 7, 100e18, 100e18, 100e18, 100e18);
        vm.prank(stranger);
        IndexToken idx = IndexToken(factory.createIndex("Odd", "ODD", tokens, u, 0));
        _issue(idx, alice, 1e18);
        uint256 eta = _start(idx);
        (,, uint256[] memory targets) = idx.pendingRebalance();
        vm.warp(eta + 1);
        (uint256 m, uint256[] memory units,,) = idx.previewRebalance();
        uint256 exact = (targets[0] - u[0]) * m;
        assertTrue(exact % WAD != 0, "input must round");
        assertEq(units[0], u[0] + exact / WAD + 1);
    }
}
