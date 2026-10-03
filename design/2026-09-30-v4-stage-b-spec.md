# Xindex v4 Stage B: contract specification (draft)

Stage B adds the native coins of BNB Chain, HyperEVM, Tron and Solana, held in vaults on their own chains, to indexes
whose shares live on Ethereum. The design is `design/2026-09-29-v4-hybrid-architecture.md`, sections 3 to 8. This spec
fixes what the design leaves open, and marks each deviation from it as a proposal for the owner.

**Status: draft, 2026-09-30; section 1 decided the same day; statuses brought up to date with `main` on 1 October
2026.** Built and gated on `main`, and deployed nowhere: the message format, the EVM vault, the factory's chain registry
and the hub's three parts (section 5), the BNB Chain and Tron state verifiers (5.1, 5.7), P1 and P2 with their verifier
contracts (sections 10 and 11), the Solana vault and P1 on Solana (sections 7 and 10), and the scripts that deploy a
vault chain, deploy a state verifier and register a chain (`script/DeployVault.s.sol`,
`script/DeployStateVerifier.s.sol`, `script/ConfigureChains.s.sol`). Section 6 lists what remains. P1 and P2 prove full
finality, and have run only in their zkVMs' execute mode: no proof of either has been generated yet
(`proofs/README.md`). Everything that depends on which Ethereum-finality proof is used sits behind one interface
(section 3), so the sync-committee fallback stays open until the owner's GPU run (M4 in
`design/2026-09-30-proving-prototype.md`) prices a proof against the prototype's $50 and 60-minute thresholds.

## 1. Proposals for the owner (deviations from the design)

**Decided by the owner on 2026-09-30: all five adopted.** Proposals 1, 2, 4 and 5 were chosen explicitly. Proposal 3 was
put forward as going ahead unless the owner objected, and the owner did not. Each is now a recorded decision of Stage B.

1. **A separate hub template, `HybridHub`, for indexes with vault tokens.** The design (4.2) extends one `IndexHub`.
   Proposed instead:
   - Stage A's `IndexHub` stays exactly as audited, and keeps serving indexes held entirely on Ethereum.
   - A new clone template serves any index with a component on another chain; the factory picks the template from the
     component list.

   Why: an Ethereum-only index then carries none of the multichain code's risk, and Stage A's audit stays valid.
   The cost is two templates to maintain.
2. **BNB Chain → Ethereum without a zkVM.** The design (4.4) calls for one proof system per chain. For BNB Chain,
   that system is the chain's own finality vote, checked on Ethereum with the EIP-2537 precompiles, plus a
   Merkle-Patricia storage proof. The prototype measured about 650k gas (`design/2026-09-30-proving-prototype.md`).
   No circuit and no trusted setup are involved. HyperEVM and Tron get the same treatment where their consensus allows,
   each decided when its verifier is built. (Since then, section 8: Tron's verifier is built, proving a vault call's
   success rather than a storage proof, and HyperEVM has no state root to prove against.)
3. **One state commitment per index on a vault.** The design's `VaultState` carries settled balances, paid totals
   and pending deposits (5.3). A vault instead keeps two kinds of 32-byte digest, each updated whenever what it covers
   changes:
   - per index, a digest of that index's balances and paid totals;
   - per intake (a mint order or a rebalance delivery), a digest of its deposits.

   Ethereum proves one storage slot per index and one per intake, and takes the preimages as calldata.
4. **The speed limit is exact over any 24 hours, counted in hourly buckets.** A token bucket that refills 4% a day
   would let 8% leave in the worst 24 hours, doubling the worst cases of section 8.1. So would 24 hourly buckets: a
   payout at the end of one hour and another 23 hours later fall in different windows. Proposed instead:
   - each payout is added to its hour's bucket;
   - a payout is allowed only if the current hour and the 24 before it, 25 buckets, plus the payout stay within 4% of
     the index's balance before those outflows.

   Every real 24-hour span lies inside those 25 buckets, so outflow in any 24 hours is at most 4%, exactly. The price is
   a limit counted over up to 25 hours, slightly stricter than the design's.
5. **A small outflow floor per token.** A limit of 4% of the current balance halves what is left geometrically, so
   the last holders of an index's vault balance could never take it all out: this is the design's open question on
   small indexes and the speed limit (section 15). Proposed: each token carries a quantity floor, set with its cap by
   `CAP_UPDATE`, below which a day's payouts are always allowed.
   - A forged burn gains at most the floor, and only from an index whose balance is already below the floor divided
     by the limit.
   - The floor is a quantity, so no price is read. The owner sets it at the supply reviews, for example the coins worth
     about $1,000 at launch.

## 2. Messages (Ethereum → vault)

Every message is an event on Ethereum:

```solidity
event VaultMessage(bytes32 indexed id, bytes payload);
// payload = abi.encode(DOMAIN, SOURCE_CHAIN_ID, kind, destChainId, vault, index, nonce, body)
// id      = keccak256(payload)
```

| Field | Value |
|---|---|
| `DOMAIN` | `keccak256("xindex.v4.vault-message")` |
| `SOURCE_CHAIN_ID` | 1 (Ethereum), or 11155111 on Sepolia |
| `kind` | one of the kinds below |
| `destChainId` | the vault chain's EVM chain id, which an EVM vault checks against `block.chainid`: 728126428 on Tron (section 8); Solana, which has none, gets an id in the chain registry (section 7) |
| `vault`, `index` | the vault's 32-byte id on its chain, an EVM vault's address as a word (section 7); the Ethereum address of the hub, or of the factory for governance |
| `nonce` | unique per `(index, destChainId)` and kind, so identical burns have different ids |

| Kind | Emitter | Body | Proof policy | Effect on the vault |
|---|---|---|---|---|
| `BURN` | the index | `(token, amount, recipient)` | P1 **and** P2 | pays `recipient`, within the speed limit, else owes it |
| `INTAKE_SETTLED` | the index | `(intakeId)` | P1 **and** P2 | the intake's deposits join the index's balance |
| `INTAKE_FAILED` | the index | `(intakeId)` | P1 **and** P2 | each depositor can take their deposit back |
| `MIGRATE` | the old index | `(newIndex, token, amount)` | P1 **and** P2 | moves coins from the old index's balance to the new one's, within the speed limit, else owes the rest (6.7, section 5.5) |
| `CAP_UPDATE` | the factory | `(token, cap, floor)` | raise either: **and**; lower both: **or** | sets a quantity cap and an outflow floor |
| `FREEZE` | the factory | `()` | P1 **or** P2 | freezes the vault for `FREEZE_DURATION` |
| `FREEZER_CHANGE` | the factory | `(freezer)` | P1 **and** P2 | replaces the guardian's freeze address |
| `VERIFIER_ROTATION` | the factory | `(p1, p2)` | P1 **and** P2 | replaces the verifiers (the 30-day delay runs on Ethereum) |

A vault accepts a message only if:
- the domain, the source chain, the destination chain and the vault are its own;
- the emitter the proof names is the index, or the factory for governance kinds;
- its id was never used. Each id is marked used before any coin moves.

**Sending again (LG-1).** A proof covers a log inside its transaction's receipt, and whoever sends a transaction shapes
that receipt: a permissionless call that emits a message, wrapped in a transaction of hundreds of other logs or a
receipt past 64 KB, could exceed what a vault chain's verifier can take, and nothing would emit the message again. So
the index and the factory each mark every message they send (`_sentMessages` in the hub, `messageSent` in the
factory), in the transaction that sends it, and anyone may call `resendMessage(payload)` to emit a marked message again,
unchanged, in a transaction of their own. The copy carries the same id, so the vault runs it at most once, and a stale
governance message is still refused by its nonce mark. Every verifier has some ceiling (P1 on Solana's is about 19,600
logs, by compute), so this, not the ceiling, is what keeps a message deliverable.

## 3. The Ethereum-event verifier interface

```solidity
interface IEthereumEventVerifier {
    /// Proves that a log with this emitter, first topic and data is in an Ethereum block that has reached the
    /// finality the verifier implements; reverts otherwise.
    function verifyEvent(bytes calldata proof)
        external view returns (address emitter, bytes32 topic0, bytes32 topic1, bytes memory data);
}
```

Section 5.6 adds the log's block number to what `verifyEvent` returns, and `verifyCheckpoint`.

P1 and P2 each implement it, over different proofs of the same event. For "and" the vault calls both, and both must
name the same emitter, topics and data. For "or" one suffices. Under the sync-committee fallback, a verifier
implementing the same interface would add the challenge delay itself. So the vault stays unchanged whichever way the
owner decides.

## 4. The EVM vault (BNB Chain, HyperEVM, Tron)

One vault per chain, shared by every index, with no owner and no upgrade. Its immutables and its storage:

| Immutable | Meaning |
|---|---|
| `SOURCE_CHAIN_ID`, `FACTORY`, `HUB_IMPLEMENTATION` | Ethereum's chain id, the factory and the hub template; an index is legitimate if its address is the factory's clone of the template under some salt, which anyone can check (`registerIndex(index, salt)`) |
| `SPEED_LIMIT` 4%, `FREEZE_DURATION` 14 days | as in the design's section 12 |

| Storage | Meaning |
|---|---|
| `balance[index][token]`, `paidTotal[index][token]` | settled holdings and cumulative payouts |
| `deposited[index][intakeId][token][depositor]`, `intake[index][intakeId]` | deposits held for an open intake, and its state (Open, Settled, Failed) |
| `owed[index][id]` | a burn accepted but beyond the speed limit, payable later by anyone |
| `outflow[index][token][hour mod 25]` | the hourly buckets of the speed limit |
| `used[id]` | messages already delivered |
| `cap[token]`, `outflowFloor[token]`, `held[token]` | quantity cap across all indexes, the speed limit's floor, and what the vault holds against the cap |
| `p1`, `p2`, `freezer`, `frozenUntil` | verifiers, the guardian's freeze address, the freeze |
| `indexDigest[index]`, `intakeDigest[index][intakeId]` | the commitments Ethereum proves (section 1, item 3) |

Tokens are the native coin (`address(0)`) in Stage B. ERC-20 deposits are measured as balance increases, as
`MintRequests` does, when a chain's listed tokens need them.

