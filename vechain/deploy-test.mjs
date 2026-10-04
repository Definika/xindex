// Tests `deploy.mjs` against a VeChain node faked in this process, so nothing reaches a network: every refusal DeployVault
// makes, adapted to VeChain; a dry run, which simulates and sends nothing; a whole deployment, every transaction it
// signs decoded by the SDK and checked (chain tag, one creation clause each, the deployer as origin, gas under EIP-7825's
// cap), the masters cleared in one transaction; and the wiring read back, refusing any of it changed. Needs `build.mjs`.
//
// The deploying key is the secp256k1 scalar 1, a well-known test key that holds nothing anywhere, and the keystore is
// the Web3 Secret Storage definition's published test vector: no key or keystore of anyone's is read or written.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { HexUInt, Keccak256, Transaction } from '@vechain/sdk-core';
import {
  NETWORKS, PROTOTYPE, STAKER, MAX_TX_GAS, MAINNET_GENESIS_TIME, MIN_ANCHOR_SLACK, Refused, addressOf, assertFresh, call, check,
  checkDeployment, checkPasswordFile, checkRoles, connect, contractAddress, deploy, encode, intrinsicGas, main, paramsFromEnv, plan, sourceRecord,
  staleSources, unlock,
} from './deploy.mjs';

const GENESIS = NETWORKS.mainnet.genesis;
const NOW = 1_791_122_000n;
const KEY = HexUInt.of('0x' + '00'.repeat(31) + '01').bytes;
const DEPLOYER = addressOf(KEY);
const word = (x) => '0x' + BigInt(x).toString(16).padStart(64, '0');
const addr = (n) => '0x' + n.toString(16).padStart(40, '0');
const SP1_ANSWERS = {
  [call('VERIFIER_HASH() view returns (bytes32)')]: word('0x0e78f4db7a6771a3a6a7d9c3b0de6fe73d58781368967a7fe84d87aefffec896'),
  [call('VERSION() view returns (string)')]: encode('string', ['v6.0.0']),
};
const R0_ANSWERS = {
  [call('SELECTOR() view returns (bytes4)')]: encode('bytes4', ['0x73c457ba']),
  [call('VERSION() view returns (string)')]: encode('string', ['3.0.0']),
};
const MODULES = 'getModulesPaginated(address,uint256) view returns (address[],address)';
const SENTINEL = addr(1);
/** What a Safe answers: its threshold, an empty first page of modules (the cursor is the sentinel, the array empty), and
 *  its signers. */
const safeAnswers = ({ threshold = 3, modules = [], owners = [addr(0xa11)] } = {}) => ({
  [call('getThreshold() view returns (uint256)')]: word(threshold),
  [call(MODULES, [SENTINEL, 1n])]: '0x' + word(0x40).slice(2) + word(1).slice(2) + word(modules.length).slice(2) + modules.map((m) => word(m).slice(2)).join(''),
  [call('getOwners() view returns (address[])')]: '0x' + word(0x20).slice(2) + word(owners.length).slice(2) + owners.map((m) => word(m).slice(2)).join(''),
});

/** A VeChain node in this process: its genesis, clock, accounts' code, views by address and calldata, and every
 *  transaction it is sent, decoded. Creations succeed in its simulation; a sent creation's contract lands at
 *  `thor.CreateContractAddress(txId, 0, 0)`. */
