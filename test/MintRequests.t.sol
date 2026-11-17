// SPDX-License-Identifier: BUSL-1.1
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
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";

/// @notice A filler that, when it is paid, tries to re-enter the contract that paid it and records how that ended. It
///         fills by id alone or bound to a hash, and re-enters `cancel(target)` or, once it is given one, another call.
contract ReentrantFiller {
    MintRequests internal immutable REQUESTS;
    uint256 public target;
    /// @dev The call it re-enters with in place of `cancel(target)`. Empty until `setReentry`.
    bytes internal reentry;
    bytes public reentryError;
    bool public reentered;

    constructor(MintRequests requests) {
        REQUESTS = requests;
    }

    function setTarget(uint256 id) external {
        target = id;
    }

    function setReentry(bytes calldata data) external {
        reentry = data;
    }

    function fill(uint256 id, uint256 amount, address token) external {
        MockERC20(token).approve(address(REQUESTS), amount);
        REQUESTS.fill(id, amount);
    }

    function fillBound(uint256 id, uint256 amount, address token, bytes32 expected) external {
        MockERC20(token).approve(address(REQUESTS), amount);
        REQUESTS.fill(id, amount, expected);
    }

    function onTokenReceived(address, uint256) external {
        bytes memory data = reentry.length == 0 ? abi.encodeCall(MintRequests.cancel, (target)) : reentry;
        (reentered, reentryError) = address(REQUESTS).call(data);
    }
}

