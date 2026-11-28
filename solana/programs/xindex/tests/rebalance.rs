// SPDX-License-Identifier: BUSL-1.1
//! The rebalance on LiteSVM: the clock, the keep mask, the cancel and the quote, and a fill through its ticket, judged
//! on units first and then by the quote and Pyth's prices, which can only refuse. Every revert is its exact error.

mod common;

use anchor_lang::prelude::Pubkey;
use common::*;
use solana_keypair::Keypair;
use solana_signer::Signer;
use xindex::{
    error::XindexError as E, state::LegSpec, AUCTION_DURATION, MAX_PRICE_AGE,
    MIN_REBALANCE_INTERVAL, REBALANCE_DELAY, SHARE_UNIT, WEIGHTS_DELAY,
};

const UNITS: [u64; 3] = [1_000_000_000, 2_000_000, 300_000_000];
const WEIGHTS: [u16; 3] = [5_000, 3_000, 2_000];
/// The units that put the index back on its weights once leg 0's price rose a quarter: leg 0 sells a tenth, the others
/// buy an eighth, worth the same at the market.
const ON_WEIGHTS: [u64; 3] = [900_000_000, 2_250_000, 337_500_000];
/// Seconds into the auction at which the bar, seven halvings down, sits under that fill's gain of about 0.62%.
const LATE: i64 = 7 * 720 + 60;
const NO_MASK: [u64; 4] = [0; 4];

struct Fixture {
    bench: Bench,
    creator: Keypair,
    index: Pubkey,
    holder: Keypair,
}

/// An index of three legs (an Ondo-like Token-2022 mint, a plain one of 6 decimals and a classic SPL mint) created on
/// its weights, ten whole shares issued, and its interval run out.
fn fixture() -> Fixture {
    let mut bench = Bench::new();
    let mints = [
        (bench.mint(T22, 9, Extensions::ondo()), T22),
        (bench.mint(T22, 6, Extensions::default()), T22),
        (bench.mint(CLASSIC, 8, Extensions::default()), CLASSIC),
    ];
    for (mint, program) in &mints {
        bench.list(mint, program);
    }
    let creator = bench.wallet();
    bench.approve(&creator.pubkey());
    let legs: Vec<LegSpec> = mints
        .iter()
        .zip(UNITS.iter().zip(WEIGHTS))
        .map(|((mint, _), (units, weight))| LegSpec {
            mint: *mint,
            units: *units,
            weight,
        })
        .collect();
    let index = bench.create(&creator, &legs);
    let holder = bench.wallet();
    bench.issue(&holder, &index, 10 * SHARE_UNIT as u64, 3);
    bench.warp(MIN_REBALANCE_INTERVAL);
    Fixture {
        bench,
        creator,
        index,
        holder,
    }
}

/// Leg 0's price up a quarter, every price published now.
fn market_moves(f: &mut Fixture) {
    f.bench.price_at(&f.index, &[6_250, 3_000, 2_000]);
}

/// Starts a rebalance as a stranger and runs the clock `into` seconds into its auction.
fn start_and_open(f: &mut Fixture, into: i64) {
    let stranger = f.bench.wallet();
    f.bench
        .send(
            &[f.bench.start_ix(&stranger.pubkey(), &f.index, NO_MASK)],
            &[&stranger],
        )
        .unwrap();
    f.bench.warp(REBALANCE_DELAY + into);
}

#[test]
fn a_fair_fill_settles_and_pays_the_executor_only_after_its_commit() {
    let mut f = fixture();
    start_and_open(&mut f, LATE);
    market_moves(&mut f);
    let executor = f.bench.wallet();
    let e = executor.pubkey();
    f.bench.prepare_fill(&executor, &f.index, &ON_WEIGHTS);
    // nothing the index sells has left it yet, and the deposits are pending in their legs
    let amounts = f.bench.amounts(&f.index, &ON_WEIGHTS);
    assert_eq!(amounts[0], (1_000_000_000, 0));
    assert_eq!(amounts[1], (0, 2_500_000));
    assert_eq!(amounts[2], (0, 375_000_000));
    let state = f.bench.index(&f.index);
    assert_eq!(state.legs[1].pending, 2_500_000);
    f.bench.assert_invariant(&f.index);

    f.bench
        .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor])
        .unwrap();
    let state = f.bench.index(&f.index);
    assert_eq!(
        state.legs.iter().map(|l| l.units).collect::<Vec<_>>(),
        ON_WEIGHTS.to_vec()
    );
    assert_eq!(state.rebalance_nonce, 1);
    assert_eq!(state.header.eta, 0);
    assert_eq!(
        state.legs[0].owed, 1_000_000_000,
        "what leg 0 sold waits for the executor"
    );
    assert_eq!(state.legs[1].pending, 0, "what leg 1 bought is backing now");
    f.bench.assert_invariant(&f.index);
    // a ticket commits once
    expect_err(
        f.bench
            .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
        E::FillCommitted,
    );

    let program = f.bench.program_of(&f.index, 0);
    f.bench.collect_fill(&executor, &f.index);
    assert_eq!(
        f.bench.balance(&ata(&e, &state.legs[0].mint, &program)),
        1_000_000_000
    );
    assert_eq!(f.bench.index(&f.index).legs[0].owed, 0);
    f.bench.assert_invariant(&f.index);
    f.bench
        .send(&[f.bench.close_fill_ix(&e, &f.index)], &[&executor])
        .unwrap();

    // the holder redeems at the new units
    let h = f.holder.pubkey();
    f.bench
        .send(
            &[f.bench.redeem_ix(&h, &f.index, SHARE_UNIT as u64)],
            &[&f.holder],
        )
        .unwrap();
    assert_eq!(
        f.bench.redeem_ticket(&f.index, &h).unwrap().owed,
        ON_WEIGHTS.to_vec()
    );
}

