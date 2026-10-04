//! MEASUREMENT ONLY, never a verifier's program: the statement against an expected contract event the input names, so
//! execute mode can cost it on a real mainnet ledger before any vault exists. It commits the production layout with the
//! event's contract id as the vault id and the hash of the event's XDR as the record hash.
#![no_main]
sp1_zkvm::entrypoint!(main);

use xindex_stellar::stellar_xdr::ContractEvent;

pub fn main() {
    let input = sp1_zkvm::io::read::<xindex_stellar::Input>();
    let expected_bytes = sp1_zkvm::io::read::<Vec<u8>>();
    let expected: ContractEvent = xindex_stellar::xdr::decode(&expected_bytes, "expected").unwrap();
    let vault_id = match &expected.contract_id {
        Some(id) => id.0 .0,
        None => [0u8; 32],
    };
    match xindex_stellar::verify_event(&input, &expected) {
        Ok(proven) => {
            let output = xindex_stellar::Output {
                proven,
                vault_id,
                record_hash: xindex_stellar::keccak256(&expected_bytes),
            };
            sp1_zkvm::io::commit_slice(&output.abi_encode())
        }
        Err(error) => panic!("the statement does not hold: {error:?}"),
    }
}
