// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StorageProof} from "../src/StorageProof.sol";

/// @notice M6: a real BNB Chain header and `eth_getProof` for WBNB's slot 0, verified on the Prague EVM.
contract StorageProofTest is Test {
    StorageProof prover;
    bytes header;
    bytes32 blockHash;
    address account;
    bytes32 slot;
    bytes32 value;
    bytes[] accountProof;
    bytes[] storageProof;

    function setUp() public {
        prover = new StorageProof();
        string memory json = vm.readFile("test/storage-fixture.json");
        header = vm.parseJsonBytes(json, ".header");
        blockHash = vm.parseJsonBytes32(json, ".blockHash");
        account = vm.parseJsonAddress(json, ".account");
        slot = vm.parseJsonBytes32(json, ".slot");
        value = vm.parseJsonBytes32(json, ".value");
        bytes[] memory a = vm.parseJsonBytesArray(json, ".accountProof");
        bytes[] memory s = vm.parseJsonBytesArray(json, ".storageProof");
        for (uint256 i = 0; i < a.length; ++i) {
            accountProof.push(a[i]);
        }
        for (uint256 i = 0; i < s.length; ++i) {
            storageProof.push(s[i]);
        }
    }

    function test_theRecordedSlotIsProved() public view {
        bytes memory h = header;
        bytes[] memory ap = accountProof;
        bytes[] memory sp = storageProof;
        uint256 before = gasleft();
        bytes32 got = prover.prove(h, blockHash, account, ap, slot, sp);
        uint256 used = before - gasleft();
        assertEq(got, value, "the proved value is eth_getStorageAt's");
        console2.log("M6: gas to prove a BNB Chain storage slot from its block hash", used);
        console2.log("calldata bytes", h.length + _size(ap) + _size(sp));
    }

    function test_aTamperedNodeIsRefused() public {
        bytes[] memory sp = storageProof;
        sp[2][40] = bytes1(uint8(sp[2][40]) ^ 1);
        vm.expectRevert(abi.encodeWithSelector(StorageProof.BadProof.selector, 2));
        prover.prove(header, blockHash, account, accountProof, slot, sp);
    }

    function test_aWrongHeaderIsRefused() public {
        vm.expectRevert(StorageProof.BadHeader.selector);
        prover.prove(header, bytes32(uint256(blockHash) ^ 1), account, accountProof, slot, storageProof);
    }

    /// @dev Slot 1's path leaves the recorded nodes at the second: its branch child is a different hash.
    function test_theNodesProveNoOtherSlot() public {
        vm.expectRevert(abi.encodeWithSelector(StorageProof.BadProof.selector, 1));
        prover.prove(header, blockHash, account, accountProof, bytes32(uint256(1)), storageProof);
    }

    function _size(bytes[] memory list) private pure returns (uint256 total) {
        for (uint256 i = 0; i < list.length; ++i) {
            total += list[i].length;
        }
    }
}
