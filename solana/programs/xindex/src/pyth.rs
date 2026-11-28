// SPDX-License-Identifier: BUSL-1.1
//! Pyth's prices on Solana, for the two checks that can only refuse: a fill's and a creation's (`docs/design/solana.md`,
//! section 8.2). Nothing else reads a price: no issue, redeem or claim.
//!
//! - A price is a `PriceUpdateV2` account of Pyth's receiver, read in place: owned by the receiver, fully verified by
//!   Wormhole's guardians, for the listing's feed. Anyone posts one, so the caller picks which signed price a check reads
//!   among those its age allows (HK-25).
//! - A value is one raw unit's worth in dollars times 1e36, the EVM reader's (`src/PythPrices.sol`): the price moved by
//!   its confidence against the executor, times ten to its exponent plus 36, times whole priced assets per raw unit.
//! - A `Multiplier` feed prices a whole share, and the mint's scaled-UI multiplier says how many shares a whole token
//!   is: Ondo's sValue, carried by the mint itself. Only a settled multiplier counts: none scheduled, and the last
//!   change at least `MIN_SVALUE_AGE` old.

use anchor_lang::prelude::*;
use anchor_spl::token_2022::spl_token_2022::{
    extension::{
        scaled_ui_amount::ScaledUiAmountConfig, BaseStateWithExtensions, StateWithExtensions,
    },
    state::Mint as MintState,
};
use ethnum::U256;

use crate::{
    constants::*,
    error::XindexError,
    settlement::mul_div,
    state::{Leg, Listing},
};

/// Pyth's receiver program on Solana, the owner of every `PriceUpdateV2` account.
pub const RECEIVER: Pubkey = pubkey!("rec5EKMGg6MxZYaMdyBfgwp4d5rB9T1VQH5pJv5LtFJ");
/// The first eight bytes of `sha256("account:PriceUpdateV2")`.
pub const PRICE_UPDATE_DISCRIMINATOR: [u8; 8] = [34, 241, 35, 99, 157, 126, 244, 205];
/// The byte that marks a price verified by every guardian signature Wormhole requires.
const FULL: u8 = 1;

/// No feed: a leg without one stops a fill that moves it, and a creation that holds it.
pub const FEED_NONE: u8 = 0;
/// The feed prices one whole token.
pub const FEED_TOKEN: u8 = 1;
/// The feed prices one whole share, and the mint's settled multiplier says how many shares a whole token is.
pub const FEED_MULTIPLIER: u8 = 2;

/// The decimal digits of a value's scale, 1e36.
const SCALE_DIGITS: i32 = 36;
/// The most digits a value's price may carry: an exponent of up to 18 above the scale's 36.
const MAX_DIGITS: i32 = 54;

/// The fields of a `PriceUpdateV2` a check reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PythPrice {
    pub feed_id: [u8; 32],
    pub price: i64,
    pub conf: u64,
    pub expo: i32,
    pub publish_time: i64,
}

/// Reads `account` as Pyth's price for `feed_id`. Its layout: the discriminator, the write authority, the verification
/// level (one byte for `Full`; `Partial` carries a second and is refused), then the price message.
pub fn read_price(account: &AccountInfo, feed_id: &[u8; 32]) -> Result<PythPrice> {
    require_keys_eq!(*account.owner, RECEIVER, XindexError::NotAPythPrice);
    let data = account.try_borrow_data()?;
    require!(
        data.len() >= 8 + 32 + 1 + 32 + 8 + 8 + 4 + 8 && data[..8] == PRICE_UPDATE_DISCRIMINATOR,
        XindexError::NotAPythPrice
    );
    require!(data[40] == FULL, XindexError::PriceNotVerified);
    let at = |from: usize, len: usize| &data[41 + from..41 + from + len];
    let price = PythPrice {
        feed_id: at(0, 32).try_into().unwrap(),
        price: i64::from_le_bytes(at(32, 8).try_into().unwrap()),
        conf: u64::from_le_bytes(at(40, 8).try_into().unwrap()),
        expo: i32::from_le_bytes(at(48, 4).try_into().unwrap()),
        publish_time: i64::from_le_bytes(at(52, 8).try_into().unwrap()),
    };
    require!(price.feed_id == *feed_id, XindexError::WrongPriceFeed);
    Ok(price)
}

