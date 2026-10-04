//! VeChain's state, proven to Ethereum (`design/2026-10-04-four-chains-interfaces.md`): the statement
//! `VeChainStateVerifier`'s SP1 program proves, in plain Rust, tested natively on mainnet's own data.
//!
//! **Finality.** VIP-220 as vechain/thor's `bft` package decides it since Hayabusa (VIP-253): blocks come in rounds of
//! 180; a round is *justified* when the distinct signers of its blocks hold more than two thirds of the weight, and
//! *committed* when those who voted COM in every block they signed in it do; a committed round finalizes the
//! checkpoint (first block) of the last justified round before it. So a block at or before the checkpoint of a
//! justified round `k` is final once a later round `r` is committed. Each vote weighs the signer's weight in the
//! Staker at the round's checkpoint, and the threshold is two thirds of the Staker's total weight there.
//!
//! **Weights, without a state proof.** The weights live only in the Staker's storage, and VeChain serves no proof of
//! it. They change only at a round's first block, before its transactions run, so a transaction anywhere in the round
//! reads the round's weights. `VeChainStakerAttester.attest(table)` reverts unless the Staker's active validators and
//! weights hash to `table`; a transaction whose one clause calls it, with a receipt that did not revert, attests the
//! round's table. That receipt is trusted once blocks after it are signed by validators holding more than two thirds
//! of the weight of a table the verifier already trusts: an honest one among them executed the block, as every VeChain
//! node does before building on it. Trusted tables are thus vouched for as TRON's producer lists are.
//!
//! **State.** A slot is proven as TRON's are, by a successful call of the vault's `attest(slots, values)`, which
//! reverts unless every slot holds its value: the statement writes the transaction's one clause itself (the vault, no
//! value, the calldata), and its receipt with `reverted` false, and finds both under the block's transactions and
//! receipts roots at the same index.
//!
//! Every header's signer is recovered with secp256k1 from its signing hash, which since Galactica covers its COM vote,
//! and the chain is linked by block ids, `number ++ blake2b(signingHash ++ signer)[4:]`.

extern crate alloc;

pub mod encode;
pub mod trie;

#[cfg(feature = "json")]
pub mod json;
#[cfg(feature = "testkit")]
pub mod testkit;

use alloc::collections::BTreeMap;
use alloc::vec::Vec;
use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use serde::{Deserialize, Serialize};

pub type Address = [u8; 20];
pub type Word = [u8; 32];

/// Blocks a round holds (`thor.EpochLength`).
pub const EPOCH: u32 = 180;
/// A header's signature: secp256k1's 65 bytes, then the 81-byte VRF proof (`block.ComplexSignature`).
pub const SIGNATURE_LENGTH: usize = 146;

/// `keccak256("xindex.v4.vechain.update")` and `keccak256("xindex.v4.vechain.slots")`: the public values' first word.
pub const UPDATE: Word = hex32("37c8da6ebee6866a157792b86cf2db84b4914f18930fc5a9905994fb97ab6543");
pub const SLOTS: Word = hex32("b5a842fc2df4bcb60011cc382c5a6255b5b05f43b17cc70434b294b69ad686e6");

const fn hex32(s: &str) -> Word {
    let b = s.as_bytes();
    let mut out = [0u8; 32];
    let mut i = 0;
    while i < 32 {
        out[i] = (digit(b[2 * i]) << 4) | digit(b[2 * i + 1]);
        i += 1;
    }
    out
}

const fn digit(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        _ => panic!("hex"),
    }
}

/// A block header's fields (`block/header.go`), as given; the statement writes and hashes them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Header {
    pub parent_id: Word,
    pub timestamp: u64,
    pub gas_limit: u64,
    pub beneficiary: Address,
    pub gas_used: u64,
    pub total_score: u64,
    pub txs_root: Word,
    pub txs_features: u32,
    pub state_root: Word,
    pub receipts_root: Word,
    /// The VRF input, the parent's beta (VIP-214); signed, not otherwise checked.
    pub alpha: Vec<u8>,
    /// The signer's COM vote (VIP-220).
    pub com: bool,
    /// Big-endian; present on every header since Galactica.
    pub base_fee: Word,
    pub signature: Vec<u8>,
}

