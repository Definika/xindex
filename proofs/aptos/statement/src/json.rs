//! Reading `fixtures/*.json`, which `fixtures/generate.py` writes, into the statement's input. The fixtures hold
//! Aptos's own BCS (ledger infos with their signatures, transaction infos, events), which this decodes; the statement
//! then writes it back and hashes what it wrote. For the host and the tests, never the program.

use alloc::string::String;
use alloc::vec::Vec;
use serde_json::Value;

use crate::{
    BlockInfo, EpochState, Included, Input, LedgerInfo, Signed, TransactionInfo, Validator, Word,
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

pub fn bytes(v: &Value) -> Vec<u8> {
    hex(text(v))
}

pub fn word(v: &Value) -> Word {
    bytes(v).try_into().expect("32 bytes")
}

pub fn number(v: &Value) -> u64 {
    match v {
        Value::Number(n) => n.as_u64().expect("an unsigned integer"),
        Value::String(s) => s.parse().expect("a decimal integer"),
        _ => panic!("a number"),
    }
}

fn list<T>(v: &Value, f: impl Fn(&Value) -> T) -> Vec<T> {
    v.as_array().expect("a list").iter().map(f).collect()
}

/// A BCS reader, strict: every read must fit, and a whole value must be consumed.
pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Reader { data, pos: 0 }
    }

    fn take(&mut self, n: usize) -> &'a [u8] {
        let out = &self.data[self.pos..self.pos + n];
        self.pos += n;
        out
    }

    fn u8(&mut self) -> u8 {
        self.take(1)[0]
    }

    fn u64(&mut self) -> u64 {
        u64::from_le_bytes(self.take(8).try_into().unwrap())
    }

    fn uleb(&mut self) -> u64 {
        let (mut n, mut shift) = (0u64, 0);
        loop {
            let b = self.u8();
            n |= u64::from(b & 0x7f) << shift;
            if b & 0x80 == 0 {
                return n;
            }
            shift += 7;
        }
    }

    fn bytes(&mut self) -> Vec<u8> {
        let n = self.uleb() as usize;
        self.take(n).to_vec()
    }

    fn word(&mut self) -> Word {
        self.take(32).try_into().unwrap()
    }

    fn option<T>(&mut self, f: impl FnOnce(&mut Self) -> T) -> Option<T> {
        match self.u8() {
            0 => None,
            1 => Some(f(self)),
            t => panic!("option tag {t}"),
        }
    }

    pub fn done(&self) {
        assert_eq!(self.pos, self.data.len(), "trailing bytes");
    }

    pub fn validators(&mut self) -> Vec<Validator> {
        let n = self.uleb();
        (0..n)
            .map(|_| Validator {
                address: self.word(),
                public_key: self.bytes(),
                voting_power: self.u64(),
            })
            .collect()
    }

    pub fn ledger_info(&mut self) -> LedgerInfo {
        let commit_info = BlockInfo {
            epoch: self.u64(),
            round: self.u64(),
            id: self.word(),
            executed_state_id: self.word(),
            version: self.u64(),
            timestamp_usecs: self.u64(),
            next_epoch_state: self.option(|r| EpochState {
                epoch: r.u64(),
                validators: r.validators(),
            }),
        };
        LedgerInfo {
            commit_info,
            consensus_data_hash: self.word(),
        }
    }

    /// `LedgerInfoWithSignatures::V0`: the ledger info, the bitmask and the signature.
    pub fn signed(&mut self) -> (LedgerInfo, Vec<u8>, Vec<u8>) {
        assert_eq!(self.u8(), 0, "LedgerInfoWithSignatures::V0");
        let li = self.ledger_info();
        let bitmask = self.bytes();
        let signature = self.option(|r| r.bytes()).expect("a signature");
        (li, bitmask, signature)
    }

    /// A successful `TransactionInfo`, V0 or V1, without its event root (which the statement computes): returns it
    /// with the event root it carries.
    pub fn transaction_info(&mut self) -> (TransactionInfo, Word) {
        let variant = self.u8();
        let gas_used = self.u64();
        assert_eq!(self.u8(), 0, "a successful transaction");
        let transaction_hash = self.word();
        let event_root = self.word();
        let state_change_hash = self.word();
        let state_checkpoint_hash = self.option(|r| r.word());
        let info = match variant {
            0 => TransactionInfo::V0 {
                gas_used,
                transaction_hash,
                state_change_hash,
                state_checkpoint_hash,
                auxiliary_info_hash: self.option(|r| r.word()),
            },
            1 => {
                let hot_state_checkpoint_hash = self.option(|r| r.word());
                let auxiliary_info_hash = self.option(|r| r.word());
                let position_state_checkpoint_hash = self.option(|r| r.word());
                let placeholders = core::array::from_fn(|_| self.option(|r| r.word()));
                TransactionInfo::V1 {
                    gas_used,
                    transaction_hash,
                    state_change_hash,
                    state_checkpoint_hash,
                    hot_state_checkpoint_hash,
                    auxiliary_info_hash,
                    position_state_checkpoint_hash,
                    placeholders,
                }
            }
            v => panic!("TransactionInfo variant {v}"),
        };
        (info, event_root)
    }
}

/// A set, `{"epoch", "validators"}`, its validators as `ValidatorVerifier`'s BCS.
pub fn epoch_state(v: &Value) -> EpochState {
    let b = bytes(&v["validators"]);
    let mut r = Reader::new(&b);
    let validators = r.validators();
    r.done();
    EpochState {
        epoch: number(&v["epoch"]),
        validators,
    }
}

/// A signed ledger info, `{"signed", "points"}`: `LedgerInfoWithSignatures`'s BCS and the signers' points.
pub fn signed(v: &Value) -> Signed {
    let b = bytes(&v["signed"]);
    let mut r = Reader::new(&b);
    let (ledger_info, bitmask, signature) = r.signed();
    r.done();
    Signed {
        ledger_info,
        bitmask,
        signature,
        points: list(&v["points"], bytes),
    }
}

/// A transaction, `{"version", "info", "siblings", "events"}`.
pub fn included(v: &Value) -> Included {
    let b = bytes(&v["info"]);
    let mut r = Reader::new(&b);
    let (info, _) = r.transaction_info();
    r.done();
    Included {
        version: number(&v["version"]),
        info,
        siblings: list(&v["siblings"], word),
        events: list(&v["events"], bytes),
    }
}

/// The update claim of a fixture: its `update` object, `{"trusted", "hops"}`.
pub fn update(f: &Value) -> Input {
    let u = &f["update"];
    Input::Update {
        trusted: epoch_state(&u["trusted"]),
        hops: list(&u["hops"], signed),
    }
}

/// The slots claim of a fixture: its `slots` object.
pub fn slots(f: &Value) -> Input {
    let s = &f["slots"];
    Input::Slots {
        trusted: epoch_state(&s["trusted"]),
        hops: list(&s["hops"], signed),
        ledger_info: signed(&s["ledger_info"]),
        transaction: included(&s["transaction"]),
        chain_id: number(&s["chain_id"]),
        package: word(&s["package"]),
        vault_id: word(&s["vault_id"]),
        timestamp: number(&s["timestamp"]),
        slots: list(&s["slots"], word),
        values: list(&s["values"], word),
    }
}
