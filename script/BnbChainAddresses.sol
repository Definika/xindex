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
///      On 2026-11-19 every Ondo stock and ETF Pyth has a feed for joined, 352 in all, each `Custodial`
///      (the owner's call, design/2026-11-22-ondo-stocks-and-etfs.md).
library BnbChainAddresses {
    /// @notice BNB Chain's chain id.
    uint256 internal constant CHAIN_ID = 56;
    /// @notice How many coins the list names.
    uint256 internal constant COUNT = 364;

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
    /// @dev The Ondo stocks and ETFs listed on 2026-11-19 (the owner's call: every Ondo stock and ETF Pyth has a
    ///      feed for, design/2026-11-22-ondo-stocks-and-etfs.md), each the same `GMToken` code as Ethereum's behind
    ///      BNB Chain's beacon (0xc046b05A920e4B412815934DD8E58904dDA73315), read from Ondo's app on 2026-11-19 and on
    ///      chain at block 134,534,714 by symbol and decimals; by the underlying's market cap.
    address internal constant AAPLON = 0x390a684EF9cADE28A7AD0DFa61AB1Eb3842618c4;
    address internal constant MSFTON = 0x6Bfe75D1ad432050eA973C3A3DcD88F02e2444C3;
    address internal constant NVDAON = 0xA9eE28C80f960B889dFbd1902055218cBa016F75;
    address internal constant GOOGLON = 0x091FC7778e6932d4009B087B191D1EE3bac5729A;
    address internal constant GOOGON = 0x817f1f6780F99BCaAc394A59CB0261962df5Da8b;
    address internal constant AMZNON = 0x4553cFe1C09f37f38b12dC509F676964e392F8Fc;
    address internal constant SPCXON = 0xd0a58BC9D88D3FF48C0294Cb7e45937d0E41A928;
    address internal constant TSMON = 0xC37042A7a4fa510D8884a433762aB87257B91965;
    address internal constant AVGOON = 0x0ED2E3180EDf393e6bf8Db124bD15DDD54dE150A;
    address internal constant METAON = 0xD7dF5863A3e742F0c767768cDfcb63f09E0422f6;
    address internal constant TSLAON = 0x2494b603319d4D9F9715c9f4496d9E0364B59d93;
    address internal constant LLYON = 0x341D31b2be1Fee9C00e395A62bA41837F4322EEd;
    address internal constant WMTON = 0xa7d1e886acf66Ec0656DF2DECB4B7C893A3bAb4C;
    address internal constant SKHYON = 0x4268F2Bfb23A7496504AA5eD1Ee325248586299F;
    address internal constant JPMON = 0x317bF42b43A394860718266Dec445DCC9FD9dA49;
    address internal constant IVVON = 0x1104EB7e85E25eB45F88e638b0C27A06C1A91CB2;
    address internal constant MUON = 0x8b6ACf6041A81567f012Ff6A4C6D96d5818d74bF;
    address internal constant AMDON = 0x9f16E46c73b43BDB70861247d537bEE4eA18F639;
    address internal constant SPYON = 0x6a708EAD771238919D85930b5a0f10454E1C331a;
    address internal constant VON = 0x1CdE419faE0Ef7f7931aE3E29e5f411C8C5E5Fa1;
    address internal constant VTION = 0x158734153f354CB326EE690C3d55f810DCb0fc90;
    address internal constant XOMON = 0x4D209D275e3492aC08497A7A42915899c4dD5E86;
    address internal constant JNJON = 0xd1F799cB9f5d0a02951b0755BeCeD6C43882712F;
    address internal constant MAON = 0x25FfDA07F585c39848dB6573E533D7585679C52d;
    address internal constant ASMLON = 0xb034f6Cb52b7f2Fd5a7EeeffCa6b9aDCD6b9A6F6;
    address internal constant ABBVON = 0x8677aBAD7B458bF16a0fB2676DFC7d3f55Ac202A;
    address internal constant COSTON = 0x34375f826fD3dD4E15F883d4F4786bB45eb705ac;
    address internal constant QQQON = 0x0cdE6936d305d5B34667fC46425E852efd73559a;
    address internal constant KOON = 0x405F38B90beBF1259062CF29Da299f3398662bcb;
    address internal constant CVXON = 0xD3113A0AD20a46F6a662C63fe8E637f7713E59c7;
    address internal constant PGON = 0x400F1e257f86D25578A0928C94dC95115F09d5c9;
    address internal constant PLTRON = 0x9351AbD19f42101dD36025E495B98E910b255d78;
    address internal constant CSCOON = 0x34304f2f7cC487eb4186e6D69F5905A613474aA2;
    address internal constant ORCLON = 0x03E4bd1Ea53f1da84513da0319D1f03dD1BBCf93;
    address internal constant GEON = 0x5151A22421Ed4277F1e4ca4785a07b035D548a36;
    address internal constant BACON = 0xd615468088B19FB9d4F03CB3CE9E33876fF3Db99;
    address internal constant HDON = 0x31DAbf49E4BC1Af1456c1819cb6A2562154e92F3;
    address internal constant MRKON = 0x869027261075c3C239D6A26842579b93802606f4;
    address internal constant INTCON = 0xA528CaaA2f96090e379d43F90834C75dF54D6E74;
    address internal constant UNHON = 0x3385Cb29cCA0aC66f5d2354d13ef977b49A2510f;
    address internal constant PANWON = 0x0eAa1a75bd682A5669AB2371A559fBD039C6b9Eb;
    address internal constant AMATON = 0x5ecC352C4640f1d26BD231dbBd171f40f7d0Eec6;
    address internal constant LRCXON = 0x35895a1fa1AFf7FB3204fB01257409Fd75acB24C;
    address internal constant TXNON = 0xCa3a5c955F1F01f20aAcF9501B03E4aa235e478B;
    address internal constant RTXON = 0x44fde2C6Bc2C2b54962C69fcEF57A2A50121DBD7;
    address internal constant TMOON = 0xbCf7D958791152128710565a5fC6f68342Ed71C8;
    address internal constant CRWDON = 0xe6837794FBC6DD024733A1A31F86061296FA2752;
    address internal constant CATON = 0x274B0cB6DB9473245A31cDEA9B789786f4108e4B;
    address internal constant GSON = 0x0D4f9b25F81163Fb4840BA4F434672543823000C;
    address internal constant ANETON = 0x538e2838f9ebC9B891399DF4a8dcc42890D9dc20;
    address internal constant NFLXON = 0x7048F5227b032326cC8DBC53cF3FdDD947a2c757;
    address internal constant WFCON = 0x629520dEE1620dEf11596F84E85de9F1Ff653012;
    address internal constant SAPON = 0x111f6F2B9F1C5f3Ec841690e1deEc606086727dA;
    address internal constant AMGNON = 0xFBdF0366F800CC79d6663DA26bc0BF21FB455Aa6;
    address internal constant LINON = 0xE1743616f705954620aa351465c8885fBDE5A8A9;
    address internal constant IBMON = 0xE8ff70859Ce4cbd72E4352b4fb45F5BF39d07464;
    address internal constant BABAON = 0xd5964f3fcee8D649995AB88F04b8982539c282D2;
    address internal constant AXPON = 0xD803f8777187D6DEe1eA57854aEB957043fb1675;
    address internal constant DISON = 0xeEe9eeE593cB8f7946260B4066CBa7907f40ACFa;
    address internal constant GEVON = 0x2Aea1D415D45CCF3EaBE565d45DcaF4ea2035b9c;
    address internal constant DELLON = 0xf26518958935654878De15BE7bC79A26971583Ba;
    address internal constant ARMON = 0x527C6436E1eAa4f2065CDE4090F798Cb5D031dD6;
    address internal constant CON = 0x8dDB97556F6ae98B4d408c56B167139fE1Cbe3e8;
    address internal constant APHON = 0x70AfC3a600f843d2018dF16B0b316E4BC9c603E9;
    address internal constant MCDON = 0x995ADd4bA29a628A57930a8a185c62cA044eC090;
    address internal constant KLACON = 0xFc263946439b0d802bF4C5a6fCd34E2885259f91;
    address internal constant PEPON = 0xf99F8f3a95257d82006183bd524efa7aaCc9Ef7A;
    address internal constant VTVON = 0xc2dD31B1B3a2f515cE0D48De712c6744C3475170;
    address internal constant VZON = 0xA3B089C886E6d721f49DEF8E050F3b9D4362560B;
    address internal constant ADION = 0x0E246E05212DbBD78A354C072a92B4e5723B2fa0;
    address internal constant IEFAON = 0x918008C3d29496C37b478b611967BeaCA365aF36;
    address internal constant ABTON = 0x5a20886b575058dd7299785f0Ea9b1172942a3E0;
    address internal constant BLKON = 0x24F5471183eA549987f245D6ce236B6108869C92;
    address internal constant QCOMON = 0xfBD4D681C92ead6Af0E49950c8B2e47EeAcbB2dB;
    address internal constant SHOPON = 0x43d0B380c33cD004a6A69aBD61843881a2de4113;
    address internal constant NEEON = 0xe9d43f7E6b2237e8873a7003b3F43c6B03160bE5;
    address internal constant UNPON = 0xfe9aA194E3C4604f3872f220eb41C33A287FCD90;
    address internal constant NVOON = 0x08a513779f46FFb7A34F16094a94016d010128a8;
    address internal constant TMUSON = 0x2588F20BAd92Da8dCCE7FaC8311B5F8Ab4690E43;
    address internal constant DEON = 0x90cCbB75d61Cb65cd73a3ABb5Df04a75961612b7;
    address internal constant SCHWON = 0xe5BA472C98b7E4695bD856290De66bDEDaffC123;
    address internal constant COPON = 0x0D586b51A90Dc999f9bB6A0506Da7F034a1D3A2E;
    address internal constant PFEON = 0x8A83C31D6751833B4940b6e871c48d9A15a07b46;
    address internal constant CRMON = 0xD04a2BB053277721a8321d7441eEd5b42FDF7250;
    address internal constant TON = 0x4255279aF47cf10eFB9A5C8839F90170F4EF759f;
    address internal constant ISRGON = 0x784584933C2192Caa062E90d8140D94768CE62d8;
    address internal constant AGGON = 0x08cE97F3D5Cf11E577D091ab048bC5e2EaE3FABB;
    address internal constant IEMGON = 0x22092c94a91d019Ad15536725598B0A6BE0a73C0;
    address internal constant UBERON = 0xDE9D6036FCA870f7efc5A82722Ae694c371Ac909;
    address internal constant VRTXON = 0x8c9979Dc208f74a5602c38691aa920F121e2f863;
    address internal constant LMTON = 0xd09F7B75b9659b864C6F82bb00Ff096f9D277998;
    address internal constant MRVLON = 0x1501EC83FFEf405B4331CC4f73277a40fb0C627d;
    address internal constant ETNON = 0x4697b2A050f7B5A8e1ebc27c325f9D78D094f041;
    address internal constant ACNON = 0x7aF44d51d1fb88c5b74Fc71d3cba649Bb8099D14;
    address internal constant SPGION = 0x55B370B704240a914f42B5bBB3195431C031f9f8;
    address internal constant APPON = 0xEDB3124e96c64C177Eb709CbC64F9977dB40Ea74;
    address internal constant BAON = 0xf21132A811Ad1A878E21Af60F64d4e690C9DaA42;
    address internal constant STXON = 0x966EbCBA3c51E81f5CF159a1EaBeFd2327aB5E8D;
    address internal constant SCCOON = 0xF15B8f7465b92799F6EE440F86B3CAB5A4dbc65A;
    address internal constant PDDON = 0xF3e82EA164CB344B2b11Bad4c24b0Ea4F7BA4714;
    address internal constant GLDON = 0xfA9a1E901085e269f6D428F79Cd5252d8b919344;
    address internal constant LOWON = 0x2ec46EeD30c94caa5979e6A0395Abe824138335f;
    address internal constant SPOTON = 0x50356167a4DbC38BeA6779C045e24E25fAcEdfdc;
    address internal constant SBUXON = 0x94d7754541B829A87321d56121Bc544167Ac490D;
    address internal constant IJHON = 0x167E93A849A0cc479769132552B99aa1cFA0948c;
    address internal constant SGOVON = 0xc008c5F579ec1450F20099c39F587547e27c7523;
    address internal constant WDCON = 0xcEb29848d04Ad3Cb46E1fE8E45B82ffAc39D797d;
    address internal constant SNDKON = 0x4Fd67CB8CFEdc718BAc984b5936abE3330d0a2A4;
    address internal constant IWFON = 0x40755F06aB7F8dE1ab3a9413b1ef562d63DE19B1;
    address internal constant NETON = 0xfEb0793EEa97585Eb3a541F3FD53450D225b2B87;
    address internal constant COFON = 0x53a8c5fc5643b437779742f494691e6b7C660a8b;
    address internal constant SOON = 0xD7a6353a23ED2c4fcaC29A63CBBe3f65ffEf41F5;
    address internal constant PBRON = 0x2b1d5cDeCC356530a746C5754231EfaEAca64022;
    address internal constant NEMON = 0x5E63232993789601CE362e0240a299C1DfCBfbEc;
    address internal constant ABNBON = 0xEf80743f78d98FC2B47a2253B293152ce8B879ba;
    address internal constant ENBON = 0x5397cB3f1E419050D9d7160756dE0f4eD4f5f898;
    address internal constant EQIXON = 0xE4E12c9CEc3e8cAE405202A97f66AFA695075fa0;
    address internal constant SNOWON = 0x138ED6833ff4E8811E1FEa0D005E13726c8886F9;
    address internal constant REGNON = 0x30BD85fD4286c5c9857679F5B188f737B4a7B8C0;
    address internal constant NOWON = 0xeb19c13c54B1cD48AFc62F6503375e92D5f1e856;
    address internal constant GLWON = 0x25a4DbAE9a0Cd8C75656D6b50FFDf4900CC20d8f;
    address internal constant WMON = 0xCE0466Bae0e867239719dC386CA84b1F3eFE6914;
    address internal constant GDON = 0x5d1a9d8aa362a6424b65Fcb601e52FefcE5b4EFA;
    address internal constant ITOTON = 0xcf9CAf83053213c44dd7027Db3e1E4aC98E55f8f;
    address internal constant CEGON = 0x65D84F0990B7394209d591380C2952c83D778aA3;
    address internal constant PWRON = 0x2418c2e1aE3B8D767594b3974D32610743f88155;
    address internal constant TTON = 0x0Afa28A7Ac4E44b1F771515c200F4d67B1f5e8d0;
    address internal constant EMRON = 0x60B273bDf00a9A52238Ca706257f61efc55bDeE0;
    address internal constant ADBEON = 0xcB22Db0EcB6fe58B7B47db443dCFdfDFbF729CEf;
    address internal constant INTUON = 0x6E3e077A6C0E3c27fD6D00B97387D9b7Bd451BAB;
    address internal constant WMBON = 0x7B7AbD762a400c9768CDeeEF3C01DaE39e0B8427;
    address internal constant CVNAON = 0xc145DC2eBDbe8EAD1fEcDeBF46c76Eb1Fdd0104D;
    address internal constant MRNAON = 0x01486675Da0764ee780Ea7cB65C33062E9B2D28c;
    address internal constant NOCON = 0x4D3442D884202584F1729bCA20Db05472B886B52;
    address internal constant VRTON = 0x9Cea8A7Be1Ab0320b709d368Ad60d8500f55995f;
    address internal constant EFAON = 0x38B9A53bfDc5dba58a29bD6992341927C2fca637;
    address internal constant IWMON = 0x500EAFc69b68Acd6F27064f9B75F1C7d91CC4d9F;
    address internal constant FCXON = 0xE3b17E6D290A0F28bd32aF4064637057627004D5;
    address internal constant SLBON = 0xfaDdE620010736a5074a4269894Cb52B0a9a91DE;
    address internal constant DASHON = 0x7567c2a46BCE46373b454682F3d95e6535BDe144;
    address internal constant APOON = 0x5630B5741A33371D9d935283849A16dC808f7F3A;
    address internal constant MELION = 0x60a8f8e05200fF73aFde9E2caE819bF1605f0BdD;
    address internal constant NTESON = 0x282973969118F9fe39bf2FF3D8DD1EFEE82CCb11;
    address internal constant HOODON = 0x19601179A60f55Ff6636F5D1A8b6671053Bd60a8;
    address internal constant HPEON = 0x492E678c1ea048C70eDc635047cdBB87FF5362a2;
    address internal constant TELON = 0x5C50fFD365c852f5e72BFBc2c1aE621e2ACa5Ece;
    address internal constant NUEON = 0x2155f5344BA7763f80420dE617Af41E56De0552b;
    address internal constant IAUON = 0xcB2a0F46f67dC4c58a316F1c008EDef5c2311795;
    address internal constant AMEON = 0x7a5bD36047A9D15C90FA79b0654De8dd9d6eBbB1;
    address internal constant OXYON = 0x01b5a4aC600bE98448DbEFBB78BcDF38262552cc;
    address internal constant BEON = 0x17D03aE104a9D12E9E5794Efb109B817Dd7f3404;
    address internal constant NKEON = 0x04b5E199F2eC84f78B111035F57b16BeE448dB6F;
    address internal constant LITEON = 0x0fAcaFB97ffDbA3cAe88512070AF49bd30674cD9;
    address internal constant KEYSON = 0x3de956D959726C448649354C6fBCa92B82dC5Ed7;
    address internal constant IBITON = 0x68B07cEf227Cea1b2b6683921C8c825cd5C69Ec7;
    address internal constant BILON = 0x03f09E2EF6e64D804a5579E21E7b519db174cf54;
    address internal constant PYPLON = 0x374D03A6c0d5bd4bE0A5117eBE1B49D52aC8a53F;
    address internal constant TLTON = 0xf69e40069aC227C11459E3f4e8a446b3401616b6;
    address internal constant XYZON = 0xe778A2e5D953c82EB9475cf3B87654226a867344;
    address internal constant CMGON = 0xAed5985afC12aA09d87F55B4b1e6bC3B8f7B0208;
    address internal constant FON = 0xb1ABA049C42B6fe811766EBA61F51f11C57acC4b;
    address internal constant COHRON = 0x0585756aAFB241b0f8A9Df62Db26c566091Bde0b;
    address internal constant NOKON = 0xE9518CB0010C717DB69001F1418EFF9e97330137;
    address internal constant NTRAON = 0x452248f839755c7b777bbC0f6Aa49D7F05EB8020;
    address internal constant IEFON = 0xA486a0A05250E8621bA3B26C3bbc517145eba619;
    address internal constant VSTON = 0xf2C24c47805f4f72d3919C8674bFDd401505794B;
    address internal constant ROKON = 0x95F7423c51Eab71cBD00ca855B0B2B2153F14184;
    address internal constant SOXXON = 0x2A3cbF64C8181DB4a25D41D4d7a7Db9984C59DAC;
    address internal constant DYNFON = 0x96A1b43C8146E6D1f6e66B226A3c520CbE3d8a50;
    address internal constant STMON = 0x8B46599e0E80a34F37e97DF58E741ca904cdfaBd;
    address internal constant TTWOON = 0xf095607F8aB6F8f813a1F93F70047ec2f0A8bd85;
    address internal constant CIENON = 0x89a9F7114bE6b220fAe645ba0cbB720889867415;
    address internal constant ALABON = 0x573e11CC667A8E5BE0c7Af2410403371088D3d0D;
    address internal constant MSTRON = 0x7313EA16493b2f55054Df0131A3A14B043ec8992;
    address internal constant VNQON = 0x10b58A3d9DCeC59bB1c3bf6b9c9414eAfCE711C9;
    address internal constant TERON = 0x6F040fC3061374304BddbfdAe9d688d7C868c785;
    address internal constant RKLBON = 0xb4D695569236273745B4CD54B539b1b9Cc1513af;
    address internal constant UMCON = 0x318ddd4d03d84A40cf44772385A0CFB3D4394049;
    address internal constant JDON = 0xE92bE960aE64F6a914Ca77014CaC9E56DE7f36C1;
    address internal constant JAAAON = 0x84719A1082ed487c7eeac7d69885E3CC2009Ea78;
    address internal constant CLSON = 0x7b695132b165cb6703F0212bBB1e91A782526156;
    address internal constant STLDON = 0x90EAa91Af0B4559F1F270258Bb5cDDFafbb62da9;
    address internal constant EQTON = 0x9A1C88ac479906A7f03e76605b15B72DF10d8E51;
    address internal constant NBISON = 0xee268780473E7a0e47baC41547C6E01512555A16;
    address internal constant INSMON = 0xaC0919D699eE1725d30d5ceD86cfd553C33DC36A;
    address internal constant PCGON = 0x47B36DDB9dd12A8411f78226f55e8c3f0D65481f;
    address internal constant COINON = 0xf8589b526FdD65F7F301c605a6e04F0F1b4B3620;
    address internal constant TQQQON = 0xe42CfB20e00912409B77A602B5BDcfF3c7aCC5F4;
    address internal constant EFVON = 0x40375E3Dd70232eaF264706e5662b90A079e3D31;
    address internal constant FLEXON = 0x102138be022f8D142bcB817F7264921d65209608;
    address internal constant SHYON = 0xf95e50BE5Efc96117c28775F80C7Cdb41Ebc4888;
    address internal constant VRSNON = 0x37fF203Ac221313B620d047eddD7bD6F68d656a6;
    address internal constant CCJON = 0xa75F08b9a91439DAac9cc7072857cC0a98Cf527A;
    address internal constant CRWVON = 0x76E39171Cb665a35981e744e2CEB7012F76caEAc;
    address internal constant TCOMON = 0x6459303F58244Ff1E7A42b90aA3782Dfb6Ca6969;
    address internal constant EEMON = 0x00c81d35edDF44c75d4Db9E07bDCdC236eB0ebcf;
    address internal constant ONON = 0xB35a9EAB5D25282f4e668798B629a9294e9A47aa;
    address internal constant HALON = 0x7A18bB5FD6Ba6343180AfDCf6Dc406eF17F7fC04;
    address internal constant CPNGON = 0x19904Bc04c09e5d29Ed216dDD105bdf103A0bA2D;
    address internal constant JBLON = 0x8D941EbB4921f8d43CFA65233B14A547f96559fc;
    address internal constant BIDUON = 0x467e59ce5D5fe01686D4A80dd1E1DAE13549AA6c;
    address internal constant CRDOON = 0xf157481bEBd0C0686780fd0F61806C900A6137e8;
    address internal constant CBRSON = 0x441a4D4Fc23f17F4cf23E3d60F12d2BD6F176728;
    address internal constant SLVON = 0x8b872732b07be325a8803CDB480D9d20B6f8d11B;
    address internal constant HUBBON = 0x1C42C07257F936a7c4f84B8D756c95817E23631A;
    address internal constant IYWON = 0xbEeEF4361F6603eDAceF5205b343C6bb6473A099;
    address internal constant EWJON = 0x82715299f3f132FB85f3De1F7e8fAfd3d79f3eB5;
    address internal constant GFSON = 0xAff6b836d3eBd29aEb0C8b840Add04EF79d79678;
    address internal constant ENTGON = 0xfB4a89A077B9020C7101b1Af760BEB708F37a416;
    address internal constant USFRON = 0xf4fd75764A5C086fb12F822be2cA318b3a362DC3;
    address internal constant EWYON = 0x12B7aDC48416A103F63E7e6210f62C81dfB91fD0;
    address internal constant SWKSON = 0x7Bd821eAad82cb92C1eA64DaC1f3bB2E787E959A;
    address internal constant SOFION = 0x71507068e98049cBA81E9bbc8d901E4A2f4222Eb;
    address internal constant HYGON = 0x0DAE81A905b645a3D1E67129b89CD0Acda224E9A;
    address internal constant NVTON = 0x484Ce83BB55b50D70236C7D1E29E0Ba7524f905B;
    address internal constant RDDTON = 0x4DA12f47578ef89c76179b760C778E70b668f80b;
    address internal constant MTSION = 0x1dCd320C5d7b84CD407437c58d56CbbDd0D9d8f3;
    address internal constant RIVNON = 0x277E1FA8704c5511FEd7E30Bc691F922aa30101B;
    address internal constant LSCCON = 0x80F03ABCb2BD85237740dD69f87d2F5De3909012;
    address internal constant SMCION = 0xC142ba8ccD36d80C3a001342fb83E4C3d218A873;
    address internal constant TLNON = 0xbbE4Dfe7a349Fb72aEc6f52d5CD9bDD78AE8f313;
    address internal constant WCCON = 0x82436bAE31AE373258bA567f32087eeFc32189F2;
    address internal constant TSEMON = 0x343324170C91c4D8Cf4D439B3E5a619F50621aE7;
    address internal constant LECOON = 0x43807bf4ce06F4fbb4FA8DEac37BF274AEa324Da;
    address internal constant MKSION = 0xd41699aA1BfC1c5f172c27f387372bd30717a5db;
    address internal constant TIPON = 0x2Ac26EC236df5D1d2Ad1A6Dd4E448A90E45DC35D;
    address internal constant CRCLON = 0x992879Cd8ce0c312d98648875B5A8D6D042cbF34;
    address internal constant MTZON = 0xf49046aAE76EAeb7ffd3EF116ce0f7CD0F52d93e;
    address internal constant IWNON = 0xF54b94eA21e1Da5d51eF00fd4502225e5394F874;
    address internal constant GMEON = 0xdABb9afF4cf02f26D2014e4cA9f94aC6fe6572a3;
    address internal constant SOXLON = 0xb943c8a0d77b656Daf5244Da060D647Fd9152289;
    address internal constant PAVEON = 0x6f28Cb07790c1049ecd7482d09Fd13B977B47201;
    address internal constant FUTUON = 0x5acf40056ED51C8bBCD1b125Ef803581Ac89A627;
    address internal constant IGVON = 0xA046C2F0A1Ac0a0E8829eFc12163ae892CEAfAc2;
    address internal constant GRABON = 0xab2F74804C022C5249d52e743AF4340E42F5f3b6;
    address internal constant GNRCON = 0x237c9F794EDAaA0071cDF64a41c25EB76771754b;
    address internal constant FNON = 0xA1DaaB37dA2a29A1eC721922b55962eB8B481001;
    address internal constant ITAON = 0x88B90f45bd6a4F97f7D85d280eD64A40880e4935;
    address internal constant HIION = 0x4Dc8dCeE22a56fEECa930dfF45581aa9A14D5E05;
    address internal constant IONQON = 0x40d8E1fbaf69173c47fa493FeB50a84eeC6b57eE;
    address internal constant LION = 0x9810beac9af3C30d14cFB61cDd557E160f60FD50;
    address internal constant ALBON = 0x0B790ABd6594918DE1022233b7cc79baDB84d92a;
    address internal constant ONTOON = 0x2F79d36184DfE7968C9d23f87cAe1aB72447c1e5;
    address internal constant PINSON = 0xCfD1F0DF84300EA1a4e2BA5238043A2fA5A7237c;
    address internal constant NVMION = 0x8a5f83A4b3AD2B9604F53c4dDf8DcE1329f9d433;
    address internal constant BMNRON = 0x52AD57A7eA642E99A892AFc79E937B383f1b59e9;
    address internal constant SNAPON = 0xF325884D9bcac457271fE7F7B6be1765348fCCa2;
    address internal constant FIGON = 0x93fac02b22B6743423381D163aec418178019B7a;
    address internal constant AIQON = 0x333932F15E6E14f4a630163D3224548a721DdfA4;
    address internal constant AMKRON = 0xb84e150A1d18380cFeEeBCdE8756368dD489A1A3;
    address internal constant AALON = 0x02D608506cA0048D0D991a11F1E7Fb8CAD1e44f8;
    address internal constant RMBSON = 0x49ccB157c77AFE5F264C35f0e9178a98D77815Ab;
    address internal constant OSCRON = 0xB0752Aa50B089EE6eA9aCD51373207Fa460E87bb;
    address internal constant TWSTON = 0x820f09C2EBe7852E14a1310008BF7aF4d29d4F09;
    address internal constant EWZON = 0x9876F4b879cDe9Aa49Ffd260034A0698B7B33A49;
    address internal constant ASTSON = 0x45Abf29515bc23F8c0Ed2a06584444cE473A75FB;
    address internal constant AURON = 0x66a1409FE303d00209202933e3d31eE43AaAB39d;
    address internal constant TTMION = 0xF400b05AD5A791c65Acc3f905E5aDe5F1B653c8c;
    address internal constant HUTON = 0x3A82f1C847cc55e52e597fD81c63a812C6722541;
    address internal constant VICRON = 0xa59469D91563CaeedDd2ffC731f41215E7b691ef;
    address internal constant INDAON = 0xdB0748297fbEf0B33dF89e86519A0BD3adAf6459;
    address internal constant CLFON = 0xaC38a6608868e2f487d7993EA7339C69e5AB077b;
    address internal constant NIOON = 0xC6f9eDbeE6042a237D72493bBdA3eE2c3c62F708;
    address internal constant RIOTON = 0xC4a88a72B848255Fd24Da3C1aD6755D980535FB1;
    address internal constant MPON = 0x4BAf4dC56Cf6a525a0874e25cc6372A6A8915135;
    address internal constant FORMON = 0xD678F3F86436Ee298d28A3C414c367aDFeD65337;
    address internal constant IRENON = 0x8FD70eE385f470c8D6FDA2D93a4E49C849BAC6a6;
    address internal constant WULFON = 0xaD56701D9e57957e28e546Db7db508A16d4f86CC;
    address internal constant FPSON = 0xd8dAFFd168651470cd5397A5D670DD5F8E4b02f5;
    address internal constant FIGRON = 0x620477782cEa4C4171165396F8014EdEF83a13da;
    address internal constant POWLON = 0xD381aec27DAAcCC87F102FF4Ad6652F8b5F20bA0;
    address internal constant SHLDON = 0xe5ca1585c6053EE891027fD0A2548cB3B27D7f01;
    address internal constant AGON = 0xa2a97e3d6140e8ccD058f3b84230F3E1a349b1a3;
    address internal constant CAION = 0x3f41bCF043a07Ca9DC734f24b0a77C01CBfA0E8D;
    address internal constant ETHAON = 0x04B16ff1F9673146F68AA5d5F57aA45AdcF068E1;
    address internal constant COPXON = 0xEC93fE7Ff4B09CA3CCAFBc4CC9615E62BE412780;
    address internal constant CORZON = 0x25eD86472cf3012607DC6576c58e6432968255C2;
    address internal constant BILION = 0x91fc7371d6dE682A1e8CFcB4EB7dA693312A03a4;
    address internal constant MXLON = 0x5Cb7671740877723c9aD55348a751D7B57052E07;
    address internal constant APLDON = 0x18De24acb876C0B8392d9C55583Bb21c0355980b;
    address internal constant PLON = 0xf9015E0b3AB4ddd216F522D6150dB826c9BE83f8;
    address internal constant KWEBON = 0x7437203800140BA7d9081ddE8cEF09EE40E3Bf03;
    address internal constant OKLOON = 0xaF6C03acf72355Ce98d0741302B78870b376428C;
    address internal constant URAON = 0xc7806943663158D68740a14ab0B270bD60BDe87D;
    address internal constant VSHON = 0x821aEf7d0F4347bB9EA6f293a98b19d823EEF0C5;
    address internal constant HIMSON = 0x4693f6F5EF257381a28afd0673e64d8b32d5C6aD;
    address internal constant AAOION = 0x149Bda9e7251DC36f536d1fE7F92A5ea203F4F3D;
    address internal constant FXION = 0x9b8E987e6fEc8Cf1380C4dcA7071e2C7853AEEA1;
    address internal constant PRIMON = 0xD60b0276640a693ece55660afAC0383ca6433882;
    address internal constant CIFRON = 0xDad07D0Ca26ed4109Bc00893dBee3Ed4cE8ce2a4;
    address internal constant ENPHON = 0x30938154E2697694F41592C2e48459287dEBe4BF;
    address internal constant BLSHON = 0xFBE22D27B6e153244882fD7bdfE7C6109918281B;
    address internal constant QBTSON = 0x8C7Bf0ED6bc778bde1489De1592C1aAd3E66371d;
    address internal constant UECON = 0xE7ddF606841ee278A30E5C90486681e68ddd8cbF;
    address internal constant RGTION = 0xEd2a500eB2b66679e0BbD76e51a60049aE5f3271;
    address internal constant BOTZON = 0xb42f5597EAdd424de67b46Fe5d1EC4b61367A4e5;
    address internal constant PENGON = 0x2144d620E3471441b12Bf256E01a09EAA5ea7F12;
    address internal constant ONDSON = 0xd85d4Ce29b4cA361FF72Ef0E53D6236e334C5DB6;
    address internal constant AMCON = 0x1d7B5e06fdbe4FD33f5C64C081E32B5d539751D0;
    address internal constant USARON = 0x2206E07410A8fE9Ef595e7184B2E9d160fdb7211;
    address internal constant SOXQON = 0x15688f10470dFdDCb4E2d60CD2ACfd3eC418317a;
    address internal constant GRNDON = 0x20CCe48D767eD68CBbA7727c4c504eFE5Bcb626c;
    address internal constant ACHRON = 0x91C62325F901EE29Da8E521CfE68980332A4Ca06;
    address internal constant MARAON = 0xd226d8170EE38793430C7Dec6903df4B818BB74C;
    address internal constant GLXYON = 0xF98B89825233808CD37706A53D2b4Ae3e359d442;
    address internal constant AXTION = 0x0C50323AF81D5C33822c6Add256Fb9093D42BC74;
    address internal constant OUSTON = 0x30033A17ea24E90631532582a1917c64AFBF87Af;
    address internal constant NVTSON = 0xB56B7C2F9988448790B0F78697F405aB5e8597E6;
    address internal constant USOON = 0x94174e3D1335db402dD03A092f7aA7ac2cb32be4;
    address internal constant SQQQON = 0x17515B68378d86C38F394c666e79907dA05dcBA9;
    address internal constant RXRXON = 0xCB6D74afF24AFc94514727eE0FCDA6bb6B64f3F9;
    address internal constant SOXSON = 0x335DD4112704f108b5Ddd8F8a44Bd9ed68522a80;
    address internal constant LUNRON = 0xA3b7B7cfEb023a6C4f444f5ca9a3Fc85809Ece15;
    address internal constant OIHON = 0x31D6011023D6c7695Efc29bB016830F3F36De40a;
    address internal constant RDWON = 0x23e39D94807a8bb7e3f8294b4911D04EE26DcE39;
    address internal constant PURRON = 0x89CC700F308a4C59889fBF3286216554C53B0601;
    address internal constant DNNON = 0x70bd780076E25D087Ed9c35f4e4A540522Abe8cF;
    address internal constant AION = 0xBb8c10f7E828E3279df8CC3397A5212F845C509b;
    address internal constant AEHRON = 0xdCE0957E22F7baf2AA1a50d854e03cEe6f215004;
    address internal constant WENON = 0x79ed7f4d9668E8e7AaadD12A711d19064840B9A5;
    address internal constant PPLTON = 0x3EC23F52F6573FC0587A0631dd8C3b107f6bcb35;
    address internal constant SMRON = 0xf4b674D4E33c36F8db4b928A5eEC4E1F87b386e3;
    address internal constant URNMON = 0xCa626a74420aAaf285987Da23d829f9159Ab867c;
    address internal constant UUUUON = 0xD2C06fef2ca2375a9C7ceB4AbcA9DBc2aB6aF981;
    address internal constant SOUNON = 0xeDCF71B2e2217064038AdCb54A3C3a5fC3488eF1;
    address internal constant PLUGON = 0x4752AE8f910b25e64E4406eAad50c1B4E8DE7E6D;
    address internal constant IGEBON = 0x9e609E96B688927aa49Dcd9758E2081f0c48ccAB;
    address internal constant SEDGON = 0x8755c5C39b1AA9053a83AC731242a2cf4D04B0Fe;
    address internal constant WOLFON = 0x55b56CC2cdcbC2C58668F72663bE7599a46Ed79F;
    address internal constant OPENON = 0xa09699fc0cbb1F85128450A0ff6a3c4d3A7E7B9B;
    address internal constant QUBTON = 0x82E07C1017032cFd889b1Ca81EBe722c4D4de825;
    address internal constant KEELON = 0x5e3cA19c533C8C0381eac5319624596557C279ED;
    address internal constant INODON = 0x517A25e696421C88218B43cbb7EA0f873B6973A6;
    address internal constant SBETON = 0x99e01F02d66455Bb106D91D469c9EAF6aB4904f6;
    address internal constant BTDRON = 0x3A562836AFB1026F5D7A6B6dA1125D27fdfeE372;
    address internal constant BBAION = 0x7BA995f1662A01f3bE0DC299ce94Bb7e9C7075f5;
    address internal constant BNOON = 0x5f2d37192576a6804F44722eB828E280D5FB43Dc;
    address internal constant PSQON = 0x3802dc739eF9E226f36421A9c15eFa519153bBBe;
    address internal constant CPERON = 0x0888EDfeC4C0A66FCE074796CF4F6509c00f6c49;
    address internal constant FCELON = 0x47Bfe4921Bd74C66c6B0C35C517aBdFB5E3BAFb3;
    address internal constant FLNCON = 0xF1a96d4B591E446445600789D60C73Dd636B357c;
    address internal constant NNEON = 0x3c276Dd9f9Eab5510f9eAfD3a6Ea54879b27CA3D;
    address internal constant BOTON = 0xC43Ae29aFE58bf90dA6Fe3Edd570C2E735fb2850;
    address internal constant PALLON = 0x3fCD741646A9790635b938Cdb69af5Df356CbaAB;
    address internal constant BTGOON = 0x5fA699c0c1319b8D86489AF77dFDe4Fa97B47DF8;
    address internal constant LPTHON = 0x6AD19E0A57Cfea0bC521A12C6c82372852842933;
    address internal constant EXODON = 0x92d504158A8Dc69de989dB5EDe3230D958fb8630;
    address internal constant BWETON = 0x472F46C5D7409C82234701EFf7D4DDA4c28B5a93;
    address internal constant BAION = 0x2659Dd96deF34ceD3679901E5500779BE297fE5a;
    address internal constant DRAMON = 0x087b5761b161429013d41eA54cd2fb6022A21564;
    address internal constant SATAON = 0x732823512Ba98D1BCDE471ca023ee2A0C9f117b7;
    address internal constant STRCON = 0x71E9dc9DEbc18650BD2342B93623B88C2aD00c89;

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
    /// @dev Pyth's price contract, a proxy, through which the factory's `PythPrices` reads the price a fill is checked
    ///      against (the owner's call of 2026-11-22). A filler posts a fresh update to it in its own transaction. Read
    ///      on chain that day: it answers `priceFeedExists` for ETH/USD, and `DeployChecks` resolves it as it does the
    ///      router.
    address internal constant PYTH = 0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594;

    /// @notice Every coin of the list: WBNB, BTCB and ETH first, then the Binance-Peg coins, then BNB Chain's own
    ///         tokens.
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
        tokens[12] = AAPLON;
        tokens[13] = MSFTON;
        tokens[14] = NVDAON;
        tokens[15] = GOOGLON;
        tokens[16] = GOOGON;
        tokens[17] = AMZNON;
        tokens[18] = SPCXON;
        tokens[19] = TSMON;
        tokens[20] = AVGOON;
        tokens[21] = METAON;
        tokens[22] = TSLAON;
        tokens[23] = LLYON;
        tokens[24] = WMTON;
        tokens[25] = SKHYON;
        tokens[26] = JPMON;
        tokens[27] = IVVON;
        tokens[28] = MUON;
        tokens[29] = AMDON;
        tokens[30] = SPYON;
        tokens[31] = VON;
        tokens[32] = VTION;
        tokens[33] = XOMON;
        tokens[34] = JNJON;
        tokens[35] = MAON;
        tokens[36] = ASMLON;
        tokens[37] = ABBVON;
        tokens[38] = COSTON;
        tokens[39] = QQQON;
        tokens[40] = KOON;
        tokens[41] = CVXON;
        tokens[42] = PGON;
        tokens[43] = PLTRON;
        tokens[44] = CSCOON;
        tokens[45] = ORCLON;
        tokens[46] = GEON;
        tokens[47] = BACON;
        tokens[48] = HDON;
        tokens[49] = MRKON;
        tokens[50] = INTCON;
        tokens[51] = UNHON;
        tokens[52] = PANWON;
        tokens[53] = AMATON;
        tokens[54] = LRCXON;
        tokens[55] = TXNON;
        tokens[56] = RTXON;
        tokens[57] = TMOON;
        tokens[58] = CRWDON;
        tokens[59] = CATON;
        tokens[60] = GSON;
        tokens[61] = ANETON;
        tokens[62] = NFLXON;
        tokens[63] = WFCON;
        tokens[64] = SAPON;
        tokens[65] = AMGNON;
        tokens[66] = LINON;
        tokens[67] = IBMON;
        tokens[68] = BABAON;
        tokens[69] = AXPON;
        tokens[70] = DISON;
        tokens[71] = GEVON;
        tokens[72] = DELLON;
        tokens[73] = ARMON;
        tokens[74] = CON;
        tokens[75] = APHON;
        tokens[76] = MCDON;
        tokens[77] = KLACON;
        tokens[78] = PEPON;
        tokens[79] = VTVON;
        tokens[80] = VZON;
        tokens[81] = ADION;
        tokens[82] = IEFAON;
        tokens[83] = ABTON;
        tokens[84] = BLKON;
        tokens[85] = QCOMON;
        tokens[86] = SHOPON;
        tokens[87] = NEEON;
        tokens[88] = UNPON;
        tokens[89] = NVOON;
        tokens[90] = TMUSON;
        tokens[91] = DEON;
        tokens[92] = SCHWON;
        tokens[93] = COPON;
        tokens[94] = PFEON;
        tokens[95] = CRMON;
        tokens[96] = TON;
        tokens[97] = ISRGON;
        tokens[98] = AGGON;
        tokens[99] = IEMGON;
        tokens[100] = UBERON;
        tokens[101] = VRTXON;
        tokens[102] = LMTON;
        tokens[103] = MRVLON;
        tokens[104] = ETNON;
        tokens[105] = ACNON;
        tokens[106] = SPGION;
        tokens[107] = APPON;
        tokens[108] = BAON;
        tokens[109] = STXON;
        tokens[110] = SCCOON;
        tokens[111] = PDDON;
        tokens[112] = GLDON;
        tokens[113] = LOWON;
        tokens[114] = SPOTON;
        tokens[115] = SBUXON;
        tokens[116] = IJHON;
        tokens[117] = SGOVON;
        tokens[118] = WDCON;
        tokens[119] = SNDKON;
        tokens[120] = IWFON;
        tokens[121] = NETON;
        tokens[122] = COFON;
        tokens[123] = SOON;
        tokens[124] = PBRON;
        tokens[125] = NEMON;
        tokens[126] = ABNBON;
        tokens[127] = ENBON;
        tokens[128] = EQIXON;
        tokens[129] = SNOWON;
        tokens[130] = REGNON;
        tokens[131] = NOWON;
        tokens[132] = GLWON;
        tokens[133] = WMON;
        tokens[134] = GDON;
        tokens[135] = ITOTON;
        tokens[136] = CEGON;
        tokens[137] = PWRON;
        tokens[138] = TTON;
        tokens[139] = EMRON;
        tokens[140] = ADBEON;
        tokens[141] = INTUON;
        tokens[142] = WMBON;
        tokens[143] = CVNAON;
        tokens[144] = MRNAON;
        tokens[145] = NOCON;
        tokens[146] = VRTON;
        tokens[147] = EFAON;
        tokens[148] = IWMON;
        tokens[149] = FCXON;
        tokens[150] = SLBON;
        tokens[151] = DASHON;
        tokens[152] = APOON;
        tokens[153] = MELION;
        tokens[154] = NTESON;
        tokens[155] = HOODON;
        tokens[156] = HPEON;
        tokens[157] = TELON;
        tokens[158] = NUEON;
        tokens[159] = IAUON;
        tokens[160] = AMEON;
        tokens[161] = OXYON;
        tokens[162] = BEON;
        tokens[163] = NKEON;
        tokens[164] = LITEON;
        tokens[165] = KEYSON;
        tokens[166] = IBITON;
        tokens[167] = BILON;
        tokens[168] = PYPLON;
        tokens[169] = TLTON;
        tokens[170] = XYZON;
        tokens[171] = CMGON;
        tokens[172] = FON;
        tokens[173] = COHRON;
        tokens[174] = NOKON;
        tokens[175] = NTRAON;
        tokens[176] = IEFON;
        tokens[177] = VSTON;
        tokens[178] = ROKON;
        tokens[179] = SOXXON;
        tokens[180] = DYNFON;
        tokens[181] = STMON;
        tokens[182] = TTWOON;
        tokens[183] = CIENON;
        tokens[184] = ALABON;
        tokens[185] = MSTRON;
        tokens[186] = VNQON;
        tokens[187] = TERON;
        tokens[188] = RKLBON;
        tokens[189] = UMCON;
        tokens[190] = JDON;
        tokens[191] = JAAAON;
        tokens[192] = CLSON;
        tokens[193] = STLDON;
        tokens[194] = EQTON;
        tokens[195] = NBISON;
        tokens[196] = INSMON;
        tokens[197] = PCGON;
        tokens[198] = COINON;
        tokens[199] = TQQQON;
        tokens[200] = EFVON;
        tokens[201] = FLEXON;
        tokens[202] = SHYON;
        tokens[203] = VRSNON;
        tokens[204] = CCJON;
        tokens[205] = CRWVON;
        tokens[206] = TCOMON;
        tokens[207] = EEMON;
        tokens[208] = ONON;
        tokens[209] = HALON;
        tokens[210] = CPNGON;
        tokens[211] = JBLON;
        tokens[212] = BIDUON;
        tokens[213] = CRDOON;
        tokens[214] = CBRSON;
        tokens[215] = SLVON;
        tokens[216] = HUBBON;
        tokens[217] = IYWON;
        tokens[218] = EWJON;
        tokens[219] = GFSON;
        tokens[220] = ENTGON;
        tokens[221] = USFRON;
        tokens[222] = EWYON;
        tokens[223] = SWKSON;
        tokens[224] = SOFION;
        tokens[225] = HYGON;
        tokens[226] = NVTON;
        tokens[227] = RDDTON;
        tokens[228] = MTSION;
        tokens[229] = RIVNON;
        tokens[230] = LSCCON;
        tokens[231] = SMCION;
        tokens[232] = TLNON;
        tokens[233] = WCCON;
        tokens[234] = TSEMON;
        tokens[235] = LECOON;
        tokens[236] = MKSION;
        tokens[237] = TIPON;
        tokens[238] = CRCLON;
        tokens[239] = MTZON;
        tokens[240] = IWNON;
        tokens[241] = GMEON;
        tokens[242] = SOXLON;
        tokens[243] = PAVEON;
        tokens[244] = FUTUON;
        tokens[245] = IGVON;
        tokens[246] = GRABON;
        tokens[247] = GNRCON;
        tokens[248] = FNON;
        tokens[249] = ITAON;
        tokens[250] = HIION;
        tokens[251] = IONQON;
        tokens[252] = LION;
        tokens[253] = ALBON;
        tokens[254] = ONTOON;
        tokens[255] = PINSON;
        tokens[256] = NVMION;
        tokens[257] = BMNRON;
        tokens[258] = SNAPON;
        tokens[259] = FIGON;
        tokens[260] = AIQON;
        tokens[261] = AMKRON;
        tokens[262] = AALON;
        tokens[263] = RMBSON;
        tokens[264] = OSCRON;
        tokens[265] = TWSTON;
        tokens[266] = EWZON;
        tokens[267] = ASTSON;
        tokens[268] = AURON;
        tokens[269] = TTMION;
        tokens[270] = HUTON;
        tokens[271] = VICRON;
        tokens[272] = INDAON;
        tokens[273] = CLFON;
        tokens[274] = NIOON;
        tokens[275] = RIOTON;
        tokens[276] = MPON;
        tokens[277] = FORMON;
        tokens[278] = IRENON;
        tokens[279] = WULFON;
        tokens[280] = FPSON;
        tokens[281] = FIGRON;
        tokens[282] = POWLON;
        tokens[283] = SHLDON;
        tokens[284] = AGON;
        tokens[285] = CAION;
        tokens[286] = ETHAON;
        tokens[287] = COPXON;
        tokens[288] = CORZON;
        tokens[289] = BILION;
        tokens[290] = MXLON;
        tokens[291] = APLDON;
        tokens[292] = PLON;
        tokens[293] = KWEBON;
        tokens[294] = OKLOON;
        tokens[295] = URAON;
        tokens[296] = VSHON;
        tokens[297] = HIMSON;
        tokens[298] = AAOION;
        tokens[299] = FXION;
        tokens[300] = PRIMON;
        tokens[301] = CIFRON;
        tokens[302] = ENPHON;
        tokens[303] = BLSHON;
        tokens[304] = QBTSON;
        tokens[305] = UECON;
        tokens[306] = RGTION;
        tokens[307] = BOTZON;
        tokens[308] = PENGON;
        tokens[309] = ONDSON;
        tokens[310] = AMCON;
        tokens[311] = USARON;
        tokens[312] = SOXQON;
        tokens[313] = GRNDON;
        tokens[314] = ACHRON;
        tokens[315] = MARAON;
        tokens[316] = GLXYON;
        tokens[317] = AXTION;
        tokens[318] = OUSTON;
        tokens[319] = NVTSON;
        tokens[320] = USOON;
        tokens[321] = SQQQON;
        tokens[322] = RXRXON;
        tokens[323] = SOXSON;
        tokens[324] = LUNRON;
        tokens[325] = OIHON;
        tokens[326] = RDWON;
        tokens[327] = PURRON;
        tokens[328] = DNNON;
        tokens[329] = AION;
        tokens[330] = AEHRON;
        tokens[331] = WENON;
        tokens[332] = PPLTON;
        tokens[333] = SMRON;
        tokens[334] = URNMON;
        tokens[335] = UUUUON;
        tokens[336] = SOUNON;
        tokens[337] = PLUGON;
        tokens[338] = IGEBON;
        tokens[339] = SEDGON;
        tokens[340] = WOLFON;
        tokens[341] = OPENON;
        tokens[342] = QUBTON;
        tokens[343] = KEELON;
        tokens[344] = INODON;
        tokens[345] = SBETON;
        tokens[346] = BTDRON;
        tokens[347] = BBAION;
        tokens[348] = BNOON;
        tokens[349] = PSQON;
        tokens[350] = CPERON;
        tokens[351] = FCELON;
        tokens[352] = FLNCON;
        tokens[353] = NNEON;
        tokens[354] = BOTON;
        tokens[355] = PALLON;
        tokens[356] = BTGOON;
        tokens[357] = LPTHON;
        tokens[358] = EXODON;
        tokens[359] = BWETON;
        tokens[360] = BAION;
        tokens[361] = DRAMON;
        tokens[362] = SATAON;
        tokens[363] = STRCON;
    }

    /// @notice The tier of a token in the list, as `Listings.tierOf` gives Ethereum's: `Custodial` for every
    ///         Binance-Peg token, BTCB and ETH among them; `Bridged` for STABLE; `Native` for WBNB and ASTER;
    ///         `Unrecorded` for any token off the list.
    function tierOf(address token) internal pure returns (Listings.Tier) {
        if (token == WBNB || token == ASTER) return Listings.Tier.Native;
        if (token == STABLE) return Listings.Tier.Bridged;
        if (
            token == BTCB || token == ETH || token == XRP || token == ZEC || token == ADA || token == BCH
                || token == LTC || token == DOT || token == ATOM
        ) return Listings.Tier.Custodial;
        if (
            token == AAPLON || token == MSFTON || token == NVDAON || token == GOOGLON || token == GOOGON
                || token == AMZNON || token == SPCXON || token == TSMON || token == AVGOON || token == METAON
                || token == TSLAON || token == LLYON || token == WMTON || token == SKHYON || token == JPMON
                || token == IVVON || token == MUON || token == AMDON || token == SPYON || token == VON || token == VTION
                || token == XOMON || token == JNJON || token == MAON || token == ASMLON || token == ABBVON
                || token == COSTON || token == QQQON || token == KOON || token == CVXON || token == PGON
                || token == PLTRON || token == CSCOON || token == ORCLON || token == GEON || token == BACON
                || token == HDON || token == MRKON || token == INTCON || token == UNHON || token == PANWON
                || token == AMATON || token == LRCXON || token == TXNON || token == RTXON || token == TMOON
                || token == CRWDON || token == CATON || token == GSON || token == ANETON || token == NFLXON
                || token == WFCON || token == SAPON || token == AMGNON || token == LINON || token == IBMON
                || token == BABAON || token == AXPON || token == DISON || token == GEVON || token == DELLON
                || token == ARMON || token == CON || token == APHON || token == MCDON || token == KLACON
                || token == PEPON || token == VTVON || token == VZON || token == ADION || token == IEFAON
                || token == ABTON || token == BLKON || token == QCOMON || token == SHOPON || token == NEEON
                || token == UNPON || token == NVOON || token == TMUSON || token == DEON || token == SCHWON
                || token == COPON || token == PFEON || token == CRMON || token == TON || token == ISRGON
                || token == AGGON || token == IEMGON || token == UBERON || token == VRTXON || token == LMTON
                || token == MRVLON || token == ETNON || token == ACNON || token == SPGION || token == APPON
                || token == BAON || token == STXON || token == SCCOON || token == PDDON || token == GLDON
                || token == LOWON || token == SPOTON || token == SBUXON || token == IJHON || token == SGOVON
                || token == WDCON || token == SNDKON || token == IWFON || token == NETON || token == COFON
                || token == SOON || token == PBRON || token == NEMON || token == ABNBON || token == ENBON
                || token == EQIXON || token == SNOWON || token == REGNON || token == NOWON || token == GLWON
                || token == WMON || token == GDON || token == ITOTON || token == CEGON || token == PWRON
                || token == TTON || token == EMRON || token == ADBEON || token == INTUON || token == WMBON
                || token == CVNAON || token == MRNAON || token == NOCON || token == VRTON || token == EFAON
                || token == IWMON || token == FCXON || token == SLBON || token == DASHON || token == APOON
                || token == MELION || token == NTESON || token == HOODON || token == HPEON || token == TELON
                || token == NUEON || token == IAUON || token == AMEON || token == OXYON || token == BEON
                || token == NKEON || token == LITEON || token == KEYSON || token == IBITON || token == BILON
                || token == PYPLON || token == TLTON || token == XYZON || token == CMGON || token == FON
                || token == COHRON || token == NOKON || token == NTRAON || token == IEFON || token == VSTON
                || token == ROKON || token == SOXXON || token == DYNFON || token == STMON || token == TTWOON
                || token == CIENON || token == ALABON || token == MSTRON || token == VNQON || token == TERON
                || token == RKLBON || token == UMCON || token == JDON || token == JAAAON || token == CLSON
                || token == STLDON || token == EQTON || token == NBISON || token == INSMON || token == PCGON
                || token == COINON || token == TQQQON || token == EFVON || token == FLEXON || token == SHYON
                || token == VRSNON || token == CCJON || token == CRWVON || token == TCOMON || token == EEMON
                || token == ONON || token == HALON || token == CPNGON || token == JBLON || token == BIDUON
                || token == CRDOON || token == CBRSON || token == SLVON || token == HUBBON || token == IYWON
                || token == EWJON || token == GFSON || token == ENTGON || token == USFRON || token == EWYON
                || token == SWKSON || token == SOFION || token == HYGON || token == NVTON || token == RDDTON
                || token == MTSION || token == RIVNON || token == LSCCON || token == SMCION || token == TLNON
                || token == WCCON || token == TSEMON || token == LECOON || token == MKSION || token == TIPON
                || token == CRCLON || token == MTZON || token == IWNON || token == GMEON || token == SOXLON
                || token == PAVEON || token == FUTUON || token == IGVON || token == GRABON || token == GNRCON
                || token == FNON || token == ITAON || token == HIION || token == IONQON || token == LION
                || token == ALBON || token == ONTOON || token == PINSON || token == NVMION || token == BMNRON
                || token == SNAPON || token == FIGON || token == AIQON || token == AMKRON || token == AALON
                || token == RMBSON || token == OSCRON || token == TWSTON || token == EWZON || token == ASTSON
                || token == AURON || token == TTMION || token == HUTON || token == VICRON || token == INDAON
                || token == CLFON || token == NIOON || token == RIOTON || token == MPON || token == FORMON
                || token == IRENON || token == WULFON || token == FPSON || token == FIGRON || token == POWLON
                || token == SHLDON || token == AGON || token == CAION || token == ETHAON || token == COPXON
                || token == CORZON || token == BILION || token == MXLON || token == APLDON || token == PLON
                || token == KWEBON || token == OKLOON || token == URAON || token == VSHON || token == HIMSON
                || token == AAOION || token == FXION || token == PRIMON || token == CIFRON || token == ENPHON
                || token == BLSHON || token == QBTSON || token == UECON || token == RGTION || token == BOTZON
                || token == PENGON || token == ONDSON || token == AMCON || token == USARON || token == SOXQON
                || token == GRNDON || token == ACHRON || token == MARAON || token == GLXYON || token == AXTION
                || token == OUSTON || token == NVTSON || token == USOON || token == SQQQON || token == RXRXON
                || token == SOXSON || token == LUNRON || token == OIHON || token == RDWON || token == PURRON
                || token == DNNON || token == AION || token == AEHRON || token == WENON || token == PPLTON
                || token == SMRON || token == URNMON || token == UUUUON || token == SOUNON || token == PLUGON
                || token == IGEBON || token == SEDGON || token == WOLFON || token == OPENON || token == QUBTON
                || token == KEELON || token == INODON || token == SBETON || token == BTDRON || token == BBAION
                || token == BNOON || token == PSQON || token == CPERON || token == FCELON || token == FLNCON
                || token == NNEON || token == BOTON || token == PALLON || token == BTGOON || token == LPTHON
                || token == EXODON || token == BWETON || token == BAION || token == DRAMON || token == SATAON
                || token == STRCON
        ) return Listings.Tier.Custodial;
        return Listings.Tier.Unrecorded;
    }
}
