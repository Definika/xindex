// SPDX-License-Identifier: BUSL-1.1
//! The test bench: a LiteSVM with mainnet's features, the program deployed under the upgradeable loader with an upgrade
//! authority, the configuration initialized, and helpers that build mints, list them, create indexes and move legs.
#![allow(dead_code)]
// LiteSVM's failure carries the whole transaction's metadata, which the tests read; it is large by design.
#![allow(clippy::result_large_err)]

use anchor_lang::{
    prelude::{Clock, Pubkey},
    solana_program::{
        bpf_loader_upgradeable,
        instruction::{AccountMeta, Instruction},
    },
    AccountDeserialize, InstructionData, ToAccountMetas,
};
use anchor_spl::{
    associated_token::{
        get_associated_token_address_with_program_id,
        spl_associated_token_account::instruction::create_associated_token_account_idempotent,
    },
    token_2022::spl_token_2022 as t22,
};
use litesvm::{
    types::{FailedTransactionMetadata, TransactionMetadata},
    LiteSVM,
};
use solana_keypair::Keypair;
use solana_message::{Message, VersionedMessage};
use solana_signer::Signer;
use solana_transaction::versioned::VersionedTransaction;
use t22::extension::{ExtensionType, StateWithExtensions};
use xindex::{
    error::XindexError,
    state::{split, IssueTicket, Leg, LegSpec, Listing, RedeemTicket},
};

pub const CLASSIC: Pubkey = anchor_spl::token::ID;
pub const T22: Pubkey = anchor_spl::token_2022::ID;
pub const ATA_PROGRAM: Pubkey = anchor_spl::associated_token::ID;
pub const SYSTEM: Pubkey = anchor_lang::system_program::ID;

pub type Sent = Result<TransactionMetadata, FailedTransactionMetadata>;

/// The extensions a test mint is built with.
#[derive(Clone, Copy, Default)]
pub struct Extensions {
    pub scaled_ui: bool,
    pub pausable: bool,
    pub hook_slot: bool,
    pub hook_program: Option<Pubkey>,
    pub default_initialized: bool,
    pub default_frozen: bool,
    pub metadata_pointer: bool,
    pub transfer_fee: bool,
    pub permanent_delegate: bool,
    pub non_transferable: bool,
}

impl Extensions {
    /// The extensions of Ondo's tokens on Solana, as NVDAon's mint carries them (`docs/design/solana.md`, section 2).
    pub fn ondo() -> Self {
        Self {
            scaled_ui: true,
            pausable: true,
            hook_slot: true,
            default_initialized: true,
            metadata_pointer: true,
            ..Self::default()
        }
    }
}

/// What a test reads of an index: its header's fields and its legs.
pub struct IndexView {
    pub share_mint: Pubkey,
    pub sealed: bool,
    pub rebalance_nonce: u64,
    pub legs: Vec<Leg>,
}

pub struct Bench {
    pub svm: LiteSVM,
    pub deployer: Keypair,
    pub owner: Keypair,
    pub guardian: Keypair,
    /// Mint, freeze, pause and hook authority of every test mint, as one key is for Ondo's.
    pub issuer: Keypair,
}

pub fn config_pda() -> Pubkey {
    Pubkey::find_program_address(&[xindex::CONFIG_SEED], &xindex::ID).0
}

pub fn listing_pda(mint: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[xindex::LISTING_SEED, mint.as_ref()], &xindex::ID).0
}

pub fn creator_pda(wallet: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[xindex::CREATOR_SEED, wallet.as_ref()], &xindex::ID).0
}

pub fn index_pda(creator: &Pubkey, terms_hash: &[u8; 32]) -> Pubkey {
    Pubkey::find_program_address(
        &[xindex::INDEX_SEED, creator.as_ref(), terms_hash.as_ref()],
        &xindex::ID,
    )
    .0
}

pub fn shares_pda(index: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[xindex::SHARES_SEED, index.as_ref()], &xindex::ID).0
}

pub fn issue_pda(index: &Pubkey, owner: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(
        &[xindex::ISSUE_SEED, index.as_ref(), owner.as_ref()],
        &xindex::ID,
    )
    .0
}

