// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../../src/WeightedHub.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {NoEtherCaller} from "../mocks/NoEtherCaller.sol";
import {IPancakeUniversalRouter} from "../../src/interfaces/IPancakeUniversalRouter.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IWeightedIndexFactory} from "../../src/interfaces/IWeightedIndexFactory.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";

interface IQuoterV2 {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );

    function quoteExactOutput(bytes memory path, uint256 amountOut)
        external
        returns (
            uint256 amountIn,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

interface IPancakeRouterAdmin {
    function owner() external view returns (address);
    function pause() external;
}

/// @notice End-to-end against the real Universal Router, real V3 and V4 pools, PancakeSwap's real router and V3 pools,
///         USDC and USDT. Skips when MAINNET_RPC_URL is unset. Run: MAINNET_RPC_URL=... forge test --match-path
///         'test/fork/*' -vvv
contract IndexZapForkTest is Test {
    using SafeERC20 for IERC20;

    WeightedIndexFactory factory;
    IndexZap zap;
    WeightedHub index;
    IQuoterV2 quoter = IQuoterV2(A.QUOTER_V2);

    address alice = makeAddr("alice");

    // 0.001 WBTC + 0.01 WETH + 1 LINK per index token
    uint256 constant U_WBTC = 100_000;
    uint256 constant U_WETH = 1e16;
    uint256 constant U_LINK = 1e18;

    uint24 constant F500 = 500;
    uint24 constant F3000 = 3000;

    /// @dev Native ether, which is how a V4 pool names it. Every live V4 pool for these components is paired against
    ///      it rather than WETH, so a V4 route reaches LINK through `address(0)`. It never reaches the zap, which has
    ///      no `receive()`: the router settles the middle of the route inside the PoolManager.
    address constant NATIVE = address(0);

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        // FORK_BLOCK overrides the pin, for a non-archive RPC that only serves recent state. Forge loads .env
        // automatically, so a MAINNET_RPC_URL set there makes a plain `forge test` run these suites too.
        uint256 forkBlock = vm.envOr("FORK_BLOCK", A.FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "MAINNET_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/fork/*'"
                )
            );
        }

        factory = new WeightedIndexFactory(address(this), address(0), A.PYTH);
        zap = new IndexZap(
            IIndexFactory(address(factory)),
            IUniversalRouter(A.UNIVERSAL_ROUTER),
            IPancakeUniversalRouter(A.PANCAKE_UNIVERSAL_ROUTER)
        );

        // The zap never asks for a price, so each token is listed under a price id of its own making.
        factory.proposeListing(A.WBTC, keccak256(abi.encode(A.WBTC)));
        factory.proposeListing(A.WETH, keccak256(abi.encode(A.WETH)));
        factory.proposeListing(A.LINK, keccak256(abi.encode(A.LINK)));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(A.WBTC);
        factory.executeListing(A.WETH);
        factory.executeListing(A.LINK);

        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](3);
        specs[0] = IWeightedIndexFactory.ComponentSpec({token: A.WBTC, weight: 3334, units: U_WBTC});
        specs[1] = IWeightedIndexFactory.ComponentSpec({token: A.WETH, weight: 3333, units: U_WETH});
        specs[2] = IWeightedIndexFactory.ComponentSpec({token: A.LINK, weight: 3333, units: U_LINK});
        index = WeightedHub(factory.createIndex("Blue Chip", "BLUE", specs));
    }

    // ---------------------------------------------------------------------
    // paths and params (stable <-> component via WETH)
    // ---------------------------------------------------------------------

    /// @dev exact-output paths for minting: component ... stable (reversed encoding)
    function _mintPaths(address stable) internal pure returns (bytes[] memory p) {
        p = new bytes[](3);
        p[0] = abi.encodePacked(A.WBTC, F500, A.WETH, F500, stable);
        p[1] = abi.encodePacked(A.WETH, F500, stable);
        p[2] = abi.encodePacked(A.LINK, F3000, A.WETH, F500, stable);
    }

    /// @dev exact-input paths for burning: component ... tokenOut
    function _burnPaths(address tokenOut) internal pure returns (bytes[] memory p) {
        p = new bytes[](3);
        p[0] = abi.encodePacked(A.WBTC, F500, A.WETH, F500, tokenOut);
        p[1] = abi.encodePacked(A.WETH, F500, tokenOut);
        p[2] = abi.encodePacked(A.LINK, F3000, A.WETH, F500, tokenOut);
    }

    /// @dev USDC -> native ether -> LINK on Uniswap V4, for an exact-output mint. The router walks an exact-output
    ///      route backwards from the component, so the first entry names what the user pays with, and each entry
    ///      carries the pool of the hop it closes: {USDC, 0.05%} is the ETH/USDC pool and {ether, 0.3%} the ETH/LINK
    ///      one. Getting either the order or the pairing wrong is what `BadRoute` and a failed swap catch.
    function _v4MintPathLink() internal pure returns (PathKey[] memory path) {
        path = new PathKey[](2);
        path[0] = PathKey({intermediateCurrency: A.USDC, fee: F500, tickSpacing: 10, hooks: address(0), hookData: ""});
        path[1] = PathKey({intermediateCurrency: NATIVE, fee: F3000, tickSpacing: 60, hooks: address(0), hookData: ""});
    }

    /// @dev The same route for a burn, which the router walks forwards from the component: the same list reversed.
    function _v4BurnPathLink() internal pure returns (PathKey[] memory path) {
        path = new PathKey[](2);
        path[0] = PathKey({intermediateCurrency: NATIVE, fee: F3000, tickSpacing: 60, hooks: address(0), hookData: ""});
        path[1] = PathKey({intermediateCurrency: A.USDC, fee: F500, tickSpacing: 10, hooks: address(0), hookData: ""});
    }

    /// @dev The basket as an app would route it today: WBTC and WETH are deeper on V3, LINK on V4. Only LINK has a
    ///      V4 pool worth using here, and it is native-ether-paired, which is why the route crosses `address(0)`.
    function _mixedMintLegs() internal pure returns (IIndexZap.MintLeg[] memory legs) {
        bytes[] memory p = _mintPaths(A.USDC);
        legs = new IIndexZap.MintLeg[](3);
        legs[0] = IIndexZap.MintLeg({v3Path: p[0], v4Path: new PathKey[](0), pancakePath: "", maxAmountIn: 0});
        legs[1] = IIndexZap.MintLeg({v3Path: p[1], v4Path: new PathKey[](0), pancakePath: "", maxAmountIn: 0});
        legs[2] = IIndexZap.MintLeg({v3Path: "", v4Path: _v4MintPathLink(), pancakePath: "", maxAmountIn: 0});
    }

    function _mixedBurnLegs() internal pure returns (IIndexZap.BurnLeg[] memory legs) {
        bytes[] memory p = _burnPaths(A.USDC);
        legs = new IIndexZap.BurnLeg[](3);
        legs[0] = IIndexZap.BurnLeg({v3Path: p[0], v4Path: new PathKey[](0), pancakePath: "", minAmountOut: 0});
        legs[1] = IIndexZap.BurnLeg({v3Path: p[1], v4Path: new PathKey[](0), pancakePath: "", minAmountOut: 0});
        legs[2] = IIndexZap.BurnLeg({v3Path: "", v4Path: _v4BurnPathLink(), pancakePath: "", minAmountOut: 0});
    }

    function _mintLegs(bytes[] memory paths) internal pure returns (IIndexZap.MintLeg[] memory legs) {
        legs = new IIndexZap.MintLeg[](paths.length);
        for (uint256 i = 0; i < paths.length; ++i) {
            legs[i] = IIndexZap.MintLeg({v3Path: paths[i], v4Path: new PathKey[](0), pancakePath: "", maxAmountIn: 0});
        }
    }

    function _burnLegs(bytes[] memory paths) internal pure returns (IIndexZap.BurnLeg[] memory legs) {
        legs = new IIndexZap.BurnLeg[](paths.length);
        for (uint256 i = 0; i < paths.length; ++i) {
            legs[i] = IIndexZap.BurnLeg({v3Path: paths[i], v4Path: new PathKey[](0), pancakePath: "", minAmountOut: 0});
        }
    }

    function _mintCall(WeightedHub idx, address tokenIn, uint256 maxIn, uint256 shares, IIndexZap.MintLeg[] memory legs)
        internal
        returns (uint256)
    {
        return zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(idx),
                expectedNonce: 0, // these indexes never rebalance; reading the nonce here would consume vm.expectRevert
                tokenIn: tokenIn,
                maxAmountIn: maxIn,
                shares: shares,
                legs: legs,
                to: alice,
                deadline: block.timestamp
            })
        );
    }

    function _burnCall(
        WeightedHub idx,
        uint256 shares,
        address tokenOut,
        uint256 minOut,
        IIndexZap.BurnLeg[] memory legs
    ) internal returns (uint256) {
        return zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(idx),
                expectedNonce: 0, // these indexes never rebalance; reading the nonce here would consume vm.expectRevert
                shares: shares,
                tokenOut: tokenOut,
                minAmountOut: minOut,
                legs: legs,
                to: alice,
                deadline: block.timestamp
            })
        );
    }

    /// @dev What the frontend does: sum QuoterV2 exact-output quotes for each leg.
    function _quoteMint(address stable, uint256 shares) internal returns (uint256 total) {
        uint256[] memory need = index.previewIssue(shares);
        bytes[] memory p = _mintPaths(stable);
        for (uint256 i = 0; i < 3; ++i) {
            (uint256 amountIn,,,) = quoter.quoteExactOutput(p[i], need[i]);
            total += amountIn;
        }
    }

    function _quoteBurn(address tokenOut, uint256 shares) internal returns (uint256 total) {
        uint256[] memory got = index.previewRedeem(shares);
        bytes[] memory p = _burnPaths(tokenOut);
        for (uint256 i = 0; i < 3; ++i) {
            if (got[i] == 0) continue;
            (uint256 amountOut,,,) = quoter.quoteExactInput(p[i], got[i]);
            total += amountOut;
        }
    }

    function _mint(address stable, uint256 shares, uint256 slippageBps)
        internal
        returns (uint256 quote, uint256 spent)
    {
        quote = _quoteMint(stable, shares);
        uint256 maxIn = quote + quote * slippageBps / 10_000;
        deal(stable, alice, maxIn);
        vm.startPrank(alice);
        IERC20(stable).forceApprove(address(zap), maxIn); // USDT returns no bool
        spent = _mintCall(index, stable, maxIn, shares, _mintLegs(_mintPaths(stable)));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // tests
    // ---------------------------------------------------------------------

    function testFork_mintWithUSDC() public {
        (uint256 quote, uint256 spent) = _mint(A.USDC, 1e18, 100);

        assertEq(index.balanceOf(alice), 1e18);
        assertEq(IERC20(A.WBTC).balanceOf(address(index)), U_WBTC);
        assertEq(IERC20(A.WETH).balanceOf(address(index)), U_WETH);
        assertEq(IERC20(A.LINK).balanceOf(address(index)), U_LINK);

        assertApproxEqRel(spent, quote, 1e14, "spend vs quote"); // 0.01%
        assertEq(IERC20(A.USDC).balanceOf(alice), quote + quote / 100 - spent, "refund");
        assertEq(IERC20(A.USDC).balanceOf(address(zap)), 0);
        assertEq(IERC20(A.WBTC).balanceOf(address(zap)), 0);
        assertEq(IERC20(A.WETH).balanceOf(address(zap)), 0);
        assertEq(IERC20(A.LINK).balanceOf(address(zap)), 0);
        assertEq(IERC20(A.USDC).allowance(address(zap), A.UNIVERSAL_ROUTER), 0, "the zap approves the router nothing");

        assertGt(spent, 100e6);
        assertLt(spent, 10_000e6);
    }

    function testFork_mintWithUSDT() public {
        (uint256 quote, uint256 spent) = _mint(A.USDT, 3e18, 100);
        assertEq(index.balanceOf(alice), 3e18);
        assertApproxEqRel(spent, quote, 1e14);
        assertEq(IERC20(A.USDT).balanceOf(address(zap)), 0);

        (, uint256 spent2) = _mint(A.USDT, 1e18, 100);
        assertGt(spent2, 0);
        assertEq(index.balanceOf(alice), 4e18);
    }

    function testFork_mintRevertsWhenQuoteExceeded() public {
        uint256 quote = _quoteMint(A.USDC, 1e18);
        uint256 maxIn = quote - quote / 100; // 1% under the quote
        deal(A.USDC, alice, maxIn);
        vm.startPrank(alice);
        IERC20(A.USDC).approve(address(zap), maxIn);
        // The zap pre-funds the router with what the leg may spend, so a leg that needs more than its cap trips the
        // pool's own slippage check. It bubbles unchanged: the router dispatches swaps as internal calls and wraps
        // only the ones it makes with a low-level call.
        vm.expectRevert(abi.encodeWithSignature("V3TooMuchRequested()"));
        _mintCall(index, A.USDC, maxIn, 1e18, _mintLegs(_mintPaths(A.USDC)));
        vm.stopPrank();
        assertEq(IERC20(A.USDC).balanceOf(alice), maxIn);
        assertEq(index.balanceOf(alice), 0);
    }

    /// @dev The V4 half of the zap against the real PoolManager. Its flash accounting is what a mock cannot stand in
    ///      for: an action that left a delta unsettled reverts inside `unlock`, so arriving here at all is the proof
    ///      that the leg settled and took exactly what it moved.
    function testFork_mintWithUSDC_linkLegThroughV4() public {
        uint256 shares = 1e18;
        uint256 v3Quote = _quoteMint(A.USDC, shares);
        uint256 maxIn = v3Quote + v3Quote / 10; // the LINK leg fills at V4's price, not the quoted V3 one
        deal(A.USDC, alice, maxIn);
        uint256 routerBefore = IERC20(A.USDC).balanceOf(A.UNIVERSAL_ROUTER);
        // Forge seeds a freshly created address with a wei, so what the call must leave untouched is the delta.
        uint256 zapEthBefore = address(zap).balance;

        vm.startPrank(alice);
        IERC20(A.USDC).approve(address(zap), maxIn);
        uint256 spent = _mintCall(index, A.USDC, maxIn, shares, _mixedMintLegs());
        vm.stopPrank();

        assertEq(index.balanceOf(alice), shares);
        assertEq(IERC20(A.LINK).balanceOf(address(index)), U_LINK, "the V4 leg delivered the whole component");
        assertEq(IERC20(A.WBTC).balanceOf(address(index)), U_WBTC);
        assertEq(IERC20(A.WETH).balanceOf(address(index)), U_WETH);

        assertEq(IERC20(A.USDC).balanceOf(address(zap)), 0, "the zap keeps no input");
        assertEq(IERC20(A.LINK).balanceOf(address(zap)), 0, "the zap keeps no component");
        assertEq(address(zap).balance, zapEthBefore, "native ether never reaches the zap");
        assertEq(IERC20(A.USDC).balanceOf(A.UNIVERSAL_ROUTER), routerBefore, "the sweep left the router as it was");
        assertEq(IERC20(A.USDC).balanceOf(alice), maxIn - spent, "refund");
        assertApproxEqRel(spent, v3Quote, 5e16, "the V4 route prices within 5% of the V3 one");
    }

    function testFork_burnToUSDC_linkLegThroughV4() public {
        _mint(A.USDC, 2e18, 100);
        uint256 routerBefore = IERC20(A.LINK).balanceOf(A.UNIVERSAL_ROUTER);
        uint256 before = IERC20(A.USDC).balanceOf(alice);
        uint256 zapEthBefore = address(zap).balance;

        vm.startPrank(alice);
        index.approve(address(zap), 2e18);
        uint256 out = _burnCall(index, 2e18, A.USDC, 1, _mixedBurnLegs());
        vm.stopPrank();

        assertEq(index.totalSupply(), 0);
        assertEq(IERC20(A.USDC).balanceOf(alice), before + out, "the payout is what the call reported");
        assertEq(IERC20(A.LINK).balanceOf(address(index)), 0, "the V4 leg sold the whole component");
        assertEq(IERC20(A.LINK).balanceOf(address(zap)), 0, "no component stayed in the zap");
        assertEq(IERC20(A.USDC).balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, zapEthBefore, "the middle of the route never leaves the PoolManager");
        assertEq(IERC20(A.LINK).balanceOf(A.UNIVERSAL_ROUTER), routerBefore, "the sweep left the router as it was");
        assertGt(out, 0);
    }

    /// @dev The V4 router enforces `amountInMaximum` itself, and the failure reaches the caller unwrapped for the same
    ///      reason a V3 one does: the Universal Router dispatches `V4_SWAP` as an internal call.
    function testFork_v4LegRevertsWhenItsCapIsTooLow() public {
        uint256 v3Quote = _quoteMint(A.USDC, 1e18);
        deal(A.USDC, alice, v3Quote * 2);
        IIndexZap.MintLeg[] memory legs = _mixedMintLegs();
        legs[2].maxAmountIn = 1e6; // a dollar, far under what one LINK costs

        vm.startPrank(alice);
        IERC20(A.USDC).approve(address(zap), v3Quote * 2);
        vm.expectPartialRevert(bytes4(keccak256("V4TooMuchRequested(uint256,uint256)")));
        _mintCall(index, A.USDC, v3Quote * 2, 1e18, legs);
        vm.stopPrank();

        assertEq(index.balanceOf(alice), 0);
        assertEq(IERC20(A.USDC).balanceOf(alice), v3Quote * 2, "nothing was spent");
    }

    function testFork_mintAndBurnWithPerLegLimits() public {
        uint256[] memory need = index.previewIssue(1e18);
        bytes[] memory mintPaths = _mintPaths(A.USDC);
        IIndexZap.MintLeg[] memory mintLegs = new IIndexZap.MintLeg[](3);
        uint256 total;
        for (uint256 i = 0; i < 3; ++i) {
            (uint256 legQuote,,,) = quoter.quoteExactOutput(mintPaths[i], need[i]);
            mintLegs[i] = IIndexZap.MintLeg({
                v3Path: mintPaths[i], v4Path: new PathKey[](0), pancakePath: "", maxAmountIn: legQuote + legQuote / 200
            });
            total += legQuote;
        }
        uint256 maxIn = total + total / 100;
        deal(A.USDC, alice, maxIn);
        vm.startPrank(alice);
        IERC20(A.USDC).approve(address(zap), maxIn);
        uint256 spent = _mintCall(index, A.USDC, maxIn, 1e18, mintLegs);
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18);

        uint256[] memory got = index.previewRedeem(1e18);
        bytes[] memory burnPaths = _burnPaths(A.USDC);
        IIndexZap.BurnLeg[] memory burnLegs = new IIndexZap.BurnLeg[](3);
        uint256 quoteOut;
        for (uint256 i = 0; i < 3; ++i) {
            (uint256 legOut,,,) = quoter.quoteExactInput(burnPaths[i], got[i]);
            burnLegs[i] = IIndexZap.BurnLeg({
                v3Path: burnPaths[i], v4Path: new PathKey[](0), pancakePath: "", minAmountOut: legOut - legOut / 200
            });
            quoteOut += legOut;
        }
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        uint256 out = _burnCall(index, 1e18, A.USDC, quoteOut - quoteOut / 100, burnLegs);
        vm.stopPrank();
        assertGt(out, spent - spent / 50);
    }

    function testFork_burnToUSDT() public {
        (, uint256 spent) = _mint(A.USDC, 2e18, 100);

        uint256 quote = _quoteBurn(A.USDT, 2e18);
        vm.startPrank(alice);
        index.approve(address(zap), 2e18);
        uint256 out = _burnCall(index, 2e18, A.USDT, quote - quote / 100, _burnLegs(_burnPaths(A.USDT)));
        vm.stopPrank();

        assertApproxEqRel(out, quote, 1e14);
        assertEq(IERC20(A.USDT).balanceOf(alice), out);
        assertEq(index.totalSupply(), 0);
        assertEq(IERC20(A.WBTC).balanceOf(address(index)), 0);
        assertEq(IERC20(A.USDT).balanceOf(address(zap)), 0);
        assertGt(out, spent - spent / 50);
    }

    function testFork_burnToWBTC() public {
        _mint(A.USDC, 1e18, 100);

        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](3);
        legs[0] = IIndexZap.BurnLeg({v3Path: "", v4Path: new PathKey[](0), pancakePath: "", minAmountOut: 0}); // WBTC is the payout token
        legs[1] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.WBTC), v4Path: new PathKey[](0), pancakePath: "", minAmountOut: 0
        });
        legs[2] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.LINK, F3000, A.WETH, F500, A.WBTC),
            v4Path: new PathKey[](0),
            pancakePath: "",
            minAmountOut: 0
        });

        (uint256 wethOut,,,) = quoter.quoteExactInput(legs[1].v3Path, U_WETH);
        (uint256 linkOut,,,) = quoter.quoteExactInput(legs[2].v3Path, U_LINK);
        uint256 quote = U_WBTC + wethOut + linkOut;

        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        uint256 out = _burnCall(index, 1e18, A.WBTC, quote - quote / 100, legs);
        vm.stopPrank();

        assertApproxEqRel(out, quote, 1e14);
        assertEq(IERC20(A.WBTC).balanceOf(alice), out);
        assertGt(out, U_WBTC);
    }

    function testFork_burnRevertsBelowMinOut() public {
        _mint(A.USDC, 1e18, 100);
        // Legs share the WETH/USDC pool, so the real total lands a few units under the summed quotes.
        uint256 quote = _quoteBurn(A.USDC, 1e18);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectPartialRevert(IIndexZap.InsufficientOutput.selector);
        _burnCall(index, 1e18, A.USDC, quote + 1, _burnLegs(_burnPaths(A.USDC)));
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18);
    }

    /// @dev tBTC has no deep direct stable pool; it routes stable -> WETH (0.05%) -> tBTC (0.3%).
    function testFork_btcBasketWithTBTC_mintAndBurn() public {
        address[] memory t = new address[](2);
        t[0] = A.WBTC;
        t[1] = A.TBTC;

        // tBTC is on no list; it is listed here to exercise a two-hop route. The basket holds 0.0005 of each: 50,000
        // raw units of WBTC (8 decimals) and 5e14 of tBTC (18).
        factory.proposeListing(A.TBTC, keccak256(abi.encode(A.TBTC)));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(A.TBTC);

        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = IWeightedIndexFactory.ComponentSpec({token: t[0], weight: 5000, units: 50_000});
        specs[1] = IWeightedIndexFactory.ComponentSpec({token: t[1], weight: 5000, units: 5e14});
        WeightedHub btc = WeightedHub(factory.createIndex("BTC Basket", "BTC2", specs));

        bytes[] memory mintPaths = new bytes[](2);
        mintPaths[0] = abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDC);
        mintPaths[1] = abi.encodePacked(A.TBTC, F3000, A.WETH, F500, A.USDC);
        uint256[] memory need = btc.previewIssue(1e18);
        (uint256 wbtcLeg,,,) = quoter.quoteExactOutput(mintPaths[0], need[0]);
        (uint256 tbtcLeg,,,) = quoter.quoteExactOutput(mintPaths[1], need[1]);
        uint256 quote = wbtcLeg + tbtcLeg;
        assertApproxEqRel(tbtcLeg, wbtcLeg, 5e16); // tBTC tracks BTC within 5%

        uint256 maxIn = quote + quote / 100;
        deal(A.USDC, alice, maxIn);
        vm.startPrank(alice);
        IERC20(A.USDC).forceApprove(address(zap), maxIn);
        uint256 spent = _mintCall(btc, A.USDC, maxIn, 1e18, _mintLegs(mintPaths));
        vm.stopPrank();

        assertEq(btc.balanceOf(alice), 1e18);
        assertEq(IERC20(A.WBTC).balanceOf(address(btc)), 50_000);
        assertEq(IERC20(A.TBTC).balanceOf(address(btc)), 5e14);
        assertApproxEqRel(spent, quote, 1e14);
        assertGt(spent, 20e6);
        assertLt(spent, 500e6);

        bytes[] memory burnPaths = new bytes[](2);
        burnPaths[0] = abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDC);
        burnPaths[1] = abi.encodePacked(A.TBTC, F3000, A.WETH, F500, A.USDC);
        vm.startPrank(alice);
        btc.approve(address(zap), 1e18);
        uint256 out = _burnCall(btc, 1e18, A.USDC, spent - spent / 20, _burnLegs(burnPaths));
        vm.stopPrank();
        assertGt(out, spent - spent / 20);
        assertEq(btc.totalSupply(), 0);
    }

    // ---------------------------------------------------------------------
    // PancakeSwap legs (the owner's call on 2026-10-06; design/2026-10-06-swap-venues.md)
    // ---------------------------------------------------------------------

    uint24 constant P100 = 100;
    uint24 constant P2500 = 2500;

    /// @dev WETH and CAKE, a dollar or two of each a token; CAKE is listed here under a price id of its own making.
    function _cakeIndex() internal returns (WeightedHub cakeIndex) {
        factory.proposeListing(A.CAKE, keccak256(abi.encode(A.CAKE)));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(A.CAKE);
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = IWeightedIndexFactory.ComponentSpec({token: A.WETH, weight: 5000, units: 1e15});
        specs[1] = IWeightedIndexFactory.ComponentSpec({token: A.CAKE, weight: 5000, units: 2e18});
        cakeIndex = WeightedHub(factory.createIndex("Cake and Ether", "CAKEETH", specs));
    }

    /// @dev CAKE through PancakeSwap (CAKE/WETH 0.25%, WETH/USDC 0.01%), WETH through Uniswap V3: one mint, both
    ///      routers, each pre-funded and swept clean.
    function _cakeMintLegs() internal pure returns (IIndexZap.MintLeg[] memory legs) {
        legs = new IIndexZap.MintLeg[](2);
        legs[0] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDC), v4Path: new PathKey[](0), pancakePath: "", maxAmountIn: 0
        });
        legs[1] = IIndexZap.MintLeg({
            v3Path: "",
            v4Path: new PathKey[](0),
            pancakePath: abi.encodePacked(A.CAKE, P2500, A.WETH, P100, A.USDC),
            maxAmountIn: 0
        });
    }

    function _cakeBurnLegs() internal pure returns (IIndexZap.BurnLeg[] memory legs) {
        legs = new IIndexZap.BurnLeg[](2);
        legs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDC), v4Path: new PathKey[](0), pancakePath: "", minAmountOut: 0
        });
        legs[1] = IIndexZap.BurnLeg({
            v3Path: "",
            v4Path: new PathKey[](0),
            pancakePath: abi.encodePacked(A.CAKE, P2500, A.WETH, P100, A.USDC),
            minAmountOut: 0
        });
    }

    /// @dev What the app does: Uniswap's QuoterV2 for the Uniswap leg, PancakeSwap's for the PancakeSwap leg.
    function _quoteCakeMint(WeightedHub cakeIndex, uint256 shares) internal returns (uint256 total) {
        uint256[] memory need = cakeIndex.previewIssue(shares);
        IIndexZap.MintLeg[] memory legs = _cakeMintLegs();
        (uint256 wethLeg,,,) = quoter.quoteExactOutput(legs[0].v3Path, need[0]);
        (uint256 cakeLeg,,,) = IQuoterV2(A.PANCAKE_QUOTER_V2).quoteExactOutput(legs[1].pancakePath, need[1]);
        total = wethLeg + cakeLeg;
    }

    function _mintCake(WeightedHub cakeIndex, uint256 shares) internal returns (uint256 quote, uint256 spent) {
        quote = _quoteCakeMint(cakeIndex, shares);
        uint256 maxIn = quote + quote / 100;
        deal(A.USDC, alice, maxIn);
        vm.startPrank(alice);
        IERC20(A.USDC).forceApprove(address(zap), maxIn);
        spent = _mintCall(cakeIndex, A.USDC, maxIn, shares, _cakeMintLegs());
        vm.stopPrank();
    }

    function testFork_pancake_mintAndBurnCake() public {
        WeightedHub cakeIndex = _cakeIndex();
        // USDC left in PancakeSwap's router by others (16,968 units on 2026-10-10): the sweep hands it back to the
        // zap, which counts it as unsold input (CR-L02), so the mint costs that much less than the quoters say.
        uint256 stray = IERC20(A.USDC).balanceOf(A.PANCAKE_UNIVERSAL_ROUTER);
        (uint256 quote, uint256 spent) = _mintCake(cakeIndex, 1e18);
        assertEq(cakeIndex.balanceOf(alice), 1e18);
        assertEq(IERC20(A.CAKE).balanceOf(address(cakeIndex)), 2e18, "the PancakeSwap leg delivered every CAKE");
        assertEq(IERC20(A.WETH).balanceOf(address(cakeIndex)), 1e15);
        assertApproxEqRel(spent + stray, quote, 1e14, "spend vs the two quoters");
        assertEq(IERC20(A.USDC).balanceOf(A.PANCAKE_UNIVERSAL_ROUTER), 0, "the sweep took the stray USDC");
        assertGt(spent, 1e6);
        assertLt(spent, 100e6);
        _assertRoutersClean();

        // Burn: CAKE sold through PancakeSwap one hop at a time, WETH through Uniswap.
        uint256[] memory got = cakeIndex.previewRedeem(1e18);
        IIndexZap.BurnLeg[] memory legs = _cakeBurnLegs();
        (uint256 wethOut,,,) = quoter.quoteExactInput(legs[0].v3Path, got[0]);
        (uint256 cakeOut,,,) = IQuoterV2(A.PANCAKE_QUOTER_V2).quoteExactInput(legs[1].pancakePath, got[1]);
        uint256 burnQuote = wethOut + cakeOut;
        uint256 before = IERC20(A.USDC).balanceOf(alice);
        vm.startPrank(alice);
        cakeIndex.approve(address(zap), 1e18);
        uint256 out = _burnCall(cakeIndex, 1e18, A.USDC, burnQuote - burnQuote / 100, _cakeBurnLegs());
        vm.stopPrank();
        assertApproxEqRel(out, burnQuote, 1e14, "payout vs the two quoters");
        assertEq(IERC20(A.USDC).balanceOf(alice) - before, out);
        assertEq(cakeIndex.totalSupply(), 0);
        _assertRoutersClean();
    }

    /// @dev SV-1 against the deployed router. One wei sent to PancakeSwap's router is enough to revert a call from
    ///      any contract that cannot receive ether, as the zap cannot: shown first with a plain sweep. The zap's
    ///      PancakeSwap legs still go through, because each ends with WRAP_ETH, which turns the wei into WETH kept by
    ///      the router.
    function testFork_SV1_strayEtherInThePancakeRouterCannotBlockALeg() public {
        WeightedHub cakeIndex = _cakeIndex();
        vm.deal(address(this), 1 wei);
        (bool sent,) = A.PANCAKE_UNIVERSAL_ROUTER.call{value: 1 wei}("");
        assertTrue(sent, "anyone can send PancakeSwap's router ether");

        NoEtherCaller victim = new NoEtherCaller();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(A.USDC, address(victim), uint256(0));
        vm.expectRevert(bytes("ETH_TRANSFER_FAILED"));
        victim.run(IPancakeUniversalRouter(A.PANCAKE_UNIVERSAL_ROUTER), abi.encodePacked(uint8(0x04)), inputs);

        uint256 wethBefore = IERC20(A.WETH).balanceOf(A.PANCAKE_UNIVERSAL_ROUTER);
        // Forge seeds a freshly created address with a wei, so what the call must leave untouched is the delta.
        uint256 zapEthBefore = address(zap).balance;
        _mintCake(cakeIndex, 1e18);
        assertEq(cakeIndex.balanceOf(alice), 1e18, "the mint went through");
        assertEq(A.PANCAKE_UNIVERSAL_ROUTER.balance, 0, "the wei was wrapped");
        assertEq(IERC20(A.WETH).balanceOf(A.PANCAKE_UNIVERSAL_ROUTER), wethBefore + 1, "and kept by the router");
        assertEq(address(zap).balance, zapEthBefore, "no ether ever reaches the zap");
    }

    /// @dev PancakeSwap's Safe can pause its router: the PancakeSwap leg reverts whole, nothing is stranded, and the
    ///      same basket routed through Uniswap alone still mints.
    function testFork_pancake_aPausedRouterStopsOnlyItsLegs() public {
        WeightedHub cakeIndex = _cakeIndex();
        uint256 quote = _quoteCakeMint(cakeIndex, 1e18);
        vm.prank(IPancakeRouterAdmin(A.PANCAKE_UNIVERSAL_ROUTER).owner());
        IPancakeRouterAdmin(A.PANCAKE_UNIVERSAL_ROUTER).pause();

        uint256 maxIn = quote + quote / 100;
        deal(A.USDC, alice, maxIn);
        vm.startPrank(alice);
        IERC20(A.USDC).forceApprove(address(zap), maxIn);
        vm.expectRevert(bytes("Pausable: paused"));
        _mintCall(cakeIndex, A.USDC, maxIn, 1e18, _cakeMintLegs());
        vm.stopPrank();
        assertEq(IERC20(A.USDC).balanceOf(alice), maxIn, "nothing spent");
        _assertRoutersClean();
    }

    function _assertRoutersClean() internal view {
        address[3] memory tokens = [A.USDC, A.WETH, A.CAKE];
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(zap)), 0, "the zap keeps nothing");
        }
        assertEq(IERC20(A.CAKE).allowance(address(zap), A.PANCAKE_UNIVERSAL_ROUTER), 0, "and approves no router");
        assertEq(IERC20(A.USDC).allowance(address(zap), A.PANCAKE_UNIVERSAL_ROUTER), 0);
    }
}
