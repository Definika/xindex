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
| `MIGRATE` | the old index | `(newIndex, token, amount)` | P1 **and** P2 | moves coins between two indexes' balances (6.7) |
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
- the stall-gated recovery and the snapshot exit (design 6.9), which come next;
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
  tracking: a new set is accepted only as an epoch header that the previous set finalized. The prototype found that a
  set takes effect some blocks after its epoch block, and the verifier must model that switch.

## 6. Build order

1. The message library and the verifier interface. Then the EVM vault, with unit tests, an invariant suite, mock
   verifiers, and 100% coverage under the repository's gates.
2. The BNB Chain state verifier on Ethereum, from the prototype, with validator-set tracking and fork tests against
   BNB Chain data.
3. The factory's chain registry, and `HybridHub` (once proposal 1 is decided).
4. The Ethereum-event verifiers (P1, P2), once the owner decides the proof system after the GPU run.
5. The Solana vault program, then HyperEVM and Tron.
6. The stall recovery and snapshot exit, then watchers, then the testnet rehearsals of the design's Phase 3.
