// SPDX-License-Identifier: BUSL-1.1
//! The arithmetic that turns shares, units and the streaming fee's scale into amounts and fee shares. Every rounding
//! goes the holders' way: an issue's need rounds up, a redeem's due rounds down, and a fee's shares round down.

use crate::{
    constants::*,
    error::XindexError,
    settlement::WAD,
    state::{IndexTerms, Leg, LegSpec},
};
use anchor_lang::prelude::*;

/// The amount of a leg that backs `shares` at `units` per whole share and `scale`: `shares · units · scale /
/// (SHARE_UNIT · 1e18)`, rounded down or up. The one place shares and units become an amount.
pub fn backing(shares: u64, units: u64, scale: u64, up: bool) -> Result<u64> {
    let amount = backing_wide(shares, units, scale, up)
        .ok_or_else(|| error!(XindexError::AmountTooLarge))?;
    u64::try_from(amount).map_err(|_| error!(XindexError::AmountTooLarge))
}

/// `backing` in 128-bit words, exact: the product `shares · units` fits 128 bits, and dividing it by 1e18 after the
/// scale and by `SHARE_UNIT` after that rounds as dividing by their product does, since `⌊⌊x / m⌋ / n⌋ = ⌊x / mn⌋`
/// and `⌈⌈x / m⌉ / n⌉ = ⌈x / mn⌉` for positive integers. None past 128 bits.
pub fn backing_wide(shares: u64, units: u64, scale: u64, up: bool) -> Option<u128> {
    let product = shares as u128 * units as u128;
    // ⌊product · scale / 1e18⌋, with the product split by 1e18 so no step passes 128 bits
    let (q, r) = (product / WAD, product % WAD);
    let rs = r * scale as u128;
    let mut scaled = q.checked_mul(scale as u128)?.checked_add(rs / WAD)?;
    if up && !rs.is_multiple_of(WAD) {
        scaled += 1;
    }
    Some(if up {
        scaled.div_ceil(SHARE_UNIT)
    } else {
        scaled / SHARE_UNIT
    })
}

/// What the vault of `leg` must hold at least: the backing of `supply` shares at `scale`, rounded down, plus what open
/// tickets hold there for others. The invariant.
pub fn required(supply: u64, leg: &Leg, scale: u64) -> u128 {
    backing_wide(supply, leg.units, scale, false).expect("a supply and units of their widths fit")
        + leg.owed as u128
        + leg.pending as u128
}

/// The shares an issue of `shares` must back: `shares` plus the fee's, `⌈shares · 10,000 / (10,000 − fee)⌉`.
pub fn gross_shares(shares: u64, fee_bps: u16) -> Result<u64> {
    if fee_bps == 0 {
        return Ok(shares);
    }
    let gross = (shares as u128 * BPS).div_ceil(BPS - fee_bps as u128);
    u64::try_from(gross).map_err(|_| error!(XindexError::AmountTooLarge))
}

/// The fee's shares on a redeem of `shares`, rounded down: minted to the recipients out of the burn.
pub fn redeem_fee_shares(shares: u64, fee_bps: u16) -> u64 {
    (shares as u128 * fee_bps as u128 / BPS) as u64
}

/// `part`'s share of `fee_shares` against `other`, rounded down; nothing when both rates are zero.
pub fn part_of(fee_shares: u64, part: u16, other: u16) -> u64 {
    let total = part as u128 + other as u128;
    if total == 0 {
        return 0;
    }
    (fee_shares as u128 * part as u128 / total) as u64
}

/// The scale and the streaming fee's shares an accrual at `now` would produce, both rounded down: `f` is `rate` times
/// the time since `last`, as a part of a year; the recipients are minted `supply · f / (1 − f)` shares and every share's
/// units shrink to `supply / (supply + minted)` of what they were. A gap long enough for `f` to reach one is capped
/// just under it, and a fee that would shrink the scale to zero, or take the supply past a token amount, is not
/// charged.
pub fn pending_accrual(rate_bps: u16, scale: u64, supply: u64, last: i64, now: i64) -> (u64, u64) {
    let owed = rate_bps as u128 * now.saturating_sub(last).max(0) as u128;
    let year = YEAR as u128 * BPS;
    if supply == 0 || owed == 0 {
        return (scale, 0);
    }
    let owed = owed.min(year - 1);
    let fee = supply as u128 * owed / (year - owed);
    let next = scale as u128 * supply as u128 / (supply as u128 + fee);
    let Ok(fee) = u64::try_from(fee) else {
        return (scale, 0);
    };
    if next == 0 || supply.checked_add(fee).is_none() {
        return (scale, 0);
    }
    (next as u64, fee)
}

