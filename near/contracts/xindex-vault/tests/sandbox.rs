//! The vault as nearcore runs it: the release Wasm (`cargo build -p xindex-vault-near --target wasm32-unknown-unknown
//! --release`, built first) on the near-workspaces sandbox, nearcore 2.13. What the mocked runtime cannot show is shown
//! here: the NEP-616 deployment that leaves the vault no key and no owner, P1's and P2's real Groth16 proofs and a real
//! Ethereum receipt through the chain's host functions, payouts that create the implicit accounts they pay, `attest`'s
//! raw return value and its block, the `#[private]` callbacks, and the snapshot exit on a real hub's storage. Every
//! method's gas is measured against NEAR's 1 PGas limit.
//!
//! P1's and P2's ranges, which only a statement proof records, are patched into the vault's storage, as the unit tests
//! record them; everything else goes through the contract's own methods.

#[path = "../src/tests/encode.rs"]
#[allow(dead_code)]
mod encode;
#[path = "../src/fixtures.rs"]
#[allow(dead_code)]
mod fixtures;

use std::collections::BTreeMap;

use encode::*;
use fixtures::{hex, hex_str, repo_file, risc0_receipt, sp1_fixture};
use near_jsonrpc_client::methods::send_tx::RpcSendTransactionRequest;
use near_jsonrpc_client::JsonRpcClient;
use near_primitives::action::{
    Action, DeployGlobalContractAction, DeterministicStateInitAction, GlobalContractDeployMode,
    GlobalContractIdentifier,
};
use near_primitives::deterministic_account_id::{
    DeterministicAccountStateInit, DeterministicAccountStateInitV1,
};
use near_primitives::hash::CryptoHash;
use near_primitives::transaction::{SignedTransaction, Transaction, TransactionV0};
use near_primitives::utils::derive_near_deterministic_account_id;
use near_primitives::views::{
    FinalExecutionOutcomeViewEnum, FinalExecutionStatus, TxExecutionStatus,
};
use near_sdk::json_types::{Base64VecU8, U128, U64};
use near_sdk::test_utils::VMContextBuilder;
use near_sdk::testing_env;
use near_workspaces::network::Sandbox;
use near_workspaces::result::ExecutionFinalResult;
use near_workspaces::types::{Gas, NearToken};
use near_workspaces::{Account, AccountId, Worker};
use serde_json::{json, Value};
use xindex_core::abi::{address_word, u256};
use xindex_core::constants::*;
use xindex_vault_near::*;

const WASM: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../target/wasm32-unknown-unknown/release/xindex_vault_near.wasm"
);
const SEPOLIA: u64 = 11_155_111;
const NEAR_TESTNET: u64 = 4_078_699_518_750_379_172;
const SEPOLIA_GENESIS: u64 = 1_655_733_600;
const ONE: u128 = 1_000_000_000_000_000_000_000_000;
/// NEAR's limit on a function call's gas, 1 PGas.
const LIMIT: u64 = 1_000_000_000_000_000;

fn h20(v: &Value) -> [u8; 20] {
    hex(v.as_str().unwrap()).try_into().unwrap()
}

fn h32(v: &Value) -> [u8; 32] {
    hex(v.as_str().unwrap()).try_into().unwrap()
}

fn word_hex(w: &[u8]) -> String {
    format!("0x{}", hex_str(w))
}

fn b64(b: &[u8]) -> Base64VecU8 {
    Base64VecU8(b.to_vec())
}

fn hub() -> Value {
    serde_json::from_str(&repo_file(
        "near/contracts/xindex-vault/tests/fixtures/hub.json",
    ))
    .unwrap()
}

fn epoch_at(now: u64) -> u64 {
    (now - SEPOLIA_GENESIS) / 384
}

fn index_slot(index: &[u8; 20]) -> [u8; 32] {
    keccak_native(&[&address_word(index), &u256(14)])
}

fn intake_slot(index: &[u8; 20], intake: &[u8; 32]) -> [u8; 32] {
    keccak_native(&[intake, &keccak_native(&[&address_word(index), &u256(15)])])
}

