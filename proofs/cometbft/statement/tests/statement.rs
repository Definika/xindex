//! The statement on Injective mainnet's own data (`fixtures/injective.json`, which `fixtures/generate.py` fetches and
//! checks with a separate implementation): a trusted header, a skipping hop half an hour on across validator-set
//! changes, an adjacent hop to `H+1`, and two slots of a real contract at `H`, one present and one absent. Every check
//! is then broken one at a time on the real data, and the two-thirds rule and the trusting period on chains of
//! generated keys, where a set can be made to sign anything.

use ics23::{commitment_proof::Proof, BatchEntry, BatchProof, CommitmentProof};
use prost::Message;
use serde_json::Value;
use tendermint::{
    block::{signed_header::SignedHeader, CommitSig, Header},
    validator::Set,
    Time,
};
use tendermint_light_client_verifier::{errors::VerificationErrorDetail, Verdict};
use tendermint_proto::{
    v0_38::types::{
        Header as RawHeader, SignedHeader as RawSignedHeader, ValidatorSet as RawValidatorSet,
    },
    Protobuf,
};
use tendermint_testgen::{
    light_block::TmLightBlock, Generator, Header as TestHeader, LightBlock as TestBlock, Validator,
};
use xindex_cometbft::json::{chain, hex, hex32, slots, state, update};
use xindex_cometbft::*;

fn fixture() -> Value {
    serde_json::from_str(include_str!("../../fixtures/injective.json")).unwrap()
}

fn decode_sh(b: &[u8]) -> SignedHeader {
    <SignedHeader as Protobuf<RawSignedHeader>>::decode_vec(b).unwrap()
}

fn encode_sh(sh: SignedHeader) -> Vec<u8> {
    <SignedHeader as Protobuf<RawSignedHeader>>::encode_vec(sh)
}

fn decode_header(b: &[u8]) -> Header {
    <Header as Protobuf<RawHeader>>::decode_vec(b).unwrap()
}

fn encode_header(h: Header) -> Vec<u8> {
    <Header as Protobuf<RawHeader>>::encode_vec(h)
}

fn decode_set(b: &[u8]) -> Set {
    <Set as Protobuf<RawValidatorSet>>::decode_vec(b).unwrap()
}

fn encode_set(s: Set) -> Vec<u8> {
    <Set as Protobuf<RawValidatorSet>>::encode_vec(s)
}

fn hop_error(r: Result<Output, Error>) -> (usize, Verdict) {
    match r {
        Err(Error::Hop { hop, verdict }) => (hop, *verdict),
        other => panic!("expected a refused hop, got {other:?}"),
    }
}

fn invalid(v: Verdict) -> VerificationErrorDetail {
    match v {
        Verdict::Invalid(d) => d,
        other => panic!("expected an invalid header, got {other:?}"),
    }
}

// ---------------------------------------------------------------------------
// mainnet
// ---------------------------------------------------------------------------

