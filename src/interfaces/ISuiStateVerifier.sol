// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultStateVerifier} from "./IVaultStateVerifier.sol";

/// @notice Sui's state on Ethereum, for one vault (`design/2026-10-04-four-chains-interfaces.md`), with no zkVM: each
///         epoch's committee certifies checkpoints with BLS12-381 min-sig signatures, checked on the EIP-2537
///         precompiles, and the last checkpoint of an epoch names the next committee. No checkpoint commits to a
///         global state root, but each commits to the objects it wrote, so a slot is proven by the vault's successful
///         `attest`: the immutable `Attestation` object it wrote, in the checkpoint's artifacts tree (BLAKE2b, on
///         EIP-152), whose `record` holds the slots and their values.
interface ISuiStateVerifier is IVaultStateVerifier {
    /// @notice A committee: its members' BLS keys, uncompressed in EIP-2537's 256 bytes each and packed, and their
    ///         voting powers, in the committee's order, which is the ascending order of the compressed keys.
    struct Committee {
        bytes keys;
        uint64[] powers;
    }

    /// @notice The committee an end-of-epoch checkpoint names, by where each member's uncompressed key comes from:
    ///         `sources` holds two bytes a member, big-endian, the index of the same key in the committee in force or
    ///         `NEW_KEY` for the next of `newKeys`, packed. Sui's committee changes little from one epoch to the next,
    ///         so most keys are neither sent nor checked on the curve again.
    struct NextCommittee {
        bytes sources;
        bytes newKeys;
        uint64[] powers;
    }

    /// @notice A `CheckpointCommitment`: its variant (0 for the live object set's digest, 1 for the artifacts digest)
    ///         and its digest.
    struct Commitment {
        uint8 kind;
        bytes32 digest;
    }

    /// @notice A `CheckpointSummary`'s fields up to its commitments, in their order (sui-types `messages_checkpoint.rs`),
    ///         and `rest`, the BCS of every field after, written as given. In `verifySlots` that is the end-of-epoch
    ///         data's option and the version-specific data; in `update`, whose checkpoint ends its epoch, everything
    ///         after the next committee, which the verifier writes itself: the next protocol version, the epoch
    ///         commitments and the version-specific data. The previous digest is always present: no checkpoint but
    ///         genesis lacks one.
    struct Checkpoint {
        uint64 epoch;
        uint64 sequenceNumber;
        uint64 networkTotalTransactions;
        bytes32 contentDigest;
        bytes32 previousDigest;
        uint64[4] epochRollingGasCostSummary;
        uint64 timestampMs;
        Commitment[] checkpointCommitments;
        bytes rest;
    }

    /// @notice A quorum's certificate: the aggregate signature, uncompressed (EIP-2537's 128 bytes), and its signers,
    ///         a bitmap over the committee's order: member `i` is bit `i % 256` of word `i / 256`.
    struct Certificate {
        bytes signature;
        uint256[] signers;
    }

    /// @notice A successful `attest`: the committee in force, the checkpoint it certified with its certificate, the
    ///         `Attestation` object's id, version, previous transaction and storage rebate, the vault's record (the
    ///         `Clock`'s time in milliseconds when `attest` ran, and the values), and the object's leaf index and
    ///         Merkle path in the checkpoint's artifacts tree. The verifier writes the object and its record itself.
    struct AttestProof {
        Committee committee;
        Checkpoint checkpoint;
        Certificate certificate;
        bytes32 objectId;
        uint64 version;
        bytes32 previousTransaction;
        uint64 storageRebate;
        uint64 timestampMs;
        bytes32[] values;
        uint256 leafIndex;
        bytes32[] path;
    }

    event CommitteeRecorded(uint256 indexed epoch, bytes32 committeeHash, uint256 epochStartMs);