/// The vault's settings: P1 and P2 the SP1 and RISC Zero programs whose real proofs the repository holds, so their
/// Groth16 checks pass on chain; the fixture hub's factory and template, so its index registers.
fn config(f: &Value, now: u64) -> InitConfig {
    let (vkey, _, _) = sp1_fixture();
    let (image, _, _) = risc0_receipt();
    InitConfig {
        source_chain_id: U64(SEPOLIA),
        chain_id: U64(NEAR_TESTNET),
        factory: Hex20(h20(&f["factory"])),
        hub_implementation: Hex20(h20(&f["hub_implementation"])),
        p1: VerifierConfig {
            system: SP1,
            key: Hex32(vkey),
            anchor: Hex32([3; 32]),
            epoch: epoch_at(now),
            genesis_time: SEPOLIA_GENESIS,
        },
        p2: VerifierConfig {
            system: RISC_ZERO,
            key: Hex32(image),
            anchor: Hex32([4; 32]),
            epoch: epoch_at(now),
            genesis_time: SEPOLIA_GENESIS,
        },
        freezer: "freezer.test.near".parse().unwrap(),
        recovery_proposer: "recovery.test.near".parse().unwrap(),
        native_cap: U128(1_000_000 * ONE),
        native_floor: U128(ONE),
    }
}

/// The storage key of a range P1 or P2 recorded: `Key::Ranges` (1), then the borsh of `(verifier, headers root)`.
fn range_key(verifier: &[u8; 32], root: &[u8; 32]) -> Vec<u8> {
    [&[1u8][..], verifier, root].concat()
}

fn range_value(first: u64, last: u64) -> Vec<u8> {
    [first.to_le_bytes(), last.to_le_bytes()].concat()
}

/// What a call cost the vault, and how it ended.
struct Outcome {
    gas: u64,
    failure: String,
    value: Vec<u8>,
    logs: Vec<String>,
    block: near_workspaces::CryptoHash,
}

impl Outcome {
    fn of(r: ExecutionFinalResult, vault: &AccountId) -> Self {
        let o = r
            .receipt_outcomes()
            .iter()
            .find(|o| &o.executor_id == vault)
            .expect("a receipt ran on the vault")
            .clone();
        let failure = if r.is_failure() {
            format!("{:?}", r.receipt_failures())
        } else {
            String::new()
        };
        let value = r.raw_bytes().unwrap_or_default();
        Self {
            gas: o.gas_burnt.as_gas(),
            failure,
            value,
            logs: o.logs,
            block: o.block_hash,
        }
    }

    fn ok(self, name: &str, gas: &mut Vec<(String, u64)>) -> Self {
        assert!(self.failure.is_empty(), "{name}: {}", self.failure);
        assert!(self.gas < LIMIT, "{name} burns {} gas", self.gas);
        gas.push((name.to_string(), self.gas));
        self
    }

    fn fails(self, expected: &str, name: &str, gas: &mut Vec<(String, u64)>) {
        assert!(
            self.failure.contains(expected),
            "{name}: expected {expected}, got {:?}",
            self.failure
        );
        if !name.is_empty() {
            gas.push((name.to_string(), self.gas));
        }
    }
}

async fn call(
    from: &Account,
    vault: &AccountId,
    method: &str,
    args: Value,
    deposit: u128,
) -> anyhow::Result<Outcome> {
    let r = from
        .call(vault, method)
        .args_json(args)
        .deposit(NearToken::from_yoctonear(deposit))
        .gas(Gas::from_tgas(1000))
        .transact()
        .await?;
    Ok(Outcome::of(r, vault))
}

async fn balance(worker: &Worker<Sandbox>, account: &str) -> anyhow::Result<u128> {
    let id: AccountId = account.parse()?;
    Ok(worker.view_account(&id).await?.balance.as_yoctonear())
}