/// The update and the slots verify, and commit exactly the public values the separate implementation computed.
#[test]
fn mainnet_verifies() {
    let f = fixture();
    let out = verify(&update(&f)).expect("the update holds");
    assert_eq!(
        out.abi_encode(),
        hex(f["public_values"]["update"].as_str().unwrap())
    );
    let Output::Update { trusted, head, .. } = out else {
        panic!()
    };
    assert_eq!(trusted.height, f["trusted"]["height"].as_u64().unwrap());
    assert_eq!(trusted.hash, hex32(&f["trusted"]["hash"]));
    assert_eq!(trusted.time, f["trusted"]["time"].as_u64().unwrap());
    assert_eq!(head.height, f["head"]["height"].as_u64().unwrap());
    assert_eq!(head.hash, hex32(&f["head"]["hash"]));
    assert_eq!(head.time, f["head"]["time"].as_u64().unwrap());

    let out = verify(&slots(&f)).expect("the slots hold");
    assert_eq!(
        out.abi_encode(),
        hex(f["public_values"]["slots"].as_str().unwrap())
    );
    let Output::Slots {
        height,
        time,
        values,
        vault,
        ..
    } = out
    else {
        panic!()
    };
    assert_eq!(height, f["state"]["height"].as_u64().unwrap());
    assert_eq!(height + 1, f["head"]["height"].as_u64().unwrap());
    assert_eq!(time, f["state"]["time"].as_u64().unwrap());
    assert_eq!(vault.to_vec(), hex(f["state"]["vault"].as_str().unwrap()));
    let expected: Vec<Hash> = f["state"]["slots"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| hex32(&s["value"]))
        .collect();
    assert_eq!(values, expected, "the values eth_getStorageAt gives");
    assert_ne!(values[0], [0u8; 32], "a present slot");
    assert_eq!(values[1], [0u8; 32], "an absent slot reads as zero");
    assert!(
        f["checks"]["set_changed_between"].as_bool().unwrap(),
        "the skipping hop crosses a change of the validator set"
    );
}

/// A proof of slots may start from `H+1` itself, once the verifier trusts it: no hop, block `H` under its
/// `app_hash`. The public values then name `H+1` as the trusted header.
#[test]
fn slots_from_a_trusted_head() {
    let f = fixture();
    let hop = &f["hops"][1];
    let c = Chain {
        chain_id: "injective-1".into(),
        trusted_header: json::header(&hop["signed_header"]["header"]),
        trusted_next_validators: json::validators(&hop["next_validators"]),
        hops: vec![],
    };
    let Output::Slots {
        trusted, height, ..
    } = verify(&Input::Slots(c, state(&f))).unwrap()
    else {
        panic!()
    };
    assert_eq!(trusted.height, f["head"]["height"].as_u64().unwrap());
    assert_eq!(trusted.hash, hex32(&f["head"]["hash"]));
    assert_eq!(height, f["state"]["height"].as_u64().unwrap());
}

// ---------------------------------------------------------------------------
// the light client, broken on mainnet's data
// ---------------------------------------------------------------------------

/// Removes the strongest signatures of `set`'s members from `sh`'s commit until they hold at most two thirds of its
/// power.
fn down_to_two_thirds(sh: &mut SignedHeader, set: &Set) {
    let total: u64 = set.validators().iter().map(|v| v.power()).sum();
    let mut signed = total;
    for v in set.validators() {
        if 3 * signed <= 2 * total {
            break;
        }
        for s in sh.commit.signatures.iter_mut() {
            if s.validator_address() == Some(v.address) {
                *s = CommitSig::BlockIdFlagAbsent;
                signed -= v.power();
            }
        }
    }
    assert!(3 * signed <= 2 * total && 3 * signed > total);
}

/// The skipping hop signed by at most two thirds of the trusted set is refused for want of trust.
#[test]
fn a_skipping_hop_needs_more_than_two_thirds_of_the_trusted_set() {
    let f = fixture();
    let mut c = chain(&f, 2);
    let mut sh = decode_sh(&c.hops[0].signed_header);
    down_to_two_thirds(&mut sh, &decode_set(&c.trusted_next_validators));
    c.hops[0].signed_header = encode_sh(sh);
    let (hop, verdict) = hop_error(verify(&Input::Update(c)));
    assert_eq!(hop, 0);
    assert!(matches!(verdict, Verdict::NotEnoughTrust(_)), "{verdict:?}");
}

/// The adjacent hop signed by at most two thirds of its set, the trusted header's next one, is refused.
#[test]
fn an_adjacent_hop_needs_more_than_two_thirds_of_the_trusted_next_set() {
    let f = fixture();
    let mut c = chain(&f, 2);
    let mut sh = decode_sh(&c.hops[1].signed_header);
    down_to_two_thirds(&mut sh, &decode_set(&c.hops[0].next_validators));
    c.hops[1].signed_header = encode_sh(sh);
    let (hop, verdict) = hop_error(verify(&Input::Update(c)));
    assert_eq!(hop, 1);
    assert!(matches!(
        invalid(verdict),
        VerificationErrorDetail::InsufficientSignersOverlap(_)
    ));
}

