// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAptosStateVerifier} from "../interfaces/IAptosStateVerifier.sol";
import {ISP1Verifier} from "../interfaces/ISP1Verifier.sol";
// Named by the `@inheritdoc` of `verifySlots`, which must name the interface that declares it.
// aderyn-fp-next-line(unused-import)
import {IVaultStateVerifier} from "../interfaces/IVaultStateVerifier.sol";

/// @title AptosStateVerifier
/// @notice A vault's slots on Aptos, from SP1 proofs of AptosBFT's signed ledger infos and of the vault's successful
///         `attest` under them (`proofs/aptos`, `design/2026-10-04-four-chains-interfaces.md`).
/// @dev No owner, no upgrade. The first set comes from the deployer, checked during the chain registry's delay as the
///      BNB, TRON, NEAR, CometBFT and VeChain verifiers' first sets are; every later one is proven.
///
///      The statement proves, in the zkVM, from a set the verifier trusts:
///      - each epoch change: the ledger info ending the trusted set's epoch, signed by validators of that set holding
///        more than two thirds of its voting power (BLS12-381 min-pk with the proof-of-possession tag, one aggregate
///        over `sha3_256("APTOS::LedgerInfo") ++ bcs(ledger_info)`), naming the next epoch's set, and so on;
///      - for an update, the last set so named;
///      - for slots, a ledger info of the last epoch reached, signed the same way, and under its transaction
///        accumulator root the info of a transaction at or before its version, written with the status `Success`,
///        whose events' accumulator holds exactly one `<package>::vault::Attested`, written by the statement from the
///        chain id, the vault id, the time and the slots and values.
///      This contract checks what the statement takes as given: the trusted set and its age, the chain, the package
///      and the vault, the times against this block, and the slots and values.
///
///      An update starts from the latest trusted set only, so trusted epochs rise. A proof of slots may start from any
///      set trusted for up to a day, so it outlives the updates made while it is in flight. Every trusted set is kept
///      by its epoch: two storage slots each.
contract AptosStateVerifier is IAptosStateVerifier {
    /// @inheritdoc IAptosStateVerifier
    uint256 public constant MAX_LAG = 1 days;
    /// @inheritdoc IAptosStateVerifier
    bytes32 public constant UPDATE = keccak256("xindex.v4.aptos.update");
    /// @inheritdoc IAptosStateVerifier
    bytes32 public constant SLOTS = keccak256("xindex.v4.aptos.slots");

    /// @dev Aptos's times are in microseconds, the EVM's in seconds.
    uint256 private constant MICROS = 1e6;
    /// @dev The public values: six words for an update, nine for slots.
    uint256 private constant UPDATE_LENGTH = 6 * 32;
    uint256 private constant SLOTS_LENGTH = 9 * 32;

    /// @inheritdoc IAptosStateVerifier
    ISP1Verifier public immutable SP1_VERIFIER;
    /// @inheritdoc IAptosStateVerifier
    bytes32 public immutable PROGRAM_KEY;
    /// @inheritdoc IAptosStateVerifier
    uint256 public immutable CHAIN_ID;
    /// @inheritdoc IAptosStateVerifier
    bytes32 public immutable PACKAGE;
    /// @inheritdoc IAptosStateVerifier
    bytes32 public immutable VAULT_ID;

    /// @inheritdoc IAptosStateVerifier
    uint64 public latestEpoch;

    mapping(uint64 epoch => Trusted) private _trusted;

    /// @param sp1Verifier SP1's Groth16 verifier v6.0.0, a bare deployment, never SP1's gateway.
    /// @param programKey The program's key (`aptos vkey`).
    /// @param chainId The chain's registry id, which the vault writes in its records.
    /// @param package The address the vault's package is published at.
    /// @param vaultId The vault's id, the address of its state object.
    /// @param epoch The epoch in force when the verifier is deployed, `set` the hash of its validators and `time` when
    ///        the ledger info that named them was signed, in microseconds.
    constructor(
        ISP1Verifier sp1Verifier,
        bytes32 programKey,
        uint256 chainId,
        bytes32 package,
        bytes32 vaultId,
        uint64 epoch,
        bytes32 set,
        uint64 time
    ) {
        if (
            address(sp1Verifier) == address(0) || programKey == bytes32(0) || chainId == 0 || package == bytes32(0)
                || vaultId == bytes32(0) || epoch == 0 || set == bytes32(0) || time == 0
        ) revert ZeroValue();
        SP1_VERIFIER = sp1Verifier;
        PROGRAM_KEY = programKey;
        CHAIN_ID = chainId;
        PACKAGE = package;
        VAULT_ID = vaultId;
        _trust(epoch, set, time);
    }

    // ---------------------------------------------------------------------
    // Following the chain
    // ---------------------------------------------------------------------

    /// @inheritdoc IAptosStateVerifier
    function update(bytes calldata publicValues, bytes calldata proof) external {
        uint64 latest = latestEpoch;
        Trusted memory t = _trusted[latest];
        // A set long superseded may have unbonded, and nothing slashes a validator for signing a fork: such a set must
        // not name the next. A verifier left this far behind stops for good, and the chain registry replaces it.
        if (block.timestamp > t.time / MICROS + MAX_LAG) revert TooOld(t.time);
        // A view of the fixed SP1 verifier, by staticcall: it cannot re-enter.
        // aderyn-fp-next-line(reentrancy-state-change)
        SP1_VERIFIER.verifyProof(PROGRAM_KEY, publicValues, proof);
        if (publicValues.length != UPDATE_LENGTH) revert BadPublicValues();
        UpdateValues memory u = abi.decode(publicValues, (UpdateValues));
        if (u.kind != UPDATE) revert BadPublicValues();
        if (u.trustedEpoch != latest || u.trustedSet != t.set) revert WrongAnchor(u.trustedEpoch, u.trustedSet);
        // The statement's hops rise one epoch at a time; this keeps the latest epoch the highest whatever a program
        // commits.
        if (u.epoch <= latest) revert BadPublicValues();
        // The set is named by the one before, which could date its ledger info later than now and so stretch the new
        // set's lag beyond a day: never a time still to come.
        if (u.time / MICROS > block.timestamp) revert InTheFuture(u.time);
        _trust(u.epoch, u.set, u.time);
    }

    function _trust(uint64 epoch, bytes32 set, uint64 time) private {
        _trusted[epoch] = Trusted({set: set, time: time});
        latestEpoch = epoch;
        emit Trusts(epoch, set, time);
    }

    /// @inheritdoc IAptosStateVerifier
    function trusted(uint64 epoch) external view returns (Trusted memory) {
        return _trusted[epoch];
    }

    // ---------------------------------------------------------------------
    // Proving slots
    // ---------------------------------------------------------------------

    /// @inheritdoc IVaultStateVerifier
    /// @dev `proof` is `abi.encode(SlotsProof)`. Returns the version of the transaction whose `attest` succeeded, the
    ///      time the vault wrote in its record, in seconds, and the values.
    function verifySlots(address account, bytes32[] calldata slots, bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, uint256 timestamp, bytes32[] memory values)
    {
        // The hub names a vault by the low 20 bytes of its id.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (account != address(uint160(uint256(VAULT_ID)))) revert WrongAccount(account);
        SlotsProof memory p = abi.decode(proof, (SlotsProof));
        if (p.values.length != slots.length) revert LengthMismatch();
        SP1_VERIFIER.verifyProof(PROGRAM_KEY, p.publicValues, p.proof);
        if (p.publicValues.length != SLOTS_LENGTH) revert BadPublicValues();
        SlotsValues memory s = abi.decode(p.publicValues, (SlotsValues));
        if (s.kind != SLOTS) revert BadPublicValues();
        _checkVault(s);
        Trusted memory t = _trusted[s.trustedEpoch];
        if (t.set == bytes32(0) || s.trustedSet != t.set) revert UnknownAnchor(s.trustedEpoch);
        // The ledger infos are signed by sets trusted from this one on; keys retired or leaked later could sign them at
        // no cost, so the set must be recent, by the same day an update needs. That also bounds the state's age from
        // below, for a reader that takes an old state as evidence.
        if (block.timestamp > t.time / MICROS + MAX_LAG) revert TooOld(t.time);
        if (s.timestamp / MICROS > block.timestamp) revert InTheFuture(s.timestamp);
        // Equal only if the vault attested exactly these slots, in this order, to exactly these values.
        if (keccak256(abi.encode(slots, p.values)) != s.slotsHash) revert NotProven(s.slotsHash);
        return (s.version, s.timestamp / MICROS, p.values);
    }

    /// @dev The record is this verifier's vault's: its chain, the package whose event it is, and the vault's id.
    function _checkVault(SlotsValues memory s) private view {
        if (s.chainId != CHAIN_ID) revert WrongChain(s.chainId);
        if (s.package != PACKAGE) revert WrongPackage(s.package);
        if (s.vaultId != VAULT_ID) revert WrongVault(s.vaultId);
    }
}
