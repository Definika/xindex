# Source reading of the 43 tokens listed on 2026-10-10 (CF-4)

**Owner's calls, 2026-10-18:** SAND and RLB are off the list; H, PLUME, SNX, SYRUP, GALA and MANA stay, MANA, CHZ, SENT
and FLUID labelled Pausable.
**Status:** prepared on 2026-10-18 for the owner's sign-off, which this reading does not replace. It is the reading
`audit/2026-10-13-security-audit.md` (CF-4) says is owed: the 31 Ethereum-issued coins and the 12 Wormhole copies
listed on 2026-10-10 (DOGE's copy, the 13th, left on 2026-10-14). Summarized in `design/2026-10-18-pre-mainnet-readings.md`,
section 6, with the owner's open calls.

- **Reads:** Ethereum blocks 26,215,048 to 26,215,359 (2026-10-17, 21:45 to 22:47 UTC) through
  `ethereum-rpc.publicnode.com`; BNB Chain block 128,252,469 for the five Binance-Peg sources only.
- **Addresses:** exactly those of `script/MainnetAddresses.sol`.
- **Marks:** **[v]** read on chain (a call, a storage slot, bytecode or selectors); **[s]** read in the verified
  source; **[w]** a website, database or explorer label says it, not verified. Event histories come from Blockscout's
  log index, since the public RPC refuses archive log ranges; every address taken from them was read on chain [v].
- **Read again** [v], independently of the first pass: SAND's admin (a Safe, threshold 3) and execution admin (a
  multisig wallet requiring 2), and the meta-transaction processor as both super operator and execution operator;
  RLB's implementation unverified on Blockscout and its ProxyAdmin and token both owned by one externally owned key;
  H's `burn(address,uint256)` being `onlyOwner` with no allowance, under a 4-of-7 Safe; EIGEN's 1-of-2 Safe owned by a
  10-day timelock and a 9-of-13 Safe; MANA's crowdsale owner key succeeding with `pauseToken()` where a stranger
  reverts.
- The raw evidence (sources as fetched, call outputs, excerpts) was kept outside the repository; every [v] read can
  be repeated at the blocks above.

## Summary

None of the 43 is refused by the letter of the WBT rule: no token, in its current code, can both blacklist a holder
and destroy or seize its balance. Eight need the owner's attention; six of them `CheckToken` reported listable, or
without the power below.

