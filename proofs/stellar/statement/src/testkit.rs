//! A synthetic Stellar for tests and execute-mode runs: a Tier 1 of ten organisations of three validators each, 7 of 10
//! and 2 of 3, with real ed25519 keys; a header, a result set and a success preimage holding the vault's `attest`
//! event; the next ledger's transaction set; and the organisations' signed `EXTERNALIZE` envelopes for its value. Every
//! byte is XDR as stellar-core writes it, so the statement runs on it unchanged.

use crate::{attest_event, sha256, xdr, Input, ENVELOPE_TYPE_SCP};
use ed25519_dalek::{Signer, SigningKey};
use stellar_xdr::{
    ContractEvent, ContractEventBody, ContractEventType, ContractEventV0, ContractId,
    ExtensionPoint, GeneralizedTransactionSet, Hash, InvokeHostFunctionResult,
    InvokeHostFunctionSuccessPreImage, LedgerHeader, LedgerHeaderExt, NodeId, OperationResult,
    OperationResultTr, PublicKey, ScBytes, ScSymbol, ScVal, ScpBallot, ScpEnvelope, ScpQuorumSet,
    ScpStatement, ScpStatementExternalize, ScpStatementPledges, Signature, StellarValue,
    StellarValueExt, TimePoint, TransactionResult, TransactionResultExt, TransactionResultPair,
    TransactionResultResult, TransactionResultSet, TransactionSetV1, Uint256, Value,
};

pub const NETWORK_ID: [u8; 32] = [0x7a; 32];
pub const ORGS: usize = 10;
pub const PER_ORG: usize = 3;
pub const LEDGER: u32 = 64_754_034;
pub const CLOSE_TIME: u64 = 1_791_056_000;
pub const VAULT: [u8; 32] = [0xc5; 32];

/// The validator keys, organisation by organisation.
pub fn keys() -> Vec<Vec<SigningKey>> {
    (0..ORGS)
        .map(|o| {
            (0..PER_ORG)
                .map(|v| SigningKey::from_bytes(&sha256(&[b"validator", &[o as u8, v as u8]])))
                .collect()
        })
        .collect()
}

fn node(k: &SigningKey) -> NodeId {
    NodeId(PublicKey::PublicKeyTypeEd25519(Uint256(
        k.verifying_key().to_bytes(),
    )))
}

/// Tier 1's shape: 7 of the 10 organisations, each 2 of its 3 validators.
pub fn quorum_set(keys: &[Vec<SigningKey>]) -> ScpQuorumSet {
    ScpQuorumSet {
        threshold: 7,
        validators: Default::default(),
        inner_sets: keys
            .iter()
            .map(|org| ScpQuorumSet {
                threshold: 2,
                validators: org.iter().map(node).collect::<Vec<_>>().try_into().unwrap(),
                inner_sets: Default::default(),
            })
            .collect::<Vec<_>>()
            .try_into()
            .unwrap(),
    }
}

/// An event another contract emitted in the same call.
pub fn other_event() -> ContractEvent {
    ContractEvent {
        ext: ExtensionPoint::V0,
        contract_id: Some(ContractId(Hash([0x11; 32]))),
        type_: ContractEventType::Contract,
        body: ContractEventBody::V0(ContractEventV0 {
            topics: vec![ScVal::Symbol(ScSymbol("transfer".try_into().unwrap()))]
                .try_into()
                .unwrap(),
            data: ScVal::I128(Default::default()),
        }),
    }
}

/// The slots an evidence proof asks for since LG-5: an intake's digest and the snapshot's root, `bytes32(25)`.
pub fn slots() -> Vec<[u8; 32]> {
    let mut snapshot = [0u8; 32];
    snapshot[31] = 25;
    vec![sha256(&[b"an intake's digest slot"]), snapshot]
}

/// Their values: a digest, and no snapshot.
pub fn values() -> Vec<[u8; 32]> {
    vec![sha256(&[b"the intake's digest"]), [0u8; 32]]
}

/// The record the vault writes for `slots()` and `values()` on Stellar mainnet.
pub fn record() -> Vec<u8> {
    crate::attest_record(crate::STELLAR_PUBNET, &VAULT, &slots(), &values())
}

fn result_pair(success: [u8; 32]) -> TransactionResultPair {
    TransactionResultPair {
        transaction_hash: Hash([0x33; 32]),
        result: TransactionResult {
            fee_charged: 100,
            result: TransactionResultResult::TxSuccess(
                vec![OperationResult::OpInner(
                    OperationResultTr::InvokeHostFunction(InvokeHostFunctionResult::Success(Hash(
                        success,
                    ))),
                )]
                .try_into()
                .unwrap(),
            ),
            ext: TransactionResultExt::V0,
        },
    }
}

fn header(seq: u32, previous: [u8; 32], result_set: [u8; 32], close_time: u64) -> LedgerHeader {
    LedgerHeader {
        ledger_version: 29,
        previous_ledger_hash: Hash(previous),
        scp_value: StellarValue {
            tx_set_hash: Hash([0x44; 32]),
            close_time: TimePoint(close_time),
            upgrades: Default::default(),
            ext: StellarValueExt::Basic,
        },
        tx_set_result_hash: Hash(result_set),
        bucket_list_hash: Hash([0x55; 32]),
        ledger_seq: seq,
        total_coins: 1,
        fee_pool: 1,
        inflation_seq: 1,
        id_pool: 1,
        base_fee: 100,
        base_reserve: 5_000_000,
        max_tx_set_size: 1_000,
        skip_list: [Hash([0; 32]), Hash([0; 32]), Hash([0; 32]), Hash([0; 32])],
        ext: LedgerHeaderExt::V0,
    }
}

