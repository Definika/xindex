// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexHub} from "./IIndexHub.sol";
import {IXindexErrors} from "./IXindexErrors.sol";

/// @title IWeightedHub
/// @notice An index whose creator chose each component's share of its value (its weight).
///         - It is a plain ERC-20, fully backed in kind by a basket of component tokens.
///         - 1e18 shares (one whole index token) always redeem for exactly `units_i` raw units of each component,
///           minus the index's fee.
///         - The components and their weights never change.
///         - A rebalance brings the units back toward the weights through an auction. Its executor names the new
///           units, and the index accepts them only if their weighted gain clears a bar that falls with time
///           ({executeRebalance}). Competing executors are what make the trade fair. The trade that scores highest
///           is close to the one that puts the index on its weights at the market's prices, not exactly it: the
///           score runs under the logarithm, so a trade a little short of the weights can score a little more.
///         - Nothing here reads a price: not a rebalance, not an issue, a redeem or a claim.
///
///         Fees
///         - Fees are paid in shares and never move a component. A minter's deposit backs the fee's shares on top of
///           its own. A burner's fee is minted to the recipients out of the shares it burns. So every share is backed
///           by the deposit that minted it.
///         - The rates are fixed at creation. The creator picks its own rate, up to the factory's caps. The platform's
///           rate is the factory's policy at that moment. A referrer named at mint takes the referral share of the
///           platform's part, unless the index is gated and its gate would refuse the referrer as a recipient.
///           The minter names the referrer and may name itself, or an account it controls: the referral share is
///           in effect a rebate every minter can take.
///         - Only an issue and a redeem charge the entry and exit fee. A fill that shrinks no leg takes nothing out
///           and mints no share for what it adds: it is a gift to the holders, in proportion to their shares, the
///           fee recipients' included. So a holder of nearly all the supply can add to its own position through a
///           fill, with no entry fee and no gate.
///         - A streaming fee is a yearly rate on the index's value. It accrues on every issue, redeem and settlement,
///           on {accrueFees}, and when the creator role is handed over. Each accrual mints the recipients their share
///           of the index, and shrinks every share's units by the same factor ({pendingStreamingFee}). So every
///           share's backing stays exactly what the index holds.
///         - The yearly rate is a ceiling. Each accrual charges the rate for the time since the last one, on what is
///           left, so the more often anyone accrues, the less a year takes: at 500 basis points, 5.00% with one
///           accrual a year and 4.88% with one a day. Anyone can call {accrueFees}; holders never pay more than the
///           rate.
///         - The factory names the recipients (the creator and the platform) at each call (`feeTerms`). It also says
///           whether `to` may receive shares of a gated index. The creator keeps that allowlist and can hand the role
///           on.
///         - A recipient that cannot hold shares is replaced, so no recipient can block a mint or an exit.
/// @dev Integrators
///      - Value an index as the sum of `units_i * price_i`, with units from {components} and an independent price
///        source.
///      - Never derive a price from `balanceOf(index)` and `totalSupply()`. Inside `issue`, `redeem` and
///        `executeRebalance` they change at different moments.
///      - Only the factory's `isIndex` proves an address is an index.
///      - `to` cannot be zero (ZeroAddress), the index itself or its FACTORY (InvalidRecipient). A plain ERC-20
///        transfer to the index or FACTORY reverts InvalidRecipient too.
///      - A caller other than the factory owner or guardian gets Unauthorized where those roles are required.
///      - It extends `IIndexHub`, which declares everything `IndexZap` calls on an index: `issue`, `redeem`, the
///        previews, `componentTokens` and `rebalanceNonce`.
interface IWeightedHub is IIndexHub, IXindexErrors {
    /// @notice One component as the factory hands it to {initialize}.
    /// @param token The component.
    /// @param units Starting raw units per 1e18 shares, non-zero and within uint96.
    /// @param weight Its share of the index's value, in basis points, non-zero; all of them sum to TOTAL_WEIGHT.
    struct ComponentInit {
        address token;
        uint256 units;
        uint256 weight;
    }

    /// @notice The first issue, made by {initialize} in the index's own creation: an issue as any other, except that
    ///         the basket is pulled from `from`, the index's creator, who approved the index's address before it
    ///         existed. Zero `shares` means the index is created with no shares.
    /// @param from Pays the basket: whoever called the factory's `createIndex`.
    /// @param shares Shares `to` receives; 1e18 is one whole index token.
    /// @param to Receives the shares.
    struct FirstIssue {
        address from;
        uint256 shares;
        address to;
    }

