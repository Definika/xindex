// SPDX-License-Identifier: BUSL-1.1
//! Fees in shares, the streaming fee's scale, the creator role, the gate, the mint pause, the price feeds and the
//! creation's check on weights, on LiteSVM. Every revert is its exact error.
// LiteSVM's failure carries the whole transaction's metadata, which the tests read; it is large by design.
#![allow(clippy::result_large_err)]

mod common;

use anchor_lang::prelude::Pubkey;
use common::*;
use solana_keypair::Keypair;
use solana_signer::Signer;
use xindex::{
    error::XindexError as E,
    state::{IndexTerms, LegSpec},
    LISTING_DELAY, MAX_REBALANCE_INTERVAL, SHARE_UNIT, YEAR,
};

const ONE: u64 = SHARE_UNIT as u64;

/// A bench with two listed mints of nine decimals and an approved creator.
fn two() -> (Bench, Keypair, Vec<LegSpec>) {
    let mut bench = Bench::new();
    let a = bench.mint(T22, 9, Extensions::default());
    let b = bench.mint(CLASSIC, 9, Extensions::default());
    bench.list(&a, &T22);
    bench.list(&b, &CLASSIC);
    let creator = bench.wallet();
    bench.approve(&creator.pubkey());
    let legs = vec![
        LegSpec {
            mint: a,
            units: 1_000_000_000,
            weight: 5_000,
        },
        LegSpec {
            mint: b,
            units: 2_000_000_000,
            weight: 5_000,
        },
    ];
    (bench, creator, legs)
}

fn set_policy(bench: &mut Bench, platform: u16, streaming: u16, referral: u16, recipient: Pubkey) {
    let owner = bench.owner.insecure_clone();
    bench
        .send(
            &[bench.fee_policy_ix(platform, streaming, referral, recipient)],
            &[&owner],
        )
        .unwrap();
}

fn shares_of(bench: &Bench, index: &Pubkey, wallet: &Pubkey) -> u64 {
    bench.balance(&ata(wallet, &shares_pda(index), &CLASSIC))
}

#[test]
fn the_fee_policy_has_its_bounds_and_reaches_only_later_indexes() {
    let (mut bench, creator, legs) = two();
    let owner = bench.owner.insecure_clone();
    let platform = bench.wallet().pubkey();
    for (fee, streaming, referral, recipient) in [
        (26, 0, 0, platform),
        (0, 101, 0, platform),
        (0, 0, 10_001, platform),
        (25, 0, 0, Pubkey::default()),
    ] {
        expect_err(
            bench.send(
                &[bench.fee_policy_ix(fee, streaming, referral, recipient)],
                &[&owner],
            ),
            E::InvalidFeePolicy,
        );
    }
    let stranger = bench.wallet();
    let mut ix = bench.fee_policy_ix(25, 100, 2_000, platform);
    ix.accounts[0].pubkey = stranger.pubkey();
    expect_err(bench.send(&[ix], &[&stranger]), E::NotOwner);
    set_policy(&mut bench, 25, 100, 2_000, platform);
    // a creator names the platform's rates as the policy has them, and its own within their bounds
    let c = creator.pubkey();
    let attempt = |bench: &mut Bench, terms: IndexTerms| {
        let hash = xindex::math::terms_hash(2, &terms, &legs);
        bench.send(
            &[bench.begin_ix_with(&c, hash, 2, "X", "X", terms, false)],
            &[&creator],
        )
    };
    let policy = IndexTerms {
        platform_fee_bps: 25,
        platform_streaming_bps: 100,
        referral_share_bps: 2_000,
        ..terms()
    };
    for (terms, error) in [
        (terms(), E::PolicyChanged),
        (
            IndexTerms {
                platform_fee_bps: 24,
                ..policy
            },
            E::PolicyChanged,
        ),
        (
            IndexTerms {
                creator_fee_bps: 101,
                ..policy
            },
            E::FeeTooHigh,
        ),
        (
            IndexTerms {
                creator_streaming_bps: 501,
                ..policy
            },
            E::FeeTooHigh,
        ),
        (
            IndexTerms {
                rebalance_interval: xindex::MIN_REBALANCE_INTERVAL - 1,
                ..policy
            },
            E::IntervalOutOfRange,
        ),
        (
            IndexTerms {
                rebalance_interval: MAX_REBALANCE_INTERVAL + 1,
                ..policy
            },
            E::IntervalOutOfRange,
        ),
    ] {
        expect_err(attempt(&mut bench, terms), error);
    }
    attempt(&mut bench, policy).unwrap();
}

