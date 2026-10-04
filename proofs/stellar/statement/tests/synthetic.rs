//! The statement on a synthetic Stellar (`testkit`), through the production path: the vault's `attest` event, written
//! by the statement itself. Every check is broken once and must fail with its own error.

use stellar_xdr::{
    ContractEvent, ContractEventBody, ContractId, Hash, LedgerHeader, ScSymbol, ScVal, ScpEnvelope,
    ScpQuorumSet, ScpStatementPledges, TransactionResultResult, TransactionResultSet,
};
use xindex_stellar::{testkit, verify, xdr, Error, Input};

fn ok(input: &Input) {
    let out = verify(input).expect("the statement holds");
    assert_eq!(out.proven.ledger, testkit::LEDGER);
    assert_eq!(out.proven.close_time, testkit::CLOSE_TIME);
    assert_eq!(out.vault_id, testkit::VAULT);
    assert_eq!(out.record_hash, xindex_stellar::keccak256(&input.record));
    assert_eq!(
        out.proven.quorum_set_hash,
        xindex_stellar::sha256(&[&input.quorum_set])
    );
}

fn fails(input: &Input, e: Error) {
    assert_eq!(verify(input).unwrap_err(), e);
}

fn edit<T: stellar_xdr::ReadXdr + stellar_xdr::WriteXdr>(
    bytes: &mut Vec<u8>,
    f: impl FnOnce(&mut T),
) {
    let mut v: T = xdr::decode(bytes, "test").unwrap();
    f(&mut v);
    *bytes = xdr::encode(&v).unwrap();
}

#[test]
fn seven_organisations_of_two_externalize_the_attest() {
    let input = testkit::build(7, 1);
    ok(&input);
    // All ten organisations, all three validators each: more signers change nothing.
    let mut all = input.clone();
    let keys = testkit::keys();
    let e: ScpEnvelope = xdr::decode(&input.envelopes[0], "e").unwrap();
    let ScpStatementPledges::Externalize(x) = &e.statement.pledges else {
        panic!()
    };
    all.envelopes = keys
        .iter()
        .flatten()
        .map(|k| {
            let env = testkit::envelope(
                k,
                &testkit::NETWORK_ID,
                e.statement.slot_index,
                x.commit.value.as_slice(),
                x.commit_quorum_set_hash.0,
            );
            xdr::encode(&env).unwrap()
        })
        .collect();
    ok(&all);
    // A longer gap between the attested ledger and the externalized one.
    ok(&testkit::build(7, 5));
}

#[test]
fn the_quorum_must_satisfy_q() {
    fails(&testkit::build(6, 1), Error::NotAQuorum);
    // Seven organisations, one of them with a single validator.
    let mut input = testkit::build(7, 1);
    input.envelopes.pop();
    fails(&input, Error::NotAQuorum);
    let mut none = testkit::build(7, 1);
    none.envelopes.clear();
    fails(&none, Error::NoEnvelopes);
}

