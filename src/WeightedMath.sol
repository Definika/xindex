// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWeightedHub} from "./interfaces/IWeightedHub.sol";
import {IWeightedMath} from "./interfaces/IWeightedMath.sol";

/// @title WeightedMath
/// @notice The settlement arithmetic of `WeightedHub`, in a contract of its own so that the hub fits EIP-170. See
///         {IWeightedMath}. It was the hub's own private functions until 2026-10-14 and is tested through the hub's
///         rebalance and invariant suites; `test_theMathConstantsAreTheHubs` pins its constants to the hub's.
/// @dev Pure: nothing here reads storage or calls anything. The hub's `_backing` at a scale of one is the formula
///      {_amount} applies, so the settlement moves each leg's change in required backing exactly as issue and redeem
///      measure it. The arrays come in memory, one stack slot each, which keeps the compiler's stack in reach.
contract WeightedMath is IWeightedMath {
    /// @inheritdoc IWeightedMath
    uint256 public constant MU_MAX = 1.02e18;
    /// @inheritdoc IWeightedMath
    uint256 public constant MAX_TURNOVER = 0.2e18;
    /// @inheritdoc IWeightedMath
    uint256 public constant MIN_TRADE = 0.001e18;

    uint256 private constant WAD = 1e18;
    uint256 private constant SHARE_UNIT = 1e18;

    /// @inheritdoc IWeightedMath
    function settlement(
        uint256 mu,
        uint256[] memory prices,
        uint256 supply,
        uint256[] memory currentUnits,
        uint256[] memory weights,
        uint256 keepMask
    ) external pure returns (uint256, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn) {
        (uint256[] memory targets, uint256 share) = _targets(keepMask, prices, currentUnits, weights);
        uint256 growth = _growth(mu, share);
        units = _move(currentUnits, targets, share, growth);
        (amountsOut, amountsIn) = _amounts(supply, currentUnits, units);
        if (mu != MU_MAX && !_any(amountsOut)) {
            mu = MU_MAX;
            growth = _growth(mu, share);
            units = _move(currentUnits, targets, share, growth);
            (amountsOut, amountsIn) = _amounts(supply, currentUnits, units);
        }
        return (mu, units, amountsOut, amountsIn);
    }

    /// @dev The factor every growing leg's step is scaled by: `mu · share`, rounded up.
    function _growth(uint256 mu, uint256 share) private pure returns (uint256) {
        return Math.mulDiv(mu, share, WAD, Math.Rounding.Ceil);
    }

    /// @dev Whether any leg sends something out.
    function _any(uint256[] memory amounts) private pure returns (bool) {
        for (uint256 i = 0; i < amounts.length; ++i) {
            if (amounts[i] != 0) return true;
        }
        return false;
    }

    /// @dev Every leg's new units, `share` of the way toward `targets`. Targets round up, so a shrinking leg keeps
    ///      more and a growing leg asks more. `share` rounds down; a shrinking leg's step rounds down and a growing
    ///      leg's rounds up, by `growth`, the factor `mu · share` rounded up. A leg on its target stays, and a kept
    ///      leg's target is its current units.
    function _move(uint256[] memory currentUnits, uint256[] memory targets, uint256 share, uint256 growth)
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
            } else {
                units[i] = current;
            }
        }
    }

    /// @dev What each leg sends out or asks back at `supply`, moving from `currentUnits` to `units`: its change in
    ///      required backing, rounded down when it leaves and up when it comes back (SA-07).
    function _amounts(uint256 supply, uint256[] memory currentUnits, uint256[] memory units)
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
            if (next < current) amountsOut[i] = _amount(supply, current - next, Math.Rounding.Floor);
            else if (next > current) amountsIn[i] = _amount(supply, next - current, Math.Rounding.Ceil);
        }
    }

    /// @dev Each moving component's target units, w · V / (W · p) rounded up, a kept one's its current units, and
    ///      the share of the way to them every leg moves: all of it, or less, so that no shrinking leg gives up more
    ///      than MAX_TURNOVER of its own units, rounded down. The cap counts units, not value, so a wrong price cannot
    ///      widen it: the prices it guards against would otherwise measure it (V5-M2). Reverts NothingToRebalance when
    ///      what the shrinking legs release, after the cap, is worth less than MIN_TRADE of V: measured before the cap,
    ///      a fill could trade a fifth of that and still restart the interval (V5R-1). Values are units times prices:
    ///      below 2^96 · MAX_PRICE each, so a hundred of them fit 256 bits.
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
            if (target >= current) continue;
            released += (current - target) * prices[i];
            uint256 limit = Math.mulDiv(current, MAX_TURNOVER, current - target);
            if (limit < share) share = limit;
        }
        // What the fill trades is the release scaled by the cap, so the minimum is checked on that (V5R-1).
        if (Math.mulDiv(released, share, WAD) < Math.mulDiv(value, MIN_TRADE, WAD, Math.Rounding.Ceil)) {
            revert IWeightedHub.NothingToRebalance();
        }
    }

    /// @dev The amount of a component `shares` are backed by at `units` per 1e18 shares: the hub's `_backing` at a
    ///      scale of one.
    function _amount(uint256 shares, uint256 units, Math.Rounding rounding) private pure returns (uint256) {
        return Math.mulDiv(shares, units, SHARE_UNIT, rounding);
    }
}
