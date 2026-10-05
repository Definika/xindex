//! DRAFT, untested (2026-10-06). The input `stellar-proof prove` takes for one successful `attest` of a Stellar vault,
//! for the filler's Stellar adapter (`keeper/chains/stellar.mjs`). Adapted from `generate.rs`, whose checks it keeps:
//! read-only, from a Stellar RPC (the call's meta, which holds the success preimage's return value and events the
//! result only hashes) and SDF's history archive (headers, transaction sets, result sets and SCP messages).
//!
//! ```text
//! cargo run --release --example attest_input -- <rpc> <archive> <passphrase> <tx hash> <vault id> \
//!     <quorum set hash> <out.json> [quorum set file] [cache dir]
//! ```
//!
//! - `<tx hash>` is the `attest` transaction's, `<vault id>` the vault's contract id and `<quorum set hash>` the
//!   verifier's `QUORUM_SET_HASH()`, each as hex.
//! - The quorum set itself is looked up among the archive's SCP quorum sets by that hash, or read from
//!   `[quorum set file]`, its XDR as hex: the file `DeployStateVerifier` was given. An empty argument skips it.
//! - Ledger `N` is the transaction's and `M = N + 1` the slot whose externalized value the envelopes sign, so the input
//!   holds one header. The builder waits until the archive has published the checkpoint holding `M`.
//!
//! Before writing, it runs the statement natively (`xindex_stellar::verify`) on exactly what the host will prove:
//! the host keeps, of the envelopes written, the first `threshold` of each of the quorum set's first `threshold` inner
//! sets (`script/src/main.rs`, `minimal`), so the builder does the same. The output is the fixture's layout
//! (`fixtures/mainnet.json`, hex without `0x`) plus `vaultId`, `record` and the public values the proof must commit.

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashMap};
use std::process::Command;
use stellar_xdr::*;
use xindex_stellar::{attest_event, quorum, success_hash, verify, Input};

/// How long to wait for the archive to publish the checkpoint holding M: checkpoints come every 64 ledgers, about
/// five minutes, and publishing lags a few more.
const WAIT_TRIES: u32 = 60;
const WAIT_SECONDS: u64 = 30;

fn sha256(b: &[u8]) -> [u8; 32] {
    Sha256::digest(b).into()
}

fn curl(args: &[&str]) -> Vec<u8> {
    let out = Command::new("curl")
        .args(["-sf", "--max-time", "120"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "curl {args:?} failed");
    out.stdout
}

fn records(gz: &str) -> Vec<Vec<u8>> {
    let out = Command::new("gunzip").args(["-c", gz]).output().unwrap();
    let d = out.stdout;
    let mut v = Vec::new();
    let mut i = 0;
    while i < d.len() {
        let mark = u32::from_be_bytes(d[i..i + 4].try_into().unwrap());
        assert!(mark & 0x8000_0000 != 0, "a record in one fragment");
        let len = (mark & 0x7fff_ffff) as usize;
        v.push(d[i + 4..i + 4 + len].to_vec());
        i += 4 + len;
    }
    v
}

fn xdr<T: WriteXdr>(t: &T) -> Vec<u8> {
    t.to_xdr(Limits::none()).unwrap()
}

fn hex32(s: &str) -> [u8; 32] {
    hex::decode(s.trim_start_matches("0x"))
        .expect("hex")
        .try_into()
        .expect("32 bytes")
}

/// The call's return value and contract events, from its meta.
fn preimage(meta: &TransactionMeta) -> Option<(ScVal, Vec<ContractEvent>)> {
    match meta {
        TransactionMeta::V4(m) => {
            let ret = m
                .soroban_meta
                .as_ref()?
                .return_value
                .clone()
                .unwrap_or(ScVal::Void);
            let events = m
                .operations
                .iter()
                .flat_map(|o| o.events.iter().cloned())
                .collect();
            Some((ret, events))
        }
        TransactionMeta::V3(m) => {
            let s = m.soroban_meta.as_ref()?;
            Some((s.return_value.clone(), s.events.to_vec()))
        }
        _ => None,
    }
}

fn rpc(url: &str, method: &str, params: Value) -> Value {
    let body = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).to_string();
    let out = curl(&[
        "-X",
        "POST",
        url,
        "-H",
        "content-type: application/json",
        "-d",
        &body,
    ]);
    let v: Value = serde_json::from_slice(&out).expect("JSON");
    assert!(v.get("error").is_none(), "{method}: {}", v["error"]);
    v["result"].clone()
}

