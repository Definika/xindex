// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexHub} from "../../src/IndexHub.sol";
import {MintRequests} from "../../src/MintRequests.sol";
import {IMintRequests} from "../../src/interfaces/IMintRequests.sol";
import {XindexTest} from "../XindexTest.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockPausableToken} from "../mocks/MockPausableToken.sol";

/// @notice Composition checks: every component frozen, a stale request as a free option, and cancel front-running.
contract MintRequestsCompositionPoC is XindexTest {
    MintRequests requests;
    IndexHub index;
    MockERC20 usdc;
    address[] components;

    address alice = makeAddr("alice");
    address minter = makeAddr("minter");

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, makeAddr("guardian"));
        usdc = market.usdc();
        requests = new MintRequests(address(factory), address(usdc), address(new MockERC20("T", "T", 6)));
        for (uint256 i = 0; i < 2; ++i) {
            components.push(address(new MockPausableToken("P", "P", 18)));
            _listWith(components[i], 100e18);
        }
        index = IndexHub(factory.createIndex("Frozen", "FRZ", components, 1e36));
        uint256[] memory need = index.previewIssue(10e18);
        vm.startPrank(minter);
        for (uint256 i = 0; i < 2; ++i) {
            MockPausableToken(components[i]).mint(minter, need[i]);
            MockPausableToken(components[i]).approve(address(index), need[i]);
        }
        index.issue(10e18, minter);
        vm.stopPrank();
    }

    /// With every component paused, shares still move: an open mint request is filled with shares nobody can redeem
    /// today (they redeem only into claims), and the requester's USDC goes to the filler. The loss is bounded by the
    /// requester's own share-denominated limit; nothing in MintRequests adds to it. A redemption request in the same
    /// state is simply not filled and its shares come back on refund.
    function test_poc_allComponentsFrozen() public {
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(requests), 1_000e6);
        uint256 id = requests.requestMint(address(index), address(usdc), 1_000e6, 1e18, block.timestamp + 30 days);
        vm.stopPrank();

        MockPausableToken(components[0]).setPaused(true);
        MockPausableToken(components[1]).setPaused(true);

        // The requester sees the freeze and cancels; a filler watching the mempool lands first.
        vm.startPrank(minter);
        index.approve(address(requests), 1e18);
        requests.fill(id, 1e18);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, id));
        requests.cancel(id);

        assertEq(usdc.balanceOf(minter), 1_000e6);
        assertEq(index.balanceOf(alice), 1e18);
        vm.prank(alice);
        vm.expectRevert("paused");
        index.redeem(1e18, alice);
        vm.prank(alice);
        index.redeemSkipping(1e18, alice, 3); // claims for both, payable once transfers resume
        assertEq(index.claimOf(alice, components[0]), 1e18 * 100e18 / 1e18);
    }
}
