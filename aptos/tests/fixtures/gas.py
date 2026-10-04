#!/usr/bin/env python3
"""Estimates the gas of the vault's calls from the unit tests, since Aptos's unit-test runner meters no gas.

Each pair in `tests/gas_tests.move` (`gas_*_base`, `gas_*_call`) is run alone with `aptos move test --coverage`, whose
coverage map counts how many times every instruction ran. The difference is the call's instructions:

- this package's are priced by opcode, read from `aptos move coverage bytecode`, at mainnet's gas schedule
  (`gas-schedule-mainnet.json`, feature version 53, fetched read-only);
- the framework's, which that command does not disassemble, at the average cost of this package's;
- the natives the call reaches are counted from the framework functions that wrap them (BN254's deserializations,
  multi-scalar multiplication and pairing, tables, events, secp256k1) and priced by the schedule's formulas; a hash's
  input size is an assumption, written below.

Storage IO, the per-transaction charges (intrinsic, dependencies) and the storage fee are counted from what each call
reads, writes and creates, listed per call below by hand. The result is an estimate: within some tens of percent for
the calls the natives dominate (P1 and P2), less precise for the others. A real figure needs `aptos move simulate`.

From `aptos/`, with the Aptos CLI on the PATH (or in APTOS), after the framework is fetched:

    python3 tests/fixtures/gas.py
"""

import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.abspath(os.path.join(HERE, "..", ".."))
APTOS = os.environ.get("APTOS", "aptos")
FLAGS = ["--dev", "--skip-fetch-latest-git-deps"]
MODULES = ["abi", "bytes", "ethereum", "light_client", "mpt", "proofs", "rlp", "snapshot", "state_reader", "vault"]
SCHEDULE = json.load(open(os.path.join(HERE, "gas-schedule-mainnet.json")))["entries"]
SCALE = SCHEDULE["txn.gas_unit_scaling_factor"]


def aptos(*args):
    done = subprocess.run(["nice", "-n", "19", APTOS, "move", *args, *FLAGS], cwd=PKG, capture_output=True, text=True)
    return done.stdout + done.stderr


# ---------------------------------------------------------------------------------------------------------------------
# The coverage map: BCS of `CoverageMap { exec_maps: BTreeMap<String, ExecCoverageMap> }`, each module's functions a
# `BTreeMap<u64 pc, u64 count>`.
# ---------------------------------------------------------------------------------------------------------------------


def read_coverage(path):
    b = open(path, "rb").read()
    at = [0]

    def uleb():
        n = shift = 0
        while True:
            x = b[at[0]]
            at[0] += 1
            n |= (x & 0x7F) << shift
            shift += 7
            if x < 0x80:
                return n

    def string():
        n = uleb()
        s = b[at[0]: at[0] + n].decode()
        at[0] += n
        return s

    def u64():
        x = int.from_bytes(b[at[0]: at[0] + 8], "little")
        at[0] += 8
        return x

    def address():
        a = b[at[0]: at[0] + 32].hex()
        at[0] += 32
        return a

    counts = {}
    for _ in range(uleb()):
        string()
        string()
        for _ in range(uleb()):
            address()
            string()
            addr, module = address(), string()
            for _ in range(uleb()):
                function = string()
                for _ in range(uleb()):
                    pc, n = u64(), u64()
                    counts[(addr, module, function, pc)] = n
    return counts


def run_test(name):
    out = aptos("test", "--filter", f"gas_tests::{name}", "--coverage")
    assert "Test result: OK. Total tests: 1;" in out, f"{name}: {out[-2000:]}"
    return read_coverage(os.path.join(PKG, ".coverage_map.mvcov"))


# ---------------------------------------------------------------------------------------------------------------------
# Opcodes of this package's functions, from the disassembly `aptos move coverage bytecode` prints.
# ---------------------------------------------------------------------------------------------------------------------

HEADER = re.compile(r"^\s*(?:#\[[^\]]*\]\s*)*(?:public(?:\([a-z]+\))?\s+)?(?:entry\s+)?(?:inline\s+)?fun\s+(\w+)")


def opcodes():
    table = {}
    for module in MODULES:
        out = re.sub(r"\x1b\[[0-9;]*m", "", aptos("coverage", "bytecode", "--module", module))
        function, pc = None, 0
        for line in out.splitlines():
            m = HEADER.match(line)
            if m:
                function, pc = m.group(1), 0
                continue
            s = line.strip()
            if (function is None or not s or s.startswith(("//", "local ", "#[", "\"", "{", "}", "use ", "module "))
                    or s.endswith(":") and not re.match(r"^l\d+:", s)):
                continue
            s = re.sub(r"^l\d+:\s*", "", s)
            table[(module, function, pc)] = s
            pc += 1
    return table


