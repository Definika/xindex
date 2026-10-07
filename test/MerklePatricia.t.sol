// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RlpReader} from "../src/libraries/RlpReader.sol";
import {MerklePatricia} from "../src/libraries/MerklePatricia.sol";
import {ProofHarness} from "./mocks/ProofHarness.sol";
import {RlpWriter} from "./utils/RlpWriter.sol";

/// @notice The RLP reader and the Merkle-Patricia walker: a real BNB Chain header and `eth_getProof` for WBNB's slot 0,
///         and small tries built here for the shapes real proofs rarely show (absent keys, embedded nodes, bad nodes).
contract MerklePatriciaTest is Test {
    ProofHarness h;

    bytes header;
    bytes32 blockHash;
    bytes32 stateRoot;
    uint256 blockNumber;
    address account;
    bytes32 slot;
    bytes32 value;
    bytes[] accountProof;
    bytes[] storageProof;

    bytes constant EMPTY = hex"80";

    function setUp() public {
        h = new ProofHarness();
        string memory json = vm.readFile("test/fixtures/bnb/wbnb-slot0.json");
        header = vm.parseJsonBytes(json, ".header");
        blockHash = vm.parseJsonBytes32(json, ".blockHash");
        stateRoot = vm.parseJsonBytes32(json, ".stateRoot");
        blockNumber = vm.parseJsonUint(json, ".block");
        account = vm.parseJsonAddress(json, ".account");
        slot = vm.parseJsonBytes32(json, ".slot");
        value = vm.parseJsonBytes32(json, ".value");
        bytes[] memory a = vm.parseJsonBytesArray(json, ".accountProof");
        bytes[] memory s = vm.parseJsonBytesArray(json, ".storageProof");
        for (uint256 i = 0; i < a.length; ++i) {
            accountProof.push(a[i]);
        }
        for (uint256 i = 0; i < s.length; ++i) {
            storageProof.push(s[i]);
        }
    }

    // ---------------------------------------------------------------------
    // a real BNB Chain proof (block 124,888,813: WBNB's name, "Wrapped BNB", in slot 0)
    // ---------------------------------------------------------------------

    function test_theRealHeaderDecodes() public view {
        assertEq(keccak256(header), blockHash);
        assertEq(h.toBytes32(_field(header, 3)), stateRoot, "the state root is the header's fourth field");
        assertEq(h.toUint(_field(header, 8)), blockNumber, "the number is the ninth");
    }

    function test_theRealSlotIsProved() public view {
        assertEq(h.storageAt(stateRoot, account, slot, accountProof, storageProof), value);
    }

    function test_aTamperedNodeIsRefused() public {
        bytes[] memory sp = storageProof;
        sp[2][40] = bytes1(uint8(sp[2][40]) ^ 1);
        vm.expectRevert(abi.encodeWithSelector(MerklePatricia.BadProof.selector, 2));
        h.storageAt(stateRoot, account, slot, accountProof, sp);
    }

    function test_aWrongRootIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(MerklePatricia.BadProof.selector, 0));
        h.storageAt(bytes32(uint256(stateRoot) ^ 1), account, slot, accountProof, storageProof);
    }

    /// @dev Slot 1's path leaves the recorded nodes at the second: its branch child is another node's hash.
    function test_theNodesProveNoOtherSlot() public {
        vm.expectRevert(abi.encodeWithSelector(MerklePatricia.BadProof.selector, 1));
        h.storageAt(stateRoot, account, bytes32(uint256(1)), accountProof, storageProof);
    }

    function test_aTruncatedProofIsRefused() public {
        bytes[] memory sp = new bytes[](storageProof.length - 1);
        for (uint256 i = 0; i < sp.length; ++i) {
            sp[i] = storageProof[i];
        }
        vm.expectRevert(abi.encodeWithSelector(MerklePatricia.BadProof.selector, sp.length));
        h.storageAt(stateRoot, account, slot, accountProof, sp);
    }

    // ---------------------------------------------------------------------
    // built tries
    // ---------------------------------------------------------------------

    /// @dev A trie of one account whose storage holds one slot; an absent account and an absent slot read as zero.
    function test_storageAt_readsZeroForWhatIsAbsent() public view {
        bytes32 slotKey = keccak256(abi.encodePacked(bytes32(uint256(5))));
        bytes memory slotLeaf = _leaf(slotKey, 0, _str(_str(hex"0102")));
        bytes32 storageRoot = keccak256(slotLeaf);
        bytes32 accountKey = keccak256(abi.encodePacked(account));
        bytes[] memory fields = new bytes[](4);
        fields[0] = _str(hex"01");
        fields[1] = EMPTY;
        fields[2] = _str(abi.encodePacked(storageRoot));
        fields[3] = _str(abi.encodePacked(keccak256("")));
        bytes memory accountLeaf = _leaf(accountKey, 0, _str(_list(fields)));
        bytes32 root = keccak256(accountLeaf);

        bytes[] memory ap = _one(accountLeaf);
        bytes[] memory sp = _one(slotLeaf);
        assertEq(h.storageAt(root, account, bytes32(uint256(5)), ap, sp), bytes32(uint256(0x0102)));
        assertEq(h.storageAt(root, account, bytes32(uint256(6)), ap, sp), 0, "another slot is absent");
        assertEq(h.storageAt(root, address(1), bytes32(uint256(5)), ap, sp), 0, "another account is absent");
    }

    /// @dev A branch whose children are two hashed leaves: a key under an empty child is absent.
    function test_get_aBranchWithAnEmptyChild() public view {
        bytes32 k1 = bytes32(uint256(0x1) << 252 | 7);
        bytes32 k2 = bytes32(uint256(0x2) << 252 | 7);
        bytes memory l1 = _leaf(k1, 1, _str(hex"aa"));
        bytes memory l2 = _leaf(k2, 1, _str(hex"bb"));
        bytes[] memory items = _emptyBranch();
        items[1] = _str(abi.encodePacked(keccak256(l1)));
        items[2] = _str(abi.encodePacked(keccak256(l2)));
        bytes memory branch = _list(items);
        bytes32 root = keccak256(branch);

        (bool found, bytes memory v) = h.get(root, k2, _two(branch, l2));
        assertTrue(found);
        assertEq(v, hex"bb");
        (found,) = h.get(root, bytes32(uint256(0x5) << 252), _one(branch));
        assertFalse(found, "nibble 5 is an empty child");
    }

    /// @dev An extension over 62 nibbles to a branch holding a leaf small enough to be embedded in it.
    function test_get_anExtensionAndAnEmbeddedLeaf() public view {
        bytes32 key = keccak256("embedded");
        bytes memory tiny = _leaf(key, 63, _str(hex"01"));
        assertLt(tiny.length, 32, "small enough to embed");
        bytes[] memory items = _emptyBranch();
        items[_nib(key, 62)] = tiny; // embedded: the node itself, not its hash
        bytes memory branch = _list(items);
        bytes memory ext = _node(_hp(key, 0, 62, false), _str(abi.encodePacked(keccak256(branch))));
        bytes32 root = keccak256(ext);

        (bool found, bytes memory v) = h.get(root, key, _two(ext, branch));
        assertTrue(found);
        assertEq(v, hex"01");
        bytes32 diverges = key ^ bytes32(uint256(1) << 200); // differs inside the extension's path
        (found,) = h.get(root, diverges, _one(ext));
        assertFalse(found, "the extension's path does not continue the key");
    }

    /// @dev A leaf whose path would run past the key's 64 nibbles cannot be the key: absent, not an error.
    function test_get_aPathLongerThanTheKeyIsAbsent() public view {
        bytes32 key = bytes32(uint256(0x3) << 252 | 5);
        bytes memory tooLong = _leaf(key, 0, _str(hex"01")); // 64 nibbles, reached after the branch used one
        bytes[] memory items = _emptyBranch();
        items[3] = _str(abi.encodePacked(keccak256(tooLong)));
        bytes memory branch = _list(items);
        (bool found,) = h.get(keccak256(branch), key, _two(branch, tooLong));
        assertFalse(found);
    }

    function test_get_badNodes() public {
        bytes32 key = keccak256("k");
        // a node of three items
        bytes[] memory three = new bytes[](3);
        (three[0], three[1], three[2]) = (EMPTY, EMPTY, EMPTY);
        bytes memory odd = _list(three);
        vm.expectRevert(abi.encodeWithSelector(MerklePatricia.BadProof.selector, 0));
        h.get(keccak256(odd), key, _one(odd));
        // a leaf that ends before the key does
        bytes memory early = _node(_hp(key, 0, 60, true), _str(hex"01"));
        vm.expectRevert(abi.encodeWithSelector(MerklePatricia.BadProof.selector, 0));
        h.get(keccak256(early), key, _one(early));
        // a branch after all 64 nibbles
        bytes memory branch = _list(_emptyBranch());
        bytes memory ext = _node(_hp(key, 0, 64, false), _str(abi.encodePacked(keccak256(branch))));
        vm.expectRevert(abi.encodeWithSelector(MerklePatricia.BadProof.selector, 1));
        h.get(keccak256(ext), key, _two(ext, branch));
        // no proof at all
        vm.expectRevert(abi.encodeWithSelector(MerklePatricia.BadProof.selector, 0));
        h.get(keccak256(ext), key, new bytes[](0));
        // an extension whose child is neither a hash nor a node
        bytes memory dangling = _node(_hp(key, 0, 10, false), EMPTY);
        vm.expectRevert(RlpReader.BadRlp.selector);
        h.get(keccak256(dangling), key, _one(dangling));
    }

    function test_get_badPathEncodings() public {
        bytes32 key = keccak256("k");
        bytes memory flag4 = _node(_str(hex"40"), _str(hex"01"));
        vm.expectRevert(RlpReader.BadRlp.selector);
        h.get(keccak256(flag4), key, _one(flag4));
        bytes memory padded = _node(_str(hex"21"), _str(hex"01")); // an even leaf path must pad with a zero nibble
        vm.expectRevert(RlpReader.BadRlp.selector);
        h.get(keccak256(padded), key, _one(padded));
        bytes memory emptyPath = _node(EMPTY, _str(hex"01"));
        vm.expectRevert(RlpReader.BadRlp.selector);
        h.get(keccak256(emptyPath), key, _one(emptyPath));
        bytes[] memory listPath = new bytes[](2);
        (listPath[0], listPath[1]) = (_list(new bytes[](0)), _str(hex"01"));
        bytes memory node = _list(listPath);
        vm.expectRevert(RlpReader.BadRlp.selector);
        h.get(keccak256(node), key, _one(node));
    }

    // ---------------------------------------------------------------------
    // the RLP reader
    // ---------------------------------------------------------------------

    function test_rlp_decodesEachForm() public view {
        assertEq(h.toUint(hex"05"), 5, "a single byte is itself");
        assertEq(h.toUint(hex"820102"), 0x0102, "a short string");
        assertEq(h.toUint(hex"80"), 0, "the empty string is zero");
        bytes memory long = new bytes(60);
        long[59] = 0x07;
        assertEq(h.toBytes(_str(long)), long, "a long string");
        bytes[] memory items = new bytes[](30);
        for (uint256 i = 0; i < items.length; ++i) {
            items[i] = _str(hex"0102");
        }
        bytes memory longList = _list(items);
        assertGe(longList.length, 58, "a long list");
        assertEq(h.count(longList), 30);
        assertEq(h.at(longList, 29), hex"0102");
        assertEq(h.byteAt(hex"820102", 1), 2);
        bytes memory forty = new bytes(40);
        forty[1] = 0x11;
        forty[39] = 0x22;
        assertEq(h.wordAt(_str(forty), 8), bytes32(uint256(0x22)), "the word at an offset");
        assertEq(h.slice(_str(forty), 1, 2), hex"1100");
        assertEq(h.uintAt(_str(forty), 1, 1), 0x11);
        assertEq(h.uintAt(_str(forty), 8, 32), 0x22);
        assertEq(h.toBytes32(_str(abi.encodePacked(bytes32(uint256(9))))), bytes32(uint256(9)));
    }

    function test_rlp_refusesMalformedItems() public view {
        _refuse(abi.encodeCall(h.toUint, (hex"")), "empty input");
        _refuse(abi.encodeCall(h.toUint, (hex"0506")), "a trailing byte");
        _refuse(abi.encodeCall(h.toUint, (hex"850102")), "a string running past its end");
        _refuse(abi.encodeCall(h.toBytes, (hex"b9")), "a length running past its end");
        _refuse(abi.encodeCall(h.toBytes, (hex"f90001")), "a long list shorter than its length");
        _refuse(abi.encodeCall(h.count, (hex"820102")), "count of a string");
        _refuse(abi.encodeCall(h.at, (hex"820102", 0)), "an item of a string");
        _refuse(abi.encodeCall(h.at, (hex"c20102", 2)), "an item past the end");
        _refuse(abi.encodeCall(h.byteAt, (hex"c20102", 0)), "a byte of a list");
        _refuse(abi.encodeCall(h.byteAt, (hex"820102", 2)), "a byte past the end");
        _refuse(abi.encodeCall(h.toBytes32, (hex"820102")), "a word of two bytes");
        _refuse(abi.encodeCall(h.toBytes32, (hex"c0")), "a word of a list");
        _refuse(abi.encodeCall(h.toUint, (_str(new bytes(33)))), "a number of 33 bytes");
        _refuse(abi.encodeCall(h.toUint, (hex"c0")), "a number of a list");
        _refuse(abi.encodeCall(h.toBytes, (hex"c0")), "the bytes of a list");
        bytes memory forty = _str(new bytes(40));
        _refuse(abi.encodeCall(h.wordAt, (forty, 9)), "a word past the end");
        _refuse(abi.encodeCall(h.wordAt, (hex"c0", 0)), "a word of a list");
        _refuse(abi.encodeCall(h.slice, (forty, 39, 2)), "a slice past the end");
        _refuse(abi.encodeCall(h.slice, (hex"c0", 0, 0)), "a slice of a list");
        _refuse(abi.encodeCall(h.uintAt, (forty, 0, 0)), "a number of no bytes");
        _refuse(abi.encodeCall(h.uintAt, (forty, 0, 33)), "a number of 33 bytes");
        _refuse(abi.encodeCall(h.uintAt, (forty, 39, 2)), "a number past the end");
        _refuse(abi.encodeCall(h.uintAt, (hex"c0", 0, 1)), "a number of a list");
        _refuse(abi.encodeCall(h.toUint, (hex"b8")), "a long string whose length byte is missing");
    }

    // ---------------------------------------------------------------------
    // helpers: an RLP writer and trie nodes
    // ---------------------------------------------------------------------

    // ---------------------------------------------------------------------
    // random tries and garbage
    // ---------------------------------------------------------------------

    /// @dev Every case of `test/fixtures/trie/random.json`: tries built by the reference implementation in its
    ///      generator, with a proof of each key and of absent keys that diverge at a leaf, inside an extension or at an
    ///      empty branch slot. The walker must agree with the reference on every verdict and every value.
    function test_get_matchesTheReferenceTries() public view {
        string memory json = vm.readFile("test/fixtures/trie/random.json");
        uint256 n = vm.parseJsonUint(json, ".count");
        assertGt(n, 400, "the fixture is whole");
        for (uint256 i = 0; i < n; ++i) {
            string memory c = string.concat(".cases[", vm.toString(i), "]");
            (bool found, bytes memory value) = h.getKey(
                vm.parseJsonBytes32(json, string.concat(c, ".root")),
                vm.parseJsonBytes32(json, string.concat(c, ".key")),
                vm.parseJsonUint(json, string.concat(c, ".nibbles")),
                vm.parseJsonBytesArray(json, string.concat(c, ".proof"))
            );
            bool expected = vm.parseJsonBool(json, string.concat(c, ".found"));
            assertEq(found, expected, string.concat("verdict of case ", vm.toString(i)));
            if (expected) {
                assertEq(
                    value,
                    vm.parseJsonBytes(json, string.concat(c, ".value")),
                    string.concat("value of case ", vm.toString(i))
                );
            }
        }
    }

    /// @dev Random bytes reach the reader only as a list whose children it walks: it either refuses them with BadRlp,
    ///      or every child it returns lies inside the list, and the child past the last is refused.
    function testFuzz_rlp_aListOfGarbageIsRefusedOrStaysInside(bytes memory payload) public view {
        bytes memory data = _listOf(payload);
        (bool ok, bytes memory ret) = address(h).staticcall(abi.encodeCall(h.count, (data)));
        if (!ok) {
            assertEq(bytes4(ret), RlpReader.BadRlp.selector, "refused for another reason");
            return;
        }
        uint256 n = abi.decode(ret, (uint256));
        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            total += h.lengthAt(data, i);
        }
        assertLe(total, payload.length, "children larger than the list");
        _refuse(abi.encodeCall(h.at, (data, n)), "the child past the last");
    }

    /// @dev Random bytes as one item: refused with BadRlp, or read as a string of at most their length and as a number
    ///      only when that string fits a word.
    function testFuzz_rlp_garbageAsOneItemIsRefusedOrBounded(bytes memory data) public view {
        (bool ok, bytes memory ret) = address(h).staticcall(abi.encodeCall(h.toBytes, (data)));
        if (!ok) {
            assertEq(bytes4(ret), RlpReader.BadRlp.selector, "refused for another reason");
            (ok, ret) = address(h).staticcall(abi.encodeCall(h.count, (data)));
            if (!ok) assertEq(bytes4(ret), RlpReader.BadRlp.selector, "a list refused for another reason");
            return;
        }
        bytes memory out = abi.decode(ret, (bytes));
        assertLe(out.length, data.length, "a string longer than its encoding");
        (ok, ret) = address(h).staticcall(abi.encodeCall(h.toUint, (data)));
        assertEq(ok, out.length <= 32, "a number of the wrong size");
        if (ok) assertEq(abi.decode(ret, (uint256)), _bigEndian(out), "a number read wrongly");
    }

    function _listOf(bytes memory payload) internal pure returns (bytes memory) {
        if (payload.length <= 55) return abi.encodePacked(bytes1(uint8(0xc0 + payload.length)), payload);
        if (payload.length < 256) return abi.encodePacked(bytes1(0xf8), bytes1(uint8(payload.length)), payload);
        return abi.encodePacked(bytes1(0xf9), bytes2(uint16(payload.length)), payload);
    }

    function _bigEndian(bytes memory b) internal pure returns (uint256 value) {
        for (uint256 i = 0; i < b.length; ++i) {
            value = (value << 8) | uint8(b[i]);
        }
    }

    function _refuse(bytes memory call, string memory what) internal view {
        (bool ok, bytes memory ret) = address(h).staticcall(call);
        assertFalse(ok, what);
        assertEq(bytes4(ret), RlpReader.BadRlp.selector, what);
    }

    function _field(bytes memory rlpList, uint256 index) internal view returns (bytes memory) {
        return _str(h.at(rlpList, index));
    }

    function _str(bytes memory b) internal pure returns (bytes memory) {
        return RlpWriter.str(b);
    }

    function _list(bytes[] memory items) internal pure returns (bytes memory) {
        return RlpWriter.list(items);
    }

    function _nib(bytes32 key, uint256 i) internal pure returns (uint256) {
        return (uint256(key) >> (252 - 4 * i)) & 0x0f;
    }

    /// @dev The hex-prefix encoding of nibbles [from, to) of `key`, as an RLP string.
    function _hp(bytes32 key, uint256 from, uint256 to, bool leaf) internal pure returns (bytes memory) {
        uint256 n = to - from;
        bool odd = n % 2 == 1;
        bytes memory out = new bytes(n / 2 + 1);
        uint256 flag = (leaf ? 2 : 0) + (odd ? 1 : 0);
        uint256 k = from;
        if (odd) {
            out[0] = bytes1(uint8(flag << 4 | _nib(key, k)));
            ++k;
        } else {
            out[0] = bytes1(uint8(flag << 4));
        }
        for (uint256 j = 1; j < out.length; ++j) {
            out[j] = bytes1(uint8(_nib(key, k) << 4 | _nib(key, k + 1)));
            k += 2;
        }
        return _str(out);
    }

    function _node(bytes memory a, bytes memory b) internal pure returns (bytes memory) {
        bytes[] memory items = new bytes[](2);
        (items[0], items[1]) = (a, b);
        return _list(items);
    }

    function _leaf(bytes32 key, uint256 from, bytes memory valueItem) internal pure returns (bytes memory) {
        return _node(_hp(key, from, 64, true), valueItem);
    }

    function _emptyBranch() internal pure returns (bytes[] memory items) {
        items = new bytes[](17);
        for (uint256 i = 0; i < 17; ++i) {
            items[i] = EMPTY;
        }
    }

    function _one(bytes memory a) internal pure returns (bytes[] memory list) {
        list = new bytes[](1);
        list[0] = a;
    }

    function _two(bytes memory a, bytes memory b) internal pure returns (bytes[] memory list) {
        list = new bytes[](2);
        (list[0], list[1]) = (a, b);
    }
}
