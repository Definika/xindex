// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeightedMath} from "../src/WeightedMath.sol";

/// @notice A Halmos harness for `WeightedMath.settlement`, run by Halmos, not by forge: every argument of a `check_`
///         function is symbolic, so a passing check holds for every value its assumptions allow. forge runs each rung
///         only at the concrete points of {test_everyRungHoldsAtConcretePoints}, so the harness cannot rot between
///         runs and CI's coverage gate reads every line of it; Halmos runs only the `check_` functions.
/// @dev The rungs widen what is symbolic one step at a time: rung 1 leaves only the new units symbolic, rung 2 adds
///      the auction's clock, rung 3 the weights, rung 4 the current units, the supply and the scale. What they check
///      is what the hub relies on without a price: an accepted fill clears a bar that is never zero, keeps every leg
///      inside its unit caps, grows at least one leg, and never has a leg both send and receive. That it never lowers
///      the weighted product of the units is a fact about the logarithm, proven in the record
///      (`design/2026-11-10-oracle-free-rebalance.md`, section 3), which no solver of integers states.
contract WeightedMathProofs is Test {
    uint256 constant WAD = 1e18;
    uint256 constant TOTAL_WEIGHT = 10_000;
    uint256 constant AUCTION_DURATION = 4 hours;
    /// @dev 0.025 ETH and 0.0005 BTC a token, as the unit suites' default index holds them.
    uint256 constant ETH_UNITS = 0.025e18;
    uint256 constant BTC_UNITS = 0.0005e8;

    WeightedMath math;

    function setUp() public {
        math = new WeightedMath();
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory v) {
        v = new uint256[](2);
        v[0] = a;
        v[1] = b;
    }

    /// @dev The properties every rung checks on a settlement that returns.
    function _check(
        uint256 elapsed,
        uint256 supply,
        uint256 scale,
        uint256[] memory units,
        uint256[] memory next,
        uint256[] memory weights
    ) internal view {
        try math.settlement(elapsed, supply, scale, units, next, weights, 0) returns (
            uint256 bar, int256 gain, uint256[] memory amountsOut, uint256[] memory amountsIn
        ) {
            assert(bar != 0);
            assert(gain >= int256(bar));
            assert(next[0] > units[0] || next[1] > units[1]);
            for (uint256 i = 0; i < 2; ++i) {
                assert(amountsOut[i] == 0 || amountsIn[i] == 0);
                assert(next[i] <= type(uint96).max);
                assert(next[i] * 5 >= units[i] * 4);
                assert(next[i] <= 2 * units[i]);
            }
        } catch {}
    }

    /// @dev Rung 1: any new units up to 64 bits, from the default units, at equal weights and the auction's end.
    function check_rung1_newUnits(uint64 v0, uint64 v1) public view {
        _check(AUCTION_DURATION, 1e18, WAD, _pair(ETH_UNITS, BTC_UNITS), _pair(v0, v1), _pair(5000, 5000));
    }

    /// @dev Rung 2: rung 1 at any second of the auction.
    function check_rung2_newUnitsAndTheClock(uint64 v0, uint64 v1, uint256 elapsed) public view {
        vm.assume(elapsed <= AUCTION_DURATION);
        _check(elapsed, 1e18, WAD, _pair(ETH_UNITS, BTC_UNITS), _pair(v0, v1), _pair(5000, 5000));
    }

    /// @dev Rung 3: rung 2 with any split of the weights.
    function check_rung3_newUnitsClockAndWeights(uint64 v0, uint64 v1, uint256 elapsed, uint16 w0) public view {
        vm.assume(elapsed <= AUCTION_DURATION && w0 != 0 && w0 < TOTAL_WEIGHT);
        _check(elapsed, 1e18, WAD, _pair(ETH_UNITS, BTC_UNITS), _pair(v0, v1), _pair(w0, TOTAL_WEIGHT - w0));
    }

    /// @dev Rung 4: rung 3 from any current units up to 96 bits, at any supply up to 128 bits and any scale up to one.
    function check_rung4_everything(
        uint96 u0,
        uint96 u1,
        uint256 v0,
        uint256 v1,
        uint256 elapsed,
        uint16 w0,
        uint128 supply,
        uint64 scale
    ) public view {
        vm.assume(u0 != 0 && u1 != 0 && elapsed <= AUCTION_DURATION && w0 != 0 && w0 < TOTAL_WEIGHT);
        vm.assume(scale != 0 && scale <= WAD);
        _check(elapsed, supply, scale, _pair(u0, u1), _pair(v0, v1), _pair(w0, TOTAL_WEIGHT - w0));
    }

    /// @dev Every rung at concrete points, which forge runs: a tenth of the ETH out for an eighth more BTC settles;
    ///      the same units again gain nothing and are refused, so the check has nothing to assert.
    function test_everyRungHoldsAtConcretePoints() public view {
        check_rung1_newUnits(0.0225e18, 0.0005625e8);
        check_rung1_newUnits(uint64(ETH_UNITS), uint64(BTC_UNITS));
        check_rung2_newUnitsAndTheClock(0.0225e18, 0.0005625e8, 3 hours);
        check_rung3_newUnitsClockAndWeights(0.0225e18, 0.0005625e8, AUCTION_DURATION, 2500);
        check_rung4_everything(1e18, 1e7, 0.9e18, 1.2e7, AUCTION_DURATION, 5000, 1e24, 0.9e18);
    }
}
