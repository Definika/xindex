# Whole-repo audit, 2026-10-04 (claude-audit-skills `audit` v0.35.0)

Declared scope: **`whole-repo`**, commit `6149aab42bbd56d4dec3657770dd939acdd573b7` (branch `main` as merged from
`four-chains`, PR #16). Method: the `audit` skill of `rainlanguage/claude-audit-skills` at commit
`9fefd09902d777aabc967ef6625d038e6c2101b7`, run as a fan-out of independent reviewers, then clean-context
verification of the findings that matter, then orchestrator synthesis.

**Confidentiality.** This report names one HIGH finding and a systemic one that are not fixed. The repository is
private (checked 2026-10-04). Per the skill's disclosure gate no GitHub issue was filed for any finding, and CRITICAL/HIGH
items must not be copied to a public surface before they are fixed.

---

## 1. Summary

**110 unique findings** (122 reported, 12 duplicates merged): **0 CRITICAL, 1 HIGH, 8 MEDIUM, 44 LOW, 57 INFO.**
Two roll-ups sit on top of them (below): **SYS-01** (HIGH, three MEDIUMs and one LOW together) and **DEP-01** (MEDIUM).

No path was found by which a stranger, an executor, a filler or a single hostile owner or guardian takes user funds on
the contracts that are built for launch. What was found is mostly liveness, governance power and deployment hazards,
plus documentation that has drifted from the code. The strongest results:

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | **B3-01** Stellar vault: the freezer can cancel its own replacement (`kind` is a `u32`, guarded whole and then narrowed with `as u8`). A hostile freezer holds every Stellar-vault payout frozen for good. | **HIGH** | Confirmed by reading the code and by a logic reproduction; the Soroban tests were not run |
| 2 | **SYS-01** A permissionless, exact-anchor `update` lets anyone kill a finality verifier (P1/P2, and the CometBFT and VeChain verifiers); a dead verifier stalls its vaults a week later, and the shipped successor path cannot finish. Holders' vault-side value is locked for up to about 187 days, and the attack can be repeated on the replacement. | **HIGH** (roll-up of B5-01, A5-01, A4-01 at MEDIUM and A4-02 at LOW) | PoCs pass against the real contracts; the fix was tested in a copy |
| 3 | **A3-01** The owner can freeze every vault's payouts and renew the freeze every 14 days forever, so the "no pause" promise does not hold and the snapshot exit never opens. | MEDIUM | Reproduced on the real factory and vault |
| 4 | **B1-01** Checkpoint timestamps of 2^63 or more wrap in the shared Rust core (Solana and NEAR): a forged checkpoint (needs both proofs broken) starts the snapshot exit at once. The EVM twin refuses it. | MEDIUM | Confirmed by reading and by a run of the real core functions |
| 5 | **A5-02** The BNB verifier needs each epoch block finalized by a vote on exactly its child; the epoch block's producer can withhold it, and the verifier then dies after one day. | MEDIUM (medium confidence) | Traced against the bsc v1.7.8 source |
| 6 | **DEP-01** The immutability of the non-EVM vaults is a manual step nothing checks: Solana's upgrade authority (B1-02), Sui's `UpgradeCap` (B4-01), NEAR's initial state (B2-01), Stellar's chain ids (B3-02). | MEDIUM (roll-up) | Read and confirmed for Solana |

**What to do first**
1. Fix B3-01 (a few lines; proposed diff and tests in section 3.1) and grep every Soroban entry point for the same
   `u32`-then-`as u8` pattern.
2. Fix SYS-01 in the verifiers (section 3.2) and correct the stall premise in AGENTS.md, the spec and the design.
3. Put a cooldown on human-initiated freezes in the factory and in all six vaults (A3-01), not a guardian-only rule.
4. Close B1-01 in `crates/xindex-core` and check the Move twins for the same cast.
5. Make the non-EVM vaults' immutability something a deploy check or the program itself enforces (DEP-01).
6. Add CI for the Rust, Move and JS parts (merged finding C1-04): today CI builds only the Foundry project.

**What held up.** The Stage A contracts (`IndexFactory`, `IndexHub`, `IndexZap`, `MintRequests`) have nothing above INFO or
LOW. An exact-integer model of the λ auction (20,000 random cases: 2 to 8 components, supplies from 1 to 2^128, units
across `[1e4, MAX_UNITS]`, random batches, keep masks, auction times and prices) found no case where holders keep less than
`λmin/λmax` of the moving value, none where an executor who delivers exactly `amountsIn` fails the backing check, and none
where an executor takes more than the band. Every rule constant matches across Solidity, the shared Rust core, Sui, Aptos and the docs;
37 keccak-derived literals were recomputed and match. Section 7 lists the rest.

---

## 2. Run record

| Item | Value |
|---|---|
| Declared scope | `whole-repo` |
| Commit audited | `6149aab42bbd56d4dec3657770dd939acdd573b7` |
| Skill | `audit` 0.35.0, `rainlanguage/claude-audit-skills` @ `9fefd09902d777aabc967ef6625d038e6c2101b7` |
| Reviewers | 19 independent agents: 8 on the Solidity (core, hybrid hub, factory and migration, vault, two verifier groups, scripts), 6 on the Rust and Move components and the proofs, 1 on repo-wide hazards, 4 verifiers. 9 ran at the deepest tier. |
| Dimensions run | 0 process, 1 security, 3 documentation, 4 code quality, 5 correctness, 6 hazard surface |
| **Pass 2 (test coverage)** | **REFUSED.** See below. |

**Pass 2 refusal (mutation-ledger gate).** The check failed on the first condition: `audit/mutation-test-scans.json` does
not exist. No override (`pass2-without-mutation-ledger`) was declared, and the skill forbids inferring one. `adversarial-mutation-test`
is the skill that writes the evidence: its campaign proves each coverage gap with a surviving mutant and ships the tests,
whereas reading tests cannot show that an assertion would change if the behaviour broke. The ways forward are to run
that campaign and commit its record, or to re-run with the override. This is a run-level fact, not a finding. Related
facts that are not suspicion: `forge coverage` reports 100% on every file (section 2.1), and tests whose assertions are too weak
are covered under dimension 5 (C1-06, A7-12, A7-13).

**Skill rules not applied.** The skill carries rainlanguage-org conventions (`iFoo`/`sFoo` storage naming, `^` pragmas for
libraries, file placement by kind, soldeer/rainix release lifecycle, Zoltu deterministic deployers, DecentraLicense naming).
They conflict with this repository's own documented conventions in AGENTS.md (SCREAMING_SNAKE immutables, pinned 0.8.28,
CREATE2 clones with a predicted-nonce deploy), so the repo's conventions were the reference, as the skill's own derivation order
allows. The substantive rules (rounding direction, fail-closed, strict deadlines, derived constants, hot-key custody,
fork-tested scripts, ambiguous sets) were applied everywhere.

### 2.1 Gates run locally by the orchestrator (Foundry 1.8.1, solc 0.8.28)

| Gate | Result |
|---|---|
| `forge build --sizes` | success, no warnings or notes. `XindexVault` runtime 23,760 B of 24,576. |
| `forge test --no-match-path 'test/fork/*'` | 820 passed, 0 failed, 0 skipped (46 suites) |
| `forge fmt --check` | clean |
| `forge lint -D notes` | clean |
| ABI regenerate-and-diff, 7 contracts | all match `abi/*.json` |
| `forge coverage` (isolated copy) | 100% lines (5934/5934), statements (8185/8185), branches (1216/1216), functions (940/940); every file at 100% |

Not run: the four fork suites (no RPC), Aderyn, Wake, and the builds and tests of the Rust, Move and JS components
(toolchains absent or not run). Two `Repo` tests fail only inside coverage mode because it writes no `out/` artifacts;
they pass in the normal run.

### 2.2 Verification record

Each MEDIUM, and the LOWs with real impact, went to a verifier with a clean context that had to try to refute the finding
first. The orchestrator also read the code behind B3-01, B1-01 and B1-02 itself, and ran a throwaway reproduction of B3-01.

