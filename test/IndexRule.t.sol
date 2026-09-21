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
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DEFAULT_MIN_LIQUIDITY, MockMarket} from "./mocks/MockMarket.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3.sol";

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

    /// @dev Five tokens listed at tick 0 with equal reference supplies, for fuzzing prices without relisting.
    address[] fuzzTokens;

    function setUp() public {
        market = new MockMarket();
        weth = address(market.weth());
        usdc = address(market.usdc());
        factory = new IndexFactory(owner, guardian, weth, address(market.uniswapV3Factory()), usdc);
        rule = IndexRule(factory.RULE());
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Low", "LOW", uint8(18)), LOW);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("High", "HIGH", uint8(18)), HIGH);
        for (uint256 i = 0; i < 5; ++i) {
            fuzzTokens.push(address(new MockERC20("F", "F", 18)));
            _listAt(fuzzTokens[i], 0, 1e24);
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

    function _listAt(address token, int24 tick, uint256 referenceSupply) internal {
        _list(token, market.configWith(token, tick, referenceSupply, new address[](0)));
    }

    /// @dev Lists fresh 18-decimal tokens with the given ticks and reference supplies.
    function _basket(int24[] memory ticks, uint256[] memory supplies) internal returns (address[] memory tokens) {
        tokens = new address[](ticks.length);
        for (uint256 i = 0; i < ticks.length; ++i) {
            tokens[i] = address(new MockERC20("B", "B", 18));
            _listAt(tokens[i], ticks[i], supplies[i]);
        }
    }

    /// @dev Tokens at tick 0 (one WETH each) whose reference supplies are `parts` whole tokens.
    function _flatBasket(uint256[] memory parts) internal returns (address[] memory tokens) {
        int24[] memory ticks = new int24[](parts.length);
        uint256[] memory supplies = new uint256[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            supplies[i] = parts[i] * WAD;
        }
        return _basket(ticks, supplies);
    }

    function _arr(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[] memory r) {
        r = new uint256[](5);
        (r[0], r[1], r[2], r[3], r[4]) = (a, b, c, d, e);
    }

    /// @dev A config with the market's default minimum liquidity; WETH's valid config sets it back to zero.
    function _config(address pool, uint256 referenceSupply, address[] memory excluded)
        internal
        pure
        returns (IIndexFactory.TokenConfig memory c)
    {
        c.pool = pool;
        c.minLiquidity = DEFAULT_MIN_LIQUIDITY;
        c.referenceSupply = referenceSupply;
        c.excluded = excluded;
    }

    // ---------------------------------------------------------------------
    // constructor
    // ---------------------------------------------------------------------

    function test_constructor() public view {
        assertEq(rule.FACTORY(), address(factory));
        assertEq(rule.WETH(), weth);
        assertEq(rule.USDC(), usdc);
        assertEq(rule.UNISWAP_V3_FACTORY(), address(market.uniswapV3Factory()));
        assertEq(rule.USD_POOL(), address(market.usdPool()));
        assertEq(rule.TWAP_WINDOW(), 30 minutes);
        assertEq(rule.TWAP_SUB_WINDOWS(), 3);
        assertEq(rule.MAX_TICK_DEVIATION(), 2_000);
        assertEq(rule.MIN_OBSERVATION_CARDINALITY(), 200);
        assertEq(rule.MAX_EXCLUDED(), 8);
        assertEq(rule.USD_POOL_FEE(), 500);
        assertEq(rule.MAX_TARGET_UNITS(), uint256(type(uint96).max) * 2 / 3);
    }

    function test_constructor_rejectsABadMarket() public {
        address v3 = address(market.uniswapV3Factory());
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new IndexRule(address(0), v3, usdc);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new IndexRule(weth, address(0), usdc);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new IndexRule(weth, v3, address(0));

        address noPool = address(new MockERC20("No Pool", "NOPE", 6));
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPool.selector, noPool, address(0)));
        new IndexRule(weth, v3, noPool);

        MockUniswapV3Pool usdPool = market.usdPool();
        usdPool.setObservationCardinality(199);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.PoolHistoryTooShort.selector, address(usdPool), 199));
        new IndexRule(weth, v3, usdc);
        usdPool.setObservationCardinality(200);
        new IndexRule(weth, v3, usdc);

        usdPool.setHistoryTooShort(true);
        vm.expectRevert(bytes("OLD"));
        new IndexRule(weth, v3, usdc);
    }

    // ---------------------------------------------------------------------
    // checkConfig
    // ---------------------------------------------------------------------

    function test_checkConfig_weth() public {
        address[] memory none = new address[](0);
        IIndexFactory.TokenConfig memory valid = _config(address(0), 120_000_000e18, none);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidMinLiquidity.selector, weth));
        rule.checkConfig(weth, valid); // WETH has no pool, so no minimum liquidity either
        valid.minLiquidity = 0;
        rule.checkConfig(weth, valid);

        address somePool = address(market.usdPool());
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPool.selector, weth, somePool));
        rule.checkConfig(weth, _config(somePool, 120_000_000e18, none));
        valid.referenceSupply = 0;
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidSupplyConfig.selector, weth));
        rule.checkConfig(weth, valid);
    }

    function test_checkConfig_pools() public {
        address[] memory none = new address[](0);
        address pool = market.configWith(LOW, 0, 1, none).pool;
        rule.checkConfig(LOW, _config(pool, 1, none));

        IIndexFactory.TokenConfig memory unguarded = _config(pool, 1, none);
        unguarded.minLiquidity = 0;
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidMinLiquidity.selector, LOW));
        rule.checkConfig(LOW, unguarded);

        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPool.selector, LOW, address(0)));
        rule.checkConfig(LOW, _config(address(0), 1, none));
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPool.selector, LOW, alice));
        rule.checkConfig(LOW, _config(alice, 1, none));

        // Another token's genuine pool, and a look-alike pool the Uniswap factory never deployed.
        address usdPool = address(market.usdPool());
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPool.selector, LOW, usdPool));
        rule.checkConfig(LOW, _config(usdPool, 1, none));
        address fake = address(new MockUniswapV3Pool(LOW, weth, 3000));
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPool.selector, LOW, fake));
        rule.checkConfig(LOW, _config(fake, 1, none));

        MockUniswapV3Pool(pool).setObservationCardinality(199);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.PoolHistoryTooShort.selector, pool, 199));
        rule.checkConfig(LOW, _config(pool, 1, none));
        MockUniswapV3Pool(pool).setObservationCardinality(1_000);
        MockUniswapV3Pool(pool).setHistoryTooShort(true);
        vm.expectRevert(bytes("OLD"));
        rule.checkConfig(LOW, _config(pool, 1, none));

        MockUniswapV3Pool(pool).setHistoryTooShort(false);
        market.setPriceTick(LOW, TickMath.MIN_TICK);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroPrice.selector, LOW));
        rule.checkConfig(LOW, _config(pool, 1, none));
    }

    function test_checkConfig_supplies() public {
        address[] memory none = new address[](0);
        address pool = market.configWith(LOW, 0, 1, none).pool;

        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroSupply.selector, LOW));
        rule.checkConfig(LOW, _config(pool, 0, none)); // nobody has minted LOW yet

        address burn = makeAddr("burn");
        address lock = makeAddr("lock");
        MockERC20(LOW).mint(alice, 100e18);
        MockERC20(LOW).mint(burn, 50e18);
        address[] memory excluded = new address[](2);
        (excluded[0], excluded[1]) = (burn, lock);
        rule.checkConfig(LOW, _config(pool, 0, excluded));

        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidSupplyConfig.selector, LOW));
        rule.checkConfig(LOW, _config(pool, 1, excluded)); // exclusions only apply to on-chain supply

        address[] memory duplicate = new address[](2);
        (duplicate[0], duplicate[1]) = (burn, burn);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidSupplyConfig.selector, LOW));
        rule.checkConfig(LOW, _config(pool, 0, duplicate));

        address[] memory tooMany = new address[](9);
        for (uint256 i = 0; i < 9; ++i) {
            tooMany[i] = address(uint160(0xB000 + i));
        }
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidSupplyConfig.selector, LOW));
        rule.checkConfig(LOW, _config(pool, 0, tooMany));

        // LR-05: and exactly MAX_EXCLUDED of them is still accepted, the side of the limit no test stood on.
        address[] memory most = new address[](8);
        for (uint256 i = 0; i < 8; ++i) {
            most[i] = tooMany[i];
        }
        rule.checkConfig(LOW, _config(pool, 0, most));

        address[] memory everyone = new address[](2);
        (everyone[0], everyone[1]) = (alice, burn);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroSupply.selector, LOW));
        rule.checkConfig(LOW, _config(pool, 0, everyone));
    }

    // ---------------------------------------------------------------------
    // prices and supplies
    // ---------------------------------------------------------------------

    function test_price_bothSidesOfThePool() public {
        _listAt(LOW, 0, 1);
        _listAt(HIGH, 0, 1);
        assertEq(rule.price(LOW), WAD);
        assertEq(rule.price(HIGH), WAD);
        assertEq(rule.price(weth), WAD);

        // Exact values of 1.0001^6932 * 1e18 and its inverse; both sides of the pool agree with them.
        market.setPriceTick(LOW, 6932);
        market.setPriceTick(HIGH, 6932);
        assertApproxEqRel(rule.price(LOW), 2000036323830947322, 1e6);
        assertApproxEqRel(rule.price(HIGH), 2000036323830947322, 1e6);
        market.setPriceTick(LOW, -100_000);
        market.setPriceTick(HIGH, 100_000);
        assertApproxEqRel(rule.price(LOW), 45422633889328, 1e8);
        assertApproxEqRel(rule.price(HIGH), 22015456048552198645701, 1e6);

        // Past a pool tick of about 443,636 the square root no longer fits 128 bits and the other formula applies.
        market.setPriceTick(LOW, TickMath.MAX_TICK);
        assertApproxEqRel(rule.price(LOW), 340256786836388094050805785052946541066751507546701582068, 1e6);
        market.setPriceTick(HIGH, TickMath.MIN_TICK);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroPrice.selector, HIGH));
        rule.price(HIGH);
    }

    function test_price_andSupplyOfATokenWithNoConfig() public {
        MockERC20 unlisted = new MockERC20("Unlisted", "NONE", 18);
        unlisted.mint(alice, 5e18);
        // No pool is configured, so the rule reads a codeless address and the decoder reverts without a reason.
        vm.expectRevert(bytes(""));
        rule.price(address(unlisted));
        assertEq(rule.supply(address(unlisted)), 5e18, "the plain total supply");
    }

    function test_price_usdcUsesTheUsdPool() public view {
        // About 3,000 USDC per ETH: WETH wei per 1e18 raw USDC units is about 1e18 * 1e12 / 3000.
        assertApproxEqRel(rule.price(usdc), uint256(1e30) / 3000, 1e15);
    }

    function test_price_meanTickRoundsTowardNegativeInfinity() public {
        _listAt(LOW, 0, 1);
        MockUniswapV3Pool pool = market.tokenPool(LOW);

        market.setPriceTick(LOW, -2);
        uint256 atMinusTwo = rule.price(LOW);
        market.setPriceTick(LOW, -1);
        uint256 atMinusOne = rule.price(LOW);
        market.setPriceTick(LOW, 1);
        uint256 atOne = rule.price(LOW);

        pool.setCumulatives(0, -1801); // mean -1.0006: rounds down to -2, like Uniswap's OracleLibrary
        assertEq(rule.price(LOW), atMinusTwo);
        pool.setCumulatives(0, -1800); // exactly -1
        assertEq(rule.price(LOW), atMinusOne);
        pool.setCumulatives(0, 1801); // positive means truncate
        assertEq(rule.price(LOW), atOne);

        pool.setCumulatives(0, int56(int256(TickMath.MAX_TICK) + 1) * 1800);
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidTick.selector, TickMath.MAX_TICK + 1));
        rule.price(LOW);
    }

    function test_supply() public {
        _listAt(LOW, 0, 7e18);
        assertEq(rule.supply(LOW), 7e18);

        address burn = makeAddr("burn");
        MockERC20 token = new MockERC20("Onchain", "ON", 18);
        token.mint(alice, 1_000e18);
        token.mint(burn, 400e18);
        address[] memory excluded = new address[](1);
        excluded[0] = burn;
        _list(address(token), market.configWith(address(token), 0, 0, excluded));
        assertEq(rule.supply(address(token)), 1_000e18);

        vm.prank(alice);
        token.transfer(burn, 1_000e18); // everything burned
        assertEq(rule.supply(address(token)), 0, "the view reports it");
        address[] memory burned = new address[](1);
        burned[0] = address(token);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroSupply.selector, address(token)));
        rule.weights(burned, UNCAPPED); // and the rule refuses to weigh it
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
        int24[] memory ticks = new int24[](2);
        uint256[] memory supplies = new uint256[](2);
        (ticks[0], ticks[1]) = (6932, 0);
        (supplies[0], supplies[1]) = (1e18, 2e18);
        address[] memory tokens = _basket(ticks, supplies);
        (uint256[] memory w, uint256[] memory prices, uint256[] memory got) = rule.weights(tokens, UNCAPPED);
        assertEq(got[0], 1e18);
        assertEq(got[1], 2e18);
        assertEq(prices[1], WAD);
        assertApproxEqRel(prices[0], 2000036323830947322, 1e6);
        assertApproxEqAbs(w[0], 0.5e18, 1e13, "two ETH-worth of caps each: 2 tokens at 1 ETH and 1 token at 2 ETH");
    }

    // ---------------------------------------------------------------------
    // targets
    // ---------------------------------------------------------------------

    function _hundreds() internal pure returns (uint256[] memory) {
        return _arr(100e18, 100e18, 100e18, 100e18, 100e18);
    }

    /// @dev XA-23: a mean tick near the extreme, with a supply large enough that supply * price would not fit in 256
    ///      bits, must still produce a snapshot instead of an arithmetic panic.
    function test_XA23_extremeTicksDoNotOverflowTheRule() public {
        int24[] memory ticks = new int24[](5);
        uint256[] memory supplies = new uint256[](5);
        ticks[0] = 880_000; // 1.0001^880000 is about 1.6e38, so a WAD price near 1.6e56
        supplies[0] = 1e33; // a SHIB-sized supply: the plain product is about 1.6e89
        for (uint256 i = 1; i < 5; ++i) {
            supplies[i] = 1e24;
        }
        address[] memory tokens = _basket(ticks, supplies);

        (uint256[] memory w,,) = rule.weights(tokens, UNCAPPED);
        assertGt(w[0], 0.99e18, "the extreme component takes almost the whole basket");
        // Units large enough that units * price would not fit either, so the basket's values are scaled as well.
        uint256[] memory units = _arr(1e24, 100e18, 100e18, 100e18, 100e18);
        (uint256[] memory t, uint256 turnover) = rule.targetUnits(tokens, units, UNCAPPED, 0);
        assertApproxEqRel(t[0], 1e24, 1e12, "it already holds the basket's value, so it barely moves");
        assertEq(t[1], 200e18, "the dust-weight components still take value up to their clip");
        assertEq(turnover, 0, "what it gives up is nothing next to the basket's value");

        // The same extreme price on a component the rule wants to shrink: the clips and the later passes still work.
        supplies[0] = 1e33;
        for (uint256 i = 1; i < 5; ++i) {
            supplies[i] = 1e72; // caps far above the extreme component's
        }
        tokens = _basket(ticks, supplies);
        (t,) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);
        assertApproxEqAbs(t[0], 100e18, 1, "the others can only double, so it keeps the value they cannot take");
        assertEq(t[1], 200e18, "the others are clipped at double");
    }

    /// @dev LR-09: XA-23 left one product unbounded. Next to a price above MAX_EXACT_PRICE, the unclipped units of a
    ///      component priced near zero, value over price, did not fit in 256 bits, and the snapshot panicked instead of
    ///      clipping that component at double. A share is now compared with the bounds as a value.
    function test_LR09_aNearZeroPriceNextToAnExtremeOneDoesNotOverflow() public {
        int24[] memory ticks = new int24[](2);
        uint256[] memory supplies = new uint256[](2);
        (ticks[0], ticks[1]) = (880_000, -400_000); // WAD prices of about 1.6e56 and 4
        (supplies[0], supplies[1]) = (1e18, 1e76); // so that the second carries real weight
        address[] memory tokens = _basket(ticks, supplies);
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
    function testFuzz_LR02_targetsAreAWaterFilling(uint256[5] memory unitSeeds, int24[5] memory tickSeeds, bool capped)
        public
    {
        address[] memory tokens = fuzzTokens;
        uint256[] memory units = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            // Whole-token magnitudes, so that rounding is far below the tolerance.
            units[i] = bound(unitSeeds[i], 1e18, 1e24);
            market.setPriceTick(tokens[i], int24(bound(tickSeeds[i], -20_000, 20_000)));
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

    function test_targetUnits_zeroWeightComponentsStillAbsorbValue() public {
        int24[] memory ticks = new int24[](2);
        uint256[] memory supplies = new uint256[](2);
        (supplies[0], supplies[1]) = (1e30, 1);
        address[] memory tokens = _basket(ticks, supplies);
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

    /// @dev Harmonic-mean liquidity of `pool` over the rule's window, read the way the rule reads it.
    function _harmonicOf(MockUniswapV3Pool pool) internal view returns (uint256) {
        uint32[] memory ago = new uint32[](4);
        (ago[0], ago[1], ago[2]) = (1800, 1200, 600);
        (, uint160[] memory perLiquidity) = pool.observe(ago);
        return uint256(1800) * type(uint160).max / (uint256(perLiquidity[3] - perLiquidity[0]) << 32);
    }

    /// @dev Makes `pool` report the tick-accumulator changes `a`, `b` and `c` over the window's three 10-minute parts,
    ///      at its current liquidity.
    function _parts(MockUniswapV3Pool pool, int56 a, int56 b, int56 c) internal {
        uint256 perSecond = (uint256(1) << 128) / pool.liquidity();
        pool.setObservation(1800, 0, 0);
        pool.setObservation(1200, a, uint160(600 * perSecond));
        pool.setObservation(600, a + b, uint160(1200 * perSecond));
        pool.setObservation(0, a + b + c, uint160(1800 * perSecond));
    }

    function test_targetUnits_snapshotNeedsTheConfiguredLiquidity() public {
        address[] memory tokens = _flatBasket(_arr(6, 1, 1, 1, 1));
        MockUniswapV3Pool pool = market.tokenPool(tokens[0]);
        uint256 harmonic = _harmonicOf(pool);
        assertApproxEqRel(harmonic, 1e18, 1e9, "a constant liquidity is its own harmonic mean");

        // Listing and snapshot share one bound, and a window exactly at the minimum passes both.
        IIndexFactory.TokenConfig memory config = market.configWith(tokens[0], 0, 6 * WAD, new address[](0));
        config.minLiquidity = uint128(harmonic);
        _list(tokens[0], config);
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);

        pool.setLiquidity(0.9e18);
        uint256 thin = _harmonicOf(pool);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ThinPriceHistory.selector, address(pool), thin, harmonic));
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ThinPriceHistory.selector, address(pool), thin, harmonic));
        rule.checkConfig(tokens[0], config);

        // Display prices and weights do not apply the snapshot checks.
        assertEq(rule.price(tokens[0]), WAD);
        (uint256[] memory w,,) = rule.weights(tokens, UNCAPPED);
        assertGt(w[0], 0);
    }

    function test_targetUnits_snapshotNeedsAgreeingSubWindows() public {
        address[] memory tokens = _flatBasket(_arr(6, 1, 1, 1, 1));
        MockUniswapV3Pool pool = market.tokenPool(tokens[0]);

        _parts(pool, 0, 0, 2_000 * 600); // the last part's mean tick is exactly MAX_TICK_DEVIATION above the others
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);

        _parts(pool, 0, 0, 2_001 * 600);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.PriceHistoryDeviates.selector, address(pool), 2_001));
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);

        _parts(pool, 0, -2_001 * 600, 0); // an outlier below counts the same
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.PriceHistoryDeviates.selector, address(pool), 2_001));
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);

        // LR-05: and so does one in the oldest part, which no test placed there: a spread that skipped it passed.
        _parts(pool, 2_001 * 600, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.PriceHistoryDeviates.selector, address(pool), 2_001));
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);
        assertGt(rule.price(tokens[0]), 0, "display prices still read the window");
    }

    function test_XA05_keptComponentsNeedNoSnapshotPrice() public {
        address[] memory tokens = _flatBasket(_arr(6, 1, 1, 1, 1));
        (uint256[] memory readable,) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 1 << 4);
        MockUniswapV3Pool broken = market.tokenPool(tokens[4]);
        broken.setHistoryTooShort(true);
        vm.expectRevert(bytes("OLD"));
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);

        // Uncapped: a kept component is renormalised away, so its pool is never read.
        (uint256[] memory t, uint256 turnover) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 1 << 4);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(t[i], readable[i]);
        }
        assertGt(turnover, 0);

        // Capped: a kept component is still ranked, from a price without the snapshot checks.
        broken.setHistoryTooShort(false);
        broken.setLiquidity(1);
        uint256 thin = _harmonicOf(broken);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexRule.ThinPriceHistory.selector, address(broken), thin, DEFAULT_MIN_LIQUIDITY)
        );
        rule.targetUnits(tokens, _hundreds(), CAPPED, 0);
        rule.targetUnits(tokens, _hundreds(), CAPPED, 1 << 4);
        broken.setHistoryTooShort(true);
        vm.expectRevert(bytes("OLD"));
        rule.targetUnits(tokens, _hundreds(), CAPPED, 1 << 4);
    }

    function test_targetUnits_snapshotPricesWethAndRejectsZeroPriceOrSupply() public {
        address[] memory tokens = _flatBasket(_arr(6, 1, 1, 1, 1));
        _listAt(weth, 0, 6 * WAD);
        tokens[0] = weth; // worth one WETH per unit without a pool, like the token it replaces
        (uint256[] memory t,) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);
        assertEq(t[0], 200e18);

        market.setPriceTick(tokens[1], TickMath.MIN_TICK);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroPrice.selector, tokens[1]));
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);
        market.setPriceTick(tokens[1], 0);

        address burn = makeAddr("burn");
        MockERC20 onChain = new MockERC20("Onchain", "ON", 18);
        onChain.mint(alice, 1_000e18);
        address[] memory excluded = new address[](1);
        excluded[0] = burn;
        _list(address(onChain), market.configWith(address(onChain), 0, 0, excluded));
        tokens[2] = address(onChain);
        vm.prank(alice);
        onChain.transfer(burn, 1_000e18); // everything burned after listing
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroSupply.selector, address(onChain)));
        rule.targetUnits(tokens, _hundreds(), UNCAPPED, 0);
    }

    function test_XA09_XA45_constantsStayInTheirRelationships() public view {
        assertEq(rule.TWAP_WINDOW() % rule.TWAP_SUB_WINDOWS(), 0, "the parts split the window exactly");
        // One observation per block at most: the ring covers the window at 12-second slots, and down to 9.05 seconds.
        assertGe(uint256(rule.MIN_OBSERVATION_CARDINALITY() - 1) * 12, rule.TWAP_WINDOW());
        assertGe(uint256(rule.MIN_OBSERVATION_CARDINALITY() - 1) * 905, uint256(rule.TWAP_WINDOW()) * 100);
        // One extreme 12-second block moves its part's mean tick far past the deviation bound.
        assertGt(uint256(uint24(TickMath.MAX_TICK)) * 12 / (rule.TWAP_WINDOW() / rule.TWAP_SUB_WINDOWS()), 8 * 2_000);
        assertEq(rule.MAX_TICK_DEVIATION(), 2_000);
        // The auction's 1.5 opening multiplier on a target at MAX_TARGET_UNITS still fits uint96 units.
        assertLe(rule.MAX_TARGET_UNITS() * 3 / 2, type(uint96).max);
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
        int24[5] memory tickSeeds,
        uint256 keepSeed,
        bool capped
    ) public {
        address[] memory tokens = fuzzTokens;
        uint256[] memory units = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            units[i] = bound(unitSeeds[i], 1, 1e30);
            market.setPriceTick(tokens[i], int24(bound(tickSeeds[i], -20_000, 20_000)));
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

    function _sheetTicks(bool scenario) internal pure returns (int24[] memory ticks) {
        ticks = new int24[](7);
        if (scenario) {
            (ticks[0], ticks[1], ticks[2], ticks[3]) = (-93558, -194173, -192891, -114655);
            (ticks[4], ticks[5], ticks[6]) = (-73799, -184116, -56552);
        } else {
            (ticks[0], ticks[1], ticks[2], ticks[3]) = (-94141, -192548, -194714, -113602);
            (ticks[4], ticks[5], ticks[6]) = (-73287, -185939, -58376);
        }
    }

    /// @dev The model's seven tokens with its circulating quantities and prices at 3,000 USD per ETH.
    function _sheetTokens() internal returns (address[] memory) {
        uint256[] memory supplies = new uint256[](7);
        (supplies[0], supplies[1], supplies[2]) = (150_880_000_000e18, 589_240_000_000_000e18, 420_680_000_000_000e18);
        (supplies[3], supplies[4], supplies[5], supplies[6]) =
        (62_860_000_000e18, 1_030_000_000e18, 81_100_000_000_000e18, 199_990_000e18);
        return _basket(_sheetTicks(false), supplies);
    }

    function _setTicks(address[] memory tokens, int24[] memory ticks) internal {
        for (uint256 i = 0; i < tokens.length; ++i) {
            market.setPriceTick(tokens[i], ticks[i]);
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
        uint256[] memory uncappedUnits = rule.initialUnits(tokens, UNCAPPED, 1_000e6);
        uint256[] memory cappedUnits = rule.initialUnits(tokens, CAPPED, 1_000e6);
        IndexToken uncapped = IndexToken(factory.createIndex("Memes", "MEME", tokens, uncappedUnits, UNCAPPED));
        IndexToken capped = IndexToken(factory.createIndex("Capped Memes", "CMEME", tokens, cappedUnits, CAPPED));

        (uint256 wethValue, uint256 usdcValue) = rule.navPerToken(address(uncapped));
        assertApproxEqRel(usdcValue, 1_000e6, 1e12, "starts at the chosen price");
        assertApproxEqRel(wethValue, 1_000e6 * rule.price(usdc) / WAD, 1e12);
        (, uint256 cappedStart) = rule.navPerToken(address(capped));
        assertApproxEqRel(cappedStart, 1_000e6, 1e12);

        uint256 capsBefore = _caps(tokens);
        _setTicks(tokens, _sheetTicks(true));
        (, uint256 uncappedAfter) = rule.navPerToken(address(uncapped));
        assertApproxEqRel(uncappedAfter, 1_000e6 * _caps(tokens) / capsBefore, 1e12, "equals the divisor price");
        assertApproxEqRel(uncappedAfter, 1_041.8e6, 1e14, "the model's 1041.80, up to tick rounding");
        (, uint256 cappedAfter) = rule.navPerToken(address(capped));
        assertApproxEqRel(cappedAfter, 1_041.11e6, 2e14, "the capped basket's own value");

        // The top coin doubles: the model's formula would show about 1,647, while the capped basket is worth 1,300.
        _setTicks(tokens, _sheetTicks(false));
        market.setPriceTick(tokens[0], _sheetTicks(false)[0] + 6932);
        (, uint256 uncappedDouble) = rule.navPerToken(address(uncapped));
        (, uint256 cappedDouble) = rule.navPerToken(address(capped));
        assertApproxEqRel(uncappedDouble, 1_647.29e6, 1e14);
        assertApproxEqRel(cappedDouble, 1_300e6, 1e14);
    }

    function test_navPerToken_onlyForIndexes() public {
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, alice));
        rule.navPerToken(alice);
    }

    function test_initialUnits_areAtLeastOne() public {
        int24[] memory ticks = new int24[](1);
        uint256[] memory supplies = new uint256[](1);
        ticks[0] = 200_000;
        supplies[0] = 1e18;
        address[] memory tokens = _basket(ticks, supplies);
        uint256[] memory units = rule.initialUnits(tokens, UNCAPPED, 1);
        assertEq(units[0], 1);
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
    ///      and a one-tick move on one pool no longer puts an eighth of it up for auction. Before the fix the same
    ///      basket's on-methodology units were 150/87.5x4 and one tick produced 12.4995% turnover from any address.
    function test_VR01_aOneTickMoveNoLongerClearsMinTurnover() public {
        address[] memory tokens = _flatBasket(_arr(1000, 1000, 1000, 1000, 1000));
        uint256[] memory onRule = _arr(100e18, 100e18, 100e18, 100e18, 100e18);
        IndexToken idx = IndexToken(factory.createIndex("Capped", "CAP", tokens, onRule, CAPPED));
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());

        (uint256[] memory t, uint256 turnover) = idx.previewTarget(0);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(t[i], onRule[i], "equal caps, equal weights: the index is exactly on its methodology");
        }
        assertEq(turnover, 0);

        market.setPriceTick(tokens[1], 1);
        (, turnover) = idx.previewTarget(0);
        assertLt(turnover, idx.MIN_TURNOVER(), "one tick no longer clears the dust filter");
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

        market.setPriceTick(tokens[4], 40_000); // only the KEPT component's pool moves
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
        market.setPriceTick(tokens[5], 40_000); // only the KEPT component's pool
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
        market.setPriceTick(tokens[4], 40_000);
        (uint256[] memory afterwards,) = rule.targetUnits(tokens, _hundreds(), UNCAPPED, 1 << 4);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(before[i], afterwards[i], "an uncapped snapshot never reads a kept component");
        }
    }

    /// @dev VR-06a. `_clip`'s floor is load-bearing on the WAD value scale. A component priced below WAD there --
    ///      so its whole floor rounds to nothing -- and carrying a weight small enough that its share of a few wei of
    ///      active value rounds to zero buys back zero units. Without the floor its target would be zero: backing the
    ///      index no longer owes on a component it still holds, and a component the rule can never restore, since
    ///      every later target is bounded by half to double of zero. Reached through the capped rule, whose kept
    ///      component sets the scale from outside the active set, so the active value stays a few wei.
    function test_VR06_theClipFloorKeepsAZeroShareAtItsFloor() public {
        int24[] memory ticks = new int24[](6);
        uint256[] memory supplies = new uint256[](6);
        (ticks[0], supplies[0]) = (880_000, 1e24); // kept: an extreme price that forces Basket.scale to WAD
        for (uint256 i = 1; i < 5; ++i) {
            (ticks[i], supplies[i]) = (-400_000, 1e24); // four wei per 1e18 units, and a real weight
        }
        (ticks[5], supplies[5]) = (-400_000, 1); // the same price, but a cap of one wei

        address[] memory tokens = _basket(ticks, supplies);
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
        int24[] memory ticks = new int24[](5);
        uint256[] memory supplies = new uint256[](5);
        ticks[0] = 880_000;
        supplies[0] = 1e24;
        for (uint256 i = 1; i < 5; ++i) {
            (ticks[i], supplies[i]) = (-400_000, 1e24);
        }
        address[] memory tokens = _basket(ticks, supplies);

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
