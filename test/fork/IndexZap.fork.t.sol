// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {ForkAddresses as A, IPoolLiquidity} from "./ForkAddresses.sol";

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

interface IUniswapV3PoolOracle {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
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

        factory = new IndexFactory(address(this), address(0), A.WETH, A.UNISWAP_V3_FACTORY, A.USDC);
        zap = new IndexZap(factory, ISwapRouter02(A.SWAP_ROUTER_02));

        factory.proposeListing(A.WBTC, _config(A.WBTC_WETH_500, A.BTC_SUPPLY));
        factory.proposeListing(A.WETH, _config(address(0), A.ETH_SUPPLY));
        factory.proposeListing(A.LINK, _config(A.LINK_WETH_3000, A.LINK_SUPPLY));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(A.WBTC);
        factory.executeListing(A.WETH);
        factory.executeListing(A.LINK);

        address[] memory t = new address[](3);
        uint256[] memory u = new uint256[](3);
        t[0] = A.WBTC;
        t[1] = A.WETH;
        t[2] = A.LINK;
        u[0] = U_WBTC;
        u[1] = U_WETH;
        u[2] = U_LINK;
        index = IndexToken(factory.createIndex("Blue Chip", "BLUE", t, u, 0));
    }

    /// @dev A listing config whose minimum liquidity is a tenth of the pool's liquidity at the fork block, under the
    ///      mainnet list's policy of a third so that a fixture never fails on the pool's own drift.
    function _config(address pool, uint256 referenceSupply) internal view returns (IIndexFactory.TokenConfig memory c) {
        c.pool = pool;
        if (pool != address(0)) c.minLiquidity = IPoolLiquidity(pool).liquidity() / 10;
        c.referenceSupply = referenceSupply;
    }

    /// @dev Grows a pool's observation ring the way anyone can on mainnet: raise the target, then trade in new blocks,
    ///      alternating direction so the tick moves each time, until the pool writes past its old ring.
    function _growObservations(address pool, address token) internal {
        IUniswapV3PoolOracle(pool).increaseObservationCardinalityNext(200);
        deal(A.WETH, address(this), 10 ether);
        IERC20(A.WETH).forceApprove(A.SWAP_ROUTER_02, type(uint256).max);
        IERC20(token).forceApprove(A.SWAP_ROUTER_02, type(uint256).max);
        for (uint256 i = 0; i < 300; ++i) {
            (,,, uint16 cardinality,,,) = IUniswapV3PoolOracle(pool).slot0();
            if (cardinality >= 200) return;
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            bytes memory path =
                i % 2 == 0 ? abi.encodePacked(A.WETH, F3000, token) : abi.encodePacked(token, F3000, A.WETH);
            uint256 amountIn = i % 2 == 0 ? 0.05 ether : IERC20(token).balanceOf(address(this));
            ISwapRouter02(A.SWAP_ROUTER_02)
                .exactInput(
                    ISwapRouter02.ExactInputParams({
                        path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: 0
                    })
                );
        }
        revert("observation ring did not grow");
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

    function _mintLegs(bytes[] memory paths) internal pure returns (IIndexZap.MintLeg[] memory legs) {
        legs = new IIndexZap.MintLeg[](paths.length);
        for (uint256 i = 0; i < paths.length; ++i) {
            legs[i] = IIndexZap.MintLeg({path: paths[i], maxAmountIn: 0});
        }
    }

    function _burnLegs(bytes[] memory paths) internal pure returns (IIndexZap.BurnLeg[] memory legs) {
        legs = new IIndexZap.BurnLeg[](paths.length);
        for (uint256 i = 0; i < paths.length; ++i) {
            legs[i] = IIndexZap.BurnLeg({path: paths[i], minAmountOut: 0});
        }
    }

    function _mintCall(IndexToken idx, address tokenIn, uint256 maxIn, uint256 shares, IIndexZap.MintLeg[] memory legs)
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
        IndexToken idx,
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
        vm.expectRevert(bytes("STF"));
        _mintCall(index, A.USDC, maxIn, 1e18, _mintLegs(_mintPaths(A.USDC)));
        vm.stopPrank();
        assertEq(IERC20(A.USDC).balanceOf(alice), maxIn);
        assertEq(index.balanceOf(alice), 0);
    }

    function testFork_mintAndBurnWithPerLegLimits() public {
        uint256[] memory need = index.previewIssue(1e18);
        bytes[] memory mintPaths = _mintPaths(A.USDC);
        IIndexZap.MintLeg[] memory mintLegs = new IIndexZap.MintLeg[](3);
        uint256 total;
        for (uint256 i = 0; i < 3; ++i) {
            (uint256 legQuote,,,) = quoter.quoteExactOutput(mintPaths[i], need[i]);
            mintLegs[i] = IIndexZap.MintLeg({path: mintPaths[i], maxAmountIn: legQuote + legQuote / 200});
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
            burnLegs[i] = IIndexZap.BurnLeg({path: burnPaths[i], minAmountOut: legOut - legOut / 200});
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
        legs[0] = IIndexZap.BurnLeg({path: "", minAmountOut: 0}); // WBTC is the payout token
        legs[1] = IIndexZap.BurnLeg({path: abi.encodePacked(A.WETH, F500, A.WBTC), minAmountOut: 0});
        legs[2] = IIndexZap.BurnLeg({path: abi.encodePacked(A.LINK, F3000, A.WETH, F500, A.WBTC), minAmountOut: 0});

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
        vm.expectPartialRevert(IIndexZap.InsufficientOutput.selector);
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

        // tBTC's 0.3% WETH pool keeps too little price history for the rule, so listing it fails until someone grows
        // the pool's observation ring, which anyone can do.
        IIndexFactory.TokenConfig memory tbtc = _config(A.TBTC_WETH_3000, 0);
        (,,, uint16 cardinality,,,) = IUniswapV3PoolOracle(A.TBTC_WETH_3000).slot0();
        if (cardinality < 200) {
            vm.expectRevert(
                abi.encodeWithSelector(IIndexRule.PoolHistoryTooShort.selector, A.TBTC_WETH_3000, cardinality)
            );
            factory.proposeListing(A.TBTC, tbtc);
            _growObservations(A.TBTC_WETH_3000, A.TBTC);
        }
        vm.warp(block.timestamp + 1 hours);
        factory.proposeListing(A.TBTC, tbtc);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(A.TBTC);

        IndexToken btc = IndexToken(factory.createIndex("BTC Basket", "BTC2", t, u, 0));

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
