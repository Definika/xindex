// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {DeployVault} from "../script/DeployVault.s.sol";
import {DeployStateVerifier} from "../script/DeployStateVerifier.s.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {CometBftStateVerifier} from "../src/verifiers/CometBftStateVerifier.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";
import {MockRiscZeroVerifier} from "./mocks/MockRiscZeroVerifier.sol";

/// @dev Nothing but a name: answers the two identity views and accepts every proof.
contract LyingSP1 {
    function VERIFIER_HASH() external pure returns (bytes32) {
        return 0x0e78f4db7a6771a3a6a7d9c3b0de6fe73d58781368967a7fe84d87aefffec896;
    }

    function VERSION() external pure returns (string memory) {
        return "v6.0.0";
    }

    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
}

contract LyingRisc0 {
    function SELECTOR() external pure returns (bytes4) {
        return 0x73c457ba;
    }

    function VERSION() external pure returns (string memory) {
        return "3.0.0";
    }
}

contract V4Test is Test {
    string injective = vm.readFile("test/fixtures/injective/anchor.json");

    function test_V4_A701_lyingContractsAndOwnedProxiesPassCheckVerifiers() public {
        DeployVault d = new DeployVault();
        // 1. contracts that merely name themselves
        d.checkVerifiers(address(new LyingSP1()), address(new LyingRisc0()));
        // 2. an owned proxy over the repo's mocks (admin = attacker)
        address attacker = makeAddr("attacker");
        address p1 = address(new TransparentUpgradeableProxy(address(new MockSP1Verifier()), attacker, abi.encodeWithSignature("VERSION()")));
        address p2 = address(new TransparentUpgradeableProxy(address(new MockRiscZeroVerifier()), attacker, abi.encodeWithSignature("VERSION()")));
        d.checkVerifiers(p1, p2);
        // codehash differs from the implementation, so a codehash pin would see it
        assertTrue(p1.codehash != address(new MockSP1Verifier()).codehash);
    }

    function test_V4_A702_reviewHelperIgnoresVerifierAndProgramKey() public {
        DeployStateVerifier script = new DeployStateVerifier();
        address lie = address(new LyingSP1());
        bytes32 attackerKey = keccak256("attacker program key");
        address vault = vm.parseJsonAddress(injective, ".vault");
        uint64 height = uint64(vm.parseJsonUint(injective, ".height"));
        bytes32 hash = vm.parseJsonBytes32(injective, ".hash");
        uint64 time = uint64(vm.parseJsonUint(injective, ".time"));
        CometBftStateVerifier v = new CometBftStateVerifier(
            ISP1Verifier(lie), attackerKey, script.INJECTIVE_MAINNET(), "injective-1", vault, height, hash, time
        );
        // the review passes: the real anchor is all it reads
        script.checkInjective(address(v), height, hash, time);
        assertEq(address(v.SP1_VERIFIER()), lie);
        assertEq(v.PROGRAM_KEY(), attackerKey);
    }
}
