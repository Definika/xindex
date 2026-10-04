// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultStateVerifier} from "./IVaultStateVerifier.sol";
import {ISP1Verifier} from "./ISP1Verifier.sol";

/// @notice A vault's state on VeChain (`design/2026-10-04-four-chains-interfaces.md`), from SP1 proofs of VIP-220
///         finality (`proofs/vechain`). The verifier trusts tables of the validators' weights, each keyed by the block
///         that attests it: the first from its deployer, each later one attested on VeChain by a successful call of
///         `VeChainStakerAttester.attest(table)` and vouched for by blocks after it signed by more than two thirds of
///         a trusted table's weight. A slot is proven by a successful call of the vault's `attest(slots, values)` in a
///         block VIP-220 has finalized under such tables.
interface IVeChainStateVerifier is IVaultStateVerifier {
    /// @notice A table the verifier trusts, kept by the id of the block it was read at: that block's number and time
    ///         (seconds), and the table's hash, `VeChainStakerAttester.currentTable`'s.
    struct Trusted {
        uint64 number;
        uint64 time;
        bytes32 table;
    }

    /// @notice What `verifySlots` takes as its proof: the program's public values, the Groth16 proof of them, and the
    ///         slots' values, one per requested slot, in order.
    struct SlotsProof {
        bytes publicValues;
        bytes proof;
        bytes32[] values;
    }

    /// @notice An update's public values, eight words: the claim, the chain's genesis id, the attester, the trusted
    ///         table the proof starts from and its block, and the new table with its block's id and time.
    struct UpdateValues {
        bytes32 kind;
        bytes32 chain;
        address attester;
        bytes32 trustedId;
        bytes32 trustedTable;
        bytes32 id;
        bytes32 table;
        uint64 time;
    }

    /// @notice A slots claim's public values, nine words: the claim, the chain's genesis id, the attester, the trusted
    ///         table the proof starts from and its block, the vault's block's number and time, the vault, and
    ///         `keccak256(abi.encode(slots, values))`.
    struct SlotsValues {
        bytes32 kind;
        bytes32 chain;
        address attester;
        bytes32 trustedId;
        bytes32 trustedTable;
        uint64 number;
        uint64 time;
        address vault;
        bytes32 slotsHash;
    }

    /// @notice The verifier trusts `table`, read at block `id` number `number`, dated `time` (seconds).
    event Trusts(uint256 indexed number, bytes32 indexed id, bytes32 table, uint256 time);

    error ZeroValue();
    /// @notice The trusted table a proof starts from was read at a block dated `time`, more than MAX_LAG ago.
    error TooOld(uint256 time);
    /// @notice A block dated `time`, after this block.
    error InTheFuture(uint256 time);
    /// @notice Public values of the wrong length or claim, or an update that does not rise.
    error BadPublicValues();
    /// @notice The proof is of the chain whose genesis id is `chain`.
    error WrongChain(bytes32 chain);
    /// @notice The proof counts on the attester `attester`, not this verifier's.
    error WrongAttester(address attester);
    /// @notice An update must start from the latest trusted table, not the one at block `id`.
    error WrongAnchor(bytes32 id);
    /// @notice A proof of slots starts from block `id`, at which the verifier trusts no such table.
    error UnknownAnchor(bytes32 id);
    /// @notice The proven slots are another contract's.
    error WrongVault(address vault);
    /// @notice The hub asks about an account other than this verifier's vault.
    error WrongAccount(address account);
    /// @notice The proof proves other slots or values than the ones requested and given.
    error NotProven(bytes32 slotsHash);
    error LengthMismatch();

    /// @notice How long after its block's time a trusted table still starts a proof: 1 day, every verifier's limit.
    ///         Nothing slashes a VeChain validator, so keys retired or leaked later could sign at no cost; a day bounds
    ///         that. Left a day behind, the verifier stops for good, and the chain registry replaces it.
    function MAX_LAG() external view returns (uint256);

    /// @notice `keccak256("xindex.v4.vechain.update")` and `keccak256("xindex.v4.vechain.slots")`: the public values'
    ///         first word.
    function UPDATE() external view returns (bytes32);
    function SLOTS() external view returns (bytes32);

    /// @notice SP1's Groth16 verifier v6.0.0, a bare deployment, never SP1's gateway, which has an owner.
    function SP1_VERIFIER() external view returns (ISP1Verifier);

    /// @notice The program's key: `vechain vkey` of `proofs/vechain`.
    function PROGRAM_KEY() external view returns (bytes32);

    /// @notice The factory's registry id of the chain: its genesis id as a number, which VeChain's `CHAINID` returns.
    function CHAIN_ID() external view returns (uint256);

    /// @notice The vault, the one contract whose slots the verifier proves.
    function VAULT() external view returns (address);

    /// @notice `VeChainStakerAttester` on VeChain, whose calls attest the weights.
    function ATTESTER() external view returns (address);

    /// @notice The block of the latest trusted table, which the next update starts from.
    function latestId() external view returns (bytes32);

    /// @notice The trusted table read at block `id`; zero if the verifier trusts none there.
    function trusted(bytes32 id) external view returns (Trusted memory);

    /// @notice Anyone, within MAX_LAG of the latest trusted table's time. Accepts a Groth16 proof of a later table,
    ///         attested on VeChain and vouched for by the latest one, which it then trusts.
    /// @param publicValues `abi.encode(UpdateValues)`, as the program commits it.
    function update(bytes calldata publicValues, bytes calldata proof) external;
}
