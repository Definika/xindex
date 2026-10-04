// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice BLAKE2b (RFC 7693), unkeyed, on the EIP-152 compression precompile at 0x09: the hash Sui digests objects,
///         checkpoints and its Merkle trees with, at a 32-byte output (fastcrypto `hash.rs:178`, `Blake2b256`).
library Blake2b {
    error PrecompileFailed(address precompile);
    error BadOutputLength(uint256 outLength);

    address private constant BLAKE2F = address(0x09);
    /// @dev The precompile's address as a number, for the assembly that calls it.
    uint256 private constant BLAKE2F_ADDRESS = 0x09;
    uint256 private constant DIGEST_256 = 32;
    uint256 private constant MAX_OUT = 64;

    /// @dev EIP-152's input, 213 bytes: the rounds (4 bytes, big-endian), the state h (64), the block m (128), the
    ///      counter t (16) and the final flag f (1). The output, the new state, is written back over h.
    uint256 private constant INPUT = 213;
    uint256 private constant H_AT = 4;
    uint256 private constant H_HIGH_AT = 36;
    uint256 private constant M_AT = 68;
    uint256 private constant T_AT = 196;
    uint256 private constant F_AT = 212;
    uint256 private constant STATE = 64;
    uint256 private constant BLOCK = 128;
    uint256 private constant WORD = 32;
    uint256 private constant FREE_MEMORY = 0x40;
    /// @dev BLAKE2b's twelve rounds, in the top four bytes of a word.
    uint256 private constant ROUNDS = 12 << 224;
    /// @dev The state's initial words, the IV in little-endian bytes. The first word's first eight bytes are XORed
    ///      with the parameter block's first word, `0x01010000 | outLength` (no key, a fanout and a depth of one),
    ///      little-endian: its bytes reversed, in the word's top bytes.
    uint256 private constant IV_0 = 0x08c9bcf367e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5;
    uint256 private constant IV_1 = 0xd182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b;
    uint256 private constant PARAMETERS = 0x0101 << 224;
    uint256 private constant OUT_LENGTH_SHIFT = 248;
    /// @dev Byte-reversing a u64: swap bytes, then pairs, then halves.
    uint256 private constant ODD_BYTES = 0xFF00FF00_FF00FF00;
    uint256 private constant EVEN_BYTES = 0x00FF00FF_00FF00FF;
    uint256 private constant ODD_PAIRS = 0xFFFF0000_FFFF0000;
    uint256 private constant EVEN_PAIRS = 0x0000FFFF_0000FFFF;
    uint256 private constant HIGH_HALF = 0xFFFFFFFF << 32;
    uint256 private constant BYTE = 8;
    uint256 private constant PAIR = 16;
    uint256 private constant HALF = 32;
    uint256 private constant U64_SHIFT = 192;

    /// @notice BLAKE2b-256 of `data`.
    function hash256(bytes memory data) internal view returns (bytes32 digest) {
        (digest,) = hash(data, DIGEST_256);
    }

    /// @notice BLAKE2b of `data` with an output of `outLength` bytes, 1 to 64: the first `outLength` bytes of the two
    ///         words returned, which are the final state.
    function hash(bytes memory data, uint256 outLength) internal view returns (bytes32 head, bytes32 tail) {
        if (outLength == 0 || outLength > MAX_OUT) revert BadOutputLength(outLength);
        uint256 h0 = IV_0 ^ PARAMETERS ^ (outLength << OUT_LENGTH_SHIFT);
        bool ok = true;
        // The precompile's input is built in place, block by block, in scratch memory past the free memory pointer:
        // Solidity would allocate and copy each block.
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            let input := mload(FREE_MEMORY)
            mstore(input, ROUNDS)
            mstore(add(input, H_AT), h0)
            mstore(add(input, H_HIGH_AT), IV_1)
            let chunk := add(input, M_AT)
            let src := add(data, WORD)
            let len := mload(data)
            let done := 0
            for {} 1 {} {
                let remaining := sub(len, done)
                let last := iszero(gt(remaining, BLOCK))
                if last {
                    // The last block, zero-padded.
                    mstore(chunk, 0)
                    mstore(add(chunk, WORD), 0)
                    mstore(add(chunk, mul(2, WORD)), 0)
                    mstore(add(chunk, mul(3, WORD)), 0)
                    mcopy(chunk, add(src, done), remaining)
                    done := len
                }
                if iszero(last) {
                    mcopy(chunk, add(src, done), BLOCK)
                    done := add(done, BLOCK)
                }
                // t: the bytes hashed so far, a little-endian u64, then eight zero bytes; f follows.
                let t := or(shr(BYTE, and(done, ODD_BYTES)), shl(BYTE, and(done, EVEN_BYTES)))
                t := or(shr(PAIR, and(t, ODD_PAIRS)), shl(PAIR, and(t, EVEN_PAIRS)))
                t := or(shr(HALF, t), and(shl(HALF, t), HIGH_HALF))
                mstore(add(input, T_AT), shl(U64_SHIFT, t))
                mstore8(add(input, F_AT), last)
                ok := and(ok, staticcall(gas(), BLAKE2F_ADDRESS, input, INPUT, add(input, H_AT), STATE))
                ok := and(ok, eq(returndatasize(), STATE))
                if last { break }
            }
            head := mload(add(input, H_AT))
            tail := mload(add(input, H_HIGH_AT))
        }
        if (!ok) revert PrecompileFailed(BLAKE2F);
    }
}
