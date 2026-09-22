// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IIndexRule} from "../src/interfaces/IIndexRule.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockRebalanceExecutor} from "./mocks/MockRebalanceExecutor.sol";

contract IndexHandler is Test {
    IndexToken public index;
    MockMarket public market;
    MockRebalanceExecutor public executor;
    address public guardian;
    MockERC20[] public comps;
    int256[] public basePrices;
    address[] public actors;

    uint256 public ghostIssued;
    uint256 public ghostRedeemed;
    uint256 public ghostExecutions;
    bool public shortFillSucceeded;
    bool public unitBoundsBroken;
    bool public holdOffMisjudged;

    constructor(
        IndexToken index_,
        MockERC20[] memory comps_,
        int256[] memory basePrices_,
        address[] memory actors_,
        MockMarket market_,
        address guardian_
    ) {
        index = index_;
        comps = comps_;
        basePrices = basePrices_;
        actors = actors_;
        market = market_;
        guardian = guardian_;
        executor = new MockRebalanceExecutor();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev The first actor from `seed` on that holds shares, or the seeded one if nobody does. A random actor mostly
    ///      held nothing, so most redeems returned early and few fills met an outstanding claim (LR-06).
    function _holder(uint256 seed) internal view returns (address) {
        uint256 first = seed % actors.length;
        for (uint256 k = 0; k < actors.length; ++k) {
            address candidate = _actor(first + k);
            if (index.balanceOf(candidate) != 0) return candidate;
        }
        return _actor(first);
    }

    // ---------------------------------------------------------------------
    // holders
    // ---------------------------------------------------------------------

    function issue(uint256 seed, uint256 toSeed, uint256 shares) external {
        address from = _actor(seed);
        shares = bound(shares, 1, 1_000_000e18);
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 i = 0; i < comps.length; ++i) {
            comps[i].mint(from, need[i]);
            vm.prank(from);
            comps[i].approve(address(index), need[i]);
        }
        vm.prank(from);
        index.issue(shares, _actor(toSeed));
        ghostIssued += shares;
    }

    function redeem(uint256 seed, uint256 toSeed, uint256 shares) external {
        address from = _holder(seed);
        uint256 bal = index.balanceOf(from);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(from);
        index.redeem(shares, _actor(toSeed));
        ghostRedeemed += shares;
    }

    function redeemSkipping(uint256 seed, uint256 toSeed, uint256 shares, uint256 mask) external {
        address from = _holder(seed);
        uint256 bal = index.balanceOf(from);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        mask = bound(mask, 1, (1 << comps.length) - 1);
        vm.prank(from);
        index.redeemSkipping(shares, _actor(toSeed), mask);
        ghostRedeemed += shares;
    }

    /// @dev Pays the first outstanding claim found from the seeded actor and component on, if there is one.
    function claim(uint256 seed, uint256 compSeed, uint256 toSeed) external {
        (seed, compSeed) = (seed % actors.length, compSeed % comps.length);
        for (uint256 k = 0; k < actors.length * comps.length; ++k) {
            address from = _actor(seed + k / comps.length);
            address token = address(comps[(compSeed + k) % comps.length]);
            if (index.claimOf(from, token) == 0) continue;
            vm.prank(from);
            index.claim(token, _actor(toSeed));
            return;
        }
    }

    function transfer(uint256 seed, uint256 toSeed, uint256 amount) external {
        address from = _actor(seed);
        uint256 bal = index.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        vm.prank(from);
        index.transfer(_actor(toSeed), amount);
    }

    function donate(uint256 compSeed, uint256 amount) external {
        amount = bound(amount, 0, 1e30);
        comps[compSeed % comps.length].mint(address(index), amount);
    }

    // ---------------------------------------------------------------------
    // market and time
    // ---------------------------------------------------------------------

    /// @dev Moves a component's price up to 7x either way from where it started. Every component has a feed, WETH
    ///      included, so none is skipped.
    function movePrice(uint256 compSeed, uint256 delta) external {
        uint256 i = compSeed % comps.length;
        market.setPrice(address(comps[i]), basePrices[i] * int256(bound(delta, 1, 49)) / 7);
    }

    /// @dev ODD counts its own total supply, so a mint raises its market cap and moves the rule's targets, while a
    ///      burn lowers it. Nothing a holder does to its balances can move it (DA-10).
    function mintOddSupply(uint256 amount, bool burning) external {
        uint256 delta = bound(amount, 0, 1e30);
        if (!burning) return comps[3].mint(actors[0], delta);
        uint256 held = comps[3].balanceOf(actors[0]);
        comps[3].burn(actors[0], delta > held ? held : delta);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 7 days));
    }

    // ---------------------------------------------------------------------
    // rebalancing
    // ---------------------------------------------------------------------

    /// @dev Warps to the first moment the caller may start, then starts unless the rule sees too little to trade.
    function startRebalance(uint256 seed, uint256 maskSeed, bool asGuardian) external {
        (uint256 eta,,) = index.pendingRebalance();
        if (eta != 0 && block.timestamp <= eta + index.AUCTION_DURATION()) return;
        uint256 earliest = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        if (!asGuardian) {
            // A cancel holds strangers off, and so does an auction that expired unfilled (XA-02). The handler used to
            // model only the first, and the stranger's revert after an expiry was swallowed (LR-06).
            uint256 afterExpiry = eta == 0 ? 0 : eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY();
            earliest = Math.max(earliest, Math.max(index.restartAllowedAt(), afterExpiry));
        }
        if (block.timestamp < earliest) vm.warp(earliest);
        // The view an app reads has to agree with the moment this handler worked out for a stranger.
        holdOffMisjudged = holdOffMisjudged || (!asGuardian && !index.canStartRebalance());

        uint256 mask = asGuardian ? bound(maskSeed, 0, (1 << comps.length) - 2) : 0;
        (, uint256 turnover) = index.previewTarget(mask);
        if (turnover < index.MIN_TURNOVER()) return;
        vm.prank(asGuardian ? guardian : _actor(seed));
        index.startRebalance(mask);
    }

    function cancelRebalance() external {
        (uint256 eta,,) = index.pendingRebalance();
        if (eta == 0) return;
        vm.prank(guardian);
        index.cancelRebalance();
    }

    /// @dev Warps into the auction if the notice is still running, and returns if there is nothing to fill.
    function _toAuction(uint256 offset) internal returns (bool open) {
        (uint256 eta,,) = index.pendingRebalance();
        if (eta == 0 || block.timestamp > eta + index.AUCTION_DURATION()) return false;
        if (block.timestamp < eta) vm.warp(eta + bound(offset, 0, index.AUCTION_DURATION()));
        return _settlementClears();
    }

    /// @dev Whether the fill would clear MIN_SETTLEMENT_RATIO (DA-05). With less than one whole index token
    ///      outstanding, every growing leg can round to zero while a shrinking one does not, which is a settlement
    ///      that pays out and receives nothing: legitimately refused, so the handler must not call into it under
    ///      `fail_on_revert`.
    function _settlementClears() internal view returns (bool) {
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        address[] memory tokens = new address[](comps.length);
        for (uint256 i = 0; i < comps.length; ++i) {
            tokens[i] = address(comps[i]);
        }
        (uint256 outValue, uint256 inValue) =
            IIndexRule(IndexFactory(index.FACTORY()).RULE()).settlementValues(tokens, amountsOut, amountsIn);
        return inValue >= outValue * index.MIN_SETTLEMENT_RATIO() / 1e18;
    }

    function executeRebalance(uint256 offset) external {
        if (!_toAuction(offset)) return;
        (, uint256[] memory before) = index.components();
        executor.setMode(MockRebalanceExecutor.Mode.Honest);
        executor.execute(index, "");
        ++ghostExecutions;
        (, uint256[] memory afterwards) = index.components();
        for (uint256 i = 0; i < before.length; ++i) {
            // A shrinking component stops at half; a growing one gets at most double at par, times the 1.5 opening
            // multiplier on the extra units, rounded up.
            unitBoundsBroken =
                unitBoundsBroken || afterwards[i] * 2 < before[i] || afterwards[i] * 2 > before[i] * 5 + 2;
        }
    }

    /// @dev Delivers one raw unit too little of a growing component. It can never settle: the index requires the whole
    ///      of amountsIn on top of what it held, so surplus from rounding or donations stays with the holders.
    function executeRebalanceShort(uint256 offset) external {
        if (!_toAuction(offset)) return;
        (,,, uint256[] memory amountsIn) = index.previewRebalance();
        uint256 growing = amountsIn.length;
        for (uint256 i = 0; i < amountsIn.length; ++i) {
            if (growing == amountsIn.length && amountsIn[i] != 0) growing = i;
        }
        if (growing == amountsIn.length) return; // an empty index moves nothing

        executor.setMode(MockRebalanceExecutor.Mode.Short);
        executor.setShortComponent(growing);
        (bool settled,) = address(executor).call(abi.encodeCall(MockRebalanceExecutor.execute, (index, "")));
        // A settlement here would break the nonce-against-ghost invariant as well, on top of this flag.
        shortFillSucceeded = shortFillSucceeded || settled;
    }
}

