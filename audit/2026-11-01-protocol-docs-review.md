# Protocol documentation review of 2026-11-01

The owner asked for every protocol Xindex uses to be read in its own documentation, and the code checked against it.
The review read `restock/non-evm` at `1966ac5`. The protocols covered:
- On chain: Pyth and its Hermes API, Uniswap's Universal Router and V3 routers, PancakeSwap v3, Circle's USDC and
  CCTP V2 with the Iris API, Tether's USDT, WETH, Safe, OpenZeppelin, and Wormhole's Token Bridge with Wormholescan.
- The restock's venues: Jupiter, Cetus's aggregator, Panora and Tinyman.
- The web app's services: WalletConnect (Reown), CoinGecko, Coinbase, Kraken and DefiLlama.

Method:
- One independent reviewer, given the code and the docs but no conclusions, read the non-EVM restock: the Solana, Sui,
  Aptos and Algorand signers and the parent's signer home.
- The rest was read here.
- Every high and medium finding of the reviewer was confirmed in the code before it was recorded.
- Where a doc was silent, the protocol's source or its chain was read, and the record says so.

The contracts that hold index funds follow every protocol's documentation; no finding touches them. The findings are
in the keeper's restock service, most in the non-EVM code of 2026-11-01, which has never run against a chain and holds
nothing yet, and in the owner's attestation procedure.

Each id is `PD-…`. The owner's call of 2026-11-02 was to fix all fourteen; "Status of the fixes" below says how each
was fixed, names its tests, which carry its id (`AGENTS.md` gate 6), and its mutants in `test/mutants/mutants.json`.
Line numbers in the findings are at `1966ac5`.

## Findings

