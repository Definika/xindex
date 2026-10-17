# Security audit of 2026-10-13

Cloudflare's `security-audit` skill (github.com/cloudflare/security-audit-skill at `c1c8a8c`) ran in full-audit mode,
`standard` profile, on `v5-custom-weights` at `eb5f3f3`. The scope was `src/`, `script/`, the keeper (`keeper/src/`,
`keeper/bot/`, `keeper/keeper.mjs`), the THORChain planner (`swaprail/thorchain.mjs`), the CI workflow and the
dependency pins.

The method:
- A coverage ledger of 35 units (entry surface × trust boundary × attack class), each closed with recorded checks.
- Hunters, then coverage critics until a post-wave critic and a distinct final-clean critic accepted no further work.
- Every candidate went to a fresh verifier that tried to refute it, and every surviving record to a second one.
- Local proofs ran only in a macOS `sandbox-exec` profile: network denied, writes confined to scratch, an empty
  environment, and CPU, file, process, memory and wall-clock limits.
- No RPC, Hermes or THORNode was contacted.
- The parent hunted the four core contracts itself, and sub-agents ran one at a time.

The run's full output (ledger, structured findings, reports and every proof) is kept outside the repository, in
`~/security-audit-skill/Xindex/run-1/` on the auditing machine.

**Result.** No exploitable path was found in `WeightedHub`, `WeightedIndexFactory`, `IndexZap` or `MintRequests`. Two
findings were confirmed, in tooling that holds no index funds. Six were source-grounded leads whose decisive fact lies
outside the repository. All but CF-3 are fixed below; CF-3 is a known limitation.

Each id is `CF-…`. A fixed finding's test carries the id, as `AGENTS.md` gate 6 requires. Each fix was checked
against a mutant that removes it, and every one of those mutants fails its test.

| Id | Verdict | Finding | Status |
|---|---|---|---|
| CF-1 | Confirmed, medium | A stolen keeper hot key can take `KeeperExecutor`'s stock through a factory index it creates | Fixed: owner-set stock allowance. `test_CF1_*`, `keeper/test/KeeperExecutor.t.sol` |
| CF-2 | Confirmed, low | One THORNode endpoint alone set a THORChain plan's limit, expiry and fee check | Fixed: every endpoint quotes, and the quotes must agree. Node test `CF-2: ...`, `swaprail/thorchain.test.mjs` |
| CF-3 | Needs validation | An issuer's corporate action on an Ondo stock token is not accounted for by fixed units | Known limitation, documented; owner to confirm Ondo's mechanism |
| CF-4 | Needs validation | `CheckToken` called a token listable when its admin can seize balances under names its table lacked; SAND likely | Fixed in the check; SAND re-pinned as review. `test_CF4_*`, `test/CheckToken.t.sol`; source reading owed |
| CF-5 | Needs validation | The mainnet broadcast was not bound to the reviewed, CI-tested build | Fixed: pinned init-code hashes. `test_CF5_*`, `test/Scripts.t.sol` |
| CF-6 | Needs validation | CI saved Foundry's RPC cache after an unpinned PyPI install in the same job | Fixed: Wake in a job of its own. `test_CF6_*`, `test/Repo.t.sol` |
| CF-7 | Needs validation | The keeper evaluated every open auction every block, empty indexes included | Fixed: fill path filtered by supply and worth, and capped. Node test `CF-7: ...`, `keeper/test/unit/math.test.mjs` |
| CF-8 | Needs validation | A Bitcoin-side memo's ticker was never proven by the quote, which asked about the full asset id | Fixed: every endpoint quotes the ticker itself. Node test `CF-8: ...`, `swaprail/thorchain.test.mjs` |

## CF-1: the keeper's stock (confirmed, medium)

`KeeperExecutor.fill` checked its counterparty only with `FACTORY.isIndex`. Anyone can create a factory index and hold
all its shares. So the holder of the keeper key could create an index whose underweight leg is a coin the executor
stocks, and fill it with a route through pools it seeded and a floor of 0, which counts only the USDC float. The
executor delivered the coin from stock, and the attacker redeemed it. Two independent reproductions each moved 19.72M of
20M stocked sats in one fill, with the float unchanged.

**Fix.** `stockAllowance[token]` is set only by `OWNER` (`setStockAllowance`). Every delivery from stock spends it, and
stock beyond it is bought through the leg's route or the fill reverts `NoRoute`. The bot caps usable stock at the
allowance. The NatSpec and `keeper/README.md`, which claimed the stock was out of the hot key's reach, now say what
bounds it. A stolen key can still trade the float badly within the floor it sets, as before.

## CF-2: one THORNode endpoint set the plan (confirmed, low)

The planner required two endpoints but asked only `nodes[0]` for the quote. A lying first endpoint planned a memo limit
of 1, an expiry of `99999999999`, and a missing fee that compared as `NaN` and passed.

**Fix.** Every endpoint is asked. The quotes must name one vault and expect outputs within `maxSpreadBps` (1%) of each
other. The plan takes the lowest output and the earliest expiry. The planner now also refuses:
- an expiry beyond `MAX_QUOTE_LIFE` (an hour);
- a fee that is not a number;
- the same endpoint given twice.

## CF-3: corporate actions (needs validation; known limitation)

An index fixes units per share and moves only amounts derived from supply and units. So:
- Tokens an issuer mints to holders belong to no share. A local test of a 10-for-1 split paid in tokens left 90% of that
  leg in the index after every share was redeemed, and the next rebalance bought more instead of using it.
- A burn leaves the leg below its backing.
- A token that stops being one share misprices the twelve Ondo legs priced at the share's feed.

