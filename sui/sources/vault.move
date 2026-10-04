/// Xindex v4 Stage B: the vault on Sui, holding SUI for every index whose shares live on Ethereum. The twin of the EVM
/// vault (`src/vault/XindexVault.sol`) and of the Solana, NEAR and Stellar vaults: coins come in only as deposits to an
/// intake and leave only on messages P1 and P2 prove final on Ethereum, within a speed limit exact over any 24 hours.
/// If Ethereum's formats change unannounced and P1 and P2 stop working, the vault stalls, may adopt a successor pair
/// after a continuity test and 30 days of review, and after 180 days pays each index's holders at its last checkpoint
/// directly (design 6.9). Its state is proven to Ethereum by `attest`, whose `Attestation` object `SuiStateVerifier`
/// reads from a certified checkpoint (`design/2026-10-04-four-chains-interfaces.md`).
///
/// What Sui changes:
/// - The vault is a shared object; its 32-byte id is that object's id. P1 and P2 are `light_client::LightClient` shared
///   objects of this package, named by their object ids, which every call that proves something passes in.
/// - Time is the `Clock` (0x6), in seconds for every rule, and in milliseconds in `attest`'s record.
/// - Amounts are SUI in MIST, `u64`; one from Ethereum that does not fit is refused, but for a cap or floor, which means
///   `u64::MAX` (B1-05). The coins sit in the vault's own `Balance<SUI>`, which only this module can split, so `held`
///   always equals it.
/// - A recipient is a 32-byte Sui address. A payout is a `Coin<SUI>` transferred to it, which never fails.
/// - No owner, no upgrade, no capability: the package is made immutable in its publishing transaction, and every role
///   is an address fixed in the vault's state (README, "Ownerless and immutable").
module xindex_vault::vault;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::hash::keccak256;
use sui::sui::SUI;
use sui::table::{Self, Table};
use xindex_vault::abi::{Self, Message};
use xindex_vault::bytes;
use xindex_vault::light_client::{Self, LightClient};
use xindex_vault::snapshot;
use xindex_vault::state_reader;

// ---------------------------------------------------------------------
// Refusals, by the EVM vault's names where it has them
// ---------------------------------------------------------------------

const EZeroAddress: u64 = 1;
const EZeroAmount: u64 = 2;
const ENotAnIndex: u64 = 3;
const EVaultFrozen: u64 = 4;
const EVaultStalled: u64 = 5;
const EIntakeClosed: u64 = 6;
const EIntakeTooLong: u64 = 7;
const EIntakeNotOpen: u64 = 8;
const ECapExceeded: u64 = 9;
const ENoProof: u64 = 10;
const ENotNative: u64 = 11;
const EWrongRoute: u64 = 12;
const EWrongEmitter: u64 = 13;
const EUnknownKind: u64 = 14;
const EBothProofsRequired: u64 = 15;
const ENotCheckpointed: u64 = 16;
const EIssuedAfterSnapshot: u64 = 17;
const EAlreadyDelivered: u64 = 18;
const ENothingOwed: u64 = 19;
const ENothingPayable: u64 = 20;
const ENothingToRefund: u64 = 21;
const ENotFreezer: u64 = 22;
const EWrongRecipient: u64 = 23;
const EStaleGovernance: u64 = 24;
const ENoPendingChange: u64 = 25;
const EChangeNotReady: u64 = 26;
const ENotNewer: u64 = 27;
const ENotRecent: u64 = 28;
const ENotStalled: u64 = 29;
const ENotRecoveryProposer: u64 = 30;
const ESameRole: u64 = 31;
const ESuccessorPending: u64 = 32;
const ENoSuccessor: u64 = 33;
const EDiscontinuous: u64 = 34;
const EVetoesExhausted: u64 = 35;
const EReviewNotOver: u64 = 36;
const ESnapshotTaken: u64 = 37;
const ENoSnapshot: u64 = 38;
const ESnapshotNotDue: u64 = 39;
const ENoCheckpoint: u64 = 40;
const ENotRecorded: u64 = 41;
const EAlreadyClaimed: u64 = 42;
const ENotAttested: u64 = 43;
/// A light client passed in is not the one the vault names, or a pair is not one SP1 and one RISC Zero client.
const EWrongVerifier: u64 = 44;
const EVerifiersNotDistinct: u64 = 45;
/// `DeployVault`'s refusals: an unknown source chain, a chain id not Sui's for it, a floor above the cap, a role that is
/// the creating key, and light clients whose anchor can no longer be advanced from.
const EUnknownSource: u64 = 46;
const EWrongChain: u64 = 47;
const EFloorAboveCap: u64 = 48;
const ERoleIsCreator: u64 = 49;
const EAnchorTooOld: u64 = 50;
/// A rotation's new light clients must be passed in: `apply_rotation`.
const EVerifiersRequired: u64 = 51;
/// An argument of the wrong length: an index, salt, intake id or slot.
const EBadLength: u64 = 52;
/// A freeze's body is not one word, the end of the factory's freeze (A3-03, B4-04).
const EBadMessage: u64 = 53;
// 54 is Aptos's `ENoVault`: on Sui the vault is an object passed in.
/// A light client anchored in an epoch that has not begun: it would not lag until its first update (B4-02).
const EAnchorNotBegun: u64 = 55;

// ---------------------------------------------------------------------
// The rules, as the EVM vault's
// ---------------------------------------------------------------------

const FREEZE_DURATION: u64 = 14 * 86_400;
const GOVERNANCE_DELAY: u64 = 7 * 86_400;
const MAX_INTAKE_LIFE: u64 = 7 * 86_400;
const STALL_PERIOD: u64 = 7 * 86_400;
const RECOVERY_DELAY: u64 = 30 * 86_400;
const MAX_RECOVERY_VETOES: u8 = 2;
const SNAPSHOT_EXIT_DELAY: u64 = 180 * 86_400;
/// The current hour and the 24 before it: every real 24-hour span lies inside them.
const BUCKETS: u64 = 25;
const HOUR: u64 = 3600;
/// 4% a day, as `SPEED_LIMIT` (0.04e18).
const SPEED_LIMIT_PERCENT: u128 = 4;

/// Message kinds, as `VaultMessages`.
const BURN: u8 = 1;
const INTAKE_SETTLED: u8 = 2;
const INTAKE_FAILED: u8 = 3;
const MIGRATE: u8 = 4;
const CAP_UPDATE: u8 = 5;
const FREEZE: u8 = 6;
const FREEZER_CHANGE: u8 = 7;
const VERIFIER_ROTATION: u8 = 8;

/// Intake states, as `IXindexVault.IntakeState`.
const INTAKE_NONE: u8 = 0;
const INTAKE_OPEN: u8 = 1;
const INTAKE_SETTLED_STATE: u8 = 2;
const INTAKE_FAILED_STATE: u8 = 3;

/// The hub's storage layout the slot map follows (`HybridHubStorage`): `intakeDigest` (15), `indexDigest` (14),
/// `_snapshot.stateRoot` (25).
const INTAKE_DIGEST_SLOT: u64 = 15;
const INDEX_DIGEST_SLOT: u64 = 14;
const SNAPSHOT_ROOT_SLOT: u64 = 25;

/// The chains: Ethereum mainnet and Sepolia, their beacon genesis times, and Sui's registry ids for each,
/// `sui:mainnet` and `sui:testnet` (interfaces doc).
const ETHEREUM: u64 = 1;
const SEPOLIA: u64 = 11_155_111;
const ETHEREUM_GENESIS: u64 = 1_606_824_023;
const SEPOLIA_GENESIS: u64 = 1_655_733_600;
const SUI_MAINNET: u64 = 13_762_264_207_064_992_463;
const SUI_TESTNET: u64 = 10_803_649_406_359_875_205;

// ---------------------------------------------------------------------
// State
// ---------------------------------------------------------------------

/// A final Ethereum block: its number, its timestamp and its state root.
public struct Checkpoint has copy, drop, store {
    block: u64,
    timestamp: u64,
    state_root: vector<u8>,
}

