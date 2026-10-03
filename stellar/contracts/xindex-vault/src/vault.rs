//! What every entry point shares: storage and its TTLs, the vault's identity, the slot map `attest` reads, the pinned
//! verifiers, the checkpoint rules, the speed limit and payouts. The rules themselves are every chain's
//! (`xindex_core`); this keeps them in Soroban storage and moves XLM through the native asset's contract.

use soroban_sdk::address_payload::AddressPayload;
use soroban_sdk::token::TokenClient;
use soroban_sdk::{
    contractclient, panic_with_error, Address, Bytes, BytesN, Env, Executable, IntoVal, TryFromVal,
    Val, Vec,
};
use xindex_core::abi;
use xindex_core::constants::*;
use xindex_core::{checkpoint, speed, Crypto};
use xindex_soroban::Soroban;

use crate::error::VaultError;
use crate::events::Paid;
use crate::types::*;

/// The verifier interface, as P1's and P2's contracts answer it: each call fails unless the proof shows the claim.
#[contractclient(name = "VerifierClient")]
#[allow(dead_code)]
pub trait EventVerifier {
    fn verify_event(
        env: Env,
        block: u64,
        emitter: BytesN<20>,
        topic0: BytesN<32>,
        topic1: BytesN<32>,
        data_hash: BytesN<32>,
        proof: Bytes,
    );
    fn verify_checkpoint(
        env: Env,
        block: u64,
        timestamp: u64,
        state_root: BytesN<32>,
        proof: Bytes,
    );
}

pub fn fail(env: &Env, e: VaultError) -> ! {
    panic_with_error!(env, e)
}

pub fn require(env: &Env, ok: bool, e: VaultError) {
    if !ok {
        fail(env, e)
    }
}

pub fn now(env: &Env) -> u64 {
    env.ledger().timestamp()
}

pub fn zero32(env: &Env) -> BytesN<32> {
    BytesN::from_array(env, &[0u8; 32])
}

// ---------------------------------------------------------------------
// storage
// ---------------------------------------------------------------------

pub fn config(env: &Env) -> Config {
    env.storage().instance().get(&DataKey::Config).unwrap()
}

pub fn set_config(env: &Env, c: &Config) {
    env.storage().instance().set(&DataKey::Config, c);
    let max = env.storage().max_ttl();
    env.storage().instance().extend_ttl(max / 2, max);
}

/// The successor pair under review, if any.
pub fn successor(env: &Env) -> Option<Successor> {
    env.storage().instance().get(&DataKey::Successor)
}

/// Drops the successor under review; true if there was one.
pub fn drop_successor(env: &Env) -> bool {
    let had = env.storage().instance().has(&DataKey::Successor);
    env.storage().instance().remove(&DataKey::Successor);
    had
}

pub fn get<V: TryFromVal<Env, Val>>(env: &Env, key: &DataKey) -> Option<V> {
    env.storage().persistent().get(key)
}

/// Writes a persistent entry and extends it to the network's maximum TTL.
pub fn put<V: IntoVal<Env, Val>>(env: &Env, key: &DataKey, value: &V) {
    env.storage().persistent().set(key, value);
    let max = env.storage().max_ttl();
    env.storage().persistent().extend_ttl(key, max / 2, max);
}

pub fn index_state(env: &Env, index: &BytesN<20>) -> IndexState {
    get(env, &DataKey::Index(index.clone())).unwrap_or_else(|| fail(env, VaultError::NotAnIndex))
}

pub fn put_index(env: &Env, index: &BytesN<20>, s: &IndexState) {
    put(env, &DataKey::Index(index.clone()), s);
}

pub fn is_index(env: &Env, index: &BytesN<20>) -> bool {
    env.storage()
        .persistent()
        .has(&DataKey::Index(index.clone()))
}

// ---------------------------------------------------------------------
// identity and the slot map
// ---------------------------------------------------------------------

/// The vault's id on Ethereum: its contract id, the 32 bytes a `C…` address encodes, as the factory registers it.
pub fn vault_id(env: &Env) -> [u8; 32] {
    match env.current_contract_address().to_payload() {
        Some(AddressPayload::ContractIdHash(h)) => h.to_array(),
        _ => fail(env, VaultError::WrongRoute),
    }
}

/// A Stellar account by its ed25519 key: a burn's or a claim's recipient, and the freezer.
pub fn account(env: &Env, key: &BytesN<32>) -> Address {
    Address::from_payload(env, AddressPayload::AccountIdPublicKeyEd25519(key.clone()))
}

/// A contract by its id: a verifier a rotation names.
pub fn contract(env: &Env, id: &BytesN<32>) -> Address {
    Address::from_payload(env, AddressPayload::ContractIdHash(id.clone()))
}

