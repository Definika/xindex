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
use t22::extension::{BaseStateWithExtensions, ExtensionType, StateWithExtensions};
use xindex::{
    error::XindexError,
    pyth::{FEED_MULTIPLIER, FEED_TOKEN, PRICE_UPDATE_DISCRIMINATOR, RECEIVER},
    state::{split, Index, IndexTerms, IssueTicket, Leg, LegSpec, Listing, RedeemTicket},
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

/// What a test reads of an index: its header and its legs.
pub struct IndexView {
    pub share_mint: Pubkey,
    pub sealed: bool,
    pub rebalance_nonce: u64,
    pub header: Index,
    pub legs: Vec<Leg>,
}

/// The terms a test index is created with unless it says otherwise: no fee and the weekly interval.
pub fn terms() -> IndexTerms {
    IndexTerms {
        rebalance_interval: xindex::MIN_REBALANCE_INTERVAL,
        ..IndexTerms::default()
    }
}

/// The terms hash of `legs` at the default terms.
pub fn terms_hash(count: u16, legs: &[LegSpec]) -> [u8; 32] {
    xindex::math::terms_hash(count, &terms(), legs)
}

pub fn sheet_pda(index: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[xindex::SHEET_SEED, index.as_ref()], &xindex::ID).0
}

pub fn fill_pda(index: &Pubkey, executor: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(
        &[xindex::FILL_SEED, index.as_ref(), executor.as_ref()],
        &xindex::ID,
    )
    .0
}

pub fn request_pda(requester: &Pubkey, id: u64) -> Pubkey {
    Pubkey::find_program_address(
        &[
            xindex::REQUEST_SEED,
            requester.as_ref(),
            id.to_le_bytes().as_ref(),
        ],
        &xindex::ID,
    )
    .0
}

pub fn quote_pda(index: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[xindex::QUOTE_SEED, index.as_ref()], &xindex::ID).0
}

pub fn weights_pda(index: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[xindex::WEIGHTS_SEED, index.as_ref()], &xindex::ID).0
}

pub fn minter_pda(index: &Pubkey, wallet: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(
        &[xindex::MINTER_SEED, index.as_ref(), wallet.as_ref()],
        &xindex::ID,
    )
    .0
}

/// The test feed of a mint: its own address, so every mint has one of its own.
pub fn feed_of(mint: &Pubkey) -> [u8; 32] {
    mint.to_bytes()
}

/// Where the bench keeps Pyth's price of a mint's feed.
pub fn price_pda(mint: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[b"price", mint.as_ref()], &RECEIVER).0
}

/// `numerator / denominator` as a Pyth price and exponent, at the finest exponent, down to −30, whose price fits with
/// room for a confidence; at least six digits.
pub fn price_of(numerator: u128, denominator: u128) -> (i64, i32) {
    for k in (0..=30u32).rev() {
        let Some(scaled) = numerator.checked_mul(10u128.pow(k)) else {
            continue;
        };
        let price = scaled / denominator;
        if price <= (i64::MAX / 4) as u128 {
            assert!(
                price >= 100_000,
                "too coarse a price: {numerator}/{denominator}"
            );
            return (price as i64, -(k as i32));
        }
    }
    panic!("no exponent fits {numerator}/{denominator}");
}

/// A `PriceUpdateV2` account's data, fully verified, as Pyth's receiver writes it.
pub fn price_update(
    feed: [u8; 32],
    price: i64,
    conf: u64,
    expo: i32,
    publish_time: i64,
) -> Vec<u8> {
    let mut data = Vec::with_capacity(134);
    data.extend_from_slice(&PRICE_UPDATE_DISCRIMINATOR);
    data.extend_from_slice(&[7u8; 32]);
    data.push(1);
    data.extend_from_slice(&feed);
    data.extend_from_slice(&price.to_le_bytes());
    data.extend_from_slice(&conf.to_le_bytes());
    data.extend_from_slice(&expo.to_le_bytes());
    data.extend_from_slice(&publish_time.to_le_bytes());
    data.extend_from_slice(&publish_time.saturating_sub(1).to_le_bytes());
    data.extend_from_slice(&price.to_le_bytes());
    data.extend_from_slice(&conf.to_le_bytes());
    data.extend_from_slice(&1u64.to_le_bytes());
    data.push(0);
    data
}