/// A successor pair under review, and when the review ends; `review_ends` zero when none is.
public struct Successor has copy, drop, store {
    p1: ID,
    p2: ID,
    review_ends: u64,
}

/// A governance change waiting: the hash of its body and when it may apply, zero when none waits.
public struct PendingChange has copy, drop, store {
    body_hash: vector<u8>,
    ready_at: u64,
}

/// One hour's payouts, tagged with the hour so a stale slot reads as empty.
public struct Bucket has copy, drop, store {
    hour: u64,
    amount: u64,
}

/// An index registered here: whether SUI is among its tokens (set by its first credit, as the EVM vault's
/// `_indexTokens`), its balance, everything paid out of it, its outflow buckets and its digest.
public struct IndexState has copy, drop, store {
    has_native: bool,
    balance: u64,
    paid_total: u64,
    outflow: vector<Bucket>,
    digest: vector<u8>,
}

/// A mint order's or a rebalance delivery's deposits for one index.
public struct Intake has copy, drop, store {
    state: u8,
    has_native: bool,
    total: u64,
    digest: vector<u8>,
}

/// A burn, a migration or a snapshot claim accepted and not yet paid in full: to an address, or into another index.
public struct Owed has copy, drop, store {
    to_index: bool,
    recipient: address,
    new_index: vector<u8>,
    remaining: u64,
}

public struct IntakeKey has copy, drop, store {
    index: vector<u8>,
    intake_id: vector<u8>,
}

public struct DepositKey has copy, drop, store {
    index: vector<u8>,
    intake_id: vector<u8>,
    depositor: address,
}

public struct OwedKey has copy, drop, store {
    index: vector<u8>,
    id: vector<u8>,
}

/// The vault. Every coin it accounts for is in `held`, which `coins` always equals: settled balances plus the deposits
/// of open and failed intakes not yet refunded.
public struct Vault has key {
    id: UID,
    source_chain_id: u64,
    chain_id: u64,
    factory: vector<u8>,
    hub_implementation: vector<u8>,
    p1: ID,
    p2: ID,
    freezer: address,
    recovery_proposer: address,
    frozen_until: u64,
    cap: u64,
    outflow_floor: u64,
    held: u64,
    coins: Balance<SUI>,
    /// The factory's nonce of the last cap update, freezer change and rotation taken on both proofs (VLT-4).
    cap_nonce: u64,
    freezer_nonce: u64,
    rotation_nonce: u64,
    /// A raised cap or floor, a new freezer and new verifiers each wait GOVERNANCE_DELAY here (VLT-2).
    pending_cap: PendingChange,
    pending_freezer: PendingChange,
    pending_rotation: PendingChange,
    checkpoint: Checkpoint,
    snapshot: Checkpoint,
    successor: Successor,
    /// The last message delivered on both proofs, which a successor must prove again (LG-3).
    last_message: vector<u8>,
    /// The freezer's vetoes in the current stall (LG-2).
    vetoes: u8,
    indexes: Table<vector<u8>, IndexState>,
    intakes: Table<IntakeKey, Intake>,
    deposits: Table<DepositKey, u64>,
    owed: Table<OwedKey, Owed>,
    used: Table<vector<u8>, bool>,
    /// The values `attest` vouches for, by the slot the hub reads them at on an EVM vault.
    slots: Table<vector<u8>, vector<u8>>,
}

/// What `attest` writes: `record = abi.encode(ATTEST_DOMAIN, chainId, vaultId, timestampMs, slots, values)`. No
/// `store`, so it can never be wrapped or transferred, and only `attest` creates one, frozen in the same transaction:
/// `SuiStateVerifier` reads it as `<package>::vault::Attestation`, `has_public_transfer` false, owner immutable.
public struct Attestation has key {
    id: UID,
    record: vector<u8>,
}

/// What a successor pair must prove: the checkpoint the pair in force last accepted, a recent one, and the last message
/// delivered on both proofs, if there was one (its payload empty when not).
public struct Continuity has copy, drop {
    last1: vector<u8>,
    last2: vector<u8>,
    recent: Checkpoint,
    recent1: vector<u8>,
    recent2: vector<u8>,
    message: vector<u8>,
    message_block: u64,
    message1: vector<u8>,
    message2: vector<u8>,
}

// ---------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------

public struct VaultCreated has copy, drop { vault: ID, source_chain_id: u64, chain_id: u64, p1: ID, p2: ID }

public struct IndexRegistered has copy, drop { index: vector<u8>, salt: vector<u8> }

public struct Deposited has copy, drop { index: vector<u8>, intake_id: vector<u8>, depositor: address, amount: u64 }

public struct Refunded has copy, drop { index: vector<u8>, intake_id: vector<u8>, depositor: address, amount: u64 }

public struct MessageDelivered has copy, drop { id: vector<u8>, kind: u8, index: vector<u8> }

public struct BurnAccepted has copy, drop { index: vector<u8>, id: vector<u8>, amount: u64, recipient: address }

public struct MigrationAccepted has copy, drop {
    index: vector<u8>,
    id: vector<u8>,
    amount: u64,
    new_index: vector<u8>,
}

public struct Paid has copy, drop { index: vector<u8>, id: vector<u8>, amount: u64, remaining: u64 }

public struct IntakeSettled has copy, drop { index: vector<u8>, intake_id: vector<u8> }

public struct IntakeFailed has copy, drop { index: vector<u8>, intake_id: vector<u8> }

public struct IntakeResolved has copy, drop { index: vector<u8>, intake_id: vector<u8>, settled: bool }

public struct CapSet has copy, drop { cap: u64, outflow_floor: u64 }

public struct FreezerChanged has copy, drop { freezer: address }

public struct VerifiersRotated has copy, drop { p1: ID, p2: ID }

public struct ChangeQueued has copy, drop { kind: u8, body: vector<u8>, ready_at: u64 }

public struct ChangeApplied has copy, drop { kind: u8 }

public struct ChangeCancelled has copy, drop { kind: u8 }

public struct Frozen has copy, drop { until: u64, by_factory: bool }

public struct CheckpointAdvanced has copy, drop { block: u64, timestamp: u64, state_root: vector<u8> }

public struct SuccessorProposed has copy, drop { p1: ID, p2: ID, review_ends: u64 }

public struct SuccessorVetoed has copy, drop { vetoes: u8 }

public struct SuccessorAdopted has copy, drop { p1: ID, p2: ID }

public struct SuccessorLapsed has copy, drop {}

public struct SnapshotBegun has copy, drop { block: u64, timestamp: u64, state_root: vector<u8> }

public struct SnapshotClaimed has copy, drop {
    index: vector<u8>,
    holder: vector<u8>,
    recipient: address,
    amount: u64,
    id: vector<u8>,
}

// ---------------------------------------------------------------------
// Creation
// ---------------------------------------------------------------------

