// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MintRequests} from "../src/MintRequests.sol";
import {IMintRequests} from "../src/interfaces/IMintRequests.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// @notice Drives requests, fills, cancels, refunds, donations and USDT's fee switch in any order, making only calls
///         that must succeed, and records anything the invariants need to see.
contract RequestsHandler is Test {
    MintRequests public immutable REQUESTS;
    MockUSDT public immutable USDT;
    MockERC20 public immutable USDC;
    WeightedHub public immutable INDEX;
    address[] internal _components;
    address[3] internal _requesters = [makeAddr("r0"), makeAddr("r1"), makeAddr("r2")];
    address[2] internal _fillers = [makeAddr("f0"), makeAddr("f1")];

    /// @notice Escrow of every open request, per token.
    mapping(address token => uint256) public openEscrow;
    /// @notice Tokens sent to the contract outside any request.
    mapping(address token => uint256) public donated;
    uint256[] public openIds;
    uint256[] public closedIds;

    bool public escrowMismatch;
    bool public paidBelowLimit;
    bool public returnedWrongAmount;
    uint256 public fills;
    uint256 public cancels;
    uint256 public refunds;
    uint256 public feeFills;

    constructor(WeightedIndexFactory factory, WeightedHub index, MockERC20 usdc, address[] memory components) {
        USDT = new MockUSDT();
        USDC = usdc;
        INDEX = index;
        _components = components;
        REQUESTS = new MintRequests(address(factory), address(usdc), address(USDT));
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _stable(bool useUsdt) internal view returns (address) {
        return useUsdt ? address(USDT) : address(USDC);
    }

    function _mintStable(address stable, address to, uint256 amount) internal {
        if (stable == address(USDT)) USDT.mint(to, amount);
        else USDC.mint(to, amount);
    }

    function _approveStable(address stable, address from, uint256 amount) internal {
        vm.startPrank(from);
        // USDT refuses a non-zero allowance changed to another non-zero one.
        if (stable == address(USDT)) USDT.approve(address(REQUESTS), 0);
        if (stable == address(USDT)) USDT.approve(address(REQUESTS), amount);
        else USDC.approve(address(REQUESTS), amount);
        vm.stopPrank();
    }

    function _balance(address token, address who) internal view returns (uint256) {
        return MockERC20(token).balanceOf(who);
    }

    /// @dev Issues `shares` in kind to `to`, minting the basket it needs.
    function _issue(address to, uint256 shares) internal {
        uint256[] memory need = INDEX.previewIssue(shares);
        vm.startPrank(to);
        for (uint256 i = 0; i < _components.length; ++i) {
            MockERC20(_components[i]).mint(to, need[i]);
            MockERC20(_components[i]).approve(address(INDEX), need[i]);
        }
        INDEX.issue(shares, to);
        vm.stopPrank();
    }

    /// @dev What a USDT transfer of `gross` delivers under the current fee.
    function _net(uint256 gross) internal view returns (uint256) {
        uint256 fee = gross * USDT.basisPointsRate() / 10_000;
        if (fee > USDT.maximumFee()) fee = USDT.maximumFee();
        return gross - fee;
    }

    function _close(uint256 slot, IMintRequests.Request memory r) internal {
        address escrowed = r.isMint ? r.stable : r.index;
        openEscrow[escrowed] -= r.escrow;
        closedIds.push(openIds[slot]);
        openIds[slot] = openIds[openIds.length - 1];
        openIds.pop();
    }

    // ---------------------------------------------------------------------
    // actions
    // ---------------------------------------------------------------------

    function requestMint(uint256 who, uint256 amount, uint256 limit, bool useUsdt, uint256 life) external {
        address requester = _requesters[who % 3];
        address stable = _stable(useUsdt);
        amount = bound(amount, 1_000, 1e15);
        limit = bound(limit, 1, 1e21);
        life = bound(life, 1, REQUESTS.MAX_REQUEST_DURATION());
        _mintStable(stable, requester, amount);
        _approveStable(stable, requester, amount);
        uint256 before = _balance(stable, address(REQUESTS));
        vm.prank(requester);
        uint256 id = REQUESTS.requestMint(address(INDEX), stable, amount, limit, block.timestamp + life);
        uint256 escrow = REQUESTS.getRequest(id).escrow;
        escrowMismatch = escrowMismatch || escrow != _balance(stable, address(REQUESTS)) - before;
        openEscrow[stable] += escrow;
        openIds.push(id);
    }

    function requestRedeem(uint256 who, uint256 shares, uint256 limit, bool useUsdt, uint256 life) external {
        address requester = _requesters[who % 3];
        shares = bound(shares, 1, 1e21);
        limit = bound(limit, 1, 1e15);
        life = bound(life, 1, REQUESTS.MAX_REQUEST_DURATION());
        _issue(requester, shares);
        vm.prank(requester);
        INDEX.approve(address(REQUESTS), shares);
        uint256 before = INDEX.balanceOf(address(REQUESTS));
        vm.prank(requester);
        uint256 id = REQUESTS.requestRedeem(address(INDEX), shares, _stable(useUsdt), limit, block.timestamp + life);
        uint256 escrow = REQUESTS.getRequest(id).escrow;
        escrowMismatch = escrowMismatch || escrow != INDEX.balanceOf(address(REQUESTS)) - before;
        openEscrow[address(INDEX)] += escrow;
        openIds.push(id);
    }

    /// @dev Fills an open request that is still in its window, delivering the limit plus `extra` after any fee.
    function fill(uint256 pick, uint256 who, uint256 extra) external {
        if (openIds.length == 0) return;
        uint256 slot = pick % openIds.length;
        uint256 id = openIds[slot];
        IMintRequests.Request memory r = REQUESTS.getRequest(id);
        if (block.timestamp > r.deadline) return;
        address filler = _fillers[who % 2];
        extra = bound(extra, 0, 1e6);

        uint256 amount;
        address delivered;
        if (r.isMint) {
            delivered = r.index;
            amount = r.limit + extra;
            _issue(filler, amount);
            vm.prank(filler);
            INDEX.approve(address(REQUESTS), amount);
        } else {
            delivered = r.stable;
            amount = r.limit + extra;
            if (delivered == address(USDT)) {
                while (_net(amount) < r.limit + extra) {
                    amount += r.limit + extra - _net(amount);
                }
                if (amount != r.limit + extra) ++feeFills;
            }
            _mintStable(delivered, filler, amount);
            _approveStable(delivered, filler, amount);
        }
        address paid = r.isMint ? r.stable : r.index;
        uint256 requesterBefore = _balance(delivered, r.requester);
        uint256 fillerBefore = _balance(paid, filler);
        uint256 sentBefore = _balance(paid, address(REQUESTS));

        vm.prank(filler);
        REQUESTS.fill(id, amount);

        paidBelowLimit = paidBelowLimit || _balance(delivered, r.requester) - requesterBefore < r.limit;
        // The contract parts with exactly the recorded escrow, whatever the filler ends up receiving after a fee.
        returnedWrongAmount = returnedWrongAmount || sentBefore - _balance(paid, address(REQUESTS)) != r.escrow;
        returnedWrongAmount = returnedWrongAmount || _balance(paid, filler) < fillerBefore;
        _close(slot, r);
        ++fills;
    }

    function cancel(uint256 pick) external {
        if (openIds.length == 0) return;
        uint256 slot = pick % openIds.length;
        uint256 id = openIds[slot];
        IMintRequests.Request memory r = REQUESTS.getRequest(id);
        address escrowed = r.isMint ? r.stable : r.index;
        uint256 before = _balance(escrowed, address(REQUESTS));
        vm.prank(r.requester);
        REQUESTS.cancel(id);
        returnedWrongAmount = returnedWrongAmount || before - _balance(escrowed, address(REQUESTS)) != r.escrow;
        _close(slot, r);
        ++cancels;
    }

    function refund(uint256 pick) external {
        if (openIds.length == 0) return;
        uint256 slot = pick % openIds.length;
        uint256 id = openIds[slot];
        IMintRequests.Request memory r = REQUESTS.getRequest(id);
        if (block.timestamp <= r.deadline) return;
        address escrowed = r.isMint ? r.stable : r.index;
        uint256 before = _balance(escrowed, address(REQUESTS));
        vm.prank(makeAddr("anyone"));
        REQUESTS.refund(id);
        returnedWrongAmount = returnedWrongAmount || before - _balance(escrowed, address(REQUESTS)) != r.escrow;
        _close(slot, r);
        ++refunds;
    }

    /// @dev Tether switching its fee on or off, as it can at any time.
    function switchFee(bool on) external {
        USDT.setParams(on ? 10 : 0, on ? 5 : 0);
    }

    function donate(uint256 amount, uint256 which) external {
        amount = bound(amount, 1, 1e12);
        address token = which % 3 == 0 ? address(USDC) : which % 3 == 1 ? address(USDT) : address(INDEX);
        if (token == address(INDEX)) {
            _issue(address(this), amount);
            INDEX.transfer(address(REQUESTS), amount);
            donated[token] += amount;
            return;
        }
        uint256 before = _balance(token, address(REQUESTS));
        _mintStable(token, address(REQUESTS), amount);
        donated[token] += _balance(token, address(REQUESTS)) - before;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 hours, 20 days));
    }

    function openCount() external view returns (uint256) {
        return openIds.length;
    }

    function closedCount() external view returns (uint256) {
        return closedIds.length;
    }
}

