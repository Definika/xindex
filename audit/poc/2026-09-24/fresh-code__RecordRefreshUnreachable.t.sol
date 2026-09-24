// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DEFAULT_STALENESS, MockMarket, usdWad} from "../mocks/MockMarket.sol";

/// @notice RT-01's documented recourse cannot be carried out with the shipped listing script, and nothing the script
///         or the factory reports shows that it is needed.
///
///         The README's known limitation "A token's decimals are recorded at listing" says: a component whose
///         `decimals()` changes afterwards "is priced at the recorded decimals, wrong by a power of ten, until a config
///         refresh records the new ones: propose the same config again". The owner is a Safe on mainnet, so its only
///         supported path to a proposal is `ConfigureWhitelist` in safe mode. But `_action` skips every entry whose
///         config equals the one in force (silently, with no log line, for a listed token), so the "same config
///         again" is never emitted, and `status` reports the token as listed with the entry's config in force. The
///         record itself is only visible through the new `tokenDecimals` getter, which no script or event surfaces:
///         `TokenConfigured` does not carry it.
contract RecordRefreshUnreachableTest is Test {
    ConfigureWhitelist configure;
    MockMarket market;
    address guardian = makeAddr("guardian");
    int256 constant SOL_PRICE = 200e8; // dollars per whole token, 8-decimal feed

    function setUp() public {
        configure = new ConfigureWhitelist();
        market = new MockMarket();
    }

    function test_theDocumentedDecimalsRefreshIsNeverProposedByTheScript() public {
        // Script broadcasts come from DEFAULT_SENDER in tests, so it owns the factory, as the Safe does on mainnet.
        IndexFactory factory = new IndexFactory(DEFAULT_SENDER, guardian);
        IIndexRule rule = IIndexRule(factory.RULE());

        // A 9-decimal component (wSOL's shape), listed through the script at 200 dollars.
        MockERC20 wsol = new MockERC20("SOL", "SOL", 9);
        market.config(address(wsol), SOL_PRICE);
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](1);
        list[0] = ConfigureWhitelist.Entry({
            token: address(wsol),
            feed: address(market.feedOf(address(wsol))),
            maxStaleness: DEFAULT_STALENESS,
            referenceSupply: 587_507_739e9
        });
        address[] memory none = new address[](0);
        configure.propose(factory, list, none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertEq(factory.tokenDecimals(address(wsol)), 9);
        assertEq(rule.price(address(wsol)), usdWad(SOL_PRICE, 9));

        // The token's upgradeable implementation now reports 18 decimals (the case the README's limitation covers).
        wsol.setDecimals(18);
        // The rule keeps pricing it at the recorded 9: every 1e18 raw units is valued 1e9 times too high relative
        // to the token's own decimals, which is what the README calls "wrong by a power of ten".
        assertEq(rule.price(address(wsol)), usdWad(SOL_PRICE, 9));
        assertEq(rule.price(address(wsol)) / usdWad(SOL_PRICE, 18), 1e9, "off by 10^9 against the live decimals");

        // The documented recourse: "propose the same config again". The script refuses to emit it.
        bytes[] memory calls = configure.safeCalldata(factory, list, none);
        assertEq(calls.length, 0, "safe mode emits no proposal: the entry equals the config in force");

        // And its read-only report calls the token healthy.
        ConfigureWhitelist.Report[] memory reports = configure.status(factory, list);
        assertTrue(reports[0].listed && reports[0].inForce, "status: listed, the entry's config in force");
        assertEq(reports[0].eta, 0, "nothing pending");

        // Only a hand-built proposeConfig with the identical config would record the new decimals, which the
        // factory accepts; the script never builds it.
        IIndexFactory.TokenConfig memory same = configure.configFor(list[0]);
        vm.prank(DEFAULT_SENDER);
        factory.proposeConfig(address(wsol), same);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(wsol));
        assertEq(factory.tokenDecimals(address(wsol)), 18, "the refresh works only when built by hand");
    }
}
