//! The vault against the real P1 and P2, `ethereum-verifier` and `risc0-verifier`, rather than the stub: the calls the
//! vault makes reach each verifier in the layout it reads. No real proof of the statement exists yet, so each
//! verifier's range is recorded directly, as its own tests record it, over one real mainnet block
//! (`test/fixtures/ethereum/receipts.json`): what a proof covering that block would have recorded.

mod common;

use anchor_lang::{
    prelude::Pubkey,
    solana_program::instruction::{AccountMeta, Instruction},
    InstructionData, ToAccountMetas,
};
use common::*;
use serde_json::Value;
use solana_account::Account;
use solana_signer::Signer;
use xindex_vault::{abi, constants::*, state::Checkpoint, verify::PairProofs};

/// `ethereum_verifier::VerifierError::NotTheCheckpoint` and `NotTheLog`, as the verifier programs return them.
const NOT_THE_CHECKPOINT: &str = "Custom(17)";
const NOT_THE_LOG: &str = "Custom(15)";

fn hex(s: &str) -> Vec<u8> {
    let s = s.trim_start_matches("0x");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn word(x: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&x.to_be_bytes());
    w
}

/// The real block: its number, time, state root and receipts root, and its first log's receipt proof.
struct Block {
    json: Value,
    number: u64,
    timestamp: u64,
    state_root: [u8; 32],
    receipts_root: [u8; 32],
}

impl Block {
    fn load() -> Self {
        let json: Value = serde_json::from_str(
            &std::fs::read_to_string(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../../test/fixtures/ethereum/receipts.json"
            ))
            .unwrap(),
        )
        .unwrap();
        let w = |k: &str| -> [u8; 32] { hex(json[k].as_str().unwrap()).try_into().unwrap() };
        Block {
            number: json["number"].as_u64().unwrap(),
            timestamp: json["timestamp"].as_u64().unwrap(),
            state_root: w("stateRoot"),
            receipts_root: w("receiptsRoot"),
            json,
        }
    }

    /// A proof over this block alone: its leaf is the headers root, and its path is empty.
    fn headers_root(&self) -> [u8; 32] {
        abi::keccak(&[
            &word(self.number),
            &word(self.timestamp),
            &self.state_root,
            &self.receipts_root,
        ])
    }

    /// A checkpoint proof: the header under the headers root, as the relayer writes it.
    fn header_proof(&self) -> Vec<u8> {
        let mut out = [
            &self.headers_root()[..],
            &self.number.to_le_bytes(),
            &self.timestamp.to_le_bytes(),
            &self.state_root,
            &self.receipts_root,
        ]
        .concat();
        out.push(0);
        out
    }

    /// An event proof of the block's first case: the header, the receipt's trie nodes, and which log.
    fn event_proof(&self) -> Vec<u8> {
        let case = &self.json["cases"][0];
        let nodes: Vec<Vec<u8>> = case["proof"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| hex(n.as_str().unwrap()))
            .collect();
        let mut out = self.header_proof();
        out.push(nodes.len() as u8);
        for n in &nodes {
            out.extend_from_slice(&(n.len() as u32).to_le_bytes());
            out.extend_from_slice(n);
        }
        out.extend_from_slice(&(case["txIndex"].as_u64().unwrap() as u32).to_le_bytes());
        out.extend_from_slice(&(case["logIndex"].as_u64().unwrap() as u32).to_le_bytes());
        out
    }

    fn checkpoint(&self) -> Checkpoint {
        Checkpoint {
            block: self.number,
            timestamp: self.timestamp,
            state_root: self.state_root,
        }
    }
}

/// The vault initialized with the real P1 and P2, immutable as it requires, each with a range over the real block.
struct Real {
    h: Harness,
    p1: Pubkey,
    p2: Pubkey,
    range1: Pubkey,
    range2: Pubkey,
    block: Block,
}

impl Real {
    fn new() -> Self {
        let mut h = Harness::new();
        let block = Block::load();
        let program = |name: &str| {
            std::fs::read(format!(
                "{}/../../target/deploy/{name}",
                env!("CARGO_MANIFEST_DIR")
            ))
            .unwrap_or_else(|_| panic!("build {name} first"))
        };
        let (p1, p2) = (Pubkey::new_unique(), Pubkey::new_unique());
        // LiteSVM loads a program with no upgrade authority: immutable, as the vault requires of a verifier (SOL-2).
        h.svm
            .add_program(p1, &program("ethereum_verifier.so"))
            .unwrap();
        h.svm
            .add_program(p2, &program("risc0_verifier.so"))
            .unwrap();
        let root = block.headers_root();
        let mut range = |program: Pubkey| {
            let (key, bump) = Pubkey::find_program_address(&[b"range", &root], &program);
            let data = [
                &block.number.to_le_bytes()[..],
                &block.number.to_le_bytes(),
                &[bump],
            ]
            .concat();
            let account = Account {
                lamports: SOL,
                data,
                owner: program,
                executable: false,
                rent_epoch: 0,
            };
            h.svm.set_account(key, account).unwrap();
            key
        };
        let (range1, range2) = (range(p1), range(p2));

        // Initialized an hour before the block, so its checkpoint is newer than the one initialization starts from.
        h.set_time(block.timestamp as i64 - 3_600);
        let ix = h.initialize_ix(&h.authority.pubkey(), h.init_args(), p1, p2);
        let authority = h.authority.insecure_clone();
        h.send(&[ix], &[&authority]).expect_ok();
        h.set_time(block.timestamp as i64 + 60);
        Real {
            h,
            p1,
            p2,
            range1,
            range2,
            block,
        }
    }

