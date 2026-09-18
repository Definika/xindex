// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {IUniswapV3Factory} from "../../src/interfaces/IUniswapV3Factory.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";

interface IRouterImmutables {
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

interface IPoolCardinality {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// @notice Checks the scripts' `MainnetAddresses` against mainnet, as AGENTS.md requires before addresses are
///         committed: tokens by symbol and decimals, the router's own factory and WETH, pools with the Uniswap V3
///         factory's `getPool`, and every default whitelist entry against the rule. Skips when MAINNET_RPC_URL is
///         unset.
contract MainnetAddressesForkTest is Test {
    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        // FORK_BLOCK overrides the pin, for a non-archive RPC that only serves recent state. Forge loads .env
        // automatically, so a MAINNET_RPC_URL set there makes a plain `forge test` run these suites too.
        uint256 forkBlock = vm.envOr("FORK_BLOCK", A.FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "MAINNET_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/fork/*'"
                )
            );
        }
    }

    function _assertToken(address token, string memory symbol, uint8 decimals) internal view {
        assertEq(IERC20Metadata(token).symbol(), symbol);
        assertEq(IERC20Metadata(token).decimals(), decimals);
    }

    function testFork_XA13_tokensAreWhatTheirNamesSay() public view {
        _assertToken(M.WETH, "WETH", 18);
        _assertToken(M.USDC, "USDC", 6);
        _assertToken(M.WBTC, "WBTC", 8);
        _assertToken(M.LINK, "LINK", 18);
        _assertToken(M.UNI, "UNI", 18);
        _assertToken(M.AAVE, "AAVE", 18);
        _assertToken(M.ONDO, "ONDO", 18);
        _assertToken(M.ENA, "ENA", 18);
        _assertToken(M.MORPHO, "MORPHO", 18);
        _assertToken(M.ETHFI, "ETHFI", 18);
        _assertToken(M.CRV, "CRV", 18);
        _assertToken(M.PENDLE, "PENDLE", 18);
        _assertToken(M.OHM, "OHM", 9);
        _assertToken(M.LDO, "LDO", 18);
        _assertToken(M.SYRUP, "SYRUP", 18);
        _assertToken(M.TBTC, "tBTC", 18);
    }

    function testFork_XA13_uniswapContractsAgree() public view {
        assertEq(IRouterImmutables(M.SWAP_ROUTER_02).factory(), M.UNISWAP_V3_FACTORY);
        assertEq(IRouterImmutables(M.SWAP_ROUTER_02).WETH9(), M.WETH);
        IUniswapV3Factory v3 = IUniswapV3Factory(M.UNISWAP_V3_FACTORY);
        assertEq(v3.getPool(M.USDC, M.WETH, 500), A.USDC_WETH_500);
        assertEq(v3.getPool(M.WBTC, M.WETH, 500), A.WBTC_WETH_500);
        assertEq(v3.getPool(M.LINK, M.WETH, 3000), A.LINK_WETH_3000);
        assertEq(v3.getPool(M.UNI, M.WETH, 3000), A.UNI_WETH_3000);
        assertEq(v3.getPool(M.AAVE, M.WETH, 3000), A.AAVE_WETH_3000);
        assertEq(v3.getPool(M.ONDO, M.WETH, 3000), A.ONDO_WETH_3000);
        assertEq(v3.getPool(M.ENA, M.WETH, 3000), A.ENA_WETH_3000);
        assertEq(v3.getPool(M.MORPHO, M.WETH, 3000), A.MORPHO_WETH_3000);
        assertEq(v3.getPool(M.ETHFI, M.WETH, 3000), A.ETHFI_WETH_3000);
        assertEq(v3.getPool(M.CRV, M.WETH, 3000), A.CRV_WETH_3000);
        assertEq(v3.getPool(M.PENDLE, M.WETH, 3000), A.PENDLE_WETH_3000);
        assertEq(v3.getPool(M.OHM, M.WETH, 3000), A.OHM_WETH_3000);
        assertEq(v3.getPool(M.LDO, M.WETH, 3000), A.LDO_WETH_3000);
        assertEq(v3.getPool(M.SYRUP, M.WETH, 10000), A.SYRUP_WETH_10000);
        assertEq(v3.getPool(M.TBTC, M.WETH, 3000), A.TBTC_WETH_3000);
    }

    function testFork_XA13_deployResolvesTheMainnetMarket() public {
        Deploy deployer = new Deploy();
        Deploy.Market memory market =
            deployer.resolveMarket(Deploy.Market(address(0), address(0), address(0), address(0)));
        assertEq(market.router, M.SWAP_ROUTER_02);
        assertEq(market.weth, M.WETH);
        assertEq(market.uniswapV3Factory, M.UNISWAP_V3_FACTORY);
        assertEq(market.usdc, M.USDC);
    }

    function testFork_XA13_XA24_defaultWhitelistMatchesMainnet() public {
        IndexFactory factory = new IndexFactory(address(this), address(0), M.WETH, M.UNISWAP_V3_FACTORY, M.USDC);
        IIndexRule rule = IIndexRule(factory.RULE());
        assertEq(rule.USD_POOL(), A.USDC_WETH_500);
        ConfigureWhitelist configure = new ConfigureWhitelist();
        ConfigureWhitelist.Entry[] memory list = configure.defaultMainnetList();
        address[15] memory pools = [
            A.WBTC_WETH_500,
            address(0),
            A.LINK_WETH_3000,
            A.UNI_WETH_3000,
            A.TBTC_WETH_3000,
            A.AAVE_WETH_3000,
            A.ONDO_WETH_3000,
            A.ENA_WETH_3000,
            A.MORPHO_WETH_3000,
            A.ETHFI_WETH_3000,
            A.CRV_WETH_3000,
            A.PENDLE_WETH_3000,
            A.OHM_WETH_3000,
            A.LDO_WETH_3000,
            A.SYRUP_WETH_10000
        ];

        for (uint256 i = 0; i < list.length; ++i) {
            IIndexFactory.TokenConfig memory config = configure.configFor(list[i], M.WETH, M.UNISWAP_V3_FACTORY);
            assertEq(config.pool, pools[i], "the fee tier names the verified pool");
            assertEq(
                config.minLiquidity == 0, config.pool == address(0), "a minimum liquidity exactly for pooled tokens"
            );
            if (config.referenceSupply != 0) {
                // A decimals slip would put a supply off by 1e8 to 1e18; every listed asset has 1e6 to 1e12 whole tokens.
                uint256 wholeTokens = config.referenceSupply / 10 ** IERC20Metadata(list[i].token).decimals();
                assertGe(wholeTokens, 1e6);
                assertLe(wholeTokens, 1e12);
            }
            if (config.pool == address(0)) {
                rule.checkConfig(list[i].token, config);
                continue;
            }
            (,,, uint16 cardinality,,,) = IPoolCardinality(config.pool).slot0();
            if (cardinality >= rule.MIN_OBSERVATION_CARDINALITY()) {
                rule.checkConfig(list[i].token, config);
                continue;
            }
            // tBTC/WETH 0.3% kept 60 slots on 2026-09-16 and cannot be listed until someone grows its ring.
            vm.expectRevert(abi.encodeWithSelector(IIndexRule.PoolHistoryTooShort.selector, config.pool, cardinality));
            rule.checkConfig(list[i].token, config);
            _checkBehindTheSlotCount(rule, list[i].token, config);
        }
    }

    /// @dev LR-08: the slot count is the first thing `checkConfig` rejects, so for a pool with too few slots the
    ///      entry's minimum liquidity and supply were never checked against the chain, and most default pools have too
    ///      few. With the slot count answered as the minimum, the rest of the check runs on the pool's real window. A
    ///      thin pool that traded within the last 30 minutes cannot serve that window yet and answers `OLD`, which
    ///      says nothing about the entry; any other rejection fails the test.
    function _checkBehindTheSlotCount(IIndexRule rule, address token, IIndexFactory.TokenConfig memory config)
        internal
    {
        (uint160 sqrtPriceX96, int24 tick, uint16 index,, uint16 next, uint8 feeProtocol, bool unlocked) =
            IPoolCardinality(config.pool).slot0();
        vm.mockCall(
            config.pool,
            abi.encodeWithSelector(IPoolCardinality.slot0.selector),
            abi.encode(sqrtPriceX96, tick, index, rule.MIN_OBSERVATION_CARDINALITY(), next, feeProtocol, unlocked)
        );
        try rule.checkConfig(token, config) {}
        catch Error(string memory reason) {
            assertEq(reason, "OLD", "the pool rejected the window for another reason than its age");
        }
        vm.clearMockedCalls();
    }
}
