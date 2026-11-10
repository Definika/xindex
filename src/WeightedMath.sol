// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IWeightedHub} from "./interfaces/IWeightedHub.sol";
import {IWeightedMath} from "./interfaces/IWeightedMath.sol";
import {IXindexErrors} from "./interfaces/IXindexErrors.sol";

/// @title WeightedMath
/// @notice The settlement arithmetic of `WeightedHub`, in its own contract so the hub fits the EIP-170 size limit.
///         See {IWeightedMath}. The settlement vectors replay it against an exact model
///         (`test/WeightedMath.vectors.t.sol`), and `test_theMathConstantsAreTheHubs` pins its constants to the hub's.
/// @dev Pure: nothing here reads storage or calls anything, and nothing here is a price.
///      - The executor names the new units. This contract only checks them: each leg inside its unit caps, and the
///        weighted gain at or above the auction's bar.
///      - {_backing} is the hub's `_backing` formula. So the settlement moves each leg's change in backing exactly as
///        issue and redeem measure it.
///      - It works on the recorded units and applies the scale only to the amounts. The caps and the gain are ratios of
///        units, unchanged by a factor every leg shares. So no leg is rounded to fold the scale in (XS-2).
///      - Every rounding goes against the executor: a leg's change and its score round down, the bar and the lower cap
///        round up, an amount rounds down when it leaves and up when it comes back.
///      - The arrays are passed in memory, one stack slot each, to stay within the compiler's stack limit.
contract WeightedMath is IWeightedMath {
    /// @inheritdoc IWeightedMath
    uint256 public constant MAX_TURNOVER = 0.2e18;
    /// @inheritdoc IWeightedMath
    uint256 public constant MAX_GROWTH = 1e18;
    /// @inheritdoc IWeightedMath
    uint256 public constant BAR_MAX = 0.5e18;
    /// @inheritdoc IWeightedMath
    uint256 public constant BAR_HALF_LIFE = 12 minutes;
    /// @inheritdoc IWeightedMath
    uint256 public constant AUCTION_DURATION = 4 hours;

    uint256 private constant WAD = 1e18;
    uint256 private constant SHARE_UNIT = 1e18;
    int256 private constant TOTAL_WEIGHT = 1e4;
    int256 private constant ONE = 1e18;
    /// @dev The common denominator of L's four terms at 1e18: 30 · 1e18³.
    int256 private constant SCORE_DENOMINATOR = 30e54;

    /// @inheritdoc IWeightedMath
    function settlement(
        uint256 elapsed,
        uint256 supply,
        uint256 scale,
        uint256[] memory currentUnits,
        uint256[] memory newUnits,
        uint256[] memory weights,
        uint256 keepMask
    ) external pure returns (uint256 bar, int256 gain, uint256[] memory amountsOut, uint256[] memory amountsIn) {
        bar = barAt(elapsed);
        if (newUnits.length != currentUnits.length) revert IXindexErrors.LengthMismatch();
        // An empty index has nothing to trade. Its units stay, so nobody moves them for nothing.
        if (supply == 0) revert IWeightedHub.NothingToRebalance();
        gain = _gain(currentUnits, newUnits, weights, keepMask);
        // The bar is at most BAR_MAX, far inside int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (gain < int256(bar)) revert IWeightedHub.GainBelowBar(gain, bar);
        (amountsOut, amountsIn) = _legAmounts(supply, scale, currentUnits, newUnits);
    }

    /// @inheritdoc IWeightedMath
    /// @dev Exact: the two sums are integers, and the floor is the value out less the tolerance, rounded up, so the
    ///      rounding goes against the executor.
    function quoteCheck(
        uint256[] memory currentUnits,
        uint256[] memory newUnits,
        uint256[] memory prices,
        uint256 tolerance
    ) external pure {
        uint256 valueOut = 0;
        uint256 valueIn = 0;
        uint256 n = currentUnits.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 current = currentUnits[i];
            uint256 next = newUnits[i];
            if (next < current) valueOut += prices[i] * (current - next);
            else if (next > current) valueIn += prices[i] * (next - current);
        }
        uint256 floor = Math.mulDiv(valueOut, WAD - tolerance, WAD, Math.Rounding.Ceil);
        if (valueIn < floor) revert IWeightedHub.BelowQuote(valueIn, floor);
    }

    /// @inheritdoc IWeightedMath
    function barAt(uint256 elapsed) public pure returns (uint256) {
        if (elapsed > AUCTION_DURATION) revert IWeightedHub.AuctionOver(elapsed);
        uint256 halvings = elapsed / BAR_HALF_LIFE;
        uint256 intoThisOne = elapsed % BAR_HALF_LIFE;
        // BAR_MAX / 2^halvings, less the part of the next halving already run, rounded up once.
        return
            Math.mulDiv(BAR_MAX, 2 * BAR_HALF_LIFE - intoThisOne, (2 * BAR_HALF_LIFE) << halvings, Math.Rounding.Ceil);
    }

    /// @dev The fill's weighted gain, `⌊Σ w_i · L(x_i) / TOTAL_WEIGHT⌋`, after checking every leg's caps.
    ///      - A kept leg must keep its units exactly. Any other leaves with at least `1 − MAX_TURNOVER` of them,
    ///        rounded up, and at most `1 + MAX_GROWTH` of them. The caps count units, not value, so nothing a market
    ///        does can widen them (V5-M2, RX-15). They also keep every `x` inside the range where L is below ln.
    ///      - The hub records units in 96 bits. Reverting here, as the hub's write would, keeps a preview from
    ///        accepting a fill the hub cannot apply (RX-61).
    function _gain(uint256[] memory currentUnits, uint256[] memory newUnits, uint256[] memory weights, uint256 keepMask)
        private
        pure
        returns (int256)
    {
        uint256 n = currentUnits.length;
        int256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            uint256 current = currentUnits[i];
            uint256 next = newUnits[i];
            uint256 lowest = current;
            uint256 highest = current;
            if ((keepMask & (1 << i)) == 0) {
                lowest = Math.mulDiv(current, WAD - MAX_TURNOVER, WAD, Math.Rounding.Ceil);
                highest = current + Math.mulDiv(current, MAX_GROWTH, WAD);
            }
            if (next < lowest || next > highest) revert IWeightedHub.LegOutOfBounds(i, next, lowest, highest);
            if (next > type(uint96).max) revert SafeCast.SafeCastOverflowedUintDowncast(96, next);
            // A weight is at most 1e4 and a score below 1e18 in size, so a hundred products fit with room to spare.
            // forge-lint: disable-next-line(unsafe-typecast)
            total += int256(weights[i]) * _score(_change(current, next));
        }
        return _floorDiv(total, TOTAL_WEIGHT);
    }

    /// @dev A leg's relative change in units at 1e18, `(next − current) / current`, rounded down, so a loss counts in
    ///      full and a gain never counts for more than it is. Units fit 96 bits, so the products fit, and the result
    ///      is between −MAX_TURNOVER and MAX_GROWTH once the caps hold.
    function _change(uint256 current, uint256 next) private pure returns (int256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (next >= current) return int256(((next - current) * WAD) / current);
        // forge-lint: disable-next-line(unsafe-typecast)
        return -int256(Math.ceilDiv((current - next) * WAD, current));
    }

    /// @dev `L(x) = x − x²/2 + x³/3 − 3x⁴/10` at 1e18, rounded down. It is at most `ln(1 + x)` for x in [−0.2, 1]:
    ///      above zero the logarithm's series alternates, so stopping after −x⁴/4 is a lower bound, and −3x⁴/10 is
    ///      lower still; below zero every term of the series is negative, and the terms after x³/3 sum to less than
    ///      3x⁴/10 while |x| is at most 0.2. The four terms are added over their common denominator and divided
    ///      once. With |x| at most 1e18 the numerator is below 7e73, inside int256.
    function _score(int256 x) private pure returns (int256) {
        int256 square = x * x;
        int256 numerator =
            30 * x * ONE * ONE * ONE - 15 * square * ONE * ONE + 10 * square * x * ONE - 9 * square * square;
        return _floorDiv(numerator, SCORE_DENOMINATOR);
    }

    /// @dev `a / b` rounded toward minus infinity, for a positive `b`. Solidity's division rounds toward zero.
    function _floorDiv(int256 a, int256 b) private pure returns (int256 quotient) {
        quotient = a / b;
        if (a % b < 0) --quotient;
    }

    /// @dev What each leg sends out or asks back at `supply` and `scale`, moving from `currentUnits` to `units`. It is
    ///      the leg's change in backing, rounded down when it leaves and up when it comes back (SA-07).
    function _legAmounts(uint256 supply, uint256 scale, uint256[] memory currentUnits, uint256[] memory units)
        private
        pure
        returns (uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        uint256 n = units.length;
        amountsOut = new uint256[](n);
        amountsIn = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 current = currentUnits[i];
            uint256 next = units[i];
            if (next < current) amountsOut[i] = _backing(supply, current - next, scale, Math.Rounding.Floor);
            else if (next > current) amountsIn[i] = _backing(supply, next - current, scale, Math.Rounding.Ceil);
        }
    }

    /// @dev The amount of a component that backs `shares`, at `units` per 1e18 shares and `scale`:
    ///      `shares · units · scale / 1e36`, the same formula as the hub's `_backing`. Units fit 96 bits and the
    ///      scale 128, so their product fits.
    function _backing(uint256 shares, uint256 units, uint256 scale, Math.Rounding rounding)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(shares, units * scale, SHARE_UNIT * WAD, rounding);
    }
}
