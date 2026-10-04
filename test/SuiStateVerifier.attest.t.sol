// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SuiStateVerifier} from "../src/verifiers/SuiStateVerifier.sol";
import {ISuiStateVerifier} from "../src/interfaces/ISuiStateVerifier.sol";
import {Bls12381MinSig} from "../src/libraries/Bls12381MinSig.sol";
import {SuiBcs} from "../src/libraries/SuiBcs.sol";
import {Blake2b} from "../src/libraries/Blake2b.sol";
import {SuiWriter} from "./utils/SuiWriter.sol";

/// @notice Builds synthetic Sui state: a committee whose secret keys the test holds, checkpoints it certifies, and an
///         artifacts tree holding the vault's `Attestation` object, written from Sui's layouts by `SuiWriter`,
///         independently of the verifier. Mainnet's own bytes pin those writers (`test/SuiStateVerifier.t.sol`); no
///         vault is deployed on Sui yet, so the attestation itself is synthetic.
abstract contract SuiAttestBase is SuiWriter {
    SuiStateVerifier verifier;
    Signers committee;

    uint256 constant CHAIN_ID = 13762264207064992463;
    bytes32 constant VAULT_ID = 0x5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c;
    bytes32 constant PACKAGE_ID = 0x00000000000000000000000000000000000000000000000000000000000a77e5;
    uint64 constant EPOCH = 7;
    uint64 constant START_MS = 1_800_000_000_000;
    uint64 constant CHECKPOINT_MS = START_MS + 30 minutes * 1000;
    /// @dev The members' powers in committee order: the first two hold the quorum exactly.
    uint64[] powers = [uint64(4000), 2667, 2333, 1000];

    bytes constant IMMUTABLE = hex"03";

    /// @notice What the vault's object holds and where, and who certifies its checkpoint.
    struct Attest {
        bytes32 package;
        string module;
        string name;
        bool publicTransfer;
        bytes owner;
        uint256 chainId;
        bytes32 vaultId;
        uint64 recordMs;
        bytes32[] slots;
        bytes32[] values;
        uint256 index;
        uint256 leaves;
        uint256 mask;
        uint64 checkpointMs;
        uint64 epoch;
    }

    function _deploy(Signers memory c, uint64 epoch, uint64 startMs) internal {
        verifier = new SuiStateVerifier(CHAIN_ID, VAULT_ID, PACKAGE_ID, epoch, _hash(c.committee), startMs);
    }

    function _slots() internal pure returns (bytes32[] memory slots, bytes32[] memory values) {
        slots = new bytes32[](2);
        values = new bytes32[](2);
        slots[0] = keccak256(abi.encode(uint256(0xabc), keccak256(abi.encode(address(0x1d), 15))));
        slots[1] = bytes32(uint256(25));
        values[0] = keccak256("an intake's digest");
        values[1] = bytes32(0);
    }

    function _default() internal pure returns (Attest memory a) {
        (bytes32[] memory slots, bytes32[] memory values) = _slots();
        a = Attest({
            package: PACKAGE_ID,
            module: "vault",
            name: "Attestation",
            publicTransfer: false,
            owner: IMMUTABLE,
            chainId: CHAIN_ID,
            vaultId: VAULT_ID,
            recordMs: CHECKPOINT_MS - 400,
            slots: slots,
            values: values,
            index: 5,
            leaves: 7,
            mask: 0x3,
            checkpointMs: CHECKPOINT_MS,
            epoch: EPOCH
        });
    }

    function _record(Attest memory a) internal pure returns (bytes memory) {
        return abi.encode(ATTEST_DOMAIN, a.chainId, a.vaultId, uint256(a.recordMs), a.slots, a.values);
    }

    /// @dev The checkpoint holding `a`'s object, with `commitments` (the artifacts digest when empty).
    function _checkpoint(Attest memory a, bytes32 artifacts)
        internal
        pure
        returns (ISuiStateVerifier.Checkpoint memory s)
    {
        s.epoch = a.epoch;
        s.sequenceNumber = 330_000_123;
        s.networkTotalTransactions = 6_100_000_000;
        s.contentDigest = keccak256("contents");
        s.previousDigest = keccak256("the checkpoint before");
        s.epochRollingGasCostSummary = [uint64(770914144510), 78059465943600, 77082694992468, 778613080732];
        s.timestampMs = a.checkpointMs;
        s.checkpointCommitments = new ISuiStateVerifier.Commitment[](1);
        s.checkpointCommitments[0] = ISuiStateVerifier.Commitment({kind: 1, digest: artifacts});
        // No end-of-epoch data, then version-specific data.
        s.rest = hex"00020000";
    }

    /// @dev The proof of `a`: its object in a tree of `a.leaves` leaves at `a.index`, the checkpoint committing to the
    ///      tree, certified by the members `a.mask` names.
    function _proof(Attest memory a) internal view returns (ISuiStateVerifier.AttestProof memory p) {
        bytes memory record = _record(a);
        p.objectId = keccak256("the attestation's id");
        p.version = 977_252_311;
        p.previousTransaction = keccak256("the attest transaction");
        p.storageRebate = 2_964_000;
        bytes memory contents = bytes.concat(p.objectId, _uleb(record.length), record);
        bytes32 digest = Blake2b.hash256(
            _object(
                a.package,
                a.module,
                a.name,
                a.publicTransfer,
                p.version,
                contents,
                a.owner,
                p.previousTransaction,
                p.storageRebate
            )
        );
        bytes32[] memory leaves = new bytes32[](a.leaves);
        for (uint256 i = 0; i < a.leaves; ++i) {
            leaves[i] = i == a.index
                ? _leafHash(p.objectId, p.version, digest)
                : _leafHash(keccak256(abi.encode("another object", i)), uint64(i), keccak256(abi.encode(i)));
        }
        bytes32 root;
        (root, p.path) = _tree(leaves, a.index);
        p.leafIndex = a.index;
        p.checkpoint = _checkpoint(a, _artifactsDigest(root));
        p.committee = committee.committee;
        p.certificate = _sign(committee, a.mask, _message(p.checkpoint, ""));
        p.timestampMs = a.recordMs;
        p.values = a.values;
    }

    function _account() internal pure returns (address) {
        return address(uint160(uint256(VAULT_ID)));
    }

    /// @dev `verifySlots` on `p` for `slots`, expecting `err`.
    function _refused(bytes32[] memory slots, ISuiStateVerifier.AttestProof memory p, bytes memory err) internal {
        vm.expectRevert(err);
        verifier.verifySlots(_account(), slots, abi.encode(p));
    }

    function _notInCheckpoint(Attest memory a) internal {
        _refused(a.slots, _proof(a), abi.encodeWithSelector(ISuiStateVerifier.NotInCheckpoint.selector));
    }
}

