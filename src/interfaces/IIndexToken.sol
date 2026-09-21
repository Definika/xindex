// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IXindexErrors} from "./IXindexErrors.sol";

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
///      Recipients: `to` can be neither zero (ZeroAddress) nor the index itself (InvalidRecipient). Callers other than
///      the factory owner or guardian get Unauthorized where those roles are required.
interface IIndexToken is IERC20, IERC20Permit, IXindexErrors {
    /// @notice `sender` paid `amounts` (per component, in component order, rounded up) and `to` received `shares`.
    event Issued(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
    /// @notice `sender` burned `shares` for `amounts` (per component, in component order, rounded down). With
    ///         {redeemSkipping}, the skipped components' amounts are recorded as claims for `sender` instead of being
    ///         sent to `to`.
    event Redeemed(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
    /// @notice {redeemSkipping} kept `amount` of `token` in the index for `account` to collect with {claim}.
    event ClaimRecorded(address indexed account, address indexed token, uint256 amount);
    /// @notice `account`'s claim of `amount` of `token` was paid to `to`.
    event Claimed(address indexed account, address indexed to, address indexed token, uint256 amount);

    /// @notice A rebalance proposal, replacing any earlier one. Each one carries its own `proposalId` ({proposalCount}
    ///         after the call), so proposals can be told apart even when several share an `id`, the value
    ///         {rebalanceNonce} takes if one of them executes. No event marks an expiry: a proposal nobody filled
    ///         expires after `eta + AUCTION_DURATION`, and the next `RebalanceStarted` is the first sign of it.
    /// @param proposalId Counts every proposal ever started on this index, from 1.
    /// @param id The value {rebalanceNonce} takes if this proposal executes.
    /// @param caller The account that started it.
    /// @param targetUnits Snapshot target units per component, in component order, in raw units per 1e18 shares.
    /// @param keepMask Bit i set leaves component i untouched.
    /// @param eta Start of the auction, after REBALANCE_DELAY of notice.
    event RebalanceStarted(
        uint256 indexed proposalId,
        uint256 indexed id,
        address indexed caller,
        uint256[] targetUnits,
        uint256 keepMask,
        uint256 eta
    );
    /// @notice Cancels the proposal with this `proposalId`, which is the live one.
    /// @param proposalId The cancelled proposal's id, as its `RebalanceStarted` carried it.
    /// @param caller The factory owner or guardian who cancelled it.
    /// @param restartAllowedAt Before this time only the factory owner or guardian can start a rebalance.
    event RebalanceCancelled(uint256 indexed proposalId, address indexed caller, uint256 restartAllowedAt);
    /// @notice The proposal with this `proposalId` settled, and {rebalanceNonce} is now `id`.
    /// @param proposalId The settled proposal's id, as its `RebalanceStarted` carried it.
    /// @param id The new {rebalanceNonce}.
    /// @param executor The contract that filled the auction.
    /// @param multiplier Multiplier applied to the growing components' extra units (1e18 = parity).
    /// @param units New units per component, in component order.
    /// @param amountsOut What the index sent `executor` per component.
    /// @param amountsIn What the index needed back per component; see `IRebalanceExecutor`.
    event Rebalanced(
        uint256 indexed proposalId,
        uint256 indexed id,
        address indexed executor,
        uint256 multiplier,
        uint256[] units,
        uint256[] amountsOut,
        uint256[] amountsIn
    );

    /// @notice {initialize} was called by an address other than FACTORY.
    error NotFactory();
    /// @notice The implementation, or a clone the factory did not initialize, cannot issue, redeem or rebalance.
    error NotInitialized();
    /// @notice {initialize} got no components, arrays of different lengths, a zero token or zero units.
    error InvalidComponents();
    /// @notice `shares` is zero.
    error ZeroShares();
    /// @notice `skipMask` is zero or sets a bit at or above {componentCount}.
    error InvalidSkipMask(uint256 skipMask);
    /// @notice The caller has no claim on `token`.
    error NothingToClaim(address token);
    /// @notice {issue} received less `token` than it pulled, as with a fee-on-transfer token.
    error TransferAmountMismatch(address token);
    /// @notice MIN_REBALANCE_INTERVAL has not passed since the last rebalance; it does at `earliest`.
    error RebalanceTooSoon(uint256 earliest);
    /// @notice A rebalance is pending until `deadline`, the end of its auction.
    error RebalancePending(uint256 deadline);
    /// @notice `keepMask` sets a bit at or above {componentCount}, or keeps every component.
    error InvalidKeepMask(uint256 keepMask);
    /// @notice The snapshot would sell `turnover` of the rebalanced value, less than MIN_TURNOVER.
    error TurnoverTooLow(uint256 turnover);
    /// @notice No rebalance is pending.
    error NoPendingRebalance();
    /// @notice The auction opens at `eta`.
    error RebalanceNotReady(uint256 eta);
    /// @notice The auction closed at `deadline`; start a new rebalance.
    error RebalanceExpired(uint256 deadline);
    /// @notice After the executor returned, the index held `balance` of `token`, below `required`: the higher of the
    ///         backing (totalSupply * new units / 1e18, plus open claims on `token`) and what the index held before the
    ///         settlement, less what it sent out and plus the whole of what it asked back.
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
    /// @param name_ ERC-20 name, also the EIP-712 domain name for permits.
    /// @param symbol_ ERC-20 symbol.
    /// @param tokens Components, in the order every array of this index uses.
    /// @param units Starting raw units per 1e18 shares, non-zero and within uint96.
    /// @param methodology_ Weighting rule id. Not checked here: the factory validates it before initializing.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address[] calldata tokens,
        uint256[] calldata units,
        uint8 methodology_
    ) external;

    /// @notice Pulls the exact basket for `shares` from msg.sender and mints `shares` to `to`.
    ///         Amounts are rounded up per component. Caller must have approved every component.
    /// @param shares Shares to mint; 1e18 is one whole index token.
    /// @param to Receives the shares.
    function issue(uint256 shares, address to) external;

    /// @notice Burns `shares` from msg.sender and sends the pro-rata basket to `to`, rounded down.
    ///         Reverts if any component transfer reverts; use {redeemSkipping} when a component is frozen.
    /// @param shares Shares to burn.
    /// @param to Receives the components.
    function redeem(uint256 shares, address to) external;

    /// @notice Burns `shares` from msg.sender, sends every component whose bit is clear in `skipMask` to `to`,
    ///         and records the skipped amounts as claims that msg.sender can collect later with {claim}.
    /// @param shares Shares to burn.
    /// @param to Receives the components that are not skipped.
    /// @param skipMask Bit i set skips component i. Must be non-zero and use only bits below {componentCount}.
    function redeemSkipping(uint256 shares, address to, uint256 skipMask) external;

    /// @notice Pays msg.sender's whole recorded claim on `token` to `to`. Reverts while `token` still refuses the
    ///         transfer; the claim stays recorded.
    /// @param token Component whose claim is paid.
    /// @param to Receives the tokens.
    /// @return amount Raw units of `token` paid.
    function claim(address token, address to) external returns (uint256 amount);

    /// @notice Amount of `token` that `account` can collect with {claim}.
    function claimOf(address account, address token) external view returns (uint256);

    /// @notice Sum of all open claims on `token`. Always covered by the index's balance.
    function totalClaims(address token) external view returns (uint256);

    /// @notice Number of components, fixed at initialization.
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

    /// @notice Number of rebalance proposals ever started, including cancelled and expired ones. Every
    ///         `RebalanceStarted` carries its own value, so an indexer can tell attempts apart.
    function proposalCount() external view returns (uint256);

    /// @notice Number of executed rebalances. It changes exactly when the units change.
    function rebalanceNonce() external view returns (uint256);

    /// @notice Time of the last executed rebalance, or of creation.
    function lastRebalance() external view returns (uint256);

    /// @notice After {cancelRebalance}, only the factory owner or guardian can start a rebalance before this time.
    function restartAllowedAt() external view returns (uint256);

    /// @notice Snapshots the rule's target units and starts the notice period. Anyone can call it once
    ///         MIN_REBALANCE_INTERVAL has passed since the last rebalance, while no unexpired rebalance is pending, and
    ///         once {restartAllowedAt} and, after an auction nobody filled, REBALANCE_DELAY past that auction's end
    ///         have passed ({canStartRebalance} answers all of this); before those the factory owner or guardian can
    ///         start it and nobody else. Reverts with
    ///         TurnoverTooLow when the targets would sell less than MIN_TURNOVER, and with the rule's ThinPriceHistory
    ///         or PriceHistoryDeviates when a moving component's price window fails the snapshot checks.
    /// @param keepMask Bit i set leaves component i untouched, for example while it is paused. Only the factory owner or
    ///        guardian can pass a non-zero mask, and it must leave at least one component to rebalance.
    function startRebalance(uint256 keepMask) external;

    /// @notice Factory owner or guardian. Cancels the pending rebalance. Anyone else must then wait REBALANCE_DELAY
    ///         before starting a new one. Cancelling an auction that already expired only clears the stale proposal
    ///         the views still report: the hold-off that expiry granted stands, and the cancel never pushes it out.
    function cancelRebalance() external;

    /// @notice Settles the pending rebalance during its auction. Sends msg.sender what the index no longer needs of each
    ///         shrinking component, calls `IRebalanceExecutor.onXindexRebalance` on it, and reverts unless the index
    ///         then holds every component's new backing and the whole of `amountsIn` on top of what it held before.
    ///         Only a contract can execute.
    /// @param data Passed unchanged to the executor's callback.
    function executeRebalance(bytes calldata data) external;

    /// @notice Targets and turnover {startRebalance} would snapshot now with `keepMask`, with the same price checks. It
    ///         checks neither the caller nor the mask: bits at or above {componentCount} and a turnover below
    ///         MIN_TURNOVER are accepted here but make {startRebalance} revert. A mask that keeps every component
    ///         reverts with the rule's DegenerateBasket.
    /// @return targetUnits Target raw units per 1e18 shares, per component in component order.
    /// @return turnover Value the rebalance would sell, as a share of the rebalanced components' value (1e18 = 100%).
    function previewTarget(uint256 keepMask) external view returns (uint256[] memory targetUnits, uint256 turnover);

    /// @notice The last started rebalance: auction start, keep mask and target units. `eta` is 0 when none was started
    ///         or the last one was executed or cancelled; an auction nobody filled keeps its `eta` after `eta +
    ///         AUCTION_DURATION`, and a new rebalance can then be started.
    function pendingRebalance() external view returns (uint256 eta, uint256 keepMask, uint256[] memory targetUnits);

    /// @notice Multiplier an execution in this block would use, or 0 outside an auction. It is parity when the
    ///         settlement would send nothing out, as on an empty index.
    function currentMultiplier() external view returns (uint256);

    /// @notice Whether anyone can start a rebalance now: MIN_REBALANCE_INTERVAL has passed, no auction is live (an
    ///         unfilled one keeps its `eta` but stops counting after `eta + AUCTION_DURATION`), and the waits after a
    ///         cancel and after an unfilled auction are over. It does not read the rule, so a start can still revert
    ///         with TurnoverTooLow or a snapshot price error, and the factory owner and guardian can start when it is
    ///         false.
    function canStartRebalance() external view returns (bool);

    /// @notice Exact settlement an execution in this block would use. Reverts like {executeRebalance} outside an auction.
    /// @return multiplier Multiplier on the growing components' extra units (1e18 = parity).
    /// @return units New units per component, in component order.
    /// @return amountsOut What the index would send the executor per component.
    /// @return amountsIn What the index would need back per component, in full.
    function previewRebalance()
        external
        view
        returns (uint256 multiplier, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn);
}
