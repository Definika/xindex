// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISuiStateVerifier} from "../interfaces/ISuiStateVerifier.sol";
import {Bls12381MinSig} from "../libraries/Bls12381MinSig.sol";
import {SuiBcs} from "../libraries/SuiBcs.sol";
// Named by the `@inheritdoc` of `verifySlots`, which must name the interface that declares it.
// aderyn-fp-next-line(unused-import)
import {IVaultStateVerifier} from "../interfaces/IVaultStateVerifier.sol";

/// @title SuiStateVerifier
/// @notice Sui's state on Ethereum, for one vault, with no zkVM and no trusted setup
///         (`design/2026-10-04-four-chains-interfaces.md`): each epoch's committee certifies checkpoints with
///         BLS12-381 min-sig aggregate signatures, checked on the EIP-2537 precompiles, and the last checkpoint of
///         each epoch names the next committee, which the verifier follows. A slot is proven by the vault's
///         successful `attest`: the immutable `<package>::vault::Attestation` object it wrote, a leaf of its
///         checkpoint's artifacts tree, whose `record` holds the slots and their values.
/// @dev No owner, no upgrade. The first committee comes from the deployer, checked during the chain registry's delay as
///      the other verifiers' first sets are; every later one is proven. The rules follow MystenLabs/sui at
///      3ae8aecf7c175a83aa97da01d491e053a6090a8c, each checked on mainnet's own data (`test/fixtures/sui`):
///      - The signed message, `VerificationObligation::add_message` (sui-types `crypto.rs:1584-1596`): the BCS of
///        `IntentMessage { intent: Intent::sui_app(CheckpointSummary), value: summary }`, that is the bytes 2, 0, 0
///        (shared-crypto `intent.rs:58,81,113`) and the summary's BCS (`messages_checkpoint.rs:328-359`), then the
///        epoch as a little-endian u64 (`crypto.rs:1591`).
///      - The certificate, `AuthorityQuorumSignInfo` (`crypto.rs:1236-1243`, checked at `crypto.rs:1309-1377`): an
///        aggregate min-sig signature (fastcrypto `bls12381/min_sig/mod.rs:9`) over that message by the members its
///        signer map names, whose voting power must reach `QUORUM_THRESHOLD`, 6,667 of a fixed 10,000
///        (`committee.rs:40,44`; `crypto.rs:1372`). The signer map, a RoaringBitmap, is not signed, so any encoding
///        of the same set is as sound: the verifier takes a plain bitmap.
///      - The next committee, `EndOfEpochData.next_epoch_committee` (`messages_checkpoint.rs:305-325`): each member
///        a compressed key, a byte string of 96 (`crypto.rs:447-450`), and a u64 voting power, in the committee's
///        order (sui-core `checkpoints/mod.rs:2104`), which `Committee::new` sorts by key and requires to total
///        10,000 (`committee.rs:59-67`) and which a signer map indexes. The verifier requires that order strictly, so
///        its indices are Sui's.
///      - The artifacts digest is the first `CheckpointCommitment::CheckpointArtifactsDigest` of the summary's
///        commitments (`messages_checkpoint.rs:285-288,468-482`); the artifacts tree and the object digest are in
///        `SuiBcs`.
///      The verifier writes every byte it hashes or checks a signature over from typed fields, and parses none; a
///      format it cannot write needs a new verifier, rotated in through the chain registry.
contract SuiStateVerifier is ISuiStateVerifier {
    /// @inheritdoc ISuiStateVerifier
    uint256 public constant MAX_LAG = 2 days;
    /// @inheritdoc ISuiStateVerifier
    bytes32 public constant ATTEST_DOMAIN = keccak256("xindex.v4.vault-attest");
    /// @inheritdoc ISuiStateVerifier
    uint256 public constant TOTAL_VOTING_POWER = 1e4;
    /// @inheritdoc ISuiStateVerifier
    uint256 public constant QUORUM = 6_667;
    /// @inheritdoc ISuiStateVerifier
    uint256 public constant NEW_KEY = type(uint16).max;

    /// @dev Sui's times are in milliseconds, the EVM's in seconds.
    uint256 private constant MS = 1000;
    /// @dev `Intent::sui_app(IntentScope::CheckpointSummary)`: scope 2, version 0, app 0 (shared-crypto `intent.rs`).
    bytes3 private constant INTENT = 0x020000;
    bytes1 private constant SOME = 0x01;
    uint256 private constant COMPRESSED_WORDS = 3;
    /// @dev An uncompressed key, and a next member's source: two bytes, big-endian.
    uint256 private constant KEY = 256;
    uint256 private constant SOURCE = 2;
    uint256 private constant BYTE_BITS = 8;
    uint256 private constant WORD_BITS = 256;
    uint8 private constant ARTIFACTS = 1;
    /// @dev The attestation's type, `<PACKAGE_ID>::vault::Attestation`, and its owner, `Owner::Immutable` (variant 3).
    string private constant MODULE = "vault";
    string private constant NAME = "Attestation";
    bytes private constant IMMUTABLE = hex"03";

    /// @inheritdoc ISuiStateVerifier
    uint256 public immutable CHAIN_ID;
    /// @inheritdoc ISuiStateVerifier
    bytes32 public immutable VAULT_ID;
    /// @inheritdoc ISuiStateVerifier
    bytes32 public immutable PACKAGE_ID;

    /// @inheritdoc ISuiStateVerifier
    uint64 public epoch;
    /// @inheritdoc ISuiStateVerifier
    uint64 public epochStartMs;
    /// @inheritdoc ISuiStateVerifier
    bytes32 public committeeHash;

    /// @param chainId The chain's registry id.
    /// @param vaultId The vault's shared state object's id.
    /// @param packageId The vault's package, immutable since it was published.
    /// @param firstEpoch The epoch the verifier starts from, `committee` the hash of its committee
    ///        (`hashCommittee(keys, powers)`), and `startMs` when it began: the time of the last checkpoint of the
    ///        epoch before, which names that committee.
    constructor(
        uint256 chainId,
        bytes32 vaultId,
        bytes32 packageId,
        uint64 firstEpoch,
        bytes32 committee,
        uint64 startMs
    ) {
        if (chainId == 0 || vaultId == 0 || packageId == 0 || committee == 0 || startMs == 0) {
            revert ZeroValue();
        }
        CHAIN_ID = chainId;
        VAULT_ID = vaultId;
        PACKAGE_ID = packageId;
        epoch = firstEpoch;
        epochStartMs = startMs;
        committeeHash = committee;
    }

    // ---------------------------------------------------------------------
    // Following the committee
    // ---------------------------------------------------------------------

    /// @inheritdoc ISuiStateVerifier
    function update(
        Committee calldata current,
        Checkpoint calldata checkpoint,
        Certificate calldata certificate,
        NextCommittee calldata next
    ) external {
        Committee memory c = current;
        Committee memory n = Committee({keys: _nextKeys(c.keys, next), powers: next.powers});
        bytes memory named = _named(n);
        Checkpoint memory s = checkpoint;
        _verify(c, s, certificate, named);
        bytes32 nextHash = keccak256(abi.encode(n.keys, n.powers));
        uint64 nextEpoch = epoch + 1;
        epoch = nextEpoch;
        epochStartMs = s.timestampMs;
        committeeHash = nextHash;
        // The calls before this are staticcalls to precompiles, which cannot re-enter.
        // forge-lint: disable-next-line(reentrancy-events)
        emit CommitteeRecorded(nextEpoch, nextHash, s.timestampMs);
    }

    /// @dev The next committee's keys, each taken from `current`'s, which are checked against the committee in force,
    ///      or the next of `next.newKeys`, which is checked on the curve here (G2ADD checks its inputs; a sum of them is
    ///      kept only for that). A key carried over was checked when its own committee was recorded.
    function _nextKeys(bytes memory current, NextCommittee memory next) private view returns (bytes memory keys) {
        uint256 count = next.powers.length;
        uint256 known = current.length / KEY;
        uint256 fresh = next.newKeys.length / KEY;
        if (count == 0 || next.sources.length != count * SOURCE || next.newKeys.length % KEY != 0) {
            revert BadCommittee();
        }
        keys = new bytes(count * KEY);
        bytes memory sum = new bytes(KEY);
        uint256 used = 0;
        for (uint256 i = 0; i < count; ++i) {
            uint256 source =
                (uint256(uint8(next.sources[SOURCE * i])) << BYTE_BITS) | uint8(next.sources[SOURCE * i + 1]);
            if (source == NEW_KEY) {
                if (used == fresh) revert BadCommittee();
                Bls12381MinSig.addKey(sum, next.newKeys, used);
                Bls12381MinSig.copyKey(keys, i, next.newKeys, used++);
            } else {
                if (source >= known) revert BadCommittee();
                Bls12381MinSig.copyKey(keys, i, current, source);
            }
        }
        if (used != fresh) revert BadCommittee();
    }

    /// @dev The end-of-epoch data's option and next committee, as the summary holds them: `Some`, the count, then each
    ///      member's compressed key and power. No key may be the identity, the keys must be strictly ascending, and
    ///      the powers 10,000 in all, as `Committee::new` requires.
    function _named(Committee memory n) private pure returns (bytes memory named) {
        uint256 count = n.powers.length;
        bytes memory body = new bytes(count * SuiBcs.COMMITTEE_ENTRY + SuiBcs.ENTRY_SLACK);
        uint256 total = 0;
        bytes32[COMPRESSED_WORDS] memory previous;
        for (uint256 i = 0; i < count; ++i) {
            (bytes32 w0, bytes32 w1, bytes32 w2) = Bls12381MinSig.compressKey(n.keys, i);
            SuiBcs.writeCommitteeEntry(body, i, w0, w1, w2, n.powers[i]);
            if (i != 0 && !_above(w0, w1, w2, previous)) revert NotAscending(i);
            total += n.powers[i];
            (previous[0], previous[1], previous[2]) = (w0, w1, w2);
        }
        if (total != TOTAL_VOTING_POWER) revert BadCommittee();
        uint256 length = count * SuiBcs.COMMITTEE_ENTRY;
        // The slack is dropped: the body is the entries.
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            mstore(body, length)
        }
        named = bytes.concat(SOME, SuiBcs.uleb128(count), body);
    }

    /// @dev Whether the compressed key `a` comes strictly after `b`, byte by byte.
    function _above(bytes32 a0, bytes32 a1, bytes32 a2, bytes32[COMPRESSED_WORDS] memory b)
        private
        pure
        returns (bool)
    {
        if (a0 != b[0]) return a0 > b[0];
        if (a1 != b[1]) return a1 > b[1];
        return a2 > b[2];
    }

    // ---------------------------------------------------------------------
    // Certificates
    // ---------------------------------------------------------------------

    /// @inheritdoc ISuiStateVerifier
    function verifyCheckpoint(Committee calldata committee, Checkpoint calldata checkpoint, Certificate calldata cert)
        external
        view
        returns (uint256 sequenceNumber, uint256 timestampMs, bytes32 artifactsDigest)
    {
        Checkpoint memory s = checkpoint;
        _verify(committee, s, cert, "");
        return (s.sequenceNumber, s.timestampMs, _artifacts(s));
    }

    /// @dev Shows `s` certified by a quorum of the committee in force, `c`, in its epoch, while the verifier still
    ///      follows the chain. `named` is the summary's next committee as `_named` writes it, for the last checkpoint
    ///      of an epoch, or empty.
    function _verify(Committee memory c, Checkpoint memory s, Certificate memory cert, bytes memory named)
        private
        view
    {
        uint256 start = epochStartMs;
        // A committee long superseded may have unstaked, and nothing slashes a validator's principal: such a committee
        // must not name the next or certify a state. A verifier left this far behind stops for good, and the chain
        // registry replaces it.
        if (block.timestamp > start / MS + MAX_LAG) revert TooOld(start);
        uint256 n = c.powers.length;
        if (c.keys.length != n * Bls12381MinSig.G2_POINT || keccak256(abi.encode(c.keys, c.powers)) != committeeHash) {
            revert WrongCommittee();
        }
        uint256 current = epoch;
        if (s.epoch != current) revert WrongEpoch(s.epoch, current);
        if (s.timestampMs < start) revert BeforeTheEpoch(s.timestampMs);
        // The time is signed by the committee itself: never after now, so it cannot push its successor's lag beyond
        // two days, nor date a state ahead of Ethereum.
        if (s.timestampMs / MS > block.timestamp) revert InTheFuture(s.timestampMs);
        bytes memory message = bytes.concat(INTENT, _summaryPrefix(s), named, s.rest, SuiBcs.le64(s.epoch));
        _checkCertificate(c, cert, message);
    }

    /// @dev The first artifacts digest `s` commits to, as `checkpoint_artifacts_digest` finds it, or zero.
    function _artifacts(Checkpoint memory s) private pure returns (bytes32) {
        Commitment[] memory list = s.checkpointCommitments;
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i].kind == ARTIFACTS) return list[i].digest;
        }
        return 0;
    }

    /// @dev The summary's BCS up to its commitments.
    function _summaryPrefix(Checkpoint memory s) private pure returns (bytes memory prefix) {
        Commitment[] memory list = s.checkpointCommitments;
        bytes memory commitments = SuiBcs.uleb128(list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            // Both variants hold one digest; another would need a new verifier.
            if (list[i].kind > ARTIFACTS) revert UnknownCommitment(list[i].kind);
            commitments = bytes.concat(commitments, bytes1(list[i].kind), SuiBcs.DIGEST, list[i].digest);
        }
        uint64[4] memory gas = s.epochRollingGasCostSummary;
        bytes memory head = bytes.concat(
            SuiBcs.le64(s.epoch),
            SuiBcs.le64(s.sequenceNumber),
            SuiBcs.le64(s.networkTotalTransactions),
            SuiBcs.DIGEST,
            s.contentDigest,
            SOME,
            SuiBcs.DIGEST,
            s.previousDigest
        );
        prefix = bytes.concat(
            head,
            SuiBcs.le64(gas[0]),
            SuiBcs.le64(gas[1]),
            SuiBcs.le64(gas[2]),
            SuiBcs.le64(gas[3]),
            SuiBcs.le64(s.timestampMs),
            commitments
        );
    }

    /// @dev The signers, a bitmap over `c`'s members with no bit past them, must hold a quorum of the voting power and
    ///      have signed `message` together.
    function _checkCertificate(Committee memory c, Certificate memory cert, bytes memory message) private view {
        uint256 n = c.powers.length;
        uint256[] memory words = cert.signers;
        uint256 tail = n % WORD_BITS;
        if (words.length != (n + WORD_BITS - 1) / WORD_BITS || (tail != 0 && words[words.length - 1] >> tail != 0)) {
            revert BadSigners();
        }
        bytes memory sum = new bytes(Bls12381MinSig.G2_POINT);
        uint256 power = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((words[i / WORD_BITS] >> (i % WORD_BITS)) & 1 == 0) continue;
            Bls12381MinSig.addKey(sum, c.keys, i);
            power += c.powers[i];
        }
        if (power < QUORUM) revert NoQuorum(power);
        if (!Bls12381MinSig.verify(sum, cert.signature, message)) revert BadSignature();
    }

    // ---------------------------------------------------------------------
    // Proving a slot
    // ---------------------------------------------------------------------

    /// @inheritdoc IVaultStateVerifier
    /// @dev `proof` is `abi.encode(AttestProof)`. `blockNumber` is the checkpoint's sequence number and `timestamp` the
    ///      vault's own, from its record: the `Clock` when `attest` ran.
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
        // `attest` ran in a transaction the checkpoint holds, and a transaction's `Clock` is its consensus commit's
        // time, never after the checkpoint's (sui-core `checkpoints/mod.rs`).
        if (p.timestampMs > p.checkpoint.timestampMs) {
            revert AfterTheCheckpoint(p.timestampMs, p.checkpoint.timestampMs);
        }
        _verify(p.committee, p.checkpoint, p.certificate, "");
        bytes32 artifacts = _artifacts(p.checkpoint);
        if (artifacts == 0) revert NoArtifactsDigest();
        bytes memory record = _record(p.timestampMs, slots, p.values);
        bytes32 digest = SuiBcs.objectDigest(
            SuiBcs.MoveObject({
                package: PACKAGE_ID,
                module: MODULE,
                name: NAME,
                hasPublicTransfer: false,
                version: p.version,
                // `Attestation { id: UID, record: vector<u8> }`: the id, then the record as a byte string.
                contents: bytes.concat(p.objectId, SuiBcs.uleb128(record.length), record),
                owner: IMMUTABLE,
                previousTransaction: p.previousTransaction,
                storageRebate: p.storageRebate
            })
        );
        bytes32 root = SuiBcs.merkleRoot(SuiBcs.artifactLeaf(p.objectId, p.version, digest), p.leafIndex, p.path);
        if (SuiBcs.artifactsDigest(root) != artifacts) revert NotInCheckpoint();
        return (p.checkpoint.sequenceNumber, p.timestampMs / MS, p.values);
    }

    /// @inheritdoc ISuiStateVerifier
    function attestRecord(uint64 timestampMs, bytes32[] calldata slots, bytes32[] calldata values)
        external
        view
        returns (bytes memory)
    {
        return _record(timestampMs, slots, values);
    }

    function _record(uint64 timestampMs, bytes32[] memory slots, bytes32[] memory values)
        private
        view
        returns (bytes memory)
    {
        return abi.encode(ATTEST_DOMAIN, CHAIN_ID, VAULT_ID, uint256(timestampMs), slots, values);
    }

    /// @inheritdoc ISuiStateVerifier
    function hashCommittee(bytes calldata keys, uint64[] calldata powers) external pure returns (bytes32) {
        return keccak256(abi.encode(keys, powers));
    }
}
