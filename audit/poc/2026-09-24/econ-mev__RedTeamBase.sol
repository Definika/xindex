// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {Methodology} from "../../src/libraries/Methodology.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice The launch whitelist as mock tokens with the real decimals, the reference supplies of
///         `script/MainnetAddresses.sol`, and the Chainlink answers read from mainnet on 2026-09-24 (block ~26,042,400).
abstract contract RedTeamBase is Test {
    MockMarket market;
    IndexFactory factory;
    IIndexRule rule;
    MockRebalanceExecutor executor;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");

    uint256 constant WAD = 1e18;

    // index positions in the launch list
    uint256 constant I_WETH = 0;
    uint256 constant I_WSTETH = 1;
    uint256 constant I_WBTC = 2;
    uint256 constant I_WSOL = 3;
    uint256 constant I_LINK = 4;
    uint256 constant I_UNI = 5;
    uint256 constant I_AAVE = 6;

    address[] launch;
    int256[] prices8;

    function _setUpLaunch() internal {
        vm.warp(1_790_183_003); // the block clock of the feed reads above
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        rule = IIndexRule(factory.RULE());
        executor = new MockRebalanceExecutor();

        uint8[7] memory decs = [18, 18, 8, 9, 18, 18, 18];
        string[7] memory syms = ["WETH", "wstETH", "WBTC", "SOL", "LINK", "UNI", "AAVE"];
        // MainnetAddresses reference supplies
        uint256[7] memory supplies = [
            uint256(122_070_499e18),
            3_715_183e18,
            20_087_871e8,
            587_507_739e9,
            748_099_970e18,
            620_716_422e18,
            15_428_841e18
        ];
        // Chainlink answers, 8 decimals, read on mainnet 2026-09-24
        int256[7] memory p = [
            int256(267773830000), // ETH/USD   2677.74
            331119242505, // wstETH/USD 3311.19
            8449255074385, // BTC/USD (x WBTC/BTC ~0.9994) 84492.55
            11475467548, // SOL/USD 114.75
            1230198627, // LINK/USD 12.30
            915930739, // UNI/USD 9.16
            13858554349 // AAVE/USD 138.59
        ];
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](7);
        for (uint256 i = 0; i < 7; ++i) {
            launch.push(address(new MockERC20(syms[i], syms[i], decs[i])));
            prices8.push(p[i]);
            configs[i] = market.configWith(launch[i], p[i], supplies[i]);
        }
        vm.startPrank(owner);
        for (uint256 i = 0; i < 7; ++i) {
            factory.proposeListing(launch[i], configs[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < 7; ++i) {
            factory.executeListing(launch[i]);
        }
    }

    function _createOnRule(address creator, address[] memory tokens, uint8 methodology, uint256 startPriceUsd)
        internal
        returns (IndexToken idx)
    {
        uint256[] memory units = rule.initialUnits(tokens, methodology, startPriceUsd);
        vm.prank(creator);
        idx = IndexToken(factory.createIndex("Launch", "L7", tokens, units, methodology));
    }

    function _issue(IndexToken idx, address who, uint256 shares) internal {
        uint256[] memory need = idx.previewIssue(shares);
        address[] memory t = idx.componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            MockERC20(t[i]).mint(who, need[i]);
            vm.prank(who);
            MockERC20(t[i]).approve(address(idx), need[i]);
        }
        vm.prank(who);
        idx.issue(shares, who);
    }

    /// @dev USD-WAD value, at the feeds in force, of a list of raw amounts of `idx`'s components.
    function _value(IndexToken idx, uint256[] memory amounts) internal view returns (uint256 v) {
        address[] memory t = idx.componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            v += Math.mulDiv(amounts[i], rule.price(t[i]), WAD);
        }
    }

    /// @dev USD-WAD value, at the feeds in force, of `who`'s holdings of `idx`'s components.
    function _walletValue(IndexToken idx, address who) internal view returns (uint256 v) {
        address[] memory t = idx.componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            v += Math.mulDiv(MockERC20(t[i]).balanceOf(who), rule.price(t[i]), WAD);
        }
    }

    function _move(address token, int256 num, int256 den) internal {
        market.movePrice(token, uint256(num), uint256(den));
    }
}
