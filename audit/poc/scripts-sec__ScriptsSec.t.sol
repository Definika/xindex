// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ScriptsTest} from "../Scripts.t.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";

contract ScriptsSecPoc is ScriptsTest {
    function test_poc_executeIgnoresEntryConfig() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        // pending proposal with a different reference supply than the operator's list
        IIndexFactory.TokenConfig memory other = _configFor(list[1]);
        other.referenceSupply = 1; // absurd
        vm.prank(DEFAULT_SENDER);
        factory.proposeListing(list[1].token, other);
        configure.propose(factory, list); // logs "already pending", does not flag mismatch
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list); // logs "listed"
        assertEq(factory.tokenConfig(list[1].token).referenceSupply, 1);
        assertTrue(factory.isWhitelisted(list[1].token));
    }

    function test_poc_wholeTokenSupplyAccepted() public {
        ConfigureWhitelist.Entry memory e = configure.parseEntry(
            string.concat(vm.toString(makeAddr("t")), ":500:20084784")
        );
        assertEq(e.referenceSupply, 20_084_784); // 0.20084784 WBTC in raw 8-decimal units
    }
}
