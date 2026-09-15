// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IIndexFactory
/// @notice Deploys index tokens as EIP-1167 clones at creator-bound CREATE2 addresses, curates the component
///         whitelist behind public delays, and keeps the registry.
interface IIndexFactory {
    event IndexCreated(
        address indexed index, address indexed creator, string name, string symbol, address[] tokens, uint256[] units
    );
    event ListingProposed(address indexed token, uint256 eta);
    event ListingCancelled(address indexed token);
    event TokenWhitelisted(address indexed token, bool allowed);
    event GuardianProposed(address indexed newGuardian, uint256 eta);
    event GuardianChangeCancelled(address indexed newGuardian);
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);

    error EmptyString();
    error InvalidComponentCount(uint256 count);
    error LengthMismatch();
    error TokenNotWhitelisted(address token);
    error DuplicateToken(address token);
    error InvalidUnits(address token, uint256 units);
    error IndexAlreadyExists(address index);
    error NotAContract(address token);
    error AlreadyWhitelisted(address token);
    error ListingPending(address token, uint256 eta);
    error NoPendingListing(address token);
    error ListingNotReady(address token, uint256 eta);
    error ListingExpired(address token, uint256 deadline);
    error NotWhitelisted(address token);
    error NoPendingGuardianChange();
    error GuardianChangeNotReady(uint256 eta);
    error GuardianChangeExpired(uint256 deadline);
    error Unauthorized(address account);
    error RenounceDisabled();

    function MAX_COMPONENTS() external view returns (uint256);

    /// @notice Time between {proposeListing} and the earliest {executeListing}.
    function LISTING_DELAY() external view returns (uint256);

    /// @notice Time between {proposeGuardian} and the earliest {executeGuardianChange}.
    function GUARDIAN_DELAY() external view returns (uint256);

    /// @notice Once a proposal is ready it must be executed within this window, or proposed again.
    function PROPOSAL_WINDOW() external view returns (uint256);

    function IMPLEMENTATION() external view returns (address);

    /// @notice Address that can cancel pending listings and delist tokens, alongside the owner. May be zero.
    function guardian() external view returns (address);

    /// @notice Guardian that {executeGuardianChange} will install, valid only while `pendingGuardianEta` is non-zero.
    function pendingGuardian() external view returns (address);

    /// @notice Timestamp from which the pending guardian change can be executed, or 0 when none is pending.
    function pendingGuardianEta() external view returns (uint256);

    function isWhitelisted(address token) external view returns (bool);
    function whitelistedTokens() external view returns (address[] memory);

    /// @notice Timestamp from which a proposed listing can be executed, or 0 when none is pending.
    function listingEta(address token) external view returns (uint256);

    function isIndex(address index) external view returns (bool);
    function creatorOf(address index) external view returns (address);
    function allIndexes(uint256 i) external view returns (address);
    function allIndexesLength() external view returns (uint256);

    /// @notice Address {createIndex} will use for these exact arguments when called by `creator`.
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] calldata units
    ) external view returns (address);

    /// @notice Permissionless. Deploys a new index with a fixed composition.
    /// @param tokens Whitelisted component tokens, no duplicates, 1..MAX_COMPONENTS entries.
    /// @param units  Raw units (in each token's own decimals) backing one whole index token (1e18 shares).
    function createIndex(
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] calldata units
    ) external returns (address index);

    /// @notice Owner only. Starts the delay after which `token` can be whitelisted. An expired proposal can be
    ///         proposed again.
    function proposeListing(address token) external;

    /// @notice Owner or guardian. Cancels a pending or expired listing proposal.
    function cancelListing(address token) external;

    /// @notice Permissionless between the listing's eta and eta + PROPOSAL_WINDOW. Whitelists a proposed token.
    function executeListing(address token) external;

    /// @notice Owner or guardian, effective immediately. Existing indexes are not affected.
    function delist(address token) external;

    /// @notice Owner only. Starts GUARDIAN_DELAY before `newGuardian` replaces the guardian; zero removes the role.
    ///         Replaces any pending change.
    function proposeGuardian(address newGuardian) external;

    /// @notice Owner only. Cancels the pending guardian change.
    function cancelGuardianChange() external;

    /// @notice Permissionless between the change's eta and eta + PROPOSAL_WINDOW. Installs the pending guardian.
    function executeGuardianChange() external;
}
