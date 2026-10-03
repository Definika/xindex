//! The statement on Stellar mainnet (`fixtures/mainnet.json`, rebuilt by `examples/generate.rs`): Tier 1's quorum set
//! and its 30 validators' `EXTERNALIZE` envelopes for ledger N+1, that ledger's transaction set, header N, N's result
//! set, and the success preimage of a real Soroban call in N. No vault is deployed, so the event checked is that call's
//! own first contract event, written from its typed fields as the statement writes the vault's.

use serde_json::Value;
use stellar_xdr::{ContractEvent, ContractEventBody, ScpEnvelope, ScpStatementPledges};
use xindex_stellar::{quorum, sha256, verify, verify_event, xdr, Error, Input};

fn fixture() -> Value {
    serde_json::from_str(include_str!("../fixtures/mainnet.json")).unwrap()
}

fn bytes(v: &Value) -> Vec<u8> {
    hex::decode(v.as_str().unwrap()).unwrap()
}

fn input() -> (Input, ContractEvent) {
    let f = fixture();
    let events: Vec<Vec<u8>> = f["events"].as_array().unwrap().iter().map(bytes).collect();
    let event_index = f["eventIndex"].as_u64().unwrap() as u32;
    let expected: ContractEvent = xdr::decode(&events[event_index as usize], "event").unwrap();
    let input = Input {
        network_id: bytes(&f["networkId"]).try_into().unwrap(),
        quorum_set: bytes(&f["quorumSet"]),
        envelopes: f["envelopes"]
            .as_array()
            .unwrap()
            .iter()
            .map(bytes)
            .collect(),
        tx_set: bytes(&f["txSet"]),
        headers: f["headers"].as_array().unwrap().iter().map(bytes).collect(),
        result_set: bytes(&f["resultSet"]),
        result_index: f["resultIndex"].as_u64().unwrap() as u32,
        return_value: bytes(&f["returnValue"]),
        events,
        event_index,
        vault_id: [0; 32],
        record: Vec::new(),
    };
    (input, expected)
}

/// Pubnet's network id is SHA-256 of its passphrase, and every signed envelope starts with it.
#[test]
fn the_fixture_is_pubnet() {
    let f = fixture();
    assert_eq!(
        bytes(&f["networkId"]),
        sha256(&[f["source"]["passphrase"].as_str().unwrap().as_bytes()]).to_vec()
    );
    assert_eq!(
        f["source"]["passphrase"],
        "Public Global Stellar Network ; September 2015"
    );
}

#[test]
fn a_real_contract_event_in_a_real_externalized_ledger() {
    let (input, expected) = input();
    let f = fixture();
    let proven = verify_event(&input, &expected).expect("the statement holds on mainnet");
    assert_eq!(u64::from(proven.ledger), f["ledger"].as_u64().unwrap());
    assert_eq!(proven.close_time, f["closeTime"].as_u64().unwrap());
    assert_eq!(proven.quorum_set_hash, sha256(&[&input.quorum_set]));
    assert_eq!(input.envelopes.len(), 30, "all of Tier 1 signed");
}

/// Tier 1 is 7 of 10 organisations, each 2 of 3 validators, so 14 signatures suffice, and 13 never do.
#[test]
fn fourteen_signatures_of_seven_organisations_suffice() {
    let (input, expected) = input();
    let q = xdr::decode(&input.quorum_set, "q").unwrap();
    let org_of = |key: &[u8; 32]| -> usize {
        let q: &stellar_xdr::ScpQuorumSet = &q;
        q.inner_sets
            .iter()
            .position(|o| quorum::validators(o).contains(key))
            .unwrap()
    };
    let mut per_org = std::collections::BTreeMap::<usize, Vec<Vec<u8>>>::new();
    for raw in &input.envelopes {
        let e: ScpEnvelope = xdr::decode(raw, "e").unwrap();
        let stellar_xdr::NodeId(stellar_xdr::PublicKey::PublicKeyTypeEd25519(k)) =
            &e.statement.node_id;
        per_org.entry(org_of(&k.0)).or_default().push(raw.clone());
    }
    assert_eq!(per_org.len(), 10);
    let pick = |orgs: usize, per: usize| -> Vec<Vec<u8>> {
        per_org
            .values()
            .take(orgs)
            .flat_map(|v| v.iter().take(per).cloned())
            .collect()
    };
    let mut min = input.clone();
    min.envelopes = pick(7, 2);
    assert_eq!(min.envelopes.len(), 14);
    verify_event(&min, &expected).expect("a minimal quorum");
    let mut six = input.clone();
    six.envelopes = pick(6, 3);
    assert_eq!(
        verify_event(&six, &expected).unwrap_err(),
        Error::NotAQuorum
    );
    let mut ones = input.clone();
    ones.envelopes = pick(10, 1);
    assert_eq!(
        verify_event(&ones, &expected).unwrap_err(),
        Error::NotAQuorum
    );
}

