// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Constants and helpers the deploy, listing and test-market scripts share.
library ScriptUtils {
    /// @notice Uniswap V3 fee tiers the listed WETH pools use.
    uint24 internal constant POOL_FEE_LOW = 500;
    uint24 internal constant POOL_FEE_MEDIUM = 3000;

    /// @notice Whether two strings are equal, for mode and symbol checks.
    function same(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
