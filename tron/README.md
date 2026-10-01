# Xindex on TRON

TRON holds a vault like any EVM chain, with differences that only TRON's own compiler and VM show. This folder builds
the contracts a TRON deployment uses with Tron's compiler and runs them on TRON's VM, on a local single-node chain of
the pinned java-tron release. Nothing here talks to a TRON network. Stage B spec, section 5.7, records the results.

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
  github.com/tronprotocol/java-tron/releases and adoptium.net.

```bash
npm install
npm run build              # out/<Contract>.json, built by tron-solc
npm run node-config        # node/private.conf and a throwaway witness key, node/witness.json (git-ignored)
cd node && java -Xmx3g -jar FullNode-aarch64.jar --witness -c private.conf &   # a local chain, blocks every 3 s
cd .. && npm run rehearse  # every step below, as mined transactions; exits non-zero on any failure
```

The node config is java-tron's own `config.conf` at the pinned release, with one witness, no peers
(`minEffectiveConnection = 0`, without which java-tron refuses every transaction), TRON mainnet's VM switches on
(read from mainnet's `getchainparameters` on 1 October 2026), and a 90-second maintenance. The rehearsal first raises
the chain's CPU limit from java-tron's default of 50 ms to mainnet's 80 ms, by a proposal its one witness approves.

## What the rehearsal shows (1 October 2026, Apple Silicon)

| Step, as a mined transaction | Energy |
|---|---:|
| SP1's Groth16 verifier on SP1's own proof (a wrong input reverts) | 217,950 |
| RISC Zero's Groth16 verifier on RISC Zero's v3.0 receipt (a wrong journal reverts) | 222,908 |
| P1's or P2's `update` (the SNARK check mocked) | about 50,800 |
| P1's or P2's `verifyEvent` on a real mainnet receipt | 51,955 to 74,606 |
| The vault: `registerIndex`, by Ethereum's CREATE2 formula | 43,847 |
| The vault: a 10 TRX deposit | 163,556 |
| The vault: `attest` of the intake (a wrong value reverts) | 1,164 |
| The vault: `INTAKE_SETTLED` | 152,905 |
| The vault: a `BURN` paying 1 TRX to a new account | 211,956 |

Every step passes within mainnet's 80 ms. So a P1 or P2 `update` costs about 270,000 energy, and a delivery, with
both `verifyEvent`s, about 330,000 to 360,000.

**The CPU limit is the constraint, not energy.** TRON bounds each transaction by elapsed CPU time, 80 ms on mainnet
(chain parameter 13), and a transaction past it fails `OUT_OF_TIME` and burns its whole fee limit. The BN254 pairing
of a Groth16 check, which java-tron computes in Java, takes about 40 ms here for its four pairs (timed by calling
java-tron's precompile directly). At 80 ms every run passed; at java-tron's default 50 ms the first pairing of a
freshly started node, or one under load, did not. A block producer slower than this machine narrows the margin. So:
- whoever sends `update` on TRON sets its fee limit near its energy, about 300,000, so a timed-out attempt costs
  little, and sends again;
- the margin is measured again on Nile, TRON's test network, before mainnet.

**Other differences that matter, none of which needs a code change:**
- Tron's compiler makes the vault 25,360 bytes, past Ethereum's 24,576. TRON has no such limit: java-tron charges 200
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