#[test]
fn the_units_are_judged_before_any_price() {
    let mut f = fixture();
    start_and_open(&mut f, LATE);
    market_moves(&mut f);
    let executor = f.bench.wallet();
    let e = executor.pubkey();
    f.bench.prepare_fill(&executor, &f.index, &ON_WEIGHTS);
    // a leg past its turnover cap or its growth cap is refused as it is named
    for units in [
        [799_999_999, 2_250_000, 337_500_000],
        [900_000_000, 4_000_001, 337_500_000],
    ] {
        expect_err(
            f.bench.send(
                &[f.bench.set_units_ix(&e, &f.index, 0, units.to_vec())],
                &[&executor],
            ),
            E::LegOutOfBounds,
        );
    }
    // units that change nothing, or a trade worth the same that the units call a loss (leg 0 sells a fifth, the rest
    // grow less than its value), never clear the bar
    for units in [UNITS, [800_000_000, 2_200_000, 330_000_000]] {
        f.bench
            .send(
                &[f.bench.set_units_ix(&e, &f.index, 0, units.to_vec())],
                &[&executor],
            )
            .unwrap();
        expect_err(
            f.bench
                .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
            E::GainBelowBar,
        );
    }
    // early in the auction the bar stands far above the fair fill's gain
    let mut f = fixture();
    start_and_open(&mut f, 60);
    market_moves(&mut f);
    let executor = f.bench.wallet();
    let e = executor.pubkey();
    f.bench.prepare_fill(&executor, &f.index, &ON_WEIGHTS);
    expect_err(
        f.bench
            .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
        E::GainBelowBar,
    );
}

#[test]
fn pyths_prices_can_only_refuse() {
    let mut f = fixture();
    start_and_open(&mut f, LATE);
    // Pyth has leg 0 dearer than the fill assumes: at its prices the fill gives out 800 and brings in 625
    f.bench.price_at(&f.index, &[8_000, 3_000, 2_000]);
    let executor = f.bench.wallet();
    let e = executor.pubkey();
    f.bench.prepare_fill(&executor, &f.index, &ON_WEIGHTS);
    expect_err(
        f.bench
            .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
        E::BelowOracleValue,
    );
    // at the moved market it holds; a price older than MAX_PRICE_AGE at the commit refuses it
    market_moves(&mut f);
    f.bench
        .send_big(
            &[f.bench.price_fill_ix(&e, &f.index, &[0, 1, 2])],
            &[&executor],
        )
        .unwrap();
    f.bench.warp(MAX_PRICE_AGE + 1);
    expect_err(
        f.bench
            .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
        E::StalePrice,
    );
    // a leg whose units change loses its price
    market_moves(&mut f);
    f.bench
        .send_big(
            &[f.bench.price_fill_ix(&e, &f.index, &[0, 1, 2])],
            &[&executor],
        )
        .unwrap();
    f.bench
        .send(
            &[f.bench.set_units_ix(&e, &f.index, 2, vec![337_500_001])],
            &[&executor],
        )
        .unwrap();
    expect_err(
        f.bench
            .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
        E::PriceMissing,
    );
    f.bench
        .send(
            &[f.bench.set_units_ix(&e, &f.index, 2, vec![337_500_000])],
            &[&executor],
        )
        .unwrap();
    f.bench
        .send_big(&[f.bench.price_fill_ix(&e, &f.index, &[2])], &[&executor])
        .unwrap();
    f.bench
        .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor])
        .unwrap();
}

