// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexRule} from "../src/IndexRule.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../src/interfaces/IIndexRule.sol";
import {IIndexToken} from "../src/interfaces/IIndexToken.sol";
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

    /// @dev A basket of tokens listed at exact WAD prices, through the 18-decimal feeds `_listWad` uses. An
    ///      eight-decimal feed quantises an 18-decimal token's price to multiples of 1e10, so a price of a few wei,
    ///      or one near MAX_PRICE, is only reachable this way.
    function _wadBasket(uint256[] memory prices, uint256[] memory supplies) internal returns (address[] memory tokens) {
        tokens = new address[](prices.length);
        for (uint256 i = 0; i < prices.length; ++i) {
            tokens[i] = _listWad(prices[i], supplies[i]);
        }
    }

    /// @dev A price above MAX_EXACT_PRICE, which forces `Basket.scale` to WAD.
    uint256 internal constant SCALE_FORCING_PRICE = 1e47;

    /// @dev Tokens at a dollar each (a WAD price of 1e18) whose reference supplies are `parts` whole tokens.
    /// @dev A price that makes a kept component dominate a flat basket: $54.58723222, which is what the tick of
    ///      40,000 these VR-02 tests were written against came to when the rule read Uniswap pools. What the tests
    ///      need is only that the kept component's cap becomes the largest; the figure is carried over so the exact
    ///      targets they assert stay the ones the finding was measured with.
    int256 internal constant KEPT_DOMINANT = 5_458_723_222;

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
        // CAPPED_TOP_WEIGHT is a ceiling, not an allocation: a largest component that does not reach it keeps its own
        // market-cap weight, and nothing is redistributed to it. Equal caps therefore weigh equally, and which of them
        // ranks first stops mattering (VR-01).
        w = rule.weightsFromCaps(_arr(5, 5, 5, 5, 5), CAPPED);
        assertEq(w[0], 0.2e18);
        assertEq(w[1], 0.2e18);
        assertEq(w[4], 0.2e18);
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

    /// @dev VR-06: a component whose market-cap share lands exactly on its ceiling still pins, so its ceiling leaves
    ///      the pool along with its cap. Treating "exactly at the ceiling" as "under it" would keep the component's
    ///      cap in the denominator while its weight was already handed out, and the weights would stop summing to one.
    function test_VR06_aShareExactlyOnTheCeilingStillPins() public view {
        // Caps of 5, 2, 1, 1, 1 out of 10: the first overshoots 30% and the second lands on 20% to the wei. Both pin
        // in the first pass, leaving 50% for the three smallest.
        uint256[] memory w = rule.weightsFromCaps(_arr(5, 2, 1, 1, 1), CAPPED);
        assertEq(w[0], 0.3e18, "the largest pins at its own ceiling");
        assertEq(w[1], 0.2e18, "the exact hit pins at the cap");
        uint256 sum = w[0] + w[1];
        for (uint256 i = 2; i < 5; ++i) {
            assertEq(w[i], uint256(0.5e18) / 3, "and the rest share what the two pins left");
            sum += w[i];
        }
        // Counting the exact hit as unpinned would leave the three smallest on 14% each and the sum at 92%.
        assertApproxEqAbs(sum, WAD, 2, "the whole weight is still placed");

        // When every component lands on or under its ceiling nothing has to be shared again, so the first pass is
        // already the answer and the boundary does not show: 3, 2, 2, 2, 1 out of 10 is 30%, 20%, 20%, 20%, 10%.
        w = rule.weightsFromCaps(_arr(3, 2, 2, 2, 1), CAPPED);
        assertEq(w[0], 0.3e18);
        assertEq(w[1], 0.2e18);
        assertEq(w[4], 0.1e18);
        assertEq(w[0] + w[1] + w[2] + w[3] + w[4], WAD);
    }

    function test_weights_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidMethodology.selector, 2));
        rule.weightsFromCaps(_arr(1, 1, 1, 1, 1), 2);

        uint256[] memory four = new uint256[](4);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.TooFewComponentsForCapped.selector, 4));
        rule.weightsFromCaps(four, CAPPED);

        vm.expectRevert(IIndexRule.DegenerateBasket.selector);
        rule.weightsFromCaps(_arr(0, 0, 0, 0, 0), CAPPED); // no cap at all to weigh
        vm.expectRevert(IIndexRule.DegenerateBasket.selector);
        rule.weightsFromCaps(_arr(10, 0, 0, 0, 0), CAPPED); // nothing left once the first reaches its ceiling
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
        assertLe(w[first], 0.3e18, "the largest stays under its own ceiling");
        for (uint256 i = 0; i < n; ++i) {
            if (i != first) assertLe(w[i], 0.2e18, "every rank below the first stays under the cap");
            assertGe(w[first], w[i], "and the largest cap keeps the largest weight");
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

    // ---------------------------------------------------------------------
    // VR-01 / VR-02 / VR-06: the verification review of 2026-09-21
    // ---------------------------------------------------------------------

    /// @dev VR-01. CAPPED_TOP_WEIGHT is a ceiling, not an allocation. It used to be assigned outright, which made the
    ///      top weight a step function of the caps: one wei of cap moved 12.5 percentage points between two of five
    ///      otherwise equal components, and the largest of twenty equal components was handed 30% against a natural 5%.
    ///      Capping instead leaves a component that does not reach its ceiling on its own market-cap weight, so equal
    ///      caps weigh equally and which of them ranks first stops mattering.
    function test_VR01_aTieNoLongerMovesTheTopWeight() public view {
        uint256[] memory caps = _arr(1e24, 1e24, 1e24, 1e24, 1e24);
        uint256[] memory w = rule.weightsFromCaps(caps, CAPPED);
        assertEq(w[0], 0.2e18, "the largest keeps its own weight, it is not promoted to the ceiling");

        caps[1] += 1; // the runner-up edges past: the rank moves, the weights must not
        uint256[] memory nudged = rule.weightsFromCaps(caps, CAPPED);
        for (uint256 i = 0; i < 5; ++i) {
            assertApproxEqAbs(nudged[i], w[i], 1, "one wei of cap moves at most one wei of weight");
        }
    }

    /// @dev VR-01: the ceiling still binds where the methodology needs it to. A basket that is genuinely top-heavy is
    ///      capped exactly as before, and the excess is shared out under the 20% cap.
    function test_VR01_theCeilingStillBindsOnATopHeavyBasket() public view {
        uint256[] memory w = rule.weightsFromCaps(_arr(70, 10, 10, 5, 5), CAPPED);
        assertEq(w[0], 0.3e18, "a component past its ceiling is still cut to it");
        assertLe(w[1], 0.2e18);
        uint256 sum = 0;
        for (uint256 i = 0; i < 5; ++i) {
            sum += w[i];
        }
        assertApproxEqAbs(sum, WAD, 5, "and the excess is placed, not lost");
    }

    /// @dev VR-01: the consequence at the token. An index sitting exactly on the capped methodology cannot rebalance,
    ///      and a one-basis-point move on one price no longer puts an eighth of it up for auction. Before the fix the
    ///      same basket's on-methodology units were 150/87.5x4 and a move this size produced 12.4995% turnover from
    ///      any address. One basis point is what a single Uniswap tick was worth when this test was written against a
    ///      pool oracle; against a feed it is simply the smallest move worth asking the question about.
    function test_VR01_aBasisPointMoveNoLongerClearsMinTurnover() public {
        address[] memory tokens = _flatBasket(_arr(1000, 1000, 1000, 1000, 1000));
        uint256[] memory onRule = _arr(100e18, 100e18, 100e18, 100e18, 100e18);
        IndexToken idx = IndexToken(factory.createIndex("Capped", "CAP", tokens, onRule, CAPPED));
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());

        (uint256[] memory t, uint256 turnover) = idx.previewTarget(0);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(t[i], onRule[i], "equal caps, equal weights: the index is exactly on its methodology");
        }
        assertEq(turnover, 0);

        market.movePrice(tokens[1], 10_001, 10_000);
        (, turnover) = idx.previewTarget(0);
        assertLt(turnover, idx.MIN_TURNOVER(), "a basis point no longer clears the dust filter");
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.TurnoverTooLow.selector, turnover));
        vm.prank(alice);
        idx.startRebalance(0);
    }

    /// @dev VR-01: a seven-constituent basket whose largest holds 64.7% of the market cap, so both ceilings bind and
    ///      capping is indistinguishable from assigning. The caps are the worked example in the Numbers model
    ///      workbook, used because they are a real top-heavy shape rather than because the sheet is a specification --
    ///      its tokens and scenario figures are illustrative, and only its methodology is the requirement. What the
    ///      workbook did settle is that its constant 0.3 for rank 1 is a ceiling that always bound there: every
    ///      constituent it ships sits far above it, rank 2 is written as an explicit MIN, and its scale factor
    ///      0.7 / (1 - top1) only makes sense while the largest is being cut down. This test passes on the rule before
    ///      and after VR-01, which is what shows the change is a no-op wherever the ceilings bind.
    function test_VR01_theModelsWorkedExampleIsUnchanged() public view {
        uint256[] memory caps = new uint256[](7); // Inputs!D2:D8, price x quantity
        caps[0] = 36_935_424_000; // Doge
        caps[1] = 7_683_689_600; // Shiba Inu
        caps[2] = 4_417_140_000; // PEPE
        caps[3] = 2_198_214_200; // Pengu
        caps[4] = 2_029_100_000; // Memecore
        caps[5] = 2_047_775_000; // BONK
        caps[6] = 1_749_912_500; // Trump

        uint256[] memory w = rule.weightsFromCaps(caps, CAPPED);
        // Inputs!G2:G8, the weights the workbook's own formulas produce for those caps.
        assertApproxEqRel(w[0], 300_000_000_000_000_000, 1e10);
        assertApproxEqRel(w[1], 200_000_000_000_000_000, 1e10);
        assertApproxEqRel(w[2], 177_507_221_284_901_400, 1e10);
        assertApproxEqRel(w[3], 88_337_452_385_709_420, 1e10);
        assertApproxEqRel(w[4], 81_541_427_871_698_310, 1e10);
        assertApproxEqRel(w[5], 82_291_901_562_252_720, 1e10);
        assertApproxEqRel(w[6], 70_321_996_895_438_010, 1e10);
    }

    /// @dev VR-02. A component kept out of a rebalance is priced by `_price`, which applies neither the minimum
    ///      liquidity nor the sub-window agreement that `_snapshotPrice` applies to every component that trades. Its
    ///      cap is not merely a ranking input: it feeds `_top` and the `pool` denominator, so it reshapes the targets
    ///      of the components that do move. Kept as the accepted residue of XA-05 -- excluding kept components from
    ///      the capped weights instead would leave fewer than MIN_CAPPED_COMPONENTS ranks to place the remainder in,
    ///      which is the feasibility condition the capped rule needs -- but pinned, and now documented as more than
    ///      ranking.
    function test_VR02_aKeptComponentsPriceReshapesTheActiveTargets() public {
        address[] memory tokens = _flatBasket(_arr(50, 20, 15, 10, 5));
        uint256 keepMask = 1 << 4;
        (uint256[] memory before, uint256 turnoverBefore) = rule.targetUnits(tokens, _hundreds(), CAPPED, keepMask);

        market.setPrice(tokens[4], KEPT_DOMINANT); // only the KEPT component's price moves
        (uint256[] memory afterwards, uint256 turnoverAfter) = rule.targetUnits(tokens, _hundreds(), CAPPED, keepMask);

        assertEq(before[4], afterwards[4], "the kept component itself never moves");
        assertEq(before[0], 133_333_333_333_333_333_334);
        assertEq(afterwards[0], 114_285_714_285_714_285_715, "but the largest active component's target does");
        assertEq(before[1], 88_888_888_888_888_888_889);
        assertEq(afterwards[1], 114_285_714_285_714_285_715);
        assertLt(turnoverAfter, turnoverBefore, "and turnover FALLS, so MIN_TURNOVER cannot see the distortion");
    }

    /// @dev VR-02, narrowed by the VR-01 fix: while no ceiling binds, every capped weight is the component's own
    ///      market-cap weight, so a kept component's cap divides out of the active set exactly as it does under the
    ///      uncapped methodology. Six equal caps put every natural weight at 16.67%, below both ceilings, and the kept
    ///      component's unchecked price then cannot move anything. What remains of VR-02 is the case a ceiling binds.
    function test_VR02_noCeilingBindingLeavesNoLever() public {
        uint256[] memory parts = new uint256[](6);
        uint256[] memory units = new uint256[](6);
        for (uint256 i = 0; i < 6; ++i) {
            (parts[i], units[i]) = (100, 100e18);
        }
        address[] memory tokens = _flatBasket(parts);
        (uint256[] memory w,,) = rule.weights(tokens, CAPPED);
        for (uint256 i = 0; i < 6; ++i) {
            assertLt(w[i], 0.2e18, "no ceiling binds on six equal caps");
        }

        (uint256[] memory before,) = rule.targetUnits(tokens, units, CAPPED, 1 << 5);
        market.setPrice(tokens[5], KEPT_DOMINANT); // only the KEPT component's price
        (uint256[] memory afterwards,) = rule.targetUnits(tokens, units, CAPPED, 1 << 5);
        for (uint256 i = 0; i < 6; ++i) {
            assertEq(before[i], afterwards[i], "the kept cap cancels out, as under the uncapped methodology");
        }
    }

    /// @dev VR-02, the control: the uncapped methodology never reads a kept component at all, so the same move on the
    ///      same pool changes nothing.
    function test_VR02_theUncappedMethodologyIsImmune() public {
        address[] memory tokens = _flatBasket(_arr(50, 20, 15, 10, 5));
        (uint256[] memory before,) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 1 << 4);
        market.setPrice(tokens[4], KEPT_DOMINANT);
        (uint256[] memory afterwards,) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 1 << 4);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(before[i], afterwards[i], "an uncapped snapshot never reads a kept component");
        }
    }

    /// @dev VR-02, the reason the residue stays: the obvious fix is to exclude kept components from the capped weights
    ///      the way the uncapped methodology already does, giving them a zero cap. That is what makes the kept price
    ///      unreadable, but it also takes a rank out of the set the ceilings have to place the whole weight in, and
    ///      the ceilings only sum above one from MIN_CAPPED_COMPONENTS ranks up. Excluding one of five leaves four,
    ///      whose ceilings sum to 30% + 3 x 20% = 90%, and the last 10% has nowhere to go: the rule reverts. A
    ///      five-component capped index -- the smallest the methodology allows -- could then never be rebalanced with
    ///      a keep mask at all, which is the guardian's safety valve for exactly the component whose pool cannot be
    ///      trusted. Excluding only when enough ranks remain would trade the lever for a step at the keep count, which
    ///      is the shape of bug VR-01 was.
    function test_VR02_excludingAKeptComponentWouldBreakTheCappedRule() public {
        // Five equal caps weigh evenly today, kept component and all.
        uint256[] memory w = rule.weightsFromCaps(_arr(25, 25, 25, 25, 25), CAPPED);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(w[i], 0.2e18, "five ranks place the whole weight");
        }

        // Zero one cap, as excluding a kept component would, and the remaining four cannot.
        vm.expectRevert(IIndexRule.DegenerateBasket.selector);
        rule.weightsFromCaps(_arr(0, 25, 25, 25, 25), CAPPED);

        // From six components up the exclusion would be feasible, which is the step it would introduce: the same
        // index rebalances or reverts depending on how many components the keep mask holds back.
        uint256[] memory six = new uint256[](6);
        for (uint256 i = 1; i < 6; ++i) {
            six[i] = 20;
        }
        w = rule.weightsFromCaps(six, CAPPED);
        assertEq(w[0], 0, "the excluded rank carries nothing");
        uint256 sum = 0;
        for (uint256 i = 0; i < 6; ++i) {
            sum += w[i];
        }
        assertEq(sum, WAD, "and five surviving ranks still place the whole weight");
    }

    /// @dev VR-06a. `_clip`'s floor is load-bearing on the WAD value scale. A component priced below WAD there --
    ///      so its whole floor rounds to nothing -- and carrying a weight small enough that its share of a few wei of
    ///      active value rounds to zero buys back zero units. Without the floor its target would be zero: backing the
    ///      index no longer owes on a component it still holds, and a component the rule can never restore, since
    ///      every later target is bounded by half to double of zero. Reached through the capped rule, whose kept
    ///      component sets the scale from outside the active set, so the active value stays a few wei.
    function test_VR06_theClipFloorKeepsAZeroShareAtItsFloor() public {
        uint256[] memory prices_ = new uint256[](6);
        uint256[] memory supplies = new uint256[](6);
        (prices_[0], supplies[0]) = (SCALE_FORCING_PRICE, 1e24); // kept: forces Basket.scale to WAD
        for (uint256 i = 1; i < 5; ++i) {
            (prices_[i], supplies[i]) = (4, 1e24); // four wei per 1e18 units, and a real weight
        }
        (prices_[5], supplies[5]) = (4, 1); // the same price, but a cap of one wei

        address[] memory tokens = _wadBasket(prices_, supplies);
        (uint256[] memory w, uint256[] memory prices,) = rule.weights(tokens, CAPPED);
        assertGt(prices[0], 1e46, "the kept component's price sets the WAD scale");
        assertEq(prices[5], 4, "the last component is worth four wei per 1e18 units");
        assertLt(w[5], w[1] / 1e6, "and its weight is a millionth of its neighbours'");

        uint256[] memory units = new uint256[](6);
        units[0] = 1e18;
        for (uint256 i = 1; i < 6; ++i) {
            units[i] = 4e17;
        }
        assertEq(Math.mulDiv((units[5] + 1) / 2, prices[5], WAD), 0, "its floor is worth nothing in that scale");
        assertLe(Math.mulDiv(units[5], prices[5], WAD), 1, "and the holding a wei, so the active value is a few wei");

        (uint256[] memory t,) = rule.targetUnits(tokens, units, CAPPED, 1);
        assertEq(t[0], units[0], "the kept component never moves");
        assertEq(t[5], 2e17, "a zero share is lifted to its floor");
        assertEq(t[5], (units[5] + 1) / 2, "which is half its units, rounded up");
        assertGt(t[5], 0, "without the floor the target would be zero units");
    }

    /// @dev VR-06b. `_bound`'s value floor is load-bearing on the same scale: without it a basket whose holdings all
    ///      round away has an activeValue of zero and the snapshot reverts DegenerateBasket instead of returning
    ///      targets. Reached through the capped rule, which prices a kept component and so lets its extreme price set
    ///      the scale while it sits outside the active set.
    function test_VR06_theBoundValueFloorKeepsADustBasketAlive() public {
        uint256[] memory prices_ = new uint256[](5);
        uint256[] memory supplies = new uint256[](5);
        prices_[0] = SCALE_FORCING_PRICE;
        supplies[0] = 1e24;
        for (uint256 i = 1; i < 5; ++i) {
            (prices_[i], supplies[i]) = (4, 1e24);
        }
        address[] memory tokens = _wadBasket(prices_, supplies);

        (uint256[] memory w, uint256[] memory prices,) = rule.weights(tokens, CAPPED);
        assertGt(prices[0], 1e46, "the kept component's price sets Basket.scale to WAD");
        assertEq(w[0], 0.3e18, "and it is rank one under the capped rule");

        uint256[] memory units = new uint256[](5);
        units[0] = 1e18;
        for (uint256 i = 1; i < 5; ++i) {
            units[i] = 1e17;
            assertEq(Math.mulDiv(units[i], prices[i], WAD), 0, "every active holding rounds away in that scale");
            assertEq(Math.mulDiv(2 * units[i], prices[i], WAD), 0, "and so does every ceiling");
        }

        (uint256[] memory t, uint256 turnover) = rule.targetUnits(tokens, units, CAPPED, 1);
        assertEq(t[0], units[0], "the kept component never moves");
        for (uint256 i = 1; i < 5; ++i) {
            assertEq(t[i], 2e17, "each takes its one wei of share and doubles");
        }
        assertEq(turnover, 0, "nothing is sold");
    }
}
