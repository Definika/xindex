// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {XindexTest} from "../XindexTest.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket, DEFAULT_STALENESS} from "../mocks/MockMarket.sol";
import {TestAggregator} from "../../script/testnet/TestAggregator.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";

/// @notice Independent verification: DA-18's MAX_SUPPLY_CHANGE bound (IndexFactory._checkSupplyChange) returns early
///         whenever the supply in force or the proposed one is 0, although 0 means "use totalSupply" in the rule.
contract VerifySupplyBoundZeroTest is XindexTest {
    // Mainnet figures (MainnetAddresses.sol and totalSupply at block ~26,034,862).
    uint256 constant BTC_SUPPLY = 20_087_871e8;
    uint256 constant WBTC_FLOAT = 11_613_218_273_272; // 116,132.18 WBTC
    uint256 constant ETH_SUPPLY = 122_070_499e18;
    uint256 constant WSTETH_FLOAT = 3_724_193_394_675_926_501_176_662;

    int256 constant BTC_PRICE = 110_000e8;
    int256 constant ETH_PRICE = 4_000e8;
    int256 constant WSTETH_PRICE = 4_900e8;

    MockERC20 wbtc;
    MockERC20 weth;
    MockERC20 wsteth;
    IIndexRule rule;
    address guardian = makeAddr("guardian");

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        rule = IIndexRule(factory.RULE());
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wsteth = new MockERC20("Wrapped stETH", "wstETH", 18);
        wbtc.mint(address(0xB0B), WBTC_FLOAT);
        weth.mint(address(0xB0B), 2_080_993e18);
        wsteth.mint(address(0xB0B), WSTETH_FLOAT);

        vm.startPrank(owner);
        factory.proposeListing(address(wbtc), market.configWith(address(wbtc), BTC_PRICE, BTC_SUPPLY));
        factory.proposeListing(address(weth), market.configWith(address(weth), ETH_PRICE, ETH_SUPPLY));
        factory.proposeListing(address(wsteth), market.configWith(address(wsteth), WSTETH_PRICE, 0));
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(wbtc));
        factory.executeListing(address(weth));
        factory.executeListing(address(wsteth));
    }

    function _proposeAndExecute(address token, uint256 referenceSupply) internal {
        IIndexFactory.TokenConfig memory c = factory.tokenConfig(token);
        c.referenceSupply = referenceSupply;
        vm.prank(owner);
        factory.proposeConfig(token, c);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    /// (1) R -> 0 moves the effective supply 173x, which a direct proposal of the same figure cannot.
    /// (2) 0 -> 1 then reaches 1 raw unit, which a direct R -> 1 proposal cannot.
    function test_R_to_zero_to_one_walksAroundTheBound() public {
        assertEq(rule.supply(address(wbtc)), BTC_SUPPLY);

        // Direct proposals of the float figure and of 1 raw unit are refused.
        IIndexFactory.TokenConfig memory c = factory.tokenConfig(address(wbtc));
        c.referenceSupply = WBTC_FLOAT;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexFactory.SupplyChangeTooLarge.selector, address(wbtc), BTC_SUPPLY, WBTC_FLOAT)
        );
        factory.proposeConfig(address(wbtc), c);
        c.referenceSupply = 1;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexFactory.SupplyChangeTooLarge.selector, address(wbtc), BTC_SUPPLY, uint256(1))
        );
        factory.proposeConfig(address(wbtc), c);

        // Step 1: R -> 0 is accepted and the effective supply drops to the float.
        uint256 t0 = block.timestamp;
        _proposeAndExecute(address(wbtc), 0);
        uint256 afterZero = rule.supply(address(wbtc));
        assertEq(afterZero, WBTC_FLOAT);
        assertGt(BTC_SUPPLY / afterZero, 170, "effective supply fell by more than 170x in one step");
        console2.log("R -> 0 cut factor", BTC_SUPPLY / afterZero);

        // Step 2: 0 -> 1 is accepted too.
        _proposeAndExecute(address(wbtc), 1);
        assertEq(rule.supply(address(wbtc)), 1);
        assertEq(block.timestamp - t0, 2 * factory.LISTING_DELAY(), "two proposals, four days");
    }

    /// A token priced from its own totalSupply (the shipped wstETH entry has WSTETH_SUPPLY = 0) takes any figure in one
    /// step: 1 raw unit, a whole-token slip, or an upward decimals slip.
    function test_onchainSupplyToken_takesAnyReferenceInOneStep() public {
        assertEq(rule.supply(address(wsteth)), WSTETH_FLOAT);

        uint256 snap = vm.snapshotState();
        _proposeAndExecute(address(wsteth), 1);
        assertEq(rule.supply(address(wsteth)), 1);
        vm.revertToState(snap);

        _proposeAndExecute(address(wsteth), 3_724_191); // whole tokens typed as raw units
        assertEq(rule.supply(address(wsteth)), 3_724_191);
        vm.revertToState(snap);

        _proposeAndExecute(address(wsteth), WSTETH_FLOAT * 1e10); // upward slip
        assertEq(rule.supply(address(wsteth)), WSTETH_FLOAT * 1e10);
    }

    /// The script turns a three-field entry into referenceSupply 0 and safe mode emits a proposeConfig the factory
    /// accepts, although the entry only meant to refresh the feed.
    function test_threeFieldEntry_becomesAnUncheckedSupplySwitch() public {
        ConfigureWhitelist configure = new ConfigureWhitelist();
        TestAggregator newFeed = new TestAggregator("WBTC / USD", 8, BTC_PRICE);
        string memory raw = string.concat(vm.toString(address(wbtc)), ":", vm.toString(address(newFeed)), ":5400");
        ConfigureWhitelist.Entry memory e = configure.parseEntry(raw);
        assertEq(e.referenceSupply, 0, "missing 4th field parses as 0");
        // A trailing colon too.
        assertEq(configure.parseEntry(string.concat(raw, ":")).referenceSupply, 0);

        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](1);
        list[0] = e;
        bytes[] memory calls = configure.safeCalldata(factory, list, new address[](0));
        assertEq(calls.length, 1, "one proposeConfig");
        IIndexFactory.TokenConfig memory expected =
            IIndexFactory.TokenConfig({feed: address(newFeed), maxStaleness: 5400, referenceSupply: 0});
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeConfig, (address(wbtc), expected)));

        vm.prank(owner);
        (bool ok,) = address(factory).call(calls[0]);
        assertTrue(ok, "factory accepts the supply switch");
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        newFeed.setAnswer(BTC_PRICE);
        factory.executeListing(address(wbtc));
        assertEq(rule.supply(address(wbtc)), WBTC_FLOAT, "effective supply now the float");
    }

    /// Downstream: equal-value uncapped WBTC/WETH/wstETH index. WBTC's target goes from its ceiling (2x) to its floor
    /// (1/2) after the unchecked R -> 0 switch.
    function test_downstream_targetSwingsCeilingToFloor() public {
        address[] memory t = new address[](3);
        t[0] = address(wbtc);
        t[1] = address(weth);
        t[2] = address(wsteth);
        uint256[] memory u = new uint256[](3);
        u[0] = 909_090; // $1,000 of WBTC at $110k
        u[1] = 0.25e18; // $1,000 of WETH at $4k
        u[2] = 204_081_632_653_061_224; // $1,000 of wstETH at $4.9k

        (uint256[] memory wBefore,,) = rule.weights(t, 0);
        (uint256[] memory before,) = rule.targetUnits(t, u, 0, 0);
        _proposeAndExecute(address(wbtc), 0);
        market.setPrice(address(weth), ETH_PRICE);
        market.setPrice(address(wsteth), WSTETH_PRICE);
        (uint256[] memory wAfter,,) = rule.weights(t, 0);
        (uint256[] memory afterT,) = rule.targetUnits(t, u, 0, 0);

        console2.log("WBTC weight before (1e18=100%)", wBefore[0]);
        console2.log("WBTC weight after", wAfter[0]);
        console2.log("WBTC target before", before[0]);
        console2.log("WBTC target after", afterT[0]);
        assertEq(before[0], 2 * u[0], "ceiling before");
        assertEq(afterT[0], (u[0] + 1) / 2, "floor after");
        assertGt(wBefore[0], 0.8e18);
        assertLt(wAfter[0], 0.03e18);
    }

    /// Calibration: the owner already moves a component's market cap by any factor in one step through the feed, which
    /// no bound covers, so the supply bound restrains only operator error in the supply field, not a malicious owner.
    function test_calibration_feedRepointIsUnboundedAnyway() public {
        TestAggregator cheap = new TestAggregator("WBTC / USD", 8, BTC_PRICE / 1e10);
        IIndexFactory.TokenConfig memory c = factory.tokenConfig(address(wbtc));
        uint256 before = rule.price(address(wbtc));
        c.feed = address(cheap);
        vm.prank(owner);
        factory.proposeConfig(address(wbtc), c);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        cheap.setAnswer(BTC_PRICE / 1e10);
        factory.executeListing(address(wbtc));
        assertEq(before / rule.price(address(wbtc)), 1e10, "cap moved 1e10x in one step through the feed");
    }
}
