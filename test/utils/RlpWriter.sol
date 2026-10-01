// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Writes RLP for tests: strings, lists and big-endian numbers.
library RlpWriter {
    function str(bytes memory b) internal pure returns (bytes memory) {
        if (b.length == 1 && uint8(b[0]) < 0x80) return b;
        if (b.length < 56) return bytes.concat(bytes1(uint8(0x80 + b.length)), b);
        bytes memory len = be(b.length);
        return bytes.concat(bytes1(uint8(0xb7 + len.length)), len, b);
    }

    function list(bytes[] memory items) internal pure returns (bytes memory) {
        bytes memory payload;
        for (uint256 i = 0; i < items.length; ++i) {
            payload = bytes.concat(payload, items[i]);
        }
        if (payload.length < 56) return bytes.concat(bytes1(uint8(0xc0 + payload.length)), payload);
        bytes memory len = be(payload.length);
        return bytes.concat(bytes1(uint8(0xf7 + len.length)), len, payload);
    }

    /// @notice The minimal big-endian bytes of `x`: empty for zero.
    function be(uint256 x) internal pure returns (bytes memory out) {
        while (x > 0) {
            out = bytes.concat(bytes1(uint8(x)), out);
            x >>= 8;
        }
    }
}
