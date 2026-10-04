// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IXindexVault} from "../../src/interfaces/IXindexVault.sol";
import {IEthereumEventVerifier} from "../../src/interfaces/IEthereumEventVerifier.sol";
import {VaultMessages} from "../../src/libraries/VaultMessages.sol";
import {EthereumFinalityVerifier} from "../../src/verifiers/EthereumFinalityVerifier.sol";
import {ISP1Verifier} from "../../src/interfaces/ISP1Verifier.sol";
import {MockEventVerifier} from "../mocks/MockEventVerifier.sol";
import {MockSP1Verifier} from "../mocks/MockSP1Verifier.sol";
import {VaultTestBase} from "../XindexVault.t.sol";

/// @notice An honest proof system: it proves only logs that really are on Ethereum (registered with `publish`), and any
///         checkpoint (the PoCs only need its event side to be honest).
contract HonestEventVerifier is IEthereumEventVerifier {
    mapping(bytes32 => bool) public real;

    error NotOnEthereum();

    function publish(bytes calldata proof) external {
        real[keccak256(proof)] = true;
    }

    function verifyEvent(bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, address emitter, bytes32 topic0, bytes32 topic1, bytes memory data)
    {
        if (!real[keccak256(proof)]) revert NotOnEthereum();
        (emitter, topic0, topic1, data) = abi.decode(proof, (address, bytes32, bytes32, bytes));
        blockNumber = 0;
    }

    function verifyCheckpoint(bytes calldata proof) external pure returns (Checkpoint memory) {
        return abi.decode(proof, (Checkpoint));
    }
}

