// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RlpReader} from "./RlpReader.sol";

/// @notice Walks Merkle-Patricia proofs, the node lists `eth_getProof` returns, on an EVM chain's state trie. Every node
///         is authenticated by its hash from the root down, or embedded in an authenticated parent, so the value found
///         is the one the root commits to; a proof that the key is absent returns nothing.
library MerklePatricia {
    using RlpReader for RlpReader.Item;

    error BadProof(uint256 node);

    uint256 private constant KEY_NIBBLES = 64;
    uint256 private constant KEY_BITS = 256;
    uint256 private constant NIBBLE_BITS = 4;
    uint256 private constant NIBBLE_MASK = 0x0f;
    uint256 private constant BRANCH_ITEMS = 17;
    uint256 private constant SHORT_NODE_ITEMS = 2;
    uint256 private constant LEAF_EVEN = 2;
    uint256 private constant LEAF_ODD = 3;

    /// @dev Where a walk stands: the node being read, how many nibbles of the key are used up, the hash the next node
    ///      must have unless it is embedded, and, once the walk is over, what it found.
    struct Cursor {
        RlpReader.Item node;
        uint256 nibble;
        bytes32 expected;
        bool embedded;
        bool done;
        bool found;
        RlpReader.Item value;
    }

    /// @notice The storage root of `account`, proven from `stateRoot`, and whether the account exists.
    function storageRoot(bytes32 stateRoot, address account, bytes[] memory accountProof)
        internal
        pure
        returns (bool exists, bytes32 root)
    {
        RlpReader.Item memory accountRlp;
        (exists, accountRlp) = get(stateRoot, keccak256(abi.encodePacked(account)), accountProof);
        // An account is the list (nonce, balance, storageRoot, codeHash), inside the leaf's value string.
        root = exists ? RlpReader.toItem(accountRlp.toBytes()).at(2).toBytes32() : bytes32(0);
    }

    /// @notice The value of `slot`, proven from an account's storage root; zero for a slot the proof shows absent.
    function slotAt(bytes32 root, bytes32 slot, bytes[] memory storageProof) internal pure returns (bytes32) {
        (bool present, RlpReader.Item memory valueRlp) = get(root, keccak256(abi.encodePacked(slot)), storageProof);
        if (!present) return bytes32(0);
        // A slot's value is its RLP-encoded big-endian integer, inside the leaf's value string.
        return bytes32(RlpReader.toItem(valueRlp.toBytes()).toUint());
    }

    /// @notice The leaf value stored under `key`, if the proof shows one.
    function get(bytes32 root, bytes32 key, bytes[] memory proof)
        internal
        pure
        returns (bool found, RlpReader.Item memory value)
    {
        Cursor memory c;
        c.expected = root;
        uint256 next = 0; // the proof node the next hash reference must match
        while (!c.done) {
            if (!c.embedded) {
                if (next >= proof.length) revert BadProof(next);
                if (keccak256(proof[next]) != c.expected) revert BadProof(next);
                c.node = RlpReader.toItem(proof[next]);
                ++next;
            }
            // An embedded node is part of the proof node that holds it, so an error in either names that one.
            uint256 i = next - 1;
            uint256 n = c.node.count();
            if (n == BRANCH_ITEMS) _branch(c, key, i);
            else if (n == SHORT_NODE_ITEMS) _shortNode(c, key, i);
            else revert BadProof(i);
        }
        return (c.found, c.value);
    }

    /// @dev A branch node: follows the key's next nibble, or ends the walk when that child is empty.
    function _branch(Cursor memory c, bytes32 key, uint256 i) private pure {
        // Keys are 32-byte hashes, so a walk never ends at a branch's own value slot.
        if (c.nibble >= KEY_NIBBLES) revert BadProof(i);
        RlpReader.Item memory child = c.node.at(_nibble(key, c.nibble));
        c.nibble += 1;
        if (!child.isList && child.len == 0) c.done = true;
        else _follow(c, child);
    }

    /// @dev A leaf or an extension: its path must continue the key, else the key is absent.
    function _shortNode(Cursor memory c, bytes32 key, uint256 i) private pure {
        (uint256 length, bool isLeaf, bool matches) = _matchPath(c.node.at(0), key, c.nibble);
        if (!matches) {
            c.done = true;
            return;
        }
        c.nibble += length;
        RlpReader.Item memory child = c.node.at(1);
        if (isLeaf) {
            if (c.nibble != KEY_NIBBLES) revert BadProof(i);
            c.value = child;
            c.found = true;
            c.done = true;
        } else {
            _follow(c, child);
        }
    }

    /// @dev Moves to a child: embedded when it is a list, else by its 32-byte hash.
    function _follow(Cursor memory c, RlpReader.Item memory child) private pure {
        if (child.isList) {
            c.node = child;
            c.embedded = true;
        } else {
            c.expected = child.toBytes32();
            c.embedded = false;
        }
    }

    /// @dev Decodes a hex-prefix path and compares it with `key` from nibble `offset`. The first nibble of the encoding
    ///      is a flag: 0 or 1 an extension, 2 or 3 a leaf, odd when the path has an odd number of nibbles, whose first
    ///      then shares the flag's byte; an even path pads that byte's second nibble with zero. The path's nibbles
    ///      are compared with the key's as two numbers, not one by one.
    function _matchPath(RlpReader.Item memory path, bytes32 key, uint256 offset)
        private
        pure
        returns (uint256 length, bool isLeaf, bool matches)
    {
        uint256 first = path.byteAt(0);
        uint256 flag = first >> NIBBLE_BITS;
        if (flag > LEAF_ODD) revert RlpReader.BadRlp();
        isLeaf = flag >= LEAF_EVEN;
        bool odd = flag & 1 == 1;
        if (!odd && first & NIBBLE_MASK != 0) revert RlpReader.BadRlp();
        uint256 rest = path.len - 1; // bytes after the flag's
        length = 2 * rest + (odd ? 1 : 0);
        matches = offset + length <= KEY_NIBBLES;
        if (!matches) return (length, isLeaf, matches);
        uint256 nibbles = rest == 0 ? 0 : path.uintAt(1, rest);
        if (odd) nibbles |= (first & NIBBLE_MASK) << (NIBBLE_BITS * 2 * rest);
        // The key's nibbles from `offset`, `length` of them; a path of no nibbles matches.
        uint256 segment =
            length == 0 ? 0 : (uint256(key) << (NIBBLE_BITS * offset)) >> (KEY_BITS - NIBBLE_BITS * length);
        matches = nibbles == segment;
    }

    function _nibble(bytes32 key, uint256 i) private pure returns (uint256) {
        return (uint256(key) >> (KEY_BITS - NIBBLE_BITS * (i + 1))) & NIBBLE_MASK;
    }
}
