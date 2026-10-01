//! P1's program (Stage B spec, section 10). It reads the statement's input, checks it with `xindex_finality::verify`,
//! and commits the public values the verifier contracts decode. An input for which the statement does not hold makes
//! the program panic, so no proof of it exists.
#![no_main]
sp1_zkvm::entrypoint!(main);

pub fn main() {
    xindex_finality::cycles::start("read");
    let input = sp1_zkvm::io::read::<xindex_finality::Input>();
    xindex_finality::cycles::end("read");
    match xindex_finality::verify(&input) {
        Ok(output) => sp1_zkvm::io::commit_slice(&output.abi_encode()),
        Err(error) => panic!("the statement does not hold: {error:?}"),
    }
}
