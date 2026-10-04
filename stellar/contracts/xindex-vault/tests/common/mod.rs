//! What the vault's tests share: the real host with the built Wasm (`stellar contract build` first), the native asset's
//! own contract and accounts holding real XLM, two mock verifiers standing in for P1 and P2, messages built as
//! `VaultMessages.encode` builds them, and the repository's real fixtures.
//!
//! A mock verifier accepts a claim only with its "proof", the keccak of the claim it attests, so a test proves exactly
//! what it means to and nothing else; set broken, it accepts anything, as a proof system an attacker broke would.
#![allow(dead_code)]

use std::rc::Rc;

use serde_json::Value;
use soroban_sdk::address_payload::AddressPayload;
use soroban_sdk::testutils::{Address as _, Ledger};
use soroban_sdk::token::TokenClient;
use soroban_sdk::{contract, contractimpl, symbol_short, xdr, Address, Bytes, BytesN, Env, Vec};
use xindex_core::abi;
use xindex_core::constants::*;
use xindex_core::crypto::Crypto;
use xindex_core::native::Native;
use xindex_vault::types::*;
use xindex_vault::{XindexVault, XindexVaultClient};

pub const SOURCE_CHAIN_ID: u64 = 11_155_111;
/// Stellar testnet's registry id: the first 8 bytes of keccak256("stellar:testnet").
pub const CHAIN_ID: u64 = 17_667_989_177_921_016_935;
/// The tests' vault contract id, the one the hub fixture registers: keccak256("xindex stellar vault (tests)").
pub const VAULT_ID: [u8; 32] =
    xindex_core::hex::h("1fe52b378c4f36f86bb4aa3eafe30f9045c01bcc23182cd8ea8d01d43515728a");
pub const FACTORY: [u8; 20] = [0x44; 20];
pub const HUB: [u8; 20] = [0x33; 20];
pub const XLM: u64 = 10_000_000;
pub const CAP: u64 = 1_000_000 * XLM;
pub const FLOOR: u64 = XLM;
pub const START: u64 = 1_800_000_000;
pub const DAY: u64 = 86_400;

pub const C: Native = Native;

/// The instructions the host charged the last top-level call: Stellar allows 400M a transaction.
pub fn instructions(env: &Env) -> u64 {
    env.cost_estimate().resources().instructions as u64
}

/// Stellar's limits a transaction must fit: instructions and its own size.
pub const MAX_INSTRUCTIONS: u64 = 400_000_000;
pub const MAX_TX_BYTES: usize = 132_096;

/// A host that writes no test snapshot when dropped.
pub fn new_env() -> Env {
    Env::new_with_config(soroban_sdk::testutils::EnvTestConfig {
        capture_snapshot_at_drop: false,
    })
}

// ---------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------

