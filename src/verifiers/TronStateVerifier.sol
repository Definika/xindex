// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ITronStateVerifier} from "../interfaces/ITronStateVerifier.sol";
import {IVaultStateVerifier} from "../interfaces/IVaultStateVerifier.sol";
import {IXindexVault} from "../interfaces/IXindexVault.sol";

/// @title TronStateVerifier
/// @notice Tron's state on Ethereum, from the chain's own producers, with no zkVM and no trusted setup: SHA-256 for
///         Tron's block ids and transaction tree, and `ecrecover` for its producers' secp256k1 signatures (Stage B
///         spec, section 5.7). A vault slot is proven by a successful top-level `attest` call in a solidified block.
/// @dev No owner, no upgrade. The first list comes from the deployer and is trusted as the chain registry's listing
///      delay lets the owner and guardian check it; every later one is learned and proven. The rules follow java-tron
///      at b33eed8: the block id and signature in `BlockCapsule`, the transaction tree and its leaves in `MerkleTree`
///      and `TransactionCapsule.getMerkleHash`, the result check in `TransactionTrace.check`, the schedule in
///      `DposSlot`, the maintenance in `MaintenanceManager.applyBlock` and `updateNextMaintenanceTime`, and
///      solidity in `DposService.updateSolidBlock`.
///
///      The verifier never parses Tron's protobuf: it writes each header and transaction itself from typed fields,
///      as Java's protobuf writes them (fields ascending, zero scalars and empty strings left out), and hashes that.
///      Anything a proof leaves out or adds makes the hash differ, so it fails closed. A header or transaction
///      carrying a field the verifier does not write, as a later fork might add, cannot be proven by it, and needs a
///      new verifier.
contract TronStateVerifier is ITronStateVerifier {
    /// @inheritdoc ITronStateVerifier
    uint256 public constant QUORUM = 19;
    /// @inheritdoc ITronStateVerifier
    uint256 public constant MAX_PRODUCERS = 27;
    /// @inheritdoc ITronStateVerifier
    uint256 public constant SLOT = 3000;
    /// @inheritdoc ITronStateVerifier
    uint256 public constant INTERVAL = 6 hours * MS;
    /// @inheritdoc ITronStateVerifier
    uint256 public constant MAX_LAG = 1 days;
    /// @inheritdoc ITronStateVerifier
    uint8 public constant NOT_LISTED = type(uint8).max;

    /// @dev Tron's times are in milliseconds, TVM's `block.timestamp` in seconds.
    uint256 private constant MS = 1000;
    /// @dev How many of a period's blocks come before its learning round: the maintenance block, run under the old
    ///      list, and the block after it, which is scheduled two slots behind its own time, since `DposSlot.getTime`
    ///      adds the two skipped slots to the slot count and `getScheduledWitness` never takes them back. From the next
    ///      block on, the schedule is the slot modulo 27.
    uint256 private constant BEFORE_ROUND = 2;
    /// @dev The byte before every Tron address.
    bytes1 private constant ADDRESS_PREFIX = 0x41;
    /// @dev `ContractType.TriggerSmartContract`, and `contractResult.SUCCESS`.
    uint256 private constant TRIGGER_SMART_CONTRACT = 31;
    uint256 private constant SUCCESS = 1;
    bytes private constant TRIGGER_TYPE_URL = "type.googleapis.com/protocol.TriggerSmartContract";
    /// @dev The low 192 bits of a block id are its header hash's; the high 64 its number.
    uint256 private constant NUMBER_SHIFT = 192;
    uint256 private constant ID_HASH_MASK = (1 << NUMBER_SHIFT) - 1;
    uint256 private constant ECRECOVER_V = 27;
    /// @dev A varint carries 7 bits a byte, the high bit set on every byte but the last.
    uint256 private constant VARINT_BITS = 7;
    uint256 private constant VARINT_MASK = 0x7f;
    uint256 private constant VARINT_MORE = 0x80;

    /// @dev Protobuf keys, `field << 3 | wire type`: a varint (0) or a length-delimited string (2).
    bytes private constant F1_VARINT = hex"08";
    bytes private constant F1_BYTES = hex"0a";
    bytes private constant F2_BYTES = hex"12";
    bytes private constant F3_VARINT = hex"18";
    bytes private constant F3_BYTES = hex"1a";
    bytes private constant F4_BYTES = hex"22";
    bytes private constant F5_VARINT = hex"28";
    bytes private constant F5_BYTES = hex"2a";
    bytes private constant F7_VARINT = hex"38";
    bytes private constant F8_VARINT = hex"40";
    bytes private constant F9_BYTES = hex"4a";
    bytes private constant F10_VARINT = hex"50";
    bytes private constant F11_BYTES = hex"5a";
    bytes private constant F14_VARINT = hex"70";
    bytes private constant F18_VARINT = hex"9001";

    /// @inheritdoc ITronStateVerifier
    uint256 public latestList;

    mapping(uint256 id => ProducerList) private _lists;

    /// @param producers The producers of the period in progress, in ascending witness order.
    /// @param nextMaintenance When that period ends: the chain's `getnextmaintenancetime`, in milliseconds.
    constructor(Producer[] memory producers, uint64 nextMaintenance) {
        _checkNewList(producers);
        uint256 start = uint256(nextMaintenance) - INTERVAL;
        _record(0, producers, start, nextMaintenance);
    }

    // ---------------------------------------------------------------------
    // Following the list
    // ---------------------------------------------------------------------

    /// @inheritdoc ITronStateVerifier
    function advance(
        Producer[] calldata currentList,
        Producer[] calldata nextList,
        Header[] calldata headerList,
        uint256 learnFrom,
        uint256 vouchFrom
    ) external {
        (Producer[] memory current, Producer[] memory next, Header[] memory headers) =
            (currentList, nextList, headerList);
        uint256 id = latestList;
        ProducerList memory list = _lists[id];
        // A list long superseded may have lost its votes and its keys changed hands, and nothing slashes a producer
        // for signing a fork: such a list must not name the next. A verifier left this far behind stops for good, and
        // the chain registry replaces it.
        if (block.timestamp > uint256(list.start) / MS + MAX_LAG) revert TooOld(list.start);
        _checkProducers(list, current);
        _checkNewList(next);
        if (learnFrom < BEFORE_ROUND || vouchFrom <= learnFrom || vouchFrom > headers.length) revert NotARound();

        bytes32[] memory hashes = _link(headers);
        (uint256 start, uint256 end) = _roundPeriod(headers, learnFrom, vouchFrom, list.end);
        _learn(headers, hashes, next, learnFrom, vouchFrom);
        // Vouching: 19 producers of the list before, at least one of them honest, built on the whole round, and an
        // honest producer builds only on blocks each signed by the producer the schedule names, with its key. When
        // they do so does not matter, so a period of absent producers, or a halt, delays the next list but does not
        // stop it.
        uint256 count = _popcount(_signers(headers, hashes, current, vouchFrom));
        if (count < QUORUM) revert NoQuorum(count);

        _record(id + 1, next, start, end);
    }

    /// @dev The period the learning round lies in, on the grid `updateNextMaintenanceTime` keeps from the latest list's
    ///      end: one after the latest list's, and not necessarily the next, so a halt or a list that cannot be learned
    ///      in time is passed over. The round lies within it, and the block two before the round does too, so that
    ///      period's maintenance block and the block after it both come before the round.
    function _roundPeriod(Header[] memory headers, uint256 learnFrom, uint256 vouchFrom, uint256 listEnd)
        private
        pure
        returns (uint256 start, uint256 end)
    {
        uint256 first = headers[learnFrom].timestamp;
        if (first < listEnd) revert RoundTooEarly();
        uint256 late = first - listEnd;
        start = listEnd + late - late % INTERVAL;
        end = start + INTERVAL;
        if (headers[learnFrom - BEFORE_ROUND].timestamp < start) revert RoundTooEarly();
        for (uint256 i = learnFrom; i < vouchFrom; ++i) {
            if (headers[i].timestamp >= end) revert OutsidePeriod(i, headers[i].timestamp);
        }
    }

    /// @dev The learning round's signers are exactly `next`. Over 27 consecutive slots the schedule names every active
    ///      producer once (`DposSlot.getScheduledWitness`), so a round that spans them leaves out only a producer that
    ///      missed its slot, and names each producer once, so a key changed mid-round cannot make it ambiguous.
    function _learn(
        Header[] memory headers,
        bytes32[] memory hashes,
        Producer[] memory next,
        uint256 learnFrom,
        uint256 vouchFrom
    ) private pure {
        uint256 learned = 0;
        for (uint256 i = learnFrom; i < vouchFrom; ++i) {
            uint256 at = headers[i].producer;
            if (at >= next.length) revert BadSignature(i);
            _checkSigner(headers[i], hashes[i], next[at], i);
            learned |= 1 << at;
        }
        if (learned != (1 << next.length) - 1) revert WrongProducers();
        if (headers[vouchFrom - 1].timestamp < headers[learnFrom].timestamp + (MAX_PRODUCERS - 1) * SLOT) {
            revert NotARound();
        }
    }

    function _checkNewList(Producer[] memory producers) private pure {
        uint256 n = producers.length;
        if (n < QUORUM || n > MAX_PRODUCERS) revert BadList();
        address last = address(0);
        for (uint256 i = 0; i < n; ++i) {
            if (producers[i].witness <= last) revert NotAscending(i);
            if (producers[i].key == address(0)) revert BadList();
            last = producers[i].witness;
        }
    }

    function _checkProducers(ProducerList memory list, Producer[] memory producers) private pure {
        if (producers.length != list.count || keccak256(abi.encode(producers)) != list.producersHash) {
            revert WrongProducers();
        }
    }

    function _record(uint256 id, Producer[] memory producers, uint256 start, uint256 end) private {
        bytes32 producersHash = keccak256(abi.encode(producers));
        _lists[id] = ProducerList({
            producersHash: producersHash,
            start: SafeCast.toUint64(start),
            end: SafeCast.toUint64(end),
            count: SafeCast.toUint8(producers.length)
        });
        latestList = id;
        // The calls before this are staticcalls to precompiles, which cannot re-enter.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ListRecorded(id, producersHash, start, end, producers.length);
    }

    // ---------------------------------------------------------------------
    // Calls and state
    // ---------------------------------------------------------------------

    /// @inheritdoc IVaultStateVerifier
    /// @dev `proof` is an ABI-encoded `CallProof` and the values: the proven call is the vault's
    ///      `attest(slots, values)`, which reverts unless every slot holds its value.
    function verifySlots(address account, bytes32[] calldata slots, bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, uint256 timestamp, bytes32[] memory values)
    {
        CallProof memory p;
        (p, values) = abi.decode(proof, (CallProof, bytes32[]));
        if (values.length != slots.length) revert LengthMismatch();
        bytes memory data = abi.encodeCall(IXindexVault.attest, (slots, values));
        (blockNumber, timestamp) = _verifyCall(p, account, data);
    }

    /// @inheritdoc ITronStateVerifier
    function verifyCall(bytes calldata proof)
        external
        view
        returns (uint256 number, uint256 timestamp, address target, bytes memory data)
    {
        CallProof memory p;
        (p, target, data) = abi.decode(proof, (CallProof, address, bytes));
        (number, timestamp) = _verifyCall(p, target, data);
    }

    /// @dev A call is final once its transaction, as written here with the result SUCCESS, is a leaf of its block's
    ///      transaction tree, and 19 distinct producers of the list built on that block within the list's period. The
    ///      period bounds the block's time, so producers of an old list cannot sign a block dated later; `MAX_LAG`
    ///      bounds its age, so they cannot forge one dated then either, for a reader that takes an old state.
    function _verifyCall(CallProof memory p, address target, bytes memory data)
        private
        view
        returns (uint256 number, uint256 timestamp)
    {
        ProducerList memory list = _lists[p.list];
        if (list.producersHash == 0) revert UnknownList(p.list);
        _checkProducers(list, p.producers);
        Header[] memory headers = p.headers;
        if (headers.length == 0) revert NoQuorum(0);
        // A leaf is the SHA-256 of a whole transaction and an inner node that of two 32-byte hashes, with nothing to
        // tell them apart; a transaction written here is always longer than 64 bytes, so it is never an inner node.
        bytes32 node = sha256(_transaction(p.transaction, target, data));
        if (p.sides >> p.path.length != 0) revert NotInBlock();
        for (uint256 i = 0; i < p.path.length; ++i) {
            node =
                (p.sides >> i) & 1 == 1 ? sha256(bytes.concat(p.path[i], node)) : sha256(bytes.concat(node, p.path[i]));
        }
        if (node != headers[0].txTrieRoot) revert NotInBlock();

        bytes32[] memory hashes = _link(headers);
        for (uint256 i = 0; i < headers.length; ++i) {
            if (headers[i].timestamp < list.start || headers[i].timestamp >= list.end) {
                revert OutsidePeriod(i, headers[i].timestamp);
            }
        }
        uint256 count = _popcount(_signers(headers, hashes, p.producers, 0));
        if (count < QUORUM) revert NoQuorum(count);
        timestamp = headers[0].timestamp / MS;
        if (block.timestamp > timestamp + MAX_LAG) revert TooOld(headers[0].timestamp);
        number = headers[0].number;
    }

    // ---------------------------------------------------------------------
    // Headers
    // ---------------------------------------------------------------------

    /// @dev Each header's hash, every one after the first required to name the one before as its parent.
    function _link(Header[] memory headers) private pure returns (bytes32[] memory hashes) {
        hashes = new bytes32[](headers.length);
        for (uint256 i = 0; i < headers.length; ++i) {
            hashes[i] = sha256(_header(headers[i]));
            if (i > 0 && headers[i].parentHash != _blockId(headers[i - 1].number, hashes[i - 1])) revert NotLinked(i);
        }
    }

    /// @dev The producers of `list` that signed headers from `from` on, as a bitset over the list. A header marked
    ///      `NOT_LISTED` counts for nothing; any other must be signed by the producer it names, with its listed key.
    function _signers(Header[] memory headers, bytes32[] memory hashes, Producer[] memory list, uint256 from)
        private
        pure
        returns (uint256 signers)
    {
        signers = 0;
        for (uint256 i = from; i < headers.length; ++i) {
            uint256 at = headers[i].producer;
            if (at == NOT_LISTED) continue;
            if (at >= list.length) revert BadSignature(i);
            _checkSigner(headers[i], hashes[i], list[at], i);
            signers |= 1 << at;
        }
    }

    /// @dev The header names `producer`'s witness and is signed with its key: `BlockCapsule.validateSignature`, which
    ///      on mainnet (`getAllowMultiSign`) checks the witness-permission key. Tron writes v as 0 or 1.
    function _checkSigner(Header memory h, bytes32 hash, Producer memory producer, uint256 i) private pure {
        if (h.witness != producer.witness || h.v > 1) revert BadSignature(i);
        // Only the signer's identity matters here: a second form of the same signature proves nothing more.
        // forge-lint: disable-next-line(ecrecover)
        if (ecrecover(hash, SafeCast.toUint8(h.v + ECRECOVER_V), h.r, h.s) != producer.key) revert BadSignature(i);
    }

    /// @dev `BlockId`: the block number in the first 8 bytes, the header hash in the other 24.
    function _blockId(uint256 number, bytes32 hash) private pure returns (bytes32) {
        return bytes32(number << NUMBER_SHIFT | (uint256(hash) & ID_HASH_MASK));
    }

    /// @dev `BlockHeader.raw`: timestamp (1), txTrieRoot (2), parentHash (3), number (7), witness_id (8), witness_address
    ///      (9), version (10), accountStateRoot (11), then any unknown fields as they are. An int64 carried as uint64
    ///      writes the same varint; version is an int32, sign-extended to 64 bits as Java writes it.
    function _header(Header memory h) private pure returns (bytes memory) {
        bytes memory head = bytes.concat(
            _varintField(F1_VARINT, h.timestamp),
            _bytesField(F2_BYTES, abi.encodePacked(h.txTrieRoot)),
            _bytesField(F3_BYTES, abi.encodePacked(h.parentHash)),
            _varintField(F7_VARINT, h.number)
        );
        return bytes.concat(
            head,
            _varintField(F8_VARINT, h.witnessId),
            _bytesField(F9_BYTES, _tronAddress(h.witness)),
            // Reinterpreting the sign-extended int64 as a uint64 is the point: it is the varint Java writes.
            // forge-lint: disable-next-line(unsafe-typecast)
            _varintField(F10_VARINT, uint64(int64(h.version))),
            _bytesField(F11_BYTES, h.accountStateRoot),
            h.extra
        );
    }

    // ---------------------------------------------------------------------
    // Transactions
    // ---------------------------------------------------------------------

    /// @dev `Transaction`: raw_data (1), each signature (2), and one result (5): its fee (1) and `contractRet` (3)
    ///      SUCCESS, the one field of it Tron's peers check.
    function _transaction(Transaction memory t, address target, bytes memory data)
        private
        pure
        returns (bytes memory out)
    {
        out = _bytesField(F1_BYTES, _raw(t, target, data));
        for (uint256 i = 0; i < t.signatures.length; ++i) {
            out = bytes.concat(out, _bytesField(F2_BYTES, t.signatures[i]));
        }
        bytes memory result = bytes.concat(_varintField(F1_VARINT, t.fee), _varintField(F3_VARINT, SUCCESS));
        out = bytes.concat(out, _bytesField(F5_BYTES, result));
    }

    /// @dev `Transaction.raw`: ref_block_bytes (1), ref_block_hash (4), expiration (8), the one contract (11), timestamp
    ///      (14), fee_limit (18).
    function _raw(Transaction memory t, address target, bytes memory data) private pure returns (bytes memory) {
        return bytes.concat(
            _bytesField(F1_BYTES, t.refBlockBytes),
            _bytesField(F4_BYTES, t.refBlockHash),
            _varintField(F8_VARINT, t.expiration),
            _bytesField(F11_BYTES, _contract(t, target, data)),
            _varintField(F14_VARINT, t.timestamp),
            _varintField(F18_VARINT, t.feeLimit)
        );
    }

    /// @dev `Transaction.Contract`: type (1) TriggerSmartContract, parameter (2) an `Any` of it, Permission_id (5).
    ///      Inside, `TriggerSmartContract`: owner_address (1), contract_address (2), data (4), and neither call_value
    ///      (3), call_token_value (5) nor token_id (6).
    function _contract(Transaction memory t, address target, bytes memory data) private pure returns (bytes memory) {
        bytes memory trigger = bytes.concat(
            _bytesField(F1_BYTES, _tronAddress(t.owner)),
            _bytesField(F2_BYTES, _tronAddress(target)),
            _bytesField(F4_BYTES, data)
        );
        bytes memory any = bytes.concat(_bytesField(F1_BYTES, TRIGGER_TYPE_URL), _bytesField(F2_BYTES, trigger));
        return bytes.concat(
            _varintField(F1_VARINT, TRIGGER_SMART_CONTRACT),
            _bytesField(F2_BYTES, any),
            _varintField(F5_VARINT, t.permissionId)
        );
    }

    // ---------------------------------------------------------------------
    // Protobuf, as Java writes it
    // ---------------------------------------------------------------------

    /// @dev A varint field, left out when zero as proto3 leaves out a zero scalar.
    function _varintField(bytes memory key, uint256 value) private pure returns (bytes memory) {
        if (value == 0) return "";
        return bytes.concat(key, _varint(value));
    }

    /// @dev A length-delimited field, left out when empty as proto3 leaves out an empty string.
    function _bytesField(bytes memory key, bytes memory value) private pure returns (bytes memory) {
        if (value.length == 0) return "";
        return bytes.concat(key, _varint(value.length), value);
    }

    function _tronAddress(address account) private pure returns (bytes memory) {
        return bytes.concat(ADDRESS_PREFIX, bytes20(account));
    }

    function _varint(uint256 x) private pure returns (bytes memory out) {
        uint256 n = 1;
        for (uint256 y = x >> VARINT_BITS; y != 0; y >>= VARINT_BITS) {
            ++n;
        }
        out = new bytes(n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 b = x & VARINT_MASK;
            if (i + 1 < n) b |= VARINT_MORE;
            out[i] = bytes1(SafeCast.toUint8(b));
            x >>= VARINT_BITS;
        }
    }

    function _popcount(uint256 x) private pure returns (uint256 n) {
        n = 0;
        for (; x != 0; x &= x - 1) {
            ++n;
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc ITronStateVerifier
    function producerList(uint256 id) external view returns (ProducerList memory) {
        return _lists[id];
    }

    /// @inheritdoc ITronStateVerifier
    function headerHash(Header calldata h) external pure returns (bytes32) {
        return sha256(_header(h));
    }

    /// @inheritdoc ITronStateVerifier
    function transactionBytes(Transaction calldata t, address target, bytes calldata data)
        external
        pure
        returns (bytes memory)
    {
        return _transaction(t, target, data);
    }
}
