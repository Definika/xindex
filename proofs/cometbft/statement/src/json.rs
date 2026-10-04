//! The statement's input from CometBFT's RPC replies, as `fixtures/generate.py` stores them: `/commit`'s signed header,
//! `/validators`' list, and `abci_query`'s proof operations in hex. For the host and the tests; the program reads only
//! the protobuf this writes.

use serde_json::Value;
use tendermint::{
    block::{signed_header::SignedHeader, Header},
    validator::{Info, Set},
};
use tendermint_proto::{
    v0_38::types::{
        Header as RawHeader, SignedHeader as RawSignedHeader, ValidatorSet as RawValidatorSet,
    },
    Protobuf,
};

use crate::{Chain, Hash, Hop, Input, Slot, State};

pub fn hex(s: &str) -> Vec<u8> {
    let s = s.trim_start_matches("0x");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex"))
        .collect()
}

pub fn hex32(v: &Value) -> Hash {
    hex(v.as_str().expect("a hex string"))
        .try_into()
        .expect("32 bytes")
}

/// `/commit`'s `signed_header` as protobuf.
pub fn signed_header(v: &Value) -> Vec<u8> {
    let sh: SignedHeader = serde_json::from_value(v.clone()).expect("a signed header");
    <SignedHeader as Protobuf<RawSignedHeader>>::encode_vec(sh)
}

/// A header as protobuf.
pub fn header(v: &Value) -> Vec<u8> {
    let h: Header = serde_json::from_value(v.clone()).expect("a header");
    <Header as Protobuf<RawHeader>>::encode_vec(h)
}

/// `/validators`' list as a `ValidatorSet`'s protobuf, in CometBFT's order.
pub fn validators(v: &Value) -> Vec<u8> {
    let infos: Vec<Info> = serde_json::from_value(v.clone()).expect("validators");
    <Set as Protobuf<RawValidatorSet>>::encode_vec(Set::without_proposer(infos))
}

/// The fixture's chain: the trusted header and its next set, and the first `hops` of its hops.
pub fn chain(f: &Value, hops: usize) -> Chain {
    Chain {
        chain_id: f["chain_id"].as_str().unwrap().to_string(),
        trusted_header: header(&f["trusted"]["header"]),
        trusted_next_validators: validators(&f["trusted"]["next_validators"]),
        hops: f["hops"].as_array().unwrap()[..hops]
            .iter()
            .map(|h| Hop {
                signed_header: signed_header(&h["signed_header"]),
                validators: validators(&h["validators"]),
                next_validators: validators(&h["next_validators"]),
            })
            .collect(),
    }
}

/// The fixture's state: block `H`, the vault, the multistore proof and the slots.
pub fn state(f: &Value) -> State {
    let s = &f["state"];
    State {
        header: header(&s["header"]),
        vault: hex(s["vault"].as_str().unwrap()).try_into().unwrap(),
        store_proof: hex(s["store_proof"].as_str().unwrap()),
        slots: s["slots"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| Slot {
                slot: hex32(&x["slot"]),
                proof: hex(x["proof"].as_str().unwrap()),
            })
            .collect(),
    }
}

/// The update the fixture commits: every hop.
pub fn update(f: &Value) -> Input {
    Input::Update(chain(f, f["hops"].as_array().unwrap().len()))
}

/// The slots the fixture commits: every hop, to `H+1`, then the state.
pub fn slots(f: &Value) -> Input {
    Input::Slots(chain(f, f["hops"].as_array().unwrap().len()), state(f))
}