def instruction_cost(text):
    """An instruction's cost in internal gas units, from its mnemonic; a call at its base and two args and locals."""
    op = re.sub(r"<.*$", "", text.split()[0])
    if op in ("call", "call_generic"):
        return SCHEDULE["instr.call.base"] + 2 * SCHEDULE["instr.call.per_arg"] + 2 * SCHEDULE["instr.call.per_local"]
    if op == "ld_const":
        return SCHEDULE["instr.ld_const.base"] + 32 * SCHEDULE["instr.ld_const.per_byte"]
    aliases = {
        "borrow_loc": "imm_borrow_loc", "borrow_field": "imm_borrow_field", "borrow_global": "imm_borrow_global",
        "borrow_field_generic": "imm_borrow_field_generic", "vec_borrow": "vec_imm_borrow",
        "borrow_variant_field": "imm_borrow_variant_field", "shl": "bit_shl", "shr": "bit_shr",
    }
    op = aliases.get(op, op)
    for key in (f"instr.{op}", f"instr.{op}.base"):
        if key in SCHEDULE:
            return SCHEDULE[key]
    return None


# ---------------------------------------------------------------------------------------------------------------------
# Natives, counted from the framework functions that call them.
# ---------------------------------------------------------------------------------------------------------------------


def fn_calls(counts, module, function):
    return sum(n for (a, m, f, pc), n in counts.items() if m == module and f == function and pc == 0)


def natives(diff, groth16_checks):
    s = SCHEDULE
    cost = 0
    notes = []
    # BN254: per Groth16 check, 9 G1 and 4 G2 points read uncompressed (with their subgroup checks) and 5 scalars, one
    # multi-scalar multiplication of 6 points, and a multi-pairing of 4.
    if groth16_checks:
        g = groth16_checks
        pairing = s["aptos_framework.algebra.ark_bn254_multi_pairing_base"] + 4 * s[
            "aptos_framework.algebra.ark_bn254_multi_pairing_per_pair"]
        deser = (9 * s["aptos_framework.algebra.ark_bn254_g1_affine_deser_uncomp"]
                 + 4 * s["aptos_framework.algebra.ark_bn254_g2_affine_deser_uncomp"]
                 + 5 * s["aptos_framework.algebra.ark_bn254_fr_deser"])
        # The schedule names no MSM cost for BN254; priced here as 6 scalar multiplications and 5 additions, an upper
        # bound on a windowed MSM.
        msm = 6 * s["aptos_framework.algebra.ark_bn254_g1_proj_scalar_mul"] + 5 * s[
            "aptos_framework.algebra.ark_bn254_g1_proj_add"]
        cost += g * (pairing + deser + msm + s["aptos_framework.algebra.ark_bn254_fq12_eq"])
        notes.append(f"BN254 per check: pairing {pairing / SCALE:.0f}, points {deser / SCALE:.0f}, MSM <= {msm / SCALE:.0f}")
    # Tables: each operation's base and its key's bytes (about 100); each key's first load in a transaction is counted
    # with the IO below.
    table_ops = sum(fn_calls(diff, "table", f) for f in ("add", "borrow", "borrow_mut", "contains", "upsert",
                                                        "borrow_mut_with_default"))
    cost += table_ops * (s["table.add_box.base"] + 100 * s["table.add_box.per_byte_serialized"])
    events = fn_calls(diff, "event", "emit")
    cost += events * (s["aptos_framework.event.write_to_event_store.base"]
                      + 200 * s["aptos_framework.event.write_to_event_store.per_abstract_memory_unit"])
    recovers = fn_calls(diff, "secp256k1", "ecdsa_recover")
    cost += recovers * s["aptos_framework.secp256k1.ecdsa_recover"]
    return cost, table_ops, events, notes


def native_slices(diff, ops, buffer):
    """`bytes::slice`'s native copies: each copies a string of about `buffer` bytes (`read_ref`, by its size) and moves
    the slice out of it (`vector::move_range`, by the bytes it moves, at most the string)."""
    n = sum(c for (a, m, f, pc), c in diff.items() if "move_range" in ops.get((m, f, pc), ""))
    per = (SCHEDULE["move_stdlib.vector.move_range.base"]
           + buffer * (SCHEDULE["instr.read_ref.per_abs_val_unit"] + SCHEDULE["move_stdlib.vector.move_range.per_index_moved"]))
    return n, n * per


def keccaks(diff, ops, hashed):
    """Calls to keccak256 from this package, at an assumed 200 bytes each, and `hashed` bytes more: the receipts'
    leaves, the long inputs."""
    n = sum(c for (a, m, f, pc), c in diff.items() if "keccak256" in ops.get((m, f, pc), ""))
    per = SCHEDULE["aptos_framework.hash.keccak256.per_byte"]
    return n, n * (SCHEDULE["aptos_framework.hash.keccak256.base"] + 200 * per) + hashed * per


