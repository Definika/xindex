// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IWeightedMath
/// @notice The settlement arithmetic of a weighted index: pure functions over the arrays the hub passes in.
///         `WeightedHub` calls it by STATICCALL, at an address the factory fixed when it deployed both. So it is as
///         fixed as the hub's own code. It holds nothing and reads nothing. No price enters the gain. Prices enter
///         two checks, and each can only refuse a fill the gain accepted: {quoteCheck}, at the prices the owner or
///         guardian posted with a start, and {oracleCheck}, at Pyth's, which the hub passes in when its factory has
///         an oracle.
/// @dev The rule. The executor names each component's new units. With `x_i = (new_i − current_i) / current_i`,
///      rounded down, and `L(x) = x − x²/2 + x³/3 − 3x⁴/10`, rounded down, a fill is accepted when every leg stays
///      inside its unit caps and
///
///          gain = ⌊ Σ w_i · L(x_i) / TOTAL_WEIGHT ⌋ ≥ bar
///
///      `L(x) ≤ ln(1 + x)` on the capped range [−MAX_TURNOVER, MAX_GROWTH]. So an accepted fill raises
///      `Σ w_i · ln(units_i)` by at least `bar`: it never lowers the weighted product of the units. At any prices
///      whatever, the index is then worth at least `e^(bar − D)` times what it was, where `D` measures how far its value
///      shares were from the weights at those prices, and is zero on the weights. Nobody has to say what the prices
///      are.
interface IWeightedMath {
    /// @notice The settlement that moves `currentUnits` to `newUnits`, `elapsed` seconds into the auction.
    ///         Reverts, in this order:
    ///         - `IWeightedHub.AuctionOver` if `elapsed` is past AUCTION_DURATION;
    ///         - `LengthMismatch` if `newUnits` is not one entry per component;
    ///         - `IWeightedHub.NothingToRebalance` if `supply` is under one whole share (1e18): such an index has
    ///           nothing to trade, and its units stay as they are;
    ///         - `IWeightedHub.LegOutOfBounds` at the first component outside its caps, a kept one that moved included;
    ///         - `SafeCastOverflowedUintDowncast(96, units)` at the first component above the 96 bits the hub records;
    ///         - `IWeightedHub.GainBelowBar` if the gain is under the bar.
    /// @param elapsed Seconds since the auction opened.
    /// @param supply The share supply the amounts are for.
    /// @param scale The factor every component's recorded units carry (1e18 = one). Each amount is the leg's change
    ///        in `supply · units · scale / 1e36`.
    /// @param currentUnits Each component's recorded units per 1e18 shares, which carry `scale`.
    /// @param newUnits The units the executor names for each component. Like `currentUnits`, they carry `scale`.
    /// @param weights Each component's weight in basis points; they sum to 10,000.
    /// @param keepMask Bit i set means component i must keep its units exactly.
    /// @return bar The gain the auction asks for at `elapsed` (1e18 = 100%).
    /// @return gain The fill's weighted gain, at least `bar`.
    /// @return amountsOut What the index sends out per component, rounded down.
    /// @return amountsIn What the index needs back per component, rounded up.
    function settlement(
        uint256 elapsed,
        uint256 supply,
        uint256 scale,
        uint256[] memory currentUnits,
        uint256[] memory newUnits,
        uint256[] memory weights,
        uint256 keepMask
    ) external pure returns (uint256 bar, int256 gain, uint256[] memory amountsOut, uint256[] memory amountsIn);

    /// @notice Checks a fill against a quote posted with its proposal's start: at `prices`, one per component per raw
    ///         unit, the units the fill adds must be worth at least the units it takes, less `tolerance` (1e18 =
    ///         100%), rounded up. Reverts `IWeightedHub.BelowQuote` otherwise. A component whose units do not change
    ///         counts for nothing, whatever its price.
    /// @dev The caller keeps every price under 2^128 and every unit within uint96, so the sums cannot overflow, and
    ///      passes one entry per component in each array, as the hub does: the lengths are the caller's to match.
    ///      {settlement} checks `newUnits` against `currentUnits` and reads `weights` by position, without checking
    ///      its length.
    function quoteCheck(
        uint256[] memory currentUnits,
        uint256[] memory newUnits,
        uint256[] memory prices,
        uint256 tolerance
    ) external pure;

    /// @notice Checks a fill against Pyth's prices, `elapsed` seconds into its auction: at `values`, one per component
    ///         per raw unit, leaning against the executor (`IPythPrices.legValues`), the units the fill adds must be
    ///         worth at least the units it takes, less {oracleToleranceAt}, rounded up. Reverts
    ///         `IWeightedHub.BelowOracleValue` otherwise, and `IWeightedHub.AuctionOver` past AUCTION_DURATION. A
    ///         component whose units do not change counts for nothing.
    /// @dev The bounds of {quoteCheck} hold: `IPythPrices` keeps every value under 2^128.
    function oracleCheck(
        uint256[] memory currentUnits,
        uint256[] memory newUnits,
        uint256[] memory values,
        uint256 elapsed
    ) external pure;

    /// @notice How much less than it takes a fill may bring in at Pyth's prices, `elapsed` seconds into the auction
    ///         (1e18 = 100%): nothing at its first second, rising along a straight line to MAX_ORACLE_TOLERANCE at its
    ///         last, rounded down. Executors compete by filling earlier, at a smaller tolerance, so a lone executor
    ///         at the last second keeps at most MAX_ORACLE_TOLERANCE of what it trades. Reverts
    ///         `IWeightedHub.AuctionOver` past AUCTION_DURATION.
    function oracleToleranceAt(uint256 elapsed) external pure returns (uint256);

    /// @notice The most a fill may fall short of what it takes, at Pyth's prices, at the auction's last second
    ///         (1e18 = 100%).
    function MAX_ORACLE_TOLERANCE() external view returns (uint256);

    /// @notice The gain the auction asks for `elapsed` seconds after it opened: BAR_MAX at first, halving every
    ///         BAR_HALF_LIFE along a straight line within each, rounded up. Reverts `IWeightedHub.AuctionOver` past
    ///         AUCTION_DURATION.
    function barAt(uint256 elapsed) external pure returns (uint256);

    /// @notice The most of any component's own units one settlement sends out (1e18 = 100%). Equal to the hub's
    ///         MAX_TURNOVER.
    function MAX_TURNOVER() external view returns (uint256);

    /// @notice The most of a component's own units one settlement adds (1e18 = 100%). So a coin anyone can mint for
    ///         nothing takes a bounded share of the other legs per fill, whatever it is worth (RX-15).
    function MAX_GROWTH() external view returns (uint256);

    /// @notice The bar at the auction's first second (1e18 = 100%).
    function BAR_MAX() external view returns (uint256);

    /// @notice The seconds in which the bar halves.
    function BAR_HALF_LIFE() external view returns (uint256);

    /// @notice Length of the auction. Equal to the hub's AUCTION_DURATION.
    function AUCTION_DURATION() external view returns (uint256);
}
