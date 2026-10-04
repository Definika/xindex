// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Blake2b} from "../src/libraries/Blake2b.sol";
import {SuiProofHarness} from "./mocks/SuiProofHarness.sol";

/// @notice BLAKE2b on the EIP-152 precompile, against the reference implementation's known answers
///         (BLAKE2/BLAKE2 `testvectors/blake2-kat.json` at ed1974ea83433eba7b2d95c5dcd9ac33cb847913, unkeyed BLAKE2b,
///         the input bytes 0, 1, 2 and so on), RFC 7693's appendix A, and BLAKE2b-256 answers of Python's `hashlib`,
///         which wraps the reference code, across the block boundary.
contract Blake2bTest is Test {
    SuiProofHarness h;

    function setUp() public {
        h = new SuiProofHarness();
    }

    function _sequence(uint256 n, uint256 modulus) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = bytes1(uint8(i % modulus));
        }
    }

    function _512(bytes memory data) internal view returns (bytes memory) {
        (bytes32 head, bytes32 tail) = h.blake2b(data, 64);
        return bytes.concat(head, tail);
    }

    function test_theReferenceKnownAnswers() public view {
        uint256[7] memory lengths = [uint256(0), 1, 2, 127, 128, 129, 255];
        bytes[7] memory answers = [
            bytes(
                hex"786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"
            ),
            hex"2fa3f686df876995167e7c2e5d74c4c7b6e48f8068fe0e44208344d480f7904c36963e44115fe3eb2a3ac8694c28bcb4f5a0f3276f2e79487d8219057a506e4b",
            hex"1c08798dc641aba9dee435e22519a4729a09b2bfe0ff00ef2dcd8ed6f8a07d15eaf4aee52bbf18ab5608a6190f70b90486c8a7d4873710b1115d3debbb4327b5",
            hex"b6292669ccd38d5f01caae96ba272c76a879a45743afa0725d83b9ebb26665b731f1848c52f11972b6644f554c064fa90780dbbbf3a89d4fc31f67df3e5857ef",
            hex"2319e3789c47e2daa5fe807f61bec2a1a6537fa03f19ff32e87eecbfd64b7e0e8ccff439ac333b040f19b0c4ddd11a61e24ac1fe0f10a039806c5dcc0da3d115",
            hex"f59711d44a031d5f97a9413c065d1e614c417ede998590325f49bad2fd444d3e4418be19aec4e11449ac1a57207898bc57d76a1bcf3566292c20c683a5c4648f",
            hex"5b21c5fd8868367612474fa2e70e9cfa2201ffeee8fafab5797ad58fefa17c9b5b107da4a3db6320baaf2c8617d5a51df914ae88da3867c2d41f0cc14fa67928"
        ];
        for (uint256 i = 0; i < lengths.length; ++i) {
            assertEq(_512(_sequence(lengths[i], 256)), answers[i]);
        }
    }

    function test_rfc7693() public view {
        assertEq(
            _512("abc"),
            hex"ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"
        );
    }

    function test_blake2b256() public view {
        assertEq(h.hash256(""), 0x0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8);
        assertEq(h.hash256("abc"), 0xbddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319);
        assertEq(
            h.hash256("The quick brown fox jumps over the lazy dog"),
            0x01718cec35cd3d796dd00020e0bfecb473ad23457d063b75eff29c0ffa2e58a9
        );
        assertEq(h.hash256(_sequence(128, 251)), 0xc3582f71ebb2be66fa5dd750f80baae97554f3b015663c8be377cfcb2488c1d1);
        assertEq(h.hash256(_sequence(129, 251)), 0xf7f3c46ba2564ff4c4c162da1f5b605f9f1c4aa6a20652a9f9a337c1a2f5b9c9);
        assertEq(h.hash256(_sequence(256, 251)), 0x582f782226018ec33076bd8d1c42413530ac7e1126260ffc0f306ba3befc3f24);
        assertEq(h.hash256(_sequence(1000, 251)), 0xb372d0608f720c8c3dd41e9c8eecb10143b41abe520b616607e754bf79c08331);
    }

    /// @dev The output length is a parameter of the hash, not a truncation.
    function test_otherOutputLengths() public view {
        (bytes32 head,) = h.blake2b("abc", 20);
        assertEq(bytes20(head), bytes20(hex"384264f676f39536840523f284921cdc68b6846b"));
        (head,) = h.blake2b("abc", 1);
        assertEq(bytes1(head), bytes1(0x6b));
    }

    /// @dev The bytes past the data's end, in memory, are not hashed with its last block: here they are the rest of
    ///      a longer sequence, which the library is called on in place.
    function test_theLastBlockIsPadded() public view {
        bytes memory data = _sequence(200, 251);
        assembly {
            mstore(data, 3)
        }
        assertEq(Blake2b.hash256(data), 0x3d8c3d594928271f44aad7a04b177154806867bcf918e1549c0bc16f9da2b09b);
    }

    function test_refusesAnOutputLengthOutsideOneTo64() public {
        vm.expectRevert(abi.encodeWithSelector(Blake2b.BadOutputLength.selector, 0));
        h.blake2b("abc", 0);
        vm.expectRevert(abi.encodeWithSelector(Blake2b.BadOutputLength.selector, 65));
        h.blake2b("abc", 65);
    }

    function test_aFailingPrecompileIsRefused() public {
        vm.mockCallRevert(address(9), bytes(""), bytes(""));
        vm.expectRevert(abi.encodeWithSelector(Blake2b.PrecompileFailed.selector, address(9)));
        h.hash256("abc");
    }
}