/// @notice Whatever requesters, fillers and Tether do, the contract holds exactly the open escrows plus donations,
///         every request is open or closed as the handler saw it, and no requester is ever paid below their limit.
contract MintRequestsInvariantTest is Test {
    WeightedIndexFactory factory;
    WeightedHub index;
    RequestsHandler handler;
    MintRequests requests;
    address owner = makeAddr("owner");

    function setUp() public {
        factory = new WeightedIndexFactory(owner, makeAddr("guardian"), address(new MockPyth()));
        address[] memory components = new address[](2);
        vm.startPrank(owner);
        for (uint256 i = 0; i < 2; ++i) {
            components[i] = address(new MockERC20("C", "C", 18));
            factory.proposeListing(components[i], keccak256(abi.encode(components[i])));
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < 2; ++i) {
            factory.executeListing(components[i]);
        }
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        for (uint256 i = 0; i < 2; ++i) {
            specs[i] = IWeightedIndexFactory.ComponentSpec({token: components[i], weight: 5000, units: 100e18});
        }
        index = WeightedHub(
            factory.createIndex(
                "Requested",
                "REQ",
                specs,
                IWeightedIndexFactory.IndexParams({
                    creatorFeeBps: 0,
                    creatorStreamingBps: 0,
                    maxPlatformFeeBps: 25,
                    maxPlatformStreamingBps: 100,
                    rebalanceInterval: 7 days,
                    gated: false,
                    listed: true
                })
            )
        );
        handler = new RequestsHandler(factory, index, new MockERC20("USD Coin", "USDC", 6), components);
        requests = handler.REQUESTS();
        targetContract(address(handler));
    }

    /// @dev The contract's balance of each token is exactly the open escrows in it plus what was donated: nothing is
    ///      paid out twice, nothing is paid out of another request's escrow, and a fee cannot leave a refund short.
    function invariant_theBalanceIsTheOpenEscrowsPlusDonations() public view {
        address[3] memory tokens = [address(handler.USDC()), address(handler.USDT()), address(index)];
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(
                MockERC20(tokens[i]).balanceOf(address(requests)),
                handler.openEscrow(tokens[i]) + handler.donated(tokens[i]),
                "the balance drifted from the open escrows"
            );
        }
    }

    /// @dev Each request is open exactly while the handler has not closed it, and the count matches.
    function invariant_everyRequestClosesOnce() public view {
        for (uint256 i = 0; i < handler.openCount(); ++i) {
            assertTrue(requests.getRequest(handler.openIds(i)).open, "a request closed without a call closing it");
        }
        for (uint256 i = 0; i < handler.closedCount(); ++i) {
            assertFalse(requests.getRequest(handler.closedIds(i)).open, "a closed request reopened");
        }
        assertEq(requests.requestCount(), handler.openCount() + handler.closedCount());
    }

    /// @dev No fill paid a requester less than their limit, measured where it landed, and every escrow recorded was
    ///      what arrived and left in full.
    function invariant_limitsHoldAndEscrowsAreExact() public view {
        assertFalse(handler.paidBelowLimit(), "a requester was paid below their limit");
        assertFalse(handler.escrowMismatch(), "an escrow was not what arrived");
        assertFalse(handler.returnedWrongAmount(), "an escrow did not leave in full");
    }

    /// @dev A redemption large enough that USDT's fee hits its 5 USDT cap: the filler covers exactly the capped fee.
    function test_aCappedUsdtFeeIsCoveredByTheFiller() public {
        handler.requestRedeem(0, 1e18, 20_000e6, true, 1 days);
        handler.switchFee(true);
        handler.fill(0, 0, 0);
        assertEq(handler.feeFills(), 1);
        assertEq(handler.USDT().balanceOf(makeAddr("r0")), 20_000e6, "the requester got the limit after the fee");
        invariant_theBalanceIsTheOpenEscrowsPlusDonations();
        invariant_limitsHoldAndEscrowsAreExact();
    }

    /// @dev The campaign reaches every path the invariants are about.
    function test_handlerReachesEveryPath() public {
        handler.requestMint(0, 1_000e6, 1e18, false, 1 days);
        handler.requestMint(1, 1_000e6, 1e18, true, 1 days);
        handler.requestRedeem(2, 2e18, 500e6, true, 1 days);
        handler.requestRedeem(0, 2e18, 500e6, false, 1 days);
        handler.switchFee(true);
        handler.fill(2, 0, 0); // the USDT redemption, whose filler covers the fee
        assertEq(handler.feeFills(), 1, "a filler covered USDT's fee");
        handler.fill(0, 1, 5);
        handler.cancel(0);
        handler.refund(0); // not expired yet: skipped
        handler.donate(3e6, 0);
        handler.donate(3e6, 1);
        handler.donate(1e18, 2);
        handler.warp(2 days);
        handler.fill(0, 0, 0); // expired: skipped
        handler.refund(0);
        handler.switchFee(false);
        handler.cancel(0); // nothing open: skipped
        handler.fill(0, 0, 0);
        handler.refund(0);
        assertEq(handler.fills(), 2);
        assertEq(handler.cancels(), 1);
        assertEq(handler.refunds(), 1);
        assertEq(handler.openCount(), 0);
        invariant_theBalanceIsTheOpenEscrowsPlusDonations();
        invariant_everyRequestClosesOnce();
        invariant_limitsHoldAndEscrowsAreExact();
    }
}
