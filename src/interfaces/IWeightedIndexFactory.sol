// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";
import {IXindexErrors} from "./IXindexErrors.sol";
import {IWeightedHub} from "./IWeightedHub.sol";
import {IPythPrices} from "./IPythPrices.sol";

/// @title IWeightedIndexFactory
/// @notice Creates indexes whose creators choose each component's weight. Only an account the owner approved creates
///         one ({setApprovedCreator}). Components come from a whitelist that the owner lists behind a timelock.
/// @dev "Owner only" functions revert with OpenZeppelin's `OwnableUnauthorizedAccount` for any other caller.
///      "Owner or guardian" functions revert with `Unauthorized`. No issue, redeem or claim reads a price. A rebalance
///      fill is checked against Pyth's prices through {PRICES}, at the feed each token's {priceFeedOf} names, and
///      that check can only refuse a fill.
interface IWeightedIndexFactory is IIndexFactory, IXindexErrors {
    /// @notice One component of an index to create.
    /// @param token A whitelisted token.
    /// @param weight Its share of the index's value, in basis points, non-zero; all of them sum to TOTAL_WEIGHT.
    /// @param units Its raw units per whole index token at creation, within [MIN_RAW_UNITS, {maxUnitsOf} the token].
    struct ComponentSpec {
        address token;
        uint256 weight;
        uint256 units;
    }

    /// @notice What a creator chooses for an index besides its components.
    /// @param creatorFeeBps The creator's fee on every issue and every redeem, in basis points of the shares, at most
    ///        MAX_CREATOR_FEE_BPS.
    /// @param creatorStreamingBps The creator's streaming fee, in basis points of the index's value per year, at most
    ///        MAX_CREATOR_STREAMING_BPS.
    /// @param maxPlatformFeeBps The highest platform fee the creator accepts. The creation reverts if the current
    ///        policy charges more, so no higher rate can land between the creator's quote and the creation. A policy
    ///        change still moves the address {predictIndexAddress} gave (RZ-28).
    /// @param maxPlatformStreamingBps The highest platform streaming fee the creator accepts, likewise.
    /// @param rebalanceInterval Seconds between rebalances, within [MIN_REBALANCE_INTERVAL, MAX_REBALANCE_INTERVAL].
    /// @param gated Whether only recipients the creator allows ({setAllowedMinter}) may be issued shares, until the
    ///        creator opens the index ({openMinting}).
    /// @param listed Whether the app should show the index. Recorded in the creation event only: it is not part of
    ///        the index or its address.
    struct IndexParams {
        uint16 creatorFeeBps;
        uint16 creatorStreamingBps;
        uint16 maxPlatformFeeBps;
        uint16 maxPlatformStreamingBps;
        uint32 rebalanceInterval;
        bool gated;
        bool listed;
    }