#[test]
fn an_issue_backs_its_fee_shares_and_a_redeem_pays_them_out_of_its_burn() {
    let (mut bench, creator, legs) = two();
    let platform = bench.wallet();
    let p = platform.pubkey();
    set_policy(&mut bench, 25, 0, 2_000, p);
    let terms = IndexTerms {
        creator_fee_bps: 75,
        platform_fee_bps: 25,
        referral_share_bps: 2_000,
        ..terms()
    };
    let index = bench.create_with(&creator, &legs, terms, false);
    bench.fund(&p, &shares_pda(&index), &CLASSIC, 0);
    let holder = bench.wallet();
    let h = holder.pubkey();
    let referrer = bench.wallet().pubkey();
    let referrer_shares = bench.fund(&referrer, &shares_pda(&index), &CLASSIC, 0);
    bench
        .send(&[bench.open_issue_ix(&h, &index, 99 * ONE)], &[&holder])
        .unwrap();
    // 99 shares at 1% back 100 gross: the deposit pays for the fee's shares too
    let ticket = bench.issue_ticket(&index, &h).unwrap();
    assert_eq!(ticket.gross, 100 * ONE);
    assert_eq!(ticket.need, vec![100 * 1_000_000_000, 100 * 2_000_000_000]);
    for (i, leg) in legs.iter().enumerate() {
        let program = bench.program_of(&index, i);
        bench.fund(&h, &leg.mint, &program, ticket.need[i]);
        bench
            .send(&[bench.deposit_ix(&h, &index, i as u16)], &[&holder])
            .unwrap();
    }
    let mine = bench.fund(&h, &shares_pda(&index), &CLASSIC, 0);
    bench
        .send(
            &[bench.finalize_ix_with(&h, &index, &mine, Some(referrer_shares), None, None)],
            &[&holder],
        )
        .unwrap();
    // one share of fee: the platform's quarter of it, less the referrer's fifth of that, and the creator the rest
    assert_eq!(shares_of(&bench, &index, &h), 99 * ONE);
    assert_eq!(shares_of(&bench, &index, &referrer), ONE / 20);
    assert_eq!(shares_of(&bench, &index, &p), ONE / 4 - ONE / 20);
    assert_eq!(shares_of(&bench, &index, &creator.pubkey()), 3 * ONE / 4);
    assert_eq!(bench.supply(&shares_pda(&index)), 100 * ONE);
    bench.assert_invariant(&index);

    // a redeem of 10 shares: 1% of them minted to the recipients, the backing of the rest owed
    bench
        .send(&[bench.redeem_ix(&h, &index, 10 * ONE)], &[&holder])
        .unwrap();
    let owed = bench.redeem_ticket(&index, &h).unwrap().owed;
    let net = 10 * ONE - ONE / 10;
    assert_eq!(owed, vec![net, 2 * net]);
    assert_eq!(
        shares_of(&bench, &index, &creator.pubkey()),
        3 * ONE / 4 + 3 * ONE / 40
    );
    assert_eq!(shares_of(&bench, &index, &p), ONE / 5 + ONE / 40);
    assert_eq!(bench.supply(&shares_pda(&index)), 90 * ONE + ONE / 10);
    bench.assert_invariant(&index);
}

#[test]
fn a_fee_account_is_its_recipients_own() {
    let (mut bench, creator, legs) = two();
    let platform = bench.wallet().pubkey();
    set_policy(&mut bench, 25, 0, 0, platform);
    let terms = IndexTerms {
        platform_fee_bps: 25,
        ..terms()
    };
    let index = bench.create_with(&creator, &legs, terms, false);
    bench.fund(&platform, &shares_pda(&index), &CLASSIC, 0);
    let holder = bench.wallet();
    let h = holder.pubkey();
    bench.issue(&holder, &index, ONE, 2);
    // a stranger's share account in place of the platform's, or none where the policy names one
    let stranger = bench.wallet().pubkey();
    let theirs = bench.fund(&stranger, &shares_pda(&index), &CLASSIC, 0);
    let mut ix = bench.redeem_ix(&h, &index, ONE / 2);
    let at = ix
        .accounts
        .iter()
        .position(|m| m.pubkey == ata(&platform, &shares_pda(&index), &CLASSIC))
        .unwrap();
    ix.accounts[at].pubkey = theirs;
    expect_err(bench.send(&[ix.clone()], &[&holder]), E::WrongFeeAccount);
    ix.accounts[at].pubkey = xindex::ID;
    expect_err(bench.send(&[ix], &[&holder]), E::WrongFeeAccount);
}