/// A transaction's fee fields: a legacy one's gas price coefficient, or a dynamic-fee one's (type `0x51`) two caps.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Fees {
    Legacy {
        gas_price_coef: u8,
    },
    Dynamic {
        max_priority_fee_per_gas: Word,
        max_fee_per_gas: Word,
    },
}

impl Fees {
    pub fn is_dynamic(&self) -> bool {
        matches!(self, Fees::Dynamic { .. })
    }
}

/// A transaction's fields but its clause, which the statement writes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Transaction {
    pub chain_tag: u8,
    pub block_ref: u64,
    pub expiration: u32,
    pub fees: Fees,
    pub gas: u64,
    pub depends_on: Option<Word>,
    pub nonce: u64,
    /// The reserved features word (1: fee delegation, VIP-191).
    pub features: u32,
    pub signature: Vec<u8>,
}

/// A receipt's fields before `reverted`, which the statement writes false, and its outputs, which it writes empty.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Receipt {
    pub gas_used: u64,
    pub gas_payer: Address,
    pub paid: Word,
    pub reward: Word,
}

/// A call proven in a block of the chain: the block's index among the chain's headers, the transaction's index in it,
/// the transaction and receipt fields, and their trie proofs, root first.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Call {
    pub block: u32,
    pub index: u32,
    pub transaction: Transaction,
    pub receipt: Receipt,
    pub transaction_proof: Vec<Vec<u8>>,
    pub receipt_proof: Vec<Vec<u8>>,
}

/// A round's weights, as the Staker gives them: its total weight and its active validators in list order, in wei.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Table {
    pub total_weight: Word,
    pub validators: Vec<(Address, Word)>,
}

/// A table attested in the round of the call's block, by a call of the attester's `attest(hash)`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attested {
    pub table: Table,
    pub call: Call,
}

/// What every claim starts from: the chain (its genesis id), the attester, the table the verifier trusts and the block
/// it is keyed by, and a chain of headers, each the parent of the next, all after that block.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Common {
    pub chain: Word,
    pub attester: Address,
    pub trusted_id: Word,
    pub trusted: Table,
    pub headers: Vec<Header>,
}

/// The two claims.
// One input is read once per run; boxing the larger claim would only add an indirection.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Input {
    /// A new table to trust, attested in its round and vouched for by the trusted one.
    Update { common: Common, attested: Attested },
    /// The vault's slots: its `attest(slots, values)` succeeded in a block at or before the checkpoint of round
    /// `justified`'s, which the signers of that round justify under its table, and a later round, `committed`'s, is
    /// committed under its own; both tables attested and vouched for.
    Slots {
        common: Common,
        vault: Address,
        slots: Vec<Word>,
        values: Vec<Word>,
        call: Call,
        justified: Attested,
        committed: Attested,
    },
}

/// What a claim proves: the public values, `Output::abi_encode`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Output {
    Update {
        chain: Word,
        attester: Address,
        trusted_id: Word,
        trusted_table: Word,
        id: Word,
        table: Word,
        time: u64,
    },
    Slots {
        chain: Word,
        attester: Address,
        trusted_id: Word,
        trusted_table: Word,
        number: u32,
        time: u64,
        vault: Address,
        slots_hash: Word,
    },
}

impl Output {
    /// `abi.encode` of the claim's words, as `VeChainStateVerifier` decodes them:
    /// update `(UPDATE, chain, attester, trustedId, trustedTable, id, table, time)`, eight words;
    /// slots `(SLOTS, chain, attester, trustedId, trustedTable, number, time, vault, slotsHash)`, nine.
    pub fn abi_encode(&self) -> Vec<u8> {
        let words: Vec<Word> = match self {
            Output::Update {
                chain,
                attester,
                trusted_id,
                trusted_table,
                id,
                table,
                time,
            } => alloc::vec![
                UPDATE,
                *chain,
                encode::word_address(attester),
                *trusted_id,
                *trusted_table,
                *id,
                *table,
                encode::word_u64(*time),
            ],
            Output::Slots {
                chain,
                attester,
                trusted_id,
                trusted_table,
                number,
                time,
                vault,
                slots_hash,
            } => alloc::vec![
                SLOTS,
                *chain,
                encode::word_address(attester),
                *trusted_id,
                *trusted_table,
                encode::word_u64(u64::from(*number)),
                encode::word_u64(*time),
                encode::word_address(vault),
                *slots_hash,
            ],
        };
        words.concat()
    }
}

