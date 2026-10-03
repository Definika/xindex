// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {INearStateVerifier} from "../interfaces/INearStateVerifier.sol";
import {ISP1Verifier} from "../interfaces/ISP1Verifier.sol";
// Named by the `@inheritdoc` of `verifySlots`, which must name the interface that declares it.
// aderyn-fp-next-line(unused-import)
import {IVaultStateVerifier} from "../interfaces/IVaultStateVerifier.sol";

/// @title NearStateVerifier
/// @notice NEAR's state on Ethereum, for one vault (`design/2026-10-03-near-stellar-interfaces.md`). A Groth16 proof
///         (SP1, `proofs/near`) shows a chain of NEAR blocks final under each epoch's block producers and records its
///         head's `block_merkle_root`; a slot is then proven by the vault's successful `attest`, its receipt's outcome
///         under a block in that root.
/// @dev No owner, no upgrade. The first epoch and producers come from the deployer, checked during the chain
///      registry's delay as the BNB and TRON verifiers' first sets are; every later set is proven. The encodings follow
///      nearcore: a block's hash `sha256(sha256(sha256(borsh(inner_lite)) ++ inner_rest_hash) ++ prev_hash)`, an
///      outcome's leaf `sha256(borsh(ExecutionOutcomeWithId::to_hashes()))` with the status `SuccessValue` (tag 2), a
///      chunk's outcome root hashed once more under its block's, and Merkle steps `sha256(left ++ right)`, all checked
///      on mainnet's own proofs (`proofs/near/fixtures`). The verifier writes every preimage from typed fields and
///      parses none, so a field it does not write cannot be proven by it.
///
///      An outcome's root lands in a later block than the receipt ran in, one block later or more where chunks were
///      missed, and no light header bounds the run's time from below. So the time a proof shows is the vault's own,
///      from its record: the height and time of the block it ran `attest` in.
contract NearStateVerifier is INearStateVerifier {
    /// @inheritdoc INearStateVerifier
    uint256 public constant MAX_LAG = 1 days;
    /// @inheritdoc INearStateVerifier
    bytes32 public constant ATTEST_DOMAIN = keccak256("xindex.v4.vault-attest");

    /// @dev NEAR's times are in nanoseconds, the EVM's in seconds.
    uint256 private constant NS = 1e9;
    /// @dev `PartialExecutionStatus::SuccessValue`'s Borsh tag.
    bytes1 private constant SUCCESS_VALUE = 0x02;
    /// @dev The public values: eight words.
    uint256 private constant PUBLIC_VALUES_LENGTH = 8 * 32;
    /// @dev An outcome's leaf hashes its id and its partial outcome before its logs.
    uint256 private constant OUTCOME_HASHES = 2;
    /// @dev Borsh's integer widths, in bytes, and a byte's.
    uint256 private constant U32_BYTES = 4;
    uint256 private constant U64_BYTES = 8;
    uint256 private constant U128_BYTES = 16;
    uint256 private constant BYTE_BITS = 8;
    uint256 private constant BYTE_MASK = 0xff;

    ISP1Verifier public immutable SP1_VERIFIER;
    bytes32 public immutable PROGRAM_KEY;
    /// @inheritdoc INearStateVerifier
    uint256 public immutable CHAIN_ID;
    /// @inheritdoc INearStateVerifier
    bytes32 public immutable VAULT_ID;

    /// @inheritdoc INearStateVerifier
    /// @dev Written once, in the constructor; `bytes` cannot be immutable.
    // aderyn-fp-next-line(state-variable-could-be-immutable)
    bytes public vaultAccount;
    /// @inheritdoc INearStateVerifier
    bytes32 public epochId;
    /// @inheritdoc INearStateVerifier
    bytes32 public producersHash;
    /// @inheritdoc INearStateVerifier
    uint64 public namedAt;

    mapping(bytes32 blockMerkleRoot => Head) private _heads;

    /// @param sp1Verifier SP1's Groth16 verifier v6.0.0, a bare deployment, never SP1's gateway.
    /// @param programKey The program's key (`near vkey`).
    /// @param chainId The chain's registry id.
    /// @param account The vault's account id.
    /// @param epoch The epoch the verifier starts from, and `producers` the hash of its block producers.
    /// @param named When a block of the epoch before named those producers, in nanoseconds.
    constructor(
        ISP1Verifier sp1Verifier,
        bytes32 programKey,
        uint256 chainId,
        string memory account,
        bytes32 epoch,
        bytes32 producers,
        uint64 named
    ) {
        if (
            address(sp1Verifier) == address(0) || programKey == bytes32(0) || chainId == 0 || bytes(account).length == 0
                || epoch == bytes32(0) || producers == bytes32(0) || named == 0
        ) revert ZeroValue();
        SP1_VERIFIER = sp1Verifier;
        PROGRAM_KEY = programKey;
        CHAIN_ID = chainId;
        VAULT_ID = keccak256(bytes(account));
        vaultAccount = bytes(account);
        epochId = epoch;
        producersHash = producers;
        namedAt = named;
    }

    // ---------------------------------------------------------------------
    // Following NEAR
    // ---------------------------------------------------------------------

    /// @inheritdoc INearStateVerifier
    function update(bytes calldata publicValues, bytes calldata proof) external {
        uint256 named = namedAt;
        // A set long superseded may have unstaked, and nothing slashes a producer for signing a fork: such a set must
        // not name the next. A verifier left this far behind stops for good, and the chain registry replaces it.
        if (block.timestamp > named / NS + MAX_LAG) revert TooOld(named);
        // A view of the fixed SP1 verifier, by staticcall: it cannot re-enter.
        // aderyn-fp-next-line(reentrancy-state-change)
        SP1_VERIFIER.verifyProof(PROGRAM_KEY, publicValues, proof);
        if (publicValues.length != PUBLIC_VALUES_LENGTH) revert BadPublicValues();
        (
            bytes32 epochIn,
            bytes32 producersIn,
            bytes32 epochOut,
            bytes32 producersOut,
            uint256 namedOut,
            uint256 height,
            uint256 timestamp,
            bytes32 root
        ) = abi.decode(publicValues, (bytes32, bytes32, bytes32, bytes32, uint256, uint256, uint256, bytes32));
        if (epochIn != epochId || producersIn != producersHash) revert WrongAnchor(epochIn, producersIn);
        if (namedOut != 0) {
            // The block that named them is the proof's own, signed by the set before: never dated after now, so that
            // set cannot push its successor's lag beyond a day.
            if (namedOut / NS > block.timestamp) revert NamedInTheFuture(namedOut);
            namedAt = SafeCast.toUint64(namedOut);
        } else if (epochOut != epochIn || producersOut != producersIn) {
            revert BadPublicValues();
        }
        epochId = epochOut;
        producersHash = producersOut;
        _heads[root] = Head({height: SafeCast.toUint64(height), timestamp: SafeCast.toUint64(timestamp)});
        // The call before this is the zkVM verifier's view.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Advanced(epochOut, producersOut, namedAt, root, height, timestamp);
    }

    /// @inheritdoc INearStateVerifier
    function head(bytes32 blockMerkleRoot) external view returns (Head memory) {
        return _heads[blockMerkleRoot];
    }

    // ---------------------------------------------------------------------
    // Proving a slot
    // ---------------------------------------------------------------------

    /// @inheritdoc IVaultStateVerifier
    /// @dev `proof` is `abi.encode(AttestProof)`. `blockNumber` and `timestamp` are the vault's own, from its record:
    ///      the block it ran `attest` in.
    function verifySlots(address account, bytes32[] calldata slots, bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, uint256 timestamp, bytes32[] memory values)
    {
        // The hub passes the low 20 bytes of the vault's 32-byte id.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (account != address(uint160(uint256(VAULT_ID)))) revert WrongAccount(account);
        AttestProof memory p = abi.decode(proof, (AttestProof));
        if (p.values.length != slots.length) revert LengthMismatch();
        bytes memory executor = vaultAccount;
        _proveOutcome(p, executor, _record(p.height, p.timestamp, slots, p.values));
        return (p.height, p.timestamp / NS, p.values);
    }

    /// @inheritdoc INearStateVerifier
    function attestRecord(uint64 height, uint64 timestamp, bytes32[] calldata slots, bytes32[] calldata values)
        external
        view
        returns (bytes memory)
    {
        return _record(height, timestamp, slots, values);
    }

    function _record(uint64 height, uint64 timestamp, bytes32[] memory slots, bytes32[] memory values)
        private
        view
        returns (bytes memory)
    {
        return abi.encode(ATTEST_DOMAIN, CHAIN_ID, VAULT_ID, uint256(height), uint256(timestamp), slots, values);
    }

    /// @dev Reverts unless `p`'s outcome, a receipt `executor` ran that returned `value`, lies under the recorded head:
    ///      outcome, chunk's outcome root, block's outcome root, block hash, the head's `block_merkle_root`. The run's
    ///      height and time must come before the block whose outcome root holds it.
    function _proveOutcome(AttestProof memory p, bytes memory executor, bytes memory value) internal view {
        if (_heads[p.head].height == 0) revert UnknownHead(p.head);
        InnerLite memory lite = p.blockHeader.innerLite;
        if (p.height >= lite.height || p.timestamp >= lite.timestamp) revert NotTheOutcome();
        bytes32 chunkRoot = _root(_outcomeLeaf(p, executor, value), p.outcomePath);
        if (_root(sha256(abi.encodePacked(chunkRoot)), p.outcomeRootPath) != lite.outcomeRoot) revert NotTheOutcome();
        if (_root(_blockHash(p.blockHeader), p.blockPath) != p.head) revert NotUnderHead();
    }

    /// @dev `sha256(borsh(Vec<CryptoHash>))` of the outcome's id, the hash of its `PartialExecutionOutcome` (receipt
    ///      ids, gas burnt, tokens burnt, executor, `SuccessValue(value)`), and each log's hash.
    function _outcomeLeaf(AttestProof memory p, bytes memory executor, bytes memory value)
        private
        pure
        returns (bytes32)
    {
        // Borsh: every variable-length field follows its own length, so no two outcomes pack alike.
        // forge-lint: disable-next-item(encode-packed-collision)
        bytes memory borsh = abi.encodePacked( // aderyn-fp(abi-encode-packed-hash-collision)
            _le32(p.receiptIds.length),
            p.receiptIds,
            _le64(p.gasBurnt),
            _le128(p.tokensBurnt),
            _le32(executor.length),
            executor,
            SUCCESS_VALUE,
            _le32(value.length),
            value
        );
        bytes32 partialOutcome = sha256(borsh);
        uint256 n = p.logs.length;
        bytes32[] memory logs = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            logs[i] = sha256(p.logs[i]);
        }
        return sha256(abi.encodePacked(_le32(OUTCOME_HASHES + n), p.receiptId, partialOutcome, logs));
    }

    /// @dev `sha256(sha256(sha256(borsh(inner_lite)) ++ inner_rest_hash) ++ prev_block_hash)`.
    function _blockHash(LiteHeader memory b) private pure returns (bytes32) {
        InnerLite memory l = b.innerLite;
        bytes32 lite = sha256(
            abi.encodePacked(
                _le64(l.height),
                l.epochId,
                l.nextEpochId,
                l.prevStateRoot,
                l.outcomeRoot,
                _le64(l.timestamp),
                l.nextBpHash,
                l.blockMerkleRoot
            )
        );
        return sha256(abi.encodePacked(sha256(abi.encodePacked(lite, b.innerRestHash)), b.prevBlockHash));
    }

    /// @dev The root `path` leads `leaf` to: each step hashes the sibling on its side.
    function _root(bytes32 leaf, PathItem[] memory path) private pure returns (bytes32 node) {
        node = leaf;
        uint256 n = path.length;
        for (uint256 i = 0; i < n; ++i) {
            node = path[i].left
                ? sha256(abi.encodePacked(path[i].hash, node))
                : sha256(abi.encodePacked(node, path[i].hash));
        }
    }

    /// @dev Borsh's little-endian integers. `_reverse` returns exactly `size` bytes, so each cast keeps all of them.
    function _le32(uint256 x) private pure returns (bytes4) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(uint32(_reverse(x, U32_BYTES)));
    }

    function _le64(uint64 x) private pure returns (bytes8) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes8(uint64(_reverse(x, U64_BYTES)));
    }

    function _le128(uint128 x) private pure returns (bytes16) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes16(uint128(_reverse(x, U128_BYTES)));
    }

    /// @dev The low `size` bytes of `x`, in reverse order.
    function _reverse(uint256 x, uint256 size) private pure returns (uint256 out) {
        out = 0;
        for (uint256 i = 0; i < size; ++i) {
            out = (out << BYTE_BITS) | ((x >> (BYTE_BITS * i)) & BYTE_MASK);
        }
    }
}
