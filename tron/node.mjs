// Writes the configuration of a local single-node TRON chain for the rehearsal, from java-tron's own config.conf at
// the pinned release: one witness with a throwaway key, no peers, and the VM switches TRON mainnet has on. Into node/,
// which git ignores. The key exists only for this local chain.
import { mkdirSync, writeFileSync, existsSync, readFileSync } from 'node:fs';
import { createHash, randomBytes } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { privateKeyToAccount } from 'viem/accounts';

const here = dirname(fileURLToPath(import.meta.url));
export const RELEASE = 'GreatVoyage-v4.8.2.3';
const dir = join(here, 'node');
mkdirSync(dir, { recursive: true });

// The witness: its key, its EVM form and its TRON form (0x41 prefix, base58check).
const witnessFile = join(dir, 'witness.json');
if (!existsSync(witnessFile)) {
  const privateKey = randomBytes(32).toString('hex');
  const evm = privateKeyToAccount(`0x${privateKey}`).address;
  const raw = Buffer.from('41' + evm.slice(2), 'hex');
  const check = createHash('sha256').update(createHash('sha256').update(raw).digest()).digest().subarray(0, 4);
  const ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  let n = BigInt('0x' + Buffer.concat([raw, check]).toString('hex'));
  let tron = '';
  while (n > 0n) { tron = ALPHABET[Number(n % 58n)] + tron; n /= 58n; }
  writeFileSync(witnessFile, JSON.stringify({ privateKey, evm, tron }));
}
const w = JSON.parse(readFileSync(witnessFile, 'utf8'));

const res = await fetch(`https://raw.githubusercontent.com/tronprotocol/java-tron/${RELEASE}/framework/src/main/resources/config.conf`);
if (!res.ok) throw new Error(`java-tron ${RELEASE} config.conf: ${res.status}`);
let c = await res.text();
const edit = (re, to) => { if (!re.test(c)) throw new Error(`config.conf changed shape: ${re}`); c = c.replace(re, to); };
edit(/version = 11111 #[^\n]*/, 'version = 20261001 # a local private chain');
edit(/(seed\.node = \{[\s\S]*?ip\.list = \[)[\s\S]*?(\n  \])/, '$1$2');
edit(/address = "TLLM21wteSPs4hKjbxgmH1L6poyMjeTbHm"/, `address = "${w.tron}"`);
edit(/witnesses = \[[\s\S]*?\n  \]/, `witnesses = [\n    {\n      address: ${w.tron},\n      url = "http://xindex.local",\n      voteCount = 100000000\n    }\n  ]`);
edit(/localwitness = \[\n\]/, `localwitness = [\n  ${w.privateKey}\n]`);
edit(/needSyncCheck = true/, 'needSyncCheck = false');
// Maintenance every 90 seconds (TRON's minimum is 81) and proposals that expire at once, so the rehearsal's proposal to
// set mainnet's CPU limit takes effect at the next maintenance instead of after mainnet's 6 hours and 3 days.
edit(/maintenanceTimeInterval = 21600000/, 'maintenanceTimeInterval = 90000');
edit(/proposalExpireTime = 259200000/, 'proposalExpireTime = 1000');
edit(/supportConstant = false/, 'supportConstant = true');
// A single node has no peers; java-tron otherwise refuses every transaction with NO_CONNECTION.
edit(/minEffectiveConnection = 1/, 'minEffectiveConnection = 0');
// The VM switches TRON mainnet has on (getchainparameters, 1 October 2026), as committee settings of a private chain.
const SWITCHES = [
  'allowCreationOfContracts', 'allowMultiSign', 'allowDelegateResource', 'allowSameTokenName', 'allowTvmTransferTrc10',
  'allowTvmConstantinople', 'allowTvmSolidity059', 'allowTvmIstanbul', 'allowTvmFreeze', 'allowTvmVote', 'allowTvmLondon',
  'allowHigherLimitForMaxCpuTimeOfOneTx', 'allowOptimizedReturnValueOfChainId', 'allowTvmShangHai', 'allowEnergyAdjustment',
  'allowTvmCancun', 'allowTvmBlob', 'changedDelegation', 'allowNewResourceModel', 'allowBlackHoleOptimization',
];
edit(/committee = \{[\s\S]*?\n\}/, 'committee = {\n' + SWITCHES.map((k) => `  ${k} = 1`).join('\n') + '\n}');
writeFileSync(join(dir, 'private.conf'), c);
console.log(`node/private.conf written: witness ${w.tron} (local only)`);
console.log(`start it from tron/node/: java -Xmx3g -jar FullNode-aarch64.jar --witness -c private.conf   (java-tron ${RELEASE}, JDK 17)`);
