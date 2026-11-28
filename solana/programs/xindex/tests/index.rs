// SPDX-License-Identifier: BUSL-1.1
//! The program against Token-2022 mints built with Ondo's extensions, on LiteSVM with mainnet's features. Every revert is
//! required to be its exact error.

mod common;

use anchor_lang::{
    prelude::Pubkey, solana_program::instruction::Instruction, InstructionData, ToAccountMetas,
};
use common::*;
use solana_keypair::Keypair;
use solana_signer::Signer;
use xindex::{error::XindexError as E, state::LegSpec, MAX_COMPONENTS, MIN_RAW_UNITS};

/// A bench with three listed mints: an Ondo-like Token-2022 mint, a plain Token-2022 mint of 6 decimals and a classic
/// SPL mint, and an approved creator.
fn three() -> (Bench, Keypair, Vec<(Pubkey, Pubkey)>) {
    let mut bench = Bench::new();
    let ondo = bench.mint(T22, 9, Extensions::ondo());
    let plain = bench.mint(T22, 6, Extensions::default());
    let classic = bench.mint(CLASSIC, 8, Extensions::default());
    let mints = vec![(ondo, T22), (plain, T22), (classic, CLASSIC)];
    for (mint, program) in &mints {
        bench.list(mint, program);
    }
    let creator = bench.wallet();
    bench.approve(&creator.pubkey());
    (bench, creator, mints)
}

fn specs(mints: &[(Pubkey, Pubkey)], units: &[u64], weights: &[u16]) -> Vec<LegSpec> {
    mints
        .iter()
        .zip(units)
        .zip(weights)
        .map(|(((mint, _), units), weight)| LegSpec {
            mint: *mint,
            units: *units,
            weight: *weight,
        })
        .collect()
}

// ---------------------------------------------------------------- configuration

#[test]
fn only_the_upgrade_authority_initializes_and_only_once() {
    let mut bench = Bench::deployed();
    let stranger = bench.wallet();
    let (owner, guardian) = (bench.owner.pubkey(), bench.guardian.pubkey());
    let ix = bench.initialize_ix(&stranger.pubkey(), owner, guardian);
    expect_err(bench.send(&[ix], &[&stranger]), E::NotUpgradeAuthority);
    let deployer = bench.deployer.insecure_clone();
    bench
        .send(
            &[bench.initialize_ix(&deployer.pubkey(), owner, guardian)],
            &[&deployer],
        )
        .unwrap();
    bench.warp(1);
    assert!(bench
        .send(
            &[bench.initialize_ix(&deployer.pubkey(), owner, guardian)],
            &[&deployer]
        )
        .is_err());
}

fn owner_only(_bench: &Bench, signer: &Pubkey, data: Vec<u8>) -> Instruction {
    Instruction::new_with_bytes(
        xindex::ID,
        &data,
        xindex::accounts::OwnerOnly {
            owner: *signer,
            config: config_pda(),
        }
        .to_account_metas(None),
    )
}

#[test]
fn the_owner_hands_its_role_on_in_two_steps() {
    let mut bench = Bench::new();
    let next = bench.wallet();
    let stranger = bench.wallet();
    let data = xindex::instruction::TransferOwnership {
        pending_owner: next.pubkey(),
    }
    .data();
    expect_err(
        bench.send(
            &[owner_only(&bench, &stranger.pubkey(), data.clone())],
            &[&stranger],
        ),
        E::NotOwner,
    );
    let owner = bench.owner.insecure_clone();
    bench
        .send(&[owner_only(&bench, &owner.pubkey(), data)], &[&owner])
        .unwrap();
    let accept = |signer: &Pubkey| {
        Instruction::new_with_bytes(
            xindex::ID,
            &xindex::instruction::AcceptOwnership {}.data(),
            xindex::accounts::AcceptOwnership {
                pending_owner: *signer,
                config: config_pda(),
            }
            .to_account_metas(None),
        )
    };
    expect_err(
        bench.send(&[accept(&stranger.pubkey())], &[&stranger]),
        E::NotPendingOwner,
    );
    bench.send(&[accept(&next.pubkey())], &[&next]).unwrap();
    // the old owner lost the role
    let data = xindex::instruction::ProposeGuardian {
        guardian: stranger.pubkey(),
    }
    .data();
    expect_err(
        bench.send(
            &[owner_only(&bench, &owner.pubkey(), data.clone())],
            &[&owner],
        ),
        E::NotOwner,
    );
    bench
        .send(&[owner_only(&bench, &next.pubkey(), data)], &[&next])
        .unwrap();
}

fn execute_guardian_ix() -> Instruction {
    Instruction::new_with_bytes(
        xindex::ID,
        &xindex::instruction::ExecuteGuardian {}.data(),
        xindex::accounts::ExecuteGuardian {
            config: config_pda(),
        }
        .to_account_metas(None),
    )
}

fn cancel_guardian_ix(signer: &Pubkey) -> Instruction {
    Instruction::new_with_bytes(
        xindex::ID,
        &xindex::instruction::CancelGuardian {}.data(),
        xindex::accounts::CancelGuardian {
            signer: *signer,
            config: config_pda(),
        }
        .to_account_metas(None),
    )
}