#[test]
fn a_price_account_is_pyths_fully_verified_price_of_the_listings_feed() {
    let mut f = fixture();
    start_and_open(&mut f, LATE);
    market_moves(&mut f);
    let executor = f.bench.wallet();
    let e = executor.pubkey();
    f.bench
        .send(&[f.bench.open_fill_ix(&e, &f.index)], &[&executor])
        .unwrap();
    f.bench
        .send(
            &[f.bench.set_units_ix(&e, &f.index, 0, ON_WEIGHTS.to_vec())],
            &[&executor],
        )
        .unwrap();
    let mint = f.bench.index(&f.index).legs[0].mint;
    let account = f.bench.svm.get_account(&price_pda(&mint)).unwrap();
    let price = |bench: &mut Bench, data: Vec<u8>, owner: Pubkey| {
        let mut forged = account.clone();
        forged.data = data;
        forged.owner = owner;
        bench.svm.set_account(price_pda(&mint), forged).unwrap();
    };
    let now = f.bench.now();
    for (data, owner, error) in [
        (account.data.clone(), SYSTEM, E::NotAPythPrice),
        (
            {
                let mut partial = account.data.clone();
                partial[40] = 0;
                partial
            },
            xindex::pyth::RECEIVER,
            E::PriceNotVerified,
        ),
        (
            price_update([9; 32], 1, 0, -8, now),
            xindex::pyth::RECEIVER,
            E::WrongPriceFeed,
        ),
        (
            price_update(f.bench.feed_for(&mint), 100, 100, -8, now),
            xindex::pyth::RECEIVER,
            E::UnusablePrice,
        ),
    ] {
        price(&mut f.bench, data, owner);
        expect_err(
            f.bench
                .send_big(&[f.bench.price_fill_ix(&e, &f.index, &[0])], &[&executor]),
            error,
        );
    }
}

#[test]
fn a_short_deposit_moves_on_and_a_long_one_comes_back() {
    let mut f = fixture();
    start_and_open(&mut f, LATE);
    market_moves(&mut f);
    let executor = f.bench.wallet();
    let e = executor.pubkey();
    f.bench.prepare_fill(&executor, &f.index, &ON_WEIGHTS);
    // a holder's issue lands mid-fill: the settlement grows with the supply, past what the executor deposited
    let newcomer = f.bench.wallet();
    f.bench.issue(&newcomer, &f.index, SHARE_UNIT as u64, 3);
    expect_err(
        f.bench
            .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
        E::RebalanceMovedOn,
    );
    // topping up both growing legs well past their need lets it settle, and the surplus returns
    let state = f.bench.index(&f.index);
    for leg in [1u16, 2] {
        let program = f.bench.program_of(&f.index, leg as usize);
        f.bench
            .fund(&e, &state.legs[leg as usize].mint, &program, 1_000_000_000);
        f.bench
            .send(
                &[f.bench.deposit_fill_ix(&e, &f.index, leg, 1_000_000_000)],
                &[&executor],
            )
            .unwrap();
    }
    f.bench
        .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor])
        .unwrap();
    let amounts_at_eleven = [1_100_000_000u64, 2_750_000, 412_500_000];
    let fill = f.bench.fill(&f.index, &e);
    assert_eq!(fill[0].settled, amounts_at_eleven[0]);
    assert_eq!(
        fill[1].deposited,
        2_500_000 + 1_000_000_000 - amounts_at_eleven[1]
    );
    assert_eq!(
        fill[2].deposited,
        375_000_000 + 1_000_000_000 - amounts_at_eleven[2]
    );
    f.bench.assert_invariant(&f.index);
    f.bench.collect_fill(&executor, &f.index);
    f.bench.assert_invariant(&f.index);
    expect_err(
        f.bench
            .send(&[f.bench.withdraw_fill_ix(&e, &f.index, 0)], &[&executor]),
        E::NothingOwed,
    );
}

