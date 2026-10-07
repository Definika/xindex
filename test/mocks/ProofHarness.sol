// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RlpReader} from "../../src/libraries/RlpReader.sol";
import {MerklePatricia} from "../../src/libraries/MerklePatricia.sol";
import {Bls12381} from "../../src/libraries/Bls12381.sol";

/// @notice Calls the proof libraries externally, so a test can expect their reverts.
contract ProofHarness {
    using RlpReader for RlpReader.Item;

    function count(bytes memory data) external pure returns (uint256) {
        return RlpReader.toItem(data).count();
    }

    function at(bytes memory data, uint256 index) external pure returns (bytes memory) {
        return RlpReader.toItem(data).at(index).toBytes();
    }

    function lengthAt(bytes memory data, uint256 index) external pure returns (uint256) {
        return RlpReader.toItem(data).at(index).len;
    }

    function byteAt(bytes memory data, uint256 offset) external pure returns (uint256) {
        return RlpReader.toItem(data).byteAt(offset);
    }

    function wordAt(bytes memory data, uint256 offset) external pure returns (bytes32) {
        return RlpReader.toItem(data).wordAt(offset);
    }

    function slice(bytes memory data, uint256 offset, uint256 len) external pure returns (bytes memory) {
        return RlpReader.toItem(data).slice(offset, len);
    }

    function uintAt(bytes memory data, uint256 offset, uint256 n) external pure returns (uint256) {
        return RlpReader.toItem(data).uintAt(offset, n);
    }

    function toBytes32(bytes memory data) external pure returns (bytes32) {
        return RlpReader.toItem(data).toBytes32();
    }

    function toUint(bytes memory data) external pure returns (uint256) {
        return RlpReader.toItem(data).toUint();
    }

    function toBytes(bytes memory data) external pure returns (bytes memory) {
        return RlpReader.toItem(data).toBytes();
    }

    function get(bytes32 root, bytes32 key, bytes[] memory proof) external pure returns (bool, bytes memory) {
        (bool found, RlpReader.Item memory value) = MerklePatricia.get(root, key, proof);
        return (found, found ? value.toBytes() : bytes(""));
    }

    function getKey(bytes32 root, bytes32 key, uint256 keyNibbles, bytes[] memory proof)
        external
        pure
        returns (bool, bytes memory)
    {
        (bool found, RlpReader.Item memory value) = MerklePatricia.get(root, key, keyNibbles, proof);
        return (found, found ? value.toBytes() : bytes(""));
    }

    function storageAt(
        bytes32 stateRoot,
        address account,
        bytes32 slot,
        bytes[] memory accountProof,
        bytes[] memory storageProof
    ) external pure returns (bytes32) {
        (bool exists, bytes32 root) = MerklePatricia.storageRoot(stateRoot, account, accountProof);
        return exists ? MerklePatricia.slotAt(root, slot, storageProof) : bytes32(0);
    }

    function checkKey(bytes memory compressed, bytes memory key) external view returns (bytes memory) {
        return Bls12381.checkKey(compressed, key);
    }

    function add(bytes memory a, bytes memory b) external view returns (bytes memory) {
        return Bls12381.add(a, b);
    }

    function verify(bytes memory key, bytes memory signature, bytes memory message) external view returns (bool) {
        return Bls12381.verify(key, signature, message);
    }

    function hashToG2(bytes memory message) external view returns (bytes memory) {
        return Bls12381.hashToG2(message);
    }
}
