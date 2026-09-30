// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IHybridHubTypes} from "../src/interfaces/IHybridHubTypes.sol";
import {IHybridIndex} from "../src/interfaces/IHybridIndex.sol";
import {IHybridIndexFactory} from "../src/interfaces/IHybridIndexFactory.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {HybridTest} from "./HybridTest.sol";

/// @notice Migration between two HybridHub versions against a real vault, and the evidence that freezes a chain: a
///         vault paying out more than the index ever sent, and a claimed order's deposit proven false.
contract HybridHubMigrationTest is HybridTest {
    IHybridIndex old;
    IHybridIndex next;
    MockERC20 link;
    address to = makeAddr("to");
    bytes32 recipient = bytes32(uint256(uint160(makeAddr("bnb recipient"))));
    uint256 constant LINK_SUPPLY = 1_000_000_000e18;
    /// @dev Half the old index's k: 0.6 WETH, 0.7 BNB and 5 LINK per whole new share.
    uint256 constant K2 = 0.5e28;

    function setUp() public {
        _deployStageB();
        old = _createHybrid();
        link = new MockERC20("Chainlink", "LINK", 18);
        vm.prank(owner);
        factory.proposeListing(address(link), LINK_SUPPLY);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(link));
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(weth), native, address(link));
        next = IHybridIndex(factory.createIndex("Version 2", "V2", tokens, K2));
        vault.registerIndex(address(next), factory.indexSalt(address(next)));
        _mint(old, holder, 1e18);
    }

    function _recipients(bytes32 r) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = r;
    }

    /// @dev LINK for `shares` of the new index, approved to it.
    function _fundLink(uint256 amount) internal {
        link.mint(holder, amount);
        vm.prank(holder);
        link.approve(address(next), amount);
    }

    /// @dev A whole mint of the new index, whose LINK `_mint` does not fund.
    function _mintNext(address who, uint256 shares) internal {
        uint256[] memory amounts = next.previewOrder(shares);
        weth.mint(who, amounts[0]);
        link.mint(who, amounts[2]);
        vm.startPrank(who);
        weth.approve(address(next), amounts[0]);
        link.approve(address(next), amounts[2]);
        (uint256 orderId, uint256 intakeId) = next.openOrder(shares, block.timestamp + 1 hours);
        vm.deal(who, amounts[1]);
        vault.deposit{value: amounts[1]}(address(next), intakeId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours + 1);
        next.settleOrder(orderId, _chainProof(block.timestamp, amounts[1]));
        vm.warp(block.timestamp + next.MINT_LOCK());
        vm.recordLogs();
        next.claimOrder(orderId);
        _deliverAll(vm.getRecordedLogs());
    }

    // ---------------------------------------------------------------------
    // migration
    // ---------------------------------------------------------------------

    /// @dev 1 old share backs 1.2 WETH and 1.4 BNB; 1.5 new shares need 0.9 WETH, 1.05 BNB and 7.5 LINK. The BNB moves
    ///      inside the vault, the WETH from index to index, the holder pays the LINK, and the rest goes to `to`.
    function test_migrate_movesOnlyTheDifference() public {
        _fundLink(7.5e18);
        vm.recordLogs();
        vm.expectEmit(address(old));
        emit IHybridHubTypes.MigratedOut(holder, address(next), to, 1e18, 1.5e18);
        vm.expectEmit(address(next));
        emit IHybridHubTypes.MigratedIn(address(old), to, 1.5e18);
        vm.prank(holder);
        old.migrate(address(next), 1e18, 1.5e18, to, _recipients(recipient));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(old.balanceOf(holder), 0);
        assertEq(old.totalSupply(), 0);
        assertEq(next.balanceOf(to), 1.5e18);
        assertEq(weth.balanceOf(address(next)), 0.9e18);
        assertEq(weth.balanceOf(to), 0.3e18, "the WETH the new shares do not need");
        assertEq(link.balanceOf(address(next)), 7.5e18);
        assertEq(old.vaultBacking(native), 0);
        assertEq(next.vaultBacking(native), 1.05e18);
        assertEq(old.sentOut(native), 1.4e18, "migrated and burned alike");
        assertEq(next.sentOut(native), 0);

        // The vault moves 1.05 BNB to the new index's balance and pays 0.35 BNB to the holder's recipient.
        assertEq(_deliverAll(logs), 2);
        assertEq(vault.balance(address(old), address(0)), 0);
        assertEq(vault.balance(address(next), address(0)), 1.05e18);
        assertEq(address(uint160(uint256(recipient))).balance, 0.35e18);
        assertEq(vault.paidTotal(address(old), address(0)), 1.4e18);
        assertEq(address(vault).balance, 1.05e18, "only the difference left the vault");

        // The new shares redeem like any others.
        vm.recordLogs();
        vm.prank(to);
        next.redeem(1.5e18, to, _recipients(recipient), 0);
        _deliverAll(vm.getRecordedLogs());
        assertEq(weth.balanceOf(to), 1.2e18);
        assertEq(link.balanceOf(to), 7.5e18);
        assertEq(address(uint160(uint256(recipient))).balance, 1.4e18);
    }

    /// @dev With no recipient on a chain, what the old shares back beyond the new ones is booked as `to`'s claim.
    function test_migrate_theRestIsAClaimWithoutARecipient() public {
        _fundLink(7.5e18);
        vm.prank(holder);
        old.migrate(address(next), 1e18, 1.5e18, to, _recipients(bytes32(0)));
        assertEq(old.claimOf(to, native), 0.35e18);
        assertEq(old.sentOut(native), 1.05e18);
        assertEq(old.vaultBacking(native), 0.35e18);
    }

    /// @dev A vault token the new shares need more of than the old ones back cannot be migrated.
    function test_migrate_aVaultLegMustBeCovered() public {
        _fundLink(10e18 + 1);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.MigrationShort.selector, native, 1.4e18, 1.4e18 + 1));
        old.migrate(address(next), 1e18, 2e18 + 1, to, _recipients(recipient));
    }

    /// @dev A vault token only the new version holds needs fresh deposits, so an order, not a migration.
    function test_migrate_aVaultTokenNewToTheVersionNeedsAnOrder() public {
        vm.prank(owner);
        factory.proposeVaultListing(chainId, bytes32(uint256(0xCA4E)), BNB_SUPPLY);
        address cake = factory.vaultTokenId(chainId, bytes32(uint256(0xCA4E)));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(cake);
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(weth), native, cake);
        IHybridIndex withCake = IHybridIndex(factory.createIndex("Cake", "CK", tokens, K2));
        vm.prank(holder);
        // 0.5 new shares need 0.35 CAKE, and the old shares back none.
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.MigrationShort.selector, cake, 0, 0.35e18));
        old.migrate(address(withCake), 1e18, 0.5e18, to, _recipients(recipient));
    }

    function test_migrate_refusals() public {
        bytes32[] memory r = _recipients(recipient);
        vm.startPrank(holder);
        vm.expectRevert(IHybridHubTypes.ZeroShares.selector);
        old.migrate(address(next), 0, 1e18, to, r);
        vm.expectRevert(IHybridHubTypes.ZeroShares.selector);
        old.migrate(address(next), 1e18, 0, to, r);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        old.migrate(address(next), 1e18, 1e18, address(0), r);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(old)));
        old.migrate(address(next), 1e18, 1e18, address(old), r);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(factory)));
        old.migrate(address(next), 1e18, 1e18, address(factory), r);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        old.migrate(address(next), 1e18, 1e18, to, new bytes32[](2));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVersion.selector, address(old)));
        old.migrate(address(old), 1e18, 1e18, to, r);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVersion.selector, holder));
        old.migrate(holder, 1e18, 1e18, to, r);
        vm.stopPrank();

        // An Ethereum-only index is Stage A's IndexHub, not a version to migrate to.
        address[] memory ethOnly = new address[](1);
        ethOnly[0] = address(weth);
        address plain = factory.createIndex("Eth", "ETHI", ethOnly, K);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVersion.selector, plain));
        old.migrate(plain, 1e18, 1e18, to, r);

        // The new index refuses its own address as the recipient of its shares.
        _fundLink(5e18);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(next)));
        old.migrate(address(next), 1e18, 1e18, address(next), r);
        // And the holder must pay the LINK only the new version holds.
        vm.prank(holder);
        link.approve(address(next), 0);
        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(next), 0, 5e18)
        );
        old.migrate(address(next), 1e18, 1e18, to, r);
    }

    /// @dev Only another version's `migrate` can mint here, and what it says it sent is checked in real balances.
    function test_acceptMigration_checksItsCallerAndTheBalances() public {
        uint256[] memory three = new uint256[](3);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVersion.selector, address(this)));
        next.acceptMigration(holder, to, 1e18, three, three);

        vm.startPrank(address(old));
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        next.acceptMigration(holder, to, 1e18, new uint256[](2), three);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        next.acceptMigration(holder, to, 1e18, three, new uint256[](2));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(factory)));
        next.acceptMigration(holder, address(factory), 1e18, three, three);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.MigrationShort.selector, native, 0, 0.7e18));
        next.acceptMigration(holder, to, 1e18, three, three);

        // Claimed but not sent: the WETH the old index says it sent never arrived.
        uint256[] memory vaultIn = new uint256[](3);
        vaultIn[1] = 0.7e18;
        uint256[] memory ethIn = new uint256[](3);
        ethIn[0] = 0.6e18;
        ethIn[2] = 5e18;
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.RebalanceUnderfunded.selector, address(weth), 0, 0.6e18));
        next.acceptMigration(holder, to, 1e18, ethIn, vaultIn);
        vm.stopPrank();
    }

    /// @dev An Ethereum token the holder pays must arrive whole.
    function test_acceptMigration_refusesAFeeOnTransfer() public {
        MockFeeToken fee = new MockFeeToken();
        vm.prank(owner);
        factory.proposeListing(address(fee), ETH_SUPPLY);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(fee));
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(weth), native, address(fee));
        IHybridIndex feeHub = IHybridIndex(factory.createIndex("Fee", "FEE", tokens, K2));
        fee.mint(holder, 10e18);
        vm.prank(holder);
        fee.approve(address(feeHub), 10e18);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.TransferAmountMismatch.selector, address(fee)));
        old.migrate(address(feeHub), 1e18, 1e18, to, _recipients(recipient));
    }

    /// @dev No backing joins an index on a frozen chain, and supply cannot grow under an accepted fill.
    function test_acceptMigration_waitsOnAFreezeAndAFill() public {
        _fundLink(5e18);
        vm.prank(guardian);
        factory.freezeChain(chainId);
        uint256 until = block.timestamp + 14 days;
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainIsFrozen.selector, chainId, until));
        old.migrate(address(next), 1e18, 1e18, to, _recipients(recipient));

        vm.warp(until);
        _mintNext(minter, 1e18);
        vm.warp(block.timestamp + next.MIN_REBALANCE_INTERVAL());
        uint256[] memory supplies = new uint256[](1);
        address[] memory tokens = new address[](1);
        (tokens[0], supplies[0]) = (address(link), LINK_SUPPLY + LINK_SUPPLY / 200);
        vm.prank(owner);
        factory.proposeSupplies(tokens, supplies);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeSupplies();
        next.startRebalance(0);
        vm.warp(block.timestamp + next.REBALANCE_DELAY());
        (,,, uint256[] memory amountsIn) = next.previewRebalance();
        address executor = makeAddr("executor");
        vm.prank(minter);
        next.transfer(executor, 0.01e18);
        for (uint256 i = 0; i < 3; ++i) {
            if (amountsIn[i] == 0 || i == 1) continue;
            MockERC20 t = i == 0 ? weth : link;
            t.mint(executor, amountsIn[i]);
            vm.prank(executor);
            t.approve(address(next), amountsIn[i]);
        }
        vm.prank(executor);
        next.acceptRebalance(_recipients(recipient), new uint256[](0));
        vm.prank(holder);
        vm.expectRevert(IHybridHubTypes.RebalanceInProgress.selector);
        old.migrate(address(next), 1e18, 1e18, to, _recipients(recipient));
    }

    // ---------------------------------------------------------------------
    // evidence: a payout Ethereum never sent
    // ---------------------------------------------------------------------

    function _record(address index) internal view returns (IHybridHubTypes.IndexRecord memory r) {
        r.tokens = vault.indexTokens(index);
        uint256 n = r.tokens.length;
        r.balances = new uint256[](n);
        r.paid = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            r.balances[i] = vault.balance(index, r.tokens[i]);
            r.paid[i] = vault.paidTotal(index, r.tokens[i]);
        }
    }

    /// @dev Delivers a message `emitter` never sent, as P1 and P2 both broken would let an attacker.
    function _forgeMessage(address emitter, uint8 kind, bytes memory body) internal {
        bytes memory payload = VaultMessages.encode(
            VaultMessages.Message({
                sourceChainId: block.chainid,
                kind: kind,
                destChainId: chainId,
                vault: _b32(address(vault)),
                index: emitter,
                nonce: 1e9,
                body: body
            })
        );
        bytes memory proof = abi.encode(emitter, VaultMessages.EVENT_TOPIC, keccak256(payload), abi.encode(payload));
        vault.deliver(proof, proof);
    }

    /// @dev A vault that paid an index's coins on a burn the index never sent shows it in its own records: the chain
    ///      freezes for every index, and so does the vault, which stops the forged payouts.
    function test_reportOutflow_aForgedPayoutFreezesTheChainAndTheVault() public {
        IHybridHubTypes.IndexRecord memory honest = _record(address(old));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAContradiction.selector, chainId));
        old.reportOutflow(chainId, honest, _honest(block.timestamp));

        address attacker = makeAddr("attacker");
        _forgeMessage(address(old), VaultMessages.BURN, abi.encode(bytes32(0), 0.5e18, _b32(attacker)));
        assertEq(attacker.balance, 0.5e18);
        IHybridHubTypes.IndexRecord memory r = _record(address(old));

        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVaultChain.selector, 7));
        old.reportOutflow(7, r, _honest(block.timestamp));
        IHybridHubTypes.IndexRecord memory short = _record(address(old));
        short.paid = new uint256[](0);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        old.reportOutflow(chainId, short, _honest(block.timestamp));
        short = _record(address(old));
        short.balances = new uint256[](2);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        old.reportOutflow(chainId, short, _honest(block.timestamp));
        IHybridHubTypes.IndexRecord memory wrong = _record(address(old));
        wrong.paid[0] += 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IHybridHubTypes.DigestMismatch.selector, chainId, vault.indexDigest(address(old)), _digestOf(wrong)
            )
        );
        old.reportOutflow(chainId, wrong, _honest(block.timestamp));

        vm.recordLogs();
        vm.expectEmit(address(old));
        emit IHybridHubTypes.OutflowDisproved(chainId, native, 0.5e18, 0);
        old.reportOutflow(chainId, r, _honest(block.timestamp));
        assertEq(factory.chainFreeze(chainId).until, block.timestamp + 14 days);
        _deliverAll(vm.getRecordedLogs());
        assertEq(vault.frozenUntil(), block.timestamp + 14 days, "the vault stops paying");
    }

    function _digestOf(IHybridHubTypes.IndexRecord memory r) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("xindex.v4.vault.index-digest"),
                chainId,
                address(vault),
                address(old),
                r.tokens,
                r.balances,
                r.paid
            )
        );
    }

    /// @dev Migrations count as paid out on the vault and as sent out here, so an honest migration is no evidence.
    function test_reportOutflow_anHonestMigrationIsNoEvidence() public {
        _fundLink(7.5e18);
        vm.recordLogs();
        vm.prank(holder);
        old.migrate(address(next), 1e18, 1.5e18, to, _recipients(recipient));
        _deliverAll(vm.getRecordedLogs());
        IHybridHubTypes.IndexRecord memory r = _record(address(old));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAContradiction.selector, chainId));
        old.reportOutflow(chainId, r, _honest(block.timestamp));
        r = _record(address(next));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAContradiction.selector, chainId));
        next.reportOutflow(chainId, r, _honest(block.timestamp));
    }

    /// @dev A forged migration out of an index is a payout it never sent, as a forged burn is.
    function test_reportOutflow_aForgedMigrationIsEvidence() public {
        _forgeMessage(address(old), VaultMessages.MIGRATE, abi.encode(address(next), bytes32(0), 1e18));
        assertEq(vault.balance(address(next), address(0)), 1e18);
        IHybridHubTypes.IndexRecord memory r = _record(address(old));
        old.reportOutflow(chainId, r, _honest(block.timestamp));
        assertEq(factory.chainFreeze(chainId).until, block.timestamp + 14 days);
    }

    // ---------------------------------------------------------------------
    // evidence: a claimed order's deposit proven false
    // ---------------------------------------------------------------------

    function _preimage(uint256 deposited) internal pure returns (IHybridHubTypes.ChainProof memory p) {
        p.tokens = new address[](1);
        p.totals = new uint256[](1);
        p.totals[0] = deposited;
    }

    function _openDigest(uint256 intakeId, uint256 total) internal view returns (bytes32) {
        address[] memory tokens = new address[](1);
        uint256[] memory totals = new uint256[](1);
        totals[0] = total;
        return keccak256(
            abi.encode(
                keccak256("xindex.v4.vault.intake-digest"),
                chainId,
                address(vault),
                address(old),
                intakeId,
                uint8(1),
                tokens,
                totals
            )
        );
    }

    /// @dev After its claim, an order's intake is honestly open (before the settle message arrives) or settled with
    ///      the same deposits. Anything else shows the proof it was claimed on was false: mints on the chain stop for
    ///      every index, and the vault keeps paying.
    function test_reportForgedDeposit_afterTheClaim() public {
        // Within the mint cap of the one share in issue: 4% of it.
        uint256 orderId = _settledOrder(old, minter, 0.01e18);
        IHybridHubTypes.ChainProof memory p = _preimage(0.014e18);
        p.proof = _honest(block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongStatus.selector, orderId, IHybridHubTypes.OrderStatus.Locked)
        );
        old.reportForgedDeposit(orderId, chainId, p);

        vm.warp(block.timestamp + old.MINT_LOCK());
        vm.recordLogs();
        old.claimOrder(orderId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAContradiction.selector, chainId));
        old.reportForgedDeposit(orderId, chainId, p); // still open at the vault
        _deliverAll(logs);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAContradiction.selector, chainId));
        old.reportForgedDeposit(orderId, chainId, p); // settled with the same deposits

        uint256 deadline = old.order(orderId).deadline;
        p.proof = _forged(deadline, bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ProofTooEarly.selector, chainId, deadline, deadline));
        old.reportForgedDeposit(orderId, chainId, p);
        IHybridHubTypes.ChainProof memory wrong = _preimage(0.015e18);
        wrong.proof = _forged(block.timestamp, bytes32(uint256(1)));
        // The preimage must be the one the order was settled on.
        uint256 intakeId = old.intakeIdOf(orderId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHybridHubTypes.DigestMismatch.selector,
                chainId,
                _openDigest(intakeId, wrong.totals[0]),
                _openDigest(intakeId, 0.014e18)
            )
        );
        old.reportForgedDeposit(orderId, chainId, wrong);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVaultChain.selector, 7));
        old.reportForgedDeposit(orderId, 7, p);

        p.proof = _forged(block.timestamp, bytes32(uint256(1)));
        vm.recordLogs();
        vm.expectEmit(address(old));
        emit IHybridHubTypes.DepositDisproved(orderId, chainId, bytes32(uint256(1)));
        vm.expectEmit(address(factory));
        emit IHybridIndexFactory.ChainFrozen(chainId, block.timestamp + 14 days, address(old));
        old.reportForgedDeposit(orderId, chainId, p);
        assertEq(_deliverAll(vm.getRecordedLogs()), 0, "no message to the vault");
        assertEq(vault.frozenUntil(), 0);
        // Every index's mints on the chain wait.
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.ChainIsFrozen.selector, chainId, block.timestamp + 14 days)
        );
        next.openOrder(1e18, block.timestamp + 1 hours);
    }
}