#[test]
fn a_ticket_whose_proposal_is_gone_commits_nothing_and_returns_its_deposits() {
    let mut f = fixture();
    start_and_open(&mut f, LATE);
    market_moves(&mut f);
    let executor = f.bench.wallet();
    let e = executor.pubkey();
    f.bench.prepare_fill(&executor, &f.index, &ON_WEIGHTS);
    let guardian = f.bench.guardian.insecure_clone();
    f.bench
        .send(
            &[f.bench.cancel_ix(&guardian.pubkey(), &f.index, None)],
            &[&guardian],
        )
        .unwrap();
    expect_err(
        f.bench
            .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
        E::StaleFill,
    );
    expect_err(
        f.bench.send(
            &[f.bench.set_units_ix(&e, &f.index, 0, UNITS.to_vec())],
            &[&executor],
        ),
        E::StaleFill,
    );
    expect_err(
        f.bench
            .send(&[f.bench.close_fill_ix(&e, &f.index)], &[&executor]),
        E::FillOutstanding,
    );
    // nor under the next proposal, which the ticket was never opened for
    f.bench
        .send(
            &[f.bench.start_ix(&guardian.pubkey(), &f.index, NO_MASK)],
            &[&guardian],
        )
        .unwrap();
    f.bench.warp(REBALANCE_DELAY + LATE);
    market_moves(&mut f);
    expect_err(
        f.bench.send_big(
            &[f.bench.price_fill_ix(&e, &f.index, &[0, 1, 2])],
            &[&executor],
        ),
        E::StaleFill,
    );
    expect_err(
        f.bench
            .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
        E::StaleFill,
    );
    f.bench.collect_fill(&executor, &f.index);
    let state = f.bench.index(&f.index);
    assert!(state.legs.iter().all(|leg| leg.pending == 0));
    f.bench
        .send(&[f.bench.close_fill_ix(&e, &f.index)], &[&executor])
        .unwrap();
    f.bench.assert_invariant(&f.index);
}

#[test]
fn the_clock_holds_strangers_to_the_interval_and_the_notice() {
    let mut bench_fixture = fixture();
    let f = &mut bench_fixture;
    let stranger = f.bench.wallet();
    let s = stranger.pubkey();
    let executor = f.bench.wallet();
    let e = executor.pubkey();
    expect_err(
        f.bench
            .send(&[f.bench.open_fill_ix(&e, &f.index)], &[&executor]),
        E::NoPendingRebalance,
    );
    f.bench
        .send(&[f.bench.start_ix(&s, &f.index, NO_MASK)], &[&stranger])
        .unwrap();
    expect_err(
        f.bench
            .send(&[f.bench.start_ix(&s, &f.index, NO_MASK)], &[&stranger]),
        E::RebalancePending,
    );
    f.bench
        .send(&[f.bench.open_fill_ix(&e, &f.index)], &[&executor])
        .unwrap();
    expect_err(
        f.bench
            .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
        E::RebalanceNotReady,
    );
    f.bench.warp(REBALANCE_DELAY + AUCTION_DURATION + 1);
    expect_err(
        f.bench
            .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
        E::RebalanceExpired,
    );
    // an auction that expired unfilled holds strangers off for REBALANCE_DELAY; the owner starts at once
    expect_err(
        f.bench
            .send(&[f.bench.start_ix(&s, &f.index, NO_MASK)], &[&stranger]),
        E::Unauthorized,
    );
    let owner = f.bench.owner.insecure_clone();
    f.bench
        .send(
            &[f.bench.start_ix(&owner.pubkey(), &f.index, NO_MASK)],
            &[&owner],
        )
        .unwrap();
    // a cancel, by the proposal its signers read
    expect_err(
        f.bench
            .send(&[f.bench.cancel_ix(&s, &f.index, None)], &[&stranger]),
        E::Unauthorized,
    );
    expect_err(
        f.bench.send(
            &[f.bench.cancel_ix(&owner.pubkey(), &f.index, Some(1))],
            &[&owner],
        ),
        E::StaleProposal,
    );
    f.bench
        .send(
            &[f.bench.cancel_ix(&owner.pubkey(), &f.index, Some(2))],
            &[&owner],
        )
        .unwrap();
    expect_err(
        f.bench.send(
            &[f.bench.cancel_ix(&owner.pubkey(), &f.index, None)],
            &[&owner],
        ),
        E::NoPendingRebalance,
    );
    expect_err(
        f.bench
            .send(&[f.bench.start_ix(&s, &f.index, NO_MASK)], &[&stranger]),
        E::Unauthorized,
    );
    f.bench.warp(REBALANCE_DELAY);
    f.bench
        .send(&[f.bench.start_ix(&s, &f.index, NO_MASK)], &[&stranger])
        .unwrap();
}

