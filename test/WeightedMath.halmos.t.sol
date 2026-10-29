// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WeightedMath} from "../src/WeightedMath.sol";

/// @notice A Halmos harness for `WeightedMath.settlement`, run by Halmos, not by forge: every argument of a `check_`
///         function is symbolic, so a passing check would hold for every value its assumptions allow. On 2026-10-29
///         Halmos 0.3.3 could not finish rung 1 in ten minutes (`design/2026-10-29-settlement-proofs.md`, section 2):
///         it explores every branch of `Math.mulDiv`, about eleven calls per settlement. The properties are proven on
///         the exact model instead (`test/vectors/proofs.py`). The harness stays for a retry with more time or a
///         later Halmos; forge compiles it and runs nothing in it.
/// @dev The rungs widen what is symbolic one step at a time: rung 1 leaves only the units symbolic, rung 2 adds the
///      multiplier, rung 3 a weight, rung 4 the prices.
contract WeightedMathProofs is Test {
    uint256 constant WAD = 1e18;
    uint256 constant TOTAL_WEIGHT = 10_000;
    uint256 constant MU_MAX = 1.02e18;
    uint256 constant MU_MIN = 0.98e18;
    uint256 constant MAX_TURNOVER = 0.2e18;
    /// @dev ETH at $2,000 with 18 decimals and BTC at $60,000 with 8, as the unit suites price them.
    uint256 constant ETH_PRICE = 2e21;
    uint256 constant BTC_PRICE = 6e32;

    WeightedMath math;

    function setUp() public {
        math = new WeightedMath();
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory v) {
        v = new uint256[](2);
        v[0] = a;
        v[1] = b;
    }

    /// @dev The properties every rung checks on a settlement that returns: a leg never both sends and receives, a
    ///      shrinking leg gives up at most MAX_TURNOVER of its own units, every leg stays within 96 bits, and the
    ///      multiplier used is the auction's or MU_MAX.
    function _check(uint256 mu, uint256[] memory prices, uint256[] memory units, uint256[] memory weights)
        internal
        view
    {
        try math.settlement(mu, prices, 1e18, WAD, units, weights, 0) returns (
            uint256 muUsed, uint256[] memory after_, uint256[] memory amountsOut, uint256[] memory amountsIn
        ) {
            assert(muUsed == mu || muUsed == MU_MAX);
            for (uint256 i = 0; i < 2; ++i) {
                assert(amountsOut[i] == 0 || amountsIn[i] == 0);
                assert(after_[i] <= type(uint96).max);
                if (after_[i] < units[i]) assert(units[i] - after_[i] <= Math.mulDiv(units[i], MAX_TURNOVER, WAD));
            }
        } catch {}
    }

    /// @dev Rung 1: any units up to 64 bits, at the fixed prices, equal weights and parity.
    function check_rung1_units(uint64 u0, uint64 u1) public view {
        vm.assume(u0 != 0 && u1 != 0);
        _check(WAD, _pair(ETH_PRICE, BTC_PRICE), _pair(u0, u1), _pair(5000, 5000));
    }

    /// @dev Rung 2: rung 1 with the multiplier anywhere in the auction's range.
    function check_rung2_unitsAndMu(uint64 u0, uint64 u1, uint256 mu) public view {
        vm.assume(u0 != 0 && u1 != 0 && mu >= MU_MIN && mu <= MU_MAX);
        _check(mu, _pair(ETH_PRICE, BTC_PRICE), _pair(u0, u1), _pair(5000, 5000));
    }

    /// @dev Rung 3: rung 2 with any split of the weights.
    function check_rung3_unitsMuAndWeights(uint64 u0, uint64 u1, uint256 mu, uint16 w0) public view {
        vm.assume(u0 != 0 && u1 != 0 && mu >= MU_MIN && mu <= MU_MAX && w0 != 0 && w0 < TOTAL_WEIGHT);
        _check(mu, _pair(ETH_PRICE, BTC_PRICE), _pair(u0, u1), _pair(w0, TOTAL_WEIGHT - w0));
    }

    /// @dev Rung 4: rung 3 with any prices up to 128 bits and units up to 96.
    function check_rung4_everything(uint96 u0, uint96 u1, uint128 p0, uint128 p1, uint256 mu, uint16 w0) public view {
        vm.assume(u0 != 0 && u1 != 0 && p0 != 0 && p1 != 0);
        vm.assume(mu >= MU_MIN && mu <= MU_MAX && w0 != 0 && w0 < TOTAL_WEIGHT);
        _check(mu, _pair(p0, p1), _pair(u0, u1), _pair(w0, TOTAL_WEIGHT - w0));
    }
}
