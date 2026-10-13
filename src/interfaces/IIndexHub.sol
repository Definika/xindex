// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IIndexHub
/// @notice What every Xindex index answers, and all that `IndexZap` calls on one: an ERC-20 with permit, fully backed in
///         kind, whose shares are issued against and redeemed for the exact basket. `IWeightedHub` extends it, so the
///         compiler holds every weighted index to it. v4's market-cap `IndexHub` and the rest of its interface are
///         deleted (audit/2026-10-06-v4-retirement.md).
/// @dev Only the factory's `isIndex` proves an address is an index.
interface IIndexHub is IERC20, IERC20Permit {
    /// @notice Pulls the exact basket for `shares` from msg.sender and mints `shares` to `to`.
    ///         Amounts are rounded up per component. Caller must have approved every component. Reads no price.
    /// @param shares Shares to mint; 1e18 is one whole index token.
    /// @param to Receives the shares.
    function issue(uint256 shares, address to) external;

    /// @notice Burns `shares` from msg.sender and sends the pro-rata basket to `to`, rounded down. Reads no price.
    ///         Reverts if any component transfer reverts; `IWeightedHub.redeemSkipping` exits around a frozen one.
    /// @param shares Shares to burn.
    /// @param to Receives the components.
    function redeem(uint256 shares, address to) external;

    /// @notice Component token addresses, in the order every array of this index uses.
    function componentTokens() external view returns (address[] memory tokens);

    /// @notice Exact amounts `issue(shares)` will pull for each component (rounded up).
    function previewIssue(uint256 shares) external view returns (uint256[] memory amountsIn);

    /// @notice Exact amounts `redeem(shares)` will push for each component (rounded down).
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut);

    /// @notice Number of executed rebalances. It changes exactly when the units change, so a caller that quoted a
    ///         basket at one value knows the basket moved when it reads another.
    function rebalanceNonce() external view returns (uint256);
}
