/// Reads an Ethereum account's storage under a trusted state root, from the proofs `eth_getProof` returns: the twin of
/// `EthereumStateReader.sol` and `crates/xindex-core/src/state_reader.rs`, whose proof format it reads. The vault uses
/// it only for its snapshot exit, under the state root of the last checkpoint P1 and P2 both accepted. Every node is
/// authenticated by its hash from the root down, or embedded in an authenticated parent (`mpt`), so a value read is
/// the one the root commits to, and a slot the proof shows absent reads zero.
///
/// A proof is `accountProof` then one storage proof per slot, in the slots' order, each a node list: `count (u8) ++
/// (length (u32, little-endian) ++ node) * count`, and nothing after.
module xindex_vault::state_reader;

use sui::hash::keccak256;
use xindex_vault::bytes;
use xindex_vault::mpt;
use xindex_vault::rlp;

/// The proof does not prove the storage: malformed, under another root, or with bytes after it.
const EBadStateProof: u64 = 141;

/// An account's RLP is the list (nonce, balance, storageRoot, codeHash).
const STORAGE_ROOT: u64 = 2;
const KEY_NIBBLES: u64 = 64;

/// The values of `slots` of `account` (20 bytes), read under `state_root` from `proof`. An account the root shows absent
/// has no storage: every slot reads zero.
public fun read_slots(
    state_root: &vector<u8>,
    account: &vector<u8>,
    slots: &vector<vector<u8>>,
    proof: &vector<u8>,
): vector<vector<u8>> {
    let (account_nodes, mut at) = mpt::read_nodes(proof, 0);
    let mut storage = vector[];
    let mut i = 0;
    while (i < slots.length()) {
        let (nodes, next) = mpt::read_nodes(proof, at);
        storage.push_back(nodes);
        at = next;
        i = i + 1;
    };
    assert!(at == proof.length(), EBadStateProof);
    let mut values = vector::tabulate!(slots.length(), |_| bytes::zero32());
    let leaf = mpt::get(proof, &account_nodes, state_root, &keccak256(account), KEY_NIBBLES);
    if (leaf.is_none()) return values;
    // The leaf's value is a string holding the account's RLP.
    let leaf = leaf.destroy_some();
    assert!(!rlp::is_list(&leaf), EBadStateProof);
    let account_item = rlp::to_item(proof, rlp::start(&leaf), rlp::len(&leaf));
    let storage_root = rlp::bytes32(proof, &rlp::at(proof, &account_item, STORAGE_ROOT));
    let mut i = 0;
    while (i < slots.length()) {
        let found = mpt::get(proof, &storage[i], &storage_root, &keccak256(&slots[i]), KEY_NIBBLES);
        if (found.is_some()) {
            // A slot's value is its RLP-encoded big-endian integer, inside the leaf's value string.
            let leaf = found.destroy_some();
            assert!(!rlp::is_list(&leaf), EBadStateProof);
            let value = rlp::to_item(proof, rlp::start(&leaf), rlp::len(&leaf));
            assert!(!rlp::is_list(&value) && rlp::len(&value) <= 32, EBadStateProof);
            let mut word = vector::tabulate!(32 - rlp::len(&value), |_| 0u8);
            word.append(rlp::bytes(proof, &value));
            *&mut values[i] = word;
        };
        i = i + 1;
    };
    values
}