/// Signs `actions` from `from` to `to` and sends them over RPC, waiting for finality: for NEP-616's actions, which
/// near-workspaces has no builder for.
async fn send(
    worker: &Worker<Sandbox>,
    from: &Account,
    to: &AccountId,
    actions: Vec<Action>,
) -> anyhow::Result<()> {
    let secret: near_crypto::SecretKey = from.secret_key().to_string().parse()?;
    let signer = near_crypto::InMemorySigner::from_secret_key(from.id().clone(), secret);
    let key = from
        .view_access_key(&from.secret_key().public_key())
        .await?;
    let block = worker.view_block().await?;
    let tx = Transaction::V0(TransactionV0 {
        signer_id: from.id().clone(),
        public_key: signer.public_key(),
        nonce: key.nonce + 1,
        receiver_id: to.clone(),
        block_hash: CryptoHash(block.hash().0),
        actions,
    });
    let (hash, _) = tx.get_hash_and_size();
    let signed = SignedTransaction::new(signer.sign(hash.as_ref()), tx);
    let response = JsonRpcClient::connect(worker.rpc_addr())
        .call(RpcSendTransactionRequest {
            signed_transaction: signed,
            wait_until: TxExecutionStatus::Final,
        })
        .await?;
    let outcome = match response.final_execution_outcome {
        Some(FinalExecutionOutcomeViewEnum::FinalExecutionOutcome(o)) => o,
        Some(FinalExecutionOutcomeViewEnum::FinalExecutionOutcomeWithReceipt(o)) => o.final_outcome,
        None => anyhow::bail!("no outcome"),
    };
    match outcome.status {
        FinalExecutionStatus::SuccessValue(_) => Ok(()),
        other => anyhow::bail!("{other:?}"),
    }
}

/// The vault's initial storage for `config` at `now`, as `new` leaves it: its state and the two light clients, built by
/// the contract's own `build` in the mocked runtime. A deterministic account's id commits to exactly this.
fn initial_state(config: InitConfig, now: u64) -> BTreeMap<Vec<u8>, Vec<u8>> {
    testing_env!(VMContextBuilder::new().build());
    let v = Vault::build(config, now);
    let state = near_sdk::borsh::to_vec(&v).unwrap();
    drop(v); // writes the light clients
    let mut data: BTreeMap<Vec<u8>, Vec<u8>> =
        near_sdk::mock::with_mocked_blockchain(|b| b.take_storage())
            .into_iter()
            .collect();
    data.insert(b"STATE".to_vec(), state);
    data
}

/// The real block of `test/fixtures/ethereum/receipts.json` under a five-block headers root.
fn real_block(b: &Value) -> (Vec<u8>, [u8; 32], (u64, u64)) {
    five_blocks(
        b["number"].as_u64().unwrap(),
        b["timestamp"].as_u64().unwrap(),
        &h32(&b["stateRoot"]),
        &h32(&b["receiptsRoot"]),
    )
}

fn nodes(v: &Value) -> Vec<Vec<u8>> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|n| hex(n.as_str().unwrap()))
        .collect()
}

fn report(title: &str, gas: &[(String, u64)]) {
    println!("{title}");
    for (name, g) in gas {
        println!(
            "  {name:<44} {:>8.2} Tgas  ({:.1}% of 1 PGas)",
            *g as f64 / 1e12,
            *g as f64 / LIMIT as f64 * 100.0
        );
    }
}

