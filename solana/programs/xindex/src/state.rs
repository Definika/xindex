// SPDX-License-Identifier: BUSL-1.1
use anchor_lang::prelude::*;

use crate::constants::{MASK_WORDS, MAX_NAME_LEN};

/// The one configuration: who owns the program's listings and approvals, who guards them, the platform's fee policy,
/// and the pause of every index's minting.
#[account]
#[derive(InitSpace)]
pub struct Config {
    pub owner: Pubkey,
    /// The account the owner offered its role to, or the default key.
    pub pending_owner: Pubkey,
    /// The guardian, or the default key once the role is removed.
    pub guardian: Pubkey,
    /// The proposed guardian; meaningful while `pending_guardian_eta` is not zero.
    pub pending_guardian: Pubkey,
    /// When the proposed guardian may take the role; zero when nothing is proposed.
    pub pending_guardian_eta: i64,
    /// The wallet the platform's fee shares go to, read at each fee; the default key folds them into the creator's.
    pub platform_recipient: Pubkey,
    /// The platform's issue and redeem fee for indexes created from now on.
    pub platform_fee_bps: u16,
    /// The platform's yearly streaming fee for indexes created from now on.
    pub platform_streaming_bps: u16,
    /// A referrer's part of the platform's issue fee, for indexes created from now on.
    pub referral_share_bps: u16,
    /// Whether the owner or the guardian has paused the minting of every index.
    pub mint_paused_all: bool,
    /// The two stablecoins a limit order is paid or paid out in, fixed at the initialization.
    pub usdc: Pubkey,
    pub usdt: Pubkey,
    pub bump: u8,
}

/// A mint's listing. Its decimals are read when it is proposed, and bound the units an index may start with. Its price
/// feed is the owner's to set behind the listing delay.
#[account]
#[derive(InitSpace)]
pub struct Listing {
    pub mint: Pubkey,
    pub token_program: Pubkey,
    pub decimals: u8,
    pub listed: bool,
    /// When the proposal may be executed; zero when nothing is proposed.
    pub eta: i64,
    pub bump: u8,
    /// Pyth's feed for the mint, and its kind (`pyth::FEED_*`); none until one is executed.
    pub feed_id: [u8; 32],
    pub feed_kind: u8,
    /// A proposed feed, executable from `feed_eta`; `feed_eta` is zero when none is proposed.
    pub pending_feed_id: [u8; 32],
    pub pending_feed_kind: u8,
    pub feed_eta: i64,
}

/// A wallet the owner approved to create indexes. The account's existence is the approval.
#[account]
#[derive(InitSpace)]
pub struct Creator {
    pub wallet: Pubkey,
    pub bump: u8,
}

/// A wallet a gated index's creator allows to receive new shares. The account's existence is the allowance.
#[account]
#[derive(InitSpace)]
pub struct Minter {
    pub index: Pubkey,
    pub wallet: Pubkey,
    pub bump: u8,
}

/// The terms an index's address commits to beside its legs: the fee rates and the rebalance interval it was created
/// with. The platform's rates and the referral share are the policy's at creation.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct IndexTerms {
    pub creator_fee_bps: u16,
    pub platform_fee_bps: u16,
    pub referral_share_bps: u16,
    pub creator_streaming_bps: u16,
    pub platform_streaming_bps: u16,
    pub rebalance_interval: i64,
}

/// One leg of an index: a listed mint, its fixed units per whole share and its weight, and what the vault holds for
/// others beside the backing of the shares. Stored after the index's header, `legs_len` of them.
#[zero_copy]
#[derive(Debug, PartialEq, Eq)]
pub struct Leg {
    pub mint: Pubkey,
    /// Raw units of the mint per whole share, before the streaming fee's scale.
    pub units: u64,
    /// What open redeem tickets and committed fills wait to claim of this leg.
    pub owed: u64,
    /// What open issue tickets and fill tickets have deposited of this leg.
    pub pending: u64,
    /// Basis points of the index's value.
    pub weight: u16,
    /// 1 when the mint is Token-2022's, 0 when it is the SPL Token program's.
    pub token_2022: u8,
    pub decimals: u8,
    pub _reserved: [u8; 4],
}

