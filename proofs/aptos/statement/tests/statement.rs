//! The statement on mainnet's own data (`fixtures/mainnet.json`), on the synthetic claims the Solidity tests use
//! (`fixtures/synthetic.json`), and on test chains (`testkit`), each check broken in turn.

use serde_json::Value;
use xindex_aptos::json::{self, hex};
use xindex_aptos::testkit::{self, Claim};
use xindex_aptos::{
    bcs, check, follow, prove_event, set_hash, verify, EpochState, Error, Included, Input, Output,
    Signed, TransactionInfo, Word, ATTEST_DOMAIN, SLOTS, UPDATE,
};

fn fixture(name: &str) -> Value {
    let path = format!("{}/../fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&std::fs::read_to_string(path).expect("the fixture")).expect("JSON")
}

// ---------------------------------------------------------------------------
// constants
// ---------------------------------------------------------------------------

/// B6-03: the three domain words are hex literals in the statement, parsed by a `const fn` that reads the first 64
/// digits, so nothing but this test ties each to its name. They tell the two claims apart (`UPDATE`, `SLOTS`) and give
/// the record its domain (`ATTEST_DOMAIN`, the one the vault's `Attested` event and every other vault's attest carry).
#[test]
fn test_b603_the_domain_words_are_the_keccaks_of_their_names() {
    assert_eq!(UPDATE, bcs::keccak(&[b"xindex.v4.aptos.update"]));
    assert_eq!(SLOTS, bcs::keccak(&[b"xindex.v4.aptos.slots"]));
    assert_eq!(ATTEST_DOMAIN, bcs::keccak(&[b"xindex.v4.vault-attest"]));
    // Three different words: a claim of one kind is never read as the other's.
    assert_ne!(UPDATE, SLOTS);
    assert_ne!(UPDATE, ATTEST_DOMAIN);
    assert_ne!(SLOTS, ATTEST_DOMAIN);
}

// ---------------------------------------------------------------------------
// mainnet.json: mainnet's own epoch changes, ledger info, transaction and events
// ---------------------------------------------------------------------------

/// The real claim the fixture holds: a trusted set, two hops, the ledger info, and the stand-in's transaction, type tag
/// and data.
struct Real {
    trusted: EpochState,
    hops: Vec<Signed>,
    ledger_info: Signed,
    transaction: Included,
    type_tag: Vec<u8>,
    data: Vec<u8>,
}

fn real() -> Real {
    let f = fixture("mainnet.json");
    let e = &f["event"];
    Real {
        trusted: json::epoch_state(&e["trusted"]),
        hops: e["hops"]
            .as_array()
            .unwrap()
            .iter()
            .map(json::signed)
            .collect(),
        ledger_info: json::signed(&e["ledger_info"]),
        transaction: json::included(&e["transaction"]),
        type_tag: json::bytes(&e["type_tag"]),
        data: json::bytes(&e["data"]),
    }
}

impl Real {
    fn run(&self) -> Result<(), Error> {
        let (set, _) = follow(&self.trusted, &self.hops)?;
        check(set, &self.ledger_info, self.hops.len())?;
        let info = &self.ledger_info.ledger_info.commit_info;
        prove_event(
            &info.executed_state_id,
            info.version,
            &self.transaction,
            &self.type_tag,
            &self.data,
        )
    }

    /// The set that signs ledger info `i`: the trusted one, then each hop's next.
    fn set(&self, i: usize) -> &EpochState {
        if i == 0 {
            &self.trusted
        } else {
            self.hops[i - 1]
                .ledger_info
                .commit_info
                .next_epoch_state
                .as_ref()
                .unwrap()
        }
    }

    fn signed(&mut self, i: usize) -> &mut Signed {
        if i < self.hops.len() {
            &mut self.hops[i]
        } else {
            &mut self.ledger_info
        }
    }
}

type SignedChange = fn(&mut Signed);
type SetChange = fn(&mut EpochState);
type IncludedChange = fn(&mut Included);

fn signers(s: &Signed) -> Vec<usize> {
    (0..s.bitmask.len() * 8)
        .filter(|&i| s.bitmask[i / 8] & (0x80 >> (i % 8)) != 0)
        .collect()
}

#[test]
fn mainnet_update_follows_two_epochs() {
    let f = fixture("mainnet.json");
    let out = verify(&json::update(&f)).expect("mainnet's epoch changes verify");
    assert_eq!(
        out.abi_encode(),
        hex(f["public_values"]["update"].as_str().unwrap())
    );
    let Output::Update {
        trusted_set, set, ..
    } = out
    else {
        unreachable!()
    };
    assert_eq!(
        trusted_set.to_vec(),
        hex(f["checks"]["trusted_set"].as_str().unwrap())
    );
    assert_eq!(set.to_vec(), hex(f["checks"]["set"].as_str().unwrap()));
}

#[test]
fn mainnet_event_is_under_a_ledger_info_the_hops_reach() {
    real()
        .run()
        .expect("mainnet's transaction and event verify");
}

#[test]
fn mainnet_bcs_round_trips() {
    // The statement writes what Aptos signed, byte for byte: each ledger info and transaction info, written from the
    // fields read out of mainnet's own BCS, is that BCS again.
    let f = fixture("mainnet.json");
    let e = &f["event"];
    for s in e["hops"]
        .as_array()
        .unwrap()
        .iter()
        .chain([&e["ledger_info"]])
    {
        let raw = json::bytes(&s["signed"]);
        let signed = json::signed(s);
        let mut written = vec![0u8];
        written.extend(bcs::ledger_info(&signed.ledger_info));
        bcs::bytes(&mut written, &signed.bitmask);
        written.push(1);
        bcs::bytes(&mut written, &signed.signature);
        assert_eq!(written, raw);
    }
    let raw = json::bytes(&e["transaction"]["info"]);
    let mut r = json::Reader::new(&raw);
    let (info, event_root) = r.transaction_info();
    assert_eq!(bcs::transaction_info(&info, &event_root), raw);
    let t = json::included(&e["transaction"]);
    let seed = bcs::seed("ContractEvent");
    let leaves: Vec<Word> = t.events.iter().map(|x| bcs::sha3(&[&seed, x])).collect();
    assert_eq!(
        bcs::accumulator_root(&bcs::seed("EventAccumulator"), &leaves),
        event_root
    );
}

#[test]
fn mainnet_a_signature_needs_more_than_two_thirds() {
    for i in 0..3 {
        // Drop signers, smallest first, until the rest hold no more than two thirds: the aggregate is not recomputed,
        // but the power is counted first.
        let mut r = real();
        let set = r.set(i).clone();
        let s = r.signed(i);
        let mut by_power = signers(s);
        by_power.sort_by_key(|&j| set.validators[j].voting_power);
        let total: u128 = set
            .validators
            .iter()
            .map(|v| u128::from(v.voting_power))
            .sum();
        let mut power: u128 = signers(s)
            .iter()
            .map(|&j| u128::from(set.validators[j].voting_power))
            .sum();
        for j in by_power {
            if 3 * power <= 2 * total {
                break;
            }
            let k = signers(s).iter().position(|&x| x == j).unwrap();
            s.bitmask[j / 8] &= !(0x80 >> (j % 8));
            s.points.remove(k);
            power -= u128::from(set.validators[j].voting_power);
        }
        assert_eq!(r.run(), Err(Error::NoQuorum(i)), "ledger info {i}");
    }
}

#[test]
fn mainnet_signers_must_be_those_that_signed() {
    for i in 0..3 {
        // One signer fewer, still a quorum: the aggregate is not theirs.
        let mut r = real();
        let s = r.signed(i);
        let j = signers(s)[0];
        s.bitmask[j / 8] &= !(0x80 >> (j % 8));
        s.points.remove(0);
        assert_eq!(r.run(), Err(Error::BadSignature(i)), "fewer, {i}");

        // One more, with its own point: neither.
        let mut r = real();
        let set = r.set(i).clone();
        let s = r.signed(i);
        let all = signers(s);
        let j = (0..set.validators.len())
            .find(|j| !all.contains(j))
            .unwrap();
        let k = all.iter().filter(|&&x| x < j).count();
        s.bitmask[j / 8] |= 0x80 >> (j % 8);
        let mut point = [0u8; 96];
        point.copy_from_slice(&hex(&decompress(&set.validators[j].public_key)));
        s.points.insert(k, point.to_vec());
        assert_eq!(r.run(), Err(Error::BadSignature(i)), "more, {i}");
    }
}

/// A compressed key's uncompressed point, by `bls12_381`.
fn decompress(compressed: &[u8]) -> String {
    let c: [u8; 48] = compressed.try_into().unwrap();
    let p = bls12_381::G1Affine::from_compressed(&c).unwrap();
    p.to_uncompressed()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

#[test]
fn mainnet_bitmask_and_points_are_exact() {
    // A byte too many, a byte too few, a bit past the set.
    let mut r = real();
    r.hops[0].bitmask.push(0);
    assert_eq!(r.run(), Err(Error::BadBitmask(0)));
    let mut r = real();
    r.hops[1].bitmask.pop();
    assert_eq!(r.run(), Err(Error::BadBitmask(1)));
    let mut r = real();
    let n = r.trusted.validators.len();
    assert!(!n.is_multiple_of(8));
    let last = r.hops[0].bitmask.len() - 1;
    r.hops[0].bitmask[last] |= 1;
    assert_eq!(r.run(), Err(Error::BadBitmask(0)));

    // Two signers' points swapped, one missing, one extra, one not 96 bytes.
    let mut r = real();
    r.ledger_info.points.swap(0, 1);
    assert_eq!(r.run(), Err(Error::BadKey(2)));
    let mut r = real();
    r.ledger_info.points.pop();
    assert_eq!(r.run(), Err(Error::BadKey(2)));
    let mut r = real();
    let p = r.ledger_info.points[0].clone();
    r.ledger_info.points.push(p);
    assert_eq!(r.run(), Err(Error::BadKey(2)));
    let mut r = real();
    r.ledger_info.points[3].pop();
    assert_eq!(r.run(), Err(Error::BadKey(2)));
    // A point negated: on the curve, but the other sign of the key.
    let mut r = real();
    let mut point: [u8; 96] = r.hops[0].points[0].clone().try_into().unwrap();
    let neg = -bls12_381::G1Affine::from_uncompressed(&point).unwrap();
    point = neg.to_uncompressed();
    r.hops[0].points[0] = point.to_vec();
    assert_eq!(r.run(), Err(Error::BadKey(0)));
    // A key that is not 48 bytes.
    let mut r = real();
    let j = signers(&r.hops[0])[0];
    r.trusted.validators[j].public_key.push(0);
    assert_eq!(r.run(), Err(Error::BadKey(0)));
}

#[test]
fn mainnet_every_field_is_signed() {
    let changes: Vec<(&str, SignedChange)> = vec![
        ("round", |s| s.ledger_info.commit_info.round += 1),
        ("id", |s| s.ledger_info.commit_info.id[0] ^= 1),
        ("root", |s| {
            s.ledger_info.commit_info.executed_state_id[31] ^= 1
        }),
        ("version", |s| s.ledger_info.commit_info.version += 1),
        ("time", |s| s.ledger_info.commit_info.timestamp_usecs += 1),
        ("consensus", |s| s.ledger_info.consensus_data_hash[0] ^= 1),
        ("signature", |s| s.signature[95] ^= 1),
    ];
    for (name, change) in &changes {
        for i in 0..3 {
            let mut r = real();
            change(r.signed(i));
            assert_eq!(r.run(), Err(Error::BadSignature(i)), "{name} of {i}");
        }
    }
    // The next set: a power, a key, an address, one validator fewer.
    let sets: Vec<(&str, SetChange)> = vec![
        ("power", |s| s.validators[0].voting_power += 1),
        ("address", |s| s.validators[1].address[0] ^= 1),
        ("order", |s| s.validators.swap(2, 3)),
        ("fewer", |s| {
            s.validators.pop();
        }),
    ];
    for (name, change) in &sets {
        for i in 0..2 {
            let mut r = real();
            change(
                r.hops[i]
                    .ledger_info
                    .commit_info
                    .next_epoch_state
                    .as_mut()
                    .unwrap(),
            );
            assert_eq!(r.run(), Err(Error::BadSignature(i)), "{name} of hop {i}");
        }
    }
}

#[test]
fn mainnet_hops_go_one_epoch_at_a_time() {
    // The ledger info of another epoch than the set.
    let mut r = real();
    r.ledger_info.ledger_info.commit_info.epoch += 1;
    assert_eq!(r.run(), Err(Error::WrongEpoch(2)));
    let mut r = real();
    r.trusted.epoch -= 1;
    assert_eq!(r.run(), Err(Error::WrongEpoch(0)));
    // A hop skipped, or the hops swapped.
    let mut r = real();
    r.hops.remove(0);
    assert_eq!(r.run(), Err(Error::WrongEpoch(0)));
    let mut r = real();
    r.hops.swap(0, 1);
    assert_eq!(r.run(), Err(Error::WrongEpoch(0)));
    // A ledger info that ends no epoch, as a hop: it verifies under its set, and names nothing.
    let r = real();
    let mut hops = r.hops.clone();
    hops.push(r.ledger_info.clone());
    assert_eq!(follow(&r.trusted, &hops).err(), Some(Error::NoNextEpoch(2)));
    // The trusted set as another: its power counts, its keys must be the signers'.
    let mut r = real();
    let j = signers(&r.hops[0])[0];
    r.trusted.validators[j].public_key = r.trusted.validators[j + 1].public_key.clone();
    assert_eq!(r.run(), Err(Error::BadKey(0)));
}

#[test]
fn mainnet_the_trusted_set_is_committed() {
    // Any change to the trusted set, even one the signatures survive, changes the hash the verifier compares.
    let f = fixture("mainnet.json");
    let base = verify(&json::update(&f)).unwrap();
    let Input::Update { mut trusted, hops } = json::update(&f) else {
        unreachable!()
    };
    let unsigned = (0..trusted.validators.len())
        .find(|&j| !signers(&hops[0]).contains(&j))
        .unwrap();
    trusted.validators[unsigned].voting_power += 1;
    let changed = verify(&Input::Update {
        trusted: trusted.clone(),
        hops,
    })
    .unwrap();
    assert_ne!(base, changed);
    let Output::Update { trusted_set, .. } = changed else {
        unreachable!()
    };
    assert_eq!(trusted_set, set_hash(&trusted.validators));
}

#[test]
fn mainnet_the_transaction_is_the_ledger_infos() {
    let changes: Vec<(&str, IncludedChange, Error)> = vec![
        ("version", |t| t.version += 1, Error::NotInAccumulator),
        (
            "sibling",
            |t| t.siblings[5][0] ^= 1,
            Error::NotInAccumulator,
        ),
        (
            "gas",
            |t| match &mut t.info {
                TransactionInfo::V0 { gas_used, .. } | TransactionInfo::V1 { gas_used, .. } => {
                    *gas_used += 1
                }
            },
            Error::NotInAccumulator,
        ),
        (
            "hash",
            |t| match &mut t.info {
                TransactionInfo::V0 {
                    transaction_hash, ..
                }
                | TransactionInfo::V1 {
                    transaction_hash, ..
                } => transaction_hash[0] ^= 1,
            },
            Error::NotInAccumulator,
        ),
        ("an event", |t| t.events[1][5] ^= 1, Error::NotInAccumulator),
        (
            "events swapped",
            |t| t.events.swap(0, 1),
            Error::NotInAccumulator,
        ),
        (
            "an event dropped",
            |t| {
                t.events.pop();
            },
            Error::NotInAccumulator,
        ),
        (
            "an event added",
            |t| {
                let e = t.events[1].clone();
                t.events.push(e);
            },
            Error::NotInAccumulator,
        ),
        (
            "a level short",
            |t| {
                t.siblings.pop();
            },
            Error::BadPath,
        ),
        (
            "a level too many",
            |t| t.siblings.push([0; 32]),
            Error::NotInAccumulator,
        ),
        (
            "64 levels",
            |t| t.siblings.resize(64, [0; 32]),
            Error::BadPath,
        ),
    ];
    for (name, change, error) in changes {
        let mut r = real();
        change(&mut r.transaction);
        assert_eq!(r.run(), Err(error), "{name}");
    }
    // After the ledger info's version.
    let mut r = real();
    r.transaction.version = r.ledger_info.ledger_info.commit_info.version + 1;
    assert_eq!(r.run(), Err(Error::AfterLedgerInfo));
}

#[test]
fn mainnet_the_event_is_counted_and_written() {
    // The stand-in's data otherwise: the typed event is not the written one.
    let mut r = real();
    r.data.push(0);
    assert_eq!(r.run(), Err(Error::NotTheEvent));
    // A type no event has.
    let mut r = real();
    r.type_tag[1] ^= 1;
    assert_eq!(r.run(), Err(Error::NotOneEvent));
    // `FeeStatement` with its own data is exactly one event too: the rule reads any type.
    let mut r = real();
    let fee = r.transaction.events[1].clone();
    let at = bcs::type_tag_at(&fee).unwrap();
    let tag_len = bcs::struct_tag(&one(), "transaction_fee", "FeeStatement").len();
    r.type_tag = fee[at..at + tag_len].to_vec();
    r.data = fee[at + tag_len + 1..].to_vec();
    r.run().expect("FeeStatement, once");
}

fn one() -> Word {
    let mut w = [0u8; 32];
    w[31] = 1;
    w
}

// ---------------------------------------------------------------------------
// synthetic.json: the claims end to end, and the public values the Solidity tests use
// ---------------------------------------------------------------------------

#[test]
fn the_synthetic_claims_commit_what_python_computed() {
    let f = fixture("synthetic.json");
    for kind in ["update", "slots"] {
        let input = if kind == "update" {
            json::update(&f)
        } else {
            json::slots(&f)
        };
        let out = verify(&input).expect("the synthetic claim holds");
        assert_eq!(
            out.abi_encode(),
            hex(f["public_values"][kind].as_str().unwrap()),
            "{kind}"
        );
    }
    let v = &f["verifier"];
    let Input::Update { trusted, .. } = json::update(&f) else {
        unreachable!()
    };
    assert_eq!(
        set_hash(&trusted.validators).to_vec(),
        hex(v["trusted_set"].as_str().unwrap())
    );
}

/// A change to a slots claim's own fields: chain id, package, vault id, timestamp, slots, values.
type Change = fn(&mut u64, &mut Word, &mut Word, &mut u64, &mut Vec<Word>, &mut Vec<Word>);

fn slots_with(input: &mut Input, change: Change) {
    let Input::Slots {
        chain_id,
        package,
        vault_id,
        timestamp,
        slots,
        values,
        ..
    } = input
    else {
        unreachable!()
    };
    change(chain_id, package, vault_id, timestamp, slots, values);
}

#[test]
fn the_synthetic_slots_are_the_records() {
    let f = fixture("synthetic.json");
    let changes: Vec<(&str, Change, Error)> = vec![
        ("timestamp", |_, _, _, t, _, _| *t += 1, Error::NotTheEvent),
        ("chain", |c, _, _, _, _, _| *c += 1, Error::NotTheEvent),
        ("vault", |_, _, v, _, _, _| v[0] ^= 1, Error::NotTheEvent),
        (
            "a slot",
            |_, _, _, _, s, _| s[0][0] ^= 1,
            Error::NotTheEvent,
        ),
        (
            "a value",
            |_, _, _, _, _, v| v[1][31] ^= 1,
            Error::NotTheEvent,
        ),
        (
            "one slot fewer",
            |_, _, _, _, s, v| {
                s.pop();
                v.pop();
            },
            Error::NotTheEvent,
        ),
        (
            "lengths",
            |_, _, _, _, _, v| {
                v.pop();
            },
            Error::LengthMismatch,
        ),
        ("package", |_, p, _, _, _, _| p[0] ^= 1, Error::NotOneEvent),
    ];
    for (name, change, error) in changes {
        let mut input = json::slots(&f);
        slots_with(&mut input, change);
        assert_eq!(verify(&input), Err(error), "{name}");
    }
}

#[test]
fn an_update_needs_a_hop() {
    let f = fixture("synthetic.json");
    let Input::Update { trusted, .. } = json::update(&f) else {
        unreachable!()
    };
    assert_eq!(
        verify(&Input::Update {
            trusted,
            hops: vec![]
        }),
        Err(Error::NoHops)
    );
}

// ---------------------------------------------------------------------------
// test chains
// ---------------------------------------------------------------------------

#[test]
fn the_quorum_is_more_than_two_thirds() {
    // Signers holding exactly two thirds fail; a unit more passes.
    let (set, keys) = testkit::set(5, 0, &[2, 2, 2]);
    let li = testkit::ledger_info(5, 9, [1; 32], None);
    assert_eq!(
        check(&set, &testkit::sign(li.clone(), &keys, &[0, 1]), 0),
        Err(Error::NoQuorum(0))
    );
    let (set, keys) = testkit::set(5, 0, &[2, 2, 3]);
    assert_eq!(
        check(&set, &testkit::sign(li.clone(), &keys, &[0, 1]), 0),
        Err(Error::NoQuorum(0))
    );
    check(&set, &testkit::sign(li.clone(), &keys, &[0, 2]), 0).expect("15 > 14");
    // No signer at all, and an empty set.
    assert_eq!(
        check(&set, &testkit::sign(li.clone(), &keys, &[]), 0),
        Err(Error::NoQuorum(0))
    );
    let empty = EpochState {
        epoch: 5,
        validators: vec![],
    };
    assert_eq!(
        check(&empty, &testkit::sign(li, &[], &[]), 0),
        Err(Error::NoQuorum(0))
    );
}

#[test]
fn test_chains_hold_from_zero_to_many_hops() {
    for hops in [0, 1, 3] {
        for (leaves, index) in [(1, 0), (2, 1), (7, 4), (16, 15)] {
            let c = testkit::claim(&[5, 3, 3, 2, 1, 1, 1, 9, 4], hops, leaves, index);
            verify(&c.input).unwrap_or_else(|e| panic!("{hops} hops, {leaves} leaves: {e:?}"));
        }
    }
}

fn transaction(c: &mut Claim) -> &mut Included {
    let Input::Slots { transaction, .. } = &mut c.input else {
        unreachable!()
    };
    transaction
}

#[test]
fn exactly_one_attested_event() {
    // Two identical: not exactly one.
    let mut c = testkit::claim(&[1, 1, 1, 1], 1, 5, 2);
    let e = transaction(&mut c).events[0].clone();
    transaction(&mut c).events.push(e);
    c.reroot();
    assert_eq!(verify(&c.input), Err(Error::NotOneEvent));

    // None.
    let mut c = testkit::claim(&[1, 1, 1, 1], 1, 5, 2);
    transaction(&mut c).events.remove(0);
    c.reroot();
    assert_eq!(verify(&c.input), Err(Error::NotOneEvent));

    // A second with another record.
    let mut c = testkit::claim(&[1, 1, 1, 1], 1, 5, 2);
    let other = testkit::attested(&testkit::PACKAGE, b"another record");
    transaction(&mut c).events.push(other);
    c.reroot();
    assert_eq!(verify(&c.input), Err(Error::NotTheEvent));

    // The same type as a handle event (V1) besides it: counted too.
    let mut c = testkit::claim(&[1, 1, 1, 1], 1, 5, 2);
    let v2 = transaction(&mut c).events[0].clone();
    let mut v1 = vec![0u8];
    v1.extend([3u8; 40]);
    v1.extend(9u64.to_le_bytes());
    v1.extend(&v2[1..]);
    transaction(&mut c).events.push(v1);
    c.reroot();
    assert_eq!(verify(&c.input), Err(Error::NotTheEvent));

    // The vault's type under another package is not the vault's.
    let mut c = testkit::claim(&[1, 1, 1, 1], 1, 5, 2);
    let Input::Slots {
        timestamp,
        slots,
        values,
        ..
    } = &c.input
    else {
        unreachable!()
    };
    let record = bcs::record(
        testkit::CHAIN_ID,
        &testkit::VAULT_ID,
        *timestamp,
        slots,
        values,
    );
    transaction(&mut c).events[0] = testkit::attested(&[0xa8; 32], &record);
    c.reroot();
    assert_eq!(verify(&c.input), Err(Error::NotOneEvent));
}

#[test]
fn only_a_successful_transaction() {
    // A transaction info whose status is not `Success`, under the ledger info: the statement writes `Success`, so its
    // path proves nothing.
    let mut c = testkit::claim(&[1, 1, 1, 1], 1, 4, 1);
    let t = transaction(&mut c).clone();
    let seed = bcs::seed("ContractEvent");
    let hashes: Vec<Word> = t.events.iter().map(|e| bcs::sha3(&[&seed, e])).collect();
    let root = bcs::accumulator_root(&bcs::seed("EventAccumulator"), &hashes);
    let mut failed = bcs::transaction_info(&t.info, &root);
    failed[9] = 1; // ExecutionStatus::OutOfGas
    c.leaves[1] = bcs::sha3(&[&bcs::seed("TransactionInfo"), &failed]);
    let Input::Slots {
        ledger_info,
        transaction,
        ..
    } = &mut c.input
    else {
        unreachable!()
    };
    transaction.siblings = testkit::siblings(&c.leaves, 1);
    ledger_info.ledger_info.commit_info.executed_state_id =
        bcs::accumulator_root(&bcs::seed("TransactionAccumulator"), &c.leaves);
    testkit::resign(ledger_info, c.keys.last().unwrap());
    assert_eq!(verify(&c.input), Err(Error::NotInAccumulator));
}

#[test]
fn a_v1_transaction_info_is_written_too() {
    let mut c = testkit::claim(&[1, 2, 3], 2, 6, 3);
    transaction(&mut c).info = TransactionInfo::V1 {
        gas_used: 5,
        transaction_hash: [1; 32],
        state_change_hash: [2; 32],
        state_checkpoint_hash: Some([3; 32]),
        hot_state_checkpoint_hash: None,
        auxiliary_info_hash: Some([4; 32]),
        position_state_checkpoint_hash: None,
        placeholders: [None, Some([5; 32]), None, None, None, None, Some([6; 32])],
    };
    c.reroot();
    verify(&c.input).expect("V1");
    // And its fields are committed.
    let TransactionInfo::V1 { placeholders, .. } = &mut transaction(&mut c).info else {
        unreachable!()
    };
    placeholders[6] = None;
    assert_eq!(verify(&c.input), Err(Error::NotInAccumulator));
}

#[test]
fn the_final_ledger_info_is_of_the_last_epoch() {
    // Signed by the set before the last: the right signers, the wrong epoch.
    let mut c = testkit::claim(&[1, 1, 1], 2, 3, 0);
    let Input::Slots { ledger_info, .. } = &mut c.input else {
        unreachable!()
    };
    ledger_info.ledger_info.commit_info.epoch -= 1;
    let keys = c.keys[1].clone();
    testkit::resign(ledger_info, &keys);
    assert_eq!(verify(&c.input), Err(Error::WrongEpoch(2)));

    // Of the last epoch, but signed by the set before it.
    let mut c = testkit::claim(&[1, 1, 1], 2, 3, 0);
    let Input::Slots { ledger_info, .. } = &mut c.input else {
        unreachable!()
    };
    let keys = c.keys[1].clone();
    testkit::resign(ledger_info, &keys);
    assert_eq!(verify(&c.input), Err(Error::BadKey(2)));

    // Its signature broken.
    let f = fixture("synthetic.json");
    let mut input = json::slots(&f);
    let Input::Slots { ledger_info, .. } = &mut input else {
        unreachable!()
    };
    ledger_info.ledger_info.commit_info.round += 1;
    assert_eq!(verify(&input), Err(Error::BadSignature(2)));
}

#[test]
fn a_hop_names_the_next_epoch() {
    let mut c = testkit::claim(&[1, 1, 1], 2, 3, 0);
    let Input::Slots { hops, .. } = &mut c.input else {
        unreachable!()
    };
    hops[0]
        .ledger_info
        .commit_info
        .next_epoch_state
        .as_mut()
        .unwrap()
        .epoch += 1;
    let keys = c.keys[0].clone();
    testkit::resign(&mut hops[0], &keys);
    assert_eq!(verify(&c.input), Err(Error::WrongEpoch(0)));
}
