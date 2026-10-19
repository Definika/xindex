// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IWeightedHub} from "./interfaces/IWeightedHub.sol";
import {IWeightedMath} from "./interfaces/IWeightedMath.sol";

/// @title WeightedMath
/// @notice The settlement arithmetic of `WeightedHub`, in its own contract so the hub fits the EIP-170 size limit.
///         See {IWeightedMath}. The hub's rebalance and invariant suites test it, and
///         `test_theMathConstantsAreTheHubs` pins its constants to the hub's.
/// @dev Pure: nothing here reads storage or calls anything.
///      - {_backing} is the hub's `_backing` formula. So the settlement moves each leg's change in backing exactly as
///        issue and redeem measure it.
///      - It works on the recorded units and applies the scale only to the amounts. Targets, the turnover cap and the
///        minimum trade are ratios, unchanged by a factor every leg shares. So no leg is rounded to fold the scale in
///        (XS-2).
///      - The arrays are passed in memory, one stack slot each, to stay within the compiler's stack limit.
contract WeightedMath is IWeightedMath {
    /// @inheritdoc IWeightedMath
    uint256 public constant MU_MAX = 1.02e18;
    /// @inheritdoc IWeightedMath
    uint256 public constant MAX_TURNOVER = 0.2e18;
    /// @inheritdoc IWeightedMath
    uint256 public constant MIN_TRADE = 0.001e18;
    /// @inheritdoc IWeightedMath
    uint256 public constant MAX_GROWTH = 1e18;

    uint256 private constant WAD = 1e18;
    uint256 private constant SHARE_UNIT = 1e18;

    /// @inheritdoc IWeightedMath
    function settlement(
        uint256 mu,
        uint256[] memory prices,
        uint256 supply,
        uint256 scale,
        uint256[] memory currentUnits,
        uint256[] memory weights,
        uint256 keepMask
    ) external pure returns (uint256, uint256[] memory, uint256[] memory, uint256[] memory) {
        (uint256[] memory targets, uint256 share) = _targets(keepMask, prices, currentUnits, weights);
        return _fill(mu, supply, scale, currentUnits, targets, share);
    }

    /// @dev Moves every leg `share` of the way to `targets` at `mu`, and computes the amounts at `supply` and `scale`.
    ///      If nothing would go out, it redoes this at MU_MAX: nobody is paid for an empty or dust index.
    function _fill(
        uint256 mu,
        uint256 supply,
        uint256 scale,
        uint256[] memory currentUnits,
        uint256[] memory targets,
        uint256 share
    ) private pure returns (uint256, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn) {
        units = _stepUnits(currentUnits, targets, share, _growthFactor(mu, share));
        (amountsOut, amountsIn) = _legAmounts(supply, scale, currentUnits, units);
        if (mu != MU_MAX && !_anyNonZero(amountsOut)) {
            mu = MU_MAX;
            units = _stepUnits(currentUnits, targets, share, _growthFactor(mu, share));
            (amountsOut, amountsIn) = _legAmounts(supply, scale, currentUnits, units);
        }
        return (mu, units, amountsOut, amountsIn);
    }

    /// @dev The factor every growing leg's step is scaled by: `mu · share`, rounded up.
    function _growthFactor(uint256 mu, uint256 share) private pure returns (uint256) {
        return Math.mulDiv(mu, share, WAD, Math.Rounding.Ceil);
    }

    /// @dev Whether any leg sends something out.
    function _anyNonZero(uint256[] memory amounts) private pure returns (bool) {
        for (uint256 i = 0; i < amounts.length; ++i) {
            if (amounts[i] != 0) return true;
        }
        return false;
    }

    /// @dev Every leg's new units, `share` of the way toward its target. All rounding favours the holders:
    ///      - targets round up, so a shrinking leg keeps more and a growing leg asks more;
    ///      - `share` rounds down, and a shrinking leg's step rounds down;
    ///      - a growing leg's step rounds up, scaled by `growth` (`mu · share`, rounded up).
    ///      A leg on its target stays. A kept leg's target is its current units.
    function _stepUnits(uint256[] memory currentUnits, uint256[] memory targets, uint256 share, uint256 growth)
        private
        pure
        returns (uint256[] memory units)
    {
        uint256 n = currentUnits.length;
        units = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 current = currentUnits[i];
            uint256 target = targets[i];
            if (target < current) {
                units[i] = current - Math.mulDiv(current - target, share, WAD);
            } else if (target > current) {
                units[i] = current + Math.mulDiv(target - current, growth, WAD, Math.Rounding.Ceil);
                // The hub records units in 96 bits. Reverting here, as the hub's write would, keeps previewRebalance
                // from returning a settlement that executeRebalance cannot apply (RX-61).
                if (units[i] > type(uint96).max) revert SafeCast.SafeCastOverflowedUintDowncast(96, units[i]);
            } else {
                units[i] = current;
            }
        }
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

    /// @dev Returns each component's target units and the `share` of the way every leg moves toward them.
    ///      - A moving component's target is w · V / (W · p), rounded up. A kept one's is its current units.
    ///      - `share` is 1e18 (all the way), or less so that no shrinking leg gives up more than MAX_TURNOVER of its
    ///        own units, and no growing leg's gap times `share` exceeds MAX_GROWTH of its own units, rounded down.
    ///        The cap counts units, not value, so a wrong price cannot widen it (V5-M2, RX-15).
    ///      - Reverts NothingToRebalance if the shrinking legs' release, after the cap, is worth less than MIN_TRADE
    ///        of V. Do not check before the cap: a fill could then trade a fifth of the minimum and still restart
    ///        the interval (V5R-1).
    ///      Values are units times prices, each below 2^96 · MAX_PRICE, so a hundred of them fit in 256 bits.
    function _targets(
        uint256 keepMask,
        uint256[] memory prices,
        uint256[] memory currentUnits,
        uint256[] memory weights
    ) private pure returns (uint256[] memory targets, uint256 share) {
        uint256 n = currentUnits.length;
        uint256 value = 0;
        uint256 weight = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) != 0) continue;
            value += currentUnits[i] * prices[i];
            weight += weights[i];
        }
        targets = new uint256[](n);
        share = WAD;
        uint256 released = 0;
        for (uint256 i = 0; i < n; ++i) {
            uint256 current = currentUnits[i];
            if ((keepMask & (1 << i)) != 0) {
                targets[i] = current;
                continue;
            }
            uint256 target = Math.mulDiv(value, weights[i], weight * prices[i], Math.Rounding.Ceil);
            targets[i] = target;
            if (target > current) {
                // A growing leg adds at most mu * MAX_GROWTH of its own units. So a coin whose issuer mints and dumps
                // it draws at most about its own value from the other legs per fill, whatever its price (RX-15).
                uint256 growLimit = Math.mulDiv(current, MAX_GROWTH, target - current);
                if (growLimit < share) share = growLimit;
                continue;
            }
            if (target == current) continue;
            released += (current - target) * prices[i];
            uint256 limit = Math.mulDiv(current, MAX_TURNOVER, current - target);
            if (limit < share) share = limit;
        }
        // The fill trades the release scaled by `share`, so the minimum is checked on that (V5R-1).
        if (Math.mulDiv(released, share, WAD) < Math.mulDiv(value, MIN_TRADE, WAD, Math.Rounding.Ceil)) {
            revert IWeightedHub.NothingToRebalance();
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