/// Creates and shares a vault, refusing what `DeployVault` refuses where Move can see it: a source chain other than
/// Ethereum or Sepolia, a chain id not Sui's for it, a missing factory or template, light clients that are not a pair
/// (`check_pair`), roles that are unset, the same or the creating key, and a floor above the cap. That the recovery
/// proposer is the owner's emergency multisig, and the freezer the guardian's key, is the deployment's to check
/// (README). Its first week's grace: a stall is a week without a new checkpoint, counted from creation until the first,
/// before which it takes no deposit (B1-04).
public fun create(
    source_chain_id: u64,
    chain_id: u64,
    factory: vector<u8>,
    hub_implementation: vector<u8>,
    p1: &LightClient,
    p2: &LightClient,
    freezer: address,
    recovery_proposer: address,
    native_cap: u64,
    native_floor: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let genesis = if (source_chain_id == ETHEREUM) {
        assert!(chain_id == SUI_MAINNET, EWrongChain);
        ETHEREUM_GENESIS
    } else {
        assert!(source_chain_id == SEPOLIA, EUnknownSource);
        assert!(chain_id == SUI_TESTNET, EWrongChain);
        SEPOLIA_GENESIS
    };
    assert!(factory.length() == 20 && hub_implementation.length() == 20, EBadLength);
    assert!(!bytes::is_zero(&factory) && !bytes::is_zero(&hub_implementation), EZeroAddress);
    let now = now(clock);
    check_pair(p1, p2, genesis, now);
    assert!(freezer != @0x0 && recovery_proposer != @0x0, EZeroAddress);
    assert!(freezer != recovery_proposer, ESameRole);
    assert!(freezer != ctx.sender() && recovery_proposer != ctx.sender(), ERoleIsCreator);
    assert!(native_floor <= native_cap, EFloorAboveCap);
    let none = PendingChange { body_hash: vector[], ready_at: 0 };
    let vault = Vault {
        id: object::new(ctx),
        source_chain_id,
        chain_id,
        factory,
        hub_implementation,
        p1: object::id(p1),
        p2: object::id(p2),
        freezer,
        recovery_proposer,
        frozen_until: 0,
        cap: native_cap,
        outflow_floor: native_floor,
        held: 0,
        coins: balance::zero(),
        cap_nonce: 0,
        freezer_nonce: 0,
        rotation_nonce: 0,
        pending_cap: none,
        pending_freezer: none,
        pending_rotation: none,
        checkpoint: Checkpoint { block: 0, timestamp: now, state_root: bytes::zero32() },
        snapshot: Checkpoint { block: 0, timestamp: 0, state_root: bytes::zero32() },
        successor: no_successor(),
        last_message: bytes::zero32(),
        vetoes: 0,
        indexes: table::new(ctx),
        intakes: table::new(ctx),
        deposits: table::new(ctx),
        owed: table::new(ctx),
        used: table::new(ctx),
        slots: table::new(ctx),
    };
    let id = object::id(&vault);
    event::emit(VaultCreated { vault: id, source_chain_id, chain_id, p1: vault.p1, p2: vault.p2 });
    event::emit(CapSet { cap: native_cap, outflow_floor: native_floor });
    transfer::share_object(vault);
    id
}

// ---------------------------------------------------------------------
// Indexes and deposits
// ---------------------------------------------------------------------

/// Anyone: records `index` once its address is the factory's CREATE2 clone of the hub template under `salt`. Only a
/// registered index takes deposits or sends messages that run.
public fun register_index(vault: &mut Vault, index: vector<u8>, salt: vector<u8>) {
    assert!(index.length() == 20 && salt.length() == 32, EBadLength);
    assert!(abi::predict_clone(&vault.hub_implementation, &salt, &vault.factory) == index, ENotAnIndex);
    if (vault.indexes.contains(index)) return;
    let outflow = vector::tabulate!(BUCKETS, |_| Bucket { hour: 0, amount: 0 });
    vault.indexes.add(index, IndexState { has_native: false, balance: 0, paid_total: 0, outflow, digest: vector[] });
    event::emit(IndexRegistered { index, salt });
    refresh_index(vault, &index);
}

/// Anyone, from the first checkpoint on, while neither frozen nor stalled: deposits `coin` into intake `intake_id` of
/// `index`. The intake's deadline is its id's top 64 bits: nobody can open another's intake with another deadline, and
/// deposits close at it for all.
public fun deposit(
    vault: &mut Vault,
    index: vector<u8>,
    intake_id: vector<u8>,
    coin: Coin<SUI>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(vault.indexes.contains(index), ENotAnIndex);
    check_not_frozen(vault, clock);
    // A stalled vault may never again see the message that would settle or fail an intake.
    assert!(!stalled(vault, clock), EVaultStalled);
    // Nor may one without a checkpoint, from which no successor and no snapshot could follow either (B1-04).
    assert!(!bytes::is_zero(&vault.checkpoint.state_root), ENoCheckpoint);
    let amount = coin.value();
    assert!(amount != 0, EZeroAmount);
    assert!(intake_id.length() == 32, EBadLength);
    let deadline = abi::deadline_of(&intake_id);
    let now = now(clock);
    assert!(now <= deadline, EIntakeClosed);
    let key = IntakeKey { index, intake_id };
    let state = if (vault.intakes.contains(key)) { vault.intakes[key].state } else { INTAKE_NONE };
    if (state == INTAKE_NONE) {
        assert!((deadline as u128) <= (now as u128) + (MAX_INTAKE_LIFE as u128), EIntakeTooLong);
        vault.intakes.add(key, Intake { state: INTAKE_OPEN, has_native: false, total: 0, digest: vector[] });
    } else {
        assert!(state == INTAKE_OPEN, EIntakeClosed);
    };
    assert!((vault.held as u128) + (amount as u128) <= (vault.cap as u128), ECapExceeded);
    vault.held = vault.held + amount;
    vault.coins.join(coin.into_balance());
    let depositor = ctx.sender();
    let dkey = DepositKey { index, intake_id, depositor };
    if (vault.deposits.contains(dkey)) {
        let mine = &mut vault.deposits[dkey];
        *mine = *mine + amount;
    } else {
        vault.deposits.add(dkey, amount);
    };
    let intake = &mut vault.intakes[key];
    intake.total = intake.total + amount;
    intake.has_native = true;
    event::emit(Deposited { index, intake_id, depositor, amount });
    refresh_intake(vault, &index, &intake_id);
}

/// A depositor of a failed intake, while not frozen: takes its deposit back, as a coin sent to it, as the EVM vault sends
/// it to `msg.sender`.
#[allow(lint(self_transfer))]
public fun refund(vault: &mut Vault, index: vector<u8>, intake_id: vector<u8>, clock: &Clock, ctx: &mut TxContext) {
    let key = IntakeKey { index, intake_id };
    assert!(vault.intakes.contains(key) && vault.intakes[key].state == INTAKE_FAILED_STATE, EIntakeNotOpen);
    check_not_frozen(vault, clock);
    let depositor = ctx.sender();
    let dkey = DepositKey { index, intake_id, depositor };
    let amount = if (vault.deposits.contains(dkey)) { vault.deposits[dkey] } else { 0 };
    assert!(amount != 0, ENothingToRefund);
    *&mut vault.deposits[dkey] = 0;
    vault.held = vault.held - amount;
    let intake = &mut vault.intakes[key];
    intake.total = intake.total - amount;
    event::emit(Refunded { index, intake_id, depositor, amount });
    refresh_intake(vault, &index, &intake_id);
    let coin = coin::from_balance(vault.coins.split(amount), ctx);
    transfer::public_transfer(coin, depositor);
}

// ---------------------------------------------------------------------
// Messages from Ethereum
// ---------------------------------------------------------------------

/// Anyone: runs one `VaultMessage` an index or the factory emitted, its log in Ethereum block `block`, on P1's proof,
/// P2's or both (an empty proof is none). After a snapshot, no block past it; then the canonical encoding, the route, the
/// emitter and the proofs; for a message that moves coins or loosens a rule, both proofs and a checkpoint covering its
/// block (VLT-3); and a used mark, so a message runs at most once, whoever sends it again (LG-1).
public fun deliver(
    vault: &mut Vault,
    p1: &LightClient,
    p2: &LightClient,
    payload: vector<u8>,
    block: u64,
    proof1: vector<u8>,
    proof2: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(p1) == vault.p1 && object::id(p2) == vault.p2, EWrongVerifier);
    // After a snapshot exit, only what Ethereum sent by its checkpoint may run: the holders at it are paid directly.
    assert!(vault.snapshot.block == 0 || block <= vault.snapshot.block, EIssuedAfterSnapshot);
    let id = abi::message_id(&payload);
    let m = abi::decode_message(&payload);
    let kind = m.kind();
    assert!(kind != 0 && kind <= VERIFIER_ROTATION, EUnknownKind);
    check_route(vault, &m);
    let governance = kind >= CAP_UPDATE;
    // Any Ethereum contract can emit a message naming itself; a governance kind is the factory's alone, and an index's
    // kind runs only for a clone of the factory registered here.
    if (governance) {
        assert!(m.index() == vault.factory, EWrongEmitter);
    } else {
        assert!(vault.indexes.contains(m.index()), ENotAnIndex);
    };
    let has1 = !proof1.is_empty();
    let has2 = !proof2.is_empty();
    assert!(has1 || has2, ENoProof);
    let data = abi::log_data(&payload);
    let topic = abi::event_topic();
    if (has1) light_client::verify_event(p1, &proof1, block, &m.index(), &topic, &id, &data);
    if (has2) light_client::verify_event(p2, &proof2, block, &m.index(), &topic, &id, &data);
    let both = has1 && has2;
    let loosening = needs_both(vault, &m);
    if (loosening) {
        assert!(both, EBothProofsRequired);
        // A message that moves coins or loosens a rule runs only from a block the vault's checkpoint covers, so a
        // snapshot at that checkpoint never pays twice what such a message already paid (VLT-3).
        assert!(block <= vault.checkpoint.block, ENotCheckpointed);
    };
    assert!(!vault.used.contains(id), EAlreadyDelivered);
    // A cut taken on one proof moves no mark (VLT-4), so it stays deliverable on both, which moves the mark past an
    // older raise; until then a replay on one proof only applies it again (A3-02). A freeze is used up at once.
    if (both || kind == FREEZE) vault.used.add(id, true);
    // Only a message on both proofs: one broken proof system could forge a one-proof freeze, which no honest successor
    // could prove again (LG-3).
    if (both) vault.last_message = id;
    event::emit(MessageDelivered { id, kind, index: m.index() });
    if (governance) governance_message(vault, &m, loosening, both, clock)
    else index_message(vault, &m, id, clock, ctx);
}