pub fn hex(s: &str) -> std::vec::Vec<u8> {
    let s = s.trim_start_matches("0x");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

pub fn h20(v: &Value) -> [u8; 20] {
    hex(v.as_str().unwrap()).try_into().unwrap()
}

pub fn h32(v: &Value) -> [u8; 32] {
    hex(v.as_str().unwrap()).try_into().unwrap()
}

/// A file of the repository, by its path from the root.
pub fn repo_file(path: &str) -> String {
    std::fs::read_to_string(format!("{}/../../../{path}", env!("CARGO_MANIFEST_DIR")))
        .unwrap_or_else(|_| panic!("read {path}"))
}

pub fn json(path: &str) -> Value {
    serde_json::from_str(&repo_file(path)).unwrap()
}

/// A built contract's Wasm: `stellar contract build` writes them.
pub fn wasm(name: &str) -> std::vec::Vec<u8> {
    let path = format!(
        "{}/../../target/wasm32v1-none/release/{name}.wasm",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read(&path).unwrap_or_else(|_| panic!("build the contracts first: {path}"))
}

pub fn b32(env: &Env, w: &[u8; 32]) -> BytesN<32> {
    BytesN::from_array(env, w)
}

pub fn b20(env: &Env, w: &[u8; 20]) -> BytesN<20> {
    BytesN::from_array(env, w)
}

pub fn bytes(env: &Env, b: &[u8]) -> Bytes {
    Bytes::from_slice(env, b)
}

pub fn u256(x: u64) -> [u8; 32] {
    abi::u256(x)
}

pub fn address_word(a: &[u8; 20]) -> [u8; 32] {
    abi::address_word(a)
}

// ---------------------------------------------------------------------
// the mock verifier
// ---------------------------------------------------------------------

/// The "proof" a mock verifier takes for a log: the keccak of the claim.
pub fn event_proof(
    block: u64,
    emitter: &[u8; 20],
    id: &[u8; 32],
    data_hash: &[u8; 32],
) -> [u8; 32] {
    C.keccak256(&[
        b"event",
        &block.to_be_bytes(),
        emitter,
        &EVENT_TOPIC,
        id,
        data_hash,
    ])
}

/// The "proof" a mock verifier takes for a checkpoint.
pub fn checkpoint_proof(block: u64, timestamp: u64, state_root: &[u8; 32]) -> [u8; 32] {
    C.keccak256(&[
        b"checkpoint",
        &block.to_be_bytes(),
        &timestamp.to_be_bytes(),
        state_root,
    ])
}

#[contract]
pub struct MockVerifier;

#[contractimpl]
impl MockVerifier {
    pub fn __constructor(env: Env, broken: bool) {
        env.storage()
            .instance()
            .set(&symbol_short!("broken"), &broken);
    }

    pub fn set_broken(env: Env, broken: bool) {
        env.storage()
            .instance()
            .set(&symbol_short!("broken"), &broken);
    }

    pub fn verify_event(
        env: Env,
        block: u64,
        emitter: BytesN<20>,
        topic0: BytesN<32>,
        topic1: BytesN<32>,
        data_hash: BytesN<32>,
        proof: Bytes,
    ) {
        let broken: bool = env
            .storage()
            .instance()
            .get(&symbol_short!("broken"))
            .unwrap();
        assert_eq!(topic0.to_array(), EVENT_TOPIC);
        let expected = event_proof(
            block,
            &emitter.to_array(),
            &topic1.to_array(),
            &data_hash.to_array(),
        );
        if !broken && proof != Bytes::from_array(&env, &expected) {
            panic!("the mock verifier refuses this log");
        }
    }

    pub fn verify_checkpoint(
        env: Env,
        block: u64,
        timestamp: u64,
        state_root: BytesN<32>,
        proof: Bytes,
    ) {
        let broken: bool = env
            .storage()
            .instance()
            .get(&symbol_short!("broken"))
            .unwrap();
        let expected = checkpoint_proof(block, timestamp, &state_root.to_array());
        if !broken && proof != Bytes::from_array(&env, &expected) {
            panic!("the mock verifier refuses this checkpoint");
        }
    }
}

/// A multisig's stand-in: any contract will do as the recovery proposer, whose auth the tests mock.
#[contract]
pub struct MockMultisig;

#[contractimpl]
impl MockMultisig {}

// ---------------------------------------------------------------------
// accounts and XLM
// ---------------------------------------------------------------------

/// The native asset's contract, deployed where the network puts it.
pub fn native_asset(env: &Env) -> Address {
    let native = Bytes::from_array(env, &[0, 0, 0, 0]);
    let deployer = env.deployer().with_stellar_asset(native);
    let address = deployer.deployed_address();
    if !address.exists() {
        deployer.deploy();
    }
    address
}

/// The Stellar account of ed25519 key `key`.
pub fn account_of(env: &Env, key: &[u8; 32]) -> Address {
    Address::from_payload(
        env,
        AddressPayload::AccountIdPublicKeyEd25519(BytesN::from_array(env, key)),
    )
}

/// Creates the account `key` holding `stroops` of XLM, as the ledger holds an account.
pub fn create_account(env: &Env, key: &[u8; 32], stroops: i64) -> Address {
    let id = xdr::AccountId(xdr::PublicKey::PublicKeyTypeEd25519(xdr::Uint256(*key)));
    let k = Rc::new(xdr::LedgerKey::Account(xdr::LedgerKeyAccount {
        account_id: id.clone(),
    }));
    let v = Rc::new(xdr::LedgerEntry {
        data: xdr::LedgerEntryData::Account(xdr::AccountEntry {
            account_id: id,
            balance: stroops,
            flags: 0,
            home_domain: Default::default(),
            inflation_dest: None,
            num_sub_entries: 0,
            seq_num: xdr::SequenceNumber(0),
            thresholds: xdr::Thresholds([1; 4]),
            signers: xdr::VecM::default(),
            ext: xdr::AccountEntryExt::V0,
        }),
        last_modified_ledger_seq: 0,
        ext: xdr::LedgerEntryExt::V0,
    });
    env.host().add_ledger_entry(&k, &v, None).unwrap();
    account_of(env, key)
}

/// A new account with plenty of XLM.
pub fn funded(env: &Env, seed: &str) -> Address {
    let key = C.keccak256(&[seed.as_bytes()]);
    create_account(env, &key, 1_000_000_000 * XLM as i64)
}

/// A key no account holds yet.
pub fn key_of(seed: &str) -> [u8; 32] {
    C.keccak256(&[seed.as_bytes()])
}

// ---------------------------------------------------------------------
// the harness
// ---------------------------------------------------------------------

/// The vault on the real host, its Wasm, under P1 and P2 mock verifiers, with an index registered.
pub struct H {
    pub env: Env,
    pub vault: Address,
    pub xlm: Address,
    pub p1: Address,
    pub p2: Address,
    pub freezer: Address,
    pub recovery: Address,
    pub index: [u8; 20],
    pub salt: [u8; 32],
    pub nonce: u64,
    /// The Ethereum block the relayer claims a message's log is in: 1 unless a test moves it.
    pub block: u64,
}

/// Which proofs a delivery carries.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum By {
    Both,
    P1,
    P2,
}

impl H {
    /// The vault, registered at the tests' vault id, with the mainnet invocation limits enforced (the SDK's default).
    pub fn deployed() -> Self {
        Self::deployed_with(FACTORY, HUB, START)
    }

    /// The vault for the factory `factory` and its hub template `hub`, deployed at time `t`.
    pub fn deployed_with(factory: [u8; 20], hub: [u8; 20], t: u64) -> Self {
        let env = new_env();
        env.mock_all_auths();
        env.ledger().with_mut(|l| {
            l.timestamp = t;
            l.min_persistent_entry_ttl = 4096;
            l.max_entry_ttl = 6_312_000;
        });
        let xlm = native_asset(&env);
        let p1 = env.register(MockVerifier, (false,));
        let p2 = env.register(MockVerifier, (false,));
        let freezer = funded(&env, "freezer");
        let recovery = env.register(MockMultisig, ());
        let vault = Self::deploy_vault(&env, &p1, &p2, &freezer, &recovery, factory, hub);
        let mut h = H {
            env,
            vault,
            xlm,
            p1,
            p2,
            freezer,
            recovery,
            index: [0; 20],
            salt: [0; 32],
            nonce: 0,
            block: 1,
        };
        let (index, salt) = h.index_of(1);
        h.index = index;
        h.salt = salt;
        h
    }

    pub fn init_args(
        env: &Env,
        freezer: &Address,
        recovery: &Address,
        factory: [u8; 20],
        hub: [u8; 20],
    ) -> InitArgs {
        InitArgs {
            source_chain_id: SOURCE_CHAIN_ID,
            chain_id: CHAIN_ID,
            factory: b20(env, &factory),
            hub_implementation: b20(env, &hub),
            freezer: freezer.clone(),
            recovery_proposer: recovery.clone(),
            native_cap: CAP,
            native_floor: FLOOR,
        }
    }

    pub fn vault_address(env: &Env) -> Address {
        Address::from_payload(env, AddressPayload::ContractIdHash(b32(env, &VAULT_ID)))
    }

    pub fn deploy_vault(
        env: &Env,
        p1: &Address,
        p2: &Address,
        freezer: &Address,
        recovery: &Address,
        factory: [u8; 20],
        hub: [u8; 20],
    ) -> Address {
        let args = Self::init_args(env, freezer, recovery, factory, hub);
        env.register_at(
            &Self::vault_address(env),
            wasm("xindex_vault").as_slice(),
            (args, p1.clone(), p2.clone()),
        )
    }

    /// The vault deployed and an index registered, with a checkpoint at block 1,000 that covers the tests' messages, as
    /// relayers advance one before delivering.
    pub fn ready() -> Self {
        let h = Self::deployed();
        h.v()
            .register_index(&b20(&h.env, &h.index), &b32(&h.env, &h.salt));
        h.warp(1);
        h.advance(1_000);
        h
    }

    pub fn v(&self) -> XindexVaultClient<'_> {
        XindexVaultClient::new(&self.env, &self.vault)
    }

    pub fn token(&self) -> TokenClient<'_> {
        TokenClient::new(&self.env, &self.xlm)
    }

    pub fn balance(&self, a: &Address) -> i128 {
        self.token().balance(a)
    }

    pub fn config(&self) -> Config {
        self.v().config()
    }

    pub fn now(&self) -> u64 {
        self.env.ledger().timestamp()
    }

    pub fn set_time(&self, t: u64) {
        self.env.ledger().with_mut(|l| l.timestamp = t);
    }

    pub fn warp(&self, seconds: u64) {
        self.set_time(self.now() + seconds);
    }

    /// The factory's CREATE2 clone of the hub template under a salt derived from `n`.
    pub fn index_of(&self, n: u8) -> ([u8; 20], [u8; 32]) {
        let salt = C.keccak256(&[b"salt", &[n]]);
        (abi::predict_clone(&C, &HUB, &salt, &FACTORY), salt)
    }

    pub fn register(&self, n: u8) -> [u8; 20] {
        let (index, salt) = self.index_of(n);
        self.v()
            .register_index(&b20(&self.env, &index), &b32(&self.env, &salt));
        index
    }

    // ---- checkpoints

    pub fn checkpoint_at(&self, block: u64, timestamp: u64) -> Checkpoint {
        Checkpoint {
            block,
            timestamp,
            state_root: b32(
                &self.env,
                &C.keccak256(&[b"state root", &block.to_be_bytes()]),
            ),
        }
    }

    pub fn cp_proof(&self, c: &Checkpoint) -> Bytes {
        Bytes::from_array(
            &self.env,
            &checkpoint_proof(c.block, c.timestamp, &c.state_root.to_array()),
        )
    }

    pub fn advance_to(&self, c: &Checkpoint) {
        let p = self.cp_proof(c);
        self.v().advance_checkpoint(c, &p, &p);
    }

    /// A checkpoint at `block`, now, that P1 and P2 both prove.
    pub fn advance(&self, block: u64) {
        let c = self.checkpoint_at(block, self.now());
        self.advance_to(&c);
    }

    /// Keeps the vault out of a stall, as keepers do: a checkpoint one block on, now.
    pub fn fresh(&self) {
        let block = self.config().checkpoint.block + 1;
        self.advance(block);
    }

    // ---- messages

    /// A message as `VaultMessages.encode` builds it, from `emitter` (an index, or the factory), to this vault.
    pub fn payload(&mut self, kind: u8, emitter: [u8; 20], body: &[u8]) -> std::vec::Vec<u8> {
        self.nonce += 1;
        payload_with(kind, emitter, self.nonce, body)
    }

    pub fn proof_of(&self, payload: &[u8], block: u64) -> Bytes {
        let id = C.keccak256(&[payload]);
        let data_hash = abi::log_data_hash(&C, payload);
        Bytes::from_array(
            &self.env,
            &event_proof(block, &abi::index_in(payload), &id, &data_hash),
        )
    }

    /// Delivers `payload` with P1's proof, P2's or both, from block `self.block`.
    pub fn deliver(&self, payload: &[u8], by: By) {
        let p = self.proof_of(payload, self.block);
        self.v().deliver(
            &bytes(&self.env, payload),
            &self.block,
            &(by != By::P2).then(|| p.clone()),
            &(by != By::P1).then_some(p),
        );
    }

    pub fn try_deliver(&self, payload: &[u8], by: By) -> Result<(), soroban_sdk::Error> {
        let p = self.proof_of(payload, self.block);
        match self.v().try_deliver(
            &bytes(&self.env, payload),
            &self.block,
            &(by != By::P2).then(|| p.clone()),
            &(by != By::P1).then_some(p),
        ) {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(e.into()),
            Err(e) => Err(e.unwrap()),
        }
    }

    /// Deposits `amount` stroops from `from` into a fresh intake of the index and settles it, so the index holds it.
    pub fn fund(&mut self, amount: u64) -> [u8; 32] {
        let from = funded(&self.env, "depositor");
        let id = self.intake(self.now() + 3600);
        self.v().deposit(
            &from,
            &b20(&self.env, &self.index),
            &b32(&self.env, &id),
            &(amount as i128),
        );
        let p = self.payload(INTAKE_SETTLED, self.index, &id);
        self.deliver(&p, By::Both);
        id
    }

    /// A fresh intake id with this deadline: `(deadline << 192) | nonce`.
    pub fn intake(&mut self, deadline: u64) -> [u8; 32] {
        self.nonce += 1;
        intake_id(deadline, self.nonce)
    }

    pub fn burn_payload(&mut self, amount: u64, recipient: &[u8; 32]) -> std::vec::Vec<u8> {
        let body = [[0u8; 32], u256(amount), *recipient].concat();
        self.payload(BURN, self.index, &body)
    }

    pub fn index_state(&self, index: &[u8; 20]) -> IndexState {
        self.v().index_state(&b20(&self.env, index)).unwrap()
    }
}

