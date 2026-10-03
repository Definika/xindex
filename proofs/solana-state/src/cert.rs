//! Alpenglow's certificates, checked as Agave checks them (v4.4.0-beta.0 on devnet, v4.3.0 for mainnet).
//!
//! - **What is signed** (`votor-messages/src/wire.rs`, `VotePayloadToSign`, wincode): a tag byte, then the slot (u64 LE)
//!   and for a block the block id (32 bytes), then the cluster's shred version (u16 LE). Tags: 1 notarize, 2 finalize,
//!   3 skip, 4 notarize-fallback, 5 skip-fallback, 6 genesis. A notarize vote names a block; a finalize vote a slot.
//! - **The ciphersuite** (solana-bls-signatures 3.4.0 and 4.0.0, `hash.rs`): Ethereum's, keys in G1 (48 bytes
//!   compressed), signatures in G2, `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`, keys proven by possession when a vote
//!   account registers them.
//! - **The set** (`runtime/src/epoch_stakes.rs`, `BLSPubkeyToRankMap::new`): the epoch's staked vote accounts with a BLS
//!   key, less every account whose BLS key or node key another shares; ranked by stake, highest first, then by
//!   compressed key, ascending. Its total is theirs alone, not the epoch's.
//! - **The bitmap** (solana-signer-store 0.1.0): a version byte (0, Base2), the bit count (u16 LE), then the bits,
//!   least significant first; bit `r` is rank `r`.
//! - **Thresholds** (`votor-messages/src/certificate.rs`): finalize, notarize and skip 60%, fast finalize 80% (of
//!   notarize votes), genesis 82% (`migration.rs`), each `signed * 100 >= total * pct`.
//! - **Finality** (`runtime/src/validated_block_finalization.rs`): a block `(slot, id)` is final on a finalize
//!   certificate for `slot` and a notarize certificate for the block, or on a fast-finalize certificate for the block.

use bls12_381::{multi_miller_loop, G1Affine, G1Projective, G2Affine, G2Prepared, Gt};
use group::{Curve, Group};
use xindex_finality::bls::{hash_to_g2, DST};

pub const NOTARIZE: u8 = 1;
pub const FINALIZE: u8 = 2;
pub const GENESIS: u8 = 6;

pub const FINALIZE_PCT: u64 = 60;
pub const NOTARIZE_PCT: u64 = 60;
pub const FAST_FINALIZE_PCT: u64 = 80;
pub const GENESIS_PCT: u64 = 82;

/// The bytes a vote for a block signs: notarize (also behind a fast-finalize certificate) or genesis.
pub fn block_payload(tag: u8, slot: u64, block_id: &[u8; 32], shred_version: u16) -> Vec<u8> {
    let mut out = vec![tag];
    out.extend_from_slice(&slot.to_le_bytes());
    out.extend_from_slice(block_id);
    out.extend_from_slice(&shred_version.to_le_bytes());
    out
}

/// The bytes a finalize vote signs.
pub fn slot_payload(tag: u8, slot: u64, shred_version: u16) -> Vec<u8> {
    let mut out = vec![tag];
    out.extend_from_slice(&slot.to_le_bytes());
    out.extend_from_slice(&shred_version.to_le_bytes());
    out
}

/// A staked vote account as the epoch's stakes hold it.
#[derive(Clone, Debug)]
pub struct Validator {
    pub vote: [u8; 32],
    pub node: [u8; 32],
    pub bls: Option<[u8; 48]>,
    pub stake: u64,
}

