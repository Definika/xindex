//! P1 and P2 on Stellar, their built Wasm on the real host: each system's own Groth16 proof (SP1 v6's fixture, RISC
//! Zero's v3.0 receipt), the lag rule (LG-4), real mainnet receipts (`test/fixtures/ethereum/receipts.json`), receipts of
//! any shape Ethereum accepts (LG-1), checkpoints, and the vault calling both. Every call runs under mainnet's
//! invocation limits, and each test reports the instructions it took against the 400M a transaction may use.

mod common;

use common::*;
use serde_json::Value;
use soroban_sdk::testutils::Ledger;
use soroban_sdk::{contractclient, Address, Bytes, BytesN, Env};
use xindex_core::constants::*;
use xindex_core::crypto::Crypto;
use xindex_core::event::word;
use xindex_soroban::light_client::{Key, Range, State, VerifierError};

#[contractclient(name = "VerifierClient")]
#[allow(dead_code)]
trait Verifier {
    fn update(env: Env, public_values: Bytes, proof: Bytes);
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
    fn check_proof(env: Env, key: BytesN<32>, proof: Bytes, public_values: Bytes);
    fn state(env: Env) -> State;
    fn lag_ends(env: Env) -> u64;
    fn range(env: Env, headers_root: BytesN<32>) -> Option<Range>;
}

const GENESIS: u64 = 1_606_824_023;
const EPOCH: u64 = 479_000;

/// A proof system's own valid proof: the key, the values, the proof.
type Fixture = ([u8; 32], std::vec::Vec<u8>, std::vec::Vec<u8>);

/// A proof system's Wasm and its fixture.
struct System {
    name: &'static str,
    wasm: &'static str,
    fixture: fn() -> Fixture,
}

const SYSTEMS: [System; 2] = [
    System {
        name: "P1",
        wasm: "p1_verifier",
        fixture: sp1_fixture,
    },
    System {
        name: "P2",
        wasm: "p2_verifier",
        fixture: risc0_receipt,
    },
];

/// SP1 v6's own Groth16 fixture (`prototype/evm/test/SP1VerifierGroth16V6.t.sol`).
fn sp1_fixture() -> Fixture {
    let t = repo_file("prototype/evm/test/SP1VerifierGroth16V6.t.sol");
    let grab = |name: &str| -> String {
        let rest = &t[t.find(name).unwrap()..];
        let start = rest.find(['"', '(']).unwrap() + 1;
        let start = if rest[start..].starts_with("0x") {
            start + 2
        } else {
            start
        };
        let end = start + rest[start..].find(['"', ')']).unwrap();
        rest[start..end].to_string()
    };
    (
        hex(&grab("PROGRAM_VKEY =")).try_into().unwrap(),
        hex(&grab("PUBLIC_VALUES =")),
        hex(&grab("PROOF_BYTES =")),
    )
}

/// RISC Zero's own v3.0 receipt (`vendor/risc0-ethereum/test/TestReceiptV3_0.sol`): image id, journal, seal.
fn risc0_receipt() -> Fixture {
    let t = repo_file("vendor/risc0-ethereum/test/TestReceiptV3_0.sol");
    let grab = |name: &str| -> std::vec::Vec<u8> {
        let rest = &t[t.find(name).unwrap()..];
        let start = rest.find("hex\"").unwrap() + 4;
        let end = start + rest[start..].find('"').unwrap();
        hex(&rest[start..end])
    };
    (
        grab("IMAGE_ID =").try_into().unwrap(),
        grab("JOURNAL ="),
        grab("SEAL ="),
    )
}

fn host() -> Env {
    let env = new_env();
    env.mock_all_auths();
    env.ledger().with_mut(|l| {
        l.timestamp = GENESIS + EPOCH * 384;
        l.min_persistent_entry_ttl = 4096;
        l.max_entry_ttl = 6_312_000;
    });
    env
}

fn deploy(env: &Env, s: &System, key: [u8; 32]) -> Address {
    env.register(
        wasm(s.wasm).as_slice(),
        (
            b32(env, &key),
            b32(env, &C.keccak256(&[b"the deployer's anchor"])),
            EPOCH,
            GENESIS,
        ),
    )
}

