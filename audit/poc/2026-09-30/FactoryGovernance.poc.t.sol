// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";
import {IndexHub} from "../../src/IndexHub.sol";
import {IIndexHub} from "../../src/interfaces/IIndexHub.sol";

/// @notice PoCs for the factory and governance review of v4 Stage A (aea5d58).
contract FactoryGovernancePoC is Test {
    IndexFactory factory;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");

    uint256 constant TX_GAS_CAP = 2 ** 24; // EIP-7825
    uint256 constant SUPPLY = 1_000_000_000e18;

    function setUp() public {
        factory = new IndexFactory(owner, guardian);
    }

    /// @dev `n` freshly listed tokens, in ascending address order.
    function _listedAscending(uint256 n) internal returns (address[] memory t) {
        t = new address[](n);
        vm.startPrank(owner);
        for (uint256 i = 0; i < n; ++i) {
            t[i] = address(new MockERC20("M", "M", 18));
            factory.proposeListing(t[i], SUPPLY);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < n; ++i) {
            factory.executeListing(t[i]);
        }
        // insertion sort, ascending
        for (uint256 i = 1; i < n; ++i) {
            address x = t[i];
            uint256 j = i;
            while (j > 0 && t[j - 1] > x) {
                t[j] = t[j - 1];
                --j;
            }
            t[j] = x;
        }
    }

    /// @dev Intrinsic cost of a transaction carrying `data`: 21,000 plus 4 per zero byte and 16 per non-zero byte.
    function _intrinsic(bytes memory data) internal pure returns (uint256 gas) {
        gas = 21_000;
        for (uint256 i = 0; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    function _proposeGas(address[] memory tokens, uint256[] memory supplies) internal returns (uint256 total) {
        vm.cool(address(factory));
        bytes memory data = abi.encodeCall(IIndexFactory.proposeSupplies, (tokens, supplies));
        vm.prank(owner);
        uint256 before = gasleft();
        factory.proposeSupplies(tokens, supplies);
        uint256 used = before - gasleft();
        total = used + _intrinsic(data);
    }

    /// @notice MAX_BATCH (256) is not reachable for tokens never named in a batch: the first batch naming them pays
    ///         a zero-to-non-zero write of `_batchOf` per token on top of the two array slots, and does not fit one
    ///         transaction under EIP-7825's 2^24 cap, before any Safe overhead.
    function test_poc_firstMaxBatchDoesNotFitOneTransaction() public {
        uint256 n = factory.MAX_BATCH();
        address[] memory t = _listedAscending(n);
        uint256[] memory s = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            s[i] = SUPPLY + 1;
        }
        uint256 total = _proposeGas(t, s);
        console2.log("first 256-token proposeSupplies, gas incl. intrinsic:", total);
        assertGt(total, TX_GAS_CAP, "a first MAX_BATCH batch exceeds the per-transaction cap");

        // The largest first batch that fits, by bisection over fresh factories is costly; report the per-token cost.
        console2.log("per token:", total / n);
        console2.log("largest first batch under the cap, roughly:", TX_GAS_CAP / (total / n));
    }

    /// @notice Once every token's `_batchOf` slot is non-zero (a batch named it before, even one cancelled), the same
    ///         256-token batch fits: the limit is a first-time cost, which a cancelled warm-up batch works around.
    function test_poc_warmMaxBatchFits() public {
        uint256 n = factory.MAX_BATCH();
        address[] memory t = _listedAscending(n);
        uint256[] memory s = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            s[i] = SUPPLY + 1;
        }
        // Warm-up in two halves, each cancelled.
        uint256 half = n / 2;
        address[] memory t1 = new address[](half);
        uint256[] memory s1 = new uint256[](half);
        address[] memory t2 = new address[](n - half);
        uint256[] memory s2 = new uint256[](n - half);
        for (uint256 i = 0; i < half; ++i) {
            (t1[i], s1[i]) = (t[i], s[i]);
        }
        for (uint256 i = half; i < n; ++i) {
            (t2[i - half], s2[i - half]) = (t[i], s[i]);
        }
        uint256 g1 = _proposeGas(t1, s1);
        vm.prank(guardian);
        factory.cancelSupplies();
        uint256 g2 = _proposeGas(t2, s2);
        vm.prank(guardian);
        factory.cancelSupplies();
        console2.log("warm-up halves:", g1, g2);

        uint256 total = _proposeGas(t, s);
        console2.log("warm 256-token proposeSupplies, gas incl. intrinsic:", total);
        assertLt(total, TX_GAS_CAP, "a warm MAX_BATCH batch fits");
    }

    /// @notice The script's supplies mode never asks whether a batch is live, so while last week's batch is still
    ///         executable it emits `proposeSupplies` calldata that the factory refuses (SuppliesPending), computed
    ///         against the supplies that batch is about to replace.
    function test_poc_supplyCalldataWhileABatchIsLiveReverts() public {
        ConfigureWhitelist configure = new ConfigureWhitelist();
        MockERC20 a = new MockERC20("A", "A", 18);
        vm.prank(owner);
        factory.proposeListing(address(a), 1_000e18);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(a));

        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](1);
        list[0] = ConfigureWhitelist.Entry({token: address(a), referenceSupply: 1_004e18});
        bytes memory week1 = configure.supplyCalldata(factory, list);
        vm.prank(owner);
        (bool ok,) = address(factory).call(week1);
        assertTrue(ok);

        // A week later nobody has executed week 1 yet (it is live until eta + PROPOSAL_WINDOW).
        vm.warp(block.timestamp + 5 days);
        assertTrue(factory.suppliesPending());
        list[0].referenceSupply = 1_005e18;
        bytes memory week2 = configure.supplyCalldata(factory, list); // no warning, no revert
        vm.prank(owner);
        (ok,) = address(factory).call(week2);
        assertFalse(ok, "the Safe transaction the script emitted reverts SuppliesPending");
    }

    /// @notice Nothing on chain makes batches weekly: one can be proposed the moment the last one executes, so a supply
    ///         moves a step every LISTING_DELAY (2 days), three and a half times the documented weekly pace.
    function test_poc_batchesAreEveryTwoDaysNotWeekly() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        vm.prank(owner);
        factory.proposeListing(address(a), SUPPLY);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(a));
        uint256 start = block.timestamp;
        address[] memory one = new address[](1);
        uint256[] memory s = new uint256[](1);
        one[0] = address(a);
        for (uint256 i = 0; i < 3; ++i) {
            uint256 inForce = factory.referenceSupply(address(a));
            s[0] = inForce + inForce * factory.MAX_SUPPLY_STEP() / 1e18;
            vm.prank(owner);
            factory.proposeSupplies(one, s);
            vm.warp(block.timestamp + factory.LISTING_DELAY());
            factory.executeSupplies();
        }
        console2.log("days elapsed:", (block.timestamp - start) / 1 days);
        console2.log("supply now, per 1e18 of the start:", factory.referenceSupply(address(a)) * 1e18 / SUPPLY);
        assertEq(block.timestamp - start, 6 days);
        assertGt(factory.referenceSupply(address(a)), SUPPLY * 1015 / 1000);
    }

    /// @notice Relistings are a second, per-token channel for supply revisions, and unlike a batch it is not atomic:
    ///         two relistings proposed together, each moving its token's supply by the same half step, execute one at a
    ///         time, and a stranger who executes one and starts a rebalance before the other turns a uniform revision,
    ///         which trades nothing when applied whole, into a trade with a band that a lone executor fills at the
    ///         floor. The atomic-batch rule exists to prevent exactly this ("a stranger who could execute half a batch
    ///         and start a rebalance on the half would turn a uniform revision ... into a trade").
    function test_poc_twoRelistingsApplyAUniformRevisionHalfway() public {
        address stranger = makeAddr("stranger");
        address holder = makeAddr("holder");
        uint256 s0 = 1e24;
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        vm.startPrank(owner);
        factory.proposeListing(address(a), s0);
        factory.proposeListing(address(b), s0);
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(a));
        factory.executeListing(address(b));

        address[] memory t = new address[](2);
        (t[0], t[1]) = (address(a), address(b));
        IndexHub hub = IndexHub(factory.createIndex("I", "I", t, 1e18)); // 1e6 raw units of each
        uint256 shares = 1_000e18;
        uint256[] memory need = hub.previewIssue(shares);
        a.mint(holder, need[0]);
        b.mint(holder, need[1]);
        vm.startPrank(holder);
        a.approve(address(hub), need[0]);
        b.approve(address(hub), need[1]);
        hub.issue(shares, holder);
        vm.stopPrank();

        // The guardian delists both (say, an incident); later the owner relists both, each supply up by the same
        // 0.5%: applied whole, relative supplies do not move and nothing should trade.
        vm.startPrank(guardian);
        factory.delist(address(a));
        factory.delist(address(b));
        vm.stopPrank();
        uint256 s1 = s0 + s0 * factory.MAX_SUPPLY_STEP() / 1e18;
        vm.startPrank(owner);
        factory.proposeListing(address(a), s1);
        factory.proposeListing(address(b), s1);
        vm.stopPrank();
        vm.warp(block.timestamp + hub.MIN_REBALANCE_INTERVAL());

        uint256 snap = vm.snapshotState();
        // Applied together: nothing to trade.
        factory.executeListing(address(a));
        factory.executeListing(address(b));
        vm.expectPartialRevert(IIndexHub.BandTooNarrow.selector);
        hub.startRebalance(0);
        vm.revertToState(snap);

        // A stranger interleaves: executes one relisting, starts a rebalance on the half, executes the other.
        vm.startPrank(stranger);
        factory.executeListing(address(a));
        hub.startRebalance(0);
        factory.executeListing(address(b));
        vm.stopPrank();
        (uint256 eta,, uint256 lambdaMin, uint256 lambdaMax,) = hub.pendingRebalance();
        console2.log("band opened by the half revision (lambdaMin, lambdaMax):", lambdaMin, lambdaMax);
        assertGt(lambdaMax * 1e18, lambdaMin * (1e18 + hub.MIN_BAND()), "a real band");

        // A lone executor fills at the floor. A and B are equally priced per raw unit here, so what it nets in raw
        // units is value taken from the holders; applied atomically they would have lost nothing.
        MockRebalanceExecutor executor = new MockRebalanceExecutor();
        vm.warp(eta + hub.AUCTION_DURATION());
        executor.execute(IIndexHub(address(hub)), "");
        uint256[] memory out = executor.lastAmountsOut();
        uint256[] memory in_ = executor.lastAmountsIn();
        uint256 taken = out[0] + out[1] - in_[0] - in_[1];
        uint256 basket = need[0] + need[1];
        console2.log("raw units taken by the executor:", taken, "of a basket of", basket);
        console2.log("in basis points of the index:", taken * 10_000 / basket);
        assertGt(taken, 0);

        // With the second relisting in force, the next rebalance trades back: a second band over the same value.
        vm.warp(block.timestamp + hub.MIN_REBALANCE_INTERVAL());
        hub.startRebalance(0);
        (eta,, lambdaMin, lambdaMax,) = hub.pendingRebalance();
        console2.log("second band (lambdaMin, lambdaMax):", lambdaMin, lambdaMax);
        vm.warp(eta + hub.AUCTION_DURATION());
        executor.execute(IIndexHub(address(hub)), "");
        out = executor.lastAmountsOut();
        in_ = executor.lastAmountsIn();
        uint256 takenAgain = out[0] + out[1] - in_[0] - in_[1];
        console2.log("taken again, in basis points:", takenAgain * 10_000 / basket);
        assertGt(takenAgain, 0);
    }
}