#[test]
fn the_streaming_fee_is_a_unit_scale() {
    let (mut bench, creator, legs) = two();
    let terms = IndexTerms {
        creator_streaming_bps: 100,
        ..terms()
    };
    let index = bench.create_with(&creator, &legs, terms, false);
    let holder = bench.wallet();
    let h = holder.pubkey();
    // a year with no shares charges nothing: the clock restarts on every accrual, one that mints nothing included, so
    // the first issue is not charged the idle time (XS-1)
    bench.warp(YEAR);
    bench.issue(&holder, &index, 1_000 * ONE, 2);
    bench.send(&[bench.accrue_ix(&index)], &[&holder]).unwrap();
    assert_eq!(shares_of(&bench, &index, &creator.pubkey()), 0);
    bench.warp(YEAR);
    bench.send(&[bench.accrue_ix(&index)], &[&holder]).unwrap();
    // a year at 1%: the creator holds about a hundredth of the index, and every share's units shrank by as much
    let state = bench.index(&index);
    let minted = shares_of(&bench, &index, &creator.pubkey());
    assert_eq!(minted, 1_000 * ONE * 100 / 9_900);
    assert!(state.header.scale < xindex::SCALE_ONE);
    let supply = bench.supply(&shares_pda(&index));
    assert_eq!(
        state.header.scale as u128,
        xindex::SCALE_ONE as u128 * (1_000 * ONE) as u128 / supply as u128
    );
    bench.assert_invariant(&index);
    // a redeem now owes the backing at the scale: the holder's thousand shares redeem for about 99% of the basket
    bench
        .send(&[bench.redeem_ix(&h, &index, 1_000 * ONE)], &[&holder])
        .unwrap();
    let owed = bench.redeem_ticket(&index, &h).unwrap().owed;
    assert_eq!(
        owed[0],
        xindex::math::backing(1_000 * ONE, 1_000_000_000, state.header.scale, false).unwrap()
    );
    assert!(owed[0] < 1_000 * 1_000_000_000 && owed[0] > 989 * 1_000_000_000);
    bench.assert_invariant(&index);
    // and the clock restarted: a second accrual at once mints nothing
    bench.send(&[bench.accrue_ix(&index)], &[&holder]).unwrap();
    assert_eq!(shares_of(&bench, &index, &creator.pubkey()), minted);
}

#[test]
fn the_creator_role_moves_in_two_steps_and_takes_its_fee_with_it() {
    let (mut bench, creator, legs) = two();
    let terms = IndexTerms {
        creator_streaming_bps: 100,
        ..terms()
    };
    let index = bench.create_with(&creator, &legs, terms, false);
    let holder = bench.wallet();
    bench.issue(&holder, &index, 1_000 * ONE, 2);
    let next = bench.wallet();
    let n = next.pubkey();
    let c = creator.pubkey();
    let offer = xindex::instruction::TransferCreator { pending: n };
    expect_err(
        bench.send(
            &[bench.creator_ix(
                &holder.pubkey(),
                &index,
                anchor_lang::InstructionData::data(&offer),
            )],
            &[&holder],
        ),
        E::NotCreator,
    );
    bench
        .send(
            &[bench.creator_ix(&c, &index, anchor_lang::InstructionData::data(&offer))],
            &[&creator],
        )
        .unwrap();
    expect_err(
        bench.send(
            &[bench.accept_creator_ix(&holder.pubkey(), &index)],
            &[&holder],
        ),
        E::NotPendingCreator,
    );
    // a pending change of weights goes with the role (HK-16)
    bench
        .send(
            &[bench.propose_weights_ix(&c, &index, vec![4_000, 6_000])],
            &[&creator],
        )
        .unwrap();
    bench.warp(YEAR / 2);
    bench
        .send(&[bench.accept_creator_ix(&n, &index)], &[&next])
        .unwrap();
    // what the role earned up to the handover went to the creator who held it (RW-6)
    let earned = shares_of(&bench, &index, &c);
    assert!(earned > 0);
    assert_eq!(bench.index(&index).header.creator_role, n);
    bench.warp(xindex::WEIGHTS_DELAY);
    expect_err(
        bench.send(&[bench.execute_weights_ix(&index)], &[&next]),
        E::NoPendingWeights,
    );
    bench.fund(&n, &shares_pda(&index), &CLASSIC, 0);
    bench.send(&[bench.accrue_ix(&index)], &[&next]).unwrap();
    assert!(shares_of(&bench, &index, &n) > 0);
    assert_eq!(shares_of(&bench, &index, &c), earned);
}