pub fn redeem_pda(index: &Pubkey, owner: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(
        &[xindex::REDEEM_SEED, index.as_ref(), owner.as_ref()],
        &xindex::ID,
    )
    .0
}

pub fn ata(wallet: &Pubkey, mint: &Pubkey, program: &Pubkey) -> Pubkey {
    get_associated_token_address_with_program_id(wallet, mint, program)
}

/// The custom error code of `error`.
pub fn code(error: XindexError) -> u32 {
    6000 + error as u32
}

/// Requires `sent` to have failed with `error`.
pub fn expect_err(sent: Sent, error: XindexError) {
    let failed = sent.expect_err("the transaction should fail");
    let needle = format!("Custom({})", code(error));
    assert!(
        format!("{:?}", failed.err).contains(&needle),
        "expected {:?} ({needle}), got {:?}\n{:#?}",
        error,
        failed.err,
        failed.meta.logs
    );
}

/// Requires `sent` to have failed with a log line containing `text`.
pub fn expect_log(sent: Sent, text: &str) {
    let failed = sent.expect_err("the transaction should fail");
    assert!(
        failed.meta.logs.iter().any(|line| line.contains(text)),
        "expected a log with {text:?}, got {:?}\n{:#?}",
        failed.err,
        failed.meta.logs
    );
}

impl Bench {
    /// A chain with the program deployed, `deployer` its upgrade authority, and the configuration initialized.
    pub fn new() -> Self {
        let mut bench = Self::deployed();
        let (owner, guardian) = (bench.owner.pubkey(), bench.guardian.pubkey());
        let deployer = bench.deployer.insecure_clone();
        bench
            .send(
                &[bench.initialize_ix(&deployer.pubkey(), owner, guardian)],
                &[&deployer],
            )
            .unwrap();
        bench
    }