/// Anyone, while not frozen: pays what the speed limit now allows of an owed burn, claim or migration.
public fun release(vault: &mut Vault, index: vector<u8>, id: vector<u8>, clock: &Clock, ctx: &mut TxContext) {
    pay(vault, index, id, true, clock, ctx);
}

/// The freezer only, before any snapshot exit: freezes the vault for FREEZE_DURATION from now. Nothing could replace
/// the freezer after a snapshot, so it must not be able to hold the exit off for good (VLT-5).
public fun freeze_vault(vault: &mut Vault, clock: &Clock, ctx: &TxContext) {
    assert!(ctx.sender() == vault.freezer, ENotFreezer);
    check_no_snapshot(vault);
    freeze_to(vault, now(clock) + FREEZE_DURATION, false);
}

/// Anyone, from its ready time: applies the waiting cap update or freezer change whose body its `ChangeQueued` event
/// announced. A freeze in force holds every change but the freezer's replacement: a freezer that froze again and again
/// must not be able to keep itself in place.
public fun apply_change(vault: &mut Vault, kind: u8, body: vector<u8>, clock: &Clock) {
    assert!(kind != VERIFIER_ROTATION, EVerifiersRequired);
    take_pending(vault, kind, &body, clock);
    apply(vault, kind, &body);
    event::emit(ChangeApplied { kind });
}

/// Anyone, from its ready time: applies a waiting rotation to the light clients its body names, which must be passed
/// in and be a pair as `create` takes one (`check_pair`, B4-03). Held by a freeze, as every change but the freezer's
/// replacement.
public fun apply_rotation(vault: &mut Vault, body: vector<u8>, p1: &LightClient, p2: &LightClient, clock: &Clock) {
    take_pending(vault, VERIFIER_ROTATION, &body, clock);
    let (a, b) = (abi::body_word(&body, 2, 0), abi::body_word(&body, 2, 1));
    assert!(object::id(p1).to_bytes() == a && object::id(p2).to_bytes() == b, EWrongVerifier);
    check_pair(p1, p2, genesis_of(vault), now(clock));
    vault.p1 = object::id(p1);
    vault.p2 = object::id(p2);
    event::emit(VerifiersRotated { p1: vault.p1, p2: vault.p2 });
    event::emit(ChangeApplied { kind: VERIFIER_ROTATION });
}

/// The freezer only: drops a waiting cap raise or rotation. It cannot drop its own replacement.
public fun cancel_change(vault: &mut Vault, kind: u8, ctx: &TxContext) {
    assert!(ctx.sender() == vault.freezer && kind != FREEZER_CHANGE, ENotFreezer);
    let waiting = pending_mut(vault, kind);
    assert!(waiting.ready_at != 0, ENoPendingChange);
    *waiting = PendingChange { body_hash: vector[], ready_at: 0 };
    event::emit(ChangeCancelled { kind });
}

// ---------------------------------------------------------------------
// Checkpoints, stall recovery and the snapshot exit (design 6.9)
// ---------------------------------------------------------------------

/// Anyone, before a snapshot exit: records a final Ethereum block both P1 and P2 prove, newer than the last, which
/// keeps the vault out of a stall. One recent enough to end a stall also lapses any successor under review and starts
/// the freezer's count again; a stale one leaves the stall, its successor and its count (LG-2).
public fun advance_checkpoint(
    vault: &mut Vault,
    p1: &LightClient,
    p2: &LightClient,
    block: u64,
    timestamp: u64,
    state_root: vector<u8>,
    proof1: vector<u8>,
    proof2: vector<u8>,
    clock: &Clock,
) {
    check_no_snapshot(vault);
    assert!(object::id(p1) == vault.p1 && object::id(p2) == vault.p2, EWrongVerifier);
    let c = Checkpoint { block, timestamp, state_root };
    proven_by_both(p1, p2, &c, &proof1, &proof2);
    check_newer(vault, &c, clock);
    vault.checkpoint = c;
    event::emit(CheckpointAdvanced { block, timestamp, state_root: c.state_root });
    if (stalled(vault, clock)) return;
    // A recent one ends the stall: the pair in force works again.
    vault.vetoes = 0;
    lapse_successor(vault);
}

/// What a successor pair must prove, assembled for `propose_successor`: `last1` and `last2` prove the vault's last
/// checkpoint, `recent1` and `recent2` the checkpoint `(recent_block, recent_timestamp, recent_state_root)`, and
/// `message1` and `message2` the log of `message` in `message_block`, the last message delivered on both proofs, if any.
public fun continuity(
    last1: vector<u8>,
    last2: vector<u8>,
    recent_block: u64,
    recent_timestamp: u64,
    recent_state_root: vector<u8>,
    recent1: vector<u8>,
    recent2: vector<u8>,
    message: vector<u8>,
    message_block: u64,
    message1: vector<u8>,
    message2: vector<u8>,
): Continuity {
    Continuity {
        last1,
        last2,
        recent: Checkpoint { block: recent_block, timestamp: recent_timestamp, state_root: recent_state_root },
        recent1,
        recent2,
        message,
        message_block,
        message1,
        message2,
    }
}

/// The recovery proposer only, while stalled, before a snapshot exit, with none under review: proposes the light
/// clients `p1` and `p2`, a pair as `create` takes one (`check_pair`, B4-03), which must prove the last checkpoint, a
/// recent one and the last message delivered on both proofs.
public fun propose_successor(
    vault: &mut Vault,
    p1: &LightClient,
    p2: &LightClient,
    proofs: Continuity,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == vault.recovery_proposer, ENotRecoveryProposer);
    check_no_snapshot(vault);
    assert!(stalled(vault, clock), ENotStalled);
    assert!(vault.successor.review_ends == 0, ESuccessorPending);
    check_pair(p1, p2, genesis_of(vault), now(clock));
    // (a) The last checkpoint the pair in force accepted.
    let last = vault.checkpoint;
    proven_by_both(p1, p2, &last, &proofs.last1, &proofs.last2);
    // (b) A recent one, which the successor's proof shows descends from it.
    proven_by_both(p1, p2, &proofs.recent, &proofs.recent1, &proofs.recent2);
    check_recent(vault, &proofs.recent, clock);
    // (c) The last message the pair in force delivered on both proofs, if there was one.
    if (!bytes::is_zero(&vault.last_message)) {
        let id = abi::message_id(&proofs.message);
        assert!(id == vault.last_message, EDiscontinuous);
        let emitter = abi::decode_message(&proofs.message).index();
        let data = abi::log_data(&proofs.message);
        let topic = abi::event_topic();
        light_client::verify_event(p1, &proofs.message1, proofs.message_block, &emitter, &topic, &id, &data);
        light_client::verify_event(p2, &proofs.message2, proofs.message_block, &emitter, &topic, &id, &data);
    };
    let review_ends = now(clock) + RECOVERY_DELAY;
    vault.successor = Successor { p1: object::id(p1), p2: object::id(p2), review_ends };
    event::emit(SuccessorProposed { p1: object::id(p1), p2: object::id(p2), review_ends });
}

