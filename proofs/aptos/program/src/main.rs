//! Aptos's state verifier's program (`design/2026-10-04-four-chains-interfaces.md`). It reads the statement's input, an
//! update or slots, checks it with `xindex_aptos::verify`, and commits the public values `AptosStateVerifier` decodes.
//! An input for which the statement does not hold makes the program panic, so no proof of it exists.
#![no_main]
sp1_zkvm::entrypoint!(main);

pub fn main() {
    let input = sp1_zkvm::io::read::<xindex_aptos::Input>();
    match xindex_aptos::verify(&input) {
        Ok(output) => sp1_zkvm::io::commit_slice(&output.abi_encode()),
        Err(error) => panic!("the statement does not hold: {error:?}"),
    }
}
