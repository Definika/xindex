//! The vault's events. Only `Attest` is part of an interface (`design/2026-10-03-near-stellar-interfaces.md`): one
//! contract event, topics `[Symbol("attest")]`, data the `Bytes` of its record, which Stellar's state verifier on
//! Ethereum proves from the call's result. The rest are for indexers and monitors.

use soroban_sdk::{contractevent, Address, Bytes, BytesN};

/// `attest`'s record: `abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots, values)`.
#[contractevent(data_format = "single-value")]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Attest {
    pub record: Bytes,
}

#[contractevent]
pub struct IndexRegistered {
    #[topic]
    pub index: BytesN<20>,
    pub salt: BytesN<32>,
}

#[contractevent]
pub struct Deposited {
    #[topic]
    pub index: BytesN<20>,
    #[topic]
    pub intake_id: BytesN<32>,
    pub depositor: Address,
    pub amount: u64,
}

#[contractevent]
pub struct Refunded {
    #[topic]
    pub index: BytesN<20>,
    #[topic]
    pub intake_id: BytesN<32>,
    pub depositor: Address,
    pub amount: u64,
}

#[contractevent]
pub struct MessageDelivered {
    #[topic]
    pub id: BytesN<32>,
    pub kind: u32,
    pub index: BytesN<20>,
}

#[contractevent]
pub struct BurnAccepted {
    #[topic]
    pub index: BytesN<20>,
    pub id: BytesN<32>,
    pub amount: u64,
    pub recipient: BytesN<32>,
}

#[contractevent]
pub struct MigrationAccepted {
    #[topic]
    pub index: BytesN<20>,
    pub id: BytesN<32>,
    pub amount: u64,
    pub new_index: BytesN<20>,
}

#[contractevent]
pub struct Paid {
    #[topic]
    pub index: BytesN<20>,
    pub id: BytesN<32>,
    pub amount: u64,
    pub remaining: u64,
}

#[contractevent]
pub struct IntakeSettled {
    #[topic]
    pub index: BytesN<20>,
    pub intake_id: BytesN<32>,
}

#[contractevent]
pub struct IntakeFailed {
    #[topic]
    pub index: BytesN<20>,
    pub intake_id: BytesN<32>,
}

#[contractevent]
pub struct IntakeResolved {
    #[topic]
    pub index: BytesN<20>,
    pub intake_id: BytesN<32>,
    pub settled: bool,
}

#[contractevent]
pub struct CapSet {
    pub cap: u64,
    pub outflow_floor: u64,
}

#[contractevent]
pub struct Frozen {
    pub until: u64,
}

#[contractevent]
pub struct ChangeQueued {
    #[topic]
    pub kind: u32,
    pub body: Bytes,
    pub ready_at: u64,
}

#[contractevent]
pub struct ChangeApplied {
    #[topic]
    pub kind: u32,
}

#[contractevent]
pub struct ChangeCancelled {
    #[topic]
    pub kind: u32,
}

#[contractevent]
pub struct FreezerChanged {
    pub freezer: Address,
}

#[contractevent]
pub struct VerifiersRotated {
    pub p1: Address,
    pub p2: Address,
}

#[contractevent]
pub struct CheckpointAdvanced {
    pub block: u64,
    pub timestamp: u64,
    pub state_root: BytesN<32>,
}

#[contractevent]
pub struct SuccessorProposed {
    pub p1: Address,
    pub p2: Address,
    pub review_ends: u64,
}

#[contractevent]
pub struct SuccessorVetoed {
    pub vetoes: u32,
}

#[contractevent]
pub struct SuccessorLapsed {}

#[contractevent]
pub struct SuccessorAdopted {
    pub p1: Address,
    pub p2: Address,
}

#[contractevent]
pub struct SnapshotBegun {
    pub block: u64,
    pub timestamp: u64,
    pub state_root: BytesN<32>,
}

#[contractevent]
pub struct SnapshotClaimed {
    #[topic]
    pub index: BytesN<20>,
    #[topic]
    pub holder: BytesN<20>,
    pub recipient: BytesN<32>,
    pub amount: u64,
    pub id: BytesN<32>,
}