/// The statement is for `injective-1` only: another chain id is refused, and a header of another chain cannot be
/// passed off, since the chain id is in every signed precommit and in the header's hash.
#[test]
fn the_chain_id_is_bound() {
    let f = fixture();
    let mut c = chain(&f, 2);
    c.chain_id = "injective-888".into();
    assert_eq!(verify(&Input::Update(c)), Err(Error::WrongChain));

    // A hop's header renamed is no longer the header its commit signed.
    let mut c = chain(&f, 2);
    let mut sh = decode_sh(&c.hops[0].signed_header);
    sh.header.chain_id = "injective-888".parse().unwrap();
    c.hops[0].signed_header = encode_sh(sh);
    let (_, verdict) = hop_error(verify(&Input::Update(c)));
    assert!(matches!(
        invalid(verdict),
        VerificationErrorDetail::InvalidCommitValue(_)
    ));

    // A trusted header of another chain does not lead to Injective's headers.
    let mut c = chain(&f, 2);
    let mut t = decode_header(&c.trusted_header);
    t.chain_id = "injective-888".parse().unwrap();
    c.trusted_header = encode_header(t);
    c.chain_id = "injective-888".into();
    let (_, verdict) = hop_error(verify(&Input::Update(c)));
    assert!(matches!(
        invalid(verdict),
        VerificationErrorDetail::ChainIdMismatch(_)
    ));
}

/// Raises one validator's power by one in `set`.
fn forge(set: &[u8]) -> Vec<u8> {
    let mut s = decode_set(set);
    let mut validators = s.validators().clone();
    validators[0].power = (validators[0].power() + 1).try_into().unwrap();
    s = Set::without_proposer(validators);
    encode_set(s)
}

/// Every validator set must be the one its header names: the trusted header's next set, each hop's set and next set.
#[test]
fn forged_validator_sets_are_refused() {
    let f = fixture();
    let mut c = chain(&f, 2);
    c.trusted_next_validators = forge(&c.trusted_next_validators);
    assert_eq!(verify(&Input::Update(c)), Err(Error::WrongNextValidators));

    let mut c = chain(&f, 2);
    c.hops[0].validators = forge(&c.hops[0].validators);
    let (hop, verdict) = hop_error(verify(&Input::Update(c)));
    assert_eq!(hop, 0);
    assert!(matches!(
        invalid(verdict),
        VerificationErrorDetail::InvalidValidatorSet(_)
    ));

    let mut c = chain(&f, 2);
    c.hops[0].next_validators = forge(&c.hops[0].next_validators);
    let (_, verdict) = hop_error(verify(&Input::Update(c)));
    assert!(matches!(
        invalid(verdict),
        VerificationErrorDetail::InvalidNextValidatorSet(_)
    ));

    // A hop before the last must bring the next set the following hop is checked against.
    let mut c = chain(&f, 2);
    c.hops[0].next_validators = vec![];
    assert_eq!(
        verify(&Input::Update(c)),
        Err(Error::MissingNextValidators { hop: 0 })
    );
    // The last hop may leave it out.
    let mut c = chain(&f, 2);
    c.hops[1].next_validators = vec![];
    assert!(verify(&Input::Update(c)).is_ok());
}

