// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IIndexHub
/// @notice What every Xindex index answers, and all that `IndexZap` calls on one. An index is an ERC-20 with permit,
///         fully backed in kind: shares are issued against, and redeemed for, the exact basket. `IWeightedHub`
///         extends it.
/// @dev Only the factory's `isIndex` proves an address is an index.
interface IIndexHub is IERC20, IERC20Permit {
    /// @notice Pulls the basket for `shares` plus the index's fee from msg.sender, and mints `shares` to `to`. The
    ///         fee's shares go to the index's fee recipients. Amounts are rounded up per component. The caller must
    ///         have approved every component. Reads no price.
    /// @param shares Shares `to` receives; 1e18 is one whole index token.
    /// @param to Receives the shares.
    function issue(uint256 shares, address to) external;

    /// @notice As {issue}, naming `referrer`, who takes the referral share of the platform's part of the fee. Zero
    ///         names nobody, and so does a referrer a gated index would not issue to as `to`: the platform keeps its
    ///         part.
    function issue(uint256 shares, address to, address referrer) external;

    /// @notice Burns `shares` from msg.sender and sends `to` the basket of those shares less the exit fee's, rounded
    ///         down ({previewRedeem}). Reads no price.
    ///         Reverts if any component transfer reverts; `IWeightedHub.redeemSkipping` exits around a frozen one.
    /// @param shares Shares to burn.
    /// @param to Receives the components.
    function redeem(uint256 shares, address to) external;

    /// @notice Component token addresses, in the order every array of this index uses.
    function componentTokens() external view returns (address[] memory tokens);

    /// @notice Exact amounts `issue(shares)` will pull for each component (rounded up), the fee's shares included.
    function previewIssue(uint256 shares) external view returns (uint256[] memory amountsIn);

    /// @notice Exact amounts `redeem(shares)` will push for each component (rounded down), the fee's shares taken.
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut);

    /// @notice Number of executed rebalances. It changes exactly when the units change. A caller that quoted a basket
    ///         at one value knows the basket changed if it now reads another.
    function rebalanceNonce() external view returns (uint256);
}
