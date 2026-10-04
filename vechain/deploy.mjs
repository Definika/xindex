// Deploys Xindex on VeChain (`design/2026-10-04-four-chains-interfaces.md`): P1's verifier on SP1's Groth16 verifier,
// P2's on RISC Zero's, the state reader the snapshot exit reads Ethereum with, the vault, linked to VaultSnapshot, and
// VeChainStakerAttester, whose calls let Ethereum follow VeChain's validators, all from forge's build (`build.mjs`). The
// twin of `script/DeployVault.s.sol`: the same checks before anything is sent, and the same wiring check after. VeChain
// gives every contract a Prototype `master`, its deployer, which can move the contract's VTHO and sponsor its users; the
// script clears each one (`Prototype.setMaster(contract, 0)`) and checks that it reads zero. Nothing deployed is then
// owned, and nothing can be changed afterwards but by the vault's own proven messages.
//
//   node deploy.mjs --network mainnet|testnet|solo --keystore <file> [--password-file <file>] [--host <url>] [--allow-dirty]
//   node deploy.mjs --network mainnet --dry-run --from <address>
//
// Before anything is sent the tool refuses a working tree that differs from its commit, and any build output that was
// compiled from other sources than the ones on disk (`npm run build` makes them), and it records the commit and the
// compiler beside the addresses. `--allow-dirty` lets a rehearsal on a testnet or solo node go ahead from a tree that
// differs, and says so in the record; a deployment on mainnet never does.
//
// The parameters come from the environment, named as DeployVault names them:
//   VAULT_SOURCE_CHAIN_ID     The chain the indexes live on: 1, Ethereum mainnet, the default, or Sepolia (11155111). It
//                             fixes the genesis time P1 and P2 date epochs from.
//   VAULT_FACTORY             The HybridIndexFactory on that chain.
//   VAULT_HUB_TEMPLATE        That factory's HYBRID_IMPLEMENTATION.
//   VAULT_SP1_VERIFIER        SP1's Groth16 verifier v6.0.0 on VeChain, a bare verifier, never a gateway. Unset: this script
//                             deploys the vendored one (`prototype/evm/src/sp1`) and checks it the same way.
//   VAULT_RISC_ZERO_VERIFIER  RISC Zero's Groth16 verifier 3.0.0 on VeChain, never its router or emergency stop. Unset: this
//                             script deploys the vendored one (`vendor/risc0-ethereum`) with its published control ids.
//   VAULT_P1_KEY, VAULT_P2_IMAGE_ID   P1's program key (`p1 vkey`) and P2's image id (`p2 image-id`).
//   VAULT_ANCHOR, VAULT_ANCHOR_EPOCH  The finalized checkpoint P1 and P2 start from (`p1-input check-state`), both
//                             required. Each stops for good a day after its anchor's epoch began, so both are advanced daily
//                             from deployment on, and an anchor with less than 12 hours of that day left is refused.
//   VAULT_FREEZER             The guardian's freeze address on VeChain: it can only freeze.
//   VAULT_RECOVERY            The owner's emergency multisig on VeChain: a Safe that needs at least three signatures, has
//                             no enabled module and counts neither the freezer nor the deployer among its signers.
//   VAULT_RECOVERY_IS_NOT_A_SAFE_ACK  Optional, `true` to accept a recovery multisig that is not a Safe, on a chain that has
//                             none: the operator's word that it needs at least three keys.
//   VAULT_NATIVE_CAP, VAULT_NATIVE_FLOOR  VET's quantity cap, above zero, and speed-limit floor, in wei; both required.
//
// The deployer's key is never on the command line or in the environment: it comes from an encrypted keystore, Ethereum's
// V3 format, which `cast wallet import` writes (a VeChain key is the same secp256k1 key), unlocked by a password typed at
// the prompt or read from `--password-file`. `--dry-run` runs every check, then the whole deployment in the node's
// read-only call simulation from the deployer's address, and sends nothing.
import { execFileSync } from 'node:child_process';
import { createDecipheriv, pbkdf2Sync, randomBytes, scryptSync } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { ABI, ABIFunction, Address, HexUInt, Keccak256, Secp256k1, Transaction } from '@vechain/sdk-core';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');

/** The networks this script deploys to, each by its genesis id, which VeChain's `CHAINID` returns: the vault compares
 *  every message's destination with it, and the factory registers the chain under it. A solo node's is its own. */