fn verifier_err(e: VerifierError) -> soroban_sdk::Error {
    soroban_sdk::Error::from_contract_error(e as u32)
}

/// Each system's own proof verifies on Stellar through the very code P1 and P2 run, and a changed proof, key or input is
/// refused.
#[test]
fn check_proof_verifies_each_systems_own_proof() {
    for s in &SYSTEMS {
        let env = host();
        let (key, values, proof) = (s.fixture)();
        let v = deploy(&env, s, key);
        let c = VerifierClient::new(&env, &v);
        c.check_proof(
            &b32(&env, &key),
            &bytes(&env, &proof),
            &bytes(&env, &values),
        );
        println!(
            "{}: check_proof, {} instructions",
            s.name,
            instructions(&env)
        );
        let mut wrong = values.clone();
        wrong[0] ^= 1;
        assert_eq!(
            c.try_check_proof(&b32(&env, &key), &bytes(&env, &proof), &bytes(&env, &wrong)),
            Err(Ok(verifier_err(VerifierError::InvalidProof)))
        );
        let mut other = key;
        other[31] ^= 1;
        assert!(c
            .try_check_proof(
                &b32(&env, &other),
                &bytes(&env, &proof),
                &bytes(&env, &values)
            )
            .is_err());
        let mut bad = proof.clone();
        bad[0] ^= 1;
        assert!(c
            .try_check_proof(&b32(&env, &key), &bytes(&env, &bad), &bytes(&env, &values))
            .is_err());
    }
}

/// The constructor takes a key, an anchor and the genesis time once, at deployment: none may be zero.
#[test]
fn the_constructor_fixes_the_verifier() {
    for s in &SYSTEMS {
        let env = host();
        let v = deploy(&env, s, [7; 32]);
        let st = VerifierClient::new(&env, &v).state();
        assert_eq!(
            (st.key.to_array(), st.epoch, st.genesis_time),
            ([7; 32], EPOCH, GENESIS)
        );
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            env.register(
                wasm(s.wasm).as_slice(),
                (b32(&env, &[0; 32]), b32(&env, &[1; 32]), EPOCH, GENESIS),
            )
        }));
        assert!(r.is_err());
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            env.register(
                wasm(s.wasm).as_slice(),
                (b32(&env, &[7; 32]), b32(&env, &[1; 32]), EPOCH, 0u64),
            )
        }));
        assert!(r.is_err());
    }
}

/// LG-4's twin on Stellar: a verifier takes a proof only until a day after its anchor's epoch began, checked before the
/// proof, so one left behind stops for good. At the bound a bad proof reaches the proof's check; one second past it is
/// refused for its lag alone.
#[test]
fn test_lg4_an_update_comes_at_most_a_day_after_its_anchor() {
    for s in &SYSTEMS {
        let env = host();
        let v = deploy(&env, s, [7; 32]);
        let c = VerifierClient::new(&env, &v);
        let ends = GENESIS + EPOCH * 384 + 86_400;
        assert_eq!(c.lag_ends(), ends);
        let values = Bytes::from_array(&env, &[0u8; 192]);
        let proof = Bytes::from_array(&env, &[0u8; 260]);
        env.ledger().with_mut(|l| l.timestamp = ends);
        assert_eq!(
            c.try_update(&values, &proof),
            Err(Ok(verifier_err(VerifierError::InvalidProof)))
        );
        env.ledger().with_mut(|l| l.timestamp = ends + 1);
        assert_eq!(
            c.try_update(&values, &proof),
            Err(Ok(verifier_err(VerifierError::Lagging)))
        );
    }
}

/// Records the range a proof over blocks `first` to `last` with `root` would have.
fn record_range(env: &Env, v: &Address, root: &[u8; 32], first: u64, last: u64) {
    env.as_contract(v, || {
        env.storage()
            .persistent()
            .set(&Key::Range(b32(env, root)), &Range { first, last });
    });
}

fn leaf(n: u64, t: u64, s: &[u8; 32], r: &[u8; 32]) -> [u8; 32] {
    C.keccak256(&[&word(n), &word(t), s, r])
}

/// The real block, its leaf alone a headers root, and its first case's event proof.
struct Real {
    f: Value,
    number: u64,
    timestamp: u64,
    state_root: [u8; 32],
    receipts_root: [u8; 32],
}

