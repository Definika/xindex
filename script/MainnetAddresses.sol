// SPDX-License-Identifier: BUSL-1.1
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
    ///      They left the list on 2026-11-21, the owner's call: Backed's wrapped xStocks take their place (below). The
    ///      addresses stay for a relisting.
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
    // Backed's wrapped xStocks (the owner's call of 2026-11-21, design/2026-11-21-xstocks.md), `Custodial`: each an
    // ERC-4626 vault (`WrappedBackedTokenImplementation` 1.0.0, 0x14f37168AB9eAFCD94d5b142a00E6e9B261Bad48) over one
    // xStock, symbol `w<ticker>x`, 18 decimals. Backed Assets (JE) issues the xStock against shares its custodian
    // holds.
    // The xStock itself is never listed: its `balanceOf` is its holder's shares times a multiplier, which a dividend
    // raises and a fee or a reverse split lowers, so an index's fixed units would strand every dividend (CF-3) and fall
    // below their backing on a cut (RX-8). A wrapper's balances never change; the multiplier moves its
    // `convertToAssets`. Read on chain on 2026-11-21, the same on every one:
    // - Each wrapper and each xStock is a transparent proxy. ProxyAdmins 0xE39FfFFfB0795c99869ba4bCFE3fD1759d2f0Cc7
    //   (wrappers) and 0x696C685a02A1Fc6E2AaCbe26CD6695F4f4a6a085 (xStocks) answer to one Safe that needs two of three
    //   signatures (0x49754062E35f7591B93cc4F9915965be89643a65). That Safe owns every xStock and sets its roles.
    // - An xStock's minter is one externally owned key (0x0A934Bc9c64309C9654451f23D8331C2DAD34C2a); its burner and
    //   its multiplier updater are another (0x5F7A4c11bde4f218f0025Ef444c369d838ffa2aD), which burns only its own
    //   balance or the token's, never a holder's. That key can set any multiplier above zero, so it reprices every
    //   wrapper; it also owns 53 of the wrappers below, the Safe the others, and the owner names a wrapper's pauser
    //   and its sanctions list.
    // - Both layers can be paused, by a Safe that needs two of four signatures
    //   (0x8768cDA7A463DAe1baA6b2500EFB025ebd7FFC50), and both refuse a sender or receiver Chainalysis' sanctions
    //   oracle lists (0x40C57923924B5c5c5455c48D93317139ADDaC8fb). No wrapper can mint, burn or charge a fee; the
    //   xStocks' automatic fee is zero on every one.
    // - Every wrapper and its xStock answer at the same address on BNB Chain where it is deployed there
    //   (`BnbChainAddresses`).
    // The list is the 118 wrappers Backed's factory (0x3dD6fbDeCb1dEe5ebeB883b12C6Da4d20F45f148) had deployed, less the
    // nine whose share has no Pyth feed that names it: AMBR, DFDV, DUOL, FUFU, TBLL, TONX, TRON and WBD have none, and
    // STRK's feed names Strategy's common stock, not the preferred the xStock holds. Few have a Uniswap pool: they mint
    // in kind or through `MintRequests`, and a rebalance needs an executor that holds them.
    // ---------------------------------------------------------------------
    /// @dev wAAPLx, over AAPLx (0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a).
    address internal constant WAAPLX = 0x5AA7649fdbDa47De64A07aC81D64B682AF9C0724;
    /// @dev wABBVx, over ABBVx (0xfBF2398dF672cEE4aFcC2A4A733222331c742a6A).
    address internal constant WABBVX = 0x5CC079963Fb70C0f987F65F539E3B61a6EBdf6Db;
    /// @dev wABTx, over ABTx (0x89233399708C18Ac6887F90A2B4Cd8Ba5fEdD06e).
    address internal constant WABTX = 0xD812B37181Ae89801e4BB3F49E4C1FAF11fC0b57;
    /// @dev wACNx, over ACNx (0x03183Ce31b1656B72A55fa6056e287f50C35BbEB).
    address internal constant WACNX = 0xc262Bea18cb810Cc7715EE48fe3cbD3D79B4aFe1;
    /// @dev wADBEx, over ADBEx (0x16E0B579be45bAaE54cEddd52e742B6457A7fE12).
    address internal constant WADBEX = 0x444DE06b76C9a1417A21A877038F49A1f0D8A1cD;
    /// @dev wAMDx, over AMDx (0x3522513E5F146a2006e2901b05f16B2821485E19).
    address internal constant WAMDX = 0x1eb8909B5C46A24F005A76C469912f5518F448eF;
    /// @dev wAMZNx, over AMZNx (0x3557Ba345B01EFa20A1bdDC61F573BFD87195081).
    address internal constant WAMZNX = 0xac85d37acbadCa37545E21ab0fB991bcE8c1187C;
    /// @dev wAPPx, over APPx (0x50a1291F69D9d3853Def8209cFb1AF0b46927BE1).
    address internal constant WAPPX = 0xd17E483364D849e3B3A52464bb2CA56626EDfc31;
    /// @dev wASMLx, over ASMLx (0xC0B417e7F83db438631Eb5E096684dd742E5294F).
    address internal constant WASMLX = 0xD0798d3c30F4408350C8448d75DA1c7721227dBa;
    /// @dev wASTSx, over ASTSx (0x89b2607878ae19baB8020b8140eD550Ef3E953bb).
    address internal constant WASTSX = 0x720347faf9D745B841541De0d7B2abc8A4b87531;
    /// @dev wAVGOx, over AVGOx (0x38BAC69cbBd28156796e4163B2B6dcb81E336565).
    address internal constant WAVGOX = 0x8DEb752aAA807E0258afd5cCFFe2b5A804026f28;
    /// @dev wAXPx, over AXPx (0xb23767492D0Ca6dC7221CBeA45689a0410f388c4).
    address internal constant WAXPX = 0x0b306951161b856Ad02c8566B4eF184c6BB08564;
    /// @dev wAZNx, over AZNx (0x5D642505FE1a28897eb3BaBA665F454755D8daA2).
    address internal constant WAZNX = 0xB908FEAeab7E671dB697d77c3acFD8859E92a4e2;
    /// @dev wBACx, over BACx (0x314938c596F5ce31C3f75307d2979338C346D7F2).
    address internal constant WBACX = 0xA2b1335256cd663Da89F650180508dd1f0DC3BAa;
    /// @dev wBKNGx, over BKNGx (0xa8A25DB6Cf17Fa097f1DBbc9c841892456898fF3).
    address internal constant WBKNGX = 0x277f724d12DD0249b48CBD7eB2623c5e5042b970;
    /// @dev wBLKx, over BLKx (0x5A6a0742cA689E7E8a91A38F5255589CB2191646).
    address internal constant WBLKX = 0xE5365A5A16A7D1DD37b33e6F8D78aeB89847398B;
    /// @dev wBLSHx, over BLSHx (0x38DE7b9FC733DeF81525E65C1Bf99722026489e2).
    address internal constant WBLSHX = 0x7a1d054e09eAe0294D53959674EE9DE14a1f70B1;
    /// @dev wBMNRx, over BMNRx (0xaeB681B69E5094E04d11BCeF51A71358A374C3ED).
    address internal constant WBMNRX = 0xBFd29b7F395d30932033c2F45ab792024E71AA94;
    /// @dev wBRK.Bx, over BRK.Bx (0x12992613fDd35aBe95DEc5a4964331b1ee23B50d).
    address internal constant WBRKBX = 0xa150245f155778e749185C9446e9e59E406674eF;
    /// @dev wBTBTx, over BTBTx (0x22E1991e5f82736A2a990322a46aac0e95826c5B).
    address internal constant WBTBTX = 0x88E437dbebdDe3D75Ff7c0cb830F54dd834538f0;
    /// @dev wCLSKx, over CLSKx (0xD0194F0f077968DA8ca59811e9407f54AE6c9432).
    address internal constant WCLSKX = 0xdCE0CA61bC9F95b771e0764dc4C553288b7F2f13;
    /// @dev wCMCSAx, over CMCSAx (0xBC7170a1280Be28513B4e940C681537EB25e39f4).
    address internal constant WCMCSAX = 0xd1A01e3F9c7565e88b1CF2413ba0a0E671e57b33;
    /// @dev wCOINx, over COINx (0x364f210f430eC2448Fc68A49203040F6124096F0).
    address internal constant WCOINX = 0x3a98E79cDc7D8B2716A8696E25af028E429f11dA;
    /// @dev wCORZx, over CORZx (0x51eD5b74A05F256DbD9Ebb4e4f68Bb41ba10160b).
    address internal constant WCORZX = 0x89E2B6cA78DBee629544679780963b85Ba76fe2a;
    /// @dev wCOSTx, over COSTx (0x4720B5e6421e6879132aED52040d56Bb6e5CFeeF).
    address internal constant WCOSTX = 0xFa48FeE923600Fecaa7af0DfB4a66E3109Ad51bf;
    /// @dev wCRCLx, over CRCLx (0xfEbDEd1B0986a8ee107f5AB1a1c5a813491DeCEB).
    address internal constant WCRCLX = 0xA90872ACa656eBE47bDEBF3B19Ec9Dd9C5ADC7f8;
    /// @dev wCRMx, over CRMx (0x4A4073f2EAF299A1be22254DCD2C41727F6F54a2).
    address internal constant WCRMX = 0xc6B6B8D50A6673C04C495e30B411da5A7adF39f5;
    /// @dev wCRWDx, over CRWDx (0x214151022C2a5E380aB80CdaC31f23Ae554a7345).
    address internal constant WCRWDX = 0xD71a6aDBc40c2674591CDB11B8C7ae03A880b06E;
    /// @dev wCSCOx, over CSCOx (0x053C784cD87B74f42e0c089f98643E79c1A3ff16).
    address internal constant WCSCOX = 0xCFa485bc42c2492917351F89F5cf5c7b2C5a66aa;
    /// @dev wCVXx, over CVXx (0xad5cdc3340904285B8159089974A99a1A09EB4C0).
    address internal constant WCVXX = 0x7F88888b7A81546a036554Aa67a289Ea428b20d4;
    /// @dev wDHRx, over DHRx (0xdbA228936F4079DaF9Aa906fd48a87f2300405F4).
    address internal constant WDHRX = 0x6c7AD1886a6Da37766fED060d5F08fF43285DcdD;
    /// @dev wEBAYx, over EBAYx (0x4c7610990cb63cdca174ce61822F7693B49FCe93).
    address internal constant WEBAYX = 0x0c4F0256FB31cC71666Fee3f0cE1De3B1abE347B;
    /// @dev wEXPEx, over EXPEx (0xd1be5bA0c293997C7F69da707D14EB4ABCB13ddD).
    address internal constant WEXPEX = 0x5230C4b621bd2d1f22933903F9a4fA82a9F17fcf;
    /// @dev wFIGx, over FIGx (0x3C313D234D0C6C876F6c21ba2EC1F26823247Be2).
    address internal constant WFIGX = 0x91049e9586301c54B2eF410C2b7e9040Ffb02182;
    /// @dev wGLDx, over GLDx (0x2380F2673C640fB67E2d6B55B44C62F0E0e69DA9).
    address internal constant WGLDX = 0x61532Ce3f1DF7fBf5fFb7B891d184226e85B37c6;
    /// @dev wGLXYx, over GLXYx (0xf7F4fAC56f012dE7Dd6adFF54C761986B9E0655a).
    address internal constant WGLXYX = 0x4c79D4A1a863830EF845431578FB40E31bD51f4A;
    /// @dev wGMEx, over GMEx (0xE5f6d3b2405ABdfE6F660e63202B25D23763160d).
    address internal constant WGMEX = 0xb2f6ED0ED3eEb22bEF7A648794FFC19b8aF3761C;
    /// @dev wGOOGLx, over GOOGLx (0xe92f673Ca36C5E2Efd2DE7628f815f84807e803F).
    address internal constant WGOOGLX = 0x1630F08370917E79df0B7572395a5e907508bBBc;
    /// @dev wGSx, over GSx (0x3Ee7E9B3A992fD23CD1C363B0e296856B04ab149).
    address internal constant WGSX = 0x6eEd78e2780d82BE4E37d9937C27Bcf32C8DA072;
    /// @dev wHDx, over HDx (0x766b0CD6ED6D90B5d49d2c36a3761E9728501BA9).
    address internal constant WHDX = 0xC641E2eBF6E076e2AE53477C2E725b3c67C0fd94;
    /// @dev wHONx, over HONx (0x62a48560861B0b451654bFffdb5be6E47aa8ff1B).
    address internal constant WHONX = 0xBd1B73b2E89967e83507B500D798998200A53380;
    /// @dev wHOODx, over HOODx (0xE1385FDd5ffB10081Cd52C56584F25EFa9084015).
    address internal constant WHOODX = 0x953707d7A1cB30cc5C636bDA8EaeBe410341eB14;
    /// @dev wHSDTx, over HSDTx (0xd457b379801433EA5c3A8542b61902023AE39DcD).
    address internal constant WHSDTX = 0x6Ec2763859C5b04F5598017880744081aFeFa3Bb;
    /// @dev wHUTx, over HUTx (0x560deb3D70Ac90064fF809349cDf9A771a06fd36).
    address internal constant WHUTX = 0x154f25Cfd146d2DF6420ec1f575C3c46D45f4Db7;
    /// @dev wIBMx, over IBMx (0xd9913208647671Fe0F48F7F260076B2C6F310Aac).
    address internal constant WIBMX = 0xa8F31436FFE4E71f51B2D65b7D5a5c457AE2000f;
    /// @dev wIEMGx, over IEMGx (0x6a668332825450ACD2e449372057d31b3de16a1E).
    address internal constant WIEMGX = 0x59361E881b186e48D71EC61E969dCF50a4dbC75b;
    /// @dev wIJRx, over IJRx (0xAA28cB97D7f7E172f54deE950743886D2d65447d).
    address internal constant WIJRX = 0x3ab20fd7c57146AF128E8565261CBdaDa0F015E6;
    /// @dev wINTCx, over INTCx (0xf8A80D1cb9cFD70D03D655D9dF42339846F3B3C8).
    address internal constant WINTCX = 0x6A2a68Ca7FC793D8CEa36326a6Ec1eF7AC3D9742;
    /// @dev wIWMx, over IWMx (0xdadfb355c6110eda0908740d52c834d6C2BCDDc7).
    address internal constant WIWMX = 0x5A47DE111D731Fd2Df90E4A2d7a9b459b31Bd643;
    /// @dev wJNJx, over JNJx (0xdb0482cfaD4789798623E64b15eebA01b16e917C).
    address internal constant WJNJX = 0xcdB53A7cBa9Ec6d55dfE8f58bd6772826722D7BD;
    /// @dev wJPMx, over JPMx (0xD9FC3E075d45254a1D834fEa18AF8041207DeA0A).
    address internal constant WJPMX = 0xaB635f839f81A12dC8Db8Ab31006af14E26292fE;
    /// @dev wKOx, over KOx (0xdCC1a2699441079dA889B1F49e12B69cC791129b).
    address internal constant WKOX = 0x9a2486fbe7bC17C9100be65c31aBE7c9Bf84C23c;
    /// @dev wLINx, over LINx (0x15059c599C16Fd8f70B633Ade165502D6402CD49).
    address internal constant WLINX = 0x316fFEa434348c2cB72024e62Ae845770315351E;
    /// @dev wLLYx, over LLYx (0x19c41EA77b34BbDEe61c3A87A75D1ABDA2ED0be4).
    address internal constant WLLYX = 0x3644971A7E971f60e707F7E8716cCaC5a0461290;
    /// @dev wLULUx, over LULUx (0x847dEB9c78fb00319bC7A006dFF729c11428E537).
    address internal constant WLULUX = 0xD395C4dAd12eb071714d2b86cB5bC16acE9996B6;
    /// @dev wMAx, over MAx (0xb365Cd2588065F522D379AD19e903304f6B622C6).
    address internal constant WMAX = 0x5b32624f352d2FC6cC70889967A143ba1814f82b;
    /// @dev wMARAx, over MARAx (0x9D692bffEf6f6BedF4274053ff9998EFE3B2539E).
    address internal constant WMARAX = 0x34f5273693C880a9B2d9B6cfc8e13A2f3B8C0F06;
    /// @dev wMCDx, over MCDx (0x80A77a372c1e12AcCdA84299492f404902E2DA67).
    address internal constant WMCDX = 0x1717D8Be2Bcb27f4E8f36c817088Fa6a2c0b3B30;
    /// @dev wMDTx, over MDTx (0x0588e851ec0418d660BeE81230d6c678dAF21d46).
    address internal constant WMDTX = 0x02C1b10e5329c4502469396B2ce9f200E60b4a77;
    /// @dev wMETAx, over METAx (0x96702be57Cd9777f835117a809C7124fe4ec989A).
    address internal constant WMETAX = 0x4E41a262cAA93C6575d336E0a4eb79f3c67caa06;
    /// @dev wMNSTx, over MNSTx (0x8499b26BBfC8c3830a37b92E47DF2d7cBc0154e9).
    address internal constant WMNSTX = 0x61a6Cd11f658D1b418e1082b564678983b71Fb7F;
    /// @dev wMRKx, over MRKx (0x17D8186Ed8F68059124190D147174D0f6697dc40).
    address internal constant WMRKX = 0x4728E48c2C201E32fe210AaB68A71E419FEAc74a;
    /// @dev wMRVLx, over MRVLx (0xeAAd46F4146Ded5a47B55AA7F6c48c191dEAEC88).
    address internal constant WMRVLX = 0x0d6fce45796D5c00689c0916b976645a0FF1F0cE;
    /// @dev wMSFTx, over MSFTx (0x5621737f42dAE558b81269FcB9E9E70c19Aa6b35).
    address internal constant WMSFTX = 0x63Ad27614231767C8C489745B9145272De50D09b;
    /// @dev wMSTRx, over MSTRx (0xAE2f842EF90C0d5213259Ab82639D5BBF649b08E).
    address internal constant WMSTRX = 0x266E5923F6118F8b340cA5a23AE7f71897361476;
    /// @dev wMUx, over MUx (0xf6a873BAe4Ba1B304e45dF52A4b7D176E1C6a8c4).
    address internal constant WMUX = 0x529E286229963bE57F0EC6F57d2D70A2F3E29935;
    /// @dev wNFLXx, over NFLXx (0xA6a65AC27E76cD53cB790473E4345c46e5eBf961).
    address internal constant WNFLXX = 0xfE0D2545f9E7f3678CB35Ed3CDf70488C5570D11;
    /// @dev wNVDAx, over NVDAx (0xc845b2894dBddd03858fd2D643B4eF725fE0849d).
    address internal constant WNVDAX = 0x93E62845C1DD5822EbC807ab71A5Fb750DecD15A;
    /// @dev wNVOx, over NVOx (0xF9523E369c5f55ad72DbAA75B0a9b92B3D8b147e).
    address internal constant WNVOX = 0x16E443AEbc83E2089AA90431A1C0d311854EEC69;
    /// @dev wOKLOx, over OKLOx (0x4b0eE7C047D43cA403239f28f42115bEdB7c0076).
    address internal constant WOKLOX = 0x9608a6eB064dd1C35eC9A4332bD9F8b05D1dE66C;
    /// @dev wOPENx, over OPENx (0xbEe6b69345F376598Fe16AbD5592c6F844825E66).
    address internal constant WOPENX = 0x9836479c80823f5f8B60FD0171F8D96301185714;
    /// @dev wORCLx, over ORCLx (0x548308E91ec9F285C7bFf05295baDBD56a6e4971).
    address internal constant WORCLX = 0x54f34Ceb15313Caaee838F77c1c3C2Fe2E94526A;
    /// @dev wPANWx, over PANWx (0xe12BB32D77BE4DB10DDC82088b230D35d097E9C5).
    address internal constant WPANWX = 0x7FbE0E7ACB47DCb053BF6146cCA6Bfb81A5D1319;
    /// @dev wPEPx, over PEPx (0x36c424a6EC0e264b1616102Ad63eD2aD7857413e).
    address internal constant WPEPX = 0xA00A5538708b5aca7045F2ca15104707965bac94;
    /// @dev wPFEx, over PFEx (0x1Ac765B5BEa23184802C7d2d497f7c33f1444A9e).
    address internal constant WPFEX = 0x4E6894c3481B3A45393ce8ac9552945Ad50A3758;
    /// @dev wPGx, over PGx (0xa90424D5D3E770e8644103AB503ed775dD1318FD).
    address internal constant WPGX = 0x0afC19943fA98E9E9E90Fc4ab4d4D3c13E162232;
    /// @dev wPLx, over PLx (0x536825370F1159cBA953055f5c2F16DDc7B5a348).
    address internal constant WPLX = 0xF429759BBf687118efd6B3713303006C356b8765;
    /// @dev wPLTRx, over PLTRx (0x6d482CeC5f9dd1f05CCee9Fd3ff79B246170F8e2).
    address internal constant WPLTRX = 0xa3B6Fe1a923585bb828fCFAa460B78EeFD5aE2EC;
    /// @dev wPMx, over PMx (0x02a6c1789c3B4FDb1a7a3DfA39F90e5d3c94F4F9).
    address internal constant WPMX = 0x7C2e00e6b0d519a8C492d20c2524342A4398FF34;
    /// @dev wPYPLx, over PYPLx (0xf706585e7e8900bE0267bEE3B9A2F70835EC6628).
    address internal constant WPYPLX = 0xCf4953c617CD1306A1f9236084204fBc67FDA2Ac;
    /// @dev wQQQx, over QQQx (0xa753A7395cAe905Cd615Da0B82A53E0560f250af).
    address internal constant WQQQX = 0xdbD9232fee15351068Fe02F0683146e16D9f2cEa;
    /// @dev wRBLXx, over RBLXx (0x5d8dA1417E3565eb02C9ca8cC588bE5D8F65b1c5).
    address internal constant WRBLXX = 0xc1de0BA489E6a5df9ebbA3911e382b455DeDF8c3;
    /// @dev wRIOTx, over RIOTx (0x6Ac47387f0a2798dF4C4eE5bb31ab9517ac97cb8).
    address internal constant WRIOTX = 0xE99c177Bcb254bE2A0333c3B7071c696400Df1cF;
    /// @dev wRKLBx, over RKLBx (0xE17ce7dD2afb6Da3488fD9ef2558523D569e17B4).
    address internal constant WRKLBX = 0xf3f249dBaA9E3e9C9B78b1784cECd954e829aC81;
    /// @dev wSBETx, over SBETx (0x338791c58fdED314b81EAb139A1A2Fb7967D90d6).
    address internal constant WSBETX = 0x9Fd163B1020535C24A3140DB9BB1153E6dEf8fCd;
    /// @dev wSCHFx, over SCHFx (0xF6D87E523512704C29E9b7cA3e9e6226bDCE3EA1).
    address internal constant WSCHFX = 0xB9FCE7dcDfa1962EB53B3e2000554A77F0c10E8b;
    /// @dev wSLVx, over SLVx (0x4833e7f4f0460f4B72A3a5879A6C9841bCC5B58B).
    address internal constant WSLVX = 0x93bd84EE978b60f37df0639f70EAC621e542AD4b;
    /// @dev wSPCEx, over SPCEx (0x7F8ba411ECBC0A135d669d5EaE5D15b0Ca0b0ea1).
    address internal constant WSPCEX = 0x382567e5D72eca3eD2Bb97a4e42918107E09fab0;
    /// @dev wSPGIx, over SPGIx (0xD3c5Af6B2F0F754b2141f368cFc5ea99C3594d3a).
    address internal constant WSPGIX = 0x2f5a59Dd87C57fBfA10a5Ab12fD902C8AFdA2dfD;
    /// @dev wSPYx, over SPYx (0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48).
    address internal constant WSPYX = 0xc88FcD8B874fDb3256E8B55b3decB8c24EAb4c02;
    /// @dev wSTRCx, over STRCx (0x1Aad217B8F78dbA5E6693460e8470F8b1A3977f3).
    address internal constant WSTRCX = 0x34D78E7B06542Dab48f9bf9f0835c7582141314e;
    /// @dev wTx, over Tx (0x75639aE3A05079873D7189DcbDBc455898cAe904).
    address internal constant WTX = 0xb10F7AA3BC0ad9FcE5Fc99702C2022d47BA93827;
    /// @dev wTEMx, over TEMx (0x61AeE4f4e6B62806c26eafF921e7F41782cA2E03).
    address internal constant WTEMX = 0xfa4fFDbf6D53E1539B03823D72886Ab9510250E7;
    /// @dev wTGTx, over TGTx (0xAB6a44AD34D083f463fa6F64d0619F11eB2cb48D).
    address internal constant WTGTX = 0x0420112790C619Fbbd44106bC72ce217b515269A;
    /// @dev wTMOx, over TMOx (0xAF072F109A2C173D822a4fe9af311A1B18F83d19).
    address internal constant WTMOX = 0x89EA0284308dEEF33a22abd7ea33888b4349108C;
    /// @dev wTMUSx, over TMUSx (0x68F3DDEE8BAE33691E7CD0372984fD857E842760).
    address internal constant WTMUSX = 0xF940Fd9D8B80412C47691442075848cc05cD6732;
    /// @dev wTQQQx, over TQQQx (0xfDDDb57878eF9D6f681Ec4381DCB626b9E69AC86).
    address internal constant WTQQQX = 0x3D843414E617CBb9D2328c7eCF155d7C18139D6A;
    /// @dev wTSLAx, over TSLAx (0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0).
    address internal constant WTSLAX = 0x43680aBF18cf54898Be84C6eF78237CFBD441883;
    /// @dev wTSMx, over TSMx (0x9e3bf4Ecfc44EeDD624F26656B6736a3F093b073).
    address internal constant WTSMX = 0x083283FAfD9CEC6145ce6a4A50F020A01737De52;
    /// @dev wUBERx, over UBERx (0xdb9783Ca04bBD64fe2c6d7B9503A979b3DE30729).
    address internal constant WUBERX = 0x4BEa51f138A30329b8855bf0DaE85EA5644Ada82;
    /// @dev wUNHx, over UNHx (0x167A6375DA1eFc4a5BE0f470E73eCEfd66245048).
    address internal constant WUNHX = 0xA0412CE46fE877b7f174B82aCD95E70063BbaF2a;
    /// @dev wVx, over Vx (0x2363FD1235C1B6d3A5088DdF8dF3A0b3A30C5293).
    address internal constant WVX = 0x3cf193acf378Ec224a0209Be888b4b0B963E1896;
    /// @dev wVSTx, over VSTx (0x7AB6C97f65e4227adc5090Bd31a376D1F36f39fa).
    address internal constant WVSTX = 0x92DB84B2358E97976DAD16f91E6aeb9B2A757e76;
    /// @dev wVTx, over VTx (0x6d5edEEbBc6A4099Eb8bb289EB3b80D799f7b28C).
    address internal constant WVTX = 0x48Da55D8FE70A4E3ec421736369BACB8D62Fa089;
    /// @dev wVTIx, over VTIx (0xbD730E618bcD88C82dDeE52e10275CF2f88A4777).
    address internal constant WVTIX = 0xE9161F111c55Bdd67525C1d4F9bbca07750aaAb7;
    /// @dev wWENx, over WENx (0xfEEE18422F8F1cD6193C12aAfad7123DbfF15517).
    address internal constant WWENX = 0x97C4C1704111B7c2304B177C37858B7169c667f9;
    /// @dev wWMTx, over WMTx (0x7AEfc9965699fBea943e03264d96e50CD4A97b21).
    address internal constant WWMTX = 0xa24D9c43D64c76aCD962003647FD43a85eb44Db8;
    /// @dev wWULFx, over WULFx (0xC0c2150cf0870E2d7aBc7cDe17C20A542faFBB9B).
    address internal constant WWULFX = 0xf068165CFf011A56562F855b44CF690e371232C8;
    /// @dev wXOMx, over XOMx (0xEEdb0273c5Af792745180e9fF568cD01550fFA13).
    address internal constant WXOMX = 0x448bC811F60eac772775dD53421380E8D4DC4338;

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
    //
    // The six copies wrapped from BNB Chain (XRP, ADA, LTC, DOT, ATOM and BNB, Wormhole chain 4) were taken off the
    // list on 2026-11-13, the owner's call: BNB Chain's deployment holds those coins in kind (`BnbChainAddresses`),
    // with no bridge under them. Their addresses stay recorded here for a relisting, and
    // `test/fork/MainnetAddresses.fork.t.sol` still checks each against its source.
    //
    // JUP, PYTH, SUI, APT and ALGO were taken off the list on 2026-11-18, the owner's call: with no Ethereum pool, a
    // rebalance can buy them only from stock bridged in from Solana, Sui, Aptos or Algorand, whose restock has never
    // run (design/2026-11-18-bridged-coins-in-a-rebalance.md). Their addresses stay here too, for a relisting.
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
    // OP's copy is off the list since 2026-11-21 (the owner's call), and kept here for a relisting: OP's pools on
    // Optimism were too thin that day for the restock to buy it.
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
    ///      `test/fork/MainnetAddresses.fork.t.sol`. Anyone attests a new source token on its home chain,
    ///      and the bridge deploys its copy here (design/2026-10-10-one-index-wormhole-legs.md, section 5).
    address internal constant WORMHOLE_TOKEN_BRIDGE = 0x3ee18B2214AFF97000D974cf647E7C347E8fa585;
}