/// @notice A `verifySlots` proof end to end on a committee the test signs for, and every way to break one. The BLS
///         precompiles exist from Prague on, so this suite runs on it.
/// forge-config: default.evm_version = "prague"
contract SuiStateVerifierAttestTest is SuiAttestBase {
    function setUp() public {
        committee = _signers("committee of epoch 7", powers);
        _deploy(committee, EPOCH, START_MS);
        vm.warp(CHECKPOINT_MS / 1000 + 1 hours);
    }

    function test_verifySlots_provesTheAttestation() public view {
        Attest memory a = _default();
        ISuiStateVerifier.AttestProof memory p = _proof(a);
        (uint256 number, uint256 timestamp, bytes32[] memory values) =
            verifier.verifySlots(_account(), a.slots, abi.encode(p));
        assertEq(number, p.checkpoint.sequenceNumber);
        assertEq(timestamp, a.recordMs / 1000);
        assertEq(values.length, 2);
        assertEq(values[0], a.values[0]);
        assertEq(values[1], a.values[1]);
        assertEq(verifier.attestRecord(a.recordMs, a.slots, a.values), _record(a));
    }

    /// @dev The object at either side of every step: the first leaf, a middle one, the last of an odd level.
    function test_verifySlots_anyLeafOfTheTree() public view {
        Attest memory a = _default();
        uint256[4] memory indices = [uint256(0), 1, 6, 4];
        uint256[4] memory sizes = [uint256(1), 2, 7, 13];
        for (uint256 i = 0; i < 4; ++i) {
            a.index = indices[i];
            a.leaves = sizes[i];
            verifier.verifySlots(_account(), a.slots, abi.encode(_proof(a)));
        }
    }

    // ---------------------------------------------------------------------
    // the object
    // ---------------------------------------------------------------------

    function test_verifySlots_onlyTheVaultsAttestationType() public {
        Attest memory a = _default();
        a.package = bytes32(uint256(PACKAGE_ID) + 1);
        _notInCheckpoint(a);
        a = _default();
        a.module = "vaults";
        _notInCheckpoint(a);
        a = _default();
        a.name = "Attestations";
        _notInCheckpoint(a);
        a = _default();
        a.publicTransfer = true;
        _notInCheckpoint(a);
    }

    /// @dev An owned, shared or object-owned object could be written again; only a frozen one is the record.
    function test_verifySlots_onlyAnImmutableObject() public {
        Attest memory a = _default();
        a.owner = bytes.concat(hex"00", bytes32(uint256(0xbeef)));
        _notInCheckpoint(a);
        a.owner = bytes.concat(hex"01", VAULT_ID);
        _notInCheckpoint(a);
        a.owner = bytes.concat(hex"02", _le(1));
        _notInCheckpoint(a);
    }

    function test_verifySlots_onlyThisChainAndVault() public {
        Attest memory a = _default();
        a.chainId = 10803649406359875205; // sui:testnet
        _notInCheckpoint(a);
        a = _default();
        a.vaultId = bytes32(uint256(VAULT_ID) ^ 1);
        _notInCheckpoint(a);
        bytes memory proof = abi.encode(_proof(_default()));
        vm.expectRevert(abi.encodeWithSelector(ISuiStateVerifier.WrongAccount.selector, address(0xbeef)));
        verifier.verifySlots(address(0xbeef), a.slots, proof);
    }

    function test_verifySlots_onlyTheRecordedSlotsAndValues() public {
        Attest memory a = _default();
        ISuiStateVerifier.AttestProof memory p = _proof(a);
        bytes memory notIn = abi.encodeWithSelector(ISuiStateVerifier.NotInCheckpoint.selector);
        p.values[1] = bytes32(uint256(1));
        _refused(a.slots, p, notIn);
        p = _proof(a);
        bytes32[] memory slots = new bytes32[](2);
        (slots[0], slots[1]) = (a.slots[1], a.slots[0]);
        _refused(slots, p, notIn);
        p.timestampMs -= 1;
        _refused(a.slots, p, notIn);
        bytes32[] memory one = new bytes32[](1);
        one[0] = a.slots[0];
        _refused(one, _proof(a), abi.encodeWithSelector(ISuiStateVerifier.LengthMismatch.selector));
    }

    function test_verifySlots_theObjectsOtherFieldsAreBound() public {
        Attest memory a = _default();
        bytes memory notIn = abi.encodeWithSelector(ISuiStateVerifier.NotInCheckpoint.selector);
        ISuiStateVerifier.AttestProof memory p = _proof(a);
        p.objectId ^= bytes32(uint256(1));
        _refused(a.slots, p, notIn);
        p = _proof(a);
        p.version += 1;
        _refused(a.slots, p, notIn);
        p = _proof(a);
        p.previousTransaction ^= bytes32(uint256(1));
        _refused(a.slots, p, notIn);
        p = _proof(a);
        p.storageRebate += 1;
        _refused(a.slots, p, notIn);
    }

    function test_verifySlots_theTreeIsBound() public {
        Attest memory a = _default();
        bytes memory notIn = abi.encodeWithSelector(ISuiStateVerifier.NotInCheckpoint.selector);
        ISuiStateVerifier.AttestProof memory p = _proof(a);
        p.path[1] ^= bytes32(uint256(1));
        _refused(a.slots, p, notIn);
        p = _proof(a);
        p.leafIndex ^= 1;
        _refused(a.slots, p, notIn);
        p = _proof(a);
        p.leafIndex += 8;
        _refused(a.slots, p, abi.encodeWithSelector(SuiBcs.BadLeafIndex.selector, 13));
        p = _proof(a);
        bytes32[] memory shorter = new bytes32[](2);
        (shorter[0], shorter[1]) = (p.path[0], p.path[1]);
        p.path = shorter;
        p.leafIndex = 1;
        _refused(a.slots, p, notIn);
    }

    /// @dev `attest` ran in a transaction the checkpoint holds, never after it.
    function test_verifySlots_theRecordPrecedesItsCheckpoint() public {
        Attest memory a = _default();
        a.recordMs = a.checkpointMs;
        verifier.verifySlots(_account(), a.slots, abi.encode(_proof(a)));
        a.recordMs = a.checkpointMs + 1;
        _refused(
            a.slots,
            _proof(a),
            abi.encodeWithSelector(ISuiStateVerifier.AfterTheCheckpoint.selector, a.recordMs, a.checkpointMs)
        );
    }

    // ---------------------------------------------------------------------
    // the commitments
    // ---------------------------------------------------------------------

    /// @dev The first artifacts digest counts, as Sui's `checkpoint_artifacts_digest` finds it; a live object set's
    ///      digest is skipped.
    function test_verifySlots_theFirstArtifactsDigest() public {
        Attest memory a = _default();
        ISuiStateVerifier.AttestProof memory p = _proof(a);
        bytes32 artifacts = p.checkpoint.checkpointCommitments[0].digest;
        ISuiStateVerifier.Commitment[] memory list = new ISuiStateVerifier.Commitment[](3);
        list[0] = ISuiStateVerifier.Commitment({kind: 0, digest: keccak256("a live object set")});
        list[1] = ISuiStateVerifier.Commitment({kind: 1, digest: artifacts});
        list[2] = ISuiStateVerifier.Commitment({kind: 1, digest: keccak256("another")});
        p.checkpoint.checkpointCommitments = list;
        p.certificate = _sign(committee, a.mask, _message(p.checkpoint, ""));
        verifier.verifySlots(_account(), a.slots, abi.encode(p));
        (list[1], list[2]) = (list[2], list[1]);
        p.certificate = _sign(committee, a.mask, _message(p.checkpoint, ""));
        _refused(a.slots, p, abi.encodeWithSelector(ISuiStateVerifier.NotInCheckpoint.selector));
    }

    function test_verifySlots_aCheckpointWithoutArtifacts() public {
        Attest memory a = _default();
        ISuiStateVerifier.AttestProof memory p = _proof(a);
        p.checkpoint.checkpointCommitments[0].kind = 0;
        p.certificate = _sign(committee, a.mask, _message(p.checkpoint, ""));
        _refused(a.slots, p, abi.encodeWithSelector(ISuiStateVerifier.NoArtifactsDigest.selector));
        p.checkpoint.checkpointCommitments = new ISuiStateVerifier.Commitment[](0);
        p.certificate = _sign(committee, a.mask, _message(p.checkpoint, ""));
        _refused(a.slots, p, abi.encodeWithSelector(ISuiStateVerifier.NoArtifactsDigest.selector));
        p.checkpoint.checkpointCommitments = new ISuiStateVerifier.Commitment[](1);
        p.checkpoint.checkpointCommitments[0].kind = 2;
        _refused(a.slots, p, abi.encodeWithSelector(ISuiStateVerifier.UnknownCommitment.selector, 2));
    }

    // ---------------------------------------------------------------------
    // the certificate
    // ---------------------------------------------------------------------

    function test_verifySlots_aQuorumOfVotingPower() public {
        Attest memory a = _default();
        // Members 1, 2 and 3 hold 6,000; members 0 and 2, 6,333.
        a.mask = 0xe;
        _refused(a.slots, _proof(a), abi.encodeWithSelector(ISuiStateVerifier.NoQuorum.selector, 6000));
        a.mask = 0x5;
        _refused(a.slots, _proof(a), abi.encodeWithSelector(ISuiStateVerifier.NoQuorum.selector, 6333));
        a.mask = 0xf;
        verifier.verifySlots(_account(), a.slots, abi.encode(_proof(a)));
    }

    function test_verifySlots_theSignersAreExact() public {
        Attest memory a = _default();
        ISuiStateVerifier.AttestProof memory p = _proof(a);
        bytes memory bad = abi.encodeWithSelector(ISuiStateVerifier.BadSignature.selector);
        p.certificate.signers[0] = 0x7; // member 2 named, but did not sign
        _refused(a.slots, p, bad);
        a.mask = 0x7;
        p = _proof(a);
        p.certificate.signers[0] = 0x3; // member 2 signed, but is not named
        _refused(a.slots, p, bad);
        p = _proof(a);
        p.certificate.signers[0] = 0x13; // a member past the committee
        _refused(a.slots, p, abi.encodeWithSelector(ISuiStateVerifier.BadSigners.selector));
        p.certificate.signers = new uint256[](2);
        p.certificate.signers[0] = 0x7;
        _refused(a.slots, p, abi.encodeWithSelector(ISuiStateVerifier.BadSigners.selector));
        p.certificate.signers = new uint256[](0);
        _refused(a.slots, p, abi.encodeWithSelector(ISuiStateVerifier.BadSigners.selector));
    }

    function test_verifySlots_theSignatureIsExact() public {
        Attest memory a = _default();
        ISuiStateVerifier.AttestProof memory p = _proof(a);
        p.checkpoint.rest = hex"00020001";
        _refused(a.slots, p, abi.encodeWithSelector(ISuiStateVerifier.BadSignature.selector));
        p = _proof(a);
        p.checkpoint.sequenceNumber += 1;
        _refused(a.slots, p, abi.encodeWithSelector(ISuiStateVerifier.BadSignature.selector));
        p = _proof(a);
        // A longer signature would add pairs of the caller's choosing to the pairing.
        p.certificate.signature = bytes.concat(p.certificate.signature, new bytes(384));
        _refused(a.slots, p, abi.encodeWithSelector(Bls12381MinSig.BadPoint.selector));
    }

    function test_verifySlots_onlyTheCommitteeInForce() public {
        Attest memory a = _default();
        ISuiStateVerifier.AttestProof memory p = _proof(a);
        bytes memory wrong = abi.encodeWithSelector(ISuiStateVerifier.WrongCommittee.selector);
        p.committee.powers[0] += 1;
        _refused(a.slots, p, wrong);
        p = _proof(a);
        p.committee.keys = bytes.concat(p.committee.keys, new bytes(1));
        _refused(a.slots, p, wrong);
        // Another committee's certificate, whatever it signs.
        Signers memory other = _signers("another committee", powers);
        p = _proof(a);
        p.committee = other.committee;
        p.certificate = _sign(other, a.mask, _message(p.checkpoint, ""));
        _refused(a.slots, p, wrong);
    }

    /// @dev Keys that cancel out sum to the identity, which no signature may verify against.
    function test_verifySlots_neverTheIdentityKey() public {
        uint64[] memory halves = new uint64[](2);
        (halves[0], halves[1]) = (5000, 5000);
        Signers memory c = _signers("two keys", halves);
        bytes memory key = _key(c.committee.keys, 0);
        (uint256[8] memory w) = abi.decode(key, (uint256[8]));
        (w[4], w[5]) = _negate(w[4], w[5]);
        (w[6], w[7]) = _negate(w[6], w[7]);
        c.committee.keys = bytes.concat(key, abi.encode(w));
        c.secrets[1] = R - c.secrets[0];
        committee = c;
        _deploy(c, EPOCH, START_MS);
        _refused(_default().slots, _proof(_default()), abi.encodeWithSelector(Bls12381MinSig.IdentityKey.selector));
    }

    // ---------------------------------------------------------------------
    // time
    // ---------------------------------------------------------------------

    function test_verifySlots_theEpochAndItsWindow() public {
        Attest memory a = _default();
        a.epoch = EPOCH + 1;
        _refused(a.slots, _proof(a), abi.encodeWithSelector(ISuiStateVerifier.WrongEpoch.selector, EPOCH + 1, EPOCH));
        a = _default();
        a.checkpointMs = START_MS - 1;
        a.recordMs = START_MS - 2;
        _refused(a.slots, _proof(a), abi.encodeWithSelector(ISuiStateVerifier.BeforeTheEpoch.selector, START_MS - 1));
        a = _default();
        a.checkpointMs = uint64(block.timestamp * 1000 + 1000);
        _refused(a.slots, _proof(a), abi.encodeWithSelector(ISuiStateVerifier.InTheFuture.selector, a.checkpointMs));
        a.checkpointMs -= 1; // the same second as this block
        verifier.verifySlots(_account(), a.slots, abi.encode(_proof(a)));
    }

    function test_verifySlots_stopsForGoodTwoDaysIntoTheEpoch() public {
        Attest memory a = _default();
        bytes memory proof = abi.encode(_proof(a));
        vm.warp(START_MS / 1000 + 2 days);
        verifier.verifySlots(_account(), a.slots, proof);
        vm.warp(START_MS / 1000 + 2 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ISuiStateVerifier.TooOld.selector, START_MS));
        verifier.verifySlots(_account(), a.slots, proof);
    }

    // ---------------------------------------------------------------------
    // deployment
    // ---------------------------------------------------------------------

    function test_constructor_refusesZeroes() public {
        bytes32 h = _hash(committee.committee);
        vm.expectRevert(ISuiStateVerifier.ZeroValue.selector);
        new SuiStateVerifier(0, VAULT_ID, PACKAGE_ID, EPOCH, h, START_MS);
        vm.expectRevert(ISuiStateVerifier.ZeroValue.selector);
        new SuiStateVerifier(CHAIN_ID, 0, PACKAGE_ID, EPOCH, h, START_MS);
        vm.expectRevert(ISuiStateVerifier.ZeroValue.selector);
        new SuiStateVerifier(CHAIN_ID, VAULT_ID, 0, EPOCH, h, START_MS);
        vm.expectRevert(ISuiStateVerifier.ZeroValue.selector);
        new SuiStateVerifier(CHAIN_ID, VAULT_ID, PACKAGE_ID, EPOCH, 0, START_MS);
        vm.expectRevert(ISuiStateVerifier.ZeroValue.selector);
        new SuiStateVerifier(CHAIN_ID, VAULT_ID, PACKAGE_ID, EPOCH, h, 0);
        SuiStateVerifier v = new SuiStateVerifier(CHAIN_ID, VAULT_ID, PACKAGE_ID, 0, h, START_MS);
        assertEq(v.epoch(), 0);
        assertEq(v.CHAIN_ID(), CHAIN_ID);
        assertEq(v.VAULT_ID(), VAULT_ID);
        assertEq(v.PACKAGE_ID(), PACKAGE_ID);
        assertEq(v.epochStartMs(), START_MS);
        assertEq(v.committeeHash(), h);
        assertEq(v.MAX_LAG(), 2 days);
        assertEq(v.QUORUM(), 6667);
        assertEq(v.TOTAL_VOTING_POWER(), 10_000);
        assertEq(v.NEW_KEY(), type(uint16).max);
        assertEq(v.ATTEST_DOMAIN(), keccak256("xindex.v4.vault-attest"));
        assertEq(v.hashCommittee(committee.committee.keys, committee.committee.powers), h);
    }

    uint256 constant P_HI = 0x1a0111ea397fe69a4b1ba7b6434bacd7;
    uint256 constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;

    function _negate(uint256 hi, uint256 lo) internal pure returns (uint256, uint256) {
        uint256 borrow = lo > P_LO ? 1 : 0;
        uint256 l;
        unchecked {
            l = P_LO - lo;
        }
        return (P_HI - hi - borrow, l);
    }
}