impl Real {
    fn load() -> Self {
        let f = json("test/fixtures/ethereum/receipts.json");
        Real {
            number: f["number"].as_u64().unwrap(),
            timestamp: f["timestamp"].as_u64().unwrap(),
            state_root: h32(&f["stateRoot"]),
            receipts_root: h32(&f["receiptsRoot"]),
            f,
        }
    }

    fn root(&self) -> [u8; 32] {
        leaf(
            self.number,
            self.timestamp,
            &self.state_root,
            &self.receipts_root,
        )
    }

    fn header(&self) -> std::vec::Vec<u8> {
        let mut out = [
            &self.root()[..],
            &self.number.to_le_bytes(),
            &self.timestamp.to_le_bytes(),
            &self.state_root,
            &self.receipts_root,
        ]
        .concat();
        out.push(0);
        out
    }

    fn event(&self, case: usize) -> std::vec::Vec<u8> {
        let c = &self.f["cases"][case];
        let nodes: std::vec::Vec<std::vec::Vec<u8>> = c["proof"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| hex(n.as_str().unwrap()))
            .collect();
        let mut out = self.header();
        out.push(nodes.len() as u8);
        for n in &nodes {
            out.extend_from_slice(&(n.len() as u32).to_le_bytes());
            out.extend_from_slice(n);
        }
        out.extend_from_slice(&(c["txIndex"].as_u64().unwrap() as u32).to_le_bytes());
        out.extend_from_slice(&(c["logIndex"].as_u64().unwrap() as u32).to_le_bytes());
        out
    }
}

/// Every real receipt of the fixture proves its log through both verifiers, and nothing but that log: another emitter,
/// topic, data or block is refused.
#[test]
fn verify_event_reads_real_receipts() {
    let r = Real::load();
    for s in &SYSTEMS {
        let env = host();
        let v = deploy(&env, s, [7; 32]);
        record_range(&env, &v, &r.root(), r.number, r.number);
        let c = VerifierClient::new(&env, &v);
        for (i, case) in r.f["cases"].as_array().unwrap().iter().enumerate() {
            let data = hex(case["data"].as_str().unwrap());
            let proof = bytes(&env, &r.event(i));
            let call = |block: u64, emitter: [u8; 20], data_hash: [u8; 32]| {
                c.try_verify_event(
                    &block,
                    &b20(&env, &emitter),
                    &b32(&env, &h32(&case["topic0"])),
                    &b32(&env, &h32(&case["topic1"])),
                    &b32(&env, &data_hash),
                    &proof,
                )
            };
            let emitter = h20(&case["emitter"]);
            let data_hash = C.keccak256(&[&data]);
            call(r.number, emitter, data_hash).unwrap().unwrap();
            println!(
                "{}: verify_event, real receipt {i} ({} proof bytes), {} instructions",
                s.name,
                proof.len(),
                instructions(&env)
            );
            assert_eq!(
                call(r.number, [9; 20], data_hash),
                Err(Ok(verifier_err(VerifierError::NotTheLog)))
            );
            assert_eq!(
                call(r.number, emitter, [9; 32]),
                Err(Ok(verifier_err(VerifierError::NotTheLog)))
            );
            assert!(call(r.number + 1, emitter, data_hash).is_err());
        }
    }
}

/// A checkpoint is proven from its header under a recorded range; another time, root or number is refused.
#[test]
fn verify_checkpoint_attests_a_covered_block_and_nothing_else() {
    let r = Real::load();
    for s in &SYSTEMS {
        let env = host();
        let v = deploy(&env, s, [7; 32]);
        let c = VerifierClient::new(&env, &v);
        let proof = bytes(&env, &r.header());
        assert_eq!(
            c.try_verify_checkpoint(&r.number, &r.timestamp, &b32(&env, &r.state_root), &proof),
            Err(Ok(verifier_err(VerifierError::UnknownHeaders)))
        );
        record_range(&env, &v, &r.root(), r.number, r.number);
        c.verify_checkpoint(&r.number, &r.timestamp, &b32(&env, &r.state_root), &proof);
        println!(
            "{}: verify_checkpoint, {} instructions",
            s.name,
            instructions(&env)
        );
        for (n, t, root) in [
            (r.number + 1, r.timestamp, r.state_root),
            (r.number, r.timestamp + 1, r.state_root),
            (r.number, r.timestamp, [9u8; 32]),
        ] {
            assert!(c
                .try_verify_checkpoint(&n, &t, &b32(&env, &root), &proof)
                .is_err());
        }
    }
}

