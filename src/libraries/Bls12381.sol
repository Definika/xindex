// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice BLS signatures on BLS12-381 through the EIP-2537 precompiles, in the form BNB Chain's finality votes use:
///         public keys in G1, signatures in G2, and the proof-of-possession ciphersuite of RFC 9380 and the IETF BLS
///         draft, `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`. Points are in EIP-2537's uncompressed encoding: each
///         coordinate of 48 bytes left-padded to 64. A key read from a chain comes compressed, 48 bytes, and
///         `checkKey` ties the uncompressed form a caller supplies to it.
library Bls12381 {
    error PrecompileFailed(address precompile);
    error BadKey();
    error IdentityKey();
    /// @notice A signature is not one uncompressed G2 point, EIP-2537's 256 bytes.
    error BadSignatureLength(uint256 length);

    address private constant MODEXP = address(0x05);
    address private constant G1ADD = address(0x0b);
    address private constant G2ADD = address(0x0d);
    address private constant PAIRING = address(0x0f);
    address private constant MAP_FP2_TO_G2 = address(0x11);

    uint256 internal constant G1_POINT = 128;
    uint256 internal constant G2_POINT = 256;
    uint256 internal constant COMPRESSED_G1 = 48;
    uint256 private constant FIELD = 48;
    uint256 private constant WORD = 32;
    /// @dev SHA-256 blocks in the 256 uniform bytes `hashToG2` expands: two Fp2 elements of two 64-byte chunks each.
    uint256 private constant XMD_BLOCKS = 8;
    uint256 private constant PAD = 16;

    /// @dev DST', the domain separation tag followed by its length: 43, which is the byte 0x2b.
    bytes private constant DST_PRIME = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_\x2b";
    /// @dev MODEXP's three sizes: a 64-byte base, a 1-byte exponent, a 48-byte modulus.
    bytes private constant MODEXP_SIZES = hex"0000000000000000000000000000000000000000000000000000000000000040"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"0000000000000000000000000000000000000000000000000000000000000030";
    bytes1 private constant ONE = 0x01;
    /// @dev expand_message_xmd's output length, 256, in two bytes, then its zero separator byte.
    bytes private constant LENGTH_AND_ZERO = hex"010000";
    /// @dev The base field modulus p.
    bytes private constant P =
        hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
    /// @dev (p - 1) / 2 in two words, the high 16 bytes and the low 32: a y above it is the "larger" of y and p - y.
    uint256 private constant HALF_P_HI = 0x0d0088f51cbff34d258dd3db21a5d66b;
    uint256 private constant HALF_P_LO = 0xb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd555;
    /// @dev The negated G1 generator, (x, p - y).
    bytes private constant NEG_G1 = hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb"
        hex"00000000000000000000000000000000114d1d6855d545a8aa7d76c8cf2e21f267816aef1db507c96655b9d5caac42364e6f38ba0ecb751bad54dcd6b939c2ca";

    /// @dev A compressed point's first three bits are flags: compressed, the identity, and y the larger root. A key
    ///      must be compressed and not the identity, so its top two bits are 0b10.
    uint256 private constant FLAG_SHIFT = 253;
    uint256 private constant COMPRESSED_NOT_IDENTITY = 0x2;
    uint256 private constant HALF_BITS = 128;
    uint256 private constant X_HI_MASK = (1 << 125) - 1; // the 125 bits of x under the flags, in a 16-byte word

    /// @notice Checks that `key`, uncompressed, is the point the compressed key `compressed` names: the same x, the y
    ///         its sign flag picks, on the curve (G1ADD checks that), and not the identity. Only one point on the curve
    ///         has that x and that sign, so `key` is then exactly the compressed key. The subgroup is not checked here:
    ///         a caller takes `compressed` from a source that checked it, as BNB Chain checks every vote key when a
    ///         validator registers it.
    /// @return point The key as the precompile returns it: adding the identity checks that both coordinates are field
    ///         elements and the point is on the curve, and gives the point back.
    function checkKey(bytes memory compressed, bytes memory key) internal view returns (bytes memory point) {
        checkSameKey(compressed, key);
        point = _call(G1ADD, bytes.concat(key, new bytes(G1_POINT)), G1_POINT);
    }

    /// @notice `checkKey` without the curve check, for a `key` already shown to be on the curve: the same x, the y its
    ///         sign flag picks, and not the identity.
    function checkSameKey(bytes memory compressed, bytes memory key) internal pure {
        if (compressed.length != COMPRESSED_G1 || key.length != G1_POINT) revert BadKey();
        (uint256 c0, uint256 c1) = abi.decode(bytes.concat(compressed, new bytes(PAD)), (uint256, uint256));
        (uint256 xHi, uint256 xLo, uint256 yHi, uint256 yLo) = abi.decode(key, (uint256, uint256, uint256, uint256));
        if (xHi | xLo | yHi | yLo == 0) revert IdentityKey();
        if (c0 >> (FLAG_SHIFT + 1) != COMPRESSED_NOT_IDENTITY) revert BadKey();
        if (xHi != (c0 >> HALF_BITS) & X_HI_MASK || xLo != (c0 << HALF_BITS) | (c1 >> HALF_BITS)) revert BadKey();
        bool larger = yHi > HALF_P_HI || (yHi == HALF_P_HI && yLo > HALF_P_LO);
        if (larger != ((c0 >> FLAG_SHIFT) & 1 == 1)) revert BadKey();
    }

    /// @notice The sum of two G1 points.
    function add(bytes memory a, bytes memory b) internal view returns (bytes memory) {
        return _call(G1ADD, bytes.concat(a, b), G1_POINT);
    }

    /// @notice Whether `signature` is the signature of `key`, a single or aggregate key other than the identity, on
    ///         `message`: `e(key, H(message)) == e(g1, signature)`. The pairing precompile checks that the signature
    ///         is a point of the subgroup.
    /// @dev The precompile reads its input as 384-byte pairs, so a key or signature of any other length would shift
    ///      the pairs or add some of the caller's choosing: `O ‖ key ‖ −H(message)` as a signature cancels the first
    ///      pair and verifies any message (BLS-1). Both lengths are exact.
    function verify(bytes memory key, bytes memory signature, bytes memory message) internal view returns (bool) {
        if (key.length != G1_POINT) revert BadKey();
        if (signature.length != G2_POINT) revert BadSignatureLength(signature.length);
        if (keccak256(key) == keccak256(new bytes(G1_POINT))) revert IdentityKey();
        bytes memory result = _call(PAIRING, bytes.concat(key, hashToG2(message), NEG_G1, signature), WORD);
        return abi.decode(result, (uint256)) == 1;
    }

    /// @notice RFC 9380 `hash_to_curve` onto G2 with `expand_message_xmd` over SHA-256 and this library's DST. The
    ///         map precompile clears the cofactor of each point, and clearing is linear, so the sum is the hash.
    function hashToG2(bytes memory message) internal view returns (bytes memory) {
        bytes32[XMD_BLOCKS] memory b = _expandMessageXmd(message);
        bytes memory q0 = _call(MAP_FP2_TO_G2, bytes.concat(_reduce(b[0], b[1]), _reduce(b[2], b[3])), G2_POINT);
        bytes memory q1 = _call(MAP_FP2_TO_G2, bytes.concat(_reduce(b[4], b[5]), _reduce(b[6], b[7])), G2_POINT);
        return _call(G2ADD, bytes.concat(q0, q1), G2_POINT);
    }

    /// @dev 256 uniform bytes as eight SHA-256 blocks, chained as RFC 9380 section 5.3.1 sets out: two field elements
    ///      of Fp2, each two 64-byte chunks.
    function _expandMessageXmd(bytes memory message) private pure returns (bytes32[XMD_BLOCKS] memory b) {
        // Z_pad (one SHA-256 block of zeros), the message, the output length and a zero byte, DST'.
        bytes32 b0 = sha256(bytes.concat(new bytes(2 * WORD), message, LENGTH_AND_ZERO, DST_PRIME));
        b[0] = sha256(bytes.concat(b0, ONE, DST_PRIME));
        for (uint8 i = 1; i < b.length; ++i) {
            b[i] = sha256(bytes.concat(b0 ^ b[i - 1], bytes1(i + 1), DST_PRIME));
        }
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