/// The freezer only, at most MAX_RECOVERY_VETOES times a stall: drops the successor under review.
public fun veto_successor(vault: &mut Vault, ctx: &TxContext) {
    assert!(ctx.sender() == vault.freezer, ENotFreezer);
    assert!(vault.successor.review_ends != 0, ENoSuccessor);
    assert!(vault.vetoes < MAX_RECOVERY_VETOES, EVetoesExhausted);
    vault.vetoes = vault.vetoes + 1;
    vault.successor = no_successor();
    event::emit(SuccessorVetoed { vetoes: vault.vetoes });
}

/// Anyone, once the review is over, with a recent checkpoint the successor proves: makes it P1 and P2, which ends the
/// stall and the freezer's count.
public fun adopt_successor(
    vault: &mut Vault,
    p1: &LightClient,
    p2: &LightClient,
    block: u64,
    timestamp: u64,
    state_root: vector<u8>,
    proof1: vector<u8>,
    proof2: vector<u8>,
    clock: &Clock,
) {
    let s = vault.successor;
    // A snapshot clears any successor, and a checkpoint that ends the stall lapses it, so a pending one is still in its
    // stall.
    assert!(s.review_ends != 0, ENoSuccessor);
    assert!(now(clock) >= s.review_ends, EReviewNotOver);
    assert!(object::id(p1) == s.p1 && object::id(p2) == s.p2, EWrongVerifier);
    let c = Checkpoint { block, timestamp, state_root };
    proven_by_both(p1, p2, &c, &proof1, &proof2);
    check_recent(vault, &c, clock);
    vault.successor = no_successor();
    vault.vetoes = 0;
    vault.p1 = s.p1;
    vault.p2 = s.p2;
    vault.checkpoint = c;
    event::emit(SuccessorAdopted { p1: s.p1, p2: s.p2 });
    event::emit(CheckpointAdvanced { block, timestamp, state_root: c.state_root });
}

/// Anyone, SNAPSHOT_EXIT_DELAY after the stall began: takes the last checkpoint as the snapshot for good. From then on
/// no message from a later Ethereum block runs, and holders at it claim directly.
public fun begin_snapshot(vault: &mut Vault, clock: &Clock) {
    check_no_snapshot(vault);
    let due = vault.checkpoint.timestamp + STALL_PERIOD + SNAPSHOT_EXIT_DELAY;
    assert!(now(clock) >= due, ESnapshotNotDue);
    let last = vault.checkpoint;
    // Without a checkpoint there is no state to pay from, and no index could have been minted into here.
    assert!(!bytes::is_zero(&last.state_root), ENoCheckpoint);
    vault.snapshot = last;
    put_slot(vault, bytes::word64(SNAPSHOT_ROOT_SLOT), last.state_root);
    event::emit(SnapshotBegun { block: last.block, timestamp: last.timestamp, state_root: last.state_root });
    lapse_successor(vault);
}

/// Anyone after the snapshot: pays `holder`'s share of SUI in `index` at the snapshot, read from the hub's storage
/// there, to `recipient`: the recovery address it registered in the hub for this chain, if any, which a contract
/// holder must register; otherwise the recipient it signed for with its Ethereum key (EIP-712, the domain's chain id
/// Ethereum's and its salt this vault's id, B1-06). Within the speed limit, as any payout: a snapshot of a forged
/// checkpoint takes no more than a forged burn. Once per holder and index.
public fun claim_snapshot(
    vault: &mut Vault,
    index: vector<u8>,
    holder: vector<u8>,
    component: u64,
    recipient: address,
    signature: vector<u8>,
    proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(vault.indexes.contains(index), ENotAnIndex);
    assert!(holder.length() == 20, EBadLength);
    assert!(recipient != @0x0, EZeroAddress);
    // The vault itself would strand the payout (SOL-9).
    assert!(recipient != vault.id.to_address(), EWrongRecipient);
    let root = snapshot_root(vault);
    let slots = snapshot::claim_slots(&holder, component, vault.chain_id);
    let values = state_reader::read_slots(&root, &index, &slots, &proof);
    let (amount, registered) = snapshot::share(&values, component, vault.chain_id);
    if (registered.is_some()) {
        // A holder that registered a recovery address, such as a contract, is paid there and nowhere else.
        assert!(registered.destroy_some() == sui::address::to_bytes(recipient), EWrongRecipient);
    } else {
        let message = snapshot::claim_message(&vault_id(vault), vault.source_chain_id, &index, &holder, &sui::address::to_bytes(recipient));
        snapshot::check_signature(&message, &signature, &holder);
    };
    let id = snapshot::claim_id(&index, &holder);
    let key = OwedKey { index, id };
    assert!(!vault.owed.contains(key), EAlreadyClaimed);
    vault.owed.add(key, Owed { to_index: false, recipient, new_index: vector[], remaining: amount });
    event::emit(SnapshotClaimed { index, holder, recipient, amount, id });
    pay(vault, index, id, false, clock, ctx);
}

/// Anyone, after the snapshot: settles an intake still open if the hub had sent its settle message by the snapshot,
/// and otherwise fails it, so its depositors take their coins back. The hub marks an intake settled in the transaction
/// that sends its settle message (`_settledIntakes`), so its mark at the snapshot says whether that message was sent by
/// then: nothing sent later will ever run here.
public fun resolve_intake(vault: &mut Vault, index: vector<u8>, intake_id: vector<u8>, proof: vector<u8>) {
    let key = IntakeKey { index, intake_id };
    assert!(vault.intakes.contains(key) && vault.intakes[key].state == INTAKE_OPEN, EIntakeNotOpen);
    let mark = read_hub(vault, &index, snapshot::settled_slot(&intake_id), &proof);
    let settled = !bytes::is_zero(&mark);
    event::emit(IntakeResolved { index, intake_id, settled });
    resolve(vault, index, intake_id, settled);
}

/// Anyone after the snapshot: a burn or migration the index sent before the snapshot and that never arrived runs on the
/// index's own record of it (`_sentMessages`), once, within the speed limit, as a delivered one would. Every other kind
/// in flight at the snapshot resolves without one: an intake's through `resolve_intake`, and governance not at all.
public fun deliver_recorded(
    vault: &mut Vault,
    payload: vector<u8>,
    proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let id = abi::message_id(&payload);
    let m = abi::decode_message(&payload);
    assert!(m.kind() == BURN || m.kind() == MIGRATE, EUnknownKind);
    check_route(vault, &m);
    assert!(vault.indexes.contains(m.index()), ENotAnIndex);
    // The index marks each burn and migration in the transaction that sends it, and only it writes its storage, so its
    // mark at the snapshot shows the index sent this message by then.
    let mark = read_hub(vault, &m.index(), snapshot::sent_slot(&id), &proof);
    assert!(!bytes::is_zero(&mark), ENotRecorded);
    assert!(!vault.used.contains(id), EAlreadyDelivered);
    vault.used.add(id, true);
    event::emit(MessageDelivered { id, kind: m.kind(), index: m.index() });
    index_message(vault, &m, id, clock, ctx);
}

// ---------------------------------------------------------------------
// What Ethereum proves of this vault
// ---------------------------------------------------------------------

/// Anyone: aborts unless every slot holds its value, a slot never written holding zero; then writes, and freezes in
/// the same transaction, an `Attestation` whose `record` is `abi.encode(ATTEST_DOMAIN, chainId, vaultId, timestampMs,
/// slots, values)`, `timestampMs` the `Clock` now. The slots are those the hub reads on an EVM vault: an intake's
/// digest, an index's digest, and the snapshot's state root. A failed transaction writes no object of this type, so a
/// certified checkpoint holding one proves a successful `attest` (interfaces doc).
public fun attest(
    vault: &Vault,
    slots: vector<vector<u8>>,
    values: vector<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(slots.length() == values.length(), ENotAttested);
    let mut i = 0;
    while (i < slots.length()) {
        assert!(slots[i].length() == 32 && values[i].length() == 32, ENotAttested);
        assert!(slot(vault, slots[i]) == values[i], ENotAttested);
        i = i + 1;
    };
    let record = abi::attest_record(vault.chain_id, &vault_id(vault), clock.timestamp_ms(), &slots, &values);
    transfer::freeze_object(Attestation { id: object::new(ctx), record });
}

