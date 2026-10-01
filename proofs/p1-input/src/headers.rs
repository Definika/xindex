//! Execution headers as RLP, rebuilt from an execution node's JSON and checked against their hashes.

use crate::rpc::{hex_bytes, number, Nodes};
use serde_json::{json, Value};
use xindex_finality::execution::keccak;
use xindex_finality::testkit::{rlp_bytes, rlp_int, rlp_list};
use xindex_finality::Root;

/// Fields as a header encodes them, in order; the last five exist from London, Shanghai, Cancun and Prague on.
const FIELDS: [(&str, bool); 21] = [
    ("parentHash", false),
    ("sha3Uncles", false),
    ("miner", false),
    ("stateRoot", false),
    ("transactionsRoot", false),
    ("receiptsRoot", false),
    ("logsBloom", false),
    ("difficulty", true),
    ("number", true),
    ("gasLimit", true),
    ("gasUsed", true),
    ("timestamp", true),
    ("extraData", false),
    ("mixHash", false),
    ("nonce", false),
    ("baseFeePerGas", true),
    ("withdrawalsRoot", false),
    ("blobGasUsed", true),
    ("excessBlobGas", true),
    ("parentBeaconBlockRoot", false),
    ("requestsHash", false),
];

/// The RLP of block `n`'s header, which must hash to the block's hash.
pub fn header(nodes: &Nodes, n: u64) -> Result<(Vec<u8>, Root), String> {
    let block: Value =
        nodes.execution("eth_getBlockByNumber", json!([format!("0x{n:x}"), false]))?;
    let mut items = Vec::new();
    for (name, is_integer) in FIELDS {
        let Some(v) = block.get(name) else { break };
        if v.is_null() {
            break;
        }
        items.push(if is_integer {
            rlp_int(number(v)?)
        } else {
            rlp_bytes(&hex_bytes(v)?)
        });
    }
    let rlp = rlp_list(&items);
    let hash: Root = crate::rpc::hex_fixed(&block["hash"])?;
    if keccak(&[&rlp]) != hash {
        return Err(format!(
            "block {n}: the rebuilt header does not hash to the block's hash"
        ));
    }
    Ok((rlp, hash))
}
