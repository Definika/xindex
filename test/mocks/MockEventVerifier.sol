// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEthereumEventVerifier} from "../../src/interfaces/IEthereumEventVerifier.sol";

/// @notice Stands in for P1 or P2 in tests: a "proof" is the log itself, `abi.encode(emitter, topic0, topic1, data)`,
///         accepted as final unless the verifier is set to refuse, as a real one refuses a proof it cannot verify.
contract MockEventVerifier is IEthereumEventVerifier {
    bool public refuse;

    error Refused();

    function setRefuse(bool refuse_) external {
        refuse = refuse_;
    }

    function verifyEvent(bytes calldata proof)
        external
        view
        returns (address emitter, bytes32 topic0, bytes32 topic1, bytes memory data)
    {
        if (refuse) revert Refused();
        return abi.decode(proof, (address, bytes32, bytes32, bytes));
    }
}
