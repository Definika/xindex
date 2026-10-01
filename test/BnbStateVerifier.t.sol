// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BnbStateVerifier} from "../src/verifiers/BnbStateVerifier.sol";
import {IBnbStateVerifier} from "../src/interfaces/IBnbStateVerifier.sol";
import {Bls12381} from "../src/libraries/Bls12381.sol";
import {ProofHarness} from "./mocks/ProofHarness.sol";
import {RlpWriter} from "./utils/RlpWriter.sol";

/// @notice The BNB Chain state verifier on real mainnet data (`test/fixtures/bnb/chain.json`, from `generate.py`): four
///         consecutive epoch blocks with the votes that finalized them, the votes on either side of a real switch, and
///         a storage proof at the head for WBNB. BNB Chain rotates part of its set at every one of these epochs. The
///         BLS precompiles exist from Prague on, so this suite runs on it.
/// forge-config: default.evm_version = "prague"
contract BnbStateVerifierTest is Test {
    string json;
    ProofHarness h;
    BnbStateVerifier verifier;
    uint256[4] epochs;

    uint256 constant EXTRA = 12;
    uint256 constant TIME = 11;

    /// @dev The chain this suite runs on: BNB Chain mainnet here, its testnet in {BnbStateVerifierTestnetTest}.
    function _fixture() internal pure virtual returns (string memory) {
        return "test/fixtures/bnb/chain.json";
    }

    function setUp() public {
        json = vm.readFile(_fixture());
        h = new ProofHarness();
        for (uint256 i = 0; i < 4; ++i) {
            epochs[i] = vm.parseJsonUint(json, _at(i, ".number"));
        }
        verifier = new BnbStateVerifier(_bytes(_at(0, ".rlp")), _keys(_at(0, ".keys")));
    }

    // ---------------------------------------------------------------------
    // fixture readers
    // ---------------------------------------------------------------------

    function _at(uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".epochs[", vm.toString(i), "]", field);
    }

    function _bytes(string memory path) internal view returns (bytes memory) {
        return vm.parseJsonBytes(json, path);
    }

    function _keys(string memory path) internal view returns (bytes[] memory) {
        return vm.parseJsonBytesArray(json, path);
    }

    function _vote(string memory path) internal view returns (IBnbStateVerifier.Vote memory v) {
        v.targetHash = vm.parseJsonBytes32(json, string.concat(path, ".targetHash"));
        v.bitset = vm.parseUint(vm.parseJsonString(json, string.concat(path, ".bitset")));
        v.signature = vm.parseJsonBytes(json, string.concat(path, ".signature"));
    }

    function _step(uint256 i) internal view returns (IBnbStateVerifier.EpochStep memory s) {
        s.header = _bytes(_at(i, ".rlp"));
        s.vote = _vote(_at(i, ".vote"));
        (s.keySources, s.newKeys) = _sources(_keys(_at(i - 1, ".keys")), _keys(_at(i, ".keys")));
    }

    /// @dev Where each of `keys` comes from: its index in `previous`, or NEW_KEY and the next of the returned keys.
    function _sources(bytes[] memory previous, bytes[] memory keys)
        internal
        pure
        returns (bytes memory sources, bytes[] memory fresh)
    {
        sources = new bytes(keys.length);
        bytes[] memory found = new bytes[](keys.length);
        uint256 n = 0;
        for (uint256 i = 0; i < keys.length; ++i) {
            sources[i] = bytes1(type(uint8).max);
            for (uint256 j = 0; j < previous.length; ++j) {
                if (keccak256(previous[j]) == keccak256(keys[i])) sources[i] = bytes1(uint8(j));
            }
            if (uint8(sources[i]) == type(uint8).max) found[n++] = keys[i];
        }
        fresh = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            fresh[i] = found[i];
        }
    }

    function _steps(uint256 from, uint256 to) internal view returns (IBnbStateVerifier.EpochStep[] memory s) {
        s = new IBnbStateVerifier.EpochStep[](to - from);
        for (uint256 i = from; i < to; ++i) {
            s[i - from] = _step(i);
        }
    }

    function _advanceAll() internal {
        verifier.advance(_keys(_at(0, ".keys")), _steps(1, 4));
    }

    function _stateProof(bytes[] memory accountProof, bytes[][] memory storageProofs)
        internal
        view
        returns (bytes memory)
    {
        uint256 epoch = vm.parseJsonUint(json, ".state.epoch");
        uint256 index = epoch == epochs[3] ? 3 : 2;
        return abi.encode(
            IBnbStateVerifier.StateProof({
                header: _bytes(".state.block.rlp"),
                epoch: epoch,
                vote: _vote(".state.block.vote"),
                keys: _keys(_at(index, ".keys")),
                accountProof: accountProof,
                storageProofs: storageProofs
            })
        );
    }

    /// @dev `header` with field `index` replaced by the string `value`.
    function _withField(bytes memory header, uint256 index, bytes memory value) internal view returns (bytes memory) {
        uint256 n = h.count(header);
        bytes[] memory fields = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            fields[i] = RlpWriter.str(i == index ? value : h.at(header, i));
        }
        return RlpWriter.list(fields);
    }

    function _extra(bytes memory header) internal view returns (bytes memory) {
        return h.at(header, EXTRA);
    }

    // ---------------------------------------------------------------------
    // the first set
    // ---------------------------------------------------------------------

    function test_deploy_recordsTheFirstSet() public view {
        IBnbStateVerifier.ValidatorSet memory set = verifier.validatorSet(epochs[0]);
        bytes[] memory keys = _keys(_at(0, ".keys"));
        assertEq(verifier.latestEpoch(), epochs[0]);
        assertEq(set.keysHash, keccak256(abi.encode(keys)));
        assertEq(set.count, keys.length);
        assertEq(set.count, vm.parseJsonUint(json, _at(0, ".count")));
        assertEq(set.turnLength, vm.parseJsonUint(json, _at(0, ".turnLength")));
        assertEq(set.time, vm.parseJsonUint(json, _at(0, ".time")));
        assertEq(set.firstTarget, epochs[0] + 1000, "certainly signing from its successor's epoch block");
        assertEq(verifier.windowEnd(epochs[0]), vm.parseJsonUint(json, _at(1, ".firstTarget")));
        assertEq(verifier.EPOCH_LENGTH(), 1000);
        assertEq(verifier.MAX_SPAN(), 15 minutes);
        assertEq(verifier.MAX_LAG(), 1 days);
    }

    /// @dev Every header is built before `expectRevert`, which the harness calls building it would otherwise consume.
    function test_deploy_refusesWhatIsNotAnEpochSet() public {
        bytes memory header = _bytes(_at(0, ".rlp"));
        bytes[] memory keys = _keys(_at(0, ".keys"));
        bytes memory extra = _extra(header);
        uint256 n = keys.length;

        bytes memory none = bytes.concat(extra);
        none[32] = 0x00;
        bytes memory tooMany = bytes.concat(extra);
        tooMany[32] = bytes1(uint8(65));
        bytes memory truncated = new bytes(33 + n * 68 + 1 + 64); // one byte short of the seal
        for (uint256 i = 0; i < truncated.length; ++i) {
            truncated[i] = extra[i];
        }
        bytes memory noTurns = bytes.concat(extra);
        noTurns[33 + n * 68] = 0x00;
        // Entries 0 and 1 swapped, with their keys: entry 1's address is now below entry 0's.
        bytes memory swapped = bytes.concat(extra);
        for (uint256 i = 0; i < 68; ++i) {
            (swapped[33 + i], swapped[33 + 68 + i]) = (extra[33 + 68 + i], extra[33 + i]);
        }
        bytes[] memory otherKeys = _keys(_at(0, ".keys"));
        (otherKeys[0], otherKeys[1]) = (otherKeys[1], otherKeys[0]);
        bytes[4] memory badLists = [
            _withField(header, EXTRA, none),
            _withField(header, EXTRA, tooMany),
            _withField(header, EXTRA, truncated),
            _withField(header, EXTRA, noTurns)
        ];
        bytes memory swappedHeader = _withField(header, EXTRA, swapped);

        uint256 notEpoch = vm.parseJsonUint(json, ".switch.before.number");
        vm.expectRevert(abi.encodeWithSelector(IBnbStateVerifier.NotAnEpochBlock.selector, notEpoch));
        new BnbStateVerifier(_bytes(".switch.before.rlp"), keys);
        for (uint256 i = 0; i < badLists.length; ++i) {
            vm.expectRevert(IBnbStateVerifier.BadValidatorList.selector);
            new BnbStateVerifier(badLists[i], keys);
        }
        vm.expectRevert(IBnbStateVerifier.WrongKeys.selector);
        new BnbStateVerifier(header, new bytes[](n - 1));
        vm.expectRevert(Bls12381.BadKey.selector);
        new BnbStateVerifier(header, otherKeys);
        vm.expectRevert(abi.encodeWithSelector(IBnbStateVerifier.NotAscending.selector, 1));
        new BnbStateVerifier(swappedHeader, otherKeys);
    }

    // ---------------------------------------------------------------------
    // following the set
    // ---------------------------------------------------------------------

    /// @dev Each epoch block's set, recorded from the vote of the set it replaces, starts signing where BNB Chain's
    ///      snapshot switches: (n / 2 + 1) * turnLength blocks after its epoch block, with the size and turn length of
    ///      the set it replaces. That is 88 blocks on mainnet (21 validators, turn length 8) and 40 on the testnet (9).
    function test_advance_followsEveryEpoch() public {
        IBnbStateVerifier.EpochStep[] memory steps = _steps(1, 4);
        bytes[] memory voters = _keys(_at(0, ".keys"));
        for (uint256 i = 1; i < 4; ++i) {
            vm.expectEmit(address(verifier));
            emit IBnbStateVerifier.ValidatorSetRecorded(
                epochs[i],
                keccak256(abi.encode(_keys(_at(i, ".keys")))),
                vm.parseJsonUint(json, _at(i, ".firstTarget")),
                vm.parseJsonUint(json, _at(i, ".count")),
                vm.parseJsonUint(json, _at(i, ".turnLength"))
            );
        }
        uint256 before = gasleft();
        verifier.advance(voters, steps);
        console2.log("gas to follow three epochs in one transaction", before - gasleft());
        assertEq(verifier.latestEpoch(), epochs[3]);
        for (uint256 i = 1; i < 4; ++i) {
            console2.log("epoch", epochs[i], "new keys", steps[i - 1].newKeys.length);
            IBnbStateVerifier.ValidatorSet memory set = verifier.validatorSet(epochs[i]);
            assertEq(set.firstTarget, vm.parseJsonUint(json, _at(i, ".firstTarget")));
            uint256 replaced = vm.parseJsonUint(json, _at(i - 1, ".count"));
            assertEq(
                set.firstTarget, epochs[i] + (replaced / 2 + 1) * vm.parseJsonUint(json, _at(i - 1, ".turnLength"))
            );
            assertEq(set.time, vm.parseJsonUint(json, _at(i, ".time")));
        }
    }

    function test_advance_oneEpochAtATime() public {
        IBnbStateVerifier.EpochStep[] memory one = _steps(1, 2);
        uint256 before = gasleft();
        verifier.advance(_keys(_at(0, ".keys")), one);
        console2.log("gas to follow one epoch", before - gasleft());
        verifier.advance(_keys(_at(1, ".keys")), _steps(2, 3));
        assertEq(verifier.latestEpoch(), epochs[2]);
    }

    function test_advance_refusesAnythingButTheNextEpochFinalized() public {
        bytes[] memory voters = _keys(_at(0, ".keys"));
        uint256 n = voters.length;
        // The most voters that are not a quorum: a quorum is at least two thirds of the set.
        uint256 short = (2 * n + 2) / 3 - 1;
        vm.expectRevert(IBnbStateVerifier.WrongKeys.selector);
        verifier.advance(_keys(_at(1, ".keys")), _steps(1, 2));

        vm.expectRevert(abi.encodeWithSelector(IBnbStateVerifier.NotTheNextEpoch.selector, epochs[2], epochs[1]));
        verifier.advance(voters, _steps(2, 3));

        IBnbStateVerifier.EpochStep[] memory s = _steps(1, 2);
        s[0].vote.targetHash = bytes32(uint256(s[0].vote.targetHash) ^ 1);
        vm.expectRevert(IBnbStateVerifier.BadSignature.selector);
        verifier.advance(voters, s);

        s = _steps(1, 2);
        s[0].vote.bitset |= 1 << n;
        vm.expectRevert(IBnbStateVerifier.BadBitset.selector);
        verifier.advance(voters, s);

        s = _steps(1, 2);
        uint256 bits = s[0].vote.bitset;
        uint256 kept = 0;
        uint256 fewer = 0;
        for (uint256 i = 0; i < n && kept < short; ++i) {
            if ((bits >> i) & 1 == 1) {
                fewer |= 1 << i;
                ++kept;
            }
        }
        s[0].vote.bitset = fewer;
        vm.expectRevert(abi.encodeWithSelector(IBnbStateVerifier.NoQuorum.selector, short, n));
        verifier.advance(voters, s);

        s = _steps(1, 2);
        s[0].vote.bitset = bits & (bits - 1); // one voter fewer: still a quorum, no longer their signature
        vm.expectRevert(IBnbStateVerifier.BadSignature.selector);
        verifier.advance(voters, s);

        verifier.advance(voters, _steps(1, 2));
        vm.expectRevert(abi.encodeWithSelector(IBnbStateVerifier.NotTheNextEpoch.selector, epochs[1], epochs[2]));
        verifier.advance(_keys(_at(1, ".keys")), _steps(1, 2));
    }

    /// @dev Each key must come from exactly where the step says: a carried-over key must be the entry's own, every
    ///      new key must be used, and none may be missing.
    function test_advance_keySourcesMustBeExact() public {
        bytes[] memory voters = _keys(_at(0, ".keys"));
        IBnbStateVerifier.EpochStep[] memory s = _steps(1, 2);
        uint256 reused = 0;
        while (uint8(s[0].keySources[reused]) == type(uint8).max) ++reused;
        bytes1 own = s[0].keySources[reused];
        s[0].keySources[reused] = bytes1(uint8(own) == 0 ? 1 : 0); // another carried-over key
        vm.expectRevert(Bls12381.BadKey.selector);
        verifier.advance(voters, s);

        s = _steps(1, 2);
        s[0].keySources[reused] = bytes1(uint8(voters.length)); // just past the set before
        vm.expectRevert(IBnbStateVerifier.WrongKeys.selector);
        verifier.advance(voters, s);

        s = _steps(1, 2);
        bytes[] memory extra = new bytes[](s[0].newKeys.length + 1);
        for (uint256 i = 0; i < s[0].newKeys.length; ++i) {
            extra[i] = s[0].newKeys[i];
        }
        extra[s[0].newKeys.length] = voters[0];
        s[0].newKeys = extra; // one new key too many
        vm.expectRevert(IBnbStateVerifier.WrongKeys.selector);
        verifier.advance(voters, s);

        s = _steps(1, 2);
        bytes[] memory fewer = new bytes[](s[0].newKeys.length - 1);
        for (uint256 i = 0; i < fewer.length; ++i) {
            fewer[i] = s[0].newKeys[i];
        }
        s[0].newKeys = fewer; // one too few
        vm.expectRevert(IBnbStateVerifier.WrongKeys.selector);
        verifier.advance(voters, s);

        s = _steps(1, 2);
        s[0].keySources = new bytes(20);
        vm.expectRevert(IBnbStateVerifier.WrongKeys.selector);
        verifier.advance(voters, s);

        s = _steps(1, 2);
        (uint256 xHi, uint256 xLo, uint256 yHi, uint256 yLo) =
            abi.decode(s[0].newKeys[0], (uint256, uint256, uint256, uint256));
        s[0].newKeys[0] = abi.encode(xHi, xLo, yHi, yLo ^ 2); // a new key off the curve
        vm.expectRevert(abi.encodeWithSelector(Bls12381.PrecompileFailed.selector, address(0x0b)));
        verifier.advance(voters, s);
    }

    // ---------------------------------------------------------------------
    // finality and the switch
    // ---------------------------------------------------------------------

    /// @dev The votes on either side of epoch 2's switch: the old set signs the block before, the new set the block the
    ///      switch names, and neither signs the other's.
    function test_verifyHeader_theSwitchIsExact() public {
        _advanceAll();
        uint256 first = vm.parseJsonUint(json, ".switch.firstTarget");
        bytes memory before = _bytes(".switch.before.rlp");
        bytes memory afterHeader = _bytes(".switch.after.rlp");
        IBnbStateVerifier.Vote memory beforeVote = _vote(".switch.before.vote");
        IBnbStateVerifier.Vote memory afterVote = _vote(".switch.after.vote");
        bytes[] memory oldKeys = _keys(_at(1, ".keys"));
        bytes[] memory newKeys = _keys(_at(2, ".keys"));

        IBnbStateVerifier.FinalHeader memory f = verifier.verifyHeader(before, epochs[1], beforeVote, oldKeys);
        assertEq(f.number, first - 2);
        assertEq(f.hash, keccak256(before));
        f = verifier.verifyHeader(afterHeader, epochs[2], afterVote, newKeys);
        assertEq(f.number, first - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IBnbStateVerifier.TargetOutsideWindow.selector, first - 1, first, first + 1000)
        );
        verifier.verifyHeader(before, epochs[2], beforeVote, newKeys);
        vm.expectRevert(
            abi.encodeWithSelector(IBnbStateVerifier.TargetOutsideWindow.selector, first, first - 1000, first)
        );
        verifier.verifyHeader(afterHeader, epochs[1], afterVote, oldKeys);
    }

    /// @dev A header's hash is what the validators signed: any other state root is refused.
    function test_verifyHeader_anyOtherHeaderIsRefused() public {
        _advanceAll();
        bytes memory header = _bytes(".switch.after.rlp");
        bytes memory forged = _withField(header, 3, abi.encodePacked(keccak256("another state")));
        vm.expectRevert(IBnbStateVerifier.BadSignature.selector);
        verifier.verifyHeader(forged, epochs[2], _vote(".switch.after.vote"), _keys(_at(2, ".keys")));
    }

    /// @dev A proven block must be dated within `MAX_SPAN` after its set's epoch block, never before it: an old set
    ///      cannot sign a header dated today.
    function test_verifyHeader_theTimeIsBounded() public {
        _advanceAll();
        bytes memory header = _bytes(".switch.after.rlp");
        uint256 epochTime = vm.parseJsonUint(json, _at(2, ".time"));
        IBnbStateVerifier.Vote memory vote = _vote(".switch.after.vote");
        bytes[] memory keys = _keys(_at(2, ".keys"));
        bytes memory late = _withField(header, TIME, RlpWriter.be(epochTime + 15 minutes + 1));
        vm.expectRevert(
            abi.encodeWithSelector(IBnbStateVerifier.TimeOutsideWindow.selector, epochTime + 15 minutes + 1, epochTime)
        );
        verifier.verifyHeader(late, epochs[2], vote, keys);
        bytes memory early = _withField(header, TIME, RlpWriter.be(epochTime - 1));
        vm.expectRevert(abi.encodeWithSelector(IBnbStateVerifier.TimeOutsideWindow.selector, epochTime - 1, epochTime));
        verifier.verifyHeader(early, epochs[2], vote, keys);
    }

    function test_verifyHeader_needsARecordedEpochAndItsKeys() public {
        IBnbStateVerifier.Vote memory vote = _vote(".switch.after.vote");
        bytes memory header = _bytes(".switch.after.rlp");
        vm.expectRevert(abi.encodeWithSelector(IBnbStateVerifier.UnknownEpoch.selector, epochs[2]));
        verifier.verifyHeader(header, epochs[2], vote, _keys(_at(2, ".keys")));
        vm.expectRevert(abi.encodeWithSelector(IBnbStateVerifier.UnknownEpoch.selector, epochs[2]));
        verifier.windowEnd(epochs[2]);
        _advanceAll();
        vm.expectRevert(IBnbStateVerifier.WrongKeys.selector);
        verifier.verifyHeader(header, epochs[2], vote, _keys(_at(1, ".keys")));
    }

    // ---------------------------------------------------------------------
    // gas, as a transaction pays it
    // ---------------------------------------------------------------------

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

    /// @dev Following BNB Chain costs one epoch every 7.5 minutes, 192 a day; batching shares the first set's keys.
    function test_gas_followingTheChain() public {
        (uint256 one, uint256 oneExecution) =
            _txGas(abi.encodeCall(verifier.advance, (_keys(_at(0, ".keys")), _steps(1, 2))));
        (uint256 two, uint256 twoExecution) =
            _txGas(abi.encodeCall(verifier.advance, (_keys(_at(1, ".keys")), _steps(2, 4))));
        console2.log("one epoch a transaction: gas", one, "of which execution", oneExecution);
        console2.log("two epochs a transaction: gas", two, "of which execution", twoExecution);
        console2.log("per epoch, two a transaction", two / 2, "a day at 192", two / 2 * 192);
        // The bounds are the optimized build's; coverage compiles without the optimizer, so it only measures.
        bool coverage = vm.isContext(VmSafe.ForgeContext.Coverage);
        if (!coverage) assertLt(one, 560_000, "one epoch a transaction");
        if (!coverage) assertLt(two / 2, 500_000, "an epoch two to a transaction");

        bytes32[] memory slots = new bytes32[](2);
        slots[0] = vm.parseJsonBytes32(json, ".state.slot");
        slots[1] = vm.parseJsonBytes32(json, ".state.unusedSlot");
        bytes[][] memory storageProofs = new bytes[][](2);
        storageProofs[0] = _keys(".state.storageProof");
        storageProofs[1] = _keys(".state.unusedSlotProof");
        bytes memory proof = _stateProof(_keys(".state.accountProof"), storageProofs);
        bytes memory call =
            abi.encodeCall(verifier.verifySlots, (vm.parseJsonAddress(json, ".state.account"), slots, proof));
        (uint256 read, uint256 readExecution) = _txGas(call);
        console2.log("proving two slots: gas", read, "of which execution", readExecution);
        console2.log("calldata bytes", call.length);
        if (!coverage) assertLt(read, 1_100_000, "a two-slot state proof");
    }

    // ---------------------------------------------------------------------
    // state
    // ---------------------------------------------------------------------

    /// @dev WBNB's slot 0 holds its name, "Wrapped BNB", and an unused slot reads zero, at a block near the head.
    function test_verifySlots_readsTheState() public {
        _advanceAll();
        bytes32[] memory slots = new bytes32[](2);
        slots[0] = vm.parseJsonBytes32(json, ".state.slot");
        slots[1] = vm.parseJsonBytes32(json, ".state.unusedSlot");
        bytes[][] memory storageProofs = new bytes[][](2);
        storageProofs[0] = _keys(".state.storageProof");
        storageProofs[1] = _keys(".state.unusedSlotProof");
        bytes memory proof = _stateProof(_keys(".state.accountProof"), storageProofs);
        address wbnb = vm.parseJsonAddress(json, ".state.account");

        uint256 before = gasleft();
        (uint256 number, uint256 time, bytes32[] memory values) = verifier.verifySlots(wbnb, slots, proof);
        console2.log("gas to prove two BNB Chain slots", before - gasleft());
        assertEq(number, vm.parseJsonUint(json, ".state.block.number"));
        assertEq(time, vm.parseJsonUint(json, ".state.block.time"));
        assertEq(values[0], vm.parseJsonBytes32(json, ".state.value"));
        assertEq(values[0], bytes32(bytes.concat("Wrapped BNB", new bytes(20), hex"16")));
        assertEq(values[1], 0, "an unused slot");
    }

    function test_verifySlots_anAbsentAccountReadsZero() public {
        _advanceAll();
        bytes32[] memory slots = new bytes32[](1);
        bytes[][] memory storageProofs = new bytes[][](1);
        bytes memory proof = _stateProof(_keys(".state.absentAccountProof"), storageProofs);
        address absent = vm.parseJsonAddress(json, ".state.absentAccount");
        (,, bytes32[] memory values) = verifier.verifySlots(absent, slots, proof);
        assertEq(values[0], 0);
    }

    function test_verifySlots_oneProofPerSlot() public {
        _advanceAll();
        bytes32[] memory slots = new bytes32[](2);
        bytes memory proof = _stateProof(_keys(".state.accountProof"), new bytes[][](1));
        vm.expectRevert(IBnbStateVerifier.LengthMismatch.selector);
        verifier.verifySlots(vm.parseJsonAddress(json, ".state.account"), slots, proof);
    }

    /// @dev BNB-2: a set long superseded may have unbonded and its keys changed hands, and BNB Chain punishes a
    ///      conflicting vote only for a recent target. So it names no next set once a day old: a verifier left that far
    ///      behind stops for good.
    function test_BNB2_aStaleSetDoesNotNameTheNextOne() public {
        uint256 setTime = verifier.validatorSet(epochs[0]).time;
        bytes[] memory keys = _keys(_at(0, ".keys"));
        IBnbStateVerifier.EpochStep[] memory steps = _steps(1, 4);
        vm.warp(setTime + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IBnbStateVerifier.TooOld.selector, setTime));
        verifier.advance(keys, steps);
        vm.warp(setTime + 1 days);
        verifier.advance(keys, steps);
        assertEq(verifier.latestEpoch(), epochs[3]);
    }

    /// @dev BNB-2: nor does the verifier prove a block more than a day old, which an old set could have forged at no
    ///      risk to itself, for a reader that takes an old state.
    function test_BNB2_noBlockMoreThanADayOld() public {
        _advanceAll();
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = vm.parseJsonBytes32(json, ".state.slot");
        bytes[][] memory storageProofs = new bytes[][](1);
        storageProofs[0] = _keys(".state.storageProof");
        bytes memory proof = _stateProof(_keys(".state.accountProof"), storageProofs);
        address wbnb = vm.parseJsonAddress(json, ".state.account");
        uint256 time = vm.parseJsonUint(json, ".state.block.time");
        vm.warp(time + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IBnbStateVerifier.TooOld.selector, time));
        verifier.verifySlots(wbnb, slots, proof);
        vm.warp(time + 1 days);
        (, uint256 provenTime,) = verifier.verifySlots(wbnb, slots, proof);
        assertEq(provenTime, time);
    }
}

/// @notice The same suite on BNB testnet (chain id 97, `test/fixtures/bnb/testnet.json`, from `generate.py`), the chain
///         the testnet deployment's verifier follows from Sepolia: the same epoch length, the same vote and the same
///         switch rule, with its own validator set.
/// forge-config: default.evm_version = "prague"
contract BnbStateVerifierTestnetTest is BnbStateVerifierTest {
    function _fixture() internal pure override returns (string memory) {
        return "test/fixtures/bnb/testnet.json";
    }
}
