// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

/// @notice Exposes the vendored library to the tests.
contract TickMathHarness {
    function sqrtPriceAtTick(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }
}

contract TickMathTest is Test {
    TickMathHarness harness;

    function setUp() public {
        harness = new TickMathHarness();
    }

    function test_boundsAndParity() public view {
        assertEq(harness.sqrtPriceAtTick(0), 1 << 96);
        assertEq(harness.sqrtPriceAtTick(TickMath.MIN_TICK), TickMath.MIN_SQRT_PRICE);
        assertEq(harness.sqrtPriceAtTick(TickMath.MAX_TICK), TickMath.MAX_SQRT_PRICE);
    }

    /// @dev Exact values of sqrt(1.0001^tick) * 2^96, computed with 120-digit decimal arithmetic. The library multiplies
    ///      rounded per-bit factors, so it agrees to within one part in 10^12.
    function test_matchesExactValues() public view {
        _check(1, 79232123823359799118286999567);
        _check(-1, 79224201403219477170569942573);
        _check(50, 79426470787362580746886972460);
        _check(-50, 79030349367926598376800521321);
        _check(6932, 112046559425783515914356180038);
        _check(-6932, 56022262241300288188759753412);
        _check(100_000, 11755562826496067164730007768449);
        _check(-100_000, 533968626430936354154228407);
        _check(524_287, 19189247130466284822469633862652052790146); // bits 0 to 18 set
        _check(524_288, 19190206568837448476620805521939294697349); // bit 19 alone
        _check(-524_288, 327099227039063106);
    }

    function _check(int24 tick, uint256 exact) internal view {
        assertApproxEqRel(harness.sqrtPriceAtTick(tick), exact, 1e6);
    }

    function test_revertsOutsideTheTickRange() public {
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidTick.selector, TickMath.MAX_TICK + 1));
        harness.sqrtPriceAtTick(TickMath.MAX_TICK + 1);
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidTick.selector, TickMath.MIN_TICK - 1));
        harness.sqrtPriceAtTick(TickMath.MIN_TICK - 1);
    }

    function testFuzz_strictlyIncreasing(int24 a, int24 b) public view {
        a = int24(bound(a, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        b = int24(bound(b, int256(a) + 1, TickMath.MAX_TICK));
        assertLt(harness.sqrtPriceAtTick(a), harness.sqrtPriceAtTick(b));
    }
}
