//! The Stellar statement: a Stellar vault's `attest` succeeded in a ledger that a pinned quorum set externalized
//! (Stage B spec, section 8; `design/2026-10-03-near-stellar-interfaces.md`). Plain Rust, tested natively here, and
//! proven by SP1 (`../program`), as `proofs/finality` is for Ethereum.
//!
//! Stellar commits to no contract storage a light client can open: its bucket list hashes whole files. So a vault's
//! slots are proven as TRON's are, by a call that succeeds only when the vault holds them. The vault's `attest` emits
//! one contract event, topics `[Symbol("attest")]` and data `Bytes(record)`, and the statement proves that event in
//! the success preimage of a successful transaction of ledger `N`:
//!
//! 1. **Externalized.** Validators of the pinned quorum set `Q` signed SCP `EXTERNALIZE` statements for slot `M` and one
//!    value, each with ed25519 over `networkID ‖ ENVELOPE_TYPE_SCP ‖ XDR(SCPStatement)` (stellar-core's
//!    `HerderImpl::signEnvelope`), and the signers satisfy `Q`: at every level at least `threshold` of its validators
//!    and inner sets. Tier 1 today is 7 of 10 organisations, each 2 of 3 validators.
//! 2. **The value to ledger M-1.** The value is a `StellarValue`, whose `txSetHash` is SHA-256 of ledger `M`'s
//!    `GeneralizedTransactionSet`, whose first field is `previousLedgerHash`: SHA-256 of header `M-1`.
//! 3. **Back to ledger N.** Headers `N..M-1`, each the SHA-256 preimage its successor names.
//! 4. **The result.** Header `N`'s `txSetResultHash` is SHA-256 of its `TransactionResultSet`; one pair of it is a
//!    successful transaction, directly or inside a fee bump, of one `InvokeHostFunction` operation, whose result is
//!    `Success(hash)`, where `hash` is SHA-256 of the call's `InvokeHostFunctionSuccessPreImage`: its return value and
//!    its contract events, which the host records only for calls that did not fail, each with the id of the contract
//!    that emitted it.
//! 5. **The event.** The preimage, decoded from typed values and written again, holds exactly the event the statement
//!    writes itself from the vault's id and the record. It never takes an event's bytes on trust: a byte string
//!    shaped like an event inside another contract's return value is not an event.
//!
//! Every XDR the statement reads is decoded strictly and must write back to the very bytes it came from, so a typed
//! value and the bytes a hash fixed are one. Ledger `M`'s transaction set is never decoded: the statement reads its
//! fixed prefix, version 1 and the previous header's hash, and hashes the rest.

pub mod cycles;
pub mod quorum;
pub mod testkit;
pub mod xdr;

/// The XDR crate the statement is written against, so the program and host use the very same types.
pub use stellar_xdr;

use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use stellar_xdr::{
    ContractEvent, ContractEventBody, ContractEventType, ContractEventV0, ContractId,
    ExtensionPoint, Hash, InnerTransactionResultResult, InvokeHostFunctionResult,
    InvokeHostFunctionSuccessPreImage, LedgerHeader, NodeId, OperationResult, OperationResultTr,
    PublicKey, ScBytes, ScSymbol, ScVal, ScpEnvelope, ScpQuorumSet, ScpStatementPledges,
    StellarValue, TransactionResult, TransactionResultResult, TransactionResultSet,
};

/// `ENVELOPE_TYPE_SCP`, an XDR enum: the four bytes between the network id and the statement in a signed envelope.
pub const ENVELOPE_TYPE_SCP: [u8; 4] = [0, 0, 0, 1];
/// `GeneralizedTransactionSet`'s only arm, version 1, in which `previousLedgerHash` is the first field.
pub const GENERALIZED_V1: [u8; 4] = [0, 0, 0, 1];
/// The first protocol in which every ledger's transaction set is generalized (protocol 20, Soroban's).
pub const MIN_LEDGER_VERSION: u32 = 20;
/// The topic the vault's `attest` event carries.
pub const ATTEST_TOPIC: &str = "attest";
/// The most headers between the attested ledger and the externalized one: an hour of five-second ledgers.
pub const MAX_HEADERS: usize = 720;
/// `keccak256("xindex.v4.vault-attest")`, the record's first word.
pub const ATTEST_DOMAIN: [u8; 32] = [
    0xb0, 0xec, 0x2b, 0x25, 0xfd, 0xd7, 0x9b, 0x42, 0xb5, 0x23, 0xd5, 0xb0, 0xe6, 0x41, 0x47, 0x45,
    0x99, 0xbb, 0xba, 0x25, 0x44, 0x60, 0xdb, 0x80, 0x8d, 0xe3, 0x3f, 0x7b, 0xc0, 0xc2, 0x5d, 0x5c,
];
/// The factory's registry ids of Stellar mainnet and testnet: the first 8 bytes of `keccak256` of their CAIP-2 names.
pub const STELLAR_PUBNET: u64 = 839_718_837_228_939_926;
pub const STELLAR_TESTNET: u64 = 17_667_989_177_921_016_935;

