// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Proves, on a vault's chain, that an Ethereum log is in a block that has reached the finality the verifier
///         implements. Each of the two independent proof systems, P1 and P2, implements it over its own proofs of the
///         same log; the vault needs one or both depending on what the message does.
interface IEthereumEventVerifier {
    /// @notice Verifies `proof` and returns the log it proves. Reverts for a proof it cannot verify, including one in a
    ///         format it does not know, so an unknown fork fails closed.
    /// @return emitter The contract on Ethereum that emitted the log.
    /// @return topic0 The log's first topic, its event signature.
    /// @return topic1 The log's second topic.
    /// @return data The log's data.
    function verifyEvent(bytes calldata proof)
        external
        view
        returns (address emitter, bytes32 topic0, bytes32 topic1, bytes memory data);
}
