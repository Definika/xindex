# Xindex on VeChain

VeChain runs `XindexVault` unchanged, as BNB Chain does, but its transactions are not Ethereum's (clauses, `blockRef`,
gas paid in VTHO), so `forge script` cannot send them. This folder deploys a VeChain vault from forge's own build, with
`script/DeployVault.s.sol`'s checks (`design/2026-10-04-four-chains-interfaces.md`). Only `deploy.mjs` sends anything,
and only when told which network and given a keystore.

## What a VeChain deployment runs

- `XindexVault`, linked to `VaultSnapshot`, and `EthereumStateReader`;
- P1, `EthereumFinalityVerifier`, on SP1's Groth16 verifier v6.0.0 (`prototype/evm/src/sp1`);
- P2, `RiscZeroFinalityVerifier`, on RISC Zero's Groth16 verifier 3.0.0 (`vendor/risc0-ethereum`);
- `VeChainStakerAttester`, whose `attest(table)` calls let Ethereum follow VeChain's validators without a state proof
  (`proofs/vechain`).

`VeChainStateVerifier`, on Ethereum, proves the vault's `attest` calls in blocks VIP-220 has finalized.

**Every contract's master is cleared.** VeChain gives each contract a Prototype `master`, the account that created it,
which can move the contract's VTHO, set its credit plan and users, and hand the role on; it cannot touch the contract's
VET, code or storage. The script ends the deployment with one transaction calling `Prototype.setMaster(contract, 0)` for
every contract it created, and reads each back as zero.

## What VeChain is (measured on mainnet, read-only, 4 October 2026)

- `CHAINID` returns the genesis id: `0x00000000851caf3cfdb6e899cf5958bfb1ac3413d346d43539627e6be7ec1b4a` on mainnet,
  `0x000000000b2bce3c70bc649a02749e8687721b09ed2e15997f466536b20bb127` on testnet (a simulated creation returning
  `CHAINID`). The vault compares every message's destination with it, and the registry id is that number.
- Cancun's opcodes run (PUSH0, MCOPY, TLOAD and TSTORE), and Osaka's CLZ, so forge's Cancun build runs as compiled.
- The BN254 precompiles sit at 0x06 to 0x08 at EIP-1108's prices: `ecAdd` 150, `ecMul` 6,000, a pairing of two 113,000.
- The code limit is 24,576 bytes (EIP-170); since INTERSTELLAR (block 25,902,540) a transaction holds at most 16,777,216
  gas (EIP-7825); a block, 40,000,000. The base fee was 10^13 wei of VTHO a gas.

`simulate.mjs` ran the whole deployment in one batch of the node's read-only call simulation on mainnet's state:

| Step | Gas | Runtime code |
|---|---:|---:|
| SP1's Groth16 verifier | 1,619,906 | 5,883 bytes |
| RISC Zero's Groth16 verifier | 1,701,298 | 5,082 bytes |
| P1, `EthereumFinalityVerifier` | 2,027,073 | 7,228 bytes |
| P2, `RiscZeroFinalityVerifier` | 2,043,823 | 7,284 bytes |
| `EthereumStateReader` | 1,177,567 | 4,197 bytes |
| `VaultSnapshot` | 871,666 | 3,082 bytes |
| `XindexVault` | 6,558,383 | 23,760 bytes |
| `VeChainStakerAttester` | 354,903 | 1,143 bytes |
| `Prototype.setMaster(contract, 0)`, each | 6,515 | |
| SP1's verifier on SP1's own v6 proof (a changed public value reverts) | 225,904 | |
| RISC Zero's verifier on its own v3.0 receipt (another journal reverts) | 233,818 | |
| `VeChainStakerAttester.attest`, the Staker's table of 101 validators (another reverts) | 731,827 | |

Each transaction fits EIP-7825's cap and each contract the code limit, the vault with 816 bytes to spare. The whole
deployment is about 16.4 million gas: about 164 VTHO at that base fee.

## Deploying