How Ondo applies splits and dividends is not in the repository.

**Status.** Documented as a known limitation in `AGENTS.md` and `README.md`, and added to the steps before mainnet. No
contract change: paying out balances would break the rule that keeps share prices out of the hub.

## CF-4: names the admission check did not know (needs validation)

`CheckToken` raised review or refusal only from a fixed table of selector names, and read an admin only through
`owner()`, `getOwner()` and `controller()`. The Sandbox's shape (SAND) was reported "powers: none found", "owner: none",
listable: an admin behind `getAdmin()` appoints super operators whose `transferFrom` and `burnFor` need no allowance.
The owner's source reading, the policy's compensating control, is recorded for the 2026-10-05 cohort only, not for the
44 tokens listed on 2026-10-10.

**Fix.** `setSuperOperator(address,bool)` now counts as destroying a holder's balance, `burnFor(address,uint256)` as a
burn from another account, and `getAdmin()` is read as the owner. A SAND-shaped token now goes to review with its admin
named. `testFork_everyWideTokenPassesTheCheck` now pins SAND as review. That expectation rests on SAND's known source
and has not yet run against mainnet: the five fork suites must run again.

**Owed.** The owner's reading of the verified source of every token listed on 2026-10-10, SAND's first.

## CF-5: the deploy and the reviewed build (needs validation)

`DeployWeighted` broadcast whatever the local tree compiled. Its release-record hashes were taken from the contracts it
had just deployed.

**Fix.** On chain 1 it refuses to broadcast unless the init code of the factory, which embeds the hub implementation's,
the zap and MintRequests hashes to `FACTORY_INITCODE_HASH`, `ZAP_INITCODE_HASH` and `REQUESTS_INITCODE_HASH`
(`BuildNotReleased`). A local edit, a `lib/` checkout off `foundry.lock` or a `FOUNDRY_*` override is refused.
`test_CF5_theReleaseHashesAreThisBuilds` fails whenever `src/`, a dependency or the compiler settings change until the
three are updated in the same commit, so only a reviewed, CI-green commit moves them. `forge coverage`, which compiles
without the optimizer, skips that pin.

## CF-6: the RPC cache and Wake's dependencies (needs validation)

The check job set up `foundry-toolchain` with its default RPC cache, which is saved for later runs and read by the fork
suites as chain state. In the same job, `pipx install eth-wake==4.22.1` resolved eth-wake's dependencies from PyPI
at run time.

**Fix.** Wake runs in a job of its own whose Foundry keeps no cache (`cache: false`). Whether the action caches by
default at the pinned commit was not observable offline; the split removes the question.

## CF-7: the keeper's per-block work (needs validation)

The bot's start path skipped empty and small indexes, but its fill path evaluated every open auction of every factory
index, each block. Each evaluation made a Hermes request and a full fill simulation. A stranger can keep empty auctions
open for the gas of a start, so the operator's paid quota was spent on them, and enough of them could push real fills
past their block.

**Fix.** Each open auction's index is valued once per auction and again every 25 blocks, with one multicall and one
Hermes request for all of them. Only indexes with shares and worth at least `MIN_TVL_USD` are simulated, the richest
eight first (`M.auctionsToEvaluate`).

## CF-8: the memo's ticker (needs validation)

A Bitcoin memo cannot carry the full Ethereum asset id beside a 42-character destination, so it names `ETH.USDC`, and
THORChain resolves that ticker when it processes the swap. The design said the quote proves the resolution, but the
quote was asked about the full id.

**Fix.** When the memo names a ticker, every endpoint is asked to quote that very ticker and must resolve it to the full
id. If THORNode ever stops resolving tickers in quotes, the fund flow refuses rather than guesses. Confirm against a
live node with `swaprail/check-live.mjs` before relying on it.

## Not findings: hardening notes the run recorded

Not acted on in this change:
- **Wormhole trust row.** The trust table's "every wrapped leg" understates one path. A party that can mint a leg's
  token without backing can also deliver it in drift-driven fills, within the 20% cap, until the guardian keeps it.
- **Stale recipient wording.** `IIndexZap`'s NatSpec still names "the rule" among the refused recipients.
- **Unchecked hand-offs.** No check covers:
  - Hermes' parsed JSON against the signed binary update;
  - a cap on replacement fees;
  - `http://` endpoints for the keeper.
- **The keeper's own logs.**
  - An unredacted RPC URL in viem's startup error.
  - A cached "no route" for a whole auction.
- **THORChain planner.**
  - Memo field separators are not refused.
  - An uppercase `0X` destination skips the contract check.
- **CheckToken.**
  - Its beacon-proxy wording hides the Wormhole bridge's power to upgrade every copy.
  - It does not show a Safe's modules.
  - It simulates transfers only between code-less accounts.
  - It names any contract with `delay()` a timelock.
  - It does not follow SNX's `setTarget`.
- **Listing data.** There is no dated Hermes snapshot pinning each price id to its coin. There is no on-chain lower
  bound of 6 decimals.
- **Symbol text.** A newline in a hostile token symbol adds a forged line to `CheckToken`'s report header (forge strips
  ANSI escapes, so the real verdict still prints).
- **Keeper install.** `npm ci --ignore-scripts` instead of `npm install`.

## Unresolved, outside the repository

- 69 of the 93 Pyth ids could not be confirmed offline against Pyth's catalogue.
- The unit of the SYRUP and BTT feeds, and whether ZK is issued on Ethereum, need Hermes or Etherscan.
- Whether the Hermes plan's rate limit lets a default keeper be slowed at all.
