//! The lattice hash, the bank hash and the slot delta, against Agave's own vectors and crate
//! (`fixtures/vectors.json`, written by `generate_vectors.py`; `solana-lattice-hash` 4.3.0), and the block id against
//! an independent implementation.

use serde_json::Value;
use std::{fs, time::Instant};
use xindex_solana_state::{
    bank::{apply_writes, written_state, BankHashPreimage, DeltaError, Write},
    block_id,
    lthash::{account_lt_hash, Account, LtHash},
};

fn vectors() -> Value {
    let path = format!("{}/fixtures/vectors.json", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap())
        .collect()
}

fn vector_lt(v: &Value, word: &str) -> LtHash {
    let values: Vec<u16> = v["ltHash"][word]["ltHash"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_u64().unwrap() as u16)
        .collect();
    LtHash(values.try_into().unwrap())
}

/// Agave's own vectors: BLAKE3's XOF over "hello" and "world!" read as 1,024 little-endian `u16`s, and their checksums.
#[test]
fn agaves_lattice_hash_vectors() {
    let v = vectors();
    for word in ["hello", "world"] {
        let mut hasher = blake3::Hasher::new();
        hasher.update(v["ltHash"][word]["input"].as_str().unwrap().as_bytes());
        let lt = LtHash::with(&hasher);
        assert_eq!(lt, vector_lt(&v, word), "{word}");
        assert_eq!(
            lt.checksum().to_vec(),
            unhex(v["ltHash"][word]["checksum"].as_str().unwrap()),
            "{word}"
        );
    }
}

/// The same as Agave's crate: an account's hash built as `AccountsDb::lt_hash_account` streams it, mixing in and out,
/// and the checksum, over accounts small and past the 200-byte buffer Agave switches at.
#[test]
fn as_agaves_crate_computes_it() {
    use solana_lattice_hash::lt_hash::LtHash as AgaveLtHash;
    let mut ours = LtHash::identity();
    let mut theirs = AgaveLtHash::identity();
    for (i, len) in [0usize, 1, 165, 200, 201, 4096].iter().enumerate() {
        let account = Account {
            lamports: 1_000 + i as u64,
            data: (0..*len).map(|b| (b * 7 + i) as u8).collect(),
            owner: [i as u8 + 1; 32],
            executable: i % 2 == 1,
        };
        let pubkey = [0x40 + i as u8; 32];
        // Agave's: lamports first, then the data, then executable, owner and pubkey, in one stream.
        let mut hasher = blake3::Hasher::new();
        hasher.update(&account.lamports.to_le_bytes());
        hasher.update(&account.data);
        hasher.update(&[u8::from(account.executable)]);
        hasher.update(&account.owner);
        hasher.update(&pubkey);
        let agave = AgaveLtHash::with(&hasher);
        let mine = account_lt_hash(&account, &pubkey);
        assert_eq!(mine.0, agave.0, "account {i}");
        if i % 2 == 0 {
            ours.mix_in(&mine);
            theirs.mix_in(&agave);
        } else {
            ours.mix_out(&mine);
            theirs.mix_out(&agave);
        }
    }
    assert_eq!(ours.0, theirs.0);
    assert_eq!(ours.checksum(), theirs.checksum().0);
    let zero = Account {
        lamports: 0,
        data: vec![1, 2, 3],
        owner: [9; 32],
        executable: false,
    };
    assert_eq!(
        account_lt_hash(&zero, &[1; 32]),
        LtHash::identity(),
        "a zero-lamport account hashes to the identity"
    );
}

fn preimage(v: &Value, i: usize) -> BankHashPreimage {
    let b = &v["bankHash"][i];
    BankHashPreimage {
        parent_bank_hash: unhex(b["parentBankHash"].as_str().unwrap())
            .try_into()
            .unwrap(),
        signature_count: b["signatureCount"].as_u64().unwrap(),
        last_blockhash: unhex(b["lastBlockhash"].as_str().unwrap())
            .try_into()
            .unwrap(),
        accounts_lt_hash: vector_lt(v, b["ltHash"].as_str().unwrap()),
        hard_forks: b["hardForks"].as_u64().unwrap(),
    }
}

