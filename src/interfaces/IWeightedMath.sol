// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IWeightedMath
/// @notice The settlement arithmetic of a weighted index, pure over the arrays the hub hands it. `WeightedHub` calls
///         it by STATICCALL through an immutable the factory set when it deployed both, so it is as fixed as the hub's
///         own code; it holds nothing and reads nothing.
interface IWeightedMath {
    /// @notice The settlement at `mu`, or at MU_MAX when it would send nothing out, as on an empty index or one so
    ///         small that every shrinking leg rounds to zero: nobody is paid for an empty or dust index (R14, XA-27).
    ///         Reverts `IWeightedHub.NothingToRebalance` when the index is on its weights.
    /// @param mu The multiplier on the growing legs the auction is at (1e18 = parity).
    /// @param prices Each moving component's price, in USD per raw unit scaled by 1e36; a kept one's is ignored.
    /// @param supply The share supply the amounts are for.
    /// @param scale The factor every component's recorded units carry (1e18 = one): the amounts are each leg's change
    ///        in `supply · units · scale / 1e36`.
    /// @param currentUnits Each component's recorded units per 1e18 shares, which carry `scale`.
    /// @param weights Each component's weight in basis points.
    /// @param keepMask Bit i set leaves component i untouched.
    /// @return muUsed The multiplier the settlement used.
    /// @return units New recorded units per component, carrying `scale` as `currentUnits` do; a kept leg's are its
    ///         current units exactly.
    /// @return amountsOut What the index sends out per component.
    /// @return amountsIn What the index needs back per component.
    function settlement(
        uint256 mu,
        uint256[] memory prices,
        uint256 supply,
        uint256 scale,
        uint256[] memory currentUnits,
        uint256[] memory weights,
        uint256 keepMask
    )
        external
        pure
        returns (uint256 muUsed, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn);

    /// @notice Where the multiplier starts; the hub's MU_MAX.
    function MU_MAX() external view returns (uint256);

    /// @notice Most of any component's own units one settlement sends out; the hub's MAX_TURNOVER.
    function MAX_TURNOVER() external view returns (uint256);

    /// @notice Least a fill must trade, as a share of the moving value; the hub's MIN_TRADE.
    function MIN_TRADE() external view returns (uint256);
}