function fakeNode({ genesis = GENESIS, now = NOW, codes = {}, views = {}, energy = 10n ** 24n } = {}) {
  const sent = [];
  const masters = {};
  const json = (x) => ({ ok: true, json: async () => x, text: async () => JSON.stringify(x) });
  const answer = (c) => {
    if (c.to === null) return { data: '0x6080', gasUsed: 1_500_000, reverted: false, vmError: '' };
    const to = c.to.toLowerCase();
    if (to === PROTOTYPE) {
      const target = '0x' + c.data.slice(34, 74);
      if (c.data.startsWith(call('setMaster(address,address)', [addr(0), addr(0)]).slice(0, 10))) return { data: '0x', gasUsed: 6515, reverted: false };
      return { data: word(masters[target] ?? 0), gasUsed: 1058, reverted: false };
    }
    const data = views[to]?.[c.data];
    return data === undefined ? { data: '0x', gasUsed: 100, reverted: true, vmError: 'execution reverted' } : { data, gasUsed: 1000, reverted: false };
  };
  const fetchImpl = async (url, opts = {}) => {
    const path = url.replace(/^https?:\/\/[^/]+/, '');
    const body = opts.body ? JSON.parse(opts.body) : undefined;
    if (path === '/blocks/0') return json({ id: genesis });
    if (path === '/blocks/best') {
      return json({ id: '0x018da0c4' + 'ab'.repeat(28), number: 26058948, timestamp: Number(now), baseFeePerGas: '0x9184e72a000', gasLimit: 40_000_000 });
    }
    if (path === '/fees/priority') return json({ maxPriorityFeePerGas: '0x3b9aca00' });
    if (path === '/accounts/*') return json(body.clauses.map(answer));
    const code = /^\/accounts\/(0x[0-9a-f]{40})\/code$/i.exec(path);
    if (code) return json({ code: codes[code[1].toLowerCase()] ?? '0x' });
    if (/^\/accounts\/0x[0-9a-f]{40}$/i.test(path)) return json({ balance: '0x0', energy: '0x' + energy.toString(16), hasCode: false });
    if (path === '/transactions') {
      const tx = Transaction.decode(HexUInt.of(body.raw).bytes, true);
      const id = tx.id.toString();
      sent.push({ id, tx });
      // A real node runs the clauses; this one records what they would do.
      for (const c of tx.body.clauses) {
        if (c.to?.toLowerCase() === PROTOTYPE) masters['0x' + c.data.slice(34, 74)] = 0n;
      }
      return json({ id });
    }
    const receipt = /^\/transactions\/(0x[0-9a-f]{64})\/receipt$/i.exec(path);
    if (receipt) {
      const s = sent.find((x) => x.id === receipt[1]);
      const outputs = s.tx.body.clauses.map((c, i) => ({ contractAddress: c.to === null ? contractAddress(s.id, i) : null, events: [], transfers: [] }));
      for (const o of outputs) if (o.contractAddress) masters[o.contractAddress] = BigInt(s.tx.origin.toString());
      return json({ gasUsed: 1_000_000, reverted: false, outputs });
    }
    throw new Error(`the fake node has no ${path}`);
  };
  return { fetchImpl, sent, masters, views, codes };
}

/** DeployVault's parameters, valid on the fake node: a multisig recovery proposer with code, an anchor in the lag. */
function goodParams(extra = {}) {
  const env = {
    VAULT_FACTORY: addr(0xfac),
    VAULT_HUB_TEMPLATE: addr(0x7e3),
    VAULT_SP1_VERIFIER: addr(0x5b1),
    VAULT_RISC_ZERO_VERIFIER: addr(0x4c0),
    VAULT_P1_KEY: '0x01',
    VAULT_P2_IMAGE_ID: '0x02',
    VAULT_ANCHOR: '0x03',
    VAULT_ANCHOR_EPOCH: String((NOW - MAINNET_GENESIS_TIME) / 384n),
    VAULT_FREEZER: addr(0xf4e),
    VAULT_RECOVERY: addr(0x4ec),
    VAULT_NATIVE_CAP: '1000',
    VAULT_NATIVE_FLOOR: '10',
    ...extra,
  };
  return { env, p: paramsFromEnv(env) };
}

function nodeWithVerifiers(extra = {}) {
  return fakeNode({
    codes: { [addr(0x4ec)]: '0x6080604052' },
    views: { [addr(0x5b1)]: SP1_ANSWERS, [addr(0x4c0)]: R0_ANSWERS, [addr(0x4ec)]: safeAnswers() },
    ...extra,
  });
}

async function refuses(code, fn) {
  await assert.rejects(fn, (e) => {
    assert.equal(e.code, code, e.message);
    return true;
  });
}

test('the network is named and checked by its genesis id', async () => {
  await refuses('UnknownNetwork', () => connect('nile', undefined, fakeNode().fetchImpl));
  await refuses('WrongNetwork', () => connect('mainnet', undefined, fakeNode({ genesis: NETWORKS.testnet.genesis }).fetchImpl));
  const chain = await connect('mainnet', undefined, fakeNode().fetchImpl);
  assert.equal(chain.chainId, BigInt(GENESIS), 'CHAINID: the genesis id');
  assert.equal(chain.chainTag, 0x4a);
  assert.equal(PROTOTYPE, '0x000000000000000000000050726f746f74797065');
  assert.equal(STAKER, '0x00000000000000000000000000005374616b6572');
});

