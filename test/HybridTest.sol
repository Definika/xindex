// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {HybridIndexFactory} from "../src/HybridIndexFactory.sol";
import {HybridHub} from "../src/HybridHub.sol";
import {IHybridHubTypes} from "../src/interfaces/IHybridHubTypes.sol";
import {IHybridIndex} from "../src/interfaces/IHybridIndex.sol";
import {HybridHubExtension} from "../src/hybrid/HybridHubExtension.sol";
import {HybridHubModule} from "../src/hybrid/HybridHubModule.sol";
import {XindexVault} from "../src/vault/XindexVault.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockEventVerifier} from "./mocks/MockEventVerifier.sol";
import {MockStateReader} from "./mocks/MockStateReader.sol";
import {IEthereumEventVerifier} from "../src/interfaces/IEthereumEventVerifier.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";
import {MockStateVerifier} from "./mocks/MockStateVerifier.sol";

/// @notice Stage B on one EVM: a factory with a HybridHub template, a real vault standing for another chain (the test
///         chain's own id), a mock state verifier that reads the vault's real storage, and a helper that delivers the
///         hub's messages to the vault as P1 and P2 would.
abstract contract HybridTest is Test {
    HybridIndexFactory factory;
    HybridHub template;
    HybridHubExtension extension;
    HybridHubModule module;
    XindexVault vault;
    MockStateVerifier stateVerifier;
    MockStateReader stateReader;
    address recoveryProposer = makeAddr("recovery proposer");
    MockEventVerifier p1;
    MockEventVerifier p2;
    MockERC20 weth;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address freezer = makeAddr("freezer");
    address minter = makeAddr("minter");
    address holder = makeAddr("holder");
    uint256 chainId;
    address native; // the vault chain's native coin, as the factory lists it

    uint256 constant ETH_SUPPLY = 120_000_000e18;
    uint256 constant BNB_SUPPLY = 140_000_000e18;
    /// @dev 1.2 WETH and 1.4 BNB per whole index token.
    uint256 constant K = 1e28;

    function _deployStageB() internal {
        vm.warp(1_700_000_000);
        chainId = block.chainid;
        // The extension, the module, then the template, then the factory all three are built for.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        extension = new HybridHubExtension(predicted);
        module = new HybridHubModule(predicted, address(extension));
        template = new HybridHub(predicted, address(module));
        factory = new HybridIndexFactory(owner, guardian, address(template));
        p1 = new MockEventVerifier();
        p2 = new MockEventVerifier();
        stateReader = new MockStateReader();
        vault = _newVault();
        stateVerifier = new MockStateVerifier();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        vm.startPrank(owner);
        factory.proposeChain(chainId, _b32(address(vault)), address(stateVerifier));
        factory.proposeListing(address(weth), ETH_SUPPLY);
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeChain(chainId);
        factory.executeListing(address(weth));
        vm.prank(owner);
        factory.proposeVaultListing(chainId, bytes32(0), BNB_SUPPLY);
        native = factory.vaultTokenId(chainId, bytes32(0));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(native);
    }

    /// @dev A vault for this chain, with the test's verifiers, freezer and a state reader of live storage.
    function _newVault() internal returns (XindexVault) {
        return new XindexVault(
            IXindexVault.Config({
                sourceChainId: chainId,
                factory: address(factory),
                hubImplementation: address(template),
                verifier1: p1,
                verifier2: p2,
                freezer: freezer,
                recoveryProposer: recoveryProposer,
                stateReader: stateReader,
                nativeCap: 1e30,
                nativeFloor: 1e30
            })
        );
    }

    /// @dev Keeps `v` out of a stall, as keepers do: a checkpoint at the current time that both verifiers prove.
    function _fresh(XindexVault v) internal {
        IEthereumEventVerifier.Checkpoint memory c = v.checkpoint();
        if (c.timestamp >= block.timestamp) return;
        bytes memory proof = abi.encode(
            IEthereumEventVerifier.Checkpoint({
                blockNumber: c.blockNumber + 1,
                timestamp: uint64(block.timestamp),
                stateRoot: keccak256(abi.encode("state root", block.timestamp))
            })
        );
        v.advanceCheckpoint(proof, proof);
    }

    function _fresh() internal {
        _fresh(vault);
    }

    function _createHybrid() internal returns (IHybridIndex hub) {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(weth), native);
        // Its creator seeds it: only the creator may mint into an empty index.
        vm.prank(minter);
        hub = IHybridIndex(factory.createIndex("Hybrid", "HYB", tokens, K));
        vault.registerIndex(address(hub), factory.indexSalt(address(hub)));
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev A state proof claiming a block at `time`, reading the vault's real storage.
    function _honest(uint256 time) internal pure returns (bytes memory) {
        return abi.encode(time, false, bytes32(0));
    }

    /// @dev A state proof claiming a block at `time` that reports `value` at the slot it is asked for, whatever the
    ///      vault holds there; a second slot, the snapshot root an evidence proof also reads, comes as the vault holds it.
    function _forged(uint256 time, bytes32 value) internal pure returns (bytes memory) {
        return abi.encode(time, true, value);
    }

    function _chainProof(uint256 time, uint256 deposited)
        internal
        pure
        returns (IHybridHubTypes.ChainProof[] memory p)
    {
        p = new IHybridHubTypes.ChainProof[](1);
        p[0].proof = _honest(time);
        p[0].tokens = new address[](1);
        p[0].totals = new uint256[](1);
        p[0].totals[0] = deposited;
    }

    /// @dev Opens an order of `shares` for `who`, funds and deposits it in full, and settles it after its deadline.
    function _settledOrder(IHybridIndex hub, address who, uint256 shares) internal returns (uint256 orderId) {
        uint256[] memory amounts = hub.previewOrder(shares);
        weth.mint(who, amounts[0]);
        vm.startPrank(who);
        weth.approve(address(hub), amounts[0]);
        uint256 intakeId;
        (orderId, intakeId) = hub.openOrder(shares, block.timestamp + 1 hours);
        vm.deal(who, amounts[1]);
        _fresh();
        vault.deposit{value: amounts[1]}(address(hub), intakeId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours + 1);
        hub.settleOrder(orderId, _chainProof(block.timestamp, amounts[1]));
    }

    /// @dev A whole mint: settled, locked, claimed, and its settle message delivered to the vault.
    function _mint(IHybridIndex hub, address who, uint256 shares) internal returns (uint256 orderId) {
        orderId = _settledOrder(hub, who, shares);
        vm.warp(block.timestamp + hub.MINT_LOCK());
        vm.recordLogs();
        hub.claimOrder(orderId);
        _deliverAll(vm.getRecordedLogs());
    }

    /// @dev Delivers every VaultMessage in `logs` to the vault, with both proofs.
    function _deliverAll(Vm.Log[] memory logs) internal returns (uint256 delivered) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != VaultMessages.EVENT_TOPIC) continue;
            bytes memory proof = abi.encode(logs[i].emitter, logs[i].topics[0], logs[i].topics[1], logs[i].data);
            vault.deliver(proof, proof);
            ++delivered;
        }
    }

    /// @dev Applies a governance change `_deliverAll` just delivered to `vault`, once the vault's own delay has passed.
    function _applyChange(uint8 kind, bytes memory body) internal {
        uint256 readyAt = block.timestamp + vault.GOVERNANCE_DELAY();
        vm.warp(readyAt);
        vault.applyChange(kind, body, readyAt);
    }

    /// @dev The id and payload of the first VaultMessage in `logs`; zero and empty if there is none.
    function _sent(Vm.Log[] memory logs) internal pure returns (bytes32 id, bytes memory payload) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != VaultMessages.EVENT_TOPIC) continue;
            return (logs[i].topics[1], abi.decode(logs[i].data, (bytes)));
        }
    }

    /// @dev The first VaultMessage in `logs`, decoded; an empty message, of kind zero, if there is none.
    function _message(Vm.Log[] memory logs) internal pure returns (VaultMessages.Message memory m) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != VaultMessages.EVENT_TOPIC) continue;
            return VaultMessages.decode(abi.decode(logs[i].data, (bytes)));
        }
    }
}
