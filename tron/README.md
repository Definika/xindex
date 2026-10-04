# Xindex on TRON

TRON holds a vault like any EVM chain, with differences that only TRON's own compiler and VM show. This folder builds
the contracts a TRON deployment uses with Tron's compiler, runs them on TRON's VM on a local single-node chain of the
pinned java-tron release, and deploys them to a TRON network (`deploy.mjs`). Only `deploy.mjs` talks to a TRON
network, and only when told which. Stage B spec, section 5.7, records the results.

## What a TRON deployment runs

- `XindexVault`, linked to `VaultSnapshot`, and `EthereumStateReader`;
- P1, `EthereumFinalityVerifier`, on SP1's Groth16 verifier (`prototype/evm/src/sp1`);
- P2, `RiscZeroFinalityVerifier`, on RISC Zero's Groth16 verifier (`vendor/risc0-ethereum`).

`TronStateVerifier`, on Ethereum, proves the vault's `attest` calls.

## Tools

- **tron-solc 0.8.28** (`tv_0.8.28`), Tron's fork of solc at the version `src/` pins: from
  github.com/tronprotocol/solidity/releases, into `~/.local/tron-solc/0.8.28/` (or set `TRON_SOLC`). `build.mjs`
  checks its SHA-256 against the release's.
- **java-tron GreatVoyage-v4.8.2.3**, `FullNode-aarch64.jar` (or `FullNode.jar` on x86), and a **JDK 17**: from
  github.com/tronprotocol/java-tron/releases and adoptium.net. Check each against its publisher's SHA-256: the release
  lists `FullNode-aarch64.jar` as `a3f0d01fb20d456dcaf1b361638f046ba8396fa2f4e8e494b3a07c5d6f7d4819`, and Adoptium
  Temurin 17.0.20.1+1 for macOS aarch64 as `196d13ba5f10414bef7f6a05a9b3f00edacb18ebacef2b99485db9e2ee18f0e8`. Neither
  needs root: the JDK unpacks anywhere, and the jar runs from `node/`.
- **Foundry's `cast`**, for `deploy-test.mjs`, which writes the deployer's keystore as `cast wallet import` would.

```bash
npm ci --ignore-scripts    # tronweb 6.5.1 and viem 2.57.2, exactly, from the lockfile, running no install script
npm run build              # out/<Contract>.json, built by tron-solc
npm run node-config        # node/private.conf and a throwaway witness key, node/witness.json (git-ignored)
cd node && java -Xmx3g -jar FullNode-aarch64.jar --witness -c private.conf &   # a local chain, blocks every 3 s
cd .. && npm run rehearse  # every step below, as mined transactions; exits non-zero on any failure
npm run deploy-test        # deploy.mjs on the same chain: every refusal, then a whole deployment from a keystore
```