#[test]
fn a_guardian_change_waits_its_delay_within_its_window() {
    let mut bench = Bench::new();
    let owner = bench.owner.insecure_clone();
    let anyone = bench.wallet();
    let next = bench.wallet();
    expect_err(
        bench.send(&[execute_guardian_ix()], &[&anyone]),
        E::NothingPending,
    );
    let data = xindex::instruction::ProposeGuardian {
        guardian: next.pubkey(),
    }
    .data();
    bench
        .send(
            &[owner_only(&bench, &owner.pubkey(), data.clone())],
            &[&owner],
        )
        .unwrap();
    bench.warp(xindex::GUARDIAN_DELAY - 1);
    expect_err(
        bench.send(&[execute_guardian_ix()], &[&anyone]),
        E::TooEarly,
    );
    bench.warp(1 + xindex::PROPOSAL_WINDOW + 1);
    expect_err(
        bench.send(&[execute_guardian_ix()], &[&anyone]),
        E::ProposalExpired,
    );
    bench
        .send(&[owner_only(&bench, &owner.pubkey(), data)], &[&owner])
        .unwrap();
    bench.warp(xindex::GUARDIAN_DELAY);
    bench.send(&[execute_guardian_ix()], &[&anyone]).unwrap();
    // the new guardian cancels a listing, the old one no longer can
    let mint = bench.mint(T22, 9, Extensions::ondo());
    bench
        .send(
            &[bench.propose_listing_ix(&owner.pubkey(), &mint, &T22)],
            &[&owner],
        )
        .unwrap();
    let old = bench.guardian.insecure_clone();
    expect_err(
        bench.send(
            &[bench.guard_listing_ix(&old.pubkey(), &mint, false)],
            &[&old],
        ),
        E::NotOwnerOrGuardian,
    );
    bench
        .send(
            &[bench.guard_listing_ix(&next.pubkey(), &mint, false)],
            &[&next],
        )
        .unwrap();
}

#[test]
fn the_guardian_cancels_only_its_removal() {
    let mut bench = Bench::new();
    let owner = bench.owner.insecure_clone();
    let guardian = bench.guardian.insecure_clone();
    let next = bench.wallet();
    let replace = xindex::instruction::ProposeGuardian {
        guardian: next.pubkey(),
    }
    .data();
    bench
        .send(&[owner_only(&bench, &owner.pubkey(), replace)], &[&owner])
        .unwrap();
    expect_err(
        bench.send(&[cancel_guardian_ix(&guardian.pubkey())], &[&guardian]),
        E::NotOwnerOrGuardian,
    );
    bench
        .send(&[cancel_guardian_ix(&owner.pubkey())], &[&owner])
        .unwrap();
    expect_err(
        bench.send(&[cancel_guardian_ix(&owner.pubkey())], &[&owner]),
        E::NothingPending,
    );
    let remove = xindex::instruction::ProposeGuardian {
        guardian: Pubkey::default(),
    }
    .data();
    bench
        .send(&[owner_only(&bench, &owner.pubkey(), remove)], &[&owner])
        .unwrap();
    bench
        .send(&[cancel_guardian_ix(&guardian.pubkey())], &[&guardian])
        .unwrap();
}

// ---------------------------------------------------------------- listings

#[test]
fn a_listing_waits_its_delay_within_its_window() {
    let mut bench = Bench::new();
    let owner = bench.owner.insecure_clone();
    let stranger = bench.wallet();
    let mint = bench.mint(T22, 9, Extensions::ondo());
    expect_err(
        bench.send(
            &[bench.propose_listing_ix(&stranger.pubkey(), &mint, &T22)],
            &[&stranger],
        ),
        E::NotOwner,
    );
    bench
        .send(
            &[bench.propose_listing_ix(&owner.pubkey(), &mint, &T22)],
            &[&owner],
        )
        .unwrap();
    bench.warp(1);
    expect_err(
        bench.send(
            &[bench.propose_listing_ix(&owner.pubkey(), &mint, &T22)],
            &[&owner],
        ),
        E::ListingPending,
    );
    bench.warp(xindex::LISTING_DELAY - 2);
    expect_err(
        bench.send(&[bench.execute_listing_ix(&mint)], &[&stranger]),
        E::TooEarly,
    );
    bench.warp(1 + xindex::PROPOSAL_WINDOW + 1);
    expect_err(
        bench.send(&[bench.execute_listing_ix(&mint)], &[&stranger]),
        E::ProposalExpired,
    );
    // a lapsed proposal is proposed again, and anyone executes it
    bench
        .send(
            &[bench.propose_listing_ix(&owner.pubkey(), &mint, &T22)],
            &[&owner],
        )
        .unwrap();
    bench.warp(xindex::LISTING_DELAY);
    bench
        .send(&[bench.execute_listing_ix(&mint)], &[&stranger])
        .unwrap();
    expect_err(
        bench.send(&[bench.execute_listing_ix(&mint)], &[&stranger]),
        E::NothingPending,
    );
    let guardian = bench.guardian.insecure_clone();
    expect_err(
        bench.send(
            &[bench.guard_listing_ix(&stranger.pubkey(), &mint, true)],
            &[&stranger],
        ),
        E::NotOwnerOrGuardian,
    );
    bench
        .send(
            &[bench.guard_listing_ix(&guardian.pubkey(), &mint, true)],
            &[&guardian],
        )
        .unwrap();
    expect_err(
        bench.send(
            &[bench.guard_listing_ix(&guardian.pubkey(), &mint, true)],
            &[&guardian],
        ),
        E::NotListed,
    );
    expect_err(
        bench.send(
            &[bench.guard_listing_ix(&guardian.pubkey(), &mint, false)],
            &[&guardian],
        ),
        E::NothingPending,
    );
}

