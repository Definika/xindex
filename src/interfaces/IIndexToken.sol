// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IIndexToken
/// @notice An index is a plain ERC-20 fully backed, in kind, by a basket of component tokens. 1e18 shares (one whole
///         index token) are always redeemable for exactly `units_i` raw units of each component. The constituents never
///         change; the units change only through a rebalance that follows the index's on-chain rule and settles through
///         an auction. There is no share price and no admin control over funds.
/// @dev Integrators: value an index as the sum of `units_i * price_i` from {components} and an independent price
///      source, or read `IIndexRule.navPerToken` for display. Never derive a price from `balanceOf(index)` and
///      `totalSupply()`: inside `issue`, `redeem` and `executeRebalance` they change at different moments, and a
///      component with transfer callbacks could expose that intermediate state to a reading contract. Only
///      `IndexFactory.isIndex` proves an address is an index.
interface IIndexToken is IERC20, IERC20Permit {
    event Issued(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
    event Redeemed(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
    event ClaimRecorded(address indexed account, address indexed token, uint256 amount);
    event Claimed(address indexed account, address indexed to, address indexed token, uint256 amount);

    /// @param id The value {rebalanceNonce} takes if this rebalance executes.
    event RebalanceStarted(
        uint256 indexed id, address indexed caller, uint256[] targetUnits, uint256 keepMask, uint256 eta
    );
    /// @param restartAllowedAt Before this time only the factory owner or guardian can start a rebalance.
    event RebalanceCancelled(uint256 indexed id, address indexed caller, uint256 restartAllowedAt);
    event Rebalanced(
        uint256 indexed id,
        address indexed executor,
        uint256 multiplier,
        uint256[] units,
        uint256[] amountsOut,
        uint256[] amountsIn
    );

    error NotFactory();
    error NotInitialized();
    error InvalidComponents();
    error ZeroShares();
    error ZeroAddress();
    error InvalidRecipient(address to);
    error InvalidSkipMask(uint256 skipMask);
    error NothingToClaim(address token);
    error TransferAmountMismatch(address token);
    error Unauthorized(address account);
    error RebalanceTooSoon(uint256 earliest);
    error RebalancePending(uint256 deadline);
    error InvalidKeepMask(uint256 keepMask);
    error TurnoverTooLow(uint256 turnover);
    error NoPendingRebalance();
    error RebalanceNotReady(uint256 eta);
    error RebalanceExpired(uint256 deadline);
    error RebalanceUnderfunded(address token, uint256 balance, uint256 required);

    /// @notice Number of shares that make up one whole index token (1e18).
    function SHARE_UNIT() external view returns (uint256);

    /// @notice Notice period between {startRebalance} and the start of the auction.
    function REBALANCE_DELAY() external view returns (uint256);

    /// @notice Time that must pass after the last executed rebalance, or after creation, before {startRebalance}.
    function MIN_REBALANCE_INTERVAL() external view returns (uint256);

    /// @notice Length of the auction. Afterwards the pending rebalance has expired and a new one can be started.
    function AUCTION_DURATION() external view returns (uint256);

    /// @notice Multiplier on the growing components' extra units when the auction opens (1e18 = parity).
    function AUCTION_START_MULTIPLIER() external view returns (uint256);

    /// @notice Multiplier on the growing components' extra units when the auction closes.
    function AUCTION_END_MULTIPLIER() external view returns (uint256);

    /// @notice Least turnover, as a share of the rebalanced value (1e18 = 100%), for which a rebalance can start.
    function MIN_TURNOVER() external view returns (uint256);

    /// @notice Factory that deployed this index; the only address allowed to initialize it.
    function FACTORY() external view returns (address);

    /// @notice Stateless rule contract that computes rebalance targets.
    function RULE() external view returns (address);

    /// @notice One-time initializer called by the factory in the same transaction as the clone.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address[] calldata tokens,
        uint256[] calldata units,
        uint8 methodology_
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

    /// @notice Weighting rule id, see `Methodology`.
    function methodology() external view returns (uint8);

    /// @notice Number of executed rebalances. It changes exactly when the units change.
    function rebalanceNonce() external view returns (uint256);

    /// @notice Time of the last executed rebalance, or of creation.
    function lastRebalance() external view returns (uint256);

    /// @notice After {cancelRebalance}, only the factory owner or guardian can start a rebalance before this time.
    function restartAllowedAt() external view returns (uint256);

    /// @notice Snapshots the rule's target units and starts the notice period. Anyone can call it once
    ///         MIN_REBALANCE_INTERVAL has passed since the last rebalance, while no unexpired rebalance is pending.
    /// @param keepMask Bit i set leaves component i untouched, for example while it is paused. Only the factory owner or
    ///        guardian can pass a non-zero mask, and it must leave at least one component to rebalance.
    function startRebalance(uint256 keepMask) external;

    /// @notice Factory owner or guardian. Cancels the pending rebalance. Anyone else must then wait REBALANCE_DELAY
    ///         before starting a new one.
    function cancelRebalance() external;

    /// @notice Settles the pending rebalance during its auction. Sends msg.sender what the index no longer needs of each
    ///         shrinking component, calls `IRebalanceExecutor.onXindexRebalance` on it, and reverts unless every
    ///         component then backs the new units. Only a contract can execute.
    function executeRebalance(bytes calldata data) external;

    /// @notice Targets and turnover {startRebalance} would snapshot now with `keepMask`.
    function previewTarget(uint256 keepMask) external view returns (uint256[] memory targetUnits, uint256 turnover);

    /// @notice The pending rebalance: auction start (0 if none), keep mask and target units.
    function pendingRebalance() external view returns (uint256 eta, uint256 keepMask, uint256[] memory targetUnits);

    /// @notice Multiplier an execution in this block would use, or 0 outside an auction.
    function currentMultiplier() external view returns (uint256);

    /// @notice Exact settlement an execution in this block would use. Reverts like {executeRebalance} outside an auction.
    function previewRebalance()
        external
        view
        returns (uint256 multiplier, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn);
}
