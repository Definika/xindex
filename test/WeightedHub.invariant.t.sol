// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {PythStructs} from "../src/interfaces/pyth/PythStructs.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";

contract WeightedHandler is Test {
    uint256 internal constant WAD = 1e18;
    int32 internal constant EXPO = -8;

    WeightedHub public index;
    MockPyth public pyth;
    MockWeightedExecutor public executor;
    address public guardian;
    MockERC20[] public comps;
    bytes32[] public ids;
    address[] public actors;
    /// @dev The prices Pyth publishes, with exponent -8, each kept within a hundredth and a hundred times its start.
    int64[] public prices;
    int64[] internal _start;

    /// @dev The fee recipients: none is an actor, so what they hold moves only with fees.
    address public feeCreator;
    address public platform;
    address public referrer;

    uint256 public ghostIssued;
    uint256 public ghostRedeemed;
    uint256 public ghostFees;
    bool public feeMisjudged;
    /// @dev The streaming rates the index was created with, and when its clock last restarted, as the handler
    ///      models it: at every accrual that minted, and at every call on an empty index.
    uint256 internal constant STREAMING = 600;
    uint256 internal constant WHOLE = 365 days * 10_000;
    uint256 internal _lastAccrual;
    uint256 public ghostExecutions;
    bool public shortFillSucceeded;
    bool public holdOffMisjudged;
    bool public previewMisled;
    bool public muBoundBroken;
    bool public turnoverBroken;
    bool public nothingMisjudged;

    constructor(
        WeightedHub index_,
        MockPyth pyth_,
        MockERC20[] memory comps_,
        bytes32[] memory ids_,
        int64[] memory prices_,
        address[] memory actors_,
        address guardian_,
        address[3] memory recipients_
    ) {
        index = index_;
        pyth = pyth_;
        comps = comps_;
        ids = ids_;
        prices = prices_;
        _start = prices_;
        actors = actors_;
        guardian = guardian_;
        (feeCreator, platform, referrer) = (recipients_[0], recipients_[1], recipients_[2]);
        executor = new MockWeightedExecutor();
        _lastAccrual = block.timestamp;
    }

    /// @dev What the streaming fee mints on a call now: the rate times the time since the clock last restarted, as a
    ///      share `f` of the index, is `supply · f / (1 − f)` shares rounded down, capped just under the whole.
    function _streamingFee() internal view returns (uint256) {
        uint256 supply = index.totalSupply();
        uint256 part = STREAMING * (block.timestamp - _lastAccrual);
        if (part >= WHOLE) part = WHOLE - 1;
        return Math.mulDiv(supply, part, WHOLE - part);
    }

    /// @dev Restarts the modelled clock as the hub does: when a fee was minted, and when the index was empty.
    function _clock(uint256 feeShares, uint256 supplyBefore) internal {
        if (feeShares != 0 || supplyBefore == 0) _lastAccrual = block.timestamp;
    }

    /// @dev What the three fee recipients hold between them.
    function _recipientsHold() internal view returns (uint256) {
        return index.balanceOf(feeCreator) + index.balanceOf(platform) + index.balanceOf(referrer);
    }

    /// @dev The fee a call minted, against what the index's rates say it should have: 100 bps to the creator and 25
    ///      to the platform, on top of an issue rounded up and out of a redeem rounded down.
    function _accountFee(uint256 heldBefore, uint256 expected) internal {
        uint256 minted = _recipientsHold() - heldBefore;
        ghostFees += minted;
        feeMisjudged = feeMisjudged || minted != expected;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev The first actor from `seed` on that holds shares, or the seeded one if nobody does.
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
        uint256 held = _recipientsHold();
        uint256 supply = index.totalSupply();
        uint256 streaming = _streamingFee();
        vm.prank(from);
        index.issue(shares, _actor(toSeed), seed % 2 == 0 ? referrer : address(0));
        ghostIssued += shares;
        _accountFee(held, streaming + (shares * 10_000 + 9874) / 9875 - shares);
        _clock(streaming, supply);
    }

    /// @dev Anyone mints the streaming fee accrued so far.
    function accrueFees(uint256 seed) external {
        uint256 held = _recipientsHold();
        uint256 supply = index.totalSupply();
        uint256 streaming = _streamingFee();
        vm.prank(_actor(seed));
        index.accrueFees();
        _accountFee(held, streaming);
        _clock(streaming, supply);
    }

    function redeem(uint256 seed, uint256 toSeed, uint256 shares) external {
        address from = _holder(seed);
        uint256 bal = index.balanceOf(from);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        uint256 held = _recipientsHold();
        uint256 supply = index.totalSupply();
        uint256 streaming = _streamingFee();
        vm.prank(from);
        index.redeem(shares, _actor(toSeed));
        ghostRedeemed += shares;
        _accountFee(held, streaming + shares * 125 / 10_000);
        _clock(streaming, supply);
    }

    function redeemSkipping(uint256 seed, uint256 toSeed, uint256 shares, uint256 mask) external {
        address from = _holder(seed);
        uint256 bal = index.balanceOf(from);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        mask = bound(mask, 1, (1 << comps.length) - 1);
        uint256 held = _recipientsHold();
        uint256 supply = index.totalSupply();
        uint256 streaming = _streamingFee();
        vm.prank(from);
        index.redeemSkipping(shares, _actor(toSeed), mask);
        ghostRedeemed += shares;
        _accountFee(held, streaming + shares * 125 / 10_000);
        _clock(streaming, supply);
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
    // prices and time
    // ---------------------------------------------------------------------

    /// @dev Moves a component's published price anywhere from a hundredth to a hundred times its start.
    function movePrice(uint256 compSeed, uint256 factor) external {
        uint256 i = compSeed % comps.length;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 start = uint256(int256(_start[i]));
        // forge-lint: disable-next-line(unsafe-typecast)
        prices[i] = int64(int256(bound(factor, start / 100, start * 100)));
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 7 days));
    }

    // ---------------------------------------------------------------------
    // rebalancing
    // ---------------------------------------------------------------------

    /// @dev Warps to the first moment the caller may start, then starts.
    function startRebalance(uint256 seed, uint256 maskSeed, bool asGuardian) external {
        (uint256 eta,) = index.pendingRebalance();
        if (eta != 0 && block.timestamp <= eta + index.AUCTION_DURATION()) return;
        uint256 earliest = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        if (!asGuardian) {
            uint256 afterExpiry = eta == 0 ? 0 : eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY();
            earliest = Math.max(earliest, Math.max(index.restartAllowedAt(), afterExpiry));
        }
        if (block.timestamp < earliest) vm.warp(earliest);
        holdOffMisjudged = holdOffMisjudged || (!asGuardian && !index.canStartRebalance());

        uint256 mask = asGuardian ? bound(maskSeed, 0, (1 << comps.length) - 2) : 0;
        // A keep mask must leave two components moving (V5-L2).
        uint256 kept = 0;
        for (uint256 i = 0; i < comps.length; ++i) {
            kept += (mask >> i) & 1;
        }
        if (comps.length - kept < 2) mask = 0;
        vm.prank(asGuardian ? guardian : _actor(seed));
        index.startRebalance(mask);
    }

    function cancelRebalance() external {
        (uint256 eta,) = index.pendingRebalance();
        if (eta == 0) return;
        vm.prank(guardian);
        index.cancelRebalance();
    }

    /// @dev Warps into the auction if the notice is still running, and returns whether there is anything to fill.
    function _toAuction(uint256 offset) internal returns (bool open) {
        (uint256 eta,) = index.pendingRebalance();
        if (eta == 0 || block.timestamp > eta + index.AUCTION_DURATION()) return false;
        if (block.timestamp < eta) vm.warp(eta + bound(offset, 0, index.AUCTION_DURATION()));
        return true;
    }

    /// @dev Every moving component's update for the price time of this block.
    function _updates() internal view returns (bytes[] memory data) {
        (, uint256 keepMask) = index.pendingRebalance();
        uint64 time = uint64(index.priceTime());
        uint256 moving = 0;
        for (uint256 i = 0; i < comps.length; ++i) {
            if ((keepMask >> i) & 1 == 0) ++moving;
        }
        data = new bytes[](moving);
        uint256 k = 0;
        for (uint256 i = 0; i < comps.length; ++i) {
            if ((keepMask >> i) & 1 == 1) continue;
            data[k++] = pyth.update(ids[i], prices[i], 0, EXPO, time, time - 1);
        }
    }

    function _structs() internal view returns (PythStructs.Price[] memory out) {
        out = new PythStructs.Price[](comps.length);
        for (uint256 i = 0; i < comps.length; ++i) {
            out[i] = PythStructs.Price({price: prices[i], conf: 0, expo: EXPO, publishTime: 0});
        }
    }

    /// @dev The settlement the preview shows, or nothing when the index is on its weights at these prices.
    function _preview()
        internal
        returns (bool trades, uint256 mu, uint256[] memory units, uint256[] memory out, uint256[] memory in_)
    {
        try index.previewRebalance(_structs()) returns (
            uint256 mu_, uint256[] memory units_, uint256[] memory out_, uint256[] memory in__
        ) {
            return (true, mu_, units_, out_, in__);
        } catch (bytes memory reason) {
            nothingMisjudged = nothingMisjudged || bytes4(reason) != IWeightedHub.NothingToRebalance.selector;
            return (false, 0, units, out, in_);
        }
    }

    function executeRebalance(uint256 offset, bool bounded) external {
        if (!_toAuction(offset)) return;
        (bool trades, uint256 mu, uint256[] memory preview, uint256[] memory out, uint256[] memory in_) = _preview();
        if (!trades) return;
        _checkValue(mu, out, in_);

        bytes[] memory data = _updates();
        uint256 held = _recipientsHold();
        uint256 supply = index.totalSupply();
        uint256 streaming = _streamingFee();
        executor.setMode(MockWeightedExecutor.Mode.Honest);
        if (bounded) executor.executeBounded(index, "", data, in_);
        else executor.execute(index, "", data);
        ++ghostExecutions;
        // The fill accrues the streaming fee first, like every issue and redeem.
        _accountFee(held, streaming);
        _clock(streaming, supply);

        (, uint256[] memory afterwards) = index.components();
        for (uint256 i = 0; i < afterwards.length; ++i) {
            previewMisled = previewMisled || afterwards[i] != preview[i] || afterwards[i] == 0;
        }
    }

    /// @dev At the settling prices, what comes in is worth at least μ times what leaves, and what leaves of each
    ///      component is at most MAX_TURNOVER of its units, at any price (V5-M2).
    function _checkValue(uint256 mu, uint256[] memory out, uint256[] memory in_) internal {
        (, uint256 keepMask) = index.pendingRebalance();
        (, uint256[] memory units) = index.components();
        (,, uint8[] memory decimals) = index.componentTerms();
        uint256 valueOut = 0;
        uint256 valueIn = 0;
        // The settlement's supply: the fee the fill accrues first is minted on top of today's.
        uint256 supply = index.totalSupply() + _streamingFee();
        for (uint256 i = 0; i < comps.length; ++i) {
            if ((keepMask >> i) & 1 == 1) continue;
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 q = uint256(int256(prices[i])) * 10 ** (36 - 8 - uint256(decimals[i]));
            valueOut += out[i] * q;
            valueIn += in_[i] * q;
            turnoverBroken = turnoverBroken || out[i] * WAD > Math.mulDiv(units[i], supply, WAD) * index.MAX_TURNOVER();
        }
        muBoundBroken = muBoundBroken || valueIn * WAD < valueOut * mu;
    }

    /// @dev Delivers one raw unit too little of a growing component. It can never settle.
    function executeRebalanceShort(uint256 offset) external {
        if (!_toAuction(offset)) return;
        (bool trades,,,, uint256[] memory amountsIn) = _preview();
        if (!trades) return;
        uint256 growing = amountsIn.length;
        for (uint256 i = 0; i < amountsIn.length; ++i) {
            if (growing == amountsIn.length && amountsIn[i] != 0) growing = i;
        }
        if (growing == amountsIn.length) return; // nothing is bought

        executor.setMode(MockWeightedExecutor.Mode.Short);
        executor.setShortComponent(growing);
        bytes[] memory data = _updates();
        (bool settled,) = address(executor).call(abi.encodeCall(MockWeightedExecutor.execute, (index, "", data)));
        shortFillSucceeded = shortFillSucceeded || settled;
    }
}