/// What the vault's `attest` emits for these slots and values: `abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots,
/// values)`, as Solidity writes it, which `StellarStateVerifier` writes again to compare.
pub fn attest_record(
    chain_id: u64,
    vault_id: &[u8; 32],
    slots: &[[u8; 32]],
    values: &[[u8; 32]],
) -> Vec<u8> {
    let word = |x: u64| {
        let mut w = [0u8; 32];
        w[24..].copy_from_slice(&x.to_be_bytes());
        w
    };
    let mut out = Vec::new();
    out.extend_from_slice(&ATTEST_DOMAIN);
    out.extend_from_slice(&word(chain_id));
    out.extend_from_slice(vault_id);
    // The two arrays' offsets, from the start of the encoding: after the five head words, then after the first array.
    out.extend_from_slice(&word(5 * 32));
    out.extend_from_slice(&word((5 + 1 + slots.len() as u64) * 32));
    for array in [slots, values] {
        out.extend_from_slice(&word(array.len() as u64));
        for w in array {
            out.extend_from_slice(w);
        }
    }
    out
}

/// What a proof is built from. Byte strings are XDR, as stellar-core writes them and SDF's history archives keep them.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Input {
    /// SHA-256 of the network's passphrase: every signed SCP envelope begins with it.
    pub network_id: [u8; 32],
    /// The pinned quorum set, `SCPQuorumSet`; its SHA-256 is a public value the verifier contract holds.
    pub quorum_set: Vec<u8>,
    /// `SCPEnvelope`s: `EXTERNALIZE` statements for slot `M`, one per signer.
    pub envelopes: Vec<Vec<u8>>,
    /// Ledger `M`'s `GeneralizedTransactionSet`.
    pub tx_set: Vec<u8>,
    /// `LedgerHeader`s `N..=M-1`, ascending.
    pub headers: Vec<Vec<u8>>,
    /// Ledger `N`'s `TransactionResultSet`.
    pub result_set: Vec<u8>,
    /// Which pair of the result set is the vault's `attest`.
    pub result_index: u32,
    /// The call's return value, an `SCVal`.
    pub return_value: Vec<u8>,
    /// The call's contract events, each a `ContractEvent`, in the order its preimage holds them.
    pub events: Vec<Vec<u8>>,
    /// Which event is the vault's.
    pub event_index: u32,
    /// The vault's contract id.
    pub vault_id: [u8; 32],
    /// What the vault attested: `abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots, values)`.
    pub record: Vec<u8>,
}

/// What a proof shows, besides the event: the network, the quorum set, and the ledger and its close time.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Proven {
    pub network_id: [u8; 32],
    pub quorum_set_hash: [u8; 32],
    pub ledger: u32,
    pub close_time: u64,
}

/// The public values the program commits and `StellarStateVerifier` decodes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Output {
    pub proven: Proven,
    pub vault_id: [u8; 32],
    pub record_hash: [u8; 32],
}

