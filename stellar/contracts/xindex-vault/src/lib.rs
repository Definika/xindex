//! Xindex v4 Stage B: the vault on Stellar, holding XLM for every index whose shares live on Ethereum. A Soroban twin
//! of the EVM vault (`src/vault/XindexVault.sol`) and of Solana's: XLM comes in only as deposits to an intake and leaves
//! only on messages P1 and P2 prove final on Ethereum, within a speed limit exact over any 24 hours. If Ethereum's
//! formats change unannounced and P1 and P2 stop working, the vault stalls, may adopt a successor pair after a
//! continuity test and 30 days of review, and after 180 days pays each index's holders at its last checkpoint directly
//! (design 6.9). It shows its own state to Ethereum through `attest` (`design/2026-10-03-near-stellar-interfaces.md`).
//!
//! No owner and no upgrade path: the constructor fixes the settings at deployment, atomically, and no call replaces the
//! contract's Wasm, so the deployer must deploy it with a plain Wasm executable, never behind an executable reference.
//! Two chain-level powers remain over any Soroban contract, which no contract can remove: a validator vote may freeze a
//! ledger key (CAP-0077), blocking access to the vault's entries though not taking them, and a protocol upgrade may
//! amend state, as CAP-0076 once did.

#![no_std]

extern crate alloc;

pub mod error;
pub mod events;
pub mod exit;
pub mod messages;
pub mod recovery;
pub mod types;
pub mod vault;

use soroban_sdk::address_payload::AddressPayload;
use soroban_sdk::token::TokenClient;
use soroban_sdk::{contract, contractimpl, Address, Bytes, BytesN, Env, Executable, Vec};
use xindex_core::abi;
use xindex_core::constants::*;
use xindex_core::hex::h;
use xindex_soroban::Soroban;

use error::VaultError;
use events::*;
use types::*;
use vault::{fail, require};

/// `keccak256("xindex.v4.vault-attest")`.
pub const ATTEST_DOMAIN: [u8; 32] =
    h("b0ec2b25fdd79b42b523d5b0e641474599bbba254460db808de33f7bc0c25d5c");

/// The native asset as an XDR `Asset`: its type, `ASSET_TYPE_NATIVE`, alone.
const NATIVE_ASSET: [u8; 4] = [0, 0, 0, 0];

/// The networks the vault deploys on, by their ids, the SHA-256 of their passphrases: `Public Global Stellar Network ;
/// September 2015` and `Test SDF Network ; September 2015`.
pub const PUBNET_NETWORK_ID: [u8; 32] =
    h("7ac33997544e3175d266bd022439b22cdb16508c01163f26e5cb2a3e1045a979");
pub const TESTNET_NETWORK_ID: [u8; 32] =
    h("cee0302d59844d32bdca915c8203dd44b33fbb7edc19051ea37abedf28ecd472");
/// Their ids in the factory's chain registry, the first 8 bytes of `keccak256("stellar:pubnet")` and
/// `keccak256("stellar:testnet")` (`design/2026-10-03-near-stellar-interfaces.md`).
pub const STELLAR_PUBNET: u64 = 839_718_837_228_939_926;
pub const STELLAR_TESTNET: u64 = 17_667_989_177_921_016_935;
/// The Ethereum network each pairs with: mainnet with pubnet, Sepolia with testnet.
pub const ETHEREUM_MAINNET: u64 = 1;
pub const SEPOLIA: u64 = 11_155_111;

#[contract]
pub struct XindexVault;

