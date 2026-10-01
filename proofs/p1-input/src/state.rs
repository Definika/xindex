//! A Fulu `BeaconState` read in place from its SSZ, and hashed field by field: the registry, the pending deposits, the
//! latest execution payload header, and the branches P1 needs. Its root is recomputed in full, so a mistake in any
//! field's layout shows as a root that does not match the block that committed to it.

use xindex_finality::beacon::BeaconBlockHeader;
use xindex_finality::registry::{validators_root, Validator};
use xindex_finality::ssz::{hash_pair, merkleize, mix_in_length, u64_chunk};
use xindex_finality::Root;

#[derive(Clone, Copy)]
enum Kind {
    Fixed(usize),
    Variable,
}
use Kind::{Fixed, Variable};

/// Fulu's 38 fields, in order: a fixed field's size, or a variable one's 4-byte offset.
const FIELDS: [Kind; 38] = [
    Fixed(8),         // 0 genesis_time
    Fixed(32),        // 1 genesis_validators_root
    Fixed(8),         // 2 slot
    Fixed(16),        // 3 fork
    Fixed(112),       // 4 latest_block_header
    Fixed(262_144),   // 5 block_roots
    Fixed(262_144),   // 6 state_roots
    Variable,         // 7 historical_roots
    Fixed(72),        // 8 eth1_data
    Variable,         // 9 eth1_data_votes
    Fixed(8),         // 10 eth1_deposit_index
    Variable,         // 11 validators
    Variable,         // 12 balances
    Fixed(2_097_152), // 13 randao_mixes
    Fixed(65_536),    // 14 slashings
    Variable,         // 15 previous_epoch_participation
    Variable,         // 16 current_epoch_participation
    Fixed(1),         // 17 justification_bits
    Fixed(40),        // 18 previous_justified_checkpoint
    Fixed(40),        // 19 current_justified_checkpoint
    Fixed(40),        // 20 finalized_checkpoint
    Variable,         // 21 inactivity_scores
    Fixed(24_624),    // 22 current_sync_committee
    Fixed(24_624),    // 23 next_sync_committee
    Variable,         // 24 latest_execution_payload_header
    Fixed(8),         // 25 next_withdrawal_index
    Fixed(8),         // 26 next_withdrawal_validator_index
    Variable,         // 27 historical_summaries
    Fixed(8),         // 28 deposit_requests_start_index
    Fixed(8),         // 29 deposit_balance_to_consume
    Fixed(8),         // 30 exit_balance_to_consume
    Fixed(8),         // 31 earliest_exit_epoch
    Fixed(8),         // 32 consolidation_balance_to_consume
    Fixed(8),         // 33 earliest_consolidation_epoch
    Variable,         // 34 pending_deposits
    Variable,         // 35 pending_partial_withdrawals
    Variable,         // 36 pending_consolidations
    Fixed(512),       // 37 proposer_lookahead
];

pub const VALIDATOR_BYTES: usize = 121;
const PENDING_DEPOSIT_BYTES: usize = 192;
const PAYLOAD_HEADER_FIXED: usize = 584;

pub struct State {
    bytes: Vec<u8>,
    spans: Vec<(usize, usize)>,
}

/// A deposit waiting in the state's queue: what a key added from it signed.
pub struct PendingDeposit {
    pub pubkey: [u8; 48],
    pub withdrawal_credentials: Root,
    pub amount: u64,
    pub signature: [u8; 96],
}

/// The latest execution payload header's block hash and number, and its 17 field roots.
pub struct PayloadHeader {
    pub block_hash: Root,
    pub block_number: u64,
    pub field_roots: Vec<Root>,
}

fn le64(b: &[u8]) -> u64 {
    u64::from_le_bytes(b[..8].try_into().unwrap())
}

fn root32(b: &[u8]) -> Root {
    b[..32].try_into().unwrap()
}

/// A byte string of up to 32 bytes as its chunk, zero-padded on the right.
fn chunk(b: &[u8]) -> Root {
    let mut c = [0u8; 32];
    c[..b.len()].copy_from_slice(b);
    c
}

/// A byte string as its chunks, the last zero-padded.
fn chunks(b: &[u8]) -> Vec<Root> {
    b.chunks(32).map(chunk).collect()
}

fn pubkey_root(b: &[u8]) -> Root {
    hash_pair(&chunk(&b[..32]), &chunk(&b[32..48]))
}

fn roots(b: &[u8]) -> Vec<Root> {
    b.chunks(32).map(root32).collect()
}

/// `List[uint64, limit]` or `List[uint8, limit]`: packed chunks under `depth`, mixed with the element count.
fn packed_list(b: &[u8], depth: usize, element_bytes: usize) -> Root {
    mix_in_length(
        &merkleize(&chunks(b), depth),
        (b.len() / element_bytes) as u64,
    )
}

