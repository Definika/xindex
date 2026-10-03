// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NearStateVerifier} from "../../src/verifiers/NearStateVerifier.sol";
import {ISP1Verifier} from "../../src/interfaces/ISP1Verifier.sol";

/// @notice `NearStateVerifier` with its outcome check exposed for any executor and return value, so a test can prove a
///         real mainnet receipt, which no vault ran, through the very code `verifySlots` runs.
contract NearStateVerifierHarness is NearStateVerifier {
    constructor(
        ISP1Verifier sp1Verifier,
        bytes32 programKey,
        uint256 chainId,
        string memory account,
        bytes32 epoch,
        bytes32 producers,
        uint64 named
    ) NearStateVerifier(sp1Verifier, programKey, chainId, account, epoch, producers, named) {}

    function proveOutcome(AttestProof memory p, bytes memory executor, bytes memory value) external view {
        _proveOutcome(p, executor, value);
    }
}
