// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexRule} from "../src/IndexRule.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../src/interfaces/IIndexRule.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DEFAULT_STALENESS, FEED_DECIMALS, MockMarket, usdWad} from "./mocks/MockMarket.sol";

contract IndexRuleTest is Test {
    MockMarket market;
    IndexFactory factory;
    IndexRule rule;
    address weth;
    address usdc;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");

    uint256 constant WAD = 1e18;
    uint8 constant UNCAPPED = 0;
    uint8 constant CAPPED = 1;
    address constant LOW = address(0x1000); // below any WETH mock: token0 of its pool
    address constant HIGH = address(type(uint160).max); // above any WETH mock: token1 of its pool

    /// @dev A dollar per whole token, in the eight decimals a feed answers in. An 18-decimal token priced here has a
    ///      WAD price of exactly 1e18, which is what every basket below is built from.
    int256 constant ONE_DOLLAR = 1e8;

    /// @dev Five tokens listed at a dollar with equal reference supplies, for fuzzing prices without relisting.
    address[] fuzzTokens;

    function setUp() public {
        market = new MockMarket();
        weth = address(market.weth());
        usdc = address(market.usdc());
        factory = new IndexFactory(owner, guardian);
        rule = IndexRule(factory.RULE());
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Low", "LOW", uint8(18)), LOW);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("High", "HIGH", uint8(18)), HIGH);
        for (uint256 i = 0; i < 5; ++i) {
            fuzzTokens.push(address(new MockERC20("F", "F", 18)));
            _listAt(fuzzTokens[i], ONE_DOLLAR, 1e24);
        }
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _list(address token, IIndexFactory.TokenConfig memory config) internal {
        vm.prank(owner);
        factory.proposeListing(token, config);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    function _listAt(address token, int256 priceUsd8, uint256 referenceSupply) internal {
        _list(token, market.configWith(token, priceUsd8, referenceSupply));
    }

    /// @dev Lists fresh 18-decimal tokens at the given dollar prices and reference supplies.
    function _basket(int256[] memory prices, uint256[] memory supplies) internal returns (address[] memory tokens) {
        tokens = new address[](prices.length);
        for (uint256 i = 0; i < prices.length; ++i) {
            tokens[i] = address(new MockERC20("B", "B", 18));
            _listAt(tokens[i], prices[i], supplies[i]);
        }
    }

    /// @dev Lists a fresh 18-decimal token whose feed answers in 18 decimals too, so the rule's exponent is zero and
    ///      the answer is the WAD price itself. It is the only way to reach a price of a few wei, or one near
    ///      MAX_PRICE, which eight decimals against an 18-decimal token cannot express.
    function _listWad(uint256 wadPrice, uint256 referenceSupply) internal returns (address token) {
        token = address(new MockERC20("B", "B", 18));
        _list(token, market.configWithFeed(token, int256(wadPrice), 18, referenceSupply));
    }

    /// @dev Tokens at a dollar each (a WAD price of 1e18) whose reference supplies are `parts` whole tokens.
    function _flatBasket(uint256[] memory parts) internal returns (address[] memory tokens) {
        int256[] memory prices = new int256[](parts.length);
        uint256[] memory supplies = new uint256[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            prices[i] = ONE_DOLLAR;
            supplies[i] = parts[i] * WAD;
        }
        return _basket(prices, supplies);
    }

    function _arr(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[] memory r) {
        r = new uint256[](5);
        (r[0], r[1], r[2], r[3], r[4]) = (a, b, c, d, e);
    }

    /// @dev A config naming `feed` with the market's default staleness bound.
    function _config(address feed, uint256 referenceSupply) internal pure returns (IIndexFactory.TokenConfig memory c) {
        c.feed = feed;
        c.maxStaleness = DEFAULT_STALENESS;
        c.referenceSupply = referenceSupply;
    }

    // ---------------------------------------------------------------------
    // constants
    // ---------------------------------------------------------------------

    function test_constants() public view {
        assertEq(rule.FACTORY(), address(factory));
        assertEq(rule.MAX_PRICE(), 1e56, "far past any real asset, and inside the rule's 256-bit proof");
        assertEq(rule.MAX_FEED_STALENESS(), 2 days, "twice the longest heartbeat the default list carries");
        assertEq(
            rule.MAX_TARGET_UNITS() * 3 / 2, uint256(type(uint96).max), "an auction's premium still fits uint96 units"
        );
    }

    // ---------------------------------------------------------------------
    // checkConfig
    // ---------------------------------------------------------------------

    /// @dev WETH used to be the one token the rule priced without reading anything, at a fixed 1e18. With every price
    ///      coming from a feed there is nothing left to special-case: WETH carries an ETH/USD feed and ether's supply
    ///      exactly as any other component carries its own.
    function test_checkConfig_wethIsAnOrdinaryToken() public {
        IIndexFactory.TokenConfig memory config = market.configWith(weth, 3_000e8, 120_000_000e18);
        rule.checkConfig(weth, config);
        _list(weth, config);
        assertEq(rule.price(weth), 3_000e18, "priced from its feed, not from being the numeraire");
        assertEq(rule.supply(weth), 120_000_000e18);
    }

    function test_checkConfig_feeds() public {
        MockERC20(LOW).mint(alice, 100e18);
        address feed = market.configWith(LOW, ONE_DOLLAR, 1).feed;

        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidFeed.selector, LOW, address(0)));
        rule.checkConfig(LOW, _config(address(0), 1));
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidFeed.selector, LOW, alice));
        rule.checkConfig(LOW, _config(alice, 1)); // an address with no code

        IIndexFactory.TokenConfig memory config = _config(feed, 1);
        config.maxStaleness = 0;
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidStaleness.selector, LOW, uint32(0)));
        rule.checkConfig(LOW, config);
        uint32 tooLong = rule.MAX_FEED_STALENESS() + 1;
        config.maxStaleness = tooLong;
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidStaleness.selector, LOW, tooLong));
        rule.checkConfig(LOW, config);
        config.maxStaleness = rule.MAX_FEED_STALENESS();
        rule.checkConfig(LOW, config); // the ceiling itself is accepted

        // A feed that answers but is not usable: refused at the proposal, not discovered at the next rebalance.
        market.setPrice(LOW, 0);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPrice.selector, LOW, int256(0)));
        rule.checkConfig(LOW, _config(feed, 1));
    }

    function test_checkConfig_supplies() public {
        address feed = market.configWith(LOW, ONE_DOLLAR, 1).feed;

        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroSupply.selector, LOW));
        rule.checkConfig(LOW, _config(feed, 0)); // nobody has minted LOW yet

        // Its own total supply, once someone has, or a reference figure instead. DA-10 left no third way to define
        // it: the list of excluded holders that `_supply` subtracted with a live `balanceOf` is gone.
        MockERC20(LOW).mint(alice, 100e18);
        rule.checkConfig(LOW, _config(feed, 0));
        rule.checkConfig(LOW, _config(feed, 1));

        MockERC20(LOW).burn(alice, 100e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroSupply.selector, LOW));
        rule.checkConfig(LOW, _config(feed, 0));
    }

    // ---------------------------------------------------------------------
    // prices and supplies
    // ---------------------------------------------------------------------

    /// @dev A WAD price is the answer scaled by 10 ** (36 - feedDecimals - tokenDecimals), so the same dollar figure
    ///      lands on the same value whatever decimals the token and its feed use.
    function test_price_convertsAnswerToUsdWad() public {
        _listAt(LOW, ONE_DOLLAR, 1);
        assertEq(rule.price(LOW), WAD, "a dollar on an 18-decimal token is 1e18");

        // The same dollar price on 8-, 9- and 6-decimal tokens: the shapes WBTC, wrapped SOL and USDC have.
        uint8[3] memory decimals = [8, 9, 6];
        for (uint256 i = 0; i < 3; ++i) {
            MockERC20 token = new MockERC20("D", "D", decimals[i]);
            token.mint(alice, 1);
            _listAt(address(token), 30_000e8, 0);
            assertEq(rule.price(address(token)), usdWad(30_000e8, decimals[i]), "30,000 dollars a whole token");
            assertEq(
                rule.price(address(token)) * 10 ** decimals[i] / WAD,
                30_000e18,
                "one whole token is worth 30,000 dollars whatever its decimals"
            );
        }

        // An 18-decimal feed on an 18-decimal token makes the exponent zero, so the answer is the price itself.
        assertEq(rule.price(_listWad(12_345, 1)), 12_345);
    }

    function test_price_andSupplyOfATokenWithNoConfig() public {
        MockERC20 unlisted = new MockERC20("Unlisted", "NONE", 18);
        unlisted.mint(alice, 5e18);
        // No config, so no feed: the rule names what is missing instead of reverting on a codeless address.
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidFeed.selector, address(unlisted), address(0)));
        rule.price(address(unlisted));
        assertEq(rule.supply(address(unlisted)), 5e18, "the plain total supply");
    }

    /// @dev The staleness bound is the token's own, not a constant, because the default list's feeds run on one-hour
    ///      and 24-hour heartbeats and a single bound would have to admit the slower one.
    function test_price_stalenessIsPerFeed() public {
        _listAt(LOW, ONE_DOLLAR, 1);
        MockERC20 slow = new MockERC20("Slow", "SLOW", 18);
        slow.mint(alice, 1e18);
        IIndexFactory.TokenConfig memory config = market.configWith(address(slow), ONE_DOLLAR, 0);
        config.maxStaleness = 1 days;
        _list(address(slow), config);

        market.setAge(LOW, DEFAULT_STALENESS);
        market.setAge(address(slow), DEFAULT_STALENESS);
        assertEq(rule.price(LOW), WAD, "the bound itself is still fresh");
        assertEq(rule.price(address(slow)), WAD);

        market.setAge(LOW, uint256(DEFAULT_STALENESS) + 1);
        market.setAge(address(slow), uint256(DEFAULT_STALENESS) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexRule.StalePrice.selector, LOW, block.timestamp - DEFAULT_STALENESS - 1)
        );
        rule.price(LOW);
        assertEq(rule.price(address(slow)), WAD, "the slower feed's own bound has not run out");

        market.setAge(address(slow), 1 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexRule.StalePrice.selector, address(slow), block.timestamp - 1 days - 1)
        );
        rule.price(address(slow));
    }

    /// @dev A timestamp ahead of the block is a broken feed, not a fresh one. Subtracting it would underflow, so the
    ///      check is written to fail closed instead.
    function test_price_futureTimestampFailsClosed() public {
        _listAt(LOW, ONE_DOLLAR, 1);
        market.feedOf(LOW).setUpdatedAt(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.StalePrice.selector, LOW, block.timestamp + 1));
        rule.price(LOW);
    }

    function test_price_rejectsZeroAndNegativeAnswers() public {
        _listAt(LOW, ONE_DOLLAR, 1);
        market.setPrice(LOW, 0);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPrice.selector, LOW, int256(0)));
        rule.price(LOW);
        market.setPrice(LOW, -1);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPrice.selector, LOW, int256(-1)));
        rule.price(LOW);
    }

    /// @dev MAX_PRICE is what keeps every value product inside 256 bits, so an answer past it is refused rather than
    ///      carried into arithmetic the rule is not proved for.
    function test_price_rejectsAPriceAboveMaxPrice() public {
        uint256 max = rule.MAX_PRICE();
        address token = _listWad(max, 1);
        assertEq(rule.price(token), max, "the ceiling itself is accepted");

        market.setPrice(token, int256(max + 1));
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.PriceTooHigh.selector, token, int256(max + 1)));
        rule.price(token);
    }

    /// @dev Decimals are read on every call rather than stored at listing, so an answer and the scale it is read with
    ///      always come from the same aggregator in the same block. A proxy repointed to one with other decimals
    ///      therefore reprices correctly instead of being read at the old scale.
    function test_price_readsDecimalsLive() public {
        MockERC20 token = new MockERC20("Six", "SIX", 6);
        token.mint(alice, 1);
        _listAt(address(token), ONE_DOLLAR, 0);
        assertEq(rule.price(address(token)), usdWad(ONE_DOLLAR, 6));

        token.setDecimals(18);
        assertEq(rule.price(address(token)), usdWad(ONE_DOLLAR, 18), "the same answer, repriced at the new scale");

        token.setDecimals(19);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidDecimals.selector, address(token), 19, FEED_DECIMALS));
        rule.price(address(token));
    }

    /// @dev There is no looser view path. Nothing about a feed can be griefed by a third party, so a display price
    ///      that skipped the checks would only ever show a dead number as if it were current.
    function test_price_hasNoDisplayPath() public {
        address[] memory tokens = _flatBasket(_arr(1, 1, 1, 1, 1));
        uint256[] memory units = _arr(1e18, 1e18, 1e18, 1e18, 1e18);
        IndexToken index = IndexToken(factory.createIndex("Display", "DISP", tokens, units, UNCAPPED));

        market.setAge(tokens[0], uint256(DEFAULT_STALENESS) + 1);
        bytes memory err =
            abi.encodeWithSelector(IIndexRule.StalePrice.selector, tokens[0], block.timestamp - DEFAULT_STALENESS - 1);

        vm.expectRevert(err);
        rule.price(tokens[0]);
        vm.expectRevert(err);
        rule.weights(tokens, UNCAPPED);
        vm.expectRevert(err);
        rule.navPerToken(address(index));
        vm.expectRevert(err);
        rule.initialUnits(tokens, UNCAPPED, 1_000e18);
        vm.expectRevert(err);
        rule.targetUnits(tokens, units, UNCAPPED, 0);
    }

    function test_supply() public {
        _listAt(LOW, ONE_DOLLAR, 7e18);
        assertEq(rule.supply(LOW), 7e18);

        MockERC20 token = new MockERC20("Onchain", "ON", 18);
        token.mint(alice, 1_400e18);
        _list(address(token), market.configWith(address(token), ONE_DOLLAR, 0));
        assertEq(rule.supply(address(token)), 1_400e18, "a token with no reference supply is its own total supply");

        token.burn(alice, 1_400e18); // everything burned
        assertEq(rule.supply(address(token)), 0, "the view reports it");
        address[] memory burned = new address[](1);
        burned[0] = address(token);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroSupply.selector, address(token)));
        rule.weights(burned, UNCAPPED); // and the rule refuses to weigh it
    }

    /// @dev DA-05. The values `IndexToken` holds a fill against. Only a leg that moves is priced, so a keep mask still
    ///      routes around a component whose feed cannot be read.
    function test_settlementValues() public {
        address[] memory tokens = _flatBasket(_arr(1, 1, 1, 1, 1));
        uint256[] memory out = new uint256[](5);
        uint256[] memory into = new uint256[](5);
        (out[0], into[1]) = (10e18, 4e18);

        (uint256 outValue, uint256 inValue) = rule.settlementValues(tokens, out, into);
        assertEq(outValue, 10e18, "a dollar per raw unit");
        assertEq(inValue, 4e18);

        // The three legs that move nothing are never read: a feed too stale to price does not stop the call.
        market.setAge(tokens[3], uint256(DEFAULT_STALENESS) + 1);
        (outValue, inValue) = rule.settlementValues(tokens, out, into);
        assertEq(outValue, 10e18, "an untouched leg needs no price");

        // A leg that does move is priced, and the same stale feed then stops it.
        out[3] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(IIndexRule.StalePrice.selector, tokens[3], block.timestamp - DEFAULT_STALENESS - 1)
        );
        rule.settlementValues(tokens, out, into);

        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        rule.settlementValues(tokens, new uint256[](4), into);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        rule.settlementValues(tokens, out, new uint256[](4));
    }

    // ---------------------------------------------------------------------
    // weights
    // ---------------------------------------------------------------------

    function _sheetCaps() internal pure returns (uint256[] memory caps) {
        caps = new uint256[](7);
        (caps[0], caps[1], caps[2], caps[3]) = (36935424000, 7683689600, 4417140000, 2198214200);
        (caps[4], caps[5], caps[6]) = (2029100000, 2047775000, 1749912500);
    }

    /// @dev The Numbers model's Inputs sheet: its capped weights, reproduced by the closed form in integer math.
    function test_weights_matchTheModel() public view {
        uint256[] memory w = rule.weightsFromCaps(_sheetCaps(), CAPPED);
        uint256[7] memory expected = [
            uint256(300000000000000000),
            200000000000000000,
            177507221284901457,
            88337452385709447,
            81541427871698326,
            82291901562252743,
            70321996895438025
        ];
        uint256[7] memory sheet = [
            uint256(0.3e18),
            0.2e18,
            0.177507221284902e18,
            0.0883374523857098e18,
            0.0815414278716985e18,
            0.082291901562253e18,
            0.0703219968954382e18
        ];
        uint256 sum = 0;
        for (uint256 i = 0; i < 7; ++i) {
            assertEq(w[i], expected[i]);
            assertApproxEqAbs(w[i], sheet[i], 1e3, "within 1e-15 of the spreadsheet");
            sum += w[i];
        }
        assertEq(sum, WAD - 2);

        uint256[] memory natural = rule.weightsFromCaps(_sheetCaps(), UNCAPPED);
        assertEq(natural[0], 647294277102943439);
        assertEq(natural[6], 30667262589997735);
    }

    function test_weights_cappedShapes() public view {
        // Rank 2 capped at 20%.
        uint256[] memory w = rule.weightsFromCaps(_arr(100, 20, 10, 10, 10), CAPPED);
        assertEq(w[0], 0.3e18);
        assertEq(w[1], 0.2e18);
        assertEq(w[2], uint256(0.5e18) / 3);
        // Rank 2 below the cap keeps 70% of its share.
        w = rule.weightsFromCaps(_arr(100, 11, 10, 10, 10), CAPPED);
        assertEq(w[1], uint256(0.7e18) * 11 / 41);
        // Rank 1 is forced up to 30% even when its natural weight is lower, and ties rank by position.
        w = rule.weightsFromCaps(_arr(5, 5, 5, 5, 5), CAPPED);
        assertEq(w[0], 0.3e18);
        assertEq(w[1], 0.175e18);
        assertEq(w[4], 0.175e18);
        // The largest can sit anywhere; here ranks 2 to 4 would take 31.5%, 17.5% and 17.5% of the whole and pin at
        // the cap over two passes, leaving the smallest the remaining 10%.
        w = rule.weightsFromCaps(_arr(1, 9, 5, 5, 40), CAPPED);
        assertEq(w[4], 0.3e18);
        assertEq(w[1], 0.2e18);
        assertEq(w[2], 0.2e18);
        assertEq(w[3], 0.2e18);
        assertEq(w[0], 0.1e18);

        // Every rank below the first is capped. Caps in the ratio of WBTC, WETH, LINK, UNI and tBTC in September 2026
        // used to put LINK at 34.9%; three ranks now pin at the cap and the smallest takes what is left.
        w = rule.weightsFromCaps(_arr(2000e9, 488e9, 15e9, 6e9, 0.5e9), CAPPED);
        assertEq(w[0], 0.3e18);
        assertEq(w[1], 0.2e18);
        assertEq(w[2], 0.2e18);
        assertEq(w[3], 0.2e18);
        assertEq(w[4], 0.1e18);
    }

    /// @dev XA-04: no constituent below the first outweighs the 20% cap, whatever the caps.
    function test_XA04_cappedCapsEveryRankBelowTheFirst() public view {
        uint256[] memory w = rule.weightsFromCaps(_arr(2000e9, 488e9, 15e9, 6e9, 0.5e9), CAPPED);
        assertLe(w[2], 0.2e18, "the third-ranked component stays under the cap");
        assertLt(w[2], w[0], "and under the first");

        // Several ranks pin in the same pass and the redistribution still terminates and places the whole weight.
        w = rule.weightsFromCaps(_arr(100, 99, 98, 97, 1), CAPPED);
        uint256 sum = 0;
        for (uint256 i = 0; i < 5; ++i) {
            if (i != 0) assertLe(w[i], 0.2e18);
            sum += w[i];
        }
        assertEq(w[0], 0.3e18);
        assertEq(w[1], 0.2e18);
        assertEq(w[2], 0.2e18);
        assertEq(w[3], 0.2e18);
        assertEq(w[4], 0.1e18);
        assertEq(sum, WAD);
    }

    function test_weights_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidMethodology.selector, 2));
        rule.weightsFromCaps(_arr(1, 1, 1, 1, 1), 2);

        uint256[] memory four = new uint256[](4);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.TooFewComponentsForCapped.selector, 4));
        rule.weightsFromCaps(four, CAPPED);

        vm.expectRevert(IIndexRule.DegenerateBasket.selector);
        rule.weightsFromCaps(_arr(10, 0, 0, 0, 0), CAPPED); // nothing below the first to share the 70%
        vm.expectRevert(IIndexRule.DegenerateBasket.selector);
        rule.weightsFromCaps(_arr(10, 5, 0, 0, 0), CAPPED); // and nothing left once the second pins at the cap
        vm.expectRevert(IIndexRule.DegenerateBasket.selector);
        rule.weightsFromCaps(_arr(0, 0, 0, 0, 0), UNCAPPED);
    }

    function testFuzz_cappedWeights(uint256[8] memory raw, uint256 count) public view {
        uint256 n = bound(count, 5, 8);
        uint256[] memory caps = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            caps[i] = bound(raw[i], 1, 1e50);
        }
        // Ranks by cap, the lower position first on a tie, as the rule does.
        uint256 first = 0;
        for (uint256 i = 1; i < n; ++i) {
            if (caps[i] > caps[first]) first = i;
        }
        uint256 second = first == 0 ? 1 : 0;
        for (uint256 i = 0; i < n; ++i) {
            if (i != first && caps[i] > caps[second]) second = i;
        }

        uint256[] memory w = rule.weightsFromCaps(caps, CAPPED);
        uint256 sum = 0;
        for (uint256 i = 0; i < n; ++i) {
            sum += w[i];
            for (uint256 j = 0; j < n; ++j) {
                bool bothBelowSecond = i != first && i != second && j != first && j != second;
                if (bothBelowSecond && caps[i] <= caps[j]) assertLe(w[i], w[j], "ranks 3 and below follow caps");
            }
        }
        assertEq(w[first], 0.3e18);
        for (uint256 i = 0; i < n; ++i) {
            if (i != first) assertLe(w[i], 0.2e18, "every rank below the first stays under the cap");
        }
        assertLe(sum, WAD);
        assertGe(sum, WAD - n);
    }

    function testFuzz_uncappedWeightsFollowCaps(uint256[6] memory raw) public view {
        uint256[] memory caps = new uint256[](6);
        for (uint256 i = 0; i < 6; ++i) {
            caps[i] = bound(raw[i], 1, 1e50);
        }
        uint256[] memory w = rule.weightsFromCaps(caps, UNCAPPED);
        uint256 sum = 0;
        for (uint256 i = 0; i < 6; ++i) {
            sum += w[i];
            for (uint256 j = 0; j < 6; ++j) {
                if (caps[i] <= caps[j]) assertLe(w[i], w[j]);
            }
        }
        assertLe(sum, WAD);
        assertGe(sum, WAD - 6);
    }

    function test_weights_readPricesAndSupplies() public {
        int256[] memory prices_ = new int256[](2);
        uint256[] memory supplies = new uint256[](2);
        (prices_[0], prices_[1]) = (2 * ONE_DOLLAR, ONE_DOLLAR);
        (supplies[0], supplies[1]) = (1e18, 2e18);
        address[] memory tokens = _basket(prices_, supplies);
        (uint256[] memory w, uint256[] memory prices, uint256[] memory got) = rule.weights(tokens, UNCAPPED);
        assertEq(got[0], 1e18);
        assertEq(got[1], 2e18);
        assertEq(prices[1], WAD);
        assertEq(prices[0], 2 * WAD);
        assertEq(w[0], 0.5e18, "two dollars of cap each: 2 tokens at a dollar and 1 token at two");
    }

    // ---------------------------------------------------------------------
    // targets
    // ---------------------------------------------------------------------

    function _hundreds() internal pure returns (uint256[] memory) {
        return _arr(100e18, 100e18, 100e18, 100e18, 100e18);
    }

    /// @dev XA-23: a price near MAX_PRICE, with a supply large enough that supply * price would not fit in 256 bits,
    ///      must still produce a snapshot instead of an arithmetic panic.
    function test_XA23_extremePricesDoNotOverflowTheRule() public {
        int256[] memory prices_ = new int256[](5);
        uint256[] memory supplies = new uint256[](5);
        (prices_[0], supplies[0]) = (ONE_DOLLAR, 1e24); // replaced below by the extreme component
        for (uint256 i = 1; i < 5; ++i) {
            prices_[i] = ONE_DOLLAR;
            supplies[i] = 1e24;
        }
        address[] memory tokens = _basket(prices_, supplies);
        // A WAD price of 5e55, just under MAX_PRICE, against a SHIB-sized supply: the plain product is about 5e88.
        tokens[0] = _listWad(5e55, 1e33);

        (uint256[] memory w,,) = rule.weights(tokens, UNCAPPED);
        assertGt(w[0], 0.99e18, "the extreme component takes almost the whole basket");
        // Units large enough that units * price would not fit either, so the basket's values are scaled as well.
        uint256[] memory units = _arr(1e24, 100e18, 100e18, 100e18, 100e18);
        (uint256[] memory t, uint256 turnover) = rule.targetUnits(tokens, units, UNCAPPED, 0);
        assertApproxEqRel(t[0], 1e24, 1e12, "it already holds the basket's value, so it barely moves");
        assertEq(t[1], 200e18, "the dust-weight components still take value up to their clip");
        assertEq(turnover, 0, "what it gives up is nothing next to the basket's value");

        // The same extreme price on a component the rule wants to shrink: the clips and the later passes still work.
        for (uint256 i = 1; i < 5; ++i) {
            supplies[i] = 1e72; // caps far above the extreme component's
        }
        tokens = _basket(prices_, supplies);
        tokens[0] = _listWad(5e55, 1e33);
        (t,) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);
        assertApproxEqAbs(t[0], 100e18, 1, "the others can only double, so it keeps the value they cannot take");
        assertEq(t[1], 200e18, "the others are clipped at double");
    }

    /// @dev LR-09: XA-23 left one product unbounded. Next to a price above MAX_EXACT_PRICE, the unclipped units of a
    ///      component priced near zero, value over price, did not fit in 256 bits, and the snapshot panicked instead of
    ///      clipping that component at double. A share is now compared with the bounds as a value.
    function test_LR09_aNearZeroPriceNextToAnExtremeOneDoesNotOverflow() public {
        address[] memory tokens = new address[](2);
        tokens[0] = _listWad(5e55, 1e18); // just under MAX_PRICE
        tokens[1] = _listWad(1, 1e76); // one wei, with a supply that gives it real weight
        (uint256[] memory w, uint256[] memory prices,) = rule.weights(tokens, UNCAPPED);
        assertGt(prices[0], 1e46, "the first price is past the exact range");
        assertLt(prices[1], 10, "the second is a few wei");
        assertGt(w[1], 0.1e18, "and still weighs enough to want far more units than 256 bits hold");

        uint256[] memory units = new uint256[](2);
        (units[0], units[1]) = (1e24, 100e18);
        (uint256[] memory t,) = rule.targetUnits(tokens, units, UNCAPPED, 0);
        assertEq(t[1], 200e18, "clipped at double instead of panicking");
        assertApproxEqRel(t[0], 1e24, 1e12, "what it could not take stays with the first");
    }

    function test_targetUnits_clipAndRedistribute() public {
        // One component wants 3x: clipped at 2x, and the value it cannot take goes to the others.
        address[] memory surge = _flatBasket(_arr(6, 1, 1, 1, 1));
        (uint256[] memory t, uint256 turnover) = rule.targetUnits(surge, _hundreds(), UNCAPPED, 0);
        assertEq(t[0], 200e18);
        assertEq(t[1], 75e18);
        assertEq(t[4], 75e18);
        assertEq(turnover, 0.2e18);

        // One component wants a fifth: clipped at half, and the others give up the extra value.
        address[] memory crash = _flatBasket(_arr(4, 49, 49, 49, 49));
        (t, turnover) = rule.targetUnits(crash, _hundreds(), UNCAPPED, 0);
        assertEq(t[0], 50e18);
        assertEq(t[1], 112.5e18);
        assertEq(turnover, 0.1e18);
    }

    function test_targetUnits_needsSeveralPasses() public {
        address[] memory tokens = _flatBasket(_arr(2, 3, 5, 8, 89));
        (uint256[] memory t, uint256 turnover) =
            rule.targetUnits(tokens, _arr(10e18, 10e18, 160e18, 10e18, 10e18), UNCAPPED, 0);
        assertEq(t[0], 20e18);
        assertEq(t[1], 20e18);
        assertEq(t[2], 120e18);
        assertEq(t[3], 20e18);
        assertEq(t[4], 20e18);
        assertEq(turnover, 0.2e18);
    }

    function test_targetUnits_lowerPassPinsAtTheFloor() public {
        // The first component wants a fiftieth of the value and is pinned at half its units; the others give that value
        // back, and the second, just above its own floor, is pinned there by the next pass.
        address[] memory tokens = _flatBasket(_arr(10, 52, 146, 146, 146));
        (uint256[] memory t, uint256 turnover) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);
        assertEq(t[0], 50e18);
        assertEq(t[1], 50e18, "pinned at its floor by the second pass");
        assertEq(t[2], t[4]);
        assertApproxEqAbs(t[0] + t[1] + t[2] + t[3] + t[4], 500e18, 10, "value kept");
        assertEq(turnover, 0.2e18);
    }

    /// @dev Tokens at tick 0 whose reference supplies, and so weights, are in the ratio of `parts`.
    function _threeTokens(uint256 a, uint256 b, uint256 c) internal returns (address[] memory) {
        uint256[] memory parts = new uint256[](3);
        (parts[0], parts[1], parts[2]) = (a, b, c);
        return _flatBasket(parts);
    }

    function _threeUnits(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory units) {
        units = new uint256[](3);
        (units[0], units[1], units[2]) = (a, b, c);
    }

    /// @dev LR-02: the first component holds five times its weight and the second a fifth of its weight, so one ends
    ///      at its floor and the other at its ceiling. The value the ceiling leaves unplaced belongs to the third
    ///      alone. The rule used to share it with every component below its ceiling, the floored one included, and
    ///      returned 28, 20 and 52: it sold less of the most overweight component than its bounds allow.
    function test_LR02_aComponentClippedToItsFloorTakesNoValueBack() public {
        address[] memory tokens = _threeTokens(10, 50, 40);
        (uint256[] memory t, uint256 turnover) = rule.targetUnits(tokens, _threeUnits(50e18, 10e18, 40e18), UNCAPPED, 0);
        assertEq(t[0], 25e18, "five times overweight: sold down to its floor and left there");
        assertEq(t[1], 20e18, "five times underweight: doubled, the most one rebalance allows");
        assertEq(t[2], 55e18, "the value the ceiling left unplaced goes to the only component still free");
        assertEq(turnover, 0.25e18);
    }

    /// @dev LR-02, mirrored: the floor adds more value than the ceilings remove, so the shares come down. The second
    ///      component was clipped to its ceiling by the first pass and used to be lowered from there like any other;
    ///      it is shared out again instead, and ends in proportion to its weight with the third.
    function test_LR02_aComponentClippedToItsCeilingIsSharedOutAgain() public {
        address[] memory tokens = _threeTokens(10, 10, 80);
        (uint256[] memory t,) = rule.targetUnits(tokens, _threeUnits(60e18, 4e18, 36e18), UNCAPPED, 0);
        assertEq(t[0], 30e18, "six times overweight: pinned at its floor");
        assertApproxEqAbs(t[1], uint256(70e18) / 9, 1, "a ninth of the 70 left, no longer clipped");
        assertApproxEqAbs(t[2], uint256(560e18) / 9, 1, "and eight ninths");
        assertApproxEqAbs(t[0] + t[1] + t[2], 100e18, 3, "value kept");
    }

    /// @dev LR-02: targets are a water-filling of value by weight. A component strictly above its floor never holds
    ///      more value per unit of weight than a component strictly below its ceiling: otherwise the rule stopped
    ///      short of moving value from the first to the second.
    function testFuzz_LR02_targetsAreAWaterFilling(
        uint256[5] memory unitSeeds,
        uint256[5] memory priceSeeds,
        bool capped
    ) public {
        address[] memory tokens = fuzzTokens;
        uint256[] memory units = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            // Whole-token magnitudes, so that rounding is far below the tolerance.
            units[i] = bound(unitSeeds[i], 1e18, 1e24);
            market.setPrice(tokens[i], int256(bound(priceSeeds[i], 1e4, 1e12)));
        }
        uint8 methodology = capped ? CAPPED : UNCAPPED;
        (uint256[] memory t,) = rule.targetUnits(tokens, units, methodology, 0);
        (uint256[] memory w, uint256[] memory prices,) = rule.weights(tokens, methodology);

        for (uint256 i = 0; i < 5; ++i) {
            if (t[i] <= (units[i] + 1) / 2) continue;
            for (uint256 j = 0; j < 5; ++j) {
                if (t[j] >= 2 * units[j]) continue;
                uint256 heavier = t[i] * prices[i] / WAD * w[j];
                uint256 lighter = t[j] * prices[j] / WAD * w[i];
                assertLe(heavier, lighter + lighter / 1e9, "value was left on a component that should have given it up");
            }
        }
    }

    /// @dev DA-22, the gap that let DA-01 through. The LR-02 fuzz bounds units to whole-token magnitudes "so that
    ///      rounding is far below the tolerance", which excludes by construction the coarse regime where a floor can
    ///      discard a component's whole move. This one starts at a single raw unit and checks the property the shape
    ///      test cannot see: the target basket is never worth less than the holding it replaces.
    function testFuzz_DA22_targetsNeverLoseValue(uint256[5] memory unitSeeds, uint256[5] memory priceSeeds, bool capped)
        public
    {
        address[] memory tokens = fuzzTokens;
        uint256[] memory units = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            units[i] = bound(unitSeeds[i], 1, 1e24);
            market.setPrice(tokens[i], int256(bound(priceSeeds[i], 1, 1e16)));
        }
        uint8 methodology = capped ? CAPPED : UNCAPPED;
        (uint256[] memory t,) = rule.targetUnits(tokens, units, methodology, 0);
        (, uint256[] memory prices,) = rule.weights(tokens, methodology);

        uint256 heldValue = 0;
        uint256 targetValue = 0;
        for (uint256 i = 0; i < 5; ++i) {
            heldValue += units[i] * prices[i];
            targetValue += t[i] * prices[i];
        }
        // One wei of slack per component: `_bound` floors a rounded-away value at one wei and `_share` rounds each
        // share down. Everything else now rounds toward the holders.
        assertGe(targetValue + 5, heldValue, "the rebalance target is worth less than the basket it replaces");
    }

    function test_targetUnits_zeroWeightComponentsStillAbsorbValue() public {
        int256[] memory prices = new int256[](2);
        uint256[] memory supplies = new uint256[](2);
        (prices[0], prices[1]) = (ONE_DOLLAR, ONE_DOLLAR);
        (supplies[0], supplies[1]) = (1e30, 1);
        address[] memory tokens = _basket(prices, supplies);
        (uint256[] memory w,,) = rule.weights(tokens, UNCAPPED);
        assertEq(w[1], 0, "the second component's weight rounds to zero");

        uint256[] memory units = new uint256[](2);
        (units[0], units[1]) = (10e18, 100e18);
        (uint256[] memory t, uint256 turnover) = rule.targetUnits(tokens, units, UNCAPPED, 0);
        assertEq(t[0], 20e18, "the first doubles, the most one rebalance allows");
        assertEq(t[1], 90e18, "the rest of the value stays in the second instead of being lost to the clip");
        assertEq(turnover, uint256(1e18) / 11);
    }

    function test_targetUnits_keepMaskAndReverts() public {
        address[] memory tokens = _flatBasket(_arr(6, 1, 1, 1, 1));
        (uint256[] memory t, uint256 turnover) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 1);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(t[i], 100e18, "the kept component keeps its units and the rest share their value by weight");
        }
        assertEq(turnover, 0);

        vm.expectRevert(IIndexRule.DegenerateBasket.selector);
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 31);
        vm.expectRevert(IIndexRule.DegenerateBasket.selector);
        rule.targetUnits(tokens, _hundreds(), CAPPED, 31); // the capped rule still ranks kept components first

        uint256[] memory four = new uint256[](4);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        rule.targetUnits(tokens, four, UNCAPPED, 0);
    }

    function test_XA05_keptComponentsNeedNoSnapshotPriceUnderUncapped() public {
        address[] memory tokens = _flatBasket(_arr(6, 1, 1, 1, 1));
        (uint256[] memory readable,) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 1 << 4);
        market.setAge(tokens[4], uint256(DEFAULT_STALENESS) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexRule.StalePrice.selector, tokens[4], block.timestamp - DEFAULT_STALENESS - 1)
        );
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);

        // Uncapped: a kept component is renormalised away, so its feed is never read.
        (uint256[] memory t, uint256 turnover) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 1 << 4);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(t[i], readable[i]);
        }
        assertGt(turnover, 0);
    }

    /// @dev DA-06. Under the capped methodology a kept component's cap sits in the denominator of every other
    ///      component's weight, so its price reshapes the targets and the turnover of the components that do trade.
    ///      It used to be read with the plain `price()`, which applied neither snapshot check, so a component whose
    ///      price nobody had checked could steer a rebalance it does not otherwise take part in. It is now priced like
    ///      any other component, which narrows XA-05: under the capped methodology the keep mask routes around a
    ///      component that cannot be transferred, not around one whose feed cannot be read.
    function test_DA06_aKeptComponentIsSnapshotCheckedUnderCapped() public {
        address[] memory tokens = _flatBasket(_arr(6, 1, 1, 1, 1));

        market.setAge(tokens[4], uint256(DEFAULT_STALENESS) + 1);
        bytes memory stale =
            abi.encodeWithSelector(IIndexRule.StalePrice.selector, tokens[4], block.timestamp - DEFAULT_STALENESS - 1);
        for (uint256 i = 0; i < 2; ++i) {
            uint256 keepMask = i == 0 ? 0 : 1 << 4;
            vm.expectRevert(stale);
            rule.targetUnits(tokens, _hundreds(), CAPPED, keepMask);
        }

        // A kept component whose feed reads cleanly is unaffected.
        market.setAge(tokens[4], 0);
        (uint256[] memory t,) = rule.targetUnits(tokens, _hundreds(), CAPPED, 1 << 4);
        assertEq(t[4], 100e18, "the kept component still keeps its units");
    }

    function test_targetUnits_rejectsAnUnusablePriceOrSupply() public {
        address[] memory tokens = _flatBasket(_arr(6, 1, 1, 1, 1));
        _listAt(weth, ONE_DOLLAR, 6 * WAD);
        tokens[0] = weth; // priced from its own feed, like the token it replaces
        (uint256[] memory t,) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);
        assertEq(t[0], 200e18);

        market.setPrice(tokens[1], 0);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPrice.selector, tokens[1], int256(0)));
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);
        market.setPrice(tokens[1], ONE_DOLLAR);

        MockERC20 onChain = new MockERC20("Onchain", "ON", 18);
        onChain.mint(alice, 1_000e18);
        _list(address(onChain), market.configWith(address(onChain), ONE_DOLLAR, 0));
        tokens[2] = address(onChain);
        onChain.burn(alice, 1_000e18); // everything burned after listing
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroSupply.selector, address(onChain)));
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);
    }

    function test_targetUnits_respectTheUint96Headroom() public {
        uint256 ceiling = rule.MAX_TARGET_UNITS();
        address[] memory tokens = _flatBasket(_arr(3, 1, 1, 1, 1));
        uint256[] memory units = _arr(ceiling, ceiling, ceiling, ceiling, ceiling);
        (uint256[] memory t,) = rule.targetUnits(tokens, units, UNCAPPED, 0);
        assertEq(t[0], ceiling, "a component at the ceiling cannot grow");

        units[0] = type(uint96).max;
        (t,) = rule.targetUnits(tokens, units, UNCAPPED, 0);
        assertLe(t[0], type(uint96).max, "a component above the ceiling never grows");
    }

    function testFuzz_targetUnits_stayInBoundsAndKeepValue(
        uint256[5] memory unitSeeds,
        uint256[5] memory priceSeeds,
        uint256 keepSeed,
        bool capped
    ) public {
        address[] memory tokens = fuzzTokens;
        uint256[] memory units = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            units[i] = bound(unitSeeds[i], 1, 1e30);
            market.setPrice(tokens[i], int256(bound(priceSeeds[i], 1e4, 1e12)));
        }
        uint256 keepMask = bound(keepSeed, 0, 30);
        (uint256[] memory t, uint256 turnover) = rule.targetUnits(tokens, units, capped ? CAPPED : UNCAPPED, keepMask);
        (, uint256[] memory prices,) = rule.weights(tokens, UNCAPPED);

        uint256 before = 0;
        uint256 afterwards = 0;
        uint256 slack = 0;
        for (uint256 i = 0; i < 5; ++i) {
            if ((keepMask >> i) & 1 == 1) {
                assertEq(t[i], units[i]);
            } else {
                assertGe(t[i], (units[i] + 1) / 2);
                assertLe(t[i], 2 * units[i]);
            }
            before += units[i] * prices[i];
            afterwards += t[i] * prices[i];
            slack += 5 * prices[i];
        }
        assertApproxEqAbs(afterwards, before, slack, "value is kept within rounding");
        assertLe(turnover, WAD);
    }

    // ---------------------------------------------------------------------
    // index prices
    // ---------------------------------------------------------------------

    /// @dev The model's seven prices, in dollars per whole token with eight decimals. The sheet quotes them against
    ///      ether, so these are those quotes at the 3,000 dollars an ether the sheet assumes.
    function _sheetPrices(bool scenario) internal pure returns (int256[] memory prices) {
        prices = new int256[](7);
        if (scenario) {
            (prices[0], prices[1], prices[2], prices[3]) = (25950880, 1108, 1260, 3147508);
            (prices[4], prices[5], prices[6]) = (187168021, 3030, 1050078807);
        } else {
            (prices[0], prices[1], prices[2], prices[3]) = (24481272, 1304, 1050, 3497001);
            (prices[4], prices[5], prices[6]) = (197000086, 2525, 875005012);
        }
    }

    /// @dev The model's seven tokens with its circulating quantities and prices at 3,000 USD per ETH.
    function _sheetTokens() internal returns (address[] memory) {
        uint256[] memory supplies = new uint256[](7);
        (supplies[0], supplies[1], supplies[2]) = (150_880_000_000e18, 589_240_000_000_000e18, 420_680_000_000_000e18);
        (supplies[3], supplies[4], supplies[5], supplies[6]) =
        (62_860_000_000e18, 1_030_000_000e18, 81_100_000_000_000e18, 199_990_000e18);
        return _basket(_sheetPrices(false), supplies);
    }

    function _setPrices(address[] memory tokens, int256[] memory prices) internal {
        for (uint256 i = 0; i < tokens.length; ++i) {
            market.setPrice(tokens[i], prices[i]);
        }
    }

    function _caps(address[] memory tokens) internal view returns (uint256 total) {
        (, uint256[] memory prices, uint256[] memory supplies) = rule.weights(tokens, UNCAPPED);
        for (uint256 i = 0; i < tokens.length; ++i) {
            total += prices[i] * supplies[i];
        }
    }

    /// @dev An uncapped index sized at 1,000 dollars follows the model's divisor price, and a capped one does not.
    function test_navPerToken_matchesTheModelsIndexPrice() public {
        address[] memory tokens = _sheetTokens();
        uint256[] memory uncappedUnits = rule.initialUnits(tokens, UNCAPPED, 1_000e18);
        uint256[] memory cappedUnits = rule.initialUnits(tokens, CAPPED, 1_000e18);
        IndexToken uncapped = IndexToken(factory.createIndex("Memes", "MEME", tokens, uncappedUnits, UNCAPPED));
        IndexToken capped = IndexToken(factory.createIndex("Capped Memes", "CMEME", tokens, cappedUnits, CAPPED));

        assertApproxEqRel(rule.navPerToken(address(uncapped)), 1_000e18, 1e12, "starts at the chosen price");
        assertApproxEqRel(rule.navPerToken(address(capped)), 1_000e18, 1e12);

        uint256 capsBefore = _caps(tokens);
        _setPrices(tokens, _sheetPrices(true));
        uint256 uncappedAfter = rule.navPerToken(address(uncapped));
        assertApproxEqRel(uncappedAfter, 1_000e18 * _caps(tokens) / capsBefore, 1e12, "equals the divisor price");
        assertApproxEqRel(uncappedAfter, 1_041.8e18, 1e15, "the model's 1041.80, up to rounding");
        assertApproxEqRel(rule.navPerToken(address(capped)), 1_041.11e18, 2e15, "the capped basket's own value");

        // The top coin doubles: the model's formula would show about 1,647, while the capped basket is worth 1,300.
        _setPrices(tokens, _sheetPrices(false));
        market.movePrice(tokens[0], 2, 1);
        assertApproxEqRel(rule.navPerToken(address(uncapped)), 1_647.29e18, 1e15);
        assertApproxEqRel(rule.navPerToken(address(capped)), 1_300e18, 1e15);
    }

    function test_navPerToken_onlyForIndexes() public {
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, alice));
        rule.navPerToken(alice);
    }

    /// @dev DA-09. `initialUnits` floored a component at one raw unit, so an arbitrarily low start price still
    ///      produced a basket. The coarser the index token, the larger a share of it one raw unit of a component is,
    ///      and a whole rebalance can then be worth less than the granularity of the component it buys. A start price
    ///      that rounds a component away entirely cannot describe the basket, so it is refused rather than floored.
    function test_DA09_initialUnitsRefuseAStartPriceThatRoundsAComponentAway() public {
        int256[] memory prices = new int256[](1);
        uint256[] memory supplies = new uint256[](1);
        prices[0] = 485_000_000e8; // a coarse component: one raw unit is worth far more than a wei of the index
        supplies[0] = 1e18;
        address[] memory tokens = _basket(prices, supplies);

        vm.expectRevert(abi.encodeWithSelector(IIndexRule.StartPriceTooLow.selector, tokens[0], uint256(1)));
        rule.initialUnits(tokens, UNCAPPED, 1);

        // An ordinary start price describes the basket in whole raw units.
        uint256[] memory units = rule.initialUnits(tokens, UNCAPPED, 100e18);
        assertGt(units[0], 1, "a hundred dollars a token is plenty of resolution");
    }
}