/// The most units a leg of `decimals` may start with per whole share.
pub fn max_units(decimals: u8) -> u64 {
    let whole = MAX_WHOLE_TOKENS as u128 * 10u128.pow(decimals as u32);
    whole.min(MAX_UNITS as u128) as u64
}

/// The hash an index's address commits to: its leg count, its terms, then every leg's mint, units and weight in order.
/// A creator's client computes it from the terms and specs it will add.
pub fn terms_hash(leg_count: u16, terms: &IndexTerms, legs: &[LegSpec]) -> [u8; 32] {
    hash_terms(
        leg_count,
        terms,
        legs.iter().map(|leg| (&leg.mint, leg.units, leg.weight)),
        legs.len(),
    )
}

/// `terms_hash` of the legs an index holds, read in place so sealing two hundred legs builds one buffer on the heap.
pub fn terms_hash_of(leg_count: u16, terms: &IndexTerms, legs: &[Leg]) -> [u8; 32] {
    hash_terms(
        leg_count,
        terms,
        legs.iter().map(|leg| (&leg.mint, leg.units, leg.weight)),
        legs.len(),
    )
}

fn hash_terms<'a>(
    leg_count: u16,
    terms: &IndexTerms,
    legs: impl Iterator<Item = (&'a Pubkey, u64, u16)>,
    len: usize,
) -> [u8; 32] {
    let mut bytes = Vec::with_capacity(TERMS_DOMAIN.len() + 2 + 18 + len * 42);
    bytes.extend_from_slice(TERMS_DOMAIN);
    bytes.extend_from_slice(&leg_count.to_le_bytes());
    for rate in [
        terms.creator_fee_bps,
        terms.platform_fee_bps,
        terms.referral_share_bps,
        terms.creator_streaming_bps,
        terms.platform_streaming_bps,
    ] {
        bytes.extend_from_slice(&rate.to_le_bytes());
    }
    bytes.extend_from_slice(&terms.rebalance_interval.to_le_bytes());
    for (mint, units, weight) in legs {
        bytes.extend_from_slice(mint.as_ref());
        bytes.extend_from_slice(&units.to_le_bytes());
        bytes.extend_from_slice(&weight.to_le_bytes());
    }
    solana_sha256_hasher::hashv(&[&bytes]).to_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    const ONE: u64 = SCALE_ONE;

    #[test]
    fn rounding_goes_the_holders_way() {
        // one raw share of a leg of 1.5 raw units a raw share: an issue needs two, a redeem is due one
        assert_eq!(backing(1, 1_500_000_000, ONE, true).unwrap(), 2);
        assert_eq!(backing(1, 1_500_000_000, ONE, false).unwrap(), 1);
        assert_eq!(backing(2, 1_500_000_000, ONE, true).unwrap(), 3);
        assert_eq!(backing(2, 1_500_000_000, ONE, false).unwrap(), 3);
        assert_eq!(backing(0, MAX_UNITS, ONE, true).unwrap(), 0);
        // at half the scale a share backs half
        assert_eq!(
            backing(SHARE_UNIT as u64, 1_000, ONE / 2, false).unwrap(),
            500
        );
        assert_eq!(backing(1, 1_000_000_001, ONE / 2, true).unwrap(), 1);
    }

    #[test]
    fn the_narrow_backing_is_the_wide_arithmetics_to_the_unit() {
        use crate::settlement::mul_div;
        use ethnum::U256;
        // a few thousand points across the widths, from a fixed linear congruential sequence
        let mut seed: u64 = 20_261_128;
        let mut next = || {
            seed = seed
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            seed
        };
        for k in 0..4_000 {
            let shares = next() >> (next() % 64);
            let units = (next() >> (next() % 64)).min(MAX_UNITS * 2);
            let scale = if k % 3 == 0 { ONE } else { next() % ONE + 1 };
            for up in [false, true] {
                let wide = mul_div(
                    U256::from(shares) * U256::from(units),
                    scale as u128,
                    SHARE_UNIT * WAD,
                    up,
                )
                .unwrap();
                assert_eq!(
                    backing_wide(shares, units, scale, up).map(U256::from),
                    Some(wide),
                    "{shares} · {units} · {scale}, up {up}"
                );
            }
        }
    }

    #[test]
    fn an_amount_beyond_a_token_amount_is_refused() {
        assert!(backing(u64::MAX, MAX_UNITS, ONE, true).is_err());
        assert!(backing(u64::MAX, MAX_UNITS, ONE, false).is_err());
        assert!(gross_shares(u64::MAX, 125).is_err());
    }

    #[test]
    fn fees_round_against_the_payer_and_split_by_rate() {
        assert_eq!(gross_shares(1_000, 0).unwrap(), 1_000);
        // 1,000 net at 1% backs ⌈1,000 · 10,000 / 9,900⌉ = 1,011
        assert_eq!(gross_shares(1_000, 100).unwrap(), 1_011);
        assert_eq!(redeem_fee_shares(1_000, 125), 12);
        assert_eq!(redeem_fee_shares(79, 125), 0);
        assert_eq!(part_of(100, 25, 75), 25);
        assert_eq!(part_of(99, 25, 75), 24);
        assert_eq!(part_of(99, 0, 0), 0);
    }

    #[test]
    fn the_streaming_fee_mints_its_part_and_shrinks_the_scale() {
        // 1% a year on 1e12 shares for a year: f = 0.01, minted 1e12 · 0.01 / 0.99
        let (scale, fee) = pending_accrual(100, ONE, 1_000_000_000_000, 0, YEAR);
        assert_eq!(fee, 10_101_010_101);
        assert_eq!(
            scale,
            (ONE as u128 * 1_000_000_000_000 / (1_000_000_000_000 + 10_101_010_101)) as u64
        );
        assert_eq!(pending_accrual(0, ONE, 1, 0, YEAR), (ONE, 0));
        assert_eq!(pending_accrual(100, ONE, 0, 0, YEAR), (ONE, 0));
        assert_eq!(pending_accrual(100, ONE, 5, 10, 10), (ONE, 0));
        // a gap of centuries is capped just under f = 1 and still answers
        let (scale, fee) = pending_accrual(600, ONE, 1_000, 0, YEAR * 1_000);
        assert!(scale > 0 && fee > 0);
        // and a fee past what a supply of shares can hold is not charged, so the last holder can still leave
        assert_eq!(
            pending_accrual(600, ONE, 1_000_000_000, 0, YEAR * 1_000),
            (ONE, 0)
        );
    }

    #[test]
    fn units_are_bounded_by_whole_tokens_and_by_the_cap() {
        assert_eq!(max_units(0), 1_000_000_000);
        assert_eq!(max_units(6), 1_000_000_000_000_000);
        assert_eq!(max_units(9), MAX_UNITS);
    }

    #[test]
    fn the_terms_hash_moves_with_every_field() {
        let a = LegSpec {
            mint: Pubkey::new_from_array([1; 32]),
            units: 10,
            weight: 5_000,
        };
        let b = LegSpec {
            mint: Pubkey::new_from_array([2; 32]),
            units: 20,
            weight: 5_000,
        };
        let t = IndexTerms {
            creator_fee_bps: 10,
            platform_fee_bps: 5,
            referral_share_bps: 2_000,
            creator_streaming_bps: 50,
            platform_streaming_bps: 25,
            rebalance_interval: 7 * 86_400,
        };
        let base = terms_hash(2, &t, &[a, b]);
        assert_ne!(base, terms_hash(3, &t, &[a, b]), "count");
        assert_ne!(base, terms_hash(2, &t, &[b, a]), "order");
        assert_ne!(
            base,
            terms_hash(2, &t, &[LegSpec { units: 11, ..a }, b]),
            "units"
        );
        assert_ne!(
            base,
            terms_hash(2, &t, &[LegSpec { weight: 4_999, ..a }, b]),
            "weight"
        );
        assert_ne!(
            base,
            terms_hash(
                2,
                &t,
                &[
                    LegSpec {
                        mint: Pubkey::new_from_array([3; 32]),
                        ..a
                    },
                    b
                ]
            ),
            "mint"
        );
        for (field, other) in [
            (
                "creator fee",
                IndexTerms {
                    creator_fee_bps: 11,
                    ..t
                },
            ),
            (
                "platform fee",
                IndexTerms {
                    platform_fee_bps: 6,
                    ..t
                },
            ),
            (
                "referral share",
                IndexTerms {
                    referral_share_bps: 2_001,
                    ..t
                },
            ),
            (
                "creator streaming",
                IndexTerms {
                    creator_streaming_bps: 51,
                    ..t
                },
            ),
            (
                "platform streaming",
                IndexTerms {
                    platform_streaming_bps: 26,
                    ..t
                },
            ),
            (
                "interval",
                IndexTerms {
                    rebalance_interval: 14 * 86_400,
                    ..t
                },
            ),
        ] {
            assert_ne!(base, terms_hash(2, &other, &[a, b]), "{field}");
        }
        assert_eq!(base, terms_hash(2, &t, &[a, b]));
        let held = |spec: LegSpec| Leg {
            mint: spec.mint,
            units: spec.units,
            owed: 7,
            pending: 9,
            weight: spec.weight,
            token_2022: 1,
            decimals: 9,
            _reserved: [0; 4],
        };
        assert_eq!(
            base,
            terms_hash_of(2, &t, &[held(a), held(b)]),
            "what an index holds hashes as its specs"
        );
    }
}