#[test]
fn a_gated_index_issues_to_its_creator_and_the_wallets_it_allows() {
    let (mut bench, creator, legs) = two();
    let platform = bench.wallet().pubkey();
    set_policy(&mut bench, 25, 0, 2_000, platform);
    let terms = IndexTerms {
        platform_fee_bps: 25,
        referral_share_bps: 2_000,
        ..terms()
    };
    let index = bench.create_with(&creator, &legs, terms, true);
    bench.fund(&platform, &shares_pda(&index), &CLASSIC, 0);
    let c = creator.pubkey();
    let holder = bench.wallet();
    let h = holder.pubkey();
    let referrer = bench.wallet().pubkey();
    let referrer_shares = bench.fund(&referrer, &shares_pda(&index), &CLASSIC, 0);
    // a stranger's ticket fills, but its shares cannot go to it
    bench
        .send(&[bench.open_issue_ix(&h, &index, ONE)], &[&holder])
        .unwrap();
    let need = bench.issue_ticket(&index, &h).unwrap().need;
    for (i, leg) in legs.iter().enumerate() {
        let program = bench.program_of(&index, i);
        bench.fund(&h, &leg.mint, &program, need[i]);
        bench
            .send(&[bench.deposit_ix(&h, &index, i as u16)], &[&holder])
            .unwrap();
    }
    let mine = bench.fund(&h, &shares_pda(&index), &CLASSIC, 0);
    expect_err(
        bench.send(&[bench.finalize_ix(&h, &index, &mine)], &[&holder]),
        E::NotAllowedMinter,
    );
    // once the creator allows the holder they may, and the referrer the gate refuses is named nobody (AU-1)
    bench
        .send(&[bench.allow_minter_ix(&c, &index, &h)], &[&creator])
        .unwrap();
    bench
        .send(
            &[bench.finalize_ix_with(
                &h,
                &index,
                &mine,
                Some(referrer_shares),
                Some(minter_pda(&index, &h)),
                None,
            )],
            &[&holder],
        )
        .unwrap();
    assert!(shares_of(&bench, &index, &h) > 0);
    assert_eq!(
        shares_of(&bench, &index, &referrer),
        0,
        "the gate refused the referrer"
    );
    // a disallowed wallet is refused again; an open index issues to anyone, for good
    bench
        .send(&[bench.disallow_minter_ix(&c, &index, &h)], &[&creator])
        .unwrap();
    let open = xindex::instruction::OpenMinting {};
    expect_err(
        bench.send(
            &[bench.creator_ix(&h, &index, anchor_lang::InstructionData::data(&open))],
            &[&holder],
        ),
        E::NotCreator,
    );
    bench
        .send(
            &[bench.creator_ix(&c, &index, anchor_lang::InstructionData::data(&open))],
            &[&creator],
        )
        .unwrap();
    expect_err(
        bench.send(
            &[bench.creator_ix(&c, &index, anchor_lang::InstructionData::data(&open))],
            &[&creator],
        ),
        E::NotGated,
    );
    let stranger = bench.wallet();
    bench.issue(&stranger, &index, ONE, 2);
    assert_eq!(shares_of(&bench, &index, &stranger.pubkey()), ONE);
}

