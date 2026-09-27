// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RebalanceSM} from "./RebalanceSM.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";

/// @notice DA-12 documents that a hostile guardian can hold an index off its rule by cancelling every proposal, and
///         that "the owner ends it by replacing that guardian" (README known limitations, ARCHITECTURE section 5,
///         AGENTS.md). The guardian has a second way to stall that the bound does not cover: it starts a keep-mask
///         rebalance that leaves only two components whose relative weight drifted a little, fills it itself at about
///         parity, and so SETTLES a rebalance that trades a sliver of the index. Settling resets `lastRebalance`, and
///         MIN_REBALANCE_INTERVAL then refuses every start, the owner's and the new guardian's included, for 28 days.
///         Replacing the guardian no longer ends the stall: it lasts until 28 days after the guardian's last sliver,
///         and nothing emits `RebalanceCancelled`, so a monitor that watches cancels sees ordinary rebalances.
contract KeepMaskStallTest is RebalanceSM {
    function setUp() public {
        // Launch-like capped basket; the market has moved (SOL -30%, LINK +40%, BTC +10%, UNI's supply +60%) so the
        // rule wants a real rebalance.
        _deploySystem(1);
    }

    function _nav() internal view returns (uint256) {
        return IIndexRule(factory.RULE()).navPerToken(address(index)) * index.totalSupply() / 1e18;
    }

    function test_guardianKeepMaskSliverOutlivesItsReplacement() public {
        vm.warp(mLast + MRI);

        (, uint256 fullTurnover) = index.previewTarget(0);
        emit log_named_decimal_uint("turnover the rule wants (share of the index)", fullTurnover, 18);
        assertGt(fullTurnover, 0.05e18, "the rule wants a real rebalance");

        // 1. The hostile guardian keeps five of seven components, leaving wSOL and UNI to trade between themselves
        //    (the cheapest pair on this basket that clears MIN_TURNOVER of its own value).
        uint256 keep = ((1 << N) - 1) & ~uint256((1 << 3) | (1 << 4));
        vm.prank(guardian0);
        index.startRebalance(keep);
        (uint256 eta,,) = index.pendingRebalance();

        // 2. The owner reacts at once and proposes a replacement guardian (7 days, which the guardian cannot cancel).
        vm.prank(owner0);
        factory.proposeGuardian(guardian1);
        uint256 replacementAt = factory.pendingGuardianEta();

        // 3. The guardian's own executor fills the sliver near parity as soon as the auction allows it to be fair.
        vm.warp(eta + 20 hours); // multiplier 1.0
        uint256 navBefore = _nav();
        (uint256 m,, uint256[] memory out,) = index.previewRebalance();
        uint256 outValue = 0;
        for (uint256 i = 0; i < N; ++i) {
            outValue += Math.mulDiv(out[i], IIndexRule(factory.RULE()).price(toks[i]), 1e18);
        }
        executor.execute(index, "");
        uint256 settledAt = block.timestamp;
        emit log_named_decimal_uint("multiplier of the sliver", m, 18);
        emit log_named_decimal_uint("value the sliver traded, share of the index", outValue * 1e18 / navBefore, 18);
        assertLt(outValue * 1e18 / navBefore, 0.005e18, "the sliver traded under 0.5% of the index");
        assertEq(index.rebalanceNonce(), 1, "it counts as the index's rebalance");

        // 4. The replacement takes effect. The owner and the new guardian both try to start the rebalance the rule
        //    wants, and both are refused until 28 days after the sliver.
        vm.warp(replacementAt);
        factory.executeGuardianChange();
        assertEq(factory.guardian(), guardian1);
        uint256 earliest = settledAt + MRI;
        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.RebalanceTooSoon.selector, earliest));
        index.startRebalance(0);
        vm.prank(owner0);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.RebalanceTooSoon.selector, earliest));
        index.startRebalance(0);
        emit log_named_uint("days the stall outlives the guardian's replacement", (earliest - replacementAt) / 1 days);
        assertGt(earliest - replacementAt, 21 days);

        // The rule still wants the rebalance it wanted before the sliver.
        vm.warp(earliest - 1);
        (, uint256 stillWanted) = index.previewTarget(0);
        emit log_named_decimal_uint("turnover still wanted a day before the stall ends", stillWanted, 18);
        assertGt(stillWanted, 0.05e18);
        assertEq(index.proposalCount(), 1, "one proposal, no cancel anywhere");
    }

    /// @dev The documented DA-12 path for contrast: a cancel stall ends the moment the replacement takes effect.
    function test_cancelStallEndsAtReplacement() public {
        vm.warp(mLast + MRI);
        vm.prank(stranger);
        index.startRebalance(0);
        vm.prank(owner0);
        factory.proposeGuardian(guardian1);
        uint256 replacementAt = factory.pendingGuardianEta();
        vm.prank(guardian0);
        index.cancelRebalance();
        vm.warp(replacementAt);
        factory.executeGuardianChange();
        vm.prank(guardian1);
        index.startRebalance(0); // no interval to wait out
    }
}