impl Output {
    /// `abi.encode(networkId, quorumSetHash, ledger, closeTime, vaultId, recordHash)`: six words.
    pub fn abi_encode(&self) -> Vec<u8> {
        let word = |x: u64| {
            let mut w = [0u8; 32];
            w[24..].copy_from_slice(&x.to_be_bytes());
            w
        };
        [
            self.proven.network_id,
            self.proven.quorum_set_hash,
            word(self.proven.ledger.into()),
            word(self.proven.close_time),
            self.vault_id,
            self.record_hash,
        ]
        .concat()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// A byte string that is not exactly one canonical XDR value of its type.
    BadXdr(&'static str),
    /// The quorum set nests too deep, names a validator twice, or has a threshold of zero or above its members.
    BadQuorumSet,
    NoEnvelopes,
    NotExternalize,
    WrongSlot,
    ValuesDiffer,
    UnknownSigner,
    DuplicateSigner,
    BadSignature,
    NotAQuorum,
    TxSetMismatch,
    NotGeneralized,
    NoHeaders,
    TooManyHeaders,
    OldLedgerVersion,
    HeaderChainBroken,
    ResultSetMismatch,
    NoSuchResult,
    NotASuccess,
    PreimageMismatch,
    NoSuchEvent,
    NotTheEvent,
}

pub fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

pub fn keccak256(data: &[u8]) -> [u8; 32] {
    use tiny_keccak::{Hasher, Keccak};
    let mut k = Keccak::v256();
    k.update(data);
    let mut out = [0u8; 32];
    k.finalize(&mut out);
    out
}

/// The event the vault's `attest` emits for `record`, written from typed fields.
pub fn attest_event(vault_id: &[u8; 32], record: &[u8]) -> Result<ContractEvent, Error> {
    let topic = ScSymbol(
        ATTEST_TOPIC
            .try_into()
            .map_err(|_| Error::BadXdr("topic"))?,
    );
    Ok(ContractEvent {
        ext: ExtensionPoint::V0,
        contract_id: Some(ContractId(Hash(*vault_id))),
        type_: ContractEventType::Contract,
        body: ContractEventBody::V0(ContractEventV0 {
            topics: vec![ScVal::Symbol(topic)]
                .try_into()
                .map_err(|_| Error::BadXdr("topics"))?,
            data: ScVal::Bytes(ScBytes(
                record
                    .to_vec()
                    .try_into()
                    .map_err(|_| Error::BadXdr("record"))?,
            )),
        }),
    })
}

/// The statement: the vault's `attest` of `record` succeeded in ledger `N`, which `Q` externalized.
pub fn verify(input: &Input) -> Result<Output, Error> {
    let expected = attest_event(&input.vault_id, &input.record)?;
    let proven = verify_event(input, &expected)?;
    Ok(Output {
        proven,
        vault_id: input.vault_id,
        record_hash: keccak256(&input.record),
    })
}

/// Steps 1 to 5 for any expected event: the vault's `attest` event in production, a real contract's event in tests.
pub fn verify_event(input: &Input, expected: &ContractEvent) -> Result<Proven, Error> {
    // 1. The quorum set.
    cycles::start("quorum set");
    let q: ScpQuorumSet = xdr::decode(&input.quorum_set, "quorum set")?;
    quorum::check_sane(&q)?;
    let quorum_set_hash = sha256(&[&input.quorum_set]);
    cycles::end("quorum set");

    // 3. The headers, which fix M: the slot whose value opens to the next ledger's transaction set.
    cycles::start("headers");
    if input.headers.is_empty() {
        return Err(Error::NoHeaders);
    }
    if input.headers.len() > MAX_HEADERS {
        return Err(Error::TooManyHeaders);
    }
    let mut headers: Vec<LedgerHeader> = Vec::with_capacity(input.headers.len());
    let mut last_hash = [0u8; 32];
    for (i, raw) in input.headers.iter().enumerate() {
        let h: LedgerHeader = xdr::decode(raw, "header")?;
        if h.ledger_version < MIN_LEDGER_VERSION {
            return Err(Error::OldLedgerVersion);
        }
        if i > 0 {
            let prev = &headers[i - 1];
            if h.previous_ledger_hash.0 != last_hash
                || h.ledger_seq != prev.ledger_seq.wrapping_add(1)
            {
                return Err(Error::HeaderChainBroken);
            }
        }
        last_hash = sha256(&[raw]);
        headers.push(h);
    }
    let slot = u64::from(headers[headers.len() - 1].ledger_seq) + 1;
    cycles::end("headers");

    // 1. The envelopes, all for slot M and one value, from distinct signers of Q that satisfy it.
    cycles::start("envelopes");
    if input.envelopes.is_empty() {
        return Err(Error::NoEnvelopes);
    }
    let members = quorum::validators(&q);
    let mut signers = BTreeSet::new();
    let mut value: Option<Vec<u8>> = None;
    for raw in &input.envelopes {
        let e: ScpEnvelope = xdr::decode(raw, "envelope")?;
        let ScpStatementPledges::Externalize(x) = &e.statement.pledges else {
            return Err(Error::NotExternalize);
        };
        if e.statement.slot_index != slot {
            return Err(Error::WrongSlot);
        }
        let v = x.commit.value.as_slice();
        match &value {
            None => value = Some(v.to_vec()),
            Some(first) if first.as_slice() != v => return Err(Error::ValuesDiffer),
            Some(_) => {}
        }
        let NodeId(PublicKey::PublicKeyTypeEd25519(key)) = &e.statement.node_id;
        if !members.contains(&key.0) {
            return Err(Error::UnknownSigner);
        }
        if !signers.insert(key.0) {
            return Err(Error::DuplicateSigner);
        }
        let statement = xdr::encode(&e.statement)?;
        let signature: [u8; 64] = e
            .signature
            .as_slice()
            .try_into()
            .map_err(|_| Error::BadSignature)?;
        let key = VerifyingKey::from_bytes(&key.0).map_err(|_| Error::BadSignature)?;
        key.verify_strict(
            &[&input.network_id[..], &ENVELOPE_TYPE_SCP, &statement].concat(),
            &Signature::from_bytes(&signature),
        )
        .map_err(|_| Error::BadSignature)?;
    }
    if !quorum::satisfied(&q, &signers) {
        return Err(Error::NotAQuorum);
    }
    cycles::end("envelopes");

    // 2. The value opens to ledger M's transaction set, whose first field is header M-1's hash.
    cycles::start("transaction set");
    let value: StellarValue = xdr::decode(&value.unwrap_or_default(), "value")?;
    if sha256(&[&input.tx_set]) != value.tx_set_hash.0 {
        return Err(Error::TxSetMismatch);
    }
    if input.tx_set.len() < 36 || input.tx_set[..4] != GENERALIZED_V1 {
        return Err(Error::NotGeneralized);
    }
    if input.tx_set[4..36] != last_hash {
        return Err(Error::HeaderChainBroken);
    }
    cycles::end("transaction set");

    // 4. Ledger N's result set, and the transaction's success hash.
    cycles::start("result set");
    let n = &headers[0];
    if sha256(&[&input.result_set]) != n.tx_set_result_hash.0 {
        return Err(Error::ResultSetMismatch);
    }
    let results: TransactionResultSet = xdr::decode(&input.result_set, "result set")?;
    let pair = results
        .results
        .get(input.result_index as usize)
        .ok_or(Error::NoSuchResult)?;
    let success = success_hash(&pair.result).ok_or(Error::NotASuccess)?;
    cycles::end("result set");

    // 5. The success preimage, written from its typed parts, and the expected event in it.
    cycles::start("preimage");
    let return_value: ScVal = xdr::decode(&input.return_value, "return value")?;
    let mut events = Vec::with_capacity(input.events.len());
    for raw in &input.events {
        events.push(xdr::decode::<ContractEvent>(raw, "event")?);
    }
    let event = events
        .get(input.event_index as usize)
        .ok_or(Error::NoSuchEvent)?;
    if event != expected {
        return Err(Error::NotTheEvent);
    }
    let preimage = InvokeHostFunctionSuccessPreImage {
        return_value,
        events: events.try_into().map_err(|_| Error::BadXdr("events"))?,
    };
    if sha256(&[&xdr::encode(&preimage)?]) != success {
        return Err(Error::PreimageMismatch);
    }
    cycles::end("preimage");

    Ok(Proven {
        network_id: input.network_id,
        quorum_set_hash,
        ledger: n.ledger_seq,
        close_time: n.scp_value.close_time.0,
    })
}

/// The success hash of a transaction of one `InvokeHostFunction` operation that succeeded, directly or inside a fee
/// bump; `None` for any other result.
pub fn success_hash(r: &TransactionResult) -> Option<[u8; 32]> {
    let ops = match &r.result {
        TransactionResultResult::TxSuccess(ops) => ops,
        TransactionResultResult::TxFeeBumpInnerSuccess(inner) => match &inner.result.result {
            InnerTransactionResultResult::TxSuccess(ops) => ops,
            _ => return None,
        },
        _ => return None,
    };
    match ops.as_slice() {
        [OperationResult::OpInner(OperationResultTr::InvokeHostFunction(
            InvokeHostFunctionResult::Success(h),
        ))] => Some(h.0),
        _ => None,
    }
}
