# Xindex v5 rebalancer bot (DRAFT, untested)

Starts rebalances on every index of a v5 factory when anyone may, and fills the auctions of Ethereum-only indexes
(`WeightedHub`) through `src/KeeperExecutor.sol` when the expected profit after gas and swap costs reaches
`MIN_PROFIT_USD`, or the loss stays within `MAX_SUBSIDY_USD`. `keeper.mjs` only starts an index holding vault coins
(`HybridHub`); `filler.mjs` fills those.

## The cross-chain filler (`filler.mjs`)

A hybrid rebalance settles in three steps, and the filler runs each, resuming after a restart:

1. **accept** – posts the bond (0.1% of the supply, in the index's own shares), delivers the bought Ethereum legs,
   names its address on each vault chain for the sold legs, and brings Pyth's update for the block;
2. **deliver** – deposits the bought vault legs into each chain's vault under the fill's intake id;
3. **settle** – proves each chain's deliveries on Ethereum through its state verifier; the index then pays it the sold
   Ethereum legs and burns the sold vault legs toward its addresses there.

The bond comes back 24 hours after settlement. The filler commits only to deliveries it already holds, on Ethereum and
on each vault chain, since an undelivered fill costs the bond. It buys nothing itself: fund it with the index's shares
for the bond, and with inventory of the coins.

Chains, each an adapter in `chains/` (`deposit`, `intakeProof`, `readDeposited`, `holds`, `recipient`, and `follow`,
which keeps the chain's state verifier on Ethereum within its day):
- BNB Chain (`bnb.mjs`): state proofs from its validators' votes, ported from the testnet relayer in `demo/relayer`.
- Injective (`injective.mjs`): an SP1 proof of CometBFT light-client hops and ICS-23 slot proofs, its input built by
  `proofs/cometbft/fixtures/input.py` and proven on SP1's prover network.
- TRON (`tron.mjs`): an `attest` of the intake digest sent on TRON, proven as a call in a solidified block by
  `tron/proof.py`, which also advances the verifier through TRON's producer lists. Its builders reproduce the
  verifier's mainnet fixture exactly (2026-10-06); nothing else of it has run.
- VeChain (`vechain.mjs`): the vault's `attest` and the Staker attester's in two later rounds, sent with
  `vechain/deploy.mjs`'s path, proven by `proofs/vechain` from `proofs/vechain/fixtures/input.py`'s input, about 90
  minutes after the attest. Its call builder reproduces the mainnet fixture's call exactly (2026-10-06).

Every other vault chain needs its adapter before the filler takes an auction that moves its coins; until then it leaves
those to other executors. The proof builders need `uv` (Python with its packages) and, for SP1 chains, the hosts built
under `proofs/`.

    RPC_URL=... KEEPER_KEY=... FACTORY=... PYTH_API_KEY=... BNB_RPC=... BNB_KEY=... TRON_API=... TRON_KEY=... npm run fill

    forge build                      # at the repo root first: both read its ABIs from out/
    forge build                      # here, the executor; deploy it with the bot's key, fund it with a small USDC float,
                                     # and `setRoute(token, path)` for every coin (an exact-input V3 path to USDC)
    npm install
    RPC_URL=... KEEPER_KEY=... FACTORY=... EXECUTOR=... PYTH_API_KEY=... npm start

The bot's key holds no role in the protocol: starting and filling are open to anyone. Use a dedicated, low-balance key.
See the header of `keeper.mjs` for every setting.
