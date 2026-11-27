// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISyntheticSharesOracle
/// @notice The one read `PythPrices` makes of Ondo's `SyntheticSharesOracle`, declared here rather than copied: the
///         public getter of its `assetData` mapping, whose answer is Ondo's `Asset` struct in its own field order, read
///         from the verified source at Ethereum's `0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6` and BNB Chain's
///         `0xF4Fd8a1B412633e10527454137A29Db7Aa35F15e` (the same source, neither a proxy).
/// @dev What Ondo's source says of each field, and what `PythPrices` takes from it:
///      - `sValue`: the shares of the stock one token stands for, 1e18 = one; zero for a token the oracle does not
///        hold. A dividend raises it by at most `allowedDriftBps` once every `driftCooldown` (`submitUpdate`); a split
///        or any larger change is scheduled as a corporate action instead.
///      - `pendingSValue` and `pauseStartTime`: a scheduled corporate action's new sValue and the second its pause
///        begins, both zero when none is scheduled. The new sValue lands only when an admin of Ondo's calls `unpause`,
///        at least the oracle's minimum pause after the start, which writes it and clears both.
///      - `lastUpdate`: the second the sValue last changed, or the asset was added.
///      The getter never reverts: an address the oracle does not hold reads as all zeros.
interface ISyntheticSharesOracle {
    /// @notice `asset`'s entry: its sValue, a scheduled corporate action's sValue and start, its last change, and the
    ///         bounds of a routine update.
    function assetData(address asset)
        external
        view
        returns (
            uint128 sValue,
            uint128 pendingSValue,
            uint256 lastUpdate,
            uint256 pauseStartTime,
            uint16 allowedDriftBps,
            uint48 driftCooldown
        );
}
