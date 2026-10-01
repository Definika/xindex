// Builds the contracts a TRON vault deployment uses with Tron's own compiler, tron-solc 0.8.28 (`tv_0.8.28`), which is
// what TRON runs: the vault and its linked VaultSnapshot, the state reader, P1's and P2's verifiers, SP1's and RISC
// Zero's Groth16 verifiers, and the test doubles the rehearsal uses. Writes out/<Contract>.json ({ abi, bin }).
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir, platform } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const solc = process.env.TRON_SOLC ?? join(homedir(), '.local/tron-solc/0.8.28', platform() === 'darwin' ? 'solc-macos' : 'solc-static-linux');
// The release's published SHA-256 (github.com/tronprotocol/solidity/releases/tag/tv_0.8.28, shasum.txt).
const SHA256 = {
  'solc-macos': 'e492e14fd3da07e65830c1189758ac34f8a3f06c3f59df42f5c5f6a744e0dbd2',
  'solc-static-linux': '0eba121b08e9fbc1019e71bb6d36467a7f653929af9f51a793a17688d859f856',
};
const digest = createHash('sha256').update(readFileSync(solc)).digest('hex');
if (!Object.values(SHA256).includes(digest)) throw new Error(`${solc} is not tron-solc tv_0.8.28 (sha256 ${digest})`);

const SOURCES = [
  'src/vault/XindexVault.sol',
  'src/verifiers/EthereumStateReader.sol',
  'src/verifiers/EthereumFinalityVerifier.sol',
  'src/verifiers/RiscZeroFinalityVerifier.sol',
  'prototype/evm/src/sp1/SP1VerifierGroth16.sol',
  'vendor/risc0-ethereum/src/groth16/RiscZeroGroth16Verifier.sol',
  'test/mocks/MockEventVerifier.sol',
  'test/mocks/MockSP1Verifier.sol',
  'test/mocks/MockRiscZeroVerifier.sol',
];
const WANTED = ['XindexVault', 'VaultSnapshot', 'EthereumStateReader', 'EthereumFinalityVerifier', 'RiscZeroFinalityVerifier', 'SP1Verifier', 'RiscZeroGroth16Verifier', 'MockEventVerifier', 'MockSP1Verifier', 'MockRiscZeroVerifier'];

const out = execFileSync(
  solc,
  [
    '@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/',
    'openzeppelin/=lib/openzeppelin-contracts/',
    '--base-path', '.', '--allow-paths', '.,lib',
    '--optimize', '--optimize-runs', '1000', '--evm-version', 'cancun',
    '--combined-json', 'abi,bin', ...SOURCES,
  ],
  { cwd: root, encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'ignore'] },
);
const contracts = JSON.parse(out).contracts;
mkdirSync(join(here, 'out'), { recursive: true });
for (const [key, c] of Object.entries(contracts)) {
  const name = key.split(':').pop();
  if (!WANTED.includes(name) || !c.bin) continue;
  const abi = typeof c.abi === 'string' ? JSON.parse(c.abi) : c.abi;
  // A linked library's place in the bytecode: `__$<34 hex>$__`, one per library it calls.
  const links = [...new Set(c.bin.match(/__\$[0-9a-f]{34}\$__/g) ?? [])];
  writeFileSync(join(here, 'out', `${name}.json`), JSON.stringify({ source: key, abi, bin: c.bin, links }));
  console.log(`${name.padEnd(26)} ${String(c.bin.length / 2).padStart(6)} bytes${links.length ? ' (links VaultSnapshot)' : ''}`);
}
