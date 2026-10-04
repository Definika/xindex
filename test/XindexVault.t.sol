// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {XindexVault} from "../src/vault/XindexVault.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";
import {IEthereumEventVerifier} from "../src/interfaces/IEthereumEventVerifier.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {IStateReader} from "../src/interfaces/IStateReader.sol";
import {MockEventVerifier} from "./mocks/MockEventVerifier.sol";
import {MockStateReader} from "./mocks/MockStateReader.sol";

/// @notice Refuses every payment, as a contract recipient without a receive function does.
contract RefusingRecipient {}

/// @notice Shared set-up for the vault's suites: a vault on this test chain serving Ethereum's factory, two mock
///         verifiers, and helpers that build and deliver messages the way P1 and P2 would prove them.
abstract contract VaultTestBase is Test {
    XindexVault vault;
    MockEventVerifier v1;
    MockEventVerifier v2;
    address factory = makeAddr("ethereumFactory");
    address hubImplementation = makeAddr("hubImplementation");
    address freezerKey = makeAddr("freezer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant CAP = 1_000_000 ether;
    uint256 constant FLOOR = 1 ether;
    uint256 nonce;

    MockStateReader reader;
    address recoveryProposer = makeAddr("recovery proposer");

    function _deployVault() internal {
        v1 = new MockEventVerifier();
        v2 = new MockEventVerifier();
        reader = new MockStateReader();
        vault = new XindexVault(_config());
    }

    function _config() internal view returns (IXindexVault.Config memory) {
        return IXindexVault.Config({
            sourceChainId: 1,
            factory: factory,
            hubImplementation: hubImplementation,
            verifier1: v1,
            verifier2: v2,
            freezer: freezerKey,
            recoveryProposer: recoveryProposer,
            stateReader: reader,
            nativeCap: CAP,
            nativeFloor: FLOOR
        });
    }

    function _checkpointProof(uint256 blockNumber, uint256 time, bytes32 root) internal pure returns (bytes memory) {
        return abi.encode(
            IEthereumEventVerifier.Checkpoint({
                blockNumber: uint64(blockNumber), timestamp: uint64(time), stateRoot: root
            })
        );
    }

    /// @dev Keeps the vault out of a stall, as keepers do: a checkpoint at the current time that both verifiers prove.
    function _fresh() internal {
        IEthereumEventVerifier.Checkpoint memory c = vault.checkpoint();
        bytes memory proof = _checkpointProof(c.blockNumber + 1, block.timestamp, keccak256("state root"));
        vault.advanceCheckpoint(proof, proof);
    }

    function _index(bytes32 salt) internal view returns (address) {
        return Clones.predictDeterministicAddress(hubImplementation, salt, factory);
    }

    function _registered(bytes32 salt) internal returns (address index) {
        index = _index(salt);
        vault.registerIndex(index, salt);
    }

    function _intake(uint256 deadline, uint256 n) internal pure returns (uint256) {
        return (deadline << 192) | n;
    }

    function _payload(uint8 kind, address index, bytes memory body) internal returns (bytes memory) {
        return VaultMessages.encode(
            VaultMessages.Message({
                sourceChainId: 1,
                kind: kind,
                destChainId: block.chainid,
                vault: bytes32(uint256(uint160(address(vault)))),
                index: index,
                nonce: ++nonce,
                body: body
            })
        );
    }

    function _proof(address emitter, bytes memory payload) internal pure returns (bytes memory) {
        return abi.encode(emitter, VaultMessages.EVENT_TOPIC, keccak256(payload), abi.encode(payload));
    }

    /// @dev The proof of the last message `_deliver` delivered, which a successor must prove again.
    bytes lastDelivered;

    function _deliver(address emitter, bytes memory payload) internal {
        vault.deliver(_proof(emitter, payload), _proof(emitter, payload));
        lastDelivered = _proof(emitter, payload);
    }

    /// @dev Delivers the factory's governance message that loosens a rule, then applies it once its delay has passed.
    function _govern(uint8 kind, bytes memory body) internal {
        uint256 readyAt = block.timestamp + vault.GOVERNANCE_DELAY();
        _deliver(factory, _payload(kind, factory, body));
        vm.warp(readyAt);
        vault.applyChange(kind, body, readyAt);
    }

    function _deposit(address from, address index, uint256 intakeId, uint256 amount) internal {
        vm.deal(from, from.balance + amount);
        vm.prank(from);
        vault.deposit{value: amount}(index, intakeId);
    }

    /// @dev Deposits `amount` into a fresh intake of `index` and settles it, so the index holds it.
    function _fund(address index, uint256 amount) internal {
        uint256 intakeId = _intake(block.timestamp + 1 hours, ++nonce);
        _deposit(alice, index, intakeId, amount);
        _deliver(index, _payload(VaultMessages.INTAKE_SETTLED, index, abi.encode(intakeId)));
    }

    function _burnPayload(address index, uint256 amount, address to) internal returns (bytes memory) {
        return _payload(VaultMessages.BURN, index, abi.encode(bytes32(0), amount, bytes32(uint256(uint160(to)))));
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}

/// @notice The EVM vault: registration, deposits into intakes, messages proven by P1 and P2, burns within the speed
///         limit, intakes settled and failed, migration, caps, the freeze, and the state digests Ethereum proves.
contract XindexVaultTest is VaultTestBase {
    address index;

    function setUp() public {
        vm.warp(1_700_000_000);
        _deployVault();
        index = _registered(keccak256("index-1"));
    }

    // ---------------------------------------------------------------------
    // construction and registration
    // ---------------------------------------------------------------------

    function test_constructor() public {
        assertEq(vault.SOURCE_CHAIN_ID(), 1);
        assertEq(vault.FACTORY(), factory);
        assertEq(vault.HUB_IMPLEMENTATION(), hubImplementation);
        assertEq(address(vault.p1()), address(v1));
        assertEq(address(vault.p2()), address(v2));
        assertEq(vault.freezer(), freezerKey);
        assertEq(vault.cap(address(0)), CAP);
        assertEq(vault.outflowFloor(address(0)), FLOOR);
        assertEq(vault.SPEED_LIMIT(), 0.04e18);
        assertEq(vault.FREEZE_DURATION(), 14 days);
        assertEq(vault.MAX_INTAKE_LIFE(), 7 days);

        assertEq(vault.RECOVERY_PROPOSER(), recoveryProposer);
        assertEq(address(vault.STATE_READER()), address(reader));
        assertEq(vault.checkpoint().timestamp, block.timestamp, "a week's grace from deployment");

        IXindexVault.Config memory c = _config();
        c.factory = address(0);
        _refuse(c, abi.encodeWithSelector(IXindexVault.ZeroAddress.selector));
        c = _config();
        c.hubImplementation = address(0);
        _refuse(c, abi.encodeWithSelector(IXindexVault.ZeroAddress.selector));
        c = _config();
        c.verifier1 = IEthereumEventVerifier(address(0));
        _refuse(c, abi.encodeWithSelector(IXindexVault.ZeroAddress.selector));
        c = _config();
        c.verifier2 = IEthereumEventVerifier(address(0));
        _refuse(c, abi.encodeWithSelector(IXindexVault.ZeroAddress.selector));
        c = _config();
        c.freezer = address(0);
        _refuse(c, abi.encodeWithSelector(IXindexVault.ZeroAddress.selector));
        c = _config();
        c.recoveryProposer = address(0);
        _refuse(c, abi.encodeWithSelector(IXindexVault.ZeroAddress.selector));
        address noCode = makeAddr("no code");
        c = _config();
        c.verifier1 = IEthereumEventVerifier(noCode);
        _refuse(c, abi.encodeWithSelector(IXindexVault.NotAContract.selector, noCode));
        c = _config();
        c.verifier2 = IEthereumEventVerifier(noCode);
        _refuse(c, abi.encodeWithSelector(IXindexVault.NotAContract.selector, noCode));
        c = _config();
        c.verifier2 = v1;
        _refuse(c, abi.encodeWithSelector(IXindexVault.VerifiersNotDistinct.selector));
        c = _config();
        c.stateReader = IStateReader(noCode);
        _refuse(c, abi.encodeWithSelector(IXindexVault.NotAContract.selector, noCode));
    }

    function _refuse(IXindexVault.Config memory c, bytes memory reason) internal {
        vm.expectRevert(reason);
        new XindexVault(c);
    }

    /// @dev An index is legitimate when its address is the factory's clone of the hub template under some salt: anyone
    ///      can show it, and nothing else registers.
    function test_registerIndex_onlyTheFactorysClones() public {
        bytes32 salt = keccak256("index-2");
        address other = _index(salt);
        assertFalse(vault.isIndex(other));
        vm.expectEmit(address(vault));
        emit IXindexVault.IndexRegistered(other, salt);
        vault.registerIndex(other, salt);
        assertTrue(vault.isIndex(other));
        vault.registerIndex(other, salt); // again: a no-op
        assertTrue(vault.indexDigest(other) != bytes32(0), "a registered index has a digest");

        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, alice));
        vault.registerIndex(alice, salt);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, other));
        vault.registerIndex(other, keccak256("another salt"));
    }

    // ---------------------------------------------------------------------
    // deposits
    // ---------------------------------------------------------------------

    function test_deposit_opensAnIntakeAndHoldsTheCoins() public {
        uint256 intakeId = _intake(block.timestamp + 2 hours, 1);
        _deposit(alice, index, intakeId, 3 ether);
        _deposit(bob, index, intakeId, 2 ether);

        assertEq(uint256(vault.intakeState(index, intakeId)), uint256(IXindexVault.IntakeState.Open));
        assertEq(vault.intakeTotal(index, intakeId, address(0)), 5 ether);
        assertEq(vault.deposited(index, intakeId, address(0), alice), 3 ether);
        assertEq(vault.deposited(index, intakeId, address(0), bob), 2 ether);
        assertEq(vault.held(address(0)), 5 ether);
        assertEq(vault.balance(index, address(0)), 0, "an open intake is not the index's yet");
        assertEq(address(vault).balance, 5 ether);
        assertEq(vault.intakeTokens(index, intakeId).length, 1);
    }

    /// @dev `attest` succeeds exactly when every slot holds its value: on Tron, whose blocks commit to no contract
    ///      storage, a successful call of it is how Ethereum proves the vault's state. The slot is the one the hub
    ///      proves for an intake.
    function test_attest_succeedsOnlyOnTheStoredValues() public {
        uint256 intakeId = _intake(block.timestamp + 2 hours, 1);
        _deposit(alice, index, intakeId, 3 ether);
        bytes32[] memory slots = new bytes32[](2);
        bytes32[] memory values = new bytes32[](2);
        slots[0] = keccak256(abi.encode(intakeId, keccak256(abi.encode(index, uint256(15)))));
        values[0] = vault.intakeDigest(index, intakeId);
        assertTrue(values[0] != 0);
        (slots[1], values[1]) = (keccak256("a slot the vault never wrote"), bytes32(0));
        vault.attest(slots, values);

        values[0] ^= bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAttested.selector, slots[0]));
        vault.attest(slots, values);
        values[0] ^= bytes32(uint256(1));
        values[1] = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAttested.selector, slots[1]));
        vault.attest(slots, values);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAttested.selector, bytes32(0)));
        vault.attest(slots, new bytes32[](1));
    }

    function test_deposit_refusals() public {
        uint256 intakeId = _intake(block.timestamp + 1 hours, 1);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, bob));
        vault.deposit{value: 1 ether}(bob, intakeId);
        vm.expectRevert(IXindexVault.ZeroAmount.selector);
        vault.deposit(index, intakeId);
        uint256 far = _intake(block.timestamp + 7 days + 1, 2);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IntakeTooLong.selector, block.timestamp + 7 days + 1));
        vault.deposit{value: 1 ether}(index, far);
        vault.deposit{value: 1 ether}(index, _intake(block.timestamp + 7 days, 3)); // exactly the longest life
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IntakeClosed.selector, index, intakeId));
        vault.deposit{value: 1 ether}(index, intakeId);
    }

    function test_deposit_withinTheCap() public {
        uint256 intakeId = _intake(block.timestamp + 1 hours, 1);
        _deposit(alice, index, intakeId, CAP);
        vm.deal(bob, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.CapExceeded.selector, address(0), CAP + 1, CAP));
        vault.deposit{value: 1}(index, intakeId);
    }

    // ---------------------------------------------------------------------
    // delivery: proofs, routes, emitters, policy
    // ---------------------------------------------------------------------

    function test_deliver_needsAProofAndBothForMovingCoins() public {
        bytes memory payload = _burnPayload(index, 1 ether, bob);
        vm.expectRevert(IXindexVault.NoProof.selector);
        vault.deliver("", "");
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.BothProofsRequired.selector, VaultMessages.BURN));
        vault.deliver(_proof(index, payload), "");
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.BothProofsRequired.selector, VaultMessages.BURN));
        vault.deliver("", _proof(index, payload));
    }

    function test_deliver_theTwoProofsMustAgree() public {
        bytes memory payload = _burnPayload(index, 1 ether, bob);
        bytes memory other = _burnPayload(index, 2 ether, bob);
        vm.expectRevert(IXindexVault.ProofsDisagree.selector);
        vault.deliver(_proof(index, payload), _proof(index, other));
        vm.expectRevert(IXindexVault.ProofsDisagree.selector);
        vault.deliver(_proof(index, payload), _proof(alice, payload));
    }

    function test_deliver_aRefusingVerifierStopsIt() public {
        bytes memory payload = _burnPayload(index, 1 ether, bob);
        v2.setRefuse(true);
        vm.expectRevert(MockEventVerifier.Refused.selector);
        _deliver(index, payload);
    }

    function test_deliver_onlyVaultMessages() public {
        assertEq(VaultMessages.EVENT_TOPIC, keccak256("VaultMessage(bytes32,bytes)"));
        bytes memory payload = _burnPayload(index, 1 ether, bob);
        bytes memory wrongTopic =
            abi.encode(index, keccak256("Other(bytes32,bytes)"), keccak256(payload), abi.encode(payload));
        vm.expectRevert(
            abi.encodeWithSelector(IXindexVault.NotAVaultMessage.selector, keccak256("Other(bytes32,bytes)"))
        );
        vault.deliver(wrongTopic, wrongTopic);
        bytes memory wrongId = abi.encode(index, VaultMessages.EVENT_TOPIC, bytes32(uint256(1)), abi.encode(payload));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IdMismatch.selector, bytes32(uint256(1))));
        vault.deliver(wrongId, wrongId);

        bytes memory foreign = abi.encode(keccak256("other domain"), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(VaultMessages.WrongDomain.selector, keccak256("other domain")));
        _deliver(
            index, abi.encode(keccak256("other domain"), 1, uint8(1), block.chainid, bytes32(0), index, 1, foreign)
        );
    }

    /// @dev A message names its source chain, destination chain and vault; a proof of it cannot be used anywhere else.
    function test_deliver_theRouteMustBeThisVaults() public {
        bytes memory body = abi.encode(bytes32(0), 1 ether, _b32(bob));
        bytes32 here = _b32(address(vault));
        VaultMessages.Message memory m =
            VaultMessages.Message(1, VaultMessages.BURN, block.chainid, here, index, 1, body);
        m.sourceChainId = 11155111;
        vm.expectRevert(IXindexVault.WrongRoute.selector);
        _deliver(index, VaultMessages.encode(m));
        m.sourceChainId = 1;
        m.destChainId = 56;
        vm.expectRevert(IXindexVault.WrongRoute.selector);
        _deliver(index, VaultMessages.encode(m));
        m.destChainId = block.chainid;
        m.vault = _b32(alice);
        vm.expectRevert(IXindexVault.WrongRoute.selector);
        _deliver(index, VaultMessages.encode(m));
    }

    /// @dev An index message must come from that index; governance must come from the factory, naming the factory.
    function test_deliver_theEmitterMustBeTheSender() public {
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.WrongEmitter.selector, alice));
        _deliver(alice, _burnPayload(index, 1 ether, bob));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.WrongEmitter.selector, index));
        _deliver(index, _payload(VaultMessages.FREEZE, factory, ""));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.WrongEmitter.selector, factory));
        _deliver(factory, _payload(VaultMessages.FREEZE, index, ""));
    }

    /// @dev A kind the vault does not know is refused before dispatch, which would otherwise treat it as the last one.
    function test_deliver_unknownKindsAreRefused() public {
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.UnknownKind.selector, 0));
        _deliver(index, _payload(0, index, ""));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.UnknownKind.selector, 9));
        _deliver(factory, _payload(9, factory, abi.encode(_b32(address(v1)), _b32(address(v2)))));
        assertEq(address(vault.p1()), address(v1), "nothing rotated");
    }

    /// @dev Any Ethereum contract can emit a VaultMessage naming itself as the index; only a registered index's own
    ///      messages run, so a contract that is not the factory's clone of the hub cannot even settle an intake.
    function test_deliver_onlyRegisteredIndexesSendIndexMessages() public {
        address impostor = makeAddr("impostor");
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, impostor));
        _deliver(impostor, _burnPayload(impostor, 1 ether, bob));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, impostor));
        _deliver(impostor, _payload(VaultMessages.INTAKE_SETTLED, impostor, abi.encode(uint256(1))));
        address unregistered = _index(keccak256("index-2"));
        bytes memory payload = _payload(VaultMessages.INTAKE_FAILED, unregistered, abi.encode(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, unregistered));
        _deliver(unregistered, payload);
        vault.registerIndex(unregistered, keccak256("index-2"));
        _deliver(unregistered, payload); // anyone registers it first, then the same proof runs
        assertTrue(vault.used(keccak256(payload)));
    }

    function test_deliver_aMessageRunsOnce() public {
        _fund(index, 100 ether);
        bytes memory payload = _burnPayload(index, 1 ether, bob);
        _deliver(index, payload);
        assertTrue(vault.used(keccak256(payload)));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.AlreadyDelivered.selector, keccak256(payload)));
        _deliver(index, payload);
        assertEq(bob.balance, 1 ether);
    }

    // ---------------------------------------------------------------------
    // burns and the speed limit
    // ---------------------------------------------------------------------

    function test_burn_paysWithinTheLimit() public {
        _fund(index, 100 ether);
        bytes memory payload = _burnPayload(index, 4 ether, bob);
        bytes32 id = keccak256(payload);
        vm.expectEmit(address(vault));
        emit IXindexVault.Paid(index, id, bob, 4 ether, 0);
        _deliver(index, payload);
        assertEq(bob.balance, 4 ether);
        assertEq(vault.balance(index, address(0)), 96 ether);
        assertEq(vault.paidTotal(index, address(0)), 4 ether);
        assertEq(vault.held(address(0)), 96 ether);
        assertEq(vault.owed(index, id).remaining, 0);
        assertEq(vault.available(index, address(0)), 0, "4% of the balance before it, all used");
    }

    /// @dev A burn above the limit is paid what the limit allows and owes the rest; it never fails and never expires.
    function test_burn_aboveTheLimitWaitsAndIsReleasedLater() public {
        _fund(index, 100 ether);
        bytes memory payload = _burnPayload(index, 10 ether, bob);
        bytes32 id = keccak256(payload);
        _deliver(index, payload);
        assertEq(bob.balance, 4 ether, "4% of 100 now");
        assertEq(vault.owed(index, id).remaining, 6 ether);

        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NothingPayable.selector, index, id));
        vault.release(index, id);

        vm.warp(block.timestamp + 25 hours);
        vault.release(index, id);
        assertEq(bob.balance, 4 ether + 3.84 ether, "4% of the 96 left");
        vm.warp(block.timestamp + 25 hours);
        vault.release(index, id);
        assertEq(bob.balance, 10 ether, "the last 2.16, within the 3.6864 now allowed");
        assertEq(vault.owed(index, id).remaining, 0);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NothingOwed.selector, index, id));
        vault.release(index, id);
    }

    /// @dev The limit counts the current hour and the 24 before it, so no two payouts less than 24 hours apart can
    ///      together exceed it: the case 24 hourly buckets would miss.
    function test_speedLimit_isExactOverAny24Hours() public {
        _fund(index, 100 ether);
        uint256 hourEnd = (block.timestamp / 1 hours + 1) * 1 hours - 1;
        vm.warp(hourEnd); // the last second of an hour
        _deliver(index, _burnPayload(index, 4 ether, bob));
        vm.warp(hourEnd + 23 hours + 1); // the first second of the hour 24 buckets later
        assertEq(vault.available(index, address(0)), 0, "still inside the same 24 hours");
        vm.warp(hourEnd + 24 hours + 1);
        assertGt(vault.available(index, address(0)), 0, "a full day later, the limit is free again");
    }

    /// @dev The floor lets the last small balance leave: 4% of a shrinking balance alone would never reach zero.
    function test_speedLimit_theFloorLetsTheLastCoinsOut() public {
        _fund(index, 0.5 ether);
        bytes memory payload = _burnPayload(index, 0.5 ether, bob);
        _deliver(index, payload);
        assertEq(bob.balance, 0.5 ether, "below the 1-coin floor, paid in full at once");
        assertEq(vault.balance(index, address(0)), 0);
    }

    /// @dev `recentOutflow` is what the limit has used: this hour's payout, until 25 hours have passed.
    function test_speedLimit_recentOutflow() public {
        _fund(index, 100 ether);
        _deliver(index, _burnPayload(index, 3 ether, bob));
        assertEq(vault.recentOutflow(index, address(0)), 3 ether);
        assertEq(vault.available(index, address(0)), 1 ether, "4% of the 100 before the payout, less the 3 paid");
        vm.warp(block.timestamp + 25 hours);
        assertEq(vault.recentOutflow(index, address(0)), 0);
    }

    /// @dev An intake takes deposits up to and including the second its id names as its deadline.
    function test_intake_theDeadlineIsTheTop64Bits() public {
        uint256 deadline = block.timestamp + 3 hours;
        uint256 intakeId = _intake(deadline, 42);
        _deposit(alice, index, intakeId, 1 ether);
        vm.warp(deadline);
        _deposit(alice, index, intakeId, 1 ether); // the deadline's own second still takes deposits
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IntakeClosed.selector, index, intakeId));
        _deposit(alice, index, intakeId, 1 ether);
    }

    /// @dev A burn never pays more than its index holds; the rest waits for the index to be funded.
    function test_burn_neverMoreThanTheBalance() public {
        _fund(index, 0.4 ether);
        bytes memory payload = _burnPayload(index, 0.9 ether, bob);
        bytes32 id = keccak256(payload);
        _deliver(index, payload);
        assertEq(bob.balance, 0.4 ether);
        assertEq(vault.owed(index, id).remaining, 0.5 ether);
        address other = _registered(keccak256("index-2"));
        _fund(other, 10 ether);
        assertEq(vault.balance(index, address(0)), 0, "another index's coins are not this one's");
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NothingPayable.selector, index, id));
        vault.release(index, id);
        _fund(index, 1 ether);
        vm.warp(block.timestamp + 25 hours);
        vault.release(index, id);
        assertEq(bob.balance, 0.9 ether);
    }

    /// @dev A bucket's hour and amount are range-checked before they are packed, so a wrapped bucket can never
    ///      understate the outflow: past 2^64 hours the vault refuses to pay rather than forget what it paid.
    function test_speedLimit_bucketsNeverWrap() public {
        _fund(index, 10 ether);
        vm.warp(uint256(type(uint64).max) * 1 hours + 1 hours);
        vm.expectRevert(IXindexVault.OutflowOverflow.selector);
        _deliver(index, _burnPayload(index, 0.1 ether, bob));
    }

    function test_burn_refusals() public {
        _fund(index, 10 ether);
        vm.expectRevert(IXindexVault.ZeroAmount.selector);
        _deliver(index, _burnPayload(index, 0, bob));
        vm.expectRevert(IXindexVault.ZeroAddress.selector);
        _deliver(index, _burnPayload(index, 1 ether, address(0)));
        bytes32 wide = bytes32(uint256(1) << 160);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnAddress.selector, wide));
        _deliver(index, _payload(VaultMessages.BURN, index, abi.encode(wide, 1 ether, _b32(bob))));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NothingOwed.selector, index, bytes32(uint256(7))));
        vault.release(index, bytes32(uint256(7)));
    }

    /// @dev A recipient that refuses the coin stops only its own burn, which stays deliverable.
    function test_burn_aRefusingRecipientKeepsItsBurnDeliverable() public {
        _fund(index, 10 ether);
        address refusing = address(new RefusingRecipient());
        bytes memory payload = _burnPayload(index, 0.1 ether, refusing);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.PaymentFailed.selector, refusing));
        _deliver(index, payload);
        assertFalse(vault.used(keccak256(payload)));
    }

    // ---------------------------------------------------------------------
    // intakes
    // ---------------------------------------------------------------------

    function test_intake_settledJoinsTheIndex() public {
        uint256 intakeId = _intake(block.timestamp + 1 hours, 1);
        _deposit(alice, index, intakeId, 7 ether);
        bytes32 openDigest = vault.intakeDigest(index, intakeId);
        vm.expectEmit(address(vault));
        emit IXindexVault.IntakeSettled(index, intakeId);
        _deliver(index, _payload(VaultMessages.INTAKE_SETTLED, index, abi.encode(intakeId)));
        assertEq(vault.balance(index, address(0)), 7 ether);
        assertEq(vault.held(address(0)), 7 ether, "settling moves nothing out");
        assertTrue(vault.intakeDigest(index, intakeId) != openDigest);
        assertEq(vault.indexTokens(index).length, 1);

        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IntakeClosed.selector, index, intakeId));
        _deposit(bob, index, intakeId, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IntakeNotOpen.selector, index, intakeId));
        _deliver(index, _payload(VaultMessages.INTAKE_SETTLED, index, abi.encode(intakeId)));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IntakeNotOpen.selector, index, intakeId));
        _deliver(index, _payload(VaultMessages.INTAKE_FAILED, index, abi.encode(intakeId)));
    }

    function test_intake_failedRefundsEachDepositor() public {
        uint256 intakeId = _intake(block.timestamp + 1 hours, 1);
        _deposit(alice, index, intakeId, 3 ether);
        _deposit(bob, index, intakeId, 2 ether);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IntakeNotOpen.selector, index, intakeId));
        vm.prank(alice);
        vault.refund(index, intakeId);

        _deliver(index, _payload(VaultMessages.INTAKE_FAILED, index, abi.encode(intakeId)));
        vm.prank(alice);
        vault.refund(index, intakeId);
        assertEq(alice.balance, 3 ether);
        vm.prank(alice);
        vm.expectRevert(IXindexVault.NothingToRefund.selector);
        vault.refund(index, intakeId);
        vm.prank(bob);
        vault.refund(index, intakeId);
        assertEq(bob.balance, 2 ether);
        assertEq(vault.held(address(0)), 0);
        assertEq(vault.balance(index, address(0)), 0, "a failed intake never joined the index");
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IntakeNotOpen.selector, index, intakeId));
        _deliver(index, _payload(VaultMessages.INTAKE_SETTLED, index, abi.encode(intakeId)));
    }

    /// @dev An intake the hub closes before anyone deposited is closed for good.
    function test_intake_closedBeforeAnyDeposit() public {
        uint256 settled = _intake(block.timestamp + 1 hours, 1);
        uint256 failed = _intake(block.timestamp + 1 hours, 2);
        _deliver(index, _payload(VaultMessages.INTAKE_SETTLED, index, abi.encode(settled)));
        _deliver(index, _payload(VaultMessages.INTAKE_FAILED, index, abi.encode(failed)));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IntakeClosed.selector, index, settled));
        _deposit(alice, index, settled, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IntakeClosed.selector, index, failed));
        _deposit(alice, index, failed, 1 ether);
    }

    // ---------------------------------------------------------------------
    // migration, caps, freeze, governance
    // ---------------------------------------------------------------------

    /// @dev A migration leaves the old index's balance as a burn does: within the speed limit, into the new index's
    ///      balance, without leaving the vault. What the limit does not allow yet stays owed and is released later.
    function test_migrate_movesCoinsWithinTheSpeedLimit() public {
        _fund(index, 100 ether);
        address next = _registered(keccak256("index-2"));
        bytes memory payload = _payload(VaultMessages.MIGRATE, index, abi.encode(next, bytes32(0), 3 ether));
        vm.expectEmit(address(vault));
        emit IXindexVault.MigrationAccepted(index, keccak256(payload), address(0), 3 ether, next);
        _deliver(index, payload);
        assertEq(vault.balance(index, address(0)), 97 ether);
        assertEq(vault.balance(next, address(0)), 3 ether);
        assertEq(vault.paidTotal(index, address(0)), 3 ether, "a migration counts as paid out of the old index");
        assertEq(vault.held(address(0)), 100 ether, "nothing left the vault");
        assertEq(vault.indexTokens(next).length, 1);

        // 4% of the 100 before any outflow is 4, of which 3 are used: 1 moves now and 9 wait.
        payload = _payload(VaultMessages.MIGRATE, index, abi.encode(next, bytes32(0), 10 ether));
        bytes32 id = keccak256(payload);
        _deliver(index, payload);
        assertEq(vault.balance(next, address(0)), 4 ether);
        IXindexVault.Owed memory o = vault.owed(index, id);
        assertTrue(o.toIndex);
        assertEq(o.recipient, next);
        assertEq(o.remaining, 9 ether);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NothingPayable.selector, index, id));
        vault.release(index, id);
        vm.warp(block.timestamp + 25 hours);
        vault.release(index, id);
        assertEq(vault.balance(next, address(0)), 4 ether + 3.84 ether, "4% of the 96 left");
        assertEq(vault.owed(index, id).remaining, 9 ether - 3.84 ether);
        assertEq(vault.paidTotal(index, address(0)), 7.84 ether);
        assertEq(vault.held(address(0)), 100 ether);

        address unregistered = _index(keccak256("index-3"));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, unregistered));
        _deliver(index, _payload(VaultMessages.MIGRATE, index, abi.encode(unregistered, bytes32(0), 1 ether)));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, index));
        _deliver(index, _payload(VaultMessages.MIGRATE, index, abi.encode(index, bytes32(0), 1 ether)));
        vm.expectRevert(IXindexVault.ZeroAmount.selector);
        _deliver(index, _payload(VaultMessages.MIGRATE, index, abi.encode(next, bytes32(0), 0)));
    }

    /// @dev A migration never moves more than the old index's balance: the rest stays owed, as a burn's would.
    function test_migrate_neverMoreThanTheBalance() public {
        _govern(VaultMessages.CAP_UPDATE, abi.encode(bytes32(0), CAP, 100 ether));
        _fund(index, 10 ether);
        address next = _registered(keccak256("index-2"));
        bytes memory payload = _payload(VaultMessages.MIGRATE, index, abi.encode(next, bytes32(0), 30 ether));
        _deliver(index, payload);
        assertEq(vault.balance(index, address(0)), 0);
        assertEq(vault.balance(next, address(0)), 10 ether, "the floor lets it all out, but no more than there is");
        assertEq(vault.owed(index, keccak256(payload)).remaining, 20 ether);
    }

    function test_capUpdate_raisingNeedsBothProofs() public {
        bytes memory lower = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP / 2, FLOOR / 2));
        vm.expectEmit(address(vault));
        emit IXindexVault.CapSet(address(0), CAP / 2, FLOOR / 2);
        vault.deliver(_proof(factory, lower), "");
        assertEq(vault.cap(address(0)), CAP / 2);

        bytes memory raiseCap = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP, FLOOR / 2));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.BothProofsRequired.selector, VaultMessages.CAP_UPDATE));
        vault.deliver(_proof(factory, raiseCap), "");
        bytes memory raiseFloor = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP / 2, FLOOR));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.BothProofsRequired.selector, VaultMessages.CAP_UPDATE));
        vault.deliver("", _proof(factory, raiseFloor));
        _deliver(factory, raiseCap);
        assertEq(vault.cap(address(0)), CAP / 2, "a raise waits");
        vm.warp(block.timestamp + vault.GOVERNANCE_DELAY());
        vault.applyChange(VaultMessages.CAP_UPDATE, abi.encode(bytes32(0), CAP, FLOOR / 2), block.timestamp);
        assertEq(vault.cap(address(0)), CAP);
    }

    /// @dev A freeze stops deposits, payouts, refunds and migration; accepted burns and migrations wait; it ends by
    ///      itself.
    function test_freeze_stopsCoinsMovingAndExpires() public {
        _fund(index, 100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotFreezer.selector, alice));
        vault.freeze();
        vm.prank(freezerKey);
        vault.freeze();
        uint256 until = vault.frozenUntil();
        assertEq(until, block.timestamp + 14 days);

        bytes memory payload = _burnPayload(index, 1 ether, bob);
        bytes32 id = keccak256(payload);
        _deliver(index, payload);
        assertEq(bob.balance, 0, "accepted, not paid");
        assertEq(vault.owed(index, id).remaining, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NothingPayable.selector, index, id));
        vault.release(index, id);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.VaultFrozen.selector, until));
        _deposit(alice, index, _intake(block.timestamp + 1 hours, 9), 1 ether);
        address next = _registered(keccak256("index-2"));
        bytes memory migration = _payload(VaultMessages.MIGRATE, index, abi.encode(next, bytes32(0), 1 ether));
        _deliver(index, migration);
        assertEq(vault.balance(next, address(0)), 0, "accepted, not moved");

        vm.warp(block.timestamp + 1 days);
        vm.prank(freezerKey);
        vault.freeze(); // a new act extends it
        assertEq(vault.frozenUntil(), block.timestamp + 14 days);
        _deliver(factory, _payload(VaultMessages.FREEZE, factory, "")); // a proven freeze never shortens it
        assertEq(vault.frozenUntil(), block.timestamp + 14 days);

        vm.warp(vault.frozenUntil());
        vault.release(index, id);
        assertEq(bob.balance, 1 ether, "paid once the freeze ended");
        vault.release(index, keccak256(migration));
        assertEq(vault.balance(next, address(0)), 1 ether, "moved once the freeze ended");
    }

    function test_freeze_refundsWaitToo() public {
        uint256 intakeId = _intake(block.timestamp + 1 hours, 1);
        _deposit(alice, index, intakeId, 1 ether);
        _deliver(index, _payload(VaultMessages.INTAKE_FAILED, index, abi.encode(intakeId)));
        vault.deliver(_proof(factory, _payload(VaultMessages.FREEZE, factory, "")), ""); // one proof suffices
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.VaultFrozen.selector, vault.frozenUntil()));
        vault.refund(index, intakeId);
    }

    function test_governance_freezerAndVerifiers() public {
        address newFreezer = makeAddr("new freezer");
        _govern(VaultMessages.FREEZER_CHANGE, abi.encode(_b32(newFreezer)));
        assertEq(vault.freezer(), newFreezer);
        _deliver(factory, _payload(VaultMessages.FREEZER_CHANGE, factory, abi.encode(bytes32(0))));
        vm.warp(block.timestamp + vault.GOVERNANCE_DELAY());
        vm.expectRevert(IXindexVault.ZeroAddress.selector);
        vault.applyChange(VaultMessages.FREEZER_CHANGE, abi.encode(bytes32(0)), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.BothProofsRequired.selector, VaultMessages.FREEZER_CHANGE));
        vault.deliver(_proof(factory, _payload(VaultMessages.FREEZER_CHANGE, factory, abi.encode(_b32(alice)))), "");

        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        _govern(VaultMessages.VERIFIER_ROTATION, abi.encode(_b32(address(n1)), _b32(address(n2))));
        assertEq(address(vault.p1()), address(n1));
        assertEq(address(vault.p2()), address(n2));
        _checkRotationRefused(
            abi.encode(_b32(alice), _b32(address(n2))),
            abi.encodeWithSelector(IXindexVault.NotAContract.selector, alice)
        );
        _checkRotationRefused(
            abi.encode(_b32(address(n1)), _b32(alice)),
            abi.encodeWithSelector(IXindexVault.NotAContract.selector, alice)
        );
        // One verifier twice would turn "P1 and P2" into a single proof.
        _checkRotationRefused(
            abi.encode(_b32(address(n2)), _b32(address(n2))),
            abi.encodeWithSelector(IXindexVault.VerifiersNotDistinct.selector)
        );
    }

    function _checkRotationRefused(bytes memory body, bytes memory err) internal {
        uint256 readyAt = block.timestamp + vault.GOVERNANCE_DELAY();
        _deliver(factory, _payload(VaultMessages.VERIFIER_ROTATION, factory, body));
        vm.warp(readyAt);
        vm.expectRevert(err);
        vault.applyChange(VaultMessages.VERIFIER_ROTATION, body, readyAt);
    }

    /// @dev VLT-2: a raised floor, a new freezer and new verifiers wait a week on the vault, however their proofs were
    ///      obtained. The freezer may drop a raise or a rotation, never its own replacement; a freeze holds every change
    ///      but that one.
    function test_VLT2_aLooseningWaitsAndTheFreezerCanStopIt() public {
        _fund(index, 100 ether);
        bytes memory raise = abi.encode(bytes32(0), CAP, 100 ether);
        bytes32 capKey = bytes32(uint256(VaultMessages.CAP_UPDATE) << 160);
        uint256 readyAt = block.timestamp + 7 days;
        vm.expectEmit(address(vault));
        emit IXindexVault.ChangeQueued(capKey, VaultMessages.CAP_UPDATE, raise, readyAt);
        _deliver(factory, _payload(VaultMessages.CAP_UPDATE, factory, raise));
        assertEq(vault.outflowFloor(address(0)), FLOOR, "the floor has not moved");
        assertEq(vault.pendingChange(capKey), keccak256(abi.encode(raise, readyAt)));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.ChangeNotReady.selector, capKey, readyAt));
        vault.applyChange(VaultMessages.CAP_UPDATE, raise, readyAt);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NoPendingChange.selector, capKey));
        vault.applyChange(VaultMessages.CAP_UPDATE, raise, readyAt + 1);
        // A burn in the meantime still sees the old floor.
        _deliver(index, _burnPayload(index, 50 ether, bob));
        assertEq(bob.balance, 4 ether, "4% of 100, not the raised floor");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotFreezer.selector, alice));
        vault.cancelChange(capKey);
        vm.expectEmit(address(vault));
        emit IXindexVault.ChangeCancelled(capKey);
        vm.prank(freezerKey);
        vault.cancelChange(capKey);
        vm.warp(readyAt);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NoPendingChange.selector, capKey));
        vault.applyChange(VaultMessages.CAP_UPDATE, raise, readyAt);
        vm.prank(freezerKey);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NoPendingChange.selector, capKey));
        vault.cancelChange(capKey);

        // Sent again, it waits again, and a freeze holds it.
        readyAt = block.timestamp + 7 days;
        _deliver(factory, _payload(VaultMessages.CAP_UPDATE, factory, raise));
        bytes32 freezerKeyId = bytes32(uint256(VaultMessages.FREEZER_CHANGE) << 160);
        address next = makeAddr("next freezer");
        _deliver(factory, _payload(VaultMessages.FREEZER_CHANGE, factory, abi.encode(_b32(next))));
        vm.prank(freezerKey);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotFreezer.selector, freezerKey));
        vault.cancelChange(freezerKeyId);
        vm.warp(readyAt - 1 days);
        vm.prank(freezerKey);
        vault.freeze();
        vm.warp(readyAt);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.VaultFrozen.selector, vault.frozenUntil()));
        vault.applyChange(VaultMessages.CAP_UPDATE, raise, readyAt);
        // The freezer's replacement is not held: a freezer freezing again and again cannot keep itself in place.
        vm.expectEmit(address(vault));
        emit IXindexVault.ChangeApplied(freezerKeyId);
        vault.applyChange(VaultMessages.FREEZER_CHANGE, abi.encode(_b32(next)), readyAt);
        assertEq(vault.freezer(), next);
        vm.warp(vault.frozenUntil());
        vault.applyChange(VaultMessages.CAP_UPDATE, raise, readyAt);
        assertEq(vault.outflowFloor(address(0)), 100 ether);
        assertEq(vault.pendingChange(capKey), bytes32(0));

        // A newer lowering drops a raise still waiting under its key.
        bytes memory raiseAgain = abi.encode(bytes32(0), CAP, 200 ether);
        readyAt = block.timestamp + 7 days;
        _deliver(factory, _payload(VaultMessages.CAP_UPDATE, factory, raiseAgain));
        _deliver(factory, _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP / 2, 50 ether)));
        assertEq(vault.pendingChange(capKey), bytes32(0));
        vm.warp(readyAt);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NoPendingChange.selector, capKey));
        vault.applyChange(VaultMessages.CAP_UPDATE, raiseAgain, readyAt);
        assertEq(vault.outflowFloor(address(0)), 50 ether);
    }

    /// @dev VLT-4: a governance message older than the last of its kind never runs, so a late delivery cannot undo a
    ///      newer change. Only a message on both proofs moves the mark: one proof, even a forged one, cannot lock the
    ///      factory out with a huge nonce, and can only tighten.
    function test_VLT4_anOlderGovernanceMessageCannotUndoANewerOne() public {
        bytes memory older = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP / 4, FLOOR));
        bytes memory otherToken = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(_b32(alice), 0, 0));
        bytes memory newer = _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP / 2, FLOOR));
        bytes32 capKey = bytes32(uint256(VaultMessages.CAP_UPDATE) << 160);
        _deliver(factory, newer);
        assertEq(vault.governanceNonce(capKey), nonce);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.StaleGovernance.selector, nonce - 2, nonce));
        _deliver(factory, older);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.StaleGovernance.selector, nonce - 2, nonce));
        vault.deliver(_proof(factory, older), "");
        assertEq(vault.cap(address(0)), CAP / 2);
        // Per token: another token's mark is its own, so its message, sent before the newer one, still runs.
        _deliver(factory, otherToken);
        assertEq(vault.governanceNonce(bytes32(uint256(VaultMessages.CAP_UPDATE) << 160 | uint160(alice))), nonce - 1);

        // One proof, a nonce far ahead: it may lower the cap, but the mark stays where both proofs put it.
        VaultMessages.Message memory forged = VaultMessages.Message({
            sourceChainId: 1,
            kind: VaultMessages.CAP_UPDATE,
            destChainId: block.chainid,
            vault: _b32(address(vault)),
            index: factory,
            nonce: type(uint64).max,
            body: abi.encode(bytes32(0), CAP / 8, FLOOR)
        });
        uint256 mark = vault.governanceNonce(capKey);
        vault.deliver(_proof(factory, VaultMessages.encode(forged)), "");
        assertEq(vault.cap(address(0)), CAP / 8);
        assertEq(vault.governanceNonce(capKey), mark, "one proof moves no mark");
        _govern(VaultMessages.CAP_UPDATE, abi.encode(bytes32(0), CAP, FLOOR));
        assertEq(vault.cap(address(0)), CAP, "the factory's next message still runs");

        // A freeze is never stale.
        _deliver(factory, _payload(VaultMessages.FREEZE, factory, ""));
        assertGt(vault.frozenUntil(), block.timestamp);
    }

    // ---------------------------------------------------------------------
    // digests
    // ---------------------------------------------------------------------

    /// @dev The digests are the hashes Ethereum proves: each is recomputable from the vault's public state.
    function test_digests_areTheHashOfThePublicState() public {
        _fund(index, 10 ether);
        _deliver(index, _burnPayload(index, 0.3 ether, bob));
        address[] memory tokens = vault.indexTokens(index);
        uint256[] memory balances = new uint256[](1);
        uint256[] memory paid = new uint256[](1);
        balances[0] = vault.balance(index, address(0));
        paid[0] = vault.paidTotal(index, address(0));
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("xindex.v4.vault.index-digest"), block.chainid, address(vault), index, tokens, balances, paid
            )
        );
        assertEq(vault.indexDigest(index), expected);

        uint256 intakeId = _intake(block.timestamp + 1 hours, 77);
        _deposit(alice, index, intakeId, 2 ether);
        uint256[] memory totals = new uint256[](1);
        totals[0] = 2 ether;
        bytes32 expectedIntake = keccak256(
            abi.encode(
                keccak256("xindex.v4.vault.intake-digest"),
                block.chainid,
                address(vault),
                index,
                intakeId,
                IXindexVault.IntakeState.Open,
                vault.intakeTokens(index, intakeId),
                totals
            )
        );
        assertEq(vault.intakeDigest(index, intakeId), expectedIntake);
    }

    // ---------------------------------------------------------------------
    // checkpoints and the stall
    // ---------------------------------------------------------------------

    function test_advanceCheckpoint_bothProofsAndAlwaysNewer() public {
        vm.warp(block.timestamp + 1 hours);
        bytes memory a = _checkpointProof(10, block.timestamp - 20 minutes, keccak256("a"));
        bytes memory b = _checkpointProof(10, block.timestamp - 20 minutes, keccak256("b"));
        vm.expectRevert(IXindexVault.ProofsDisagree.selector);
        vault.advanceCheckpoint(a, b);
        vm.expectEmit(address(vault));
        emit IXindexVault.CheckpointAdvanced(10, block.timestamp - 20 minutes, keccak256("a"));
        vault.advanceCheckpoint(a, a);
        assertEq(vault.checkpoint().blockNumber, 10);
        assertEq(vault.checkpoint().stateRoot, keccak256("a"));

        uint256 t = block.timestamp - 20 minutes;
        _notNewer(10, t + 1, keccak256("a")); // no later block
        _notNewer(11, t, keccak256("a")); // no later time
        _notNewer(11, block.timestamp + 1, keccak256("a")); // in the future
        _notNewer(11, t + 1, bytes32(0)); // no state
        bytes memory c = _checkpointProof(11, block.timestamp, keccak256("c"));
        vault.advanceCheckpoint(c, c);

        v1.setRefuse(true);
        vm.expectRevert(MockEventVerifier.Refused.selector);
        vault.advanceCheckpoint(c, c);
    }

    function _notNewer(uint256 blockNumber, uint256 time, bytes32 root) internal {
        bytes memory p = _checkpointProof(blockNumber, time, root);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotNewer.selector, blockNumber, time));
        vault.advanceCheckpoint(p, p);
    }

    /// @dev A week without a checkpoint stalls the vault: it takes no deposit, which it might never be able to settle
    ///      or refund, until anyone brings a new checkpoint.
    function test_stall_aWeekWithoutACheckpoint() public {
        uint256 deployed = vault.checkpoint().timestamp;
        assertEq(vault.stallStart(), deployed + 7 days);
        vm.warp(deployed + 7 days);
        assertFalse(vault.stalled());
        vm.warp(deployed + 7 days + 1);
        assertTrue(vault.stalled());
        uint256 intakeId = _intake(block.timestamp + 1 hours, 1);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.VaultStalled.selector, deployed + 7 days));
        vault.deposit{value: 1 ether}(index, intakeId);
        _fresh();
        assertFalse(vault.stalled());
        _deposit(alice, index, intakeId, 1 ether);
    }

    // ---------------------------------------------------------------------
    // stall recovery
    // ---------------------------------------------------------------------

    /// @dev A checkpoint at `blockNumber`, now, that the current verifiers prove; the vault's last one after it.
    function _advance(uint256 blockNumber) internal returns (bytes memory proof) {
        if (vault.checkpoint().timestamp >= block.timestamp) vm.warp(block.timestamp + 1);
        proof = _checkpointProof(blockNumber, block.timestamp, keccak256(abi.encode(blockNumber)));
        vault.advanceCheckpoint(proof, proof);
    }

    /// @dev The continuity test a successor passes: the last checkpoint, a recent one at `recentBlock`, and the last
    ///      message delivered.
    function _continuity(uint256 recentBlock, bytes memory message)
        internal
        view
        returns (IXindexVault.Continuity memory c)
    {
        IEthereumEventVerifier.Checkpoint memory last = vault.checkpoint();
        bytes memory lastProof = abi.encode(last);
        bytes memory recent = _checkpointProof(recentBlock, block.timestamp, keccak256(abi.encode(recentBlock)));
        c = IXindexVault.Continuity({
            last1: lastProof, last2: lastProof, recent1: recent, recent2: recent, message1: message, message2: message
        });
    }

    /// @dev A stall, a successor proposed by the emergency multisig, 30 days of review, adoption on a fresh
    ///      checkpoint: the vault runs on the new pair and no longer stalls.
    function test_recovery_proposeReviewAdopt() public {
        _advance(100);
        _fund(index, 10 ether); // a delivery: the last message a successor must prove again
        vm.warp(block.timestamp + 7 days + 1);
        assertTrue(vault.stalled());
        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        (,, bytes32 topic1,) = abi.decode(lastDelivered, (address, bytes32, bytes32, bytes));
        assertEq(vault.lastMessage(), topic1);
        IXindexVault.Continuity memory c = _continuity(200, lastDelivered);

        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotRecoveryProposer.selector, alice));
        vm.prank(alice);
        vault.proposeSuccessor(n1, n2, c);
        vm.startPrank(recoveryProposer);
        vm.expectRevert(IXindexVault.VerifiersNotDistinct.selector);
        vault.proposeSuccessor(n1, n1, c);
        vm.expectEmit(address(vault));
        emit IXindexVault.SuccessorProposed(address(n1), address(n2), block.timestamp + 30 days);
        vault.proposeSuccessor(n1, n2, c);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.SuccessorPending.selector, block.timestamp + 30 days));
        vault.proposeSuccessor(n1, n2, c);
        vm.stopPrank();
        assertEq(vault.successor().p1, address(n1));

        vm.expectRevert(abi.encodeWithSelector(IXindexVault.ReviewNotOver.selector, block.timestamp + 30 days));
        vault.adoptSuccessor(c.recent1, c.recent2);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotRecent.selector, block.timestamp - 30 days));
        vault.adoptSuccessor(c.recent1, c.recent2);
        bytes memory fresh = _checkpointProof(300, block.timestamp, keccak256("fresh"));
        vm.expectEmit(address(vault));
        emit IXindexVault.SuccessorAdopted(address(n1), address(n2));
        vault.adoptSuccessor(fresh, fresh);
        assertEq(address(vault.p1()), address(n1));
        assertEq(address(vault.p2()), address(n2));
        assertEq(vault.checkpoint().blockNumber, 300);
        assertFalse(vault.stalled());
        assertEq(vault.successor().reviewEnds, 0);
        vm.expectRevert(IXindexVault.NoSuccessor.selector);
        vault.adoptSuccessor(fresh, fresh);
    }

    /// @dev What a successor must prove: the checkpoint the pair in force last accepted, a recent one, and the last
    ///      message delivered. Only in a stall, and never after a snapshot.
    function test_recovery_theContinuityTest() public {
        _advance(100);
        _fund(index, 10 ether);
        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        bytes memory message = lastDelivered;
        IXindexVault.Continuity memory c = _continuity(200, message);
        vm.startPrank(recoveryProposer);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotStalled.selector, block.timestamp + 7 days));
        vault.proposeSuccessor(n1, n2, c);
        vm.warp(block.timestamp + 8 days);

        // (a) a different last checkpoint
        c = _continuity(200, message);
        c.last1 = _checkpointProof(99, block.timestamp - 8 days, keccak256("other"));
        c.last2 = c.last1;
        vm.expectRevert(IXindexVault.Discontinuous.selector);
        vault.proposeSuccessor(n1, n2, c);
        c = _continuity(200, message);
        c.last2 = _checkpointProof(99, block.timestamp - 8 days, keccak256("other"));
        vm.expectRevert(IXindexVault.ProofsDisagree.selector);
        vault.proposeSuccessor(n1, n2, c);
        // (b) a checkpoint no newer than the last, or not recent
        c = _continuity(100, message);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotNewer.selector, 100, block.timestamp));
        vault.proposeSuccessor(n1, n2, c);
        c = _continuity(200, message);
        uint256 stale = vault.checkpoint().timestamp + 1; // newer than the last, but more than a week old
        c.recent1 = _checkpointProof(200, stale, keccak256("stale"));
        c.recent2 = c.recent1;
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotRecent.selector, stale));
        vault.proposeSuccessor(n1, n2, c);
        // (c) another message than the last one delivered, from either
        c = _continuity(200, message);
        c.message2 = _proof(index, _burnPayload(index, 1, bob));
        vm.expectRevert(IXindexVault.Discontinuous.selector);
        vault.proposeSuccessor(n1, n2, c);
        c = _continuity(200, message);
        c.message1 = c.message2 = _proof(index, _burnPayload(index, 1, bob));
        vm.expectRevert(IXindexVault.Discontinuous.selector);
        vault.proposeSuccessor(n1, n2, c);
        vault.proposeSuccessor(n1, n2, _continuity(200, message));
        vm.stopPrank();
    }

    /// @dev A vault that never delivered a message needs no message proven again.
    function test_recovery_noMessageYet() public {
        _advance(100);
        vm.warp(block.timestamp + 7 days + 1);
        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        IXindexVault.Continuity memory c = _continuity(200, "");
        vm.prank(recoveryProposer);
        vault.proposeSuccessor(n1, n2, c);
    }

    /// @dev The freezer vetoes at most twice a stall; a checkpoint from the pair in force lapses a successor and
    ///      begins a new stall's count.
    function test_recovery_vetoesAndLapse() public {
        _advance(100);
        vm.warp(block.timestamp + 7 days + 1);
        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotFreezer.selector, alice));
        vm.prank(alice);
        vault.vetoSuccessor();
        vm.prank(freezerKey);
        vm.expectRevert(IXindexVault.NoSuccessor.selector);
        vault.vetoSuccessor();
        for (uint256 i = 0; i < 2; ++i) {
            IXindexVault.Continuity memory c = _continuity(200 + i, "");
            vm.prank(recoveryProposer);
            vault.proposeSuccessor(n1, n2, c);
            vm.expectEmit(address(vault));
            emit IXindexVault.SuccessorVetoed(i + 1);
            vm.prank(freezerKey);
            vault.vetoSuccessor();
        }
        IXindexVault.Continuity memory third = _continuity(210, "");
        vm.prank(recoveryProposer);
        vault.proposeSuccessor(n1, n2, third);
        vm.prank(freezerKey);
        vm.expectRevert(IXindexVault.VetoesExhausted.selector);
        vault.vetoSuccessor();
        assertEq(vault.vetoes(), 2);

        // The pair in force proves a new checkpoint: the stall is over, and so is the successor.
        vm.expectEmit(address(vault));
        emit IXindexVault.SuccessorLapsed();
        _advance(220);
        assertEq(vault.successor().reviewEnds, 0);
        assertEq(vault.vetoes(), 0);
        // A new stall, a new count.
        vm.warp(block.timestamp + 7 days + 1);
        IXindexVault.Continuity memory next = _continuity(230, "");
        vm.prank(recoveryProposer);
        vault.proposeSuccessor(n1, n2, next);
        vm.prank(freezerKey);
        vault.vetoSuccessor();
        assertEq(vault.vetoes(), 1);
    }

    /// @dev LG-2: during a stall the pair in force can still prove blocks up to where it broke, newer than the last
    ///      checkpoint but stale. Such an advance lets burns sent before the break run (VLT-3), and leaves the stall as
    ///      it was: the successor under review stays, and so does the freezer's count, so nobody can lapse the review
    ///      or win the freezer new vetoes one stale block at a time. Adoption ends the stall and the count.
    function test_LG2_aStaleCheckpointKeepsTheSuccessorAndTheVetoes() public {
        _advance(100);
        IEthereumEventVerifier.Checkpoint memory last = vault.checkpoint();
        vm.warp(block.timestamp + 8 days);
        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        IXindexVault.Continuity memory c = _continuity(9_000, "");
        vm.prank(recoveryProposer);
        vault.proposeSuccessor(n1, n2, c);
        vm.prank(freezerKey);
        vault.vetoSuccessor();
        c = _continuity(9_001, "");
        vm.prank(recoveryProposer);
        vault.proposeSuccessor(n1, n2, c);
        uint256 reviewEnds = vault.successor().reviewEnds;

        // A day before the review ends, a stranger advances by one stale block.
        vm.warp(reviewEnds - 1 days);
        bytes memory stale = _checkpointProof(101, last.timestamp + 12, keccak256("stale"));
        vm.recordLogs();
        vm.prank(alice);
        vault.advanceCheckpoint(stale, stale);
        assertEq(vm.getRecordedLogs().length, 1, "CheckpointAdvanced alone: no SuccessorLapsed");
        assertEq(vault.checkpoint().blockNumber, 101);
        assertTrue(vault.stalled());
        assertEq(vault.successor().reviewEnds, reviewEnds, "the review goes on");
        assertEq(vault.vetoes(), 1, "the count goes on");

        // The freezer's second veto is its last in this stall, stale advances or not.
        vm.prank(freezerKey);
        vault.vetoSuccessor();
        bytes memory stale2 = _checkpointProof(102, last.timestamp + 24, keccak256("stale 2"));
        vault.advanceCheckpoint(stale2, stale2);
        c = _continuity(9_002, "");
        vm.prank(recoveryProposer);
        vault.proposeSuccessor(n1, n2, c);
        bytes memory stale3 = _checkpointProof(103, last.timestamp + 36, keccak256("stale 3"));
        vault.advanceCheckpoint(stale3, stale3);
        vm.prank(freezerKey);
        vm.expectRevert(IXindexVault.VetoesExhausted.selector);
        vault.vetoSuccessor();

        // The review runs its course and the successor is adopted, which ends the stall and the count.
        vm.warp(vault.successor().reviewEnds);
        bytes memory fresh = _checkpointProof(9_100, block.timestamp, keccak256("fresh"));
        vault.adoptSuccessor(fresh, fresh);
        assertEq(address(vault.p1()), address(n1));
        assertFalse(vault.stalled());
        assertEq(vault.vetoes(), 0);
    }

    /// @dev LG-3: only a message on both proofs becomes the last message a successor must prove again. With one proof
    ///      system broken, a forged one-proof freeze still freezes, but it cannot keep an honest successor out.
    function test_LG3_aOneProofMessageIsNotTheLastMessage() public {
        _advance(100);
        _fund(index, 10 ether);
        bytes memory realLast = lastDelivered;
        bytes32 realId = vault.lastMessage();
        assertTrue(realId != bytes32(0));

        bytes memory forged = _payload(VaultMessages.FREEZE, factory, "");
        vault.deliver(_proof(factory, forged), "");
        assertTrue(vault.used(keccak256(forged)), "delivered: the vault is frozen");
        assertGt(vault.frozenUntil(), block.timestamp);
        bytes memory forged2 = _payload(VaultMessages.FREEZE, factory, "");
        vault.deliver("", _proof(factory, forged2));
        assertTrue(vault.used(keccak256(forged2)));
        assertEq(vault.lastMessage(), realId, "neither one-proof message counts");

        vm.warp(block.timestamp + 15 days);
        assertTrue(vault.stalled());
        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        IXindexVault.Continuity memory c = _continuity(200, realLast);
        vm.prank(recoveryProposer);
        vault.proposeSuccessor(n1, n2, c);
        assertEq(vault.successor().p1, address(n1));
    }

    // ---------------------------------------------------------------------
    // the snapshot exit
    // ---------------------------------------------------------------------

    /// @dev A stall 180 days old with no successor: the last checkpoint becomes the snapshot for good.
    function _snapshot() internal returns (IEthereumEventVerifier.Checkpoint memory snap) {
        vm.roll(1000);
        _advance(1000);
        snap = vault.checkpoint();
        vm.warp(vault.stallStart() + 180 days);
        vault.beginSnapshot();
    }

    function test_beginSnapshot_onlyAfter180DaysOfStall() public {
        vm.warp(vault.stallStart() + 180 days);
        vm.expectRevert(IXindexVault.NoCheckpoint.selector);
        vault.beginSnapshot();
        _advance(1000);
        IEthereumEventVerifier.Checkpoint memory last = vault.checkpoint();
        uint256 due = vault.stallStart() + 180 days;
        vm.warp(due - 1);
        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        IXindexVault.Continuity memory c = _continuity(1001, "");
        vm.prank(recoveryProposer);
        vault.proposeSuccessor(n1, n2, c);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.SnapshotNotDue.selector, due));
        vault.beginSnapshot();
        vm.warp(due);
        vm.expectEmit(address(vault));
        emit IXindexVault.SnapshotBegun(last.blockNumber, last.timestamp, last.stateRoot);
        vault.beginSnapshot();
        assertEq(vault.snapshot().stateRoot, last.stateRoot);
        assertEq(vault.successor().reviewEnds, 0, "a successor under review lapses");

        vm.expectRevert(IXindexVault.SnapshotTaken.selector);
        vault.beginSnapshot();
        bytes memory later = _checkpointProof(2000, block.timestamp, keccak256("later"));
        vm.expectRevert(IXindexVault.SnapshotTaken.selector);
        vault.advanceCheckpoint(later, later);
        vm.prank(recoveryProposer);
        vm.expectRevert(IXindexVault.SnapshotTaken.selector);
        vault.proposeSuccessor(n1, n2, c);
        vm.prank(freezerKey);
        vm.expectRevert(IXindexVault.SnapshotTaken.selector);
        vault.freeze();
    }

    /// @dev Marks `payload` as sent in the index's storage, where the hub's `_sentMessages` (slot 62) keeps it.
    function _record(bytes memory payload) internal {
        vm.store(index, keccak256(abi.encode(keccak256(payload), uint256(62))), bytes32(uint256(1)));
    }

    /// @dev A burn or migration in flight when P1 and P2 stopped, never delivered, runs after the snapshot on the index's
    ///      own record of it, once, within the speed limit. Nothing else runs that way.
    function test_deliverRecorded_paysWhatWasInFlight() public {
        _fund(index, 10 ether);
        bytes memory burn = _burnPayload(index, 1 ether, bob);
        bytes32 id = keccak256(burn);
        _record(burn);
        vm.expectRevert(IXindexVault.NoSnapshot.selector);
        vault.deliverRecorded(burn, "");
        _snapshot();

        vm.expectEmit(address(vault));
        emit IXindexVault.MessageDelivered(id, VaultMessages.BURN, index);
        vault.deliverRecorded(burn, "");
        assertEq(bob.balance, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.AlreadyDelivered.selector, id));
        vault.deliverRecorded(burn, "");

        bytes memory unrecorded = _burnPayload(index, 1 ether, bob);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotRecorded.selector, keccak256(unrecorded)));
        vault.deliverRecorded(unrecorded, "");
        bytes memory settle = _payload(VaultMessages.INTAKE_SETTLED, index, abi.encode(uint256(1)));
        _record(settle);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.UnknownKind.selector, VaultMessages.INTAKE_SETTLED));
        vault.deliverRecorded(settle, "");
        VaultMessages.Message memory m = VaultMessages.decode(_burnPayload(index, 1 ether, bob));
        m.destChainId = block.chainid + 1;
        vm.expectRevert(IXindexVault.WrongRoute.selector);
        vault.deliverRecorded(VaultMessages.encode(m), "");
        address unregistered = _index(keccak256("unregistered"));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, unregistered));
        vault.deliverRecorded(_burnPayload(unregistered, 1 ether, bob), "");

        // A migration in flight is owed to the new index, as a delivered one would be, and moves within the limit.
        address next = _registered(keccak256("index-2"));
        bytes memory migration = _payload(VaultMessages.MIGRATE, index, abi.encode(next, bytes32(0), 2 ether));
        _record(migration);
        vault.deliverRecorded(migration, "");
        assertEq(vault.owed(index, keccak256(migration)).remaining, 2 ether, "the burn used the day's floor");
        vm.warp(block.timestamp + 25 hours);
        vault.release(index, keccak256(migration));
        assertEq(vault.balance(next, address(0)), 1 ether, "the floor's worth a day");
    }

    /// @dev After the snapshot, a message from a later Ethereum block never runs; one from its block or before does.
    function test_snapshot_refusesLaterMessages() public {
        _fund(index, 10 ether);
        IEthereumEventVerifier.Checkpoint memory snap = _snapshot();
        bytes memory payload = _burnPayload(index, 1 ether, bob);
        v1.setEventBlock(snap.blockNumber + 1);
        v2.setEventBlock(snap.blockNumber + 1);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IssuedAfterSnapshot.selector, snap.blockNumber + 1));
        _deliver(index, payload);
        v2.setEventBlock(snap.blockNumber);
        vm.expectRevert(IXindexVault.ProofsDisagree.selector);
        _deliver(index, payload);
        v1.setEventBlock(snap.blockNumber);
        _deliver(index, payload);
        assertEq(bob.balance, 1 ether);
    }

    /// @dev VLT-1: a snapshot claim reads a component only inside the hub's components array. Past its end lies other
    ///      storage a holder may be able to fill, with a token and "units" of its choosing.
    function test_VLT1_theComponentMustLieInsideTheArray() public {
        _fund(index, 100 ether);
        (address holder, uint256 key) = makeAddrAndKey("holder");
        _hubState(index, holder, 2e18, 1.4e18, 0, address(0));
        // Storage past the array's end, filled as if a component: the vault's coin at a far larger unit count.
        uint256 past = 7;
        vm.store(
            index,
            bytes32(uint256(keccak256(abi.encode(uint256(0)))) + past),
            bytes32(uint256(1e24) << 160 | uint160(_nativeId()))
        );
        _snapshot();
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.WrongComponent.selector, past));
        vault.claimSnapshot(index, holder, bob, past, "", _sign(key, index, holder, bob));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.WrongComponent.selector, 2));
        vault.claimSnapshot(index, holder, bob, 2, "", _sign(key, index, holder, bob));
        vault.claimSnapshot(index, holder, bob, 1, "", _sign(key, index, holder, bob));
        assertEq(bob.balance, 2.8 ether);
    }

    /// @dev VLT-I3: a recovery address that can be no address here counts as none, so its holder still claims by
    ///      signature.
    function test_VLTI3_aMalformedRecoveryAddressCountsAsNone() public {
        _fund(index, 100 ether);
        (address holder, uint256 key) = makeAddrAndKey("holder");
        _hubState(index, holder, 2e18, 1.4e18, 0, address(0));
        bytes32 slot = keccak256(abi.encode(block.chainid, keccak256(abi.encode(holder, uint256(59)))));
        vm.store(index, slot, bytes32(type(uint256).max));
        _snapshot();
        vault.claimSnapshot(index, holder, bob, 1, "", _sign(key, index, holder, bob));
        assertEq(bob.balance, 2.8 ether);
    }

    /// @dev VLT-3: a message that moves coins or loosens a rule runs only from a block the checkpoint covers, so the
    ///      snapshot at that checkpoint never pays a holder whose burn the vault paid too. A freeze and a lowered cap
    ///      need no checkpoint.
    function test_VLT3_aMessageAfterTheCheckpointWaitsForIt() public {
        _fund(index, 10 ether);
        _advance(100);
        v1.setEventBlock(101);
        v2.setEventBlock(101);
        bytes memory payload = _burnPayload(index, 1 ether, bob);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotCheckpointed.selector, 101, 100));
        _deliver(index, payload);
        _deliver(factory, _payload(VaultMessages.CAP_UPDATE, factory, abi.encode(bytes32(0), CAP / 2, FLOOR)));
        assertEq(vault.cap(address(0)), CAP / 2);
        _deliver(factory, _payload(VaultMessages.FREEZE, factory, ""));
        vm.warp(vault.frozenUntil());
        _advance(101);
        _deliver(index, payload);
        assertEq(bob.balance, 1 ether);
    }

    /// @dev VLT-5: after the snapshot a proven freeze cannot hold the exit off, as the freezer's own cannot.
    function test_VLT5_noFreezeAfterTheSnapshot() public {
        _fund(index, 10 ether);
        _snapshot();
        vm.expectRevert(IXindexVault.SnapshotTaken.selector);
        _deliver(factory, _payload(VaultMessages.FREEZE, factory, ""));
        vm.expectRevert(IXindexVault.SnapshotTaken.selector);
        vault.deliver(_proof(factory, _payload(VaultMessages.FREEZE, factory, "")), "");
        assertEq(vault.frozenUntil(), 0);
    }

    /// @dev Writes the hub's storage the snapshot reads, at the index's address: shares, the component, the claim, the
    ///      recovery address.
    function _hubState(address idx, address holder, uint256 shares, uint256 units, uint256 claim, address recovery)
        internal
    {
        bytes32 hubShares = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
        address token = _nativeId();
        vm.store(idx, keccak256(abi.encode(holder, hubShares)), bytes32(shares));
        vm.store(idx, bytes32(0), bytes32(uint256(2))); // two components; the vault's coin is the second
        vm.store(idx, bytes32(uint256(keccak256(abi.encode(uint256(0)))) + 1), bytes32(units << 160 | uint160(token)));
        vm.store(idx, keccak256(abi.encode(token, keccak256(abi.encode(holder, uint256(11))))), bytes32(claim));
        vm.store(
            idx,
            keccak256(abi.encode(block.chainid, keccak256(abi.encode(holder, uint256(59))))),
            bytes32(uint256(uint160(recovery)))
        );
    }

    function _nativeId() internal view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encode(keccak256("xindex.v4.vault-token"), block.chainid, bytes32(0)))))
            );
    }

    function _sign(uint256 key, address idx, address holder, address recipient) internal view returns (bytes memory) {
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
                keccak256("SnapshotClaim(address index,address holder,address recipient)"), idx, holder, recipient
            )
        );
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s_, v);
    }

    /// @dev An EOA holder signs for its recipient: paid its shares' backing at the snapshot's units plus its claim,
    ///      within the speed limit.
    function test_claimSnapshot_bySignature() public {
        _fund(index, 100 ether);
        (address holder, uint256 key) = makeAddrAndKey("holder");
        _hubState(index, holder, 2e18, 1.4e18, 0.2 ether, address(0));
        vm.expectRevert(IXindexVault.NoSnapshot.selector);
        vault.claimSnapshot(index, holder, bob, 1, "", _sign(key, index, holder, bob));
        _snapshot();

        vm.expectRevert(IXindexVault.BadSignature.selector);
        vault.claimSnapshot(index, holder, bob, 1, "", _sign(key, index, holder, alice));
        vm.expectRevert(IXindexVault.BadSignature.selector);
        vault.claimSnapshot(index, holder, bob, 1, "", hex"00");
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.WrongComponent.selector, 0));
        vault.claimSnapshot(index, holder, bob, 0, "", _sign(key, index, holder, bob));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, alice));
        vault.claimSnapshot(alice, holder, bob, 1, "", _sign(key, index, holder, bob));
        vm.expectRevert(IXindexVault.ZeroAddress.selector);
        vault.claimSnapshot(index, holder, address(0), 1, "", _sign(key, index, holder, address(0)));

        bytes32 id = keccak256(
            abi.encode(keccak256("SnapshotClaim(address index,address holder,address recipient)"), index, holder)
        );
        vm.expectEmit(address(vault));
        emit IXindexVault.SnapshotClaimed(index, holder, bob, 3 ether, id);
        vault.claimSnapshot(index, holder, bob, 1, "", _sign(key, index, holder, bob));
        assertEq(bob.balance, 3 ether, "2 shares at 1.4, plus a claim of 0.2");
        assertTrue(vault.snapshotClaimed(index, holder));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.AlreadyClaimed.selector, index, holder));
        vault.claimSnapshot(index, holder, bob, 1, "", _sign(key, index, holder, bob));
    }

    /// @dev A holder with a recovery address, such as a contract, is paid there and only there; one with no share is
    ///      paid nothing; a large claim waits for the speed limit.
    function test_claimSnapshot_toTheRecoveryAddress() public {
        _fund(index, 100 ether);
        address safe = makeAddr("a safe");
        address safeOnBnb = makeAddr("the safe's recovery address");
        _hubState(index, safe, 50e18, 1e18, 0, safeOnBnb);
        address nobody = makeAddr("nobody");
        _snapshot();
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.WrongRecipient.selector, safeOnBnb));
        vault.claimSnapshot(index, safe, bob, 1, "", "");
        vault.claimSnapshot(index, safe, safeOnBnb, 1, "", "");
        assertEq(safeOnBnb.balance, 4 ether, "4% of the 100 today");
        bytes32 id = keccak256(
            abi.encode(keccak256("SnapshotClaim(address index,address holder,address recipient)"), index, safe)
        );
        assertEq(vault.owed(index, id).remaining, 46 ether);
        vm.warp(block.timestamp + 25 hours);
        vault.release(index, id);
        assertEq(safeOnBnb.balance, 4 ether + 3.84 ether);

        _hubState(index, nobody, 0, 1e18, 0, address(0));
        vm.expectRevert(IXindexVault.ZeroAmount.selector);
        vault.claimSnapshot(index, nobody, bob, 1, "", "");
    }

    /// @dev After the snapshot, an intake still open is settled if the hub had sent its settle message by then, and
    ///      otherwise failed, so its depositors take their coins back.
    function test_resolveIntake_fromTheHubAtTheSnapshot() public {
        uint256 settled = _intake(block.timestamp + 1 hours, 71);
        uint256 unsettled = _intake(block.timestamp + 1 hours, 72);
        _deposit(alice, index, settled, 2 ether);
        _deposit(bob, index, unsettled, 3 ether);
        vm.store(index, keccak256(abi.encode(settled, uint256(60))), bytes32(uint256(1)));
        vm.expectRevert(IXindexVault.NoSnapshot.selector);
        vault.resolveIntake(index, settled, "");
        _snapshot();

        vm.expectEmit(address(vault));
        emit IXindexVault.IntakeResolved(index, settled, true);
        vault.resolveIntake(index, settled, "");
        assertEq(vault.balance(index, address(0)), 2 ether);
        vault.resolveIntake(index, unsettled, "");
        assertEq(uint256(vault.intakeState(index, unsettled)), uint256(IXindexVault.IntakeState.Failed));
        vm.prank(bob);
        vault.refund(index, unsettled);
        assertEq(bob.balance, 3 ether);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.IntakeNotOpen.selector, index, settled));
        vault.resolveIntake(index, settled, "");
    }
}