    error ZeroValue();
    /// @notice The committee in force began its epoch more than MAX_LAG ago (`epochStartMs`, milliseconds).
    error TooOld(uint256 epochStartMs);
    error WrongCommittee();
    error BadCommittee();
    error NotAscending(uint256 index);
    error WrongEpoch(uint256 epoch, uint256 expected);
    /// @notice A checkpoint dated before the epoch in force began (milliseconds).
    error BeforeTheEpoch(uint256 timestampMs);
    /// @notice A checkpoint dated after this block (milliseconds).
    error InTheFuture(uint256 timestampMs);
    error UnknownCommitment(uint256 kind);
    error NoArtifactsDigest();
    error BadSigners();
    error NoQuorum(uint256 votingPower);
    error BadSignature();
    error WrongAccount(address account);
    error LengthMismatch();
    /// @notice A record dated after the checkpoint holding it (milliseconds).
    error AfterTheCheckpoint(uint256 timestampMs, uint256 checkpointMs);
    error NotInCheckpoint();

    /// @notice How long after the committee in force began its epoch the verifier still takes a proof: two days. Sui's
    ///         epochs last 24 hours, so a day would lapse before the next committee is named. Left further behind,
    ///         the verifier stops for good, and the chain registry replaces it.
    function MAX_LAG() external view returns (uint256);

    /// @notice `keccak256("xindex.v4.vault-attest")`, the first word of every `attest` record.
    function ATTEST_DOMAIN() external view returns (bytes32);

    /// @notice Sui's fixed total voting power, 10,000, and the quorum of it a certificate needs, 6,667 (sui-types
    ///         `committee.rs` `TOTAL_VOTING_POWER`, `QUORUM_THRESHOLD`).
    function TOTAL_VOTING_POWER() external view returns (uint256);
    function QUORUM() external view returns (uint256);

    /// @notice `NextCommittee.sources` value for a key that is not in the committee in force.
    function NEW_KEY() external view returns (uint256);

    /// @notice The factory's registry id of the chain (`sui:mainnet` or `sui:testnet` hashed).
    function CHAIN_ID() external view returns (uint256);

    /// @notice The vault's 32-byte id: the id of its shared state object.
    function VAULT_ID() external view returns (bytes32);

    /// @notice The vault's package, whose `vault::Attestation` objects the verifier proves.
    function PACKAGE_ID() external view returns (bytes32);

    /// @notice The epoch whose committee certifies the checkpoints the verifier takes, the hash of that committee
    ///         (`hashCommittee(keys, powers)`), and when the epoch began in milliseconds: the time of the checkpoint
    ///         that ended the epoch before.
    function epoch() external view returns (uint64);
    function epochStartMs() external view returns (uint64);
    function committeeHash() external view returns (bytes32);

    /// @notice `keccak256(abi.encode(keys, powers))`, the hash a committee is stored under.
    function hashCommittee(bytes calldata keys, uint64[] calldata powers) external pure returns (bytes32);

    /// @notice Anyone, within MAX_LAG of the epoch's start. Takes the last checkpoint of the epoch in force,
    ///         certified by its committee `current`, and moves to the next epoch, its committee `next`, which the
    ///         checkpoint names, and its start, the checkpoint's time.
    function update(
        Committee calldata current,
        Checkpoint calldata checkpoint,
        Certificate calldata certificate,
        NextCommittee calldata next
    ) external;

    /// @notice Shows `checkpoint` certified by a quorum of the committee in force, `committee`, in its epoch, and
    ///         returns its sequence number, its time in milliseconds and the artifacts digest it commits to.
    function verifyCheckpoint(Committee calldata committee, Checkpoint calldata checkpoint, Certificate calldata cert)
        external
        view
        returns (uint256 sequenceNumber, uint256 timestampMs, bytes32 artifactsDigest);

    /// @notice The record a successful `attest` writes: `abi.encode(ATTEST_DOMAIN, CHAIN_ID, VAULT_ID, timestampMs,
    ///         slots, values)`, the `Clock`'s time in milliseconds when it ran.
    function attestRecord(uint64 timestampMs, bytes32[] calldata slots, bytes32[] calldata values)
        external
        view
        returns (bytes memory);
}
