//! The harness the vault's tests share: the vault and two copies of the stub verifier (P1 and P2) in LiteSVM, a
//! factory and hub template on "Ethereum" named by address, messages built as `VaultMessages.encode` builds them, and
//! the accounts every instruction names.
#![allow(dead_code)]

use anchor_lang::{
    prelude::{Clock, Pubkey},
    solana_program::{
        instruction::{AccountMeta, Instruction},
        system_program,
    },
    AccountDeserialize, InstructionData, ToAccountMetas,
};
use litesvm::LiteSVM;
use solana_keypair::Keypair;
use solana_message::{Message, VersionedMessage};
use solana_signer::Signer;
use solana_transaction::versioned::VersionedTransaction;
use xindex_vault::{abi, constants::*, error::VaultError, state::*};

pub const SOURCE_CHAIN_ID: u64 = 11_155_111;
pub const CHAIN_ID: u64 = 1_399_811_150;
pub const FACTORY: [u8; 20] = [0x44; 20];
pub const HUB: [u8; 20] = [0x33; 20];
pub const CAP: u64 = 1_000_000 * 1_000_000_000;
pub const FLOOR: u64 = 1_000_000_000;
pub const START: i64 = 1_800_000_000;
pub const SOL: u64 = 1_000_000_000;

pub struct Harness {
    pub svm: LiteSVM,
    pub authority: Keypair,
    pub payer: Keypair,
    pub freezer: Keypair,
    pub p1: Pubkey,
    pub p2: Pubkey,
    pub relayer1: Keypair,
    pub relayer2: Keypair,
    pub config: Pubkey,
    pub treasury: Pubkey,
    pub nonce: u64,
}

pub fn pda(seeds: &[&[u8]]) -> Pubkey {
    Pubkey::find_program_address(seeds, &xindex_vault::id()).0
}

/// A program's ProgramData account under the upgradeable loader.
pub fn programdata_of(program: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(
        &[program.as_ref()],
        &anchor_lang::solana_program::bpf_loader_upgradeable::id(),
    )
    .0
}

pub fn index_of(salt: u8) -> ([u8; 20], [u8; 32]) {
    let salt = [salt; 32];
    (abi::predict_clone(&HUB, &salt, &FACTORY), salt)
}

pub fn code(e: VaultError) -> u32 {
    anchor_lang::error::ERROR_CODE_OFFSET + e as u32
}

fn u256(x: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&x.to_be_bytes());
    w
}

fn address(a: &[u8; 20]) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(a);
    w
}

/// An intake id with its deadline in the top 64 bits.
pub fn intake_id(deadline: i64, nonce: u64) -> [u8; 32] {
    let mut id = [0u8; 32];
    id[..8].copy_from_slice(&(deadline as u64).to_be_bytes());
    id[24..].copy_from_slice(&nonce.to_be_bytes());
    id
}

pub fn burn_body(amount: u64, recipient: &Pubkey) -> Vec<u8> {
    [[0u8; 32], u256(amount), recipient.to_bytes()].concat()
}

pub fn migrate_body(new_index: &[u8; 20], amount: u64) -> Vec<u8> {
    [address(new_index), [0u8; 32], u256(amount)].concat()
}

pub fn cap_body(cap: u64, floor: u64) -> Vec<u8> {
    [[0u8; 32], u256(cap), u256(floor)].concat()
}

/// Which verifiers prove a message, as the relayer chooses.
#[derive(Clone, Copy, PartialEq)]
pub enum By {
    Both,
    P1,
    P2,
}

pub struct Outcome {
    pub ok: bool,
    pub error: Option<String>,
    pub logs: Vec<String>,
}

impl Outcome {
    pub fn expect_code(&self, e: VaultError) {
        let want = format!("Custom({})", code(e));
        assert!(!self.ok, "expected {want}, but it succeeded");
        let got = self.error.clone().unwrap_or_default();
        assert!(
            got.contains(&want),
            "expected {want}, got {got}\n{:#?}",
            self.logs
        );
    }

    pub fn expect_error(&self, fragment: &str) {
        assert!(!self.ok, "expected {fragment}, but it succeeded");
        let got = self.error.clone().unwrap_or_default();
        assert!(
            got.contains(fragment),
            "expected {fragment}, got {got}\n{:#?}",
            self.logs
        );
    }

