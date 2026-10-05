// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IXindexErrors} from "./IXindexErrors.sol";
import {PythStructs} from "./pyth/PythStructs.sol";

/// @title IWeightedHub
/// @notice An index whose creator chose each component's share of its value. It is a plain ERC-20 fully backed, in
///         kind, by a basket of component tokens: 1e18 shares (one whole index token) are always redeemable for exactly
///         `units_i` raw units of each component. The constituents and their weights never change. A rebalance brings
///         the units back to the weights at Pyth prices read in the settling transaction, through an auction on the
///         growing legs; issue, redeem and claims never read a price.
/// @dev Integrators: value an index as the sum of `units_i * price_i` from {components} and an independent price
///      source. Never derive a price from `balanceOf(index)` and `totalSupply()`: inside `issue`, `redeem` and
///      `executeRebalance` they change at different moments. Only the factory's `isIndex` proves an address is an index.
///      Recipients: `to` can be neither zero (ZeroAddress) nor the index itself or its FACTORY (InvalidRecipient), and
///      a plain ERC-20 transfer to either of those reverts InvalidRecipient too. Callers other than the factory owner or
///      guardian get Unauthorized where those roles are required.
///
///      The functions an index shares with `IIndexHub` (issue, redeem, the previews, `componentTokens` and
///      `rebalanceNonce`) keep its signatures, so `IndexZap` and `MintRequests` serve these indexes unchanged.
interface IWeightedHub is IERC20, IERC20Permit, IXindexErrors {
    /// @notice One component as the factory hands it to {initialize}.
    /// @param token The component.
    /// @param units Starting raw units per 1e18 shares, non-zero and within uint96.
    /// @param weight Its share of the index's value, in basis points, non-zero; all of them sum to TOTAL_WEIGHT.
    /// @param priceId Its Pyth price id, non-zero.
    /// @param decimals Its decimals, as the factory recorded them at listing, at most 18.
    struct ComponentInit {
        address token;
        uint256 units;
        uint256 weight;
        bytes32 priceId;
        uint8 decimals;
    }

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

    /// @notice A rebalance proposal, replacing any earlier one. No event marks an expiry: a proposal nobody filled
    ///         expires after `eta + AUCTION_DURATION`, and the next `RebalanceStarted` is the first sign of it.
    /// @param proposalId Counts every proposal ever started on this index, from 1.
    /// @param id The value {rebalanceNonce} takes if this proposal executes.
    /// @param caller The account that started it.
    /// @param keepMask Bit i set leaves component i untouched.
    /// @param eta Start of the auction, after REBALANCE_DELAY of notice.
    event RebalanceStarted(
        uint256 indexed proposalId, uint256 indexed id, address indexed caller, uint256 keepMask, uint256 eta
    );
    /// @notice Cancels the proposal with this `proposalId`, which is the most recent one. Cancelling an auction that
    ///         already expired only clears the stale proposal: the hold-off the expiry granted stands.
    /// @param restartAllowedAt Before this time only the factory owner or guardian can start a rebalance.
    event RebalanceCancelled(uint256 indexed proposalId, address indexed caller, uint256 restartAllowedAt);
    /// @notice The proposal with this `proposalId` settled, and {rebalanceNonce} is now `id`.
    /// @param executor The contract that filled the auction.
    /// @param mu The multiplier on the growing legs the settlement used (1e18 = parity).
    /// @param priceTime The second the prices were read at: each is Pyth's first update at or after it.
    /// @param prices Each moving component's price, in USD per raw unit scaled by 1e36; zero for a kept one.
    /// @param units New units per component, in component order.
    /// @param amountsOut What the index sent `executor` per component.
    /// @param amountsIn What the index needed back per component; see `IRebalanceExecutor`.
    event Rebalanced(
        uint256 indexed proposalId,
        uint256 indexed id,
        address indexed executor,
        uint256 mu,
        uint256 priceTime,
        uint256[] prices,
        uint256[] units,
        uint256[] amountsOut,
        uint256[] amountsIn
    );