    /// A chain with the program deployed and nothing initialized.
    pub fn deployed() -> Self {
        let mut svm = LiteSVM::new();
        let bytes = include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../target/deploy/xindex.so"
        ));
        svm.add_program(xindex::ID, bytes).unwrap();
        let deployer = Keypair::new();
        // the loader's ProgramData account: a u32 tag, a u64 slot, then an optional upgrade authority
        let program_data =
            Pubkey::find_program_address(&[xindex::ID.as_ref()], &bpf_loader_upgradeable::ID).0;
        let mut account = svm.get_account(&program_data).unwrap();
        account.data[12] = 1;
        account.data[13..45].copy_from_slice(deployer.pubkey().as_ref());
        svm.set_account(program_data, account).unwrap();
        let (owner, guardian, issuer) = (Keypair::new(), Keypair::new(), Keypair::new());
        for key in [&deployer, &owner, &guardian, &issuer] {
            svm.airdrop(&key.pubkey(), 1_000_000_000_000).unwrap();
        }
        Self {
            svm,
            deployer,
            owner,
            guardian,
            issuer,
        }
    }

    pub fn initialize_ix(
        &self,
        authority: &Pubkey,
        owner: Pubkey,
        guardian: Pubkey,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::Initialize { owner, guardian }.data(),
            xindex::accounts::Initialize {
                authority: *authority,
                config: config_pda(),
                program: xindex::ID,
                program_data: Pubkey::find_program_address(
                    &[xindex::ID.as_ref()],
                    &bpf_loader_upgradeable::ID,
                )
                .0,
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    pub fn send(&mut self, ixs: &[Instruction], signers: &[&Keypair]) -> Sent {
        let payer = signers[0].pubkey();
        self.svm.expire_blockhash();
        let message = Message::new_with_blockhash(ixs, Some(&payer), &self.svm.latest_blockhash());
        let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(message), signers).unwrap();
        self.svm.send_transaction(tx)
    }

    /// `send` with the transaction's compute budget raised to Solana's limit, 1.4M units.
    pub fn send_big(&mut self, ixs: &[Instruction], signers: &[&Keypair]) -> Sent {
        let mut all = vec![
            solana_compute_budget_interface::ComputeBudgetInstruction::set_compute_unit_limit(
                1_400_000,
            ),
        ];
        all.extend_from_slice(ixs);
        self.send(&all, signers)
    }

    pub fn now(&self) -> i64 {
        self.svm.get_sysvar::<Clock>().unix_timestamp
    }

    pub fn warp(&mut self, seconds: i64) {
        let mut clock = self.svm.get_sysvar::<Clock>();
        clock.unix_timestamp += seconds;
        clock.slot += 1;
        self.svm.set_sysvar(&clock);
    }

    pub fn wallet(&mut self) -> Keypair {
        let key = Keypair::new();
        self.svm.airdrop(&key.pubkey(), 1_000_000_000_000).unwrap();
        key
    }

    // ---- mints and token accounts ----

    /// A mint of `program` with `decimals` and, on Token-2022, `extensions`; the issuer holds every authority.
    pub fn mint(&mut self, program: Pubkey, decimals: u8, extensions: Extensions) -> Pubkey {
        let mint = Keypair::new();
        let issuer = self.issuer.pubkey();
        let mut types = Vec::new();
        let mut init: Vec<Instruction> = Vec::new();
        let m = mint.pubkey();
        if extensions.scaled_ui {
            types.push(ExtensionType::ScaledUiAmount);
            init.push(
                t22::extension::scaled_ui_amount::instruction::initialize(
                    &T22,
                    &m,
                    Some(issuer),
                    1.0017,
                )
                .unwrap(),
            );
        }
        if extensions.pausable {
            types.push(ExtensionType::Pausable);
            init.push(
                t22::extension::pausable::instruction::initialize(&T22, &m, &issuer).unwrap(),
            );
        }
        if extensions.hook_slot || extensions.hook_program.is_some() {
            types.push(ExtensionType::TransferHook);
            init.push(
                t22::extension::transfer_hook::instruction::initialize(
                    &T22,
                    &m,
                    Some(issuer),
                    extensions.hook_program,
                )
                .unwrap(),
            );
        }
        if extensions.default_initialized || extensions.default_frozen {
            types.push(ExtensionType::DefaultAccountState);
            let state = if extensions.default_frozen {
                t22::state::AccountState::Frozen
            } else {
                t22::state::AccountState::Initialized
            };
            init.push(
                t22::extension::default_account_state::instruction::initialize_default_account_state(&T22, &m, &state)
                    .unwrap(),
            );
        }
        if extensions.metadata_pointer {
            types.push(ExtensionType::MetadataPointer);
            init.push(
                t22::extension::metadata_pointer::instruction::initialize(
                    &T22,
                    &m,
                    Some(issuer),
                    Some(m),
                )
                .unwrap(),
            );
        }
        if extensions.transfer_fee {
            types.push(ExtensionType::TransferFeeConfig);
            init.push(
                t22::extension::transfer_fee::instruction::initialize_transfer_fee_config(
                    &T22,
                    &m,
                    Some(&issuer),
                    Some(&issuer),
                    100,
                    u64::MAX,
                )
                .unwrap(),
            );
        }
        if extensions.permanent_delegate {
            types.push(ExtensionType::PermanentDelegate);
            init.push(t22::instruction::initialize_permanent_delegate(&T22, &m, &issuer).unwrap());
        }
        if extensions.non_transferable {
            types.push(ExtensionType::NonTransferable);
            init.push(t22::instruction::initialize_non_transferable_mint(&T22, &m).unwrap());
        }
        let space = if program == T22 {
            ExtensionType::try_calculate_account_len::<t22::state::Mint>(&types).unwrap()
        } else {
            82
        };
        let lamports = self.svm.minimum_balance_for_rent_exemption(space);
        let mut ixs = vec![solana_system_interface::instruction::create_account(
            &issuer,
            &m,
            lamports,
            space as u64,
            &program,
        )];
        ixs.extend(init);
        ixs.push(
            t22::instruction::initialize_mint2(&program, &m, &issuer, Some(&issuer), decimals)
                .unwrap(),
        );
        let issuer_key = self.issuer.insecure_clone();
        self.send(&ixs, &[&issuer_key, &mint]).unwrap();
        m
    }

    /// The wallet's associated account of `mint`, created if needed, with `amount` minted into it.
    pub fn fund(
        &mut self,
        wallet: &Pubkey,
        mint: &Pubkey,
        program: &Pubkey,
        amount: u64,
    ) -> Pubkey {
        let account = ata(wallet, mint, program);
        let issuer = self.issuer.insecure_clone();
        let mut ixs = vec![create_associated_token_account_idempotent(
            &issuer.pubkey(),
            wallet,
            mint,
            program,
        )];
        if amount != 0 {
            ixs.push(
                t22::instruction::mint_to(program, mint, &account, &issuer.pubkey(), &[], amount)
                    .unwrap(),
            );
        }
        self.send(&ixs, &[&issuer]).unwrap();
        account
    }

    pub fn balance(&self, account: &Pubkey) -> u64 {
        let data = self
            .svm
            .get_account(account)
            .map(|a| a.data)
            .unwrap_or_default();
        if data.is_empty() {
            return 0;
        }
        StateWithExtensions::<t22::state::Account>::unpack(&data)
            .unwrap()
            .base
            .amount
    }

    pub fn supply(&self, mint: &Pubkey) -> u64 {
        let data = self.svm.get_account(mint).unwrap().data;
        StateWithExtensions::<t22::state::Mint>::unpack(&data)
            .unwrap()
            .base
            .supply
    }

    /// Overwrites `account`'s token balance, as an issuer's burn would leave it (no listed mint lets anyone else).
    pub fn set_balance(&mut self, account: &Pubkey, amount: u64) {
        let mut acc = self.svm.get_account(account).unwrap();
        acc.data[64..72].copy_from_slice(&amount.to_le_bytes());
        self.svm.set_account(*account, acc).unwrap();
    }

    pub fn pause(&mut self, mint: &Pubkey, paused: bool) {
        let issuer = self.issuer.insecure_clone();
        let ix = if paused {
            t22::extension::pausable::instruction::pause(&T22, mint, &issuer.pubkey(), &[]).unwrap()
        } else {
            t22::extension::pausable::instruction::resume(&T22, mint, &issuer.pubkey(), &[])
                .unwrap()
        };
        self.send(&[ix], &[&issuer]).unwrap();
    }

    pub fn freeze(&mut self, account: &Pubkey, mint: &Pubkey, program: &Pubkey, frozen: bool) {
        let issuer = self.issuer.insecure_clone();
        let ix = if frozen {
            t22::instruction::freeze_account(program, account, mint, &issuer.pubkey(), &[]).unwrap()
        } else {
            t22::instruction::thaw_account(program, account, mint, &issuer.pubkey(), &[]).unwrap()
        };
        self.send(&[ix], &[&issuer]).unwrap();
    }

    pub fn set_hook(&mut self, mint: &Pubkey, program: Option<Pubkey>) {
        let issuer = self.issuer.insecure_clone();
        let ix = t22::extension::transfer_hook::instruction::update(
            &T22,
            mint,
            &issuer.pubkey(),
            &[],
            program,
        )
        .unwrap();
        self.send(&[ix], &[&issuer]).unwrap();
    }

    // ---- listings and approvals ----

    pub fn propose_listing_ix(
        &self,
        signer: &Pubkey,
        mint: &Pubkey,
        program: &Pubkey,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::ProposeListing {}.data(),
            xindex::accounts::ProposeListing {
                owner: *signer,
                config: config_pda(),
                mint: *mint,
                listing: listing_pda(mint),
                token_program: *program,
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    pub fn execute_listing_ix(&self, mint: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::ExecuteListing {}.data(),
            xindex::accounts::ExecuteListing {
                mint: *mint,
                listing: listing_pda(mint),
            }
            .to_account_metas(None),
        )
    }

    pub fn guard_listing_ix(&self, signer: &Pubkey, mint: &Pubkey, delist: bool) -> Instruction {
        let accounts = xindex::accounts::GuardListing {
            signer: *signer,
            config: config_pda(),
            listing: listing_pda(mint),
        }
        .to_account_metas(None);
        if delist {
            Instruction::new_with_bytes(
                xindex::ID,
                &xindex::instruction::Delist {}.data(),
                accounts,
            )
        } else {
            Instruction::new_with_bytes(
                xindex::ID,
                &xindex::instruction::CancelListing {}.data(),
                accounts,
            )
        }
    }

    /// Proposes and executes a listing of `mint`.
    pub fn list(&mut self, mint: &Pubkey, program: &Pubkey) {
        let owner = self.owner.insecure_clone();
        self.send(
            &[self.propose_listing_ix(&owner.pubkey(), mint, program)],
            &[&owner],
        )
        .unwrap();
        self.warp(xindex::LISTING_DELAY);
        self.send(&[self.execute_listing_ix(mint)], &[&owner])
            .unwrap();
    }

    pub fn listing(&self, mint: &Pubkey) -> Listing {
        let data = self.svm.get_account(&listing_pda(mint)).unwrap().data;
        Listing::try_deserialize(&mut data.as_slice()).unwrap()
    }

    /// Writes a mint account read from another chain, `data` as it was read, owned by `program`.
    pub fn put_mint(&mut self, mint: &Pubkey, program: &Pubkey, data: Vec<u8>) {
        let lamports = self.svm.minimum_balance_for_rent_exemption(data.len());
        let account = solana_account::Account {
            lamports,
            data,
            owner: *program,
            executable: false,
            rent_epoch: 0,
        };
        self.svm.set_account(*mint, account).unwrap();
    }

    pub fn approve_ix(&self, wallet: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::ApproveCreator { wallet: *wallet }.data(),
            xindex::accounts::ApproveCreator {
                owner: self.owner.pubkey(),
                config: config_pda(),
                approval: creator_pda(wallet),
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    pub fn approve(&mut self, wallet: &Pubkey) {
        let owner = self.owner.insecure_clone();
        self.send(&[self.approve_ix(wallet)], &[&owner]).unwrap();
    }

    pub fn revoke(&mut self, wallet: &Pubkey) {
        let owner = self.owner.insecure_clone();
        let ix = Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::RevokeCreator {}.data(),
            xindex::accounts::RevokeCreator {
                owner: owner.pubkey(),
                config: config_pda(),
                approval: creator_pda(wallet),
            }
            .to_account_metas(None),
        );
        self.send(&[ix], &[&owner]).unwrap();
    }

    // ---- creation ----

    pub fn begin_ix(
        &self,
        creator: &Pubkey,
        terms_hash: [u8; 32],
        leg_count: u16,
        name: &str,
        symbol: &str,
    ) -> Instruction {
        let index = index_pda(creator, &terms_hash);
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::BeginIndex {
                terms_hash,
                leg_count,
                name: name.to_string(),
                symbol: symbol.to_string(),
            }
            .data(),
            xindex::accounts::BeginIndex {
                creator: *creator,
                approval: creator_pda(creator),
                index,
                share_mint: shares_pda(&index),
                token_program: CLASSIC,
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    pub fn add_legs_ix(&self, creator: &Pubkey, index: &Pubkey, legs: &[LegSpec]) -> Instruction {
        let mut accounts = xindex::accounts::AddLegs {
            creator: *creator,
            index: *index,
            system_program: SYSTEM,
        }
        .to_account_metas(None);
        accounts.extend(
            legs.iter()
                .map(|leg| AccountMeta::new_readonly(listing_pda(&leg.mint), false)),
        );
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::AddLegs {
                legs: legs.to_vec(),
            }
            .data(),
            accounts,
        )
    }

    pub fn seal_ix(&self, creator: &Pubkey, index: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::SealIndex {}.data(),
            xindex::accounts::SealIndex {
                creator: *creator,
                approval: creator_pda(creator),
                index: *index,
            }
            .to_account_metas(None),
        )
    }

    /// Creates an index of `legs` by `creator`, an approved wallet: begun, its legs added ten a transaction, sealed.
    pub fn create(&mut self, creator: &Keypair, legs: &[LegSpec]) -> Pubkey {
        let hash = xindex::math::terms_hash(legs.len() as u16, legs);
        let index = index_pda(&creator.pubkey(), &hash);
        self.send(
            &[self.begin_ix(
                &creator.pubkey(),
                hash,
                legs.len() as u16,
                "Test Index",
                "TIX",
            )],
            &[creator],
        )
        .unwrap();
        for chunk in legs.chunks(10) {
            self.send_big(
                &[self.add_legs_ix(&creator.pubkey(), &index, chunk)],
                &[creator],
            )
            .unwrap();
        }
        self.send_big(&[self.seal_ix(&creator.pubkey(), &index)], &[creator])
            .unwrap();
        index
    }

    pub fn index(&self, index: &Pubkey) -> IndexView {
        let data = self.svm.get_account(index).unwrap().data;
        let (header, legs) = split(&data).unwrap();
        IndexView {
            share_mint: header.share_mint,
            sealed: header.sealed == 1,
            rebalance_nonce: header.rebalance_nonce,
            legs: legs.to_vec(),
        }
    }

    pub fn issue_ticket(&self, index: &Pubkey, owner: &Pubkey) -> Option<IssueTicket> {
        let data = self.svm.get_account(&issue_pda(index, owner))?.data;
        if data.is_empty() {
            return None;
        }
        Some(IssueTicket::try_deserialize(&mut data.as_slice()).unwrap())
    }

    pub fn redeem_ticket(&self, index: &Pubkey, owner: &Pubkey) -> Option<RedeemTicket> {
        let data = self.svm.get_account(&redeem_pda(index, owner))?.data;
        if data.is_empty() {
            return None;
        }
        Some(RedeemTicket::try_deserialize(&mut data.as_slice()).unwrap())
    }

    pub fn program_of(&self, index: &Pubkey, leg: usize) -> Pubkey {
        if self.index(index).legs[leg].token_2022 == 1 {
            T22
        } else {
            CLASSIC
        }
    }

    pub fn vault(&self, index: &Pubkey, leg: usize) -> Pubkey {
        let state = self.index(index);
        ata(index, &state.legs[leg].mint, &self.program_of(index, leg))
    }

    // ---- issue and redeem ----

    pub fn open_issue_ix(&self, owner: &Pubkey, index: &Pubkey, shares: u64) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::OpenIssue { shares }.data(),
            xindex::accounts::OpenIssue {
                owner: *owner,
                index: *index,
                ticket: issue_pda(index, owner),
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    /// A deposit of leg `leg`, from the owner's associated account of `mint` under `program`.
    pub fn deposit_ix_with(
        &self,
        owner: &Pubkey,
        index: &Pubkey,
        leg: u16,
        mint: &Pubkey,
        program: &Pubkey,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::Deposit { leg }.data(),
            xindex::accounts::Deposit {
                owner: *owner,
                index: *index,
                share_mint: shares_pda(index),
                ticket: issue_pda(index, owner),
                mint: *mint,
                from: ata(owner, mint, program),
                vault: ata(index, mint, program),
                token_program: *program,
                associated_token_program: ATA_PROGRAM,
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    pub fn deposit_ix(&self, owner: &Pubkey, index: &Pubkey, leg: u16) -> Instruction {
        let state = self.index(index);
        let mint = state.legs[leg as usize].mint;
        let program = self.program_of(index, leg as usize);
        self.deposit_ix_with(owner, index, leg, &mint, &program)
    }

    pub fn withdraw_ix(&self, owner: &Pubkey, index: &Pubkey, leg: u16) -> Instruction {
        let state = self.index(index);
        let mint = state.legs[leg as usize].mint;
        let program = self.program_of(index, leg as usize);
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::WithdrawDeposit { leg }.data(),
            xindex::accounts::WithdrawDeposit {
                owner: *owner,
                index: *index,
                ticket: issue_pda(index, owner),
                mint,
                vault: ata(index, &mint, &program),
                to: ata(owner, &mint, &program),
                token_program: program,
            }
            .to_account_metas(None),
        )
    }

    pub fn finalize_ix(&self, owner: &Pubkey, index: &Pubkey, recipient: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::FinalizeIssue {}.data(),
            xindex::accounts::FinalizeIssue {
                owner: *owner,
                index: *index,
                ticket: issue_pda(index, owner),
                share_mint: shares_pda(index),
                recipient: *recipient,
                token_program: CLASSIC,
            }
            .to_account_metas(None),
        )
    }

    pub fn cancel_issue_ix(&self, owner: &Pubkey, index: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::CancelIssue {}.data(),
            xindex::accounts::CancelIssue {
                owner: *owner,
                index: *index,
                ticket: issue_pda(index, owner),
            }
            .to_account_metas(None),
        )
    }

    /// Funds `owner` with what `shares` need of every leg, deposits them `per_tx` legs a transaction, and finalizes to the
    /// owner's share account. Returns the most compute units a deposit transaction spent.
    pub fn issue(&mut self, owner: &Keypair, index: &Pubkey, shares: u64, per_tx: usize) -> u64 {
        let state = self.index(index);
        self.send(
            &[self.open_issue_ix(&owner.pubkey(), index, shares)],
            &[owner],
        )
        .unwrap();
        let need = self.issue_ticket(index, &owner.pubkey()).unwrap().need;
        for (i, leg) in state.legs.iter().enumerate() {
            let program = self.program_of(index, i);
            self.fund(&owner.pubkey(), &leg.mint, &program, need[i]);
        }
        let mut most = 0;
        let legs: Vec<u16> = (0..state.legs.len() as u16).collect();
        for chunk in legs.chunks(per_tx) {
            let ixs: Vec<Instruction> = chunk
                .iter()
                .map(|leg| self.deposit_ix(&owner.pubkey(), index, *leg))
                .collect();
            let sent = self.send_big(&ixs, &[owner]).unwrap();
            most = most.max(sent.compute_units_consumed);
        }
        let shares_account = self.fund(&owner.pubkey(), &shares_pda(index), &CLASSIC, 0);
        self.send(
            &[self.finalize_ix(&owner.pubkey(), index, &shares_account)],
            &[owner],
        )
        .unwrap();
        most
    }

    pub fn redeem_ix(&self, owner: &Pubkey, index: &Pubkey, shares: u64) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::Redeem { shares }.data(),
            xindex::accounts::Redeem {
                owner: *owner,
                index: *index,
                share_mint: shares_pda(index),
                owner_shares: ata(owner, &shares_pda(index), &CLASSIC),
                ticket: redeem_pda(index, owner),
                token_program: CLASSIC,
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    pub fn claim_ix(
        &self,
        owner: &Pubkey,
        index: &Pubkey,
        leg: u16,
        amount: u64,
        to: &Pubkey,
    ) -> Instruction {
        let state = self.index(index);
        let mint = state.legs[leg as usize].mint;
        let program = self.program_of(index, leg as usize);
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::Claim { leg, amount }.data(),
            xindex::accounts::Claim {
                owner: *owner,
                index: *index,
                ticket: redeem_pda(index, owner),
                mint,
                vault: ata(index, &mint, &program),
                to: *to,
                token_program: program,
            }
            .to_account_metas(None),
        )
    }

    pub fn close_redeem_ix(&self, owner: &Pubkey, index: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::CloseRedeem {}.data(),
            xindex::accounts::CloseRedeem {
                owner: *owner,
                index: *index,
                ticket: redeem_pda(index, owner),
            }
            .to_account_metas(None),
        )
    }

    /// Requires every vault of `index` to hold at least the backing of the supply plus what tickets hold there.
    pub fn assert_invariant(&self, index: &Pubkey) {
        let state = self.index(index);
        let supply = self.supply(&state.share_mint);
        for (i, leg) in state.legs.iter().enumerate() {
            let held = self.balance(&self.vault(index, i)) as u128;
            let required = xindex::math::required(supply, leg);
            assert!(
                held >= required,
                "leg {i}: the vault holds {held}, under {required}"
            );
        }
    }
}
