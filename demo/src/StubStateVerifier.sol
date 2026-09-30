// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// STUB, NOT A PROOF SYSTEM: testnets only (design/2026-09-30-hackathon-plan.md).

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IVaultStateVerifier} from "xindex/interfaces/IVaultStateVerifier.sol";

/// @title StubStateVerifier
/// @notice STUB, NOT A PROOF SYSTEM. Stands in for a vault chain's state verifier on Sepolia in the hackathon
///         demonstration: it accepts any vault state its relayer key signed. Whoever holds the key can make an index
///         mint against deposits nobody made. It must never be a mainnet chain's verifier.
/// @dev A signature covers Sepolia, this verifier and the vault chain, so it proves nothing about another chain.
contract StubStateVerifier is IVaultStateVerifier {
    bytes32 public constant STATE_TYPEHASH = keccak256("xindex.demo.stub-state");
    /// @notice The key whose signature is the whole "proof".
    address public immutable RELAYER;
    /// @notice The vault chain this verifier speaks for, as the factory's registry names it.
    uint256 public immutable VAULT_CHAIN_ID;

    error NotRelayer(address signer);
    error LengthMismatch();

    constructor(address relayer, uint256 vaultChainId) {
        RELAYER = relayer;
        VAULT_CHAIN_ID = vaultChainId;
    }

    /// @param proof `abi.encode(blockNumber, timestamp, values, signature)`.
    function verifySlots(address account, bytes32[] calldata slots, bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, uint256 timestamp, bytes32[] memory values)
    {
        bytes memory signature;
        (blockNumber, timestamp, values, signature) = abi.decode(proof, (uint256, uint256, bytes32[], bytes));
        if (values.length != slots.length) revert LengthMismatch();
        bytes32 digest = stateDigest(account, slots, values, blockNumber, timestamp);
        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(digest), signature);
        if (signer != RELAYER) revert NotRelayer(signer);
    }

    /// @notice What the relayer signs for a state reading, as an EIP-191 personal message.
    function stateDigest(
        address account,
        bytes32[] calldata slots,
        bytes32[] memory values,
        uint256 blockNumber,
        uint256 timestamp
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                STATE_TYPEHASH,
                block.chainid,
                address(this),
                VAULT_CHAIN_ID,
                account,
                slots,
                values,
                blockNumber,
                timestamp
            )
        );
    }
}
