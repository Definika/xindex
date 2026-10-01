// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TronStateVerifier} from "../src/verifiers/TronStateVerifier.sol";
import {ITronStateVerifier} from "../src/interfaces/ITronStateVerifier.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";

/// @notice Tron's state verifier, first against real mainnet data from `test/fixtures/tron/generate.py`: 122 blocks
///         around the maintenance boundary of 1 October 2026 at 12:00 UTC, every header written from its fields and
///         hashed to its real block id, a real call proven in each period, and the list followed across the boundary.
///         Then on synthetic chains signed with test keys, each refusal reached by changing one thing.
contract TronStateVerifierTest is Test {
    TronStateVerifier verifier;
    string json;
    uint256 boundary;

    uint8 constant NL = type(uint8).max;
    uint256 constant SLOT = 3000;
    uint256 constant INTERVAL = 6 hours * 1000;
    uint256 constant MASK = (1 << 192) - 1;

    /// @dev A fixture header, as `generate.py` writes it, with the key it recovered and its block id.
    struct FixtureHeader {
        uint256 timestamp;
        bytes32 txTrieRoot;
        bytes32 parentHash;
        uint256 number;
        uint256 witnessId;
        address witness;
        uint256 version;
        bytes accountStateRoot;
        bytes32 r;
        bytes32 s;
        uint256 v;
        address key;
        bytes32 id;
        bytes extra;
    }

    string constant HEADER_TYPE = "FixtureHeader(uint256 timestamp,bytes32 txTrieRoot,bytes32 parentHash,uint256 number,"
        "uint256 witnessId,address witness,uint256 version,bytes accountStateRoot,bytes32 r,bytes32 s,uint256 v,"
        "address key,bytes32 id,bytes extra)";

    function setUp() public {
        json = vm.readFile("test/fixtures/tron/chain.json");
        boundary = vm.parseJsonUint(json, ".boundary");
        verifier = new TronStateVerifier(_list(".oldList"), uint64(boundary));
        vm.warp(boundary / 1000 + 30 minutes);
    }

    // ---------------------------------------------------------------------
    // fixture
    // ---------------------------------------------------------------------

    function _at(string memory path, uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(path, "[", vm.toString(i), "].", field);
    }

    function _list(string memory path) internal view returns (ITronStateVerifier.Producer[] memory) {
        return abi.decode(
            vm.parseJsonTypeArray(json, path, "Producer(address witness,address key)"), (ITronStateVerifier.Producer[])
        );
    }

    /// @dev Every fixture header, decoded in one call: each cheatcode call copies the whole file.
    function _fixture() internal view returns (FixtureHeader[] memory) {
        return abi.decode(vm.parseJsonTypeArray(json, ".headers", HEADER_TYPE), (FixtureHeader[]));
    }

    /// @dev A fixture header, its producer named by index in `list` where it signs with its listed key.
    function _header(FixtureHeader memory f, ITronStateVerifier.Producer[] memory list)
        internal
        pure
        returns (ITronStateVerifier.Header memory h)
    {
        h = ITronStateVerifier.Header({
            timestamp: uint64(f.timestamp),
            txTrieRoot: f.txTrieRoot,
            parentHash: f.parentHash,
            number: uint64(f.number),
            witnessId: uint64(f.witnessId),
            witness: f.witness,
            version: int32(int256(f.version)),
            accountStateRoot: f.accountStateRoot,
            extra: f.extra,
            r: f.r,
            s: f.s,
            v: uint8(f.v),
            producer: NL
        });
        for (uint256 k = 0; k < list.length; ++k) {
            if (list[k].witness == f.witness && list[k].key == f.key) h.producer = uint8(k);
        }
    }

    function _headers(uint256 from, uint256 to, ITronStateVerifier.Producer[] memory list)
        internal
        view
        returns (ITronStateVerifier.Header[] memory hs)
    {
        FixtureHeader[] memory all = _fixture();
        hs = new ITronStateVerifier.Header[](to - from);
        for (uint256 i = from; i < to; ++i) {
            hs[i - from] = _header(all[i], list);
        }
    }

    /// @dev The call proof of the fixture's `which` proof ("oldProof" or "newProof"), signed by list `id`.
    function _realProof(string memory which, uint256 id, ITronStateVerifier.Producer[] memory list)
        internal
        view
        returns (ITronStateVerifier.CallProof memory p, address target, bytes memory data)
    {
        string memory q = string.concat(".", which);
        p.list = id;
        p.producers = list;
        p.transaction = ITronStateVerifier.Transaction({
            owner: vm.parseJsonAddress(json, string.concat(q, ".owner")),
            refBlockBytes: vm.parseJsonBytes(json, string.concat(q, ".refBlockBytes")),
            refBlockHash: vm.parseJsonBytes(json, string.concat(q, ".refBlockHash")),
            expiration: uint64(vm.parseJsonUint(json, string.concat(q, ".expiration"))),
            timestamp: uint64(vm.parseJsonUint(json, string.concat(q, ".timestamp"))),
            feeLimit: uint64(vm.parseJsonUint(json, string.concat(q, ".feeLimit"))),
            permissionId: uint32(vm.parseJsonUint(json, string.concat(q, ".permissionId"))),
            signatures: vm.parseJsonBytesArray(json, string.concat(q, ".signatures")),
            fee: uint64(vm.parseJsonUint(json, string.concat(q, ".fee")))
        });
        p.path = vm.parseJsonBytes32Array(json, string.concat(q, ".path"));
        p.sides = vm.parseJsonUint(json, string.concat(q, ".sides"));
        uint256 from = vm.parseJsonUint(json, string.concat(q, ".block"));
        p.headers = _headers(from, vm.parseJsonUint(json, string.concat(q, ".headersEnd")), list);
        target = vm.parseJsonAddress(json, string.concat(q, ".target"));
        data = vm.parseJsonBytes(json, string.concat(q, ".data"));
    }

    /// @dev The fixture's advance: from the old period's last block, through the maintenance block and the block after
    ///      it, the round, and the blocks in which 19 old producers vouch.
    function _realAdvance()
        internal
        view
        returns (ITronStateVerifier.Header[] memory hs, uint256 learnFrom, uint256 vouchFrom)
    {
        uint256 m = vm.parseJsonUint(json, ".maintenance");
        uint256 from = vm.parseJsonUint(json, ".learnFrom");
        uint256 vouch = vm.parseJsonUint(json, ".vouchFrom");
        uint256 end = vm.parseJsonUint(json, ".advanceEnd");
        ITronStateVerifier.Producer[] memory oldList = _list(".oldList");
        ITronStateVerifier.Producer[] memory newList = _list(".newList");
        FixtureHeader[] memory all = _fixture();
        hs = new ITronStateVerifier.Header[](end - (m - 1));
        for (uint256 i = m - 1; i < end; ++i) {
            // The round names its producers in the new list, the vouching blocks theirs in the old one.
            ITronStateVerifier.Producer[] memory list =
                i >= from && i < vouch ? newList : i >= vouch ? oldList : new ITronStateVerifier.Producer[](0);
            hs[i - (m - 1)] = _header(all[i], list);
        }
        (learnFrom, vouchFrom) = (from - (m - 1), vouch - (m - 1));
    }

    function _id(ITronStateVerifier.Header memory h) internal view returns (bytes32) {
        return bytes32(uint256(h.number) << 192 | (uint256(verifier.headerHash(h)) & MASK));
    }

    // ---------------------------------------------------------------------
    // real mainnet data
    // ---------------------------------------------------------------------

    /// @dev Each of the 122 real headers, written from its fields, hashes to its block id, and its signature recovers to
    ///      the key the fixture recovered independently.
    function test_realHeadersHashToTheirIds() public view {
        FixtureHeader[] memory all = _fixture();
        assertEq(all.length, 122);
        ITronStateVerifier.Producer[] memory none = new ITronStateVerifier.Producer[](0);
        for (uint256 i = 0; i < all.length; ++i) {
            ITronStateVerifier.Header memory h = _header(all[i], none);
            bytes32 hash = verifier.headerHash(h);
            assertEq(_id(h), all[i].id, "block id");
            assertEq(ecrecover(hash, h.v + 27, h.r, h.s), all[i].key, "signer");
            if (i > 0) assertEq(h.parentHash, all[i - 1].id, "linked");
        }
    }

    /// @dev Two real USDT transfers, written from their fields with the result SUCCESS, are leaves of their blocks'
    ///      transaction trees, which the fixture rebuilt from every transaction of each block.
    function test_realTransactionsAreLeaves() public view {
        string[2] memory which = ["oldProof", "newProof"];
        for (uint256 k = 0; k < 2; ++k) {
            (ITronStateVerifier.CallProof memory p, address target, bytes memory data) =
                _realProof(which[k], 0, new ITronStateVerifier.Producer[](0));
            bytes32 node = sha256(verifier.transactionBytes(p.transaction, target, data));
            assertEq(node, vm.parseJsonBytes32(json, string.concat(".", which[k], ".leaf")));
            for (uint256 i = 0; i < p.path.length; ++i) {
                node = (p.sides >> i) & 1 == 1
                    ? sha256(bytes.concat(p.path[i], node))
                    : sha256(bytes.concat(node, p.path[i]));
            }
            assertEq(node, p.headers[0].txTrieRoot, "the block's transaction root");
        }
    }

    function test_verifyCall_aRealCallInTheOldPeriod() public view {
        (ITronStateVerifier.CallProof memory p, address target, bytes memory data) =
            _realProof("oldProof", 0, _list(".oldList"));
        (uint256 number, uint256 time, address t, bytes memory d) = verifier.verifyCall(abi.encode(p, target, data));
        assertEq(number, p.headers[0].number);
        assertEq(time, p.headers[0].timestamp / 1000);
        assertEq(t, target);
        assertEq(d, data);
        assertEq(bytes4(d), bytes4(keccak256("transfer(address,uint256)")), "a USDT transfer");
    }

    /// @dev The list followed across the boundary: the round after the maintenance names 27 producers, and 19 of the
    ///      list before vouch for it; a call in the new period is then proven by the new list.
    function test_advance_acrossARealBoundary() public {
        (ITronStateVerifier.Header[] memory hs, uint256 learnFrom, uint256 vouchFrom) = _realAdvance();
        ITronStateVerifier.Producer[] memory newList = _list(".newList");
        verifier.advance(_list(".oldList"), newList, hs, learnFrom, vouchFrom);
        assertEq(verifier.latestList(), 1);
        ITronStateVerifier.ProducerList memory l = verifier.producerList(1);
        assertEq(l.producersHash, keccak256(abi.encode(newList)));
        assertEq(l.start, boundary);
        assertEq(l.end, boundary + INTERVAL);
        assertEq(l.count, 27);

        (ITronStateVerifier.CallProof memory p, address target, bytes memory data) = _realProof("newProof", 1, newList);
        (uint256 number,, address t,) = verifier.verifyCall(abi.encode(p, target, data));
        assertEq(number, p.headers[0].number);
        assertEq(t, target);
        // The old list cannot prove a block of the new period.
        (p, target, data) = _realProof("newProof", 0, _list(".oldList"));
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.OutsidePeriod.selector, 0, p.headers[0].timestamp));
        verifier.verifyCall(abi.encode(p, target, data));
    }

    /// @dev What a transaction pays, the 21,000 and its calldata included: following one period, and proving a slot.
    function test_gas_realProofs() public {
        (ITronStateVerifier.Header[] memory hs, uint256 learnFrom, uint256 vouchFrom) = _realAdvance();
        bytes memory advance =
            abi.encodeCall(verifier.advance, (_list(".oldList"), _list(".newList"), hs, learnFrom, vouchFrom));
        uint256 following = _txGas(advance);
        (ITronStateVerifier.CallProof memory p, address target, bytes memory data) =
            _realProof("newProof", 1, _list(".newList"));
        uint256 proving = _txGas(abi.encodeCall(verifier.verifyCall, (abi.encode(p, target, data))));
        console2.log("following one period (", hs.length, "headers ): gas", following);
        console2.log("proving a call (19 headers): gas", proving);
        // The bounds are the optimized build's; coverage compiles without the optimizer, so it only measures.
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;
        assertLt(following, 1_500_000, "a period a transaction");
        assertLt(proving, 600_000, "a call");
    }

    function _txGas(bytes memory data) internal returns (uint256 used) {
        address target = address(verifier);
        vm.cool(target);
        bool ok;
        uint256 before = gasleft();
        assembly ("memory-safe") {
            ok := call(gas(), target, 0, add(data, 32), mload(data), 0, 0)
        }
        used = before - gasleft();
        assertTrue(ok);
    }
}

