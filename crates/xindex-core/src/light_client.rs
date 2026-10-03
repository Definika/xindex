//! The rules of `FinalityVerifier.sol`, which P1 and P2 share on every vault chain: the anchor a proof must start from
//! and the step it moves, the day's lag past which a verifier stops for good (LG-4), and the checks of a vault message's
//! log and of a checkpoint in a block a recorded proof covered. Where a chain keeps the anchor and the recorded ranges
//! is its own: it passes them in, and records what `advance` returns.

use crate::crypto::Crypto;
use crate::event;

/// Everything the light client refuses, by name. A chain maps each to its own error code.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    WrongAnchor,
    BadPublicValues,
    Lagging,
    UnknownHeaders,
    NotInRange,
    BadHeaderPath,
    BadEventProof,
    BadReceiptProof,
    NoReceipt,
    FailedTransaction,
    NoLog,
    NotTheLog,
    NotTheCheckpoint,
}

/// `abi.encode(anchorIn, anchorOut, epoch, headersRoot, first, last)`, as the P1 program commits it and P2's journal
/// carries it.
pub const PUBLIC_VALUES_LEN: usize = 6 * 32;
/// How long after its anchor's epoch began a verifier still takes a proof, as `FinalityVerifier.MAX_LAG`. Past it the
/// verifier stops for good: catching up from an old anchor would trust stake that may have left since, and could sign
/// a forged finality at no risk (LG-4).
pub const MAX_LAG: u64 = 86_400;
/// An epoch's length: 32 slots of 12 seconds.
pub const SECONDS_PER_EPOCH: u64 = 384;

/// The last second a verifier anchored at `epoch` takes a proof: `genesisTime + epoch * 384 + MAX_LAG`, saturating, as
/// `FinalityVerifier.lagEnds()`.
pub fn lag_ends(epoch: u64, genesis_time: u64) -> u64 {
    epoch
        .saturating_mul(SECONDS_PER_EPOCH)
        .saturating_add(genesis_time)
        .saturating_add(MAX_LAG)
}

/// Refuses an update at `now` (unix seconds) past `lag_ends`, as `FinalityVerifier.update` does. The statement bounds a
/// step to 225 epochs, which is one day, so an honest prover keeps up only by proving at least daily (LG-4).
pub fn check_lag(epoch: u64, genesis_time: u64, now: i64) -> Result<(), Error> {
    if i128::from(now) > i128::from(lag_ends(epoch, genesis_time)) {
        return Err(Error::Lagging);
    }
    Ok(())
}

/// What a P1 or P2 proof commits: the anchor in and out, the epoch of its checkpoint, and the headers root over the
/// blocks `first` to `last`.
pub struct PublicValues {
    pub anchor_in: [u8; 32],
    pub anchor_out: [u8; 32],
    pub epoch: u64,
    pub headers_root: [u8; 32],
    pub first: u64,
    pub last: u64,
}

impl PublicValues {
    pub fn decode(values: &[u8]) -> Result<Self, Error> {
        if values.len() != PUBLIC_VALUES_LEN {
            return Err(Error::BadPublicValues);
        }
        let word = |i: usize| -> [u8; 32] { values[32 * i..32 * (i + 1)].try_into().unwrap() };
        let small = |i: usize| -> Result<u64, Error> {
            let w = word(i);
            if w[..24].iter().any(|b| *b != 0) {
                return Err(Error::BadPublicValues);
            }
            Ok(u64::from_be_bytes(w[24..].try_into().unwrap()))
        };
        Ok(PublicValues {
            anchor_in: word(0),
            anchor_out: word(1),
            epoch: small(2)?,
            headers_root: word(3),
            first: small(4)?,
            last: small(5)?,
        })
    }
}

/// Moves the stored `anchor` and `epoch` one proven step: the proof's values must start from the stored anchor.
/// Returns the values, whose headers root and blocks the caller records. Check the proof itself first.
pub fn advance(
    anchor: &mut [u8; 32],
    epoch: &mut u64,
    values: &[u8],
) -> Result<PublicValues, Error> {
    let v = PublicValues::decode(values)?;
    if *anchor != v.anchor_in {
        return Err(Error::WrongAnchor);
    }
    *anchor = v.anchor_out;
    *epoch = v.epoch;
    Ok(v)
}

/// The log a vault claims a message arrived in: its block, its emitter, its two topics, and its data's hash.
pub struct LogClaim {
    pub block: u64,
    pub emitter: [u8; 20],
    pub topic0: [u8; 32],
    pub topic1: [u8; 32],
    pub data_hash: [u8; 32],
}

/// Succeeds only if `proof` (`event::parse`'s format) shows that very log, of a successful transaction, in its claimed
/// block, at its place under a headers root a proof recorded. `range` gives the blocks the proof that recorded a headers
/// root covered, `UnknownHeaders` if none did.
pub fn verify_event<C: Crypto>(
    c: &C,
    proof: &[u8],
    claim: &LogClaim,
    range: impl FnOnce(&[u8; 32]) -> Result<(u64, u64), Error>,
) -> Result<(), Error> {
    let p = event::parse(proof)?;
    let (first, last) = range(&p.header.headers_root)?;
    event::check_header(c, &p.header, first, last)?;
    if p.header.number != claim.block {
        return Err(Error::NotTheLog);
    }
    let log = event::log(
        c,
        &p.header.receipts_root,
        &p.nodes,
        p.tx_index,
        p.log_index,
    )?;
    if log.emitter != claim.emitter
        || log.topic0 != claim.topic0
        || log.topic1 != claim.topic1
        || c.keccak256(&[log.data]) != claim.data_hash
    {
        return Err(Error::NotTheLog);
    }
    Ok(())
}

/// The checkpoint a vault claims: a block, its timestamp and its state root.
pub struct CheckpointClaim {
    pub block: u64,
    pub timestamp: u64,
    pub state_root: [u8; 32],
}

/// Succeeds only if `proof` (`event::parse_header`'s format) places that very block, with that timestamp and state root,
/// under a headers root a proof recorded, as `FinalityVerifier.verifyCheckpoint` returns it.
pub fn verify_checkpoint<C: Crypto>(
    c: &C,
    proof: &[u8],
    claim: &CheckpointClaim,
    range: impl FnOnce(&[u8; 32]) -> Result<(u64, u64), Error>,
) -> Result<(), Error> {
    let h = event::parse_header(proof)?;
    let (first, last) = range(&h.headers_root)?;
    event::check_header(c, &h, first, last)?;
    if h.number != claim.block || h.timestamp != claim.timestamp || h.state_root != claim.state_root
    {
        return Err(Error::NotTheCheckpoint);
    }
    Ok(())
}
