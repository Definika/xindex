// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IXindexErrors} from "./IXindexErrors.sol";

/// @title IIndexFactory
/// @notice Deploys index hubs as EIP-1167 clones at creator-bound CREATE2 addresses, curates the component whitelist
///         and each token's reference supply behind public delays, and keeps the registry. Nothing here reads a price.
/// @dev "Owner only" functions revert with OpenZeppelin's `OwnableUnauthorizedAccount` for any other caller, and
///      "owner or guardian" functions with `Unauthorized`.
interface IIndexFactory is IXindexErrors {
    /// @notice `creator` deployed and initialized `index` with these constituents and starting units (raw units of each
    ///         token per 1e18 shares, in the same order), computed as `k * referenceSupply / K_SCALE`.
    event IndexCreated(
        address indexed index, address indexed creator, string name, string symbol, address[] tokens, uint256[] units
    );
    /// @notice Listing `token` with `referenceSupply` was proposed. It can be executed from `eta` until
    ///         `eta + PROPOSAL_WINDOW`.
    event ListingProposed(address indexed token, uint256 eta, uint256 referenceSupply);
    /// @notice The pending listing of `token` was cancelled, or dropped because {delist} removed the token.
    event ListingCancelled(address indexed token);
    /// @notice `token`'s reference supply changed from `previous` (zero before a first listing) to `referenceSupply`.
    event ReferenceSupplySet(address indexed token, uint256 previous, uint256 referenceSupply);
    /// @notice `token` was whitelisted (`allowed`) or delisted.
    event TokenWhitelisted(address indexed token, bool allowed);
    /// @notice Supply batch `batchId` was proposed. It can be executed from `eta` until `eta + PROPOSAL_WINDOW`.
    event SuppliesProposed(uint256 indexed batchId, uint256 eta, address[] tokens, uint256[] referenceSupplies);
    /// @notice Supply batch `batchId` was cancelled.
    event SuppliesCancelled(uint256 indexed batchId);
    /// @notice Supply batch `batchId` came into force; a `ReferenceSupplySet` precedes this for each of its tokens.
    event SuppliesExecuted(uint256 indexed batchId);
    /// @notice A change to `newGuardian` was proposed. It can be executed from `eta` until `eta + PROPOSAL_WINDOW`.
    event GuardianProposed(address indexed newGuardian, uint256 eta);
    /// @notice The pending change to `newGuardian` was cancelled, or replaced by a new proposal.
    event GuardianChangeCancelled(address indexed newGuardian);
    /// @notice The guardian changed, at deployment or when a proposed change was executed. Zero means no guardian.
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);

    /// @notice The index name or symbol is empty.
    error EmptyString();
    /// @notice An index needs 1 to MAX_COMPONENTS components; `count` were given.
    error InvalidComponentCount(uint256 count);
    /// @notice `token` is not whitelisted, so no new index can hold it.
    error TokenNotWhitelisted(address token);
    /// @notice `token` appears twice in the components.
    error DuplicateToken(address token);
    /// @notice `k` gives `token` `units` raw units per whole index token, outside [MIN_RAW_UNITS, MAX_UNITS].
    error UnitsOutOfRange(address token, uint256 units);
    /// @notice The same creator already deployed an index with these exact arguments, at `index`.
    error IndexAlreadyExists(address index);
    /// @notice `token` has no code.
    error NotAContract(address token);
    /// @notice `token` has never been listed, so it has no reference supply to revise.
    error NotConfigured(address token);
    /// @notice A reference supply of `referenceSupply` for `token` is zero or above MAX_SUPPLY.
    error SupplyOutOfRange(address token, uint256 referenceSupply);
    /// @notice A proposed reference supply for `token` moves more than MAX_SUPPLY_STEP from the one in force. A larger
    ///         change goes in steps, each behind its own delay and the guardian's veto.
    error SupplyStepTooLarge(address token, uint256 inForce, uint256 proposed);
    /// @notice A listing of `token` executable from `eta` is still pending or executable. Cancel it first; one that
    ///         expired can be replaced.
    error ListingPending(address token, uint256 eta);
    /// @notice No listing is proposed for `token`.
    error NoPendingListing(address token);
    /// @notice The listing of `token` can be executed from `eta`.
    error ListingNotReady(address token, uint256 eta);
    /// @notice The listing of `token` could be executed until `deadline`; propose it again.
    error ListingExpired(address token, uint256 deadline);
    /// @notice {delist} for a token that is not whitelisted.
    error NotWhitelisted(address token);
    /// @notice {proposeListing} for a token that is whitelisted: its reference supply changes only through a supply
    ///         batch, so no revision can land outside one.
    error AlreadyListed(address token);
    /// @notice A supply batch executable from `eta` is still pending or executable. Cancel it first; one that expired
    ///         can be replaced.
    error SuppliesPending(uint256 eta);
    /// @notice `token` is in the live supply batch, so its listing waits for that batch to execute, be cancelled or
    ///         expire: nothing but the batch may change a supply the batch was checked against.
    error TokenInBatch(address token);
    /// @notice A supply batch must name 1 to MAX_BATCH tokens in strictly ascending address order; this one breaks that
    ///         at `token`, or is empty or too long (`token` zero).
    error InvalidBatch(address token);
    /// @notice No supply batch is proposed.
    error NoPendingSupplies();
    /// @notice The supply batch can be executed from `eta`.
    error SuppliesNotReady(uint256 eta);
    /// @notice The supply batch could be executed until `deadline`; propose it again.
    error SuppliesExpired(uint256 deadline);
    /// @notice No guardian change is pending.
    error NoPendingGuardianChange();
    /// @notice The pending guardian change can be executed from `eta`.
    error GuardianChangeNotReady(uint256 eta);
    /// @notice The pending guardian change could be executed until `deadline`; propose it again.
    error GuardianChangeExpired(uint256 deadline);
    /// @notice Ownership cannot be renounced: without an owner, listings and reference supplies could never change.
    error RenounceDisabled();

    /// @notice Most components an index can have.
    function MAX_COMPONENTS() external view returns (uint256);

    /// @notice Most tokens one supply batch can name.
    function MAX_BATCH() external view returns (uint256);

    /// @notice Largest move of a token's reference supply one relisting or batch can make, either way (1e18 = 100%),
    ///         after its first listing. The hub clamps each rebalance to the same step, however many batches landed
    ///         between two rebalances, so neither bound alone is the one holders rely on.
    function MAX_SUPPLY_STEP() external view returns (uint256);

    /// @notice Largest reference supply, in a token's raw units: the hub multiplies it by units below 2^96, and the
    ///         product has to fit.
    function MAX_SUPPLY() external view returns (uint256);

    /// @notice Fewest raw units of any component an index can start with (DA-09's granularity floor).
    function MIN_RAW_UNITS() external view returns (uint256);

    /// @notice Most raw units of any component an index can start with: a 2^10 margin below uint96, so the units can
    ///         grow through about 690 rebalances at the widest band.
    function MAX_UNITS() external view returns (uint256);

    /// @notice Scale of `k` in {createIndex}: `units = k * referenceSupply / K_SCALE`.
    function K_SCALE() external view returns (uint256);

    /// @notice Time between a proposal and the earliest execution of a listing or a supply batch.
    function LISTING_DELAY() external view returns (uint256);

    /// @notice Time between {proposeGuardian} and the earliest {executeGuardianChange}.
    function GUARDIAN_DELAY() external view returns (uint256);

    /// @notice Once a proposal is ready it must be executed within this window, or proposed again.
    function PROPOSAL_WINDOW() external view returns (uint256);

    /// @notice IndexHub implementation every index clones. It cannot be initialized, so it can never issue shares.
    function IMPLEMENTATION() external view returns (address);

    /// @notice Address that, alongside the owner, can cancel pending listings, supply batches and rebalances, delist
    ///         tokens, start a rebalance with a keep mask on any index, and start one while strangers are held off after
    ///         a cancel or an unfilled auction (RT-08). May be zero.
    function guardian() external view returns (address);

    /// @notice Guardian the last proposed change names. It stays set after that proposal expires, so on its own it does
    ///         not mean a change is pending: {guardianChangePending} answers that (DA-16).
    function pendingGuardian() external view returns (address);

    /// @notice Timestamp from which the last proposed guardian change can be executed, 0 once it is executed or
    ///         cancelled. An expired proposal keeps it non-zero; ask {guardianChangePending} whether it can still run.
    function pendingGuardianEta() external view returns (uint256);

    /// @notice True for the owner and for a non-zero guardian.
    function isOwnerOrGuardian(address account) external view returns (bool);

    /// @notice Whether {createIndex} accepts `token` as a component. Delisting does not affect existing indexes.
    function isWhitelisted(address token) external view returns (bool);

    /// @notice Whitelisted tokens. The order is not stable: {delist} moves the last entry into the freed position.
    function whitelistedTokens() external view returns (address[] memory);

    /// @notice The reference supply in force for `token`, in its raw units: the supply of what the token represents
    ///         (Bitcoin's for WBTC, ether's for WETH), never read from the token itself. Zero for a token never listed.
    ///         It stays after delisting, because existing indexes still rebalance with it.
    function referenceSupply(address token) external view returns (uint256);

    /// @notice {referenceSupply} for each of `tokens`, in order. Reads storage only: no call reaches a token.
    function referenceSupplies(address[] calldata tokens) external view returns (uint256[] memory supplies);

    /// @notice Timestamp from which the last proposed listing of `token` can be executed, 0 once it is executed or
    ///         cancelled. An expired proposal keeps it non-zero; ask {listingPending} whether it can still run (DA-16).
    function listingEta(address token) external view returns (uint256);

    /// @notice Reference supply the last listing proposal for `token` carries, pending or expired; zero once it is
    ///         executed or cancelled.
    function pendingReferenceSupply(address token) external view returns (uint256);

    /// @notice Whether a proposed listing of `token` can still be executed: `listingEta` alone stays set after the window
    ///         closes (DA-16).
    function listingPending(address token) external view returns (bool);

    /// @notice Number of supply batches ever proposed, which is the last one's id.
    function supplyBatchCount() external view returns (uint256);

    /// @notice The last proposed supply batch: its id, the time from which it can be executed (0 once executed or
    ///         cancelled; an expired one keeps it), and its tokens and supplies.
    function pendingSupplies()
        external
        view
        returns (uint256 batchId, uint256 eta, address[] memory tokens, uint256[] memory referenceSupplies);

    /// @notice Whether the last proposed supply batch can still be executed.
    function suppliesPending() external view returns (bool);

    /// @notice Whether a proposed guardian change can still be executed. A proposal that passed its PROPOSAL_WINDOW is
    ///         dead but leaves `pendingGuardian` and `pendingGuardianEta` set, so those alone read as pending forever
    ///         and an operator could believe a guardian was replaced when it never was (DA-16). Ask this instead.
    function guardianChangePending() external view returns (bool);

    /// @notice Whether this factory deployed `index`: the only proof that an address is an Xindex index.
    function isIndex(address index) external view returns (bool);

    /// @notice Account that created `index`, or zero for an address that is not an index.
    function creatorOf(address index) external view returns (address);

    /// @notice The index at position `i` in creation order. Reverts at or past {allIndexesLength}.
    function allIndexes(uint256 i) external view returns (address);

    /// @notice Number of indexes this factory has deployed.
    function allIndexesLength() external view returns (uint256);

    /// @notice Starting units {createIndex} would give `tokens` for `k` with the supplies in force: `k * supply /
    ///         K_SCALE` each, rounded down. Computed for any arguments; only {createIndex} validates them.
    function previewUnits(address[] calldata tokens, uint256 k) external view returns (uint256[] memory units);

    /// @notice Address {createIndex} will use when `creator` calls it with these arguments while the supplies in force
    ///         stay as they are. The address commits to the computed units, so a supply batch executed in between moves
    ///         the address, never the basket at an address. Computed for any arguments; only {createIndex} validates.
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256 k
    ) external view returns (address);

    /// @notice Permissionless. Deploys a new index whose constituents are fixed and whose units start proportional to
    ///         the reference supplies in force: `units_i = k * referenceSupply_i / K_SCALE`, rounded down. The index
    ///         starts with no supply; anyone can then issue shares against the basket. No price is read.
    /// @param name ERC-20 name, non-empty. It is also the index's EIP-712 domain name for permits.
    /// @param symbol ERC-20 symbol, non-empty.
    /// @param tokens Whitelisted component tokens, no duplicates, 1..MAX_COMPONENTS entries.
    /// @param k Scale of the basket: every resulting unit must lie in [MIN_RAW_UNITS, MAX_UNITS] (UnitsOutOfRange).
    /// @return index The new index, at {predictIndexAddress} for msg.sender and these arguments.
    function createIndex(string calldata name, string calldata symbol, address[] calldata tokens, uint256 k)
        external
        returns (address index);

    /// @notice Owner only. Starts the delay after which `token` is whitelisted with `referenceSupply`. A token that has
    ///         carried a supply before, as a delisted one does, is relisted only within MAX_SUPPLY_STEP of it; a first
    ///         listing is bounded only by MAX_SUPPLY. Reverts AlreadyListed for a whitelisted token, whose supply changes
    ///         only in a batch, and TokenInBatch while `token` is in the live supply batch. An expired proposal can be
    ///         proposed again.
    /// @param token Token to list; must have code.
    /// @param referenceSupply Its reference supply, in raw units, from 1 to MAX_SUPPLY.
    function proposeListing(address token, uint256 referenceSupply) external;

    /// @notice Owner or guardian. Cancels a pending or expired listing.
    function cancelListing(address token) external;

    /// @notice Permissionless between the proposal's eta and eta + PROPOSAL_WINDOW. Sets the proposed reference supply
    ///         and whitelists the token if it is not listed.
    function executeListing(address token) external;

    /// @notice Owner or guardian, effective immediately. Relisting takes a fresh proposal and delay. The reference supply
    ///         stays, and existing indexes are not affected.
    function delist(address token) external;

    /// @notice Owner only. Proposes one batch of reference supplies, which executes all or nothing after LISTING_DELAY.
    ///         `tokens` must be 1 to MAX_BATCH tokens in strictly ascending address order (InvalidBatch), each already
    ///         carrying a supply (NotConfigured) and none with a live listing proposal (ListingPending); each supply
    ///         from 1 to MAX_SUPPLY and within MAX_SUPPLY_STEP of the one in force. Only one batch can be live: an
    ///         executable one reverts SuppliesPending, an expired one is replaced.
    /// @dev Atomic because a stranger who could execute half a batch and start a rebalance on the half would turn a
    ///      uniform revision, which trades nothing, into a trade.
    function proposeSupplies(address[] calldata tokens, uint256[] calldata referenceSupplies) external;

    /// @notice Owner or guardian. Cancels the pending or expired supply batch.
    function cancelSupplies() external;

    /// @notice Permissionless between the batch's eta and eta + PROPOSAL_WINDOW. Puts every supply of the batch in force.
    function executeSupplies() external;

    /// @notice Owner only. Starts GUARDIAN_DELAY before `newGuardian` replaces the guardian; zero removes the role.
    ///         Replaces any pending change, emitting GuardianChangeCancelled for it first.
    function proposeGuardian(address newGuardian) external;

    /// @notice Cancels the pending guardian change. The owner can cancel any; the current guardian can cancel only a
    ///         change that removes the role (`pendingGuardian` zero), so it cannot block its own replacement. Anyone
    ///         else gets Unauthorized.
    function cancelGuardianChange() external;

    /// @notice Permissionless between the change's eta and eta + PROPOSAL_WINDOW. Installs the pending guardian.
    function executeGuardianChange() external;
}