#[test]
fn the_mint_pause_stops_new_shares_and_no_exit() {
    let (mut bench, creator, legs) = two();
    let index = bench.create(&creator, &legs);
    let holder = bench.wallet();
    let h = holder.pubkey();
    bench.issue(&holder, &index, 2 * ONE, 2);
    let guardian = bench.guardian.insecure_clone();
    let g = guardian.pubkey();
    let owner = bench.owner.insecure_clone();
    let stranger = bench.wallet();
    expect_err(
        bench.send(
            &[bench.pause_ix(&stranger.pubkey(), Some(&index), true)],
            &[&stranger],
        ),
        E::NotOwnerOrGuardian,
    );
    // a ticket opened before the pause cannot take a deposit nor finalize under it, and withdraws
    bench
        .send(&[bench.open_issue_ix(&h, &index, ONE)], &[&holder])
        .unwrap();
    let need = bench.issue_ticket(&index, &h).unwrap().need;
    let program = bench.program_of(&index, 0);
    bench.fund(&h, &legs[0].mint, &program, need[0]);
    bench
        .send(&[bench.deposit_ix(&h, &index, 0)], &[&holder])
        .unwrap();
    bench
        .send(&[bench.pause_ix(&g, Some(&index), true)], &[&guardian])
        .unwrap();
    expect_err(
        bench.send(&[bench.deposit_ix(&h, &index, 1)], &[&holder]),
        E::MintingPaused,
    );
    let mine = ata(&h, &shares_pda(&index), &CLASSIC);
    expect_err(
        bench.send(&[bench.finalize_ix(&h, &index, &mine)], &[&holder]),
        E::MintingPaused,
    );
    bench
        .send(&[bench.withdraw_ix(&h, &index, 0)], &[&holder])
        .unwrap();
    bench
        .send(&[bench.cancel_issue_ix(&h, &index)], &[&holder])
        .unwrap();
    expect_err(
        bench.send(&[bench.open_issue_ix(&h, &index, ONE)], &[&holder]),
        E::MintingPaused,
    );
    // a redeem and its claims go on
    bench
        .send(&[bench.redeem_ix(&h, &index, ONE)], &[&holder])
        .unwrap();
    let to = ata(&h, &legs[0].mint, &program);
    bench
        .send(&[bench.claim_ix(&h, &index, 0, u64::MAX, &to)], &[&holder])
        .unwrap();
    // only the owner lifts it; the pause of every index is the same
    expect_err(
        bench.send(&[bench.pause_ix(&g, Some(&index), false)], &[&guardian]),
        E::NotOwnerOrGuardian,
    );
    bench
        .send(
            &[bench.pause_ix(&owner.pubkey(), Some(&index), false)],
            &[&owner],
        )
        .unwrap();
    bench
        .send(&[bench.pause_ix(&g, None, true)], &[&guardian])
        .unwrap();
    expect_err(
        bench.send(&[bench.open_issue_ix(&h, &index, ONE)], &[&holder]),
        E::MintingPaused,
    );
    expect_err(
        bench.send(&[bench.pause_ix(&g, None, false)], &[&guardian]),
        E::NotOwnerOrGuardian,
    );
    bench
        .send(&[bench.pause_ix(&owner.pubkey(), None, false)], &[&owner])
        .unwrap();
    bench.issue(&holder, &index, ONE, 2);
}

