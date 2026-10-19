// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";
import {IXindexErrors} from "./IXindexErrors.sol";
import {IWeightedHub} from "./IWeightedHub.sol";

/// @title IWeightedIndexFactory
/// @notice Creates indexes whose creators choose each component's weight. Components come from a whitelist that the
///         owner lists behind a timelock. Each listed token carries the Pyth price id its indexes rebalance at.
/// @dev "Owner only" functions revert with OpenZeppelin's `OwnableUnauthorizedAccount` for any other caller.
///      "Owner or guardian" functions revert with `Unauthorized`. The factory stores price ids and never reads a price.
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
    ///        policy charges more, so a policy change cannot land between the creator's quote and the creation.
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
    ///         - `components`: each one's token, starting units, weight in basis points, and the Pyth price id and
    ///           decimals copied from its listing.
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
    /// @notice The owner set the fee policy that every index created from now on copies: the platform's fee, its
    ///         yearly streaming fee, the referrer's share of the platform's fee, the recipient of the platform's shares
    ///         and creation fees, and the creation fee in wei.
    event FeePolicySet(
        uint16 platformFeeBps,
        uint16 platformStreamingBps,
        uint16 referralShareBps,
        address indexed recipient,
        uint256 creationFee
    );
    /// @notice `index`'s creator offered the role to `pendingCreator`, who takes it with {acceptCreator}.
    event CreatorTransferStarted(address indexed index, address indexed creator, address indexed pendingCreator);
    /// @notice `index`'s creator role, and with it its creator's fee shares and allowlist, moved to `newCreator`.
    event CreatorTransferred(address indexed index, address indexed previousCreator, address indexed newCreator);
    /// @notice `account` may (`allowed`) or may no longer be issued shares of the gated `index`.
    event MinterAllowed(address indexed index, address indexed account, bool allowed);
    /// @notice `index`'s creator opened it to every minter, for good.
    event MintingOpened(address indexed index);
    /// @notice The owner proposed listing `token` with Pyth price id `priceId` and `decimals`, executable from `eta`.
    event ListingProposed(address indexed token, uint256 eta, bytes32 priceId, uint8 decimals);
    /// @notice A pending listing was cancelled.
    event ListingCancelled(address indexed token);
    /// @notice `token` was listed (`allowed`) or delisted.
    event TokenWhitelisted(address indexed token, bool allowed);
    /// @notice `token` now carries `priceId` and `decimals` for every index created from here on.
    event TokenTermsSet(address indexed token, bytes32 priceId, uint8 decimals);
    /// @notice The owner proposed `newGuardian`, executable from `eta`.
    event GuardianProposed(address indexed newGuardian, uint256 eta);
    /// @notice A pending guardian change was cancelled, or replaced by a new proposal.
    event GuardianChangeCancelled(address indexed newGuardian);
    /// @notice The guardian changed.
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);

    /// @notice Name or symbol is empty.
    error EmptyString();
    /// @notice An index needs between MIN_COMPONENTS and MAX_COMPONENTS components.
    error InvalidComponentCount(uint256 count);
    /// @notice `token` is not on the whitelist.
    error TokenNotWhitelisted(address token);
    /// @notice `token` appears twice.
    error DuplicateToken(address token);
    /// @notice `token` carries the same Pyth price id as an earlier component. Pyth fills only the first of two equal
    ///         ids, so such an index could never settle a rebalance (V5-M1).
    error DuplicatePriceId(address token);
    /// @notice `units` for `token` lie outside [MIN_RAW_UNITS, {maxUnitsOf} `token`].
    error UnitsOutOfRange(address token, uint256 units);
    /// @notice A weight is zero or above TOTAL_WEIGHT, or the weights do not sum to TOTAL_WEIGHT.
    error InvalidWeights();
    /// @notice An index with this address already exists: the same creator, name, symbol and contents.
    error IndexAlreadyExists(address index);
    /// @notice `token` has no code.
    error NotAContract(address token);
    /// @notice The price id is zero.
    error InvalidPriceId(address token);
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

    /// @notice Fewest components an index can hold: one alone is always on its weight.
    function MIN_COMPONENTS() external view returns (uint256);

    /// @notice Most components an index can hold.
    function MAX_COMPONENTS() external view returns (uint256);

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

    /// @notice The Pyth contract every index reads its prices from.
    function PYTH() external view returns (address);

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

    /// @notice `token`'s Pyth price id, which a new index copies; zero for a token never listed. Delisting keeps it.
    function priceIdOf(address token) external view returns (bytes32);

    /// @notice `token`'s decimals as read when its listing was proposed, which a new index copies.
    function decimalsOf(address token) external view returns (uint8);

    /// @notice Most raw units of `token` an index may start with: MAX_WHOLE_TOKENS whole tokens at its listed decimals,
    ///         capped at MAX_UNITS.
    function maxUnitsOf(address token) external view returns (uint256);

    /// @notice When `token`'s pending listing becomes executable; zero when none was proposed. Stays set after it
    ///         expires: read {listingPending}.
    function listingEta(address token) external view returns (uint256);

    /// @notice The price id and decimals a pending listing of `token` carries.
    function pendingTerms(address token) external view returns (bytes32 priceId, uint8 decimals);

    /// @notice Whether `token` has a listing that can still be executed or is waiting out its delay.
    function listingPending(address token) external view returns (bool);

    /// @notice Whether a guardian change can still be executed or is waiting out its delay.
    function guardianChangePending() external view returns (bool);

    /// @notice `index`'s creator: who created it, or whoever accepted the role since ({acceptCreator}). The
    ///         creator receives the creator's fee shares and keeps a gated index's allowlist. It has no power over the
    ///         index's components.
    function creatorOf(address index) external view returns (address);

    /// @notice Whether `index` issues shares only to accounts its creator allows.
    function isGated(address index) external view returns (bool);

    /// @notice Whether `account` may be issued shares of `index` while it is gated.
    function isAllowedMinter(address index, address account) external view returns (bool);

    /// @notice What `index` reads at each issue and redeem: whether `to` may receive new shares (always true when the
    ///         index is not gated), its creator, and the platform recipient.
    function feeTerms(address index, address to) external view returns (bool allowed, address creator, address platform);

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
    ///         never names an account that did not agree to it (RX-22).
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

    /// @notice The address {createIndex} would deploy to for these arguments, with the current price ids and fee
    ///         policy. Reverts as {createIndex} would on `params`.
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components,
        IndexParams calldata params
    ) external view returns (address);

    /// @notice Creates an index of `components`, with the caller as its creator.
    ///         - Copies each token's current price id and decimals into the index.
    ///         - Takes the fee rates from `params` and the current policy.
    ///         - `msg.value` must equal the policy's creation fee; it is forwarded to the platform recipient.
    ///         Reads no price. The app derives the units from the weights at current prices, and the first rebalance
    ///         brings any index to its weights.
    /// @param components Between MIN_COMPONENTS and MAX_COMPONENTS distinct whitelisted tokens, no two sharing a price
    ///        id, with their weights and units.
    /// @param params The creator's fee, the platform fee it accepts, the rebalance interval, and the gate and listing
    ///        flags.
    function createIndex(
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components,
        IndexParams calldata params
    ) external payable returns (address index);

    /// @notice Owner only. Sets the fee policy that indexes created from now on copy, and the recipient every index
    ///         reads at each issue and redeem. It does not change any existing index's rates. The recipient cannot be
    ///         zero, the factory or an index (InvalidFeePolicy), since none could hold the shares.
    /// @param platformFeeBps_ The platform's fee on every issue and redeem, at most MAX_PLATFORM_FEE_BPS.
    /// @param platformStreamingBps_ The platform's streaming fee per year, at most MAX_PLATFORM_STREAMING_BPS.
    /// @param referralShareBps_ The referrer's share of the platform's fee, at most 10,000 basis points.
    /// @param recipient Receives the platform's fee shares and the creation fees.
    /// @param creationFee_ What {createIndex} must be sent from now on, in wei.
    function setFeePolicy(
        uint16 platformFeeBps_,
        uint16 platformStreamingBps_,
        uint16 referralShareBps_,
        address recipient,
        uint256 creationFee_
    ) external;

    /// @notice Owner only. Proposes listing `token` with Pyth price id `priceId`. Its decimals are read and recorded
    ///         now. Anyone can execute it from LISTING_DELAY later, within PROPOSAL_WINDOW. A relisting may carry a new
    ///         price id. It reaches only indexes created afterwards, since every index copies its ids at creation.
    function proposeListing(address token, bytes32 priceId) external;

    /// @notice Owner or guardian. Cancels `token`'s pending listing.
    function cancelListing(address token) external;

    /// @notice Anyone. Executes `token`'s listing once its delay has passed and before it expires.
    function executeListing(address token) external;

    /// @notice Owner or guardian. Removes `token` from the whitelist; existing indexes keep it.
    function delist(address token) external;

    /// @notice Owner only. Proposes `newGuardian` (zero removes the role), executable after GUARDIAN_DELAY.
    function proposeGuardian(address newGuardian) external;

    /// @notice The owner cancels any guardian change; the guardian only its own removal.
    function cancelGuardianChange() external;

    /// @notice Anyone. Executes the pending guardian change once its delay has passed and before it expires.
    function executeGuardianChange() external;
}
