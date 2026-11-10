// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../../src/WeightedHub.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IUniversalRouterSwaps} from "../../src/interfaces/IUniversalRouterSwaps.sol";
import {IWeightedHub} from "../../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../../src/interfaces/IWeightedIndexFactory.sol";
import {IRebalanceExecutor} from "../../src/interfaces/IRebalanceExecutor.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {Listings} from "../../script/Listings.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {ISwapRouter02} from "../mocks/ISwapRouter02.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {WeightedExecutorV3} from "./WeightedExecutorV3.sol";

interface IQuoterV2Weighted {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

interface IUniswapV3FactoryWeighted {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3PoolLiquidity {
    function liquidity() external view returns (uint128);
}

interface IWbtcAdmin {
    function owner() external view returns (address);
    function pause() external;
    function unpause() external;
}

/// @notice The weighted index on a mainnet fork, with every coin of the Ethereum list (the first four and the wide
///         list), real token contracts and real Uniswap pools. Nothing stands in for a price: the contracts read none.
///         The tests price each coin from the pools, as an executor would, and name their fills by those prices.
///
///         It answers what the unit tests cannot: does every real token issue, redeem and rebalance through the hub;
///         which coins can Uniswap actually trade, at what slippage; does the zap mint and burn a weighted index
///         through real pools; does a Uniswap rebalancer settle; and what happens, with real tokens, when WBTC is
///         paused, an executor leaves a coin alone, a fill asks for too much or nobody fills. Skips when
///         MAINNET_RPC_URL is unset.
contract WeightedHubForkTest is Test, IRebalanceExecutor {
    using SafeERC20 for IERC20;

    WeightedIndexFactory factory;
    IndexZap zap;
    IQuoterV2Weighted quoter = IQuoterV2Weighted(A.QUOTER_V2);
    IUniswapV3FactoryWeighted v3 = IUniswapV3FactoryWeighted(M.UNISWAP_V3_FACTORY);

    address guardian = makeAddr("guardian");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    /// @dev What the fork found for one coin.
    struct Coin {
        address token;
        uint8 decimals;
        bool dealt; // whether forge's `deal` can write its balance
        bool routed; // whether a Uniswap V3 route to USDC exists
        bytes route; // exact-input path to USDC
        int64 priceE8; // USD with 8 decimals, from the pools, or $1 with no route
        uint256 slippageBps; // selling $1,000 against selling $10, in basis points
    }

    Coin[] coins;
    /// @dev Dollars per index token. Spread over every coin of the list, each gets VALUE / 49; Tether Gold, at about
    ///      $4,200 an ounce in 6 decimals, needs at least $42 of it to reach the factory's MIN_RAW_UNITS of 10,000.
    uint256 constant VALUE = 2500;
    uint256 constant QUOTE_ATTEMPTS = 3;
    /// @dev Gas for one `deal`: a probe that walks a token's storage stops here, with 1/64 left for the rest.
    uint256 internal constant DEAL_GAS = 32_000_000;
    uint24[4] TIERS = [uint24(100), 500, 3000, 10_000];

    // ---------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
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

        factory = new WeightedIndexFactory(address(this), guardian);
        factory.setApprovedCreator(creator, true);
        zap = new IndexZap(IIndexFactory(address(factory)), IUniversalRouter(A.UNIVERSAL_ROUTER), IWETH9(A.WETH));

        address[] memory tokens = Listings.all();
        for (uint256 i = 0; i < tokens.length; ++i) {
            factory.proposeListing(tokens[i]);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < tokens.length; ++i) {
            factory.executeListing(tokens[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Discovery: what Uniswap can do with each coin
    // ---------------------------------------------------------------------

    /// @dev Finds, for the first `count` coins of the table, the Uniswap V3 route to USDC (direct, or through WETH,
    ///      over every fee tier with liquidity) that pays most for a $1,000 sale, prices the coin from a $10 sale along
    ///      it, and measures the slippage of the $1,000 one.
    function _discover(uint256 count) internal {
        address[] memory tokens = Listings.all();
        for (uint256 i = 0; i < count; ++i) {
            Coin memory c;
            c.token = tokens[i];
            c.decimals = IERC20Metadata(tokens[i]).decimals();
            c.dealt = _canDeal(tokens[i]);
            (c.route, c.routed) = _bestRoute(tokens[i], c.decimals);
            c.priceE8 = 1e8;
            if (c.routed) {
                // The $10 and $1,000 sales along the route that pays most for $1,000.
                (uint256 one,) = _quote(c.route, 10 ** c.decimals);
                uint256 small = Math.max(Math.mulDiv(10e6, 10 ** c.decimals, Math.max(one, 1)), 1);
                (c.route,) = _bestRouteFor(tokens[i], small * 100);
                (uint256 smallOut, bool priced) = _quote(c.route, small);
                // A live route that prices a coin at nothing means a quote failed, not that the coin is worthless.
                // Pricing it at the smallest unit instead once gave VIRTUAL 10^-8 USD and units past MAX_UNITS, when the
                // public RPC dropped its pool's storage reads (2026-10-06): refuse with the reason rather than misprice.
                require(
                    priced && smallOut != 0,
                    string.concat(
                        "cannot price ",
                        IERC20Metadata(tokens[i]).symbol(),
                        " along its live route: the fork's RPC dropped a read, or the route broke; re-run"
                    )
                );
                c.priceE8 = int64(int256(Math.mulDiv(smallOut, 10 ** c.decimals * 100, small)));
                (uint256 bigOut, bool ok) = _quote(c.route, small * 100);
                c.slippageBps =
                    ok && smallOut != 0 ? 10_000 - Math.min(10_000, bigOut * 10_000 / (smallOut * 100)) : 10_000;
            } else {
                c.slippageBps = 10_000;
            }
            coins.push(c);
        }
    }

    function _report() internal view {
        console2.log("coin | decimals | dealt | Uniswap route | price (USD, 8 dec) | slippage of $1,000 (bps)");
        for (uint256 i = 0; i < coins.length; ++i) {
            Coin storage c = coins[i];
            console2.log(
                string.concat(
                    IERC20Metadata(c.token).symbol(),
                    " | ",
                    vm.toString(c.decimals),
                    " | ",
                    c.dealt ? "yes" : "NO",
                    " | ",
                    c.routed ? "yes" : "none",
                    " | ",
                    vm.toString(int256(c.priceE8)),
                    " | ",
                    c.routed ? vm.toString(c.slippageBps) : "-"
                )
            );
        }
    }

    /// @dev forge-std's `deal` finds a token's balance slot by writing `type(uint256).max` into each slot `balanceOf`
    ///      read and calling it again. RSR's `balanceOf` reads the length of its `origins` set, so that probe makes
    ///      it walk 2^256 empty slots, each a fresh fork read, until the gas runs out, which at a test's gas limit is
    ///      hours of RPC calls. The cap ends the walk after about 10,000 reads; the probe fails, forge-std moves to
    ///      the next slot, finds the balance and verifies its write with the 1/64 the walk leaves, about 500k. Every
    ///      `deal` of this suite goes through it.
    function deal(address token, address to, uint256 give) internal override {
        this.dealWithin{gas: DEAL_GAS}(token, to, give);
    }

    /// @dev forge-std's `deal` as an external call, so `deal` can cap its gas and `_canDeal` can catch its revert.
    function dealWithin(address token, address to, uint256 give) external {
        super.deal(token, to, give);
    }

    function _canDeal(address token) internal returns (bool) {
        try this.dealWithin{gas: DEAL_GAS}(token, address(0xdead1), 12_345) {
            return IERC20(token).balanceOf(address(0xdead1)) == 12_345;
        } catch {
            return false;
        }
    }

    /// @dev A quote along `path`, tried up to QUOTE_ATTEMPTS times: on a fork, a failed quote is as often the RPC
    ///      dropping a storage read as the route failing, and a dropped read must not pass for "no output".
    function _quote(bytes memory path, uint256 amountIn) internal returns (uint256 out, bool ok) {
        for (uint256 attempt = 0; attempt < QUOTE_ATTEMPTS; ++attempt) {
            try quoter.quoteExactInput(path, amountIn) returns (uint256 o, uint160[] memory, uint32[] memory, uint256) {
                return (o, true);
            } catch {}
        }
        return (0, false);
    }

    function _live(address a, address b, uint24 fee) internal view returns (bool) {
        address pool = v3.getPool(a, b, fee);
        return pool != address(0) && IUniswapV3PoolLiquidity(pool).liquidity() != 0;
    }

    /// @dev The candidate route that sells one whole token for the most USDC, for a first price.
    function _bestRoute(address token, uint8 decimals) internal returns (bytes memory best, bool found) {
        return _bestRouteFor(token, 10 ** decimals);
    }

    /// @dev The candidate route that sells `probe` raw units for the most USDC.
    function _bestRouteFor(address token, uint256 probe) internal returns (bytes memory best, bool found) {
        uint256 bestOut = 0;
        for (uint256 t = 0; t < TIERS.length; ++t) {
            if (_live(token, A.USDC, TIERS[t])) {
                bytes memory path = abi.encodePacked(token, TIERS[t], A.USDC);
                (uint256 out, bool ok) = _quote(path, probe);
                if (ok && out > bestOut) (best, bestOut, found) = (path, out, true);
            }
            if (token != A.WETH && _live(token, A.WETH, TIERS[t])) {
                bytes memory path = abi.encodePacked(token, TIERS[t], A.WETH, uint24(500), A.USDC);
                (uint256 out, bool ok) = _quote(path, probe);
                if (ok && out > bestOut) (best, bestOut, found) = (path, out, true);
            }
        }
    }

    // ---------------------------------------------------------------------
    // Index helpers
    // ---------------------------------------------------------------------

    /// @dev An index of `picked` coins at equal weights worth VALUE dollars a token at their discovered prices, each
    ///      price scaled by `skewBps[i]` (10,000 = as found), so an index can start off its weights.
    function _create(string memory name, Coin[] memory picked, uint256[] memory skewBps)
        internal
        returns (WeightedHub)
    {
        uint256 n = picked.length;
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](n);
        uint256 each = 10_000 / n;
        uint256 scale = 1;
        for (uint256 i = 0; i < n; ++i) {
            uint256 weight = i == 0 ? 10_000 - each * (n - 1) : each;
            // units = weight · VALUE dollars / price, in raw units: weight/1e4 · VALUE · 1e8 · 10^dec / priceE8.
            uint256 price = uint256(int256(picked[i].priceE8)) * skewBps[i] / 10_000;
            uint256 units = Math.mulDiv(weight * VALUE * 1e8, 10 ** picked[i].decimals, 10_000 * price);
            specs[i] = IWeightedIndexFactory.ComponentSpec({token: picked[i].token, weight: weight, units: units});
            // A share is VALUE dollars, unless a coin's slice would fall under the factory's floor of raw units: Tether
            // Gold, 6 decimals at thousands of dollars, holds under 1e4 of them at a ninetieth of VALUE. Then every
            // slice is scaled by the same factor, which keeps the weights and makes the share worth that much more.
            if (units < factory.MIN_RAW_UNITS()) {
                scale = Math.max(scale, Math.ceilDiv(factory.MIN_RAW_UNITS(), units));
            }
        }
        for (uint256 i = 0; i < n; ++i) {
            specs[i].units *= scale;
        }
        vm.prank(creator);
        return WeightedHub(
            factory.createIndex(
                name,
                name,
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
    }

    function _flat(uint256 n) internal pure returns (uint256[] memory skew) {
        skew = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            skew[i] = 10_000;
        }
    }

    function _issueInKind(WeightedHub index, address who, uint256 shares) internal {
        address[] memory tokens = index.componentTokens();
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(tokens[i], who, IERC20(tokens[i]).balanceOf(who) + need[i]);
        }
        vm.startPrank(who);
        for (uint256 i = 0; i < tokens.length; ++i) {
            IERC20(tokens[i]).forceApprove(address(index), need[i]);
        }
        index.issue(shares, who);
        vm.stopPrank();
    }

    function _assertBacked(WeightedHub index) internal view {
        (address[] memory t, uint256[] memory u) = index.components();
        uint256 supply = index.totalSupply();
        for (uint256 i = 0; i < t.length; ++i) {
            uint256 required = Math.mulDiv(supply, u[i], 1e18) + index.totalClaims(t[i]);
            assertGe(IERC20(t[i]).balanceOf(address(index)), required, "component under-backed");
        }
    }

    /// @dev The fill an executor names for `index` when the market prices each of `picked` at its pool price scaled
    ///      by `moveBps[i]`: toward the units that sit on the weights there, every leg the same share of the way, as far
    ///      as the unit caps let the furthest leg go. The components `leaveMask` names keep their units.
    function _fillUnits(WeightedHub index, Coin[] memory picked, uint256[] memory moveBps, uint256 leaveMask)
        internal
        view
        returns (uint256[] memory fill)
    {
        fill = index.recordedUnits();
        uint256[] memory weights = index.componentWeights();
        uint256 n = fill.length;
        uint256[] memory quotes = new uint256[](n);
        uint256 value = 0;
        uint256 weight = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((leaveMask >> i) & 1 == 1) continue;
            // Dollars per raw unit, scaled by 1e36.
            quotes[i] = uint256(int256(picked[i].priceE8)) * moveBps[i] / 10_000 * 10 ** (28 - picked[i].decimals);
            value += fill[i] * quotes[i];
            weight += weights[i];
        }
        uint256[] memory targets = new uint256[](n);
        uint256 share = 1e18;
        for (uint256 i = 0; i < n; ++i) {
            if ((leaveMask >> i) & 1 == 1) continue;
            uint256 target = Math.mulDiv(value, weights[i], weight * quotes[i], Math.Rounding.Ceil);
            targets[i] = target;
            if (target > fill[i]) share = Math.min(share, Math.mulDiv(fill[i], 1e18, target - fill[i]));
            if (target < fill[i]) share = Math.min(share, Math.mulDiv(fill[i], 0.2e18, fill[i] - target));
        }
        for (uint256 i = 0; i < n; ++i) {
            if ((leaveMask >> i) & 1 == 1) continue;
            if (targets[i] > fill[i]) {
                fill[i] += Math.mulDiv(targets[i] - fill[i], share, 1e18, Math.Rounding.Ceil);
            } else {
                fill[i] -= Math.mulDiv(fill[i] - targets[i], share, 1e18);
            }
        }
    }

    function _openAuction(WeightedHub index, uint256 keepMask, uint256 into) internal {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        if (keepMask != 0) vm.prank(guardian);
        else vm.prank(stranger);
        index.startRebalance(keepMask);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + into);
    }

    /// @dev As the test's own executor: it brings what the index needs from inventory, as a market maker would.
    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory tokens = IWeightedHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsIn[i] == 0) continue;
            deal(tokens[i], address(this), IERC20(tokens[i]).balanceOf(address(this)) + amountsIn[i]);
            IERC20(tokens[i]).safeTransfer(msg.sender, amountsIn[i]);
        }
    }

    function _pick(function(Coin storage) view returns (bool) keep) internal view returns (Coin[] memory picked) {
        uint256 count = 0;
        for (uint256 i = 0; i < coins.length; ++i) {
            if (keep(coins[i])) ++count;
        }
        picked = new Coin[](count);
        uint256 k = 0;
        for (uint256 i = 0; i < coins.length; ++i) {
            if (keep(coins[i])) picked[k++] = coins[i];
        }
    }

    function _dealable(Coin storage c) internal view returns (bool) {
        return c.dealt;
    }

    function _liquid(Coin storage c) internal view returns (bool) {
        return c.dealt && c.routed && c.slippageBps <= 200;
    }

    function _blueChips() internal view returns (Coin[] memory picked) {
        picked = new Coin[](4);
        for (uint256 i = 0; i < 4; ++i) {
            picked[i] = coins[i]; // WETH, WBTC, LINK, UNI: Listings names them first
        }
    }

    // ---------------------------------------------------------------------
    // 1. Every coin, in kind
    // ---------------------------------------------------------------------

    /// @dev Every coin `deal` can fund goes in one index: it issues, rebalances with real transfers of every token, and
    ///      redeems to the last unit. The report says which coins Uniswap can trade, and how well.
    function testFork_everyCoinIssuesRebalancesAndRedeems() public {
        _discover(Listings.COUNT);
        _report();
        Coin[] memory picked = _pick(_dealable);
        console2.log("coins in the index:", picked.length, "of", coins.length);
        assertGe(picked.length, 25, "most of the list can be funded on the fork");

        WeightedHub index = _create("Everything", picked, _flat(picked.length));
        _issueInKind(index, alice, 5e18);
        _assertBacked(index);

        // Prices move: every other coin up 10%, the rest down 10%.
        uint256[] memory moves = new uint256[](picked.length);
        for (uint256 i = 0; i < picked.length; ++i) {
            moves[i] = i % 2 == 0 ? 11_000 : 9000;
        }
        _openAuction(index, 0, index.AUCTION_DURATION() / 2);
        uint256[] memory fill = _fillUnits(index, picked, moves, 0);
        uint256 gasBefore = gasleft();
        index.executeRebalance(fill, "");
        console2.log("gas for a fill of", picked.length, "real tokens:", gasBefore - gasleft());
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);

        // Each weight is back on target at the moved prices, to within rounding. The prices are the ones the fill was
        // named by, truncated to whole 1e-8 dollars: SHIB and PEPE trade near 400 of those, so the untruncated move
        // would be up to 0.25% off the price the fill used.
        (, uint256[] memory units) = index.components();
        uint256 total = 0;
        uint256[] memory values = new uint256[](picked.length);
        for (uint256 i = 0; i < picked.length; ++i) {
            uint256 published = uint256(int256(picked[i].priceE8)) * moves[i] / 10_000;
            values[i] = Math.mulDiv(units[i], published, 10 ** picked[i].decimals);
            total += values[i];
        }
        uint256[] memory weights = index.componentWeights();
        for (uint256 i = 0; i < picked.length; ++i) {
            assertApproxEqRel(values[i] * 10_000, total * weights[i], 0.001e18, "weight back on target");
        }

        // Alice leaves in kind, every token arriving.
        address[] memory tokens = index.componentTokens();
        uint256[] memory expected = index.previewRedeem(5e18);
        vm.prank(alice);
        index.redeem(5e18, alice);
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertGe(IERC20(tokens[i]).balanceOf(alice), expected[i], "every real token redeemed");
        }
        assertEq(index.totalSupply(), 0);
    }

    // ---------------------------------------------------------------------
    // 2. The liquid coins, through the zap and Uniswap
    // ---------------------------------------------------------------------

    /// @dev The coins Uniswap sells $1,000 of within 2% of a $10 sale go in one index, created 5% off its weights.
    ///      Alice mints with USDC through the zap, a Uniswap rebalancer fills at the auction's end, and she burns back
    ///      to USDC.
    function testFork_liquidCoinsThroughTheZapAndAUniswapRebalance() public {
        _discover(Listings.COUNT);
        Coin[] memory picked = _pick(_liquid);
        console2.log("liquid coins (<= 2% slippage on $1,000):", picked.length);
        for (uint256 i = 0; i < picked.length; ++i) {
            console2.log("  ", IERC20Metadata(picked[i].token).symbol(), "slippage bps", picked[i].slippageBps);
        }
        assertGe(picked.length, 4, "at least the first four are liquid");

        uint256[] memory skew = new uint256[](picked.length);
        for (uint256 i = 0; i < picked.length; ++i) {
            skew[i] = i % 2 == 0 ? 10_500 : 9500;
        }
        WeightedHub index = _create("Liquid", picked, skew);

        // Alice mints two tokens, 2 * VALUE dollars at the pools, with USDC.
        IUniversalRouterSwaps.MintLeg[] memory legs = new IUniversalRouterSwaps.MintLeg[](picked.length);
        for (uint256 i = 0; i < picked.length; ++i) {
            legs[i] = IUniversalRouterSwaps.MintLeg({v3Path: picked[i].route, v4Path: new PathKey[](0), maxAmountIn: 0});
        }
        deal(A.USDC, alice, 3 * VALUE * 1e6);
        vm.startPrank(alice);
        IERC20(A.USDC).forceApprove(address(zap), 3 * VALUE * 1e6);
        uint256 spent = zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(index),
                expectedNonce: 0,
                tokenIn: A.USDC,
                maxAmountIn: 3 * VALUE * 1e6,
                shares: 2e18,
                legs: legs,
                to: alice,
                deadline: block.timestamp,
                referrer: address(0)
            })
        );
        vm.stopPrank();
        console2.log("zap mint of 2 tokens cost USDC (6 dec):", spent);
        assertEq(index.balanceOf(alice), 2e18);
        _issueInKind(index, stranger, 50e18); // a larger holder, so the fill trades real size
        _assertBacked(index);

        // A Uniswap rebalancer fills at the auction's end, at the pools' own prices.
        WeightedExecutorV3 executor = new WeightedExecutorV3(ISwapRouter02(A.SWAP_ROUTER_02), A.USDC);
        for (uint256 i = 0; i < picked.length; ++i) {
            executor.setRoute(picked[i].token, picked[i].route);
        }
        deal(A.USDC, address(executor), 100_000e6);
        _openAuction(index, 0, index.AUCTION_DURATION());
        uint256[] memory fill = _fillUnits(index, picked, _flat(picked.length), 0);
        uint256 floatBefore = IERC20(A.USDC).balanceOf(address(executor));
        executor.fill(index, fill);
        uint256 floatAfter = IERC20(A.USDC).balanceOf(address(executor));
        console2.log("rebalancer's float before / after (USDC, 6 dec):", floatBefore, floatAfter);
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);

        // Alice burns both tokens to USDC.
        IUniversalRouterSwaps.BurnLeg[] memory burnLegs = new IUniversalRouterSwaps.BurnLeg[](picked.length);
        for (uint256 i = 0; i < picked.length; ++i) {
            burnLegs[i] =
                IUniversalRouterSwaps.BurnLeg({v3Path: picked[i].route, v4Path: new PathKey[](0), minAmountOut: 0});
        }
        vm.startPrank(alice);
        index.approve(address(zap), 2e18);
        uint256 out = zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(index),
                expectedNonce: 1,
                shares: 2e18,
                tokenOut: A.USDC,
                minAmountOut: 1,
                legs: burnLegs,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        console2.log("zap burn of 2 tokens returned USDC (6 dec):", out);
        assertGt(out * 100, spent * 90, "a mint and burn round trip keeps at least 90%");
    }

    // ---------------------------------------------------------------------
    // 3. Drills, on the first four real coins
    // ---------------------------------------------------------------------

    /// @dev WBTC's real owner pauses it. Holders cannot redeem it but leave with the rest and a claim; the guardian
    ///      rebalances around it; once unpaused, the claim pays.
    function testFork_drill_wbtcPaused() public {
        _discover(4);
        Coin[] memory picked = _blueChips();
        uint256[] memory skew = new uint256[](4);
        (skew[0], skew[1], skew[2], skew[3]) = (11_000, 10_000, 9000, 10_000);
        WeightedHub index = _create("Blue", picked, skew);
        _issueInKind(index, alice, 10e18);

        IWbtcAdmin wbtc = IWbtcAdmin(A.WBTC);
        vm.prank(wbtc.owner());
        wbtc.pause();

        vm.prank(alice);
        vm.expectRevert();
        index.redeem(1e18, alice);
        vm.prank(alice);
        index.redeemSkipping(1e18, alice, 2); // WBTC is component 1
        uint256 owed = index.claimOf(alice, A.WBTC);
        assertGt(owed, 0, "the WBTC stays as Alice's claim");

        // The guardian rebalances everything but WBTC.
        _openAuction(index, 2, index.AUCTION_DURATION() / 2);
        index.executeRebalance(_fillUnits(index, picked, _flat(4), 2), "");
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);

        vm.prank(wbtc.owner());
        wbtc.unpause();
        vm.prank(alice);
        index.claim(A.WBTC, alice);
        assertEq(IERC20(A.WBTC).balanceOf(alice), owed);
    }

    /// @dev An executor that holds no UNI leaves it alone, with no mask and no guardian: it names UNI's own units and
    ///      rebalances the rest among themselves.
    function testFork_drill_anExecutorLeavesACoinAlone() public {
        _discover(4);
        Coin[] memory picked = _blueChips();
        uint256[] memory skew = new uint256[](4);
        (skew[0], skew[1], skew[2], skew[3]) = (11_000, 9000, 10_000, 10_000);
        WeightedHub index = _create("Blue", picked, skew);
        _issueInKind(index, alice, 10e18);

        _openAuction(index, 0, index.AUCTION_DURATION() / 2);
        uint256[] memory before = index.recordedUnits();
        uint256 uniHeld = IERC20(picked[3].token).balanceOf(address(index));
        uint256[] memory fill = _fillUnits(index, picked, _flat(4), 8); // UNI is component 3
        index.executeRebalance(fill, "");
        assertEq(index.recordedUnits()[3], before[3], "UNI untouched");
        assertEq(IERC20(picked[3].token).balanceOf(address(index)), uniHeld);
        // The skew prices WETH a tenth above the market at creation, so the index holds less of it than its weight asks,
        // and more WBTC: a fill toward the weights buys the first and sells the second.
        assertGt(index.recordedUnits()[0], before[0], "WETH, worth less than its weight, was bought");
        assertLt(index.recordedUnits()[1], before[1], "WBTC, worth more than its weight, was sold");
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);
    }

    /// @dev What a fill may ask of an index on its weights: no more than a fifth of any coin, whatever it offers
    ///      (V5-M2), and not even that for a coin poured in to the most a fill accepts. As if UNI were free to mint, an
    ///      executor doubles it and asks for a fifth of the other three: refused. Asking for 15% of them is the most
    ///      that doubling pays for.
    function testFork_drill_noFillTakesMoreThanAFifth() public {
        _discover(4);
        Coin[] memory picked = _blueChips();
        WeightedHub index = _create("Blue", picked, _flat(4));
        _issueInKind(index, alice, 10e18);
        uint256[] memory units = index.recordedUnits();

        _openAuction(index, 0, index.AUCTION_DURATION());
        uint256[] memory fill = new uint256[](4);
        (fill[0], fill[1], fill[2], fill[3]) = (units[0] * 79 / 100, units[1], units[2], units[3] * 2);
        vm.expectPartialRevert(IWeightedHub.LegOutOfBounds.selector);
        index.previewRebalance(fill);

        for (uint256 i = 0; i < 3; ++i) {
            fill[i] = Math.mulDiv(units[i], 8, 10, Math.Rounding.Ceil);
        }
        vm.expectPartialRevert(IWeightedHub.GainBelowBar.selector);
        index.previewRebalance(fill);

        for (uint256 i = 0; i < 3; ++i) {
            fill[i] = Math.mulDiv(units[i], 85, 100, Math.Rounding.Ceil);
        }
        (,, uint256[] memory out,) = index.previewRebalance(fill);
        for (uint256 i = 0; i < 3; ++i) {
            assertLe(out[i], units[i] * 10 * 15 / 100, "at most 15% of each coin's units, for 10 tokens");
        }
        assertEq(out[3], 0);
    }

    /// @dev Nobody fills: the auction expires, a stranger waits out the hold-off, the owner may restart at once.
    function testFork_drill_nobodyFills() public {
        _discover(4);
        Coin[] memory picked = _blueChips();
        uint256[] memory skew = new uint256[](4);
        (skew[0], skew[1], skew[2], skew[3]) = (10_500, 9500, 10_500, 9500);
        WeightedHub index = _create("Blue", picked, skew);
        _issueInKind(index, alice, 10e18);

        _openAuction(index, 0, index.AUCTION_DURATION() + 1);
        uint256[] memory fill = _fillUnits(index, picked, _flat(4), 0);
        (uint256 eta,) = index.pendingRebalance();
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceExpired.selector, eta + index.AUCTION_DURATION()));
        index.executeRebalance(fill, "");
        assertFalse(index.canStartRebalance());
        index.startRebalance(0); // the test contract is the factory's owner
        (uint256 again,) = index.pendingRebalance();
        // Five percent off its weights the index gains 0.12% from a fair fill, which the bar reaches inside three
        // hours.
        vm.warp(again + 3 hours);
        index.executeRebalance(fill, "");
        assertEq(index.rebalanceNonce(), 1);
    }
}
