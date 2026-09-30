// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {HybridHub} from "../src/HybridHub.sol";
import {HybridIndexFactory} from "../src/HybridIndexFactory.sol";
import {IHybridHub} from "../src/interfaces/IHybridHub.sol";
import {XindexVault} from "../src/vault/XindexVault.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HybridTest} from "./HybridTest.sol";

/// @notice Drives orders from every state, deposits short or whole, settlements, claims, failures, voids on forged
///         proofs, factory freezes and re-confirmations, redemptions with and without recipients, claims on both chains,
///         and the clock, making only calls that must succeed. Every message the hub or factory emits is delivered to the
///         vault at once, as P1 and P2 would, so the vault's books can be read against the hub's.
contract HybridHandler is Test {
    HybridHub public immutable HUB;
    HybridIndexFactory public immutable FACTORY;
    XindexVault public immutable VAULT;
    MockERC20 public immutable WETH;
    address public immutable NATIVE;
    address public immutable GUARDIAN;
    uint256 public immutable CHAIN_ID;
    address[3] internal _actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2")];

    uint256[] public orders;
    uint256 public claims;
    uint256 public fails;
    uint256 public voids;
    uint256 public freezes;
    uint256 public reconfirms;
    uint256 public burns;

    constructor(HybridHub hub, HybridIndexFactory factory, XindexVault vault, MockERC20 weth, address guardian) {
        HUB = hub;
        FACTORY = factory;
        VAULT = vault;
        WETH = weth;
        NATIVE = factory.vaultTokenId(block.chainid, bytes32(0));
        GUARDIAN = guardian;
        CHAIN_ID = block.chainid;
    }

    function _deliver() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != VaultMessages.EVENT_TOPIC) continue;
            bytes memory proof = abi.encode(logs[i].emitter, logs[i].topics[0], logs[i].topics[1], logs[i].data);
            VAULT.deliver(proof, proof);
        }
    }

    function _frozen() internal view returns (bool) {
        (, uint256 until) = HUB.chainFreeze(CHAIN_ID);
        return block.timestamp < until;
    }

    function _order(uint256 pick) internal view returns (uint256 id, IHybridHub.Order memory o) {
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
        VAULT.deposit{value: deposit}(address(HUB), intakeId);
        vm.stopPrank();
        orders.push(id);
    }

    function settle(uint256 pick) external {
        if (orders.length == 0 || _frozen()) return;
        (uint256 id, IHybridIndexFactory_Order memory o) = _orderView(pick);
        if (o.status != IHybridHub.OrderStatus.Open || block.timestamp <= o.deadline) return;
        uint256 intakeId = HUB.intakeIdOf(id);
        uint256 deposited = VAULT.intakeTotal(address(HUB), intakeId, address(0));
        if (deposited < HUB.previewOrder(o.shares)[1] || o.shares > HUB.mintRoom()) return;
        IHybridHub.ChainProof[] memory p = new IHybridHub.ChainProof[](1);
        p[0].proof = _proof(block.timestamp);
        p[0].tokens = new address[](1);
        p[0].totals = new uint256[](1);
        p[0].totals[0] = deposited;
        HUB.settleOrder(id, p);
    }

    function claim(uint256 pick) external {
        if (orders.length == 0) return;
        (uint256 id, IHybridIndexFactory_Order memory o) = _orderView(pick);
        if (o.status != IHybridHub.OrderStatus.Locked || block.timestamp < o.lockEnds || _frozen()) return;
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
        if (o.status != IHybridHub.OrderStatus.Open) return;
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
        if (o.status != IHybridHub.OrderStatus.Locked) return;
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
        if (o.status != IHybridHub.OrderStatus.Locked) return;
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

    function claimBoth(uint256 who) external {
        address holder = _actors[who % 3];
        vm.startPrank(holder);
        if (HUB.claimOf(holder, address(WETH)) != 0) HUB.claim(address(WETH), holder);
        vm.recordLogs();
        if (HUB.claimOf(holder, NATIVE) != 0) HUB.claimToVault(NATIVE, bytes32(uint256(uint160(holder))));
        vm.stopPrank();
        _deliver();
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
        IHybridHub.OrderStatus status;
    }

    function _orderView(uint256 pick) internal view returns (uint256 id, IHybridIndexFactory_Order memory v) {
        IHybridHub.Order memory o;
        (id, o) = _order(pick);
        v = IHybridIndexFactory_Order(o.minter, o.shares, o.deadline, o.lockEnds, o.settledAt, o.status);
    }

    function orderCount() external view returns (uint256) {
        return orders.length;
    }
}

/// @notice Whatever orders, holders, forgers, the guardian and the clock do: the Ethereum escrow and backing are held in
///         full, the hub's book of the vault is backed, the vault's real balance is exactly the hub's book, and every
///         order's escrow is accounted for by its status.
contract HybridHubInvariantTest is HybridTest {
    HybridHub hub;
    HybridHandler handler;

    function setUp() public {
        _deployStageB();
        hub = _createHybrid();
        handler = new HybridHandler(hub, factory, vault, weth, guardian);
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

    /// @dev Every message delivered at once and every burn paid in full: the vault holds for the index exactly the hub's
    ///      book, deposits of claimed orders less every amount burned.
    function invariant_theVaultAgreesWithTheBook() public view {
        assertEq(vault.balance(address(hub), address(0)), hub.vaultBacking(native));
    }

    /// @dev The escrow is exactly the Ethereum amounts of orders still open or locked; the rest were claimed into the
    ///      backing or returned as claims.
    function invariant_escrowFollowsTheOrders() public view {
        uint256 open = 0;
        for (uint256 i = 0; i < handler.orderCount(); ++i) {
            uint256 id = handler.orders(i);
            IHybridHub.OrderStatus s = hub.order(id).status;
            if (s == IHybridHub.OrderStatus.Open || s == IHybridHub.OrderStatus.Locked) {
                (uint256[] memory amounts,) = hub.orderAmounts(id);
                open += amounts[0];
            }
        }
        assertEq(hub.escrowed(address(weth)), open);
    }

    /// @dev The campaign reaches every path the invariants are about.
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
        assertEq(handler.claims(), 2);
        assertEq(handler.fails(), 2);
        assertEq(handler.voids(), 1);
        assertEq(handler.freezes(), 1);
        assertEq(handler.reconfirms(), 1);
        assertEq(handler.burns(), 2);
        invariant_theEthereumComponentIsBacked();
        invariant_theVaultComponentIsBacked();
        invariant_theVaultAgreesWithTheBook();
        invariant_escrowFollowsTheOrders();
    }
}