contract VaultRecoveryPoC is VaultTestBase {
    address index;
    address attacker = makeAddr("attacker");

    // The old pair's view of Ethereum: block n has timestamp T0 + (n - N0) * 12.
    uint256 constant N0 = 1_000;
    uint256 T0;

    function setUp() public {
        vm.warp(1_700_000_000);
        _deployVault();
        index = _registered(keccak256("index-1"));
        // The first checkpoint the keepers bring is a minute after deployment.
        T0 = block.timestamp + 60;
        vm.warp(T0 + 60);
    }

    function _cp(uint256 n) internal view returns (bytes memory) {
        return _checkpointProof(n, T0 + (n - N0) * 12, keccak256(abi.encode("root", n)));
    }

    function _continuity(uint256 recentBlock) internal view returns (IXindexVault.Continuity memory c) {
        bytes memory lastProof = abi.encode(vault.checkpoint());
        bytes memory recent = _checkpointProof(recentBlock, block.timestamp, keccak256(abi.encode(recentBlock)));
        c = IXindexVault.Continuity({
            last1: lastProof, last2: lastProof, recent1: recent, recent2: recent, message1: "", message2: ""
        });
    }

    /// @dev Keepers last advanced the vault to block N0. The old pair kept covering Ethereum for a while after that (a
    ///      day: 7,200 blocks), then stopped for good. Nobody advanced the vault to the end of that coverage.
    function _stallWithAGap() internal {
        vault.advanceCheckpoint(_cp(N0), _cp(N0));
        vm.warp(T0 + 8 days);
        assertTrue(vault.stalled());
    }

    /// FINDING 1a: a checkpoint newer than the last but still stale lapses a pending successor although the vault
    /// stays stalled: anyone can throw away the 30-day review, as often as the old pair's coverage has blocks.
    function test_poc_staleAdvanceLapsesTheSuccessorWhileStillStalled() public {
        _stallWithAGap();
        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        IXindexVault.Continuity memory c = _continuity(9_000_000);
        vm.prank(recoveryProposer);
        vault.proposeSuccessor(n1, n2, c);
        uint256 reviewEnds = vault.successor().reviewEnds;

        // One day before the review ends, a stranger advances by ONE block of the old pair's old coverage.
        vm.warp(reviewEnds - 1 days);
        vm.prank(attacker);
        vault.advanceCheckpoint(_cp(N0 + 1), _cp(N0 + 1));

        assertEq(vault.successor().reviewEnds, 0, "successor lapsed");
        assertTrue(vault.stalled(), "...yet the vault is still stalled: the old pair does not work");
        // The snapshot's due date moved by 12 seconds only.
        emit log_named_uint("stallStart moved by (s)", vault.stallStart() - (T0 + 7 days));
    }

    /// FINDING 1b: the same stale advance gives the freezer a fresh pair of vetoes in what is one and the same stall.
    function test_poc_staleAdvanceResetsTheVetoCount() public {
        _stallWithAGap();
        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        uint256 vetoesCast = 0;
        for (uint256 round = 0; round < 3; ++round) {
            for (uint256 i = 0; i < 2; ++i) {
                IXindexVault.Continuity memory c = _continuity(9_000_000 + round * 10 + i);
                vm.prank(recoveryProposer);
                vault.proposeSuccessor(n1, n2, c);
                vm.prank(freezerKey);
                vault.vetoSuccessor();
                ++vetoesCast;
            }
            // The freezer (or anyone) steps the checkpoint one stale block: a "new stall", a new count.
            vault.advanceCheckpoint(_cp(N0 + 1 + round), _cp(N0 + 1 + round));
            assertTrue(vault.stalled());
        }
        assertEq(vetoesCast, 6, "six vetoes in one stall; MAX_RECOVERY_VETOES is 2");
    }

    /// FINDING 1c: by lapsing every proposal shortly before its review ends, a stranger denies recovery until the
    /// snapshot exit, which is final.
    function test_poc_recoveryDeniedUntilTheSnapshot() public {
        _stallWithAGap();
        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        uint256 step = 1;
        while (block.timestamp < vault.stallStart() + vault.SNAPSHOT_EXIT_DELAY()) {
            IXindexVault.Continuity memory c = _continuity(9_000_000 + step);
            vm.prank(recoveryProposer);
            vault.proposeSuccessor(n1, n2, c);
            uint256 reviewEnds = vault.successor().reviewEnds;
            vm.warp(reviewEnds - 1 hours);
            vm.prank(attacker);
            vault.advanceCheckpoint(_cp(N0 + step), _cp(N0 + step));
            assertEq(vault.successor().reviewEnds, 0);
            ++step;
            vm.warp(block.timestamp + 1 hours);
        }
        emit log_named_uint("proposals lapsed", step - 1);
        vault.beginSnapshot();
        assertTrue(vault.snapshot().stateRoot != bytes32(0), "the exit, final, instead of the recovery");
    }

    /// FINDING 2: a message on ONE proof (a freeze) becomes `lastMessage`. With one proof system broken (P1 here, which
    /// proves anything), its forged freeze is a message no honest successor pair can prove again, so continuity (c)
    /// fails for every honest successor and only the snapshot remains.
    function test_poc_aForgedOneProofFreezeBlocksAnHonestSuccessor() public {
        vault.advanceCheckpoint(_cp(N0), _cp(N0));
        // An honest settle message on both proofs: the last real message.
        _fund(index, 10 ether);
        bytes memory realLast = lastDelivered;

        // P1 is broken: it "proves" a freeze the factory never sent. Only P1's proof is given.
        bytes memory forged = _payload(VaultMessages.FREEZE, factory, "");
        vault.deliver(_proof(factory, forged), "");
        assertEq(vault.lastMessage(), keccak256(forged));

        // Ethereum's formats break; the vault stalls.
        vm.warp(block.timestamp + 15 days);
        assertTrue(vault.stalled());
        HonestEventVerifier h1 = new HonestEventVerifier();
        HonestEventVerifier h2 = new HonestEventVerifier();
        h1.publish(realLast);
        h2.publish(realLast);

        IXindexVault.Continuity memory c = _continuity(9_000_000);
        // The honest pair can prove the last REAL message, but the vault asks for the forged one.
        c.message1 = realLast;
        c.message2 = realLast;
        vm.prank(recoveryProposer);
        vm.expectRevert(IXindexVault.Discontinuous.selector);
        vault.proposeSuccessor(h1, h2, c);
        c.message1 = _proof(factory, forged);
        c.message2 = _proof(factory, forged);
        vm.prank(recoveryProposer);
        vm.expectRevert(HonestEventVerifier.NotOnEthereum.selector);
        vault.proposeSuccessor(h1, h2, c);
    }

    /// FINDING 3: P1's and P2's verifier has no wall-clock bound on its anchor (BNB-2's MAX_LAG): a proof from an anchor
    /// a year old is accepted, so "a day behind, a verifier stops for good" holds in epochs inside the statement only.
    function test_poc_finalityVerifierTakesAProofFromAYearOldAnchor() public {
        MockSP1Verifier sp1 = new MockSP1Verifier();
        bytes32 key = keccak256("program");
        bytes32 anchor0 = keccak256("anchor at deployment");
        EthereumFinalityVerifier p = new EthereumFinalityVerifier(ISP1Verifier(address(sp1)), key, anchor0, 479_000);
        vm.warp(block.timestamp + 365 days);
        bytes memory pv =
            abi.encode(anchor0, keccak256("next"), uint64(479_001), keccak256("headers"), uint64(1), uint64(32));
        p.update(pv, sp1.prove(key, pv));
        assertEq(p.anchorEpoch(), 479_001, "accepted a year after its anchor");
    }
}
