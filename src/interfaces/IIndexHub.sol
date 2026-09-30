// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IXindexErrors} from "./IXindexErrors.sol";

/// @title IIndexHub
/// @notice An index is a plain ERC-20 fully backed, in kind, by a basket of component tokens. 1e18 shares (one whole
///         index token) are always redeemable for exactly `units_i` raw units of each component. The constituents never
///         change. The units follow the components' reference supplies, and change only through a rebalance that
///         settles through a price-free auction on a single number, λ. Nothing in the hub reads a price, and nobody
///         controls its funds.
/// @dev Integrators: value an index as the sum of `units_i * price_i` from {components} and an independent price
///      source. Never derive a price from `balanceOf(index)` and `totalSupply()`: inside `issue`, `redeem` and
///      `executeRebalance` they change at different moments, and a component with transfer callbacks could expose that
///      intermediate state to a reading contract. Only `IndexFactory.isIndex` proves an address is an index.
///      Recipients: `to` can be neither zero (ZeroAddress) nor the index itself or its FACTORY (InvalidRecipient). A
///      plain ERC-20 `transfer` or `transferFrom` to either of those reverts InvalidRecipient too, since neither can
///      ever move a share on (CR-I01, RT-21); one to zero reverts with OpenZeppelin's ERC20InvalidReceiver. Callers
///      other than the factory owner or guardian get Unauthorized where those roles are required.
interface IIndexHub is IERC20, IERC20Permit, IXindexErrors {
    /// @notice `sender` paid `amounts` (per component, in component order, rounded up) and `to` received `shares`.
    event Issued(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
    /// @notice `sender` burned `shares` for `amounts` (per component, in component order, rounded down). With
    ///         {redeemSkipping}, the skipped components' amounts are recorded as claims for `to` instead of being
    ///         sent to it.
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
    /// @param keepMask Bit i set leaves component i untouched.
    /// @param lambdaMin Where λ ends, at `eta + AUCTION_DURATION` (1e18 = parity).
    /// @param lambdaMax Where λ starts, at `eta`.
    /// @param ratios Each moving component's clamped ratio r_i (1e18 = parity), in component order; zero for a kept one.
    /// @param eta Start of the auction, after REBALANCE_DELAY of notice.
    event RebalanceStarted(
        uint256 indexed proposalId,
        uint256 indexed id,
        address indexed caller,
        uint256 keepMask,
        uint256 lambdaMin,
        uint256 lambdaMax,
        uint256[] ratios,
        uint256 eta
    );
    /// @notice Cancels the proposal with this `proposalId`, which is the most recent one: usually the live proposal,
    ///         but `cancelRebalance` also cancels an auction that expired unfilled. That only clears the stale proposal
    ///         the views still report: the hold-off the expiry granted stands, neither shortened nor extended (VR-04).
    /// @param proposalId The cancelled proposal's id, as its `RebalanceStarted` carried it.
    /// @param caller The factory owner or guardian who cancelled it.
    /// @param restartAllowedAt Before this time only the factory owner or guardian can start a rebalance.
    event RebalanceCancelled(uint256 indexed proposalId, address indexed caller, uint256 restartAllowedAt);
    /// @notice The proposal with this `proposalId` settled, and {rebalanceNonce} is now `id`.
    /// @param proposalId The settled proposal's id, as its `RebalanceStarted` carried it.
    /// @param id The new {rebalanceNonce}.
    /// @param executor The contract that filled the auction.
    /// @param lambda The λ the settlement used (1e18 = parity).
    /// @param units New units per component, in component order.
    /// @param amountsOut What the index sent `executor` per component.
    /// @param amountsIn What the index needed back per component; see `IRebalanceExecutor`.
    event Rebalanced(
        uint256 indexed proposalId,
        uint256 indexed id,
        address indexed executor,
        uint256 lambda,
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
    /// @notice The moving components' ratios span less than MIN_BAND: their units already follow their reference
    ///         supplies (no supply changed, every supply changed alike, or a single component moves), so there is
    ///         nothing to rebalance.
    error BandTooNarrow(uint256 lambdaMin, uint256 lambdaMax);
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
    /// @notice The settlement needs more of `token` than the caller said it would fill, because the supply grew
    ///         between the quote and this block. Only raised by the bounded `executeRebalance`.
    error RebalanceMovedOn(address token, uint256 required, uint256 maxAmountIn);

    /// @notice Number of shares that make up one whole index token (1e18).
    function SHARE_UNIT() external view returns (uint256);

    /// @notice Notice period between {startRebalance} and the start of the auction.
    function REBALANCE_DELAY() external view returns (uint256);

    /// @notice Time that must pass after the last executed rebalance, or after creation, before {startRebalance}.
    function MIN_REBALANCE_INTERVAL() external view returns (uint256);

    /// @notice Length of the auction. Afterwards the pending rebalance has expired: the factory owner and guardian can
    ///         start a new one at once, and anyone else from `eta + AUCTION_DURATION + REBALANCE_DELAY`; see
    ///         {canStartRebalance} (RT-08).
    function AUCTION_DURATION() external view returns (uint256);

    /// @notice How far a moving component's ratio may sit from the band's centre (1e18 = 100%): the hub's per-rebalance
    ///         clamp, the same 0.5% as the factory's per-update step. It bounds the band at
    ///         (1 + STEP) / (1 − STEP), so a lone executor at the auction's floor takes at most 0.995% of the moving value.
    function MAX_SUPPLY_STEP() external view returns (uint256);

    /// @notice Narrowest band a rebalance can start with (1e18 = 100%): below it units already follow supplies to
    ///         within rounding.
    function MIN_BAND() external view returns (uint256);

    /// @notice Factory that deployed this index: the only address allowed to initialize it, and the source of the
    ///         reference supplies a rebalance reads.
    function FACTORY() external view returns (address);

    /// @notice One-time initializer called by the factory in the same transaction as the clone.
    /// @param name_ ERC-20 name, also the EIP-712 domain name for permits.
    /// @param symbol_ ERC-20 symbol.
    /// @param tokens Components, in the order every array of this index uses.
    /// @param units Starting raw units per 1e18 shares, non-zero and within uint96.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address[] calldata tokens,
        uint256[] calldata units
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
    ///         and records the skipped amounts as claims that `to` can collect later with {claim}. The claim follows
    ///         the components to the recipient, so a contract redeeming on a holder's behalf does not end up holding
    ///         a claim only it could collect.
    /// @param shares Shares to burn.
    /// @param to Receives the components that are not skipped, and owns the claims for those that are.
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

    /// @notice Number of rebalance proposals ever started, including cancelled and expired ones. Every
    ///         `RebalanceStarted` carries its own value, so an indexer can tell attempts apart.
    function proposalCount() external view returns (uint256);

    /// @notice Number of executed rebalances. It changes exactly when the units change.
    function rebalanceNonce() external view returns (uint256);

    /// @notice Time of the last executed rebalance, or of creation.
    function lastRebalance() external view returns (uint256);

    /// @notice After {cancelRebalance}, only the factory owner or guardian can start a rebalance before this time. Only
    ///         a cancel sets it: an auction that expires unfilled holds strangers off until `eta + AUCTION_DURATION +
    ///         REBALANCE_DELAY` without moving it, so read {canStartRebalance} rather than this alone (RT-08).
    function restartAllowedAt() external view returns (uint256);

    /// @notice Snapshots the band of the moving components' ratios and starts the notice period. Anyone can call it once
    ///         MIN_REBALANCE_INTERVAL has passed since the last rebalance, while no unexpired rebalance is pending, and
    ///         once {restartAllowedAt} and, after an auction nobody filled, REBALANCE_DELAY past that auction's end
    ///         have passed ({canStartRebalance} answers all of this); before those the factory owner or guardian can
    ///         start it and nobody else. The auction's end is its last fillable second, `eta + AUCTION_DURATION`, so
    ///         after an expiry the owner and guardian have the start to themselves for REBALANCE_DELAY less one second,
    ///         against a full REBALANCE_DELAY after a cancel (CR-I02). Reverts BandTooNarrow when the band is narrower
    ///         than MIN_BAND. It reads the reference supplies of the moving components from the factory, and calls
    ///         nothing on any component.
    /// @param keepMask Bit i set leaves component i untouched, for example while it is paused. Only the factory owner or
    ///        guardian can pass a non-zero mask, and it must leave at least one component to rebalance.
    function startRebalance(uint256 keepMask) external;

    /// @notice Factory owner or guardian. Cancels the pending rebalance. Anyone else must then wait REBALANCE_DELAY
    ///         before starting a new one. Cancelling an auction that already expired only clears the stale proposal
    ///         the views still report: the hold-off that expiry granted stands, and the cancel never pushes it out.
    function cancelRebalance() external;

    /// @notice Settles the pending rebalance during its auction at the current λ. Sends msg.sender what the index no
    ///         longer needs of each shrinking component, calls `IRebalanceExecutor.onXindexRebalance` on it, and
    ///         reverts unless the index then holds every component's new backing and the whole of `amountsIn` on top
    ///         of what it held before. Only a contract can execute. Nothing is priced.
    /// @dev `amountsOut` and `amountsIn` are recomputed from `totalSupply()` in the block that settles, and issue and
    ///      redeem stay open throughout the notice and the auction, so they can differ from any earlier simulation.
    ///      The callback's arguments are authoritative; an executor that sizes itself off chain should either source
    ///      from them or use the bounded overload.
    /// @param data Passed unchanged to the executor's callback.
    function executeRebalance(bytes calldata data) external;

    /// @notice As {executeRebalance}, but refuses to settle if the supply grew enough since the caller quoted that the
    ///         index now needs more of some component than the caller is prepared to deliver (RebalanceMovedOn).
    /// @param data Passed unchanged to the executor's callback.
    /// @param maxAmountsIn Most of each component, in component order, the caller will deliver. Must have one entry per
    ///        component (else LengthMismatch); an empty array is the unbounded {executeRebalance}.
    function executeRebalance(bytes calldata data, uint256[] calldata maxAmountsIn) external;

    /// @notice The band {startRebalance} would snapshot now with `keepMask`. It checks neither the caller nor the mask,
    ///         and a band narrower than MIN_BAND is returned rather than refused.
    /// @return ratios Each moving component's clamped ratio (1e18 = parity), in component order; zero for a kept one.
    /// @return lambdaMin The smallest ratio, where the auction would end.
    /// @return lambdaMax The largest ratio, where it would start.
    function previewBand(uint256 keepMask)
        external
        view
        returns (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax);

    /// @notice The last started rebalance. `eta` is 0 when none was started or the last one was executed or cancelled;
    ///         an auction nobody filled keeps its `eta` after `eta + AUCTION_DURATION`, and a new rebalance can then be
    ///         started by the factory owner or guardian at once and by anyone else from `eta + AUCTION_DURATION +
    ///         REBALANCE_DELAY` (RT-08).
    function pendingRebalance()
        external
        view
        returns (uint256 eta, uint256 keepMask, uint256 lambdaMin, uint256 lambdaMax, uint256[] memory ratios);

    /// @notice λ an execution in this block would use, or 0 outside an auction. It is `lambdaMax` when the settlement
    ///         would send nothing out, as on an empty index.
    function currentLambda() external view returns (uint256);

    /// @notice Whether anyone can start a rebalance now: MIN_REBALANCE_INTERVAL has passed, no auction is live (an
    ///         unfilled one keeps its `eta` but stops counting after `eta + AUCTION_DURATION`), and the waits after a
    ///         cancel and after an unfilled auction are over. It does not read the band, so a start can still revert
    ///         BandTooNarrow; {previewBand} answers that. While it is false the factory owner and guardian can still
    ///         start during those two waits, but not before MIN_REBALANCE_INTERVAL or while an auction is live (RT-09).
    function canStartRebalance() external view returns (bool);

    /// @notice Exact settlement an execution in this block would use. Reverts like {executeRebalance} outside an auction.
    /// @return lambda The λ it would use (1e18 = parity).
    /// @return units New units per component, in component order.
    /// @return amountsOut What the index would send the executor per component.
    /// @return amountsIn What the index would need back per component, in full.
    function previewRebalance()
        external
        view
        returns (uint256 lambda, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn);
}