**Deposits.** `deposit(index, intakeId)` is payable, and works while not frozen and within the native coin's cap.
- It adds to the depositor's share of an open intake.
- An intake id carries its deposit deadline in its top 64 bits, `(deadline << 192) | nonce`. So nobody can open
  someone else's intake with a different deadline, and deposits close at the deadline for everyone.
  - Ethereum settles an intake only from a vault state proven at a height after its deadline, so the hub settles
    exactly the deposits it counted.
  - A first deposit may not set a deadline more than `MAX_INTAKE_LIFE` (7 days) ahead.
- An intake is Open from its first deposit until a message settles or fails it. Deposits cannot be withdrawn while it
  is open, which is what makes a proven deposit binding.
- The vault never refunds on a timeout. A refund after a delayed settle message could let a minter keep both the shares
  and the coins. The hub instead fails any intake it has no live order for, so every depositor can always get a refund
  message.
- Coins sent without `deposit` count for no index, as the design requires (4.3).

**Payouts.** `deliver(proof1, proof2)` runs a proven message, and `release(index, id)` pays an owed burn once the
speed limit allows. A burn never pays more than the index's balance, and a payout above the limit waits instead of
failing, so nothing expires. While frozen, nothing is paid and no deposit is taken. Accepted burns stay owed.

**Invariants**, checked by an invariant suite:
- **V1:** for every token, the vault's actual balance is at least `held`, and `held` is the sum of every index's
  `balance` plus the deposits of every open intake and of every failed intake not yet refunded. An owed burn is not
  added: it is paid out of its index's balance, which still holds it.
- **V2:** a message pays at most once.
- **V3:** a burn pays at most its index's balance.
- **V4:** outflow over any 24 hours is at most `SPEED_LIMIT` of an index's balance before it, or the token's floor if
  that is larger.
- **V5:** each digest is always the hash of the state it covers.

**Not in this first step:**
- the stall-gated recovery and the snapshot exit (design 6.9), built since (section 5.6);
- Tron's TVM differences, checked since by running the vault on TRON's VM (section 5.7, `tron/`): none needs a code
  change. No audit has reviewed them yet.

## 5. Ethereum side

- **The chain registry** in the factory: `proposeChain(chainId, vault, stateVerifier)` behind `LISTING_DELAY`, as the
  design sets out (4.1). The registry also carries the chain id assigned to Solana; Tron's is its own `block.chainid`.
- **`HybridHub`** (proposal 1): Stage A's in-kind logic for Tier 1 tokens, plus:
  - the mirror per vault token (7.2);
  - mint orders with the 24-hour lock and automatic voiding (6.3);
  - redemption that emits `BURN` messages (6.5);
  - the rebalance with deliveries, bond and settlement (6.6);
  - `MINT_CAP`, per-chain freeze flags, migration, recovery addresses.
- **A state verifier per chain.** For BNB Chain, the prototype's vote check and storage proof, plus validator-set
  tracking, set out in section 5.1. For Tron, a vault call proven in a solidified block (section 5.7). Section 8 has the
  other chains.

### 5.1 The BNB Chain state verifier (built 2026-09-30)

BNB Chain rotates 4 to 5 of its 21 active validators at every epoch block (every 1,000 blocks, 7.5 minutes), from the
45 elected each day. The prototype record first assumed daily changes; that was wrong, and the owner chose on
2026-09-30 to **follow every rotation** (over a zk proof of the rotation chain, an optimistic scheme with a challenge
hour, and trusting the pool of 45). The rules, from bnb-chain/bsc v1.7.8 and checked against mainnet:

- **Epochs and turns.** An epoch block is a multiple of 1,000 (Maxwell; Fermi kept it). Its extra data lists the next
  set, `count` entries of a 20-byte address and a 48-byte compressed BLS key in ascending address order, then a
  turn-length byte, which governance sets (8 today, 16 a year ago), so it is read from each header, never assumed.
- **The switch.** Epoch block `E`'s set signs the votes whose target is at least
  `E + (n/2 + 1) * t`, where `n` and `t` are the previous set's size and turn length: the snapshot takes the new set
  while applying block `E + (n/2 + 1) * t - 1`, and a vote on target `T` is checked with the snapshot at `T - 1`. On
  mainnet, 21 validators and turn length 8 put the first block the new set signs at `E + 88`.
- **Finality.** A block `B` is final once a vote whose source is `B` and whose target is `B + 1` carries at least
  `ceil(2n/3)` of the active set: 14 of 21. A vote signs `keccak256(rlp([source number, source hash, target number,
  target hash]))` under the proof-of-possession ciphersuite; its bitset indexes the set in ascending address order.
- **Following the chain.** The verifier starts from one epoch block its deployer names, and then takes each next epoch
  block, exactly 1,000 later, with the vote that finalized it by the set it replaces. Nothing can be skipped: each set
  is known only through the previous one. Anyone can submit, several epochs to a transaction. The latest set may name
  the next only within `MAX_LAG` (1 day) of its own epoch block (BNB-2). BNB Chain punishes a conflicting vote only for
  a recent target, and a set long superseded may have unbonded and its keys changed hands, so an old set must not name
  the next. A verifier left a day behind therefore stops for good: BNB deposits wait until the registry replaces it,
  which takes `ROTATION_DELAY` (FAC-1). Holders redeem throughout.
- **Keys.** A header carries compressed keys; the submitter adds the uncompressed ones, and each must have the same x,
  the y the sign flag names, and lie on the curve (G1ADD checks that). That makes it the key the header names, which
  BNB Chain checked for the subgroup when the validator registered it, so no subgroup check is repeated here.
- **State.** A storage proof of block `B` names the epoch whose set signs `B + 1`; the verifier checks that the target
  lies in that set's window and that `B`'s timestamp is after that epoch block's and at most `MAX_SPAN` (15 minutes,
  twice an epoch at 0.45 seconds a block) after it. Old sets stay valid for their own windows forever, so without that
  bound a coalition of validators from long ago could forge a header in an old window with a timestamp of today. And
  `B` must be at most `MAX_LAG` (1 day) old, or the same coalition could forge one dated then, which a reader that
  takes old states, such as evidence of an outflow or of an exit, would accept (BNB-2). The hub must also refuse a
  state older than one it has already accepted from the same vault.
- **Carried-over keys.** About 16 of each set's 21 keys were in the set before. A step names, for each entry, either
  the index of the same key in the previous set or a new key; a carried-over key is only matched against the header's
  compressed key, since it was checked on the curve when its own set was recorded.

**Measured cost** (`src/verifiers/BnbStateVerifier.sol` on mainnet data, `test_gas_followingTheChain`; each figure is
a whole transaction, calldata included):

| What | Gas |
|---|---|
| One epoch in a transaction | 510k |
| Two epochs in a transaction | 462k each |
| Following the chain, 192 epochs a day, two to a transaction | 89M a day |
| A state proof of two storage slots | 820k |

At 0.23 gwei and ETH at $2,700 (2026-09-30), following the chain costs about **$20k a year**; at 1 gwei, about
$87k. The estimate put to the owner before the choice was $14k a year at the same prices (330k gas an epoch); the
measured figure replaces it. Of an epoch's 462k, the vote check is about 210k (the pairing 103k, hashing to the curve
74k), the header about 70k with its calldata, the new keys about 40k, and the record 50k. A cheaper form, one pairing
for several epochs' votes (BLS aggregate verification over distinct messages), would save about 60k an epoch at eight
to a transaction, but it mixes two signature checks whose combination needs its own security argument, so it waits
for review.

### 5.2 The factory and `HybridHub`, layer 1 (built 2026-09-30)

The Ethereum side is built in layers, each committed only when every gate is green. Layer 1 is the chain registry,
vault-token listings, and a `HybridHub` that mints through orders and redeems through burns. It does not rebalance.

**The factory.** `HybridIndexFactory` extends Stage A's `IndexFactory`, which gains only two internal hooks: which
template an index is a clone of, and how to initialize it. Stage A's behaviour is unchanged, and its `IndexHub` is
byte-identical: an index of Ethereum tokens only is still an `IndexHub` clone.
- **Chains.** `proposeChain(chainId, vault, stateVerifier)` by the owner, executable by anyone after `LISTING_DELAY`
  and within `PROPOSAL_WINDOW`, cancellable by the owner or guardian. Chain id zero is refused, since zero is
  Ethereum's place in an index.
- **Fixed vault.** A chain's vault is fixed at its first registration, because every index holding its tokens copies it
  (I8). After that, only its state verifier changes, through the same delay, and every index reads the verifier live
  at each proof. That is how a verifier follows a chain upgrade (design 6.10).
- **Vault tokens.** `proposeVaultListing(chainId, tokenId, supply)` lists a token held in a vault under an Ethereum-side
  id, a hash of the chain and the token id that no contract holds. From its proposal on it runs Stage A's flow
  unchanged: executeListing, delist, and weekly supply batches.
- **Freeze.** `freezeChain(chainId)`, by the owner or guardian, freezes every index's mints on that chain for 14 days.
  It also emits a `FREEZE` message, which the vault accepts on either proof.
- **Templates.** An index holding any vault token is a `HybridHub` clone. The factory records its CREATE2 salt, which
  the vault's `registerIndex` needs. The `HybridHub` template is deployed first, for the factory's predicted address,
  and the factory's constructor refuses a template built for another factory: with both templates, its own initcode
  would pass the 48KB limit.

**`HybridHub`.**
- **Tokens on Ethereum** are held in the hub's balance as in Stage A.
- **Tokens in vaults** are held in the hub's book, `vaultBacking`, which is exact by construction: it grows by the
  proven deposits of every claimed order and falls by every amount burned.
- **Invariants:** `balanceOf ≥ floor(S·u) + claims + escrow` on Ethereum, and `vaultBacking ≥ floor(S·u) + claims`
  per vault token. The invariant suite also checks, with every message delivered, that the vault's real balance
  equals the book.

The order flow:
- **Open.** `openOrder(shares, deadline)` escrows the Ethereum components and gives an intake id,
  `(deadline << 192) | orderId`. The deadline is at most `MAX_ORDER_LIFE` (6 hours) ahead: the design's 2-hour default,
  its 6-hour maximum. The minter deposits on each vault chain under that id.
