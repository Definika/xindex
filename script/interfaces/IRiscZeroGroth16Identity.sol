// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice How RISC Zero's Groth16 verifier names itself (risc0/risc0-ethereum, `RiscZeroGroth16Verifier.sol`, 3.0.0),
///         which `DeployVault` reads to refuse any other verifier for P2.
interface IRiscZeroGroth16Identity {
    function VERSION() external view returns (string memory);
    function SELECTOR() external view returns (bytes4);
}
