//! THROWAWAY review tests (not for commit): large receipts on P1's Solana verifier.

use anchor_lang::solana_program::{
    bpf_loader_upgradeable,
    instruction::{AccountMeta, Instruction},
    pubkey::Pubkey,
};
use ethereum_verifier::{event, keccak, RANGE_LEN, RANGE_SEED, VERIFY_EVENT};
use litesvm::LiteSVM;
use solana_account::Account;
use solana_keypair::Keypair;
use solana_message::{Message, VersionedMessage};
use solana_signer::Signer;
use solana_transaction::versioned::VersionedTransaction;

const SOL: u64 = 1_000_000_000;

fn rlp_str(b: &[u8]) -> Vec<u8> {
    if b.len() == 1 && b[0] < 0x80 {
        return b.to_vec();
    }
    [prefix(0x80, b.len()), b.to_vec()].concat()
}
fn rlp_list(items: &[Vec<u8>]) -> Vec<u8> {
    let body: Vec<u8> = items.concat();
    [prefix(0xc0, body.len()), body].concat()
}
fn prefix(base: u8, len: usize) -> Vec<u8> {
    if len < 56 {
        vec![base + len as u8]
    } else {
        let be = (len as u64).to_be_bytes();
        let skip = be.iter().take_while(|b| **b == 0).count();
        let n = &be[skip..];
        [vec![base + 55 + n.len() as u8], n.to_vec()].concat()
    }
}
fn word(x: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&x.to_be_bytes());
    w
}

const EMITTER: [u8; 20] = [0xab; 20];
const TOPIC0: [u8; 32] = [0x11; 32];
const TOPIC1: [u8; 32] = [0x22; 32];
const DATA: [u8; 96] = [0x33; 96];

