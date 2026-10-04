// Runs the Xindex contracts on TRON's VM, on the local chain `node.mjs` configures, each step a mined transaction under
// the chain's per-transaction CPU limit, and prints the energy of each. Exits non-zero on any failure. Needs `build.mjs`
// first. Offline: every proof comes from the repository's fixtures.
//
//   1. SP1's and RISC Zero's Groth16 verifiers on their own real proofs: the BN254 pairing at the core of P1 and P2.
//   2. P1's and P2's verifiers proving three real mainnet receipts (test/fixtures/ethereum/receipts.json) under a
//      recorded headers root; the SNARK check there is the repository's mock, which accepts exactly those values. A
//      verifier whose anchor is more than a day old refuses the same proof (LG-4).
//   3. The vault end to end: register an index by Ethereum's CREATE2 formula, deposit TRX, attest the intake, settle it,
//      and pay a burn to a new account. Its two proofs are MockEventVerifier, so what is measured is the vault.
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { concat, encodeAbiParameters, keccak256, pad, parseAbiParameters, sha256, toHex } from 'viem';

const require = createRequire(import.meta.url);
const { TronWeb } = require('tronweb');
const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const w = JSON.parse(readFileSync(join(here, 'node/witness.json'), 'utf8'));
const tw = new TronWeb({ fullHost: process.env.TRON_NODE ?? 'http://127.0.0.1:8090', privateKey: w.privateKey });
const art = (name) => JSON.parse(readFileSync(join(here, 'out', `${name}.json`), 'utf8'));
const FEE = 1_000_000_000; // a local chain's maximum fee limit, 1,000 TRX
const TRANSACTED = ['verifyProof', 'verify', 'verifyEvent', 'attest'];
const rows = [];
let failed = false;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const evmOf = (tronAddr) => '0x' + tw.address.toHex(tronAddr).slice(2);

async function info(txid) {
  for (let i = 0; i < 40; i++) {
    const r = await tw.trx.getUnconfirmedTransactionInfo(txid);
    if (r && r.id) return r;
    await sleep(1500);
  }
  throw new Error(`no receipt for ${txid}`);
}

/** Deploys `name` (its bin linked to `links`), with raw abi-encoded constructor arguments. */
async function deploy(name, raw, links = {}) {
  const a = art(name);
  let bin = a.bin;
  for (const ph of a.links) bin = bin.split(ph).join(links[ph] ?? (() => { throw new Error(`${name}: unlinked ${ph}`); })());
  // The uploaded ABI marks the views measured here as non-view: for a view, TRON's triggersmartcontract simulates the call
  // before building the transaction, on a node whose JIT may be cold, and that simulation is not what a block runs. In
  // production nothing calls these views by transaction but `attest`, which costs 1,164 energy; P1's and P2's Groth16
  // check runs inside `update`, which is no view.
  const abi = a.abi.map((e) => (e.stateMutability === 'view' && TRANSACTED.includes(e.name) ? { ...e, stateMutability: 'nonpayable' } : e));
  const opts = { abi, bytecode: bin, feeLimit: FEE, callValue: 0, userFeePercentage: 100, originEnergyLimit: 10_000_000 };
  if (raw) opts.rawParameter = raw.slice(2);
  const i = await info((await tw.trx.sendRawTransaction(await tw.trx.sign(await tw.transactionBuilder.createSmartContract(opts, w.tron)))).txid);
  if (i.receipt.result !== 'SUCCESS') throw new Error(`deploy ${name}: ${i.receipt.result}`);
  return tw.address.fromHex(i.contract_address);
}

/** Sends `sig(params)` as a mined transaction and records it; `expect` is SUCCESS or REVERT. A view is sent as a
 *  transaction too, which TRON allows once Constantinople is on: the CPU limit applies only to mined transactions. */
async function send(label, addr, sig, params, { value = 0, expect = 'SUCCESS' } = {}) {
  const r = await tw.transactionBuilder.triggerSmartContract(addr, sig, { feeLimit: FEE, callValue: value }, params, w.tron);
  const i = await info((await tw.trx.sendRawTransaction(await tw.trx.sign(r.transaction))).txid);
  const result = i.receipt.result ?? 'SUCCESS';
  const ok = result === expect;
  failed ||= !ok;
  rows.push([label, i.receipt.energy_usage_total ?? 0, result + (ok ? '' : `, expected ${expect}`)]);
  return i;
}

const b = (v) => ({ type: 'bytes', value: v });
const b32 = (v) => ({ type: 'bytes32', value: v });