#[test]
fn ondos_mints_and_classic_mints_are_listable() {
    let mut bench = Bench::new();
    for (program, decimals, extensions) in [
        (T22, 9, Extensions::ondo()),
        (T22, 6, Extensions::default()),
        (CLASSIC, 8, Extensions::default()),
    ] {
        let mint = bench.mint(program, decimals, extensions);
        bench.list(&mint, &program);
    }
}

#[test]
fn a_mint_an_index_cannot_hold_in_kind_is_refused() {
    let mut bench = Bench::new();
    let owner = bench.owner.insecure_clone();
    let hook = Pubkey::new_unique();
    for extensions in [
        Extensions {
            transfer_fee: true,
            ..Extensions::default()
        },
        Extensions {
            permanent_delegate: true,
            ..Extensions::default()
        },
        Extensions {
            non_transferable: true,
            ..Extensions::default()
        },
        Extensions {
            default_frozen: true,
            ..Extensions::default()
        },
        Extensions {
            hook_program: Some(hook),
            ..Extensions::ondo()
        },
    ] {
        let mint = bench.mint(T22, 9, extensions);
        expect_err(
            bench.send(
                &[bench.propose_listing_ix(&owner.pubkey(), &mint, &T22)],
                &[&owner],
            ),
            E::UnlistableMint,
        );
    }
    let wide = bench.mint(T22, 10, Extensions::default());
    expect_err(
        bench.send(
            &[bench.propose_listing_ix(&owner.pubkey(), &wide, &T22)],
            &[&owner],
        ),
        E::TooManyDecimals,
    );
    let classic = bench.mint(CLASSIC, 6, Extensions::default());
    expect_err(
        bench.send(
            &[bench.propose_listing_ix(&owner.pubkey(), &classic, &T22)],
            &[&owner],
        ),
        E::WrongTokenProgram,
    );
}

#[test]
fn a_hook_set_after_the_proposal_stops_the_listing() {
    let mut bench = Bench::new();
    let owner = bench.owner.insecure_clone();
    let mint = bench.mint(T22, 9, Extensions::ondo());
    bench
        .send(
            &[bench.propose_listing_ix(&owner.pubkey(), &mint, &T22)],
            &[&owner],
        )
        .unwrap();
    bench.set_hook(&mint, Some(Pubkey::new_unique()));
    bench.warp(xindex::LISTING_DELAY);
    expect_err(
        bench.send(&[bench.execute_listing_ix(&mint)], &[&owner]),
        E::UnlistableMint,
    );
}

// ---------------------------------------------------------------- creation

#[test]
fn only_an_approved_wallet_creates() {
    let (mut bench, creator, mints) = three();
    let legs = specs(
        &mints,
        &[1_000_000_000, 2_000_000, 300_000_000],
        &[5_000, 3_000, 2_000],
    );
    let hash = terms_hash(3, &legs);
    let stranger = bench.wallet();
    expect_err(
        bench.send(
            &[bench.begin_ix(&stranger.pubkey(), hash, 3, "X", "X")],
            &[&stranger],
        ),
        E::CreatorNotApproved,
    );
    // an approval withdrawn before the seal stops the creation
    let index = index_pda(&creator.pubkey(), &hash);
    bench
        .send(
            &[bench.begin_ix(&creator.pubkey(), hash, 3, "X", "X")],
            &[&creator],
        )
        .unwrap();
    bench
        .send(
            &[bench.add_legs_ix(&creator.pubkey(), &index, &legs)],
            &[&creator],
        )
        .unwrap();
    bench.revoke(&creator.pubkey());
    expect_err(
        bench.send(&[bench.seal_ix(&creator.pubkey(), &index)], &[&creator]),
        E::CreatorNotApproved,
    );
    bench.approve(&creator.pubkey());
    bench.price_on_weights(&creator, &index);
    bench
        .send(&[bench.seal_ix(&creator.pubkey(), &index)], &[&creator])
        .unwrap();
    let state = bench.index(&index);
    assert!(state.sealed);
    assert_eq!(state.share_mint, shares_pda(&index));
    assert_eq!(bench.supply(&state.share_mint), 0);
}

#[test]
fn begin_refuses_a_bad_count_or_name() {
    let (mut bench, creator, _) = three();
    let c = creator.pubkey();
    expect_err(
        bench.send(&[bench.begin_ix(&c, [1; 32], 1, "X", "X")], &[&creator]),
        E::BadLegCount,
    );
    expect_err(
        bench.send(
            &[bench.begin_ix(&c, [2; 32], (MAX_COMPONENTS + 1) as u16, "X", "X")],
            &[&creator],
        ),
        E::BadLegCount,
    );
    let long = "x".repeat(33);
    expect_err(
        bench.send(&[bench.begin_ix(&c, [3; 32], 2, &long, "X")], &[&creator]),
        E::NameTooLong,
    );
    expect_err(
        bench.send(
            &[bench.begin_ix(&c, [4; 32], 2, "X", "ELEVENCHARS")],
            &[&creator],
        ),
        E::NameTooLong,
    );
}