    /// Each verifier's program and its range: the accounts after the vault's own in every call to both.
    fn verifiers(&self) -> Vec<AccountMeta> {
        vec![
            AccountMeta::new_readonly(self.p1, false),
            AccountMeta::new_readonly(self.range1, false),
            AccountMeta::new_readonly(self.p2, false),
            AccountMeta::new_readonly(self.range2, false),
        ]
    }

    fn advance(&mut self, c: Checkpoint, proof: Vec<u8>) -> Outcome {
        let mut metas = xindex_vault::accounts::AdvanceCheckpoint {
            config: self.h.config,
        }
        .to_account_metas(None);
        metas.extend(self.verifiers());
        let ix = Instruction {
            program_id: xindex_vault::id(),
            accounts: metas,
            data: xindex_vault::instruction::AdvanceCheckpoint {
                checkpoint: c,
                proofs: PairProofs {
                    proof1: proof.clone(),
                    proof2: proof,
                    accounts1: 1,
                    accounts2: 1,
                },
            }
            .data(),
        };
        let payer = self.h.payer.insecure_clone();
        self.h.send(&[ix], &[&payer])
    }
}

/// P1 and P2 each prove the vault's checkpoint from a header under their recorded range, so the vault takes the real
/// block's number, time and state root; a state root, time or number the header does not carry is refused by the
/// verifiers themselves.
#[test]
fn the_real_verifiers_prove_a_checkpoint() {
    let mut r = Real::new();
    let proof = r.block.header_proof();
    let good = r.block.checkpoint();
    for wrong in [
        Checkpoint {
            state_root: abi::keccak(&[b"another root"]),
            ..good
        },
        Checkpoint {
            timestamp: good.timestamp - 1,
            ..good
        },
        Checkpoint {
            block: good.block + 1,
            ..good
        },
    ] {
        let outcome = r.advance(wrong, proof.clone());
        outcome.expect_error(NOT_THE_CHECKPOINT);
    }
    r.advance(good, proof).expect_ok();
    let c = r.h.config().checkpoint;
    assert_eq!(
        (c.block, c.timestamp, c.state_root),
        (good.block, good.timestamp, good.state_root)
    );
    assert!(!r.h.config().snapshot.state_root.iter().any(|b| *b != 0));
}

/// A message's delivery reaches both real verifiers in the layout `verify_event` reads: here a burn whose log is not
/// in the real receipt, which each verifier parses, proves, and refuses as not the log, from a block the checkpoint
/// covers (VLT-3).
#[test]
fn the_real_verifiers_read_the_vaults_event_call() {
    let mut r = Real::new();
    let proof = r.block.header_proof();
    r.advance(r.block.checkpoint(), proof).expect_ok();
    let (index, salt) = index_of(1);
    r.h.register(index, salt).expect_ok();
    let recipient = Pubkey::new_unique();
    let payload = r.h.payload(BURN, index, &burn_body(SOL, &recipient));
    let id = abi::keccak(&[&payload]);
    let event = r.block.event_proof();
    let data = xindex_vault::instruction::DeliverBurn {
        payload,
        proofs: xindex_vault::Proofs {
            block: r.block.number,
            proof1: Some(event.clone()),
            proof2: Some(event),
            p1_accounts: 1,
        },
    }
    .data();
    let mut metas = xindex_vault::accounts::DeliverBurn {
        payer: r.h.payer.pubkey(),
        config: r.h.config,
        used: pda(&[USED_SEED, &id]),
        index_state: pda(&[INDEX_SEED, &index]),
        owed: pda(&[OWED_SEED, &index, &id]),
        recipient,
        treasury: r.h.treasury,
        system_program: anchor_lang::solana_program::system_program::ID,
    }
    .to_account_metas(None);
    metas.extend(r.verifiers());
    let ix = Instruction {
        program_id: xindex_vault::id(),
        accounts: metas,
        data,
    };
    let payer = r.h.payer.insecure_clone();
    r.h.send(&[ix], &[&payer]).expect_error(NOT_THE_LOG);
}