/// An `EXTERNALIZE` envelope of slot `slot` for `value`, signed by `key` on `network`.
pub fn envelope(
    key: &SigningKey,
    network: &[u8; 32],
    slot: u64,
    value: &[u8],
    qhash: [u8; 32],
) -> ScpEnvelope {
    let statement = ScpStatement {
        node_id: node(key),
        slot_index: slot,
        pledges: ScpStatementPledges::Externalize(ScpStatementExternalize {
            commit: ScpBallot {
                counter: 1,
                value: Value(value.to_vec().try_into().unwrap()),
            },
            n_h: 1,
            commit_quorum_set_hash: Hash(qhash),
        }),
    };
    let message = [
        &network[..],
        &ENVELOPE_TYPE_SCP,
        &xdr::encode(&statement).unwrap(),
    ]
    .concat();
    ScpEnvelope {
        statement,
        signature: Signature(key.sign(&message).to_bytes().to_vec().try_into().unwrap()),
    }
}

/// The signers: the first two validators of the first `orgs` organisations.
pub fn signers(keys: &[Vec<SigningKey>], orgs: usize) -> Vec<&SigningKey> {
    keys.iter()
        .take(orgs)
        .flat_map(|org| org.iter().take(2))
        .collect()
}

/// A whole proof: the attest in ledger `LEDGER` after `gap` - 1 more headers, externalized by `orgs` organisations.
pub fn build(orgs: usize, gap: u32) -> Input {
    let keys = keys();
    let q = quorum_set(&keys);
    let q_bytes = xdr::encode(&q).unwrap();
    let record = record();
    let events = vec![other_event(), attest_event(&VAULT, &record).unwrap()];
    let preimage = InvokeHostFunctionSuccessPreImage {
        return_value: ScVal::Void,
        events: events.clone().try_into().unwrap(),
    };
    let success = sha256(&[&xdr::encode(&preimage).unwrap()]);
    let result_set = TransactionResultSet {
        results: vec![result_pair([0x99; 32]), result_pair(success)]
            .try_into()
            .unwrap(),
    };
    let result_bytes = xdr::encode(&result_set).unwrap();
    let mut headers = vec![header(
        LEDGER,
        [0x66; 32],
        sha256(&[&result_bytes]),
        CLOSE_TIME,
    )];
    for i in 1..gap {
        let prev = sha256(&[&xdr::encode(&headers[(i - 1) as usize]).unwrap()]);
        headers.push(header(
            LEDGER + i,
            prev,
            [0x77; 32],
            CLOSE_TIME + 5 * u64::from(i),
        ));
    }
    let header_bytes: Vec<Vec<u8>> = headers.iter().map(|h| xdr::encode(h).unwrap()).collect();
    let tx_set = xdr::encode(&GeneralizedTransactionSet::V1(TransactionSetV1 {
        previous_ledger_hash: Hash(sha256(&[header_bytes.last().unwrap()])),
        phases: Default::default(),
    }))
    .unwrap();
    let value = xdr::encode(&StellarValue {
        tx_set_hash: Hash(sha256(&[&tx_set])),
        close_time: TimePoint(CLOSE_TIME + 5 * u64::from(gap)),
        upgrades: Default::default(),
        ext: StellarValueExt::Basic,
    })
    .unwrap();
    let slot = u64::from(LEDGER + gap);
    let qhash = sha256(&[&q_bytes]);
    let envelopes = signers(&keys, orgs)
        .into_iter()
        .map(|k| xdr::encode(&envelope(k, &NETWORK_ID, slot, &value, qhash)).unwrap())
        .collect();
    Input {
        network_id: NETWORK_ID,
        quorum_set: q_bytes,
        envelopes,
        tx_set,
        headers: header_bytes,
        result_set: result_bytes,
        result_index: 1,
        return_value: xdr::encode(&ScVal::Void).unwrap(),
        events: events.iter().map(|e| xdr::encode(e).unwrap()).collect(),
        event_index: 1,
        vault_id: VAULT,
        record,
    }
}

/// The synthetic attest of `build(7, 1)` as JSON, for the Solidity verifier's tests (`fixtures/attest.json`).
pub fn vector() -> String {
    let input = build(7, 1);
    let out = crate::verify(&input).expect("the synthetic attest holds");
    let hex = |b: &[u8]| -> String { b.iter().map(|x| format!("{x:02x}")).collect() };
    let list = |ws: &[[u8; 32]]| -> String {
        ws.iter()
            .map(|w| format!("\"0x{}\"", hex(w)))
            .collect::<Vec<_>>()
            .join(", ")
    };
    format!(
        "{{\n  \"chainId\": {},\n  \"vaultId\": \"0x{}\",\n  \"networkId\": \"0x{}\",\n  \"quorumSetHash\": \"0x{}\",\n  \
         \"ledger\": {},\n  \"closeTime\": {},\n  \"slots\": [{}],\n  \"values\": [{}],\n  \"record\": \"0x{}\",\n  \
         \"publicValues\": \"0x{}\"\n}}\n",
        crate::STELLAR_PUBNET,
        hex(&VAULT),
        hex(&out.proven.network_id),
        hex(&out.proven.quorum_set_hash),
        out.proven.ledger,
        out.proven.close_time,
        list(&slots()),
        list(&values()),
        hex(&input.record),
        hex(&out.abi_encode()),
    )
}

/// The data of a record, as `ScVal::Bytes`, for tests that rewrite an event's data.
pub fn bytes_val(b: &[u8]) -> ScVal {
    ScVal::Bytes(ScBytes(b.to_vec().try_into().unwrap()))
}