#[test]
fn every_envelope_must_be_a_signed_externalize_of_the_slot_and_the_value() {
    let base = testkit::build(7, 1);
    // A bad signature.
    let mut input = base.clone();
    edit::<ScpEnvelope>(&mut input.envelopes[3], |e| {
        let mut s = e.signature.to_vec();
        s[0] ^= 1;
        e.signature = stellar_xdr::Signature(s.try_into().unwrap());
    });
    fails(&input, Error::BadSignature);
    // Signed on another network.
    let mut other = base.clone();
    other.network_id[0] ^= 1;
    fails(&other, Error::BadSignature);
    // A signature that is not 64 bytes.
    let mut short = base.clone();
    edit::<ScpEnvelope>(&mut short.envelopes[0], |e| {
        e.signature = stellar_xdr::Signature(vec![0u8; 63].try_into().unwrap());
    });
    fails(&short, Error::BadSignature);
    // Another slot.
    let mut slot = base.clone();
    edit::<ScpEnvelope>(&mut slot.envelopes[2], |e| e.statement.slot_index += 1);
    fails(&slot, Error::WrongSlot);
    // Another value from one signer.
    let mut value = base.clone();
    edit::<ScpEnvelope>(&mut value.envelopes[5], |e| {
        if let ScpStatementPledges::Externalize(x) = &mut e.statement.pledges {
            let mut v = x.commit.value.to_vec();
            v[0] ^= 1;
            x.commit.value = stellar_xdr::Value(v.try_into().unwrap());
        }
    });
    fails(&value, Error::ValuesDiffer);
    // A CONFIRM, not an EXTERNALIZE.
    let mut confirm = base.clone();
    edit::<ScpEnvelope>(&mut confirm.envelopes[0], |e| {
        if let ScpStatementPledges::Externalize(x) = &e.statement.pledges {
            e.statement.pledges = ScpStatementPledges::Confirm(stellar_xdr::ScpStatementConfirm {
                ballot: x.commit.clone(),
                n_prepared: 1,
                n_commit: 1,
                n_h: 1,
                quorum_set_hash: x.commit_quorum_set_hash.clone(),
            });
        }
    });
    fails(&confirm, Error::NotExternalize);
    // The same signer twice.
    let mut twice = base.clone();
    twice.envelopes.push(base.envelopes[0].clone());
    fails(&twice, Error::DuplicateSigner);
    // A key Q does not name, even with a valid signature.
    let mut stranger = base.clone();
    let key = ed25519_dalek::SigningKey::from_bytes(&[9u8; 32]);
    let e: ScpEnvelope = xdr::decode(&base.envelopes[0], "e").unwrap();
    let ScpStatementPledges::Externalize(x) = &e.statement.pledges else {
        panic!()
    };
    let env = testkit::envelope(
        &key,
        &testkit::NETWORK_ID,
        e.statement.slot_index,
        x.commit.value.as_slice(),
        x.commit_quorum_set_hash.0,
    );
    stranger.envelopes.push(xdr::encode(&env).unwrap());
    fails(&stranger, Error::UnknownSigner);
}

#[test]
fn the_value_opens_to_the_next_ledgers_set_and_its_previous_header() {
    let base = testkit::build(7, 1);
    let mut set = base.clone();
    set.tx_set.push(0);
    fails(&set, Error::TxSetMismatch);
    // A value whose set is not generalized: version 0 under a re-signed value.
    let rebuild = |tx_set: Vec<u8>| {
        let mut input = base.clone();
        let keys = testkit::keys();
        let e: ScpEnvelope = xdr::decode(&base.envelopes[0], "e").unwrap();
        let ScpStatementPledges::Externalize(x) = &e.statement.pledges else {
            panic!()
        };
        let mut value: stellar_xdr::StellarValue =
            xdr::decode(x.commit.value.as_slice(), "v").unwrap();
        value.tx_set_hash = Hash(xindex_stellar::sha256(&[&tx_set]));
        let value = xdr::encode(&value).unwrap();
        input.envelopes = testkit::signers(&keys, 7)
            .into_iter()
            .map(|k| {
                let env = testkit::envelope(
                    k,
                    &testkit::NETWORK_ID,
                    e.statement.slot_index,
                    &value,
                    x.commit_quorum_set_hash.0,
                );
                xdr::encode(&env).unwrap()
            })
            .collect();
        input.tx_set = tx_set;
        input
    };
    let mut v0 = base.tx_set.clone();
    v0[3] = 0;
    fails(&rebuild(v0), Error::NotGeneralized);
    fails(&rebuild(vec![0, 0, 0, 1]), Error::NotGeneralized);
    // A generalized set naming another previous header.
    let mut prev = base.tx_set.clone();
    prev[4] ^= 1;
    fails(&rebuild(prev), Error::HeaderChainBroken);
    // The unchanged set, re-signed: the helper itself is sound.
    ok(&rebuild(base.tx_set.clone()));
}

