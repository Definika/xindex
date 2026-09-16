// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FaucetToken} from "../script/testnet/FaucetToken.sol";

contract FaucetTokenTest is Test {
    FaucetToken token;
    address alice = makeAddr("alice");

    function setUp() public {
        token = new FaucetToken("Xindex Test WBTC", "tWBTC", 8, 0.001e8, 10e8);
    }

    function test_constructor_mintsStartingSupplyToDeployer() public view {
        assertEq(token.name(), "Xindex Test WBTC");
        assertEq(token.symbol(), "tWBTC");
        assertEq(token.decimals(), 8);
        assertEq(token.DRIP_AMOUNT(), 0.001e8);
        assertEq(token.balanceOf(address(this)), 10e8);
        assertEq(token.totalSupply(), 10e8);
    }

    function test_drip_oncePerCooldown() public {
        vm.startPrank(alice);
        token.drip();
        assertEq(token.balanceOf(alice), 0.001e8);
        assertEq(token.lastDrip(alice), block.timestamp);

        uint256 next = block.timestamp + token.COOLDOWN();
        vm.expectRevert(abi.encodeWithSelector(FaucetToken.DripTooSoon.selector, next));
        token.drip();

        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(FaucetToken.DripTooSoon.selector, next));
        token.drip();

        vm.warp(next);
        token.drip();
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 0.002e8);
        assertEq(token.totalSupply(), 10e8 + 0.002e8);
    }

    function test_drip_cooldownIsPerAccount() public {
        vm.prank(alice);
        token.drip();
        token.drip();
        assertEq(token.balanceOf(address(this)), 10e8 + 0.001e8);
    }
}