/// The key the hub reads an index's digest at: `keccak256(abi.encode(index, 14))`.
pub fn index_slot(env: &Env, index: &[u8; 20]) -> [u8; 32] {
    Soroban(env).keccak256(&[&abi::address_word(index), &abi::u256(14)])
}

/// The key the hub reads an intake's digest at: `keccak256(abi.encode(intakeId, keccak256(abi.encode(index, 15))))`.
pub fn intake_slot(env: &Env, index: &[u8; 20], intake_id: &[u8; 32]) -> [u8; 32] {
    let c = Soroban(env);
    let inner = c.keccak256(&[&abi::address_word(index), &abi::u256(15)]);
    c.keccak256(&[intake_id, &inner])
}

/// The key the hub reads the snapshot's state root at: `bytes32(25)`.
pub fn snapshot_slot() -> [u8; 32] {
    abi::u256(25)
}

pub fn set_slot(env: &Env, key: &[u8; 32], value: &[u8; 32]) {
    put(
        env,
        &DataKey::Slot(BytesN::from_array(env, key)),
        &BytesN::from_array(env, value),
    );
}

pub fn slot(env: &Env, key: &BytesN<32>) -> BytesN<32> {
    get(env, &DataKey::Slot(key.clone())).unwrap_or_else(|| zero32(env))
}

pub fn refresh_index(env: &Env, cfg: &Config, index: &BytesN<20>, s: &IndexState) {
    let index = index.to_array();
    let digest = abi::index_digest(
        &Soroban(env),
        cfg.chain_id,
        &vault_id(env),
        &index,
        s.has_native,
        s.balance,
        s.paid_total,
    );
    set_slot(env, &index_slot(env, &index), &digest);
}

pub fn refresh_intake(
    env: &Env,
    cfg: &Config,
    index: &BytesN<20>,
    intake_id: &BytesN<32>,
    i: &Intake,
) {
    let (index, intake_id) = (index.to_array(), intake_id.to_array());
    let digest = abi::intake_digest(
        &Soroban(env),
        cfg.chain_id,
        &vault_id(env),
        &index,
        &intake_id,
        i.state as u8,
        i.has_native,
        i.total,
    );
    set_slot(env, &intake_slot(env, &index, &intake_id), &digest);
}

// ---------------------------------------------------------------------
// verifiers
// ---------------------------------------------------------------------

/// A verifier contract, its current code pinned: it must be a Wasm contract.
pub fn pin(env: &Env, address: Address) -> Verifier {
    match address.executable() {
        Some(Executable::Wasm(code)) => Verifier { address, code },
        _ => fail(env, VaultError::NotAContract),
    }
}

/// Two different verifier contracts, pinned.
pub fn pin_pair(env: &Env, a: Address, b: Address) -> (Verifier, Verifier) {
    require(env, a != b, VaultError::VerifiersNotDistinct);
    (pin(env, a), pin(env, b))
}

/// The verifier, still running the code the vault pinned.
fn client<'a>(env: &'a Env, v: &Verifier) -> VerifierClient<'a> {
    require(
        env,
        v.address.executable() == Some(Executable::Wasm(v.code.clone())),
        VaultError::VerifierChanged,
    );
    VerifierClient::new(env, &v.address)
}

/// The log a message arrives in, as the relayer claims it; the verifiers attest it.
pub struct Log {
    pub block: u64,
    pub emitter: [u8; 20],
    pub id: [u8; 32],
    pub data_hash: [u8; 32],
}

impl Log {
    /// The log of `payload`, a message from `emitter`, in `block`.
    pub fn of(env: &Env, payload: &[u8], emitter: [u8; 20], block: u64) -> Self {
        let c = Soroban(env);
        Log {
            block,
            emitter,
            id: abi::message_id(&c, payload),
            data_hash: abi::log_data_hash(&c, payload),
        }
    }
}

pub fn verify_event(env: &Env, v: &Verifier, log: &Log, proof: &Bytes) {
    client(env, v).verify_event(
        &log.block,
        &BytesN::from_array(env, &log.emitter),
        &BytesN::from_array(env, &EVENT_TOPIC),
        &BytesN::from_array(env, &log.id),
        &BytesN::from_array(env, &log.data_hash),
        proof,
    );
}

pub fn verify_checkpoint(env: &Env, v: &Verifier, c: &Checkpoint, proof: &Bytes) {
    client(env, v).verify_checkpoint(&c.block, &c.timestamp, &c.state_root, proof);
}

/// Both verifiers of a pair prove checkpoint `c`, as `_agreed` requires: the same block, timestamp and state root.
pub fn checkpoint_by_both(
    env: &Env,
    pair: (&Verifier, &Verifier),
    c: &Checkpoint,
    p1: &Bytes,
    p2: &Bytes,
) {
    verify_checkpoint(env, pair.0, c, p1);
    verify_checkpoint(env, pair.1, c, p2);
}