/// A header changed in any field is not the one the commit signed: its app hash, its time, its height.
#[test]
fn a_changed_header_is_not_the_signed_one() {
    let f = fixture();
    for change in 0..3 {
        let mut c = chain(&f, 2);
        let mut sh = decode_sh(&c.hops[1].signed_header);
        match change {
            0 => {
                sh.header.app_hash = vec![7u8; 32].try_into().unwrap();
            }
            1 => {
                sh.header.time = (sh.header.time + core::time::Duration::from_secs(1)).unwrap();
            }
            _ => {
                sh.header.last_results_hash = Some(tendermint::Hash::Sha256([1u8; 32]));
            }
        }
        c.hops[1].signed_header = encode_sh(sh);
        let (hop, verdict) = hop_error(verify(&Input::Update(c)));
        assert_eq!(hop, 1);
        assert!(matches!(
            invalid(verdict),
            VerificationErrorDetail::InvalidCommitValue(_)
        ));
    }
}

/// A forged signature, or one moved to another validator, fails the hop.
#[test]
fn a_bad_signature_fails_the_hop() {
    let f = fixture();
    let mut c = chain(&f, 2);
    let mut sh = decode_sh(&c.hops[1].signed_header);
    if let CommitSig::BlockIdFlagCommit {
        signature: Some(sig),
        ..
    } = &mut sh.commit.signatures[0]
    {
        let mut bytes = sig.as_bytes().to_vec();
        bytes[0] ^= 1;
        *sig = tendermint::Signature::new(bytes).unwrap().unwrap();
    } else {
        panic!("the first validator signed");
    }
    c.hops[1].signed_header = encode_sh(sh);
    let (_, verdict) = hop_error(verify(&Input::Update(c)));
    assert!(matches!(
        invalid(verdict),
        VerificationErrorDetail::InvalidSignature(_)
    ));

    let mut c = chain(&f, 2);
    let mut sh = decode_sh(&c.hops[1].signed_header);
    let first = sh.commit.signatures[0].clone();
    sh.commit.signatures[1] = first;
    c.hops[1].signed_header = encode_sh(sh);
    let (_, verdict) = hop_error(verify(&Input::Update(c)));
    assert!(matches!(
        invalid(verdict),
        VerificationErrorDetail::DuplicateValidator(_)
    ));
}

/// Hops go forward: the adjacent hop before the skipping one, or the same header twice, is refused; and an update needs
/// a hop.
#[test]
fn hops_go_forward() {
    let f = fixture();
    let mut c = chain(&f, 2);
    c.hops.reverse();
    c.hops[0].next_validators = json::validators(&f["hops"][1]["next_validators"]);
    assert!(matches!(verify(&Input::Update(c)), Err(Error::Hop { .. })));

    let mut c = chain(&f, 2);
    c.hops[1] = c.hops[0].clone();
    let (hop, _) = hop_error(verify(&Input::Update(c)));
    assert_eq!(hop, 1);

    let mut c = chain(&f, 2);
    c.hops.clear();
    assert_eq!(verify(&Input::Update(c)), Err(Error::NoHops));
}

/// Inputs that are not the protobuf they must be are refused.
#[test]
fn garbage_does_not_decode() {
    let f = fixture();
    let junk = vec![0xffu8; 7];
    let mut c = chain(&f, 2);
    c.trusted_header = junk.clone();
    assert_eq!(verify(&Input::Update(c)), Err(Error::Decode("header")));
    let mut c = chain(&f, 2);
    c.trusted_next_validators = junk.clone();
    assert_eq!(
        verify(&Input::Update(c)),
        Err(Error::Decode("validator set"))
    );
    let mut c = chain(&f, 2);
    c.hops[0].signed_header = junk.clone();
    assert_eq!(
        verify(&Input::Update(c)),
        Err(Error::Decode("signed header"))
    );
    let mut s = state(&f);
    s.store_proof = junk.clone();
    assert_eq!(
        verify(&Input::Slots(chain(&f, 2), s)),
        Err(Error::Decode("commitment proof"))
    );
    let mut s = state(&f);
    s.header = junk;
    assert_eq!(
        verify(&Input::Slots(chain(&f, 2), s)),
        Err(Error::Decode("header"))
    );
}

// ---------------------------------------------------------------------------
// the state, broken on mainnet's data
// ---------------------------------------------------------------------------