/// The checkpoint whose files hold `ledger`: checkpoints end at ledgers 63, 127, 191 and so on.
fn checkpoint_of(ledger: u32) -> u32 {
    ledger | 63
}

fn wait_for(archive: &str, checkpoint: u32) {
    for _ in 0..WAIT_TRIES {
        let wk = curl(&[&format!("{archive}/.well-known/stellar-history.json")]);
        let v: Value = serde_json::from_slice(&wk).unwrap();
        if v["currentLedger"].as_u64().unwrap() >= u64::from(checkpoint) {
            return;
        }
        eprintln!(
            "waiting for checkpoint {checkpoint} ({})",
            v["currentLedger"]
        );
        std::thread::sleep(std::time::Duration::from_secs(WAIT_SECONDS));
    }
    panic!("the archive has not published checkpoint {checkpoint}");
}

/// The archive's history of one checkpoint, as `generate.rs` reads it.
#[derive(Default)]
struct History {
    headers: HashMap<u32, LedgerHeader>,
    tx_sets: HashMap<u32, Vec<u8>>,
    results: HashMap<u32, TransactionResultSet>,
    scp: HashMap<u32, Vec<ScpEnvelope>>,
    qsets: HashMap<[u8; 32], Vec<u8>>,
}

fn load(archive: &str, cache: &str, checkpoint: u32, into: &mut History) {
    let h = format!("{checkpoint:08x}");
    let l = Limits::none();
    let mut files = HashMap::new();
    for kind in ["ledger", "transactions", "results", "scp"] {
        let path = format!("{cache}/{kind}-{h}.xdr.gz");
        if !std::path::Path::new(&path).exists() {
            let url = format!(
                "{archive}/{kind}/{}/{}/{}/{kind}-{h}.xdr.gz",
                &h[0..2],
                &h[2..4],
                &h[4..6]
            );
            std::fs::write(&path, curl(&[&url])).unwrap();
        }
        files.insert(kind, records(&path));
    }
    for r in &files["ledger"] {
        let e = LedgerHeaderHistoryEntry::from_xdr(r, l.clone()).unwrap();
        assert_eq!(
            sha256(&xdr(&e.header)),
            e.hash.0,
            "a header hashes to its entry's hash"
        );
        into.headers.insert(e.header.ledger_seq, e.header);
    }
    for r in &files["transactions"] {
        let e = TransactionHistoryEntry::from_xdr(r, l.clone()).unwrap();
        if let TransactionHistoryEntryExt::V1(g) = e.ext {
            into.tx_sets.insert(e.ledger_seq, xdr(&g));
        }
    }
    for r in &files["results"] {
        let e = TransactionHistoryResultEntry::from_xdr(r, l.clone()).unwrap();
        into.results.insert(e.ledger_seq, e.tx_result_set);
    }
    for r in &files["scp"] {
        let ScpHistoryEntry::V0(v) = ScpHistoryEntry::from_xdr(r, l.clone()).unwrap();
        for q in v.quorum_sets.iter() {
            let b = xdr(q);
            into.qsets.insert(sha256(&b), b);
        }
        into.scp.insert(
            v.ledger_messages.ledger_seq,
            v.ledger_messages.messages.to_vec(),
        );
    }
}

fn signer(e: &ScpEnvelope) -> [u8; 32] {
    let NodeId(PublicKey::PublicKeyTypeEd25519(k)) = &e.statement.node_id;
    k.0
}