/// Why a claim does not hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    /// No header.
    NoHeaders,
    /// Header `i`'s signature is not 146 bytes or recovers no key.
    BadSignature(usize),
    /// Header `i`'s parent is not header `i - 1`.
    NotLinked(usize),
    /// The chain does not start after the trusted block.
    NotAfterTrusted,
    /// A table names a validator twice, or a weight past 128 bits.
    BadTable,
    /// A call's block is not in the chain.
    NoBlock,
    /// A call's transaction is not for this chain.
    WrongChain,
    /// A call's transaction, as the statement writes it, is not its block's leaf at its index.
    NotTheTransaction,
    /// A call's receipt, written with `reverted` false and no output, is not its block's leaf at its index.
    NotTheReceipt,
    /// The signers after an attested table's call hold no more than two thirds of the trusted table's weight.
    NotVouched,
    /// The justified round's signers hold no more than two thirds of its weight.
    NotJustified,
    /// The committed round's COM voters hold no more than two thirds of its weight.
    NotCommitted,
    /// The chain lacks some of the committed round's 180 blocks.
    RoundIncomplete,
    /// The committed round is not after the justified one.
    RoundsOutOfOrder,
    /// The vault's call lies after the justified round's checkpoint.
    NotFinal,
    /// Slots and values differ in number.
    LengthMismatch,
}

/// A header the statement has checked: its number, id, signer, and vote.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Linked {
    pub number: u32,
    pub id: Word,
    pub signer: Address,
    pub com: bool,
    pub time: u64,
}

/// The signer of a header: the address of the secp256k1 key that signed its signing hash, as go-ethereum's
/// `crypto.SigToPub` recovers it from `r ++ s ++ v`.
pub fn signer(h: &Header) -> Option<Address> {
    if h.signature.len() != SIGNATURE_LENGTH {
        return None;
    }
    let hash = encode::signing_hash(h);
    let mut sig = Signature::from_slice(&h.signature[..64]).ok()?;
    let mut recid = RecoveryId::from_byte(h.signature[64])?;
    // libsecp256k1, which go-ethereum recovers with, takes a high `s`; k256 does not. `(r, n - s)` with the other
    // parity recovers the same key, so a signer cannot make its blocks unprovable by signing with a high `s`.
    if let Some(low) = sig.normalize_s() {
        sig = low;
        recid = RecoveryId::new(!recid.is_y_odd(), recid.is_x_reduced());
    }
    let key = VerifyingKey::recover_from_prehash(&hash, &sig, recid).ok()?;
    let point = key.to_encoded_point(false);
    let digest = encode::keccak(&[&point.as_bytes()[1..]]);
    let mut out = [0u8; 20];
    out.copy_from_slice(&digest[12..]);
    Some(out)
}

/// Checks every header's signature and that each is the parent of the next, and returns them checked.
pub fn link(headers: &[Header]) -> Result<Vec<Linked>, Error> {
    if headers.is_empty() {
        return Err(Error::NoHeaders);
    }
    let mut out: Vec<Linked> = Vec::with_capacity(headers.len());
    for (i, h) in headers.iter().enumerate() {
        let number = encode::number(h).ok_or(Error::NotLinked(i))?;
        if let Some(parent) = out.last() {
            if h.parent_id != parent.id {
                return Err(Error::NotLinked(i));
            }
        }
        let signer = signer(h).ok_or(Error::BadSignature(i))?;
        let id = encode::block_id(number, &encode::signing_hash(h), &signer);
        out.push(Linked {
            number,
            id,
            signer,
            com: h.com,
            time: h.timestamp,
        });
    }
    Ok(out)
}

