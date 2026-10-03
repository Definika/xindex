//! P1's Solana program in LiteSVM, on real data: SP1 v6's own Groth16 fixture through `check_proof`, and three real
//! mainnet receipts (block 26,092,387, rebuilt and checked by `test/fixtures/ethereum/generate.py`) through
//! `verify_event`, inline and staged in a loader buffer, laid out as the vault's `verify` sends it. Each refusal is
//! reached by changing one thing. Build first: `cargo build-sbf --manifest-path programs/ethereum-verifier/Cargo.toml`.

use anchor_lang::solana_program::{
    bpf_loader_upgradeable,
    clock::Clock,
    instruction::{AccountMeta, Instruction},
    pubkey::Pubkey,
    system_program,
};
use ethereum_verifier::{
    keccak, VerifierError, CHECK_PROOF, INITIALIZE, RANGE_LEN, RANGE_SEED, STATE_LEN, STATE_SEED,
    UPDATE, VERIFY_EVENT,
};
use litesvm::LiteSVM;
use serde_json::Value;
use solana_account::Account;
use solana_keypair::Keypair;
use solana_message::{Message, VersionedMessage};
use solana_signer::Signer;
use solana_transaction::versioned::VersionedTransaction;

const SOL: u64 = 1_000_000_000;
/// Mainnet's beacon genesis time.
const GENESIS: u64 = 1_606_824_023;

struct H {
    svm: LiteSVM,
    id: Pubkey,
    authority: Keypair,
}

fn hex(s: &str) -> Vec<u8> {
    let s = s.trim_start_matches("0x");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn word(x: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&x.to_be_bytes());
    w
}

impl H {
    fn new() -> Self {
        let mut svm = LiteSVM::new();
        let program = include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../target/deploy/ethereum_verifier.so"
        ));
        let id = Pubkey::new_unique();
        svm.add_program(id, program).unwrap();
        let authority = Keypair::new();
        // LiteSVM loads a program with no upgrade authority; this one's is the test's deployer.
        let programdata =
            Pubkey::find_program_address(&[id.as_ref()], &bpf_loader_upgradeable::id()).0;
        let mut account = svm.get_account(&programdata).unwrap();
        account.data[12] = 1;
        account.data[13..45].copy_from_slice(authority.pubkey().as_ref());
        svm.set_account(programdata, account).unwrap();
        svm.airdrop(&authority.pubkey(), 10 * SOL).unwrap();
        H { svm, id, authority }
    }

    /// Sends `ixs` paid by the authority; the compute units used, or the error.
    fn send(&mut self, ixs: &[Instruction]) -> Result<u64, String> {
        self.svm.expire_blockhash();
        let payer = self.authority.insecure_clone();
        let msg =
            Message::new_with_blockhash(ixs, Some(&payer.pubkey()), &self.svm.latest_blockhash());
        let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), &[&payer]).unwrap();
        match self.svm.send_transaction(tx) {
            Ok(meta) => Ok(meta.compute_units_consumed),
            Err(f) => Err(format!("{:?} {:?}", f.err, f.meta.logs)),
        }
    }

    fn refused(&mut self, ixs: &[Instruction], e: VerifierError) {
        let want = format!("Custom({})", e as u32);
        match self.send(ixs) {
            Ok(_) => panic!("expected {want}, but it succeeded"),
            Err(got) => assert!(got.contains(&want), "expected {want}, got {got}"),
        }
    }

    fn ix(&self, data: Vec<u8>, accounts: Vec<AccountMeta>) -> Instruction {
        Instruction::new_with_bytes(self.id, &data, accounts)
    }

    fn state(&self) -> Pubkey {
        Pubkey::find_program_address(&[STATE_SEED], &self.id).0
    }

    fn programdata(&self) -> Pubkey {
        Pubkey::find_program_address(&[self.id.as_ref()], &bpf_loader_upgradeable::id()).0
    }

    fn initialize_ix(
        &self,
        by: &Pubkey,
        key: [u8; 32],
        anchor: [u8; 32],
        epoch: u64,
    ) -> Instruction {
        self.initialize_at(by, key, anchor, epoch, GENESIS)
    }

    fn initialize_at(
        &self,
        by: &Pubkey,
        key: [u8; 32],
        anchor: [u8; 32],
        epoch: u64,
        genesis: u64,
    ) -> Instruction {
        let data = [
            &[INITIALIZE][..],
            &key,
            &anchor,
            &epoch.to_le_bytes(),
            &genesis.to_le_bytes(),
        ]
        .concat();
        self.ix(
            data,
            vec![
                AccountMeta::new(self.state(), false),
                AccountMeta::new(*by, true),
                AccountMeta::new_readonly(system_program::id(), false),
                AccountMeta::new_readonly(self.programdata(), false),
            ],
        )
    }

    fn set_time(&mut self, unix_timestamp: i64) {
        let mut clock: Clock = self.svm.get_sysvar();
        clock.unix_timestamp = unix_timestamp;
        self.svm.set_sysvar(&clock);
    }

    /// The range account a proof over blocks `first` to `last` with `headers_root` would have recorded.
    fn record_range(&mut self, headers_root: &[u8; 32], first: u64, last: u64) -> Pubkey {
        let (key, bump) = Pubkey::find_program_address(&[RANGE_SEED, headers_root], &self.id);
        let data = [&first.to_le_bytes()[..], &last.to_le_bytes(), &[bump]].concat();
        assert_eq!(data.len(), RANGE_LEN);
        self.svm
            .set_account(
                key,
                Account {
                    lamports: SOL,
                    data,
                    owner: self.id,
                    executable: false,
                    rent_epoch: 0,
                },
            )
            .unwrap();
        key
    }
}

