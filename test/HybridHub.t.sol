// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {HybridHub} from "../src/HybridHub.sol";
import {IHybridHubTypes} from "../src/interfaces/IHybridHubTypes.sol";
import {IHybridIndex} from "../src/interfaces/IHybridIndex.sol";
import {HybridHubExtension} from "../src/hybrid/HybridHubExtension.sol";
import {HybridHubModule} from "../src/hybrid/HybridHubModule.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";
import {XindexVault} from "../src/vault/XindexVault.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {HybridTest} from "./HybridTest.sol";

/// @notice The HybridHub on one EVM, against a real vault: mint orders from opening to claim, burns delivered and paid,
///         failures, voids on contradiction, freezes and re-confirmation, stray intakes, claims, and the mint cap.
contract HybridHubTest is HybridTest {
    IHybridIndex hub;
    address to = makeAddr("to");
    bytes32 recipient = bytes32(uint256(uint160(makeAddr("bnb recipient"))));

    function setUp() public {
        _deployStageB();
        hub = _createHybrid();
    }

    function _recipients(bytes32 r) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = r;
    }

    /// @dev The Ethereum and vault invariants of {IHybridHub}, and the hub's book against the vault's real balance.
    function _checkBacking() internal view {
        (, uint256[] memory units,,) = hub.components();
        uint256 supply = hub.totalSupply();
        assertGe(
            weth.balanceOf(address(hub)),
            supply * units[0] / 1e18 + hub.totalClaims(address(weth)) + hub.escrowed(address(weth)),
            "Ethereum backing"
        );
        assertGe(hub.vaultBacking(native), supply * units[1] / 1e18 + hub.totalClaims(native), "vault backing");
    }

    // ---------------------------------------------------------------------
    // the whole path
    // ---------------------------------------------------------------------

    function test_mint_fromOrderToShares() public {
        uint256[] memory amounts = hub.previewOrder(1e18);
        assertEq(amounts[0], 1.2e18);
        assertEq(amounts[1], 1.4e18);
        uint256 orderId = _settledOrder(hub, minter, 1e18);
        IHybridHubTypes.Order memory o = hub.order(orderId);
        assertEq(uint256(o.status), uint256(IHybridHubTypes.OrderStatus.Locked));
        assertEq(o.lockEnds, block.timestamp + 24 hours);
        assertEq(hub.escrowed(address(weth)), 1.2e18);
        assertEq(hub.balanceOf(minter), 0, "nothing claimable in the lock");

        vm.warp(o.lockEnds);
        vm.recordLogs();
        hub.claimOrder(orderId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        VaultMessages.Message memory m = _message(logs);
        assertEq(m.kind, VaultMessages.INTAKE_SETTLED);
        assertEq(abi.decode(m.body, (uint256)), hub.intakeIdOf(orderId));
        assertEq(_deliverAll(logs), 1);

        assertEq(hub.balanceOf(minter), 1e18);
        assertEq(hub.escrowed(address(weth)), 0);
        assertEq(hub.vaultBacking(native), 1.4e18);
        assertEq(vault.balance(address(hub), address(0)), 1.4e18, "the vault's books agree");
        assertEq(uint256(hub.order(orderId).status), uint256(IHybridHubTypes.OrderStatus.Claimed));
        _checkBacking();
    }

    function test_redeem_paysOnEthereumAndBurnsOnTheVaultChain() public {
        _mint(hub, minter, 2e18);
        vm.prank(minter);
        hub.transfer(holder, 1e18);

        address bnbRecipient = address(uint160(uint256(recipient)));
        vm.recordLogs();
        vm.prank(holder);
        hub.redeem(1e18, to, _recipients(recipient), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        VaultMessages.Message memory m = _message(logs);
        assertEq(m.kind, VaultMessages.BURN);
        assertEq(m.index, address(hub));
        (bytes32 token, uint256 amount, bytes32 who) = abi.decode(m.body, (bytes32, uint256, bytes32));
        (token, who); // the native coin to the recipient
        assertEq(amount, 1.4e18);
        _deliverAll(logs);

        assertEq(weth.balanceOf(to), 1.2e18);
        assertEq(bnbRecipient.balance, 1.4e18, "paid on the vault chain");
        assertEq(hub.vaultBacking(native), 1.4e18);
        assertEq(vault.balance(address(hub), address(0)), 1.4e18);
        _checkBacking();
    }

    /// @dev The hub proves the vault's intake digest at the slot the vault keeps it in, with the vault's own hash.
    function test_theVaultLayoutIsPinned() public {
        uint256[] memory amounts = hub.previewOrder(1e18);
        weth.mint(minter, amounts[0]);
        vm.startPrank(minter);
        weth.approve(address(hub), amounts[0]);
        (, uint256 intakeId) = hub.openOrder(1e18, block.timestamp + 1 hours);
        vm.deal(minter, 3e18);
        _fresh();
        vault.deposit{value: 3e18}(address(hub), intakeId);
        vm.stopPrank();
        bytes32 slot = keccak256(abi.encode(intakeId, keccak256(abi.encode(address(hub), uint256(15)))));
        assertEq(vm.load(address(vault), slot), vault.intakeDigest(address(hub), intakeId));
        address[] memory tokens = new address[](1);
        uint256[] memory totals = new uint256[](1);
        totals[0] = 3e18;
        bytes32 digest = keccak256(
            abi.encode(
                keccak256("xindex.v4.vault.intake-digest"),
                chainId,
                address(vault),
                address(hub),
                intakeId,
                IXindexVault.IntakeState.Open,
                tokens,
                totals
            )
        );
        assertEq(vault.intakeDigest(address(hub), intakeId), digest);
    }

    // ---------------------------------------------------------------------
    // opening and settling
    // ---------------------------------------------------------------------

    function test_openOrder_refusals() public {
        vm.expectRevert(IHybridHubTypes.ZeroShares.selector);
        hub.openOrder(0, block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.BadDeadline.selector, block.timestamp));
        hub.openOrder(1e18, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.BadDeadline.selector, block.timestamp + 6 hours + 1));
        hub.openOrder(1e18, block.timestamp + 6 hours + 1);

        weth.mint(minter, 10e18);
        vm.startPrank(minter);
        weth.approve(address(hub), 10e18);
        (uint256 orderId, uint256 intakeId) = hub.openOrder(1e18, block.timestamp + 6 hours);
        vm.stopPrank();
        assertEq(orderId, 1);
        assertEq(intakeId, ((block.timestamp + 6 hours) << 192) | 1);
        assertEq(hub.intakeIdOf(orderId), intakeId);
        assertEq(weth.balanceOf(address(hub)), 1.2e18, "escrowed now");
        (uint256[] memory amounts, uint256[] memory deposits) = hub.orderAmounts(orderId);
        assertEq(amounts[1], 1.4e18);
        assertEq(deposits.length, 0, "nothing proven yet");
    }

    /// @dev An index whose Ethereum component takes a fee on transfer cannot be minted: the escrow must arrive whole.
    function test_openOrder_refusesAFeeOnTransfer() public {
        MockFeeToken fee = new MockFeeToken();
        vm.prank(owner);
        factory.proposeListing(address(fee), ETH_SUPPLY);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(fee));
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(fee), native);
        vm.prank(minter);
        IHybridIndex feeHub = IHybridIndex(factory.createIndex("Fee", "FEE", tokens, K));
        fee.mint(minter, 10e18);
        vm.startPrank(minter);
        fee.approve(address(feeHub), 10e18);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.TransferAmountMismatch.selector, address(fee)));
        feeHub.openOrder(1e18, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_settleOrder_refusals() public {
        uint256[] memory amounts = hub.previewOrder(1e18);
        weth.mint(minter, amounts[0]);
        vm.startPrank(minter);
        weth.approve(address(hub), amounts[0]);
        (uint256 orderId, uint256 intakeId) = hub.openOrder(1e18, block.timestamp + 1 hours);
        vm.deal(minter, amounts[1]);
        _fresh();
        vault.deposit{value: amounts[1] - 1}(address(hub), intakeId); // one wei short
        vm.stopPrank();
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongStatus.selector, 2, IHybridHubTypes.OrderStatus.None)
        );
        hub.settleOrder(2, _chainProof(deadline + 1, 0));
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        hub.settleOrder(orderId, new IHybridHubTypes.ChainProof[](0));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ProofTooEarly.selector, chainId, deadline, deadline));
        hub.settleOrder(orderId, _chainProof(deadline, amounts[1] - 1));

        vm.warp(deadline + 1);
        IHybridHubTypes.ChainProof[] memory lying = _chainProof(block.timestamp, amounts[1]);
        bytes32 honest = vault.intakeDigest(address(hub), intakeId);
        // The preimage claims the full amount: its hash is not the vault's (C1-06: the very error, no other).
        vm.expectPartialRevert(IHybridHubTypes.DigestMismatch.selector);
        hub.settleOrder(orderId, lying);
        IHybridHubTypes.ChainProof[] memory ragged = _chainProof(block.timestamp, amounts[1] - 1);
        ragged[0].totals = new uint256[](2);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        hub.settleOrder(orderId, ragged);
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.DepositShort.selector, native, amounts[1] - 1, amounts[1])
        );
        hub.settleOrder(orderId, _chainProof(block.timestamp, amounts[1] - 1));
        assertTrue(honest != bytes32(0));
    }

    function test_settleOrder_theDigestMustBeTheVaults() public {
        uint256[] memory amounts = hub.previewOrder(1e18);
        weth.mint(minter, amounts[0]);
        vm.startPrank(minter);
        weth.approve(address(hub), amounts[0]);
        (uint256 orderId, uint256 intakeId) = hub.openOrder(1e18, block.timestamp + 1 hours);
        vm.deal(minter, amounts[1]);
        _fresh();
        vault.deposit{value: amounts[1]}(address(hub), intakeId);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        IHybridHubTypes.ChainProof[] memory p = _chainProof(block.timestamp, amounts[1] + 1); // more than was deposited
        bytes32 proven = vault.intakeDigest(address(hub), intakeId);
        address[] memory tokens = new address[](1);
        uint256[] memory totals = new uint256[](1);
        totals[0] = amounts[1] + 1;
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("xindex.v4.vault.intake-digest"),
                chainId,
                address(vault),
                address(hub),
                intakeId,
                uint8(1),
                tokens,
                totals
            )
        );
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.DigestMismatch.selector, chainId, proven, expected));
        hub.settleOrder(orderId, p);
    }

    /// @dev A deposit above what the order needs joins the index whole: the surplus stays with the holders.
    function test_settleOrder_surplusJoinsTheIndex() public {
        uint256[] memory amounts = hub.previewOrder(1e18);
        weth.mint(minter, amounts[0]);
        vm.startPrank(minter);
        weth.approve(address(hub), amounts[0]);
        (uint256 orderId, uint256 intakeId) = hub.openOrder(1e18, block.timestamp + 1 hours);
        vm.deal(minter, 2e18);
        _fresh();
        vault.deposit{value: 2e18}(address(hub), intakeId);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        hub.settleOrder(orderId, _chainProof(block.timestamp, 2e18));
        (, uint256[] memory deposits) = hub.orderAmounts(orderId);
        assertEq(deposits[1], 2e18);
        vm.warp(block.timestamp + 1 days);
        hub.claimOrder(orderId);
        assertEq(hub.vaultBacking(native), 2e18);
    }

    // ---------------------------------------------------------------------
    // the mint cap
    // ---------------------------------------------------------------------

    /// @dev An empty index has no room: only its creator seeds it, with no cap. After the seed, 4% of the supply over
    ///      any 24 hours.
    function test_mintCap() public {
        assertEq(hub.mintRoom(), 0, "an empty index: only its creator's seed");
        uint256 seed = _settledOrder(hub, minter, 100e18);
        assertEq(hub.mintRoom(), 0, "nothing more while the seed is locked");
        vm.warp(block.timestamp + 1 days);
        hub.claimOrder(seed);
        assertEq(hub.mintRoom(), 0, "the seed used the window");
        vm.warp(block.timestamp + 25 hours);
        assertEq(hub.mintRoom(), 4e18);

        uint256[] memory amounts = hub.previewOrder(5e18);
        weth.mint(minter, amounts[0]);
        vm.startPrank(minter);
        weth.approve(address(hub), amounts[0]);
        (uint256 orderId, uint256 intakeId) = hub.openOrder(5e18, block.timestamp + 1 hours);
        vm.deal(minter, amounts[1]);
        _fresh();
        vault.deposit{value: amounts[1]}(address(hub), intakeId);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.MintCapExceeded.selector, 5e18, 4e18));
        hub.settleOrder(orderId, _chainProof(block.timestamp, amounts[1]));

        _settledOrder(hub, minter, 3e18);
        assertEq(hub.mintRoom(), 1e18);
        _settledOrder(hub, minter, 1e18);
        assertEq(hub.mintRoom(), 0);
    }

    /// @dev A2-05: an index emptied but for dust is as mint-dead as an empty one, since 4% of dust a day never grows to
    ///      a share, so its creator may seed it as it may an empty one. A stranger still may not.
    function test_A205_theCreatorReseedsAnIndexBelowOneShare() public {
        _mint(hub, minter, 100e18);
        address stranger = makeAddr("stranger");
        vm.prank(minter);
        hub.transfer(stranger, 1); // a wei nobody redeems
        bytes32[] memory recipients = new bytes32[](1);
        recipients[0] = _b32(minter);
        vm.prank(minter);
        hub.redeem(100e18 - 1, minter, recipients, 0);
        assertEq(hub.totalSupply(), 1);
        vm.warp(block.timestamp + 25 hours); // the seed's own window is over
        assertEq(hub.mintRoom(), 0);

        uint256 dust = 1e15;
        uint256[] memory amounts = hub.previewOrder(dust);
        weth.mint(stranger, amounts[0]);
        vm.startPrank(stranger);
        weth.approve(address(hub), amounts[0]);
        (uint256 orderId, uint256 intakeId) = hub.openOrder(dust, block.timestamp + 1 hours);
        vm.deal(stranger, amounts[1]);
        _fresh();
        vault.deposit{value: amounts[1]}(address(hub), intakeId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.MintCapExceeded.selector, dust, 0));
        hub.settleOrder(orderId, _chainProof(block.timestamp, amounts[1]));

        _mint(hub, minter, 10e18);
        assertEq(hub.totalSupply(), 10e18 + 1);
        assertEq(hub.balanceOf(stranger), 1, "the dust is untouched");
    }

    /// @dev HUB-2: a stranger cannot seed an empty index. Its dust would be the whole supply, and 4% of dust a day would
    ///      never let the index grow.
    function test_HUB2_onlyTheCreatorSeedsAnEmptyIndex() public {
        address stranger = makeAddr("stranger");
        uint256 dust = 1e15;
        uint256[] memory amounts = hub.previewOrder(dust);
        weth.mint(stranger, amounts[0]);
        vm.startPrank(stranger);
        weth.approve(address(hub), amounts[0]);
        (uint256 orderId, uint256 intakeId) = hub.openOrder(dust, block.timestamp + 1 hours);
        vm.deal(stranger, amounts[1]);
        _fresh();
        vault.deposit{value: amounts[1]}(address(hub), intakeId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours + 1);
        IHybridHubTypes.ChainProof[] memory p = _chainProof(block.timestamp, amounts[1]);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.MintCapExceeded.selector, dust, 0));
        hub.settleOrder(orderId, p);
        // The creator's seed settles, however large; while it is locked, nobody's order does, the creator's included.
        amounts = hub.previewOrder(dust);
        weth.mint(minter, amounts[0]);
        vm.startPrank(minter);
        weth.approve(address(hub), amounts[0]);
        (uint256 second, uint256 secondIntake) = hub.openOrder(dust, block.timestamp + 1 hours);
        vm.deal(minter, amounts[1]);
        vault.deposit{value: amounts[1]}(address(hub), secondIntake);
        vm.stopPrank();
        _settledOrder(hub, minter, 100e18);
        assertEq(hub.mintRoom(), 0);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.MintCapExceeded.selector, dust, 0));
        hub.settleOrder(orderId, p);
        p = _chainProof(block.timestamp, amounts[1]);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.MintCapExceeded.selector, dust, 0));
        hub.settleOrder(second, p);
    }

    // ---------------------------------------------------------------------
    // claims of orders, failures, voids, freezes
    // ---------------------------------------------------------------------

    function test_claimOrder_refusals() public {
        uint256 orderId = _settledOrder(hub, minter, 1e18);
        uint256 lockEnds = hub.order(orderId).lockEnds;
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotYet.selector, lockEnds));
        hub.claimOrder(orderId);
        vm.warp(lockEnds);
        hub.claimOrder(orderId);
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongStatus.selector, orderId, IHybridHubTypes.OrderStatus.Claimed)
        );
        hub.claimOrder(orderId);
    }

    /// @dev An open order fails at its minter's word at any time, or at anyone's after the grace; its escrow becomes the
    ///      minter's claim and each vault is told to refund the deposits.
    function test_failOrder() public {
        uint256[] memory amounts = hub.previewOrder(1e18);
        weth.mint(minter, amounts[0]);
        vm.startPrank(minter);
        weth.approve(address(hub), amounts[0]);
        (uint256 orderId, uint256 intakeId) = hub.openOrder(1e18, block.timestamp + 1 hours);
        vm.deal(minter, amounts[1]);
        _fresh();
        vault.deposit{value: amounts[1]}(address(hub), intakeId);
        vm.stopPrank();

        uint256 openTo = block.timestamp + 1 hours + 6 hours;
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotYet.selector, openTo));
        hub.failOrder(orderId);
        vm.warp(openTo + 1);
        vm.recordLogs();
        hub.failOrder(orderId); // a stranger, after the grace
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_message(logs).kind, VaultMessages.INTAKE_FAILED);
        _deliverAll(logs);

        assertEq(hub.claimOf(minter, address(weth)), amounts[0]);
        assertEq(hub.escrowed(address(weth)), 0);
        vm.prank(minter);
        hub.claim(address(weth), minter);
        assertEq(weth.balanceOf(minter), amounts[0]);
        vm.prank(minter);
        vault.refund(address(hub), intakeId);
        assertEq(minter.balance, amounts[1], "refunded on the vault chain");
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongStatus.selector, orderId, IHybridHubTypes.OrderStatus.Failed)
        );
        hub.failOrder(orderId);
    }

    function test_failOrder_theMinterAtAnyTime() public {
        weth.mint(minter, 2e18);
        vm.startPrank(minter);
        weth.approve(address(hub), 2e18);
        (uint256 orderId,) = hub.openOrder(1e18, block.timestamp + 1 hours);
        hub.failOrder(orderId);
        vm.stopPrank();
        assertEq(uint256(hub.order(orderId).status), uint256(IHybridHubTypes.OrderStatus.Failed));
    }

    /// @dev In the lock, a proof of the same intake showing anything else voids the order and freezes the chain's mints.
    function test_voidOrder_onAContradiction() public {
        uint256 orderId = _settledOrder(hub, minter, 1e18);
        uint256 deadline = hub.order(orderId).deadline;
        bytes32 recorded = vault.intakeDigest(address(hub), hub.intakeIdOf(orderId));

        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAContradiction.selector, chainId));
        hub.voidOrder(orderId, chainId, _honest(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ProofTooEarly.selector, chainId, deadline, deadline));
        hub.voidOrder(orderId, chainId, _forged(deadline, bytes32(uint256(1))));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVaultChain.selector, 7));
        hub.voidOrder(orderId, 7, _forged(block.timestamp, bytes32(uint256(1))));

        vm.expectEmit(address(hub));
        emit IHybridHubTypes.OrderVoided(orderId, chainId, bytes32(uint256(1)), recorded);
        vm.recordLogs();
        hub.voidOrder(orderId, chainId, _forged(block.timestamp, bytes32(uint256(1))));
        _deliverAll(vm.getRecordedLogs());
        assertEq(uint256(hub.order(orderId).status), uint256(IHybridHubTypes.OrderStatus.Failed));
        (, uint256 frozenTo) = hub.chainFreeze(chainId);
        assertEq(frozenTo, block.timestamp + 14 days);
        assertEq(factory.chainFreeze(chainId).until, frozenTo, "frozen at the factory, for every index");
        assertEq(vault.frozenUntil(), 0, "a false deposit proof stops mints, not the vault's payouts");
        assertEq(hub.claimOf(minter, address(weth)), 1.2e18);
        uint256 intakeId = hub.intakeIdOf(orderId); // before the prank, which a call in the arguments would consume
        vm.prank(minter);
        vault.refund(address(hub), intakeId);
        assertEq(minter.balance, 1.4e18, "the deposit came back on the vault chain");

        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.ChainIsFrozen.selector, chainId, block.timestamp + 14 days)
        );
        hub.openOrder(1e18, block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongStatus.selector, orderId, IHybridHubTypes.OrderStatus.Failed)
        );
        hub.voidOrder(orderId, chainId, _forged(block.timestamp, bytes32(uint256(1))));
    }

    /// @dev A freeze after an order settled holds it: not while frozen, and after the freeze only once a fresh proof of
    ///      the unchanged intake re-confirms it.
    function test_freeze_holdsAnOrderUntilReconfirmed() public {
        uint256 orderId = _settledOrder(hub, minter, 1e18);
        hub.reconfirmOrder(orderId, _oneProof(bytes(""))); // nothing froze: nothing to prove
        vm.warp(block.timestamp + 1 hours);
        vm.recordLogs();
        vm.prank(guardian);
        factory.freezeChain(chainId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 until = block.timestamp + 14 days;
        (uint256 start, uint256 end) = hub.chainFreeze(chainId);
        assertEq(start, block.timestamp);
        assertEq(end, until);
        // The factory's FREEZE message stops the vault too, on one proof.
        bytes memory proof = abi.encode(logs[1].emitter, logs[1].topics[0], logs[1].topics[1], logs[1].data);
        vault.deliver(proof, "");
        assertEq(vault.frozenUntil(), until);

        vm.warp(hub.order(orderId).lockEnds);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainIsFrozen.selector, chainId, until));
        hub.claimOrder(orderId);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainIsFrozen.selector, chainId, until));
        hub.reconfirmOrder(orderId, _oneProof(_honest(until + 1)));
        vm.warp(until);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NeedsReconfirmation.selector, orderId, chainId));
        hub.claimOrder(orderId);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ProofTooEarly.selector, chainId, until, until));
        hub.reconfirmOrder(orderId, _oneProof(_honest(until)));
        bytes32 recorded = vault.intakeDigest(address(hub), hub.intakeIdOf(orderId));
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.DigestMismatch.selector, chainId, bytes32(uint256(2)), recorded)
        );
        hub.reconfirmOrder(orderId, _oneProof(_forged(until + 1, bytes32(uint256(2)))));
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        hub.reconfirmOrder(orderId, new bytes[](0));
        vm.warp(until + 1);
        hub.reconfirmOrder(orderId, _oneProof(_honest(until + 1)));
        hub.claimOrder(orderId);
        assertEq(hub.balanceOf(minter), 1e18);
    }

    /// @dev HUB-3: an order a freeze holds, never re-confirmed, is not stuck for good. Once the freeze has been over for
    ///      a week, its minter, and only its minter, may give it up: the escrow becomes its claims, and the vault refunds
    ///      the deposit.
    function test_HUB3_theMinterMayGiveUpAnOrderAFreezeHolds() public {
        uint256 orderId = _settledOrder(hub, minter, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainNotExited.selector, chainId));
        vm.prank(minter);
        hub.failHeldOrder(orderId, chainId); // nothing holds it
        vm.warp(block.timestamp + 1 hours);
        vm.prank(guardian);
        factory.freezeChain(chainId);
        (, uint256 until) = hub.chainFreeze(chainId);
        uint256 openAt = until + hub.HELD_ORDER_GRACE();
        assertEq(openAt, until + 7 days);
        vm.warp(openAt - 1);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotYet.selector, openAt));
        hub.failHeldOrder(orderId, chainId);
        vm.warp(openAt);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainNotExited.selector, chainId));
        hub.failHeldOrder(orderId, chainId); // not its minter
        (uint256[] memory escrow,) = hub.orderAmounts(orderId);
        vm.recordLogs();
        vm.prank(minter);
        hub.failHeldOrder(orderId, chainId);
        assertEq(uint256(hub.order(orderId).status), uint256(IHybridHubTypes.OrderStatus.Failed));
        assertEq(hub.claimOf(minter, address(weth)), escrow[0]);
        assertEq(_message(vm.getRecordedLogs()).kind, VaultMessages.INTAKE_FAILED);
    }

    /// @dev A freeze in the very second an order settles came after the settlement, since nothing settles while
    ///      frozen, so it holds the order as a later one would.
    function test_freeze_inTheSettlingSecondHoldsTheOrder() public {
        uint256 orderId = _settledOrder(hub, minter, 1e18);
        vm.prank(guardian);
        factory.freezeChain(chainId);
        uint256 until = block.timestamp + 14 days;
        vm.warp(until);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NeedsReconfirmation.selector, orderId, chainId));
        hub.claimOrder(orderId);
        vm.warp(until + 1);
        hub.reconfirmOrder(orderId, _oneProof(_honest(until + 1)));
        hub.claimOrder(orderId);
    }

    function _oneProof(bytes memory p) internal pure returns (bytes[] memory list) {
        list = new bytes[](1);
        list[0] = p;
    }

    /// @dev An intake no order owns can be failed once its deadline has passed, so a stray deposit is never stuck.
    function test_failIntake() public {
        uint256 stray = ((block.timestamp + 1 hours) << 192) | 99;
        vm.deal(holder, 1e18);
        _fresh();
        vm.prank(holder);
        vault.deposit{value: 1e18}(address(hub), stray);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.IntakeStillOpen.selector, block.timestamp + 1 hours));
        hub.failIntake(chainId, stray);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVaultChain.selector, 5));
        hub.failIntake(5, stray);

        uint256 orderId = _settledOrder(hub, minter, 1e18); // order 1
        uint256 ownIntake = hub.intakeIdOf(orderId);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.IntakeOfAnOrder.selector, ownIntake));
        hub.failIntake(chainId, ownIntake);

        vm.recordLogs();
        hub.failIntake(chainId, stray); // order 99 does not exist
        _deliverAll(vm.getRecordedLogs());
        vm.prank(holder);
        vault.refund(address(hub), stray);
        assertEq(holder.balance, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.IntakeAlreadyFailed.selector, stray));
        hub.failIntake(chainId, stray);

        // Order 1's id under another deadline, and an id with no order part, are not order 1's.
        uint256 otherDeadline = ((block.timestamp - 2) << 192) | orderId; // its own deadline was a second ago
        hub.failIntake(chainId, otherDeadline);
        hub.failIntake(chainId, (block.timestamp - 2) << 192);
    }

    /// @dev LG-1: whoever sends a transaction shapes its receipt, and a receipt can be made too large for a vault
    ///      chain's verifier to prove. So every message an index sends is marked sent, from the hub and from its module
    ///      alike, and anyone may emit it again, unchanged, in a transaction of their own. The vault runs it once.
    function test_LG1_anyoneSendsAMessageAgain() public {
        uint256 orderId = _settledOrder(hub, minter, 1e18);
        vm.warp(hub.order(orderId).lockEnds);
        vm.recordLogs();
        hub.claimOrder(orderId); // its settle message never reaches the vault
        (bytes32 id, bytes memory payload) = _sent(vm.getRecordedLogs());
        assertTrue(hub.messageSent(id));

        vm.recordLogs();
        vm.prank(holder);
        hub.resendMessage(payload);
        Vm.Log[] memory again = vm.getRecordedLogs();
        assertEq(again.length, 1, "the message alone");
        assertEq(again[0].emitter, address(hub));
        (bytes32 resentId, bytes memory resent) = _sent(again);
        assertEq(resentId, id);
        assertEq(resent, payload);
        assertEq(_deliverAll(again), 1);
        assertEq(vault.balance(address(hub), address(0)), 1.4e18);
        bytes memory proof = abi.encode(address(hub), VaultMessages.EVENT_TOPIC, id, abi.encode(payload));
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.AlreadyDelivered.selector, id));
        vault.deliver(proof, proof);

        // The module's messages are marked too.
        uint256 stray = ((block.timestamp + 1 hours) << 192) | 99;
        vm.warp(block.timestamp + 1 hours + 1);
        vm.recordLogs();
        hub.failIntake(chainId, stray);
        (bytes32 failed, bytes memory failure) = _sent(vm.getRecordedLogs());
        assertEq(VaultMessages.decode(failure).kind, VaultMessages.INTAKE_FAILED);
        assertTrue(hub.messageSent(failed));
        hub.resendMessage(failure);

        bytes memory never = abi.encodePacked(payload, bytes1(0));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotSent.selector, keccak256(never)));
        hub.resendMessage(never);
    }

    // ---------------------------------------------------------------------
    // redeem and claims
    // ---------------------------------------------------------------------

    function test_redeem_refusals() public {
        _mint(hub, minter, 1e18);
        bytes32[] memory r = _recipients(recipient);
        vm.startPrank(minter);
        vm.expectRevert(IHybridHubTypes.ZeroShares.selector);
        hub.redeem(0, to, r, 0);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        hub.redeem(1, address(0), r, 0);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(hub)));
        hub.redeem(1, address(hub), r, 0);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(factory)));
        hub.redeem(1, address(factory), r, 0);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        hub.redeem(1, to, new bytes32[](2), 0);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.InvalidSkipMask.selector, 4));
        hub.redeem(1, to, r, 4);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(hub)));
        hub.transfer(address(hub), 1);
        vm.stopPrank();
    }

    /// @dev A zero recipient books the vault component as a claim of `to`, burned later toward a recipient it names; a
    ///      skipped Ethereum component is a claim paid on Ethereum.
    function test_redeem_claimsForLater() public {
        _mint(hub, minter, 1e18);
        vm.recordLogs();
        vm.prank(minter);
        hub.redeem(0.5e18, to, _recipients(bytes32(0)), 1); // skip WETH, no BNB recipient yet
        assertEq(_deliverAll(vm.getRecordedLogs()), 0, "nothing burned yet");
        assertEq(hub.claimOf(to, address(weth)), 0.6e18);
        assertEq(hub.claimOf(to, native), 0.7e18);
        assertEq(hub.vaultBacking(native), 1.4e18, "the claim is still in the vault");
        _checkBacking();

        vm.startPrank(to);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAnEthereumToken.selector, native));
        hub.claim(native, to);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVaultToken.selector, address(weth)));
        hub.claimToVault(address(weth), recipient);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVaultToken.selector, address(1)));
        hub.claimToVault(address(1), recipient);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        hub.claimToVault(native, bytes32(0));
        hub.claim(address(weth), to);
        vm.recordLogs();
        hub.claimToVault(native, recipient);
        vm.stopPrank();
        _deliverAll(vm.getRecordedLogs());
        assertEq(weth.balanceOf(to), 0.6e18);
        assertEq(address(uint160(uint256(recipient))).balance, 0.7e18);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NothingToClaim.selector, native));
        vm.prank(to);
        hub.claimToVault(native, recipient);
        _checkBacking();
    }

    // ---------------------------------------------------------------------
    // two vault chains
    // ---------------------------------------------------------------------

    /// @dev An index on two vault chains: one order deposits on both, settles on two proofs, and each vault receives
    ///      only its own messages. The second vault believes it runs on chain 56; the test switches the EVM's chain id
    ///      around its calls.
    function test_twoChains_oneOrderSpansBoth() public {
        uint256 bsc = 56;
        XindexVault second = _newVault();
        vm.prank(owner);
        factory.proposeChain(bsc, _b32(address(second)), address(stateVerifier));
        vm.warp(block.timestamp + 2 days);
        factory.executeChain(bsc);
        vm.prank(owner);
        factory.proposeVaultListing(bsc, bytes32(0), BNB_SUPPLY);
        address bnb = factory.vaultTokenId(bsc, bytes32(0));
        vm.warp(block.timestamp + 2 days);
        factory.executeListing(bnb);

        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(weth), native, bnb);
        vm.prank(minter);
        IHybridIndex two = IHybridIndex(factory.createIndex("Two", "TWO", tokens, K));
        (uint256[] memory ids,) = two.chains();
        assertEq(ids.length, 2);
        assertEq(ids[1], bsc);
        vault.registerIndex(address(two), factory.indexSalt(address(two)));
        second.registerIndex(address(two), factory.indexSalt(address(two)));

        uint256[] memory amounts = two.previewOrder(1e18);
        weth.mint(minter, amounts[0]);
        vm.deal(minter, amounts[1] + amounts[2]);
        vm.startPrank(minter);
        weth.approve(address(two), amounts[0]);
        (uint256 orderId, uint256 intakeId) = two.openOrder(1e18, block.timestamp + 1 hours);
        _fresh();
        vault.deposit{value: amounts[1]}(address(two), intakeId);
        vm.chainId(bsc);
        _fresh(second);
        second.deposit{value: amounts[2]}(address(two), intakeId);
        vm.chainId(chainId);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);
        IHybridHubTypes.ChainProof[] memory proofs = new IHybridHubTypes.ChainProof[](2);
        proofs[0] = _chainProof(block.timestamp, amounts[1])[0];
        proofs[1] = _chainProof(block.timestamp, amounts[2])[0];
        two.settleOrder(orderId, proofs);
        vm.warp(block.timestamp + 1 days);
        vm.recordLogs();
        two.claimOrder(orderId);
        _deliverTo(vm.getRecordedLogs(), second, bsc);
        assertEq(vault.balance(address(two), address(0)), amounts[1]);
        assertEq(second.balance(address(two), address(0)), amounts[2]);

        bytes32[] memory recipients = new bytes32[](2);
        (recipients[0], recipients[1]) = (recipient, recipient);
        vm.recordLogs();
        vm.prank(minter);
        two.redeem(1e18, to, recipients, 0);
        _deliverTo(vm.getRecordedLogs(), second, bsc);
        assertEq(address(uint160(uint256(recipient))).balance, amounts[1] + amounts[2], "paid on both chains");
        assertEq(vault.balance(address(two), address(0)), 0);
        assertEq(second.balance(address(two), address(0)), 0);
    }

    /// @dev Delivers each message to the vault it names: the first vault as it is, `other` on `otherChain`.
    function _deliverTo(Vm.Log[] memory logs, XindexVault other, uint256 otherChain) internal {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != VaultMessages.EVENT_TOPIC) continue;
            bytes memory proof = abi.encode(logs[i].emitter, logs[i].topics[0], logs[i].topics[1], logs[i].data);
            VaultMessages.Message memory m = VaultMessages.decode(abi.decode(logs[i].data, (bytes)));
            if (m.destChainId == otherChain) {
                vm.chainId(otherChain);
                other.deliver(proof, proof);
                vm.chainId(chainId);
            } else {
                vault.deliver(proof, proof);
            }
        }
    }

    // ---------------------------------------------------------------------
    // initialization and views
    // ---------------------------------------------------------------------

    function test_views() public {
        (address[] memory tokens, uint256[] memory units, uint256[] memory chainIds, bytes32[] memory vaultTokens) =
            hub.components();
        assertEq(tokens[0], address(weth));
        assertEq(tokens[1], native);
        assertEq(units[0], 1.2e18);
        assertEq(chainIds[0], 0);
        assertEq(chainIds[1], chainId);
        assertEq(vaultTokens[1], bytes32(0));
        (uint256[] memory ids, bytes32[] memory vaults) = hub.chains();
        assertEq(ids.length, 1);
        assertEq(vaults[0], _b32(address(vault)));
        assertEq(hub.previewRedeem(1e18)[1], 1.4e18);
        assertEq(hub.FACTORY(), address(factory));
        assertEq(hub.MINT_LOCK(), 24 hours);
        assertEq(hub.MAX_ORDER_LIFE(), 6 hours);
        assertEq(hub.SETTLE_GRACE(), 6 hours);
        assertEq(hub.MINT_CAP(), 0.04e18);
        assertEq(hub.FREEZE_DURATION(), 14 days);
        _mint(hub, minter, 1e18);
        assertEq(hub.orderCount(), 1);
        assertEq(hub.messageNonce(), 1);
        assertEq(hub.nonces(minter), 0);
    }

    /// @dev A redemption too small for a component's raw unit sends nothing of it: no zero burn, no zero claim.
    function test_redeem_aDustComponentSendsNothing() public {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(weth), native);
        vm.prank(minter);
        IHybridIndex small = IHybridIndex(factory.createIndex("Small", "SML", tokens, 1e22)); // 1.2e12 and 1.4e12 raw units
        vault.registerIndex(address(small), factory.indexSalt(address(small)));
        _mint(small, minter, 1e18);
        vm.recordLogs();
        vm.prank(minter);
        small.redeem(1e5, to, _recipients(recipient), 0); // 0.12 and 0.14 raw units: both round to nothing
        assertEq(_deliverAll(vm.getRecordedLogs()), 0);
        assertEq(small.claimOf(to, native), 0);
        assertEq(weth.balanceOf(to), 0);
    }

    function test_initialize_refusals() public {
        HybridHubExtension ownExtension = new HybridHubExtension(address(this));
        HybridHubModule own_ = new HybridHubModule(address(this), address(ownExtension));
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new HybridHub(address(0), address(own_));
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new HybridHubModule(address(0), address(ownExtension));
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new HybridHubExtension(address(0));
        // A zero part is refused by name, before the part is asked which factory it serves.
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new HybridHub(address(this), address(0));
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new HybridHubModule(address(this), address(0));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.WrongModule.selector, address(module)));
        new HybridHub(address(this), address(module)); // a module built for another factory
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.WrongModule.selector, address(extension)));
        new HybridHubModule(address(this), address(extension)); // an extension built for another factory
        assertEq(own_.EXTENSION(), address(ownExtension));
        HybridHub own = new HybridHub(address(this), address(own_));
        address[] memory tokens = new address[](1);
        uint256[] memory units = new uint256[](1);
        IHybridHubTypes.Placement[] memory placements = new IHybridHubTypes.Placement[](1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        own.initialize("x", "x", tokens, units, placements);

        tokens[0] = address(weth);
        units[0] = 1e18;
        placements[0] = IHybridHubTypes.Placement({chainId: 5, vaultToken: bytes32(0), vault: _b32(address(vault))});
        HybridHub clone = HybridHub(payable(Clones.clone(address(own))));
        vm.prank(minter);
        vm.expectRevert(IHybridHubTypes.NotFactory.selector);
        clone.initialize("x", "x", tokens, units, placements);
        vm.expectRevert(IHybridHubTypes.InvalidComponents.selector);
        clone.initialize("x", "x", new address[](0), new uint256[](0), new IHybridHubTypes.Placement[](0));
        vm.expectRevert(IHybridHubTypes.InvalidComponents.selector);
        clone.initialize("x", "x", tokens, new uint256[](2), placements);
        vm.expectRevert(IHybridHubTypes.InvalidComponents.selector);
        clone.initialize("x", "x", tokens, units, new IHybridHubTypes.Placement[](2));
        vm.expectRevert(IHybridHubTypes.InvalidComponents.selector);
        clone.initialize("x", "x", new address[](1), units, placements);
        vm.expectRevert(IHybridHubTypes.InvalidComponents.selector);
        clone.initialize("x", "x", tokens, new uint256[](1), placements);
        vm.expectRevert(IHybridHubTypes.InvalidComponents.selector); // Ethereum components only
        clone.initialize("x", "x", tokens, units, new IHybridHubTypes.Placement[](1));
        placements[0].vault = bytes32(0);
        vm.expectRevert(IHybridHubTypes.InvalidComponents.selector); // a vault chain without a vault
        clone.initialize("x", "x", tokens, units, placements);

        // Two components on one chain share it.
        address[] memory two = new address[](2);
        (two[0], two[1]) = (address(weth), native);
        uint256[] memory twoUnits = new uint256[](2);
        (twoUnits[0], twoUnits[1]) = (1, 1);
        IHybridHubTypes.Placement[] memory both = new IHybridHubTypes.Placement[](2);
        both[0] = IHybridHubTypes.Placement({chainId: 5, vaultToken: bytes32(uint256(1)), vault: _b32(address(vault))});
        both[1] = IHybridHubTypes.Placement({chainId: 5, vaultToken: bytes32(0), vault: _b32(address(vault))});
        clone.initialize("x", "x", two, twoUnits, both);
        (uint256[] memory ids,) = clone.chains();
        assertEq(ids.length, 1);

        HybridHub never = HybridHub(payable(Clones.clone(address(own))));
        vm.expectRevert(IHybridHubTypes.NotInitialized.selector);
        never.openOrder(1, block.timestamp + 1);
    }
}
