// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexHub} from "../../src/IndexHub.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IIndexHub} from "../../src/interfaces/IIndexHub.sol";
import {ISwapRouter02} from "../mocks/ISwapRouter02.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {RebalanceExecutorV3} from "./RebalanceExecutorV3.sol";

interface IQuoterV2ExactInput {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

interface IWbtcPauser {
    function owner() external view returns (address);
    function pause() external;
    function unpause() external;
}

/// @notice The λ auction against real Uniswap V3 pools and tokens, listed at their dated mainnet reference supplies.
///         Prices exist only inside the test, from the quoter; the index never reads one. Skips when MAINNET_RPC_URL is
///         unset.
contract RebalanceForkTest is Test {
    using SafeERC20 for IERC20;

    IndexFactory factory;
    IndexZap zap;
    RebalanceExecutorV3 executor;
    IQuoterV2ExactInput quoter = IQuoterV2ExactInput(A.QUOTER_V2);

    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");
    address[] tokens;

    uint24 constant F500 = 500;
    uint24 constant F3000 = 3000;
    uint256 constant WAD = 1e18;
    /// @dev About 0.001 WBTC per index token at the reference supplies, and the rest in proportion to market cap:
    ///      roughly 0.006 WETH, 0.037 LINK and 0.031 UNI.
    uint256 constant K = 5e25;
    /// @dev A thousand index tokens, so every moving leg is well above a pool's rounding.
    uint256 constant SHARES = 1_000e18;

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

        factory = new IndexFactory(address(this), guardian);
        zap = new IndexZap(factory, IUniversalRouter(A.UNIVERSAL_ROUTER));

        tokens.push(A.WBTC);
        tokens.push(A.WETH);
        tokens.push(A.LINK);
        tokens.push(A.UNI);
        factory.proposeListing(A.WBTC, A.BTC_SUPPLY);
        factory.proposeListing(A.WETH, A.ETH_SUPPLY);
        factory.proposeListing(A.LINK, A.LINK_SUPPLY);
        factory.proposeListing(A.UNI, A.UNI_SUPPLY);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < tokens.length; ++i) {
            factory.executeListing(tokens[i]);
        }

        executor = new RebalanceExecutorV3(factory, ISwapRouter02(A.SWAP_ROUTER_02), A.WETH);
        executor.setFee(A.WBTC, F500);
        executor.setFee(A.LINK, F3000);
        executor.setFee(A.UNI, F3000);
        deal(A.WETH, address(executor), 100 ether);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _feeOf(address token) internal pure returns (uint24) {
        return token == A.WBTC ? F500 : F3000;
    }

    /// @dev Exact-input path from a component to USDC through WETH.
    function _toUsdc(address token) internal pure returns (bytes memory) {
        if (token == A.WETH) return abi.encodePacked(A.WETH, F500, A.USDC);
        return abi.encodePacked(token, _feeOf(token), A.WETH, F500, A.USDC);
    }