// ---------------------------------------------------------------------
// Groth16
// ---------------------------------------------------------------------

/// SP1 v6's own Groth16 fixture, from sp1-contracts' test (`prototype/evm/test/SP1VerifierGroth16V6.t.sol`).
fn sp1_fixture() -> ([u8; 32], Vec<u8>, Vec<u8>) {
    let t = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../prototype/evm/test/SP1VerifierGroth16V6.t.sol"
    ))
    .unwrap();
    let grab = |name: &str| -> Vec<u8> {
        let rest = &t[t.find(name).unwrap()..];
        let start = rest.find(['"', '(']).unwrap() + 1;
        let end = start + rest[start..].find(['"', ')']).unwrap();
        hex(&rest[start..end])
    };
    (
        grab("PROGRAM_VKEY =").try_into().unwrap(),
        grab("PUBLIC_VALUES ="),
        grab("PROOF_BYTES ="),
    )
}

#[test]
fn check_proof_verifies_sp1s_own_proof_on_chain() {
    let mut h = H::new();
    let (key, values, proof) = sp1_fixture();
    let data = [&[CHECK_PROOF][..], &key, &proof, &values].concat();
    let cu = h
        .send(&[h.ix(data, vec![])])
        .expect("SP1's own proof verifies");
    println!("compute units to verify an SP1 v6 Groth16 proof: {cu}");
    assert!(cu < 400_000, "{cu}");

    let mut tampered = values.clone();
    tampered[31] ^= 1;
    let data = [&[CHECK_PROOF][..], &key, &proof, &tampered].concat();
    h.refused(&[h.ix(data, vec![])], VerifierError::InvalidProof);
    let data = [&[CHECK_PROOF][..], &key, &proof[..100]].concat();
    h.refused(&[h.ix(data, vec![])], VerifierError::BadInstruction);
}

// ---------------------------------------------------------------------
// initialize and update
// ---------------------------------------------------------------------

