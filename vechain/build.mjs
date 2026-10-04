// Builds what a VeChain deployment sends, with forge, from the repository's own sources: VeChain runs Cancun's EVM
// (PUSH0, MCOPY and transient storage measured on mainnet), so forge's build of `src/` is what VeChain runs.
//   - `out/`: the repository's contracts, `forge build` with foundry.toml's settings: P1, P2, the state reader, the
//     vault and its linked VaultSnapshot, and VeChainStakerAttester;
//   - `vechain/out/sp1/`: SP1's Groth16 verifier v6.0.0, vendored in `prototype/evm/src/sp1`, which needs via-IR;
//   - `vechain/out/risc0/`: RISC Zero's Groth16 verifier 3.0.0, vendored in `vendor/risc0-ethereum`.
// Neither verifier exists on VeChain yet; `deploy.mjs` deploys them when not given, and checks them either way.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const forge = (args) => execFileSync('forge', args, { cwd: root, stdio: ['ignore', 'inherit', 'inherit'] });

forge(['build']);
forge(['build', 'prototype/evm/src/sp1/SP1VerifierGroth16.sol', '--via-ir',
  '--out', 'vechain/out/sp1', '--cache-path', 'vechain/cache/sp1']);
forge(['build', 'vendor/risc0-ethereum/src/groth16/RiscZeroGroth16Verifier.sol',
  '--remappings', 'openzeppelin/=lib/openzeppelin-contracts/', '--out', 'vechain/out/risc0', '--cache-path', 'vechain/cache/risc0']);

for (const [path, name] of [
  ['out/XindexVault.sol/XindexVault.json', 'XindexVault'],
  ['out/VeChainStakerAttester.sol/VeChainStakerAttester.json', 'VeChainStakerAttester'],
  ['vechain/out/sp1/SP1VerifierGroth16.sol/SP1Verifier.json', 'SP1Verifier'],
  ['vechain/out/risc0/RiscZeroGroth16Verifier.sol/RiscZeroGroth16Verifier.json', 'RiscZeroGroth16Verifier'],
]) {
  const a = JSON.parse(readFileSync(join(root, path), 'utf8'));
  const runtime = (a.deployedBytecode.object.length - 2) / 2;
  console.log(`${name.padEnd(24)} runtime ${String(runtime).padStart(6)} bytes${runtime > 24_576 ? ' (past the 24,576-byte limit)' : ''}`);
}
