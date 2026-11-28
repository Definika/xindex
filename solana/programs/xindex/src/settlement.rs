// SPDX-License-Identifier: BUSL-1.1
//! The settlement arithmetic of a rebalance: the EVM's `src/WeightedMath.sol`, rule for rule, replayed against the
//! exact model's vectors (`test/vectors/settlement.json`, by `tests/vectors.rs`). Pure: it reads no account and no
//! price; the two value checks take the prices they are given and can only refuse a fill the gain accepted.
//!
//! - The executor names the new units. This only checks them: each leg inside its unit caps, and the weighted gain
//!   `⌊Σ w_i · L(x_i) / 10,000⌋` at or above the auction's bar, `x_i` the leg's relative change in units rounded down
//!   and `L(x) = x − x²/2 + x³/3 − 3x⁴/10` rounded down, a lower bound of `ln(1 + x)` on `[−0.2, 1]`.
//! - Every rounding goes against the executor: a leg's change and its score round down, the bar and the lower cap
//!   round up, an amount rounds down when it leaves and up when it comes back.
//! - The share unit and the largest units are parameters: the EVM's are 1e18 and 2^96 − 1, which the vectors use, and
//!   the program's `SHARE_UNIT` and `u64::MAX`.

use ethnum::{I256, U256};

/// One, in the arithmetic's 18-decimal fixed point.
pub const WAD: u128 = 1_000_000_000_000_000_000;
/// A fill leaves a leg with at least `1 − MAX_TURNOVER` of its own units.
pub const MAX_TURNOVER: u128 = 200_000_000_000_000_000;
/// And with at most `1 + MAX_GROWTH` of them.
pub const MAX_GROWTH: u128 = WAD;
/// The bar at the auction's first second: a half.
pub const BAR_MAX: u128 = 500_000_000_000_000_000;
/// Seconds in which the bar halves.
pub const BAR_HALF_LIFE: u64 = 720;
/// The auction's length, twenty halvings.
pub const AUCTION_DURATION: u64 = 14_400;
/// What a fill may fall short of at Pyth's prices at the auction's last second: 2%.
pub const MAX_ORACLE_TOLERANCE: u128 = 20_000_000_000_000_000;
/// The weights of an index sum to this.
pub const TOTAL_WEIGHT: i128 = 10_000;

/// Why a settlement is refused, in the order the checks run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// Past the auction's end.
    AuctionOver,
    /// New units for another count of legs.
    LengthMismatch,
    /// A supply under one whole share.
    NothingToRebalance,
    /// The first leg outside its caps.
    LegOutOfBounds {
        leg: usize,
        next: U256,
        lowest: U256,
        highest: U256,
    },
    /// The first leg above the largest units.
    UnitsOverflow { next: U256 },
    /// A gain under the bar.
    GainBelowBar { gain: i128, bar: u128 },
}

/// One leg of a fill: its units now, the units named, its weight, and whether the proposal keeps it. Units are 256
/// bits wide here, as the EVM's arguments are; the program's are `u64`.
#[derive(Clone, Copy, Debug)]
pub struct LegMove {
    pub current: U256,
    pub next: U256,
    pub weight: u16,
    pub kept: bool,
}

/// A settlement the arithmetic accepts.
#[derive(Debug, PartialEq, Eq)]
pub struct Settled {
    pub bar: u128,
    pub gain: i128,
    pub amounts_out: Vec<U256>,
    pub amounts_in: Vec<U256>,
}

/// The bar `elapsed` seconds into the auction: `BAR_MAX` halved once per `BAR_HALF_LIFE`, a straight line within each
/// half-life, rounded up once, so it never reaches zero. None past the auction's end.
pub fn bar_at(elapsed: u64) -> Option<u128> {
    if elapsed > AUCTION_DURATION {
        return None;
    }
    let halvings = elapsed / BAR_HALF_LIFE;
    let into = (elapsed % BAR_HALF_LIFE) as u128;
    let span = 2 * BAR_HALF_LIFE as u128;
    Some((BAR_MAX * (span - into)).div_ceil(span << halvings))
}

/// The tolerance Pyth's check allows `elapsed` seconds into the auction, rising from nothing to
/// `MAX_ORACLE_TOLERANCE`, rounded down. None past the auction's end.
pub fn oracle_tolerance_at(elapsed: u64) -> Option<u128> {
    if elapsed > AUCTION_DURATION {
        return None;
    }
    Some(MAX_ORACLE_TOLERANCE * elapsed as u128 / AUCTION_DURATION as u128)
}