# ---------------------------------------------------------------------------------------------------------------------
# What each call reads, writes and creates, by hand: (slots read with bytes each, slots written with bytes, new slots
# with bytes, events with bytes, transaction bytes, modules loaded).
# ---------------------------------------------------------------------------------------------------------------------

VAULT = 900  # the `Vault` resource's bytes, about
# A transaction's bytes besides its arguments: its sender, sequence number, gas fields, expiry, chain id, the function's
# name and an Ed25519 authenticator.
ENVELOPE = 250


def fixture_len(name):
    text = open(os.path.join(PKG, "tests", "fixtures.move")).read()
    return len(re.search(r"fun " + name + r"\(\): vector<u8> \{ x\"([0-9a-f]*)\" \}", text).group(1)) // 2


def module_sizes():
    sizes = {}
    root = os.path.join(PKG, "build", "xindex_vault", "bytecode_modules")
    for d, _, files in os.walk(root):
        for f in files:
            if f.endswith(".mv"):
                sizes[f[:-3]] = os.path.getsize(os.path.join(d, f))
    return sizes
CALLS = {
    # deposit: the vault, its store and the depositor's (object cores and stores), APT's metadata, the clock; the index,
    # the intake, the deposit and the intake's slot entries, three of them new.
    "deposit": dict(pair="deposit", reads=[VAULT, 100, 100, 100, 100, 200, 50] + [150, 150, 100, 100],
                    writes=[VAULT, 100, 100, 150, 100, 100], new=[150, 100, 100], events=[200, 150, 150],
                    tx=ENVELOPE + 32 + 21 + 33 + 8, checks=0),
    # deliver of a settle, both proofs: the vault, P1 and P2, the clock; the used mark (new), the index and its slot,
    # the intake and its slot, and each client's range.
    "deliver settle": dict(pair="settle", buffer=fixture_len("gas_settle_proof"),
                           hashed=2 * fixture_len("gas_settle_proof"), reads=[VAULT, 150, 150, 50] + [100, 300, 150, 100, 100, 100, 100],
                           writes=[VAULT, 300, 150, 100, 100, 100], new=[100], events=[200, 200],
                           tx=ENVELOPE + 32 + 8 + 3 * 3 + fixture_len("gas_settle") + 2 * fixture_len("gas_settle_proof"),
                           checks=0),
    # deliver of a burn, both proofs, 40 APT paid: as a settle, with the owed entry (new), and the payout's withdrawal
    # and deposit (the vault's store, and the recipient's primary store created, one slot for its object's resources).
    "deliver burn": dict(pair="burn", buffer=fixture_len("gas_burn_proof"),
                         hashed=2 * fixture_len("gas_burn_proof"), reads=[VAULT, 150, 150, 50] + [100, 300, 100, 100, 100, 100, 200, 100, 100],
                         writes=[VAULT, 300, 150, 100, 100, 100, 100, 100], new=[100, 150, 300],
                         events=[200, 200, 200, 200, 150, 150],
                         tx=ENVELOPE + 32 + 8 + 3 * 3 + fixture_len("gas_burn") + 2 * fixture_len("gas_burn_proof"),
                         checks=0),
    # attest, three slots: the vault, the clock, three slot entries; one event of 450 bytes.
    "attest": dict(pair="attest", reads=[VAULT, 50, 100, 100, 100], writes=[], new=[], events=[450],
                   tx=ENVELOPE + 32 + 2 + 6 * 33, checks=0),
    # P1's update: the client, the clock and the features; its range (new); the check and the step.
    "P1 update (SP1)": dict(pair=("sp1", "step"), buffer=356, reads=[300, 50, 100, 100], writes=[300, 100], new=[100],
                            events=[200], tx=ENVELOPE + 32 + 2 + 192 + 2 + 356, checks=1),
    "P2 update (RISC Zero)": dict(pair=("risc0", "step"), buffer=260, reads=[300, 50, 100, 100], writes=[300, 100], new=[100],
                                  events=[200], tx=ENVELOPE + 32 + 2 + 192 + 2 + 260, checks=1),
    # One event proof whose receipt also holds another log of 8 or 32 KB (LG-1): the walk alone, as part of a deliver.
    "event proof, 8 KB of other logs": dict(pair="bloat8", buffer=fixture_len("bloated_8000_proof"),
                                            hashed=fixture_len("bloated_8000_proof"), reads=[], writes=[], new=[], events=[], tx=0, checks=0,
                                            walk_only=True),
    "event proof, 32 KB of other logs": dict(pair="bloat32", buffer=fixture_len("bloated_32000_proof"),
                                             hashed=fixture_len("bloated_32000_proof"), reads=[], writes=[], new=[], events=[], tx=0, checks=0,
                                             walk_only=True),
}


