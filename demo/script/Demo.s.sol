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
import {EthereumFinalityVerifier} from "xindex/verifiers/EthereumFinalityVerifier.sol";
import {BnbStateVerifier} from "xindex/verifiers/BnbStateVerifier.sol";
import {ISP1Verifier} from "xindex/interfaces/ISP1Verifier.sol";
import {SP1Verifier} from "sp1-contracts/SP1VerifierGroth16.sol";
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
    uint256 constant BNB_TESTNET = 97;
    /// @notice The id the demo's registry gives Solana's devnet; any id no EVM chain of the index uses.
    uint256 constant SOLANA_DEVNET = 1_399_811_150;

    /// @notice Demo reference supplies, rounded, of 30 September 2026: ETH in wei, SOL in lamports, HYPE in wei.
    uint256 constant ETH_SUPPLY = 120_000_000e18;
    uint256 constant SOL_SUPPLY = 600_000_000e9;
    uint256 constant HYPE_SUPPLY = 334_000_000e18;
    /// @notice BNB in wei, rounded as the others.
    uint256 constant BNB_SUPPLY = 140_000_000e18;
    /// @notice 0.001 WETH, 0.005 SOL and about 0.0028 HYPE a share.
    uint256 constant K = 8_333_333_333_333_333_333_333_333;

    string constant SEPOLIA_FILE = "deployments/sepolia.json";
    string constant HYPEREVM_FILE = "deployments/hyperevm.json";
    string constant BNB_FILE = "deployments/bnb.json";
    string constant BNB_EPOCH_FILE = "deployments/bnb-epoch.json";
    string constant SEPOLIA_BNB_FILE = "deployments/sepolia-bnb.json";

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

    // ---------------------------------------------------------------------
    // BNB testnet: real proofs both ways, but P2
    // ---------------------------------------------------------------------
    //
    // A second index, of WETH and BNB, whose messages travel on real proofs: P1 proves Sepolia's finality on BNB
    // testnet (`proofs/`, built with `--features sepolia`), and BnbStateVerifier proves the vault's state on Sepolia
    // from BNB testnet's own validator votes. Only P2 is a stub: the demo was built before P2 (`proofs/p2`). The steps
    // run beside the ones above, on the same calendar, and need `sepolia0` first.

    /// @notice BNB testnet, day 0: SP1's Groth16 verifier, P1's verifier from a finalized Sepolia checkpoint, the stub
    ///         for P2, the state reader and the vault. Needs `P1_KEY` (`p1 vkey` of the Sepolia build), `P1_ANCHOR` and
    ///         `P1_EPOCH` (`p1-input check-state` of that checkpoint's state, which the relayer keeps as P1's first
    ///         anchor), `RELAYER2`, `FREEZER` and `RECOVERY`.
    function bnb0() external {
        require(block.chainid == BNB_TESTNET, "BNB testnet only");
        string memory s = vm.readFile(SEPOLIA_FILE);
        vm.startBroadcast();
        SP1Verifier sp1 = new SP1Verifier();
        EthereumFinalityVerifier p1 = new EthereumFinalityVerifier(
            ISP1Verifier(address(sp1)),
            vm.envBytes32("P1_KEY"),
            vm.envBytes32("P1_ANCHOR"),
            uint64(vm.envUint("P1_EPOCH"))
        );
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

        string memory j = "bnb";
        vm.serializeAddress(j, "sp1", address(sp1));
        vm.serializeAddress(j, "p1", address(p1));
        vm.serializeAddress(j, "p2", address(p2));
        // Where the relayer starts reading P1's `Advanced` events.
        vm.serializeUint(j, "fromBlock", block.number);
        string memory out = vm.serializeAddress(j, "vault", address(vault));
        vm.writeJson(out, BNB_FILE);
        console.log("vault", address(vault));
    }

    /// @notice Sepolia, day 0, after `bnb0`: BnbStateVerifier from the finalized epoch block the relayer's `bnb-epoch`
    ///         wrote, and the BNB testnet chain proposed with the vault and that verifier. From here the relayer must
    ///         keep the verifier following BNB testnet (`relay` does), since a set older than its MAX_LAG of a day
    ///         names no successor.
    function sepoliaBnb0() external {
        require(block.chainid == SEPOLIA, "Sepolia only");
        HybridIndexFactory factory = HybridIndexFactory(vm.parseJsonAddress(vm.readFile(SEPOLIA_FILE), ".factory"));
        string memory e = vm.readFile(BNB_EPOCH_FILE);
        bytes32 vault = bytes32(uint256(uint160(vm.parseJsonAddress(vm.readFile(BNB_FILE), ".vault"))));
        vm.startBroadcast();
        BnbStateVerifier bnbState =
            new BnbStateVerifier(vm.parseJsonBytes(e, ".rlp"), vm.parseJsonBytesArray(e, ".keys"));
        factory.proposeChain(BNB_TESTNET, vault, address(bnbState));
        vm.stopBroadcast();

        string memory out = vm.serializeAddress("sepoliaBnb", "bnbStateVerifier", address(bnbState));
        vm.writeJson(out, SEPOLIA_BNB_FILE);
        console.log("bnbStateVerifier", address(bnbState));
    }

    /// @notice Sepolia, from day 2 to day 9: registers BNB testnet and proposes BNB's listing. WETH's listing is
    ///         `sepolia2`'s.
    function sepoliaBnb2() external {
        HybridIndexFactory factory = HybridIndexFactory(vm.parseJsonAddress(vm.readFile(SEPOLIA_FILE), ".factory"));
        vm.startBroadcast();
        factory.executeChain(BNB_TESTNET);
        factory.proposeVaultListing(BNB_TESTNET, bytes32(0), BNB_SUPPLY);
        vm.stopBroadcast();
    }

    /// @notice Sepolia, from day 4: lists BNB and creates the index of WETH and BNB, from `SENDER_KEY`'s account as
    ///         `sepolia4`. The relayer's `register bnb` then registers it on the BNB vault.
    function sepoliaBnb4() external {
        string memory s = vm.readFile(SEPOLIA_FILE);
        HybridIndexFactory factory = HybridIndexFactory(vm.parseJsonAddress(s, ".factory"));
        address bnb = factory.vaultTokenId(BNB_TESTNET, bytes32(0));
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (vm.parseJsonAddress(s, ".weth"), bnb);
        vm.startBroadcast();
        factory.executeListing(bnb);
        address index = factory.createIndex("Xindex BNB Demo", "XBNB", tokens, K);
        vm.stopBroadcast();

        string memory j = "indexBnb";
        vm.serializeAddress(j, "index", index);
        vm.serializeBytes32(j, "salt", factory.indexSalt(index));
        string memory out = vm.serializeAddress(j, "bnb", bnb);
        vm.writeJson(out, "deployments/index-bnb.json");
        console.log("index", index);
    }
}