contract IndexTokenInvariantTest is Test {
    MockMarket market;
    IndexFactory factory;
    IndexToken index;
    IndexHandler handler;
    MockERC20[] comps;
    address[] actors;

    function setUp() public {
        address owner = makeAddr("owner");
        address guardian = makeAddr("guardian");
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);

        comps.push(new MockERC20("WBTC", "WBTC", 8));
        comps.push(market.weth());
        comps.push(market.usdc());
        comps.push(new MockERC20("ODD", "ODD", 13));
        uint256[] memory units = new uint256[](4);
        (units[0], units[1], units[2], units[3]) = (100_000, 1e16, 10e6, 7); // the last is tiny so rounding bites

        // Prices, in dollars per whole token, that make every component worth 30 dollars per index token, and
        // supplies that give all four the same market cap, so the basket starts on its rule and supply changes create
        // real turnover. ODD counts on-chain supply. WBTC at 30,000 and WETH at 3,000 are the realistic pair; USDC and
        // ODD are priced to match them rather than to look like themselves.
        int256[] memory prices = new int256[](4);
        (prices[0], prices[1], prices[2], prices[3]) = (30_000e8, 3_000e8, 3e8, 42_857_142_857_142e8);
        uint256[] memory supplies = new uint256[](4);
        (supplies[0], supplies[1], supplies[2], supplies[3]) = (1e34, 1e45, 1e36, 0);
        comps[3].mint(makeAddr("oddHolder"), 7e29);

        address[] memory t = new address[](comps.length);
        for (uint256 i = 0; i < comps.length; ++i) {
            t[i] = address(comps[i]);
            IIndexFactory.TokenConfig memory config = market.configWith(t[i], prices[i], supplies[i]);
            vm.prank(owner);
            factory.proposeListing(t[i], config);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < comps.length; ++i) {
            factory.executeListing(t[i]);
        }
        index = IndexToken(factory.createIndex("Inv", "INV", t, units, 0));

        for (uint256 i = 0; i < 5; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
        handler = new IndexHandler(index, comps, prices, actors, market, guardian);
        targetContract(address(handler));
    }

    /// @dev Walks the handler through every path once, so its coverage does not depend on what the fuzzer calls.
    function test_handlerReachesEveryPath() public {
        // Nothing to do yet: no shares, no claims, no pending rebalance, and the basket starts on its rule.
        handler.redeem(0, 0, 1e18);
        handler.redeemSkipping(0, 0, 1e18, 1);
        handler.transfer(0, 1, 1e18);
        handler.claim(0, 0, 0);
        handler.cancelRebalance();
        handler.executeRebalance(0);
        handler.executeRebalanceShort(0);
        handler.movePrice(1, 1_000); // WETH has no pool
        handler.movePrice(0, 1_000);
        handler.warp(1 hours);
        handler.startRebalance(0, 0, false); // warps to the interval, then finds nothing to trade
        (uint256 eta,,) = index.pendingRebalance();
        assertEq(eta, 0);

        // An empty index: a short fill has nothing to shortchange, and an honest fill settles at parity.
        handler.mintOddSupply(1, true);
        handler.mintOddSupply(7e29, false);
        handler.startRebalance(0, 0, false);
        handler.startRebalance(0, 0, false); // already pending
        handler.executeRebalanceShort(0); // warps into the auction
        handler.executeRebalance(0);
        assertEq(index.rebalanceNonce(), 1);

        // After a cancel, strangers wait out the cooldown, which the handler warps past.
        handler.mintOddSupply(7e29, false);
        handler.startRebalance(0, 0, false);
        handler.cancelRebalance();
        handler.startRebalance(0, 0, false);
        (eta,,) = index.pendingRebalance();
        assertGt(eta, 0);

        // Holders act during the notice; then a short fill fails, and keeps failing once donations could have covered
        // the missing unit, because the index requires the whole of amountsIn on top of what it already held.
        handler.issue(0, 0, 3e18);
        handler.redeem(0, 0, 1e18);
        handler.redeemSkipping(0, 0, 1e18, 1);
        handler.claim(0, 0, 0);
        handler.transfer(0, 1, 5e17);
        handler.executeRebalanceShort(0);
        assertEq(index.rebalanceNonce(), 1, "one raw unit short, no settlement");
        for (uint256 i = 0; i < comps.length; ++i) {
            handler.donate(i, 1e30);
        }
        handler.executeRebalanceShort(0);
        assertEq(index.rebalanceNonce(), 1, "the donations belong to the holders, not to the executor");
        handler.executeRebalance(0);
        assertEq(index.rebalanceNonce(), 2, "an honest fill settles");
        assertEq(handler.ghostExecutions(), 2);
        assertFalse(handler.shortFillSucceeded());

        // The guardian can start with a keep mask.
        handler.mintOddSupply(1e30, false);
        handler.startRebalance(0, 1, true);
        (, uint256 keepMask,) = index.pendingRebalance();
        assertEq(keepMask, 1);
        assertFalse(handler.unitBoundsBroken());
    }

    function invariant_everyComponentBackedIncludingClaims() public view {
        uint256 supply = index.totalSupply();
        (, uint256[] memory units) = index.components();
        for (uint256 i = 0; i < comps.length; ++i) {
            uint256 required = Math.mulDiv(supply, units[i], 1e18) + index.totalClaims(address(comps[i]));
            assertGe(comps[i].balanceOf(address(index)), required, "component under-backed");
        }
    }

    function invariant_supplyMatchesGhostAndHolders() public view {
        assertEq(index.totalSupply(), handler.ghostIssued() - handler.ghostRedeemed());
        uint256 sum = 0;
        for (uint256 i = 0; i < actors.length; ++i) {
            sum += index.balanceOf(actors[i]);
        }
        assertEq(sum, index.totalSupply());
    }

    function invariant_claimsAddUp() public view {
        for (uint256 c = 0; c < comps.length; ++c) {
            uint256 sum = 0;
            for (uint256 i = 0; i < actors.length; ++i) {
                sum += index.claimOf(actors[i], address(comps[c]));
            }
            assertEq(sum, index.totalClaims(address(comps[c])));
        }
    }

    function invariant_rebalanceBookkeeping() public view {
        assertEq(index.rebalanceNonce(), handler.ghostExecutions(), "the nonce counts executed rebalances");
        assertFalse(handler.shortFillSucceeded(), "a short fill never settles, whatever surplus the index holds");
        assertFalse(handler.unitBoundsBroken(), "units move between half and 2.5 times per rebalance");
        assertFalse(handler.holdOffMisjudged(), "canStartRebalance says when a stranger may start");
        (uint256 eta,, uint256[] memory targets) = index.pendingRebalance();
        assertEq(targets.length, eta == 0 ? 0 : comps.length, "targets exist exactly while a rebalance is pending");
    }
}
