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
///         controls its funds. v4's `IndexHub`, the one contract that implemented all of this, is deleted, and the
///         errors and events only it raised and emitted with it (audit/2026-10-06-v4-retirement.md). `IndexZap` calls
///         an index through the functions every Xindex index answers: `issue`, `redeem`, the previews,
///         `componentTokens` and `rebalanceNonce`.
/// @dev Integrators: value an index as the sum of `units_i * price_i` from {components} and an independent price
///      source. Never derive a price from `balanceOf(index)` and `totalSupply()`: inside `issue`, `redeem` and
///      `executeRebalance` they change at different moments, and a component with transfer callbacks could expose that
///      intermediate state to a reading contract. Only `IndexFactory.isIndex` proves an address is an index.
///      Recipients: `to` can be neither zero (ZeroAddress) nor the index itself or its FACTORY (InvalidRecipient). A
///      plain ERC-20 `transfer` or `transferFrom` to either of those reverts InvalidRecipient too, since neither can
///      ever move a share on (CR-I01, RT-21); one to zero reverts with OpenZeppelin's ERC20InvalidReceiver. Callers
///      other than the factory owner or guardian get Unauthorized where those roles are required.
interface IIndexHub is IERC20, IERC20Permit, IXindexErrors {
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