#[test]
fn add_legs_checks_every_leg() {
    let (mut bench, creator, mints) = three();
    let c = creator.pubkey();
    let unlisted = bench.mint(T22, 9, Extensions::ondo());
    let hash = [7u8; 32];
    let index = index_pda(&c, &hash);
    bench
        .send(&[bench.begin_ix(&c, hash, 3, "X", "X")], &[&creator])
        .unwrap();
    let ok = |mint: Pubkey| LegSpec {
        mint,
        units: 1_000_000,
        weight: 1_000,
    };

    // a listing account of another mint
    let mut ix = bench.add_legs_ix(&c, &index, &[ok(mints[0].0)]);
    ix.accounts[3].pubkey = listing_pda(&mints[1].0);
    expect_err(bench.send(&[ix], &[&creator]), E::ListingMismatch);
    // no listing account at all
    let mut ix = bench.add_legs_ix(&c, &index, &[ok(mints[0].0)]);
    ix.accounts.pop();
    expect_err(bench.send(&[ix], &[&creator]), E::ListingMismatch);
    // an unlisted mint, whose listing account does not exist
    expect_err(
        bench.send(
            &[bench.add_legs_ix(&c, &index, &[ok(unlisted)])],
            &[&creator],
        ),
        E::ListingMismatch,
    );
    // a delisted mint
    let guardian = bench.guardian.insecure_clone();
    bench
        .send(
            &[bench.guard_listing_ix(&guardian.pubkey(), &mints[2].0, true)],
            &[&guardian],
        )
        .unwrap();
    expect_err(
        bench.send(
            &[bench.add_legs_ix(&c, &index, &[ok(mints[2].0)])],
            &[&creator],
        ),
        E::NotListed,
    );
    // units outside their bounds: under the floor, and over 1e9 whole tokens of a 6-decimal mint
    let low = LegSpec {
        units: MIN_RAW_UNITS - 1,
        ..ok(mints[0].0)
    };
    expect_err(
        bench.send(&[bench.add_legs_ix(&c, &index, &[low])], &[&creator]),
        E::UnitsOutOfBounds,
    );
    let high = LegSpec {
        units: 1_000_000_000_000_001,
        ..ok(mints[1].0)
    };
    expect_err(
        bench.send(&[bench.add_legs_ix(&c, &index, &[high])], &[&creator]),
        E::UnitsOutOfBounds,
    );
    let exact = LegSpec {
        units: 1_000_000_000_000_000,
        ..ok(mints[1].0)
    };
    // a zero weight, a duplicate in one call and across calls
    let zero = LegSpec {
        weight: 0,
        ..ok(mints[0].0)
    };
    expect_err(
        bench.send(&[bench.add_legs_ix(&c, &index, &[zero])], &[&creator]),
        E::ZeroWeight,
    );
    expect_err(
        bench.send(
            &[bench.add_legs_ix(&c, &index, &[ok(mints[0].0), ok(mints[0].0)])],
            &[&creator],
        ),
        E::DuplicateLeg,
    );
    bench
        .send(
            &[bench.add_legs_ix(&c, &index, &[ok(mints[0].0), exact])],
            &[&creator],
        )
        .unwrap();
    expect_err(
        bench.send(
            &[bench.add_legs_ix(&c, &index, &[ok(mints[0].0)])],
            &[&creator],
        ),
        E::DuplicateLeg,
    );
    // more legs than begun with
    let other = bench.mint(T22, 9, Extensions::ondo());
    bench.list(&other, &T22);
    let extra = bench.mint(T22, 9, Extensions::ondo());
    bench.list(&extra, &T22);
    expect_err(
        bench.send(
            &[bench.add_legs_ix(&c, &index, &[ok(other), ok(extra)])],
            &[&creator],
        ),
        E::TooManyLegs,
    );
    // a stranger cannot add to the creator's index
    let stranger = bench.wallet();
    let ix = bench.add_legs_ix(&stranger.pubkey(), &index, &[ok(other)]);
    assert!(bench.send(&[ix], &[&stranger]).is_err());
}

