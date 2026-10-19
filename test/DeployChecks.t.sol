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

    /// @dev A chain-id override cannot switch the mainnet checks off against Ethereum's state: they key on Ethereum's
    ///      router having code too, which an override does not change (RX-23).
    function test_RX23_aChainIdOverrideCannotUnpinEthereum() public {
        vm.chainId(56);
        assertFalse(checks.isPinnedChain());
        vm.etch(checks.MAINNET_UNIVERSAL_ROUTER(), hex"00");
        assertTrue(checks.isPinnedChain(), "Ethereum's router is there, whatever the chain id says");
    }

    /// @dev Ethereum alone is pinned: BNB Chain's address book was deleted with its deployment on 2026-10-13.
    function test_onlyEthereumIsPinned() public {
        vm.chainId(56);
        assertFalse(checks.isPinnedChain());
        vm.chainId(1);
        assertTrue(checks.isPinnedChain());
    }
}
