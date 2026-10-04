// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProofHarness} from "./mocks/ProofHarness.sol";

/// @notice Research for Solana's state verifier (`design/2026-10-03-solana-state-proof.md`): Ethereum checks a real
///         Alpenglow certificate with the library BNB Chain's verifier uses. Devnet's genesis certificate, 11 of epoch
///         1167's 17 ranks over `[6] ++ slot ++ block id ++ shred version`, verifies on the EIP-2537 precompiles under
///         the same ciphersuite. Stakes and the rank map are not checked here: public RPC no longer serves epoch 1167's.
/// forge-config: default.evm_version = "prague"
contract SolanaCertificateTest is Test {
    ProofHarness h;
    bytes[] keys;
    bytes[] compressed;
    bytes signature;
    bytes payload;
    uint256 slot;
    bytes32 blockId;
    uint256 shredVersion;

    function setUp() public {
        h = new ProofHarness();
        string memory json = vm.readFile("test/fixtures/solana/genesis-cert.json");
        bytes[] memory k = vm.parseJsonBytesArray(json, ".keys");
        bytes[] memory c = vm.parseJsonBytesArray(json, ".keysCompressed");
        for (uint256 i = 0; i < k.length; ++i) {
            keys.push(k[i]);
            compressed.push(c[i]);
        }
        signature = vm.parseJsonBytes(json, ".signature");
        payload = vm.parseJsonBytes(json, ".payload");
        slot = vm.parseJsonUint(json, ".slot");
        blockId = vm.parseJsonBytes32(json, ".blockId");
        shredVersion = vm.parseJsonUint(json, ".shredVersion");
    }

    function _payload(uint8 tag, uint256 s, bytes32 id, uint256 shred) internal pure returns (bytes memory) {
        return abi.encodePacked(tag, _le64(s), id, _le16(shred));
    }

    function _le64(uint256 x) internal pure returns (bytes8 out) {
        for (uint256 i = 0; i < 8; ++i) {
            out |= bytes8(bytes1(uint8(x >> (8 * i)))) >> (8 * i);
        }
    }

    function _le16(uint256 x) internal pure returns (bytes2) {
        return bytes2(uint16((x & 0xff) << 8 | (x >> 8)));
    }

    function _aggregate(uint256 skip) internal view returns (bytes memory agg) {
        for (uint256 i = 0; i < keys.length; ++i) {
            if (i == skip) continue;
            agg = agg.length == 0 ? keys[i] : h.add(agg, keys[i]);
        }
    }

    function test_devnetsGenesisCertificateVerifiesOnEthereum() public {
        assertEq(
            payload, _payload(6, slot, blockId, shredVersion), "the payload is Alpenglow's genesis vote, rebuilt here"
        );
        assertEq(payload.length, 43);
        for (uint256 i = 0; i < keys.length; ++i) {
            assertEq(h.checkKey(compressed[i], keys[i]), keys[i], "each key is the one its vote account registers");
        }
        bytes memory agg = _aggregate(type(uint256).max);
        uint256 before = gasleft();
        bool ok = h.verify(agg, signature, payload);
        emit log_named_uint("gas: hash to G2 and the pairing check", before - gasleft());
        assertTrue(ok, "the aggregate of the 11 signers' keys verifies the certificate");
    }

    function test_anyOtherVoteOrSignerSetFails() public view {
        bytes memory agg = _aggregate(type(uint256).max);
        assertFalse(h.verify(agg, signature, _payload(6, slot + 1, blockId, shredVersion)), "another slot");
        assertFalse(h.verify(agg, signature, _payload(6, slot, blockId, shredVersion + 1)), "another cluster");
        assertFalse(h.verify(agg, signature, _payload(1, slot, blockId, shredVersion)), "a notarize vote");
        assertFalse(h.verify(agg, signature, _payload(6, slot, ~blockId, shredVersion)), "another block");
        assertFalse(h.verify(_aggregate(0), signature, payload), "a signer missing");
    }
}