#[test]
fn seal_checks_the_whole_against_the_terms() {
    let (mut bench, creator, mints) = three();
    let c = creator.pubkey();
    let legs = specs(
        &mints,
        &[1_000_000_000, 2_000_000, 300_000_000],
        &[5_000, 3_000, 2_000],
    );
    // legs missing
    let hash = terms_hash(3, &legs);
    let index = index_pda(&c, &hash);
    bench
        .send(&[bench.begin_ix(&c, hash, 3, "X", "X")], &[&creator])
        .unwrap();
    bench
        .send(&[bench.add_legs_ix(&c, &index, &legs[..2])], &[&creator])
        .unwrap();
    expect_err(
        bench.send(&[bench.seal_ix(&c, &index)], &[&creator]),
        E::LegsMissing,
    );
    // an index is not open before its seal
    let holder = bench.wallet();
    expect_err(
        bench.send(
            &[bench.open_issue_ix(&holder.pubkey(), &index, 1)],
            &[&holder],
        ),
        E::NotSealed,
    );
    bench
        .send(&[bench.add_legs_ix(&c, &index, &legs[2..])], &[&creator])
        .unwrap();
    bench.price_on_weights(&creator, &index);
    bench
        .send(&[bench.seal_ix(&c, &index)], &[&creator])
        .unwrap();
    // a sealed index's price sheet is closed, so a second seal cannot even load it
    let again = bench
        .send(&[bench.seal_ix(&c, &index)], &[&creator])
        .expect_err("a second seal");
    assert!(
        format!("{:?}", again.err).contains("Custom(3007)"),
        "{:?}",
        again.err
    );
    assert!(bench
        .svm
        .get_account(&sheet_pda(&index))
        .is_none_or(|a| a.data.is_empty()));
    expect_err(
        bench.send(&[bench.add_legs_ix(&c, &index, &legs[..1])], &[&creator]),
        E::AlreadySealed,
    );

    // weights that do not make 10,000
    let short = specs(
        &mints,
        &[1_000_000_000, 2_000_000, 300_000_000],
        &[5_000, 3_000, 1_999],
    );
    let hash = terms_hash(3, &short);
    let index = index_pda(&c, &hash);
    bench
        .send(&[bench.begin_ix(&c, hash, 3, "X", "X")], &[&creator])
        .unwrap();
    bench
        .send(&[bench.add_legs_ix(&c, &index, &short)], &[&creator])
        .unwrap();
    expect_err(
        bench.send(&[bench.seal_ix(&c, &index)], &[&creator]),
        E::WeightsNotWhole,
    );

    // legs other than the terms the address commits to: one unit off, or the order swapped
    for altered in [
        specs(
            &mints,
            &[1_000_000_001, 2_000_000, 300_000_000],
            &[5_000, 3_000, 2_000],
        ),
        vec![legs[1], legs[0], legs[2]],
    ] {
        let index = index_pda(&c, &[9u8; 32]);
        if bench.svm.get_account(&index).is_none() {
            bench
                .send(&[bench.begin_ix(&c, [9u8; 32], 3, "X", "X")], &[&creator])
                .unwrap();
            bench
                .send(&[bench.add_legs_ix(&c, &index, &altered)], &[&creator])
                .unwrap();
            expect_err(
                bench.send(&[bench.seal_ix(&c, &index)], &[&creator]),
                E::TermsMismatch,
            );
        }
        let hash = terms_hash(3, &legs);
        let decoy = index_pda(&c, &hash);
        assert_ne!(
            decoy, index,
            "the address of the real terms is another account"
        );
    }
}

// ---------------------------------------------------------------- issue

#[test]
fn an_issue_takes_each_leg_rounded_up_and_mints_the_shares() {
    let (mut bench, creator, mints) = three();
    let legs = specs(
        &mints,
        &[1_500_000_001, 2_000_000, 300_000_000],
        &[5_000, 3_000, 2_000],
    );
    let index = bench.create(&creator, &legs);
    let holder = bench.wallet();
    let shares = 2_000_000_000; // two whole shares
    bench.issue(&holder, &index, shares, 3);
    let state = bench.index(&index);
    assert_eq!(
        bench.balance(&ata(&holder.pubkey(), &state.share_mint, &CLASSIC)),
        shares
    );
    assert_eq!(bench.supply(&state.share_mint), shares);
    // ⌈2e9 · 1,500,000,001 / 1e9⌉ = 3,000,000,002, and so on
    assert_eq!(bench.balance(&bench.vault(&index, 0)), 3_000_000_002);
    assert_eq!(bench.balance(&bench.vault(&index, 1)), 4_000_000);
    assert_eq!(bench.balance(&bench.vault(&index, 2)), 600_000_000);
    assert!(state
        .legs
        .iter()
        .all(|leg| leg.pending == 0 && leg.owed == 0));
    assert!(
        bench.issue_ticket(&index, &holder.pubkey()).is_none(),
        "the ticket closed"
    );
    bench.assert_invariant(&index);

    // one raw share still costs a raw unit of every leg: the rounding is the issuer's
    let dust = bench.wallet();
    bench.issue(&dust, &index, 1, 3);
    assert_eq!(bench.balance(&bench.vault(&index, 0)), 3_000_000_004);
    assert_eq!(bench.balance(&bench.vault(&index, 1)), 4_000_001);
    bench.assert_invariant(&index);
}

