// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
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
import {RebalanceExecutorV3} from "./RebalanceExecutorV3.sol";

interface IQuoterV2ExactInput {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

interface IPoolObservations {
    function slot0() external view returns (uint160, int24, uint16 observationIndex, uint16, uint16, uint8, bool);
    function observations(uint256) external view returns (uint32 blockTimestamp, int56, uint160, bool);
}

interface IWbtcPauser {
    function owner() external view returns (address);
    function pause() external;
    function unpause() external;
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

        executor = new RebalanceExecutorV3(factory, ISwapRouter02(A.SWAP_ROUTER_02), A.WETH);
        executor.setFee(A.WBTC, F500);
        executor.setFee(A.LINK, F3000);
        executor.setFee(A.UNI, F3000);
        executor.setFee(A.AAVE, F3000);
        deal(A.WETH, address(executor), 100 ether);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    /// @dev A listing config whose minimum liquidity is a tenth of the pool's liquidity at the fork block, under the
    ///      mainnet list's policy of a third so that a fixture never fails on the pool's own drift.
    function _config(address pool, uint256 referenceSupply) internal view returns (IIndexFactory.TokenConfig memory c) {
        c.pool = pool;
        if (pool != address(0)) c.minLiquidity = IPoolLiquidity(pool).liquidity() / 10;
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

    function _poolOf(address token) internal pure returns (address) {
        if (token == A.WBTC) return A.WBTC_WETH_500;
        if (token == A.LINK) return A.LINK_WETH_3000;
        if (token == A.UNI) return A.UNI_WETH_3000;
        if (token == A.AAVE) return A.AAVE_WETH_3000;
        return address(0);
    }

    /// @dev Whether `pool` has already written an observation in this block.
    function _isFresh(address pool) internal view returns (bool) {
        // forge-lint: disable-next-line(unused-return)
        (,, uint16 idx,,,,) = IPoolObservations(pool).slot0();
        // forge-lint: disable-next-line(unused-return)
        (uint32 ts,,,) = IPoolObservations(pool).observations(idx);
        return ts == uint32(block.timestamp);
    }

    /// @dev Time passing on a fork does not make the pools trade: after a warp their newest observation is as old as
    ///      the warp, so `MAX_OBSERVATION_AGE` refuses the snapshot. On chain, twenty-eight days of elapsed time are
    ///      twenty-eight days of trading, so the test writes the observation that real trading would have written.
    ///      A pool writes one only when a swap moves its tick, so the amount escalates until it does, and each swap is
    ///      reversed so the poke leaves the price where it found it. The observation records the accumulators from
    ///      before the swap, so the history the rule reads stays honest. A pool whose token refuses transfers, as a
    ///      paused WBTC does, is left alone: a kept component is not read under the uncapped methodology anyway.
    function _pokePools() internal {
        deal(A.WETH, address(this), 100_000 ether);
        IERC20(A.WETH).forceApprove(A.SWAP_ROUTER_02, type(uint256).max);
        for (uint256 i = 0; i < tokens.length; ++i) {
            address pool = _poolOf(tokens[i]);
            if (pool == address(0)) continue;
            uint256 amount = 1 ether;
            for (uint256 tries = 0; tries < 10 && !_isFresh(pool); ++tries) {
                if (!_swap(A.WETH, tokens[i], amount)) break;
                amount *= 4;
            }
        }
    }

    /// @dev Swaps `amountIn` of `from` into `to` and straight back. Returns false when the pool refuses the trade.
    function _swap(address from, address to, uint256 amountIn) internal returns (bool) {
        uint24 fee = _feeOf(from == A.WETH ? to : from);
        try ISwapRouter02(A.SWAP_ROUTER_02)
            .exactInput(
                ISwapRouter02.ExactInputParams({
                    path: abi.encodePacked(from, fee, to),
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: 0
                })
            ) returns (
            uint256 got
        ) {
            IERC20(to).forceApprove(A.SWAP_ROUTER_02, got);
            try ISwapRouter02(A.SWAP_ROUTER_02)
                .exactInput(
                    ISwapRouter02.ExactInputParams({
                        path: abi.encodePacked(to, fee, from),
                        recipient: address(this),
                        amountIn: got,
                        amountOutMinimum: 0
                    })
                ) returns (
                uint256
            ) {}
                catch {}
            return true;
        } catch {
            return false;
        }
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
        _pokePools();
        uint256 gasBefore = gasleft();
        index.startRebalance(0);
        console2.log("startRebalance gas, 5 components:", gasBefore - gasleft());
        (uint256 eta,, uint256[] memory targets) = index.pendingRebalance();
        assertLt(targets[0], units[0], "the overweight component shrinks");
        assertGt(targets[2], units[2], "the underweight component grows");

        // Prices do not move on a fork, so an executor without competition waits for the floor.
        vm.warp(eta + index.AUCTION_DURATION());
        // Settlement prices the two sides again (DA-05), and three days of warping leave every pool's newest
        // observation three days old, which on chain only happens to a pool that has genuinely stopped trading.
        _pokePools();
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

        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            legs[i] = IIndexZap.BurnLeg({path: _toUsdc(tokens[i]), minAmountOut: 0});
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
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.StaleRebalanceNonce.selector, 0, 1));
        zap.burnToToken(p);
        p.expectedNonce = 1;
        uint256 out = zap.burnToToken(p);
        vm.stopPrank();
        assertApproxEqRel(out, navUsdc, 0.03e18);
    }

    function testFork_guardianRebalancesAroundAPausedWbtc() public {
        IndexToken index = _offTargetIndex(0, "PAUSE");
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        _pokePools();
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();

        address pauser = IWbtcPauser(A.WBTC).owner();
        vm.prank(pauser);
        IWbtcPauser(A.WBTC).pause();
        vm.warp(eta + index.AUCTION_DURATION());
        // A paused WBTC cannot trade, so its pool cannot be poked and the settlement guard would stop on its stale
        // price before reaching any transfer. This test is about the transfer, so the pause lifts for the poke.
        vm.prank(pauser);
        IWbtcPauser(A.WBTC).unpause();
        _pokePools();
        vm.prank(pauser);
        IWbtcPauser(A.WBTC).pause();
        (,, uint256[] memory amountsOut,) = index.previewRebalance();
        assertGt(amountsOut[0], 0, "WBTC is a shrinking leg");
        vm.expectRevert(bytes("")); // WBTC's whenNotPaused reverts with no data, and the index passes it on
        executor.fill(index); // WBTC must shrink, and its transfer fails

        uint256 wbtcHeld = IERC20(A.WBTC).balanceOf(address(index));
        _pokePools(); // three days have passed since the first snapshot; WBTC is paused, so its pool is skipped
        vm.startPrank(guardian);
        index.cancelRebalance();
        index.startRebalance(1 << 0);
        vm.stopPrank();
        (eta,,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());
        // WBTC is kept, so the settlement never prices it; the four legs that do trade need a fresh window.
        _pokePools();
        executor.fill(index);

        assertEq(IERC20(A.WBTC).balanceOf(address(index)), wbtcHeld, "WBTC never moved");
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);
    }
}