| Id | Severity | Finding | Fix |
|---|---|---|---|
| PD-1 | High | The Solana swap's simulation bounds only the swap's two token accounts (`keeper/restock/solana/jupiter.mjs:108-111`, `keeper/restock/solana/verify.mjs:20-46`), and any number of instructions to Jupiter's program pass (`jupiter.mjs:35-45`, `79-87`). Jupiter's `route` takes the wallet's signature as transfer authority over whatever token account it names as source (Jupiter's v6 IDL, `jup-ag/jupiter-cpi`). A compromised `/swap/v2/build` answer adds a second route that sells the wallet's other coin, PYTH during a JUP buy, into an account of its own; every bound still holds. | Bound every token account the wallet owns, unchanged outside the swap; allow exactly one Jupiter instruction; decode its accounts, requiring the input account as source, the output account as destination and no platform fee account. |
| PD-2 | High | Jupiter's on-chain minimum lives in the swap instruction's data (`route(routePlan, inAmount, quotedOutAmount, slippageBps, platformFeeBps)`), which the code never decodes: it checks the answer's JSON `otherAmountThreshold` (`jupiter.mjs:72-77`), and the simulation proves the floor only when it runs. An instruction carrying `slippageBps` 10000 passes every check and leaves the swap open to a sandwich down to nothing, up to one batch (`RESTOCK_MAX_TRANSFER_USD`). | Decode the instruction with Jupiter's IDL (Anchor's coder, already a dependency) and require `inAmount == amount`, `floor(quotedOutAmount · (10000 − slippageBps) / 10000) ≥ minOut` and `platformFeeBps == 0`. |
| PD-3 | High | Cetus's aggregator SDK (1.7.5) takes the package that receives the input coin and runs `confirm_swap_v3`, the floor's check, from the API's answer whenever it names one (`getAggregatorPublishedAt`), over its own pinned default; each hop's DEX package comes from the answer too. The swap's output goes to the wallet with no floor of the code's own (`keeper/restock/sui/moves.mjs:250-251`), and the simulation's bounds hold only when it runs. A compromised answer names a package that skips the floor, or behaves honestly in simulation and keeps the coin on chain. | Pin `aggregator_v3` and allowlist the DEX packages; enforce the floor inside the transaction: `splitCoins(output, [share])` aborts below `share`. |
| PD-4 | Medium | Aptos's `fate` (`keeper/restock/aptos/moves.mjs:100-112`) calls a move expired once the account's sequence number passed the move's, without asking which transaction took it. Behind a load-balanced endpoint, a by-hash lookup on a node a second behind (404) and an account read on a fresher one drop a move that landed: a bridge-in's VAA is never redeemed, a buy is bought again. | Read `/accounts/{address}/transactions?start=N&limit=1` and drop only when another hash holds N; a 410 (pruned) is unknown. |
| PD-5 | Medium | Sui's `fate` treats any error reading a gas coin as expiry (`keeper/restock/sui/moves.mjs:68-70`, `.catch(() => null)`). A timeout or a 429 drops a transaction that can still execute until its epoch ends (Sui's epochs page: "A transaction is only valid if executed before its expiration epoch"), with PD-4's consequences. | Count only a missing coin or a changed version as evidence; rethrow every other error. |
| PD-6 | Medium | A signer marks a transaction in flight when it signs it (`sui/moves.mjs:143`, `aptos/moves.mjs:174`, `algorand/moves.mjs:156`) and refuses every other build until it resolves. When the parent gives up waiting for an answer (`keeper/restock/signer-home.mjs`, the request timeout), the move is never journalled or sent, and the signer waits out its expiry: up to two Sui epochs (about 48 hours), 600 seconds on Aptos, 1000 rounds on Algorand. A completing step rejected before execution, as at an epoch's new gas price, does the same. | Mark in flight on `send`, or let the parent tell the signer to forget a move it did not journal; on a rejected completing step, spend the gas coin's version so the stuck transaction cannot run. |
| PD-7 | Medium | The attestation procedure for the 26 copies still to attest (`design/2026-10-10-one-index-wormhole-legs.md:140-143`) sends the Solana and Sui sources through Portal's own interface. Wormhole retired that interface, legacy Portal, on 2026-06-30, and its docs now describe only the TS SDK route: `createAttestation` on the home chain, `submitAttestation` on Ethereum. Twelve Solana copies, WAL from Sui and RAY's `updateWrapped` wait on it. | Write the SDK route into the procedure; the Solana and Sui signers already carry the SDK, so an `attest` operation there serves the owner. |
| PD-8 | Low | Solana drops a move on a null signature status once its blockhash expired (`keeper/restock/solana/moves.mjs:114-123`, `keeper/restock/solana-sending.mjs`). A node without the history, or one behind, answers null for a transaction that landed (Solana's `getSignatureStatuses` reference on `searchTransactionHistory`). | Before dropping, confirm with `getTransaction` at finalized commitment, or compare the answer's `context.slot` with the finalized slot. |
| PD-9 | Low | After a restart the service advances moves oldest first (`keeper/restock.mjs`), so an older move's redeem or receipt can reach a signer before a newer signed move is resumed. Aptos's and Algorand's signers then sign a second transaction against the same sequence number or wallet. Sui's `gasCoins` does not leave out a journalled move's coins (`sui/moves.mjs:90-107`), so a redeem can equivocate the main SUI coin until the epoch ends. | Resume every signed move of a chain before any other request to its signer. |
| PD-10 | Low, uncertain | Nothing refreshes a stored attestation or VAA (`keeper/restock.mjs:107-138`). Circle encodes an expiry block 24 hours out in a message it signs ("If the burn expires, it must be re-signed", the technical guide), and `TokenMessengerV2` enforces any non-zero one; Circle's docs tie it to Fast Transfers and the restock's are Standard, so whether it can arise is uncertain. Wormhole keeps a superseded guardian set valid for 24 hours, so a VAA held past a guardian set change stops verifying. Either way a move fails every tick until someone re-attests and edits the journal. | Treat "Message expired and must be re-signed" as a state: `POST /v2/reattest/{nonce}`, fetch the new message and replace the journal's; refetch a VAA that no longer verifies. |
| PD-11 | Low | `startSigner` attaches no `'error'` listener to the child or its stdin (`keeper/restock/signer-home.mjs:35-73`). A write to a signer that just died raises EPIPE as an unhandled error, which stops the whole service. | Listen for `'error'` on both and fail the pending requests. |
| PD-12 | Low | Every CCTP burn passes a `maxFee` of 0 (`keeper/restock/evm.mjs:272`, `solana/cctp.mjs:84`, `sui/moves.mjs:285`, `aptos/moves.mjs:295`). Right today: Circle's fees page says Standard Transfers are free, and only Sei's deployment has a fee switch. Should Circle switch one on for a route in use, the burn reverts in simulation and nothing is lost. | Optional: read `GET /v2/burn/USDC/fees` and set a bounded `maxFee`. |
| PD-13 | Low, uncertain | Panora documents no meaning for `router_entry`'s arguments. The code writes the floor into the `u64` the on-chain ABI places after the input amounts (`aptos/moves.mjs:262-270`) and leaves the next two, a `u64` and an address, unchecked. The router is upgradeable (compatible policy, 17 upgrades, no published source). | Confirm on mainnet that a floor above the quote aborts; pin the two arguments. |
| PD-14 | Low | Reown's docs: an empty domain allowlist lets any origin use the project ID, which ships in the site's bundle (`PUBLIC_WALLETCONNECT_PROJECT_ID`). The setting lives in Reown Cloud, not in code. | List `xindex.io` and `testnet.xindex.io` in Reown Cloud. |

Informational, no fix proposed:
- The design record's D3 says each key lives in its child signer. The non-EVM keys sit in the parent's environment
  (`keeper/restock/config.mjs`) and reach each child through the env allowlist. The isolation that matters holds: no
  child sees `TREASURY_KEY`.
- Solana's `verifyCctp` skips its simulation while the wallet's USDC account is missing.
- Fees are fixed: Aptos pays a gas price of 100 octas, Algorand a flat fee. Under congestion a move expires rather
  than lands.
- Algorand's checks refuse the closing fields but not `rekeyTo` on a wallet-signed transaction. This matters only as
  defence in depth, since every transaction is built here.
- Aptos balances are read from `FungibleStore.balance`. Should Aptos turn on concurrent fungible balances (feature 68,
  off on 2026-11-01), every APT move would be refused, which is a safe failure.
- Sui's CCTP package ids are pinned. Circle's state objects are version-gated, so a Circle upgrade stops the calls
  until the ids are updated.
- Algorand's USDC opt-in is checked neither by `info()` nor in the design record's setup list.
- Tinyman's USDC/ALGO pool held about 768.6k USDC, so large batches halve under the 100 bps bound.
- CoinGecko's Demo budget is about 9,100 of 10,000 calls a month (the backend's README). Each worker restart refetches
  the id list and runs the price job at once.

