// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The Ethereum mainnet contracts and market data the deploy and listing scripts use. This is the only copy:
///         the scripts, the testnet market and the fork tests read it, and `test/fork/MainnetAddresses.fork.t.sol`
///         checks it on-chain (tokens by symbol and decimals, the router and the PoolManager by their code).
library MainnetAddresses {
    // ---------------------------------------------------------------------
    // Components: the Stage A list, the Ethereum tokens of the design's 0.2% weight floor that pass its liquidity
    // screen (design/2026-09-29-v4-hybrid-architecture.md, section 2.1). Checked on 2026-09-22 by symbol and decimals.
    // WBT, also on the floor list, stays off after its check: a single key can blacklist a holder and destroy its
    // balance, and no Uniswap pool holds it (design/2026-09-30-wbt-check.md, the owner's call on 2026-09-30).
    // ---------------------------------------------------------------------
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    // ---------------------------------------------------------------------
    // The wide list: every coin of CoinMarketCap's top 100 on 2026-10-05 with a contract on Ethereum, less
    // stablecoins, gold tokens and memecoins (design/2026-10-05-wide-asset-support.md, section 2), for creators'
    // indexes; the flagship's list above does not change. Each address was taken from CoinGecko and cross-checked
    // against CoinMarketCap and CoinPaprika (or the issuer), then read on chain on 2026-10-05 by symbol and decimals;
    // each passed `CheckToken` (design/2026-10-05-token-admission-report.md). Two of the 29 are left out by the WBT
    // rule: LEO (0x2AF5D2aD76741191D15Dfe7bF6aC92d4Bd912Ca3), whose MiniMe controller destroys any balance and approves
    // every transfer, and WLFI (0xdA5e1988097297dCdc1f90D4dFE7909e847CBeF6), whose owner blacklists and reallocates any
    // holder's balance. Issued on Ethereum:
    // ---------------------------------------------------------------------
    address internal constant QNT = 0x4a220E6096B25EADb88358cb44068A3248254675;
    address internal constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    /// @dev OKX is phasing the Ethereum copy out in favour of X Layer's native OKB (2025-08-13), and its
    ///      OwnedUpgradeabilityProxy is upgraded by a single key.
    address internal constant OKB = 0x75231F58b43240C9718Dd58B4967c5114342a86c;
    address internal constant ENA = 0x57e114B691Db790C35207b2e685D4A43181e6061;
    address internal constant ONDO = 0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3;
    /// @dev Sky, Maker's successor; not MKR.
    address internal constant SKY = 0x56072C95FAA701256059aa122697B133aDEd9279;
    address internal constant WLD = 0x163f8C2467924be0ae7B5347228CABF260318753;
    address internal constant MNT = 0x3c3a81e81dc49A522A592e7622A7E711c06bf354;
    address internal constant MORPHO = 0x58D97B57BB95320F9a05dC918Aef65434969c2B2;
    /// @dev The contract Bitget named on 2024-07-01; the old BGB at 0x19de6b897Ed14A376Dda0Fe53a5420D2aC828a28 answers
    ///      the same symbol, name, decimals and supply.
    address internal constant BGB = 0x54D2252757e1672EEaD234D27B1270728fF90581;
    /// @dev The Polygon Ecosystem Token; not MATIC.
    address internal constant POL = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    /// @dev GateChainToken's 2019 ERC-20; its owner, a single key, can stop every transfer.
    address internal constant GT = 0xE66747a101bFF2dBA3697199DCcE5b743b454759;
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
    /// @dev Toncoin, which CoinGecko and CoinMarketCap now list as Gram (GRAM): the TON bridge's Wrapped TON Coin,
    ///      symbol TONCOIN, 9 decimals. Exchanges reported that bridge closing for good on 2026-09-01.
    address internal constant GRAM = 0x582d872A1B094FC48F5DE31D3B73F2D9bE47def1;
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

    // ---------------------------------------------------------------------
    // Prices, for v5's weighted indexes only.
    // ---------------------------------------------------------------------
    /// @dev Pyth's contract on Ethereum, from which `WeightedHub` reads every settlement's prices. An ERC-1967 proxy the
    ///      Pyth DAO upgrades by governance message; read on 2026-10-05 at block 26,128,096: version 1.4.6, Wormhole
    ///      chain id 2, update fee 0, implementation 0x3F38404A2e3Cb949bcDfA19a5C3bDf3fE375fEb0. The proxy's code hash
    ///      is pinned by `test/fork/MainnetAddresses.fork.t.sol`; the implementation's is not, since Pyth upgrades it.
    address internal constant PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

    // ---------------------------------------------------------------------
    // Reference supplies. Every token carries one, and nothing reads a supply live (CR-M01). Circulating supplies
    // reported by CoinGecko on 2026-09-22, rounded down to whole tokens, in raw units. WBTC and WETH are listed with
    // bitcoin's and ether's supply, because their on-chain supply is only the wrapped float. Revised weekly through a
    // supply batch (`ConfigureWhitelist` supplies mode), each within 0.5% of the figure in force.
    // ---------------------------------------------------------------------
    uint256 internal constant BTC_SUPPLY = 20_087_871e8;
    uint256 internal constant ETH_SUPPLY = 122_070_499e18;
    uint256 internal constant LINK_SUPPLY = 748_099_970e18;
    uint256 internal constant UNI_SUPPLY = 620_716_422e18;

    // ---------------------------------------------------------------------
    // The wide list's reference supplies: circulating supplies reported by CoinGecko on 2026-10-05 (updated between
    // 04:44 and 04:56 UTC), rounded down to whole tokens, in raw units. Beside each, CoinMarketCap's figure at 05:00 UTC
    // the same day, and the difference where it is 0.01% or more; most agree to the token, because both take the
    // issuer's figure. A bridged copy carries its coin's whole circulating supply, as WBTC carries bitcoin's.
    // ---------------------------------------------------------------------
    /// @dev CoinMarketCap 12,072,738 (+20.47%): it leaves out the company treasury.
    uint256 internal constant QNT_SUPPLY = 14_544_176e18;
    /// @dev CoinMarketCap 15,435,383.
    uint256 internal constant AAVE_SUPPLY = 15_435_383e18;
    /// @dev CoinMarketCap 21,000,000; the Ethereum copy's own supply is about 429,064.
    uint256 internal constant OKB_SUPPLY = 21_000_000e18;
    /// @dev CoinMarketCap 10,362,500,000.
    uint256 internal constant ENA_SUPPLY = 10_362_500_000e18;
    /// @dev CoinMarketCap 4,869,330,647.
    uint256 internal constant ONDO_SUPPLY = 4_869_330_647e18;
    /// @dev CoinMarketCap 23,430,516,994.
    uint256 internal constant SKY_SUPPLY = 23_430_551_390e18;
    /// @dev CoinMarketCap 3,798,073,016.
    uint256 internal constant WLD_SUPPLY = 3_798_073_016e18;
    /// @dev CoinMarketCap 3,302,003,382.
    uint256 internal constant MNT_SUPPLY = 3_302_003_382e18;
    /// @dev CoinMarketCap 532,608,523 (+31.44%): it leaves out the DAO's and the Morpho Association's tokens.
    uint256 internal constant MORPHO_SUPPLY = 700_036_111e18;
    /// @dev CoinMarketCap 699,992,029.
    uint256 internal constant BGB_SUPPLY = 699_992_029e18;
    /// @dev CoinMarketCap 10,626,317,694.
    uint256 internal constant POL_SUPPLY = 10_626_317_704e18;
    /// @dev CoinMarketCap 104,663,942.
    uint256 internal constant GT_SUPPLY = 104_663_958e18;
    /// @dev CoinMarketCap 250,000,000.
    uint256 internal constant LIT_SUPPLY = 250_000_000e18;
    /// @dev CoinMarketCap 965,350,000.
    uint256 internal constant ETHFI_SUPPLY = 965_350_000e18;
    /// @dev CoinMarketCap 2,341,485,817 (-1.28%).
    uint256 internal constant FET_SUPPLY = 2_311_508_384e18;
    /// @dev CoinMarketCap 1,569,832,680 (+0.09%).
    uint256 internal constant CRV_SUPPLY = 1_571_278_819e18;
    /// @dev CoinMarketCap 646,145,839 (+54.76%): it leaves out the buyback reserve, which CoinGecko counts.
    uint256 internal constant NEXO_SUPPLY = 1_000_000_000e18;
    /// @dev CoinMarketCap 659,001,770 (-0.09%).
    uint256 internal constant VIRTUAL_SUPPLY = 658_385_841e18;
    /// @dev CoinMarketCap 7,421,949,505.
    uint256 internal constant STRK_SUPPLY = 7_421_949_505e18;
    /// @dev CoinMarketCap 173,634,059.
    uint256 internal constant PENDLE_SUPPLY = 173_634_059e18;
    /// @dev Toncoin's: CoinMarketCap 2,819,624,866. 9 decimals; about 9.29M sit on Ethereum.
    uint256 internal constant GRAM_SUPPLY = 2_819_616_021e9;
    /// @dev Cronos's: CoinMarketCap 49,533,955,328. 8 decimals.
    uint256 internal constant CRO_SUPPLY = 49_533_969_069e8;
    /// @dev Internet Computer's: CoinMarketCap 557,202,386. 8 decimals.
    uint256 internal constant ICP_SUPPLY = 557_202_382e8;
    /// @dev Arbitrum's: CoinMarketCap 6,785,574,605.
    uint256 internal constant ARB_SUPPLY = 6_785_574_605e18;
    /// @dev Render's: CoinMarketCap 518,776,241.
    uint256 internal constant RENDER_SUPPLY = 518_776_241e18;
    /// @dev PancakeSwap's: CoinMarketCap 376,261,104.
    uint256 internal constant CAKE_SUPPLY = 376_261_104e18;
    /// @dev LayerZero's: CoinMarketCap 399,061,088 (-11.46%).
    uint256 internal constant ZRO_SUPPLY = 353_313_325e18;
}
