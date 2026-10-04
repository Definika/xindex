// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultStateVerifier} from "./IVaultStateVerifier.sol";
import {ISP1Verifier} from "./ISP1Verifier.sol";

/// @notice NEAR's state on Ethereum (`design/2026-10-03-near-stellar-interfaces.md`). No NEAR header commits to a
///         contract's storage in a form Ethereum can read cheaply, so a slot is proven by a successful `attest` of the
///         vault: a receipt the vault executed, whose return value is its record of the slots it holds. The receipt's
///         outcome lies under its block's outcome root, the block under the `block_merkle_root` of a final head, and
///         the head is recorded by a Groth16 proof that NEAR's block producers finalized it, each epoch's producers
///         named by the epoch before (`proofs/near`).
interface INearStateVerifier is IVaultStateVerifier {
    /// @notice A Merkle path's step: the sibling, and whether it is the left one.
    struct PathItem {
        bytes32 hash;
        bool left;
    }

    /// @notice `BlockHeaderInnerLite`, as nearcore orders it. Times are in nanoseconds.
    struct InnerLite {
        uint64 height;
        bytes32 epochId;
        bytes32 nextEpochId;
        bytes32 prevStateRoot;
        bytes32 outcomeRoot;
        uint64 timestamp;
        bytes32 nextBpHash;
        bytes32 blockMerkleRoot;
    }

    /// @notice A block's light header: enough to compute its hash.
    struct LiteHeader {
        InnerLite innerLite;
        bytes32 innerRestHash;
        bytes32 prevBlockHash;
    }

    /// @notice A head the verifier recorded, by its `block_merkle_root`: its height and its time in nanoseconds.
    struct Head {
        uint64 height;
        uint64 timestamp;
    }

    /// @notice A successful `attest`: the receipt's outcome, its Merkle path to its chunk's outcome root, that root's
    ///         path to the block's outcome root, the block, the block's path to the recorded head's
    ///         `block_merkle_root`, and the vault's record: its height and time (nanoseconds) when it ran, and the
    ///         values. The verifier writes the outcome and the record from these fields itself; nothing is parsed.
    struct AttestProof {
        bytes32 head;
        bytes32 receiptId;
        bytes32[] receiptIds;
        uint64 gasBurnt;
        uint128 tokensBurnt;
        bytes[] logs;
        PathItem[] outcomePath;
        PathItem[] outcomeRootPath;
        LiteHeader blockHeader;
        PathItem[] blockPath;
        uint64 height;
        uint64 timestamp;
        bytes32[] values;
    }

    event Advanced(
        bytes32 indexed epochId,
        bytes32 producersHash,
        uint256 namedAt,
        bytes32 indexed blockMerkleRoot,
        uint256 height,
        uint256 timestamp
    );

    error ZeroValue();
    /// @notice The producer set in force was named more than MAX_LAG ago (`namedAt`, nanoseconds).
    error TooOld(uint256 namedAt);
    error WrongAnchor(bytes32 epochId, bytes32 producersHash);
    error BadPublicValues();
    /// @notice A proof names a producer set at a time still to come (nanoseconds).
    error NamedInTheFuture(uint256 namedAt);
    error UnknownHead(bytes32 blockMerkleRoot);
    error WrongAccount(address account);
    error LengthMismatch();
    error NotTheOutcome();
    error NotUnderHead();

    /// @notice How long after the producer set in force was named the verifier still takes a proof: a day, about three
    ///         of NEAR's epochs. Left further behind, it stops for good, and the chain registry replaces it.
    function MAX_LAG() external view returns (uint256);

    /// @notice `keccak256("xindex.v4.vault-attest")`, the first word of every `attest` record.
    function ATTEST_DOMAIN() external view returns (bytes32);

    /// @notice SP1's Groth16 verifier v6.0.0, a bare deployment, never SP1's gateway, which has an owner.
    function SP1_VERIFIER() external view returns (ISP1Verifier);

    /// @notice The program's key: `near vkey` of `proofs/near`.
    function PROGRAM_KEY() external view returns (bytes32);

    /// @notice The factory's registry id of the chain (`near:mainnet` or `near:testnet` hashed).
    function CHAIN_ID() external view returns (uint256);

    /// @notice The vault's 32-byte id, `keccak256` of its account id.
    function VAULT_ID() external view returns (bytes32);

    /// @notice The vault's account id, whose receipts the verifier proves.
    function vaultAccount() external view returns (bytes memory);

    /// @notice The epoch whose producers check the next proof, the hash of those producers (`sha256(borsh(...))`), and
    ///         when they were named, in nanoseconds.
    function epochId() external view returns (bytes32);
    function producersHash() external view returns (bytes32);
    function namedAt() external view returns (uint64);

    /// @notice The head recorded under `blockMerkleRoot`; zero if none is.
    function head(bytes32 blockMerkleRoot) external view returns (Head memory);

    /// @notice Anyone, within MAX_LAG of when the producers in force were named. Accepts a Groth16 proof of the
    ///         statement from the stored epoch and producers, moves to the ones it ends at, and records its head.
    /// @param publicValues `abi.encode(epochIn, producersIn, epochOut, producersOut, namedAt, height, timestamp,
    ///        blockMerkleRoot)`, as the program commits them.
    function update(bytes calldata publicValues, bytes calldata proof) external;

    /// @notice The record a successful `attest` returns: `abi.encode(ATTEST_DOMAIN, CHAIN_ID, VAULT_ID, height,
    ///         timestamp, slots, values)`, the height and time (nanoseconds) of the block the vault ran it in.
    function attestRecord(uint64 height, uint64 timestamp, bytes32[] calldata slots, bytes32[] calldata values)
        external
        view
        returns (bytes memory);
}
