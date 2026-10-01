//! A synthetic chain for tests and for running the program on inputs of any size: validators with known keys, real
//! signatures, a checkpoint block whose state and body commit to what the statement reads, and execution headers as
//! RLP. Nothing here is used by the statement itself.

use crate::beacon::{
    compute_domain, deposit_message_root, fork_version, signing_root, AttestationData,
    BeaconBlockHeader, Checkpoint, DOMAIN_BEACON_ATTESTER, DOMAIN_DEPOSIT, GENESIS_FORK_VERSION,
    GENESIS_VALIDATORS_ROOT,
};
use crate::bls::DST;
use crate::execution::keccak;
use crate::registry::{self, validators_root, Validator};
use crate::ssz::hash_pair;
use crate::statement::{Aggregate, Anchor, Input, NewKey};
use crate::Root;
use bls12_381::hash_to_curve::{ExpandMsgXmd, HashToCurve};
use bls12_381::{G1Affine, G2Projective, Scalar};
use group::Curve;
use sha2::Sha256;

/// Validators with known secret keys, as the registry holds them.
pub struct Chain {
    pub secrets: Vec<Scalar>,
    pub validators: Vec<Validator>,
    pub keys: Vec<G1Affine>,
}

impl Chain {
    /// The y coordinate of validator `i`'s key, big-endian, as a signer's record carries it.
    pub fn key_y(&self, i: usize) -> [u8; 48] {
        self.keys[i].to_uncompressed()[48..].try_into().unwrap()
    }

    /// The registry as the input carries it, with C1 at `c1_epoch` and keys for `signers`.
    pub fn registry(&self, c1_epoch: u64, signers: &[u32]) -> Vec<u8> {
        let mut signs = vec![false; self.validators.len()];
        for &i in signers {
            if let Some(s) = signs.get_mut(i as usize) {
                *s = true;
            }
        }
        registry::encode(&self.validators, c1_epoch, |i| {
            signs[i].then(|| self.key_y(i))
        })
    }
}

/// `n` active validators with secret keys 1,000 on, each holding `balance` Gwei.
pub fn chain(n: usize, balance: u64) -> Chain {
    let secrets: Vec<Scalar> = (0..n).map(|i| Scalar::from(1_000 + i as u64)).collect();
    let mut validators = Vec::new();
    let mut keys = Vec::new();
    for s in &secrets {
        let point = (G1Affine::generator() * s).to_affine();
        validators.push(Validator {
            pubkey: point.to_compressed(),
            withdrawal_credentials: [0x01; 32],
            effective_balance: balance,
            slashed: false,
            activation_eligibility_epoch: 0,
            activation_epoch: 0,
            exit_epoch: u64::MAX,
            withdrawable_epoch: u64::MAX,
        });
        keys.push(point);
    }
    Chain {
        secrets,
        validators,
        keys,
    }
}

/// The aggregate signature of `signers` over `data`.
pub fn sign(chain: &Chain, signers: &[u32], data: &AttestationData) -> [u8; 96] {
    let secret = signers
        .iter()
        .fold(Scalar::zero(), |acc, &i| acc + chain.secrets[i as usize]);
    sign_with(secret, data)
}

/// The signature over `data` of the secret `secret`, which may be a sum of secrets: an aggregate signature.
pub fn sign_with(secret: Scalar, data: &AttestationData) -> [u8; 96] {
    let domain = compute_domain(
        DOMAIN_BEACON_ATTESTER,
        fork_version(data.target.epoch).unwrap(),
        &GENESIS_VALIDATORS_ROOT,
    );
    let message = signing_root(&data.hash_tree_root(), &domain);
    let hashed =
        <G2Projective as HashToCurve<ExpandMsgXmd<Sha256>>>::hash_to_curve([&message[..]], DST);
    (hashed * secret).to_affine().to_compressed()
}

/// A validator added after the anchor: its key and its deposit, signed with `secret`.
pub fn new_key(secret: Scalar, amount: u64) -> NewKey {
    let pubkey = (G1Affine::generator() * secret).to_affine().to_compressed();
    let withdrawal_credentials = [0x02; 32];
    let domain = compute_domain(DOMAIN_DEPOSIT, GENESIS_FORK_VERSION, &[0u8; 32]);
    let message = signing_root(
        &deposit_message_root(&pubkey, &withdrawal_credentials, amount),
        &domain,
    );
    let hashed =
        <G2Projective as HashToCurve<ExpandMsgXmd<Sha256>>>::hash_to_curve([&message[..]], DST);
    NewKey {
        pubkey,
        withdrawal_credentials,
        amount,
        signature: (hashed * secret).to_affine().to_compressed(),
    }
}

// ---------------------------------------------------------------------
// RLP, as an execution client writes a header
// ---------------------------------------------------------------------

pub fn rlp_bytes(b: &[u8]) -> Vec<u8> {
    if b.len() == 1 && b[0] < 0x80 {
        return b.to_vec();
    }
    let mut out = length_prefix(b.len(), 0x80);
    out.extend_from_slice(b);
    out
}

pub fn rlp_list(items: &[Vec<u8>]) -> Vec<u8> {
    let payload: Vec<u8> = items.concat();
    let mut out = length_prefix(payload.len(), 0xc0);
    out.extend(payload);
    out
}

fn length_prefix(len: usize, base: u8) -> Vec<u8> {
    if len <= 55 {
        return vec![base + len as u8];
    }
    let be: Vec<u8> = len
        .to_be_bytes()
        .iter()
        .copied()
        .skip_while(|b| *b == 0)
        .collect();
    let mut out = vec![base + 55 + be.len() as u8];
    out.extend(be);
    out
}

