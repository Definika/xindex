# The skills audit of 2026-10-04: its open findings, fixed on 2026-10-25

The skills audit of 2026-10-04 ran on branch `claude/affectionate-hawking-1casmh` (13 commits from `6149aab`, its tip
`ae10a71`) and recorded 110 findings there, in `audit/2026-10-04-skills-audit-findings.json` and
`audit/2026-10-04-triage.md`. The branch was never merged. By 2026-10-25 it conflicted with `main` in 189 files and
its last CI run had failed, so it was archived and its remote branch deleted. Each finding was checked against `main`
at `687664c`: 102 concern code `main` has since deleted (v4's market-cap factory and hub, Stage B's hybrid contracts,
the THORChain and PancakeSwap legs) or were fixed or reworded since. Eight still held. They are fixed here.

**Result.** No path to protocol funds. Three are low: a deploy check that let an owner with one key through
(A7-08), and two repository tests that passed without the claims they are named for (A7-12, A7-13). Five are
informational. A sixth informational one turned up while they were ported: CI's coverage gate depended on the fuzz
seed, because XS-16's walk of the invariant handler missed eleven of its branches. Two independent reviews of the
fixes then found ways around five of them; each held, and each is closed under the id of the fix it reopened
("Independent review of the fixes").

Each id is the audit's own, `A7-…` or `A1a-…`. A fixed finding's test carries its id, as `AGENTS.md` gate 6
requires, and each fix was checked against mutants that undo it: every one of them fails a test named after its
finding.

| Id | Verdict | Finding | Status |
|---|---|---|---|
| A7-08 | Confirmed, low | On Ethereum the deploy accepted any owner contract that is not a Safe: a smart account with one key, a forwarder to a hot key, a Safe whose `getThreshold` reverts | Fixed: refused unless `OWNER_IS_NOT_A_SAFE` names that owner; the Safe rules unchanged. `test_A708_aNonSafeOwnerNeedsTheOperatorsAcknowledgment`, `test_A708_deployRun_readsEnvironment`, `test_CRI36_A708_aFailedSafeCallIsNeverReadAsAnAnswer`, `test_L06_checkOwner` |
| A7-12 | Confirmed, low | Repository tests named for a CI claim passed without it: deleting the fmt, build or test step, or the test step's fork RPC, left them green | Fixed: every gate's step pinned whole, cut as YAML reads it; the workflow and both Foundry configs pinned whole by their hashes; no `continue-on-error`, one condition. `test_XA10_A712_A717_ciRunsEveryGate`, `test_I11_A712_theCiToolchainIsPinned`, `test_XA44_A712_theAbisAreCommittedAndChecked`, `test_XA64_A712_ciChecksOutDirectSubmodulesAndTheLockBothWays`, `test_A712_aStepEndsWhereYamlEndsIt`, `test_A712_theCiConfigIsPinnedWhole`; part (c) by XS-17 before |
| A7-13 | Confirmed, low | The test of "no contract reads a price" knew five words; `latestAnswer`, `getSlot0` and `getReserves` passed it | Fixed: 47 words, and a test of the scan itself. `test_A713_noContractReadsAPrice`, `test_A713_theScanFindsEveryPriceWord` |
| A1a-05 | Confirmed, info | The zap's burn sold `previewRedeem`'s figures, not what the redeem delivered | Fixed: what arrived, measured. `test_A1a05_aBurnSellsWhatTheRedeemDelivered`, `test_A1a05_aBurnNeverSpendsTheZapsOwnTokens` |
| A1a-06 | Confirmed, info | `_checkOwnerOrGuardian` was `internal`; modifier logic is private | Fixed, and a modifier's whole body is checked. `test_A1a06_modifierLogicIsPrivate`, `test_A1a06_aModifierHoldsItsHelperCallAlone` |
| A7-17 | Confirmed, info | CI's build passed with compiler warnings | Fixed: `--deny warnings` on the repository's build and the keeper's. `test_XA10_A712_A717_ciRunsEveryGate` |
| A7-18 | Confirmed, info | Tests and scripts could read the whole repository, `.env` included | Fixed: the thirteen paths the checks read. `test_A718_noCheatcodeReadsTheEnvFile` |
| A7-22 | Confirmed, info | `ConfigureWeighted` refused only Ethereum's USDC and USDT as components, so off Ethereum a whitelist could list the deployment's own mint currency | Fixed: the deployment's currencies, `V5_USDC` and `V5_USDT`. `test_A722_theDeploymentsMintCurrencyIsNeverAComponent`, `test_A722_theMintCurrenciesAreTheDeployments`, `test_A722_run_readsEnvironment` |
| XS-16 | Found in the port, info | XS-16's walk left five lines and eleven branches of the invariant handler to the fuzzer, so CI's 100% coverage gate passed or failed by the seed | Fixed: two walks take every path. `test_XS16_handlerReachesEveryPath`, `test_XS16_handlerReachesEveryPathOnAnEmptyIndex` |

