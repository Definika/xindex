// SPDX-License-Identifier: MIT
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
import {IWeightedHub} from "../../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../../src/interfaces/IWeightedIndexFactory.sol";
import {IRebalanceExecutor} from "../../src/interfaces/IRebalanceExecutor.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {PythStructs} from "../../src/interfaces/pyth/PythStructs.sol";
import {PythIds} from "../../script/PythIds.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {ISwapRouter02} from "../mocks/ISwapRouter02.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
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

/// @notice v5 on a mainnet fork, with every coin of the Ethereum list (49: the first four and the wide list), real
///         token contracts and real Uniswap pools. Only Pyth is a stand-in, since real
///         signed updates need an API key; its prices come from the pools, as Pyth's track the market.
///
///         It answers what the unit tests cannot: does every real token issue, redeem and rebalance through the hub;
///         which coins can Uniswap actually trade, at what slippage; does the zap mint and burn a weighted index
///         through real pools; does a Uniswap rebalancer settle at a profit; and what happens, with real tokens, when
///         WBTC is paused, a feed goes silent, a price is wrong or nobody fills. Skips when MAINNET_RPC_URL is unset.
contract WeightedHubForkTest is Test, IRebalanceExecutor {
    using SafeERC20 for IERC20;

    MockPyth pyth;
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
        bytes32 id;
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

        pyth = new MockPyth();
        factory = new WeightedIndexFactory(address(this), guardian, address(pyth));
        zap = new IndexZap(IIndexFactory(address(factory)), IUniversalRouter(A.UNIVERSAL_ROUTER));

        (address[] memory tokens, bytes32[] memory ids) = PythIds.all();
        for (uint256 i = 0; i < tokens.length; ++i) {
            factory.proposeListing(tokens[i], ids[i]);
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
        (address[] memory tokens, bytes32[] memory ids) = PythIds.all();
        for (uint256 i = 0; i < count; ++i) {
            Coin memory c;
            c.token = tokens[i];
            c.id = ids[i];
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
        return WeightedHub(factory.createIndex(name, name, specs));
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

    /// @dev Pyth updates at the index's price time for `picked`, each price scaled by `moveBps[i]`, skipping the
    ///      components `skipMask` names.
    function _updates(WeightedHub index, Coin[] memory picked, uint256[] memory moveBps, uint256 skipMask)
        internal
        view
        returns (bytes[] memory data)
    {
        uint64 time = uint64(index.priceTime());
        uint256 count = 0;
        for (uint256 i = 0; i < picked.length; ++i) {
            if ((skipMask >> i) & 1 == 0) ++count;
        }
        data = new bytes[](count);
        uint256 k = 0;
        for (uint256 i = 0; i < picked.length; ++i) {
            if ((skipMask >> i) & 1 == 1) continue;
            int64 price = int64(int256(uint256(int256(picked[i].priceE8)) * moveBps[i] / 10_000));
            data[k++] = pyth.update(picked[i].id, price, uint64(price) / 1000, -8, time, time - 1);
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
            picked[i] = coins[i]; // WETH, WBTC, LINK, UNI: PythIds lists them first
        }
    }

    // ---------------------------------------------------------------------
    // 1. Every coin, in kind
    // ---------------------------------------------------------------------

    /// @dev Every coin `deal` can fund goes in one index: it issues, rebalances with real transfers of every token, and
    ///      redeems to the last unit. The report says which coins Uniswap can trade, and how well.
    function testFork_everyCoinIssuesRebalancesAndRedeems() public {
        _discover(PythIds.COUNT);
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
        bytes[] memory data = _updates(index, picked, moves, 0);
        uint256 gasBefore = gasleft();
        index.executeRebalance("", data);
        console2.log("gas for a fill of", picked.length, "real tokens (mock Pyth parse):", gasBefore - gasleft());
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);

        // Each weight is back on target at the moved prices, to within rounding. The prices are the ones `_updates`
        // published, truncated to whole 1e-8 dollars: SHIB and PEPE trade near 400 of those, so the untruncated move
        // would be up to 0.25% off the price the hub settled at.
        (, uint256[] memory units) = index.components();
        uint256 total = 0;
        uint256[] memory values = new uint256[](picked.length);
        for (uint256 i = 0; i < picked.length; ++i) {
            uint256 published = uint256(int256(picked[i].priceE8)) * moves[i] / 10_000;
            values[i] = Math.mulDiv(units[i], published, 10 ** picked[i].decimals);
            total += values[i];
        }
        (uint256[] memory weights,,) = index.componentTerms();
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
        _discover(PythIds.COUNT);
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
        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](picked.length);
        for (uint256 i = 0; i < picked.length; ++i) {
            legs[i] = IIndexZap.MintLeg({v3Path: picked[i].route, v4Path: new PathKey[](0), maxAmountIn: 0});
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
                deadline: block.timestamp
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
        bytes[] memory data = _updates(index, picked, _flat(picked.length), 0);
        uint256 floatBefore = IERC20(A.USDC).balanceOf(address(executor));
        executor.fill(index, data);
        uint256 floatAfter = IERC20(A.USDC).balanceOf(address(executor));
        console2.log("rebalancer's float before / after (USDC, 6 dec):", floatBefore, floatAfter);
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);

        // Alice burns both tokens to USDC.
        IIndexZap.BurnLeg[] memory burnLegs = new IIndexZap.BurnLeg[](picked.length);
        for (uint256 i = 0; i < picked.length; ++i) {
            burnLegs[i] = IIndexZap.BurnLeg({v3Path: picked[i].route, v4Path: new PathKey[](0), minAmountOut: 0});
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
        bytes[] memory data = _updates(index, picked, _flat(4), 2);
        index.executeRebalance("", data);
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);

        vm.prank(wbtc.owner());
        wbtc.unpause();
        vm.prank(alice);
        index.claim(A.WBTC, alice);
        assertEq(IERC20(A.WBTC).balanceOf(alice), owed);
    }

    /// @dev Pyth goes silent for UNI: no fill can settle, since UNI's update is missing. The guardian cancels and
    ///      restarts with UNI kept, and the rest rebalance.
    function testFork_drill_aFeedGoesSilent() public {
        _discover(4);
        Coin[] memory picked = _blueChips();
        uint256[] memory skew = new uint256[](4);
        (skew[0], skew[1], skew[2], skew[3]) = (11_000, 9000, 10_000, 10_000);
        WeightedHub index = _create("Blue", picked, skew);
        _issueInKind(index, alice, 10e18);

        _openAuction(index, 0, index.AUCTION_DURATION() / 2);
        bytes[] memory data = _updates(index, picked, _flat(4), 8); // UNI is component 3
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        index.executeRebalance("", data);

        vm.prank(guardian);
        index.cancelRebalance();
        vm.prank(guardian);
        index.startRebalance(8);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + 1 hours);
        data = _updates(index, picked, _flat(4), 8);
        (, uint256[] memory before) = index.components();
        index.executeRebalance("", data);
        (, uint256[] memory afterwards) = index.components();
        assertEq(afterwards[3], before[3], "UNI untouched");
        assertEq(index.rebalanceNonce(), 1);
    }

    /// @dev A wrong price: Pyth reports UNI at a hundredth of its value. The fill would buy UNI with everything else,
    ///      but sends out at most a fifth of each coin it sells (V5-M2); the guardian cancels instead of letting it fill.
    function testFork_drill_aWrongPriceTakesAtMostAFifth() public {
        _discover(4);
        Coin[] memory picked = _blueChips();
        WeightedHub index = _create("Blue", picked, _flat(4));
        _issueInKind(index, alice, 10e18);
        (, uint256[] memory units) = index.components();

        _openAuction(index, 0, index.AUCTION_DURATION());
        uint256[] memory moves = _flat(4);
        moves[3] = 100; // UNI is component 3
        bytes[] memory data = _updates(index, picked, moves, 0);
        (,, uint256[] memory out,) = index.previewRebalance(_structs(picked, moves));
        for (uint256 i = 0; i < 4; ++i) {
            assertLe(out[i], units[i] * 10 / 5, "at most a fifth of each coin's units, for 10 tokens");
        }
        vm.prank(guardian);
        index.cancelRebalance();
        vm.expectRevert(IWeightedHub.NoPendingRebalance.selector);
        index.executeRebalance("", data);
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
        bytes[] memory data = _updates(index, picked, _flat(4), 0);
        (uint256 eta,) = index.pendingRebalance();
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceExpired.selector, eta + index.AUCTION_DURATION()));
        index.executeRebalance("", data);
        assertFalse(index.canStartRebalance());
        index.startRebalance(0); // the test contract is the factory's owner
        (uint256 again,) = index.pendingRebalance();
        vm.warp(again + 1 hours);
        index.executeRebalance("", _updates(index, picked, _flat(4), 0));
        assertEq(index.rebalanceNonce(), 1);
    }

    function _structs(Coin[] memory picked, uint256[] memory moves)
        internal
        pure
        returns (PythStructs.Price[] memory out)
    {
        out = new PythStructs.Price[](picked.length);
        for (uint256 i = 0; i < picked.length; ++i) {
            out[i] = PythStructs.Price({
                price: int64(int256(uint256(int256(picked[i].priceE8)) * moves[i] / 10_000)),
                conf: 0,
                expo: -8,
                publishTime: 0
            });
        }
    }
}