    /// @notice `creator` created `index`.
    ///         - `components`: each one's token, starting units and weight in basis points.
    ///         - `config`: the index's other fixed terms.
    ///         - `listed`: whether the creator wants the app to show it.
    event IndexCreated(
        address indexed index,
        address indexed creator,
        string name,
        string symbol,
        IWeightedHub.ComponentInit[] components,
        IWeightedHub.Config config,
        bool listed
    );
    /// @notice The owner set the fee policy. Every index created from now on copies the platform's fee, its yearly
    ///         streaming fee and the referrer's share of the platform's fee. The recipient of the platform's shares
    ///         and of the creation fees is read by every index, old and new, at each call from now on; the creation
    ///         fee, in wei, is what {createIndex} takes from now on.
    event FeePolicySet(
        uint16 platformFeeBps,
        uint16 platformStreamingBps,
        uint16 referralShareBps,
        address indexed recipient,
        uint256 creationFee
    );
    /// @notice The owner approved `account` to create indexes (`approved`), or withdrew that approval.
    event CreatorApprovalSet(address indexed account, bool approved);
    /// @notice `index`'s creator offered the role to `pendingCreator`, who takes it with {acceptCreator}.
    event CreatorTransferStarted(address indexed index, address indexed creator, address indexed pendingCreator);
    /// @notice `index`'s creator role, and with it its creator's fee shares and allowlist, moved to `newCreator`.
    event CreatorTransferred(address indexed index, address indexed previousCreator, address indexed newCreator);
    /// @notice `account` may (`allowed`) or may no longer be issued shares of the gated `index`.
    event MinterAllowed(address indexed index, address indexed account, bool allowed);
    /// @notice `index`'s creator opened it to every minter, for good.
    event MintingOpened(address indexed index);
    /// @notice `by`, the owner or guardian, paused the issue of new shares of `index`, or of every index when `index`
    ///         is zero.
    event MintingPaused(address indexed index, address indexed by);
    /// @notice The owner lifted the pause on `index`, or the pause on every index when `index` is zero.
    event MintingResumed(address indexed index);
    /// @notice The owner proposed listing `token`, which reports `decimals`, executable from `eta`.
    event ListingProposed(address indexed token, uint256 eta, uint8 decimals);
    /// @notice A pending listing was cancelled.
    event ListingCancelled(address indexed token);
    /// @notice `token` was listed (`allowed`) or delisted.
    event TokenWhitelisted(address indexed token, bool allowed);
    /// @notice `token`'s listing took effect with `decimals`, which bound the units an index may start it with.
    event TokenDecimalsSet(address indexed token, uint8 decimals);
    /// @notice The owner proposed `newGuardian`, executable from `eta`.
    event GuardianProposed(address indexed newGuardian, uint256 eta);
    /// @notice A pending guardian change was cancelled, or replaced by a new proposal.
    event GuardianChangeCancelled(address indexed newGuardian);
    /// @notice The guardian changed.
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    /// @notice A change of `token`'s price feed was proposed, executable from `eta`.
    event PriceFeedProposed(address indexed token, bytes32 id, IPythPrices.FeedKind kind, uint256 eta);
    /// @notice `token`'s pending price feed change was cancelled.
    event PriceFeedCancelled(address indexed token);
    /// @notice `index`'s creator proposed new `weights`, which apply from `eta`.
    event WeightsProposed(address indexed index, uint256[] weights, uint256 eta);
    /// @notice A pending change of `index`'s weights was cancelled: by its creator, the owner or the guardian, or by
    ///         the creator role moving on.
    event WeightsCancelled(address indexed index);
    /// @notice `token`'s price feed is now `id`, valued as `kind`; `None` removes it.
    event PriceFeedSet(address indexed token, bytes32 id, IPythPrices.FeedKind kind);

