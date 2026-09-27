// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexRule} from "../../src/IndexRule.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

/// @notice Killing tests for IndexRule mutants that survive the whole offline suite (mutation-hunter, 2026-09-24).
contract RuleMutationGapsTest is Test {
    MockMarket market;
    IndexFactory factory;
    IndexRule rule;
    address owner = makeAddr("owner");
    uint8 constant UNCAPPED = 0;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, address(0));
        rule = IndexRule(factory.RULE());
    }

    function _list(address token, IIndexFactory.TokenConfig memory config) internal {
        vm.prank(owner);
        factory.proposeListing(token, config);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    /// @dev An 18-decimal token behind an 18-decimal feed, so the feed answer is the WAD price itself.
    function _listWad(uint256 wadPrice, uint256 referenceSupply) internal returns (address token) {
        token = address(new MockERC20("W", "W", 18));
        _list(token, market.configWithFeed(token, int256(wadPrice), 18, referenceSupply));
    }

    /// @dev MH-R1. `_cap` floors a market cap at one wei. The only test of the floor (CR-I32) puts a sub-wei cap next
    ///      to a cap of exactly one wei, so a floor of two gives both components the same weight too, and the mutant
    ///      `Math.max(..., 2)` survives. Next to a cap of three wei, the floor's value shows: 1:3 against 2:3.
    function test_MHR1_theCapFloorIsExactlyOneWei() public {
        address[] memory tokens = new address[](2);
        tokens[0] = _listWad(0.5e18, 1); // half a wei of cap: floored
        tokens[1] = _listWad(3e18, 1); // exactly three wei
        (uint256[] memory w,,) = rule.weights(tokens, UNCAPPED);
        assertEq(w[0], 0.25e18, "a sub-wei cap weighs one wei against three");
        assertEq(w[1], 0.75e18);
    }

    /// @dev MH-R2. `_bound` counts a weight that rounds to zero as one wei, so a component too small to weigh anything
    ///      can still take the value the clips move (R23). Every test of it leaves that component the only one still
    ///      free once the clips are pinned, where any positive weight takes 100% of what is left, so the mutant
    ///      `basket.weights[i] = 2` survives. Here a second free component weighs exactly three wei: the shipped rule
    ///      shares the remainder 3:1, so the floored component lands on its floor and is pinned; the mutant shares
    ///      it 3:2 and moves 29.6 more tokens of value into the dust-cap component.
    function test_MHR2_aZeroWeightCountsAsExactlyOneWei() public {
        address[] memory tokens = new address[](3);
        // Caps at a WAD price of 1e18 equal the raw supplies: they add up to exactly 1e36.
        tokens[0] = _listWad(1e18, 1e36 - 3e18 - 1);
        tokens[1] = _listWad(1e18, 3e18);
        tokens[2] = _listWad(1e18, 1);
        (uint256[] memory w,,) = rule.weights(tokens, UNCAPPED);
        assertEq(w[0], 1e18 - 4);
        assertEq(w[1], 3, "a weight of exactly three wei");
        assertEq(w[2], 0, "and one that rounds to zero");

        uint256[] memory units = new uint256[](3);
        (units[0], units[1], units[2]) = (1e18, 100e18, 100e18);
        (uint256[] memory t,) = rule.targetUnits(tokens, units, UNCAPPED, 0);
        // Pass 1 clips the heavy component to its ceiling (2e18) and pins it. Pass 2 shares the remaining 199e18 as
        // 3:1: 149.25e18 and 49.75e18, which is under the dust component's floor of 50e18, so it is pinned there. Pass 3
        // gives the rest to the second component. With a floor weight of two, pass 2 is 119.4e18 and 79.6e18, inside
        // both bounds, and the rule stops there.
        assertEq(t[0], 2e18, "the heavy component doubles");
        assertEq(t[1], 149e18, "the three-wei component takes the rest");
        assertEq(t[2], 50e18, "the zero-weight component is pinned at its floor");
    }

    /// @dev MH-R3. `_price` refuses `answer > MAX_PRICE / scale`, the bound every overflow argument in the rule rests
    ///      on. Its only test lists an 18-decimal feed on an 18-decimal token, where the scale is one, so the mutant
    ///      `answer > MAX_PRICE` (the scale forgotten) survives. Every launch token has a scale above one (8-decimal
    ///      feeds on 18-, 8- and 9-decimal tokens: 1e10, 1e20, 1e19), and there the mutant lets a price up to
    ///      MAX_PRICE * scale through, past the range the rule's value products are proved for.
    function test_MHR3_thePriceCeilingIsAppliedAfterScaling() public {
        MockERC20 token = new MockERC20("Eighteen", "E18", 18);
        _list(address(token), market.config(address(token), 1e8)); // an 8-decimal feed: scale 1e10
        uint256 atCeiling = rule.MAX_PRICE() / 1e10;
        market.setPrice(address(token), int256(atCeiling));
        assertEq(rule.price(address(token)), rule.MAX_PRICE(), "the ceiling itself, reached through the scale");
        market.setPrice(address(token), int256(atCeiling + 1));
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.PriceTooHigh.selector, address(token), int256(atCeiling + 1)));
        rule.price(address(token));
    }
}
