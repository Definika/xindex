// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {XindexTest} from "../XindexTest.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

/// @notice r3 git-history lens, R07 ("wrapped assets carry a reference supply").
///
///         At 85a3443 the rule enforced R07 on-chain for WETH, in `checkConfig`, which the factory runs at proposal and
///         again at execution:
///             if (token == WETH) { ...; if (config.referenceSupply == 0) revert InvalidSupplyConfig(token); ... }
///         and `test_R07_wrappedAssetsCarryAReferenceSupply` opened with
///             vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidSupplyConfig.selector, address(weth)));
///             rule.checkConfig(address(weth), onChain);
///         Commit 640e57a deleted the check and re-pointed that first assertion at `InvalidFeed` for an EMPTY config,
///         a property unrelated to R07; the test kept its R07 id and R07 is not in the v3 retirement ledger, so the
///         ledger's "Unaffected: the mechanism, the fix and the test are untouched" covers it. On-chain nothing now
///         stops WETH (or any wrapper) from being listed, or re-configured, onto its wrapped float.
///
///         Because `_checkSupplyChange` skips the bound whenever either side is zero, the switch from ether's supply to
///         the float is also outside DA-18's order-of-magnitude bound. At 85a3443 that transition was impossible for
///         WETH, because R07's check refused the zero reference supply at proposal and at execution.
contract R07WethSupplyGuardLostPoC is XindexTest {
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    uint8 constant CAPPED = 1;
    /// @dev WETH's mainnet totalSupply at block 26,035,527 (2026-09-23): the wrapped float, ~1.7% of ether's supply.
    uint256 constant WETH_FLOAT = 2_077_005_743_338_270_307_201_773;

    function setUp() public {
        vm.warp(30 days);
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
    }

    /// @dev The exact call the base test expected to revert, with a feed so it gets past `InvalidFeed`.
    function test_poc_theRuleAcceptsWethOnItsWrappedFloat() public {
        MockERC20 weth = market.weth();
        IIndexRule rule = IIndexRule(factory.RULE());
        weth.mint(alice, WETH_FLOAT); // the wrapped float exists, as it does on mainnet
        IIndexFactory.TokenConfig memory onChain = market.configWith(address(weth), 3_000e8, 0);
        rule.checkConfig(address(weth), onChain); // 85a3443: InvalidSupplyConfig(weth)

        vm.prank(owner);
        factory.proposeListing(address(weth), onChain);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(weth)); // 85a3443: InvalidSupplyConfig(weth) again, at execution
        assertTrue(factory.isWhitelisted(address(weth)));

        assertEq(rule.supply(address(weth)), WETH_FLOAT, "WETH is counted at its wrapped float");
    }

    /// @dev The consequence on a live capped index: one owner config change, outside DA-18's bound because the new
    ///      reference supply is zero, halves WETH at the next permissionless rebalance.
    function test_poc_aConfigChangeToTheFloatHalvesWethAtTheNextRebalance() public {
        MockERC20 weth = market.weth();
        weth.mint(alice, WETH_FLOAT);
        address[] memory t = new address[](5);
        t[0] = address(weth);
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](5);
        configs[0] = market.configWith(address(weth), 3_000e8, 122_070_499e18); // ether's supply, as shipped
        for (uint256 i = 1; i < 5; ++i) {
            t[i] = address(new MockERC20("Coin", "COIN", 18));
            configs[i] = market.configWith(t[i], 10e8, 1_500_000_000e18); // $15bn cap each
        }
        vm.startPrank(owner);
        for (uint256 i = 0; i < 5; ++i) {
            factory.proposeListing(t[i], configs[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < 5; ++i) {
            factory.executeListing(t[i]);
        }
        IIndexRule rule = IIndexRule(factory.RULE());
        uint256[] memory units = rule.initialUnits(t, CAPPED, 1_000e18);
        IndexToken idx = IndexToken(factory.createIndex("Majors", "MAJ", t, units, CAPPED));
        (uint256[] memory w,,) = rule.weights(t, CAPPED);
        assertEq(w[0], 0.3e18, "ether's supply puts WETH on its 30% ceiling");

        // The owner switches WETH to on-chain supply. Nothing on-chain refuses it any more, and DA-18 does not apply.
        IIndexFactory.TokenConfig memory toFloat = market.configWith(address(weth), 3_000e8, 0);
        vm.prank(owner);
        factory.proposeConfig(address(weth), toFloat);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(weth));

        (w,,) = rule.weights(t, CAPPED);
        assertLt(w[0], 0.12e18, "WETH's weight collapses from 30% to under 12%");
        emit log_named_decimal_uint("WETH weight after the switch", w[0], 18);

        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        (uint256[] memory targets, uint256 turnover) = idx.previewTarget(0);
        assertEq(targets[0], (units[0] + 1) / 2, "WETH is targeted at its floor: half the index's ether goes");
        assertGt(turnover, 0.1e18, "a >10% turnover, far above MIN_TURNOVER");
        vm.prank(stranger);
        idx.startRebalance(0); // and any address can start it
    }
}