#[test]
fn the_headers_link_back_to_the_attested_ledger() {
    let base = testkit::build(7, 3);
    ok(&base);
    let mut broken = base.clone();
    edit::<LedgerHeader>(&mut broken.headers[1], |h| h.previous_ledger_hash.0[0] ^= 1);
    fails(&broken, Error::HeaderChainBroken);
    let mut seq = base.clone();
    edit::<LedgerHeader>(&mut seq.headers[1], |h| h.ledger_seq += 1);
    fails(&seq, Error::HeaderChainBroken);
    // The externalized slot follows the last header: drop it and the slot no longer matches.
    let mut short = base.clone();
    short.headers.pop();
    fails(&short, Error::WrongSlot);
    let mut none = base.clone();
    none.headers.clear();
    fails(&none, Error::NoHeaders);
    let mut many = base.clone();
    many.headers = vec![base.headers[0].clone(); xindex_stellar::MAX_HEADERS + 1];
    fails(&many, Error::TooManyHeaders);
    let mut old = testkit::build(7, 1);
    edit::<LedgerHeader>(&mut old.headers[0], |h| h.ledger_version = 19);
    fails(&old, Error::OldLedgerVersion);
}

#[test]
fn the_result_must_be_a_successful_call_whose_preimage_holds_the_attest() {
    let base = testkit::build(7, 1);
    let mut set = base.clone();
    set.result_set.push(0);
    fails(&set, Error::ResultSetMismatch);
    let mut index = base.clone();
    index.result_index = 2;
    fails(&index, Error::NoSuchResult);
    // Result 0 is a success of another call: its preimage is not this one.
    let mut other = base.clone();
    other.result_index = 0;
    fails(&other, Error::PreimageMismatch);
    // The event list changed in any way changes the preimage.
    let mut dropped = base.clone();
    dropped.events.remove(0);
    dropped.event_index = 0;
    fails(&dropped, Error::PreimageMismatch);
    let mut ret = base.clone();
    ret.return_value = xdr::encode(&ScVal::Bool(true)).unwrap();
    fails(&ret, Error::PreimageMismatch);
    let mut event = base.clone();
    event.event_index = 2;
    fails(&event, Error::NoSuchEvent);
    let mut not_it = base.clone();
    not_it.event_index = 0;
    fails(&not_it, Error::NotTheEvent);
    // Another record, another vault: the expected event differs from the one the preimage holds.
    let mut record = base.clone();
    record.record[0] ^= 1;
    fails(&record, Error::NotTheEvent);
    let mut vault = base.clone();
    vault.vault_id[0] ^= 1;
    fails(&vault, Error::NotTheEvent);
}

/// A failed or non-Soroban result is no success, whatever its operations say.
#[test]
fn only_a_successful_invoke_counts() {
    let base = testkit::build(7, 1);
    let set: TransactionResultSet = xdr::decode(&base.result_set, "r").unwrap();
    let pair = &set.results[1];
    assert!(xindex_stellar::success_hash(&pair.result).is_some());
    let mut failed = pair.result.clone();
    if let TransactionResultResult::TxSuccess(ops) = &failed.result {
        failed.result = TransactionResultResult::TxFailed(ops.clone());
    }
    assert_eq!(xindex_stellar::success_hash(&failed), None);
    let mut two = pair.result.clone();
    if let TransactionResultResult::TxSuccess(ops) = &two.result {
        let mut v = ops.to_vec();
        v.push(v[0].clone());
        two.result = TransactionResultResult::TxSuccess(v.try_into().unwrap());
    }
    assert_eq!(xindex_stellar::success_hash(&two), None);
    let mut no_ops = pair.result.clone();
    no_ops.result = TransactionResultResult::TxSuccess(Default::default());
    assert_eq!(xindex_stellar::success_hash(&no_ops), None);
    // Through a fee bump, an inner success counts, and an inner failure does not.
    let inner =
        |result: stellar_xdr::InnerTransactionResultResult| stellar_xdr::TransactionResult {
            fee_charged: 1,
            result: TransactionResultResult::TxFeeBumpInnerSuccess(
                stellar_xdr::InnerTransactionResultPair {
                    transaction_hash: Hash([1; 32]),
                    result: stellar_xdr::InnerTransactionResult {
                        fee_charged: 1,
                        result,
                        ext: stellar_xdr::InnerTransactionResultExt::V0,
                    },
                },
            ),
            ext: stellar_xdr::TransactionResultExt::V0,
        };
    let TransactionResultResult::TxSuccess(ops) = &pair.result.result else {
        panic!()
    };
    assert_eq!(
        xindex_stellar::success_hash(&inner(
            stellar_xdr::InnerTransactionResultResult::TxSuccess(ops.clone())
        )),
        xindex_stellar::success_hash(&pair.result)
    );
    assert_eq!(
        xindex_stellar::success_hash(&inner(stellar_xdr::InnerTransactionResultResult::TxFailed(
            ops.clone()
        ))),
        None
    );
}

