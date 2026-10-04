// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Proves, on a vault's chain, that an Ethereum log is in a block that has reached the finality the verifier
///         implements. Each of the two independent proof systems, P1 and P2, implements it over its own proofs of the
///         same log; the vault needs one or both depending on what the message does.
interface IEthereumEventVerifier {
    /// @notice An Ethereum execution block that has reached the verifier's finality: its number, its timestamp and its
    ///         state root.
    struct Checkpoint {
        uint64 blockNumber;
        uint64 timestamp;
        bytes32 stateRoot;
    }

    /// @notice The proof system whose proofs this verifier checks, as a fixed tag. A vault refuses P1 and P2 of one
    ///         system, so that one broken system cannot prove a message twice. Self-reported: it catches a mistaken
    ///         pair, while the delays and reviews of a rotation or a successor guard against a dishonest one (B5-03).
    function PROOF_SYSTEM() external view returns (bytes32);

    /// @notice Verifies `proof` and returns the log it proves. Reverts for a proof it cannot verify, including one in a
    ///         format it does not know, so an unknown fork fails closed.
    /// @return blockNumber The number of the Ethereum block the log is in.
    /// @return emitter The contract on Ethereum that emitted the log.
    /// @return topic0 The log's first topic, its event signature.
    /// @return topic1 The log's second topic.
    /// @return data The log's data.
    function verifyEvent(bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, address emitter, bytes32 topic0, bytes32 topic1, bytes memory data);

    /// @notice Verifies `proof` of a final Ethereum block and returns it. Reverts as {verifyEvent} does. For a successor
    ///         pair under stall recovery, a proof of a recent checkpoint is also its proof that the chain of final
    ///         checkpoints from the vault's last one to it was signed by at least two thirds of the stake known at each
    ///         (design 6.9); that is what its review checks.
    function verifyCheckpoint(bytes calldata proof) external view returns (Checkpoint memory);
}
