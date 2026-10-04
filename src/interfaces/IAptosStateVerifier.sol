// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultStateVerifier} from "./IVaultStateVerifier.sol";
import {ISP1Verifier} from "./ISP1Verifier.sol";

/// @notice A vault's state on Aptos (`design/2026-10-04-four-chains-interfaces.md`), from SP1 proofs of AptosBFT's
///         signed ledger infos (`proofs/aptos`). The verifier trusts validator sets, each kept by its epoch: the first
///         from its deployer, each later one named by the ledger info that ended the epoch before, signed by more than
///         two thirds of a trusted set's voting power. A slot is proven by a successful `attest(slots, values)` of the
///         vault: its one `<package>::vault::Attested` event, in a transaction under a ledger info signed by such a
///         set.
interface IAptosStateVerifier is IVaultStateVerifier {
    /// @notice A set the verifier trusts, kept by its epoch: `keccak256` of its `ValidatorVerifier` BCS, and when the
    ///         ledger info that named it was signed, in microseconds, Aptos's unit.
    struct Trusted {
        bytes32 set;
        uint64 time;
    }

    /// @notice What `verifySlots` takes as its proof: the program's public values, the Groth16 proof of them, and the
    ///         slots' values, one per requested slot, in order.
    struct SlotsProof {
        bytes publicValues;
        bytes proof;
        bytes32[] values;
    }

    /// @notice An update's public values, six words: the claim, the trusted epoch the proof starts from and its set,
    ///         and the new epoch with its set and the time (microseconds) of the ledger info that named it.
    struct UpdateValues {
        bytes32 kind;
        uint64 trustedEpoch;
        bytes32 trustedSet;
        uint64 epoch;
        bytes32 set;
        uint64 time;
    }

    /// @notice A slots claim's public values, nine words: the claim, the chain's registry id the vault's record
    ///         carries, the trusted epoch the proof starts from and its set, the vault's package and id, the version of
    ///         the transaction whose `attest` succeeded, the record's time (microseconds), and
    ///         `keccak256(abi.encode(slots, values))`.
    struct SlotsValues {
        bytes32 kind;
        uint64 chainId;
        uint64 trustedEpoch;
        bytes32 trustedSet;
        bytes32 package;
        bytes32 vaultId;
        uint64 version;
        uint64 timestamp;
        bytes32 slotsHash;
    }

    /// @notice The verifier trusts `set` for `epoch`, named at `time` (microseconds).
    event Trusts(uint256 indexed epoch, bytes32 set, uint256 time);

    error ZeroValue();
    /// @notice The trusted set a proof starts from was named at `time` (microseconds), more than MAX_LAG ago.
    error TooOld(uint256 time);
    /// @notice A time (microseconds) after this block.
    error InTheFuture(uint256 time);
    /// @notice Public values of the wrong length or claim, or an update that does not rise.
    error BadPublicValues();
    /// @notice The vault's record names the chain `chainId`.
    error WrongChain(uint256 chainId);
    /// @notice An update must start from the latest trusted set, not `set` at `epoch`.
    error WrongAnchor(uint64 epoch, bytes32 set);
    /// @notice A proof of slots starts from `epoch`, for which the verifier trusts no such set.
    error UnknownAnchor(uint64 epoch);
    /// @notice The proven event is another package's.
    error WrongPackage(bytes32 package);
    /// @notice The proven record is another vault's.
    error WrongVault(bytes32 vaultId);
    /// @notice The hub asks about an account other than this verifier's vault.
    error WrongAccount(address account);
    /// @notice The proof proves other slots or values than the ones requested and given.
    error NotProven(bytes32 slotsHash);
    error LengthMismatch();

    /// @notice How long after the ledger info that named it a trusted set still starts a proof: 1 day, every
    ///         verifier's limit, twelve of Aptos's two-hour epochs, which one proof may cross. Aptos does not slash,
    ///         so keys retired or leaked later could sign at no cost; a day bounds that. Left a day behind, the
    ///         verifier stops for good, and the chain registry replaces it.
    function MAX_LAG() external view returns (uint256);

    /// @notice `keccak256("xindex.v4.aptos.update")` and `keccak256("xindex.v4.aptos.slots")`: the public values' first
    ///         word.
    function UPDATE() external view returns (bytes32);
    function SLOTS() external view returns (bytes32);

    /// @notice SP1's Groth16 verifier v6.0.0, a bare deployment, never SP1's gateway, which has an owner.
    function SP1_VERIFIER() external view returns (ISP1Verifier);

    /// @notice The program's key: `aptos vkey` of `proofs/aptos`.
    function PROGRAM_KEY() external view returns (bytes32);

    /// @notice The factory's registry id of the chain, the `chainId` the vault writes in its record: `aptos:1`'s,
    ///         549304973309166888, on mainnet.
    function CHAIN_ID() external view returns (uint256);

    /// @notice The address the vault's package is published at, whose `vault::Attested` events the verifier reads.
    function PACKAGE() external view returns (bytes32);

    /// @notice The vault's id: the address of its state object, which its records carry.
    function VAULT_ID() external view returns (bytes32);

    /// @notice The epoch of the latest trusted set, which the next update starts from.
    function latestEpoch() external view returns (uint64);

    /// @notice The set trusted for `epoch`; zero if the verifier trusts none.
    function trusted(uint64 epoch) external view returns (Trusted memory);

    /// @notice Anyone, within MAX_LAG of the latest trusted set's naming. Accepts a Groth16 proof of a later epoch's
    ///         set, named by epoch-ending ledger infos each signed by the set before, from the latest one, which it then
    ///         trusts.
    /// @param publicValues `abi.encode(UpdateValues)`, as the program commits it.
    function update(bytes calldata publicValues, bytes calldata proof) external;
}