## A7-08: on Ethereum the deploy accepted an owner with one key (confirmed, low)

`DeployChecks.checkOwner` (`script/DeployChecks.sol:65` on `main`) held the owner to the Safe rules, at least three
signatures and no enabled module, only when it answered `getThreshold` with one word. Any other contract was "accepted
as it is" (line 71), meaning a timelock. A smart account with one key, a forwarder to a hot key, an `Ownable` executor
and a Safe whose `getThreshold` reverted all passed, and `test_L06_checkOwner` and `test_CRI36_...` asserted three such
owners were accepted. The owner holds no funds, but it proposes every listing and supply batch and names the guardian;
the three-signature rule is what keeps one key from holding those powers. `OWNER` is the operator's input, so the check
guards a mistake, not a hostile operator.

Reproduction: on chain 1, `main`'s check accepts the router mock, a contract whose fallback answers nothing
(`SilentFallback`) and one whose `getThreshold` reverts. The mutant that restores the acceptance fails
`test_A708_aNonSafeOwnerNeedsTheOperatorsAcknowledgment`: "next call did not revert as expected".

Fix (`script/DeployChecks.sol:76`): on a pinned chain a contract that answers no Safe threshold is refused with
`OwnerNotASafe(owner)` unless the operator acknowledges it by name. `deploy` takes the acknowledged owner from `run`,
which reads `OWNER_IS_NOT_A_SAFE`, none while it is unset (`script/DeployWeighted.s.sol:72`), and only the owner's own
address acknowledges it. As first written the acknowledgment was a flag, so a `true` left in `.env` from a timelock's
run would have let any later owner through, a smart account with one key among them (the review below). It lowers no
Safe rule: a contract that answers a threshold is held to three signatures and no module either way. The acknowledged
owner's code hash is logged for the operator to check, and `checkOwner(owner)` with one argument refuses. Refusing
every owner that is not a Safe was the stricter choice; it would have removed the timelock owner the check allowed, so
the audit's own proposal, the acknowledgment, was taken.

Tests: `test_A708_aNonSafeOwnerNeedsTheOperatorsAcknowledgment` (three non-Safes refused without the acknowledgment and
with another owner's, accepted with their own, a Safe needing two signatures refused even acknowledged, `deploy`
refusing a non-Safe); `test_A708_deployRun_readsEnvironment` (on chain 1, `run` with a timelock owner reverts while
`OWNER_IS_NOT_A_SAFE` is empty, `true`, `false` or another contract's address, and deploys with the timelock's own; the
test sets the variable empty rather than leaving it as found, since forge loads a local `.env`);
`test_CRI36_A708_aFailedSafeCallIsNeverReadAsAnAnswer` (a Safe-like contract whose call fails is refused, and accepted
only acknowledged); `test_L06_checkOwner`, whose two acceptances moved to the A7-08 test.

## A7-12: repository tests passed without the CI claims they are named for (confirmed, low)

(a) `test_XA10_ciRunsEveryGate`, "CI runs every gate of the definition of done" (`test/Repo.t.sol:165` on `main`),
checked lint, coverage, the secret's condition and Wake, but never `forge fmt --check`, `forge build` or `forge test`:
deleting any of those steps left every repository test green. (b) `test_I11_theCiToolchainIsPinned` checked that the
workflow names `MAINNET_RPC_URL` (line 54). The name also stands in the step that requires the secret, so a test step
that lost its `env:`, its fork suites then skipping, passed. (c) `test_I09_theKnownLimitationsAreDocumented` found the
phrase anywhere in the README; that part was fixed on 2026-10-16 (XS-17), and the test reads the section by its heading.

The same gap stood wherever a test pinned a step by a few of its words. The coverage step's `sys.exit(1)` could go, the
Wake step could end in `|| true`, the ABI check could stop failing on a diff, the submodule check could `exit 0`, a step
or a job could gain `if: false` or `continue-on-error`, and the keeper's tests and the node tests had no pin at all.
Each passed every repository test.