#[test]
fn a_ticket_refuses_what_it_does_not_need() {
    let (mut bench, creator, mints) = three();
    let legs = specs(
        &mints,
        &[1_000_000_000, 2_000_000, 300_000_000],
        &[5_000, 3_000, 2_000],
    );
    let index = bench.create(&creator, &legs);
    let holder = bench.wallet();
    let h = holder.pubkey();
    expect_err(
        bench.send(&[bench.open_issue_ix(&h, &index, 0)], &[&holder]),
        E::ZeroShares,
    );
    bench
        .send(
            &[bench.open_issue_ix(&h, &index, 1_000_000_000)],
            &[&holder],
        )
        .unwrap();
    for (i, (mint, program)) in mints.iter().enumerate() {
        let need = bench.issue_ticket(&index, &h).unwrap().need[i];
        bench.fund(&h, mint, program, need * 2);
    }
    // a leg out of range, a mint that is not the leg's, a token program that is not the leg's
    let mut ix = bench.deposit_ix(&h, &index, 0);
    ix.data = xindex::instruction::Deposit { leg: 3 }.data();
    expect_err(bench.send(&[ix], &[&holder]), E::BadLeg);
    let ix = bench.deposit_ix_with(&h, &index, 0, &mints[1].0, &T22);
    expect_err(bench.send(&[ix], &[&holder]), E::WrongLegAccount);
    let ix = bench.deposit_ix_with(&h, &index, 1, &mints[2].0, &CLASSIC);
    expect_err(bench.send(&[ix], &[&holder]), E::WrongLegAccount);

    bench
        .send(&[bench.deposit_ix(&h, &index, 0)], &[&holder])
        .unwrap();
    bench.warp(1);
    expect_err(
        bench.send(&[bench.deposit_ix(&h, &index, 0)], &[&holder]),
        E::NothingToDeposit,
    );
    let shares_account = bench.fund(&h, &shares_pda(&index), &CLASSIC, 0);
    expect_err(
        bench.send(
            &[bench.finalize_ix(&h, &index, &shares_account)],
            &[&holder],
        ),
        E::IssueIncomplete,
    );
    expect_err(
        bench.send(&[bench.cancel_issue_ix(&h, &index)], &[&holder]),
        E::DepositsOutstanding,
    );
    // a withdrawal returns the leg whole and the ticket can close
    let before = bench.balance(&ata(&h, &mints[0].0, &T22));
    bench
        .send(&[bench.withdraw_ix(&h, &index, 0)], &[&holder])
        .unwrap();
    assert_eq!(
        bench.balance(&ata(&h, &mints[0].0, &T22)),
        before + 1_000_000_000
    );
    assert_eq!(bench.index(&index).legs[0].pending, 0);
    bench.warp(1);
    expect_err(
        bench.send(&[bench.withdraw_ix(&h, &index, 0)], &[&holder]),
        E::NothingDeposited,
    );
    bench
        .send(&[bench.cancel_issue_ix(&h, &index)], &[&holder])
        .unwrap();
    assert!(bench.issue_ticket(&index, &h).is_none());
}

#[test]
fn a_deposit_refuses_a_vault_under_what_it_owes() {
    let (mut bench, creator, mints) = three();
    let legs = specs(
        &mints,
        &[1_000_000_000, 2_000_000, 300_000_000],
        &[5_000, 3_000, 2_000],
    );
    let index = bench.create(&creator, &legs);
    let first = bench.wallet();
    bench.issue(&first, &index, 1_000_000_000, 3);
    // the vault of leg 0 loses one raw unit, as after an issuer's burn: a newcomer's deposit would pay for it
    let vault = bench.vault(&index, 0);
    let held = bench.balance(&vault);
    bench.set_balance(&vault, held - 1);
    let next = bench.wallet();
    let n = next.pubkey();
    bench
        .send(&[bench.open_issue_ix(&n, &index, 1_000_000_000)], &[&next])
        .unwrap();
    for (i, (mint, program)) in mints.iter().enumerate() {
        let need = bench.issue_ticket(&index, &n).unwrap().need[i];
        bench.fund(&n, mint, program, need);
    }
    expect_err(
        bench.send(&[bench.deposit_ix(&n, &index, 0)], &[&next]),
        E::Underbacked,
    );
    bench
        .send(&[bench.deposit_ix(&n, &index, 1)], &[&next])
        .unwrap();
    // made whole by anyone, the leg takes deposits again
    bench.set_balance(&vault, held);
    bench
        .send(&[bench.deposit_ix(&n, &index, 0)], &[&next])
        .unwrap();
}

#[test]
fn a_vault_must_receive_what_was_sent() {
    // no listing admits a transfer fee; written in by hand, the deposit still refuses the short credit
    let (mut bench, creator, mints) = three();
    let fee = bench.mint(
        T22,
        9,
        Extensions {
            transfer_fee: true,
            ..Extensions::default()
        },
    );
    let ondo = mints[0].0;
    let listed = listing_pda(&ondo);
    let mut account = bench.svm.get_account(&listed).unwrap();
    // a listing account of the fee mint at its own address, as if it had passed
    let fee_listing = listing_pda(&fee);
    let bump = Pubkey::find_program_address(&[xindex::LISTING_SEED, fee.as_ref()], &xindex::ID).1;
    account.data[8..40].copy_from_slice(fee.as_ref());
    // the listing's bump and feed, after its mint, token program, decimals, flag and eta
    let at = 8 + 32 + 32 + 1 + 1 + 8;
    account.data[at] = bump;
    account.data[at + 1..at + 33].copy_from_slice(&feed_of(&fee));
    bench.svm.set_account(fee_listing, account).unwrap();
    let legs = vec![
        LegSpec {
            mint: fee,
            units: 1_000_000_000,
            weight: 5_000,
        },
        LegSpec {
            mint: mints[1].0,
            units: 1_000_000,
            weight: 5_000,
        },
    ];
    let index = bench.create(&creator, &legs);
    let holder = bench.wallet();
    let h = holder.pubkey();
    bench
        .send(
            &[bench.open_issue_ix(&h, &index, 1_000_000_000)],
            &[&holder],
        )
        .unwrap();
    bench.fund(&h, &fee, &T22, 2_000_000_000);
    expect_err(
        bench.send(&[bench.deposit_ix(&h, &index, 0)], &[&holder]),
        E::ShortDeposit,
    );
}

