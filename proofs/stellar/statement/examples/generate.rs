//! Rebuilds `fixtures/mainnet.json` from Stellar mainnet, read-only: one checkpoint of SDF's history archive (its
//! ledger headers, transaction sets, result sets and SCP messages) and, from a public Stellar RPC, the meta of one
//! successful Soroban call, which holds the success preimage's return value and events the result only hashes.
//!
//! ```text
//! cargo run --release --example generate -- [checkpoint ledger] [cache dir]
//! ```
//!
//! It picks the ledger N of the checkpoint whose next ledger's transaction set and N's result set are smallest, among
//! those with a successful Soroban call that emitted at least one contract event, and checks every hash the statement
//! will check before writing anything: the result's success hash against the rebuilt preimage, the result set against
//! header N, header N against ledger N+1's transaction set, that set against the externalized value, and the quorum
//! set against the hash the validators commit to.

use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::process::Command;
use stellar_xdr::*;

const ARCHIVE: &str = "https://history.stellar.org/prd/core-live/core_live_001";
const RPC: &str = "https://soroban-rpc.mainnet.stellar.gateway.fm";
const PASSPHRASE: &str = "Public Global Stellar Network ; September 2015";

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

/// The success hash of a Soroban call's result, through a fee bump if there is one.
fn success(r: &TransactionResult) -> Option<[u8; 32]> {
    let ops = match &r.result {
        TransactionResultResult::TxSuccess(ops) => ops,
        TransactionResultResult::TxFeeBumpInnerSuccess(inner) => match &inner.result.result {
            InnerTransactionResultResult::TxSuccess(ops) => ops,
            _ => return None,
        },
        _ => return None,
    };
    match ops.as_slice() {
        [OperationResult::OpInner(OperationResultTr::InvokeHostFunction(
            InvokeHostFunctionResult::Success(h),
        ))] => Some(h.0),
        _ => None,
    }
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

fn rpc_meta(hash: &[u8; 32]) -> Option<TransactionMeta> {
    let body = format!(
        r#"{{"jsonrpc":"2.0","id":1,"method":"getTransaction","params":{{"hash":"{}"}}}}"#,
        hex::encode(hash)
    );
    let out = curl(&[
        "-X",
        "POST",
        RPC,
        "-H",
        "content-type: application/json",
        "-d",
        &body,
    ]);
    let v: serde_json::Value = serde_json::from_slice(&out).ok()?;
    let meta = v["result"]["resultMetaXdr"].as_str()?;
    TransactionMeta::from_xdr_base64(meta, Limits::none()).ok()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let checkpoint: u32 = match args.get(1) {
        Some(c) => c.parse().unwrap(),
        None => {
            let wk = curl(&[&format!("{ARCHIVE}/.well-known/stellar-history.json")]);
            let v: serde_json::Value = serde_json::from_slice(&wk).unwrap();
            v["currentLedger"].as_u64().unwrap() as u32
        }
    };
    assert_eq!((checkpoint + 1) % 64, 0, "a checkpoint ledger");
    let cache = args
        .get(2)
        .cloned()
        .unwrap_or_else(|| "target/stellar-archive".into());
    std::fs::create_dir_all(&cache).unwrap();
    let h = format!("{checkpoint:08x}");
    let mut files = HashMap::new();
    for kind in ["ledger", "transactions", "results", "scp"] {
        let path = format!("{cache}/{kind}-{h}.xdr.gz");
        if !std::path::Path::new(&path).exists() {
            let url = format!(
                "{ARCHIVE}/{kind}/{}/{}/{}/{kind}-{h}.xdr.gz",
                &h[0..2],
                &h[2..4],
                &h[4..6]
            );
            std::fs::write(&path, curl(&[&url])).unwrap();
        }
        files.insert(kind, records(&path));
    }
    let l = Limits::none();
    let headers: HashMap<u32, LedgerHeader> = files["ledger"]
        .iter()
        .map(|r| {
            let e = LedgerHeaderHistoryEntry::from_xdr(r, l.clone()).unwrap();
            assert_eq!(
                sha256(&xdr(&e.header)),
                e.hash.0,
                "a header hashes to its entry's hash"
            );
            (e.header.ledger_seq, e.header)
        })
        .collect();
    let tx_sets: HashMap<u32, Vec<u8>> = files["transactions"]
        .iter()
        .filter_map(|r| {
            let e = TransactionHistoryEntry::from_xdr(r, l.clone()).unwrap();
            match e.ext {
                TransactionHistoryEntryExt::V1(g) => Some((e.ledger_seq, xdr(&g))),
                _ => None,
            }
        })
        .collect();
    let results: HashMap<u32, TransactionResultSet> = files["results"]
        .iter()
        .map(|r| {
            let e = TransactionHistoryResultEntry::from_xdr(r, l.clone()).unwrap();
            (e.ledger_seq, e.tx_result_set)
        })
        .collect();
    let mut qsets: HashMap<[u8; 32], Vec<u8>> = HashMap::new();
    let mut scp: HashMap<u32, Vec<ScpEnvelope>> = HashMap::new();
    for r in &files["scp"] {
        let ScpHistoryEntry::V0(v) = ScpHistoryEntry::from_xdr(r, l.clone()).unwrap();
        for q in v.quorum_sets.iter() {
            let b = xdr(q);
            qsets.insert(sha256(&b), b);
        }
        scp.insert(
            v.ledger_messages.ledger_seq,
            v.ledger_messages.messages.to_vec(),
        );
    }

    // Candidates: N with N+1 in this checkpoint, smallest inputs first.
    let mut candidates: Vec<u32> = results
        .keys()
        .copied()
        .filter(|n| {
            tx_sets.contains_key(&(n + 1)) && scp.contains_key(&(n + 1)) && headers.contains_key(n)
        })
        .collect();
    let size = |n: &u32| tx_sets[&(n + 1)].len() + xdr(&results[n]).len();
    candidates.sort_by_key(size);

    for n in candidates {
        let set = &results[&n];
        for (index, pair) in set.results.iter().enumerate() {
            let Some(hash) = success(&pair.result) else {
                continue;
            };
            let Some(meta) = rpc_meta(&pair.transaction_hash.0) else {
                continue;
            };
            let Some((ret, events)) = preimage(&meta) else {
                continue;
            };
            let Some(event_index) = events.iter().position(|e| e.contract_id.is_some()) else {
                continue;
            };
            let pre = InvokeHostFunctionSuccessPreImage {
                return_value: ret.clone(),
                events: events.clone().try_into().unwrap(),
            };
            assert_eq!(
                sha256(&xdr(&pre)),
                hash,
                "the meta rebuilds the result's success preimage"
            );
            let m = n + 1;
            let header = &headers[&n];
            assert_eq!(sha256(&xdr(set)), header.tx_set_result_hash.0);
            let tx_set = &tx_sets[&m];
            assert_eq!(&tx_set[..4], &[0, 0, 0, 1]);
            assert_eq!(&tx_set[4..36], &sha256(&xdr(header)));
            let envelopes: Vec<&ScpEnvelope> = scp[&m]
                .iter()
                .filter(|e| e.statement.slot_index == m as u64)
                .filter(|e| matches!(e.statement.pledges, ScpStatementPledges::Externalize(_)))
                .collect();
            let mut counts: HashMap<[u8; 32], usize> = HashMap::new();
            for e in &envelopes {
                if let ScpStatementPledges::Externalize(x) = &e.statement.pledges {
                    let value =
                        StellarValue::from_xdr(x.commit.value.as_slice(), l.clone()).unwrap();
                    assert_eq!(
                        value.tx_set_hash.0,
                        sha256(tx_set),
                        "the value opens to the set"
                    );
                    *counts.entry(x.commit_quorum_set_hash.0).or_default() += 1;
                }
            }
            let (qhash, _) = counts.iter().max_by_key(|(_, c)| **c).unwrap();
            let quorum_set = qsets
                .get(qhash)
                .expect("the committed quorum set's preimage is archived");
            let out = serde_json::json!({
                "source": {
                    "archive": ARCHIVE,
                    "checkpoint": checkpoint,
                    "rpc": RPC,
                    "transaction": hex::encode(pair.transaction_hash.0),
                    "passphrase": PASSPHRASE,
                },
                "networkId": hex::encode(sha256(PASSPHRASE.as_bytes())),
                "quorumSet": hex::encode(quorum_set),
                "envelopes": envelopes.iter().map(|e| hex::encode(xdr(*e))).collect::<Vec<_>>(),
                "txSet": hex::encode(tx_set),
                "headers": [hex::encode(xdr(header))],
                "resultSet": hex::encode(xdr(set)),
                "resultIndex": index,
                "returnValue": hex::encode(xdr(&ret)),
                "events": events.iter().map(|e| hex::encode(xdr(e))).collect::<Vec<_>>(),
                "eventIndex": event_index,
                "ledger": n,
                "closeTime": header.scp_value.close_time.0,
            });
            let path = concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/mainnet.json");
            std::fs::write(path, serde_json::to_string_pretty(&out).unwrap()).unwrap();
            println!(
                "ledger {n}, tx {} (result {index}, event {event_index} of {}), {} envelopes, {} bytes of tx set, {} of results",
                hex::encode(pair.transaction_hash.0),
                events.len(),
                envelopes.len(),
                tx_set.len(),
                xdr(set).len()
            );
            return;
        }
    }
    panic!("no ledger of this checkpoint has a Soroban call with a contract event");
}