/// A table's weights by validator, in wei, and its hash: `h0 = keccak256(abi.encode(totalWeight))`, then
/// `h = keccak256(abi.encode(h, validator, weight))` for each validator in order, as `VeChainStakerAttester.currentTable`.
pub struct Weights {
    pub hash: Word,
    pub total: u128,
    pub by: BTreeMap<Address, u128>,
}

/// A weight below 2^100 wei, about 1.27e12 VET, more than the whole supply (86.7e9 VET) at the Staker's highest
/// multiplier: no real table holds more, and sums of such weights fit 128 bits with room to spare.
fn small(w: &Word) -> Result<u128, Error> {
    if w[..19].iter().any(|b| *b != 0) || w[19] >= 0x10 {
        return Err(Error::BadTable);
    }
    let mut low = [0u8; 16];
    low.copy_from_slice(&w[16..]);
    Ok(u128::from_be_bytes(low))
}

pub fn weights(t: &Table) -> Result<Weights, Error> {
    let mut hash = encode::keccak(&[&t.total_weight]);
    let mut by = BTreeMap::new();
    for (v, w) in &t.validators {
        hash = encode::keccak(&[&hash, &encode::word_address(v), w]);
        if by.insert(*v, small(w)?).is_some() {
            return Err(Error::BadTable);
        }
    }
    Ok(Weights {
        hash,
        total: small(&t.total_weight)?,
        by,
    })
}

impl Weights {
    /// Whether `signers` hold more than two thirds of the total: `Σ > total * 2 / 3` in VET, as thor's justifier
    /// compares, is `3Σ > 2·total` for the whole VET the Staker gives in wei. A signer the table does not name weighs
    /// nothing.
    pub fn quorum<'a>(&self, signers: impl Iterator<Item = &'a Address>) -> bool {
        let mut seen = BTreeMap::new();
        let mut sum: u128 = 0;
        for s in signers {
            if seen.insert(*s, ()).is_none() {
                // Each weight is below 2^100 (`small`), so no real sum overflows; one that did would fail closed.
                match sum.checked_add(self.by.get(s).copied().unwrap_or(0)) {
                    Some(v) => sum = v,
                    None => return false,
                }
            }
        }
        match (sum.checked_mul(3), self.total.checked_mul(2)) {
            (Some(a), Some(b)) => a > b,
            _ => false,
        }
    }
}

/// Checks that the chain's block `call.block` holds, at `call.index`, a transaction with one clause calling `to` with
/// no value and `data`, and a receipt that did not revert, with `outputs` (already encoded) as its outputs.
pub fn verify_call(
    headers: &[Header],
    chain: &Word,
    call: &Call,
    to: &Address,
    data: &[u8],
    outputs: &[u8],
) -> Result<(), Error> {
    let h = headers
        .get(usize::try_from(call.block).map_err(|_| Error::NoBlock)?)
        .ok_or(Error::NoBlock)?;
    // The chain tag is the last byte of the genesis id, which consensus checks against its own.
    if call.transaction.chain_tag != chain[31] {
        return Err(Error::WrongChain);
    }
    let key = encode::index_key(call.index);
    let tx = encode::transaction(&call.transaction, to, data);
    if trie::get(&h.txs_root, &key, &call.transaction_proof) != Some(tx.as_slice()) {
        return Err(Error::NotTheTransaction);
    }
    let receipt = encode::receipt(call.transaction.fees.is_dynamic(), &call.receipt, outputs);
    if trie::get(&h.receipts_root, &key, &call.receipt_proof) != Some(receipt.as_slice()) {
        return Err(Error::NotTheReceipt);
    }
    Ok(())
}