// ---------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------

fun now(clock: &Clock): u64 {
    clock.timestamp_ms() / 1000
}

fun no_successor(): Successor {
    let zero = object::id_from_address(@0x0);
    Successor { p1: zero, p2: zero, review_ends: 0 }
}

fun lapse_successor(vault: &mut Vault) {
    if (vault.successor.review_ends != 0) {
        vault.successor = no_successor();
        event::emit(SuccessorLapsed {});
    }
}

fun check_not_frozen(vault: &Vault, clock: &Clock) {
    assert!(now(clock) >= vault.frozen_until, EVaultFrozen);
}

fun check_no_snapshot(vault: &Vault) {
    assert!(bytes::is_zero(&vault.snapshot.state_root), ESnapshotTaken);
}

fun snapshot_root(vault: &Vault): vector<u8> {
    let root = vault.snapshot.state_root;
    assert!(!bytes::is_zero(&root), ENoSnapshot);
    root
}

/// A checkpoint after the last, in blocks and in time, not in the future, and with a state to read.
fun check_newer(vault: &Vault, c: &Checkpoint, clock: &Clock) {
    let last = &vault.checkpoint;
    assert!(
        c.block > last.block && c.timestamp > last.timestamp && c.timestamp <= now(clock)
            && c.state_root.length() == 32 && !bytes::is_zero(&c.state_root),
        ENotNewer,
    );
}

/// A newer checkpoint within STALL_PERIOD of now: one that would not leave the vault stalled.
fun check_recent(vault: &Vault, c: &Checkpoint, clock: &Clock) {
    check_newer(vault, c, clock);
    assert!(c.timestamp + STALL_PERIOD >= now(clock), ENotRecent);
}

/// A pair the vault can stand on, checked alike for the first pair, a rotated one and a successor (B4-03): two light
/// clients of two different proof systems, P1 an SP1 one and P2 a RISC Zero one, both of the source chain's beacon
/// genesis, both anchored in an epoch that has begun (B4-02) and can still be advanced from.
fun check_pair(p1: &LightClient, p2: &LightClient, genesis: u64, now: u64) {
    assert!(object::id(p1) != object::id(p2), EVerifiersNotDistinct);
    assert!(light_client::system(p1) != light_client::system(p2), EVerifiersNotDistinct);
    assert!(
        light_client::system(p1) == light_client::sp1() && light_client::system(p2) == light_client::risc_zero(),
        EWrongVerifier,
    );
    assert!(light_client::genesis_time(p1) == genesis && light_client::genesis_time(p2) == genesis, EWrongVerifier);
    assert!(light_client::epoch_start(p1) <= now && light_client::epoch_start(p2) <= now, EAnchorNotBegun);
    assert!(now <= light_client::lag_ends(p1) && now <= light_client::lag_ends(p2), EAnchorTooOld);
}

/// The beacon genesis time of the vault's source chain, which `create` checked is Ethereum or Sepolia.
fun genesis_of(vault: &Vault): u64 {
    if (vault.source_chain_id == ETHEREUM) ETHEREUM_GENESIS else SEPOLIA_GENESIS
}

/// Both light clients of a pair prove checkpoint `c`, as `_agreed` requires: the same block, timestamp and root.
fun proven_by_both(p1: &LightClient, p2: &LightClient, c: &Checkpoint, proof1: &vector<u8>, proof2: &vector<u8>) {
    light_client::verify_checkpoint(p1, proof1, c.block, c.timestamp, &c.state_root);
    light_client::verify_checkpoint(p2, proof2, c.block, c.timestamp, &c.state_root);
}

/// The message is Ethereum's, for this chain and this vault.
fun check_route(vault: &Vault, m: &Message) {
    assert!(
        m.source_chain_id() == vault.source_chain_id && m.dest_chain_id() == vault.chain_id
            && m.vault() == vault_id(vault),
        EWrongRoute,
    );
}

/// Whether a message needs both proofs and a checkpoint covering its block: everything that moves coins or changes
/// governance does. Only a freeze, and a cap update that raises neither the cap nor the floor, may rest on one.
fun needs_both(vault: &Vault, m: &Message): bool {
    let kind = m.kind();
    if (kind == FREEZE) return false;
    if (kind == CAP_UPDATE) {
        let (cap, floor) = read_cap(&m.body());
        return cap > vault.cap || floor > vault.outflow_floor
    };
    true
}

/// A cap update's body: the native coin's id, which must be zero, then its cap and floor. The factory proposes them in
/// 256 bits, knowing no chain's width; past 64 bits, a figure means `u64::MAX` here, never a refused message (B1-05).
fun read_cap(body: &vector<u8>): (u64, u64) {
    check_native(&abi::body_word(body, 3, 0));
    (abi::saturating(&abi::body_word(body, 3, 1)), abi::saturating(&abi::body_word(body, 3, 2)))
}

/// A body word that must be zero: the vault holds SUI only, `address(0)` on Ethereum.
fun check_native(word: &vector<u8>) {
    assert!(bytes::is_zero(word), ENotNative);
}

/// One slot of `index`'s storage in Ethereum's state at the snapshot.
fun read_hub(vault: &Vault, index: &vector<u8>, slot: vector<u8>, proof: &vector<u8>): vector<u8> {
    let root = snapshot_root(vault);
    state_reader::read_slots(&root, index, &vector[slot], proof)[0]
}

fun index_message(vault: &mut Vault, m: &Message, id: vector<u8>, clock: &Clock, ctx: &mut TxContext) {
    let kind = m.kind();
    if (kind == BURN) {
        burn(vault, m, id, clock, ctx);
    } else if (kind == INTAKE_SETTLED || kind == INTAKE_FAILED) {
        let intake_id = abi::body_word(&m.body(), 1, 0);
        let key = IntakeKey { index: m.index(), intake_id };
        let state = if (vault.intakes.contains(key)) { vault.intakes[key].state } else { INTAKE_NONE };
        assert!(state == INTAKE_NONE || state == INTAKE_OPEN, EIntakeNotOpen);
        resolve(vault, m.index(), intake_id, kind == INTAKE_SETTLED);
    } else {
        migrate(vault, m, id, clock, ctx);
    }
}

/// A burn from an index: pays its recipient what the speed limit allows now, and owes the rest.
fun burn(vault: &mut Vault, m: &Message, id: vector<u8>, clock: &Clock, ctx: &mut TxContext) {
    let body = m.body();
    check_native(&abi::body_word(&body, 3, 0));
    let amount = abi::amount(&abi::body_word(&body, 3, 1));
    let word = abi::body_word(&body, 3, 2);
    assert!(amount != 0, EZeroAmount);
    assert!(!bytes::is_zero(&word), EZeroAddress);
    let recipient = sui::address::from_bytes(word);
    // The vault itself would strand the payout (SOL-9).
    assert!(recipient != vault.id.to_address(), EWrongRecipient);
    let index = m.index();
    vault.owed.add(OwedKey { index, id }, Owed { to_index: false, recipient, new_index: vector[], remaining: amount });
    event::emit(BurnAccepted { index, id, amount, recipient });
    pay(vault, index, id, false, clock, ctx);
}

/// A migration from an index: moves coins two index versions share from the old index's balance into the new one's,
/// within the speed limit, as a burn leaves (Stage B spec, section 5.5). The coins never leave the vault.
fun migrate(vault: &mut Vault, m: &Message, id: vector<u8>, clock: &Clock, ctx: &mut TxContext) {
    let body = m.body();
    let index = m.index();
    let new_index = abi::to_address(&abi::body_word(&body, 3, 0));
    assert!(new_index != index && vault.indexes.contains(new_index), ENotAnIndex);
    check_native(&abi::body_word(&body, 3, 1));
    let amount = abi::amount(&abi::body_word(&body, 3, 2));
    assert!(amount != 0, EZeroAmount);
    vault.owed.add(OwedKey { index, id }, Owed { to_index: true, recipient: @0x0, new_index, remaining: amount });
    event::emit(MigrationAccepted { index, id, amount, new_index });
    pay(vault, index, id, false, clock, ctx);
}