    /// @notice {createIndex} from `account`, which the owner has not approved to create indexes.
    error CreatorNotApproved(address account);
    /// @notice Name or symbol is empty.
    error EmptyString();
    /// @notice An index needs between MIN_COMPONENTS and MAX_COMPONENTS components.
    error InvalidComponentCount(uint256 count);
    /// @notice `token` is not on the whitelist.
    error TokenNotWhitelisted(address token);
    /// @notice `token` appears twice.
    error DuplicateToken(address token);
    /// @notice `units` for `token` lie outside [MIN_RAW_UNITS, {maxUnitsOf} `token`].
    error UnitsOutOfRange(address token, uint256 units);
    /// @notice A weight is zero or above TOTAL_WEIGHT, or the weights do not sum to TOTAL_WEIGHT.
    error InvalidWeights();
    /// @notice At Pyth's prices `token`'s units are `valueShare` of the index's value, in TOTAL_WEIGHT's units, further
    ///         than MAX_WEIGHT_DEVIATION from its `weight`: the index would start off its weights.
    error OffWeights(address token, uint256 weight, uint256 valueShare);
    /// @notice An index with this address already exists: the same creator, name, symbol and contents.
    error IndexAlreadyExists(address index);
    /// @notice `token` has no code.
    error NotAContract(address token);
    /// @notice `token` reports more than 18 decimals.
    error InvalidDecimals(address token, uint8 decimals);
    /// @notice `token` already has a listing that has not expired, executable from `eta`.
    error ListingPending(address token, uint256 eta);
    /// @notice `token` has no pending listing.
    error NoPendingListing(address token);
    /// @notice `token`'s listing is executable from `eta`.
    error ListingNotReady(address token, uint256 eta);
    /// @notice `token`'s listing expired at `deadline`; propose it again.
    error ListingExpired(address token, uint256 deadline);
    /// @notice `token` is not whitelisted.
    error NotWhitelisted(address token);
    /// @notice `token` is already whitelisted.
    error AlreadyListed(address token);
    /// @notice No guardian change is pending.
    error NoPendingGuardianChange();
    /// @notice The guardian change is executable from `eta`.
    error GuardianChangeNotReady(uint256 eta);
    /// @notice The guardian change expired at `deadline`; propose it again.
    error GuardianChangeExpired(uint256 deadline);
    /// @notice Ownership cannot be renounced.
    error RenounceDisabled();
    /// @notice `creatorFeeBps` is above MAX_CREATOR_FEE_BPS.
    error CreatorFeeTooHigh(uint256 creatorFeeBps);
    /// @notice `creatorStreamingBps` is above MAX_CREATOR_STREAMING_BPS.
    error StreamingFeeTooHigh(uint256 creatorStreamingBps);
    /// @notice The policy's streaming fee, `platformStreamingBps`, is above the `maxPlatformStreamingBps` the creator
    ///         accepts.
    error PlatformStreamingFeeTooHigh(uint256 platformStreamingBps, uint256 maxPlatformStreamingBps);
    /// @notice `rebalanceInterval` lies outside [MIN_REBALANCE_INTERVAL, MAX_REBALANCE_INTERVAL].
    error IntervalOutOfRange(uint256 rebalanceInterval);
    /// @notice The policy's platform fee, `platformFeeBps`, is above the `maxPlatformFeeBps` the creator accepts.
    error PlatformFeeTooHigh(uint256 platformFeeBps, uint256 maxPlatformFeeBps);
    /// @notice {createIndex} was sent `sent` wei; the creation fee is `required`. A recipient that refuses the fee
    ///         fails the creation with OpenZeppelin's `FailedCall`.
    error WrongCreationFee(uint256 sent, uint256 required);
    /// @notice The policy has a platform fee above MAX_PLATFORM_FEE_BPS, a platform streaming fee above
    ///         MAX_PLATFORM_STREAMING_BPS, a referral share above 10,000 basis points, or a recipient that cannot hold
    ///         shares: zero, the factory, or one of its indexes.
    error InvalidFeePolicy();
    /// @notice {openMinting} on `index`, which is not gated.
    error NotGated(address index);
    /// @notice The factory was deployed without an oracle, so it has no price feeds to set.
    error NoOracle();
    /// @notice A feed of a kind other than `None` names no id, or one of kind `None` names an id.
    error InvalidPriceFeed(bytes32 id);
    /// @notice A price feed change for `token` is already pending, executable from `eta`.
    error PriceFeedPending(address token, uint256 eta);
    /// @notice No price feed change is pending for `token`.
    error NoPendingPriceFeed(address token);
    /// @notice `index` has no pending change of weights.
    error NoPendingWeights(address index);
    /// @notice `index`'s pending weights apply from `eta`.
    error WeightsNotReady(address index, uint256 eta);
    /// @notice `index`'s pending weights could apply until `deadline`, which has passed.
    error WeightsExpired(address index, uint256 deadline);
    /// @notice `token`'s price feed change is executable only from `eta`.
    error PriceFeedNotReady(address token, uint256 eta);
    /// @notice `token`'s price feed change expired at `deadline`, unexecuted.
    error PriceFeedExpired(address token, uint256 deadline);

    /// @notice Fewest components an index can hold: one alone is always on its weight.
    function MIN_COMPONENTS() external view returns (uint256);

    /// @notice Most components an index can hold.
    function MAX_COMPONENTS() external view returns (uint256);

    /// @notice How far, relative to its weight (1e18 = 100%), a component's share of a new index's value at Pyth's
    ///         prices may lie from that weight, on a factory with an oracle: 5%. A creator who could name units far
    ///         from the weights could drain the index through its own rebalance auctions; within 5% of each weight the
    ///         index starts about a thousandth of its value or less from its weights.
    function MAX_WEIGHT_DEVIATION() external view returns (uint256);

    /// @notice What every index's weights sum to: they are in basis points.
    function TOTAL_WEIGHT() external view returns (uint256);

    /// @notice Fewest raw units a component may start with, so no component starts coarse.
    function MIN_RAW_UNITS() external view returns (uint256);

