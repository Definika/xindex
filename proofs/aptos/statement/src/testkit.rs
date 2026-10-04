//! Test validators that sign, and claims built from them: for the tests, never the program. Every key here is a test
//! key and every ledger info made up.

use alloc::vec::Vec;
use bls12_381::{G1Affine, G2Affine, Scalar};
use group::Curve;
use xindex_finality::bls;

use crate::{
    bcs, BlockInfo, EpochState, Included, Input, LedgerInfo, Signed, TransactionInfo, Validator,
    Word, EVENT, MODULE,
};

/// A test validator's key: its secret, its compressed key and its uncompressed point.
#[derive(Clone)]
pub struct Key {
    pub secret: Scalar,
    pub compressed: Vec<u8>,
    pub point: Vec<u8>,
}

pub fn key(i: u64) -> Key {
    let secret = Scalar::from(0x5eed_0000 + i);
    let public = (G1Affine::generator() * secret).to_affine();
    Key {
        secret,
        compressed: public.to_compressed().to_vec(),
        point: public.to_uncompressed().to_vec(),
    }
}

/// A set of epoch `epoch`, validator `i` holding key `first + i` with power `powers[i]`.
pub fn set(epoch: u64, first: u64, powers: &[u64]) -> (EpochState, Vec<Key>) {
    let keys: Vec<Key> = (0..powers.len() as u64).map(|i| key(first + i)).collect();
    let validators = keys
        .iter()
        .zip(powers)
        .enumerate()
        .map(|(i, (k, p))| Validator {
            address: bcs::keccak(&[&(first + i as u64).to_be_bytes()]),
            public_key: k.compressed.clone(),
            voting_power: *p,
        })
        .collect();
    (EpochState { epoch, validators }, keys)
}

/// Signs `ledger_info` by validators `signers` of a set of `keys`: the bitmask, their points, and the aggregate.
pub fn sign(ledger_info: LedgerInfo, keys: &[Key], signers: &[usize]) -> Signed {
    let mut bitmask = alloc::vec![0u8; keys.len().div_ceil(8)];
    let mut secret = Scalar::zero();
    let mut sorted = signers.to_vec();
    sorted.sort_unstable();
    sorted.dedup();
    for &i in &sorted {
        bitmask[i / 8] |= 0x80 >> (i % 8);
        secret += keys[i].secret;
    }
    let message = bcs::signing_message(&ledger_info);
    let signature: G2Affine = (bls::hash_to_g2(&message, bls::DST) * secret).to_affine();
    Signed {
        ledger_info,
        bitmask,
        signature: signature.to_compressed().to_vec(),
        points: sorted.iter().map(|&i| keys[i].point.clone()).collect(),
    }
}

/// Signs `signed`'s ledger info again, as it now stands, by the same signers.
pub fn resign(signed: &mut Signed, keys: &[Key]) {
    let signers: Vec<usize> = (0..keys.len())
        .filter(|&i| signed.bitmask[i / 8] & (0x80 >> (i % 8)) != 0)
        .collect();
    *signed = sign(signed.ledger_info.clone(), keys, &signers);
}

pub fn ledger_info(epoch: u64, version: u64, root: Word, next: Option<EpochState>) -> LedgerInfo {
    LedgerInfo {
        commit_info: BlockInfo {
            epoch,
            round: 7 + epoch,
            id: bcs::keccak(&[b"block", &epoch.to_be_bytes(), &version.to_be_bytes()]),
            executed_state_id: root,
            version,
            timestamp_usecs: 1_791_000_000_000_000 + epoch * 7_200_000_000 + version,
            next_epoch_state: next,
        },
        consensus_data_hash: bcs::keccak(&[b"consensus", &epoch.to_be_bytes()]),
    }
}

/// A test claim and everything to change it with: the sets' keys (the trusted set's first), the accumulator's leaves
/// and the transaction's index among them.
pub struct Claim {
    pub input: Input,
    pub keys: Vec<Vec<Key>>,
    pub leaves: Vec<Word>,
    pub index: usize,
}

pub const PACKAGE: Word = [0xa7; 32];
pub const VAULT_ID: Word = [0x0b; 32];
pub const CHAIN_ID: u64 = 549_304_973_309_166_888;

/// `0x1::transaction_fee::FeeStatement`, another event in the transaction.
pub fn fee_event() -> Vec<u8> {
    let mut one = [0u8; 32];
    one[31] = 1;
    bcs::module_event(
        &bcs::struct_tag(&one, "transaction_fee", "FeeStatement"),
        &[7u8; 40],
    )
}

/// The vault's event for `record`.
pub fn attested(package: &Word, record: &[u8]) -> Vec<u8> {
    let mut data = Vec::new();
    bcs::bytes(&mut data, record);
    bcs::module_event(&bcs::struct_tag(package, MODULE, EVENT), &data)
}

