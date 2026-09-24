// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "../XindexTest.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IXindexErrors} from "../../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

/// @notice CR-I01's class, not closed: the index refuses its own shares because "shares it held could never leave",
///         but two more addresses the index knows as immutables -- its FACTORY and its RULE -- can never move a share or
///         a component either. The factory has no ERC-20 function at all, and the rule is a stateless view contract.
///         Shares sent to either, or a redemption or claim naming either as `to`, are burned for good with their
///         backing stranded in the index, exactly the wallet slip CR-I01 was fixed for. The factory is the address a
///         user interacts with to create an index, so it is the likeliest paste after the index's own.
contract CRI01ClassFactoryRuleLockTest is XindexTest {
    IndexToken index;
    MockERC20 wbtc;
    MockERC20 weth;
    MockERC20 link;
    address alice = makeAddr("alice");

    // 0.0001 WBTC + 0.001 WETH + 0.1 LINK per index token (launch decimals: 8, 18, 18)
    uint256 constant U_WBTC = 10_000;
    uint256 constant U_WETH = 1e15;
    uint256 constant U_LINK = 1e17;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, address(0));
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = market.weth();
        link = new MockERC20("ChainLink Token", "LINK", 18);
        _list(address(wbtc));
        _list(address(weth));
        _list(address(link));
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(wbtc), address(weth), address(link));
        uint256[] memory units = new uint256[](3);
        (units[0], units[1], units[2]) = (U_WBTC, U_WETH, U_LINK);
        index = IndexToken(factory.createIndex("Blue Chip", "BLUE", tokens, units, 0));
    }

    function _fundAndIssue(address who, uint256 shares, address to) internal {
        uint256[] memory need = index.previewIssue(shares);
        wbtc.mint(who, need[0]);
        weth.mint(who, need[1]);
        link.mint(who, need[2]);
        vm.startPrank(who);
        wbtc.approve(address(index), need[0]);
        weth.approve(address(index), need[1]);
        link.approve(address(index), need[2]);
        index.issue(shares, to);
        vm.stopPrank();
    }

    function test_sharesSentToTheFactoryOrTheRuleAreLockedForGood() public {
        address rule = factory.RULE();
        _fundAndIssue(alice, 10e18, alice);

        // CR-I01's fix is in place: the index itself is refused.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        index.transfer(address(index), 1e18);

        // The same slip to the factory or to the rule goes through.
        vm.startPrank(alice);
        index.transfer(address(factory), 3e18);
        index.transfer(rule, 2e18);
        vm.stopPrank();
        assertEq(index.balanceOf(address(factory)), 3e18, "the factory now holds shares");
        assertEq(index.balanceOf(rule), 2e18, "and so does the rule");

        // `issue` and `redeem` accept them as `to` as well: _checkRecipient refuses only zero and the index.
        _fundAndIssue(alice, 1e18, address(factory));
        vm.prank(alice);
        index.redeem(1e18, rule);
        assertEq(wbtc.balanceOf(rule), U_WBTC, "a redemption paid its WBTC to the rule");

        // Neither contract can ever move them: the factory exposes no ERC-20 function and the rule is view-only, so
        // there is no call that transfers, approves or redeems. Their backing sits in the index for good.
        (bool ok,) = address(factory).call(abi.encodeWithSignature("transfer(address,uint256)", alice, 1));
        assertFalse(ok, "the factory has no way to send shares");
        uint256 lockedShares = index.balanceOf(address(factory)) + index.balanceOf(rule);
        assertEq(lockedShares, 6e18, "six index tokens are locked");
        // Their backing: 6 x (0.0001 WBTC + 0.001 WETH + 0.1 LINK), unredeemable forever.
        assertGe(wbtc.balanceOf(address(index)), lockedShares * U_WBTC / 1e18, "stranded WBTC backing");
    }
}