test("every refusal DeployVault's check makes", async () => {
  const node = nodeWithVerifiers();
  const chain = await connect('mainnet', undefined, node.fetchImpl);
  const { p } = goodParams();
  await check(p, chain, DEPLOYER);
  const variant = async (code, extra, deployer = DEPLOYER, n = node) => {
    const c = await connect('mainnet', undefined, n.fetchImpl);
    await refuses(code, () => check(goodParams(extra).p, c, deployer));
  };
  await variant('SourceChain', { VAULT_SOURCE_CHAIN_ID: String(BigInt(GENESIS)) });
  await variant('UnknownSource', { VAULT_SOURCE_CHAIN_ID: '56' });
  for (const k of ['VAULT_FACTORY', 'VAULT_HUB_TEMPLATE', 'VAULT_P1_KEY', 'VAULT_P2_IMAGE_ID', 'VAULT_ANCHOR', 'VAULT_FREEZER', 'VAULT_RECOVERY']) {
    await variant('Required', { [k]: '' });
  }
  await variant('Required', { VAULT_FACTORY: addr(0) });
  // A7-07: an epoch more than 12 hours old has less than 12 hours of its day left, and is refused.
  await variant('AnchorTooOld', { VAULT_ANCHOR_EPOCH: String((NOW - MAINNET_GENESIS_TIME - 43_200n) / 384n - 1n) });
  await variant('WrongVerifier', { VAULT_SP1_VERIFIER: addr(0x4c0) });
  await variant('WrongVerifier', { VAULT_RISC_ZERO_VERIFIER: addr(0x5b1) });
  await variant('SameRole', { VAULT_FREEZER: addr(0x4ec) });
  await variant('RoleIsBroadcaster', { VAULT_FREEZER: DEPLOYER });
  await variant('RoleIsBroadcaster', {}, addr(0x4ec));
  await variant('RecoveryMustBeContract', { VAULT_RECOVERY: addr(0xeee) });
  const delegated = nodeWithVerifiers({ codes: { [addr(0x4ec)]: '0xef0100' + '11'.repeat(20) } });
  await variant('RecoveryMustBeContract', {}, DEPLOYER, delegated);
  await variant('FloorAboveCap', { VAULT_NATIVE_FLOOR: '1001' });
  await variant('Required', { VAULT_NATIVE_CAP: '0', VAULT_NATIVE_FLOOR: '0' });
  assert.throws(() => paramsFromEnv({ VAULT_FACTORY: 'T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb' }), Refused);
});

test('A7-07: an anchor needs 12 hours of its day left, to the second', async () => {
  const chain = await connect('mainnet', undefined, nodeWithVerifiers().fetchImpl);
  const epoch = (NOW - MAINNET_GENESIS_TIME) / 384n - 100n;
  const lagEnds = MAINNET_GENESIS_TIME + epoch * 384n + 86_400n;
  assert.equal(MIN_ANCHOR_SLACK, 43_200n);
  // The fake node's clock is NOW: an epoch whose day ends exactly 12 hours from now passes, one second less does not.
  const slack = lagEnds - NOW;
  assert.ok(slack > 0n);
  const at = async (now) => check(goodParams({ VAULT_ANCHOR_EPOCH: String(epoch) }).p, await connect('mainnet', undefined, nodeWithVerifiers({ now }).fetchImpl), DEPLOYER);
  await at(lagEnds - MIN_ANCHOR_SLACK);
  await refuses('AnchorTooOld', () => at(lagEnds - MIN_ANCHOR_SLACK + 1n));
  await refuses('AnchorTooOld', () => at(lagEnds + 1n));
  assert.equal(chain.chainId, BigInt(GENESIS));
});

