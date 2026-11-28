// SPDX-License-Identifier: BUSL-1.1
//! Limit orders on LiteSVM: a request escrows in an account of its own, a fill pays the requester first and then takes
//! the escrow, at the basket the request was made on, and the escrow always comes back. Every revert is its exact
//! error.
// LiteSVM's failure carries the whole transaction's metadata, which the tests read; it is large by design.
#![allow(clippy::result_large_err)]

mod common;

use anchor_lang::prelude::Pubkey;
use common::*;
use solana_keypair::Keypair;
use solana_signer::Signer;
use xindex::{
    error::XindexError as E,
    instructions::requests::{MINT_REQUEST, REDEEM_REQUEST},
    state::LegSpec,
    MAX_REQUEST_DURATION, SHARE_UNIT,
};

const ONE: u64 = SHARE_UNIT as u64;
const DOLLARS: u64 = 1_000_000;

struct Fixture {
    bench: Bench,
    index: Pubkey,
    /// A holder of ten shares, who fills mint requests from them.
    filler: Keypair,
}

fn fixture() -> Fixture {
    let mut bench = Bench::new();
    let a = bench.mint(T22, 9, Extensions::ondo());
    let b = bench.mint(CLASSIC, 6, Extensions::default());
    bench.list(&a, &T22);
    bench.list(&b, &CLASSIC);
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
    let index = bench.create(&creator, &legs);
    let filler = bench.wallet();
    bench.issue(&filler, &index, 10 * ONE, 2);
    Fixture {
        bench,
        index,
        filler,
    }
}

#[test]
fn a_mint_request_escrows_its_stablecoin_and_a_fill_pays_the_requester_first() {
    let mut f = fixture();
    let requester = f.bench.wallet();
    let r = requester.pubkey();
    let usdc = f.bench.usdc;
    f.bench.fund(&r, &usdc, &CLASSIC, 100 * DOLLARS);
    let deadline = f.bench.now() + 3_600;
    f.bench
        .send(
            &[f.bench.open_request_ix(
                &r,
                &f.index,
                7,
                MINT_REQUEST,
                100 * DOLLARS,
                2 * ONE,
                deadline,
                Some(0),
            )],
            &[&requester],
        )
        .unwrap();
    let request = request_pda(&r, 7);
    assert_eq!(
        f.bench.balance(&ata(&request, &usdc, &CLASSIC)),
        100 * DOLLARS
    );
    assert_eq!(f.bench.balance(&ata(&r, &usdc, &CLASSIC)), 0);
    // short of the limit, refused; at a hash of other terms, refused
    let p = f.filler.pubkey();
    f.bench.fund(&r, &shares_pda(&f.index), &CLASSIC, 0);
    f.bench.fund(&p, &usdc, &CLASSIC, 0);
    expect_err(
        f.bench.send(
            &[f.bench.fill_request_ix(&p, &r, 7, 2 * ONE - 1, None)],
            &[&f.filler],
        ),
        E::BelowLimit,
    );
    expect_err(
        f.bench.send(
            &[f.bench.fill_request_ix(&p, &r, 7, 2 * ONE, Some([1; 32]))],
            &[&f.filler],
        ),
        E::RequestChanged,
    );
    let hash = xindex::instructions::requests::request_hash(&f.bench.request(&r, 7));
    f.bench
        .send(
            &[f.bench.fill_request_ix(&p, &r, 7, 2 * ONE, Some(hash))],
            &[&f.filler],
        )
        .unwrap();
    assert_eq!(
        f.bench.balance(&ata(&r, &shares_pda(&f.index), &CLASSIC)),
        2 * ONE
    );
    assert_eq!(f.bench.balance(&ata(&p, &usdc, &CLASSIC)), 100 * DOLLARS);
    assert!(
        f.bench
            .svm
            .get_account(&request)
            .is_none_or(|a| a.data.is_empty()),
        "the request is closed"
    );
}

#[test]
fn a_redeem_request_escrows_shares_for_a_stablecoin() {
    let mut f = fixture();
    let p = f.filler.pubkey();
    let usdt = f.bench.usdt;
    let deadline = f.bench.now() + 3_600;
    // the holder of the shares asks for 50 USDT for 3 shares; a buyer of shares fills it
    f.bench
        .send(
            &[f.bench.open_request_ix(
                &p,
                &f.index,
                1,
                REDEEM_REQUEST,
                3 * ONE,
                50 * DOLLARS,
                deadline,
                None,
            )],
            &[&f.filler],
        )
        .unwrap();
    assert_eq!(
        f.bench.balance(&ata(&p, &shares_pda(&f.index), &CLASSIC)),
        7 * ONE
    );
    let buyer = f.bench.wallet();
    let b = buyer.pubkey();
    f.bench.fund(&b, &usdt, &CLASSIC, 50 * DOLLARS);
    f.bench.fund(&p, &usdt, &CLASSIC, 0);
    f.bench.fund(&b, &shares_pda(&f.index), &CLASSIC, 0);
    f.bench
        .send(
            &[f.bench.fill_request_ix(&b, &p, 1, 50 * DOLLARS, None)],
            &[&buyer],
        )
        .unwrap();
    assert_eq!(f.bench.balance(&ata(&p, &usdt, &CLASSIC)), 50 * DOLLARS);
    assert_eq!(
        f.bench.balance(&ata(&b, &shares_pda(&f.index), &CLASSIC)),
        3 * ONE
    );
}

