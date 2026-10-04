// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SuiStateVerifier} from "../src/verifiers/SuiStateVerifier.sol";
import {ISuiStateVerifier} from "../src/interfaces/ISuiStateVerifier.sol";
import {Bls12381MinSig} from "../src/libraries/Bls12381MinSig.sol";
import {SuiBcs} from "../src/libraries/SuiBcs.sol";
import {SuiProofHarness} from "./mocks/SuiProofHarness.sol";
import {SuiWriter} from "./utils/SuiWriter.sol";

/// @notice Reads `test/fixtures/sui/chain.json` (its `generate.py`): Sui mainnet's committee of epoch 1268, the last
///         checkpoint of that epoch with its certificate and the committee of 1269 it names, and a checkpoint of 1269
///         with its certificate and the artifacts paths of two of the objects it wrote.
abstract contract SuiFixture is SuiWriter {
    string json;

    uint256 constant SUI_MAINNET = 13762264207064992463;

    function _load() internal {
        json = vm.readFile("test/fixtures/sui/chain.json");
    }

    function _u64(string memory path) internal view returns (uint64) {
        return uint64(vm.parseJsonUint(json, path));
    }

    function _committee(string memory path) internal view returns (ISuiStateVerifier.Committee memory c) {
        c.keys = vm.parseJsonBytes(json, string.concat(path, ".keys"));
        uint256[] memory powers = vm.parseJsonUintArray(json, string.concat(path, ".powers"));
        c.powers = new uint64[](powers.length);
        for (uint256 i = 0; i < powers.length; ++i) {
            c.powers[i] = uint64(powers[i]);
        }
    }

    function _checkpoint(string memory path) internal view returns (ISuiStateVerifier.Checkpoint memory s) {
        s.epoch = _u64(string.concat(path, ".epoch"));
        s.sequenceNumber = _u64(string.concat(path, ".sequenceNumber"));
        s.networkTotalTransactions = _u64(string.concat(path, ".networkTotalTransactions"));
        s.contentDigest = vm.parseJsonBytes32(json, string.concat(path, ".contentDigest"));
        s.previousDigest = vm.parseJsonBytes32(json, string.concat(path, ".previousDigest"));
        string[] memory gas = vm.parseJsonStringArray(json, string.concat(path, ".gas"));
        for (uint256 i = 0; i < 4; ++i) {
            s.epochRollingGasCostSummary[i] = uint64(vm.parseUint(gas[i]));
        }
        s.timestampMs = _u64(string.concat(path, ".timestampMs"));
        uint256[] memory kinds = vm.parseJsonUintArray(json, string.concat(path, ".commitmentKinds"));
        bytes32[] memory digests = vm.parseJsonBytes32Array(json, string.concat(path, ".commitmentDigests"));
        s.checkpointCommitments = new ISuiStateVerifier.Commitment[](kinds.length);
        for (uint256 i = 0; i < kinds.length; ++i) {
            s.checkpointCommitments[i] = ISuiStateVerifier.Commitment({kind: uint8(kinds[i]), digest: digests[i]});
        }
        s.rest = vm.parseJsonBytes(json, string.concat(path, ".rest"));
    }

    function _certificate(string memory path) internal view returns (ISuiStateVerifier.Certificate memory c) {
        c.signature = vm.parseJsonBytes(json, string.concat(path, ".signature"));
        string[] memory words = vm.parseJsonStringArray(json, string.concat(path, ".signers"));
        c.signers = new uint256[](words.length);
        for (uint256 i = 0; i < words.length; ++i) {
            c.signers[i] = vm.parseUint(words[i]);
        }
    }

    function _compressed(string memory path) internal view returns (bytes[] memory) {
        return vm.parseJsonBytesArray(json, string.concat(path, ".compressed"));
    }
}

