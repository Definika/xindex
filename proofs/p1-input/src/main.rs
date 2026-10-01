//! Builds P1's input from real chain data. Every piece is checked against the root that commits to it before use: a
//! state's recomputed root against its block, each execution header's hash against its child's parent hash. Usage:
//!
//! ```text
//! p1-input check-state <state.ssz>
//! p1-input build <beacon-url> <execution-url> <anchor-state.ssz> <c1-state.ssz> <out.bin>
//! ```
//!
//! The two states are the post-states of two finalized checkpoint blocks, each at its epoch's first slot, as a
//! checkpoint-sync server or a beacon node's `/eth/v2/debug/beacon/states/{id}` serves them.
mod headers;
mod rpc;
mod state;
mod votes;

use bls12_381::G1Affine;
use rpc::Nodes;
use state::{branch, State};
use std::time::Instant;
use xindex_finality::beacon::{Checkpoint, STATE_DEPTH, STATE_VALIDATORS_INDEX};
use xindex_finality::registry;
use xindex_finality::ssz::merkleize;
use xindex_finality::{verify, Anchor, Input, NewKey, Root};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("check-state") if args.len() == 2 => check_state(&args[1]),
        Some("build") if args.len() == 6 => build(&args[1], &args[2], &args[3], &args[4], &args[5]),
        _ => Err("usage: p1-input check-state <state.ssz> | p1-input build <beacon-url> <execution-url> <anchor-state.ssz> <c1-state.ssz> <out.bin>".into()),
    };
    if let Err(e) = result {
        eprintln!("{e}");
        std::process::exit(1);
    }
}

/// A checkpoint's state, parsed and hashed: its field roots, and its checkpoint (the epoch, and its block's root with
/// the state root filled in).
struct Loaded {
    state: State,
    roots: Vec<Root>,
    checkpoint: Checkpoint,
}

fn load(path: &str) -> Result<Loaded, String> {
    let state = State::parse(std::fs::read(path).map_err(|e| format!("{path}: {e}"))?)?;
    let roots = state.field_roots()?;
    let mut header = state.latest_block_header();
    if header.state_root == [0u8; 32] {
        header.state_root = merkleize(&roots, STATE_DEPTH);
    }
    if state.slot() % 32 != 0 || header.slot != state.slot() {
        return Err(format!(
            "{path}: not a checkpoint block's post-state at its epoch's first slot"
        ));
    }
    let checkpoint = Checkpoint {
        epoch: state.slot() / 32,
        root: header.hash_tree_root(),
    };
    Ok(Loaded {
        state,
        roots,
        checkpoint,
    })
}

fn check_state(path: &str) -> Result<(), String> {
    let l = load(path)?;
    let payload = l.state.payload_header()?;
    println!(
        "epoch {} checkpoint root 0x{}",
        l.checkpoint.epoch,
        hex::encode(l.checkpoint.root)
    );
    println!(
        "state root 0x{}",
        hex::encode(merkleize(&l.roots, STATE_DEPTH))
    );
    println!(
        "validators {}, pending deposits {}",
        l.state.validators().len(),
        l.state.pending_deposits().len()
    );
    println!(
        "execution block {} 0x{}",
        payload.block_number,
        hex::encode(payload.block_hash)
    );
    Ok(())
}