/// An index's header. Its address commits to its terms (`["index", creator, terms_hash]`); it opens once sealed. The
/// legs follow it in the account's data, read in place, so two hundred of them cost no heap.
#[account(zero_copy)]
#[derive(Debug)]
pub struct Index {
    /// The wallet that began the index, in its address; it never changes.
    pub creator: Pubkey,
    pub terms_hash: [u8; 32],
    pub share_mint: Pubkey,
    /// Who holds the creator role now: its fees, its gate and its weights.
    pub creator_role: Pubkey,
    /// The account the role was offered to, or the default key.
    pub pending_creator: Pubkey,
    /// Moves when a rebalance settles; an issue ticket finalizes only at the nonce it was opened at.
    pub rebalance_nonce: u64,
    /// The factor every leg's units carry, in 1e18; each streaming accrual shrinks it, and nothing else moves it.
    pub scale: u64,
    /// When the streaming fee was last accrued, an accrual that owed nothing included.
    pub last_accrual: i64,
    pub rebalance_interval: i64,
    /// When the pending auction opens; zero when no rebalance is pending.
    pub eta: i64,
    /// The id of the latest proposal.
    pub proposal_count: u64,
    /// When the last fill settled, or when the index was sealed.
    pub last_rebalance: i64,
    /// Strangers may not start before this, after a cancel.
    pub restart_allowed_at: i64,
    /// The proposal a quote binds, and its tolerance in 1e18; zero when none does.
    pub quote_proposal: u64,
    pub quote_tolerance: u64,
    /// The legs the pending proposal keeps, a bit each.
    pub keep_mask: [u64; MASK_WORDS],
    /// The legs the index was begun with; `legs_len` reaches it before the index can be sealed.
    pub leg_count: u16,
    pub legs_len: u16,
    pub creator_fee_bps: u16,
    pub platform_fee_bps: u16,
    pub referral_share_bps: u16,
    pub creator_streaming_bps: u16,
    pub platform_streaming_bps: u16,
    pub sealed: u8,
    pub bump: u8,
    pub shares_bump: u8,
    pub name_len: u8,
    pub symbol_len: u8,
    /// Whether only the creator role and the wallets it allows receive new shares.
    pub gated: u8,
    /// Whether the owner or the guardian has paused this index's minting.
    pub mint_paused: u8,
    /// Whether the last settlement had a keep mask, so the next start may come `MIN_REBALANCE_INTERVAL` after it.
    pub masked_fill: u8,
    pub name: [u8; MAX_NAME_LEN],
    pub symbol: [u8; 16],
    pub _reserved: [u8; 2],
}

/// What an index's signer seeds are built from, copied out so no borrow of its data is held across a call.
pub struct IndexSeeds {
    pub creator: Pubkey,
    pub terms_hash: [u8; 32],
    pub bump: [u8; 1],
}

impl IndexSeeds {
    pub fn seeds(&self) -> [&[u8]; 4] {
        [
            crate::constants::INDEX_SEED,
            self.creator.as_ref(),
            self.terms_hash.as_ref(),
            self.bump.as_ref(),
        ]
    }
}

impl Index {
    /// Where the legs start: the discriminator, then the header.
    pub const HEADER: usize = 8 + std::mem::size_of::<Index>();
    pub const LEG: usize = std::mem::size_of::<Leg>();

    /// The account's size with `legs` legs.
    pub fn space(legs: usize) -> usize {
        Self::HEADER + legs * Self::LEG
    }

    pub fn seeds(&self) -> IndexSeeds {
        IndexSeeds {
            creator: self.creator,
            terms_hash: self.terms_hash,
            bump: [self.bump],
        }
    }

    pub fn terms(&self) -> IndexTerms {
        IndexTerms {
            creator_fee_bps: self.creator_fee_bps,
            platform_fee_bps: self.platform_fee_bps,
            referral_share_bps: self.referral_share_bps,
            creator_streaming_bps: self.creator_streaming_bps,
            platform_streaming_bps: self.platform_streaming_bps,
            rebalance_interval: self.rebalance_interval,
        }
    }

    /// The fee on an issue and a redeem, the creator's and the platform's, in basis points.
    pub fn fee_bps(&self) -> u16 {
        self.creator_fee_bps + self.platform_fee_bps
    }

    /// The yearly streaming fee, the creator's and the platform's, in basis points.
    pub fn streaming_bps(&self) -> u16 {
        self.creator_streaming_bps + self.platform_streaming_bps
    }

    /// Whether the pending proposal keeps leg `leg`.
    pub fn keeps(&self, leg: usize) -> bool {
        mask_bit(&self.keep_mask, leg)
    }
}

/// Whether `mask` sets bit `leg`.
pub fn mask_bit(mask: &[u64; MASK_WORDS], leg: usize) -> bool {
    leg < 64 * MASK_WORDS && (mask[leg / 64] >> (leg % 64)) & 1 == 1
}

/// The header and the `legs_len` legs of an index account's data.
pub fn split(data: &[u8]) -> Result<(&Index, &[Leg])> {
    require!(
        data.len() >= Index::HEADER,
        ErrorCode::AccountDidNotDeserialize
    );
    let (head, tail) = data.split_at(Index::HEADER);
    let header: &Index = bytemuck::try_from_bytes(&head[8..])
        .map_err(|_| error!(ErrorCode::AccountDidNotDeserialize))?;
    let end = header.legs_len as usize * Index::LEG;
    require!(tail.len() >= end, ErrorCode::AccountDidNotDeserialize);
    let legs: &[Leg] = bytemuck::try_cast_slice(&tail[..end])
        .map_err(|_| error!(ErrorCode::AccountDidNotDeserialize))?;
    Ok((header, legs))
}

