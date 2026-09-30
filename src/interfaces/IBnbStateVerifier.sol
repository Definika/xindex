// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultStateVerifier} from "./IVaultStateVerifier.sol";

/// @notice BNB Chain's state on Ethereum, from the chain's own finality votes. BNB Chain rotates part of its validator
///         set at every epoch block, so the verifier follows every one: each epoch block is accepted only with the vote
///         that finalized it, signed by the set it replaces.
interface IBnbStateVerifier is IVaultStateVerifier {
    /// @notice A finality vote: its target block's hash, the voters as a bitset over the set in ascending address
    ///         order, and the aggregate signature, uncompressed (EIP-2537's 256 bytes).
    struct Vote {
        bytes32 targetHash;
        uint256 bitset;
        bytes signature;
    }

    /// @notice The next epoch block, the vote that finalized it, and where each uncompressed key of the set it lists
    ///         comes from: `keySources[i]` is the index of the same key in the set it replaces, or `NEW_KEY` for the
    ///         next of `newKeys`. Most of a set carries over, so most keys are neither sent nor checked on the curve
    ///         again.
    struct EpochStep {
        bytes header;
        Vote vote;
        bytes keySources;
        bytes[] newKeys;
    }

    /// @notice A set recorded from its epoch block: the hash of its uncompressed keys, the first vote target it signs,
    ///         its epoch block's timestamp, its size, and the turn length its epoch block set.
    struct ValidatorSet {
        bytes32 keysHash;
        uint64 firstTarget;
        uint64 time;
        uint8 count;
        uint8 turnLength;
    }

    /// @notice What `verifySlots` takes as its proof: a header, the epoch whose set signs its child, the vote that
    ///         finalized it, that set's uncompressed keys, and Merkle-Patricia proofs of the account and each slot.
    struct StateProof {
        bytes header;
        uint256 epoch;
        Vote vote;
        bytes[] keys;
        bytes[] accountProof;
        bytes[][] storageProofs;
    }

    /// @notice A header shown final.
    struct FinalHeader {
        bytes32 hash;
        uint256 number;
        uint256 time;
        bytes32 stateRoot;
    }

    event ValidatorSetRecorded(
        uint256 indexed epoch, bytes32 keysHash, uint256 firstTarget, uint256 count, uint256 turnLength
    );

    error NotAnEpochBlock(uint256 number);
    error NotTheNextEpoch(uint256 number, uint256 expected);
    error UnknownEpoch(uint256 epoch);
    error WrongKeys();
    error BadValidatorList();
    error NotAscending(uint256 index);
    error TargetOutsideWindow(uint256 target, uint256 firstTarget, uint256 end);
    error TimeOutsideWindow(uint256 time, uint256 epochTime);
    error BadBitset();
    error NoQuorum(uint256 voters, uint256 count);
    error BadSignature();
    error LengthMismatch();

    /// @notice Blocks between epoch blocks: 1,000 since Maxwell.
    function EPOCH_LENGTH() external view returns (uint256);

    /// @notice How long after its epoch block's timestamp a set may sign a proven block: 1 hour.
    function MAX_SPAN() external view returns (uint256);

    /// @notice The latest epoch block recorded.
    function latestEpoch() external view returns (uint256);

    /// @notice The set epoch block `epoch` listed; empty if it was never recorded.
    function validatorSet(uint256 epoch) external view returns (ValidatorSet memory);

    /// @notice The first vote target that `epoch`'s set does not sign: the first its successor signs.
    function windowEnd(uint256 epoch) external view returns (uint256);

    /// @notice `EpochStep.keySources` value for a key that is not in the set before.
    function NEW_KEY() external view returns (uint8);

    /// @notice Anyone. Records the next epoch blocks in order, each with the vote that finalized it. `voterKeys` are
    ///         the uncompressed keys of the latest recorded set, which signs the first step.
    function advance(bytes[] calldata voterKeys, EpochStep[] calldata steps) external;

    /// @notice Shows `header` final: its child was the target of `vote`, signed by a quorum of the set of epoch
    ///         `epoch`, whose uncompressed keys are `keys`, within that set's window and `MAX_SPAN`.
    function verifyHeader(bytes calldata header, uint256 epoch, Vote calldata vote, bytes[] calldata keys)
        external
        view
        returns (FinalHeader memory);
}
