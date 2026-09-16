// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";

contract DeploySwapPoc is Test {
    function test_swappedWethAndUsdcDeploysOnChain1() public {
        Deploy deployer = new Deploy();
        MockMarket market = new MockMarket();
        MockSwapRouter router = new MockSwapRouter();
        vm.chainId(1);
        MockSafeT safe = new MockSafeT();
        Deploy.Market memory m = Deploy.Market({
            router: address(router),
            weth: address(market.usdc()), // swapped
            uniswapV3Factory: address(market.uniswapV3Factory()),
            usdc: address(market.weth()) // swapped
        });
        (IndexFactory factory,) = deployer.deploy(address(safe), makeAddr("g"), m);
        IIndexRule rule = IIndexRule(factory.RULE());
        assertEq(rule.WETH(), address(market.usdc()));
        assertEq(rule.USD_POOL(), address(market.usdPool()));
    }
}

contract MockSafeT {
    function getThreshold() external pure returns (uint256) { return 2; }
}
