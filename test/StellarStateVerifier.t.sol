// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StellarStateVerifier} from "../src/verifiers/StellarStateVerifier.sol";
import {IStellarStateVerifier} from "../src/interfaces/IStellarStateVerifier.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";

/// @notice The Stellar state verifier against the statement's own outputs. `proofs/stellar/statement/fixtures/attest.json`
///         is the public values the Rust statement computes for its synthetic attest, with the slots, values and record
///         behind them, so the record's encoding and the public values' layout are pinned on both sides.
///         `fixtures/mainnet.json` gives a real mainnet ledger: pubnet's network id, Tier 1's quorum set as its
///         validators commit to it, the ledger's number and its close time. The Groth16 check is mocked.
contract StellarStateVerifierTest is Test {
    string constant ATTEST = "proofs/stellar/statement/fixtures/attest.json";
    string constant MAINNET = "proofs/stellar/statement/fixtures/mainnet.json";
    bytes32 constant KEY = keccak256("the Stellar program");
    /// @dev `stellar:pubnet` and `stellar:testnet` in the factory's registry.
    uint256 constant PUBNET = 839_718_837_228_939_926;
    uint256 constant TESTNET = 17_667_989_177_921_016_935;

    MockSP1Verifier sp1;
    StellarStateVerifier verifier;
    string attest;
    bytes32 vaultId;
    bytes32[] slots;
    bytes32[] values;
    bytes publicValues;
    uint64 closeTime;
    uint64 ledger;

    function setUp() public {
        sp1 = new MockSP1Verifier();
        attest = vm.readFile(ATTEST);
        vaultId = vm.parseJsonBytes32(attest, ".vaultId");
        slots = vm.parseJsonBytes32Array(attest, ".slots");
        values = vm.parseJsonBytes32Array(attest, ".values");
        publicValues = vm.parseJsonBytes(attest, ".publicValues");
        closeTime = uint64(vm.parseJsonUint(attest, ".closeTime"));
        ledger = uint64(vm.parseJsonUint(attest, ".ledger"));
        verifier = new StellarStateVerifier(
            sp1,
            KEY,
            vm.parseJsonBytes32(attest, ".networkId"),
            vm.parseJsonBytes32(attest, ".quorumSetHash"),
            vm.parseJsonUint(attest, ".chainId"),
            vaultId
        );
        vm.warp(closeTime + 1 hours);
    }

    function _vault() internal view returns (address) {
        return address(uint160(uint256(vaultId)));
    }

    /// @dev The mock's proof of `pv`, written here as `MockSP1Verifier.prove` writes it, so that building a proof makes
    ///      no call that an `expectRevert` before it would take for its own.
    function _proof(bytes memory pv, bytes32[] memory vals) internal pure returns (bytes memory) {
        bytes memory proof = abi.encode(keccak256(abi.encode(KEY, pv)));
        return abi.encode(IStellarStateVerifier.SlotsProof({publicValues: pv, proof: proof, values: vals}));
    }

    function _pv(bytes32 network, bytes32 quorumSet, uint64 n, uint64 t, bytes32 vault, bytes32 recordHash)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(network, quorumSet, n, t, vault, recordHash);
    }

    /// @dev The record the Rust statement proved is Solidity's encoding of the slots and values, and the verifier
    ///      returns them with the ledger and its close time.
    function test_verifySlots_theStatementsAttest() public view {
        assertEq(
            vm.parseJsonBytes(attest, ".record"),
            abi.encode(verifier.ATTEST_DOMAIN(), PUBNET, vaultId, slots, values),
            "the vault's record is abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots, values)"
        );
        assertEq(verifier.ATTEST_DOMAIN(), keccak256("xindex.v4.vault-attest"));
        (uint256 n, uint256 t, bytes32[] memory got) =
            verifier.verifySlots(_vault(), slots, _proof(publicValues, values));
        assertEq(n, ledger);
        assertEq(t, closeTime);
        assertEq(got.length, 2);
        assertEq(got[0], values[0]);
        assertEq(got[1], values[1]);
    }

    /// @dev Mainnet's real public values, as the program commits them for an attest in the fixture's ledger: pubnet's
    ///      network id, the quorum set Tier 1 commits to (7 of 10 organisations, 2 of 3 validators each), the ledger
    ///      and its close time.
    function _mainnet() internal view returns (bytes32 network, bytes32 quorumSet, uint64 n, uint64 t) {
        string memory m = vm.readFile(MAINNET);
        network = vm.parseJsonBytes32(m, ".networkId");
        quorumSet = sha256(vm.parseJsonBytes(m, ".quorumSet"));
        n = uint64(vm.parseJsonUint(m, ".ledger"));
        t = uint64(vm.parseJsonUint(m, ".closeTime"));
    }

    function test_verifySlots_onMainnetValues() public {
        (bytes32 network, bytes32 quorumSet, uint64 n, uint64 t) = _mainnet();
        assertEq(network, sha256("Public Global Stellar Network ; September 2015"));
        StellarStateVerifier pubnet = new StellarStateVerifier(sp1, KEY, network, quorumSet, PUBNET, vaultId);
        bytes32 recordHash = keccak256(abi.encode(pubnet.ATTEST_DOMAIN(), PUBNET, vaultId, slots, values));
        bytes memory proof = _proof(_pv(network, quorumSet, n, t, vaultId, recordHash), values);
        vm.warp(t + 10 minutes);
        uint256 before = gasleft();
        (uint256 number, uint256 time, bytes32[] memory got) = pubnet.verifySlots(_vault(), slots, proof);
        emit log_named_uint("verifySlots gas, the Groth16 check mocked", before - gasleft());
        assertEq(number, n);
        assertEq(time, t);
        assertEq(got[0], values[0]);
    }

    /// @dev Each verifier pins its own Tier 1: a proof under mainnet's quorum set is no proof to a verifier pinned to
    ///      another.
    function test_verifySlots_onlyThePinnedQuorumSet() public {
        (, bytes32 quorumSet, uint64 n, uint64 t) = _mainnet();
        bytes32 recordHash = keccak256(abi.encode(verifier.ATTEST_DOMAIN(), PUBNET, vaultId, slots, values));
        bytes memory proof = _proof(_pv(verifier.NETWORK_ID(), quorumSet, n, t, vaultId, recordHash), values);
        vm.warp(t + 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(IStellarStateVerifier.WrongQuorumSet.selector, quorumSet));
        verifier.verifySlots(_vault(), slots, proof);
    }

    function test_verifySlots_refusals() public {
        // Another account than the vault's.
        vm.expectRevert(abi.encodeWithSelector(IStellarStateVerifier.WrongAccount.selector, address(1)));
        verifier.verifySlots(address(1), slots, _proof(publicValues, values));
        // One value too few.
        bytes32[] memory one = new bytes32[](1);
        one[0] = values[0];
        vm.expectRevert(IStellarStateVerifier.LengthMismatch.selector);
        verifier.verifySlots(_vault(), slots, _proof(publicValues, one));
        // A proof of other public values.
        bytes memory forged = abi.encode(
            IStellarStateVerifier.SlotsProof({
                publicValues: publicValues,
                proof: sp1.prove(KEY, abi.encodePacked(publicValues, uint8(0))),
                values: values
            })
        );
        vm.expectRevert(MockSP1Verifier.Rejected.selector);
        verifier.verifySlots(_vault(), slots, forged);
        // A proof under another program's key.
        bytes memory otherProgram = abi.encode(
            IStellarStateVerifier.SlotsProof({
                publicValues: publicValues, proof: sp1.prove(keccak256("another program"), publicValues), values: values
            })
        );
        vm.expectRevert(MockSP1Verifier.Rejected.selector);
        verifier.verifySlots(_vault(), slots, otherProgram);
    }

    function test_verifySlots_thePublicValuesMustBeThisVerifiers() public {
        bytes32 recordHash = keccak256(abi.encode(verifier.ATTEST_DOMAIN(), PUBNET, vaultId, slots, values));
        bytes32 network = verifier.NETWORK_ID();
        bytes32 quorumSet = verifier.QUORUM_SET_HASH();
        bytes32 other = keccak256("other");
        vm.expectRevert(abi.encodeWithSelector(IStellarStateVerifier.WrongNetwork.selector, other));
        verifier.verifySlots(
            _vault(), slots, _proof(_pv(other, quorumSet, ledger, closeTime, vaultId, recordHash), values)
        );
        vm.expectRevert(abi.encodeWithSelector(IStellarStateVerifier.WrongQuorumSet.selector, other));
        verifier.verifySlots(
            _vault(), slots, _proof(_pv(network, other, ledger, closeTime, vaultId, recordHash), values)
        );
        vm.expectRevert(abi.encodeWithSelector(IStellarStateVerifier.WrongVault.selector, other));
        verifier.verifySlots(
            _vault(), slots, _proof(_pv(network, quorumSet, ledger, closeTime, other, recordHash), values)
        );
    }

    /// @dev A ledger that closed a day ago is the oldest a proof may show.
    function test_verifySlots_aDayOldAtMost() public {
        vm.warp(uint256(closeTime) + 1 days);
        verifier.verifySlots(_vault(), slots, _proof(publicValues, values));
        vm.warp(uint256(closeTime) + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IStellarStateVerifier.TooOld.selector, closeTime));
        verifier.verifySlots(_vault(), slots, _proof(publicValues, values));
        assertEq(verifier.MAX_LAG(), 1 days);
    }

    /// @dev The record fixes the slots, their order, the values and the chain: a proof of one attest answers nothing
    ///      else.
    function test_verifySlots_onlyTheAttestedSlotsAndValues() public {
        bytes32 recordHash = keccak256(abi.encode(verifier.ATTEST_DOMAIN(), PUBNET, vaultId, slots, values));
        bytes32[] memory otherValues = new bytes32[](2);
        otherValues[0] = values[0];
        otherValues[1] = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(IStellarStateVerifier.NotAttested.selector, recordHash));
        verifier.verifySlots(_vault(), slots, _proof(publicValues, otherValues));
        bytes32[] memory reordered = new bytes32[](2);
        (reordered[0], reordered[1]) = (slots[1], slots[0]);
        bytes32[] memory swappedValues = new bytes32[](2);
        (swappedValues[0], swappedValues[1]) = (values[1], values[0]);
        vm.expectRevert(abi.encodeWithSelector(IStellarStateVerifier.NotAttested.selector, recordHash));
        verifier.verifySlots(_vault(), reordered, _proof(publicValues, swappedValues));
        bytes32[] memory first = new bytes32[](1);
        first[0] = slots[0];
        bytes32[] memory firstValue = new bytes32[](1);
        firstValue[0] = values[0];
        vm.expectRevert(abi.encodeWithSelector(IStellarStateVerifier.NotAttested.selector, recordHash));
        verifier.verifySlots(_vault(), first, _proof(publicValues, firstValue));
        // The same attest on testnet's verifier: another chain id, another record.
        StellarStateVerifier testnet =
            new StellarStateVerifier(sp1, KEY, verifier.NETWORK_ID(), verifier.QUORUM_SET_HASH(), TESTNET, vaultId);
        vm.expectRevert(abi.encodeWithSelector(IStellarStateVerifier.NotAttested.selector, recordHash));
        testnet.verifySlots(_vault(), slots, _proof(publicValues, values));
    }

    function test_constructor() public {
        assertEq(address(verifier.SP1_VERIFIER()), address(sp1));
        assertEq(verifier.PROGRAM_KEY(), KEY);
        assertEq(verifier.CHAIN_ID(), PUBNET);
        assertEq(verifier.VAULT_ID(), vaultId);
        bytes32 n = verifier.NETWORK_ID();
        bytes32 q = verifier.QUORUM_SET_HASH();
        vm.expectRevert(IStellarStateVerifier.ZeroValue.selector);
        new StellarStateVerifier(ISP1Verifier(address(0)), KEY, n, q, PUBNET, vaultId);
        vm.expectRevert(IStellarStateVerifier.ZeroValue.selector);
        new StellarStateVerifier(sp1, bytes32(0), n, q, PUBNET, vaultId);
        vm.expectRevert(IStellarStateVerifier.ZeroValue.selector);
        new StellarStateVerifier(sp1, KEY, bytes32(0), q, PUBNET, vaultId);
        vm.expectRevert(IStellarStateVerifier.ZeroValue.selector);
        new StellarStateVerifier(sp1, KEY, n, bytes32(0), PUBNET, vaultId);
        vm.expectRevert(IStellarStateVerifier.ZeroValue.selector);
        new StellarStateVerifier(sp1, KEY, n, q, 0, vaultId);
        vm.expectRevert(IStellarStateVerifier.ZeroValue.selector);
        new StellarStateVerifier(sp1, KEY, n, q, PUBNET, bytes32(0));
    }
}
