// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IXindexErrors} from "./IXindexErrors.sol";

/// @title IIndexFactory
/// @notice Deploys index tokens as EIP-1167 clones at creator-bound CREATE2 addresses, curates the component whitelist
///         and each token's market-data configuration behind public delays, and keeps the registry.
/// @dev "Owner only" functions revert with OpenZeppelin's `OwnableUnauthorizedAccount` for any other caller, and
///      "owner or guardian" functions with `Unauthorized`.
interface IIndexFactory is IXindexErrors {
    /// @notice Where the rebalance rule reads a token's price and supply.
    /// @param pool Uniswap V3 pool of the token against WETH. Zero only for WETH itself.
    /// @param minLiquidity Least harmonic-mean in-range liquidity of `pool` over the rule's TWAP window for which a
    ///        rebalance snapshot accepts its price. A window whose price was pushed through thin or empty ranges falls
    ///        below it. Non-zero for every token with a pool; zero for WETH.
    /// @param referenceSupply Supply used instead of the on-chain one, in the token's raw units. Needed for wrapped assets
    ///        such as WBTC or WETH, whose on-chain supply counts only the wrapped coins. Zero uses on-chain supply.
    /// @param excluded Addresses whose balances do not circulate, such as burn or lock wallets. Only allowed when
    ///        `referenceSupply` is zero.
    struct TokenConfig {
        address pool;
        uint128 minLiquidity;
        uint256 referenceSupply;
        address[] excluded;
    }

    /// @notice `creator` deployed and initialized `index` with these constituents, starting units (raw units of each
    ///         token per 1e18 shares, in the same order) and methodology.
    event IndexCreated(
        address indexed index,
        address indexed creator,
        string name,
        string symbol,
        address[] tokens,
        uint256[] units,
        uint8 methodology
    );
    /// @notice A listing or config change for `token` was proposed with this config. It can be executed from `eta`
    ///         until `eta + PROPOSAL_WINDOW`.
    /// @param listing True when executing the proposal whitelists `token`; false for a config change only.
    event ListingProposed(
        address indexed token,
        uint256 eta,
        bool listing,
        address pool,
        uint128 minLiquidity,
        uint256 referenceSupply,
        address[] excluded
    );
    /// @notice The pending proposal for `token` was cancelled, or dropped because {delist} removed the token.
    event ListingCancelled(address indexed token);
    /// @notice An executed proposal put this config in force for `token`.
    event TokenConfigured(
        address indexed token, address pool, uint128 minLiquidity, uint256 referenceSupply, address[] excluded
    );
    /// @notice `token` was whitelisted (`allowed`) or delisted.
    event TokenWhitelisted(address indexed token, bool allowed);
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
    /// @notice The starting `units` of `token` are zero or do not fit uint96.
    error InvalidUnits(address token, uint256 units);
    /// @notice The same creator already deployed an index with these exact arguments, at `index`.
    error IndexAlreadyExists(address index);
    /// @notice `token` has no code.
    error NotAContract(address token);
    /// @notice {proposeConfig} for a token that has never been listed; use {proposeListing}.
    error NotConfigured(address token);
    /// @notice A proposal for `token` executable from `eta` is still pending or executable. Cancel it first; one that
    ///         expired can be replaced.
    error ListingPending(address token, uint256 eta);
    /// @notice Nothing is proposed for `token`.
    error NoPendingListing(address token);
    /// @notice The proposal for `token` can be executed from `eta`.
    error ListingNotReady(address token, uint256 eta);
    /// @notice The proposal for `token` could be executed until `deadline`; propose it again.
    error ListingExpired(address token, uint256 deadline);
    /// @notice {delist} for a token that is not whitelisted.
    error NotWhitelisted(address token);
    /// @notice No guardian change is pending.
    error NoPendingGuardianChange();
    /// @notice The pending guardian change can be executed from `eta`.
    error GuardianChangeNotReady(uint256 eta);
    /// @notice The pending guardian change could be executed until `deadline`; propose it again.
    error GuardianChangeExpired(uint256 deadline);
    /// @notice Ownership cannot be renounced: without an owner, listings and token configs could never change again.
    error RenounceDisabled();

    /// @notice Most components an index can have.
    function MAX_COMPONENTS() external view returns (uint256);

    /// @notice Fewest components an index with the capped methodology can have.
    function MIN_CAPPED_COMPONENTS() external view returns (uint256);

    /// @notice Time between {proposeListing} and the earliest {executeListing}.
    function LISTING_DELAY() external view returns (uint256);

    /// @notice Time between {proposeGuardian} and the earliest {executeGuardianChange}.
    function GUARDIAN_DELAY() external view returns (uint256);

    /// @notice Once a proposal is ready it must be executed within this window, or proposed again.
    function PROPOSAL_WINDOW() external view returns (uint256);

    /// @notice IndexToken implementation every index clones. It cannot be initialized, so it can never issue shares.
    function IMPLEMENTATION() external view returns (address);

    /// @notice Stateless contract that reads market data, computes rebalance targets and prices indexes.
    function RULE() external view returns (address);

    /// @notice Address that, alongside the owner, can cancel pending listings and rebalances, delist tokens, start a
    ///         rebalance with a keep mask on any index, and start one before an index's `restartAllowedAt`. May be
    ///         zero.
    function guardian() external view returns (address);

    /// @notice Guardian that {executeGuardianChange} will install, valid only while `pendingGuardianEta` is non-zero.
    function pendingGuardian() external view returns (address);

    /// @notice Timestamp from which the pending guardian change can be executed, or 0 when none is pending.
    function pendingGuardianEta() external view returns (uint256);

