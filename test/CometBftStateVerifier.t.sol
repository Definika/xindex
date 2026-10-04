// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CometBftStateVerifier} from "../src/verifiers/CometBftStateVerifier.sol";
import {ICometBftStateVerifier} from "../src/interfaces/ICometBftStateVerifier.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";

/// @notice The CometBFT state verifier on Injective mainnet's own data (`proofs/cometbft/fixtures/injective.json`, which
///         `generate.py` fetches from mainnet's public endpoints and checks with a separate implementation): the
///         statement's public values for an update from a trusted header, across validator-set changes, to header
///         `H+1`, and for two slots of a real contract at block `H`, one present and one absent, as
///         `eth_getStorageAt` reads them. The Groth16 check is mocked; what the verifier does with a proven statement is
///         not.
contract CometBftStateVerifierTest is Test {
    string constant FIXTURE = "proofs/cometbft/fixtures/injective.json";
    bytes32 constant KEY = keccak256("the CometBFT program");
    uint256 constant INJECTIVE = 1776;
    string constant NAME = "injective-1";

    MockSP1Verifier sp1;
    CometBftStateVerifier verifier;
    string json;

    uint64 trustedHeight;
    bytes32 trustedHash;
    uint64 trustedTime;
    uint64 headHeight;
    bytes32 headHash;
    uint64 headTime;
    uint64 stateHeight;
    uint64 stateTime;
    address vault;
    bytes32[] slots;
    bytes32[] values;
    bytes updateValues;
    bytes slotsValues;

    function setUp() public {
        sp1 = new MockSP1Verifier();
        json = vm.readFile(FIXTURE);
        trustedHeight = uint64(vm.parseJsonUint(json, ".trusted.height"));
        trustedHash = vm.parseJsonBytes32(json, ".trusted.hash");
        trustedTime = uint64(vm.parseJsonUint(json, ".trusted.time"));
        headHeight = uint64(vm.parseJsonUint(json, ".head.height"));
        headHash = vm.parseJsonBytes32(json, ".head.hash");
        headTime = uint64(vm.parseJsonUint(json, ".head.time"));
        stateHeight = uint64(vm.parseJsonUint(json, ".state.height"));
        stateTime = uint64(vm.parseJsonUint(json, ".state.time"));
        vault = vm.parseJsonAddress(json, ".state.vault");
        slots.push(vm.parseJsonBytes32(json, ".state.slots[0].slot"));
        slots.push(vm.parseJsonBytes32(json, ".state.slots[1].slot"));
        values.push(vm.parseJsonBytes32(json, ".state.slots[0].value"));
        values.push(vm.parseJsonBytes32(json, ".state.slots[1].value"));
        updateValues = vm.parseJsonBytes(json, ".public_values.update");
        slotsValues = vm.parseJsonBytes(json, ".public_values.slots");
        verifier = _deploy(NAME);
        vm.warp(headTime + 60);
    }

    function _deploy(string memory name) internal returns (CometBftStateVerifier) {
        return new CometBftStateVerifier(sp1, KEY, INJECTIVE, name, vault, trustedHeight, trustedHash, trustedTime);
    }

    /// @dev The mock's proof of `pv`, written here as `MockSP1Verifier.prove` writes it, so that building a proof makes
    ///      no call that an `expectRevert` before it would take for its own.
    function _mock(bytes memory pv) internal pure returns (bytes memory) {
        return abi.encode(keccak256(abi.encode(KEY, pv)));
    }

    function _slotsProof(bytes memory pv, bytes32[] memory vals) internal pure returns (bytes memory) {
        return abi.encode(ICometBftStateVerifier.SlotsProof({publicValues: pv, proof: _mock(pv), values: vals}));
    }

    function _update(ICometBftStateVerifier.UpdateValues memory u) internal pure returns (bytes memory) {
        return abi.encode(u);
    }

    function _slots(ICometBftStateVerifier.SlotsValues memory s) internal pure returns (bytes memory) {
        return abi.encode(s);
    }

    /// @dev The fixture's update and slots, decoded, for tests that change one field.
    function _realUpdate() internal view returns (ICometBftStateVerifier.UpdateValues memory) {
        return abi.decode(updateValues, (ICometBftStateVerifier.UpdateValues));
    }

    function _realSlots() internal view returns (ICometBftStateVerifier.SlotsValues memory) {
        return abi.decode(slotsValues, (ICometBftStateVerifier.SlotsValues));
    }

    // ---------------------------------------------------------------------
    // deployment
    // ---------------------------------------------------------------------

    function test_constructor() public {
        assertEq(address(verifier.SP1_VERIFIER()), address(sp1));
        assertEq(verifier.PROGRAM_KEY(), KEY);
        assertEq(verifier.CHAIN_ID(), INJECTIVE);
        assertEq(verifier.cosmosChainId(), NAME);
        assertEq(verifier.COSMOS_CHAIN_ID_HASH(), keccak256("injective-1"));
        assertEq(verifier.VAULT(), vault);
        assertEq(verifier.latestHash(), trustedHash);
        ICometBftStateVerifier.Trusted memory t = verifier.trusted(trustedHash);
        assertEq(t.height, trustedHeight);
        assertEq(t.time, trustedTime);
        assertEq(verifier.MAX_LAG(), 1 days);
        assertEq(verifier.UPDATE(), keccak256("xindex.v4.cometbft.update"));
        assertEq(verifier.SLOTS(), keccak256("xindex.v4.cometbft.slots"));
        assertEq(vm.parseJsonUint(json, ".evm_chain_id"), INJECTIVE);
        assertEq(vm.parseJsonString(json, ".chain_id"), NAME);

        vm.expectEmit();
        emit ICometBftStateVerifier.Trusts(trustedHeight, trustedHash, trustedTime);
        _deploy(NAME);

        bytes32 h = trustedHash;
        bytes4 zero = ICometBftStateVerifier.ZeroValue.selector;
        vm.expectRevert(zero);
        new CometBftStateVerifier(ISP1Verifier(address(0)), KEY, INJECTIVE, NAME, vault, 1, h, 1);
        vm.expectRevert(zero);
        new CometBftStateVerifier(sp1, bytes32(0), INJECTIVE, NAME, vault, 1, h, 1);
        vm.expectRevert(zero);
        new CometBftStateVerifier(sp1, KEY, 0, NAME, vault, 1, h, 1);
        vm.expectRevert(zero);
        new CometBftStateVerifier(sp1, KEY, INJECTIVE, "", vault, 1, h, 1);
        vm.expectRevert(zero);
        new CometBftStateVerifier(sp1, KEY, INJECTIVE, NAME, address(0), 1, h, 1);
        vm.expectRevert(zero);
        new CometBftStateVerifier(sp1, KEY, INJECTIVE, NAME, vault, 0, h, 1);
        vm.expectRevert(zero);
        new CometBftStateVerifier(sp1, KEY, INJECTIVE, NAME, vault, 1, bytes32(0), 1);
        vm.expectRevert(zero);
        new CometBftStateVerifier(sp1, KEY, INJECTIVE, NAME, vault, 1, h, 0);
    }

    // ---------------------------------------------------------------------
    // following Injective
    // ---------------------------------------------------------------------

    /// @dev Mainnet's hops, half an hour across validator-set changes: the verifier trusts `H+1` and keeps trusting the
    ///      anchor; the same proof never runs twice, since an update starts from the latest header only.
    function test_update_followsMainnet() public {
        ICometBftStateVerifier.UpdateValues memory u = _realUpdate();
        assertEq(u.kind, verifier.UPDATE());
        assertEq(u.chainIdHash, keccak256("injective-1"));
        assertEq(u.trustedHash, trustedHash);
        assertEq(u.hash, headHash);
        assertEq(u.height, headHeight);
        assertEq(u.time, headTime);

        bytes memory proof = sp1.prove(KEY, updateValues);
        vm.expectEmit(address(verifier));
        emit ICometBftStateVerifier.Trusts(headHeight, headHash, headTime);
        verifier.update(updateValues, proof);
        assertEq(verifier.latestHash(), headHash);
        ICometBftStateVerifier.Trusted memory t = verifier.trusted(headHash);
        assertEq(t.height, headHeight);
        assertEq(t.time, headTime);
        assertEq(verifier.trusted(trustedHash).height, trustedHeight, "the anchor stays trusted");

        vm.expectRevert(abi.encodeWithSelector(ICometBftStateVerifier.WrongAnchor.selector, trustedHeight, trustedHash));
        verifier.update(updateValues, proof);
    }

    /// @dev A day after the latest trusted header, nothing advances the verifier again.
    function test_update_stopsForGoodADayBehind() public {
        bytes memory proof = sp1.prove(KEY, updateValues);
        uint256 ends = uint256(trustedTime) + 1 days;
        vm.warp(ends + 1);
        vm.expectRevert(abi.encodeWithSelector(ICometBftStateVerifier.TooOld.selector, trustedTime));
        verifier.update(updateValues, proof);
        vm.warp(ends);
        verifier.update(updateValues, proof);
    }

    /// @dev `update` with values the mocked zkVM accepts, which the verifier must still refuse with `error`.
    function _refuseUpdate(bytes memory pv, bytes memory error) internal {
        bytes memory proof = _mock(pv);
        vm.expectRevert(error);
        verifier.update(pv, proof);
    }

    /// @dev Only proven values of this chain's update claim, from the latest header, rising, and never dated after now.
    function test_update_refusals() public {
        bytes memory otherProgram = sp1.prove(keccak256("another program"), updateValues);
        vm.expectRevert(MockSP1Verifier.Rejected.selector);
        verifier.update(updateValues, otherProgram);

        bytes memory bad = abi.encodeWithSelector(ICometBftStateVerifier.BadPublicValues.selector);
        _refuseUpdate(abi.encodePacked(updateValues, uint256(0)), bad);
        _refuseUpdate(slotsValues, bad);
        ICometBftStateVerifier.UpdateValues memory u = _realUpdate();
        u.kind = verifier.SLOTS();
        _refuseUpdate(_update(u), bad);

        u = _realUpdate();
        u.chainIdHash = keccak256("injective-888");
        _refuseUpdate(_update(u), abi.encodeWithSelector(ICometBftStateVerifier.WrongChain.selector, u.chainIdHash));

        bytes4 anchor = ICometBftStateVerifier.WrongAnchor.selector;
        u = _realUpdate();
        u.trustedHash = keccak256("another header");
        _refuseUpdate(_update(u), abi.encodeWithSelector(anchor, u.trustedHeight, u.trustedHash));
        u = _realUpdate();
        u.trustedHeight += 1;
        _refuseUpdate(_update(u), abi.encodeWithSelector(anchor, u.trustedHeight, u.trustedHash));
        u = _realUpdate();
        u.trustedTime += 1;
        _refuseUpdate(_update(u), abi.encodeWithSelector(anchor, u.trustedHeight, u.trustedHash));

        u = _realUpdate();
        u.height = trustedHeight;
        _refuseUpdate(_update(u), bad);

        u = _realUpdate();
        u.time = uint64(block.timestamp + 1);
        _refuseUpdate(_update(u), abi.encodeWithSelector(ICometBftStateVerifier.InTheFuture.selector, u.time));
        u.time = uint64(block.timestamp);
        bytes memory pv = _update(u);
        verifier.update(pv, sp1.prove(KEY, pv));
        assertEq(verifier.trusted(u.hash).time, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // proving slots
    // ---------------------------------------------------------------------

    /// @dev Mainnet's slots, from the anchor to `H+1`: the hub gets the present slot's value, zero for the absent one,
    ///      and block `H`'s height and time, which the EVM gave block `H`.
    function test_verifySlots_onMainnetValues() public view {
        ICometBftStateVerifier.SlotsValues memory s = _realSlots();
        assertEq(s.kind, verifier.SLOTS());
        assertEq(s.vault, vault);
        assertEq(s.slotsHash, keccak256(abi.encode(slots, values)));
        assertEq(stateHeight + 1, headHeight);
        (uint256 n, uint256 t, bytes32[] memory got) =
            verifier.verifySlots(vault, slots, _slotsProof(slotsValues, values));
        assertEq(n, stateHeight);
        assertEq(t, stateTime);
        assertEq(got.length, 2);
        assertEq(got[0], values[0]);
        assertTrue(got[0] != bytes32(0), "the present slot");
        assertEq(got[1], bytes32(0), "the absent slot");
    }

    /// @dev A proof of slots starts from any header the verifier trusts, so one built from the anchor still holds after
    ///      an update moved the latest header on, until the anchor is a day old.
    function test_verifySlots_outlivesAnUpdate() public {
        verifier.update(updateValues, sp1.prove(KEY, updateValues));
        bytes memory proof = _slotsProof(slotsValues, values);
        verifier.verifySlots(vault, slots, proof);
        vm.warp(uint256(trustedTime) + 1 days);
        verifier.verifySlots(vault, slots, proof);
        vm.warp(uint256(trustedTime) + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ICometBftStateVerifier.TooOld.selector, trustedTime));
        verifier.verifySlots(vault, slots, proof);
    }

    function _refuseSlots(bytes memory pv, bytes memory error) internal {
        bytes memory proof = _slotsProof(pv, values);
        vm.expectRevert(error);
        verifier.verifySlots(vault, slots, proof);
    }

    function test_verifySlots_refusals() public {
        bytes memory proof = _slotsProof(slotsValues, values);
        vm.expectRevert(abi.encodeWithSelector(ICometBftStateVerifier.WrongAccount.selector, address(1)));
        verifier.verifySlots(address(1), slots, proof);

        bytes32[] memory one = new bytes32[](1);
        one[0] = values[0];
        bytes memory short = _slotsProof(slotsValues, one);
        vm.expectRevert(ICometBftStateVerifier.LengthMismatch.selector);
        verifier.verifySlots(vault, slots, short);

        bytes memory otherProgram = abi.encode(
            ICometBftStateVerifier.SlotsProof({
                publicValues: slotsValues, proof: sp1.prove(keccak256("another program"), slotsValues), values: values
            })
        );
        vm.expectRevert(MockSP1Verifier.Rejected.selector);
        verifier.verifySlots(vault, slots, otherProgram);

        bytes memory bad = abi.encodeWithSelector(ICometBftStateVerifier.BadPublicValues.selector);
        _refuseSlots(updateValues, bad);
        _refuseSlots(abi.encodePacked(slotsValues, uint256(0)), bad);
        ICometBftStateVerifier.SlotsValues memory s = _realSlots();
        s.kind = verifier.UPDATE();
        _refuseSlots(_slots(s), bad);

        s = _realSlots();
        s.chainIdHash = keccak256("injective-888");
        _refuseSlots(_slots(s), abi.encodeWithSelector(ICometBftStateVerifier.WrongChain.selector, s.chainIdHash));

        bytes4 unknown = ICometBftStateVerifier.UnknownHeader.selector;
        s = _realSlots();
        s.trustedHash = keccak256("a header nobody trusts");
        _refuseSlots(_slots(s), abi.encodeWithSelector(unknown, s.trustedHash));
        // An unknown header claimed at height and time zero, which is what the verifier reads for one it never trusted.
        s.trustedHeight = 0;
        s.trustedTime = 0;
        _refuseSlots(_slots(s), abi.encodeWithSelector(unknown, s.trustedHash));
        s = _realSlots();
        s.trustedHeight += 1;
        _refuseSlots(_slots(s), abi.encodeWithSelector(unknown, s.trustedHash));
        s = _realSlots();
        s.trustedTime -= 1;
        _refuseSlots(_slots(s), abi.encodeWithSelector(unknown, s.trustedHash));

        s = _realSlots();
        s.vault = address(uint160(vault) ^ 1);
        _refuseSlots(_slots(s), abi.encodeWithSelector(ICometBftStateVerifier.WrongVault.selector, s.vault));

        // Block H dated after this block.
        vm.warp(stateTime - 1);
        _refuseSlots(slotsValues, abi.encodeWithSelector(ICometBftStateVerifier.InTheFuture.selector, stateTime));
    }

    /// @dev The slots hash fixes the slots, their order and the values: a proof of one claim answers nothing else.
    function test_verifySlots_onlyTheProvenSlotsAndValues() public {
        bytes32 slotsHash = _realSlots().slotsHash;
        bytes memory notProven = abi.encodeWithSelector(ICometBftStateVerifier.NotProven.selector, slotsHash);
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

    /// @dev Each verifier is for one CometBFT chain: mainnet's proof is no proof to a verifier of another chain id.
    function test_verifySlots_onlyThisChain() public {
        CometBftStateVerifier other = _deploy("injective-888");
        bytes memory proof = _slotsProof(slotsValues, values);
        vm.expectRevert(abi.encodeWithSelector(ICometBftStateVerifier.WrongChain.selector, keccak256("injective-1")));
        other.verifySlots(vault, slots, proof);
        bytes memory updateProof = _mock(updateValues);
        vm.expectRevert(abi.encodeWithSelector(ICometBftStateVerifier.WrongChain.selector, keccak256("injective-1")));
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

    /// @dev What each transaction costs on mainnet's values, the Groth16 check mocked (SP1's real one adds about
    ///      230,000): two slots proven, and an update.
    function test_gas() public {
        bytes memory slotsCall = abi.encodeCall(verifier.verifySlots, (vault, slots, _slotsProof(slotsValues, values)));
        bytes memory updateCall = abi.encodeCall(verifier.update, (updateValues, sp1.prove(KEY, updateValues)));
        (uint256 read, uint256 readExecution) = _txGas(slotsCall);
        emit log_named_uint("verifySlots, two slots: gas", read);
        emit log_named_uint("  of which execution", readExecution);
        (uint256 step, uint256 stepExecution) = _txGas(updateCall);
        emit log_named_uint("update: gas", step);
        emit log_named_uint("  of which execution", stepExecution);
        assertEq(verifier.latestHash(), headHash);
    }
}
