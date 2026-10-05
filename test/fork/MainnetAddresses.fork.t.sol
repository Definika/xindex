// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";

interface IRouterImmutables {
    function poolManager() external view returns (address);
}

/// @notice Checks the scripts' `MainnetAddresses` against mainnet, as AGENTS.md requires before addresses are
///         committed: tokens by symbol and decimals, the router by the PoolManager it names and both by their runtime
///         code hashes, and every default whitelist entry for a supply of plausibly many whole tokens at the token's
///         own decimals. Nothing in v4 reads a price, so no feed is pinned. Skips when MAINNET_RPC_URL is unset.
contract MainnetAddressesForkTest is Test {
    /// @dev Runtime code hash of Universal Router 2.0.0 at `MainnetAddresses.UNIVERSAL_ROUTER`, read on 2026-09-23. The
    ///      router has no proxy, and its immutables are part of its code, so the hash is the build and its wiring.
    bytes32 constant UNIVERSAL_ROUTER_CODEHASH = 0x6a5f46971b50c6e1b7eef97902311444e479d734e4f80ad88367783cf373fe7f;
    /// @dev Runtime code hash of the V4 PoolManager at `MainnetAddresses.POOL_MANAGER`, read on 2026-09-23.
    bytes32 constant POOL_MANAGER_CODEHASH = 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;
    /// @dev Runtime code hash of Uniswap V3's factory at `MainnetAddresses.UNISWAP_V3_FACTORY`, read on 2026-10-05.
    bytes32 constant UNISWAP_V3_FACTORY_CODEHASH = 0x4d7b8525cd5d14343fa67a732fba5b24cddba11620ca88392f4ec6c52f91fd69;

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
        _assertToken(M.USDT, "USDT", 6);
        _assertToken(M.WBTC, "WBTC", 8);
        _assertToken(M.LINK, "LINK", 18);
        _assertToken(M.UNI, "UNI", 18);
    }

    /// @dev XA-13, CR-I35. The zap reads the pool manager off the router, so the pinned router has to name the pool
    ///      manager the address book does, and both are pinned by their code hashes to the builds the zap was verified
    ///      against: every Universal Router build answers `poolManager()` the same way.
    function testFork_XA13_CRI35_uniswapContractsAgree() public view {
        assertEq(IRouterImmutables(M.UNIVERSAL_ROUTER).poolManager(), M.POOL_MANAGER);
        assertEq(M.UNIVERSAL_ROUTER.codehash, UNIVERSAL_ROUTER_CODEHASH, "the pinned router is the 2.0.0 build");
        assertEq(M.POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH, "and the PoolManager is the one it settles with");
    }

    /// @dev The V3 factory `CheckToken` reads depth from is Uniswap's own, by its code.
    function testFork_theV3FactoryIsUniswaps() public view {
        assertEq(M.UNISWAP_V3_FACTORY.codehash, UNISWAP_V3_FACTORY_CODEHASH);
    }

    function testFork_XA13_deployResolvesTheMainnetMarket() public {
        Deploy deployer = new Deploy();
        assertEq(deployer.resolveRouter(address(0)), M.UNIVERSAL_ROUTER);
        assertEq(deployer.resolveStable("USDC", address(0), M.USDC), M.USDC);
        assertEq(deployer.resolveStable("USDT", address(0), M.USDT), M.USDT);
    }

    /// @dev Every default entry, as the listing script builds it, listed on a fresh factory. Each reference supply is a
    ///      whole number of tokens between a million and a trillion at the token's own on-chain decimals, where a
    ///      decimals slip shows: a first listing has nothing to bound it against (XA-24, CR-I22).
    function testFork_XA13_XA24_CRI22_defaultWhitelistMatchesMainnet() public {
        IndexFactory factory = new IndexFactory(address(this), address(0));
        ConfigureWhitelist configure = new ConfigureWhitelist();
        ConfigureWhitelist.Entry[] memory list = configure.defaultMainnetList();
        assertEq(list.length, 4, "the Stage A list is four components");
        for (uint256 i = 0; i < list.length; ++i) {
            uint256 one = 10 ** uint256(IERC20Metadata(list[i].token).decimals());
            assertEq(list[i].referenceSupply % one, 0, "a whole number of tokens");
            assertGe(list[i].referenceSupply / one, 1e6, "at least a million of them");
            assertLe(list[i].referenceSupply / one, 1e12, "and at most a trillion");
            factory.proposeListing(list[i].token, list[i].referenceSupply);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < list.length; ++i) {
            factory.executeListing(list[i].token);
            assertTrue(factory.isWhitelisted(list[i].token));
            assertEq(factory.referenceSupply(list[i].token), list[i].referenceSupply);
        }
    }
}