// ---------------------------------------------------------------------
// checkpoints
// ---------------------------------------------------------------------

fn core_checkpoint(c: &Checkpoint) -> checkpoint::Checkpoint {
    checkpoint::Checkpoint {
        block: c.block,
        timestamp: c.timestamp,
        state_root: c.state_root.to_array(),
    }
}

/// When the vault stalls: STALL_PERIOD after its last checkpoint's time, or after deployment until the first.
pub fn stall_start(cfg: &Config) -> u64 {
    checkpoint::stall_start(cfg.checkpoint.timestamp) as u64
}

/// A week without a new checkpoint: P1 and P2 may have stopped working.
pub fn stalled(env: &Env, cfg: &Config) -> bool {
    checkpoint::stalled(cfg.checkpoint.timestamp, now(env) as i64)
}

/// A checkpoint after the last, in blocks and in time, not in the future, and with a state to read.
pub fn check_newer(env: &Env, cfg: &Config, c: &Checkpoint) {
    require(
        env,
        checkpoint::is_newer(
            &core_checkpoint(&cfg.checkpoint),
            &core_checkpoint(c),
            now(env) as i64,
        ),
        VaultError::NotNewer,
    );
}

/// A newer checkpoint within STALL_PERIOD of now: one that would not leave the vault stalled.
pub fn check_recent(env: &Env, cfg: &Config, c: &Checkpoint) {
    check_newer(env, cfg, c);
    require(
        env,
        checkpoint::is_recent(&core_checkpoint(c), now(env) as i64),
        VaultError::NotRecent,
    );
}

pub fn check_no_snapshot(env: &Env, cfg: &Config) {
    require(
        env,
        cfg.snapshot.state_root == zero32(env),
        VaultError::SnapshotTaken,
    );
}

/// The snapshot's state root, which every read of the hub's storage is under.
pub fn snapshot_root(env: &Env, cfg: &Config) -> [u8; 32] {
    let root = cfg.snapshot.state_root.to_array();
    require(env, root != [0u8; 32], VaultError::NoSnapshot);
    root
}

pub fn check_not_frozen(env: &Env, cfg: &Config) {
    require(env, now(env) >= cfg.frozen_until, VaultError::VaultFrozen);
}

// ---------------------------------------------------------------------
// payouts and the speed limit
// ---------------------------------------------------------------------

/// The index's speed-limit buckets, all empty: the current hour and the 24 before it.
pub fn empty_outflow(env: &Env) -> Vec<Bucket> {
    let mut v = Vec::new(env);
    for _ in 0..BUCKETS {
        v.push_back(Bucket { hour: 0, amount: 0 });
    }
    v
}

/// What more the index may pay out now: 4% of its balance before the recent outflow, or the floor if larger.
pub fn available(s: &IndexState, floor: u64, now: u64) -> u64 {
    let recent = speed::recent(s.outflow.iter().map(|b| (b.hour, b.amount)), now as i64);
    speed::available(s.balance, recent, floor)
}

/// Pays what the speed limit, the index's balance and a freeze allow of `owed`, out of `s`. `payable` is false when the
/// recipient cannot take it yet, an account that does not exist, and the payout then waits (SOL-5). `strict` is set for
/// an explicit release, which fails when it can pay nothing; a message just delivered keeps waiting instead. Returns
/// what it paid: the caller moves it, to the recipient or into the new index.
#[allow(clippy::too_many_arguments)]
pub fn pay_owed(
    env: &Env,
    cfg: &Config,
    index: &BytesN<20>,
    s: &mut IndexState,
    id: &BytesN<32>,
    owed: &mut Owed,
    strict: bool,
    payable: bool,
) -> u64 {
    require(env, owed.remaining != 0, VaultError::NothingOwed);
    let now = now(env);
    let pay = if now < cfg.frozen_until || !payable {
        0
    } else {
        owed.remaining
            .min(available(s, cfg.outflow_floor, now))
            .min(s.balance)
    };
    if pay == 0 {
        require(env, !strict, VaultError::NothingPayable);
        return 0;
    }
    owed.remaining -= pay;
    s.balance -= pay;
    s.paid_total += pay;
    let slot = speed::slot_of(speed::hour_of(now as i64)) as u32;
    let b = s.outflow.get(slot).unwrap();
    let (hour, amount) = speed::record((b.hour, b.amount), pay, now as i64);
    s.outflow.set(slot, Bucket { hour, amount });
    Paid {
        index: index.clone(),
        id: id.clone(),
        amount: pay,
        remaining: owed.remaining,
    }
    .publish(env);
    pay
}

/// Sends `amount` stroops of XLM from the vault to `to`.
pub fn send(env: &Env, cfg: &Config, to: &Address, amount: u64) {
    TokenClient::new(env, &cfg.xlm).transfer(
        &env.current_contract_address(),
        to,
        &(amount as i128),
    );
}
