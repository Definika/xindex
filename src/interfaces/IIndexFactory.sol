// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IIndexFactory
/// @notice Deploys index tokens as EIP-1167 clones at creator-bound CREATE2 addresses, curates the component whitelist
///         and each token's market-data configuration behind public delays, and keeps the registry.
interface IIndexFactory {
    /// @notice Where the rebalance rule reads a token's price and supply.
    /// @param pool Uniswap V3 pool of the token against WETH. Zero only for WETH itself.
    /// @param referenceSupply Supply used instead of the on-chain one, in the token's raw units. Needed for wrapped assets
    ///        such as WBTC or WETH, whose on-chain supply counts only the wrapped coins. Zero uses on-chain supply.
    /// @param excluded Addresses whose balances do not circulate, such as burn or lock wallets. Only allowed when
    ///        `referenceSupply` is zero.
    struct TokenConfig {
        address pool;
        uint256 referenceSupply;
        address[] excluded;
    }

    event IndexCreated(
        address indexed index,
        address indexed creator,
        string name,
        string symbol,
        address[] tokens,
        uint256[] units,
        uint8 methodology
    );
    event ListingProposed(
        address indexed token, uint256 eta, address pool, uint256 referenceSupply, address[] excluded
    );
    event ListingCancelled(address indexed token);
    event TokenConfigured(address indexed token, address pool, uint256 referenceSupply, address[] excluded);
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
    error InvalidMethodology(uint8 methodology);
    error TooFewComponentsForCapped(uint256 count);
    error IndexAlreadyExists(address index);
    error NotAContract(address token);
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

    /// @notice Fewest components an index with the capped methodology can have.
    function MIN_CAPPED_COMPONENTS() external view returns (uint256);

    /// @notice Time between {proposeListing} and the earliest {executeListing}.
    function LISTING_DELAY() external view returns (uint256);

    /// @notice Time between {proposeGuardian} and the earliest {executeGuardianChange}.
    function GUARDIAN_DELAY() external view returns (uint256);

    /// @notice Once a proposal is ready it must be executed within this window, or proposed again.
    function PROPOSAL_WINDOW() external view returns (uint256);

    function IMPLEMENTATION() external view returns (address);

    /// @notice Stateless contract that reads market data, computes rebalance targets and prices indexes.
    function RULE() external view returns (address);

    /// @notice Address that can cancel pending listings and rebalances and delist tokens, alongside the owner. May be
    ///         zero.
    function guardian() external view returns (address);

    /// @notice Guardian that {executeGuardianChange} will install, valid only while `pendingGuardianEta` is non-zero.
    function pendingGuardian() external view returns (address);

    /// @notice Timestamp from which the pending guardian change can be executed, or 0 when none is pending.
    function pendingGuardianEta() external view returns (uint256);

    /// @notice True for the owner and for a non-zero guardian.
    function isOwnerOrGuardian(address account) external view returns (bool);

    function isWhitelisted(address token) external view returns (bool);
    function whitelistedTokens() external view returns (address[] memory);

    /// @notice Timestamp from which a proposed listing or config change can be executed, or 0 when none is pending.
    function listingEta(address token) external view returns (uint256);

    /// @notice Market-data configuration in force for `token`. It stays after delisting, because existing indexes still
    ///         rebalance with it.
    function tokenConfig(address token) external view returns (TokenConfig memory);

    /// @notice Configuration {executeListing} will apply, valid only while `listingEta(token)` is non-zero.
    function pendingTokenConfig(address token) external view returns (TokenConfig memory);

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
        uint256[] calldata units,
        uint8 methodology
    ) external view returns (address);

    /// @notice Permissionless. Deploys a new index whose constituents are fixed and whose units follow `methodology`.
    /// @param tokens Whitelisted component tokens, no duplicates, 1..MAX_COMPONENTS entries.
    /// @param units  Starting raw units (in each token's own decimals) backing one whole index token (1e18 shares).
    ///               `IIndexRule.initialUnits` returns units that already follow the methodology.
    /// @param methodology `Methodology.UNCAPPED` or `Methodology.CAPPED`, the latter with at least MIN_CAPPED_COMPONENTS
    ///               components.
    function createIndex(
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] calldata units,
        uint8 methodology
    ) external returns (address index);

    /// @notice Owner only. Starts the delay after which `token` is whitelisted with `config`, or, for a token that is
    ///         already listed, after which its config is replaced. The rule validates the config first. An expired
    ///         proposal can be proposed again.
    function proposeListing(address token, TokenConfig calldata config) external;

    /// @notice Owner or guardian. Cancels a pending or expired listing or config change.
    function cancelListing(address token) external;

    /// @notice Permissionless between the proposal's eta and eta + PROPOSAL_WINDOW. Applies the proposed config and
    ///         whitelists the token if it is not listed.
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
