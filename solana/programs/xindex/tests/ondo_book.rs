// SPDX-License-Identifier: BUSL-1.1
//! Solana's address book of Ondo's tokens (`solana/listing/ondo.json`), against the mint accounts it was read from
//! (`solana/listing/ondo-mints.json`, written by `solana/listing/read_ondo.py`): every mint passes the program's
//! listing check as Ondo deployed it, and two hundred of them make an index.

mod common;

use std::collections::HashSet;

use anchor_lang::prelude::Pubkey;
use base64::Engine;
use common::*;
use serde_json::Value;
use solana_signer::Signer;
use xindex::{state::LegSpec, MAX_COMPONENTS};

const BOOK: &str = include_str!("../../../listing/ondo.json");
const MINTS: &str = include_str!("../../../listing/ondo-mints.json");

fn book() -> Vec<Value> {
    let book: Value = serde_json::from_str(BOOK).unwrap();
    book["tokens"].as_array().unwrap().clone()
}

fn mint_of(token: &Value) -> Pubkey {
    token["mint"].as_str().unwrap().parse().unwrap()
}

#[test]
fn the_book_holds_each_of_ondos_tokens_once() {
    let tokens = book();
    let mut mints = HashSet::new();
    let mut symbols = HashSet::new();
    let mut ethereum = HashSet::new();
    let mut priced_as_tokens = 0;
    for token in &tokens {
        let symbol = token["symbol"].as_str().unwrap();
        assert!(mints.insert(mint_of(token)), "{symbol}: a mint twice");
        assert!(symbols.insert(symbol.to_string()), "{symbol} twice");
        assert!(
            ethereum.insert(token["ethereum"].as_str().unwrap().to_string()),
            "{symbol}: an Ethereum token twice"
        );
        assert!(symbol.ends_with("on"), "{symbol} is not an Ondo symbol");
        assert_eq!(token["decimals"], 9, "{symbol}");
        let feed = token["pythFeed"].as_str().unwrap();
        assert!(
            feed.len() == 66 && feed.starts_with("0x"),
            "{symbol}: feed {feed}"
        );
        assert!(
            token["hookProgram"].is_null(),
            "{symbol} has a transfer hook"
        );
        assert_eq!(
            token["permanentDelegate"], false,
            "{symbol} has a permanent delegate"
        );
        if token["feedKind"] == "token" {
            priced_as_tokens += 1;
        } else {
            assert_eq!(token["feedKind"], "share", "{symbol}");
        }
    }
    assert_eq!(
        priced_as_tokens, 9,
        "Pyth prices nine of Ondo's tokens as tokens"
    );
    let fixtures: Value = serde_json::from_str(MINTS).unwrap();
    assert_eq!(
        fixtures["accounts"].as_object().unwrap().len(),
        tokens.len(),
        "a mint account for every entry"
    );
}

#[test]
fn every_mint_in_the_book_passes_the_listing_check_and_two_hundred_make_an_index() {
    let tokens = book();
    let fixtures: Value = serde_json::from_str(MINTS).unwrap();
    let mut bench = Bench::new();
    // the chain's clock a few hours after the mints were read, so their multipliers stand settled as Ondo left them
    let read_at = 1_795_900_000;
    let now = bench.now();
    bench.warp(read_at - now);
    let owner = bench.owner.insecure_clone();
    let mints: Vec<Pubkey> = tokens.iter().map(mint_of).collect();
    for mint in &mints {
        let data = base64::engine::general_purpose::STANDARD
            .decode(fixtures["accounts"][mint.to_string()].as_str().unwrap())
            .unwrap();
        bench.put_mint(mint, &T22, data);
    }
    // each listed with its Pyth feed: the token's own for the nine Pyth prices as tokens, else the share's, which the
    // mint's multiplier turns into a token's
    let feed = |token: &Value| {
        let hex = token["pythFeed"].as_str().unwrap().trim_start_matches("0x");
        let mut id = [0u8; 32];
        for (k, byte) in id.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&hex[2 * k..2 * k + 2], 16).unwrap();
        }
        let kind = if token["feedKind"] == "token" {
            xindex::pyth::FEED_TOKEN
        } else {
            xindex::pyth::FEED_MULTIPLIER
        };
        (id, kind)
    };
    for chunk in tokens.chunks(4) {
        let ixs: Vec<_> = chunk
            .iter()
            .flat_map(|token| {
                let mint = mint_of(token);
                let (id, kind) = feed(token);
                [
                    bench.propose_listing_ix(&owner.pubkey(), &mint, &T22),
                    bench.propose_feed_ix(&owner.pubkey(), &mint, id, kind),
                ]
            })
            .collect();
        bench.send(&ixs, &[&owner]).unwrap();
    }
    bench.warp(xindex::LISTING_DELAY);
    for chunk in mints.chunks(4) {
        let ixs: Vec<_> = chunk
            .iter()
            .flat_map(|mint| [bench.execute_listing_ix(mint), bench.execute_feed_ix(mint)])
            .collect();
        bench.send(&ixs, &[&owner]).unwrap();
    }
    for (token, mint) in tokens.iter().zip(&mints) {
        let listing = bench.listing(mint);
        assert!(listing.listed, "{}", token["symbol"]);
        assert_eq!(listing.decimals, 9);
        assert_eq!(listing.token_program, T22);
        assert_eq!(
            (listing.feed_id, listing.feed_kind),
            feed(token),
            "{}",
            token["symbol"]
        );
    }

    let creator = bench.wallet();
    bench.approve(&creator.pubkey());
    let legs: Vec<LegSpec> = mints
        .iter()
        .take(MAX_COMPONENTS)
        .map(|mint| LegSpec {
            mint: *mint,
            units: 10_000_000,
            weight: 50,
        })
        .collect();
    // created on its weights at Pyth's prices, each share-priced leg through its mint's own multiplier
    let index = bench.create(&creator, &legs);
    assert!(bench.index(&index).sealed);
    assert_eq!(bench.index(&index).legs.len(), MAX_COMPONENTS);
}