    /// @notice {initialize} was called by an address other than FACTORY.
    error NotFactory();
    /// @notice The implementation, or a clone the factory did not initialize, cannot issue, redeem or rebalance.
    error NotInitialized();
    /// @notice {initialize} got fewer than MIN_COMPONENTS or more than MAX_COMPONENTS components, a zero token, zero
    ///         units, a zero weight, weights that do not sum to TOTAL_WEIGHT, a zero price id, more than 18 decimals, or
    ///         two components with the same token or the same price id.
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
    /// @notice `keepMask` sets a bit at or above {componentCount}, or leaves fewer than MIN_COMPONENTS components moving:
    ///         one moving component is already on its weight among the moving ones.
    error InvalidKeepMask(uint256 keepMask);
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
    /// @notice The settlement needs more of `token` than the caller said it would fill. Only raised by the bounded
    ///         `executeRebalance`.
    error RebalanceMovedOn(address token, uint256 required, uint256 maxAmountIn);
    /// @notice What the shrinking legs would release is worth less than MIN_TRADE of the moving value at these prices:
    ///         the index is on its weights, and a fill would only restart MIN_REBALANCE_INTERVAL.
    error NothingToRebalance();
    /// @notice `prices` does not have one entry per component. Only raised by {previewRebalance}.
    error PriceCountMismatch(uint256 count);
    /// @notice Pyth returned an update for `id` that is not the one asked for, or one published outside the second
    ///         {priceTime} names and the block that settles.
    error PriceMismatch(bytes32 id, uint256 publishTime);
    /// @notice `token`'s price is not positive, has an exponent outside [MIN_EXPO, 0], or comes to more than MAX_PRICE.
    error PriceOutOfRange(address token, int64 price, int32 expo);
    /// @notice `token`'s confidence interval is wider than MAX_CONFIDENCE of its price: Pyth's publishers disagree.
    error PriceUncertain(address token, int64 price, uint64 conf);

    /// @notice Number of shares that make up one whole index token (1e18).
    function SHARE_UNIT() external view returns (uint256);

    /// @notice Fewest components an index can hold; the factory requires the same.
    function MIN_COMPONENTS() external view returns (uint256);

    /// @notice Most components an index can hold; the factory allows the same.
    function MAX_COMPONENTS() external view returns (uint256);

    /// @notice What the weights sum to: they are in basis points.
    function TOTAL_WEIGHT() external view returns (uint256);

    /// @notice Notice period between {startRebalance} and the start of the auction. Prices are read at settlement, so
    ///         the notice lets executors prepare; it does not fix anything a holder would need to leave over.
    function REBALANCE_DELAY() external view returns (uint256);

    /// @notice Time that must pass after the last executed rebalance, or after creation, before {startRebalance}.
    function MIN_REBALANCE_INTERVAL() external view returns (uint256);

    /// @notice Length of the auction. Afterwards the pending rebalance has expired: the factory owner and guardian can
    ///         start a new one at once, and anyone else from `eta + AUCTION_DURATION + REBALANCE_DELAY`.
    function AUCTION_DURATION() external view returns (uint256);

    /// @notice Where the multiplier on the growing legs starts (1e18 = parity): an executor first has to deliver more
    ///         value than it takes, at the settling prices.
    function MU_MAX() external view returns (uint256);

    /// @notice Where the multiplier ends: a lone executor at the auction's end keeps at most `1 − MU_MIN` of the value
    ///         it trades, at the settling prices.
    function MU_MIN() external view returns (uint256);

    /// @notice Most of any component's own units one rebalance sends out (1e18 = 100%). Beyond it every leg moves the
    ///         same smaller share of the way to its target. It counts units, not value, so whatever a price says, a
    ///         fill sends out at most this share of each component it sells (V5-M2).
    function MAX_TURNOVER() external view returns (uint256);

