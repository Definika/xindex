// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
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

/// @notice End-to-end against real Uniswap V3, USDC and USDT. Skips when MAINNET_RPC_URL is unset.
///         Run: MAINNET_RPC_URL=... forge test --match-path 'test/fork/*' -vvv
contract IndexZapForkTest is Test {
    using SafeERC20 for IERC20;

    IndexFactory factory;
    IndexZap zap;
    IndexToken index;
    IQuoterV2 quoter = IQuoterV2(A.QUOTER_V2);

    address alice = makeAddr("alice");

    // 0.001 WBTC + 0.01 WETH + 1 LINK per index token
    uint256 constant U_WBTC = 100_000;
    uint256 constant U_WETH = 1e16;
    uint256 constant U_LINK = 1e18;

    uint24 constant F500 = 500;
    uint24 constant F3000 = 3000;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        // FORK_BLOCK env overrides the pin (e.g. for non-archive RPCs that only serve recent state).
        vm.createSelectFork(url, vm.envOr("FORK_BLOCK", A.FORK_BLOCK));

        factory = new IndexFactory(address(this), address(0));
        zap = new IndexZap(factory, ISwapRouter02(A.SWAP_ROUTER_02));

        address[4] memory list = [A.WBTC, A.WETH, A.LINK, A.TBTC];
        for (uint256 i = 0; i < list.length; ++i) {
            factory.proposeListing(list[i]);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < list.length; ++i) {
            factory.executeListing(list[i]);
        }

        address[] memory t = new address[](3);
        uint256[] memory u = new uint256[](3);
        t[0] = A.WBTC;
        t[1] = A.WETH;
        t[2] = A.LINK;
        u[0] = U_WBTC;
        u[1] = U_WETH;
        u[2] = U_LINK;
        index = IndexToken(factory.createIndex("Blue Chip", "BLUE", t, u));
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

    function _mintLegs(bytes[] memory paths) internal pure returns (IndexZap.MintLeg[] memory legs) {
        legs = new IndexZap.MintLeg[](paths.length);
        for (uint256 i = 0; i < paths.length; ++i) {
            legs[i] = IndexZap.MintLeg({path: paths[i], maxAmountIn: 0});
        }
    }

    function _burnLegs(bytes[] memory paths) internal pure returns (IndexZap.BurnLeg[] memory legs) {
        legs = new IndexZap.BurnLeg[](paths.length);
        for (uint256 i = 0; i < paths.length; ++i) {
            legs[i] = IndexZap.BurnLeg({path: paths[i], minAmountOut: 0});
        }
    }

    function _mintCall(IndexToken idx, address tokenIn, uint256 maxIn, uint256 shares, IndexZap.MintLeg[] memory legs)
        internal
        returns (uint256)
    {
        return zap.mintWithToken(
            IndexZap.MintParams({
                index: address(idx),
                tokenIn: tokenIn,
                maxAmountIn: maxIn,
                shares: shares,
                legs: legs,
                to: alice,
                deadline: block.timestamp
            })
        );
    }

    function _burnCall(IndexToken idx, uint256 shares, address tokenOut, uint256 minOut, IndexZap.BurnLeg[] memory legs)
        internal
        returns (uint256)
    {
        return zap.burnToToken(
            IndexZap.BurnParams({
                index: address(idx),
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
        assertEq(IERC20(A.USDC).allowance(address(zap), A.SWAP_ROUTER_02), 0);

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
        // SwapRouter02 checks amountInMaximum only after the pool pulled the input, so an underfunded leg
        // surfaces as "STF" rather than "Too much requested". Either way the whole mint reverts.
        vm.expectRevert();
        _mintCall(index, A.USDC, maxIn, 1e18, _mintLegs(_mintPaths(A.USDC)));
        vm.stopPrank();
        assertEq(IERC20(A.USDC).balanceOf(alice), maxIn);
        assertEq(index.balanceOf(alice), 0);
    }

    function testFork_mintAndBurnWithPerLegLimits() public {
        uint256[] memory need = index.previewIssue(1e18);
        bytes[] memory mintPaths = _mintPaths(A.USDC);
        IndexZap.MintLeg[] memory mintLegs = new IndexZap.MintLeg[](3);
        uint256 total;
        for (uint256 i = 0; i < 3; ++i) {
            (uint256 legQuote,,,) = quoter.quoteExactOutput(mintPaths[i], need[i]);
            mintLegs[i] = IndexZap.MintLeg({path: mintPaths[i], maxAmountIn: legQuote + legQuote / 200});
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
        IndexZap.BurnLeg[] memory burnLegs = new IndexZap.BurnLeg[](3);
        uint256 quoteOut;
        for (uint256 i = 0; i < 3; ++i) {
            (uint256 legOut,,,) = quoter.quoteExactInput(burnPaths[i], got[i]);
            burnLegs[i] = IndexZap.BurnLeg({path: burnPaths[i], minAmountOut: legOut - legOut / 200});
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

        IndexZap.BurnLeg[] memory legs = new IndexZap.BurnLeg[](3);
        legs[0] = IndexZap.BurnLeg({path: "", minAmountOut: 0}); // WBTC is the payout token
        legs[1] = IndexZap.BurnLeg({path: abi.encodePacked(A.WETH, F500, A.WBTC), minAmountOut: 0});
        legs[2] = IndexZap.BurnLeg({path: abi.encodePacked(A.LINK, F3000, A.WETH, F500, A.WBTC), minAmountOut: 0});

        (uint256 wethOut,,,) = quoter.quoteExactInput(legs[1].path, U_WETH);
        (uint256 linkOut,,,) = quoter.quoteExactInput(legs[2].path, U_LINK);
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
        vm.expectPartialRevert(IndexZap.InsufficientOutput.selector);
        _burnCall(index, 1e18, A.USDC, quote + 1, _burnLegs(_burnPaths(A.USDC)));
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18);
    }

    /// @dev tBTC has no deep direct stable pool; it routes stable -> WETH (0.05%) -> tBTC (0.3%).
    function testFork_btcBasketWithTBTC_mintAndBurn() public {
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        t[0] = A.WBTC;
        t[1] = A.TBTC;
        u[0] = 50_000; // 0.0005 WBTC (8 decimals)
        u[1] = 5e14; // 0.0005 tBTC (18 decimals)
        IndexToken btc = IndexToken(factory.createIndex("BTC Basket", "BTC2", t, u));

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
}
