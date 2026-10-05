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
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Drives deposits, settled and failed intakes, refunds, burns, releases, migrations, cap changes, freezes,
///         replays, stray coins and the clock in any order, on the native coin and a token alike, making only calls
///         that must succeed, and records every payout where it landed so the invariants check the vault against what
///         actually moved.
contract VaultHandler is Test {
    XindexVault public immutable VAULT;
    address public immutable FACTORY;
    address public immutable FREEZER;
    address[2] public indexes;
    /// @notice The coins every action picks from: the native coin (zero) and a token.
    address[2] public coins;
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
        address coin;
        uint256 time;
        uint256 amount;
        uint256 balanceAfter;
        uint256 floor;
    }

    Intake[] public intakes;
    Burn[] public burns;
    Payout[] public payouts;
    bytes[] internal _delivered;

    /// @notice What each index was credited of each coin: settled intakes, and migrations in as they were paid.
    mapping(address index => mapping(address coin => uint256)) public credited;
    /// @notice What each index paid out of each coin, burns and migrations alike, measured where it landed.
    mapping(address index => mapping(address coin => uint256)) public paidOut;
    /// @notice Coins sent to the vault outside any deposit.
    mapping(address coin => uint256) public stray;

    bool public replayed;
    bool public movedOtherThanPaid;
    uint256 public settles;
    uint256 public fails;
    uint256 public refunds;
    uint256 public releases;
    uint256 public migrations;
    uint256 public capUpdates;
    uint256 public freezes;
    /// @dev Past the token's first cap, which set-up sends at nonce 1.
    uint256 internal _nonce = 1;

    constructor(XindexVault vault, address factory, address freezer, address[2] memory indexes_, address token) {
        VAULT = vault;
        FACTORY = factory;
        FREEZER = freezer;
        indexes = indexes_;
        coins[1] = token;
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
    function _record(address index, address coin, uint256 paid, uint256 balanceBefore) internal {
        uint256 balanceAfter = VAULT.balance(index, coin);
        movedOtherThanPaid = movedOtherThanPaid || balanceBefore - balanceAfter != paid;
        if (paid == 0) return;
        paidOut[index][coin] += paid;
        payouts.push(Payout(index, coin, block.timestamp, paid, balanceAfter, VAULT.outflowFloor(coin)));
    }

    /// @dev What `account` holds of `coin` outside the vault's books.
    function _holding(address coin, address account) internal view returns (uint256) {
        return coin == address(0) ? account.balance : MockERC20(coin).balanceOf(account);
    }

    // ---------------------------------------------------------------------
    // actions
    // ---------------------------------------------------------------------

    /// @notice A deposit into a new intake, or into an open one whose deadline has not passed.
    function deposit(uint256 who, uint256 pick, uint256 amount, uint256 life, bool fresh, uint256 c) external {
        if (_frozen()) return;
        address coin = coins[c % 2];
        amount = bound(amount, 1, 50 ether);
        if (VAULT.held(coin) + amount > VAULT.cap(coin)) return;
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
        _fresh();
        if (coin == address(0)) {
            vm.deal(depositor, amount);
            vm.prank(depositor);
            VAULT.deposit{value: amount}(index, id);
        } else {
            MockERC20(coin).mint(depositor, amount);
            vm.startPrank(depositor);
            MockERC20(coin).approve(address(VAULT), amount);
            VAULT.depositToken(index, id, coin, amount);
            vm.stopPrank();
        }
    }

    function settle(uint256 pick) external {
        if (intakes.length == 0) return;
        Intake memory it = intakes[pick % intakes.length];
        if (VAULT.intakeState(it.index, it.id) != IXindexVault.IntakeState.Open) return;
        for (uint256 c = 0; c < 2; ++c) {
            credited[it.index][coins[c]] += VAULT.intakeTotal(it.index, it.id, coins[c]);
        }
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

    function refund(uint256 pick, uint256 who, uint256 c) external {
        if (intakes.length == 0 || _frozen()) return;
        Intake memory it = intakes[pick % intakes.length];
        if (VAULT.intakeState(it.index, it.id) != IXindexVault.IntakeState.Failed) return;
        address coin = coins[c % 2];
        address depositor = _actors[who % 3];
        uint256 amount = VAULT.deposited(it.index, it.id, coin, depositor);
        if (amount == 0) return;
        uint256 before = _holding(coin, depositor);
        vm.prank(depositor);
        VAULT.refund(it.index, it.id, coin);
        movedOtherThanPaid = movedOtherThanPaid || _holding(coin, depositor) - before != amount;
        ++refunds;
    }

    /// @notice A burn proven from Ethereum: it pays what the limit allows now and owes the rest.
    function burn(uint256 pick, uint256 amount, uint256 to, uint256 c) external {
        address index = indexes[pick % 2];
        address coin = coins[c % 2];
        amount = bound(amount, 1, 20 ether);
        address recipient = _recipients[to % 3];
        uint256 before = _holding(coin, recipient);
        uint256 balanceBefore = VAULT.balance(index, coin);
        bytes32 id = _deliver(
            VaultMessages.BURN,
            index,
            abi.encode(bytes32(uint256(uint160(coin))), amount, bytes32(uint256(uint160(recipient))))
        );
        uint256 paid = _holding(coin, recipient) - before;
        burns.push(Burn(index, id, amount, paid));
        _record(index, coin, paid, balanceBefore);
    }

    function release(uint256 pick) external {
        if (burns.length == 0 || _frozen()) return;
        Burn storage b = burns[pick % burns.length];
        IXindexVault.Owed memory o = VAULT.owed(b.index, b.id);
        if (o.remaining == 0) return;
        if (VAULT.available(b.index, o.token) == 0 || VAULT.balance(b.index, o.token) == 0) return;
        uint256 before = _received(o);
        uint256 balanceBefore = VAULT.balance(b.index, o.token);
        VAULT.release(b.index, b.id);
        uint256 paid = _received(o) - before;
        b.paid += paid;
        if (o.toIndex) credited[o.recipient][o.token] += paid;
        _record(b.index, o.token, paid, balanceBefore);
        ++releases;
    }

    /// @dev What an owed payout's recipient holds: a burn's recipient's coins, or a migration's new index's balance.
    function _received(IXindexVault.Owed memory o) internal view returns (uint256) {
        return o.toIndex ? VAULT.balance(o.recipient, o.token) : _holding(o.token, o.recipient);
    }

    /// @notice A migration proven from Ethereum: like a burn, it moves what the limit allows now and owes the rest,
    ///         frozen or not.
    function migrate(uint256 pick, uint256 amount, uint256 c) external {
        (address from, address to) = pick % 2 == 0 ? (indexes[0], indexes[1]) : (indexes[1], indexes[0]);
        address coin = coins[c % 2];
        amount = bound(amount, 1, 20 ether);
        uint256 before = VAULT.balance(to, coin);
        uint256 balanceBefore = VAULT.balance(from, coin);
        bytes32 id = _deliver(VaultMessages.MIGRATE, from, abi.encode(to, bytes32(uint256(uint160(coin))), amount));
        uint256 paid = VAULT.balance(to, coin) - before;
        burns.push(Burn(from, id, amount, paid));
        credited[to][coin] += paid;
        _record(from, coin, paid, balanceBefore);
        ++migrations;
    }

    /// @notice Raises or lowers a coin's cap and floor; a cap is never set below what the vault already holds. A raise
    ///         waits on the vault and is never applied here, so caps only fall.
    function setCaps(uint256 newCap, uint256 newFloor, uint256 c) external {
        address coin = coins[c % 2];
        newCap = bound(newCap, VAULT.held(coin), 1000 ether);
        newFloor = bound(newFloor, 0, 5 ether);
        _deliver(VaultMessages.CAP_UPDATE, FACTORY, abi.encode(bytes32(uint256(uint160(coin))), newCap, newFloor));
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

    function sendStray(uint256 amount, uint256 c) external {
        address coin = coins[c % 2];
        amount = bound(amount, 1, 5 ether);
        if (coin == address(0)) vm.deal(address(VAULT), address(VAULT).balance + amount);
        else MockERC20(coin).mint(address(VAULT), amount);
        stray[coin] += amount;
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

/// @notice V1 to V5 of the Stage B spec, whatever depositors, Ethereum's messages, the guardian and the clock do, for the
///         native coin and a token alike: the vault holds what it owes, a message pays at most once, a burn pays at
///         most its index's balance, outflow over any 24 real hours stays within the speed limit, and each digest is
///         the hash of what it covers.
contract XindexVaultInvariantTest is Test {
    XindexVault vault;
    VaultHandler handler;
    MockERC20 token;
    address[2] coins;
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
        token = new MockERC20("Binance-Peg XRP Token", "XRP", 18);
        coins[1] = address(token);
        _capToken(500 ether, 1 ether);
        handler = new VaultHandler(vault, factory, makeAddr("freezer"), indexes, address(token));
        targetContract(address(handler));
    }

    /// @dev The token's first cap, as the factory sends it: on both proofs, applied after GOVERNANCE_DELAY.
    function _capToken(uint256 cap, uint256 floor) internal {
        bytes memory body = abi.encode(bytes32(uint256(uint160(address(token)))), cap, floor);
        bytes memory payload = VaultMessages.encode(
            VaultMessages.Message({
                sourceChainId: 1,
                kind: VaultMessages.CAP_UPDATE,
                destChainId: block.chainid,
                vault: bytes32(uint256(uint160(address(vault)))),
                index: factory,
                nonce: 1,
                body: body
            })
        );
        bytes memory proof = abi.encode(factory, VaultMessages.EVENT_TOPIC, keccak256(payload), abi.encode(payload));
        vault.deliver(proof, proof);
        vm.warp(block.timestamp + vault.GOVERNANCE_DELAY());
        vault.applyChange(VaultMessages.CAP_UPDATE, body, block.timestamp);
    }

    /// @dev What the vault holds of `coin`, books aside.
    function _held(address coin) internal view returns (uint256) {
        return coin == address(0) ? address(vault).balance : token.balanceOf(address(vault));
    }

    /// @dev V1: the vault's coins are `held` plus stray coins, and `held` is every settled balance plus every open or
    ///      failed intake's unrefunded deposits.
    function invariant_V1_theVaultHoldsWhatItOwes() public view {
        for (uint256 c = 0; c < 2; ++c) {
            address coin = coins[c];
            assertEq(_held(coin), vault.held(coin) + handler.stray(coin), "coins drifted from held");
            uint256 owedTotal = vault.balance(indexes[0], coin) + vault.balance(indexes[1], coin);
            for (uint256 i = 0; i < handler.intakeCount(); ++i) {
                (address index, uint256 id) = handler.intakes(i);
                IXindexVault.IntakeState state = vault.intakeState(index, id);
                if (state == IXindexVault.IntakeState.Open || state == IXindexVault.IntakeState.Failed) {
                    owedTotal += vault.intakeTotal(index, id, coin);
                }
            }
            assertEq(vault.held(coin), owedTotal, "held is not the balances plus the pending deposits");
            assertLe(vault.held(coin), vault.cap(coin), "held above the cap");
        }
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
        for (uint256 i = 0; i < 4; ++i) {
            (address index, address coin) = (indexes[i % 2], coins[i / 2]);
            assertEq(vault.paidTotal(index, coin), handler.paidOut(index, coin), "paidTotal is not what was paid");
            assertEq(
                vault.balance(index, coin) + handler.paidOut(index, coin),
                handler.credited(index, coin),
                "an index paid out more than it was credited"
            );
        }
    }

    /// @dev V4, on real timestamps rather than the vault's buckets: at every payout, the payouts of that index and coin in
    ///      the 24 hours up to it total at most 4% of its balance before them (`100 x out <= 4 x (after + out)`), or at most
    ///      the floor then in force.
    function invariant_V4_outflowOverAny24HoursIsWithinTheLimit() public view {
        uint256 n = handler.payoutCount();
        for (uint256 j = 0; j < n; ++j) {
            VaultHandler.Payout memory p = handler.payoutAt(j);
            uint256 out = 0;
            for (uint256 i = 0; i <= j; ++i) {
                VaultHandler.Payout memory q = handler.payoutAt(i);
                if (q.index == p.index && q.coin == p.coin && q.time + 24 hours > p.time) out += q.amount;
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
        handler.deposit(0, 0, 50 ether, 1 days, true, 0);
        handler.deposit(1, 0, 10 ether, 0, false, 0);
        handler.deposit(2, 1, 5 ether, 1 days, true, 0);
        handler.deposit(1, 0, 1 ether, 1 hours, true, 0); // stays open past its deadline
        handler.settle(0);
        handler.fail(1);
        handler.refund(1, 2, 0);
        handler.refund(1, 2, 0); // nothing left: skipped
        handler.burn(0, 5 ether, 0, 0); // above 4% of 60: 2.4 paid, the rest owed
        handler.release(0); // nothing available yet: skipped
        handler.warp(1); // to the hour's last second
        handler.warp(2); // the hour 24 later: still inside the window
        handler.release(0); // skipped
        handler.warp(3); // days later
        handler.release(0);
        handler.deposit(0, 2, 1 ether, 0, false, 0); // past the open intake's deadline: skipped
        handler.migrate(0, 3 ether, 0);
        handler.setCaps(400 ether, 2 ether, 0);
        handler.replay(0);
        handler.sendStray(1 ether, 0);
        handler.freeze(0);
        handler.deposit(0, 0, 1 ether, 1 days, true, 0); // frozen: skipped
        handler.burn(1, 1 ether, 1, 0); // accepted, owed
        handler.warp(15 days - 1); // past the freeze (a seed of 3 mod 4 moves the clock by days)
        handler.release(1); // the migration: part of it moves
        handler.release(1); // nothing more available yet: skipped
        handler.warp(2 days + 3); // two days later (a seed of 3 mod 4), past the 25-hour window
        handler.release(1); // the rest, within the limit
        assertEq(vault.owed(indexes[0], _burnId(1)).remaining, 0);
        handler.release(1); // moved in full: skipped

        // The token, through every path the coin took.
        handler.deposit(0, 0, 30 ether, 1 days, true, 1); // intake 3, on the first index
        handler.deposit(1, 1, 4 ether, 1 days, true, 1); // intake 4, on the second
        handler.deposit(2, 4, 2 ether, 0, false, 0); // the coin beside it in intake 4
        handler.settle(3);
        handler.fail(4);
        handler.refund(4, 1, 1); // the token back to its depositor
        handler.refund(4, 2, 0); // the coin back, on its own
        handler.burn(0, 5 ether, 2, 1); // 4% of 30: 1.2 paid, the rest owed
        handler.migrate(0, 2 ether, 1); // nothing available yet: owed
        handler.warp(2 days + 3); // past the 25-hour window
        handler.release(handler.burnCount() - 2); // the burn's rest, within the limit
        handler.warp(2 days + 3);
        handler.release(handler.burnCount() - 1); // the migration
        handler.setCaps(400 ether, 0, 1);
        handler.sendStray(1 ether, 1);
        invariant_V1_theVaultHoldsWhatItOwes();
        invariant_V2_aMessagePaysAtMostOnce();
        invariant_V3_aBurnPaysAtMostItsIndexsBalance();
        invariant_V4_outflowOverAny24HoursIsWithinTheLimit();
        invariant_V5_digestsAreTheHashOfTheState();
        assertEq(handler.settles(), 2);
        assertEq(handler.fails(), 2);
        assertEq(handler.refunds(), 3);
        assertEq(handler.releases(), 5);
        assertEq(handler.migrations(), 2);
        assertEq(handler.capUpdates(), 2);
        assertEq(handler.freezes(), 1);
        assertGe(handler.payoutCount(), 6);
        assertGt(vault.paidTotal(indexes[0], address(token)), 0, "the token paid out");
        assertGt(vault.balance(indexes[1], address(token)), 0, "the token migrated");
    }
}