/// An event's bytes are decoded, never trusted: a byte string shaped like the attest event, hidden in another value,
/// is not an event, and a non-canonical encoding of any input is refused.
#[test]
fn inputs_are_strict_xdr() {
    let base = testkit::build(7, 1);
    let mut trailing = base.clone();
    trailing.events[1].push(0);
    fails(&trailing, Error::BadXdr("event"));
    let mut ret = base.clone();
    ret.return_value.push(0);
    fails(&ret, Error::BadXdr("return value"));
    let mut q = base.clone();
    q.quorum_set.push(0);
    fails(&q, Error::BadXdr("quorum set"));
    let mut header = base.clone();
    header.headers[0].extend_from_slice(&[0, 0, 0, 0]);
    fails(&header, Error::BadXdr("header"));
    let mut env = base.clone();
    env.envelopes[0].pop();
    fails(&env, Error::BadXdr("envelope"));
    // The attest event's own bytes, as the return value's data: the preimage then holds no attest event at all.
    let mut hidden = base.clone();
    let attest = hidden.events[1].clone();
    hidden.return_value = xdr::encode(&testkit::bytes_val(&attest)).unwrap();
    hidden.events.remove(1);
    hidden.event_index = 0;
    fails(&hidden, Error::NotTheEvent);
    // An event of the right shape whose topic or type differs is not the attest.
    let mut topic = base.clone();
    edit::<ContractEvent>(&mut topic.events[1], |e| {
        let ContractEventBody::V0(v) = &mut e.body;
        v.topics = vec![ScVal::Symbol(ScSymbol("attesT".try_into().unwrap()))]
            .try_into()
            .unwrap();
    });
    fails(&topic, Error::NotTheEvent);
    let mut system = base.clone();
    edit::<ContractEvent>(&mut system.events[1], |e| {
        e.type_ = stellar_xdr::ContractEventType::System
    });
    fails(&system, Error::NotTheEvent);
    let mut anonymous = base.clone();
    edit::<ContractEvent>(&mut anonymous.events[1], |e| e.contract_id = None);
    fails(&anonymous, Error::NotTheEvent);
    let mut other = base.clone();
    edit::<ContractEvent>(&mut other.events[1], |e| {
        e.contract_id = Some(ContractId(Hash([1; 32])))
    });
    fails(&other, Error::NotTheEvent);
}