contract WeightedHubInvariantTest is Test {
    MockPyth pyth;
    WeightedIndexFactory factory;
    WeightedHub index;
    WeightedHandler handler;
    MockERC20[] comps;
    address[] actors;
    /// @dev The creator, the platform and the referrer, outside the actors.
    address[3] recipients = [makeAddr("feeCreator"), makeAddr("platform"), makeAddr("referrer")];

    function setUp() public {
        vm.warp(1_800_000_000);
        address owner = makeAddr("owner");
        address guardian = makeAddr("guardian");
        pyth = new MockPyth();
        factory = new WeightedIndexFactory(owner, guardian, address(pyth));

        comps.push(new MockERC20("BTC", "BTC", 8));
        comps.push(new MockERC20("ETH", "ETH", 18));
        comps.push(new MockERC20("USD", "USD", 6));
        comps.push(new MockERC20("ODD", "ODD", 13));
        bytes32[] memory ids = new bytes32[](4);
        int64[] memory prices = new int64[](4);
        (prices[0], prices[1], prices[2], prices[3]) = (60_000e8, 2000e8, 1e8, 0.5e8);
        // On their weights at those prices but the last, which starts at MIN_RAW_UNITS, so rounding and the turnover
        // cap both bite.
        uint256[4] memory units = [uint256(0.0004e8), 0.01e18, 20e6, factory.MIN_RAW_UNITS()];
        uint256[4] memory weights = [uint256(2400), 2000, 2000, 3600];

        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](4);
        for (uint256 i = 0; i < comps.length; ++i) {
            ids[i] = keccak256(abi.encode("feed", i));
            vm.prank(owner);
            factory.proposeListing(address(comps[i]), ids[i]);
            specs[i] =
                IWeightedIndexFactory.ComponentSpec({token: address(comps[i]), weight: weights[i], units: units[i]});
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < comps.length; ++i) {
            factory.executeListing(address(comps[i]));
        }
        // The creator's caps and the platform's, with half of the platform's mint fee to a referrer, so every fee
        // path carries value under the invariants: 100 and 25 bps on every issue and redeem, 500 and 100 bps a year.
        vm.prank(owner);
        factory.setFeePolicy(25, 100, 5000, recipients[1], 0);
        index = WeightedHub(
            factory.createIndex(
                "Inv",
                "INV",
                specs,
                IWeightedIndexFactory.IndexParams({
                    creatorFeeBps: 100,
                    creatorStreamingBps: 500,
                    maxPlatformFeeBps: 25,
                    maxPlatformStreamingBps: 100,
                    rebalanceInterval: 7 days,
                    gated: false,
                    listed: true
                })
            )
        );
        factory.transferCreator(address(index), recipients[0]);

        for (uint256 i = 0; i < 5; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
        handler = new WeightedHandler(index, pyth, comps, ids, prices, actors, guardian, recipients);
        targetContract(address(handler));
    }

    /// @dev Walks the handler through every path once, so its coverage does not depend on what the fuzzer calls.
    function test_handlerReachesEveryPath() public {
        handler.redeem(0, 0, 1e18);
        handler.redeemSkipping(0, 0, 1e18, 1);
        handler.transfer(0, 1, 1e18);
        handler.claim(0, 0, 0);
        handler.cancelRebalance();
        handler.executeRebalance(0, false);
        handler.executeRebalanceShort(0);
        handler.warp(1 hours);
        handler.accrueFees(0);

        // An empty index: nothing to shortchange, and an honest fill settles at MU_MAX.
        handler.startRebalance(0, 0, false);
        handler.startRebalance(0, 0, false); // already pending
        handler.executeRebalanceShort(0);
        handler.executeRebalance(0, false);
        assertEq(index.rebalanceNonce(), 1);

        // After a cancel, strangers wait out the hold-off, which the handler warps past.
        handler.startRebalance(0, 0, false);
        handler.cancelRebalance();
        handler.startRebalance(0, 0, false);
        (uint256 eta,) = index.pendingRebalance();
        assertGt(eta, 0);

        // Holders act during the notice; prices move; a short fill fails, before and after donations.
        handler.issue(0, 0, 3e18);
        handler.redeem(0, 0, 1e18);
        handler.redeemSkipping(0, 0, 1e18, 1);
        handler.claim(0, 0, 0);
        handler.transfer(0, 1, 5e17);
        handler.movePrice(1, 4000e8);
        handler.executeRebalanceShort(0);
        assertEq(index.rebalanceNonce(), 1, "one raw unit short, no settlement");
        for (uint256 i = 0; i < comps.length; ++i) {
            handler.donate(i, 1e30);
        }
        handler.executeRebalanceShort(0);
        assertEq(index.rebalanceNonce(), 1, "the donations belong to the holders, not to the executor");
        handler.executeRebalance(0, true);
        assertEq(index.rebalanceNonce(), 2, "an honest fill settles");

        // The guardian starts with a keep mask; a fill moves only the others.
        handler.startRebalance(0, 1, true);
        (, uint256 keepMask) = index.pendingRebalance();
        assertEq(keepMask, 1);
        handler.movePrice(2, 0.5e8);
        handler.executeRebalance(0, false);
        assertEq(index.rebalanceNonce(), 3);

        // Fills at μ = 1 bring the index onto its weights within a few rebalances, the unit cap allowing; then the next
        // fill has nothing to trade and is refused (V5-L2), and the handler skips it.
        uint256 fills;
        uint256 rounds = 0;
        do {
            fills = index.rebalanceNonce();
            handler.startRebalance(0, 0, false);
            handler.executeRebalance(12 hours, false);
            ++rounds;
        } while (index.rebalanceNonce() != fills && rounds < 8);
        assertEq(index.rebalanceNonce(), fills, "the last fill found nothing to trade");
        handler.executeRebalanceShort(12 hours);
        assertEq(index.rebalanceNonce(), fills);
        assertFalse(handler.nothingMisjudged());

        assertFalse(handler.muBoundBroken());
        assertFalse(handler.turnoverBroken());
        assertFalse(handler.previewMisled());
        assertFalse(handler.shortFillSucceeded());

        // A lifetime without an accrual: the fee's share is capped just under the whole, in the hub and in the model.
        handler.issue(0, 0, 1e18);
        vm.warp(block.timestamp + 20 * 365 days);
        handler.accrueFees(0);
        assertFalse(handler.feeMisjudged(), "the capped accrual is what the model says");
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
        assertEq(index.totalSupply(), handler.ghostIssued() + handler.ghostFees() - handler.ghostRedeemed());
        uint256 sum = 0;
        for (uint256 i = 0; i < actors.length; ++i) {
            sum += index.balanceOf(actors[i]);
        }
        for (uint256 i = 0; i < recipients.length; ++i) {
            sum += index.balanceOf(recipients[i]);
        }
        assertEq(sum, index.totalSupply());
    }

    function invariant_feesAreExactlyTheRates() public view {
        assertFalse(handler.feeMisjudged(), "every fee minted is what the rates say, no more and no less");
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
        assertFalse(handler.holdOffMisjudged(), "canStartRebalance says when a stranger may start");
        assertFalse(handler.previewMisled(), "a fill settles exactly the units its preview showed, none zero");
        assertFalse(handler.muBoundBroken(), "what comes in is worth at least mu times what leaves");
        assertFalse(handler.turnoverBroken(), "a fill sends out no more than MAX_TURNOVER of a component's units");
        assertFalse(handler.nothingMisjudged(), "a preview refuses only an index on its weights");
        (uint256[] memory weights,,) = index.componentTerms();
        uint256 total = 0;
        for (uint256 i = 0; i < weights.length; ++i) {
            total += weights[i];
        }
        assertEq(total, index.TOTAL_WEIGHT(), "the weights never change");
    }
}