- **Settle.** `settleOrder` proves each vault's intake digest at a block after the deadline, when deposits are final. It
  checks the digest's preimage and that each deposit covers the order. The whole deposit, surplus included, joins the
  index.
- **Mint cap.** Settling applies the mint cap, 4% of the supply over the current hour and the 24 before it. An empty
  index has no room: only its creator may seed it, with no cap of its own, since the vault's quantity cap bounds a real
  seed. A stranger's seed could be dust, which 4% a day would never let grow (HUB-2).
- **Void.** During the 24-hour lock, `voidOrder` takes any proof of the same intake, at a block after the deadline,
  showing a different digest. An intake cannot change between its deadline and the hub's message, so such a proof means
  the deposit or the proof was false. The order fails, and the hub freezes that chain's mints for 14 days.
- **Freeze.** A freeze of the chain, by the factory or by a void, that begins at or after an order's settlement holds
  the order. It cannot be claimed until `reconfirmOrder` proves the intake unchanged at a block after the freeze ended.
  Same-second freezes count, since nothing settles while frozen; a mutant using `>` fails
  `test_freeze_inTheSettlingSecondHoldsTheOrder`.
- **Claim.** `claimOrder` mints the shares, credits the deposits to the book, and sends `INTAKE_SETTLED` to each vault.
- **Fail.** `failOrder` works for the minter at any time while the order is open, or for anyone `SETTLE_GRACE` (6 hours)
  after the deadline. It books the escrow as the minter's claims, never transfers it, so a paused Ethereum token cannot
  keep vault depositors from their refund. It then sends `INTAKE_FAILED`.
- **Stray intakes.** `failIntake` fails an intake that belongs to no order, once its deadline has passed, so a stray
  deposit is never stuck.

Redeeming and claims:
- `redeem(shares, to, recipients, skipMask)` pays the Ethereum components to `to` and sends each vault a `BURN` toward
  `recipients[j]`.
- A skipped component, or one on a chain whose recipient is zero, is booked as a claim of `to`.
- `claim` pays an Ethereum claim; `claimToVault` burns a vault claim toward a recipient named then.

**New parameters, for the owner's review.**
- `SETTLE_GRACE` (6 hours): how long an unsettled order stays its minter's before anyone may fail it.
- `MAX_ORDER_LIFE` (6 hours): the design's maximum deadline.
- The seed's exemption from the mint cap, for the index's creator only, bounded by the vault's quantity cap. It
  replaces the design's "launch cap".

**Size.** The hub is 23.9KB of the 24KB limit, so layer 2 (the rebalance with deliveries and bond) goes in a separate
module the hub delegates to, not in the hub itself.

**One factory or two: decided on 2026-10-01: one.** The owner's call: v4 is one hybrid product, so it launches on this
factory once the hybrid index is ready, and Stage A does not launch on its own. `script/Deploy.s.sol` deploys this
factory, with the `HybridHub` template built for its predicted address. The question as it stood, deferred on
2026-09-30 once it was clear that Stage B is added beside Stage A either way: An index's tokens are fixed for good, so
no Stage A index ever gains a vault token under either choice. Holders switch to a Stage B index when they choose, and a
helper could do the Ethereum part in one transaction.
The choice matters only when Stage A is deployed. The factory is immutable, and the Stage B factory must know the
`HybridHub` template when it is deployed, so the alternatives are:
- Stage A launches on this factory with no chains registered: one factory, one set of supplies, and Stage A's audit
  covering the registry. Stage A's launch then waits for the `HybridHub` template to be final.
- Stage A launches on `IndexFactory` now, and Stage B deploys this factory beside it: two sets of supplies for the
  owner to keep, and Stage A's indexes never hold a vault token.

The first waits for the Stage B hub to be finished, audited and rehearsed on testnets, which is where the months come
from, and a hub bug found after that factory is live would need a new factory anyway.

**Not in layer 1** (all built since, in sections 5.3 to 5.6):
- the rebalance with deliveries and bond, and migration between versions;
- shortfall evidence from index digests;
- the governance messages `CAP_UPDATE`, `FREEZER_CHANGE` and `VERIFIER_ROTATION`, with its 30-day delay;
- stall recovery and the snapshot exit.

### 5.3 Layer 2: the rebalance with deliveries (design 6.6, step 4; built 2026-09-30)

**Architecture.** `HybridHub` is 23.9KB, so the rebalance lives in `HybridHubModule`, a contract the hub reaches
through its fallback by `DELEGATECALL`. Both inherit one storage base, `HybridHubStorage`, which declares every state
variable the two read. Every OpenZeppelin part they use keeps its state in its own namespaced slot. The module's
address is fixed in the template's constructor, so nothing can change it: it is code split in two, not an upgrade
path. The rarer order paths, `voidOrder`, `reconfirmOrder` and `failIntake`, move to the module too.

**The auction.** The start, the band, the notice, the keep mask and the cancel are Stage A's, unchanged.
`startRebalance`, `cancelRebalance`, `previewBand` and `canStartRebalance` behave as in `IndexHub`, over every
component. A vault component's reference supply comes from the factory like any other.

**Accepting.** An index holding vault tokens cannot settle in one transaction, so a fill has three steps.
1. `acceptRebalance(recipients, maxAmountsIn)` at the current λ, while the auction is live. It freezes λ and the
   settlement's units, and takes three things from the executor:
   - a bond of `REBALANCE_BOND` (0.1%) of the supply, in shares;
   - every bought Ethereum component, in the same transaction;
   - one recipient per vault chain, for the sold vault legs.

   `maxAmountsIn`, if not empty, bounds each component's delivery.

   The executor then deposits every bought vault leg on its chain, under a delivery intake id,
   `(deadline << 192) | 1 << 191 | nonce`. That id cannot be an order's, whose ids stay below 2^191. The deadline is
   `DELIVERY_WINDOW` (6 hours) away. A chain with a moving vault leg must not be frozen.
2. `settleRebalance(proofs)`, by anyone, with a proof of each delivery intake showing the deliveries at least the
   settlement's.
   - The settlement is recomputed at the supply of the settling block. Redemptions during the window can only lower
     it, and any excess delivered stays with the holders.
   - It writes the new units and pays the sold Ethereum legs to the executor.
   - It burns the sold vault legs toward the executor's recipients, and tells each vault that the deliveries joined
     the index.
   - A proof may come from before the delivery deadline, since deposits only grow until then.
3. The bond is held for `BOND_HOLD` (24 hours). Afterwards the executor takes it back with `releaseBond`.
   - During the hold, `slashRebalance` takes a proof of a delivery intake that is neither open nor settled, or that
     shows less than the settlement recorded. That means a delivery was forged. The bond is burned, raising every
     share's backing, and the chain's mints freeze.
   - This bounds a forged delivery by the band, as design 8.1 states: at most the bought vault legs, ≤ 1.0% × the vault
     share, about 0.11% of the index, most of it covered by the bond.

**Failing.**
- `failRebalance` is open to the executor at any time before settlement, or to anyone `SETTLE_GRACE` after the
  delivery deadline. It burns the bond, returns the Ethereum deliveries as the executor's claims, tells every vault to
  refund the deliveries, and holds strangers off for `REBALANCE_DELAY`.
- The executor pays for an abandoned fill, so accepting is never a free option.
- A guardian's `cancelRebalance` of an accepted fill returns the bond, since the executor did nothing wrong. The rest
  unwinds as a failure.

**Orders across a rebalance.**
- While a fill is accepted, `claimOrder` waits (`RebalanceInProgress`), at most the delivery window and its grace.
  Supply then cannot grow under a settlement sized for it.
- An order whose escrow or deposits no longer cover its shares at the units in force when it is claimed fails at that
  claim, returning its escrow as claims and refunding its deposits. That is the rare order that lives across a settled
  rebalance whose units moved against it.

**As built.**
- **Sizes.** The hub is 23.1KB and the module 23.5KB, each under the 24KB limit. At `main` on 1 October, the hub is
  23,371 bytes, the module 24,150 and the extension 16,025, of EIP-170's 24,576.
- **Shares in the module.** The module does not inherit OpenZeppelin's ERC-20: `HubShares` reads the supply, moves the
  bond and burns it on the same ERC-7201 slot, as OpenZeppelin's `_update` does for each case. A harness test checks
  it against OpenZeppelin's own token.
- **The layout.** `test_theHubAndTheModuleShareOneLayout` compares the two contracts' storage layouts from the
  compiler's artifacts.
- **Tests.** 15 mutants of the fill's safety checks each fail a test.
- **The invariant suite** runs whole fills beside orders and redemptions. It holds the escrow to the open orders plus
  a live fill's Ethereum deliveries, the index's own shares to exactly the live bond, and the vault's real balance to
  the hub's book plus the burns it still owes.

**New parameters, for the owner's review:**
- `REBALANCE_BOND` 0.1% of supply, `BOND_HOLD` 24 hours and `DELIVERY_WINDOW` 6 hours, all from design §12;
- the executor's bond burned on its own abort;
- mint claims waiting during a delivery window;
- an order failing at claim when its units moved against it.

### 5.4 Governance messages to vaults (built 2026-09-30)

A vault has no owner. Its settings change only through messages the factory emits, which P1 and P2 prove on the vault's
chain. The factory sends them only after a public delay, the same way it runs listings, and anyone can execute a
proposal within `PROPOSAL_WINDOW` (7 days) after its delay.

| Proposal (owner only) | Message | Delay | Who can cancel |
|---|---|---|---|
| `proposeCap(chainId, token, cap, floor)` | `CAP_UPDATE` | `LISTING_DELAY`, 2 days | owner or guardian |
| `proposeFreezer(chainId, freezer)` | `FREEZER_CHANGE` | `GUARDIAN_DELAY`, 7 days | owner only |
| `proposeRotation(chainId, p1, p2)` | `VERIFIER_ROTATION` | `ROTATION_DELAY`, 30 days | owner or guardian |