/// The host's choice of envelopes (`script/src/main.rs`, `minimal`): of each of the quorum set's first `threshold`
/// inner sets, its first `threshold` signers among `envelopes`.
fn minimal(q: &ScpQuorumSet, envelopes: &[ScpEnvelope]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    for inner in q.inner_sets.iter().take(q.threshold as usize) {
        let members = quorum::validators(inner);
        out.extend(
            envelopes
                .iter()
                .filter(|e| members.contains(&signer(e)))
                .take(inner.threshold as usize)
                .map(xdr),
        );
    }
    out
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 8 {
        eprintln!(
            "usage: attest_input <rpc> <archive> <passphrase> <tx hash> <vault id> <quorum set hash> <out.json> \
             [quorum set file] [cache dir]"
        );
        std::process::exit(2);
    }
    let (rpc_url, archive, passphrase) = (&args[1], args[2].trim_end_matches('/'), &args[3]);
    let tx_hash = hex32(&args[4]);
    let vault_id = hex32(&args[5]);
    let pinned = hex32(&args[6]);
    let out_path = &args[7];
    let qset_file = args.get(8).filter(|s| !s.is_empty());
    let cache = args
        .get(9)
        .cloned()
        .unwrap_or_else(|| "target/stellar-archive".into());
    std::fs::create_dir_all(&cache).unwrap();

    // 1. The transaction: its ledger N, and from its meta the return value and events its success hash covers. The
    //    vault's event among them must be exactly the one the statement writes from the vault's id and the record.
    let tx = rpc(
        rpc_url,
        "getTransaction",
        json!({"hash": hex::encode(tx_hash)}),
    );
    assert_eq!(tx["status"], "SUCCESS", "the attest transaction succeeded");
    let n = tx["ledger"].as_u64().expect("its ledger") as u32;
    let meta = TransactionMeta::from_xdr_base64(
        tx["resultMetaXdr"].as_str().expect("its meta"),
        Limits::none(),
    )
    .expect("the meta");
    let (ret, events) = preimage(&meta).expect("a Soroban call's meta");
    let (event_index, record) = events
        .iter()
        .enumerate()
        .find_map(|(i, e)| {
            let ContractEventBody::V0(body) = &e.body;
            let ScVal::Bytes(ScBytes(record)) = &body.data else {
                return None;
            };
            let record = record.as_slice().to_vec();
            (attest_event(&vault_id, &record).ok()? == *e).then_some((i, record))
        })
        .expect("the vault's attest event");

    // 2. Ledger N's header and result set, and ledger M's transaction set and SCP messages, from the archive.
    let m = n + 1;
    wait_for(archive, checkpoint_of(m));
    let mut history = History::default();
    load(archive, &cache, checkpoint_of(n), &mut history);
    if checkpoint_of(m) != checkpoint_of(n) {
        load(archive, &cache, checkpoint_of(m), &mut history);
    }
    let header = history.headers.get(&n).expect("header N").clone();
    let set = history.results.get(&n).expect("result set N");
    assert_eq!(sha256(&xdr(set)), header.tx_set_result_hash.0);
    let result_index = set
        .results
        .iter()
        .position(|p| p.transaction_hash.0 == tx_hash)
        .expect("the transaction in ledger N's results");
    let hash = success_hash(&set.results[result_index].result)
        .expect("a successful call of one InvokeHostFunction");
    let pre = InvokeHostFunctionSuccessPreImage {
        return_value: ret.clone(),
        events: events.clone().try_into().unwrap(),
    };
    assert_eq!(
        sha256(&xdr(&pre)),
        hash,
        "the meta rebuilds the result's success preimage"
    );
    let tx_set = history.tx_sets.get(&m).expect("transaction set M").clone();
    assert_eq!(&tx_set[..4], &[0, 0, 0, 1]);
    assert_eq!(&tx_set[4..36], &sha256(&xdr(&header)));

    // 3. The pinned quorum set, and the EXTERNALIZE envelopes of its validators for slot M, each opening to the set.
    let quorum_set = match qset_file {
        Some(path) => hex::decode(
            std::fs::read_to_string(path)
                .unwrap()
                .trim()
                .trim_start_matches("0x"),
        )
        .unwrap(),
        None => history
            .qsets
            .get(&pinned)
            .expect("the pinned quorum set among the archive's; pass its file otherwise")
            .clone(),
    };
    assert_eq!(
        sha256(&quorum_set),
        pinned,
        "the quorum set the verifier pins"
    );
    let q = ScpQuorumSet::from_xdr(&quorum_set, Limits::none()).unwrap();
    let members = quorum::validators(&q);
    let envelopes: Vec<ScpEnvelope> = history
        .scp
        .get(&m)
        .expect("SCP messages for M")
        .iter()
        .filter(|e| e.statement.slot_index == u64::from(m))
        .filter(|e| matches!(e.statement.pledges, ScpStatementPledges::Externalize(_)))
        .filter(|e| members.contains(&signer(e)))
        .cloned()
        .collect();
    for e in &envelopes {
        if let ScpStatementPledges::Externalize(x) = &e.statement.pledges {
            let value = StellarValue::from_xdr(x.commit.value.as_slice(), Limits::none()).unwrap();
            assert_eq!(
                value.tx_set_hash.0,
                sha256(&tx_set),
                "the value opens to the set"
            );
        }
    }
    let signers: BTreeSet<[u8; 32]> = envelopes.iter().map(signer).collect();
    assert!(
        quorum::satisfied(&q, &signers),
        "the archive's envelopes for M satisfy the pinned quorum set"
    );

    // 4. The statement, natively, on the envelopes the host will keep.
    let input = Input {
        network_id: sha256(passphrase.as_bytes()),
        quorum_set: quorum_set.clone(),
        envelopes: minimal(&q, &envelopes),
        tx_set: tx_set.clone(),
        headers: vec![xdr(&header)],
        result_set: xdr(set),
        result_index: result_index as u32,
        return_value: xdr(&ret),
        events: events.iter().map(xdr).collect(),
        event_index: event_index as u32,
        vault_id,
        record: record.clone(),
    };
    let output = verify(&input).unwrap_or_else(|e| {
        panic!(
            "the statement fails on the host's choice of envelopes ({e:?}); if NotAQuorum, one of the quorum set's \
             first inner sets lacks signatures in the archive, which the host's `minimal` does not skip"
        )
    });

    let out = json!({
        "source": {
            "archive": archive,
            "rpc": rpc_url,
            "transaction": hex::encode(tx_hash),
            "passphrase": passphrase,
        },
        "networkId": hex::encode(input.network_id),
        "quorumSet": hex::encode(&quorum_set),
        "envelopes": envelopes.iter().map(|e| hex::encode(xdr(e))).collect::<Vec<_>>(),
        "txSet": hex::encode(&tx_set),
        "headers": input.headers.iter().map(hex::encode).collect::<Vec<_>>(),
        "resultSet": hex::encode(&input.result_set),
        "resultIndex": result_index,
        "returnValue": hex::encode(&input.return_value),
        "events": input.events.iter().map(hex::encode).collect::<Vec<_>>(),
        "eventIndex": event_index,
        "ledger": n,
        "closeTime": header.scp_value.close_time.0,
        "vaultId": hex::encode(vault_id),
        "record": hex::encode(&record),
        "publicValues": format!("0x{}", hex::encode(output.abi_encode())),
    });
    std::fs::write(out_path, serde_json::to_string_pretty(&out).unwrap()).unwrap();
    eprintln!(
        "ledger {n}, tx {} (result {result_index}, event {event_index}), {} of {} envelopes kept",
        hex::encode(tx_hash),
        input.envelopes.len(),
        envelopes.len()
    );
}