| # | Token | Why |
|---|---|---|
| 1 | **SAND** | Two independent multisigs can each move or burn any holder's SAND, an index's included, in one transaction with no timelock [s][v]: the admin (a 3-of-5 Safe) through super operators, and a separate execution admin (a 2-of-3 legacy multisig) through execution operators. 22 third-party contracts already hold the no-allowance power [v]. The rule's purpose, that one party can zero an index's leg, applies; only the missing blacklist keeps it out of the rule's letter. **Recommended: treat as refused unless the owner accepts this.** |
| 2 | **RLB** | The implementation `0x0D9Bdd2d61A37Bc074e59b2801F32deEE01307e5` is not verified on Blockscout or Sourcify [v], so it cannot be read. One externally owned key, `0x3bC7FF113Afe1b34EeDb96f01D4B4b865F5b901B`, owns both the ProxyAdmin (upgrade at any time) and the token (pause) [v]. **Recommended: delist until the source is verified.** |
| 3 | **H** | The owner, a 4-of-7 Safe with no timelock, can `burn(anyAccount, value)` with no allowance, mint without a cap, and upgrade [s][v]. |
| 4 | **SNX** | One 4-of-7 Safe owns the proxy, the token and the address resolver, with no timelock [v]. `migrateAccountBalances(account)` moves an account's whole liquid SNX to the caller, a caller the resolver alone names [s]; the Safe can also swap the `TokenState` that holds every balance, and the proxy's target [s][v]; transfers stop when `SystemStatus` suspends the system [s]. |
| 5 | **PLUME** | `burn(from, amount)` by `BURNER_ROLE` needs no allowance [s]. No account holds `BURNER_ROLE`, `PAUSER_ROLE` or `MINTER_ROLE` today [v]; the 4-of-7 Safe holding admin and upgrader can grant them at any time [v]. |
| 6 | **GALA** | `BLOCKLISTER_ROLE` (a 3-of-5 Safe) can blocklist any account, which then can neither send nor receive [s][v]. The current code destroys nothing: `burnFrom` spends an allowance [s]. A UUPS upgrade by the 4-of-7 admin Safe could add a destroy [s][v]. A blacklist alone is no bar (the owner's call of 2026-10-10). |
| 7 | **SYRUP** | A module can `burn(from, amount)` with no allowance [s]. Adding a module needs Maple's `GovernorTimelock` (3 days) and a `MapleGlobals` schedule (7-day delay, 2-day window) [v][s]; the one module today only mints to the treasury [s]. Low urgency. |
| 8 | **MANA** | One externally owned key, `0xDf861993Edbe95BAFbfA7760838f8ebbd5Afda9F`, can pause every MANA transfer through the 2017 crowdsale contract that owns the token: `pauseToken()` succeeds from that key and reverts from any other [v]. The crowdsale is unverified [v]. Label it Pausable, as WBTC is. |

### Where this differs from `CheckToken`

- **A burn that needs no allowance** [s]: H, PLUME, SYRUP, ZK and the 12 Wormhole copies. `CheckToken` files
  `burn(address,uint256)` and `bridgeBurn(address,uint256)` as a burn from another account, judged only beside a
  blacklist, because the same selector is a bridge's burn as often as an owner's; this reading is the check for
  which it is. For ZK and the Wormhole copies the power sits with the bridge, a trust the owner already accepted: keep.
- **Seizable** [s]: SNX, through `migrateAccountBalances`, `setTokenState` and `setTarget`. They sit behind Synthetix's
  own proxy (`target()`), a pattern the check's proxy reader does not follow, so its selector scan never sees them.
- **Blocklisting** [s]: GALA's `blocklist(address)` (0xe5c7160b) and `isBlocklisted(address)`, missing from the check's
  table. Added on 2026-10-18; the check now sends GALA to review (blocklist beside `burnFrom`).
- **SAND's second admin** [s]: the verdict (review) was right, but the check saw only `getAdmin()`; the execution
  admin's `setExecutionOperator(address,bool)` was added to the table on 2026-10-18 beside `setSuperOperator`.
- **Not readable:** RLB's implementation, MANA's owner contract (the crowdsale `0xA66d83716c7CFE425B44D0f7ef92dE263468fb3d`;
  MANA itself is verified) and one of SAND's 22 super operators, `0x7c7cd62a9ab6ae50d21b9cad6dae15824bf9a86a`, a land
  sale by its selectors [w] that expired on 2021-09-04 [v]. Everything else is verified on Blockscout.

### The address book against the chain

- **EIGEN** said "a 1-of-2 Safe: that key can change the token's code at any time". The Safe `0x369e6F59…`'s two
  owners are an OpenZeppelin `TimelockController` (`0xC06Fd4F8…`, a 10-day delay) and a 9-of-13 Safe (`0xFEA47018…`)
  [v], either acting alone. Corrected in `script/MainnetAddresses.sol`.
- **ATH**'s verified source calls itself "Cethir Token"/"CTH"; the chain answers "Aethir Token"/"ATH" [v]. Name and
  symbol are constructor storage, so the runtime code still matches (Blockscout: partial match; Sourcify: runtime
  match): the logic read is the deployed logic.
- **APE** is verified under the contract name "Astgik": a plain OpenZeppelin ERC-20 with a constructor mint and no
  admin [s][v].

## SAND, `0x3845badAde8e6dFF049820680d1F14bD3903a5d0`

Verified (Blockscout and Sourcify full matches; `Sand`, solc 0.5.9). Not a proxy: every proxy slot is zero [v] and the
source has no `delegatecall` [s]. 18 decimals; no mint after the constructor, no pause, no blacklist, no fee, no
receive hooks [s].

| Who | Function | Effect [s] |
|---|---|---|
| admin (`getAdmin()`) | `changeAdmin`, `setSuperOperator(addr, bool)` | appoints super operators |
| super operator | `transferFrom(from, to, amount)` | no allowance needed |
| super operator | `burnFor(owner, amount)` | no allowance needed: destroys any balance |
| super operator | `approveFor`, `addAllowanceIfNeeded` | sets an allowance on any holder |
| execution admin (`getExecutionAdmin()`) | `changeExecutionAdmin`, `setExecutionOperator` | appoints execution operators, independently of the admin |
| execution operator | `transferAndChargeForGas(from, to, amount, …)` | moves any holder's balance with no allowance |
| execution operator | `approveAndExecuteWithSpecificGas(from, to, amount, …)` and its `…AndChargeForIt` variant | raises `from`'s allowance to `to` and calls `to` |
| execution operator | `executeWithSpecificGas(to, gas, data)` | any call made by the SAND contract |

Who holds them [v]:
- **Admin:** `0x6ec4090d0F3cB76d9f3D8c4D5BB058A225E560a1`, a Safe 1.3.0, 3 of 5 externally owned keys, no module, no
  guard, no timelock.
- **Execution admin:** `0xEAA0993E1d21c2103e4f172a20D29371FbAF6D06`, Gnosis's `MultiSigWalletWithDailyLimit`, 2 of 3
  externally owned keys, no delay.
- **Execution operator:** one, `0xb48ce889bdfc5164c309d03b9c6126133c85f396`, the `NativeMetaTransactionProcessor`. It
  has no admin, and moves `from`'s SAND only on `from`'s signature (`ecrecover`, or `from`'s own EIP-1271 or EIP-1654
  `isValidSignature`) [s]. Xindex's contracts implement no `isValidSignature` and no `fallback` or `receive` [s], so an
  index cannot be drained through it.
- **Super operators:** 22, all contracts, none revoked; `isSuperOperator` is true for each today. Beside the
  meta-transaction processor: 2 `AssetSignedAuction`, 2 `LandSaleWithETHAndDAI` (expired in 2019), 4 `CatalystMinter`,
  10 `EstateSaleWithFee`, `StarterPackV1`, `CommonMinter` and the unverified land sale `0x7c7c…`. Each accepts an
  arbitrary `buyer`, `from` or `creator` when the caller is one of its registered meta-transaction processors, which
  its own admin sets [s]; 20 of the 22 have `0xEAA0…` as admin. Four `EstateSaleWithFee` contracts (`0xb11822c3`,
  `0xc3ab6492`, `0x2e95319e`, `0x6ee6b352`) never expire: their expiry is stored in milliseconds, 1601053200000 [v].

**Assessment.** Either multisig can move or burn an index's SAND in one transaction, with no timelock, and any bug in
the 22 old operator contracts can do the same. `design/2026-09-30-wbt-check.md` justifies the rule with "one key could
blacklist an index hub and zero its WBT"; SAND needs no blacklist for that. Review by the rule's letter, refused by its
purpose: the owner's call.

## The Wormhole copies

XRP, ADA, LTC, DOT, ATOM, AVAX (WAVAX), JUP, ALGO, AERO, APT, PYTH and OP [v]:
- Each is a `BridgeToken` beacon proxy whose beacon slot holds the token bridge,
  `0x3ee18B2214AFF97000D974cf647E7C347E8fa585`, which is also its `owner()`. The bridge's `tokenImplementation()` is
  `0x0fD04a68d3c3A692d6Fa30384D1A87Ef93554eE6`; `isWrappedAsset` is true for all 12, and each copy's `chainId()` and
  `nativeContract()` match the address book. AVAX's proxy is an older `BridgeToken` build over the same beacon.
- `TokenImplementation` [s]: `mint`, `burn` (no allowance) and `updateDetails` are the bridge's alone; `permit`; no
  pause, no blacklist, no fee, no hooks. The bridge burns only what it pulled from the sender, and mints only on
  transfers the guardians signed [s].
- Upgrades: the bridge proxy's admin slot is empty [v]; `upgrade(vaa)` needs a governance message the core verifies,
  guardian set 7, 13 of 19 [v][s], with no timelock, and the new implementation can set a new token implementation, so
  one message can change every copy's code at once [s].
- The five Binance-Peg sources on BNB Chain [v]: none is a proxy, none can pause or blacklist; each has `mint(uint256)`
  under the same externally owned key, `0xF68a4b64162906efF0fF6aE34E2bB1Cd42FEf62d`, which can mint unbacked BEP-20s
  and bridge them.

Keep all 12: the trust the owner accepted on 2026-10-10.

## Table

"Who holds them" is [v] unless marked. Throughout: decimals 6 to 18 [v]; no fee on transfer, rebasing or receive
hooks [s]; every non-proxy's proxy slots are zero [v].

| Token | Address | Proxy and upgrade (who) [v] | Verified | Powers [marks] | Who holds them | Verdict |
|---|---|---|---|---|---|---|
| FF | `0xFA1C09fC8B491B6A4d3Ff53A10CAd29381b3F949` | no | Blockscout partial | none: fixed supply; permit [s] | nobody | keep |
| BTT | `0xC669928185DbCE49d2230CC9B0979BE6DC797957` | no | Blockscout full | mint by `PREDICATE_ROLE`; meta-transactions [s] | BTTC predicate proxy `0x9277a463`, upgraded by a 3-of-5 Safe `0x4fb08a82`; `DEFAULT_ADMIN_ROLE` empty | keep (bridge mint) |
| GNO | `0x6810e776880C02933D47DB1b9fc05908e5386b96` | no | Blockscout partial | none [s] | nobody | keep |
| OHM | `0x64aa3364F17a4D01c6f1751Fd97C2BD3D7e7f1D5` | no | Blockscout full | mint by the vault; `burnFrom` spends an allowance [s] | `OlympusMinter` `0xa90bFe53`; governor a 4-of-8 Safe `0x245cc372` | keep |
| GRT | `0xc944E90C64B2c07662A292be6244BDf05Cda44a7` | no | Blockscout partial | mint by minters; `burnFrom` spends an allowance [s] | governor a 4-of-7 Safe `0x48301Fe5` | keep |
| SYRUP | `0x643C4E15d7d62Ad0aBeC4a9BD4b001aA3Ef52d66` | `MapleTokenProxy` over `0x6eD767EB`; scheduled governor upgrade [s] | Blockscout full | module **burn any account, no allowance**; module mint [s] | `RecapitalizationModule`; `GovernorTimelock` (3 days); Globals schedule (7 days) | **review** |
| ENS | `0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72` | no | Blockscout full | mint at most 2% a year [s] | OZ timelock, 2 days | keep |
| JASMY | `0x7420B4b9a0110cdC71fB720908340C03F9Bc03EC` | no | Blockscout partial | none [s] | nobody | keep |
| COMP | `0xc00e94Cb662C3520282E6f5717214004A7f26888` | no | Blockscout partial | none [s] | nobody | keep |
| EIGEN | `0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83` | transparent proxy over `0x2C4A81e2`; ProxyAdmin `0x8b9566ad` | Blockscout full | scheduled mint; transfer allowlist off for good; upgrade [s][v] | a 1-of-2 Safe owned by a 10-day timelock and a 9-of-13 Safe | keep |
| AXS | `0xBB0E17EF65F82Ab018d8EDd776e8DD940327B28b` | no | Blockscout partial | the old Ronin gateway holds an infinite allowance over every holder, fixed at construction [s][v] | gateway `0x1A2a1c93`, paused; its admin can only pause, and its code pulls only from `msg.sender` [s][v] | keep (note) |
| SAND | `0x3845badAde8e6dFF049820680d1F14bD3903a5d0` | no | Blockscout and Sourcify full | operators **move or burn any holder's balance** [s] | a 3-of-5 Safe; a 2-of-3 multisig; 22 super operators, 1 execution operator | **review; refused by the rule's purpose** |
| BAT | `0x0D8775F648430679A709E98d2b0Cb6250d2887EF` | no | Blockscout partial | sale functions only, finalized [s][v] | nobody | keep |
| CVX | `0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B` | no | Blockscout partial | mint by the operator, capped at 100M, reached [s][v] | Booster `0xF403C135` | keep |
| MANA | `0x0F5D2fB29fb7d3CFeE444a200298f468908cC942` | no | Blockscout partial | **pause every transfer**; mint, minting not finished [s][v] | the crowdsale `0xA66d8371` (unverified), owned by the key `0xDf861993` | keep, label Pausable |
| IMX | `0xF57e7e7C23978C3cAEC3C3548E3D615c346e79fF` | no | Blockscout partial | mint capped at 2B, reached [s][v] | — | keep |
| FLUID | `0x6f40d4A6237C257fff2dB00FA0510DeEECd303eb` | delegator over `0x31de2088`; upgrade by the master [s] | Blockscout full | **pause every transfer**; mint at most 2% a year; upgrade [s] | a 1-day timelock `0x2386DC45` under GovernorBravo `0x0204Cd03` | keep, label Pausable |
| CHZ | `0x3506424F91fD33084466F402d5D97f05F8e3b4AF` | no | Blockscout partial | **pause every transfer** [s] | 2 externally owned keys | keep, label Pausable |
| ZK | `0x66A5cFB2e9c529f14FE6364Ad1075dF3a649C0A5` | beacon over `0xEA3c8d61`; owner ZKsync's `ProtocolUpgradeHandler` [w for the name] | Blockscout | `bridgeBurn(from)` with no allowance; `bridgeMint`, both by the vault [s] | vault `0xbeD1EB54`; burns the depositor [s] | keep (bridge) |
| APE | `0x4d224452801ACEd8B2F0aebE155379bb5D594381` | no | Blockscout and Sourcify, as "Astgik" | none [s] | nobody | keep |
| SENT | `0x56A3BA04E95d34268A19b2a4474DC979baBDaf76` | UUPS over `0x9Fec8725` | Blockscout full | **pause**; upgrade; inflation at rate 0 [s][v] | a 4-of-7 Safe | keep, label Pausable |
| SNX | `0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F` | `ProxyERC20`, target `0xc5f0b419`; `setTarget` by the owner | Blockscout | **`migrateAccountBalances`**; `setTokenState`; suspension [s] | one 4-of-7 Safe | **review** |
| 1INCH | `0x111111111117dC0aa78b770fA6A738034120C302` | no | Blockscout partial | mint by the owner [s] | owner renounced | keep |
| GLM | `0x7DD9c5Cba05E151C895FDe1CF355C9A1D5DA6429` | no | Blockscout partial | mint by minters [s] | only `GNTMigrationAgent`; owner renounced | keep |
| ATH | `0xbe0Ed4138121EcFC5c0E56B40517da27E6c5226B` | no | Blockscout partial; Sourcify runtime | mint into the token itself, cap reached; pays out to allowlisted accounts [s][v] | a 2-of-3 Safe | keep |
| H | `0xE76c5b78f93909d34404E9eb4C1f19e7582a5dE1` | transparent proxy over `0x85D0B85f`; ProxyAdmin `0xb3b355a9` | Blockscout full | **burn any account, no allowance**; mint, no cap; upgrade [s] | a 4-of-7 Safe | **review** |
| PLUME | `0x4C1746A800D224393fE2470C70A35717eD4eA5F1` | UUPS over `0x8ab07665` | Blockscout full | **burn any account, no allowance**; pause; mint; upgrade [s] | a 4-of-7 Safe; burner, pauser, minter: none today | **review** |
| GALA | `0xd1d2Eb1B1e90B638588728b4130137D262C87cae` | UUPS over `0x8D92A681` | Blockscout | **blocklist**; pause; mint; upgrade [s] | blocklister a 3-of-5 Safe; admin a 4-of-7 Safe; minter `GalaBridge`, owned by one key | **review** |
| RLB | `0x046EeE2cc3188071C02BfC1745A6b17c656e3f3d` | transparent proxy over `0x0D9Bdd2d` (**unverified**); ProxyAdmin `0x61772739` | implementation: **neither** | selectors [v], named by 4byte [w]: pause, snapshot, flash mint, burn, permit | one key, `0x3bC7FF11` | **review** |
| W | `0xB0fFa8000886e57F86dd5264b9582b2Ad87b2b91` | UUPS over `0x34451893` | Blockscout partial | mint, capped; own-balance burn; `burnFrom` disabled [s] | Wormhole `Governance` `0x23Fea551` | keep |
| RSR | `0x320623b8E4fF03373931769A31Fc52A4E78B5d70` | no | Blockscout full | pause by pauser, mage or owner [s] | all zero | keep |
| XRP, ADA, LTC, DOT, ATOM | as in the address book | Wormhole beacon proxy | — | bridge mint and burn [s] | the token bridge | keep (Custodial) |
| AVAX, JUP, ALGO, AERO, APT, PYTH, OP | as in the address book | Wormhole beacon proxy | — | the same | the same | keep |

## Notes

- **SYRUP:** with no per-function override for adding a module or setting an implementation, the global delay
  applies [v][s].
- **PLUME:** every grantee in the log index was checked with `hasRole`; only the Safe still holds a role [v].
- **SNX:** the resolver's two allowed callers are `0x94f864e5` and `0x3AcF163B`; whether either lets a third party name
  another account was not read. Balances live in `TokenState` `0x5b1b5fEa`.
- **RLB:** never upgraded (one `Upgraded` event, at block 17,579,757); `flashFee` is 0 [v].
- **MANA:** the crowdsale is finalized; `beginContinuousSale()` also succeeds from the key in a simulation, a mint path
  [v].
- **AXS:** the gateway's infinite allowance is permanent [s].
- **BTT:** unbacked minting is possible if its predicate is upgraded.
- **Not done:** no fork, no transaction; event histories from Blockscout; SAND's 22 operator contracts were read only
  for how each constrains `from`.