/// The least and most units a fill may leave a leg with: its own units if kept, else what `MAX_TURNOVER` leaves,
/// rounded up, and what `MAX_GROWTH` adds, rounded down.
pub fn bounds(current: U256, kept: bool) -> (U256, U256) {
    if kept {
        return (current, current);
    }
    let lowest =
        mul_div(current, WAD - MAX_TURNOVER, WAD, true).expect("a quotient below the dividend");
    let growth = mul_div(current, MAX_GROWTH, WAD, false).expect("a quotient below the dividend");
    (lowest, current + growth)
}

/// The fill's weighted gain after checking every leg's caps and its largest units, the first failure refused:
/// `⌊Σ leg_score / TOTAL_WEIGHT⌋`.
pub fn gain(legs: impl Iterator<Item = LegMove>, max_units: U256) -> Result<i128, Refusal> {
    let mut total: i128 = 0;
    for (leg, m) in legs.enumerate() {
        // a weight is at most 1e4 and a score under 1e18 in size: two hundred legs fit an i128 with room to spare
        total += leg_score(leg, m, max_units)?;
    }
    Ok(floor_div(total, TOTAL_WEIGHT))
}

/// Leg `leg`'s weighted score, `w · L(x)`, after checking it is inside its caps and its largest units. The program
/// records it per leg as the executor names the units, and sums the records at the commit.
pub fn leg_score(leg: usize, m: LegMove, max_units: U256) -> Result<i128, Refusal> {
    let (lowest, highest) = bounds(m.current, m.kept);
    if m.next < lowest || m.next > highest {
        return Err(Refusal::LegOutOfBounds {
            leg,
            next: m.next,
            lowest,
            highest,
        });
    }
    if m.next > max_units {
        return Err(Refusal::UnitsOverflow { next: m.next });
    }
    if m.next == m.current {
        return Ok(0);
    }
    Ok(m.weight as i128 * score(change(m.current, m.next)))
}

/// What a leg moving from `current` to `next` units is worth at `price`, and whether it leaves: the term the value
/// checks sum. Nothing for a leg that does not move.
pub fn leg_value(current: U256, next: U256, price: u128) -> (U256, bool) {
    let leaving = next < current;
    let delta = if leaving {
        current - next
    } else {
        next - current
    };
    (
        delta
            .checked_mul(U256::from(price))
            .expect("a value of its width"),
        leaving,
    )
}

/// The floor of `value_out` less `tolerance`, rounded up: `value_out − ⌊value_out · tolerance⌋`.
pub fn floor_of(value_out: U256, tolerance: u128) -> U256 {
    value_out - mul_div(value_out, tolerance, WAD, false).expect("a tolerance under one")
}

/// A leg's relative change in units at 1e18, `(next − current) / current`, rounded down, so a loss counts in full and
/// a gain never counts for more than it is. Within the caps it lies in `[−MAX_TURNOVER, MAX_GROWTH]`.
pub fn change(current: U256, next: U256) -> i128 {
    let wad = U256::from(WAD);
    if next >= current {
        ((next - current) * wad / current).as_i128()
    } else {
        let loss = (current - next) * wad;
        let up = loss / current + U256::from((loss % current != U256::ZERO) as u8);
        -up.as_i128()
    }
}

/// `L(x) = x − x²/2 + x³/3 − 3x⁴/10` at 1e18, rounded down: the four terms over their common denominator, `30 · 1e54`,
/// divided once.
pub fn score(x: i128) -> i128 {
    let x = I256::from(x);
    let one = I256::from(WAD as i128);
    let one2 = one * one;
    let one3 = one2 * one;
    let square = x * x;
    let numerator = I256::from(30) * x * one3 - I256::from(15) * square * one2
        + I256::from(10) * square * x * one
        - I256::from(9) * square * square;
    floor_div_wide(numerator, I256::from(30) * one3).as_i128()
}

/// `a / b` rounded toward minus infinity, for a positive `b`.
pub fn floor_div(a: i128, b: i128) -> i128 {
    let q = a / b;
    if a % b < 0 {
        q - 1
    } else {
        q
    }
}

fn floor_div_wide(a: I256, b: I256) -> I256 {
    let q = a / b;
    if a % b < I256::ZERO {
        q - I256::ONE
    } else {
        q
    }
}

/// `a · b / c`, rounded down or up, exact for any `a` and for `b` and `c` below 2^128: `a` is split by `c` first, so no
/// product passes 256 bits unless the result does. None when the result does not fit.
pub fn mul_div(a: U256, b: u128, c: u128, up: bool) -> Option<U256> {
    let (b, c) = (U256::from(b), U256::from(c));
    let (q, r) = (a / c, a % c);
    let rb = r * b;
    let mut part = rb / c;
    if up && rb % c != U256::ZERO {
        part += U256::ONE;
    }
    q.checked_mul(b)?.checked_add(part)
}

