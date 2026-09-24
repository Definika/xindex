// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockUniversalRouter} from "../mocks/MockUniversalRouter.sol";
import {SimRouter} from "./SimRouter.sol";

/// @notice CR-I14's documentation fix is incomplete. The audit of 2026-09-23 found that the docs justified the
///         pre-fund/sweep design as atomic because "a sweep that came up short would fail the swap", while the zap
///         encodes a sweep minimum of zero. The triage marks it DOCUMENTED and names the zap's design notes,
///         AGENTS.md and ARCHITECTURE as corrected. README.md's known limitation on callback currencies still says
///         the opposite: "which is atomic — a short sweep fails the swap and reverts everything". This test pins
///         (1) that the sentence is still in the README next to the corrected text in the zap, (2) that every SWEEP
///         the zap emits has amountMin 0, and (3) that a sweep which returns less than the router held does not fail
///         the call: the mint succeeds and the shortfall simply comes out of the caller's refund.
contract ShortSweepClaimTest is Test {
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    MockMarket market;
    IndexFactory factory;
    MockERC20 weth;
    MockERC20 usdc;
    MockERC20 wbtc;
    IndexToken index;
    function test_readmeStillSaysAShortSweepRevertsEverything() public view {
        string memory readme = vm.readFile("README.md");
        string memory zapSrc = vm.readFile("src/IndexZap.sol");
        assertTrue(
            vm.contains(readme, "a short sweep fails the swap"), "README still claims a short sweep reverts the call"
        );
        assertTrue(
            vm.contains(zapSrc, "The sweep's minimum is zero, so it checks nothing and can never come up short (CR-I14)"),
            "the zap's own notes were corrected"
        );
    }

    function _list(IndexFactory factory, MockMarket market, address owner, address token) internal {
        IIndexFactory.TokenConfig memory config = market.config(token, 1e8);
        vm.prank(owner);
        factory.proposeListing(token, config);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    function test_everySweepTheZapEmitsHasMinimumZero_andAShortSweepDoesNotRevert() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, address(0));
        weth = market.weth();
        usdc = market.usdc();
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        _list(factory, market, owner, address(wbtc));
        _list(factory, market, owner, address(weth));
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        (t[0], t[1]) = (address(wbtc), address(weth));
        (u[0], u[1]) = (100_000, 1e16);
        index = IndexToken(factory.createIndex("Two", "TWO", t, u, 0));

        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](2);
        legs[0].v3Path = abi.encodePacked(address(wbtc), uint24(500), address(usdc));
        legs[1].v3Path = abi.encodePacked(address(weth), uint24(500), address(usdc));
        IIndexZap.MintParams memory p = IIndexZap.MintParams({
            index: address(index),
            expectedNonce: 0,
            tokenIn: address(usdc),
            maxAmountIn: 1_000e6,
            shares: 1e18,
            legs: legs,
            to: alice,
            deadline: block.timestamp
        });

        // (2) The repository's strict mock records the SWEEP input: amountMin is 0.
        {
            MockUniversalRouter strictRouter = new MockUniversalRouter(makeAddr("pm"));
            IndexZap zap = new IndexZap(factory, strictRouter);
            strictRouter.setPrice(address(wbtc), 110_000e18, 8);
            strictRouter.setPrice(address(weth), 3_000e18, 18);
            strictRouter.setPrice(address(usdc), 1e18, 6);
            wbtc.mint(address(strictRouter.inventory()), 1e8);
            weth.mint(address(strictRouter.inventory()), 1e18);
            usdc.mint(alice, 1_000e6);
            vm.startPrank(alice);
            usdc.approve(address(zap), 1_000e6);
            zap.mintWithToken(p);
            vm.stopPrank();
            (,, uint256 amountMin) = abi.decode(strictRouter.lastInput(1), (address, address, uint256));
            assertEq(amountMin, 0, "the zap's SWEEP minimum is zero");
        }

        _shortSweep(p);
    }

    function _shortSweep(IIndexZap.MintParams memory p) internal {
        // (3) A router whose sweep hands back only half its balance: the call still succeeds.
        SimRouter sim = new SimRouter(makeAddr("pm2"));
        IndexZap zap2 = new IndexZap(factory, sim);
        sim.setPrice(address(wbtc), 110_000e18, 8);
        sim.setPrice(address(weth), 3_000e18, 18);
        sim.setPrice(address(usdc), 1e18, 6);
        wbtc.mint(address(sim.v3Pools()), 1e8);
        weth.mint(address(sim.v3Pools()), 1e18);
        sim.setSkimBps(5_000);
        usdc.mint(alice, 1_000e6);
        uint256 before = usdc.balanceOf(alice);
        vm.startPrank(alice);
        usdc.approve(address(zap2), 1_000e6);
        uint256 spent = zap2.mintWithToken(p);
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 2e18, "the mint went through despite short sweeps");
        assertGt(IERC20(address(usdc)).balanceOf(address(sim)), 0, "the router kept part of the pre-fund");
        assertEq(before - usdc.balanceOf(alice), spent, "the shortfall came out of the refund, not a revert");
    }
}
