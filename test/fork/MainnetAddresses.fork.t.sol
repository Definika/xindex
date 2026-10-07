// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {ConfigureWeighted} from "../../script/ConfigureWeighted.s.sol";
import {DeployWeighted} from "../../script/DeployWeighted.s.sol";
import {DeployChecks} from "../../script/DeployChecks.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";

interface IRouterImmutables {
    function poolManager() external view returns (address);
}

/// @dev What the fork test asks Pyth: its Wormhole chain id, and the parse `WeightedHub` calls, with the feeds it
///      returns read as raw words, since only their count matters here.
interface IPythProbe {
    function chainId() external view returns (uint16);

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (bytes32[] memory);
}

/// @notice Checks the scripts' `MainnetAddresses` against mainnet, as AGENTS.md requires before addresses are
///         committed: tokens by symbol and decimals, the router by the PoolManager it names and both by their runtime
///         code hashes, every entry of v5's lists listed on a fresh factory with its price id and its token's own
///         decimals, and Pyth's proxy, v5's one price source. Skips when MAINNET_RPC_URL is unset.
contract MainnetAddressesForkTest is Test {
    /// @dev Runtime code hash of Universal Router 2.0.0 at `MainnetAddresses.UNIVERSAL_ROUTER`, read on 2026-09-23. The
    ///      router has no proxy, and its immutables are part of its code, so the hash is the build and its wiring.
    bytes32 constant UNIVERSAL_ROUTER_CODEHASH = 0x6a5f46971b50c6e1b7eef97902311444e479d734e4f80ad88367783cf373fe7f;
    /// @dev Runtime code hash of the V4 PoolManager at `MainnetAddresses.POOL_MANAGER`, read on 2026-09-23.
    bytes32 constant POOL_MANAGER_CODEHASH = 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;
    /// @dev Runtime code hash of Uniswap V3's factory at `MainnetAddresses.UNISWAP_V3_FACTORY`, read on 2026-10-05.
    bytes32 constant UNISWAP_V3_FACTORY_CODEHASH = 0x4d7b8525cd5d14343fa67a732fba5b24cddba11620ca88392f4ec6c52f91fd69;
    /// @dev Runtime code hash of Pyth's ERC-1967 proxy at `MainnetAddresses.PYTH`, read on 2026-10-05. Pyth's DAO
    ///      upgrades the implementation behind it, so only the proxy is pinned.
    /// @dev Runtime code hash of PancakeSwap's v3 Universal Router at `MainnetAddresses.PANCAKE_UNIVERSAL_ROUTER`, read on
    ///      2026-10-06. Its immutables (PancakeSwap's V3 deployer and pool init code hash, its Permit2 and WETH) are
    ///      part of the code, so this pins the pools a PancakeSwap leg can reach too.
    bytes32 constant PANCAKE_ROUTER_CODEHASH = 0xdb8dfdb9e10400c36fae415f58c5d4a6a573b28e2bd1e25a6328623a2112d3f6;
    bytes32 constant PYTH_PROXY_CODEHASH = 0x330b9f1afee9d71fb2ee42927a996a39889a45323883a66a194e210ab850d111;

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

    /// @dev The wide list's tokens, by the symbol and decimals each answers on chain, written out here rather than read
    ///      from the list. RNDR is Render and Cake is PancakeSwap's.
    function testFork_wideTokensAreWhatTheirNamesSay() public view {
        _assertToken(M.QNT, "QNT", 18);
        _assertToken(M.AAVE, "AAVE", 18);
        _assertToken(M.ENA, "ENA", 18);
        _assertToken(M.ONDO, "ONDO", 18);
        _assertToken(M.SKY, "SKY", 18);
        _assertToken(M.WLD, "WLD", 18);
        _assertToken(M.MNT, "MNT", 18);
        _assertToken(M.MORPHO, "MORPHO", 18);
        _assertToken(M.POL, "POL", 18);
        _assertToken(M.LIT, "LIT", 18);
        _assertToken(M.ETHFI, "ETHFI", 18);
        _assertToken(M.FET, "FET", 18);
        _assertToken(M.CRV, "CRV", 18);
        _assertToken(M.NEXO, "NEXO", 18);
        _assertToken(M.VIRTUAL, "VIRTUAL", 18);
        _assertToken(M.STRK, "STRK", 18);
        _assertToken(M.PENDLE, "PENDLE", 18);
        _assertToken(M.CRO, "CRO", 8);
        _assertToken(M.ICP, "ICP", 8);
        _assertToken(M.ARB, "ARB", 18);
        _assertToken(M.RENDER, "RNDR", 18);
        _assertToken(M.CAKE, "Cake", 18);
        _assertToken(M.ZRO, "ZRO", 18);
    }

    /// @dev Every entry, as the listing script builds it, listed on a fresh v5 factory over Pyth's own contract, which
    ///      records each token's on-chain decimals and the price id the entry names.
    function _listOnAFreshFactory(ConfigureWeighted.Entry[] memory list) internal {
        WeightedIndexFactory factory = new WeightedIndexFactory(address(this), address(0), M.PYTH);
        for (uint256 i = 0; i < list.length; ++i) {
            factory.proposeListing(list[i].token, list[i].priceId);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < list.length; ++i) {
            factory.executeListing(list[i].token);
            assertTrue(factory.isWhitelisted(list[i].token));
            assertEq(factory.priceIdOf(list[i].token), list[i].priceId);
            assertEq(factory.decimalsOf(list[i].token), IERC20Metadata(list[i].token).decimals());
        }
    }

    /// @dev Every wide entry lists on a fresh factory with its price id and its token's own decimals.
    function testFork_wideWhitelistMatchesMainnet() public {
        ConfigureWeighted.Entry[] memory list = new ConfigureWeighted().wideMainnetList();
        assertEq(list.length, 23);
        _listOnAFreshFactory(list);
    }

    /// @dev XA-13, CR-I35. The zap reads the pool manager off the router, so the pinned router has to name the pool
    ///      manager the address book does, and both are pinned by their code hashes to the builds the zap was verified
    ///      against: every Universal Router build answers `poolManager()` the same way.
    function testFork_XA13_CRI35_uniswapContractsAgree() public view {
        assertEq(IRouterImmutables(M.UNIVERSAL_ROUTER).poolManager(), M.POOL_MANAGER);
        assertEq(M.UNIVERSAL_ROUTER.codehash, UNIVERSAL_ROUTER_CODEHASH, "the pinned router is the 2.0.0 build");
        assertEq(M.POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH, "and the PoolManager is the one it settles with");
    }

    /// @dev v5's one price source is Pyth's own proxy on Ethereum, Wormhole chain 2, and it answers the parse
    ///      `WeightedHub` calls: with no ids it returns no feeds, and for a feed with no update it refuses.
    function testFork_pythIsPyths() public {
        assertEq(M.PYTH.codehash, PYTH_PROXY_CODEHASH);
        assertEq(IPythProbe(M.PYTH).chainId(), 2);
        assertEq(IPythProbe(M.PYTH).parsePriceFeedUpdatesUnique(new bytes[](0), new bytes32[](0), 0, 0).length, 0);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
        vm.expectRevert();
        IPythProbe(M.PYTH).parsePriceFeedUpdatesUnique(new bytes[](0), ids, 0, 0);
    }

    /// @dev The zap's PancakeSwap legs run through PancakeSwap's own v3 Universal Router, by its code; the zap's fork
    ///      suite runs real legs through it and checks SV-1 there.
    function testFork_thePancakeRouterIsPancakes() public view {
        assertEq(M.PANCAKE_UNIVERSAL_ROUTER.codehash, PANCAKE_ROUTER_CODEHASH);
    }

    /// @dev The V3 factory `CheckToken` reads depth from is Uniswap's own, by its code.
    function testFork_theV3FactoryIsUniswaps() public view {
        assertEq(M.UNISWAP_V3_FACTORY.codehash, UNISWAP_V3_FACTORY_CODEHASH);
    }

    function testFork_XA13_deployResolvesTheMainnetMarket() public {
        DeployWeighted deployer = new DeployWeighted();
        assertEq(deployer.resolveRouter(address(0)), M.UNIVERSAL_ROUTER);
        assertEq(deployer.resolvePancakeRouter(address(0)), M.PANCAKE_UNIVERSAL_ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "PANCAKE_ROUTER", M.UNIVERSAL_ROUTER)
        );
        deployer.resolvePancakeRouter(M.UNIVERSAL_ROUTER);
        assertEq(deployer.resolveStable("USDC", address(0), M.USDC), M.USDC);
        assertEq(deployer.resolveStable("USDT", address(0), M.USDT), M.USDT);
    }

    /// @dev Every default entry, the four checked above by address, lists on a fresh v5 factory with its price id.
    function testFork_XA13_theDefaultListMatchesMainnet() public {
        ConfigureWeighted.Entry[] memory list = new ConfigureWeighted().defaultMainnetList();
        address[4] memory four = [M.WETH, M.WBTC, M.LINK, M.UNI];
        assertEq(list.length, four.length);
        for (uint256 i = 0; i < four.length; ++i) {
            assertEq(list[i].token, four[i]);
        }
        _listOnAFreshFactory(list);
    }
}