#[test]
fn only_the_upgrade_authority_initializes_once() {
    let mut h = H::new();
    let stranger = Keypair::new();
    h.svm.airdrop(&stranger.pubkey(), SOL).unwrap();
    let ix = h.initialize_ix(&stranger.pubkey(), [1; 32], [2; 32], 7);
    h.svm.expire_blockhash();
    let msg =
        Message::new_with_blockhash(&[ix], Some(&stranger.pubkey()), &h.svm.latest_blockhash());
    let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), &[&stranger]).unwrap();
    let err = format!("{:?}", h.svm.send_transaction(tx).unwrap_err().err);
    assert!(
        err.contains(&format!(
            "Custom({})",
            VerifierError::NotUpgradeAuthority as u32
        )),
        "{err}"
    );

    let me = h.authority.pubkey();
    h.refused(
        &[h.initialize_ix(&me, [0; 32], [2; 32], 7)],
        VerifierError::BadInstruction,
    );
    h.refused(
        &[h.initialize_at(&me, [1; 32], [2; 32], 7, 0)],
        VerifierError::BadInstruction,
    );
    h.send(&[h.initialize_ix(&me, [1; 32], [2; 32], 7)])
        .unwrap();
    let state = h.svm.get_account(&h.state()).unwrap();
    assert_eq!(state.owner, h.id);
    assert_eq!(state.data.len(), STATE_LEN);
    assert_eq!(
        state.data,
        [
            &[1u8; 32][..],
            &[2u8; 32],
            &7u64.to_le_bytes(),
            &GENESIS.to_le_bytes()
        ]
        .concat()
    );
    h.refused(
        &[h.initialize_ix(&me, [3; 32], [4; 32], 8)],
        VerifierError::AlreadyInitialized,
    );
}

impl H {
    fn update_ix(&self, range: Pubkey, values: &[u8], proof: &[u8]) -> Instruction {
        self.ix(
            [&[UPDATE][..], values, proof].concat(),
            vec![
                AccountMeta::new(self.state(), false),
                AccountMeta::new(range, false),
                AccountMeta::new(self.authority.pubkey(), true),
                AccountMeta::new_readonly(system_program::id(), false),
            ],
        )
    }
}

#[test]
fn an_update_needs_a_valid_proof_of_the_program() {
    let mut h = H::new();
    let (key, _, proof) = sp1_fixture();
    let range = Pubkey::new_unique();
    let me = h.authority.pubkey();
    let values = vec![0x11u8; 192];
    h.refused(
        &[h.update_ix(range, &values, &proof)],
        VerifierError::WrongAccount,
    );
    h.send(&[h.initialize_ix(&me, key, [2; 32], 7)]).unwrap();
    h.set_time((GENESIS + 7 * 384) as i64);
    h.refused(
        &[h.update_ix(range, &values[..191], &proof)],
        VerifierError::BadInstruction,
    );
    // SP1's fixture is a proof of other values: refused, and nothing moves.
    h.refused(
        &[h.update_ix(range, &values, &proof)],
        VerifierError::InvalidProof,
    );
    assert_eq!(
        h.svm.get_account(&h.state()).unwrap().data[32..64],
        [2u8; 32]
    );
}

/// LG-4: the verifier takes a proof until a day after its anchor's epoch began, then stops for good, as
/// `FinalityVerifier.update` does. Before the bound an update reaches the proof's check (SP1's fixture proves other
/// values, so `InvalidProof`); a second past it, the update is refused before the proof is read.
#[test]
fn test_lg4_an_update_comes_at_most_a_day_after_its_anchor() {
    let mut h = H::new();
    let (key, _, proof) = sp1_fixture();
    let range = Pubkey::new_unique();
    let me = h.authority.pubkey();
    let epoch = 400_000u64;
    h.send(&[h.initialize_ix(&me, key, [2; 32], epoch)])
        .unwrap();
    let bound = (GENESIS + epoch * 384 + 86_400) as i64;
    let values = vec![0x11u8; 192];
    h.set_time(bound);
    h.refused(
        &[h.update_ix(range, &values, &proof)],
        VerifierError::InvalidProof,
    );
    h.set_time(bound + 1);
    h.refused(
        &[h.update_ix(range, &values, &proof)],
        VerifierError::Lagging,
    );
    // A year late is as late: no catching up through old checkpoints.
    h.set_time(bound + 365 * 86_400);
    h.refused(
        &[h.update_ix(range, &values, &proof)],
        VerifierError::Lagging,
    );
}

// ---------------------------------------------------------------------
// verify_event, on real receipts
// ---------------------------------------------------------------------

