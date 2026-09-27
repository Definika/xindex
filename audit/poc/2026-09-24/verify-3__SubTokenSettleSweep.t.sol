// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {IXindexErrors} from "../../src/interfaces/IXindexErrors.sol";
import {TestAggregator} from "../../script/testnet/TestAggregator.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice Verifier sweep: where does "less than one whole token cannot settle" actually hold? Includes an
///         8-decimal WBTC-like leg at the AGENTS.md-recommended ~10,000 raw units per token.
contract SubTokenSettleSweepTest is Test {
    function _setup(uint256 shares) internal returns (IndexToken index) {
        address owner = makeAddr("owner");
        IndexFactory factory = new IndexFactory(owner, makeAddr("guardian"));
        address[] memory t = new address[](3);
        uint8[3] memory dec = [uint8(18), 8, 18];
        int256[3] memory px = [int256(4_000e8), 110_000e8, 20e8];
        uint256[3] memory sup = [uint256(122_070_499e18), 19_900_000e8, 748_099_970e18];
        for (uint256 i = 0; i < 3; ++i) {
            t[i] = address(new MockERC20("C", "C", dec[i]));
            TestAggregator f = new TestAggregator("X / USD", 8, px[i]);
            vm.prank(owner);
            factory.proposeListing(
                t[i], IIndexFactory.TokenConfig({feed: address(f), maxStaleness: 5400, referenceSupply: sup[i]})
            );
        }
        vm.warp(block.timestamp + 2 days);
        for (uint256 i = 0; i < 3; ++i) {
            factory.executeListing(t[i]);
        }
        // Roughly $11 per index token: ~10,000 raw WBTC units, as AGENTS.md recommends for granularity.
        uint256[] memory units = new uint256[](3);
        (units[0], units[1], units[2]) = (0.001e18, 1e4, 0.2e18);
        index = IndexToken(factory.createIndex("S", "S", t, units, 0));
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 i = 0; i < 3; ++i) {
            MockERC20(t[i]).mint(address(this), need[i]);
            MockERC20(t[i]).approve(address(index), need[i]);
        }
        index.issue(shares, address(this));
        vm.warp(block.timestamp + 28 days);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        vm.warp(eta + 12 hours);
    }

    function _settles(uint256 shares) internal {
        IndexToken index = _setup(shares);
        assertEq(index.totalSupply(), shares);
        (,, uint256[] memory out_, uint256[] memory in_) = index.previewRebalance();
        uint256 nzIn;
        uint256 nzOut;
        for (uint256 i = 0; i < 3; ++i) {
            if (in_[i] != 0) ++nzIn;
            if (out_[i] != 0) ++nzOut;
        }
        assertGt(nzIn, 0, "growing leg non-zero");
        assertGt(nzOut, 0, "shrinking leg non-zero");
        MockRebalanceExecutor ex = new MockRebalanceExecutor();
        ex.execute(IIndexToken(address(index)), "");
        assertEq(index.rebalanceNonce(), 1);
    }

    function test_settles_0_999() public {
        _settles(0.999e18);
    }

    function test_settles_0_01() public {
        _settles(0.01e18);
    }

    function test_settles_1e15wei() public {
        _settles(1e15); // 0.001 token, about a cent
    }

    /// @dev The documented limit is real only in a dust band: a shrinking leg moves a raw unit, no growing leg does.
    function test_dustBandIsRefused() public {
        IndexToken index = _setup(1e12);
        (,, uint256[] memory out_, uint256[] memory in_) = index.previewRebalance();
        emit log_named_array("out", out_);
        emit log_named_array("in", in_);
        MockRebalanceExecutor ex = new MockRebalanceExecutor();
        vm.expectPartialRevert(IIndexToken.SettlementValueTooLow.selector);
        ex.execute(IIndexToken(address(index)), "");
        assertEq(index.rebalanceNonce(), 0);
    }

    /// @dev Below that band nothing moves at all, the multiplier is parity, and it settles again.
    function test_tinierDustSettlesEmpty() public {
        IndexToken index = _setup(3);
        (,, uint256[] memory out_, uint256[] memory in_) = index.previewRebalance();
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(out_[i], 0);
            assertEq(in_[i], 0);
        }
        MockRebalanceExecutor ex = new MockRebalanceExecutor();
        ex.execute(IIndexToken(address(index)), "");
        assertEq(index.rebalanceNonce(), 1);
    }
}
