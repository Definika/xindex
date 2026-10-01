// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// STUB, NOT A PROOF SYSTEM: testnets only (design/2026-09-30-hackathon-plan.md).

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEthereumEventVerifier} from "xindex/interfaces/IEthereumEventVerifier.sol";

/// @title StubEventVerifier
/// @notice STUB, NOT A PROOF SYSTEM. Stands in for P1 or P2 on a testnet vault chain in the hackathon demonstration: it
///         accepts any Ethereum log or checkpoint its relayer key signed. Whoever holds the key can make the vault pay
///         anything. It must never be a mainnet vault's verifier.
/// @dev A signature covers this chain and this verifier, so one stub's signature is never another's.
contract StubEventVerifier is IEthereumEventVerifier {
    bytes32 public constant EVENT_TYPEHASH = keccak256("xindex.demo.stub-event");
    bytes32 public constant CHECKPOINT_TYPEHASH = keccak256("xindex.demo.stub-checkpoint");
    /// @notice The key whose signature is the whole "proof".
    address public immutable RELAYER;

    error NotRelayer(address signer);

    constructor(address relayer) {
        RELAYER = relayer;
    }

    /// @param proof `abi.encode(blockNumber, emitter, topic0, topic1, data, signature)`.
    function verifyEvent(bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, address emitter, bytes32 topic0, bytes32 topic1, bytes memory data)
    {
        bytes memory signature;
        (blockNumber, emitter, topic0, topic1, data, signature) =
            abi.decode(proof, (uint256, address, bytes32, bytes32, bytes, bytes));
        _check(eventDigest(blockNumber, emitter, topic0, topic1, keccak256(data)), signature);
    }

    /// @param proof `abi.encode(checkpoint, signature)`.
    function verifyCheckpoint(bytes calldata proof) external view returns (Checkpoint memory checkpoint) {
        bytes memory signature;
        (checkpoint, signature) = abi.decode(proof, (Checkpoint, bytes));
        _check(checkpointDigest(checkpoint), signature);
    }

    /// @notice What the relayer signs for a log, as an EIP-191 personal message.
    function eventDigest(uint256 blockNumber, address emitter, bytes32 topic0, bytes32 topic1, bytes32 dataHash)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(EVENT_TYPEHASH, block.chainid, address(this), blockNumber, emitter, topic0, topic1, dataHash)
        );
    }

    /// @notice What the relayer signs for a checkpoint, as an EIP-191 personal message.
    function checkpointDigest(Checkpoint memory c) public view returns (bytes32) {
        return keccak256(
            abi.encode(CHECKPOINT_TYPEHASH, block.chainid, address(this), c.blockNumber, c.timestamp, c.stateRoot)
        );
    }

    function _check(bytes32 digest, bytes memory signature) private view {
        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(digest), signature);
        if (signer != RELAYER) revert NotRelayer(signer);
    }
}
