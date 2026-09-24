// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {XindexTest} from "../XindexTest.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeToken} from "../mocks/MockFeeToken.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice Killing tests for IndexToken mutants that survive the whole offline suite (mutation-hunter, 2026-09-24).
///         Each test passes on the shipped code and fails on the mutant it names.
contract TokenMutationGapsTest is XindexTest {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, address(0));
    }

    /// @dev MH-1. `issue`'s fee-on-transfer check, `balanceOf(index) - before < amounts[i]`, is only ever exercised
    ///      on an index that holds none of the token (before == 0), where `balanceOf(index) + before < amounts[i]`
    ///      and `balanceOf(index) < amounts[i]` behave the same, so both mutants survive every offline test. Either
    ///      regression mints unbacked shares on every issue after the first, the moment a component charges a fee.
    ///      Here the index already holds the fee token, so only the shipped delta check still refuses the issue.
    function test_MH1_feeCheckRefusesAFeeTokenWhenTheIndexAlreadyHoldsSome() public {
        MockFeeToken fee = new MockFeeToken();
        _list(address(fee));
        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(fee);
        u[0] = 1e18;
        IndexToken feeIndex = IndexToken(factory.createIndex("Fee", "FEE", t, u, 0));

        // The index already holds 9.9 FEE (a 10 FEE transfer burns 1% on the way in), as it would after any donation
        // or any earlier holder's basket.
        fee.mint(address(this), 10e18);
        fee.transfer(address(feeIndex), 10e18);
        assertEq(fee.balanceOf(address(feeIndex)), 9.9e18);

        fee.mint(alice, 1e18);
        vm.startPrank(alice);
        fee.approve(address(feeIndex), 1e18);
        // One share needs 1e18 FEE and 0.99e18 arrives. The shipped check sees a delta of 0.99e18 and refuses; the
        // mutants compare 10.89e18 (+ before: 20.79e18) with 1e18 and mint a share backed by 0.99 of its basket.
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.TransferAmountMismatch.selector, address(fee)));
        feeIndex.issue(1e18, alice);
        vm.stopPrank();
        assertEq(feeIndex.totalSupply(), 0, "no share was minted against 0.99 of a basket");
    }

    /// @dev MH-E (token half). `Issued` and `Redeemed` name the caller and the recipient separately, and indexers tell
    ///      a zap's mint for a user from the user's own mint by them. Every expectEmit on them has sender == to, so
    ///      swapping the two arguments survives.
    function test_MHE_issueAndRedeemEventsNameCallerAndRecipientApart() public {
        MockERC20 tok = new MockERC20("T", "T", 18);
        _list(address(tok));
        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(tok);
        u[0] = 1e18;
        IndexToken idx = IndexToken(factory.createIndex("One", "ONE", t, u, 0));
        tok.mint(alice, 1e18);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;

        vm.startPrank(alice);
        tok.approve(address(idx), 1e18);
        vm.expectEmit(true, true, true, true, address(idx));
        emit IIndexToken.Issued(alice, bob, 1e18, amounts);
        idx.issue(1e18, bob);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, address(idx));
        emit IIndexToken.Redeemed(bob, alice, 1e18, amounts);
        vm.prank(bob);
        idx.redeem(1e18, alice);
    }
}

/// @notice Rebalance-side killing tests, on the rebalance suite's five-token basket but with units and a supply that
///         leave fractional products, so rounding actually bites.
contract TokenRebalanceMutationGapsTest is Test {
    MockMarket market;
    IndexFactory factory;
    IndexToken index;
    MockRebalanceExecutor executor;
    address[] tokens;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        executor = new MockRebalanceExecutor();
        uint256[5] memory parts = [uint256(6), 1, 1, 1, 1];
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](5);
        uint256[] memory units = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            tokens.push(address(new MockERC20("C", "C", 18)));
            configs[i] = market.configWith(tokens[i], 1e8, parts[i] * 1e24);
            // Odd units, so supply * units / 1e18 has a remainder on every leg.
            units[i] = 100e18 + 1_234_567_891 * (i + 1);
        }
        vm.startPrank(owner);
        for (uint256 i = 0; i < 5; ++i) {
            factory.proposeListing(tokens[i], configs[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < 5; ++i) {
            factory.executeListing(tokens[i]);
        }
        index = IndexToken(factory.createIndex("Rebalanced", "RBL", tokens, units, 0));
    }

    function _issue(address who, uint256 shares) internal {
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(who, need[i]);
            vm.prank(who);
            MockERC20(tokens[i]).approve(address(index), need[i]);
        }
        vm.prank(who);
        index.issue(shares, who);
    }

    /// @dev What the index holds of component i above its backing: the holders' rounding surplus.
    function _surplus(uint256 i) internal view returns (uint256) {
        (, uint256[] memory u) = index.components();
        uint256 required = index.totalSupply() * u[i] / 1e18 + index.totalClaims(tokens[i]);
        return MockERC20(tokens[i]).balanceOf(address(index)) - required;
    }

    /// @dev MH-S. The design rule says a settlement moves exactly the change in required backing, so the rounding
    ///      surplus the holders own (issue rounds up, redeem rounds down) is untouched by a fill (XA-28). The suite
    ///      pins that only with an executor that underdelivers its own `amountsIn`; nothing pins how `amountsIn` and
    ///      `amountsOut` are rounded, because every rebalance test uses products with no remainder. Both mutants
    ///      `amountsIn[i] = mulDiv(supply, next - current, 1e18)` (asks up to one raw unit less per growing leg, paid
    ///      out of the holders' surplus, or reverting RebalanceUnderfunded when there is none) and
    ///      `amountsOut[i] = mulDiv(supply, current - target, 1e18)` (sends up to one raw unit less) survive. Here the
    ///      surplus of every leg is compared across an honest fill.
    function test_MHS_aFillMovesExactlyTheChangeInBackingOnEveryLeg() public {
        _issue(alice, 3_333_333_333_333_333_350);
        uint256[] memory before = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            before[i] = _surplus(i);
        }

        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        vm.warp(eta + 7 hours + 13 minutes); // a multiplier with a remainder
        executor.execute(index, "");
        assertEq(index.rebalanceNonce(), 1, "the fill settled");

        for (uint256 i = 0; i < 5; ++i) {
            assertEq(_surplus(i), before[i], "the holders' rounding surplus moved in the fill");
        }
    }

    /// @dev MH-E (rebalance half). `RebalanceStarted` carries the keep mask, which is the only on-chain record of which
    ///      components a guardian's start routes around until `pendingRebalance` is read. Its only expectEmit is a
    ///      stranger's start with mask 0, so emitting 0 unconditionally survives.
    function test_MHE_aGuardianStartReportsItsKeepMask() public {
        _issue(alice, 10e18);
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        (uint256[] memory targets,) = index.previewTarget(1 << 1);
        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexToken.RebalanceStarted(1, 1, guardian, targets, 1 << 1, block.timestamp + index.REBALANCE_DELAY());
        vm.prank(guardian);
        index.startRebalance(1 << 1);
    }
}
