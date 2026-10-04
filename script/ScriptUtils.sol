// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISP1Groth16Identity} from "./interfaces/ISP1Groth16Identity.sol";

/// @notice Constants and helpers the deploy, listing and test-market scripts share.
library ScriptUtils {
    /// @notice SP1's Groth16 verifier v6.0.0 names itself by this hash, the circuit its proofs come from.
    bytes32 internal constant SP1_VERIFIER_HASH = 0x0e78f4db7a6771a3a6a7d9c3b0de6fe73d58781368967a7fe84d87aefffec896;
    string internal constant SP1_VERSION = "v6.0.0";

    /// @notice Uniswap V3 fee tiers the listed WETH pools use.
    uint24 internal constant POOL_FEE_LOW = 500;
    uint24 internal constant POOL_FEE_MEDIUM = 3000;

    /// @notice Whether `code` is an EIP-7702 delegation: 0xef0100 followed by the delegate address. Such an account is
    ///         still a key that signs transactions, not a contract. Since EIP-3541 no contract can deploy code that
    ///         starts with 0xef, so the 0xef01 prefix alone identifies a delegation.
    function isDelegatedAccount(bytes memory code) internal pure returns (bool) {
        return code.length >= 2 && code[0] == 0xef && code[1] == 0x01;
    }

    /// @notice Whether two strings are equal, for mode and symbol checks.
    function same(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice Whether `target` answers `query` with exactly `expected`. A static call, compared byte for byte, so a
    ///         missing function, a fallback or a short answer is a no rather than a revert.
    function answers(address target, bytes memory query, bytes memory expected) internal view returns (bool) {
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory answer) = target.staticcall(query);
        return ok && keccak256(answer) == keccak256(expected);
    }

    /// @notice Whether `verifier` names itself SP1's Groth16 verifier v6.0.0. An owned gateway answers neither, so it
    ///         is refused too.
    function isSp1Verifier(address verifier) internal view returns (bool) {
        return answers(verifier, abi.encodeCall(ISP1Groth16Identity.VERIFIER_HASH, ()), abi.encode(SP1_VERIFIER_HASH))
            && answers(verifier, abi.encodeCall(ISP1Groth16Identity.VERSION, ()), abi.encode(SP1_VERSION));
    }
}
