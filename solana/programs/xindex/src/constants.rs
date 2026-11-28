// SPDX-License-Identifier: BUSL-1.1
//! The program's fixed numbers. Each mirrors the EVM factory's constant of the same name where one exists
//! (`src/WeightedIndexFactory.sol`), scaled to Solana's nine-decimal shares.

/// Seed of the one configuration account.
pub const CONFIG_SEED: &[u8] = b"config";
/// Seed of a mint's listing, `["listing", mint]`.
pub const LISTING_SEED: &[u8] = b"listing";
/// Seed of a wallet's approval to create, `["creator", wallet]`.
pub const CREATOR_SEED: &[u8] = b"creator";
/// Seed of an index, `["index", creator, terms_hash]`.
pub const INDEX_SEED: &[u8] = b"index";
/// Seed of an index's share mint, `["shares", index]`.
pub const SHARES_SEED: &[u8] = b"shares";
/// Seed of a holder's issue ticket, `["issue", index, owner]`.
pub const ISSUE_SEED: &[u8] = b"issue";
/// Seed of a holder's redeem ticket, `["redeem", index, owner]`.
pub const REDEEM_SEED: &[u8] = b"redeem";

/// A listing proposal waits this long before anyone may execute it, in seconds.
pub const LISTING_DELAY: i64 = 2 * 86_400;
/// A guardian change waits this long before anyone may execute it, in seconds.
pub const GUARDIAN_DELAY: i64 = 7 * 86_400;
/// After its delay, a proposal is executable for this long and then lapses, in seconds.
pub const PROPOSAL_WINDOW: i64 = 7 * 86_400;

/// Decimals of every index's shares.
pub const SHARE_DECIMALS: u8 = 9;
/// Raw shares in one whole share: a leg's units are its raw units per whole share.
pub const SHARE_UNIT: u128 = 1_000_000_000;

/// The fewest legs an index holds.
pub const MIN_COMPONENTS: usize = 2;
/// The most legs an index holds, the EVM factories' limit. Paths that touch every leg are split over transactions.
pub const MAX_COMPONENTS: usize = 200;
/// The weights of an index sum to this, in basis points.
pub const TOTAL_WEIGHT: u32 = 10_000;

/// The fewest raw units a leg starts with per whole share.
pub const MIN_RAW_UNITS: u64 = 10_000;
/// The most whole tokens a leg holds per whole share.
pub const MAX_WHOLE_TOKENS: u64 = 1_000_000_000;
/// The most raw units a leg holds per whole share, whatever its decimals.
pub const MAX_UNITS: u64 = 1_000_000_000_000_000_000;
/// The most decimals a listed mint may have, so `MAX_WHOLE_TOKENS` whole tokens fit `MAX_UNITS`.
pub const MAX_DECIMALS: u8 = 9;

/// The longest index name and symbol, in bytes.
pub const MAX_NAME_LEN: usize = 32;
pub const MAX_SYMBOL_LEN: usize = 10;

/// The domain the terms hash starts with, so no other hash of the same bytes names an index.
pub const TERMS_DOMAIN: &[u8] = b"xindex/solana/index/v1";