- **One live proposal** per chain and kind, and per token for caps. An expired one can be replaced.
- **The vault's own delay (VLT-2).** A raised cap or floor, a new freezer and new verifiers then wait
  `GOVERNANCE_DELAY` (7 days) on the vault itself before anyone applies them, however their proofs were obtained. So
  even P1 and P2 both broken cannot lift the speed limit or replace the verifiers at once. The freezer may cancel a
  waiting raise or rotation, never its own replacement, and a freeze in force holds every change but that one: a
  freezer that froze again and again must not keep itself in place. A lowering applies at once and drops a waiting
  raise.
- **Order (VLT-4, FAC-2).** Every governance message but a freeze must carry a newer factory nonce than the last of its
  kind, per token for caps, that the vault took on both proofs. Only a message on both proofs moves that mark, so one
  broken proof system cannot lock the factory out with a forged nonce.
- **Caps.** Every cap change waits the delay, a lowering included. The immediate protection is the freeze, which
  either proof system carries. On the vault, a message that raises the cap or the floor needs both proofs.
- **Freezer.** A freezer change follows the guardian's own rule: the guardian cannot block its own replacement. The
  vault refuses a zero freezer, so the role can never be removed.
- **Rotation.** A rotation must name two different, non-zero verifiers. The vault checks the same, and its constructor
  refuses one verifier used twice, since "P1 and P2" would then be a single proof.
  - The 30 days are public: holders who object can leave, and the guardian can cancel.
  - `ROTATION_LEAD` (90 days) stays operational, not enforced. The owner proposes the next pair at least 90 days before a
    scheduled Ethereum upgrade, so a guardian's veto, the guardian's replacement (7 days) and a second 30-day rotation
    all fit before the upgrade.
- **Evidence.** `freezeOnEvidence(chainId, payouts)` lets any of the factory's HybridHub clones freeze a chain's mints
  as the owner or guardian can, and with `payouts` its vault too, once it has checked evidence that the chain's records
  or proofs are false (section 5.5). An Ethereum-only index cannot call it.

**Unchanged, for the record:** a compromised owner could rotate a vault's verifiers to ones it controls, but only after
30 days in public, only if the guardian does not cancel, and holders can leave within those 30 days. That is design
8.1's "owner Safe compromised" row. The same now holds for a registered chain's state verifier, which decides every
index's mints there: `proposeChain` for a registered chain waits `ROTATION_DELAY`, not `LISTING_DELAY` (FAC-1).

### 5.5 Migration and evidence against a chain (built 2026-09-30)

Both live in `HybridHubExtension`, a third contract on the clone's storage, which the module reaches by `DELEGATECALL`
from its fallback: the hub and the module are both near the 24KB limit. Like the module, it is fixed when the template
is built.

**Migration (design 6.7).** `migrate(newIndex, shares, newShares, to, recipients)` on the old index moves a holder to
another HybridHub index of the same factory in one Ethereum transaction:
- the old shares are burned;
- each vault token both versions hold moves inside its vault, as a `MIGRATE` message, for exactly what the new shares
  need;
- each Ethereum token both hold moves from index to index, and the holder pays what the new shares need beyond it;
- what the old shares back beyond the new ones goes to `to`, as a redemption's would: Ethereum tokens sent, vault tokens
  burned toward `recipients`, or booked as `to`'s claims where a recipient is zero.

The new index's `acceptMigration` accepts only another HybridHub clone of the factory. It credits its book with the
vault legs, pulls the rest from the holder, mints, and checks its backing in real balances, so nothing the old index
says goes unchecked. It refuses while a fill is accepted, as mint claims do, and while any of its chains is frozen.
Migration involves no vault-chain proof of its own and has no lock. It does count against the new index's mint cap
(MOD-2): the old index's book rests on deposit proofs too, and an index seeded on a forged one could otherwise carry
that book into any other index at once, past the only bound design 8.1 has on a broken deposit proof. An empty index
is seeded by migration only by its creator, as by an order. So a new version fills at 4% of its supply a day, after
its creator's seed; the creator can seed it large from its own holdings of the old version.

**The vault side.** A `MIGRATE` is now paid like a burn: owed, released within the 4% speed limit, into the new index's
balance, and counted in the old index's `paidTotal`. Before, it moved the whole amount at once. That meant a forged
`MIGRATE`, which needs P1 and P2 both broken, could empty an index's vault balance in one message, past invariant I5.

**Evidence (design 5.3, 6.8, 7.2).** Anyone can prove either of two things, each from the vault's own records:
- `reportOutflow(chainId, record, proof)` proves the vault's index digest, with its preimage of tokens, balances and
  paid totals. If a token shows more paid out than this index ever sent out (`sentOut`, every `BURN` and `MIGRATE`),
  the vault paid on a message Ethereum never sent. Only a break of both Ethereum-side proofs allows that.
- `reportForgedDeposit(orderId, chainId, proof)` proves a claimed order's intake at a height after its deadline. The
  intake can honestly be open with the deposits the order was claimed on, or settled with the same deposits. Anything
  else shows the proof the order was claimed on was false.

Both freeze the chain at the factory, for every index: the state verifier is shared by all of them. Voids and slashes
now do the same, where layer 1 froze only the index that found the contradiction.

**An exited chain takes no evidence (LG-5).** A vault in its snapshot exit honestly fails every intake the hub had not
marked settled at its checkpoint, and pays holders what the index never sent. So every evidence proof, a void's and a
slash's included, also reads the vault's snapshot root (`VAULT_SNAPSHOT_ROOT_SLOT`) in the same state proof and is
refused (`ChainExited`) when it is set, whether or not anyone has called `recordExit` on this index; and none is taken
once the exit is recorded. The vault's snapshot is permanent, so no honest state after it can count as evidence.

**Proposals for the owner (deviations from the design):**
1. **A vault token new to a version comes by order, not by migration.** The design's migration mints "against those
   coins plus fresh deposits for the tokens only the new version holds". Fresh vault deposits need an order's deadline,
   proof and lock, so a migration would have to wait on them: the old shares held across two transactions, and
   returned if the order failed. Built instead: migration is atomic, and refuses a new version with a vault token the
   old one lacks. Holders of such a version redeem and order. With the floor buffer, membership changes are rare, and
   Stage B's four chains are in the flagship from the start.
2. **Evidence against deposits freezes mints only.** The design (6.8) has every contradiction also emit `FREEZE`. A false
   deposit proof can only inflate mints, and the mint freeze stops them. Stopping the vault's payouts too would only
   delay every holder's exit on that chain. Evidence of a payout Ethereum never sent does stop the vault, since that is
   where the forged payouts come from. The guardian can still freeze the vault after any evidence.
3. **The design's shortfall inequality is replaced by the two checks above.** `settled − (burned − paid) < floor(S × u)`
   cannot be proven soundly from the vault's records: a settle message still in flight leaves the vault's balance
   below the hub's book with nothing wrong. The two checks compare only things that can never honestly disagree:
   - paid totals, which never exceed the amounts sent;
   - a claimed intake, which never changes after its deadline except to settle.

**Not covered, stated plainly:**
- A forged rebalance delivery found after its bond's 24-hour hold. It is bounded by the band, as design 8.1 states.
- A vault crediting an index more than Ethereum told it to, for example a forged `INTAKE_SETTLED` of an intake the hub
  failed. The index is not harmed. That intake's depositors are, and their refund failing is the signal. Only P1 and
  P2 both broken allow it.

### 5.6 Stall recovery and the snapshot exit (design 6.9, layers 3 and 4; built 2026-09-30)

**What the verifiers now prove.** `IEthereumEventVerifier` gains two things every Ethereum-finality proof can give,
whether full finality or the sync-committee fallback:
- `verifyEvent` returns the log's block number;
- `verifyCheckpoint(proof)` returns a final execution block: its number, timestamp and state root.

**Checkpoints and the stall.**
- Anyone calls `advanceCheckpoint` with a block both P1 and P2 prove.
- The block must be later than the last in number and time, not in the future, and carry a state root.
- A vault that has accepted no checkpoint for `STALL_PERIOD` (7 days, counted from the checkpoint's own Ethereum
  timestamp) is stalled. Old checkpoints cannot keep it out of a stall.
- While Ethereum's formats are unchanged, anyone can end a stall, so nobody, the owner included, can manufacture one.
- A stalled vault takes no deposit, since it may never see the message that would settle or refund it. It keeps paying
  what it already owes.
- **Messages wait for the checkpoint (VLT-3).** A message that moves coins or loosens a rule runs only from an Ethereum
  block at or before the vault's checkpoint; a freeze and a lowered cap need no checkpoint. So the snapshot, which is
  the last checkpoint, never pays a holder whose burn the vault also paid. Relayers advance the checkpoint before
  delivering, and the latency of a burn becomes that of a checkpoint.

**Recovery (layer 3).** Only while stalled, `RECOVERY_PROPOSER` may propose a successor pair. That is the owner's
emergency multisig on the vault's chain, fixed at deployment; the Safe rotates its own signers. The pair must pass a
continuity test:
- **(a)** both prove exactly the last checkpoint the vault accepted;
- **(b)** both prove a recent checkpoint, newer and within `STALL_PERIOD` of now, which their proof shows descends from
  (a) by validator signatures;
- **(c)** both prove again the last message the vault delivered on both proofs, its id recorded at each such delivery.
  This is a fixed sample the proposer cannot choose. A message carried on one proof, a freeze or a lowered cap, is not
  recorded: with one proof system broken, a forged one-proof freeze would otherwise be the last message, which no
  honest successor could prove again (LG-3).

Review and adoption:
- **Review** lasts `RECOVERY_DELAY` (30 days). The freezer may veto `MAX_RECOVERY_VETOES` (2) successors per stall. A
  stall ends only with a checkpoint recent enough to end it, by an advance or an adoption, and that starts the count
  again (LG-2).
- **Adoption** by anyone after the review needs a checkpoint the successor proves, recent at that moment. The vault
  leaves its stall.
- **Lapse.** A checkpoint from the pair in force that ends the stall lapses the successor: the old pair works, so there
  is nothing to recover. A stale one does not. During a stall the old pair can still prove blocks up to where it
  broke, newer than the checkpoint but not recent, and an advance to one only lets messages sent before the break run
  (VLT-3). Before LG-2, such an advance lapsed the successor and reset the vetoes, so anyone could throw the review away
  one block at a time until the snapshot.