// --- the chain -------------------------------------------------------------------------------------------------------
// A private chain starts with java-tron's default CPU limit, 50 ms; mainnet's is 80 (chain parameter 13). The rehearsal
// sets mainnet's by a proposal its one witness approves, which applies at the next maintenance.
const MAINNET_CPU_MS = 80;
const chainParams = async () => Object.fromEntries((await tw.trx.getChainParameters()).map((p) => [p.key, p.value]));
let params = await chainParams();
if (params.getMaxCpuTimeOfOneTx !== MAINNET_CPU_MS && !process.env.KEEP_CPU_LIMIT) {
  const created = await tw.trx.sendRawTransaction(await tw.trx.sign(await tw.transactionBuilder.createProposal([{ key: 13, value: MAINNET_CPU_MS }], w.tron)));
  await info(created.txid).catch(() => {});
  const proposals = await tw.trx.listProposals();
  const id = Math.max(...proposals.map((p) => p.proposal_id ?? 0));
  await tw.trx.sendRawTransaction(await tw.trx.sign(await tw.transactionBuilder.voteProposal(id, true, w.tron)));
  console.log(`proposal ${id}: CPU limit ${params.getMaxCpuTimeOfOneTx} -> ${MAINNET_CPU_MS} ms, applied at the next maintenance`);
  for (let i = 0; i < 80 && params.getMaxCpuTimeOfOneTx !== MAINNET_CPU_MS; i++) {
    await sleep(5000);
    params = await chainParams();
  }
}
const cpu = params.getMaxCpuTimeOfOneTx;
const chainid = BigInt('0x' + (await tw.trx.getBlockByNumber(0)).blockID.slice(-8));
console.log(`TRON local chain: CPU limit ${cpu} ms a transaction (mainnet 80), Cancun ${params.getAllowTvmCancun}, chain id ${chainid}`);

// --- 1. the Groth16 checks ---------------------------------------------------------------------------------------------
// A node that has just started runs the pairing before its JIT has compiled it, and on this measure a cold first
// pairing exceeds a 50 ms limit while a warm one fits. A producing node has long been warm, so each check is first
// sent until it succeeds, up to five times, and only the runs after that are asserted.
async function warm(label, addr, sig, params) {
  for (let i = 1; i <= 5; i++) {
    const r = await tw.transactionBuilder.triggerSmartContract(addr, sig, { feeLimit: FEE }, params, w.tron);
    const x = await info((await tw.trx.sendRawTransaction(await tw.trx.sign(r.transaction))).txid);
    if ((x.receipt.result ?? 'SUCCESS') === 'SUCCESS') return rows.push([`${label}: warm after ${i} run(s)`, 0, 'warm-up']);
  }
  failed = true;
  rows.push([`${label}: never warm`, 0, 'OUT_OF_TIME five times']);
}
{
  const t = readFileSync(join(root, 'prototype/evm/test/SP1VerifierGroth16V6.t.sol'), 'utf8');
  const vkey = /PROGRAM_VKEY\s*=\s*bytes32\((0x[0-9a-fA-F]{64})\)/.exec(t)[1];
  const pv = '0x' + /PUBLIC_VALUES\s*=\s*hex"([0-9a-f]*)"/.exec(t)[1];
  const proof = '0x' + /PROOF_BYTES\s*=\s*hex"([0-9a-f]*)"/.exec(t)[1];
  const sp1 = await deploy('SP1Verifier');
  await warm('SP1 Groth16', sp1, 'verifyProof(bytes32,bytes,bytes)', [b32(vkey), b(pv), b(proof)]);
  await send('SP1 Groth16 verifyProof (real proof)', sp1, 'verifyProof(bytes32,bytes,bytes)', [b32(vkey), b(pv), b(proof)]);
  await send('SP1 Groth16, other public values', sp1, 'verifyProof(bytes32,bytes,bytes)', [b32(vkey), b(pv.slice(0, -2) + '00'), b(proof)], { expect: 'REVERT' });
}
{
  const c = readFileSync(join(root, 'vendor/risc0-ethereum/src/groth16/ControlID.sol'), 'utf8');
  const controlRoot = '0x' + /CONTROL_ROOT\s*=\s*hex"([0-9a-f]+)"/.exec(c)[1];
  const bn254 = '0x' + /BN254_CONTROL_ID\s*=\s*hex"([0-9a-f]+)"/.exec(c)[1];
  const t = readFileSync(join(root, 'vendor/risc0-ethereum/test/TestReceiptV3_0.sol'), 'utf8');
  const seal = '0x' + /SEAL\s*=\s*\n?\s*hex"([0-9a-f]+)"/.exec(t)[1];
  const journal = '0x' + /JOURNAL\s*=\s*hex"([0-9a-f]*)"/.exec(t)[1];
  const image = '0x' + /IMAGE_ID\s*=\s*hex"([0-9a-f]+)"/.exec(t)[1];
  const r0 = await deploy('RiscZeroGroth16Verifier', encodeAbiParameters(parseAbiParameters('bytes32, bytes32'), [controlRoot, bn254]));
  await warm('RISC Zero Groth16', r0, 'verify(bytes,bytes32,bytes32)', [b(seal), b32(image), b32(sha256(journal))]);
  await send('RISC Zero Groth16 verify (real receipt)', r0, 'verify(bytes,bytes32,bytes32)', [b(seal), b32(image), b32(sha256(journal))]);
  await send('RISC Zero Groth16, another journal', r0, 'verify(bytes,bytes32,bytes32)', [b(seal), b32(image), b32(sha256('0x00'))], { expect: 'REVERT' });
}

