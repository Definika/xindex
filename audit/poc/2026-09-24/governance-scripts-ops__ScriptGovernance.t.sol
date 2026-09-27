// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DEFAULT_STALENESS, MockMarket} from "../mocks/MockMarket.sol";

/// @notice Red-team PoCs on the listing script's view of the factory.
contract ScriptGovernanceRedTeam is Test {
    ConfigureWhitelist configure;
    MockMarket market;
    IndexFactory factory;
    IIndexRule rule;
    address owner = makeAddr("ownerSafe");
    address guardian = makeAddr("guardian");
    address[] none;

    function setUp() public {
        configure = new ConfigureWhitelist();
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        rule = IIndexRule(factory.RULE());
    }

    function _entry(MockERC20 token, uint256 supply) internal returns (ConfigureWhitelist.Entry memory e) {
        market.config(address(token), 1e8);
        e = ConfigureWhitelist.Entry({
            token: address(token),
            feed: address(market.feedOf(address(token))),
            maxStaleness: DEFAULT_STALENESS,
            referenceSupply: supply
        });
    }

    /// @dev What the Safe does with safe mode's output: every logged call, sent by the owner, in one batch.
    function _safeSends(bytes[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(factory).call(calls[i]);
            assertTrue(ok, "the Safe batch executes");
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // RT-01's decimals record is invisible to the operator tooling, and the documented recourse cannot be proposed
    // through it.
    // -------------------------------------------------------------------------------------------------------------

    /// README, Known limitations: "A component whose decimals() changes afterwards ... is priced at the recorded
    /// decimals, wrong by a power of ten, until a config refresh records the new ones: propose the same config again".
    function test_RT01recourse_theScriptCannotProposeItAndStatusCannotSeeIt() public {
        // An upgradeable 18-decimal component (the launch list's upgradeable ones are wSOL and AAVE), listed through
        // the script's safe mode and execute mode, as on mainnet.
        MockERC20 token = new MockERC20("Upgradeable", "UPG", 18);
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](1);
        list[0] = _entry(token, 1_000_000e18);
        _safeSends(configure.safeCalldata(factory, list, none));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        market.setPrice(address(token), 1e8);
        configure.execute(factory, list);
        assertEq(factory.tokenDecimals(address(token)), 18);
        uint256 priceBefore = rule.price(address(token));

        // The token's admin upgrades it and decimals() now answers 8.
        token.setDecimals(8);

        // 1. `status`, the runbook's check, reports the token listed with exactly the entry's config and nothing
        //    pending. Nothing in its report or its log says that the rule prices the token at 18 decimals while the
        //    token answers 8.
        ConfigureWhitelist.Report[] memory reports = configure.status(factory, list);
        assertTrue(reports[0].listed && reports[0].inForce && reports[0].eta == 0, "status: all in order");
        assertEq(factory.tokenDecimals(address(token)), 18, "while the record is 18");
        assertEq(token.decimals(), 8, "and the token says 8");

        // 2. The documented recourse, proposing the same config again, is exactly what propose and safe mode refuse:
        //    `_action` returns Skip for a listed token whose config in force equals the entry, without even a log line.
        assertEq(configure.safeCalldata(factory, list, none).length, 0, "safe mode proposes nothing");
        IndexFactory keyOwned = new IndexFactory(DEFAULT_SENDER, guardian);
        MockERC20 token2 = new MockERC20("Upgradeable2", "UPG2", 18);
        ConfigureWhitelist.Entry[] memory list2 = new ConfigureWhitelist.Entry[](1);
        list2[0] = _entry(token2, 1_000_000e18);
        configure.propose(keyOwned, list2, none);
        vm.warp(block.timestamp + keyOwned.LISTING_DELAY());
        market.setPrice(address(token2), 1e8);
        configure.execute(keyOwned, list2);
        token2.setDecimals(8);
        configure.propose(keyOwned, list2, none);
        assertEq(keyOwned.listingEta(address(token2)), 0, "propose mode proposes nothing either");

        // 3. The factory itself accepts the recourse, so it can only be sent as hand-built calldata. When it executes,
        //    the rule's price moves ten orders of magnitude, and the only event is a TokenConfigured byte-identical to
        //    the listing's: a monitor that follows configs sees "no change".
        IIndexFactory.TokenConfig memory same = configure.configFor(list[0]);
        vm.prank(owner);
        factory.proposeConfig(address(token), same);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        market.setPrice(address(token), 1e8);
        vm.recordLogs();
        factory.executeListing(address(token));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one event");
        assertEq(logs[0].topics[0], IIndexFactory.TokenConfigured.selector);
        assertEq(logs[0].data, abi.encode(same.feed, same.maxStaleness, same.referenceSupply), "identical to the listing's");
        assertEq(factory.tokenDecimals(address(token)), 8);
        assertEq(rule.price(address(token)), priceBefore * 1e10, "price moved 1e10-fold with no event naming it");
    }

    /// @dev The same record rides along, unreviewed, on any routine refresh: the proposal is reviewed at one decimals
    ///      value and executed, at a moment any caller picks (CR-I09), at another.
    function test_RT01recourse_aReviewedSupplyRefreshExecutesAnUnreviewedDecimalsChange() public {
        MockERC20 token = new MockERC20("Upgradeable", "UPG", 18);
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](1);
        list[0] = _entry(token, 1_000_000e18);
        _safeSends(configure.safeCalldata(factory, list, none));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        market.setPrice(address(token), 1e8);
        configure.execute(factory, list);
        uint256 priceBefore = rule.price(address(token));

        // Monthly supply refresh, +5%: reviewed by the signers and the guardian with the token at 18 decimals. Its
        // ListingProposed event carries feed, staleness and supply, and nothing about decimals.
        list[0].referenceSupply = 1_050_000e18;
        _safeSends(configure.safeCalldata(factory, list, none));
        // During the notice the token's admin changes decimals() to 17.
        token.setDecimals(17);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        market.setPrice(address(token), 1e8);
        // Anyone executes it; execute mode even reports plain success.
        vm.prank(makeAddr("anyone"));
        factory.executeListing(address(token));
        assertEq(factory.tokenDecimals(address(token)), 17);
        assertEq(rule.price(address(token)), priceBefore * 10, "a tenfold repricing nobody reviewed");
        // With the reviewed supply of 1.05M "whole tokens" still counted in raw units, the component's market cap as
        // the rule sees it is now 10x what the signers approved.
        (,, uint256[] memory supplies) = rule.weights(_one(address(token)), 0);
        assertEq(supplies[0], 1_050_000e18);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    // -------------------------------------------------------------------------------------------------------------
    // A guardian's veto of a first listing does not survive the next routine run of the default list.
    // -------------------------------------------------------------------------------------------------------------

    function test_cancelledFirstListingIsReproposedByTheNextRoutineRun() public {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](2);
        list[0] = _entry(tokenA, 1_000_000e18);
        list[1] = _entry(tokenB, 1_000_000e18);

        // Launch: the Safe signs safe mode's batch; the guardian vetoes B during the notice.
        _safeSends(configure.safeCalldata(factory, list, none));
        vm.prank(guardian);
        factory.cancelListing(address(tokenB));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        market.setPrice(address(tokenA), 1e8);
        market.setPrice(address(tokenB), 1e8);
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(address(tokenA)));
        assertFalse(factory.isWhitelisted(address(tokenB)), "the veto held at launch");

        // A month later, the runbook's routine reference-supply refresh for A. With WHITELIST=default the list is the
        // hard-coded seven, so the vetoed token is necessarily still in it.
        vm.warp(block.timestamp + 30 days);
        market.setPrice(address(tokenA), 1e8);
        market.setPrice(address(tokenB), 1e8);
        list[0].referenceSupply = 1_020_000e18;
        bytes[] memory calls = configure.safeCalldata(factory, list, none);
        assertEq(calls.length, 2, "the refresh batch carries two proposals");
        assertEq(bytes4(calls[0]), IIndexFactory.proposeConfig.selector);
        assertEq(
            calls[1],
            abi.encodeCall(IIndexFactory.proposeListing, (address(tokenB), configure.configFor(list[1]))),
            "and the vetoed listing is back, unlabelled in safe mode's output"
        );
        _safeSends(calls);

        // If the guardian does not veto it a second time within two days, anyone's execute run whitelists it.
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        market.setPrice(address(tokenA), 1e8);
        market.setPrice(address(tokenB), 1e8);
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(address(tokenB)), "the vetoed token is listed");

        // Contrast XA-11: had the guardian delisted B instead, the same routine run would not list it again without
        // RELIST. Delist B, refresh once more: no proposeListing for B.
        vm.prank(guardian);
        factory.delist(address(tokenB));
        list[0].referenceSupply = 1_030_000e18;
        calls = configure.safeCalldata(factory, list, none);
        assertEq(calls.length, 1, "a delisted token is protected by RELIST; a vetoed first listing is not");
    }

    // -------------------------------------------------------------------------------------------------------------
    // Safe mode and propose mode disagree on a WHITELIST that names a token twice.
    // -------------------------------------------------------------------------------------------------------------

    /// @dev CR-I38 made safe mode pre-check everything the factory would refuse, because one refused proposal takes
    ///      the whole Safe batch down. A token named twice (say, a config tweak appended to a list that already has
    ///      the token) is skipped by propose mode, whose second look sees the first proposal pending, but safe mode
    ///      decides every entry against the same unchanged state and emits both: the batch then always reverts.
    function test_duplicateEntryMakesTheSafeBatchRevertWherePropose_skipsIt() public {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](3);
        list[0] = _entry(tokenA, 1_000_000e18);
        list[1] = _entry(tokenB, 1_000_000e18);
        list[2] = _entry(tokenA, 1_100_000e18); // A again, e.g. an edited copy appended to the list
        bytes[] memory calls = configure.safeCalldata(factory, list, none);
        assertEq(calls.length, 3, "safe mode emits a proposal for both copies of A");

        // The Safe executes the batch atomically (MultiSendCallOnly reverts on the first failure): the third call
        // reverts ListingPending, so B's listing and A's are lost with it.
        vm.startPrank(owner);
        (bool ok0,) = address(factory).call(calls[0]);
        (bool ok1,) = address(factory).call(calls[1]);
        (bool ok2, bytes memory err) = address(factory).call(calls[2]);
        vm.stopPrank();
        assertTrue(ok0 && ok1);
        assertFalse(ok2, "the duplicate fails, and with it the atomic batch");
        assertEq(bytes4(err), IIndexFactory.ListingPending.selector);

        // Propose mode, for a key-held owner, handles the same list: its second look sees A pending and skips it.
        IndexFactory keyOwned = new IndexFactory(DEFAULT_SENDER, guardian);
        configure.propose(keyOwned, list, none);
        assertEq(keyOwned.pendingTokenConfig(address(tokenA)).referenceSupply, 1_000_000e18);
        assertTrue(keyOwned.listingPending(address(tokenB)));
    }
}
