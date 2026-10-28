// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISwapRouter02} from "./ISwapRouter02.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockUSDT} from "./MockUSDT.sol";
import {MockSwapRouter} from "./MockSwapRouter.sol";
import {MockPausableToken} from "./MockPausableToken.sol";
import {MockRouterInventory, MockUniversalRouter} from "./MockUniversalRouter.sol";
import {UniversalRouterCommands as Cmd} from "../../src/libraries/UniversalRouterCommands.sol";
import {
    PathKey,
    UniswapV4Types as V4,
    V4ExactInputParams,
    V4ExactOutputParams
} from "../../src/libraries/UniswapV4Types.sol";
import {IXindexErrors} from "../../src/interfaces/IXindexErrors.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./MockUniswapV3.sol";
import {MockWETH} from "./MockWETH.sol";
import {MockPositionManager} from "./MockPositionManager.sol";
import {INonfungiblePositionManager} from "../../script/interfaces/INonfungiblePositionManager.sol";
import {MockMarket} from "./MockMarket.sol";
import {MockPyth} from "./MockPyth.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../../src/WeightedHub.sol";
import {IIndexHub} from "../../src/interfaces/IIndexHub.sol";
import {IWeightedHub} from "../../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../../src/interfaces/IWeightedIndexFactory.sol";
import {PythStructs} from "../../src/interfaces/pyth/PythStructs.sol";
import {WeightedExecutorV3} from "../fork/WeightedExecutorV3.sol";

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

    /// @dev The fee switch as on mainnet: the sender pays the value, the recipient gets it less the fee, the owner
    ///      gets the fee, and the fee is capped at `maximumFee` whole tokens. Only the deployer can switch it.
    function test_usdt_feeSwitch() public {
        usdt.mint(alice, 100_000e6);
        vm.prank(alice);
        vm.expectRevert("USDT: owner");
        usdt.setParams(10, 5);

        usdt.setParams(10, 5); // 0.10%, at most 5 USDT
        assertEq(usdt.owner(), address(this));
        vm.prank(alice);
        usdt.transfer(bob, 1_000e6);
        assertEq(usdt.balanceOf(alice), 99_000e6, "the sender pays the value");
        assertEq(usdt.balanceOf(bob), 999e6, "the recipient gets it less 0.10%");
        assertEq(usdt.balanceOf(address(this)), 1e6, "and the owner the fee");

        vm.prank(alice);
        usdt.transfer(bob, 10_000e6);
        assertEq(usdt.balanceOf(bob), 999e6 + 9_995e6, "a fee above the cap is capped at 5 USDT");
        assertEq(usdt.maximumFee(), 5e6);
        assertEq(usdt.basisPointsRate(), 10);
    }

    /// @dev Mainnet Tether's freezes: `transfer` checks the sender only and `transferFrom` checks `from` only, so a
    ///      blacklisted address can still receive and a blacklisted caller can still move someone else's approved
    ///      tokens; a pause stops both; the owner can zero a blacklisted balance.
    function test_usdt_blacklistAndPause() public {
        address carol = makeAddr("carol");
        usdt.mint(alice, 10e6);
        usdt.mint(bob, 10e6);
        vm.prank(alice);
        usdt.approve(bob, 10e6);
        vm.startPrank(bob);
        vm.expectRevert("USDT: owner");
        usdt.addBlackList(alice);
        vm.expectRevert("USDT: owner");
        usdt.removeBlackList(alice);
        vm.expectRevert("USDT: owner");
        usdt.pause();
        vm.expectRevert("USDT: owner");
        usdt.unpause();
        vm.expectRevert("USDT: owner");
        usdt.destroyBlackFunds(alice);
        vm.stopPrank();

        usdt.addBlackList(bob);
        assertTrue(usdt.isBlackListed(bob));
        vm.prank(alice);
        usdt.transfer(bob, 1e6); // the recipient is never checked
        vm.prank(bob);
        vm.expectRevert("USDT: blacklisted");
        usdt.transfer(alice, 1);
        vm.prank(bob);
        usdt.transferFrom(alice, carol, 1e6); // nor is the caller
        vm.prank(alice);
        usdt.approve(address(this), 0);
        vm.prank(bob);
        usdt.approve(alice, 5e6);
        vm.prank(alice);
        vm.expectRevert("USDT: blacklisted");
        usdt.transferFrom(bob, alice, 1);

        vm.expectRevert("USDT: not blacklisted");
        usdt.destroyBlackFunds(alice);
        usdt.destroyBlackFunds(bob);
        assertEq(usdt.balanceOf(bob), 0, "the owner zeroed the blacklisted balance");
        assertEq(usdt.totalSupply(), 9e6, "and burned it from the supply");
        usdt.removeBlackList(bob);
        assertFalse(usdt.isBlackListed(bob));

        usdt.pause();
        assertTrue(usdt.paused());
        vm.prank(alice);
        vm.expectRevert("USDT: paused");
        usdt.transfer(bob, 1);
        vm.prank(bob);
        vm.expectRevert("USDT: paused");
        usdt.transferFrom(alice, bob, 1);
        usdt.unpause();
        vm.prank(alice);
        usdt.transfer(bob, 1);
        assertEq(usdt.balanceOf(bob), 1);
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

    /// @dev A withdrawn implementation fails every read, not only the balance a settlement checks (RT-01).
    function test_pausableToken_brokenReadsFailEveryRead() public {
        MockPausableToken p = new MockPausableToken("Pausable BTC", "pBTC", 8);
        p.mint(alice, 10);
        assertEq(p.name(), "Pausable BTC");
        assertEq(p.symbol(), "pBTC");
        assertEq(p.totalSupply(), 10);
        assertEq(p.allowance(alice, bob), 0);

        p.setReadsBroken(true);
        vm.expectRevert(bytes("reads broken"));
        p.name();
        vm.expectRevert(bytes("reads broken"));
        p.symbol();
        vm.expectRevert(bytes("reads broken"));
        p.decimals();
        vm.expectRevert(bytes("reads broken"));
        p.totalSupply();
        vm.expectRevert(bytes("reads broken"));
        p.balanceOf(alice);
        vm.expectRevert(bytes("reads broken"));
        p.allowance(alice, bob);
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
    // WeightedExecutorV3 (used by the fork tests), driven through the mock router
    // ---------------------------------------------------------------------

    function test_market_holdsWethUsdcAndTheirSupplies() public {
        MockMarket m = new MockMarket();
        assertEq(m.weth().decimals(), 18);
        assertEq(m.usdc().decimals(), 6);
        assertEq(m.supplyOf(address(m.weth())), m.ETH_SUPPLY(), "WETH is listed with ether's supply");
        assertEq(m.supplyOf(address(m.usdc())), m.DEFAULT_SUPPLY(), "anything else with the default");
    }

    function test_weightedExecutorV3_sellsBuysAndSettlesThroughARouter() public {
        MockPyth pyth = new MockPyth();
        WeightedIndexFactory f = new WeightedIndexFactory(address(this), address(0), address(pyth));
        MockERC20 shrinking = new MockERC20("Shrinking", "SHR", 18);
        MockERC20 growing = new MockERC20("Growing", "GRO", 18);
        address[2] memory t = [address(shrinking), address(growing)];
        for (uint256 i = 0; i < 2; ++i) {
            f.proposeListing(t[i], keccak256(abi.encode(t[i])));
        }
        vm.warp(block.timestamp + f.LISTING_DELAY());
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        for (uint256 i = 0; i < 2; ++i) {
            f.executeListing(t[i]);
            specs[i] = IWeightedIndexFactory.ComponentSpec({token: t[i], weight: 5000, units: 100e18});
        }
        WeightedHub idx = WeightedHub(
            f.createIndex(
                "Executor",
                "EXEC",
                specs,
                IWeightedIndexFactory.IndexParams({
                    creatorFeeBps: 0,
                    creatorStreamingBps: 0,
                    maxPlatformFeeBps: 25,
                    maxPlatformStreamingBps: 100,
                    rebalanceInterval: 7 days,
                    gated: false,
                    listed: true
                })
            )
        );
        shrinking.mint(address(this), 100e18);
        growing.mint(address(this), 100e18);
        shrinking.approve(address(idx), 100e18);
        growing.approve(address(idx), 100e18);
        idx.issue(1e18, address(this));

        // The shrinking component trades at $2 and the growing one at $1: half and half by weight, a fill sells the
        // first and buys the second.
        router.setPrice(address(shrinking), 2e18);
        router.setPrice(address(growing), 1e18);
        growing.mint(address(router), 1_000e18);
        WeightedExecutorV3 executor = new WeightedExecutorV3(router, address(usdc));
        executor.setRoute(address(shrinking), _path(address(shrinking), address(usdc)));
        executor.setRoute(address(growing), _path(address(growing), address(usdc)));
        assertEq(executor.routeOf(address(growing)), _path(address(growing), address(usdc)));
        usdc.mint(address(executor), 100e6); // a float for what the fill does not pay for itself

        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        idx.startRebalance(0, pyth.liveUpdates(idx, 0));
        (uint256 eta,) = idx.pendingRebalance();
        vm.warp(eta + idx.AUCTION_DURATION() / 2);
        uint64 time = uint64(idx.priceTime());
        bytes[] memory updates = new bytes[](2);
        updates[0] = pyth.update(keccak256(abi.encode(t[0])), 2e8, 0, -8, time, time - 1);
        updates[1] = pyth.update(keccak256(abi.encode(t[1])), 1e8, 0, -8, time, time - 1);
        PythStructs.Price[] memory prices = new PythStructs.Price[](2);
        prices[0] = PythStructs.Price({price: 2e8, conf: 0, expo: -8, publishTime: time});
        prices[1] = PythStructs.Price({price: 1e8, conf: 0, expo: -8, publishTime: time});
        (, uint256[] memory next, uint256[] memory amountsOut, uint256[] memory amountsIn) =
            idx.previewRebalance(prices);
        executor.fill(idx, updates);

        (, uint256[] memory units) = idx.components();
        assertEq(units, next, "the settlement is the preview's");
        assertLt(units[0], 100e18, "the component worth more than its weight shrank");
        assertGt(units[1], 100e18, "the one worth less was bought with USDC");
        assertEq(shrinking.balanceOf(address(router)), amountsOut[0], "what the index sent was sold through the router");
        assertEq(growing.balanceOf(address(idx)), 100e18 + amountsIn[1], "and what it asked for was delivered");
    }

    function test_XA12_weightedExecutorV3_takesCallbacksOnlyFromTheIndexItFills() public {
        WeightedExecutorV3 executor = new WeightedExecutorV3(router, address(usdc));
        usdc.mint(address(executor), 10_000e6); // the operator's float
        executor.setRoute(address(weth), _path(address(weth), address(usdc)));

        // A contract posing as an index that holds only WETH asks for as much as the whole float buys.
        address fake = makeAddr("fake index");
        vm.etch(fake, hex"00");
        address[] memory onlyWeth = new address[](1);
        onlyWeth[0] = address(weth);
        vm.mockCall(fake, abi.encodeWithSelector(IIndexHub.componentTokens.selector), abi.encode(onlyWeth));
        uint256[] memory nothing = new uint256[](1);
        uint256[] memory everything = new uint256[](1);
        everything[0] = 3e18;
        vm.prank(fake);
        vm.expectRevert(abi.encodeWithSelector(WeightedExecutorV3.UnexpectedCaller.selector, fake));
        executor.onXindexRebalance(nothing, everything, "");
        assertEq(usdc.balanceOf(address(executor)), 10_000e6, "the float stays");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(WeightedExecutorV3.NotOwner.selector, bob));
        executor.setRoute(address(weth), _path(address(weth), address(usdc)));
    }

    /// @dev LR-04: the XA-12 check trusted whatever index `fill` was pointed at, and anyone could call `fill`. A
    ///      contract posing as an index then called back from its own `executeRebalance` and asked for the whole
    ///      float, which the executor paid. Only the deployer starts a fill now, and a callback outside one is refused.
    function test_LR04_weightedExecutorV3_fillCannotBePointedAtAFakeIndex() public {
        WeightedExecutorV3 executor = new WeightedExecutorV3(router, address(usdc));
        usdc.mint(address(executor), 10_000e6); // the operator's float
        FakeIndex fake = new FakeIndex(address(usdc), address(executor));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(WeightedExecutorV3.NotOwner.selector, bob));
        executor.fill(IWeightedHub(address(fake)), new bytes[](0));
        assertEq(usdc.balanceOf(address(executor)), 10_000e6, "the float stays");

        // The fake does what the finding describes: without the checks above, this callback emptied the float.
        vm.expectRevert(abi.encodeWithSelector(WeightedExecutorV3.UnexpectedCaller.selector, address(fake)));
        fake.executeRebalance("", new bytes[](0));
    }

    // ---------------------------------------------------------------------
    // the router interface against Uniswap's own
    // ---------------------------------------------------------------------

    /// @dev `ISwapRouter02` is a hand-written subset of Uniswap's `IV3SwapRouter`. The zap no longer uses it -- it
    ///      swaps through the Universal Router -- so what encodes against it now is `test/fork/WeightedExecutorV3`,
    ///      the fixture that fills auctions through the real SwapRouter02 at
    ///      0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45. A field reordered or retyped here would still compile and
    ///      still pass every other local test, because `MockSwapRouter` is written against the same declaration, and
    ///      the fork suite that would catch it needs an RPC. The pin is cheap and keeps the fixture honest offline
    ///      (VR-06).
    ///
    ///      A selector is not enough on its own: it covers the tuple's types, so swapping `amountIn` with
    ///      `amountOutMinimum` -- both `uint256` -- leaves it unchanged while inverting what the router is told. The
    ///      whole calldata is pinned instead, built from values that distinguish every field, against the bytes
    ///      `cast calldata` produces for Uniswap's own signature. Canonical source: Uniswap/swap-router-contracts,
    ///      contracts/interfaces/IV3SwapRouter.sol.
    function test_routerCalldataMatchesUniswaps() public pure {
        bytes memory input = abi.encodeCall(
            ISwapRouter02.exactInput,
            ISwapRouter02.ExactInputParams({
                path: hex"aabb", recipient: address(0xaA), amountIn: 111, amountOutMinimum: 222
            })
        );
        // cast calldata "exactInput((bytes,address,uint256,uint256))" "(0xaabb,0x...aa,111,222)"
        assertEq(
            input,
            hex"b858183f" hex"0000000000000000000000000000000000000000000000000000000000000020"
            hex"0000000000000000000000000000000000000000000000000000000000000080"
            hex"00000000000000000000000000000000000000000000000000000000000000aa"
            hex"000000000000000000000000000000000000000000000000000000000000006f"
            hex"00000000000000000000000000000000000000000000000000000000000000de"
            hex"0000000000000000000000000000000000000000000000000000000000000002"
            hex"aabb000000000000000000000000000000000000000000000000000000000000",
            "exactInput encodes differently from Uniswap's IV3SwapRouter"
        );

        bytes memory output = abi.encodeCall(
            ISwapRouter02.exactOutput,
            ISwapRouter02.ExactOutputParams({
                path: hex"ccdd", recipient: address(0xbB), amountOut: 333, amountInMaximum: 444
            })
        );
        // cast calldata "exactOutput((bytes,address,uint256,uint256))" "(0xccdd,0x...bb,333,444)"
        assertEq(
            output,
            hex"09b81346" hex"0000000000000000000000000000000000000000000000000000000000000020"
            hex"0000000000000000000000000000000000000000000000000000000000000080"
            hex"00000000000000000000000000000000000000000000000000000000000000bb"
            hex"000000000000000000000000000000000000000000000000000000000000014d"
            hex"00000000000000000000000000000000000000000000000000000000000001bc"
            hex"0000000000000000000000000000000000000000000000000000000000000002"
            hex"ccdd000000000000000000000000000000000000000000000000000000000000",
            "exactOutput encodes differently from Uniswap's IV3SwapRouter"
        );
    }
}

/// @dev Poses as an index whose only component is the executor's float token: its `executeRebalance` calls the
///      executor back and asks for everything the executor holds.
contract FakeIndex {
    address internal immutable FLOAT;
    address internal immutable EXECUTOR;

    constructor(address float, address executor) {
        FLOAT = float;
        EXECUTOR = executor;
    }

    function executeRebalance(bytes calldata data, bytes[] calldata) external {
        uint256[] memory nothing = new uint256[](1);
        uint256[] memory everything = new uint256[](1);
        everything[0] = MockERC20(FLOAT).balanceOf(EXECUTOR);
        WeightedExecutorV3(EXECUTOR).onXindexRebalance(nothing, everything, data);
    }
}
