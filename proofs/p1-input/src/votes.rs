//! The two links' votes, from the blocks that carried them: each on-chain aggregate spans the committees its
//! `committee_bits` name, in index order, and its `aggregation_bits` pick the signers among their members.

use crate::rpc::{hex_bytes, hex_fixed, number, Nodes};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use xindex_finality::beacon::{AttestationData, Checkpoint};
use xindex_finality::{Aggregate, Root};

/// An aggregate with its signers' global validator indices, before they are mapped to the input's.
pub struct Vote {
    pub data: AttestationData,
    pub signature: [u8; 96],
    pub signers: Vec<u64>,
}

fn checkpoint(v: &Value) -> Result<Checkpoint, String> {
    Ok(Checkpoint {
        epoch: number(&v["epoch"])?,
        root: hex_fixed(&v["root"])?,
    })
}

fn data(v: &Value) -> Result<AttestationData, String> {
    Ok(AttestationData {
        slot: number(&v["slot"])?,
        index: number(&v["index"])?,
        beacon_block_root: hex_fixed(&v["beacon_block_root"])?,
        source: checkpoint(&v["source"])?,
        target: checkpoint(&v["target"])?,
    })
}

/// Each committee's members by (slot, index), for one epoch.
fn committees(nodes: &Nodes, epoch: u64) -> Result<HashMap<(u64, u64), Vec<u64>>, String> {
    let list = nodes.beacon(&format!(
        "/eth/v1/beacon/states/head/committees?epoch={epoch}"
    ))?;
    let mut out = HashMap::new();
    for c in list.as_array().ok_or("committees: not a list")? {
        let members = c["validators"]
            .as_array()
            .ok_or("committee: no validators")?;
        let members = members
            .iter()
            .map(number)
            .collect::<Result<Vec<u64>, String>>()?;
        out.insert((number(&c["slot"])?, number(&c["index"])?), members);
    }
    Ok(out)
}

/// The signers of one on-chain (Electra) attestation.
fn signers(
    a: &Value,
    committees: &HashMap<(u64, u64), Vec<u64>>,
    slot: u64,
) -> Result<Vec<u64>, String> {
    let committee_bits = hex_bytes(&a["committee_bits"])?;
    let mut members: Vec<u64> = Vec::new();
    for i in 0..committee_bits.len() * 8 {
        if committee_bits[i / 8] >> (i % 8) & 1 == 1 {
            members.extend(
                committees
                    .get(&(slot, i as u64))
                    .ok_or(format!("no committee {i} at slot {slot}"))?,
            );
        }
    }
    // A bitlist: its highest set bit marks its length.
    let bits = hex_bytes(&a["aggregation_bits"])?;
    let top = (0..bits.len() * 8)
        .rev()
        .find(|&i| bits[i / 8] >> (i % 8) & 1 == 1)
        .ok_or("empty bitlist")?;
    if top != members.len() {
        return Err(format!(
            "aggregation bits for {top} members, committees hold {}",
            members.len()
        ));
    }
    Ok((0..top)
        .filter(|&i| bits[i / 8] >> (i % 8) & 1 == 1)
        .map(|i| members[i])
        .collect())
}

/// Every vote in the blocks of epochs `e1` to `e1 + 2` for the link into `c1` (from whichever source most signers
/// share) and for the link from `c1` to its child checkpoint (whichever root most signers share).
pub fn collect(nodes: &Nodes, c1: Checkpoint) -> Result<(Vec<Vote>, Vec<Vote>), String> {
    let e1 = c1.epoch;
    let mut committees_by_epoch = BTreeMap::new();
    for e in [e1, e1 + 1] {
        committees_by_epoch.insert(e, committees(nodes, e)?);
    }
    let mut into: BTreeMap<Root, Vec<Vote>> = BTreeMap::new();
    let mut out_of: BTreeMap<Root, Vec<Vote>> = BTreeMap::new();
    let mut seen: HashSet<Vec<u8>> = HashSet::new();
    for slot in e1 * 32..(e1 + 3) * 32 {
        let block = match nodes.beacon(&format!("/eth/v2/beacon/blocks/{slot}")) {
            Ok(b) => b,
            Err(e) if e.ends_with("not found") => continue, // an empty slot
            Err(e) => return Err(e),
        };
        for a in block["message"]["body"]["attestations"]
            .as_array()
            .ok_or("no attestations")?
        {
            let d = data(&a["data"])?;
            let into_c1 = d.target == c1;
            let out_of_c1 = d.source == c1 && d.target.epoch == e1 + 1;
            if !into_c1 && !out_of_c1 {
                continue;
            }
            // The same aggregate can be included in more than one block.
            let key = serde_json::to_vec(a).map_err(|e| e.to_string())?;
            if !seen.insert(key) {
                continue;
            }
            let committees = &committees_by_epoch[&d.target.epoch];
            let vote = Vote {
                data: d,
                signature: hex_fixed(&a["signature"])?,
                signers: signers(a, committees, d.slot)?,
            };
            if into_c1 {
                into.entry(d.source.root).or_default().push(vote);
            } else {
                out_of.entry(d.target.root).or_default().push(vote);
            }
        }
    }
    let widest = |groups: BTreeMap<Root, Vec<Vote>>| -> Vec<Vote> {
        groups
            .into_values()
            .max_by_key(|votes| {
                votes
                    .iter()
                    .flat_map(|v| v.signers.iter())
                    .collect::<HashSet<_>>()
                    .len()
            })
            .unwrap_or_default()
    };
    Ok((widest(into), widest(out_of)))
}

/// The votes with their signers as the input's indices: the anchor's registry for an index it holds, and past it the
/// position in `new` of a validator added since, which the caller supplies a key for.
pub fn aggregates(votes: Vec<Vote>, registry: usize, new: &mut Vec<u64>) -> Vec<Aggregate> {
    votes
        .into_iter()
        .map(|v| Aggregate {
            data: v.data,
            signature: v.signature,
            signers: v
                .signers
                .iter()
                .map(|&i| {
                    if (i as usize) < registry {
                        return i as u32;
                    }
                    let k = new.iter().position(|&j| j == i).unwrap_or_else(|| {
                        new.push(i);
                        new.len() - 1
                    });
                    (registry + k) as u32
                })
                .collect(),
        })
        .collect()
}
