// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice How SP1's Groth16 verifier names itself (succinctlabs/sp1-contracts, `SP1VerifierGroth16.sol`, v6.0.0), which
///         `DeployVault` reads to refuse any other verifier for P1.
interface ISP1Groth16Identity {
    function VERSION() external view returns (string memory);
    function VERIFIER_HASH() external view returns (bytes32);
}
