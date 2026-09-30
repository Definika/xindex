// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {XindexVault} from "../src/vault/XindexVault.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {MockEventVerifier} from "./mocks/MockEventVerifier.sol";
import {MockStateReader} from "./mocks/MockStateReader.sol";
import {IEthereumEventVerifier} from "../src/interfaces/IEthereumEventVerifier.sol";

/// @notice Drives deposits, settled and failed intakes, refunds, burns, releases, migrations, cap changes, freezes,
///         replays, stray coins and the clock in any order, making only calls that must succeed, and records every
///         payout where it landed so the invariants check the vault against what actually moved.
contract VaultHandler is Test {
    XindexVault public immutable VAULT;
    address public immutable FACTORY;
    address public immutable FREEZER;
    address[2] public indexes;
    address[3] internal _actors = [makeAddr("d0"), makeAddr("d1"), makeAddr("d2")];
    address[3] internal _recipients = [makeAddr("to0"), makeAddr("to1"), makeAddr("to2")];

    struct Intake {
        address index;
        uint256 id;
    }

    struct Burn {
        address index;
        bytes32 id;
        uint256 amount;
        uint256 paid;
    }

    struct Payout {
        address index;
        uint256 time;
        uint256 amount;
        uint256 balanceAfter;
        uint256 floor;
    }

    Intake[] public intakes;
    Burn[] public burns;
    Payout[] public payouts;
    bytes[] internal _delivered;

    /// @notice What each index was credited: settled intakes, and migrations in as they were paid.
    mapping(address index => uint256) public credited;
    /// @notice What each index paid out, burns and migrations alike, measured where it landed.
    mapping(address index => uint256) public paidOut;
    /// @notice Coins sent to the vault outside any deposit.
    uint256 public stray;

    bool public replayed;
    bool public movedOtherThanPaid;
    uint256 public settles;
    uint256 public fails;
    uint256 public refunds;
    uint256 public releases;
    uint256 public migrations;
    uint256 public capUpdates;
    uint256 public freezes;
    uint256 internal _nonce;

    constructor(XindexVault vault, address factory, address freezer, address[2] memory indexes_) {
        VAULT = vault;
        FACTORY = factory;
        FREEZER = freezer;
        indexes = indexes_;
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _frozen() internal view returns (bool) {
        return block.timestamp < VAULT.frozenUntil();
    }

    /// @dev A checkpoint at the current time, as keepers keep the vault out of a stall.
    function _fresh() internal {
        IEthereumEventVerifier.Checkpoint memory c = VAULT.checkpoint();
        if (c.timestamp >= block.timestamp) return;
        bytes memory proof = abi.encode(
            IEthereumEventVerifier.Checkpoint({
                blockNumber: c.blockNumber + 1, timestamp: uint64(block.timestamp), stateRoot: keccak256("state root")
            })
        );
        VAULT.advanceCheckpoint(proof, proof);
    }

    function _deliver(uint8 kind, address emitter, bytes memory body) internal returns (bytes32) {
        bytes memory payload = VaultMessages.encode(
            VaultMessages.Message({
                sourceChainId: 1,
                kind: kind,
                destChainId: block.chainid,
                vault: bytes32(uint256(uint160(address(VAULT)))),
                index: emitter,
                nonce: ++_nonce,
                body: body
            })
        );
        bytes memory proof = abi.encode(emitter, VaultMessages.EVENT_TOPIC, keccak256(payload), abi.encode(payload));
        VAULT.deliver(proof, proof);
        _delivered.push(proof);
        return keccak256(payload);
    }

    /// @dev Records a payout of `index` measured at its recipient, and flags a balance that moved by anything else.
    function _record(address index, uint256 paid, uint256 balanceBefore) internal {
        uint256 balanceAfter = VAULT.balance(index, address(0));
        movedOtherThanPaid = movedOtherThanPaid || balanceBefore - balanceAfter != paid;
        if (paid == 0) return;
        paidOut[index] += paid;
        payouts.push(Payout(index, block.timestamp, paid, balanceAfter, VAULT.outflowFloor(address(0))));
    }

    // ---------------------------------------------------------------------
    // actions
    // ---------------------------------------------------------------------

    /// @notice A deposit into a new intake, or into an open one whose deadline has not passed.
    function deposit(uint256 who, uint256 pick, uint256 amount, uint256 life, bool fresh) external {
        if (_frozen()) return;
        amount = bound(amount, 1, 50 ether);
        if (VAULT.held(address(0)) + amount > VAULT.cap(address(0))) return;
        address index;
        uint256 id;
        if (fresh || intakes.length == 0) {
            index = indexes[pick % 2];
            id = ((block.timestamp + bound(life, 1 hours, 7 days)) << 192) | ++_nonce;
            intakes.push(Intake(index, id));
        } else {
            Intake memory it = intakes[pick % intakes.length];
            (index, id) = (it.index, it.id);
            if (VAULT.intakeState(index, id) != IXindexVault.IntakeState.Open) return;
            if (block.timestamp > id >> 192) return;
        }
        address depositor = _actors[who % 3];
        vm.deal(depositor, amount);
        _fresh();
        vm.prank(depositor);
        VAULT.deposit{value: amount}(index, id);
    }

    function settle(uint256 pick) external {
        if (intakes.length == 0) return;
        Intake memory it = intakes[pick % intakes.length];
        if (VAULT.intakeState(it.index, it.id) != IXindexVault.IntakeState.Open) return;
        credited[it.index] += VAULT.intakeTotal(it.index, it.id, address(0));
        _deliver(VaultMessages.INTAKE_SETTLED, it.index, abi.encode(it.id));
        ++settles;
    }

    function fail(uint256 pick) external {
        if (intakes.length == 0) return;
        Intake memory it = intakes[pick % intakes.length];
        if (VAULT.intakeState(it.index, it.id) != IXindexVault.IntakeState.Open) return;
        _deliver(VaultMessages.INTAKE_FAILED, it.index, abi.encode(it.id));
        ++fails;
    }

    function refund(uint256 pick, uint256 who) external {
        if (intakes.length == 0 || _frozen()) return;
        Intake memory it = intakes[pick % intakes.length];
        if (VAULT.intakeState(it.index, it.id) != IXindexVault.IntakeState.Failed) return;
        address depositor = _actors[who % 3];
        uint256 amount = VAULT.deposited(it.index, it.id, address(0), depositor);
        if (amount == 0) return;
        uint256 before = depositor.balance;
        vm.prank(depositor);
        VAULT.refund(it.index, it.id);
        movedOtherThanPaid = movedOtherThanPaid || depositor.balance - before != amount;
        ++refunds;
    }

    /// @notice A burn proven from Ethereum: it pays what the limit allows now and owes the rest.
    function burn(uint256 pick, uint256 amount, uint256 to) external {
        address index = indexes[pick % 2];
        amount = bound(amount, 1, 20 ether);
        address recipient = _recipients[to % 3];
        uint256 before = recipient.balance;
        uint256 balanceBefore = VAULT.balance(index, address(0));
        bytes32 id =
            _deliver(VaultMessages.BURN, index, abi.encode(bytes32(0), amount, bytes32(uint256(uint160(recipient)))));
        uint256 paid = recipient.balance - before;
        burns.push(Burn(index, id, amount, paid));
        _record(index, paid, balanceBefore);
    }

    function release(uint256 pick) external {
        if (burns.length == 0 || _frozen()) return;
        Burn storage b = burns[pick % burns.length];
        IXindexVault.Owed memory o = VAULT.owed(b.index, b.id);
        if (o.remaining == 0) return;
        if (VAULT.available(b.index, address(0)) == 0 || VAULT.balance(b.index, address(0)) == 0) return;
        uint256 before = _received(o);
        uint256 balanceBefore = VAULT.balance(b.index, address(0));
        VAULT.release(b.index, b.id);
        uint256 paid = _received(o) - before;
        b.paid += paid;
        if (o.toIndex) credited[o.recipient] += paid;
        _record(b.index, paid, balanceBefore);
        ++releases;
    }

    /// @dev What an owed payout's recipient holds: a burn's recipient's coins, or a migration's new index's balance.
    function _received(IXindexVault.Owed memory o) internal view returns (uint256) {
        return o.toIndex ? VAULT.balance(o.recipient, address(0)) : o.recipient.balance;
    }

    /// @notice A migration proven from Ethereum: like a burn, it moves what the limit allows now and owes the rest,
    ///         frozen or not.
    function migrate(uint256 pick, uint256 amount) external {
        (address from, address to) = pick % 2 == 0 ? (indexes[0], indexes[1]) : (indexes[1], indexes[0]);
        amount = bound(amount, 1, 20 ether);
        uint256 before = VAULT.balance(to, address(0));
        uint256 balanceBefore = VAULT.balance(from, address(0));
        bytes32 id = _deliver(VaultMessages.MIGRATE, from, abi.encode(to, bytes32(0), amount));
        uint256 paid = VAULT.balance(to, address(0)) - before;
        burns.push(Burn(from, id, amount, paid));
        credited[to] += paid;
        _record(from, paid, balanceBefore);
        ++migrations;
    }

    /// @notice Raises or lowers the cap and the floor; a cap is never set below what the vault already holds.
    function setCaps(uint256 newCap, uint256 newFloor) external {
        newCap = bound(newCap, VAULT.held(address(0)), 1000 ether);
        newFloor = bound(newFloor, 0, 5 ether);
        _deliver(VaultMessages.CAP_UPDATE, FACTORY, abi.encode(bytes32(0), newCap, newFloor));
        ++capUpdates;
    }

    /// @notice The guardian freezes now and then; the clock ends it.
    function freeze(uint256 seed) external {
        if (seed % 4 != 0) return;
        vm.prank(FREEZER);
        VAULT.freeze();
        ++freezes;
    }

    /// @notice Delivers a message already run; it must be refused.
    function replay(uint256 pick) external {
        if (_delivered.length == 0) return;
        bytes memory proof = _delivered[pick % _delivered.length];
        (bool ok,) = address(VAULT).call(abi.encodeCall(VAULT.deliver, (proof, proof)));
        replayed = replayed || ok;
    }

    function sendStray(uint256 amount) external {
        amount = bound(amount, 1, 5 ether);
        vm.deal(address(VAULT), address(VAULT).balance + amount);
        stray += amount;
    }

    /// @notice Moves the clock: a little, to an hour's last second, to the first second of the hour 24 later, or days.
    function warp(uint256 seed) external {
        uint256 mode = seed % 4;
        uint256 hourEnd = (block.timestamp / 1 hours + 1) * 1 hours - 1;
        if (mode == 0) vm.warp(block.timestamp + bound(seed, 1, 2 hours));
        else if (mode == 1) vm.warp(hourEnd > block.timestamp ? hourEnd : block.timestamp + 1);
        else if (mode == 2) vm.warp(block.timestamp + 23 hours + 1);
        else vm.warp(block.timestamp + bound(seed, 1 days, 15 days));
    }

    // ---------------------------------------------------------------------
    // views for the invariants
    // ---------------------------------------------------------------------

    function intakeCount() external view returns (uint256) {
        return intakes.length;
    }

    function burnCount() external view returns (uint256) {
        return burns.length;
    }

    function payoutCount() external view returns (uint256) {
        return payouts.length;
    }

    function payoutAt(uint256 i) external view returns (Payout memory) {
        return payouts[i];
    }
}

/// @notice V1 to V5 of the Stage B spec, whatever depositors, Ethereum's messages, the guardian and the clock do: the
///         vault holds what it owes, a message pays at most once, a burn pays at most its index's balance, outflow
///         over any 24 real hours stays within the speed limit, and each digest is the hash of what it covers.
contract XindexVaultInvariantTest is Test {
    XindexVault vault;
    VaultHandler handler;
    address factory = makeAddr("ethereumFactory");
    address hubImplementation = makeAddr("hubImplementation");
    address[2] indexes;

    function setUp() public {
        vm.warp(1_700_000_000);
        vault = new XindexVault(
            IXindexVault.Config({
                sourceChainId: 1,
                factory: factory,
                hubImplementation: hubImplementation,
                verifier1: new MockEventVerifier(),
                verifier2: new MockEventVerifier(),
                freezer: makeAddr("freezer"),
                recoveryProposer: makeAddr("recovery proposer"),
                stateReader: new MockStateReader(),
                nativeCap: 500 ether,
                nativeFloor: 1 ether
            })
        );
        for (uint256 i = 0; i < 2; ++i) {
            bytes32 salt = keccak256(abi.encode("index", i));
            indexes[i] = Clones.predictDeterministicAddress(hubImplementation, salt, factory);
            vault.registerIndex(indexes[i], salt);
        }
        handler = new VaultHandler(vault, factory, makeAddr("freezer"), indexes);
        targetContract(address(handler));
    }

    /// @dev V1: the vault's coins are `held` plus stray coins, and `held` is every settled balance plus every open or
    ///      failed intake's unrefunded deposits.
    function invariant_V1_theVaultHoldsWhatItOwes() public view {
        assertEq(address(vault).balance, vault.held(address(0)) + handler.stray(), "coins drifted from held");
        uint256 owedTotal = vault.balance(indexes[0], address(0)) + vault.balance(indexes[1], address(0));
        for (uint256 i = 0; i < handler.intakeCount(); ++i) {
            (address index, uint256 id) = handler.intakes(i);
            IXindexVault.IntakeState state = vault.intakeState(index, id);
            if (state == IXindexVault.IntakeState.Open || state == IXindexVault.IntakeState.Failed) {
                owedTotal += vault.intakeTotal(index, id, address(0));
            }
        }
        assertEq(vault.held(address(0)), owedTotal, "held is not the balances plus the pending deposits");
        assertLe(vault.held(address(0)), vault.cap(address(0)), "held above the cap");
    }

    /// @dev V2: a delivered message never runs again, and a burn's or a migration's payouts plus what it still owes are
    ///      its amount.
    function invariant_V2_aMessagePaysAtMostOnce() public view {
        assertFalse(handler.replayed(), "a message was delivered twice");
        for (uint256 i = 0; i < handler.burnCount(); ++i) {
            (address index, bytes32 id, uint256 amount, uint256 paid) = handler.burns(i);
            assertEq(paid + vault.owed(index, id).remaining, amount, "a burn paid other than its amount");
        }
    }

    /// @dev V3: an index pays out only what it was credited, exactly what left its balance, and its `paidTotal`.
    function invariant_V3_aBurnPaysAtMostItsIndexsBalance() public view {
        assertFalse(handler.movedOtherThanPaid(), "a balance moved by other than what was paid");
        for (uint256 i = 0; i < 2; ++i) {
            address index = indexes[i];
            assertEq(vault.paidTotal(index, address(0)), handler.paidOut(index), "paidTotal is not what was paid");
            assertEq(
                vault.balance(index, address(0)) + handler.paidOut(index),
                handler.credited(index),
                "an index paid out more than it was credited"
            );
        }
    }

    /// @dev V4, on real timestamps rather than the vault's buckets: at every payout, the payouts of that index in the 24
    ///      hours up to it total at most 4% of its balance before them (`100 x out <= 4 x (after + out)`), or at most
    ///      the floor then in force.
    function invariant_V4_outflowOverAny24HoursIsWithinTheLimit() public view {
        uint256 n = handler.payoutCount();
        for (uint256 j = 0; j < n; ++j) {
            VaultHandler.Payout memory p = handler.payoutAt(j);
            uint256 out = 0;
            for (uint256 i = 0; i <= j; ++i) {
                VaultHandler.Payout memory q = handler.payoutAt(i);
                if (q.index == p.index && q.time + 24 hours > p.time) out += q.amount;
            }
            assertTrue(
                100 * out <= 4 * (p.balanceAfter + out) || out <= p.floor, "more than the limit left within 24 hours"
            );
        }
    }

    /// @dev V5: every digest is the hash of the public state it covers.
    function invariant_V5_digestsAreTheHashOfTheState() public view {
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(vault.indexDigest(indexes[i]), _indexDigest(indexes[i]), "an index digest is stale");
        }
        for (uint256 i = 0; i < handler.intakeCount(); ++i) {
            (address index, uint256 id) = handler.intakes(i);
            assertEq(vault.intakeDigest(index, id), _intakeDigest(index, id), "an intake digest is stale");
        }
    }

    function _indexDigest(address index) internal view returns (bytes32) {
        address[] memory tokens = vault.indexTokens(index);
        uint256[] memory balances = new uint256[](tokens.length);
        uint256[] memory paid = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            balances[i] = vault.balance(index, tokens[i]);
            paid[i] = vault.paidTotal(index, tokens[i]);
        }
        return keccak256(
            abi.encode(
                keccak256("xindex.v4.vault.index-digest"), block.chainid, address(vault), index, tokens, balances, paid
            )
        );
    }

    function _intakeDigest(address index, uint256 id) internal view returns (bytes32) {
        address[] memory tokens = vault.intakeTokens(index, id);
        uint256[] memory totals = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            totals[i] = vault.intakeTotal(index, id, tokens[i]);
        }
        return keccak256(
            abi.encode(
                keccak256("xindex.v4.vault.intake-digest"),
                block.chainid,
                address(vault),
                index,
                id,
                vault.intakeState(index, id),
                tokens,
                totals
            )
        );
    }

    function _burnId(uint256 k) internal view returns (bytes32 id) {
        (, id,,) = handler.burns(k);
    }

    /// @dev The campaign reaches every path the invariants are about.
    function test_handlerReachesEveryPath() public {
        handler.deposit(0, 0, 50 ether, 1 days, true);
        handler.deposit(1, 0, 10 ether, 0, false);
        handler.deposit(2, 1, 5 ether, 1 days, true);
        handler.deposit(1, 0, 1 ether, 1 hours, true); // stays open past its deadline
        handler.settle(0);
        handler.fail(1);
        handler.refund(1, 2);
        handler.refund(1, 2); // nothing left: skipped
        handler.burn(0, 5 ether, 0); // above 4% of 60: 2.4 paid, the rest owed
        handler.release(0); // nothing available yet: skipped
        handler.warp(1); // to the hour's last second
        handler.warp(2); // the hour 24 later: still inside the window
        handler.release(0); // skipped
        handler.warp(3); // days later
        handler.release(0);
        handler.deposit(0, 2, 1 ether, 0, false); // past the open intake's deadline: skipped
        handler.migrate(0, 3 ether);
        handler.setCaps(400 ether, 2 ether);
        handler.replay(0);
        handler.sendStray(1 ether);
        handler.freeze(0);
        handler.deposit(0, 0, 1 ether, 1 days, true); // frozen: skipped
        handler.burn(1, 1 ether, 1); // accepted, owed
        handler.warp(15 days - 1); // past the freeze (a seed of 3 mod 4 moves the clock by days)
        handler.release(1); // the migration: part of it moves
        handler.release(1); // nothing more available yet: skipped
        handler.warp(2 days + 3); // two days later (a seed of 3 mod 4), past the 25-hour window
        handler.release(1); // the rest, within the limit
        assertEq(vault.owed(indexes[0], _burnId(1)).remaining, 0);
        handler.release(1); // moved in full: skipped
        invariant_V1_theVaultHoldsWhatItOwes();
        invariant_V2_aMessagePaysAtMostOnce();
        invariant_V3_aBurnPaysAtMostItsIndexsBalance();
        invariant_V4_outflowOverAny24HoursIsWithinTheLimit();
        invariant_V5_digestsAreTheHashOfTheState();
        assertEq(handler.settles(), 1);
        assertEq(handler.fails(), 1);
        assertEq(handler.refunds(), 1);
        assertEq(handler.releases(), 3);
        assertEq(handler.migrations(), 1);
        assertEq(handler.capUpdates(), 1);
        assertEq(handler.freezes(), 1);
        assertGe(handler.payoutCount(), 3);
    }
}
