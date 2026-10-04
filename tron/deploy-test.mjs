// Rehearses `deploy.mjs` on the local chain `node.mjs` configures: every refusal DeployVault makes, adapted to TRON, then
// a whole deployment from a Foundry keystore through the command line, and its wiring read back. Exits non-zero on any
// failure. Needs `build.mjs`, a running node and Foundry's `cast`, which writes the keystore as a deployer's would.
import { execFileSync, spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { keccak256, toHex } from 'viem';
import {
  MAINNET_GENESIS_TIME, MIN_ANCHOR_SLACK, assertFresh, check, checkDeployment, checkPasswordFile, connect, isMultisig,
  paramsFromEnv, requireCleanTree, sourceRecord, staleSources, tronHex, unlock,
} from './deploy.mjs';

const require = createRequire(import.meta.url);
const { TronWeb } = require('tronweb');
const here = dirname(fileURLToPath(import.meta.url));
const w = JSON.parse(readFileSync(join(here, 'node/witness.json'), 'utf8'));
const HOST = process.env.TRON_NODE ?? 'http://127.0.0.1:8090';
const tw = new TronWeb({ fullHost: HOST, privateKey: w.privateKey });
const chain = await connect('local', HOST);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
let failed = false;
const pass = (label) => results.push(['ok', label]);
const fail = (label, why) => {
  failed = true;
  results.push(['FAIL', `${label}: ${why}`]);
};

/** Expects `fn` to be refused with DeployVault's error `code`. */
async function refused(label, code, fn) {
  try {
    await fn();
    fail(label, `not refused, expected ${code}`);
  } catch (e) {
    if (e.code === code) pass(`${label}: ${code}`);
    else fail(label, `expected ${code}, got ${e.code ?? e.message}`);
  }
}
async function accepted(label, fn) {
  try {
    await fn();
    pass(label);
  } catch (e) {
    fail(label, e.message);
  }
}

async function mined(txid) {
  for (let i = 0; i < 40; i++) {
    const r = await tw.trx.getUnconfirmedTransactionInfo(txid);
    if (r && r.id) return r;
    await sleep(1500);
  }
  throw new Error(`no receipt for ${txid}`);
}
const fund = async (to, sun) => mined((await tw.trx.sendTransaction(to, sun)).txid);
const art = (name) => JSON.parse(readFileSync(join(here, 'out', `${name}.json`), 'utf8'));
async function deployByWitness(name, raw) {
  const a = art(name);
  const opts = { abi: a.abi, bytecode: a.bin, feeLimit: 1_000_000_000, callValue: 0, userFeePercentage: 100, originEnergyLimit: 10_000_000 };
  if (raw) opts.rawParameter = raw.slice(2);
  const tx = await tw.transactionBuilder.createSmartContract(opts, w.tron);
  const i = await mined((await tw.trx.sendRawTransaction(await tw.trx.sign(tx))).txid);
  return i.contract_address.toLowerCase();
}

/** A funded account whose owner permission, and active permission `opsOneKey` if given, are set as described. */
async function account({ ownerThreshold, ownerKeys, activeThreshold, activeKeys }) {
  const acct = tw.utils.accounts.generateAccount();
  await fund(acct.address.base58, 2_000_000_000);
  const keys = (n) => Array.from({ length: n }, () => tw.utils.accounts.generateAccount().address.base58);
  const owner = { type: 0, permission_name: 'owner', threshold: ownerThreshold, keys: keys(ownerKeys).map((address) => ({ address, weight: 1 })) };
  // Transfers (type 1) and calling a contract (type 31), the operation the recovery proposer's call needs.
  const ops = '02000080' + '00'.repeat(28);
  const active = [{ type: 2, permission_name: 'active', threshold: activeThreshold, operations: ops, keys: keys(activeKeys).map((address) => ({ address, weight: 1 })) }];
  const own = new TronWeb({ fullHost: HOST, privateKey: acct.privateKey });
  const tx = await own.transactionBuilder.updateAccountPermissions(acct.address.base58, owner, null, active);
  const r = await own.trx.sendRawTransaction(await own.trx.sign(tx));
  if (!r.result) throw new Error(`permissions: ${JSON.stringify(r)}`);
  await mined(r.txid);
  return acct.address.hex.toLowerCase();
}

// --- the cast: a deployer from a Foundry keystore, a freezer, and the recovery proposers -------------------------------
const ks = join(here, 'node', `ks-${Date.now()}`);
mkdirSync(ks, { recursive: true });
const passwordFile = join(ks, 'password');
// Readable by its owner alone, as `deploy.mjs` requires of a password file (A7-21).
writeFileSync(passwordFile, 'a throwaway password\n', { mode: 0o600 });
const cast = spawnSync('cast', ['wallet', 'new', ks, '--unsafe-password', 'a throwaway password'], { encoding: 'utf8' });
const castOut = cast.stdout + cast.stderr;
const castAddress = /Address:\s+(0x[0-9a-fA-F]{40})/.exec(castOut)[1];
const keystoreFile = join(ks, readdirSync(ks).find((f) => f !== 'password'));
const keystore = JSON.parse(readFileSync(keystoreFile, 'utf8'));
const deployer = tronHex(castAddress);
await fund(TronWeb.address.fromHex(deployer), 50_000_000_000);
await accepted('the Foundry keystore opens to the address cast reported', async () => {
  const key = unlock(keystore, 'a throwaway password');
  if (TronWeb.address.toHex(TronWeb.address.fromPrivateKey(key)).toLowerCase() !== deployer) throw new Error('another key');
});
await refused('a wrong password', 'WrongPassword', async () => unlock(keystore, 'not it'));

const freezer = tronHex(tw.utils.accounts.generateAccount().address.base58);
const contractRecovery = await deployByWitness('MockEventVerifier');
// TRON's own multisig needs three of its keys, as the factory owner's Safe needs three signatures (A7-09).
const multisig = await account({ ownerThreshold: 3, ownerKeys: 5, activeThreshold: 3, activeKeys: 5 });
const twoOfThree = await account({ ownerThreshold: 2, ownerKeys: 3, activeThreshold: 2, activeKeys: 3 });
const weak = await account({ ownerThreshold: 3, ownerKeys: 5, activeThreshold: 1, activeKeys: 1 });
const single = await account({ ownerThreshold: 1, ownerKeys: 1, activeThreshold: 1, activeKeys: 1 });
const plainKey = tronHex(tw.utils.accounts.generateAccount().address.base58);
await fund(TronWeb.address.fromHex(plainKey), 10_000_000);
await accepted("TRON's multisig reads as one, a single key and a weak active permission do not", async () => {
  if (!isMultisig(await chain.account(multisig))) throw new Error('3-of-5 not a multisig');
  if (isMultisig(await chain.account(twoOfThree))) throw new Error('2-of-3 passed: two keys sign for it');
  if (isMultisig(await chain.account(weak))) throw new Error('an active permission of one key passed');
  if (isMultisig(await chain.account(single))) throw new Error('one key passed');
  if (isMultisig(await chain.account(plainKey))) throw new Error('a plain account passed');
});

// --- the checks, before anything is sent ---------------------------------------------------------------------------
const epochNow = async () => ((await chain.now()) - MAINNET_GENESIS_TIME) / 384n;
const base = async () => ({
  sourceChainId: 1n,
  factory: '0x' + 'f1'.repeat(20),
  hubImplementation: '0x' + 'ab'.repeat(20),
  sp1Verifier: '',
  riscZeroVerifier: '',
  p1ProgramKey: keccak256(toHex('P1')),
  p2ImageId: keccak256(toHex('P2')),
  anchor: keccak256(toHex('a finalized checkpoint')),
  anchorEpoch: await epochNow(),
  freezer,
  recoveryProposer: contractRecovery,
  nativeCap: 1_000_000_000_000n,
  nativeFloor: 1_000_000n,
});
const with_ = async (change) => ({ ...(await base()), ...change });
const ZERO32 = '0x' + '00'.repeat(32);

await accepted('the parameters pass, with a contract as recovery proposer', async () => check(await base(), chain, deployer));
await accepted("and with TRON's own 3-of-5 multisig", async () => check(await with_({ recoveryProposer: multisig }), chain, deployer));
await accepted('and on Sepolia', async () => check(await with_({ sourceChainId: 11_155_111n, anchorEpoch: ((await chain.now()) - 1_655_733_600n) / 384n }), chain, deployer));
await refused("the indexes' own chain", 'SourceChain', async () => check(await with_({ sourceChainId: chain.chainId }), chain, deployer));
await refused('another source chain', 'UnknownSource', async () => check(await with_({ sourceChainId: 17_000n }), chain, deployer));
for (const [name, change] of [
  ['VAULT_FACTORY', { factory: '0x' + '00'.repeat(20) }],
  ['VAULT_HUB_TEMPLATE', { hubImplementation: '' }],
  ['VAULT_P1_KEY', { p1ProgramKey: ZERO32 }],
  ['VAULT_P2_IMAGE_ID', { p2ImageId: ZERO32 }],
  ['VAULT_ANCHOR', { anchor: ZERO32 }],
  ['VAULT_FREEZER', { freezer: '' }],
  ['VAULT_RECOVERY', { recoveryProposer: '' }],
]) {
  await refused(`${name} missing`, 'Required', async () => check(await with_(change), chain, deployer));
}
// LG-4 and A7-07: lagEnds = genesis + epoch * 384 + a day, and 12 hours of it must be left: an anchor 111 epochs back
// (about 11.8 hours) still has them, one 113 back (12.05 hours) has not.
await accepted('an anchor 111 epochs old (A7-07)', async () => check(await with_({ anchorEpoch: (await epochNow()) - 111n }), chain, deployer));
await refused('an anchor 113 epochs old (A7-07)', 'AnchorTooOld', async () => check(await with_({ anchorEpoch: (await epochNow()) - 113n }), chain, deployer));
await refused('an anchor 226 epochs old (LG-4)', 'AnchorTooOld', async () => check(await with_({ anchorEpoch: (await epochNow()) - 226n }), chain, deployer));
if (MIN_ANCHOR_SLACK !== 43_200n) throw new Error('the slack is 12 hours');

const ids = readFileSync(join(here, '..', 'vendor/risc0-ethereum/src/groth16/ControlID.sol'), 'utf8');
const controlRoot = '0x' + /CONTROL_ROOT\s*=\s*hex"([0-9a-f]+)"/.exec(ids)[1];
const bn254 = '0x' + /BN254_CONTROL_ID\s*=\s*hex"([0-9a-f]+)"/.exec(ids)[1];
const { encodeAbiParameters, parseAbiParameters } = await import('viem');
const sp1 = await deployByWitness('SP1Verifier');
const r0 = await deployByWitness('RiscZeroGroth16Verifier', encodeAbiParameters(parseAbiParameters('bytes32, bytes32'), [controlRoot, bn254]));
const mockSp1 = await deployByWitness('MockSP1Verifier');
const mockR0 = await deployByWitness('MockRiscZeroVerifier');
await accepted('the vendored SP1 and RISC Zero verifiers name themselves as pinned', async () => check(await with_({ sp1Verifier: sp1, riscZeroVerifier: r0 }), chain, deployer));
// The repository's mocks name themselves as the pinned verifiers do, as DeployVault's tests need: a name is no proof of
// code, so a release leaves both addresses unset and this script deploys the vendored verifiers itself.
await accepted("a contract that names itself SP1's passes the name check, as on the EVM", async () => check(await with_({ sp1Verifier: mockSp1, riscZeroVerifier: mockR0 }), chain, deployer));
await refused('another contract as SP1 verifier', 'WrongVerifier', async () => check(await with_({ sp1Verifier: contractRecovery }), chain, deployer));
await refused('an account as SP1 verifier', 'WrongVerifier', async () => check(await with_({ sp1Verifier: plainKey }), chain, deployer));
await refused("RISC Zero's place taken by SP1's verifier", 'WrongVerifier', async () => check(await with_({ riscZeroVerifier: sp1 }), chain, deployer));
await refused('another contract as RISC Zero verifier', 'WrongVerifier', async () => check(await with_({ riscZeroVerifier: contractRecovery }), chain, deployer));

await refused('one account as freezer and recovery', 'SameRole', async () => check(await with_({ recoveryProposer: freezer }), chain, deployer));
await refused('the deployer as freezer', 'RoleIsBroadcaster', async () => check(await with_({ freezer: deployer }), chain, deployer));
await refused('the deployer as recovery', 'RoleIsBroadcaster', async () => check(await with_({ recoveryProposer: deployer }), chain, deployer));
await refused('a plain key as recovery', 'RecoveryMustBeMultisig', async () => check(await with_({ recoveryProposer: plainKey }), chain, deployer));
await refused('an account of one key as recovery', 'RecoveryMustBeMultisig', async () => check(await with_({ recoveryProposer: single }), chain, deployer));
await refused('a multisig whose active permission one key holds', 'RecoveryMustBeMultisig', async () => check(await with_({ recoveryProposer: weak }), chain, deployer));
await refused('a floor above the cap', 'FloorAboveCap', async () => check(await with_({ nativeFloor: 2_000_000_000_000n }), chain, deployer));
await refused('a native cap of zero (A7-23)', 'Required', async () => check(await with_({ nativeCap: 0n, nativeFloor: 0n }), chain, deployer));
await refused('a 2-of-3 account as recovery (A7-09)', 'RecoveryMustBeMultisig', async () => check(await with_({ recoveryProposer: twoOfThree }), chain, deployer));

// A7-23: the epoch, the cap and the floor are required, as DeployVault requires them.
{
  const env0 = { VAULT_ANCHOR_EPOCH: '1', VAULT_NATIVE_CAP: '2', VAULT_NATIVE_FLOOR: '1' };
  paramsFromEnv(env0);
  for (const k of Object.keys(env0)) {
    const without = { ...env0 };
    delete without[k];
    await refused(`${k} unset`, 'Required', async () => paramsFromEnv(without));
    await refused(`${k} empty`, 'Required', async () => paramsFromEnv({ ...env0, [k]: '' }));
  }
}

// A7-10: a tree that differs, or a build from other sources, is refused before anything is sent.
await accepted('the commit and whether the tree differs come from git', async () => {
  const git = (answers) => (args) => answers[args.join(' ')];
  const clean = sourceRecord(git({ 'rev-parse HEAD': 'abc123\n', 'status --porcelain': '' }));
  const dirty = sourceRecord(git({ 'rev-parse HEAD': 'abc123\n', 'status --porcelain': ' M src/vault/XindexVault.sol\n' }));
  if (clean.commit !== 'abc123' || clean.dirty || !dirty.dirty) throw new Error(JSON.stringify([clean, dirty]));
});
await accepted('without a git checkout nothing can be said of the source', async () => {
  try {
    sourceRecord(() => {
      throw new Error('not a git repository');
    });
    throw new Error('not refused');
  } catch (e) {
    if (e.code !== 'NoGit') throw e;
  }
});
const dirtyTree = { commit: 'abc123', dirty: true };
await refused('a tree that differs on mainnet', 'DirtyTree', async () => requireCleanTree({ network: 'mainnet', allowDirty: false }, dirtyTree));
await refused('--allow-dirty on mainnet, whatever the tree', 'DirtyTree', async () => requireCleanTree({ network: 'mainnet', allowDirty: true }, { commit: 'abc123', dirty: false }));
await refused('a tree that differs on a rehearsal network without --allow-dirty', 'DirtyTree', async () => requireCleanTree({ network: 'nile', allowDirty: false }, dirtyTree));
await accepted('a rehearsal from a tree that differs with --allow-dirty, and a clean tree anywhere', async () => {
  requireCleanTree({ network: 'nile', allowDirty: true }, dirtyTree);
  requireCleanTree({ network: 'mainnet', allowDirty: false }, { commit: 'abc123', dirty: false });
});
await accepted('a build output is stale when a source changed, is gone, or none is recorded', async () => {
  const a = { compiler: '0.8.28+commit.7893614a', sources: { 'src/A.sol': keccak256(toHex('a')), 'src/B.sol': '0x00' } };
  const disk = { 'src/A.sol': 'a', 'src/B.sol': 'b' };
  const read = (p) => { if (!(p in disk)) throw new Error('gone'); return Buffer.from(disk[p]); };
  if (JSON.stringify(staleSources(a, read)) !== '["src/B.sol"]') throw new Error('B differs');
  if (staleSources({}, read).length !== 1 || staleSources({ sources: {} }, read).length !== 1) throw new Error('none recorded');
  delete disk['src/A.sol'];
  if (staleSources(a, read).length !== 2) throw new Error('a source that is gone is stale');
  disk['src/A.sol'] = 'a';
  const fresh = { compiler: '0.8.28+commit.7893614a', sources: { 'src/A.sol': keccak256(toHex('a')) } };
  if (assertFresh(['XindexVault'], () => fresh, read) !== '0.8.28+commit.7893614a') throw new Error('the compiler is recorded');
  try {
    assertFresh(['XindexVault'], () => a, read);
    throw new Error('not refused');
  } catch (e) {
    if (e.code !== 'StaleBuild' || !e.message.includes('XindexVault') || !e.message.includes('src/B.sol')) throw e;
  }
});
await accepted('the real build output is current', async () => {
  const names = ['SP1Verifier', 'RiscZeroGroth16Verifier', 'EthereumFinalityVerifier', 'RiscZeroFinalityVerifier', 'EthereumStateReader', 'VaultSnapshot', 'XindexVault'];
  if (!assertFresh(names)) throw new Error('no compiler recorded');
});

// A7-21: a password file that group or others can read is refused.
await accepted('a password file of mode 600 passes and one of 640 or 644 does not', async () => {
  checkPasswordFile('x', () => ({ mode: 0o100600 }));
  for (const mode of [0o100640, 0o100644, 0o100604, 0o100660]) {
    try {
      checkPasswordFile('x', () => ({ mode }));
      throw new Error(`mode ${mode.toString(8)} passed`);
    } catch (e) {
      if (e.code !== 'PasswordFileReadable') throw e;
    }
  }
});
await accepted('the real password file written above is readable by its owner alone', async () => checkPasswordFile(passwordFile));
await refused("Nile's name on this chain", 'WrongNetwork', async () => connect('nile', HOST));
await refused("mainnet's name on this chain", 'WrongNetwork', async () => connect('mainnet', HOST));

// --- a whole deployment, through the command line --------------------------------------------------------------------
const p = await with_({ recoveryProposer: multisig });
const env = {
  ...process.env,
  VAULT_SOURCE_CHAIN_ID: '1',
  VAULT_FACTORY: p.factory,
  VAULT_HUB_TEMPLATE: p.hubImplementation,
  VAULT_P1_KEY: p.p1ProgramKey,
  VAULT_P2_IMAGE_ID: p.p2ImageId,
  VAULT_ANCHOR: p.anchor,
  VAULT_ANCHOR_EPOCH: String(p.anchorEpoch),
  VAULT_FREEZER: TronWeb.address.fromHex(freezer),
  VAULT_RECOVERY: TronWeb.address.fromHex(multisig),
  VAULT_NATIVE_CAP: String(p.nativeCap),
  VAULT_NATIVE_FLOOR: String(p.nativeFloor),
};
const run = (args) => execFileSync('node', [join(here, 'deploy.mjs'), ...args], { env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
await accepted('a dry run checks and sends nothing', async () => {
  const out = run(['--network', 'local', '--dry-run', '--from', TronWeb.address.fromHex(deployer)]);
  if (!/every check passed/.test(out) || !/dry run: would deploy/.test(out)) throw new Error(out);
});
await refused('no network named', 'Exit', async () => {
  try {
    run(['--keystore', keystoreFile, '--password-file', passwordFile]);
  } catch (e) {
    if (/--network/.test(String(e.stderr))) throw Object.assign(new Error('refused'), { code: 'Exit' });
    throw e;
  }
});
let d;
await accepted('the deployment, from the keystore, with the vendored verifiers', async () => {
  // A rehearsal on the local chain from a tree that may differ, which the record then says.
  const out = run(['--network', 'local', '--keystore', keystoreFile, '--password-file', passwordFile, '--allow-dirty']);
  const record = JSON.parse(out.slice(out.indexOf('\n{') + 1));
  if (!/^[0-9a-f]{40}$/.test(record.commit) || typeof record.dirty !== 'boolean' || !/^0\.8\.28/.test(record.compiler)) throw new Error('the record names no commit or compiler');
  d = Object.fromEntries(Object.entries(record.deployment).map(([k, v]) => [k, '41' + v.hex.slice(2)]));
  for (const [k, v] of Object.entries(record.deployment)) results.push(['  ', `${k.padEnd(17)} ${v.base58}  ${v.codehash}`]);
});
if (d) {
  await accepted('its wiring reads back', async () => checkDeployment(d, p, chain));
  await refused('a deployment read against other parameters', 'WrongWiring', async () => checkDeployment(d, { ...p, factory: '0x' + 'f2'.repeat(20) }, chain));
  await refused('P1 and P2 swapped', 'WrongWiring', async () => checkDeployment({ ...d, p1: d.p2, p2: d.p1 }, p, chain));
}

for (const [s, l] of results) console.log(`${s.padEnd(4)} ${l}`);
console.log(failed ? '\nFAIL' : '\nPASS: every refusal of DeployVault, adapted to TRON, and a whole deployment');
process.exit(failed ? 1 : 0);
