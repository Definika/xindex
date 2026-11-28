# Retirement of the zap's ether entry points: USDC and USDT are the only currencies

On 2026-11-18 the owner ruled that payments go in and out in stablecoins alone: "lets leave payments with only stable
coins usdt and usdc". Asked how strict the contracts should be, the owner chose the lock on chain over a limit in the
app alone. So, on both deployments, Ethereum's and BNB Chain's:

- `IndexZap` takes and pays its `USDC` and `USDT` and nothing else. `mintWithToken`, `mintWithTokenPermit`,
  `burnToToken` and `burnToTokenWithPermit` revert `NotAStable(token)` on any other `tokenIn` or `tokenOut`, zero
  included, before anything moves.
- `BasketBuilder.buy` is paid, and `BasketBuilder.sell` pays, in the builder's `USDC` or `USDT` alone, with the same
  error. `deposit` and `withdraw` still take any token: they move legs in kind, not a payment.
- `MintRequests` already escrowed USDC and USDT alone, and is unchanged but for its error, `NotAStable`, which moves
  to `IXindexErrors` now that three contracts raise it.

The call reverses the owner's call of 2026-10-29, which widened the zap's entry of 2026-10-14 ("users come with USDC
or USDT") to ether. It also narrows the zap's burn, which had paid out any token the caller named (a component, WBTC
for instance) since the first zap.

What went:

- `IndexZap.mintWithEth`, `burnToEth` and `burnToEthWithPermit`, the zap's `WETH` and its constructor argument, its
  `receive()`, and the errors `NotWETH` and `ValueMismatch`. The zap has no payable entry point and no `receive()`,
  so no call brings ether in or pays it out. Its constructor is `(factory, router, usdc, usdt)`, the builder's too,
  and both refuse a zero address and one stablecoin named twice.
- `DeployWeighted`'s `WETH` setting and argument, and `DeployChecks.pinnedWeth`. `deploy` takes the router, USDC and
  USDT, and gives the same two to the zap, the builder and `MintRequests`; `checkDeployment` refuses a zap or a
  builder whose stablecoins are not `MintRequests'`. A run against one chain's state under the other's id still stops
  at the first address of the wrong book with no code: Ethereum's USDC has none on BNB Chain, and BNB Chain's none on
  Ethereum (read on 2026-11-18), where it stopped at WETH and WBNB before.
- `src/interfaces/IWETH9.sol`, back at `script/interfaces/IWETH9.sol` with `deposit` alone, for the Sepolia test
  market that wraps the ether its pools are seeded with. No contract in `src/` names WETH as a currency; WETH and
  WBNB stay listed components.
- The tests of the ether entry points: in `test/IndexZap.t.sol` the section "ether in and out" (`test_mintWithEth_*`,
  `test_burnToEth_*`, `test_burnToEthWithPermit_*`, `test_receive_takesEtherFromWethAlone`), the three ether variants
  of CR-I26 (`test_CRI26_anEtherMintHoldsTheGuardThroughItsRefund`, `..._anEtherBurnHoldsTheGuardThroughItsPayout`,
  `..._anEtherPermitBurnHoldsTheGuardThroughItsPayout`) and the `EtherRefuser` helper; in
  `test/fork/IndexZap.fork.t.sol` `testFork_mintWithEth`, `testFork_burnToEth`, `testFork_burnToEth_permit` and
  `testFork_burnToWBTC`; in `test/fork/BnbChainAddresses.fork.t.sol` `testFork_theZapMintsAndBurnsInBnb`.

What stands in their place:

- `test_aCurrencyOtherThanTheTwoStablecoinsReverts` (zero, WETH and LINK through all four zap entry points),
  `test_constructor`, `test_buyChecksTheCall`, `test_sellChecksTheCall`, the builder's constructor test,
  `test_deployWeighted_checkDeploymentRefusesOtherStables`, `testFork_aCurrencyOtherThanTheTwoStablecoinsIsRefused`
  on Ethereum's real tokens and `testFork_theZapRefusesBnb` on BNB Chain's. Mutants S1 to S7
  (`test/mutants/mutants.json`) drop each check in turn, and each is killed.
- The pass-through leg, a component that is the call's own currency, is a stablecoin the index holds: DA-15's tests
  and the builder's pass-through sale run on an index of WETH and USDC (`_mixedIndex`, `stableIndex`) instead of a
  WBTC or WETH payout. No listed index holds a stablecoin (A7-22), so on mainnet the leg is not reached; the factory
  does not refuse one, and the zap keeps the rule.
- Tests whose currency was a token of their own (a fee-on-transfer token, a callback token, Tether's pattern, a
  balance behind two addresses) now build a zap or a builder whose USDT is that token (`_payingIn`), as Tether's own
  USDT would be with its fee switch on. Their names and ids are unchanged: I02, CR-I26, LR-05, XS-10, RW-10.

This file says which past findings went with the ether entry points, in the form of
`audits/retired/pancakeswap-zap-venue.md`. **RETIRED** means the mechanism the finding lived in is gone. A retired
id is not free to reuse, and its test must not be restored against a new design.

The check behind this file: the audit ids that name a test in the tree before this change (the red team of
2026-11-14's fixes included), less the ids that name one after it, are none. RY-1 keeps its test, renamed for the half
that stands.

## The red team of 2026-10-31 (`audits/internal/red-team-ry.md`)

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| RY-1 | LOW | `burnToEth` paid ether to WETH's address, which wrapped it back into the zap; a payout to its own token's contract was kept there | RETIRED IN PART | The WETH half went with `burnToEth` and the zap's `WETH`: `_checkIndexCall` no longer names WETH. The other half stands: a burn refuses its own `tokenOut` and a mint its own `tokenIn` as recipient, now `test_RY1_theCallsOwnTokenIsNotAValidRecipient` (was `test_RY1_wethAndTheCallsOwnTokenAreNotValidRecipients`). |
| RY-2 | INFO | Ether forced into the zap is stranded; its comments said no stranger could leave any | RETIRED | Fixed by documentation, which went with `receive()`. Forced ether is still stranded and harmless: the zap pays out no ether at all. |

Unaffected: every finding against the zap's and the builder's token paths keeps its test, among them DA-15, CR-L02,
CR-I26 (its four token tests), CR-I27, CR-I31, XA-22, XA-29, XA-30, RT-21, I02, I03, A1a-05, RW-9 and RW-10.
`test_I03_strayRouterEthIsRefundedNotLocked` in `test/fork/Security.fork.t.sol` now pays in USDC through WETH rather
than in WETH, and still shows that stray ether in the router is never wrapped or taken.
