// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultStateVerifier} from "./IVaultStateVerifier.sol";
import {ISP1Verifier} from "./ISP1Verifier.sol";

/// @notice A vault's state on a CometBFT chain with an EVM, Injective's first (`design/2026-10-04-four-chains-interfaces.md`).
///         The verifier trusts CometBFT headers, the first from its deployer and each later one from an SP1 proof of
///         light-client hops from one it trusts, every hop signed by more than two thirds of a trusted set's power
///         (`proofs/cometbft`). A slot is proven by one SP1 proof of hops from a trusted header to header `H+1`, then of
///         ICS-23 paths under `H+1`'s `app_hash`, which commits the state after block `H`: the vault's key
///         `0x02 ++ vault ++ slot` in the `evm` store's IAVL tree, and that store's root in the multistore.
interface ICometBftStateVerifier is IVaultStateVerifier {
    /// @notice A header the verifier trusts: its height and its time, in seconds. Kept by the header's hash.
    struct Trusted {
        uint64 height;
        uint64 time;
    }

    /// @notice What `verifySlots` takes as its proof: the program's public values, the Groth16 proof of them, and the
    ///         slots' values, one per requested slot, in order.
    struct SlotsProof {
        bytes publicValues;
        bytes proof;
        bytes32[] values;
    }

    /// @notice An update's public values, eight words: the claim, the chain id's keccak, the trusted header the hops
    ///         start from, and the header they reach.
    struct UpdateValues {
        bytes32 kind;
        bytes32 chainIdHash;
        uint64 trustedHeight;
        bytes32 trustedHash;
        uint64 trustedTime;
        uint64 height;
        bytes32 hash;
        uint64 time;
    }

    /// @notice A slots claim's public values, nine words: the claim, the chain id's keccak, the trusted header the hops
    ///         start from, block `H`'s height and time, the vault, and `keccak256(abi.encode(slots, values))`.
    struct SlotsValues {
        bytes32 kind;
        bytes32 chainIdHash;
        uint64 trustedHeight;
        bytes32 trustedHash;
        uint64 trustedTime;
        uint64 height;
        uint64 time;
        address vault;
        bytes32 slotsHash;
    }

    /// @notice The verifier trusts the header `hash` at `height`, dated `time` (seconds).
    event Trusts(uint256 indexed height, bytes32 indexed hash, uint256 time);

    error ZeroValue();
    /// @notice The trusted header a proof starts from is dated `time`, more than MAX_LAG ago.
    error TooOld(uint256 time);
    /// @notice A header dated `time`, after this block.
    error InTheFuture(uint256 time);
    /// @notice Public values of the wrong length or claim, or an update that does not rise.
    error BadPublicValues();
    /// @notice The proof is of a chain whose id's keccak is `chainIdHash`.
    error WrongChain(bytes32 chainIdHash);
    /// @notice An update must start from the latest trusted header, not `hash` at `height`.
    error WrongAnchor(uint256 height, bytes32 hash);
    /// @notice A proof of slots starts from `hash`, which the verifier does not trust at that height and time.
    error UnknownHeader(bytes32 hash);
    /// @notice The proven slots are another contract's.
    error WrongVault(address vault);
    /// @notice The hub asks about an account other than this verifier's vault.
    error WrongAccount(address account);
    /// @notice The proof proves other slots or values than the ones requested and given.
    error NotProven(bytes32 slotsHash);
    error LengthMismatch();

    /// @notice How long after its time a trusted header still starts a proof: 1 day, every verifier's limit, and the
    ///         statement's trusting period. Nothing slashes an Injective validator, so keys retired or leaked later
    ///         could sign a header at no cost; a day bounds that. Left a day behind, the verifier stops for good, and
    ///         the chain registry replaces it.
    function MAX_LAG() external view returns (uint256);

    /// @notice `keccak256("xindex.v4.cometbft.update")` and `keccak256("xindex.v4.cometbft.slots")`: the public values'
    ///         first word.
    function UPDATE() external view returns (bytes32);
    function SLOTS() external view returns (bytes32);

    /// @notice SP1's Groth16 verifier v6.0.0, a bare deployment, never SP1's gateway, which has an owner.
    function SP1_VERIFIER() external view returns (ISP1Verifier);

    /// @notice The program's key: `cometbft vkey` of `proofs/cometbft`.
    function PROGRAM_KEY() external view returns (bytes32);

    /// @notice The factory's registry id of the chain: its EVM chain id, 1776 for Injective.
    function CHAIN_ID() external view returns (uint256);

    /// @notice The CometBFT chain id the headers carry (`injective-1`), and its keccak, which the proofs commit.
    function cosmosChainId() external view returns (string memory);
    function COSMOS_CHAIN_ID_HASH() external view returns (bytes32);

    /// @notice The vault, the one contract whose slots the verifier proves.
    function VAULT() external view returns (address);

    /// @notice The latest header the verifier trusts, which the next update starts from.
    function latestHash() external view returns (bytes32);

    /// @notice The trusted header `hash`; zero if the verifier does not trust it.
    function trusted(bytes32 hash) external view returns (Trusted memory);

    /// @notice Anyone, within MAX_LAG of the latest trusted header's time. Accepts a Groth16 proof of hops from that
    ///         header to a later one, which it then trusts.
    /// @param publicValues `abi.encode(UpdateValues)`, as the program commits it.
    function update(bytes calldata publicValues, bytes calldata proof) external;
}
