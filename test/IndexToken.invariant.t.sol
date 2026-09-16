// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
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
    address public oddExcluded;
    MockERC20[] public comps;
    int24[] public baseTicks;
    address[] public actors;

    uint256 public ghostIssued;
    uint256 public ghostRedeemed;
    uint256 public ghostExecutions;
    bool public shortFillSucceeded;
    bool public unitBoundsBroken;

    constructor(
        IndexToken index_,
        MockERC20[] memory comps_,
        int24[] memory baseTicks_,
        address[] memory actors_,
        MockMarket market_,
        address guardian_,
        address oddExcluded_
    ) {
        index = index_;
        comps = comps_;
        baseTicks = baseTicks_;
        actors = actors_;
        market = market_;
        guardian = guardian_;
        oddExcluded = oddExcluded_;
        executor = new MockRebalanceExecutor();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
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
        address from = _actor(seed);
        uint256 bal = index.balanceOf(from);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(from);
        index.redeem(shares, _actor(toSeed));
        ghostRedeemed += shares;
    }

    function redeemSkipping(uint256 seed, uint256 toSeed, uint256 shares, uint256 mask) external {
        address from = _actor(seed);
        uint256 bal = index.balanceOf(from);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        mask = bound(mask, 1, (1 << comps.length) - 1);
        vm.prank(from);
        index.redeemSkipping(shares, _actor(toSeed), mask);
        ghostRedeemed += shares;
    }

    function claim(uint256 seed, uint256 compSeed, uint256 toSeed) external {
        address from = _actor(seed);
        address token = address(comps[compSeed % comps.length]);
        if (index.claimOf(from, token) == 0) return;
        vm.prank(from);
        index.claim(token, _actor(toSeed));
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

    /// @dev Moves a component's time-weighted price up to about 7x either way from where it started. WETH has no pool.
    function movePrice(uint256 compSeed, int256 delta) external {
        uint256 i = compSeed % comps.length;
        if (address(comps[i]) == address(market.weth())) return;
        market.setPriceTick(address(comps[i]), baseTicks[i] + int24(bound(delta, -20_000, 20_000)));
    }

    /// @dev ODD counts on-chain supply with one excluded holder: minting there leaves its cap unchanged, minting to
    ///      anyone else raises it.
    function mintOddSupply(uint256 amount, bool toExcluded) external {
        comps[3].mint(toExcluded ? oddExcluded : actors[0], bound(amount, 0, 1e30));
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
        uint256 restart = index.restartAllowedAt();
        if (!asGuardian && restart > earliest) earliest = restart;
        if (block.timestamp < earliest) vm.warp(earliest);

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
        return true;
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

    /// @dev Delivers one raw unit too little of a growing component. It can settle only when the index already holds at
    ///      least that much surplus of the component, from rounding or donations, so holders stay fully backed.
    function executeRebalanceShort(uint256 offset) external {
        if (!_toAuction(offset)) return;
        (, uint256[] memory units,, uint256[] memory amountsIn) = index.previewRebalance();
        uint256 growing = amountsIn.length;
        for (uint256 i = 0; i < amountsIn.length; ++i) {
            if (growing == amountsIn.length && amountsIn[i] != 0) growing = i;
        }
        if (growing == amountsIn.length) return; // an empty index moves nothing
        MockERC20 token = comps[growing];
        uint256 required = Math.mulDiv(index.totalSupply(), units[growing], 1e18) + index.totalClaims(address(token));
        uint256 surplus = token.balanceOf(address(index)) + amountsIn[growing] - required;

        executor.setMode(MockRebalanceExecutor.Mode.Short);
        executor.setShortComponent(growing);
        (bool settled,) = address(executor).call(abi.encodeCall(MockRebalanceExecutor.execute, (index, "")));
        if (settled) ++ghostExecutions;
        shortFillSucceeded = shortFillSucceeded || (settled && surplus == 0);
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
        address oddExcluded = makeAddr("oddExcluded");
        market = new MockMarket();
        factory = new IndexFactory(
            owner, guardian, address(market.weth()), address(market.uniswapV3Factory()), address(market.usdc())
        );

        comps.push(new MockERC20("WBTC", "WBTC", 8));
        comps.push(market.weth());
        comps.push(market.usdc());
        comps.push(new MockERC20("ODD", "ODD", 13));
        uint256[] memory units = new uint256[](4);
        (units[0], units[1], units[2], units[3]) = (100_000, 1e16, 10e6, 7); // the last is tiny so rounding bites

        // Prices that make every component worth about 0.01 WETH per index token, and supplies proportional to the
        // units, so the basket starts on its rule and supply changes create real turnover. ODD counts on-chain supply.
        int24[] memory ticks = new int24[](4);
        (ticks[0], ticks[1], ticks[2], ticks[3]) = (253_297, 0, 207_243, 348_972);
        uint256[] memory supplies = new uint256[](4);
        (supplies[0], supplies[1], supplies[2], supplies[3]) = (1e34, 1e45, 1e36, 0);
        comps[3].mint(makeAddr("oddHolder"), 7e29);

        address[] memory t = new address[](comps.length);
        address[] memory excluded = new address[](1);
        excluded[0] = oddExcluded;
        for (uint256 i = 0; i < comps.length; ++i) {
            t[i] = address(comps[i]);
            IIndexFactory.TokenConfig memory config =
                market.configWith(t[i], ticks[i], supplies[i], i == 3 ? excluded : new address[](0));
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
        handler = new IndexHandler(index, comps, ticks, actors, market, guardian, oddExcluded);
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

        // Holders act during the notice; then a short fill fails without surplus and settles once donations cover it.
        handler.issue(0, 0, 3e18);
        handler.redeem(0, 0, 1e18);
        handler.redeemSkipping(0, 0, 1e18, 1);
        handler.claim(0, 0, 0);
        handler.transfer(0, 1, 5e17);
        handler.executeRebalanceShort(0);
        assertEq(index.rebalanceNonce(), 1, "no surplus, no settlement");
        for (uint256 i = 0; i < comps.length; ++i) {
            handler.donate(i, 1e30);
        }
        handler.executeRebalanceShort(0);
        assertEq(index.rebalanceNonce(), 2, "the donations covered the missing unit");
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
        assertFalse(handler.shortFillSucceeded(), "a short fill never settles without surplus to cover it");
        assertFalse(handler.unitBoundsBroken(), "units move between half and 2.5 times per rebalance");
        (uint256 eta,, uint256[] memory targets) = index.pendingRebalance();
        assertEq(targets.length, eta == 0 ? 0 : comps.length, "targets exist exactly while a rebalance is pending");
    }
}
