// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {VaultTestBase} from "./XindexVault.t.sol";
import {HybridTest} from "./HybridTest.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";

contract PocV1Vault is VaultTestBase {
    address index;

    function setUp() public {
        vm.warp(1_700_000_000);
        _deployVault();
        index = _registered(keccak256("index-1"));
    }

    /// A3-02 / A4-03: a newer cut taken on one proof leaves the mark; an older raise delivered afterwards on both proofs
    /// is queued and, 7 days on, replaces the cut.
    function test_V1_aNewerCutOnOneProofIsUndoneByAnOlderRaise() public {
        bytes32 capKey = bytes32(uint256(VaultMessages.CAP_UPDATE) << 160);
        bytes memory olderRaise = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP * 2, FLOOR * 10));
        bytes memory newerCut = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP / 2, FLOOR));
        vault.deliver(_proof(factory, newerCut), "");
        assertEq(vault.cap(address(0)), CAP / 2, "cut applied");
        assertEq(vault.governanceNonce(capKey), 0, "mark unmoved");
        uint256 readyAt = block.timestamp + vault.GOVERNANCE_DELAY();
        _deliver(factory, olderRaise); // both proofs: accepted
        vm.warp(readyAt);
        vault.applyChange(VaultMessages.CAP_UPDATE, abi.encode(bytes32(0), CAP * 2, FLOOR * 10), readyAt);
        assertEq(vault.cap(address(0)), CAP * 2, "older raise undid the newer cut");
        // the cut can no longer be delivered on both proofs to move the mark
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.AlreadyDelivered.selector, keccak256(newerCut)));
        _deliver(factory, newerCut);
    }

    /// A3-02 mitigations: freezer cancels the waiting raise (so it is LOW).
    function test_V1_freezerCanCancelTheQueuedRaise() public {
        bytes32 capKey = bytes32(uint256(VaultMessages.CAP_UPDATE) << 160);
        bytes memory olderRaise = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP * 2, FLOOR * 10));
        bytes memory newerCut = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP / 2, FLOOR));
        vault.deliver(_proof(factory, newerCut), "");
        _deliver(factory, olderRaise);
        assertTrue(vault.pendingChange(capKey) != bytes32(0));
        vm.prank(freezerKey);
        vault.cancelChange(capKey);
        assertEq(vault.pendingChange(capKey), bytes32(0));
    }

    /// A3-03: an old, never-delivered FREEZE, delivered 300 days later, freezes the vault for 14 days from delivery.
    function test_V1_aLateFreezeStillFreezes() public {
        bytes memory freezeMsg = _payload(VaultMessages.FREEZE, factory, "");
        vm.warp(block.timestamp + 300 days);
        _fresh();
        vault.deliver(_proof(factory, freezeMsg), "");
        assertEq(vault.frozenUntil(), block.timestamp + 14 days);
    }

    /// A3-01 (vault side): FREEZE messages renewed every 13 days on one proof; the vault never stalls, never pays.
    function test_V1_renewedFreezeKeepsTheVaultFrozenAndNeverStalled() public {
        _fund(index, 10 ether);
        bytes memory burn = _burnPayload(index, 1 ether, bob);
        bytes32 id = keccak256(burn);
        vault.deliver(_proof(index, burn), _proof(index, burn));
        vault.deliver(_proof(factory, _payload(VaultMessages.FREEZE, factory, "")), "");
        // note: burn was delivered before the freeze and paid at once; add a second burn after the freeze
        bytes memory burn2 = _burnPayload(index, 1 ether, bob);
        bytes32 id2 = keccak256(burn2);
        vault.deliver(_proof(index, burn2), _proof(index, burn2));
        assertEq(vault.owed(index, id2).remaining, 1 ether, "owed, unpaid");
        uint256 start = block.timestamp;
        for (uint256 i = 0; i < 30; ++i) {
            vm.warp(block.timestamp + 13 days);
            _fresh();
            assertFalse(vault.stalled());
            assertGt(vault.frozenUntil(), block.timestamp, "still frozen");
            vm.expectRevert();
            vault.release(index, id2);
            vault.deliver(_proof(factory, _payload(VaultMessages.FREEZE, factory, "")), "");
        }
        assertGt(block.timestamp - start, 360 days);
        assertEq(vault.owed(index, id2).remaining, 1 ether, "still owed after a year");
        id;
    }
}

contract PocV1Factory is HybridTest {
    function setUp() public {
        _deployStageB();
    }

    /// A3-01 (factory side): the owner can call freezeChain every 13 days with no limit, and each is deliverable.
    function test_V1_ownerRenewsFreezeChainWithoutLimit() public {
        for (uint256 i = 0; i < 30; ++i) {
            vm.recordLogs();
            vm.prank(owner);
            factory.freezeChain(chainId);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            vault.deliver(abi.encode(address(factory), VaultMessages.EVENT_TOPIC, logs[logs.length - 1].topics[1], logs[logs.length - 1].data), "");
            assertGt(vault.frozenUntil(), block.timestamp);
            assertGt(factory.chainFreeze(chainId).until, block.timestamp);
            vm.warp(block.timestamp + 13 days);
            _fresh();
            assertFalse(vault.stalled());
        }
        assertGt(vault.frozenUntil(), block.timestamp);
    }

    /// A3-01 fix A is incomplete: the owner replaces the guardian in 7 days, who then holds the same unlimited freeze.
    function test_V1_ownerBecomesGuardianInSevenDays() public {
        vm.prank(owner);
        factory.proposeGuardian(owner);
        vm.prank(guardian);
        vm.expectRevert();
        factory.cancelGuardianChange(); // the guardian cannot block its replacement
        vm.warp(block.timestamp + 7 days);
        factory.executeGuardianChange();
        assertEq(factory.guardian(), owner);
    }
}

contract PocV1Fixed is VaultTestBase {
    address index;

    function setUp() public {
        vm.warp(1_700_000_000);
        _deployVault();
        index = _registered(keccak256("index-1"));
    }

    function test_V1_fixed_aNewerCutOnOneProofIsNotUndoneByAnOlderRaise() public {
        bytes32 capKey = bytes32(uint256(VaultMessages.CAP_UPDATE) << 160);
        bytes memory olderRaise = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP * 2, FLOOR * 10));
        bytes memory newerCut = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP / 2, FLOOR));
        vault.deliver(_proof(factory, newerCut), "");
        _deliver(factory, olderRaise); // queued
        assertTrue(vault.pendingChange(capKey) != bytes32(0));
        _deliver(factory, newerCut); // both proofs: moves the mark and (via replay) re-applies the cut, dropping the raise
        assertEq(vault.pendingChange(capKey), bytes32(0), "older raise dropped");
        assertEq(vault.governanceNonce(capKey), nonce);
        assertEq(vault.cap(address(0)), CAP / 2);
        // the second stage: a newer cut C' on one proof, then older C replayed on both
        bytes memory c2 = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP / 4, FLOOR));
        vault.deliver(_proof(factory, c2), "");
        assertEq(vault.cap(address(0)), CAP / 4);
        // an older raise-equivalent: C (CAP/2) is now loosening relative to CAP/4; replay of an already-used both-proof message reverts
        vm.expectRevert();
        _deliver(factory, newerCut);
    }
}