/// @notice Escrowed mint and redeem requests: the escrow is what arrived, the requester gets at least their limit,
///         every request closes once, and nothing reads a price. A request is filled only while the index reads the
///         rebalance nonce it was made at, and a bound fill only as the request its caller priced.
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

    /// @dev Settles a rebalance of the index, which takes its nonce up by one. The rebalance starts at the first second
    ///      it may and is filled six hours later, in its auction's last second. The fill adds a hundredth to every
    ///      component, which clears the bar the auction ends at.
    function _settleRebalance() internal {
        uint256 earliest = index.earliestRebalance();
        if (block.timestamp < earliest) vm.warp(earliest);
        index.startRebalance(0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());

        uint256[] memory units = index.recordedUnits();
        for (uint256 i = 0; i < units.length; ++i) {
            units[i] += units[i] / 100;
        }
        new MockWeightedExecutor().execute(index, units, "");
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

        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        requests.requestMint(address(index), address(usdc), 0, 1e18, deadline);
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        requests.requestMint(address(index), address(usdc), 100e6, 0, deadline);
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        requests.requestRedeem(address(index), 0, address(usdc), 1e6, deadline);
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
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

    /// @dev A requester filling its own redeem request under a USDT fee lowers its own balance by the fee: that is
    ///      nothing delivered, refused as BelowLimit, not an arithmetic panic (RX-54).
    function test_RX54_aSelfFillUnderAUsdtFeeIsBelowTheLimit() public {
        uint256 id = _requestRedeem(1e18, address(usdt), 1_000e6);
        usdt.setParams(10, 5);
        _fund(alice, address(usdt), 2_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.BelowLimit.selector, 0, 1_000e6));
        requests.fill(id, 1_000e6);
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
    // a settlement since the request
    // ---------------------------------------------------------------------

    /// @dev RW-2: a request named no basket, so it stayed fillable across a rebalance that changed what a share is
    ///      backed by. It now records the index's nonce when it is made: 0 before the first settlement and 1 after
    ///      it, for either kind. A request made at the index's nonce fills, by its id alone or bound to its hash, which
    ///      covers the nonce.
    function test_RW2_aRequestRecordsTheNonceItWasMadeAt() public {
        uint256 first = _requestMint(address(usdc), 300e6, 1e18);
        assertEq(requests.getRequest(first).rebalanceNonce, 0);

        _settleRebalance();
        assertEq(index.rebalanceNonce(), 1);
        uint256 mintId = _requestMint(address(usdc), 300e6, 1e18);
        uint256 redeemId = _requestRedeem(2e18, address(usdc), 500e6);
        assertEq(requests.getRequest(mintId).rebalanceNonce, 1, "a mint request made after the settlement");
        assertEq(requests.getRequest(redeemId).rebalanceNonce, 1, "and a redeem request");
        assertEq(requests.getRequest(first).rebalanceNonce, 0, "the earlier one keeps the nonce it was made at");

        vm.startPrank(minter);
        index.approve(address(requests), 1e18);
        requests.fill(mintId, 1e18);
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18, "a request made at the index's nonce fills");

        _fund(minter, address(usdc), 500e6);
        bytes32 priced = requests.requestHash(redeemId);
        vm.prank(minter);
        requests.fill(redeemId, 500e6, priced);
        assertEq(_balance(address(usdc), alice), 500e6, "and so does one bound to its hash at that nonce");
        assertEq(index.balanceOf(minter), 9e18, "whose filler takes the escrowed shares");
    }

    /// @dev RW-2: a mint request's limit counts shares of the basket it was made for. A filler that settled a rebalance
    ///      first could deliver shares backed by less and take the whole escrow. Either `fill` now refuses a request
    ///      made before a settlement, and the requester cancels it with the escrow whole.
    function test_RW2_aMintRequestIsNotFilledAfterASettlement() public {
        vm.warp(index.earliestRebalance()); // a rebalance may start at once, so it settles inside the request's day
        uint256 id = _requestMint(address(usdc), 300e6, 1e18);
        bytes32 priced = requests.requestHash(id);
        _settleRebalance();

        vm.startPrank(minter);
        index.approve(address(requests), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 0, 1));
        requests.fill(id, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 0, 1));
        requests.fill(id, 1e18, priced); // the request is still the one priced; the index is not
        vm.stopPrank();
        assertTrue(requests.getRequest(id).open, "a refused fill leaves the request open");

        vm.prank(alice);
        requests.cancel(id);
        assertEq(_balance(address(usdc), alice), 300e6, "the requester has the whole escrow back");
        assertEq(_balance(address(usdc), address(requests)), 0);
    }

    /// @dev RW-2, a redeem request: its limit was set for what the escrowed shares were backed by. After a settlement
    ///      it is refused the same way, and once its deadline passes anyone sends the shares back.
    function test_RW2_aRedeemRequestIsNotFilledAfterASettlement() public {
        vm.warp(index.earliestRebalance()); // a rebalance may start at once, so it settles inside the request's day
        uint256 id = _requestRedeem(2e18, address(usdc), 500e6);
        uint256 deadline = requests.getRequest(id).deadline;
        _settleRebalance();

        _fund(minter, address(usdc), 500e6);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 0, 1));
        requests.fill(id, 500e6);

        vm.warp(deadline + 1);
        vm.prank(stranger);
        requests.refund(id);
        assertEq(index.balanceOf(alice), 2e18, "the escrowed shares are back with the requester");
        assertEq(index.balanceOf(address(requests)), 0);
        assertEq(_balance(address(usdc), minter), 500e6, "and the filler kept its USDC");
    }

    // ---------------------------------------------------------------------
    // the bound fill
    // ---------------------------------------------------------------------

    /// @dev RW-7: an id is only a counter. A filler prices a request that is still pending and expects it at the next
    ///      id; a dust request ordered first takes that id, and a fill by id alone delivers the shares for one raw unit
    ///      of USDC. Bound to the hash of what it priced, the fill refuses the dust request, and takes the priced one
    ///      at its own id under the same hash.
    function test_RW7_aBoundFillRefusesAnotherRequestBehindTheId() public {
        uint256 deadline = block.timestamp + DAY;
        // What the filler priced: the requester's request as it will be recorded, from its pending terms.
        bytes32 priced = keccak256(
            abi.encode(
                IMintRequests.Request({
                    requester: alice,
                    deadline: uint40(deadline),
                    isMint: true,
                    open: true,
                    rebalanceNonce: 0,
                    index: address(index),
                    stable: address(usdc),
                    escrow: 300e6,
                    limit: 1e18
                })
            )
        );

        _fund(stranger, address(usdc), 1);
        vm.prank(stranger);
        uint256 dust = requests.requestMint(address(index), address(usdc), 1, 1, deadline);
        uint256 id = _requestMint(address(usdc), 300e6, 1e18);
        assertEq(dust, 1, "the dust request took the id the filler expected");

        vm.startPrank(minter);
        index.approve(address(requests), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestChanged.selector, dust));
        requests.fill(dust, 1e18, priced);
        vm.stopPrank();
        assertEq(index.balanceOf(minter), 10e18, "the filler keeps its shares");
        assertTrue(requests.getRequest(dust).open, "and the dust request stays as it was");

        vm.prank(minter);
        requests.fill(id, 1e18, priced);
        assertEq(index.balanceOf(alice), 1e18, "the priced request fills under the same hash");
        assertEq(_balance(address(usdc), minter), 300e6, "for the escrow the filler priced");
    }

    /// @dev RW-7: `requestHash` is the hash of the request as `getRequest` returns it, and the bound fill takes that
    ///      hash alone: zero is no wildcard. A request closed by its fill is not open under the hash it filled at, nor
    ///      under the hash it has now, so nothing fills twice.
    function test_RW7_aBoundFillTakesOnlyTheHashOfItsRequest() public {
        uint256 id = _requestMint(address(usdc), 300e6, 1e18);
        bytes32 priced = keccak256(abi.encode(requests.getRequest(id)));
        assertEq(requests.requestHash(id), priced, "the view hashes what getRequest returns");

        vm.startPrank(minter);
        index.approve(address(requests), 2e18);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestChanged.selector, id));
        requests.fill(id, 1e18, bytes32(0));
        requests.fill(id, 1e18, priced);
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18);
        assertEq(_balance(address(usdc), minter), 300e6);

        bytes32 closed = requests.requestHash(id);
        assertNotEq(closed, priced, "the hash covers the open flag");
        vm.startPrank(minter);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, id));
        requests.fill(id, 1e18, priced);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, id));
        requests.fill(id, 1e18, closed);
        vm.stopPrank();
    }

    /// @dev RW-2, RW-7: the order of the bound fill's checks. An open request is compared with the hash first, so a
    ///      filler whose id names another request is told RequestChanged even when that request is stale or expired.
    ///      Under its own hash a request is expired before it is stale, as it is through the fill by id alone.
    function test_RW2_RW7_aBoundFillChecksTheHashThenTheDeadlineThenTheNonce() public {
        vm.warp(index.earliestRebalance()); // a rebalance may start at once, so it settles inside the request's day
        uint256 id = _requestMint(address(usdc), 300e6, 1e18);
        uint256 deadline = requests.getRequest(id).deadline;
        bytes32 priced = requests.requestHash(id);
        _settleRebalance();

        vm.startPrank(minter);
        index.approve(address(requests), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestChanged.selector, id));
        requests.fill(id, 1e18, bytes32(0)); // stale, under another hash: the hash is compared before the nonce
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 0, 1));
        requests.fill(id, 1e18, priced);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestChanged.selector, id));
        requests.fill(id, 1e18, bytes32(0)); // expired too: still the hash first
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestExpired.selector, id, deadline));
        requests.fill(id, 1e18, priced); // under its own hash: the deadline before the nonce
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestExpired.selector, id, deadline));
        requests.fill(id, 1e18);
        vm.stopPrank();
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

    /// @dev RW-7: the bound fill is an entry point of its own, and the test above enters only by id and re-enters only
    ///      `cancel`, so the bound fill could lose `nonReentrant` unseen. It shares the guard both ways: a filler paid
    ///      by the bound fill is refused a fill by id alone from inside the payment, and a filler paid by the fill by
    ///      id alone is refused a bound one. Each re-entry fills a redeem request with the payment itself, a fill
    ///      that is valid on its own and ran to completion without the guard.
    function test_RW7_theBoundFillSharesTheGuard() public {
        MockHookToken hook = new MockHookToken();
        MintRequests hooked = new MintRequests(address(factory), address(hook), address(usdt));
        ReentrantFiller fromBound = new ReentrantFiller(hooked);
        ReentrantFiller intoBound = new ReentrantFiller(hooked);
        bytes memory refused = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);

        hook.mint(alice, 200e18);
        vm.startPrank(minter);
        index.transfer(alice, 1e18);
        index.transfer(address(fromBound), 1e18);
        index.transfer(address(intoBound), 1e18);
        vm.stopPrank();
        vm.startPrank(alice);
        hook.approve(address(hooked), 200e18);
        index.approve(address(hooked), 1e18);
        uint256 first = hooked.requestMint(address(index), address(hook), 100e18, 1e18, block.timestamp + DAY);
        uint256 second = hooked.requestMint(address(index), address(hook), 100e18, 1e18, block.timestamp + DAY);
        uint256 other = hooked.requestRedeem(address(index), 1e18, address(hook), 100e18, block.timestamp + DAY);
        vm.stopPrank();
        bytes32 priced = hooked.requestHash(first);
        bytes32 otherPriced = hooked.requestHash(other);
        // Each filler lets the contract take what its fill pays it, which is what the redeem request asks for.
        vm.prank(address(fromBound));
        hook.approve(address(hooked), 100e18);
        vm.prank(address(intoBound));
        hook.approve(address(hooked), 100e18);

        fromBound.setReentry(abi.encodeWithSignature("fill(uint256,uint256)", other, 100e18));
        fromBound.fillBound(first, 1e18, address(index), priced);
        assertFalse(fromBound.reentered(), "no re-entry from inside the bound fill went through");
        assertEq(fromBound.reentryError(), refused, "the bound fill holds the guard the fill by id alone checks");
        assertEq(hook.balanceOf(address(fromBound)), 100e18, "and its filler holds what the bound fill paid it");

        intoBound.setReentry(abi.encodeWithSignature("fill(uint256,uint256,bytes32)", other, 100e18, otherPriced));
        intoBound.fill(second, 1e18, address(index));
        assertFalse(intoBound.reentered(), "no re-entry into the bound fill went through");
        assertEq(intoBound.reentryError(), refused, "the bound fill checks the guard the fill by id alone holds");
        assertEq(hook.balanceOf(address(intoBound)), 100e18, "and its filler holds what that fill paid it");

        assertEq(hooked.requestHash(other), otherPriced, "the redeem request is as it was, still open");
        assertEq(index.balanceOf(address(hooked)), 1e18, "with its shares in escrow");
        assertEq(index.balanceOf(alice), 2e18, "and each fill delivered its share to the requester");
    }
}
