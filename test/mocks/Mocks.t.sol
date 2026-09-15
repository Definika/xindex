// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockUSDT} from "./MockUSDT.sol";
import {MockSwapRouter} from "./MockSwapRouter.sol";
import {MockPausableToken} from "./MockPausableToken.sol";
import {MockPartialFillRouter} from "./MockPartialFillRouter.sol";

/// @notice Exercises the mocks' own guard rails so their behaviour in the real tests is trustworthy.
contract MocksTest is Test {
    MockSwapRouter router;
    MockERC20 usdc;
    MockERC20 weth;
    MockERC20 unpriced;
    MockUSDT usdt;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        router = new MockSwapRouter();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        unpriced = new MockERC20("No Price", "NOPE", 18);
        usdt = new MockUSDT();

        router.setPrice(address(usdc), 1e18);
        router.setPrice(address(weth), 3_000e18);
        weth.mint(address(router), 1_000e18);
        usdc.mint(address(router), 1_000_000e6);
    }

    function _path(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, uint24(500), b);
    }

    // ---------------------------------------------------------------------
    // MockSwapRouter
    // ---------------------------------------------------------------------

    function test_router_quotesAreInverse() public view {
        // 3000 USDC -> 1 WETH, and 1 WETH costs 3000 USDC
        assertEq(router.quoteOut(address(usdc), address(weth), 3_000e6), 1e18);
        assertEq(router.quoteIn(address(usdc), address(weth), 1e18), 3_000e6);
        // ceil on exact-output: 1 wei of WETH still costs 1 unit of USDC
        assertEq(router.quoteIn(address(usdc), address(weth), 1), 1);
    }

    function test_router_exactInput_happyPath() public {
        usdc.mint(alice, 3_000e6);
        vm.startPrank(alice);
        usdc.approve(address(router), 3_000e6);
        uint256 out = router.exactInput(
            ISwapRouter02.ExactInputParams({
                path: _path(address(usdc), address(weth)), recipient: bob, amountIn: 3_000e6, amountOutMinimum: 1e18
            })
        );
        vm.stopPrank();
        assertEq(out, 1e18);
        assertEq(weth.balanceOf(bob), 1e18);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_router_exactInput_reverts() public {
        ISwapRouter02.ExactInputParams memory p = ISwapRouter02.ExactInputParams({
            path: abi.encodePacked(address(usdc), address(weth)), // no fee => malformed
            recipient: bob,
            amountIn: 1e6,
            amountOutMinimum: 0
        });
        vm.expectRevert("MockRouter: path");
        router.exactInput(p);

        p.path = _path(address(usdc), address(unpriced));
        vm.expectRevert("MockRouter: no price");
        router.exactInput(p);

        p.path = _path(address(usdc), address(weth));
        p.amountOutMinimum = type(uint256).max;
        vm.expectRevert("Too little received");
        router.exactInput(p);
    }

    function test_router_exactOutput_reverts() public {
        ISwapRouter02.ExactOutputParams memory p = ISwapRouter02.ExactOutputParams({
            path: abi.encodePacked(address(weth), address(usdc)),
            recipient: bob,
            amountOut: 1e18,
            amountInMaximum: type(uint256).max
        });
        vm.expectRevert("MockRouter: path");
        router.exactOutput(p);

        p.path = _path(address(unpriced), address(usdc));
        vm.expectRevert("MockRouter: no price");
        router.exactOutput(p);

        p.path = _path(address(weth), address(usdc));
        p.amountInMaximum = 0;
        vm.expectRevert("Too much requested");
        router.exactOutput(p);
    }

    // ---------------------------------------------------------------------
    // MockUSDT
    // ---------------------------------------------------------------------

    function test_usdt_metadataAndMint() public {
        assertEq(usdt.name(), "Tether USD");
        assertEq(usdt.symbol(), "USDT");
        assertEq(usdt.decimals(), 6);
        usdt.mint(alice, 5e6);
        assertEq(usdt.totalSupply(), 5e6);
        assertEq(usdt.balanceOf(alice), 5e6);
    }

    function test_usdt_approveFromNonZeroReverts() public {
        vm.startPrank(alice);
        usdt.approve(bob, 1);
        vm.expectRevert("USDT: approve from non-zero");
        usdt.approve(bob, 2);
        usdt.approve(bob, 0);
        usdt.approve(bob, 2);
        vm.stopPrank();
        assertEq(usdt.allowance(alice, bob), 2);
    }

    function test_usdt_transferFrom_allowanceAndInfinite() public {
        usdt.mint(alice, 10e6);

        vm.prank(bob);
        vm.expectRevert("USDT: allowance");
        usdt.transferFrom(alice, bob, 1);

        vm.prank(alice);
        usdt.approve(bob, 4e6);
        vm.prank(bob);
        usdt.transferFrom(alice, bob, 3e6);
        assertEq(usdt.allowance(alice, bob), 1e6);

        vm.prank(alice);
        usdt.approve(bob, 0);
        vm.prank(alice);
        usdt.approve(bob, type(uint256).max);
        vm.prank(bob);
        usdt.transferFrom(alice, bob, 2e6);
        assertEq(usdt.allowance(alice, bob), type(uint256).max, "infinite allowance is not decremented");
        assertEq(usdt.balanceOf(bob), 5e6);
    }

    function test_usdt_transferInsufficientBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert("USDT: balance");
        usdt.transfer(bob, 1);
    }
    // ---------------------------------------------------------------------
    // MockPausableToken
    // ---------------------------------------------------------------------

    function test_pausableToken_blocksTransfersWhilePaused() public {
        MockPausableToken p = new MockPausableToken("Pausable BTC", "pBTC", 8);
        assertEq(p.decimals(), 8);
        p.mint(alice, 10);

        p.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        p.transfer(bob, 1);

        p.setPaused(false);
        vm.prank(alice);
        p.transfer(bob, 1);
        assertEq(p.balanceOf(bob), 1);
    }

    // ---------------------------------------------------------------------
    // MockPartialFillRouter
    // ---------------------------------------------------------------------

    function test_partialFillRouter_sellsHalf() public {
        MockPartialFillRouter half = new MockPartialFillRouter(3_000e6);
        usdc.mint(address(half), 10_000e6);
        weth.mint(alice, 1e18);

        vm.startPrank(alice);
        weth.approve(address(half), 1e18);
        ISwapRouter02.ExactInputParams memory p = ISwapRouter02.ExactInputParams({
            path: _path(address(weth), address(usdc)), recipient: alice, amountIn: 1e18, amountOutMinimum: 1_500e6 + 1
        });
        vm.expectRevert("Too little received");
        half.exactInput(p);

        p.amountOutMinimum = 1_500e6;
        assertEq(half.exactInput(p), 1_500e6);
        vm.stopPrank();
        assertEq(weth.balanceOf(alice), 5e17, "half of the input was never taken");

        vm.expectRevert("MockPartialFillRouter: exactOutput unsupported");
        half.exactOutput(
            ISwapRouter02.ExactOutputParams({path: "", recipient: alice, amountOut: 1, amountInMaximum: 1})
        );
    }
}
