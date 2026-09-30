use anchor_lang::prelude::*;

/// The EVM vault's events (`IXindexVault`), for watchers and the relayer.
#[event]
pub struct IndexRegistered {
    pub index: [u8; 20],
    pub salt: [u8; 32],
}

#[event]
pub struct Deposited {
    pub index: [u8; 20],
    pub intake_id: [u8; 32],
    pub depositor: Pubkey,
    pub amount: u64,
}

#[event]
pub struct MessageDelivered {
    pub id: [u8; 32],
    pub kind: u8,
    pub index: [u8; 20],
}

#[event]
pub struct BurnAccepted {
    pub index: [u8; 20],
    pub id: [u8; 32],
    pub amount: u64,
    pub recipient: Pubkey,
}

#[event]
pub struct MigrationAccepted {
    pub index: [u8; 20],
    pub id: [u8; 32],
    pub amount: u64,
    pub new_index: [u8; 20],
}

#[event]
pub struct Paid {
    pub index: [u8; 20],
    pub id: [u8; 32],
    pub amount: u64,
    pub remaining: u64,
}

#[event]
pub struct IntakeSettled {
    pub index: [u8; 20],
    pub intake_id: [u8; 32],
}

#[event]
pub struct IntakeFailed {
    pub index: [u8; 20],
    pub intake_id: [u8; 32],
}

#[event]
pub struct Refunded {
    pub index: [u8; 20],
    pub intake_id: [u8; 32],
    pub depositor: Pubkey,
    pub amount: u64,
}

#[event]
pub struct CapSet {
    pub cap: u64,
    pub outflow_floor: u64,
}

#[event]
pub struct Frozen {
    pub until: i64,
    pub by: Pubkey,
}

#[event]
pub struct FreezerChanged {
    pub freezer: Pubkey,
}

#[event]
pub struct VerifiersRotated {
    pub p1: Pubkey,
    pub p2: Pubkey,
}

#[event]
pub struct ChangeQueued {
    pub kind: u8,
    pub body: Vec<u8>,
    pub ready_at: i64,
}

#[event]
pub struct ChangeApplied {
    pub kind: u8,
}

#[event]
pub struct ChangeCancelled {
    pub kind: u8,
}