/// A typed receipt, successful: the vault message's log first, then `junk_logs` empty logs and one junk log carrying
/// `junk_data` bytes, as a contract wrapping a permissionless hub call could add in the same transaction.
fn receipt(junk_logs: usize, junk_data: usize) -> Vec<u8> {
    let mut logs = vec![rlp_list(&[
        rlp_str(&EMITTER),
        rlp_list(&[rlp_str(&TOPIC0), rlp_str(&TOPIC1)]),
        rlp_str(&DATA),
    ])];
    for _ in 0..junk_logs {
        logs.push(rlp_list(&[rlp_str(&[0xee; 20]), rlp_list(&[]), rlp_str(&[])]));
    }
    if junk_data > 0 {
        logs.push(rlp_list(&[
            rlp_str(&[0xee; 20]),
            rlp_list(&[]),
            rlp_str(&vec![0u8; junk_data]),
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

/// A receipts trie holding only transaction 0: its root node is a leaf at key rlp(0) = 0x80.
fn trie(receipt: &[u8]) -> ([u8; 32], Vec<u8>) {
    let leaf = rlp_list(&[rlp_str(&[0x20, 0x80]), rlp_str(receipt)]);
    (keccak(&[&leaf]), leaf)
}

/// The event proof as the relayer writes it (event.rs `parse`), for a one-block range: the leaf is the root.
fn encode(number: u64, receipts_root: &[u8; 32], node: &[u8]) -> ([u8; 32], Vec<u8>) {
    let (t, s) = (1_700_000_000u64, [0x44u8; 32]);
    let leaf = keccak(&[&word(number), &word(t), &s, receipts_root]);
    let mut out = [&leaf[..], &number.to_le_bytes(), &t.to_le_bytes(), &s, receipts_root].concat();
    out.push(0); // no path
    out.push(1); // one node
    out.extend_from_slice(&(node.len() as u16).to_le_bytes()); // the format's u16: a longer node is cut
    out.extend_from_slice(node);
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    (leaf, out)
}

#[test]
fn review_a_receipt_past_64kb_is_valid_but_cannot_be_encoded() {
    let r = receipt(0, 70_000);
    let (root, node) = trie(&r);
    println!("leaf node: {} bytes", node.len());
    assert!(node.len() > u16::MAX as usize);
    // The verifier's own logic, which is the EVM twin's, accepts this receipt and finds the vault's log...
    let log = event::log(&root, &[&node], 0, 0).expect("the receipt and its log are valid");
    assert_eq!((log.emitter, log.topic0, log.topic1), (EMITTER, TOPIC0, TOPIC1));
    assert_eq!(log.data, &DATA[..]);
    // ...but the wire format carries a node's length as a u16, so no encoding of this proof parses.
    let (_, proof) = encode(100, &root, &node);
    assert!(event::parse(&proof).is_err(), "the cut length leaves trailing bytes");
}

struct H {
    svm: LiteSVM,
    id: Pubkey,
    payer: Keypair,
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
        let payer = Keypair::new();
        svm.airdrop(&payer.pubkey(), 10 * SOL).unwrap();
        H { svm, id, payer }
    }
    fn record_range(&mut self, headers_root: &[u8; 32], first: u64, last: u64) -> Pubkey {
        let (key, bump) = Pubkey::find_program_address(&[RANGE_SEED, headers_root], &self.id);
        let data = [&first.to_le_bytes()[..], &last.to_le_bytes(), &[bump]].concat();
        assert_eq!(data.len(), RANGE_LEN);
        self.svm
            .set_account(
                key,
                Account { lamports: SOL, data, owner: self.id, executable: false, rent_epoch: 0 },
            )
            .unwrap();
        key
    }
    fn stage(&mut self, proof: &[u8]) -> Pubkey {
        let buffer = Pubkey::new_unique();
        let mut data = vec![1, 0, 0, 0, 1];
        data.extend_from_slice(self.payer.pubkey().as_ref());
        data.extend_from_slice(&(proof.len() as u32).to_le_bytes());
        data.extend_from_slice(proof);
        self.svm
            .set_account(
                buffer,
                Account {
                    lamports: SOL,
                    data,
                    owner: bpf_loader_upgradeable::id(),
                    executable: false,
                    rent_epoch: 0,
                },
            )
            .unwrap();
        buffer
    }
    fn send(&mut self, ixs: &[Instruction]) -> Result<u64, String> {
        self.svm.expire_blockhash();
        let payer = self.payer.insecure_clone();
        let msg =
            Message::new_with_blockhash(ixs, Some(&payer.pubkey()), &self.svm.latest_blockhash());
        let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), &[&payer]).unwrap();
        match self.svm.send_transaction(tx) {
            Ok(meta) => Ok(meta.compute_units_consumed),
            Err(f) => Err(format!("{:?} {:?}", f.err, f.meta.logs)),
        }
    }
}

fn compute_budget(tag: u8, value: u32) -> Instruction {
    let id: Pubkey = "ComputeBudget111111111111111111111111111111".parse().unwrap();
    Instruction::new_with_bytes(id, &[&[tag][..], &value.to_le_bytes()].concat(), vec![])
}

fn verify(h: &mut H, junk_logs: usize, heap: Option<u32>) -> Result<u64, String> {
    let r = receipt(junk_logs, 0);
    let (root, node) = trie(&r);
    let (leaf, proof) = encode(100, &root, &node);
    println!("{junk_logs} junk logs: leaf node {} bytes, proof {} bytes", node.len(), proof.len());
    assert!(event::parse(&proof).is_ok(), "encodable");
    let range = h.record_range(&leaf, 100, 100);
    let buffer = h.stage(&proof);
    let data = [
        &[VERIFY_EVENT][..],
        &100u64.to_le_bytes(),
        &EMITTER,
        &TOPIC0,
        &TOPIC1,
        &keccak(&[&DATA]),
    ]
    .concat();
    let ix = Instruction::new_with_bytes(
        h.id,
        &data,
        vec![AccountMeta::new_readonly(range, false), AccountMeta::new_readonly(buffer, false)],
    );
    let mut ixs = vec![compute_budget(2, 1_400_000)];
    if let Some(bytes) = heap {
        ixs.push(compute_budget(1, bytes));
    }
    ixs.push(ix);
    h.send(&ixs)
}

/// Below the u16 limit, a receipt of many small logs still exhausts the verifier's heap: every `items()` is a Vec the
/// bump allocator never frees.
#[test]
fn review_many_small_logs_exhaust_the_default_heap() {
    let mut h = H::new();
    println!("control, 0 junk logs: {:?}", verify(&mut h, 0, None).map_err(|e| e[..200.min(e.len())].to_string()));
    let full = verify(&mut h, 700, Some(256 * 1024)).unwrap_err();
    println!("FULL ERROR, 700 junk logs, 256 KB heap requested: {full}");
    let (mut lo, mut hi) = (500usize, 700usize);
    while hi - lo > 1 {
        let mid = (lo + hi) / 2;
        if verify(&mut h, mid, Some(256 * 1024)).is_ok() {
            lo = mid
        } else {
            hi = mid
        }
    }
    println!("THRESHOLD: {lo} junk logs verify, {hi} do not ({} and {} logs in the receipt)", lo + 1, hi + 1);
    for n in [500usize, 700, 1_000, 2_000, 2_600] {
        let default = verify(&mut h, n, None);
        let max_heap = verify(&mut h, n, Some(256 * 1024));
        let short = |r: &Result<u64, String>| match r {
            Ok(cu) => format!("OK {cu} CU"),
            Err(e) => e.chars().take(160).collect(),
        };
        println!("  default heap: {}\n  256 KB heap:  {}", short(&default), short(&max_heap));
    }
}
