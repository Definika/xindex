//! `fixtures/attest.json`, which the Solidity verifier's tests read, is what the code writes now.

#[test]
fn the_attest_vector_is_current() {
    assert_eq!(
        include_str!("../fixtures/attest.json"),
        xindex_stellar::testkit::vector(),
        "run `cargo run --example vector` and commit the file"
    );
}

/// The record is Solidity's `abi.encode(bytes32, uint256, bytes32, bytes32[], bytes32[])`, word for word.
#[test]
fn the_record_is_solidity_abi() {
    let slots = [[1u8; 32]];
    let values = [[2u8; 32]];
    let r = xindex_stellar::attest_record(7, &[3u8; 32], &slots, &values);
    let words: Vec<&[u8]> = r.chunks(32).collect();
    assert_eq!(words.len(), 9);
    assert_eq!(words[0], &xindex_stellar::ATTEST_DOMAIN);
    assert_eq!(words[1][31], 7);
    assert_eq!(words[2], &[3u8; 32]);
    assert_eq!(
        words[3][31], 0xa0,
        "the slots start after the five head words"
    );
    assert_eq!(
        words[4][30..],
        [0x00, 0xe0],
        "the values after the slots' length and one slot"
    );
    assert_eq!(words[5][31], 1);
    assert_eq!(words[6], &[1u8; 32]);
    assert_eq!(words[7][31], 1);
    assert_eq!(words[8], &[2u8; 32]);
    assert_eq!(
        xindex_stellar::ATTEST_DOMAIN,
        xindex_stellar::keccak256(b"xindex.v4.vault-attest")
    );
}