## Status of the fixes

All fourteen were fixed on 2026-11-02. Each fix's logic sits in a module with no dependency, so the keeper's unit
tests (`node --test keeper/test/unit/*.test.mjs`, 175 passing) cover it in CI, which installs nothing for them; the
signers only wire it to their SDKs. The mutation gate now runs node suites too (`"runner": "node"` in
`test/mutants/mutants.json`, `test/mutants/run.py`), and each fix adds its mutants there: P1 to P24, all killed. Fixing
turned up four more faults, fixed with the findings they belong to, and three fixes differ from what the table
proposed; both are said below.

- **PD-1** (`keeper/restock/solana/checks.mjs`, `verify.mjs`, `jupiter.mjs`): `checkJupiterSwap` requires exactly one
  instruction to Jupiter's program, a route of `JUPITER_ROUTES`, with the wallet as signing authority, the wallet's
  input account as source, its output account as destination (an optional override may name only that account or
  none), the asked mints and no platform fee account. The simulation holds every token account the wallet owns, under
  both token programs, to no change (`withEveryAccount`, at most 64). Found while fixing:
  - Solana's public RPC returns at most 3 accounts from a simulation ("Too many accounts provided; max 3"), which
    refused every move. `simulateInChunks` asks again in chunks of the size the node names.
  - A token account the wallet holds may carry another's close authority or delegate from before the move, which the
    "wallet's alone" check refused. Only the move's own accounts must be the wallet's alone now; every other must keep
    its owner, delegate and close authority bytes unchanged.

  Tests: `PD-1: one Jupiter instruction, …`, `PD-1: every other token account …` and `PD-1: a node that caps …`. Mutants
  P1, P2, P23 and P24. On mainnet on 2026-11-02, the check simulated a wallet holding eight token accounts, one with a
  close authority, through the public RPC in chunks of three, and passed.
