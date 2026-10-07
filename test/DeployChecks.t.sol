// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployChecks} from "../script/DeployChecks.sol";
import {DeployWeighted} from "../script/DeployWeighted.s.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {BnbChainAddresses} from "../script/BnbChainAddresses.sol";

/// @notice How the deployment checks resolve PancakeSwap's router for the zap and keep the roles off it (the swap
///         venues of 2026-10-06). The rest of `DeployChecks` is tested in `test/Scripts.t.sol`.
contract DeployChecksTest is Test {
    DeployChecks checks;
    address pancake = MainnetAddresses.PANCAKE_UNIVERSAL_ROUTER;

    function setUp() public {
        checks = new DeployWeighted();
    }

    function test_offMainnetNoPancakeRouterIsAccepted() public {
        vm.chainId(11_155_111);
        assertEq(checks.resolvePancakeRouter(address(0)), address(0), "a testnet zap without PancakeSwap legs");
        address router = makeAddr("a testnet router");
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressHasNoCode.selector, "PANCAKE_ROUTER", router));
        checks.resolvePancakeRouter(router);
        vm.etch(router, hex"00");
        assertEq(checks.resolvePancakeRouter(router), router);
    }

    function test_onMainnetOnlyThePinnedRouter() public {
        vm.chainId(1);
        vm.etch(pancake, hex"00");
        assertEq(checks.resolvePancakeRouter(address(0)), pancake, "zero takes the pinned router");
        assertEq(checks.resolvePancakeRouter(pancake), pancake);
        address other = makeAddr("another router");
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "PANCAKE_ROUTER", other));
        checks.resolvePancakeRouter(other);
    }

    function test_onBnbChainOnlyThePinnedRouter() public {
        vm.chainId(BnbChainAddresses.CHAIN_ID);
        address bnbPancake = BnbChainAddresses.PANCAKE_UNIVERSAL_ROUTER;
        vm.etch(bnbPancake, hex"00");
        assertEq(checks.resolvePancakeRouter(address(0)), bnbPancake, "zero takes BNB Chain's pinned router");
        assertEq(checks.resolvePancakeRouter(bnbPancake), bnbPancake);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "PANCAKE_ROUTER", pancake));
        checks.resolvePancakeRouter(pancake); // Ethereum's router is another address on BNB Chain
        assertEq(checks.BNB_PANCAKE_ROUTER(), bnbPancake);
        assertEq(checks.BNB_UNIVERSAL_ROUTER(), BnbChainAddresses.UNIVERSAL_ROUTER);
        assertTrue(checks.isPinnedChain());
        vm.chainId(11_155_111);
        assertFalse(checks.isPinnedChain());
    }

    function test_neitherRoleMayBeThePancakeRouter() public {
        address owner = makeAddr("owner");
        address guardian = makeAddr("guardian");
        checks.checkRolesAreNotPancake(owner, guardian, pancake);
        checks.checkRolesAreNotPancake(owner, guardian, address(0));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, pancake));
        checks.checkRolesAreNotPancake(pancake, guardian, pancake);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, pancake));
        checks.checkRolesAreNotPancake(owner, pancake, pancake);
    }
}
