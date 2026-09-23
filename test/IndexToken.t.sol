// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "./XindexTest.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexToken} from "../src/interfaces/IIndexToken.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

/// @notice A stateless forwarding router, the shape a zap or an aggregator has: it holds nothing between calls and has
///         no way to call `claim` on anyone's behalf afterwards.
contract PassThroughRouter {
    function redeemSkippingFor(IndexToken index, uint256 shares, address to, uint256 skipMask) external {
        IIndexToken(address(index)).redeemSkipping(shares, to, skipMask);
    }
}

contract IndexTokenTest is XindexTest {
    IndexToken index;

    MockERC20 wbtc; // 8 decimals
    MockERC20 weth; // 18 decimals
    MockERC20 usdc; // 6 decimals

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // 0.001 WBTC + 0.01 WETH + 10 USDC per index token
    uint256 constant U_WBTC = 100_000;
    uint256 constant U_WETH = 1e16;
    uint256 constant U_USDC = 10e6;

    address[] tokens;
    uint256[] units;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, address(0));
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = market.weth();
        usdc = market.usdc();
        _list(address(wbtc));
        _list(address(weth));
        _list(address(usdc));

        tokens.push(address(wbtc));
        tokens.push(address(weth));
        tokens.push(address(usdc));
        units.push(U_WBTC);
        units.push(U_WETH);
        units.push(U_USDC);

        index = IndexToken(factory.createIndex("Blue Chip", "BLUE", tokens, units, 0));
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _fund(address who, uint256 shares) internal {
        uint256[] memory need = index.previewIssue(shares);
        wbtc.mint(who, need[0]);
        weth.mint(who, need[1]);
        usdc.mint(who, need[2]);
        vm.startPrank(who);
        wbtc.approve(address(index), need[0]);
        weth.approve(address(index), need[1]);
        usdc.approve(address(index), need[2]);
        vm.stopPrank();
    }

    function _required(uint256 supply, uint256 unit) internal pure returns (uint256) {
        return supply * unit / 1e18;
    }

    function _assertBacked() internal view {
        uint256 s = index.totalSupply();
        assertGe(
            wbtc.balanceOf(address(index)), _required(s, U_WBTC) + index.totalClaims(address(wbtc)), "wbtc backing"
        );
        assertGe(
            weth.balanceOf(address(index)), _required(s, U_WETH) + index.totalClaims(address(weth)), "weth backing"
        );
        assertGe(
            usdc.balanceOf(address(index)), _required(s, U_USDC) + index.totalClaims(address(usdc)), "usdc backing"
        );
    }

    // ---------------------------------------------------------------------
    // initialization
    // ---------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(index.name(), "Blue Chip");
        assertEq(index.symbol(), "BLUE");
        assertEq(index.decimals(), 18);
        assertEq(index.SHARE_UNIT(), 1e18);
        assertEq(index.FACTORY(), address(factory));
        assertEq(index.RULE(), factory.RULE());
        assertEq(index.methodology(), 0);
        assertEq(index.rebalanceNonce(), 0);
        assertEq(index.lastRebalance(), block.timestamp);
        assertEq(index.componentCount(), 3);
        (address[] memory t, uint256[] memory u) = index.components();
        assertEq(t.length, 3);
        assertEq(t[0], address(wbtc));
        assertEq(t[1], address(weth));
        assertEq(t[2], address(usdc));
        assertEq(u[0], U_WBTC);
        assertEq(u[1], U_WETH);
        assertEq(u[2], U_USDC);
        address[] memory onlyTokens = index.componentTokens();
        assertEq(onlyTokens.length, 3);
        assertEq(onlyTokens[2], address(usdc));
    }

    function test_constructor_rejectsZeroRule() public {
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new IndexToken(address(0));
    }

    function test_cannotReinitialize() public {
        vm.prank(address(factory));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        index.initialize("x", "x", tokens, units, 0);
    }

    function test_implementationCannotBeInitialized() public {
        IndexToken impl = IndexToken(factory.IMPLEMENTATION());
        vm.prank(address(factory));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize("x", "x", tokens, units, 0);
    }

    function test_nonFactoryCannotInitializeFreshClone() public {
        IndexToken rogue = IndexToken(Clones.clone(factory.IMPLEMENTATION()));
        vm.expectRevert(IIndexToken.NotFactory.selector);
        rogue.initialize("x", "x", tokens, units, 0);
    }

    /// @dev The factory validates inputs before initializing, so these branches are only reachable
    ///      by calling a fresh clone as the factory.
    function test_initialize_rejectsBadComponents() public {
        IndexToken fresh = IndexToken(Clones.clone(factory.IMPLEMENTATION()));
        address[] memory t;
        uint256[] memory u;

        vm.startPrank(address(factory));

        vm.expectRevert(IIndexToken.InvalidComponents.selector);
        fresh.initialize("x", "x", t, u, 0);

        t = new address[](1);
        u = new uint256[](2);
        t[0] = address(wbtc);
        vm.expectRevert(IIndexToken.InvalidComponents.selector);
        fresh.initialize("x", "x", t, u, 0);

        u = new uint256[](1);
        u[0] = 1;
        t[0] = address(0);
        vm.expectRevert(IIndexToken.InvalidComponents.selector);
        fresh.initialize("x", "x", t, u, 0);

        t[0] = address(wbtc);
        u[0] = 0;
        vm.expectRevert(IIndexToken.InvalidComponents.selector);
        fresh.initialize("x", "x", t, u, 0);

        u[0] = uint256(type(uint96).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, u[0]));
        fresh.initialize("x", "x", t, u, 0);

        u[0] = type(uint96).max;
        fresh.initialize("x", "x", t, u, 0);
        vm.stopPrank();
        (, uint256[] memory uu) = fresh.components();
        assertEq(uu[0], type(uint96).max);
    }

    function test_uninitializedInstancesCannotIssueOrRedeem() public {
        IndexToken impl = IndexToken(factory.IMPLEMENTATION());
        IndexToken rogue = IndexToken(Clones.clone(address(impl)));

        vm.expectRevert(IIndexToken.NotInitialized.selector);
        impl.issue(1_000_000e18, alice);
        vm.expectRevert(IIndexToken.NotInitialized.selector);
        rogue.issue(42e18, alice);
        vm.expectRevert(IIndexToken.NotInitialized.selector);
        rogue.redeem(1, alice);
        vm.expectRevert(IIndexToken.NotInitialized.selector);
        rogue.redeemSkipping(1, alice, 1);
        assertEq(impl.totalSupply(), 0);
        assertEq(rogue.totalSupply(), 0);

        // DA-22: and they say so. `lastRebalance` is zero on an uninitialized instance, so the rebalance-due
        // predicate used to answer true for a clone that can never rebalance at all.
        assertFalse(impl.canStartRebalance(), "the implementation is not waiting to be rebalanced");
        assertFalse(rogue.canStartRebalance(), "nor is a clone deployed outside the factory");
        vm.expectRevert(IIndexToken.NotInitialized.selector);
        rogue.startRebalance(0);
    }

    // ---------------------------------------------------------------------
    // issue
    // ---------------------------------------------------------------------

    function test_issue_oneShare() public {
        _fund(alice, 1e18);
        uint256[] memory expected = new uint256[](3);
        expected[0] = U_WBTC;
        expected[1] = U_WETH;
        expected[2] = U_USDC;

        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexToken.Issued(alice, alice, 1e18, expected);
        vm.prank(alice);
        index.issue(1e18, alice);

        assertEq(index.balanceOf(alice), 1e18);
        assertEq(index.totalSupply(), 1e18);
        assertEq(wbtc.balanceOf(address(index)), U_WBTC);
        assertEq(weth.balanceOf(address(index)), U_WETH);
        assertEq(usdc.balanceOf(address(index)), U_USDC);
        assertEq(wbtc.balanceOf(alice), 0);
        _assertBacked();
    }

    function test_issue_toOtherAddress() public {
        _fund(alice, 5e17);
        vm.prank(alice);
        index.issue(5e17, bob);
        assertEq(index.balanceOf(bob), 5e17);
        assertEq(index.balanceOf(alice), 0);
    }

    function test_issue_roundsUp() public {
        uint256[] memory need = index.previewIssue(1);
        assertEq(need[0], 1);
        assertEq(need[1], 1);
        assertEq(need[2], 1);

        need = index.previewIssue(1e18 - 1);
        assertEq(need[0], U_WBTC);
        assertEq(need[1], U_WETH);
        assertEq(need[2], U_USDC);

        _fund(alice, 1);
        vm.prank(alice);
        index.issue(1, alice);
        _assertBacked();
    }

    function test_issue_revertsZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(IIndexToken.ZeroShares.selector);
        index.issue(0, alice);
    }

    function test_issue_revertsBadRecipients() public {
        _fund(alice, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        index.issue(1e18, address(0));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        index.issue(1e18, address(index));
        vm.stopPrank();
    }

    function test_issue_revertsWithoutApproval() public {
        uint256[] memory need = index.previewIssue(1e18);
        wbtc.mint(alice, need[0]);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(index), 0, need[0])
        );
        index.issue(1e18, alice);
    }

    function test_issue_rejectsFeeOnTransferToken() public {
        MockFeeToken fee = new MockFeeToken();
        _list(address(fee));

        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(fee);
        u[0] = 1e18;
        IndexToken feeIndex = IndexToken(factory.createIndex("Fee", "FEE", t, u, 0));

        fee.mint(alice, 10e18);
        vm.startPrank(alice);
        fee.approve(address(feeIndex), 10e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.TransferAmountMismatch.selector, address(fee)));
        feeIndex.issue(1e18, alice);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // redeem
    // ---------------------------------------------------------------------

    function test_redeem_full() public {
        _fund(alice, 2e18);
        vm.prank(alice);
        index.issue(2e18, alice);

        uint256[] memory expected = new uint256[](3);
        expected[0] = 2 * U_WBTC;
        expected[1] = 2 * U_WETH;
        expected[2] = 2 * U_USDC;

        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexToken.Redeemed(alice, alice, 2e18, expected);
        vm.prank(alice);
        index.redeem(2e18, alice);

        assertEq(index.totalSupply(), 0);
        assertEq(index.balanceOf(alice), 0);
        assertEq(wbtc.balanceOf(alice), 2 * U_WBTC);
        assertEq(weth.balanceOf(alice), 2 * U_WETH);
        assertEq(usdc.balanceOf(alice), 2 * U_USDC);
        assertEq(wbtc.balanceOf(address(index)), 0);
    }

    function test_redeem_toOtherAddress() public {
        _fund(alice, 1e18);
        vm.startPrank(alice);
        index.issue(1e18, alice);
        index.redeem(1e18, bob);
        vm.stopPrank();
        assertEq(wbtc.balanceOf(bob), U_WBTC);
        assertEq(wbtc.balanceOf(alice), 0);
    }

    function test_redeem_roundsDown_keepsBacking() public {
        _fund(alice, 1e18);
        vm.startPrank(alice);
        index.issue(1e18, alice);

        uint256[] memory out = index.previewRedeem(1);
        assertEq(out[0], 0);
        assertEq(out[1], 0);
        assertEq(out[2], 0);
        index.redeem(1, alice);
        vm.stopPrank();

        assertEq(index.totalSupply(), 1e18 - 1);
        assertEq(wbtc.balanceOf(alice), 0);
        _assertBacked();
    }

    function test_redeem_revertsZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(IIndexToken.ZeroShares.selector);
        index.redeem(0, alice);
    }

    function test_redeem_revertsBadRecipients() public {
        _fund(alice, 1e18);
        vm.startPrank(alice);
        index.issue(1e18, alice);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        index.redeem(1e18, address(0));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        index.redeem(1e18, address(index));
        vm.stopPrank();
    }

    function test_redeem_revertsInsufficientBalance() public {
        _fund(alice, 1e18);
        vm.startPrank(alice);
        index.issue(1e18, alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 1e18 + 1));
        index.redeem(1e18 + 1, alice);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // redeemSkipping and claim
    // ---------------------------------------------------------------------

    function test_redeemSkipping_paysTheRestAndRecordsClaims() public {
        _fund(alice, 2e18);
        vm.prank(alice);
        index.issue(2e18, alice);

        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexToken.ClaimRecorded(bob, address(wbtc), U_WBTC);
        vm.prank(alice);
        index.redeemSkipping(1e18, bob, 1 << 0);

        assertEq(index.balanceOf(alice), 1e18);
        assertEq(wbtc.balanceOf(bob), 0);
        assertEq(weth.balanceOf(bob), U_WETH);
        assertEq(usdc.balanceOf(bob), U_USDC);
        assertEq(index.claimOf(bob, address(wbtc)), U_WBTC, "the claim follows the components, to the recipient");
        assertEq(index.claimOf(alice, address(wbtc)), 0);
        assertEq(index.totalClaims(address(wbtc)), U_WBTC);
        assertEq(wbtc.balanceOf(address(index)), 2 * U_WBTC);
        _assertBacked();
    }

    /// @dev DA-17. The claim was booked to msg.sender while every other component went to `to`, so a router that
    ///      redeemed on a holder's behalf kept the claim; a stateless one strands the skipped components for good.
    ///      The claim now follows the components to the recipient.
    function test_DA17_aRouterRedemptionLeavesTheClaimWithTheHolder() public {
        PassThroughRouter router = new PassThroughRouter();
        _fund(alice, 1e18);
        vm.startPrank(alice);
        index.issue(1e18, alice);
        index.transfer(address(router), 1e18);
        vm.stopPrank();

        router.redeemSkippingFor(index, 1e18, alice, 1 << 0);

        assertEq(index.claimOf(address(router), address(wbtc)), 0, "the router keeps nothing it could never collect");
        assertEq(index.claimOf(alice, address(wbtc)), U_WBTC, "the holder owns the claim");
        assertEq(weth.balanceOf(alice), U_WETH, "and already has the components that were not skipped");

        vm.prank(alice);
        assertEq(index.claim(address(wbtc), alice), U_WBTC, "and can collect the rest without the router's help");
        assertEq(wbtc.balanceOf(alice), U_WBTC);
        assertEq(index.totalClaims(address(wbtc)), 0);
        _assertBacked();
    }

    function test_redeemSkipping_claimsAccumulate() public {
        _fund(alice, 2e18);
        vm.startPrank(alice);
        index.issue(2e18, alice);
        index.redeemSkipping(1e18, alice, 1 << 1);
        index.redeemSkipping(1e18, alice, 1 << 1);
        vm.stopPrank();
        assertEq(index.claimOf(alice, address(weth)), 2 * U_WETH);
        assertEq(index.totalClaims(address(weth)), 2 * U_WETH);
        assertEq(index.totalSupply(), 0);
        _assertBacked();
    }

    function test_redeemSkipping_zeroAmountRecordsNoClaim() public {
        _fund(alice, 1e18);
        vm.startPrank(alice);
        index.issue(1e18, alice);
        index.redeemSkipping(1, alice, 1 << 0);
        vm.stopPrank();
        assertEq(index.claimOf(alice, address(wbtc)), 0);
        assertEq(index.totalClaims(address(wbtc)), 0);
        assertEq(index.totalSupply(), 1e18 - 1);
        _assertBacked();
    }

    function test_redeemSkipping_revertsInvalidMask() public {
        _fund(alice, 1e18);
        vm.startPrank(alice);
        index.issue(1e18, alice);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.InvalidSkipMask.selector, 0));
        index.redeemSkipping(1e18, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.InvalidSkipMask.selector, 1 << 3));
        index.redeemSkipping(1e18, alice, 1 << 3);
        vm.stopPrank();
    }

    function test_redeemSkipping_revertsZeroSharesAndBadRecipients() public {
        _fund(alice, 1e18);
        vm.startPrank(alice);
        index.issue(1e18, alice);
        vm.expectRevert(IIndexToken.ZeroShares.selector);
        index.redeemSkipping(0, alice, 1);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        index.redeemSkipping(1e18, address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        index.redeemSkipping(1e18, address(index), 1);
        vm.stopPrank();
    }

    function test_claim_paysAndClears() public {
        _fund(alice, 1e18);
        vm.startPrank(alice);
        index.issue(1e18, alice);
        index.redeemSkipping(1e18, alice, (1 << 0) | (1 << 2));

        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexToken.Claimed(alice, bob, address(wbtc), U_WBTC);
        uint256 paid = index.claim(address(wbtc), bob);
        vm.stopPrank();

        assertEq(paid, U_WBTC);
        assertEq(wbtc.balanceOf(bob), U_WBTC);
        assertEq(index.claimOf(alice, address(wbtc)), 0);
        assertEq(index.totalClaims(address(wbtc)), 0);
        assertEq(index.claimOf(alice, address(usdc)), U_USDC);
        assertEq(weth.balanceOf(alice), U_WETH);
        assertEq(index.totalSupply(), 0);
        _assertBacked();
    }

    function test_claim_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.NothingToClaim.selector, address(wbtc)));
        index.claim(address(wbtc), alice);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        index.claim(address(wbtc), address(0));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        index.claim(address(wbtc), address(index));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // permit
    // ---------------------------------------------------------------------

    function test_permit() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        _fund(signer, 1e18);
        vm.prank(signer);
        index.issue(1e18, signer);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                bob,
                1e18,
                index.nonces(signer),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", index.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        index.permit(signer, bob, 1e18, deadline, v, r, s);
        assertEq(index.allowance(signer, bob), 1e18);
        assertEq(index.nonces(signer), 1);

        vm.prank(bob);
        index.transferFrom(signer, bob, 1e18);
        assertEq(index.balanceOf(bob), 1e18);
    }

    // ---------------------------------------------------------------------
    // fuzz
    // ---------------------------------------------------------------------

    function testFuzz_issueThenRedeem_roundTrip(uint256 shares) public {
        shares = bound(shares, 1, 1_000_000e18);
        _fund(alice, shares);
        uint256[] memory paid = index.previewIssue(shares);

        vm.startPrank(alice);
        index.issue(shares, alice);
        _assertBacked();
        index.redeem(shares, alice);
        vm.stopPrank();

        uint256[] memory got = index.previewRedeem(shares);
        assertEq(wbtc.balanceOf(alice), got[0]);
        assertEq(weth.balanceOf(alice), got[1]);
        assertEq(usdc.balanceOf(alice), got[2]);
        assertLe(paid[0] - got[0], 1);
        assertLe(paid[1] - got[1], 1);
        assertLe(paid[2] - got[2], 1);
        assertEq(index.totalSupply(), 0);
        _assertBacked();
    }

    function testFuzz_partialRedeem_keepsBacking(uint256 issued, uint256 redeemed) public {
        issued = bound(issued, 1, 1_000_000e18);
        redeemed = bound(redeemed, 1, issued);
        _fund(alice, issued);
        vm.startPrank(alice);
        index.issue(issued, alice);
        index.redeem(redeemed, alice);
        vm.stopPrank();
        assertEq(index.totalSupply(), issued - redeemed);
        _assertBacked();
    }

    function testFuzz_redeemSkippingThenClaim_keepsBacking(uint256 shares, uint256 mask) public {
        shares = bound(shares, 1, 1_000_000e18);
        mask = bound(mask, 1, 7);
        _fund(alice, shares);
        uint256[] memory owed = index.previewRedeem(shares);

        vm.prank(alice);
        index.issue(shares, alice);
        vm.prank(alice);
        index.redeemSkipping(shares, bob, mask);
        _assertBacked();
        // The claim belongs to the recipient, so the recipient is who can collect it (DA-17).
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(index.claimOf(alice, tokens[i]), 0, "the caller keeps no claim of its own");
            if (index.claimOf(bob, tokens[i]) != 0) {
                vm.prank(bob);
                index.claim(tokens[i], bob);
            }
        }

        assertEq(wbtc.balanceOf(bob), owed[0]);
        assertEq(weth.balanceOf(bob), owed[1]);
        assertEq(usdc.balanceOf(bob), owed[2]);
        assertEq(index.totalClaims(address(wbtc)), 0);
        assertEq(index.totalClaims(address(weth)), 0);
        assertEq(index.totalClaims(address(usdc)), 0);
        _assertBacked();
    }

    // ---------------------------------------------------------------------
    // Security audit of 2026-09-23
    // ---------------------------------------------------------------------

    /// @dev CR-I01. The recipient rule covered only issue, redeem, redeemSkipping and claim: a plain `transfer` of
    ///      shares to the index itself, a common wallet slip, went through, and the shares could never leave again,
    ///      since the index never moves, approves or redeems its own shares and cannot sign a permit. Their backing
    ///      stayed stranded beside them. Every transfer to the index is refused now, `transferFrom` included.
    function test_CRI01_sharesCannotBeSentToTheIndexItself() public {
        _fund(alice, 2e18);
        vm.prank(alice);
        index.issue(2e18, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        index.transfer(address(index), 1e18);

        vm.prank(alice);
        index.approve(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        index.transferFrom(alice, address(index), 1e18);
        assertEq(index.balanceOf(address(index)), 0, "nothing was locked in the index");

        // Every other move still works: a transfer, a transferFrom and the in-kind exit.
        vm.prank(alice);
        index.transfer(bob, 5e17);
        vm.prank(bob);
        index.transferFrom(alice, bob, 5e17);
        vm.prank(bob);
        index.redeem(1e18, bob);
        assertEq(wbtc.balanceOf(bob), U_WBTC, "the backing of a share sent anywhere else is still redeemable");
        _assertBacked();
    }

    /// @dev CR-I25. DA-22 made `canStartRebalance` answer false for an instance that was never initialized, but its
    ///      test ran at a timestamp below MIN_REBALANCE_INTERVAL, where `lastRebalance` of zero plus 28 days is still
    ///      in the future and the view answers false without the fix. At a mainnet timestamp only the initialization
    ///      check stands between the implementation, or a clone deployed outside the factory, and an answer of true.
    function test_CRI25_anUninitializedInstanceIsNeverDueAtAMainnetTimestamp() public {
        IndexToken impl = IndexToken(factory.IMPLEMENTATION());
        IndexToken rogue = IndexToken(Clones.clone(address(impl)));
        vm.warp(1_790_000_000); // September 2026
        assertGe(block.timestamp, impl.lastRebalance() + impl.MIN_REBALANCE_INTERVAL(), "the interval is long past");
        assertFalse(impl.canStartRebalance(), "the implementation is not waiting to be rebalanced");
        assertFalse(rogue.canStartRebalance(), "nor is a clone deployed outside the factory");
        vm.expectRevert(IIndexToken.NotInitialized.selector);
        rogue.startRebalance(0);
    }

    /// @dev CR-I33. Every permit test signed against `DOMAIN_SEPARATOR()` read back from the index, so each agreed with
    ///      whatever domain the index held, the empty one a clone would keep without `__ERC20Permit_init` included. A
    ///      wallet builds the domain itself, from the token's name and version "1", and that is what has to verify.
    function test_CRI33_aWalletsPermitVerifiesAgainstTheIndexsOwnName() public {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = index.eip712Domain();
        assertEq(name, "Blue Chip", "the domain carries the index's name");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(index));

        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(index.name())),
                keccak256(bytes("1")),
                block.chainid,
                address(index)
            )
        );
        assertEq(index.DOMAIN_SEPARATOR(), domain);

        (address signer, uint256 pk) = makeAddrAndKey("wallet");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                bob,
                1e18,
                0,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        index.permit(signer, bob, 1e18, deadline, v, r, s);
        assertEq(index.allowance(signer, bob), 1e18, "a permit signed the way a wallet signs it verifies");
    }
}
