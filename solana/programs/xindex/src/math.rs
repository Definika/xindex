// SPDX-License-Identifier: BUSL-1.1
//! The arithmetic that turns shares and units into amounts. Every rounding goes the holders' way: an issue's need rounds
//! up and a redeem's due rounds down.

use anchor_lang::prelude::*;

use crate::{
    constants::{MAX_UNITS, MAX_WHOLE_TOKENS, SHARE_UNIT, TERMS_DOMAIN},
    error::XindexError,
    state::{Leg, LegSpec},
};

/// `⌈shares · units / SHARE_UNIT⌉`: what an issue of `shares` needs of a leg.
pub fn amount_up(shares: u64, units: u64) -> Result<u64> {
    let need = (shares as u128 * units as u128).div_ceil(SHARE_UNIT);
    u64::try_from(need).map_err(|_| error!(XindexError::AmountTooLarge))
}

/// `⌊shares · units / SHARE_UNIT⌋`: what a redeem of `shares` is due of a leg.
pub fn amount_down(shares: u64, units: u64) -> Result<u64> {
    let due = shares as u128 * units as u128 / SHARE_UNIT;
    u64::try_from(due).map_err(|_| error!(XindexError::AmountTooLarge))
}

/// What the vault of `leg` must hold at least: the backing of `supply` shares, rounded down, plus what open tickets
/// hold there for others. The invariant.
pub fn required(supply: u64, leg: &Leg) -> u128 {
    supply as u128 * leg.units as u128 / SHARE_UNIT + leg.owed as u128 + leg.pending as u128
}

/// The most units a leg of `decimals` may start with per whole share.
pub fn max_units(decimals: u8) -> u64 {
    let whole = MAX_WHOLE_TOKENS as u128 * 10u128.pow(decimals as u32);
    whole.min(MAX_UNITS as u128) as u64
}

/// The hash an index's address commits to: its leg count, then every leg's mint, units and weight in order. A
/// creator's client computes it from the specs it will add.
pub fn terms_hash(leg_count: u16, legs: &[LegSpec]) -> [u8; 32] {
    hash_terms(
        leg_count,
        legs.iter().map(|leg| (&leg.mint, leg.units, leg.weight)),
        legs.len(),
    )
}

/// `terms_hash` of the legs an index holds, read in place so sealing two hundred legs builds one buffer on the heap.
pub fn terms_hash_of(leg_count: u16, legs: &[Leg]) -> [u8; 32] {
    hash_terms(
        leg_count,
        legs.iter().map(|leg| (&leg.mint, leg.units, leg.weight)),
        legs.len(),
    )
}

fn hash_terms<'a>(
    leg_count: u16,
    legs: impl Iterator<Item = (&'a Pubkey, u64, u16)>,
    len: usize,
) -> [u8; 32] {
    let mut bytes = Vec::with_capacity(TERMS_DOMAIN.len() + 2 + len * 42);
    bytes.extend_from_slice(TERMS_DOMAIN);
    bytes.extend_from_slice(&leg_count.to_le_bytes());
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

    #[test]
    fn rounding_goes_the_holders_way() {
        // one raw share of a leg of 1.5 raw units a raw share: an issue needs two, a redeem is due one
        assert_eq!(amount_up(1, 1_500_000_000).unwrap(), 2);
        assert_eq!(amount_down(1, 1_500_000_000).unwrap(), 1);
        assert_eq!(amount_up(2, 1_500_000_000).unwrap(), 3);
        assert_eq!(amount_down(2, 1_500_000_000).unwrap(), 3);
        assert_eq!(amount_up(0, MAX_UNITS).unwrap(), 0);
    }

    #[test]
    fn an_amount_beyond_a_token_amount_is_refused() {
        assert!(amount_up(u64::MAX, MAX_UNITS).is_err());
        assert!(amount_down(u64::MAX, MAX_UNITS).is_err());
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
        let base = terms_hash(2, &[a, b]);
        assert_ne!(base, terms_hash(3, &[a, b]), "count");
        assert_ne!(base, terms_hash(2, &[b, a]), "order");
        assert_ne!(
            base,
            terms_hash(2, &[LegSpec { units: 11, ..a }, b]),
            "units"
        );
        assert_ne!(
            base,
            terms_hash(2, &[LegSpec { weight: 4_999, ..a }, b]),
            "weight"
        );
        assert_ne!(
            base,
            terms_hash(
                2,
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
        assert_eq!(base, terms_hash(2, &[a, b]));
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
            terms_hash_of(2, &[held(a), held(b)]),
            "what an index holds hashes as its specs"
        );
    }
}