fn build(
    beacon: &str,
    execution: &str,
    anchor_path: &str,
    c1_path: &str,
    out: &str,
) -> Result<(), String> {
    let started = Instant::now();
    let nodes = Nodes::new(beacon, execution);
    let a = load(anchor_path)?;
    let c = load(c1_path)?;
    let a_payload = a.state.payload_header()?;
    let c_payload = c.state.payload_header()?;
    let validators = a.state.validators();
    let anchor = Anchor {
        epoch: a.checkpoint.epoch,
        validators_root: a.roots[STATE_VALIDATORS_INDEX as usize],
        exec_hash: a_payload.block_hash,
        exec_number: a_payload.block_number,
    };
    println!(
        "anchor: epoch {}, {} validators, execution block {}",
        anchor.epoch,
        validators.len(),
        anchor.exec_number
    );
    println!(
        "C1: epoch {} root 0x{}, execution block {}",
        c.checkpoint.epoch,
        hex::encode(c.checkpoint.root),
        c_payload.block_number
    );

    // C1's state: the next registry at field 11, and the payload header at field 24 with the block hash at its 12.
    let header = {
        let mut h = c.state.latest_block_header();
        h.state_root = merkleize(&c.roots, STATE_DEPTH);
        h
    };
    let (_, validators_branch) = branch(&c.roots, STATE_DEPTH, STATE_VALIDATORS_INDEX as usize);
    let (_, payload_branch) = branch(&c_payload.field_roots, 5, 12);
    let (_, state_branch) = branch(&c.roots, STATE_DEPTH, 24);

    // The votes, from the beacon node.
    let (into, out_of) = votes::collect(&nodes, c.checkpoint)?;
    let mut new: Vec<u64> = Vec::new();
    let justification = votes::aggregates(into, validators.len(), &mut new);
    let finalization = votes::aggregates(out_of, validators.len(), &mut new);
    println!(
        "votes: {} and {} aggregates, {} keys added since the anchor",
        justification.len(),
        finalization.len(),
        new.len()
    );

    // Keys added since the anchor, each with the deposit that created it: queued in the anchor's state.
    let c_validators = c.state.validators();
    let deposits = a.state.pending_deposits();
    let new_keys = new
        .iter()
        .map(|&i| {
            let pubkey = c_validators.get(i as usize).ok_or(format!("validator {i} is not in C1's registry"))?.pubkey;
            let d = deposits
                .iter()
                .find(|d| d.pubkey == pubkey)
                .ok_or(format!("validator {i}'s deposit is not queued in the anchor's state: prove a nearer checkpoint first"))?;
            Ok(NewKey { pubkey, withdrawal_credentials: d.withdrawal_credentials, amount: d.amount, signature: d.signature })
        })
        .collect::<Result<Vec<NewKey>, String>>()?;

    // The registry as the input carries it: the y coordinate of each signer's key, the only keys the statement reads,
    // and every validator that exited by C1 as four values.
    let mut ys: Vec<Option<[u8; 48]>> = vec![None; validators.len()];
    for aggregate in justification.iter().chain(finalization.iter()) {
        for &i in &aggregate.signers {
            let i = i as usize;
            if i < validators.len() && ys[i].is_none() {
                let point = Option::<G1Affine>::from(G1Affine::from_compressed_unchecked(
                    &validators[i].pubkey,
                ))
                .ok_or(format!("validator {i}'s key does not decompress"))?;
                ys[i] = Some(point.to_uncompressed()[48..].try_into().unwrap());
            }
        }
    }
    let registry = registry::encode(&validators, c.checkpoint.epoch, |i| ys[i]);
    println!(
        "registry: {} bytes, {} signers' keys",
        registry.len(),
        ys.iter().flatten().count()
    );

    // The execution headers from the anchor's block to C1's.
    let mut exec_headers = Vec::new();
    for n in anchor.exec_number + 1..=c_payload.block_number {
        exec_headers.push(headers::header(&nodes, n)?.0);
    }

    let input = Input {
        anchor,
        registry,
        new_keys,
        justification,
        finalization,
        header,
        new_validators_root: c.roots[STATE_VALIDATORS_INDEX as usize],
        validators_branch,
        block_hash: c_payload.block_hash,
        block_hash_branch: [payload_branch, state_branch].concat(),
        exec_headers,
    };
    let checked = Instant::now();
    let output = verify(&input).map_err(|e| format!("the statement does not hold: {e:?}"))?;
    println!(
        "the statement holds natively ({:.1} s); public values 0x{}",
        checked.elapsed().as_secs_f64(),
        hex::encode(output.abi_encode())
    );
    println!(
        "anchor in 0x{}\nanchor out 0x{}",
        hex::encode(output.anchor_in),
        hex::encode(output.anchor_out)
    );
    std::fs::write(out, bincode::serialize(&input).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    println!("wrote {out} in {:.1} s", started.elapsed().as_secs_f64());
    Ok(())
}
