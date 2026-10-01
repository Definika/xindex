// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IBnbStateVerifier} from "../interfaces/IBnbStateVerifier.sol";
import {RlpReader} from "../libraries/RlpReader.sol";
import {MerklePatricia} from "../libraries/MerklePatricia.sol";
import {Bls12381} from "../libraries/Bls12381.sol";
// Named by the `@inheritdoc` of `verifySlots`, which must name the interface that declares it.
// aderyn-fp-next-line(unused-import)
import {IVaultStateVerifier} from "../interfaces/IVaultStateVerifier.sol";

/// @title BnbStateVerifier
/// @notice BNB Chain's state on Ethereum from the chain's own fast-finality votes, with no zkVM and no trusted setup:
///         BLS12-381 aggregate signatures checked with the EIP-2537 precompiles, and Merkle-Patricia proofs of storage.
///         BNB Chain rotates part of its active validator set at every epoch block (1,000 blocks, 7.5 minutes), so the
///         verifier follows every epoch block, each accepted only with the vote that finalized it, signed by the set
///         it replaces (Stage B spec, section 5.1).
/// @dev No owner, no upgrade. The first set comes from the deployer and is trusted as the chain registry's listing
///      delay lets the owner and guardian check it; every later one is proven. The rules follow bnb-chain/bsc v1.7.8:
///      the switch in `consensus/parlia/snapshot.go`, the vote check in `parlia.go` `verifyVoteAttestation`, the
///      finality rule in `snapshot.go` `updateAttestation`. A fork that changes the epoch length, the extra data or the
///      vote needs a new verifier, rotated in through the registry.
contract BnbStateVerifier is IBnbStateVerifier {
    using RlpReader for RlpReader.Item;

    /// @inheritdoc IBnbStateVerifier
    uint256 public constant EPOCH_LENGTH = 1000;
    /// @inheritdoc IBnbStateVerifier
    uint256 public constant MAX_SPAN = 15 minutes;
    /// @inheritdoc IBnbStateVerifier
    uint256 public constant MAX_LAG = 1 days;
    /// @inheritdoc IBnbStateVerifier
    uint8 public constant NEW_KEY = type(uint8).max;
    /// @dev A vote's bitset is a uint64 on BNB Chain.
    uint256 private constant MAX_VALIDATORS = 64;

    /// @dev Extra data: 32 bytes of vanity, then on an epoch block the validator count, the entries (a 20-byte address
    ///      and a 48-byte compressed BLS key each) and the turn length, then an optional attestation and a 65-byte seal.
    uint256 private constant VANITY = 32;
    uint256 private constant ENTRY = 68;
    uint256 private constant ADDRESS_BYTES = 20;
    uint256 private constant ADDRESS_SHIFT = 96;
    uint256 private constant SEAL = 65;

    /// @dev Header fields read: the state root, the number, the timestamp and the extra data.
    uint256 private constant STATE_ROOT = 3;
    uint256 private constant NUMBER = 8;
    uint256 private constant TIME = 11;
    uint256 private constant EXTRA = 12;

    /// @dev RLP prefixes of the vote data: a list of 56 to 255 bytes, and a 32-byte string.
    bytes1 private constant LONG_LIST_ONE_BYTE = 0xf8;
    bytes1 private constant WORD_STRING = 0xa0;
    uint256 private constant SHORT_STRING = 0x80;
    uint256 private constant BYTE_BITS = 8;
    /// @dev The vote data's two hashes with their prefixes.
    uint256 private constant TWO_WORD_STRINGS = 66;

    /// @inheritdoc IBnbStateVerifier
    uint256 public latestEpoch;

    mapping(uint256 epoch => ValidatorSet) private _sets;

    /// @param epochHeader The RLP header of a recent epoch block, whose set the verifier starts from.
    /// @param keys The uncompressed keys of that set, in the header's order.
    constructor(bytes memory epochHeader, bytes[] memory keys) {
        (FinalHeader memory h, RlpReader.Item memory extra) = _parse(epochHeader);
        bytes memory sources = new bytes(keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            sources[i] = bytes1(NEW_KEY);
        }
        (ValidatorSet memory set,) = _readSet(h, extra, new bytes[](0), sources, keys);
        // Which block the set took over from depends on the set before it, which the verifier never sees; from its
        // own successor's epoch block on it certainly signs, and the first proof of the chain is that block's.
        set.firstTarget = SafeCast.toUint64(h.number + EPOCH_LENGTH);
        _record(h.number, set);
    }

    // ---------------------------------------------------------------------
    // Following the validator set
    // ---------------------------------------------------------------------

    /// @inheritdoc IBnbStateVerifier
    function advance(bytes[] calldata voterKeys, EpochStep[] calldata steps) external {
        uint256 epoch = latestEpoch;
        ValidatorSet memory set = _sets[epoch];
        // A set long superseded may have unbonded and its keys changed hands, and BNB Chain punishes a conflicting
        // vote only for a recent target: such a set must not name the next (BNB-2). A verifier left this far behind
        // stops for good, and the chain registry replaces it.
        if (block.timestamp > uint256(set.time) + MAX_LAG) revert TooOld(set.time);
        bytes[] memory voters = voterKeys;
        _checkKeys(set, voters);
        for (uint256 i = 0; i < steps.length; ++i) {
            (FinalHeader memory h, RlpReader.Item memory extra) = _parse(steps[i].header);
            if (h.number != epoch + EPOCH_LENGTH) revert NotTheNextEpoch(h.number, epoch + EPOCH_LENGTH);
            _checkVote(h, epoch, set, steps[i].vote, voters);
            (ValidatorSet memory next, bytes[] memory keys) =
                _readSet(h, extra, voters, steps[i].keySources, steps[i].newKeys);
            next.firstTarget = SafeCast.toUint64(_windowEnd(epoch, set));
            _record(h.number, next);
            (epoch, set, voters) = (h.number, next, keys);
        }
    }

    /// @dev Reads and checks the set an epoch block lists: its size and turn length, its entries in ascending address
    ///      order, and the uncompressed form of each entry's compressed key, taken from `previous` where `sources`
    ///      points there and from `newKeys` in order otherwise. A key from `previous` was checked on the curve when
    ///      its own set was recorded, so it only has to match; a new one is checked on the curve too.
    function _readSet(
        FinalHeader memory h,
        RlpReader.Item memory extra,
        bytes[] memory previous,
        bytes memory sources,
        bytes[] memory newKeys
    ) private view returns (ValidatorSet memory set, bytes[] memory keys) {
        if (h.number % EPOCH_LENGTH != 0) revert NotAnEpochBlock(h.number);
        uint256 n = extra.byteAt(VANITY);
        uint256 listEnd = VANITY + 1 + n * ENTRY;
        if (n == 0 || n > MAX_VALIDATORS || extra.len < listEnd + 1 + SEAL) revert BadValidatorList();
        uint256 turnLength = extra.byteAt(listEnd);
        // The next epoch block's vote targets its child, which this set must still sign: at least one block of
        // switch delay. BNB Chain's is 87.
        if ((n / 2 + 1) * turnLength < 2) revert BadValidatorList();
        keys = _readKeys(extra, n, previous, sources, newKeys);
        set.keysHash = keccak256(abi.encode(keys));
        set.time = SafeCast.toUint64(h.time);
        set.count = SafeCast.toUint8(n);
        set.turnLength = SafeCast.toUint8(turnLength);
    }

    /// @dev The uncompressed keys of the `n` entries, each matched to its compressed key in order of address.
    function _readKeys(
        RlpReader.Item memory extra,
        uint256 n,
        bytes[] memory previous,
        bytes memory sources,
        bytes[] memory newKeys
    ) private view returns (bytes[] memory keys) {
        if (sources.length != n) revert WrongKeys();
        keys = new bytes[](n);
        uint256 fresh = 0;
        uint256 lastAccount = 0;
        for (uint256 i = 0; i < n; ++i) {
            uint256 at = VANITY + 1 + i * ENTRY;
            uint256 account = uint256(extra.wordAt(at)) >> ADDRESS_SHIFT;
            if (account <= lastAccount) revert NotAscending(i);
            lastAccount = account;
            (keys[i], fresh) = _entryKey(
                extra.slice(at + ADDRESS_BYTES, Bls12381.COMPRESSED_G1), uint8(sources[i]), previous, newKeys, fresh
            );
        }
        if (fresh != newKeys.length) revert WrongKeys();
    }

    /// @dev One entry's key: carried over from `previous` and matched, or the next new key and checked on the curve.
    function _entryKey(
        bytes memory compressed,
        uint8 source,
        bytes[] memory previous,
        bytes[] memory newKeys,
        uint256 fresh
    ) private view returns (bytes memory key, uint256) {
        if (source == NEW_KEY) {
            if (fresh == newKeys.length) revert WrongKeys();
            return (Bls12381.checkKey(compressed, newKeys[fresh]), fresh + 1);
        }
        if (source >= previous.length) revert WrongKeys();
        key = previous[source];
        Bls12381.checkSameKey(compressed, key);
        return (key, fresh);
    }

    function _record(uint256 epoch, ValidatorSet memory set) private {
        _sets[epoch] = set;
        latestEpoch = epoch;
        // The calls before this are staticcalls to precompiles, which cannot re-enter.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ValidatorSetRecorded(epoch, set.keysHash, set.firstTarget, set.count, set.turnLength);
    }

    // ---------------------------------------------------------------------
    // Finality and state
    // ---------------------------------------------------------------------

    /// @inheritdoc IBnbStateVerifier
    function verifyHeader(bytes calldata header, uint256 epoch, Vote calldata vote, bytes[] calldata keys)
        external
        view
        returns (FinalHeader memory)
    {
        return _verifyHeader(header, epoch, vote, keys);
    }

    /// @inheritdoc IVaultStateVerifier
    function verifySlots(address account, bytes32[] calldata slots, bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, uint256 timestamp, bytes32[] memory values)
    {
        StateProof memory p = abi.decode(proof, (StateProof));
        if (p.storageProofs.length != slots.length) revert LengthMismatch();
        FinalHeader memory h = _verifyHeader(p.header, p.epoch, p.vote, p.keys);
        (bool exists, bytes32 root) = MerklePatricia.storageRoot(h.stateRoot, account, p.accountProof);
        values = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; ++i) {
            if (exists) values[i] = MerklePatricia.slotAt(root, slots[i], p.storageProofs[i]);
        }
        return (h.number, h.time, values);
    }

    /// @dev A header is final once a quorum of the set active at its child voted with it as the source and its child
    ///      as the target. The set's window bounds the block number, and `MAX_SPAN` its timestamp: an old set stays
    ///      valid for its own window forever, so without the bound validators from long ago could forge a header
    ///      there dated today. `MAX_LAG` bounds its age, so a set from long ago cannot forge one there dated then
    ///      either, for a reader that takes an old state, as evidence of an outflow or an exit does (BNB-2).
    function _verifyHeader(bytes memory header, uint256 epoch, Vote memory vote, bytes[] memory keys)
        private
        view
        returns (FinalHeader memory h)
    {
        ValidatorSet memory set = _sets[epoch];
        if (set.keysHash == 0) revert UnknownEpoch(epoch);
        _checkKeys(set, keys);
        (h,) = _parse(header);
        if (h.time < set.time || h.time > set.time + MAX_SPAN) revert TimeOutsideWindow(h.time, set.time);
        if (block.timestamp > h.time + MAX_LAG) revert TooOld(h.time);
        _checkVote(h, epoch, set, vote, keys);
    }

    /// @dev Checks a vote whose source is `h` and whose target is its child: the target in `epoch`'s window, the bitset
    ///      within the set, at least two thirds of the set voting, and the aggregate signature on the vote data.
    function _checkVote(
        FinalHeader memory h,
        uint256 epoch,
        ValidatorSet memory set,
        Vote memory vote,
        bytes[] memory keys
    ) private view {
        uint256 target = h.number + 1;
        uint256 end = _windowEnd(epoch, set);
        if (target < set.firstTarget || target >= end) revert TargetOutsideWindow(target, set.firstTarget, end);
        if (vote.bitset >> set.count != 0) revert BadBitset();
        bytes memory aggregate;
        uint256 voters = 0;
        for (uint256 i = 0; i < set.count; ++i) {
            if ((vote.bitset >> i) & 1 == 0) continue;
            aggregate = voters == 0 ? keys[i] : Bls12381.add(aggregate, keys[i]);
            ++voters;
        }
        // BNB Chain's quorum, ceil(2n / 3), divides by the whole set.
        if (3 * voters < 2 * uint256(set.count)) revert NoQuorum(voters, set.count);
        bytes32 message = _voteHash(h.number, h.hash, vote.targetHash);
        if (!Bls12381.verify(aggregate, vote.signature, abi.encodePacked(message))) revert BadSignature();
    }

    function _checkKeys(ValidatorSet memory set, bytes[] memory keys) private pure {
        if (keys.length != set.count || keccak256(abi.encode(keys)) != set.keysHash) revert WrongKeys();
    }

    /// @dev `epoch`'s set signs targets up to its successor's switch: the snapshot takes the next set while applying
    ///      block `next + (n / 2 + 1) * turnLength - 1`, with this set's size and turn length (`snapshot.go` `apply`,
    ///      `minerHistoryCheckLen`), and a vote on target `T` is checked with the snapshot at `T - 1`.
    function _windowEnd(uint256 epoch, ValidatorSet memory set) private pure returns (uint256) {
        return epoch + EPOCH_LENGTH + (uint256(set.count) / 2 + 1) * set.turnLength;
    }

    /// @dev `keccak256(rlp([sourceNumber, sourceHash, targetNumber, targetHash]))`, the target being the source's
    ///      child: BNB Chain's `VoteData.Hash`. The list is always 68 to 84 bytes, so its prefix is 0xf8 and one length
    ///      byte.
    function _voteHash(uint256 number, bytes32 hash, bytes32 targetHash) private pure returns (bytes32) {
        bytes memory source = _rlpUint(number);
        bytes memory target = _rlpUint(number + 1);
        bytes1 length = bytes1(SafeCast.toUint8(source.length + target.length + TWO_WORD_STRINGS));
        return
            keccak256(
                bytes.concat(LONG_LIST_ONE_BYTE, length, source, WORD_STRING, hash, target, WORD_STRING, targetHash)
            );
    }

    /// @dev The RLP of a vote's block number: a string of its big-endian bytes. A vote's source is at least the block
    ///      before a set's first target, and no set's first target is below one epoch length, so the number is never
    ///      below 0x80, which RLP would write as a single byte.
    function _rlpUint(uint256 value) private pure returns (bytes memory out) {
        uint256 len = 0;
        for (uint256 v = value; v != 0; v >>= BYTE_BITS) {
            ++len;
        }
        out = new bytes(len + 1);
        out[0] = bytes1(SafeCast.toUint8(SHORT_STRING + len));
        for (uint256 i = 0; i < len; ++i) {
            out[len - i] = bytes1(SafeCast.toUint8((value >> (BYTE_BITS * i)) & 0xff));
        }
    }

    function _parse(bytes memory header) private pure returns (FinalHeader memory h, RlpReader.Item memory extra) {
        RlpReader.Item memory fields = RlpReader.toItem(header);
        h.hash = keccak256(header);
        h.number = fields.at(NUMBER).toUint();
        h.time = fields.at(TIME).toUint();
        h.stateRoot = fields.at(STATE_ROOT).toBytes32();
        extra = fields.at(EXTRA);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IBnbStateVerifier
    function validatorSet(uint256 epoch) external view returns (ValidatorSet memory) {
        return _sets[epoch];
    }

    /// @inheritdoc IBnbStateVerifier
    function windowEnd(uint256 epoch) external view returns (uint256) {
        ValidatorSet memory set = _sets[epoch];
        if (set.keysHash == 0) revert UnknownEpoch(epoch);
        return _windowEnd(epoch, set);
    }
}