#[test]
fn a_request_takes_only_a_stablecoin_its_index_and_a_deadline_within_thirty_days() {
    let mut f = fixture();
    let requester = f.bench.wallet();
    let r = requester.pubkey();
    let usdc = f.bench.usdc;
    f.bench.fund(&r, &usdc, &CLASSIC, 100 * DOLLARS);
    let now = f.bench.now();
    let other = f.bench.mint(CLASSIC, 6, Extensions::default());
    f.bench.fund(&r, &other, &CLASSIC, 100 * DOLLARS);
    for (pay, deadline, nonce, error) in [
        (other, now + 60, None, E::NotAStable),
        (usdc, now, None, E::BadDeadline),
        (usdc, now + MAX_REQUEST_DURATION + 1, None, E::BadDeadline),
        (usdc, now + 60, Some(1), E::StaleRebalanceNonce),
    ] {
        let mut ix =
            f.bench
                .open_request_ix(&r, &f.index, 1, MINT_REQUEST, DOLLARS, ONE, deadline, nonce);
        if pay != usdc {
            ix = f.bench.open_request_with_ix(
                &r,
                &f.index,
                1,
                MINT_REQUEST,
                &pay,
                DOLLARS,
                ONE,
                deadline,
                nonce,
            );
        }
        expect_err(f.bench.send(&[ix], &[&requester]), error);
    }
}

#[test]
fn a_request_fills_only_at_the_basket_it_was_made_on_and_always_comes_back() {
    let mut f = fixture();
    let requester = f.bench.wallet();
    let r = requester.pubkey();
    let usdc = f.bench.usdc;
    f.bench.fund(&r, &usdc, &CLASSIC, 100 * DOLLARS);
    let deadline = f.bench.now() + 3_600;
    f.bench
        .send(
            &[f.bench.open_request_ix(
                &r,
                &f.index,
                3,
                MINT_REQUEST,
                100 * DOLLARS,
                ONE,
                deadline,
                None,
            )],
            &[&requester],
        )
        .unwrap();
    // the index settles a rebalance: the request no longer fills
    let mut account = f.bench.svm.get_account(&f.index).unwrap();
    let at = 8 + std::mem::offset_of!(xindex::state::Index, rebalance_nonce);
    account.data[at..at + 8].copy_from_slice(&1u64.to_le_bytes());
    f.bench.svm.set_account(f.index, account).unwrap();
    let p = f.filler.pubkey();
    f.bench.fund(&r, &shares_pda(&f.index), &CLASSIC, 0);
    f.bench.fund(&p, &usdc, &CLASSIC, 0);
    expect_err(
        f.bench.send(
            &[f.bench.fill_request_ix(&p, &r, 3, ONE, None)],
            &[&f.filler],
        ),
        E::StaleRebalanceNonce,
    );
    // nobody but the requester closes it before the deadline; the requester does, whole, at any nonce
    expect_err(
        f.bench
            .send(&[f.bench.close_request_ix(&p, &r, 3)], &[&f.filler]),
        E::RequestOpen,
    );
    f.bench
        .send(&[f.bench.close_request_ix(&r, &r, 3)], &[&requester])
        .unwrap();
    assert_eq!(f.bench.balance(&ata(&r, &usdc, &CLASSIC)), 100 * DOLLARS);
    // after its deadline anyone refunds a request, and nobody fills it
    f.bench
        .send(
            &[f.bench.open_request_ix(
                &r,
                &f.index,
                4,
                MINT_REQUEST,
                100 * DOLLARS,
                ONE,
                deadline,
                None,
            )],
            &[&requester],
        )
        .unwrap();
    f.bench.warp(3_601);
    expect_err(
        f.bench.send(
            &[f.bench.fill_request_ix(&p, &r, 4, ONE, None)],
            &[&f.filler],
        ),
        E::RequestExpired,
    );
    f.bench
        .send(&[f.bench.close_request_ix(&p, &r, 4)], &[&f.filler])
        .unwrap();
    assert_eq!(f.bench.balance(&ata(&r, &usdc, &CLASSIC)), 100 * DOLLARS);
}
