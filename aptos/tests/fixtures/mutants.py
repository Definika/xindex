#!/usr/bin/env python3
"""The mutants of the vault's main rules that the tests must kill (README, "Tests"): each is applied to `sources/` in
turn, the whole suite runs, and some test must fail. Every source file is restored after each mutant, whatever
happens; a mutant whose snippet is not found exactly once counts as surviving, so the list cannot rot silently.

From `aptos/`, with the Aptos CLI on the PATH (or in APTOS), after the framework is fetched:

    python3 tests/fixtures/mutants.py
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.abspath(os.path.join(HERE, "..", ".."))
ROOT = os.path.join(PKG, "sources") + os.sep
APTOS = os.environ.get("APTOS", "aptos")

V = "vault.move"
MUTANTS = [
    ("VLT-1: the component inside the array", "snapshot.move",
     "assert!((component as u256) < length, EWrongComponent);", "let _ = length;"),
    ("VLT-1: only this chain's coin", "snapshot.move",
     "assert!(bytes::slice_eq(packed, 12, 20, &vault_token(chain_id)), EWrongComponent);", ""),
    ("VLT-2: the governance delay", V,
     "let ready_at = timestamp::now_seconds() + GOVERNANCE_DELAY;", "let ready_at = timestamp::now_seconds();"),
    ("VLT-2: the freezer cannot drop its replacement", V,
     "assert!(signer::address_of(freezer) == v.freezer && kind != FREEZER_CHANGE, ENotFreezer);",
     "assert!(signer::address_of(freezer) == v.freezer, ENotFreezer);"),
    ("VLT-2: a freeze holds every change but the freezer's", V,
     "assert!(kind == FREEZER_CHANGE || !frozen, EVaultFrozen);", "let _ = frozen;"),
    ("VLT-2: a freeze does not hold the freezer's replacement", V,
     "assert!(kind == FREEZER_CHANGE || !frozen, EVaultFrozen);", "assert!(!frozen, EVaultFrozen);"),
    ("VLT-3: a message waits for the checkpoint", V,
     "assert!(block <= v.checkpoint.block, ENotCheckpointed);", ""),
    ("VLT-4: only both proofs move a mark", V,
     "        if (both) {\n            if (kind == CAP_UPDATE) v.cap_nonce = nonce",
     "        if (true) {\n            if (kind == CAP_UPDATE) v.cap_nonce = nonce"),
    ("VLT-4: a stale nonce is refused", V, "assert!(nonce > last, EStaleGovernance);", "let _ = last;"),
    ("VLT-5: the freezer's freeze after the snapshot", V,
     "ENotFreezer);\n        check_no_snapshot(v);\n        freeze_to(v, vault, timestamp::now_seconds() + FREEZE_DURATION, false);",
     "ENotFreezer);\n        freeze_to(v, vault, timestamp::now_seconds() + FREEZE_DURATION, false);"),
    ("VLT-5: the factory's freeze after the snapshot", V,
     "            check_no_snapshot(v);\n            // A freeze already over", "            // A freeze already over"),
    ("A3-03: a freeze already over freezes nothing", V,
     "if (until > now) freeze_to(v, vault, min(until, now + FREEZE_DURATION), true);",
     "freeze_to(v, vault, min(until, now + FREEZE_DURATION), true);"),
    ("A3-03: a freeze lasts at most FREEZE_DURATION", V,
     "if (until > now) freeze_to(v, vault, min(until, now + FREEZE_DURATION), true);",
     "if (until > now) freeze_to(v, vault, until, true);"),
    ("B4-04: a freeze's body is one word", V, "assert!(body.length() == 32, EBadMessage);", ""),
    ("the snapshot's block bound", V,
     "assert!(v.snapshot.block == 0 || block <= v.snapshot.block, EIssuedAfterSnapshot);", ""),
    ("LG-1: a message runs once", V,
     "assert!(!v.used.contains(id), EAlreadyDelivered);\n        // A cut taken on one proof moves no mark (VLT-4), so it stays "
     "deliverable on both, which moves the mark past an\n        // older raise; until then a replay on one proof only applies it "
     "again (A3-02). A freeze is used up at once.\n        if (both || kind == FREEZE) v.used.add(id, true);",
     "if (both || kind == FREEZE) v.used.upsert(id, true);"),
    ("LG-2: a stale checkpoint keeps the stall", V, "        if (stalled_of(v)) return;\n", ""),
    ("LG-3: only a both-proof message is the last", V, "if (both) v.last_message = id;", "v.last_message = id;"),
    ("LG-4: the lag", "light_client.move",
     "assert!(timestamp::now_seconds() <= lag_ends_of(lc), ELagging);", ""),
    ("LG-4: the lag's last second", "light_client.move",
     "assert!(timestamp::now_seconds() <= lag_ends_of(lc), ELagging);",
     "assert!(timestamp::now_seconds() < lag_ends_of(lc), ELagging);"),
    ("SOL-9: burns", V,
     "        // The vault itself, or its coins' store, would strand the payout (SOL-9).\n        check_recipient(v, vault, recipient);\n        let index",
     "        let index"),
    ("SOL-9: claims", V,
     "        // The vault itself, or its coins' store, would strand the payout (SOL-9).\n        check_recipient(v, vault, recipient);\n        let root",
     "        let root"),
    ("SOL-9: the coins' store", V,
     "assert!(recipient != vault && recipient != object::object_address(&v.store), EWrongRecipient);",
     "assert!(recipient != vault, EWrongRecipient);"),
    ("the speed limit's 4%", V, "const SPEED_LIMIT_PERCENT: u128 = 4;", "const SPEED_LIMIT_PERCENT: u128 = 5;"),
    ("the speed limit's 24-hour window", V, "if (b.hour + BUCKETS > hour)", "if (b.hour + BUCKETS - 1 > hour)"),
    ("one hour's bucket", V, "        if (bucket.hour == hour) {\n            bucket.amount += pay;",
     "        if (bucket.hour == hour) {\n            bucket.amount = pay;"),
    ("a frozen vault pays nothing", V, "let pay = if (now < v.frozen_until) {", "let pay = if (false) {"),
    ("both proofs to move coins: burns", V, "        if (kind == FREEZE) return false;",
     "        if (kind == FREEZE || kind == BURN) return false;"),
    ("both proofs to move coins: migrations", V, "        if (kind == FREEZE) return false;",
     "        if (kind == FREEZE || kind == MIGRATE) return false;"),
    ("both proofs to move coins: failures", V, "        if (kind == FREEZE) return false;",
     "        if (kind == FREEZE || kind == INTAKE_FAILED) return false;"),
    ("the cap's floor loosens too", V, "return cap > v.cap || floor > v.outflow_floor", "return cap > v.cap"),
    ("attest's check", V, "assert!(slot_of(v, slots[i]) == values[i], ENotAttested);", ""),
    ("the record's layout", "abi.move", "out.append(bytes::word64(6 * WORD));", "out.append(bytes::word64(7 * WORD));"),
    ("the record's time in microseconds", V, "timestamp::now_microseconds(), &slots, &values);",
     "timestamp::now_seconds(), &slots, &values);"),
    ("the recovery proposer", V,
     "assert!(signer::address_of(proposer) == v.recovery_proposer, ENotRecoveryProposer);", ""),
    ("continuity (a): the last checkpoint", V,
     "        let last = v.checkpoint;\n        proven_by_both(p1, p2, &last, &proofs.last1, &proofs.last2);\n", ""),
    ("continuity (c): the last message", V, "if (!bytes::is_zero(&v.last_message)) {", "if (false) {"),
    ("the G2 coordinates' order", "proofs.move",
     "        let out = bytes::le32(x_re);\n        out.append(bytes::le32(x_im));",
     "        let out = bytes::le32(x_im);\n        out.append(bytes::le32(x_re));"),
    ("SP1's public-values digest", "proofs.move", "digest[0] &= 0x1f;", "digest[0] &= 0x3f;"),
    ("the pairing's verdict", "proofs.move",
     "assert!(crypto_algebra::eq(&product, &crypto_algebra::zero<Gt>()), EInvalidProof);", "let _ = product;"),
    ("the intake's deadline", V, "assert!(now <= deadline, EIntakeClosed);", ""),
    ("the intake's life", V,
     "assert!((deadline as u128) <= (now as u128) + (MAX_INTAKE_LIFE as u128), EIntakeTooLong);", ""),
    ("the log's emitter", "light_client.move", "ethereum::emitter(&log) == *emitter\n                && ", ""),
    ("the light client's range", "light_client.move", "        ethereum::check_header(header, r.first, r.last);\n", ""),
    ("the update's anchor", "light_client.move", "assert!(anchor_in == lc.anchor, EWrongAnchor);", ""),
    ("the receipt's status", "ethereum.move",
     "assert!(rlp::uint(proof, &rlp::at(proof, &receipt, STATUS)) == 1, EFailedTransaction);", ""),
    ("the route's vault", V, "\n                && abi::vault(m) == bcs::to_bytes(&vault),", ","),
    ("the index digest's paid total", "abi.move", "if (has) out.append(bytes::word64(paid));",
     "if (has) out.append(bytes::word64(balance));"),
    ("held", V, "            v.held -= pay;\n", ""),
    ("the stall's hold on deposits", V, "assert!(!stalled_of(v), EVaultStalled);", ""),
    ("B1-04: no deposit before the first checkpoint", V,
     "assert!(!bytes::is_zero(&v.checkpoint.state_root), ENoCheckpoint);", ""),
    ("B1-05: a cap past 64 bits saturates", V,
     "(abi::saturating(&abi::body_word(body, 3, 1)), abi::saturating(&abi::body_word(body, 3, 2)))",
     "(abi::amount(&abi::body_word(body, 3, 1)), abi::amount(&abi::body_word(body, 3, 2)))"),
    ("B1-06: the claim's domain names Ethereum", V, "v.source_chain_id, &index, &holder", "v.chain_id, &index, &holder"),
    ("B2-02: a floor above the cap", V, "assert!(native_floor <= native_cap, EFloorAboveCap);", ""),
    ("B2-02: the vault's own chain is no source", V, "assert!(source_chain_id == SEPOLIA, EUnknownSource);", ""),
    ("the hub's sent mark", V, "assert!(!bytes::is_zero(&mark), ENotRecorded);", ""),
    ("the hub's settled mark", V, "let settled = !bytes::is_zero(&mark);", "let settled = bytes::is_zero(&mark);"),
    ("only APT is deposited", V, "assert!(fungible_asset::metadata_from_asset(&fa) == apt(), ENotNative);", ""),
    ("nobody owns the vault", V,
     "        object::transfer_with_constructor_ref(&cref, @0x0);\n        object::set_untransferable(&cref);\n        let extend_ref",
     "        let extend_ref"),
    ("the vault cannot be moved", V,
     "        object::transfer_with_constructor_ref(&cref, @0x0);\n        object::set_untransferable(&cref);\n        let extend_ref",
     "        object::transfer_with_constructor_ref(&cref, @0x0);\n        let extend_ref"),
    ("a rotation's pair", V,
     "            check_pair(p1, p2, genesis_of(v), timestamp::now_seconds());\n            v.p1 = p1;", "            v.p1 = p1;"),
    ("B4-02: the anchor's epoch has begun", V,
     "assert!(light_client::epoch_start(p1) <= now && light_client::epoch_start(p2) <= now, EAnchorNotBegun);", ""),
    ("B4-02: an epoch that begins now", V,
     "assert!(light_client::epoch_start(p1) <= now && light_client::epoch_start(p2) <= now, EAnchorNotBegun);",
     "assert!(light_client::epoch_start(p1) < now && light_client::epoch_start(p2) < now, EAnchorNotBegun);"),
    ("B4-03: a pair's roles", V,
     "        assert!(\n            light_client::system(p1) == light_client::sp1() && light_client::system(p2) == light_client::risc_zero(),\n            EWrongVerifier,\n        );\n",
     ""),
    ("B4-03: a pair's genesis", V,
     "assert!(light_client::genesis_time(p1) == genesis && light_client::genesis_time(p2) == genesis, EWrongVerifier);", ""),
    ("B4-03: a successor's pair", V,
     "        check_pair(p1, p2, genesis_of(v), timestamp::now_seconds());\n        // (a)", "        // (a)"),
    ("a governance kind is the factory's", V, "assert!(abi::index(&m) == v.factory, EWrongEmitter);", ""),
    ("a freeze needs one proof only", V, "        if (kind == FREEZE) return false;\n", ""),
    ("the claim signature's signer", "snapshot.move", "assert!(signer == *holder, EBadSignature);", "let _ = signer;"),
    ("the claim signature's low s", "snapshot.move", "&& s <= SECP256K1_HALF_ORDER", ""),
    ("a registered recovery address", V,
     "assert!(registered.destroy_some() == bcs::to_bytes(&recipient), EWrongRecipient);", ""),
    ("a claim once", V, "assert!(!v.owed.contains(key), EAlreadyClaimed);", ""),
    ("the native slice", "bytes.move", "vector::move_range(&mut all, start, len, &mut out, 0);",
     "vector::move_range(&mut all, start + 1, len - 1, &mut out, 0);"),
    ("the native comparison", "bytes.move", "if (copied_natively(v, len)) return slice(v, start, len) == *other;",
     "if (copied_natively(v, len)) return true;"),
]


def run_tests():
    done = subprocess.run(["nice", "-n", "19", APTOS, "move", "test", "--dev", "--skip-fetch-latest-git-deps"], cwd=PKG,
                          capture_output=True, text=True)
    out = done.stdout + done.stderr
    return "Test result: OK" in out, out


def main():
    ok, _ = run_tests()
    assert ok, "the suite fails before any mutant"
    survivors = []
    for name, file, before, after in MUTANTS:
        path = ROOT + file
        original = open(path).read()
        if original.count(before) != 1:
            print(f"SKIP  {name}: the snippet occurs {original.count(before)} times", flush=True)
            survivors.append(name + " (not applied)")
            continue
        try:
            open(path, "w").write(original.replace(before, after))
            ok, out = run_tests()
            if "Test result" not in out:
                print(f"BUILD {name}: the mutant does not compile", flush=True)
                survivors.append(name + " (does not compile)")
            elif ok:
                print(f"LIVES {name}", flush=True)
                survivors.append(name)
            else:
                failed = [l for l in out.splitlines() if "[ FAIL" in l]
                print(f"KILLED {name}: {len(failed)} failing, e.g. {failed[0].split('::')[-1] if failed else '?'}",
                      flush=True)
        finally:
            open(path, "w").write(original)
    ok, _ = run_tests()
    assert ok, "the suite fails after restoring"
    print(f"{len(MUTANTS)} mutants, {len(MUTANTS) - len(survivors)} killed", flush=True)
    for s in survivors:
        print("  not killed:", s, flush=True)
    sys.exit(1 if survivors else 0)


if __name__ == "__main__":
    main()
