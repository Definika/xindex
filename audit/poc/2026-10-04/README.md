# PoCs of the 2026-10-04 audit run

Each file is named after the finding(s) it supports (`audit/2026-10-04-skills-audit.md`). Solidity files were written
and run in scratch copies of this repository at commit 6149aab; copy one into `test/poc/` to run it with
`forge test --match-path 'test/poc/*'`. They import the repository's own test helpers and sources, and none of them
changes anything under `src/`. They are evidence, not part of the test suite (CI neither compiles nor runs them).

- `B3-01__guard_bypass.rs`: standalone `rustc` program mirroring the Stellar vault's guard and dispatch.
- `B1-01__wrap.rs`: a `cargo` binary over `crates/xindex-core` (add the path dependency to run it).
- `A1b__auction_model.py`, `A1b__auction_drift.py`: the exact-integer model of the lambda auction (20,000 random cases).
