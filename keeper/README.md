# Xindex v5 rebalancer bot (DRAFT, untested)

Starts rebalances on every index of a v5 factory when anyone may, and fills the auctions of Ethereum-only indexes
(`WeightedHub`) through `src/KeeperExecutor.sol` when the expected profit after gas and swap costs reaches
`MIN_PROFIT_USD`, or the loss stays within `MAX_SUBSIDY_USD`. An index holding vault coins (`HybridHub`) is only
started: its fill needs deliveries on the vault chains and their proofs.

    forge build                      # the executor; deploy it with the bot's key, fund it with a small USDC float,
                                     # and `setRoute(token, path)` for every coin (an exact-input V3 path to USDC)
    npm install
    RPC_URL=... KEEPER_KEY=... FACTORY=... EXECUTOR=... PYTH_API_KEY=... npm start

The bot's key holds no role in the protocol: starting and filling are open to anyone. Use a dedicated, low-balance key.
See the header of `keeper.mjs` for every setting.
