// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// TESTNETS ONLY (design/2026-09-30-hackathon-plan.md). Every step reads what the last wrote in deployments/.

import {Script, console} from "forge-std/Script.sol";
import {HybridIndexFactory} from "xindex/HybridIndexFactory.sol";
import {HybridHub} from "xindex/HybridHub.sol";
import {HybridHubModule} from "xindex/hybrid/HybridHubModule.sol";
import {HybridHubExtension} from "xindex/hybrid/HybridHubExtension.sol";
import {IXindexVault} from "xindex/interfaces/IXindexVault.sol";
import {XindexVault} from "xindex/vault/XindexVault.sol";
import {EthereumStateReader} from "xindex/verifiers/EthereumStateReader.sol";
import {StubEventVerifier} from "../src/StubEventVerifier.sol";
import {StubStateVerifier} from "../src/StubStateVerifier.sol";
import {DemoToken} from "../src/DemoToken.sol";

/// @title Demo
/// @notice The hackathon's testnet deployment, step by step along the factory's timelocks: day 0 deploys and proposes
///         the chains, day 2 registers them and proposes the coins' listings, day 4 lists them and creates the index.
///         Run each step with `forge script script/Demo.s.sol --sig "<step>()" --rpc-url <chain> --broadcast` and a
///         keystore or `--browser` wallet; the broadcaster is the factory's owner on the testnet.
contract Demo is Script {
    uint256 constant SEPOLIA = 11_155_111;
    uint256 constant HYPEREVM_TESTNET = 998;
    /// @notice The id the demo's registry gives Solana's devnet; any id no EVM chain of the index uses.
    uint256 constant SOLANA_DEVNET = 1_399_811_150;

    /// @notice Demo reference supplies, rounded, of 30 September 2026: ETH in wei, SOL in lamports, HYPE in wei.
    uint256 constant ETH_SUPPLY = 120_000_000e18;
    uint256 constant SOL_SUPPLY = 600_000_000e9;
    uint256 constant HYPE_SUPPLY = 334_000_000e18;
    /// @notice 0.001 WETH, 0.005 SOL and about 0.0028 HYPE a share.
    uint256 constant K = 8_333_333_333_333_333_333_333_333;

    string constant SEPOLIA_FILE = "deployments/sepolia.json";
    string constant HYPEREVM_FILE = "deployments/hyperevm.json";

    // ---------------------------------------------------------------------
    // day 0
    // ---------------------------------------------------------------------

    /// @notice Sepolia, day 0: the hub's three parts and the factory, the Solana chain's stub state verifier, a demo
    ///         WETH; proposes the Solana chain and WETH's listing. Needs `GUARDIAN`, `STATE_RELAYER` and
    ///         `SOLANA_VAULT` (the vault program's `config` account, 32 bytes).
    function sepolia0() external {
        require(block.chainid == SEPOLIA, "Sepolia only");
        address guardian = vm.envAddress("GUARDIAN");
        address stateRelayer = vm.envAddress("STATE_RELAYER");
        bytes32 solanaVault = vm.envBytes32("SOLANA_VAULT");

        vm.startBroadcast();
        address owner = msg.sender;
        address predicted = vm.computeCreateAddress(owner, vm.getNonce(owner) + 3);
        HybridHubExtension extension = new HybridHubExtension(predicted);
        HybridHubModule module = new HybridHubModule(predicted, address(extension));
        HybridHub template = new HybridHub(predicted, address(module));
        HybridIndexFactory factory = new HybridIndexFactory(owner, guardian, address(template));
        require(address(factory) == predicted, "factory address");
        StubStateVerifier solanaState = new StubStateVerifier(stateRelayer, SOLANA_DEVNET);
        StubStateVerifier hyperState = new StubStateVerifier(stateRelayer, HYPEREVM_TESTNET);
        DemoToken weth = new DemoToken("Demo Wrapped Ether (testnet)", "dWETH");
        factory.proposeChain(SOLANA_DEVNET, solanaVault, address(solanaState));
        factory.proposeListing(address(weth), ETH_SUPPLY);
        vm.stopBroadcast();

        string memory j = "sepolia";
        vm.serializeAddress(j, "factory", address(factory));
        vm.serializeAddress(j, "template", address(template));
        vm.serializeAddress(j, "module", address(module));
        vm.serializeAddress(j, "extension", address(extension));
        vm.serializeAddress(j, "solanaStateVerifier", address(solanaState));
        vm.serializeAddress(j, "hyperStateVerifier", address(hyperState));
        vm.serializeAddress(j, "weth", address(weth));
        vm.serializeBytes32(j, "solanaVault", solanaVault);
        vm.serializeUint(j, "solanaChainId", SOLANA_DEVNET);
        string memory out = vm.serializeUint(j, "hyperChainId", HYPEREVM_TESTNET);
        vm.writeJson(out, SEPOLIA_FILE);
        console.log("factory", address(factory));
        console.log("template", address(template));
    }

    /// @notice HyperEVM testnet, day 0: two stub event verifiers (P1, P2), the state reader and the vault, for the
    ///         factory and template `sepolia0` deployed. Needs `RELAYER1`, `RELAYER2`, `FREEZER` and `RECOVERY`.
    ///         The vault is about 23KB: HyperEVM puts it in a big block, which the deployer must have opted into.
    function hyperevm0() external {
        require(block.chainid == HYPEREVM_TESTNET, "HyperEVM testnet only");
        string memory s = vm.readFile(SEPOLIA_FILE);
        vm.startBroadcast();
        StubEventVerifier p1 = new StubEventVerifier(vm.envAddress("RELAYER1"));
        StubEventVerifier p2 = new StubEventVerifier(vm.envAddress("RELAYER2"));
        XindexVault vault = new XindexVault(
            IXindexVault.Config({
                sourceChainId: SEPOLIA,
                factory: vm.parseJsonAddress(s, ".factory"),
                hubImplementation: vm.parseJsonAddress(s, ".template"),
                verifier1: p1,
                verifier2: p2,
                freezer: vm.envAddress("FREEZER"),
                recoveryProposer: vm.envAddress("RECOVERY"),
                stateReader: new EthereumStateReader(),
                nativeCap: 1_000e18,
                nativeFloor: 1e18
            })
        );
        vm.stopBroadcast();

        string memory j = "hyperevm";
        vm.serializeAddress(j, "p1", address(p1));
        vm.serializeAddress(j, "p2", address(p2));
        string memory out = vm.serializeAddress(j, "vault", address(vault));
        vm.writeJson(out, HYPEREVM_FILE);
        console.log("vault", address(vault));
    }

    /// @notice Sepolia, day 0, after `hyperevm0`: proposes the HyperEVM chain with its vault.
    function sepolia0b() external {
        string memory s = vm.readFile(SEPOLIA_FILE);
        string memory h = vm.readFile(HYPEREVM_FILE);
        HybridIndexFactory factory = HybridIndexFactory(vm.parseJsonAddress(s, ".factory"));
        bytes32 vault = bytes32(uint256(uint160(vm.parseJsonAddress(h, ".vault"))));
        vm.broadcast();
        factory.proposeChain(HYPEREVM_TESTNET, vault, vm.parseJsonAddress(s, ".hyperStateVerifier"));
    }

    // ---------------------------------------------------------------------
    // day 2
    // ---------------------------------------------------------------------

    /// @notice Sepolia, from day 2 (LISTING_DELAY) to day 9 (PROPOSAL_WINDOW): registers both chains, lists WETH, and
    ///         proposes SOL's and HYPE's listings.
    function sepolia2() external {
        string memory s = vm.readFile(SEPOLIA_FILE);
        HybridIndexFactory factory = HybridIndexFactory(vm.parseJsonAddress(s, ".factory"));
        vm.startBroadcast();
        factory.executeChain(SOLANA_DEVNET);
        factory.executeChain(HYPEREVM_TESTNET);
        factory.executeListing(vm.parseJsonAddress(s, ".weth"));
        factory.proposeVaultListing(SOLANA_DEVNET, bytes32(0), SOL_SUPPLY);
        factory.proposeVaultListing(HYPEREVM_TESTNET, bytes32(0), HYPE_SUPPLY);
        vm.stopBroadcast();
    }

    // ---------------------------------------------------------------------
    // day 4
    // ---------------------------------------------------------------------

    /// @notice Sepolia, from day 4: lists SOL and HYPE and creates the demo index of WETH, SOL and HYPE. The index must
    ///         then be registered on both vaults with its salt (the relayer's `register` does it).
    function sepolia4() external {
        string memory s = vm.readFile(SEPOLIA_FILE);
        HybridIndexFactory factory = HybridIndexFactory(vm.parseJsonAddress(s, ".factory"));
        address sol = factory.vaultTokenId(SOLANA_DEVNET, bytes32(0));
        address hype = factory.vaultTokenId(HYPEREVM_TESTNET, bytes32(0));
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (vm.parseJsonAddress(s, ".weth"), sol, hype);
        vm.startBroadcast();
        factory.executeListing(sol);
        factory.executeListing(hype);
        address index = factory.createIndex("Xindex Hybrid Demo", "XHD", tokens, K);
        vm.stopBroadcast();

        string memory j = "index";
        vm.serializeAddress(j, "index", index);
        vm.serializeBytes32(j, "salt", factory.indexSalt(index));
        vm.serializeAddress(j, "sol", sol);
        string memory out = vm.serializeAddress(j, "hype", hype);
        vm.writeJson(out, "deployments/index.json");
        console.log("index", index);
    }
}