    /// @notice Most raw units any component may start with, leaving rebalances room to grow it within uint96.
    function MAX_UNITS() external view returns (uint256);

    /// @notice Most whole tokens of a component one index token may start with. With it, one wei-share backs a
    ///         negligible amount of every component, so no fee's rounding is worth anything (RX-5).
    function MAX_WHOLE_TOKENS() external view returns (uint256);

    /// @notice Most a creator can charge on an issue or a redeem, in basis points of the shares. The hub checks only
    ///         that the two rates sum to at most 125.
    function MAX_CREATOR_FEE_BPS() external view returns (uint256);

    /// @notice Most the platform's policy can charge on an issue or a redeem, in basis points. The hub checks only
    ///         the sum, as above.
    function MAX_PLATFORM_FEE_BPS() external view returns (uint256);

    /// @notice Most a creator can charge as a streaming fee, in basis points of the index's value per year.
    function MAX_CREATOR_STREAMING_BPS() external view returns (uint256);

    /// @notice Most the platform's policy can charge as a streaming fee, in basis points per year.
    function MAX_PLATFORM_STREAMING_BPS() external view returns (uint256);

    /// @notice Shortest rebalance interval an index can be created with; the hub holds the same.
    function MIN_REBALANCE_INTERVAL() external view returns (uint256);

    /// @notice Longest rebalance interval an index can be created with. Only the factory checks it.
    function MAX_REBALANCE_INTERVAL() external view returns (uint256);

    /// @notice Delay before a listing can be executed.
    function LISTING_DELAY() external view returns (uint256);

    /// @notice Delay before a guardian change can be executed.
    function GUARDIAN_DELAY() external view returns (uint256);

    /// @notice How long a proposal stays executable after its delay.
    function PROPOSAL_WINDOW() external view returns (uint256);

    /// @notice The `WeightedHub` every index is a clone of.
    function IMPLEMENTATION() external view returns (address);

    /// @notice The guardian: cancels listings, rebalances and its own removal, delists, and starts rebalances early or
    ///         with a keep mask. Zero when there is none.
    function guardian() external view returns (address);

    /// @notice The proposed guardian; zero when no change was proposed. Stays set after the proposal expires: read
    ///         {guardianChangePending}.
    function pendingGuardian() external view returns (address);

    /// @notice When the proposed guardian change becomes executable; zero when none was proposed. Stays set after it
    ///         expires: read {guardianChangePending}.
    function pendingGuardianEta() external view returns (uint256);

    /// @notice Whether `account` is the owner or a non-zero guardian.
    function isOwnerOrGuardian(address account) external view returns (bool);

    /// @notice Whether `token` can go in a new index.
    function isWhitelisted(address token) external view returns (bool);

    /// @notice Every whitelisted token, in no particular order.
    function whitelistedTokens() external view returns (address[] memory);

    /// @notice `token`'s decimals as read when its listing was proposed; zero for a token never listed. Delisting
    ///         keeps them. They only bound the units an index may start with ({maxUnitsOf}).
    function decimalsOf(address token) external view returns (uint8);

    /// @notice Most raw units of `token` an index may start with: MAX_WHOLE_TOKENS whole tokens at its listed decimals,
    ///         capped at MAX_UNITS.
    function maxUnitsOf(address token) external view returns (uint256);

    /// @notice When `token`'s pending listing becomes executable; zero when none was proposed. Stays set after it
    ///         expires: read {listingPending}.
    function listingEta(address token) external view returns (uint256);

    /// @notice Whether `token` has a listing that can still be executed or is waiting out its delay.
    function listingPending(address token) external view returns (bool);

    /// @notice Whether a guardian change can still be executed or is waiting out its delay.
    function guardianChangePending() external view returns (bool);

    /// @notice Whether `account` may create an index. Only {createIndex} reads it: an index keeps running, and its
    ///         creator role can be handed to any account ({transferCreator}), whatever this says.
    function isApprovedCreator(address account) external view returns (bool);

    /// @notice `index`'s creator: who created it, or whoever accepted the role since ({acceptCreator}). The
    ///         creator receives the creator's fee shares and keeps a gated index's allowlist. It has no power over the
    ///         index's components.
    function creatorOf(address index) external view returns (address);