/// A list of fixed-size containers of `size` bytes, each hashed by `each`, under `depth`, mixed with the count.
fn container_list(b: &[u8], size: usize, depth: usize, each: impl Fn(&[u8]) -> Root) -> Root {
    let leaves: Vec<Root> = b.chunks(size).map(each).collect();
    mix_in_length(&merkleize(&leaves, depth), leaves.len() as u64)
}

fn checkpoint_root(b: &[u8]) -> Root {
    hash_pair(&u64_chunk(le64(b)), &root32(&b[8..]))
}

fn eth1_data_root(b: &[u8]) -> Root {
    merkleize(&[root32(b), u64_chunk(le64(&b[32..])), root32(&b[40..])], 2)
}

fn sync_committee_root(b: &[u8]) -> Root {
    let keys: Vec<Root> = b[..512 * 48].chunks(48).map(pubkey_root).collect();
    hash_pair(&merkleize(&keys, 9), &pubkey_root(&b[512 * 48..]))
}

fn pending_deposit_root(b: &[u8]) -> Root {
    merkleize(
        &[
            pubkey_root(&b[..48]),
            root32(&b[48..]),
            u64_chunk(le64(&b[80..])),
            merkleize(&chunks(&b[88..184]), 2),
            u64_chunk(le64(&b[184..])),
        ],
        3,
    )
}

pub fn header(b: &[u8]) -> BeaconBlockHeader {
    BeaconBlockHeader {
        slot: le64(b),
        proposer_index: le64(&b[8..]),
        parent_root: root32(&b[16..]),
        state_root: root32(&b[48..]),
        body_root: root32(&b[80..]),
    }
}

/// `ExecutionPayloadHeader` (Deneb on): 17 fields, `extra_data` the one variable, at offset 584.
pub fn payload_header(b: &[u8]) -> Result<PayloadHeader, String> {
    if b.len() < PAYLOAD_HEADER_FIXED
        || u32::from_le_bytes(b[436..440].try_into().unwrap()) as usize != PAYLOAD_HEADER_FIXED
    {
        return Err("a malformed execution payload header".into());
    }
    let extra = &b[PAYLOAD_HEADER_FIXED..];
    if extra.len() > 32 {
        return Err("extra data longer than 32 bytes".into());
    }
    let field_roots = vec![
        root32(b),                                                        // parent_hash
        chunk(&b[32..52]),                                                // fee_recipient
        root32(&b[52..]),                                                 // state_root
        root32(&b[84..]),                                                 // receipts_root
        merkleize(&chunks(&b[116..372]), 3),                              // logs_bloom
        root32(&b[372..]),                                                // prev_randao
        u64_chunk(le64(&b[404..])),                                       // block_number
        u64_chunk(le64(&b[412..])),                                       // gas_limit
        u64_chunk(le64(&b[420..])),                                       // gas_used
        u64_chunk(le64(&b[428..])),                                       // timestamp
        mix_in_length(&merkleize(&chunks(extra), 0), extra.len() as u64), // extra_data
        root32(&b[440..]),          // base_fee_per_gas, a little-endian uint256
        root32(&b[472..]),          // block_hash
        root32(&b[504..]),          // transactions_root
        root32(&b[536..]),          // withdrawals_root
        u64_chunk(le64(&b[568..])), // blob_gas_used
        u64_chunk(le64(&b[576..])), // excess_blob_gas
    ];
    Ok(PayloadHeader {
        block_hash: root32(&b[472..]),
        block_number: le64(&b[404..]),
        field_roots,
    })
}

impl State {
    pub fn parse(bytes: Vec<u8>) -> Result<State, String> {
        let mut spans = vec![(0usize, 0usize); FIELDS.len()];
        let mut variable: Vec<(usize, usize)> = Vec::new();
        let mut at = 0usize;
        for (i, kind) in FIELDS.iter().enumerate() {
            match kind {
                Fixed(n) => {
                    spans[i] = (at, at + n);
                    at += n;
                }
                Variable => {
                    let offset = u32::from_le_bytes(
                        bytes
                            .get(at..at + 4)
                            .ok_or("truncated")?
                            .try_into()
                            .unwrap(),
                    );
                    variable.push((i, offset as usize));
                    at += 4;
                }
            }
        }
        if variable.first().map(|v| v.1) != Some(at) {
            return Err("the first offset must follow the fixed part".into());
        }
        for (k, &(i, start)) in variable.iter().enumerate() {
            let end = variable.get(k + 1).map(|v| v.1).unwrap_or(bytes.len());
            if start > end || end > bytes.len() {
                return Err(format!("field {i}: offsets out of order"));
            }
            spans[i] = (start, end);
        }
        Ok(State { bytes, spans })
    }

