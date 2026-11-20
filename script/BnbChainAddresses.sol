// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Listings} from "./Listings.sol";

/// @notice The BNB Chain contracts the deploy and listing scripts use for the BNB Chain deployment
///         (`design/2026-11-13-bnb-chain-deployment.md`): the tokens its indexes may hold, each with its trust tier,
///         the mint currencies and Uniswap's contracts there. This is the only copy: `DeployChecks`,
///         `ConfigureWeighted` and `CheckToken` read it on chain 56, and `test/fork/BnbChainAddresses.fork.t.sol`
///         checks it on chain (tokens by symbol and decimals, the router, the PoolManager and the V3 factory by their
///         runtime code). No coin carries a price feed: an index rebalances on units alone
///         (`design/2026-11-10-oracle-free-rebalance.md`). Every address here was read on chain 56 on 2026-11-13.
/// @dev The list is the BNB Chain list of 2026-10-07, deleted on 2026-10-13 and restored on 2026-11-13 (the owner's
///      call), less what the owner's later rulings exclude:
///      - DOGE (0xbA2aE424d960c26247Dd6c32edC70B295c744C43), AVAX (0x1CE0c2827e2eF14D5C4f29a091d735A204794041) and
///        FIL (0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153): each is a proxy whose admin, one externally owned key
///        (0xD2f93484f2D319194cBa95C5171B18C1d8cfD6C4), can replace its code. That is the reason DOGE left the
///        Ethereum list on 2026-10-14 and FIL is held (RX-64); the read of 2026-11-13 found the same admin on all
///        three.
///      - TRX (0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3): TRON closed its BTTC bridge on 2026-06-18, the reason
///        BTT left the Ethereum list (RX-28).
///      - Binance-Peg SOL (0x570A5D26f7765Ecb712C0924E4De545B89fD43dF): SOL is held on Ethereum as Wormhole's copy
///        (the owner's call of 2026-10-10).
///      - NIGHT (0xFe930c2d63AeD9b82fC4DBC801920dD2c1a3224F) is refused (the owner's call of 2026-10-06).
///      Backed's wrapped xStocks joined on 2026-11-21 (the owner's call, design/2026-11-21-xstocks.md): the 104 of
///      Ethereum's 109 that Backed has deployed here, at the same addresses, over the same xStocks. AMD, MARA,
///      OKLO, SLV and SPGI have no wrapper on BNB Chain.
library BnbChainAddresses {
    /// @notice BNB Chain's chain id.
    uint256 internal constant CHAIN_ID = 56;
    /// @notice How many coins the list names.
    uint256 internal constant COUNT = 116;

    // ---------------------------------------------------------------------
    // BNB Chain's own coin, wrapped as WETH wraps ether, and the two majors as Binance holds them: BTCB and "ETH" are
    // Binance-Peg tokens, `Custodial`, 18 decimals each.
    // ---------------------------------------------------------------------
    /// @dev "Wrapped BNB", symbol WBNB, 18 decimals: the WETH9 wrapper, `Native`. The zap's wrapped coin here, which
    ///      its ether entry points wrap and unwrap as they do WETH on Ethereum.
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// @dev "BTCB Token", symbol BTCB, 18 decimals: Binance's bitcoin, as WBTC is BitGo's.
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    /// @dev "Ethereum Token", symbol ETH, 18 decimals: Binance-Peg ether.
    address internal constant ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;

    // ---------------------------------------------------------------------
    // Binance-Peg tokens: custodial copies Binance mints with a single key (0xF68a4b64162906efF0fF6aE34E2bB1Cd42FEf62d,
    // each one's `owner()`), the trust tier `Custodial`. None of these seven is a proxy: no key can replace its code.
    // 18 decimals each.
    // ---------------------------------------------------------------------
    address internal constant XRP = 0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE;
    address internal constant ZEC = 0x1Ba42e5193dfA8B03D15dd1B86a3113bbBEF8Eeb;
    address internal constant ADA = 0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47;
    address internal constant BCH = 0x8fF795a6F4D97E7887C79beA79aba5cc76444aDf;
    address internal constant LTC = 0x4338665CBB7B2485A8855A139b75D5e34AB0DB94;
    address internal constant DOT = 0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402;
    address internal constant ATOM = 0x0Eb3a705fc54725037CC9e008bDede697f62F335;

    // ---------------------------------------------------------------------
    // Tokens issued for BNB Chain: ASTER, `Native`, with a fixed supply and no admin power found; STABLE, `Bridged`,
    // a LayerZero OFT behind a proxy whose admin contract (0x386f92606b2D5E0A992ECc3704c31eF39Ff56392) answers to a
    // 3-of-5 Safe (0x2548B8D0FD9277cD4f4b78c79172caEfc46Fd2E6), which sets its peers and upgrades it.
    // ---------------------------------------------------------------------
    address internal constant ASTER = 0x000Ae314E2A2172a039B26378814C252734f556A;
    address internal constant STABLE = 0x011EBe7d75E2C9D1E0bD0be0bEf5C36f0A90075F;

    // ---------------------------------------------------------------------
    // Backed's wrapped xStocks, `Custodial`: each an ERC-4626 vault over one xStock, symbol `w<ticker>x`, 18 decimals,
    // at the address it has on Ethereum and over the same xStock there, read on chain 56 on 2026-11-21. The terms are
    // `MainnetAddresses`' (its wrapped-xStock section): the same implementations, the same ProxyAdmins, the same
    // Safes, keys and sanctions oracle, but every wrapper here is owned by the Safe
    // (0x49754062E35f7591B93cc4F9915965be89643a65).
    // An xStock itself is never listed: its balances move with a multiplier.
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
    /// @dev wSPCEx, over SPCEx (0x7F8ba411ECBC0A135d669d5EaE5D15b0Ca0b0ea1).
    address internal constant WSPCEX = 0x382567e5D72eca3eD2Bb97a4e42918107E09fab0;
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
    // Mint and burn currencies, 18 decimals each on BNB Chain ("Tether USD" and "USD Coin", Binance-Peg). Never
    // components; see the whitelist policy. Nothing in the zap or `MintRequests` assumes a currency's decimals.
    // Binance-Peg USDC is a proxy under the key that holds DOGE's (above): that key can replace its code, which
    // reaches what `MintRequests` holds in USDC escrows and nothing an index holds. USDT is no proxy.
    // ---------------------------------------------------------------------
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    // ---------------------------------------------------------------------
    // Execution. The router is the same build as the Ethereum one the zap is pinned to, byte for byte but for its
    // immutables (compared on 2026-10-07), so the command inputs the zap encodes hold here. The runtime code hashes
    // are pinned by `test/fork/BnbChainAddresses.fork.t.sol`.
    //
    // Ethereum's router address, `MainnetAddresses.UNIVERSAL_ROUTER`, has code on BNB Chain too: a byte-identical
    // replay of Ethereum's deployment, wired to Ethereum's PoolManager address and so to no market here. It is not
    // this book's router. Both routers are CREATE2 deployments anyone can replay onto the other chain, so
    // `DeployChecks` tells chains 1 and 56 by their chain id, and reads a router's code only under any other id.
    // ---------------------------------------------------------------------
    /// @dev Uniswap Universal Router 2.0.0 on BNB Chain, which routes both V3 and V4 pools; answers {POOL_MANAGER}.
    address internal constant UNIVERSAL_ROUTER = 0x1906c1d672b88cD1B9aC7593301cA990F94Eae07;
    /// @dev Uniswap V4's PoolManager on BNB Chain, which the zap reads off the router.
    address internal constant POOL_MANAGER = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
    /// @dev Uniswap V3's factory on BNB Chain, where `CheckToken` looks up a token's Uniswap pools. Most BNB Chain
    ///      depth sits on PancakeSwap, which neither the zap nor `CheckToken` reads, so the depth recorded here is
    ///      what the zap can reach and not the coin's market.
    address internal constant UNISWAP_V3_FACTORY = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;

    /// @notice Every coin of the list: WBNB, BTCB and ETH first, then the Binance-Peg coins, then BNB Chain's own
    ///         tokens, then the wrapped xStocks of 2026-11-21, by ticker.
    function all() internal pure returns (address[] memory tokens) {
        tokens = new address[](COUNT);
        tokens[0] = WBNB;
        tokens[1] = BTCB;
        tokens[2] = ETH;
        tokens[3] = XRP;
        tokens[4] = ZEC;
        tokens[5] = ADA;
        tokens[6] = BCH;
        tokens[7] = LTC;
        tokens[8] = DOT;
        tokens[9] = ATOM;
        tokens[10] = ASTER;
        tokens[11] = STABLE;
        tokens[12] = WAAPLX;
        tokens[13] = WABBVX;
        tokens[14] = WABTX;
        tokens[15] = WACNX;
        tokens[16] = WADBEX;
        tokens[17] = WAMZNX;
        tokens[18] = WAPPX;
        tokens[19] = WASMLX;
        tokens[20] = WASTSX;
        tokens[21] = WAVGOX;
        tokens[22] = WAXPX;
        tokens[23] = WAZNX;
        tokens[24] = WBACX;
        tokens[25] = WBKNGX;
        tokens[26] = WBLKX;
        tokens[27] = WBLSHX;
        tokens[28] = WBMNRX;
        tokens[29] = WBRKBX;
        tokens[30] = WBTBTX;
        tokens[31] = WCLSKX;
        tokens[32] = WCMCSAX;
        tokens[33] = WCOINX;
        tokens[34] = WCORZX;
        tokens[35] = WCOSTX;
        tokens[36] = WCRCLX;
        tokens[37] = WCRMX;
        tokens[38] = WCRWDX;
        tokens[39] = WCSCOX;
        tokens[40] = WCVXX;
        tokens[41] = WDHRX;
        tokens[42] = WEBAYX;
        tokens[43] = WEXPEX;
        tokens[44] = WFIGX;
        tokens[45] = WGLDX;
        tokens[46] = WGLXYX;
        tokens[47] = WGMEX;
        tokens[48] = WGOOGLX;
        tokens[49] = WGSX;
        tokens[50] = WHDX;
        tokens[51] = WHONX;
        tokens[52] = WHOODX;
        tokens[53] = WHSDTX;
        tokens[54] = WHUTX;
        tokens[55] = WIBMX;
        tokens[56] = WIEMGX;
        tokens[57] = WIJRX;
        tokens[58] = WINTCX;
        tokens[59] = WIWMX;
        tokens[60] = WJNJX;
        tokens[61] = WJPMX;
        tokens[62] = WKOX;
        tokens[63] = WLINX;
        tokens[64] = WLLYX;
        tokens[65] = WLULUX;
        tokens[66] = WMAX;
        tokens[67] = WMCDX;
        tokens[68] = WMDTX;
        tokens[69] = WMETAX;
        tokens[70] = WMNSTX;
        tokens[71] = WMRKX;
        tokens[72] = WMRVLX;
        tokens[73] = WMSFTX;
        tokens[74] = WMSTRX;
        tokens[75] = WMUX;
        tokens[76] = WNFLXX;
        tokens[77] = WNVDAX;
        tokens[78] = WNVOX;
        tokens[79] = WOPENX;
        tokens[80] = WORCLX;
        tokens[81] = WPANWX;
        tokens[82] = WPEPX;
        tokens[83] = WPFEX;
        tokens[84] = WPGX;
        tokens[85] = WPLX;
        tokens[86] = WPLTRX;
        tokens[87] = WPMX;
        tokens[88] = WPYPLX;
        tokens[89] = WQQQX;
        tokens[90] = WRBLXX;
        tokens[91] = WRIOTX;
        tokens[92] = WRKLBX;
        tokens[93] = WSBETX;
        tokens[94] = WSCHFX;
        tokens[95] = WSPCEX;
        tokens[96] = WSPYX;
        tokens[97] = WSTRCX;
        tokens[98] = WTX;
        tokens[99] = WTEMX;
        tokens[100] = WTGTX;
        tokens[101] = WTMOX;
        tokens[102] = WTMUSX;
        tokens[103] = WTQQQX;
        tokens[104] = WTSLAX;
        tokens[105] = WTSMX;
        tokens[106] = WUBERX;
        tokens[107] = WUNHX;
        tokens[108] = WVX;
        tokens[109] = WVSTX;
        tokens[110] = WVTX;
        tokens[111] = WVTIX;
        tokens[112] = WWENX;
        tokens[113] = WWMTX;
        tokens[114] = WWULFX;
        tokens[115] = WXOMX;
    }

    /// @notice The tier of a token in the list, as `Listings.tierOf` gives Ethereum's: `Custodial` for every
    ///         Binance-Peg token, BTCB and ETH among them, and every wrapped xStock; `Bridged` for STABLE; `Native`
    ///         for WBNB and ASTER; `Unrecorded` for any token off the list.
    function tierOf(address token) internal pure returns (Listings.Tier) {
        if (token == WBNB || token == ASTER) return Listings.Tier.Native;
        if (token == STABLE) return Listings.Tier.Bridged;
        if (
            token == BTCB || token == ETH || token == XRP || token == ZEC || token == ADA || token == BCH
                || token == LTC || token == DOT || token == ATOM || token == WAAPLX || token == WABBVX || token == WABTX
                || token == WACNX || token == WADBEX || token == WAMZNX || token == WAPPX || token == WASMLX
                || token == WASTSX || token == WAVGOX || token == WAXPX || token == WAZNX || token == WBACX
                || token == WBKNGX || token == WBLKX || token == WBLSHX || token == WBMNRX || token == WBRKBX
                || token == WBTBTX || token == WCLSKX || token == WCMCSAX || token == WCOINX || token == WCORZX
                || token == WCOSTX || token == WCRCLX || token == WCRMX || token == WCRWDX || token == WCSCOX
                || token == WCVXX || token == WDHRX || token == WEBAYX || token == WEXPEX || token == WFIGX
                || token == WGLDX || token == WGLXYX || token == WGMEX || token == WGOOGLX || token == WGSX
                || token == WHDX || token == WHONX || token == WHOODX || token == WHSDTX || token == WHUTX
                || token == WIBMX || token == WIEMGX || token == WIJRX || token == WINTCX || token == WIWMX
                || token == WJNJX || token == WJPMX || token == WKOX || token == WLINX || token == WLLYX
                || token == WLULUX || token == WMAX || token == WMCDX || token == WMDTX || token == WMETAX
                || token == WMNSTX || token == WMRKX || token == WMRVLX || token == WMSFTX || token == WMSTRX
                || token == WMUX || token == WNFLXX || token == WNVDAX || token == WNVOX || token == WOPENX
                || token == WORCLX || token == WPANWX || token == WPEPX || token == WPFEX || token == WPGX
                || token == WPLX || token == WPLTRX || token == WPMX || token == WPYPLX || token == WQQQX
                || token == WRBLXX || token == WRIOTX || token == WRKLBX || token == WSBETX || token == WSCHFX
                || token == WSPCEX || token == WSPYX || token == WSTRCX || token == WTX || token == WTEMX
                || token == WTGTX || token == WTMOX || token == WTMUSX || token == WTQQQX || token == WTSLAX
                || token == WTSMX || token == WUBERX || token == WUNHX || token == WVX || token == WVSTX
                || token == WVTX || token == WVTIX || token == WWENX || token == WWMTX || token == WWULFX
                || token == WXOMX
        ) return Listings.Tier.Custodial;
        return Listings.Tier.Unrecorded;
    }
}
