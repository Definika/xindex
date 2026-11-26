// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployChecks} from "../script/DeployChecks.sol";
import {DeployWeighted} from "../script/DeployWeighted.s.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {BnbChainAddresses} from "../script/BnbChainAddresses.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {IUniversalRouterSwaps} from "../src/interfaces/IUniversalRouterSwaps.sol";

/// @notice Which chains the deployment checks pin to an address book, and how they tell the two apart. The rest of
///         `DeployChecks` is tested in `test/Scripts.t.sol`.
contract DeployChecksTest is Test {
    DeployChecks checks;

    function setUp() public {
        checks = new DeployWeighted();
    }

    /// @dev A chain-id override cannot switch the mainnet checks off against Ethereum's state: they key on Ethereum's
    ///      router having code too, which an override does not change (RX-23).
    function test_RX23_aChainIdOverrideCannotUnpinEthereum() public {
        vm.chainId(137);
        assertFalse(checks.isPinnedChain());
        vm.etch(checks.MAINNET_UNIVERSAL_ROUTER(), hex"00");
        assertTrue(checks.isPinnedChain(), "Ethereum's router is there, whatever the chain id says");
        assertFalse(checks.onBnbChain());
        assertEq(checks.pinnedRouter(), MainnetAddresses.UNIVERSAL_ROUTER);
    }

    /// @dev Nor against BNB Chain's state, which its own router names (RX-23): under an id that is no pinned chain's
    ///      the book stays BNB Chain's. Under an override to Ethereum's own id the id decides, as it must on the real
    ///      chain 1: the run stays pinned, resolves Ethereum's book, and stops at Ethereum's USDC address, which has
    ///      no code on BNB Chain (read on 2026-11-18).
    function test_RX23_aChainIdOverrideCannotUnpinBnbChain() public {
        vm.chainId(137);
        vm.etch(checks.BNB_UNIVERSAL_ROUTER(), hex"00");
        vm.etch(checks.MAINNET_UNIVERSAL_ROUTER(), hex"00"); // the replay of Ethereum's router BNB Chain holds
        assertTrue(checks.isPinnedChain(), "BNB Chain's router is there, whatever the chain id says");
        assertTrue(checks.onBnbChain());
        assertEq(checks.pinnedRouter(), BnbChainAddresses.UNIVERSAL_ROUTER);
        assertEq(checks.pinnedUsdc(), BnbChainAddresses.USDC);

        vm.chainId(1);
        assertTrue(checks.isPinnedChain(), "still a mainnet, with every mainnet check");
        assertFalse(checks.onBnbChain());
        address usdc = checks.pinnedUsdc();
        assertEq(usdc, MainnetAddresses.USDC);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressHasNoCode.selector, "USDC", usdc));
        checks.resolveStable("USDC", address(0), usdc);
    }

    /// @dev On chain 1 nothing anyone deploys names BNB Chain. Its router is a CREATE2 deployment from a factory
    ///      anyone may call, so anyone can put it at its address on Ethereum, as someone did on Base (read on
    ///      2026-11-13); the first rule of that day asked for that code before the chain id, and a replay would have
    ///      handed every deployment on Ethereum BNB Chain's book, stopping it at that book's first address with no code
    ///      on Ethereum.
    function test_bnbChainsRouterReplayedOnEthereumNamesNothing() public {
        vm.chainId(1);
        vm.etch(checks.MAINNET_UNIVERSAL_ROUTER(), hex"00");
        vm.etch(checks.BNB_UNIVERSAL_ROUTER(), hex"00");
        assertTrue(checks.isPinnedChain());
        assertFalse(checks.onBnbChain(), "chain 1 is Ethereum, whatever stands at BNB Chain's router address");
        assertEq(checks.pinnedRouter(), MainnetAddresses.UNIVERSAL_ROUTER);
        assertEq(checks.pinnedUsdc(), MainnetAddresses.USDC);
        assertEq(checks.pinnedUsdt(), MainnetAddresses.USDT);
        assertEq(checks.resolveRouter(address(0)), MainnetAddresses.UNIVERSAL_ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.MainnetOverride.selector, "UNIVERSAL_ROUTER", BnbChainAddresses.UNIVERSAL_ROUTER
            )
        );
        checks.resolveRouter(BnbChainAddresses.UNIVERSAL_ROUTER);
        // The roles are checked against Ethereum's market there, not BNB Chain's.
        vm.mockCall(
            MainnetAddresses.UNIVERSAL_ROUTER, abi.encodeWithSignature("poolManager()"), abi.encode(address(0xbeef))
        );
        assertGt(checks.marketContracts(MainnetAddresses.UNIVERSAL_ROUTER).length, 2 + BnbChainAddresses.COUNT + 3);
    }

    /// @dev Ethereum and BNB Chain are pinned, each to its own address book, and no other chain is.
    function test_ethereumAndBnbChainArePinned() public {
        assertEq(checks.BNB_UNIVERSAL_ROUTER(), BnbChainAddresses.UNIVERSAL_ROUTER);
        vm.chainId(11_155_111);
        assertFalse(checks.isPinnedChain(), "Sepolia takes its market from the environment");
        assertFalse(checks.onBnbChain());

        vm.chainId(1);
        assertTrue(checks.isPinnedChain());
        assertFalse(checks.onBnbChain());
        assertEq(checks.pinnedRouter(), MainnetAddresses.UNIVERSAL_ROUTER);
        assertEq(checks.pinnedUsdc(), MainnetAddresses.USDC);
        assertEq(checks.pinnedUsdt(), MainnetAddresses.USDT);

        vm.chainId(BnbChainAddresses.CHAIN_ID);
        assertTrue(checks.isPinnedChain());
        assertTrue(checks.onBnbChain());
        assertEq(checks.pinnedRouter(), BnbChainAddresses.UNIVERSAL_ROUTER);
        assertEq(checks.pinnedUsdc(), BnbChainAddresses.USDC);
        assertEq(checks.pinnedUsdt(), BnbChainAddresses.USDT);
    }

    /// @dev Ethereum's router address has code on BNB Chain too: a replay of Ethereum's deployment, wired to
    ///      Ethereum's PoolManager address (read on 2026-11-13). The checks before 2026-11-13 read that code as
    ///      "this is Ethereum" and resolved Ethereum's book on BNB Chain. BNB Chain is told by its chain id, and under
    ///      any id that is not a pinned chain's by its own router, asked before Ethereum's, so the replay names
    ///      nothing.
    function test_ethereumsRouterAddressOnBnbChainDoesNotNameEthereum() public {
        vm.chainId(BnbChainAddresses.CHAIN_ID);
        vm.etch(checks.MAINNET_UNIVERSAL_ROUTER(), hex"00");
        vm.etch(checks.BNB_UNIVERSAL_ROUTER(), hex"00");
        assertTrue(checks.onBnbChain());
        assertEq(checks.pinnedRouter(), BnbChainAddresses.UNIVERSAL_ROUTER);
        assertEq(checks.pinnedUsdc(), BnbChainAddresses.USDC);
        assertEq(checks.resolveRouter(address(0)), BnbChainAddresses.UNIVERSAL_ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.MainnetOverride.selector, "UNIVERSAL_ROUTER", MainnetAddresses.UNIVERSAL_ROUTER
            )
        );
        checks.resolveRouter(MainnetAddresses.UNIVERSAL_ROUTER);

        // The same state under a chain id that is not BNB Chain's: still BNB Chain's book, since its router is here.
        vm.chainId(31_337);
        assertTrue(checks.onBnbChain());
        assertEq(checks.pinnedRouter(), BnbChainAddresses.UNIVERSAL_ROUTER);
    }

    /// @dev Base is pinned to its own address book by its chain id, 8453, and by nothing else: BNB Chain's router and
    ///      Ethereum's both have code on Base, replays that settle against nothing there (read on 2026-11-21), and
    ///      before Base had a book the first of them handed a deployment on Base BNB Chain's.
    function test_baseIsPinnedByItsChainIdWhateverRoutersStandThere() public {
        assertEq(checks.BASE_UNIVERSAL_ROUTER(), BaseAddresses.UNIVERSAL_ROUTER);
        vm.chainId(BaseAddresses.CHAIN_ID);
        vm.etch(checks.BNB_UNIVERSAL_ROUTER(), hex"00");
        vm.etch(checks.MAINNET_UNIVERSAL_ROUTER(), hex"00");
        vm.etch(checks.BASE_UNIVERSAL_ROUTER(), hex"00");
        assertTrue(checks.isPinnedChain());
        assertTrue(checks.onBase());
        assertFalse(checks.onBnbChain(), "chain 8453 is Base, whatever stands at BNB Chain's router address");
        assertEq(checks.pinnedRouter(), BaseAddresses.UNIVERSAL_ROUTER);
        assertEq(checks.pinnedUsdc(), BaseAddresses.USDC);
        assertEq(checks.pinnedUsdt(), BaseAddresses.USDT);
        assertEq(checks.resolveRouter(address(0)), BaseAddresses.UNIVERSAL_ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.MainnetOverride.selector, "UNIVERSAL_ROUTER", BnbChainAddresses.UNIVERSAL_ROUTER
            )
        );
        checks.resolveRouter(BnbChainAddresses.UNIVERSAL_ROUTER);

        // The roles are checked against Base's market there: the router, its PoolManager, Aero's router and its three
        // factories, the book's tokens, the two mint currencies and Pyth.
        vm.mockCall(
            BaseAddresses.UNIVERSAL_ROUTER, abi.encodeWithSignature("poolManager()"), abi.encode(address(0xbeef))
        );
        address[] memory market = checks.marketContracts(BaseAddresses.UNIVERSAL_ROUTER);
        assertEq(market.length, 6 + BaseAddresses.COUNT + 3);
        assertEq(market[2], BaseAddresses.AERO_METAROUTER);
        assertEq(market[6], BaseAddresses.WETH);
        assertEq(market[market.length - 3], BaseAddresses.USDC);
        assertEq(market[market.length - 2], BaseAddresses.USDT);
        assertEq(market[market.length - 1], BaseAddresses.PYTH);
        assertEq(checks.pinnedPyth(), BaseAddresses.PYTH);
    }

    /// @dev Base's router address has code on Ethereum and on BNB Chain too (read on 2026-11-21), so no router's code
    ///      names Base: under any id but 8453 the same state is not Base. On Ethereum's and BNB Chain's own ids
    ///      their ids decide, and under any other the book is the one the routers there name, never Base's. A run
    ///      against Base's state under another id is therefore still pinned, to BNB Chain's book, whose USDC address
    ///      has no code on Base: it stops there.
    function test_basesRouterReplayedElsewhereNamesNothing() public {
        vm.etch(checks.BASE_UNIVERSAL_ROUTER(), hex"00");
        vm.chainId(137);
        assertFalse(checks.onBase());
        assertFalse(checks.isPinnedChain(), "Base's router alone pins nothing");

        vm.chainId(1);
        assertFalse(checks.onBase());
        assertEq(checks.pinnedRouter(), MainnetAddresses.UNIVERSAL_ROUTER);
        vm.chainId(BnbChainAddresses.CHAIN_ID);
        assertFalse(checks.onBase());
        assertEq(checks.pinnedRouter(), BnbChainAddresses.UNIVERSAL_ROUTER);

        // Base's state under an override: BNB Chain's router stands there, and the run resolves BNB Chain's book.
        vm.chainId(31_337);
        vm.etch(checks.BNB_UNIVERSAL_ROUTER(), hex"00");
        assertTrue(checks.isPinnedChain(), "still pinned, whatever the chain id says");
        assertFalse(checks.onBase());
        address usdc = checks.pinnedUsdc();
        assertEq(usdc, BnbChainAddresses.USDC);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressHasNoCode.selector, "USDC", usdc));
        checks.resolveStable("USDC", address(0), usdc);
    }

    /// @dev Each chain's own DEX beside Uniswap comes from its address book alone: none off the pinned chains and on
    ///      Ethereum, PancakeSwap's router on BNB Chain, Aero's Metarouter and three factories on Base; and every
    ///      address it names must have code (the owner's call of 2026-11-26).
    function test_eachPinnedChainNamesItsOwnDex() public {
        IUniversalRouterSwaps.LocalVenue memory venue = checks.pinnedLocalVenue();
        assertEq(uint8(venue.dex), uint8(IUniversalRouterSwaps.LocalDex.None));
        assertEq(venue.router, address(0));
        assertEq(checks.resolveLocalVenue().router, address(0), "nothing to have code");
        vm.chainId(1);
        assertEq(uint8(checks.pinnedLocalVenue().dex), uint8(IUniversalRouterSwaps.LocalDex.None));

        vm.chainId(BnbChainAddresses.CHAIN_ID);
        venue = checks.pinnedLocalVenue();
        assertEq(uint8(venue.dex), uint8(IUniversalRouterSwaps.LocalDex.PancakeSwap));
        assertEq(venue.router, BnbChainAddresses.PANCAKE_UNIVERSAL_ROUTER);
        assertEq(venue.clFactory, address(0));
        assertEq(venue.stableFactory, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.AddressHasNoCode.selector, "LOCAL_VENUE", BnbChainAddresses.PANCAKE_UNIVERSAL_ROUTER
            )
        );
        checks.resolveLocalVenue();
        vm.etch(BnbChainAddresses.PANCAKE_UNIVERSAL_ROUTER, hex"00");
        assertEq(checks.resolveLocalVenue().router, BnbChainAddresses.PANCAKE_UNIVERSAL_ROUTER);

        vm.chainId(BaseAddresses.CHAIN_ID);
        venue = checks.pinnedLocalVenue();
        assertEq(uint8(venue.dex), uint8(IUniversalRouterSwaps.LocalDex.Aero));
        assertEq(venue.router, BaseAddresses.AERO_METAROUTER);
        assertEq(venue.clFactory, BaseAddresses.AERO_CL_FACTORY);
        assertEq(venue.volatileFactory, BaseAddresses.AERO_VOLATILE_FACTORY);
        assertEq(venue.stableFactory, BaseAddresses.AERO_STABLE_FACTORY);
        vm.etch(BaseAddresses.AERO_METAROUTER, hex"00");
        vm.etch(BaseAddresses.AERO_CL_FACTORY, hex"00");
        vm.etch(BaseAddresses.AERO_VOLATILE_FACTORY, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.AddressHasNoCode.selector, "LOCAL_VENUE", BaseAddresses.AERO_STABLE_FACTORY
            )
        );
        checks.resolveLocalVenue();
        vm.etch(BaseAddresses.AERO_STABLE_FACTORY, hex"00");
        assertEq(checks.resolveLocalVenue().stableFactory, BaseAddresses.AERO_STABLE_FACTORY);
    }
}