/// @notice The Sui verifier on real mainnet data: a committee transition and two real certificates, each checked over
///         bytes the verifier writes itself, and the artifacts paths of real objects. The BLS precompiles exist from
///         Prague on, so this suite runs on it.
/// forge-config: default.evm_version = "prague"
contract SuiStateVerifierTest is SuiFixture {
    SuiStateVerifier verifier;
    SuiProofHarness h;
    bytes32 constant VAULT_ID = keccak256("an xindex vault on sui");
    bytes32 constant PACKAGE_ID = keccak256("the xindex package on sui");
    bytes constant POP_DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_";

    function setUp() public {
        _load();
        h = new SuiProofHarness();
        verifier = new SuiStateVerifier(
            SUI_MAINNET,
            VAULT_ID,
            PACKAGE_ID,
            _u64(".anchor.epoch"),
            _hash(_committee(".anchor")),
            _u64(".anchor.startMs")
        );
        vm.warp(_u64(".state.checkpoint.timestampMs") / 1000 + 10 minutes);
    }

    function _next() internal view returns (ISuiStateVerifier.NextCommittee memory) {
        return _carry(_committee(".anchor"), _committee(".step.next"));
    }

    function _update() internal {
        verifier.update(
            _committee(".anchor"), _checkpoint(".step.checkpoint"), _certificate(".step.certificate"), _next()
        );
    }

    function _updateCall(ISuiStateVerifier.Checkpoint memory s, ISuiStateVerifier.Committee memory next)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            verifier.update,
            (_committee(".anchor"), s, _certificate(".step.certificate"), _carry(_committee(".anchor"), next))
        );
    }

    /// @dev The aggregate key of the members `cert` names.
    function _aggregate(ISuiStateVerifier.Committee memory c, ISuiStateVerifier.Certificate memory cert)
        internal
        view
        returns (bytes memory sum)
    {
        sum = new bytes(256);
        for (uint256 i = 0; i < c.powers.length; ++i) {
            if ((cert.signers[i / 256] >> (i % 256)) & 1 == 1) sum = h.addKey(sum, c.keys, i);
        }
    }

    // ---------------------------------------------------------------------
    // the writers, against Sui's own bytes
    // ---------------------------------------------------------------------

    /// @dev The summaries, written from their fields as the verifier writes them (here independently), are the BCS
    ///      Sui serves, which hashes to the checkpoint's digest: `blake2b("CheckpointSummary::" ++ bcs)`.
    function test_theSummariesAreSuisOwnBytes() public view {
        bytes memory named = _named(_compressed(".step.next"), _committee(".step.next").powers);
        bytes memory end = _summary(_checkpoint(".step.checkpoint"), named);
        assertEq(end, vm.parseJsonBytes(json, ".step.checkpoint.bcs"));
        assertEq(
            h.hash256(bytes.concat("CheckpointSummary::", end)), vm.parseJsonBytes32(json, ".step.checkpoint.digest")
        );
        bytes memory state = _summary(_checkpoint(".state.checkpoint"), "");
        assertEq(state, vm.parseJsonBytes(json, ".state.checkpoint.bcs"));
        assertEq(
            h.hash256(bytes.concat("CheckpointSummary::", state)), vm.parseJsonBytes32(json, ".state.checkpoint.digest")
        );
    }

    /// @dev Every key of both committees compresses to the bytes the checkpoint lists, so both of y's signs, and the
    ///      order the committee is sorted in, are exercised on real keys.
    function test_theKeysCompressToSuisBytes() public view {
        string[2] memory paths = [".anchor", ".step.next"];
        for (uint256 p = 0; p < 2; ++p) {
            ISuiStateVerifier.Committee memory c = _committee(paths[p]);
            bytes[] memory compressed = _compressed(paths[p]);
            for (uint256 i = 0; i < compressed.length; ++i) {
                assertEq(h.compressKey(c.keys, i), compressed[i]);
            }
        }
    }

    // ---------------------------------------------------------------------
    // following the committee
    // ---------------------------------------------------------------------

    function test_update_followsTheRealCommittee() public {
        vm.expectEmit(address(verifier));
        emit ISuiStateVerifier.CommitteeRecorded(
            _u64(".anchor.epoch") + 1, _hash(_committee(".step.next")), _u64(".step.checkpoint.timestampMs")
        );
        _update();
        assertEq(verifier.epoch(), _u64(".anchor.epoch") + 1);
        assertEq(verifier.epochStartMs(), _u64(".step.checkpoint.timestampMs"));
        assertEq(verifier.committeeHash(), _hash(_committee(".step.next")));
        assertEq(
            verifier.hashCommittee(_committee(".step.next").keys, _committee(".step.next").powers),
            verifier.committeeHash()
        );
    }

    function test_verifyCheckpoint_theRealCertificate() public {
        _update();
        (uint256 seq, uint256 ts, bytes32 artifacts) = verifier.verifyCheckpoint(
            _committee(".step.next"), _checkpoint(".state.checkpoint"), _certificate(".state.certificate")
        );
        assertEq(seq, _u64(".state.checkpoint.sequenceNumber"));
        assertEq(ts, _u64(".state.checkpoint.timestampMs"));
        assertEq(artifacts, vm.parseJsonBytes32(json, ".state.artifactsDigest"));
    }

    /// @dev The end-of-epoch checkpoint verifies as a checkpoint too, with its committee left in `rest`.
    function test_verifyCheckpoint_theEndOfAnEpoch() public view {
        ISuiStateVerifier.Checkpoint memory s = _checkpoint(".step.checkpoint");
        s.rest = bytes.concat(_named(_compressed(".step.next"), _committee(".step.next").powers), s.rest);
        (uint256 seq,,) = verifier.verifyCheckpoint(_committee(".anchor"), s, _certificate(".step.certificate"));
        assertEq(seq, _u64(".step.checkpoint.sequenceNumber"));
    }

    /// @dev A certificate of the epoch before cannot be used once the next committee is in force, nor one of the next
    ///      before it is.
    function test_update_onceAndInOrder() public {
        ISuiStateVerifier.Committee memory anchor = _committee(".anchor");
        ISuiStateVerifier.Committee memory next = _committee(".step.next");
        ISuiStateVerifier.Checkpoint memory state = _checkpoint(".state.checkpoint");
        ISuiStateVerifier.Certificate memory stateCert = _certificate(".state.certificate");
        vm.expectRevert(ISuiStateVerifier.WrongCommittee.selector);
        verifier.verifyCheckpoint(next, state, stateCert);
        vm.expectRevert(abi.encodeWithSelector(ISuiStateVerifier.WrongEpoch.selector, 1269, 1268));
        verifier.verifyCheckpoint(anchor, state, stateCert);
        _update();
        vm.expectRevert(ISuiStateVerifier.WrongCommittee.selector);
        verifier.update(
            anchor, _checkpoint(".step.checkpoint"), _certificate(".step.certificate"), _carry(anchor, next)
        );
        vm.expectRevert(abi.encodeWithSelector(ISuiStateVerifier.WrongEpoch.selector, 1268, 1269));
        verifier.update(next, _checkpoint(".step.checkpoint"), _certificate(".step.certificate"), _carry(next, next));
    }

    // ---------------------------------------------------------------------
    // what the real certificates refuse
    // ---------------------------------------------------------------------

    function test_update_anyOtherCommitteeIsRefused() public {
        ISuiStateVerifier.Checkpoint memory s = _checkpoint(".step.checkpoint");
        ISuiStateVerifier.Committee memory next = _committee(".step.next");
        // Two powers swapped: the total holds, but a byte of the signed summary differs.
        assertTrue(next.powers[0] != next.powers[1]);
        (next.powers[0], next.powers[1]) = (next.powers[1], next.powers[0]);
        (bool ok, bytes memory ret) = address(verifier).call(_updateCall(s, next));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(ISuiStateVerifier.BadSignature.selector));
        // One key fewer: the powers no longer sum to 10,000.
        next = _committee(".step.next");
        bytes memory keys = next.keys;
        uint64[] memory powers = next.powers;
        assembly {
            mstore(keys, sub(mload(keys), 256))
            mstore(powers, sub(mload(powers), 1))
        }
        (ok, ret) = address(verifier).call(_updateCall(s, next));
        assertEq(ret, abi.encodeWithSelector(ISuiStateVerifier.BadCommittee.selector));
    }

    function test_update_anyOtherSummaryIsRefused() public {
        ISuiStateVerifier.Committee memory next = _committee(".step.next");
        ISuiStateVerifier.Checkpoint memory s = _checkpoint(".step.checkpoint");
        s.timestampMs -= 1;
        (bool ok, bytes memory ret) = address(verifier).call(_updateCall(s, next));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(ISuiStateVerifier.BadSignature.selector));
        s = _checkpoint(".step.checkpoint");
        s.rest[0] = bytes1(uint8(s.rest[0]) ^ 1);
        (ok, ret) = address(verifier).call(_updateCall(s, next));
        assertEq(ret, abi.encodeWithSelector(ISuiStateVerifier.BadSignature.selector));
        s = _checkpoint(".step.checkpoint");
        s.contentDigest ^= bytes32(uint256(1));
        (ok, ret) = address(verifier).call(_updateCall(s, next));
        assertEq(ret, abi.encodeWithSelector(ISuiStateVerifier.BadSignature.selector));
    }

    /// @dev The end of epoch 1268 was certified by exactly 6,667 of 10,000, the quorum itself: any signer fewer is
    ///      refused before any pairing, and a member the bitmap adds who did not sign breaks the aggregate.
    function test_verifyCheckpoint_theQuorumIsExact() public {
        ISuiStateVerifier.Committee memory anchor = _committee(".anchor");
        ISuiStateVerifier.Checkpoint memory s = _checkpoint(".step.checkpoint");
        s.rest = bytes.concat(_named(_compressed(".step.next"), _committee(".step.next").powers), s.rest);
        ISuiStateVerifier.Certificate memory cert = _certificate(".step.certificate");
        uint256 word = cert.signers[0];
        uint256 power = 0;
        for (uint256 i = 0; i < anchor.powers.length; ++i) {
            if ((word >> i) & 1 == 1) power += anchor.powers[i];
        }
        assertEq(power, 6667, "the quorum, exactly");
        for (uint256 i = 0; i < 3; ++i) {
            if ((word >> i) & 1 == 0) continue;
            cert.signers[0] = word ^ (1 << i);
            vm.expectRevert(abi.encodeWithSelector(ISuiStateVerifier.NoQuorum.selector, 6667 - anchor.powers[i]));
            verifier.verifyCheckpoint(anchor, s, cert);
        }
        cert.signers[0] = word | ((~word) & (word + 1)); // the lowest member who did not sign
        vm.expectRevert(ISuiStateVerifier.BadSignature.selector);
        verifier.verifyCheckpoint(anchor, s, cert);
    }

    /// @dev The checkpoint of 1269 was certified by 6,700: a signer left out who did sign breaks the aggregate.
    function test_verifyCheckpoint_aSignerLeftOut() public {
        _update();
        ISuiStateVerifier.Committee memory next = _committee(".step.next");
        ISuiStateVerifier.Certificate memory cert = _certificate(".state.certificate");
        uint256 word = cert.signers[0];
        uint256 weakest = 0;
        for (uint256 i = 0; i < next.powers.length; ++i) {
            if ((word >> i) & 1 == 1 && (weakest == 0 || next.powers[i] < next.powers[weakest - 1])) weakest = i + 1;
        }
        cert.signers[0] = word ^ (1 << (weakest - 1));
        vm.expectRevert(ISuiStateVerifier.BadSignature.selector);
        verifier.verifyCheckpoint(next, _checkpoint(".state.checkpoint"), cert);
    }

    /// @dev Sui's signature verifies under its own tag only: the same check under the proof-of-possession tag, or of
    ///      the summary without the intent or the epoch, fails.
    function test_theRealSignatureNeedsSuisTagAndMessage() public view {
        ISuiStateVerifier.Committee memory anchor = _committee(".anchor");
        ISuiStateVerifier.Certificate memory cert = _certificate(".step.certificate");
        bytes memory key = _aggregate(anchor, cert);
        bytes memory bcs = vm.parseJsonBytes(json, ".step.checkpoint.bcs");
        bytes memory message = bytes.concat(INTENT, bcs, _le(_u64(".step.checkpoint.epoch")));
        assertTrue(h.verify(key, cert.signature, message));
        assertTrue(h.verifyHashed(key, cert.signature, h.hashToG1(message, Bls12381MinSig.DST)));
        assertFalse(h.verifyHashed(key, cert.signature, h.hashToG1(message, POP_DST)));
        assertFalse(h.verify(key, cert.signature, bytes.concat(INTENT, bcs)));
        assertFalse(h.verify(key, cert.signature, bytes.concat(bcs, _le(_u64(".step.checkpoint.epoch")))));
    }

    // ---------------------------------------------------------------------
    // time
    // ---------------------------------------------------------------------

    function test_update_noCheckpointFromTheFuture() public {
        uint64 ts = _u64(".step.checkpoint.timestampMs");
        vm.warp(ts / 1000 - 1);
        vm.expectRevert(abi.encodeWithSelector(ISuiStateVerifier.InTheFuture.selector, ts));
        _update();
        vm.warp(ts / 1000);
        _update();
    }

    function test_update_stopsForGoodTwoDaysIntoTheEpoch() public {
        uint64 start = _u64(".anchor.startMs");
        vm.warp(start / 1000 + 2 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ISuiStateVerifier.TooOld.selector, start));
        _update();
        vm.warp(start / 1000 + 2 days);
        _update();
    }

    function test_verifyCheckpoint_neitherBeforeTheEpochNorTooLate() public {
        _update();
        uint64 start = _u64(".step.checkpoint.timestampMs");
        ISuiStateVerifier.Committee memory next = _committee(".step.next");
        ISuiStateVerifier.Checkpoint memory s = _checkpoint(".state.checkpoint");
        ISuiStateVerifier.Certificate memory cert = _certificate(".state.certificate");
        vm.warp(start / 1000 + 2 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ISuiStateVerifier.TooOld.selector, start));
        verifier.verifyCheckpoint(next, s, cert);
        vm.warp(start / 1000 + 2 days);
        verifier.verifyCheckpoint(next, s, cert);
        s.timestampMs = start - 1;
        vm.expectRevert(abi.encodeWithSelector(ISuiStateVerifier.BeforeTheEpoch.selector, start - 1));
        verifier.verifyCheckpoint(next, s, cert);
    }

    // ---------------------------------------------------------------------
    // the artifacts tree and objects
    // ---------------------------------------------------------------------

    /// @dev The Clock's leaf and the tree's last leaf, whose first sibling is the empty node closing the odd leaf
    ///      level, lead to the artifacts digest the certified checkpoint commits to; the Clock, written from its
    ///      fields, hashes to its leaf's digest. A tampered path, index or leaf does not.
    function test_realArtifactsPaths() public view {
        bytes32 artifacts = vm.parseJsonBytes32(json, ".state.artifactsDigest");
        string[2] memory leaves = [".state.leaf", ".state.lastLeaf"];
        for (uint256 i = 0; i < 2; ++i) {
            bytes32 id = vm.parseJsonBytes32(json, string.concat(leaves[i], ".objectId"));
            uint64 version = _u64(string.concat(leaves[i], ".version"));
            bytes32 digest = vm.parseJsonBytes32(json, string.concat(leaves[i], ".digest"));
            uint256 index = vm.parseJsonUint(json, string.concat(leaves[i], ".index"));
            bytes32[] memory path = vm.parseJsonBytes32Array(json, string.concat(leaves[i], ".path"));
            bytes32 leaf = h.artifactLeaf(id, version, digest);
            assertEq(leaf, _leafHash(id, version, digest));
            assertEq(h.artifactsDigest(h.merkleRoot(leaf, index, path)), artifacts);
            assertTrue(h.artifactsDigest(h.merkleRoot(leaf, index ^ 1, path)) != artifacts);
            path[path.length - 1] ^= bytes32(uint256(1));
            assertTrue(h.artifactsDigest(h.merkleRoot(leaf, index, path)) != artifacts);
        }
        assertEq(
            vm.parseJsonBytes32(json, ".state.lastLeaf.path[0]"),
            bytes32(0),
            "the last leaf's sibling is the empty node"
        );
        SuiBcs.MoveObject memory clock = SuiBcs.MoveObject({
            package: vm.parseJsonBytes32(json, ".state.object.package"),
            module: vm.parseJsonString(json, ".state.object.module"),
            name: vm.parseJsonString(json, ".state.object.name"),
            hasPublicTransfer: vm.parseJsonBool(json, ".state.object.hasPublicTransfer"),
            version: _u64(".state.object.version"),
            contents: vm.parseJsonBytes(json, ".state.object.contents"),
            owner: vm.parseJsonBytes(json, ".state.object.owner"),
            previousTransaction: vm.parseJsonBytes32(json, ".state.object.previousTransaction"),
            storageRebate: _u64(".state.object.storageRebate")
        });
        assertEq(h.objectDigest(clock), vm.parseJsonBytes32(json, ".state.leaf.digest"));
        assertEq(
            h.objectDigest(clock),
            h.hash256(
                _object(
                    clock.package,
                    clock.module,
                    clock.name,
                    clock.hasPublicTransfer,
                    clock.version,
                    clock.contents,
                    clock.owner,
                    clock.previousTransaction,
                    clock.storageRebate
                )
            )
        );
    }

    // ---------------------------------------------------------------------
    // gas, as a transaction pays it
    // ---------------------------------------------------------------------

    /// @dev What a transaction sending `data` to the verifier pays, and how much of it is execution: Foundry runs each
    ///      call as its own transaction, so the gas measured carries the 21,000 and the calldata, EIP-7623's floor
    ///      included (`test/BnbStateVerifier.t.sol`).
    function _txGas(address target, bytes memory data) internal returns (uint256 total, uint256 floor) {
        uint256 zeros = 0;
        for (uint256 i = 0; i < data.length; ++i) {
            if (data[i] == 0) ++zeros;
        }
        uint256 tokens = zeros + 4 * (data.length - zeros);
        floor = 21_000 + 10 * tokens;
        vm.cool(target);
        bool ok;
        uint256 before = gasleft();
        assembly ("memory-safe") {
            ok := call(gas(), target, 0, add(data, 32), mload(data), 0, 0)
        }
        total = before - gasleft();
        assertTrue(ok);
    }

    /// @dev Following Sui costs one update a day, with both committees' 127 keys in calldata.
    function test_gas_update() public {
        bytes memory call = abi.encodeCall(
            verifier.update,
            (_committee(".anchor"), _checkpoint(".step.checkpoint"), _certificate(".step.certificate"), _next())
        );
        (uint256 gas, uint256 floor) = _txGas(address(verifier), call);
        console2.log("update, 127 members to the same 127, 84 signers: gas", gas, "calldata floor", floor);
        console2.log("calldata bytes", call.length);
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) assertLt(gas, 3_000_000, "an update");
        assertEq(verifier.epoch(), _u64(".anchor.epoch") + 1);
        call = abi.encodeCall(
            verifier.verifyCheckpoint,
            (_committee(".step.next"), _checkpoint(".state.checkpoint"), _certificate(".state.certificate"))
        );
        (gas, floor) = _txGas(address(verifier), call);
        console2.log("verifyCheckpoint, 127 members, 84 signers: gas", gas, "calldata floor", floor);
    }
}
