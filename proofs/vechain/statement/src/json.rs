//! Reading `fixtures/*.json`, which `fixtures/generate.py` writes, into the statement's input. For the host and the
//! tests, never the program.

use alloc::string::String;
use alloc::vec::Vec;
use serde_json::Value;

use crate::{
    Address, Attested, Call, Common, Fees, Header, Input, Receipt, Table, Transaction, Word,
};

pub fn hex(s: &str) -> Vec<u8> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    let s: String = if s.len() % 2 == 1 {
        alloc::format!("0{s}")
    } else {
        s.into()
    };
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex"))
        .collect()
}

fn text(v: &Value) -> &str {
    v.as_str().expect("a hex string")
}

pub fn word(v: &Value) -> Word {
    let b = hex(text(v));
    let mut out = [0u8; 32];
    out[32 - b.len()..].copy_from_slice(&b);
    out
}

pub fn address(v: &Value) -> Address {
    hex(text(v)).try_into().expect("20 bytes")
}

fn number(v: &Value) -> u64 {
    match v {
        Value::Number(n) => n.as_u64().expect("an unsigned integer"),
        Value::String(s) => {
            u64::from_str_radix(s.strip_prefix("0x").unwrap_or(s), 16).expect("hex")
        }
        _ => panic!("a number"),
    }
}

pub fn header(v: &Value) -> Header {
    Header {
        parent_id: word(&v["parentID"]),
        timestamp: number(&v["timestamp"]),
        gas_limit: number(&v["gasLimit"]),
        beneficiary: address(&v["beneficiary"]),
        gas_used: number(&v["gasUsed"]),
        total_score: number(&v["totalScore"]),
        txs_root: word(&v["txsRoot"]),
        txs_features: number(&v["txsFeatures"]) as u32,
        state_root: word(&v["stateRoot"]),
        receipts_root: word(&v["receiptsRoot"]),
        alpha: hex(text(&v["alpha"])),
        com: v["com"].as_bool().expect("COM"),
        base_fee: word(&v["baseFee"]),
        signature: hex(text(&v["signature"])),
    }
}

pub fn headers(v: &Value) -> Vec<Header> {
    v.as_array().expect("headers").iter().map(header).collect()
}

pub fn transaction(v: &Value) -> Transaction {
    let fees = if v.get("gasPriceCoef").is_some() {
        Fees::Legacy {
            gas_price_coef: number(&v["gasPriceCoef"]) as u8,
        }
    } else {
        Fees::Dynamic {
            max_priority_fee_per_gas: word(&v["maxPriorityFeePerGas"]),
            max_fee_per_gas: word(&v["maxFeePerGas"]),
        }
    };
    Transaction {
        chain_tag: number(&v["chainTag"]) as u8,
        block_ref: number(&v["blockRef"]),
        expiration: number(&v["expiration"]) as u32,
        fees,
        gas: number(&v["gas"]),
        depends_on: if v["dependsOn"].is_null() {
            None
        } else {
            Some(word(&v["dependsOn"]))
        },
        nonce: number(&v["nonce"]),
        features: number(&v["features"]) as u32,
        signature: hex(text(&v["signature"])),
    }
}

fn proof(v: &Value) -> Vec<Vec<u8>> {
    v.as_array()
        .expect("a proof")
        .iter()
        .map(|n| hex(text(n)))
        .collect()
}

pub fn call(v: &Value) -> Call {
    let r = &v["receipt"];
    Call {
        block: number(&v["block"]) as u32,
        index: number(&v["index"]) as u32,
        transaction: transaction(&v["transaction"]),
        receipt: Receipt {
            gas_used: number(&r["gasUsed"]),
            gas_payer: address(&r["gasPayer"]),
            paid: word(&r["paid"]),
            reward: word(&r["reward"]),
        },
        transaction_proof: proof(&v["transactionProof"]),
        receipt_proof: proof(&v["receiptProof"]),
    }
}

pub fn table(v: &Value) -> Table {
    Table {
        total_weight: word(&v["totalWeight"]),
        validators: v["validators"]
            .as_array()
            .expect("validators")
            .iter()
            .map(|p| (address(&p[0]), word(&p[1])))
            .collect(),
    }
}

fn attested(v: &Value) -> Attested {
    Attested {
        table: table(&v["table"]),
        call: call(&v["call"]),
    }
}

/// What both claims of a fixture start from.
pub fn common(f: &Value) -> Common {
    Common {
        chain: word(&f["chain"]),
        attester: address(&f["attester"]),
        trusted_id: word(&f["trusted"]["id"]),
        trusted: table(&f["trusted"]["table"]),
        headers: headers(&f["headers"]),
    }
}

pub fn update(f: &Value) -> Input {
    Input::Update {
        common: common(f),
        attested: attested(&f["update"]["attested"]),
    }
}

pub fn slots(f: &Value) -> Input {
    let s = &f["slots"];
    let words = |v: &Value| v.as_array().expect("words").iter().map(word).collect();
    Input::Slots {
        common: common(f),
        vault: address(&s["vault"]),
        slots: words(&s["slots"]),
        values: words(&s["values"]),
        call: call(&s["call"]),
        justified: attested(&s["justified"]),
        committed: attested(&s["committed"]),
    }
}
