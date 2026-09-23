// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The Ethereum mainnet contracts and market data the deploy and listing scripts use. This is the only copy:
///         the scripts, the testnet market and the fork tests read it, and `test/fork/MainnetAddresses.fork.t.sol`
///         checks it on-chain (tokens by symbol and decimals, feeds by `description` and `decimals`).
library MainnetAddresses {
    // ---------------------------------------------------------------------
    // Components. Checked on 2026-09-22 by symbol and decimals.
    // ---------------------------------------------------------------------
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @dev Lido wrapped staked ether, 18 decimals. Non-rebasing, so it is an ordinary ERC-20 component.
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    /// @dev Wormhole wrapped SOL, 9 decimals. Its symbol is plain "SOL"; the mainnet ERC-20 is the bridged float, so
    ///      it carries Solana's circulating supply as a reference figure rather than its own.
    address internal constant WSOL = 0xD31a59c85aE9D8edEFeC411D448f90841571b89c;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address internal constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;

    // ---------------------------------------------------------------------
    // Mint and burn currencies. Never components; see the whitelist policy.
    // ---------------------------------------------------------------------
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // ---------------------------------------------------------------------
    // Execution.
    // ---------------------------------------------------------------------
    /// @dev Uniswap Universal Router 2.0.0, which routes both V3 and V4 pools. Pinned to this deployment rather than
    ///      the 2.1.x line, whose V3 inputs carry an extra per-hop price array (`minHopPriceX36`) the zap does not
    ///      encode: a 2.0.0-shaped input reverts SliceOutOfBounds on the labelled 2.1.1 and 2.1.2 releases. One
    ///      unlabelled 2.1-line deployment, 0x0542093271A31f6FC1DADB232bd59eeb27de780F, also carried #491 and #497,
    ///      which upstream later reverted; the labelled releases carry neither (CR-I19). Its runtime code hash is
    ///      pinned by `test/fork/MainnetAddresses.fork.t.sol`, since every build answers `poolManager()` the same way.
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    /// @dev Uniswap V4 singleton the Universal Router settles V4 legs against. The zap reads it from the router
    ///      rather than taking it as an argument, so the two can never be wired to different deployments.
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    // ---------------------------------------------------------------------
    // Price feeds. Chainlink aggregator proxies, all 8 decimals, each checked on 2026-09-22 by `description`. The
    // category is Chainlink's own risk label from its reference data directory (feeds-mainnet.json), read on
    // 2026-09-23; it lives off chain, so no test can pin it, and a change is worth reading before a config is renewed.
    // ---------------------------------------------------------------------
    /// @dev "ETH / USD", 1-hour heartbeat, 0.5% deviation, category low.
    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    /// @dev "wstETH / USD Calculated", 24-hour heartbeat, 0.5% deviation, category custom. Not a market feed: each
    ///      answer is Chainlink's STETH/USD answer (1-hour heartbeat, 1% deviation, category medium) times the
    ///      on-chain `stEthPerToken`, republished about a round later, so it moves in the 1% steps of its input and can
    ///      sit 1-1.5% from ETH x stEthPerToken rather than 0.5% (CR-I17). The stETH peg is priced through it too.
    address internal constant WSTETH_USD_FEED = 0x164b276057258d81941e97B0a900D4C7B358bCe0;
    /// @dev "BTC / USD", 1-hour heartbeat, 0.5% deviation, category low. First leg of WBTC's composite feed.
    address internal constant BTC_USD_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    /// @dev "WBTC / BTC", 24-hour heartbeat, 0.5% deviation, category medium. Second leg of WBTC's composite feed:
    ///      there is no WBTC/USD feed, and the product is what prices a depeg of the wrapper against the coin it wraps.
    address internal constant WBTC_BTC_FEED = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    /// @dev "SOL / USD", 24-hour heartbeat, 2% deviation, category low. It prices wrapped SOL at par with SOL: no
    ///      Wormhole-SOL/SOL feed exists on Ethereum, so unlike WBTC there is no peg leg, and a bridge failure would go
    ///      unpriced until the guardian keeps the component out of a rebalance or it is delisted (CR-L05).
    address internal constant SOL_USD_FEED = 0x4ffC43a60e009B551865A93d232E33Fce9f01507;
    /// @dev "UNI / USD", 1-hour heartbeat, 1% deviation, category low.
    address internal constant UNI_USD_FEED = 0x553303d460EE0afB37EdFf9bE42922D8FF63220e;
    /// @dev "LINK / USD", 1-hour heartbeat, 0.5% deviation, category low.
    address internal constant LINK_USD_FEED = 0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c;
    /// @dev "AAVE / USD", 1-hour heartbeat, 1% deviation, category low.
    address internal constant AAVE_USD_FEED = 0x547a514d5e3769680Ce22B2361c10Ea13619e8a9;

    /// @dev Staleness bound for a feed on a one-hour heartbeat: the heartbeat plus half an hour. The grace covers a
    ///      late round without admitting a dead feed, and the rule caps any bound at its own MAX_FEED_STALENESS.
    uint32 internal constant STALENESS_1H = 5_400;
    /// @dev Staleness bound for a feed on a 24-hour heartbeat, on the same policy. A component priced this way can be
    ///      valued on an answer most of a day old, which its deviation threshold, not its heartbeat, is what bounds.
    uint32 internal constant STALENESS_24H = 88_200;

    // ---------------------------------------------------------------------
    // Reference supplies. Every token carries one: the rule reads no supply live (CR-M01). Circulating supplies
    // reported by CoinGecko on 2026-09-22, rounded down to whole tokens, in raw units, except wstETH's. WBTC, WETH and
    // wrapped SOL are listed with bitcoin's, ether's and solana's supply, because their on-chain supply is only the
    // wrapped or bridged float.
    // ---------------------------------------------------------------------
    uint256 internal constant BTC_SUPPLY = 20_087_871e8;
    uint256 internal constant ETH_SUPPLY = 122_070_499e18;
    uint256 internal constant SOL_SUPPLY = 587_507_739e9;
    uint256 internal constant LINK_SUPPLY = 748_099_970e18;
    uint256 internal constant UNI_SUPPLY = 620_716_422e18;
    uint256 internal constant AAVE_SUPPLY = 15_428_841e18;
    /// @dev wstETH's own `totalSupply` at block 26,039,211 (2026-09-23 09:13 UTC), rounded down to whole tokens: each
    ///      wstETH is a claim on staked ether rather than a bridged copy of a supply that lives elsewhere, so its own
    ///      supply is the right measure. It is a dated figure rather than a live read because `unwrap` burns wstETH and
    ///      `wrap` mints it, and a third of the supply could be flash-borrowed for free, unwrapped around a snapshot
    ///      and wrapped back (CR-M01). Refresh it like every other reference supply. The staked ether behind it is
    ///      counted twice in an index that also holds WETH, once in ether's supply and once here; an index holding
    ///      both is holding two claims on the same asset, which the app labels.
    uint256 internal constant WSTETH_SUPPLY = 3_715_183e18;
}