test('A7-23: the epoch, the cap and the floor are required, as DeployVault requires them', () => {
  const { env } = goodParams();
  paramsFromEnv(env);
  for (const k of ['VAULT_ANCHOR_EPOCH', 'VAULT_NATIVE_CAP', 'VAULT_NATIVE_FLOOR']) {
    const without = { ...env };
    delete without[k];
    assert.throws(() => paramsFromEnv(without), (e) => e.code === 'Required' && e.message.includes(k), k);
    assert.throws(() => paramsFromEnv({ ...env, [k]: '' }), (e) => e.code === 'Required', `${k} empty`);
  }
  // `simulate.mjs` measures with placeholders, and reads any of them as zero.
  assert.equal(paramsFromEnv({}, true).nativeCap, 0n);
});

test('A7-21: a password file that group or others can read is refused', () => {
  checkPasswordFile('x', () => ({ mode: 0o100600 }));
  for (const mode of [0o100640, 0o100644, 0o100604, 0o100660]) {
    assert.throws(() => checkPasswordFile('x', () => ({ mode })), (e) => e.code === 'PasswordFileReadable', mode.toString(8));
  }
});

test('A7-09: the recovery multisig is held to the factory owner\'s rule', async () => {
  const chainOf = async (extra) => connect('mainnet', undefined, nodeWithVerifiers(extra).fetchImpl);
  const freezer = addr(0xf4e);
  const recovery = addr(0x4ec);
  const roles = async (views, ack = false, deployer = DEPLOYER) => checkRoles(await chainOf({ views: { [recovery]: views } }), freezer, recovery, deployer, ack);
  await roles(safeAnswers());
  await refuses('RecoveryThresholdTooLow', () => roles(safeAnswers({ threshold: 1 })));
  await refuses('RecoveryThresholdTooLow', () => roles(safeAnswers({ threshold: 2 }), true));
  await refuses('RecoveryHasModules', () => roles(safeAnswers({ modules: [addr(0x30d)] })));
  await refuses('RecoverySignedByRole', () => roles(safeAnswers({ owners: [addr(0xa11), freezer] })));
  await refuses('RecoverySignedByRole', () => roles(safeAnswers({ owners: [DEPLOYER] })));
  // A module list that cannot be read is refused, not trusted.
  await refuses('RecoveryModulesUnknown', () => roles({ ...safeAnswers(), [call(MODULES, [SENTINEL, 1n])]: '0x01' }));
  const noModules = safeAnswers();
  delete noModules[call(MODULES, [SENTINEL, 1n])];
  await refuses('RecoveryModulesUnknown', () => roles(noModules));
  // A contract that is not a Safe shows nothing of how many keys hold it: refused unless the operator vouches for it.
  await refuses('RecoveryNotASafe', () => roles({}));
  await refuses('RecoveryNotASafe', () => roles({ [call('getThreshold() view returns (uint256)')]: '0x01' }));
  await roles({}, true);
  // The word waives only that: no code is no multisig at all.
  await refuses('RecoveryMustBeContract', async () => checkRoles(await chainOf(), freezer, addr(0xeee), DEPLOYER, true));
  // And through `check`, the parameter's word reaches it.
  const bare = await chainOf({ views: { [addr(0x5b1)]: SP1_ANSWERS, [addr(0x4c0)]: R0_ANSWERS } });
  await refuses('RecoveryNotASafe', () => check(goodParams().p, bare, DEPLOYER));
  await check(goodParams({ VAULT_RECOVERY_IS_NOT_A_SAFE_ACK: 'true' }).p, bare, DEPLOYER);
});