| Verifier | Result |
|---|---|
| V1 | A3-01 PARTIAL, stays MEDIUM, and its proposed fix was corrected (a guardian-only rule does not bound the owner). A3-02, A3-03, A4-03 VALID, LOW (A3-02 and A4-03 are one issue). |
| V2 | A4-01 VALID, MEDIUM, PoC passes. A4-02 PARTIAL, lowered to LOW. A4-04 VALID, LOW. |
| V3 | A5-01 VALID, MEDIUM, PoC re-run and the proposed fix tested. A5-02 VALID, MEDIUM (medium confidence). A6-01 lowered MEDIUM to LOW. |
| V4 | A7-01 and A7-02 lowered MEDIUM to LOW. A2-01 and A2-02 VALID, LOW. A2-05 lowered LOW to INFO. A1a-05 VALID, INFO. |
| Orchestrator | B3-01 confirmed (code and logic reproduction). B1-01 and B1-02 confirmed by reading. C1-03 corrected (see its entry). |

Findings that were not re-verified are tagged `single-reviewer` in the appendices. B5-01 rests on its author's passing PoC
(the same mechanism was re-run independently for CometBFT/VeChain as A5-01).

### 2.3 Cost

About **$148** estimated from token usage (lighter tier $3/$15 and deeper tier $5/$25 per million input/output tokens, cache
writes at 125% and reads at 10%), including the orchestrator. The real billing was not visible to the run, and
the deeper tier's rate is an assumption: treat the figure as an estimate with a wide error bar. The run was designed
for a $250 ceiling; the last agents were launched when the estimate stood near $110, and none after.

### 2.4 Not swept (named, not implied)

- **Pass 2** (above).
- Reviewed only by unit or grep: test bodies (except `Repo.t.sol` and `Scripts.t.sol`, read in full, and 19 sampled regression
  tests); `proofs/p1-input` (state, votes, headers, rpc), `proofs/*/fixtures/generate.py`, `proofs/finality` test bodies, the
  Rust and Move vault test suites, `demo/` and `prototype/`.
- Not run: any Rust, Move or JS build or test, except the reproductions listed under "Evidence". Soroban host semantics,
  nearcore's own light-client behaviour, `tendermint-rs` 0.40.4 and `ics23` 0.12.0 behaviour (sources unavailable offline) and
  the Universal Router 2.0.0 / v4-periphery byte layouts (checked against recorded layouts and earlier audit
  `2026-09-23`, with no network) rest on documentation, fixtures or memory, as each affected finding says.
- Dimension 4 network checks (soldeer staleness, explorer verification) do not apply: the repo has no soldeer package and
  nothing is deployed.
- Only some LOW and INFO findings were re-verified. Findings were de-duplicated by the orchestrator, not re-derived.

### 2.5 Evidence

PoCs are in `audit/poc/2026-10-04/` (see its README). Solidity PoCs ran against unmodified `src/` in scratch copies.

---

## 3. HIGH findings

### 3.1 B3-01 (HIGH): Stellar vault `cancel_change` lets the freezer cancel its own replacement

`stellar/contracts/xindex-vault/src/messages.rs:487-505` (and `lib.rs:292-299`).

`cancel_change` and `apply_change` take `kind: u32`. The guard compares the full `u32` (`kind != FREEZER_CHANGE as u32`,
line 490), then `pending()` dispatches on `kind as u8` (line 499). `cancel_change(263)` (or 519, 775, …) passes the guard,
resolves to the freezer's own pending change, and clears it. The rule it breaks is VLT-2's: the freezer may cancel a waiting
raise or rotation, never its own replacement (AGENTS.md, spec section 5, README). The NEAR and Solana vaults take `kind: u8`,
so only Stellar is affected.

Scenario: a freezer account that is hostile or compromised freezes the vault (14 days, renewable) and cancels each
replacement the owner sends (FREEZER_CHANGE: 7 days at the factory, 7 days at the vault) by calling `cancel_change(263)`.
Payouts stay frozen. Checkpoints keep advancing (anyone can advance them), so the vault never stalls and the snapshot exit
never opens. All Stellar-vault value is locked indefinitely. Nothing is stolen, and holders can still redeem the Ethereum legs.
It is HIGH, not CRITICAL, because it needs a hostile freezer key and takes no funds; it is HIGH, not MEDIUM, because the
rule it breaks is the only bound on that key and the lock has no exit.

Evidence: code read in full by the finding's author and by the orchestrator; `audit/poc/2026-10-04/B3-01__guard_bypass.rs`
mirrors the two functions and shows `263` and `519` passing the guard and resolving to the freezer slot. The Soroban test
suite was not run (no Stellar CLI).

Proposed fix (`messages.rs`): narrow once at the entry points and use the `u8` everywhere.
```diff
 pub fn cancel_change(env: &Env, kind: u32) {
     let mut cfg = vault::config(env);
     cfg.freezer.require_auth();
-    require(env, kind != FREEZER_CHANGE as u32, VaultError::NotFreezer);
+    let kind = narrow(env, kind);
+    require(env, kind != FREEZER_CHANGE, VaultError::NotFreezer);
     let waiting = pending(env, &mut cfg, kind);
 ...
-fn pending<'a>(env: &Env, cfg: &'a mut Config, kind: u32) -> &'a mut PendingChange {
-    match kind as u8 {
+fn pending<'a>(env: &Env, cfg: &'a mut Config, kind: u8) -> &'a mut PendingChange {
+    match kind {
```
plus `fn narrow(env: &Env, kind: u32) -> u8 { u8::try_from(kind).unwrap_or_else(|_| fail(env, VaultError::NoPendingChange)) }`,
the same `narrow` at the top of `apply_change` (replacing `kind != FREEZER_CHANGE as u32` and `match kind as u8`), and
`ChangeApplied { kind: kind as u32 }`. Tests for `tests/vault.rs`: with a FREEZER_CHANGE queued,
`try_cancel_change(&(FREEZER_CHANGE as u32 + 256))` and `try_apply_change(&(CAP_UPDATE as u32 + 256), ..)` must fail with
`NoPendingChange`, and the replacement must still apply after `GOVERNANCE_DELAY` while frozen. Then audit every Soroban
entry point that takes a wider integer and narrows it.

### 3.2 SYS-01 (HIGH, roll-up): anyone can kill a finality verifier, a dead verifier stalls its vaults, and recovery cannot finish

Components, each with its own verified rating: **B5-01** (MEDIUM), **A5-01** (MEDIUM, verified), **A4-01** (MEDIUM, verified),
**A4-02** (LOW, partial), with **A4-04** (LOW) and A6-05 (INFO) as neighbours. The roll-up rating is the orchestrator's: the
verifiers rated each part by its own conditions, and the combination is what changes the risk.

The mechanism, common to every verifier that has a lag limit:
- `update` is permissionless and must start from **exactly** the stored anchor (`FinalityVerifier.sol:91`,
  `CometBftStateVerifier.sol:106`, `VeChainStateVerifier.sol:108`; the Solana, NEAR, Stellar, Sui and Aptos twins use the
  same rule).
- The statement accepts any finalized checkpoint after the anchor, with no requirement that it be recent (a single
  one-epoch step, or a single adjacent hop, is a valid proof).
- The verifier dies for good once its anchor is a day old (LG-4, `MAX_LAG`).
- So an attacker lands a cheap stale step just before an honest keeper's proof, which voids every honest proof in flight
  (`WrongAnchor`), while the lag clock moves only 384 s (P1/P2) or about 1 to 10 s (CometBFT, VeChain) per step. After about
  a day the verifier is dead for good.

Consequences (all verified by test or by trace):
1. The vault's checkpoint can then reach only a block inside a range the dead verifier recorded, so after 7 days
   `stalled()` is true and nothing permissionless can end it (A4-01, PoC passes). Every BURN sent after the last
   covered block reverts `NotCheckpointed`, so holders cannot leave that chain through the vault.
2. A successor pair cannot pass the continuity test: a `FinalityVerifier` proves only ranges its `update` recorded, and
   `update` refuses anchors older than a day, so a checkpoint seven or more days old can never be proven (A4-02, PoC
   passes). The missing "proof of descent" is disclosed as unbuilt, but the docs miss that LG-4 made recovery
   impossible with this verifier, and ARCHITECTURE's "as built" bound still promises 37 to 97 days.
3. The other exit is the snapshot at about 187 days, which pays only what was recorded in flight and what a snapshot
   claim proves. The successor pair has the same flaw, so the attack can be repeated on it.

