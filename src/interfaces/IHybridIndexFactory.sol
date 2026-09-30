// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";

/// @title IHybridIndexFactory
/// @notice The factory of Stage B: everything {IIndexFactory} does, plus a registry of the chains whose native coins
///         and tokens indexes may hold in vaults, the listing of those tokens, and a freeze of a chain's vault. An index
///         of Ethereum tokens only is an `IndexHub` clone, exactly as in Stage A; an index holding any vault token is a
///         `HybridHub` clone.
/// @dev A vault token has an Ethereum-side id, `vaultTokenId(chainId, tokenId)`, a 20-byte hash no contract can hold,
///      and from its listing on it takes Stage A's flow unchanged under that id: executeListing, delist, supply batches.
interface IHybridIndexFactory is IIndexFactory {
    /// @notice A chain registered with its vault and the Ethereum-side verifier of its state.
    struct Chain {
        bytes32 vault;
        address stateVerifier;
    }

    /// @notice A chain's current or last freeze: when it began and when it ends.
    struct Freeze {
        uint64 start;
        uint64 until;
    }

    /// @notice Registering `chainId` with `vault` and `stateVerifier` was proposed; executable from `eta` until
    ///         `eta + PROPOSAL_WINDOW`. For a chain already registered only the state verifier can change.
    event ChainProposed(uint256 indexed chainId, bytes32 vault, address stateVerifier, uint256 eta);
    /// @notice The pending proposal for `chainId` was cancelled.
    event ChainProposalCancelled(uint256 indexed chainId);
    /// @notice `chainId` is registered with `vault` and `stateVerifier`, for the first time or with a new verifier.
    event ChainSet(uint256 indexed chainId, bytes32 vault, address stateVerifier);
    /// @notice `token` is the Ethereum-side id of `tokenId` on `chainId`, proposed for listing.
    event VaultTokenRegistered(address indexed token, uint256 indexed chainId, bytes32 tokenId);
    /// @notice `by` froze `chainId`'s vault and every index's mints on it until `until`; a `FREEZE` message to the vault
    ///         goes with it.
    event ChainFrozen(uint256 indexed chainId, uint256 until, address indexed by);

    /// @notice `chainId` cannot be a vault chain: zero is Ethereum's place in an index.
    error InvalidChain(uint256 chainId);
    /// @notice A proposal for `chainId` executable from `eta` is still pending or executable.
    error ChainPending(uint256 chainId, uint256 eta);
    /// @notice No proposal is pending for `chainId`.
    error NoPendingChain(uint256 chainId);
    /// @notice The proposal for `chainId` can be executed from `eta`.
    error ChainNotReady(uint256 chainId, uint256 eta);
    /// @notice The proposal for `chainId` could be executed until `deadline`; propose it again.
    error ChainExpired(uint256 chainId, uint256 deadline);
    /// @notice `chainId` keeps `vault` for good: every index holding its tokens copied that address.
    error VaultFixed(uint256 chainId, bytes32 vault);
    /// @notice `chainId` is not registered.
    error UnknownChain(uint256 chainId);
    /// @notice `implementation` is not a HybridHub built for this factory.
    error NotFactoryTemplate(address implementation);

    /// @notice How long a freeze lasts: 14 days, as on the vault.
    function FREEZE_DURATION() external view returns (uint256);

    /// @notice The HybridHub template an index holding vault tokens is a clone of.
    function HYBRID_IMPLEMENTATION() external view returns (address);

    /// @notice The registered vault and state verifier of `chainId`; zero for a chain not registered.
    function chain(uint256 chainId) external view returns (Chain memory);

    /// @notice The state verifier of `chainId`, which every index holding its tokens reads at each proof; zero for a
    ///         chain not registered.
    function stateVerifier(uint256 chainId) external view returns (address);

    /// @notice `chainId`'s current or last freeze.
    function chainFreeze(uint256 chainId) external view returns (Freeze memory);

    /// @notice The Ethereum-side id of `tokenId` on `chainId`.
    function vaultTokenId(uint256 chainId, bytes32 tokenId) external pure returns (address);

    /// @notice The chain and token id behind `token`; zero for an Ethereum token.
    function vaultToken(address token) external view returns (uint256 chainId, bytes32 tokenId);

    /// @notice The CREATE2 salt `index` was deployed with, for a vault's `registerIndex`; zero for an Ethereum-only
    ///         index.
    function indexSalt(address index) external view returns (bytes32);

    /// @notice Whether a proposal for `chainId` is pending or executable.
    function chainPending(uint256 chainId) external view returns (bool);

    /// @notice Owner only. Proposes registering `chainId` with `vault` and `stateVerifier`, or, for a registered chain,
    ///         a new state verifier with the same vault. Executable after LISTING_DELAY.
    function proposeChain(uint256 chainId, bytes32 vault, address stateVerifier) external;

    /// @notice Owner or guardian. Cancels the pending proposal for `chainId`.
    function cancelChain(uint256 chainId) external;

    /// @notice Anyone, from the proposal's eta until PROPOSAL_WINDOW after it. Applies it.
    function executeChain(uint256 chainId) external;

    /// @notice Owner only. Proposes listing `tokenId` on the registered `chainId` with `supply`; the listing then runs
    ///         as {proposeListing}'s under `vaultTokenId(chainId, tokenId)`.
    function proposeVaultListing(uint256 chainId, bytes32 tokenId, uint256 supply) external;

    /// @notice Owner or guardian. Freezes `chainId` for FREEZE_DURATION from now: every index's mints on it stop, and a
    ///         `FREEZE` message, which either Ethereum-side proof carries, stops the vault's payouts and deposits.
    function freezeChain(uint256 chainId) external;
}
