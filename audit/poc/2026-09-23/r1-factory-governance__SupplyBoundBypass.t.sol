// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

/// @notice r1-factory-governance: the DA-18 per-step bound on reference supplies (`IndexFactory._checkSupplyChange`)
///         returns early whenever the supply in force or the proposed one is zero, and zero means "the token's own
///         totalSupply". The effective supply the rule reads can therefore move by any factor in one step (R -> 0 on a
///         wrapped asset, or 0 -> R on a token priced from its own supply) and to any value in two (R -> 0 -> R').
contract SupplyBoundBypassTest is Test {
    MockMarket market;
    IndexFactory factory;
    IIndexRule rule;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    MockERC20 wbtc; // 8 decimals, on-chain float much smaller than bitcoin's supply
    MockERC20 weth; // 18 decimals, reference supply = ether's supply
    MockERC20 wsteth; // 18 decimals, priced from its own totalSupply (reference supply 0), like the shipped wstETH

    // Mainnet figures: script/MainnetAddresses.sol and on-chain totalSupply at block 26,034,668.
    uint256 constant BTC_SUPPLY = 20_087_871e8; // MainnetAddresses.BTC_SUPPLY
    uint256 constant WBTC_FLOAT = 116_132e8; // WBTC.totalSupply() = 11,613,218,273,272
    uint256 constant ETH_SUPPLY = 122_070_499e18; // MainnetAddresses.ETH_SUPPLY
    uint256 constant WSTETH_FLOAT = 3_724_191e18; // wstETH.totalSupply() = 3.724e24
    uint32 constant STALENESS = 5_400;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        rule = IIndexRule(factory.RULE());
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wsteth = new MockERC20("Wrapped liquid staked Ether 2.0", "wstETH", 18);
        wbtc.mint(address(0xB0B), WBTC_FLOAT);
        wsteth.mint(address(0xB0B), WSTETH_FLOAT);

        _listNow(address(wbtc), market.configWith(address(wbtc), 110_000e8, BTC_SUPPLY));
        _listNow(address(weth), market.configWith(address(weth), 4_000e8, ETH_SUPPLY));
        _listNow(address(wsteth), market.configWith(address(wsteth), 4_800e8, 0));
    }

    function _listNow(address token, IIndexFactory.TokenConfig memory config) internal {
        vm.prank(owner);
        factory.proposeListing(token, config);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    function _changeSupply(address token, uint256 referenceSupply) internal {
        IIndexFactory.TokenConfig memory c = factory.tokenConfig(token);
        c.referenceSupply = referenceSupply;
        vm.prank(owner);
        factory.proposeConfig(token, c);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    /// @dev The lead. A direct move to one raw unit is refused, but R -> 0 -> 1 goes through in two proposals (four days),
    ///      where the documented bound implies ceil(log10(2.0e15)) = 16 proposals (32+ days).
    function test_twoStepsThroughZeroMoveAReferenceSupplyByAnyFactor() public {
        uint256 t0 = block.timestamp;
        IIndexFactory.TokenConfig memory typo = factory.tokenConfig(address(wbtc));
        typo.referenceSupply = 1;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexFactory.SupplyChangeTooLarge.selector, address(wbtc), BTC_SUPPLY, uint256(1))
        );
        factory.proposeConfig(address(wbtc), typo);

        // Step 1: a "change of kind" to on-chain supply. Unchecked, and it alone moves the effective supply 173x.
        assertEq(rule.supply(address(wbtc)), BTC_SUPPLY);
        _changeSupply(address(wbtc), 0);
        assertEq(rule.supply(address(wbtc)), WBTC_FLOAT);
        assertGt(BTC_SUPPLY / rule.supply(address(wbtc)), 170, "one step moved the effective supply > 170x");

        // Step 2: inForce == 0, so any figure is accepted, including the very "1 raw unit" DA-18 names.
        _changeSupply(address(wbtc), 1);
        assertEq(rule.supply(address(wbtc)), 1);
        assertEq(block.timestamp - t0, 2 * factory.LISTING_DELAY(), "four days, two proposals");
        assertGt(BTC_SUPPLY, 1e15, "a factor of 2e15, 15+ orders of magnitude");
    }

    /// @dev A token priced from its own totalSupply (the shipped wstETH entry is exactly this) takes the "1 raw unit"
    ///      figure the DA-18 triage says is caught, in a single step.
    function test_aTokenOnItsOwnSupplyTakesOneRawUnitInOneStep() public {
        assertEq(factory.tokenConfig(address(wsteth)).referenceSupply, 0);
        assertEq(rule.supply(address(wsteth)), WSTETH_FLOAT);
        _changeSupply(address(wsteth), 1);
        assertEq(rule.supply(address(wsteth)), 1, "3.7e24x drop in one timelocked step");

        // and the decimals slip the triage says is caught, a 1e10-too-large figure, also passes from zero
        _changeSupply(address(wsteth), 0);
        _changeSupply(address(wsteth), WSTETH_FLOAT * 1e10);
        assertEq(rule.supply(address(wsteth)), WSTETH_FLOAT * 1e10);
    }

    /// @dev The realistic mistake: a routine feed refresh through ConfigureWhitelist with a three-field entry. The script
    ///      reads a missing fourth field as 0, proposes it as a config change, and the factory accepts it; the script's
    ///      "reference supply in whole tokens" log line is skipped for 0, so nothing on screen shows the supply moved.
    function test_aThreeFieldScriptEntryDropsWbtcToItsFloatUnchecked() public {
        ConfigureWhitelist configure = new ConfigureWhitelist();
        address newFeed = address(market.feedOf(address(wbtc))); // same answer, the "repointed" aggregator
        string memory raw =
            string.concat(vm.toString(address(wbtc)), ":", vm.toString(newFeed), ":", vm.toString(uint256(88_200)));
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](1);
        list[0] = configure.parseEntry(raw);
        assertEq(list[0].referenceSupply, 0, "missing field parses as on-chain supply");

        bytes[] memory calls = configure.safeCalldata(IIndexFactory(address(factory)), list, new address[](0));
        assertEq(calls.length, 1, "the script proposes it");
        vm.prank(owner);
        (bool ok,) = address(factory).call(calls[0]);
        assertTrue(ok, "the factory accepts it: no SupplyChangeTooLarge");
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(wbtc));
        assertEq(rule.supply(address(wbtc)), WBTC_FLOAT, "bitcoin's 20.09M became WBTC's 116k float");
    }

    /// @dev Downstream: in an equal-value WBTC/WETH/wstETH index the rule wants WBTC doubled (it is 81% of the three
    ///      market caps). After the single unchecked R -> 0 step it wants WBTC at 2.5%, so the very next snapshot drives
    ///      it to its floor instead: a 4x swing in its target from one config change the DA-18 bound never looked at.
    function test_theUncheckedStepDrivesTheComponentToItsFloor() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(wbtc);
        tokens[1] = address(weth);
        tokens[2] = address(wsteth);
        uint256[] memory units = new uint256[](3);
        units[0] = 909_090; // $1,000 of WBTC at $110k
        units[1] = 0.25e18; // $1,000 of WETH at $4k
        units[2] = 208_333_333_333_333_333; // $1,000 of wstETH at $4.8k
        IndexToken index = IndexToken(factory.createIndex("BTC-ETH-stETH", "BES", tokens, units, 0));
        uint256[] memory need = index.previewIssue(100e18);
        for (uint256 i = 0; i < 3; ++i) {
            MockERC20(tokens[i]).mint(alice, need[i]);
            vm.prank(alice);
            MockERC20(tokens[i]).approve(address(index), need[i]);
        }
        vm.prank(alice);
        index.issue(100e18, alice);

        (uint256[] memory wanted,) = index.previewTarget(0);
        assertEq(wanted[0], 2 * units[0], "before: the rule doubles WBTC");

        _changeSupply(address(wbtc), 0); // one step, unbounded, within the documented flow

        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        index.startRebalance(0);
        (,, uint256[] memory targets) = index.pendingRebalance();
        assertEq(targets[0], (units[0] + 1) / 2, "after: WBTC pinned at its floor, half of it sold at auction");
        emit log_named_uint("WBTC target before the step", wanted[0]);
        emit log_named_uint("WBTC target after the step ", targets[0]);
    }

    /// @dev Info: the script mirrors the rule's checkConfig but not the factory's supply bound, so an out-of-bound entry
    ///      is not "skipped and logged" as the README promises for rejected entries; safe mode emits calldata the factory
    ///      is certain to revert (and inside a Safe MultiSend batch that reverts every other proposal with it).
    function test_scriptEmitsAProposalTheFactoryMustRevert() public {
        ConfigureWhitelist configure = new ConfigureWhitelist();
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](1);
        list[0] = ConfigureWhitelist.Entry({
            token: address(weth),
            feed: address(market.feedOf(address(weth))),
            maxStaleness: STALENESS,
            referenceSupply: ETH_SUPPLY * 100
        });
        bytes[] memory calls = configure.safeCalldata(IIndexFactory(address(factory)), list, new address[](0));
        assertEq(calls.length, 1, "the script does not skip it");
        vm.prank(owner);
        (bool ok, bytes memory ret) = address(factory).call(calls[0]);
        assertFalse(ok);
        assertEq(bytes4(ret), IIndexFactory.SupplyChangeTooLarge.selector);
    }
}
