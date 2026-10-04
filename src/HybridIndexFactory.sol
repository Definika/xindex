// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IndexFactory} from "./IndexFactory.sol";
import {IHybridIndexFactory} from "./interfaces/IHybridIndexFactory.sol";
import {IHybridHub} from "./interfaces/IHybridHub.sol";
import {IHybridHubTypes} from "./interfaces/IHybridHubTypes.sol";
import {VaultMessages} from "./libraries/VaultMessages.sol";

/// @title HybridIndexFactory
/// @notice Stage B's factory: Stage A's, plus the chain registry, vault-token listings, the choice of template, a
///         chain freeze and the governance messages to vaults. See {IHybridIndexFactory}.
/// @dev Stage A's flow is untouched: an index of Ethereum tokens only is an `IndexHub` clone, as `IndexFactory` makes
///      it. Chains follow the listing flow's timelock: proposed by the owner, executable by anyone after LISTING_DELAY
///      and within PROPOSAL_WINDOW, cancellable by the owner or guardian. A chain's vault is fixed at its first
///      registration, because every index holding its tokens copies it; only its state verifier can change after that,
///      which is how a verifier follows a chain upgrade (design 6.10), and a new one waits ROTATION_DELAY (FAC-1). A vault's own settings change only through
///      messages the factory sends after a delay: a cap after LISTING_DELAY, the freezer after GUARDIAN_DELAY, and the
///      Ethereum-event verifiers after ROTATION_DELAY (design 6.9).
contract HybridIndexFactory is IndexFactory, IHybridIndexFactory {
    /// @inheritdoc IHybridIndexFactory
    uint256 public constant FREEZE_DURATION = 14 days;
    /// @inheritdoc IHybridIndexFactory
    uint256 public constant ROTATION_DELAY = 30 days;
    /// @inheritdoc IHybridIndexFactory
    address public immutable HYBRID_IMPLEMENTATION;

    bytes32 private constant VAULT_TOKEN_DOMAIN = keccak256("xindex.v4.vault-token");
    uint256 private constant ADDRESS_BITS = 160;

    struct ChainProposal {
        bytes32 vault;
        address stateVerifier;
        uint64 eta;
    }

    mapping(uint256 chainId => Chain) private _chains;
    mapping(uint256 chainId => ChainProposal) private _chainProposals;
    mapping(uint256 chainId => Freeze) private _freezes;
    mapping(address token => uint256 chainId) private _tokenChain;
    mapping(address token => bytes32 tokenId) private _tokenId;
    /// @inheritdoc IHybridIndexFactory
    mapping(address index => bytes32 salt) public indexSalt;
    /// @notice The nonce of the factory's last message to a vault.
    uint256 public messageNonce;
    /// @inheritdoc IHybridIndexFactory
    mapping(bytes32 id => bool) public messageSent;
    mapping(bytes32 id => VaultProposal) private _vaultProposals;

    /// @param hybridImplementation A `HybridHub` deployed for this factory: its FACTORY must be this contract.
    constructor(address initialOwner, address initialGuardian, address hybridImplementation)
        IndexFactory(initialOwner, initialGuardian)
    {
        if (hybridImplementation == address(0)) revert ZeroAddress();
        HYBRID_IMPLEMENTATION = hybridImplementation;
        if (IHybridHub(hybridImplementation).FACTORY() != address(this)) {
            revert NotFactoryTemplate(hybridImplementation);
        }
    }

    // ---------------------------------------------------------------------
    // Chains
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridIndexFactory
    function proposeChain(uint256 chainId, bytes32 vault, address verifier) external onlyOwner {
        if (chainId == 0) revert InvalidChain(chainId);
        if (vault == bytes32(0)) revert ZeroAddress();
        if (verifier.code.length == 0) revert NotAContract(verifier);
        bytes32 fixedVault = _chains[chainId].vault;
        if (fixedVault != bytes32(0) && vault != fixedVault) revert VaultFixed(chainId, fixedVault);
        uint256 pending = _chainProposals[chainId].eta;
        if (pending != 0 && block.timestamp <= pending + PROPOSAL_WINDOW) revert ChainPending(chainId, pending);

        // A new state verifier for a registered chain decides every index's mints there, as new P1 and P2 decide the
        // vault's payouts, so it waits as long (FAC-1).
        uint256 eta = block.timestamp + (fixedVault == bytes32(0) ? LISTING_DELAY : ROTATION_DELAY);
        _chainProposals[chainId] = ChainProposal({vault: vault, stateVerifier: verifier, eta: SafeCast.toUint64(eta)});
        emit ChainProposed(chainId, vault, verifier, eta);
    }

    /// @inheritdoc IHybridIndexFactory
    function cancelChain(uint256 chainId) external onlyOwnerOrGuardian {
        if (_chainProposals[chainId].eta == 0) revert NoPendingChain(chainId);
        delete _chainProposals[chainId];
        emit ChainProposalCancelled(chainId);
    }

    /// @inheritdoc IHybridIndexFactory
    function executeChain(uint256 chainId) external {
        ChainProposal memory p = _chainProposals[chainId];
        if (p.eta == 0) revert NoPendingChain(chainId);
        if (block.timestamp < p.eta) revert ChainNotReady(chainId, p.eta);
        if (block.timestamp > p.eta + PROPOSAL_WINDOW) revert ChainExpired(chainId, p.eta + PROPOSAL_WINDOW);
        delete _chainProposals[chainId];
        // The proposal checked the vault against the one in force, and nothing else sets it.
        _chains[chainId] = Chain({vault: p.vault, stateVerifier: p.stateVerifier});
        emit ChainSet(chainId, p.vault, p.stateVerifier);
    }

    /// @inheritdoc IHybridIndexFactory
    function proposeVaultListing(uint256 chainId, bytes32 tokenId, uint256 supply) external onlyOwner {
        if (_chains[chainId].vault == bytes32(0)) revert UnknownChain(chainId);
        // Every vault's digests carry a token as 20 bytes, and the hub reads an id's low 20 (A3-04).
        if (uint256(tokenId) >> ADDRESS_BITS != 0) revert InvalidTokenId(tokenId);
        address token = vaultTokenId(chainId, tokenId);
        if (_tokenChain[token] == 0) {
            _tokenChain[token] = chainId;
            _tokenId[token] = tokenId;
            emit VaultTokenRegistered(token, chainId, tokenId);
        }
        _proposeListing(token, supply);
    }

    /// @inheritdoc IHybridIndexFactory
    function freezeChain(uint256 chainId) external onlyOwnerOrGuardian {
        _freezeChain(chainId, true);
    }

    /// @inheritdoc IHybridIndexFactory
    function freezeOnEvidence(uint256 chainId, bool payouts) external {
        // Only this factory's HybridHub clones have a recorded salt, and each checked the evidence before calling.
        if (indexSalt[msg.sender] == bytes32(0)) revert NotAHybridIndex(msg.sender);
        _freezeChain(chainId, payouts);
    }

    /// @dev Freezes every index's mints on `chainId`, and with `payouts` the vault too, through a `FREEZE` message.
    function _freezeChain(uint256 chainId, bool payouts) private {
        bytes32 vault = _chains[chainId].vault;
        if (vault == bytes32(0)) revert UnknownChain(chainId);
        uint256 until = block.timestamp + FREEZE_DURATION;
        _freezes[chainId] = Freeze({start: SafeCast.toUint64(block.timestamp), until: SafeCast.toUint64(until)});
        emit ChainFrozen(chainId, until, msg.sender);
        if (payouts) _sendVault(chainId, vault, VaultMessages.FREEZE, "");
    }

    /// @dev Emits a message to `chainId`'s vault, which P1, P2 or both prove final there, as its kind requires.
    function _sendVault(uint256 chainId, bytes32 vault, uint8 kind, bytes memory body) private {
        bytes memory payload = VaultMessages.encode(
            VaultMessages.Message({
                sourceChainId: block.chainid,
                kind: kind,
                destChainId: chainId,
                vault: vault,
                index: address(this),
                nonce: ++messageNonce,
                body: body
            })
        );
        bytes32 id = keccak256(payload);
        messageSent[id] = true;
        emit VaultMessages.VaultMessage(id, payload);
    }

    /// @inheritdoc IHybridIndexFactory
    function resendMessage(bytes calldata payload) external {
        bytes32 id = keccak256(payload);
        if (!messageSent[id]) revert IHybridHubTypes.NotSent(id);
        emit VaultMessages.VaultMessage(id, payload);
    }

    // ---------------------------------------------------------------------
    // Governance messages
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridIndexFactory
    function proposeCap(uint256 chainId, bytes32 token, uint256 cap, uint256 floor)
        external
        onlyOwner
        returns (bytes32 id)
    {
        return _proposeVault(chainId, VaultMessages.CAP_UPDATE, token, abi.encode(token, cap, floor), LISTING_DELAY);
    }

    /// @inheritdoc IHybridIndexFactory
    function proposeFreezer(uint256 chainId, bytes32 freezer) external onlyOwner returns (bytes32 id) {
        if (freezer == bytes32(0)) revert ZeroAddress();
        return _proposeVault(chainId, VaultMessages.FREEZER_CHANGE, bytes32(0), abi.encode(freezer), GUARDIAN_DELAY);
    }

    /// @inheritdoc IHybridIndexFactory
    function proposeRotation(uint256 chainId, bytes32 p1, bytes32 p2) external onlyOwner returns (bytes32 id) {
        if (p1 == bytes32(0) || p2 == bytes32(0)) revert ZeroAddress();
        if (p1 == p2) revert VerifiersNotDistinct();
        return _proposeVault(chainId, VaultMessages.VERIFIER_ROTATION, bytes32(0), abi.encode(p1, p2), ROTATION_DELAY);
    }

    /// @dev One live proposal per chain, kind and key; an expired one is replaced.
    function _proposeVault(uint256 chainId, uint8 kind, bytes32 key, bytes memory body, uint256 delay)
        private
        returns (bytes32 id)
    {
        if (_chains[chainId].vault == bytes32(0)) revert UnknownChain(chainId);
        id = vaultProposalId(chainId, kind, key);
        uint256 pending = _vaultProposals[id].eta;
        if (pending != 0 && block.timestamp <= pending + PROPOSAL_WINDOW) revert VaultProposalPending(id, pending);
        uint256 eta = block.timestamp + delay;
        _vaultProposals[id] = VaultProposal({chainId: chainId, kind: kind, eta: SafeCast.toUint64(eta), body: body});
        emit VaultProposalMade(id, chainId, kind, body, eta);
    }

    /// @inheritdoc IHybridIndexFactory
    function cancelVaultProposal(bytes32 id) external {
        VaultProposal storage p = _vaultProposals[id];
        if (p.eta == 0) revert NoVaultProposal(id);
        // The guardian cannot block its own replacement, on a vault chain as on Ethereum.
        bool guardianMay = p.kind != VaultMessages.FREEZER_CHANGE && msg.sender == guardian && guardian != address(0);
        if (msg.sender != owner() && !guardianMay) revert Unauthorized(msg.sender);
        delete _vaultProposals[id];
        emit VaultProposalCancelled(id, msg.sender);
    }

    /// @inheritdoc IHybridIndexFactory
    function executeVaultProposal(bytes32 id) external {
        VaultProposal memory p = _vaultProposals[id];
        if (p.eta == 0) revert NoVaultProposal(id);
        if (block.timestamp < p.eta) revert VaultProposalNotReady(id, p.eta);
        if (block.timestamp > p.eta + PROPOSAL_WINDOW) revert VaultProposalExpired(id, p.eta + PROPOSAL_WINDOW);
        delete _vaultProposals[id];
        // A chain's vault never changes once registered, so the proposal's chain still names the vault it was for.
        emit VaultProposalExecuted(id);
        _sendVault(p.chainId, _chains[p.chainId].vault, p.kind, p.body);
    }

    // ---------------------------------------------------------------------
    // Templates
    // ---------------------------------------------------------------------

    /// @dev An index holding any vault token is a HybridHub.
    function _template(address[] calldata tokens) internal view override returns (address) {
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_tokenChain[tokens[i]] != 0) return HYBRID_IMPLEMENTATION;
        }
        return IMPLEMENTATION;
    }

    /// @dev A HybridHub gets each component's chain, token id and vault, copied here once: an index's vaults never
    ///      change (I8). Its salt is recorded for the vaults' `registerIndex`.
    function _initializeIndex(
        address index,
        bytes32 salt,
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] memory units
    ) internal override {
        if (_template(tokens) == IMPLEMENTATION) {
            super._initializeIndex(index, salt, name, symbol, tokens, units);
            return;
        }
        uint256 n = tokens.length;
        IHybridHubTypes.Placement[] memory placements = new IHybridHubTypes.Placement[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = _tokenChain[tokens[i]];
            if (id == 0) continue;
            placements[i] =
                IHybridHubTypes.Placement({chainId: id, vaultToken: _tokenId[tokens[i]], vault: _chains[id].vault});
        }
        indexSalt[index] = salt;
        IHybridHub(index).initialize(name, symbol, tokens, units, placements);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridIndexFactory
    function chain(uint256 chainId) external view returns (Chain memory) {
        return _chains[chainId];
    }

    /// @inheritdoc IHybridIndexFactory
    function stateVerifier(uint256 chainId) external view returns (address) {
        return _chains[chainId].stateVerifier;
    }

    /// @inheritdoc IHybridIndexFactory
    function chainFreeze(uint256 chainId) external view returns (Freeze memory) {
        return _freezes[chainId];
    }

    /// @inheritdoc IHybridIndexFactory
    function vaultTokenId(uint256 chainId, bytes32 tokenId) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(VAULT_TOKEN_DOMAIN, chainId, tokenId)))));
    }

    /// @inheritdoc IHybridIndexFactory
    function vaultToken(address token) external view returns (uint256 chainId, bytes32 tokenId) {
        return (_tokenChain[token], _tokenId[token]);
    }

    /// @inheritdoc IHybridIndexFactory
    function chainPending(uint256 chainId) external view returns (bool) {
        uint256 eta = _chainProposals[chainId].eta;
        return eta != 0 && block.timestamp <= eta + PROPOSAL_WINDOW;
    }

    /// @inheritdoc IHybridIndexFactory
    function chainProposal(uint256 chainId) external view returns (bytes32 vault, address verifier, uint256 eta) {
        ChainProposal memory p = _chainProposals[chainId];
        return (p.vault, p.stateVerifier, p.eta);
    }

    /// @inheritdoc IHybridIndexFactory
    function vaultProposal(bytes32 id) external view returns (VaultProposal memory) {
        return _vaultProposals[id];
    }

    /// @inheritdoc IHybridIndexFactory
    function vaultProposalId(uint256 chainId, uint8 kind, bytes32 key) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, kind, key));
    }
}