    /// @notice Least a fill must trade, as a share of the moving value at its prices (1e18 = 100%): below it the index
    ///         is on its weights and the fill reverts NothingToRebalance (V5-L2).
    function MIN_TRADE() external view returns (uint256);

    /// @notice Widest confidence interval a price may carry, as a share of the price (1e18 = 100%).
    function MAX_CONFIDENCE() external view returns (uint256);

    /// @notice How far before the settling block its prices are read, one Ethereum slot: also the length of the window
    ///         they must be published in, from {priceTime} to the second before the block.
    function PRICE_LAG() external view returns (uint256);

    /// @notice Highest price, in USD per raw unit scaled by 1e36, a settlement accepts: one raw unit worth a billion
    ///         dollars, which only a broken feed reaches. It keeps every value product inside 256 bits.
    function MAX_PRICE() external view returns (uint256);

    /// @notice Lowest exponent a Pyth price may carry.
    function MIN_EXPO() external view returns (int256);

    /// @notice Factory that deployed this index: the only address allowed to initialize it, and the one that answers
    ///         who its owner and guardian are.
    function FACTORY() external view returns (address);

    /// @notice The Pyth contract every settlement reads its prices from, fixed in the implementation.
    function PYTH() external view returns (address);

    /// @notice One-time initializer called by the factory in the same transaction as the clone.
    /// @param name_ ERC-20 name, also the EIP-712 domain name for permits.
    /// @param symbol_ ERC-20 symbol.
    /// @param components_ The components, in the order every array of this index uses.
    function initialize(string calldata name_, string calldata symbol_, ComponentInit[] calldata components_) external;

    /// @notice Pulls the exact basket for `shares` from msg.sender and mints `shares` to `to`.
    ///         Amounts are rounded up per component. Caller must have approved every component. Reads no price.
    function issue(uint256 shares, address to) external;

    /// @notice Burns `shares` from msg.sender and sends the pro-rata basket to `to`, rounded down. Reads no price.
    ///         Reverts if any component transfer reverts; use {redeemSkipping} when a component is frozen.
    function redeem(uint256 shares, address to) external;

    /// @notice Burns `shares` from msg.sender, sends every component whose bit is clear in `skipMask` to `to`,
    ///         and records the skipped amounts as claims that `to` can collect later with {claim}.
    /// @param skipMask Bit i set skips component i. Must be non-zero and use only bits below {componentCount}.
    function redeemSkipping(uint256 shares, address to, uint256 skipMask) external;

    /// @notice Pays msg.sender's whole recorded claim on `token` to `to`. Reverts while `token` still refuses the
    ///         transfer; the claim stays recorded.
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

    /// @notice What the creator fixed for each component, in component order.
    /// @return weights Share of the index's value, in basis points.
    /// @return priceIds Pyth price id.
    /// @return decimals Decimals the factory recorded at listing; prices are scaled by these, never by a live read.
    function componentTerms()
        external
        view
        returns (uint256[] memory weights, bytes32[] memory priceIds, uint8[] memory decimals);

    /// @notice Exact amounts `issue(shares)` will pull for each component (rounded up).
    function previewIssue(uint256 shares) external view returns (uint256[] memory amountsIn);

