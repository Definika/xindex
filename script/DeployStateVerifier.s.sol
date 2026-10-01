// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BnbStateVerifier} from "../src/verifiers/BnbStateVerifier.sol";
import {TronStateVerifier} from "../src/verifiers/TronStateVerifier.sol";
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
///   TRON's is the same with `tron` and `test/fixtures/tron/generate.py <TronGrid URL> anchor`. The chain is then
///   added with `ConfigureChains`, naming the verifier. Forge simulates the whole run first, so a check that fails
///   broadcasts nothing.
///
/// Env:
///   STATE_CHAIN   `bnb` or `tron`.
///   STATE_ANCHOR  The anchor file the generator wrote.
contract DeployStateVerifier is Script {
    /// @notice The oldest BNB Chain anchor deployed, which leaves the rest of MAX_LAG to advance the verifier.
    uint256 public constant MAX_ANCHOR_AGE = 1 hours;

    /// @dev TRON's times are in milliseconds.
    uint256 private constant MS = 1000;
    /// @dev TRON's maintenance interval, in milliseconds: the verifier's INTERVAL.
    uint256 private constant TRON_INTERVAL = 6 hours * MS;
    uint256 private constant SEPOLIA = 11_155_111;
    string private constant PRODUCER = "Producer(address witness,address key)";

    /// @notice A verifier of a chain's state belongs on Ethereum, beside the hub, and the BNB verifier needs Ethereum's
    ///         BLS12-381 precompiles: mainnet or Sepolia only.
    error NotEthereum(uint256 chainId);
    /// @notice STATE_CHAIN is neither `bnb` nor `tron`.
    error UnknownChain(string chain);
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