/// The vault at a NEP-616 deterministic account: its code deployed once by its hash, which no one can change, and the
/// account created from its initial state, which its id commits to. The account has no access key, the code no upgrade
/// method: nobody can sign for the vault or change it. Then everything a live vault does, on the chain's own host
/// functions: an index registered by the factory's CREATE2 formula, a checkpoint at a real Ethereum block and a real
/// receipt under it, a deposit settled and burns paid to the implicit and ETH-implicit accounts they create, `attest`'s
/// record stating the block it ran in, a private callback refused, and P1's and P2's real Groth16 proofs checked.
#[tokio::test]
async fn a_deterministic_vault_runs_with_no_key_and_no_owner() -> anyhow::Result<()> {
    let worker = near_workspaces::sandbox().await?;
    let root = worker.root_account()?;
    let wasm = std::fs::read(WASM)?;
    let f = hub();
    let real: Value = serde_json::from_str(&repo_file("test/fixtures/ethereum/receipts.json"))?;
    let real_time = real["timestamp"].as_u64().unwrap();
    let now = worker.view_block().await?.timestamp() / 1_000_000_000;
    assert!(
        now > real_time,
        "the sandbox runs on the wall clock, after the real block"
    );
    let config = config(&f, now);
    let (p1, p2) = (verifier_id(&config.p1), verifier_id(&config.p2));

    // The code, by its hash; then the account, from its initial state, initialized before the real block so that
    // block can be its first checkpoint.
    send(
        &worker,
        &root,
        root.id(),
        vec![Action::DeployGlobalContract(DeployGlobalContractAction {
            code: wasm.clone().into(),
            deploy_mode: GlobalContractDeployMode::CodeHash,
        })],
    )
    .await?;
    let state_init = DeterministicAccountStateInit::V1(DeterministicAccountStateInitV1 {
        code: GlobalContractIdentifier::CodeHash(near_primitives::hash::hash(&wasm)),
        data: initial_state(config.clone(), real_time - 1_000),
    });
    let id = derive_near_deterministic_account_id(&state_init);
    send(
        &worker,
        &root,
        &id,
        vec![Action::DeterministicStateInit(Box::new(
            DeterministicStateInitAction {
                state_init,
                deposit: NearToken::from_near(5),
            },
        ))],
    )
    .await?;
    assert!(id.as_str().starts_with("0s") && id.as_str().len() == 42);
    assert!(worker.view_access_keys(&id).await?.is_empty(), "no key");
    let cfg: Value = worker.view(&id, "config").await?.json()?;
    let vault_id = keccak_native(&[id.as_bytes()]);
    assert_eq!(cfg["vault_id"], word_hex(&vault_id));
    assert_eq!(cfg["p1"], word_hex(&p1));

    let relayer = root
        .create_subaccount("relayer")
        .initial_balance(NearToken::from_near(100))
        .transact()
        .await?
        .into_result()?;
    let alice = root
        .create_subaccount("alice")
        .initial_balance(NearToken::from_near(50))
        .transact()
        .await?
        .into_result()?;
    let mut gas = Vec::new();
    let index = h20(&f["index"]);
    call(
        &relayer,
        &id,
        "register_index",
        json!({"index": word_hex(&index), "salt": f["salt"]}),
        ONE,
    )
    .await?
    .ok("register_index", &mut gas);

    // A checkpoint at block 26,092,387 of Ethereum mainnet, under a headers root P1 and P2 recorded.
    let (head, root_hash, range) = real_block(&real);
    for v in [p1, p2] {
        worker
            .patch_state(
                &id,
                &range_key(&v, &root_hash),
                &range_value(range.0, range.1),
            )
            .await?;
    }
    let number = real["number"].as_u64().unwrap();
    let checkpoint =
        json!({"block": number, "timestamp": real_time, "state_root": real["stateRoot"]});
    let proofs = json!({"proof1": b64(&head), "proof2": b64(&head)});
    call(
        &relayer,
        &id,
        "advance_checkpoint",
        json!({"checkpoint": checkpoint, "proofs": proofs}),
        0,
    )
    .await?
    .ok("advance_checkpoint", &mut gas);

    // A message claimed in a real receipt of that block that holds another log: the receipt's proof walks the real
    // trie to tx 130's receipt, and its log is not the message.
    let case = real["cases"]
        .as_array()
        .unwrap()
        .iter()
        .max_by_key(|c| c["txIndex"].as_u64().unwrap())
        .unwrap();
    let event = [
        head.clone(),
        receipt_part(
            &nodes(&case["proof"]),
            case["txIndex"].as_u64().unwrap(),
            case["logIndex"].as_u64().unwrap(),
        ),
    ]
    .concat();
    let burn = message(
        SEPOLIA,
        BURN,
        &index,
        &burn_body(ONE, &[0x42; 32]),
        1,
        NEAR_TESTNET,
        &vault_id,
    );
    call(
        &relayer,
        &id,
        "deliver",
        json!({"payload": b64(&burn), "block": number, "proof1": b64(&event), "proof2": b64(&event)}),
        ONE,
    )
    .await?
    .fails("NotTheLog", "deliver (real receipt, tx 130, refused)", &mut gas);

    // A recent checkpoint, then a deposit, its settlement and two burns.
    let now = worker.view_block().await?.timestamp() / 1_000_000_000;
    let block = number + 100;
    let (head, root_hash) = header(block, now, &[0x77; 32], &[9; 32]);
    for v in [p1, p2] {
        worker
            .patch_state(&id, &range_key(&v, &root_hash), &range_value(block, block))
            .await?;
    }
    let checkpoint = json!({"block": block, "timestamp": now, "state_root": word_hex(&[0x77; 32])});
    let proofs = json!({"proof1": b64(&head), "proof2": b64(&head)});
    call(
        &relayer,
        &id,
        "advance_checkpoint",
        json!({"checkpoint": checkpoint, "proofs": proofs}),
        0,
    )
    .await?
    .ok("advance_checkpoint (no stall)", &mut gas);
    let stalled: bool = worker.view(&id, "stalled").await?.json()?;
    assert!(!stalled);

    let intake = intake_id(now + 3_600, 1);
    call(
        &alice,
        &id,
        "deposit",
        json!({"index": word_hex(&index), "intake_id": word_hex(&intake), "amount": U128(10 * ONE)}),
        11 * ONE,
    )
    .await?
    .ok("deposit", &mut gas);
    let mut nonce = 1;
    let mut deliver = |kind: u8, body: Vec<u8>| {
        nonce += 1;
        let payload = message(SEPOLIA, kind, &index, &body, nonce, NEAR_TESTNET, &vault_id);
        let (proof, root) = event_proof(&index, &payload, block - nonce, now);
        (payload, proof, root, block - nonce)
    };
    let run = |payload: Vec<u8>, proof: Vec<u8>, at: u64| {
        let relayer = relayer.clone();
        let id = id.clone();
        async move {
            call(
                &relayer,
                &id,
                "deliver",
                json!({"payload": b64(&payload), "block": at, "proof1": b64(&proof), "proof2": b64(&proof)}),
                ONE,
            )
            .await
        }
    };
    let settle = deliver(INTAKE_SETTLED, intake.to_vec());
    for v in [p1, p2] {
        worker
            .patch_state(
                &id,
                &range_key(&v, &settle.2),
                &range_value(settle.3, settle.3),
            )
            .await?;
    }
    run(settle.0, settle.1, settle.3)
        .await?
        .ok("deliver (intake settled)", &mut gas);

    // The digests the hub reads, vouched for by `attest`: its return value states the block it ran in, and it logs
    // nothing.
    let slots = [index_slot(&index), intake_slot(&index, &intake)];
    let mut values = Vec::new();
    for s in &slots {
        let v: String = worker
            .view(&id, "slot")
            .args_json(json!({"slot": word_hex(s)}))
            .await?
            .json()?;
        values.push(<[u8; 32]>::try_from(hex(&v)).unwrap());
    }
    assert!(values.iter().all(|v| *v != [0u8; 32]));
    let attest = call(
        &relayer,
        &id,
        "attest",
        json!({"slots": slots.map(|s| word_hex(&s)), "values": values.iter().map(|v| word_hex(v)).collect::<Vec<_>>()}),
        0,
    )
    .await?
    .ok("attest (two slots)", &mut gas);
    let ran_in = worker.view_block().block_hash(attest.block).await?;
    assert_eq!(
        attest.value,
        attest_record(
            NEAR_TESTNET,
            &vault_id,
            ran_in.height(),
            ran_in.timestamp(),
            &slots,
            &values
        ),
        "abi.encode(ATTEST_DOMAIN, chainId, vaultId, height, timestampNs, slots, values)"
    );
    assert!(attest.logs.is_empty(), "attest logs nothing");
    call(
        &relayer,
        &id,
        "attest",
        json!({"slots": [word_hex(&slots[0])], "values": [word_hex(&[1; 32])]}),
        0,
    )
    .await?
    .fails("NotAttested", "", &mut gas);

    // Burns to accounts that do not exist yet: an ETH-implicit one (top 12 bytes zero) and an ed25519 one.
    let eth = [&[0u8; 12][..], &[0xe7; 20]].concat();
    let eth: [u8; 32] = eth.try_into().unwrap();
    let ed = [0x5d; 32];
    for (recipient, amount, name) in [
        (eth, ONE / 2, "deliver (burn, ETH-implicit, paid)"),
        (ed, ONE / 4, "deliver (burn, ed25519 implicit, paid)"),
    ] {
        let b = deliver(BURN, burn_body(amount, &recipient));
        for v in [p1, p2] {
            worker
                .patch_state(&id, &range_key(&v, &b.2), &range_value(b.3, b.3))
                .await?;
        }
        run(b.0, b.1, b.3).await?.ok(name, &mut gas);
    }
    assert_eq!(
        balance(&worker, &format!("0x{}", hex_str(&[0xe7; 20]))).await?,
        ONE / 2
    );
    assert_eq!(balance(&worker, &hex_str(&ed)).await?, ONE / 4);

    // A payout's callback is the vault's own.
    call(
        &alice,
        &id,
        "on_payout",
        json!({"index": word_hex(&index), "id": word_hex(&[1; 32]), "amount": U128(ONE)}),
        0,
    )
    .await?
    .fails("Method on_payout is private", "", &mut gas);

    // P1's light client takes SP1's own Groth16 proof through the chain's alt_bn128 host functions, and refuses its
    // public values as no statement of ours; P2's likewise RISC Zero's v3.0 receipt.
    let (_, values, proof) = sp1_fixture();
    call(
        &relayer,
        &id,
        "update_verifier",
        json!({"id": word_hex(&p1), "public_values": b64(&values), "proof": b64(&proof)}),
        ONE,
    )
    .await?
    .fails(
        "BadPublicValues",
        "update_verifier (SP1 Groth16 checked, refused)",
        &mut gas,
    );
    let (_, journal, seal) = risc0_receipt();
    call(
        &relayer,
        &id,
        "update_verifier",
        json!({"id": word_hex(&p2), "public_values": b64(&journal), "proof": b64(&seal)}),
        ONE,
    )
    .await?
    .fails(
        "BadPublicValues",
        "update_verifier (RISC Zero Groth16 checked, refused)",
        &mut gas,
    );
    report("gas, deterministic vault:", &gas);
    Ok(())
}