def main():
    ops = opcodes()
    sizes = module_sizes()
    priced = [(k, instruction_cost(v)) for k, v in ops.items()]
    unknown = sorted({ops[k].split()[0] for k, c in priced if c is None})
    if unknown:
        print("unpriced opcodes, at the average:", ", ".join(unknown))
    known = [c for _, c in priced if c is not None]
    average = sum(known) / len(known)
    runs = {}

    def counts(name):
        if name not in runs:
            runs[name] = run_test(name)
        return runs[name]

    def difference(call, base):
        a, b = counts(call), counts(base)
        return {k: a.get(k, 0) - b.get(k, 0) for k in set(a) | set(b) if a.get(k, 0) != b.get(k, 0)}

    s = SCHEDULE
    rows = []
    for label, c in CALLS.items():
        if isinstance(c["pair"], tuple):
            check, step = c["pair"]
            diff = difference(f"gas_{check}_call", "gas_check_base")
            for k, v in difference("gas_step_call", "gas_step_base").items():
                diff[k] = diff.get(k, 0) + v
        else:
            diff = difference(f"gas_{c['pair']}_call", f"gas_{c['pair']}_base")
        own = framework = 0
        cost = plain_cost = plain = 0
        for (a, m, f, pc), n in diff.items():
            if m in MODULES and a.endswith("c0de"):
                own += n
                op = ops.get((m, f, pc))
                unit = instruction_cost(op) if op else None
                cost += n * (unit if unit is not None else average)
                if op and not op.startswith("call") and unit is not None:
                    plain_cost += n * unit
                    plain += n
            else:
                framework += n
        # The framework's instructions, which cannot be disassembled here, at this call's own mix: without its calls
        # (as a loop such as `vector::slice` runs) for the low figure, with them for the high one.
        low_unit = plain_cost / plain if plain else average
        high_unit = (cost / own) if own else average
        cost_low = cost + framework * low_unit
        cost += framework * high_unit
        native, table_ops, events, notes = natives(diff, c["checks"])
        hashes, hash_cost = keccaks(diff, {(m, f, pc): v for (m, f, pc), v in ops.items()}, c.get("hashed", 0))
        copies, copy_cost = native_slices(diff, ops, c.get("buffer", 0))
        execution = cost + native + hash_cost + copy_cost
        execution_low = cost_low + native + hash_cost + copy_cost
        io = (sum(s["txn.storage_io_per_state_slot_read"] + n * s["txn.storage_io_per_state_byte_read"] for n in c["reads"])
              + sum(s["txn.storage_io_per_state_slot_write"] + n * s["txn.storage_io_per_state_byte_write"]
                    for n in c["writes"] + c["new"])
              + sum(n * s["txn.storage_io_per_event_byte_write"] for n in c["events"])
              + c["tx"] * s["txn.storage_io_per_transaction_byte_write"])
        intrinsic = s["txn.min_transaction_gas_units"] + max(0, c["tx"] - s["txn.large_transaction_cutoff"]) * s[
            "txn.intrinsic_gas_per_byte"]
        loaded = {m for (a, m, f, pc) in diff}
        dependencies = sum(s["txn.dependency_per_module"] + sizes.get(m, 6000) * s["txn.dependency_per_byte"]
                           for m in loaded)
        if c.get("walk_only"):
            intrinsic = dependencies = 0
        fee = sum(s["txn.storage_fee_per_state_slot"] + n * s["txn.storage_fee_per_state_byte"] for n in c["new"])
        total = (execution + io + intrinsic + dependencies) / SCALE
        total_low = (execution_low + io + intrinsic + dependencies) / SCALE
        rows.append((label, own, framework, (execution_low / SCALE, execution / SCALE), io / SCALE,
                     (intrinsic + dependencies) / SCALE, (total_low, total),
                     fee, len(c["new"]), notes + [f"{len(loaded)} modules, {c['tx']} transaction bytes, {hashes} keccaks, {copies} native slices"]))
    print(f"average instruction: {average:.0f} internal units")
    print("| Call | Instructions (package / framework) | Execution | IO | Intrinsic and modules | Gas units | "
          "Storage fee |")
    print("|---|---|---|---|---|---|---|")
    for label, own, framework, ex, io, fixed, total, fee, new, notes in rows:
        print(f"| {label} | {own:,} / {framework:,} | {ex[0]:,.0f}-{ex[1]:,.0f} | {io:,.0f} | {fixed:,.0f} | "
              f"{total[0]:,.0f}-{total[1]:,.0f} | {fee:,} octas ({new} new slots) |")
        for n in notes:
            print(f"|   {n} |")


if __name__ == "__main__":
    sys.exit(main())
