// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IXindexVault} from "../interfaces/IXindexVault.sol";
import {IStateReader} from "../interfaces/IStateReader.sol";

/// @title VaultSnapshot
/// @notice What a vault reads of an index at its snapshot exit, and the holder's signature it checks there. Linked to
///         `XindexVault` rather than inlined, so the vault fits EIP-170's size limit. It reads and writes no storage of
///         its own or of the vault: everything it uses comes in as an argument.
library VaultSnapshot {
    /// @dev The hub's storage a claim reads (`HybridHubStorage`, and OpenZeppelin's ERC-20 namespace), pinned by
    ///      `test_theHubLayoutIsPinned` against the compiler's layout: the shares' balances, `_components` (slot 0, each
    ///      `(units << 160) | token`), `_claimOf` (11) and `_recovery` (59).
    bytes32 private constant HUB_SHARES = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
    uint256 private constant HUB_COMPONENTS_SLOT = 0;
    uint256 private constant HUB_CLAIMS_SLOT = 11;
    uint256 private constant HUB_RECOVERY_SLOT = 59;
    /// @dev The factory's id of a vault token on Ethereum: `vaultTokenId(chainId, tokenId)`.
    bytes32 private constant VAULT_TOKEN_DOMAIN = keccak256("xindex.v4.vault-token");
    uint256 private constant UNITS_SHIFT = 160;
    uint256 private constant WAD = 1e18;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant SNAPSHOT_CLAIM_TYPEHASH =
        keccak256("SnapshotClaim(address index,address holder,address recipient)");

    /// @notice What `holder` is owed of `token`, this chain's coin or a token on it, in `index` at the snapshot, once
    ///         `recipient` is shown to be where it is paid: the recovery address it registered in the hub for this chain,
    ///         such as a contract's, and nowhere else, or else the one it signed for with its Ethereum key. Called by the
    ///         vault, whose address, under delegatecall, is the signature's domain. One entry point for both checks
    ///         keeps the vault within EIP-170's size limit.
    function claim(
        IStateReader reader,
        bytes32 root,
        address index,
        address holder,
        address recipient,
        address token,
        uint256 component,
        bytes calldata proof,
        bytes calldata signature
    ) external view returns (uint256 amount) {
        address registered;
        (amount, registered) = _share(reader, root, index, holder, token, component, proof);
        if (registered != address(0)) {
            if (recipient != registered) revert IXindexVault.WrongRecipient(registered);
        } else {
            _checkSignature(address(this), index, holder, recipient, signature);
        }
    }

    /// @dev `holder`'s share of `token` in `index` at the snapshot, read from the hub's storage under `root`: its shares
    ///      at the units then in force, rounded down, plus its claim of the coin; and its recovery address on this
    ///      chain, zero if none.
    function _share(
        IStateReader reader,
        bytes32 root,
        address index,
        address holder,
        address token,
        uint256 component,
        bytes calldata proof
    ) private view returns (uint256 amount, address registered) {
        // The coin's id on Ethereum, as the factory's `vaultTokenId(chainId, tokenId)` computes it: the native coin's
        // `tokenId` is zero, and a token's is its address.
        address id = address(
            uint160(uint256(keccak256(abi.encode(VAULT_TOKEN_DOMAIN, block.chainid, bytes32(uint256(uint160(token)))))))
        );
        bytes32[] memory slots = new bytes32[](5);
        slots[0] = keccak256(abi.encode(holder, HUB_SHARES));
        slots[1] = bytes32(uint256(keccak256(abi.encode(HUB_COMPONENTS_SLOT))) + component);
        slots[2] = keccak256(abi.encode(id, keccak256(abi.encode(holder, HUB_CLAIMS_SLOT))));
        slots[3] = keccak256(abi.encode(block.chainid, keccak256(abi.encode(holder, HUB_RECOVERY_SLOT))));
        slots[4] = bytes32(HUB_COMPONENTS_SLOT);
        bytes32[] memory v = reader.readSlots(root, index, slots, proof);
        // Inside the components array, whose length the slot itself holds: past it lies any other storage a holder
        // could fill, an allowance included, with whatever "units" it likes (VLT-1).
        if (component >= uint256(v[4]) || address(uint160(uint256(v[1]))) != id) {
            revert IXindexVault.WrongComponent(component);
        }
        amount = uint256(v[0]) * (uint256(v[1]) >> UNITS_SHIFT) / WAD + uint256(v[2]);
        if (amount == 0) revert IXindexVault.ZeroAmount();
        // A value that is no address here counts as none, so a holder that mistyped one can still sign (VLT-I3).
        registered = uint256(v[3]) >> 160 == 0 ? address(uint160(uint256(v[3]))) : address(0);
    }

    /// @dev EIP-712: `holder` signed, with its Ethereum key, that `vault` may pay its snapshot share of `index` to
    ///      `recipient`, every token of it on this chain.
    function _checkSignature(address vault, address index, address holder, address recipient, bytes calldata signature)
        private
        view
    {
        bytes32 domain = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("Xindex vault"), keccak256("1"), block.chainid, vault)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            domain, keccak256(abi.encode(SNAPSHOT_CLAIM_TYPEHASH, index, holder, recipient))
        );
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || signer != holder) revert IXindexVault.BadSignature();
    }
}
