// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {UniversalRouterCommands as Cmd} from "../../src/libraries/UniversalRouterCommands.sol";
import {IndexZapTest} from "../IndexZap.t.sol";
import {MockUniversalRouter} from "../mocks/MockUniversalRouter.sol";
import {IndexZapForkTest} from "../fork/IndexZap.fork.t.sol";
import {ForkAddresses as A} from "../fork/ForkAddresses.sol";

/// @notice Independent verification: a router balance of a burn hop's input token larger than the hop's spend makes
///         `inBefore - balanceAfter` underflow inside `Math.saturatingSub(given, ...)` (IndexZap.sol:316 / :346).
///         Unit half, on the repo's strict MockUniversalRouter.
contract VerifyStrayBurnUnit is IndexZapTest {
    event ComponentReturned(address indexed index, address indexed to, address indexed component, uint256 amount);

    address griefer = makeAddr("griefer");

    function _burnAll(IIndexZap.BurnLeg[] memory legs) internal returns (uint256) {
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        uint256 out = zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
        return out;
    }

    function _expectBurnPanics(IIndexZap.BurnLeg[] memory legs) internal {
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        IIndexZap.BurnParams memory p = _burnParams(address(index), 1e18, address(usdc), 1, legs, alice);
        vm.expectRevert(stdError.arithmeticError); // Panic(0x11)
        zap.burnToToken(p);
        vm.stopPrank();
    }

    function _griefSweep(address token) internal {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(token, griefer, uint256(0));
        vm.prank(griefer);
        router.execute(abi.encodePacked(Cmd.SWEEP), inputs);
    }

    /// Component hop (V3, first hop of the WBTC leg): got = 100_000 sats, stray 100_001 sats.
    function test_verify_unit_v3ComponentHop_strayAboveSpendPanics() public {
        _mintFor(alice, 1e18, 200e6);
        wbtc.mint(griefer, 100_001);
        vm.prank(griefer);
        wbtc.transfer(address(router), 100_001);

        _expectBurnPanics(_burnLegs(address(usdc)));

        _griefSweep(address(wbtc));
        assertEq(wbtc.balanceOf(griefer), 100_001, "griefer recovers the whole donation");
        uint256 out = _burnAll(_burnLegs(address(usdc)));
        assertGt(out, 0, "the identical burn succeeds on a clean router");
    }

    /// Boundary: a stray exactly equal to the spend does not revert, and is reported as `ComponentReturned` although
    /// the swap sold every wei it was given.
    function test_verify_unit_v3ComponentHop_strayEqualToSpendIsReportedAsUnsold() public {
        _mintFor(alice, 1e18, 200e6);
        wbtc.mint(address(router), 100_000);
        IIndexZap.BurnParams memory p = _burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), alice);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectEmit(true, true, true, true, address(zap));
        emit ComponentReturned(address(index), alice, address(wbtc), 100_000);
        zap.burnToToken(p);
        vm.stopPrank();
        assertEq(wbtc.balanceOf(alice), 100_000, "the router's stray reaches alice as 'unsold' WBTC");
    }

    /// Intermediate hop: hop 2 of the WBTC leg sells 0.02 WETH; a 0.02 WETH + 1 wei stray panics it.
    function test_verify_unit_v3IntermediateHop_strayAboveSpendPanics() public {
        _mintFor(alice, 1e18, 200e6);
        weth.mint(address(router), 2e16 + 1);
        _expectBurnPanics(_burnLegs(address(usdc)));
    }

    /// V4 leg: LINK leg via a hookless single-hop V4 route sells 1 LINK; a 1 LINK + 1 wei stray panics it.
    function test_verify_unit_v4Leg_strayAboveSpendPanics() public {
        _mintFor(alice, 1e18, 200e6);
        IIndexZap.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[2] = IIndexZap.BurnLeg({v3Path: "", v4Path: _v4Path1(address(usdc)), minAmountOut: 0});
        link.mint(address(router), 1e18 + 1);
        _expectBurnPanics(legs);
    }

    /// Partial fill (the case the saturating arithmetic was written for): the pool takes half of the 100_000 sats,
    /// so any stray above the 50_000 actually spent panics the burn instead of being refunded.
    function test_verify_unit_partialFill_strayAbovePartialSpendPanics() public {
        _mintFor(alice, 1e18, 200e6);
        router.setMode(MockUniversalRouter.Mode.PartialFirstHop);
        wbtc.mint(address(router), 50_001);
        _expectBurnPanics(_burnLegs(address(usdc)));
    }

    /// The mint side, by contrast, saturates: the same kind of stray (tokenIn) never reverts a mint.
    function test_verify_unit_mintSideSaturates() public {
        usdc.mint(address(router), 1_000e6);
        uint256 spent = _mintFor(alice, 1e18, 200e6);
        assertEq(spent, 0);
        assertEq(index.balanceOf(alice), 1e18);
    }
}