/// A table attested in its block's round and vouched for: the attester's call succeeded there, and the signers of
/// the blocks after it hold more than two thirds of the trusted table's weight. Returns the table's weights and the
/// attesting block's round.
fn attested(
    c: &Common,
    linked: &[Linked],
    trusted: &Weights,
    a: &Attested,
) -> Result<(Weights, u32, usize), Error> {
    let w = weights(&a.table)?;
    verify_call(
        &c.headers,
        &c.chain,
        &a.call,
        &c.attester,
        &encode::staker_attest(&w.hash),
        &encode::NO_OUTPUTS,
    )?;
    let at = a.call.block as usize;
    if !trusted.quorum(linked[at + 1..].iter().map(|l| &l.signer)) {
        return Err(Error::NotVouched);
    }
    Ok((w, linked[at].number / EPOCH, at))
}

/// Checks a claim and returns the public values it proves.
pub fn verify(input: &Input) -> Result<Output, Error> {
    let c = match input {
        Input::Update { common, .. } | Input::Slots { common, .. } => common,
    };
    let trusted = weights(&c.trusted)?;
    let linked = link(&c.headers)?;
    let trusted_number = u32::from_be_bytes([
        c.trusted_id[0],
        c.trusted_id[1],
        c.trusted_id[2],
        c.trusted_id[3],
    ]);
    // Every block proven is after the trusted one: an attester or a vault deployed after it was there.
    if linked[0].number <= trusted_number {
        return Err(Error::NotAfterTrusted);
    }
    match input {
        Input::Update { attested: a, .. } => {
            let (w, _, at) = attested(c, &linked, &trusted, a)?;
            Ok(Output::Update {
                chain: c.chain,
                attester: c.attester,
                trusted_id: c.trusted_id,
                trusted_table: trusted.hash,
                id: linked[at].id,
                table: w.hash,
                time: linked[at].time,
            })
        }
        Input::Slots {
            vault,
            slots,
            values,
            call,
            justified,
            committed,
            ..
        } => {
            if slots.len() != values.len() {
                return Err(Error::LengthMismatch);
            }
            verify_call(
                &c.headers,
                &c.chain,
                call,
                vault,
                &encode::vault_attest(slots, values),
                &encode::NO_OUTPUTS,
            )?;
            let (wk, k, _) = attested(c, &linked, &trusted, justified)?;
            let (wr, r, _) = attested(c, &linked, &trusted, committed)?;
            if k >= r {
                return Err(Error::RoundsOutOfOrder);
            }
            // Round k is justified: a subset of its blocks justifies it if the whole round would.
            if !wk.quorum(
                linked
                    .iter()
                    .filter(|l| l.number / EPOCH == k)
                    .map(|l| &l.signer),
            ) {
                return Err(Error::NotJustified);
            }
            // Round r is committed: every one of its 180 blocks is in the chain, since a signer who voted COM in one
            // block and not in another of the round counts as not voting COM.
            let first = r.checked_mul(EPOCH).ok_or(Error::RoundIncomplete)?;
            let last = first.checked_add(EPOCH - 1).ok_or(Error::RoundIncomplete)?;
            if linked[0].number > first || linked[linked.len() - 1].number < last {
                return Err(Error::RoundIncomplete);
            }
            let round: Vec<&Linked> = linked.iter().filter(|l| l.number / EPOCH == r).collect();
            let mut against = BTreeMap::new();
            for l in &round {
                if !l.com {
                    against.insert(l.signer, ());
                }
            }
            let voters = round
                .iter()
                .filter(|l| !against.contains_key(&l.signer))
                .map(|l| &l.signer);
            if !wr.quorum(voters) {
                return Err(Error::NotCommitted);
            }
            // The vault's call is at or before round k's checkpoint: round r's commit finalizes that checkpoint or a
            // later one, the last justified before r.
            let y = &linked[call.block as usize];
            if y.number > k * EPOCH {
                return Err(Error::NotFinal);
            }
            Ok(Output::Slots {
                chain: c.chain,
                attester: c.attester,
                trusted_id: c.trusted_id,
                trusted_table: trusted.hash,
                number: y.number,
                time: y.time,
                vault: *vault,
                slots_hash: encode::keccak(&[&encode::abi_slots_values(slots, values)]),
            })
        }
    }
}
