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
/// Seed of a wallet's allowance to receive a gated index's new shares, `["minter", index, wallet]`.
pub const MINTER_SEED: &[u8] = b"minter";
/// Seed of a creator's price sheet for an index it creates, `["sheet", index]`.
pub const SHEET_SEED: &[u8] = b"sheet";
/// Seed of an executor's fill ticket, `["fill", index, executor]`.
pub const FILL_SEED: &[u8] = b"fill";
/// Seed of an index's quote, `["quote", index]`.
pub const QUOTE_SEED: &[u8] = b"quote";
/// Seed of an index's proposed weights, `["weights", index]`.
pub const WEIGHTS_SEED: &[u8] = b"weights";
/// Seed of a limit order, `["request", requester, id]`.
pub const REQUEST_SEED: &[u8] = b"request";

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
pub const TERMS_DOMAIN: &[u8] = b"xindex/solana/index/v2";

/// Basis points in one.
pub const BPS: u128 = 10_000;
/// A year, in seconds, for the streaming fee.
pub const YEAR: i64 = 365 * 86_400;
/// The streaming fee's scale before any fee: one, in 1e18.
pub const SCALE_ONE: u64 = 1_000_000_000_000_000_000;
/// The highest issue and redeem fee a creator may charge, in basis points.
pub const MAX_CREATOR_FEE_BPS: u16 = 100;
/// The highest issue and redeem fee the platform's policy may set.
pub const MAX_PLATFORM_FEE_BPS: u16 = 25;
/// The highest yearly streaming fee a creator may charge.
pub const MAX_CREATOR_STREAMING_BPS: u16 = 500;
/// The highest yearly streaming fee the platform's policy may set.
pub const MAX_PLATFORM_STREAMING_BPS: u16 = 100;

/// The notice a rebalance gives executors before its auction opens, in seconds.
pub const REBALANCE_DELAY: i64 = 2 * 3_600;
/// The auction's length, in seconds: the bar's twenty halvings (`settlement::AUCTION_DURATION`).
pub const AUCTION_DURATION: i64 = crate::settlement::AUCTION_DURATION as i64;
/// The shortest rebalance interval an index may choose, and what a fill under a keep mask restarts.
pub const MIN_REBALANCE_INTERVAL: i64 = 7 * 86_400;
/// The longest rebalance interval an index may choose.
pub const MAX_REBALANCE_INTERVAL: i64 = 91 * 86_400;
/// A change of weights waits this long before anyone may apply it.
pub const WEIGHTS_DELAY: i64 = 7 * 86_400;
/// The furthest a limit order's deadline may lie, in seconds.
pub const MAX_REQUEST_DURATION: i64 = 30 * 86_400;
/// The legs a keep mask can name: four words of 64 bits.
pub const MASK_WORDS: usize = 4;

/// The oldest price a fill's check reads, at the commit, in seconds.
pub const MAX_PRICE_AGE: i64 = 15;
/// The oldest price a creation's check reads, at the seal, in seconds.
pub const MAX_CREATION_PRICE_AGE: i64 = 60;
/// How long a mint's multiplier must have stood unchanged before a check reads it, in seconds.
pub const MIN_SVALUE_AGE: i64 = 20 * 60;
/// How far a leg's share of a new index's value may lie from its weight, relative to the weight, in 1e18: 5%.
pub const MAX_WEIGHT_DEVIATION: u128 = 50_000_000_000_000_000;
