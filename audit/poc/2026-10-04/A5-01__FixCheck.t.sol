// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CometBftStateVerifier} from "../src/verifiers/CometBftStateVerifier.sol";
import {ICometBftStateVerifier} from "../src/interfaces/ICometBftStateVerifier.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";

contract FixCheckTest is Test {
    bytes32 constant KEY = keccak256("program");
    MockSP1Verifier sp1;

    function setUp() public { sp1 = new MockSP1Verifier(); }

    function _proof(bytes memory pv) internal pure returns (bytes memory) { return abi.encode(keccak256(abi.encode(KEY, pv))); }

    function _pv(CometBftStateVerifier v, uint64 th, bytes32 thash, uint64 tt, uint64 h, bytes32 hash, uint64 t) internal view returns (bytes memory) {
        return abi.encode(ICometBftStateVerifier.UpdateValues({kind: v.UPDATE(), chainIdHash: keccak256("injective-1"), trustedHeight: th, trustedHash: thash, trustedTime: tt, height: h, hash: hash, time: t}));
    }

    // With the 6h bound, the attacker's tiny steps cannot walk the verifier to death: once the latest is older than 6h
    // an update must land a recent header, which only helps; a keeper's update still lands.
    function test_fixed_attackerCannotStarve() public {
        uint64 t0 = 1_800_000_000;
        vm.warp(t0 + 60);
        CometBftStateVerifier v = new CometBftStateVerifier(sp1, KEY, 1776, "injective-1", address(0xBEEF), 100, keccak256("h100"), t0);
        uint64 h = 100; bytes32 hash = keccak256("h100"); uint64 t = t0;
        uint256 landed;
        for (uint256 round = 0; round < 60; ++round) {
            vm.warp(block.timestamp + 10 minutes);
            bytes32 next = keccak256(abi.encode("next", round));
            bytes memory pv = _pv(v, h, hash, t, h + 1, next, t + 1);
            if (block.timestamp > uint256(t) + 1 + 6 hours) {
                vm.expectRevert(abi.encodeWithSelector(ICometBftStateVerifier.TooOld.selector, t + 1));
                v.update(pv, _proof(pv));
                break;
            }
            v.update(pv, _proof(pv));
            (h, hash, t) = (h + 1, next, t + 1);
            ++landed;
        }
        assertGt(landed, 0);
        // still alive at 7 hours: the keeper lands its jump
        assertLt(block.timestamp, uint256(t) + 1 days);
        bytes memory kpv = _pv(v, h, hash, t, h + 900, keccak256("keeper"), uint64(block.timestamp - 30));
        v.update(kpv, _proof(kpv));
        assertEq(v.latestHash(), keccak256("keeper"));
    }
}
