// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NearStateVerifier} from "../src/verifiers/NearStateVerifier.sol";
import {INearStateVerifier} from "../src/interfaces/INearStateVerifier.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";
import {NearStateVerifierHarness} from "./mocks/NearStateVerifierHarness.sol";

/// @notice NEAR's state verifier on mainnet's own data (`proofs/near/fixtures/mainnet.json`, which `generate.py`
///         rebuilds from mainnet's RPC and checks with a separate implementation): the statement's public values for
///         epoch E-1's producers, E-1's last final block and the head, then a real receipt's outcome under that head.
///         The Groth16 check is mocked; what the verifier does with a proven statement is not. A vault's own `attest`
///         is proven on a synthetic tree the generator built, since no vault runs on mainnet.
contract NearStateVerifierTest is Test {
    string json;
    MockSP1Verifier sp1;

    bytes32 constant KEY = keccak256("the NEAR program");
    uint256 constant NEAR_MAINNET = 339_552_387_624_818_629;
    uint256 constant NS = 1e9;

    function setUp() public {
        json = vm.readFile("proofs/near/fixtures/mainnet.json");
        sp1 = new MockSP1Verifier();
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _named() internal view returns (uint64) {
        return uint64(vm.parseJsonUint(json, ".anchor.named_at"));
    }

    function _deploy(string memory account) internal returns (NearStateVerifierHarness) {
        return new NearStateVerifierHarness(
            sp1,
            KEY,
            NEAR_MAINNET,
            account,
            vm.parseJsonBytes32(json, ".anchor.epoch_id"),
            vm.parseJsonBytes32(json, ".anchor.producers_hash"),
            _named()
        );
    }

    function _path(string memory base) internal view returns (INearStateVerifier.PathItem[] memory items) {
        bytes32[] memory hashes = vm.parseJsonBytes32Array(json, string.concat(base, "_hashes"));
        bool[] memory left = vm.parseJsonBoolArray(json, string.concat(base, "_left"));
        items = new INearStateVerifier.PathItem[](hashes.length);
        for (uint256 i = 0; i < hashes.length; ++i) {
            items[i] = INearStateVerifier.PathItem({hash: hashes[i], left: left[i]});
        }
    }

    function _header(string memory base) internal view returns (INearStateVerifier.LiteHeader memory b) {
        string memory l = string.concat(base, ".inner_lite");
        b.innerLite = INearStateVerifier.InnerLite({
            height: uint64(vm.parseJsonUint(json, string.concat(l, ".height"))),
            epochId: vm.parseJsonBytes32(json, string.concat(l, ".epoch_id")),
            nextEpochId: vm.parseJsonBytes32(json, string.concat(l, ".next_epoch_id")),
            prevStateRoot: vm.parseJsonBytes32(json, string.concat(l, ".prev_state_root")),
            outcomeRoot: vm.parseJsonBytes32(json, string.concat(l, ".outcome_root")),
            timestamp: uint64(vm.parseJsonUint(json, string.concat(l, ".timestamp"))),
            nextBpHash: vm.parseJsonBytes32(json, string.concat(l, ".next_bp_hash")),
            blockMerkleRoot: vm.parseJsonBytes32(json, string.concat(l, ".block_merkle_root"))
        });
        b.innerRestHash = vm.parseJsonBytes32(json, string.concat(base, ".inner_rest_hash"));
        b.prevBlockHash = vm.parseJsonBytes32(json, string.concat(base, ".prev_block_hash"));
    }

    /// @dev The real receipt's proof under the head, with the height and time of the block it ran in.
    function _real() internal view returns (INearStateVerifier.AttestProof memory p) {
        p.head = vm.parseJsonBytes32(json, ".blocks[1].inner_lite.block_merkle_root");
        p.receiptId = vm.parseJsonBytes32(json, ".outcome.receipt_id");
        p.receiptIds = vm.parseJsonBytes32Array(json, ".outcome.receipt_ids");
        p.gasBurnt = uint64(vm.parseJsonUint(json, ".outcome.gas_burnt"));
        p.tokensBurnt = uint128(vm.parseJsonUint(json, ".outcome.tokens_burnt"));
        p.logs = vm.parseJsonBytesArray(json, ".outcome.logs");
        p.outcomePath = _path(".outcome.outcome_path");
        p.outcomeRootPath = _path(".outcome.outcome_root_path");
        p.blockHeader = _header(".outcome.block");
        p.blockPath = _path(".outcome.block_path");
        p.height = uint64(vm.parseJsonUint(json, ".outcome.executed_in.height"));
        p.timestamp = uint64(vm.parseJsonUint(json, ".outcome.executed_in.timestamp"));
    }

    function _realExecutor() internal view returns (bytes memory) {
        return bytes(vm.parseJsonString(json, ".outcome.executor"));
    }

    function _realValue() internal view returns (bytes memory) {
        return vm.parseJsonBytes(json, ".outcome.value");
    }

    /// @dev The synthetic attest's proof, values included.
    function _synthetic() internal view returns (INearStateVerifier.AttestProof memory p) {
        p.head = vm.parseJsonBytes32(json, ".synthetic.head.block_merkle_root");
        p.receiptId = vm.parseJsonBytes32(json, ".synthetic.receipt_id");
        p.receiptIds = new bytes32[](0);
        p.gasBurnt = uint64(vm.parseJsonUint(json, ".synthetic.gas_burnt"));
        p.tokensBurnt = uint128(vm.parseJsonUint(json, ".synthetic.tokens_burnt"));
        p.logs = new bytes[](0);
        p.outcomePath = _path(".synthetic.outcome_path");
        p.outcomeRootPath = _path(".synthetic.outcome_root_path");
        p.blockHeader = _header(".synthetic.block");
        p.blockPath = _path(".synthetic.block_path");
        p.height = uint64(vm.parseJsonUint(json, ".synthetic.height"));
        p.timestamp = uint64(vm.parseJsonUint(json, ".synthetic.timestamp"));
        p.values = vm.parseJsonBytes32Array(json, ".synthetic.values");
    }

    function _slots() internal view returns (bytes32[] memory) {
        return vm.parseJsonBytes32Array(json, ".synthetic.slots");
    }

    /// @dev Records the real head: the statement's public values for mainnet's chain, at the head's time.
    function _recordRealHead(NearStateVerifier v) internal {
        vm.warp(vm.parseJsonUint(json, ".blocks[1].inner_lite.timestamp") / NS + 60);
        bytes memory pv = vm.parseJsonBytes(json, ".public_values");
        v.update(pv, sp1.prove(KEY, pv));
    }

    /// @dev Records the synthetic head, which names no new producers.
    function _recordSyntheticHead(NearStateVerifier v) internal {
        vm.warp(vm.parseJsonUint(json, ".synthetic.head.timestamp") / NS + 60);
        bytes memory pv = vm.parseJsonBytes(json, ".synthetic.public_values");
        v.update(pv, sp1.prove(KEY, pv));
    }

    function _values(
        bytes32 epochIn,
        bytes32 producersIn,
        bytes32 epochOut,
        bytes32 producersOut,
        uint256 namedOut,
        bytes32 root
    ) internal pure returns (bytes memory) {
        return abi.encode(epochIn, producersIn, epochOut, producersOut, namedOut, uint256(1), uint256(2), root);
    }

    // ---------------------------------------------------------------------
    // deployment
    // ---------------------------------------------------------------------

    function test_deploy() public {
        NearStateVerifier v = _deploy("xindex-vault.near");
        assertEq(address(v.SP1_VERIFIER()), address(sp1));
        assertEq(v.PROGRAM_KEY(), KEY);
        assertEq(v.CHAIN_ID(), NEAR_MAINNET);
        assertEq(v.VAULT_ID(), keccak256("xindex-vault.near"));
        assertEq(v.VAULT_ID(), vm.parseJsonBytes32(json, ".synthetic.vault_id"), "the generator's keccak agrees");
        assertEq(v.vaultAccount(), bytes("xindex-vault.near"));
        assertEq(v.epochId(), vm.parseJsonBytes32(json, ".anchor.epoch_id"));
        assertEq(v.producersHash(), vm.parseJsonBytes32(json, ".anchor.producers_hash"));
        assertEq(v.namedAt(), _named());
        assertEq(v.ATTEST_DOMAIN(), keccak256("xindex.v4.vault-attest"));
        assertEq(v.MAX_LAG(), 1 days);

        bytes32 e = keccak256("epoch");
        vm.expectRevert(INearStateVerifier.ZeroValue.selector);
        new NearStateVerifier(ISP1Verifier(address(0)), KEY, 1, "a", e, e, 1);
        vm.expectRevert(INearStateVerifier.ZeroValue.selector);
        new NearStateVerifier(sp1, bytes32(0), 1, "a", e, e, 1);
        vm.expectRevert(INearStateVerifier.ZeroValue.selector);
        new NearStateVerifier(sp1, KEY, 0, "a", e, e, 1);
        vm.expectRevert(INearStateVerifier.ZeroValue.selector);
        new NearStateVerifier(sp1, KEY, 1, "", e, e, 1);
        vm.expectRevert(INearStateVerifier.ZeroValue.selector);
        new NearStateVerifier(sp1, KEY, 1, "a", bytes32(0), e, 1);
        vm.expectRevert(INearStateVerifier.ZeroValue.selector);
        new NearStateVerifier(sp1, KEY, 1, "a", e, bytes32(0), 1);
        vm.expectRevert(INearStateVerifier.ZeroValue.selector);
        new NearStateVerifier(sp1, KEY, 1, "a", e, e, 0);
    }

    /// @dev An integrator or a deployment check written against the interface reads the program it trusts (A6-06).
    function test_A606_theInterfaceNamesTheProgram() public {
        INearStateVerifier v = _deploy("xindex-vault.near");
        assertEq(address(v.SP1_VERIFIER()), address(sp1));
        assertEq(v.PROGRAM_KEY(), KEY);
    }

    // ---------------------------------------------------------------------
    // following NEAR
    // ---------------------------------------------------------------------

    /// @dev Mainnet's chain: from E-1's producers through E-1's last final block to the head, which names E+1's. The
    ///      verifier moves to E+1, named at the head's time, and records the head; the same proof never runs twice.
    function test_update_followsMainnet() public {
        NearStateVerifier v = _deploy("xindex-vault.near");
        bytes memory pv = vm.parseJsonBytes(json, ".public_values");
        bytes memory proof = sp1.prove(KEY, pv);
        uint64 height = uint64(vm.parseJsonUint(json, ".blocks[1].inner_lite.height"));
        uint64 time = uint64(vm.parseJsonUint(json, ".blocks[1].inner_lite.timestamp"));
        bytes32 root = vm.parseJsonBytes32(json, ".blocks[1].inner_lite.block_merkle_root");
        bytes32 epochOut = vm.parseJsonBytes32(json, ".blocks[1].inner_lite.next_epoch_id");
        vm.warp(time / NS + 60);

        bytes memory anotherProgram = sp1.prove(keccak256("another program"), pv);
        vm.expectRevert(MockSP1Verifier.Rejected.selector);
        v.update(pv, anotherProgram);

        (,,, bytes32 producersOut,,,,) =
            abi.decode(pv, (bytes32, bytes32, bytes32, bytes32, uint256, uint256, uint256, bytes32));
        vm.expectEmit(address(v));
        emit INearStateVerifier.Advanced(epochOut, producersOut, time, root, height, time);
        v.update(pv, proof);
        assertEq(v.epochId(), epochOut);
        assertEq(v.producersHash(), producersOut);
        assertEq(v.namedAt(), time, "the head named E+1's producers");
        INearStateVerifier.Head memory h = v.head(root);
        assertEq(h.height, height);
        assertEq(h.timestamp, time);

        bytes32 epochIn = vm.parseJsonBytes32(json, ".anchor.epoch_id");
        bytes32 producersIn = vm.parseJsonBytes32(json, ".anchor.producers_hash");
        vm.expectRevert(abi.encodeWithSelector(INearStateVerifier.WrongAnchor.selector, epochIn, producersIn));
        v.update(pv, proof);
    }

    /// @dev A day after the producers in force were named, nothing advances the verifier again.
    function test_update_stopsForGoodADayBehind() public {
        NearStateVerifier v = _deploy("xindex-vault.near");
        bytes memory pv = vm.parseJsonBytes(json, ".public_values");
        bytes memory proof = sp1.prove(KEY, pv);
        uint256 ends = uint256(_named()) / NS + 1 days;
        vm.warp(ends + 1);
        vm.expectRevert(abi.encodeWithSelector(INearStateVerifier.TooOld.selector, _named()));
        v.update(pv, proof);
        vm.warp(ends);
        v.update(pv, proof);
    }

    /// @dev The anchor must be the stored one; the values must be eight words; a proof that names no producers keeps
    ///      the ones in force; and producers named at a time still to come are refused.
    function test_update_refusals() public {
        NearStateVerifier v = _deploy("xindex-vault.near");
        bytes32 e = v.epochId();
        bytes32 p = v.producersHash();
        bytes32 other = keccak256("other");
        vm.warp(uint256(_named()) / NS + 1 hours);

        _refuseUpdate(
            v,
            _values(other, p, e, p, 0, other),
            abi.encodeWithSelector(INearStateVerifier.WrongAnchor.selector, other, p)
        );
        _refuseUpdate(
            v,
            _values(e, other, e, p, 0, other),
            abi.encodeWithSelector(INearStateVerifier.WrongAnchor.selector, e, other)
        );
        bytes memory bad = abi.encodeWithSelector(INearStateVerifier.BadPublicValues.selector);
        _refuseUpdate(v, abi.encode(e, p, e, p, uint256(0), uint256(1), uint256(2)), bad);
        _refuseUpdate(v, _values(e, p, other, p, 0, other), bad);
        _refuseUpdate(v, _values(e, p, e, other, 0, other), bad);

        uint256 future = (block.timestamp + 1) * NS;
        _refuseUpdate(
            v,
            _values(e, p, other, other, future, other),
            abi.encodeWithSelector(INearStateVerifier.NamedInTheFuture.selector, future)
        );
        bytes memory pv = _values(e, p, other, other, block.timestamp * NS + NS - 1, other);
        v.update(pv, sp1.prove(KEY, pv));
        assertEq(v.namedAt(), block.timestamp * NS + NS - 1);
    }

    /// @dev `update` with values the mocked zkVM accepts, which the verifier must still refuse with `error`.
    function _refuseUpdate(NearStateVerifier v, bytes memory pv, bytes memory error) internal {
        bytes memory proof = sp1.prove(KEY, pv);
        vm.expectRevert(error);
        v.update(pv, proof);
    }

    /// @dev A proof inside one epoch records its head and leaves the producers and their time as they were.
    function test_update_withinAnEpoch() public {
        NearStateVerifier v = _deploy("xindex-vault.near");
        _recordSyntheticHead(v);
        assertEq(v.epochId(), vm.parseJsonBytes32(json, ".anchor.epoch_id"));
        assertEq(v.namedAt(), _named());
        INearStateVerifier.Head memory h = v.head(vm.parseJsonBytes32(json, ".synthetic.head.block_merkle_root"));
        assertEq(h.height, vm.parseJsonUint(json, ".synthetic.head.height"));
    }

    // ---------------------------------------------------------------------
    // a real receipt under the real head
    // ---------------------------------------------------------------------

    /// @dev A real `intents.near` receipt, proven through every hash a vault's `attest` takes: its outcome, its chunk's
    ///      and block's outcome roots, its block, and the head's `block_merkle_root`. It ran a block before the one
    ///      whose outcome root holds it.
    function test_proveOutcome_aRealReceipt() public {
        NearStateVerifierHarness v = _deploy("xindex-vault.near");
        _recordRealHead(v);
        INearStateVerifier.AttestProof memory p = _real();
        assertEq(p.height + 1, p.blockHeader.innerLite.height, "it ran in the block before");
        v.proveOutcome(p, _realExecutor(), _realValue());
    }

    function _refused(
        NearStateVerifierHarness v,
        INearStateVerifier.AttestProof memory p,
        bytes memory executor,
        bytes memory value,
        bytes4 error
    ) internal {
        vm.expectRevert(error);
        v.proveOutcome(p, executor, value);
    }

    /// @dev Anything else than what ran, where it ran, under the recorded head, is refused: every field of the outcome,
    ///      every step of each path, every field of the block, and an unrecorded head.
    function test_proveOutcome_refusesAnythingElse() public {
        NearStateVerifierHarness v = _deploy("xindex-vault.near");
        _recordRealHead(v);
        bytes memory ex = _realExecutor();
        bytes memory val = _realValue();
        bytes4 notOutcome = INearStateVerifier.NotTheOutcome.selector;
        bytes4 notUnder = INearStateVerifier.NotUnderHead.selector;

        _refused(v, _real(), bytes("intents.near2"), val, notOutcome);
        _refused(v, _real(), ex, bytes.concat(val, hex"00"), notOutcome);
        INearStateVerifier.AttestProof memory p = _real();
        p.receiptId = keccak256("another receipt");
        _refused(v, p, ex, val, notOutcome);
        p = _real();
        p.gasBurnt += 1;
        _refused(v, p, ex, val, notOutcome);
        p = _real();
        p.tokensBurnt += 1;
        _refused(v, p, ex, val, notOutcome);
        p = _real();
        p.logs = new bytes[](0);
        _refused(v, p, ex, val, notOutcome);
        p = _real();
        p.receiptIds = new bytes32[](1);
        _refused(v, p, ex, val, notOutcome);
        p = _real();
        p.outcomePath[0].hash ^= bytes32(uint256(1));
        _refused(v, p, ex, val, notOutcome);
        p = _real();
        p.outcomePath[0].left = !p.outcomePath[0].left;
        _refused(v, p, ex, val, notOutcome);
        p = _real();
        p.outcomeRootPath[0].hash ^= bytes32(uint256(1));
        _refused(v, p, ex, val, notOutcome);
        p = _real();
        p.blockHeader.innerLite.outcomeRoot ^= bytes32(uint256(1));
        _refused(v, p, ex, val, notOutcome);

        p = _real();
        p.blockHeader.innerRestHash ^= bytes32(uint256(1));
        _refused(v, p, ex, val, notUnder);
        p = _real();
        p.blockHeader.prevBlockHash ^= bytes32(uint256(1));
        _refused(v, p, ex, val, notUnder);
        p = _real();
        p.blockHeader.innerLite.blockMerkleRoot ^= bytes32(uint256(1));
        _refused(v, p, ex, val, notUnder);
        p = _real();
        p.blockHeader.innerLite.timestamp += 1;
        _refused(v, p, ex, val, notUnder);
        p = _real();
        p.blockPath[3].hash ^= bytes32(uint256(1));
        _refused(v, p, ex, val, notUnder);
        p = _real();
        p.blockPath[3].left = !p.blockPath[3].left;
        _refused(v, p, ex, val, notUnder);

        // The run must come before the block whose outcome root holds it, in height and in time.
        p = _real();
        p.height = p.blockHeader.innerLite.height;
        _refused(v, p, ex, val, notOutcome);
        p = _real();
        p.timestamp = p.blockHeader.innerLite.timestamp;
        _refused(v, p, ex, val, notOutcome);

        p = _real();
        p.head = keccak256("a head nobody recorded");
        vm.expectRevert(abi.encodeWithSelector(INearStateVerifier.UnknownHead.selector, p.head));
        v.proveOutcome(p, ex, val);
    }

    // ---------------------------------------------------------------------
    // a vault's attest, end to end
    // ---------------------------------------------------------------------

    /// @dev The vault's record is the interfaces doc's encoding, as the generator writes it independently; a proof of it
    ///      gives the hub the slots' values and the vault's own height and time, in seconds.
    function test_verifySlots_aVaultsAttest() public {
        NearStateVerifier v = _deploy("xindex-vault.near");
        _recordSyntheticHead(v);
        INearStateVerifier.AttestProof memory p = _synthetic();
        bytes32[] memory slots = _slots();
        assertEq(v.attestRecord(p.height, p.timestamp, slots, p.values), vm.parseJsonBytes(json, ".synthetic.record"));
        address account = address(uint160(uint256(v.VAULT_ID())));
        (uint256 height, uint256 time, bytes32[] memory values) = v.verifySlots(account, slots, abi.encode(p));
        assertEq(height, p.height);
        assertEq(time, p.timestamp / NS);
        assertEq(values.length, 2);
        assertEq(values[0], p.values[0]);
        assertEq(values[1], p.values[1]);
    }

    function test_verifySlots_refusals() public {
        NearStateVerifier v = _deploy("xindex-vault.near");
        _recordSyntheticHead(v);
        INearStateVerifier.AttestProof memory p = _synthetic();
        bytes32[] memory slots = _slots();
        address account = address(uint160(uint256(v.VAULT_ID())));

        vm.expectRevert(abi.encodeWithSelector(INearStateVerifier.WrongAccount.selector, address(1)));
        v.verifySlots(address(1), slots, abi.encode(p));

        bytes32[] memory one = new bytes32[](1);
        one[0] = slots[0];
        vm.expectRevert(INearStateVerifier.LengthMismatch.selector);
        v.verifySlots(account, one, abi.encode(p));

        // Other slots, other values, or another time than the vault recorded: not what it returned.
        bytes32[] memory swapped = new bytes32[](2);
        (swapped[0], swapped[1]) = (slots[1], slots[0]);
        vm.expectRevert(INearStateVerifier.NotTheOutcome.selector);
        v.verifySlots(account, swapped, abi.encode(p));
        p.values[0] = bytes32(0);
        vm.expectRevert(INearStateVerifier.NotTheOutcome.selector);
        v.verifySlots(account, slots, abi.encode(p));
        p = _synthetic();
        p.timestamp += 1;
        vm.expectRevert(INearStateVerifier.NotTheOutcome.selector);
        v.verifySlots(account, slots, abi.encode(p));

        // Another vault's verifier takes none of this vault's records.
        NearStateVerifier w = _deploy("another-vault.near");
        _recordSyntheticHead(w);
        p = _synthetic();
        address other = address(uint160(uint256(w.VAULT_ID())));
        vm.expectRevert(INearStateVerifier.NotTheOutcome.selector);
        w.verifySlots(other, slots, abi.encode(p));
    }

    /// @dev What each call costs: an update of mainnet's chain, and a vault's two-slot attest proven.
    function test_gas() public {
        NearStateVerifier v = _deploy("xindex-vault.near");
        bytes memory pv = vm.parseJsonBytes(json, ".public_values");
        bytes memory proof = sp1.prove(KEY, pv);
        vm.warp(vm.parseJsonUint(json, ".blocks[1].inner_lite.timestamp") / NS + 60);
        uint256 before = gasleft();
        v.update(pv, proof);
        emit log_named_uint("update, Groth16 mocked", before - gasleft());

        NearStateVerifier w = _deploy("xindex-vault.near");
        _recordSyntheticHead(w);
        bytes memory attest = abi.encode(_synthetic());
        bytes32[] memory slots = _slots();
        address account = address(uint160(uint256(w.VAULT_ID())));
        before = gasleft();
        w.verifySlots(account, slots, attest);
        emit log_named_uint("verifySlots, two slots", before - gasleft());

        NearStateVerifierHarness x = _deploy("xindex-vault.near");
        _recordRealHead(x);
        INearStateVerifier.AttestProof memory real = _real();
        bytes memory ex = _realExecutor();
        bytes memory val = _realValue();
        before = gasleft();
        x.proveOutcome(real, ex, val);
        emit log_named_uint("a real receipt under a real head (19-step block path)", before - gasleft());
    }
}
