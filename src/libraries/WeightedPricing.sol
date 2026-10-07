// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PythStructs} from "../interfaces/pyth/PythStructs.sol";

/// @title WeightedPricing
/// @notice v5's rebalance math, as `WeightedHub` applies it, for the hybrid index: a Pyth price scaled to USD per raw
///         unit, the targets of a weighted basket, the unit cap and the settlement at a multiplier. Pure functions over
///         memory, so the caller keeps its own storage and errors.
/// @dev DRAFT, untested in this form (2026-10-06): the hybrid index's port of `WeightedHub`'s tested math. Its
///      entry points are external or public, so the library is deployed once and linked, which keeps the hybrid module
///      under the size limit. Decimals may
///      reach MAX_DECIMALS (24, NEAR's yoctoNEAR), so a price is refused when 36 + expo - decimals would be negative: a
///      24-decimal coin needs an exponent of at least -12. Pyth's crypto feeds use -8; should one fall lower, every fill
///      of an index holding that coin reverts until the guardian keeps it, as with a collapsing coin (V5-L3, V5R-I1).
library WeightedPricing {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant PRICE_DECIMALS = 36;
    uint256 internal constant MAX_DECIMALS = 24;
    uint256 internal constant MAX_PRICE = 1e45;
    int256 internal constant MIN_EXPO = -18;
    uint256 internal constant MAX_CONFIDENCE = 0.02e18;
    uint256 internal constant MAX_TURNOVER = 0.2e18;
    uint256 internal constant MIN_TRADE = 0.001e18;
    uint256 internal constant MU_MAX = 1.02e18;
    uint256 internal constant MU_MIN = 0.98e18;

    /// @notice `token`'s price is not positive, has an exponent outside [MIN_EXPO, 0] or too small for its decimals,
    ///         or comes to more than MAX_PRICE.
    error PriceOutOfRange(address token, int64 price, int32 expo);
    /// @notice `token`'s confidence interval is wider than MAX_CONFIDENCE of its price.
    error PriceUncertain(address token, int64 price, uint64 conf);
    /// @notice What the shrinking legs would release is worth less than MIN_TRADE of the moving value.
    error NothingToRebalance();

    /// @notice `p` as USD per raw unit scaled by 1e36, refused as `WeightedHub` refuses it.
    function price(PythStructs.Price memory p, uint256 decimals, address token) external pure returns (uint256) {
        int256 expo = p.expo;
        // Both constants and `decimals` are small (a vault coin's are at most MAX_DECIMALS), so the casts keep them.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (p.price <= 0 || expo > 0 || expo < MIN_EXPO || int256(PRICE_DECIMALS) + expo < int256(decimals)) {
            revert PriceOutOfRange(token, p.price, p.expo);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 value = uint256(int256(p.price));
        if (uint256(p.conf) * WAD > value * MAX_CONFIDENCE) revert PriceUncertain(token, p.price, p.conf);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 exponent = uint256(int256(PRICE_DECIMALS) + expo) - decimals;
        value = value * 10 ** exponent;
        if (value > MAX_PRICE) revert PriceOutOfRange(token, p.price, p.expo);
        return value;
    }

    /// @notice μ at `elapsed` seconds into an auction of `duration`, falling from MU_MAX to MU_MIN, rounded up.
    function mu(uint256 elapsed, uint256 duration) internal pure returns (uint256) {
        return MU_MAX - Math.mulDiv(MU_MAX - MU_MIN, elapsed, duration);
    }

    /// @notice Each moving component's target units, w · V / (W · p) rounded up, and the share of the way every leg
    ///         moves, so no shrinking leg gives up more than MAX_TURNOVER of its units. Reverts NothingToRebalance when
    ///         the release, after the cap, is worth less than MIN_TRADE of the moving value (V5R-1).
    function targets(uint256[] memory units, uint256[] memory prices, uint256[] memory weights, uint256 keepMask)
        public
        pure
        returns (uint256[] memory target, uint256 share)
    {
        (uint256 value, uint256 weight) = _totals(units, prices, weights, keepMask);
        target = new uint256[](units.length);
        share = WAD;
        uint256 released = 0;
        for (uint256 i = 0; i < units.length; ++i) {
            if ((keepMask & (1 << i)) != 0) continue;
            target[i] = Math.mulDiv(value, weights[i], weight * prices[i], Math.Rounding.Ceil);
            if (target[i] >= units[i]) continue;
            released += (units[i] - target[i]) * prices[i];
            share = Math.min(share, Math.mulDiv(units[i], MAX_TURNOVER, units[i] - target[i]));
        }
        // What the fill trades is the release scaled by the cap, so the minimum is checked on that (V5R-1).
        if (Math.mulDiv(released, share, WAD) < Math.mulDiv(value, MIN_TRADE, WAD, Math.Rounding.Ceil)) {
            revert NothingToRebalance();
        }
    }

    /// @dev The moving components' value, Σ u·p, and weight.
    function _totals(uint256[] memory units, uint256[] memory prices, uint256[] memory weights, uint256 keepMask)
        private
        pure
        returns (uint256 value, uint256 weight)
    {
        value = 0;
        weight = 0;
        for (uint256 i = 0; i < units.length; ++i) {
            if ((keepMask & (1 << i)) != 0) continue;
            value += units[i] * prices[i];
            weight += weights[i];
        }
    }

    /// @notice What a settlement needs once prices are read.
    struct Basket {
        uint256[] current;
        uint256[] prices;
        uint256[] weights;
        uint256 keepMask;
        uint256 elapsed;
        uint256 duration;
        uint256 supply;
    }

    /// @notice The whole settlement after prices: targets, the unit cap, μ at `elapsed` into an auction of `duration`
    ///         (or MU_MAX when nothing would leave, so nobody is paid for an empty or dust index), the new units, and
    ///         each leg's change in required backing at `supply` shares, rounded down when it leaves and up when it
    ///         must come back (SA-07).
    function settle(Basket memory b)
        external
        pure
        returns (uint256 m, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        (uint256[] memory target, uint256 share) = targets(b.current, b.prices, b.weights, b.keepMask);
        m = mu(b.elapsed, b.duration);
        bool sells;
        (units, amountsOut, amountsIn, sells) =
            _amounts(b.current, newUnits(b.current, target, share, m, b.keepMask), b.supply);
        if (!sells && m != MU_MAX) {
            m = MU_MAX;
            (units, amountsOut, amountsIn,) =
                _amounts(b.current, newUnits(b.current, target, share, m, b.keepMask), b.supply);
        }
    }

    function _amounts(uint256[] memory current, uint256[] memory next, uint256 supply)
        private
        pure
        returns (uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn, bool sells)
    {
        units = next;
        sells = false;
        uint256 n = next.length;
        amountsOut = new uint256[](n);
        amountsIn = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            if (next[i] < current[i]) {
                amountsOut[i] = Math.mulDiv(supply, current[i] - next[i], WAD);
                if (amountsOut[i] != 0) sells = true;
            } else if (next[i] > current[i]) {
                amountsIn[i] = Math.mulDiv(supply, next[i] - current[i], WAD, Math.Rounding.Ceil);
            }
        }
    }

    /// @notice New units at multiplier `m`: shrinking legs move ⌊share · (u − t)⌋, growing legs ⌈⌈m · share⌉ · (t − u)⌉;
    ///         kept and unmoved legs keep their units.
    function newUnits(uint256[] memory units, uint256[] memory target, uint256 share, uint256 m, uint256 keepMask)
        public
        pure
        returns (uint256[] memory next)
    {
        uint256 n = units.length;
        next = new uint256[](n);
        uint256 growth = Math.mulDiv(m, share, WAD, Math.Rounding.Ceil);
        for (uint256 i = 0; i < n; ++i) {
            uint256 current = units[i];
            uint256 t = target[i];
            if ((keepMask & (1 << i)) != 0 || t == current) {
                next[i] = current;
            } else if (t < current) {
                next[i] = current - Math.mulDiv(current - t, share, WAD);
            } else {
                next[i] = current + Math.mulDiv(t - current, growth, WAD, Math.Rounding.Ceil);
            }
        }
    }
}
