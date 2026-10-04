/// The package is meant to be published and made immutable in one transaction: the publish command returns the
/// package's `UpgradeCap`, and the same programmable transaction passes it to `sui::package::make_immutable`, which
/// destroys it, so no key can ever upgrade the code. The package defines no `init`, no capability, no one-time witness
/// and no `Publisher`: nothing is created at publication, and every function gates on an address fixed in the vault's
/// state (the freezer, the recovery proposer) or on nothing. This runs that publication in a scenario, then the vault's
/// life, with no capability anywhere.
#[test_only]
module xindex_vault::immutable_tests;

use sui::package::{Self, UpgradeCap};
use sui::test_scenario as ts;
use xindex_vault::harness;

const ONE: u64 = 1_000_000_000;

#[test]
fun the_package_is_made_immutable_at_publication() {
    let publisher = @0xc4ea7042;
    let mut s = ts::begin(publisher);
    let cap = package::test_publish(object::id_from_address(@xindex_vault), s.ctx());
    assert!(package::version(&cap) == 1);
    package::make_immutable(cap);
    s.next_tx(publisher);
    assert!(!ts::has_most_recent_for_sender<UpgradeCap>(&s));
    s.end();
}

/// The vault's life, end to end, from creation to a payout, with no capability: every call is made by an address the
/// vault names or by anyone.
#[test]
fun the_vaults_life_needs_no_capability() {
    let mut t = harness::new();
    t.fund(1_000 * ONE);
    t.deliver(1, harness::burn_body(10 * ONE, @0xbeef));
    assert!(t.received(@0xbeef) == 10 * ONE);
    t.govern(6, vector[], 1, true, false);
    t.end();
}
