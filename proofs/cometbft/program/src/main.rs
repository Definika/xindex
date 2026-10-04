//! The CometBFT state verifier's program (`design/2026-10-04-four-chains-interfaces.md`). It reads the statement's
//! input, an update or slots, checks it with `xindex_cometbft::verify`, and commits the public values
//! `CometBftStateVerifier` decodes. An input for which the statement does not hold makes the program panic, so no proof
//! of it exists.
#![no_main]
sp1_zkvm::entrypoint!(main);

pub fn main() {
    let input = sp1_zkvm::io::read::<xindex_cometbft::Input>();
    match xindex_cometbft::verify(&input) {
        Ok(output) => sp1_zkvm::io::commit_slice(&output.abi_encode()),
        Err(error) => panic!("the statement does not hold: {error:?}"),
    }
}
