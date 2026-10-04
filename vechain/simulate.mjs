// Measures a VeChain deployment without sending anything: the whole of it, in one batch of clauses, in a node's read-only
// call simulation (`POST /accounts/*`) on the best block's state, from an address that holds no key:
//   - every contract `deploy.mjs` sends, built by `build.mjs`, its gas against EIP-7825's 16,777,216 a transaction and
//     its code against the 24,576-byte limit;
//   - each master cleared by `Prototype.setMaster(contract, 0)`, and read back as zero;
//   - SP1's Groth16 verifier on SP1's own v6 proof, and RISC Zero's on its own v3.0 receipt, on VeChain's BN254
//     precompiles, each refusing a tampered input;
//   - VeChainStakerAttester on the real Staker: its table, `attest` of it, and `attest` of another, which reverts.
// A batch stops at its first revert, so each refusal runs in a batch of its own, after deploying what it calls.
//
//   node simulate.mjs [mainnet|testnet] [--host <url>]
//
// The deployment's parameters are DeployVault's, from the environment when set, else placeholders: the simulation
// shows the code runs and what it costs, not a release.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  MAX_TX_GAS, PROTOTYPE, Refused, call, connect, contractAddress, genesisTime, intrinsicGas, paramsFromEnv, plan,
} from './deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const ZERO32 = '0x' + '00'.repeat(32);
const placeholder = (n) => '0x' + n.toString(16).padStart(40, '0');
const word = (n) => '0x' + BigInt(n).toString(16).padStart(64, '0');

/** A constant `name` from a vendored test file: `hex"..."` or `bytes32(0x...)`. */
function constant(path, name) {
  const t = readFileSync(join(root, path), 'utf8');
  const m = new RegExp(`${name}\\s*=\\s*(?:hex"([0-9a-f]*)"|bytes32\\(0x([0-9a-f]{64})\\))`).exec(t);
  return '0x' + (m[1] ?? m[2]);
}

/** DeployVault's parameters from the environment, placeholders for any unset. */
function parameters(env, now) {
  const p = paramsFromEnv(env, true);
  p.factory ||= placeholder(0xfac);
  p.hubImplementation ||= placeholder(0x7e3);
  if (p.p1ProgramKey === ZERO32) p.p1ProgramKey = word(1);
  if (p.p2ImageId === ZERO32) p.p2ImageId = word(2);
  if (p.anchor === ZERO32) p.anchor = word(3);
  if (p.anchorEpoch === 0n) p.anchorEpoch = (now - genesisTime(p.sourceChainId)) / 384n;
  p.freezer ||= placeholder(0xf4e);
  p.recoveryProposer ||= placeholder(0x4ec);
  if (p.nativeCap === 0n) p.nativeCap = 10n ** 27n;
  if (p.nativeFloor === 0n) p.nativeFloor = 10n ** 24n;
  return p;
}

