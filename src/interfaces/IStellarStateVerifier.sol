// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultStateVerifier} from "./IVaultStateVerifier.sol";
import {ISP1Verifier} from "./ISP1Verifier.sol";

/// @notice A Stellar vault's state on Ethereum (`design/2026-10-03-near-stellar-interfaces.md`). Stellar commits to no
///         storage a light client can open, so a slot is proven as TRON's are: by the vault's `attest`, which succeeds
///         only when the vault holds every slot it is asked for, and then emits one event carrying
///         `abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots, values)`. An SP1 proof of `proofs/stellar`'s statement
///         shows that event in a successful transaction of ledger `N`, which validators of a pinned quorum set
///         externalized by signed SCP `EXTERNALIZE` statements, with ledger `N`'s number and close time.
interface IStellarStateVerifier is IVaultStateVerifier {
    /// @notice What `verifySlots` takes as its proof: the program's public values, the Groth16 proof of them, and the
    ///         values the vault attested, one per requested slot, in order.
    struct SlotsProof {
        bytes publicValues;
        bytes proof;
        bytes32[] values;
    }

    /// @notice The program's public values, `abi.encode` of these six words: the network and the quorum set the
    ///         signers satisfied, ledger `N` and its close time, the vault whose event it is, and the record's keccak.
    struct PublicValues {
        bytes32 networkId;
        bytes32 quorumSetHash;
        uint64 ledger;
        uint64 closeTime;
        bytes32 vaultId;
        bytes32 recordHash;
    }

    /// @notice The quorum set's validators signed a value other than this verifier's network's.
    error WrongNetwork(bytes32 networkId);
    /// @notice The proof's signers satisfy another quorum set than the one this verifier pins.
    error WrongQuorumSet(bytes32 quorumSetHash);
    /// @notice The proven event is another contract's.
    error WrongVault(bytes32 vaultId);
    /// @notice The hub asks about an account other than this verifier's vault.
    error WrongAccount(address account);
    /// @notice The proven ledger closed more than MAX_LAG ago.
    error TooOld(uint256 closeTime);
    /// @notice The vault attested other slots or values than the ones requested and given.
    error NotAttested(bytes32 recordHash);
    error LengthMismatch();
    error ZeroValue();

    /// @notice How old a proven ledger may be, by its close time: 1 day, as every other verifier's limit. Keys outlive
    ///         their validators' tenure and nothing slashes a Stellar validator, so keys retired or leaked later could
    ///         otherwise sign a ledger dated long ago at no cost.
    function MAX_LAG() external view returns (uint256);

    /// @notice `keccak256("xindex.v4.vault-attest")`, the record's first word.
    function ATTEST_DOMAIN() external view returns (bytes32);

    /// @notice SP1's Groth16 verifier, one deployment, never SP1's gateway, which has an owner.
    function SP1_VERIFIER() external view returns (ISP1Verifier);

    /// @notice The program's key: `stellar-proof vkey` of `proofs/stellar`.
    function PROGRAM_KEY() external view returns (bytes32);

    /// @notice SHA-256 of the network's passphrase, which every SCP envelope signs first.
    function NETWORK_ID() external view returns (bytes32);

    /// @notice SHA-256 of the pinned quorum set, `XDR(SCPQuorumSet)`: Tier 1's configuration. A new Tier 1 needs a new
    ///         verifier, which the factory rotates in behind its 30-day `ROTATION_DELAY`.
    function QUORUM_SET_HASH() external view returns (bytes32);

    /// @notice The factory's registry id of the chain: `stellar:pubnet` or `stellar:testnet`'s.
    function CHAIN_ID() external view returns (uint256);

    /// @notice The vault's contract id, the 32-byte id the factory registers.
    function VAULT_ID() external view returns (bytes32);
}
