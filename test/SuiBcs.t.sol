// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SuiBcs} from "../src/libraries/SuiBcs.sol";
import {SuiProofHarness} from "./mocks/SuiProofHarness.sol";

/// @notice Sui's BCS integers, and the artifacts tree's edges. Real checkpoints, objects and paths pin the rest
///         (`test/SuiStateVerifier.t.sol`).
contract SuiBcsTest is Test {
    SuiProofHarness h;

    function setUp() public {
        h = new SuiProofHarness();
    }

    function test_le64() public view {
        assertEq(h.le64(0x0102030405060708), bytes8(0x0807060504030201));
        assertEq(h.le64(0), bytes8(0));
        assertEq(h.le64(type(uint64).max), bytes8(type(uint64).max));
        assertEq(h.le64(1790985941751), bytes8(hex"f7b214ffa0010000"));
    }

    function test_uleb128() public view {
        assertEq(h.uleb128(0), hex"00");
        assertEq(h.uleb128(127), hex"7f");
        assertEq(h.uleb128(128), hex"8001");
        assertEq(h.uleb128(300), hex"ac02");
        assertEq(h.uleb128(16_384), hex"808001");
        assertEq(h.uleb128(type(uint64).max), hex"ffffffffffffffffff01");
    }

    function test_fuzz_uleb128RoundTrips(uint64 n) public view {
        bytes memory out = h.uleb128(n);
        uint256 value = 0;
        for (uint256 i = 0; i < out.length; ++i) {
            uint8 b = uint8(out[i]);
            value |= uint256(b & 0x7f) << (7 * i);
            assertEq(b >= 0x80, i + 1 < out.length, "the top bit marks every byte but the last");
        }
        assertEq(value, n);
    }

    /// @dev Entries written in place, in order, each a byte string of 96 and a u64; the slack past the last is
    ///      required.
    function test_writeCommitteeEntry() public {
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");
        bytes32 c = keccak256("c");
        bytes memory body = new bytes(2 * 105 + 24);
        body = h.writeCommitteeEntry(body, 0, a, b, c, 54);
        body = h.writeCommitteeEntry(body, 1, c, b, a, 0x0102);
        bytes memory expected =
            bytes.concat(hex"60", a, b, c, h.le64(54), hex"60", c, b, a, h.le64(0x0102), new bytes(24));
        assertEq(body, expected);
        vm.expectRevert(SuiBcs.BadBuffer.selector);
        h.writeCommitteeEntry(new bytes(2 * 105), 1, a, b, c, 1);
    }

    /// @dev A tree of one leaf is the leaf; an index needing more bits than the path has steps is refused.
    function test_merkleRoot_edges() public {
        bytes32 leaf = keccak256("a leaf");
        assertEq(h.merkleRoot(leaf, 0, new bytes32[](0)), leaf);
        vm.expectRevert(abi.encodeWithSelector(SuiBcs.BadLeafIndex.selector, 1));
        h.merkleRoot(leaf, 1, new bytes32[](0));
        vm.expectRevert(abi.encodeWithSelector(SuiBcs.BadLeafIndex.selector, 4));
        h.merkleRoot(leaf, 4, new bytes32[](2));
        h.merkleRoot(leaf, 3, new bytes32[](2));
        h.merkleRoot(leaf, type(uint256).max, new bytes32[](256));
    }
}