    /// @notice Exact amounts `redeem(shares)` will push for each component (rounded down).
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut);

    /// @notice Number of rebalance proposals ever started, including cancelled and expired ones.
    function proposalCount() external view returns (uint256);

    /// @notice Number of executed rebalances. It changes exactly when the units change.
    function rebalanceNonce() external view returns (uint256);

    /// @notice Time of the last executed rebalance, or of creation.
    function lastRebalance() external view returns (uint256);

    /// @notice After {cancelRebalance}, only the factory owner or guardian can start a rebalance before this time. Read
    ///         {canStartRebalance} rather than this alone.
    function restartAllowedAt() external view returns (uint256);

    /// @notice Starts the notice period. Anyone can call it once MIN_REBALANCE_INTERVAL has passed since the last
    ///         rebalance, while no unexpired rebalance is pending, and once the waits after a cancel and after an
    ///         auction nobody filled are over ({canStartRebalance} answers all of this); before those the factory owner
    ///         or guardian can start it and nobody else. It reads no price and calls nothing on any component.
    /// @param keepMask Bit i set leaves component i untouched, for example while it is paused or its price feed has
    ///        stopped. Only the factory owner or guardian can pass a non-zero mask, and it must leave at least
    ///        MIN_COMPONENTS components to rebalance.
    function startRebalance(uint256 keepMask) external;

    /// @notice Factory owner or guardian. Cancels the pending rebalance. Anyone else must then wait REBALANCE_DELAY
    ///         before starting a new one.
    function cancelRebalance() external;

    /// @notice Settles the pending rebalance during its auction. Reads every moving component's price from
    ///         `priceUpdate` at {priceTime}, through Pyth, sends msg.sender what the index no longer needs of each
    ///         shrinking component, calls `IRebalanceExecutor.onXindexRebalance` on it, and reverts unless the index
    ///         then holds every component's new backing and the whole of `amountsIn` on top of what it held before.
    ///         Only a contract can execute. Reverts NothingToRebalance when the index is on its weights.
    /// @dev The whole of msg.value goes to Pyth as its update fee, which `IPyth.getUpdateFee(priceUpdate)` quotes;
    ///      Pyth keeps any excess. `amountsOut` and `amountsIn` are recomputed from `totalSupply()` in the block that
    ///      settles; the callback's arguments are authoritative.
    /// @param data Passed unchanged to the executor's callback.
    /// @param priceUpdate Pyth's signed update data, from its Hermes service, covering every moving component at
    ///        {priceTime}.
    function executeRebalance(bytes calldata data, bytes[] calldata priceUpdate) external payable;

    /// @notice As {executeRebalance}, but refuses to settle if the index needs more of some component than the caller
    ///         is prepared to deliver (RebalanceMovedOn).
    /// @param maxAmountsIn Most of each component, in component order, the caller will deliver. Must have one entry per
    ///        component (else LengthMismatch); an empty array is the unbounded {executeRebalance}.
    function executeRebalance(bytes calldata data, bytes[] calldata priceUpdate, uint256[] calldata maxAmountsIn)
        external
        payable;

    /// @notice The second whose prices an execution in this block reads: PRICE_LAG before it. Pyth must deliver, for
    ///         each moving component, its first update published at or after this second and before the block, so a
    ///         settlement has exactly one price per component to use.
    function priceTime() external view returns (uint256);

    /// @notice The last started rebalance. `eta` is 0 when none was started or the last one was executed or cancelled;
    ///         an auction nobody filled keeps its `eta` after `eta + AUCTION_DURATION`.
    function pendingRebalance() external view returns (uint256 eta, uint256 keepMask);

    /// @notice The multiplier an execution in this block would start from, or 0 outside an auction. A settlement that
    ///         would send nothing out uses MU_MAX instead.
    function currentMu() external view returns (uint256);

    /// @notice Whether anyone can start a rebalance now: MIN_REBALANCE_INTERVAL has passed, no auction is live, and the
    ///         waits after a cancel and after an unfilled auction are over.
    function canStartRebalance() external view returns (bool);

    /// @notice Exact settlement an execution in this block would use with `prices`. Reverts like {executeRebalance}
    ///         outside an auction and on a price it would refuse; it does not check publish times.
    /// @param prices One Pyth price per component, in component order; a kept component's entry is ignored.
    /// @return mu The multiplier on the growing legs (1e18 = parity).
    /// @return units New units per component, in component order.
    /// @return amountsOut What the index would send the executor per component.
    /// @return amountsIn What the index would need back per component, in full.
    function previewRebalance(PythStructs.Price[] calldata prices)
        external
        view
        returns (uint256 mu, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn);
}
