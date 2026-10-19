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
    // GT, which no Uniswap route trades, and the bridged GRAM, whose bridge closed. On 2026-10-10 CoinGecko's top 100
    // was read again (design/2026-10-05-token-admission-report.md, "Top 100 of 2026-10-10"): INJ is added; BTW
    // (0x3A63DE3572c69a1307ff08394f3Ee7702C16d25d) has no Pyth feed and no Uniswap pool, and HTX
    // (0x61EC85aB89377db65762E234C946b5c25A56E99e) no Uniswap liquidity, so no fill could rebalance either. SHIB and
    // PEPE, which passed the check, are added on the owner's call of 2026-10-10, which lifts the memecoin exclusion of
    // 4 October for these two. Issued on Ethereum:
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
    /// @dev Shiba Inu, a fixed supply with no owner and no admin function (2026-10-10).
    address internal constant SHIB = 0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE;
    /// @dev Pepe, a fixed supply whose owner is renounced (2026-10-10).
    address internal constant PEPE = 0x6982508145454Ce325dDbE47a25d4ec3d2311933;

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
    /// @dev Injective's original 2020 ERC-20, a fixed supply of 100,000,000 minted once at deployment, with no owner,
    ///      mint, pause or upgrade (verified source, `InjectiveToken`). Added on 2026-10-10 from CoinGecko's top 100,
    ///      read on chain by symbol and decimals and passed by `CheckToken`. Bridged: the coin lives on Injective's own
    ///      chain, and the Peggy bridge's validators tie this token to it.
    address internal constant INJ = 0xe28b3B32B6c345A34Ff64674606124Dd5Aceca30;
    /// @dev Solana's SOL as Wormhole's token bridge wraps it, symbol SOL, name "Wrapped SOL", 9 decimals: the bridge
    ///      (0x3ee18B2214AFF97000D974cf647E7C347E8fa585, Wormhole chain 2) owns it, mints it against SOL locked on
    ///      Solana and burns it on the way back, and is upgraded by the guardians' governance messages. No blacklist.
    ///      Moved here from BNB Chain's Binance-Peg SOL on 2026-10-10 (the owner's call): the only Ethereum copy of a
    ///      Binance-Peg coin that passed `CheckToken` with a Uniswap route.
    address internal constant SOL = 0xD31a59c85aE9D8edEFeC411D448f90841571b89c;

    // ---------------------------------------------------------------------
    // Real-world assets, `Custodial`, added on 2026-10-10 on the owner's call that a blacklist is no bar to listing
    // (design/2026-10-05-token-admission-report.md, "Real-world assets of 2026-10-10"). Each issuer holds the asset and
    // can block and burn any holder's tokens; `CheckToken` refuses XAUT under the WBT rule, and the owner admits it
    // anyway. Read on chain on 2026-10-10 by symbol and decimals.
    // ---------------------------------------------------------------------
    /// @dev Tether Gold, symbol XAUt, 6 decimals: one fine troy ounce of gold Tether holds per token. Tether can
    ///      blacklist a holder and destroy its balance (`destroyBlackFunds`).
    address internal constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    /// @dev Ondo Global Markets tokens, symbol `<ticker>on`, 18 decimals, one share each, the shares held by Ondo's
    ///      custodian. One implementation (`GMToken`) behind each proxy, upgraded through a timelock: a compliance
    ///      contract may block any sender or receiver, `BURNER_ROLE` burns any holder's balance, and a pause manager can
    ///      stop transfers. Most have no Uniswap liquidity: they mint in kind or through `MintRequests`, and a rebalance
    ///      needs an executor that holds them or mints them with Ondo.
    address internal constant NVDAON = 0x2D1F7226Bd1F780AF6B9A49DCC0aE00E8Df4bDEE;
    address internal constant AAPLON = 0x14c3abF95Cb9C93a8b82C1CdCB76D72Cb87b2d4c;
    address internal constant GOOGLON = 0xbA47214eDd2bb43099611b208f75E4b42FDcfEDc;
    address internal constant MSFTON = 0xB812837b81a3a6b81d7CD74CfB19A7f2784555E5;
    address internal constant AMZNON = 0xbb8774FB97436d23d74C1b882E8E9A69322cFD31;
    address internal constant TSMON = 0x3Cafdbfe682aec17d5acE2f97A2f3ab3dCf6a4A9;
    address internal constant SPCXON = 0xc9eef266834730340A55B6CC24621B31BAF55581;
    address internal constant METAON = 0x59644165402b611b350645555B50Afb581C71EB2;
    address internal constant AVGOON = 0x0d54D4279B9E8c54cD8547c2C75A8Ee81A0BcaE8;
    address internal constant TSLAON = 0xf6b1117ec07684D3958caD8BEb1b302bfD21103f;
    address internal constant SKHYON = 0xc0fE36F4FFBDf1B38E192215073590a68f9A2Af7;
    address internal constant MUON = 0x050362Ab1072Cb2Ce74d74770E22A3203Ad04ee5;
    address internal constant LLYON = 0xf192957AE52dB3eb088654403CC2eDeD014ae556;
    address internal constant AMDON = 0x0C1f3412A44Ff99E40bF14e06e5Ea321aE7B3938;
    address internal constant JPMON = 0x03C1EC4CA9DBb168E6Db0DeF827c085999CBffaF;
    address internal constant WMTON = 0x82106347dDbB23cE44Cf4cE4053Ef1adf8b9323B;
    address internal constant VON = 0xaC37c20C1d0E5285035e056101a64e263Ff94a41;

    // ---------------------------------------------------------------------
    // The hundred-coin list, Ethereum-issued: CoinGecko's top 300 on 2026-10-10, less stablecoins, gold, stocks,
    // wrapped or staked derivatives, memecoins beyond SHIB, PEPE and DOGE, and the refused exchange tokens, keeping
    // only coins with a Pyth feed (design/2026-10-10-one-index-wormhole-legs.md, section 2). Each address is
    // CoinGecko's, read on chain on 2026-10-10 by symbol and decimals, and each passed `CheckToken` on a fork at block
    // 26,163,788. Refused by the check that day: LDO (the WBT rule: its MiniMe controller destroys any balance), ZAMA
    // (ERC-1363 callbacks) and NEAR's Rainbow bridge copy (24 decimals). Left for the owner's call: Binance's 2017 BNB
    // ERC-20 (0xB8c77482e45F1F44dE1745F52C74426C631bDD52), which Binance alone redeems; U (United Stables, which may
    // be a stablecoin); and EDGE and BEAM, whose Pyth feeds (EDGEX, BEAM) may name other coins. LEO, WLFI and GRAM
    // stay out under the earlier calls. Two of the 31 left on 2026-10-18, the owner's call after the source reading
    // (design/2026-10-18-token-source-reading.md): The Sandbox's SAND (0x3845badAde8e6dFF049820680d1F14bD3903a5d0),
    // whose two multisig admins and 22 operator contracts can move or burn any holder's balance with no timelock, and
    // Rollbit's RLB (0x046EeE2cc3188071C02BfC1745A6b17c656e3f3d), whose implementation is unverified and upgradeable by
    // one externally owned key. BitTorrent's BTT (0xC669928185DbCE49d2230CC9B0979BE6DC797957), as BTTC's bridge issued
    // it, left on 2026-10-19, the owner's call: that bridge closed in June 2026, so the copy redeems for nothing while
    // it would be priced as native BTT (audit/2026-10-18-red-team.md, RX-28).
    // ---------------------------------------------------------------------
    /// @dev Falcon Finance; no owner and no admin power.
    address internal constant FF = 0xFA1C09fC8B491B6A4d3Ff53A10CAd29381b3F949;
    /// @dev Gnosis; no owner.
    address internal constant GNO = 0x6810e776880C02933D47DB1b9fc05908e5386b96;
    /// @dev Olympus's OHM, 9 decimals.
    address internal constant OHM = 0x64aa3364F17a4D01c6f1751Fd97C2BD3D7e7f1D5;
    /// @dev The Graph.
    address internal constant GRT = 0xc944E90C64B2c07662A292be6244BDf05Cda44a7;
    /// @dev Maple Finance's SYRUP, priced at Pyth's MAPLE FINANCE feed.
    address internal constant SYRUP = 0x643C4E15d7d62Ad0aBeC4a9BD4b001aA3Ef52d66;
    /// @dev Ethereum Name Service; owned by a timelock with a 2-day delay.
    address internal constant ENS = 0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72;
    /// @dev JasmyCoin.
    address internal constant JASMY = 0x7420B4b9a0110cdC71fB720908340C03F9Bc03EC;
    /// @dev Compound.
    address internal constant COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    /// @dev EigenLayer's EIGEN, a proxy upgraded by a 1-of-2 Safe whose owners are a 10-day timelock and a 9-of-13
    ///      Safe, either able to change the token's code alone (read on 2026-10-18).
    address internal constant EIGEN = 0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83;
    /// @dev Axie Infinity.
    address internal constant AXS = 0xBB0E17EF65F82Ab018d8EDd776e8DD940327B28b;
    /// @dev Basic Attention Token.
    address internal constant BAT = 0x0D8775F648430679A709E98d2b0Cb6250d2887EF;
    /// @dev Convex Finance.
    address internal constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    /// @dev Decentraland's MANA; its minter contract is owned by one externally owned key.
    address internal constant MANA = 0x0F5D2fB29fb7d3CFeE444a200298f468908cC942;
    /// @dev Immutable.
    address internal constant IMX = 0xF57e7e7C23978C3cAEC3C3548E3D615c346e79fF;
    /// @dev Fluid.
    address internal constant FLUID = 0x6f40d4A6237C257fff2dB00FA0510DeEECd303eb;
    /// @dev Chiliz, symbol CHZ.
    address internal constant CHZ = 0x3506424F91fD33084466F402d5D97f05F8e3b4AF;
    /// @dev ZKsync's ZK, a proxy upgraded by a contract, whose only minter is ZKsync's L1 Native Token Vault: ZK is
    ///      issued on ZKsync Era, so this is the bridge's copy, tiered Bridged, with ZKsync's bridge as its party (RX-19).
    address internal constant ZK = 0x66A5cFB2e9c529f14FE6364Ad1075dF3a649C0A5;
    /// @dev ApeCoin.
    address internal constant APE = 0x4d224452801ACEd8B2F0aebE155379bb5D594381;
    /// @dev Sentient.
    address internal constant SENT = 0x56A3BA04E95d34268A19b2a4474DC979baBDaf76;
    /// @dev Synthetix, owned by a 4-of-7 Safe.
    address internal constant SNX = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;
    /// @dev 1inch, symbol 1INCH (the identifier cannot start with a digit).
    address internal constant ONEINCH = 0x111111111117dC0aa78b770fA6A738034120C302;
    /// @dev Golem.
    address internal constant GLM = 0x7DD9c5Cba05E151C895FDe1CF355C9A1D5DA6429;
    /// @dev Aethir, owned by a 2-of-3 Safe.
    address internal constant ATH = 0xbe0Ed4138121EcFC5c0E56B40517da27E6c5226B;
    /// @dev Humanity's H, a proxy upgraded by a contract owned by a 4-of-7 Safe.
    address internal constant H = 0xE76c5b78f93909d34404E9eb4C1f19e7582a5dE1;
    /// @dev Plume Network.
    address internal constant PLUME = 0x4C1746A800D224393fE2470C70A35717eD4eA5F1;
    /// @dev Gala, 8 decimals.
    address internal constant GALA = 0xd1d2Eb1B1e90B638588728b4130137D262C87cae;
    /// @dev Wormhole's W, the Ethereum peer of its native-token-transfer mesh, owned by its transfer manager; the coin's home is Solana.
    address internal constant W = 0xB0fFa8000886e57F86dd5264b9582b2Ad87b2b91;
    /// @dev Reserve Rights.
    address internal constant RSR = 0x320623b8E4fF03373931769A31Fc52A4E78B5d70;

    // ---------------------------------------------------------------------
    // Wormhole's copies: coins Ethereum does not have, as Wormhole's token bridge (`WORMHOLE_TOKEN_BRIDGE`) wraps them
    // from the chain that has them (the owner's decision of 2026-10-10). The bridge owns each: it mints against the
    // source token locked on the home chain, burns on the way back, and its guardians' governance can upgrade every
    // copy's code at once, with no timelock. Each is priced at its coin's Pyth feed. `Custodial` when the source is a
    // Binance-Peg BEP-20, since Binance's custody stands under the bridge's; `Bridged` otherwise. None has Uniswap
    // depth: they mint in kind or through `MintRequests`, and a fill needs an executor that bridged them beforehand.
    // Each address was read on 2026-10-10 from the bridge's `wrappedAsset(chain, source)`, which
    // `test/fork/MainnetAddresses.fork.t.sol` repeats, and each passed `CheckToken` at block 26,163,788. BNB's, SUI's
    // and SEI's copies, which that day's count missed, were read the same way on 2026-10-18 and passed `CheckToken` at
    // block 26,215,111; Sui names a coin by its CoinMetadata object, and Sei's bridge a native denom by its keccak256
    // with the first byte set to 1. DOGE's copy
    // (0xd881A7F17Ed2c71FD671AfbA3A9b30Eb914Aea5F, from Binance-Peg DOGE 0xba2ae424d960c26247dd6c32edc70b295c744c43 on
    // BNB Chain) was taken off the list on 2026-10-14, the owner's call, for now: Pyth prices DOGE, not the copy, so
    // a broken peg or bridge leaves the copy priced as DOGE, and the source is a proxy whose admin, one externally
    // owned key, can replace its code (read on BNB Chain that day).
    // ---------------------------------------------------------------------
    /// @dev XRP as the bridge wraps Binance-Peg XRP (0x1d2f0da169ceb9fc7b3144628db156f3f6c60dbe on BNB Chain, Wormhole chain 4): symbol XRP, 18 decimals.
    address internal constant XRP = 0xc730d8256B8A1030eEA67f1Bc7ebed3898f7A535;
    /// @dev ADA as the bridge wraps Binance-Peg ADA (0x3ee2200efb3400fabb9aacf31297cbdd1d435d47 on BNB Chain, Wormhole chain 4): symbol ADA, 18 decimals.
    address internal constant ADA = 0x8EfFbF747d4A60Bc6b68D9A1bE4c4188bA8A3a0b;
    /// @dev LTC as the bridge wraps Binance-Peg LTC (0x4338665cbb7b2485a8855a139b75d5e34ab0db94 on BNB Chain, Wormhole chain 4): symbol LTC, 18 decimals.
    address internal constant LTC = 0x1cA1Ef3fB8Ff4a480C0ae7eea5f91A24a5BB3344;
    /// @dev AVAX as the bridge wraps Avalanche's WAVAX (0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7, Wormhole chain 6): symbol WAVAX, 18 decimals.
    address internal constant AVAX = 0x85f138bfEE4ef8e540890CFb48F620571d67Eda3;
    /// @dev DOT as the bridge wraps Binance-Peg DOT (0x7083609fce4d1d8dc0c979aab8c869ea2c873402 on BNB Chain, Wormhole chain 4): symbol DOT, 18 decimals.
    address internal constant DOT = 0x1839a38E59536D88C25e8E6e0D0f59e05b143ab2;
    /// @dev JUP as the bridge wraps Solana's mint JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN (Wormhole chain 1): symbol JUP, 6 decimals.
    address internal constant JUP = 0x8687a10BCa6F139B25eb31020FCABB5782214764;
    /// @dev ALGO as the bridge wraps Algorand's ALGO itself (asset 0, Wormhole chain 8): symbol ALGO, 6 decimals.
    address internal constant ALGO = 0xe31Cfcd36FeD044ae4Cf9405B577fe875762194F;
    /// @dev ATOM as the bridge wraps Binance-Peg ATOM (0x0eb3a705fc54725037cc9e008bdede697f62f335 on BNB Chain, Wormhole chain 4): symbol ATOM, 18 decimals.
    address internal constant ATOM = 0x7845167B54253269624dBA0cA5Fee87933107b34;
    /// @dev AERO as the bridge wraps Base's 0x940181a94a35a4569e4529a3cdfb74e38fd98631 (Wormhole chain 30): symbol AERO, 18 decimals.
    address internal constant AERO = 0x750525C1877E30304F1E22b1b49b4C9DdE674ddF;
    /// @dev APT as the bridge wraps Aptos's APT itself (0x1::aptos_coin::AptosCoin, Wormhole chain 22): symbol APT, 8 decimals.
    address internal constant APT = 0x8CDf7AF57E4c8B930e1B23c477c22f076530585e;
    /// @dev Pyth Network's PYTH (`PYTH_TOKEN`, since `PYTH` is Pyth's price contract below) as the bridge wraps Solana's mint HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3 (Wormhole chain 1): symbol PYTH, 6 decimals.
    address internal constant PYTH_TOKEN = 0xeFc0CED4B3D536103e76a1c4c74F0385C8F4Bdd3;
    /// @dev OP as the bridge wraps Optimism's 0x4200000000000000000000000000000000000042 (Wormhole chain 24): symbol OP, 18 decimals.
    address internal constant OP = 0x1df721D242E0783F8fCab4A9FfE4F35bdf329909;
    /// @dev BNB as the bridge wraps BNB Chain's WBNB (0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, Wormhole chain 4), the wrapper of BNB itself rather than a Binance-Peg token: symbol WBNB, 18 decimals.
    address internal constant BNB = 0x418D75f65a02b3D53B2418FB8E1fe493759c7605;
    /// @dev SUI as the bridge wraps Sui's SUI itself (0x2::sui::SUI, its CoinMetadata object 0x9258181f5ceac8dbffb7030890243caed69a9599d2886d957a9cb7656af3bdb3, Wormhole chain 21): symbol SUI, 9 decimals.
    address internal constant SUI = 0x84074EA631dEc7a4edcD5303d164D5dEa4c653D6;
    // SEI's copy (0xf91e605af079384cc7077B3914A4a36019a89EE8, Sei's usei from Wormhole chain 32) left on 2026-10-19, the
    // owner's call: it redeems only through Sei's CosmWasm side, which Sei is shutting down (RX-32).

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
    // Bridges. No contract calls one; the app and the fillers do.
    // ---------------------------------------------------------------------
    /// @dev Wormhole's token bridge on Ethereum (Portal), which owns every Wormhole copy above: `wrappedAsset(chain,
    ///      source)` names the copy of a source token, and `isWrappedAsset(token)` says whether a token is one. An
    ///      ERC-1967 proxy the guardians' governance upgrades; its proxy code hash is pinned by
    ///      `test/fork/MainnetAddresses.fork.t.sol`, as Pyth's is. Anyone attests a new source token on its home chain,
    ///      and the bridge deploys its copy here (design/2026-10-10-one-index-wormhole-legs.md, section 5).
    address internal constant WORMHOLE_TOKEN_BRIDGE = 0x3ee18B2214AFF97000D974cf647E7C347E8fa585;

    // ---------------------------------------------------------------------
    // Prices, for v5's weighted indexes only.
    // ---------------------------------------------------------------------
    /// @dev Pyth's contract on Ethereum, from which `WeightedHub` reads every settlement's prices. An ERC-1967 proxy the
    ///      Pyth DAO upgrades by governance message; read on 2026-10-05 at block 26,128,096: version 1.4.6, Wormhole
    ///      chain id 2, update fee 0, implementation 0x3F38404A2e3Cb949bcDfA19a5C3bDf3fE375fEb0. The proxy's code hash
    ///      is pinned by `test/fork/MainnetAddresses.fork.t.sol`; the implementation's is not, since Pyth upgrades it.
    address internal constant PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
}