Cost to the attacker, from the reviewers' estimates: for P1/P2, about 34 attacker proofs at an honest proving latency of
47 minutes, about $1,700 at the prototype's target of $50 per proof or less (B5-01, PoC against the real contract with the
repo's mock SP1 verifier); for CometBFT and VeChain, roughly $100 to $500 a day for VeChain and $1k to $10k a day for
Injective (A5-01, verified). The attacker's next proofs are deterministic from public chain data, so they are proven in
parallel. No coins are taken: the harm is value delayed up to about 187 days on every vault chain the attack reaches, the
mints, fills and settlements that chain's verifier gates, and the executors' bonds on accepted fills there.

It is rated HIGH because it is cheap, permissionless, repeatable on the replacement and has no working recovery.

Proposed fix:
1. `src/verifiers/FinalityVerifier.sol`: let a proof start from any anchor the verifier accepted that is still within its
   lag, as long as it moves the anchor forward, so a stale step landed first voids nothing (full diff in `B5.json`: a
   `mapping(bytes32 => uint64) accepted`, set in the constructor and in `update`, and the `anchorIn != anchor` check
   replaced by `accepted[anchorIn] != 0 && block.timestamp <= lagEnds(anchorIn)`). Mirror in the Solana verifier, the shared
   core's `advance` (Solana, NEAR, Stellar), Sui `light_client.move:139` and Aptos.
2. `CometBftStateVerifier.sol` and `VeChainStateVerifier.sol`: add `uint256 public constant MAX_UPDATE_AGE = 6 hours;` and
   after the `InTheFuture` check `if (block.timestamp > uint256(u.time) + MAX_UPDATE_AGE) revert TooOld(u.time);`.
   Verified in a copy: the PoC then reverts `TooOld` and the verifier stays alive.
3. Documentation: AGENTS.md lines 430-437, spec section 5.6 (line 537) and design 6.9 say a stall "cannot be manufactured".
   After LG-4 that holds only while nobody lets a verifier lapse, and the wording should say so, name independent daily
   provers as a launch requirement, and correct the "as built" 37 to 97 day bound. Exact before/after text is in `A4.json`.
4. Decide, before launch, how a successor proves continuity with a pair that has a different `update` range history
   (A4-02): either a proof of descent or a documented 187-day-only recovery.

---

## 4. MEDIUM findings

### A3-01: the owner can freeze every vault's payouts and renew the freeze forever (verified, corrected)

`src/HybridIndexFactory.sol:113-133`, `src/vault/XindexVault.sol:224-232, 288-293, 398-399, 440-441, 564-575`.

`freezeChain` is callable by the owner or the guardian, has no delay, veto or rate limit, and sends a fresh FREEZE each time.
The vault takes FREEZE on one proof, with no checkpoint cover and no nonce check, and sets `frozenUntil = now + 14 days`. While
frozen, `_release` pays 0 (every BURN, MIGRATE and snapshot claim stays owed), `refund` and `deposit` revert, and no change applies
except the freezer's own replacement. Checkpoints still advance, so the vault never stalls and the snapshot exit never opens.
The owner cannot be removed. The PoC (30 renewals at 13-day steps on the real factory and vault, 390 days) passes.

Two claims in the original finding were overstated: Stage B spec 5.2 and ARCHITECTURE 629 do give `freezeChain` to "the owner or
guardian", and the existing test documents a freezer re-freeze as "a new act extends it". The conflict is with AGENTS.md
("There is no pause"; the owner's powers do not list `freezeChain`), README line 96 and design 2026-09-29 (§3.1, decision row
at line 785: guardian-only, expiring). And the finding's first fix, making `freezeChain` guardian-only, is **not** a bound,
because the owner replaces the guardian in 7 days.

Proposed fix: a cooldown. Add a minimum gap between the end of a freeze and the next human-initiated freeze, in
`HybridIndexFactory._freezeChain` (the human path only, leaving `freezeOnEvidence` free) and in `XindexVault._freeze` and
`freeze()`: `if (block.timestamp < frozenUntil + FREEZE_COOLDOWN) revert FreezeCoolingDown();`, with the same rule in the Solana, NEAR,
Stellar, Sui and Aptos twins. Then payouts run for at least a fixed share of every period. Settle the docs at the same time: spec,
ARCHITECTURE and AGENTS.md should say who may freeze and how often.

### A5-02: the BNB verifier needs each epoch block finalized by a vote on exactly its child (verified, medium confidence)

`src/verifiers/BnbStateVerifier.sol:85-104, 233-255`, `src/interfaces/IBnbStateVerifier.sol:22-27`.

`advance` accepts epoch block E+1000 only with a quorum vote whose source is exactly E+1000 and target E+1001. Under bsc v1.7.8
(the version the contract cites; read in the source): votes carry the justified block as source, a block is justified only by an
attestation carried in a later header, including that attestation is optional, and since Fermi the producer may target one of
three ancestors. With a turn length of 8, one validator produces E+1000 to E+1007 and alone decides whether that child
attestation exists; a natural miss has the same effect. Nothing can be skipped, and once the latest set is more than
`MAX_LAG` old the verifier is dead, replaced only by the 30-day rotation. The natural miss rate could not be measured.

Proposed fix: accept the epoch block as final when any descendant within the old set's window is directly finalized and linked to
it by parent hashes: add `bytes[] descendants` to `EpochStep` and `error NotLinked(uint256 index)`, and check the chain of
parent hashes before `_checkVote` (diff in `A5.json`).

### B1-01: a checkpoint timestamp of 2^63 or more wraps in the shared Rust core (verified by reading and a run)

`crates/xindex-core/src/checkpoint.rs:16-36`; used by `solana/programs/xindex-vault` (`vault.rs`, `recovery.rs`) and by
`near/contracts/xindex-vault/src/lib.rs`.

`is_newer` checks `c.timestamp as i64 <= now` and `stall_start` computes `timestamp as i64 + STALL_PERIOD`. A `u64` timestamp
of 2^63 or more casts negative, so the "not in the future" check passes, `stalled()` is true at once, and
`begin_snapshot` is due immediately. `XindexVault.sol` compares in `uint256` and refuses such a checkpoint.

Precondition: P1 and P2 both accept a forged header. That is the layered-defence case VLT-2, VLT-4 and LG-3 are built for, and on
the EVM twin the forgery still cannot force a snapshot sooner than 187 days. On Solana and NEAR the window is zero: anyone starts the
snapshot exit at a forged root and the freezer is locked out. The real core functions were run on a forged checkpoint
(`audit/poc/2026-10-04/B1-01__wrap.rs`). The twin rule applies, so `sui/` and `aptos/` should be checked for the same cast.

Proposed fix (`checkpoint.rs`): never cast a `u64` timestamp to `i64` unchecked.
```diff
 pub fn stall_start(timestamp: u64) -> i64 {
-    timestamp as i64 + STALL_PERIOD
+    i64::try_from(timestamp).unwrap_or(i64::MAX).saturating_add(STALL_PERIOD)
 }
 ...
-        && c.timestamp as i64 <= now
+        && i64::try_from(c.timestamp).is_ok_and(|t| t <= now)
 ...
-    c.timestamp as i64 + STALL_PERIOD >= now
+    i64::try_from(c.timestamp).is_ok_and(|t| t.saturating_add(STALL_PERIOD) >= now)
```
with a regression test for `1 << 63` and `u64::MAX` against `is_newer`, `is_recent` and `stalled`.

### DEP-01 (roll-up): the immutability of the non-EVM vaults is a manual step nothing checks

Parts: **B1-02** (MEDIUM, read and confirmed), **B2-01** (MEDIUM, single reviewer), **B4-01** (LOW) and **B3-02** (LOW).

The EVM vault has no owner and cannot be upgraded by construction. The others depend on a step outside the code:
- **Solana (B1-02).** `xindex-vault/src/lib.rs` says the deployer "on mainnet then removes the program's upgrade authority".
  `initialize` requires the upgrade authority to sign, but nothing before `register_index`, `deposit` or any message requires it to
  be gone. One upgrade-authority key could redeploy the program and move the treasury in one transaction, bypassing P1/P2, the
  speed limit and the freezer. The vault already enforces this for P1 and P2 (`check_immutable`, SOL-2).
- **Sui (B4-01).** The Ethereum verifier pins the package's type-origin id, which survives upgrades; the `UpgradeCap` is gone only if the
  publisher destroys it, and `sui/` has no publish script.
- **NEAR (B2-01).** NEP-616 initial state is an arbitrary key/value map, and nothing derives it from `Vault::build` or checks the
  deployed account's state against it; a deployer could seed ranges, balances or the P1 key.
