// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VeChainStateVerifier} from "../src/verifiers/VeChainStateVerifier.sol";
import {IVeChainStateVerifier} from "../src/interfaces/IVeChainStateVerifier.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";

/// @notice VeChain's state verifier on the public values its program commits (`proofs/vechain`): an update to a table
///         attested and vouched for, and two vault slots proven final. No vault and no attester exist on VeChain yet,
///         so no real `attest` call does: these values come from `proofs/vechain/fixtures/synthetic.json`, a SYNTHETIC
///         chain signed with test keys, which the Rust statement, its SP1 program in execute mode and the fixture's
///         separate Python implementation all agree on. Every piece of the statement is also checked natively on
///         mainnet's own blocks, tables and a real call (`proofs/vechain/fixtures/mainnet.json`). The Groth16 check is
///         mocked; what the verifier does with a proven statement is not. The deployment anchor is real
///         (`test/fixtures/vechain/anchor.json`).
contract VeChainStateVerifierTest is Test {
    string constant FIXTURE = "proofs/vechain/fixtures/synthetic.json";
    string constant ANCHOR = "test/fixtures/vechain/anchor.json";
    bytes32 constant KEY = keccak256("the VeChain program");
    /// @notice VeChain mainnet's registry id: its genesis id, which its `CHAINID` returns.
    uint256 constant VECHAIN = 0x00000000851caf3cfdb6e899cf5958bfb1ac3413d346d43539627e6be7ec1b4a;

    MockSP1Verifier sp1;
    VeChainStateVerifier verifier;
    string json;

    bytes32 trustedId;
    uint64 trustedTime;
    bytes32 trustedTable;
    address attester;
    address vault;
    bytes32[] slots;
    bytes32[] values;
    bytes updateValues;
    bytes slotsValues;

    function setUp() public {
        sp1 = new MockSP1Verifier();
        json = vm.readFile(FIXTURE);
        trustedId = vm.parseJsonBytes32(json, ".trusted.id");
        trustedTime = uint64(vm.parseJsonUint(json, ".trusted.time"));
        trustedTable = vm.parseJsonBytes32(json, ".trusted.table.hash");
        attester = vm.parseJsonAddress(json, ".attester");
        vault = vm.parseJsonAddress(json, ".slots.vault");
        slots = vm.parseJsonBytes32Array(json, ".slots.slots");
        values = vm.parseJsonBytes32Array(json, ".slots.values");
        updateValues = vm.parseJsonBytes(json, ".public_values.update");
        slotsValues = vm.parseJsonBytes(json, ".public_values.slots");
        verifier = _deploy(VECHAIN);
        vm.warp(_realUpdate().time + 600);
    }

    function _deploy(uint256 chainId) internal returns (VeChainStateVerifier) {
        return new VeChainStateVerifier(sp1, KEY, chainId, vault, attester, trustedId, trustedTime, trustedTable);
    }

    /// @dev The mock's proof of `pv`, written here as `MockSP1Verifier.prove` writes it, so that building a proof makes
    ///      no call that an `expectRevert` before it would take for its own.
    function _mock(bytes memory pv) internal pure returns (bytes memory) {
        return abi.encode(keccak256(abi.encode(KEY, pv)));
    }

    function _slotsProof(bytes memory pv, bytes32[] memory vals) internal pure returns (bytes memory) {
        return abi.encode(IVeChainStateVerifier.SlotsProof({publicValues: pv, proof: _mock(pv), values: vals}));
    }

    function _realUpdate() internal view returns (IVeChainStateVerifier.UpdateValues memory) {
        return abi.decode(updateValues, (IVeChainStateVerifier.UpdateValues));
    }

    function _realSlots() internal view returns (IVeChainStateVerifier.SlotsValues memory) {
        return abi.decode(slotsValues, (IVeChainStateVerifier.SlotsValues));
    }

    function _number(bytes32 id) internal pure returns (uint64) {
        return uint64(uint256(id) >> 224);
    }

    // ---------------------------------------------------------------------
    // deployment
    // ---------------------------------------------------------------------

    function test_constructor() public {
        assertEq(address(verifier.SP1_VERIFIER()), address(sp1));
        assertEq(verifier.PROGRAM_KEY(), KEY);
        assertEq(verifier.CHAIN_ID(), VECHAIN);
        assertEq(verifier.VAULT(), vault);
        assertEq(verifier.ATTESTER(), attester);
        assertEq(verifier.latestId(), trustedId);
        IVeChainStateVerifier.Trusted memory t = verifier.trusted(trustedId);
        assertEq(t.number, vm.parseJsonUint(json, ".trusted.number"));
        assertEq(t.number, _number(trustedId));
        assertEq(t.time, trustedTime);
        assertEq(t.table, trustedTable);
        assertEq(verifier.MAX_LAG(), 1 days);
        assertEq(verifier.UPDATE(), keccak256("xindex.v4.vechain.update"));
        assertEq(verifier.SLOTS(), keccak256("xindex.v4.vechain.slots"));
        assertEq(vm.parseJsonBytes32(json, ".chain"), bytes32(VECHAIN));

        vm.expectEmit();
        emit IVeChainStateVerifier.Trusts(_number(trustedId), trustedId, trustedTable, trustedTime);
        _deploy(VECHAIN);

        (bytes32 id, bytes32 tb) = (trustedId, trustedTable);
        bytes4 zero = IVeChainStateVerifier.ZeroValue.selector;
        vm.expectRevert(zero);
        new VeChainStateVerifier(ISP1Verifier(address(0)), KEY, VECHAIN, vault, attester, id, 1, tb);
        vm.expectRevert(zero);
        new VeChainStateVerifier(sp1, bytes32(0), VECHAIN, vault, attester, id, 1, tb);
        vm.expectRevert(zero);
        new VeChainStateVerifier(sp1, KEY, 0, vault, attester, id, 1, tb);
        vm.expectRevert(zero);
        new VeChainStateVerifier(sp1, KEY, VECHAIN, address(0), attester, id, 1, tb);
        vm.expectRevert(zero);
        new VeChainStateVerifier(sp1, KEY, VECHAIN, vault, address(0), id, 1, tb);
        // A block id whose number, its first four bytes, is zero: the genesis block or no block.
        vm.expectRevert(zero);
        new VeChainStateVerifier(sp1, KEY, VECHAIN, vault, attester, bytes32(uint256(id) << 32 >> 32), 1, tb);
        vm.expectRevert(zero);
        new VeChainStateVerifier(sp1, KEY, VECHAIN, vault, attester, id, 0, tb);
        vm.expectRevert(zero);
        new VeChainStateVerifier(sp1, KEY, VECHAIN, vault, attester, id, 1, bytes32(0));
    }

    /// @dev The real anchor `DeployStateVerifier` deploys from: mainnet's latest finalized checkpoint when it was
    ///      written, and the Staker's table there.
    function test_constructor_fromTheRealAnchor() public {
        string memory a = vm.readFile(ANCHOR);
        assertEq(vm.parseJsonUint(a, ".chainId"), VECHAIN);
        bytes32 id = vm.parseJsonBytes32(a, ".id");
        uint64 number = uint64(vm.parseJsonUint(a, ".number"));
        assertEq(_number(id), number);
        assertEq(number % 180, 0, "a checkpoint");
        uint64 time = uint64(vm.parseJsonUint(a, ".time"));
        bytes32 table = vm.parseJsonBytes32(a, ".table");
        VeChainStateVerifier v = new VeChainStateVerifier(sp1, KEY, VECHAIN, vault, attester, id, time, table);
        IVeChainStateVerifier.Trusted memory t = v.trusted(id);
        assertEq(t.number, number);
        assertEq(t.time, time);
        assertEq(t.table, table);
    }

    // ---------------------------------------------------------------------
    // following VeChain
    // ---------------------------------------------------------------------

    /// @dev The verifier trusts the new table at its block and keeps trusting the anchor; the same proof never runs
    ///      twice, since an update starts from the latest table only.
    function test_update_followsTheChain() public {
        IVeChainStateVerifier.UpdateValues memory u = _realUpdate();
        assertEq(u.kind, verifier.UPDATE());
        assertEq(uint256(u.chain), VECHAIN);
        assertEq(u.attester, attester);
        assertEq(u.trustedId, trustedId);
        assertEq(u.trustedTable, trustedTable);
        assertGt(_number(u.id), _number(trustedId));

        bytes memory proof = sp1.prove(KEY, updateValues);
        vm.expectEmit(address(verifier));
        emit IVeChainStateVerifier.Trusts(_number(u.id), u.id, u.table, u.time);
        verifier.update(updateValues, proof);
        assertEq(verifier.latestId(), u.id);
        IVeChainStateVerifier.Trusted memory t = verifier.trusted(u.id);
        assertEq(t.number, _number(u.id));
        assertEq(t.time, u.time);
        assertEq(t.table, u.table);
        assertEq(verifier.trusted(trustedId).table, trustedTable, "the anchor stays trusted");

        vm.expectRevert(abi.encodeWithSelector(IVeChainStateVerifier.WrongAnchor.selector, trustedId));
        verifier.update(updateValues, proof);
    }

    /// @dev A day after the latest trusted table's block, nothing advances the verifier again.
    function test_update_stopsForGoodADayBehind() public {
        bytes memory proof = sp1.prove(KEY, updateValues);
        uint256 ends = uint256(trustedTime) + 1 days;
        vm.warp(ends + 1);
        vm.expectRevert(abi.encodeWithSelector(IVeChainStateVerifier.TooOld.selector, trustedTime));
        verifier.update(updateValues, proof);
        vm.warp(ends);
        verifier.update(updateValues, proof);
    }

    /// @dev `update` with values the mocked zkVM accepts, which the verifier must still refuse with `error`.
    function _refuseUpdate(IVeChainStateVerifier.UpdateValues memory u, bytes memory error) internal {
        _refuseUpdateRaw(abi.encode(u), error);
    }

    function _refuseUpdateRaw(bytes memory pv, bytes memory error) internal {
        bytes memory proof = _mock(pv);
        vm.expectRevert(error);
        verifier.update(pv, proof);
    }

    /// @dev Only proven values of this chain's update claim, on this attester, from the latest table, rising, and never
    ///      dated after now.
    function test_update_refusals() public {
        bytes memory otherProgram = sp1.prove(keccak256("another program"), updateValues);
        vm.expectRevert(MockSP1Verifier.Rejected.selector);
        verifier.update(updateValues, otherProgram);

        bytes memory bad = abi.encodeWithSelector(IVeChainStateVerifier.BadPublicValues.selector);
        _refuseUpdateRaw(abi.encodePacked(updateValues, uint256(0)), bad);
        _refuseUpdateRaw(slotsValues, bad);
        IVeChainStateVerifier.UpdateValues memory u = _realUpdate();
        u.kind = verifier.SLOTS();
        _refuseUpdate(u, bad);

        u = _realUpdate();
        u.chain = bytes32(uint256(0x000000000b2bce3c70bc649a02749e8687721b09ed2e15997f466536b20bb127));
        _refuseUpdate(u, abi.encodeWithSelector(IVeChainStateVerifier.WrongChain.selector, u.chain));
        u = _realUpdate();
        u.attester = address(uint160(attester) ^ 1);
        _refuseUpdate(u, abi.encodeWithSelector(IVeChainStateVerifier.WrongAttester.selector, u.attester));

        bytes4 anchor = IVeChainStateVerifier.WrongAnchor.selector;
        u = _realUpdate();
        u.trustedId = keccak256("another block");
        _refuseUpdate(u, abi.encodeWithSelector(anchor, u.trustedId));
        u = _realUpdate();
        u.trustedTable = keccak256("another table");
        _refuseUpdate(u, abi.encodeWithSelector(anchor, u.trustedId));

        // A block that does not rise past the trusted one.
        u = _realUpdate();
        u.id = trustedId;
        _refuseUpdate(u, bad);
        u.id = bytes32(uint256(trustedId) - (1 << 224));
        _refuseUpdate(u, bad);

        u = _realUpdate();
        u.time = uint64(block.timestamp + 1);
        _refuseUpdate(u, abi.encodeWithSelector(IVeChainStateVerifier.InTheFuture.selector, u.time));
        u.time = uint64(block.timestamp);
        bytes memory pv = abi.encode(u);
        verifier.update(pv, sp1.prove(KEY, pv));
        assertEq(verifier.trusted(u.id).time, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // proving slots
    // ---------------------------------------------------------------------

    /// @dev The vault's two slots, its intake digest and the snapshot root, from the anchor: the hub gets the values,
    ///      and the number and time of the block whose `attest` succeeded.
    function test_verifySlots() public view {
        IVeChainStateVerifier.SlotsValues memory s = _realSlots();
        assertEq(s.kind, verifier.SLOTS());
        assertEq(s.vault, vault);
        assertEq(s.trustedId, trustedId);
        assertEq(s.slotsHash, keccak256(abi.encode(slots, values)));
        assertEq(slots[1], bytes32(uint256(25)), "the snapshot root's slot");
        (uint256 n, uint256 t, bytes32[] memory got) =
            verifier.verifySlots(vault, slots, _slotsProof(slotsValues, values));
        assertEq(n, s.number);
        assertGt(n, _number(trustedId));
        assertEq(t, s.time);
        assertEq(got.length, 2);
        assertEq(got[0], values[0]);
        assertEq(got[1], bytes32(0));
    }

    /// @dev A proof of slots starts from any table the verifier trusts, so one built from the anchor still holds after
    ///      an update moved the latest table on, until the anchor's block is a day old.
    function test_verifySlots_outlivesAnUpdate() public {
        verifier.update(updateValues, sp1.prove(KEY, updateValues));
        bytes memory proof = _slotsProof(slotsValues, values);
        verifier.verifySlots(vault, slots, proof);
        vm.warp(uint256(trustedTime) + 1 days);
        verifier.verifySlots(vault, slots, proof);
        vm.warp(uint256(trustedTime) + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IVeChainStateVerifier.TooOld.selector, trustedTime));
        verifier.verifySlots(vault, slots, proof);
    }

    function _refuseSlots(IVeChainStateVerifier.SlotsValues memory s, bytes memory error) internal {
        _refuseSlotsRaw(abi.encode(s), error);
    }

    function _refuseSlotsRaw(bytes memory pv, bytes memory error) internal {
        bytes memory proof = _slotsProof(pv, values);
        vm.expectRevert(error);
        verifier.verifySlots(vault, slots, proof);
    }

    function test_verifySlots_refusals() public {
        bytes memory proof = _slotsProof(slotsValues, values);
        vm.expectRevert(abi.encodeWithSelector(IVeChainStateVerifier.WrongAccount.selector, address(1)));
        verifier.verifySlots(address(1), slots, proof);

        bytes32[] memory one = new bytes32[](1);
        one[0] = values[0];
        bytes memory short = _slotsProof(slotsValues, one);
        vm.expectRevert(IVeChainStateVerifier.LengthMismatch.selector);
        verifier.verifySlots(vault, slots, short);

        bytes memory otherProgram = abi.encode(
            IVeChainStateVerifier.SlotsProof({
                publicValues: slotsValues, proof: sp1.prove(keccak256("another program"), slotsValues), values: values
            })
        );
        vm.expectRevert(MockSP1Verifier.Rejected.selector);
        verifier.verifySlots(vault, slots, otherProgram);

        bytes memory bad = abi.encodeWithSelector(IVeChainStateVerifier.BadPublicValues.selector);
        _refuseSlotsRaw(updateValues, bad);
        _refuseSlotsRaw(abi.encodePacked(slotsValues, uint256(0)), bad);
        IVeChainStateVerifier.SlotsValues memory s = _realSlots();
        s.kind = verifier.UPDATE();
        _refuseSlots(s, bad);

        s = _realSlots();
        s.chain = bytes32(VECHAIN + 1);
        _refuseSlots(s, abi.encodeWithSelector(IVeChainStateVerifier.WrongChain.selector, s.chain));
        s = _realSlots();
        s.attester = address(0xA77E57E5);
        _refuseSlots(s, abi.encodeWithSelector(IVeChainStateVerifier.WrongAttester.selector, s.attester));

        bytes4 unknown = IVeChainStateVerifier.UnknownAnchor.selector;
        s = _realSlots();
        s.trustedId = keccak256("a block nobody trusts");
        _refuseSlots(s, abi.encodeWithSelector(unknown, s.trustedId));
        // An unknown block claimed with the zero table, which is what the verifier reads for one it never trusted.
        s.trustedTable = bytes32(0);
        _refuseSlots(s, abi.encodeWithSelector(unknown, s.trustedId));
        s = _realSlots();
        s.trustedTable = keccak256("another table");
        _refuseSlots(s, abi.encodeWithSelector(unknown, s.trustedId));

        s = _realSlots();
        s.vault = address(uint160(vault) ^ 1);
        _refuseSlots(s, abi.encodeWithSelector(IVeChainStateVerifier.WrongVault.selector, s.vault));

        // The vault's block dated after this block.
        s = _realSlots();
        vm.warp(s.time - 1);
        _refuseSlotsRaw(slotsValues, abi.encodeWithSelector(IVeChainStateVerifier.InTheFuture.selector, s.time));
    }

    /// @dev The slots hash fixes the slots, their order and the values: a proof of one claim answers nothing else.
    function test_verifySlots_onlyTheProvenSlotsAndValues() public {
        bytes32 slotsHash = _realSlots().slotsHash;
        bytes memory notProven = abi.encodeWithSelector(IVeChainStateVerifier.NotProven.selector, slotsHash);
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

    /// @dev Each verifier is for one chain: mainnet's proof is no proof to a verifier of testnet.
    function test_onlyThisChain() public {
        VeChainStateVerifier other = _deploy(0x000000000b2bce3c70bc649a02749e8687721b09ed2e15997f466536b20bb127);
        bytes memory proof = _slotsProof(slotsValues, values);
        vm.expectRevert(abi.encodeWithSelector(IVeChainStateVerifier.WrongChain.selector, bytes32(VECHAIN)));
        other.verifySlots(vault, slots, proof);
        bytes memory updateProof = _mock(updateValues);
        vm.expectRevert(abi.encodeWithSelector(IVeChainStateVerifier.WrongChain.selector, bytes32(VECHAIN)));
        other.update(updateValues, updateProof);
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
        assertEq(verifier.latestId(), _realUpdate().id);
    }
}
