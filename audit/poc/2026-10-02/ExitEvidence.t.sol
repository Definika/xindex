// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEthereumEventVerifier} from "../../src/interfaces/IEthereumEventVerifier.sol";
import {IHybridHubTypes} from "../../src/interfaces/IHybridHubTypes.sol";
import {IHybridIndex} from "../../src/interfaces/IHybridIndex.sol";
import {IHybridIndexFactory} from "../../src/interfaces/IHybridIndexFactory.sol";
import {HybridTest} from "../HybridTest.sol";

/// @notice PoC: after a vault's snapshot exit, its honest `resolveIntake` of an order the hub never settled is taken as
///         a contradiction by `voidOrder` (which has no exit check, unlike reportOutflow/reportForgedDeposit), and,
///         before anyone calls `recordExit` on the index, by `reportForgedDeposit` too. Both freeze the chain at the
///         factory, for every index, on honest state.
contract ExitEvidencePoC is HybridTest {
    IHybridIndex hub;
    uint256 constant SNAPSHOT_BLOCK = 50;

    function setUp() public {
        _deployStageB();
        hub = _createHybrid();
    }

    function _checkpointAt(uint256 blockNumber) internal {
        vm.roll(blockNumber);
        bytes memory proof = abi.encode(
            IEthereumEventVerifier.Checkpoint({
                blockNumber: uint64(blockNumber),
                timestamp: uint64(block.timestamp),
                stateRoot: keccak256("the state at the snapshot")
            })
        );
        vault.advanceCheckpoint(proof, proof);
    }

    function _snapshot() internal {
        vm.warp(vault.stallStart() + vault.SNAPSHOT_EXIT_DELAY());
        vault.beginSnapshot();
        vm.roll(SNAPSHOT_BLOCK + 100);
    }

    /// @dev Exit recorded, then voidOrder still takes the vault's honest resolution as evidence and freezes the chain.
    function test_poc_voidOrderAfterTheExitFreezesTheChainOnHonestState() public {
        _mint(hub, minter, 1e18); // the creator's seed
        uint256 locked = _settledOrder(hub, minter, 0.02e18); // locked when the verifiers stop
        _checkpointAt(SNAPSHOT_BLOCK);
        _snapshot();

        // The vault, behaving honestly, fails the intake the hub never settled by the checkpoint.
        vault.resolveIntake(address(hub), hub.intakeIdOf(locked), "");
        assertEq(uint256(vault.intakeState(address(hub), hub.intakeIdOf(locked))), 3, "failed");

        hub.recordExit(chainId, _honest(block.timestamp));
        assertEq(hub.exitedAt(chainId), block.timestamp);

        IHybridIndexFactory.Freeze memory before = factory.chainFreeze(chainId);
        assertEq(before.start, 0, "no factory freeze yet");

        // Anyone: an honest proof of the failed intake, after the deadline, counts as a contradiction.
        vm.warp(block.timestamp + 1);
        hub.voidOrder(locked, chainId, _honest(block.timestamp));

        IHybridIndexFactory.Freeze memory afterVoid = factory.chainFreeze(chainId);
        assertEq(afterVoid.start, block.timestamp, "the factory froze the chain on evidence, for every index");
        assertEq(uint256(hub.order(locked).status), uint256(IHybridHubTypes.OrderStatus.Failed));
    }

    /// @dev Before anyone records the exit on this index, reportForgedDeposit's VLT-I6 check does not apply: a claimed
    ///      order whose claim came after the checkpoint is "disproved" by the vault's honest resolution.
    function test_poc_reportForgedDepositBeforeRecordExitFreezesTheChainOnHonestState() public {
        _mint(hub, minter, 1e18);
        _checkpointAt(SNAPSHOT_BLOCK);
        // Settled and claimed after the vault's last checkpoint: its settle message can never run there.
        vm.roll(SNAPSHOT_BLOCK + 1);
        uint256 claimed = _settledOrder(hub, minter, 0.01e18);
        vm.warp(block.timestamp + hub.MINT_LOCK());
        hub.claimOrder(claimed);
        assertTrue(hub.intakeSettled(hub.intakeIdOf(claimed)));
        _snapshot();

        // MockStateReader reads live storage, so stand in for "not marked at the checkpoint" by clearing the mark
        // the vault would not see in the snapshot's state (the claim came after it), then restoring it.
        bytes32 slot = keccak256(abi.encode(hub.intakeIdOf(claimed), uint256(60)));
        vm.store(address(hub), slot, bytes32(0));
        vault.resolveIntake(address(hub), hub.intakeIdOf(claimed), "");
        vm.store(address(hub), slot, bytes32(uint256(1)));
        assertEq(uint256(vault.intakeState(address(hub), hub.intakeIdOf(claimed))), 3, "failed at the vault");

        IHybridHubTypes.ChainProof memory p;
        p.proof = _honest(block.timestamp);
        p.tokens = new address[](1);
        p.totals = new uint256[](1);
        (uint256[] memory amounts,) = hub.orderAmounts(claimed);
        p.totals[0] = amounts[1];
        hub.reportForgedDeposit(claimed, chainId, p);
        assertEq(factory.chainFreeze(chainId).start, block.timestamp, "frozen on honest state");
    }
}