/// The header and every leg slot the account has room for, the unused ones included.
pub fn split_mut(data: &mut [u8]) -> Result<(&mut Index, &mut [Leg])> {
    require!(
        data.len() >= Index::HEADER,
        ErrorCode::AccountDidNotDeserialize
    );
    let (head, tail) = data.split_at_mut(Index::HEADER);
    let header: &mut Index = bytemuck::try_from_bytes_mut(&mut head[8..])
        .map_err(|_| error!(ErrorCode::AccountDidNotDeserialize))?;
    let room = tail.len() / Index::LEG * Index::LEG;
    let legs: &mut [Leg] = bytemuck::try_cast_slice_mut(&mut tail[..room])
        .map_err(|_| error!(ErrorCode::AccountDidNotDeserialize))?;
    Ok((header, legs))
}

/// A holder's issue in progress: what each leg needs for `gross` shares, of which `shares` go to its recipient and the
/// rest to the fee's recipients, and what has been deposited.
#[account]
pub struct IssueTicket {
    pub index: Pubkey,
    pub owner: Pubkey,
    pub shares: u64,
    pub gross: u64,
    pub rebalance_nonce: u64,
    pub bump: u8,
    pub need: Vec<u64>,
    pub deposited: Vec<u64>,
}

impl IssueTicket {
    pub fn space(legs: usize) -> usize {
        8 + 32 + 32 + 8 + 8 + 8 + 1 + (4 + 8 * legs) + (4 + 8 * legs)
    }
}

/// What the index owes a holder who redeemed, leg by leg, until it is claimed.
#[account]
pub struct RedeemTicket {
    pub index: Pubkey,
    pub owner: Pubkey,
    pub bump: u8,
    pub owed: Vec<u64>,
}

impl RedeemTicket {
    pub fn space(legs: usize) -> usize {
        8 + 32 + 32 + 1 + (4 + 8 * legs)
    }
}

/// A leg as a creator names it.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub struct LegSpec {
    pub mint: Pubkey,
    pub units: u64,
    pub weight: u16,
}

/// One leg's price as a check recorded it: its value per raw unit in 1e36, in two words, and Pyth's publish time.
#[zero_copy]
#[derive(Debug, Default, PartialEq, Eq)]
pub struct PricedLeg {
    pub value_lo: u64,
    pub value_hi: u64,
    pub publish_time: i64,
}

impl PricedLeg {
    pub fn value(&self) -> u128 {
        self.value_lo as u128 | (self.value_hi as u128) << 64
    }

    pub fn set(&mut self, value: u128, publish_time: i64) {
        self.value_lo = value as u64;
        self.value_hi = (value >> 64) as u64;
        self.publish_time = publish_time;
    }
}

/// A creator's prices of the index it creates, for the seal's check on weights: a header, then one `PricedLeg` per leg.
#[account(zero_copy)]
#[derive(Debug)]
pub struct PriceSheet {
    pub index: Pubkey,
    pub legs: u16,
    pub bump: u8,
    pub _reserved: [u8; 5],
}

impl PriceSheet {
    pub const HEADER: usize = 8 + std::mem::size_of::<PriceSheet>();

    pub fn space(legs: usize) -> usize {
        Self::HEADER + legs * std::mem::size_of::<PricedLeg>()
    }
}

/// One leg of a fill: the units the executor names, what it deposited, what the commit settled (what the leg took in,
/// or gave out), and the leg's price.
#[zero_copy]
#[derive(Debug, Default, PartialEq, Eq)]
pub struct FillLeg {
    pub new_units: u64,
    pub deposited: u64,
    pub settled: u64,
    pub price: PricedLeg,
}

/// An executor's fill of one proposal, over several transactions: a header, then one `FillLeg` per leg. The header
/// keeps the sums the commit judges, each kept exact as the legs change: the units' weighted score, and what the legs
/// that move are worth at their recorded prices, coming in and going out.
#[account(zero_copy)]
#[derive(Debug)]
pub struct FillTicket {
    pub index: Pubkey,
    pub executor: Pubkey,
    pub proposal_id: u64,
    pub rebalance_nonce: u64,
    /// `Σ w · L(x)` over the legs, an `i128` in two words, low first.
    pub score: [u64; 2],
    /// What the growing legs are worth at their prices, and what the shrinking ones are, 256 bits each, low word first.
    pub value_in: [u64; 4],
    pub value_out: [u64; 4],
    pub legs: u16,
    pub committed: u8,
    pub bump: u8,
    pub _reserved: [u8; 4],
}