- **Worst case, as the design states:** 37 days of delay without vetoes, 97 with two.

**The snapshot exit (layer 4).** From `SNAPSHOT_EXIT_DELAY` (180 days) after the stall began, anyone calls
`beginSnapshot`. The last checkpoint becomes the snapshot, for good. From then on:
- **No later message.** A message from an Ethereum block after the snapshot never runs. Messages from its block or
  earlier still do, if the old verifiers can prove them.
- **Holders claim directly.** `claimSnapshot(index, holder, recipient, component, proof, signature)` reads the hub's
  storage at the snapshot's state root. `component` must lie inside the hub's components array, whose length the claim
  reads too; past its end lies storage a holder could fill with "units" of its choosing (VLT-1). The holder's shares at
  the units then in force, rounded down, plus its claim on the coin (`_claimOf`) are paid to:
  - the recovery address it registered in the hub for this chain, if any, which a contract holder must register; a
    value that is no address on this chain counts as none (VLT-I3);
  - otherwise the recipient it signed for with its Ethereum key (EIP-712 `SnapshotClaim(index, holder, recipient)`).
  - One claim per holder and index.
- **Open intakes are resolved.** The hub marks an intake settled in the transaction that sends its settle message
  (`_settledIntakes`). `resolveIntake` reads that mark at the snapshot and settles the intake if it was sent, and
  otherwise fails it so its depositors take their coins back. Nothing sent later can ever run here.
- **Reading the state.** The vault reads Ethereum's state through `STATE_READER`, a stateless contract fixed at
  deployment: the Merkle-Patricia walker already tested on BNB Chain's trie, which is Ethereum's format. It checks no
  consensus and is used only under the root the verifiers accepted.

**The hub side.**
- `setRecoveryAddress(chainId, recipient)` for any holder, which the app prompts every contract holder to call.
- `recordExit(chainId, proof)` proves, through the chain's state verifier, that its vault began a snapshot. That
  direction of proof still works when Ethereum's does not. From then on the index treats the chain as frozen for good:
  nothing mints on it, no order on it is claimed, no migration brings backing onto it.
- `failHeldOrder` fails a locked order the exit keeps from its claim. Its vault refunds that order's deposits, since it
  was never settled at the snapshot.
- `test_theHubLayoutIsPinned` holds the slots each side reads of the other against the compiler's layouts.

**Proposals for the owner (deviations from the design):**
1. **Snapshot claims are paid within the speed limit.** The design has the vault "pay each index's balance". Paid at
   once, a forged snapshot root (both P1 and P2 broken before the stall) would take everything; paid within 4% a day,
   it takes what a forged burn would. The floor lets small balances out whole. Holders wait longer: a mass exit takes
   months, as a mass redemption does.
2. **No freeze after a snapshot,** neither the freezer's own nor the factory's message (VLT-5). Nothing could replace
   the freezer then, since `FREEZER_CHANGE` would be a later message, so a hostile freezer could otherwise hold the exit
   off for good. A freeze in force when the snapshot begins still runs out.
3. **A stalled vault takes no deposit.** The design does not say. Without this rule, deposits during a stall could
   never be settled or refunded if the stall ended in a snapshot.
4. **The hub stops minting on an exited chain, rather than detaching it.** The design has the hub "detach that chain's
   tokens so later buyers are not charged". Removing a component from an index would touch every path the hub and
   module share, both near 24KB. Built instead: the index is mint-dead on that chain and redeemable as before, and its
   holders move to a version without the chain by migration, which carries only the components the new version holds.
5. **Gas.** The settled mark is one more storage write, about 22,000 gas, on each order claim and each fill settlement.
6. **Burns in flight are paid from the hub's record (built 30 September, the owner's call).** The hub marks every
   `BURN` and `MIGRATE` it sends in `_sentMessages`, in the transaction that sends it: one more storage write, about
   22,000 gas, per vault leg of every redemption, migration and sold fill leg. Since LG-1 it marks every other message
   too, an intake's settle or failure once per vault chain, so that anyone can send any of them again. After the
   snapshot, anyone calls the
   vault's `deliverRecorded(payload, proof)`, which reads that mark under the snapshot's state root and runs the message
   as a delivered one would: owed, within the speed limit, once. So a burn issued before the break and never delivered
   is paid, not lost, and the holder's snapshot share no longer counts the burned shares, so nothing is paid twice. The
   claim's reading and signature check live in the linked library `VaultSnapshot`, which keeps the vault under
   EIP-170's size limit.

**Not built, stated plainly:**
- **Look-through for the official pool's LPs.** The hub records no official pool yet, and a concentrated-liquidity
  position's share of the index tokens depends on its ticks, the pool's price and uncollected fees, read from proofs of
  the pool's storage. The choices are the owner's: which pool, V3 or V4, and whether to read positions by owner or by
  NFT. Until then, the pool's shares at the snapshot are unclaimable, and so are the shares of anyone who could neither
  sign nor register a recovery address.
- **A forged exit record**, possible only with a broken state verifier, freezes one index's mints on that chain for
  good. That is a delay: holders migrate once the verifier is rotated.
- **A successor's proof of descent**, which recovery asks of a proposed pair, is not built. P1 and P2 are, on SP1 and
  RISC Zero (sections 10 and 11); the vault's side is fixed by the interface above.

### 5.7 The Tron state verifier (built 2026-10-01)

`src/verifiers/TronStateVerifier.sol` follows section 8's design and the owner's three decisions of 1 October 2026:
the list is inferred from signatures, 19 of 27 producers must sign, and `MAX_LAG` is a day.

**What a proof shows.** A top-level `attest(slots, values)` call to the vault succeeded in a Tron block that 19
distinct producers of its period's list then built on: a solidified block (`DposService.updateSolidBlock`). That
proves the values, because:
- Tron's peers re-run every contract call and reject a block whose `ret[0].contractRet` differs
  (`TransactionTrace.check`);
- the block's transaction root hashes each whole transaction, results included.

`verifySlots` returns the values with the block's number and its time in seconds. `verifyCall` proves any top-level
call the same way, for integrators.

**Written, never parsed.** The verifier writes every header and transaction it hashes itself, from typed fields, as
Java's protobuf writes them: fields ascending, zero scalars and empty strings left out.
- **What the verifier writes itself.** In a transaction: the contract type, the vault's address, the call data, no
  value, and the result SUCCESS.
- **What the prover gives.** Only the fields that change nothing about what was called: the owner, the reference
  block, the expiry, the time, the fee limit, the permission id, the signatures, and the result's fee.

So there is no parser to get wrong, and a field the verifier does not write makes a proof fail closed. Checked on
real mainnet data:
- every one of 122 real headers written this way hashes to its block id;
- two real USDT transfers hash to leaves of their blocks' transaction trees.

`test/fixtures/tron/generate.py` checks all of it independently in Python.

**Following the list.** Every 6 hours, anyone calls `advance` with a chain of blocks holding:
- the learning round: 27 consecutive slots in one period after the latest list's, starting at least two blocks into
  that period, whose distinct signers are exactly the new list;
- then blocks, in any later period, in which 19 producers of the old list, each signing with its listed key, built on
  the whole round.

Any later period will do, so a halt, or producers absent for a period, delays the next list but does not stop it
(TRN-3, TRN-9).

**A subtlety found on mainnet data.** The block right after the maintenance is scheduled two slots behind its own
time: `DposSlot.getTime` adds the two skipped slots to the slot count, and `getScheduledWitness` never takes them back.
- Counted from that block, a round names one producer twice and misses another.
- Counted from the block after it, the schedule is the slot modulo 27.

The fixture checks both facts on the chain itself. So the round starts at least two blocks into its period. That
block's producer also comes round again inside the round, so it could have signed the round with two keys, by changing
its witness-permission key in between, and stalled the verifier (TRN-2).

**What a producer writes into its own header.** Tron never checks a header's `version`, an int32 that Java writes in
ten bytes when it is negative. It keeps any unknown field a producer adds to `BlockHeader.raw`, and hashes it. The
verifier writes `version` sign-extended and appends a header's unknown fields as given (TRN-1). That is sound unparsed:
every field the verifier reads comes before them and delimits itself, so the hash fixes them.

**Other rules.**
- The new period starts on the 6-hour grid even after a halt, as `updateNextMaintenanceTime` keeps it.
- Each learned producer is the witness its block names, with the key that signed it, so one key cannot be learned
  under two witnesses.

**Bounds.**
- A list proves only blocks of its own period, and none older than `MAX_LAG`.
- The latest list names its successor only within `MAX_LAG` of its period's start. So a verifier left about 18 hours
  behind a boundary stops for good and is rotated (30 days).

**Measured** (`test_gas_realProofs`, on real mainnet blocks of 1 October 2026):
- proving a slot: about 568k gas, with 19 headers;
- following one period: about 1.3M gas. Four a day comes to about 5.2M gas, about $2.80 at 0.2 gwei, against the BNB
  verifier's 89M.

**Limits, for the owner.** The internal review of 1 October 2026 (`audit/2026-10-01-tron-review.md`) found no way to
forge a proof. What remains:
- **The vouching margin is 8.** Vouching needs 19 producers of the old list, signing with the keys it recorded.
  - If nine of them are voted out, or change their witness-permission keys before vouching (100 TRX each), no
    successor can be learned (TRN-3).
  - The verifier then stops until the 30-day rotation. Mints on Tron stop with it; funds stay safe, and burns still
    pay, since they need only Ethereum's proofs.
  - A faster recovery path, such as an owner-proposed list behind a delay with the guardian's veto, would trade that
    stall for trust in the owner's key. That is the owner's decision.
- **Packing producers.** The producer that packs an `attest` can make that one transaction unprovable, since Tron's
  peers check only `ret[0].contractRet`; the keeper sends it again (TRN-7).
- **Rotated keys.** A key a producer rotated out stays valid in its recorded list, for the period and a day (TRN-8).
- **One period per proof.** A proof's 19 headers must lie in one period, so an `attest` in the minute before a boundary
  is proven only by sending another after it.