/// @notice Fork half: the real Universal Router 2.0.0 and the real PoolManager.
contract VerifyStrayBurnFork is IndexZapForkTest {
    event ComponentReturned(address indexed index, address indexed to, address indexed component, uint256 amount);

    address griefer = makeAddr("griefer");

    function _donate(address token, uint256 amount) internal {
        deal(token, griefer, amount);
        vm.prank(griefer);
        IERC20(token).transfer(A.UNIVERSAL_ROUTER, amount);
    }

    function _griefSweep(address token) internal {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(token, griefer, uint256(0));
        vm.prank(griefer);
        IUniversalRouter(A.UNIVERSAL_ROUTER).execute(abi.encodePacked(Cmd.SWEEP), inputs);
    }

    function _burnParams(IIndexZap.BurnLeg[] memory legs) internal view returns (IIndexZap.BurnParams memory) {
        return IIndexZap.BurnParams({
            index: address(index),
            expectedNonce: 0,
            shares: 1e18,
            tokenOut: A.USDC,
            minAmountOut: 1,
            legs: legs,
            to: alice,
            deadline: block.timestamp
        });
    }

    /// Front-run with 1 WETH: exceeds the ~0.0x WETH that hop 2 of the WBTC leg sells (0.001 WBTC worth of WETH).
    function test_verify_fork_v3IntermediateHop_griefAndRecover() public {
        _mint(A.USDC, 1e18, 100);
        assertEq(IERC20(A.WETH).balanceOf(A.UNIVERSAL_ROUTER), 0, "router starts clean");
        _donate(A.WETH, 1 ether);

        IIndexZap.BurnParams memory p = _burnParams(_burnLegs(_burnPaths(A.USDC)));
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(stdError.arithmeticError);
        zap.burnToToken(p);
        vm.stopPrank();

        _griefSweep(A.WETH);
        assertEq(IERC20(A.WETH).balanceOf(griefer), 1 ether, "griefer recovers 100% of the donation");

        vm.prank(alice);
        uint256 out = zap.burnToToken(p);
        assertGt(out, 0, "same burn succeeds once the router is clean");
        assertEq(index.balanceOf(alice), 0);
    }

    /// V4 LINK leg (LINK -> ether -> USDC): 1 LINK sold, 1 LINK + 1 wei planted.
    function test_verify_fork_v4Leg_strayAboveSpendPanics() public {
        _mint(A.USDC, 1e18, 100);
        _donate(A.LINK, 1e18 + 1);
        IIndexZap.BurnParams memory p = _burnParams(_mixedBurnLegs());
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(stdError.arithmeticError);
        zap.burnToToken(p);
        vm.stopPrank();
    }

    /// Control / boundary on the real router: a stray equal to the V4 leg's spend (1 LINK) does not revert and is
    /// emitted as ComponentReturned although the V4 swap consumed all of its input.
    function test_verify_fork_v4Leg_strayAtSpendIsForwardedAsUnsold() public {
        _mint(A.USDC, 1e18, 100);
        _donate(A.LINK, 1e18);
        IIndexZap.BurnParams memory p = _burnParams(_mixedBurnLegs());
        uint256 linkBefore = IERC20(A.LINK).balanceOf(alice);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectEmit(true, true, true, true, address(zap));
        emit ComponentReturned(address(index), alice, A.LINK, 1e18);
        zap.burnToToken(p);
        vm.stopPrank();
        assertEq(IERC20(A.LINK).balanceOf(alice) - linkBefore, 1e18, "the stray reaches alice labelled as unsold");
        assertEq(IERC20(A.LINK).balanceOf(A.UNIVERSAL_ROUTER), 0);
    }
}
