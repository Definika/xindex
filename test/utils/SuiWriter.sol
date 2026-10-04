// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISuiStateVerifier} from "../../src/interfaces/ISuiStateVerifier.sol";
import {Blake2b} from "../../src/libraries/Blake2b.sol";
import {Bls12381MinSig} from "../../src/libraries/Bls12381MinSig.sol";

/// @notice Sui's encodings and a committee's signatures, written for the tests independently of the verifier: BCS
///         byte by byte from Sui's layouts, keys and signatures by scalar multiplication on the EIP-2537 precompiles.
///         `test/fixtures/sui/chain.json` pins the writers against mainnet's own bytes. Needs Prague.
abstract contract SuiWriter is Test {
    /// @dev The group order r, and the G2 generator.
    uint256 constant R = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001;
    bytes constant G2 = hex"00000000000000000000000000000000024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8"
        hex"0000000000000000000000000000000013e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e"
        hex"000000000000000000000000000000000ce5d527727d6e118cc9cdc6da2e351aadfd9baa8cbdd3a76d429a695160d12c923ac9cc3baca289e193548608b82801"
        hex"000000000000000000000000000000000606c4a02ea734cc32acd2b02bc28b99cb3e287e85a763af267492ab572e99ab3f370d275cec1da1aaa9075ff05f79be";
    bytes32 constant ATTEST_DOMAIN = keccak256("xindex.v4.vault-attest");
    address constant G1MSM = address(0x0c);
    address constant G2MSM = address(0x0e);
    bytes3 constant INTENT = 0x020000;

    /// @notice A committee with its secret keys, in the committee's order.
    struct Signers {
        ISuiStateVerifier.Committee committee;
        uint256[] secrets;
        bytes[] compressed;
    }

    // ---------------------------------------------------------------------
    // BCS
    // ---------------------------------------------------------------------

    function _le(uint64 v) internal pure returns (bytes memory out) {
        out = new bytes(8);
        for (uint256 i = 0; i < 8; ++i) {
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    function _uleb(uint256 n) internal pure returns (bytes memory out) {
        while (n >= 0x80) {
            out = bytes.concat(out, bytes1(uint8(n % 0x80 + 0x80)));
            n /= 0x80;
        }
        out = bytes.concat(out, bytes1(uint8(n)));
    }

    /// @dev A summary's BCS, `named` (the end-of-epoch option and committee, for `update`) between its commitments
    ///      and `rest`.
    function _summary(ISuiStateVerifier.Checkpoint memory s, bytes memory named) internal pure returns (bytes memory) {
        bytes memory out = bytes.concat(_le(s.epoch), _le(s.sequenceNumber), _le(s.networkTotalTransactions));
        out = bytes.concat(out, hex"20", s.contentDigest, hex"0120", s.previousDigest);
        for (uint256 i = 0; i < 4; ++i) {
            out = bytes.concat(out, _le(s.epochRollingGasCostSummary[i]));
        }
        out = bytes.concat(out, _le(s.timestampMs), _uleb(s.checkpointCommitments.length));
        for (uint256 i = 0; i < s.checkpointCommitments.length; ++i) {
            ISuiStateVerifier.Commitment memory c = s.checkpointCommitments[i];
            out = bytes.concat(out, _uleb(c.kind), hex"20", c.digest);
        }
        return bytes.concat(out, named, s.rest);
    }

    /// @dev What the committee signs: the intent, the summary and the epoch.
    function _message(ISuiStateVerifier.Checkpoint memory s, bytes memory named) internal pure returns (bytes memory) {
        return bytes.concat(INTENT, _summary(s, named), _le(s.epoch));
    }

    /// @dev `Some(EndOfEpochData)` up to its committee: the option, the count, each compressed key and power.
    function _named(bytes[] memory compressed, uint64[] memory powers) internal pure returns (bytes memory out) {
        out = bytes.concat(hex"01", _uleb(compressed.length));
        for (uint256 i = 0; i < compressed.length; ++i) {
            out = bytes.concat(out, hex"60", compressed[i], _le(powers[i]));
        }
    }

    /// @dev An object of type `package::module::name`, as Sui writes it to digest it.
    function _object(
        bytes32 package,
        string memory module,
        string memory name,
        bool publicTransfer,
        uint64 version,
        bytes memory contents,
        bytes memory owner,
        bytes32 previousTransaction,
        uint64 storageRebate
    ) internal pure returns (bytes memory) {
        bytes memory head = bytes.concat("Object::", hex"0000", package, _uleb(bytes(module).length), bytes(module));
        head = bytes.concat(
            head, _uleb(bytes(name).length), bytes(name), hex"00", publicTransfer ? bytes1(0x01) : bytes1(0x00)
        );
        return bytes.concat(
            head,
            _le(version),
            _uleb(contents.length),
            contents,
            owner,
            hex"20",
            previousTransaction,
            _le(storageRebate)
        );
    }

    function _leafHash(bytes32 id, uint64 version, bytes32 digest) internal view returns (bytes32) {
        return Blake2b.hash256(bytes.concat(hex"00", id, _le(version), hex"20", digest));
    }

    /// @dev The tree over `leaves` (leaf hashes), fastcrypto's way, and the path of leaf `index`.
    function _tree(bytes32[] memory leaves, uint256 index) internal view returns (bytes32 root, bytes32[] memory path) {
        bytes32[] memory level = leaves;
        bytes32[] memory steps = new bytes32[](64);
        uint256 depth = 0;
        while (level.length > 1) {
            uint256 n = (level.length + 1) / 2;
            bytes32[] memory up = new bytes32[](n);
            for (uint256 i = 0; i < n; ++i) {
                bytes32 right = 2 * i + 1 < level.length ? level[2 * i + 1] : bytes32(0);
                up[i] = Blake2b.hash256(bytes.concat(hex"01", level[2 * i], right));
            }
            uint256 sibling = index ^ 1;
            steps[depth++] = sibling < level.length ? level[sibling] : bytes32(0);
            index /= 2;
            level = up;
        }
        root = level[0];
        path = new bytes32[](depth);
        for (uint256 i = 0; i < depth; ++i) {
            path[i] = steps[i];
        }
    }

    function _artifactsDigest(bytes32 root) internal view returns (bytes32) {
        return Blake2b.hash256(bytes.concat(hex"0120", root));
    }

    // ---------------------------------------------------------------------
    // Keys and signatures
    // ---------------------------------------------------------------------

    function _msm(address precompile, bytes memory point, uint256 scalar) internal view returns (bytes memory out) {
        bool ok;
        (ok, out) = precompile.staticcall(bytes.concat(point, bytes32(scalar)));
        assertTrue(ok, "msm");
    }

    /// @dev `n` members with the secret keys a seed gives and the powers given, sorted by compressed key as Sui
    ///      orders a committee; `powers` follow the sorted order.
    function _signers(string memory seed, uint64[] memory powers) internal view returns (Signers memory) {
        uint256[] memory secrets = new uint256[](powers.length);
        for (uint256 i = 0; i < powers.length; ++i) {
            secrets[i] = uint256(keccak256(abi.encode(seed, i))) % R;
        }
        return _signersFrom(secrets, powers);
    }

    /// @dev The members with secret keys `secrets`, sorted by compressed key; `powers` follow the sorted order.
    function _signersFrom(uint256[] memory secrets, uint64[] memory powers) internal view returns (Signers memory s) {
        uint256 n = powers.length;
        bytes[] memory keys = new bytes[](n);
        bytes[] memory compressed = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            keys[i] = _msm(G2MSM, G2, secrets[i]);
            (bytes32 w0, bytes32 w1, bytes32 w2) = Bls12381MinSig.compressKey(keys[i], 0);
            compressed[i] = bytes.concat(w0, w1, w2);
        }
        for (uint256 i = 1; i < n; ++i) {
            for (uint256 j = i; j > 0 && _before(compressed[j], compressed[j - 1]); --j) {
                (compressed[j], compressed[j - 1]) = (compressed[j - 1], compressed[j]);
                (keys[j], keys[j - 1]) = (keys[j - 1], keys[j]);
                (secrets[j], secrets[j - 1]) = (secrets[j - 1], secrets[j]);
            }
        }
        bytes memory packed;
        for (uint256 i = 0; i < n; ++i) {
            packed = bytes.concat(packed, keys[i]);
        }
        s.committee = ISuiStateVerifier.Committee({keys: packed, powers: powers});
        s.secrets = secrets;
        s.compressed = compressed;
    }

    function _before(bytes memory a, bytes memory b) internal pure returns (bool) {
        for (uint256 i = 0; i < a.length; ++i) {
            if (a[i] != b[i]) return a[i] < b[i];
        }
        return false;
    }

    /// @dev The certificate of the members `mask` names on `message`.
    function _sign(Signers memory s, uint256 mask, bytes memory message)
        internal
        view
        returns (ISuiStateVerifier.Certificate memory c)
    {
        uint256 n = s.secrets.length;
        uint256 secret = 0;
        c.signers = new uint256[]((n + 255) / 256);
        for (uint256 i = 0; i < n; ++i) {
            if ((mask >> i) & 1 == 0) continue;
            secret = addmod(secret, s.secrets[i], R);
            c.signers[i / 256] |= 1 << (i % 256);
        }
        c.signature = _msm(G1MSM, Bls12381MinSig.hashToG1(message, Bls12381MinSig.DST), secret);
    }

    /// @dev Key `i` of packed keys.
    function _key(bytes memory keys, uint256 i) internal pure returns (bytes memory out) {
        out = new bytes(256);
        assembly {
            mcopy(add(out, 32), add(add(keys, 32), mul(i, 256)), 256)
        }
    }

    /// @dev `next` as `update` takes it from `current`: each key by its index there, or new.
    function _carry(ISuiStateVerifier.Committee memory current, ISuiStateVerifier.Committee memory next)
        internal
        pure
        returns (ISuiStateVerifier.NextCommittee memory n)
    {
        uint256 count = next.powers.length;
        uint256 known = current.keys.length / 256;
        n.powers = next.powers;
        for (uint256 i = 0; i < count; ++i) {
            bytes32 key = keccak256(_key(next.keys, i));
            uint256 source = type(uint16).max;
            for (uint256 j = 0; j < known; ++j) {
                if (keccak256(_key(current.keys, j)) == key) source = j;
            }
            n.sources = bytes.concat(n.sources, bytes2(uint16(source)));
            if (source == type(uint16).max) n.newKeys = bytes.concat(n.newKeys, _key(next.keys, i));
        }
    }

    function _hash(ISuiStateVerifier.Committee memory c) internal pure returns (bytes32) {
        return keccak256(abi.encode(c.keys, c.powers));
    }
}
