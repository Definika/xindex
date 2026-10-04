// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICometBftStateVerifier} from "../interfaces/ICometBftStateVerifier.sol";
import {ISP1Verifier} from "../interfaces/ISP1Verifier.sol";
// Named by the `@inheritdoc` of `verifySlots`, which must name the interface that declares it.
// aderyn-fp-next-line(unused-import)
import {IVaultStateVerifier} from "../interfaces/IVaultStateVerifier.sol";

/// @title CometBftStateVerifier
/// @notice A vault's slots on a CometBFT chain with an EVM, Injective's first, from SP1 proofs of CometBFT light-client
///         hops and ICS-23 paths (`proofs/cometbft`, `design/2026-10-04-four-chains-interfaces.md`).
/// @dev No owner, no upgrade. The first header comes from the deployer, checked during the chain registry's delay as
///      the BNB, TRON and NEAR verifiers' first sets are; every later one is proven from a header the verifier trusts.
///
///      The statement proves, in the zkVM, with tendermint-rs 0.40.4 and ics23 0.12.0, the crates IBC's SP1 Tendermint
///      client runs: each hop's header is signed by more than two thirds of its own set's power and of the trusted
///      header's next set's, adjacent or skipping, with the chain id, heights, times and sets checked as tendermint-rs
///      checks them, each set trusted for MAX_LAG; and for slots, block `H` is the parent of the last header `H+1`, and
///      each slot is the vault's key `0x02 ++ vault ++ slot` in the `evm` store, present with its value or proven
///      absent, under `H+1`'s `app_hash`. This contract checks what the statement takes as given: the chain id, the
///      header it starts from and its age, the vault, the times against this block, and the slots and values.
///
///      An update starts from the latest trusted header only, so trusted headers rise in height. A proof of slots may
///      start from any trusted header up to a day old, so it outlives the updates made while it is in flight. Every
///      trusted header is kept by its hash: one storage slot each.
contract CometBftStateVerifier is ICometBftStateVerifier {
    /// @inheritdoc ICometBftStateVerifier
    uint256 public constant MAX_LAG = 1 days;
    /// @inheritdoc ICometBftStateVerifier
    bytes32 public constant UPDATE = keccak256("xindex.v4.cometbft.update");
    /// @inheritdoc ICometBftStateVerifier
    bytes32 public constant SLOTS = keccak256("xindex.v4.cometbft.slots");

    /// @dev The public values: eight words for an update, nine for slots.
    uint256 private constant UPDATE_LENGTH = 8 * 32;
    uint256 private constant SLOTS_LENGTH = 9 * 32;

    /// @inheritdoc ICometBftStateVerifier
    ISP1Verifier public immutable SP1_VERIFIER;
    /// @inheritdoc ICometBftStateVerifier
    bytes32 public immutable PROGRAM_KEY;
    /// @inheritdoc ICometBftStateVerifier
    uint256 public immutable CHAIN_ID;
    /// @inheritdoc ICometBftStateVerifier
    bytes32 public immutable COSMOS_CHAIN_ID_HASH;
    /// @inheritdoc ICometBftStateVerifier
    address public immutable VAULT;

    /// @inheritdoc ICometBftStateVerifier
    /// @dev Written once, in the constructor; `string` cannot be immutable.
    // aderyn-fp-next-line(state-variable-could-be-immutable)
    string public cosmosChainId;
    /// @inheritdoc ICometBftStateVerifier
    bytes32 public latestHash;

    mapping(bytes32 hash => Trusted) private _trusted;

    /// @param sp1Verifier SP1's Groth16 verifier v6.0.0, a bare deployment, never SP1's gateway.
    /// @param programKey The program's key (`cometbft vkey`).
    /// @param chainId The chain's registry id, its EVM chain id.
    /// @param chainName The CometBFT chain id its headers carry, `injective-1` on mainnet.
    /// @param vault The vault whose slots the verifier proves.
    /// @param height The height of the header the verifier starts from, `hash` its hash, `time` its time in seconds.
    constructor(
        ISP1Verifier sp1Verifier,
        bytes32 programKey,
        uint256 chainId,
        string memory chainName,
        address vault,
        uint64 height,
        bytes32 hash,
        uint64 time
    ) {
        if (
            address(sp1Verifier) == address(0) || programKey == bytes32(0) || chainId == 0
                || bytes(chainName).length == 0 || vault == address(0) || height == 0 || hash == bytes32(0) || time == 0
        ) revert ZeroValue();
        SP1_VERIFIER = sp1Verifier;
        PROGRAM_KEY = programKey;
        CHAIN_ID = chainId;
        COSMOS_CHAIN_ID_HASH = keccak256(bytes(chainName));
        VAULT = vault;
        cosmosChainId = chainName;
        _trust(height, hash, time);
    }

    // ---------------------------------------------------------------------
    // Following the chain
    // ---------------------------------------------------------------------

    /// @inheritdoc ICometBftStateVerifier
    function update(bytes calldata publicValues, bytes calldata proof) external {
        bytes32 latest = latestHash;
        Trusted memory t = _trusted[latest];
        // A set long superseded may have unbonded, and nothing slashes a validator for signing a fork: such a set must
        // not name the next. A verifier left this far behind stops for good, and the chain registry replaces it.
        if (block.timestamp > uint256(t.time) + MAX_LAG) revert TooOld(t.time);
        // A view of the fixed SP1 verifier, by staticcall: it cannot re-enter.
        // aderyn-fp-next-line(reentrancy-state-change)
        SP1_VERIFIER.verifyProof(PROGRAM_KEY, publicValues, proof);
        if (publicValues.length != UPDATE_LENGTH) revert BadPublicValues();
        UpdateValues memory u = abi.decode(publicValues, (UpdateValues));
        if (u.kind != UPDATE) revert BadPublicValues();
        if (u.chainIdHash != COSMOS_CHAIN_ID_HASH) revert WrongChain(u.chainIdHash);
        if (u.trustedHash != latest || u.trustedHeight != t.height || u.trustedTime != t.time) {
            revert WrongAnchor(u.trustedHeight, u.trustedHash);
        }
        // The statement's hops rise; this keeps the latest header the highest whatever a program commits.
        if (u.height <= t.height) revert BadPublicValues();
        // The header is signed by the set before it, which could date it later than now and so stretch its successor's
        // lag beyond a day: never a time still to come.
        if (u.time > block.timestamp) revert InTheFuture(u.time);
        _trust(u.height, u.hash, u.time);
    }

    function _trust(uint64 height, bytes32 hash, uint64 time) private {
        _trusted[hash] = Trusted({height: height, time: time});
        latestHash = hash;
        emit Trusts(height, hash, time);
    }

    /// @inheritdoc ICometBftStateVerifier
    function trusted(bytes32 hash) external view returns (Trusted memory) {
        return _trusted[hash];
    }

    // ---------------------------------------------------------------------
    // Proving slots
    // ---------------------------------------------------------------------

    /// @inheritdoc IVaultStateVerifier
    /// @dev `proof` is `abi.encode(SlotsProof)`. Returns block `H`'s height and time, and the values.
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
        if (s.chainIdHash != COSMOS_CHAIN_ID_HASH) revert WrongChain(s.chainIdHash);
        Trusted memory t = _trusted[s.trustedHash];
        if (t.height == 0 || s.trustedHeight != t.height || s.trustedTime != t.time) {
            revert UnknownHeader(s.trustedHash);
        }
        // The hops are signed by sets trusted from this header on; keys retired or leaked later could sign them at no
        // cost, so the header must be recent, by the same day an update needs. That also bounds the state's age from
        // below, for a reader that takes an old state as evidence.
        if (block.timestamp > uint256(t.time) + MAX_LAG) revert TooOld(t.time);
        if (s.time > block.timestamp) revert InTheFuture(s.time);
        if (s.vault != VAULT) revert WrongVault(s.vault);
        // Equal only if the statement opened exactly these slots, in this order, to exactly these values.
        if (keccak256(abi.encode(slots, p.values)) != s.slotsHash) revert NotProven(s.slotsHash);
        return (s.height, s.time, p.values);
    }
}
