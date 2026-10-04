//! A vault message's log, shown in a block a P1 or P2 proof covered: the block's leaf at its place in the headers tree
//! the proof recorded, then the receipt under the block's receipts root, which must have succeeded, and the log in it.
//! As `FinalityVerifier.verifyEvent` checks it on an EVM chain. A checkpoint is the same block's leaf alone, as
//! `FinalityVerifier.verifyCheckpoint` checks it.

use alloc::vec::Vec;

use crate::crypto::Crypto;
use crate::light_client::Error;
use crate::mpt;
use crate::rlp::{to_item, Item};

/// A receipt's fields: (status, cumulativeGasUsed, logsBloom, logs).
const STATUS: usize = 0;
const LOGS: usize = 3;

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
    fn take(&mut self, n: usize) -> Result<&'a [u8], Error> {
        if self.data.len() < n {
            return Err(Error::BadEventProof);
        }
        let (head, rest) = self.data.split_at(n);
        self.data = rest;
        Ok(head)
    }
    fn word(&mut self) -> Result<[u8; 32], Error> {
        Ok(self.take(32)?.try_into().unwrap())
    }
    fn u64(&mut self) -> Result<u64, Error> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> Result<u32, Error> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u8(&mut self) -> Result<u8, Error> {
        Ok(self.take(1)?[0])
    }
}

/// Reads `headersRoot (32) ++ number (u64) ++ timestamp (u64) ++ stateRoot (32) ++ receiptsRoot (32) ++ path count
/// (u8) ++ path ++ node count (u8) ++ each node's length (u32) and bytes ++ txIndex (u32) ++ logIndex (u32)`, integers
/// little-endian, which must be the whole of `proof`. A node's length is a u32 because a receipt has no size limit of
/// its own: a leaf past 64 KB is valid on Ethereum (LG-1). Nodes stay where they lie in `proof`, and each list is sized
/// once, so the heap holds at most 255 words and 255 slices.
pub fn parse(proof: &[u8]) -> Result<EventProof<'_>, Error> {
    let mut r = Reader { data: proof };
    let header = read_header(&mut r)?;
    let count = r.u8()?;
    let mut nodes = Vec::with_capacity(count.into());
    for _ in 0..count {
        let len = r.u32()? as usize;
        nodes.push(r.take(len)?);
    }
    let tx_index = r.u32()?;
    let log_index = r.u32()?;
    if !r.data.is_empty() {
        return Err(Error::BadEventProof);
    }
    Ok(EventProof {
        header,
        nodes,
        tx_index,
        log_index,
    })
}

/// Reads a checkpoint proof: an event proof's header part alone, `headersRoot ++ number ++ timestamp ++ stateRoot ++
/// receiptsRoot ++ path count (u8) ++ path`, which must be the whole of `proof`. As `FinalityVerifier.verifyCheckpoint`
/// takes `abi.encode(Header)`.
pub fn parse_header(proof: &[u8]) -> Result<Header, Error> {
    let mut r = Reader { data: proof };
    let header = read_header(&mut r)?;
    if !r.data.is_empty() {
        return Err(Error::BadEventProof);
    }
    Ok(header)
}

fn read_header(r: &mut Reader) -> Result<Header, Error> {
    let headers_root = r.word()?;
    let number = r.u64()?;
    let timestamp = r.u64()?;
    let state_root = r.word()?;
    let receipts_root = r.word()?;
    let depth = r.u8()?;
    let mut path = Vec::with_capacity(depth.into());
    for _ in 0..depth {
        path.push(r.word()?);
    }
    Ok(Header {
        headers_root,
        number,
        timestamp,
        state_root,
        receipts_root,
        path,
    })
}

/// The header's leaf lies at its place in the tree a proof recorded over blocks `first` to `last`: `number - first`, at
/// a depth of `ceil(log2(last - first + 1))`, a zero standing in for an odd layer's missing sibling. The leaf is
/// `keccak256(abi.encode(uint256 number, uint256 timestamp, stateRoot, receiptsRoot))`.
pub fn check_header<C: Crypto>(c: &C, h: &Header, first: u64, last: u64) -> Result<(), Error> {
    if h.number < first || h.number > last {
        return Err(Error::NotInRange);
    }
    let depth = (64 - (last - first).leading_zeros()) as usize;
    if h.path.len() != depth {
        return Err(Error::BadHeaderPath);
    }
    let mut node = c.keccak256(&[
        &word(h.number),
        &word(h.timestamp),
        &h.state_root,
        &h.receipts_root,
    ]);
    let index = h.number - first;
    for (i, sibling) in h.path.iter().enumerate() {
        node = if (index >> i) & 1 == 1 {
            c.keccak256(&[sibling, &node])
        } else {
            c.keccak256(&[&node, sibling])
        };
    }
    if node != h.headers_root {
        return Err(Error::BadHeaderPath);
    }
    Ok(())
}

/// The `log_index`-th log of the receipt of transaction `tx_index`, which must have succeeded, proven under
/// `receipts_root`. The log must carry at least two topics.
pub fn log<'a, C: Crypto>(
    c: &C,
    receipts_root: &[u8; 32],
    nodes: &[&'a [u8]],
    tx_index: u32,
    log_index: u32,
) -> Result<Log<'a>, Error> {
    let (key, nibbles) = mpt::receipt_key(tx_index).ok_or(Error::NoReceipt)?;
    let value = mpt::get(c, receipts_root, &key, nibbles, nodes)
        .map_err(|_| Error::BadReceiptProof)?
        .ok_or(Error::NoReceipt)?;
    // Lists are read in place, item by item, as `RlpReader.sol` reads them: a receipt of any number of logs needs no
    // heap (LG-1).
    let bad = |_| Error::BadReceiptProof;
    let receipt = receipt(&value)?;
    if receipt.at(STATUS).and_then(|s| s.uint()).map_err(bad)? != 1 {
        return Err(Error::FailedTransaction);
    }
    let logs = receipt.at(LOGS).map_err(bad)?;
    if log_index as usize >= logs.count().map_err(bad)? {
        return Err(Error::NoLog);
    }
    let log = logs.at(log_index as usize).map_err(bad)?;
    let emitter: [u8; 20] = log
        .at(0)
        .and_then(|a| a.bytes())
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or(Error::BadReceiptProof)?;
    let topics = log.at(1).map_err(bad)?;
    if topics.count().map_err(bad)? < 2 {
        return Err(Error::NoLog);
    }
    let topic = |i: usize| topics.at(i).and_then(|t| t.bytes32()).map_err(bad);
    Ok(Log {
        emitter,
        topic0: topic(0)?,
        topic1: topic(1)?,
        data: log.at(2).and_then(|d| d.bytes()).map_err(bad)?,
    })
}

/// A receipt is the list (status, cumulativeGasUsed, logsBloom, logs), after its type byte if it has one: a typed
/// receipt's first byte is its type, below every RLP list's prefix.
fn receipt<'a>(value: &Item<'a>) -> Result<Item<'a>, Error> {
    let bytes = value.bytes().map_err(|_| Error::BadReceiptProof)?;
    let first = *bytes.first().ok_or(Error::BadReceiptProof)?;
    let list = if first < 0xc0 { &bytes[1..] } else { bytes };
    to_item(list).map_err(|_| Error::BadReceiptProof)
}

/// A number as a 32-byte big-endian word, as `abi.encode(uint256)` writes it.
pub fn word(x: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&x.to_be_bytes());
    w
}
