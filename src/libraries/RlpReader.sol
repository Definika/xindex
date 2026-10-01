// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Reads RLP in place: an item is where its payload lies in memory and how long it is, never a copy. Every
///         item is checked to lie inside the item that contains it, so a malformed encoding reverts rather than being
///         read past its end.
// Assembly only loads from memory at a position inside an item this library bounds-checked; Solidity cannot read
// memory at an address without it.
// forge-lint: disable-next-item(inline-assembly)
library RlpReader {
    /// @notice An item's payload: `len` bytes at memory address `ptr`, and whether the item is a list.
    struct Item {
        uint256 ptr;
        uint256 len;
        bool isList;
    }

    error BadRlp();

    uint256 private constant WORD = 32;
    uint256 private constant BYTE_BITS = 8;
    /// @dev The first prefix of each encoding: a short string, a long string, a short list, a long list.
    uint256 private constant SHORT_STRING = 0x80;
    uint256 private constant LONG_STRING = 0xb8;
    uint256 private constant SHORT_LIST = 0xc0;
    uint256 private constant LONG_LIST = 0xf8;

    /// @notice The item `data` encodes, which must span all of `data`.
    function toItem(bytes memory data) internal pure returns (Item memory item) {
        uint256 start;
        assembly ("memory-safe") {
            start := data
        }
        start += WORD; // past the length word
        uint256 end = start + data.length;
        uint256 next;
        (item.ptr, item.len, item.isList, next) = _decode(start, end);
        if (next != end) revert BadRlp();
    }

    /// @notice The number of items in `list`.
    function count(Item memory list) internal pure returns (uint256 n) {
        if (!list.isList) revert BadRlp();
        n = 0;
        uint256 ptr = list.ptr;
        uint256 end = list.ptr + list.len;
        while (ptr < end) {
            (,,, ptr) = _decode(ptr, end);
            ++n;
        }
    }

    /// @notice The `index`-th item of `list`.
    function at(Item memory list, uint256 index) internal pure returns (Item memory) {
        if (!list.isList) revert BadRlp();
        uint256 ptr = list.ptr;
        uint256 end = list.ptr + list.len;
        uint256 payload = 0;
        uint256 len = 0;
        bool isList = false;
        for (uint256 k = 0; k <= index; ++k) {
            (payload, len, isList, ptr) = _decode(ptr, end);
        }
        return Item({ptr: payload, len: len, isList: isList});
    }

    /// @notice The byte at `offset` of a string's payload.
    function byteAt(Item memory item, uint256 offset) internal pure returns (uint256) {
        if (item.isList || offset >= item.len) revert BadRlp();
        return _byte(item.ptr + offset);
    }

    /// @notice The 32 bytes at `offset` of a string's payload.
    function wordAt(Item memory item, uint256 offset) internal pure returns (bytes32 word) {
        if (item.isList || offset + WORD > item.len) revert BadRlp();
        uint256 ptr = item.ptr + offset;
        assembly ("memory-safe") {
            word := mload(ptr)
        }
    }

    /// @notice A copy of `len` bytes at `offset` of a string's payload.
    function slice(Item memory item, uint256 offset, uint256 len) internal pure returns (bytes memory out) {
        if (item.isList || offset + len > item.len) revert BadRlp();
        out = _copy(item.ptr + offset, len);
    }

    /// @notice The `n` bytes (1 to 32) at `offset` of a string's payload, as a big-endian number.
    function uintAt(Item memory item, uint256 offset, uint256 n) internal pure returns (uint256) {
        if (item.isList || n == 0 || n > WORD || offset + n > item.len) revert BadRlp();
        return _bigEndian(item.ptr + offset, n);
    }

    /// @notice A 32-byte string, as a word.
    function toBytes32(Item memory item) internal pure returns (bytes32 word) {
        if (item.isList || item.len != WORD) revert BadRlp();
        uint256 ptr = item.ptr;
        assembly ("memory-safe") {
            word := mload(ptr)
        }
    }

    /// @notice A string of at most 32 bytes, as a big-endian number.
    function toUint(Item memory item) internal pure returns (uint256 value) {
        if (item.isList || item.len > WORD) revert BadRlp();
        if (item.len == 0) return 0;
        value = _bigEndian(item.ptr, item.len);
    }

    /// @notice A copy of a string's bytes.
    function toBytes(Item memory item) internal pure returns (bytes memory out) {
        if (item.isList) revert BadRlp();
        out = _copy(item.ptr, item.len);
    }

    function _copy(uint256 src, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        uint256 dst;
        assembly ("memory-safe") {
            dst := out
        }
        dst += WORD; // past the length word
        assembly ("memory-safe") {
            mcopy(dst, src, len)
        }
    }

    /// @dev The item at `ptr`, which must end at or before `end`: where its payload starts, its length, whether it is a
    ///      list, and where the next item starts. In assembly and on the stack, because a proof walks hundreds of
    ///      items: every read is bounded by `end` first, and a length of up to eight bytes cannot overflow a word.
    function _decode(uint256 ptr, uint256 end)
        private
        pure
        returns (uint256 payload, uint256 len, bool isList, uint256 next)
    {
        // Zeroed first so every path assigns them, then set in assembly. `isList` starts false as `payload != 0`, since
        // the linter reads a literal `false` there as a misused constant.
        payload = 0;
        len = 0;
        next = 0;
        isList = payload != 0;
        bool bad;
        assembly ("memory-safe") {
            bad := iszero(lt(ptr, end))
            if iszero(bad) {
                let prefix := byte(0, mload(ptr))
                switch lt(prefix, SHORT_STRING)
                case 1 {
                    payload := ptr
                    len := 1
                }
                default {
                    let long := 0
                    switch lt(prefix, LONG_STRING)
                    case 1 {
                        payload := add(ptr, 1)
                        len := sub(prefix, SHORT_STRING)
                    }
                    default {
                        switch lt(prefix, SHORT_LIST)
                        case 1 { long := sub(prefix, sub(LONG_STRING, 1)) }
                        default {
                            isList := 1
                            switch lt(prefix, LONG_LIST)
                            case 1 {
                                payload := add(ptr, 1)
                                len := sub(prefix, SHORT_LIST)
                            }
                            default { long := sub(prefix, sub(LONG_LIST, 1)) }
                        }
                    }
                    // A long item: its length takes `long` (1 to 8) bytes after the prefix.
                    if long {
                        payload := add(add(ptr, 1), long)
                        bad := gt(payload, end)
                        len := shr(mul(BYTE_BITS, sub(WORD, long)), mload(add(ptr, 1)))
                    }
                }
                next := add(payload, len)
                bad := or(bad, gt(next, end))
            }
        }
        if (bad) revert BadRlp();
    }

    /// @dev The `len` bytes (1 to 32) at `ptr`, as a big-endian number.
    function _bigEndian(uint256 ptr, uint256 len) private pure returns (uint256 value) {
        uint256 shift = BYTE_BITS * (WORD - len);
        assembly ("memory-safe") {
            value := shr(shift, mload(ptr))
        }
    }

    function _byte(uint256 ptr) private pure returns (uint256 b) {
        assembly ("memory-safe") {
            b := byte(0, mload(ptr))
        }
    }
}