/// Settles an intake, whose deposits join the index, or fails it, so its depositors can take them back.
fun resolve(vault: &mut Vault, index: vector<u8>, intake_id: vector<u8>, settle: bool) {
    let key = IntakeKey { index, intake_id };
    if (!vault.intakes.contains(key)) {
        vault.intakes.add(key, Intake { state: INTAKE_NONE, has_native: false, total: 0, digest: vector[] });
    };
    let intake = &mut vault.intakes[key];
    if (settle) {
        intake.state = INTAKE_SETTLED_STATE;
        let (has, total) = (intake.has_native, intake.total);
        if (has) {
            let state = &mut vault.indexes[index];
            state.balance = state.balance + total;
            state.has_native = true;
        };
        event::emit(IntakeSettled { index, intake_id });
        refresh_intake(vault, &index, &intake_id);
        if (has) refresh_index(vault, &index);
    } else {
        intake.state = INTAKE_FAILED_STATE;
        event::emit(IntakeFailed { index, intake_id });
        refresh_intake(vault, &index, &intake_id);
    }
}

/// What `state` may still pay out now: 4% of its balance before the recent outflow, or the floor if larger, less what
/// already left.
fun available_of(state: &IndexState, floor: u64, clock: &Clock): u64 {
    let recent = recent_of(state, clock);
    let limit = ((state.balance as u128) + recent) * SPEED_LIMIT_PERCENT / 100;
    let limit = if (limit < (floor as u128)) { floor as u128 } else { limit };
    if (limit > recent) { ((limit - recent) as u64) } else { 0 }
}

/// What the buckets hold of the current hour and the 24 before it: a stale slot reads empty.
fun recent_of(state: &IndexState, clock: &Clock): u128 {
    let hour = now(clock) / HOUR;
    let mut total: u128 = 0;
    state.outflow.do_ref!(|b| if (b.hour + BUCKETS > hour) total = total + (b.amount as u128));
    total
}

/// Pays what the speed limit, the index's balance and a freeze allow of owed `(index, id)`. `strict` is set for an
/// explicit release, which aborts when it can pay nothing; a message just accepted keeps waiting instead. A migration
/// is paid into the new index's balance, so the coins stay in the vault and `held` stays; anything else is a coin
/// transferred to its recipient.
fun pay(vault: &mut Vault, index: vector<u8>, id: vector<u8>, strict: bool, clock: &Clock, ctx: &mut TxContext) {
    let key = OwedKey { index, id };
    assert!(vault.owed.contains(key), ENothingOwed);
    let owed = vault.owed[key];
    assert!(owed.remaining != 0, ENothingOwed);
    assert!(vault.indexes.contains(index), ENotAnIndex);
    let pay = if (now(clock) < vault.frozen_until) {
        0
    } else {
        let state = &vault.indexes[index];
        min(min(owed.remaining, available_of(state, vault.outflow_floor, clock)), state.balance)
    };
    if (pay == 0) {
        assert!(!strict, ENothingPayable);
        return
    };
    let remaining = owed.remaining - pay;
    let o = &mut vault.owed[key];
    o.remaining = remaining;
    let hour = now(clock) / HOUR;
    let state = &mut vault.indexes[index];
    state.balance = state.balance - pay;
    state.paid_total = state.paid_total + pay;
    let bucket = &mut state.outflow[hour % BUCKETS];
    if (bucket.hour == hour) {
        bucket.amount = bucket.amount + pay;
    } else {
        *bucket = Bucket { hour, amount: pay };
    };
    refresh_index(vault, &index);
    event::emit(Paid { index, id, amount: pay, remaining });
    if (owed.to_index) {
        let new = &mut vault.indexes[owed.new_index];
        new.balance = new.balance + pay;
        new.has_native = true;
        refresh_index(vault, &owed.new_index);
    } else {
        vault.held = vault.held - pay;
        let coin = coin::from_balance(vault.coins.split(pay), ctx);
        transfer::public_transfer(coin, owed.recipient);
    }
}

/// A freeze, a cap update raising neither figure, a raise, a new freezer or new verifiers from the factory. The
/// factory's nonce only rises: an older message of a kind, delivered late, cannot undo a newer one. Only one on both
/// proofs moves the mark, so a single broken proof system cannot lock the factory out with a forged nonce (VLT-4). A
/// loosening change waits GOVERNANCE_DELAY here, where the freezer can see it and stop a raise or a rotation, however
/// its proofs were obtained (VLT-2).
fun governance_message(vault: &mut Vault, m: &Message, loosening: bool, both: bool, clock: &Clock) {
    let kind = m.kind();
    let body = m.body();
    if (kind == FREEZE) {
        // One word: when the factory's freeze ends, in Unix seconds (A3-03, B4-04).
        assert!(body.length() == 32, EBadMessage);
        // Nothing could replace the freezer after a snapshot, and nothing may hold the exit off (VLT-5).
        check_no_snapshot(vault);
        // A freeze already over on Ethereum freezes nothing, however late it is delivered; one still running freezes to
        // its end, and never past FREEZE_DURATION from now.
        let (until, now) = (abi::saturating(&body), now(clock));
        if (until > now) freeze_to(vault, min(until, now + FREEZE_DURATION), true);
        return
    };
    let last = if (kind == CAP_UPDATE) {
        vault.cap_nonce
    } else if (kind == FREEZER_CHANGE) {
        vault.freezer_nonce
    } else {
        vault.rotation_nonce
    };
    assert!(m.nonce() > last, EStaleGovernance);
    if (both) {
        if (kind == CAP_UPDATE) vault.cap_nonce = m.nonce()
        else if (kind == FREEZER_CHANGE) vault.freezer_nonce = m.nonce()
        else vault.rotation_nonce = m.nonce();
    };
    // The body's form, checked before it waits.
    if (kind == CAP_UPDATE) {
        let (_, _) = read_cap(&body);
    } else if (kind == FREEZER_CHANGE) {
        let _ = abi::body_word(&body, 1, 0);
    } else {
        let _ = abi::body_word(&body, 2, 0);
    };
    if (loosening) {
        let ready_at = now(clock) + GOVERNANCE_DELAY;
        *pending_mut(vault, kind) = PendingChange { body_hash: keccak256(&body), ready_at };
        event::emit(ChangeQueued { kind, body, ready_at });
    } else {
        // Newer than a waiting raise, which it replaces.
        *pending_mut(vault, kind) = PendingChange { body_hash: vector[], ready_at: 0 };
        apply(vault, kind, &body);
    }
}

/// The waiting change of `kind`, which must be `body` and ready, and not held by a freeze unless it replaces the
/// freezer; taken, so it applies once.
fun take_pending(vault: &mut Vault, kind: u8, body: &vector<u8>, clock: &Clock) {
    let now = now(clock);
    let frozen = now < vault.frozen_until;
    let waiting = pending_mut(vault, kind);
    assert!(waiting.ready_at != 0 && waiting.body_hash == keccak256(body), ENoPendingChange);
    assert!(now >= waiting.ready_at, EChangeNotReady);
    assert!(kind == FREEZER_CHANGE || !frozen, EVaultFrozen);
    *waiting = PendingChange { body_hash: vector[], ready_at: 0 };
}

fun apply(vault: &mut Vault, kind: u8, body: &vector<u8>) {
    if (kind == CAP_UPDATE) {
        let (cap, floor) = read_cap(body);
        vault.cap = cap;
        vault.outflow_floor = floor;
        event::emit(CapSet { cap, outflow_floor: floor });
    } else {
        let word = abi::body_word(body, 1, 0);
        assert!(!bytes::is_zero(&word), EZeroAddress);
        let freezer = sui::address::from_bytes(word);
        vault.freezer = freezer;
        event::emit(FreezerChanged { freezer });
    }
}

