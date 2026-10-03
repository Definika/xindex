// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStellarStateVerifier} from "../interfaces/IStellarStateVerifier.sol";
import {ISP1Verifier} from "../interfaces/ISP1Verifier.sol";
// Named by the `@inheritdoc` of `verifySlots`, which must name the interface that declares it.
// aderyn-fp-next-line(unused-import)
import {IVaultStateVerifier} from "../interfaces/IVaultStateVerifier.sol";

/// @title StellarStateVerifier
/// @notice A Stellar vault's slots on Ethereum, from an SP1 proof that the vault's `attest` succeeded in a ledger that
///         Tier 1 externalized (`proofs/stellar`, `design/2026-10-03-near-stellar-interfaces.md`).
/// @dev No owner, no upgrade, no state: every proof stands alone under the quorum set pinned at deployment, since
///      Stellar names its validators nowhere on chain, and nothing is to be followed from one ledger to the next. A
///      proof per call costs one Groth16 check; a checkpoint the calls shared would need the result set, 30 to 110 KB of
///      XDR, posted and hashed here on every call, and its Soroban results parsed in Solidity, for no saving.
///
///      The statement proves, in the zkVM: validators satisfying the pinned quorum set signed `EXTERNALIZE` for slot
///      `M` and one value; the value opens to ledger `M`'s transaction set, which names header `M-1`; headers link back
///      to ledger `N`; `N`'s result set holds a successful `InvokeHostFunction` whose success preimage holds the event
///      the vault's `attest` emits for the record. This contract checks what the statement takes as given: the
///      network, the quorum set, the vault, the record's slots and values, and the ledger's age.
contract StellarStateVerifier is IStellarStateVerifier {
    /// @inheritdoc IStellarStateVerifier
    uint256 public constant MAX_LAG = 1 days;
    /// @inheritdoc IStellarStateVerifier
    bytes32 public constant ATTEST_DOMAIN = keccak256("xindex.v4.vault-attest");

    /// @inheritdoc IStellarStateVerifier
    ISP1Verifier public immutable SP1_VERIFIER;
    /// @inheritdoc IStellarStateVerifier
    bytes32 public immutable PROGRAM_KEY;
    /// @inheritdoc IStellarStateVerifier
    bytes32 public immutable NETWORK_ID;
    /// @inheritdoc IStellarStateVerifier
    bytes32 public immutable QUORUM_SET_HASH;
    /// @inheritdoc IStellarStateVerifier
    uint256 public immutable CHAIN_ID;
    /// @inheritdoc IStellarStateVerifier
    bytes32 public immutable VAULT_ID;

    constructor(
        ISP1Verifier sp1Verifier,
        bytes32 programKey,
        bytes32 networkId,
        bytes32 quorumSetHash,
        uint256 chainId,
        bytes32 vaultId
    ) {
        if (
            address(sp1Verifier) == address(0) || programKey == bytes32(0) || networkId == bytes32(0)
                || quorumSetHash == bytes32(0) || chainId == 0 || vaultId == bytes32(0)
        ) revert ZeroValue();
        SP1_VERIFIER = sp1Verifier;
        PROGRAM_KEY = programKey;
        NETWORK_ID = networkId;
        QUORUM_SET_HASH = quorumSetHash;
        CHAIN_ID = chainId;
        VAULT_ID = vaultId;
    }

    /// @inheritdoc IVaultStateVerifier
    /// @dev `proof` is `abi.encode(SlotsProof)`. Returns ledger `N`'s number and close time, and the attested values.
    function verifySlots(address account, bytes32[] calldata slots, bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, uint256 timestamp, bytes32[] memory values)
    {
        // The hub names a vault by the low 20 bytes of its id (`_vaultAddress`).
        // forge-lint: disable-next-line(unsafe-typecast)
        if (account != address(uint160(uint256(VAULT_ID)))) revert WrongAccount(account);
        SlotsProof memory p = abi.decode(proof, (SlotsProof));
        if (p.values.length != slots.length) revert LengthMismatch();
        SP1_VERIFIER.verifyProof(PROGRAM_KEY, p.publicValues, p.proof);
        PublicValues memory v = abi.decode(p.publicValues, (PublicValues));
        if (v.networkId != NETWORK_ID) revert WrongNetwork(v.networkId);
        if (v.quorumSetHash != QUORUM_SET_HASH) revert WrongQuorumSet(v.quorumSetHash);
        if (v.vaultId != VAULT_ID) revert WrongVault(v.vaultId);
        // Keys outlive their validators' tenure, and nothing slashes a Stellar validator: keys retired or leaked later
        // could sign a ledger dated long ago at no cost. A day bounds that, as it does for every other verifier.
        if (block.timestamp > uint256(v.closeTime) + MAX_LAG) revert TooOld(v.closeTime);
        // The record the vault emitted, written here from the requested slots and the given values: equal only if the
        // vault attested exactly these slots, in this order, with exactly these values.
        if (keccak256(abi.encode(ATTEST_DOMAIN, CHAIN_ID, VAULT_ID, slots, p.values)) != v.recordHash) {
            revert NotAttested(v.recordHash);
        }
        return (v.ledger, v.closeTime, p.values);
    }
}
