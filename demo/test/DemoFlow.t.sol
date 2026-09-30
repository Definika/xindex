// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {HybridIndexFactory} from "xindex/HybridIndexFactory.sol";
import {HybridHub} from "xindex/HybridHub.sol";
import {HybridHubModule} from "xindex/hybrid/HybridHubModule.sol";
import {HybridHubExtension} from "xindex/hybrid/HybridHubExtension.sol";
import {IHybridIndex} from "xindex/interfaces/IHybridIndex.sol";
import {IHybridHubTypes} from "xindex/interfaces/IHybridHubTypes.sol";
import {IEthereumEventVerifier} from "xindex/interfaces/IEthereumEventVerifier.sol";
import {IXindexVault} from "xindex/interfaces/IXindexVault.sol";
import {XindexVault} from "xindex/vault/XindexVault.sol";
import {EthereumStateReader} from "xindex/verifiers/EthereumStateReader.sol";
import {VaultMessages} from "xindex/libraries/VaultMessages.sol";
import {StubEventVerifier} from "../src/StubEventVerifier.sol";
import {StubStateVerifier} from "../src/StubStateVerifier.sol";
import {DemoToken} from "../src/DemoToken.sol";

/// @notice The hackathon's flow on one EVM, with the real hub and vault and the stubs between them, signed as the relayer
///         signs: an index of WETH, a HyperEVM coin in a real vault, and a Solana coin whose vault state the relayer
///         reports as the Solana program computes it. Mint, settle, claim, deliver, redeem, pay.
contract DemoFlowTest is Test {
    uint256 constant SOLANA = 1_399_811_150;
    uint256 constant ETH_SUPPLY = 120_000_000e18;
    uint256 constant SOL_SUPPLY = 600_000_000e9;
    uint256 constant HYPE_SUPPLY = 334_000_000e18;
    /// @dev 0.001 WETH a share.
    uint256 constant K = 8_333_333_333_333_333_333_333_333;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    Vm.Wallet relayer1 = vm.createWallet("relayer 1");
    Vm.Wallet relayer2 = vm.createWallet("relayer 2");
    Vm.Wallet stateRelayer = vm.createWallet("state relayer");
    address minter = makeAddr("minter");

    HybridIndexFactory factory;
    HybridHub template;
    XindexVault vault;
    StubEventVerifier p1;
    StubEventVerifier p2;
    StubStateVerifier hyperState;
    StubStateVerifier solanaState;
    DemoToken weth;
    bytes32 solanaVault = keccak256("the Solana vault's config account");
    address hype;
    address sol;
    IHybridIndex index;

    function setUp() public {
        vm.warp(1_800_000_000);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        HybridHubExtension extension = new HybridHubExtension(predicted);
        HybridHubModule module = new HybridHubModule(predicted, address(extension));
        template = new HybridHub(predicted, address(module));
        factory = new HybridIndexFactory(owner, guardian, address(template));

        p1 = new StubEventVerifier(relayer1.addr);
        p2 = new StubEventVerifier(relayer2.addr);
        vault = new XindexVault(
            IXindexVault.Config({
                sourceChainId: block.chainid,
                factory: address(factory),
                hubImplementation: address(template),
                verifier1: p1,
                verifier2: p2,
                freezer: guardian,
                recoveryProposer: owner,
                stateReader: new EthereumStateReader(),
                nativeCap: 1e30,
                nativeFloor: 1e18
            })
        );
        hyperState = new StubStateVerifier(stateRelayer.addr, block.chainid);
        solanaState = new StubStateVerifier(stateRelayer.addr, SOLANA);
        weth = new DemoToken("Wrapped Ether", "WETH");

        vm.startPrank(owner);
        factory.proposeChain(block.chainid, bytes32(uint256(uint160(address(vault)))), address(hyperState));
        factory.proposeChain(SOLANA, solanaVault, address(solanaState));
        factory.proposeListing(address(weth), ETH_SUPPLY);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        factory.executeChain(block.chainid);
        factory.executeChain(SOLANA);
        factory.executeListing(address(weth));
        vm.startPrank(owner);
        factory.proposeVaultListing(block.chainid, bytes32(0), HYPE_SUPPLY);
        factory.proposeVaultListing(SOLANA, bytes32(0), SOL_SUPPLY);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        hype = factory.vaultTokenId(block.chainid, bytes32(0));
        sol = factory.vaultTokenId(SOLANA, bytes32(0));
        factory.executeListing(hype);
        factory.executeListing(sol);

        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(weth), hype, sol);
        // The sender who seeds it creates it: only an index's creator may mint into it empty.
        vm.prank(minter);
        index = IHybridIndex(factory.createIndex("Xindex Hybrid Demo", "XHD", tokens, K));
        vault.registerIndex(address(index), factory.indexSalt(address(index)));
        _checkpoint();
    }

    // ---------------------------------------------------------------------
    // what the relayer does
    // ---------------------------------------------------------------------

    function _sign(Vm.Wallet memory w, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w, MessageHashUtils.toEthSignedMessageHash(digest));
        return abi.encodePacked(r, s, v);
    }

    function _checkpoint() internal {
        IEthereumEventVerifier.Checkpoint memory c = IEthereumEventVerifier.Checkpoint({
            blockNumber: uint64(block.number + vault.checkpoint().blockNumber + 1),
            timestamp: uint64(block.timestamp),
            stateRoot: keccak256("state")
        });
        vault.advanceCheckpoint(
            abi.encode(c, _sign(relayer1, p1.checkpointDigest(c))),
            abi.encode(c, _sign(relayer2, p2.checkpointDigest(c)))
        );
    }

    /// @dev Delivers every VaultMessage in `logs` to the HyperEVM vault, signed by both relayers.
    function _relay(Vm.Log[] memory logs) internal returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics.length < 2 || l.topics[0] != VaultMessages.EVENT_TOPIC) continue;
            VaultMessages.Message memory m = VaultMessages.decode(abi.decode(l.data, (bytes)));
            if (m.destChainId != block.chainid) continue;
            vault.deliver(_eventProof(p1, relayer1, l), _eventProof(p2, relayer2, l));
            ++n;
        }
    }

    /// @dev A stub's "proof" of a log: the log and the relayer's signature over the stub's digest of it.
    function _eventProof(StubEventVerifier v, Vm.Wallet memory w, Vm.Log memory l) internal returns (bytes memory) {
        bytes32 digest = v.eventDigest(block.number, l.emitter, l.topics[0], l.topics[1], keccak256(l.data));
        return abi.encode(block.number, l.emitter, l.topics[0], l.topics[1], l.data, _sign(w, digest));
    }

    /// @dev The Solana program's intake digest (its `abi::intake_digest`): the vault's address is its key's low 20
    ///      bytes, as the hub's `_vaultAddress` keeps them.
    function _solanaIntakeDigest(uint256 intakeId, uint8 state, uint256 total) internal view returns (bytes32) {
        address[] memory tokens = new address[](1);
        uint256[] memory totals = new uint256[](1);
        totals[0] = total;
        return keccak256(
            abi.encode(
                keccak256("xindex.v4.vault.intake-digest"),
                SOLANA,
                address(uint160(uint256(solanaVault))),
                address(index),
                intakeId,
                state,
                tokens,
                totals
            )
        );
    }

    function _stateProof(StubStateVerifier v, address account, bytes32 slot, bytes32 value)
        internal
        returns (bytes memory)
    {
        bytes32[] memory slots = new bytes32[](1);
        bytes32[] memory values = new bytes32[](1);
        (slots[0], values[0]) = (slot, value);
        bytes32 digest = v.stateDigest(account, slots, values, block.number, block.timestamp);
        return abi.encode(block.number, block.timestamp, values, _sign(stateRelayer, digest));
    }

    /// @dev What the relayer reports for an order's intakes: the HyperEVM vault's digest read from its storage, and the
    ///      Solana program's, which the relayer reads from the intake account.
    function _settleProofs(uint256 intakeId, uint256[] memory amounts)
        internal
        returns (IHybridHubTypes.ChainProof[] memory proofs)
    {
        proofs = new IHybridHubTypes.ChainProof[](2);
        bytes32 slot = keccak256(abi.encode(intakeId, keccak256(abi.encode(address(index), uint256(15)))));
        proofs[0].proof = _stateProof(hyperState, address(vault), slot, vm.load(address(vault), slot));
        proofs[0].tokens = new address[](1);
        proofs[0].totals = new uint256[](1);
        proofs[0].totals[0] = amounts[1];
        address solanaAccount = address(uint160(uint256(solanaVault)));
        proofs[1].proof = _stateProof(solanaState, solanaAccount, slot, _solanaIntakeDigest(intakeId, 1, amounts[2]));
        proofs[1].tokens = new address[](1);
        proofs[1].totals = new uint256[](1);
        proofs[1].totals[0] = amounts[2];
    }

    // ---------------------------------------------------------------------
    // the flow
    // ---------------------------------------------------------------------

    function test_mintAndRedeemAcrossThreeChains() public {
        uint256[] memory amounts = index.previewOrder(100e18);
        assertApproxEqAbs(amounts[0], 0.1e18, 1e6, "0.001 WETH a share, less the units' rounding");
        weth.mint(minter, amounts[0]);
        vm.startPrank(minter);
        weth.approve(address(index), amounts[0]);
        (uint256 orderId, uint256 intakeId) = index.openOrder(100e18, block.timestamp + 1 hours);
        // The HyperEVM deposit, in the real vault.
        vm.deal(minter, amounts[1]);
        vault.deposit{value: amounts[1]}(address(index), intakeId);
        vm.stopPrank();
        // The Solana deposit happens on Solana; its intake digest there is what the relayer reports.
        vm.warp(block.timestamp + 1 hours + 1);

        index.settleOrder(orderId, _settleProofs(intakeId, amounts));

        vm.warp(block.timestamp + index.MINT_LOCK());
        vm.recordLogs();
        index.claimOrder(orderId);
        assertEq(index.balanceOf(minter), 100e18);
        assertEq(_relay(vm.getRecordedLogs()), 1, "the HyperEVM vault's settle message");
        assertEq(vault.balance(address(index), address(0)), amounts[1]);

        // Redeem half: WETH at once, HYPE paid by the vault on the relayed burn, SOL burned toward a Solana key.
        bytes32[] memory recipients = new bytes32[](2);
        address hyperRecipient = makeAddr("hyperevm recipient");
        recipients[0] = bytes32(uint256(uint160(hyperRecipient)));
        recipients[1] = keccak256("a Solana public key");
        vm.recordLogs();
        vm.prank(minter);
        index.redeem(50e18, minter, recipients, 0);
        assertEq(weth.balanceOf(minter), amounts[0] / 2);
        assertEq(_relay(vm.getRecordedLogs()), 1, "the HyperEVM burn; the Solana one goes to Solana");
        assertEq(hyperRecipient.balance, amounts[1] / 2, "within the 1-coin floor");
    }

    // ---------------------------------------------------------------------
    // the stubs refuse anyone but their relayer
    // ---------------------------------------------------------------------

    function test_theStubsAcceptOnlyTheirRelayer() public {
        bytes memory data = abi.encode(bytes("payload"));
        bytes32 h = keccak256(data);
        bytes32 t = VaultMessages.EVENT_TOPIC;
        bytes memory byRelayer2 = _sign(relayer2, p1.eventDigest(1, address(this), t, bytes32(0), h));
        vm.expectRevert(abi.encodeWithSelector(StubEventVerifier.NotRelayer.selector, relayer2.addr));
        p1.verifyEvent(abi.encode(1, address(this), t, bytes32(0), data, byRelayer2));
        // P2's own signature over P1's digest is still P2's, and P1 refuses it; over its own digest P2 accepts.
        bytes memory forP2 = _sign(relayer2, p2.eventDigest(1, address(this), t, bytes32(0), h));
        vm.expectRevert();
        p1.verifyEvent(abi.encode(1, address(this), t, bytes32(0), data, forP2));
        (uint256 blockNumber, address emitter,,,) =
            p2.verifyEvent(abi.encode(1, address(this), t, bytes32(0), data, forP2));
        assertEq(blockNumber, 1);
        assertEq(emitter, address(this));

        IEthereumEventVerifier.Checkpoint memory c =
            IEthereumEventVerifier.Checkpoint({blockNumber: 7, timestamp: 8, stateRoot: bytes32(uint256(9))});
        bytes memory byRelayer2Checkpoint = abi.encode(c, _sign(relayer2, p1.checkpointDigest(c)));
        vm.expectRevert(abi.encodeWithSelector(StubEventVerifier.NotRelayer.selector, relayer2.addr));
        p1.verifyCheckpoint(byRelayer2Checkpoint);
        assertEq(p1.verifyCheckpoint(abi.encode(c, _sign(relayer1, p1.checkpointDigest(c)))).blockNumber, 7);

        bytes32[] memory slots = new bytes32[](1);
        bytes32[] memory values = new bytes32[](2);
        vm.expectRevert(StubStateVerifier.LengthMismatch.selector);
        solanaState.verifySlots(address(1), slots, abi.encode(1, 2, values, bytes("")));
        values = new bytes32[](1);
        bytes memory wrong = _sign(relayer1, solanaState.stateDigest(address(1), slots, values, 1, 2));
        vm.expectRevert(abi.encodeWithSelector(StubStateVerifier.NotRelayer.selector, relayer1.addr));
        solanaState.verifySlots(address(1), slots, abi.encode(1, 2, values, wrong));
        // The Solana verifier's signature is not the HyperEVM verifier's.
        bytes memory forSolana = _sign(stateRelayer, solanaState.stateDigest(address(1), slots, values, 1, 2));
        vm.expectRevert();
        hyperState.verifySlots(address(1), slots, abi.encode(1, 2, values, forSolana));
    }
}