The node config is java-tron's own `config.conf` at the pinned release, with one witness, no peers
(`minEffectiveConnection = 0`, without which java-tron refuses every transaction), TRON mainnet's VM switches on
(read from mainnet's `getchainparameters` on 1 October 2026), and a 90-second maintenance. The rehearsal first raises
the chain's CPU limit from java-tron's default of 50 ms to mainnet's 80 ms, by a proposal its one witness approves.

## What the rehearsal shows (3 October 2026, Apple Silicon)

Run again on the code with the logic review's fixes (LG-1 to LG-6): P1 and P2 take the beacon genesis time and refuse a
proof a day past their anchor (LG-4), and the vault's recovery and last-message rules changed (LG-2, LG-3).

| Step, as a mined transaction | Energy |
|---|---:|
| SP1's Groth16 verifier on SP1's own proof (a wrong input reverts) | 217,950 |
| RISC Zero's Groth16 verifier on RISC Zero's v3.0 receipt (a wrong journal reverts) | 222,908 |
| P1's or P2's `update` from an anchor a day old: refused before the proof is read (LG-4) | about 1,250 |
| P1's or P2's `update` (the SNARK check mocked) | about 36,100 |
| P1's or P2's `verifyEvent` on a real mainnet receipt | 51,955 to 74,606 |
| The vault: `registerIndex`, by Ethereum's CREATE2 formula | 43,847 |
| The vault: a 10 TRX deposit | 163,556 |
| The vault: `attest` of the intake (a wrong value reverts) | 1,164 |
| The vault: `INTAKE_SETTLED` | 152,931 |
| The vault: a `BURN` paying 1 TRX to a new account | 211,982 |

Every step passes within mainnet's 80 ms. So a P1 or P2 `update` costs about 255,000 energy, and a delivery, with
both `verifyEvent`s, about 330,000 to 360,000. An `update` costs less than on 1 October (about 50,800 mocked), where the
rehearsal's anchor epoch was zero and the first update wrote a fresh slot.

**The CPU limit is the constraint, not energy.** TRON bounds each transaction by elapsed CPU time, 80 ms on mainnet
(chain parameter 13), and a transaction past it fails `OUT_OF_TIME` and burns its whole fee limit. The BN254 pairing
of a Groth16 check, which java-tron computes in Java, takes about 40 ms here for its four pairs (timed by calling
java-tron's precompile directly). At 80 ms every run passed; at java-tron's default 50 ms the first pairing of a
freshly started node, or one under load, did not. A block producer slower than this machine narrows the margin. So:
- whoever sends `update` on TRON sets its fee limit near its energy, about 300,000, so a timed-out attempt costs
  little, and sends again;
- the margin is measured again on Nile, TRON's test network, before mainnet.

**Other differences that matter, none of which needs a code change:**
- Tron's compiler makes the vault 26,593 bytes, past Ethereum's 24,576. TRON has no such limit: java-tron charges 200
  energy a byte to store code and checks nothing else (`VMActuator`, `Program.createContract`).
- Cancun, Shanghai, London and Istanbul are on, so the vault's Cancun bytecode runs as compiled.
- `block.chainid` is the last 4 bytes of the genesis block id: 728126428 on mainnet. A message to TRON names it.
- `block.timestamp` is in seconds, as on Ethereum.
- The BN254 precompiles sit at 0x06 to 0x08 with Ethereum's energy prices. There is no BLS12-381, which neither P1
  nor P2 needs.
- `registerIndex` computes an index's address by Ethereum's CREATE2 formula (prefix `0xff`) in code, as it must for
  indexes on Ethereum, whatever TRON's own `CREATE2` opcode uses (prefix `0x41`).
- `attest` is a view, and TRON accepts a transaction to a view: java-tron's refusal applies only before Constantinople,
  which mainnet has on.
- TRX has 6 decimals, so a TRON vault's caps and floor, and TRX's reference supply, are in sun.

## Deploying

**On TRON: `deploy.mjs`,** the twin of `script/DeployVault.s.sol`, which covers the EVM vault chains. After `npm run
build`, it deploys P1 (`EthereumFinalityVerifier`), P2 (`RiscZeroFinalityVerifier`), `EthereumStateReader`,
`VaultSnapshot` and `XindexVault` linked to it, each with `consume_user_resource_percent` at 100, so callers pay all
energy, as nobody owns the vault.

```bash
VAULT_FACTORY=0x... VAULT_HUB_TEMPLATE=0x... VAULT_P1_KEY=0x... VAULT_P2_IMAGE_ID=0x... \
VAULT_ANCHOR=0x... VAULT_ANCHOR_EPOCH=... VAULT_FREEZER=T... VAULT_RECOVERY=T... \
VAULT_NATIVE_CAP=<sun> VAULT_NATIVE_FLOOR=<sun> \
node deploy.mjs --network nile --keystore ~/.foundry/keystores/deployer [--dry-run]
```

- **The parameters** are DeployVault's, by the same names (the file's header lists them). TRON addresses may be base58
  or hex; the factory and the hub template are Ethereum addresses.
- **The key** never appears on the command line or in the environment. It is an Ethereum V3 keystore, the format `cast
  wallet import` writes, since a TRON key is the same secp256k1 key, unlocked by a password typed at the prompt or read
  from `--password-file`, which must be readable by its owner alone (`chmod 600`): a file holding the password beside
  the keystore is a raw key in effect, and one that group or others can read is refused (A7-21). Install with `npm ci
  --ignore-scripts`, never `npm install`, on the machine that unlocks the keystore: the lockfile's integrity hashes then
  hold, and no package runs a script. `--dry-run --from <address>` checks everything without the keystore and sends nothing.
- **The network** is named, never defaulted: `nile`, `mainnet` or `local`. The script reads the node's genesis block and
  refuses a node that is not that network (chain ids 3448148188 and 728126428). `--host` points at another node.
- **Before sending anything** it makes every check `DeployVault.check` makes, adapted to TRON:
  - the indexes' chain is mainnet Ethereum or Sepolia, and not this one;
  - the factory, the hub template, P1's key, P2's image id and the anchor are set;
  - P1 and P2 could still be advanced from the anchor: TRON's clock is within 12 hours of a day after its epoch's start
    (LG-4, A7-07), so the first advance, which needs two proofs of Ethereum's finality, still has time;
  - a given SP1 or RISC Zero verifier names itself the pinned version (`VERIFIER_HASH` and `VERSION` "v6.0.0";
    `SELECTOR` 0x73c457ba and `VERSION` "3.0.0");
  - the freezer and the recovery proposer are set, distinct, and not the deployer;
  - the recovery proposer is the owner's multisig: a contract, or an account that is TRON's own multisig, whose owner
    permission and every active permission able to call a contract need at least three of their keys, as the factory
    owner's Safe needs three signatures (A7-09);
  - the epoch, the cap and the floor are all given, the cap above zero, and the floor not above the cap (A7-23).
- **The source.** Before it sends anything the tool refuses a working tree that differs from its commit, and any
  `out/<Contract>.json` whose recorded sources (the compiler's keccak256 of each file, which `build.mjs` writes) differ from
  the files on disk, and it prints the commit and the compiler beside the addresses (A7-10). `--allow-dirty` lets a rehearsal
  on Nile or a local chain go ahead from a tree that differs, and the record says `"dirty": true`; mainnet never does. A
  receipt that names no result is no success, and a failed `build.mjs` shows the compiler's errors.
- **The Groth16 verifiers.** Left unset, `VAULT_SP1_VERIFIER` and `VAULT_RISC_ZERO_VERIFIER` make the script deploy the
  vendored ones itself (RISC Zero's with its published control ids) and check them the same way. A release should do
  that: a version is a name, and a contract can name itself anything, as the repository's own mocks do.
- **After deploying** it reads the wiring back, as `checkDeployment` does, and more: the vault's P1, P2, state reader,
  factory, hub template, recovery proposer, freezer, source chain, cap and floor; P1's and P2's Groth16 verifiers, keys,
  anchor, epoch and genesis time. Then it prints every address, base58 and hex, and each contract's runtime code hash
  for the release record.
- **Cost.** The whole deployment uses about 12.2 million energy on the local chain, the vault 5.2 million of it: about
  1,220 TRX at mainnet's energy fee of 100 sun, unless the deployer has staked for energy. Each transaction's fee
  limit is 1,000 TRX unless `--fee-limit` (in sun) says otherwise.
- **What the deployer keeps.** On TRON a contract's deployer, its origin, can still change who pays its energy
  (`UpdateSetting`, `UpdateEnergyLimit`) and clear its stored ABI. None of that reaches the vault's coins or rules, and
  at 100% callers pay their own energy whatever it is set to; a deployer that set it lower would pay others' energy
  itself.

`deploy-test.mjs` runs it on the local chain: each refusal above, then a whole deployment from a keystore `cast` wrote,
through the command line, with TRON's own 2-of-3 multisig as recovery proposer, and the wiring read back, including
against other parameters and with P1 and P2 swapped, which it refuses.

**On Ethereum, as for any vault chain** (the root README's deployment section has the full commands):
1. `python3 test/fixtures/tron/generate.py https://api.trongrid.io anchor anchors/tron-anchor.json` writes the anchor: the
   period in progress, its end, and its producers as their own blocks show them.
2. `script/DeployStateVerifier.s.sol`, with `STATE_CHAIN=tron` and `STATE_ANCHOR=anchors/tron-anchor.json`, deploys
   `TronStateVerifier` from it, on mainnet or Sepolia only, and refuses a period that has ended. Anyone must then
   `advance` it to a newer list within a day of the latest one's start, first by the time the script logs, or it stops
   for good.
3. `script/ConfigureChains.s.sol` proposes the chain with the entry `728126428:<vault>:<verifier>` in `CHAINS`, the
   vault being its 20-byte address without TRON's `0x41` prefix, left-padded to a word. Once the chain is registered,
   TRX follows with `728126428:0x0:<supply in sun>` in `VAULT_TOKENS`.
4. During the chain's listing delay, `DeployStateVerifier.checkTron` confirms that the verifier runs this release's
   code and started from the anchor file, and the file is compared with TRON itself: `listwitnesses` and the period's
   blocks.
