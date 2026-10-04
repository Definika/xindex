//! SCP's quorum sets, as stellar-core reads them (`QuorumSetUtils`, `LocalNode::isQuorumSlice`): a set is satisfied by
//! the nodes `S` when at least `threshold` of its members are, a validator by being in `S` and an inner set by being
//! satisfied itself.

use crate::Error;
use std::collections::BTreeSet;
use stellar_xdr::{NodeId, PublicKey, ScpQuorumSet};

/// How deep inner sets nest, at most: stellar-core's `MAXIMUM_QUORUM_NESTING_LEVEL`, counting the top set as 0.
pub const MAX_NESTING: usize = 4;

fn key(n: &NodeId) -> [u8; 32] {
    let NodeId(PublicKey::PublicKeyTypeEd25519(k)) = n;
    k.0
}

/// Refuses a quorum set no sound configuration has: one nested deeper than stellar-core allows, one naming a validator
/// twice (who would then count twice), or a level whose threshold is zero (satisfied by nobody) or above its members
/// (satisfied never). The verifier pins the set, so this guards against a mistaken pin, not an attacker.
pub fn check_sane(q: &ScpQuorumSet) -> Result<(), Error> {
    let mut seen = BTreeSet::new();
    sane(q, 0, &mut seen)
}

fn sane(q: &ScpQuorumSet, depth: usize, seen: &mut BTreeSet<[u8; 32]>) -> Result<(), Error> {
    if depth > MAX_NESTING {
        return Err(Error::BadQuorumSet);
    }
    let members = q.validators.len() + q.inner_sets.len();
    if q.threshold == 0 || q.threshold as usize > members {
        return Err(Error::BadQuorumSet);
    }
    for v in q.validators.iter() {
        if !seen.insert(key(v)) {
            return Err(Error::BadQuorumSet);
        }
    }
    for inner in q.inner_sets.iter() {
        sane(inner, depth + 1, seen)?;
    }
    Ok(())
}

/// Every validator the set names, at any level.
pub fn validators(q: &ScpQuorumSet) -> BTreeSet<[u8; 32]> {
    let mut out = BTreeSet::new();
    collect(q, &mut out);
    out
}

fn collect(q: &ScpQuorumSet, out: &mut BTreeSet<[u8; 32]>) {
    for v in q.validators.iter() {
        out.insert(key(v));
    }
    for inner in q.inner_sets.iter() {
        collect(inner, out);
    }
}

/// Whether the nodes `signers` satisfy `q`.
pub fn satisfied(q: &ScpQuorumSet, signers: &BTreeSet<[u8; 32]>) -> bool {
    let mut count = q
        .validators
        .iter()
        .filter(|v| signers.contains(&key(v)))
        .count();
    count += q
        .inner_sets
        .iter()
        .filter(|i| satisfied(i, signers))
        .count();
    count >= q.threshold as usize
}
