// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {VmSafe} from "forge-std/Vm.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedMath} from "../src/WeightedMath.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IPythPrices} from "../src/interfaces/IPythPrices.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {WeightedTest} from "./WeightedTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockVault, MockMultiplierToken} from "./mocks/MockPricedTokens.sol";
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";
import {HoldingExecutor} from "./WeightedHub.rebalance.t.sol";

/// @notice Pyth's check on a rebalance fill (the owner's call of 2026-11-22): a fill the units accept must also bring
///         in, at Pyth's prices, at least what it takes less a tolerance that rises from nothing to 2% over the auction.
///         The check can only refuse: no price reaches an issue, a redeem or a claim, and a fill the units refuse is
///         refused whatever the prices say.
contract WeightedHubOracleTest is WeightedTest {
    uint256 constant SHARES = 100e18;
    bytes32 constant ETH_FEED = keccak256("ETH/USD");
    bytes32 constant BTC_FEED = keccak256("BTC/USD");
    bytes32 constant USD_FEED = keccak256("USD/USD");

    MockPyth pyth;
    IPythPrices prices;
    WeightedMath math;
    WeightedHub index;
    MockWeightedExecutor executor;

    function setUp() public {
        vm.warp(1_800_000_000);
        pyth = new MockPyth();
        factory = new WeightedIndexFactory(owner, guardian, address(pyth), address(new WeightedMath()));
        prices = IPythPrices(factory.PRICES());
        _approveCreator(creator);
        eth = new MockERC20("Ether", "ETH", 18);
        btc = new MockERC20("Bitcoin", "BTC", 8);
        usd = new MockERC20("Dollar", "USD", 6);
        _listAll();
        _post(ETH_PRICE, BTC_PRICE, USD_PRICE);
        _setFeed(address(eth), ETH_FEED, IPythPrices.FeedKind.Token);
        _setFeed(address(btc), BTC_FEED, IPythPrices.FeedKind.Token);
        _setFeed(address(usd), USD_FEED, IPythPrices.FeedKind.Token);
        index = _create(_defaultSpecs());
        math = WeightedMath(index.MATH());
        _issue(index, alice, SHARES);
        executor = new MockWeightedExecutor();
    }

    /// @dev Sets `token`'s feed through the factory's timelock.
    function _setFeed(address token, bytes32 id, IPythPrices.FeedKind kind) internal {
        vm.prank(owner);
        factory.proposePriceFeed(token, IPythPrices.PriceFeed({id: id, kind: kind}));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executePriceFeed(token);
    }

    /// @dev Posts the three default coins' prices, in dollars per whole token, as fresh at every block.
    function _post(uint256 ethDollars, uint256 btcDollars, uint256 usdDollars) internal {
        pyth.setLivePrice(ETH_FEED, int64(int256(ethDollars * 1e8)), 0, -8);
        pyth.setLivePrice(BTC_FEED, int64(int256(btcDollars * 1e8)), 0, -8);
        pyth.setLivePrice(USD_FEED, int64(int256(usdDollars * 1e8)), 0, -8);
    }

    /// @dev Starts a rebalance once the interval has passed and moves `into` seconds into its auction.
    function _open(uint256 into) internal {
        vm.warp(index.earliestRebalance());
        index.startRebalance(0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + into);
    }

    function _three(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory u) {
        u = new uint256[](3);
        (u[0], u[1], u[2]) = (a, b, c);
    }

    /// @dev `fair` with each rising leg's increase cut by `cutBps`: the fill keeps that much of what it should bring in.
    function _greedy(uint256[] memory fair, uint256 cutBps) internal view returns (uint256[] memory units) {
        uint256[] memory current = index.recordedUnits();
        units = new uint256[](fair.length);
        for (uint256 i = 0; i < fair.length; ++i) {
            units[i] = fair[i] > current[i] ? current[i] + (fair[i] - current[i]) * (1e4 - cutBps) / 1e4 : fair[i];
        }
    }

    // ---------------------------------------------------------------------
    // The tolerance
    // ---------------------------------------------------------------------

    /// @dev The tolerance is nothing at the auction's first second and 2% at its last, along a straight line, rounded
    ///      down; past the auction there is none to ask.
    function test_theToleranceRisesFromNothingToTwoPercent() public {
        uint256 duration = math.AUCTION_DURATION();
        assertEq(math.MAX_ORACLE_TOLERANCE(), 0.02e18);
        assertEq(math.oracleToleranceAt(0), 0);
        assertEq(math.oracleToleranceAt(duration / 2), 0.01e18);
        assertEq(math.oracleToleranceAt(duration), 0.02e18);
        assertEq(math.oracleToleranceAt(1), uint256(0.02e18) / duration, "rounded down");
        assertEq(math.oracleToleranceAt(7), uint256(0.02e18) * 7 / duration);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.AuctionOver.selector, duration + 1));
        math.oracleToleranceAt(duration + 1);
    }

    // ---------------------------------------------------------------------
    // Fair and unfair fills
    // ---------------------------------------------------------------------

    /// @dev A fill on the weights at the market's prices, which Pyth reports, gives up nothing at those prices: it
    ///      passes at the second the bar first clears, whatever the tolerance then.
    function test_aFairFillPassesAsSoonAsTheBarClears() public {
        _post(2500, BTC_PRICE, USD_PRICE);
        _open(0);
        uint256[] memory fair = _onWeights(index, _market(2500, BTC_PRICE, USD_PRICE));
        _warpToFirstFill(index, fair);
        (uint256 eta,) = index.pendingRebalance();
        assertLt(block.timestamp - eta, 2 hours, "it clears in the first half, at a tolerance under 1%");
        executor.execute(index, fair, "");
        assertEq(index.recordedUnits(), fair);
    }

    /// @dev A fill that keeps 1% of what it should bring in passes the units' bar early, and Pyth refuses it until the
    ///      tolerance reaches 1%, half way through the auction. One that keeps 3% is refused even at the last second,
    ///      where the tolerance is 2%. On units alone a lone executor at the last second keeps the index's whole
    ///      distance from its weights; under the check it keeps at most 2% of what it trades.
    function test_aLoneExecutorKeepsAtMostTheTolerance() public {
        _post(2500, BTC_PRICE, USD_PRICE);
        _open(0);
        uint256[] memory fair = _onWeights(index, _market(2500, BTC_PRICE, USD_PRICE));
        uint256[] memory keepsOne = _greedy(fair, 100);
        uint256[] memory keepsThree = _greedy(fair, 300);
        (uint256 eta,) = index.pendingRebalance();
        uint256 duration = index.AUCTION_DURATION();

        vm.warp(eta + duration / 2 - 10 minutes);
        vm.expectPartialRevert(IWeightedHub.BelowOracleValue.selector);
        index.previewRebalance(keepsOne);

        vm.warp(eta + duration);
        vm.expectPartialRevert(IWeightedHub.BelowOracleValue.selector);
        index.previewRebalance(keepsThree);
        (uint256 bar, int256 gain,,) = _settlementOnUnits(keepsThree);
        assertGt(gain, int256(bar), "the units alone accept what Pyth refuses");

        vm.warp(eta + duration / 2 + 10 minutes);
        executor.execute(index, keepsOne, "");
        assertEq(index.recordedUnits(), keepsOne);
    }

    /// @dev The settlement on units alone, as `WeightedMath` judges it, without the value checks.
    function _settlementOnUnits(uint256[] memory newUnits)
        internal
        view
        returns (uint256 bar, int256 gain, uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        (uint256 eta,) = index.pendingRebalance();
        return math.settlement(
            block.timestamp - eta,
            index.totalSupply(),
            1e18,
            index.recordedUnits(),
            newUnits,
            index.componentWeights(),
            0
        );
    }

    /// @dev MAX_WEIGHT_DEVIATION: at Pyth's prices each leg's share of a new index's value lies within 5% of its
    ///      weight, relative to it, or the creation reverts OffWeights. A 50/50 index of ETH and dollars named 90/10 by
    ///      value is refused, the drain the design rule "An index created off its weights" describes; 51.25/48.75 is
    ///      2.5% off each weight and passes, 52.5/47.5 exactly 5% and passes, and 52.7/47.3 is 5.4% off the dollars' and
    ///      is refused.
    function test_anIndexIsCreatedOnItsWeights() public {
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        IWeightedIndexFactory.IndexParams memory params = _params();
        specs[0] = _spec(address(eth), 5000, 0.045e18); // $90
        specs[1] = _spec(address(usd), 5000, 10e6); // $10
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.OffWeights.selector, address(eth), 5000, 9000));
        factory.createIndex("Skewed", "SKW", specs, params);

        specs[0] = _spec(address(eth), 5000, 0.025625e18); // $51.25
        specs[1] = _spec(address(usd), 5000, 48.75e6); // $48.75
        assertEq(_create(specs).componentWeights()[0], 5000, "within 5% of each weight");

        specs[0] = _spec(address(eth), 5000, 0.02625e18); // $52.50
        specs[1] = _spec(address(usd), 5000, 47.5e6); // $47.50
        assertEq(_create(specs).componentWeights()[1], 5000, "exactly 5% off each weight still passes");

        specs[0] = _spec(address(eth), 5000, 0.02635e18); // $52.70
        specs[1] = _spec(address(usd), 5000, 47.3e6); // $47.30
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.OffWeights.selector, address(eth), 5000, 5270));
        factory.createIndex("Skewed", "SKW", specs, params);
    }

    /// @dev What an index off its weights invites, now only once the market has moved it there: a 50/50 index of ETH
    ///      and dollars created on its weights, after which ETH rises ninefold, so it stands 90/10 by value. A lone
    ///      executor fills at the last second, ETH down a fifth and dollars up a quarter, which keeps the weighted
    ///      product: on units alone that fill takes 15.5% of the index's value. Pyth refuses it; a fill worth what it
    ///      takes passes.
    function test_aLoneExecutorCannotTakeTheDistanceAMarketMoveOpened() public {
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = _spec(address(eth), 5000, 0.045e18);
        specs[1] = _spec(address(usd), 5000, 10e6);
        // $10 of each at ETH a ninth of its price, then ETH back at its price: $90 and $10.
        _post2(ETH_PRICE / 9);
        WeightedHub skewed = _create(specs);
        _post2(ETH_PRICE);
        _issue(skewed, alice, SHARES);
        vm.warp(skewed.earliestRebalance());
        skewed.startRebalance(0);
        (uint256 eta,) = skewed.pendingRebalance();
        vm.warp(eta + skewed.AUCTION_DURATION());

        uint256[] memory drain = new uint256[](2);
        // A dollar leg a hair over the quarter, since L runs under the logarithm.
        (drain[0], drain[1]) = (0.036e18, 12.51e6);
        uint256[] memory current = skewed.recordedUnits();
        uint256[] memory weights = skewed.componentWeights();
        (uint256 bar, int256 gain, uint256[] memory out, uint256[] memory into) =
            math.settlement(skewed.AUCTION_DURATION(), skewed.totalSupply(), 1e18, current, drain, weights, 0);
        assertGe(gain, int256(bar), "the units alone accept the drain");
        uint256 takenDollars = out[0] * ETH_PRICE / 1e18 - into[1] / 1e6;
        assertEq(takenDollars * 100 / (SHARES / 1e18 * 100), 15, "15.5% of the index's value");
        vm.expectPartialRevert(IWeightedHub.BelowOracleValue.selector);
        executor.execute(skewed, drain, "");

        // Worth what it takes: a tenth of the ETH out, its whole value in dollars back.
        uint256[] memory fair = new uint256[](2);
        (fair[0], fair[1]) = (0.0405e18, 19e6);
        executor.execute(skewed, fair, "");
        assertEq(skewed.recordedUnits(), fair);
    }

    // ---------------------------------------------------------------------
    // The check can only refuse
    // ---------------------------------------------------------------------

    /// @dev A fill the units refuse is refused whatever Pyth says: with ETH reported at a tenth of its price, a fill
    ///      that sells too much ETH for too little is still stopped by the bar, before any price is read.
    function test_aWrongPriceCannotPassAFillTheUnitsRefuse() public {
        _post(ETH_PRICE / 10, BTC_PRICE, USD_PRICE);
        _open(0);
        uint256[] memory units = index.recordedUnits();
        units[0] = units[0] * 79 / 100;
        vm.expectPartialRevert(IWeightedHub.LegOutOfBounds.selector);
        executor.execute(index, units, "");
        units[0] = index.recordedUnits()[0] * 9 / 10;
        vm.expectPartialRevert(IWeightedHub.GainBelowBar.selector);
        executor.execute(index, units, "");
    }

    /// @dev No issue, redeem or claim reads a price. With Pyth's contract answering nothing at all, holders still mint
    ///      and leave, in full and skipping a leg, a claim is paid and a rebalance starts; only the fill stops.
    function test_exitsAndMintsReadNoPrice() public {
        pyth.setBroken(true);
        _issue(index, alice, 1e18);
        vm.prank(alice);
        index.redeem(1e18, alice);
        vm.prank(alice);
        index.redeemSkipping(1e18, alice, 1);
        vm.prank(alice);
        assertGt(index.claim(address(eth), alice), 0, "the skipped leg's claim is paid");

        _open(2 hours);
        uint256[] memory fair = _onWeights(index, _market(2500, BTC_PRICE, USD_PRICE));
        vm.expectRevert("pyth is down");
        executor.execute(index, fair, "");
        vm.prank(guardian);
        index.cancelRebalance();
    }

    // ---------------------------------------------------------------------
    // What a price must be
    // ---------------------------------------------------------------------

    /// @dev The legs a fill moves are valued, and only those: a leg without a feed stops a fill that moves it, and a
    ///      fill that leaves it at its units passes.
    function test_aLegWithoutAFeedStopsOnlyAFillThatMovesIt() public {
        _setFeed(address(usd), bytes32(0), IPythPrices.FeedKind.None);
        _post(2500, BTC_PRICE, USD_PRICE);
        _open(2 hours);
        uint256[] memory moved = _onWeights(index, _market(2500, BTC_PRICE, USD_PRICE));
        vm.expectRevert(abi.encodeWithSelector(IPythPrices.NoPriceFeed.selector, address(usd)));
        executor.execute(index, moved, "");

        uint256[] memory leftAlone = _onWeights(index, _market(2500, BTC_PRICE, USD_PRICE), 4);
        executor.execute(index, leftAlone, "");
        assertEq(index.recordedUnits()[2], USD_UNITS, "the dollar leg kept its units");
    }

    /// @dev A price published more than a minute before the fill values nothing.
    function test_aStalePriceStopsTheFill() public {
        _open(2 hours);
        uint256 published = block.timestamp - 61;
        pyth.setPrice(ETH_FEED, 2500e8, 0, -8, published);
        uint256[] memory fair = _onWeights(index, _market(2500, BTC_PRICE, USD_PRICE));
        vm.expectRevert(abi.encodeWithSelector(IPythPrices.StalePrice.selector, address(eth), published));
        executor.execute(index, fair, "");
        // Exactly a minute old is still fresh.
        pyth.setPrice(ETH_FEED, 2500e8, 0, -8, published + 1);
        executor.execute(index, fair, "");
    }

    /// @dev Posts ETH alone at `ethDollars`, fresh, leaving the other two as they are.
    function _post2(uint256 ethDollars) internal {
        pyth.setLivePrice(ETH_FEED, int64(int256(ethDollars * 1e8)), 0, -8);
    }

    /// @dev A price that is not positive, no wider than its confidence, or of an exponent past what a value can take,
    ///      values nothing.
    function test_anUnusablePriceStopsTheFill() public {
        int64[3] memory badPrices = [int64(0), -1, 2500e8];
        uint64[3] memory confs = [uint64(0), 0, 2500e8];
        for (uint256 i = 0; i < 3; ++i) {
            pyth.setLivePrice(ETH_FEED, badPrices[i], confs[i], -8);
            vm.expectRevert(abi.encodeWithSelector(IPythPrices.UnusablePrice.selector, address(eth)));
            prices.valueOf(address(eth), true);
        }
        int32[2] memory badExpos = [int32(-37), 19];
        for (uint256 i = 0; i < 2; ++i) {
            pyth.setLivePrice(ETH_FEED, 2500e8, 0, badExpos[i]);
            vm.expectRevert(abi.encodeWithSelector(IPythPrices.UnusablePrice.selector, address(eth)));
            prices.valueOf(address(eth), true);
        }
        // The edges of the exponent's range value something.
        pyth.setLivePrice(ETH_FEED, 1, 0, -36);
        assertEq(prices.valueOf(address(eth), true), 1, "a value that rounds up to one raw unit's least");
        // Where it arrives it rounds down to nothing, and nothing is no price: refused, not valued at zero.
        vm.expectRevert(abi.encodeWithSelector(IPythPrices.UnusablePrice.selector, address(eth)));
        prices.valueOf(address(eth), false);
        pyth.setLivePrice(ETH_FEED, 1, 0, 18);
        assertEq(prices.valueOf(address(eth), true), 1e36);
        // A value past what the math can sum is refused, as no listed coin would reach.
        pyth.setLivePrice(ETH_FEED, type(int64).max, 0, 18);
        vm.expectRevert(abi.encodeWithSelector(IPythPrices.UnusablePrice.selector, address(eth)));
        prices.valueOf(address(eth), true);
    }

    /// @dev Pyth's confidence leans against the executor: what leaves is valued at the price plus it, rounded up, and
    ///      what arrives at the price less it, rounded down. A dollar per whole token of 6 decimals is 1e30 a raw unit.
    function test_theConfidenceLeansAgainstTheExecutor() public {
        pyth.setLivePrice(USD_FEED, 1e8, 0.01e8, -8);
        assertEq(prices.valueOf(address(usd), true), 1.01e30, "leaving: the price plus its confidence");
        assertEq(prices.valueOf(address(usd), false), 0.99e30, "arriving: the price less it");
        pyth.setLivePrice(BTC_FEED, 3, 0, 0);
        assertEq(prices.valueOf(address(btc), true), 3e28, "three dollars a bitcoin is 3e28 a satoshi");
        pyth.setLivePrice(ETH_FEED, 1, 0, -33);
        assertEq(prices.valueOf(address(eth), true), 1, "1e-33 dollars per ether is under one value unit a wei: up");
        // Down, it comes to nothing, which is no price: `test_anUnusablePriceStopsTheFill`.
        vm.expectRevert(abi.encodeWithSelector(IPythPrices.UnusablePrice.selector, address(eth)));
        prices.valueOf(address(eth), false);

        uint256[] memory current = _three(10, 10, 10);
        uint256[] memory next = _three(9, 10, 11);
        uint256[] memory values = prices.legValues(index.componentTokens(), current, next);
        assertEq(values[0], 1, "the falling leg is valued as leaving");
        assertEq(values[1], 0, "the leg that keeps its units is not read");
        assertEq(values[2], 0.99e30, "the rising leg as arriving");
    }

    /// @dev A vault's feed prices its asset, and one whole vault token is worth `convertToAssets` of it, read at the
    ///      fill; a stock token's feed prices one share, and one token stands for `multiplier()` of them.
    function test_aVaultAndAStockTokenAreValuedAtTheirRate() public {
        MockERC20 share = new MockERC20("Share", "SHR", 18);
        MockVault vault = new MockVault(share);
        vault.mint(address(this), 1e18);
        share.mint(address(vault), 1e18); // the vault now holds two shares for each of its tokens
        MockMultiplierToken stock = new MockMultiplierToken(8);
        stock.setMultiplier(8e18);
        _list(address(vault));
        _list(address(stock));
        bytes32 shareFeed = keccak256("SHR/USD");
        pyth.setLivePrice(shareFeed, 100e8, 0, -8);
        _setFeed(address(vault), shareFeed, IPythPrices.FeedKind.Vault);
        _setFeed(address(stock), shareFeed, IPythPrices.FeedKind.Multiplier);

        assertEq(vault.convertToAssets(1e18), 2e18 - 1, "about two shares a vault token, rounded down");
        assertEq(prices.valueOf(address(vault), true), (2e18 - 1) * 100 * 1e36 / 1e36, "$200 a whole vault token");
        assertEq(prices.valueOf(address(stock), true), 800e28, "$800 a whole stock token of 8 decimals");
        stock.setMultiplier(1e18);
        assertEq(prices.valueOf(address(stock), true), 100e28, "the multiplier is read at each valuation");
        // A multiplier of zero would value the token at nothing, and a leg that leaves at nothing is free to take by
        // Pyth's measure. It is refused instead, both ways, so a fill that moves the token waits.
        stock.setMultiplier(0);
        vm.expectRevert(abi.encodeWithSelector(IPythPrices.UnusablePrice.selector, address(stock)));
        prices.valueOf(address(stock), true);
        vm.expectRevert(abi.encodeWithSelector(IPythPrices.UnusablePrice.selector, address(stock)));
        prices.valueOf(address(stock), false);
    }

    /// @dev Both refusals apply to a quoted proposal: the quote's, at the guardian's prices, and Pyth's.
    function test_aQuoteAndPythBothRefuse() public {
        _post(2500, BTC_PRICE, USD_PRICE);
        vm.warp(index.earliestRebalance());
        uint256[] memory quoted = _market(2500, BTC_PRICE, USD_PRICE);
        vm.prank(guardian);
        index.startRebalance(0, quoted, 0.03e18);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + 2 hours);
        uint256[] memory fair = _onWeights(index, quoted);
        uint256[] memory keepsOne = _greedy(fair, 100);
        vm.expectPartialRevert(IWeightedHub.BelowOracleValue.selector);
        executor.execute(index, keepsOne, "");

        // The quote binds where Pyth is lenient: ETH reported cheaper than the guardian quoted it.
        _post(1000, BTC_PRICE, USD_PRICE);
        uint256[] memory keepsFive = _greedy(fair, 500);
        vm.expectPartialRevert(IWeightedHub.BelowQuote.selector);
        executor.execute(index, keepsFive, "");
        _post(2500, BTC_PRICE, USD_PRICE);
        executor.execute(index, fair, "");
    }

    /// @dev A kept leg keeps its units, so its price is never read, even under a feed that stopped answering.
    function test_aKeptLegIsNotRead() public {
        pyth.setPrice(BTC_FEED, 60_000e8, 0, -8, block.timestamp);
        _post2(2500);
        pyth.setLivePrice(USD_FEED, 1e8, 0, -8);
        vm.warp(index.earliestRebalance());
        vm.prank(guardian);
        index.startRebalance(2);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + 2 hours);
        uint256[] memory fill = _onWeights(index, _market(2500, BTC_PRICE, USD_PRICE), 2);
        executor.execute(index, fill, "");
        assertEq(index.recordedUnits()[1], BTC_UNITS, "the kept leg's stale price was never read");
    }

    /// @dev The preview runs the same check, so a filler's simulation sees the refusal its fill would meet.
    function test_thePreviewChecksPythToo() public {
        _post(2500, BTC_PRICE, USD_PRICE);
        _open(0);
        uint256[] memory greedy = _greedy(_onWeights(index, _market(2500, BTC_PRICE, USD_PRICE)), 300);
        vm.warp(block.timestamp + 2 hours);
        vm.expectPartialRevert(IWeightedHub.BelowOracleValue.selector);
        index.previewRebalance(greedy);
    }

    /// @dev At MAX_COMPONENTS, two hundred legs, the creation that values every leg at its Pyth price, and a fill that
    ///      moves every one of them, each valued at its Pyth price, each fit five sixths of EIP-7825's 2^24 cap,
    ///      measured as `test_theMostComponentsFitOneTransaction` measures them without an oracle: every touched account
    ///      cold, an executor that already holds the tokens. The index starts on its weights at one price for every
    ///      leg, as creation requires, and the market then moves every leg a tenth, so the fill moves them all. Pyth's
    ///      own contract reads dearer than this mock, and the fork suites measure it.
    function test_theMostComponentsFillUnderPythsCheckInOneTransaction() public {
        uint256 n = factory.MAX_COMPONENTS();
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](n);
        address[] memory tokens = new address[](n);
        uint256[] memory market = new uint256[](n);
        bytes32[] memory ids = new bytes32[](n);
        vm.startPrank(owner);
        for (uint256 i = 0; i < n; ++i) {
            MockERC20 token = new MockERC20("T", "T", 18);
            tokens[i] = address(token);
            factory.proposeListing(address(token));
            bytes32 id = keccak256(abi.encode("feed", i));
            ids[i] = id;
            market[i] = i % 2 == 0 ? 110 : 90;
            pyth.setLivePrice(id, 100e8, 0, -8);
            factory.proposePriceFeed(address(token), IPythPrices.PriceFeed({id: id, kind: IPythPrices.FeedKind.Token}));
            specs[i] = _spec(address(token), 10_000 / n, 1e18);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < n; ++i) {
            factory.executeListing(tokens[i]);
            factory.executePriceFeed(tokens[i]);
        }
        for (uint256 i = 0; i < n; ++i) {
            vm.cool(tokens[i]);
        }
        vm.cool(address(factory));
        vm.cool(address(pyth));
        vm.cool(factory.PRICES());
        IWeightedIndexFactory.IndexParams memory params = _params();
        vm.prank(creator);
        uint256 before = gasleft();
        WeightedHub wide = WeightedHub(factory.createIndex("Wide", "WIDE", specs, params));
        uint256 creation = before - gasleft();
        emit log_named_uint("createIndex under Pyth's check", creation);
        // as below, the bound is the release build's: `forge coverage`'s unoptimized build costs more
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) assertLt(creation, uint256(1 << 24) * 5 / 6);
        _issue(wide, alice, 2e18);
        for (uint256 i = 0; i < n; ++i) {
            pyth.setLivePrice(ids[i], int64(int256(market[i] * 1e8)), 0, -8);
        }

        vm.warp(wide.earliestRebalance());
        wide.startRebalance(0);
        (uint256 eta,) = wide.pendingRebalance();
        vm.warp(eta + wide.AUCTION_DURATION() / 2);
        uint256[] memory fill = _onWeights(wide, market);
        HoldingExecutor holder = new HoldingExecutor();
        for (uint256 i = 0; i < n; ++i) {
            MockERC20(tokens[i]).mint(address(holder), 2e18);
            vm.cool(tokens[i]);
        }
        vm.cool(address(factory));
        vm.cool(factory.IMPLEMENTATION());
        vm.cool(address(wide));
        vm.cool(wide.MATH());
        vm.cool(wide.PRICES());
        vm.cool(address(pyth));
        vm.cool(address(holder));
        before = gasleft();
        holder.execute(wide, fill);
        uint256 used = before - gasleft();
        emit log_named_uint("executeRebalance under Pyth's check", used);
        // `forge coverage` compiles without the optimizer, which costs this fill 16.2M where the release build's is
        // 12.7M: the bound is the release build's, as test_CF5's pin is.
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) assertLt(used, uint256(1 << 24) * 5 / 6);
        assertEq(wide.rebalanceNonce(), 1);
    }

    /// @dev The widest index a creation with its first issue is measured at.
    uint256 constant WIDEST_FIRST_ISSUE = 125;

    /// @dev Creating an index and issuing its first shares in one call costs about what the two cost apart, some
    ///      110,000 gas a component. So it fits five sixths of EIP-7825's 2^24 cap up to a hundred and twenty-five
    ///      components (13.4M), under Pyth's check and with every touched account cold. At MAX_COMPONENTS it passes
    ///      the cap itself, and such an index is created with `createIndex` and issued afterwards, each of which fits
    ///      on its own (`test_theMostComponentsFitOneTransaction`). Real tokens transfer dearer than these mocks.
    function test_aCreationWithItsFirstIssueFitsOneTransaction() public {
        uint256 used = _createAndIssueWide(WIDEST_FIRST_ISSUE);
        emit log_named_uint("createAndIssue of 125 under Pyth's check", used);
        // As above, the bound is the release build's: `forge coverage`'s unoptimized build costs more.
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) assertLt(used, uint256(1 << 24) * 5 / 6);

        used = _createAndIssueWide(factory.MAX_COMPONENTS());
        emit log_named_uint("createAndIssue of 200 under Pyth's check", used);
        assertGt(used, uint256(1 << 24), "the widest index is created and issued in two transactions");
    }

    /// @dev Lists `n` new tokens, where `n` divides TOTAL_WEIGHT, with a feed each at one price, and has `creator`
    ///      create an index of them all, equally weighted, with a first issue of two shares, every touched account
    ///      cold. Returns the creation's gas.
    function _createAndIssueWide(uint256 n) internal returns (uint256 used) {
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](n);
        vm.startPrank(owner);
        for (uint256 i = 0; i < n; ++i) {
            MockERC20 token = new MockERC20("T", "T", 18);
            factory.proposeListing(address(token));
            bytes32 id = keccak256(abi.encode("first issue", n, i));
            pyth.setLivePrice(id, 100e8, 0, -8);
            factory.proposePriceFeed(address(token), IPythPrices.PriceFeed({id: id, kind: IPythPrices.FeedKind.Token}));
            specs[i] = _spec(address(token), 10_000 / n, 1e18);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        IWeightedIndexFactory.IndexParams memory params = _params();
        string memory name = string.concat("Wide", vm.toString(n));
        address predicted = factory.predictIndexAddress(creator, name, "WIDE", specs, params);
        uint256 shares = 2e18;
        vm.startPrank(creator);
        for (uint256 i = 0; i < n; ++i) {
            factory.executeListing(specs[i].token);
            factory.executePriceFeed(specs[i].token);
            uint256 amount = Math.mulDiv(shares, specs[i].units, 1e18, Math.Rounding.Ceil);
            MockERC20(specs[i].token).mint(creator, amount);
            MockERC20(specs[i].token).approve(predicted, amount);
        }
        vm.stopPrank();
        for (uint256 i = 0; i < n; ++i) {
            vm.cool(specs[i].token);
        }
        vm.cool(address(factory));
        vm.cool(factory.IMPLEMENTATION());
        vm.cool(address(pyth));
        vm.cool(factory.PRICES());
        vm.prank(creator);
        uint256 before = gasleft();
        WeightedHub wide = WeightedHub(factory.createAndIssue(name, "WIDE", specs, params, shares, alice));
        used = before - gasleft();
        assertEq(address(wide), predicted);
        assertEq(wide.balanceOf(alice), shares);
        assertEq(wide.componentCount(), n);
    }

    /// @dev The hub names the reader its factory deployed, and the reader names the chain's Pyth and that factory.
    function test_theHubReadsTheFactorysReader() public view {
        assertEq(index.PRICES(), factory.PRICES());
        assertEq(prices.PYTH(), address(pyth));
        assertEq(prices.FACTORY(), address(factory));
        assertEq(prices.MAX_PRICE_AGE(), 60);
        assertEq(prices.VALUE_SCALE(), 1e36);
    }

    // ---------------------------------------------------------------------
    // Changing the weights (the owner's calls of 2026-11-23, `design/2026-11-23-changeable-weights.md`)
    // ---------------------------------------------------------------------

    function _weights(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory w) {
        w = new uint256[](3);
        (w[0], w[1], w[2]) = (a, b, c);
    }

    /// @dev The creator proposes new weights; nothing changes for WEIGHTS_DELAY, a week in which holders can leave; then
    ///      anyone applies them, and the next rebalance moves the units to them, under the bar and Pyth's check.
    function test_theCreatorChangesTheWeightsAfterTheNotice() public {
        uint256[] memory next = _weights(4500, 3000, 2500);
        uint256 eta = block.timestamp + factory.WEIGHTS_DELAY();
        assertEq(factory.WEIGHTS_DELAY(), 7 days);
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.WeightsProposed(address(index), next, eta);
        vm.prank(creator);
        factory.proposeWeights(address(index), next);
        (uint256[] memory pending, uint256 pendingEta) = factory.pendingWeights(address(index));
        assertEq(pending, next);
        assertEq(pendingEta, eta);
        assertEq(index.componentWeights(), _weights(5000, 3000, 2000), "nothing changes during the notice");

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.WeightsNotReady.selector, address(index), eta));
        factory.executeWeights(address(index));
        vm.warp(eta);
        vm.expectEmit(address(index));
        emit IWeightedHub.WeightsChanged(next);
        vm.prank(stranger);
        factory.executeWeights(address(index));
        assertEq(index.componentWeights(), next);
        assertEq(factory.weightsEta(address(index)), 0);
        (pending,) = factory.pendingWeights(address(index));
        assertEq(pending.length, 0);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NoPendingWeights.selector, address(index)));
        factory.executeWeights(address(index));

        // The units follow at the next rebalance: a fill onto the new weights at Pyth's prices passes both checks.
        _open(index.AUCTION_DURATION());
        uint256[] memory market = _market(ETH_PRICE, BTC_PRICE, USD_PRICE);
        uint256[] memory fair = _onWeights(index, market);
        uint256[] memory before = index.recordedUnits();
        assertLt(fair[0], before[0], "ETH goes down to 45%");
        assertGt(fair[2], before[2], "dollars go up to 25%");
        executor.execute(index, fair, "");
        assertEq(index.recordedUnits(), fair);
    }

    /// @dev Only the index's creator proposes; the weights obey creation's rule, each at least a basis point and all
    ///      summing to TOTAL_WEIGHT, one for each component; and only an index of this factory takes a proposal.
    function test_onlyTheCreatorProposesValidWeights() public {
        uint256[] memory next = _weights(4500, 3000, 2500);
        address[2] memory others = [owner, stranger];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, others[i]));
            factory.proposeWeights(address(index), next);
        }
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, stranger));
        factory.proposeWeights(stranger, next);

        uint256[][4] memory bad =
            [_weights(5000, 5000, 0), _weights(10_001, 0, 0), _weights(4500, 3000, 2499), new uint256[](2)];
        bad[3][0] = 5000;
        bad[3][1] = 5000;
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(creator);
            vm.expectRevert(IWeightedIndexFactory.InvalidWeights.selector);
            factory.proposeWeights(address(index), bad[i]);
        }
        // A basis point is enough: a coin is phased out, never dropped.
        vm.prank(creator);
        factory.proposeWeights(address(index), _weights(9998, 1, 1));
    }

    /// @dev A second proposal replaces the first and restarts the notice; the creator, the owner and the guardian
    ///      cancel one, nobody else; and one left beyond its window can no longer apply.
    function test_aProposalIsReplacedCancelledOrExpires() public {
        vm.prank(creator);
        factory.proposeWeights(address(index), _weights(4500, 3000, 2500));
        vm.warp(block.timestamp + 3 days);
        vm.prank(creator);
        factory.proposeWeights(address(index), _weights(4000, 3000, 3000));
        assertEq(factory.weightsEta(address(index)), block.timestamp + 7 days, "the notice restarts");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        factory.cancelWeights(address(index));
        address[3] memory cancellers = [creator, owner, guardian];
        for (uint256 i = 0; i < cancellers.length; ++i) {
            vm.prank(creator);
            factory.proposeWeights(address(index), _weights(4500, 3000, 2500));
            vm.expectEmit(address(factory));
            emit IWeightedIndexFactory.WeightsCancelled(address(index));
            vm.prank(cancellers[i]);
            factory.cancelWeights(address(index));
            assertEq(factory.weightsEta(address(index)), 0);
        }
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NoPendingWeights.selector, address(index)));
        factory.cancelWeights(address(index));

        vm.prank(creator);
        factory.proposeWeights(address(index), _weights(4500, 3000, 2500));
        uint256 deadline = factory.weightsEta(address(index)) + factory.PROPOSAL_WINDOW();
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.WeightsExpired.selector, address(index), deadline));
        factory.executeWeights(address(index));
    }

    /// @dev No change applies while a rebalance is live, so a fill is always judged on the weights its auction
    ///      started with; once the auction is over, it applies.
    function test_noChangeAppliesDuringARebalance() public {
        vm.prank(creator);
        factory.proposeWeights(address(index), _weights(4500, 3000, 2500));
        uint256 applies = factory.weightsEta(address(index));
        vm.warp(applies);
        vm.warp(index.earliestRebalance() > block.timestamp ? index.earliestRebalance() : block.timestamp);
        index.startRebalance(0);
        (uint256 eta,) = index.pendingRebalance();
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalancePending.selector, eta + index.AUCTION_DURATION()));
        factory.executeWeights(address(index));
        vm.warp(eta + index.AUCTION_DURATION() + 1);
        factory.executeWeights(address(index));
        assertEq(index.componentWeights(), _weights(4500, 3000, 2500));
    }

    /// @dev Only the factory writes an index's weights, and only one for each component.
    function test_onlyTheFactoryWritesTheWeights() public {
        vm.expectRevert(IWeightedHub.NotFactory.selector);
        index.setWeights(_weights(4500, 3000, 2500));
        vm.prank(address(factory));
        vm.expectRevert(IWeightedHub.InvalidComponents.selector);
        index.setWeights(new uint256[](2));
    }

    /// @dev On a factory without an oracle nothing bounds what a change of weights opens to its creator's own auction,
    ///      so no proposal is taken; and a factory needs a math with code.
    function test_aFactoryWithoutAnOracleTakesNoProposal() public {
        WeightedIndexFactory bare = new WeightedIndexFactory(owner, guardian, address(0), address(new WeightedMath()));
        vm.prank(owner);
        bare.setApprovedCreator(creator, true);
        address[3] memory tokens = [address(eth), address(btc), address(usd)];
        for (uint256 i = 0; i < tokens.length; ++i) {
            vm.prank(owner);
            bare.proposeListing(tokens[i]);
        }
        vm.warp(block.timestamp + bare.LISTING_DELAY());
        for (uint256 i = 0; i < tokens.length; ++i) {
            bare.executeListing(tokens[i]);
        }
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        IWeightedIndexFactory.IndexParams memory params = _params();
        vm.prank(creator);
        address unpriced = bare.createIndex("Bare", "BARE", specs, params);
        vm.prank(creator);
        vm.expectRevert(IWeightedIndexFactory.NoOracle.selector);
        bare.proposeWeights(unpriced, _weights(4500, 3000, 2500));

        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NotAContract.selector, stranger));
        new WeightedIndexFactory(owner, guardian, address(0), stranger);
    }
}
