// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice Five 18-decimal components at a dollar each, 100 units apiece, where the reference supplies want the first at
///         60%: the same shape IndexToken.rebalance.t.sol uses, so a stranger's start at the interval always clears
///         MIN_TURNOVER. Everything goes through the real listing flow.
abstract contract GapBase is Test {
    MockMarket market;
    IndexFactory factory;
    IndexToken index;
    MockRebalanceExecutor executor;
    address[] tokens;
    uint256[] startUnits;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    function setUp() public virtual {
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        executor = new MockRebalanceExecutor();
        uint256[5] memory parts = [uint256(6), 1, 1, 1, 1];
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](5);
        for (uint256 i = 0; i < 5; ++i) {
            tokens.push(address(new MockERC20("C", "C", 18)));
            configs[i] = market.configWith(tokens[i], 1e8, parts[i] * 1e24);
            startUnits.push(100e18);
        }
        vm.startPrank(owner);
        for (uint256 i = 0; i < 5; ++i) {
            factory.proposeListing(tokens[i], configs[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < 5; ++i) {
            factory.executeListing(tokens[i]);
        }
        index = IndexToken(factory.createIndex("Gap", "GAP", tokens, startUnits, 0));
        _issue(alice, 10e18);
    }

    function _issue(address who, uint256 shares) internal {
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(who, need[i]);
            vm.prank(who);
            MockERC20(tokens[i]).approve(address(index), need[i]);
        }
        vm.prank(who);
        index.issue(shares, who);
    }

    /// @dev Keeps every feed fresh at the current timestamp.
    function _refreshFeeds() internal {
        for (uint256 i = 0; i < tokens.length; ++i) {
            market.setPrice(tokens[i], 1e8);
        }
    }
}
