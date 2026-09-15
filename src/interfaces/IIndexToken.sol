// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IIndexToken
/// @notice An index is a plain ERC-20 fully backed, in kind, by a fixed basket of component tokens.
///         1e18 shares (one whole index token) is always redeemable for exactly `units_i` raw units of
///         each component. There is no share price, no oracle and no admin control over funds.
/// @dev Integrators: value an index as the sum of `units_i * price_i` from {components} and an independent
///      price source. Never derive a price from `balanceOf(index)` and `totalSupply()`: inside `issue` and
///      `redeem` they change at different moments, and a component with transfer callbacks could expose that
///      intermediate state to a reading contract. Only `IndexFactory.isIndex` proves an address is an index.
interface IIndexToken is IERC20, IERC20Permit {
    event Issued(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
    event Redeemed(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
    event ClaimRecorded(address indexed account, address indexed token, uint256 amount);
    event Claimed(address indexed account, address indexed to, address indexed token, uint256 amount);

    error NotFactory();
    error NotInitialized();
    error InvalidComponents();
    error ZeroShares();
    error ZeroAddress();
    error InvalidRecipient(address to);
    error InvalidSkipMask(uint256 skipMask);
    error NothingToClaim(address token);
    error TransferAmountMismatch(address token);

    /// @notice Number of shares that make up one whole index token (1e18).
    function SHARE_UNIT() external view returns (uint256);

    /// @notice Factory that deployed this index; the only address allowed to initialize it.
    function FACTORY() external view returns (address);

    /// @notice One-time initializer called by the factory in the same transaction as the clone.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address[] calldata tokens,
        uint256[] calldata units
    ) external;

    /// @notice Pulls the exact basket for `shares` from msg.sender and mints `shares` to `to`.
    ///         Amounts are rounded up per component. Caller must have approved every component.
    function issue(uint256 shares, address to) external;

    /// @notice Burns `shares` from msg.sender and sends the pro-rata basket to `to`, rounded down.
    ///         Reverts if any component transfer reverts; use {redeemSkipping} when a component is frozen.
    function redeem(uint256 shares, address to) external;

    /// @notice Burns `shares` from msg.sender, sends every component whose bit is clear in `skipMask` to `to`,
    ///         and records the skipped amounts as claims that msg.sender can collect later with {claim}.
    /// @param skipMask Bit i set skips component i. Must be non-zero and use only bits below {componentCount}.
    function redeemSkipping(uint256 shares, address to, uint256 skipMask) external;

    /// @notice Pays msg.sender's recorded claim on `token` to `to`.
    function claim(address token, address to) external returns (uint256 amount);

    /// @notice Amount of `token` that `account` can collect with {claim}.
    function claimOf(address account, address token) external view returns (uint256);

    /// @notice Sum of all open claims on `token`. Always covered by the index's balance.
    function totalClaims(address token) external view returns (uint256);

    function componentCount() external view returns (uint256);

    /// @notice Component token addresses only (cheaper than {components} when units are not needed).
    function componentTokens() external view returns (address[] memory tokens);

    /// @notice Component tokens and the raw units of each backing one whole index token (1e18 shares).
    function components() external view returns (address[] memory tokens, uint256[] memory units);

    /// @notice Exact amounts `issue(shares)` will pull for each component (rounded up).
    function previewIssue(uint256 shares) external view returns (uint256[] memory amountsIn);

    /// @notice Exact amounts `redeem(shares)` will push for each component (rounded down).
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut);
}
