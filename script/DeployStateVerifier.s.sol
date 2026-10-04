// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BnbStateVerifier} from "../src/verifiers/BnbStateVerifier.sol";
import {TronStateVerifier} from "../src/verifiers/TronStateVerifier.sol";
import {NearStateVerifier} from "../src/verifiers/NearStateVerifier.sol";
import {StellarStateVerifier} from "../src/verifiers/StellarStateVerifier.sol";
import {SuiStateVerifier} from "../src/verifiers/SuiStateVerifier.sol";
import {CometBftStateVerifier} from "../src/verifiers/CometBftStateVerifier.sol";
import {VeChainStateVerifier} from "../src/verifiers/VeChainStateVerifier.sol";
import {Bls12381MinSig} from "../src/libraries/Bls12381MinSig.sol";
import {ICometBftStateVerifier} from "../src/interfaces/ICometBftStateVerifier.sol";
import {IVeChainStateVerifier} from "../src/interfaces/IVeChainStateVerifier.sol";
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
///   quorum set (`proofs/stellar`), each for one vault. Sui's checks its committee's BLS signatures itself, from an
///   epoch and its committee (`test/fixtures/sui/generate.py`); Injective's (`proofs/cometbft`) and VeChain's
///   (`proofs/vechain`) check SP1 proofs, from a header or a staker table (`design/2026-10-04-four-chains-interfaces.md`).
///   The chain is then added with `ConfigureChains`, naming the verifier. Forge simulates the whole run first, so a
///   check that fails broadcasts nothing.
///
/// Env:
///   STATE_CHAIN         `bnb`, `tron`, `near`, `stellar`, `sui`, `injective` or `vechain`.
///   STATE_ANCHOR        The anchor file: the generator's for BNB Chain and TRON; for NEAR `epochId`, `producersHash`,
///                       `namedAt` (nanoseconds), `account` and `chainId`; for Stellar `networkId`, `quorumSet` (its
///                       XDR), `chainId` and `vaultId`; for both, `programKey`. For Sui the generator's `chainId`,
///                       `epoch`, `startMs`, `keys`, `compressed` and `powers`, with the vault's `vaultId` and
///                       `packageId`; for Injective the generator's `chainId`, `cosmosChainId`, `height`, `hash` and
///                       `time`; for VeChain its `chainId`, `id`, `time` and `table`; for both, the `vault` and
///                       `programKey`, and VeChain's `attester`.
///   STATE_SP1_VERIFIER  NEAR, Stellar, Injective and VeChain: SP1's Groth16 verifier v6.0.0 on Ethereum, a bare
///                       verifier.
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

    /// @notice Sui's registry ids, `sui:mainnet` and `sui:testnet` hashed as NEAR's are; Injective's and VeChain's are
    ///         their EVM chain ids, VeChain's being its genesis block's id (`design/2026-10-04-four-chains-interfaces.md`).
    uint256 public constant SUI_MAINNET = 13_762_264_207_064_992_463;
    uint256 public constant SUI_TESTNET = 10_803_649_406_359_875_205;
    uint256 public constant INJECTIVE_MAINNET = 1776;
    uint256 public constant INJECTIVE_TESTNET = 1439;
    bytes32 private constant VECHAIN_MAINNET_GENESIS =
        hex"00000000851caf3cfdb6e899cf5958bfb1ac3413d346d43539627e6be7ec1b4a";
    uint256 public constant VECHAIN_MAINNET = uint256(VECHAIN_MAINNET_GENESIS);
    bytes32 private constant VECHAIN_TESTNET_GENESIS =
        hex"000000000b2bce3c70bc649a02749e8687721b09ed2e15997f466536b20bb127";
    uint256 public constant VECHAIN_TESTNET = uint256(VECHAIN_TESTNET_GENESIS);
    /// @notice The oldest Sui anchor deployed: the verifier stops two days after its committee's epoch began, and an
    ///         epoch lasts a day, so this leaves at least a day and four hours for the first update.
    uint256 public constant MAX_SUI_ANCHOR_AGE = 20 hours;
    /// @notice The oldest VeChain anchor deployed, a table read at a finalized block: it leaves 18 hours of MAX_LAG.
    uint256 public constant MAX_VECHAIN_ANCHOR_AGE = 6 hours;
    /// @dev Sui's committees hold 10,000 units of voting power in all.
    uint256 private constant SUI_TOTAL_POWER = 1e4;

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
    /// @notice `name` is not the Cosmos chain id of the Injective network the registry id names.
    error WrongCosmosChain(string name);
    /// @notice The Sui anchor's committee is malformed: the lengths disagree, a key is not the uncompressed form of its
    ///         compressed one, the compressed keys do not ascend, or the powers do not total 10,000.
    error BadCommittee(uint256 index);
    /// @notice The VeChain anchor's block id names block zero, which no table is read at.
    error BadBlockId(bytes32 id);
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
        if (ScriptUtils.same(chain, "sui")) return address(_deploySuiFrom(json));
        if (ScriptUtils.same(chain, "injective")) {
            return address(
                deployInjective(
                    ISP1Verifier(vm.envAddress("STATE_SP1_VERIFIER")),
                    vm.parseJsonBytes32(json, ".programKey"),
                    vm.parseJsonUint(json, ".chainId"),
                    vm.parseJsonString(json, ".cosmosChainId"),
                    vm.parseJsonAddress(json, ".vault"),
                    SafeCast.toUint64(vm.parseJsonUint(json, ".height")),
                    vm.parseJsonBytes32(json, ".hash"),
                    SafeCast.toUint64(vm.parseJsonUint(json, ".time"))
                )
            );
        }
        if (ScriptUtils.same(chain, "vechain")) {
            return address(
                deployVeChain(
                    ISP1Verifier(vm.envAddress("STATE_SP1_VERIFIER")),
                    vm.parseJsonBytes32(json, ".programKey"),
                    // The genesis id, a 32-byte hex string.
                    uint256(vm.parseJsonBytes32(json, ".chainId")),
                    vm.parseJsonAddress(json, ".vault"),
                    vm.parseJsonAddress(json, ".attester"),
                    vm.parseJsonBytes32(json, ".id"),
                    SafeCast.toUint64(vm.parseJsonUint(json, ".time")),
                    vm.parseJsonBytes32(json, ".table")
                )
            );
        }
        revert UnknownChain(chain);
    }

    /// @dev Sui's anchor, read from its file: the generator writes the chain id as a decimal string, since it passes
    ///      2^63.
    function _deploySuiFrom(string memory json) private returns (SuiStateVerifier) {
        uint256[] memory read = vm.parseJsonUintArray(json, ".powers");
        uint64[] memory powers = new uint64[](read.length);
        for (uint256 i = 0; i < read.length; ++i) {
            powers[i] = SafeCast.toUint64(read[i]);
        }
        return deploySui(
            vm.parseUint(vm.parseJsonString(json, ".chainId")),
            vm.parseJsonBytes32(json, ".vaultId"),
            vm.parseJsonBytes32(json, ".packageId"),
            SafeCast.toUint64(vm.parseJsonUint(json, ".epoch")),
            vm.parseJsonBytes(json, ".keys"),
            vm.parseJsonBytesArray(json, ".compressed"),
            powers,
            SafeCast.toUint64(vm.parseJsonUint(json, ".startMs"))
        );
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

    /// @notice Deploys Sui's verifier for the vault `vaultId` of package `packageId`, from epoch `epoch`, its committee
    ///         (`keys` uncompressed and packed, `compressed` as the end-of-epoch checkpoint names them, `powers`) and its
    ///         start `startMs`, the time of the checkpoint that named it (`test/fixtures/sui/generate.py anchor`). It
    ///         checks the network the registry id names against this one, the anchor's age (begun within
    ///         MAX_SUI_ANCHOR_AGE, never in the future), and the committee as `Committee::new` requires it: each key the
    ///         uncompressed form of its compressed one, the compressed keys strictly ascending, 10,000 units in all.
    function deploySui(
        uint256 chainId,
        bytes32 vaultId,
        bytes32 packageId,
        uint64 epoch,
        bytes memory keys,
        bytes[] memory compressed,
        uint64[] memory powers,
        uint64 startMs
    ) public returns (SuiStateVerifier verifier) {
        _requireEthereum();
        if (chainId != (block.chainid == SEPOLIA ? SUI_TESTNET : SUI_MAINNET)) revert WrongNetwork(chainId);
        uint256 start = uint256(startMs) / MS;
        if (start > block.timestamp || block.timestamp - start > MAX_SUI_ANCHOR_AGE) {
            revert StaleAnchor(start, block.timestamp);
        }
        _checkSuiCommittee(keys, compressed, powers);
        bytes32 committee = keccak256(abi.encode(keys, powers));
        vm.startBroadcast();
        verifier = new SuiStateVerifier(chainId, vaultId, packageId, epoch, committee, startMs);
        vm.stopBroadcast();
        checkSui(address(verifier), epoch, committee, startMs);
        console2.log("SuiStateVerifier:", address(verifier));
        console2.log("  epoch:           ", uint256(epoch));
        console2.log("  committee hash:  ", vm.toString(committee));
        console2.log("  update before:   ", start + verifier.MAX_LAG());
    }

    function _checkSuiCommittee(bytes memory keys, bytes[] memory compressed, uint64[] memory powers) private pure {
        uint256 count = powers.length;
        if (count == 0 || compressed.length != count || keys.length != count * Bls12381MinSig.G2_POINT) {
            revert BadCommittee(count);
        }
        uint256 total = 0;
        for (uint256 i = 0; i < count; ++i) {
            (bytes32 w0, bytes32 w1, bytes32 w2) = Bls12381MinSig.compressKey(keys, i);
            if (keccak256(abi.encodePacked(w0, w1, w2)) != keccak256(compressed[i])) revert BadCommittee(i);
            if (i != 0 && !ScriptUtils.above(compressed[i], compressed[i - 1])) revert BadCommittee(i);
            total += powers[i];
        }
        if (total != SUI_TOTAL_POWER) revert BadCommittee(count);
    }

    /// @notice Deploys Injective's verifier for `vault`, from header `height` (`hash`, dated `time`), read off the
    ///         chain by `proofs/cometbft/fixtures/generate.py anchor`. It checks SP1's verifier, the network both ids
    ///         name against this one, and the anchor's age (within MAX_ANCHOR_AGE, never in the future), then reads the
    ///         anchor back.
    function deployInjective(
        ISP1Verifier sp1,
        bytes32 programKey,
        uint256 chainId,
        string memory cosmosChainId,
        address vault,
        uint64 height,
        bytes32 hash,
        uint64 time
    ) public returns (CometBftStateVerifier verifier) {
        _requireEthereum();
        bool testnet = block.chainid == SEPOLIA;
        if (chainId != (testnet ? INJECTIVE_TESTNET : INJECTIVE_MAINNET)) revert WrongNetwork(chainId);
        if (!ScriptUtils.same(cosmosChainId, testnet ? "injective-888" : "injective-1")) {
            revert WrongCosmosChain(cosmosChainId);
        }
        if (!ScriptUtils.isSp1Verifier(address(sp1))) revert NotSp1Verifier(address(sp1));
        if (time > block.timestamp || block.timestamp - time > MAX_ANCHOR_AGE) {
            revert StaleAnchor(time, block.timestamp);
        }
        vm.startBroadcast();
        verifier = new CometBftStateVerifier(sp1, programKey, chainId, cosmosChainId, vault, height, hash, time);
        vm.stopBroadcast();
        checkInjective(address(verifier), height, hash, time);
        console2.log("CometBftStateVerifier:", address(verifier));
        console2.log("  update before:      ", uint256(time) + verifier.MAX_LAG());
    }

    /// @notice Deploys VeChain's verifier for `vault`, its weights attested by `attester`, from the staker table
    ///         `table` read at the finalized block `id`, dated `time` (`proofs/vechain/fixtures/generate.py anchor`,
    ///         after the vault and the attester are deployed: the verifier proves only later blocks). It checks SP1's
    ///         verifier, the network the genesis id names against this one, the block, and the anchor's age (within
    ///         MAX_VECHAIN_ANCHOR_AGE, never in the future), then reads the anchor back.
    function deployVeChain(
        ISP1Verifier sp1,
        bytes32 programKey,
        uint256 chainId,
        address vault,
        address attester,
        bytes32 id,
        uint64 time,
        bytes32 table
    ) public returns (VeChainStateVerifier verifier) {
        _requireEthereum();
        if (chainId != (block.chainid == SEPOLIA ? VECHAIN_TESTNET : VECHAIN_MAINNET)) revert WrongNetwork(chainId);
        if (!ScriptUtils.isSp1Verifier(address(sp1))) revert NotSp1Verifier(address(sp1));
        // A VeChain block id begins with the block's number.
        if (uint256(id) >> 224 == 0) revert BadBlockId(id);
        if (time > block.timestamp || block.timestamp - time > MAX_VECHAIN_ANCHOR_AGE) {
            revert StaleAnchor(time, block.timestamp);
        }
        vm.startBroadcast();
        verifier = new VeChainStateVerifier(sp1, programKey, chainId, vault, attester, id, time, table);
        vm.stopBroadcast();
        checkVeChain(address(verifier), id, time, table);
        console2.log("VeChainStateVerifier:", address(verifier));
        console2.log("  update before:     ", uint256(time) + verifier.MAX_LAG());
    }

    /// @notice The review of a deployed Sui verifier: it follows from epoch `epoch`, begun at `startMs`, with the
    ///         committee whose hash is `committee`. The reviewer compares the anchor file with Sui's own record of that
    ///         epoch (its committee and the checkpoint that named it). A codehash cannot be compared: the verifier's
    ///         immutables are in its code.
    function checkSui(address verifier, uint64 epoch, bytes32 committee, uint64 startMs) public view {
        SuiStateVerifier v = SuiStateVerifier(verifier);
        if (v.epoch() != epoch || v.committeeHash() != committee || v.epochStartMs() != startMs) {
            revert WrongAnchor(verifier);
        }
    }

    /// @notice The review of a deployed Injective verifier: its latest trusted header is `height`, `hash`, dated
    ///         `time`. The reviewer compares those with Injective's own `/commit?height=` (the block id's hash, the time's
    ///         whole seconds).
    function checkInjective(address verifier, uint64 height, bytes32 hash, uint64 time) public view {
        CometBftStateVerifier v = CometBftStateVerifier(verifier);
        ICometBftStateVerifier.Trusted memory t = v.trusted(hash);
        if (v.latestHash() != hash || t.height != height || t.time != time) revert WrongAnchor(verifier);
    }

    /// @notice The review of a deployed VeChain verifier: its latest trusted table is `table`, read at block `id`,
    ///         dated `time`. The reviewer recomputes the table at that block with `generate.py anchor`, and checks that
    ///         the vault's and the attester's masters read zero.
    function checkVeChain(address verifier, bytes32 id, uint64 time, bytes32 table) public view {
        VeChainStateVerifier v = VeChainStateVerifier(verifier);
        IVeChainStateVerifier.Trusted memory t = v.trusted(id);
        if (v.latestId() != id || t.table != table || t.time != time) revert WrongAnchor(verifier);
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
