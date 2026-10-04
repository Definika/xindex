//! The statement on mainnet's own data (`fixtures/mainnet.json`), on the synthetic claims the program is executed on
//! (`fixtures/synthetic.json`), and on test chains built here, each refusal reached by changing one thing. Several
//! tests exist to kill a named mutant of `src/lib.rs`, which they say.

use serde_json::Value;
use xindex_vechain::encode::{self, keccak};
use xindex_vechain::testkit::{self, default_plan, slots_of, Plan};
use xindex_vechain::*;

fn fixture(name: &str) -> Value {
    let path = format!("{}/../fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&std::fs::read_to_string(path).expect("the fixture")).expect("JSON")
}

fn common_of(input: &mut Input) -> &mut Common {
    match input {
        Input::Update { common, .. } | Input::Slots { common, .. } => common,
    }
}

// ---------------------------------------------------------------------------
// constants
// ---------------------------------------------------------------------------

#[test]
fn constants_are_their_hashes() {
    assert_eq!(UPDATE, keccak(&[b"xindex.v4.vechain.update"]));
    assert_eq!(SLOTS, keccak(&[b"xindex.v4.vechain.slots"]));
    assert_eq!(
        encode::VAULT_ATTEST,
        keccak(&[b"attest(bytes32[],bytes32[])"])[..4]
    );
    assert_eq!(encode::STAKER_ATTEST, keccak(&[b"attest(bytes32)"])[..4]);
    // `[[[], []]]`: one clause's outputs, no event, no transfer.
    let mut empty = Vec::new();
    encode::list(&mut empty, &[]);
    let mut output = Vec::new();
    encode::list(&mut output, &[empty.clone(), empty].concat());
    let mut outputs = Vec::new();
    encode::list(&mut outputs, &output);
    assert_eq!(outputs, encode::NO_OUTPUTS);
}

// ---------------------------------------------------------------------------
// mainnet's own data
// ---------------------------------------------------------------------------

#[test]
fn real_headers_link_and_recover_their_signers() {
    let f = fixture("mainnet.json");
    let headers = json::headers(&f["headers"]);
    let linked = link(&headers).expect("mainnet's chain links");
    let first = f["first"].as_u64().unwrap() as u32;
    for (i, l) in linked.iter().enumerate() {
        assert_eq!(l.number, first + i as u32);
        assert_eq!(l.id, json::word(&f["ids"][i]), "header {i}'s id");
        assert_eq!(
            l.signer,
            json::address(&f["signers"][i]),
            "header {i}'s signer"
        );
    }
}

#[test]
fn real_tables_hash_as_the_attester_hashes_them() {
    let f = fixture("mainnet.json");
    for which in ["trusted", "justified", "committed"] {
        let t = &f["tables"][which];
        let w = weights(&json::table(t)).unwrap();
        assert_eq!(w.hash, json::word(&t["hash"]), "{which}");
        assert_eq!(w.by.len(), t["validators"].as_array().unwrap().len());
    }
}

/// thor finalized checkpoint `k * 180`: round `k` justified and round `k + 1` committed, as the statement counts them
/// under the Staker's real tables.
#[test]
fn real_rounds_are_final_as_thor_finalized_them() {
    let f = fixture("mainnet.json");
    let headers = json::headers(&f["headers"]);
    let linked = link(&headers).unwrap();
    let (k, r) = (
        f["justifiedRound"].as_u64().unwrap() as u32,
        f["committedRound"].as_u64().unwrap() as u32,
    );
    assert_eq!(f["finalized"].as_u64().unwrap() as u32, k * EPOCH);
    let tk = weights(&json::table(&f["tables"]["justified"])).unwrap();
    let tr = weights(&json::table(&f["tables"]["committed"])).unwrap();
    let trusted = weights(&json::table(&f["tables"]["trusted"])).unwrap();
    let in_round = |n: u32| linked.iter().filter(move |l| l.number / EPOCH == n);
    assert_eq!(in_round(r).count(), EPOCH as usize);
    assert!(
        tk.quorum(in_round(k).map(|l| &l.signer)),
        "round k justified"
    );
    let against: Vec<_> = in_round(r).filter(|l| !l.com).map(|l| l.signer).collect();
    let voters: Vec<_> = in_round(r)
        .filter(|l| !against.contains(&l.signer))
        .map(|l| l.signer)
        .collect();
    assert!(tr.quorum(voters.iter()), "round k + 1 committed");
    assert_eq!(f["expect"]["justified"], true);
    assert_eq!(f["expect"]["committed"], true);
    // Vouching: the blocks after round k's and round k + 1's first blocks, by the table of round k - 1.
    let first = f["first"].as_u64().unwrap() as u32;
    for n in [k * EPOCH, r * EPOCH] {
        let after = &linked[(n - first) as usize + 1..];
        assert_eq!(
            trusted.quorum(after.iter().map(|l| &l.signer)),
            f["expect"][if n == k * EPOCH {
                "vouchedAfterK"
            } else {
                "vouchedAfterR"
            }]
            .as_bool()
            .unwrap()
        );
    }
    // No signer outside the round's table: every vote weighs.
    for l in in_round(k) {
        assert!(tk.by.contains_key(&l.signer));
    }
}

/// A real successful call, one clause and no value, written by the statement from its fields, is its block's
/// transaction, and its receipt, written with `reverted` false, its receipt.
#[test]
fn real_call_is_proven_under_its_blocks_roots() {
    let f = fixture("mainnet.json");
    let headers = json::headers(&f["headers"]);
    let chain = json::word(&f["chain"]);
    let s = &f["standin"];
    let call = json::call(&s["call"]);
    let to = json::address(&s["to"]);
    let data = json::hex(s["data"].as_str().unwrap());
    let outputs = json::hex(s["outputs"].as_str().unwrap());
    assert_eq!(
        verify_call(&headers, &chain, &call, &to, &data, &outputs),
        Ok(())
    );
    if s["quiet"].as_bool().unwrap() {
        assert_eq!(outputs, encode::NO_OUTPUTS, "as an attest call's");
    } else {
        assert_eq!(
            verify_call(&headers, &chain, &call, &to, &data, &encode::NO_OUTPUTS),
            Err(Error::NotTheReceipt),
            "a call that logged is not one that did not"
        );
    }

    let mut other = data.clone();
    *other.last_mut().unwrap() ^= 1;
    assert_eq!(
        verify_call(&headers, &chain, &call, &to, &other, &outputs),
        Err(Error::NotTheTransaction)
    );
    let mut to2 = to;
    to2[0] ^= 1;
    assert_eq!(
        verify_call(&headers, &chain, &call, &to2, &data, &outputs),
        Err(Error::NotTheTransaction)
    );
    let mut c = call.clone();
    c.receipt.gas_used += 1;
    assert_eq!(
        verify_call(&headers, &chain, &c, &to, &data, &outputs),
        Err(Error::NotTheReceipt)
    );
    let mut c = call.clone();
    c.transaction.nonce ^= 1;
    assert_eq!(
        verify_call(&headers, &chain, &c, &to, &data, &outputs),
        Err(Error::NotTheTransaction)
    );
    let mut c = call.clone();
    c.index += 1;
    assert_eq!(
        verify_call(&headers, &chain, &c, &to, &data, &outputs),
        Err(Error::NotTheTransaction)
    );
    let mut c = call.clone();
    c.block = headers.len() as u32;
    assert_eq!(
        verify_call(&headers, &chain, &c, &to, &data, &outputs),
        Err(Error::NoBlock)
    );
    let mut c = call.clone();
    c.block = 1;
    assert_eq!(
        verify_call(&headers, &chain, &c, &to, &data, &outputs),
        Err(Error::NotTheTransaction),
        "another block's roots"
    );
    let mut wrong = chain;
    wrong[31] ^= 1;
    assert_eq!(
        verify_call(&headers, &wrong, &call, &to, &data, &outputs),
        Err(Error::WrongChain)
    );
    // A proof with a node too many, too few, or a node changed.
    let mut c = call.clone();
    c.transaction_proof.push(vec![0xc0]);
    assert_eq!(
        verify_call(&headers, &chain, &c, &to, &data, &outputs),
        Err(Error::NotTheTransaction)
    );
    let mut c = call.clone();
    c.receipt_proof.pop();
    assert_eq!(
        verify_call(&headers, &chain, &c, &to, &data, &outputs),
        Err(Error::NotTheReceipt)
    );
    let mut c = call;
    let last = c.receipt_proof.len() - 1;
    let n = c.receipt_proof[last].len();
    c.receipt_proof[last][n - 1] ^= 1;
    assert_eq!(
        verify_call(&headers, &chain, &c, &to, &data, &outputs),
        Err(Error::NotTheReceipt)
    );
}

/// Kills the mutant that recovers without normalizing `s`: a high-`s` twin of a real signature, which go-ethereum
/// recovers to the same signer, still links.
#[test]
fn a_high_s_signature_recovers_the_same_signer() {
    let f = fixture("mainnet.json");
    let mut h = json::header(&f["headers"][0]);
    let before = signer(&h).unwrap();
    // n - s, big-endian, and the other parity.
    let n: [u8; 32] = json::word(&serde_json::json!(
        "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"
    ));
    let s = &h.signature[32..64];
    let mut out = [0u8; 32];
    let mut borrow = 0i16;
    for i in (0..32).rev() {
        let d = n[i] as i16 - s[i] as i16 - borrow;
        out[i] = d.rem_euclid(256) as u8;
        borrow = i16::from(d < 0);
    }
    h.signature[32..64].copy_from_slice(&out);
    h.signature[64] ^= 1;
    assert_eq!(signer(&h), Some(before));
}

#[test]
fn a_changed_header_signs_for_someone_else() {
    let f = fixture("mainnet.json");
    let mut headers = json::headers(&f["headers"]);
    headers[3].com = !headers[3].com;
    assert_eq!(link(&headers), Err(Error::NotLinked(4)));
    let mut headers = json::headers(&f["headers"]);
    headers[3].base_fee[31] ^= 1;
    assert_eq!(link(&headers), Err(Error::NotLinked(4)));
    let mut headers = json::headers(&f["headers"]);
    headers[3].signature.truncate(145);
    assert_eq!(link(&headers), Err(Error::BadSignature(3)));
    let mut headers = json::headers(&f["headers"]);
    headers[3].signature[64] = 4;
    assert_eq!(link(&headers), Err(Error::BadSignature(3)));
    let mut headers = json::headers(&f["headers"]);
    headers.remove(3);
    assert_eq!(link(&headers), Err(Error::NotLinked(3)));
    assert_eq!(link(&[]), Err(Error::NoHeaders));
}

// ---------------------------------------------------------------------------
// the synthetic claims: what the program is executed on
// ---------------------------------------------------------------------------

#[test]
fn synthetic_claims_commit_the_fixtures_public_values() {
    let f = fixture("synthetic.json");
    for (kind, input) in [("update", json::update(&f)), ("slots", json::slots(&f))] {
        let out = verify(&input).unwrap_or_else(|e| panic!("{kind}: {e:?}"));
        assert_eq!(
            out.abi_encode(),
            json::hex(f["public_values"][kind].as_str().unwrap()),
            "{kind}"
        );
    }
}

fn expect(input: &Input, error: Error) {
    assert_eq!(verify(input), Err(error));
}

#[test]
fn synthetic_refusals() {
    let f = fixture("synthetic.json");
    let slots = json::slots(&f);
    let update = json::update(&f);

    let mut i = slots.clone();
    common_of(&mut i).headers.remove(40);
    expect(&i, Error::NotLinked(40));

    let mut i = slots.clone();
    common_of(&mut i).headers.clear();
    expect(&i, Error::NoHeaders);

    let mut i = slots.clone();
    let first = encode::number(&common_of(&mut i).headers[0]).unwrap();
    common_of(&mut i).trusted_id[..4].copy_from_slice(&first.to_be_bytes());
    expect(&i, Error::NotAfterTrusted);
    let mut i = slots.clone();
    common_of(&mut i).trusted_id[..4].copy_from_slice(&(first - 1).to_be_bytes());
    assert!(verify(&i).is_ok(), "the block right after the trusted one");

    let mut i = slots.clone();
    let dup = common_of(&mut i).trusted.validators[0];
    common_of(&mut i).trusted.validators.push(dup);
    expect(&i, Error::BadTable);

    let mut i = slots.clone();
    common_of(&mut i).chain[31] ^= 1;
    expect(&i, Error::WrongChain);

    // A phantom validator holding most of the trusted weight signs nothing: no vouching.
    let mut i = update.clone();
    let mut big = [0u8; 32];
    big[19] = 0x0f;
    common_of(&mut i).trusted.validators.push(([0xee; 20], big));
    common_of(&mut i).trusted.total_weight = big;
    expect(&i, Error::NotVouched);

    // Another table than the one attested.
    let mut i = update.clone();
    if let Input::Update { attested, .. } = &mut i {
        attested.table.validators[0].1[31] ^= 1;
    }
    expect(&i, Error::NotTheTransaction);
    let mut i = update;
    if let Input::Update { attested, .. } = &mut i {
        attested.call.receipt.paid[31] ^= 1;
    }
    expect(&i, Error::NotTheReceipt);

    // Other values than the vault attested.
    let mut i = slots.clone();
    if let Input::Slots { values, .. } = &mut i {
        values[0][0] ^= 1;
    }
    expect(&i, Error::NotTheTransaction);
    let mut i = slots.clone();
    if let Input::Slots { values, .. } = &mut i {
        values.pop();
    }
    expect(&i, Error::LengthMismatch);
    let mut i = slots.clone();
    if let Input::Slots { vault, .. } = &mut i {
        vault[0] ^= 1;
    }
    expect(&i, Error::NotTheTransaction);
    let mut i = slots.clone();
    if let Input::Slots { call, .. } = &mut i {
        call.block = 10_000;
    }
    expect(&i, Error::NoBlock);

    // The rounds swapped.
    let mut i = slots.clone();
    if let Input::Slots {
        justified,
        committed,
        ..
    } = &mut i
    {
        std::mem::swap(justified, committed);
    }
    expect(&i, Error::RoundsOutOfOrder);

    // The chain cut one block short of round r's end.
    let mut i = slots.clone();
    let len = common_of(&mut i).headers.len();
    let first = encode::number(&common_of(&mut i).headers[0]).unwrap();
    let r_end = (first / EPOCH + 2) * EPOCH + EPOCH - 1;
    common_of(&mut i).headers.truncate((r_end - first) as usize);
    assert!(len > (r_end - first) as usize);
    expect(&i, Error::RoundIncomplete);
    let mut i = slots;
    common_of(&mut i)
        .headers
        .truncate((r_end - first) as usize + 1);
    assert!(verify(&i).is_ok(), "the chain may end with round r");
}

// ---------------------------------------------------------------------------
// test chains: the thresholds, each against the mutant it kills
// ---------------------------------------------------------------------------

fn all(_: u32) -> bool {
    true
}

/// Kills `>=` for `>` in `quorum`: two of three equal validators sign round k, exactly two thirds, which does not
/// justify it; the third signs round r, so vouching holds throughout.
#[test]
fn exactly_two_thirds_does_not_justify() {
    let vals = testkit::validators(b"thirds", &[1_000_000, 1_000_000, 1_000_000]);
    let k = 100 * EPOCH;
    let two = |n: u32| {
        if n < k + EPOCH {
            (n % 2) as usize
        } else {
            (n % 3) as usize
        }
    };
    let p = default_plan(&vals, &two, &all);
    expect(&slots_of(&p), Error::NotJustified);
    let three = |n: u32| (n % 3) as usize;
    let p = default_plan(&vals, &three, &all);
    assert!(verify(&slots_of(&p)).is_ok());
}

/// Kills a commit that counts any COM vote: of four equal validators, two vote COM in one of their blocks of round r
/// and not in another, so only two count, half the weight. With one such, three count.
#[test]
fn a_signer_voting_both_ways_counts_against() {
    let vals = testkit::validators(b"both ways", &[5, 5, 5, 5]);
    let r = 101 * EPOCH;
    let signer = |n: u32| (n % 4) as usize;
    let two = |n: u32| !(n >= r && n < r + 8 && n % 4 >= 2);
    let p = default_plan(&vals, &signer, &two);
    expect(&slots_of(&p), Error::NotCommitted);
    let one = |n: u32| !(n >= r && n < r + 8 && n % 4 == 3);
    let p = default_plan(&vals, &signer, &one);
    assert!(verify(&slots_of(&p)).is_ok());
    // Not voting COM at all, in round k, does not stop it being justified.
    let k = 100 * EPOCH;
    let none_in_k = |n: u32| !(n >= k && n < k + EPOCH);
    let p = default_plan(&vals, &signer, &none_in_k);
    assert!(verify(&slots_of(&p)).is_ok());
}

/// Kills vouching that counts the attesting block's own signer: the heaviest validator signs round r's table into its
/// block and nothing after it, so the others, two fifths of the trusted weight, cannot vouch for it.
#[test]
fn an_attesting_block_does_not_vouch_for_itself() {
    let vals = testkit::validators(b"self", &[3, 1, 1]);
    let r = 101 * EPOCH;
    let signer = |n: u32| {
        if n < r + 1 {
            (n % 3) as usize
        } else if n == r + 1 {
            0
        } else {
            1 + (n % 2) as usize
        }
    };
    let p = default_plan(&vals, &signer, &all);
    expect(&slots_of(&p), Error::NotVouched);
    // Signing once more after it, it does.
    let again = |n: u32| if n == r + 2 { 0 } else { signer(n) };
    let p = default_plan(&vals, &again, &all);
    assert!(verify(&slots_of(&p)).is_ok());
}

/// Kills `>=` for `>` in the finality check: the vault's call may be round k's checkpoint itself, not the block after.
#[test]
fn the_call_may_be_round_ks_checkpoint_and_no_later() {
    let vals = testkit::validators(b"checkpoint", &[7, 7, 7]);
    let k = 100 * EPOCH;
    let signer = |n: u32| (n % 3) as usize;
    let mut p: Plan = default_plan(&vals, &signer, &all);
    p.xk = k + 2;
    p.y = k;
    assert!(verify(&slots_of(&p)).is_ok());
    p.y = k + 1;
    expect(&slots_of(&p), Error::NotFinal);
    // In the same block as round k's table.
    p.y = k + 2;
    expect(&slots_of(&p), Error::NotFinal);
}

/// Both tables attested in one round: there is no later round to commit.
#[test]
fn the_tables_must_come_from_two_rounds() {
    let vals = testkit::validators(b"rounds", &[2, 2, 2]);
    let k = 100 * EPOCH;
    let signer = |n: u32| (n % 3) as usize;
    let mut p = default_plan(&vals, &signer, &all);
    p.xr = k + 5;
    expect(&slots_of(&p), Error::RoundsOutOfOrder);
}

/// The weights each round counts are its own table's: round r's table gives the validator that stops signing COM
/// there most of the weight, so it is not committed, though the trusted table and round k's would commit it.
#[test]
fn each_round_counts_its_own_table() {
    let vals = testkit::validators(b"own table", &[4, 4, 4, 4]);
    let r = 101 * EPOCH;
    let signer = |n: u32| (n % 4) as usize;
    let com = |n: u32| !(n >= r && n.is_multiple_of(4));
    let mut p = default_plan(&vals, &signer, &com);
    assert!(verify(&slots_of(&p)).is_ok(), "three of four, equal");
    let mut heavy = testkit::table(&vals);
    heavy.validators[0].1 = {
        let mut w = [0u8; 32];
        w[16..].copy_from_slice(&(20u128 * 1_000_000_000_000_000_000).to_be_bytes());
        w
    };
    heavy.total_weight = {
        let mut w = [0u8; 32];
        w[16..].copy_from_slice(&(32u128 * 1_000_000_000_000_000_000).to_be_bytes());
        w
    };
    p.table_r = heavy;
    expect(&slots_of(&p), Error::NotCommitted);
}

#[test]
fn weights_stay_below_two_to_the_hundred() {
    let mut t = Table {
        total_weight: [0u8; 32],
        validators: vec![([1; 20], [0u8; 32])],
    };
    t.validators[0].1[19] = 0x0f;
    t.validators[0].1[20..].fill(0xff);
    assert!(weights(&t).is_ok());
    t.validators[0].1 = [0u8; 32];
    t.validators[0].1[19] = 0x10;
    assert_eq!(weights(&t).err(), Some(Error::BadTable));
    t.validators[0].1 = [0u8; 32];
    t.total_weight[0] = 1;
    assert_eq!(weights(&t).err(), Some(Error::BadTable));
}