#[contractimpl]
impl XindexVault {
    /// The deployer's settings, and P1 and P2: two different Wasm contracts, whose code the vault pins. The chain ids
    /// are the network's own: Stellar's registry id and Ethereum mainnet's on pubnet, testnet's and Sepolia's on
    /// testnet, and no other network takes the vault (B3-02). The floor is at most the cap (B2-02). The freezer is a
    /// Stellar account, whose own signers and thresholds may make it a multisig. The recovery proposer must be a
    /// contract, the twin of `DeployVault`'s "a contract, not an EIP-7702 account": a Stellar account's signers cannot
    /// be read from a contract, so one would have to be trusted to be a multisig.
    pub fn __constructor(env: Env, args: InitArgs, p1: Address, p2: Address) {
        require(
            &env,
            args.factory.to_array() != [0u8; 20] && args.hub_implementation.to_array() != [0u8; 20],
            VaultError::ZeroAddress,
        );
        // The chain ids the network it runs on must carry, as `DeployVault` pairs them on an EVM chain (HUB-I2): on an
        // ownerless vault a wrong one is for good, every message refused and every digest unprovable (B3-02).
        // Ethereum's own chain is then never the vault's (B2-02).
        let (registry, ethereum) = match env.ledger().network_id().to_array() {
            PUBNET_NETWORK_ID => (STELLAR_PUBNET, ETHEREUM_MAINNET),
            TESTNET_NETWORK_ID => (STELLAR_TESTNET, SEPOLIA),
            _ => fail(&env, VaultError::WrongRoute),
        };
        require(
            &env,
            args.chain_id == registry && args.source_chain_id == ethereum,
            VaultError::WrongRoute,
        );
        // A floor above the cap would leave the speed limit never binding, as `DeployVault` refuses (B2-02).
        require(
            &env,
            args.native_floor <= args.native_cap,
            VaultError::FloorAboveCap,
        );
        let freezer = match args.freezer.to_payload() {
            Some(AddressPayload::AccountIdPublicKeyEd25519(key)) => key,
            _ => fail(&env, VaultError::NotAnAccount),
        };
        require(
            &env,
            freezer != vault::zero32(&env),
            VaultError::ZeroAddress,
        );
        // A contract, so never the freezer, which is an account: the two roles are distinct by their kinds.
        require(
            &env,
            matches!(
                args.recovery_proposer.executable(),
                Some(Executable::Wasm(_))
            ),
            VaultError::NotAContract,
        );
        let (p1, p2) = vault::pin_pair(&env, p1, p2);
        let xlm = env
            .deployer()
            .with_stellar_asset(Bytes::from_array(&env, &NATIVE_ASSET))
            .deployed_address();
        require(&env, xlm.exists(), VaultError::NoNativeAsset);
        let zero = vault::zero32(&env);
        let cfg = Config {
            source_chain_id: args.source_chain_id,
            chain_id: args.chain_id,
            factory: args.factory,
            hub_implementation: args.hub_implementation,
            xlm,
            p1,
            p2,
            freezer: args.freezer,
            frozen_until: 0,
            cap: args.native_cap,
            outflow_floor: args.native_floor,
            held: 0,
            cap_nonce: 0,
            freezer_nonce: 0,
            rotation_nonce: 0,
            pending_cap: messages::none(&env),
            pending_freezer: messages::none(&env),
            pending_rotation: messages::none(&env),
            recovery_proposer: args.recovery_proposer,
            // Its first week's grace: a stall is a week without a new checkpoint, counted from deployment until the
            // first.
            checkpoint: Checkpoint {
                block: 0,
                timestamp: vault::now(&env),
                state_root: zero.clone(),
            },
            snapshot: Checkpoint {
                block: 0,
                timestamp: 0,
                state_root: zero.clone(),
            },
            last_message: zero,
            vetoes: 0,
        };
        CapSet {
            cap: cfg.cap,
            outflow_floor: cfg.outflow_floor,
        }
        .publish(&env);
        vault::set_config(&env, &cfg);
    }

    /// Anyone: records `index` once its address is the factory's CREATE2 clone of the hub template under `salt`. Only a
    /// registered index takes deposits or sends messages that run.
    pub fn register_index(env: Env, index: BytesN<20>, salt: BytesN<32>) {
        let cfg = vault::config(&env);
        let predicted = abi::predict_clone(
            &Soroban(&env),
            &cfg.hub_implementation.to_array(),
            &salt.to_array(),
            &cfg.factory.to_array(),
        );
        require(&env, predicted == index.to_array(), VaultError::NotAnIndex);
        if vault::is_index(&env, &index) {
            return;
        }
        let s = IndexState {
            has_native: false,
            balance: 0,
            paid_total: 0,
            outflow: vault::empty_outflow(&env),
        };
        vault::refresh_index(&env, &cfg, &index, &s);
        vault::put_index(&env, &index, &s);
        IndexRegistered { index, salt }.publish(&env);
    }

