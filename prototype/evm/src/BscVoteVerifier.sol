// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Checks a BNB Chain fast-finality vote on Ethereum with the EIP-2537 BLS12-381 precompiles: the voters'
///         keys are summed, the vote hash is hashed to G2 as RFC 9380 prescribes for Ethereum's proof-of-possession
///         scheme, and one pairing check compares the two sides. A prototype for measuring gas: the caller supplies
///         the voters' keys uncompressed, and a real verifier would also track the validator set and check each key
///         against the compressed one its epoch header committed.
contract BscVoteVerifier {
    address private constant G1ADD = address(0x0b);
    address private constant G2ADD = address(0x0d);
    address private constant PAIRING = address(0x0f);
    address private constant MAP_FP2_TO_G2 = address(0x11);
    address private constant MODEXP = address(0x05);

    bytes private constant DST = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";
    /// @dev The BLS12-381 base field modulus, 48 bytes.
    bytes private constant P =
        hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
    /// @dev The negated G1 generator in EIP-2537 encoding (x, p - y), each coordinate left-padded to 64 bytes.
    bytes private constant NEG_G1 =
        hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb"
        hex"00000000000000000000000000000000114d1d6855d545a8aa7d76c8cf2e21f267816aef1db507c96655b9d5caac42364e6f38ba0ecb751bad54dcd6b939c2ca";

    error PrecompileFailed(address precompile);

    /// @return ok Whether the voters' aggregate key signed `voteHash` with `signature`.
    function verifyVote(bytes[] calldata voterKeys, bytes calldata signature, bytes32 voteHash)
        external
        view
        returns (bool ok)
    {
        bytes memory aggregate = voterKeys[0];
        for (uint256 i = 1; i < voterKeys.length; ++i) {
            aggregate = _call(G1ADD, bytes.concat(aggregate, voterKeys[i]), 128);
        }
        bytes memory h = hashToG2(abi.encodePacked(voteHash));
        bytes memory result = _call(PAIRING, bytes.concat(aggregate, h, NEG_G1, signature), 32);
        ok = abi.decode(result, (uint256)) == 1;
    }

    /// @notice RFC 9380 hash_to_curve for G2 with expand_message_xmd over SHA-256, as Ethereum's BLS signatures use.
    function hashToG2(bytes memory message) public view returns (bytes memory) {
        bytes memory uniform = _expandMessageXmd(message);
        bytes memory q0 = _call(MAP_FP2_TO_G2, bytes.concat(_reduce(uniform, 0), _reduce(uniform, 64)), 256);
        bytes memory q1 = _call(MAP_FP2_TO_G2, bytes.concat(_reduce(uniform, 128), _reduce(uniform, 192)), 256);
        return _call(G2ADD, bytes.concat(q0, q1), 256);
    }

    /// @dev 256 uniform bytes: eight SHA-256 blocks chained as RFC 9380 section 5.3.1 sets out.
    function _expandMessageXmd(bytes memory message) private pure returns (bytes memory out) {
        bytes memory dstPrime = bytes.concat(DST, bytes1(uint8(DST.length)));
        bytes32 b0 = sha256(bytes.concat(new bytes(64), message, hex"0100", hex"00", dstPrime));
        bytes32 bi = sha256(bytes.concat(b0, hex"01", dstPrime));
        out = new bytes(256);
        for (uint256 i = 1; i <= 8; ++i) {
            if (i > 1) bi = sha256(bytes.concat(b0 ^ bi, bytes1(uint8(i)), dstPrime));
            assembly ("memory-safe") {
                mstore(add(add(out, 32), mul(sub(i, 1), 32)), bi)
            }
        }
    }

    /// @dev The 64 bytes at `offset` reduced mod p, returned left-padded to 64 bytes as EIP-2537 takes a field element.
    function _reduce(bytes memory uniform, uint256 offset) private view returns (bytes memory) {
        bytes memory chunk = new bytes(64);
        for (uint256 i = 0; i < 64; ++i) {
            chunk[i] = uniform[offset + i];
        }
        bytes memory reduced =
            _call(MODEXP, bytes.concat(bytes32(uint256(64)), bytes32(uint256(1)), bytes32(uint256(48)), chunk, hex"01", P), 48);
        return bytes.concat(new bytes(16), reduced);
    }

    function _call(address precompile, bytes memory input, uint256 outLength) private view returns (bytes memory out) {
        bool success;
        (success, out) = precompile.staticcall(input);
        if (!success || out.length != outLength) revert PrecompileFailed(precompile);
    }
}