#[test]
fn a_keep_mask_is_the_owners_or_the_guardians_and_keeps_its_leg() {
    let mut f = fixture();
    let stranger = f.bench.wallet();
    let guardian = f.bench.guardian.insecure_clone();
    let g = guardian.pubkey();
    expect_err(
        f.bench.send(
            &[f.bench.start_ix(&stranger.pubkey(), &f.index, [1, 0, 0, 0])],
            &[&stranger],
        ),
        E::Unauthorized,
    );
    // a mask must leave two legs moving and name none the index lacks
    for mask in [[3, 0, 0, 0], [8, 0, 0, 0], [0, 0, 0, 1 << 63]] {
        expect_err(
            f.bench
                .send(&[f.bench.start_ix(&g, &f.index, mask)], &[&guardian]),
            E::InvalidKeepMask,
        );
    }
    f.bench
        .send(
            &[f.bench.start_ix(&g, &f.index, [4, 0, 0, 0])],
            &[&guardian],
        )
        .unwrap();
    f.bench.warp(REBALANCE_DELAY + LATE);
    // leg 2 is kept: naming it other units is out of its bounds; a fill that trades legs 0 and 1 alone settles. Leg 0
    // sells a tenth, worth 600, which buys leg 1 a fifth; its gain, about 0.2%, clears the bar two halvings on.
    let executor = f.bench.wallet();
    let e = executor.pubkey();
    f.bench
        .send(&[f.bench.open_fill_ix(&e, &f.index)], &[&executor])
        .unwrap();
    expect_err(
        f.bench.send(
            &[f.bench.set_units_ix(&e, &f.index, 2, vec![337_500_000])],
            &[&executor],
        ),
        E::LegOutOfBounds,
    );
    f.bench
        .send(&[f.bench.close_fill_ix(&e, &f.index)], &[&executor])
        .unwrap();
    let kept = [900_000_000, 2_400_000, 300_000_000];
    f.bench.warp(2 * 720);
    f.bench.price_at(&f.index, &[6_000, 3_000, 2_000]);
    f.bench.prepare_fill(&executor, &f.index, &kept);
    f.bench
        .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor])
        .unwrap();
    assert_eq!(f.bench.index(&f.index).header.masked_fill, 1);
    // a fill under a mask restarts only MIN_REBALANCE_INTERVAL, which is the interval here; the next unmasked start
    // and its fill restart the index's own
    f.bench.warp(MIN_REBALANCE_INTERVAL);
    f.bench
        .send(
            &[f.bench.start_ix(&stranger.pubkey(), &f.index, NO_MASK)],
            &[&stranger],
        )
        .unwrap();
}

#[test]
fn the_owner_or_the_guardian_restarts_a_week_after_a_fill_and_never_before_the_first() {
    // a quarterly index: strangers wait 91 days after a fill, the roles a week
    let mut bench = Bench::new();
    let a = bench.mint(T22, 9, Extensions::default());
    let b = bench.mint(T22, 9, Extensions::default());
    bench.list(&a, &T22);
    bench.list(&b, &T22);
    let creator = bench.wallet();
    bench.approve(&creator.pubkey());
    let legs = [
        LegSpec {
            mint: a,
            units: 1_000_000_000,
            weight: 5_000,
        },
        LegSpec {
            mint: b,
            units: 1_000_000_000,
            weight: 5_000,
        },
    ];
    let terms = xindex::state::IndexTerms {
        rebalance_interval: xindex::MAX_REBALANCE_INTERVAL,
        ..terms()
    };
    let index = bench.create_with(&creator, &legs, terms, false);
    let holder = bench.wallet();
    bench.issue(&holder, &index, 10 * SHARE_UNIT as u64, 2);
    let guardian = bench.guardian.insecure_clone();
    let g = guardian.pubkey();
    bench.warp(MIN_REBALANCE_INTERVAL);
    expect_err(
        bench.send(&[bench.start_ix(&g, &index, NO_MASK)], &[&guardian]),
        E::RebalanceTooSoon,
    );
    bench.warp(xindex::MAX_REBALANCE_INTERVAL - MIN_REBALANCE_INTERVAL);
    bench
        .send(&[bench.start_ix(&g, &index, NO_MASK)], &[&guardian])
        .unwrap();
    bench.warp(REBALANCE_DELAY + LATE);
    // b rose a quarter against a: a fill buys an eighth more of a for a tenth of b, even at those prices
    bench.price_at(&index, &[5_000, 6_250]);
    let executor = bench.wallet();
    let e = executor.pubkey();
    let next = [1_125_000_000u64, 900_000_000];
    bench.prepare_fill(&executor, &index, &next);
    bench
        .send(&[bench.commit_ix(&e, &index)], &[&executor])
        .unwrap();
    let stranger = bench.wallet();
    bench.warp(MIN_REBALANCE_INTERVAL);
    expect_err(
        bench.send(
            &[bench.start_ix(&stranger.pubkey(), &index, NO_MASK)],
            &[&stranger],
        ),
        E::RebalanceTooSoon,
    );
    bench
        .send(&[bench.start_ix(&g, &index, NO_MASK)], &[&guardian])
        .unwrap();
}