#[derive(Clone)]
struct Receipts {
    json: Value,
    number: u64,
    timestamp: u64,
    state_root: [u8; 32],
    receipts_root: [u8; 32],
}

fn receipts() -> Receipts {
    let json: Value = serde_json::from_str(
        &std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../test/fixtures/ethereum/receipts.json"
        ))
        .unwrap(),
    )
    .unwrap();
    let w = |k: &str| -> [u8; 32] { hex(json[k].as_str().unwrap()).try_into().unwrap() };
    Receipts {
        number: json["number"].as_u64().unwrap(),
        timestamp: json["timestamp"].as_u64().unwrap(),
        state_root: w("stateRoot"),
        receipts_root: w("receiptsRoot"),
        json,
    }
}

fn leaf(n: u64, t: u64, s: &[u8; 32], r: &[u8; 32]) -> [u8; 32] {
    keccak(&[&word(n), &word(t), s, r])
}

/// The tree a proof over five blocks around the real one commits to (it is the second), and the real one's path: as
/// `EthereumFinalityVerifier.t.sol` builds it.
fn headers(r: &Receipts) -> ([u8; 32], Vec<[u8; 32]>) {
    let mut layer: Vec<[u8; 32]> = (0..5u64)
        .map(|i| {
            let n = r.number - 1 + i;
            if n == r.number {
                leaf(n, r.timestamp, &r.state_root, &r.receipts_root)
            } else {
                leaf(
                    n,
                    r.timestamp,
                    &keccak(&[&word(n)]),
                    &keccak(&[&word(n), &word(1)]),
                )
            }
        })
        .collect();
    let (mut index, mut path) = (1usize, Vec::new());
    while layer.len() > 1 {
        path.push(layer.get(index ^ 1).copied().unwrap_or([0; 32]));
        layer = layer
            .chunks(2)
            .map(|p| keccak(&[&p[0], p.get(1).unwrap_or(&[0; 32])]))
            .collect();
        index /= 2;
    }
    (layer[0], path)
}

/// The event proof's bytes, as the relayer writes them, every field given so each test changes one.
#[allow(clippy::too_many_arguments)]
fn encode(
    root: &[u8; 32],
    number: u64,
    r: &Receipts,
    receipts_root: &[u8; 32],
    path: &[[u8; 32]],
    nodes: &[Vec<u8>],
    tx: u32,
    log: u32,
) -> Vec<u8> {
    let mut out = [
        &root[..],
        &number.to_le_bytes(),
        &r.timestamp.to_le_bytes(),
        &r.state_root,
        receipts_root,
    ]
    .concat();
    out.push(path.len() as u8);
    path.iter().for_each(|p| out.extend_from_slice(p));
    out.push(nodes.len() as u8);
    for n in nodes {
        out.extend_from_slice(&(n.len() as u32).to_le_bytes());
        out.extend_from_slice(n);
    }
    out.extend_from_slice(&tx.to_le_bytes());
    out.extend_from_slice(&log.to_le_bytes());
    out
}

fn nodes(r: &Receipts, at: &str) -> Vec<Vec<u8>> {
    r.json.pointer(at).unwrap()["proof"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| hex(n.as_str().unwrap()))
        .collect()
}

/// The vault's call (`xindex_vault::verify`): the log it claims, then the proof.
fn verify_ix(
    h: &H,
    block: u64,
    case: &Value,
    proof: &[u8],
    accounts: Vec<AccountMeta>,
) -> Instruction {
    let b = |k: &str| hex(case[k].as_str().unwrap());
    let data = [
        &[VERIFY_EVENT][..],
        &block.to_le_bytes(),
        &b("emitter"),
        &b("topic0"),
        &b("topic1"),
        &keccak(&[&b("data")]),
        proof,
    ]
    .concat();
    h.ix(data, accounts)
}

struct Event {
    h: H,
    r: Receipts,
    root: [u8; 32],
    path: Vec<[u8; 32]>,
    range: Pubkey,
}

