// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {Methodology} from "../../src/libraries/Methodology.sol";
import {RedTeamBase} from "./RedTeamBase.sol";

/// @notice Verifier's cross-check of econ-1: the front-run exiter pays exactly the per-share haircut every holder at the
///         settlement pays (no more), and a mint's loss does not depend on the fill being ordered right behind it.
contract ExitFrontRunCheckTest is RedTeamBase {
    IndexToken index;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _setUpLaunch();
        index = _createOnRule(makeAddr("creator"), launch, Methodology.CAPPED, 100e18);
        _issue(index, alice, 50_000e18);
        _issue(index, bob, 50_000e18);
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        _move(launch[I_WSOL], 120, 100);
        _move(launch[I_LINK], 110, 100);
        _move(launch[I_WBTC], 92, 100);
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION() - 10 minutes);
    }

    /// Alice's front-run loss equals Bob's loss from simply holding through the same fill.
    function test_frontRunExiterPaysSameAsAnyHolder() public {
        uint256 preValue = _value(index, index.previewRedeem(50_000e18));
        executor.execute(IIndexToken(address(index)), "");
        vm.prank(alice);
        index.redeem(50_000e18, alice);
        vm.prank(bob);
        index.redeem(50_000e18, bob);
        uint256 a = _walletValue(index, alice);
        uint256 b = _walletValue(index, bob);
        console2.log("pre-fill value of 50k shares  ", preValue / 1e18);
        console2.log("alice (front-run exit)        ", a / 1e18);
        console2.log("bob (held through)            ", b / 1e18);
        assertApproxEqAbs(a, b, 1e18, "front-run exiter pays exactly the holder's haircut");
    }

    /// Carol's mint loss is the same whether the fill lands right behind her mint or an unrelated block later.
    function test_mintLossIndependentOfOrdering() public {
        address carol = makeAddr("carol");
        uint256 paid = _value(index, index.previewIssue(100_000e18));
        _issue(index, carol, 100_000e18);

        uint256 snap = vm.snapshotState();
        executor.execute(IIndexToken(address(index)), ""); // "back-run": immediately after the mint
        vm.prank(carol);
        index.redeem(100_000e18, carol);
        uint256 lossBackRun = paid - _walletValue(index, carol);
        vm.revertToState(snap);

        vm.warp(block.timestamp + 12); // an ordinary fill one block later
        executor.execute(IIndexToken(address(index)), "");
        vm.prank(carol);
        index.redeem(100_000e18, carol);
        uint256 lossLater = paid - _walletValue(index, carol);
        console2.log("carol loss, fill right behind mint", lossBackRun / 1e18);
        console2.log("carol loss, fill one block later  ", lossLater / 1e18);
        assertApproxEqRel(lossBackRun, lossLater, 0.01e18, "ordering is not what costs the minter");
    }
}