#[test]
fn the_quorum_set_must_be_sane() {
    let base = testkit::build(7, 1);
    let with = |f: &dyn Fn(&mut ScpQuorumSet)| {
        let mut input = base.clone();
        edit::<ScpQuorumSet>(&mut input.quorum_set, f);
        input
    };
    // VecM has no mutable indexing: an inner set is rewritten through a copy.
    let inner = |q: &mut ScpQuorumSet, i: usize, f: &dyn Fn(&mut ScpQuorumSet)| {
        let mut sets = q.inner_sets.to_vec();
        f(&mut sets[i]);
        q.inner_sets = sets.try_into().unwrap();
    };
    fails(&with(&|q| q.threshold = 0), Error::BadQuorumSet);
    fails(&with(&|q| q.threshold = 11), Error::BadQuorumSet);
    fails(
        &with(&|q| inner(q, 0, &|s| s.threshold = 0)),
        Error::BadQuorumSet,
    );
    fails(
        &with(&|q| inner(q, 0, &|s| s.threshold = 4)),
        Error::BadQuorumSet,
    );
    fails(
        &with(&|q| {
            let dup = q.inner_sets[0].validators[0].clone();
            inner(q, 1, &|s| {
                let mut v = s.validators.to_vec();
                v[0] = dup.clone();
                s.validators = v.try_into().unwrap();
            });
        }),
        Error::BadQuorumSet,
    );
    // Five levels of nesting below the top set, one more than stellar-core allows.
    let deep = with(&|q| {
        let mut inner = q.inner_sets[0].clone();
        for _ in 0..5 {
            inner = ScpQuorumSet {
                threshold: 1,
                validators: Default::default(),
                inner_sets: vec![inner].try_into().unwrap(),
            };
        }
        q.inner_sets = vec![inner].try_into().unwrap();
        q.threshold = 1;
    });
    fails(&deep, Error::BadQuorumSet);
    // Another quorum set, sane, that the signers do not satisfy: three organisations must all sign twice.
    let three = with(&|q| {
        let v = q.inner_sets.to_vec();
        q.inner_sets = vec![v[7].clone(), v[8].clone(), v[9].clone()]
            .try_into()
            .unwrap();
        q.threshold = 3;
    });
    fails(&three, Error::UnknownSigner);
}

/// stellar-core allows inner sets four levels below the top one, and no deeper (`MAXIMUM_QUORUM_NESTING_LEVEL`).
#[test]
fn nesting_stops_at_stellar_cores_limit() {
    let base: ScpQuorumSet = xdr::decode(&testkit::build(7, 1).quorum_set, "q").unwrap();
    let wrapped = |levels: usize| {
        let mut inner = base.inner_sets[0].clone();
        for _ in 0..levels {
            inner = ScpQuorumSet {
                threshold: 1,
                validators: Default::default(),
                inner_sets: vec![inner].try_into().unwrap(),
            };
        }
        ScpQuorumSet {
            threshold: 1,
            validators: Default::default(),
            inner_sets: vec![inner].try_into().unwrap(),
        }
    };
    // Three wrappers put the organisation's validators four levels down: allowed. Four put them five down: not.
    assert_eq!(xindex_stellar::quorum::check_sane(&wrapped(3)), Ok(()));
    assert_eq!(
        xindex_stellar::quorum::check_sane(&wrapped(4)),
        Err(Error::BadQuorumSet)
    );
}

/// XDR pads opaque data to four bytes with zeros; stellar-xdr refuses any other padding, so a value cannot be given two
/// encodings. The statement's write-back check would refuse it too, as a second line.
#[test]
fn non_zero_padding_is_refused() {
    let base = testkit::build(7, 1);
    let mut input = base.clone();
    // A record is whole words: give the attest event three bytes of data instead, then set a padding byte.
    let mut event: ContractEvent = xdr::decode(&input.events[1], "e").unwrap();
    let ContractEventBody::V0(v) = &mut event.body;
    v.data = testkit::bytes_val(&[1, 2, 3]);
    let mut raw = xdr::encode(&event).unwrap();
    let n = raw.len();
    assert_eq!(raw[n - 1], 0, "the padding byte");
    raw[n - 1] = 1;
    input.events[1] = raw;
    assert_eq!(verify(&input).unwrap_err(), Error::BadXdr("event"));
}

#[test]
fn the_public_values_are_six_words() {
    let input = testkit::build(7, 1);
    let out = verify(&input).unwrap();
    let words = out.abi_encode();
    assert_eq!(words.len(), 192);
    assert_eq!(&words[..32], &testkit::NETWORK_ID);
    assert_eq!(&words[32..64], &out.proven.quorum_set_hash);
    assert_eq!(&words[88..96], &u64::from(testkit::LEDGER).to_be_bytes());
    assert_eq!(&words[120..128], &testkit::CLOSE_TIME.to_be_bytes());
    assert_eq!(&words[128..160], &testkit::VAULT);
    assert_eq!(&words[160..192], &out.record_hash);
}