fn slots_with(f: &Value, s: State) -> Result<Output, Error> {
    verify(&Input::Slots(chain(f, 2), s))
}

/// Block `H` must be the parent of the last header: not another block, not the last header itself.
#[test]
fn the_state_is_the_parents() {
    let f = fixture();
    let mut s = state(&f);
    s.header = json::header(&f["trusted"]["header"]);
    assert_eq!(slots_with(&f, s), Err(Error::NotTheParent));
    // The hops stop at H: H's own header is not its parent.
    let c = chain(&f, 1);
    assert_eq!(
        verify(&Input::Slots(c, state(&f))),
        Err(Error::NotTheParent)
    );
    // H's time changed: another header, so not the parent.
    let mut s = state(&f);
    let mut h = decode_header(&s.header);
    h.time = (h.time + core::time::Duration::from_secs(1)).unwrap();
    s.header = encode_header(h);
    assert_eq!(slots_with(&f, s), Err(Error::NotTheParent));
}

/// The multistore proof opens the `evm` store under the last header's app hash and nowhere else.
#[test]
fn the_store_is_under_the_app_hash() {
    let f = fixture();
    let c = chain(&f, 2);
    let (_, last) = follow(&c).unwrap();
    let s = state(&f);
    assert!(prove_state(&last, &s).is_ok());
    // Another app hash.
    let mut other = last.clone();
    other.app_hash = vec![7u8; 32].try_into().unwrap();
    assert_eq!(prove_state(&other, &s), Err(Error::StoreProof));
    // Another root for the `evm` store.
    let mut s2 = state(&f);
    let mut p = CommitmentProof::decode(&s2.store_proof[..]).unwrap();
    if let Some(Proof::Exist(ex)) = &mut p.proof {
        ex.value[0] ^= 1;
    }
    s2.store_proof = p.encode_to_vec();
    assert_eq!(prove_state(&last, &s2), Err(Error::StoreProof));
    // Another store.
    let mut s3 = state(&f);
    let mut p = CommitmentProof::decode(&s3.store_proof[..]).unwrap();
    if let Some(Proof::Exist(ex)) = &mut p.proof {
        ex.key = b"bank".to_vec();
    }
    s3.store_proof = p.encode_to_vec();
    assert_eq!(prove_state(&last, &s3), Err(Error::StoreProof));
    // A slot's proof given as the store's.
    let mut s4 = state(&f);
    s4.store_proof = s4.slots[1].proof.clone();
    assert_eq!(prove_state(&last, &s4), Err(Error::StoreProof));
}

/// A slot's value is the one its leaf holds: any other is not under the root.
#[test]
fn a_tampered_value_is_refused() {
    let f = fixture();
    let mut s = state(&f);
    let mut p = CommitmentProof::decode(&s.slots[0].proof[..]).unwrap();
    if let Some(Proof::Exist(ex)) = &mut p.proof {
        ex.value[31] ^= 1;
    }
    s.slots[0].proof = p.encode_to_vec();
    assert_eq!(slots_with(&f, s), Err(Error::SlotProof { slot: 0 }));
}

/// The key is the vault's: the same proofs for another address prove nothing.
#[test]
fn a_key_under_another_address_is_refused() {
    let f = fixture();
    let mut s = state(&f);
    s.vault[19] ^= 1;
    assert_eq!(slots_with(&f, s), Err(Error::SlotProof { slot: 0 }));
    // The absent slot alone, for another address: its neighbours do not bracket that key.
    let mut s = state(&f);
    s.vault[0] ^= 0x80;
    s.slots.remove(0);
    assert_eq!(slots_with(&f, s), Err(Error::SlotProof { slot: 0 }));
}