/// The snapshot exit on Wasm: the vault at `vault.test.near`, whose id the fixture hub's chain registry names, brought
/// by its own code to the snapshot of the hub's last block (in the mocked runtime, where the clock can pass 180 days),
/// that storage patched into the sandbox account, and the account's key deleted. Then an intake resolved, a refund, a
/// burn in flight paid from the hub's record, and both holders' claims, each read through a real storage proof.
#[tokio::test]
async fn the_snapshot_exit_on_wasm() -> anyhow::Result<()> {
    let worker = near_workspaces::sandbox().await?;
    let root = worker.root_account()?;
    let wasm = std::fs::read(WASM)?;
    let f = hub();
    let index = h20(&f["index"]);
    let amount = |name: &str| -> u128 { f[name]["amount"].as_str().unwrap().parse().unwrap() };

    // The state, by the vault's own methods.
    let vault: near_sdk::AccountId = "vault.test.near".parse()?;
    let at = |now: u64, who: &str, deposit: u128| {
        testing_env!(VMContextBuilder::new()
            .current_account_id(vault.clone())
            .predecessor_account_id(who.parse().unwrap())
            .signer_account_id(who.parse().unwrap())
            .block_timestamp(now * 1_000_000_000)
            .attached_deposit(near_sdk::NearToken::from_yoctonear(deposit))
            .prepaid_gas(near_sdk::Gas::from_tgas(1000))
            .build());
    };
    let start = f["settled_intake"]["deadline"].as_u64().unwrap() - 600;
    let timestamp = f["timestamp"].as_u64().unwrap();
    at(start, "relayer.test.near", 0);
    let config = config(&f, start);
    let (p1, p2) = (verifier_id(&config.p1), verifier_id(&config.p2));
    let mut v = Vault::build(config, start);
    at(start, "relayer.test.near", ONE);
    v.register_index(Hex20(index), Hex32(h32(&f["salt"])));
    // A first checkpoint, which deposits wait for (B1-04).
    let first = [0x77; 32];
    let (head, headers) = header(1, start + 1, &first, &[9; 32]);
    for id in [p1, p2] {
        near_sdk::env::storage_write(&range_key(&id, &headers), &range_value(1, 1));
    }
    at(start + 1, "relayer.test.near", 0);
    v.advance_checkpoint(
        Checkpoint {
            block: 1,
            timestamp: start + 1,
            state_root: Hex32(first),
        },
        PairProofs {
            proof1: b64(&head),
            proof2: b64(&head),
        },
    );
    at(start + 1, "alice.test.near", 31 * ONE);
    let settled = h32(&f["settled_intake"]["id"]);
    v.deposit(Hex20(index), Hex32(settled), U128(amount("settled_intake")));
    at(timestamp + 60, "bob.test.near", 4 * ONE);
    let open = h32(&f["open_intake"]["id"]);
    v.deposit(Hex20(index), Hex32(open), U128(amount("open_intake")));
    let state_root = h32(&f["state_root"]);
    let block = f["block"].as_u64().unwrap();
    let (head, headers) = header(block, timestamp, &state_root, &[9; 32]);
    for id in [p1, p2] {
        near_sdk::env::storage_write(&range_key(&id, &headers), &range_value(block, block));
    }
    at(timestamp + 120, "relayer.test.near", 0);
    v.advance_checkpoint(
        Checkpoint {
            block,
            timestamp,
            state_root: Hex32(state_root),
        },
        PairProofs {
            proof1: b64(&head),
            proof2: b64(&head),
        },
    );
    // Whoever begins the snapshot pays its slot's storage (B2-04).
    at(
        v.stall_start() + SNAPSHOT_EXIT_DELAY as u64,
        "relayer.test.near",
        ONE,
    );
    v.begin_snapshot();
    let state = near_sdk::borsh::to_vec(&v)?;
    drop(v);
    let mut storage = near_sdk::mock::with_mocked_blockchain(|b| b.take_storage());
    storage.insert(b"STATE".to_vec(), state);

    // The account: the code, that storage, and no key.
    let account = root
        .create_subaccount("vault")
        .initial_balance(NearToken::from_near(60))
        .transact()
        .await?
        .into_result()?;
    let id = account.id().clone();
    account.deploy(&wasm).await?.into_result()?;
    for (k, v) in &storage {
        worker.patch_state(&id, k, v).await?;
    }
    account
        .batch(&id)
        .delete_key(account.secret_key().public_key())
        .transact()
        .await?
        .into_result()?;
    assert!(worker.view_access_keys(&id).await?.is_empty());
    let cfg: Value = worker.view(&id, "config").await?.json()?;
    assert_eq!(
        cfg["snapshot"]["state_root"],
        f["state_root"].as_str().unwrap().to_lowercase()
    );
    assert_eq!(cfg["vault_id"], f["vault"]);

    let relayer = root
        .create_subaccount("relayer")
        .initial_balance(NearToken::from_near(20))
        .transact()
        .await?
        .into_result()?;
    let bob = root
        .create_subaccount("bob")
        .initial_balance(NearToken::from_near(5))
        .transact()
        .await?
        .into_result()?;
    let mut gas = Vec::new();
    let proof = |name: &str| b64(&hex(f[name]["proof"]["proof"].as_str().unwrap()));
    call(
        &relayer,
        &id,
        "resolve_intake",
        json!({"index": word_hex(&index), "intake_id": word_hex(&settled), "proof": proof("settled_intake")}),
        0,
    )
    .await?
    .ok("resolve_intake (settled)", &mut gas);
    call(
        &relayer,
        &id,
        "resolve_intake",
        json!({"index": word_hex(&index), "intake_id": word_hex(&open), "proof": proof("open_intake")}),
        0,
    )
    .await?
    .ok("resolve_intake (failed)", &mut gas);
    // The refund leaves the vault's account and reaches the depositor's, less Bob's fees: the gas Bob prepaid and did not
    // burn comes back in a refund receipt of its own, a few blocks after this transaction's result.
    let (bob_before, vault_before) = (
        balance(&worker, bob.id().as_str()).await?,
        balance(&worker, id.as_str()).await?,
    );
    let r = bob
        .call(&id, "refund")
        .args_json(json!({"index": word_hex(&index), "intake_id": word_hex(&open)}))
        .gas(Gas::from_tgas(30))
        .transact()
        .await?;
    Outcome::of(r, &id).ok("refund", &mut gas);
    worker.fast_forward(5).await?;
    let left = vault_before - balance(&worker, id.as_str()).await?;
    assert!(left > 3 * ONE - ONE / 1000 && left <= 3 * ONE, "{left}");
    let arrived = balance(&worker, bob.id().as_str()).await? - bob_before;
    assert!(
        arrived > 3 * ONE - ONE / 100 && arrived < 3 * ONE,
        "{arrived}"
    );
    let deposited: U128 = worker
        .view(&id, "deposited")
        .args_json(
            json!({"index": word_hex(&index), "intake_id": word_hex(&open), "depositor": bob.id()}),
        )
        .await?
        .json()?;
    assert_eq!(deposited.0, 0);

    // The burn in flight: 3 NEAR, of which 4% of the 30 NEAR leaves today, to the implicit account it names.
    call(
        &relayer,
        &id,
        "deliver_recorded",
        json!({"payload": b64(&hex(f["burn"]["payload"].as_str().unwrap())), "proof": proof("burn")}),
        ONE,
    )
    .await?
    .ok("deliver_recorded (burn, paid)", &mut gas);
    let recipient = hex_str(&h32(&f["burn"]["recipient"]));
    assert_eq!(balance(&worker, &recipient).await?, 30 * ONE * 4 / 100);

    // The migration in flight names the index's second version: refused until that version registers here (a refusal
    // on chain keeps no used mark), then run, with nothing left of today's limit to move.
    let migrate = json!({"payload": b64(&hex(f["migrate"]["payload"].as_str().unwrap())), "proof": proof("migrate")});
    call(&relayer, &id, "deliver_recorded", migrate.clone(), ONE)
        .await?
        .fails("NotAnIndex", "", &mut gas);
    call(
        &relayer,
        &id,
        "register_index",
        json!({"index": f["migrate"]["new_index"], "salt": f["migrate"]["new_salt"]}),
        ONE,
    )
    .await?
    .ok("register_index (second version)", &mut gas);
    call(&relayer, &id, "deliver_recorded", migrate, ONE)
        .await?
        .ok("deliver_recorded (migration, owed)", &mut gas);
    let owed: Value = worker
        .view(&id, "owed")
        .args_json(json!({"index": word_hex(&index), "id": f["migrate"]["id"]}))
        .await?
        .json()?;
    assert_eq!(owed["remaining"], (3 * ONE).to_string());

    // Holder A by its signature, holder B to its recovery address.
    let claim = |holder: &str, component: usize, signature: &str| {
        json!({
            "index": word_hex(&index),
            "holder": f[holder]["address"],
            "component": component,
            "recipient": f[holder]["recipient"],
            "signature": b64(&hex(signature)),
            "proof": b64(&hex(f[holder]["claims"][component]["proof"].as_str().unwrap())),
        })
    };
    call(
        &relayer,
        &id,
        "claim_snapshot",
        claim("holder_a", 1, f["holder_a"]["signature"].as_str().unwrap()),
        ONE,
    )
    .await?
    .ok("claim_snapshot (signature)", &mut gas);
    call(
        &relayer,
        &id,
        "claim_snapshot",
        claim("holder_b", 1, ""),
        ONE,
    )
    .await?
    .ok("claim_snapshot (recovery address)", &mut gas);
    call(
        &relayer,
        &id,
        "claim_snapshot",
        claim("holder_b", 1, ""),
        ONE,
    )
    .await?
    .fails("AlreadyClaimed", "", &mut gas);
    report("gas, snapshot exit:", &gas);
    Ok(())
}