- **Trust.** 19 colluding producers could forge at no cost to their stake, since Tron has no slashing.
- **Shared keys.** Two producers sharing a permission key count twice here, as they do in Tron's own solidity rule.
- A proposal changing the maintenance interval (6 hours since genesis) needs a new verifier.
- **Run on TRON's VM (1 October 2026, `tron/`).** Built with Tron's compiler, tron-solc 0.8.28, and run on a local
  single-node chain of java-tron GreatVoyage-v4.8.2.3 with mainnet's VM switches and mainnet's 80 ms CPU limit, every
  step a mined transaction:
  - SP1's and RISC Zero's Groth16 verifiers pass on their own real proofs, 217,950 and 222,908 energy, and refuse a
    wrong input; P1's and P2's `verifyEvent` prove three real mainnet receipts, 51,955 to 74,606 energy;
  - the vault deploys (Tron's compiler makes it 25,360 bytes; TRON has no 24,576-byte limit), registers an index by
    Ethereum's CREATE2 formula, takes a TRX deposit, settles it, and pays a burn to a new account; `attest` costs 1,164
    energy, and a transaction to that view is accepted, since Constantinople is on.
- **The CPU limit is TRON's constraint for P1 and P2.** TRON bounds a transaction by 80 ms of elapsed CPU time, and one
  past it fails `OUT_OF_TIME` and burns its whole fee limit. The BN254 pairing of a Groth16 check takes about 40 ms in
  java-tron on the machine measured; every run passed at 80 ms, while at java-tron's default 50 ms a cold or loaded
  node failed. The check runs only in `update`, one per proof system, never in a delivery. Whoever sends `update`
  sets a fee limit near its energy, about 300,000, and the margin is measured again on Nile before mainnet.
- **Still for the deployment:** the script that deploys the vault on a TRON network with `script/DeployVault.s.sol`'s
  checks and `consume_user_resource_percent` at 100 (so callers pay all energy, as nobody owns the vault), as
  `tron/rehearse.mjs` deploys it on the local chain; and TRX's 6 decimals in the caps, the floor and the reference
  supply. The Ethereum side is scripted: `script/DeployStateVerifier.s.sol` deploys the verifier from a fresh anchor,
  and `script/ConfigureChains.s.sol` proposes chain 728126428 and TRX's listing (`tron/README.md`).

## 6. Build order

Statuses as of `main` on 1 October 2026. Nothing has been deployed but on local chains.

1. The message library and the verifier interface. Then the EVM vault, with unit tests, an invariant suite, mock
   verifiers, and 100% coverage under the repository's gates. Built.
2. The BNB Chain state verifier on Ethereum, from the prototype, with validator-set tracking and fork tests against
   BNB Chain data. Built (section 5.1), and tested on recorded BNB Chain data, mainnet's and the testnet's
   (`test/fixtures/bnb`), rather than on a fork.
3. The factory's chain registry, and `HybridHub` (once proposal 1 is decided). Layer 1 is built (section 5.2); layer 2
   is the rebalance with deliveries and bond (built, section 5.3); the governance messages (section 5.4), and
   migration with the evidence against a chain (section 5.5), are built.
4. The Ethereum-event verifiers: P1 on SP1 (built, section 10) and P2 on RISC Zero (built, section 11, the owner's call
   on 1 October 2026). Neither has generated a proof yet; a proof's price and time wait on the owner's GPU run.
5. The Solana vault program (built, section 7, with P1 on Solana; P2 on Solana and a Solana state verifier are not
   built), then Tron (its state verifier built, section 5.7, and its contracts run on TRON's VM; the vault's deploy
   script on TRON is not written) and HyperEVM (blocked: no state root to prove against, section 8).
6. The stall recovery and snapshot exit (built, section 5.6, but for the pool look-through and a successor's proof of
   descent), then watchers (not built), then the testnet rehearsals of the design's Phase 3 (not run; the hackathon's
   demonstration has been rehearsed only on local chains and local forks, with real testnet data, `demo/README.md`).
7. The deployment scripts: a vault chain's verifiers and vault, a chain's state verifier on Ethereum, and the chain's
   registration with its coins' listings (built: `script/DeployVault.s.sol`, `script/DeployStateVerifier.s.sol`,
   `script/ConfigureChains.s.sol`), with the hybrid ABIs the app decodes (`abi/HybridIndexFactory.json`,
   `abi/IHybridIndex.json`, `abi/XindexVault.json`).

## 7. The Solana vault (hackathon build, from 30 September 2026)

The EVM vault's rules (section 4), ported to a Solana program in `solana/programs/xindex-vault`, for the testnet
demonstration of `design/2026-09-30-hackathon-plan.md`. It keeps the same messages, the same digests, the same speed
limit and the same freeze. What Solana changes:

- **Identity.** The vault is the program's `config` account. Its 32-byte key is what Ethereum registers as the chain's
  vault and names in every message.
  - The digests carry the vault's whole 32-byte id, as the factory registers it: the program hashes its full key. An EVM
    vault's id is its address as a word, which encodes exactly as the address did, so EVM digests are unchanged. Only
    the state verifier is still asked about a 20-byte account, which each chain's verifier defines for itself.
- **Chain id.** Solana has no EVM chain id. The program takes the id the factory's registry assigns it at
  initialization, and every message must name it.
- **Coins.** Native SOL, in lamports, held by a system-owned `treasury` account the program signs for. Amounts from
  Ethereum are 256-bit and must fit 64 bits, or the message is refused.
- **Recipients.** A burn's recipient, 32 bytes on Ethereum, is a Solana public key exactly.
- **One instruction per message kind.** `deliver_burn`, `deliver_intake` (settled or failed), `deliver_migrate` and
  `deliver_governance` each take the message and its proofs and name only the accounts that kind touches.
- **Verifiers are programs.** P1 and P2 are two different program ids. The vault calls each one's
  `verify_event(block, emitter, topic0, topic1, data_hash, proof)`, which must succeed, with the verifier's state
  account at a fixed address of its own.
  - The vault passes the log's data by its hash, so the message travels once, not three times. A transaction is at most
    1,232 bytes.
  - The message id, the index, the intake and every account address are read from the payload itself, and the emitter
    the verifiers must attest is the index the message names, or the factory. A burn with both stub proofs takes
    1,143 bytes. Real proofs need an address lookup table for the static accounts, and a buffer account: P1's event
    proof is 1.5 to 2.2 KB (section 10).
  - The real P1, built since, is `solana/programs/ethereum-verifier` (section 10): its `update` checks the SP1 Groth16
    proof, 96,910 compute units measured in LiteSVM, and its `verify_event` proves the log by its receipt under the
    headers root that proof recorded, 9,100 to 12,500. P2 on Solana is not built.
- **Used messages.** Each delivered message creates an account at an address derived from its id, so a second
  delivery fails by construction.
- **Initialization** only by the program's upgrade authority, so nobody can take the configuration in front of the
  deployer. In production the upgrade authority is then removed. On the devnet it stays.
- **Verifiers nobody can upgrade (SOL-2).** P1 and P2, at initialization and at a rotation, must be programs whose
  upgrade authority is removed, or programs of the older loaders.
- **Governance as on the EVM vault (VLT-2, VLT-4).** A raised cap or floor, a new freezer and new verifiers wait
  `GOVERNANCE_DELAY` (7 days) in the `config` account, applied by anyone with `apply_change` and cancelled by the freezer
  with `cancel_change`, the freezer's own replacement excepted. Only a message on both proofs moves a kind's nonce.

**As built (30 September):**
- 7 unit tests pin the encodings against Solidity's.
- 29 LiteSVM tests cover initialization, registration, deposits, the route, the used mark, burns under the speed limit,
  refunds, migration, governance and its delay, the freeze, rotation, and the red team's findings (SOL-1 to SOL-9,
  VLT-2, VLT-4).
- `anchor build --no-idl`: Anchor's IDL generator cannot follow addresses derived from the payload.

**Not in the hackathon build:** stall recovery and the snapshot exit (section 5.6), which follow once Solana's own state
proof exists; the vault's state proven to Ethereum, which a relayer stub stands in for; tokens other than SOL.

**The stubs.** `solana/programs/stub-verifier` accepts any log its relayer key signed. It is deployed twice, as P1 and
as P2, under two keys. Its name, its first line and the submission all say it is a stub. The Ethereum side's stub is
in `demo/`.

## 8. Proving a vault's state on Ethereum, chain by chain (found and researched 30 September 2026)

Proposal 3 (section 1) has Ethereum prove one storage slot of the vault per index or intake, against a state root the
chain's finality signs. That holds where a block commits to contract storage, and not everywhere. The owner chose
"research, then build" for the chains where it does not. Three read-only research passes found:

| Chain | Commitment to the vault's state | Path | Ethereum gas per proof | Status |
|---|---|---|---|---|
| BNB Chain | an Ethereum-style state root | its finality vote plus a storage proof (5.1) | about 820k for two slots, measured | built |
| Tron | none: `accountStateRoot` covers balances only, and is off on mainnet | a transaction's result, which the transaction root commits to | about 568k, measured | built (5.7) |
| Solana | none: the accounts lattice hash has no inclusion proofs | a zkVM proof of the slot's account writes, under Alpenglow | about 260k, estimated | waits on Alpenglow's mainnet launch |
| HyperEVM | none: every header's `stateRoot` is zero | nothing public to prove against | none | waits on Hyperliquid |

### Tron: prove a call's success

Tron's transaction root is a SHA-256 tree whose leaves hash each whole transaction, its result included. Every node
re-executes a contract call and rejects a block that misstates the result. So a call that succeeds only when the vault
holds a value proves that value.
- **The vault** gains `attest(slot, value)`, which reverts unless its storage holds `value` at `slot`.
- **A proof** carries three things:
  - the successful `attest` transaction, parsed strictly;
  - its Merkle path;
  - the headers of its block and the 18 after it, signed by 19 distinct block producers of the verifier's list, as Tron
    solidifies a block. Each producer signs with secp256k1, which Ethereum's `ecrecover` checks.
- **The list of 27 producers** is recomputed from votes every 6 hours, and no header records it. The verifier follows it
  as the BNB verifier follows BNB's sets: each period's first round is accepted once 19 keys of the previous list have
  built on it. No period can be skipped, and a list older than `MAX_LAG` names no successor.
