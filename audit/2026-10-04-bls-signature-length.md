# BLS-1: a signature of the wrong length verified any message (4 October 2026)

Found while building Sui's state verifier, whose BLS12-381 min-sig library checks every length and so drew the
comparison with `src/libraries/Bls12381.sol`. Fixed the same day. Nothing was deployed.

| Id | Severity | Finding | Status |
|---|---|---|---|
| BLS-1 | Critical | `Bls12381.verify` passed `key ‖ H(m) ‖ −g1 ‖ signature` to the pairing precompile without checking either length. The precompile reads its input as 384-byte pairs, so a 640-byte "signature" `O ‖ key ‖ −H(m)` adds the pair `(key, −H(m))`, which cancels `e(key, H(m))`, and the check passes for any message under any key. `BnbStateVerifier` takes a vote's signature from calldata, so anyone could have certified a BNB Chain header nobody signed (any state root), then proven any vault state through `verifySlots`, and so minted against deposits that never happened. | FIXED: `verify` refuses a key that is not 128 bytes (`BadKey`) and a signature that is not 256 bytes (`BadSignatureLength`), before the precompile runs. Tests: `test_BLS1_aKeyOrSignatureOfAnyOtherLengthIsRefused` (`test/Bls12381.t.sol`), and `test_BLS1_aLongSignatureCannotForgeAHeader` (`test/BnbStateVerifier.t.sol`, which runs on the mainnet and the testnet fixtures), each failing without the fix. |

**Reach.** `Bls12381.verify` has one caller in `src/`, `BnbStateVerifier._checkVote`, for `advance`, `verifyHeader` and
`verifySlots`. The research test `test/SolanaCertificate.t.sol` calls it with exact lengths. No other verifier passes
caller-sized points to a precompile: P1 and P2 decode fixed-size Groth16 proofs, TRON's verifier recovers secp256k1
signatures, and NEAR's and Stellar's check one SP1 proof each.

**Why the reviews missed it.** The library's tests and the BNB verifier's checked real votes and malformed points of
the right length; none supplied a signature of another length. A precompile that consumes variable-length input as a
sequence of fixed records turns every unchecked length into a choice of extra records.