    /// `from`, while neither frozen nor stalled, from the first checkpoint: deposits `amount` stroops of XLM into
    /// intake `intake_id` of `index`. The intake's deadline is its id's top 64 bits: nobody can open another's intake
    /// with another deadline, and deposits close at it for everyone. The vault books what the native asset's contract
    /// moves, exactly `amount`.
    pub fn deposit(
        env: Env,
        from: Address,
        index: BytesN<20>,
        intake_id: BytesN<32>,
        amount: i128,
    ) {
        from.require_auth();
        let mut cfg = vault::config(&env);
        vault::check_not_frozen(&env, &cfg);
        // A stalled vault may never again see the message that would settle or fail an intake.
        require(&env, !vault::stalled(&env, &cfg), VaultError::VaultStalled);
        // Nor may one without a checkpoint: no message runs from a block none covers, and no successor or snapshot can
        // follow without one (B1-04).
        require(
            &env,
            cfg.checkpoint.state_root != vault::zero32(&env),
            VaultError::NoCheckpoint,
        );
        require(&env, amount > 0, VaultError::ZeroAmount);
        require(&env, amount <= u64::MAX as i128, VaultError::Overflow);
        let amount = amount as u64;
        require(&env, vault::is_index(&env, &index), VaultError::NotAnIndex);
        let now = vault::now(&env);
        let deadline = abi::deadline_of(&intake_id.to_array());
        require(&env, now <= deadline, VaultError::IntakeClosed);
        let key = DataKey::Intake(index.clone(), intake_id.clone());
        let mut intake: Intake = match vault::get::<Intake>(&env, &key) {
            None => {
                require(
                    &env,
                    deadline <= now + MAX_INTAKE_LIFE as u64,
                    VaultError::IntakeTooLong,
                );
                Intake {
                    state: INTAKE_OPEN as u32,
                    has_native: false,
                    total: 0,
                }
            }
            Some(i) if i.state == INTAKE_OPEN as u32 => i,
            Some(_) => fail(&env, VaultError::IntakeClosed),
        };
        let held = cfg
            .held
            .checked_add(amount)
            .unwrap_or_else(|| fail(&env, VaultError::CapExceeded));
        require(&env, held <= cfg.cap, VaultError::CapExceeded);
        cfg.held = held;
        let record = DataKey::Deposit(index.clone(), intake_id.clone(), from.clone());
        let mine: u64 = vault::get(&env, &record).unwrap_or(0);
        vault::put(&env, &record, &(mine + amount));
        intake.total += amount;
        intake.has_native = true;
        vault::refresh_intake(&env, &cfg, &index, &intake_id, &intake);
        vault::put(&env, &key, &intake);
        vault::set_config(&env, &cfg);
        Deposited {
            index,
            intake_id,
            depositor: from.clone(),
            amount,
        }
        .publish(&env);
        TokenClient::new(&env, &cfg.xlm).transfer(
            &from,
            env.current_contract_address(),
            &(amount as i128),
        );
    }

    /// A depositor of a failed intake, while not frozen: takes its deposit back.
    pub fn refund(env: Env, depositor: Address, index: BytesN<20>, intake_id: BytesN<32>) {
        depositor.require_auth();
        let mut cfg = vault::config(&env);
        let key = DataKey::Intake(index.clone(), intake_id.clone());
        let mut intake: Intake = vault::get(&env, &key)
            .filter(|i: &Intake| i.state == INTAKE_FAILED_STATE as u32)
            .unwrap_or_else(|| fail(&env, VaultError::IntakeNotOpen));
        vault::check_not_frozen(&env, &cfg);
        let record = DataKey::Deposit(index.clone(), intake_id.clone(), depositor.clone());
        let amount: u64 = vault::get(&env, &record).unwrap_or(0);
        require(&env, amount != 0, VaultError::NothingToRefund);
        vault::put(&env, &record, &0u64);
        cfg.held -= amount;
        intake.total -= amount;
        vault::refresh_intake(&env, &cfg, &index, &intake_id, &intake);
        vault::put(&env, &key, &intake);
        vault::set_config(&env, &cfg);
        Refunded {
            index,
            intake_id,
            depositor: depositor.clone(),
            amount,
        }
        .publish(&env);
        vault::send(&env, &cfg, &depositor, amount);
    }

    /// Anyone: runs one `VaultMessage` an index or the factory emitted on Ethereum in `block`, with P1's proof, P2's or
    /// both. A burn, an intake's settlement or failure, a migration, a raised cap or floor, a new freezer and new
    /// verifiers need both and a checkpoint covering `block`; a freeze and a lowered cap may rest on one.
    pub fn deliver(
        env: Env,
        payload: Bytes,
        block: u64,
        proof1: Option<Bytes>,
        proof2: Option<Bytes>,
    ) {
        messages::deliver(&env, &payload, block, &proof1, &proof2);
    }

