// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "../XindexTest.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket, usdWad} from "../mocks/MockMarket.sol";

/// @notice Test gap in the RT-01 fix. `test_RT01_aListedTokenIsPricedWithTheDecimalsRecordedAtListing` asserts
///         "a proposal records nothing", but it proposes the refresh while the token still reports the decimals already
///         on record (6) and changes them to 18 only afterwards, so a factory that ALSO recorded the token's decimals in
///         `_propose` passes it unchanged. The mutation
///             `_propose`: + `tokenDecimals[token] = IERC20Metadata(token).decimals();`
///         survives all 445 offline tests. That regression is not cosmetic: it would let the owner reprice any
///         component for every index at once, with no LISTING_DELAY and no guardian veto, by proposing a config and
///         cancelling it, which is the timelock RT-01's record was meant to sit behind.
///
///         The test below is the assertion the suite is missing: change the decimals first, then propose, then check
///         that neither the record nor the price moved. It passes on the tree under review and fails under the mutant.
contract RT01ProposalRecordGapTest is XindexTest {
    address guardian = makeAddr("guardian");

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
    }

    function test_RT01gap_aProposalMustNotMoveTheRecordEvenWhenTheDecimalsChanged() public {
        IIndexRule rule = IIndexRule(factory.RULE());
        MockERC20 token = new MockERC20("Nine", "NINE", 9);
        IIndexFactory.TokenConfig memory config = market.configWith(address(token), 200e8, 587_507_739e9);
        vm.prank(owner);
        factory.proposeListing(address(token), config);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(token));
        assertEq(factory.tokenDecimals(address(token)), 9);

        // The token's decimals change BEFORE the proposal, which is the case the existing assertion never reaches.
        token.setDecimals(18);
        IIndexFactory.TokenConfig memory refresh = market.configWith(address(token), 200e8, 587_507_739e9);
        vm.prank(owner);
        factory.proposeConfig(address(token), refresh);
        assertEq(factory.tokenDecimals(address(token)), 9, "a proposal alone must not move the record");
        assertEq(rule.price(address(token)), usdWad(200e8, 9), "nor the price every index is valued at");

        // And a cancelled proposal leaves nothing behind.
        vm.prank(guardian);
        factory.cancelListing(address(token));
        assertEq(factory.tokenDecimals(address(token)), 9, "a cancelled proposal changed nothing");
    }
}
