//! The Stellar state proof's program (`design/2026-10-03-near-stellar-interfaces.md`). It reads the statement's input,
//! checks it with `xindex_stellar::verify`, which writes the vault's `attest` event itself, and commits the public
//! values `StellarStateVerifier` decodes. An input for which the statement does not hold makes it panic, so no proof of
//! it exists.
#![no_main]
sp1_zkvm::entrypoint!(main);

pub fn main() {
    xindex_stellar::cycles::start("read");
    let input = sp1_zkvm::io::read::<xindex_stellar::Input>();
    xindex_stellar::cycles::end("read");
    match xindex_stellar::verify(&input) {
        Ok(output) => sp1_zkvm::io::commit_slice(&output.abi_encode()),
        Err(error) => panic!("the statement does not hold: {error:?}"),
    }
}
