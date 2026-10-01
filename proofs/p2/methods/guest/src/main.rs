//! P2's guest (Stage B spec, section 11), P1's statement in RISC Zero. It reads the input P1's program reads, the
//! bincode of `xindex_finality::Input` that `p1-input` writes, checks it with `xindex_finality::verify`, and commits
//! the same public values the verifier contracts decode as its journal. An input for which the statement does not
//! hold makes the guest panic, so no receipt of it exists.
use risc0_zkvm::guest::env;
use std::io::Read;

fn main() {
    let mut bytes = Vec::new();
    env::stdin()
        .read_to_end(&mut bytes)
        .expect("the input");
    let input: xindex_finality::Input = bincode::deserialize(&bytes).expect("an Input");
    drop(bytes);
    match xindex_finality::verify(&input) {
        Ok(output) => env::commit_slice(&output.abi_encode()),
        Err(e) => panic!("the statement does not hold: {e:?}"),
    }
}
