// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {XindexVault} from "../src/vault/XindexVault.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";
import {IEthereumEventVerifier} from "../src/interfaces/IEthereumEventVerifier.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {MockEventVerifier} from "./mocks/MockEventVerifier.sol";

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

    function _deployVault() internal {
        v1 = new MockEventVerifier();
        v2 = new MockEventVerifier();
        vault = new XindexVault(1, factory, hubImplementation, v1, v2, freezerKey, CAP, FLOOR);
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

    function _deliver(address emitter, bytes memory payload) internal {
        vault.deliver(_proof(emitter, payload), _proof(emitter, payload));
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

        IEthereumEventVerifier none = IEthereumEventVerifier(address(0));
        vm.expectRevert(IXindexVault.ZeroAddress.selector);
        new XindexVault(1, address(0), hubImplementation, v1, v2, freezerKey, CAP, FLOOR);
        vm.expectRevert(IXindexVault.ZeroAddress.selector);
        new XindexVault(1, factory, address(0), v1, v2, freezerKey, CAP, FLOOR);
        vm.expectRevert(IXindexVault.ZeroAddress.selector);
        new XindexVault(1, factory, hubImplementation, none, v2, freezerKey, CAP, FLOOR);
        vm.expectRevert(IXindexVault.ZeroAddress.selector);
        new XindexVault(1, factory, hubImplementation, v1, none, freezerKey, CAP, FLOOR);
        vm.expectRevert(IXindexVault.ZeroAddress.selector);
        new XindexVault(1, factory, hubImplementation, v1, v2, address(0), CAP, FLOOR);
        IEthereumEventVerifier noCode = IEthereumEventVerifier(makeAddr("no code"));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAContract.selector, address(noCode)));
        new XindexVault(1, factory, hubImplementation, noCode, v2, freezerKey, CAP, FLOOR);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAContract.selector, address(noCode)));
        new XindexVault(1, factory, hubImplementation, v1, noCode, freezerKey, CAP, FLOOR);
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

    function test_migrate_movesCoinsBetweenIndexes() public {
        _fund(index, 10 ether);
        address next = _registered(keccak256("index-2"));
        bytes memory body = abi.encode(next, bytes32(0), 6 ether);
        _deliver(index, _payload(VaultMessages.MIGRATE, index, body));
        assertEq(vault.balance(index, address(0)), 4 ether);
        assertEq(vault.balance(next, address(0)), 6 ether);
        assertEq(vault.held(address(0)), 10 ether, "nothing left the vault");
        assertEq(vault.indexTokens(next).length, 1);

        address unregistered = _index(keccak256("index-3"));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, unregistered));
        _deliver(index, _payload(VaultMessages.MIGRATE, index, abi.encode(unregistered, bytes32(0), 1 ether)));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAnIndex.selector, index));
        _deliver(index, _payload(VaultMessages.MIGRATE, index, abi.encode(index, bytes32(0), 1 ether)));
        vm.expectRevert(IXindexVault.ZeroAmount.selector);
        _deliver(index, _payload(VaultMessages.MIGRATE, index, abi.encode(next, bytes32(0), 0)));
        vm.expectRevert(
            abi.encodeWithSelector(IXindexVault.InsufficientBalance.selector, index, address(0), 4 ether, 5 ether)
        );
        _deliver(index, _payload(VaultMessages.MIGRATE, index, abi.encode(next, bytes32(0), 5 ether)));
    }

    /// @dev Lowering a cap or a floor is protective and may rest on one proof; raising either needs both.
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
        assertEq(vault.cap(address(0)), CAP);
    }

    /// @dev A freeze stops deposits, payouts, refunds and migration; accepted burns wait; it ends by itself.
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
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.VaultFrozen.selector, until));
        _deliver(index, _payload(VaultMessages.MIGRATE, index, abi.encode(next, bytes32(0), 1 ether)));

        vm.warp(block.timestamp + 1 days);
        vm.prank(freezerKey);
        vault.freeze(); // a new act extends it
        assertEq(vault.frozenUntil(), block.timestamp + 14 days);
        _deliver(factory, _payload(VaultMessages.FREEZE, factory, "")); // a proven freeze never shortens it
        assertEq(vault.frozenUntil(), block.timestamp + 14 days);

        vm.warp(vault.frozenUntil());
        vault.release(index, id);
        assertEq(bob.balance, 1 ether, "paid once the freeze ended");
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
        _deliver(factory, _payload(VaultMessages.FREEZER_CHANGE, factory, abi.encode(_b32(newFreezer))));
        assertEq(vault.freezer(), newFreezer);
        vm.expectRevert(IXindexVault.ZeroAddress.selector);
        _deliver(factory, _payload(VaultMessages.FREEZER_CHANGE, factory, abi.encode(bytes32(0))));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.BothProofsRequired.selector, VaultMessages.FREEZER_CHANGE));
        vault.deliver(_proof(factory, _payload(VaultMessages.FREEZER_CHANGE, factory, abi.encode(_b32(alice)))), "");

        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        _deliver(
            factory,
            _payload(VaultMessages.VERIFIER_ROTATION, factory, abi.encode(_b32(address(n1)), _b32(address(n2))))
        );
        assertEq(address(vault.p1()), address(n1));
        assertEq(address(vault.p2()), address(n2));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAContract.selector, alice));
        _deliver(
            factory, _payload(VaultMessages.VERIFIER_ROTATION, factory, abi.encode(_b32(alice), _b32(address(n2))))
        );
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.NotAContract.selector, alice));
        _deliver(
            factory, _payload(VaultMessages.VERIFIER_ROTATION, factory, abi.encode(_b32(address(n1)), _b32(alice)))
        );
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
}