test('A7-10: a working tree that differs, or a build from other sources, is refused before anything is sent', async () => {
  // The commit and whether the tree differs, from what git answers.
  const git = (answers) => (args) => answers[args.join(' ')];
  assert.deepEqual(sourceRecord(git({ 'rev-parse HEAD': 'abc123\n', 'status --porcelain': '' })), { commit: 'abc123', dirty: false });
  assert.deepEqual(sourceRecord(git({ 'rev-parse HEAD': 'abc123\n', 'status --porcelain': ' M src/vault/XindexVault.sol\n' })), { commit: 'abc123', dirty: true });

  // Without a git checkout nothing can be said of the source: a deployment is refused, and a dry run goes on and says so.
  assert.throws(() => sourceRecord(() => { throw new Error('not a git repository'); }), (e) => e.code === 'NoGit');
  const nogit = () => { throw new Refused('NoGit', 'no checkout'); };
  const said = [];
  await main(['--network', 'mainnet', '--dry-run', '--from', DEPLOYER], goodParams().env, nodeWithVerifiers().fetchImpl, (l) => said.push(l), nogit);
  assert.ok(said.some((l) => l.startsWith('warning: NoGit')));
  await refuses('NoGit', () => main(['--network', 'mainnet', '--keystore', '/nonexistent'], goodParams().env, nodeWithVerifiers().fetchImpl, () => {}, nogit));

  // A real deployment from a tree that differs is refused before the keystore is read, and on mainnet whatever is passed.
  const node = nodeWithVerifiers();
  const { env } = goodParams();
  const dirty = () => ({ commit: 'abc123', dirty: true });
  const clean = () => ({ commit: 'abc123', dirty: false });
  await refuses('DirtyTree', () => main(['--network', 'mainnet', '--keystore', '/nonexistent'], env, node.fetchImpl, () => {}, dirty));
  await refuses('DirtyTree', () => main(['--network', 'mainnet', '--keystore', '/nonexistent', '--allow-dirty'], env, node.fetchImpl, () => {}, dirty));
  await refuses('DirtyTree', () => main(['--network', 'mainnet', '--keystore', '/nonexistent', '--allow-dirty'], env, node.fetchImpl, () => {}, clean));
  // On a rehearsal network it needs --allow-dirty, and then goes on to the keystore.
  const testnet = nodeWithVerifiers({ genesis: NETWORKS.testnet.genesis });
  await refuses('DirtyTree', () => main(['--network', 'testnet', '--keystore', '/nonexistent'], env, testnet.fetchImpl, () => {}, dirty));
  await assert.rejects(() => main(['--network', 'testnet', '--keystore', '/nonexistent', '--allow-dirty'], env, testnet.fetchImpl, () => {}, dirty), /ENOENT/);
  // A dry run only says.
  const lines = [];
  await main(['--network', 'mainnet', '--dry-run', '--from', DEPLOYER], env, node.fetchImpl, (l) => lines.push(l), dirty);
  assert.ok(lines.some((l) => l.startsWith('warning: the working tree differs from abc123')));
  assert.ok(lines.some((l) => l.startsWith('build output is current')), 'and the build is checked');

  // forge's artifact lists every source's hash; one that changed, or an artifact that lists none, is stale.
  const artifact = { metadata: { compiler: { version: '0.8.28+commit.7893614a' }, sources: { 'src/A.sol': { keccak256: Keccak256.of(Buffer.from('a')).toString() }, 'src/B.sol': { keccak256: '0x00' } } } };
  const disk = { 'src/A.sol': 'a', 'src/B.sol': 'b' };
  const read = (p) => { if (!(p in disk)) throw new Error('gone'); return Buffer.from(disk[p]); };
  assert.deepEqual(staleSources(artifact, read), ['src/B.sol'], 'B differs');
  assert.deepEqual(staleSources({ metadata: { sources: {} } }, read), ['(the artifact records no sources)']);
  assert.deepEqual(staleSources({}, read), ['(the artifact records no sources)']);
  delete disk['src/A.sol'];
  assert.deepEqual(staleSources(artifact, read), ['src/A.sol', 'src/B.sol'], 'a source that is gone is stale');
  // assertFresh names the artifact and its sources, and returns the compiler of a fresh build.
  const fresh = { metadata: { compiler: { version: '0.8.28+commit.7893614a' }, sources: { 'src/A.sol': { keccak256: Keccak256.of(Buffer.from('a')).toString() } } } };
  disk['src/A.sol'] = 'a';
  assert.equal(assertFresh(['XindexVault'], () => JSON.stringify(fresh), read), '0.8.28+commit.7893614a');
  assert.throws(() => assertFresh(['XindexVault'], () => JSON.stringify(artifact), read), (e) => e.code === 'StaleBuild' && e.message.includes('XindexVault') && e.message.includes('src/B.sol'));
});

