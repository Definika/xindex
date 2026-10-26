# Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) and Node.js for the keeper.

```bash
git clone --recurse-submodules https://github.com/Definika/xindex.git
cd xindex

forge build --sizes --deny warnings    # a compiler warning fails the build, as in CI
forge lint -D notes                    # fails on any warning or note
forge fmt --check
forge test                             # unit, fuzz, invariant and regression tests; no RPC needed
forge coverage                         # 100% on every file
aderyn .                               # static analysis of src/, configured in aderyn.toml; reports nothing

forge test --root keeper               # the keeper's executor, a Foundry project of its own
node --test keeper/test/unit/*.test.mjs
```

## Fork tests

The fork suites run against Ethereum mainnet: the real Universal Router, V3 and V4 pools, USDC, USDT and every listed
token. They are skipped when `MAINNET_RPC_URL` is unset and need an archive node for the pinned block.

```bash
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -j 1
# a non-archive RPC serves only recent state: pin a recent block instead
MAINNET_RPC_URL=https://... FORK_BLOCK=<recent block> forge test --match-path 'test/fork/*'
```

`WeightedHub.fork.t.sol` takes about an hour on a cold RPC cache. `-j 1` keeps a keyed RPC under its rate limit.

## CI

`.github/workflows/test.yml` checks that every submodule commit matches `foundry.lock` and that no committed file names
a path on its author's machine. It then runs fmt, build, lint, the tests with 100% coverage, the ABI diff, the Wake
detectors on `src/` and the keeper's gates, with pinned Foundry and Wake versions. The fork suites run on every push
from this repository. Pull requests from forks get no secrets and skip them, so a maintainer re-runs them before
merging. CI does not run Aderyn yet: run it before pushing.

After an ABI change, regenerate `abi/`:

```bash
for c in IndexZap BasketBuilder MintRequests WeightedIndexFactory WeightedHub; do
  forge inspect $c abi --json > abi/$c.json
done
```
