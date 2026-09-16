// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title PathLib
/// @notice Helpers for Uniswap V3 packed swap paths: token(20) | fee(3) | token(20) [| fee(3) | token(20)]...
library PathLib {
    /// @notice Bytes of a token address in a path.
    uint256 internal constant ADDR_SIZE = 20;
    /// @notice Bytes of a fee tier in a path.
    uint256 internal constant FEE_SIZE = 3;
    /// @notice Bytes each hop adds after the first token: a fee tier and the next token.
    uint256 internal constant HOP_SIZE = ADDR_SIZE + FEE_SIZE;

    /// @notice True if `path` has at least one hop and a well-formed length.
    function isValidShape(bytes calldata path) internal pure returns (bool) {
        return path.length >= ADDR_SIZE + HOP_SIZE && (path.length - ADDR_SIZE) % HOP_SIZE == 0;
    }

    /// @notice The first token of `path`. Call only on a path {isValidShape} accepts: a shorter one reverts.
    function firstToken(bytes calldata path) internal pure returns (address) {
        return address(bytes20(path[:ADDR_SIZE]));
    }

    /// @notice The last token of `path`. Call only on a path {isValidShape} accepts: a shorter one reverts.
    function lastToken(bytes calldata path) internal pure returns (address) {
        return address(bytes20(path[path.length - ADDR_SIZE:]));
    }
}