/// @notice The verifier's rules on synthetic chains: 27 producers with test keys, headers written and signed through the
///         verifier's own encoding (which the real-data suite pins to Tron's), and a vault `attest` in a small
///         transaction tree. Each refusal is reached by changing one thing.
contract TronStateVerifierRulesTest is Test {
    TronStateVerifier verifier;

    uint8 constant NL = type(uint8).max;
    uint256 constant SLOT = 3000;
    uint256 constant INTERVAL = 6 hours * 1000;
    uint256 constant MASK = (1 << 192) - 1;
    /// @dev The end of list 0's period, a maintenance time on Tron's grid, in milliseconds.
    uint64 constant E = 1_800_000_000_000;
    address constant VAULT = address(0x7a017);

    /// @dev One block to build: its producer, the secret it signs with, its index in the proof's list, the slots since
    ///      its parent, its transaction root, and whether its producer poisoned its header: a negative version and an
    ///      unknown field, both of which Tron keeps and hashes.
    struct Step {
        address witness;
        uint256 pk;
        uint8 hint;
        uint256 gap;
        bytes32 txTrieRoot;
        bool poisoned;
    }

    function setUp() public {
        verifier = new TronStateVerifier(_old(), E);
        vm.warp(E / 1000 + 1 hours);
    }

    // ---------------------------------------------------------------------
    // producers
    // ---------------------------------------------------------------------

    function _oldPk(uint256 i) internal pure returns (uint256) {
        return 0xA11CE + i;
    }

    function _old() internal pure returns (ITronStateVerifier.Producer[] memory list) {
        list = new ITronStateVerifier.Producer[](27);
        for (uint256 i = 0; i < 27; ++i) {
            list[i] = ITronStateVerifier.Producer(address(uint160(0x1000 + i)), vm.addr(_oldPk(i)));
        }
    }

    /// @dev The next list: the old one's first 25, and two newcomers, in ascending witness order.
    function _newPk(uint256 i) internal pure returns (uint256) {
        return i < 25 ? _oldPk(i) : 0xBEEF0 + i;
    }

    function _new() internal pure returns (ITronStateVerifier.Producer[] memory list) {
        list = new ITronStateVerifier.Producer[](27);
        for (uint256 i = 0; i < 27; ++i) {
            address witness = i < 25 ? address(uint160(0x1000 + i)) : address(uint160(0x2000 + i));
            list[i] = ITronStateVerifier.Producer(witness, vm.addr(_newPk(i)));
        }
    }

    // ---------------------------------------------------------------------
    // chains
    // ---------------------------------------------------------------------

    function _id(ITronStateVerifier.Header memory h) internal view returns (bytes32) {
        return bytes32(uint256(h.number) << 192 | (uint256(verifier.headerHash(h)) & MASK));
    }

    function _sign(ITronStateVerifier.Header memory h, uint256 pk) internal view {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, verifier.headerHash(h));
        (h.v, h.r, h.s) = (v - 27, r, s);
    }

    /// @dev A chain of signed headers, each naming the one before; the first at `time`, number 70,000,000.
    function _build(uint256 time, Step[] memory steps) internal view returns (ITronStateVerifier.Header[] memory hs) {
        hs = new ITronStateVerifier.Header[](steps.length);
        bytes32 parent = keccak256("the block before");
        for (uint256 i = 0; i < steps.length; ++i) {
            time += i == 0 ? 0 : steps[i].gap * SLOT;
            hs[i].number = uint64(70_000_000 + i);
            hs[i].timestamp = uint64(time);
            hs[i].parentHash = parent;
            hs[i].txTrieRoot = steps[i].txTrieRoot == 0 ? keccak256(abi.encode("txs", i)) : steps[i].txTrieRoot;
            hs[i].witness = steps[i].witness;
            hs[i].version = 38;
            if (steps[i].poisoned) (hs[i].version, hs[i].extra) = (-1, hex"6005");
            hs[i].producer = steps[i].hint;
            _sign(hs[i], steps[i].pk);
            parent = _id(hs[i]);
        }
    }

    function _step(ITronStateVerifier.Producer[] memory list, uint256 i, uint256 pk, bool counts)
        internal
        pure
        returns (Step memory)
    {
        return Step(list[i].witness, pk, counts ? uint8(i) : NL, 1, 0, false);
    }

    // ---------------------------------------------------------------------
    // calls
    // ---------------------------------------------------------------------

    function _slots() internal pure returns (bytes32[] memory slots, bytes32[] memory values) {
        slots = new bytes32[](2);
        values = new bytes32[](2);
        (slots[0], values[0]) = (keccak256("an intake's digest slot"), keccak256("its digest"));
        (slots[1], values[1]) = (bytes32(uint256(3)), bytes32(uint256(42)));
    }

    function _tx() internal pure returns (ITronStateVerifier.Transaction memory t) {
        t.owner = address(0x5e1a7);
        t.refBlockBytes = hex"4e20";
        t.refBlockHash = hex"0102030405060708";
        t.expiration = uint64(E - INTERVAL + 120_000);
        t.timestamp = uint64(E - INTERVAL + 60_000);
        t.feeLimit = 100_000_000;
        t.signatures = new bytes[](1);
        t.signatures[0] = abi.encodePacked(keccak256("r"), keccak256("s"), uint8(1));
    }

    /// @dev Tron's transaction tree over `leaves` (an odd node promoted), and the path of leaf `index`.
    function _tree(bytes32[] memory leaves, uint256 index)
        internal
        pure
        returns (bytes32 root, bytes32[] memory path, uint256 sides)
    {
        bytes32[] memory p = new bytes32[](8);
        uint256 n = 0;
        while (leaves.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < leaves.length) {
                if (index & 1 == 1) sides |= 1 << n;
                p[n++] = leaves[sibling];
            }
            bytes32[] memory up = new bytes32[]((leaves.length + 1) / 2);
            for (uint256 i = 0; i < up.length; ++i) {
                up[i] =
                    2 * i + 1 < leaves.length ? sha256(bytes.concat(leaves[2 * i], leaves[2 * i + 1])) : leaves[2 * i];
            }
            leaves = up;
            index /= 2;
        }
        root = leaves[0];
        path = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            path[i] = p[i];
        }
    }

    /// @dev A proof that `transaction` is the second of four leaves of a block of list 0's period, which producers 0 to
    ///      18 of list 0 then build on: the leaf is the call as the verifier writes it, or `leaf` where given.
    function _callProof(ITronStateVerifier.Transaction memory t, address target, bytes memory data, bytes32 leaf)
        internal
        view
        returns (ITronStateVerifier.CallProof memory p)
    {
        bytes32[] memory leaves = new bytes32[](5);
        for (uint256 i = 0; i < 5; ++i) {
            leaves[i] = keccak256(abi.encode("another transaction", i));
        }
        leaves[1] = leaf != 0 ? leaf : sha256(verifier.transactionBytes(t, target, data));
        (bytes32 root, bytes32[] memory path, uint256 sides) = _tree(leaves, 1);
        Step[] memory steps = new Step[](19);
        ITronStateVerifier.Producer[] memory list = _old();
        for (uint256 i = 0; i < 19; ++i) {
            steps[i] = _step(list, i, _oldPk(i), true);
        }
        steps[0].txTrieRoot = root;
        p.list = 0;
        p.producers = list;
        p.transaction = t;
        p.path = path;
        p.sides = sides;
        p.headers = _build(E - INTERVAL + 90_000, steps);
    }

    function _attest(ITronStateVerifier.CallProof memory p, bytes32[] memory values)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(p, values);
    }

    function _attestProof()
        internal
        view
        returns (ITronStateVerifier.CallProof memory p, bytes32[] memory slots, bytes32[] memory values)
    {
        (slots, values) = _slots();
        p = _callProof(_tx(), VAULT, abi.encodeCall(IXindexVault.attest, (slots, values)), 0);
    }

    // ---------------------------------------------------------------------
    // proving slots
    // ---------------------------------------------------------------------

    function test_verifySlots_provesASuccessfulAttest() public view {
        (ITronStateVerifier.CallProof memory p, bytes32[] memory slots, bytes32[] memory values) = _attestProof();
        (uint256 number, uint256 time, bytes32[] memory got) = verifier.verifySlots(VAULT, slots, _attest(p, values));
        assertEq(number, p.headers[0].number);
        assertEq(time, p.headers[0].timestamp / 1000, "TVM's seconds");
        assertEq(got, values);
    }

    /// @dev The verifier writes the vault, the call and the result itself, so a proof of anything else names a leaf the
    ///      block does not hold.
    function test_verifySlots_provesOnlyTheVaultsSuccessfulAttest() public {
        (ITronStateVerifier.CallProof memory p, bytes32[] memory slots, bytes32[] memory values) = _attestProof();
        vm.expectRevert(ITronStateVerifier.NotInBlock.selector);
        verifier.verifySlots(address(0xbad), slots, _attest(p, values));

        bytes32[] memory other = new bytes32[](2);
        (other[0], other[1]) = (values[0], bytes32(uint256(43)));
        vm.expectRevert(ITronStateVerifier.NotInBlock.selector);
        verifier.verifySlots(VAULT, slots, _attest(p, other));

        vm.expectRevert(ITronStateVerifier.LengthMismatch.selector);
        verifier.verifySlots(VAULT, slots, _attest(p, new bytes32[](1)));

        // The same call in the block, but its result REVERT: the vault did not hold those values.
        bytes memory data = abi.encodeCall(IXindexVault.attest, (slots, values));
        bytes memory reverted = verifier.transactionBytes(p.transaction, VAULT, data);
        assertEq(uint8(reverted[reverted.length - 1]), 1, "contractRet SUCCESS is the last byte");
        reverted[reverted.length - 1] = bytes1(uint8(2));
        ITronStateVerifier.CallProof memory q = _callProof(p.transaction, VAULT, data, sha256(reverted));
        vm.expectRevert(ITronStateVerifier.NotInBlock.selector);
        verifier.verifySlots(VAULT, slots, _attest(q, values));
    }

    function test_verifySlots_thePathIsTheBlocks() public {
        (ITronStateVerifier.CallProof memory p, bytes32[] memory slots, bytes32[] memory values) = _attestProof();
        p.path[1] = keccak256("another sibling");
        vm.expectRevert(ITronStateVerifier.NotInBlock.selector);
        verifier.verifySlots(VAULT, slots, _attest(p, values));

        (p,,) = _attestProof();
        p.sides ^= 1;
        vm.expectRevert(ITronStateVerifier.NotInBlock.selector);
        verifier.verifySlots(VAULT, slots, _attest(p, values));

        (p,,) = _attestProof();
        p.sides |= 1 << p.path.length;
        vm.expectRevert(ITronStateVerifier.NotInBlock.selector);
        verifier.verifySlots(VAULT, slots, _attest(p, values));
    }

    function test_verifySlots_theListIsRecorded() public {
        (ITronStateVerifier.CallProof memory p, bytes32[] memory slots, bytes32[] memory values) = _attestProof();
        p.list = 9;
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.UnknownList.selector, 9));
        verifier.verifySlots(VAULT, slots, _attest(p, values));

        (p,,) = _attestProof();
        p.producers[3].key = address(0xbad);
        vm.expectRevert(ITronStateVerifier.WrongProducers.selector);
        verifier.verifySlots(VAULT, slots, _attest(p, values));

        (p,,) = _attestProof();
        p.producers = _new();
        vm.expectRevert(ITronStateVerifier.WrongProducers.selector);
        verifier.verifySlots(VAULT, slots, _attest(p, values));
    }

    /// @dev Nineteen distinct listed producers must build on the block: one short, or one signing twice, is not enough.
    function test_verifySlots_needsNineteenDistinctProducers() public {
        (ITronStateVerifier.CallProof memory p, bytes32[] memory slots, bytes32[] memory values) = _attestProof();
        p.headers[18].producer = NL;
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.NoQuorum.selector, 18));
        verifier.verifySlots(VAULT, slots, _attest(p, values));

        // Producer 0 signs the last block too, instead of producer 18.
        bytes memory data = abi.encodeCall(IXindexVault.attest, (slots, values));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = sha256(verifier.transactionBytes(_tx(), VAULT, data));
        Step[] memory steps = new Step[](19);
        ITronStateVerifier.Producer[] memory list = _old();
        for (uint256 i = 0; i < 19; ++i) {
            steps[i] = _step(list, i == 18 ? 0 : i, _oldPk(i == 18 ? 0 : i), true);
        }
        steps[0].txTrieRoot = leaves[0];
        p.headers = _build(E - INTERVAL + 90_000, steps);
        p.path = new bytes32[](0);
        p.sides = 0;
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.NoQuorum.selector, 18));
        verifier.verifySlots(VAULT, slots, _attest(p, values));

        p.headers = new ITronStateVerifier.Header[](0);
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.NoQuorum.selector, 0));
        verifier.verifySlots(VAULT, slots, _attest(p, values));
    }

    function test_verifySlots_eachSignatureIsItsProducers() public {
        (ITronStateVerifier.CallProof memory p, bytes32[] memory slots, bytes32[] memory values) = _attestProof();
        // Named as another producer.
        p.headers[4].producer = 5;
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.BadSignature.selector, 4));
        verifier.verifySlots(VAULT, slots, _attest(p, values));
        // Past the list.
        (p,,) = _attestProof();
        p.headers[4].producer = 27;
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.BadSignature.selector, 4));
        verifier.verifySlots(VAULT, slots, _attest(p, values));
        // Signed with a key the list does not hold for it.
        (p,,) = _attestProof();
        _sign(p.headers[18], 0xbad);
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.BadSignature.selector, 18));
        verifier.verifySlots(VAULT, slots, _attest(p, values));
        // Signed with its producer's key, but naming another producer's witness.
        (p,,) = _attestProof();
        p.headers[18].witness = p.producers[17].witness;
        _sign(p.headers[18], _oldPk(18));
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.BadSignature.selector, 18));
        verifier.verifySlots(VAULT, slots, _attest(p, values));
        // A recovery id Tron never writes.
        (p,,) = _attestProof();
        p.headers[18].v = 2;
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.BadSignature.selector, 18));
        verifier.verifySlots(VAULT, slots, _attest(p, values));
    }

    function test_verifySlots_theHeadersAreOneChain() public {
        (ITronStateVerifier.CallProof memory p, bytes32[] memory slots, bytes32[] memory values) = _attestProof();
        p.headers[3].parentHash = keccak256("elsewhere");
        _sign(p.headers[3], _oldPk(3));
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.NotLinked.selector, 3));
        verifier.verifySlots(VAULT, slots, _attest(p, values));
    }

    /// @dev A list signs only blocks of its own period, and only blocks of the last day.
    function test_verifySlots_withinThePeriodAndTheLag() public {
        (bytes32[] memory slots, bytes32[] memory values) = _slots();
        bytes memory data = abi.encodeCall(IXindexVault.attest, (slots, values));
        bytes32 leaf = sha256(verifier.transactionBytes(_tx(), VAULT, data));
        ITronStateVerifier.Producer[] memory list = _old();
        Step[] memory steps = new Step[](19);
        for (uint256 i = 0; i < 19; ++i) {
            steps[i] = _step(list, i, _oldPk(i), true);
        }
        steps[0].txTrieRoot = leaf;
        ITronStateVerifier.CallProof memory p;
        (p.list, p.producers, p.transaction) = (0, list, _tx());

        // Before the period.
        p.headers = _build(E - INTERVAL - 3000, steps);
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.OutsidePeriod.selector, 0, E - INTERVAL - 3000));
        verifier.verifySlots(VAULT, slots, _attest(p, values));
        // Running past its end.
        p.headers = _build(E - 10 * SLOT, steps);
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.OutsidePeriod.selector, 10, E));
        verifier.verifySlots(VAULT, slots, _attest(p, values));
        // Inside it, until a day after the block.
        p.headers = _build(E - 20 * SLOT, steps);
        verifier.verifySlots(VAULT, slots, _attest(p, values));
        vm.warp((E - 20 * SLOT) / 1000 + 1 days);
        verifier.verifySlots(VAULT, slots, _attest(p, values));
        vm.warp((E - 20 * SLOT) / 1000 + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.TooOld.selector, E - 20 * SLOT));
        verifier.verifySlots(VAULT, slots, _attest(p, values));
    }

    // ---------------------------------------------------------------------
    // proving calls, and the encodings
    // ---------------------------------------------------------------------

    /// @dev Any top-level call, with every optional field of the transaction and header written.
    function test_verifyCall_returnsTheCall() public view {
        ITronStateVerifier.Transaction memory t = _tx();
        t.permissionId = 2;
        t.fee = 345_000;
        t.signatures = new bytes[](2);
        (t.signatures[0], t.signatures[1]) = (abi.encodePacked(keccak256("a")), abi.encodePacked(keccak256("b")));
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", address(0xb0b), 7e6);
        ITronStateVerifier.CallProof memory p = _callProof(t, address(0xc0ffee), data, 0);
        (uint256 number, uint256 time, address target, bytes memory d) =
            verifier.verifyCall(abi.encode(p, address(0xc0ffee), data));
        assertEq(number, p.headers[0].number);
        assertEq(time, p.headers[0].timestamp / 1000);
        assertEq(target, address(0xc0ffee));
        assertEq(d, data);
    }

    /// @dev Java writes a negative int32 sign-extended to ten bytes, and unknown fields after the known ones.
    function test_TRN1_headerHash_writesANegativeVersionAndUnknownFields() public view {
        ITronStateVerifier.Header memory h;
        h.timestamp = 1;
        h.number = 2;
        h.witness = address(0x41);
        h.version = -1;
        h.extra = hex"6005";
        bytes memory raw = bytes.concat(
            hex"0801",
            hex"1220",
            bytes32(0),
            hex"1a20",
            bytes32(0),
            hex"3802",
            hex"4a1541",
            bytes20(h.witness),
            hex"50ffffffffffffffffff01",
            hex"6005"
        );
        assertEq(verifier.headerHash(h), sha256(raw));
    }

    function test_headerHash_writesEveryField() public view {
        ITronStateVerifier.Header memory h;
        h.timestamp = 1;
        h.txTrieRoot = bytes32(uint256(2));
        h.parentHash = bytes32(uint256(3));
        h.number = 300;
        h.witnessId = 5;
        h.witness = address(0x41);
        h.version = 0;
        h.accountStateRoot = abi.encodePacked(bytes32(uint256(7)));
        bytes memory raw = bytes.concat(
            hex"0801",
            hex"1220",
            h.txTrieRoot,
            hex"1a20",
            h.parentHash,
            hex"38ac02",
            hex"4005",
            hex"4a1541",
            bytes20(h.witness),
            hex"5a20",
            bytes32(uint256(7))
        );
        assertEq(verifier.headerHash(h), sha256(raw), "a zero version is left out, a two-byte varint written");
    }

    /// @dev A leaf is a whole transaction's hash and an inner node a hash of 64 bytes; the shortest transaction the
    ///      verifier can write is longer, so no inner node can pass for a leaf.
    function test_aTransactionIsNeverAnInnerNode() public view {
        ITronStateVerifier.Transaction memory t;
        assertGt(verifier.transactionBytes(t, address(0), "").length, 64);
    }

    // ---------------------------------------------------------------------
    // following the list
    // ---------------------------------------------------------------------

    /// @dev The old period's last block, the maintenance block, the block after it (two slots late, as Tron schedules
    ///      it, and not learned), a round of 27 slots naming every producer of the next list, then producers 0 to 18 of
    ///      the old list vouching.
    function _advanceSteps() internal pure returns (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) {
        ITronStateVerifier.Producer[] memory o = _old();
        ITronStateVerifier.Producer[] memory n = _new();
        steps = new Step[](49);
        steps[0] = _step(o, 26, _oldPk(26), false);
        steps[1] = _step(o, 0, _oldPk(0), false);
        steps[2] = Step(n[24].witness, _newPk(24), NL, 3, 0, false);
        for (uint256 i = 0; i < 27; ++i) {
            steps[3 + i] = Step(n[i].witness, _newPk(i), uint8(i), 1, 0, false);
        }
        (learnFrom, vouchFrom) = (3, 30);
        for (uint256 i = 0; i < 19; ++i) {
            steps[30 + i] = _step(o, i, _oldPk(i), true);
        }
    }

    function _advance(Step[] memory steps, uint256 learnFrom, uint256 vouchFrom, uint256 first) internal {
        verifier.advance(_old(), _new(), _build(first, steps), learnFrom, vouchFrom);
    }

    /// @dev Builds the chain first, since building calls the verifier, and only then expects `err`.
    function _refused(Step[] memory steps, uint256 learnFrom, uint256 vouchFrom, uint256 first, bytes memory err)
        internal
    {
        ITronStateVerifier.Header[] memory hs = _build(first, steps);
        vm.expectRevert(err);
        verifier.advance(_old(), _new(), hs, learnFrom, vouchFrom);
    }

    function _err(bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }

    function test_advance_learnsTheNextList() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        vm.expectEmit(address(verifier));
        emit ITronStateVerifier.ListRecorded(1, keccak256(abi.encode(_new())), E, E + INTERVAL, 27);
        _advance(steps, learnFrom, vouchFrom, E - SLOT);
        assertEq(verifier.latestList(), 1);
        ITronStateVerifier.ProducerList memory l = verifier.producerList(1);
        assertEq(l.start, E);
        assertEq(l.end, E + INTERVAL);
        assertEq(l.count, 27);
        assertEq(verifier.producerList(0).end, E, "the list before keeps its period");
        assertEq(verifier.producerList(2).producersHash, 0);
    }

    function test_advance_theListsAreTheRecordedOnes() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        ITronStateVerifier.Header[] memory hs = _build(E - SLOT, steps);
        ITronStateVerifier.Producer[] memory wrong = _old();
        wrong[0].key = address(0xbad);
        vm.expectRevert(ITronStateVerifier.WrongProducers.selector);
        verifier.advance(wrong, _new(), hs, learnFrom, vouchFrom);

        ITronStateVerifier.Producer[] memory short = new ITronStateVerifier.Producer[](18);
        vm.expectRevert(ITronStateVerifier.BadList.selector);
        verifier.advance(_old(), short, hs, learnFrom, vouchFrom);
        ITronStateVerifier.Producer[] memory unordered = _new();
        (unordered[3], unordered[4]) = (unordered[4], unordered[3]);
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.NotAscending.selector, 4));
        verifier.advance(_old(), unordered, hs, learnFrom, vouchFrom);
        ITronStateVerifier.Producer[] memory keyless = _new();
        keyless[6].key = address(0);
        vm.expectRevert(ITronStateVerifier.BadList.selector);
        verifier.advance(_old(), keyless, hs, learnFrom, vouchFrom);
    }

    function test_advance_aListOlderThanADayNamesNoSuccessor() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        ITronStateVerifier.Header[] memory hs = _build(E - SLOT, steps);
        vm.warp((E - INTERVAL) / 1000 + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.TooOld.selector, E - INTERVAL));
        verifier.advance(_old(), _new(), hs, learnFrom, vouchFrom);
    }

    /// @dev The round lies in a period after the latest list's, past its maintenance block and the block after it.
    function test_advance_theRoundStartsTwoBlocksIntoALaterPeriod() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        // Counted from the block after the maintenance, which is scheduled two slots behind, a round of 27 slots can
        // name one producer twice and miss another, as the fixture's real boundary shows.
        _refused(steps, 2, vouchFrom, E - SLOT, _err(ITronStateVerifier.RoundTooEarly.selector));
        // A round in the latest list's own period.
        _refused(steps, learnFrom, vouchFrom, E - 40 * SLOT, _err(ITronStateVerifier.RoundTooEarly.selector));
        // A round whose first block is in the next period but whose maintenance block is not shown.
        steps[1].gap = 2;
        _refused(steps, learnFrom, vouchFrom, E - 3 * SLOT, _err(ITronStateVerifier.RoundTooEarly.selector));
    }

    function test_advance_theHeadersAreOneChainAndTheRoundOnePeriod() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        ITronStateVerifier.Header[] memory hs = _build(E - SLOT, steps);
        hs[20].parentHash = keccak256("elsewhere");
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.NotLinked.selector, 20));
        verifier.advance(_old(), _new(), hs, learnFrom, vouchFrom);

        // A round running past its period.
        steps[25].gap = INTERVAL / SLOT;
        uint256 at = E + 9000 + 22 * SLOT + INTERVAL;
        _refused(
            steps,
            learnFrom,
            vouchFrom,
            E - SLOT,
            abi.encodeWithSelector(ITronStateVerifier.OutsidePeriod.selector, 25, at)
        );
    }

    function test_advance_theRoundIsFull() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        _refused(steps, learnFrom, learnFrom, E - SLOT, _err(ITronStateVerifier.NotARound.selector));
        _refused(steps, learnFrom, steps.length + 1, E - SLOT, _err(ITronStateVerifier.NotARound.selector));
        _refused(steps, 1, vouchFrom, E - SLOT, _err(ITronStateVerifier.NotARound.selector));
        // A round of 26 slots.
        _refused(steps, learnFrom + 1, vouchFrom, E - SLOT, _err(ITronStateVerifier.WrongProducers.selector));
        // A round block that names no producer of the next list.
        steps[10].hint = NL;
        _refused(
            steps, learnFrom, vouchFrom, E - SLOT, abi.encodeWithSelector(ITronStateVerifier.BadSignature.selector, 10)
        );
        // A producer of the next list the round never shows.
        (steps,,) = _advanceSteps();
        steps[29] = steps[28];
        _refused(steps, learnFrom, vouchFrom, E - SLOT, _err(ITronStateVerifier.WrongProducers.selector));
        // Every producer shown, but within 26 slots: a list of 20 learned too fast is not a round.
        ITronStateVerifier.Producer[] memory n = _new();
        ITronStateVerifier.Producer[] memory twenty = new ITronStateVerifier.Producer[](20);
        Step[] memory quick = new Step[](45);
        (quick[0], quick[1], quick[2]) = (steps[0], steps[1], steps[2]);
        for (uint256 i = 0; i < 20; ++i) {
            twenty[i] = n[i];
            quick[3 + i] = Step(n[i].witness, _newPk(i), uint8(i), 1, 0, false);
        }
        for (uint256 i = 0; i < 22; ++i) {
            quick[23 + i] = steps[30 + (i < 19 ? i : 18)];
        }
        ITronStateVerifier.Header[] memory hs = _build(E - SLOT, quick);
        vm.expectRevert(ITronStateVerifier.NotARound.selector);
        verifier.advance(_old(), twenty, hs, 3, 23);
    }

    /// @dev A round one slot short: 26 producers in 26 consecutive slots. A full round of 27 slots would have shown the
    ///      27th, or shown that it missed its slot.
    function test_advance_aRoundIsTwentySevenSlots() public {
        (Step[] memory steps,,) = _advanceSteps();
        ITronStateVerifier.Producer[] memory n = _new();
        ITronStateVerifier.Producer[] memory most = new ITronStateVerifier.Producer[](26);
        Step[] memory short = new Step[](48);
        (short[0], short[1], short[2]) = (steps[0], steps[1], steps[2]);
        for (uint256 i = 0; i < 26; ++i) {
            most[i] = n[i];
            short[3 + i] = Step(n[i].witness, _newPk(i), uint8(i), 1, 0, false);
        }
        for (uint256 i = 0; i < 19; ++i) {
            short[29 + i] = steps[30 + i];
        }
        ITronStateVerifier.Header[] memory hs = _build(E - SLOT, short);
        vm.expectRevert(ITronStateVerifier.NotARound.selector);
        verifier.advance(_old(), most, hs, 3, 29);
        // One slot more, and the same 26 producers are a round: the 27th missed its slot.
        short[28].gap = 2;
        hs = _build(E - SLOT, short);
        verifier.advance(_old(), most, hs, 3, 29);
        assertEq(verifier.producerList(1).count, 26);
    }

    /// @dev The block after the maintenance is not learned: its producer may change its key before its turn in the
    ///      round comes round, as a key rotation there once could have stalled the verifier for good.
    function test_TRN2_theBlockAfterTheMaintenanceIsNotLearned() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        steps[2].pk = 0xD1FFE7E47;
        _advance(steps, learnFrom, vouchFrom, E - SLOT);
        assertEq(verifier.latestList(), 1);
    }

    /// @dev A learned producer is the witness its block names, with the key that signed it. Otherwise one key could be
    ///      learned under two witnesses and count twice in every quorum after, or any key under a real witness.
    function test_TRN5_learnsEachProducerWithItsOwnKey() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        ITronStateVerifier.Producer[] memory next = _new();
        // The last newcomer's entry carries producer 0's key, and its round block is one producer 0 made.
        next[26].key = next[0].key;
        steps[29] = Step(next[0].witness, _newPk(0), 26, 1, 0, false);
        ITronStateVerifier.Header[] memory hs = _build(E - SLOT, steps);
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.BadSignature.selector, 29));
        verifier.advance(_old(), next, hs, learnFrom, vouchFrom);
        // A real witness recorded with a key that did not sign its block.
        (steps,,) = _advanceSteps();
        next = _new();
        next[5].key = address(0xbad);
        hs = _build(E - SLOT, steps);
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.BadSignature.selector, 8));
        verifier.advance(_old(), next, hs, learnFrom, vouchFrom);
    }

    /// @dev Only the list before vouches, each producer with its own recorded key: a round cannot vouch for itself.
    function test_TRN4_onlyTheOldListVouches() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        steps[48].hint = NL;
        _refused(
            steps, learnFrom, vouchFrom, E - SLOT, abi.encodeWithSelector(ITronStateVerifier.NoQuorum.selector, 18)
        );
        // A newcomer, at its index in the next list, is no voucher.
        (steps,,) = _advanceSteps();
        steps[48] = Step(_new()[26].witness, _newPk(26), 26, 1, 0, false);
        _refused(
            steps, learnFrom, vouchFrom, E - SLOT, abi.encodeWithSelector(ITronStateVerifier.BadSignature.selector, 48)
        );
    }

    /// @dev Vouchers may sign in any later period, so producers absent for a period delay the next list, not stop it.
    function test_TRN3_vouchersMaySignLater() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        steps[40].gap = INTERVAL / SLOT;
        vm.warp(E / 1000 + 8 hours);
        _advance(steps, learnFrom, vouchFrom, E - SLOT);
        assertEq(verifier.producerList(1).start, E, "the round's period");
    }

    /// @dev A chain that halted past a boundary runs one maintenance, the grid holds, and the period passed over has no
    ///      list.
    function test_TRN9_passesOverAPeriodOnTheGrid() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        steps[1].gap = INTERVAL / SLOT + 2;
        _advance(steps, learnFrom, vouchFrom, E - SLOT);
        ITronStateVerifier.ProducerList memory l = verifier.producerList(1);
        assertEq(l.start, E + INTERVAL);
        assertEq(l.end, E + 2 * INTERVAL);
    }

    /// @dev A producer that writes its header so the verifier cannot, with a negative version and an unknown field,
    ///      neither stops the list nor a proof: both are written as Tron writes them.
    function test_TRN1_aPoisonedHeaderIsStillWritten() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        steps[15].poisoned = true;
        steps[35].poisoned = true;
        _advance(steps, learnFrom, vouchFrom, E - SLOT);
        assertEq(verifier.latestList(), 1);
    }

    /// @dev Two periods in a row, each list learned from its own round.
    function test_advance_periodAfterPeriod() public {
        (Step[] memory steps, uint256 learnFrom, uint256 vouchFrom) = _advanceSteps();
        _advance(steps, learnFrom, vouchFrom, E - SLOT);
        vm.warp((E + INTERVAL) / 1000 + 1 hours);
        // The next boundary: the new list vouches, and learns itself back.
        ITronStateVerifier.Producer[] memory n = _new();
        Step[] memory next = new Step[](49);
        next[0] = Step(n[26].witness, _newPk(26), NL, 1, 0, false);
        next[1] = Step(n[0].witness, _newPk(0), NL, 1, 0, false);
        next[2] = Step(n[24].witness, _newPk(24), NL, 3, 0, false);
        for (uint256 i = 0; i < 27; ++i) {
            next[3 + i] = Step(n[i].witness, _newPk(i), uint8(i), 1, 0, false);
        }
        for (uint256 i = 0; i < 19; ++i) {
            next[30 + i] = Step(n[i + 8].witness, _newPk(i + 8), uint8(i + 8), 1, 0, false);
        }
        verifier.advance(n, n, _build(E + INTERVAL - SLOT, next), 3, 30);
        assertEq(verifier.latestList(), 2);
        assertEq(verifier.producerList(2).start, E + INTERVAL);
    }

    // ---------------------------------------------------------------------
    // deployment
    // ---------------------------------------------------------------------

    function test_constructor_checksTheFirstList() public {
        ITronStateVerifier.Producer[] memory list = _old();
        vm.expectEmit();
        emit ITronStateVerifier.ListRecorded(0, keccak256(abi.encode(list)), E - INTERVAL, E, 27);
        TronStateVerifier v = new TronStateVerifier(list, E);
        assertEq(v.latestList(), 0);
        assertEq(v.QUORUM(), 19);
        assertEq(v.MAX_PRODUCERS(), 27);
        assertEq(v.SLOT(), 3000);
        assertEq(v.INTERVAL(), 21_600_000);
        assertEq(v.MAX_LAG(), 1 days);
        assertEq(v.NOT_LISTED(), 255);

        ITronStateVerifier.Producer[] memory big = new ITronStateVerifier.Producer[](28);
        for (uint256 i = 0; i < 28; ++i) {
            big[i] = ITronStateVerifier.Producer(address(uint160(0x1000 + i)), address(1));
        }
        vm.expectRevert(ITronStateVerifier.BadList.selector);
        new TronStateVerifier(big, E);
        (list[1], list[2]) = (list[2], list[1]);
        vm.expectRevert(abi.encodeWithSelector(ITronStateVerifier.NotAscending.selector, 2));
        new TronStateVerifier(list, E);
    }
}