    /// @notice True for the owner and for a non-zero guardian.
    function isOwnerOrGuardian(address account) external view returns (bool);

    /// @notice Whether {createIndex} accepts `token` as a component. Delisting does not affect existing indexes.
    function isWhitelisted(address token) external view returns (bool);

    /// @notice Whitelisted tokens. The order is not stable: {delist} moves the last entry into the freed position.
    function whitelistedTokens() external view returns (address[] memory);

    /// @notice Timestamp from which a proposed listing or config change can be executed, or 0 when none is pending.
    function listingEta(address token) external view returns (uint256);

    /// @notice Market-data configuration in force for `token`. It stays after delisting, because existing indexes still
    ///         rebalance with it.
    function tokenConfig(address token) external view returns (TokenConfig memory);

    /// @notice Configuration {executeListing} will apply, valid only while `listingEta(token)` is non-zero.
    function pendingTokenConfig(address token) external view returns (TokenConfig memory);

    /// @notice Whether a proposed guardian change can still be executed. A proposal that passed its PROPOSAL_WINDOW is
    ///         dead but leaves `pendingGuardian` and `pendingGuardianEta` set, so those alone read as pending forever
    ///         and an operator could believe a guardian was replaced when it never was (DA-16). Ask this instead.
    function guardianChangePending() external view returns (bool);

    /// @notice Whether a proposed listing or config change can still be executed, for the same reason as
    ///         {guardianChangePending}: `listingEta` alone stays set after the window closes.
    function listingPending(address token) external view returns (bool);

    /// @notice Whether the pending proposal for `token` whitelists it when executed ({proposeListing}) or only replaces
    ///         its config ({proposeConfig}). Valid only while `listingEta(token)` is non-zero.
    function pendingIsListing(address token) external view returns (bool);

    /// @notice Whether this factory deployed `index`: the only proof that an address is an Xindex index.
    function isIndex(address index) external view returns (bool);

    /// @notice Account that created `index`, or zero for an address that is not an index.
    function creatorOf(address index) external view returns (address);

    /// @notice The index at position `i` in creation order. Reverts at or past {allIndexesLength}.
    function allIndexes(uint256 i) external view returns (address);

    /// @notice Number of indexes this factory has deployed.
    function allIndexesLength() external view returns (uint256);

    /// @notice Address {createIndex} will use for these exact arguments when called by `creator`. It is computed for
    ///         any arguments; only {createIndex} validates them.
    /// @param creator The account that will call {createIndex}.
    /// @return The index address.
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] calldata units,
        uint8 methodology
    ) external view returns (address);

    /// @notice Permissionless. Deploys a new index whose constituents are fixed and whose units follow `methodology`.
    ///         The index starts with no supply; anyone can then issue shares against the basket.
    /// @param name ERC-20 name, non-empty. It is also the index's EIP-712 domain name for permits.
    /// @param symbol ERC-20 symbol, non-empty.
    /// @param tokens Whitelisted component tokens, no duplicates, 1..MAX_COMPONENTS entries.
    /// @param units  Starting raw units (in each token's own decimals) backing one whole index token (1e18 shares),
    ///               each from 1 to type(uint96).max. `IIndexRule.initialUnits` returns units that already follow the
    ///               methodology.
    /// @param methodology `Methodology.UNCAPPED` or `Methodology.CAPPED`, the latter with at least MIN_CAPPED_COMPONENTS
    ///               components.
    /// @return index The new index, at {predictIndexAddress} for msg.sender and these arguments.
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
    /// @param token Token to list; must have code.
    /// @param config Market-data config, checked with `IIndexRule.checkConfig`.
    function proposeListing(address token, TokenConfig calldata config) external;

    /// @notice Owner only. Starts the delay after which `config` replaces the config in force for `token`, which must
    ///         have been listed, without whitelisting it: a delisted token keeps receiving config refreshes for the
    ///         indexes that still hold it. The rule validates the config first. Reverts NotConfigured for a token never
    ///         listed.
    /// @param token Listed or delisted token whose config changes.
    /// @param config Replacement config, checked with `IIndexRule.checkConfig`.
    function proposeConfig(address token, TokenConfig calldata config) external;

    /// @notice Owner or guardian. Cancels a pending or expired listing or config change.
    /// @param token Token whose proposal is dropped.
    function cancelListing(address token) external;

    /// @notice Permissionless between the proposal's eta and eta + PROPOSAL_WINDOW. Applies the proposed config and,
    ///         for a {proposeListing} proposal, whitelists the token if it is not listed.
    /// @param token Token whose proposal is executed.
    function executeListing(address token) external;

    /// @notice Owner or guardian, effective immediately. Also cancels a pending {proposeListing} proposal for `token`,
    ///         so relisting always takes a fresh proposal and delay; a pending {proposeConfig} change stays. Existing
    ///         indexes are not affected.
    /// @param token Whitelisted token to remove from the whitelist.
    function delist(address token) external;

    /// @notice Owner only. Starts GUARDIAN_DELAY before `newGuardian` replaces the guardian; zero removes the role.
    ///         Replaces any pending change, emitting GuardianChangeCancelled for it first.
    /// @param newGuardian The next guardian, or zero for none.
    function proposeGuardian(address newGuardian) external;

    /// @notice Cancels the pending guardian change. The owner can cancel any; the current guardian can cancel only a
    ///         change that removes the role (`pendingGuardian` zero), so it cannot block its own replacement. Anyone
    ///         else gets Unauthorized.
    function cancelGuardianChange() external;

    /// @notice Permissionless between the change's eta and eta + PROPOSAL_WINDOW. Installs the pending guardian.
    function executeGuardianChange() external;
}