    /// @notice Whether `index` issues shares only to its creator and the accounts its creator allows. The fee's shares
    ///         still go to the creator and the platform recipient, and to a referrer only if it is one of those
    ///         accounts.
    function isGated(address index) external view returns (bool);

    /// @notice Whether `account` may be issued shares of `index` while it is gated. The creator needs no entry.
    function isAllowedMinter(address index, address account) external view returns (bool);

    /// @notice What `index` reads at each issue and redeem: whether `to` may receive new shares, its creator, and the
    ///         platform recipient. `allowed` is false while minting is paused, on `index` or on every index
    ///         ({mintingPaused}); otherwise it is true when the index is not gated or `to` is its creator, who could
    ///         allow itself anyway, or an account its creator allowed. Only an issue reads `allowed`: a redeem, a
    ///         claim, a fee accrual and a rebalance take the two recipients and nothing else.
    function feeTerms(address index, address to) external view returns (bool allowed, address creator, address platform);

    /// @notice Whether the issue of new shares is paused: of `index`, or, asked of the zero address, of every index.
    ///         An index issues only while neither is. Nothing else reads it: holders redeem, skip a frozen
    ///         component, collect claims and transfer as before, and rebalances go on.
    function mintingPaused(address index) external view returns (bool);

    /// @notice Owner or guardian. Stops the issue of new shares of `index`, a factory index (NotIndex otherwise), or
    ///         of every index of this factory when `index` is zero, at once: the brake for an index, or a build,
    ///         found to have a fault, so that no new deposit enters it. It stops nothing else and moves nothing: no
    ///         redeem, claim, transfer or rebalance reads it. While it holds, an issue reverts `NotAllowedMinter`,
    ///         a creation with a first issue with it.
    function pauseMinting(address index) external;

    /// @notice Owner only. Lifts the pause on `index`, or the pause on every index when `index` is zero; each is
    ///         lifted on its own. The guardian can pause and cannot resume, so a pause the owner set stays until the
    ///         owner lifts it.
    function resumeMinting(address index) external;

    /// @notice The platform's fee an index created now copies, in basis points of the shares on every issue and
    ///         redeem.
    function platformFeeBps() external view returns (uint16);

    /// @notice The platform's streaming fee an index created now copies, in basis points per year.
    function platformStreamingBps() external view returns (uint16);

    /// @notice The referrer's share of the platform's fee an index created now copies, in basis points.
    function referralShareBps() external view returns (uint16);

    /// @notice Where every index mints the platform's fee shares (read at each issue and redeem), and where creation
    ///         fees go. Zero until the owner sets a policy; until then an index mints the platform's part to its
    ///         creator.
    function platformFeeRecipient() external view returns (address);

    /// @notice `index`'s creator only. Offers the creator role to `newCreator`, who takes it with {acceptCreator};
    ///         until then the creator keeps it, and a later offer replaces this one. `newCreator` cannot be zero
    ///         (ZeroAddress), the factory or an index (InvalidRecipient), since those could not hold the shares.
    ///         Reverts NotIndex for an address the factory did not deploy.
    function transferCreator(address index, address newCreator) external;

    /// @notice The account `index`'s creator offered the role to, which only it can accept; zero if none.
    function pendingCreatorOf(address index) external view returns (address);

    /// @notice The pending creator of `index` only (Unauthorized otherwise). Takes the creator role, so `creatorOf`
    ///         never names an account that did not agree to it (RX-22). The index's streaming fee is accrued first,
    ///         so what was earned up to the handover goes to the outgoing creator. A change of weights the outgoing
    ///         creator proposed is cancelled with it (WeightsCancelled): the new creator proposes its own (HK-16).
    ///         Reverts if called from inside one of the index's own calls, such as a rebalance callback.
    function acceptCreator(address index) external;

    /// @notice `index`'s creator only. Lets `account` be issued shares of `index` (`allowed`), or no longer. Only a
    ///         gated index reads it.
    function setAllowedMinter(address index, address account, bool allowed) external;

    /// @notice `index`'s creator only. Opens a gated index to every minter, for good (NotGated otherwise).
    function openMinting(address index) external;

