// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CometBftStateVerifier} from "../src/verifiers/CometBftStateVerifier.sol";
import {ICometBftStateVerifier} from "../src/interfaces/ICometBftStateVerifier.sol";
import {VeChainStateVerifier} from "../src/verifiers/VeChainStateVerifier.sol";
import {IVeChainStateVerifier} from "../src/interfaces/IVeChainStateVerifier.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";

/// A stranger's valid minimal-step updates (each a real next block, proven) keep invalidating the keeper's proof,
/// which must start from the latest header; the verifier's clock barely moves, and after a day it is dead for good.
contract UpdateGriefTest is Test {
    bytes32 constant KEY = keccak256("program");
    MockSP1Verifier sp1;

    function setUp() public {
        sp1 = new MockSP1Verifier();
    }

    function _proof(bytes memory pv) internal pure returns (bytes memory) {
        return abi.encode(keccak256(abi.encode(KEY, pv)));
    }

    function test_cometbft_minimalStepsStarveTheKeeper() public {
        uint64 t0 = 1_800_000_000;
        vm.warp(t0 + 60);
        CometBftStateVerifier v = new CometBftStateVerifier(
            sp1, KEY, 1776, "injective-1", address(0xBEEF), 100, keccak256("h100"), t0
        );
        bytes32 chainHash = keccak256("injective-1");

        uint64 h = 100;
        bytes32 hash = keccak256("h100");
        uint64 t = t0;
        // Every ~10 minutes the keeper finishes a proof from the latest header to a header near now; the attacker lands
        // a proven one-block step first (front-run, or simply one step per proving window).
        for (uint256 round = 0; round < 150; ++round) {
            vm.warp(block.timestamp + 10 minutes);
            // keeper's proof, built from (h, hash, t)
            bytes memory keeperPv = abi.encode(
                ICometBftStateVerifier.UpdateValues({
                    kind: v.UPDATE(), chainIdHash: chainHash, trustedHeight: h, trustedHash: hash, trustedTime: t,
                    height: h + 900, hash: keccak256(abi.encode("keeper", round)), time: uint64(block.timestamp - 30)
                })
            );
            // attacker's step: the very next block, 1 second later
            bytes32 next = keccak256(abi.encode("next", round));
            bytes memory attackPv = abi.encode(
                ICometBftStateVerifier.UpdateValues({
                    kind: v.UPDATE(), chainIdHash: chainHash, trustedHeight: h, trustedHash: hash, trustedTime: t,
                    height: h + 1, hash: next, time: t + 1
                })
            );
            if (block.timestamp > uint256(t) + 1 days) {
                vm.expectRevert(abi.encodeWithSelector(ICometBftStateVerifier.TooOld.selector, t));
                v.update(keeperPv, _proof(keeperPv));
                return; // dead for good: no update, from anyone, can ever land again
            }
            vm.prank(address(0xA77AC));
            v.update(attackPv, _proof(attackPv));
            (uint64 oldH, bytes32 oldHash) = (h, hash);
            (h, hash, t) = (h + 1, next, t + 1);
            vm.expectRevert(abi.encodeWithSelector(ICometBftStateVerifier.WrongAnchor.selector, uint256(oldH), oldHash));
            v.update(keeperPv, _proof(keeperPv));
        }
        revert("still alive");
    }

    function test_vechain_minimalStepsStarveTheKeeper() public {
        uint64 t0 = 1_800_000_000;
        vm.warp(t0 + 60);
        bytes32 id0 = bytes32(uint256(1000) << 224);
        VeChainStateVerifier v =
            new VeChainStateVerifier(sp1, KEY, 0x4a, address(0xBEEF), address(0xA77E), id0, t0, keccak256("table"));
        bytes32 latest = id0;
        uint64 t = t0;
        uint256 n = 1000;
        for (uint256 round = 0; round < 200; ++round) {
            vm.warp(block.timestamp + 10 minutes);
            bytes memory keeperPv = abi.encode(
                IVeChainStateVerifier.UpdateValues({
                    kind: v.UPDATE(), chain: bytes32(uint256(0x4a)), attester: address(0xA77E), trustedId: latest,
                    trustedTable: keccak256("table"), id: bytes32((n + 60) << 224), table: keccak256("table"),
                    time: uint64(block.timestamp - 15 minutes)
                })
            );
            bytes32 nextId = bytes32(((n + 1) << 224) | round);
            bytes memory attackPv = abi.encode(
                IVeChainStateVerifier.UpdateValues({
                    kind: v.UPDATE(), chain: bytes32(uint256(0x4a)), attester: address(0xA77E), trustedId: latest,
                    trustedTable: keccak256("table"), id: nextId, table: keccak256("table"), time: t + 10
                })
            );
            if (block.timestamp > uint256(t) + 1 days) {
                vm.expectRevert(abi.encodeWithSelector(IVeChainStateVerifier.TooOld.selector, t));
                v.update(keeperPv, _proof(keeperPv));
                return;
            }
            v.update(attackPv, _proof(attackPv));
            bytes32 old = latest;
            (latest, t, n) = (nextId, t + 10, n + 1);
            vm.expectRevert(abi.encodeWithSelector(IVeChainStateVerifier.WrongAnchor.selector, old));
            v.update(keeperPv, _proof(keeperPv));
        }
        revert("still alive");
    }
}