#[test]
fn a_ticket_from_before_a_rebalance_cannot_finalize() {
    let (mut bench, creator, mints) = three();
    let legs = specs(
        &mints,
        &[1_000_000_000, 2_000_000, 300_000_000],
        &[5_000, 3_000, 2_000],
    );
    let index = bench.create(&creator, &legs);
    let holder = bench.wallet();
    let h = holder.pubkey();
    bench
        .send(
            &[bench.open_issue_ix(&h, &index, 1_000_000_000)],
            &[&holder],
        )
        .unwrap();
    for (i, (mint, program)) in mints.iter().enumerate() {
        let need = bench.issue_ticket(&index, &h).unwrap().need[i];
        bench.fund(&h, mint, program, need);
    }
    bench
        .send(
            &[
                bench.deposit_ix(&h, &index, 0),
                bench.deposit_ix(&h, &index, 1),
            ],
            &[&holder],
        )
        .unwrap();
    // a settled rebalance moves the nonce, written here; the rebalance's own tests settle one
    let mut account = bench.svm.get_account(&index).unwrap();
    let at = 8 + std::mem::offset_of!(xindex::state::Index, rebalance_nonce);
    account.data[at..at + 8].copy_from_slice(&1u64.to_le_bytes());
    bench.svm.set_account(index, account).unwrap();
    assert_eq!(bench.index(&index).rebalance_nonce, 1);
    expect_err(
        bench.send(&[bench.deposit_ix(&h, &index, 2)], &[&holder]),
        E::StaleRebalanceNonce,
    );
    let shares_account = bench.fund(&h, &shares_pda(&index), &CLASSIC, 0);
    expect_err(
        bench.send(
            &[bench.finalize_ix(&h, &index, &shares_account)],
            &[&holder],
        ),
        E::StaleRebalanceNonce,
    );
    // the deposits still come back
    bench
        .send(
            &[
                bench.withdraw_ix(&h, &index, 0),
                bench.withdraw_ix(&h, &index, 1),
            ],
            &[&holder],
        )
        .unwrap();
    bench
        .send(&[bench.cancel_issue_ix(&h, &index)], &[&holder])
        .unwrap();
}

// ---------------------------------------------------------------- redeem

#[test]
fn a_redeem_books_each_leg_rounded_down_and_claims_pay_it() {
    let (mut bench, creator, mints) = three();
    let legs = specs(
        &mints,
        &[1_500_000_001, 2_000_000, 300_000_000],
        &[5_000, 3_000, 2_000],
    );
    let index = bench.create(&creator, &legs);
    let holder = bench.wallet();
    let h = holder.pubkey();
    bench.issue(&holder, &index, 2_000_000_000, 3);
    expect_err(
        bench.send(&[bench.redeem_ix(&h, &index, 0)], &[&holder]),
        E::ZeroShares,
    );
    bench
        .send(&[bench.redeem_ix(&h, &index, 1)], &[&holder])
        .unwrap();
    bench
        .send(&[bench.redeem_ix(&h, &index, 999_999_999)], &[&holder])
        .unwrap();
    let owed = bench.redeem_ticket(&index, &h).unwrap().owed;
    // ⌊1 · 1,500,000,001 / 1e9⌋ + ⌊999,999,999 · 1,500,000,001 / 1e9⌋ = 1 + 1,499,999,999
    assert_eq!(owed, vec![1_500_000_000, 1_999_999, 299_999_999]);
    let state = bench.index(&index);
    assert_eq!(bench.supply(&state.share_mint), 1_000_000_000);
    assert_eq!(
        state.legs.iter().map(|leg| leg.owed).collect::<Vec<_>>(),
        owed
    );
    bench.assert_invariant(&index);

    let to: Vec<Pubkey> = mints
        .iter()
        .map(|(mint, program)| bench.fund(&h, mint, program, 0))
        .collect();
    expect_err(
        bench.send(&[bench.close_redeem_ix(&h, &index)], &[&holder]),
        E::ClaimsOutstanding,
    );
    // a part, then the rest; a claim beyond what is owed pays what is owed
    bench
        .send(
            &[bench.claim_ix(&h, &index, 0, 500_000_000, &to[0])],
            &[&holder],
        )
        .unwrap();
    assert_eq!(bench.balance(&to[0]), 500_000_000);
    bench
        .send(
            &[bench.claim_ix(&h, &index, 0, u64::MAX, &to[0])],
            &[&holder],
        )
        .unwrap();
    assert_eq!(bench.balance(&to[0]), 1_500_000_000);
    bench.warp(1);
    expect_err(
        bench.send(
            &[bench.claim_ix(&h, &index, 0, u64::MAX, &to[0])],
            &[&holder],
        ),
        E::NothingOwed,
    );
    bench
        .send(
            &[
                bench.claim_ix(&h, &index, 1, u64::MAX, &to[1]),
                bench.claim_ix(&h, &index, 2, u64::MAX, &to[2]),
            ],
            &[&holder],
        )
        .unwrap();
    bench.assert_invariant(&index);
    bench
        .send(&[bench.close_redeem_ix(&h, &index)], &[&holder])
        .unwrap();
    assert!(bench.redeem_ticket(&index, &h).is_none());
    // what is left backs the shares still out
    assert_eq!(
        bench.balance(&bench.vault(&index, 0)),
        3_000_000_002 - 1_500_000_000
    );
}

