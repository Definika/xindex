//! The speed limit, as `XindexVault`'s: a payout counts in its hour's bucket, and the current hour and the 24 before
//! it, with the payout, must stay within 4% of the index's balance before them, or the coin's outflow floor if that is
//! larger, so outflow in any 24 hours is at most 4% exactly. Each chain keeps the buckets (`BUCKETS` of them, each an
//! hour and an amount) in its own storage; these functions are their arithmetic.

use crate::constants::{BUCKETS, HOUR, SPEED_LIMIT_PERCENT};

/// The hour `now` (unix seconds) falls in.
pub fn hour_of(now: i64) -> u64 {
    (now / HOUR) as u64
}

/// The bucket an hour's payouts go to.
pub fn slot_of(hour: u64) -> usize {
    (hour % BUCKETS as u64) as usize
}

/// What the buckets, each `(hour, amount)`, hold of the current hour and the 24 before it: a stale slot reads empty.
pub fn recent(buckets: impl IntoIterator<Item = (u64, u64)>, now: i64) -> u64 {
    let hour = hour_of(now);
    buckets
        .into_iter()
        .filter(|(h, _)| h + BUCKETS as u64 > hour)
        .map(|(_, amount)| amount)
        .sum()
}

/// What more an index holding `balance` may pay out, `recent` having left recently: 4% of its balance before the recent
/// outflow, or `floor` if larger, less what already left.
pub fn available(balance: u64, recent: u64, floor: u64) -> u64 {
    let limit = ((balance as u128 + recent as u128) * SPEED_LIMIT_PERCENT / 100) as u64;
    limit.max(floor).saturating_sub(recent)
}

/// The bucket `(hour, amount)` of the slot `slot_of(hour_of(now))` after a payout of `amount` now: added to the hour's
/// amount if the slot holds this hour, else starting it.
pub fn record(bucket: (u64, u64), amount: u64, now: i64) -> (u64, u64) {
    let hour = hour_of(now);
    let (h, held) = bucket;
    (hour, if h == hour { held + amount } else { amount })
}

/// `recent`, for a chain whose amounts need 128 bits, as NEAR's yoctoNEAR do. The buckets hold at most what the vault
/// ever held, so their sum never overflows.
pub fn recent_wide(buckets: impl IntoIterator<Item = (u64, u128)>, now: i64) -> u128 {
    let hour = hour_of(now);
    buckets
        .into_iter()
        .filter(|(h, _)| h + BUCKETS as u64 > hour)
        .map(|(_, amount)| amount)
        .sum()
}

/// `available`, for a chain whose amounts need 128 bits. `balance + recent` is at most what the vault ever held, so 4% of
/// it never overflows for a coin whose supply fits `u128::MAX / 4`, NEAR's in yocto (about 1.2e33) included.
pub fn available_wide(balance: u128, recent: u128, floor: u128) -> u128 {
    let limit = (balance + recent) * SPEED_LIMIT_PERCENT / 100;
    limit.max(floor).saturating_sub(recent)
}

/// `record`, for a chain whose amounts need 128 bits.
pub fn record_wide(bucket: (u64, u128), amount: u128, now: i64) -> (u64, u128) {
    let hour = hour_of(now);
    let (h, held) = bucket;
    (hour, if h == hour { held + amount } else { amount })
}