test('a dry run checks, simulates the whole deployment, and sends nothing', async () => {
  const node = nodeWithVerifiers();
  const lines = [];
  const { env } = goodParams();
  await main(['--network', 'mainnet', '--dry-run', '--from', DEPLOYER], env, node.fetchImpl, (l) => lines.push(l));
  assert.equal(node.sent.length, 0);
  assert.ok(lines.some((l) => l.startsWith('simulated XindexVault')));
  assert.ok(lines.some((l) => l.includes('every master cleared')));
  assert.equal(lines.at(-1), 'dry run: nothing sent');
  await refuses('Required', () => main(['--network', 'mainnet', '--dry-run'], env, node.fetchImpl, () => {}));
  await refuses('Required', () => main(['--network', 'mainnet'], env, node.fetchImpl, () => {}));
  await refuses('Required', () => main([], env, node.fetchImpl, () => {}));
  await refuses('BadArgument', () => main(['--network', 'mainnet', '--private-key', '0x01'], env, node.fetchImpl, () => {}));
});

test('the deployment: one creation a transaction, the masters cleared, the wiring read back', async () => {
  // Without verifiers given, the script deploys the vendored ones first.
  const { p } = goodParams({ VAULT_SP1_VERIFIER: '', VAULT_RISC_ZERO_VERIFIER: '' });
  const node = fakeNode({ codes: { [addr(0x4ec)]: '0x6080604052' } });
  const order = plan(p, () => addr(1)).map((s) => s.name);
  assert.deepEqual(order, ['SP1Verifier', 'RiscZeroGroth16Verifier', 'EthereumFinalityVerifier', 'RiscZeroFinalityVerifier',
    'EthereumStateReader', 'VaultSnapshot', 'XindexVault', 'VeChainStakerAttester']);
  // The vendored verifiers name themselves once they exist: the node answers for each at the address it got.
  const fetchImpl = async (url, opts) => {
    const r = await node.fetchImpl(url, opts);
    for (const [i, answers] of [[0, SP1_ANSWERS], [1, R0_ANSWERS]]) {
      if (node.sent[i]) node.views[contractAddress(node.sent[i].id, 0)] = answers;
    }
    return r;
  };
  const chain2 = await connect('mainnet', undefined, fetchImpl);
  const d = await deploy(p, chain2, KEY, { log: () => {}, wait: 0 });
  assert.equal(node.sent.length, order.length + 1);
  node.sent.slice(0, order.length).forEach(({ id, tx }, i) => {
    assert.equal(tx.body.chainTag, 0x4a);
    assert.equal(tx.origin.toString().toLowerCase(), DEPLOYER);
    assert.equal(tx.body.clauses.length, 1);
    assert.equal(tx.body.clauses[0].to, null, 'a creation');
    assert.ok(BigInt(tx.body.gas) <= MAX_TX_GAS);
    assert.equal(d[order[i]], contractAddress(id, 0));
  });
  // The vault's creation code carries VaultSnapshot's address where forge left its placeholder.
  const vaultData = node.sent[order.indexOf('XindexVault')].tx.body.clauses[0].data.toLowerCase();
  assert.ok(vaultData.includes(d.VaultSnapshot.slice(2)));
  assert.ok(!vaultData.includes('__$'));
  // The last transaction clears every master, one clause each.
  const clear = node.sent.at(-1).tx.body.clauses;
  assert.equal(clear.length, order.length);
  clear.forEach((c, i) => {
    assert.equal(c.to.toLowerCase(), PROTOTYPE);
    assert.equal(c.data, call('setMaster(address,address)', [d[order[i]], addr(0)]));
  });

  // The wiring, as a node would read it back.
  const a = (x) => '0x' + x.slice(2).padStart(64, '0');
  const v = node.views;
  v[d.XindexVault] = {
    [call('p1() view returns (address)')]: a(d.EthereumFinalityVerifier),
    [call('p2() view returns (address)')]: a(d.RiscZeroFinalityVerifier),
    [call('STATE_READER() view returns (address)')]: a(d.EthereumStateReader),
    [call('FACTORY() view returns (address)')]: a(p.factory),
    [call('HUB_IMPLEMENTATION() view returns (address)')]: a(p.hubImplementation),
    [call('RECOVERY_PROPOSER() view returns (address)')]: a(p.recoveryProposer),
    [call('freezer() view returns (address)')]: a(p.freezer),
    [call('SOURCE_CHAIN_ID() view returns (uint256)')]: word(1),
    [call('cap(address) view returns (uint256)', [addr(0)])]: word(1000),
    [call('outflowFloor(address) view returns (uint256)', [addr(0)])]: word(10),
  };
  const finality = (zkvm, which, key) => ({
    [call(`${which}() view returns (address)`)]: a(zkvm),
    [call(`${which === 'SP1_VERIFIER' ? 'PROGRAM_KEY' : 'IMAGE_ID'}() view returns (bytes32)`)]: key,
    [call('anchor() view returns (bytes32)')]: p.anchor,
    [call('anchorEpoch() view returns (uint64)')]: word(p.anchorEpoch),
    [call('GENESIS_TIME() view returns (uint256)')]: word(MAINNET_GENESIS_TIME),
  });
  v[d.EthereumFinalityVerifier] = finality(d.SP1Verifier, 'SP1_VERIFIER', p.p1ProgramKey);
  v[d.RiscZeroFinalityVerifier] = finality(d.RiscZeroGroth16Verifier, 'RISC_ZERO_VERIFIER', p.p2ImageId);
  v[d.VeChainStakerAttester] = { [call('STAKER() view returns (address)')]: a(STAKER) };
  for (const x of Object.values(d)) node.codes[x] = '0x6080';
  const hashes = await checkDeployment(d, p, chain2);
  assert.deepEqual(Object.keys(hashes), order);

  // Any of it changed is refused: P1 and P2 swapped in the vault, a master still set, a contract without code.
  v[d.XindexVault][call('p1() view returns (address)')] = a(d.RiscZeroFinalityVerifier);
  await refuses('WrongWiring', () => checkDeployment(d, p, chain2));
  v[d.XindexVault][call('p1() view returns (address)')] = a(d.EthereumFinalityVerifier);
  v[d.XindexVault][call('cap(address) view returns (uint256)', [addr(0)])] = word(999);
  await refuses('WrongWiring', () => checkDeployment(d, p, chain2));
  v[d.XindexVault][call('cap(address) view returns (uint256)', [addr(0)])] = word(1000);
  node.masters[d.VaultSnapshot] = 7n;
  await refuses('MasterNotCleared', () => checkDeployment(d, p, chain2));
  node.masters[d.VaultSnapshot] = 0n;
  node.codes[d.VeChainStakerAttester] = '0x';
  await refuses('WrongWiring', () => checkDeployment(d, p, chain2));
});