Fix: every gate's step is pinned whole, keys and script, as the path check's step already was: fmt, build, lint, the
ABI check, the fork RPC's requirement, the tests, the keeper's executor, the node tests, coverage, Wake and the
submodule check. Across the file there is no `continue-on-error`, one `if:` (the fork RPC's requirement, pinned whole)
and no quoted `if` key; CI runs on every push and pull request; each job installs Foundry once, pinned. The pins were
generated from the workflow's text and are compared exactly, so a step that changes must change its pin with it.

The review below found three ways around those pins, and each held. `_step` ended a step at the first line indented
less than its keys, a comment included, while YAML gives a comment's indentation no meaning: `shell: true {0}` under
the comment above the next step is a key of the gate step (PyYAML reads it so), makes GitHub run `true` in place of its
script, and passed every pin. Nine of the twelve steps pinned that way have such a comment below them. Nothing outside
the steps was pinned: a job's `defaults: run: shell`, `FOUNDRY_NO_MATCH_PATH` on the job, a job-level `if : false` (a
space before the colon, which the count of `if:` misses), an install step before the gates, a `ref:` on the checkout,
or a `no_match_path` in either Foundry config each passed every test. Now `_step` takes a comment line as the step's
when a key of the step follows it, and the workflow and both Foundry configs are pinned whole by their keccak-256
(`test_A712_theCiConfigIsPinnedWhole`, which prints the new hash): a change to one fails until its hash is pinned in
the same commit, and the step pins still hold every gate through a change that is. Each of the three files opens with a
line saying so.

Tests: `test_XA10_A712_A717_ciRunsEveryGate`, `test_I11_A712_theCiToolchainIsPinned`,
`test_XA44_A712_theAbisAreCommittedAndChecked`, `test_XA64_A712_ciChecksOutDirectSubmodulesAndTheLockBothWays`,
`test_A712_aStepEndsWhereYamlEndsIt`, `test_A712_theCiConfigIsPinnedWhole`, and for (c)
`test_I09_XS17_theKnownLimitationsAreDocumented`.

## A7-13: the test of "no contract reads a price" knew five words (confirmed, low)

`test_noContractReadsAPrice` (`test/Repo.t.sol:353` on `main`) searched `src/` and `abi/` for `latestRoundData`,
`AggregatorV3`, `slot0`, `observe(` and `navPerToken`. Chainlink's `latestAnswer` and `getRoundData`, Uniswap V4's
`getSlot0` (capital S) and raw `extsload`, a V2 pair's reserves and cumulative prices, a TWAP `consult(` and every
quoter passed it. The tree names none of them, so no contract reads a price today, but the guard of the design's first
rule would not have tripped.

Reproduction: `main`'s test passes over a `src/` that names `latestAnswer`, `getSlot0` and `getReserves`.

Fix: `_priceWords` holds 47 words: Chainlink's feeds, legacy rounds included; a V3 or V4 pool's slot 0, square-root
price, observations and raw state; a V2 pair's reserves and cumulative prices (`CumulativeLast` and `CumulativePrices`
as well as `priceCumulative`, which misses V2's own `price0CumulativeLast`); TWAP oracles; quoters', routers' and
ERC-7726 quotes; Curve's and Balancer's pool prices, rates and queries; the lending markets', Band's, Chronicle's,
Maker's, API3's and Tellor's oracles; a staked or vault token's exchange rate; and the retired `navPerToken`. Pyth's
getters stay V5-I4's words, allowed in the hub alone. The first fix held 29; the review below named seventeen common
reads still missing (Balancer's `getRate`, `queryBatchSwap` and `querySwap`, Curve's `price_scale`, `get_p(` and
`ema_price`, ERC-7726's `getQuote(`, Morpho's `.price(`, Chronicle's, Maker's and API3's `.read(` and `.peek(`, Tellor's
`getDataBefore` and `getCurrentValue`, Aave's `getAssetsPrices`, and `stEthPerToken`, `exchangeRate`,
`convertToAssets` and `pricePerShare`), and Chainlink's legacy `getAnswer` makes eighteen. None is in `src/` or
`abi/`. A read through a name not listed, or by raw selector, is review's to catch. The audit proposed a scan of a
fixture file written for the test; reads are all A7-18 leaves, so `test_A713_theScanFindsEveryPriceWord` runs the same
scan over a line naming each word, and over one naming none.

Tests: `test_A713_noContractReadsAPrice`, `test_A713_theScanFindsEveryPriceWord`.

## A1a-05: the zap's burn sold the preview, not what the redeem delivered (confirmed, info)