// ---------------------------------------------------------------------
// LG-1: receipts of any shape Ethereum accepts
// ---------------------------------------------------------------------

fn rlp_str(b: &[u8]) -> std::vec::Vec<u8> {
    if b.len() == 1 && b[0] < 0x80 {
        return b.to_vec();
    }
    [rlp_prefix(0x80, b.len()), b.to_vec()].concat()
}

fn rlp_list(items: &[std::vec::Vec<u8>]) -> std::vec::Vec<u8> {
    let body = items.concat();
    [rlp_prefix(0xc0, body.len()), body].concat()
}

fn rlp_prefix(base: u8, len: usize) -> std::vec::Vec<u8> {
    if len < 56 {
        return vec![base + len as u8];
    }
    let be = (len as u64).to_be_bytes();
    let n = &be[be.iter().take_while(|b| **b == 0).count()..];
    [vec![base + 55 + n.len() as u8], n.to_vec()].concat()
}

const EMITTER: [u8; 20] = [0xab; 20];
const TOPIC0: [u8; 32] = [0x11; 32];
const TOPIC1: [u8; 32] = [0x22; 32];
const DATA: [u8; 96] = [0x33; 96];

/// A successful typed receipt as a contract wrapping a permissionless hub call shapes it: `before` empty logs, the vault
/// message's log, then one log carrying `junk` bytes of data if `junk` is not zero (the Solana verifier's test's).
fn shaped_receipt(before: usize, junk: usize) -> std::vec::Vec<u8> {
    let empty = rlp_list(&[rlp_str(&[0xee; 20]), rlp_list(&[]), rlp_str(&[])]);
    let mut logs = vec![empty; before];
    logs.push(rlp_list(&[
        rlp_str(&EMITTER),
        rlp_list(&[rlp_str(&TOPIC0), rlp_str(&TOPIC1)]),
        rlp_str(&DATA),
    ]));
    if junk > 0 {
        logs.push(rlp_list(&[
            rlp_str(&[0xee; 20]),
            rlp_list(&[]),
            rlp_str(&vec![0u8; junk]),
        ]));
    }
    let body = rlp_list(&[
        rlp_str(&[1]),
        rlp_str(&[0x01, 0x00, 0x00]),
        rlp_str(&[0u8; 256]),
        rlp_list(&logs),
    ]);
    [vec![0x02], body].concat()
}

/// Verifies the message's log in `receipt`, transaction 0 of a one-block range: its instructions, or the error.
fn verify_shaped(
    env: &Env,
    v: &Address,
    receipt: &[u8],
    log_index: u32,
) -> Result<u64, soroban_sdk::Error> {
    let node = rlp_list(&[rlp_str(&[0x20, 0x80]), rlp_str(receipt)]);
    let receipts_root = C.keccak256(&[&node]);
    let (number, timestamp, state_root) = (100u64, 1_700_000_000u64, [0x44u8; 32]);
    let root = leaf(number, timestamp, &state_root, &receipts_root);
    let mut proof = [
        &root[..],
        &number.to_le_bytes(),
        &timestamp.to_le_bytes(),
        &state_root,
        &receipts_root,
    ]
    .concat();
    proof.extend_from_slice(&[0, 1]);
    proof.extend_from_slice(&(node.len() as u32).to_le_bytes());
    proof.extend_from_slice(&node);
    proof.extend_from_slice(&0u32.to_le_bytes());
    proof.extend_from_slice(&log_index.to_le_bytes());
    record_range(env, v, &root, number, number);
    let r = VerifierClient::new(env, v).try_verify_event(
        &number,
        &b20(env, &EMITTER),
        &b32(env, &TOPIC0),
        &b32(env, &TOPIC1),
        &b32(env, &C.keccak256(&[&DATA])),
        &bytes(env, &proof),
    );
    match r {
        Ok(_) => Ok(instructions(env)),
        Err(Ok(e)) => Err(e),
        Err(Err(e)) => panic!("{e:?}"),
    }
}

