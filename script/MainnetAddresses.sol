// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The Ethereum mainnet contracts and market data the deploy and listing scripts use. This is the only copy:
///         the scripts, the testnet market and the fork tests read it, and `test/fork/MainnetAddresses.fork.t.sol`
///         checks it on-chain (tokens by symbol and decimals, the router and the PoolManager by their code).
library MainnetAddresses {
    // ---------------------------------------------------------------------
    // The `default` list's four, first listed for v4's floor and kept for v5. Checked on 2026-09-22 by symbol and
    // decimals. WBT stays off after its check: a single key can blacklist a holder and destroy its balance, and no
    // Uniswap pool holds it (design/2026-09-30-wbt-check.md, the owner's call on 2026-09-30).
    // ---------------------------------------------------------------------
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    // ---------------------------------------------------------------------
    // The wide list: every coin of CoinMarketCap's top 100 on 2026-10-05 with a contract on Ethereum, less
    // stablecoins, gold tokens and memecoins (design/2026-10-05-wide-asset-support.md, section 2), for creators'
    // indexes. Each address was taken from CoinGecko and cross-checked against CoinMarketCap and CoinPaprika (or the
    // issuer), then read on chain on 2026-10-05 by symbol and decimals; each passed `CheckToken`
    // (design/2026-10-05-token-admission-report.md). Two of the 29 are left out by the WBT rule: LEO
    // (0x2AF5D2aD76741191D15Dfe7bF6aC92d4Bd912Ca3), whose MiniMe controller destroys any balance and approves every
    // transfer, and WLFI (0xdA5e1988097297dCdc1f90D4dFE7909e847CBeF6), whose owner blacklists and reallocates any
    // holder's balance. The owner's calls of 2026-10-06 left out four more: OKB, being retired on Ethereum, BGB and
    // GT, which no Uniswap route trades, and the bridged GRAM, whose bridge closed. Issued on Ethereum:
    // ---------------------------------------------------------------------
    address internal constant QNT = 0x4a220E6096B25EADb88358cb44068A3248254675;
    address internal constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address internal constant ENA = 0x57e114B691Db790C35207b2e685D4A43181e6061;
    address internal constant ONDO = 0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3;
    /// @dev Sky, Maker's successor; not MKR.
    address internal constant SKY = 0x56072C95FAA701256059aa122697B133aDEd9279;
    address internal constant WLD = 0x163f8C2467924be0ae7B5347228CABF260318753;
    address internal constant MNT = 0x3c3a81e81dc49A522A592e7622A7E711c06bf354;
    address internal constant MORPHO = 0x58D97B57BB95320F9a05dC918Aef65434969c2B2;
    /// @dev The Polygon Ecosystem Token; not MATIC.
    address internal constant POL = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    /// @dev Lighter.
    address internal constant LIT = 0x232CE3bd40fCd6f80f3d55A522d03f25Df784Ee2;
    address internal constant ETHFI = 0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB;
    /// @dev The Artificial Superintelligence Alliance's FET; the old FET at 0x1D287CC25dAD7cCaF76a26bc660c5F7C8E2a05BD
    ///      answers the same symbol.
    address internal constant FET = 0xaea46A60368A7bD060eec7DF8CBa43b7EF41Ad85;
    address internal constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address internal constant NEXO = 0xB62132e35a6c13ee1EE0f84dC5d40bad8d815206;
    address internal constant VIRTUAL = 0x44ff8620b8cA30902395A7bD3F2407e1A091BF73;
    address internal constant STRK = 0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766;
    address internal constant PENDLE = 0x808507121B80c02388fAd14726482e061B8da827;

    // ---------------------------------------------------------------------
    // The wide list, bridged copies of coins issued elsewhere.
    // ---------------------------------------------------------------------
    /// @dev Cronos's original 2018 ERC-20, 8 decimals; Crypto.com's migration to the native coin runs one way.
    address internal constant CRO = 0xA0b73E1Ff0B80914AB6fe0444E65848C4C34450b;
    /// @dev Internet Computer's copy from the OneSec bridge, 8 decimals, minted by a single key.
    address internal constant ICP = 0x00f3C42833C3170159af4E92dbb451Fb3F708917;
    /// @dev Arbitrum's token on Ethereum, from Arbitrum's own gateway.
    address internal constant ARB = 0xB50721BCf8d664c30412Cfbc6cf7a15145234ad1;
    /// @dev Render's Ethereum token, symbol RNDR; most of it is locked in Wormhole for Solana's RENDER.
    address internal constant RENDER = 0x6De037ef9aD2725EB40118Bb1702EBb27e4Aeb24;
    /// @dev PancakeSwap's LayerZero copy, symbol Cake.
    address internal constant CAKE = 0x152649eA73beAb28c5b49B26eb48f7EAD6d4c898;
    /// @dev LayerZero's ZRO, one peer of its burn-and-mint mesh.
    address internal constant ZRO = 0x6985884C4392D348587B19cb9eAAf157F13271cd;

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
    /// @dev Uniswap V3's factory, where `CheckToken` looks up a token's pools to record its depth before a listing. No
    ///      contract reads it. Its runtime code hash is pinned by `test/fork/MainnetAddresses.fork.t.sol`.
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    /// @dev PancakeSwap's v3 Universal Router, through which the zap runs a leg that names a PancakeSwap V3 path (the
    ///      owner's call on 2026-10-06; `design/2026-10-06-swap-venues.md`). Its immutables wire it to PancakeSwap's V3
    ///      deployer and pool init code hash, its own Permit2 and WETH, so its runtime code hash, pinned by
    ///      `test/fork/MainnetAddresses.fork.t.sol`, fixes all of them. Read on 2026-10-06: owner PancakeSwap's Safe
    ///      0x21835332cBDf1b3530fAE9f6Cd66FEB9477dFC02, not paused. The owner can pause it, which stops the zap's
    ///      PancakeSwap legs and moves nobody's funds.
    address internal constant PANCAKE_UNIVERSAL_ROUTER = 0x65b382653f7C31bC0Af67f188122035461ec9C76;

    // ---------------------------------------------------------------------
    // Prices, for v5's weighted indexes only.
    // ---------------------------------------------------------------------
    /// @dev Pyth's contract on Ethereum, from which `WeightedHub` reads every settlement's prices. An ERC-1967 proxy the
    ///      Pyth DAO upgrades by governance message; read on 2026-10-05 at block 26,128,096: version 1.4.6, Wormhole
    ///      chain id 2, update fee 0, implementation 0x3F38404A2e3Cb949bcDfA19a5C3bDf3fE375fEb0. The proxy's code hash
    ///      is pinned by `test/fork/MainnetAddresses.fork.t.sol`; the implementation's is not, since Pyth upgrades it.
    address internal constant PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
}