// --- 2. P1's and P2's verifiers on real receipts -----------------------------------------------------------------------
{
  const f = JSON.parse(readFileSync(join(root, 'test/fixtures/ethereum/receipts.json'), 'utf8'));
  const KEY = keccak256(toHex('the program'));
  const ANCHOR = keccak256(toHex('an anchor'));
  // Mainnet's beacon genesis, and the epoch in progress: a verifier takes a proof only within a day of its anchor's.
  const GENESIS = 1_606_824_023n;
  const EPOCH = (BigInt(Math.floor(Date.now() / 1000)) - GENESIS) / 384n;
  // One block, recorded alone: its leaf is the headers root and its path is empty.
  const leaf = keccak256(encodeAbiParameters(parseAbiParameters('uint256, uint256, bytes32, bytes32'), [BigInt(f.number), BigInt(f.timestamp), f.stateRoot, f.receiptsRoot]));
  const pv = encodeAbiParameters(parseAbiParameters('bytes32, bytes32, uint64, bytes32, uint64, uint64'), [ANCHOR, keccak256(toHex('next')), EPOCH + 1n, leaf, BigInt(f.number), BigInt(f.number)]);
  const header = [leaf, BigInt(f.number), BigInt(f.timestamp), f.stateRoot, f.receiptsRoot, []];
  for (const [label, verifierName, mockName, seal] of [
    ['P1', 'EthereumFinalityVerifier', 'MockSP1Verifier', (m) => m.prove(KEY, pv).call()],
    ['P2', 'RiscZeroFinalityVerifier', 'MockRiscZeroVerifier', (m) => m.prove(KEY, pv).call()],
  ]) {
    const mock = await deploy(mockName);
    const v = await deploy(verifierName, encodeAbiParameters(parseAbiParameters('address, bytes32, bytes32, uint64, uint256'), [evmOf(mock), KEY, ANCHOR, EPOCH, GENESIS]));
    const proof = await seal(await tw.contract(art(mockName).abi, mock));
    // LG-4: the same proof, to a verifier whose anchor's epoch began more than a day ago (300 epochs, 32 hours): refused.
    const stale = await deploy(verifierName, encodeAbiParameters(parseAbiParameters('address, bytes32, bytes32, uint64, uint256'), [evmOf(mock), KEY, ANCHOR, EPOCH - 300n, GENESIS]));
    await send(`${label} update, anchor a day old (LG-4)`, stale, 'update(bytes,bytes)', [b(pv), b(proof)], { expect: 'REVERT' });
    await send(`${label} update (SNARK mocked)`, v, 'update(bytes,bytes)', [b(pv), b(proof)]);
    for (const [k, c] of f.cases.entries()) {
      const ev = encodeAbiParameters(parseAbiParameters('(bytes32, uint64, uint64, bytes32, bytes32, bytes32[]), bytes[], uint256, uint256'), [header, c.proof, BigInt(c.txIndex), BigInt(c.logIndex)]);
      await send(`${label} verifyEvent, real receipt ${k} (tx ${c.txIndex})`, v, 'verifyEvent(bytes)', [b(ev)]);
    }
  }
}

