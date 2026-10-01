// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {HybridHub} from "../src/HybridHub.sol";
import {HybridIndexFactory} from "../src/HybridIndexFactory.sol";
import {IHybridHubTypes} from "../src/interfaces/IHybridHubTypes.sol";
import {IHybridIndex} from "../src/interfaces/IHybridIndex.sol";
import {XindexVault} from "../src/vault/XindexVault.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IEthereumEventVerifier} from "../src/interfaces/IEthereumEventVerifier.sol";
import {HybridTest} from "./HybridTest.sol";

/// @notice Drives orders from every state, deposits short or whole, settlements, claims, failures, voids on forged
///         proofs, factory freezes and re-confirmations, redemptions with and without recipients, claims on both chains,
///         migrations to a next version, and the clock, making only calls that must succeed. Every message the hub or factory emits is delivered to the
///         vault at once, as P1 and P2 would, so the vault's books can be read against the hub's.
contract HybridHandler is Test {
    IHybridIndex public immutable HUB;
    /// @notice A next version of the same tokens at half the units, which holders migrate to.
    IHybridIndex public immutable NEXT;
    HybridIndexFactory public immutable FACTORY;
    XindexVault public immutable VAULT;
    MockERC20 public immutable WETH;
    address public immutable NATIVE;
    address public immutable GUARDIAN;
    address public immutable OWNER;
    uint256 public immutable CHAIN_ID;
    address[3] internal _actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2")];

    uint256[] public orders;
    uint256 public claims;
    uint256 public fails;
    uint256 public voids;
    uint256 public freezes;
    uint256 public reconfirms;
    uint256 public burns;
    uint256 public fills;
    uint256 public fillFails;
    uint256 public slashes;
    uint256 public bondReleases;
    uint256 public migrations;
    /// @notice Every BURN and MIGRATE the hub sent the vault, whose owed remainder the vault holds beyond its book.
    bytes32[] public burnIds;
    /// @notice The MIGRATEs among them, whose remainder the next version's book counts before the vault moves it.
    bytes32[] public migrationIds;

    constructor(
        IHybridIndex hub,
        IHybridIndex next,
        HybridIndexFactory factory,
        XindexVault vault,
        MockERC20 weth,
        address guardian,
        address owner
    ) {
        HUB = hub;
        NEXT = next;
        FACTORY = factory;
        VAULT = vault;
        WETH = weth;
        NATIVE = factory.vaultTokenId(block.chainid, bytes32(0));
        GUARDIAN = guardian;
        OWNER = owner;
        CHAIN_ID = block.chainid;
    }

    function _deliver() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != VaultMessages.EVENT_TOPIC) continue;
            bytes memory proof = abi.encode(logs[i].emitter, logs[i].topics[0], logs[i].topics[1], logs[i].data);
            VAULT.deliver(proof, proof);
            VaultMessages.Message memory m = VaultMessages.decode(abi.decode(logs[i].data, (bytes)));
            if (m.kind == VaultMessages.BURN || m.kind == VaultMessages.MIGRATE) burnIds.push(logs[i].topics[1]);
            if (m.kind == VaultMessages.MIGRATE) migrationIds.push(logs[i].topics[1]);
        }
    }

    function _frozen() internal view returns (bool) {
        (, uint256 until) = HUB.chainFreeze(CHAIN_ID);
        return block.timestamp < until;
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

    /// @dev Whether `who` may seed `idx`: it is empty, with nothing locked, and `who` created it.
    function _seedable(IHybridIndex idx, address who) internal view returns (bool) {
        if (idx.totalSupply() != 0 || who != FACTORY.creatorOf(address(idx))) return false;
        if (idx != HUB) return true; // the next version takes no orders
        for (uint256 i = 0; i < orders.length; ++i) {
            if (HUB.order(orders[i]).status == IHybridHubTypes.OrderStatus.Locked) return false;
        }
        return true;
    }

    function _order(uint256 pick) internal view returns (uint256 id, IHybridHubTypes.Order memory o) {
        id = orders[pick % orders.length];
        o = HUB.order(id);
    }

    function _proof(uint256 time) internal pure returns (bytes memory) {
        return abi.encode(time, false, bytes32(0));
    }

    // ---------------------------------------------------------------------
    // actions
    // ---------------------------------------------------------------------

    /// @notice Opens an order and deposits it on the vault chain, in full or one wei short.
    function open(uint256 who, uint256 shares, bool short) external {
        if (_frozen()) return;
        shares = bound(shares, 1e15, 5e18);
        address minter = _actors[who % 3];
        uint256[] memory amounts = HUB.previewOrder(shares);
        WETH.mint(minter, amounts[0]);
        vm.startPrank(minter);
        WETH.approve(address(HUB), amounts[0]);
        (uint256 id, uint256 intakeId) = HUB.openOrder(shares, block.timestamp + 1 hours);
        uint256 deposit = short ? amounts[1] - 1 : amounts[1];
        vm.deal(minter, deposit);
        _fresh();
        VAULT.deposit{value: deposit}(address(HUB), intakeId);
        vm.stopPrank();
        orders.push(id);
    }

    function settle(uint256 pick) external {
        if (orders.length == 0 || _frozen()) return;
        (uint256 id, IHybridIndexFactory_Order memory o) = _orderView(pick);
        if (o.status != IHybridHubTypes.OrderStatus.Open || block.timestamp <= o.deadline) return;
        uint256 intakeId = HUB.intakeIdOf(id);
        uint256 deposited = VAULT.intakeTotal(address(HUB), intakeId, address(0));
        if (deposited < HUB.previewOrder(o.shares)[1]) return;
        if (o.shares > HUB.mintRoom() && !_seedable(HUB, o.minter)) return;
        IHybridHubTypes.ChainProof[] memory p = new IHybridHubTypes.ChainProof[](1);
        p[0].proof = _proof(block.timestamp);
        p[0].tokens = new address[](1);
        p[0].totals = new uint256[](1);
        p[0].totals[0] = deposited;
        HUB.settleOrder(id, p);
    }

    function claim(uint256 pick) external {
        if (orders.length == 0) return;
        (uint256 id, IHybridIndexFactory_Order memory o) = _orderView(pick);
        // Mint claims also wait while a fill is accepted.
        if (
            o.status != IHybridHubTypes.OrderStatus.Locked || block.timestamp < o.lockEnds || _frozen()
                || HUB.fill().status == IHybridHubTypes.FillStatus.Accepted
        ) return;
        (uint256 start,) = HUB.chainFreeze(CHAIN_ID);
        if (start >= o.settledAt) return; // needs re-confirming first
        vm.recordLogs();
        HUB.claimOrder(id);
        _deliver();
        ++claims;
    }

    function fail(uint256 pick) external {
        if (orders.length == 0) return;
        (uint256 id, IHybridIndexFactory_Order memory o) = _orderView(pick);
        if (o.status != IHybridHubTypes.OrderStatus.Open) return;
        vm.recordLogs();
        vm.prank(o.minter); // the minter may fail an open order at any time
        HUB.failOrder(id);
        _deliver();
        ++fails;
    }

    /// @notice A forged proof contradicting a locked order's intake.
    function forge(uint256 pick) external {
        if (orders.length == 0) return;
        (uint256 id, IHybridIndexFactory_Order memory o) = _orderView(pick);
        if (o.status != IHybridHubTypes.OrderStatus.Locked) return;
        vm.recordLogs();
        HUB.voidOrder(id, CHAIN_ID, abi.encode(block.timestamp, true, keccak256(abi.encode(id))));
        _deliver();
        ++voids;
    }

    function freeze(uint256 seed) external {
        if (seed % 6 != 0) return;
        vm.recordLogs();
        vm.prank(GUARDIAN);
        FACTORY.freezeChain(CHAIN_ID);
        _deliver();
        ++freezes;
    }

    function reconfirm(uint256 pick) external {
        (, uint256 until) = HUB.chainFreeze(CHAIN_ID);
        // A re-confirming proof must be from after the freeze ended.
        if (orders.length == 0 || block.timestamp <= until) return;
        (uint256 id, IHybridIndexFactory_Order memory o) = _orderView(pick);
        if (o.status != IHybridHubTypes.OrderStatus.Locked) return;
        bytes[] memory p = new bytes[](1);
        p[0] = _proof(block.timestamp);
        HUB.reconfirmOrder(id, p);
        ++reconfirms;
    }

    /// @notice A holder redeems: to a recipient on the vault chain, or booking the vault part as a claim.
    function redeem(uint256 who, uint256 amount, bool withRecipient, bool skipWeth) external {
        address holder = _actors[who % 3];
        uint256 balance = HUB.balanceOf(holder);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        bytes32[] memory r = new bytes32[](1);
        r[0] = withRecipient ? bytes32(uint256(uint160(makeAddr("vault chain recipient")))) : bytes32(0);
        vm.recordLogs();
        vm.prank(holder);
        HUB.redeem(amount, holder, r, skipWeth ? 1 : 0);
        _deliver();
        ++burns;
    }

    /// @notice A holder moves shares to the next version, one new share for each old one: at half the units, the old
    ///         shares cover both components, and the rest goes to the holder, or a claim, as a redemption's would.
    function migrate(uint256 who, uint256 amount, bool withRecipient) external {
        if (_frozen()) return;
        address holder = _actors[who % 3];
        uint256 balance = HUB.balanceOf(holder);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        if (amount > NEXT.mintRoom() && !_seedable(NEXT, holder)) return;
        bytes32[] memory r = new bytes32[](1);
        r[0] = withRecipient ? bytes32(uint256(uint160(makeAddr("vault chain recipient")))) : bytes32(0);
        vm.recordLogs();
        vm.prank(holder);
        HUB.migrate(address(NEXT), amount, amount, holder, r);
        _deliver();
        ++migrations;
    }

    function claimBoth(uint256 who) external {
        address holder = _actors[who % 3];
        vm.startPrank(holder);
        if (HUB.claimOf(holder, address(WETH)) != 0) HUB.claim(address(WETH), holder);
        vm.recordLogs();
        if (HUB.claimOf(holder, NATIVE) != 0) HUB.claimToVault(NATIVE, bytes32(uint256(uint160(holder))));
        vm.stopPrank();
        _deliver();
    }

    /// @notice Pays what the vault's speed limit and freeze now allow of an owed burn.
    function releaseOwed(uint256 pick) external {
        if (burnIds.length == 0 || block.timestamp < VAULT.frozenUntil()) return;
        bytes32 id = burnIds[pick % burnIds.length];
        if (VAULT.owed(address(HUB), id).remaining == 0 || VAULT.available(address(HUB), address(0)) == 0) return;
        VAULT.release(address(HUB), id);
    }

    // ---------------------------------------------------------------------
    // the rebalance
    // ---------------------------------------------------------------------

    /// @notice The owner moves one supply half a percent up, in a batch, when the factory's pace allows.
    function revise(bool nativeUp) external {
        if (FACTORY.suppliesPending()) return;
        address token = nativeUp ? NATIVE : address(WETH);
        uint256 supply = FACTORY.referenceSupply(token);
        address[] memory tokens = new address[](1);
        uint256[] memory supplies = new uint256[](1);
        (tokens[0], supplies[0]) = (token, supply + supply / 200);
        vm.prank(OWNER);
        FACTORY.proposeSupplies(tokens, supplies);
    }

    function executeRevision() external {
        (, uint256 eta,,) = FACTORY.pendingSupplies();
        if (eta == 0 || block.timestamp < eta || block.timestamp > eta + 7 days) return;
        FACTORY.executeSupplies();
    }

    function startFill() external {
        if (!HUB.canStartRebalance()) return;
        (, uint256 low, uint256 high) = HUB.previewBand(0);
        if (high * 1e18 < low * (1e18 + 0.001e18)) return;
        HUB.startRebalance(0);
    }

    /// @notice A holder with shares for the bond takes the auction.
    function accept(uint256 who) external {
        (uint256 eta,,,,) = HUB.pendingRebalance();
        address executor = _actors[who % 3];
        // A settled fill's hold is always over by the next auction, so only a live acceptance stands in the way.
        if (
            eta == 0 || block.timestamp < eta || block.timestamp > eta + 24 hours || _frozen()
                || HUB.fill().status == IHybridHubTypes.FillStatus.Accepted
                || HUB.balanceOf(executor) < (HUB.totalSupply() + 999) / 1000
        ) return;
        (,,, uint256[] memory amountsIn) = HUB.previewRebalance();
        WETH.mint(executor, amountsIn[0]);
        bytes32[] memory r = new bytes32[](1);
        r[0] = bytes32(uint256(uint160(executor)));
        vm.startPrank(executor);
        WETH.approve(address(HUB), amountsIn[0]);
        HUB.acceptRebalance(r, new uint256[](0));
        vm.stopPrank();
        ++fills;
    }

    /// @notice The executor deposits its vault delivery, in full or a wei short.
    function deliverFill(bool short) external {
        IHybridHubTypes.Fill memory f = HUB.fill();
        (, uint256[] memory deliveries,) = HUB.fillAmounts();
        uint256 intakeId = HUB.fillIntakeId();
        uint256 amount = deliveries.length == 0 ? 0 : (short ? deliveries[1] - 1 : deliveries[1]);
        if (
            f.status != IHybridHubTypes.FillStatus.Accepted || block.timestamp > f.deadline
                || block.timestamp < VAULT.frozenUntil() || amount == 0
                || VAULT.intakeTotal(address(HUB), intakeId, address(0)) != 0
        ) return;
        vm.deal(f.executor, amount);
        _fresh();
        vm.prank(f.executor);
        VAULT.deposit{value: amount}(address(HUB), intakeId);
    }

    function settleFill() external {
        IHybridHubTypes.Fill memory f = HUB.fill();
        if (f.status != IHybridHubTypes.FillStatus.Accepted) return;
        (, uint256[] memory deliveries,) = HUB.fillAmounts();
        uint256 deposited = VAULT.intakeTotal(address(HUB), HUB.fillIntakeId(), address(0));
        // What the fill needs now is at most what it needed at acceptance; a full delivery always covers it.
        if (deposited < deliveries[1]) return;
        IHybridHubTypes.ChainProof[] memory p = new IHybridHubTypes.ChainProof[](1);
        p[0].proof = _proof(block.timestamp);
        p[0].tokens = new address[](1);
        p[0].totals = new uint256[](1);
        p[0].totals[0] = deposited;
        vm.recordLogs();
        HUB.settleRebalance(p);
        _deliver();
    }

    function failFill() external {
        IHybridHubTypes.Fill memory f = HUB.fill();
        if (f.status != IHybridHubTypes.FillStatus.Accepted) return;
        vm.recordLogs();
        vm.prank(f.executor); // the executor may abandon its fill at any time, and pays its bond for it
        HUB.failRebalance();
        _deliver();
        ++fillFails;
    }

    function releaseFillBond() external {
        IHybridHubTypes.Fill memory f = HUB.fill();
        if (f.status != IHybridHubTypes.FillStatus.Settled || block.timestamp < f.bondRelease) return;
        HUB.releaseBond();
        ++bondReleases;
    }

    /// @notice A forged proof that a settled fill's delivery intake never existed.
    function slashFill() external {
        IHybridHubTypes.Fill memory f = HUB.fill();
        if (f.status != IHybridHubTypes.FillStatus.Settled || block.timestamp >= f.bondRelease) return;
        // Evidence is proven after the delivery deadline, which lies well inside the bond's hold.
        if (block.timestamp <= f.deadline) vm.warp(f.deadline + 1);
        // A forged state no honest vault shows: the delivery intake failed.
        IHybridHubTypes.ChainProof memory p;
        p.tokens = new address[](0);
        p.totals = new uint256[](0);
        bytes32 failed = keccak256(
            abi.encode(
                keccak256("xindex.v4.vault.intake-digest"),
                CHAIN_ID,
                address(VAULT),
                address(HUB),
                HUB.fillIntakeId(),
                uint8(3),
                p.tokens,
                p.totals
            )
        );
        p.proof = abi.encode(block.timestamp, true, failed);
        HUB.slashRebalance(CHAIN_ID, 3, p);
        ++slashes;
    }

    function warp(uint256 seed) external {
        uint256 mode = seed % 3;
        if (mode == 0) vm.warp(block.timestamp + bound(seed, 1, 2 hours));
        else if (mode == 1) vm.warp(block.timestamp + bound(seed, 1 days, 2 days));
        else vm.warp(block.timestamp + bound(seed, 14 days, 15 days));
    }

    // ---------------------------------------------------------------------
    // views
    // ---------------------------------------------------------------------

    struct IHybridIndexFactory_Order {
        address minter;
        uint256 shares;
        uint256 deadline;
        uint256 lockEnds;
        uint256 settledAt;
        IHybridHubTypes.OrderStatus status;
    }

    function _orderView(uint256 pick) internal view returns (uint256 id, IHybridIndexFactory_Order memory v) {
        IHybridHubTypes.Order memory o;
        (id, o) = _order(pick);
        v = IHybridIndexFactory_Order(o.minter, o.shares, o.deadline, o.lockEnds, o.settledAt, o.status);
    }

    function orderCount() external view returns (uint256) {
        return orders.length;
    }

    function burnCount() external view returns (uint256) {
        return burnIds.length;
    }

    function migrationCount() external view returns (uint256) {
        return migrationIds.length;
    }
}

