// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice BLS signatures on BLS12-381 through the EIP-2537 precompiles, in the form Sui's validators sign checkpoints
///         with: signatures in G1, public keys in G2, and the basic ciphersuite of RFC 9380 and the IETF BLS draft,
///         `BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_` (MystenLabs/fastcrypto at
///         576f00e2d466593ad2c643210b09efb5b6d4aff1, `bls12381/min_sig/mod.rs:9-10`). The twin of `Bls12381.sol`,
///         which has the opposite arrangement for BNB Chain's votes. Points are in EIP-2537's uncompressed encoding:
///         each coordinate of 48 bytes left-padded to 64, an Fp2 element `c0` then `c1`. A key is written compressed,
///         96 bytes, as Sui lists it: `x.c1` then `x.c0`, big-endian, the top three bits the flags compressed,
///         identity and sign (supranational/blst at 4f72b303888fd02d402a786eeb3d35ac38263ac2, `src/e2.c:251`, the sign
///         from `sgn0_pty_mod_384x`, `src/no_asm.h:538-554`).
library Bls12381MinSig {
    error PrecompileFailed(address precompile);
    error BadPoint();
    error IdentityKey();

    address private constant MODEXP = address(0x05);
    address private constant G1ADD = address(0x0b);
    address private constant G2ADD = address(0x0d);
    /// @dev G2ADD's address as a number, for the assembly that calls it.
    uint256 private constant G2ADD_ADDRESS = 0x0d;
    address private constant PAIRING = address(0x0f);
    address private constant MAP_FP_TO_G1 = address(0x10);

    uint256 internal constant G1_POINT = 128;
    uint256 internal constant G2_POINT = 256;
    /// @notice The ciphersuite's domain separation tag, Sui's for every authority signature.
    bytes internal constant DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_";

    uint256 private constant TWO_G2_POINTS = 512;
    /// @dev The offsets of a G2 point's words after its first.
    uint256 private constant X0_LO = 32;
    uint256 private constant X1_HI = 64;
    uint256 private constant X1_LO = 96;
    uint256 private constant Y0_HI = 128;
    uint256 private constant Y0_LO = 160;
    uint256 private constant Y1_HI = 192;
    uint256 private constant Y1_LO = 224;
    uint256 private constant FREE_MEMORY = 0x40;
    uint256 private constant FIELD = 48;
    uint256 private constant WORD = 32;
    uint256 private constant PAD = 16;
    uint256 private constant HALF_BITS = 128;
    /// @dev Z_pad: one SHA-256 block of zeros.
    uint256 private constant Z_PAD = 64;
    /// @dev expand_message_xmd's output length, 128 (two field elements of 64 bytes), in two bytes, then its zero
    ///      separator byte.
    bytes private constant LENGTH_AND_ZERO = hex"008000";
    /// @dev MODEXP's three sizes: a 64-byte base, a 1-byte exponent, a 48-byte modulus.
    bytes private constant MODEXP_SIZES = hex"0000000000000000000000000000000000000000000000000000000000000040"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"0000000000000000000000000000000000000000000000000000000000000030";
    bytes1 private constant ONE = 0x01;
    /// @dev The base field modulus p.
    bytes private constant P =
        hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
    /// @dev (p - 1) / 2 in two words, the high 16 bytes and the low 32: a coordinate above it is the "larger" root.
    uint256 private constant HALF_P_HI = 0x0d0088f51cbff34d258dd3db21a5d66b;
    uint256 private constant HALF_P_LO = 0xb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd555;
    /// @dev A compressed key's flags: compressed, and y the larger root.
    uint256 private constant COMPRESSED = 0x80 << 248;
    uint256 private constant LARGER = 0x20 << 248;
    /// @dev The negated G2 generator, (x, -y).
    bytes private constant NEG_G2 = hex"00000000000000000000000000000000024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8"
        hex"0000000000000000000000000000000013e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e"
        hex"000000000000000000000000000000000d1b3cc2c7027888be51d9ef691d77bcb679afda66c73f17f9ee3837a55024f78c71363275a75d75d86bab79f74782aa"
        hex"0000000000000000000000000000000013fa4d4a0ad8b1ce186ed5061789213d993923066dddaf1040bc3ff59f825c78df74f2d75467e25e0f55f8a00fa030ed";

    /// @notice Whether `signature` is the signature of `key`, a single or aggregate key other than the identity, on
    ///         `message` under `DST`: `e(signature, g2) == e(H(message), key)`.
    function verify(bytes memory key, bytes memory signature, bytes memory message) internal view returns (bool) {
        return verifyHashed(key, signature, hashToG1(message, DST));
    }

    /// @notice `verify` on a message already hashed to G1. The pairing precompile checks that the signature and the
    ///         key are points of their subgroups. Every length is checked, as the precompile reads its input as pairs:
    ///         a longer signature would add pairs of the caller's choosing.
    function verifyHashed(bytes memory key, bytes memory signature, bytes memory point) internal view returns (bool) {
        if (key.length != G2_POINT || signature.length != G1_POINT || point.length != G1_POINT) revert BadPoint();
        if (keccak256(key) == keccak256(new bytes(G2_POINT))) revert IdentityKey();
        bytes memory result = _call(PAIRING, bytes.concat(signature, NEG_G2, point, key), WORD);
        return abi.decode(result, (uint256)) == 1;
    }

    /// @notice RFC 9380 `hash_to_curve` onto G1 with `expand_message_xmd` over SHA-256 and the tag `dst`, at most 255
    ///         bytes. The map precompile clears the cofactor of each point, and clearing is linear, so the sum is the
    ///         hash.
    function hashToG1(bytes memory message, bytes memory dst) internal view returns (bytes memory) {
        bytes memory dstPrime = bytes.concat(dst, bytes1(SafeCast.toUint8(dst.length)));
        // Z_pad, the message, the output length and a zero byte, DST'; then the four blocks of 32 bytes, chained.
        bytes32 b0 = sha256(bytes.concat(new bytes(Z_PAD), message, LENGTH_AND_ZERO, dstPrime));
        bytes32 b1 = sha256(bytes.concat(b0, ONE, dstPrime));
        bytes32 b2 = sha256(bytes.concat(b0 ^ b1, bytes1(0x02), dstPrime));
        bytes32 b3 = sha256(bytes.concat(b0 ^ b2, bytes1(0x03), dstPrime));
        bytes32 b4 = sha256(bytes.concat(b0 ^ b3, bytes1(0x04), dstPrime));
        bytes memory q0 = _call(MAP_FP_TO_G1, _reduce(b1, b2), G1_POINT);
        bytes memory q1 = _call(MAP_FP_TO_G1, _reduce(b3, b4), G1_POINT);
        return _call(G1ADD, bytes.concat(q0, q1), G1_POINT);
    }

    /// @notice Adds key `index` of `keys`, packed keys of 256 bytes each, to `sum`, in place. G2ADD checks that both
    ///         are points of the curve, but not of the subgroup.
    function addKey(bytes memory sum, bytes memory keys, uint256 index) internal view {
        if (sum.length != G2_POINT || keys.length < (index + 1) * G2_POINT) revert BadPoint();
        bool ok;
        // The sum and the key go to the precompile from scratch memory past the free memory pointer, and the result
        // comes back over the sum: Solidity would allocate a copy of both and of the result at every addition.
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            let input := mload(FREE_MEMORY)
            mcopy(input, add(sum, WORD), G2_POINT)
            mcopy(add(input, G2_POINT), add(add(keys, WORD), mul(index, G2_POINT)), G2_POINT)
            ok := staticcall(gas(), G2ADD_ADDRESS, input, TWO_G2_POINTS, add(sum, WORD), G2_POINT)
            ok := and(ok, eq(returndatasize(), G2_POINT))
        }
        if (!ok) revert PrecompileFailed(G2ADD);
    }

    /// @notice Copies key `j` of `from` to key `i` of `to`, both packed keys of 256 bytes each.
    function copyKey(bytes memory to, uint256 i, bytes memory from, uint256 j) internal pure {
        if (to.length < (i + 1) * G2_POINT || from.length < (j + 1) * G2_POINT) revert BadPoint();
        // A key is copied in one piece; Solidity cannot slice memory.
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            mcopy(add(add(to, WORD), mul(i, G2_POINT)), add(add(from, WORD), mul(j, G2_POINT)), G2_POINT)
        }
    }

    /// @notice Key `index` of `keys` compressed, as three words: `x.c1`, then `x.c0`, under the flags compressed and,
    ///         where y is the larger root, sign. Fp2's "larger" compares `c1`, or `c0` when `c1` is zero (the ZCash
    ///         serialization blst follows). Only a point of the curve compresses faithfully; G2ADD checks that.
    function compressKey(bytes memory keys, uint256 index) internal pure returns (bytes32 w0, bytes32 w1, bytes32 w2) {
        if (keys.length < (index + 1) * G2_POINT) revert BadPoint();
        // The key's eight words: x.c0, x.c1, y.c0 and y.c1, each a 16-byte high word and a 32-byte low one.
        uint256 x0Hi;
        uint256 x0Lo;
        uint256 x1Hi;
        uint256 x1Lo;
        uint256 y0Hi;
        uint256 y0Lo;
        uint256 y1Hi;
        uint256 y1Lo;
        // Read in place out of the packed keys, with no copy.
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            let k := add(add(keys, WORD), mul(index, G2_POINT))
            x0Hi := mload(k)
            x0Lo := mload(add(k, X0_LO))
            x1Hi := mload(add(k, X1_HI))
            x1Lo := mload(add(k, X1_LO))
            y0Hi := mload(add(k, Y0_HI))
            y0Lo := mload(add(k, Y0_LO))
            y1Hi := mload(add(k, Y1_HI))
            y1Lo := mload(add(k, Y1_LO))
        }
        if (x0Hi | x0Lo | x1Hi | x1Lo | y0Hi | y0Lo | y1Hi | y1Lo == 0) revert IdentityKey();
        bool larger = (y1Hi | y1Lo) != 0 ? _larger(y1Hi, y1Lo) : _larger(y0Hi, y0Lo);
        w0 = bytes32((x1Hi << HALF_BITS) | (x1Lo >> HALF_BITS) | COMPRESSED | (larger ? LARGER : 0));
        w1 = bytes32((x1Lo << HALF_BITS) | x0Hi);
        w2 = bytes32(x0Lo);
    }

    /// @dev Whether the field element `hi || lo` exceeds (p - 1) / 2.
    function _larger(uint256 hi, uint256 lo) private pure returns (bool) {
        return hi > HALF_P_HI || (hi == HALF_P_HI && lo > HALF_P_LO);
    }

    /// @dev The 64 bytes `hi || lo` reduced mod p, left-padded to 64 bytes as EIP-2537 takes a field element.
    function _reduce(bytes32 hi, bytes32 lo) private view returns (bytes memory) {
        bytes memory input = bytes.concat(MODEXP_SIZES, hi, lo, ONE, P);
        return bytes.concat(new bytes(PAD), _call(MODEXP, input, FIELD));
    }

    function _call(address precompile, bytes memory input, uint256 outLength) private view returns (bytes memory out) {
        bool success;
        // A precompile has no ABI to call it through; success and the output's length are checked below.
        // forge-lint: disable-next-line(low-level-calls)
        (success, out) = precompile.staticcall(input);
        if (!success || out.length != outLength) revert PrecompileFailed(precompile);
    }
}