#[test]
fn a_quote_can_only_refuse_and_binds_its_proposal_alone() {
    let mut f = fixture();
    let guardian = f.bench.guardian.insecure_clone();
    let g = guardian.pubkey();
    let stranger = f.bench.wallet();
    expect_err(
        f.bench.send(
            &[f.bench
                .write_quote_ix(&stranger.pubkey(), &f.index, 0, vec![1, 1, 1])],
            &[&stranger],
        ),
        E::Unauthorized,
    );
    // a quote that misses a price, or a tolerance of one, is refused
    f.bench
        .send(
            &[f.bench.write_quote_ix(&g, &f.index, 0, vec![125, 0, 100])],
            &[&guardian],
        )
        .unwrap();
    expect_err(
        f.bench.send(
            &[f.bench.start_quoted_ix(&g, &f.index, NO_MASK, 0)],
            &[&guardian],
        ),
        E::InvalidQuote,
    );
    f.bench
        .send(
            &[f.bench.write_quote_ix(&g, &f.index, 1, vec![150])],
            &[&guardian],
        )
        .unwrap();
    expect_err(
        f.bench.send(
            &[f.bench
                .start_quoted_ix(&g, &f.index, NO_MASK, 1_000_000_000_000_000_000)],
            &[&guardian],
        ),
        E::InvalidQuote,
    );
    // the quote prices leg 1 dear: at it the fair fill gives away too much of leg 0 for what it buys
    f.bench
        .send(
            &[f.bench.write_quote_ix(&g, &f.index, 0, vec![1_000, 10, 1])],
            &[&guardian],
        )
        .unwrap();
    f.bench
        .send(
            &[f.bench.start_quoted_ix(&g, &f.index, NO_MASK, 0)],
            &[&guardian],
        )
        .unwrap();
    expect_err(
        f.bench.send(
            &[f.bench.write_quote_ix(&g, &f.index, 0, vec![1])],
            &[&guardian],
        ),
        E::QuoteBound,
    );
    f.bench.warp(REBALANCE_DELAY + LATE);
    market_moves(&mut f);
    let executor = f.bench.wallet();
    let e = executor.pubkey();
    f.bench.prepare_fill(&executor, &f.index, &ON_WEIGHTS);
    expect_err(
        f.bench
            .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor]),
        E::BelowQuote,
    );
    // the next proposal starts without it
    f.bench
        .send(&[f.bench.cancel_ix(&g, &f.index, None)], &[&guardian])
        .unwrap();
    f.bench.collect_fill(&executor, &f.index);
    f.bench
        .send(&[f.bench.close_fill_ix(&e, &f.index)], &[&executor])
        .unwrap();
    f.bench
        .send(&[f.bench.start_ix(&g, &f.index, NO_MASK)], &[&guardian])
        .unwrap();
    f.bench.warp(REBALANCE_DELAY + LATE);
    market_moves(&mut f);
    f.bench.prepare_fill(&executor, &f.index, &ON_WEIGHTS);
    f.bench
        .send(&[f.bench.commit_ix(&e, &f.index)], &[&executor])
        .unwrap();
}

#[test]
fn an_index_under_one_whole_share_does_not_rebalance() {
    let mut f = fixture();
    let h = f.holder.pubkey();
    f.bench
        .send(
            &[f.bench.redeem_ix(&h, &f.index, 9 * SHARE_UNIT as u64 + 1)],
            &[&f.holder],
        )
        .unwrap();
    start_and_open(&mut f, LATE);
    market_moves(&mut f);
    let executor = f.bench.wallet();
    f.bench.prepare_fill(&executor, &f.index, &ON_WEIGHTS);
    expect_err(
        f.bench.send(
            &[f.bench.commit_ix(&executor.pubkey(), &f.index)],
            &[&executor],
        ),
        E::NothingToRebalance,
    );
}