pub fn info(i: u64) -> TransactionInfo {
    TransactionInfo::V0 {
        gas_used: 100 + i,
        transaction_hash: bcs::keccak(&[b"txn", &i.to_be_bytes()]),
        state_change_hash: bcs::keccak(&[b"state", &i.to_be_bytes()]),
        state_checkpoint_hash: None,
        auxiliary_info_hash: Some(bcs::keccak(&[b"aux", &i.to_be_bytes()])),
    }
}

/// The leaf of a transaction info with `events`.
pub fn leaf(info: &TransactionInfo, events: &[Vec<u8>]) -> Word {
    let seed = bcs::seed("ContractEvent");
    let hashes: Vec<Word> = events.iter().map(|e| bcs::sha3(&[&seed, e])).collect();
    let root = bcs::accumulator_root(&bcs::seed("EventAccumulator"), &hashes);
    bcs::sha3(&[
        &bcs::seed("TransactionInfo"),
        &bcs::transaction_info(info, &root),
    ])
}

/// The siblings of leaf `index` in an accumulator of `leaves` (all of them, the first at version 0).
pub fn siblings(leaves: &[Word], index: usize) -> Vec<Word> {
    let seed = bcs::seed("TransactionAccumulator");
    let mut level = leaves.to_vec();
    let mut i = index;
    let mut out = Vec::new();
    while level.len() > 1 {
        if level.len() % 2 == 1 {
            level.push(bcs::PLACEHOLDER);
        }
        out.push(level[i ^ 1]);
        level = level
            .as_chunks::<2>()
            .0
            .iter()
            .map(|[left, right]| bcs::node(&seed, left, right))
            .collect();
        i /= 2;
    }
    out
}

/// A slots claim: a trusted set of `powers.len()` validators at epoch 40, `hops` epoch changes signed by every
/// validator, a ledger info of the last epoch over an accumulator of `leaves` transactions, the vault's `attest` at
/// `index` with a fee event after it.
pub fn claim(powers: &[u64], hops: usize, leaves: usize, index: usize) -> Claim {
    let slots = alloc::vec![[1u8; 32], [25u8; 32]];
    let values = alloc::vec![[0xd1u8; 32], [0u8; 32]];
    let timestamp = 1_791_100_000_123_456;
    let record = bcs::record(CHAIN_ID, &VAULT_ID, timestamp, &slots, &values);
    let events = alloc::vec![attested(&PACKAGE, &record), fee_event()];
    let infos: Vec<TransactionInfo> = (0..leaves as u64).map(info).collect();
    let hashes: Vec<Word> = infos
        .iter()
        .enumerate()
        .map(|(i, inf)| {
            if i == index {
                leaf(inf, &events)
            } else {
                leaf(inf, &[fee_event()])
            }
        })
        .collect();
    let root = bcs::accumulator_root(&bcs::seed("TransactionAccumulator"), &hashes);
    let (trusted, keys0) = set(40, 0, powers);
    let mut keys = alloc::vec![keys0];
    let mut hop_list = Vec::new();
    let mut current = trusted.clone();
    for h in 0..hops {
        let (next, next_keys) = set(current.epoch + 1, 100 * (h as u64 + 1), powers);
        let li = ledger_info(
            current.epoch,
            10 * h as u64,
            [h as u8; 32],
            Some(next.clone()),
        );
        let all: Vec<usize> = (0..powers.len()).collect();
        hop_list.push(sign(li, keys.last().unwrap(), &all));
        keys.push(next_keys);
        current = next;
    }
    let all: Vec<usize> = (0..powers.len()).collect();
    let final_li = sign(
        ledger_info(current.epoch, leaves as u64 - 1, root, None),
        keys.last().unwrap(),
        &all,
    );
    Claim {
        input: Input::Slots {
            trusted,
            hops: hop_list,
            ledger_info: final_li,
            transaction: Included {
                version: index as u64,
                info: infos[index].clone(),
                siblings: siblings(&hashes, index),
                events,
            },
            chain_id: CHAIN_ID,
            package: PACKAGE,
            vault_id: VAULT_ID,
            timestamp,
            slots,
            values,
        },
        keys,
        leaves: hashes,
        index,
    }
}

impl Claim {
    /// After the transaction's info or events change: its leaf, the accumulator's root and path, and the ledger
    /// info's signature, all made again, so only the change itself can fail.
    pub fn reroot(&mut self) {
        let Input::Slots {
            ledger_info,
            transaction,
            ..
        } = &mut self.input
        else {
            unreachable!()
        };
        self.leaves[self.index] = leaf(&transaction.info, &transaction.events);
        transaction.siblings = siblings(&self.leaves, self.index);
        ledger_info.ledger_info.commit_info.executed_state_id =
            bcs::accumulator_root(&bcs::seed("TransactionAccumulator"), &self.leaves);
        resign(ledger_info, self.keys.last().unwrap());
    }
}
