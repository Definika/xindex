// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VeChainStakerAttester} from "../src/vault/VeChainStakerAttester.sol";
import {MockVeChainStaker} from "./mocks/MockVeChainStaker.sol";

/// @notice The attester VeChain's state verifier counts on (`proofs/vechain`), against a stand-in Staker etched at the
///         builtin's address: its table is the hash chain the statement computes, here on mainnet's real table of 101
///         validators (`proofs/vechain/fixtures/mainnet.json`, read from the Staker's own views), and `attest` returns
///         only for it. The contract's own run on mainnet's Staker, simulated read-only, gave the same hash (see the
///         fixture generator).
contract VeChainStakerAttesterTest is Test {
    address constant STAKER = 0x00000000000000000000000000005374616B6572;
    string constant FIXTURE = "proofs/vechain/fixtures/mainnet.json";

    MockVeChainStaker staker;
    VeChainStakerAttester attester;

    function setUp() public {
        vm.etch(STAKER, address(new MockVeChainStaker()).code);
        staker = MockVeChainStaker(STAKER);
        attester = new VeChainStakerAttester();
    }

    /// @dev The fixture's table `which`: its validators, weights and total, and the hash the statement gave it.
    function _real(string memory which)
        internal
        view
        returns (address[] memory vals, uint256[] memory weights, uint256 total, bytes32 hash)
    {
        string memory json = vm.readFile(FIXTURE);
        string memory base = string.concat(".tables.", which);
        uint256 n = 0;
        while (vm.keyExistsJson(json, string.concat(base, ".validators[", vm.toString(n), "]"))) {
            ++n;
        }
        vals = new address[](n);
        weights = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory at = string.concat(base, ".validators[", vm.toString(i), "]");
            vals[i] = vm.parseJsonAddress(json, string.concat(at, "[0]"));
            weights[i] = uint256(vm.parseJsonBytes32(json, string.concat(at, "[1]")));
        }
        total = uint256(vm.parseJsonBytes32(json, string.concat(base, ".totalWeight")));
        hash = vm.parseJsonBytes32(json, string.concat(base, ".hash"));
    }

    function test_STAKER() public view {
        assertEq(address(attester.STAKER()), STAKER);
        assertEq(bytes20(STAKER), bytes20(bytes("\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00Staker")));
    }

    /// @dev Mainnet's tables of three rounds, 101 validators each: the attester hashes each as the statement did.
    function test_table_isTheStatementsHashChain_onMainnetsTables() public {
        string[3] memory which = ["trusted", "justified", "committed"];
        for (uint256 j = 0; j < 3; ++j) {
            (address[] memory vals, uint256[] memory weights, uint256 total, bytes32 hash) = _real(which[j]);
            assertEq(vals.length, 101);
            staker.set(vals, weights, total);
            assertEq(attester.currentTable(), hash, which[j]);
            attester.attest(hash);
        }
    }

    /// @dev The chain over the total, then each validator and weight, in list order.
    function test_table_hashChain() public {
        address[] memory vals = new address[](2);
        uint256[] memory weights = new uint256[](2);
        (vals[0], vals[1]) = (address(0xA11CE), address(0xB0B));
        (weights[0], weights[1]) = (100 ether, 50 ether);
        staker.set(vals, weights, 150 ether);
        bytes32 h = keccak256(abi.encode(uint256(150 ether)));
        h = keccak256(abi.encode(h, vals[0], weights[0]));
        h = keccak256(abi.encode(h, vals[1], weights[1]));
        assertEq(attester.currentTable(), h);

        // Another order is another table.
        (vals[0], vals[1]) = (vals[1], vals[0]);
        (weights[0], weights[1]) = (weights[1], weights[0]);
        staker.set(vals, weights, 150 ether);
        assertTrue(attester.currentTable() != h);

        // No active validator: the total alone.
        staker.set(new address[](0), new uint256[](0), 7);
        assertEq(attester.currentTable(), keccak256(abi.encode(uint256(7))));
    }

    /// @dev `attest` returns for the table and reverts, naming the actual one, for any other.
    function test_attest() public {
        address[] memory vals = new address[](1);
        uint256[] memory weights = new uint256[](1);
        vals[0] = address(0xA11CE);
        weights[0] = 3 ether;
        staker.set(vals, weights, 3 ether);
        bytes32 actual = attester.currentTable();
        attester.attest(actual);
        vm.expectRevert(abi.encodeWithSelector(VeChainStakerAttester.NotAttested.selector, actual));
        attester.attest(bytes32(uint256(actual) ^ 1));
        // The weight changed under it: the old table no longer attests.
        weights[0] = 4 ether;
        staker.set(vals, weights, 4 ether);
        vm.expectRevert(abi.encodeWithSelector(VeChainStakerAttester.NotAttested.selector, attester.currentTable()));
        attester.attest(actual);
    }

    /// @dev The stand-in's own answers.
    function test_mockStaker() public {
        address[] memory vals = new address[](2);
        uint256[] memory weights = new uint256[](2);
        (vals[0], vals[1]) = (address(1), address(2));
        (weights[0], weights[1]) = (5, 6);
        staker.set(vals, weights, 11);
        (uint256 vet, uint256 weight) = staker.totalStake();
        assertEq(vet, 5);
        assertEq(weight, 11);
        assertEq(staker.firstActive(), address(1));
        assertEq(staker.next(address(1)), address(2));
        assertEq(staker.next(address(2)), address(0));
        assertEq(staker.next(address(3)), address(0));
        (address endorser, uint256 stake, uint256 w, uint256 queued, uint8 status, uint32 offline) =
            staker.getValidation(address(2));
        assertEq(endorser, address(2));
        assertEq(stake, 25_000_000 ether);
        assertEq(w, 6);
        assertEq(queued, 0);
        assertEq(status, 2);
        assertEq(offline, type(uint32).max);
        staker.set(new address[](0), new uint256[](0), 0);
        assertEq(staker.firstActive(), address(0));
    }
}