fn event() -> Event {
    let mut h = H::new();
    let r = receipts();
    let (root, path) = headers(&r);
    let range = h.record_range(&root, r.number - 1, r.number + 3);
    Event {
        h,
        r,
        root,
        path,
        range,
    }
}

impl Event {
    fn proof(&self, case: &str) -> Vec<u8> {
        let c = self.r.json.pointer(case).unwrap();
        let tx = c["txIndex"].as_u64().unwrap() as u32;
        let log = c["logIndex"].as_u64().unwrap_or(0) as u32;
        encode(
            &self.root,
            self.r.number,
            &self.r,
            &self.r.receipts_root,
            &self.path,
            &nodes(&self.r, case),
            tx,
            log,
        )
    }
    fn ix(&self, case: &str, proof: &[u8]) -> Instruction {
        let c = self.r.json.pointer(case).unwrap();
        verify_ix(
            &self.h,
            self.r.number,
            c,
            proof,
            vec![AccountMeta::new_readonly(self.range, false)],
        )
    }
}

/// Three real receipts: a one-byte key, a two-byte key (index 130), and a legacy receipt with no type byte.
#[test]
fn verify_event_reads_real_receipts() {
    let mut e = event();
    for c in 0..3 {
        let case = format!("/cases/{c}");
        let proof = e.proof(&case);
        let ix = e.ix(&case, &proof);
        let cu =
            e.h.send(&[ix])
                .unwrap_or_else(|err| panic!("case {c}: {err}"));
        println!("case {c}: {} proof bytes, {cu} compute units", proof.len());
    }
}

/// A proof too long for a transaction, staged in a loader buffer, as the relayer stages one.
#[test]
fn verify_event_reads_a_staged_proof() {
    let mut e = event();
    let proof = e.proof("/cases/1");
    let buffer = Pubkey::new_unique();
    let mut data = vec![1, 0, 0, 0, 1];
    data.extend_from_slice(e.h.authority.pubkey().as_ref());
    data.extend_from_slice(&(proof.len() as u32).to_le_bytes());
    data.extend_from_slice(&proof);
    data.extend_from_slice(&[0u8; 100]);
    let account = Account {
        lamports: SOL,
        data,
        owner: bpf_loader_upgradeable::id(),
        executable: false,
        rent_epoch: 0,
    };
    e.h.svm.set_account(buffer, account.clone()).unwrap();
    let c = e.r.json.pointer("/cases/1").unwrap().clone();
    let accounts = vec![
        AccountMeta::new_readonly(e.range, false),
        AccountMeta::new_readonly(buffer, false),
    ];
    let ix = verify_ix(&e.h, e.r.number, &c, &[], accounts.clone());
    e.h.send(std::slice::from_ref(&ix))
        .expect("the staged proof verifies");

    // A buffer the loader does not own, or with no buffer tag, or one cut short, is refused.
    let mut foreign = account.clone();
    foreign.owner = Pubkey::new_unique();
    e.h.svm.set_account(buffer, foreign).unwrap();
    e.h.refused(std::slice::from_ref(&ix), VerifierError::WrongAccount);
    let mut untagged = account.clone();
    untagged.data[0] = 3;
    e.h.svm.set_account(buffer, untagged).unwrap();
    e.h.refused(std::slice::from_ref(&ix), VerifierError::WrongAccount);
    let mut short = account;
    short.data.truncate(37 + 4 + 10);
    e.h.svm.set_account(buffer, short).unwrap();
    e.h.refused(&[ix], VerifierError::BadEventProof);
    let no_buffer = verify_ix(
        &e.h,
        e.r.number,
        &c,
        &[],
        vec![AccountMeta::new_readonly(e.range, false)],
    );
    e.h.refused(&[no_buffer], VerifierError::WrongAccount);
}

