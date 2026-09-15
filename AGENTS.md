# AGENTS.md

Guidance for Codex (and humans) working in this repository.

## What this is

Xindex smart contracts: a Foundry project where users create fixed-composition crypto index tokens
(ERC-20) backed in kind, mint them with USDC/USDT, and burn them into any token via Uniswap V3.
The web app lives in a separate repo. See `ARCHITECTURE.md` for the design and `README.md` for the
product brief, frontend integration notes, and deployment.

## Commands

```bash
forge build --sizes          # compile + forge lint (must print "Compiler run successful!" with no findings)
forge fmt                    # format; CI runs `forge fmt --check`
forge test                   # unit + fuzz + invariant tests, no RPC needed
forge coverage               # must stay at 100% for every file (lines, statements, branches, functions)

# mainnet fork tests (real Uniswap V3 / USDC / USDT); skipped when the env var is unset
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -vvv
# public non-archive RPCs only serve recent state: pin near the head
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com FORK_BLOCK=$(( $(cast block-number --rpc-url https://ethereum-rpc.publicnode.com) - 8 )) forge test --match-path 'test/fork/*'
```

Deployment: `script/Deploy.s.sol` then `script/ConfigureWhitelist.s.sol` (see README).

## Definition of done for any change

1. `forge fmt --check` clean.
2. `forge build` clean, including `forge lint` (zero warnings and notes). Lint config lives in
   `foundry.toml` `[lint]`; each excluded rule has its reason in the comment block above the list. Do not
   add exclusions without a reason there. Prefer fixing code; use `// forge-lint: disable-next-line(<rule>)`
   or `disable-next-item(<rule>)` only for verified false positives or deliberate behaviour, with a one-line
   reason on the line above.
3. `forge test` green. `forge coverage` at 100% for every file, including mocks and scripts.
4. Fork tests green if the change touches `IndexZap`, paths, token behaviour, or anything Uniswap-related.
5. The Wake VS Code analyzer reports no errors or warnings on `src/`. Its reentrancy detector does
   not model reentrancy guards; the two documented suppressions are on the `redeem` call in `IndexZap._burnBasket`
   and the `permit` call in `IndexZap.burnToTokenWithPermit`.
6. Every finding of the security review keeps its regression test passing in `test/Security.t.sol`
   or `test/fork/Security.fork.t.sol`.

## Layout

```
src/IndexToken.sol            index implementation (ERC20 + permit + in-kind issue, redeem, redeemSkipping, claim), cloned
src/IndexFactory.sol          listing delay + guardian, registry, CREATE2 clone deployer
src/IndexZap.sol              stateless Uniswap V3 mint/burn router with per-leg limits
src/interfaces/               IIndexToken, IIndexFactory, ISwapRouter02
src/libraries/PathLib.sol     V3 packed path decoding (shared with test mocks)
test/*.t.sol                  unit / fuzz / invariant / script tests
test/Security.t.sol           one regression test per security review finding
test/mocks/                   mock tokens and routers (+ Mocks.t.sol)
test/fork/                    mainnet addresses, end-to-end fork tests, fork security regressions
script/                       Deploy, ConfigureWhitelist
```

## Design rules that must not be broken

- **The core is in-kind and oracle-free.** `IndexToken` only ever moves the exact basket. Never
  compute anything from balances, never add a share price, never add an oracle to the core.
- **No admin power over funds.** The factory owner proposes listings (`LISTING_DELAY`) and guardian changes
  (`GUARDIAN_DELAY`), each executable only within `PROPOSAL_WINDOW` afterwards, delists, and transfers ownership;
  the guardian can cancel pending listings and delist. No pause, no upgrade, no sweep, no renounce, and no
  instant guardian change. Keep it that way.
- **Fixed composition.** `units` are immutable after `initialize`. Rebalancing is a v2 discussion.
- **Invariant:** for every component `i`,
  `token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]`.
  Issue rounds up, redeem rounds down, and a claim is only recorded for an amount that stayed in the index.
  The invariant test enforces this; keep it passing.
