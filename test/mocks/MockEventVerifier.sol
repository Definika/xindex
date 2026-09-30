// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEthereumEventVerifier} from "../../src/interfaces/IEthereumEventVerifier.sol";

/// @notice Stands in for P1 or P2 in tests: a "proof" of a log is the log itself, `abi.encode(emitter, topic0, topic1,
///         data)`, and a proof of a checkpoint is the checkpoint, `abi.encode(Checkpoint)`, both accepted as final
///         unless the verifier is set to refuse, as a real one refuses a proof it cannot verify. A log's block is the
///         one set with `setEventBlock`, or the current block while none is.
contract MockEventVerifier is IEthereumEventVerifier {
    bool public refuse;
    uint256 public eventBlock;

    error Refused();

    function setRefuse(bool refuse_) external {
        refuse = refuse_;
    }

    function setEventBlock(uint256 blockNumber) external {
        eventBlock = blockNumber;
    }

    function verifyEvent(bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, address emitter, bytes32 topic0, bytes32 topic1, bytes memory data)
    {
        if (refuse) revert Refused();
        (emitter, topic0, topic1, data) = abi.decode(proof, (address, bytes32, bytes32, bytes));
        blockNumber = eventBlock == 0 ? block.number : eventBlock;
    }

    function verifyCheckpoint(bytes calldata proof) external view returns (Checkpoint memory) {
        if (refuse) revert Refused();
        return abi.decode(proof, (Checkpoint));
    }
}
