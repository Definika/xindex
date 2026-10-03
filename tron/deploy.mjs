// Deploys Xindex on TRON (Stage B spec, section 5.7): P1's verifier on SP1's Groth16 verifier, P2's on RISC Zero's, the
// state reader the snapshot exit reads Ethereum with, and the vault, linked to VaultSnapshot, all as Tron's compiler
// builds them (`build.mjs`). The twin of `script/DeployVault.s.sol`: the same checks, adapted to TRON, before anything is
// sent, and the same wiring check after. Nothing deployed is owned, and nothing can be changed afterwards but by the
// vault's own proven messages.
//
//   node deploy.mjs --network nile|mainnet|local --keystore <file> [--password-file <file>] [--dry-run] [--fee-limit <sun>]
//
// The parameters come from the environment, named as DeployVault names them:
//   VAULT_SOURCE_CHAIN_ID     The chain the indexes live on: 1, Ethereum mainnet, the default, or Sepolia (11155111). It
//                             fixes the genesis time P1 and P2 date epochs from.
//   VAULT_FACTORY             The HybridIndexFactory on that chain (an Ethereum address, 0x...).
//   VAULT_HUB_TEMPLATE        That factory's HYBRID_IMPLEMENTATION (an Ethereum address).
//   VAULT_SP1_VERIFIER        SP1's Groth16 verifier v6.0.0 on TRON, a bare verifier, never a gateway. Unset: this script
//                             deploys the vendored one (`prototype/evm/src/sp1`) and checks it the same way.
//   VAULT_RISC_ZERO_VERIFIER  RISC Zero's Groth16 verifier 3.0.0 on TRON, never its router or emergency stop. Unset: this
//                             script deploys the vendored one (`vendor/risc0-ethereum`) with its published control ids.
//   VAULT_P1_KEY, VAULT_P2_IMAGE_ID   P1's program key (`p1 vkey`) and P2's image id (`p2 image-id`).
//   VAULT_ANCHOR, VAULT_ANCHOR_EPOCH  The finalized checkpoint P1 and P2 start from (`p1-input check-state`). Each stops
//                             for good a day after its anchor's epoch began, so both are advanced daily from deployment on.
//   VAULT_FREEZER             The guardian's freeze address on TRON: it can only freeze.
//   VAULT_RECOVERY            The owner's emergency multisig on TRON: a contract, or an account whose every permission able
//                             to call a contract needs at least two of its keys (TRON's own multisig).
//   VAULT_NATIVE_CAP, VAULT_NATIVE_FLOOR  TRX's quantity cap and speed-limit floor, in sun.
//
// The deployer's key is never on the command line or in the environment: it comes from an encrypted keystore, Ethereum's
// V3 format, which `cast wallet import` writes (a TRON key is the same secp256k1 key), unlocked by a password typed at the
// prompt or read from `--password-file`. `--dry-run` runs every check and prints the plan, and sends nothing.
import { createRequire } from 'node:module';
import { createDecipheriv, pbkdf2Sync, scryptSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { encodeAbiParameters, keccak256, parseAbiParameters, toHex } from 'viem';

const require = createRequire(import.meta.url);
const { TronWeb } = require('tronweb');
const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');

/** The networks this script deploys to, and the chain id each must answer: the last 4 bytes of its genesis block id,
 *  which is TRON's `block.chainid`. A local chain's id is its own. */
export const NETWORKS = {
  mainnet: { host: 'https://api.trongrid.io', solidity: 'https://api.trongrid.io', chainId: 728126428n },
  nile: { host: 'https://nile.trongrid.io', solidity: 'https://nile.trongrid.io', chainId: 3448148188n },
  // A local java-tron serves its solidified blocks' API on a port of its own.
  local: { host: 'http://127.0.0.1:8090', solidity: 'http://127.0.0.1:8091', chainId: undefined },
};

/** SP1's Groth16 verifier v6.0.0 names itself by this hash, the circuit its proofs come from (DeployVault's). */
export const SP1_VERIFIER_HASH = '0x0e78f4db7a6771a3a6a7d9c3b0de6fe73d58781368967a7fe84d87aefffec896';
export const SP1_VERSION = 'v6.0.0';
/** RISC Zero's Groth16 verifier 3.0.0, deployed with its published control ids, names itself by this selector. */
export const RISC_ZERO_SELECTOR = '0x73c457ba';
export const RISC_ZERO_VERSION = '3.0.0';
/** The beacon chain's genesis time on Ethereum mainnet and on Sepolia, and P1's and P2's MAX_LAG. */
export const MAINNET_GENESIS_TIME = 1_606_824_023n;
export const SEPOLIA_GENESIS_TIME = 1_655_733_600n;
export const SEPOLIA = 11_155_111n;
export const VERIFIER_MAX_LAG = 86_400n;
const EPOCH_SECONDS = 384n;
/** `AccountPermissionUpdate`'s contract type for calling a contract, whose bit a permission's operations must hold. */
const TRIGGER_SMART_CONTRACT = 31;

/** A refusal, named as DeployVault's errors are. */
export class Refused extends Error {
  constructor(name, detail) {
    super(`${name}: ${detail}`);
    this.code = name;
  }
}

// ---------------------------------------------------------------------
// addresses
// ---------------------------------------------------------------------

/** A TRON address, base58 (T...) or hex (41..., or 0x and 20 bytes), as its 21-byte hex form `41...`; '' if unset. */
export function tronHex(a) {
  if (!a) return '';
  if (/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(a)) return TronWeb.address.toHex(a).toLowerCase();
  if (/^41[0-9a-fA-F]{40}$/.test(a)) return a.toLowerCase();
  if (/^0x[0-9a-fA-F]{40}$/.test(a)) return ('41' + a.slice(2)).toLowerCase();
  throw new Refused('BadAddress', a);
}
const base58 = (hex) => TronWeb.address.fromHex(hex);
const evm = (hex) => '0x' + hex.slice(2);
const ZERO32 = '0x' + '00'.repeat(32);

/** The parameters, from the environment, as DeployVault's `run` reads them. */
export function paramsFromEnv(env = process.env) {
  const bytes32 = (k) => (env[k] ? toHex(BigInt(env[k]), { size: 32 }) : ZERO32);
  return {
    sourceChainId: BigInt(env.VAULT_SOURCE_CHAIN_ID ?? '1'),
    factory: (env.VAULT_FACTORY ?? '').toLowerCase(),
    hubImplementation: (env.VAULT_HUB_TEMPLATE ?? '').toLowerCase(),
    sp1Verifier: tronHex(env.VAULT_SP1_VERIFIER),
    riscZeroVerifier: tronHex(env.VAULT_RISC_ZERO_VERIFIER),
    p1ProgramKey: bytes32('VAULT_P1_KEY'),
    p2ImageId: bytes32('VAULT_P2_IMAGE_ID'),
    anchor: bytes32('VAULT_ANCHOR'),
    anchorEpoch: BigInt(env.VAULT_ANCHOR_EPOCH ?? '0'),
    freezer: tronHex(env.VAULT_FREEZER),
    recoveryProposer: tronHex(env.VAULT_RECOVERY),
    nativeCap: BigInt(env.VAULT_NATIVE_CAP ?? '0'),
    nativeFloor: BigInt(env.VAULT_NATIVE_FLOOR ?? '0'),
  };
}

// ---------------------------------------------------------------------
// the chain, read through its HTTP API
// ---------------------------------------------------------------------

/** The network `name`'s node at `host` (the network's own unless given), checked to be that network. */
export async function connect(name, host, solidityHost) {
  const net = NETWORKS[name];
  if (!net) throw new Refused('UnknownNetwork', `${name}: choose nile, mainnet or local`);
  const url = host ?? net.host;
  const solidityUrl = solidityHost ?? (host && name !== 'local' ? host : net.solidity);
  const post = async (path, body) => {
    const r = await fetch(`${url}/wallet/${path}`, { method: 'POST', body: JSON.stringify(body) });
    if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
    return r.json();
  };
  const chainId = BigInt('0x' + (await post('getblockbynum', { num: 0 })).blockID.slice(-8));
  if (net.chainId !== undefined && chainId !== net.chainId) {
    throw new Refused('WrongNetwork', `${url} answers chain ${chainId}, not ${name}'s ${net.chainId}`);
  }
  const now = async () => BigInt((await post('getnowblock', {})).block_header.raw_data.timestamp) / 1000n;
  /** The 32-byte words a view returns, or undefined if it reverts or the address answers nothing. */
  const call = async (contract, selector, parameter = '') => {
    const r = await post('triggerconstantcontract', {
      owner_address: contract,
      contract_address: contract,
      function_selector: selector,
      parameter,
    });
    if (!r.result?.result || !r.constant_result) return undefined;
    return '0x' + r.constant_result[0];
  };
  const code = async (a) => '0x' + ((await post('getcontractinfo', { value: a })).runtimecode ?? '');
  const account = (a) => post('getaccount', { address: a });
  return { name, url, solidityUrl, chainId, now, call, code, account, post };
}

// ---------------------------------------------------------------------
// the checks, before anything is sent
// ---------------------------------------------------------------------

/** The beacon genesis time of the indexes' chain, which P1 and P2 date their anchor's epoch from. */
export function genesisTime(sourceChainId) {
  if (sourceChainId === 1n) return MAINNET_GENESIS_TIME;
  if (sourceChainId === SEPOLIA) return SEPOLIA_GENESIS_TIME;
  throw new Refused('UnknownSource', String(sourceChainId));
}

/** DeployVault's `check`: refuses the indexes' own chain, a missing address or key, an anchor P1 and P2 could no longer
 *  advance from, verifiers that are not the pinned SP1 and RISC Zero ones (when given), roles that are not what the
 *  vault assumes, and a floor above the cap. `deployer` is the 21-byte hex address that would send the deployment. */
export async function check(p, chain, deployer) {
  if (p.sourceChainId === chain.chainId) throw new Refused('SourceChain', String(chain.chainId));
  const ethAddress = (name, a) => {
    if (!/^0x[0-9a-f]{40}$/.test(a) || /^0x0{40}$/.test(a)) throw new Refused('Required', name);
  };
  ethAddress('VAULT_FACTORY', p.factory);
  ethAddress('VAULT_HUB_TEMPLATE', p.hubImplementation);
  if (p.p1ProgramKey === ZERO32) throw new Refused('Required', 'VAULT_P1_KEY');
  if (p.p2ImageId === ZERO32) throw new Refused('Required', 'VAULT_P2_IMAGE_ID');
  if (p.anchor === ZERO32) throw new Refused('Required', 'VAULT_ANCHOR');
  // LG-4: P1 and P2 refuse any proof a day after their anchor's epoch began, by TRON's clock as by Ethereum's.
  const lagEnds = genesisTime(p.sourceChainId) + p.anchorEpoch * EPOCH_SECONDS + VERIFIER_MAX_LAG;
  if ((await chain.now()) > lagEnds) throw new Refused('AnchorTooOld', `epoch ${p.anchorEpoch}, past ${lagEnds}`);
  if (p.sp1Verifier) await checkSp1(chain, p.sp1Verifier);
  if (p.riscZeroVerifier) await checkRiscZero(chain, p.riscZeroVerifier);
  await checkRoles(chain, p.freezer, p.recoveryProposer, deployer);
  if (p.nativeFloor > p.nativeCap) throw new Refused('FloorAboveCap', `${p.nativeFloor} > ${p.nativeCap}`);
}

/** Whether `contract` answers `selector` with exactly `expected`: a revert, a missing function or a short answer is a no. */
async function answers(chain, contract, selector, expected) {
  return (await chain.call(contract, selector))?.toLowerCase() === expected.toLowerCase();
}

/** Requires SP1's Groth16 verifier v6.0.0 itself: an owned gateway answers neither. */
export async function checkSp1(chain, a) {
  const hash = encodeAbiParameters(parseAbiParameters('bytes32'), [SP1_VERIFIER_HASH]);
  const version = encodeAbiParameters(parseAbiParameters('string'), [SP1_VERSION]);
  if (!(await answers(chain, a, 'VERIFIER_HASH()', hash)) || !(await answers(chain, a, 'VERSION()', version))) {
    throw new Refused('WrongVerifier', `VAULT_SP1_VERIFIER ${base58(a)}`);
  }
}

/** Requires RISC Zero's Groth16 verifier 3.0.0 with its published control ids: its router or emergency stop answers
 *  neither. */
export async function checkRiscZero(chain, a) {
  const selector = encodeAbiParameters(parseAbiParameters('bytes4'), [RISC_ZERO_SELECTOR]);
  const version = encodeAbiParameters(parseAbiParameters('string'), [RISC_ZERO_VERSION]);
  if (!(await answers(chain, a, 'SELECTOR()', selector)) || !(await answers(chain, a, 'VERSION()', version))) {
    throw new Refused('WrongVerifier', `VAULT_RISC_ZERO_VERIFIER ${base58(a)}`);
  }
}

/** Whether a TRON account is its own multisig: its owner permission, and every active permission that may call a
 *  contract, need at least two of their keys, no one key's weight reaching the threshold. An account that never set
 *  permissions has one key of weight 1 against a threshold of 1. */
export function isMultisig(account) {
  const allows = (ops, type) => ops && (parseInt(ops.slice(2 * (type >> 3), 2 * (type >> 3) + 2), 16) >> (type & 7)) & 1;
  const owner = account.owner_permission;
  if (!owner) return false;
  const perms = [owner, ...(account.active_permission ?? []).filter((p) => allows(p.operations, TRIGGER_SMART_CONTRACT))];
  return perms.every((p) => (p.keys ?? []).length >= 2 && p.keys.every((k) => (k.weight ?? 1) < (p.threshold ?? 1)));
}

/** DeployVault's `checkRoles`: a freezer and a recovery proposer that are set, distinct and not the deploying key, and a
 *  recovery proposer that is the owner's multisig, not a key: a contract, or an account that is TRON's own multisig. */
export async function checkRoles(chain, freezer, recovery, deployer) {
  if (!freezer) throw new Refused('Required', 'VAULT_FREEZER');
  if (!recovery) throw new Refused('Required', 'VAULT_RECOVERY');
  if (freezer === recovery) throw new Refused('SameRole', base58(freezer));
  if (freezer === deployer) throw new Refused('RoleIsBroadcaster', `VAULT_FREEZER ${base58(freezer)}`);
  if (recovery === deployer) throw new Refused('RoleIsBroadcaster', `VAULT_RECOVERY ${base58(recovery)}`);
  if ((await chain.code(recovery)) !== '0x') return;
  if (!isMultisig(await chain.account(recovery))) throw new Refused('RecoveryMustBeMultisig', base58(recovery));
}

// ---------------------------------------------------------------------
// the key
// ---------------------------------------------------------------------

/** The private key in an Ethereum V3 keystore (scrypt or pbkdf2, aes-128-ctr), checked by its MAC. */
export function unlock(keystore, password) {
  const c = keystore.crypto ?? keystore.Crypto;
  const p = c.kdfparams;
  const salt = Buffer.from(p.salt, 'hex');
  const dk =
    c.kdf === 'scrypt'
      ? scryptSync(password, salt, p.dklen, { N: p.n, r: p.r, p: p.p, maxmem: 256 * p.n * p.r + (1 << 20) })
      : pbkdf2Sync(password, salt, p.c, p.dklen, 'sha256');
  const ciphertext = Buffer.from(c.ciphertext, 'hex');
  if (keccak256(Buffer.concat([dk.subarray(16, 32), ciphertext])).slice(2) !== c.mac.toLowerCase()) {
    throw new Refused('WrongPassword', 'the keystore did not open');
  }
  const d = createDecipheriv(c.cipher, dk.subarray(0, 16), Buffer.from(c.cipherparams.iv, 'hex'));
  return Buffer.concat([d.update(ciphertext), d.final()]).toString('hex');
}

/** A password typed at the terminal, not echoed. */
async function prompt(question) {
  if (!process.stdin.isTTY) throw new Refused('NoPassword', 'no terminal to type it at: pass --password-file');
  const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  rl._writeToOutput = (s) => rl.output.write(s.startsWith(question) ? s : '');
  const answer = await new Promise((r) => rl.question(question, r));
  rl.close();
  process.stdout.write('\n');
  return answer;
}

// ---------------------------------------------------------------------
// deploying
// ---------------------------------------------------------------------

const art = (name) => JSON.parse(readFileSync(join(here, 'out', `${name}.json`), 'utf8'));

/** Deploys every contract, in DeployVault's order, from `key`, and returns their 21-byte hex addresses. Callers pay all
 *  energy (`consume_user_resource_percent` 100): nobody owns these contracts. Each waits for its solidified block. */
export async function deploy(p, chain, key, { feeLimit = 1_000_000_000, log = console.log } = {}) {
  const tw = new TronWeb({ fullNode: chain.url, solidityNode: chain.solidityUrl, eventServer: chain.url, privateKey: key });
  const from = tw.defaultAddress.base58;
  const sendDeploy = async (name, raw = '0x', links = {}) => {
    const a = art(name);
    let bin = a.bin;
    for (const ph of a.links) bin = bin.split(ph).join(links[ph] ?? (() => { throw new Error(`${name}: unlinked ${ph}`); })());
    const opts = { abi: a.abi, bytecode: bin, feeLimit, callValue: 0, userFeePercentage: 100, originEnergyLimit: 10_000_000 };
    if (raw !== '0x') opts.rawParameter = raw.slice(2);
    const tx = await tw.transactionBuilder.createSmartContract(opts, from);
    const sent = await tw.trx.sendRawTransaction(await tw.trx.sign(tx));
    if (!sent.result) throw new Error(`deploy ${name}: ${JSON.stringify(sent)}`);
    for (let i = 0; i < 60; i++) {
      const r = await tw.trx.getTransactionInfo(sent.txid);
      if (r && r.id) {
        if ((r.receipt?.result ?? 'SUCCESS') !== 'SUCCESS') throw new Error(`deploy ${name}: ${r.receipt?.result}`);
        const address = r.contract_address.toLowerCase();
        log(`${name.padEnd(26)} ${base58(address)}  ${evm(address)}  energy ${r.receipt.energy_usage_total ?? 0}`);
        return address;
      }
      await new Promise((ok) => setTimeout(ok, 3000));
    }
    throw new Error(`deploy ${name}: no receipt for ${sent.txid}`);
  };

  const d = {};
  d.sp1Verifier = p.sp1Verifier || (await sendDeploy('SP1Verifier'));
  if (!p.sp1Verifier) await checkSp1(chain, d.sp1Verifier);
  if (p.riscZeroVerifier) d.riscZeroVerifier = p.riscZeroVerifier;
  else {
    const ids = readFileSync(join(root, 'vendor/risc0-ethereum/src/groth16/ControlID.sol'), 'utf8');
    const controlRoot = '0x' + /CONTROL_ROOT\s*=\s*hex"([0-9a-f]+)"/.exec(ids)[1];
    const bn254 = '0x' + /BN254_CONTROL_ID\s*=\s*hex"([0-9a-f]+)"/.exec(ids)[1];
    const args = encodeAbiParameters(parseAbiParameters('bytes32, bytes32'), [controlRoot, bn254]);
    d.riscZeroVerifier = await sendDeploy('RiscZeroGroth16Verifier', args);
    await checkRiscZero(chain, d.riscZeroVerifier);
  }
  const genesis = genesisTime(p.sourceChainId);
  const verifierArgs = (zkvm, key2) =>
    encodeAbiParameters(parseAbiParameters('address, bytes32, bytes32, uint64, uint256'), [evm(zkvm), key2, p.anchor, p.anchorEpoch, genesis]);
  d.p1 = await sendDeploy('EthereumFinalityVerifier', verifierArgs(d.sp1Verifier, p.p1ProgramKey));
  d.p2 = await sendDeploy('RiscZeroFinalityVerifier', verifierArgs(d.riscZeroVerifier, p.p2ImageId));
  d.stateReader = await sendDeploy('EthereumStateReader');
  d.vaultSnapshot = await sendDeploy('VaultSnapshot');
  const config = encodeAbiParameters(
    parseAbiParameters('(uint256, address, address, address, address, address, address, address, uint256, uint256)'),
    [[p.sourceChainId, p.factory, p.hubImplementation, evm(d.p1), evm(d.p2), evm(p.freezer), evm(p.recoveryProposer), evm(d.stateReader), p.nativeCap, p.nativeFloor]],
  );
  const links = Object.fromEntries(art('XindexVault').links.map((ph) => [ph, d.vaultSnapshot.slice(2)]));
  d.vault = await sendDeploy('XindexVault', config, links);
  return d;
}

// ---------------------------------------------------------------------
// the wiring check, after
// ---------------------------------------------------------------------

/** DeployVault's `checkDeployment`: `d` is one deployment made with `p`, read back from the chain, and the runtime code
 *  hashes the release record keeps. Run it again later against the recorded addresses: equal hashes prove the code is
 *  unchanged. */
export async function checkDeployment(d, p, chain) {
  const word = async (contract, selector) => {
    const r = await chain.call(contract, selector);
    if (r === undefined) throw new Refused('WrongWiring', `${base58(contract)} does not answer ${selector}`);
    return r.toLowerCase();
  };
  const address = (a) => encodeAbiParameters(parseAbiParameters('address'), [evm(a)]).toLowerCase();
  const same = async (name, contract, selector, expected) => {
    const actual = await word(contract, selector);
    if (actual !== expected.toLowerCase()) throw new Refused('WrongWiring', `${name}: ${expected} expected, ${actual} found`);
  };
  const n = (x) => toHex(x, { size: 32 });
  await same('p1', d.vault, 'p1()', address(d.p1));
  await same('p2', d.vault, 'p2()', address(d.p2));
  await same('STATE_READER', d.vault, 'STATE_READER()', address(d.stateReader));
  await same('FACTORY', d.vault, 'FACTORY()', address('41' + p.factory.slice(2)));
  await same('HUB_IMPLEMENTATION', d.vault, 'HUB_IMPLEMENTATION()', address('41' + p.hubImplementation.slice(2)));
  await same('RECOVERY_PROPOSER', d.vault, 'RECOVERY_PROPOSER()', address(p.recoveryProposer));
  await same('freezer', d.vault, 'freezer()', address(p.freezer));
  await same('SOURCE_CHAIN_ID', d.vault, 'SOURCE_CHAIN_ID()', n(p.sourceChainId));
  await same('SP1_VERIFIER', d.p1, 'SP1_VERIFIER()', address(d.sp1Verifier));
  await same('RISC_ZERO_VERIFIER', d.p2, 'RISC_ZERO_VERIFIER()', address(d.riscZeroVerifier));
  await same('PROGRAM_KEY', d.p1, 'PROGRAM_KEY()', p.p1ProgramKey);
  await same('IMAGE_ID', d.p2, 'IMAGE_ID()', p.p2ImageId);
  for (const [name, v] of [['p1', d.p1], ['p2', d.p2]]) {
    await same(`${name} anchor`, v, 'anchor()', p.anchor);
    await same(`${name} anchorEpoch`, v, 'anchorEpoch()', n(p.anchorEpoch));
    await same(`${name} GENESIS_TIME`, v, 'GENESIS_TIME()', n(genesisTime(p.sourceChainId)));
  }
  const nativeArg = encodeAbiParameters(parseAbiParameters('address'), ['0x' + '00'.repeat(20)]).slice(2);
  const cap = (await chain.call(d.vault, 'cap(address)', nativeArg))?.toLowerCase();
  const floor = (await chain.call(d.vault, 'outflowFloor(address)', nativeArg))?.toLowerCase();
  if (cap !== n(p.nativeCap) || floor !== n(p.nativeFloor)) throw new Refused('WrongWiring', `cap ${cap}, floor ${floor}`);
  const hashes = {};
  for (const name of ['vault', 'p1', 'p2', 'stateReader', 'vaultSnapshot', 'sp1Verifier', 'riscZeroVerifier']) {
    if (!d[name]) continue;
    const code = await chain.code(d[name]);
    if (code === '0x') throw new Refused('WrongWiring', `${name} has no code`);
    hashes[name] = keccak256(code);
  }
  return hashes;
}

// ---------------------------------------------------------------------
// the command line
// ---------------------------------------------------------------------

function argsOf(argv) {
  const a = { dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--dry-run') a.dryRun = true;
    else if (['--network', '--keystore', '--password-file', '--fee-limit', '--host', '--solidity-host', '--from'].includes(k)) a[k.slice(2)] = argv[++i];
    else throw new Refused('BadArgument', k);
  }
  if (!a.network) throw new Refused('Required', '--network nile|mainnet|local');
  return a;
}

export async function main(argv = process.argv.slice(2), env = process.env) {
  const a = argsOf(argv);
  const chain = await connect(a.network, a.host, a['solidity-host']);
  const p = paramsFromEnv(env);
  let key;
  let deployer;
  if (a.dryRun && a.from) deployer = tronHex(a.from);
  else {
    if (!a.keystore) throw new Refused('Required', '--keystore');
    const keystore = JSON.parse(readFileSync(a.keystore, 'utf8'));
    const password = a['password-file'] ? readFileSync(a['password-file'], 'utf8').replace(/\r?\n$/, '') : await prompt('keystore password: ');
    key = unlock(keystore, password);
    deployer = TronWeb.address.toHex(TronWeb.address.fromPrivateKey(key)).toLowerCase();
  }
  console.log(`TRON ${a.network} (chain ${chain.chainId}) at ${chain.url}, deployer ${base58(deployer)}`);
  await check(p, chain, deployer);
  console.log('every check passed');
  if (a.dryRun) {
    console.log('dry run: would deploy',
      [!p.sp1Verifier && 'SP1Verifier (vendored)', !p.riscZeroVerifier && 'RiscZeroGroth16Verifier (vendored)',
        'EthereumFinalityVerifier (P1)', 'RiscZeroFinalityVerifier (P2)', 'EthereumStateReader', 'VaultSnapshot', 'XindexVault']
        .filter(Boolean).join(', '));
    return undefined;
  }
  const d = await deploy(p, chain, key, a['fee-limit'] ? { feeLimit: Number(a['fee-limit']) } : {});
  const hashes = await checkDeployment(d, p, chain);
  const record = Object.fromEntries(Object.entries(d).map(([k, v]) => [k, { base58: base58(v), hex: evm(v), codehash: hashes[k] }]));
  console.log(JSON.stringify({ network: a.network, chainId: String(chain.chainId), deployment: record }, null, 2));
  return d;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e.code ? `refused, ${e.message}` : e);
    process.exit(1);
  });
}