- **The hub does not change:** a `TronStateVerifier` returns the slot through `IVaultStateVerifier`. Tron's chain id is
  728126428, which TVM's `block.chainid` returns.
- **Trust.** Weaker than BNB's. Tron has no slashing, so 19 colluding producers could forge at no cost to their stake,
  and its finality is a longest-chain rule. Tron's own nodes and exchanges rely on the same guarantee.
- **Decided by the owner on 1 October 2026:**
  - the list is inferred from signatures, not kept by the owner;
  - 19 signers, as Tron uses;
  - Tron's `MAX_LAG` is 1 day, as BNB Chain's.
- **The other direction:** TVM has BN254 precompiles but no BLS12-381 ones, so P1's Groth16 verifier works there.

### Solana: prove the slot's account writes, once Alpenglow is live

Alpenglow's finalization certificates are BLS12-381 aggregates over a block id, with Ethereum's own ciphersuite. Each
block's footer carries its bank hash, which folds in the lattice hash of all accounts, and validators vote only after
replaying a block.
- **The vault** gains an `attest` that seals an intake after its deadline and always changes its account.
- **A zkVM proof** shows four linked facts:
  - a finalized block's footer gives a bank hash;
  - its lattice hash differs from its parent's by exactly a listed set of distinct account changes, each changing;
  - the intake account is among them;
  - it now holds digest D.

  A failed deposit changes no account, so it cannot count.
- **The validator set** is committed nowhere, since SIMD-0400 was closed. A small registry program records each epoch's
  stakes and BLS keys, and Ethereum accepts the next set only from a block the current set certifies.
- **Cost.** About 0.5B to 3B prover gas, estimated, against P1's 36.6B, measured. Alpenglow is on testnet and devnet since 24–25
  September 2026, so it can be measured there now. Mainnet has no date.
- **Its soundness argument is new and unpublished,** like the one-epoch finality argument, and must be reviewed before
  anyone relies on it.

### HyperEVM: nothing to prove against yet

- **What is missing.** Every HyperEVM header's `stateRoot` is zero, and `eth_getProof` does not exist. Nothing public
  that validators sign commits to an EVM block, and the node is closed source.
- **Trust today.** HyperBFT's quorum is two thirds of stake, the Hyper Foundation's five validators hold 47.5%, and
  there is no slashing.
- **What would be needed:** a state root with proofs, a quorum-signed commitment to each EVM block, and a light-client
  specification. Until Hyperliquid publishes those, HyperEVM cannot hold a vault that Ethereum can check.
- **For whenever it can:**
  - HyperEVM has no BLS12-381 precompiles;
  - a payout to `0x2222…2222` would move coins into the vault's own HyperCore account, so such system addresses must
    never be recipients;
  - the vault deploys only in a big block.

### Stage C: Avalanche, NEAR, Stellar, Hedera and Cardano (researched 1 October 2026)

Five more read-only passes asked the same questions of the Stage C chains, and whether each passes the design's
deterministic-finality rule. The record, with every source, is `design/2026-10-01-stage-c-research.md`.

| Chain | Deterministic finality | Its state, proven on Ethereum | Status |
|---|---|---|---|
| Avalanche C-Chain | no as written: probabilistic safety, though accepted blocks never revert | nothing on mainnet signs the validator set's changes | waits on Ava Labs, and on the owner's reading of the rule |
| NEAR | yes | a zkVM proof of each epoch's ed25519 approvals, then SHA-256 paths to an `attest` result | buildable; no production client exists |
| Stellar | yes | a zkVM proof of a Tier 1 quorum's EXTERNALIZE signatures, then the `attest` call's result | buildable; Tier 1's changes have no on-chain anchor |
| Hedera | yes, under a permissioned council | hinTS (BLS12-381) block proofs, switched off on mainnet until about November 2026 | waits on Hedera's TSS cutover, and on the owner accepting the council |
| Cardano | no: Praos, and Peras too, are probabilistic | Mithril certifies inclusion only, under operator-held genesis keys | fails the rule as written |

