# Xindex v5 rebalancer bot (DRAFT, untested)

Starts rebalances on every index of a v5 factory when anyone may, and fills the auctions through
`src/KeeperExecutor.sol` when the expected profit after gas and swap costs reaches `MIN_PROFIT_USD`, or the loss stays
within `MAX_SUBSIDY_USD`. One bot runs per deployment: on Ethereum and on BNB Chain, each with its own `RPC_URL`,
`FACTORY` and `EXECUTOR`.

    forge build                      # at the repo root first: the bot reads its ABIs from out/
    forge build                      # here, the executor; deploy it with the bot's key, fund it with a small USDC float,
                                     # and `setRoute(token, path)` for every coin (an exact-input V3 path to USDC)
    npm install
    RPC_URL=... KEEPER_KEY=... FACTORY=... EXECUTOR=... PYTH_API_KEY=... npm start

The bot's key holds no role in the protocol: starting and filling are open to anyone. Use a dedicated, low-balance key.
See the header of `keeper.mjs` for every setting. Pyth's Hermes needs an API key.