    /// @notice What the factory fixed for the index at creation, besides its components. None of it ever changes.
    /// @param creatorFeeBps The creator's fee on every issue and on every redeem, in basis points of the shares, at
    ///        most the factory's MAX_CREATOR_FEE_BPS.
    /// @param platformFeeBps The platform's fee, likewise, at most the factory's MAX_PLATFORM_FEE_BPS.
    /// @param referralShareBps The referrer's share of the platform's fee, in basis points, at most 10,000.
    /// @param creatorStreamingBps The creator's streaming fee, in basis points of the index's value per year, at most
    ///        the factory's MAX_CREATOR_STREAMING_BPS.
    /// @param platformStreamingBps The platform's streaming fee, likewise, at most the factory's
    ///        MAX_PLATFORM_STREAMING_BPS.
    /// @param rebalanceInterval Seconds between rebalances, at least MIN_REBALANCE_INTERVAL and at most the
    ///        factory's MAX_REBALANCE_INTERVAL.
    struct Config {
        uint16 creatorFeeBps;
        uint16 platformFeeBps;
        uint16 referralShareBps;
        uint16 creatorStreamingBps;
        uint16 platformStreamingBps;
        uint32 rebalanceInterval;
    }

    /// @notice The index's weights are now `weights`, set through its factory after the creator's notice; its units
    ///         follow at its next rebalance.
    event WeightsChanged(uint256[] weights);

