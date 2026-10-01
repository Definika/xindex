// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexHub} from "../src/IndexHub.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockRebalanceExecutor} from "./mocks/MockRebalanceExecutor.sol";

contract IndexHandler is Test {
    uint256 internal constant WAD = 1e18;

    IndexHub public index;
    IndexFactory public factory;
    MockRebalanceExecutor public executor;
    address public guardian;
    MockERC20[] public comps;
    address[] public actors;
    /// @dev Prices that exist only in this test, which no contract ever sees: they value each fill so the handler can
    ///      check the band's bound against a market the hub knows nothing about.
    uint256[] public shadowPrices;

    uint256 public ghostIssued;
    uint256 public ghostRedeemed;
    uint256 public ghostExecutions;
    uint256 public ghostBatches;
    bool public shortFillSucceeded;
    bool public unitBoundsBroken;
    bool public holdOffMisjudged;
    bool public worstCaseBroken;
    bool public clampBroken;
    bool public previewMisled;

    constructor(IndexHub index_, MockERC20[] memory comps_, address[] memory actors_, address guardian_) {
        index = index_;
        factory = IndexFactory(index_.FACTORY());
        comps = comps_;
        actors = actors_;
        guardian = guardian_;
        executor = new MockRebalanceExecutor();
        for (uint256 i = 0; i < comps_.length; ++i) {
            shadowPrices.push(1e18);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev The first actor from `seed` on that holds shares, or the seeded one if nobody does (LR-06).
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
    // supplies, prices and time
    // ---------------------------------------------------------------------

    /// @dev Revises every component's reference supply by up to a step, up, down or not at all, through a supply batch:
    ///      the owner proposes, the delay passes, anyone executes. Nothing a holder does can move a supply (CR-M01).
    function reviseSupplies(uint256 seed) external {
        if (factory.suppliesPending()) return;
        uint256 n = comps.length;
        address[] memory sorted = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            sorted[i] = address(comps[i]);
        }
        for (uint256 i = 1; i < n; ++i) {
            for (uint256 j = i; j > 0 && sorted[j - 1] > sorted[j]; --j) {
                (sorted[j - 1], sorted[j]) = (sorted[j], sorted[j - 1]);
            }
        }
        uint256[] memory supplies = factory.referenceSupplies(sorted);
        for (uint256 i = 0; i < n; ++i) {
            uint256 step = supplies[i] * factory.MAX_SUPPLY_STEP() / WAD;
            uint256 pick = (seed >> (2 * i)) % 3;
            supplies[i] = pick == 0 ? supplies[i] + step : pick == 1 ? supplies[i] - step : supplies[i];
        }
        vm.prank(factory.owner());
        factory.proposeSupplies(sorted, supplies);
        // The batch comes due LISTING_DELAY away, or a week after the last one when that is later (SA-04).
        (, uint256 eta,,) = factory.pendingSupplies();
        vm.warp(eta);
        factory.executeSupplies();
        ++ghostBatches;
    }

    /// @dev Moves a component's shadow price anywhere from a thousandth to a thousand times its start. The hub never
    ///      sees it; only the value checks below do.
    function moveShadowPrice(uint256 compSeed, uint256 price) external {
        shadowPrices[compSeed % comps.length] = bound(price, 1e15, 1e21);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 7 days));
    }

    // ---------------------------------------------------------------------
    // rebalancing
    // ---------------------------------------------------------------------

    /// @dev Warps to the first moment the caller may start, then starts unless the band is too narrow to trade.
    function startRebalance(uint256 seed, uint256 maskSeed, bool asGuardian) external {
        (uint256 eta,,,,) = index.pendingRebalance();
        if (eta != 0 && block.timestamp <= eta + index.AUCTION_DURATION()) return;
        uint256 earliest = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        if (!asGuardian) {
            // A cancel holds strangers off, and so does an auction that expired unfilled (XA-02, LR-06).
            uint256 afterExpiry = eta == 0 ? 0 : eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY();
            earliest = Math.max(earliest, Math.max(index.restartAllowedAt(), afterExpiry));
        }
        if (block.timestamp < earliest) vm.warp(earliest);
        // The view an app reads has to agree with the moment this handler worked out for a stranger.
        holdOffMisjudged = holdOffMisjudged || (!asGuardian && !index.canStartRebalance());

        uint256 mask = asGuardian ? bound(maskSeed, 0, (1 << comps.length) - 2) : 0;
        (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax) = index.previewBand(mask);
        if (lambdaMax * WAD < lambdaMin * (WAD + index.MIN_BAND())) return;
        vm.prank(asGuardian ? guardian : _actor(seed));
        index.startRebalance(mask);

        for (uint256 i = 0; i < ratios.length; ++i) {
            if ((mask >> i) & 1 == 1) continue;
            clampBroken = clampBroken || ratios[i] < lambdaMin || ratios[i] > lambdaMax
                || ratios[i] < WAD - index.MAX_SUPPLY_STEP() || ratios[i] > WAD + index.MAX_SUPPLY_STEP();
        }
    }

    function cancelRebalance() external {
        (uint256 eta,,,,) = index.pendingRebalance();
        if (eta == 0) return;
        vm.prank(guardian);
        index.cancelRebalance();
    }

    /// @dev Warps into the auction if the notice is still running, and returns whether there is anything to fill.
    function _toAuction(uint256 offset) internal returns (bool open) {
        (uint256 eta,,,,) = index.pendingRebalance();
        if (eta == 0 || block.timestamp > eta + index.AUCTION_DURATION()) return false;
        if (block.timestamp < eta) vm.warp(eta + bound(offset, 0, index.AUCTION_DURATION()));
        return true;
    }

    function executeRebalance(uint256 offset, bool bounded) external {
        if (!_toAuction(offset)) return;
        (, uint256[] memory before) = index.components();
        (, uint256 keepMask, uint256 lambdaMin, uint256 lambdaMax,) = index.pendingRebalance();
        (uint256 lambda, uint256[] memory preview,, uint256[] memory amountsIn) = index.previewRebalance();
        _checkValue(before, preview, keepMask, lambda, lambdaMax);

        executor.setMode(MockRebalanceExecutor.Mode.Honest);
        if (bounded) executor.executeBounded(index, "", amountsIn);
        else executor.execute(index, "");
        ++ghostExecutions;

        (, uint256[] memory afterwards) = index.components();
        for (uint256 i = 0; i < before.length; ++i) {
            previewMisled = previewMisled || afterwards[i] != preview[i];
            // Each unit moves by no more than the band either way, plus one raw unit of rounding (CR-I03).
            unitBoundsBroken = unitBoundsBroken || afterwards[i] * lambdaMax < before[i] * lambdaMin
                || afterwards[i] * lambdaMin > before[i] * lambdaMax + lambdaMin;
        }
    }

    /// @dev The moving components, at the shadow prices, are worth at least λ / λmax of what they were.
    function _checkValue(
        uint256[] memory before,
        uint256[] memory preview,
        uint256 keepMask,
        uint256 lambda,
        uint256 lambdaMax
    ) internal {
        uint256 was = 0;
        uint256 will = 0;
        for (uint256 i = 0; i < before.length; ++i) {
            if ((keepMask >> i) & 1 == 1) continue;
            was += before[i] * shadowPrices[i];
            will += preview[i] * shadowPrices[i];
        }
        worstCaseBroken = worstCaseBroken || will * lambdaMax < was * lambda;
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
        if (growing == amountsIn.length) return; // nothing is bought at this λ

        executor.setMode(MockRebalanceExecutor.Mode.Short);
        executor.setShortComponent(growing);
        (bool settled,) = address(executor).call(abi.encodeCall(MockRebalanceExecutor.execute, (index, "")));
        // A settlement here would break the nonce-against-ghost invariant as well, on top of this flag.
        shortFillSucceeded = shortFillSucceeded || settled;
    }
}