`IndexZap._burnBasket` (`src/IndexZap.sol:154` on `main`) took `got = previewRedeem(shares)` and sold exactly `got[i]`
of each component, on the comment that the preview is the exact amount received. That holds while every component
transfers what it is sent. One that pays less, a rebasing token or one that starts charging a fee after its listing,
left the zap short: every burn of that index through the zap reverted, and with tokens of that component already in the
zap it sold them, breaking the zap's promise never to use them. Exits in kind through the hub were unaffected.

Reproduction: an index of `ShortToken`, which pays one wei short on every transfer out of the index, beside USDC. On
`main`'s code `test_A1a05_aBurnSellsWhatTheRedeemDelivered` reverts with `ERC20InsufficientBalance(zap,
999999999999999999, 1000000000000000000)`, and `test_A1a05_aBurnNeverSpendsTheZapsOwnTokens` finds the five wei a
stranger had sent the zap at four.

Fix (`src/IndexZap.sol:153`): the zap reads each component's balance before and after `redeem` and sells the
difference, two `balanceOf` calls per component.

Tests: `test_A1a05_aBurnSellsWhatTheRedeemDelivered`, `test_A1a05_aBurnNeverSpendsTheZapsOwnTokens`.

## A1a-06: a modifier's logic was internal (confirmed, info)

`AGENTS.md` keeps modifier logic in a private function. `WeightedIndexFactory._checkOwnerOrGuardian`
(`src/WeightedIndexFactory.sol:349`) was `internal`, callable by a derived contract outside its modifier. No contract
derives from the factory, so this was style alone.

Fix: `private`. Test: `test_A1a06_modifierLogicIsPrivate` reads both modifiers of `src/`: each body must be its
helper's call and `_;` alone, each on a line of its own, and the helper the file's one function of its name, declared
`private`. As first written the check read a modifier's first statement only, and took the first function of the
helper's name anywhere in the file: a second statement, a check after `_;`, a body with no call (whose next function's
call was read as its own) and a private function of the name in another contract all passed it (the review below).
`test_A1a06_aModifierHoldsItsHelperCallAlone` runs the parse over each of those four, and over a modifier it accepts.

## A7-17: CI's build passed with compiler warnings (confirmed, info)

The definition of done asks for a clean build. CI ran `forge build --sizes` (`.github/workflows/test.yml:91` on
`main`), which succeeds with solc warnings. The tree had none, so this was latent.

Reproduction: with an unused local variable in `src/IndexZap.sol`, a fresh `forge build --sizes` exits 0 ("Compiler
run successful with warnings"), and CI's build step now exits non-zero on it.

Fix: `forge build --sizes --deny warnings`, pinned by `test_XA10_A712_A717_ciRunsEveryGate`. The keeper's executor,
which the workflow says gets the same gates, was still built without the flag (the review below): with an unused local
in `keeper/src/KeeperExecutor.sol`, `forge build --root keeper` exits 0 and `forge build --root keeper --deny warnings`
exits 1. Its step now denies warnings too, pinned by the same test.

## A7-18: tests and scripts could read the whole repository (confirmed, info)

`fs_permissions = [{ access = "read", path = "./" }]` (`foundry.toml:28` on `main`) let any test or script, and any
dependency's code one runs, read `.env` (the RPC URLs and the Etherscan key), the gitignored broadcast records and any
other file. First-party code read only the files `test/Repo.t.sol` checks, so nothing used it.

Fix: read access to the thirteen paths those checks read, and nothing else (`foundry.toml:30`): the twelve of the
first fix, and `keeper/foundry.toml`, which `test_A712_theCiConfigIsPinnedWhole` pins. Foundry normalizes a path
before it checks it, so a read that climbs out of a readable folder (`src/../.env`) is refused too. Forge still loads
`.env` into the environment of every run, so `vm.env*` reads its variables: the rule that `.env` holds no key
(keystores only) is what keeps keys out of reach.

Test: `test_A718_noCheatcodeReadsTheEnvFile` (`.env`, `src/../.env`, `keeper/.env`, a broadcast record and
`AGENTS.md`, each refused as not allowed).

## A7-22: the mint currencies were Ethereum's alone (confirmed, info)

`ConfigureWeighted._followsPolicy` (`script/ConfigureWeighted.s.sol:309` on `main`) skipped a whitelist entry equal to
Ethereum's USDC or USDT. Off Ethereum the mint currencies are whatever `DeployWeighted` was given (the Sepolia guide
uses tUSDC), so a testnet whitelist could propose the deployment's own mint currency as a component.

Fix: `mintCurrencies` returns the deployment's two (`script/ConfigureWeighted.s.sol:347`): `V5_USDC` and `V5_USDT`,
required off Ethereum (`MintCurrencyRequired`), and on Ethereum the address book's, any other value refused
(`MintCurrencyOverride`). Propose and safe mode compute them once (line 99) and skip an entry naming either, or
Ethereum's. Execute and status mode need neither.

Tests: `test_A722_theDeploymentsMintCurrencyIsNeverAComponent`, `test_A722_theMintCurrenciesAreTheDeployments`,
`test_A722_run_readsEnvironment` (`run`, with `V5_USDC` naming a whitelist entry, proposes and lists every entry but
that one).

## XS-16's walk left CI's coverage gate to the fuzz seed (found during the port)

`test_XS16_handlerReachesEveryPath` exists so that the invariant handler's coverage "does not depend on what the fuzzer
calls". Run alone under coverage, it left five lines and eleven branches of `test/WeightedHub.invariant.t.sol`
untaken: the holder paths that return while nobody holds anything, `_holder`'s fallback, a refused gated issue, the
guardian's two corrections of a keep mask, a front-run fill with nothing to trade and a short fill with nothing to buy.
The fuzzer reached most of them, but not the last two reliably. With `--fuzz-seed` 1 to 5 and 8, `main` and this branch
alike left the front-run's return untaken, and with seed 1 the short fill's too, so CI's coverage gate, 100% on every
file, passed or failed by the seed. It failed on this branch's first coverage run.

Fix: the walk makes a front-run fill once an auction has nothing to trade, and
`test_XS16_handlerReachesEveryPathOnAnEmptyIndex` walks the rest on a fresh index nobody holds. A short fill there has
nothing to buy because, off its weights, the preview trades units, but on no supply every amount is zero:
`WeightedMath._legAmounts` rounds a growing leg up, so only a zero supply buys nothing. The two walks alone now take
every line and branch of the handler, and seeds 1 to 8 all reach 100%. No seed is pinned, which would cut the fuzzing
the gate is there for.

## Independent review of the fixes

Two read-only reviewers went over the fixes before they were committed: one the production code and CI's
configuration, one the tests. Every claim was checked against the code before anything changed. Each finding held,
and each is fixed above under the id of the fix it reopened.

| From | Finding | Closed under |
|---|---|---|
| Both | The keeper's build still allowed compiler warnings, though the workflow gives it the same gates | A7-17 |
| Tests | `_step` ended a step at a comment, whose indentation YAML ignores, so a key below the comment went unpinned | A7-12 |
| Tests | Nothing outside the steps was pinned: a job's `defaults`, a `FOUNDRY_*` variable, `if :`, a `no_match_path` | A7-12 |
| Tests | Steps around the pinned ones: an install before the gates, the checkout's `ref` | A7-12 |
| Tests | The modifier check read a modifier's first statement only | A1a-06 |
| Tests | A local `.env` setting `OWNER_IS_NOT_A_SAFE` changed what the test of its unset case tested | A7-08 |
| Tests | `OWNER_IS_NOT_A_SAFE=true` acknowledged any owner, so one left from a timelock's run let a later owner through | A7-08 |
| Tests | Common price reads were missing from the scan | A7-13 |

Found sound, among what the reviewers checked: A1a-05's measurement has no underflow, double count or reentrancy path
(`WeightedHub._redeem` transfers every amount or reverts, and a component list holds no duplicate); an owner with no
code, or an EIP-7702 account, is refused before any acknowledgment is read, and the guardian, market-role and Pyth
checks still follow it; `ConfigureWeighted.run` is unchanged but for the currencies; and no file cheatcode is used
outside `test/Repo.t.sol`, so the narrowed read access breaks no fork suite or script.

## Status of the fixes (2026-10-25)

Gates, on a frozen copy of the branch whose `lib/` is a clone of the repository's:

- `forge fmt --check`: clean. `forge build --sizes --deny warnings --force`: no warning, and the keeper's build with
  `--deny warnings` none either. `forge lint -D notes`: nothing. CI's ABI step: no diff.
- `forge test`, offline: 482 passed, 0 failed, 5 skipped (the fork suites, without an RPC); `test/Repo.t.sol` 23 passed.
- CI's coverage step, run as GitHub runs it: "100% coverage on all 48 files".
- `node --test keeper/test/unit/*.test.mjs`: 126 passed, 0 failed.
- `wake detect all src` (4.22.1, its config generated with `keeper/` left out, as CI makes it): no detections.
- Fork suites at the pinned block 26,033,838, on Tenderly's public archive: `IndexZap.fork` 11, `Security.fork` 9 and
  `MainnetAddresses.fork` 9 passed on this tree, the zap's burn on Ethereum's tokens and the owner check on real Safes
  among them; `CheckToken.fork` 6 and `WeightedHub.fork` 6 passed on a copy whose `src/` and suites are byte for
  byte this tree's. The keeper's step as CI runs it: 64 passed, a fresh build denying warnings and its fork suite on
  Wormhole's real Token Bridge included.

Mutants, each in a copy of the tree, each failing a test named after its finding: 92, all killed.

- A7-08, nine: the old acceptance; any acknowledgment acknowledging any owner, the flag's rule; an acknowledgment that
  lowers the Safe rules; a Safe that falls through to the refusal; `checkOwner(owner)` acknowledging; `run` reading
  `OWNER` by default, taking any set value as the flag did, or ignoring the variable; `deploy` acknowledging every
  owner.
- A7-12, thirty-five: each gate step deleted, or its command weakened (`forge fmt` without `--check`, lint without
  `-D notes`, the tests without the fork RPC, coverage that no longer exits on a shortfall, Wake's findings ignored or
  its version unpinned, the keeper's tests dropped, an ABI left out or a stale one passing, a lock mismatch exiting 0,
  the fork RPC no longer required, or required on no branch); `if: false` on a step and on a job, a quoted `if` key,
  `continue-on-error` on a step and on a job; the Wake job's Foundry unpinned; no CI on pull requests; nested
  submodules cloned; `shell: true {0}` under the comment below the test step; `_step` ending a step at a comment again;
  the eight changes only the whole-file pin sees (a job's `defaults`, `FOUNDRY_NO_MATCH_PATH` on the job, `if : false`
  on the job, an install step before the gates, the checkout's `ref`, an edited comment, a `no_match_path` in either
  Foundry config); and for part (c), the limitations section's heading renamed.
- A7-13, twenty-eight: a source file naming `latestAnswer`, `getSlot0`, `getReserves`, `extsload`,
  `price0CumulativeLast`, `quoteExactInputSingle`, `get_dy` or `getAssetPrice`; a new source file naming each of the
  eighteen words added after the review; an ABI naming `latestAnswer`; the scan finding nothing.
- A7-22, six: Ethereum's currencies alone; a missing currency accepted; an override accepted on Ethereum; Ethereum's
  taken on every chain; `run` ignoring `V5_USDC` and `V5_USDT`; `V5_USDT` read for both.
- A1a-06, six: the helper `internal` again; the check inlined in the modifier; a second statement after the helper's
  call; a check after `_;`; a one-line modifier; the helper `internal` behind a private function of its name in another
  contract of the file. A1a-05, three: the preview's figures back; what the zap held before not subtracted; the balance
  read before the redeem only. A7-18, three: the whole root readable, the keeper's folder, `.env`. A7-17, two: the
  repository's build and the keeper's allowing warnings.

The findings as they stood, run directly:

- A7-13: `main`'s scan passes over a `src/` that names `latestAnswer`, `getSlot0` and `getReserves`; the first fix's
  29-word scan passes over a new `src/` file naming the eighteen words added since.
- A7-17: a fresh `forge build --sizes` passes an unused local variable with "Compiler run successful with warnings",
  which CI's build step now fails; the keeper's build likewise, exit 0 without the flag and 1 with it.
- A7-12: each of the eight changes only the whole-file pin sees passes every step pin, their six tests green; PyYAML
  reads `shell: true {0}` under the comment below the test step as a key of "Run Forge tests".
- A1a-06: the first fix's parse returns `_check` for each of the four modifiers it should refuse.
- A7-08: with the acknowledgment an address but the flag's rule kept (any acknowledgment acknowledges), both A7-08
  tests fail: "next call did not revert as expected".

Open, the owner's call:

- A7-08's acknowledgment keeps a timelock, or another contract that is not a Safe, possible as the owner. A rule of a
  Safe and nothing else would refuse them.
- CI's own settings (`permissions: {}`, `contents: read`, `persist-credentials: false`, the actions pinned by commit)
  are pinned with the rest of the workflow, but no test names them one by one, so a reviewed change that pins a new
  hash could drop one; the publish checklist checks them by hand before each push.