    function _issue(IndexHub index, address who, uint256 shares) internal {
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(tokens[i], who, need[i]);
        }
        vm.startPrank(who);
        for (uint256 i = 0; i < tokens.length; ++i) {
            IERC20(tokens[i]).forceApprove(address(index), need[i]);
        }
        index.issue(shares, who);
        vm.stopPrank();
    }

    function _assertBacked(IndexHub index) internal view {
        (address[] memory t, uint256[] memory u) = index.components();
        uint256 supply = index.totalSupply();
        for (uint256 i = 0; i < t.length; ++i) {
            uint256 required = supply * u[i] / 1e18 + index.totalClaims(t[i]);
            assertGe(IERC20(t[i]).balanceOf(address(index)), required, "component under-backed");
        }
    }

    /// @dev What `shares` of the index sell for on Uniswap, leg by leg, in raw USDC.
    function _quoteInUsdc(IndexHub index, uint256 shares) internal returns (uint256 total) {
        uint256[] memory amounts = index.previewRedeem(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            (uint256 out,,,) = quoter.quoteExactInput(_toUsdc(tokens[i]), amounts[i]);
            total += out;
        }
    }

    /// @dev Each component's price in WETH wei per 1e18 raw units, from what one whole token sells for into WETH. The
    ///      pool fee is inside the quote, which scales a price down by at most 0.3% and changes no conclusion below.
    function _quotedPrices() internal returns (uint256[] memory prices) {
        prices = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (tokens[i] == A.WETH) {
                prices[i] = WAD;
                continue;
            }
            uint256 whole = tokens[i] == A.WBTC ? 1e8 : 1e18;
            (uint256 out,,,) = quoter.quoteExactInput(abi.encodePacked(tokens[i], _feeOf(tokens[i]), A.WETH), whole);
            prices[i] = out * WAD / whole;
        }
    }

    function _value(uint256[] memory amounts, uint256[] memory prices) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < amounts.length; ++i) {
            total += amounts[i] * prices[i] / WAD;
        }
    }

    /// @dev An index of the four at K, with SHARES issued to alice.
    function _index(string memory symbol) internal returns (IndexHub index) {
        index = IndexHub(factory.createIndex(symbol, symbol, tokens, K));
        _issue(index, alice, SHARES);
    }

    /// @dev One weekly supply batch moving WBTC, LINK and UNI by the given basis points each (±50 is the step), then the
    ///      wait until the index may rebalance.
    function _revise(IndexHub index, int256 wbtcBps, int256 linkBps, int256 uniBps) internal {
        address[] memory t = new address[](3);
        uint256[] memory s = new uint256[](3);
        (t[0], t[1], t[2]) = (A.WBTC, A.LINK, A.UNI);
        (s[0], s[1], s[2]) =
        (_moved(A.BTC_SUPPLY, wbtcBps), _moved(A.LINK_SUPPLY, linkBps), _moved(A.UNI_SUPPLY, uniBps));
        _sortByAddress(t, s);
        factory.proposeSupplies(t, s);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeSupplies();
        uint256 due = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        if (block.timestamp < due) vm.warp(due);
    }

    function _moved(uint256 supply, int256 bps) internal pure returns (uint256) {
        return bps >= 0 ? supply * (10_000 + uint256(bps)) / 10_000 : supply * (10_000 - uint256(-bps)) / 10_000;
    }

    function _sortByAddress(address[] memory t, uint256[] memory s) internal pure {
        for (uint256 i = 1; i < t.length; ++i) {
            for (uint256 j = i; j > 0 && t[j] < t[j - 1]; --j) {
                (t[j], t[j - 1]) = (t[j - 1], t[j]);
                (s[j], s[j - 1]) = (s[j - 1], s[j]);
            }
        }
    }

    // ---------------------------------------------------------------------
    // tests
    // ---------------------------------------------------------------------

    /// @dev The point of the units-anchored band: the λ at which a fill is value-neutral to holders, at whatever prices,
    ///      is λ* = Σ u_i p_i / Σ (u_i / r_i) p_i, a weighted average of the moving ratios, so it lies inside
    ///      [λmin, λmax]. Here the prices are real Uniswap quotes, and the settlement the index would make at the second
    ///      λ(t) reaches λ* gives back, at those prices, what it takes to within the rounding of one second of decay.
    function testFork_breakEvenLiesInsideTheBandAtRealQuotes() public {
        IndexHub index = _index("EVEN");
        _revise(index, 50, -50, 30);
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,, uint256 lambdaMin, uint256 lambdaMax, uint256[] memory ratios) = index.pendingRebalance();
        assertGe(lambdaMax * WAD, lambdaMin * (WAD + index.MIN_BAND()), "the revision opens at least MIN_BAND");
        assertLe(lambdaMax, WAD + index.MAX_SUPPLY_STEP(), "and the clamp holds the top");
        assertGe(lambdaMin, WAD - index.MAX_SUPPLY_STEP(), "and the bottom");

        (, uint256[] memory units) = index.components();
        uint256[] memory prices = _quotedPrices();
        uint256 held;
        uint256 scaled;
        for (uint256 i = 0; i < units.length; ++i) {
            held += units[i] * prices[i];
            scaled += units[i] * prices[i] * WAD / ratios[i];
        }
        uint256 breakEven = held * WAD / scaled;
        console2.log("band", lambdaMin, lambdaMax);
        console2.log("break-even at real quotes", breakEven);
        assertGe(breakEven, lambdaMin, "the break-even lies inside the band");
        assertLe(breakEven, lambdaMax);

        _assertNeutralAt(index, eta, breakEven, prices, held);
    }

    /// @dev Warps to the second λ(t) reaches `breakEven` and values the settlement there at `prices`. What separates
    ///      its two sides is rounding, all of it bounded: a second of decay moves the whole basket by
    ///      (λmax − λmin) / AUCTION_DURATION, and every new unit is rounded up, by less than one raw unit per share,
    ///      which the backing turns into at most SHARES / 1e18 raw units of that component, plus one from flooring it.
    function _assertNeutralAt(IndexHub index, uint256 eta, uint256 breakEven, uint256[] memory prices, uint256 held)
        internal
    {
        (,, uint256 lambdaMin, uint256 lambdaMax,) = index.pendingRebalance();
        vm.warp(eta + (lambdaMax - breakEven) * index.AUCTION_DURATION() / (lambdaMax - lambdaMin));
        (uint256 lambda,, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        assertApproxEqRel(lambda, breakEven, 1e12, "the auction reaches the break-even");
        uint256 paid = _value(amountsOut, prices);
        uint256 received = _value(amountsIn, prices);
        assertGt(paid, 0, "both sides move at the break-even");

        uint256 aSecond = held / WAD * SHARES / WAD * (lambdaMax - lambdaMin) / index.AUCTION_DURATION() / WAD + 1;
        uint256 roundedUp;
        for (uint256 i = 0; i < prices.length; ++i) {
            roundedUp += (SHARES / WAD + 1) * prices[i] / WAD + 1;
        }
        console2.log("paid, received, at real quotes (WETH wei)", paid, received);
        console2.log("rounding bound", roundedUp + aSecond);
        assertGe(received + aSecond, paid, "the index gives up no more than it gets back, at those prices");
        assertLe(received, paid + roundedUp + aSecond, "and gets back no more than its rounding");
    }

    function testFork_indexRebalancesThroughUniswap() public {
        IndexHub index = _index("BLUE");
        (, uint256[] memory units) = index.components();
        _revise(index, 50, -50, 30);

        uint256 gasBefore = gasleft();
        vm.prank(stranger);
        index.startRebalance(0);
        console2.log("startRebalance gas, 4 components:", gasBefore - gasleft());
        (uint256 eta,,,,) = index.pendingRebalance();

        // Prices do not move on a fork, so an executor without competition waits for the floor, where the component
        // with the lowest ratio keeps its units and every other one shrinks by up to twice the step.
        vm.warp(eta + index.AUCTION_DURATION());
        (uint256 lambda, uint256[] memory newUnits,,) = index.previewRebalance();
        assertEq(lambda, index.currentLambda());
        assertLt(newUnits[2], units[2], "LINK, whose supply fell, shrinks");
        uint256 quoteBefore = _quoteInUsdc(index, SHARES);
        uint256 wethBefore = IERC20(A.WETH).balanceOf(address(executor));
        gasBefore = gasleft();
        executor.fill(index);
        console2.log("executeRebalance gas, with the executor's swaps:", gasBefore - gasleft());
        assertGe(IERC20(A.WETH).balanceOf(address(executor)), wethBefore, "the floor covers the executor's swap costs");
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);
        uint256 quoteAfter = _quoteInUsdc(index, SHARES);
        console2.log("basket in USDC before and after the fill at the floor", quoteBefore, quoteAfter);
        assertGe(
            quoteAfter * WAD,
            quoteBefore * (WAD - 2 * index.MAX_SUPPLY_STEP() - 0.001e18),
            "a lone executor takes at most the band"
        );

        // The fill re-anchors the units to the supplies, so the next start has nothing left to do.
        vm.warp(block.timestamp + index.MIN_REBALANCE_INTERVAL());
        (, uint256 nextMin, uint256 nextMax) = index.previewBand(0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.BandTooNarrow.selector, nextMin, nextMax));
        index.startRebalance(0);

        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            legs[i] = IIndexZap.BurnLeg({v3Path: _toUsdc(tokens[i]), v4Path: new PathKey[](0), minAmountOut: 0});
        }
        IIndexZap.BurnParams memory p = IIndexZap.BurnParams({
            index: address(index),
            expectedNonce: 0,
            shares: 1e18,
            tokenOut: A.USDC,
            minAmountOut: 1,
            legs: legs,
            to: alice,
            deadline: block.timestamp
        });
        uint256 quoted = _quoteInUsdc(index, 1e18);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.StaleRebalanceNonce.selector, 0, 1));
        zap.burnToToken(p);
        p.expectedNonce = 1;
        uint256 out = zap.burnToToken(p);
        vm.stopPrank();
        assertApproxEqRel(out, quoted, 0.01e18, "the burn pays what the basket quotes");
    }

    /// @dev M01's rebalancing half on the real token: a paused WBTC that must shrink blocks the fill, and the guardian
    ///      routes around it with a keep mask while the other three still span a band.
    function testFork_guardianRebalancesAroundAPausedWbtc() public {
        IndexHub index = _index("PAUSE");
        _revise(index, -50, 50, -30);
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,,,) = index.pendingRebalance();

        address pauser = IWbtcPauser(A.WBTC).owner();
        vm.prank(pauser);
        IWbtcPauser(A.WBTC).pause();
        vm.warp(eta + index.AUCTION_DURATION());
        (,, uint256[] memory amountsOut,) = index.previewRebalance();
        assertGt(amountsOut[0], 0, "WBTC is a shrinking leg");
        vm.expectRevert(bytes("")); // WBTC's whenNotPaused reverts with no data, and the index passes it on
        executor.fill(index);

        uint256 wbtcHeld = IERC20(A.WBTC).balanceOf(address(index));
        (, uint256[] memory unitsBefore) = index.components();
        vm.startPrank(guardian);
        index.cancelRebalance();
        index.startRebalance(1 << 0);
        vm.stopPrank();
        (eta,,,,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());
        executor.fill(index);

        (, uint256[] memory unitsAfter) = index.components();
        assertEq(unitsAfter[0], unitsBefore[0], "a kept component keeps its units");
        assertEq(IERC20(A.WBTC).balanceOf(address(index)), wbtcHeld, "WBTC never moved");
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);
    }
}
