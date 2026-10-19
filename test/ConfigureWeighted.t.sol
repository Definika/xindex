// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConfigureWeighted} from "../script/ConfigureWeighted.s.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {PythIds} from "../script/PythIds.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice A contract with no `decimals`, so the policy check finds no answer.
contract NoDecimals {}

/// @notice v5's listing script against a real `WeightedIndexFactory`. Broadcasts come from DEFAULT_SENDER, the
///         factory's owner here. The V5_ variables are set by `test_run_readsEnvironment` alone.
contract ConfigureWeightedTest is Test {
    ConfigureWeighted configure;
    WeightedIndexFactory factory;
    MockERC20 a;
    MockERC20 b;
    address guardian = makeAddr("guardian");

    bytes32 constant A_ID = keccak256("A/USD");
    bytes32 constant B_ID = keccak256("B/USD");

    function setUp() public {
        configure = new ConfigureWeighted();
        factory = new WeightedIndexFactory(DEFAULT_SENDER, guardian, address(new MockPyth()));
        a = new MockERC20("Alpha", "A", 18);
        b = new MockERC20("Beta", "B", 8);
    }

    function _list() internal view returns (ConfigureWeighted.Entry[] memory list) {
        list = new ConfigureWeighted.Entry[](2);
        list[0] = ConfigureWeighted.Entry({token: address(a), priceId: A_ID});
        list[1] = ConfigureWeighted.Entry({token: address(b), priceId: B_ID});
    }

    function _all() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(a), address(b));
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    // ---------------------------------------------------------------------
    // Lists and parsing
    // ---------------------------------------------------------------------

    function test_theMainnetListsAreTheTable() public {
        vm.chainId(1);
        ConfigureWeighted.Entry[] memory first = configure.resolveList("default");
        ConfigureWeighted.Entry[] memory wide = configure.resolveList("wide");
        (address[] memory tokens, bytes32[] memory ids) = PythIds.all();
        assertEq(first.length, configure.DEFAULT_COUNT());
        assertEq(first.length + wide.length, tokens.length);
        assertEq(
            tokens.length,
            91,
            "the list of 2026-10-06, 2026-10-10's additions, less DOGE (10-14), with BNB and SUI, less SAND, RLB, BTT, SEI"
        );
        for (uint256 i = 0; i < tokens.length; ++i) {
            ConfigureWeighted.Entry memory entry = i < 4 ? first[i] : wide[i - 4];
            assertEq(entry.token, tokens[i]);
            assertEq(entry.priceId, ids[i]);
        }
        assertEq(first[0].token, MainnetAddresses.WETH);
    }

    /// @dev PYTH is pinned here too, written out independently of the address book like the table below, since every
    ///      settlement of every index parses at it and no test reaching only the address book would catch a wrong one
    ///      (RX-33).
    function test_RX33_pythIsPinnedIndependently() public pure {
        assertEq(MainnetAddresses.PYTH, 0x4305FB66699C3B2702D4d05CF36551390A4c69C6, "Pyth's proxy on Ethereum");
        assertEq(
            MainnetAddresses.UNIVERSAL_ROUTER, 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af, "Universal Router 2.0.0"
        );
    }

    /// @dev Every coin of the table has a price id of its own, none zero, and the first three are pinned to the feeds
    ///      they were read from: no index could hold two coins on one id (V5-M1).
    function test_everyListedCoinHasItsOwnPriceId() public pure {
        (, bytes32[] memory ids) = PythIds.all();
        for (uint256 i = 0; i < ids.length; ++i) {
            assertTrue(ids[i] != bytes32(0));
            for (uint256 j = 0; j < i; ++j) {
                assertTrue(ids[i] != ids[j], "one id per coin");
            }
        }
        assertEq(ids[0], 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, "WETH on ETH/USD");
        assertEq(ids[1], 0xc9d8b075a5c69303365ae23633d4e085199bf5c520a3b90fed1322a0342ffc33, "WBTC on WBTC/USD");
        assertEq(ids[2], 0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221, "LINK on LINK/USD");
    }

    /// @dev Every coin of the table carries a tier, as the app and safe mode show it: WBTC, Tether Gold and the Ondo stocks
    ///         custodial, eight bridged
    ///         copies, and the rest issued on Ethereum.
    function test_everyListedCoinHasItsTier() public view {
        (address[] memory tokens,) = PythIds.all();
        uint256[4] memory count;
        for (uint256 i = 0; i < tokens.length; ++i) {
            PythIds.Tier tier = PythIds.tierOf(tokens[i]);
            assertTrue(tier != PythIds.Tier.Unrecorded, "every listed coin is recorded");
            ++count[uint256(tier)];
        }
        assertEq(count[uint256(PythIds.Tier.Native)], 48, "22 of the wide list and 26 of the hundred-coin list");
        assertEq(count[uint256(PythIds.Tier.Bridged)], 19, "8, ZK and W, and 9 Wormhole copies");
        assertEq(count[uint256(PythIds.Tier.Custodial)], 24, "19, and 5 Wormhole copies of Binance-Peg coins");
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.WBTC)), uint8(PythIds.Tier.Custodial));
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.ARB)), uint8(PythIds.Tier.Bridged));
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.INJ)), uint8(PythIds.Tier.Bridged));
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.SOL)), uint8(PythIds.Tier.Bridged));
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.XAUT)), uint8(PythIds.Tier.Custodial));
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.GNO)), uint8(PythIds.Tier.Native));
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.ONEINCH)), uint8(PythIds.Tier.Native));
        assertEq(
            uint8(PythIds.tierOf(MainnetAddresses.ZK)), uint8(PythIds.Tier.Bridged), "ZKsync's bridge issues it (RX-19)"
        );
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.W)), uint8(PythIds.Tier.Bridged), "a mesh peer, home Solana");
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.JUP)), uint8(PythIds.Tier.Bridged), "a Wormhole copy");
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.OP)), uint8(PythIds.Tier.Bridged));
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.BNB)), uint8(PythIds.Tier.Bridged), "WBNB, not Binance-Peg");
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.SUI)), uint8(PythIds.Tier.Bridged));
        assertEq(
            uint8(PythIds.tierOf(MainnetAddresses.XRP)),
            uint8(PythIds.Tier.Custodial),
            "a Wormhole copy of a Binance-Peg coin carries Binance's custody"
        );
        assertEq(
            uint8(PythIds.tierOf(0xd881A7F17Ed2c71FD671AfbA3A9b30Eb914Aea5F)),
            uint8(PythIds.Tier.Unrecorded),
            "DOGE's copy, off the list since 2026-10-14"
        );
        assertEq(
            uint8(PythIds.tierOf(0x3845badAde8e6dFF049820680d1F14bD3903a5d0)),
            uint8(PythIds.Tier.Unrecorded),
            "SAND, off the list since 2026-10-18"
        );
        assertEq(
            uint8(PythIds.tierOf(0xC669928185DbCE49d2230CC9B0979BE6DC797957)),
            uint8(PythIds.Tier.Unrecorded),
            "BTT, off the list since 2026-10-19 (RX-28)"
        );
        assertEq(
            uint8(PythIds.tierOf(0xf91e605af079384cc7077B3914A4a36019a89EE8)),
            uint8(PythIds.Tier.Unrecorded),
            "SEI's copy, off the list since 2026-10-19 (RX-32)"
        );
        assertEq(
            uint8(PythIds.tierOf(0x046EeE2cc3188071C02BfC1745A6b17c656e3f3d)),
            uint8(PythIds.Tier.Unrecorded),
            "RLB, off the list since 2026-10-18"
        );
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.ATOM)), uint8(PythIds.Tier.Custodial));
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.VON)), uint8(PythIds.Tier.Custodial));
        assertEq(uint8(PythIds.tierOf(MainnetAddresses.USDC)), uint8(PythIds.Tier.Unrecorded));
        assertEq(PythIds.tierName(PythIds.Tier.Native), "Native");
        assertEq(PythIds.tierName(PythIds.Tier.Bridged), "Bridged");
        assertEq(PythIds.tierName(PythIds.Tier.Custodial), "Custodial");
        assertEq(PythIds.tierName(PythIds.Tier.Unrecorded), "Unrecorded");
        assertEq(configure.tierLabel(MainnetAddresses.WBTC), " (Custodial)");
        assertEq(configure.tierLabel(address(a)), "", "a token off the table carries no label");
    }

    /// @dev CR-L08: the lists are the release record, pinned against this table, written out by hand, address and
    ///      price id, rather than read from `PythIds`, so a slip in either shows.
    function test_CRL08_theListsAreTheReleaseRecord() public view {
        ConfigureWeighted.Entry[] memory first = configure.defaultMainnetList();
        ConfigureWeighted.Entry[] memory wide = configure.wideMainnetList();
        address[91] memory tokens = [
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH
            0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, // WBTC
            0x514910771AF9Ca656af840dff83E8264EcF986CA, // LINK
            0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, // UNI
            0x4a220E6096B25EADb88358cb44068A3248254675, // QNT
            0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9, // AAVE
            0x57e114B691Db790C35207b2e685D4A43181e6061, // ENA
            0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3, // ONDO
            0x56072C95FAA701256059aa122697B133aDEd9279, // SKY
            0x163f8C2467924be0ae7B5347228CABF260318753, // WLD
            0x3c3a81e81dc49A522A592e7622A7E711c06bf354, // MNT
            0x58D97B57BB95320F9a05dC918Aef65434969c2B2, // MORPHO
            0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6, // POL
            0x232CE3bd40fCd6f80f3d55A522d03f25Df784Ee2, // LIT
            0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB, // ETHFI
            0xaea46A60368A7bD060eec7DF8CBa43b7EF41Ad85, // FET
            0xD533a949740bb3306d119CC777fa900bA034cd52, // CRV
            0xB62132e35a6c13ee1EE0f84dC5d40bad8d815206, // NEXO
            0x44ff8620b8cA30902395A7bD3F2407e1A091BF73, // VIRTUAL
            0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766, // STRK
            0x808507121B80c02388fAd14726482e061B8da827, // PENDLE
            0xA0b73E1Ff0B80914AB6fe0444E65848C4C34450b, // CRO
            0x00f3C42833C3170159af4E92dbb451Fb3F708917, // ICP
            0xB50721BCf8d664c30412Cfbc6cf7a15145234ad1, // ARB
            0x6De037ef9aD2725EB40118Bb1702EBb27e4Aeb24, // RENDER
            0x152649eA73beAb28c5b49B26eb48f7EAD6d4c898, // CAKE
            0x6985884C4392D348587B19cb9eAAf157F13271cd, // ZRO
            0xe28b3B32B6c345A34Ff64674606124Dd5Aceca30, // INJ
            0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE, // SHIB
            0x6982508145454Ce325dDbE47a25d4ec3d2311933, // PEPE
            0xD31a59c85aE9D8edEFeC411D448f90841571b89c, // SOL
            0x68749665FF8D2d112Fa859AA293F07A622782F38, // XAUt
            0x2D1F7226Bd1F780AF6B9A49DCC0aE00E8Df4bDEE, // NVDAon
            0x14c3abF95Cb9C93a8b82C1CdCB76D72Cb87b2d4c, // AAPLon
            0xbA47214eDd2bb43099611b208f75E4b42FDcfEDc, // GOOGLon
            0xB812837b81a3a6b81d7CD74CfB19A7f2784555E5, // MSFTon
            0xbb8774FB97436d23d74C1b882E8E9A69322cFD31, // AMZNon
            0x3Cafdbfe682aec17d5acE2f97A2f3ab3dCf6a4A9, // TSMon
            0xc9eef266834730340A55B6CC24621B31BAF55581, // SPCXon
            0x59644165402b611b350645555B50Afb581C71EB2, // METAon
            0x0d54D4279B9E8c54cD8547c2C75A8Ee81A0BcaE8, // AVGOon
            0xf6b1117ec07684D3958caD8BEb1b302bfD21103f, // TSLAon
            0xc0fE36F4FFBDf1B38E192215073590a68f9A2Af7, // SKHYon
            0x050362Ab1072Cb2Ce74d74770E22A3203Ad04ee5, // MUon
            0xf192957AE52dB3eb088654403CC2eDeD014ae556, // LLYon
            0x0C1f3412A44Ff99E40bF14e06e5Ea321aE7B3938, // AMDon
            0x03C1EC4CA9DBb168E6Db0DeF827c085999CBffaF, // JPMon
            0x82106347dDbB23cE44Cf4cE4053Ef1adf8b9323B, // WMTon
            0xaC37c20C1d0E5285035e056101a64e263Ff94a41, // Von
            0xFA1C09fC8B491B6A4d3Ff53A10CAd29381b3F949, // FF
            0x6810e776880C02933D47DB1b9fc05908e5386b96, // GNO
            0x64aa3364F17a4D01c6f1751Fd97C2BD3D7e7f1D5, // OHM
            0xc944E90C64B2c07662A292be6244BDf05Cda44a7, // GRT
            0x643C4E15d7d62Ad0aBeC4a9BD4b001aA3Ef52d66, // SYRUP
            0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72, // ENS
            0x7420B4b9a0110cdC71fB720908340C03F9Bc03EC, // JASMY
            0xc00e94Cb662C3520282E6f5717214004A7f26888, // COMP
            0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83, // EIGEN
            0xBB0E17EF65F82Ab018d8EDd776e8DD940327B28b, // AXS
            0x0D8775F648430679A709E98d2b0Cb6250d2887EF, // BAT
            0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B, // CVX
            0x0F5D2fB29fb7d3CFeE444a200298f468908cC942, // MANA
            0xF57e7e7C23978C3cAEC3C3548E3D615c346e79fF, // IMX
            0x6f40d4A6237C257fff2dB00FA0510DeEECd303eb, // FLUID
            0x3506424F91fD33084466F402d5D97f05F8e3b4AF, // CHZ
            0x66A5cFB2e9c529f14FE6364Ad1075dF3a649C0A5, // ZK
            0x4d224452801ACEd8B2F0aebE155379bb5D594381, // APE
            0x56A3BA04E95d34268A19b2a4474DC979baBDaf76, // SENT
            0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F, // SNX
            0x111111111117dC0aa78b770fA6A738034120C302, // 1INCH
            0x7DD9c5Cba05E151C895FDe1CF355C9A1D5DA6429, // GLM
            0xbe0Ed4138121EcFC5c0E56B40517da27E6c5226B, // ATH
            0xE76c5b78f93909d34404E9eb4C1f19e7582a5dE1, // H
            0x4C1746A800D224393fE2470C70A35717eD4eA5F1, // PLUME
            0xd1d2Eb1B1e90B638588728b4130137D262C87cae, // GALA
            0xB0fFa8000886e57F86dd5264b9582b2Ad87b2b91, // W
            0x320623b8E4fF03373931769A31Fc52A4E78B5d70, // RSR
            0xc730d8256B8A1030eEA67f1Bc7ebed3898f7A535, // XRP
            0x8EfFbF747d4A60Bc6b68D9A1bE4c4188bA8A3a0b, // ADA
            0x1cA1Ef3fB8Ff4a480C0ae7eea5f91A24a5BB3344, // LTC
            0x85f138bfEE4ef8e540890CFb48F620571d67Eda3, // AVAX
            0x1839a38E59536D88C25e8E6e0D0f59e05b143ab2, // DOT
            0x8687a10BCa6F139B25eb31020FCABB5782214764, // JUP
            0xe31Cfcd36FeD044ae4Cf9405B577fe875762194F, // ALGO
            0x7845167B54253269624dBA0cA5Fee87933107b34, // ATOM
            0x750525C1877E30304F1E22b1b49b4C9DdE674ddF, // AERO
            0x8CDf7AF57E4c8B930e1B23c477c22f076530585e, // APT
            0xeFc0CED4B3D536103e76a1c4c74F0385C8F4Bdd3, // PYTH
            0x1df721D242E0783F8fCab4A9FfE4F35bdf329909, // OP
            0x418D75f65a02b3D53B2418FB8E1fe493759c7605, // BNB (WBNB)
            0x84074EA631dEc7a4edcD5303d164D5dEa4c653D6 // SUI
        ];
        bytes32[91] memory ids = [
            bytes32(0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace), // WETH
            0xc9d8b075a5c69303365ae23633d4e085199bf5c520a3b90fed1322a0342ffc33, // WBTC
            0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221, // LINK
            0x78d185a741d07edb3412b09008b7c5cfb9bbbd7d568bf00ba737b456ba171501, // UNI
            0x19ab139032007c8bd7d1fd3842ef392a5434569a72b555504a5aee47df2a0a35, // QNT
            0x2b9ab1e972a281585084148ba1389800799bd4be63b957507db1349314e47445, // AAVE
            0xb7910ba7322db020416fcac28b48c01212fd9cc8fbcbaf7d30477ed8605f6bd4, // ENA
            0xd40472610abe56d36d065a0cf889fc8f1dd9f3b7f2a478231a5fc6df07ea5ce3, // ONDO
            0xa483243eed64ca27a1f6e26385b7d1e0d07e9fe264bb6903efb3efc4689d3fe7, // SKY
            0xd6835ad1f773de4a378115eb6824bd0c0e42d84d1c84d9750e853fb6b6c7794a, // WLD
            0x4e3037c822d852d79af3ac80e35eb420ee3b870dca49f9344a38ef4773fb0585, // MNT
            0x5b2a4c542d4a74dd11784079ef337c0403685e3114ba0d9909b5c7a7e06fdc42, // MORPHO
            0xffd11c5a1cfd42f80afb2df4d9f264c15f956d68153335374ec10722edd70472, // POL
            0xc0c83f00c39165892d55dcd17ade2191e289697e2ac132d9ab721e20834e2a9e, // LIT
            0xb27578a9654246cb0a2950842b92330e9ace141c52b63829cc72d5c45a5a595a, // ETHFI
            0x7da003ada32eabbac855af3d22fcf0fe692cc589f0cfd5ced63cf0bdcc742efe, // FET
            0xa19d04ac696c7a6616d291c7e5d1377cc8be437c327b75adb5dc1bad745fcae8, // CRV
            0xe5f406d97d7fa159c21647912b72aa8c669e24d7bd59bcd518587bbde027c531, // NEXO
            0x8132e3eb1dac3e56939a16ff83848d194345f6688bff97eb1c8bd462d558802b, // VIRTUAL
            0x6a182399ff70ccf3e06024898942028204125a819e519a335ffa4579e66cd870, // STRK
            0x9a4df90b25497f66b1afb012467e316e801ca3d839456db028892fe8c70c8016, // PENDLE
            0x23199c2bcb1303f667e733b9934db9eca5991e765b45f5ed18bc4b231415f2fe, // CRO
            0xc9907d786c5821547777780a1e4f89484f3417cb14dd244f2b0a34ea7a554d67, // ICP
            0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5, // ARB
            0x3d4a2bd9535be6ce8059d75eadeba507b043257321aa544717c56fa19b49e35d, // RENDER
            0x2356af9529a1064d41e32d617e2ce1dca5733afa901daba9e2b68dee5d53ecf9, // CAKE
            0x3bd860bea28bf982fa06bcf358118064bb114086cc03993bd76197eaab0b8018, // ZRO
            0x7a5bc1d2b56ad029048cd63964b3ad2776eadf812edc1a43a31406cb54bff592, // INJ
            0xf0d57deca57b3da2fe63a493f4c25925fdfd8edf834b20f93e1f84dbd1504d4a, // SHIB
            0xd69731a2e74ac1ce884fc3890f7ee324b6deb66147055249568869ed700882e4, // PEPE
            0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d, // SOL
            0x44465e17d2e9d390e70c999d5a11fda4f092847fcd2e3e5aa089d96c98a30e67, // XAUt
            0x207ddea2a443d30b7e13a7c88a9e3f106765deb97049afc65a18cede50fffc82, // NVDAon
            0xe6734de88a83d9d2fb33072adab319004700aefd069653aba30ba9e3cac056f2, // AAPLon
            0xad79b3487bef87ff8f8ab31c0b779ad08d931fdfa5436f7e92a234bb82bff7e4, // GOOGLon
            0x29b228e9fd72bbd306bcca3b10c165d8dba5d535ef8d5aab6c6e4bc18912d150, // MSFTon
            0x329635cf9e705e01ed2d842fafbb6c426d7e5630e75847740d89957222fd68b8, // AMZNon
            0xe722560a66e4ab00522ef20a38fa2ba5d1b41f1c5404723ed895d202a7af7cc4, // TSMon
            0x2dbfb1791e75725227a90dbd23c6bdd83b80cc9d13011973c948b6aeacdf17b9, // SPCXon
            0x2cc0c022f7f37920485a5947f3cea8633783b6cb7fff6d94ee52f48687b7783d, // METAon
            0xd0c9aef79b28308b256db7742a0a9b08aaa5009db67a52ea7fa30ed6853f243b, // AVGOon
            0xc09ef687ed07091c047da444f1499f2da52cdc1c085104643ec565a9eb1af514, // TSLAon
            0xb196587ca694ea231cd8710321f4f62ed08794c6a096759d5c63616730042ae0, // SKHYon
            0x27e65b49e4572601374c5bde284411c20f49eb74845cc7f7801f9d27fba2b4b2, // MUon
            0x70dcf5fd56553d0023693e4b590336a8c9bcfd0d98dd9f093b1f697820d98325, // LLYon
            0xfa1a3697811ac1b36846b4de42ad1b4d3c7b50b556eed405dbefbf4e4a0c7c07, // AMDon
            0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e, // JPMon
            0x327ae981719058e6fb44e132fb4adbf1bd5978b43db0661bfdaefd9bea0c82dc, // WMTon
            0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90, // Von
            0xf9597faf41a8d91fcc4dc95e9b4f408ea391cf17ec26955ae2055b6dbda5ec89, // FF
            0xc5f60d00d926ee369ded32a38a6bd5c1e0faa936f91b987a5d0dcf3c5d8afab0, // GNO
            0x3a8c0214e4fb7f1dd7792ed4d5b2971372e52f088fcd9cc02309253cbdc4a70e, // OHM
            0x4d1f8dae0d96236fb98e8f47471a366ec3b1732b47041781934ca3a9bb2f35e7, // GRT
            0xed86e0c6321d790302e5d88751995ebc9079273e549005d68a83ba72e48ff1ce, // SYRUP
            0xb98ab6023650bd2edc026b983fb7c2f8fa1020286f1ba6ecf3f4322cd83b72a6, // ENS
            0x2b386bdca7fda5cf3c3975f70318593bf144104cb00742592ecff60dd798972f, // JASMY
            0x4a8e42861cabc5ecb50996f92e7cfa2bce3fd0a2423b0c44c9b423fb2bd25478, // COMP
            0xc65db025687356496e8653d0d6608eec64ce2d96e2e28c530e574f0e4f712380, // EIGEN
            0xb7e3904c08ddd9c0c10c6d207d390fd19e87eb6aab96304f571ed94caebdefa0, // AXS
            0x8e860fb74e60e5736b455d82f60b3728049c348e94961add5f961b02fdee2535, // BAT
            0x6aac625e125ada0d2a6b98316493256ca733a5808cd34ccef79b0e28c64d1e76, // CVX
            0x1dfffdcbc958d732750f53ff7f06d24bb01364b3f62abea511a390c74b8d16a5, // MANA
            0x941320a8989414874de5aa2fc340a75d5ed91fdff1613dd55f83844d52ea63a2, // IMX
            0x47d462d8bac4c29b6ae1792029b9b92c8adea12ed22155bfc22f481287f1e349, // FLUID
            0xe799f456b358a2534aa1b45141d454ac04b444ed23b1440b778549bb758f2b5c, // CHZ
            0xcc03dc09298fb447e0bf9afdb760d5b24340fd2167fd33d8967dd8f9a141a2e8, // ZK
            0x15add95022ae13563a11992e727c91bdb6b55bc183d9d747436c80a483d8c864, // APE
            0xc1c19f04619dbca4343d76f240b4d944551bbbb56883051e874a8d0533bce644, // SENT
            0x39d020f60982ed892abbcd4a06a276a9f9b7bfbce003204c110b6e488f502da3, // SNX
            0x63f341689d98a12ef60a5cff1d7f85c70a9e17bf1575f0e7c0b2512d48b1c8b3, // 1INCH
            0x01a09cbc99b1894271cfd90d6e5aab527cafa66b19d651b441b84e84f671de33, // GLM
            0xf6b551a947e7990089e2d5149b1e44b369fcc6ad3627cb822362a2b19d24ad4a, // ATH
            0x807df1ed343907c4d97790334338c5df6e360036b3c95f880450d078569b5481, // H
            0xded84d57dbf810bf86b97936f12e1f01b8d6d01c251a4d6eac592147988d475c, // PLUME
            0x0781209c28fda797616212b7f94d77af3a01f3e94a5d421760aef020cf2bcb51, // GALA
            0xeff7446475e218517566ea99e72a4abec2e1bd8498b43b7d8331e29dcb059389, // W
            0xfb7565b77267ba3f6ef770bed5d7f9b22b8542db676dbd9b934a2fcf945f4371, // RSR
            0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8, // XRP
            0x2a01deaec9e51a579277b34b122399984d0bbf57e2458a7e42fecd2829867a0d, // ADA
            0x6e3f3fa8253588df9326580180233eb791e03b443a3ba7a1d892e73874e19a54, // LTC
            0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7, // AVAX
            0xca3eed9b267293f6595901c734c7525ce8ef49adafe8284606ceb307afa2ca5b, // DOT
            0x0a0408d619e9380abad35060f9192039ed5042fa6f82301d0e48bb52be830996, // JUP
            0xfa17ceaf30d19ba51112fdcc750cc83454776f47fb0112e4af07f15f4bb1ebc0, // ALGO
            0xb00b60f88b03a6a625a8d1c048c3f66653edf217439983d037e7222c4e612819, // ATOM
            0x9db37f4d5654aad3e37e2e14ffd8d53265fb3026d1d8f91146539eebaa2ef45f, // AERO
            0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5, // APT
            0x0bbf28e9a841a1cc788f6a361b17ca072d0ea3098a1e5df1c3922d06719579ff, // PYTH
            0x385f64d993f7b77d8182ed5003d97c60aa3361f3cecfe711544d2d59165e9bdf, // OP
            0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f, // BNB
            0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744 // SUI
        ];
        assertEq(first.length, 4);
        assertEq(wide.length, 87);
        for (uint256 i = 0; i < tokens.length; ++i) {
            ConfigureWeighted.Entry memory entry = i < 4 ? first[i] : wide[i - 4];
            assertEq(entry.token, tokens[i]);
            assertEq(entry.priceId, ids[i]);
        }
    }

    /// @dev The named lists are Ethereum's and resolve on chain 1 only.
    function test_theNamedListsResolveOnlyOnTheirChain() public {
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.ListOffItsChain.selector, "default", block.chainid));
        configure.resolveList("default");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.ListOffItsChain.selector, "wide", block.chainid));
        configure.resolveList("wide");
        vm.chainId(1);
        assertEq(configure.resolveList("default").length, configure.DEFAULT_COUNT());
    }

    function test_entriesParse() public view {
        string memory raw = string.concat(
            vm.toString(address(a)), ":", vm.toString(A_ID), " , ", vm.toString(address(b)), ":", vm.toString(B_ID)
        );
        ConfigureWeighted.Entry[] memory list = configure.resolveList(raw);
        assertEq(list.length, 2);
        assertEq(list[0].token, address(a));
        assertEq(list[0].priceId, A_ID);
        assertEq(list[1].token, address(b));
        assertEq(list[1].priceId, B_ID);
    }

    function test_malformedEntriesAreRefused() public {
        string memory token = vm.toString(address(a));
        string[4] memory bad = [
            token,
            string.concat(token, ":"),
            string.concat(token, ":", vm.toString(A_ID), ":x"),
            string.concat(token, ":", vm.toString(bytes32(0)))
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.MalformedEntry.selector, bad[i]));
            configure.parseEntry(bad[i]);
        }
    }

    /// @dev A token or a price id named twice is refused before anything runs (RT-24, V5-M1).
    function test_RT24_V5M1_aListNamingATokenOrAnIdTwiceIsRefused() public {
        ConfigureWeighted.Entry[] memory list = _list();
        list[1].token = address(a);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.DuplicateEntry.selector, address(a)));
        configure.safeCalldata(factory, list, _all(), _none());

        list = _list();
        list[1].priceId = A_ID;
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.DuplicatePriceId.selector, A_ID));
        configure.propose(factory, list, _all(), _none());

        string memory raw = string.concat(
            vm.toString(address(a)), ":", vm.toString(A_ID), ",", vm.toString(address(a)), ":", vm.toString(B_ID)
        );
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.DuplicateEntry.selector, address(a)));
        configure.resolveList(raw);
    }

    function test_addressListsParse() public view {
        assertEq(configure.parseAddresses("").length, 0);
        address[] memory parsed =
            configure.parseAddresses(string.concat(vm.toString(address(a)), ", ", vm.toString(address(b))));
        assertEq(parsed.length, 2);
        assertEq(parsed[1], address(b));
        address[] memory all = configure.resolveFirstListings("all", _list());
        assertEq(all.length, 2);
        assertEq(all[0], address(a));
        assertEq(configure.resolveFirstListings(vm.toString(address(b)), _list())[0], address(b));
    }

    // ---------------------------------------------------------------------
    // Proposals
    // ---------------------------------------------------------------------

    /// @dev RT-06: a token never listed gets a proposal only when named in V5_LIST.
    function test_RT06_aFirstListingIsProposedOnlyWhenNamed() public {
        configure.propose(factory, _list(), _none(), _none());
        assertEq(factory.listingEta(address(a)), 0, "not named, not proposed");

        address[] memory onlyA = new address[](1);
        onlyA[0] = address(a);
        configure.propose(factory, _list(), onlyA, _none());
        assertGt(factory.listingEta(address(a)), 0);
        assertEq(factory.listingEta(address(b)), 0);
        (bytes32 id,) = factory.pendingTerms(address(a));
        assertEq(id, A_ID);
    }

    /// @dev RT-06: a listing the guardian cancelled is not proposed again by a routine run, and a delisted token comes
    ///      back only when named in V5_RELIST.
    function test_RT06_XA11_aVetoedOrDelistedTokenStaysOutUnlessNamed() public {
        configure.propose(factory, _list(), _all(), _none());
        vm.prank(guardian);
        factory.cancelListing(address(a));
        configure.propose(factory, _list(), _none(), _none());
        assertEq(factory.listingEta(address(a)), 0, "a routine run does not repropose the vetoed listing");

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, _list());
        assertTrue(factory.isWhitelisted(address(b)));
        vm.prank(guardian);
        factory.delist(address(b));
        configure.propose(factory, _list(), _all(), _none());
        assertEq(factory.listingEta(address(b)), 0, "delisted, and only V5_LIST named it");
        configure.propose(factory, _list(), _none(), _all());
        assertGt(factory.listingEta(address(b)), 0, "named in V5_RELIST");
    }

    /// @dev An expired first listing is the owner's own proposal run out, not a veto: a routine run proposes it again,
    ///      while a cancelled one still waits to be named (RX-39).
    function test_RX39_anExpiredFirstListingIsProposedAgainButACancelledOneIsNot() public {
        configure.propose(factory, _list(), _all(), _none());
        vm.prank(guardian);
        factory.cancelListing(address(a));
        vm.warp(block.timestamp + factory.LISTING_DELAY() + factory.PROPOSAL_WINDOW() + 1);
        assertFalse(factory.listingPending(address(b)), "b's proposal expired unexecuted");

        configure.propose(factory, _list(), _none(), _none());
        assertTrue(factory.listingPending(address(b)), "proposed again without V5_LIST");
        assertEq(factory.listingEta(address(a)), 0, "the cancelled one is not");
    }

    function test_XA40_proposeSkipsWhatThePolicyOrTheFactoryWouldRefuse() public {
        configure.propose(factory, _list(), _all(), _none());
        // Already pending with the entry's id, or with another: both skipped.
        ConfigureWeighted.Entry[] memory changed = _list();
        changed[0].priceId = keccak256("A, another feed");
        configure.propose(factory, changed, _all(), _none());
        configure.propose(factory, _list(), _all(), _none());
        (bytes32 id,) = factory.pendingTerms(address(a));
        assertEq(id, A_ID);
        // Listed: skipped.
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, _list());
        configure.propose(factory, _list(), _all(), _all());
        assertEq(factory.listingEta(address(a)), 0);

        // The policy: a mint currency, a token with no code, no decimals, and decimals outside 6 to 18.
        ConfigureWeighted.Entry[] memory odd = new ConfigureWeighted.Entry[](6);
        odd[0] = ConfigureWeighted.Entry({token: MainnetAddresses.USDC, priceId: keccak256("1")});
        odd[1] = ConfigureWeighted.Entry({token: MainnetAddresses.USDT, priceId: keccak256("2")});
        odd[2] = ConfigureWeighted.Entry({token: makeAddr("no code"), priceId: keccak256("3")});
        odd[3] = ConfigureWeighted.Entry({token: address(new NoDecimals()), priceId: keccak256("4")});
        odd[4] = ConfigureWeighted.Entry({token: address(new MockERC20("Five", "FIVE", 5)), priceId: keccak256("5")});
        odd[5] = ConfigureWeighted.Entry({token: address(new MockERC20("Wide", "WIDE", 19)), priceId: keccak256("6")});
        address[] memory named = new address[](6);
        for (uint256 i = 0; i < 6; ++i) {
            named[i] = odd[i].token;
        }
        (bytes[] memory calls,) = configure.safeCalldata(factory, odd, named, _none());
        assertEq(calls.length, 0, "the policy skips every one");
    }

    function test_XA18_LR07_proposeNeedsAnOwnerThatSigns() public {
        WeightedIndexFactory owned = new WeightedIndexFactory(address(configure), guardian, address(new MockPyth()));
        ConfigureWeighted.Entry[] memory list = _list();
        address[] memory all = _all();
        address[] memory none = _none();
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.OwnerIsContract.selector, address(configure)));
        configure.propose(owned, list, all, none);

        // A key delegated under EIP-7702 has code but still signs.
        vm.etch(DEFAULT_SENDER, abi.encodePacked(hex"ef0100", address(0x1234)));
        configure.propose(factory, list, all, none);
        assertGt(factory.listingEta(address(a)), 0);
    }

    function test_safeModeLabelsEveryProposal() public view {
        (bytes[] memory calls, string[] memory labels) = configure.safeCalldata(factory, _list(), _all(), _none());
        assertEq(calls.length, 2);
        assertEq(calls[0], abi.encodeCall(factory.proposeListing, (address(a), A_ID)));
        assertEq(
            labels[1], string.concat("proposeListing B ", vm.toString(address(b)), " price id ", vm.toString(B_ID))
        );
    }

    // ---------------------------------------------------------------------
    // Execution and status
    // ---------------------------------------------------------------------

    function test_XA06_executeRunsOnlyWhatIsDueAndTheEntrys() public {
        configure.execute(factory, _list()); // nothing pending
        configure.propose(factory, _list(), _all(), _none());
        configure.execute(factory, _list()); // not ready
        assertFalse(factory.isWhitelisted(address(a)));

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        ConfigureWeighted.Entry[] memory changed = _list();
        changed[0].priceId = keccak256("A, another feed");
        configure.execute(factory, changed);
        assertFalse(factory.isWhitelisted(address(a)), "the pending id is not the entry's");
        assertTrue(factory.isWhitelisted(address(b)));

        vm.warp(block.timestamp + factory.PROPOSAL_WINDOW() + 1);
        configure.execute(factory, _list());
        assertFalse(factory.isWhitelisted(address(a)), "expired");
    }

    /// @dev FR-05: executing needs no role. Any account runs what is due, and a listing the guardian cancelled stays
    ///      cancelled.
    function test_FR05_executeWorksFromAnyAccountAndNeverReproposesACancelledListing() public {
        address someoneElse = makeAddr("someone else"); // the broadcaster is neither owner nor guardian
        WeightedIndexFactory other = new WeightedIndexFactory(someoneElse, guardian, address(new MockPyth()));
        ConfigureWeighted.Entry[] memory list = _list();
        vm.startPrank(someoneElse);
        other.proposeListing(list[0].token, list[0].priceId);
        other.proposeListing(list[1].token, list[1].priceId);
        vm.stopPrank();
        vm.prank(guardian);
        other.cancelListing(list[1].token);

        vm.warp(block.timestamp + other.LISTING_DELAY());
        configure.execute(other, list);
        assertTrue(other.isWhitelisted(list[0].token));
        assertFalse(other.isWhitelisted(list[1].token));
        assertEq(other.listingEta(list[1].token), 0, "a cancelled listing stays cancelled");
    }

    function test_XA42_statusReportsListingsAndPendingProposals() public {
        configure.propose(factory, _list(), _all(), _none());
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        ConfigureWeighted.Entry[] memory onlyB = new ConfigureWeighted.Entry[](1);
        onlyB[0] = _list()[1];
        configure.execute(factory, onlyB);

        ConfigureWeighted.Entry[] memory changed = _list();
        changed[0].priceId = keccak256("A, another feed");
        ConfigureWeighted.Report[] memory reports = configure.status(factory, changed);
        assertFalse(reports[0].listed);
        assertFalse(reports[0].idInForce);
        assertGt(reports[0].eta, 0);
        assertFalse(reports[0].pendingMatches);
        assertTrue(reports[1].listed);
        assertTrue(reports[1].idInForce);
        assertEq(reports[1].eta, 0);

        reports = configure.status(factory, _list());
        assertTrue(reports[0].pendingMatches);
    }

    // ---------------------------------------------------------------------
    // run
    // ---------------------------------------------------------------------

    function test_run_readsEnvironment() public {
        string memory raw = string.concat(
            vm.toString(address(a)), ":", vm.toString(A_ID), ",", vm.toString(address(b)), ":", vm.toString(B_ID)
        );
        vm.setEnv("V5_FACTORY", vm.toString(address(factory)));
        vm.setEnv("V5_WHITELIST", raw);
        vm.setEnv("V5_LIST", "all");
        vm.setEnv("V5_RELIST", "");
        vm.setEnv("V5_MODE", "safe");
        configure.run();
        assertEq(factory.listingEta(address(a)), 0, "safe mode broadcasts nothing");
        vm.setEnv("V5_MODE", "propose");
        configure.run();
        assertGt(factory.listingEta(address(a)), 0);
        vm.setEnv("V5_MODE", "status");
        configure.run();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.setEnv("V5_MODE", "execute");
        configure.run();
        assertTrue(factory.isWhitelisted(address(a)));
        assertTrue(factory.isWhitelisted(address(b)));
        vm.setEnv("V5_MODE", "sideways");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.UnknownMode.selector, "sideways"));
        configure.run();
    }
}
