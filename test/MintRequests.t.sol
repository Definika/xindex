// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {MintRequests} from "../src/MintRequests.sol";
import {IMintRequests} from "../src/interfaces/IMintRequests.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {XindexTest} from "./XindexTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHookToken} from "./mocks/MockHookToken.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// @notice A filler that, when it is paid, tries to re-enter the contract that paid it and records how that ended.
contract ReentrantFiller {
    MintRequests internal immutable REQUESTS;
    uint256 public target;
    bytes public reentryError;
    bool public reentered;

    constructor(MintRequests requests) {
        REQUESTS = requests;
    }

    function setTarget(uint256 id) external {
        target = id;
    }

    function fill(uint256 id, uint256 amount, address token) external {
        MockERC20(token).approve(address(REQUESTS), amount);
        REQUESTS.fill(id, amount);
    }

    function onTokenReceived(address, uint256) external {
        (reentered, reentryError) = address(REQUESTS).call(abi.encodeCall(MintRequests.cancel, (target)));
    }
}

/// @notice Escrowed mint and redeem requests: the escrow is what arrived, the requester gets at least their limit,
///         every request closes once, and nothing reads a price.
/// @dev An index of two 18-decimal components listed at 100e18 each and created at k = 1e36, so a share needs 100e18 of
///      each. USDC is the market's 6-decimal mock and USDT the mainnet-shaped mock with its fee switch.
contract MintRequestsTest is XindexTest {
    MintRequests requests;
    WeightedHub index;
    MockERC20 usdc;
    MockUSDT usdt;
    address[] components;

    address alice = makeAddr("alice");
    address minter = makeAddr("minter");
    address stranger = makeAddr("stranger");

    /// @dev Each component's units per whole index token.
    uint256 constant UNITS = 100e18;
    uint256 constant DAY = 1 days;

    function setUp() public {
        market = new MockMarket();
        _deployFactory(makeAddr("guardian"));
        usdc = market.usdc();
        usdt = new MockUSDT();
        requests = new MintRequests(address(factory), address(usdc), address(usdt));
        for (uint256 i = 0; i < 2; ++i) {
            components.push(address(new MockERC20("C", "C", 18)));
            _listWith(components[i]);
        }
        index = _createIndex("Requested", "REQ", components, _pair(UNITS, UNITS));
        _issueTo(minter, 10e18);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _issueTo(address who, uint256 shares) internal {
        uint256[] memory need = index.previewIssue(shares);
        vm.startPrank(who);
        for (uint256 i = 0; i < components.length; ++i) {
            MockERC20(components[i]).mint(who, need[i]);
            MockERC20(components[i]).approve(address(index), need[i]);
        }
        index.issue(shares, who);
        vm.stopPrank();
    }

    function _fund(address who, address stable, uint256 amount) internal {
        if (stable == address(usdt)) usdt.mint(who, amount);
        else usdc.mint(who, amount);
        vm.prank(who);
        if (stable == address(usdt)) usdt.approve(address(requests), amount);
        else usdc.approve(address(requests), amount);
    }

    function _requestMint(address stable, uint256 amount, uint256 minShares) internal returns (uint256 id) {
        _fund(alice, stable, amount);
        vm.prank(alice);
        id = requests.requestMint(address(index), stable, amount, minShares, block.timestamp + DAY);
    }

    function _requestRedeem(uint256 shares, address stable, uint256 minOut) internal returns (uint256 id) {
        vm.prank(minter);
        index.transfer(alice, shares);
        vm.startPrank(alice);
        index.approve(address(requests), shares);
        id = requests.requestRedeem(address(index), shares, stable, minOut, block.timestamp + DAY);
        vm.stopPrank();
    }

    function _balance(address token, address who) internal view returns (uint256) {
        return MockERC20(token).balanceOf(who);
    }

    // ---------------------------------------------------------------------
    // construction
    // ---------------------------------------------------------------------

    function test_constructor() public {
        assertEq(requests.FACTORY(), address(factory));
        assertEq(requests.USDC(), address(usdc));
        assertEq(requests.USDT(), address(usdt));
        assertEq(requests.MAX_REQUEST_DURATION(), 30 days);
        assertEq(requests.requestCount(), 0);

        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new MintRequests(address(0), address(usdc), address(usdt));
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new MintRequests(address(factory), address(0), address(usdt));
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new MintRequests(address(factory), address(usdc), address(0));
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.NotAStable.selector, address(usdc)));
        new MintRequests(address(factory), address(usdc), address(usdc));
    }

    // ---------------------------------------------------------------------
    // requests
    // ---------------------------------------------------------------------

    function test_requestMint_escrowsAndRecords() public {
        _fund(alice, address(usdc), 250e6);
        uint256 deadline = block.timestamp + DAY;
        vm.expectEmit(address(requests));
        emit IMintRequests.MintRequested(1, alice, address(index), address(usdc), 250e6, 1e18, deadline);
        vm.prank(alice);
        uint256 id = requests.requestMint(address(index), address(usdc), 250e6, 1e18, deadline);

        assertEq(id, 1);
        assertEq(requests.requestCount(), 1);
        assertEq(_balance(address(usdc), address(requests)), 250e6);
        IMintRequests.Request memory r = requests.getRequest(id);
        assertEq(r.requester, alice);
        assertEq(r.deadline, deadline);
        assertTrue(r.isMint);
        assertTrue(r.open);
        assertEq(r.index, address(index));
        assertEq(r.stable, address(usdc));
        assertEq(r.escrow, 250e6);
        assertEq(r.limit, 1e18);
    }

    function test_requestRedeem_escrowsShares() public {
        uint256 id = _requestRedeem(2e18, address(usdt), 500e6);
        assertEq(index.balanceOf(address(requests)), 2e18);
        IMintRequests.Request memory r = requests.getRequest(id);
        assertFalse(r.isMint);
        assertEq(r.escrow, 2e18);
        assertEq(r.limit, 500e6);
        assertEq(r.stable, address(usdt));
    }

    /// @dev The escrow is what arrived. With USDT's fee on, a request for 1,000 USDT escrows 999: the contract never
    ///      records more than it holds, so the last refund can never come up short.
    function test_requestMint_escrowIsWhatArrivedUnderAUsdtFee() public {
        usdt.setParams(10, 5);
        uint256 id = _requestMint(address(usdt), 1_000e6, 1e18);
        assertEq(requests.getRequest(id).escrow, 999e6);
        assertEq(_balance(address(usdt), address(requests)), 999e6);
    }

    /// @dev A donation sitting in the contract is not anyone's escrow: the next request records only its own transfer.
    function test_requestMint_aDonationIsNotEscrow() public {
        usdc.mint(address(requests), 7e6);
        uint256 id = _requestMint(address(usdc), 100e6, 1e18);
        assertEq(requests.getRequest(id).escrow, 100e6);
    }

    function test_requests_revertOnBadArguments() public {
        _fund(alice, address(usdc), 100e6);
        uint256 deadline = block.timestamp + DAY;
        vm.startPrank(alice);

        address rogue = Clones.clone(factory.IMPLEMENTATION());
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, rogue));
        requests.requestMint(rogue, address(usdc), 100e6, 1e18, deadline);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(usdc)));
        requests.requestRedeem(address(usdc), 1e18, address(usdc), 1e6, deadline);

        vm.expectRevert(abi.encodeWithSelector(IMintRequests.NotAStable.selector, components[0]));
        requests.requestMint(address(index), components[0], 100e6, 1e18, deadline);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.NotAStable.selector, address(index)));
        requests.requestRedeem(address(index), 1e18, address(index), 1e6, deadline);

        vm.expectRevert(IMintRequests.ZeroAmount.selector);
        requests.requestMint(address(index), address(usdc), 0, 1e18, deadline);
        vm.expectRevert(IMintRequests.ZeroAmount.selector);
        requests.requestMint(address(index), address(usdc), 100e6, 0, deadline);
        vm.expectRevert(IMintRequests.ZeroAmount.selector);
        requests.requestRedeem(address(index), 0, address(usdc), 1e6, deadline);
        vm.expectRevert(IMintRequests.ZeroAmount.selector);
        requests.requestRedeem(address(index), 1e18, address(usdc), 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(IMintRequests.InvalidDeadline.selector, block.timestamp));
        requests.requestMint(address(index), address(usdc), 100e6, 1e18, block.timestamp);
        uint256 tooFar = block.timestamp + requests.MAX_REQUEST_DURATION() + 1;
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.InvalidDeadline.selector, tooFar));
        requests.requestMint(address(index), address(usdc), 100e6, 1e18, tooFar);
        vm.stopPrank();

        // Both ends inclusive of what is allowed: one second from now, and exactly the maximum.
        vm.prank(alice);
        requests.requestMint(address(index), address(usdc), 50e6, 1e18, block.timestamp + 1);
        vm.prank(alice);
        requests.requestMint(address(index), address(usdc), 50e6, 1e18, tooFar - 1);
        assertEq(requests.requestCount(), 2);
    }

    /// @dev A transfer that leaves nothing behind is refused rather than recorded as an empty escrow.
    function test_requestMint_revertsWhenNothingArrives() public {
        usdt.setParams(10_000, type(uint128).max); // the mock can charge a whole transfer; mainnet caps it at 0.2%
        _fund(alice, address(usdt), 100e6);
        vm.prank(alice);
        vm.expectRevert(IMintRequests.NothingEscrowed.selector);
        requests.requestMint(address(index), address(usdt), 100e6, 1e18, block.timestamp + DAY);
    }

    /// @dev Tether checks only the sender of a `transferFrom`, so a MintRequests it has blacklisted would still take a
    ///      new USDT escrow that could then never leave: `cancel`, `refund` and every fill pay out with `transfer`,
    ///      which Tether refuses from a blacklisted sender. A mint request first sends itself nothing, which fails
    ///      exactly when the way out is shut, so the deposit is refused instead of trapped.
    function test_SA01_aBlacklistedContractTakesNoNewUsdtEscrow() public {
        usdt.addBlackList(address(requests));
        _fund(alice, address(usdt), 100e6);
        vm.prank(alice);
        vm.expectRevert("USDT: blacklisted");
        requests.requestMint(address(index), address(usdt), 100e6, 1e18, block.timestamp + DAY);
        assertEq(usdt.balanceOf(address(requests)), 0, "nothing was taken");

        usdt.removeBlackList(address(requests));
        vm.prank(alice);
        requests.requestMint(address(index), address(usdt), 100e6, 1e18, block.timestamp + DAY);
        assertEq(usdt.balanceOf(address(requests)), 100e6, "and deposits resume once the way out is open");
    }

    // ---------------------------------------------------------------------
    // fill
    // ---------------------------------------------------------------------

    function test_fill_mintPaysTheRequesterAndTheFiller() public {
        uint256 id = _requestMint(address(usdc), 300e6, 1e18);
        vm.startPrank(minter);
        index.approve(address(requests), 1e18);
        vm.expectEmit(address(requests));
        emit IMintRequests.RequestFilled(id, minter, 1e18);
        requests.fill(id, 1e18);
        vm.stopPrank();

        assertEq(index.balanceOf(alice), 1e18, "the requester gets their shares");
        assertEq(_balance(address(usdc), minter), 300e6, "the filler gets the escrow");
        assertEq(_balance(address(usdc), address(requests)), 0, "and nothing stays behind");
        assertFalse(requests.getRequest(id).open);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, id));
        requests.fill(id, 1e18);
    }

    function test_fill_redeemPaysTheRequesterAndTheFiller() public {
        uint256 id = _requestRedeem(2e18, address(usdc), 500e6);
        _fund(minter, address(usdc), 500e6);
        vm.prank(minter);
        requests.fill(id, 500e6);
        assertEq(_balance(address(usdc), alice), 500e6);
        assertEq(index.balanceOf(minter), 10e18, "the filler gets the escrowed shares back into its stock");
        assertEq(index.balanceOf(address(requests)), 0);
    }

    /// @dev What the requester gets is measured where it lands. Under USDT's fee a filler sending exactly the limit
    ///      delivers less and is refused; sending enough to cover the fee fills.
    function test_fill_redeemUnderAUsdtFeeMustDeliverTheLimitAfterTheFee() public {
        uint256 id = _requestRedeem(1e18, address(usdt), 1_000e6);
        usdt.setParams(10, 5);
        _fund(minter, address(usdt), 2_000e6);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.BelowLimit.selector, 999e6, 1_000e6));
        requests.fill(id, 1_000e6);

        uint256 gross = 1_001_001_002; // 1,001.001002 USDT, of which 0.10% (1.001001 USDT) is the fee
        vm.prank(minter);
        requests.fill(id, gross);
        assertEq(usdt.balanceOf(alice), 1_000_000_001);
        assertGe(usdt.balanceOf(alice), 1_000e6);
    }

    function test_fill_mintBelowTheLimitIsRefused() public {
        uint256 id = _requestMint(address(usdc), 300e6, 1e18);
        vm.startPrank(minter);
        index.approve(address(requests), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.BelowLimit.selector, 1e18 - 1, 1e18));
        requests.fill(id, 1e18 - 1);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.BelowLimit.selector, 0, 1e18));
        requests.fill(id, 0);
        vm.stopPrank();
        assertTrue(requests.getRequest(id).open, "a refused fill leaves the request open");
    }

    /// @dev A filler who is also the requester delivers nothing to anyone, so the fill is refused.
    function test_fill_bySelfDeliversNothing() public {
        vm.prank(minter);
        index.transfer(alice, 1e18);
        uint256 id = _requestMint(address(usdc), 300e6, 1e18);
        vm.startPrank(alice);
        index.approve(address(requests), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.BelowLimit.selector, 0, 1e18));
        requests.fill(id, 1e18);
        vm.stopPrank();
    }

    function test_fill_windowEndsAtTheDeadline() public {
        uint256 id = _requestMint(address(usdc), 300e6, 1e18);
        uint256 deadline = requests.getRequest(id).deadline;
        vm.prank(minter);
        index.approve(address(requests), 2e18);

        vm.warp(deadline + 1);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestExpired.selector, id, deadline));
        requests.fill(id, 1e18);

        vm.warp(deadline);
        vm.prank(minter);
        requests.fill(id, 1e18); // the deadline's own second still fills
        assertEq(index.balanceOf(alice), 1e18);
    }

    function test_unknownRequestsAreNotOpen() public {
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, 0));
        requests.fill(0, 1);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, 7));
        requests.cancel(7);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, 7));
        requests.refund(7);
        IMintRequests.Request memory r = requests.getRequest(7);
        assertEq(r.requester, address(0));
        assertEq(r.escrow, 0);
    }

    // ---------------------------------------------------------------------
    // cancel and refund
    // ---------------------------------------------------------------------

    function test_cancel_onlyTheRequesterAtAnyTime() public {
        uint256 id = _requestMint(address(usdc), 300e6, 1e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        requests.cancel(id);

        vm.warp(block.timestamp + 40 days); // well past the deadline: cancelling still works
        vm.expectEmit(address(requests));
        emit IMintRequests.RequestCancelled(id);
        vm.prank(alice);
        requests.cancel(id);
        assertEq(_balance(address(usdc), alice), 300e6);
        assertFalse(requests.getRequest(id).open);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, id));
        requests.cancel(id);
    }

    function test_refund_anyoneAfterTheDeadline() public {
        uint256 id = _requestRedeem(3e18, address(usdc), 700e6);
        uint256 deadline = requests.getRequest(id).deadline;
        vm.warp(deadline);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotExpired.selector, id, deadline));
        requests.refund(id);

        vm.warp(deadline + 1);
        vm.expectEmit(address(requests));
        emit IMintRequests.RequestRefunded(id, stranger);
        vm.prank(stranger);
        requests.refund(id);
        assertEq(index.balanceOf(alice), 3e18, "the shares go back to the requester, not the caller");
        assertEq(index.balanceOf(stranger), 0);

        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, id));
        requests.refund(id);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, id));
        requests.fill(id, 700e6);
    }

    /// @dev USDT switches its fee on after the requests were made. Every escrow still leaves in full: each requester
    ///      is sent exactly what the contract recorded, the fee comes out of what they receive, and the contract ends
    ///      empty rather than short.
    function test_refund_aFeeSwitchedOnLaterNeverLeavesTheLastRefundShort() public {
        uint256 first = _requestMint(address(usdt), 1_000e6, 1e18);
        uint256 second = _requestMint(address(usdt), 2_000e6, 2e18);
        usdt.setParams(10, 5);
        vm.warp(block.timestamp + DAY + 1);
        requests.refund(first);
        vm.prank(alice);
        requests.cancel(second);
        assertEq(usdt.balanceOf(address(requests)), 0, "every escrow left, and nothing was short");
        assertEq(usdt.balanceOf(alice), 999e6 + 1_998e6, "the fee came out of what the requester received");
    }

    // ---------------------------------------------------------------------
    // reentrancy
    // ---------------------------------------------------------------------

    /// @dev Every entry point shares the guard. With a token that calls its recipient back standing in for USDC, a
    ///      filler paid by `fill` tries to cancel another open request from inside the payment, and is refused.
    function test_everyEntryPointSharesTheGuard() public {
        MockHookToken hook = new MockHookToken();
        MintRequests hooked = new MintRequests(address(factory), address(hook), address(usdt));
        ReentrantFiller filler = new ReentrantFiller(hooked);

        hook.mint(alice, 200e18);
        vm.startPrank(alice);
        hook.approve(address(hooked), 200e18);
        uint256 id = hooked.requestMint(address(index), address(hook), 100e18, 1e18, block.timestamp + DAY);
        uint256 other = hooked.requestMint(address(index), address(hook), 100e18, 1e18, block.timestamp + DAY);
        vm.stopPrank();
        filler.setTarget(other);

        vm.prank(minter);
        index.transfer(address(filler), 1e18);
        filler.fill(id, 1e18, address(index));

        assertFalse(filler.reentered(), "the re-entry did not go through");
        assertEq(filler.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertTrue(hooked.getRequest(other).open, "the other request is untouched");
        assertEq(hook.balanceOf(address(filler)), 100e18, "and the fill paid its filler");
    }
}