- **Holders can always leave.** `redeemSkipping` must keep working when any subset of components is frozen,
  and claims must be payable once transfers resume.
- **Index addresses commit to their contents.** Clones are CREATE2-deployed from a salt over the creator and the
  full composition. Do not switch back to CREATE.
- **Only initialized clones issue or redeem.** Keep the `onlyInitialized` guard on every function that mints or burns.
- **The zap is stateless and replaceable.** New UX features (ETH in/out, aggregators, V4) go in a
  new or extended zap, never in the token or factory. The zap must validate every swap path's endpoints, honour
  per-leg limits, measure what the user pays and receives as balance changes inside the call (never using tokens
  already in the zap), send the unsold part of a partially filled leg to the recipient, revert on transfer
  shortfalls, and never call `redeemSkipping` (a claim recorded for the zap could never be collected).
- **Checks-effects-interactions.** Emit events and write state before external calls where the
  data is available; make the call into a user-supplied address the last interaction when possible.
- **Standard ERC-20s only as components** (whitelist policy). `issue` rejects fee-on-transfer
  tokens by checking the received amount. Do not whitelist USDC/USDT as components in scripts
  or docs; they are fine as mint/burn currencies. Pausable components such as WBTC must be labelled in the app.

## Conventions

- `pragma solidity 0.8.28;` in `src/` and `script/`; tests use `^0.8.24`. The compiler is pinned to 0.8.28
  in `foundry.toml`.
- OpenZeppelin v5.7.0 and forge-std v1.16.2, pinned in `foundry.lock`; the staged submodule commits must match
  it, and CI checks that. The token uses the upgradeable ERC20 because clones skip constructors, and the
  storage-based `ReentrancyGuard` because its zeroed slot is "not entered" in a clone.
- Custom errors, not revert strings. Immutables in SCREAMING_SNAKE_CASE. Loop counters initialised
  explicitly (`uint256 i = 0`). Modifier logic lives in a private function.
- Tests: one `*.t.sol` per contract, mocks under `test/mocks/`, mainnet constants in
  `test/fork/ForkAddresses.sol`. New behaviour needs a unit test; new revert paths need a test
  hitting the exact error (`vm.expectRevert(abi.encodeWithSelector(...))`). Whitelisting in tests goes through
  `proposeListing`, a `vm.warp` past `LISTING_DELAY`, and `executeListing`.
- Scripts keep their logic in public functions that take explicit arguments (`Deploy.deploy`,
  `ConfigureWhitelist.propose` and `execute`) so tests can call them without environment variables. Environment variables
  are process-global and tests run in parallel, so each variable name is set by exactly one test (see
  `test/Scripts.t.sol`). In tests, script broadcasts come from `DEFAULT_SENDER`.
- Deployments never use raw private keys: `--account` keystores or `--ledger`. `OWNER` and `GUARDIAN` are
  required. On mainnet the owner must be a contract that is not an EIP-7702 delegated account, and a Safe owner
  must need at least two signatures.
- Mainnet addresses are verified on-chain by symbol before being committed. The WBTC address is
  `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599`; an earlier draft had a wrong one.

## Product decisions already made (do not re-litigate silently)

Ethereum mainnet; Uniswap V3 (SwapRouter02 + QuoterV2) for v1; composition fixed at creation;
no fees in v1; component whitelist only (no synthetics for L1 coins without a mainnet wrapper);
burner chooses the exit token (mint currency is not tracked per holder). Rationale in
`ARCHITECTURE.md`. If a change would alter one of these, say so explicitly.

## Not in v1 (candidate backlog)

`mintWithETH` / `burnToETH`, `createAndMint`, `mintWithTokenPermit` for USDC, creator or protocol fees (attribute
them by `creatorOf`, never by name), rebalancing, Chainlink NAV lens, Universal Router / V4 / aggregator zap,
synthetic exposure for L1 coins.
