// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {DeployVault} from "../script/DeployVault.s.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";
import {MockRiscZeroVerifier} from "./mocks/MockRiscZeroVerifier.sol";

contract YesMan {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
    function verify(bytes calldata, bytes32, bytes32) external pure {}
}

contract ImpostorTest is Test {
    function test_proxyAdminOwnedVerifiersPassTheIdentityCheck() public {
        DeployVault d = new DeployVault();
        address attacker = makeAddr("attacker");
        // a proxy to a contract that answers the identity views: the proxy itself answers them identically
        TransparentUpgradeableProxy sp1 = new TransparentUpgradeableProxy(address(new MockSP1Verifier()), attacker, abi.encodeWithSignature("VERSION()"));
        TransparentUpgradeableProxy r0 = new TransparentUpgradeableProxy(address(new MockRiscZeroVerifier()), attacker, abi.encodeWithSignature("VERSION()"));
        d.checkVerifiers(address(sp1), address(r0)); // passes: "refuses any Groth16 verifier but the pinned ones"
    }
}
