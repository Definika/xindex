// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BnbStateVerifier} from "../src/verifiers/BnbStateVerifier.sol";
import {TronStateVerifier} from "../src/verifiers/TronStateVerifier.sol";
import {NearStateVerifier} from "../src/verifiers/NearStateVerifier.sol";
import {StellarStateVerifier} from "../src/verifiers/StellarStateVerifier.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {IBnbStateVerifier} from "../src/interfaces/IBnbStateVerifier.sol";
import {ITronStateVerifier} from "../src/interfaces/ITronStateVerifier.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice Deploys a vault chain's state verifier on Ethereum from an anchor read off that chain: BNB Chain's
///         `BnbStateVerifier` from a final epoch block and its validators' keys, or TRON's `TronStateVerifier` from the
///         producers of the period in progress. The anchor is the one thing a verifier trusts; every later set or list
///         is proven from it. So it must be fresh; the verifier must be advanced within MAX_LAG (1 day) of it, and
///         every day after, or it stops for good; and the owner and guardian check it against the chain itself during
///         the chain's listing delay, with `checkBnb` or `checkTron`.
///
///     python3 test/fixtures/bnb/generate.py <BNB Chain RPC> anchor bnb-anchor.json
///     STATE_CHAIN=bnb STATE_ANCHOR=bnb-anchor.json forge script script/DeployStateVerifier.s.sol --rpc-url mainnet \
///       --account deployer --sender <deployer> --broadcast
///
///   TRON's is the same with `tron` and `test/fixtures/tron/generate.py <TronGrid URL> anchor`. NEAR's and Stellar's
///   verifiers check SP1 proofs of their chain's finality, so they also take the program's key and SP1's Groth16
///   verifier: NEAR's from an epoch and its producers (`proofs/near`), Stellar's from the network and the pinned Tier 1
///   quorum set (`proofs/stellar`), each for one vault. The chain is then added with `ConfigureChains`, naming the
///   verifier. Forge simulates the whole run first, so a check that fails broadcasts nothing.
///
/// Env:
///   STATE_CHAIN         `bnb`, `tron`, `near` or `stellar`.
///   STATE_ANCHOR        The anchor file: the generator's for BNB Chain and TRON; for NEAR `epochId`, `producersHash`,
///                       `namedAt` (nanoseconds), `account` and `chainId`; for Stellar `networkId`, `quorumSet` (its
///                       XDR), `chainId` and `vaultId`; for both, `programKey`.
///   STATE_SP1_VERIFIER  NEAR and Stellar: SP1's Groth16 verifier v6.0.0 on Ethereum, a bare verifier.
contract DeployStateVerifier is Script {
    /// @notice The oldest BNB Chain anchor deployed, which leaves the rest of MAX_LAG to advance the verifier.
    uint256 public constant MAX_ANCHOR_AGE = 1 hours;

    /// @dev TRON's times are in milliseconds.
    uint256 private constant MS = 1000;
    /// @dev TRON's maintenance interval, in milliseconds: the verifier's INTERVAL.
    uint256 private constant TRON_INTERVAL = 6 hours * MS;
    uint256 private constant SEPOLIA = 11_155_111;
    string private constant PRODUCER = "Producer(address witness,address key)";

    /// @notice The registry ids of NEAR's and Stellar's networks: the first 8 bytes of `keccak256` of their CAIP-2 names
    ///         (`design/2026-10-03-near-stellar-interfaces.md`).
    uint256 public constant NEAR_MAINNET = 339_552_387_624_818_629;
    uint256 public constant NEAR_TESTNET = 4_078_699_518_750_379_172;
    uint256 public constant STELLAR_PUBNET = 839_718_837_228_939_926;
    uint256 public constant STELLAR_TESTNET = 17_667_989_177_921_016_935;
    /// @notice Stellar's network ids: SHA-256 of each network's passphrase, which every validator's signature covers.
    bytes32 public constant STELLAR_PUBNET_ID = 0x7ac33997544e3175d266bd022439b22cdb16508c01163f26e5cb2a3e1045a979;
    bytes32 public constant STELLAR_TESTNET_ID = 0xcee0302d59844d32bdca915c8203dd44b33fbb7edc19051ea37abedf28ecd472;
    /// @notice The oldest NEAR anchor deployed. A set of producers is named an epoch, about 7.2 hours, before it serves,
    ///         so the anchor of the epoch in force is up to two epochs old; this leaves 8 hours of MAX_LAG to advance it.
    uint256 public constant MAX_NEAR_ANCHOR_AGE = 16 hours;
    /// @dev NEAR's times are in nanoseconds.
    uint256 private constant NS = 1e9;

    /// @notice A verifier of a chain's state belongs on Ethereum, beside the hub, and the BNB verifier needs Ethereum's
    ///         BLS12-381 precompiles: mainnet or Sepolia only.
    error NotEthereum(uint256 chainId);
    /// @notice STATE_CHAIN is none of `bnb`, `tron`, `near` and `stellar`.
    error UnknownChain(string chain);
    /// @notice `chainId` is not the registry id of the chain's network that pairs with this Ethereum network: mainnet's
    ///         on mainnet, the testnet's on Sepolia.
    error WrongNetwork(uint256 chainId);
    /// @notice `networkId` is not the hash of the Stellar network's passphrase.
    error WrongNetworkId(bytes32 networkId);
    /// @notice `verifier` does not name itself SP1's Groth16 verifier v6.0.0.
    error NotSp1Verifier(address verifier);
    /// @notice The BNB anchor's epoch block, dated `time`, is in the future or more than MAX_ANCHOR_AGE old.
    error StaleAnchor(uint256 time, uint256 timestamp);
    /// @notice The TRON anchor's period, ending at `nextMaintenance` (milliseconds), is not the one in progress.
    error NotThePeriodInProgress(uint256 nextMaintenance, uint256 timestampMs);
    /// @notice `verifier` does not run the code this release compiles.
    error WrongCode(address verifier);
    /// @notice `verifier` did not start from the anchor given.
    error WrongAnchor(address verifier);

    /// @notice Reads the chain and its anchor from the environment and deploys its verifier.
    function run() external returns (address verifier) {
        string memory chain = vm.envString("STATE_CHAIN");
        // Reads the one file the operator names, which the deployment is built from.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(vm.envString("STATE_ANCHOR"));
        if (ScriptUtils.same(chain, "bnb")) {
            return address(deployBnb(vm.parseJsonBytes(json, ".rlp"), vm.parseJsonBytesArray(json, ".keys")));
        }
        if (ScriptUtils.same(chain, "tron")) {
            uint64 nextMaintenance = SafeCast.toUint64(vm.parseJsonUint(json, ".nextMaintenance"));
            return address(deployTron(producers(json), nextMaintenance));
        }
        if (ScriptUtils.same(chain, "near")) {
            return address(
                deployNear(
                    ISP1Verifier(vm.envAddress("STATE_SP1_VERIFIER")),
                    vm.parseJsonBytes32(json, ".programKey"),
                    vm.parseJsonUint(json, ".chainId"),
                    vm.parseJsonString(json, ".account"),
                    vm.parseJsonBytes32(json, ".epochId"),
                    vm.parseJsonBytes32(json, ".producersHash"),
                    SafeCast.toUint64(vm.parseJsonUint(json, ".namedAt"))
                )
            );
        }
        if (ScriptUtils.same(chain, "stellar")) {
            return address(
                deployStellar(
                    ISP1Verifier(vm.envAddress("STATE_SP1_VERIFIER")),
                    vm.parseJsonBytes32(json, ".programKey"),
                    vm.parseJsonBytes32(json, ".networkId"),
                    vm.parseJsonBytes(json, ".quorumSet"),
                    vm.parseJsonUint(json, ".chainId"),
                    vm.parseJsonBytes32(json, ".vaultId")
                )
            );
        }
        revert UnknownChain(chain);
    }

    /// @notice The producers a TRON anchor file lists.
    function producers(string memory json) public pure returns (ITronStateVerifier.Producer[] memory) {
        return abi.decode(vm.parseJsonTypeArray(json, ".producers", PRODUCER), (ITronStateVerifier.Producer[]));
    }

    /// @notice Deploys BNB Chain's verifier from `epochHeader`, the RLP of a final epoch block, and `keys`, its
    ///         validators' uncompressed BLS keys in the header's order. The verifier checks the header's set and each
    ///         key on the curve; this checks the chain and the anchor's age.
    function deployBnb(bytes memory epochHeader, bytes[] memory keys) public returns (BnbStateVerifier verifier) {
        _requireEthereum();
        vm.startBroadcast();
        verifier = new BnbStateVerifier(epochHeader, keys);
        vm.stopBroadcast();
        uint256 epoch = verifier.latestEpoch();
        IBnbStateVerifier.ValidatorSet memory set = verifier.validatorSet(epoch);
        if (set.time > block.timestamp || block.timestamp - set.time > MAX_ANCHOR_AGE) {
            revert StaleAnchor(set.time, block.timestamp);
        }
        console2.log("BnbStateVerifier:", address(verifier));
        console2.log("  code hash:       ", vm.toString(address(verifier).codehash));
        console2.log("  anchor epoch:    ", epoch);
        console2.log("  anchor hash:     ", vm.toString(keccak256(epochHeader)));
        console2.log("  validators:      ", set.count);
        console2.log("  advance before:  ", uint256(set.time) + verifier.MAX_LAG());
    }

    /// @notice Deploys TRON's verifier from `list`, the producers of the period in progress in ascending witness
    ///         order, and `nextMaintenance`, when that period ends. The verifier checks the list's shape; this checks
    ///         the chain and that the period is the one in progress.
    function deployTron(ITronStateVerifier.Producer[] memory list, uint64 nextMaintenance)
        public
        returns (TronStateVerifier verifier)
    {
        _requireEthereum();
        uint256 nowMs = block.timestamp * MS;
        if (nextMaintenance <= nowMs || nextMaintenance > nowMs + TRON_INTERVAL) {
            revert NotThePeriodInProgress(nextMaintenance, nowMs);
        }
        vm.startBroadcast();
        verifier = new TronStateVerifier(list, nextMaintenance);
        vm.stopBroadcast();
        ITronStateVerifier.ProducerList memory recorded = verifier.producerList(0);
        console2.log("TronStateVerifier:", address(verifier));
        console2.log("  code hash:        ", vm.toString(address(verifier).codehash));
        console2.log("  producers hash:   ", vm.toString(recorded.producersHash));
        console2.log("  producers:        ", recorded.count);
        console2.log("  period ends (ms): ", recorded.end);
        console2.log("  advance before:   ", uint256(recorded.start) / MS + verifier.MAX_LAG());
    }

    /// @notice Deploys NEAR's verifier for the vault at `account`, from epoch `epoch` and the hash of its ordered block
    ///         producers, named at `named` (nanoseconds) by a block of the epoch before (`proofs/near`'s generator). It
    ///         checks SP1's verifier, the network the registry id names against this one, and the anchor's age: named
    ///         within MAX_NEAR_ANCHOR_AGE, and never in the future.
    function deployNear(
        ISP1Verifier sp1,
        bytes32 programKey,
        uint256 chainId,
        string memory account,
        bytes32 epoch,
        bytes32 producersHash,
        uint64 named
    ) public returns (NearStateVerifier verifier) {
        _requireEthereum();
        if (chainId != (block.chainid == SEPOLIA ? NEAR_TESTNET : NEAR_MAINNET)) revert WrongNetwork(chainId);
        if (!ScriptUtils.isSp1Verifier(address(sp1))) revert NotSp1Verifier(address(sp1));
        uint256 namedAt = uint256(named) / NS;
        if (namedAt > block.timestamp || block.timestamp - namedAt > MAX_NEAR_ANCHOR_AGE) {
            revert StaleAnchor(namedAt, block.timestamp);
        }
        vm.startBroadcast();
        verifier = new NearStateVerifier(sp1, programKey, chainId, account, epoch, producersHash, named);
        vm.stopBroadcast();
        console2.log("NearStateVerifier:", address(verifier));
        console2.log("  code hash:       ", vm.toString(address(verifier).codehash));
        console2.log("  vault id:        ", vm.toString(verifier.VAULT_ID()));
        console2.log("  advance before:  ", namedAt + verifier.MAX_LAG());
    }

    /// @notice Deploys Stellar's verifier for the vault `vaultId`, from the network's id and the pinned quorum set's XDR
    ///         (Tier 1's, as its validators commit to it). A new Tier 1 is a new verifier, rotated in by the factory's
    ///         ROTATION_DELAY. It checks SP1's verifier, the network the registry id names against this one, and the
    ///         network id against that network's passphrase.
    function deployStellar(
        ISP1Verifier sp1,
        bytes32 programKey,
        bytes32 networkId,
        bytes memory quorumSet,
        uint256 chainId,
        bytes32 vaultId
    ) public returns (StellarStateVerifier verifier) {
        _requireEthereum();
        bool testnet = block.chainid == SEPOLIA;
        if (chainId != (testnet ? STELLAR_TESTNET : STELLAR_PUBNET)) revert WrongNetwork(chainId);
        if (networkId != (testnet ? STELLAR_TESTNET_ID : STELLAR_PUBNET_ID)) revert WrongNetworkId(networkId);
        if (!ScriptUtils.isSp1Verifier(address(sp1))) revert NotSp1Verifier(address(sp1));
        vm.startBroadcast();
        verifier = new StellarStateVerifier(sp1, programKey, networkId, sha256(quorumSet), chainId, vaultId);
        vm.stopBroadcast();
        console2.log("StellarStateVerifier:", address(verifier));
        console2.log("  code hash:          ", vm.toString(address(verifier).codehash));
        console2.log("  quorum set hash:    ", vm.toString(sha256(quorumSet)));
    }

    /// @notice The review of a deployed BNB verifier: it runs this release's code, and its first set is the one
    ///         `number`'s epoch block lists, with `keys`, and no set before it. Every set after the first is proven
    ///         from it, so this roots the verifier in the anchor; the reviewer then compares the anchor file with BNB
    ///         Chain itself (the epoch block's hash, and the keys its validators registered).
    function checkBnb(address verifier, uint256 number, bytes[] memory keys) public view returns (bytes32 codehash) {
        codehash = verifier.codehash;
        if (codehash != keccak256(type(BnbStateVerifier).runtimeCode)) revert WrongCode(verifier);
        BnbStateVerifier v = BnbStateVerifier(verifier);
        IBnbStateVerifier.ValidatorSet memory set = v.validatorSet(number);
        bool first = number < v.EPOCH_LENGTH() || v.validatorSet(number - v.EPOCH_LENGTH()).keysHash == 0;
        if (set.keysHash != keccak256(abi.encode(keys)) || set.count != keys.length || !first) {
            revert WrongAnchor(verifier);
        }
    }

    /// @notice The review of a deployed TRON verifier: it runs this release's code, and its first list, id 0, is
    ///         `list`, for the period ending at `nextMaintenance`. The reviewer then compares the anchor file with TRON
    ///         itself (`listwitnesses`, and the producers' blocks in that period).
    function checkTron(address verifier, ITronStateVerifier.Producer[] memory list, uint64 nextMaintenance)
        public
        view
        returns (bytes32 codehash)
    {
        codehash = verifier.codehash;
        if (codehash != keccak256(type(TronStateVerifier).runtimeCode)) revert WrongCode(verifier);
        ITronStateVerifier.ProducerList memory first = TronStateVerifier(verifier).producerList(0);
        if (first.producersHash != keccak256(abi.encode(list)) || first.end != nextMaintenance) {
            revert WrongAnchor(verifier);
        }
    }

    function _requireEthereum() private view {
        if (block.chainid != 1 && block.chainid != SEPOLIA) revert NotEthereum(block.chainid);
    }
}
