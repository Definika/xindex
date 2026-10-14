// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployChecks} from "../script/DeployChecks.sol";
import {DeployWeighted} from "../script/DeployWeighted.s.sol";

/// @notice Which chains the deployment checks pin to an address book. The rest of `DeployChecks` is tested in
///         `test/Scripts.t.sol`.
contract DeployChecksTest is Test {
    DeployChecks checks;

    function setUp() public {
        checks = new DeployWeighted();
    }

    /// @dev Ethereum alone is pinned: BNB Chain's address book was deleted with its deployment on 2026-10-13.
    function test_onlyEthereumIsPinned() public {
        vm.chainId(56);
        assertFalse(checks.isPinnedChain());
        vm.chainId(1);
        assertTrue(checks.isPinnedChain());
    }
}
