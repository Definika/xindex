"""Mutation gate: applies every mutant of test/mutants/mutants.json and requires the suite it names to fail.

Run from the repository root, standard library only:

    python3 -I test/mutants/run.py               # every mutant
    python3 -I test/mutants/run.py --only M3,V8  # some mutants, by id
    python3 -I test/mutants/run.py --check       # only that every edit still applies, without running forge

A mutant is one or more exact edits to one file. Each edit's `old` text must occur exactly once in that file, so a
mutant whose code has changed fails the gate as stale rather than turning into a no-op. The file is mutated in place
and restored from the bytes read before the edit, never from git (AGENTS.md), in a `finally`, and checked equal
after. Before any mutant runs, every suite the run uses must pass unmutated, so a broken test cannot read as a kill.
A mutant is killed when its suite reports a failing test; a compile error is neither a kill nor a survival but an
error. The run fails on any survivor, stale edit or error.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

TABLE = pathlib.Path("test/mutants/mutants.json")
# A failing test as forge prints it. A failure's reason can hold a bracketed number, `[1.801e9]`, so the pattern does
# not stop at the first `]` (AGENTS.md).
FAILED = re.compile(r"^\[FAIL[^\n]*\] (\w+)\(", re.MULTILINE)
TIMEOUT_S = 1800


def forge_test(mutant):
    command = ["forge", "test", "--match-path", mutant["test"]]
    if mutant.get("root"):
        command += ["--root", mutant["root"]]
    started = time.monotonic()
    done = subprocess.run(command, capture_output=True, text=True, timeout=TIMEOUT_S)
    output = done.stdout + done.stderr
    # forge lists each failure again in its summary, so the names are counted once.
    return done.returncode, output, sorted(set(FAILED.findall(output))), time.monotonic() - started


def apply(text, mutant):
    for edit in mutant["edits"]:
        count = text.count(edit["old"])
        if count != 1:
            return None, f"stale: an edit's text occurs {count} times in {mutant['file']}"
        text = text.replace(edit["old"], edit["new"])
    return text, None


def run(mutant):
    path = pathlib.Path(mutant["file"])
    original = path.read_bytes()
    mutated, problem = apply(original.decode(), mutant)
    if problem:
        return "stale", problem
    try:
        path.write_bytes(mutated.encode())
        code, output, failed, seconds = forge_test(mutant)
    finally:
        path.write_bytes(original)
    if path.read_bytes() != original:
        raise SystemExit(f"{mutant['id']}: {path} was not restored")
    if failed:
        return "killed", f"{len(failed)} failing, e.g. {failed[0]} ({seconds:.0f} s)"
    if code != 0:
        tail = output.strip().splitlines()[-3:]
        return "error", "forge failed without a failing test: " + " | ".join(tail)
    return "survived", f"every test of {mutant['test']} passed ({seconds:.0f} s)"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="comma-separated mutant ids")
    parser.add_argument("--check", action="store_true", help="only check that every edit still applies")
    args = parser.parse_args()

    mutants = json.loads(TABLE.read_text())
    ids = [m["id"] for m in mutants]
    if len(set(ids)) != len(ids):
        raise SystemExit("duplicate mutant ids in the table")
    if args.only:
        wanted = args.only.split(",")
        unknown = set(wanted) - set(ids)
        if unknown:
            raise SystemExit(f"unknown mutant ids: {sorted(unknown)}")
        mutants = [m for m in mutants if m["id"] in wanted]

    if args.check:
        stale = []
        for m in mutants:
            _, problem = apply(pathlib.Path(m["file"]).read_text(), m)
            if problem:
                stale.append(f"{m['id']}: {problem}")
        print("\n".join(stale) or f"all {len(mutants)} mutants apply")
        return 1 if stale else 0

    # Every suite this run uses must pass as committed, or a failure would read as a kill.
    for suite in sorted({(m["test"], m.get("root")) for m in mutants}, key=str):
        code, output, failed, seconds = forge_test({"test": suite[0], "root": suite[1]})
        if code != 0 or failed:
            print(output[-4000:])
            raise SystemExit(f"the unmutated suite {suite[0]} fails: fix it before the mutation gate")
        print(f"baseline {suite[0]}: passes ({seconds:.0f} s)", flush=True)

    results = []
    for m in mutants:
        verdict, detail = run(m)
        results.append((m["id"], verdict, detail))
        print(f"{m['id']:<5} {verdict:<9} {m['what']}: {detail}", flush=True)

    bad = [r for r in results if r[1] != "killed"]
    print(f"\n{len(results) - len(bad)} of {len(results)} mutants killed")
    for id_, verdict, detail in bad:
        print(f"::error::mutant {id_} {verdict}: {detail}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