/// A present key cannot be proven absent, nor an absent one present, nor one slot by another's proof.
#[test]
fn presence_and_absence_cannot_be_swapped() {
    let f = fixture();
    // The absent slot's non-existence proof, claimed for the present slot.
    let mut s = state(&f);
    s.slots[0].proof = s.slots[1].proof.clone();
    assert_eq!(slots_with(&f, s), Err(Error::SlotProof { slot: 0 }));
    // The present slot's existence proof, claimed for the absent slot.
    let mut s = state(&f);
    s.slots[1].proof = s.slots[0].proof.clone();
    assert_eq!(slots_with(&f, s), Err(Error::SlotProof { slot: 1 }));
    // The slots swapped, each with the other's proof.
    let mut s = state(&f);
    let (a, b) = (s.slots[0].slot, s.slots[1].slot);
    s.slots[0].slot = b;
    s.slots[1].slot = a;
    assert_eq!(slots_with(&f, s), Err(Error::SlotProof { slot: 0 }));
    // A non-existence proof that leaves out a neighbour no longer shows the key absent.
    let mut s = state(&f);
    let mut p = CommitmentProof::decode(&s.slots[1].proof[..]).unwrap();
    if let Some(Proof::Nonexist(non)) = &mut p.proof {
        non.left = None;
    }
    s.slots[1].proof = p.encode_to_vec();
    assert_eq!(slots_with(&f, s), Err(Error::SlotProof { slot: 1 }));
}

/// Only a plain existence or non-existence proof is taken, never a batch.
#[test]
fn only_plain_proofs() {
    let f = fixture();
    let mut s = state(&f);
    let p = CommitmentProof::decode(&s.slots[0].proof[..]).unwrap();
    let Some(Proof::Exist(ex)) = p.proof else {
        panic!()
    };
    let batch = CommitmentProof {
        proof: Some(Proof::Batch(BatchProof {
            entries: vec![BatchEntry {
                proof: Some(ics23::batch_entry::Proof::Exist(ex)),
            }],
        })),
    };
    s.slots[0].proof = batch.encode_to_vec();
    assert_eq!(slots_with(&f, s), Err(Error::SlotProof { slot: 0 }));
}

/// What the EVM reads for the bytes the store holds: `common.BytesToHash`.
#[test]
fn values_are_what_get_state_reads() {
    let mut full = [0u8; 32];
    full[0] = 1;
    full[31] = 2;
    assert_eq!(evm_value(&full), full);
    let mut short = [0u8; 32];
    short[31] = 5;
    assert_eq!(evm_value(&[5]), short);
    assert_eq!(evm_value(&[]), [0u8; 32]);
    let mut long = vec![9u8];
    long.extend_from_slice(&full);
    assert_eq!(evm_value(&long), full);
    assert_eq!(
        storage_key(&[0xaa; 20], &[0xbb; 32]),
        [vec![2u8], vec![0xaa; 20], vec![0xbb; 32]].concat()
    );
}

/// The public values' encodings, word by word.
#[test]
fn public_values_layout() {
    let f = fixture();
    let pv = verify(&slots(&f)).unwrap().abi_encode();
    assert_eq!(pv.len(), 9 * 32);
    assert_eq!(pv[..32], slots_kind());
    assert_eq!(pv[32..64], keccak(&[b"injective-1"]));
    let pv = verify(&update(&f)).unwrap().abi_encode();
    assert_eq!(pv.len(), 8 * 32);
    assert_eq!(pv[..32], update_kind());
    assert_ne!(update_kind(), slots_kind());
}

// ---------------------------------------------------------------------------
// the two-thirds rule and the trusting period, on generated keys
// ---------------------------------------------------------------------------

const T0: i64 = 1_791_000_000;

fn validators(names: &[&str]) -> Vec<Validator> {
    names
        .iter()
        .map(|n| Validator::new(n).voting_power(10))
        .collect()
}

fn block(height: u64, time: i64, vals: &[Validator], next: &[Validator]) -> TmLightBlock {
    let header = TestHeader::new(vals)
        .next_validators(next)
        .height(height)
        .chain_id("injective-1")
        .time(Time::from_unix_timestamp(time, 0).unwrap());
    TestBlock::new_default_with_header(header)
        .next_validators(next)
        .generate()
        .unwrap()
}