    /// @notice `sender` paid `amounts` (per component, in component order, rounded up) and `to` received `shares`.
    ///         For the first issue of an index created with one, `sender` is its creator.
    event Issued(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
    /// @notice `sender` burned `shares` for `amounts` (per component, in component order, rounded down). With
    ///         {redeemSkipping}, the skipped components' amounts are recorded as claims for `to` instead of being
    ///         sent to it.
    event Redeemed(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
    /// @notice {redeemSkipping} kept `amount` of `token` in the index for `account` to collect with {claim}.
    event ClaimRecorded(address indexed account, address indexed token, uint256 amount);
    /// @notice `account`'s claim of `amount` of `token` was paid to `to`.
    event Claimed(address indexed account, address indexed to, address indexed token, uint256 amount);
    /// @notice The streaming fee of `feeShares` shares was minted to the recipients for the time since the last
    ///         accrual, and every component's recorded units now carry `scale` (1e18 = none).
    event StreamingFeeAccrued(uint256 feeShares, uint256 scale);
    /// @notice An issue, a redeem or a streaming accrual minted its fee: `creatorShares` to `creator`,
    ///         `platformShares` to `platform` and `referrerShares` to `referrer` (zero if none was named).
    ///         The factory names the recipients. A creator that cannot hold shares is replaced by the call's `to` (the
    ///         caller, for an accrual). A platform that cannot is reported as zero, and its part goes to the creator.
    event FeeSharesMinted(
        address indexed referrer,
        address creator,
        address platform,
        uint256 creatorShares,
        uint256 platformShares,
        uint256 referrerShares
    );

    /// @notice A rebalance proposal, replacing any earlier one. No event marks an expiry. A proposal nobody filled
    ///         expires after `eta + AUCTION_DURATION`; the next `RebalanceStarted` is the first sign of it.
    /// @param proposalId Counts every proposal ever started on this index, from 1.
    /// @param id The value {rebalanceNonce} takes if this proposal executes.
    /// @param caller The account that started it.
    /// @param keepMask Bit i set leaves component i untouched.
    /// @param eta Start of the auction, after REBALANCE_DELAY of notice.
    event RebalanceStarted(
        uint256 indexed proposalId, uint256 indexed id, address indexed caller, uint256 keepMask, uint256 eta
    );
    /// @notice The most recent proposal, `proposalId`, was cancelled. Cancelling an auction that already expired only
    ///         clears the stale proposal: the wait the expiry set still stands.
    /// @param restartAllowedAt Before this time only the factory owner or guardian can start a rebalance.
    event RebalanceCancelled(uint256 indexed proposalId, address indexed caller, uint256 restartAllowedAt);
    /// @notice The owner or guardian posted a quote with proposal `proposalId`: one price per component, in any one
    ///         unit per raw unit of the token (zero for a kept component), and the tolerance, 1e18 = 100%. A fill of
    ///         this proposal must also bring in, at these prices, at least `1 − tolerance` of what it takes out.
    event RebalanceQuoted(uint256 indexed proposalId, uint256[] prices, uint256 tolerance);
    /// @notice The proposal with this `proposalId` settled, and {rebalanceNonce} is now `id`.
    /// @param executor The contract that filled the auction.
    /// @param bar The gain the auction asked for in the settling block (1e18 = 100%).
    /// @param gain The fill's weighted gain, at least `bar`.
    /// @param units New recorded units per component, in component order, as the executor named them. Like the old
    ///        ones, they carry the index's scale (the last `StreamingFeeAccrued` one); {components} reports them with
    ///        it applied. A kept component's units are unchanged.
    /// @param amountsOut What the index sent `executor` per component.
    /// @param amountsIn What the index needed back per component; see `IRebalanceExecutor`.
    event Rebalanced(
        uint256 indexed proposalId,
        uint256 indexed id,
        address indexed executor,
        uint256 bar,
        int256 gain,
        uint256[] units,
        uint256[] amountsOut,
        uint256[] amountsIn
    );

    /// @notice {initialize} was called by an address other than FACTORY.
    error NotFactory();
    /// @notice The implementation, or a clone the factory did not initialize, cannot issue, redeem or rebalance.
    error NotInitialized();
    /// @notice {initialize} got fewer than MIN_COMPONENTS or more than MAX_COMPONENTS components, a zero token, zero
    ///         units, a zero weight, weights that do not sum to TOTAL_WEIGHT, or the same token twice.
    error InvalidComponents();
    /// @notice {initialize} got fee rates summing to more than 125 basis points, streaming rates summing to more than
    ///         600, a referral share above 10,000 basis points, or an interval below MIN_REBALANCE_INTERVAL. The
    ///         factory bounds each rate and the interval more tightly.
    error InvalidConfig();
    /// @notice The factory does not let `to` be issued shares now: the index is gated and `to` is not on its
    ///         allowlist, or minting is paused, on this index or on every index (`mintingPaused`).
    error NotAllowedMinter(address to);
    /// @notice `shares` is zero.
    error ZeroShares();
    /// @notice `skipMask` is zero or sets a bit at or above {componentCount}.
    error InvalidSkipMask(uint256 skipMask);
    /// @notice The caller has no claim on `token`, or asked for none of it.
    error NothingToClaim(address token);
    /// @notice The caller asked for `amount` of `token`, more than the `recorded` claim it holds.
    error ClaimTooLarge(address token, uint256 amount, uint256 recorded);
    /// @notice {issue} received less `token` than it pulled, as with a fee-on-transfer token.
    error TransferAmountMismatch(address token);
    /// @notice The caller may not start a rebalance yet: it may at `earliest`, the index's rebalance interval after
    ///         the last fill or the creation, or, once a fill has settled, MIN_REBALANCE_INTERVAL after it for the
    ///         factory owner or guardian.
    error RebalanceTooSoon(uint256 earliest);
    /// @notice A rebalance is pending until `deadline`, the end of its auction.
    error RebalancePending(uint256 deadline);
    /// @notice `keepMask` sets a bit at or above {componentCount}, or leaves fewer than MIN_COMPONENTS components
    ///         moving. One moving component alone is always on its weight, so there would be nothing to trade.
    error InvalidKeepMask(uint256 keepMask);
    /// @notice No rebalance is pending.
    error NoPendingRebalance();
    /// @notice The cancel names proposal `expected`, and the index's latest is `actual`: the one the caller meant is
    ///         gone and another was started since.
    error StaleProposal(uint256 expected, uint256 actual);
    /// @notice The auction opens at `eta`.
    error RebalanceNotReady(uint256 eta);
    /// @notice The auction closed at `deadline`; start a new rebalance.
    error RebalanceExpired(uint256 deadline);
    /// @notice After the executor returned, the index held `balance` of `token`, below `required`. `required` is the
    ///         higher of:
    ///         - the backing: totalSupply * new units * scale / 1e36, plus open claims on `token`;
    ///         - what the index held before the settlement, minus what it sent out, plus all it asked back.
    error RebalanceUnderfunded(address token, uint256 balance, uint256 required);
    /// @notice The settlement needs more of `token` than the caller said it would fill. Only raised by the bounded
    ///         `executeRebalance`.
    error RebalanceMovedOn(address token, uint256 required, uint256 maxAmountIn);
    /// @notice The index has less than one whole share (SHARE_UNIT), so it has nothing to trade. Its units stay as
    ///         they are. A fill pays in proportion to the supply, so on a nearly empty index the units would move for
    ///         a few wei.
    error NothingToRebalance();
    /// @notice The fill names `units` for component `index`, outside what one fill may leave it with: at least
    ///         `lowest` (what MAX_TURNOVER leaves, rounded up) and at most `highest` (what MAX_GROWTH adds). A kept
    ///         component must keep its units exactly, so both bounds are its current units.
    error LegOutOfBounds(uint256 index, uint256 units, uint256 lowest, uint256 highest);
    /// @notice The fill's weighted gain is `gain`, under the `bar` the auction asks for in this block. It will be
    ///         accepted once the bar has fallen to it, if nobody fills first. A fill that changes nothing has no gain,
    ///         so none can restart the rebalance interval for free (V5-L2). The least a fill can give is the bar at
    ///         the auction's last second, about 4.8e-7. In an auction nothing else filled, or could fill, a fill that
    ///         gives only that restarts the interval like any other, for everyone, the owner and guardian included.
    error GainBelowBar(int256 gain, uint256 bar);
    /// @notice The math was asked for a bar `elapsed` seconds into an auction, past AUCTION_DURATION. The hub refuses
    ///         an expired auction first (RebalanceExpired), so only a direct call to the math sees this.
    error AuctionOver(uint256 elapsed);
    /// @notice A quote must name a price from 1 to 2^128 − 1 for every component the keep mask leaves moving, and a
    ///         tolerance under 100%.
    error InvalidQuote();
    /// @notice The fill brings in `valueIn` at the prices the owner or guardian posted with this proposal, under the
    ///         `floor` the quote asks: the value it takes out, less the tolerance, rounded up.
    error BelowQuote(uint256 valueIn, uint256 floor);

    /// @notice At Pyth's prices the fill brings in `valueIn`, under the `floor` the auction's oracle tolerance allows
    ///         at this second: what it takes, less that tolerance.
    error BelowOracleValue(uint256 valueIn, uint256 floor);
    /// @notice After a fill or an issue, the index could not send itself one raw unit of `token`, a leg it bought or
    ///         was just paid, or lost some doing so: a token that blocks the index as a sender would trap what came
    ///         in (RX-12).
    error CannotSendOut(address token);

    /// @notice Number of shares that make up one whole index token (1e18).
    function SHARE_UNIT() external view returns (uint256);

    /// @notice Fewest components an index can hold; the factory requires the same.
    function MIN_COMPONENTS() external view returns (uint256);

    /// @notice Most components an index can hold; the factory allows the same.
    function MAX_COMPONENTS() external view returns (uint256);

    /// @notice What the weights sum to: they are in basis points.
    function TOTAL_WEIGHT() external view returns (uint256);

    /// @notice Notice period between {startRebalance} and the start of the auction. It lets executors prepare. It is
    ///         not an exit window for holders, who can redeem at any time.
    function REBALANCE_DELAY() external view returns (uint256);

    /// @notice Shortest rebalance interval an index can be created with. It is also the wait that a settlement with a
    ///         keep mask restarts, whatever the index's own interval ({earliestRebalance}), and the wait after any
    ///         fill before the factory owner or guardian may start the next. The factory bounds the interval
    ///         above.
    function MIN_REBALANCE_INTERVAL() external view returns (uint256);

    /// @notice Length of the auction, over which the bar falls from the math's BAR_MAX by half every BAR_HALF_LIFE.
    ///         After it, the pending rebalance has expired. The factory owner and guardian can start a new one at
    ///         once; anyone else from `eta + AUCTION_DURATION + REBALANCE_DELAY`.
    function AUCTION_DURATION() external view returns (uint256);

    /// @notice The most of any component's own units one rebalance sends out (1e18 = 100%). It counts units, not value.
    ///         So whatever anything is worth, a fill sends out at most this share of each component it takes (V5-M2).
    ///         A growing leg is capped too, at the math's MAX_GROWTH of its own units (RX-15).
    function MAX_TURNOVER() external view returns (uint256);

    /// @notice The factory that deployed this index. Only it can initialize the index, and it says who the owner and
    ///         guardian are.
    function FACTORY() external view returns (address);

    /// @notice The settlement arithmetic (`IWeightedMath`) every fill and preview runs. The factory deployed it with
    ///         this implementation, and it never changes.
    function MATH() external view returns (address);

    /// @notice The contract that values a fill's legs at Pyth's prices (`IPythPrices`), which the factory deployed with
    ///         this implementation; zero when the factory has no oracle, and then no fill is checked against one.
    function PRICES() external view returns (address);

    /// @notice One-time initializer called by the factory in the same transaction as the clone.
    /// @param name_ ERC-20 name, also the EIP-712 domain name for permits.
    /// @param symbol_ ERC-20 symbol.
    /// @param components_ The components, in the order every array of this index uses.
    /// @param config_ The fee rates and the rebalance interval.
    /// @param first_ The creation's own first issue ({FirstIssue}); zero shares for none. It runs every check an
    ///        {issue} runs, the gate, the fee and each component's arrival among them, and reverts the creation with
    ///        it. This is the only time the index pulls a basket from an account other than its caller.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        ComponentInit[] calldata components_,
        Config calldata config_,
        FirstIssue calldata first_
    ) external;

    /// @notice The fee rates and the rebalance interval, fixed at creation.
    function config() external view returns (Config memory);

    /// @notice Mints the streaming fee owed since the last accrual. Every issue, redeem and settlement does this first.
    ///         Anyone may call it. It reads no price.
    function accrueFees() external;

    /// @notice What {accrueFees} would mint now, and the factor (1e18 = one) every component's recorded units would
    ///         then carry. The previews and {components} already include both. Zero shares means an accrual now would
    ///         mint nothing and restart the clock, so that time is never charged later (XS-1).
    function pendingStreamingFee() external view returns (uint256 feeShares, uint256 scale);

    /// @notice When the streaming fee was last accrued, including accruals that owed nothing. {pendingStreamingFee}
    ///         counts from here. On an index without a streaming fee, the creation time.
    function lastAccrual() external view returns (uint256);

    /// @notice Burns `shares` from msg.sender, sends every component whose bit is clear in `skipMask` to `to`,
    ///         and records the skipped amounts as claims that `to` can collect later with {claim}.
    /// @param skipMask Bit i set skips component i. Must be non-zero and use only bits below {componentCount}.
    function redeemSkipping(uint256 shares, address to, uint256 skipMask) external;

    /// @notice Pays msg.sender's whole recorded claim on `token` to `to`. Reverts while `token` still refuses the
    ///         transfer; the claim stays recorded.
    function claim(address token, address to) external returns (uint256 amount);

    /// @notice Pays `amount` of msg.sender's recorded claim on `token` to `to`, and leaves the rest recorded. For a
    ///         claim the index can no longer pay whole, as after the token's issuer burned part of the index's
    ///         balance: what is left can still be collected, first come, first served (CA-S01). Reverts
    ///         NothingToClaim for an `amount` of zero and ClaimTooLarge for one above the claim.
    function claim(address token, address to, uint256 amount) external;

    /// @notice Amount of `token` that `account` can collect with {claim}.
    function claimOf(address account, address token) external view returns (uint256);

    /// @notice Sum of all open claims on `token`. The index's balance covers it on top of the shares' backing, since
    ///         no amount the index computes ever touches it. Only the token's issuer can break that, by taking part
    ///         of the index's balance: an issue is then refused (Underbacked), and redeems and claims are paid from
    ///         what is left, first come, first served, with no part of it set aside for the claims (CA-M3).
    function totalClaims(address token) external view returns (uint256);

    /// @notice Number of components, fixed at initialization.
    function componentCount() external view returns (uint256);

    /// @notice The component tokens, and the raw units of each that back one whole index token (1e18 shares). The
    ///         streaming fee owed up to now is applied, rounded down. An issue of one whole token pulls these for its
    ///         gross shares, the fee's included, rounded up; {previewIssue} gives the exact amounts (RX-42).
    function components() external view returns (address[] memory tokens, uint256[] memory units);

    /// @notice Each component's share of the index's value, in basis points, in component order: as the creator fixed
    ///         it, or as its last change of weights through the factory set it.
    function componentWeights() external view returns (uint256[] memory weights);

    /// @notice Sets the components' weights, in component order, and emits WeightsChanged; the units follow at the next
    ///         rebalance. The factory only (NotFactory otherwise), from {IWeightedIndexFactory-executeWeights}, which
    ///         checked them. Reverts RebalancePending while a rebalance is live, and InvalidComponents on a wrong length.
    function setWeights(uint256[] calldata weights) external;

    /// @notice Number of rebalance proposals ever started, including cancelled and expired ones.
    function proposalCount() external view returns (uint256);

    /// @notice Time of the last executed rebalance, or of creation.
    function lastRebalance() external view returns (uint256);

    /// @notice The earliest time anyone may start the next rebalance: the index's rebalance interval after
    ///         {lastRebalance}, or only MIN_REBALANCE_INTERVAL if that settlement had a keep mask (XS-3). Once a fill
    ///         has settled, the factory owner and guardian may start from MIN_REBALANCE_INTERVAL after it in either
    ///         case, so a fill that traded next to nothing does not hold an index off its weights for its whole
    ///         interval; before an index's first fill they wait as anyone does.
    ///         {canStartRebalance} also checks the waits after a cancel and after an auction nobody filled.
    function earliestRebalance() external view returns (uint256);

    /// @notice After {cancelRebalance}, only the factory owner or guardian can start a rebalance before this time. Read
    ///         {canStartRebalance} rather than this alone.
    function restartAllowedAt() external view returns (uint256);

    /// @notice Starts the notice period. Anyone can call it when all of these hold ({canStartRebalance} checks them):
    ///         - {earliestRebalance} has passed;
    ///         - no unexpired rebalance is pending;
    ///         - the waits after a cancel and after an auction nobody filled are over.
    ///         Before the waits are over, only the factory owner or guardian can start one, and before
    ///         {earliestRebalance} only they can, once a fill has settled and MIN_REBALANCE_INTERVAL has passed
    ///         since it. It calls nothing on any component and reads no price.
    /// @param keepMask Bit i set leaves component i untouched: no fill of this rebalance may change its units, for
    ///        example while its issuer is minting it without limit. Only the factory owner or guardian can pass a
    ///        non-zero mask, and it must leave at least MIN_COMPONENTS components to rebalance. An executor needs no
    ///        mask to leave a component alone: it names that component's current units.
    function startRebalance(uint256 keepMask) external;

    /// @notice Owner or guardian only. Starts a rebalance as {startRebalance} does, under the same clock, and posts a
    ///         quote with it: a fill of this proposal must clear the bar, as any fill, and must also bring in, at
    ///         `prices`, at least `1 − tolerance` of the value it takes out (BelowQuote otherwise).
    ///         - The index still reads no price of its own: these are the caller's, fixed at the start, and they
    ///           only ever refuse a fill the bar would accept. A quote that is wrong, stale or hostile can stop the
    ///           proposal from filling, which a cancel already can; it can make no fill worse than a start without
    ///           one allows. One thing it can do that a cancel cannot: prices that refuse every trade worth making
    ///           still pass a fill that shrinks no leg, and such a fill, however small, settles the proposal and
    ///           restarts the index's whole interval for strangers. The other role may start again
    ///           MIN_REBALANCE_INTERVAL later.
    ///         - What it buys: an executor alone at the auction's last second keeps at most `tolerance` of what it
    ///           trades, where without a quote it keeps the index's whole distance from its weights.
    ///         - The quote belongs to this proposal alone and ends with it.
    /// @param keepMask As in {startRebalance}.
    /// @param prices One per component, in component order: the price of one raw unit of the token, in any one unit
    ///        of account, from 1 to 2^128 − 1 for a component the mask leaves moving (InvalidQuote otherwise). Only
    ///        their ratios matter. A kept component's entry is ignored.
    /// @param tolerance How far under the quoted value a fill may bring in, 1e18 = 100%; under 1e18 (InvalidQuote).
    function startRebalance(uint256 keepMask, uint256[] calldata prices, uint256 tolerance) external;

    /// @notice Factory owner or guardian. Cancels the pending rebalance, whichever it is when the call lands. Anyone
    ///         else must then wait REBALANCE_DELAY before starting a new one. A proposal whose auction has already
    ///         expired is only cleared: the hold-off its expiry set stands, and none starts again (VR-04).
    function cancelRebalance() external;

    /// @notice As {cancelRebalance}, and only if the index's latest proposal is still `proposalId`
    ///         ({proposalCount}, and `RebalanceStarted`'s id): reverts StaleProposal otherwise. A Safe uses this one,
    ///         since its transaction can land hours after its signers read the proposal, when the other role may
    ///         already have replaced it with a start of its own (CA-S02).
    function cancelRebalance(uint256 proposalId) external;

    /// @notice Settles the pending rebalance during its auction, moving every component to the units the caller
    ///         names:
    ///         1. checks `newUnits`: every component inside its unit caps, a kept one unchanged, and the weighted gain
    ///            at or above {currentBar} (`IWeightedMath` has the rule);
    ///         2. sends msg.sender what the index no longer needs of each shrinking component;
    ///         3. calls `IRebalanceExecutor.onXindexRebalance` on msg.sender;
    ///         4. reverts unless the index then holds the new backing of every component that moved, and the whole
    ///            of `amountsIn` on top of what it held before. A component that neither sends nor receives is not
    ///            read at all, so a fill works around one whose `balanceOf` reverts (DA-14), and a settlement says
    ///            nothing of the backing of a leg it left alone (CA-S08).
    ///         Only a contract can execute. It reads no price: the bar falls until some executor finds the trade worth
    ///         making, and the first to clear it settles. Reverts NothingToRebalance on an index with less than one
    ///         whole share.
    /// @dev `amountsOut` and `amountsIn` are computed from `totalSupply()` in the settling block, so the callback's
    ///      arguments are the ones to trust.
    /// @param newUnits The recorded units each component is to have, in component order. Like {previewRebalance}'s
    ///        `currentUnits`, they carry the index's scale. Name a component's current units to leave it alone.
    /// @param data Passed unchanged to the executor's callback.
    function executeRebalance(uint256[] calldata newUnits, bytes calldata data) external;

    /// @notice As {executeRebalance}, but refuses to settle if the index needs more of some component than the caller
    ///         is prepared to deliver (RebalanceMovedOn).
    /// @param maxAmountsIn Most of each component, in component order, the caller will deliver. Must have one entry per
    ///        component (else LengthMismatch); an empty array is the unbounded {executeRebalance}.
    function executeRebalance(uint256[] calldata newUnits, bytes calldata data, uint256[] calldata maxAmountsIn)
        external;

    /// @notice The last started rebalance. `eta` is 0 when none was started, or the last one was executed or
    ///         cancelled. An auction nobody filled keeps its `eta` after `eta + AUCTION_DURATION`.
    function pendingRebalance() external view returns (uint256 eta, uint256 keepMask);

    /// @notice The gain a fill in this block must reach (1e18 = 100%), or 0 outside an auction.
    function currentBar() external view returns (uint256);

    /// @notice The quote posted with the pending rebalance: its prices, one per component (zero for a kept one), and
    ///         its tolerance. Empty and zero when no rebalance is pending or its start posted none.
    function rebalanceQuote() external view returns (uint256[] memory prices, uint256 tolerance);

    /// @notice Whether anyone can start a rebalance now: {earliestRebalance} has passed, no auction is live, and the
    ///         waits after a cancel and after an unfilled auction are over.
    function canStartRebalance() external view returns (bool);

    /// @notice Each component's recorded units, in component order, as a fill's `newUnits` are compared with them.
    ///         Unlike {components}, they do not have the scale applied: units per whole index token are these times
    ///         {pendingStreamingFee}'s scale / 1e18.
    function recordedUnits() external view returns (uint256[] memory units);

    /// @notice The exact settlement an execution in this block would make of `newUnits`. Reverts like
    ///         {executeRebalance}: outside an auction, on an index with less than one whole share, on a component
    ///         outside its caps, on a gain under the bar, and, when the proposal's start posted a quote, on a fill that
    ///         brings in less than it asks (BelowQuote).
    /// @param newUnits The recorded units each component is to have, in component order.
    /// @return bar The gain the auction asks for in this block.
    /// @return gain The weighted gain of `newUnits`.
    /// @return amountsOut What the index would send the executor per component.
    /// @return amountsIn What the index would need back per component, in full.
    function previewRebalance(uint256[] calldata newUnits)
        external
        view
        returns (uint256 bar, int256 gain, uint256[] memory amountsOut, uint256[] memory amountsIn);
}
