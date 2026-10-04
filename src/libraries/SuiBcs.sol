// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Blake2b} from "./Blake2b.sol";

/// @notice The few of Sui's BCS encodings and digests a state proof needs, each written from typed fields and never
///         parsed, so a field it does not write cannot be proven by it. Every rule names its source in
///         MystenLabs/sui at 3ae8aecf7c175a83aa97da01d491e053a6090a8c and MystenLabs/fastcrypto at
///         576f00e2d466593ad2c643210b09efb5b6d4aff1, and every one is checked on mainnet's own data
///         (`test/fixtures/sui/generate.py`).
///
///         BCS writes integers little-endian, a sequence's or a string's length as ULEB128 before it, an `Option` as
///         a byte 0 or 1, an enum's variant as its ULEB128 index, and a struct as its fields in order. A Sui `Digest`
///         is `serde_as(Bytes)` (sui-types `digests.rs:24-28`), so it is written as a byte string: 0x20, then 32
///         bytes. An object id or address is a fixed array of 32 bytes, written as is.
library SuiBcs {
    error BadLeafIndex(uint256 index);
    error BadBuffer();

    /// @notice A Move object whose type takes no type parameters, `MoveObjectType_::Other(StructTag)` (sui-types
    ///         `base_types.rs:292-294`): its type's package, module and name, the deprecated `has_public_transfer` (the
    ///         type's `store` ability when created, sui-adapter `static_programmable_transactions/execution/
    ///         context.rs:651`), its version, its contents (the Move value's BCS), its owner's BCS (`object.rs:932-944`:
    ///         `Immutable` is variant 3), the transaction that last wrote it and its storage rebate (`MoveObject`,
    ///         `object.rs:55-67`; `ObjectInner`, `object.rs:1084-1097`).
    struct MoveObject {
        bytes32 package;
        string module;
        string name;
        bool hasPublicTransfer;
        uint64 version;
        bytes contents;
        bytes owner;
        bytes32 previousTransaction;
        uint64 storageRebate;
    }

    /// @dev A digest's BCS prefix: its length, 32.
    bytes1 internal constant DIGEST = 0x20;
    /// @dev `Data::Move`, then `MoveObjectType_::Other`, then an empty list of type parameters.
    bytes2 private constant MOVE_OTHER = 0x0000;
    bytes1 private constant NO_TYPE_PARAMS = 0x00;
    bytes1 private constant FALSE = 0x00;
    bytes1 private constant TRUE = 0x01;
    /// @dev `ObjectInner` is serialized under the name `Object` (sui-types `object.rs:1085`), and its digest hashes
    ///      `Object::` before its BCS (`object.rs:1313-1315`; `crypto.rs:1512,1521-1532`).
    bytes8 private constant OBJECT_NAME = "Object::";
    /// @dev fastcrypto `merkle.rs:18-19,496-515`: a leaf is hashed after 0x00, an inner node after 0x01.
    bytes1 private constant LEAF = 0x00;
    bytes1 private constant NODE = 0x01;
    /// @dev `CheckpointArtifactsDigest::from_artifact_digests` (`digests.rs:1091-1095`) hashes the BCS of a
    ///      `Vec<Digest>`: one artifact, the object states' root, so a length of 1 and the root as a digest.
    bytes2 private constant ONE_DIGEST = 0x0120;
    uint256 private constant BYTE_BITS = 7;
    uint256 private constant LOW_SEVEN = 0x7f;
    uint256 private constant CONTINUE = 0x80;
    /// @dev Byte-reversing a u64: swap bytes, then pairs, then halves.
    uint64 private constant ODD_BYTES = 0xFF00FF00_FF00FF00;
    uint64 private constant EVEN_BYTES = 0x00FF00FF_00FF00FF;
    uint64 private constant ODD_PAIRS = 0xFFFF0000_FFFF0000;
    uint64 private constant EVEN_PAIRS = 0x0000FFFF_0000FFFF;
    uint64 private constant BYTE = 8;
    uint64 private constant PAIR = 16;
    uint64 private constant HALF = 32;

    /// @notice An entry of a committee's BCS, `(AuthorityPublicKeyBytes, StakeUnit)`: the compressed key as a byte
    ///         string (its length, 96, then the key; sui-types `crypto.rs:447-450`), then the voting power as a u64.
    uint256 internal constant COMMITTEE_ENTRY = 105;
    /// @notice The bytes a body of entries needs past its last one: `writeCommitteeEntry` writes the power as a word.
    uint256 internal constant ENTRY_SLACK = 24;
    uint256 private constant KEY_LENGTH = 0x60;
    uint256 private constant W1_AT = 33;
    uint256 private constant W2_AT = 65;
    uint256 private constant POWER_AT = 97;
    uint256 private constant BYTES_AT = 32;

    /// @notice A `u64`'s eight little-endian bytes.
    function le64(uint64 v) internal pure returns (bytes8) {
        v = ((v & ODD_BYTES) >> BYTE) | ((v & EVEN_BYTES) << BYTE);
        v = ((v & ODD_PAIRS) >> PAIR) | ((v & EVEN_PAIRS) << PAIR);
        return bytes8((v >> HALF) | (v << HALF));
    }

    /// @notice Writes entry `i` of a committee's body in place: the compressed key `w0 || w1 || w2` and `power`. The
    ///         power's word runs into the next entry, written after it, or into the body's `ENTRY_SLACK`, which the
    ///         caller allocates past the last entry.
    function writeCommitteeEntry(bytes memory body, uint256 i, bytes32 w0, bytes32 w1, bytes32 w2, uint64 power)
        internal
        pure
    {
        if (body.length < (i + 1) * COMMITTEE_ENTRY + ENTRY_SLACK) revert BadBuffer();
        bytes8 le = le64(power);
        // Written in place: Solidity would allocate each entry and copy them all again to join them.
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            let at := add(add(body, BYTES_AT), mul(i, COMMITTEE_ENTRY))
            mstore8(at, KEY_LENGTH)
            mstore(add(at, 1), w0)
            mstore(add(at, W1_AT), w1)
            mstore(add(at, W2_AT), w2)
            mstore(add(at, POWER_AT), le)
        }
    }

    /// @notice `n` in ULEB128: seven bits a byte, low first, the top bit set on every byte but the last.
    function uleb128(uint256 n) internal pure returns (bytes memory out) {
        out = "";
        while (n > LOW_SEVEN) {
            // Seven bits and the continuation bit: a byte.
            // forge-lint: disable-next-line(unsafe-typecast)
            out = bytes.concat(out, bytes1(uint8((n & LOW_SEVEN) | CONTINUE)));
            n >>= BYTE_BITS;
        }
        // At most seven bits are left: a byte.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes.concat(out, bytes1(uint8(n)));
    }

    /// @notice An object's digest, `ObjectDigest`: BLAKE2b-256 of `Object::` and the BCS of `ObjectInner { data:
    ///         Data::Move(MoveObject { type_, has_public_transfer, version, contents }), owner, previous_transaction,
    ///         storage_rebate }` (sui-types `object.rs:1313-1315`; `Data::Move` is variant 0, `object.rs:424-428`).
    function objectDigest(MoveObject memory o) internal view returns (bytes32) {
        bytes memory module = bytes(o.module);
        bytes memory name = bytes(o.name);
        bytes memory bcs = bytes.concat(
            OBJECT_NAME,
            MOVE_OTHER,
            o.package,
            uleb128(module.length),
            module,
            uleb128(name.length),
            name,
            NO_TYPE_PARAMS,
            o.hasPublicTransfer ? TRUE : FALSE,
            le64(o.version),
            uleb128(o.contents.length),
            o.contents
        );
        return Blake2b.hash256(bytes.concat(bcs, o.owner, DIGEST, o.previousTransaction, le64(o.storageRebate)));
    }

    /// @notice An object state's leaf hash in a checkpoint's artifacts tree: the BCS of `(ObjectID, SequenceNumber,
    ///         ObjectDigest)` (sui-types `messages_checkpoint.rs:139-155`), hashed after 0x00. The tree holds every
    ///         object the checkpoint's transactions wrote, deleted or wrapped, at its last version, sorted by id
    ///         (`messages_checkpoint.rs:235-250`, `effects/effects_v2.rs:280-302`); a failed transaction writes only
    ///         its gas object, so an object of a type only the vault creates proves the vault's call succeeded.
    function artifactLeaf(bytes32 objectId, uint64 version, bytes32 digest) internal view returns (bytes32) {
        return Blake2b.hash256(bytes.concat(LEAF, objectId, le64(version), DIGEST, digest));
    }

    /// @notice The root `path` leads `leaf`, the leaf hash at `index`, to: fastcrypto `MerkleProof::compute_root`
    ///         (`merkle.rs:137-159`), each step `blake2b(0x01 ++ left ++ right)`, the side from the index's bit; an odd
    ///         level is closed by a node of 32 zero bytes (`merkle.rs:392-397`), which a path carries as its sibling.
    ///         An index needing more bits than the path has steps is refused, as fastcrypto refuses it.
    function merkleRoot(bytes32 leaf, uint256 index, bytes32[] memory path) internal view returns (bytes32 node) {
        uint256 n = path.length;
        if (index >> n != 0) revert BadLeafIndex(index);
        node = leaf;
        for (uint256 i = 0; i < n; ++i) {
            node = (index >> i) & 1 == 0
                ? Blake2b.hash256(bytes.concat(NODE, node, path[i]))
                : Blake2b.hash256(bytes.concat(NODE, path[i], node));
        }
    }

    /// @notice The `CheckpointArtifactsDigest` a checkpoint commits to, from the root of its object states' tree: its
    ///         one artifact today (sui-types `messages_checkpoint.rs:217-226`).
    function artifactsDigest(bytes32 objectStatesRoot) internal view returns (bytes32) {
        return Blake2b.hash256(bytes.concat(ONE_DIGEST, objectStatesRoot));
    }
}
