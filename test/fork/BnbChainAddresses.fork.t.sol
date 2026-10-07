// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {MintRequests} from "../../src/MintRequests.sol";
import {CheckToken} from "../../script/CheckToken.s.sol";
import {ConfigureWeighted} from "../../script/ConfigureWeighted.s.sol";
import {DeployWeighted} from "../../script/DeployWeighted.s.sol";
import {DeployChecks} from "../../script/DeployChecks.sol";
import {BnbChainAddresses as B} from "../../script/BnbChainAddresses.sol";

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

/// @notice Checks the scripts' `BnbChainAddresses` against BNB Chain, as `MainnetAddresses.fork.t.sol` checks
///         Ethereum's: tokens by symbol and decimals, the routers, the PoolManager, Uniswap's V3 factory and Pyth's
///         proxy by their runtime code hashes, the BNB Chain list listed on a fresh factory over BNB Chain's Pyth, the
///         three tokens the 2026-10-05 admission run did not cover through `CheckToken`, and a whole deployment from
///         the address book alone. Skips when BNB_RPC_URL is unset.
contract BnbChainAddressesForkTest is Test {
    /// @dev Runtime code hashes read on BNB Chain on 2026-10-07 at block 126,305,003. The routers have no proxy and their
    ///      immutables are part of their code, so each hash is the build and its wiring; both builds are Ethereum's
    ///      but for those immutables.
    bytes32 constant UNIVERSAL_ROUTER_CODEHASH = 0x4899c516cf2f0b82251ab88630a9b326d1a2668855c553f9f5a0ea2de993e63b;
    bytes32 constant POOL_MANAGER_CODEHASH = 0x48752321ee7abf0d2a17c30679df9a1ddd14dc75d28b26e2509b76396145a005;
    bytes32 constant PANCAKE_ROUTER_CODEHASH = 0xc5af5d1a2b8539337cdb6e3992026ccb3ba8e70f81b56ab471d13c1a268fd724;
    bytes32 constant UNISWAP_V3_FACTORY_CODEHASH = 0x34b1009d0f004e58da791225992645e2df7697ac71ac89dc5e80469c4ef7e322;
    /// @dev Pyth's ERC-1967 proxy, the same code as Ethereum's; Pyth's DAO upgrades the implementation behind it.
    bytes32 constant PYTH_PROXY_CODEHASH = 0x330b9f1afee9d71fb2ee42927a996a39889a45323883a66a194e210ab850d111;
    /// @dev Block the fork pins to; BNB_FORK_BLOCK overrides it for a non-archive RPC that only serves recent state.
    uint256 constant FORK_BLOCK = 126_305_003;

    function setUp() public {
        string memory url = vm.envOr("BNB_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BNB_FORK_BLOCK", FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "BNB_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set BNB_FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/fork/*'"
                )
            );
        }
        assertEq(block.chainid, B.CHAIN_ID, "BNB_RPC_URL is a BNB Chain node");
    }

    function _assertToken(address token, string memory symbol, uint8 decimals) internal view {
        assertEq(IERC20Metadata(token).symbol(), symbol);
        assertEq(IERC20Metadata(token).decimals(), decimals);
    }

    /// @dev Every token of the address book, by the symbol and decimals each answers on chain, written out here rather
    ///      than read from the list.
    function testFork_tokensAreWhatTheirNamesSay() public view {
        _assertToken(B.WBNB, "WBNB", 18);
        _assertToken(B.BTCB, "BTCB", 18);
        _assertToken(B.ETH, "ETH", 18);
        _assertToken(B.XRP, "XRP", 18);
        _assertToken(B.SOL, "SOL", 18);
        _assertToken(B.ZEC, "ZEC", 18);
        _assertToken(B.DOGE, "DOGE", 8);
        _assertToken(B.ADA, "ADA", 18);
        _assertToken(B.BCH, "BCH", 18);
        _assertToken(B.LTC, "LTC", 18);
        _assertToken(B.AVAX, "AVAX", 18);
        _assertToken(B.DOT, "DOT", 18);
        _assertToken(B.FIL, "FIL", 18);
        _assertToken(B.ATOM, "ATOM", 18);
        _assertToken(B.ASTER, "ASTER", 18);
        _assertToken(B.STABLE, "STABLE", 18);
        _assertToken(B.TRX, "TRX", 6);
        _assertToken(B.USDT, "USDT", 18);
        _assertToken(B.USDC, "USDC", 18);
    }

    /// @dev CR-I35 on BNB Chain: the router names the PoolManager the address book does, and the routers, the
    ///      PoolManager and the V3 factory are pinned by their code to the builds the zap was verified against.
    function testFork_CRI35_theRoutersArePinnedBuilds() public view {
        assertEq(IRouterImmutables(B.UNIVERSAL_ROUTER).poolManager(), B.POOL_MANAGER);
        assertEq(B.UNIVERSAL_ROUTER.codehash, UNIVERSAL_ROUTER_CODEHASH, "Uniswap's router is the 2.0.0 build");
        assertEq(B.POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH, "and the PoolManager is the one it settles with");
        assertEq(B.PANCAKE_UNIVERSAL_ROUTER.codehash, PANCAKE_ROUTER_CODEHASH, "PancakeSwap's router is its v3 build");
        assertEq(B.UNISWAP_V3_FACTORY.codehash, UNISWAP_V3_FACTORY_CODEHASH, "the V3 factory is Uniswap's");
    }

    /// @dev The one price source on BNB Chain is Pyth's own proxy, Wormhole chain 4, and it answers the parse
    ///      `WeightedHub` calls: with no ids it returns no feeds, and for a feed with no update it refuses.
    function testFork_pythIsPyths() public {
        assertEq(B.PYTH.codehash, PYTH_PROXY_CODEHASH);
        assertEq(IPythProbe(B.PYTH).chainId(), 4);
        assertEq(IPythProbe(B.PYTH).parsePriceFeedUpdatesUnique(new bytes[](0), new bytes32[](0), 0, 0).length, 0);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = B.BTCB_PRICE_ID;
        vm.expectRevert();
        IPythProbe(B.PYTH).parsePriceFeedUpdatesUnique(new bytes[](0), ids, 0, 0);
    }

    /// @dev On chain 56 the deploy script resolves every market address from the address book and refuses any other.
    function testFork_deployResolvesTheBnbChainMarket() public {
        DeployWeighted deployer = new DeployWeighted();
        assertEq(deployer.resolveRouter(address(0)), B.UNIVERSAL_ROUTER);
        assertEq(deployer.resolvePancakeRouter(address(0)), B.PANCAKE_UNIVERSAL_ROUTER);
        assertEq(deployer.resolvePyth(address(0)), B.PYTH);
        assertEq(deployer.resolveStable("USDC", address(0), deployer.pinnedUsdc()), B.USDC);
        assertEq(deployer.resolveStable("USDT", address(0), deployer.pinnedUsdt()), B.USDT);
        vm.expectRevert(
            abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "PANCAKE_ROUTER", B.UNIVERSAL_ROUTER)
        );
        deployer.resolvePancakeRouter(B.UNIVERSAL_ROUTER);
    }

    /// @dev A whole deployment on BNB Chain from the book alone: a contract owner (this test, which answers no Safe
    ///      threshold), a guardian, and zero for every market address.
    function testFork_aDeploymentFromTheAddressBook() public {
        DeployWeighted deployer = new DeployWeighted();
        (WeightedIndexFactory factory, IndexZap zap, MintRequests requests) = deployer.deploy(
            address(this), makeAddr("guardian"), address(0), address(0), address(0), address(0), address(0)
        );
        assertEq(factory.PYTH(), B.PYTH);
        assertEq(address(zap.ROUTER()), B.UNIVERSAL_ROUTER);
        assertEq(zap.POOL_MANAGER(), B.POOL_MANAGER);
        assertEq(address(zap.PANCAKE_ROUTER()), B.PANCAKE_UNIVERSAL_ROUTER);
        assertEq(requests.USDC(), B.USDC);
        assertEq(requests.USDT(), B.USDT);
        deployer.checkDeployment(factory, zap, requests);
    }

    /// @dev Every entry of the BNB Chain list, as the listing script builds it, listed on a fresh factory over BNB
    ///      Chain's Pyth, which records each token's on-chain decimals and the price id the entry names.
    function testFork_theBnbListMatchesTheChain() public {
        ConfigureWeighted.Entry[] memory list = new ConfigureWeighted().resolveList("bnb");
        assertEq(list.length, B.COUNT);
        WeightedIndexFactory factory = new WeightedIndexFactory(address(this), address(0), B.PYTH);
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

    /// @dev The three tokens the admission run of 2026-10-05 did not cover: WBNB, BTCB and Binance-Peg ETH each pass
    ///      `CheckToken`, with their powers recorded for the signers.
    function testFork_wbnbBtcbAndEthPassTheAdmissionCheck() public {
        CheckToken checker = new CheckToken();
        address[3] memory tokens = [B.WBNB, B.BTCB, B.ETH];
        string[3] memory symbols = ["WBNB", "BTCB", "ETH"];
        for (uint256 i = 0; i < tokens.length; ++i) {
            CheckToken.Report memory r = checker.check(tokens[i], address(0), checker.markets());
            checker.log(r);
            assertEq(r.symbol, symbols[i]);
            assertEq(r.decimals, 18);
            assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact));
            assertTrue(r.verdict != CheckToken.Verdict.Refused, string.concat(symbols[i], " is not refused"));
        }
    }
}
