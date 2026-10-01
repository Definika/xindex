// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultStateVerifier} from "./IVaultStateVerifier.sol";

/// @notice Tron's state on Ethereum, from the chain's own producers. No Tron header commits to contract storage, so a
///         slot is proven by a call that succeeds only when the vault holds it: a top-level `attest` in a solidified
///         block, whose transaction, result included, the block's transaction root commits to. Tron's peers re-run
///         every contract call and reject a block that misstates its result. A block is solidified once 19 distinct
///         producers of the period's list have built on it. No header names the list, which votes elect again every
///         6 hours, so the verifier follows the lists: each is learned from a full round of 27 slots in its period, and
///         accepted once 19 producers of the list before it have built on that round.
interface ITronStateVerifier is IVaultStateVerifier {
    /// @notice A producer: its account, the witness address its blocks name (without Tron's 0x41 prefix), and the key
    ///         that signs them, which is a separate witness-permission key for some producers.
    struct Producer {
        address witness;
        address key;
    }

    /// @notice A block header's fields, which the verifier encodes as Tron's protobuf `BlockHeader.raw` to hash, and
    ///         the producer's signature over that hash. `producer` is the index of its signer in the list the proof
    ///         names, or `NOT_LISTED` where it counts for nothing. `extra` is whatever unknown fields the producer put
    ///         in `raw`, which Tron keeps, writes after the known ones and hashes; it is appended as it is. Every
    ///         field the verifier reads comes before it and delimits itself, so the hash fixes them whatever `extra`
    ///         holds. `version` is Java's int32, which Tron never checks: a negative one is written in ten bytes.
    struct Header {
        uint64 timestamp;
        bytes32 txTrieRoot;
        bytes32 parentHash;
        uint64 number;
        uint64 witnessId;
        address witness;
        int32 version;
        bytes accountStateRoot;
        bytes extra;
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint8 producer;
    }

    /// @notice A top-level TriggerSmartContract transaction as its block holds it, its result included. The verifier
    ///         writes the call itself: its type, the contract called, no value, the data, and the result SUCCESS. The
    ///         fields here are the rest, which change nothing about what was called: who paid, the reference block,
    ///         the expiry, the time, the fee limit, the permission it used, its signatures, and the fee its result
    ///         records.
    struct Transaction {
        address owner;
        bytes refBlockBytes;
        bytes refBlockHash;
        uint64 expiration;
        uint64 timestamp;
        uint64 feeLimit;
        uint32 permissionId;
        bytes[] signatures;
        uint64 fee;
    }

    /// @notice A call shown in a solidified block: the list that signed (by id, with its producers), the transaction,
    ///         its Merkle path to the block's transaction root (siblings bottom up, bit `i` of `sides` set where
    ///         `path[i]` is the left one), and the block's header followed by the headers built on it.
    struct CallProof {
        uint256 list;
        Producer[] producers;
        Transaction transaction;
        bytes32[] path;
        uint256 sides;
        Header[] headers;
    }

    /// @notice A list recorded: the hash of its producers, its size, and the period it signs, in Tron's milliseconds.
    struct ProducerList {
        bytes32 producersHash;
        uint64 start;
        uint64 end;
        uint8 count;
    }

    event ListRecorded(uint256 indexed id, bytes32 producersHash, uint256 start, uint256 end, uint256 count);

    error UnknownList(uint256 id);
    error WrongProducers();
    error BadList();
    error NotAscending(uint256 index);
    /// @notice A list's period, or a proven block, dated `time` (Tron's milliseconds), more than MAX_LAG ago.
    error TooOld(uint256 time);
    error NotLinked(uint256 index);
    error RoundTooEarly();
    error OutsidePeriod(uint256 index, uint256 time);
    error BadSignature(uint256 index);
    error NotARound();
    error NoQuorum(uint256 signers);
    error NotInBlock();
    error LengthMismatch();

    /// @notice Distinct producers of a list that must build on a block: 19, Tron's own solidity threshold of 70%.
    function QUORUM() external view returns (uint256);

    /// @notice Tron's active producers: 27.
    function MAX_PRODUCERS() external view returns (uint256);

    /// @notice Tron's slot, 3 seconds, in milliseconds.
    function SLOT() external view returns (uint256);

    /// @notice Tron's maintenance interval, 6 hours, in milliseconds. A proposal that changes it changes when lists
    ///         turn over, and needs a new verifier, rotated in through the chain registry.
    function INTERVAL() external view returns (uint256);

    /// @notice How old a proven block, or the latest list when it names the next, may be: 1 day. A verifier left
    ///         further behind stops for good and is replaced through the chain registry.
    function MAX_LAG() external view returns (uint256);

    /// @notice `Header.producer` for a header that counts for nothing.
    function NOT_LISTED() external view returns (uint8);

    /// @notice The latest list recorded.
    function latestList() external view returns (uint256);

    /// @notice List `id`; empty if it was never recorded.
    function producerList(uint256 id) external view returns (ProducerList memory);

    /// @notice Anyone. Records the list of a later period than the latest list's. `currentList` is the latest list's
    ///         producers. `headerList` is a chain of blocks: those from `learnFrom` to before `vouchFrom` are the
    ///         learning round, which spans at least 27 slots, lies in one period after the latest list's, starts at
    ///         least two blocks into it (past its maintenance block and the block after it), and whose distinct signers
    ///         are exactly `nextList`, in ascending witness order; those from `vouchFrom` on must include 19 distinct
    ///         producers of `currentList`, each signing with its listed key, in any period.
    function advance(
        Producer[] calldata currentList,
        Producer[] calldata nextList,
        Header[] calldata headerList,
        uint256 learnFrom,
        uint256 vouchFrom
    ) external;

    /// @notice The SHA-256 of a header's `BlockHeader.raw` as the verifier writes it: what its producer signs, and the
    ///         low 24 bytes of its block id.
    function headerHash(Header calldata h) external pure returns (bytes32);

    /// @notice A TriggerSmartContract transaction of `target` with `data`, result SUCCESS, as the verifier writes it:
    ///         its SHA-256 is its leaf in the block's transaction tree.
    function transactionBytes(Transaction calldata t, address target, bytes calldata data)
        external
        pure
        returns (bytes memory);

    /// @notice Shows a call final: the contract `target` called with `data`, top level, succeeded in a solidified
    ///         block, at `number` and `timestamp` (in seconds). `proof` is an ABI-encoded `CallProof`, `target` and
    ///         `data`.
    function verifyCall(bytes calldata proof)
        external
        view
        returns (uint256 number, uint256 timestamp, address target, bytes memory data);
}
