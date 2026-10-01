// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EthereumFinalityVerifier} from "../src/verifiers/EthereumFinalityVerifier.sol";
import {IEthereumEventVerifier} from "../src/interfaces/IEthereumEventVerifier.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {MerklePatricia} from "../src/libraries/MerklePatricia.sol";
import {RlpReader} from "../src/libraries/RlpReader.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";

/// @notice P1's verifier on an EVM vault chain, against real mainnet receipts: block 26,092,387's receipts trie rebuilt
///         and checked against its header by `test/fixtures/ethereum/generate.py`. The SP1 proof is mocked; what the
///         verifier does with a proven statement is not.
contract EthereumFinalityVerifierTest is Test {
    MockSP1Verifier sp1;
    EthereumFinalityVerifier verifier;
    string json;

    bytes32 constant KEY = keccak256("the P1 program");
    bytes32 constant ANCHOR = keccak256("the deployer's anchor");
    bytes32 constant NEXT = keccak256("the next anchor");
    uint64 constant EPOCH = 479_000;

    uint64 number;
    uint64 timestamp;
    bytes32 stateRoot;
    bytes32 receiptsRoot;

    function setUp() public {
        sp1 = new MockSP1Verifier();
        verifier = new EthereumFinalityVerifier(sp1, KEY, ANCHOR, EPOCH);
        json = vm.readFile("test/fixtures/ethereum/receipts.json");
        number = uint64(vm.parseJsonUint(json, ".number"));
        timestamp = uint64(vm.parseJsonUint(json, ".timestamp"));
        stateRoot = vm.parseJsonBytes32(json, ".stateRoot");
        receiptsRoot = vm.parseJsonBytes32(json, ".receiptsRoot");
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _leaf(uint64 n, uint64 t, bytes32 s, bytes32 r) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(n), uint256(t), s, r));
    }

    /// @dev The tree the P1 program commits to (`keccak_root`): layer by layer, a zero for an odd layer's missing
    ///      sibling. Returns the root and the path of leaf `index`.
    function _tree(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32, bytes32[] memory path) {
        uint256 depth = 0;
        while ((1 << depth) < leaves.length) {
            ++depth;
        }
        path = new bytes32[](depth);
        bytes32[] memory layer = leaves;
        for (uint256 level = 0; level < depth; ++level) {
            uint256 sibling = index ^ 1;
            path[level] = sibling < layer.length ? layer[sibling] : bytes32(0);
            bytes32[] memory up = new bytes32[]((layer.length + 1) / 2);
            for (uint256 i = 0; i < up.length; ++i) {
                bytes32 right = 2 * i + 1 < layer.length ? layer[2 * i + 1] : bytes32(0);
                up[i] = keccak256(abi.encode(layer[2 * i], right));
            }
            layer = up;
            index >>= 1;
        }
        return (layer[0], path);
    }

    /// @dev A proof covering five blocks around the real one, which is the second; the others are made up.
    function _advance() internal returns (EthereumFinalityVerifier.Header memory h) {
        bytes32[] memory leaves = new bytes32[](5);
        for (uint256 i = 0; i < 5; ++i) {
            uint64 n = number - 1 + uint64(i);
            leaves[i] = n == number
                ? _leaf(number, timestamp, stateRoot, receiptsRoot)
                : _leaf(n, timestamp, keccak256(abi.encode(n)), keccak256(abi.encode(n, 1)));
        }
        (bytes32 root, bytes32[] memory path) = _tree(leaves, 1);
        _update(ANCHOR, NEXT, root, number - 1, number + 3);
        h = EthereumFinalityVerifier.Header({
            headersRoot: root,
            number: number,
            timestamp: timestamp,
            stateRoot: stateRoot,
            receiptsRoot: receiptsRoot,
            path: path
        });
    }

    function _update(bytes32 anchorIn, bytes32 anchorOut, bytes32 root, uint64 first, uint64 last) internal {
        bytes memory publicValues = abi.encode(anchorIn, anchorOut, EPOCH + 1, root, first, last);
        verifier.update(publicValues, sp1.prove(KEY, publicValues));
    }

    function _receiptProof(string memory path) internal view returns (bytes[] memory) {
        return vm.parseJsonBytesArray(json, string.concat(path, ".proof"));
    }

    function _event(EthereumFinalityVerifier.Header memory h, bytes[] memory proof, uint256 txIndex, uint256 logIndex)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(h, proof, txIndex, logIndex);
    }

    // ---------------------------------------------------------------------
    // advancing
    // ---------------------------------------------------------------------

    function test_deploy() public {
        assertEq(address(verifier.SP1_VERIFIER()), address(sp1));
        assertEq(verifier.PROGRAM_KEY(), KEY);
        assertEq(verifier.anchor(), ANCHOR);
        assertEq(verifier.anchorEpoch(), EPOCH);
        vm.expectRevert(EthereumFinalityVerifier.ZeroAddress.selector);
        new EthereumFinalityVerifier(ISP1Verifier(address(0)), KEY, ANCHOR, EPOCH);
        vm.expectRevert(EthereumFinalityVerifier.ZeroAddress.selector);
        new EthereumFinalityVerifier(sp1, bytes32(0), ANCHOR, EPOCH);
        vm.expectRevert(EthereumFinalityVerifier.ZeroAddress.selector);
        new EthereumFinalityVerifier(sp1, KEY, bytes32(0), EPOCH);
    }

    /// @dev A proof moves the anchor one step and records the blocks it covers; the same proof never runs twice, and
    ///      no proof starts anywhere but at the stored anchor.
    function test_update_followsTheAnchor() public {
        bytes32 root = keccak256("headers");
        bytes memory publicValues = abi.encode(ANCHOR, NEXT, EPOCH + 1, root, uint64(10), uint64(20));
        bytes memory proof = sp1.prove(KEY, publicValues);
        bytes memory anotherProgram = sp1.prove(keccak256("another program"), publicValues);
        vm.expectRevert(MockSP1Verifier.Rejected.selector);
        verifier.update(publicValues, anotherProgram);

        vm.expectEmit(address(verifier));
        emit EthereumFinalityVerifier.Advanced(EPOCH + 1, NEXT, root, 10, 20);
        verifier.update(publicValues, proof);
        assertEq(verifier.anchor(), NEXT);
        assertEq(verifier.anchorEpoch(), EPOCH + 1);
        assertEq(verifier.range(root).first, 10);
        assertEq(verifier.range(root).last, 20);

        vm.expectRevert(abi.encodeWithSelector(EthereumFinalityVerifier.WrongAnchor.selector, ANCHOR, NEXT));
        verifier.update(publicValues, proof);
    }

    // ---------------------------------------------------------------------
    // events and checkpoints
    // ---------------------------------------------------------------------

    /// @dev Three real receipts: a one-byte key, a two-byte key (index 130) and a legacy receipt with no type byte.
    function test_verifyEvent_readsRealReceipts() public {
        EthereumFinalityVerifier.Header memory h = _advance();
        for (uint256 c = 0; c < 3; ++c) {
            string memory at = string.concat(".cases[", vm.toString(c), "]");
            uint256 txIndex = vm.parseJsonUint(json, string.concat(at, ".txIndex"));
            uint256 logIndex = vm.parseJsonUint(json, string.concat(at, ".logIndex"));
            (uint256 blockNumber, address emitter, bytes32 topic0, bytes32 topic1, bytes memory data) =
                verifier.verifyEvent(_event(h, _receiptProof(at), txIndex, logIndex));
            assertEq(blockNumber, number);
            assertEq(emitter, vm.parseJsonAddress(json, string.concat(at, ".emitter")));
            assertEq(topic0, vm.parseJsonBytes32(json, string.concat(at, ".topic0")));
            assertEq(topic1, vm.parseJsonBytes32(json, string.concat(at, ".topic1")));
            assertEq(data, vm.parseJsonBytes(json, string.concat(at, ".data")));
        }
        assertEq(vm.parseJsonUint(json, ".cases[1].txIndex"), 130, "a two-byte key");
        assertEq(vm.parseJsonUint(json, ".cases[2].type"), 0, "a legacy receipt");
    }

    function test_verifyEvent_refusals() public {
        EthereumFinalityVerifier.Header memory h = _advance();
        bytes[] memory proof = _receiptProof(".cases[0]");

        uint256 failed = vm.parseJsonUint(json, ".failed.txIndex");
        vm.expectRevert(abi.encodeWithSelector(EthereumFinalityVerifier.FailedTransaction.selector, failed));
        verifier.verifyEvent(_event(h, _receiptProof(".failed"), failed, 0));

        uint256 absent = vm.parseJsonUint(json, ".absent.txIndex");
        vm.expectRevert(abi.encodeWithSelector(EthereumFinalityVerifier.NoReceipt.selector, absent));
        verifier.verifyEvent(_event(h, _receiptProof(".absent"), absent, 0));
        vm.expectRevert(abi.encodeWithSelector(EthereumFinalityVerifier.NoReceipt.selector, 1 << 16));
        verifier.verifyEvent(_event(h, proof, 1 << 16, 0));

        uint256 one = vm.parseJsonUint(json, ".oneTopic.txIndex");
        uint256 oneLog = vm.parseJsonUint(json, ".oneTopic.logIndex");
        vm.expectRevert(abi.encodeWithSelector(EthereumFinalityVerifier.NoLog.selector, oneLog));
        verifier.verifyEvent(_event(h, _receiptProof(".oneTopic"), one, oneLog));
        vm.expectRevert(abi.encodeWithSelector(EthereumFinalityVerifier.NoLog.selector, 1_000));
        verifier.verifyEvent(_event(h, proof, 0, 1_000));

        // A proof node changed by one byte no longer hashes to its reference.
        bytes[] memory tampered = _receiptProof(".cases[0]");
        tampered[1][40] ^= 0x01;
        vm.expectRevert(abi.encodeWithSelector(MerklePatricia.BadProof.selector, 1));
        verifier.verifyEvent(_event(h, tampered, 0, 0));
    }

    /// @dev A log whose address is not 20 bytes, which no real block holds, from a made-up trie: refused, not cut.
    function test_verifyEvent_anAddressIsTwentyBytes() public {
        bytes32 root = vm.parseJsonBytes32(json, ".malformed.receiptsRoot");
        bytes32 leaf = _leaf(number, timestamp, stateRoot, root);
        _update(ANCHOR, NEXT, leaf, number, number);
        EthereumFinalityVerifier.Header memory h = EthereumFinalityVerifier.Header({
            headersRoot: leaf,
            number: number,
            timestamp: timestamp,
            stateRoot: stateRoot,
            receiptsRoot: root,
            path: new bytes32[](0)
        });
        bytes memory proof = _event(h, _receiptProof(".malformed"), 0, 0);
        vm.expectRevert(RlpReader.BadRlp.selector);
        verifier.verifyEvent(proof);
    }

    function test_verifyCheckpoint_returnsACoveredBlock() public {
        EthereumFinalityVerifier.Header memory h = _advance();
        IEthereumEventVerifier.Checkpoint memory c = verifier.verifyCheckpoint(abi.encode(h));
        assertEq(c.blockNumber, number);
        assertEq(c.timestamp, timestamp);
        assertEq(c.stateRoot, stateRoot);
    }

    /// @dev A header proves only at its own place in a tree some proof recorded.
    function test_headers_refusals() public {
        EthereumFinalityVerifier.Header memory h = _advance();

        // A copy: assigning a memory struct would alias it.
        EthereumFinalityVerifier.Header memory other = abi.decode(abi.encode(h), (EthereumFinalityVerifier.Header));
        other.headersRoot = keccak256("never proven");
        vm.expectRevert(abi.encodeWithSelector(EthereumFinalityVerifier.UnknownHeaders.selector, other.headersRoot));
        verifier.verifyCheckpoint(abi.encode(other));

        h.number = number + 4;
        vm.expectRevert(
            abi.encodeWithSelector(EthereumFinalityVerifier.NotInRange.selector, number + 4, number - 1, number + 3)
        );
        verifier.verifyCheckpoint(abi.encode(h));
        h.number = number - 2;
        vm.expectRevert(
            abi.encodeWithSelector(EthereumFinalityVerifier.NotInRange.selector, number - 2, number - 1, number + 3)
        );
        verifier.verifyCheckpoint(abi.encode(h));

        // Another number in range puts the leaf at another place.
        h.number = number + 1;
        vm.expectRevert(EthereumFinalityVerifier.BadHeaderPath.selector);
        verifier.verifyCheckpoint(abi.encode(h));
        h.number = number;
        h.timestamp += 1;
        vm.expectRevert(EthereumFinalityVerifier.BadHeaderPath.selector);
        verifier.verifyCheckpoint(abi.encode(h));
        h.timestamp -= 1;
        h.path[0] = bytes32(uint256(h.path[0]) ^ 1);
        vm.expectRevert(EthereumFinalityVerifier.BadHeaderPath.selector);
        verifier.verifyCheckpoint(abi.encode(h));
        h.path = new bytes32[](2);
        vm.expectRevert(EthereumFinalityVerifier.BadHeaderPath.selector);
        verifier.verifyCheckpoint(abi.encode(h));
    }

    /// @dev A proof of a single block: the leaf is the root, with an empty path.
    function test_aSingleBlockIsItsOwnRoot() public {
        bytes32 leaf = _leaf(number, timestamp, stateRoot, receiptsRoot);
        _update(ANCHOR, NEXT, leaf, number, number);
        EthereumFinalityVerifier.Header memory h = EthereumFinalityVerifier.Header({
            headersRoot: leaf,
            number: number,
            timestamp: timestamp,
            stateRoot: stateRoot,
            receiptsRoot: receiptsRoot,
            path: new bytes32[](0)
        });
        assertEq(verifier.verifyCheckpoint(abi.encode(h)).blockNumber, number);
    }

    /// @dev The tree rule, pinned against the P1 program's own test (`the_encodings_match_solidity`).
    function test_theTreeIsTheProgramsTree() public pure {
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");
        bytes32 c = keccak256("c");
        bytes32[] memory leaves = new bytes32[](3);
        (leaves[0], leaves[1], leaves[2]) = (a, b, c);
        (bytes32 root,) = _tree(leaves, 0);
        assertEq(root, keccak256(abi.encode(keccak256(abi.encode(a, b)), keccak256(abi.encode(c, bytes32(0))))));
    }
}