export async function measure(network = 'mainnet', host, env = process.env, fetchImpl = globalThis.fetch, log = console.log) {
  const chain = await connect(network, host, fetchImpl);
  const p = parameters(env, await chain.now());
  const from = placeholder(0xde9);

  const addresses = {};
  const steps = plan(p, (name) => addresses[name]);
  steps.forEach((s, i) => { addresses[s.name] = contractAddress(ZERO32, i); });
  const created = steps.map((s) => ({ to: null, value: '0x0', data: s.data() }));
  const creation = Object.fromEntries(steps.map((s, i) => [s.name, created[i]]));

  // The checks that must succeed, after the deployment, in its batch.
  const checks = [];
  const check = (label, to, data) => checks.push({ label, clause: { to, value: '0x0', data } });
  for (const a of Object.values(addresses)) check(`setMaster(${a}, 0)`, PROTOTYPE, call('setMaster(address,address)', [a, '0x' + '00'.repeat(20)]));
  for (const a of Object.values(addresses)) check(`master(${a}) reads zero`, PROTOTYPE, call('master(address) view returns (address)', [a]));
  // The refusals, each in a batch of its own: the contract it calls deployed first, at clause 0's address.
  const refusals = [];
  const refusal = (label, name, data) => refusals.push({ label, name, data });

  // SP1's own proof, vendored with its verifier's test (prototype/evm/test/SP1VerifierGroth16V6.t.sol).
  const sp1Test = 'prototype/evm/test/SP1VerifierGroth16V6.t.sol';
  const [vkey, values, proof] = ['PROGRAM_VKEY', 'PUBLIC_VALUES', 'PROOF_BYTES'].map((n) => constant(sp1Test, n));
  const sp1Call = (pv) => call('verifyProof(bytes32,bytes,bytes) view', [vkey, pv, proof]);
  if (addresses.SP1Verifier) {
    check('SP1 Groth16 verifyProof, SP1\'s own v6 proof', addresses.SP1Verifier, sp1Call(values));
    refusal('SP1 Groth16 verifyProof, a public value changed', 'SP1Verifier', sp1Call(values.slice(0, -1) + (values.endsWith('0') ? '1' : '0')));
  }
  // RISC Zero's own v3.0 receipt (vendor/risc0-ethereum/test/TestReceiptV3_0.sol).
  const r0Test = 'vendor/risc0-ethereum/test/TestReceiptV3_0.sol';
  const [seal, journal, image] = ['SEAL', 'JOURNAL', 'IMAGE_ID'].map((n) => constant(r0Test, n));
  const digest = (j) => '0x' + createHash('sha256').update(Buffer.from(j.slice(2), 'hex')).digest('hex');
  const r0Call = (d) => call('verify(bytes,bytes32,bytes32) view', [seal, image, d]);
  if (addresses.RiscZeroGroth16Verifier) {
    check('RISC Zero Groth16 verify, its own v3.0 receipt', addresses.RiscZeroGroth16Verifier, r0Call(digest(journal)));
    refusal('RISC Zero Groth16 verify, another journal', 'RiscZeroGroth16Verifier', r0Call(digest('0x00')));
  }
  // The attester on the real Staker: its table first, then `attest` of it, and of another.
  const [tableOut] = await chain.inspect([creation.VeChainStakerAttester, { to: contractAddress(ZERO32, 0), value: '0x0', data: call('currentTable() view returns (bytes32)') }], from).then((o) => o.slice(1));
  if (!tableOut || tableOut.reverted) throw new Refused('SimulationFailed', 'the attester gave no table');
  const table = tableOut.data;
  check('VeChainStakerAttester.attest, the Staker\'s table', addresses.VeChainStakerAttester, call('attest(bytes32) view', [table]));
  refusal('VeChainStakerAttester.attest, another table', 'VeChainStakerAttester', call('attest(bytes32) view', [word(BigInt(table) ^ 1n)]));

  const out = await chain.inspect([...created, ...checks.map((c) => c.clause)], from);
  const rows = [];
  let failures = 0;
  const labels = [...steps.map((s) => `deploy ${s.name}`), ...checks.map((c) => c.label)];
  const clauses = [...created, ...checks.map((c) => c.clause)];
  labels.forEach((label, i) => {
    const r = out[i];
    if (!r) {
      rows.push({ label, ok: false, note: 'not run: an earlier clause reverted' });
      failures++;
      return;
    }
    const create = clauses[i].to === null;
    const gas = BigInt(r.gasUsed) + (create ? intrinsicGas([clauses[i]]) : 0n);
    const size = create ? (r.data.length - 2) / 2 : undefined;
    let ok = !r.reverted;
    if (label.startsWith('master(')) ok &&= BigInt(r.data) === 0n;
    if (create) ok &&= gas <= MAX_TX_GAS && size <= 24_576;
    if (!ok) failures++;
    rows.push({ label, gas, size, ok, note: r.reverted ? `reverted: ${r.vmError}` : '' });
  });
  for (const f of refusals) {
    const o = await chain.inspect([creation[f.name], { to: contractAddress(ZERO32, 0), value: '0x0', data: f.data }], from);
    const ok = !o[0].reverted && o[1]?.reverted === true;
    if (!ok) failures++;
    rows.push({ label: f.label, gas: o[1] ? BigInt(o[1].gasUsed) : undefined, ok, note: o[1]?.reverted ? 'reverted, as it must' : 'did not revert' });
  }

  const best = await chain.best();
  log(`VeChain ${network}, block ${best.number} (${best.id}), base fee ${BigInt(best.baseFeePerGas)} wei a gas, block gas limit ${best.gasLimit}`);
  for (const r of rows) {
    const gas = r.gas === undefined ? '' : `gas ${String(r.gas).padStart(9)}`;
    const size = r.size === undefined ? '' : `  code ${String(r.size).padStart(6)} bytes`;
    log(`${r.ok ? 'ok  ' : 'FAIL'} ${r.label.padEnd(64)} ${gas}${size}${r.note ? `  ${r.note}` : ''}`);
  }
  log(`the attester's table: ${table}`);
  if (failures) throw new Refused('SimulationFailed', `${failures} step(s)`);
  return rows;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const hostAt = args.indexOf('--host');
  const host = hostAt >= 0 ? args[hostAt + 1] : undefined;
  const network = args.find((a, i) => !a.startsWith('--') && (hostAt < 0 || i !== hostAt + 1)) ?? 'mainnet';
  measure(network, host).catch((e) => {
    console.error(e.code ? `refused, ${e.message}` : e);
    process.exit(1);
  });
}