/// The multiplier of `mint` at `now`, in 1e18, if it is settled: rounded up for a leg that leaves and down for one that
/// arrives, so its rounding goes against the executor. Refused while a change is scheduled and until `MIN_SVALUE_AGE`
/// after the last one took effect (`MultiplierUnsettled`); a mint without the extension, or a multiplier that is not a
/// positive finite number, values nothing (`UnusablePrice`).
pub fn settled_multiplier(mint: &AccountInfo, now: i64, up: bool) -> Result<u128> {
    require_keys_eq!(
        *mint.owner,
        anchor_spl::token_2022::ID,
        XindexError::UnusablePrice
    );
    let data = mint.try_borrow_data()?;
    let state = StateWithExtensions::<MintState>::unpack(&data)
        .map_err(|_| error!(XindexError::UnusablePrice))?;
    let config = state
        .get_extension::<ScaledUiAmountConfig>()
        .map_err(|_| error!(XindexError::UnusablePrice))?;
    let changed: i64 = config.new_multiplier_effective_timestamp.into();
    require!(
        now >= changed.saturating_add(MIN_SVALUE_AGE),
        XindexError::MultiplierUnsettled
    );
    // past the change, the mint's own rule is that the new multiplier holds
    wad_of(f64::from(config.new_multiplier), up).ok_or_else(|| error!(XindexError::UnusablePrice))
}

/// `x` in 1e18, exact from its mantissa and exponent, rounded down or up. None for a value that is not positive and
/// finite, or that reaches 2^127 in 1e18.
pub fn wad_of(x: f64, up: bool) -> Option<u128> {
    if !x.is_finite() || x <= 0.0 {
        return None;
    }
    let bits = x.to_bits();
    let exponent = ((bits >> 52) & 0x7ff) as i32;
    let fraction = (bits & ((1u64 << 52) - 1)) as u128;
    let (mantissa, power) = if exponent == 0 {
        (fraction, -1074)
    } else {
        (fraction | (1u128 << 52), exponent - 1075)
    };
    let scaled = U256::from(mantissa) * U256::from(crate::settlement::WAD);
    let wad = if power >= 0 {
        if power > 70 {
            return None;
        }
        scaled << power as u32
    } else {
        let shift = (-power) as u32;
        if shift >= 256 {
            U256::from(up as u8)
        } else {
            let q = scaled >> shift;
            let exact = q << shift == scaled;
            q + U256::from((up && !exact) as u8)
        }
    };
    (wad < U256::ONE << 127).then(|| wad.as_u128())
}

/// One raw unit of a leg of `decimals` at `price`, leaning against the executor: up for a leg that leaves, down for one
/// that arrives. `multiplier` is the mint's settled multiplier in 1e18 for a `Multiplier` feed, and None for a `Token`
/// feed. A value of nothing, or past `u128`, is no price (`UnusablePrice`).
pub fn value(
    price: &PythPrice,
    decimals: u8,
    multiplier: Option<u128>,
    leaving: bool,
) -> Result<u128> {
    let digits = SCALE_DIGITS + price.expo;
    require!(
        price.price > 0 && (0..=MAX_DIGITS).contains(&digits),
        XindexError::UnusablePrice
    );
    let raw = price.price as u64;
    require!(raw > price.conf, XindexError::UnusablePrice);
    let edge = if leaving {
        raw as u128 + price.conf as u128
    } else {
        (raw - price.conf) as u128
    };
    let one = 10u128.pow(decimals as u32);
    let (assets, per_raw) = match multiplier {
        None => (1, one),
        Some(m) => (m, crate::settlement::WAD * one),
    };
    let scaled = U256::from(edge) * U256::from(10u8).pow(digits as u32);
    let worth = mul_div(scaled, assets, per_raw, leaving)
        .ok_or_else(|| error!(XindexError::UnusablePrice))?;
    require!(
        worth != U256::ZERO && worth <= U256::from(u128::MAX),
        XindexError::UnusablePrice
    );
    Ok(worth.as_u128())
}