    pub fn expect_ok(&self) {
        assert!(self.ok, "failed: {:?}\n{:#?}", self.error, self.logs);
    }
}

impl Harness {
    pub fn new() -> Self {
        let mut svm = LiteSVM::new();
        let vault = include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../target/deploy/xindex_vault.so"
        ));
        let stub = include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../target/deploy/stub_verifier.so"
        ));
        svm.add_program(xindex_vault::id(), vault).unwrap();
        let (p1, p2) = (Pubkey::new_unique(), Pubkey::new_unique());
        svm.add_program(p1, stub).unwrap();
        svm.add_program(p2, stub).unwrap();
        let authority = Keypair::new();
        // LiteSVM loads a program with no upgrade authority; the vault's is the test's deployer.
        let programdata = Pubkey::find_program_address(
            &[xindex_vault::id().as_ref()],
            &anchor_lang::solana_program::bpf_loader_upgradeable::id(),
        )
        .0;
        let mut account = svm.get_account(&programdata).unwrap();
        account.data[12] = 1;
        account.data[13..45].copy_from_slice(authority.pubkey().as_ref());
        svm.set_account(programdata, account).unwrap();

        let mut h = Harness {
            svm,
            authority,
            payer: Keypair::new(),
            freezer: Keypair::new(),
            p1,
            p2,
            relayer1: Keypair::new(),
            relayer2: Keypair::new(),
            config: pda(&[CONFIG_SEED]),
            treasury: pda(&[TREASURY_SEED]),
            nonce: 0,
        };
        for k in [&h.authority, &h.payer, &h.freezer, &h.relayer1, &h.relayer2] {
            h.svm.airdrop(&k.pubkey(), 1_000 * SOL).unwrap();
        }
        h.set_time(START);
        let (r1, r2) = (h.relayer1.pubkey(), h.relayer2.pubkey());
        h.init_stub(p1, &r1).expect_ok();
        h.init_stub(p2, &r2).expect_ok();
        h
    }

    pub fn set_time(&mut self, t: i64) {
        let mut clock: Clock = self.svm.get_sysvar();
        clock.unix_timestamp = t;
        self.svm.set_sysvar(&clock);
        self.svm.expire_blockhash();
    }

    pub fn now(&self) -> i64 {
        self.svm.get_sysvar::<Clock>().unix_timestamp
    }

    pub fn warp(&mut self, seconds: i64) {
        let t = self.now() + seconds;
        self.set_time(t);
    }

    pub fn send(&mut self, ixs: &[Instruction], signers: &[&Keypair]) -> Outcome {
        self.svm.expire_blockhash();
        let payer = signers[0].pubkey();
        let msg = Message::new_with_blockhash(ixs, Some(&payer), &self.svm.latest_blockhash());
        let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), signers).unwrap();
        match self.svm.send_transaction(tx) {
            Ok(meta) => Outcome {
                ok: true,
                error: None,
                logs: meta.logs,
            },
            Err(f) => Outcome {
                ok: false,
                error: Some(format!("{:?}", f.err)),
                logs: f.meta.logs,
            },
        }
    }

    /// The serialized size of a transaction of `ixs`, against Solana's 1,232-byte limit.
    pub fn size(&self, ixs: &[Instruction], signers: &[&Keypair]) -> usize {
        let payer = signers[0].pubkey();
        let msg = Message::new_with_blockhash(ixs, Some(&payer), &self.svm.latest_blockhash());
        msg.serialize().len() + 1 + 64 * signers.len()
    }

    /// Deploys the stub as a deployer does: its upgrade authority sets the relayer key, then the program is made
    /// immutable, as the vault requires of a verifier.
    pub fn init_stub(&mut self, program: Pubkey, relayer: &Pubkey) -> Outcome {
        let payer = self.payer.insecure_clone();
        self.set_upgrade_authority(program, Some(payer.pubkey()));
        let outcome = self.init_stub_by(program, relayer, &payer);
        self.set_upgrade_authority(program, None);
        outcome
    }

    pub fn init_stub_by(&mut self, program: Pubkey, relayer: &Pubkey, by: &Keypair) -> Outcome {
        let state = Pubkey::find_program_address(&[b"verifier"], &program).0;
        let ix = Instruction {
            program_id: program,
            accounts: vec![
                AccountMeta::new(state, false),
                AccountMeta::new(by.pubkey(), true),
                AccountMeta::new_readonly(system_program::ID, false),
                AccountMeta::new_readonly(programdata_of(&program), false),
            ],
            data: [&[1u8][..], relayer.as_ref()].concat(),
        };
        self.send(&[ix], &[by])
    }

    /// Rewrites a program's upgrade authority in its ProgramData account, as `solana program set-upgrade-authority`
    /// would; `None` makes it immutable.
    pub fn set_upgrade_authority(&mut self, program: Pubkey, authority: Option<Pubkey>) {
        let data = programdata_of(&program);
        let mut account = self.svm.get_account(&data).unwrap();
        match authority {
            Some(key) => {
                account.data[12] = 1;
                account.data[13..45].copy_from_slice(key.as_ref());
            }
            None => {
                account.data[12] = 0;
                account.data[13..45].fill(0);
            }
        }
        self.svm.set_account(data, account).unwrap();
    }

    pub fn init_args(&self) -> xindex_vault::InitArgs {
        xindex_vault::InitArgs {
            source_chain_id: SOURCE_CHAIN_ID,
            chain_id: CHAIN_ID,
            factory: FACTORY,
            hub_implementation: HUB,
            freezer: self.freezer.pubkey(),
            native_cap: CAP,
            native_floor: FLOOR,
        }
    }

    pub fn initialize_ix(
        &self,
        by: &Pubkey,
        args: xindex_vault::InitArgs,
        p1: Pubkey,
        p2: Pubkey,
    ) -> Instruction {
        let programdata = Pubkey::find_program_address(
            &[xindex_vault::id().as_ref()],
            &anchor_lang::solana_program::bpf_loader_upgradeable::id(),
        )
        .0;
        Instruction::new_with_bytes(
            xindex_vault::id(),
            &xindex_vault::instruction::Initialize { args }.data(),
            xindex_vault::accounts::Initialize {
                authority: *by,
                config: self.config,
                treasury: self.treasury,
                p1,
                p2,
                program: xindex_vault::id(),
                program_data: programdata,
                system_program: system_program::ID,
                p1_data: Some(programdata_of(&p1)),
                p2_data: Some(programdata_of(&p2)),
            }
            .to_account_metas(None),
        )
    }

    /// The vault initialized by its deployer, with an index registered.
    pub fn ready() -> (Self, [u8; 20]) {
        let mut h = Self::new();
        let ix = h.initialize_ix(&h.authority.pubkey(), h.init_args(), h.p1, h.p2);
        let authority = h.authority.insecure_clone();
        h.send(&[ix], &[&authority]).expect_ok();
        let (index, salt) = index_of(1);
        h.register(index, salt).expect_ok();
        (h, index)
    }

    pub fn register(&mut self, index: [u8; 20], salt: [u8; 32]) -> Outcome {
        let ix = Instruction::new_with_bytes(
            xindex_vault::id(),
            &xindex_vault::instruction::RegisterIndex { index, salt }.data(),
            xindex_vault::accounts::RegisterIndex {
                payer: self.payer.pubkey(),
                config: self.config,
                index_state: pda(&[INDEX_SEED, &index]),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        let payer = self.payer.insecure_clone();
        self.send(&[ix], &[&payer])
    }

    pub fn deposit(
        &mut self,
        from: &Keypair,
        index: [u8; 20],
        intake: [u8; 32],
        amount: u64,
    ) -> Outcome {
        let ix = Instruction::new_with_bytes(
            xindex_vault::id(),
            &xindex_vault::instruction::Deposit {
                index,
                intake_id: intake,
                amount,
            }
            .data(),
            xindex_vault::accounts::Deposit {
                depositor: from.pubkey(),
                config: self.config,
                index_state: pda(&[INDEX_SEED, &index]),
                intake: pda(&[INTAKE_SEED, &index, &intake]),
                deposit_record: pda(&[DEPOSIT_SEED, &index, &intake, from.pubkey().as_ref()]),
                treasury: self.treasury,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        self.send(&[ix], &[from])
    }

    pub fn refund(&mut self, from: &Keypair, index: [u8; 20], intake: [u8; 32]) -> Outcome {
        let ix = Instruction::new_with_bytes(
            xindex_vault::id(),
            &xindex_vault::instruction::Refund {
                index,
                intake_id: intake,
            }
            .data(),
            xindex_vault::accounts::Refund {
                depositor: from.pubkey(),
                config: self.config,
                intake: pda(&[INTAKE_SEED, &index, &intake]),
                deposit_record: pda(&[DEPOSIT_SEED, &index, &intake, from.pubkey().as_ref()]),
                treasury: self.treasury,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        self.send(&[ix], &[from])
    }

    /// A message as `VaultMessages.encode` builds it, from `emitter` (an index, or the factory), to this vault.
    pub fn payload(&mut self, kind: u8, emitter: [u8; 20], body: &[u8]) -> Vec<u8> {
        self.nonce += 1;
        let mut p = Vec::new();
        for w in [
            DOMAIN,
            u256(SOURCE_CHAIN_ID),
            u256(kind as u64),
            u256(CHAIN_ID),
            self.config.to_bytes(),
            address(&emitter),
            u256(self.nonce),
            u256(256),
            u256(body.len() as u64),
        ] {
            p.extend_from_slice(&w);
        }
        p.extend_from_slice(body);
        p.resize(p.len() + (32 - body.len() % 32) % 32, 0);
        p
    }

    pub fn proofs(&self, by: By) -> xindex_vault::Proofs {
        xindex_vault::Proofs {
            block: 1,
            proof1: (by != By::P2).then(Vec::new),
            proof2: (by != By::P1).then(Vec::new),
            p1_accounts: 2,
        }
    }

    /// The verifiers' accounts, and the relayers who must sign for the stubs.
    pub fn verifier_accounts(&self, by: By) -> (Vec<AccountMeta>, Vec<Keypair>) {
        let mut metas = Vec::new();
        let mut signers = Vec::new();
        let groups = [
            (self.p1, &self.relayer1, By::P2),
            (self.p2, &self.relayer2, By::P1),
        ];
        for (program, relayer, skip) in groups {
            if by == skip {
                continue;
            }
            metas.push(AccountMeta::new_readonly(program, false));
            metas.push(AccountMeta::new_readonly(
                Pubkey::find_program_address(&[b"verifier"], &program).0,
                false,
            ));
            metas.push(AccountMeta::new_readonly(relayer.pubkey(), true));
            signers.push(relayer.insecure_clone());
        }
        (metas, signers)
    }

    fn deliver(&mut self, data: Vec<u8>, mut metas: Vec<AccountMeta>, by: By) -> Outcome {
        let (verifiers, relayers) = self.verifier_accounts(by);
        metas.extend(verifiers);
        let ix = Instruction {
            program_id: xindex_vault::id(),
            accounts: metas,
            data,
        };
        let payer = self.payer.insecure_clone();
        let mut signers: Vec<&Keypair> = vec![&payer];
        signers.extend(relayers.iter());
        self.send(&[ix], &signers)
    }

    pub fn deliver_burn(
        &mut self,
        index: [u8; 20],
        payload: Vec<u8>,
        recipient: Pubkey,
        by: By,
    ) -> Outcome {
        let id = abi::keccak(&[&payload]);
        let data = xindex_vault::instruction::DeliverBurn {
            payload,
            proofs: self.proofs(by),
        }
        .data();
        let metas = xindex_vault::accounts::DeliverBurn {
            payer: self.payer.pubkey(),
            config: self.config,
            used: pda(&[USED_SEED, &id]),
            index_state: pda(&[INDEX_SEED, &index]),
            owed: pda(&[OWED_SEED, &index, &id]),
            recipient,
            treasury: self.treasury,
            system_program: system_program::ID,
        }
        .to_account_metas(None);
        self.deliver(data, metas, by)
    }

    pub fn deliver_intake(
        &mut self,
        index: [u8; 20],
        intake: [u8; 32],
        kind: u8,
        by: By,
    ) -> Outcome {
        let payload = self.payload(kind, index, &intake);
        self.deliver_intake_payload(index, intake, payload, by)
    }

    pub fn deliver_intake_payload(
        &mut self,
        index: [u8; 20],
        intake: [u8; 32],
        payload: Vec<u8>,
        by: By,
    ) -> Outcome {
        let id = abi::keccak(&[&payload]);
        self.deliver_intake_with_id(index, intake, payload, id, by)
    }

    /// With the used mark at the address `id` derives, which the program checks is the payload's.
    pub fn deliver_intake_with_id(
        &mut self,
        index: [u8; 20],
        intake: [u8; 32],
        payload: Vec<u8>,
        id: [u8; 32],
        by: By,
    ) -> Outcome {
        let data = xindex_vault::instruction::DeliverIntake {
            payload,
            proofs: self.proofs(by),
        }
        .data();
        let metas = xindex_vault::accounts::DeliverIntake {
            payer: self.payer.pubkey(),
            config: self.config,
            used: pda(&[USED_SEED, &id]),
            index_state: pda(&[INDEX_SEED, &index]),
            intake: pda(&[INTAKE_SEED, &index, &intake]),
            system_program: system_program::ID,
        }
        .to_account_metas(None);
        self.deliver(data, metas, by)
    }

    pub fn deliver_migrate(
        &mut self,
        index: [u8; 20],
        new_index: [u8; 20],
        payload: Vec<u8>,
        by: By,
    ) -> Outcome {
        let id = abi::keccak(&[&payload]);
        let data = xindex_vault::instruction::DeliverMigrate {
            payload,
            proofs: self.proofs(by),
        }
        .data();
        let metas = xindex_vault::accounts::DeliverMigrate {
            payer: self.payer.pubkey(),
            config: self.config,
            used: pda(&[USED_SEED, &id]),
            index_state: pda(&[INDEX_SEED, &index]),
            new_index_state: pda(&[INDEX_SEED, &new_index]),
            owed: pda(&[OWED_SEED, &index, &id]),
            system_program: system_program::ID,
        }
        .to_account_metas(None);
        self.deliver(data, metas, by)
    }

    pub fn deliver_governance(&mut self, payload: Vec<u8>, by: By) -> Outcome {
        let id = abi::keccak(&[&payload]);
        let data = xindex_vault::instruction::DeliverGovernance {
            payload,
            proofs: self.proofs(by),
        }
        .data();
        let metas = xindex_vault::accounts::DeliverGovernance {
            payer: self.payer.pubkey(),
            config: self.config,
            used: pda(&[USED_SEED, &id]),
            system_program: system_program::ID,
        }
        .to_account_metas(None);
        self.deliver(data, metas, by)
    }

    /// Applies the waiting change of `kind` with `body`; a rotation names its new verifiers' accounts.
    pub fn apply_change(
        &mut self,
        kind: u8,
        body: &[u8],
        new_verifiers: Option<(Pubkey, Pubkey)>,
    ) -> Outcome {
        let ix = Instruction::new_with_bytes(
            xindex_vault::id(),
            &xindex_vault::instruction::ApplyChange {
                kind,
                body: body.to_vec(),
            }
            .data(),
            xindex_vault::accounts::ApplyChange {
                config: self.config,
                new_p1: new_verifiers.map(|v| v.0),
                new_p2: new_verifiers.map(|v| v.1),
                new_p1_data: new_verifiers.map(|v| programdata_of(&v.0)),
                new_p2_data: new_verifiers.map(|v| programdata_of(&v.1)),
            }
            .to_account_metas(None),
        );
        let payer = self.payer.insecure_clone();
        self.send(&[ix], &[&payer])
    }

    pub fn cancel_change(&mut self, by: &Keypair, kind: u8) -> Outcome {
        let ix = Instruction::new_with_bytes(
            xindex_vault::id(),
            &xindex_vault::instruction::CancelChange { kind }.data(),
            xindex_vault::accounts::CancelChange {
                freezer: by.pubkey(),
                config: self.config,
            }
            .to_account_metas(None),
        );
        let payer = self.payer.insecure_clone();
        self.send(&[ix], &[&payer, by])
    }

    /// The factory's governance message that loosens a rule, on both proofs, applied once its delay has passed.
    pub fn govern(
        &mut self,
        kind: u8,
        body: &[u8],
        new_verifiers: Option<(Pubkey, Pubkey)>,
    ) -> Outcome {
        let p = self.payload(kind, FACTORY, body);
        self.deliver_governance(p, By::Both).expect_ok();
        self.warp(GOVERNANCE_DELAY);
        self.apply_change(kind, body, new_verifiers)
    }

    pub fn release(&mut self, index: [u8; 20], id: [u8; 32], recipient: Pubkey) -> Outcome {
        let ix = Instruction::new_with_bytes(
            xindex_vault::id(),
            &xindex_vault::instruction::Release { index, id }.data(),
            xindex_vault::accounts::Release {
                config: self.config,
                index_state: pda(&[INDEX_SEED, &index]),
                owed: pda(&[OWED_SEED, &index, &id]),
                recipient,
                treasury: self.treasury,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        let payer = self.payer.insecure_clone();
        self.send(&[ix], &[&payer])
    }

    pub fn release_migration(
        &mut self,
        index: [u8; 20],
        id: [u8; 32],
        new_index: [u8; 20],
    ) -> Outcome {
        let ix = Instruction::new_with_bytes(
            xindex_vault::id(),
            &xindex_vault::instruction::ReleaseMigration { index, id }.data(),
            xindex_vault::accounts::ReleaseMigration {
                config: self.config,
                index_state: pda(&[INDEX_SEED, &index]),
                owed: pda(&[OWED_SEED, &index, &id]),
                new_index_state: pda(&[INDEX_SEED, &new_index]),
            }
            .to_account_metas(None),
        );
        let payer = self.payer.insecure_clone();
        self.send(&[ix], &[&payer])
    }

    pub fn freeze(&mut self, by: &Keypair) -> Outcome {
        let ix = Instruction::new_with_bytes(
            xindex_vault::id(),
            &xindex_vault::instruction::Freeze {}.data(),
            xindex_vault::accounts::Freeze {
                freezer: by.pubkey(),
                config: self.config,
            }
            .to_account_metas(None),
        );
        let payer = self.payer.insecure_clone();
        self.send(&[ix], &[&payer, by])
    }

    /// Deposits `amount` into a fresh intake of `index` and settles it, so the index holds it.
    pub fn fund(&mut self, index: [u8; 20], amount: u64) -> [u8; 32] {
        self.nonce += 1;
        let intake = intake_id(self.now() + 3600, self.nonce);
        let depositor = Keypair::new();
        self.svm.airdrop(&depositor.pubkey(), amount + SOL).unwrap();
        self.deposit(&depositor, index, intake, amount).expect_ok();
        self.deliver_intake(index, intake, INTAKE_SETTLED, By::Both)
            .expect_ok();
        intake
    }

    pub fn account<T: AccountDeserialize>(&self, key: &Pubkey) -> T {
        let account = self.svm.get_account(key).expect("no such account");
        T::try_deserialize(&mut account.data.as_slice()).unwrap()
    }

    pub fn config(&self) -> Config {
        self.account(&self.config)
    }

    pub fn index(&self, index: &[u8; 20]) -> IndexState {
        self.account(&pda(&[INDEX_SEED, index]))
    }

    pub fn intake(&self, index: &[u8; 20], intake: &[u8; 32]) -> Intake {
        self.account(&pda(&[INTAKE_SEED, index, intake]))
    }

    pub fn owed(&self, index: &[u8; 20], id: &[u8; 32]) -> Owed {
        self.account(&pda(&[OWED_SEED, index, id]))
    }

    pub fn lamports(&self, key: &Pubkey) -> u64 {
        self.svm.get_account(key).map(|a| a.lamports).unwrap_or(0)
    }

    /// What the treasury holds beyond its rent reserve.
    pub fn treasury_balance(&self) -> u64 {
        self.lamports(&self.treasury) - self.svm.minimum_balance_for_rent_exemption(0)
    }
}