    /// @notice What {createIndex} must be sent, in wei.
    function creationFee() external view returns (uint256);

    /// @notice The `i`th index ever created.
    function allIndexes(uint256 i) external view returns (address);

    /// @notice Number of indexes ever created.
    function allIndexesLength() external view returns (uint256);

    /// @notice The address {createIndex} would deploy to for these arguments, with the current fee policy. Reverts as
    ///         {createIndex} would on `params`. It does not check that `creator` is approved.
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components,
        IndexParams calldata params
    ) external view returns (address);

    /// @notice Creates an index of `components`, with the caller as its creator.
    ///         - Only an approved creator (CreatorNotApproved otherwise).
    ///         - Takes the fee rates from `params` and the current policy.
    ///         - `msg.value` must equal the policy's creation fee; it is forwarded to the platform recipient.
    ///         - On a factory with an oracle, each component's units must lie within MAX_WEIGHT_DEVIATION of its
    ///           weight at Pyth's prices (OffWeights otherwise), so the caller posts Pyth's update first.
    ///         The index is created with no shares. An index narrow enough for one transaction is created with its
    ///         first issue instead, by {createAndIssue}.
    /// @param components Between MIN_COMPONENTS and MAX_COMPONENTS distinct whitelisted tokens, with their weights and
    ///        units.
    /// @param params The creator's fee, the platform fee it accepts, the rebalance interval, and the gate and listing
    ///        flags.
    function createIndex(
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components,
        IndexParams calldata params
    ) external payable returns (address index);

    /// @notice Creates an index as {createIndex} does and, in the same call, issues its first `shares` to `to`:
    ///         creating the index is buying it. The basket is pulled from the caller by the new index itself, as
    ///         `issue` pulls it, so the caller approves every component to the address {predictIndexAddress} gives
    ///         before calling. It is an issue as any other: the index's fee is charged, a gated index issues only to
    ///         its creator, and a component that arrives short or could not leave again reverts the whole creation,
    ///         so no index is left behind that its own creator could not back.
    ///         Creating and issuing together cost about what the two calls cost apart, so the widest indexes do not
    ///         fit one transaction: those are created with {createIndex} and issued afterwards.
    /// @param shares Shares `to` receives, non-zero (`ZeroShares` otherwise); 1e18 is one whole index token.
    /// @param to Receives the shares.
    function createAndIssue(
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components,
        IndexParams calldata params,
        uint256 shares,
        address to
    ) external payable returns (address index);

    /// @notice Owner only. Lets `account` create indexes (`approved`), or no longer. It takes effect at once and
    ///         reaches no index that exists: an approved creator can do nothing a listing and the fee caps do not
    ///         already bound, and has no power over any index's funds.
    function setApprovedCreator(address account, bool approved) external;

    /// @notice Owner only. Sets the fee policy that indexes created from now on copy, and the recipient every index
    ///         reads at each issue and redeem. It does not change any existing index's rates. The recipient cannot be
    ///         zero, the factory or an index (InvalidFeePolicy), since none could hold the shares.
    /// @param platformFeeBps_ The platform's fee on every issue and redeem, at most MAX_PLATFORM_FEE_BPS.
    /// @param platformStreamingBps_ The platform's streaming fee per year, at most MAX_PLATFORM_STREAMING_BPS.
    /// @param referralShareBps_ The referrer's share of the platform's fee, at most 10,000 basis points. A minter may
    ///        name itself as the referrer, so size it as a rebate every minter can take.
    /// @param recipient Receives the platform's fee shares and the creation fees. It takes the platform's part from
    ///        the next call on: what an index has not accrued yet of the streaming fee goes to the new recipient.
    /// @param creationFee_ What {createIndex} must be sent from now on, in wei.
    function setFeePolicy(
        uint16 platformFeeBps_,
        uint16 platformStreamingBps_,
        uint16 referralShareBps_,
        address recipient,
        uint256 creationFee_
    ) external;

    /// @notice Owner only. Proposes listing `token`. Its decimals are read and recorded now. Anyone can execute it
    ///         from LISTING_DELAY later, within PROPOSAL_WINDOW. A listing reaches only indexes created afterwards.
    function proposeListing(address token) external;

    /// @notice Owner or guardian. Cancels `token`'s pending listing.
    function cancelListing(address token) external;

    /// @notice Anyone. Executes `token`'s listing once its delay has passed and before it expires.
    function executeListing(address token) external;

    /// @notice Owner or guardian. Removes `token` from the whitelist; existing indexes keep it.
    function delist(address token) external;

    /// @notice The contract that values a rebalance fill at Pyth's prices (`IPythPrices`), which this factory deployed
    ///         with its implementation; zero for a factory without an oracle. Every index of this factory reads it.
    function PRICES() external view returns (address);

    /// @notice `token`'s price feed: Pyth's id and how it values the token. `None` when it has none, and a fill that
    ///         moves the token then reverts. It reaches every index of this factory from the moment it is set: a feed
    ///         can only make a fill refused or let one through that the units already accept, so it holds no power
    ///         over funds.
    function priceFeedOf(address token) external view returns (IPythPrices.PriceFeed memory);

    // ---------------------------------------------------------------------
    // Changing an index's weights (the owner's calls of 2026-11-23, `design/2026-11-23-changeable-weights.md`)
    // ---------------------------------------------------------------------

    /// @notice How long a proposed change of weights waits before anyone may apply it: 7 days, in which holders who
    ///         disagree leave at full value.
    function WEIGHTS_DELAY() external view returns (uint256);

    /// @notice When `index`'s pending weights apply; zero when none is pending.
    function weightsEta(address index) external view returns (uint256);

    /// @notice `index`'s pending weights and when they apply; both empty when none is pending.
    function pendingWeights(address index) external view returns (uint256[] memory weights, uint256 eta);

    /// @notice `index`'s creator only, on a factory with an oracle. Proposes new `weights` for `index`'s components,
    ///         in component order: each at least one basis point, all summing to TOTAL_WEIGHT, as at creation. Its
    ///         coins never change. Replaces a pending proposal and restarts the delay. Applies from `block.timestamp`
    ///         plus WEIGHTS_DELAY, by anyone, within PROPOSAL_WINDOW after that. Reverts NotIndex, Unauthorized,
    ///         NoOracle or InvalidWeights.
    function proposeWeights(address index, uint256[] calldata weights) external;

    /// @notice `index`'s creator, the owner or the guardian. Cancels `index`'s pending weights. Reverts Unauthorized
    ///         or NoPendingWeights.
    function cancelWeights(address index) external;

    /// @notice Anyone. Applies `index`'s pending weights once WEIGHTS_DELAY has passed and before PROPOSAL_WINDOW ends
    ///         after it; the index's units follow at its next rebalance. Reverts NoPendingWeights, WeightsNotReady,
    ///         WeightsExpired, or the hub's RebalancePending while a rebalance is live.
    function executeWeights(address index) external;

    /// @notice `token`'s pending price feed change and when it becomes executable; `eta` zero when none was proposed.
    ///         An expired one keeps its `eta`: it is executable only within PROPOSAL_WINDOW of it.
    function pendingPriceFeed(address token) external view returns (IPythPrices.PriceFeed memory feed, uint256 eta);

    /// @notice Owner only. Proposes `feed` as `token`'s price feed, or kind `None` to remove it. The id is not checked
    ///         against Pyth's contract, which knows a feed only once an update of it was posted on this chain; a wrong
    ///         id can only stop a creation or a fill that needs it. Anyone can execute it from LISTING_DELAY later, within PROPOSAL_WINDOW. Reverts
    ///         `NoOracle` on a factory without one.
    function proposePriceFeed(address token, IPythPrices.PriceFeed calldata feed) external;

    /// @notice Owner or guardian. Cancels `token`'s pending price feed change.
    function cancelPriceFeed(address token) external;

    /// @notice Anyone. Executes `token`'s price feed change once its delay has passed and before it expires.
    function executePriceFeed(address token) external;

    /// @notice Owner only. Proposes `newGuardian` (zero removes the role), executable after GUARDIAN_DELAY.
    function proposeGuardian(address newGuardian) external;

    /// @notice The owner cancels any guardian change; the guardian only its own removal.
    function cancelGuardianChange() external;

    /// @notice Anyone. Executes the pending guardian change once its delay has passed and before it expires.
    function executeGuardianChange() external;
}
