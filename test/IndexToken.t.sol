// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IIndexToken} from "../src/interfaces/IIndexToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";

contract IndexTokenTest is Test {
    IndexFactory factory;
    IndexToken index;

    MockERC20 wbtc; // 8 decimals
    MockERC20 weth; // 18 decimals
    MockERC20 usdc; // 6 decimals

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // 0.001 WBTC + 0.01 WETH + 10 USDC per index token
    uint256 constant U_WBTC = 100_000;
    uint256 constant U_WETH = 1e16;
    uint256 constant U_USDC = 10e6;

    address[] tokens;
    uint256[] units;

    function setUp() public {
        factory = new IndexFactory(owner, address(0));
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        _list(address(wbtc));
        _list(address(weth));
        _list(address(usdc));

        tokens.push(address(wbtc));
        tokens.push(address(weth));
        tokens.push(address(usdc));
        units.push(U_WBTC);
        units.push(U_WETH);
        units.push(U_USDC);

        index = IndexToken(factory.createIndex("Blue Chip", "BLUE", tokens, units));
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _list(address token) internal {
        vm.prank(owner);
        factory.proposeListing(token);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

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

    function test_cannotReinitialize() public {
        vm.prank(address(factory));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        index.initialize("x", "x", tokens, units);
    }

    function test_implementationCannotBeInitialized() public {
        IndexToken impl = IndexToken(factory.IMPLEMENTATION());
        vm.prank(address(factory));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize("x", "x", tokens, units);
    }

    function test_nonFactoryCannotInitializeFreshClone() public {
        IndexToken rogue = IndexToken(Clones.clone(factory.IMPLEMENTATION()));
        vm.expectRevert(IIndexToken.NotFactory.selector);
        rogue.initialize("x", "x", tokens, units);
    }

    /// @dev The factory validates inputs before initializing, so these branches are only reachable
    ///      by calling a fresh clone as the factory.
    function test_initialize_rejectsBadComponents() public {
        IndexToken fresh = IndexToken(Clones.clone(factory.IMPLEMENTATION()));
        address[] memory t;
        uint256[] memory u;

        vm.startPrank(address(factory));

        vm.expectRevert(IIndexToken.InvalidComponents.selector);
        fresh.initialize("x", "x", t, u);

        t = new address[](1);
        u = new uint256[](2);
        t[0] = address(wbtc);
        vm.expectRevert(IIndexToken.InvalidComponents.selector);
        fresh.initialize("x", "x", t, u);

        u = new uint256[](1);
        u[0] = 1;
        t[0] = address(0);
        vm.expectRevert(IIndexToken.InvalidComponents.selector);
        fresh.initialize("x", "x", t, u);

        t[0] = address(wbtc);
        u[0] = 0;
        vm.expectRevert(IIndexToken.InvalidComponents.selector);
        fresh.initialize("x", "x", t, u);

        u[0] = uint256(type(uint96).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, u[0]));
        fresh.initialize("x", "x", t, u);

        u[0] = type(uint96).max;
        fresh.initialize("x", "x", t, u);
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
        vm.expectRevert(IIndexToken.ZeroAddress.selector);
        index.issue(1e18, address(0));
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.InvalidRecipient.selector, address(index)));
        index.issue(1e18, address(index));
        vm.stopPrank();
    }

    function test_issue_revertsWithoutApproval() public {
        uint256[] memory need = index.previewIssue(1e18);
        wbtc.mint(alice, need[0]);
        vm.prank(alice);
        vm.expectRevert();
        index.issue(1e18, alice);
    }

    function test_issue_rejectsFeeOnTransferToken() public {
        MockFeeToken fee = new MockFeeToken();
        _list(address(fee));

        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(fee);
        u[0] = 1e18;
        IndexToken feeIndex = IndexToken(factory.createIndex("Fee", "FEE", t, u));

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
        vm.expectRevert(IIndexToken.ZeroAddress.selector);
        index.redeem(1e18, address(0));
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.InvalidRecipient.selector, address(index)));
        index.redeem(1e18, address(index));
        vm.stopPrank();
    }

    function test_redeem_revertsInsufficientBalance() public {
        _fund(alice, 1e18);
        vm.startPrank(alice);
        index.issue(1e18, alice);
        vm.expectRevert();
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
        emit IIndexToken.ClaimRecorded(alice, address(wbtc), U_WBTC);
        vm.prank(alice);
        index.redeemSkipping(1e18, bob, 1 << 0);

        assertEq(index.balanceOf(alice), 1e18);
        assertEq(wbtc.balanceOf(bob), 0);
        assertEq(weth.balanceOf(bob), U_WETH);
        assertEq(usdc.balanceOf(bob), U_USDC);
        assertEq(index.claimOf(alice, address(wbtc)), U_WBTC);
        assertEq(index.claimOf(bob, address(wbtc)), 0);
        assertEq(index.totalClaims(address(wbtc)), U_WBTC);
        assertEq(wbtc.balanceOf(address(index)), 2 * U_WBTC);
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
        vm.expectRevert(IIndexToken.ZeroAddress.selector);
        index.redeemSkipping(1e18, address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.InvalidRecipient.selector, address(index)));
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
        vm.expectRevert(IIndexToken.ZeroAddress.selector);
        index.claim(address(wbtc), address(0));
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.InvalidRecipient.selector, address(index)));
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

        vm.startPrank(alice);
        index.issue(shares, alice);
        index.redeemSkipping(shares, bob, mask);
        _assertBacked();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (index.claimOf(alice, tokens[i]) != 0) index.claim(tokens[i], bob);
        }
        vm.stopPrank();

        assertEq(wbtc.balanceOf(bob), owed[0]);
        assertEq(weth.balanceOf(bob), owed[1]);
        assertEq(usdc.balanceOf(bob), owed[2]);
        assertEq(index.totalClaims(address(wbtc)), 0);
        assertEq(index.totalClaims(address(weth)), 0);
        assertEq(index.totalClaims(address(usdc)), 0);
        _assertBacked();
    }
}