/// @notice Whatever orders, holders, forgers, the guardian and the clock do: the Ethereum escrow and backing are held in
///         full, the hub's book of the vault is backed, the vault's real balance is exactly the hub's book, and every
///         order's escrow is accounted for by its status.
contract HybridHubInvariantTest is HybridTest {
    IHybridIndex hub;
    IHybridIndex next;
    HybridHandler handler;

    function setUp() public {
        _deployStageB();
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(weth), native);
        // The handler's actors a0 and a1 create the index and its next version: their first order and migration seed them.
        vm.prank(makeAddr("a0"));
        hub = IHybridIndex(factory.createIndex("Hybrid", "HYB", tokens, K));
        vault.registerIndex(address(hub), factory.indexSalt(address(hub)));
        vm.prank(makeAddr("a1"));
        next = IHybridIndex(factory.createIndex("Next", "NXT", tokens, K / 2));
        vault.registerIndex(address(next), factory.indexSalt(address(next)));
        handler = new HybridHandler(hub, next, factory, vault, weth, guardian, owner);
        targetContract(address(handler));
    }

    function invariant_theEthereumComponentIsBacked() public view {
        (, uint256[] memory units,,) = hub.components();
        assertGe(
            weth.balanceOf(address(hub)),
            hub.totalSupply() * units[0] / 1e18 + hub.totalClaims(address(weth)) + hub.escrowed(address(weth))
        );
    }

    function invariant_theVaultComponentIsBacked() public view {
        (, uint256[] memory units,,) = hub.components();
        assertGe(hub.vaultBacking(native), hub.totalSupply() * units[1] / 1e18 + hub.totalClaims(native));
    }

    /// @dev Every message is delivered at once, so the vault holds for the index exactly the hub's book, deposits of
    ///      claimed orders and settled fills less every amount burned, plus what it still owes of burns a freeze or its
    ///      speed limit held back.
    function invariant_theVaultAgreesWithTheBook() public view {
        uint256 owed = 0;
        for (uint256 i = 0; i < handler.burnCount(); ++i) {
            owed += vault.owed(address(hub), handler.burnIds(i)).remaining;
        }
        assertEq(vault.balance(address(hub), address(0)), hub.vaultBacking(native) + owed);
    }

    /// @dev The next version's book counts every migration in at once; the vault moves it within its speed limit, so
    ///      its balance plus what it still owes of those migrations is the book exactly.
    function invariant_theNextVersionAgreesWithTheBook() public view {
        uint256 moving = 0;
        for (uint256 i = 0; i < handler.migrationCount(); ++i) {
            moving += vault.owed(address(hub), handler.migrationIds(i)).remaining;
        }
        assertEq(vault.balance(address(next), address(0)) + moving, next.vaultBacking(native));
    }

    /// @dev The next version is backed on both chains, as the first is.
    function invariant_theNextVersionIsBacked() public view {
        (, uint256[] memory units,,) = next.components();
        uint256 supply = next.totalSupply();
        assertGe(weth.balanceOf(address(next)), supply * units[0] / 1e18 + next.totalClaims(address(weth)));
        assertGe(next.vaultBacking(native), supply * units[1] / 1e18 + next.totalClaims(native));
    }

    /// @dev No vault record ever shows an index paid out more than it sent: the evidence of `reportOutflow` never
    ///      fires on honest traffic.
    function invariant_noVaultPaysMoreThanWasSent() public view {
        assertLe(vault.paidTotal(address(hub), address(0)), hub.sentOut(native));
        assertLe(vault.paidTotal(address(next), address(0)), next.sentOut(native));
    }

    /// @dev An order's intake is marked settled, for a snapshot exit to read, exactly when the order was claimed.
    function invariant_settledMarksFollowTheOrders() public view {
        for (uint256 i = 0; i < handler.orderCount(); ++i) {
            uint256 id = handler.orders(i);
            bool claimed = hub.order(id).status == IHybridHubTypes.OrderStatus.Claimed;
            assertEq(hub.intakeSettled(hub.intakeIdOf(id)), claimed);
        }
    }

    /// @dev The index holds of its own shares exactly a live fill's bond, accepted or held after settlement.
    function invariant_theIndexHoldsOnlyTheBond() public view {
        IHybridHubTypes.Fill memory f = hub.fill();
        uint256 bond = f.status == IHybridHubTypes.FillStatus.None ? 0 : f.bond;
        assertEq(hub.balanceOf(address(hub)), bond);
    }

    /// @dev The escrow is exactly the Ethereum amounts of orders still open or locked and of a fill still accepted; the
    ///      rest were claimed or settled into the backing, or returned as claims.
    function invariant_escrowFollowsTheOrders() public view {
        uint256 open = 0;
        if (hub.fill().status == IHybridHubTypes.FillStatus.Accepted) {
            (, uint256[] memory deliveries,) = hub.fillAmounts();
            open += deliveries[0];
        }
        for (uint256 i = 0; i < handler.orderCount(); ++i) {
            uint256 id = handler.orders(i);
            IHybridHubTypes.OrderStatus s = hub.order(id).status;
            if (s == IHybridHubTypes.OrderStatus.Open || s == IHybridHubTypes.OrderStatus.Locked) {
                (uint256[] memory amounts,) = hub.orderAmounts(id);
                open += amounts[0];
            }
        }
        assertEq(hub.escrowed(address(weth)), open);
    }

    /// @dev A supply revision through its batch, then a rebalance started and its auction live.
    function _cycle(bool nativeUp) internal {
        handler.revise(nativeUp);
        (, uint256 eta,,) = factory.pendingSupplies();
        vm.warp(eta);
        handler.executeRevision();
        uint256 earliest = hub.lastRebalance() + 7 days;
        if (block.timestamp < earliest) vm.warp(earliest);
        handler.startFill();
        (uint256 auction,,,,) = hub.pendingRebalance();
        vm.warp(auction + 12 hours);
    }

    /// @dev The campaign reaches every path the invariants are about.
    /// @dev While the creator's seed is locked, the supply is still zero and its next order waits: the handler skips it.
    function test_handlerWaitsOnALockedSeed() public {
        handler.open(0, 2e18, false); // order 1: a0's seed
        handler.open(0, 1e18, false); // order 2: a0's too
        handler.warp(7200);
        handler.settle(0);
        handler.settle(1); // skipped, not reverted
        assertEq(uint256(hub.order(1).status), uint256(IHybridHubTypes.OrderStatus.Locked));
        assertEq(uint256(hub.order(2).status), uint256(IHybridHubTypes.OrderStatus.Open));
    }

    function test_handlerReachesEveryPath() public {
        handler.open(0, 2e18, false); // order 1: the seed
        handler.open(1, 1e18, true); // order 2: one wei short, never settles
        handler.open(2, 1e18, false); // order 3
        handler.warp(7200); // two hours on
        handler.settle(0);
        handler.settle(1); // short: skipped
        handler.fail(1);
        handler.warp(86401); // a day on
        handler.claim(0);
        handler.redeem(0, 1e18, true, false);
        handler.redeem(0, 0.5e18, false, true);
        handler.claimBoth(0);
        handler.settle(2); // 1e18 is above 4% of the 0.5e18 left: skipped
        handler.fail(2);
        handler.open(0, 0.01e18, false); // order 4
        handler.warp(7200);
        handler.settle(3);
        handler.forge(3); // voided, and the chain's mints freeze for 14 days
        handler.warp(1209602);
        handler.open(1, 0.005e18, false); // order 5
        handler.warp(7200);
        handler.settle(4);
        handler.freeze(0); // the guardian freezes the chain in the second order 5 settled
        handler.reconfirm(4); // still frozen: skipped
        handler.warp(1209602);
        handler.claim(4); // needs a re-confirmation: skipped
        handler.reconfirm(4);
        handler.claim(4);
        // A burn held back by the freeze, paid once it ends.
        handler.freeze(0);
        handler.redeem(1, 0.001e18, true, false);
        handler.releaseOwed(handler.burnCount() - 1); // frozen: skipped
        vm.warp(block.timestamp + 14 days);
        handler.releaseOwed(handler.burnCount() - 1);
        assertEq(vault.owed(address(hub), handler.burnIds(handler.burnCount() - 1)).remaining, 0);
        handler.releaseOwed(handler.burnCount() - 1); // paid in full: skipped
        handler.migrate(2, 0, true); // no shares: skipped
        handler.migrate(1, 0.002e18, true); // a1 created the next version: its seed
        handler.migrate(1, 0.001e18, false); // above 4% of the next version's supply: skipped
        handler.warp(90_001); // 25 hours on: the seed has left the window
        handler.migrate(1, 0.00008e18, false);
        assertEq(next.totalSupply(), 0.00208e18);
        handler.freeze(0);
        handler.migrate(1, 0.001e18, true); // frozen: skipped
        vm.warp(block.timestamp + 14 days);

        // Three rebalance cycles: settled then slashed on a forged proof; settled with its bond released; abandoned.
        _cycle(true);
        handler.settleFill(); // nothing accepted: skipped
        handler.deliverFill(false); // nothing accepted: skipped
        handler.accept(0);
        handler.settleFill(); // not delivered: skipped
        handler.deliverFill(false);
        handler.deliverFill(false); // already delivered: skipped
        handler.settleFill();
        handler.slashFill();
        vm.warp(block.timestamp + 15 days);
        _cycle(false);
        handler.accept(2); // no shares for a bond: skipped
        handler.accept(0);
        handler.accept(0); // already accepted: skipped
        handler.claim(4); // mint claims wait for the fill: skipped
        handler.deliverFill(false); // native is sold: nothing to deliver
        handler.settleFill();
        handler.releaseFillBond(); // in its hold: skipped
        vm.warp(block.timestamp + 1 days);
        handler.releaseFillBond();
        _cycle(true);
        handler.accept(0);
        handler.failFill();
        assertEq(handler.fills(), 3);
        assertEq(handler.slashes(), 1);
        assertEq(handler.bondReleases(), 1);
        assertEq(handler.fillFails(), 1);
        assertEq(handler.claims(), 2);
        assertEq(handler.fails(), 2);
        assertEq(handler.voids(), 1);
        assertEq(handler.reconfirms(), 1);
        assertEq(handler.burns(), 3);
        assertEq(handler.migrations(), 2);
        assertEq(handler.freezes(), 3);
        invariant_theEthereumComponentIsBacked();
        invariant_theVaultComponentIsBacked();
        invariant_theVaultAgreesWithTheBook();
        invariant_escrowFollowsTheOrders();
        invariant_theNextVersionAgreesWithTheBook();
        invariant_theNextVersionIsBacked();
        invariant_noVaultPaysMoreThanWasSent();
        invariant_settledMarksFollowTheOrders();
    }
}