test('gas: VeChain intrinsic gas, and contract addresses as thor derives them', () => {
  // 5,000, a creation's 48,000, two zero bytes at 4 and one other at 68.
  assert.equal(intrinsicGas([{ to: null, data: '0x000001' }]), 5_000n + 48_000n + 4n + 4n + 68n);
  assert.equal(intrinsicGas([{ to: addr(1), data: '0x' }, { to: addr(2), data: '0x' }]), 5_000n + 2n * 16_000n);
  // The simulation's zero transaction id puts clause 0's contract here: the address mainnet's simulated `$Master` event
  // came from when this repository first probed VeChain's CHAINID.
  assert.equal(contractAddress('0x' + '00'.repeat(32), 0), '0x841a6556c524d47030762eb14dc4af897e605d9b');
});

test('the keystore: the Web3 Secret Storage test vector opens with its password, and only with it', () => {
  // https://ethereum.org/developers/docs/data-structures-and-encoding/web3-secret-storage, the PBKDF2-SHA-256 vector.
  const vector = {
    crypto: {
      cipher: 'aes-128-ctr',
      cipherparams: { iv: '6087dab2f9fdbbfaddc31a909735c1e6' },
      ciphertext: '5318b4d5bcd28de64ee5559e671353e16f075ecae9f99c7a79a38af5f869aa46',
      kdf: 'pbkdf2',
      kdfparams: { c: 262144, dklen: 32, prf: 'hmac-sha256', salt: 'ae3cd4e7013836a3df6bd7241b12db061dbe2c6785853cce422d148a624ce0bd' },
      mac: '517ead924a9d0dc3124507e3393d175ce3ff7c1e96529c6c555ce9e51205e9b2',
    },
  };
  assert.equal(HexUInt.of(unlock(vector, 'testpassword')).toString(), '0x7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d');
  assert.throws(() => unlock(vector, 'another'), (e) => e.code === 'WrongPassword');
});