/// @notice `update` on committees the test signs for: a new committee with keys carried over and new ones, and every
///         way to name one wrongly.
/// forge-config: default.evm_version = "prague"
contract SuiStateVerifierUpdateTest is SuiAttestBase {
    Signers next;
    uint64 constant END_MS = START_MS + 1 days;

    function setUp() public {
        committee = _signers("committee of epoch 7", powers);
        _deploy(committee, EPOCH, START_MS);
        // The next committee keeps members 0 and 2 and adds two.
        uint256[] memory secrets = new uint256[](4);
        secrets[0] = committee.secrets[0];
        secrets[1] = committee.secrets[2];
        secrets[2] = uint256(keccak256("a new member")) % R;
        secrets[3] = uint256(keccak256("another new member")) % R;
        uint64[] memory quarters = new uint64[](4);
        (quarters[0], quarters[1], quarters[2], quarters[3]) = (2500, 2500, 2500, 2500);
        next = _signersFrom(secrets, quarters);
        vm.warp(END_MS / 1000 + 1 hours);
    }

    /// @dev The last checkpoint of epoch 7, `rest` the BCS after its committee: the next protocol version, the epoch
    ///      commitments and the version-specific data.
    function _end() internal pure returns (ISuiStateVerifier.Checkpoint memory s) {
        Attest memory a = _default();
        a.checkpointMs = END_MS;
        s = _checkpoint(a, keccak256("the last tree of the epoch"));
        s.rest = bytes.concat(_le(137), hex"010020", keccak256("the live object set"), hex"0a00010000000000000000");
    }

    function _namedBy(Signers memory c) internal pure returns (bytes memory) {
        return _named(c.compressed, c.committee.powers);
    }

    function _update(ISuiStateVerifier.Checkpoint memory s, ISuiStateVerifier.NextCommittee memory n, bytes memory err)
        internal
    {
        ISuiStateVerifier.Certificate memory cert = _sign(committee, 0x3, _message(s, _namedBy(next)));
        if (err.length != 0) vm.expectRevert(err);
        verifier.update(committee.committee, s, cert, n);
    }

    function test_update_followsANewCommittee() public {
        ISuiStateVerifier.NextCommittee memory n = _carry(committee.committee, next.committee);
        assertEq(n.newKeys.length, 2 * 256, "two new keys");
        vm.expectEmit(address(verifier));
        emit ISuiStateVerifier.CommitteeRecorded(EPOCH + 1, _hash(next.committee), END_MS);
        _update(_end(), n, "");
        assertEq(verifier.epoch(), EPOCH + 1);
        assertEq(verifier.epochStartMs(), END_MS);
        assertEq(verifier.committeeHash(), _hash(next.committee));
        // The new committee certifies the epoch's checkpoints: three of its four members hold a quorum.
        committee = next;
        Attest memory a = _default();
        a.mask = 0x7;
        a.epoch = EPOCH + 1;
        a.checkpointMs = END_MS + 1000;
        a.recordMs = END_MS + 500;
        verifier.verifySlots(_account(), a.slots, abi.encode(_proof(a)));
        // A second update with the same checkpoint is of an epoch gone.
        ISuiStateVerifier.Checkpoint memory s = _end();
        ISuiStateVerifier.Certificate memory cert = _sign(committee, 0x3, _message(s, _namedBy(next)));
        n = _carry(next.committee, next.committee);
        vm.expectRevert(abi.encodeWithSelector(ISuiStateVerifier.WrongEpoch.selector, EPOCH, EPOCH + 1));
        verifier.update(next.committee, s, cert, n);
    }

    /// @dev Only the last checkpoint of an epoch names a committee: one whose summary has none is refused, as the
    ///      verifier writes `Some` and the committee into what was signed.
    function test_update_onlyTheLastCheckpointOfTheEpoch() public {
        Attest memory a = _default();
        a.checkpointMs = END_MS;
        ISuiStateVerifier.Checkpoint memory s = _checkpoint(a, keccak256("a tree"));
        ISuiStateVerifier.Certificate memory cert = _sign(committee, 0x3, _message(s, ""));
        verifier.verifyCheckpoint(committee.committee, s, cert);
        ISuiStateVerifier.NextCommittee memory n = _carry(committee.committee, next.committee);
        vm.expectRevert(ISuiStateVerifier.BadSignature.selector);
        verifier.update(committee.committee, s, cert, n);
    }

    function test_update_theSourcesAreExact() public {
        bytes memory bad = abi.encodeWithSelector(ISuiStateVerifier.BadCommittee.selector);
        ISuiStateVerifier.Checkpoint memory s = _end();
        // No members.
        ISuiStateVerifier.NextCommittee memory m =
            ISuiStateVerifier.NextCommittee({sources: "", newKeys: "", powers: new uint64[](0)});
        _update(s, m, bad);
        // A source short.
        m = _carry(committee.committee, next.committee);
        m.sources = bytes.concat(bytes2(0), bytes2(0), bytes2(0), bytes1(0));
        _update(s, m, bad);
        // A new key cut short.
        m = _carry(committee.committee, next.committee);
        m.newKeys = bytes.concat(m.newKeys, hex"00");
        _update(s, m, bad);
        // A source past the committee in force.
        m = _carry(committee.committee, next.committee);
        m.sources = _withSource(m.sources, _firstCarried(m.sources), 4);
        _update(s, m, bad);
        // One new key too few, or one too many.
        m = _carry(committee.committee, next.committee);
        m.newKeys = _key(m.newKeys, 0);
        _update(s, m, bad);
        m = _carry(committee.committee, next.committee);
        m.newKeys = bytes.concat(m.newKeys, _key(m.newKeys, 0));
        _update(s, m, bad);
    }

    function test_update_theCommitteeIsWellFormed() public {
        ISuiStateVerifier.Checkpoint memory s = _end();
        // Powers that do not sum to 10,000.
        ISuiStateVerifier.NextCommittee memory m = _carry(committee.committee, next.committee);
        m.powers[3] += 1;
        _update(s, m, abi.encodeWithSelector(ISuiStateVerifier.BadCommittee.selector));
        // Two members out of order.
        _update(
            s,
            _swapFirstTwo(committee.committee, next.committee),
            abi.encodeWithSelector(ISuiStateVerifier.NotAscending.selector, 1)
        );
        // The same key twice: a carried key stands in for its neighbour.
        m = _carry(committee.committee, next.committee);
        uint256 at = _firstCarried(m.sources);
        uint256 other = at == 0 ? 1 : at - 1;
        m.sources = _withSource(m.sources, other, _source(m.sources, at));
        m.newKeys = _newKeysFor(m.sources, next.committee.keys);
        _update(s, m, abi.encodeWithSelector(ISuiStateVerifier.NotAscending.selector, at == 0 ? 1 : at));
    }

    /// @dev The order is the compressed keys' bytes, word by word. Keys that share their first word cannot both be
    ///      points, so these come from an anchor, which only its hash vouches for: `high` and `low` differ in x.c0's
    ///      high bytes, in the second word, `low` and `lowest` in its low bytes, in the third.
    function test_update_theOrderReadsEveryWord() public {
        uint256[8] memory w;
        (w[2], w[3]) = (0x0123, 0x4567);
        w[0] = 2;
        bytes memory high = abi.encode(w);
        w[0] = 1;
        bytes memory low = abi.encode(w);
        w[1] = 9;
        bytes memory lowest = abi.encode(w);
        uint64[] memory halves = new uint64[](2);
        (halves[0], halves[1]) = (5000, 5000);
        ISuiStateVerifier.Committee memory anchor =
            ISuiStateVerifier.Committee({keys: bytes.concat(high, low, lowest), powers: new uint64[](3)});
        verifier = new SuiStateVerifier(CHAIN_ID, VAULT_ID, PACKAGE_ID, EPOCH, _hash(anchor), START_MS);
        ISuiStateVerifier.Checkpoint memory s = _end();
        ISuiStateVerifier.Certificate memory none =
            ISuiStateVerifier.Certificate({signature: new bytes(128), signers: new uint256[](1)});
        bytes memory notAscending = abi.encodeWithSelector(ISuiStateVerifier.NotAscending.selector, 1);
        // `low` then `high`, by the second word: in order, and refused only for want of signers.
        ISuiStateVerifier.NextCommittee memory n =
            ISuiStateVerifier.NextCommittee({sources: hex"00010000", newKeys: "", powers: halves});
        vm.expectRevert(abi.encodeWithSelector(ISuiStateVerifier.NoQuorum.selector, 0));
        verifier.update(anchor, s, none, n);
        n.sources = hex"00000001";
        vm.expectRevert(notAscending);
        verifier.update(anchor, s, none, n);
        // `lowest` then `low`, by the third word.
        n.sources = hex"00020001";
        vm.expectRevert(notAscending);
        verifier.update(anchor, s, none, n);
    }

    function test_update_newKeysAreCheckedOnTheCurve() public {
        ISuiStateVerifier.Checkpoint memory s = _end();
        ISuiStateVerifier.NextCommittee memory m = _carry(committee.committee, next.committee);
        bytes memory off = bytes.concat(m.newKeys);
        off[255] = bytes1(uint8(off[255]) ^ 1);
        m.newKeys = off;
        _update(s, m, abi.encodeWithSelector(Bls12381MinSig.PrecompileFailed.selector, address(0x0d)));
        m = _carry(committee.committee, next.committee);
        m.newKeys = bytes.concat(new bytes(256), _key(m.newKeys, 1));
        _update(s, m, abi.encodeWithSelector(Bls12381MinSig.IdentityKey.selector));
    }

    function test_update_time() public {
        ISuiStateVerifier.NextCommittee memory n = _carry(committee.committee, next.committee);
        ISuiStateVerifier.Checkpoint memory s = _end();
        s.timestampMs = START_MS - 1;
        _update(s, n, abi.encodeWithSelector(ISuiStateVerifier.BeforeTheEpoch.selector, START_MS - 1));
        s.timestampMs = uint64(block.timestamp * 1000 + 1000);
        _update(s, n, abi.encodeWithSelector(ISuiStateVerifier.InTheFuture.selector, s.timestampMs));
        vm.warp(START_MS / 1000 + 2 days + 1);
        _update(_end(), n, abi.encodeWithSelector(ISuiStateVerifier.TooOld.selector, START_MS));
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _source(bytes memory sources, uint256 i) internal pure returns (uint256) {
        return (uint256(uint8(sources[2 * i])) << 8) | uint8(sources[2 * i + 1]);
    }

    function _firstCarried(bytes memory sources) internal pure returns (uint256) {
        for (uint256 i = 0; i < sources.length / 2; ++i) {
            if (_source(sources, i) != type(uint16).max) return i;
        }
        revert("none carried");
    }

    function _withSource(bytes memory sources, uint256 i, uint256 source) internal pure returns (bytes memory out) {
        out = bytes.concat(sources);
        out[2 * i] = bytes1(uint8(source >> 8));
        out[2 * i + 1] = bytes1(uint8(source));
    }

    /// @dev The new keys `sources` asks for, taken in order from the members of `keys` it marks new.
    function _newKeysFor(bytes memory sources, bytes memory keys) internal pure returns (bytes memory out) {
        for (uint256 i = 0; i < sources.length / 2; ++i) {
            if (_source(sources, i) == type(uint16).max) out = bytes.concat(out, _key(keys, i));
        }
    }

    /// @dev `n` with its first two members swapped, as `update` takes it.
    function _swapFirstTwo(ISuiStateVerifier.Committee memory current, ISuiStateVerifier.Committee memory n)
        internal
        pure
        returns (ISuiStateVerifier.NextCommittee memory)
    {
        bytes memory keys = bytes.concat(_key(n.keys, 1), _key(n.keys, 0));
        for (uint256 i = 2; i < n.powers.length; ++i) {
            keys = bytes.concat(keys, _key(n.keys, i));
        }
        uint64[] memory p = new uint64[](n.powers.length);
        for (uint256 i = 0; i < p.length; ++i) {
            p[i] = n.powers[i];
        }
        (p[0], p[1]) = (p[1], p[0]);
        return _carry(current, ISuiStateVerifier.Committee({keys: keys, powers: p}));
    }
}

/// @notice The cost of `verifySlots` and `update` at mainnet's size: 127 members with mainnet's voting powers, the
///         84 signers of a real certificate, and an artifacts tree of 512 leaves.
/// forge-config: default.evm_version = "prague"
contract SuiStateVerifierGasTest is SuiAttestBase {
    uint256 mask;

    function setUp() public {
        string memory json = vm.readFile("test/fixtures/sui/chain.json");
        uint256[] memory p = vm.parseJsonUintArray(json, ".step.next.powers");
        uint64[] memory real = new uint64[](p.length);
        for (uint256 i = 0; i < p.length; ++i) {
            real[i] = uint64(p[i]);
        }
        committee = _signers("a committee of mainnet's size", real);
        mask = vm.parseUint(vm.parseJsonStringArray(json, ".state.certificate.signers")[0]);
        _deploy(committee, EPOCH, START_MS);
        vm.warp(CHECKPOINT_MS / 1000 + 1 hours);
    }

    function _txGas(bytes memory data) internal returns (uint256 total, uint256 floor) {
        uint256 zeros = 0;
        for (uint256 i = 0; i < data.length; ++i) {
            if (data[i] == 0) ++zeros;
        }
        floor = 21_000 + 10 * (zeros + 4 * (data.length - zeros));
        address target = address(verifier);
        vm.cool(target);
        bool ok;
        uint256 before = gasleft();
        assembly ("memory-safe") {
            ok := call(gas(), target, 0, add(data, 32), mload(data), 0, 0)
        }
        total = before - gasleft();
        assertTrue(ok);
    }

    function test_gas_verifySlots() public {
        Attest memory a = _default();
        a.mask = mask;
        a.leaves = 512;
        a.index = 333;
        bytes memory call = abi.encodeCall(verifier.verifySlots, (_account(), a.slots, abi.encode(_proof(a))));
        (uint256 gas, uint256 floor) = _txGas(call);
        console2.log("verifySlots, two slots, 127 members, 84 signers, 512 leaves: gas", gas, "calldata floor", floor);
        console2.log("calldata bytes", call.length);
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) assertLt(gas, 1_500_000, "a two-slot proof");
    }
}
