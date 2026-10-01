// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BscVoteVerifier} from "../src/BscVoteVerifier.sol";

/// @notice M6: the recorded BNB Chain vote (20 of 21 validators, block 124,884,600) checked on the Prague EVM.
contract BscVoteVerifierTest is Test {
    BscVoteVerifier verifier;
    bytes[] voters;
    bytes signature;
    bytes32 voteHash;

    function setUp() public {
        verifier = new BscVoteVerifier();
        string memory json = vm.readFile("test/fixture.json");
        bytes[] memory keys = vm.parseJsonBytesArray(json, ".keys");
        uint256 bitset = vm.parseUint(vm.parseJsonString(json, ".bitset"));
        for (uint256 i = 0; i < keys.length; ++i) {
            if ((bitset >> i) & 1 == 1) voters.push(keys[i]);
        }
        signature = vm.parseJsonBytes(json, ".signature");
        voteHash = vm.parseJsonBytes32(json, ".voteHash");
    }

    function test_theRecordedVoteVerifies() public view {
        bytes[] memory keys = voters; // out of storage first, so the measurement is the verifier's alone
        bytes memory sig = signature;
        uint256 before = gasleft();
        bool ok = verifier.verifyVote(keys, sig, voteHash);
        uint256 used = before - gasleft();
        assertTrue(ok, "the vote verifies");
        console2.log("voters", voters.length, "gas to check the vote", used);
    }

    function test_aDifferentVoteDoesNotVerify() public view {
        assertFalse(verifier.verifyVote(voters, signature, bytes32(uint256(voteHash) ^ 1)));
    }

    function test_aMissingVoterDoesNotVerify() public {
        voters.pop();
        assertFalse(verifier.verifyVote(voters, signature, voteHash));
    }
}