#[test]
fn verify_event_proves_only_the_claimed_log() {
    let mut e = event();
    let proof = e.proof("/cases/0");
    let case = e.r.json.pointer("/cases/0").unwrap().clone();
    let range = vec![AccountMeta::new_readonly(e.range, false)];
    // The block, the emitter, a topic or the data claimed differently.
    let ix = verify_ix(&e.h, e.r.number + 1, &case, &proof, range.clone());
    e.h.refused(&[ix], VerifierError::NotTheLog);
    for field in ["emitter", "topic0", "topic1", "data"] {
        let mut other = case.clone();
        let mut b = hex(other[field].as_str().unwrap());
        let last = b.len() - 1;
        b[last] ^= 1;
        other[field] = Value::String(format!(
            "0x{}",
            b.iter().map(|x| format!("{x:02x}")).collect::<String>()
        ));
        let ix = verify_ix(&e.h, e.r.number, &other, &proof, range.clone());
        e.h.refused(&[ix], VerifierError::NotTheLog);
    }
    // Trailing bytes, and a log the vault's data cannot even hold.
    let ix = e.ix("/cases/0", &[&proof[..], &[0]].concat());
    e.h.refused(&[ix], VerifierError::BadEventProof);
    let short = e.h.ix(vec![VERIFY_EVENT; 50], range);
    e.h.refused(&[short], VerifierError::BadInstruction);
}

#[test]
fn verify_event_needs_a_recorded_range_and_the_blocks_place_in_it() {
    let mut e = event();
    let proof = e.proof("/cases/0");
    // Another account at the range's place, or a range of another headers root.
    let fake = Pubkey::new_unique();
    let mut account = e.h.svm.get_account(&e.range).unwrap();
    e.h.svm.set_account(fake, account.clone()).unwrap();
    let c = e.r.json.pointer("/cases/0").unwrap().clone();
    e.h.refused(
        &[verify_ix(
            &e.h,
            e.r.number,
            &c,
            &proof,
            vec![AccountMeta::new_readonly(fake, false)],
        )],
        VerifierError::UnknownHeaders,
    );
    account.owner = Pubkey::new_unique();
    e.h.svm.set_account(e.range, account.clone()).unwrap();
    e.h.refused(&[e.ix("/cases/0", &proof)], VerifierError::UnknownHeaders);
    account.owner = e.h.id;
    e.h.svm.set_account(e.range, account).unwrap();

    // A block the proof did not cover, or a path of the wrong depth or the wrong siblings.
    let r = e.r.clone();
    let r = &r;
    let tx = 0;
    let n = nodes(r, "/cases/0");
    let outside = encode(
        &e.root,
        r.number + 4,
        r,
        &r.receipts_root,
        &e.path,
        &n,
        tx,
        0,
    );
    let ix = verify_ix(
        &e.h,
        r.number + 4,
        &c,
        &outside,
        vec![AccountMeta::new_readonly(e.range, false)],
    );
    e.h.refused(&[ix], VerifierError::NotInRange);
    let shallow = encode(
        &e.root,
        r.number,
        r,
        &r.receipts_root,
        &e.path[..2],
        &n,
        tx,
        0,
    );
    e.h.refused(&[e.ix("/cases/0", &shallow)], VerifierError::BadHeaderPath);
    let mut wrong = e.path.clone();
    wrong[0][0] ^= 1;
    let bad = encode(&e.root, r.number, r, &r.receipts_root, &wrong, &n, tx, 0);
    e.h.refused(&[e.ix("/cases/0", &bad)], VerifierError::BadHeaderPath);
}