// --- 3. the vault end to end ------------------------------------------------------------------------------------------
{
  const snapshot = await deploy('VaultSnapshot');
  const reader = await deploy('EthereumStateReader');
  const p1 = await deploy('MockEventVerifier');
  const p2 = await deploy('MockEventVerifier');
  const FACTORY = '0x' + 'f1'.repeat(20); // an Ethereum address: the factory the indexes come from
  const HUB = '0x' + 'ab'.repeat(20); // the HybridHub template it clones
  const SOURCE = 1n; // Ethereum
  const config = encodeAbiParameters(
    parseAbiParameters('(uint256, address, address, address, address, address, address, address, uint256, uint256)'),
    [[SOURCE, FACTORY, HUB, evmOf(p1), evmOf(p2), w.evm, w.evm, evmOf(reader), 1_000_000_000_000n, 1_000_000n]],
  );
  const links = Object.fromEntries(art('XindexVault').links.map((ph) => [ph, tw.address.toHex(snapshot).slice(2)]));
  const vault = await deploy('XindexVault', config, links);

  const salt = keccak256(toHex('xindex on tron'));
  const initcode = concat(['0x3d602d80600a3d3981f3363d3d373d3d3d363d73', HUB, '0x5af43d82803e903d91602b57fd5bf3']);
  const index = '0x' + keccak256(concat(['0xff', FACTORY, salt, keccak256(initcode)])).slice(26);
  const addr = (a) => ({ type: 'address', value: '41' + a.slice(2) });
  await send('vault registerIndex (Ethereum CREATE2)', vault, 'registerIndex(address,bytes32)', [addr(index), b32(salt)]);

  const intakeId = ((BigInt(Math.floor(Date.now() / 1000)) + 3600n) << 192n) | 1n;
  await send('vault deposit 10 TRX', vault, 'deposit(address,uint256)', [addr(index), { type: 'uint256', value: intakeId.toString() }], { value: 10_000_000 });
  const v = await tw.contract(art('XindexVault').abi, vault);
  const digest = await v.intakeDigest('41' + index.slice(2), intakeId.toString()).call();
  const slot = keccak256(encodeAbiParameters(parseAbiParameters('uint256, bytes32'), [intakeId, keccak256(encodeAbiParameters(parseAbiParameters('address, uint256'), [index, 15n]))]));
  await send('vault attest the intake', vault, 'attest(bytes32[],bytes32[])', [{ type: 'bytes32[]', value: [slot] }, { type: 'bytes32[]', value: [digest] }]);
  await send('vault attest, another value', vault, 'attest(bytes32[],bytes32[])', [{ type: 'bytes32[]', value: [slot] }, { type: 'bytes32[]', value: [pad('0x01')] }], { expect: 'REVERT' });

  const DOMAIN = keccak256(toHex('xindex.v4.vault-message'));
  const TOPIC = keccak256(toHex('VaultMessage(bytes32,bytes)'));
  let nonce = 0n;
  const message = (kind, body) => {
    const payload = encodeAbiParameters(parseAbiParameters('bytes32, uint256, uint8, uint256, bytes32, address, uint256, bytes'), [DOMAIN, SOURCE, kind, chainid, pad(evmOf(vault)), index, ++nonce, body]);
    return encodeAbiParameters(parseAbiParameters('address, bytes32, bytes32, bytes'), [index, TOPIC, keccak256(payload), encodeAbiParameters(parseAbiParameters('bytes'), [payload])]);
  };
  const settle = message(2, encodeAbiParameters(parseAbiParameters('uint256'), [intakeId]));
  await send('vault deliver INTAKE_SETTLED', vault, 'deliver(bytes,bytes)', [b(settle), b(settle)]);
  const fresh = TronWeb.createRandom();
  const PAY = 1_000_000; // 1 TRX, within the floor, so paid at once
  const burn = message(1, encodeAbiParameters(parseAbiParameters('bytes32, uint256, bytes32'), [pad('0x00'), BigInt(PAY), pad(evmOf(fresh.address))]));
  await send('vault deliver BURN to a new account', vault, 'deliver(bytes,bytes)', [b(burn), b(burn)]);
  const paid = await tw.trx.getUnconfirmedBalance(fresh.address);
  if (paid !== PAY) failed = true;
  rows.push(['the burn recipient was paid', 0, `${paid} sun`]);
}

console.log('\n' + 'step'.padEnd(46) + 'energy'.padStart(10) + '   result');
for (const [l, e, r] of rows) console.log(l.padEnd(46) + String(e).padStart(10) + '   ' + r);
console.log(failed ? '\nFAIL' : `\nPASS: every step ran on TRON's VM within its ${cpu} ms CPU limit`);
process.exit(failed ? 1 : 0);
