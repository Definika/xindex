// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISwapRouter02} from "./ISwapRouter02.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockUSDT} from "./MockUSDT.sol";
import {MockSwapRouter} from "./MockSwapRouter.sol";
import {MockPausableToken} from "./MockPausableToken.sol";
import {MockMarket, usdWad} from "./MockMarket.sol";
import {TestAggregator} from "../../script/testnet/TestAggregator.sol";
import {MockRouterInventory, MockUniversalRouter} from "./MockUniversalRouter.sol";
import {UniversalRouterCommands as Cmd} from "../../src/libraries/UniversalRouterCommands.sol";
import {
    PathKey,
    UniswapV4Types as V4,
    V4ExactInputParams,
    V4ExactOutputParams
} from "../../src/libraries/UniswapV4Types.sol";
import {ForkFeeds} from "../fork/ForkFeeds.sol";
import {ForkAddresses as A} from "../fork/ForkAddresses.sol";
import {CompositeFeed} from "../../src/CompositeFeed.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IXindexErrors} from "../../src/interfaces/IXindexErrors.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./MockUniswapV3.sol";
import {MockWETH} from "./MockWETH.sol";
import {MockPositionManager} from "./MockPositionManager.sol";
import {INonfungiblePositionManager} from "../../script/interfaces/INonfungiblePositionManager.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {RebalanceExecutorV3} from "../fork/RebalanceExecutorV3.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";

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

    // ---------------------------------------------------------------------
    // MockUniswapV3Pool and MockUniswapV3Factory
    // ---------------------------------------------------------------------

    /// @dev The mock pool records its starting price once, as the real one does.
    function test_uniswapPool_initializesOnlyOnce() public {
        MockUniswapV3Factory f = new MockUniswapV3Factory();
        MockUniswapV3Pool p = MockUniswapV3Pool(f.createPool(address(1), address(2), 500));
        p.initialize(1 << 96);
        assertEq(p.sqrtPriceX96(), 1 << 96);
        vm.expectRevert(bytes("AI"));
        p.initialize(2 << 96);
    }

    function test_uniswapFactory_registersBothOrdersAndSortsTokens() public {
        MockUniswapV3Factory f = new MockUniswapV3Factory();
        address pool = f.createPool(address(weth), address(usdc), 500);
        assertEq(f.getPool(address(weth), address(usdc), 500), pool);
        assertEq(f.getPool(address(usdc), address(weth), 500), pool);
        assertEq(f.getPool(address(usdc), address(weth), 3000), address(0));

        address low = address(0x1000);
        address high = address(0xF000);
        MockUniswapV3Pool ascending = new MockUniswapV3Pool(low, high, 3000);
        MockUniswapV3Pool descending = new MockUniswapV3Pool(high, low, 3000);
        assertEq(ascending.token0(), low);
        assertEq(ascending.token1(), high);
        assertEq(descending.token0(), low);
        assertEq(descending.token1(), high);
        assertEq(descending.fee(), 3000);
    }

    // ---------------------------------------------------------------------
    // MockWETH and MockPositionManager
    // ---------------------------------------------------------------------

    function test_weth_depositWrapsEther() public {
        MockWETH w = new MockWETH();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        w.deposit{value: 0.4 ether}();
        assertEq(w.balanceOf(alice), 0.4 ether);
        assertEq(address(w).balance, 0.4 ether);
    }

    function test_positionManager_takesDesiredAmountsAndRecordsThem() public {
        MockPositionManager positions = new MockPositionManager();
        weth.mint(alice, 2e18);
        usdc.mint(alice, 3_000e6);
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            tickLower: -60,
            tickUpper: 60,
            amount0Desired: 3_000e6,
            amount1Desired: 1e18,
            amount0Min: 0,
            amount1Min: 0,
            recipient: bob,
            deadline: 7
        });
        vm.startPrank(alice);
        usdc.approve(address(positions), 3_000e6);
        weth.approve(address(positions), 1e18);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = positions.mint(params);
        vm.stopPrank();

        assertEq(tokenId, 1);
        assertEq(liquidity, 1);
        assertEq(amount0, 3_000e6);
        assertEq(amount1, 1e18);
        assertEq(positions.mints(), 1);
        assertEq(usdc.balanceOf(address(positions)), 3_000e6);
        assertEq(weth.balanceOf(alice), 1e18);
        INonfungiblePositionManager.MintParams memory recorded = positions.position(1);
        assertEq(recorded.tickLower, -60);
        assertEq(recorded.tickUpper, 60);
        assertEq(recorded.recipient, bob);
        assertEq(recorded.deadline, 7);
    }

    // ---------------------------------------------------------------------
    // MockUniversalRouter
    // ---------------------------------------------------------------------

    /// @dev The router mock is strict on purpose: it refuses everything the zap is not supposed to emit, so a change
    ///      that started emitting one would fail here rather than on mainnet. These are those refusals.
    function test_universalRouter_refusesWhatTheZapNeverEmits() public {
        MockUniversalRouter r = new MockUniversalRouter(makeAddr("pm"));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        r.setPrice(address(a), 1e18, 18);
        r.setPrice(address(b), 1e18, 18);
        b.mint(address(r.inventory()), 100e18);

        bytes[] memory one = new bytes[](1);
        bytes[] memory two = new bytes[](2);

        vm.expectRevert("MockUR: length");
        r.execute(abi.encodePacked(Cmd.SWEEP, Cmd.SWEEP), one);

        one[0] = "";
        vm.expectRevert("MockUR: the zap emitted a command it should not");
        r.execute(abi.encodePacked(uint8(0x02)), one); // PERMIT2_TRANSFER_FROM

        // A swap that makes the caller the payer, which is what pre-funding exists to avoid.
        one[0] = abi.encode(
            address(this), uint256(1), uint256(0), abi.encodePacked(address(a), uint24(500), address(b)), true
        );
        vm.expectRevert("MockUR: the zap pays from the router's balance, never the caller's");
        r.execute(abi.encodePacked(Cmd.V3_SWAP_EXACT_IN), one);

        // A sweep to anyone but the caller.
        one[0] = abi.encode(address(a), makeAddr("elsewhere"), uint256(0));
        vm.expectRevert("MockUR: the zap names itself as the recipient");
        r.execute(abi.encodePacked(Cmd.SWEEP), one);

        // A sweep that finds less than it was promised.
        one[0] = abi.encode(address(a), address(this), uint256(1));
        vm.expectRevert("MockUR: sweep below minimum");
        r.execute(abi.encodePacked(Cmd.SWEEP), one);

        // A swap the zap did not pre-fund.
        two[0] = abi.encode(
            address(this), uint256(1e18), uint256(0), abi.encodePacked(address(a), uint24(500), address(b)), false
        );
        two[1] = abi.encode(address(a), address(this), uint256(0));
        vm.expectRevert("MockUR: not pre-funded");
        r.execute(abi.encodePacked(Cmd.V3_SWAP_EXACT_IN, Cmd.SWEEP), two);
    }

    function test_universalRouter_refusesMalformedV4Actions() public {
        MockUniversalRouter r = new MockUniversalRouter(makeAddr("pm"));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        r.setPrice(address(a), 1e18, 18);
        r.setPrice(address(b), 1e18, 18);

        bytes[] memory one = new bytes[](1);
        bytes[] memory params = new bytes[](3);
        PathKey[] memory path = new PathKey[](1);
        path[0] =
            PathKey({intermediateCurrency: address(b), fee: 500, tickSpacing: 10, hooks: address(0), hookData: ""});

        params[0] =
            abi.encode(V4ExactInputParams({currencyIn: address(a), path: path, amountIn: 1e18, amountOutMinimum: 0}));
        params[1] = abi.encode(address(a), V4.OPEN_DELTA, false);
        params[2] = abi.encode(address(b), address(this), V4.OPEN_DELTA);

        bytes[] memory shortParams = new bytes[](2);
        shortParams[0] = params[0];
        shortParams[1] = params[1];
        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.SETTLE), shortParams);
        vm.expectRevert("MockUR: the zap emits swap, settle, take");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.TAKE, V4.TAKE), params);
        vm.expectRevert("MockUR: second action is settle");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.SETTLE, V4.SETTLE), params);
        vm.expectRevert("MockUR: third action is take");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        // Anything but "the whole of it" on either side would leave the unlock with a delta to argue about.
        bytes[] memory partialDelta = new bytes[](3);
        partialDelta[0] = params[0];
        partialDelta[1] = abi.encode(address(a), uint256(1), false);
        partialDelta[2] = params[2];
        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.SETTLE, V4.TAKE), partialDelta);
        vm.expectRevert("MockUR: settle the whole debt");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        partialDelta[1] = params[1];
        partialDelta[2] = abi.encode(address(b), address(this), uint256(1));
        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.SETTLE, V4.TAKE), partialDelta);
        vm.expectRevert("MockUR: take the whole credit");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        // A route with a hook, which the zap rejects before the router ever sees it.
        PathKey[] memory hooked = new PathKey[](1);
        hooked[0] = PathKey({
            intermediateCurrency: address(b), fee: 500, tickSpacing: 10, hooks: makeAddr("hook"), hookData: ""
        });
        bytes[] memory hookedParams = new bytes[](3);
        hookedParams[0] =
            abi.encode(V4ExactInputParams({currencyIn: address(a), path: hooked, amountIn: 1e18, amountOutMinimum: 0}));
        hookedParams[1] = params[1];
        hookedParams[2] = params[2];
        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.SETTLE, V4.TAKE), hookedParams);
        vm.expectRevert("MockUR: the zap rejects hooks");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        // And a first action that is not a swap at all.
        one[0] = abi.encode(abi.encodePacked(V4.TAKE, V4.SETTLE, V4.TAKE), params);
        vm.expectRevert("MockUR: first action is a swap");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);
    }

    function test_universalRouter_quotesAndV4Slippage() public {
        MockUniversalRouter r = new MockUniversalRouter(makeAddr("pm"));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 8);
        r.setPrice(address(a), 2e18, 18);
        r.setPrice(address(b), 1e18, 8);
        a.mint(address(r), 10e18);
        b.mint(address(r.inventory()), 100e8);

        // Two dollars a whole A against a dollar a whole B, across different decimals.
        assertEq(r.quoteOut(address(a), address(b), 1e18), 2e8);
        assertEq(r.quoteIn(address(a), address(b), 2e8), 1e18);

        bytes[] memory one = new bytes[](1);
        PathKey[] memory path = new PathKey[](1);
        path[0] =
            PathKey({intermediateCurrency: address(b), fee: 500, tickSpacing: 10, hooks: address(0), hookData: ""});
        bytes[] memory params = new bytes[](3);
        params[1] = abi.encode(address(a), V4.OPEN_DELTA, false);
        params[2] = abi.encode(address(b), address(this), V4.OPEN_DELTA);

        // A settle that names a currency the swap does not owe.
        params[0] =
            abi.encode(V4ExactInputParams({currencyIn: address(a), path: path, amountIn: 1e18, amountOutMinimum: 0}));
        bytes[] memory wrongSettle = new bytes[](3);
        wrongSettle[0] = params[0];
        wrongSettle[1] = abi.encode(address(b), V4.OPEN_DELTA, false);
        wrongSettle[2] = params[2];
        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.SETTLE, V4.TAKE), wrongSettle);
        vm.expectRevert("MockUR: settle the input");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        // A V4 exact input that misses its minimum.
        params[0] =
            abi.encode(V4ExactInputParams({currencyIn: address(a), path: path, amountIn: 1e18, amountOutMinimum: 3e8}));
        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.SETTLE, V4.TAKE), params);
        vm.expectRevert(abi.encodeWithSignature("V4TooLittleReceived(uint256,uint256)", uint256(3e8), uint256(2e8)));
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        // And a V4 exact output that would cost more than its cap.
        bytes[] memory outParams = new bytes[](3);
        outParams[0] =
            abi.encode(V4ExactOutputParams({currencyOut: address(b), path: path, amountOut: 2e8, amountInMaximum: 1}));
        outParams[1] = abi.encode(address(b), V4.OPEN_DELTA, false); // path[0] names B, so B is what is settled
        outParams[2] = abi.encode(address(b), address(this), V4.OPEN_DELTA);
        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_OUT, V4.SETTLE, V4.TAKE), outParams);
        vm.expectRevert(abi.encodeWithSignature("V4TooMuchRequested(uint256,uint256)", uint256(1), uint256(2e8)));
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        // A take that names a currency the swap did not produce, on both directions.
        bytes[] memory wrongTakeIn = new bytes[](3);
        wrongTakeIn[0] =
            abi.encode(V4ExactInputParams({currencyIn: address(a), path: path, amountIn: 1e18, amountOutMinimum: 0}));
        wrongTakeIn[1] = params[1];
        wrongTakeIn[2] = abi.encode(address(a), address(this), V4.OPEN_DELTA);
        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.SETTLE, V4.TAKE), wrongTakeIn);
        vm.expectRevert("MockUR: take the output");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        bytes[] memory wrongOut = new bytes[](3);
        wrongOut[0] = abi.encode(
            V4ExactOutputParams({currencyOut: address(b), path: path, amountOut: 1, amountInMaximum: type(uint128).max})
        );
        wrongOut[1] = abi.encode(address(a), V4.OPEN_DELTA, false); // path[0] names B, not A
        wrongOut[2] = outParams[2];
        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_OUT, V4.SETTLE, V4.TAKE), wrongOut);
        vm.expectRevert("MockUR: settle the input");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        wrongOut[1] = abi.encode(address(b), V4.OPEN_DELTA, false);
        wrongOut[2] = abi.encode(address(a), address(this), V4.OPEN_DELTA);
        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_OUT, V4.SETTLE, V4.TAKE), wrongOut);
        vm.expectRevert("MockUR: take the output");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);

        // The inventory pays out only for the router. Read first: expectRevert applies to the next call, and the
        // getter is one.
        MockRouterInventory inventory = r.inventory();
        vm.expectRevert("MockURInv: only the router pays out");
        inventory.pay(address(b), address(this), 1);

        // Actions and parameters come in pairs.
        bytes[] memory mismatched = new bytes[](2);
        mismatched[0] = params[0];
        mismatched[1] = params[1];
        one[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.SETTLE, V4.TAKE), mismatched);
        vm.expectRevert("MockUR: v4 length");
        r.execute(abi.encodePacked(Cmd.V4_SWAP), one);
    }

    // ---------------------------------------------------------------------
    // MockMarket, TestAggregator and CompositeFeed
    // ---------------------------------------------------------------------

    function test_market_pricesAndConfigs() public {
        vm.warp(30 days);
        MockMarket m = new MockMarket();
        address mWeth = address(m.weth());

        IIndexFactory.TokenConfig memory c = m.config(mWeth, 3_000e8);
        assertEq(c.feed, address(m.feedOf(mWeth)), "the feed is created on first use");
        assertEq(c.maxStaleness, m.STALENESS());
        assertEq(c.referenceSupply, m.ETH_SUPPLY());
        assertEq(m.feedOf(mWeth).answer(), 3_000e8);

        MockERC20 token = new MockERC20("T", "T", 18);
        c = m.config(address(token), 42e8);
        assertEq(c.referenceSupply, m.DEFAULT_SUPPLY(), "anything but WETH gets the default supply");
        address feed = c.feed;

        IIndexFactory.TokenConfig memory again = m.configWith(address(token), 7e8, 0);
        assertEq(again.feed, feed, "the feed is created once");
        assertEq(again.referenceSupply, 0);
        assertEq(m.feedOf(address(token)).answer(), 7e8);

        m.movePrice(address(token), 3, 2);
        assertEq(m.feedOf(address(token)).answer(), 10.5e8);

        m.setAge(address(token), 900);
        (,,, uint256 updatedAt,) = m.feedOf(address(token)).latestRoundData();
        assertEq(updatedAt, block.timestamp - 900);

        assertEq(usdWad(1e8, 18), 1e18, "a dollar on an 18-decimal token");
        assertEq(usdWad(30_000e8, 8), 3e32);
    }

    /// @dev The two freshness modes: one that follows the block clock, so a test can warp weeks ahead and still read a
    ///      live feed, and one that pins a timestamp, as a real feed does between rounds.
    function test_testAggregator_bothFreshnessModes() public {
        vm.warp(30 days);
        TestAggregator feed = new TestAggregator("T / USD", 8, 5e8);
        assertEq(feed.description(), "T / USD");
        assertEq(feed.decimals(), 8);
        assertTrue(feed.fresh());

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) =
            feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, 5e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredIn, 1);

        feed.setAnswer(6e8);
        feed.setAge(60);
        vm.warp(block.timestamp + 30 days);
        (, answer,, updatedAt,) = feed.latestRoundData();
        assertEq(answer, 6e8);
        assertEq(updatedAt, block.timestamp - 60, "still on the block clock after a long warp");

        feed.setUpdatedAt(1_000);
        assertFalse(feed.fresh());
        (,,, updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, 1_000, "and pinned once a test says so");
    }

    function test_compositeFeed_multipliesAndBoundsEachLeg() public {
        vm.warp(30 days);
        TestAggregator a = new TestAggregator("BTC / USD", 8, 86_000e8);
        TestAggregator b = new TestAggregator("WBTC / BTC", 8, 0.9995e8);
        CompositeFeed composite = new CompositeFeed(a, b, 1 hours, 24 hours);

        assertEq(composite.decimals(), 8, "the first leg's decimals");
        assertEq(composite.description(), "BTC / USD * WBTC / BTC");
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) =
            composite.latestRoundData();
        assertEq(answer, int256(86_000e8) * 0.9995e8 / 1e8);
        assertEq(roundId, 0, "two legs have no common round");
        assertEq(answeredIn, 0);
        assertEq(startedAt, updatedAt);

        // The older of the two timestamps is reported, so the rule's own bound still reaches the staler leg.
        b.setAge(600);
        (,,, updatedAt,) = composite.latestRoundData();
        assertEq(updatedAt, block.timestamp - 600);

        // Each leg is bounded where it is read: the fast leg's hour does not stretch to the slow leg's day.
        a.setAge(1 hours + 1);
        vm.expectRevert(
            abi.encodeWithSelector(CompositeFeed.StaleLeg.selector, address(a), block.timestamp - 1 hours - 1)
        );
        composite.latestRoundData();
        a.setAge(0);
        b.setAge(24 hours + 1);
        vm.expectRevert(
            abi.encodeWithSelector(CompositeFeed.StaleLeg.selector, address(b), block.timestamp - 24 hours - 1)
        );
        composite.latestRoundData();
        b.setAge(0);

        // A future timestamp is a broken feed, not a fresh one.
        a.setUpdatedAt(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.StaleLeg.selector, address(a), block.timestamp + 1));
        composite.latestRoundData();
        a.setAge(0);

        a.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.NonPositiveAnswer.selector, address(a), int256(0)));
        composite.latestRoundData();
        a.setAnswer(86_000e8);
        b.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.NonPositiveAnswer.selector, address(b), int256(-1)));
        composite.latestRoundData();
    }

    function test_compositeFeed_constructorChecks() public {
        TestAggregator a = new TestAggregator("BTC / USD", 8, 1e8);
        TestAggregator b = new TestAggregator("WBTC / BTC", 8, 1e8);
        uint32 tooLong = 2 days + 1;

        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new CompositeFeed(IAggregatorV3(address(0)), b, 1 hours, 1 hours);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new CompositeFeed(a, IAggregatorV3(address(0)), 1 hours, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.InvalidLegStaleness.selector, uint32(0)));
        new CompositeFeed(a, b, 0, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.InvalidLegStaleness.selector, tooLong));
        new CompositeFeed(a, b, tooLong, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.InvalidLegStaleness.selector, uint32(0)));
        new CompositeFeed(a, b, 1 hours, 0);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.InvalidLegStaleness.selector, tooLong));
        new CompositeFeed(a, b, 1 hours, tooLong);
    }

    // ---------------------------------------------------------------------
    // RebalanceExecutorV3 (used by the fork tests), driven through the mock router
    // ---------------------------------------------------------------------

    function test_rebalanceExecutorV3_sellsBuysAndSettlesThroughARouter() public {
        MockMarket m = new MockMarket();
        IndexFactory f = new IndexFactory(address(this), address(0));
        MockERC20 shrinking = new MockERC20("Shrinking", "SHR", 18);
        MockERC20 growing = new MockERC20("Growing", "GRO", 18);
        MockERC20 mWeth = m.weth();
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(shrinking), address(mWeth), address(growing));

        // WETH and the growing token weigh ten times the shrinking one: it halves, and the other two gain 25% each.
        f.proposeListing(t[0], m.configWith(t[0], 1e8, 12e24));
        f.proposeListing(t[1], m.config(t[1], 1e8));
        f.proposeListing(t[2], m.configWith(t[2], 1e8, 120e24));
        vm.warp(block.timestamp + f.LISTING_DELAY());
        for (uint256 i = 0; i < 3; ++i) {
            f.executeListing(t[i]);
        }
        uint256[] memory u = new uint256[](3);
        (u[0], u[1], u[2]) = (100e18, 100e18, 100e18);
        IndexToken idx = IndexToken(f.createIndex("Executor", "EXEC", t, u, 0));
        shrinking.mint(address(this), 100e18);
        mWeth.mint(address(this), 100e18);
        growing.mint(address(this), 100e18);
        shrinking.approve(address(idx), 100e18);
        mWeth.approve(address(idx), 100e18);
        growing.approve(address(idx), 100e18);
        idx.issue(1e18, address(this));

        MockSwapRouter r = new MockSwapRouter();
        r.setPrice(address(shrinking), 1e18);
        r.setPrice(address(mWeth), 1e18);
        r.setPrice(address(growing), 1e18);
        mWeth.mint(address(r), 1_000e18);
        growing.mint(address(r), 1_000e18);

        RebalanceExecutorV3 executor = new RebalanceExecutorV3(f, r, address(mWeth));
        executor.setFee(address(shrinking), 3000);
        executor.setFee(address(growing), 3000);
        assertEq(executor.feeOf(address(growing)), 3000);

        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        idx.startRebalance(0);
        (uint256 eta,,) = idx.pendingRebalance();
        vm.warp(eta + idx.AUCTION_DURATION());
        executor.fill(idx);

        (, uint256[] memory units) = idx.components();
        assertEq(units[0], 50e18, "the shrinking component went to target");
        assertEq(units[1], 122.5e18, "WETH gained 90% of its extra units, delivered without a swap");
        assertEq(units[2], 122.5e18, "the growing component was bought with WETH");
        assertEq(mWeth.balanceOf(address(executor)), 5e18, "sold 50, spent 22.5 on the purchase and 22.5 on delivery");
        assertEq(shrinking.balanceOf(address(r)), 50e18);
    }

    function test_XA12_rebalanceExecutorV3_takesCallbacksOnlyFromTheIndexItFills() public {
        MockERC20 mWeth = new MockERC20("Wrapped Ether", "WETH", 18);
        RebalanceExecutorV3 executor =
            new RebalanceExecutorV3(IIndexFactory(makeAddr("factory")), new MockSwapRouter(), address(mWeth));
        mWeth.mint(address(executor), 10e18); // the operator's float

        // A contract posing as an index that holds only WETH asks for the whole float.
        address fake = makeAddr("fake index");
        vm.etch(fake, hex"00");
        address[] memory onlyWeth = new address[](1);
        onlyWeth[0] = address(mWeth);
        vm.mockCall(fake, abi.encodeWithSelector(IIndexToken.componentTokens.selector), abi.encode(onlyWeth));
        uint256[] memory nothing = new uint256[](1);
        uint256[] memory everything = new uint256[](1);
        everything[0] = 10e18;
        vm.prank(fake);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutorV3.UnexpectedCaller.selector, fake));
        executor.onXindexRebalance(nothing, everything, "");
        assertEq(mWeth.balanceOf(address(executor)), 10e18, "the float stays");

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutorV3.NotOwner.selector, stranger));
        executor.setFee(address(mWeth), 3000);
    }

    /// @dev LR-04: the XA-12 check trusted whatever index `fill` was pointed at, and anyone could call `fill`. A
    ///      contract posing as an index then called back from its own `executeRebalance` and asked for the whole
    ///      float, which the executor paid. Only the deployer starts a fill now, and only on one of the factory's
    ///      indexes.
    function test_LR04_rebalanceExecutorV3_fillCannotBePointedAtAFakeIndex() public {
        MockMarket m = new MockMarket();
        IndexFactory f = new IndexFactory(address(this), address(0));
        MockERC20 mWeth = m.weth();
        RebalanceExecutorV3 executor = new RebalanceExecutorV3(f, new MockSwapRouter(), address(mWeth));
        mWeth.mint(address(executor), 10e18); // the operator's float
        FakeIndex fake = new FakeIndex(address(mWeth), address(executor));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutorV3.NotOwner.selector, stranger));
        executor.fill(IIndexToken(address(fake)));

        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutorV3.NotIndex.selector, address(fake)));
        executor.fill(IIndexToken(address(fake)));
        assertEq(mWeth.balanceOf(address(executor)), 10e18, "the float stays");

        // The fake does what the finding describes: without the two checks above, this callback emptied the float.
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutorV3.UnexpectedCaller.selector, address(fake)));
        fake.executeRebalance("");
    }
}