#[test]
fn a_multiplier_counts_only_once_settled() {
    let mut bench = Bench::new();
    let ondo = bench.mint(T22, 9, Extensions::ondo());
    let other = bench.mint(T22, 9, Extensions::default());
    bench.list_with(&ondo, &T22, xindex::pyth::FEED_MULTIPLIER);
    bench.list(&other, &T22);
    let creator = bench.wallet();
    bench.approve(&creator.pubkey());
    let legs = [
        LegSpec {
            mint: ondo,
            units: 1_000_000_000,
            weight: 5_000,
        },
        LegSpec {
            mint: other,
            units: 1_000_000_000,
            weight: 5_000,
        },
    ];
    let hash = xindex::math::terms_hash(2, &terms(), &legs);
    let index = index_pda(&creator.pubkey(), &hash);
    bench
        .send(
            &[bench.begin_ix(&creator.pubkey(), hash, 2, "X", "X")],
            &[&creator],
        )
        .unwrap();
    bench
        .send(
            &[bench.add_legs_ix(&creator.pubkey(), &index, &legs)],
            &[&creator],
        )
        .unwrap();
    // Ondo schedules a split's multiplier an hour ahead: refused until twenty minutes after it takes effect
    let effective = bench.now() + 3_600;
    bench.set_multiplier(&ondo, 2.0, effective);
    for wait in [0, 3_600 + xindex::MIN_SVALUE_AGE - 1] {
        bench.warp(wait);
        bench.price_at(&index, &[5_000, 5_000]);
        expect_err(
            bench.send_big(
                &[bench.price_legs_ix(&creator.pubkey(), &index, &[0])],
                &[&creator],
            ),
            E::MultiplierUnsettled,
        );
    }
    bench.warp(1);
    // settled, the leg is valued at the share's price times two
    bench.price_on_weights(&creator, &index);
    bench
        .send(&[bench.seal_ix(&creator.pubkey(), &index)], &[&creator])
        .unwrap();
}

#[test]
fn weights_change_behind_their_notice_and_never_during_a_rebalance() {
    let mut f = fixture();
    let c = f.creator.pubkey();
    let stranger = f.bench.wallet();
    expect_err(
        f.bench.send(
            &[f.bench
                .propose_weights_ix(&stranger.pubkey(), &f.index, vec![4_000, 4_000, 2_000])],
            &[&stranger],
        ),
        E::NotCreator,
    );
    for bad in [
        vec![5_000, 5_000, 0],
        vec![5_000, 3_000, 1_999],
        vec![5_000, 5_000],
    ] {
        expect_err(
            f.bench.send(
                &[f.bench.propose_weights_ix(&c, &f.index, bad)],
                &[&f.creator],
            ),
            E::InvalidWeights,
        );
    }
    f.bench
        .send(
            &[f.bench
                .propose_weights_ix(&c, &f.index, vec![4_000, 4_000, 2_000])],
            &[&f.creator],
        )
        .unwrap();
    expect_err(
        f.bench
            .send(&[f.bench.execute_weights_ix(&f.index)], &[&f.creator]),
        E::WeightsNotReady,
    );
    f.bench.warp(WEIGHTS_DELAY);
    f.bench
        .send(
            &[f.bench.start_ix(&stranger.pubkey(), &f.index, NO_MASK)],
            &[&stranger],
        )
        .unwrap();
    expect_err(
        f.bench
            .send(&[f.bench.execute_weights_ix(&f.index)], &[&f.creator]),
        E::RebalancePending,
    );
    let owner = f.bench.owner.insecure_clone();
    f.bench
        .send(
            &[f.bench.cancel_ix(&owner.pubkey(), &f.index, None)],
            &[&owner],
        )
        .unwrap();
    f.bench
        .send(&[f.bench.execute_weights_ix(&f.index)], &[&f.creator])
        .unwrap();
    let weights: Vec<u16> = f
        .bench
        .index(&f.index)
        .legs
        .iter()
        .map(|l| l.weight)
        .collect();
    assert_eq!(weights, vec![4_000, 4_000, 2_000]);
    expect_err(
        f.bench
            .send(&[f.bench.execute_weights_ix(&f.index)], &[&f.creator]),
        E::NoPendingWeights,
    );
    // the owner cancels a pending change; a window run out leaves it unappliable
    f.bench
        .send(
            &[f.bench
                .propose_weights_ix(&c, &f.index, vec![5_000, 3_000, 2_000])],
            &[&f.creator],
        )
        .unwrap();
    f.bench
        .send(
            &[f.bench.cancel_weights_ix(&owner.pubkey(), &f.index)],
            &[&owner],
        )
        .unwrap();
    expect_err(
        f.bench.send(
            &[f.bench.cancel_weights_ix(&owner.pubkey(), &f.index)],
            &[&owner],
        ),
        E::NoPendingWeights,
    );
    f.bench
        .send(
            &[f.bench
                .propose_weights_ix(&c, &f.index, vec![5_000, 3_000, 2_000])],
            &[&f.creator],
        )
        .unwrap();
    f.bench.warp(WEIGHTS_DELAY + xindex::PROPOSAL_WINDOW + 1);
    expect_err(
        f.bench
            .send(&[f.bench.execute_weights_ix(&f.index)], &[&f.creator]),
        E::WeightsExpired,
    );
}