    /// Anyone, while not frozen: pays what the speed limit now allows of an owed burn or claim, once its account exists.
    pub fn release(env: Env, index: BytesN<20>, id: BytesN<32>) {
        let mut cfg = vault::config(&env);
        let mut owed: Owed = vault::get(&env, &DataKey::Owed(index.clone(), id.clone()))
            .unwrap_or_else(|| fail(&env, VaultError::NothingOwed));
        require(&env, !owed.to_index, VaultError::WrongRecipient);
        messages::pay_recipient(&env, &mut cfg, &index, &id, &mut owed, true);
        vault::set_config(&env, &cfg);
    }

    /// Anyone, while not frozen: moves what the speed limit now allows of an owed migration into the new index.
    pub fn release_migration(env: Env, index: BytesN<20>, id: BytesN<32>) {
        let cfg = vault::config(&env);
        let mut owed: Owed = vault::get(&env, &DataKey::Owed(index.clone(), id.clone()))
            .unwrap_or_else(|| fail(&env, VaultError::NothingOwed));
        require(&env, owed.to_index, VaultError::WrongRecipient);
        messages::pay_migration(&env, &cfg, &index, &id, &mut owed, true);
    }

    /// The guardian's freeze address only, before any snapshot exit: freezes the vault for FREEZE_DURATION from now.
    /// Nothing could replace the freezer after a snapshot, so it must not be able to hold the exit off for good (VLT-5).
    pub fn freeze(env: Env) {
        let mut cfg = vault::config(&env);
        cfg.freezer.require_auth();
        vault::check_no_snapshot(&env, &cfg);
        let until = vault::now(&env) + FREEZE_DURATION as u64;
        messages::freeze_until(&env, &mut cfg, until);
        vault::set_config(&env, &cfg);
    }

    /// Anyone, from its `ready_at`: applies the waiting governance change of `kind` with this body.
    pub fn apply_change(env: Env, kind: u32, body: Bytes) {
        messages::apply_change(&env, kind, &body);
    }

    /// The freezer only: drops a waiting cap raise or rotation, never its own replacement.
    pub fn cancel_change(env: Env, kind: u32) {
        messages::cancel_change(&env, kind);
    }

    /// Anyone, before a snapshot exit: a final Ethereum block both P1 and P2 prove, newer than the last.
    pub fn advance_checkpoint(env: Env, checkpoint: Checkpoint, proof1: Bytes, proof2: Bytes) {
        recovery::advance_checkpoint(&env, &checkpoint, &proof1, &proof2);
    }

    /// The recovery proposer only, while stalled: a successor pair that passes the continuity test.
    pub fn propose_successor(
        env: Env,
        new_p1: Address,
        new_p2: Address,
        continuity: Continuity,
        last_message: Option<LastMessage>,
    ) {
        recovery::propose_successor(&env, new_p1, new_p2, &continuity, &last_message);
    }

    /// The freezer only, at most twice a stall: drops the successor under review.
    pub fn veto_successor(env: Env) {
        recovery::veto_successor(&env);
    }

    /// Anyone, once the review is over, with a recent checkpoint the successor proves: makes it P1 and P2.
    pub fn adopt_successor(env: Env, checkpoint: Checkpoint, proof1: Bytes, proof2: Bytes) {
        recovery::adopt_successor(&env, &checkpoint, &proof1, &proof2);
    }

    /// Anyone, 180 days into a stall: takes the last checkpoint as the snapshot, for good.
    pub fn begin_snapshot(env: Env) {
        recovery::begin_snapshot(&env);
    }

    /// Anyone, after the snapshot: pays `holder`'s share of XLM in `index` to the account `recipient`.
    pub fn claim_snapshot(
        env: Env,
        index: BytesN<20>,
        holder: BytesN<20>,
        component: u64,
        recipient: BytesN<32>,
        signature: Bytes,
        proof: Bytes,
    ) {
        exit::claim_snapshot(
            &env, &index, &holder, component, &recipient, &signature, &proof,
        );
    }

    /// Anyone, after the snapshot: settles or fails an intake still open, by the hub's mark at the snapshot.
    pub fn resolve_intake(env: Env, index: BytesN<20>, intake_id: BytesN<32>, proof: Bytes) {
        exit::resolve_intake(&env, &index, &intake_id, &proof);
    }

    /// Anyone, after the snapshot: a burn or migration the hub marked sent, run once on that mark.
    pub fn deliver_recorded(env: Env, payload: Bytes, proof: Bytes) {
        exit::deliver_recorded(&env, &payload, &proof);
    }

