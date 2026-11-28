// SPDX-License-Identifier: BUSL-1.1
use anchor_lang::prelude::*;

use crate::constants::MAX_NAME_LEN;

/// The one configuration: who owns the program's listings and approvals, and who guards them.
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
    pub bump: u8,
}

/// A mint's listing. Its decimals are read when it is proposed, and bound the units an index may start with.
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
}

/// A wallet the owner approved to create indexes. The account's existence is the approval.
#[account]
#[derive(InitSpace)]
pub struct Creator {
    pub wallet: Pubkey,
    pub bump: u8,
}

/// One leg of an index: a listed mint, its fixed units per whole share and its weight, and what the vault holds for
/// others beside the backing of the shares. Stored after the index's header, `legs_len` of them.
#[zero_copy]
#[derive(Debug, PartialEq, Eq)]
pub struct Leg {
    pub mint: Pubkey,
    /// Raw units of the mint per whole share.
    pub units: u64,
    /// What open redeem tickets wait to claim of this leg.
    pub owed: u64,
    /// What open issue tickets have deposited of this leg.
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
    pub creator: Pubkey,
    pub terms_hash: [u8; 32],
    pub share_mint: Pubkey,
    /// Moves when a rebalance settles; an issue ticket finalizes only at the nonce it was opened at.
    pub rebalance_nonce: u64,
    /// The legs the index was begun with; `legs_len` reaches it before the index can be sealed.
    pub leg_count: u16,
    pub legs_len: u16,
    pub sealed: u8,
    pub bump: u8,
    pub shares_bump: u8,
    pub name_len: u8,
    pub name: [u8; MAX_NAME_LEN],
    pub symbol: [u8; 16],
    pub symbol_len: u8,
    pub _reserved: [u8; 7],
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

/// A holder's issue in progress: what each leg needs for `shares`, and what has been deposited.
#[account]
pub struct IssueTicket {
    pub index: Pubkey,
    pub owner: Pubkey,
    pub shares: u64,
    pub rebalance_nonce: u64,
    pub bump: u8,
    pub need: Vec<u64>,
    pub deposited: Vec<u64>,
}

impl IssueTicket {
    pub fn space(legs: usize) -> usize {
        8 + 32 + 32 + 8 + 8 + 1 + (4 + 8 * legs) + (4 + 8 * legs)
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
