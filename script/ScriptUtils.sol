// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Constants and helpers the deploy, listing and test-market scripts share.
library ScriptUtils {
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
}
