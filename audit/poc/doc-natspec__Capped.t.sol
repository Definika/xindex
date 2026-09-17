// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test, console2} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexRule} from "../../src/IndexRule.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
contract CappedDocPoc is Test {
    function test_thirdRankOutweighsTop() public {
        MockMarket market = new MockMarket();
        IndexFactory f = new IndexFactory(address(1), address(2), address(market.weth()), address(market.uniswapV3Factory()), address(market.usdc()));
        IndexRule rule = IndexRule(f.RULE());
        uint256[] memory caps = new uint256[](5);
        caps[0] = 2000; caps[1] = 500; caps[2] = 15; caps[3] = 6; caps[4] = 1; // BTC, ETH, LINK, UNI, tBTC-like ($B)
        uint256[] memory w = rule.weightsFromCaps(caps, 1);
        for (uint256 i = 0; i < 5; ++i) console2.log(i, w[i]);
        assertGt(w[2], w[0]);
    }
}
