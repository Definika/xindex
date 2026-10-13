// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";
import {IXindexErrors} from "./IXindexErrors.sol";
import {IWeightedHub} from "./IWeightedHub.sol";

/// @title IWeightedIndexFactory
/// @notice Creates indexes whose creators choose each component's weight, from a whitelist of tokens the owner lists
///         behind a timelock, each with the Pyth price id its indexes will be rebalanced at.
/// @dev "Owner only" functions revert with OpenZeppelin's `OwnableUnauthorizedAccount` for any other caller, and
///      "owner or guardian" functions with `Unauthorized`. The factory stores price ids and never reads a price.
interface IWeightedIndexFactory is IIndexFactory, IXindexErrors {
    /// @notice One component of an index to create.
    /// @param token A whitelisted token.
    /// @param weight Its share of the index's value, in basis points, non-zero; all of them sum to TOTAL_WEIGHT.
    /// @param units Its raw units per whole index token at creation, within [MIN_RAW_UNITS, MAX_UNITS].
    struct ComponentSpec {
        address token;
        uint256 weight;
        uint256 units;
    }

    /// @notice `creator` created `index` with `components`: each one's token, starting units, weight in basis points,
    ///         and the Pyth price id and decimals it copied from its listing.
    event IndexCreated(
        address indexed index,
        address indexed creator,
        string name,
        string symbol,
        IWeightedHub.ComponentInit[] components
    );
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
    /// @notice `units` for `token` lie outside [MIN_RAW_UNITS, MAX_UNITS].
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

    /// @notice Fewest components an index can hold: one alone is always on its weight.
    function MIN_COMPONENTS() external view returns (uint256);

    /// @notice Most components an index can hold.
    function MAX_COMPONENTS() external view returns (uint256);

    /// @notice What every index's weights sum to: they are in basis points.
    function TOTAL_WEIGHT() external view returns (uint256);

    /// @notice Fewest raw units a component may start with, so no component starts coarse.
    function MIN_RAW_UNITS() external view returns (uint256);

    /// @notice Most raw units a component may start with, leaving rebalances room to grow it within uint96.
    function MAX_UNITS() external view returns (uint256);

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

    /// @notice When `token`'s pending listing becomes executable; zero when none was proposed. Stays set after it
    ///         expires: read {listingPending}.
    function listingEta(address token) external view returns (uint256);

    /// @notice The price id and decimals a pending listing of `token` carries.
    function pendingTerms(address token) external view returns (bytes32 priceId, uint8 decimals);

    /// @notice Whether `token` has a listing that can still be executed or is waiting out its delay.
    function listingPending(address token) external view returns (bool);

    /// @notice Whether a guardian change can still be executed or is waiting out its delay.
    function guardianChangePending() external view returns (bool);

    /// @notice Who created `index`.
    function creatorOf(address index) external view returns (address);

    /// @notice The `i`th index ever created.
    function allIndexes(uint256 i) external view returns (address);

    /// @notice Number of indexes ever created.
    function allIndexesLength() external view returns (uint256);

    /// @notice The address {createIndex} would deploy to for these arguments, from the price ids in force now.
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components
    ) external view returns (address);

    /// @notice Creates an index of `components` and copies each token's price id and decimals into it. Reads no price:
    ///         the app derives the units from the weights at current prices, and the first rebalance brings any index
    ///         to its weights.
    /// @param components Between MIN_COMPONENTS and MAX_COMPONENTS distinct whitelisted tokens, no two sharing a price
    ///        id, with their weights and units.
    function createIndex(string calldata name, string calldata symbol, ComponentSpec[] calldata components)
        external
        returns (address index);

    /// @notice Owner only. Proposes listing `token` with Pyth price id `priceId`; its decimals are read and recorded
    ///         now. Executable by anyone from LISTING_DELAY later, within PROPOSAL_WINDOW. A relisting may carry a new
    ///         price id: it reaches only indexes created afterwards, since every index copies its ids at creation.
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
