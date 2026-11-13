// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployChecks} from "../script/DeployChecks.sol";
import {DeployWeighted} from "../script/DeployWeighted.s.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {BnbChainAddresses} from "../script/BnbChainAddresses.sol";

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
    ///      chain 1: the run stays pinned, resolves Ethereum's book, and stops at Ethereum's WETH address, which has
    ///      no code on BNB Chain.
    function test_RX23_aChainIdOverrideCannotUnpinBnbChain() public {
        vm.chainId(137);
        vm.etch(checks.BNB_UNIVERSAL_ROUTER(), hex"00");
        vm.etch(checks.MAINNET_UNIVERSAL_ROUTER(), hex"00"); // the replay of Ethereum's router BNB Chain holds
        assertTrue(checks.isPinnedChain(), "BNB Chain's router is there, whatever the chain id says");
        assertTrue(checks.onBnbChain());
        assertEq(checks.pinnedRouter(), BnbChainAddresses.UNIVERSAL_ROUTER);
        assertEq(checks.pinnedWeth(), BnbChainAddresses.WBNB);

        vm.chainId(1);
        assertTrue(checks.isPinnedChain(), "still a mainnet, with every mainnet check");
        assertFalse(checks.onBnbChain());
        address weth = checks.pinnedWeth();
        assertEq(weth, MainnetAddresses.WETH);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressHasNoCode.selector, "WETH", weth));
        checks.resolveStable("WETH", address(0), weth);
    }

    /// @dev On chain 1 nothing anyone deploys names BNB Chain. Its router is a CREATE2 deployment from a factory
    ///      anyone may call, so anyone can put it at its address on Ethereum, as someone did on Base (read on
    ///      2026-11-13); the first rule of that day asked for that code before the chain id, and a replay would have
    ///      handed every deployment on Ethereum BNB Chain's book, stopping it at WBNB's address.
    function test_bnbChainsRouterReplayedOnEthereumNamesNothing() public {
        vm.chainId(1);
        vm.etch(checks.MAINNET_UNIVERSAL_ROUTER(), hex"00");
        vm.etch(checks.BNB_UNIVERSAL_ROUTER(), hex"00");
        assertTrue(checks.isPinnedChain());
        assertFalse(checks.onBnbChain(), "chain 1 is Ethereum, whatever stands at BNB Chain's router address");
        assertEq(checks.pinnedRouter(), MainnetAddresses.UNIVERSAL_ROUTER);
        assertEq(checks.pinnedWeth(), MainnetAddresses.WETH);
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
        assertGt(checks.marketContracts(MainnetAddresses.UNIVERSAL_ROUTER).length, 2 + BnbChainAddresses.COUNT + 2);
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
        assertEq(checks.pinnedWeth(), MainnetAddresses.WETH);
        assertEq(checks.pinnedUsdc(), MainnetAddresses.USDC);
        assertEq(checks.pinnedUsdt(), MainnetAddresses.USDT);

        vm.chainId(BnbChainAddresses.CHAIN_ID);
        assertTrue(checks.isPinnedChain());
        assertTrue(checks.onBnbChain());
        assertEq(checks.pinnedRouter(), BnbChainAddresses.UNIVERSAL_ROUTER);
        assertEq(checks.pinnedWeth(), BnbChainAddresses.WBNB, "the zap wraps BNB there");
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
}