#[test]
fn verify_event_refuses_failed_absent_and_malformed_receipts() {
    let mut e = event();
    let r = e.r.clone();
    let r = &r;
    let at = |k: &str| r.json.pointer(k).unwrap().as_u64().unwrap() as u32;
    let case0 = r.json.pointer("/cases/0").unwrap().clone();
    let range = vec![AccountMeta::new_readonly(e.range, false)];
    let send = |e: &mut Event, proof: Vec<u8>, err: VerifierError| {
        let ix = verify_ix(&e.h, e.r.number, &case0, &proof, range.clone());
        e.h.refused(&[ix], err);
    };
    let failed = encode(
        &e.root,
        r.number,
        r,
        &r.receipts_root,
        &e.path,
        &nodes(r, "/failed"),
        at("/failed/txIndex"),
        0,
    );
    let absent = encode(
        &e.root,
        r.number,
        r,
        &r.receipts_root,
        &e.path,
        &nodes(r, "/absent"),
        at("/absent/txIndex"),
        0,
    );
    let one = encode(
        &e.root,
        r.number,
        r,
        &r.receipts_root,
        &e.path,
        &nodes(r, "/oneTopic"),
        at("/oneTopic/txIndex"),
        at("/oneTopic/logIndex"),
    );
    let beyond = encode(
        &e.root,
        r.number,
        r,
        &r.receipts_root,
        &e.path,
        &nodes(r, "/cases/0"),
        0,
        1_000,
    );
    let far = encode(
        &e.root,
        r.number,
        r,
        &r.receipts_root,
        &e.path,
        &nodes(r, "/cases/0"),
        1 << 16,
        0,
    );
    let mut tampered = nodes(r, "/cases/0");
    tampered[1][40] ^= 1;
    let tampered = encode(
        &e.root,
        r.number,
        r,
        &r.receipts_root,
        &e.path,
        &tampered,
        0,
        0,
    );
    send(&mut e, failed, VerifierError::FailedTransaction);
    send(&mut e, absent, VerifierError::NoReceipt);
    send(&mut e, one, VerifierError::NoLog);
    send(&mut e, beyond, VerifierError::NoLog);
    send(&mut e, far, VerifierError::NoReceipt);
    send(&mut e, tampered, VerifierError::BadReceiptProof);

    // A log whose address is not 20 bytes, which no real block holds, from a made-up trie: refused, not cut.
    let root: [u8; 32] = hex(r.json["malformed"]["receiptsRoot"].as_str().unwrap())
        .try_into()
        .unwrap();
    let lone = leaf(r.number, r.timestamp, &r.state_root, &root);
    let range = e.h.record_range(&lone, r.number, r.number);
    let proof = encode(
        &lone,
        r.number,
        r,
        &root,
        &[],
        &nodes(r, "/malformed"),
        0,
        0,
    );
    let ix = verify_ix(
        &e.h,
        r.number,
        &case0,
        &proof,
        vec![AccountMeta::new_readonly(range, false)],
    );
    e.h.refused(&[ix], VerifierError::BadReceiptProof);
}

// ---------------------------------------------------------------------
// LG-1: receipts of any shape Ethereum accepts
// ---------------------------------------------------------------------

fn rlp_str(b: &[u8]) -> Vec<u8> {
    if b.len() == 1 && b[0] < 0x80 {
        return b.to_vec();
    }
    [rlp_prefix(0x80, b.len()), b.to_vec()].concat()
}

fn rlp_list(items: &[Vec<u8>]) -> Vec<u8> {
    let body = items.concat();
    [rlp_prefix(0xc0, body.len()), body].concat()
}