/// What a leg sends out and asks back at `supply` and `scale`, moving from `current` to `next` units: its change in
/// backing, `supply · Δunits · scale / (share_unit · 1e18)`, rounded down when it leaves and up when it comes back.
pub fn leg_amounts(
    supply: U256,
    scale: u128,
    current: U256,
    next: U256,
    share_unit: u128,
) -> (U256, U256) {
    let denominator = share_unit * WAD;
    let amount = |delta: U256, up: bool| {
        let product = supply
            .checked_mul(delta)
            .expect("a supply and a change of their widths fit");
        mul_div(product, scale, denominator, up).expect("an amount of its width fits")
    };
    if next < current {
        (amount(current - next, false), U256::ZERO)
    } else if next > current {
        (U256::ZERO, amount(next - current, true))
    } else {
        (U256::ZERO, U256::ZERO)
    }
}

/// The settlement `elapsed` seconds into the auction, or the first refusal. The program runs the same steps leg by
/// leg over the index's own data; this composes them for the vectors.
#[allow(clippy::too_many_arguments)]
pub fn settlement(
    elapsed: u64,
    supply: U256,
    scale: u128,
    current: &[U256],
    next: &[U256],
    weights: &[u16],
    kept: impl Fn(usize) -> bool,
    share_unit: u128,
    max_units: U256,
) -> Result<Settled, Refusal> {
    let bar = bar_at(elapsed).ok_or(Refusal::AuctionOver)?;
    if next.len() != current.len() {
        return Err(Refusal::LengthMismatch);
    }
    if supply < U256::from(share_unit) {
        return Err(Refusal::NothingToRebalance);
    }
    let moves = (0..current.len()).map(|i| LegMove {
        current: current[i],
        next: next[i],
        weight: weights[i],
        kept: kept(i),
    });
    let gain = gain(moves, max_units)?;
    if gain < bar as i128 {
        return Err(Refusal::GainBelowBar { gain, bar });
    }
    let (amounts_out, amounts_in) = current
        .iter()
        .zip(next)
        .map(|(c, n)| leg_amounts(supply, scale, *c, *n, share_unit))
        .unzip();
    Ok(Settled {
        bar,
        gain,
        amounts_out,
        amounts_in,
    })
}

/// What the units a fill adds are worth at `prices` and the least they may be worth: what the units it takes are
/// worth, less `tolerance`, rounded up. A leg whose units do not change counts for nothing, whatever its price.
pub fn value_floor(
    moves: impl Iterator<Item = (U256, U256, u128)>,
    tolerance: u128,
) -> (U256, U256) {
    let mut value_in = U256::ZERO;
    let mut value_out = U256::ZERO;
    for (current, next, price) in moves {
        if next == current {
            continue;
        }
        match leg_value(current, next, price) {
            (worth, true) => value_out += worth,
            (worth, false) => value_in += worth,
        }
    }
    (value_in, floor_of(value_out, tolerance))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bar_halves_and_never_reaches_zero() {
        assert_eq!(bar_at(0), Some(BAR_MAX));
        assert_eq!(bar_at(BAR_HALF_LIFE), Some(BAR_MAX / 2));
        assert_eq!(bar_at(BAR_HALF_LIFE / 2), Some(BAR_MAX * 3 / 4));
        assert!(bar_at(AUCTION_DURATION).unwrap() > 0);
        assert_eq!(bar_at(AUCTION_DURATION + 1), None);
        assert_eq!(
            oracle_tolerance_at(AUCTION_DURATION),
            Some(MAX_ORACLE_TOLERANCE)
        );
        assert_eq!(oracle_tolerance_at(0), Some(0));
        assert_eq!(oracle_tolerance_at(AUCTION_DURATION + 1), None);
    }

    #[test]
    fn the_score_is_below_the_logarithm_at_the_caps() {
        // L(−0.2) = −0.2 − 0.02 − 0.0026666… − 0.00048 against ln(0.8) = −0.2231435…: three millionths of margin
        assert_eq!(score(-200_000_000_000_000_000), -223_146_666_666_666_667);
        assert_eq!(score(0), 0);
        assert_eq!(score(WAD as i128), 533_333_333_333_333_333);
    }

    #[test]
    fn mul_div_is_exact_past_256_bits_of_product() {
        let a = U256::MAX / U256::from(3u8);
        assert_eq!(mul_div(a, 3, 3, false), Some(a));
        assert_eq!(mul_div(U256::from(10u8), 1, 3, true), Some(U256::from(4u8)));
        assert_eq!(
            mul_div(U256::from(10u8), 1, 3, false),
            Some(U256::from(3u8))
        );
        assert_eq!(mul_div(U256::MAX, 2, 1, false), None);
    }
}