#[test]
fn a_paused_or_frozen_leg_never_stands_between_a_holder_and_the_others() {
    let (mut bench, creator, mints) = three();
    let legs = specs(
        &mints,
        &[1_000_000_000, 2_000_000, 300_000_000],
        &[5_000, 3_000, 2_000],
    );
    let index = bench.create(&creator, &legs);
    let holder = bench.wallet();
    let h = holder.pubkey();
    bench.issue(&holder, &index, 1_000_000_000, 3);
    let to: Vec<Pubkey> = mints
        .iter()
        .map(|(mint, program)| bench.fund(&h, mint, program, 0))
        .collect();

    // Ondo pauses its token and freezes the vault of the plain mint
    bench.pause(&mints[0].0, true);
    let vault1 = bench.vault(&index, 1);
    bench.freeze(&vault1, &mints[1].0, &T22, true);
    bench
        .send(&[bench.redeem_ix(&h, &index, 1_000_000_000)], &[&holder])
        .unwrap();
    expect_log(
        bench.send(
            &[bench.claim_ix(&h, &index, 0, u64::MAX, &to[0])],
            &[&holder],
        ),
        "paused",
    );
    expect_log(
        bench.send(
            &[bench.claim_ix(&h, &index, 1, u64::MAX, &to[1])],
            &[&holder],
        ),
        "frozen",
    );
    bench
        .send(
            &[bench.claim_ix(&h, &index, 2, u64::MAX, &to[2])],
            &[&holder],
        )
        .unwrap();
    assert_eq!(bench.balance(&to[2]), 300_000_000);

    // a hook set on the mint holds the leg the same way: no transfer here passes its accounts
    bench.pause(&mints[0].0, false);
    bench.set_hook(&mints[0].0, Some(Pubkey::new_unique()));
    assert!(bench
        .send(
            &[bench.claim_ix(&h, &index, 0, u64::MAX, &to[0])],
            &[&holder]
        )
        .is_err());
    bench.set_hook(&mints[0].0, None);
    bench.freeze(&vault1, &mints[1].0, &T22, false);
    bench.warp(1);
    bench
        .send(
            &[
                bench.claim_ix(&h, &index, 0, u64::MAX, &to[0]),
                bench.claim_ix(&h, &index, 1, u64::MAX, &to[1]),
            ],
            &[&holder],
        )
        .unwrap();
    assert_eq!(bench.balance(&to[0]), 1_000_000_000);
    assert_eq!(bench.balance(&to[1]), 2_000_000);
    bench.assert_invariant(&index);
}

#[test]
fn a_frozen_vault_takes_no_deposit() {
    let (mut bench, creator, mints) = three();
    let legs = specs(
        &mints,
        &[1_000_000_000, 2_000_000, 300_000_000],
        &[5_000, 3_000, 2_000],
    );
    let index = bench.create(&creator, &legs);
    let first = bench.wallet();
    bench.issue(&first, &index, 1_000_000_000, 3);
    bench.freeze(&bench.vault(&index, 0), &mints[0].0, &T22, true);
    let next = bench.wallet();
    let n = next.pubkey();
    bench
        .send(&[bench.open_issue_ix(&n, &index, 1_000_000_000)], &[&next])
        .unwrap();
    bench.fund(&n, &mints[0].0, &T22, 1_000_000_000);
    expect_log(
        bench.send(&[bench.deposit_ix(&n, &index, 0)], &[&next]),
        "frozen",
    );
}

// ---------------------------------------------------------------- two hundred legs

#[test]
fn two_hundred_legs_create_issue_and_redeem_within_solanas_limits() {
    let mut bench = Bench::new();
    let creator = bench.wallet();
    bench.approve(&creator.pubkey());
    let mut legs = Vec::new();
    for i in 0..MAX_COMPONENTS {
        let mint = bench.mint(T22, 9, Extensions::ondo());
        bench.list(&mint, &T22);
        legs.push(LegSpec {
            mint,
            units: 1_000_000 + i as u64,
            weight: 50,
        });
    }
    let index = bench.create(&creator, &legs);
    // the first issue creates each vault: an account's creation takes six of a transaction's 64 instruction-trace
    // entries, so nine such deposits fit one transaction
    let first = bench.wallet();
    let creating = bench.issue(&first, &index, 5_000_000_000, 9);
    // once the vaults exist, eighteen: 9 shared accounts and 3 a leg make 63, under the lock limit of 64
    let holder = bench.wallet();
    let most = bench.issue(&holder, &index, 5_000_000_000, 18);
    assert!(
        creating <= 1_400_000 && most <= 1_400_000,
        "deposit transactions spent {creating} and {most} units"
    );
    assert_eq!(bench.supply(&shares_pda(&index)), 10_000_000_000);
    bench.assert_invariant(&index);
    let h = holder.pubkey();
    let sent = bench
        .send_big(&[bench.redeem_ix(&h, &index, 5_000_000_000)], &[&holder])
        .unwrap();
    assert!(
        sent.compute_units_consumed <= 1_400_000,
        "redeem spent {}",
        sent.compute_units_consumed
    );
    println!(
        "200 legs: 9 deposits creating vaults spent at most {creating} units, 18 deposits {most}, a redeem {}",
        sent.compute_units_consumed
    );
    let owed = bench.redeem_ticket(&index, &h).unwrap().owed;
    assert_eq!(owed[199], 5 * 1_000_199);
    bench.assert_invariant(&index);
}