/// LG-1 on Stellar: a receipt of 513 logs, the message's last, verifies, and so does one of 2,001; the walk still stops
/// at the receipt's end. The verifiers read every list in place (`xindex_core::rlp`), as the Solana verifier's fix does.
#[test]
fn test_lg1_a_receipt_of_513_logs_verifies() {
    for s in &SYSTEMS {
        let env = host();
        let v = deploy(&env, s, [7; 32]);
        let n = verify_shaped(&env, &v, &shaped_receipt(512, 0), 512).expect("513 logs verify");
        println!("{}: 513 logs, {n} instructions", s.name);
        let n =
            verify_shaped(&env, &v, &shaped_receipt(2_000, 0), 2_000).expect("2,001 logs verify");
        println!("{}: 2,001 logs, {n} instructions", s.name);
        assert_eq!(
            verify_shaped(&env, &v, &shaped_receipt(512, 0), 513),
            Err(verifier_err(VerifierError::NoLog))
        );
    }
}

/// LG-1 on Stellar: a receipt leaf past 64 KB verifies; a Soroban transaction holds 132 KB.
#[test]
fn test_lg1_a_receipt_leaf_past_64kb_verifies() {
    for s in &SYSTEMS {
        let env = host();
        let v = deploy(&env, s, [7; 32]);
        let receipt = shaped_receipt(0, 70_000);
        assert!(receipt.len() > 65_535);
        let n = verify_shaped(&env, &v, &receipt, 0).expect("a 70 KB leaf verifies");
        println!(
            "{}: a {}-byte leaf, {n} instructions",
            s.name,
            receipt.len()
        );
    }
}

/// The vault against the real P1 and P2: its checkpoint call reaches both in the layout they read and takes a real
/// mainnet block's number, time and state root; and a message whose log the receipt does not hold is refused by the
/// verifiers themselves.
#[test]
fn the_vault_runs_on_the_real_verifiers() {
    let r = Real::load();
    let env = host();
    native_asset(&env);
    let p1 = deploy(&env, &SYSTEMS[0], [7; 32]);
    let p2 = deploy(&env, &SYSTEMS[1], [8; 32]);
    record_range(&env, &p1, &r.root(), r.number, r.number);
    record_range(&env, &p2, &r.root(), r.number, r.number);
    let freezer = funded(&env, "freezer");
    let recovery = env.register(MockMultisig, ());
    env.ledger().with_mut(|l| l.timestamp = r.timestamp - 3600);
    let vault = H::deploy_vault(&env, &p1, &p2, &freezer, &recovery, FACTORY, HUB);
    env.ledger().with_mut(|l| l.timestamp = r.timestamp + 60);
    let v = xindex_vault::XindexVaultClient::new(&env, &vault);
    let header = bytes(&env, &r.header());
    let good = xindex_vault::types::Checkpoint {
        block: r.number,
        timestamp: r.timestamp,
        state_root: b32(&env, &r.state_root),
    };
    let wrong = xindex_vault::types::Checkpoint {
        state_root: b32(&env, &[9; 32]),
        ..good.clone()
    };
    assert_eq!(
        v.try_advance_checkpoint(&wrong, &header, &header),
        Err(Ok(verifier_err(VerifierError::NotTheCheckpoint)))
    );
    v.advance_checkpoint(&good, &header, &header);
    println!(
        "vault: advance_checkpoint through P1 and P2, {} instructions",
        instructions(&env)
    );
    assert_eq!(v.config().checkpoint, good);

    let salt = C.keccak256(&[b"salt", &[1u8]]);
    let index = xindex_core::abi::predict_clone(&C, &HUB, &salt, &FACTORY);
    v.register_index(&b20(&env, &index), &b32(&env, &salt));
    let body = [[0u8; 32], u256(XLM), key_of("bob")].concat();
    let payload = payload_with(BURN, index, 1, &body);
    let event = bytes(&env, &r.event(0));
    assert_eq!(
        v.try_deliver(
            &bytes(&env, &payload),
            &r.number,
            &Some(event.clone()),
            &Some(event)
        ),
        Err(Ok(verifier_err(VerifierError::NotTheLog)))
    );
}
