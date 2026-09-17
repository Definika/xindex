// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test, console2} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexRule} from "../../src/IndexRule.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

contract CappedRank3Poc is Test {
    IndexRule rule;
    function setUp() public {
        MockMarket market = new MockMarket();
        IndexFactory factory = new IndexFactory(makeAddr("o"), makeAddr("g"), address(market.weth()), address(market.uniswapV3Factory()), address(market.usdc()));
        rule = IndexRule(factory.RULE());
    }
    function test_defaultMainnetListCapped() public view {
        // USD market caps (rough, Sep 2026): BTC 20.08M*110k, ETH 122.05M*4300, LINK 748.1M*22, UNI 623.2M*9, tBTC 5500*110k
        uint256[] memory caps = new uint256[](5);
        caps[0] = 20_084_784 * 110_000;
        caps[1] = 122_050_160 * 4_300;
        caps[2] = 748_099_970 * 22;
        caps[3] = 623_212_423 * 9;
        caps[4] = 5_500 * 110_000;
        uint256[] memory w = rule.weightsFromCaps(caps, 1);
        for (uint256 i = 0; i < 5; ++i) console2.log(i, w[i]);
        assertGt(w[2], w[0], "LINK (rank 3) outweighs BTC (rank 1, the capped 30%)");
        assertGt(w[2], w[1]);
        // LINK at half its price still exceeds the 20% "second" cap
        caps[2] = 748_099_970 * 11;
        w = rule.weightsFromCaps(caps, 1);
        console2.log("LINK at $11", w[2]);
        assertGt(w[2], 0.2e18);
    }
}