fn rlp_prefix(base: u8, len: usize) -> Vec<u8> {
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
/// message's log, then one log carrying `junk` bytes of data if `junk` is not zero. The message's log is at `before`.
fn shaped_receipt(before: usize, junk: usize) -> Vec<u8> {
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

impl H {
    /// Stages `proof` in a loader buffer, as the relayer does with `solana program write-buffer`.
    fn stage(&mut self, proof: &[u8]) -> Pubkey {
        let buffer = Pubkey::new_unique();
        let mut data = vec![1, 0, 0, 0, 1];
        data.extend_from_slice(self.authority.pubkey().as_ref());
        data.extend_from_slice(&(proof.len() as u32).to_le_bytes());
        data.extend_from_slice(proof);
        let account = Account {
            lamports: SOL,
            data,
            owner: bpf_loader_upgradeable::id(),
            executable: false,
            rent_epoch: 0,
        };
        self.svm.set_account(buffer, account).unwrap();
        buffer
    }

    /// Verifies the message's log in `receipt`, transaction 0 of a one-block range, staged in a buffer, with the
    /// transaction's whole compute budget and the default heap: the compute units used, or the error.
    fn verify_shaped(&mut self, receipt: &[u8], log_index: u32) -> Result<u64, String> {
        // A receipts trie of transaction 0 alone: its root is a leaf at key rlp(0) = 0x80.
        let node = rlp_list(&[rlp_str(&[0x20, 0x80]), rlp_str(receipt)]);
        let receipts_root = keccak(&[&node]);
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
        let range = self.record_range(&root, number, number);
        let buffer = self.stage(&proof);
        let data = [
            &[VERIFY_EVENT][..],
            &number.to_le_bytes(),
            &EMITTER,
            &TOPIC0,
            &TOPIC1,
            &keccak(&[&DATA]),
        ]
        .concat();
        let ix = self.ix(
            data,
            vec![
                AccountMeta::new_readonly(range, false),
                AccountMeta::new_readonly(buffer, false),
            ],
        );
        let budget: Pubkey = "ComputeBudget111111111111111111111111111111"
            .parse()
            .unwrap();
        let limit = Instruction::new_with_bytes(
            budget,
            &[&[2u8][..], &1_400_000u32.to_le_bytes()].concat(),
            vec![],
        );
        self.send(&[limit, ix])
    }
}

/// LG-1: a receipt of 513 logs, the message's last, verifies within the default 32 KiB heap. The verifier collected
/// every list's items into a vector the bump allocator never frees, so from 512 logs on it ran out of memory, and anyone
/// could make a hub message undeliverable here by sending it from a transaction that also emits 512 empty logs.
#[test]
fn test_lg1_a_receipt_of_513_logs_verifies() {
    let mut h = H::new();
    let cu = h
        .verify_shaped(&shaped_receipt(512, 0), 512)
        .expect("513 logs verify");
    println!("513 logs, the message's last: {cu} compute units");
    let cu = h
        .verify_shaped(&shaped_receipt(2_000, 0), 2_000)
        .expect("2,001 logs verify");
    println!("2,001 logs, the message's last: {cu} compute units");
    // The walk still stops at the receipt's end.
    let err = h.verify_shaped(&shaped_receipt(512, 0), 513).unwrap_err();
    assert!(
        err.contains(&format!("Custom({})", VerifierError::NoLog as u32)),
        "{err}"
    );
}

/// LG-1: a receipt leaf past 64 KB verifies. The proof carried a node's length in 16 bits, so no such proof could be
/// written, though Ethereum's receipts have no size limit of their own and the EVM verifier accepts them.
#[test]
fn test_lg1_a_receipt_leaf_past_64kb_verifies() {
    let mut h = H::new();
    let receipt = shaped_receipt(0, 70_000);
    assert!(receipt.len() > usize::from(u16::MAX));
    let cu = h.verify_shaped(&receipt, 0).expect("a 70 KB leaf verifies");
    println!(
        "a {}-byte receipt leaf: {cu} compute units",
        receipt.len() + 6
    );
}

/// LG-1: what bounds a receipt here now is the transaction's 1.4M compute units, not memory, and every limit is far
/// past a clean transaction's receipt. The hub and the factory can emit a recorded message again in a transaction of
/// its own, so a receipt past these limits delays a message, never strands it. Prints the limits; `--nocapture`.
#[test]
fn lg1_limits_of_a_receipt() {
    let mut h = H::new();
    let logs = ceiling(&mut h, 2_000, 200_000, |n| (shaped_receipt(n, 0), n as u32));
    println!("empty logs before the message, at most: {logs}");
    let bytes = ceiling(&mut h, 70_000, 9_000_000, |n| (shaped_receipt(0, n), 0));
    println!("bytes of one log's data after the message, at most: {bytes}");
    assert!(logs > 2_000 && bytes > 70_000);
}

/// The largest `n` in `[lo, hi)` whose receipt `make(n)` still verifies, `lo`'s verifying.
fn ceiling(
    h: &mut H,
    mut lo: usize,
    mut hi: usize,
    make: impl Fn(usize) -> (Vec<u8>, u32),
) -> usize {
    while hi - lo > 1 {
        let mid = (lo + hi) / 2;
        let (receipt, at) = make(mid);
        if h.verify_shaped(&receipt, at).is_ok() {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    lo
}
