// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "../XindexTest.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockUniversalRouter} from "../mocks/MockUniversalRouter.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";

/// @notice Killing tests for IndexZap mutants that survive the whole offline suite (mutation-hunter, 2026-09-24), on
///         the zap suite's own mock market.
contract ZapMutationGapsTest is XindexTest {
    IndexZap zap;
    MockUniversalRouter router;
    IndexToken index;
    MockERC20 wbtc;
    MockERC20 weth;
    MockERC20 usdc;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint24 constant FEE = 500;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, address(0));
        router = new MockUniversalRouter(makeAddr("poolManager"));
        zap = new IndexZap(factory, router);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = market.weth();
        usdc = market.usdc();
        router.setPrice(address(wbtc), 60_000e18, 8);
        router.setPrice(address(weth), 3_000e18, 18);
        router.setPrice(address(usdc), 1e18, 6);
        wbtc.mint(address(router.inventory()), 1_000e8);
        weth.mint(address(router.inventory()), 100_000e18);
        usdc.mint(address(router.inventory()), 1_000_000_000e6);
        _list(address(wbtc));
        _list(address(weth));
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        (t[0], t[1]) = (address(wbtc), address(weth));
        (u[0], u[1]) = (100_000, 1e16);
        index = IndexToken(factory.createIndex("Two", "TWO", t, u, 0));
    }

    function _noV4() internal pure returns (PathKey[] memory) {
        return new PathKey[](0);
    }

    /// @dev MH-E (zap half). `ZapMint` and `ZapBurn` name the caller (who paid, or whose shares burned) and the
    ///      recipient separately. Every expectEmit on them has msg.sender == p.to, so swapping the two survives.
    function test_MHE_zapEventsNameCallerAndRecipientApart() public {
        IIndexZap.MintLeg[] memory mintLegs = new IIndexZap.MintLeg[](2);
        mintLegs[0] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(address(wbtc), FEE, address(usdc)), v4Path: _noV4(), maxAmountIn: 0
        });
        mintLegs[1] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(address(weth), FEE, address(usdc)), v4Path: _noV4(), maxAmountIn: 0
        });
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);
        // 0.001 WBTC at $60k and 0.01 WETH at $3k: $90 of basket for one share.
        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ZapMint(address(index), alice, bob, address(usdc), 90e6, 1e18);
        zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(index),
                expectedNonce: 0,
                tokenIn: address(usdc),
                maxAmountIn: 200e6,
                shares: 1e18,
                legs: mintLegs,
                to: bob,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        IIndexZap.BurnLeg[] memory burnLegs = new IIndexZap.BurnLeg[](2);
        burnLegs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(address(wbtc), FEE, address(usdc)), v4Path: _noV4(), minAmountOut: 0
        });
        burnLegs[1] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(address(weth), FEE, address(usdc)), v4Path: _noV4(), minAmountOut: 0
        });
        vm.startPrank(bob);
        index.approve(address(zap), 1e18);
        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ZapBurn(address(index), bob, alice, address(usdc), 1e18, 90e6);
        zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(index),
                expectedNonce: 0,
                shares: 1e18,
                tokenOut: address(usdc),
                minAmountOut: 1,
                legs: burnLegs,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    /// @dev MH-Z1. `_buy` measures a mint leg's delivery as `balanceOf(component) - outBefore` and raises ShortFill
    ///      below `amountOut`, which is load-bearing because the pinned V4 router does not check exact-output delivery.
    ///      Its only test runs with the zap holding none of the component, where `balanceOf + outBefore` gives the same
    ///      answer, so that mutant survives. With it, any stray of the component sitting in the zap hides a short fill
    ///      of up to that stray, and `issue` quietly spends the stray to cover it. Here one raw WBTC sits in the zap and
    ///      the router under-delivers by one: only the shipped delta check still names the short fill.
    function test_MHZ1_aStrayOfTheComponentDoesNotHideAShortFill() public {
        wbtc.mint(address(zap), 1); // a stray, as anyone can send
        router.setMode(MockUniversalRouter.Mode.UnderDeliverExactOut);
        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](2);
        legs[0] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(address(wbtc), FEE, address(usdc)), v4Path: _noV4(), maxAmountIn: 0
        });
        legs[1] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(address(weth), FEE, address(usdc)), v4Path: _noV4(), maxAmountIn: 0
        });
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);
        uint256[] memory need = index.previewIssue(1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.ShortFill.selector, 0, need[0] - 1, need[0]));
        zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(index),
                expectedNonce: 0,
                tokenIn: address(usdc),
                maxAmountIn: 200e6,
                shares: 1e18,
                legs: legs,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    /// @dev MH-Z2. `PathLib.isValidShape` requires a whole number of hops, `(length - 20) % 23 == 0`, on top of the
    ///      one-hop minimum. No test offers a path of a valid minimum length with a stray byte in it, so the mutant that
    ///      turns the `&&` into `||` (every path of 43 bytes or more is well-shaped) survives, as does dropping the
    ///      modulo. Here the endpoints the zap checks are right (WBTC first, USDC in the last 20 bytes) but a stray byte
    ///      sits between the fee and the last token, so the router would read the hop's input from a misaligned
    ///      20-byte window: only the shape check names it as a bad route.
    function test_MHZ2_aPathWithAStrayByteIsABadRoute() public {
        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](2);
        legs[0] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(address(wbtc), FEE, bytes1(0x42), address(usdc)), v4Path: _noV4(), maxAmountIn: 0
        });
        legs[1] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(address(weth), FEE, address(usdc)), v4Path: _noV4(), maxAmountIn: 0
        });
        assertEq(legs[0].v3Path.length, 44);
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadRoute.selector, 0));
        zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(index),
                expectedNonce: 0,
                tokenIn: address(usdc),
                maxAmountIn: 200e6,
                shares: 1e18,
                legs: legs,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }
}