Every one of them can verify P1 and P2 but Cardano, which has no BN254 and would need an unaudited wrapper of both
proofs over BLS12-381. None of the five is built: NEAR and Stellar each need a finality statement, its zk proof, a
state verifier and a vault in the chain's own language, the work Solana needs, and the owner has three decisions to
make first (the record's summary lists them).

The hackathon demonstration is unaffected: none of its chains is a Stage C chain. Its state verifiers are stubs for
Solana and HyperEVM, and the real `BnbStateVerifier` for its second index, of WETH and BNB (`demo/README.md`).

## 9. The internal red team of Stage B (30 September 2026)

Five reviewers read the EVM vault, the hub's three parts, the factory with the BNB verifier and its libraries, and the
Solana vault with its stub. The findings, their fixes and their tests are in `audit/2026-09-30-stage-b-red-team.md`.
What changed in the rules above:
- the vault's own `GOVERNANCE_DELAY` for anything that loosens a rule (5.4), and nonces that only a message on both
  proofs moves;
- messages wait for the vault's checkpoint (5.6), and a snapshot claim reads the components array's length;
- only an index's creator seeds it, and migration counts against the new index's mint cap (5.2, 5.5);
- evidence of a forged delivery is proven after the delivery deadline, and an empty intake is evidence only on a chain
  where the fill recorded a delivery (5.3);
- the BNB verifier's `MAX_LAG` of 1 day and `MAX_SPAN` of 15 minutes (5.1);
- a registered chain's new state verifier waits `ROTATION_DELAY` (5.4).

**For the owner's review:** the last three rules each change something a holder or the owner can do:
- migration's mint cap slows a move to a new version to 4% a day after its creator's seed;
- a BNB verifier left a day behind stops for good;
- a new state verifier waits 30 days, not 2, so a dead one pauses that chain's mints for longer.

Each trades availability for a bound on loss.


## 10. P1: the Ethereum-finality proof (design, 30 September 2026; built 30 September and 1 October)

P1 proves to a vault chain that an Ethereum block is final, so the vault can accept a message logged in it. It
replaces the testnet stubs. The zkVM is SP1; its proof is wrapped as BN254 Groth16, which an EVM checks with the BN254
precompiles (about 227k gas, measured) and Solana with its `alt_bn128` syscalls.

**Built:** the statement (`proofs/finality`), SP1's program and host, the input builder, `EthereumFinalityVerifier` for
EVM vault chains and its Solana twin (`proofs/README.md`). The program has run in SP1's execute mode on real mainnet and
Sepolia inputs. No proof of it has been generated yet: the Groth16 checks have run on SP1's own proofs, and the rest of
the verifiers on real public values and receipts with the SNARK check mocked (`design/2026-09-30-proving-prototype.md`,
`demo/README.md`, `tron/README.md`).

### What each verifier keeps

Each vault chain runs one P1 verifier: a light client of Ethereum that anyone can advance. It keeps an **anchor**, the
last checkpoint it accepted:
- `epoch`, a finalized checkpoint's epoch `e0`;
- `validatorsRoot`, the SSZ `hash_tree_root` of `state.validators` in that checkpoint's state;
- the last execution block it covers, by hash and number.

The first anchor comes from the deployer, and the vault's listing delay lets the owner and guardian check it, as for
the BNB verifier. Every later anchor is proven.

### The statement

Given the anchor, the proof shows that checkpoint `C1 = (e1, r1)` is finalized, by Casper's two-epoch rule:
1. **Justification.** Aggregate attestations whose data share a source `S` and the target `C1` are signed by
   validators holding at least the threshold below.
2. **Finalization.** Aggregate attestations with source `C1` and target `C2 = (e1 + 1, r2)` are signed the same way.
3. **Who counts.** Every signer is looked up in the anchor's validator registry: its public key, effective balance,
   activation and exit epochs and slashed flag, all proven against `validatorsRoot`. A signer counts once per link,
   only if unslashed and active at the target epoch by those records. The threshold is two thirds of the stake the
   records show active at that epoch, plus a margin.
4. **The signatures.** Each aggregate's signature verifies against its signers' keys, over the attestation's signing
   root under `DOMAIN_BEACON_ATTESTER`, the fork version of the target epoch and mainnet's genesis validators root.

Only the anchor's keys are trusted, and each is a real validator's, checked for possession when it was deposited. So
no committee assignment, shuffle or later state has to be trusted to count a vote: a vote counts because the key that
signed it was in the trusted registry. The prover supplies each aggregate's signer list, which it reads from a beacon
node. A wrong list only makes the signature fail.

**Keys added since the anchor.** An on-chain aggregate spans every committee of its slot, so once validators join after
the anchor, nearly every aggregate includes some. Their keys are not in the anchor's registry, yet the signature
cannot be checked without them. A new key may therefore join an aggregate, counting no stake, but only with the
signature of the deposit that added it, which only the holder of its secret could make.
- **Why the proof of possession is essential.** Without it, a prover could name a key equal to its own minus the
  honest signers' keys. "The honest signers plus that key" would then sum to the prover's own key, and its own
  signature would verify as theirs: the rogue-key attack, which forges any finality.
  `a_rogue_key_cannot_forge_the_honest_stake` mounts it and shows the forged aggregate verifying until the check
  refuses the key.
- **Cost.** Every new key is fully checked, subgroup included, at about one pairing. Activations are limited to 256
  ETH an epoch, so a day holds at most about 1,800 new keys: about 7 billion prover gas at worst, far less than proving
  every few epochs to keep the registry current would cost.

**The margin.** Records at `e0` go stale by `e1`, both ways, and the protocol limits each per epoch:
- exits take the activation-exit churn, `min(256 ETH, balance churn)`, and consolidations the rest of the balance
  churn, `max(128 ETH, total active balance / 65,536)`; stake that leaves this way still counts by the records;
- deposits, top-ups included, take a churn of their own, 256 ETH an epoch, before they enter the registry, so stake
  that joins after `e0` is bounded the same way; a key added since the anchor signs for nothing;
- activations take no churn in Electra: when finality returns, every validator queued in the registry activates at
  once, however long the queue grew while finality stalled. So the statement counts every record not yet given an
  activation epoch in the total, and never as signed stake (LG-6).

So the records drift by at most the balance churn plus 256 ETH an epoch: about 775 ETH at 34M ETH staked, and about
1,020 ETH at 50M. The threshold adds 2,048 ETH for every epoch since `e0`, over twice that drift at any stake below
about 50M ETH (LG-I1). `e1 − e0` is at most 225 epochs, a day, as the BNB verifier's `MAX_LAG` is, so the margin is at
most 460,800 ETH, about 1.4% of today's stake, and honest participation near 99% clears 66.7% plus that easily.

The records are those of `C1`'s block's state, which the next proof reads. A checkpoint's block is the one at its
epoch's first slot, or the last before it where that slot was missed, so its state is at most one epoch older than the
checkpoint, and the margin counts that epoch too. The statement refuses an older block (`StaleCheckpointBlock`, LG-6):
that needs every slot from the previous epoch's first to the checkpoint's own to be missed, and a later checkpoint
serves instead.

**What the margin does not bound.** The margin bounds churn, and an exit is not what frees a key within its window: a
validator that exits after `e0` stays slashable until its withdrawable epoch, at least 256 epochs (about 27 hours)
after its exit, past any proof's day. What frees a key is a slashing. A slashed validator cannot be slashed again,
while the records at `e0` still show it unslashed and active, and no churn limits how many are slashed. A mass
slashing between two proofs would lower, by the slashed stake, the stake a forger must put at risk. The statement does
not bound that: it is a known limitation, and such a slashing would be a public attack on Ethereum itself (LG-I1).

The verifier holds that day by the clock as well (LG-4). The statement bounds each step in epochs only, so without a
clock an honest prover could walk a verifier left behind forward through old checkpoints, and validators who had since
exited, and could no longer be slashed, could sign one of those at no risk. So `update` refuses a proof once
`MAX_LAG` (1 day) has passed since the stored anchor's epoch began, dated from the network's beacon genesis time fixed
at deployment (`GENESIS_TIME`; `DeployVault` takes mainnet's or Sepolia's from the indexes' chain and refuses an anchor
already past it). A day behind, a verifier stops for good and is rotated, as the BNB one is.

**The new anchor.** `C1`'s block header hashes to `r1`. Two SSZ proofs from its state root give the new
`validatorsRoot` (field 11) and the block hash of the execution payload the block carried: the state's
`latest_execution_payload_header` (field 24), which a block's post-state sets to its own payload's. So the block's body
is never needed.

**Execution headers.** The prover supplies every execution header from the anchor's last block to `C1`'s, each
hashing to its successor's parent hash and the last to `C1`'s payload hash. The proof commits to a Merkle root
(keccak) over one leaf per header, `keccak256(abi.encode(number, timestamp, stateRoot, receiptsRoot))`, so a
message in any block since the last anchor can be proven.

**Public values** (ABI-encoded): the anchor in, the anchor out, `e1`, the headers root, and the first and last block
numbers it covers.

### The verifier contract, and what the vault asks of it

`update(publicValues, proof)`: anyone. It checks the SP1 proof against the fixed program key, requires the anchor in
to equal the stored one, stores the anchor out, and records the headers root. Then:
- `verifyEvent(proof)`: a header leaf proven into a recorded headers root, a receipt proven against the leaf's
  `receiptsRoot` (Merkle-Patricia, key `rlp(txIndex)`), and the log at `logIndex`. It returns what the vault needs.
- `verifyCheckpoint(proof)`: a header leaf proven into a recorded headers root, returned as the checkpoint.

**On Solana (built 1 October 2026).** `solana/programs/ethereum-verifier` is the same verifier as a Solana program,
behind the vault's existing verifier interface (`xindex_vault::verify`).
- **Same rules.** The same anchor, the same headers tree, the same receipt and log checks. `update` keeps the anchor in
  a state account and each proof's covered blocks in an account at the headers root's address.
- **Groth16.** It checks SP1 v6's Groth16 proof with the `alt_bn128` syscalls, which take Ethereum's encodings, so it
  is a line-for-line port of the vendored Solidity verifier.
- **Measured** in LiteSVM:
  - verifying SP1's own v6 proof takes 96,910 compute units, under 7% of a transaction's 1.4M;
  - proving a real mainnet log takes 9,100 to 12,500.
- **Staged proofs.** An event proof is 1.5 to 2.2 KB, more than a transaction holds, so the relayer stages it in a
  loader buffer first. What the buffer holds is no more trusted than instruction data.
- **Deployment.** As the stub: the upgrade authority sets the program key, the first anchor and the network's beacon
  genesis time once, then makes the program immutable, which the vault requires.
- **Any receipt (LG-1).** It reads RLP lists in place, as `RlpReader.sol` does, and carries a node's length in 32 bits,
  so neither a receipt's number of logs nor a leaf past 64 KB exhausts its 32 KiB heap. Only compute bounds a receipt:
  513 logs take 41,633 units, and about 19,600 logs or 2.8 MB of log data fit, below the about 44,700 empty logs a
  2^24-gas transaction can hold. That residual ceiling is why messages can be sent again (section 2).
- **A day's lag (LG-4).** `update` refuses a proof more than a day after the stored anchor's epoch began, as the EVM
  verifier does. With no stall recovery on the Solana vault yet (SOL-7), a P1 left a day behind there cannot be
  rotated out on its own: a `VERIFIER_ROTATION` needs both proofs, P1's included (LG-I4).
- **Not built.** `verifyCheckpoint`: the Solana vault has no checkpoints or snapshot exit yet.

### Deliberately not in P1

- **A cheaper commitment than the registry's.** Every record is proven against the SSZ registry root, which means
  re-hashing the whole registry, 2.4 million validators, exited ones included, in every proof. That is simple and
  obviously sound, and it is now nearly all of P1's cost: 36.6B prover gas on mainnet data, after the input was made
  compact (a key only for each signer, read once for both links; an exited validator as the four values its leaf
  needs). A commitment kept up by the proofs themselves is left for a reviewed later version.
- **One-epoch finality.** Section "One-epoch finality" of the prototype record is not relied on; both links are
  proven.
- **Forks.** The fork schedule is a constant of the program, so a new Ethereum fork needs a new program key, which is
  a verifier rotation (30 days), proposed well ahead of the fork.

## 11. P2: the same statement, proven by RISC Zero (built 1 October 2026)

The design (4.4) asks for two independent systems from Ethereum to each vault chain, "from different teams and
different proving stacks", so that one broken prover can stop coins but never move them. P1 runs on SP1, Succinct's
zkVM. P2 runs on RISC Zero, the owner's call on 1 October 2026: another team, another RISC-V zkVM with its own
circuits, its own STARK-to-SNARK wrapping and its own Groth16 setup.

**What is shared, and what that means.** P2 proves the statement of section 10, the code in `proofs/finality`, with
the same input and the same public values. A soundness bug in either zkVM, in its circuits or in its Groth16 wrapping
breaks one system only, which is the failure the two-system rule exists for. A bug in the statement itself would
break both at once. That shared risk is a known
limitation, stated here rather than left implicit. What stands against it is what stands behind P1: the statement
is plain Rust tested natively, its SSZ and BLS checked against the consensus specs' own libraries (`vectors.py`),
real mainnet and Sepolia votes, mutants the tests catch, and the audits before launch. A second statement written
apart from the first would close it, at the cost of a second program to audit.

**The guest** (`proofs/p2/methods/guest`) reads the bincode of `xindex_finality::Input` that `p1-input` writes, the
same file P1's program reads, runs `xindex_finality::verify`, and commits `Output::abi_encode()` as its journal: P1's
public values, byte for byte. An input for which the statement does not hold panics, so no receipt exists. The
accelerated `sha2`, `bls12_381` and `tiny-keccak` are RISC Zero's forks of the exact versions the statement uses. The
guest is a workspace of its own, since RISC Zero's forks and SP1's replace the same crates. `--features sepolia`
builds the testnets' guest, with its own image id, as for P1.

**The host** (`p2`, `proofs/p2/host`) runs the guest in execute mode and checks its journal against the statement run
natively, prints the image id, and proves with RISC Zero's Groth16 on Bonsai or a CUDA GPU; like P1's host, it
refuses this machine's CPU. Before writing a proof it verifies RISC Zero's receipt against the image id and checks the
journal again.

**One statement, two zkVMs.** The statement calls no zkVM fork's own API. Its hash to G2 had used SP1's fork of
`bls12_381`, whose `hash_to_curve` takes other arguments than zkcrypto's and RISC Zero's; `bls::hash_to_g2` now
composes it from RFC 9380's steps (`expand_message_xmd` with SHA-256, two field elements, the map, the cofactor) over
functions every build shares, and RFC 9380's own vectors pin it (`finality/tests/hash_to_curve.rs`). P1's output is
unchanged on every test and on the real input below; its program key changed with its code.

**Measured** (1 October 2026, execute mode, the real Sepolia input: 1,997 validators, 1,874 and 1,784 signers in the
two links, 64 execution blocks): P2 runs 1.84 billion RISC Zero cycles in 1,864 segments, P1 327 million SP1
instructions (358 million prover gas), and both commit the same 192 bytes, which the statement run natively computes
too. Where RISC Zero spends its cycles is not profiled yet.

**The verifier contract.** `EthereumFinalityVerifier` was split: what P1 and P2 share, the anchor, the recorded
ranges, the headers tree and the receipt proofs, is `FinalityVerifier`, unchanged; each system adds only the check of
its proof. `RiscZeroFinalityVerifier` calls `verify(seal, IMAGE_ID, sha256(publicValues))` on one RISC Zero Groth16
verifier deployment, never RISC Zero's router, which has an owner: nothing outside the contract can change what P2
accepts, as for P1, which calls one SP1 Groth16 verifier and not SP1's gateway. The verifier suite runs once through
each, and P2's own test pins the SHA-256 digest of the journal.

**Before mainnet, for the owner:**
- RISC Zero's and SP1's Groth16 setups must each meet the design's rule: no secret setup, or one from a large public
  ceremony. Check each against its published ceremony record.
- The image id is reproducible only from a pinned build: RISC Zero builds a guest reproducibly in its Docker image,
  which a mainnet image id should come from.
- P2 on Solana, the twin of `solana/programs/ethereum-verifier`, waits with the rest of the Solana work.