pub fn intake_id(deadline: u64, nonce: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[..8].copy_from_slice(&deadline.to_be_bytes());
    w[24..].copy_from_slice(&nonce.to_be_bytes());
    w
}

/// A message to the tests' vault, from `emitter`, under `nonce`.
pub fn payload_with(kind: u8, emitter: [u8; 20], nonce: u64, body: &[u8]) -> std::vec::Vec<u8> {
    payload_for(
        SOURCE_CHAIN_ID,
        kind,
        CHAIN_ID,
        VAULT_ID,
        emitter,
        nonce,
        body,
    )
}

pub fn payload_for(
    source: u64,
    kind: u8,
    dest: u64,
    vault: [u8; 32],
    emitter: [u8; 20],
    nonce: u64,
    body: &[u8],
) -> std::vec::Vec<u8> {
    let mut p = std::vec::Vec::new();
    for w in [
        DOMAIN,
        u256(source),
        u256(kind as u64),
        u256(dest),
        vault,
        address_word(&emitter),
        u256(nonce),
        u256(256),
        u256(body.len() as u64),
    ] {
        p.extend_from_slice(&w);
    }
    p.extend_from_slice(body);
    p.resize(p.len() + (32 - body.len() % 32) % 32, 0);
    p
}

/// The vault's error with this code, as a failed call reports it.
pub fn code(e: xindex_vault::error::VaultError) -> soroban_sdk::Error {
    soroban_sdk::Error::from_contract_error(e as u32)
}

pub fn vec32(env: &Env, words: &[[u8; 32]]) -> Vec<BytesN<32>> {
    let mut v = Vec::new(env);
    for w in words {
        v.push_back(b32(env, w));
    }
    v
}

pub fn _unused(_: XindexVault) {}

/// A random account address, existing nowhere.
pub fn stranger(env: &Env) -> Address {
    Address::generate(env)
}
