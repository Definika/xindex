// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {XindexVault} from "../src/vault/XindexVault.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";
import {IEthereumEventVerifier} from "../src/interfaces/IEthereumEventVerifier.sol";
import {EthereumFinalityVerifier} from "../src/verifiers/EthereumFinalityVerifier.sol";
import {FinalityVerifier} from "../src/verifiers/FinalityVerifier.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";
import {MockStateReader} from "./mocks/MockStateReader.sol";

/// @notice V2 verification of A4-01, A4-02: real FinalityVerifier pairs (zk check mocked) behind the real vault.
contract A4VerifyTest is Test {
    uint256 constant GENESIS = 1_606_824_023;
    uint64 constant EPOCH = 479_000;
    bytes32 constant KEY = keccak256("the P1 program");
    bytes32 constant ANCHOR = keccak256("the deployer's anchor");
    bytes32 constant NEXT = keccak256("next");
    bytes32 constant STATE = keccak256("state root of block 20");
    bytes32 constant RECEIPTS = keccak256("receipts");

    MockSP1Verifier sp1;
    EthereumFinalityVerifier p1;
    EthereumFinalityVerifier p2;
    XindexVault vault;
    address recoveryProposer = makeAddr("recovery");
    uint256 t0;
    uint64 tC; // timestamp of the last covered block (the old pair's last checkpoint)

    function _leaf(uint64 n, uint64 t, bytes32 s, bytes32 r) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(n), uint256(t), s, r));
    }

    function setUp() public {
        sp1 = new MockSP1Verifier();
        t0 = GENESIS + uint256(EPOCH) * 384;
        vm.warp(t0);
        p1 = new EthereumFinalityVerifier(sp1, KEY, ANCHOR, EPOCH, GENESIS);
        p2 = new EthereumFinalityVerifier(sp1, KEY, ANCHOR, EPOCH, GENESIS);
        vault = new XindexVault(
            IXindexVault.Config({
                sourceChainId: 1,
                factory: makeAddr("factory"),
                hubImplementation: makeAddr("hub"),
                verifier1: p1,
                verifier2: p2,
                freezer: makeAddr("freezer"),
                recoveryProposer: recoveryProposer,
                stateReader: new MockStateReader(),
                nativeCap: 1_000_000 ether,
                nativeFloor: 1 ether
            })
        );
        // Honest keepers: both pairs updated once an hour in, covering block 20 (single-leaf range), anchor epoch +10.
        vm.warp(t0 + 4000);
        tC = uint64(GENESIS + uint256(EPOCH + 10) * 384);
        bytes32 root = _leaf(20, tC, STATE, RECEIPTS);
        bytes memory pv = abi.encode(ANCHOR, NEXT, EPOCH + 10, root, uint64(20), uint64(20));
        p1.update(pv, sp1.prove(KEY, pv));
        p2.update(pv, sp1.prove(KEY, pv));
        FinalityVerifier.Header memory h = _header20(root);
        vault.advanceCheckpoint(abi.encode(h), abi.encode(h));
        assertEq(vault.checkpoint().blockNumber, 20);
    }

    function _header20(bytes32 root) internal view returns (FinalityVerifier.Header memory h) {
        h = FinalityVerifier.Header({
            headersRoot: root, number: 20, timestamp: tC, stateRoot: STATE, receiptsRoot: RECEIPTS, path: new bytes32[](0)
        });
    }

    /// A4-01: nobody proves for a day -> both verifiers dead for good -> the checkpoint cannot move -> the vault
    /// stalls 7 days after the last covered block, and no permissionless call can end the stall.
    function test_A401_aDayWithoutProofsStallsTheVaultForGood() public {
        uint256 ends = p1.lagEnds();
        assertEq(ends, tC + 1 days);
        // The honest keeper is down just over a day.
        vm.warp(ends + 1);
        bytes memory pv = abi.encode(NEXT, keccak256("n2"), EPOCH + 20, keccak256("hr"), uint64(21), uint64(30));
        bytes memory pr = sp1.prove(KEY, pv);
        vm.expectRevert(abi.encodeWithSelector(FinalityVerifier.TooOld.selector, EPOCH + 10));
        p1.update(pv, pr);
        // 6 days on, the keeper is back with a perfectly valid proof: still refused, for good.
        vm.warp(tC + 7 days + 1);
        assertTrue(vault.stalled());
        vm.expectRevert(abi.encodeWithSelector(FinalityVerifier.TooOld.selector, EPOCH + 10));
        p1.update(pv, pr);
        // The vault's checkpoint cannot be advanced past the last covered block either (no recorded range).
        FinalityVerifier.Header memory later = FinalityVerifier.Header({
            headersRoot: keccak256("hr"),
            number: 25,
            timestamp: uint64(block.timestamp),
            stateRoot: STATE,
            receiptsRoot: RECEIPTS,
            path: new bytes32[](0)
        });
        vm.expectRevert(abi.encodeWithSelector(FinalityVerifier.UnknownHeaders.selector, keccak256("hr")));
        vault.advanceCheckpoint(abi.encode(later), abi.encode(later));
        // Even a year on nothing ends the stall permissionlessly.
        vm.warp(block.timestamp + 150 days);
        assertTrue(vault.stalled());
        // Rotation of the pair would need a VERIFIER_ROTATION delivered by the dead pair: any log after the last
        // covered block is unprovable (UnknownHeaders), so only recoveryProposer / the snapshot remain.
    }

    /// A4-02 (honest case): a new pair deployed after the stall began, from an honest anchor, cannot prove the old
    /// checkpoint, so proposeSuccessor reverts.
    function test_A402_anHonestSuccessorCannotPassContinuity() public {
        vm.warp(tC + 7 days + 1);
        assertTrue(vault.stalled());
        // New pair: anchor from just before block 20 (epoch EPOCH+5), as an honest deployer would choose.
        EthereumFinalityVerifier n1 = new EthereumFinalityVerifier(sp1, KEY, keccak256("anchor2"), EPOCH + 5, GENESIS);
        EthereumFinalityVerifier n2 = new EthereumFinalityVerifier(sp1, KEY, keccak256("anchor2"), EPOCH + 5, GENESIS);
        bytes32 root = _leaf(20, tC, STATE, RECEIPTS);
        bytes memory pv = abi.encode(keccak256("anchor2"), NEXT, EPOCH + 10, root, uint64(16), uint64(20));
        bytes memory pr = sp1.prove(KEY, pv);
        vm.expectRevert(abi.encodeWithSelector(FinalityVerifier.TooOld.selector, EPOCH + 5));
        n1.update(pv, pr);
        // Hence it knows no header: the continuity test (a) cannot pass.
        bytes memory proof = abi.encode(_header20(root));
        IXindexVault.Continuity memory c = IXindexVault.Continuity({
            last1: proof, last2: proof, recent1: proof, recent2: proof, message1: "", message2: ""
        });
        vm.prank(recoveryProposer);
        vm.expectRevert(abi.encodeWithSelector(FinalityVerifier.UnknownHeaders.selector, root));
        vault.proposeSuccessor(n1, n2, c);
    }

    /// A4-02 (best case): a deployer who misdates the anchor epoch (so the first update is accepted) and acts in the
    /// day-7..8 window can PROPOSE, but the pair can never be adopted: its anchor is dead after one update and the
    /// 30-day review ends with no recent checkpoint it can prove.
    function test_A402_evenAMisdatedSuccessorCanNeverBeAdopted() public {
        vm.warp(tC + 7 days + 1);
        EthereumFinalityVerifier n1 =
            new EthereumFinalityVerifier(sp1, KEY, keccak256("anchor2"), uint64((block.timestamp - GENESIS) / 384), GENESIS);
        EthereumFinalityVerifier n2 =
            new EthereumFinalityVerifier(sp1, KEY, keccak256("anchor2"), uint64((block.timestamp - GENESIS) / 384), GENESIS);
        // Range [20, 21]: the old checkpoint's block, and one a few seconds after (recent: within 7 days of now).
        uint64 tR = tC + 12;
        bytes32 l20 = _leaf(20, tC, STATE, RECEIPTS);
        bytes32 l21 = _leaf(21, tR, keccak256("state21"), RECEIPTS);
        bytes32 root = keccak256(abi.encode(l20, l21));
        bytes memory pv = abi.encode(keccak256("anchor2"), NEXT, EPOCH + 10, root, uint64(20), uint64(21));
        n1.update(pv, sp1.prove(KEY, pv));
        n2.update(pv, sp1.prove(KEY, pv));
        bytes32[] memory path20 = new bytes32[](1);
        path20[0] = l21;
        bytes32[] memory path21 = new bytes32[](1);
        path21[0] = l20;
        bytes memory last = abi.encode(
            FinalityVerifier.Header({
                headersRoot: root, number: 20, timestamp: tC, stateRoot: STATE, receiptsRoot: RECEIPTS, path: path20
            })
        );
        bytes memory recent = abi.encode(
            FinalityVerifier.Header({
                headersRoot: root,
                number: 21,
                timestamp: tR,
                stateRoot: keccak256("state21"),
                receiptsRoot: RECEIPTS,
                path: path21
            })
        );
        IXindexVault.Continuity memory c = IXindexVault.Continuity({
            last1: last, last2: last, recent1: recent, recent2: recent, message1: "", message2: ""
        });
        vm.prank(recoveryProposer);
        vault.proposeSuccessor(n1, n2, c);
        assertEq(vault.successor().p1, address(n1));
        // The successor's own verifier is dead after that one update: a second one is refused.
        vm.warp(block.timestamp + 30 days);
        bytes memory pv2 = abi.encode(NEXT, keccak256("n3"), EPOCH + 300, keccak256("h3"), uint64(22), uint64(40));
        bytes memory pr2 = sp1.prove(KEY, pv2);
        vm.expectRevert(abi.encodeWithSelector(FinalityVerifier.TooOld.selector, EPOCH + 10));
        n1.update(pv2, pr2);
        // And at adoption the best checkpoint it proves is 30 days old: not recent.
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotRecent.selector, tR));
        vault.adoptSuccessor(recent, recent);
    }
}
