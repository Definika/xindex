// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AptosStateVerifier} from "../src/verifiers/AptosStateVerifier.sol";
import {IAptosStateVerifier} from "../src/interfaces/IAptosStateVerifier.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";

/// @notice Aptos's state verifier on the public values its program commits (`proofs/aptos`): an update across two
///         epoch changes, and two vault slots proven by the vault's `Attested` event. No vault exists on Aptos yet, so
///         no real `attest` does: these values come from `proofs/aptos/fixtures/synthetic.json`, a SYNTHETIC chain
///         signed with test keys, which the Rust statement, its SP1 program in execute mode and the fixture's separate
///         Python implementation all agree on. Every piece of the statement is also checked natively on mainnet's own
///         epoch changes, ledger info, transaction and events (`proofs/aptos/fixtures/mainnet.json`). The Groth16
///         check is mocked; what the verifier does with a proven statement is not. The deployment anchor is real
///         (`test/fixtures/aptos/anchor.json`).
contract AptosStateVerifierTest is Test {
    string constant FIXTURE = "proofs/aptos/fixtures/synthetic.json";
    string constant ANCHOR = "test/fixtures/aptos/anchor.json";
    bytes32 constant KEY = keccak256("the Aptos program");
    /// @notice Aptos's registry ids: the first 8 bytes of `keccak256` of `aptos:1` and `aptos:2`.
    uint256 constant APTOS = 549304973309166888;
    uint256 constant APTOS_TESTNET = 10134113455198361380;

    MockSP1Verifier sp1;
    AptosStateVerifier verifier;
    string json;

    uint64 trustedEpoch;
    bytes32 trustedSet;
    uint64 trustedTime;
    bytes32 package;
    bytes32 vaultId;
    address vault;
    bytes32[] slots;
    bytes32[] values;
    bytes updateValues;
    bytes slotsValues;

    function setUp() public {
        sp1 = new MockSP1Verifier();
        json = vm.readFile(FIXTURE);
        trustedEpoch = uint64(vm.parseJsonUint(json, ".verifier.trusted_epoch"));
        trustedSet = vm.parseJsonBytes32(json, ".verifier.trusted_set");
        trustedTime = uint64(vm.parseJsonUint(json, ".verifier.trusted_time"));
        package = vm.parseJsonBytes32(json, ".verifier.package");
        vaultId = vm.parseJsonBytes32(json, ".verifier.vault_id");
        vault = address(uint160(uint256(vaultId)));
        slots = vm.parseJsonBytes32Array(json, ".slots.slots");
        values = vm.parseJsonBytes32Array(json, ".slots.values");
        updateValues = vm.parseJsonBytes(json, ".public_values.update");
        slotsValues = vm.parseJsonBytes(json, ".public_values.slots");
        verifier = _deploy(APTOS);
        vm.warp(_realUpdate().time / 1e6 + 600);
    }

    function _deploy(uint256 chainId) internal returns (AptosStateVerifier) {
        return new AptosStateVerifier(sp1, KEY, chainId, package, vaultId, trustedEpoch, trustedSet, trustedTime);
    }

    /// @dev The mock's proof of `pv`, written here as `MockSP1Verifier.prove` writes it, so that building a proof makes
    ///      no call that an `expectRevert` before it would take for its own.
    function _mock(bytes memory pv) internal pure returns (bytes memory) {
        return abi.encode(keccak256(abi.encode(KEY, pv)));
    }

    function _slotsProof(bytes memory pv, bytes32[] memory vals) internal pure returns (bytes memory) {
        return abi.encode(IAptosStateVerifier.SlotsProof({publicValues: pv, proof: _mock(pv), values: vals}));
    }

    function _realUpdate() internal view returns (IAptosStateVerifier.UpdateValues memory) {
        return abi.decode(updateValues, (IAptosStateVerifier.UpdateValues));
    }

    function _realSlots() internal view returns (IAptosStateVerifier.SlotsValues memory) {
        return abi.decode(slotsValues, (IAptosStateVerifier.SlotsValues));
    }

    // ---------------------------------------------------------------------
    // deployment
    // ---------------------------------------------------------------------

    function test_constructor() public {
        assertEq(address(verifier.SP1_VERIFIER()), address(sp1));
        assertEq(verifier.PROGRAM_KEY(), KEY);
        assertEq(verifier.CHAIN_ID(), APTOS);
        assertEq(verifier.PACKAGE(), package);
        assertEq(verifier.VAULT_ID(), vaultId);
        assertEq(verifier.latestEpoch(), trustedEpoch);
        IAptosStateVerifier.Trusted memory t = verifier.trusted(trustedEpoch);
        assertEq(t.set, trustedSet);
        assertEq(t.time, trustedTime);
        assertEq(verifier.trusted(trustedEpoch + 1).set, bytes32(0));
        assertEq(verifier.MAX_LAG(), 1 days);
        assertEq(verifier.UPDATE(), keccak256("xindex.v4.aptos.update"));
        assertEq(verifier.SLOTS(), keccak256("xindex.v4.aptos.slots"));
        assertEq(uint64(bytes8(keccak256("aptos:1"))), APTOS);
        assertEq(uint64(bytes8(keccak256("aptos:2"))), APTOS_TESTNET);
        assertEq(vm.parseJsonUint(json, ".verifier.chain_id"), APTOS);

        vm.expectEmit();
        emit IAptosStateVerifier.Trusts(trustedEpoch, trustedSet, trustedTime);
        _deploy(APTOS);

        (bytes32 p, bytes32 v, bytes32 s) = (package, vaultId, trustedSet);
        bytes4 zero = IAptosStateVerifier.ZeroValue.selector;
        vm.expectRevert(zero);
        new AptosStateVerifier(ISP1Verifier(address(0)), KEY, APTOS, p, v, 1, s, 1);
        vm.expectRevert(zero);
        new AptosStateVerifier(sp1, bytes32(0), APTOS, p, v, 1, s, 1);
        vm.expectRevert(zero);
        new AptosStateVerifier(sp1, KEY, 0, p, v, 1, s, 1);
        vm.expectRevert(zero);
        new AptosStateVerifier(sp1, KEY, APTOS, bytes32(0), v, 1, s, 1);
        vm.expectRevert(zero);
        new AptosStateVerifier(sp1, KEY, APTOS, p, bytes32(0), 1, s, 1);
        vm.expectRevert(zero);
        new AptosStateVerifier(sp1, KEY, APTOS, p, v, 0, s, 1);
        vm.expectRevert(zero);
        new AptosStateVerifier(sp1, KEY, APTOS, p, v, 1, bytes32(0), 1);
        vm.expectRevert(zero);
        new AptosStateVerifier(sp1, KEY, APTOS, p, v, 1, s, 0);
    }

    /// @dev The real anchor `DeployStateVerifier` deploys from: mainnet's epoch in force when it was written, its set
    ///      read from the chain's own `ValidatorSet` and checked against the backup's epoch-ending ledger info.
    function test_constructor_fromTheRealAnchor() public {
        string memory a = vm.readFile(ANCHOR);
        assertEq(vm.parseJsonUint(a, ".chainId"), APTOS);
        uint64 epoch = uint64(vm.parseJsonUint(a, ".epoch"));
        bytes32 set = vm.parseJsonBytes32(a, ".set");
        uint64 time = uint64(vm.parseJsonUint(a, ".time"));
        assertGt(epoch, 17_000);
        assertGt(time, 1_790_000_000 * 1e6, "microseconds");
        AptosStateVerifier v = new AptosStateVerifier(sp1, KEY, APTOS, package, vaultId, epoch, set, time);
        assertEq(v.latestEpoch(), epoch);
        IAptosStateVerifier.Trusted memory t = v.trusted(epoch);
        assertEq(t.set, set);
        assertEq(t.time, time);
    }

    // ---------------------------------------------------------------------
    // following Aptos
    // ---------------------------------------------------------------------

    /// @dev The verifier trusts the new set at its epoch and keeps trusting the anchor; the same proof never runs
    ///      twice, since an update starts from the latest set only.
    function test_update_followsTheChain() public {
        IAptosStateVerifier.UpdateValues memory u = _realUpdate();
        assertEq(u.kind, verifier.UPDATE());
        assertEq(u.trustedEpoch, trustedEpoch);
        assertEq(u.trustedSet, trustedSet);
        assertEq(u.epoch, trustedEpoch + 2, "two epoch changes in one proof");
        assertEq(u.set, vm.parseJsonBytes32(json, ".verifier.new_set"));
        assertEq(u.time, vm.parseJsonUint(json, ".verifier.new_time"));

        bytes memory proof = sp1.prove(KEY, updateValues);
        vm.expectEmit(address(verifier));
        emit IAptosStateVerifier.Trusts(u.epoch, u.set, u.time);
        verifier.update(updateValues, proof);
        assertEq(verifier.latestEpoch(), u.epoch);
        IAptosStateVerifier.Trusted memory t = verifier.trusted(u.epoch);
        assertEq(t.set, u.set);
        assertEq(t.time, u.time);
        assertEq(verifier.trusted(trustedEpoch).set, trustedSet, "the anchor stays trusted");

        vm.expectRevert(abi.encodeWithSelector(IAptosStateVerifier.WrongAnchor.selector, trustedEpoch, trustedSet));
        verifier.update(updateValues, proof);
    }

    /// @dev A day after the latest trusted set was named, nothing advances the verifier again.
    function test_update_stopsForGoodADayBehind() public {
        bytes memory proof = sp1.prove(KEY, updateValues);
        uint256 ends = uint256(trustedTime) / 1e6 + 1 days;
        vm.warp(ends + 1);
        vm.expectRevert(abi.encodeWithSelector(IAptosStateVerifier.TooOld.selector, trustedTime));
        verifier.update(updateValues, proof);
        vm.warp(ends);
        verifier.update(updateValues, proof);
    }

    /// @dev `update` with values the mocked zkVM accepts, which the verifier must still refuse with `error`.
    function _refuseUpdate(IAptosStateVerifier.UpdateValues memory u, bytes memory error) internal {
        _refuseUpdateRaw(abi.encode(u), error);
    }

    function _refuseUpdateRaw(bytes memory pv, bytes memory error) internal {
        bytes memory proof = _mock(pv);
        vm.expectRevert(error);
        verifier.update(pv, proof);
    }

    /// @dev Only proven values of the update claim, from the latest set, rising, and never dated after now.
    function test_update_refusals() public {
        bytes memory otherProgram = sp1.prove(keccak256("another program"), updateValues);
        vm.expectRevert(MockSP1Verifier.Rejected.selector);
        verifier.update(updateValues, otherProgram);

        bytes memory bad = abi.encodeWithSelector(IAptosStateVerifier.BadPublicValues.selector);
        _refuseUpdateRaw(abi.encodePacked(updateValues, uint256(0)), bad);
        _refuseUpdateRaw(slotsValues, bad);
        IAptosStateVerifier.UpdateValues memory u = _realUpdate();
        u.kind = verifier.SLOTS();
        _refuseUpdate(u, bad);

        bytes4 anchor = IAptosStateVerifier.WrongAnchor.selector;
        u = _realUpdate();
        u.trustedEpoch = trustedEpoch - 1;
        _refuseUpdate(u, abi.encodeWithSelector(anchor, u.trustedEpoch, u.trustedSet));
        u = _realUpdate();
        u.trustedSet = keccak256("another set");
        _refuseUpdate(u, abi.encodeWithSelector(anchor, u.trustedEpoch, u.trustedSet));

        // An epoch that does not rise past the trusted one.
        u = _realUpdate();
        u.epoch = trustedEpoch;
        _refuseUpdate(u, bad);
        u.epoch = trustedEpoch - 1;
        _refuseUpdate(u, bad);

        // Named in a second after this block's, or in it.
        u = _realUpdate();
        u.time = uint64((block.timestamp + 1) * 1e6);
        _refuseUpdate(u, abi.encodeWithSelector(IAptosStateVerifier.InTheFuture.selector, u.time));
        u.time = uint64(block.timestamp * 1e6 + 999_999);
        bytes memory pv = abi.encode(u);
        verifier.update(pv, sp1.prove(KEY, pv));
        assertEq(verifier.trusted(u.epoch).time, u.time);
    }

    // ---------------------------------------------------------------------
    // proving slots
    // ---------------------------------------------------------------------

    /// @dev The vault's two slots, an intake digest and the snapshot root, from the anchor across two epoch changes:
    ///      the hub gets the values, the version of the transaction whose `attest` succeeded, and the vault's time in
    ///      seconds.
    function test_verifySlots() public view {
        IAptosStateVerifier.SlotsValues memory s = _realSlots();
        assertEq(s.kind, verifier.SLOTS());
        assertEq(s.chainId, APTOS);
        assertEq(s.trustedEpoch, trustedEpoch);
        assertEq(s.trustedSet, trustedSet);
        assertEq(s.package, package);
        assertEq(s.vaultId, vaultId);
        assertEq(s.version, vm.parseJsonUint(json, ".slots.transaction.version"));
        assertEq(s.timestamp, vm.parseJsonUint(json, ".slots.timestamp"));
        assertEq(s.slotsHash, keccak256(abi.encode(slots, values)));
        assertEq(slots[1], bytes32(uint256(25)), "the snapshot root's slot");
        (uint256 n, uint256 t, bytes32[] memory got) =
            verifier.verifySlots(vault, slots, _slotsProof(slotsValues, values));
        assertEq(n, s.version);
        assertEq(t, s.timestamp / 1e6);
        assertGt(t, trustedTime / 1e6);
        assertEq(got.length, 2);
        assertEq(got[0], values[0]);
        assertEq(got[1], bytes32(0));
    }

    /// @dev A proof of slots starts from any set the verifier trusts, so one built from the anchor still holds after an
    ///      update moved the latest set on, until the anchor's naming is a day old.
    function test_verifySlots_outlivesAnUpdate() public {
        verifier.update(updateValues, sp1.prove(KEY, updateValues));
        bytes memory proof = _slotsProof(slotsValues, values);
        verifier.verifySlots(vault, slots, proof);
        vm.warp(uint256(trustedTime) / 1e6 + 1 days);
        verifier.verifySlots(vault, slots, proof);
        vm.warp(uint256(trustedTime) / 1e6 + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IAptosStateVerifier.TooOld.selector, trustedTime));
        verifier.verifySlots(vault, slots, proof);
    }

    function _refuseSlots(IAptosStateVerifier.SlotsValues memory s, bytes memory error) internal {
        _refuseSlotsRaw(abi.encode(s), error);
    }

    function _refuseSlotsRaw(bytes memory pv, bytes memory error) internal {
        bytes memory proof = _slotsProof(pv, values);
        vm.expectRevert(error);
        verifier.verifySlots(vault, slots, proof);
    }

    function test_verifySlots_refusals() public {
        bytes memory proof = _slotsProof(slotsValues, values);
        vm.expectRevert(abi.encodeWithSelector(IAptosStateVerifier.WrongAccount.selector, address(1)));
        verifier.verifySlots(address(1), slots, proof);

        bytes32[] memory one = new bytes32[](1);
        one[0] = values[0];
        bytes memory short = _slotsProof(slotsValues, one);
        vm.expectRevert(IAptosStateVerifier.LengthMismatch.selector);
        verifier.verifySlots(vault, slots, short);

        bytes memory otherProgram = abi.encode(
            IAptosStateVerifier.SlotsProof({
                publicValues: slotsValues, proof: sp1.prove(keccak256("another program"), slotsValues), values: values
            })
        );
        vm.expectRevert(MockSP1Verifier.Rejected.selector);
        verifier.verifySlots(vault, slots, otherProgram);

        bytes memory bad = abi.encodeWithSelector(IAptosStateVerifier.BadPublicValues.selector);
        _refuseSlotsRaw(updateValues, bad);
        _refuseSlotsRaw(abi.encodePacked(slotsValues, uint256(0)), bad);
        IAptosStateVerifier.SlotsValues memory s = _realSlots();
        s.kind = verifier.UPDATE();
        _refuseSlots(s, bad);

        s = _realSlots();
        s.chainId = uint64(APTOS_TESTNET);
        _refuseSlots(s, abi.encodeWithSelector(IAptosStateVerifier.WrongChain.selector, APTOS_TESTNET));

        bytes4 unknown = IAptosStateVerifier.UnknownAnchor.selector;
        s = _realSlots();
        s.trustedEpoch = trustedEpoch + 1;
        _refuseSlots(s, abi.encodeWithSelector(unknown, s.trustedEpoch));
        // An unknown epoch claimed with the zero set, which is what the verifier reads for one it never trusted.
        s.trustedSet = bytes32(0);
        _refuseSlots(s, abi.encodeWithSelector(unknown, s.trustedEpoch));
        s = _realSlots();
        s.trustedSet = keccak256("another set");
        _refuseSlots(s, abi.encodeWithSelector(unknown, s.trustedEpoch));

        s = _realSlots();
        s.package = keccak256("another package");
        _refuseSlots(s, abi.encodeWithSelector(IAptosStateVerifier.WrongPackage.selector, s.package));
        s = _realSlots();
        s.vaultId = bytes32(uint256(vaultId) ^ (1 << 255));
        _refuseSlots(s, abi.encodeWithSelector(IAptosStateVerifier.WrongVault.selector, s.vaultId));

        // The vault's record dated in a second after this block's.
        s = _realSlots();
        vm.warp(s.timestamp / 1e6 - 1);
        _refuseSlotsRaw(slotsValues, abi.encodeWithSelector(IAptosStateVerifier.InTheFuture.selector, s.timestamp));
        vm.warp(s.timestamp / 1e6);
        verifier.verifySlots(vault, slots, proof);
    }

    /// @dev The slots hash fixes the slots, their order and the values: a proof of one claim answers nothing else.
    function test_verifySlots_onlyTheProvenSlotsAndValues() public {
        bytes32 slotsHash = _realSlots().slotsHash;
        bytes memory notProven = abi.encodeWithSelector(IAptosStateVerifier.NotProven.selector, slotsHash);
        bytes32[] memory otherValues = new bytes32[](2);
        otherValues[0] = values[0];
        otherValues[1] = bytes32(uint256(1));
        bytes memory proof = _slotsProof(slotsValues, otherValues);
        vm.expectRevert(notProven);
        verifier.verifySlots(vault, slots, proof);

        bytes32[] memory reordered = new bytes32[](2);
        (reordered[0], reordered[1]) = (slots[1], slots[0]);
        bytes32[] memory swapped = new bytes32[](2);
        (swapped[0], swapped[1]) = (values[1], values[0]);
        proof = _slotsProof(slotsValues, swapped);
        vm.expectRevert(notProven);
        verifier.verifySlots(vault, reordered, proof);

        bytes32[] memory first = new bytes32[](1);
        first[0] = slots[0];
        bytes32[] memory firstValue = new bytes32[](1);
        firstValue[0] = values[0];
        proof = _slotsProof(slotsValues, firstValue);
        vm.expectRevert(notProven);
        verifier.verifySlots(vault, first, proof);
    }

    /// @dev Each verifier is for one chain: mainnet's record is no proof to a verifier of testnet, and testnet's sets
    ///      are other sets, so an update from mainnet's starts from no set it trusts.
    function test_onlyThisChain() public {
        AptosStateVerifier other = _deploy(APTOS_TESTNET);
        bytes memory proof = _slotsProof(slotsValues, values);
        vm.expectRevert(abi.encodeWithSelector(IAptosStateVerifier.WrongChain.selector, APTOS));
        other.verifySlots(vault, slots, proof);

        bytes32 testnetSet = keccak256("testnet's validators");
        AptosStateVerifier testnet =
            new AptosStateVerifier(sp1, KEY, APTOS_TESTNET, package, vaultId, trustedEpoch, testnetSet, trustedTime);
        bytes memory updateProof = _mock(updateValues);
        vm.expectRevert(abi.encodeWithSelector(IAptosStateVerifier.WrongAnchor.selector, trustedEpoch, trustedSet));
        testnet.update(updateValues, updateProof);
    }

    /// @dev What a transaction sending `data` to the verifier pays, and how much of it is execution. Foundry runs each
    ///      call a test makes as its own transaction (`isolate`), so the measured gas already carries the 21,000 and
    ///      the calldata: `21,000 + max(4 * tokens + execution, 10 * tokens)` under EIP-7623, a token being a zero
    ///      byte or a quarter of a non-zero one.
    function _txGas(bytes memory data) internal returns (uint256 total, uint256 execution) {
        uint256 zeros = 0;
        for (uint256 i = 0; i < data.length; ++i) {
            if (data[i] == 0) ++zeros;
        }
        uint256 tokens = zeros + 4 * (data.length - zeros);
        address target = address(verifier);
        vm.cool(target);
        vm.cool(address(sp1));
        bool ok;
        uint256 before = gasleft();
        // Sent from where it lies: Solidity's `call` would first copy it to the top of this test's memory.
        assembly ("memory-safe") {
            ok := call(gas(), target, 0, add(data, 32), mload(data), 0, 0)
        }
        total = before - gasleft();
        assertTrue(ok);
        assertGt(total, 21_000 + 4 * tokens, "each call runs as a transaction, paying for its calldata");
        execution = total - 21_000 - 4 * tokens;
    }

    /// @dev What each transaction costs, the Groth16 check mocked (SP1's real one adds about 230,000): two slots
    ///      proven, and an update.
    function test_gas() public {
        bytes memory slotsCall = abi.encodeCall(verifier.verifySlots, (vault, slots, _slotsProof(slotsValues, values)));
        bytes memory updateCall = abi.encodeCall(verifier.update, (updateValues, sp1.prove(KEY, updateValues)));
        (uint256 read, uint256 readExecution) = _txGas(slotsCall);
        emit log_named_uint("verifySlots, two slots: gas", read);
        emit log_named_uint("  of which execution", readExecution);
        (uint256 step, uint256 stepExecution) = _txGas(updateCall);
        emit log_named_uint("update: gas", step);
        emit log_named_uint("  of which execution", stepExecution);
        assertEq(verifier.latestEpoch(), _realUpdate().epoch);
    }
}