pub struct Bench {
    pub svm: LiteSVM,
    pub deployer: Keypair,
    pub owner: Keypair,
    pub guardian: Keypair,
    /// Mint, freeze, pause and hook authority of every test mint, as one key is for Ondo's.
    pub issuer: Keypair,
    /// The most compute units a step of the last `prepare_fill` spent, naming units or pricing legs.
    pub last_fill_cu: u64,
    /// The configuration's two stablecoins, classic SPL mints of six decimals as Solana's USDC and USDT are.
    pub usdc: Pubkey,
    pub usdt: Pubkey,
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
        let mut bench = Self {
            svm,
            deployer,
            owner,
            guardian,
            issuer,
            last_fill_cu: 0,
            usdc: Pubkey::default(),
            usdt: Pubkey::default(),
        };
        bench.usdc = bench.mint(CLASSIC, 6, Extensions::default());
        bench.usdt = bench.mint(CLASSIC, 6, Extensions::default());
        bench
    }

    pub fn initialize_ix(
        &self,
        authority: &Pubkey,
        owner: Pubkey,
        guardian: Pubkey,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::Initialize {
                owner,
                guardian,
                usdc: self.usdc,
                usdt: self.usdt,
            }
            .data(),
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

    /// Has the issuer set `mint`'s scaled-UI multiplier to `multiplier` from `effective`, as Ondo does for a split or a
    /// dividend.
    pub fn set_multiplier(&mut self, mint: &Pubkey, multiplier: f64, effective: i64) {
        let issuer = self.issuer.insecure_clone();
        let ix = t22::extension::scaled_ui_amount::instruction::update_multiplier(
            &T22,
            mint,
            &issuer.pubkey(),
            &[],
            multiplier,
            effective,
        )
        .unwrap();
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

    /// Proposes and executes a listing of `mint` with its own feed, a `Token` one.
    pub fn list(&mut self, mint: &Pubkey, program: &Pubkey) {
        self.list_with(mint, program, FEED_TOKEN);
    }

    /// Proposes and executes a listing of `mint` and its feed of `kind`.
    pub fn list_with(&mut self, mint: &Pubkey, program: &Pubkey, kind: u8) {
        let owner = self.owner.insecure_clone();
        self.send(
            &[self.propose_listing_ix(&owner.pubkey(), mint, program)],
            &[&owner],
        )
        .unwrap();
        self.send(
            &[self.propose_feed_ix(&owner.pubkey(), mint, feed_of(mint), kind)],
            &[&owner],
        )
        .unwrap();
        self.warp(xindex::LISTING_DELAY);
        self.send(
            &[self.execute_listing_ix(mint), self.execute_feed_ix(mint)],
            &[&owner],
        )
        .unwrap();
    }

    pub fn propose_feed_ix(
        &self,
        signer: &Pubkey,
        mint: &Pubkey,
        feed: [u8; 32],
        kind: u8,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::ProposePriceFeed {
                feed_id: feed,
                kind,
            }
            .data(),
            xindex::accounts::ProposePriceFeed {
                owner: *signer,
                config: config_pda(),
                listing: listing_pda(mint),
            }
            .to_account_metas(None),
        )
    }

    pub fn execute_feed_ix(&self, mint: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::ExecutePriceFeed {}.data(),
            xindex::accounts::ExecutePriceFeed {
                listing: listing_pda(mint),
            }
            .to_account_metas(None),
        )
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
        self.begin_ix_with(creator, terms_hash, leg_count, name, symbol, terms(), false)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn begin_ix_with(
        &self,
        creator: &Pubkey,
        terms_hash: [u8; 32],
        leg_count: u16,
        name: &str,
        symbol: &str,
        terms: IndexTerms,
        gated: bool,
    ) -> Instruction {
        let index = index_pda(creator, &terms_hash);
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::BeginIndex {
                terms_hash,
                leg_count,
                name: name.to_string(),
                symbol: symbol.to_string(),
                terms,
                gated,
            }
            .data(),
            xindex::accounts::BeginIndex {
                creator: *creator,
                approval: creator_pda(creator),
                config: config_pda(),
                index,
                share_mint: shares_pda(&index),
                sheet: sheet_pda(&index),
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
                sheet: sheet_pda(index),
            }
            .to_account_metas(None),
        )
    }

    /// Creates an index of `legs` by `creator`, an approved wallet, at the default terms: begun, its legs added ten a
    /// transaction, priced on its weights, sealed.
    pub fn create(&mut self, creator: &Keypair, legs: &[LegSpec]) -> Pubkey {
        self.create_with(creator, legs, terms(), false)
    }

    pub fn create_with(
        &mut self,
        creator: &Keypair,
        legs: &[LegSpec],
        terms: IndexTerms,
        gated: bool,
    ) -> Pubkey {
        let hash = xindex::math::terms_hash(legs.len() as u16, &terms, legs);
        let index = index_pda(&creator.pubkey(), &hash);
        self.send(
            &[self.begin_ix_with(
                &creator.pubkey(),
                hash,
                legs.len() as u16,
                "Test Index",
                "TIX",
                terms,
                gated,
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
        self.price_on_weights(creator, &index);
        self.send_big(&[self.seal_ix(&creator.pubkey(), &index)], &[creator])
            .unwrap();
        self.fund(&creator.pubkey(), &shares_pda(&index), &CLASSIC, 0);
        index
    }

    // ---- prices ----

    /// The feed a mint's listing names, or proposes, or else the mint's test feed.
    pub fn feed_for(&self, mint: &Pubkey) -> [u8; 32] {
        match self.svm.get_account(&listing_pda(mint)) {
            Some(account) if !account.data.is_empty() => {
                let listing = self.listing(mint);
                if listing.feed_kind != 0 {
                    listing.feed_id
                } else if listing.feed_eta != 0 {
                    listing.pending_feed_id
                } else {
                    feed_of(mint)
                }
            }
            _ => feed_of(mint),
        }
    }

    /// The multiplier a Token-2022 mint's scaled-UI extension holds now, in 1e18, rounded down.
    pub fn multiplier(&self, mint: &Pubkey) -> u128 {
        let data = self.svm.get_account(mint).unwrap().data;
        let state = StateWithExtensions::<t22::state::Mint>::unpack(&data).unwrap();
        let config = state
            .get_extension::<t22::extension::scaled_ui_amount::ScaledUiAmountConfig>()
            .unwrap();
        xindex::pyth::wad_of(f64::from(config.new_multiplier), false).unwrap()
    }

    /// Writes Pyth's price of `mint`'s feed: `price` at `expo`, with `conf`, published at `publish_time`.
    pub fn set_price(
        &mut self,
        mint: &Pubkey,
        price: i64,
        conf: u64,
        expo: i32,
        publish_time: i64,
    ) {
        let data = price_update(self.feed_for(mint), price, conf, expo, publish_time);
        let lamports = self.svm.minimum_balance_for_rent_exemption(data.len());
        let account = solana_account::Account {
            lamports,
            data,
            owner: RECEIVER,
            executable: false,
            rent_epoch: 0,
        };
        self.svm.set_account(price_pda(mint), account).unwrap();
    }

    /// The accounts `pyth::price_leg` reads for `leg`: its listing, its price, and its mint for a `Multiplier` feed.
    pub fn price_accounts(&self, leg: &Leg) -> Vec<AccountMeta> {
        let mut metas = vec![
            AccountMeta::new_readonly(listing_pda(&leg.mint), false),
            AccountMeta::new_readonly(price_pda(&leg.mint), false),
        ];
        if self.listing(&leg.mint).feed_kind == FEED_MULTIPLIER {
            metas.push(AccountMeta::new_readonly(leg.mint, false));
        }
        metas
    }

    pub fn price_legs_ix(&self, creator: &Pubkey, index: &Pubkey, legs: &[u16]) -> Instruction {
        let state = self.index(index);
        let mut accounts = xindex::accounts::PriceLegs {
            creator: *creator,
            index: *index,
            sheet: sheet_pda(index),
        }
        .to_account_metas(None);
        for leg in legs {
            accounts.extend(self.price_accounts(&state.legs[*leg as usize]));
        }
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::PriceLegs {
                legs: legs.to_vec(),
            }
            .data(),
            accounts,
        )
    }

    /// Prices every leg of an unsealed index so its value lies on its weights, publishes the prices now, and records
    /// them in the creator's sheet, ten legs a transaction.
    pub fn price_on_weights(&mut self, creator: &Keypair, index: &Pubkey) {
        let state = self.index(index);
        let weights: Vec<u16> = state.legs.iter().map(|leg| leg.weight).collect();
        self.price_at(index, &weights);
        let legs: Vec<u16> = (0..state.legs.len() as u16).collect();
        for chunk in legs.chunks(10) {
            self.send_big(
                &[self.price_legs_ix(&creator.pubkey(), index, chunk)],
                &[creator],
            )
            .unwrap();
        }
    }

    /// Sets every leg's price so the index's value at its units splits as `shares` do, published now: a whole token of
    /// leg `i` costs `shares_i · 10^decimals / units_i`, at the finest exponent its price fits.
    pub fn price_at(&mut self, index: &Pubkey, shares: &[u16]) {
        let state = self.index(index);
        let now = self.now();
        for (leg, share) in state.legs.iter().zip(shares) {
            let whole = *share as u128 * 10u128.pow(leg.decimals as u32);
            let (price, expo) = if self.listing(&leg.mint).feed_kind == FEED_MULTIPLIER {
                // the feed prices a share, and the mint's multiplier says how many shares a token is
                price_of(
                    whole * 10u128.pow(12),
                    leg.units as u128 * self.multiplier(&leg.mint) / 1_000_000,
                )
            } else {
                price_of(whole, leg.units as u128)
            };
            self.set_price(&leg.mint, price, 0, expo, now);
        }
    }

    pub fn index(&self, index: &Pubkey) -> IndexView {
        let data = self.svm.get_account(index).unwrap().data;
        let (header, legs) = split(&data).unwrap();
        IndexView {
            share_mint: header.share_mint,
            sealed: header.sealed == 1,
            rebalance_nonce: header.rebalance_nonce,
            header: *header,
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
                share_mint: shares_pda(index),
                config: config_pda(),
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
                config: config_pda(),
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
        self.finalize_ix_with(owner, index, recipient, None, None, None)
    }

    /// The fee recipients' share accounts: the creator role's, and the platform recipient's unless the policy names
    /// nobody.
    pub fn fee_accounts(&self, index: &Pubkey) -> (Pubkey, Option<Pubkey>) {
        let state = self.index(index);
        let creator = ata(&state.header.creator_role, &shares_pda(index), &CLASSIC);
        let recipient = self.config().platform_recipient;
        let platform =
            (recipient != Pubkey::default()).then(|| ata(&recipient, &shares_pda(index), &CLASSIC));
        (creator, platform)
    }

    pub fn finalize_ix_with(
        &self,
        owner: &Pubkey,
        index: &Pubkey,
        recipient: &Pubkey,
        referrer: Option<Pubkey>,
        recipient_allowance: Option<Pubkey>,
        referrer_allowance: Option<Pubkey>,
    ) -> Instruction {
        let (creator_shares, platform_shares) = self.fee_accounts(index);
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::FinalizeIssue {}.data(),
            xindex::accounts::FinalizeIssue {
                owner: *owner,
                index: *index,
                ticket: issue_pda(index, owner),
                share_mint: shares_pda(index),
                recipient: *recipient,
                config: config_pda(),
                creator_shares,
                platform_shares,
                referrer_shares: referrer,
                recipient_allowance,
                referrer_allowance,
                token_program: CLASSIC,
            }
            .to_account_metas(None),
        )
    }

    pub fn config(&self) -> xindex::state::Config {
        let data = self.svm.get_account(&config_pda()).unwrap().data;
        xindex::state::Config::try_deserialize(&mut data.as_slice()).unwrap()
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
        self.send_big(
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
        self.send_big(
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
                config: config_pda(),
                creator_shares: self.fee_accounts(index).0,
                platform_shares: self.fee_accounts(index).1,
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

    // ---- fees, roles, the gate and the pause ----

    pub fn fee_policy_ix(
        &self,
        platform: u16,
        streaming: u16,
        referral: u16,
        recipient: Pubkey,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::SetFeePolicy {
                platform_fee_bps: platform,
                platform_streaming_bps: streaming,
                referral_share_bps: referral,
                recipient,
            }
            .data(),
            xindex::accounts::SetFeePolicy {
                owner: self.owner.pubkey(),
                config: config_pda(),
            }
            .to_account_metas(None),
        )
    }

    pub fn accrue_ix(&self, index: &Pubkey) -> Instruction {
        let (creator_shares, platform_shares) = self.fee_accounts(index);
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::AccrueFees {}.data(),
            xindex::accounts::AccrueFees {
                index: *index,
                share_mint: shares_pda(index),
                config: config_pda(),
                creator_shares,
                platform_shares,
                token_program: CLASSIC,
            }
            .to_account_metas(None),
        )
    }

    pub fn creator_ix(&self, signer: &Pubkey, index: &Pubkey, data: Vec<u8>) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &data,
            xindex::accounts::CreatorOnly {
                creator_role: *signer,
                index: *index,
            }
            .to_account_metas(None),
        )
    }

    pub fn accept_creator_ix(&self, signer: &Pubkey, index: &Pubkey) -> Instruction {
        let (creator_shares, platform_shares) = self.fee_accounts(index);
        let weights = weights_pda(index);
        let has_weights = self
            .svm
            .get_account(&weights)
            .is_some_and(|a| !a.data.is_empty());
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::AcceptCreator {}.data(),
            xindex::accounts::AcceptCreator {
                pending_creator: *signer,
                index: *index,
                share_mint: shares_pda(index),
                config: config_pda(),
                creator_shares,
                platform_shares,
                weights: has_weights.then_some(weights),
                token_program: CLASSIC,
            }
            .to_account_metas(None),
        )
    }

    pub fn allow_minter_ix(&self, signer: &Pubkey, index: &Pubkey, wallet: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::AllowMinter { wallet: *wallet }.data(),
            xindex::accounts::AllowMinter {
                creator_role: *signer,
                index: *index,
                allowance: minter_pda(index, wallet),
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    pub fn disallow_minter_ix(
        &self,
        signer: &Pubkey,
        index: &Pubkey,
        wallet: &Pubkey,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::DisallowMinter {}.data(),
            xindex::accounts::DisallowMinter {
                creator_role: *signer,
                index: *index,
                allowance: minter_pda(index, wallet),
            }
            .to_account_metas(None),
        )
    }

    pub fn pause_ix(&self, signer: &Pubkey, index: Option<&Pubkey>, paused: bool) -> Instruction {
        match index {
            Some(index) => Instruction::new_with_bytes(
                xindex::ID,
                &xindex::instruction::SetMintPause { paused }.data(),
                xindex::accounts::PauseIndex {
                    signer: *signer,
                    config: config_pda(),
                    index: *index,
                }
                .to_account_metas(None),
            ),
            None => Instruction::new_with_bytes(
                xindex::ID,
                &xindex::instruction::SetMintPauseAll { paused }.data(),
                xindex::accounts::PauseAll {
                    signer: *signer,
                    config: config_pda(),
                }
                .to_account_metas(None),
            ),
        }
    }

    // ---- the rebalance ----

    pub fn start_ix(&self, caller: &Pubkey, index: &Pubkey, keep_mask: [u64; 4]) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::StartRebalance { keep_mask }.data(),
            xindex::accounts::StartRebalance {
                caller: *caller,
                config: config_pda(),
                index: *index,
            }
            .to_account_metas(None),
        )
    }

    pub fn start_quoted_ix(
        &self,
        caller: &Pubkey,
        index: &Pubkey,
        keep_mask: [u64; 4],
        tolerance: u64,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::StartQuotedRebalance {
                keep_mask,
                tolerance,
            }
            .data(),
            xindex::accounts::StartQuotedRebalance {
                caller: *caller,
                config: config_pda(),
                index: *index,
                quote: quote_pda(index),
            }
            .to_account_metas(None),
        )
    }

    pub fn write_quote_ix(
        &self,
        caller: &Pubkey,
        index: &Pubkey,
        offset: u16,
        prices: Vec<u128>,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::WriteQuote { offset, prices }.data(),
            xindex::accounts::WriteQuote {
                caller: *caller,
                config: config_pda(),
                index: *index,
                quote: quote_pda(index),
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    pub fn cancel_ix(
        &self,
        caller: &Pubkey,
        index: &Pubkey,
        proposal_id: Option<u64>,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::CancelRebalance { proposal_id }.data(),
            xindex::accounts::CancelRebalance {
                caller: *caller,
                config: config_pda(),
                index: *index,
            }
            .to_account_metas(None),
        )
    }

    pub fn open_fill_ix(&self, executor: &Pubkey, index: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::OpenFill {}.data(),
            xindex::accounts::OpenFill {
                executor: *executor,
                index: *index,
                ticket: fill_pda(index, executor),
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    fn edit_fill_metas(&self, executor: &Pubkey, index: &Pubkey) -> Vec<AccountMeta> {
        xindex::accounts::EditFill {
            executor: *executor,
            index: *index,
            ticket: fill_pda(index, executor),
        }
        .to_account_metas(None)
    }

    pub fn set_units_ix(
        &self,
        executor: &Pubkey,
        index: &Pubkey,
        offset: u16,
        units: Vec<u64>,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::SetFillUnits { offset, units }.data(),
            self.edit_fill_metas(executor, index),
        )
    }

    /// Prices the legs named that move in the executor's ticket.
    pub fn price_fill_ix(&self, executor: &Pubkey, index: &Pubkey, legs: &[u16]) -> Instruction {
        let state = self.index(index);
        let fill = self.fill(index, executor);
        let mut accounts = self.edit_fill_metas(executor, index);
        for leg in legs {
            let i = *leg as usize;
            if fill[i].new_units != state.legs[i].units {
                accounts.extend(self.price_accounts(&state.legs[i]));
            }
        }
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::PriceFill {
                legs: legs.to_vec(),
            }
            .data(),
            accounts,
        )
    }

    pub fn deposit_fill_ix(
        &self,
        executor: &Pubkey,
        index: &Pubkey,
        leg: u16,
        amount: u64,
    ) -> Instruction {
        let state = self.index(index);
        let mint = state.legs[leg as usize].mint;
        let program = self.program_of(index, leg as usize);
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::DepositFill { leg, amount }.data(),
            xindex::accounts::DepositFill {
                executor: *executor,
                index: *index,
                share_mint: shares_pda(index),
                ticket: fill_pda(index, executor),
                mint,
                from: ata(executor, &mint, &program),
                vault: ata(index, &mint, &program),
                token_program: program,
            }
            .to_account_metas(None),
        )
    }

    pub fn withdraw_fill_ix(&self, executor: &Pubkey, index: &Pubkey, leg: u16) -> Instruction {
        let state = self.index(index);
        let mint = state.legs[leg as usize].mint;
        let program = self.program_of(index, leg as usize);
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::WithdrawFill { leg }.data(),
            xindex::accounts::WithdrawFill {
                executor: *executor,
                index: *index,
                ticket: fill_pda(index, executor),
                mint,
                vault: ata(index, &mint, &program),
                to: ata(executor, &mint, &program),
                token_program: program,
            }
            .to_account_metas(None),
        )
    }

    pub fn commit_ix(&self, executor: &Pubkey, index: &Pubkey) -> Instruction {
        let (creator_shares, platform_shares) = self.fee_accounts(index);
        let quote = quote_pda(index);
        let has_quote = self
            .svm
            .get_account(&quote)
            .is_some_and(|a| !a.data.is_empty());
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::CommitFill {}.data(),
            xindex::accounts::CommitFill {
                executor: *executor,
                index: *index,
                ticket: fill_pda(index, executor),
                share_mint: shares_pda(index),
                config: config_pda(),
                creator_shares,
                platform_shares,
                quote: has_quote.then_some(quote),
                token_program: CLASSIC,
            }
            .to_account_metas(None),
        )
    }

    pub fn close_fill_ix(&self, executor: &Pubkey, index: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::CloseFill {}.data(),
            xindex::accounts::CloseFill {
                executor: *executor,
                ticket: fill_pda(index, executor),
            }
            .to_account_metas(None),
        )
    }

    /// The legs of the executor's fill ticket.
    pub fn fill(&self, index: &Pubkey, executor: &Pubkey) -> Vec<xindex::state::FillLeg> {
        let mut data = self
            .svm
            .get_account(&fill_pda(index, executor))
            .unwrap()
            .data;
        let (_, legs) = xindex::state::split_fill(&mut data).unwrap();
        legs.to_vec()
    }

    /// What each leg of `index` gives out and needs in moving to `next` at the supply and scale now.
    pub fn amounts(&self, index: &Pubkey, next: &[u64]) -> Vec<(u64, u64)> {
        let state = self.index(index);
        let supply = self.supply(&state.share_mint);
        self.amounts_at(index, next, state.header.scale, supply)
    }

    /// What each leg of `index` gives out and needs in moving to `next` at `supply` and `scale`.
    pub fn amounts_at(
        &self,
        index: &Pubkey,
        next: &[u64],
        scale: u64,
        supply: u64,
    ) -> Vec<(u64, u64)> {
        let state = self.index(index);
        state
            .legs
            .iter()
            .zip(next)
            .map(|(leg, n)| {
                let (out, need) = xindex::settlement::leg_amounts(
                    ethnum::U256::from(supply),
                    scale as u128,
                    ethnum::U256::from(leg.units),
                    ethnum::U256::from(*n),
                    xindex::SHARE_UNIT,
                );
                (out.as_u64(), need.as_u64())
            })
            .collect()
    }

    /// Opens the executor's ticket, names `next`, prices the moving legs at the prices standing, and deposits exactly
    /// what each growing leg needs, funding the executor with it. Leaves the commit to the caller.
    pub fn prepare_fill(&mut self, executor: &Keypair, index: &Pubkey, next: &[u64]) {
        let e = executor.pubkey();
        let state = self.index(index);
        self.send(&[self.open_fill_ix(&e, index)], &[executor])
            .unwrap();
        let mut most = 0;
        for (k, chunk) in next.chunks(50).enumerate() {
            let sent = self
                .send_big(
                    &[self.set_units_ix(&e, index, (k * 50) as u16, chunk.to_vec())],
                    &[executor],
                )
                .unwrap();
            most = most.max(sent.compute_units_consumed);
        }
        let legs: Vec<u16> = (0..state.legs.len() as u16).collect();
        for chunk in legs.chunks(10) {
            let sent = self
                .send_big(&[self.price_fill_ix(&e, index, chunk)], &[executor])
                .unwrap();
            most = most.max(sent.compute_units_consumed);
        }
        self.last_fill_cu = most;
        let amounts = self.amounts(index, next);
        for (i, (_, need)) in amounts.iter().enumerate() {
            if *need == 0 {
                continue;
            }
            let program = self.program_of(index, i);
            self.fund(&e, &state.legs[i].mint, &program, *need);
            self.send(
                &[self.deposit_fill_ix(&e, index, i as u16, *need)],
                &[executor],
            )
            .unwrap();
        }
    }

    /// Withdraws everything the executor's ticket holds for it, every leg, its accounts created first.
    pub fn collect_fill(&mut self, executor: &Keypair, index: &Pubkey) {
        let e = executor.pubkey();
        let state = self.index(index);
        let fill = self.fill(index, &e);
        for (i, slot) in fill.iter().enumerate() {
            if slot.deposited == 0 && slot.settled == 0 {
                continue;
            }
            let program = self.program_of(index, i);
            self.fund(&e, &state.legs[i].mint, &program, 0);
            self.send(&[self.withdraw_fill_ix(&e, index, i as u16)], &[executor])
                .unwrap();
        }
    }

    pub fn propose_weights_ix(
        &self,
        signer: &Pubkey,
        index: &Pubkey,
        weights: Vec<u16>,
    ) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::ProposeWeights { weights }.data(),
            xindex::accounts::ProposeWeights {
                creator_role: *signer,
                index: *index,
                weights: weights_pda(index),
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    pub fn cancel_weights_ix(&self, signer: &Pubkey, index: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::CancelWeights {}.data(),
            xindex::accounts::CancelWeights {
                signer: *signer,
                config: config_pda(),
                index: *index,
                weights: weights_pda(index),
            }
            .to_account_metas(None),
        )
    }

    pub fn execute_weights_ix(&self, index: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::ExecuteWeights {}.data(),
            xindex::accounts::ExecuteWeights {
                index: *index,
                weights: weights_pda(index),
            }
            .to_account_metas(None),
        )
    }

    // ---- limit orders ----

    /// A limit order of `kind` by `requester` paying, for a mint request, `stable` for shares, and for a redeem request
    /// shares for `stable`.
    #[allow(clippy::too_many_arguments)]
    pub fn open_request_with_ix(
        &self,
        requester: &Pubkey,
        index: &Pubkey,
        id: u64,
        kind: u8,
        stable: &Pubkey,
        amount: u64,
        min_out: u64,
        deadline: i64,
        expected_nonce: Option<u64>,
    ) -> Instruction {
        let shares = shares_pda(index);
        let (pay, want) = if kind == xindex::instructions::requests::MINT_REQUEST {
            (*stable, shares)
        } else {
            (shares, *stable)
        };
        let request = request_pda(requester, id);
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::OpenRequest {
                id,
                kind,
                amount,
                min_out,
                deadline,
                expected_nonce,
            }
            .data(),
            xindex::accounts::OpenRequest {
                requester: *requester,
                config: config_pda(),
                index: *index,
                request,
                pay_mint: pay,
                want_mint: want,
                from: ata(requester, &pay, &CLASSIC),
                escrow: ata(&request, &pay, &CLASSIC),
                token_program: CLASSIC,
                associated_token_program: ATA_PROGRAM,
                system_program: SYSTEM,
            }
            .to_account_metas(None),
        )
    }

    /// A limit order in USDC for a mint request and in USDT for a redeem request.
    #[allow(clippy::too_many_arguments)]
    pub fn open_request_ix(
        &self,
        requester: &Pubkey,
        index: &Pubkey,
        id: u64,
        kind: u8,
        amount: u64,
        min_out: u64,
        deadline: i64,
        expected_nonce: Option<u64>,
    ) -> Instruction {
        let stable = if kind == xindex::instructions::requests::MINT_REQUEST {
            self.usdc
        } else {
            self.usdt
        };
        self.open_request_with_ix(
            requester,
            index,
            id,
            kind,
            &stable,
            amount,
            min_out,
            deadline,
            expected_nonce,
        )
    }

    pub fn request(&self, requester: &Pubkey, id: u64) -> xindex::state::Request {
        let data = self
            .svm
            .get_account(&request_pda(requester, id))
            .unwrap()
            .data;
        xindex::state::Request::try_deserialize(&mut data.as_slice()).unwrap()
    }

    pub fn fill_request_ix(
        &self,
        filler: &Pubkey,
        requester: &Pubkey,
        id: u64,
        amount: u64,
        expected: Option<[u8; 32]>,
    ) -> Instruction {
        let r = self.request(requester, id);
        let request = request_pda(requester, id);
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::FillRequest { amount, expected }.data(),
            xindex::accounts::FillRequest {
                filler: *filler,
                index: r.index,
                requester: *requester,
                request,
                pay_mint: r.pay_mint,
                want_mint: r.want_mint,
                escrow: ata(&request, &r.pay_mint, &CLASSIC),
                requester_account: ata(requester, &r.want_mint, &CLASSIC),
                filler_from: ata(filler, &r.want_mint, &CLASSIC),
                filler_to: ata(filler, &r.pay_mint, &CLASSIC),
                pay_program: CLASSIC,
                want_program: CLASSIC,
            }
            .to_account_metas(None),
        )
    }

    pub fn close_request_ix(&self, signer: &Pubkey, requester: &Pubkey, id: u64) -> Instruction {
        let r = self.request(requester, id);
        let request = request_pda(requester, id);
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::CloseRequest {}.data(),
            xindex::accounts::CloseRequest {
                signer: *signer,
                requester: *requester,
                request,
                pay_mint: r.pay_mint,
                escrow: ata(&request, &r.pay_mint, &CLASSIC),
                back_to: ata(requester, &r.pay_mint, &CLASSIC),
                pay_program: CLASSIC,
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
            let required = xindex::math::required(supply, leg, state.header.scale);
            assert!(
                held >= required,
                "leg {i}: the vault holds {held}, under {required}"
            );
        }
    }
}
