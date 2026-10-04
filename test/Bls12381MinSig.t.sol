// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Bls12381MinSig} from "../src/libraries/Bls12381MinSig.sol";
import {SuiProofHarness} from "./mocks/SuiProofHarness.sol";
import {SuiWriter} from "./utils/SuiWriter.sol";

/// @notice BLS min-sig on the EIP-2537 precompiles: RFC 9380's hash to G1 against its own vectors (appendix J.9.1),
///         signatures made here by scalar multiplication, and every refusal. Sui's real signatures are checked in
///         `test/SuiStateVerifier.t.sol`. The precompiles exist from Prague on, so this suite runs on it.
/// forge-config: default.evm_version = "prague"
contract Bls12381MinSigTest is SuiWriter {
    SuiProofHarness h;

    bytes constant QUUX = "QUUX-V01-CS02-with-BLS12381G1_XMD:SHA-256_SSWU_RO_";
    uint256 constant P_HI = 0x1a0111ea397fe69a4b1ba7b6434bacd7;
    uint256 constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;
    uint256 constant HALF_HI = 0x0d0088f51cbff34d258dd3db21a5d66b;
    uint256 constant HALF_LO = 0xb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd555;

    function setUp() public {
        h = new SuiProofHarness();
    }

    function _repeat(string memory prefix, bytes1 c, uint256 n) internal pure returns (bytes memory out) {
        out = bytes(prefix);
        for (uint256 i = 0; i < n; ++i) {
            out = bytes.concat(out, c);
        }
    }

    function test_hashToG1_rfc9380() public view {
        bytes[5] memory messages =
            [bytes(""), "abc", "abcdef0123456789", _repeat("q128_", "q", 128), _repeat("a512_", "a", 512)];
        bytes[5] memory points = [
            bytes(
                hex"00000000000000000000000000000000052926add2207b76ca4fa57a8734416c8dc95e24501772c814278700eed6d1e4e8cf62d9c09db0fac349612b759e79a10000000000000000000000000000000008ba738453bfed09cb546dbb0783dbb3a5f1f566ed67bb6be0e8c67e2e81a4cc68ee29813bb7994998f3eae0c9c6a265"
            ),
            hex"0000000000000000000000000000000003567bc5ef9c690c2ab2ecdf6a96ef1c139cc0b2f284dca0a9a7943388a49a3aee664ba5379a7655d3c68900be2f6903000000000000000000000000000000000b9c15f3fe6e5cf4211f346271d7b01c8f3b28be689c8429c85b67af215533311f0b8dfaaa154fa6b88176c229f2885d",
            hex"0000000000000000000000000000000011e0b079dea29a68f0383ee94fed1b940995272407e3bb916bbf268c263ddd57a6a27200a784cbc248e84f357ce82d980000000000000000000000000000000003a87ae2caf14e8ee52e51fa2ed8eefe80f02457004ba4d486d6aa1f517c0889501dc7413753f9599b099ebcbbd2d709",
            hex"0000000000000000000000000000000015f68eaa693b95ccb85215dc65fa81038d69629f70aeee0d0f677cf22285e7bf58d7cb86eefe8f2e9bc3f8cb84fac488000000000000000000000000000000001807a1d50c29f430b8cafc4f8638dfeeadf51211e1602a5f184443076715f91bb90a48ba1e370edce6ae1062f5e6dd38",
            hex"00000000000000000000000000000000082aabae8b7dedb0e78aeb619ad3bfd9277a2f77ba7fad20ef6aabdc6c31d19ba5a6d12283553294c1825c4b3ca2dcfe0000000000000000000000000000000005b84ae5a942248eea39e1d91030458c40153f3b654ab7872d779ad1e942856a20c438e8d99bc8abfbf74729ce1f7ac8"
        ];
        assertEq(messages[3].length, 133);
        assertEq(messages[4].length, 517);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(h.hashToG1(messages[i], QUUX), points[i]);
        }
    }

    function test_hashToG1_theTagIsAtMost255Bytes() public {
        vm.expectRevert();
        h.hashToG1("abc", new bytes(256));
        h.hashToG1("abc", new bytes(255));
    }

    /// @dev A signature made here verifies for its key and message only, and only under Sui's tag.
    function test_verify_aSignatureMadeHere() public view {
        uint256 secret = uint256(keccak256("a secret key")) % R;
        bytes memory key = _msm(G2MSM, G2, secret);
        bytes memory signature = _msm(G1MSM, h.hashToG1("a checkpoint", Bls12381MinSig.DST), secret);
        assertTrue(h.verify(key, signature, "a checkpoint"));
        assertFalse(h.verify(key, signature, "another checkpoint"));
        assertFalse(h.verify(_msm(G2MSM, G2, secret + 1), signature, "a checkpoint"));
        assertFalse(
            h.verifyHashed(key, signature, h.hashToG1("a checkpoint", "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_"))
        );
        // Two keys aggregate, and their signatures with them.
        bytes memory other = _msm(G2MSM, G2, 7);
        bytes memory sum = h.addKey(h.addKey(new bytes(256), bytes.concat(key, other), 0), bytes.concat(key, other), 1);
        bytes memory both = _msm(G1MSM, h.hashToG1("a checkpoint", Bls12381MinSig.DST), addmod(secret, 7, R));
        assertTrue(h.verify(sum, both, "a checkpoint"));
        assertFalse(h.verify(key, both, "a checkpoint"));
    }

    function test_verify_everyLengthIsExact() public {
        bytes memory key = _msm(G2MSM, G2, 5);
        bytes memory signature = _msm(G1MSM, h.hashToG1("m", Bls12381MinSig.DST), 5);
        bytes memory point = h.hashToG1("m", Bls12381MinSig.DST);
        vm.expectRevert(Bls12381MinSig.BadPoint.selector);
        h.verifyHashed(bytes.concat(key, new bytes(1)), signature, point);
        vm.expectRevert(Bls12381MinSig.BadPoint.selector);
        h.verifyHashed(key, bytes.concat(signature, new bytes(384)), point);
        vm.expectRevert(Bls12381MinSig.BadPoint.selector);
        h.verifyHashed(key, signature, bytes.concat(point, new bytes(32)));
        assertTrue(h.verifyHashed(key, signature, point));
    }

    function test_verify_neverTheIdentityKey() public {
        vm.expectRevert(Bls12381MinSig.IdentityKey.selector);
        h.verify(new bytes(256), new bytes(128), "anything");
    }

    function test_verify_malformedPointsFailThePrecompile() public {
        bytes memory key = _msm(G2MSM, G2, 5);
        bytes memory signature = _msm(G1MSM, h.hashToG1("m", Bls12381MinSig.DST), 5);
        signature[0] = 0x01; // a coordinate's padding must be zero
        vm.expectRevert(abi.encodeWithSelector(Bls12381MinSig.PrecompileFailed.selector, address(0x0f)));
        h.verify(key, signature, "m");
    }

    // ---------------------------------------------------------------------
    // keys
    // ---------------------------------------------------------------------

    function test_addKey() public view {
        bytes memory key = _msm(G2MSM, G2, 9);
        assertEq(h.addKey(new bytes(256), key, 0), key, "the identity plus a key is the key");
        assertEq(h.addKey(key, _negate(key), 0), new bytes(256), "a key and its negation cancel");
        assertEq(h.addKey(_msm(G2MSM, G2, 4), bytes.concat(G2, key), 1), _msm(G2MSM, G2, 13));
    }

    function test_addKey_refusesWhatIsNotTwoPoints() public {
        bytes memory key = _msm(G2MSM, G2, 9);
        vm.expectRevert(Bls12381MinSig.BadPoint.selector);
        h.addKey(new bytes(255), key, 0);
        vm.expectRevert(Bls12381MinSig.BadPoint.selector);
        h.addKey(new bytes(256), key, 1);
        bytes memory off = bytes.concat(key);
        off[255] = bytes1(uint8(off[255]) ^ 1);
        vm.expectRevert(abi.encodeWithSelector(Bls12381MinSig.PrecompileFailed.selector, address(0x0d)));
        h.addKey(new bytes(256), off, 0);
    }

    function test_copyKey() public {
        bytes memory from = bytes.concat(G2, _msm(G2MSM, G2, 3));
        bytes memory to = new bytes(512);
        to = h.copyKey(to, 1, from, 1);
        assertEq(to, bytes.concat(new bytes(256), _msm(G2MSM, G2, 3)));
        vm.expectRevert(Bls12381MinSig.BadPoint.selector);
        h.copyKey(to, 2, from, 0);
        vm.expectRevert(Bls12381MinSig.BadPoint.selector);
        h.copyKey(to, 0, from, 2);
    }

    /// @dev The generator and its negation, compressed as every BLS library writes them: the flags 0x80, and 0x20
    ///      on the negation, whose y is the larger root.
    function test_compressKey_theGenerator() public view {
        bytes memory compressed =
            hex"93e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8";
        assertEq(h.compressKey(G2, 0), compressed);
        compressed[0] = 0xb3;
        assertEq(h.compressKey(_negate(G2), 0), compressed);
        assertEq(h.compressKey(bytes.concat(G2, _negate(G2)), 1), compressed);
        assertTrue(_before(h.compressKey(G2, 0), compressed), "a committee sorts the generator first");
        assertFalse(_before(compressed, compressed), "and never a key before itself");
    }

    /// @dev Fp2's sign reads y.c1, or y.c0 when y.c1 is zero, each against (p - 1) / 2. These words are not points:
    ///      the compression reads only the sign and x.
    function test_compressKey_theSignRule() public view {
        uint256[8] memory w;
        w[0] = 0x1234;
        (w[6], w[7]) = (HALF_HI, HALF_LO);
        assertEq(uint8(h.compressKey(abi.encode(w), 0)[0]), 0x80, "y.c1 at (p - 1) / 2 is not larger");
        (w[6], w[7]) = (HALF_HI, HALF_LO + 1);
        assertEq(uint8(h.compressKey(abi.encode(w), 0)[0]), 0xa0, "y.c1 just above it is");
        (w[6], w[7]) = (HALF_HI + 1, 0);
        assertEq(uint8(h.compressKey(abi.encode(w), 0)[0]), 0xa0, "a higher top word is");
        (w[6], w[7]) = (0, 0);
        (w[4], w[5]) = (HALF_HI, HALF_LO + 1);
        assertEq(uint8(h.compressKey(abi.encode(w), 0)[0]), 0xa0, "with y.c1 zero, y.c0 decides");
        (w[4], w[5]) = (0, 1);
        assertEq(uint8(h.compressKey(abi.encode(w), 0)[0]), 0x80);
    }

    function test_compressKey_refusals() public {
        vm.expectRevert(Bls12381MinSig.IdentityKey.selector);
        h.compressKey(new bytes(256), 0);
        vm.expectRevert(Bls12381MinSig.BadPoint.selector);
        h.compressKey(new bytes(511), 1);
    }

    /// @dev (x, -y), each coordinate of y negated mod p.
    function _negate(bytes memory point) internal pure returns (bytes memory) {
        uint256[8] memory w = abi.decode(point, (uint256[8]));
        (w[4], w[5]) = _neg(w[4], w[5]);
        (w[6], w[7]) = _neg(w[6], w[7]);
        return abi.encode(w);
    }

    function _neg(uint256 hi, uint256 lo) internal pure returns (uint256, uint256) {
        if (hi == 0 && lo == 0) return (0, 0);
        uint256 borrow = lo > P_LO ? 1 : 0;
        uint256 l;
        unchecked {
            l = P_LO - lo;
        }
        return (P_HI - hi - borrow, l);
    }
}
