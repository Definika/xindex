// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {XindexVault} from "../src/vault/XindexVault.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";
import {EthereumFinalityVerifier} from "../src/verifiers/EthereumFinalityVerifier.sol";
import {RiscZeroFinalityVerifier} from "../src/verifiers/RiscZeroFinalityVerifier.sol";
import {EthereumStateReader} from "../src/verifiers/EthereumStateReader.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {IRiscZeroVerifier} from "../src/interfaces/IRiscZeroVerifier.sol";
import {ISP1Groth16Identity} from "./interfaces/ISP1Groth16Identity.sol";
import {IRiscZeroGroth16Identity} from "./interfaces/IRiscZeroGroth16Identity.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice Deploys Xindex on an EVM vault chain whose state Ethereum can verify (today BNB Chain; Stage B spec,
///         section 8): P1's verifier on SP1's Groth16 verifier, P2's on RISC Zero's, the state reader the snapshot exit
///         reads Ethereum with, and the vault, its `VaultSnapshot` library linked by forge. Nothing here is owned, and
///         nothing can be changed afterwards but by the vault's own proven messages.
///
///   VAULT_FACTORY=... VAULT_HUB_TEMPLATE=... VAULT_SP1_VERIFIER=... VAULT_RISC_ZERO_VERIFIER=... \
///   VAULT_P1_KEY=... VAULT_P2_IMAGE_ID=... VAULT_ANCHOR=... VAULT_ANCHOR_EPOCH=... \
///   VAULT_FREEZER=... VAULT_RECOVERY=... VAULT_NATIVE_CAP=... VAULT_NATIVE_FLOOR=... \
///   forge script script/DeployVault.s.sol --rpc-url <vault chain> --account deployer --sender <address> --broadcast --verify
///
/// Env:
///   VAULT_SOURCE_CHAIN_ID     The chain the indexes live on: 1, Ethereum mainnet, the default, or Sepolia; never
///                             this chain. It fixes the genesis time P1 and P2 date epochs from.
///   VAULT_FACTORY             The HybridIndexFactory on that chain, whose clones the vault serves.
///   VAULT_HUB_TEMPLATE        That factory's HYBRID_IMPLEMENTATION, which `registerIndex` computes clones from.
///   VAULT_SP1_VERIFIER        SP1's Groth16 verifier v6.0.0 on this chain: a bare verifier, never SP1's gateway.
///   VAULT_RISC_ZERO_VERIFIER  RISC Zero's Groth16 verifier 3.0.0 on this chain: a bare verifier, never RISC Zero's
///                             router or its emergency-stop wrapper, which have owners.
///   VAULT_P1_KEY              P1's program key (`p1 vkey`, proofs/README.md).
///   VAULT_P2_IMAGE_ID         P2's image id (`p2 image-id`), from a reproducible build.
///   VAULT_ANCHOR, VAULT_ANCHOR_EPOCH  The finalized checkpoint P1 and P2 start from (`p1-input check-state`), the
///                             same for both, checked during the chain's listing delay. Each verifier stops for good
///                             a day after its anchor's epoch, so both must be advanced daily from deployment on.
///   VAULT_FREEZER             The guardian's freeze address on this chain: it can only freeze.
///   VAULT_RECOVERY            The owner's emergency multisig on this chain, which proposes a successor pair after
///                             a stall: a contract.
///   VAULT_NATIVE_CAP, VAULT_NATIVE_FLOOR  The native coin's quantity cap and speed-limit floor, in its smallest unit.
contract DeployVault is Script {
    /// @notice SP1's Groth16 verifier v6.0.0 names itself by this hash, the circuit its proofs come from.
    bytes32 public constant SP1_VERIFIER_HASH = 0x0e78f4db7a6771a3a6a7d9c3b0de6fe73d58781368967a7fe84d87aefffec896;
    string public constant SP1_VERSION = "v6.0.0";
    /// @notice RISC Zero's Groth16 verifier 3.0.0, deployed with its published control ids, names itself by this
    ///         selector (risc0-ethereum's deployment.toml at v3.0.1).
    bytes4 public constant RISC_ZERO_SELECTOR = 0x73c457ba;
    string public constant RISC_ZERO_VERSION = "3.0.0";
    /// @notice The beacon chain's genesis time on Ethereum mainnet and on Sepolia, which date P1's and P2's epochs.
    uint256 public constant MAINNET_GENESIS_TIME = 1_606_824_023;
    uint256 public constant SEPOLIA_GENESIS_TIME = 1_655_733_600;
    uint256 private constant SEPOLIA = 11_155_111;
    /// @notice `FinalityVerifier.MAX_LAG`: how long after its epoch began P1 and P2 still advance from an anchor.
    uint256 public constant VERIFIER_MAX_LAG = 1 days;
    /// @dev An epoch's 32 slots of 12 seconds.
    uint256 private constant EPOCH_SECONDS = 384;

    struct Params {
        uint256 sourceChainId;
        address factory;
        address hubImplementation;
        address sp1Verifier;
        address riscZeroVerifier;
        bytes32 p1ProgramKey;
        bytes32 p2ImageId;
        bytes32 anchor;
        uint64 anchorEpoch;
        address freezer;
        address recoveryProposer;
        uint256 nativeCap;
        uint256 nativeFloor;
    }

    struct Deployment {
        XindexVault vault;
        EthereumFinalityVerifier p1;
        RiscZeroFinalityVerifier p2;
        EthereumStateReader stateReader;
    }

    /// @notice This is the indexes' own chain: a vault serves another one.
    error SourceChain(uint256 chainId);
    /// @notice The variable `name` is zero.
    error Required(string name);
    /// @notice `verifier` is not the Groth16 verifier `name` must be.
    error WrongVerifier(string name, address verifier);
    /// @notice The recovery proposer has no code, or is an EIP-7702 delegated key: it must be a multisig.
    error RecoveryMustBeContract(address recovery);
    /// @notice A role is the key broadcasting the deployment.
    error RoleIsBroadcaster(string name, address account);
    /// @notice The freezer and the recovery proposer are one account.
    error SameRole(address account);
    /// @notice The floor lets more out at once than the cap lets in.
    error FloorAboveCap(uint256 floor, uint256 cap);
    /// @notice `name` points at `actual` instead of `expected`, so these contracts are not one deployment.
    error WrongWiring(string name, address expected, address actual);
    /// @notice The indexes' chain is neither Ethereum mainnet nor Sepolia, whose genesis times the script knows.
    error UnknownSource(uint256 chainId);
    /// @notice P1 and P2 could never advance from this anchor: its epoch began more than their MAX_LAG ago.
    error AnchorTooOld(uint64 epoch, uint256 lagEnded);

    /// @notice Reads the parameters from the environment and calls {deploy}.
    function run() external returns (Deployment memory) {
        return deploy(
            Params({
                sourceChainId: vm.envOr("VAULT_SOURCE_CHAIN_ID", uint256(1)),
                factory: vm.envAddress("VAULT_FACTORY"),
                hubImplementation: vm.envAddress("VAULT_HUB_TEMPLATE"),
                sp1Verifier: vm.envAddress("VAULT_SP1_VERIFIER"),
                riscZeroVerifier: vm.envAddress("VAULT_RISC_ZERO_VERIFIER"),
                p1ProgramKey: vm.envBytes32("VAULT_P1_KEY"),
                p2ImageId: vm.envBytes32("VAULT_P2_IMAGE_ID"),
                anchor: vm.envBytes32("VAULT_ANCHOR"),
                anchorEpoch: SafeCast.toUint64(vm.envUint("VAULT_ANCHOR_EPOCH")),
                freezer: vm.envAddress("VAULT_FREEZER"),
                recoveryProposer: vm.envAddress("VAULT_RECOVERY"),
                nativeCap: vm.envUint("VAULT_NATIVE_CAP"),
                nativeFloor: vm.envUint("VAULT_NATIVE_FLOOR")
            })
        );
    }

    /// @notice Checks every parameter, then broadcasts P1's and P2's verifiers, the state reader and the vault, and
    ///         logs their addresses and the code hashes the release record keeps.
    /// @param p The deployment's parameters; see {check}.
    /// @return d What was deployed.
    function deploy(Params memory p) public returns (Deployment memory d) {
        check(p);
        vm.startBroadcast();
        uint256 genesis = genesisTime(p.sourceChainId);
        d.p1 =
            new EthereumFinalityVerifier(ISP1Verifier(p.sp1Verifier), p.p1ProgramKey, p.anchor, p.anchorEpoch, genesis);
        d.p2 = new RiscZeroFinalityVerifier(
            IRiscZeroVerifier(p.riscZeroVerifier), p.p2ImageId, p.anchor, p.anchorEpoch, genesis
        );
        d.stateReader = new EthereumStateReader();
        d.vault = new XindexVault(
            IXindexVault.Config({
                sourceChainId: p.sourceChainId,
                factory: p.factory,
                hubImplementation: p.hubImplementation,
                verifier1: d.p1,
                verifier2: d.p2,
                freezer: p.freezer,
                recoveryProposer: p.recoveryProposer,
                stateReader: d.stateReader,
                nativeCap: p.nativeCap,
                nativeFloor: p.nativeFloor
            })
        );
        vm.stopBroadcast();

        console2.log("XindexVault:             ", address(d.vault));
        console2.log("P1 (SP1):                ", address(d.p1));
        console2.log("P2 (RISC Zero):          ", address(d.p2));
        console2.log("EthereumStateReader:     ", address(d.stateReader));
        bytes32[4] memory codehashes = checkDeployment(d, p);
        console2.log("XindexVault hash:        ", vm.toString(codehashes[0]));
        console2.log("P1 hash:                 ", vm.toString(codehashes[1]));
        console2.log("P2 hash:                 ", vm.toString(codehashes[2]));
        console2.log("EthereumStateReader hash:", vm.toString(codehashes[3]));
    }

    /// @notice Refuses a deployment on the indexes' own chain, a missing address or key, an anchor P1 and P2 could no
    ///         longer advance from, a verifier that is not the pinned SP1 or RISC Zero one, and roles that are not what
    ///         the vault assumes.
    function check(Params memory p) public view {
        if (block.chainid == p.sourceChainId) revert SourceChain(block.chainid);
        if (p.factory == address(0)) revert Required("VAULT_FACTORY");
        if (p.hubImplementation == address(0)) revert Required("VAULT_HUB_TEMPLATE");
        if (p.p1ProgramKey == bytes32(0)) revert Required("VAULT_P1_KEY");
        if (p.p2ImageId == bytes32(0)) revert Required("VAULT_P2_IMAGE_ID");
        if (p.anchor == bytes32(0)) revert Required("VAULT_ANCHOR");
        uint256 lagEnds = genesisTime(p.sourceChainId) + uint256(p.anchorEpoch) * EPOCH_SECONDS + VERIFIER_MAX_LAG;
        if (block.timestamp > lagEnds) revert AnchorTooOld(p.anchorEpoch, lagEnds);
        checkVerifiers(p.sp1Verifier, p.riscZeroVerifier);
        checkRoles(p.freezer, p.recoveryProposer);
        if (p.nativeFloor > p.nativeCap) revert FloorAboveCap(p.nativeFloor, p.nativeCap);
    }

    /// @notice The beacon genesis time of the indexes' chain, which P1 and P2 date their anchor's epoch from.
    function genesisTime(uint256 sourceChainId) public pure returns (uint256) {
        if (sourceChainId == 1) return MAINNET_GENESIS_TIME;
        if (sourceChainId == SEPOLIA) return SEPOLIA_GENESIS_TIME;
        revert UnknownSource(sourceChainId);
    }

    /// @notice Requires P1's Groth16 verifier to name itself SP1's v6.0.0 and P2's RISC Zero's 3.0.0 with its published
    ///         control ids. An owned gateway, router or emergency stop answers neither, so it is refused too.
    function checkVerifiers(address sp1, address riscZero) public view {
        if (
            !_answers(sp1, abi.encodeCall(ISP1Groth16Identity.VERIFIER_HASH, ()), abi.encode(SP1_VERIFIER_HASH))
                || !_answers(sp1, abi.encodeCall(ISP1Groth16Identity.VERSION, ()), abi.encode(SP1_VERSION))
        ) revert WrongVerifier("VAULT_SP1_VERIFIER", sp1);
        if (
            !_answers(riscZero, abi.encodeCall(IRiscZeroGroth16Identity.SELECTOR, ()), abi.encode(RISC_ZERO_SELECTOR))
                || !_answers(
                    riscZero, abi.encodeCall(IRiscZeroGroth16Identity.VERSION, ()), abi.encode(RISC_ZERO_VERSION)
                )
        ) revert WrongVerifier("VAULT_RISC_ZERO_VERIFIER", riscZero);
    }

    /// @dev Whether `target` answers `query` with exactly `expected`. A static call, compared byte for byte, so a
    ///      missing function, a fallback or a short answer is a no rather than a revert.
    function _answers(address target, bytes memory query, bytes memory expected) private view returns (bool) {
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory answer) = target.staticcall(query);
        return ok && keccak256(answer) == keccak256(expected);
    }

    /// @notice Requires a freezer and a recovery proposer that are set, distinct, not the broadcasting key, and a
    ///         recovery proposer that is a contract: the owner's multisig on this chain, not a key.
    function checkRoles(address freezer, address recovery) public view {
        if (freezer == address(0)) revert Required("VAULT_FREEZER");
        if (recovery == address(0)) revert Required("VAULT_RECOVERY");
        if (freezer == recovery) revert SameRole(freezer);
        if (freezer == msg.sender) revert RoleIsBroadcaster("VAULT_FREEZER", freezer);
        if (recovery == msg.sender) revert RoleIsBroadcaster("VAULT_RECOVERY", recovery);
        bytes memory code = recovery.code;
        if (code.length == 0 || ScriptUtils.isDelegatedAccount(code)) revert RecoveryMustBeContract(recovery);
    }

    /// @notice Checks that `d` is one deployment made with `p` and returns the runtime code hashes for the release
    ///         record: the vault's, P1's, P2's and the state reader's. Run it again later against the recorded
    ///         addresses: equal hashes prove the code is unchanged.
    function checkDeployment(Deployment memory d, Params memory p) public view returns (bytes32[4] memory codehashes) {
        XindexVault v = d.vault;
        _same("p1", address(d.p1), address(v.p1()));
        _same("p2", address(d.p2), address(v.p2()));
        _same("STATE_READER", address(d.stateReader), address(v.STATE_READER()));
        _same("FACTORY", p.factory, v.FACTORY());
        _same("HUB_IMPLEMENTATION", p.hubImplementation, v.HUB_IMPLEMENTATION());
        _same("RECOVERY_PROPOSER", p.recoveryProposer, v.RECOVERY_PROPOSER());
        _same("SP1_VERIFIER", p.sp1Verifier, address(d.p1.SP1_VERIFIER()));
        _same("RISC_ZERO_VERIFIER", p.riscZeroVerifier, address(d.p2.RISC_ZERO_VERIFIER()));
        codehashes =
            [address(v).codehash, address(d.p1).codehash, address(d.p2).codehash, address(d.stateReader).codehash];
    }

    function _same(string memory name, address expected, address actual) private pure {
        if (expected != actual) revert WrongWiring(name, expected, actual);
    }
}
