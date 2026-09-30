// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Bls12381} from "../src/libraries/Bls12381.sol";
import {ProofHarness} from "./mocks/ProofHarness.sol";

/// @notice BLS on the EIP-2537 precompiles, against a real BNB Chain finality vote: 20 of the 21 validators signed
///         the vote data of block 124,884,599 in one aggregate signature. The precompiles exist from Prague on, so
///         this suite runs on it while the repository compiles for Cancun.
/// forge-config: default.evm_version = "prague"
contract Bls12381Test is Test {
    ProofHarness h;
    bytes[] keys;
    bytes[] compressed;
    uint256 bitset;
    bytes signature;
    bytes32 voteHash;
    bytes voteRlp;

    uint256 constant P_HI = 0x1a0111ea397fe69a4b1ba7b6434bacd7;
    uint256 constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;

    function setUp() public {
        h = new ProofHarness();
        string memory json = vm.readFile("test/fixtures/bnb/vote-124884600.json");
        bytes[] memory k = vm.parseJsonBytesArray(json, ".keys");
        bytes[] memory c = vm.parseJsonBytesArray(json, ".keysCompressed");
        for (uint256 i = 0; i < k.length; ++i) {
            keys.push(k[i]);
            compressed.push(c[i]);
        }
        bitset = vm.parseUint(vm.parseJsonString(json, ".bitset"));
        signature = vm.parseJsonBytes(json, ".signature");
        voteHash = vm.parseJsonBytes32(json, ".voteHash");
        voteRlp = vm.parseJsonBytes(json, ".voteRlp");
    }

    function _aggregate(uint256 bits) internal view returns (bytes memory agg) {
        for (uint256 i = 0; i < keys.length; ++i) {
            if ((bits >> i) & 1 == 0) continue;
            agg = agg.length == 0 ? keys[i] : h.add(agg, keys[i]);
        }
    }

    function test_theRecordedVoteVerifies() public view {
        assertEq(keccak256(voteRlp), voteHash, "the vote hash is the hash of the vote data's RLP");
        for (uint256 i = 0; i < keys.length; ++i) {
            assertEq(h.checkKey(compressed[i], keys[i]), keys[i], "the precompile gives the key back");
        }
        assertTrue(h.verify(_aggregate(bitset), signature, abi.encodePacked(voteHash)));
    }

    function test_aDifferentVoteOrAMissingVoterFails() public view {
        bytes memory agg = _aggregate(bitset);
        assertFalse(h.verify(agg, signature, abi.encodePacked(voteHash ^ bytes32(uint256(1)))));
        assertFalse(h.verify(_aggregate(bitset & (bitset - 1)), signature, abi.encodePacked(voteHash)));
    }

    function test_theIdentityIsNeverAKey() public {
        vm.expectRevert(Bls12381.IdentityKey.selector);
        h.verify(new bytes(128), signature, abi.encodePacked(voteHash));
        bytes memory identity = new bytes(48);
        identity[0] = 0x80; // compressed, flags claiming a point, x = 0
        vm.expectRevert(Bls12381.IdentityKey.selector);
        h.checkKey(identity, new bytes(128));
    }

    function test_checkKey_refusesWhatIsNotTheCompressedKey() public {
        bytes memory c = compressed[0];
        bytes memory k = keys[0];
        vm.expectRevert(Bls12381.BadKey.selector);
        h.checkKey(bytes.concat(c, hex"00"), k);
        vm.expectRevert(Bls12381.BadKey.selector);
        h.checkKey(c, bytes.concat(k, hex"00"));

        bytes memory uncompressedFlag = bytes.concat(c);
        uncompressedFlag[0] = bytes1(uint8(c[0]) & 0x7f);
        vm.expectRevert(Bls12381.BadKey.selector);
        h.checkKey(uncompressedFlag, k);

        bytes memory identityFlag = bytes.concat(c);
        identityFlag[0] = bytes1(uint8(c[0]) | 0x40);
        vm.expectRevert(Bls12381.BadKey.selector);
        h.checkKey(identityFlag, k);

        bytes memory otherHighX = bytes.concat(c);
        otherHighX[3] = bytes1(uint8(c[3]) ^ 1);
        vm.expectRevert(Bls12381.BadKey.selector);
        h.checkKey(otherHighX, k);

        bytes memory otherLowX = bytes.concat(c);
        otherLowX[40] = bytes1(uint8(c[40]) ^ 1);
        vm.expectRevert(Bls12381.BadKey.selector);
        h.checkKey(otherLowX, k);

        bytes memory otherSign = bytes.concat(c);
        otherSign[0] = bytes1(uint8(c[0]) ^ 0x20);
        vm.expectRevert(Bls12381.BadKey.selector);
        h.checkKey(otherSign, k);
    }

    /// @dev The sign flag picks between y and p - y: flipping both gives the negated key, which is a valid key too.
    function test_checkKey_theSignFlagPicksTheRoot() public view {
        for (uint256 i = 0; i < 4; ++i) {
            bytes memory c = bytes.concat(compressed[i]);
            c[0] = bytes1(uint8(c[0]) ^ 0x20);
            h.checkKey(c, _negate(keys[i]));
        }
    }

    /// @dev A point with the key's x and another y, on the same side of p / 2, is not on the curve.
    function test_checkKey_offTheCurve() public {
        (uint256 xHi, uint256 xLo, uint256 yHi, uint256 yLo) = abi.decode(keys[0], (uint256, uint256, uint256, uint256));
        bytes memory off = abi.encode(xHi, xLo, yHi, yLo ^ 2);
        vm.expectRevert(abi.encodeWithSelector(Bls12381.PrecompileFailed.selector, address(0x0b)));
        h.checkKey(compressed[0], off);
    }

    function test_malformedPointsFailThePrecompiles() public {
        bytes memory bad = bytes.concat(keys[0]);
        bad[0] = 0x01; // a coordinate's padding must be zero
        vm.expectRevert(abi.encodeWithSelector(Bls12381.PrecompileFailed.selector, address(0x0b)));
        h.add(bad, keys[1]);
        bytes memory badSignature = bytes.concat(signature);
        badSignature[0] = 0x01;
        vm.expectRevert(abi.encodeWithSelector(Bls12381.PrecompileFailed.selector, address(0x0f)));
        h.verify(keys[0], badSignature, abi.encodePacked(voteHash));
    }

    function test_hashToG2IsAPointOfG2() public view {
        bytes memory point = h.hashToG2("xindex");
        assertEq(point.length, 256);
        assertTrue(keccak256(point) != keccak256(h.hashToG2("xindex!")), "another message, another point");
    }

    /// @dev (x, p - y), with the 384-bit subtraction done on the two words of y.
    function _negate(bytes memory key) internal pure returns (bytes memory) {
        (uint256 xHi, uint256 xLo, uint256 yHi, uint256 yLo) = abi.decode(key, (uint256, uint256, uint256, uint256));
        uint256 borrow = yLo > P_LO ? 1 : 0;
        uint256 lo;
        unchecked {
            lo = P_LO - yLo;
        }
        return abi.encode(xHi, xLo, P_HI - yHi - borrow, lo);
    }
}