impl FillTicket {
    pub const HEADER: usize = 8 + std::mem::size_of::<FillTicket>();

    pub fn space(legs: usize) -> usize {
        Self::HEADER + legs * std::mem::size_of::<FillLeg>()
    }

    pub fn score(&self) -> i128 {
        (self.score[0] as u128 | (self.score[1] as u128) << 64) as i128
    }

    pub fn set_score(&mut self, score: i128) {
        let bits = score as u128;
        self.score = [bits as u64, (bits >> 64) as u64];
    }
}

/// A 256-bit number from four words, low first.
pub fn wide(words: &[u64; 4]) -> ethnum::U256 {
    let lo = words[0] as u128 | (words[1] as u128) << 64;
    let hi = words[2] as u128 | (words[3] as u128) << 64;
    ethnum::U256::from_words(hi, lo)
}

/// The four words of a 256-bit number, low first.
pub fn words(value: ethnum::U256) -> [u64; 4] {
    let (hi, lo) = value.into_words();
    [lo as u64, (lo >> 64) as u64, hi as u64, (hi >> 64) as u64]
}

/// The header and the legs of a fill ticket's data.
pub fn split_fill(data: &mut [u8]) -> Result<(&mut FillTicket, &mut [FillLeg])> {
    require!(
        data.len() >= FillTicket::HEADER,
        ErrorCode::AccountDidNotDeserialize
    );
    let (head, tail) = data.split_at_mut(FillTicket::HEADER);
    let header: &mut FillTicket = bytemuck::try_from_bytes_mut(&mut head[8..])
        .map_err(|_| error!(ErrorCode::AccountDidNotDeserialize))?;
    let end = header.legs as usize * std::mem::size_of::<FillLeg>();
    require!(tail.len() >= end, ErrorCode::AccountDidNotDeserialize);
    let legs: &mut [FillLeg] = bytemuck::try_cast_slice_mut(&mut tail[..end])
        .map_err(|_| error!(ErrorCode::AccountDidNotDeserialize))?;
    Ok((header, legs))
}

/// The header and the legs of a price sheet's data.
pub fn split_sheet(data: &mut [u8]) -> Result<(&mut PriceSheet, &mut [PricedLeg])> {
    require!(
        data.len() >= PriceSheet::HEADER,
        ErrorCode::AccountDidNotDeserialize
    );
    let (head, tail) = data.split_at_mut(PriceSheet::HEADER);
    let header: &mut PriceSheet = bytemuck::try_from_bytes_mut(&mut head[8..])
        .map_err(|_| error!(ErrorCode::AccountDidNotDeserialize))?;
    let end = header.legs as usize * std::mem::size_of::<PricedLeg>();
    require!(tail.len() >= end, ErrorCode::AccountDidNotDeserialize);
    let legs: &mut [PricedLeg] = bytemuck::try_cast_slice_mut(&mut tail[..end])
        .map_err(|_| error!(ErrorCode::AccountDidNotDeserialize))?;
    Ok((header, legs))
}

/// The prices the owner or the guardian posts with a start, one per leg, zero for a kept one, in any unit of its own:
/// written in ranges, then bound to the proposal the start opens, and never written again while it binds a live one.
#[account]
pub struct Quote {
    pub index: Pubkey,
    /// The proposal the quote binds; zero until a start binds it.
    pub proposal: u64,
    pub bump: u8,
    pub prices: Vec<u128>,
}

impl Quote {
    pub fn space(legs: usize) -> usize {
        8 + 32 + 8 + 1 + (4 + 16 * legs)
    }
}

/// A limit order: what its requester escrowed in its own escrow account, for at least `min_out` of what it wants,
/// until `deadline`, at the index's `rebalance_nonce` when it was made.
#[account]
#[derive(InitSpace)]
pub struct Request {
    pub requester: Pubkey,
    pub index: Pubkey,
    /// The requester's own number for it, in its address.
    pub id: u64,
    /// `requests::MINT_REQUEST` or `requests::REDEEM_REQUEST`.
    pub kind: u8,
    pub pay_mint: Pubkey,
    pub want_mint: Pubkey,
    /// The token program of `pay_mint`.
    pub pay_program: Pubkey,
    /// What the escrow received when the request was opened.
    pub escrowed: u64,
    pub min_out: u64,
    pub deadline: i64,
    pub rebalance_nonce: u64,
    pub bump: u8,
}

/// New weights the creator role proposed, applicable from `eta` for `PROPOSAL_WINDOW`; `eta` is zero when none are.
#[account]
pub struct PendingWeights {
    pub index: Pubkey,
    pub eta: i64,
    pub bump: u8,
    pub weights: Vec<u16>,
}

impl PendingWeights {
    pub fn space(legs: usize) -> usize {
        8 + 32 + 8 + 1 + (4 + 2 * legs)
    }
}