/// The bank hash, against hashlib's: the whole lattice hash is absorbed, and a hard fork hashes once more.
#[test]
fn the_bank_hash_is_agaves_formula() {
    let v = vectors();
    for i in 0..2 {
        assert_eq!(
            preimage(&v, i).hash().to_vec(),
            unhex(v["bankHash"][i]["bankHash"].as_str().unwrap())
        );
    }
}

fn account(lamports: u64, data: &[u8], owner: u8) -> Account {
    Account {
        lamports,
        data: data.to_vec(),
        owner: [owner; 32],
        executable: false,
    }
}

/// A slot of four writes, as a bank applies them: an intake sealed (the vault's account changed), a sysvar, an account
/// created and one deleted. The parent's lattice hash is Agave's "hello" vector.
fn slot() -> (BankHashPreimage, BankHashPreimage, Vec<Write>) {
    let v = vectors();
    let parent = preimage(&v, 0);
    let writes = vec![
        Write {
            pubkey: [0xa1; 32],
            old: Some(account(5_000_000, b"intake: open, 3 SOL", 0x77)),
            new: Some(account(5_000_000, b"intake: sealed, 3 SOL", 0x77)),
        },
        Write {
            pubkey: [0x06; 32],
            old: Some(account(1, &[1; 40], 0x06)),
            new: Some(account(1, &[2; 40], 0x06)),
        },
        Write {
            pubkey: [0xb2; 32],
            old: None,
            new: Some(account(890_880, &[0; 165], 0x12)),
        },
        Write {
            pubkey: [0xc3; 32],
            old: Some(account(2_039_280, &[5; 165], 0x12)),
            new: Some(account(0, &[], 0x00)),
        },
    ];
    let lt = apply_writes(&parent.accounts_lt_hash, &writes).unwrap();
    let slot = BankHashPreimage {
        parent_bank_hash: parent.hash(),
        signature_count: 3,
        last_blockhash: [0x5b; 32],
        accounts_lt_hash: lt,
        hard_forks: 0,
    };
    (slot, parent, writes)
}

/// The slot's writes take the parent's lattice hash to the slot's, so the intake's new state is proven. The slot's
/// lattice hash is rebuilt with Agave's crate, each old state mixed out and each new one in, as
/// `AccountsLtHashAsyncProgress::process` does, so the direction is not this crate's word alone.
#[test]
fn the_slot_proves_the_intake_it_wrote() {
    use solana_lattice_hash::lt_hash::LtHash as AgaveLtHash;
    let (slot, parent, writes) = slot();
    let agave_hash = |a: &Account, key: &[u8; 32]| {
        if a.lamports == 0 {
            return AgaveLtHash::identity();
        }
        let mut h = blake3::Hasher::new();
        h.update(&a.lamports.to_le_bytes());
        h.update(&a.data);
        h.update(&[u8::from(a.executable)]);
        h.update(&a.owner);
        h.update(key);
        AgaveLtHash::with(&h)
    };
    let mut expected = AgaveLtHash(parent.accounts_lt_hash.0);
    for w in &writes {
        if let Some(old) = &w.old {
            expected.mix_out(&agave_hash(old, &w.pubkey));
        }
        if let Some(new) = &w.new {
            expected.mix_in(&agave_hash(new, &w.pubkey));
        }
    }
    assert_eq!(expected.0, slot.accounts_lt_hash.0);
    let state = written_state(&slot, &parent, &writes, &[0xa1; 32]).unwrap();
    assert_eq!(state.unwrap().data, b"intake: sealed, 3 SOL");
    assert_eq!(
        written_state(&slot, &parent, &writes, &[0xee; 32]),
        Ok(None),
        "not written in this slot"
    );
}