    /// Anyone: succeeds only if every slot of the map the hub reads holds its value, an absent one zero, and then emits
    /// exactly one record, `abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots, values)`, as the `Attest` event. A
    /// successful `attest` in a final ledger is what Stellar's state verifier on Ethereum proves, in place of a storage
    /// proof, as on TRON (`design/2026-10-03-near-stellar-interfaces.md`).
    pub fn attest(env: Env, slots: Vec<BytesN<32>>, values: Vec<BytesN<32>>) {
        let cfg = vault::config(&env);
        let n = slots.len();
        require(&env, values.len() == n, VaultError::NotAttested);
        for i in 0..n {
            require(
                &env,
                vault::slot(&env, &slots.get(i).unwrap()) == values.get(i).unwrap(),
                VaultError::NotAttested,
            );
        }
        Attest {
            record: attest_record(&env, cfg.chain_id, &slots, &values),
        }
        .publish(&env);
    }

    // ---------------------------------------------------------------------
    // views
    // ---------------------------------------------------------------------

    pub fn config(env: Env) -> Config {
        vault::config(&env)
    }

    /// The successor pair under review, if any.
    pub fn successor(env: Env) -> Option<Successor> {
        vault::successor(&env)
    }

    /// The vault's id on Ethereum: its contract id.
    pub fn vault_id(env: Env) -> BytesN<32> {
        BytesN::from_array(&env, &vault::vault_id(&env))
    }

    pub fn index_state(env: Env, index: BytesN<20>) -> Option<IndexState> {
        vault::get(&env, &DataKey::Index(index))
    }

    pub fn intake(env: Env, index: BytesN<20>, intake_id: BytesN<32>) -> Option<Intake> {
        vault::get(&env, &DataKey::Intake(index, intake_id))
    }

    pub fn deposited(
        env: Env,
        index: BytesN<20>,
        intake_id: BytesN<32>,
        depositor: Address,
    ) -> u64 {
        vault::get(&env, &DataKey::Deposit(index, intake_id, depositor)).unwrap_or(0)
    }

    pub fn owed(env: Env, index: BytesN<20>, id: BytesN<32>) -> Option<Owed> {
        vault::get(&env, &DataKey::Owed(index, id))
    }

    pub fn used(env: Env, id: BytesN<32>) -> bool {
        env.storage().persistent().has(&DataKey::Used(id))
    }

    /// The value at a slot of the map the hub reads; zero if none.
    pub fn slot(env: Env, key: BytesN<32>) -> BytesN<32> {
        vault::slot(&env, &key)
    }

    /// An index's digest, as the hub reads it.
    pub fn index_digest(env: Env, index: BytesN<20>) -> BytesN<32> {
        let key = vault::index_slot(&env, &index.to_array());
        vault::slot(&env, &BytesN::from_array(&env, &key))
    }

    /// An intake's digest, as the hub reads it.
    pub fn intake_digest(env: Env, index: BytesN<20>, intake_id: BytesN<32>) -> BytesN<32> {
        let key = vault::intake_slot(&env, &index.to_array(), &intake_id.to_array());
        vault::slot(&env, &BytesN::from_array(&env, &key))
    }

    /// What more an index may pay out now, by the speed limit and its balance.
    pub fn available(env: Env, index: BytesN<20>) -> u64 {
        let cfg = vault::config(&env);
        let s = vault::index_state(&env, &index);
        vault::available(&s, cfg.outflow_floor, vault::now(&env)).min(s.balance)
    }

    pub fn stalled(env: Env) -> bool {
        vault::stalled(&env, &vault::config(&env))
    }

    pub fn stall_start(env: Env) -> u64 {
        vault::stall_start(&vault::config(&env))
    }
}

/// `abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots, values)`, as Solidity encodes `(bytes32, uint256, bytes32,
/// bytes32[], bytes32[])`.
pub fn attest_record(
    env: &Env,
    chain_id: u64,
    slots: &Vec<BytesN<32>>,
    values: &Vec<BytesN<32>>,
) -> Bytes {
    let n = slots.len() as u64;
    let mut out = Bytes::new(env);
    out.extend_from_array(&ATTEST_DOMAIN);
    out.extend_from_array(&abi::u256(chain_id));
    out.extend_from_array(&vault::vault_id(env));
    out.extend_from_array(&abi::u256(5 * 32));
    out.extend_from_array(&abi::u256(5 * 32 + 32 * (1 + n)));
    for list in [slots, values] {
        out.extend_from_array(&abi::u256(n));
        for w in list.iter() {
            out.extend_from_array(&w.to_array());
        }
    }
    out
}