/// @dev Poses as an index whose only component is WETH: its `executeRebalance` calls the executor back and asks for
///      everything the executor holds.
contract FakeIndex {
    address internal immutable WETH;
    address internal immutable EXECUTOR;

    constructor(address weth, address executor) {
        WETH = weth;
        EXECUTOR = executor;
    }

    function executeRebalance(bytes calldata data) external {
        uint256[] memory nothing = new uint256[](1);
        uint256[] memory everything = new uint256[](1);
        everything[0] = MockERC20(WETH).balanceOf(EXECUTOR);
        RebalanceExecutorV3(EXECUTOR).onXindexRebalance(nothing, everything, data);
    }
}

/// @notice Covers the fork suites' feed helper offline, the way `RebalanceExecutorV3` is covered here: CI measures
///         coverage with the fork suites excluded, so a helper only they call would otherwise read as untested.
contract ForkFeedsTest is ForkFeeds {
    function test_forkFeeds_putsRealAnswersOnTheBlockClock() public {
        vm.warp(30 days);
        address[8] memory feeds = _shippedFeeds();
        for (uint256 i = 0; i < feeds.length; ++i) {
            // Stand in for the mainnet aggregators, which have no code on a local chain.
            TestAggregator stub = new TestAggregator("X / USD", 8, int256(1_000e8 + int256(i)));
            vm.etch(feeds[i], address(stub).code);
            TestAggregator(feeds[i]).setAnswer(int256(1_000e8 + int256(i)));
            TestAggregator(feeds[i]).setDecimals(8);
            TestAggregator(feeds[i]).setUpdatedAt(block.timestamp - 10 days); // long stale, as at a fork block
        }

        _pinFeedsToTheBlockClock();
        vm.warp(block.timestamp + 90 days);
        for (uint256 i = 0; i < feeds.length; ++i) {
            (, int256 answer,, uint256 updatedAt,) = TestAggregator(feeds[i]).latestRoundData();
            assertEq(answer, int256(1_000e8 + int256(i)), "the real answer is kept");
            assertEq(updatedAt, block.timestamp, "and follows the clock however far a test warps");
        }

        _movePinnedFeed(feeds[0], 3, 2);
        (, int256 moved,,,) = TestAggregator(feeds[0]).latestRoundData();
        assertEq(moved, int256(1_000e8) * 3 / 2, "a test that wants drift asks for it");
        assertEq(A.ETH_USD_FEED, feeds[0]);
    }
}
