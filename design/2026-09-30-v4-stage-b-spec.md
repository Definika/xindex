# Xindex v4 Stage B: contract specification (draft)

Stage B adds the native coins of BNB Chain, HyperEVM, Tron and Solana, held in vaults on their own chains, to indexes
whose shares live on Ethereum. The design is `design/2026-09-29-v4-hybrid-architecture.md`, sections 3 to 8. This spec
fixes what the design leaves open, and marks each deviation from it as a proposal for the owner.

**Status: draft, 2026-09-30; section 1 decided the same day.** The build starts with the parts every outcome of the proving prototype shares: the
message format, the EVM vault, and the vault-to-Ethereum path for BNB Chain. Everything that depends on which
Ethereum-finality proof is used (full finality, or the sync-committee fallback) sits behind one interface, and waits
for the owner's decision after the GPU run.

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
   each decided when its verifier is built.
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
| `destChainId` | the vault chain's EVM chain id (Tron and Solana get fixed ids in the chain registry) |
| `vault`, `index` | the vault's address on its chain; the Ethereum address of the hub, or of the factory for governance |
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

## 3. The Ethereum-event verifier interface

```solidity
interface IEthereumEventVerifier {
    /// Proves that a log with this emitter, first topic and data is in an Ethereum block that has reached the
    /// finality the verifier implements; reverts otherwise.
    function verifyEvent(bytes calldata proof)
        external view returns (address emitter, bytes32 topic0, bytes32 topic1, bytes memory data);
}
```

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
- Tron's TVM differences, audited when Tron's vault is built.

## 5. Ethereum side

- **The chain registry** in the factory: `proposeChain(chainId, vault, stateVerifier)` behind `LISTING_DELAY`, as the
  design sets out (4.1). The registry also carries the chain ids assigned to Tron and Solana.
- **`HybridHub`** (proposal 1): Stage A's in-kind logic for Tier 1 tokens, plus:
  - the mirror per vault token (7.2);
  - mint orders with the 24-hour lock and automatic voiding (6.3);
  - redemption that emits `BURN` messages (6.5);
  - the rebalance with deliveries, bond and settlement (6.6);
  - `MINT_CAP`, per-chain freeze flags, migration, recovery addresses.
- **A state verifier per chain.** For BNB Chain, the prototype's vote check and storage proof, plus validator-set
  tracking, set out in section 5.1.

### 5.1 The BNB Chain state verifier

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

**One factory or two: decided later** (the owner's call on 2026-09-30, once it was clear that Stage B is added beside
Stage A either way). An index's tokens are fixed for good, so no Stage A index ever gains a vault token under either
choice. Holders switch to a Stage B index when they choose, and a helper could do the Ethereum part in one transaction.
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
1. `acceptRebalance(recipients)` at the current λ, while the auction is live. It freezes λ and the settlement's units,
   and takes three things from the executor:
   - a bond of `REBALANCE_BOND` (0.1%) of the supply, in shares;
   - every bought Ethereum component, in the same transaction;
   - one recipient per vault chain, for the sold vault legs.

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
- **Sizes.** The hub is 23.1KB and the module 23.5KB, each under the 24KB limit.
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
- **Evidence.** `freezeOnEvidence(chainId)` lets any of the factory's HybridHub clones freeze a chain as the owner or
  guardian can, once it has checked evidence that the chain's records or proofs are false (section 5.5). An
  Ethereum-only index cannot call it.

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
- **(c)** both prove again the last message the vault delivered, its id recorded at each delivery. This is a fixed
  sample the proposer cannot choose.

Review and adoption:
- **Review** lasts `RECOVERY_DELAY` (30 days). The freezer may veto `MAX_RECOVERY_VETOES` (2) successors per stall; a
  stall is identified by the checkpoint it began after.
- **Adoption** by anyone after the review needs a checkpoint the successor proves, recent at that moment. The vault
  leaves its stall.
- **Lapse.** A checkpoint from the pair in force at any time lapses the successor: the old pair works, so there is
  nothing to recover.
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

**Not built, stated plainly:**
- **Look-through for the official pool's LPs.** The hub records no official pool yet, and a concentrated-liquidity
  position's share of the index tokens depends on its ticks, the pool's price and uncollected fees, read from proofs of
  the pool's storage. The choices are the owner's: which pool, V3 or V4, and whether to read positions by owner or by
  NFT. Until then, the pool's shares at the snapshot are unclaimable, and so are the shares of anyone who could neither
  sign nor register a recovery address.
- **Burns in flight at the snapshot.** A burn issued at or before the snapshot but not yet delivered needs the old
  verifiers to prove an event from before it. If they cannot, those coins stay in the vault. That is a redeemer's part
  of a few minutes before the break. The fix is a per-burn record in the hub's storage, about 22,000 gas per vault burn
  on every redemption, for the vault to pay from the snapshot's state; it is the owner's call.