    fn field(&self, i: usize) -> &[u8] {
        &self.bytes[self.spans[i].0..self.spans[i].1]
    }

    pub fn slot(&self) -> u64 {
        le64(self.field(2))
    }

    pub fn latest_block_header(&self) -> BeaconBlockHeader {
        header(self.field(4))
    }

    pub fn validators(&self) -> Vec<Validator> {
        self.field(11)
            .chunks(VALIDATOR_BYTES)
            .map(|v| Validator {
                pubkey: v[..48].try_into().unwrap(),
                withdrawal_credentials: root32(&v[48..]),
                effective_balance: le64(&v[80..]),
                slashed: v[88] == 1,
                activation_eligibility_epoch: le64(&v[89..]),
                activation_epoch: le64(&v[97..]),
                exit_epoch: le64(&v[105..]),
                withdrawable_epoch: le64(&v[113..]),
            })
            .collect()
    }

    pub fn pending_deposits(&self) -> Vec<PendingDeposit> {
        self.field(34)
            .chunks(PENDING_DEPOSIT_BYTES)
            .map(|d| PendingDeposit {
                pubkey: d[..48].try_into().unwrap(),
                withdrawal_credentials: root32(&d[48..]),
                amount: le64(&d[80..]),
                signature: d[88..184].try_into().unwrap(),
            })
            .collect()
    }

    pub fn payload_header(&self) -> Result<PayloadHeader, String> {
        payload_header(self.field(24))
    }

    /// Every field's root, in order.
    pub fn field_roots(&self) -> Result<Vec<Root>, String> {
        let f = |i: usize| self.field(i);
        let fork = f(3);
        Ok(vec![
            u64_chunk(le64(f(0))),
            root32(f(1)),
            u64_chunk(le64(f(2))),
            merkleize(
                &[
                    chunk(&fork[..4]),
                    chunk(&fork[4..8]),
                    u64_chunk(le64(&fork[8..])),
                ],
                2,
            ),
            self.latest_block_header().hash_tree_root(),
            merkleize(&roots(f(5)), 13),
            merkleize(&roots(f(6)), 13),
            mix_in_length(&merkleize(&roots(f(7)), 24), (f(7).len() / 32) as u64),
            eth1_data_root(f(8)),
            container_list(f(9), 72, 11, eth1_data_root),
            u64_chunk(le64(f(10))),
            validators_root(&self.validators()),
            packed_list(f(12), 38, 8),
            merkleize(&roots(f(13)), 16),
            merkleize(&chunks(f(14)), 11),
            packed_list(f(15), 35, 1),
            packed_list(f(16), 35, 1),
            chunk(f(17)),
            checkpoint_root(f(18)),
            checkpoint_root(f(19)),
            checkpoint_root(f(20)),
            packed_list(f(21), 38, 8),
            sync_committee_root(f(22)),
            sync_committee_root(f(23)),
            merkleize(&self.payload_header()?.field_roots, 5),
            u64_chunk(le64(f(25))),
            u64_chunk(le64(f(26))),
            container_list(f(27), 64, 24, |s| hash_pair(&root32(s), &root32(&s[32..]))),
            u64_chunk(le64(f(28))),
            u64_chunk(le64(f(29))),
            u64_chunk(le64(f(30))),
            u64_chunk(le64(f(31))),
            u64_chunk(le64(f(32))),
            u64_chunk(le64(f(33))),
            container_list(f(34), PENDING_DEPOSIT_BYTES, 27, pending_deposit_root),
            container_list(f(35), 24, 27, |w| {
                merkleize(
                    &[
                        u64_chunk(le64(w)),
                        u64_chunk(le64(&w[8..])),
                        u64_chunk(le64(&w[16..])),
                    ],
                    2,
                )
            }),
            container_list(f(36), 16, 18, |c| {
                hash_pair(&u64_chunk(le64(c)), &u64_chunk(le64(&c[8..])))
            }),
            merkleize(&chunks(f(37)), 4),
        ])
    }
}

/// The root of `leaves` (padded to `2^depth` with zero chunks) and the branch of leaf `index`, bottom up.
pub fn branch(leaves: &[Root], depth: usize, index: usize) -> (Root, Vec<Root>) {
    let mut layer = leaves.to_vec();
    layer.resize(1 << depth, [0u8; 32]);
    let mut i = index;
    let mut siblings = Vec::with_capacity(depth);
    for _ in 0..depth {
        siblings.push(layer[i ^ 1]);
        layer = layer.chunks(2).map(|p| hash_pair(&p[0], &p[1])).collect();
        i /= 2;
    }
    (layer[0], siblings)
}
