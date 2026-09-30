// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEthereumEventVerifier} from "../interfaces/IEthereumEventVerifier.sol";
import {ISP1Verifier} from "../interfaces/ISP1Verifier.sol";
import {MerklePatricia} from "../libraries/MerklePatricia.sol";
import {RlpReader} from "../libraries/RlpReader.sol";

/// @title EthereumFinalityVerifier
/// @notice P1 on an EVM vault chain (Stage B spec, section 10): a light client of Ethereum that anyone advances with an
///         SP1 proof that a checkpoint is finalized by two thirds of the anchor's validators, and that proves a vault
///         message by its receipt in any execution block those proofs covered.
/// @dev No owner, no upgrade. The first anchor comes from the deployer, checked during the vault's listing delay as the
///      BNB verifier's first set is; every later one is proven. A proof that starts from any other anchor is refused,
///      so the verifier follows Ethereum one proven step at a time, each at most a day past the last. The program key
///      fixes the statement and Ethereum's fork schedule: a new fork needs a new verifier, rotated in behind
///      `ROTATION_DELAY`.
contract EthereumFinalityVerifier is IEthereumEventVerifier {
    using RlpReader for RlpReader.Item;

    /// @notice The execution blocks one proof covered, by number.
    struct Range {
        uint64 first;
        uint64 last;
    }

    /// @notice A block covered by a proof: its leaf's fields, and the leaf's path to the headers root that proof
    ///         recorded, siblings from the bottom up.
    struct Header {
        bytes32 headersRoot;
        uint64 number;
        uint64 timestamp;
        bytes32 stateRoot;
        bytes32 receiptsRoot;
        bytes32[] path;
    }

    ISP1Verifier public immutable SP1_VERIFIER;
    bytes32 public immutable PROGRAM_KEY;

    /// @notice `keccak256(abi.encode(epoch, validatorsRoot, execHash, execNumber))` of the last checkpoint accepted.
    bytes32 public anchor;
    uint64 public anchorEpoch;
    mapping(bytes32 headersRoot => Range) internal _ranges;

    event Advanced(uint64 indexed epoch, bytes32 anchor, bytes32 headersRoot, uint64 first, uint64 last);

    error ZeroAddress();
    error WrongAnchor(bytes32 given, bytes32 held);
    error UnknownHeaders(bytes32 root);
    error NotInRange(uint64 number, uint64 first, uint64 last);
    error BadHeaderPath();
    error NoReceipt(uint256 txIndex);
    error FailedTransaction(uint256 txIndex);
    error NoLog(uint256 logIndex);

    uint256 private constant ADDRESS_BYTES = 20;
    uint256 private constant STATUS = 0;
    uint256 private constant LOGS = 3;
    /// @dev A typed receipt's first byte is its type, below every RLP list's prefix.
    uint256 private constant FIRST_LIST_PREFIX = 0xc0;
    uint256 private constant SINGLE_BYTE = 0x80;

    constructor(ISP1Verifier sp1Verifier, bytes32 programKey, bytes32 initialAnchor, uint64 initialEpoch) {
        if (address(sp1Verifier) == address(0) || programKey == bytes32(0) || initialAnchor == bytes32(0)) {
            revert ZeroAddress();
        }
        SP1_VERIFIER = sp1Verifier;
        PROGRAM_KEY = programKey;
        anchor = initialAnchor;
        anchorEpoch = initialEpoch;
    }

    /// @notice Anyone. Accepts an SP1 proof of the statement from the stored anchor, and records the blocks it covers.
    /// @param publicValues `abi.encode(anchorIn, anchorOut, epoch, headersRoot, first, last)`, as the program commits.
    function update(bytes calldata publicValues, bytes calldata proof) external {
        SP1_VERIFIER.verifyProof(PROGRAM_KEY, publicValues, proof);
        (bytes32 anchorIn, bytes32 anchorOut, uint64 epoch, bytes32 headersRoot, uint64 first, uint64 last) =
            abi.decode(publicValues, (bytes32, bytes32, uint64, bytes32, uint64, uint64));
        if (anchorIn != anchor) revert WrongAnchor(anchorIn, anchor);
        anchor = anchorOut;
        anchorEpoch = epoch;
        _ranges[headersRoot] = Range({first: first, last: last});
        // The call before this is the SP1 verifier's view.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Advanced(epoch, anchorOut, headersRoot, first, last);
    }

    /// @notice The blocks the proof that recorded `headersRoot` covered; zero if none did.
    function range(bytes32 headersRoot) external view returns (Range memory) {
        return _ranges[headersRoot];
    }

    /// @inheritdoc IEthereumEventVerifier
    /// @dev `proof` is `abi.encode(Header, bytes[] receiptProof, uint256 txIndex, uint256 logIndex)`: the block, the
    ///      receipt's Merkle-Patricia proof under the block's receipts root, and which log. The transaction must have
    ///      succeeded, and the log must carry at least two topics.
    function verifyEvent(bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, address emitter, bytes32 topic0, bytes32 topic1, bytes memory data)
    {
        (Header memory h, bytes[] memory receiptProof, uint256 txIndex, uint256 logIndex) =
            abi.decode(proof, (Header, bytes[], uint256, uint256));
        _checkHeader(h);
        RlpReader.Item memory log = _log(h.receiptsRoot, receiptProof, txIndex, logIndex);
        RlpReader.Item memory account = log.at(0);
        if (account.len != ADDRESS_BYTES) revert RlpReader.BadRlp();
        RlpReader.Item memory topics = log.at(1);
        if (topics.count() < 2) revert NoLog(logIndex);
        return (
            h.number,
            // Twenty bytes, checked above, fit an address exactly.
            // forge-lint: disable-next-line(unsafe-typecast)
            address(uint160(account.toUint())),
            topics.at(0).toBytes32(),
            topics.at(1).toBytes32(),
            log.at(2).toBytes()
        );
    }

    /// @dev The `logIndex`-th log of the receipt of transaction `txIndex`, which must have succeeded, proven under
    ///      `receiptsRoot`.
    function _log(bytes32 receiptsRoot, bytes[] memory receiptProof, uint256 txIndex, uint256 logIndex)
        private
        pure
        returns (RlpReader.Item memory)
    {
        (bytes32 key, uint256 nibbles) = _receiptKey(txIndex);
        (bool found, RlpReader.Item memory value) = MerklePatricia.get(receiptsRoot, key, nibbles, receiptProof);
        if (!found) revert NoReceipt(txIndex);
        RlpReader.Item memory receipt = _receipt(value);
        if (receipt.at(STATUS).toUint() != 1) revert FailedTransaction(txIndex);
        RlpReader.Item memory logs = receipt.at(LOGS);
        if (logIndex >= logs.count()) revert NoLog(logIndex);
        return logs.at(logIndex);
    }

    /// @inheritdoc IEthereumEventVerifier
    /// @dev `proof` is `abi.encode(Header)`.
    function verifyCheckpoint(bytes calldata proof) external view returns (Checkpoint memory) {
        Header memory h = abi.decode(proof, (Header));
        _checkHeader(h);
        return Checkpoint({blockNumber: h.number, timestamp: h.timestamp, stateRoot: h.stateRoot});
    }

    /// @dev The header's leaf lies at its place in the tree a proof recorded: `number - first`, at a depth of
    ///      `ceil(log2(last - first + 1))`, a zero standing in for an odd layer's missing sibling.
    function _checkHeader(Header memory h) private view {
        Range memory r = _ranges[h.headersRoot];
        if (r.last == 0) revert UnknownHeaders(h.headersRoot);
        if (h.number < r.first || h.number > r.last) revert NotInRange(h.number, r.first, r.last);
        uint256 size = uint256(r.last) - r.first + 1;
        uint256 depth = 0;
        while ((1 << depth) < size) {
            ++depth;
        }
        if (h.path.length != depth) revert BadHeaderPath();
        bytes32 node = keccak256(abi.encode(uint256(h.number), uint256(h.timestamp), h.stateRoot, h.receiptsRoot));
        uint256 index = h.number - r.first;
        for (uint256 i = 0; i < depth; ++i) {
            node =
                (index >> i) & 1 == 1 ? keccak256(abi.encode(h.path[i], node)) : keccak256(abi.encode(node, h.path[i]));
        }
        if (node != h.headersRoot) revert BadHeaderPath();
    }

    /// @dev A receipt's key in its block's trie is `rlp(txIndex)`, left-aligned, with its length in nibbles.
    function _receiptKey(uint256 txIndex) private pure returns (bytes32 key, uint256 nibbles) {
        if (txIndex == 0) return (bytes32(SINGLE_BYTE << 248), 2);
        if (txIndex < SINGLE_BYTE) return (bytes32(txIndex << 248), 2);
        if (txIndex < 1 << 8) return (bytes32((uint256(0x81) << 248) | (txIndex << 240)), 4);
        if (txIndex < 1 << 16) return (bytes32((uint256(0x82) << 248) | (txIndex << 232)), 6);
        revert NoReceipt(txIndex);
    }

    /// @dev A receipt is the list (status, cumulativeGasUsed, logsBloom, logs), after its type byte if it has one.
    function _receipt(RlpReader.Item memory value) private pure returns (RlpReader.Item memory) {
        if (value.byteAt(0) < FIRST_LIST_PREFIX) return RlpReader.toItem(value.slice(1, value.len - 1));
        return RlpReader.toItem(value.toBytes());
    }
}