#[test]
fn every_real_input_is_bound() {
    let (base, expected) = input();
    let check = |f: &dyn Fn(&mut Input), e: Error| {
        let mut input = base.clone();
        f(&mut input);
        assert_eq!(verify_event(&input, &expected).unwrap_err(), e);
    };
    // Another network: every signature fails.
    check(
        &|i| i.network_id = sha256(&[b"Test SDF Network ; September 2015"]),
        Error::BadSignature,
    );
    // A byte of one validator's signature.
    check(
        &|i| {
            let mut e: ScpEnvelope = xdr::decode(&i.envelopes[4], "e").unwrap();
            let mut s = e.signature.to_vec();
            s[10] ^= 1;
            e.signature = stellar_xdr::Signature(s.try_into().unwrap());
            i.envelopes[4] = xdr::encode(&e).unwrap();
        },
        Error::BadSignature,
    );
    // A byte of the transaction set, of the header, of the result set.
    check(
        &|i| {
            let n = i.tx_set.len();
            i.tx_set[n - 1] ^= 1;
        },
        Error::TxSetMismatch,
    );
    check(&|i| i.headers[0][100] ^= 1, Error::HeaderChainBroken);
    check(
        &|i| {
            let n = i.result_set.len();
            i.result_set[n - 9] ^= 1;
        },
        Error::ResultSetMismatch,
    );
    // Another result of the same ledger: one that is no Soroban success, and another Soroban success, whose preimage
    // this is not.
    let set: stellar_xdr::TransactionResultSet = xdr::decode(&base.result_set, "r").unwrap();
    let mine = base.result_index as usize;
    let not_soroban = (0..set.results.len())
        .find(|&k| xindex_stellar::success_hash(&set.results[k].result).is_none())
        .unwrap() as u32;
    check(&|i| i.result_index = not_soroban, Error::NotASuccess);
    let other_call = (0..set.results.len())
        .find(|&k| k != mine && xindex_stellar::success_hash(&set.results[k].result).is_some())
        .expect("another Soroban success in the ledger") as u32;
    check(&|i| i.result_index = other_call, Error::PreimageMismatch);
    // The return value or an event's data, changed.
    check(
        &|i| i.return_value = xdr::encode(&stellar_xdr::ScVal::U32(7)).unwrap(),
        Error::PreimageMismatch,
    );
    check(
        &|i| {
            let k = if i.event_index == 0 { 1 } else { 0 };
            let mut e: ContractEvent = xdr::decode(&i.events[k], "e").unwrap();
            let ContractEventBody::V0(v) = &mut e.body;
            v.data = stellar_xdr::ScVal::U32(1);
            i.events[k] = xdr::encode(&e).unwrap();
        },
        Error::PreimageMismatch,
    );
    // The value an envelope externalized, re-signed is impossible: changed, its signature fails first.
    check(
        &|i| {
            let mut e: ScpEnvelope = xdr::decode(&i.envelopes[0], "e").unwrap();
            if let ScpStatementPledges::Externalize(x) = &mut e.statement.pledges {
                x.n_h += 1;
            }
            i.envelopes[0] = xdr::encode(&e).unwrap();
        },
        Error::BadSignature,
    );
}

/// The production statement writes the vault's `attest` event and accepts nothing else: on the same real ledger, the
/// call's own event is not one, whatever vault id and record are claimed.
#[test]
fn the_real_event_is_no_attest() {
    let (mut input, expected) = input();
    let stellar_xdr::ContractEvent { contract_id, .. } = &expected;
    input.vault_id = contract_id.as_ref().unwrap().0 .0;
    input.record = b"anything".to_vec();
    assert_eq!(verify(&input).unwrap_err(), Error::NotTheEvent);
}
