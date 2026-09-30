// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Proves a storage slot of a contract on an EVM chain (here BNB Chain) from a block hash its finality vote
///         certified: the header must hash to that block hash, its state root anchors the account proof, and the
///         account's storage root anchors the storage proof. A prototype for measuring gas; the proofs are the node
///         lists `eth_getProof` returns. RLP items are located in place, never copied into arrays: a node's list is
///         walked to the one item the path needs.
contract StorageProof {
    error BadHeader();
    error BadProof(uint256 node);
    error BadRlp();

    /// @return value The storage slot's value, left-padded to 32 bytes; zero for a slot the proof shows absent.
    function prove(
        bytes calldata header,
        bytes32 blockHash,
        address account,
        bytes[] calldata accountProof,
        bytes32 slot,
        bytes[] calldata storageProof
    ) external pure returns (bytes32 value) {
        if (keccak256(header) != blockHash) revert BadHeader();
        bytes memory h = header;
        (uint256 hp, uint256 hl, bool hList) = _decode(_start(h));
        if (!hList) revert BadRlp();
        bytes32 stateRoot = _word32(hp, hl, 3);

        (uint256 ap, uint256 al) = _get(stateRoot, keccak256(abi.encodePacked(account)), accountProof);
        if (al == 0) return bytes32(0);
        (uint256 lp, uint256 ll, bool isList) = _decode(ap);
        if (!isList) revert BadRlp();
        bytes32 storageRoot = _word32(lp, ll, 2);

        (uint256 vp, uint256 vl) = _get(storageRoot, keccak256(abi.encodePacked(slot)), storageProof);
        if (vl == 0) return bytes32(0);
        (uint256 p, uint256 len, bool vList) = _decode(vp);
        if (vList || len > 32) revert BadRlp();
        uint256 word;
        assembly ("memory-safe") {
            word := shr(mul(8, sub(32, len)), mload(p))
        }
        value = bytes32(word);
    }

    /// @dev Walks a Merkle-Patricia proof for `key` from `root`. Returns where the value's RLP lies in memory, or a zero
    ///      length when the proof shows the key absent.
    function _get(bytes32 root, bytes32 key, bytes[] calldata proof) internal pure returns (uint256 ptr, uint256 len) {
        uint256 nibble = 0;
        bytes32 expected = root;
        uint256 lp;
        uint256 ll;
        bool embedded = false;
        for (uint256 i = 0; i < proof.length || embedded; ++i) {
            if (!embedded) {
                if (keccak256(proof[i]) != expected) revert BadProof(i);
                bytes memory node = proof[i];
                bool isList;
                (lp, ll, isList) = _decode(_start(node));
                if (!isList) revert BadRlp();
            }
            embedded = false;
            uint256 count = _count(lp, ll);
            uint256 cp;
            uint256 cl;
            bool cList;
            if (count == 17) {
                if (nibble == 64) return _at(lp, ll, 16);
                (cp, cl, cList) = _itemAt(lp, ll, _nibble(key, nibble));
                nibble += 1;
                if (cl == 0 && !cList) return (0, 0);
            } else if (count == 2) {
                (uint256 pp, uint256 pl,) = _itemAt(lp, ll, 0);
                (uint256 pathLen, bool isLeaf, bool matches) = _matchPath(pp, pl, key, nibble);
                if (!matches) return (0, 0);
                nibble += pathLen;
                (cp, cl, cList) = _itemAt(lp, ll, 1);
                if (isLeaf) {
                    if (nibble != 64) revert BadProof(i);
                    return (cp, cl);
                }
            } else {
                revert BadProof(i);
            }
            if (cList) {
                (lp, ll) = (cp, cl);
                embedded = true;
            } else {
                if (cl != 32) revert BadRlp();
                assembly ("memory-safe") {
                    expected := mload(cp)
                }
            }
        }
        revert BadProof(proof.length);
    }

    /// @dev Decodes a hex-prefix path at `ptr` and compares it with `key` from nibble `offset`.
    function _matchPath(uint256 ptr, uint256 len, bytes32 key, uint256 offset)
        private
        pure
        returns (uint256 length, bool isLeaf, bool matches)
    {
        uint256 first;
        assembly ("memory-safe") {
            first := byte(0, mload(ptr))
        }
        uint256 flag = first >> 4;
        isLeaf = flag >= 2;
        bool odd = flag & 1 == 1;
        length = len * 2 - (odd ? 1 : 2);
        matches = offset + length <= 64;
        uint256 start = odd ? 1 : 2; // nibble position of the path's first nibble within the encoding
        for (uint256 j = 0; j < length && matches; ++j) {
            uint256 pos = start + j;
            uint256 b;
            assembly ("memory-safe") {
                b := byte(0, mload(add(ptr, shr(1, pos))))
            }
            uint256 n = pos & 1 == 0 ? b >> 4 : b & 0x0f;
            matches = n == _nibble(key, offset + j);
        }
    }

    function _nibble(bytes32 key, uint256 i) private pure returns (uint256) {
        return (uint256(key) >> (252 - 4 * i)) & 0x0f;
    }

    function _start(bytes memory data) private pure returns (uint256 ptr) {
        assembly ("memory-safe") {
            ptr := add(data, 32)
        }
    }

    /// @dev The RLP item at `ptr`: where its payload starts, how long it is, and whether it is a list.
    function _decode(uint256 ptr) private pure returns (uint256 payload, uint256 len, bool isList) {
        assembly ("memory-safe") {
            let prefix := byte(0, mload(ptr))
            switch lt(prefix, 0x80)
            case 1 {
                payload := ptr
                len := 1
            }
            default {
                switch lt(prefix, 0xb8)
                case 1 {
                    payload := add(ptr, 1)
                    len := sub(prefix, 0x80)
                }
                default {
                    switch lt(prefix, 0xc0)
                    case 1 {
                        let ll := sub(prefix, 0xb7)
                        len := shr(mul(8, sub(32, ll)), mload(add(ptr, 1)))
                        payload := add(add(ptr, 1), ll)
                    }
                    default {
                        isList := 1
                        switch lt(prefix, 0xf8)
                        case 1 {
                            payload := add(ptr, 1)
                            len := sub(prefix, 0xc0)
                        }
                        default {
                            let ll := sub(prefix, 0xf7)
                            len := shr(mul(8, sub(32, ll)), mload(add(ptr, 1)))
                            payload := add(add(ptr, 1), ll)
                        }
                    }
                }
            }
        }
    }

    /// @dev The number of items in the list whose payload is `len` bytes at `ptr`.
    function _count(uint256 ptr, uint256 len) private pure returns (uint256 count) {
        uint256 end = ptr + len;
        while (ptr < end) {
            (uint256 p, uint256 l,) = _decode(ptr);
            ptr = p + l;
            ++count;
        }
        if (ptr != end) revert BadRlp();
    }

    /// @dev The `index`-th item of the list whose payload is `len` bytes at `ptr`.
    function _itemAt(uint256 ptr, uint256 len, uint256 index)
        private
        pure
        returns (uint256 payload, uint256 itemLen, bool isList)
    {
        uint256 end = ptr + len;
        for (uint256 k = 0; ptr < end; ++k) {
            (payload, itemLen, isList) = _decode(ptr);
            if (k == index) return (payload, itemLen, isList);
            ptr = payload + itemLen;
        }
        revert BadRlp();
    }

    function _at(uint256 ptr, uint256 len, uint256 index) private pure returns (uint256, uint256) {
        (uint256 p, uint256 l,) = _itemAt(ptr, len, index);
        return (p, l);
    }

    function _word32(uint256 ptr, uint256 len, uint256 index) private pure returns (bytes32 v) {
        (uint256 p, uint256 l, bool isList) = _itemAt(ptr, len, index);
        if (isList || l != 32) revert BadRlp();
        assembly ("memory-safe") {
            v := mload(p)
        }
    }
}
