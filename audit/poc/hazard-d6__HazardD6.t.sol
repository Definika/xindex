// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

contract HazardD6Test is Test {
    function test_delistedTokenIsReproposedAndRelisted() public {
        MockMarket market = new MockMarket();
        ConfigureWhitelist configure = new ConfigureWhitelist();
        address guardian = makeAddr("guardian");
        IndexFactory factory = new IndexFactory(
            DEFAULT_SENDER, guardian, address(market.weth()), address(market.uniswapV3Factory()), address(market.usdc())
        );
        MockERC20 tokenB = new MockERC20("B", "B", 8);
        market.config(address(tokenB), 0);
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](1);
        list[0] = ConfigureWhitelist.Entry({token: address(tokenB), fee: 3000, referenceSupply: 21_000_000e8, excluded: new address[](0)});

        configure.propose(factory, list);
        vm.warp(block.timestamp + 2 days);
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(address(tokenB)));

        vm.prank(guardian);
        factory.delist(address(tokenB)); // emergency delist
        assertFalse(factory.isWhitelisted(address(tokenB)));

        // Later: routine reference-supply refresh run over the same list
        list[0].referenceSupply = 21_000_001e8;
        configure.propose(factory, list);
        assertGt(factory.listingEta(address(tokenB)), 0, "delisted token re-proposed");
        vm.warp(block.timestamp + 2 days);
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(address(tokenB)), "delisted token silently relisted");

        // Even with identical config: re-proposed, because isWhitelisted is false
        vm.prank(guardian);
        factory.delist(address(tokenB));
        configure.propose(factory, list);
        assertGt(factory.listingEta(address(tokenB)), 0, "re-proposed with identical config");
    }
}
