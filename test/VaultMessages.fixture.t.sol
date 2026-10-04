// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";

/// @notice Pins `test/fixtures/vault-messages.json`, which every vault twin decodes, against Solidity: each payload is
///         `VaultMessages.encode` of its fields, and each id its keccak, so a twin that reads the fixture right reads
///         what the hub and the factory send.
contract VaultMessagesFixtureTest is Test {
    string constant FIXTURE = "test/fixtures/vault-messages.json";

    /// @dev C1-02: one message per kind from INTAKE_SETTLED to VERIFIER_ROTATION, in order, each built here from its
    ///      fields with the body its kind's NatSpec in `VaultMessages` gives.
    function test_C102_theMessageFixtureIsVaultMessagesEncode() public view {
        string memory json = vm.readFile(FIXTURE);
        uint256 sourceChainId = vm.parseJsonUint(json, ".sourceChainId");
        uint256 destChainId = vm.parseJsonUint(json, ".destChainId");
        bytes32 vault = vm.parseJsonBytes32(json, ".vault");
        address index = vm.parseJsonAddress(json, ".index");
        uint8 first = VaultMessages.INTAKE_SETTLED;
        uint8 last = VaultMessages.VERIFIER_ROTATION;
        for (uint8 kind = first; kind <= last; ++kind) {
            string memory at = string.concat(".messages[", vm.toString(kind - first), "]");
            assertEq(vm.parseJsonUint(json, string.concat(at, ".kind")), kind, "one message per kind, in order");
            bytes memory body = _body(json, string.concat(at, ".fields"), kind);
            assertEq(body, vm.parseJsonBytes(json, string.concat(at, ".body")), "the body is its fields' encoding");
            bytes memory payload = VaultMessages.encode(
                VaultMessages.Message({
                    sourceChainId: sourceChainId,
                    kind: kind,
                    destChainId: destChainId,
                    vault: vault,
                    index: index,
                    nonce: vm.parseJsonUint(json, string.concat(at, ".nonce")),
                    body: body
                })
            );
            assertEq(payload, vm.parseJsonBytes(json, string.concat(at, ".payload")), "the payload is VaultMessages'");
            assertEq(keccak256(payload), vm.parseJsonBytes32(json, string.concat(at, ".id")), "the id is its keccak");
        }
        assertFalse(vm.keyExistsJson(json, string.concat(".messages[", vm.toString(last - first + 1), "]")));
    }

    /// @dev The body of a message of `kind` from the fields at `at`.
    function _body(string memory json, string memory at, uint8 kind) internal pure returns (bytes memory) {
        if (kind == VaultMessages.INTAKE_SETTLED || kind == VaultMessages.INTAKE_FAILED) {
            return abi.encode(vm.parseJsonUint(json, string.concat(at, ".intakeId")));
        }
        if (kind == VaultMessages.MIGRATE) {
            return abi.encode(
                vm.parseJsonAddress(json, string.concat(at, ".newIndex")),
                vm.parseJsonBytes32(json, string.concat(at, ".token")),
                vm.parseJsonUint(json, string.concat(at, ".amount"))
            );
        }
        if (kind == VaultMessages.CAP_UPDATE) {
            return abi.encode(
                vm.parseJsonBytes32(json, string.concat(at, ".token")),
                vm.parseJsonUint(json, string.concat(at, ".cap")),
                vm.parseJsonUint(json, string.concat(at, ".floor"))
            );
        }
        if (kind == VaultMessages.FREEZE) return abi.encode(vm.parseJsonUint(json, string.concat(at, ".until")));
        if (kind == VaultMessages.FREEZER_CHANGE) {
            return abi.encode(vm.parseJsonBytes32(json, string.concat(at, ".freezer")));
        }
        return abi.encode(
            vm.parseJsonBytes32(json, string.concat(at, ".p1")), vm.parseJsonBytes32(json, string.concat(at, ".p2"))
        );
    }
}