fun pending_mut(vault: &mut Vault, kind: u8): &mut PendingChange {
    if (kind == CAP_UPDATE) return &mut vault.pending_cap;
    if (kind == FREEZER_CHANGE) return &mut vault.pending_freezer;
    assert!(kind == VERIFIER_ROTATION, ENoPendingChange);
    &mut vault.pending_rotation
}

/// Freezes the vault until `until`; a later freeze extends it, and none shortens it.
fun freeze_to(vault: &mut Vault, until: u64, by_factory: bool) {
    if (until > vault.frozen_until) vault.frozen_until = until;
    event::emit(Frozen { until: vault.frozen_until, by_factory });
}

fun refresh_index(vault: &mut Vault, index: &vector<u8>) {
    let vid = vault_id(vault);
    let state = &mut vault.indexes[*index];
    state.digest = abi::index_digest(vault.chain_id, &vid, index, state.has_native, state.balance, state.paid_total);
    let digest = state.digest;
    put_slot(vault, index_slot(index), digest);
}

fun refresh_intake(vault: &mut Vault, index: &vector<u8>, intake_id: &vector<u8>) {
    let vid = vault_id(vault);
    let intake = &mut vault.intakes[IntakeKey { index: *index, intake_id: *intake_id }];
    intake.digest =
        abi::intake_digest(vault.chain_id, &vid, index, intake_id, intake.state, intake.has_native, intake.total);
    let digest = intake.digest;
    put_slot(vault, intake_slot(index, intake_id), digest);
}

fun put_slot(vault: &mut Vault, slot: vector<u8>, value: vector<u8>) {
    if (vault.slots.contains(slot)) {
        *&mut vault.slots[slot] = value;
    } else {
        vault.slots.add(slot, value);
    }
}

fun min(a: u64, b: u64): u64 {
    if (a < b) a else b
}



/// Where the hub reads an index's digest on an EVM vault: `keccak256(abi.encode(index, 14))`.
public fun index_slot(index: &vector<u8>): vector<u8> {
    snapshot::mapping_slot(&bytes::address_word(index), &bytes::word64(INDEX_DIGEST_SLOT))
}

/// Where the hub reads an intake's digest: `keccak256(abi.encode(intakeId, keccak256(abi.encode(index, 15))))`.
public fun intake_slot(index: &vector<u8>, intake_id: &vector<u8>): vector<u8> {
    let inner = snapshot::mapping_slot(&bytes::address_word(index), &bytes::word64(INTAKE_DIGEST_SLOT));
    snapshot::mapping_slot(intake_id, &inner)
}

// ---------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------

/// The vault's id in messages, digests and records: its shared object's id (interfaces doc).
public fun vault_id(vault: &Vault): vector<u8> { vault.id.to_bytes() }

public fun source_chain_id(vault: &Vault): u64 { vault.source_chain_id }

public fun chain_id(vault: &Vault): u64 { vault.chain_id }

public fun factory(vault: &Vault): vector<u8> { vault.factory }

public fun hub_implementation(vault: &Vault): vector<u8> { vault.hub_implementation }

public fun p1(vault: &Vault): ID { vault.p1 }

public fun p2(vault: &Vault): ID { vault.p2 }

public fun freezer(vault: &Vault): address { vault.freezer }

public fun recovery_proposer(vault: &Vault): address { vault.recovery_proposer }

public fun frozen_until(vault: &Vault): u64 { vault.frozen_until }

public fun cap(vault: &Vault): u64 { vault.cap }

public fun outflow_floor(vault: &Vault): u64 { vault.outflow_floor }

public fun held(vault: &Vault): u64 { vault.held }

/// The coins the vault holds: always `held`.
public fun coins(vault: &Vault): u64 { vault.coins.value() }

/// The nonce marks of cap updates, freezer changes and rotations.
public fun nonces(vault: &Vault): vector<u64> { vector[vault.cap_nonce, vault.freezer_nonce, vault.rotation_nonce] }

/// The waiting change of `kind`: its body's hash and ready time, zero when none waits.
public fun pending(vault: &Vault, kind: u8): (vector<u8>, u64) {
    let p = if (kind == CAP_UPDATE) {
        vault.pending_cap
    } else if (kind == FREEZER_CHANGE) {
        vault.pending_freezer
    } else {
        vault.pending_rotation
    };
    (p.body_hash, p.ready_at)
}

public fun checkpoint(vault: &Vault): (u64, u64, vector<u8>) {
    (vault.checkpoint.block, vault.checkpoint.timestamp, vault.checkpoint.state_root)
}

public fun exit_snapshot(vault: &Vault): (u64, u64, vector<u8>) {
    (vault.snapshot.block, vault.snapshot.timestamp, vault.snapshot.state_root)
}

public fun successor(vault: &Vault): (ID, ID, u64) {
    (vault.successor.p1, vault.successor.p2, vault.successor.review_ends)
}

public fun last_message(vault: &Vault): vector<u8> { vault.last_message }

public fun vetoes(vault: &Vault): u8 { vault.vetoes }

public fun is_index(vault: &Vault, index: vector<u8>): bool { vault.indexes.contains(index) }

/// An index's books: whether it holds SUI, its balance, its paid total, its digest, and what it may pay out now.
public fun index_state(vault: &Vault, index: vector<u8>, clock: &Clock): (bool, u64, u64, vector<u8>, u64) {
    let s = &vault.indexes[index];
    (s.has_native, s.balance, s.paid_total, s.digest, available_of(s, vault.outflow_floor, clock))
}

/// An intake's state, total and digest; state 0 for one never opened.
public fun intake(vault: &Vault, index: vector<u8>, intake_id: vector<u8>): (u8, u64, vector<u8>) {
    let key = IntakeKey { index, intake_id };
    if (!vault.intakes.contains(key)) return (INTAKE_NONE, 0, vector[]);
    let i = &vault.intakes[key];
    (i.state, i.total, i.digest)
}

public fun deposited(vault: &Vault, index: vector<u8>, intake_id: vector<u8>, depositor: address): u64 {
    let key = DepositKey { index, intake_id, depositor };
    if (vault.deposits.contains(key)) vault.deposits[key] else 0
}

/// An owed payout: whether it goes into an index, its recipient or new index, and what remains; none owed reads zero.
public fun owed(vault: &Vault, index: vector<u8>, id: vector<u8>): (bool, address, vector<u8>, u64) {
    let key = OwedKey { index, id };
    if (!vault.owed.contains(key)) return (false, @0x0, vector[], 0);
    let o = &vault.owed[key];
    (o.to_index, o.recipient, o.new_index, o.remaining)
}

public fun used(vault: &Vault, id: vector<u8>): bool { vault.used.contains(id) }

/// The value `attest` vouches for at `slot`: zero for one never written.
public fun slot(vault: &Vault, slot: vector<u8>): vector<u8> {
    if (vault.slots.contains(slot)) vault.slots[slot] else bytes::zero32()
}

/// A week without a new checkpoint: P1 and P2 may have stopped working.
public fun stalled(vault: &Vault, clock: &Clock): bool {
    now(clock) > stall_start(vault)
}

public fun stall_start(vault: &Vault): u64 {
    vault.checkpoint.timestamp + STALL_PERIOD
}

/// An attestation's record.
public fun record(a: &Attestation): vector<u8> { a.record }

/// Lands checkpoint `(block, timestamp, state_root)` as a proven one would: for gas tests whose call needs a first
/// checkpoint (B1-04) and whose measure must not carry the cost of proving it.
#[test_only]
public fun checkpoint_for_testing(vault: &mut Vault, block: u64, timestamp: u64, state_root: vector<u8>) {
    vault.checkpoint = Checkpoint { block, timestamp, state_root };
}

/// Credits `coin` to `index` as a settled intake would: for gas tests that need a funded index without a delivery.
#[test_only]
public fun credit_for_testing(vault: &mut Vault, index: vector<u8>, coin: Coin<SUI>) {
    let amount = coin.value();
    vault.held = vault.held + amount;
    vault.coins.join(coin.into_balance());
    let state = &mut vault.indexes[index];
    state.balance = state.balance + amount;
    state.has_native = true;
    refresh_index(vault, &index);
}