contract IndexHubInvariantTest is Test {
    MockMarket market;
    IndexFactory factory;
    IndexHub index;
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
        // Listed with their units as their supplies, so k = K_SCALE creates exactly these units. The last sits at
        // MIN_RAW_UNITS, so rounding bites.
        uint256[] memory supplies = new uint256[](4);
        (supplies[0], supplies[1], supplies[2], supplies[3]) = (100_000, 1e16, 10e6, factory.MIN_RAW_UNITS());

        address[] memory t = new address[](comps.length);
        for (uint256 i = 0; i < comps.length; ++i) {
            t[i] = address(comps[i]);
            vm.prank(owner);
            factory.proposeListing(t[i], supplies[i]);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < comps.length; ++i) {
            factory.executeListing(t[i]);
        }
        index = IndexHub(factory.createIndex("Inv", "INV", t, factory.K_SCALE()));

        for (uint256 i = 0; i < 5; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
        handler = new IndexHandler(index, comps, actors, guardian);
        targetContract(address(handler));
    }

    /// @dev Walks the handler through every path once, so its coverage does not depend on what the fuzzer calls.
    function test_handlerReachesEveryPath() public {
        // Nothing to do yet: no shares, no claims, no pending rebalance, and units follow supplies exactly.
        handler.redeem(0, 0, 1e18);
        handler.redeemSkipping(0, 0, 1e18, 1);
        handler.transfer(0, 1, 1e18);
        handler.claim(0, 0, 0);
        handler.cancelRebalance();
        handler.executeRebalance(0, false);
        handler.executeRebalanceShort(0);
        handler.moveShadowPrice(1, 5e18);
        handler.warp(1 hours);
        handler.startRebalance(0, 0, false); // warps to the interval, then finds the band too narrow
        (uint256 eta,,,,) = index.pendingRebalance();
        assertEq(eta, 0);

        // An empty index: a short fill has nothing to shortchange, and an honest fill settles at λmax.
        handler.reviseSupplies(0); // every supply up a step: a uniform change, still nothing to trade
        handler.startRebalance(0, 0, false);
        (eta,,,,) = index.pendingRebalance();
        assertEq(eta, 0, "a uniform revision trades nothing");
        handler.reviseSupplies(0x4); // the second component down a step, the others up
        handler.startRebalance(0, 0, false);
        handler.startRebalance(0, 0, false); // already pending
        handler.executeRebalanceShort(0);
        handler.executeRebalance(0, false);
        assertEq(index.rebalanceNonce(), 1);

        // After a cancel, strangers wait out the cooldown, which the handler warps past.
        handler.reviseSupplies(0x4);
        handler.startRebalance(0, 0, false);
        handler.cancelRebalance();
        handler.startRebalance(0, 0, false);
        (eta,,,,) = index.pendingRebalance();
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
        handler.executeRebalance(0, true); // the bounded entry point, at the amounts the preview quoted (DA-13)
        assertEq(index.rebalanceNonce(), 2, "an honest fill settles");
        assertEq(handler.ghostExecutions(), 2);
        assertFalse(handler.shortFillSucceeded());

        // The guardian can start with a keep mask, once a revision moves the components it leaves moving apart.
        for (uint256 seed = 1; seed < 64; ++seed) {
            handler.reviseSupplies(seed);
            (, uint256 low, uint256 high) = index.previewBand(1);
            if (high * 1e18 >= low * (1e18 + index.MIN_BAND())) break;
        }
        handler.startRebalance(0, 1, true);
        (, uint256 keepMask,,,) = index.pendingRebalance();
        assertEq(keepMask, 1);
        assertFalse(handler.unitBoundsBroken());
        assertFalse(handler.worstCaseBroken());
        assertFalse(handler.clampBroken());
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
        assertFalse(handler.unitBoundsBroken(), "units move at most the band per rebalance, plus one raw unit");
        assertFalse(handler.holdOffMisjudged(), "canStartRebalance says when a stranger may start");
        assertFalse(handler.previewMisled(), "a fill settles exactly the units its preview showed");
        (uint256 eta,,,, uint256[] memory ratios) = index.pendingRebalance();
        assertEq(ratios.length, eta == 0 ? 0 : comps.length, "ratios exist exactly while a rebalance is pending");
    }

    /// @dev The band's promises, at prices the hub never sees: every stored ratio lies within the clamp and the band,
    ///      and no fill ever left the moving components worth less than λ / λmax of what they were.
    function invariant_theBandBoundsEveryFill() public view {
        assertFalse(handler.clampBroken(), "a ratio outside the clamp or the band");
        assertFalse(handler.worstCaseBroken(), "a fill worth less than lambda / lambdaMax of the moving value");
    }
}