- **A forged exit record**, possible only with a broken state verifier, freezes one index's mints on that chain for
  good. That is a delay: holders migrate once the verifier is rotated.
- **The real P1 and P2**, and a successor's proof of descent, belong to the proof system the owner picks after the GPU
  run. The vault's side is fixed by the interface above.

## 6. Build order

1. The message library and the verifier interface. Then the EVM vault, with unit tests, an invariant suite, mock
   verifiers, and 100% coverage under the repository's gates.
2. The BNB Chain state verifier on Ethereum, from the prototype, with validator-set tracking and fork tests against
   BNB Chain data.
3. The factory's chain registry, and `HybridHub` (once proposal 1 is decided). Layer 1 is built (section 5.2); layer 2
   is the rebalance with deliveries and bond (built, section 5.3); the governance messages (section 5.4), and
   migration with the evidence against a chain (section 5.5), are built.
4. The Ethereum-event verifiers (P1, P2), once the owner decides the proof system after the GPU run.
5. The Solana vault program, then HyperEVM and Tron.
6. The stall recovery and snapshot exit (built, section 5.6, but for the pool look-through), then watchers, then the
   testnet rehearsals of the design's Phase 3.

## 7. The Solana vault (hackathon build, from 30 September 2026)

The EVM vault's rules (section 4), ported to a Solana program in `solana/programs/xindex-vault`, for the testnet
demonstration of `design/2026-09-30-hackathon-plan.md`. It keeps the same messages, the same digests, the same speed
limit and the same freeze. What Solana changes:

- **Identity.** The vault is the program's `config` account. Its 32-byte key is what Ethereum registers as the chain's
  vault and names in every message.
  - The hub builds digests with a vault's low 20 bytes (`_vaultAddress`), as for an EVM chain, so the program hashes
    those same 20 bytes, the last 20 of its key. That is enough for the demonstration. For production, the digest
    should carry all 32 bytes, a change to the hub and to both vaults.
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
    1,143 bytes. Real proofs need an address lookup table for the static accounts, and possibly a buffer account.
  - A real P1 is an SP1 Groth16 verifier whose public values commit to the log (about 94,000 compute units, bounded
    in `design/2026-09-30-proving-prototype.md`).
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
- 6 unit tests pin the encodings against Solidity's.
- 29 LiteSVM tests cover initialization, registration, deposits, the route, the used mark, burns under the speed limit,
  refunds, migration, governance and its delay, the freeze, rotation, and the red team's findings (SOL-1 to SOL-9,
  VLT-2, VLT-4).
- `anchor build --no-idl`: Anchor's IDL generator cannot follow addresses derived from the payload.

**Not in the hackathon build:** stall recovery and the snapshot exit (section 5.6), which follow once Solana's own state
proof exists; the vault's state proven to Ethereum, which a relayer stub stands in for; tokens other than SOL.

**The stubs.** `solana/programs/stub-verifier` accepts any log its relayer key signed. It is deployed twice, as P1 and
as P2, under two keys. Its name, its first line and the submission all say it is a stub. The Ethereum side's stub is
in `demo/`.

## 8. Open design problem: proving a vault's state on Ethereum, chain by chain (found 30 September 2026)

Proposal 3 (section 1) has Ethereum prove one storage slot of the vault per index or intake, against a state root the
chain's finality signs. That holds where a block commits to contract storage, and not everywhere:

| Chain | Does a block commit to the vault's storage? | Consequence |
|---|---|---|
| BNB Chain | Yes: an Ethereum-style state root | Built and tested (section 5.1) |
| HyperEVM | Its blocks carry an Ethereum-style state root; how HyperBFT finalizes them has no public light-client specification | Waits on that specification |
| Tron | No: a header's `accountStateRoot` covers balances only, not contract storage | Slot proofs are impossible |
| Solana | No: the accounts lattice hash (SIMD-0215) has no inclusion proofs | Slot proofs are impossible |

For Tron and Solana the vault's state has to reach Ethereum another way. The options, for the owner:
1. **Prove transactions, not storage.** Ethereum proves each deposit transaction in a final block, through
   `txTrieRoot` on Tron and Solana's transaction inclusion. The hub rebuilds the intake from them. Deadlines and
   refunds need the same care as today's digests.
2. **Prove execution** in a zkVM: the vault's state at a height, from the chain's blocks. That is general but heavy,
   another proof system per chain.
3. **Defer those chains.** Stage B launches with BNB Chain, whose path is built, and adds each chain once its proof
   exists.

The hackathon demonstration is unaffected: its state verifiers are stubs on every chain.

Sources: the TRON VM storage note (blog.phor.net/tron-vm-storage-vulnerability) and java-tron's archive-node
discussion; SIMD-0215 (accounts lattice hash) and the Solana light-client discussion #278 in
solana-improvement-documents.

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