- **PD-2** (`keeper/restock/solana/idl-decode.mjs`, `checks.mjs`): the swap instruction is read by Jupiter's IDL, which
  the signer reads from the program's IDL account on chain, hourly, since every upgrade adds venues to the route plan.
  A dependency-free Borsh reader takes the arguments from the front, as the program does, and refuses bytes after
  them: the v1 routes put their amounts after a plan of variable length, where a decoy appended at the end would
  otherwise be read. `checkJupiterSwap` then requires `in_amount` to be the amount, no platform fee and no kept
  surplus, and `floor(quoted_out_amount · (10000 − slippage_bps) / 10000)` at or above the floor. The reader was checked
  against six live Jupiter swaps (`route` with one to three steps, and `route_v2`): every measurable `in_amount` equals
  the source account's balance change. One of them carried a slippage of 10000 bps, the case this finding is about.
  Jupiter's repository publishes its IDL under no license, so no copy is committed; the tests use an IDL and
  instructions of our own in its shape. Tests: `PD-2: the swap's arguments are read from the front …` and `PD-2:
  Jupiter's on-chain minimum …`. Mutants P3 and P4.
- **PD-3** (`keeper/restock/sui/checks.mjs`, `moves.mjs`): a route may name only Cetus's own aggregator package, the
  SDK's pinned `AGGREGATOR_V3_CONFIG.DEFAULT_PUBLISHED_AT`, or an upgrade of it, the same original package as read on
  chain (`checkAggregator`). The floor is split off the output inside the transaction (`payWithFloor`): Sui's
  `splitCoins` aborts below it.
  - Unlike the table: the DEX packages are not allowlisted. A route's packages touch only the input coin, and with the
    floor held on chain none of them can take more than the plan's loss bound. An allowlist would also stop every swap
    at each DEX upgrade.
  - On mainnet on 2026-11-02: a live route named the pinned package, and the check passed against its original. A swap
    of 10 SUI simulated as a holder succeeded with the floor at 99% of the quote, and aborted with the floor above the
    output (`InsufficientCoinBalance`).

  Tests: `PD-3: the swap's input goes only to Cetus's own aggregator package …` and `PD-3: the floor is split off …`.
  Mutants P5 and P6.
- **PD-4** (`keeper/restock/aptos/checks.mjs`, `moves.mjs`): unlike the table, by ledger versions rather than the
  account's transaction list. The public node's `/accounts/{address}/transactions` answered `[]` for an account with a
  committed transaction (read on 2026-11-02), so a lookup by sequence number would never see the transaction holding
  it, and a dead move would have blocked the signer for good. `fate` reads the account, then the hash, each with the
  ledger headers every Aptos answer carries, a 404 included. A passed sequence number expires a move only when the hash
  lookup's node is at or past the account read's version and still keeps the version the transaction was built at,
  which its expiry now records (`sentVersion`). A node behind means wait; one that pruned means unknown, which the
  parent reports instead of dropping the move. On mainnet on 2026-11-02 the four branches answered as tested. Test:
  `PD-4: a passed sequence number expires a move only from a hash lookup at or past …`. Mutant P7.
- **PD-5** (`keeper/restock/sui/checks.mjs`): only the SDK's own not-found errors count (`ObjectError` code `notExists`,
  `TransactionError` reason `notFound`), read by their fields; any other failure is thrown and the move asked about
  again. On mainnet, a never-sent digest with a gas coin that never existed answered "expired: no longer exists". Test:
  `PD-5: only a gas coin that is gone …`. Mutant P8.