/// Any other account of writes is refused: a new state changed, a write left out or added, old and new swapped, an
/// address twice, or another parent.
#[test]
fn the_slot_proves_nothing_else() {
    let (slot, parent, writes) = slot();
    let refused = |w: &[Write]| written_state(&slot, &parent, w, &[0xa1; 32]).map(|s| s.cloned());
    let mut forged = writes.clone();
    forged[0].new.as_mut().unwrap().data = b"intake: sealed, 300 SOL".to_vec();
    assert_eq!(refused(&forged), Err(DeltaError::Mismatch));
    assert_eq!(refused(&writes[1..]), Err(DeltaError::Mismatch));
    let mut extra = writes.clone();
    extra.push(Write {
        pubkey: [0xd4; 32],
        old: None,
        new: Some(account(1, b"x", 1)),
    });
    assert_eq!(refused(&extra), Err(DeltaError::Mismatch));
    let mut swapped = writes.clone();
    let first = &mut swapped[0];
    std::mem::swap(&mut first.old, &mut first.new);
    assert_eq!(refused(&swapped), Err(DeltaError::Mismatch));
    let mut twice = writes.clone();
    twice.push(writes[0].clone());
    assert_eq!(refused(&twice), Err(DeltaError::Duplicate([0xa1; 32])));
    let mut other_parent = parent.clone();
    other_parent.signature_count += 1;
    assert_eq!(
        written_state(&slot, &other_parent, &writes, &[0xa1; 32]),
        Err(DeltaError::WrongParent)
    );
}

/// The block id against the generator's own tree, and every leaf's proof walked back to it.
#[test]
fn the_block_id() {
    let v = vectors();
    let b = &v["blockId"];
    let fec: Vec<[u8; 32]> = b["fecRoots"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| unhex(x.as_str().unwrap()).try_into().unwrap())
        .collect();
    let parent: [u8; 32] = unhex(b["parentBlockId"].as_str().unwrap())
        .try_into()
        .unwrap();
    let id = block_id::block_id(&fec, b["parentSlot"].as_u64().unwrap(), &parent).unwrap();
    assert_eq!(id.to_vec(), unhex(b["blockId"].as_str().unwrap()));

    // Five leaves (four FEC sets and the parent's): an odd layer joins its last node with itself.
    let leaves: Vec<[u8; 32]> = (0..5u8).map(|i| [i; 32]).collect();
    let root = block_id::root(&leaves).unwrap();
    let entry = |h: &[u8; 32]| -> [u8; 20] { h[..20].try_into().unwrap() };
    let l1: Vec<[u8; 32]> = vec![
        block_id::join(&leaves[0], &leaves[1]),
        block_id::join(&leaves[2], &leaves[3]),
        block_id::join(&leaves[4], &leaves[4]),
    ];
    let l2 = [
        block_id::join(&l1[0], &l1[1]),
        block_id::join(&l1[2], &l1[2]),
    ];
    assert_eq!(root, block_id::join(&l2[0], &l2[1]));
    let proof = [entry(&leaves[4]), entry(&l1[2]), entry(&l2[0])];
    assert_eq!(block_id::root_from_proof(4, leaves[4], &proof), Some(root));
    assert_ne!(block_id::root_from_proof(4, leaves[3], &proof), Some(root));
    assert_eq!(
        block_id::root_from_proof(9, leaves[4], &proof),
        None,
        "an index past the tree"
    );
}

/// What a slot costs natively, to estimate a zkVM's: every written account hashed twice (old and new), each into a
/// 2,048-byte XOF, the rest a few SHA-256 blocks. Printed, not asserted.
#[test]
fn measure_a_slot() {
    for (writes, size) in [(1_000usize, 165usize), (3_000, 165), (3_000, 1_000)] {
        let ws: Vec<Write> = (0..writes)
            .map(|i| {
                let mut key = [0u8; 32];
                key[..8].copy_from_slice(&(i as u64).to_le_bytes());
                Write {
                    pubkey: key,
                    old: Some(account(1, &vec![1; size], 2)),
                    new: Some(account(2, &vec![3; size], 2)),
                }
            })
            .collect();
        let start = Instant::now();
        let _ = apply_writes(&LtHash::identity(), &ws).unwrap();
        // BLAKE3 compresses 64 bytes at a time: the input, plus 32 blocks of XOF output per hash.
        let blocks = 2 * writes * ((8 + size + 1 + 64).div_ceil(64) + 32);
        println!(
            "{writes} writes of {size} bytes: {:?} natively, {blocks} BLAKE3 compressions",
            start.elapsed()
        );
    }
}