fn synthetic(trusted: &TmLightBlock, hops: &[&TmLightBlock]) -> Input {
    Input::Update(Chain {
        chain_id: "injective-1".into(),
        trusted_header: encode_header(trusted.signed_header.header.clone()),
        trusted_next_validators: encode_set(trusted.next_validators.clone()),
        hops: hops
            .iter()
            .map(|b| Hop {
                signed_header: encode_sh(b.signed_header.clone()),
                validators: encode_set(b.validators.clone()),
                next_validators: encode_set(b.next_validators.clone()),
            })
            .collect(),
    })
}

/// A new set that every one of its members signed, but that shares only two thirds of the trusted set's power, is
/// refused: ibc-go's third would take it. Three quarters of the trusted set is enough.
#[test]
fn two_thirds_of_the_trusted_set_and_no_less() {
    let abc = validators(&["a", "b", "c"]);
    let trusted = block(10, T0, &abc, &abc);

    let two_of_three = validators(&["a", "b", "d", "e", "f", "g"]);
    let u = block(20, T0 + 60, &two_of_three, &two_of_three);
    let (hop, verdict) = hop_error(verify(&synthetic(&trusted, &[&u])));
    assert_eq!(hop, 0);
    let Verdict::NotEnoughTrust(tally) = verdict else {
        panic!("{verdict:?}")
    };
    assert_eq!((tally.tallied, tally.total), (20, 30));

    let abcd = validators(&["a", "b", "c", "d"]);
    let trusted4 = block(10, T0, &abcd, &abcd);
    let three_of_four = validators(&["a", "b", "c", "e"]);
    let u = block(20, T0 + 60, &three_of_four, &three_of_four);
    assert!(verify(&synthetic(&trusted4, &[&u])).is_ok());
}

/// An adjacent header whose set is not the trusted header's next set is refused, whoever signed it.
#[test]
fn an_adjacent_header_is_the_next_sets() {
    let abc = validators(&["a", "b", "c"]);
    let trusted = block(10, T0, &abc, &abc);
    let def = validators(&["d", "e", "f"]);
    let u = block(11, T0 + 1, &def, &def);
    let (_, verdict) = hop_error(verify(&synthetic(&trusted, &[&u])));
    assert!(matches!(
        invalid(verdict),
        VerificationErrorDetail::InvalidNextValidatorSet(_)
    ));
}

/// A set is trusted for a day after its header: a hop a day on is refused, a second less is taken.
#[test]
fn a_set_is_trusted_for_a_day() {
    let abc = validators(&["a", "b", "c"]);
    let trusted = block(10, T0, &abc, &abc);
    let late = block(20, T0 + MAX_LAG as i64, &abc, &abc);
    let (_, verdict) = hop_error(verify(&synthetic(&trusted, &[&late])));
    assert!(matches!(
        invalid(verdict),
        VerificationErrorDetail::NotWithinTrustPeriod(_)
    ));
    let in_time = block(20, T0 + MAX_LAG as i64 - 1, &abc, &abc);
    assert!(verify(&synthetic(&trusted, &[&in_time])).is_ok());
    // Over two hops, each set is timed from the last header: the first set too.
    let mid = block(15, T0 + 100, &abc, &abc);
    let (hop, _) = hop_error(verify(&synthetic(&trusted, &[&mid, &late])));
    assert_eq!(hop, 0);
}

/// A header before 1970 has no time the EVM could give it.
#[test]
fn times_before_1970_are_refused() {
    let abc = validators(&["a", "b", "c"]);
    let trusted = block(10, -100, &abc, &abc);
    let u = block(20, -50, &abc, &abc);
    assert_eq!(verify(&synthetic(&trusted, &[&u])), Err(Error::BadTime));
}