export const NETWORKS = {
  mainnet: { host: 'https://mainnet.vechain.org', genesis: '0x00000000851caf3cfdb6e899cf5958bfb1ac3413d346d43539627e6be7ec1b4a' },
  testnet: { host: 'https://testnet.vechain.org', genesis: '0x000000000b2bce3c70bc649a02749e8687721b09ed2e15997f466536b20bb127' },
  solo: { host: 'http://127.0.0.1:8669', genesis: undefined },
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
/** How much of P1's and P2's day an anchor must still have left (DeployVault's MIN_ANCHOR_SLACK): the first advance
 *  needs two proofs of finality, which take hours, and a verifier that stops first is an immutable of the vault. */
export const MIN_ANCHOR_SLACK = 43_200n;
/** Fewest signatures the recovery multisig may need, the factory owner's. */
export const MIN_RECOVERY_THRESHOLD = 3n;
const EPOCH_SECONDS = 384n;
/** A builtin contract's address: its name in ASCII, left-padded to 20 bytes (`thor.BytesToAddress`). */
const builtin = (name) => '0x' + Buffer.from(name).toString('hex').padStart(40, '0');
/** VeChain's builtin Prototype, which keeps every account's master. */
export const PROTOTYPE = builtin('Prototype');
/** VeChain's builtin Staker, which VeChainStakerAttester reads. */
export const STAKER = builtin('Staker');
/** EIP-7825's per-transaction gas cap, which VeChain applies since INTERSTELLAR (block 25,902,540 on mainnet). */
export const MAX_TX_GAS = 16_777_216n;
const ZERO_ADDRESS = '0x' + '00'.repeat(20);
const ZERO32 = '0x' + '00'.repeat(32);

/** A refusal, named as DeployVault's errors are. */
export class Refused extends Error {
  constructor(name, detail) {
    super(`${name}: ${detail}`);
    this.code = name;
  }
}

// ---------------------------------------------------------------------
// encoding
// ---------------------------------------------------------------------

const fn = (signature) => new ABIFunction(`function ${signature}`);
export const call = (signature, args = []) => fn(signature).encodeData(args).toString();
export const encode = (types, values) => ABI.of(types, values).toHex().toString();
const word = (x) => '0x' + BigInt(x).toString(16).padStart(64, '0');
const addressWord = (a) => '0x' + a.slice(2).toLowerCase().padStart(64, '0');

/** An EVM address, `0x` and 20 bytes, lowercased; '' if unset. */
export function evmAddress(a) {
  if (!a) return '';
  if (!/^0x[0-9a-fA-F]{40}$/.test(a)) throw new Refused('BadAddress', a);
  return a.toLowerCase();
}

/** The parameters, from the environment, as DeployVault's `run` reads them: the epoch, the cap and the floor are
 *  required, as `vm.envUint` requires them there, since an unset cap would deploy a vault that refuses every deposit.
 *  `simulate.mjs` measures a deployment with placeholders, and passes `lenient` to read any of them as zero. */
export function paramsFromEnv(env = process.env, lenient = false) {
  const bytes32 = (k) => (env[k] ? word(env[k]) : ZERO32);
  const need = (k) => {
    if (env[k] === undefined || env[k] === '') {
      if (lenient) return 0n;
      throw new Refused('Required', k);
    }
    return BigInt(env[k]);
  };
  return {
    sourceChainId: BigInt(env.VAULT_SOURCE_CHAIN_ID ?? '1'),
    factory: evmAddress(env.VAULT_FACTORY),
    hubImplementation: evmAddress(env.VAULT_HUB_TEMPLATE),
    sp1Verifier: evmAddress(env.VAULT_SP1_VERIFIER),
    riscZeroVerifier: evmAddress(env.VAULT_RISC_ZERO_VERIFIER),
    p1ProgramKey: bytes32('VAULT_P1_KEY'),
    p2ImageId: bytes32('VAULT_P2_IMAGE_ID'),
    anchor: bytes32('VAULT_ANCHOR'),
    anchorEpoch: need('VAULT_ANCHOR_EPOCH'),
    freezer: evmAddress(env.VAULT_FREEZER),
    recoveryProposer: evmAddress(env.VAULT_RECOVERY),
    recoveryIsNotASafe: env.VAULT_RECOVERY_IS_NOT_A_SAFE_ACK === 'true',
    nativeCap: need('VAULT_NATIVE_CAP'),
    nativeFloor: need('VAULT_NATIVE_FLOOR'),
  };
}

// ---------------------------------------------------------------------
// the chain, read through its REST API
// ---------------------------------------------------------------------

/** The network `name`'s node at `host` (the network's own unless given), checked to be that network by its genesis id. */
export async function connect(name, host, fetchImpl = globalThis.fetch) {
  const net = NETWORKS[name];
  if (!net) throw new Refused('UnknownNetwork', `${name}: choose mainnet, testnet or solo`);
  const url = host ?? net.host;
  const request = async (path, body) => {
    const r = await fetchImpl(`${url}${path}`, body === undefined
      ? {}
      : { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
    if (!r.ok) throw new Error(`${path}: HTTP ${r.status} ${await r.text()}`);
    return r.json();
  };
  const genesis = (await request('/blocks/0')).id.toLowerCase();
  if (net.genesis !== undefined && genesis !== net.genesis) {
    throw new Refused('WrongNetwork', `${url} answers genesis ${genesis}, not ${name}'s ${net.genesis}`);
  }
  const chain = {
    name,
    url,
    genesis,
    /** The registry id, VeChain's `CHAINID`: the genesis id as a number. */
    chainId: BigInt(genesis),
    chainTag: Number(BigInt(genesis) & 0xffn),
    request,
    best: () => request('/blocks/best'),
    now: async () => BigInt((await request('/blocks/best')).timestamp),
    /** Runs `clauses` in the node's read-only call simulation, from `caller`, on the best block's state. */
    inspect: (clauses, caller) => request('/accounts/*', { clauses, ...(caller ? { caller } : {}), gas: 50_000_000 }),
    /** The bytes a view returns, or undefined if it reverts. */
    view: async (to, data) => {
      const [r] = await request('/accounts/*', { clauses: [{ to, value: '0x0', data }] });
      return r.reverted ? undefined : r.data;
    },
    code: async (a) => (await request(`/accounts/${a}/code`)).code,
    account: (a) => request(`/accounts/${a}`),
    send: (raw) => request('/transactions', { raw }),
    receipt: (id) => request(`/transactions/${id}/receipt`),
  };
  chain.master = async (a) => '0x' + (await chain.view(PROTOTYPE, call('master(address)', [a]))).slice(-40);
  return chain;
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

/** DeployVault's `check`: refuses the indexes' own chain, a missing address or key, an anchor P1 and P2 could not be
 *  advanced from in time, verifiers that are not the pinned SP1 and RISC Zero ones (when given), roles that are not what
 *  the vault assumes, a native cap of zero and a floor above the cap. `deployer` is the address that would send the
 *  deployment. */
export async function check(p, chain, deployer) {
  if (p.sourceChainId === chain.chainId) throw new Refused('SourceChain', String(chain.chainId));
  const required = (name, a) => {
    if (!a || a === ZERO_ADDRESS) throw new Refused('Required', name);
  };
  required('VAULT_FACTORY', p.factory);
  required('VAULT_HUB_TEMPLATE', p.hubImplementation);
  if (p.p1ProgramKey === ZERO32) throw new Refused('Required', 'VAULT_P1_KEY');
  if (p.p2ImageId === ZERO32) throw new Refused('Required', 'VAULT_P2_IMAGE_ID');
  if (p.anchor === ZERO32) throw new Refused('Required', 'VAULT_ANCHOR');
  // LG-4: P1 and P2 refuse any proof a day after their anchor's epoch began, by VeChain's clock as by Ethereum's, and
  // the first advance needs time (A7-07).
  const lagEnds = genesisTime(p.sourceChainId) + p.anchorEpoch * EPOCH_SECONDS + VERIFIER_MAX_LAG;
  if ((await chain.now()) + MIN_ANCHOR_SLACK > lagEnds) throw new Refused('AnchorTooOld', `epoch ${p.anchorEpoch}, past ${lagEnds}`);
  if (p.sp1Verifier) await checkSp1(chain, p.sp1Verifier);
  if (p.riscZeroVerifier) await checkRiscZero(chain, p.riscZeroVerifier);
  await checkRoles(chain, p.freezer, p.recoveryProposer, deployer, p.recoveryIsNotASafe);
  if (p.nativeCap === 0n) throw new Refused('Required', 'VAULT_NATIVE_CAP');
  if (p.nativeFloor > p.nativeCap) throw new Refused('FloorAboveCap', `${p.nativeFloor} > ${p.nativeCap}`);
}

/** Whether `contract` answers `signature` with exactly `expected`: a revert, a missing function or a short answer is a
 *  no. */
async function answers(chain, contract, signature, expected) {
  return (await chain.view(contract, call(signature)))?.toLowerCase() === expected.toLowerCase();
}

/** Requires SP1's Groth16 verifier v6.0.0 itself: an owned gateway answers neither. */
export async function checkSp1(chain, a) {
  if (!(await answers(chain, a, 'VERIFIER_HASH() view returns (bytes32)', encode('bytes32', [SP1_VERIFIER_HASH])))
    || !(await answers(chain, a, 'VERSION() view returns (string)', encode('string', [SP1_VERSION])))) {
    throw new Refused('WrongVerifier', `VAULT_SP1_VERIFIER ${a}`);
  }
}

/** Requires RISC Zero's Groth16 verifier 3.0.0 with its published control ids: its router or emergency stop answers
 *  neither. */
export async function checkRiscZero(chain, a) {
  if (!(await answers(chain, a, 'SELECTOR() view returns (bytes4)', encode('bytes4', [RISC_ZERO_SELECTOR])))
    || !(await answers(chain, a, 'VERSION() view returns (string)', encode('string', [RISC_ZERO_VERSION])))) {
    throw new Refused('WrongVerifier', `VAULT_RISC_ZERO_VERIFIER ${a}`);
  }
}

/** The addresses of an ABI-encoded `address[]` (or of a tuple that starts with one), from a view's answer; empty when the
 *  answer is shorter than an array's offset and length. */
function addressArray(data) {
  const hex = data.slice(2);
  if (hex.length < 128) return [];
  const at = Number(BigInt('0x' + hex.slice(0, 64))) * 2;
  const n = Number(BigInt('0x' + hex.slice(at, at + 64)));
  return Array.from({ length: n }, (_, i) => '0x' + hex.slice(at + 64 + 64 * i + 24, at + 64 + 64 * (i + 1)).toLowerCase());
}

/** DeployVault's `checkRoles`: a freezer and a recovery proposer that are set, distinct and not the deploying key, and a
 *  recovery proposer that is the owner's multisig held to the factory owner's rule: a contract that is not an EIP-7702
 *  delegated key and is a Safe needing at least three signatures, with no enabled module, counting neither the freezer
 *  nor the deployer among its signers (A7-09). A contract that is not a Safe is accepted only when `recoveryIsNotASafe`
 *  says the operator vouches for it. */
export async function checkRoles(chain, freezer, recovery, deployer, recoveryIsNotASafe = false) {
  if (!freezer) throw new Refused('Required', 'VAULT_FREEZER');
  if (!recovery) throw new Refused('Required', 'VAULT_RECOVERY');
  if (freezer === recovery) throw new Refused('SameRole', freezer);
  if (freezer === deployer) throw new Refused('RoleIsBroadcaster', `VAULT_FREEZER ${freezer}`);
  if (recovery === deployer) throw new Refused('RoleIsBroadcaster', `VAULT_RECOVERY ${recovery}`);
  const code = (await chain.code(recovery)).toLowerCase();
  if (code === '0x' || code.startsWith('0xef0100')) throw new Refused('RecoveryMustBeContract', recovery);
  // A Safe answers getThreshold with one word; anything else, a revert included, shows nothing of how many keys hold it.
  const threshold = await chain.view(recovery, call('getThreshold() view returns (uint256)'));
  if (threshold === undefined || threshold.length !== 66) {
    if (!recoveryIsNotASafe) throw new Refused('RecoveryNotASafe', recovery);
    return;
  }
  if (BigInt(threshold) < MIN_RECOVERY_THRESHOLD) throw new Refused('RecoveryThresholdTooLow', `${recovery}: ${BigInt(threshold)}`);
  const modules = await chain.view(recovery, call('getModulesPaginated(address,uint256) view returns (address[],address)', ['0x' + '00'.repeat(19) + '01', 1n]));
  // A well-formed answer holds at least the array offset, the next cursor and the array length.
  if (modules === undefined || modules.length < 2 + 96 * 2) throw new Refused('RecoveryModulesUnknown', recovery);
  const [module] = addressArray(modules);
  if (module !== undefined) throw new Refused('RecoveryHasModules', `${recovery}: ${module}`);
  const signers = addressArray((await chain.view(recovery, call('getOwners() view returns (address[])'))) ?? '0x');
  for (const [role, account] of [['VAULT_FREEZER', freezer], ['deployer', deployer]]) {
    if (signers.includes(account.toLowerCase())) throw new Refused('RecoverySignedByRole', `${role} ${account}`);
  }
}

// ---------------------------------------------------------------------
// the source, before anything is sent
// ---------------------------------------------------------------------

/** The commit the deployment is made from and whether the working tree differs from it (an untracked file that git does
 *  not ignore counts). `run` is `git`, so a test can say what it answers. */
export function sourceRecord(run = (args) => execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })) {
  try {
    return { commit: run(['rev-parse', 'HEAD']).trim(), dirty: run(['status', '--porcelain']).trim() !== '' };
  } catch {
    throw new Refused('NoGit', 'the deployment is made from a git checkout, whose commit the record names');
  }
}

/** Refuses to send from a working tree that differs from its commit, unless `--allow-dirty` says it is a rehearsal, which
 *  a mainnet deployment never is. */
export function requireCleanTree(a, tree) {
  if (a.allowDirty && a.network === 'mainnet') throw new Refused('DirtyTree', '--allow-dirty is never accepted on mainnet');
  if (tree.dirty && !a.allowDirty) throw new Refused('DirtyTree', `${tree.commit} has uncommitted changes: commit them${a.network === 'mainnet' ? '' : ', or pass --allow-dirty for a rehearsal'}`);
}

/** The sources a build output was compiled from that no longer have the hash it recorded: forge's artifact lists every
 *  source's keccak256 in its metadata. An artifact that records none counts as stale, so nothing is deployed that cannot
 *  be tied to the files on disk (A7-10). */
export function staleSources(artifact, read = (p) => readFileSync(join(root, p))) {
  const sources = artifact.metadata?.sources;
  if (!sources || Object.keys(sources).length === 0) return ['(the artifact records no sources)'];
  return Object.entries(sources)
    .filter(([path, source]) => {
      try {
        return Keccak256.of(read(path)).toString().toLowerCase() !== source.keccak256.toLowerCase();
      } catch {
        return true;
      }
    })
    .map(([path]) => path);
}

// ---------------------------------------------------------------------
// the contracts, as forge builds them
// ---------------------------------------------------------------------

const ARTIFACTS = {
  SP1Verifier: 'vechain/out/sp1/SP1VerifierGroth16.sol/SP1Verifier.json',
  RiscZeroGroth16Verifier: 'vechain/out/risc0/RiscZeroGroth16Verifier.sol/RiscZeroGroth16Verifier.json',
  EthereumFinalityVerifier: 'out/EthereumFinalityVerifier.sol/EthereumFinalityVerifier.json',
  RiscZeroFinalityVerifier: 'out/RiscZeroFinalityVerifier.sol/RiscZeroFinalityVerifier.json',
  EthereumStateReader: 'out/EthereumStateReader.sol/EthereumStateReader.json',
  VaultSnapshot: 'out/VaultSnapshot.sol/VaultSnapshot.json',
  XindexVault: 'out/XindexVault.sol/XindexVault.json',
  VeChainStakerAttester: 'out/VeChainStakerAttester.sol/VeChainStakerAttester.json',
};

/** A contract's creation code as forge built it, every linked library placed at `links[library name]`. */
export function creationCode(name, links = {}, read = (p) => readFileSync(join(root, p), 'utf8')) {
  const a = JSON.parse(read(ARTIFACTS[name]));
  let hex = a.bytecode.object.slice(2);
  for (const libs of Object.values(a.bytecode.linkReferences ?? {})) {
    for (const [lib, places] of Object.entries(libs)) {
      const at = links[lib];
      if (!at) throw new Error(`${name}: unlinked ${lib}`);
      for (const { start, length } of places) hex = hex.slice(0, 2 * start) + at.slice(2).toLowerCase() + hex.slice(2 * (start + length));
    }
  }
  if (hex.includes('__$')) throw new Error(`${name}: a placeholder is left`);
  return '0x' + hex;
}

/** Refuses any artifact `names` lists that was compiled from other sources than the ones on disk, and returns the
 *  compiler they were built with, for the record. */
export function assertFresh(names, read = (p) => readFileSync(join(root, p), 'utf8'), readSource) {
  const compilers = new Set();
  for (const name of names) {
    const artifact = JSON.parse(read(ARTIFACTS[name]));
    const stale = staleSources(artifact, readSource);
    if (stale.length) throw new Refused('StaleBuild', `${name} was built from other sources than the ones here (${stale.slice(0, 3).join(', ')}): run npm run build`);
    compilers.add(artifact.metadata.compiler.version);
  }
  return [...compilers].join(', ');
}

/** RISC Zero's published control ids, from the vendored `ControlID.sol`. */
export function riscZeroControlIds(read = (p) => readFileSync(join(root, p), 'utf8')) {
  const ids = read('vendor/risc0-ethereum/src/groth16/ControlID.sol');
  return ['0x' + /CONTROL_ROOT\s*=\s*hex"([0-9a-f]+)"/.exec(ids)[1], '0x' + /BN254_CONTROL_ID\s*=\s*hex"([0-9a-f]+)"/.exec(ids)[1]];
}

/** The deployment's steps, in DeployVault's order with the attester last: each a name, its creation code with its
 *  constructor's arguments, and where its address goes. `at(name)` gives an earlier step's address. */
export function plan(p, at) {
  const genesis = genesisTime(p.sourceChainId);
  const verifierArgs = (zkvm, key) => encode('address, bytes32, bytes32, uint64, uint256', [zkvm, key, p.anchor, p.anchorEpoch, genesis]).slice(2);
  const steps = [];
  if (!p.sp1Verifier) steps.push({ name: 'SP1Verifier', data: () => creationCode('SP1Verifier') });
  if (!p.riscZeroVerifier) {
    steps.push({ name: 'RiscZeroGroth16Verifier', data: () => creationCode('RiscZeroGroth16Verifier') + encode('bytes32, bytes32', riscZeroControlIds()).slice(2) });
  }
  const sp1 = () => p.sp1Verifier || at('SP1Verifier');
  const r0 = () => p.riscZeroVerifier || at('RiscZeroGroth16Verifier');
  steps.push(
    { name: 'EthereumFinalityVerifier', data: () => creationCode('EthereumFinalityVerifier') + verifierArgs(sp1(), p.p1ProgramKey) },
    { name: 'RiscZeroFinalityVerifier', data: () => creationCode('RiscZeroFinalityVerifier') + verifierArgs(r0(), p.p2ImageId) },
    { name: 'EthereumStateReader', data: () => creationCode('EthereumStateReader') },
    { name: 'VaultSnapshot', data: () => creationCode('VaultSnapshot') },
    {
      name: 'XindexVault',
      data: () => creationCode('XindexVault', { VaultSnapshot: at('VaultSnapshot') }) + encode(
        '(uint256, address, address, address, address, address, address, address, uint256, uint256)',
        [[p.sourceChainId, p.factory, p.hubImplementation, at('EthereumFinalityVerifier'), at('RiscZeroFinalityVerifier'),
          p.freezer, p.recoveryProposer, at('EthereumStateReader'), p.nativeCap, p.nativeFloor]],
      ).slice(2),
    },
    { name: 'VeChainStakerAttester', data: () => creationCode('VeChainStakerAttester') },
  );
  return steps;
}

/** VeChain's intrinsic gas (`tx.IntrinsicGas`): 5,000, then per clause 16,000, or 48,000 to create a contract, and 4 a
 *  zero byte and 68 any other of its data. */
export function intrinsicGas(clauses) {
  let gas = 5_000n;
  for (const c of clauses) {
    gas += c.to === null ? 48_000n : 16_000n;
    const bytes = Buffer.from(c.data.slice(2), 'hex');
    for (const b of bytes) gas += b === 0 ? 4n : 68n;
  }
  return gas;
}

/** A clause-created contract's address (`thor.CreateContractAddress`): keccak256 of the transaction id, the clause's
 *  index and the creation's count, as 4 bytes each. */
export function contractAddress(txId, clauseIndex, count = 0) {
  const b = Buffer.alloc(40);
  Buffer.from(txId.slice(2), 'hex').copy(b, 0);
  b.writeUInt32BE(clauseIndex, 32);
  b.writeUInt32BE(count, 36);
  return '0x' + Keccak256.of(b).toString().slice(-40);
}

// ---------------------------------------------------------------------
// the simulation: the whole deployment in the node's read-only call simulation
// ---------------------------------------------------------------------

/** Runs every step, then the masters' clearing and the wiring's reads, as one batch of clauses in the node's call
 *  simulation from `from`: nothing is sent. The simulation's transaction id is zero, so each clause's contract has a
 *  known address. Returns each step's gas, the created code's size and the addresses, or throws on any revert. */
export async function simulate(p, chain, from) {
  const addresses = {};
  const steps = plan(p, (name) => addresses[name]);
  steps.forEach((s, i) => { addresses[s.name] = contractAddress(ZERO32, i); });
  const clauses = steps.map((s) => ({ to: null, value: '0x0', data: s.data() }));
  const created = Object.values(addresses);
  for (const a of created) clauses.push({ to: PROTOTYPE, value: '0x0', data: call('setMaster(address,address)', [a, ZERO_ADDRESS]) });
  for (const a of created) clauses.push({ to: PROTOTYPE, value: '0x0', data: call('master(address) view returns (address)', [a]) });
  const out = await chain.inspect(clauses, from);
  const report = steps.map((s, i) => {
    const r = out[i];
    if (r.reverted) throw new Refused('SimulationReverted', `${s.name}: ${r.vmError}`);
    const create = { ...clauses[i], to: null };
    return { name: s.name, address: addresses[s.name], gas: BigInt(r.gasUsed) + intrinsicGas([create]), codeSize: (r.data.length - 2) / 2 };
  });
  for (let i = 0; i < created.length; i++) {
    const cleared = out[steps.length + i];
    if (cleared.reverted) throw new Refused('SimulationReverted', `setMaster(${created[i]}): ${cleared.vmError}`);
    const master = out[steps.length + created.length + i].data;
    if (BigInt(master) !== 0n) throw new Refused('MasterNotCleared', `${created[i]}: ${master}`);
  }
  return { report, addresses };
}

// ---------------------------------------------------------------------
// the key
// ---------------------------------------------------------------------

/** The private key in an Ethereum V3 keystore (scrypt or pbkdf2, aes-128-ctr), checked by its MAC. */
export function unlock(keystore, password) {
  const c = keystore.crypto ?? keystore.Crypto;
  const k = c.kdfparams;
  const salt = Buffer.from(k.salt, 'hex');
  const dk =
    c.kdf === 'scrypt'
      ? scryptSync(password, salt, k.dklen, { N: k.n, r: k.r, p: k.p, maxmem: 256 * k.n * k.r + (1 << 20) })
      : pbkdf2Sync(password, salt, k.c, k.dklen, 'sha256');
  const ciphertext = Buffer.from(c.ciphertext, 'hex');
  if (Keccak256.of(Buffer.concat([dk.subarray(16, 32), ciphertext])).toString().slice(2) !== c.mac.toLowerCase()) {
    throw new Refused('WrongPassword', 'the keystore did not open');
  }
  const d = createDecipheriv(c.cipher, dk.subarray(0, 16), Buffer.from(c.cipherparams.iv, 'hex'));
  return new Uint8Array(Buffer.concat([d.update(ciphertext), d.final()]));
}

/** The address a key signs for. */
export const addressOf = (key) => Address.ofPublicKey(Secp256k1.derivePublicKey(key, false)).toString().toLowerCase();

/** Refuses a password file that group or others can read: it holds the keystore's password, which makes the keystore a raw
 *  key in effect (A7-21). */
export function checkPasswordFile(path, stat = statSync) {
  if ((stat(path).mode & 0o077) !== 0) throw new Refused('PasswordFileReadable', `${path} must be readable by its owner alone: chmod 600 it`);
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
// sending
// ---------------------------------------------------------------------

/** Signs and sends one transaction of `clauses` from `key`, its gas the simulation's plus a fifth, and waits for its
 *  receipt, which must not have reverted. Fees: the node's suggested priority fee, on top of twice the best block's base
 *  fee. */
export async function send(chain, key, clauses, { log = console.log, label = '', wait = 10_000, tries = 60 } = {}) {
  const from = addressOf(key);
  const simulated = await chain.inspect(clauses, from);
  const failed = simulated.find((r) => r.reverted);
  if (failed) throw new Refused('SimulationReverted', `${label}: ${failed.vmError}`);
  const execution = simulated.reduce((s, r) => s + BigInt(r.gasUsed), 0n);
  const gas = ((intrinsicGas(clauses) + execution) * 6n) / 5n;
  if (gas > MAX_TX_GAS) throw new Refused('TooMuchGas', `${label}: ${gas} > ${MAX_TX_GAS}`);
  const best = await chain.best();
  const baseFee = BigInt(best.baseFeePerGas ?? '0');
  const tip = BigInt((await chain.request('/fees/priority')).maxPriorityFeePerGas ?? '0');
  const body = {
    chainTag: chain.chainTag,
    blockRef: best.id.slice(0, 18),
    expiration: 720,
    clauses,
    maxFeePerGas: '0x' + (2n * baseFee + tip).toString(16),
    maxPriorityFeePerGas: '0x' + tip.toString(16),
    gas: Number(gas),
    dependsOn: null,
    nonce: '0x' + randomBytes(8).toString('hex'),
  };
  const tx = Transaction.of(body).sign(key);
  const id = tx.id.toString();
  const sent = await chain.send(HexUInt.of(tx.encoded).toString());
  if (sent.id?.toLowerCase() !== id.toLowerCase()) throw new Error(`${label}: the node answered ${JSON.stringify(sent)}`);
  for (let i = 0; i < tries; i++) {
    const r = await chain.receipt(id);
    if (r) {
      if (r.reverted) throw new Error(`${label}: transaction ${id} reverted`);
      log(`${label.padEnd(26)} tx ${id}  gas ${r.gasUsed}`);
      return { id, receipt: r };
    }
    await new Promise((ok) => setTimeout(ok, wait));
  }
  throw new Error(`${label}: no receipt for ${id}`);
}

/** Deploys every step from `key`, one transaction each, then clears every master in one transaction, and returns the
 *  addresses. Each transaction is simulated first, from the deployer, and must succeed there. */
export async function deploy(p, chain, key, opts = {}) {
  const d = {};
  for (const step of plan(p, (name) => d[name])) {
    const { receipt } = await send(chain, key, [{ to: null, value: '0x0', data: step.data() }], { ...opts, label: step.name });
    d[step.name] = receipt.outputs[0].contractAddress.toLowerCase();
    if (step.name === 'SP1Verifier') await checkSp1(chain, d.SP1Verifier);
    if (step.name === 'RiscZeroGroth16Verifier') await checkRiscZero(chain, d.RiscZeroGroth16Verifier);
  }
  const created = Object.values(d);
  await send(chain, key, created.map((a) => ({ to: PROTOTYPE, value: '0x0', data: call('setMaster(address,address)', [a, ZERO_ADDRESS]) })),
    { ...opts, label: 'Prototype.setMaster(_, 0)' });
  return d;
}

// ---------------------------------------------------------------------
// the wiring check, after
// ---------------------------------------------------------------------

/** DeployVault's `checkDeployment`, and VeChain's masters: `d` is one deployment made with `p`, read back from the chain,
 *  every contract's master reads zero, and the runtime code hashes the release record keeps. Run it again later against
 *  the recorded addresses: equal hashes prove the code is unchanged. */
export async function checkDeployment(d, p, chain) {
  const same = async (name, contract, signature, expected) => {
    const actual = (await chain.view(contract, call(signature)))?.toLowerCase();
    if (actual !== expected.toLowerCase()) throw new Refused('WrongWiring', `${name}: ${expected} expected, ${actual} found`);
  };
  const sp1 = p.sp1Verifier || d.SP1Verifier;
  const r0 = p.riscZeroVerifier || d.RiscZeroGroth16Verifier;
  const v = d.XindexVault;
  const genesis = word(genesisTime(p.sourceChainId));
  await same('p1', v, 'p1() view returns (address)', addressWord(d.EthereumFinalityVerifier));
  await same('p2', v, 'p2() view returns (address)', addressWord(d.RiscZeroFinalityVerifier));
  await same('STATE_READER', v, 'STATE_READER() view returns (address)', addressWord(d.EthereumStateReader));
  await same('FACTORY', v, 'FACTORY() view returns (address)', addressWord(p.factory));
  await same('HUB_IMPLEMENTATION', v, 'HUB_IMPLEMENTATION() view returns (address)', addressWord(p.hubImplementation));
  await same('RECOVERY_PROPOSER', v, 'RECOVERY_PROPOSER() view returns (address)', addressWord(p.recoveryProposer));
  await same('freezer', v, 'freezer() view returns (address)', addressWord(p.freezer));
  await same('SOURCE_CHAIN_ID', v, 'SOURCE_CHAIN_ID() view returns (uint256)', word(p.sourceChainId));
  await same('SP1_VERIFIER', d.EthereumFinalityVerifier, 'SP1_VERIFIER() view returns (address)', addressWord(sp1));
  await same('RISC_ZERO_VERIFIER', d.RiscZeroFinalityVerifier, 'RISC_ZERO_VERIFIER() view returns (address)', addressWord(r0));
  await same('PROGRAM_KEY', d.EthereumFinalityVerifier, 'PROGRAM_KEY() view returns (bytes32)', p.p1ProgramKey);
  await same('IMAGE_ID', d.RiscZeroFinalityVerifier, 'IMAGE_ID() view returns (bytes32)', p.p2ImageId);
  for (const [name, x] of [['p1', d.EthereumFinalityVerifier], ['p2', d.RiscZeroFinalityVerifier]]) {
    await same(`${name} anchor`, x, 'anchor() view returns (bytes32)', p.anchor);
    await same(`${name} anchorEpoch`, x, 'anchorEpoch() view returns (uint64)', word(p.anchorEpoch));
    await same(`${name} GENESIS_TIME`, x, 'GENESIS_TIME() view returns (uint256)', genesis);
  }
  await same('STAKER', d.VeChainStakerAttester, 'STAKER() view returns (address)', addressWord(STAKER));
  await checkSp1(chain, sp1);
  await checkRiscZero(chain, r0);
  const cap = await chain.view(v, call('cap(address) view returns (uint256)', [ZERO_ADDRESS]));
  const floor = await chain.view(v, call('outflowFloor(address) view returns (uint256)', [ZERO_ADDRESS]));
  if (cap?.toLowerCase() !== word(p.nativeCap) || floor?.toLowerCase() !== word(p.nativeFloor)) {
    throw new Refused('WrongWiring', `cap ${cap}, floor ${floor}`);
  }
  const hashes = {};
  for (const [name, a] of Object.entries(d)) {
    const code = await chain.code(a);
    if (code === '0x') throw new Refused('WrongWiring', `${name} has no code`);
    const master = await chain.master(a);
    if (BigInt(master) !== 0n) throw new Refused('MasterNotCleared', `${name} ${a}: ${master}`);
    hashes[name] = Keccak256.of(code).toString();
  }
  return hashes;
}

// ---------------------------------------------------------------------
// the command line
// ---------------------------------------------------------------------

function argsOf(argv) {
  const a = { dryRun: false, allowDirty: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--dry-run') a.dryRun = true;
    else if (k === '--allow-dirty') a.allowDirty = true;
    else if (['--network', '--keystore', '--password-file', '--host', '--from'].includes(k)) a[k.slice(2)] = argv[++i];
    else throw new Refused('BadArgument', k);
  }
  if (!a.network) throw new Refused('Required', '--network mainnet|testnet|solo');
  return a;
}

export async function main(argv = process.argv.slice(2), env = process.env, fetchImpl = globalThis.fetch, log = console.log, source = sourceRecord) {
  const a = argsOf(argv);
  const chain = await connect(a.network, a.host, fetchImpl);
  const p = paramsFromEnv(env);
  // A deployment is made from a committed tree, so its record names the commit it deployed (A7-10). A dry run only says.
  let tree;
  try {
    tree = source();
  } catch (e) {
    // Without a git checkout nothing can be said of the source: a dry run goes on, and a deployment does not.
    if (!a.dryRun) throw e;
    tree = { commit: 'unknown', dirty: true };
    log(`warning: ${e.message}`);
  }
  if (tree.dirty) log(`warning: the working tree differs from ${tree.commit}`);
  let key;
  let deployer;
  if (a.dryRun) {
    if (!a.from) throw new Refused('Required', '--from <deployer address> with --dry-run');
    deployer = evmAddress(a.from);
  } else {
    if (!a.keystore) throw new Refused('Required', '--keystore');
    requireCleanTree(a, tree);
    if (a['password-file']) checkPasswordFile(a['password-file']);
    const keystore = JSON.parse(readFileSync(a.keystore, 'utf8'));
    const password = a['password-file'] ? readFileSync(a['password-file'], 'utf8').replace(/\r?\n$/, '') : await prompt('keystore password: ');
    key = unlock(keystore, password);
    deployer = addressOf(key);
  }
  log(`VeChain ${a.network} (genesis ${chain.genesis}) at ${chain.url}, deployer ${deployer}`);
  await check(p, chain, deployer);
  log('every check passed');
  // What is deployed is what is on disk: every artifact the plan uses was compiled from these sources.
  const compiler = assertFresh([...new Set(plan(p, () => '0x').map((step) => step.name))]);
  log(`build output is current; compiled with solc ${compiler}`);
  const { report } = await simulate(p, chain, deployer);
  let total = 0n;
  for (const r of report) {
    total += r.gas;
    log(`simulated ${r.name.padEnd(26)} gas ${String(r.gas).padStart(9)}  code ${String(r.codeSize).padStart(6)} bytes`);
    if (r.gas > MAX_TX_GAS) throw new Refused('TooMuchGas', `${r.name}: ${r.gas} > ${MAX_TX_GAS}`);
  }
  log(`simulated every master cleared; ${total} gas in all`);
  // VeChain's gas is paid in VTHO, which the deployer's VET generates: twice the base fee bounds what it may cost.
  const baseFee = BigInt((await chain.best()).baseFeePerGas ?? '0');
  const energy = BigInt((await chain.account(deployer)).energy);
  const needs = ((total * 6n) / 5n) * 2n * baseFee;
  log(`deployer holds ${energy} wei of VTHO; the deployment needs at most about ${needs}`);
  if (!a.dryRun && energy < needs) throw new Refused('NotEnoughEnergy', `${energy} < ${needs}`);
  if (a.dryRun) {
    log('dry run: nothing sent');
    return undefined;
  }
  const d = await deploy(p, chain, key, { log });
  const hashes = await checkDeployment(d, p, chain);
  const record = Object.fromEntries(Object.entries(d).map(([k, x]) => [k, { address: x, codehash: hashes[k] }]));
  log(JSON.stringify({ network: a.network, chainId: chain.genesis, commit: tree.commit, dirty: tree.dirty, compiler, deployment: record }, null, 2));
  return d;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e.code ? `refused, ${e.message}` : e);
    process.exit(1);
  });
}