- **Stellar (B3-02).** The constructor never binds `chain_id` or `source_chain_id` to the network; the vault is immutable, so a wrong
  id is permanent.

Proposed fix, Solana (`setup.rs`): refuse `register_index` until the program is final, with a `devnet` feature for the testnet
build.
```diff
+    #[account(constraint = program.programdata_address()? == Some(program_data.key()) @ VaultError::NotDeployer)]
+    pub program: Program<'info, XindexVault>,
+    pub program_data: Account<'info, ProgramData>,
 ...
+    #[cfg(not(feature = "devnet"))]
+    require!(ctx.accounts.program_data.upgrade_authority_address.is_none(), VaultError::VaultUpgradeable);
```
Elsewhere: a deploy-time read-back that fails when the package is upgradeable (Sui `UpgradeCap`), an expected-state derivation
and comparison for NEAR, and chain-id checks for Stellar, each as a script test (see also A7-02 and A7-06, which ask the same of
the EVM-side review helpers).

---

## 5. Notes on corrected or merged findings

- **C1-03 (corrected).** AGENTS.md:474 and ARCHITECTURE.md:790 say the Solana program's `abi` tests pin every encoding against
  Solidity. `solana/programs/xindex-vault/src/abi.rs` is a thin wrapper over `xindex_core::abi` with no tests of its own; the
  Solidity pins live in `crates/xindex-core/tests/vault.rs` (`digests_match_solidity`). The sentence is imprecise, not false. C1-02
  separately lists the message bodies that have no Solidity-generated pin.
- **Merged duplicates.** A3-02 = A4-03 = B3-03 (the VLT-4 fix is incomplete on every vault); A2-04 = A3-08 = A5-03 (the hub never
  refuses an older vault state); C1-04 = A7-11 = B2-06 = B3-05 = B6-01 (no CI outside Foundry); B2-05 = B3-06; A3-03 = A4-06;
  A6-04 = B6-04; A6-07 = B6-05.
- The full structured set, with each finding's description, scenario and proposed fix, is
  `audit/2026-10-04-skills-audit-findings.json`.

---

## 6. LOW and INFO findings

Every LOW has its proposed fix in the JSON; the first lines are quoted here. "verified" means a clean-context verifier
confirmed it; "single-reviewer" means it has not been re-verified.

### 6.1 LOW (44)

- **A1b-01** [LOW; single-reviewer] Stage A spec still specifies the pre-SA-07 settlement amounts (differences of floored backings) — `design/2026-09-30-v4-stage-a-spec.md` 114-118
  Fix: design/2026-09-30-v4-stage-a-spec.md lines 115-117, before: "sold: `out_i = ⌊S·u_i/1e18⌋ − ⌊S·u'_i/1e18⌋`; one above is bought: `in_i = ⌊S·u'_i/1e18⌋ − ⌊S·u_i/1e18⌋`." After: "sold: `out_i = ⌊S·(u_i − u'_i)/1e18⌋`; one above is bought: `in_i = ⌈S·(u'_i − …
- **A2-01** [LOW; verified] An accepted fill can become unsettleable through no fault of its executor, and anyone then burns the bond — `src/hybrid/HybridHubModule.sol` 292-337, 394-423
  Fix: src/hybrid/HybridHubModule.sol lines 329-331, book the sold Ethereum legs as the executor's claims instead of sending them (the executor collects with claim(token, to)): - for (uint256 i = 0; i < n; ++i) { - if (out[i] != 0 && _slotOf[i] == 0) …
- **A2-02** [LOW; verified] A fill on an index with no supply is free (no bond, no deliveries, no proofs), so anyone can stall or break the creator's locked seed — `src/hybrid/HybridHubModule.sol` 227-260, 297-303
  Fix: src/hybrid/HybridHubModule.sol line 227, refuse a fill when there is nothing to rebalance and no bond to post: uint256 supply = _shareSupply(); + // An empty index posts no bond and owes no delivery: a fill there would only hold or break a locked seed. + if …
- **A2-03** [LOW; single-reviewer] The mint cap is a first-come allowance: a capitalised actor can hold it full and have every other order failed — `src/hybrid/HybridHubStorage.sol` 278-306
  Fix: Document it, README.md after line 543 (Stage B limitations): +- **The mint cap is first come, first served.** Anyone settling an order uses the index's 4% a day; a holder of enough of the components can keep it full, and orders that cannot settle are failed …
- **A2-04** [LOW; single-reviewer] The hub never refuses a vault state older than one it already accepted, which the verifier interface and spec 5.1 require of it — `src/hybrid/HybridHubStorage.sol` 252-276 (also reported as A3-08, A5-03)
  Fix: Pick one. (a) Correct the documents to what the hub relies on: src/interfaces/IVaultStateVerifier.sol lines 9-10: - /// @return timestamp The block's timestamp, in seconds. A caller comparing it with a deadline must also refuse a - /// state older than one it …
