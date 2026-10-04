// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVeChainStateVerifier} from "../interfaces/IVeChainStateVerifier.sol";
import {ISP1Verifier} from "../interfaces/ISP1Verifier.sol";
// Named by the `@inheritdoc` of `verifySlots`, which must name the interface that declares it.
// aderyn-fp-next-line(unused-import)
import {IVaultStateVerifier} from "../interfaces/IVaultStateVerifier.sol";

/// @title VeChainStateVerifier
/// @notice A vault's slots on VeChain, from SP1 proofs of VIP-220 finality over the Staker's weights and of successful
///         `attest` calls in the blocks' transactions and receipts tries (`proofs/vechain`,
///         `design/2026-10-04-four-chains-interfaces.md`).
/// @dev No owner, no upgrade. The first table comes from the deployer, checked during the chain registry's delay as
///      the BNB, TRON, NEAR and CometBFT verifiers' first sets are; every later one is proven.
///
///      The statement proves, in the zkVM, from a table the verifier trusts:
///      - every header's signer, recovered with secp256k1 from its blake2b signing hash, which covers its COM vote,
///        and the chain linked by block ids, all after the trusted table's block;
///      - each table it uses attested in its round by a successful one-clause call of `ATTESTER.attest(table)`, and
///        vouched for by blocks after that call signed by more than two thirds of the trusted table's weight;
///      - for an update, the new table so attested and vouched for;
///      - for slots, the vault's `attest(slots, values)` succeeding, written by the statement as its transaction's one
///        clause with no value, in a block at or before the checkpoint of a round justified under its table, with a
///        later round committed under its own: VIP-220 finality, more than two thirds of the weight each time.
///      This contract checks what the statement takes as given: the chain, the attester, the trusted table and its
///      age, the vault, the times against this block, and the slots and values.
///
///      An update starts from the latest trusted table only, so trusted tables rise in block number. A proof of slots
///      may start from any trusted table up to a day old, so it outlives the updates made while it is in flight. Every
///      trusted table is kept by its block's id: two storage slots each.
contract VeChainStateVerifier is IVeChainStateVerifier {
    /// @inheritdoc IVeChainStateVerifier
    uint256 public constant MAX_LAG = 1 days;
    /// @inheritdoc IVeChainStateVerifier
    uint256 public constant MAX_UPDATE_AGE = 6 hours;
    /// @inheritdoc IVeChainStateVerifier
    bytes32 public constant UPDATE = keccak256("xindex.v4.vechain.update");
    /// @inheritdoc IVeChainStateVerifier
    bytes32 public constant SLOTS = keccak256("xindex.v4.vechain.slots");

    /// @dev The public values: eight words for an update, nine for slots.
    uint256 private constant UPDATE_LENGTH = 8 * 32;
    uint256 private constant SLOTS_LENGTH = 9 * 32;

    /// @inheritdoc IVeChainStateVerifier
    ISP1Verifier public immutable SP1_VERIFIER;
    /// @inheritdoc IVeChainStateVerifier
    bytes32 public immutable PROGRAM_KEY;
    /// @inheritdoc IVeChainStateVerifier
    uint256 public immutable CHAIN_ID;
    /// @inheritdoc IVeChainStateVerifier
    address public immutable VAULT;
    /// @inheritdoc IVeChainStateVerifier
    address public immutable ATTESTER;

    /// @inheritdoc IVeChainStateVerifier
    bytes32 public latestId;

    mapping(bytes32 id => Trusted) private _trusted;

    /// @param sp1Verifier SP1's Groth16 verifier v6.0.0, a bare deployment, never SP1's gateway.
    /// @param programKey The program's key (`vechain vkey`).
    /// @param chainId The chain's registry id: its genesis id as a number.
    /// @param vault The vault whose slots the verifier proves.
    /// @param attester `VeChainStakerAttester` on VeChain.
    /// @param id The block the first table was read at, after the vault and the attester were deployed; `time` its
    ///        time in seconds, `table` the table's hash.
    constructor(
        ISP1Verifier sp1Verifier,
        bytes32 programKey,
        uint256 chainId,
        address vault,
        address attester,
        bytes32 id,
        uint64 time,
        bytes32 table
    ) {
        if (
            address(sp1Verifier) == address(0) || programKey == bytes32(0) || chainId == 0 || vault == address(0)
                || attester == address(0) || _number(id) == 0 || time == 0 || table == bytes32(0)
        ) revert ZeroValue();
        SP1_VERIFIER = sp1Verifier;
        PROGRAM_KEY = programKey;
        CHAIN_ID = chainId;
        VAULT = vault;
        ATTESTER = attester;
        _trust(id, time, table);
    }

    // ---------------------------------------------------------------------
    // Following the chain
    // ---------------------------------------------------------------------

    /// @inheritdoc IVeChainStateVerifier
    function update(bytes calldata publicValues, bytes calldata proof) external {
        bytes32 latest = latestId;
        Trusted memory t = _trusted[latest];
        // A table long superseded may have unbonded, and nothing slashes a validator for signing a fork: such a table
        // must not vouch for the next. A verifier left this far behind stops for good, and the chain registry
        // replaces it.
        if (block.timestamp > uint256(t.time) + MAX_LAG) revert TooOld(t.time);
        // A view of the fixed SP1 verifier, by staticcall: it cannot re-enter.
        // aderyn-fp-next-line(reentrancy-state-change)
        SP1_VERIFIER.verifyProof(PROGRAM_KEY, publicValues, proof);
        if (publicValues.length != UPDATE_LENGTH) revert BadPublicValues();
        UpdateValues memory u = abi.decode(publicValues, (UpdateValues));
        if (u.kind != UPDATE) revert BadPublicValues();
        _checkChain(u.chain, u.attester);
        if (u.trustedId != latest || u.trustedTable != t.table) revert WrongAnchor(u.trustedId);
        // The statement's chain lies after the trusted block; this keeps the latest table the highest whatever a
        // program commits.
        if (_number(u.id) <= t.number) revert BadPublicValues();
        // The block is vouched for by the table before it, which could date it later than now and so stretch its
        // successor's lag beyond a day: never a time still to come.
        if (u.time > block.timestamp) revert InTheFuture(u.time);
        // Nor long past: a block just beyond the latest would void the keepers' proofs in flight while aging the verifier
        // toward MAX_LAG, so every update must bring it near the chain's present (A5-01).
        if (block.timestamp > uint256(u.time) + MAX_UPDATE_AGE) revert StaleHead(u.time);
        _trust(u.id, u.time, u.table);
    }

    function _trust(bytes32 id, uint64 time, bytes32 table) private {
        uint64 number = _number(id);
        _trusted[id] = Trusted({number: number, time: time, table: table});
        latestId = id;
        emit Trusts(number, id, table, time);
    }

    function _checkChain(bytes32 chain, address attester) private view {
        if (uint256(chain) != CHAIN_ID) revert WrongChain(chain);
        if (attester != ATTESTER) revert WrongAttester(attester);
    }

    /// @dev A block id's first four bytes are its number.
    function _number(bytes32 id) private pure returns (uint64) {
        // Deliberate: the cast keeps the id's first four bytes, which are the number.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(bytes4(id)); // aderyn-fp(unsafe-casting)
    }

    /// @inheritdoc IVeChainStateVerifier
    function trusted(bytes32 id) external view returns (Trusted memory) {
        return _trusted[id];
    }

    // ---------------------------------------------------------------------
    // Proving slots
    // ---------------------------------------------------------------------

    /// @inheritdoc IVaultStateVerifier
    /// @dev `proof` is `abi.encode(SlotsProof)`. Returns the number and time of the block whose `attest` succeeded,
    ///      and the values.
    function verifySlots(address account, bytes32[] calldata slots, bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, uint256 timestamp, bytes32[] memory values)
    {
        // The hub names a vault by the low 20 bytes of its id, the vault's address on an EVM chain.
        if (account != VAULT) revert WrongAccount(account);
        SlotsProof memory p = abi.decode(proof, (SlotsProof));
        if (p.values.length != slots.length) revert LengthMismatch();
        SP1_VERIFIER.verifyProof(PROGRAM_KEY, p.publicValues, p.proof);
        if (p.publicValues.length != SLOTS_LENGTH) revert BadPublicValues();
        SlotsValues memory s = abi.decode(p.publicValues, (SlotsValues));
        if (s.kind != SLOTS) revert BadPublicValues();
        _checkChain(s.chain, s.attester);
        Trusted memory t = _trusted[s.trustedId];
        if (t.number == 0 || s.trustedTable != t.table) revert UnknownAnchor(s.trustedId);
        // The blocks are signed by tables trusted from this one on; keys retired or leaked later could sign them at no
        // cost, so the table must be recent, by the same day an update needs. That also bounds the state's age from
        // below, for a reader that takes an old state as evidence.
        if (block.timestamp > uint256(t.time) + MAX_LAG) revert TooOld(t.time);
        if (s.time > block.timestamp) revert InTheFuture(s.time);
        if (s.vault != VAULT) revert WrongVault(s.vault);
        // Equal only if the vault attested exactly these slots, in this order, to exactly these values.
        if (keccak256(abi.encode(slots, p.values)) != s.slotsHash) revert NotProven(s.slotsHash);
        return (s.number, s.time, p.values);
    }
}
