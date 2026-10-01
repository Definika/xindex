//! A vault message's log, shown in a block a P1 proof covered: the block's leaf at its place in the headers tree the
//! proof recorded, then the receipt under the block's receipts root, which must have succeeded, and the log in it. As
//! `EthereumFinalityVerifier.verifyEvent` checks it on an EVM chain.

use crate::mpt;
use crate::rlp::{to_item, Item};
use crate::{keccak, VerifierError};

/// A block covered by a proof: its leaf's fields, and the leaf's path to the headers root that proof recorded.
pub struct Header {
    pub headers_root: [u8; 32],
    pub number: u64,
    pub timestamp: u64,
    pub state_root: [u8; 32],
    pub receipts_root: [u8; 32],
    pub path: Vec<[u8; 32]>,
}

/// An event proof: the block, the receipt's trie nodes, and which transaction and log.
pub struct EventProof<'a> {
    pub header: Header,
    pub nodes: Vec<&'a [u8]>,
    pub tx_index: u32,
    pub log_index: u32,
}

pub struct Log<'a> {
    pub emitter: [u8; 20],
    pub topic0: [u8; 32],
    pub topic1: [u8; 32],
    pub data: &'a [u8],
}

struct Reader<'a> {
    data: &'a [u8],
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], VerifierError> {
        if self.data.len() < n {
            return Err(VerifierError::BadEventProof);
        }
        let (head, rest) = self.data.split_at(n);
        self.data = rest;
        Ok(head)
    }
    fn word(&mut self) -> Result<[u8; 32], VerifierError> {
        Ok(self.take(32)?.try_into().unwrap())
    }
    fn u64(&mut self) -> Result<u64, VerifierError> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> Result<u32, VerifierError> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u16(&mut self) -> Result<u16, VerifierError> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u8(&mut self) -> Result<u8, VerifierError> {
        Ok(self.take(1)?[0])
    }
}

/// Reads `headersRoot (32) ++ number (u64) ++ timestamp (u64) ++ stateRoot (32) ++ receiptsRoot (32) ++ path count
/// (u8) ++ path ++ node count (u8) ++ each node's length (u16) and bytes ++ txIndex (u32) ++ logIndex (u32)`, integers
/// little-endian, which must be the whole of `proof`.
pub fn parse(proof: &[u8]) -> Result<EventProof<'_>, VerifierError> {
    let mut r = Reader { data: proof };
    let headers_root = r.word()?;
    let number = r.u64()?;
    let timestamp = r.u64()?;
    let state_root = r.word()?;
    let receipts_root = r.word()?;
    let path = (0..r.u8()?)
        .map(|_| r.word())
        .collect::<Result<Vec<_>, _>>()?;
    let mut nodes = Vec::new();
    for _ in 0..r.u8()? {
        let len = r.u16()? as usize;
        nodes.push(r.take(len)?);
    }
    let tx_index = r.u32()?;
    let log_index = r.u32()?;
    if !r.data.is_empty() {
        return Err(VerifierError::BadEventProof);
    }
    Ok(EventProof {
        header: Header {
            headers_root,
            number,
            timestamp,
            state_root,
            receipts_root,
            path,
        },
        nodes,
        tx_index,
        log_index,
    })
}

/// The header's leaf lies at its place in the tree a proof recorded over blocks `first` to `last`: `number - first`, at
/// a depth of `ceil(log2(last - first + 1))`, a zero standing in for an odd layer's missing sibling. The leaf is
/// `keccak256(abi.encode(uint256 number, uint256 timestamp, stateRoot, receiptsRoot))`.
pub fn check_header(h: &Header, first: u64, last: u64) -> Result<(), VerifierError> {
    if h.number < first || h.number > last {
        return Err(VerifierError::NotInRange);
    }
    let depth = (64 - (last - first).leading_zeros()) as usize;
    if h.path.len() != depth {
        return Err(VerifierError::BadHeaderPath);
    }
    let mut node = keccak(&[
        &word(h.number),
        &word(h.timestamp),
        &h.state_root,
        &h.receipts_root,
    ]);
    let index = h.number - first;
    for (i, sibling) in h.path.iter().enumerate() {
        node = if (index >> i) & 1 == 1 {
            keccak(&[sibling, &node])
        } else {
            keccak(&[&node, sibling])
        };
    }
    if node != h.headers_root {
        return Err(VerifierError::BadHeaderPath);
    }
    Ok(())
}

/// The `log_index`-th log of the receipt of transaction `tx_index`, which must have succeeded, proven under
/// `receipts_root`. The log must carry at least two topics.
pub fn log<'a>(
    receipts_root: &[u8; 32],
    nodes: &[&'a [u8]],
    tx_index: u32,
    log_index: u32,
) -> Result<Log<'a>, VerifierError> {
    let (key, nibbles) = mpt::receipt_key(tx_index).ok_or(VerifierError::NoReceipt)?;
    let value = mpt::get(receipts_root, &key, nibbles, nodes)
        .map_err(|_| VerifierError::BadReceiptProof)?
        .ok_or(VerifierError::NoReceipt)?;
    let receipt = receipt(&value)?;
    let fields = receipt
        .items()
        .map_err(|_| VerifierError::BadReceiptProof)?;
    if fields.len() < 4 {
        return Err(VerifierError::BadReceiptProof);
    }
    if fields[0]
        .uint()
        .map_err(|_| VerifierError::BadReceiptProof)?
        != 1
    {
        return Err(VerifierError::FailedTransaction);
    }
    let logs = fields[3]
        .items()
        .map_err(|_| VerifierError::BadReceiptProof)?;
    let log = logs.get(log_index as usize).ok_or(VerifierError::NoLog)?;
    let parts = log.items().map_err(|_| VerifierError::BadReceiptProof)?;
    if parts.len() < 3 {
        return Err(VerifierError::BadReceiptProof);
    }
    let emitter: [u8; 20] = parts[0]
        .bytes()
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or(VerifierError::BadReceiptProof)?;
    let topics = parts[1]
        .items()
        .map_err(|_| VerifierError::BadReceiptProof)?;
    if topics.len() < 2 {
        return Err(VerifierError::NoLog);
    }
    let topic = |t: &Item| t.bytes32().map_err(|_| VerifierError::BadReceiptProof);
    Ok(Log {
        emitter,
        topic0: topic(&topics[0])?,
        topic1: topic(&topics[1])?,
        data: parts[2]
            .bytes()
            .map_err(|_| VerifierError::BadReceiptProof)?,
    })
}

/// A receipt is the list (status, cumulativeGasUsed, logsBloom, logs), after its type byte if it has one: a typed
/// receipt's first byte is its type, below every RLP list's prefix.
fn receipt<'a>(value: &Item<'a>) -> Result<Item<'a>, VerifierError> {
    let bytes = value.bytes().map_err(|_| VerifierError::BadReceiptProof)?;
    let first = *bytes.first().ok_or(VerifierError::BadReceiptProof)?;
    let list = if first < 0xc0 { &bytes[1..] } else { bytes };
    to_item(list).map_err(|_| VerifierError::BadReceiptProof)
}

fn word(x: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&x.to_be_bytes());
    w
}
