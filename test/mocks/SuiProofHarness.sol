// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Blake2b} from "../../src/libraries/Blake2b.sol";
import {Bls12381MinSig} from "../../src/libraries/Bls12381MinSig.sol";
import {SuiBcs} from "../../src/libraries/SuiBcs.sol";

/// @notice Calls the Sui proof libraries externally, so a test can expect their reverts.
contract SuiProofHarness {
    function hash256(bytes memory data) external view returns (bytes32) {
        return Blake2b.hash256(data);
    }

    function blake2b(bytes memory data, uint256 outLength) external view returns (bytes32, bytes32) {
        return Blake2b.hash(data, outLength);
    }

    function verify(bytes memory key, bytes memory signature, bytes memory message) external view returns (bool) {
        return Bls12381MinSig.verify(key, signature, message);
    }

    function verifyHashed(bytes memory key, bytes memory signature, bytes memory point) external view returns (bool) {
        return Bls12381MinSig.verifyHashed(key, signature, point);
    }

    function hashToG1(bytes memory message, bytes memory dst) external view returns (bytes memory) {
        return Bls12381MinSig.hashToG1(message, dst);
    }

    function addKey(bytes memory sum, bytes memory keys, uint256 index) external view returns (bytes memory) {
        Bls12381MinSig.addKey(sum, keys, index);
        return sum;
    }

    function copyKey(bytes memory to, uint256 i, bytes memory from, uint256 j) external pure returns (bytes memory) {
        Bls12381MinSig.copyKey(to, i, from, j);
        return to;
    }

    function writeCommitteeEntry(bytes memory body, uint256 i, bytes32 w0, bytes32 w1, bytes32 w2, uint64 power)
        external
        pure
        returns (bytes memory)
    {
        SuiBcs.writeCommitteeEntry(body, i, w0, w1, w2, power);
        return body;
    }

    function compressKey(bytes memory keys, uint256 index) external pure returns (bytes memory) {
        (bytes32 w0, bytes32 w1, bytes32 w2) = Bls12381MinSig.compressKey(keys, index);
        return bytes.concat(w0, w1, w2);
    }

    function le64(uint64 v) external pure returns (bytes8) {
        return SuiBcs.le64(v);
    }

    function uleb128(uint256 n) external pure returns (bytes memory) {
        return SuiBcs.uleb128(n);
    }

    function objectDigest(SuiBcs.MoveObject memory o) external view returns (bytes32) {
        return SuiBcs.objectDigest(o);
    }

    function artifactLeaf(bytes32 objectId, uint64 version, bytes32 digest) external view returns (bytes32) {
        return SuiBcs.artifactLeaf(objectId, version, digest);
    }

    function merkleRoot(bytes32 leaf, uint256 index, bytes32[] memory path) external view returns (bytes32) {
        return SuiBcs.merkleRoot(leaf, index, path);
    }

    function artifactsDigest(bytes32 root) external view returns (bytes32) {
        return SuiBcs.artifactsDigest(root);
    }
}