#[test]
fn a_price_feed_waits_its_delay_and_the_guardian_cancels_it() {
    let mut bench = Bench::new();
    let mint = bench.mint(T22, 9, Extensions::default());
    bench.list(&mint, &T22);
    let owner = bench.owner.insecure_clone();
    let o = owner.pubkey();
    for (feed, kind) in [([1u8; 32], 0u8), ([0u8; 32], 1), ([1u8; 32], 3)] {
        expect_err(
            bench.send(&[bench.propose_feed_ix(&o, &mint, feed, kind)], &[&owner]),
            E::InvalidPriceFeed,
        );
    }
    bench
        .send(&[bench.propose_feed_ix(&o, &mint, [2; 32], 1)], &[&owner])
        .unwrap();
    expect_err(
        bench.send(&[bench.propose_feed_ix(&o, &mint, [3; 32], 1)], &[&owner]),
        E::PriceFeedPending,
    );
    expect_err(
        bench.send(&[bench.execute_feed_ix(&mint)], &[&owner]),
        E::TooEarly,
    );
    let guardian = bench.guardian.insecure_clone();
    let cancel = anchor_lang::solana_program::instruction::Instruction::new_with_bytes(
        xindex::ID,
        &anchor_lang::InstructionData::data(&xindex::instruction::CancelPriceFeed {}),
        anchor_lang::ToAccountMetas::to_account_metas(
            &xindex::accounts::GuardListing {
                signer: guardian.pubkey(),
                config: config_pda(),
                listing: listing_pda(&mint),
            },
            None,
        ),
    );
    bench
        .send(std::slice::from_ref(&cancel), &[&guardian])
        .unwrap();
    expect_err(bench.send(&[cancel], &[&guardian]), E::NothingPending);
    expect_err(
        bench.send(&[bench.execute_feed_ix(&mint)], &[&owner]),
        E::NothingPending,
    );
    assert_eq!(
        bench.listing(&mint).feed_id,
        feed_of(&mint),
        "the standing feed is kept"
    );
    bench
        .send(&[bench.propose_feed_ix(&o, &mint, [2; 32], 1)], &[&owner])
        .unwrap();
    bench.warp(LISTING_DELAY + xindex::PROPOSAL_WINDOW + 1);
    expect_err(
        bench.send(&[bench.execute_feed_ix(&mint)], &[&owner]),
        E::ProposalExpired,
    );
}

#[test]
fn an_index_is_created_on_its_weights_at_fresh_prices() {
    let (mut bench, creator, legs) = two();
    let c = creator.pubkey();
    let hash = terms_hash(2, &legs);
    let index = index_pda(&c, &hash);
    bench
        .send(&[bench.begin_ix(&c, hash, 2, "X", "X")], &[&creator])
        .unwrap();
    bench
        .send(&[bench.add_legs_ix(&c, &index, &legs)], &[&creator])
        .unwrap();
    // a leg unpriced
    bench.price_at(&index, &[5_000, 5_000]);
    bench
        .send_big(&[bench.price_legs_ix(&c, &index, &[0])], &[&creator])
        .unwrap();
    expect_err(
        bench.send(&[bench.seal_ix(&c, &index)], &[&creator]),
        E::PriceMissing,
    );
    // a leg worth 47.4% of the index against its weight of 50% lies more than 5% of the weight from it
    bench.price_at(&index, &[5_000, 4_500]);
    bench
        .send_big(&[bench.price_legs_ix(&c, &index, &[0, 1])], &[&creator])
        .unwrap();
    expect_err(
        bench.send(&[bench.seal_ix(&c, &index)], &[&creator]),
        E::OffWeights,
    );
    // a price over a minute old at the seal
    bench.price_at(&index, &[5_000, 5_000]);
    bench
        .send_big(&[bench.price_legs_ix(&c, &index, &[0, 1])], &[&creator])
        .unwrap();
    bench.warp(xindex::MAX_CREATION_PRICE_AGE + 1);
    expect_err(
        bench.send(&[bench.seal_ix(&c, &index)], &[&creator]),
        E::StalePrice,
    );
    // 49% against 50% is within it
    bench.price_at(&index, &[5_100, 4_900]);
    bench
        .send_big(&[bench.price_legs_ix(&c, &index, &[0, 1])], &[&creator])
        .unwrap();
    bench
        .send(&[bench.seal_ix(&c, &index)], &[&creator])
        .unwrap();
    // a leg without a feed cannot be priced
    let (mut bench, creator, legs) = two();
    let owner = bench.owner.insecure_clone();
    bench
        .send(
            &[bench.propose_feed_ix(&owner.pubkey(), &legs[0].mint, [0; 32], 0)],
            &[&owner],
        )
        .unwrap();
    bench.warp(LISTING_DELAY);
    bench
        .send(&[bench.execute_feed_ix(&legs[0].mint)], &[&owner])
        .unwrap();
    let c = creator.pubkey();
    let hash = terms_hash(2, &legs);
    let index = index_pda(&c, &hash);
    bench
        .send(&[bench.begin_ix(&c, hash, 2, "X", "X")], &[&creator])
        .unwrap();
    bench
        .send(&[bench.add_legs_ix(&c, &index, &legs)], &[&creator])
        .unwrap();
    expect_err(
        bench.send_big(&[bench.price_legs_ix(&c, &index, &[0])], &[&creator]),
        E::NoPriceFeed,
    );
}