pub fn rlp_int(x: u64) -> Vec<u8> {
    let be: Vec<u8> = x
        .to_be_bytes()
        .iter()
        .copied()
        .skip_while(|b| *b == 0)
        .collect();
    rlp_bytes(&be)
}

/// A Prague header with every field an execution client writes.
pub fn exec_header(parent: Root, number: u64) -> Vec<u8> {
    rlp_list(&[
        rlp_bytes(&parent),
        rlp_bytes(&[0x1d; 32]),
        rlp_bytes(&[0x95; 20]),
        rlp_bytes(&keccak(&[b"state", &number.to_be_bytes()])),
        rlp_bytes(&[0x56; 32]),
        rlp_bytes(&keccak(&[b"receipts", &number.to_be_bytes()])),
        rlp_bytes(&[0u8; 256]),
        rlp_int(0),
        rlp_int(number),
        rlp_int(36_000_000),
        rlp_int(12_345_678),
        rlp_int(1_750_000_000 + 12 * number),
        rlp_bytes(b"xindex"),
        rlp_bytes(&[0x33; 32]),
        rlp_bytes(&[0u8; 8]),
        rlp_int(7),
        rlp_bytes(&[0x44; 32]),
        rlp_int(0),
        rlp_int(0),
        rlp_bytes(&[0x55; 32]),
        rlp_bytes(&[0x66; 32]),
    ])
}

// ---------------------------------------------------------------------
// SSZ trees for the checkpoint's state and body
// ---------------------------------------------------------------------

/// The root of `leaves` (a power of two long) and the branch of leaf `index`, bottom up.
pub fn tree(leaves: &[Root], index: usize) -> (Root, Vec<Root>) {
    let mut layer = leaves.to_vec();
    let mut i = index;
    let mut branch = Vec::new();
    while layer.len() > 1 {
        branch.push(layer[i ^ 1]);
        layer = layer.chunks(2).map(|p| hash_pair(&p[0], &p[1])).collect();
        i /= 2;
    }
    (layer[0], branch)
}

/// An input where the anchor is at epoch `e0` and `C1` at `e0 + gap`, with `signers` voting on both links, and
/// `headers` execution blocks since the anchor.
pub fn build(chain: &Chain, e0: u64, gap: u64, signers: &[u32], headers: u64) -> Input {
    let anchor_exec = keccak(&[b"the anchor's block"]);
    let anchor = Anchor {
        epoch: e0,
        validators_root: validators_root(&chain.validators),
        exec_hash: anchor_exec,
        exec_number: 20_000_000,
    };

    // Execution headers from the anchor's block on.
    let mut exec_headers = Vec::new();
    let mut parent = anchor_exec;
    for k in 1..=headers {
        let rlp = exec_header(parent, anchor.exec_number + k);
        parent = keccak(&[&rlp]);
        exec_headers.push(rlp);
    }
    let block_hash = parent;

    // C1's block: a state holding the next registry at field 11, and a body holding the payload's block hash.
    // C1's state: the next registry at field 11, and at field 24 the header of the payload its block carried, whose
    // field 12 is the block hash.
    let new_validators_root = keccak(&[b"the registry at C1"]);
    let mut payload_leaves: Vec<Root> = (0..32u8).map(|i| [0x80 | i; 32]).collect();
    payload_leaves[12] = block_hash;
    let (payload_root, payload_branch) = tree(&payload_leaves, 12);
    let mut state_leaves: Vec<Root> = (0..64u8).map(|i| [i; 32]).collect();
    state_leaves[11] = new_validators_root;
    state_leaves[24] = payload_root;
    let (state_root, validators_branch) = tree(&state_leaves, 11);
    let (_, state_branch) = tree(&state_leaves, 24);
    let block_hash_branch = [payload_branch, state_branch].concat();
    let body_root = [0xb0; 32];
    let header = BeaconBlockHeader {
        slot: (e0 + gap) * 32,
        proposer_index: 7,
        parent_root: [9; 32],
        state_root,
        body_root,
    };

    let e1 = e0 + gap;
    let source = Checkpoint {
        epoch: e1 - 1,
        root: [0x51; 32],
    };
    let c1 = Checkpoint {
        epoch: e1,
        root: header.hash_tree_root(),
    };
    let c2 = Checkpoint {
        epoch: e1 + 1,
        root: [0x52; 32],
    };
    let justification = votes(chain, signers, source, c1);
    let finalization = votes(chain, signers, c1, c2);
    Input {
        anchor,
        registry: chain.registry(e1, signers),
        new_keys: Vec::new(),
        justification,
        finalization,
        header,
        new_validators_root,
        validators_branch,
        block_hash,
        block_hash_branch,
        exec_headers,
    }
}

/// `signers` split into two aggregates at two slots of the target epoch, overlapping by one.
pub fn votes(
    chain: &Chain,
    signers: &[u32],
    source: Checkpoint,
    target: Checkpoint,
) -> Vec<Aggregate> {
    let half = signers.len() / 2;
    let parts = [&signers[..half + 1], &signers[half..]];
    parts
        .iter()
        .enumerate()
        .map(|(k, part)| {
            let data = AttestationData {
                slot: target.epoch * 32 + k as u64,
                index: 0,
                beacon_block_root: [0x70 + k as u8; 32],
                source,
                target,
            };
            Aggregate {
                data,
                signature: sign(chain, part, &data),
                signers: part.to_vec(),
            }
        })
        .collect()
}
