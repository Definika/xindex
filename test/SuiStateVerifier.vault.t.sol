// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SuiStateVerifier} from "../src/verifiers/SuiStateVerifier.sol";
import {ISuiStateVerifier} from "../src/interfaces/ISuiStateVerifier.sol";
import {SuiBcs} from "../src/libraries/SuiBcs.sol";
import {SuiAttestBase} from "./SuiStateVerifier.attest.t.sol";

/// @notice The Sui vault's own record (`sui/`): `test/fixtures/sui/vault-attest.json` holds the slots and values its Move
///         test attests, under Sui testnet's registry id and the vault object's id, and the record the Move vault writes
///         for them, which `sui/tests/vault_tests.move` checks byte for byte against the `Attestation` it froze
///         (`sui/tests/fixtures/vectors.py` writes the vector with Solidity's own encoder). Here the verifier rebuilds
///         the same record, and proves it end to end from a certified checkpoint holding that object. The BLS
///         precompiles exist from Prague on, so this suite runs on it.
/// forge-config: default.evm_version = "prague"
contract SuiStateVerifierVaultTest is SuiAttestBase {
    uint256 chainId;
    bytes32 vaultId;
    uint64 timestampMs;
    bytes32[] slots;
    bytes32[] values;
    bytes record;

    function setUp() public {
        string memory json = vm.readFile("test/fixtures/sui/vault-attest.json");
        chainId = vm.parseJsonUint(json, ".chainId");
        vaultId = vm.parseJsonBytes32(json, ".vaultId");
        timestampMs = uint64(vm.parseJsonUint(json, ".timestampMs"));
        slots = vm.parseJsonBytes32Array(json, ".slots");
        values = vm.parseJsonBytes32Array(json, ".values");
        record = vm.parseJsonBytes(json, ".record");
        committee = _signers("committee of epoch 7", powers);
        verifier = new SuiStateVerifier(
            chainId, vaultId, PACKAGE_ID, EPOCH, _hash(committee.committee), timestampMs - 30 minutes * 1000
        );
        vm.warp(timestampMs / 1000 + 1 hours);
    }

    /// @dev The Move vault's record is the verifier's for the same slots and values; the object's contents are its id
    ///      and then the record as a byte string, its 448 bytes written `0xc0 0x03`, as the Move test reads them.
    function test_theSuiVaultsRecordIsTheVerifiers() public view {
        assertEq(chainId, 10_803_649_406_359_875_205, "sui:testnet");
        assertEq(verifier.attestRecord(timestampMs, slots, values), record);
        assertEq(record.length, 448);
        assertEq(SuiBcs.uleb128(record.length), hex"c003");
    }

    /// @dev The vault's `Attestation`, in a checkpoint's artifacts tree a committee certified, proves its slots.
    function test_theSuiVaultsAttestationVerifies() public view {
        Attest memory a = _default();
        a.chainId = chainId;
        a.vaultId = vaultId;
        a.recordMs = timestampMs;
        a.slots = slots;
        a.values = values;
        a.checkpointMs = timestampMs + 400;
        assertEq(_record(a), record);
        ISuiStateVerifier.AttestProof memory p = _proof(a);
        (uint256 number, uint256 timestamp, bytes32[] memory got) =
            verifier.verifySlots(address(uint160(uint256(vaultId))), slots, abi.encode(p));
        assertEq(number, p.checkpoint.sequenceNumber);
        assertEq(timestamp, timestampMs / 1000);
        assertEq(got.length, values.length);
        for (uint256 i = 0; i < got.length; ++i) {
            assertEq(got[i], values[i]);
        }
    }
}
