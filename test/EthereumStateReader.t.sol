// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EthereumStateReader} from "../src/verifiers/EthereumStateReader.sol";
import {MerklePatricia} from "../src/libraries/MerklePatricia.sol";
import {RlpWriter} from "./utils/RlpWriter.sol";

/// @notice The snapshot exit's state reader, on a real `eth_getProof` (BNB Chain's trie is Ethereum's) and on a
///         one-account trie built here.
contract EthereumStateReaderTest is Test {
    EthereumStateReader reader;
    bytes32 stateRoot;
    address account;
    bytes32 slot;
    bytes32 value;
    bytes[] accountProof;
    bytes[] storageProof;

    function setUp() public {
        reader = new EthereumStateReader();
        string memory json = vm.readFile("test/fixtures/bnb/wbnb-slot0.json");
        stateRoot = vm.parseJsonBytes32(json, ".stateRoot");
        account = vm.parseJsonAddress(json, ".account");
        slot = vm.parseJsonBytes32(json, ".slot");
        value = vm.parseJsonBytes32(json, ".value");
        accountProof = vm.parseJsonBytesArray(json, ".accountProof");
        storageProof = vm.parseJsonBytesArray(json, ".storageProof");
    }

    function _proof(bytes[] memory a, bytes[] memory s, uint256 slots) internal pure returns (bytes memory) {
        bytes[][] memory each = new bytes[][](slots);
        for (uint256 i = 0; i < slots; ++i) {
            each[i] = s;
        }
        return abi.encode(a, each);
    }

    function test_readsARealSlot() public view {
        bytes32[] memory slots = new bytes32[](2);
        (slots[0], slots[1]) = (slot, slot);
        bytes32[] memory values = reader.readSlots(stateRoot, account, slots, _proof(accountProof, storageProof, 2));
        assertEq(values[0], value);
        assertEq(values[1], value);
    }

    function test_refusals() public {
        bytes32[] memory slots = new bytes32[](2);
        vm.expectRevert(EthereumStateReader.LengthMismatch.selector);
        reader.readSlots(stateRoot, account, slots, _proof(accountProof, storageProof, 1));
        vm.expectRevert(abi.encodeWithSelector(MerklePatricia.BadProof.selector, 0));
        reader.readSlots(bytes32(uint256(stateRoot) ^ 1), account, slots, _proof(accountProof, storageProof, 2));
    }

    /// @dev A trie of one account: any other account is absent, and every slot of it reads zero.
    function test_anAbsentAccountReadsZero() public view {
        bytes[] memory fields = new bytes[](4);
        fields[0] = RlpWriter.str(hex"01");
        fields[1] = hex"80";
        fields[2] = RlpWriter.str(abi.encodePacked(keccak256("storage")));
        fields[3] = RlpWriter.str(abi.encodePacked(keccak256("")));
        bytes[] memory leaf = new bytes[](2);
        leaf[0] = RlpWriter.str(abi.encodePacked(bytes1(0x20), keccak256(abi.encodePacked(account))));
        leaf[1] = RlpWriter.str(RlpWriter.list(fields));
        bytes[] memory proof = new bytes[](1);
        proof[0] = RlpWriter.list(leaf);
        bytes32 root = keccak256(proof[0]);

        bytes32[] memory slots = new bytes32[](1);
        slots[0] = slot;
        bytes32[] memory values = reader.readSlots(root, address(1), slots, _proof(proof, new bytes[](0), 1));
        assertEq(values[0], 0);
    }
}
