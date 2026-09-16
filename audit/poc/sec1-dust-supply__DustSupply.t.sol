// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockPausableToken} from "../mocks/MockPausableToken.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice Rebalance lifecycle of an index: snapshot, notice, auction, settlement, cancellation.
/// @dev The basket holds five tokens worth one WETH each, 100 units apiece, while the rule wants the first at 60% and
///      the others at 10%. The first target is clipped at 200 units and the others land at 75, for 20% turnover. The
///      second component can be paused.
contract DustSupplyPoC is Test {
    MockMarket market;
    IndexFactory factory;
    IndexToken index;
    MockRebalanceExecutor executor;
    MockPausableToken pausable;
    address[] tokens;
    uint256[] startUnits;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    uint256 constant WAD = 1e18;
    uint256 constant SHARES = 10e18;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(
            owner, guardian, address(market.weth()), address(market.uniswapV3Factory()), address(market.usdc())
        );
        executor = new MockRebalanceExecutor();

        pausable = new MockPausableToken("Pausable", "PAUSE", 18);
        uint256[5] memory parts = [uint256(6), 1, 1, 1, 1];
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](5);
        for (uint256 i = 0; i < 5; ++i) {
            tokens.push(i == 1 ? address(pausable) : address(new MockERC20("C", "C", 18)));
            configs[i] = market.configWith(tokens[i], 0, parts[i] * 1e24, new address[](0));
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

        index = IndexToken(factory.createIndex("Rebalanced", "RBL", tokens, startUnits, 0));
        _issue(index, alice, SHARES);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _issue(IndexToken idx, address who, uint256 shares) internal {
        uint256[] memory need = idx.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(who, need[i]);
            vm.prank(who);
            MockERC20(tokens[i]).approve(address(idx), need[i]);
        }
        vm.prank(who);
        idx.issue(shares, who);
    }

    function _expectedTargets() internal pure returns (uint256[] memory t) {
        t = new uint256[](5);
        (t[0], t[1], t[2], t[3], t[4]) = (200e18, 75e18, 75e18, 75e18, 75e18);
    }

    /// @dev Warps to the first moment a rebalance may start and starts one as a stranger.
    function _start(IndexToken idx) internal returns (uint256 eta) {
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        idx.startRebalance(0);
        (eta,,) = idx.pendingRebalance();
    }

    function _units(IndexToken idx) internal view returns (uint256[] memory units) {
        (, units) = idx.components();
    }

    function _assertBacked(IndexToken idx) internal view {
        (address[] memory t, uint256[] memory u) = idx.components();
        uint256 supply = idx.totalSupply();
        for (uint256 i = 0; i < t.length; ++i) {
            uint256 required = supply * u[i] / WAD + idx.totalClaims(t[i]);
            assertGe(MockERC20(t[i]).balanceOf(address(idx)), required, "component under-backed");
        }
    }


    function test_poc_dustSupplyLetsExecutorPickMultiplier() public {
        IndexToken dust = IndexToken(factory.createIndex("Dust", "DUST", tokens, startUnits, 0));
        _issue(dust, stranger, 1); // 1 wei share: every issue amount rounds up to 1 raw unit
        uint256 eta = _start(dust);
        vm.warp(eta); // multiplier 1.5, nothing moves because floor(1 * units / 1e18) == 0
        assertEq(dust.currentMultiplier(), 1.5e18);
        executor.execute(dust, "");
        uint256[] memory u = _units(dust);
        emit log_named_uint("units[0] after", u[0]);
        emit log_named_uint("units[1] after", u[1]);
        // rule target was 200e18/75e18 (value-conserving); parity would give that exactly
        assertEq(u[0], 250e18);
        assertEq(u[1], 75e18);
        // basket value per token: before 500, rule target 500, after 550 (+10%)
        uint256 v; for (uint256 i = 0; i < 5; ++i) v += u[i];
        emit log_named_uint("sum units after (same price per unit)", v);
    }
}