#[test]
fn two_hundred_legs_fill_within_solanas_limits() {
    let mut bench = Bench::new();
    let mut legs = Vec::new();
    for _ in 0..xindex::MAX_COMPONENTS {
        let mint = bench.mint(T22, 9, Extensions::default());
        bench.list(&mint, &T22);
        legs.push(LegSpec {
            mint,
            units: 10_000_000,
            weight: 50,
        });
    }
    let creator = bench.wallet();
    bench.approve(&creator.pubkey());
    let index = bench.create(&creator, &legs);
    let holder = bench.wallet();
    bench.issue(&holder, &index, 10 * SHARE_UNIT as u64, 9);
    bench.warp(MIN_REBALANCE_INTERVAL);
    let stranger = bench.wallet();
    bench
        .send(
            &[bench.start_ix(&stranger.pubkey(), &index, NO_MASK)],
            &[&stranger],
        )
        .unwrap();
    bench.warp(REBALANCE_DELAY + LATE);
    // the first hundred legs are worth 5,500 to the others' 4,500: back on the weights, the first sell an eleventh and
    // the others buy a ninth, worth the same
    let shares: Vec<u16> = (0..200)
        .map(|i| if i < 100 { 5_500 } else { 4_500 })
        .collect();
    bench.price_at(&index, &shares);
    let next: Vec<u64> = (0..200)
        .map(|i| if i < 100 { 9_090_910 } else { 11_111_111 })
        .collect();
    let executor = bench.wallet();
    bench.prepare_fill(&executor, &index, &next);
    let sent = bench
        .send_big(&[bench.commit_ix(&executor.pubkey(), &index)], &[&executor])
        .unwrap();
    println!(
        "two hundred legs: a commit {} compute units, a step naming fifty legs' units or pricing ten {}",
        sent.compute_units_consumed, bench.last_fill_cu
    );
    assert!(sent.compute_units_consumed < 1_200_000);
    assert!(bench.last_fill_cu < 1_200_000);
    assert_eq!(bench.index(&index).rebalance_nonce, 1);
    bench.assert_invariant(&index);
}

#[test]
fn a_fill_accrues_the_streaming_fee_first_and_rounds_against_the_executor() {
    let mut bench = Bench::new();
    let a = bench.mint(T22, 9, Extensions::default());
    let b = bench.mint(T22, 6, Extensions::default());
    bench.list(&a, &T22);
    bench.list(&b, &T22);
    let creator = bench.wallet();
    bench.approve(&creator.pubkey());
    let legs = [
        LegSpec {
            mint: a,
            units: 1_000_000_000,
            weight: 5_000,
        },
        LegSpec {
            mint: b,
            units: 3_000_000,
            weight: 5_000,
        },
    ];
    let terms = xindex::state::IndexTerms {
        creator_streaming_bps: 100,
        ..terms()
    };
    let index = bench.create_with(&creator, &legs, terms, false);
    // a supply of ten shares and seven raw ones, so no amount of the fill is whole
    let holder = bench.wallet();
    bench.issue(&holder, &index, 10 * SHARE_UNIT as u64 + 7, 2);
    let creator_shares = ata(&creator.pubkey(), &shares_pda(&index), &CLASSIC);
    let before = bench.balance(&creator_shares);
    bench.warp(MIN_REBALANCE_INTERVAL);
    let stranger = bench.wallet();
    bench
        .send(
            &[bench.start_ix(&stranger.pubkey(), &index, NO_MASK)],
            &[&stranger],
        )
        .unwrap();
    bench.warp(REBALANCE_DELAY + LATE);
    bench.price_at(&index, &[5_000, 6_250]);
    let next = [1_125_000_000u64, 2_700_000];
    let executor = bench.wallet();
    let e = executor.pubkey();
    bench.prepare_fill(&executor, &index, &next);
    let deposited = bench.fill(&index, &e)[0].deposited;
    // the deposits were sized at the scale before the commit's accrual, which only lowers what the legs need
    bench
        .send(&[bench.commit_ix(&e, &index)], &[&executor])
        .unwrap();
    assert!(
        bench.balance(&creator_shares) > before,
        "the commit accrued the fee"
    );
    let state = bench.index(&index);
    let scale = state.header.scale;
    assert!(scale < xindex::SCALE_ONE);
    let supply = bench.supply(&shares_pda(&index));
    let fill = bench.fill(&index, &e);
    // at the scale and supply of the commit, what leg 0 needed rounds up and what leg 1 gave out rounds down, and
    // neither is whole, so the direction shows
    let at =
        |delta: u64, up: bool| xindex::math::backing_wide(supply, delta, scale, up).unwrap() as u64;
    assert_ne!(at(125_000_000, true), at(125_000_000, false));
    assert_ne!(at(300_000, true), at(300_000, false));
    assert_eq!(fill[0].deposited, deposited - at(125_000_000, true));
    assert_eq!(fill[1].settled, at(300_000, false));
    bench.assert_invariant(&index);
}