/// The epoch's signers by rank, and the total their stake makes.
pub struct RankMap {
    pub keys: Vec<G1Affine>,
    pub stakes: Vec<u64>,
    pub total: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub enum CertError {
    BadKey,
    BadSignature,
    BadBitmap,
    MissingRank(usize),
    NotEnoughStake { signed: u64, total: u64, pct: u64 },
    Invalid,
}

impl RankMap {
    pub fn new(validators: &[Validator]) -> Result<Self, CertError> {
        let staked: Vec<&Validator> = validators
            .iter()
            .filter(|v| v.stake > 0 && v.bls.is_some())
            .collect();
        let count = |f: &dyn Fn(&Validator) -> bool| staked.iter().filter(|v| f(v)).count();
        let mut kept: Vec<&Validator> = staked
            .iter()
            .copied()
            .filter(|v| count(&|w| w.bls == v.bls) == 1 && count(&|w| w.node == v.node) == 1)
            .collect();
        kept.sort_by(|a, b| b.stake.cmp(&a.stake).then(a.bls.cmp(&b.bls)));
        let mut keys = Vec::with_capacity(kept.len());
        for v in &kept {
            let key = Option::<G1Affine>::from(G1Affine::from_compressed(&v.bls.unwrap()))
                .ok_or(CertError::BadKey)?;
            keys.push(key);
        }
        Ok(Self {
            keys,
            stakes: kept.iter().map(|v| v.stake).collect(),
            total: kept.iter().map(|v| v.stake).sum(),
        })
    }
}

/// The ranks a Base2 bitmap names. A Base3 bitmap, which finality and notarize certificates never carry, is refused.
pub fn decode_base2(bitmap: &[u8], max: usize) -> Result<Vec<usize>, CertError> {
    if bitmap.len() < 3 || bitmap[0] != 0 {
        return Err(CertError::BadBitmap);
    }
    let bits = u16::from_le_bytes([bitmap[1], bitmap[2]]) as usize;
    let data = &bitmap[3..];
    if bits > max || data.len() != bits.div_ceil(8) {
        return Err(CertError::BadBitmap);
    }
    Ok((0..bits)
        .filter(|r| data[r / 8] >> (r % 8) & 1 == 1)
        .collect())
}

/// A signature in G2, uncompressed (192 bytes, as `getAgGenesisCert` serves it) or compressed (96, as a block
/// footer carries it), checked in its subgroup.
pub fn signature(bytes: &[u8]) -> Result<G2Affine, CertError> {
    let point = match bytes.len() {
        192 => G2Affine::from_uncompressed(bytes.try_into().unwrap()),
        96 => G2Affine::from_compressed(bytes.try_into().unwrap()),
        _ => return Err(CertError::BadSignature),
    };
    Option::from(point).ok_or(CertError::BadSignature)
}

/// Checks one certificate: the aggregate of the ranks' keys verifies `signature` over `payload`, and their stake meets
/// `pct` of the set's total. Returns the stake that signed.
pub fn verify(
    map: &RankMap,
    payload: &[u8],
    signature: &G2Affine,
    bitmap: &[u8],
    pct: u64,
) -> Result<u64, CertError> {
    let ranks = decode_base2(bitmap, map.keys.len())?;
    let mut aggregate = G1Projective::identity();
    let mut signed = 0u64;
    for r in ranks {
        let key = map.keys.get(r).ok_or(CertError::MissingRank(r))?;
        aggregate += G1Projective::from(key);
        signed += map.stakes[r];
    }
    let aggregate = aggregate.to_affine();
    if bool::from(aggregate.is_identity()) {
        return Err(CertError::Invalid);
    }
    let hashed = hash_to_g2(payload, DST).to_affine();
    let result: Gt = multi_miller_loop(&[
        (&aggregate, &G2Prepared::from(hashed)),
        (&-G1Affine::generator(), &G2Prepared::from(*signature)),
    ])
    .final_exponentiation();
    if !bool::from(result.is_identity()) {
        return Err(CertError::Invalid);
    }
    if (signed as u128) * 100 < (map.total as u128) * (pct as u128) {
        return Err(CertError::NotEnoughStake {
            signed,
            total: map.total,
            pct,
        });
    }
    Ok(signed)
}

/// A finality proof for a block: slow (finalize and notarize certificates) or fast.
pub enum Finality<'a> {
    Slow {
        finalize: (&'a G2Affine, &'a [u8]),
        notarize: (&'a G2Affine, &'a [u8]),
    },
    Fast((&'a G2Affine, &'a [u8])),
}

/// Whether `(slot, block_id)` is final under `map`, as `ValidatedBlockFinalizationCert::try_from_footer` decides.
pub fn verify_finality(
    map: &RankMap,
    slot: u64,
    block_id: &[u8; 32],
    shred_version: u16,
    proof: &Finality,
) -> Result<(), CertError> {
    let notar = block_payload(NOTARIZE, slot, block_id, shred_version);
    match proof {
        Finality::Slow { finalize, notarize } => {
            verify(
                map,
                &slot_payload(FINALIZE, slot, shred_version),
                finalize.0,
                finalize.1,
                FINALIZE_PCT,
            )?;
            verify(map, &notar, notarize.0, notarize.1, NOTARIZE_PCT)?;
        }
        Finality::Fast(fast) => {
            verify(map, &notar, fast.0, fast.1, FAST_FINALIZE_PCT)?;
        }
    }
    Ok(())
}

/// `e(key, H(payload))` for each key: lets a search over signer sets multiply in GT instead of pairing per set.
pub fn per_key_pairings(keys: &[G1Affine], payload: &[u8]) -> Vec<Gt> {
    let hashed = G2Prepared::from(hash_to_g2(payload, DST).to_affine());
    keys.iter()
        .map(|k| multi_miller_loop(&[(k, &hashed)]).final_exponentiation())
        .collect()
}

/// `e(g1, signature)`, the other side of every check against `signature`.
pub fn signature_pairing(signature: &G2Affine) -> Gt {
    multi_miller_loop(&[(&G1Affine::generator(), &G2Prepared::from(*signature))])
        .final_exponentiation()
}