- **PD-6** (`keeper/restock/inflight.mjs`, the Sui, Aptos and Algorand signers, `signer-home.mjs`): one tracker for the
  three signers puts a transaction in flight when it is sent, never when it is signed, so a move the parent gave up
  waiting for holds nothing. The parent sends each move with its digest and expiry.
  - Unlike the table, a completing step the chain refuses outright (`refusedOutright`: a 4xx, or a gRPC status naming
    the transaction invalid) is forgotten rather than cancelled: it holds no gas coin or sequence number, and a
    completing step that ran after all would find its work done. A move the parent journalled is never forgotten, and
    its chain's expiry still bounds the wait.
  - No transaction is sent to spend a gas coin's version: on Sui, two transactions over one live version can lock the
    coin for the rest of the epoch.

  Tests: the three `PD-6` tests in `restock-inflight.test.mjs`, and `PD-6: a move goes to the signer with its digest and
  expiry …`. Mutants P9 and P10.
- **PD-7** (`keeper/restock/attest.mjs`, the Solana and Sui signers' `attest`, `restock.mjs`): `node restock.mjs
  --attest <chain> <token>` follows Wormhole's documented SDK route. The chain's signer attests, after a simulation in
  which no token of the wallet moves; the guardians' signed attestation is fetched and checked on Ethereum's core; the
  treasury creates the copy, or updates it when it exists (RAY). The procedure in
  `design/2026-10-10-one-index-wormhole-legs.md`, section 2a, now says so. Tests: the three `PD-7` tests in
  `restock-attest.test.mjs`, and `PD-7: a token attestation's chain, address, decimals …`. Mutant P11.
- **PD-8** (`keeper/restock/solana-sending.mjs`, `solana/moves.mjs`, `signer-home.mjs`): a Solana expiry records the
  slot the transaction was built at. A null status drops a move only when the node that answered is at or past the
  finalized slot, keeps the slots back to that one, and has no record of the transaction (`getTransaction`, whose
  "history is not available" counts as unknown). Otherwise the move is reported unknown and stays signed. On mainnet,
  a landed swap with an expired blockhash answered landed, and a never-sent signature answered expired, from the
  public RPC. Tests: `PD-8: a null status drops a move only from a node caught up …` and `PD-8: a move whose fate the
  node cannot show …`. Mutants P12, P13 and P14.
- **PD-9** (`keeper/restock/journal.mjs` `resumeOrder`, the signers' `status`): a round resumes every signed move first,
  and every signer's `status` puts a move that may still execute back in flight, so no completing step is built over
  it. Test: `PD-9: a round resumes every signed move before …`. Mutant P15.
- **PD-10** (`keeper/restock/advance.mjs`, moved out of `restock.mjs` so it is tested):
  - A Circle signature the receiving chain refuses is never stored for the move. One whose message carries an expiry
    is re-attested (`POST /v2/reattest/{nonce}`) at most once an hour, and the fresh signature is received.
  - A stored one that went stale before its receipt is replaced the same way.
  - A VAA that no longer verifies is fetched again; with none newer, the move waits with the reason.

  Tests: the four `PD-10` tests in `restock-advance.test.mjs`, and `PD-10: a CCTP message's nonce and expiry …`.
  Mutants P16, P17 and P18.
- **PD-11** (`keeper/restock/signer-home.mjs`): the child and its input each have an `'error'` listener that fails what
  is waiting; the next request starts the signer again. Test: `PD-11: a signer whose input closed under a write …`,
  which writes to a signer that closed its input; unheard, the EPIPE ended the test process. Mutant P19.
- **PD-12** (`keeper/restock/attestations.mjs` `cctpMaxFee`, every burn): each burn allows the route's standard fee from
  Iris's table (`GET /v2/burn/USDC/fees/{source}/{destination}`), rounded up, and refuses a rate above
  `MAX_CCTP_FEE_BPS` (10). The table read 0 for every route used on 2026-11-02, so nothing paid changes. Test: `PD-12:
  a burn allows the route's standard fee …`. Mutant P20.
- **PD-13** (`keeper/restock/aptos/checks.mjs` `checkPanoraArgs`): a simulation of 2026-11-02, as an APT holder, settled
  the uncertainty. With argument 17 at the quote's minimum the swap succeeded; one unit above the quote, it aborted with
  `E_OUTPUT_LESS_THAN_MINIMUM_TRY_INCREASING_SLIPPAGE`. Arguments 18 and 19 are Panora's integrator fee: no fee is
  1e16 and Panora's own address, on four swaps both ways, and asking for 0.1% to an address set them to about 1.1e16
  and that address. Both are pinned.
  - Found while fixing: argument 16 is one amount per split, and Panora split a 10 USDC swap five ways. The check
    demanded a single amount, so most swaps would have been refused; the splits must now add up to the amount.

  Test: `PD-13: Panora's swap spends exactly the amount …`. Mutants P21 and P22.
- **PD-14** (the site's README, in its own repository): the WalletConnect project ID's domain allowlist is a Reown
  Cloud setting. The README now says to list `xindex.io` and `testnet.xindex.io` there before the site goes live. Fixed
  by documentation; the setting itself is the owner's to make.

The EVM restock end-to-end test ran again on the changed `restock.mjs` (the extracted advance, the resume order and
the fee-bounded burns), on Tenderly's public archive and forks of the home chains; its fake Iris now serves the fee
table too. It passed, 94/0, as before the fixes: every chain's round trip, and both restarts.

## Checked and consistent

Pyth:
- The hub's pattern is the delayed settlement Pyth's best practices recommend. The price second is fixed one slot back,
  and `parsePriceFeedUpdatesUnique` accepts only the first update at or after it
  (`prevPublishTime < minPublishTime <= publishTime <= maxPublishTime`), so a submitter cannot choose among updates.
- The window is under 12 seconds wide. The hub refuses a confidence wider than 2% and a price 5% off the moving
  average, reads every moving feed at a start (market hours), and checks the exponent's range.
- The keeper pays `getUpdateFee` exactly.
- Hermes serves at `pyth.dourolabs.app/hermes` with `Authorization: Bearer`, which the keeper and the backend both
  use. Hermes's source confirms that `/v2/updates/price/{publish_time}` returns each feed's first update at or after
  the time (`RequestTime::FirstAfter`).
- No key reaches a browser, as Pyth's docs require.

Uniswap's Universal Router:
- Every command is built in the contract. The router is pre-funded and swept back in the same `execute`.
- The allow-revert flag, which the README warns about, is never set. The deadline is the zap's own.
- V4 routes are hookless, with native ether allowed only as an intermediate. Delivery is measured as a balance change
  (`ShortFill`).

WETH, USDT and permits:
- The zap's `receive()` reads one immutable, inside the 2300 gas WETH's `withdraw` forwards.
- USDT's no-return transfers and zero-first approvals go through `SafeERC20`.
- Permits are tried and caught, as OpenZeppelin advises against front-run permits.

Safe: the deploy checks read `getThreshold`, `getModulesPaginated` from the sentinel, and `getOwners`, as Safe's
interface defines them.

OpenZeppelin 5.7.0:
- No published advisory affects it. The latest, in `Bytes.lastIndexOf`, covered 5.2.0 up to 5.4.0 and is not used.
- The hub's implementation calls `_disableInitializers()`, and each clone is created and initialized in one
  transaction.
- The reentrancy guard's namespaced slot reads zero as not entered, so it works in clones.

Wormhole:
- Payload transfers can be completed only by their recipient, the executor.
- The executor checks the arriving token through `wrappedAsset`.
- Ethereum's message fee is 0 (read on chain); the executor forwards whatever is sent, and resets its approvals.
- Amounts are measured as balance changes, so the eight-decimal truncation is harmless.
- A Governor delay only makes the restock wait.
- Ethereum's core has 19 guardians (read on chain).
- No listed copy's home chain is among the networks Wormhole deprecated: Terra, Oasis, Aurora, Acala, Karura, XPLA,
  Fantom, Mantle, X Layer, Scroll, Berachain and Injective (INJ is Ethereum's own ERC-20).
- The reviewer matched every non-EVM core, token bridge and emitter to the SDK's contracts and to Ethereum's
  `bridgeContracts`.
- Each transfer path matches its chain's documented entry point.

Circle CCTP V2:
- `depositForBurn` takes V2's seven arguments. A zero `destinationCaller` lets anyone receive, and the mint still goes
  to `mintRecipient`. Finality 2000 makes a transfer Standard.
- Messages come from Iris v2 `GET /v2/messages/{domain}?transactionHash=`, are checked against the move's fields, and
  are verified by simulating the receive.
- The reviewer matched Solana's programs, accounts and five-day event-account reclaim, Sui's seven ids and its PTB,
  and Aptos's transmitter and script arguments to Circle's docs and examples.

The restock's EVM venues: every router, quoter, factory, USDC, token bridge and CCTP address matches the documented
deployments. Swap bounds come from Pyth prices, and leftover allowances to the immutable routers can be spent only by
the wallet itself.

Jupiter, Tinyman and the chains (the reviewer):
- Jupiter's `/swap/v2/build` endpoint, `x-api-key`, parameters and fields are as documented.
- Tinyman's app, pool and fixed-input group are as documented.
- Solana's expiry rule (the blockhash past `lastValidBlockHeight`) and Algorand's (`lastValid` on algod and the indexer)
  are sound.
- The journal writes ahead with fsync and rename.

Backend and site: CoinGecko is called with the Demo key header and credited on the coin pages. Only the WalletConnect
project ID is public in the site's bundle.

## Not reached

- solana.com answered 429; its docs were read from their GitHub source.
- Sui's equivocation guide answered 404; its epochs page was used.
- Circle's message-format page answered 404; its technical guide was used.
- Panora publishes no argument reference; its example and the on-chain ABI were used.
- Jupiter publishes no IDL; `jup-ag/jupiter-cpi` was used.
- Cetus's docs do not describe on-chain enforcement; the SDK's source was used.
- Uniswap's new developer site gave no command encodings; the commands stay pinned by `UniversalRouterCommands` and
  the fork suites.

## Sources

- Pyth: https://docs.pyth.network/price-feeds/best-practices,
  https://api-reference.pyth.network/price-feeds/evm/parsePriceFeedUpdatesUnique,
  https://docs.pyth.network/price-feeds/core/fetch-price-updates, and Hermes's
  `apps/hermes/server/src/api/rest/v2/timestamp_price_updates.rs` in `pyth-network/pyth-crosschain`.
- Uniswap: https://github.com/Uniswap/universal-router (README).
- Circle: https://developers.circle.com/cctp/technical-guide, https://developers.circle.com/cctp/concepts/fees,
  https://developers.circle.com/api-reference/cctp/all/reattest-message, and `src/v2/TokenMessengerV2.sol` in
  `circlefin/evm-cctp-contracts`.
- Wormhole: https://wormhole.com/blog/sunsetting-portal-legacy-what-you-need-to-know,
  https://wormhole.com/docs/products/token-transfers/wrapped-token-transfers/guides/attest-tokens/ and
  https://wormhole.com/blog/updates-to-wormholes-supported-networks.
- Jupiter: https://developers.jup.ag/docs/swap/build and `jup-ag/jupiter-cpi`'s `idl.json`.
- Cetus: https://cetus-1.gitbook.io/cetus-developer-docs/developer/cetus-aggregator/features-available.
- Sui: https://docs.sui.io/concepts/sui-architecture/epochs.
- Aptos: https://api.mainnet.aptoslabs.com/v1/spec.
- Reown: https://docs.reown.com/cloud/relay.
- OpenZeppelin: the repository's published security advisories.