- **A3-02** [LOW; verified] VLT-4 fix incomplete: a newer cap cut relayed on one proof leaves the nonce mark, so an older raise delivered afterwards queues and undoes it — `src/vault/XindexVault.sol` 224-239, 288-307, 398-406 (also reported as A4-03, B3-03)
  Fix: Allow a governance message first delivered on one proof to be delivered again on both proofs, only to move its mark and drop an older waiting change. In src/vault/XindexVault.sol, record the nonce of a queued change (`mapping(bytes32 key => uint256) public …
- **A3-03** [LOW; verified] A FREEZE message never expires: one delivered late freezes the vault for 14 days from its delivery, at a stranger's chosen time — `src/vault/XindexVault.sol` 288-292, 571-575 (also reported as A4-06)
  Fix: Bind the vault's freeze to the Ethereum-side one. In src/HybridIndexFactory.sol:132: - if (payouts) _sendVault(chainId, vault, VaultMessages.FREEZE, ""); + if (payouts) _sendVault(chainId, vault, VaultMessages.FREEZE, abi.encode(until)); In …
- **A3-04** [LOW; single-reviewer] The factory accepts vault token ids wider than 160 bits, and the hub silently truncates them, so two listings can share one deposit — `src/HybridIndexFactory.sol` 102-111
  Fix: Fail closed at listing. In src/HybridIndexFactory.sol:102-104, add: if (_chains[chainId].vault == bytes32(0)) revert UnknownChain(chainId); + // Every vault's digests carry a token as 20 bytes (`address[]`), and the hub compares it so. + if (uint256(tokenId) …
- **A4-02** [LOW; verified, corrected, reviewer rated MEDIUM] No honest successor can pass the continuity test: a FinalityVerifier pair cannot prove a checkpoint older than a day, so every stall ends in owner-supplied custom code or the 187-day snapshot — `src/vault/XindexVault.sol` 614-640 (with src/verifiers/FinalityVerifier.sol 76-98, 157-168)
  Fix: Make an honest successor constructible: let a FinalityVerifier inherit proven ranges from its predecessor, so it proves (a) and (c) from data already proven and only (b) rests on its fresh anchor, which the 30-day review checks as any first anchor is checked. …
- **A4-04** [LOW; verified] The stall is keyed to checkpoints only: a break of receipt proofs alone leaves the vault unable to deliver anything yet never stalled, so recovery and the snapshot exit never open — `src/vault/XindexVault.sol` 586-611
  Fix: Make a checkpoint count only if the pair can still prove a receipt in it: give the factory a permissionless 'function heartbeat() external { emit Heartbeat(block.number); }', and have advanceCheckpoint take two more proofs, 'function advanceCheckpoint(bytes …
- **A4-05** [LOW; single-reviewer] paidTotal NatSpec and ARCHITECTURE.md say it can never exceed what the index sent, but snapshot claims add to it — `src/interfaces/IXindexVault.sol` 255-257
  Fix: src/interfaces/IXindexVault.sol 255-256, before: '/// @notice Everything paid out of the index's balance of `token`: to burn recipients, and into other indexes'\n /// balances by migration. It can never exceed what the index sent out in BURN and MIGRATE …
- **A6-01** [LOW; verified, reviewer rated MEDIUM] NEAR verifier moves to epoch E+1 on any block of E, after which no head of E can be recorded: NEAR proofs can be held about one epoch (~7 h) behind, past the hub's 6-hour GRACE — `src/verifiers/NearStateVerifier.sol` 102-136 (update); proofs/near/statement/src/lib.rs 208-245
  Fix: proofs/near/statement/src/lib.rs, after the loop (before `Ok(Output { .. })`, line 236), refuse a proof whose head is not in the epoch it ends at: // nearcore's light client changes epoch only on a block of the next epoch. Every block of an epoch names the …
- **A6-02** [LOW; single-reviewer] StellarStateVerifier's 1-day MAX_LAG does not bound retired or leaked keys, as its NatSpec claims: the signers write the close time, and the pinned quorum set never expires — `src/verifiers/StellarStateVerifier.sol` 79-81; src/interfaces/IStellarStateVerifier.sol 48-51
  Fix: src/verifiers/StellarStateVerifier.sol lines 79-80, replace the comment: // A day bounds how stale a proof may be. It does not bound retired or leaked keys: the signers write the close time, // so keys of the pinned quorum set can sign a ledger dated now for …
- **A7-01** [LOW; verified, reviewer rated MEDIUM] Pinned Groth16 verifier checks are self-declared identity: a proxy or any contract that answers two view calls passes — `script/ScriptUtils.sol` 36-49
  Fix: Pin runtime code, not names. script/ScriptUtils.sol: add `bytes32 internal constant SP1_VERIFIER_CODEHASH = 0x<codehash of the official SP1VerifierGroth16 v6.0.0>;` (no immutables, so one hash) and `RISC_ZERO_VERIFIER_CODEHASH` (3.0.0 with its published …
- **A7-02** [LOW; verified, reviewer rated MEDIUM] State-verifier review helpers read only the anchor: no code or trust-bearing immutable is checked for six verifiers, and NEAR and Stellar have no review helper — `script/DeployStateVerifier.s.sol` 490-526
  Fix: Make every check* compare the trust-bearing values and the code, and add checkNear/checkStellar. Code can be compared despite immutables by building a reference with the same arguments and comparing runtime hashes (the helper then becomes non-view, which is …
- **A7-03** [LOW; single-reviewer] ConfigureChains has no RT-06/XA-11 protection: a guardian's cancelled chain proposal, cancelled first listing or delisting is proposed again by the next routine run — `script/ConfigureChains.s.sol` 133-200
  Fix: Mirror RT-06. Add env `LIST_CHAINS` (chain ids or `all`), `LIST_COINS` (chainId:tokenId pairs or `all`) and `RELIST_COINS`, and gate the proposals: in shouldProposeChain, before `return true` for an unregistered chain: `if (registered.vault == bytes32(0) && …
- **A7-04** [LOW; single-reviewer] ConfigureChains accepts a vault word of any length, and a mistyped vault is permanent (VaultFixed) — `script/ConfigureChains.s.sol` 326-332
  Fix: script/ConfigureChains.s.sol: add `function _vaultWord(string memory raw, string memory entry) private pure returns (bytes32) { bytes32 w = _word(raw, entry); uint256 digits = bytes(raw).length - 2; if (digits != 40 && digits != 64) revert …
- **A7-05** [LOW; single-reviewer] First-listing supply of a vault coin has no whole-unit display or plausibility bound, and a wrong first figure is near-permanent — `script/ConfigureChains.s.sol` 174-200
  Fix: Add a decimals field to TokenEntry (`chainId:tokenId:supply:decimals`), log `supply / 10**decimals` whole units in shouldListToken and in safe-mode labels, and skip (with the reason) outside a plausible whole-unit band, e.g. `uint256 whole = e.supply / …
- **A7-06** [LOW; single-reviewer] DeployVault.checkDeployment reads back far less than its TRON and VeChain twins, so the release check cannot confirm keys, anchor, cap, floor or freezer — `script/DeployVault.s.sol` 216-231
  Fix: script/DeployVault.s.sol checkDeployment (lines 219-231): add `_same("freezer", p.freezer, v.freezer()); _sameWord("SOURCE_CHAIN_ID", bytes32(p.sourceChainId), bytes32(v.SOURCE_CHAIN_ID())); _sameWord("PROGRAM_KEY", p.p1ProgramKey, d.p1.PROGRAM_KEY()); …
- **A7-07** [LOW; single-reviewer] DeployVault accepts an anchor with one second of P1/P2 lag left; no minimum slack, unlike every DeployStateVerifier chain — `script/DeployVault.s.sol` 176-177
  Fix: Add a slack constant and refuse inside it: `uint256 public constant MIN_ANCHOR_SLACK = 12 hours; if (block.timestamp + MIN_ANCHOR_SLACK > lagEnds) revert AnchorTooOld(p.anchorEpoch, lagEnds);` (script/DeployVault.s.sol 177), the same in tron/deploy.mjs …
- **A7-08** [LOW; single-reviewer] Owner check is Safe-only and fail-open: any other contract (a 1-of-1 smart account, a forwarder to a hot key) is accepted without a threshold or module check — `script/Deploy.s.sol` 188-203
  Fix: script/Deploy.s.sol: in the else-branch of lines 197-202 take the restrictive path unless the operator acknowledges a non-Safe owner explicitly: `if (!(ok && data.length == 32)) { if (!vm.envOr("OWNER_IS_NOT_A_SAFE_ACK", false)) revert OwnerNotASafe(owner); …
- **A7-09** [LOW; single-reviewer] The vault's recovery proposer is only required to be 'a contract' (or two TRON keys): no threshold or module check, unlike the factory owner — `script/DeployVault.s.sol` 204-214
  Fix: Factor Deploy.checkOwner's Safe rules into ScriptUtils (`checkMultisig(address)`, using ISafeThreshold: threshold >= 3, no modules, not the broadcaster or the freezer among getOwners) and call it from DeployVault.checkRoles for the recovery proposer, with the …
- **A7-10** [LOW; single-reviewer] TRON and VeChain deploy tools deploy gitignored build output with no freshness check, record no source commit, and have no resume or balance check — `tron/deploy.mjs` 262-289
  Fix: In both deploy.mjs: before sending, run `git rev-parse HEAD` and `git status --porcelain` and refuse a dirty tree; compare each artifact's `source` hash with a freshly built one (have deploy.mjs call build.mjs, or store sha256 of the sources in …
- **A7-12** [LOW; single-reviewer] Repo.t.sol tests named for a CI claim pass without it (XA-10, I11, I09), contradicting the rule that a regression test must fail without its fix — `test/Repo.t.sol` 49-57, 80-83, 90-115
  Fix: test/Repo.t.sol: in test_XA10 add `assertTrue(_contains(workflow, "run: forge fmt --check")); assertTrue(_contains(workflow, "run: forge build --sizes")); assertTrue(_contains(workflow, "run: forge test -vvv"));`; in test_I11 require the test step's env block …
- **A7-13** [LOW; single-reviewer] The test guarding the central 'no price in any contract' rule is a five-word blacklist — `test/Repo.t.sol` 205-236
  Fix: test/Repo.t.sol line 210: widen to `string[12] memory priceWords = ["latestRoundData", "latestAnswer", "getRoundData", "AggregatorV3", "slot0", "Slot0", "observe(", "getReserves", "sqrtPriceX96", "consult(", "getPrice", "navPerToken"];` (and the helper's …
- **A7-14** [LOW; single-reviewer] README tells operators two signers sign the Safe batch; the owner Safe must need at least three — `README.md` 813-814
  Fix: README.md line 814: replace 'Two signers sign it, and one executes it.' with 'At least three of the Safe's signers sign it (the owner Safe's threshold), and one executes it.'
- **B1-03** [LOW; single-reviewer] initialize pins neither P1/P2's identity nor DeployVault's role checks: a finalized stub verifier is accepted as a mainnet P1/P2, and the freezer may be the deployer key — `solana/programs/xindex-vault/src/instructions/setup.rs` 53-80
  Fix: solana/programs/xindex-vault/src/instructions/setup.rs, after line 72: require_keys_neq!(args.freezer, ctx.accounts.authority.key(), VaultError::SameRole); require!(args.native_floor <= args.native_cap, VaultError::FloorAboveCap); #[cfg(not(feature = …
- **B1-04** [LOW; single-reviewer] Deposits are taken before the first checkpoint; if none ever arrives they can never be settled, refunded or exited — `solana/programs/xindex-vault/src/instructions/deposits.rs` 45-58
  Fix: solana/programs/xindex-vault/src/instructions/deposits.rs, after line 57: // Without a checkpoint no message can settle or fail this intake, and no successor or snapshot can follow. require!(ctx.accounts.config.checkpoint.state_root != [0u8; 32], …
- **B1-05** [LOW; single-reviewer] A CAP_UPDATE whose cap or floor exceeds u64 can never be delivered to the Solana vault, though an EVM vault would apply it — `solana/programs/xindex-vault/src/instructions/governance.rs` 110-116
  Fix: solana/programs/xindex-vault/src/instructions/governance.rs:110-116: BEFORE: let cap = abi::to_u64(abi::body_word(body, 3, 1)?)?; let floor = abi::to_u64(abi::body_word(body, 3, 2)?)?; AFTER: // No lamport amount exceeds u64, so a larger figure means the same …
- **B1-06** [LOW; single-reviewer] Snapshot-claim EIP-712 domain uses the registry's chain id, which common wallets refuse to sign — `crates/xindex-core/src/snapshot.rs` 219-243
  Fix: crates/xindex-core/src/snapshot.rs:221-235. Take the source chain id (Ethereum's, where the holder's wallet already is) for the domain's chainId. The vault's 32-byte id stays as the salt, which keeps the domain unique: pub fn claim_digest<C: Crypto>(c: &C, …
- **B2-02** [LOW; single-reviewer] Vault::build omits DeployVault's guards: floor above cap (speed limit never binds) and source chain equal to the vault's own chain — `near/contracts/xindex-vault/src/lib.rs` 907-969
  Fix: near/contracts/xindex-vault/src/errors.rs: add `FloorAboveCap`. src/lib.rs after line 911 (inside build): + check(config.native_floor.0 <= config.native_cap.0, Error::FloorAboveCap); + check(config.source_chain_id != config.chain_id, Error::WrongRoute); Also …
- **B2-03** [LOW; single-reviewer] Initial checkpoint timestamp is a deployer-chosen `now` in the NEP-616 path; a far-future value permanently blocks every checkpoint, intake settle/fail and any stall recovery — `near/contracts/xindex-vault/src/lib.rs` 907-909, 946-952; crates/xindex-core/src/checkpoint.rs:30-35
  Fix: crates/xindex-core/src/checkpoint.rs is_newer, and a NEAR-only wrapper: treat the first checkpoint specially so the baked grace time cannot block it: - && c.timestamp > last.timestamp + && (last.block == 0 || c.timestamp > last.timestamp) (this changes only …
- **B3-02** [LOW; single-reviewer] Stellar vault constructor never binds `chain_id` / `source_chain_id` to the network, and no script/test covers a Stellar deployment (HUB-I2 left to a manual step) — `stellar/contracts/xindex-vault/src/lib.rs` 55-127
  Fix: stellar/contracts/xindex-vault/src/lib.rs, in `__constructor` before building `cfg`: const PUBNET: [u8; 32] = h("7ac33997544e3175d266bd022439b22cdb16508c01163f26e5cb2a3e1045a979"); const TESTNET: [u8; 32] = …
- **B3-04** [LOW; single-reviewer] Stellar statement's quorum-set sanity check accepts any non-zero threshold, so a weak pinned set would yield a weak verifier instead of a dead one — `proofs/stellar/statement/src/quorum.rs` 17-42
  Fix: proofs/stellar/statement/src/quorum.rs `sane()`: after the zero/over-threshold check add + // at least two thirds of every level, as Tier 1 keeps (7 of 10, 2 of 3); a weaker pin could never be a Tier 1 quorum + if (q.threshold as usize) * 3 < members * 2 { + …
- **B3-07** [LOW; single-reviewer] The Stellar zk program's key (StellarStateVerifier.PROGRAM_KEY) has no reproducible-build recipe and no re-derivation check — `proofs/stellar/script/build.rs` 1-4
  Fix: proofs/stellar/script/build.rs: build the guest reproducibly, e.g. `sp1_build::build_program_with_args("../program", sp1_build::BuildArgs { docker: true, tag: "v6.8.1".into(), ..Default::default() })`, commit the expected key in `proofs/stellar/PROGRAM_KEY` …
- **B4-01** [LOW; single-reviewer] Sui vault's immutability is an unenforced manual step the Ethereum verifier cannot detect (PACKAGE_ID is the type-origin id, which survives upgrades) — `sui/sources/vault.move` 16-17 (also sui/README.md 115-123, src/verifiers/SuiStateVerifier.sol 64-66,74)
  Fix: 1) sui/README.md, section 'Ownerless and immutable' (lines ~115-123): add a mandatory gate and an exact recipe. Before: 'Check on chain that the package's `UpgradeCap` is gone'. After: 'A Sui vault may be registered (`proposeChain`) only after the publish …
- **B6-02** [LOW; single-reviewer] Solana prototype: written_state returns a zero-lamport account whose data and owner are unauthenticated — `proofs/solana-state/src/bank.rs` 87-105
  Fix: proofs/solana-state/src/bank.rs lines 101-104, replace Ok(writes.iter().find(|w| w.pubkey == *pubkey).and_then(|w| w.new.as_ref())) with Ok(writes.iter().find(|w| w.pubkey == *pubkey).and_then(|w| w.new.as_ref()).filter(|a| a.lamports > 0)) and in …
- **B6-03** [LOW; single-reviewer] Aptos statement: derived domain constants UPDATE, SLOTS, ATTEST_DOMAIN are hex literals with no Rust test that recomputes them, and hex32 ignores trailing characters — `proofs/aptos/statement/src/lib.rs` 41-62
  Fix: proofs/aptos/statement/tests/statement.rs, add: #[test] fn the_domain_words_are_the_keccaks_of_their_names() { assert_eq!(UPDATE, bcs::keccak(&[b"xindex.v4.aptos.update"])); assert_eq!(SLOTS, bcs::keccak(&[b"xindex.v4.aptos.slots"])); …
- **C1-01** [LOW; single-reviewer] Vault rule constants shared by six vault implementations are pinned to Solidity by no test — `crates/xindex-core/src/constants.rs` 8-25
  Fix: 1) crates/xindex-core/tests/vault.rs: add #[test] fn the_rules_are_the_evm_vaults() { assert_eq!(SPEED_LIMIT_PERCENT, 4); assert_eq!(FREEZE_DURATION, 14*86400); assert_eq!(GOVERNANCE_DELAY, 7*86400); assert_eq!(MAX_INTAKE_LIFE, 7*86400); …
- **C1-02** [LOW; single-reviewer] Governance and settlement message bodies (CAP_UPDATE, FREEZER_CHANGE, VERIFIER_ROTATION, FREEZE, INTAKE_SETTLED/FAILED) have no Solidity-generated cross-language pin — `crates/xindex-core/tests/vault.rs` 29-125
  Fix: Extend hub.json generation (each tests/fixtures/generate.py) or add a Solidity-side `vm.writeJson` of one canonical payload per kind (VaultMessages.encode of CAP_UPDATE with token=0,cap=500e18,floor=0.5e18; FREEZER_CHANGE; VERIFIER_ROTATION with two distinct …
- **C1-03** [LOW; single-reviewer] AGENTS.md and ARCHITECTURE.md say the Solana program's `abi` tests pin every encoding against Solidity; no such tests exist there — `AGENTS.md` 474
  Fix: AGENTS.md:474 and ARCHITECTURE.md:790: replace 'its `abi` tests pin every encoding against Solidity's' with 'the shared core's tests (`crates/xindex-core/tests/vault.rs`) pin the message envelope, BURN and MIGRATE bodies, both digests and the snapshot reads …
- **C1-04** [LOW; single-reviewer] CI runs Foundry only: no cargo, Move, npm or Anchor gate runs for the six non-EVM vaults, the shared core or the proof statements — `.github/workflows/test.yml` 1-147 (also reported as A7-11, B2-06, B3-05, B6-01)
  Fix: Add jobs to .github/workflows/test.yml (path-filtered if desired): core: `cd crates/xindex-core && cargo test --locked && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo build --locked --target wasm32-unknown-unknown …
- **C1-05** [LOW; single-reviewer] Hub/vault storage slots are copied into three Solidity files, the Rust core, two Move modules and five fixture generators, pinned only by a Solidity test and by five hub.json captures that carry no source revision — `test/Repo.t.sol` 283-295
  Fix: test/Repo.t.sol, extend test_theHubLayoutIsPinned: read crates/xindex-core/src/constants.rs, sui/sources/snapshot.move and aptos/sources/snapshot.move via _read and assert each contains the literal text for the slot just proven against the compiler layout, …
- **C1-06** [LOW; single-reviewer] Bare vm.expectRevert() in three HybridHub tests (and one in Bls12381MinSig) accepts any revert; three bare #[expected_failure] in Sui proofs tests — `test/HybridHub.rebalance.t.sol` 286,383
  Fix: test/HybridHub.rebalance.t.sol:286 and 383, test/HybridHub.t.sol:205: replace `vm.expectRevert();` with `vm.expectPartialRevert(IHybridHubTypes.DigestMismatch.selector);` (Foundry 1.8.1 supports it; or compute the exact args with …

### 6.2 INFO (57)

- **A1a-01** [INFO; single-reviewer] IIndexZap NatSpec still lists the retired v3 'rule' among refused recipients — `src/interfaces/IIndexZap.sol` 18-20, 59-60, 79-80
- **A1a-02** [INFO; single-reviewer] SA-02 left stale wording: 'one relisting or batch' moves a supply, and executeListing 'sets the proposed reference supply' — `src/interfaces/IIndexFactory.sol` 108-110, 245-249, 257-259 (and README.md 412-413)
- **A1a-03** [INFO; single-reviewer] IIndexFactory NatSpec describes Stage A only, but the deployed factory is HybridIndexFactory — `src/interfaces/IIndexFactory.sol` 136-142, 233-235
- **A1a-04** [INFO; single-reviewer] ZeroAmount is declared separately in IIndexZap and IMintRequests, against the shared-error convention — `src/interfaces/IIndexZap.sol` 127-128 (and src/interfaces/IMintRequests.sol 56-57)
- **A1a-05** [INFO; verified] Zap burn sells the previewed redeem amounts instead of measuring what redeem delivered — `src/IndexZap.sol` 238-246, 273-277, 343
- **A1a-06** [INFO; single-reviewer] Modifier helper _checkOwnerOrGuardian is internal, not private as the convention states — `src/IndexFactory.sol` 84-87, 181-183
- **A1b-02** [INFO; single-reviewer] The λ band and settlement math exist twice (IndexHub and HybridHubModule) with no differential check, and the copies already differ — `src/IndexHub.sol` 404-540
- **A1b-03** [INFO; single-reviewer] _previewRebalance NatSpec line runs to 196 columns: the SA-07 sentence was spliced in without rewrapping — `src/IndexHub.sol` 398-403
- **A2-05** [INFO; verified, corrected, reviewer rated LOW] HUB-2 covers only an empty index: a residual dust supply keeps an index mint-dead and its creator cannot re-seed it — `src/hybrid/HybridHubStorage.sol` 280-306
- **A2-06** [INFO; single-reviewer] _sentMessages NatSpec still says it holds only BURN and MIGRATE messages — `src/hybrid/HybridHubStorage.sol` 168-170
- **A2-07** [INFO; single-reviewer] _vaultAddress NatSpec says every vault runs on an EVM chain; NEAR, Stellar, Sui, Aptos and Solana vaults have 32-byte ids — `src/hybrid/HybridHubStorage.sol` 218-221
- **A2-08** [INFO; single-reviewer] The book's description omits migrations (HybridHub) and fills and migrations (IHybridHub) — `src/HybridHub.sol` 31-33
- **A2-09** [INFO; single-reviewer] voidOrder is documented as 'during a locked order's lock' but works for as long as the order is Locked — `src/interfaces/IHybridHubModule.sol` 29-33
- **A2-10** [INFO; single-reviewer] slashRebalance after the hold reverts NotYet, an error that means too early; RebalanceSlashed's NatSpec covers one of three cases — `src/hybrid/HybridHubModule.sol` 450
- **A2-11** [INFO; single-reviewer] New units are range-checked only at settlement, after the executor has delivered — `src/hybrid/HybridHubModule.sol` 245, 315
- **A2-12** [INFO; single-reviewer] Spec says claims wait 'at most the delivery window and its grace'; nothing ends an accepted fill unless someone fails it — `design/2026-09-30-v4-stage-b-spec.md` 391-392
- **A3-05** [INFO; single-reviewer] `vaultProposal(id)` NatSpec says it is empty when nothing is pending, but an expired proposal keeps its values, and there is no pending view as DA-16 added for the other proposals — `src/interfaces/IHybridIndexFactory.sol` 122-123
- **A3-06** [INFO; single-reviewer] Stale NatSpec: the hub and its storage still describe two parts, not three — `src/HybridHub.sol` 26-37
- **A3-07** [INFO; single-reviewer] `recordExit` on a vault with no snapshot reverts `NotAContradiction`, an evidence error, though `ChainNotExited` exists for this case — `src/hybrid/HybridHubExtension.sol` 294-295
- **A4-07** [INFO; single-reviewer] Stale or misplaced NatSpec on the vault and P1/P2 — `src/vault/XindexVault.sol` 13-17, 54-57
- **A5-04** [INFO; single-reviewer] RlpReader accepts non-canonical RLP; safe only while every decoded buffer is hash-authenticated — `src/libraries/RlpReader.sol` 4-6, 131-184
- **A6-03** [INFO; single-reviewer] StellarStateVerifier lacks its siblings' defence-in-depth checks: no future-time refusal and no exact public-values length — `src/verifiers/StellarStateVerifier.sol` 74-87
- **A6-04** [INFO; single-reviewer] AptosStateVerifier says the trusted set's lag bounds the attested state's age; it does not, and Aptos and NEAR prove attests of any age — `src/verifiers/AptosStateVerifier.sol` 152-155 (also reported as B6-04)
- **A6-05** [INFO; single-reviewer] SuiStateVerifier proves only checkpoints of the epoch in force, so the permissionless update at each epoch end invalidates every proof in flight — `src/verifiers/SuiStateVerifier.sol` 113-132, 229-230
- **A6-06** [INFO; single-reviewer] Interface documentation drift: ISuiStateVerifier names a non-existent committeeHash(keys, powers); INearStateVerifier omits SP1_VERIFIER and PROGRAM_KEY — `src/interfaces/ISuiStateVerifier.sol` 129-131; src/interfaces/INearStateVerifier.sol 12-123; src/verifiers/NearStateVerifier.sol 48-49
- **A6-07** [INFO; single-reviewer] Staleness boundary is inclusive: a proof exactly MAX_LAG after its anchor is still accepted — `src/verifiers/SuiStateVerifier.sol` 224; AptosStateVerifier.sol 100,155; NearStateVerifier.sol 106; StellarStateVerifier.sol 81 (also reported as B6-05)
- **A7-15** [INFO; single-reviewer] DeployStateVerifier's header, NatSpec and AGENTS.md list only the first two or four chains' review helpers and entry points — `script/DeployStateVerifier.s.sol` 23-28, 113
- **A7-16** [INFO; single-reviewer] Derived constants (verifier identities, registry ids, epoch length) are copied across Solidity, two JS tools and mocks, with no re-derivation test in the main suite — `script/DeployVault.s.sol` 44-58
- **A7-17** [INFO; single-reviewer] CI does not deny compiler warnings although the definition of done says forge build must be clean — `.github/workflows/test.yml` 69-70
- **A7-18** [INFO; single-reviewer] foundry.toml grants every script and test read access to the whole project root, .env included — `foundry.toml` 22-25
- **A7-19** [INFO; single-reviewer] Deploy and DeployVault take the 'broadcasting key' from msg.sender in the role checks but from vm.readCallers() for the nonce — `script/Deploy.s.sol` 109-112, 219-237
- **A7-20** [INFO; single-reviewer] Launch supplies are dated 2026-09-22 and nothing makes them be refreshed before the first mainnet listing — `script/MainnetAddresses.sol` 40-48
- **A7-21** [INFO; single-reviewer] TRON deploy tool depends on caret-ranged npm packages and is installed with `npm install`; the keystore password may sit in a file — `tron/package.json` 9-12
- **A7-22** [INFO; single-reviewer] ConfigureWhitelist's 'USDC/USDT are never components' check compares against mainnet addresses only — `script/ConfigureWhitelist.s.sol` 537-540
- **A7-23** [INFO; single-reviewer] TRON and VeChain tools default unset NATIVE_CAP, NATIVE_FLOOR and ANCHOR_EPOCH to 0 where DeployVault refuses — `tron/deploy.mjs` 91-108
- **B1-07** [INFO; single-reviewer] min_payout covers only an empty recipient; a rent-paying legacy recipient fails the whole delivery — `solana/programs/xindex-vault/src/vault.rs` 172-179
- **B1-08** [INFO; single-reviewer] Spec section 7 says the vault calls each verifier 'with the verifier's state account at a fixed address'; the real P1/P2 take a per-headers-root range PDA and an optional buffer — `design/2026-09-30-v4-stage-b-spec.md` 784-787
- **B2-04** [INFO; single-reviewer] begin_snapshot adds a storage entry with no deposit or charge, drawing on whatever balance the vault has beyond its storage stake; storage callers pay is never released — `near/contracts/xindex-vault/src/lib.rs` 611-626, 1000-1014
- **B2-05** [INFO; single-reviewer] decode_message truncates the body length with `as usize`, so on 32-bit targets (NEAR and Soroban Wasm) a non-canonical length word is accepted — `crates/xindex-core/src/abi.rs` 108-122 (also reported as B3-06)
- **B2-07** [INFO; single-reviewer] Stale comment in crates/xindex-core/Cargo.toml: NEAR and Stellar are described as next — `crates/xindex-core/Cargo.toml` 26-28
- **B2-08** [INFO; single-reviewer] u64 chain ids above 2^53 are serialized as JSON numbers in the `config` view, which JavaScript clients misread — `near/contracts/xindex-vault/src/types.rs` 191-193, 265-266 (ConfigView.chain_id at 266)
- **B2-09** [INFO; single-reviewer] is_implicit, the recovery-proposer 'not a single-key account' guard, does not know nearcore's newer account family (`0u` universal accounts) — `near/contracts/xindex-vault/src/types.rs` 300-309; lib.rs:916-919
- **B3-08** [INFO; single-reviewer] proofs/stellar README example passes an argument the CLI ignores — `proofs/stellar/README.md` 53
- **B4-02** [INFO; single-reviewer] Light-client `epoch` is deployer-declared and unbounded above, so LG-4's lag can be defeated until the first update (both Move vaults); `create` checks only the `system` label, never the program key — `sui/sources/light_client.move` 88-110, 157-162 (Aptos: aptos/sources/light_client.move 97-120, 174-177; sui/sources/vault.move 379-383; aptos/sources/vault.move 443-448)
- **B4-03** [INFO; single-reviewer] Rotated and successor light-client pairs skip the genesis, lag and role checks `create` applies (check_pair only tests distinct ids and distinct system labels) — `sui/sources/vault.move` 597-606, 680-712, 925-929 (Aptos: aptos/sources/vault.move 786-818, 1071-1076, 1346-1354)
- **B4-04** [INFO; single-reviewer] Twin drift on the protective path: Move vaults abort a FREEZE whose body is non-empty, the EVM vault freezes regardless — `sui/sources/vault.move` 1119-1125 (Aptos: aptos/sources/vault.move 1282-1288); EVM: src/vault/XindexVault.sol 289-293
- **B4-05** [INFO; single-reviewer] Aptos P1/P2 `update` feasibility rests on an estimated, unmeasured gas figure (the unit-test runner meters nothing) — `aptos/README.md` Gas section (~262-285), Limits section; ARCHITECTURE.md 841-843
- **B5-02** [INFO; single-reviewer] Margin reasoning omits consolidations completing after the anchor; 'over twice the drift below 50M ETH' is false — `design/2026-09-30-v4-stage-b-spec.md` 1040-1052
- **B5-03** [INFO; single-reviewer] P1 and P2 'two different verifiers' is enforced as two different addresses only — `src/vault/XindexVault.sol` 770-774
- **B5-04** [INFO; single-reviewer] The first anchor's epoch is a second, unbound source of truth beside the anchor hash — `src/verifiers/FinalityVerifier.sol` 76-81
- **B5-05** [INFO; single-reviewer] Network separation rests only on an unchecked program key / image id; the public values never name the network — `script/DeployVault.s.sol` 108-116,170-178
- **B6-06** [INFO; single-reviewer] Solana design record states 2^160 security for truncated Merkle nodes; a leader equivocating on a block id needs only a 2^80 collision — `design/2026-10-03-solana-state-proof.md` 114,198-206
- **B6-07** [INFO; single-reviewer] Solana prototype: bank-hash and double-Merkle block-id compositions are checked only against vectors the same author composed from reading Agave — `proofs/solana-state/fixtures/generate_vectors.py` 1-12
- **B6-08** [INFO; single-reviewer] Aptos TransactionInfo::V1 layout is verified only against the statement's own encoder — `proofs/aptos/statement/src/bcs.rs` 147-165
- **B6-09** [INFO; single-reviewer] VeChain statement never links its header chain to trusted_id; 'after the trusted block' is only a number comparison, and the docs do not say the safety argument rests wholly on the vouching quorum — `proofs/vechain/statement/src/lib.rs` 477-492
- **C1-07** [INFO; single-reviewer] Program keys and image ids are not recorded in the repo, and the proof workspaces float on the `stable` toolchain — `proofs/rust-toolchain` 1-3
- **C1-08** [INFO; single-reviewer] abi/IHybridIndex.json omits the hub's VaultMessage event and the ERC-20/ECDSA/SafeERC20 errors the hub can raise — `src/interfaces/IHybridIndex.sol` 13

---

## 7. Examined and found sound (assurance, not findings)

- **Stage A core.** `IndexFactory`: every boundary of the listing, batch and guardian state machines and their exclusions, the
  0.5% step at small supplies, `MIN_SUPPLY_INTERVAL`, unit math and overflow, the CREATE2 salt, both hook overrides.
  `IndexHub`: the invariant on issue, redeem, `redeemSkipping`, claims and the settlement post-check, the reentrancy guard and
  `onlyInitialized` on every minting, burning or rebalancing entry point, clone initialization, the trap-recipient rule, the
  timing of starts, cancels and expiry, the keep mask, `previewBand`. `IndexZap`: route checks, pre-fund and sweep accounting,
  stray balances, `ShortFill`, permit front-running, nonce re-checks, reentrancy. `MintRequests`.
- **Hybrid layer.** Selector maps of the hub, module and extension clash only on `FACTORY()`, which returns the same value in all
  three. The three storage layouts are identical (36 entries each); hub slots 0, 11, 59, 60, 62, vault slots 14, 15, 25 and
  OpenZeppelin's ERC-20 slot match their constants. The deploy script's nonce prediction is safe: each part's constructor refuses
  a mismatched factory.
- **Verifiers.** The TRN-1/2/4/5/9 fixes hold; the BLS-1 length checks hold; BLS12-381 constants, DST, `expand_message_xmd`,
  pairing input order and the hash to G1 and G2 were recomputed or checked against RFC 9380; Blake2b matches `hashlib.blake2b`
  vectors; Sui's BCS, signer bitmap, quorum and next-committee binding; NEAR and Stellar Merkle and outcome encodings; the
  P1 statement's generalized indices, fork and domain constants, threshold arithmetic and headers tree; SP1 v6 and RISC Zero v3
  claim hashing and pairing order; the vault's binding of emitter, topic, chain ids and vault. No file in the verifier area
  has an `unchecked` block.
- **Twin vaults.** Constants and encodings (4% limit, 25 buckets, 14/7/30/180-day periods, 2 vetoes, message kinds 1 to 8, the
  192-bit intake-id deadline shift) are identical across Solidity, the shared core, Sui, Aptos and the docs; the NEAR payout
  callbacks write state before the promise and restore the books; the Aptos vault object is owned by `0x0` and no outside owner
  can withdraw; Sui's `Vault`, `LightClient` and `Attestation` have `key` only and no capability exists.
- **Deployment.** Constants recomputed and matching (`RISC_ZERO_SELECTOR`, `SP1_VERIFIER_HASH`, the registry ids, network ids,
  beacon genesis times, TRON chain ids, the WBTC address); the Safe, guardian, market-contract and 7702 rules, and the
  `DeployVault` refusals, are implemented as AGENTS.md states.
- **Repo.** Dependencies: no floating git dependencies, `overflow-checks = true` in the release profiles, lockfiles for every Rust
  workspace. 19 sampled audit-id regression tests trigger the error their names claim. `vm.skip` appears only in the four fork
  suites' RPC guards.

---

## 8. Corrections to this run's own record

- A first-pass severity of MEDIUM was lowered by a verifier for A4-02, A6-01, A7-01 and A7-02, and a LOW to INFO for A2-05.
  The reasons are in section 2.2 and in the findings JSON.
- A3-01's first fix proposal was withdrawn and replaced (section 4).
