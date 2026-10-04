//! The NEAR state verifier's program (`design/2026-10-03-near-stellar-interfaces.md`). It reads the statement's input,
//! checks it with `xindex_near_finality::verify`, and commits the public values `NearStateVerifier.update` decodes. An
//! input for which the statement does not hold makes the program panic, so no proof of it exists.
#![no_main]
sp1_zkvm::entrypoint!(main);

pub fn main() {
    let input = sp1_zkvm::io::read::<xindex_near_finality::Input>();
    match xindex_near_finality::verify(&input) {
        Ok(output) => sp1_zkvm::io::commit_slice(&output.abi_encode()),
        Err(error) => panic!("the statement does not hold: {error:?}"),
    }
}