/// Prices `leg` from the accounts at `accounts[*at..]`, moving `at` past them: the mint's listing, then Pyth's price
/// for its feed, then, for a `Multiplier` feed, the mint itself. Returns the value of one raw unit, leaning as `leaving`
/// says, and the price's publish time. The listing's feed is read at each check, so a feed set later reaches every
/// index, as the EVM factory's record does.
pub fn price_leg<'info>(
    accounts: &'info [AccountInfo<'info>],
    at: &mut usize,
    leg: &Leg,
    leaving: bool,
    now: i64,
) -> Result<(u128, i64)> {
    let mut next = || {
        let account = accounts
            .get(*at)
            .ok_or_else(|| error!(XindexError::ListingMismatch))?;
        *at += 1;
        Ok::<&AccountInfo<'info>, Error>(account)
    };
    let listing_info = next()?;
    let listing: Account<Listing> =
        Account::try_from(listing_info).map_err(|_| error!(XindexError::ListingMismatch))?;
    let expected = Pubkey::create_program_address(
        &[LISTING_SEED, leg.mint.as_ref(), &[listing.bump]],
        &crate::ID,
    )
    .map_err(|_| error!(XindexError::ListingMismatch))?;
    require_keys_eq!(listing_info.key(), expected, XindexError::ListingMismatch);
    require!(listing.feed_kind != FEED_NONE, XindexError::NoPriceFeed);
    let price = read_price(next()?, &listing.feed_id)?;
    let multiplier = if listing.feed_kind == FEED_MULTIPLIER {
        let mint = next()?;
        require_keys_eq!(mint.key(), leg.mint, XindexError::WrongLegAccount);
        Some(settled_multiplier(mint, now, leaving)?)
    } else {
        None
    };
    Ok((
        value(&price, leg.decimals, multiplier, leaving)?,
        price.publish_time,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(price: i64, conf: u64, expo: i32) -> PythPrice {
        PythPrice {
            feed_id: [0; 32],
            price,
            conf,
            expo,
            publish_time: 0,
        }
    }

    #[test]
    fn a_value_leans_against_the_executor() {
        // $70.24 with a confidence of $0.02, eight decimals: a whole token of nine decimals
        let p = at(7_024_000_000, 2_000_000, -8);
        let leaving = value(&p, 9, None, true).unwrap();
        let arriving = value(&p, 9, None, false).unwrap();
        assert_eq!(leaving, 70_260_000_000_000_000_000_000_000_000);
        assert_eq!(arriving, 70_220_000_000_000_000_000_000_000_000);
        // a share price times a multiplier of 1.5
        let one_and_a_half = wad_of(1.5, false).unwrap();
        assert_eq!(one_and_a_half, 1_500_000_000_000_000_000);
        assert_eq!(
            value(&p, 9, Some(one_and_a_half), false).unwrap(),
            arriving * 3 / 2
        );
    }

    #[test]
    fn a_price_a_check_cannot_use_is_refused() {
        assert!(value(&at(0, 0, -8), 9, None, true).is_err());
        assert!(value(&at(-1, 0, -8), 9, None, true).is_err());
        assert!(
            value(&at(100, 100, -8), 9, None, false).is_err(),
            "price at its confidence"
        );
        assert!(
            value(&at(100, 0, -37), 0, None, true).is_err(),
            "too small an exponent"
        );
        assert!(
            value(&at(100, 0, 19), 0, None, true).is_err(),
            "too large an exponent"
        );
        assert!(
            value(&at(1, 0, -36), 9, None, false).is_err(),
            "a value of nothing"
        );
        assert!(
            value(&at(i64::MAX, 0, 18), 0, None, true).is_err(),
            "past u128"
        );
    }

    #[test]
    fn a_multiplier_is_read_exactly_and_rounded_against_the_executor() {
        assert_eq!(wad_of(1.0, false), Some(1_000_000_000_000_000_000));
        assert_eq!(wad_of(10.0, true), Some(10_000_000_000_000_000_000));
        // 1.0017152487959897 is not a binary fraction of eighteen decimals: up and down differ by one
        let m = 1.0017152487959897_f64;
        assert_eq!(wad_of(m, true).unwrap(), wad_of(m, false).unwrap() + 1);
        assert_eq!(wad_of(0.0, true), None);
        assert_eq!(wad_of(-1.0, true), None);
        assert_eq!(wad_of(f64::NAN, true), None);
        assert_eq!(wad_of(f64::INFINITY, true), None);
        assert_eq!(wad_of(1e30, true), None);
        assert_eq!(wad_of(f64::MIN_POSITIVE / 4.0, true), Some(1));
        assert_eq!(wad_of(f64::MIN_POSITIVE / 4.0, false), Some(0));
    }
}
