// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {IEthereumEventVerifier} from "../src/interfaces/IEthereumEventVerifier.sol";
import {IHybridHubTypes} from "../src/interfaces/IHybridHubTypes.sol";
import {IHybridIndex} from "../src/interfaces/IHybridIndex.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {HybridTest} from "./HybridTest.sol";

/// @notice The snapshot exit against a real hub (design 6.9, layer 4): recovery addresses registered in the hub, the
///         vault paying holders at its last checkpoint from the hub's own storage, open intakes settled or refunded from
///         the hub's record of what it sent, and the hub recording the exit so nothing mints on the chain again.
contract HybridHubExitTest is HybridTest {
    IHybridIndex hub;
    address safe = makeAddr("a safe");
    address safeOnVaultChain = makeAddr("the safe's recovery address");
    address eoa;
    uint256 eoaKey;
    uint256 constant SNAPSHOT_BLOCK = 50;

    function setUp() public {
        _deployStageB();
        hub = _createHybrid();
        (eoa, eoaKey) = makeAddrAndKey("eoa holder");
    }

    /// @dev The vault's checkpoint at `blockNumber`, now: the last one before its verifiers stop working.
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

    /// @dev No checkpoint for 187 days: the stall, then the snapshot. Ethereum's blocks run on past it.
    function _snapshot() internal {
        vm.warp(vault.stallStart() + vault.SNAPSHOT_EXIT_DELAY());
        vault.beginSnapshot();
        vm.roll(SNAPSHOT_BLOCK + 100);
    }

    function _sign(uint256 key, address holder, address recipient) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Xindex vault"),
                keccak256("1"),
                block.chainid,
                address(vault)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SnapshotClaim(address index,address holder,address recipient)"),
                address(hub),
                holder,
                recipient
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function test_setRecoveryAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVaultChain.selector, 7));
        vm.prank(safe);
        hub.setRecoveryAddress(7, _b32(safeOnVaultChain));
        vm.expectEmit(address(hub));
        emit IHybridHubTypes.RecoveryAddressSet(safe, chainId, _b32(safeOnVaultChain));
        vm.prank(safe);
        hub.setRecoveryAddress(chainId, _b32(safeOnVaultChain));
        assertEq(hub.recoveryAddress(safe, chainId), _b32(safeOnVaultChain));
        vm.prank(safe);
        hub.setRecoveryAddress(chainId, bytes32(0));
        assertEq(hub.recoveryAddress(safe, chainId), bytes32(0));
    }

    /// @dev The hub marks an intake settled in the transaction that sends its settle message, and never otherwise.
    function test_intakeSettled_marksWhatWasSent() public {
        _mint(hub, minter, 1e18);
        assertTrue(hub.intakeSettled(hub.intakeIdOf(1)));
        uint256 orderId = _settledOrder(hub, minter, 0.01e18);
        assertFalse(hub.intakeSettled(hub.intakeIdOf(orderId)), "locked, not claimed");
    }

    /// @dev VLT-I6 and MOD-I1: after the exit, the vault's paid totals include the holders' claims and it resolves every intake
    ///      itself, so neither is evidence against it.
    function test_VLTI6_MODI1_noEvidenceAfterTheExit() public {
        uint256 claimed = _mint(hub, minter, 1e18);
        _checkpointAt(SNAPSHOT_BLOCK);
        _snapshot();
        hub.recordExit(chainId, _honest(block.timestamp));
        IHybridHubTypes.IndexRecord memory record;
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainExited.selector, chainId));
        hub.reportOutflow(chainId, record, _honest(block.timestamp));
        IHybridHubTypes.ChainProof memory p;
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainExited.selector, chainId));
        hub.reportForgedDeposit(claimed, chainId, p);
    }

    /// @dev The whole exit. At the last checkpoint an EOA and a safe hold shares, one order is claimed but its settle
    ///      message never reached the vault, and another is locked. 187 days later the vault pays each holder from the
    ///      hub's storage at the checkpoint, settles the claimed order's intake and refunds the locked one's; the hub
    ///      records the exit, fails the locked order, and nothing mints on the chain again.
    function test_theSnapshotExit() public {
        _mint(hub, minter, 1e18); // the creator's seed
        vm.prank(minter);
        hub.transfer(eoa, 1e18);
        vm.prank(eoa);
        hub.transfer(safe, 0.25e18);
        vm.prank(safe);
        hub.setRecoveryAddress(chainId, _b32(safeOnVaultChain));
        // Claimed, but its settle message is never delivered.
        uint256 claimed = _settledOrder(hub, minter, 0.01e18);
        vm.warp(block.timestamp + hub.MINT_LOCK());
        hub.claimOrder(claimed);
        // Locked when the verifiers stop.
        uint256 locked = _settledOrder(hub, minter, 0.02e18);
        _checkpointAt(SNAPSHOT_BLOCK);

        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAContradiction.selector, chainId));
        hub.recordExit(chainId, _honest(block.timestamp));
        _snapshot();

        // The holders at the checkpoint: 0.75 and 0.25 shares, at 1.4 BNB a share.
        vault.claimSnapshot(address(hub), eoa, eoa, 1, "", _sign(eoaKey, eoa, eoa));
        assertEq(eoa.balance, 1.05e18);
        vault.claimSnapshot(address(hub), safe, safeOnVaultChain, 1, "", "");
        assertEq(safeOnVaultChain.balance, 0.35e18);
        // The claimed order's intake joins the index, and its minter claims its shares' share like anyone.
        vault.resolveIntake(address(hub), hub.intakeIdOf(claimed), "");
        assertEq(uint256(vault.intakeState(address(hub), hub.intakeIdOf(claimed))), 2, "settled");
        (, uint256 minterKey) = makeAddrAndKey("minter");
        address minterTo = makeAddr("minter's recipient");
        vault.claimSnapshot(address(hub), minter, minterTo, 1, "", _sign(minterKey, minter, minterTo));
        assertEq(minterTo.balance, 0.014e18, "its 0.01 shares, backed by the intake just settled");
        // The locked order's deposit goes back to its depositor.
        uint256 lockedIntake = hub.intakeIdOf(locked);
        vault.resolveIntake(address(hub), lockedIntake, "");
        uint256 before = minter.balance;
        vm.prank(minter);
        vault.refund(address(hub), lockedIntake);
        assertEq(minter.balance - before, 0.028e18);

        // The hub learns of the exit through the vault's own state.
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainNotExited.selector, chainId));
        hub.failHeldOrder(locked, chainId);
        vm.expectEmit(address(hub));
        emit IHybridHubTypes.ChainExitRecorded(chainId, keccak256("the state at the snapshot"));
        hub.recordExit(chainId, _honest(block.timestamp));
        assertEq(hub.exitedAt(chainId), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainExited.selector, chainId));
        hub.recordExit(chainId, _honest(block.timestamp));
        (uint256 start, uint256 until) = hub.chainFreeze(chainId);
        assertEq(start, block.timestamp);
        assertEq(until, type(uint64).max, "frozen for good");
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainIsFrozen.selector, chainId, type(uint64).max));
        hub.claimOrder(locked);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainIsFrozen.selector, chainId, type(uint64).max));
        hub.openOrder(0.01e18, block.timestamp + 1 hours);

        // The locked order can never be claimed: anyone fails it, and its escrow is its minter's claim.
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongStatus.selector, claimed, IHybridHubTypes.OrderStatus.Claimed)
        );
        hub.failHeldOrder(claimed, chainId);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVaultChain.selector, 7));
        hub.failHeldOrder(locked, 7);
        vm.recordLogs();
        hub.failHeldOrder(locked, chainId);
        assertEq(hub.claimOf(minter, address(weth)), 0.024e18);
        // Its INTAKE_FAILED is from after the snapshot: the vault refuses it, having resolved the intake already.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory message = logs[logs.length - 1];
        assertEq(message.topics[0], VaultMessages.EVENT_TOPIC);
        assertEq(_message(logs).kind, VaultMessages.INTAKE_FAILED);
        bytes memory proof = abi.encode(message.emitter, message.topics[0], message.topics[1], message.data);
        p1.setEventBlock(block.number);
        p2.setEventBlock(block.number);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IssuedAfterSnapshot.selector, SNAPSHOT_BLOCK + 100));
        vault.deliver(proof, proof);
    }
}
