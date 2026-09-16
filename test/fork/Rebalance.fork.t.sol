// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
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
}

/// @notice Rule-based rebalancing against real Uniswap V3 pools and tokens. Skips when MAINNET_RPC_URL is unset.
contract RebalanceForkTest is Test {
    using SafeERC20 for IERC20;

    IndexFactory factory;
    IIndexRule rule;
    IndexZap zap;
    RebalanceExecutorV3 executor;
    IQuoterV2ExactInput quoter = IQuoterV2ExactInput(A.QUOTER_V2);

    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address[] tokens;

    uint24 constant F500 = 500;
    uint24 constant F3000 = 3000;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, vm.envOr("FORK_BLOCK", A.FORK_BLOCK));

        factory = new IndexFactory(address(this), guardian, A.WETH, A.UNISWAP_V3_FACTORY, A.USDC);
        rule = IIndexRule(factory.RULE());
        zap = new IndexZap(factory, ISwapRouter02(A.SWAP_ROUTER_02));

        tokens.push(A.WBTC);
        tokens.push(A.WETH);
        tokens.push(A.LINK);
        tokens.push(A.UNI);
        tokens.push(A.AAVE);
        factory.proposeListing(A.WBTC, _config(A.WBTC_WETH_500, A.BTC_SUPPLY));
        factory.proposeListing(A.WETH, _config(address(0), A.ETH_SUPPLY));
        factory.proposeListing(A.LINK, _config(A.LINK_WETH_3000, A.LINK_SUPPLY));
        factory.proposeListing(A.UNI, _config(A.UNI_WETH_3000, A.UNI_SUPPLY));
        factory.proposeListing(A.AAVE, _config(A.AAVE_WETH_3000, 0)); // on-chain supply
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < tokens.length; ++i) {
            factory.executeListing(tokens[i]);
        }

        executor = new RebalanceExecutorV3(ISwapRouter02(A.SWAP_ROUTER_02), A.WETH);
        executor.setFee(A.WBTC, F500);
        executor.setFee(A.LINK, F3000);
        executor.setFee(A.UNI, F3000);
        executor.setFee(A.AAVE, F3000);
        deal(A.WETH, address(executor), 100 ether);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _config(address pool, uint256 referenceSupply) internal pure returns (IIndexFactory.TokenConfig memory c) {
        c.pool = pool;
        c.referenceSupply = referenceSupply;
    }

    function _feeOf(address token) internal pure returns (uint24) {
        return token == A.WBTC ? F500 : F3000;
    }

    /// @dev Exact-input path from a component to USDC through WETH.
    function _toUsdc(address token) internal pure returns (bytes memory) {
        if (token == A.WETH) return abi.encodePacked(A.WETH, F500, A.USDC);
        return abi.encodePacked(token, _feeOf(token), A.WETH, F500, A.USDC);
    }

    function _issue(IndexToken index, address who, uint256 shares) internal {
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

    function _assertBacked(IndexToken index) internal view {
        (address[] memory t, uint256[] memory u) = index.components();
        uint256 supply = index.totalSupply();
        for (uint256 i = 0; i < t.length; ++i) {
            uint256 required = supply * u[i] / 1e18 + index.totalClaims(t[i]);
            assertGe(IERC20(t[i]).balanceOf(address(index)), required, "component under-backed");
        }
    }

    /// @dev What `shares` of the index sell for on Uniswap, leg by leg, in raw USDC.
    function _quoteInUsdc(IndexToken index, uint256 shares) internal returns (uint256 total) {
        uint256[] memory amounts = index.previewRedeem(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            (uint256 out,,,) = quoter.quoteExactInput(_toUsdc(tokens[i]), amounts[i]);
            total += out;
        }
    }

    /// @dev Units that follow `methodology` at 1,000 dollars, pushed off target: the first component 60% heavier and
    ///      the third 40% lighter.
    function _offTargetIndex(uint8 methodology, string memory symbol) internal returns (IndexToken index) {
        uint256[] memory units = rule.initialUnits(tokens, methodology, 1_000e6);
        units[0] = units[0] * 16 / 10;
        units[2] = units[2] * 6 / 10;
        index = IndexToken(factory.createIndex(symbol, symbol, tokens, units, methodology));
        _issue(index, alice, 10e18);
    }

    // ---------------------------------------------------------------------
    // tests
    // ---------------------------------------------------------------------

    function testFork_rulePricesTrackUniswapQuotes() public {
        _assertPriceNearQuote(A.WBTC, 1e8);
        _assertPriceNearQuote(A.LINK, 1e18);
        _assertPriceNearQuote(A.UNI, 1e18);
        _assertPriceNearQuote(A.AAVE, 1e18);
        (uint256 wethForUsdc,,,) = quoter.quoteExactInput(abi.encodePacked(A.USDC, F500, A.WETH), 1_000e6);
        assertApproxEqRel(rule.price(A.USDC), wethForUsdc * 1e18 / 1_000e6, 0.03e18);
        assertEq(rule.price(A.WETH), 1e18);
        assertEq(rule.supply(A.WBTC), A.BTC_SUPPLY);
        assertEq(rule.supply(A.AAVE), IERC20(A.AAVE).totalSupply());
    }

    function _assertPriceNearQuote(address token, uint256 wholeToken) internal {
        (uint256 wethOut,,,) = quoter.quoteExactInput(abi.encodePacked(token, _feeOf(token), A.WETH), wholeToken);
        assertApproxEqRel(rule.price(token), wethOut * 1e18 / wholeToken, 0.03e18);
    }

    function testFork_uncappedIndexRebalancesThroughUniswap() public {
        _rebalanceThroughUniswap(_offTargetIndex(0, "BLUE"));
    }

    function testFork_cappedIndexRebalancesThroughUniswap() public {
        _rebalanceThroughUniswap(_offTargetIndex(1, "CBLUE"));
    }

    function _rebalanceThroughUniswap(IndexToken index) internal {
        (, uint256[] memory units) = index.components();
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        uint256 gasBefore = gasleft();
        index.startRebalance(0);
        console2.log("startRebalance gas, 5 components:", gasBefore - gasleft());
        (uint256 eta,, uint256[] memory targets) = index.pendingRebalance();
        assertLt(targets[0], units[0], "the overweight component shrinks");
        assertGt(targets[2], units[2], "the underweight component grows");

        // Prices do not move on a fork, so an executor without competition waits for the floor.
        vm.warp(eta + index.AUCTION_DURATION());
        uint256 wethBefore = IERC20(A.WETH).balanceOf(address(executor));
        gasBefore = gasleft();
        executor.fill(index);
        console2.log("executeRebalance gas, with the executor's swaps:", gasBefore - gasleft());
        assertGe(IERC20(A.WETH).balanceOf(address(executor)), wethBefore, "the floor covers the executor's swap costs");
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);

        (, uint256 navUsdc) = rule.navPerToken(address(index));
        assertApproxEqRel(
            navUsdc, _quoteInUsdc(index, 1e18), 0.03e18, "the displayed price matches what the basket sells for"
        );

        IndexZap.BurnLeg[] memory legs = new IndexZap.BurnLeg[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            legs[i] = IndexZap.BurnLeg({path: _toUsdc(tokens[i]), minAmountOut: 0});
        }
        IndexZap.BurnParams memory p = IndexZap.BurnParams({
            index: address(index),
            expectedNonce: 0,
            shares: 1e18,
            tokenOut: A.USDC,
            minAmountOut: 1,
            legs: legs,
            to: alice,
            deadline: block.timestamp
        });
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IndexZap.StaleRebalanceNonce.selector, 0, 1));
        zap.burnToToken(p);
        p.expectedNonce = 1;
        uint256 out = zap.burnToToken(p);
        vm.stopPrank();
        assertApproxEqRel(out, navUsdc, 0.03e18);
    }

    function testFork_guardianRebalancesAroundAPausedWbtc() public {
        IndexToken index = _offTargetIndex(0, "PAUSE");
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();

        vm.prank(IWbtcPauser(A.WBTC).owner());
        IWbtcPauser(A.WBTC).pause();
        vm.warp(eta + index.AUCTION_DURATION());
        vm.expectRevert();
        executor.fill(index); // WBTC must shrink, and its transfer fails

        uint256 wbtcHeld = IERC20(A.WBTC).balanceOf(address(index));
        vm.startPrank(guardian);
        index.cancelRebalance();
        index.startRebalance(1 << 0);
        vm.stopPrank();
        (eta,,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());
        executor.fill(index);

        assertEq(IERC20(A.WBTC).balanceOf(address(index)), wbtcHeld, "WBTC never moved");
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);
    }
}