```bash
npm install                # @vechain/sdk-core 2.1.0, exactly, from the lockfile
npm run build              # forge build, and the two vendored Groth16 verifiers into vechain/out/
npm run simulate           # the whole deployment, simulated read-only on mainnet; or `node simulate.mjs testnet`
npm run deploy-test        # deploy.mjs against a node faked in-process: every refusal, a dry run, a whole deployment

VAULT_FACTORY=0x... VAULT_HUB_TEMPLATE=0x... VAULT_P1_KEY=0x... VAULT_P2_IMAGE_ID=0x... \
VAULT_ANCHOR=0x... VAULT_ANCHOR_EPOCH=... VAULT_FREEZER=0x... VAULT_RECOVERY=0x... \
VAULT_NATIVE_CAP=<wei> VAULT_NATIVE_FLOOR=<wei> \
node deploy.mjs --network testnet --keystore ~/.foundry/keystores/deployer [--dry-run --from 0x...]
```

- **The parameters** are DeployVault's, by the same names (the file's header lists them).
- **The key** never appears on the command line or in the environment. It is an Ethereum V3 keystore, the format `cast
  wallet import` writes, since a VeChain key is the same secp256k1 key, unlocked by a password typed at the prompt or
  read from `--password-file`. `--dry-run --from <address>` needs no keystore and sends nothing.
- **The network** is named, never defaulted: `mainnet`, `testnet` or `solo`; the script refuses a node whose genesis id
  is not that network's. `--host` points at another node.
- **Before sending anything** it makes every check `DeployVault.check` makes:
  - the indexes' chain is mainnet Ethereum or Sepolia, and not this one;
  - the factory, the hub template, P1's key, P2's image id and the anchor are set;
  - P1 and P2 could still advance from the anchor: VeChain's clock is within a day of its epoch's start (LG-4);
  - a given SP1 or RISC Zero verifier names itself the pinned version (`VERIFIER_HASH` and `VERSION` "v6.0.0";
    `SELECTOR` 0x73c457ba and `VERSION` "3.0.0");
  - the freezer and the recovery proposer are set, distinct, and not the deployer;
  - the recovery proposer is a contract, and not an EIP-7702 delegated key: the owner's multisig;
  - the floor is not above the cap.

  Then it runs the whole deployment, masters cleared, in the node's read-only simulation from the deployer's address,
  and refuses any step that reverts, needs more than 16,777,216 gas or leaves a master set; and, unless a dry run,
  a deployer holding less VTHO than twice the base fee would charge.
- **The Groth16 verifiers.** Left unset, `VAULT_SP1_VERIFIER` and `VAULT_RISC_ZERO_VERIFIER` make the script deploy the
  vendored ones itself (RISC Zero's with its published control ids) and check them the same way, as `tron/deploy.mjs`
  does. Neither exists on VeChain today.
- **Sending.** One transaction a contract, each simulated first, its gas the simulation's plus a fifth, its fee twice the
  base fee plus the node's suggested priority fee; each must not revert. Then one transaction of clauses clears every
  master.
- **After deploying** it reads the wiring back, as `checkDeployment` does, and more: the vault's P1, P2, state reader,
  factory, hub template, recovery proposer, freezer, source chain, cap and floor; P1's and P2's Groth16 verifiers, keys,
  anchor, epoch and genesis time; each verifier's name; the attester's Staker; every master zero. Then it prints every
  address and each contract's runtime code hash for the release record.

`deploy-test.mjs` signs with the secp256k1 scalar 1, a well-known test key, against a node faked in-process: every
transaction is decoded by the SDK and checked, and nothing reaches a network.

**On Ethereum, as for any vault chain:**
1. `python3 proofs/vechain/fixtures/generate.py anchor vechain-anchor.json` writes the anchor: the latest finalized
   checkpoint's id and time, and the Staker's table there. Choose it after the vault and the attester are deployed: the
   verifier proves only blocks after its anchor, so a call to their addresses before they had code proves nothing.
2. `script/DeployStateVerifier.s.sol` deploys `VeChainStateVerifier(sp1Verifier, programKey, chainId, vault, attester,
   id, time, table)` from it. Anyone must then `update` it within a day of the anchor's time, and every day after, or it
   stops for good: each update needs a transaction of `VeChainStakerAttester.attest(table)` in the round it proves.
3. `script/ConfigureChains.s.sol` proposes the chain under its genesis id as a number, with the vault's address,
   left-padded to a word, and the verifier; once registered, VET follows in wei.
