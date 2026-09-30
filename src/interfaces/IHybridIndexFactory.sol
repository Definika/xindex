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

    /// @notice A governance message for a chain's vault, waiting out its delay: `kind` is `CAP_UPDATE`,
    ///         `FREEZER_CHANGE` or `VERIFIER_ROTATION` of `VaultMessages`, and `body` its body.
    struct VaultProposal {
        uint256 chainId;
        uint8 kind;
        uint64 eta;
        bytes body;
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
    ///         goes with it. `by` is the owner, the guardian, or an index that proved the chain's records false.
    event ChainFrozen(uint256 indexed chainId, uint256 until, address indexed by);
    /// @notice A governance message for `chainId`'s vault was proposed; executable from `eta` until
    ///         `eta + PROPOSAL_WINDOW`.
    event VaultProposalMade(bytes32 indexed id, uint256 indexed chainId, uint8 kind, bytes body, uint256 eta);
    /// @notice `by` cancelled the proposal `id`.
    event VaultProposalCancelled(bytes32 indexed id, address indexed by);
    /// @notice The proposal `id` was executed: its message, the `VaultMessage` emitted next, is on its way to the vault.
    event VaultProposalExecuted(bytes32 indexed id);

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
    /// @notice The proposal `id`, executable from `eta`, is still pending or executable.
    error VaultProposalPending(bytes32 id, uint256 eta);
    /// @notice No proposal `id` is pending.
    error NoVaultProposal(bytes32 id);
    /// @notice The proposal `id` can be executed from `eta`.
    error VaultProposalNotReady(bytes32 id, uint256 eta);
    /// @notice The proposal `id` could be executed until `deadline`; propose it again.
    error VaultProposalExpired(bytes32 id, uint256 deadline);
    /// @notice A rotation must name two different verifiers, or "P1 and P2" would be one proof.
    error VerifiersNotDistinct();
    /// @notice `caller` is not a HybridHub index of this factory.
    error NotAHybridIndex(address caller);

    /// @notice How long a freeze lasts: 14 days, as on the vault.
    function FREEZE_DURATION() external view returns (uint256);

    /// @notice The delay of a verifier rotation: 30 days, in public, during which the guardian can cancel it and
    ///         holders who object can leave (design 6.9).
    function ROTATION_DELAY() external view returns (uint256);

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

    /// @notice The governance proposal `id`; an empty one if none is pending.
    function vaultProposal(bytes32 id) external view returns (VaultProposal memory);

    /// @notice The id of the one proposal of `kind` for `chainId` that may be live at a time; `key` is the token of a
    ///         cap update and zero for the other kinds.
    function vaultProposalId(uint256 chainId, uint8 kind, bytes32 key) external pure returns (bytes32);

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

    /// @notice A HybridHub index of this factory only, on evidence it has checked that `chainId`'s records or proofs
    ///         are false. Freezes every index's mints on the chain, and with `payouts` the vault too, as {freezeChain}
    ///         does. Evidence against the chain's deposit proofs stops mints only, since those proofs can only inflate
    ///         mints; evidence of a payout Ethereum never sent stops the vault as well.
    function freezeOnEvidence(uint256 chainId, bool payouts) external;

    /// @notice Owner only. Proposes `CAP_UPDATE` for `token` on `chainId`'s vault: its quantity cap and outflow floor.
    ///         Executable after LISTING_DELAY; the vault takes it on both proofs if it raises either figure, else on one.
    function proposeCap(uint256 chainId, bytes32 token, uint256 cap, uint256 floor) external returns (bytes32 id);

    /// @notice Owner only. Proposes `FREEZER_CHANGE` on `chainId`'s vault. Executable after GUARDIAN_DELAY, like a
    ///         guardian change, and the guardian cannot cancel it: it cannot block its own replacement.
    function proposeFreezer(uint256 chainId, bytes32 freezer) external returns (bytes32 id);

    /// @notice Owner only. Proposes `VERIFIER_ROTATION` on `chainId`'s vault to two new, different verifiers.
    ///         Executable after ROTATION_DELAY.
    function proposeRotation(uint256 chainId, bytes32 p1, bytes32 p2) external returns (bytes32 id);

    /// @notice The owner, or the guardian for any kind but a freezer change. Cancels the proposal `id`.
    function cancelVaultProposal(bytes32 id) external;

    /// @notice Anyone, from the proposal's eta until PROPOSAL_WINDOW after it. Sends its message to the vault.
    function executeVaultProposal(bytes32 id) external;
}
