// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {WeightedMath} from "../src/WeightedMath.sol";
import {Test} from "forge-std/Test.sol";
import {ConfigureWeighted} from "../script/ConfigureWeighted.s.sol";
import {ScriptLists} from "../script/ScriptLists.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {BnbChainAddresses} from "../script/BnbChainAddresses.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {Listings} from "../script/Listings.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IPythPrices} from "../src/interfaces/IPythPrices.sol";
import {PriceFeeds} from "../script/PriceFeeds.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice A contract with no `decimals`, so the policy check finds no answer.
contract NoDecimals {}

/// @notice The listing script against a real `WeightedIndexFactory`. Broadcasts come from DEFAULT_SENDER, the
///         factory's owner here. The V5_ variables are set by `test_A722_run_readsEnvironment` alone.
contract ConfigureWeightedTest is Test {
    ConfigureWeighted configure;
    WeightedIndexFactory factory;
    MockERC20 a;
    MockERC20 b;
    address guardian = makeAddr("guardian");

    /// @dev The deployment's mint currencies here: two addresses no list names.
    address constant HERE_USDC = address(0xC0FFEE01);
    address constant HERE_USDT = address(0xC0FFEE02);

    function setUp() public {
        configure = new ConfigureWeighted();
        factory = new WeightedIndexFactory(DEFAULT_SENDER, guardian, address(0), address(new WeightedMath()));
        a = new MockERC20("Alpha", "A", 18);
        b = new MockERC20("Beta", "B", 8);
    }

    function _list() internal view returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (address(a), address(b));
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _currencies() internal pure returns (address[2] memory) {
        return [HERE_USDC, HERE_USDT];
    }

    // ---------------------------------------------------------------------
    // Lists and parsing
    // ---------------------------------------------------------------------

    function test_theMainnetListsAreTheTable() public {
        vm.chainId(1);
        address[] memory first = configure.resolveList("default");
        address[] memory wide = configure.resolveList("wide");
        address[] memory tokens = Listings.all();
        assertEq(first.length, configure.DEFAULT_COUNT());
        assertEq(first.length + wide.length, tokens.length);
        assertEq(
            tokens.length,
            415,
            "the list of 2026-10-06 and 2026-10-10's additions, less DOGE, SAND, RLB, BTT, SEI, BNB Chain's six, the five no restock has served and OP, the 335 Ondo stocks and ETFs of 2026-11-19 and ANTon"
        );
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(i < 4 ? first[i] : wide[i - 4], tokens[i]);
        }
        assertEq(first[0], MainnetAddresses.WETH);
    }

    /// @dev The router is pinned here too, written out independently of the address book like the table below, since
    ///      every swap of the zap and the builder goes through it and no test reaching only the address book would
    ///      catch a wrong one (RX-33). Pyth's address, pinned beside it until 2026-11-10, went with the oracle.
    function test_RX33_theRouterIsPinnedIndependently() public pure {
        assertEq(
            MainnetAddresses.UNIVERSAL_ROUTER, 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af, "Universal Router 2.0.0"
        );
    }

    /// @dev Every coin of the table is a token of its own, none zero: the factory refuses a token named twice in an
    ///      index, and a list that names one twice is a slip.
    function test_everyListedCoinIsListedOnce() public pure {
        address[] memory tokens = Listings.all();
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertTrue(tokens[i] != address(0));
            for (uint256 j = 0; j < i; ++j) {
                assertTrue(tokens[i] != tokens[j], "one entry per coin");
            }
        }
    }

    /// @dev Every coin of the table carries a tier, as the app and safe mode show it: WBTC, Tether Gold and the Ondo stocks
    ///         and ETFs custodial, three Wormhole copies and ten other bridged coins, and the rest issued on Ethereum.
    function test_everyListedCoinHasItsTier() public view {
        address[] memory tokens = Listings.all();
        uint256[4] memory count;
        for (uint256 i = 0; i < tokens.length; ++i) {
            Listings.Tier tier = Listings.tierOf(tokens[i]);
            assertTrue(tier != Listings.Tier.Unrecorded, "every listed coin is recorded");
            ++count[uint256(tier)];
        }
        assertEq(count[uint256(Listings.Tier.Native)], 48, "22 of the wide list and 26 of the hundred-coin list");
        assertEq(count[uint256(Listings.Tier.Bridged)], 12, "8, ZK and W, and 2 Wormhole copies");
        assertEq(count[uint256(Listings.Tier.Custodial)], 355, "WBTC, Tether Gold and the 353 Ondo stocks and ETFs");
        assertEq(uint8(Listings.tierOf(MainnetAddresses.WBTC)), uint8(Listings.Tier.Custodial));
        assertEq(uint8(Listings.tierOf(MainnetAddresses.ARB)), uint8(Listings.Tier.Bridged));
        assertEq(uint8(Listings.tierOf(MainnetAddresses.INJ)), uint8(Listings.Tier.Bridged));
        assertEq(uint8(Listings.tierOf(MainnetAddresses.SOL)), uint8(Listings.Tier.Bridged));
        assertEq(uint8(Listings.tierOf(MainnetAddresses.XAUT)), uint8(Listings.Tier.Custodial));
        assertEq(uint8(Listings.tierOf(MainnetAddresses.GNO)), uint8(Listings.Tier.Native));
        assertEq(uint8(Listings.tierOf(MainnetAddresses.ONEINCH)), uint8(Listings.Tier.Native));
        assertEq(
            uint8(Listings.tierOf(MainnetAddresses.ZK)),
            uint8(Listings.Tier.Bridged),
            "ZKsync's bridge issues it (RX-19)"
        );
        assertEq(uint8(Listings.tierOf(MainnetAddresses.W)), uint8(Listings.Tier.Bridged), "a mesh peer, home Solana");
        assertEq(uint8(Listings.tierOf(MainnetAddresses.AVAX)), uint8(Listings.Tier.Bridged), "a Wormhole copy");
        assertEq(uint8(Listings.tierOf(MainnetAddresses.AERO)), uint8(Listings.Tier.Bridged));
        // Wormhole's copy of OP, off since 2026-11-21: the restock found no route to buy it on Optimism
        assertEq(uint8(Listings.tierOf(MainnetAddresses.OP)), uint8(Listings.Tier.Unrecorded), "OP is off the list");
        for (uint256 j = 0; j < tokens.length; ++j) {
            assertTrue(tokens[j] != MainnetAddresses.OP, "OP's copy is listed");
        }
        // Wormhole's copies of the five coins with no Ethereum pool and no restock that has run, off since 2026-11-18
        address[5] memory unserved = [
            0x8687a10BCa6F139B25eb31020FCABB5782214764, // JUP
            0xeFc0CED4B3D536103e76a1c4c74F0385C8F4Bdd3, // PYTH
            0x84074EA631dEc7a4edcD5303d164D5dEa4c653D6, // SUI
            0x8CDf7AF57E4c8B930e1B23c477c22f076530585e, // APT
            0xe31Cfcd36FeD044ae4Cf9405B577fe875762194F // ALGO
        ];
        for (uint256 i = 0; i < unserved.length; ++i) {
            assertEq(uint8(Listings.tierOf(unserved[i])), uint8(Listings.Tier.Unrecorded), "no restock serves it");
            for (uint256 j = 0; j < tokens.length; ++j) {
                assertTrue(tokens[j] != unserved[i], "a copy no restock serves is listed");
            }
        }
        // Wormhole's copies of the six coins BNB Chain's deployment holds in kind, off the list since 2026-11-13
        address[6] memory onBnbChain = [
            0xc730d8256B8A1030eEA67f1Bc7ebed3898f7A535, // XRP
            0x8EfFbF747d4A60Bc6b68D9A1bE4c4188bA8A3a0b, // ADA
            0x1cA1Ef3fB8Ff4a480C0ae7eea5f91A24a5BB3344, // LTC
            0x1839a38E59536D88C25e8E6e0D0f59e05b143ab2, // DOT
            0x7845167B54253269624dBA0cA5Fee87933107b34, // ATOM
            0x418D75f65a02b3D53B2418FB8E1fe493759c7605 // BNB
        ];
        for (uint256 i = 0; i < onBnbChain.length; ++i) {
            assertEq(uint8(Listings.tierOf(onBnbChain[i])), uint8(Listings.Tier.Unrecorded), "held on BNB Chain");
            for (uint256 j = 0; j < tokens.length; ++j) {
                assertTrue(tokens[j] != onBnbChain[i], "a copy of a coin BNB Chain holds is listed");
            }
        }
        assertEq(
            uint8(Listings.tierOf(0xd881A7F17Ed2c71FD671AfbA3A9b30Eb914Aea5F)),
            uint8(Listings.Tier.Unrecorded),
            "DOGE's copy, off the list since 2026-10-14"
        );
        assertEq(
            uint8(Listings.tierOf(0x3845badAde8e6dFF049820680d1F14bD3903a5d0)),
            uint8(Listings.Tier.Unrecorded),
            "SAND, off the list since 2026-10-18"
        );
        assertEq(
            uint8(Listings.tierOf(0xC669928185DbCE49d2230CC9B0979BE6DC797957)),
            uint8(Listings.Tier.Unrecorded),
            "BTT, off the list since 2026-10-19 (RX-28)"
        );
        assertEq(
            uint8(Listings.tierOf(0xf91e605af079384cc7077B3914A4a36019a89EE8)),
            uint8(Listings.Tier.Unrecorded),
            "SEI's copy, off the list since 2026-10-19 (RX-32)"
        );
        assertEq(
            uint8(Listings.tierOf(0x046EeE2cc3188071C02BfC1745A6b17c656e3f3d)),
            uint8(Listings.Tier.Unrecorded),
            "RLB, off the list since 2026-10-18"
        );
        assertEq(uint8(Listings.tierOf(MainnetAddresses.VON)), uint8(Listings.Tier.Custodial));
        assertEq(uint8(Listings.tierOf(MainnetAddresses.USDC)), uint8(Listings.Tier.Unrecorded));
        assertEq(Listings.tierName(Listings.Tier.Native), "Native");
        assertEq(Listings.tierName(Listings.Tier.Bridged), "Bridged");
        assertEq(Listings.tierName(Listings.Tier.Custodial), "Custodial");
        assertEq(Listings.tierName(Listings.Tier.Unrecorded), "Unrecorded");
        assertEq(configure.tierLabel(MainnetAddresses.WBTC), " (Custodial)");
        assertEq(configure.tierLabel(address(a)), "", "a token off the table carries no label");
    }

    /// @dev CR-L08: the lists are the release record, pinned against this table, written out by hand rather than read
    ///      from `Listings`, so a slip in either shows.
    function test_CRL08_theListsAreTheReleaseRecord() public view {
        address[] memory first = configure.defaultMainnetList();
        address[] memory wide = configure.wideMainnetList();
        address[415] memory tokens = [
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
            0x85f138bfEE4ef8e540890CFb48F620571d67Eda3, // AVAX
            0x750525C1877E30304F1E22b1b49b4C9DdE674ddF, // AERO
            0x36B90aDcDC99Be31BF39A3c031288bAa0B457E10, // GOOGon
            0x62cA254a363dc3c748e7E955c20447aB5bF06fF7, // IVVon
            0xFeDC5f4a6c38211c1338aa411018DFAf26612c08, // SPYon
            0x57B392146848C6321bb2A3D4358DF1bDEACdc62A, // VTIon
            0xF05Ad9840924EA6f977EBccb3b1da87e31DcD0B4, // XOMon
            0xdd0E1e6162666a210905fFE8d368661B313c00e9, // JNJon
            0xA29dC2102dfc2a0A4A5dCb84Af984315567c9858, // MAon
            0xE51bA774ebF6392c45Bf1d9E6b334d07992460d3, // ASMLon
            0x7c7378143a9c8839e0502e2178F058F46c6ea504, // ABBVon
            0x0c8276E4FeC072cf7854Be69c70F7773D1610857, // COSTon
            0x0e397938C1Aa0680954093495B70A9F5e2249aBa, // QQQon
            0x74a03d741226f738098C35da8188E57acA50d146, // KOon
            0x8F3E41b378ae010c46d255F36bFC1D303b52dceb, // CVXon
            0x339ce23a355ed6D513DD3e1462975C4eCD86823a, // PGon
            0x0c666485b02F7A87d21AdD7AEb9F5e64975AA490, // PLTRon
            0x980a1001ee94e54142b231f44C7CA7c9DF71FBe1, // CSCOon
            0x8a23C6BaadB88512b30475C83Df6A63881e33e1E, // ORCLon
            0xD904bCf89B7CedF5c89f9Df7e829191D695F847E, // GEon
            0x576E9CA70e3a040c00d8139b0665a2b7b7B64844, // BACon
            0x7DBd435aa4eCAB5471CFCeF4527a022feF0b7e1C, // HDon
            0xdc8a7Db05EA704227D56F5D4a4b77A2d1bbA29c0, // MRKon
            0xFdA09936DbD717368De0835bA441d9E62069d36f, // INTCon
            0x075756F3b6381a79633438fAA8964946bf40163d, // UNHon
            0x34bfdFF25F0fdA6d3ad0c33F1e06c0D40bD68885, // PANWon
            0x6bE935eaDc71c49c414b1175985946ee40365c67, // AMATon
            0x21bE23f5bF87A749670c088F6DEe26760F1Ab80F, // LRCXon
            0x58fC9d573Ea773ef9a25c3DE66F990B87Ee5f50E, // TXNon
            0x67c5902F5210F62f37157cd9C735c693164c1378, // RTXon
            0x60808f2a0d035e16F57e9043842BD1BFBda24fA2, // TMOon
            0xCaC9AAfb2cf51645Ae1ab4Fb1F35F07d42437f80, // CRWDon
            0xF719b02079E0FaA5450392DA2D3e11a1e5b0EADB, // CATon
            0xdB57d9C14e357Fc01E49035a808779Df41E9B4e2, // GSon
            0x20e113E9235dF6A2A9BFc6f244c2ccC380c8f546, // ANETon
            0x032deC3372F25C41EA8054B4987a7c4832CDB338, // NFLXon
            0x4AD2118Da8a65eaa81402A3d583FEF6eE76BDf3F, // WFCon
            0xCAfD1c0EE8B392cb446e3E745A4ADEfF7A861995, // SAPon
            0x1c5FA55eAdE69ae98571059332520F73733C2D82, // AMGNon
            0x01B19c68f8A9eE3a480dA788ba401cFAbdf19B93, // LINon
            0x25d3f236B2d61656eebdeA86Ac6D42168e340011, // IBMon
            0x41765F0FCddC276309195166C7A62AE522FA09ef, // BABAon
            0x2Bc7Ff0C5dA9F1a4A51F96e77C5b0F7165DC06d2, // AXPon
            0xc3D93B45249E8E06cfeB01d25A96337E8893265d, // DISon
            0xA043FDc5A6E2E381e3532d5A97404b82fb7A0af8, // GEVon
            0xeE9f43476C5b7292b114bA1b280A42A8746792d4, // DELLon
            0x5Bf1b2A808598C0eF4Af1673a5457d86fE6d7B3d, // ARMon
            0xC46e7eF70d7Cf8C17863a6B0b9be2aF6a4C41aBe, // Con
            0xD9C1b5df94063177CF168680b695A417919aE1ae, // APHon
            0x4C82c8cD9a218612DCe60b156B73A36705645e3b, // MCDon
            0xa637ae510cB50E61236a89AC480B93B8c3bcCc46, // KLACon
            0x3cE219D498D807317F840f4CB0f03FA27dd65046, // PEPon
            0x84E8f1b9b40DD1832925702459D12FFb14d97bF3, // VTVon
            0x0e3D889D5B857C3e6eb361B9C9aE35bb7DdbD254, // VZon
            0x2dDc2391CC89E3e716A938F089AE755174cfDf1f, // ADIon
            0xFEFf7a377A86462F5a2A872009722C154707F09e, // IEFAon
            0x3859385363f7BB4Dfe42811cCF3F294FcD41dd1D, // ABTon
            0x7a0F89c1606f71499950AA2590d547c3975B728E, // BLKon
            0xE3419710c1f77D44B4DaB02316d3f048818C4E59, // QCOMon
            0x908266C1192628371Cff7AD2F5Eba4dE061a0ac5, // SHOPon
            0xF46BA88694cd7933Ca28Be84EE787Ad5732e856B, // NEEon
            0x39930751d4569F7DD45d1bA46E82CD3680EC2e0a, // UNPon
            0x28151F5888833D3d767C4d6945a0Ee50D1B193E3, // NVOon
            0xdEb3C23f93349229823A006657CfE1a6552B6340, // TMUSon
            0x32d7c413fD3477E86b8eC6B0BB8F3Ac510eAfaae, // DEon
            0xe737f948bDFe3bEAe9423292853EC0579173cebB, // SCHWon
            0x8E6A5338eaC4B6fE8D51a7653Fad3B9DA755Eea6, // COPon
            0x06954faa913fA14c28Eb1b2e459594F22f33f3dE, // PFEon
            0x55720eF5b023Fd043AE5F8D2e526030207978950, // CRMon
            0x3361A73262199873b74D6835760a59B8817fa592, // Ton
            0x2691b13fca1E02322685b9554B5ae0F5F3f05C55, // ISRGon
            0xfF7CF16aA2fFc463b996DB2f7B7cf0130336899D, // AGGon
            0xcDD60D15125bf3362b6838D2506b0Fa33bc1a515, // IEMGon
            0x5Bcd8195E3Ef58f677aeF9eBC276B5087c027050, // UBERon
            0xFC003a764a7B5054Cc6fDb6b511F35deC8022751, // VRTXon
            0x691b126cF619707Ed5d16CaB1B27C000aa8De300, // LMTon
            0xF404E5f887dBd5508e16a1198fCDD5DE1A4296B8, // MRVLon
            0x9b56f5ED5A94Ae3266b7FF21953e6626F94008F1, // ETNon
            0xAbA9Ae731Aad63335C604E5f6E6A5db2e05f549d, // ACNon
            0xbc843b147DB4C7E00721d76037b8b92e13AfE13f, // SPGIon
            0xd5C5B2883735Fa9B658Dd52e2FCC8d7c0f1A42Ce, // APPon
            0x57270D35A840BC5C094da6FBeCA033FB71eA6Ab0, // BAon
            0xB53894f82a6B2d3B7365f24932B5bDE1c5Fb51FF, // STXon
            0xdA81DA76070a7377eAEEB2978F0E13C5d57FaDb7, // SCCOon
            0xcC40965d3621362C3EE1dD946bA98d6A708ea86B, // PDDon
            0x423D42E505e64F99b6E277eb7ED324CC5606F139, // GLDon
            0x84328D8B85019FdCeCf4c82FBE076Bf350FC0cab, // LOWon
            0x590F21186489cA1612f49a4B1ff5c66acD6796A9, // SPOTon
            0xf15FbC1349ab99ABAd63db3f9A510BF413bE3BeF, // SBUXon
            0xFd50Fc4E3686a8DA814c5C3D6121d8aB98a537F0, // IJHon
            0x8De5D49725550f7b318b2FA0f1B1F118E98E8D0F, // SGOVon
            0x44e89d34601b8D0155e16634d2553EF7F54DBab2, // WDCon
            0x71E2400CF1Cb83204f33794eD326636A71a9AAfC, // SNDKon
            0x8d05432C2786e3F93f1a9A62b9572DBf54f3ea06, // IWFon
            0x4f5A3B3E184b1424816D9107448314ba0aAd63e1, // NETon
            0x3D07c3161F355Cb9E5B524beF8d113c96e0263AB, // COFon
            0x99aA107e55250a9fE52bB4b5541A59239EB6D974, // SOon
            0xD08DDb436e731f32455Fe302723eE0FD2E9E8706, // PBRon
            0x0C802aCB21Cb2AadB2EB5E5090868E1361B26B69, // NEMon
            0xb035c3d5083bdc80074F380aeBc9Fcb68aBa0A28, // ABNBon
            0xB2e9Ec5c62f78596cA4a21a21570b9a00c6D226c, // ENBon
            0x73d2ccEE12C120E7DA265a2dE9d9f952a0101b4f, // EQIXon
            0x5D1a9a9B118fF19721e0111f094f2360b6Ef7A2f, // SNOWon
            0x33aC34DA58168De69cE74a66fbaD81a88F974BD5, // REGNon
            0x8bCF9012f4b0c1C3D359eDb7133C294f82f80790, // NOWon
            0xE45575b8895664DEdf7bEfFEe98b078F2Cf1A192, // GLWon
            0x1fb5a8DCd70bE750a97Eaf8a47bBe74Ab7d3183e, // WMon
            0xD68fa0978C257aace5BEc5246b201B56E838D45d, // GDon
            0x0692481C369E2BDc728A69ae31b848343a4567Be, // ITOTon
            0x060505527C83E8BfEb9b4Ff08248B82e688800F1, // CEGon
            0xB4d71137656150E97f3ed2C18d4a30bE138D8f2e, // PWRon
            0x26E78f7170d8Cc3bd3865d37CE4c554B65B1C9ba, // TTon
            0x26719965000A3DCAcc1451F836FbB9c883CCDe85, // EMRon
            0x7042a8fFc7c7049684BfBc2fcb41b72380755a43, // ADBEon
            0x6cc0afD51CE4Cb6920B775F3D6376Ab82b9A93Bb, // INTUon
            0xfB6d594CccfDEd3606e1500b92a26b8B43a35071, // WMBon
            0xFe4eC50E0413148021d2f50d114CC44De6fFBF23, // CVNAon
            0xA2C1c0b4683a871187d4565Eb63ABF9AEF5947Ee, // MRNAon
            0x8Ce34F749796F82A6990fFa2d80622ef75CA7aD5, // NOCon
            0x0752163d221d3D5d4B6e98bD616B22bd2b453964, // VRTon
            0x4111b60bc87F2Bd1e81E783E271D7F0ec6EE088B, // EFAon
            0x070D79021dD7e841123cB0CF554993bF683c511D, // IWMon
            0xeb08d539Be0f6a6C90eA24276196E348f5688A02, // FCXon
            0xCEA4290d6578f0253308304F7184eA2E8F5EB0E4, // SLBon
            0x241958c86c7744d15d5f6314BA1Ea4c81DDA2896, // DASHon
            0x4D21aFfD27183B07335935F81A5C26b6A5A15355, // APOon
            0x2816169A49953C548BfEb3948dCF05c4A0E4657D, // MELIon
            0x3d1cF8692A6f2Fc9048A9cc1A06aBF77F3465f0a, // NTESon
            0x998f02A9E343EF6E3E6f28700d5A20F839fD74E6, // HOODon
            0xE67AbcA57E1504a26bd2eD209F2e0C09543Fd7Eb, // HPEon
            0x7C17a5423200246EAFdd9fa0f5d70eAde3067Dd6, // TELon
            0x167f8D6B357FA9fff9B1286E519Bd32d4504757E, // NUEon
            0x4f0CA3df1c2e6b943cf82E649d576ffe7B2fABCF, // IAUon
            0x113faE6e1103A4C09250C8697a6a4BE6Ca987d06, // AMEon
            0xeedC48205852E9D83Ea5cA92fa8656597788601f, // OXYon
            0x92e04b1fCC2b16347820241D226853Cf01C9eBAB, // BEon
            0xD8e26FcC879b30cB0a0B543925a2B3500f074D81, // NKEon
            0xbF5ab848efff75D897a3DBE4647B939C59D3cdb0, // LITEon
            0x1E328BBCd67e1bbEE198bb3F90e764812e6E0AC9, // KEYSon
            0x122940c4C5F9cCFAe7Fa86455a42D3EC140855cE, // IBITon
            0x2710E30d84B376c34a3B3036aa196b26a83A321b, // BILon
            0x4EFD92F372898B57F292De69fCe377dd7D912bDd, // PYPLon
            0x992651BFeB9A0DCC4457610E284ba66D86489d4d, // TLTon
            0x6cC41275ef02B4EecCC04fC4424849A96f3272aa, // XYZon
            0x25018520138bbaB60684AD7983D4432E8B8E926B, // CMGon
            0xf72936FA8afC808c99eb76E620A98DDC6a7A53d1, // Fon
            0x2B7727076B9C9B1834a2f95B81f12EEdD30db9f1, // COHRon
            0x01E7eaF05Be1d0c2D1834fC65080188376026d07, // NOKon
            0x3F5331EC2B6DFd249BE361f4626eAe442D1e5432, // NTRAon
            0xA2eC76139028F279A1C790d323c57Cc4158098d6, // IEFon
            0xf1573EdDDB75BF7Ce165f142A17Ed6b5E7f5aA13, // VSTon
            0x4ef7A9145e7B3C92E23A97FB41A9F4E9856288CB, // ROKon
            0x1fE2126bC05E4BB0468C4a198e930c889e1054a3, // SOXXon
            0xa32847395b007ee4a40407E3DD2f8F9bF56Ca6aB, // DYNFon
            0xF5852886Fff060dF3Af99a4246456fCa26445e8c, // STMon
            0x6C190f0b8f7525244C6dcf0363A1241a99509101, // TTWOon
            0x1ffAc2Df9696868D06F9fe8d72fEE9e1452eeF76, // CIENon
            0xd6D09189B6fD611A75435e4a123e373A56Ab0e41, // ALABon
            0xCabD955322dfbf94C084929ac5E9Eca3fEB5556F, // MSTRon
            0xcCAe8843E26259278C200C6506F6E5A3bdD524cd, // VNQon
            0x1d1b9ae25722d0B27dB23171CFeE0C269B203695, // TERon
            0x36E3b8d9aAd0e51aC08E56a75A8f6005bF68535B, // RKLBon
            0x9784508a0758cBb43eCb9b62F4CF4b1b3a36480c, // UMCon
            0xdeB6B89088cA9B7d7756087c8a0F7C6DF46f319C, // JDon
            0x219a1b27baA08D72fAC836665a3B752F3C9aCBBC, // JAAAon
            0x1630281079eBaC2E873FB1F1cB41df3D0e451E23, // CLSon
            0xf9D5aF26E1B96625dBC86609463A06602bE42966, // STLDon
            0x05d2d23398756821dC3DE359ffCe8EBbD50af8c5, // EQTon
            0xE4babaa960bA7D37860f3fe00D7b95D3868e8EDc, // NBISon
            0x0431067992F312B40D30C476fc11f8AFDD1E0E90, // INSMon
            0x193Fdf644451CC394b28B9Cec2F5D32E2b4dE515, // PCGon
            0xF042cfa86cf1D598a75Bdb55c3507a1F39f9493b, // COINon
            0xa45cd7ac9865b9539166ebaf2aBc362Df4736580, // TQQQon
            0x1252c5fa0a4031F6843D5Cf8d4986Ba99a8A9b42, // EFVon
            0x4493E670F5a077D46Eb3389fFA9Af19999Ea54eD, // FLEXon
            0x5C424B9b60383FCE7fE7069D2a2B1047BCd04a73, // SHYon
            0xc5a72B01Cc9e2721DC6dE1A35Ab8d92A6AA273e6, // VRSNon
            0xA9F9BE37b19F261AB067C5f7DEDA2c969Ec66944, // CCJon
            0x66908813cd7676269494B2c6F6DBAB8B4f9E95df, // CRWVon
            0x398f7f759380F3d309B9fC0E6cB3D36E0D67818d, // TCOMon
            0x77A1a02e4a888ADA8620b93C30dE8a41E621126c, // EEMon
            0xa52B2D6cA1CD9B1E8b931645428380c340cAEF9A, // ONon
            0x596b790CceE1032F6658Ac2c78a119cCE69727FC, // HALon
            0xFA9f0Bf8baa9A3D5E0a8E5c0AeAF186ACaBef63D, // CPNGon
            0xD9584f80CCE13afC96BfD0188fd5C81E08f18C85, // JBLon
            0x9d4C6AD12B55E4645b585209F90Cc26614061E91, // BIDUon
            0xB348a4Bce7FaE890d2d37Ea104e59fb3881757c2, // CRDOon
            0x61882Bb63aF8e6A39531175CdfDe1Fcd98346503, // CBRSon
            0xF3e4872e6a4cF365888D93b6146a2bAA7348F1A4, // SLVon
            0x24e7504246DFdd7E866936e2816BFbEa73bd890a, // HUBBon
            0x1577D4ae114B6F217453b754AeaC164db44832DA, // IYWon
            0x625Fb557cAD6D4638dae420626F3F08A485b43a8, // EWJon
            0xB326821B68313082F00A1A4d6Fa3f924D3E826Dc, // GFSon
            0x44Abf03ca01B8e7877bC3Dbc37b132F6f25E9450, // ENTGon
            0xFb82561A955bF59B9263301126AF490D3799e231, // USFRon
            0xbd660e96D45e7C175512d1ed0cCc119Cb980b81a, // EWYon
            0xC15F11599828b0afB0C071994679EF9E685F9E2E, // SWKSon
            0x9f2e3EB0160117c56b07652Fe66a08a48b5bD7B5, // SOFIon
            0xeD3618Bb8778F8eBBe2f241Da532227591771D04, // HYGon
            0x38cBBBF83Ab583E231960B5c112145324Bef55ae, // NVTon
            0xA9431d354cFAD3c6B76E50f0e73b43D48Be80CD0, // RDDTon
            0x6e9C4BcEDDd057D66b65794A0093ad95c5fa0Cc4, // MTSIon
            0x04d94914Cd1D7FF749eFedEe764335777225b962, // RIVNon
            0xa0Db1eCa4AaEBCa03A3c04ed221b036Dd3CcB025, // LSCCon
            0x2ca12a3F9635fD69C21580def14F25C210cA9612, // SMCIon
            0xc80C91BC6215E1333eA98314b8671d6e26c58470, // TLNon
            0xF87efCA06f6Af53Cb096847bA092ccd04395A192, // WCCon
            0xEbe0D1B1d50bC68458Fcdc45C3c276d57CDC422B, // TSEMon
            0xD62C0Bf1e1dD6F4FEe1b3D042A9E479Ad1Fb1BCb, // LECOon
            0xDc4F9c9CAa96046816255Bc6c10fd6433863128E, // MKSIon
            0x2Df38cA485D01fC15e4FD85847ed26b7EF871c1c, // TIPon
            0x3632DEa96A953C11dac2f00b4A05a32CD1063fAE, // CRCLon
            0x5cb95099a2C7e3C8187fbca6eFe5ba222b5bA820, // MTZon
            0x9DCf7f739B8C0270E2FC0Cc8D0DaBe355a150dBa, // IWNon
            0x71d24Baeb0A033ec5F90FF65C4210545AF378D97, // GMEon
            0xd318bBBE6B6E83F74e7aCAEb5e94C08ddbDb44c0, // SOXLon
            0xD4c6CCE0Cadf2fe4C0AF9eE6777989EFD8fB7670, // PAVEon
            0x5Ce215d9c37a195DF88e294a06B8396C296B4e15, // FUTUon
            0xa9E5c59f34397fe6Baa9E4dA139bA4E63Bd84324, // IGVon
            0x1C174711f3FD63C4165d6F296b3eB19D17fde94a, // GRABon
            0xD120f60FeC8189ed4a2346E10107B0F1F61354Cb, // GNRCon
            0x93A96721a624822A6aB6461A7891a5C6b154102F, // FNon
            0x68622855dcf14ced1B0Cc2A69cc34843708e2E0f, // ITAon
            0x10bd54f1F4DC19bE0c46B1Ea7E5f38FD2eaFeE26, // HIIon
            0x2F2e4b09B99fbf018F600e031aAfD9Da6347Cc75, // IONQon
            0xb6E362a39db703f0F7cF582C9fc043A51624e53d, // LIon
            0x1b468d5535Ed7C19Ce42f0073db7Fdf441028131, // ALBon
            0xC29FF16a7B0a895E9fE05c32Ce3f26c44e8eca3D, // ONTOon
            0xC017C622cd05698580E2decD0F97d4A17DaB70F9, // PINSon
            0x80d04221eC124850C4B9ba8f625b9a12AD609200, // NVMIon
            0x33483A58079b4225b10e57958Ca28ad7b9CDbAF7, // BMNRon
            0xB2924278cc92E60DB9b673d6A311d7a331dD703D, // SNAPon
            0x073E7a0669833d356fa88ca65CC6D454EFaAa3c5, // FIGon
            0x2A5ae1BdE731cb8732fD762073DD0bBE151360B9, // AIQon
            0xF02b8309df07641dDcFd1DABCeFFDde3d30915De, // AMKRon
            0xBE8eb7b51a08f9d52Bb6C8c7EcA699f0f89BfC02, // AALon
            0xae1c6E353cdc9Dc3CC01124FFB62a0d0Ce64a401, // RMBSon
            0x244EFb92f76a57da49B5F71045dcE3E546E13106, // OSCRon
            0x9ba8789ab8A3AD1502814c375f0b18A03fc3634E, // TWSTon
            0x54021fDe36B7c4C4F9C35b02fb9A153eD8F5938A, // EWZon
            0x0D1fa4E1E3719945899Ef7b02840627Df46aF44A, // ASTSon
            0xFc9D0eBBd17d3aAa336a50488795806c69EA4b32, // AURon
            0xDEbb8E6F581655759e3D64f769247a007AF0aE36, // TTMIon
            0xdf3F2315D124F7F8b714Ba031d6e69aA16a61FA2, // HUTon
            0x6c51001149c7782820c107ADcE650692aB6c5378, // VICRon
            0xa6CdB19b22B03e03EA89e133A8a46aDc3017aa6d, // INDAon
            0xa95837130Bcbc0AD99e188E22F674E4eC6925be2, // CLFon
            0xEe2542F442a5ed8008e2fe3590e14F90DB69f70d, // NIOon
            0x21deafD91116FCe9fE87C8f15Bde03f99a309b72, // RIOTon
            0x75846A2b2Eeee6575Ac775f9984be54fd1D08189, // MPon
            0x6401365aA495ca96Bcfcf9c6c47Bd4a590336b00, // FORMon
            0x0b59fDb1A233A7477ea14061004b9DD776e73CB3, // IRENon
            0x110CAe53912C2Ed9bF279CD70B3b699e26C79E58, // WULFon
            0x410e7D6B6303E531753D4fbe3e50e35EfBcFf53c, // FPSon
            0xc2dBFE026f17e7BbC17a9e41F9b8D69531887d47, // FIGRon
            0x1b8085e78877dfBA98692Cb918809b35f6280015, // POWLon
            0xFb4Aa24c9c4E65f82d57d268dA8a65a0dE0DC43B, // SHLDon
            0xaa26e62e51bc5da24ED2B6Fc6491e137d68824B9, // AGon
            0x4a0A962E5b3df711AFab01fFFE34C4F31e452697, // CAIon
            0x98284FbC11eDD7540E29b896a49817Bbe52DdCBd, // ETHAon
            0x423A63dfE8d82CD9C6568C92210AA537d8Ef6885, // COPXon
            0xddAf7945093ad7457228c185783FDf6aB25022B2, // CORZon
            0x7e08cE07acA80CefE61ebbFA0CedFe5C7b07eDB9, // BILIon
            0xD1C3bF5DdE6ee17Ae2a472a8C4f0258e0B350cb4, // MXLon
            0x318Dcb4f07C3e6ccEcc12A252100Fb3Bf76Eeb02, // APLDon
            0xa656C5Dd6B64b3AcB6E32aF8A876a48B5748f858, // PLon
            0xeAA2287290544eD9F481012aa348619A4D2F9e51, // KWEBon
            0xF0372e226553aF4F343b44111A789f87A9fa427A, // OKLOon
            0xf98Ec282300892b3518B5cB996012b18d9B7D435, // URAon
            0x6987F17A188c3B64F4892f0E31C2ccd88F54FCFd, // VSHon
            0xCa468554e5C0423Ee858fe3942c9568C51FcAa79, // HIMSon
            0x99888f2CCD08258eD5F66e94bA59d7E75016900F, // AAOIon
            0x2dD57b497c777D9825A5902114BE81dF98eDE958, // FXIon
            0xBa6FF85f4595a3E71F3a965E6B528bBcf51A2c79, // PRIMon
            0x24E5Bc45d5b6Cef6F38989AC33dF587a3FC850cf, // CIFRon
            0x4F3B49aC895a29c0908c57538932967Cdc8e3c80, // ENPHon
            0x334ccd8Df4013bac99Af8C5C61d3605B315302a0, // BLSHon
            0x3807562A482B824C08A564DFefcc471806d3E00a, // QBTSon
            0x0F8887772262c449793890DCD3Bf320308dB423B, // UECon
            0xfDFDf5db2F4A72cb754FfA8896EA012dC2cc0F5e, // RGTIon
            0x7AbeC847A3f9820397C82E1DAd231721Bf5a6732, // BOTZon
            0x41fA6d32917E17cF29a5e93940471492D7c301C8, // PENGon
            0x818234860A647D480b9BBCC9a47A23889f2Ec900, // ONDSon
            0x592643a667633bCa51Cb2387C98B6dE6CE549A45, // AMCon
            0xE2c149FA719d43912BfE584c71c9a6a018a5e916, // USARon
            0x4032d3076974b89238adfe61085EC57fC4522646, // SOXQon
            0xe5b26BA77E6a4d79a7c54a5296d81254269D9700, // GRNDon
            0x9cFA08002d606e638Fe91941bE725e1b970B84a6, // ACHRon
            0x4604b0b581269843ac7a6b70A5FC019E7762e511, // MARAon
            0xE668e08a6f5792CEF0e63E9D98524968fDB5882f, // GLXYon
            0x6a3E77d984e22bed6A036D3DA79D7857936a593f, // AXTIon
            0x67A47353D5449fC24088190c44247d4D4E296073, // OUSTon
            0x2D9fc6C5dD136658ab6190f356ae3186c4Daa7D5, // NVTSon
            0x1F5fc5c3c8B0F15c7E21AF623936FF2b210b6415, // USOon
            0x0a00c19246Fc41B2524d56C87EC44Ce8b30Ba0f8, // SQQQon
            0xDaA3b81a3ACFcB60b875eBA1D26852376BC38486, // RXRXon
            0x01eb2eE6Ec05C304666210133B762088FF9965aC, // SOXSon
            0x58a2EDF0169eDE82904e47a0E2a3a4008eDebB60, // LUNRon
            0xBcA31049ab4782f0FfA9CfFCB2cF48e8D6dE4fb8, // OIHon
            0x3a16aF9Ef328D087cc781053A2a2a27549aE6768, // RDWon
            0x211d1d372E6A782e9786b045004382834bDB224e, // PURRon
            0x7AA59A63d1D0C435a08bC96E11bef2E95aB66c40, // DNNon
            0x4554ad55ccA5e7CB97B77813f486aAf6D4D9AB62, // AIon
            0xeB48e68F01c0C76735dc6F1dcC0F151A973BD9d2, // AEHRon
            0x613518b520241f90c3E023Bb6006c63A5019CA7B, // WENon
            0xf1883461Ec7BD883A3668749c5CF5f351080d059, // PPLTon
            0x0a600856eEDCe367eD49C3cd399775DC95d8BB5a, // SMRon
            0xa65db7879774BD6758ABaF583A91177AfD96D5A3, // URNMon
            0xF14d47AeD45e16BF1f6E06904ac7f852FCe6cdf4, // UUUUon
            0x966dB065199A3edEa2228C6E5Eb6Ac49FF251AcC, // SOUNon
            0xe7ee911172bDD557B9Ab6Be7701F86BBc8FD772E, // PLUGon
            0x65513b741541025731124408DEb1A714699E3ee8, // IGEBon
            0x8E82a0d7347329703FB6c6A745B1C2b3aBB1658c, // SEDGon
            0x995584539633F7d28757B6329A42439BD8aeCEde, // WOLFon
            0xB22d83E228c4266075Ec75c32aCc3BC059B6f248, // OPENon
            0xc95c9e3fA311664b5e744B3C2716547BEc2Ba7dA, // QUBTon
            0x96c662b152BEC886fAcab388bd98470FD3Aa9737, // KEELon
            0x1C99a152e00a5dc40f8c3e893C1d04b0F6a48B0f, // INODon
            0xfDb46864A7C476F0914c5E82CdED3364a9F56F8a, // SBETon
            0x0683154c33B7563ed39951B4d7C0470EA28D93e9, // BTDRon
            0x1b8d3e59b31981385C066eE0916Ec964628ff1f9, // BBAIon
            0x9ddb2524782684942FAD28b44E76552cB7f3F548, // BNOon
            0x9ebd34d99Cc3a45B39CAFc14Ad7994263fa2Be56, // PSQon
            0x22a684E0A3cc9B74596719F722cf4e597AAFA3bA, // CPERon
            0xb71c4EBB4eDbAd867290206239C19DBb59eD55E1, // FCELon
            0xf6C9C6b33BD3df0d761702db7075f89e561A54D8, // FLNCon
            0xb5dd7ff8E2e4019cA7a55f10C13282071a5775D4, // NNEon
            0x0e05BA0756C504B69AAA642f7379CD1AF7C63969, // BOTon
            0x0cE36d199bd6851788e03392568849394cBdE722, // PALLon
            0x510Dd21055188Eda378714DE3bb5591Ffa0CC468, // BTGOon
            0x9A73A9CC7c5889C521423870e896904F71562504, // LPTHon
            0x185E5FA1B84F94D46ef2A33052aD39bD5f326fd8, // EXODon
            0xEcA55ac71f83931B7e074228AEBc9104F13d8c02, // BWETon
            0x9463b0EE32c1b40B7fdA6459e815F0790159bC3A, // BAIon
            0xdB5a8f5B4C17f2Ee2e7192A150687E48eB3C415d, // DRAMon
            0x141196732cE4BB20010E4149704C0F278d5d3CEA, // SATAon
            0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c, // STRCon
            0x43a0943893474F246aA58e9921d975aD60Adee59 // ANTon
        ];
        assertEq(first.length, 4);
        assertEq(wide.length, 411);
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(i < 4 ? first[i] : wide[i - 4], tokens[i]);
        }
    }

    /// @dev Each named list resolves on its own chain only: Ethereum's two on chain 1, BNB Chain's on chain 56.
    function test_theNamedListsResolveOnlyOnTheirChain() public {
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.ListOffItsChain.selector, "default", block.chainid));
        configure.resolveList("default");
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.ListOffItsChain.selector, "wide", block.chainid));
        configure.resolveList("wide");
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.ListOffItsChain.selector, "bnb", block.chainid));
        configure.resolveList("bnb");
        vm.chainId(1);
        assertEq(configure.resolveList("default").length, configure.DEFAULT_COUNT());
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.ListOffItsChain.selector, "bnb", 1));
        configure.resolveList("bnb");
        vm.chainId(BnbChainAddresses.CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.ListOffItsChain.selector, "wide", 56));
        configure.resolveList("wide");
        assertEq(configure.resolveList("bnb").length, BnbChainAddresses.COUNT);
    }

    /// @dev The BNB Chain list is `BnbChainAddresses`' table: WBNB, BTCB and ETH first, one entry per token, every coin
    ///      carrying its tier, and none of the coins the owner's rulings exclude.
    function test_theBnbListIsTheTable() public {
        vm.chainId(BnbChainAddresses.CHAIN_ID);
        address[] memory list = configure.resolveList("bnb");
        address[] memory tokens = BnbChainAddresses.all();
        assertEq(
            list.length,
            365,
            "the BNB Chain list of 2026-10-07, less SOL, DOGE, AVAX, FIL and TRX, the 352 Ondo stocks and ETFs of 2026-11-19 and ANTon"
        );
        assertEq(list, tokens);
        uint256[4] memory count;
        for (uint256 i = 0; i < tokens.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                assertTrue(tokens[i] != tokens[j], "one entry per token");
            }
            Listings.Tier tier = BnbChainAddresses.tierOf(tokens[i]);
            assertTrue(tier != Listings.Tier.Unrecorded, "every listed coin is recorded");
            assertEq(uint8(Listings.tierOf(tokens[i])), uint8(Listings.Tier.Unrecorded), "and is no Ethereum token");
            ++count[uint256(tier)];
        }
        assertEq(list[0], BnbChainAddresses.WBNB);
        assertEq(count[uint256(Listings.Tier.Native)], 2, "WBNB and ASTER");
        assertEq(count[uint256(Listings.Tier.Bridged)], 1, "STABLE");
        assertEq(
            count[uint256(Listings.Tier.Custodial)],
            362,
            "BTCB, ETH, the seven Binance-Peg coins and the 353 Ondo assets"
        );
        assertEq(configure.tierLabel(BnbChainAddresses.BTCB), " (Custodial)");
        assertEq(configure.tierLabel(BnbChainAddresses.WBNB), " (Native)");
        assertEq(configure.tierLabel(BnbChainAddresses.STABLE), " (Bridged)");
        assertEq(configure.tierLabel(MainnetAddresses.WBTC), " (Custodial)", "Ethereum's labels are unchanged");
        assertEq(configure.tierLabel(BnbChainAddresses.USDC), "", "a mint currency carries no tier");
        address[5] memory excluded = [
            0x570A5D26f7765Ecb712C0924E4De545B89fD43dF, // Binance-Peg SOL: held on Ethereum as Wormhole's copy
            0xbA2aE424d960c26247Dd6c32edC70B295c744C43, // DOGE: a proxy one key upgrades
            0x1CE0c2827e2eF14D5C4f29a091d735A204794041, // AVAX: the same proxy admin
            0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153, // FIL: the same
            0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3 // TRX: its bridge closed
        ];
        for (uint256 i = 0; i < excluded.length; ++i) {
            assertEq(uint8(BnbChainAddresses.tierOf(excluded[i])), uint8(Listings.Tier.Unrecorded));
        }
    }

    /// @dev CR-L08 for BNB Chain: the list is the release record, pinned against this table, written out by hand.
    function test_CRL08_theBnbListIsTheReleaseRecord() public view {
        address[] memory list = configure.bnbList();
        address[365] memory tokens = [
            0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, // WBNB
            0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c, // BTCB
            0x2170Ed0880ac9A755fd29B2688956BD959F933F8, // ETH
            0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE, // XRP
            0x1Ba42e5193dfA8B03D15dd1B86a3113bbBEF8Eeb, // ZEC
            0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47, // ADA
            0x8fF795a6F4D97E7887C79beA79aba5cc76444aDf, // BCH
            0x4338665CBB7B2485A8855A139b75D5e34AB0DB94, // LTC
            0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402, // DOT
            0x0Eb3a705fc54725037CC9e008bDede697f62F335, // ATOM
            0x000Ae314E2A2172a039B26378814C252734f556A, // ASTER
            0x011EBe7d75E2C9D1E0bD0be0bEf5C36f0A90075F, // STABLE
            0x390a684EF9cADE28A7AD0DFa61AB1Eb3842618c4, // AAPLon
            0x6Bfe75D1ad432050eA973C3A3DcD88F02e2444C3, // MSFTon
            0xA9eE28C80f960B889dFbd1902055218cBa016F75, // NVDAon
            0x091FC7778e6932d4009B087B191D1EE3bac5729A, // GOOGLon
            0x817f1f6780F99BCaAc394A59CB0261962df5Da8b, // GOOGon
            0x4553cFe1C09f37f38b12dC509F676964e392F8Fc, // AMZNon
            0xd0a58BC9D88D3FF48C0294Cb7e45937d0E41A928, // SPCXon
            0xC37042A7a4fa510D8884a433762aB87257B91965, // TSMon
            0x0ED2E3180EDf393e6bf8Db124bD15DDD54dE150A, // AVGOon
            0xD7dF5863A3e742F0c767768cDfcb63f09E0422f6, // METAon
            0x2494b603319d4D9F9715c9f4496d9E0364B59d93, // TSLAon
            0x341D31b2be1Fee9C00e395A62bA41837F4322EEd, // LLYon
            0xa7d1e886acf66Ec0656DF2DECB4B7C893A3bAb4C, // WMTon
            0x4268F2Bfb23A7496504AA5eD1Ee325248586299F, // SKHYon
            0x317bF42b43A394860718266Dec445DCC9FD9dA49, // JPMon
            0x1104EB7e85E25eB45F88e638b0C27A06C1A91CB2, // IVVon
            0x8b6ACf6041A81567f012Ff6A4C6D96d5818d74bF, // MUon
            0x9f16E46c73b43BDB70861247d537bEE4eA18F639, // AMDon
            0x6a708EAD771238919D85930b5a0f10454E1C331a, // SPYon
            0x1CdE419faE0Ef7f7931aE3E29e5f411C8C5E5Fa1, // Von
            0x158734153f354CB326EE690C3d55f810DCb0fc90, // VTIon
            0x4D209D275e3492aC08497A7A42915899c4dD5E86, // XOMon
            0xd1F799cB9f5d0a02951b0755BeCeD6C43882712F, // JNJon
            0x25FfDA07F585c39848dB6573E533D7585679C52d, // MAon
            0xb034f6Cb52b7f2Fd5a7EeeffCa6b9aDCD6b9A6F6, // ASMLon
            0x8677aBAD7B458bF16a0fB2676DFC7d3f55Ac202A, // ABBVon
            0x34375f826fD3dD4E15F883d4F4786bB45eb705ac, // COSTon
            0x0cdE6936d305d5B34667fC46425E852efd73559a, // QQQon
            0x405F38B90beBF1259062CF29Da299f3398662bcb, // KOon
            0xD3113A0AD20a46F6a662C63fe8E637f7713E59c7, // CVXon
            0x400F1e257f86D25578A0928C94dC95115F09d5c9, // PGon
            0x9351AbD19f42101dD36025E495B98E910b255d78, // PLTRon
            0x34304f2f7cC487eb4186e6D69F5905A613474aA2, // CSCOon
            0x03E4bd1Ea53f1da84513da0319D1f03dD1BBCf93, // ORCLon
            0x5151A22421Ed4277F1e4ca4785a07b035D548a36, // GEon
            0xd615468088B19FB9d4F03CB3CE9E33876fF3Db99, // BACon
            0x31DAbf49E4BC1Af1456c1819cb6A2562154e92F3, // HDon
            0x869027261075c3C239D6A26842579b93802606f4, // MRKon
            0xA528CaaA2f96090e379d43F90834C75dF54D6E74, // INTCon
            0x3385Cb29cCA0aC66f5d2354d13ef977b49A2510f, // UNHon
            0x0eAa1a75bd682A5669AB2371A559fBD039C6b9Eb, // PANWon
            0x5ecC352C4640f1d26BD231dbBd171f40f7d0Eec6, // AMATon
            0x35895a1fa1AFf7FB3204fB01257409Fd75acB24C, // LRCXon
            0xCa3a5c955F1F01f20aAcF9501B03E4aa235e478B, // TXNon
            0x44fde2C6Bc2C2b54962C69fcEF57A2A50121DBD7, // RTXon
            0xbCf7D958791152128710565a5fC6f68342Ed71C8, // TMOon
            0xe6837794FBC6DD024733A1A31F86061296FA2752, // CRWDon
            0x274B0cB6DB9473245A31cDEA9B789786f4108e4B, // CATon
            0x0D4f9b25F81163Fb4840BA4F434672543823000C, // GSon
            0x538e2838f9ebC9B891399DF4a8dcc42890D9dc20, // ANETon
            0x7048F5227b032326cC8DBC53cF3FdDD947a2c757, // NFLXon
            0x629520dEE1620dEf11596F84E85de9F1Ff653012, // WFCon
            0x111f6F2B9F1C5f3Ec841690e1deEc606086727dA, // SAPon
            0xFBdF0366F800CC79d6663DA26bc0BF21FB455Aa6, // AMGNon
            0xE1743616f705954620aa351465c8885fBDE5A8A9, // LINon
            0xE8ff70859Ce4cbd72E4352b4fb45F5BF39d07464, // IBMon
            0xd5964f3fcee8D649995AB88F04b8982539c282D2, // BABAon
            0xD803f8777187D6DEe1eA57854aEB957043fb1675, // AXPon
            0xeEe9eeE593cB8f7946260B4066CBa7907f40ACFa, // DISon
            0x2Aea1D415D45CCF3EaBE565d45DcaF4ea2035b9c, // GEVon
            0xf26518958935654878De15BE7bC79A26971583Ba, // DELLon
            0x527C6436E1eAa4f2065CDE4090F798Cb5D031dD6, // ARMon
            0x8dDB97556F6ae98B4d408c56B167139fE1Cbe3e8, // Con
            0x70AfC3a600f843d2018dF16B0b316E4BC9c603E9, // APHon
            0x995ADd4bA29a628A57930a8a185c62cA044eC090, // MCDon
            0xFc263946439b0d802bF4C5a6fCd34E2885259f91, // KLACon
            0xf99F8f3a95257d82006183bd524efa7aaCc9Ef7A, // PEPon
            0xc2dD31B1B3a2f515cE0D48De712c6744C3475170, // VTVon
            0xA3B089C886E6d721f49DEF8E050F3b9D4362560B, // VZon
            0x0E246E05212DbBD78A354C072a92B4e5723B2fa0, // ADIon
            0x918008C3d29496C37b478b611967BeaCA365aF36, // IEFAon
            0x5a20886b575058dd7299785f0Ea9b1172942a3E0, // ABTon
            0x24F5471183eA549987f245D6ce236B6108869C92, // BLKon
            0xfBD4D681C92ead6Af0E49950c8B2e47EeAcbB2dB, // QCOMon
            0x43d0B380c33cD004a6A69aBD61843881a2de4113, // SHOPon
            0xe9d43f7E6b2237e8873a7003b3F43c6B03160bE5, // NEEon
            0xfe9aA194E3C4604f3872f220eb41C33A287FCD90, // UNPon
            0x08a513779f46FFb7A34F16094a94016d010128a8, // NVOon
            0x2588F20BAd92Da8dCCE7FaC8311B5F8Ab4690E43, // TMUSon
            0x90cCbB75d61Cb65cd73a3ABb5Df04a75961612b7, // DEon
            0xe5BA472C98b7E4695bD856290De66bDEDaffC123, // SCHWon
            0x0D586b51A90Dc999f9bB6A0506Da7F034a1D3A2E, // COPon
            0x8A83C31D6751833B4940b6e871c48d9A15a07b46, // PFEon
            0xD04a2BB053277721a8321d7441eEd5b42FDF7250, // CRMon
            0x4255279aF47cf10eFB9A5C8839F90170F4EF759f, // Ton
            0x784584933C2192Caa062E90d8140D94768CE62d8, // ISRGon
            0x08cE97F3D5Cf11E577D091ab048bC5e2EaE3FABB, // AGGon
            0x22092c94a91d019Ad15536725598B0A6BE0a73C0, // IEMGon
            0xDE9D6036FCA870f7efc5A82722Ae694c371Ac909, // UBERon
            0x8c9979Dc208f74a5602c38691aa920F121e2f863, // VRTXon
            0xd09F7B75b9659b864C6F82bb00Ff096f9D277998, // LMTon
            0x1501EC83FFEf405B4331CC4f73277a40fb0C627d, // MRVLon
            0x4697b2A050f7B5A8e1ebc27c325f9D78D094f041, // ETNon
            0x7aF44d51d1fb88c5b74Fc71d3cba649Bb8099D14, // ACNon
            0x55B370B704240a914f42B5bBB3195431C031f9f8, // SPGIon
            0xEDB3124e96c64C177Eb709CbC64F9977dB40Ea74, // APPon
            0xf21132A811Ad1A878E21Af60F64d4e690C9DaA42, // BAon
            0x966EbCBA3c51E81f5CF159a1EaBeFd2327aB5E8D, // STXon
            0xF15B8f7465b92799F6EE440F86B3CAB5A4dbc65A, // SCCOon
            0xF3e82EA164CB344B2b11Bad4c24b0Ea4F7BA4714, // PDDon
            0xfA9a1E901085e269f6D428F79Cd5252d8b919344, // GLDon
            0x2ec46EeD30c94caa5979e6A0395Abe824138335f, // LOWon
            0x50356167a4DbC38BeA6779C045e24E25fAcEdfdc, // SPOTon
            0x94d7754541B829A87321d56121Bc544167Ac490D, // SBUXon
            0x167E93A849A0cc479769132552B99aa1cFA0948c, // IJHon
            0xc008c5F579ec1450F20099c39F587547e27c7523, // SGOVon
            0xcEb29848d04Ad3Cb46E1fE8E45B82ffAc39D797d, // WDCon
            0x4Fd67CB8CFEdc718BAc984b5936abE3330d0a2A4, // SNDKon
            0x40755F06aB7F8dE1ab3a9413b1ef562d63DE19B1, // IWFon
            0xfEb0793EEa97585Eb3a541F3FD53450D225b2B87, // NETon
            0x53a8c5fc5643b437779742f494691e6b7C660a8b, // COFon
            0xD7a6353a23ED2c4fcaC29A63CBBe3f65ffEf41F5, // SOon
            0x2b1d5cDeCC356530a746C5754231EfaEAca64022, // PBRon
            0x5E63232993789601CE362e0240a299C1DfCBfbEc, // NEMon
            0xEf80743f78d98FC2B47a2253B293152ce8B879ba, // ABNBon
            0x5397cB3f1E419050D9d7160756dE0f4eD4f5f898, // ENBon
            0xE4E12c9CEc3e8cAE405202A97f66AFA695075fa0, // EQIXon
            0x138ED6833ff4E8811E1FEa0D005E13726c8886F9, // SNOWon
            0x30BD85fD4286c5c9857679F5B188f737B4a7B8C0, // REGNon
            0xeb19c13c54B1cD48AFc62F6503375e92D5f1e856, // NOWon
            0x25a4DbAE9a0Cd8C75656D6b50FFDf4900CC20d8f, // GLWon
            0xCE0466Bae0e867239719dC386CA84b1F3eFE6914, // WMon
            0x5d1a9d8aa362a6424b65Fcb601e52FefcE5b4EFA, // GDon
            0xcf9CAf83053213c44dd7027Db3e1E4aC98E55f8f, // ITOTon
            0x65D84F0990B7394209d591380C2952c83D778aA3, // CEGon
            0x2418c2e1aE3B8D767594b3974D32610743f88155, // PWRon
            0x0Afa28A7Ac4E44b1F771515c200F4d67B1f5e8d0, // TTon
            0x60B273bDf00a9A52238Ca706257f61efc55bDeE0, // EMRon
            0xcB22Db0EcB6fe58B7B47db443dCFdfDFbF729CEf, // ADBEon
            0x6E3e077A6C0E3c27fD6D00B97387D9b7Bd451BAB, // INTUon
            0x7B7AbD762a400c9768CDeeEF3C01DaE39e0B8427, // WMBon
            0xc145DC2eBDbe8EAD1fEcDeBF46c76Eb1Fdd0104D, // CVNAon
            0x01486675Da0764ee780Ea7cB65C33062E9B2D28c, // MRNAon
            0x4D3442D884202584F1729bCA20Db05472B886B52, // NOCon
            0x9Cea8A7Be1Ab0320b709d368Ad60d8500f55995f, // VRTon
            0x38B9A53bfDc5dba58a29bD6992341927C2fca637, // EFAon
            0x500EAFc69b68Acd6F27064f9B75F1C7d91CC4d9F, // IWMon
            0xE3b17E6D290A0F28bd32aF4064637057627004D5, // FCXon
            0xfaDdE620010736a5074a4269894Cb52B0a9a91DE, // SLBon
            0x7567c2a46BCE46373b454682F3d95e6535BDe144, // DASHon
            0x5630B5741A33371D9d935283849A16dC808f7F3A, // APOon
            0x60a8f8e05200fF73aFde9E2caE819bF1605f0BdD, // MELIon
            0x282973969118F9fe39bf2FF3D8DD1EFEE82CCb11, // NTESon
            0x19601179A60f55Ff6636F5D1A8b6671053Bd60a8, // HOODon
            0x492E678c1ea048C70eDc635047cdBB87FF5362a2, // HPEon
            0x5C50fFD365c852f5e72BFBc2c1aE621e2ACa5Ece, // TELon
            0x2155f5344BA7763f80420dE617Af41E56De0552b, // NUEon
            0xcB2a0F46f67dC4c58a316F1c008EDef5c2311795, // IAUon
            0x7a5bD36047A9D15C90FA79b0654De8dd9d6eBbB1, // AMEon
            0x01b5a4aC600bE98448DbEFBB78BcDF38262552cc, // OXYon
            0x17D03aE104a9D12E9E5794Efb109B817Dd7f3404, // BEon
            0x04b5E199F2eC84f78B111035F57b16BeE448dB6F, // NKEon
            0x0fAcaFB97ffDbA3cAe88512070AF49bd30674cD9, // LITEon
            0x3de956D959726C448649354C6fBCa92B82dC5Ed7, // KEYSon
            0x68B07cEf227Cea1b2b6683921C8c825cd5C69Ec7, // IBITon
            0x03f09E2EF6e64D804a5579E21E7b519db174cf54, // BILon
            0x374D03A6c0d5bd4bE0A5117eBE1B49D52aC8a53F, // PYPLon
            0xf69e40069aC227C11459E3f4e8a446b3401616b6, // TLTon
            0xe778A2e5D953c82EB9475cf3B87654226a867344, // XYZon
            0xAed5985afC12aA09d87F55B4b1e6bC3B8f7B0208, // CMGon
            0xb1ABA049C42B6fe811766EBA61F51f11C57acC4b, // Fon
            0x0585756aAFB241b0f8A9Df62Db26c566091Bde0b, // COHRon
            0xE9518CB0010C717DB69001F1418EFF9e97330137, // NOKon
            0x452248f839755c7b777bbC0f6Aa49D7F05EB8020, // NTRAon
            0xA486a0A05250E8621bA3B26C3bbc517145eba619, // IEFon
            0xf2C24c47805f4f72d3919C8674bFDd401505794B, // VSTon
            0x95F7423c51Eab71cBD00ca855B0B2B2153F14184, // ROKon
            0x2A3cbF64C8181DB4a25D41D4d7a7Db9984C59DAC, // SOXXon
            0x96A1b43C8146E6D1f6e66B226A3c520CbE3d8a50, // DYNFon
            0x8B46599e0E80a34F37e97DF58E741ca904cdfaBd, // STMon
            0xf095607F8aB6F8f813a1F93F70047ec2f0A8bd85, // TTWOon
            0x89a9F7114bE6b220fAe645ba0cbB720889867415, // CIENon
            0x573e11CC667A8E5BE0c7Af2410403371088D3d0D, // ALABon
            0x7313EA16493b2f55054Df0131A3A14B043ec8992, // MSTRon
            0x10b58A3d9DCeC59bB1c3bf6b9c9414eAfCE711C9, // VNQon
            0x6F040fC3061374304BddbfdAe9d688d7C868c785, // TERon
            0xb4D695569236273745B4CD54B539b1b9Cc1513af, // RKLBon
            0x318ddd4d03d84A40cf44772385A0CFB3D4394049, // UMCon
            0xE92bE960aE64F6a914Ca77014CaC9E56DE7f36C1, // JDon
            0x84719A1082ed487c7eeac7d69885E3CC2009Ea78, // JAAAon
            0x7b695132b165cb6703F0212bBB1e91A782526156, // CLSon
            0x90EAa91Af0B4559F1F270258Bb5cDDFafbb62da9, // STLDon
            0x9A1C88ac479906A7f03e76605b15B72DF10d8E51, // EQTon
            0xee268780473E7a0e47baC41547C6E01512555A16, // NBISon
            0xaC0919D699eE1725d30d5ceD86cfd553C33DC36A, // INSMon
            0x47B36DDB9dd12A8411f78226f55e8c3f0D65481f, // PCGon
            0xf8589b526FdD65F7F301c605a6e04F0F1b4B3620, // COINon
            0xe42CfB20e00912409B77A602B5BDcfF3c7aCC5F4, // TQQQon
            0x40375E3Dd70232eaF264706e5662b90A079e3D31, // EFVon
            0x102138be022f8D142bcB817F7264921d65209608, // FLEXon
            0xf95e50BE5Efc96117c28775F80C7Cdb41Ebc4888, // SHYon
            0x37fF203Ac221313B620d047eddD7bD6F68d656a6, // VRSNon
            0xa75F08b9a91439DAac9cc7072857cC0a98Cf527A, // CCJon
            0x76E39171Cb665a35981e744e2CEB7012F76caEAc, // CRWVon
            0x6459303F58244Ff1E7A42b90aA3782Dfb6Ca6969, // TCOMon
            0x00c81d35edDF44c75d4Db9E07bDCdC236eB0ebcf, // EEMon
            0xB35a9EAB5D25282f4e668798B629a9294e9A47aa, // ONon
            0x7A18bB5FD6Ba6343180AfDCf6Dc406eF17F7fC04, // HALon
            0x19904Bc04c09e5d29Ed216dDD105bdf103A0bA2D, // CPNGon
            0x8D941EbB4921f8d43CFA65233B14A547f96559fc, // JBLon
            0x467e59ce5D5fe01686D4A80dd1E1DAE13549AA6c, // BIDUon
            0xf157481bEBd0C0686780fd0F61806C900A6137e8, // CRDOon
            0x441a4D4Fc23f17F4cf23E3d60F12d2BD6F176728, // CBRSon
            0x8b872732b07be325a8803CDB480D9d20B6f8d11B, // SLVon
            0x1C42C07257F936a7c4f84B8D756c95817E23631A, // HUBBon
            0xbEeEF4361F6603eDAceF5205b343C6bb6473A099, // IYWon
            0x82715299f3f132FB85f3De1F7e8fAfd3d79f3eB5, // EWJon
            0xAff6b836d3eBd29aEb0C8b840Add04EF79d79678, // GFSon
            0xfB4a89A077B9020C7101b1Af760BEB708F37a416, // ENTGon
            0xf4fd75764A5C086fb12F822be2cA318b3a362DC3, // USFRon
            0x12B7aDC48416A103F63E7e6210f62C81dfB91fD0, // EWYon
            0x7Bd821eAad82cb92C1eA64DaC1f3bB2E787E959A, // SWKSon
            0x71507068e98049cBA81E9bbc8d901E4A2f4222Eb, // SOFIon
            0x0DAE81A905b645a3D1E67129b89CD0Acda224E9A, // HYGon
            0x484Ce83BB55b50D70236C7D1E29E0Ba7524f905B, // NVTon
            0x4DA12f47578ef89c76179b760C778E70b668f80b, // RDDTon
            0x1dCd320C5d7b84CD407437c58d56CbbDd0D9d8f3, // MTSIon
            0x277E1FA8704c5511FEd7E30Bc691F922aa30101B, // RIVNon
            0x80F03ABCb2BD85237740dD69f87d2F5De3909012, // LSCCon
            0xC142ba8ccD36d80C3a001342fb83E4C3d218A873, // SMCIon
            0xbbE4Dfe7a349Fb72aEc6f52d5CD9bDD78AE8f313, // TLNon
            0x82436bAE31AE373258bA567f32087eeFc32189F2, // WCCon
            0x343324170C91c4D8Cf4D439B3E5a619F50621aE7, // TSEMon
            0x43807bf4ce06F4fbb4FA8DEac37BF274AEa324Da, // LECOon
            0xd41699aA1BfC1c5f172c27f387372bd30717a5db, // MKSIon
            0x2Ac26EC236df5D1d2Ad1A6Dd4E448A90E45DC35D, // TIPon
            0x992879Cd8ce0c312d98648875B5A8D6D042cbF34, // CRCLon
            0xf49046aAE76EAeb7ffd3EF116ce0f7CD0F52d93e, // MTZon
            0xF54b94eA21e1Da5d51eF00fd4502225e5394F874, // IWNon
            0xdABb9afF4cf02f26D2014e4cA9f94aC6fe6572a3, // GMEon
            0xb943c8a0d77b656Daf5244Da060D647Fd9152289, // SOXLon
            0x6f28Cb07790c1049ecd7482d09Fd13B977B47201, // PAVEon
            0x5acf40056ED51C8bBCD1b125Ef803581Ac89A627, // FUTUon
            0xA046C2F0A1Ac0a0E8829eFc12163ae892CEAfAc2, // IGVon
            0xab2F74804C022C5249d52e743AF4340E42F5f3b6, // GRABon
            0x237c9F794EDAaA0071cDF64a41c25EB76771754b, // GNRCon
            0xA1DaaB37dA2a29A1eC721922b55962eB8B481001, // FNon
            0x88B90f45bd6a4F97f7D85d280eD64A40880e4935, // ITAon
            0x4Dc8dCeE22a56fEECa930dfF45581aa9A14D5E05, // HIIon
            0x40d8E1fbaf69173c47fa493FeB50a84eeC6b57eE, // IONQon
            0x9810beac9af3C30d14cFB61cDd557E160f60FD50, // LIon
            0x0B790ABd6594918DE1022233b7cc79baDB84d92a, // ALBon
            0x2F79d36184DfE7968C9d23f87cAe1aB72447c1e5, // ONTOon
            0xCfD1F0DF84300EA1a4e2BA5238043A2fA5A7237c, // PINSon
            0x8a5f83A4b3AD2B9604F53c4dDf8DcE1329f9d433, // NVMIon
            0x52AD57A7eA642E99A892AFc79E937B383f1b59e9, // BMNRon
            0xF325884D9bcac457271fE7F7B6be1765348fCCa2, // SNAPon
            0x93fac02b22B6743423381D163aec418178019B7a, // FIGon
            0x333932F15E6E14f4a630163D3224548a721DdfA4, // AIQon
            0xb84e150A1d18380cFeEeBCdE8756368dD489A1A3, // AMKRon
            0x02D608506cA0048D0D991a11F1E7Fb8CAD1e44f8, // AALon
            0x49ccB157c77AFE5F264C35f0e9178a98D77815Ab, // RMBSon
            0xB0752Aa50B089EE6eA9aCD51373207Fa460E87bb, // OSCRon
            0x820f09C2EBe7852E14a1310008BF7aF4d29d4F09, // TWSTon
            0x9876F4b879cDe9Aa49Ffd260034A0698B7B33A49, // EWZon
            0x45Abf29515bc23F8c0Ed2a06584444cE473A75FB, // ASTSon
            0x66a1409FE303d00209202933e3d31eE43AaAB39d, // AURon
            0xF400b05AD5A791c65Acc3f905E5aDe5F1B653c8c, // TTMIon
            0x3A82f1C847cc55e52e597fD81c63a812C6722541, // HUTon
            0xa59469D91563CaeedDd2ffC731f41215E7b691ef, // VICRon
            0xdB0748297fbEf0B33dF89e86519A0BD3adAf6459, // INDAon
            0xaC38a6608868e2f487d7993EA7339C69e5AB077b, // CLFon
            0xC6f9eDbeE6042a237D72493bBdA3eE2c3c62F708, // NIOon
            0xC4a88a72B848255Fd24Da3C1aD6755D980535FB1, // RIOTon
            0x4BAf4dC56Cf6a525a0874e25cc6372A6A8915135, // MPon
            0xD678F3F86436Ee298d28A3C414c367aDFeD65337, // FORMon
            0x8FD70eE385f470c8D6FDA2D93a4E49C849BAC6a6, // IRENon
            0xaD56701D9e57957e28e546Db7db508A16d4f86CC, // WULFon
            0xd8dAFFd168651470cd5397A5D670DD5F8E4b02f5, // FPSon
            0x620477782cEa4C4171165396F8014EdEF83a13da, // FIGRon
            0xD381aec27DAAcCC87F102FF4Ad6652F8b5F20bA0, // POWLon
            0xe5ca1585c6053EE891027fD0A2548cB3B27D7f01, // SHLDon
            0xa2a97e3d6140e8ccD058f3b84230F3E1a349b1a3, // AGon
            0x3f41bCF043a07Ca9DC734f24b0a77C01CBfA0E8D, // CAIon
            0x04B16ff1F9673146F68AA5d5F57aA45AdcF068E1, // ETHAon
            0xEC93fE7Ff4B09CA3CCAFBc4CC9615E62BE412780, // COPXon
            0x25eD86472cf3012607DC6576c58e6432968255C2, // CORZon
            0x91fc7371d6dE682A1e8CFcB4EB7dA693312A03a4, // BILIon
            0x5Cb7671740877723c9aD55348a751D7B57052E07, // MXLon
            0x18De24acb876C0B8392d9C55583Bb21c0355980b, // APLDon
            0xf9015E0b3AB4ddd216F522D6150dB826c9BE83f8, // PLon
            0x7437203800140BA7d9081ddE8cEF09EE40E3Bf03, // KWEBon
            0xaF6C03acf72355Ce98d0741302B78870b376428C, // OKLOon
            0xc7806943663158D68740a14ab0B270bD60BDe87D, // URAon
            0x821aEf7d0F4347bB9EA6f293a98b19d823EEF0C5, // VSHon
            0x4693f6F5EF257381a28afd0673e64d8b32d5C6aD, // HIMSon
            0x149Bda9e7251DC36f536d1fE7F92A5ea203F4F3D, // AAOIon
            0x9b8E987e6fEc8Cf1380C4dcA7071e2C7853AEEA1, // FXIon
            0xD60b0276640a693ece55660afAC0383ca6433882, // PRIMon
            0xDad07D0Ca26ed4109Bc00893dBee3Ed4cE8ce2a4, // CIFRon
            0x30938154E2697694F41592C2e48459287dEBe4BF, // ENPHon
            0xFBE22D27B6e153244882fD7bdfE7C6109918281B, // BLSHon
            0x8C7Bf0ED6bc778bde1489De1592C1aAd3E66371d, // QBTSon
            0xE7ddF606841ee278A30E5C90486681e68ddd8cbF, // UECon
            0xEd2a500eB2b66679e0BbD76e51a60049aE5f3271, // RGTIon
            0xb42f5597EAdd424de67b46Fe5d1EC4b61367A4e5, // BOTZon
            0x2144d620E3471441b12Bf256E01a09EAA5ea7F12, // PENGon
            0xd85d4Ce29b4cA361FF72Ef0E53D6236e334C5DB6, // ONDSon
            0x1d7B5e06fdbe4FD33f5C64C081E32B5d539751D0, // AMCon
            0x2206E07410A8fE9Ef595e7184B2E9d160fdb7211, // USARon
            0x15688f10470dFdDCb4E2d60CD2ACfd3eC418317a, // SOXQon
            0x20CCe48D767eD68CBbA7727c4c504eFE5Bcb626c, // GRNDon
            0x91C62325F901EE29Da8E521CfE68980332A4Ca06, // ACHRon
            0xd226d8170EE38793430C7Dec6903df4B818BB74C, // MARAon
            0xF98B89825233808CD37706A53D2b4Ae3e359d442, // GLXYon
            0x0C50323AF81D5C33822c6Add256Fb9093D42BC74, // AXTIon
            0x30033A17ea24E90631532582a1917c64AFBF87Af, // OUSTon
            0xB56B7C2F9988448790B0F78697F405aB5e8597E6, // NVTSon
            0x94174e3D1335db402dD03A092f7aA7ac2cb32be4, // USOon
            0x17515B68378d86C38F394c666e79907dA05dcBA9, // SQQQon
            0xCB6D74afF24AFc94514727eE0FCDA6bb6B64f3F9, // RXRXon
            0x335DD4112704f108b5Ddd8F8a44Bd9ed68522a80, // SOXSon
            0xA3b7B7cfEb023a6C4f444f5ca9a3Fc85809Ece15, // LUNRon
            0x31D6011023D6c7695Efc29bB016830F3F36De40a, // OIHon
            0x23e39D94807a8bb7e3f8294b4911D04EE26DcE39, // RDWon
            0x89CC700F308a4C59889fBF3286216554C53B0601, // PURRon
            0x70bd780076E25D087Ed9c35f4e4A540522Abe8cF, // DNNon
            0xBb8c10f7E828E3279df8CC3397A5212F845C509b, // AIon
            0xdCE0957E22F7baf2AA1a50d854e03cEe6f215004, // AEHRon
            0x79ed7f4d9668E8e7AaadD12A711d19064840B9A5, // WENon
            0x3EC23F52F6573FC0587A0631dd8C3b107f6bcb35, // PPLTon
            0xf4b674D4E33c36F8db4b928A5eEC4E1F87b386e3, // SMRon
            0xCa626a74420aAaf285987Da23d829f9159Ab867c, // URNMon
            0xD2C06fef2ca2375a9C7ceB4AbcA9DBc2aB6aF981, // UUUUon
            0xeDCF71B2e2217064038AdCb54A3C3a5fC3488eF1, // SOUNon
            0x4752AE8f910b25e64E4406eAad50c1B4E8DE7E6D, // PLUGon
            0x9e609E96B688927aa49Dcd9758E2081f0c48ccAB, // IGEBon
            0x8755c5C39b1AA9053a83AC731242a2cf4D04B0Fe, // SEDGon
            0x55b56CC2cdcbC2C58668F72663bE7599a46Ed79F, // WOLFon
            0xa09699fc0cbb1F85128450A0ff6a3c4d3A7E7B9B, // OPENon
            0x82E07C1017032cFd889b1Ca81EBe722c4D4de825, // QUBTon
            0x5e3cA19c533C8C0381eac5319624596557C279ED, // KEELon
            0x517A25e696421C88218B43cbb7EA0f873B6973A6, // INODon
            0x99e01F02d66455Bb106D91D469c9EAF6aB4904f6, // SBETon
            0x3A562836AFB1026F5D7A6B6dA1125D27fdfeE372, // BTDRon
            0x7BA995f1662A01f3bE0DC299ce94Bb7e9C7075f5, // BBAIon
            0x5f2d37192576a6804F44722eB828E280D5FB43Dc, // BNOon
            0x3802dc739eF9E226f36421A9c15eFa519153bBBe, // PSQon
            0x0888EDfeC4C0A66FCE074796CF4F6509c00f6c49, // CPERon
            0x47Bfe4921Bd74C66c6B0C35C517aBdFB5E3BAFb3, // FCELon
            0xF1a96d4B591E446445600789D60C73Dd636B357c, // FLNCon
            0x3c276Dd9f9Eab5510f9eAfD3a6Ea54879b27CA3D, // NNEon
            0xC43Ae29aFE58bf90dA6Fe3Edd570C2E735fb2850, // BOTon
            0x3fCD741646A9790635b938Cdb69af5Df356CbaAB, // PALLon
            0x5fA699c0c1319b8D86489AF77dFDe4Fa97B47DF8, // BTGOon
            0x6AD19E0A57Cfea0bC521A12C6c82372852842933, // LPTHon
            0x92d504158A8Dc69de989dB5EDe3230D958fb8630, // EXODon
            0x472F46C5D7409C82234701EFf7D4DDA4c28B5a93, // BWETon
            0x2659Dd96deF34ceD3679901E5500779BE297fE5a, // BAIon
            0x087b5761b161429013d41eA54cd2fb6022A21564, // DRAMon
            0x732823512Ba98D1BCDE471ca023ee2A0C9f117b7, // SATAon
            0x71E9dc9DEbc18650BD2342B93623B88C2aD00c89, // STRCon
            0x343ccbc9f8409f862008b7abebFFf20ECf935C75 // ANTon
        ];
        assertEq(list.length, tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(list[i], tokens[i]);
        }
        // The mint currencies and Uniswap's contracts, by hand too: the fork suite that reads them on chain runs
        // only with BNB_RPC_URL, and a stablecoin address changed to another contract with code would deploy
        // `MintRequests` on the wrong currency.
        assertEq(BnbChainAddresses.USDT, 0x55d398326f99059fF775485246999027B3197955);
        assertEq(BnbChainAddresses.USDC, 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d);
        assertEq(BnbChainAddresses.UNIVERSAL_ROUTER, 0x1906c1d672b88cD1B9aC7593301cA990F94Eae07);
        assertEq(BnbChainAddresses.POOL_MANAGER, 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF);
        assertEq(BnbChainAddresses.UNISWAP_V3_FACTORY, 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7);
    }

    /// @dev BNB Chain's mint currencies are never components, whatever a list names and whatever the deployment's own
    ///      are (the whitelist policy, A7-22): each is a token with code and 18 decimals, which only the policy's own
    ///      rule on mint currencies refuses.
    function test_A722_theBnbMintCurrenciesAreNeverComponents() public {
        address[2] memory stables = [BnbChainAddresses.USDT, BnbChainAddresses.USDC];
        for (uint256 i = 0; i < stables.length; ++i) {
            vm.etch(stables[i], hex"00");
            vm.mockCall(stables[i], abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
            address[] memory list = new address[](1);
            list[0] = stables[i];
            (bytes[] memory calls,) = configure.safeCalldata(factory, list, list, _none(), _currencies());
            assertEq(calls.length, 0, "a mint currency is skipped");
        }
        // The same token under any other address is proposed: the rule, not the token, refused it.
        address twin = makeAddr("twin");
        vm.etch(twin, hex"00");
        vm.mockCall(twin, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        address[] memory one = new address[](1);
        one[0] = twin;
        (bytes[] memory proposed,) = configure.safeCalldata(factory, one, one, _none(), _currencies());
        assertEq(proposed.length, 1);
    }

    function test_entriesParse() public view {
        address[] memory list =
            configure.resolveList(string.concat(vm.toString(address(a)), " , ", vm.toString(address(b))));
        assertEq(list, _list());
    }

    /// @dev A token named twice is refused before anything runs (RT-24).
    function test_RT24_aListNamingATokenTwiceIsRefused() public {
        address[] memory list = _list();
        list[1] = address(a);
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.DuplicateEntry.selector, address(a)));
        configure.safeCalldata(factory, list, _list(), _none(), _currencies());
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.DuplicateEntry.selector, address(a)));
        configure.propose(factory, list, _list(), _none(), _currencies());

        string memory raw = string.concat(vm.toString(address(a)), ",", vm.toString(address(a)));
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.DuplicateEntry.selector, address(a)));
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
        configure.propose(factory, _list(), _none(), _none(), _currencies());
        assertEq(factory.listingEta(address(a)), 0, "not named, not proposed");

        address[] memory onlyA = new address[](1);
        onlyA[0] = address(a);
        configure.propose(factory, _list(), onlyA, _none(), _currencies());
        assertGt(factory.listingEta(address(a)), 0);
        assertEq(factory.listingEta(address(b)), 0);
    }

    /// @dev RT-06: a listing the guardian cancelled is not proposed again by a routine run, and a delisted token comes
    ///      back only when named in V5_RELIST.
    function test_RT06_XA11_aVetoedOrDelistedTokenStaysOutUnlessNamed() public {
        configure.propose(factory, _list(), _list(), _none(), _currencies());
        vm.prank(guardian);
        factory.cancelListing(address(a));
        configure.propose(factory, _list(), _none(), _none(), _currencies());
        assertEq(factory.listingEta(address(a)), 0, "a routine run does not repropose the vetoed listing");

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, _list());
        assertTrue(factory.isWhitelisted(address(b)));
        vm.prank(guardian);
        factory.delist(address(b));
        configure.propose(factory, _list(), _list(), _none(), _currencies());
        assertEq(factory.listingEta(address(b)), 0, "delisted, and only V5_LIST named it");
        configure.propose(factory, _list(), _none(), _list(), _currencies());
        assertGt(factory.listingEta(address(b)), 0, "named in V5_RELIST");
    }

    /// @dev An expired first listing is the owner's own proposal run out, not a veto: a routine run proposes it again,
    ///      while a cancelled one still waits to be named (RX-39).
    function test_RX39_anExpiredFirstListingIsProposedAgainButACancelledOneIsNot() public {
        configure.propose(factory, _list(), _list(), _none(), _currencies());
        vm.prank(guardian);
        factory.cancelListing(address(a));
        vm.warp(block.timestamp + factory.LISTING_DELAY() + factory.PROPOSAL_WINDOW() + 1);
        assertFalse(factory.listingPending(address(b)), "b's proposal expired unexecuted");

        configure.propose(factory, _list(), _none(), _none(), _currencies());
        assertTrue(factory.listingPending(address(b)), "proposed again without V5_LIST");
        assertEq(factory.listingEta(address(a)), 0, "the cancelled one is not");
    }

    function test_XA40_proposeSkipsWhatThePolicyOrTheFactoryWouldRefuse() public {
        configure.propose(factory, _list(), _list(), _none(), _currencies());
        uint256 eta = factory.listingEta(address(a));
        // Already pending: skipped, and the proposal stands as it was.
        vm.warp(block.timestamp + 1);
        configure.propose(factory, _list(), _list(), _none(), _currencies());
        assertEq(factory.listingEta(address(a)), eta);
        // Listed: skipped.
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, _list());
        configure.propose(factory, _list(), _list(), _list(), _currencies());
        assertEq(factory.listingEta(address(a)), 0);

        // The policy: a mint currency, a token with no code, no decimals, and decimals outside 6 to 18.
        address[] memory odd = new address[](6);
        odd[0] = MainnetAddresses.USDC;
        odd[1] = MainnetAddresses.USDT;
        odd[2] = makeAddr("no code");
        odd[3] = address(new NoDecimals());
        odd[4] = address(new MockERC20("Five", "FIVE", 5));
        odd[5] = address(new MockERC20("Wide", "WIDE", 19));
        (bytes[] memory calls,) = configure.safeCalldata(factory, odd, odd, _none(), _currencies());
        assertEq(calls.length, 0, "the policy skips every one");
    }

    function test_XA18_LR07_proposeNeedsAnOwnerThatSigns() public {
        WeightedIndexFactory owned =
            new WeightedIndexFactory(address(configure), guardian, address(0), address(new WeightedMath()));
        address[] memory list = _list();
        address[] memory none = _none();
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.OwnerIsContract.selector, address(configure)));
        configure.propose(owned, list, list, none, _currencies());

        // A key delegated under EIP-7702 has code but still signs.
        vm.etch(DEFAULT_SENDER, abi.encodePacked(hex"ef0100", address(0x1234)));
        configure.propose(factory, list, list, none, _currencies());
        assertGt(factory.listingEta(address(a)), 0);
    }

    function test_safeModeLabelsEveryProposal() public view {
        (bytes[] memory calls, string[] memory labels) =
            configure.safeCalldata(factory, _list(), _list(), _none(), _currencies());
        assertEq(calls.length, 2);
        assertEq(calls[0], abi.encodeCall(factory.proposeListing, (address(a))));
        assertEq(labels[1], string.concat("proposeListing B ", vm.toString(address(b))));
    }

    // ---------------------------------------------------------------------
    // Execution and status
    // ---------------------------------------------------------------------

    function test_XA06_executeRunsOnlyWhatIsDue() public {
        configure.execute(factory, _list()); // nothing pending
        configure.propose(factory, _list(), _list(), _none(), _currencies());
        configure.execute(factory, _list()); // not ready
        assertFalse(factory.isWhitelisted(address(a)));

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        address[] memory onlyB = new address[](1);
        onlyB[0] = address(b);
        configure.execute(factory, onlyB);
        assertFalse(factory.isWhitelisted(address(a)), "not in the list this run was given");
        assertTrue(factory.isWhitelisted(address(b)));

        vm.warp(block.timestamp + factory.PROPOSAL_WINDOW() + 1);
        configure.execute(factory, _list());
        assertFalse(factory.isWhitelisted(address(a)), "expired");
    }

    /// @dev FR-05: executing needs no role. Any account runs what is due, and a listing the guardian cancelled stays
    ///      cancelled.
    function test_FR05_executeWorksFromAnyAccountAndNeverReproposesACancelledListing() public {
        address someoneElse = makeAddr("someone else"); // the broadcaster is neither owner nor guardian
        WeightedIndexFactory other =
            new WeightedIndexFactory(someoneElse, guardian, address(0), address(new WeightedMath()));
        address[] memory list = _list();
        vm.startPrank(someoneElse);
        other.proposeListing(list[0]);
        other.proposeListing(list[1]);
        vm.stopPrank();
        vm.prank(guardian);
        other.cancelListing(list[1]);

        vm.warp(block.timestamp + other.LISTING_DELAY());
        configure.execute(other, list);
        assertTrue(other.isWhitelisted(list[0]));
        assertFalse(other.isWhitelisted(list[1]));
        assertEq(other.listingEta(list[1]), 0, "a cancelled listing stays cancelled");
    }

    function test_XA42_statusReportsListingsAndPendingProposals() public {
        configure.propose(factory, _list(), _list(), _none(), _currencies());
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        address[] memory onlyB = new address[](1);
        onlyB[0] = address(b);
        configure.execute(factory, onlyB);

        ConfigureWeighted.Report[] memory reports = configure.status(factory, _list());
        assertEq(reports[0].token, address(a));
        assertFalse(reports[0].listed);
        assertGt(reports[0].eta, 0);
        assertEq(reports[1].token, address(b));
        assertTrue(reports[1].listed);
        assertEq(reports[1].eta, 0);
    }

    // ---------------------------------------------------------------------
    // run
    // ---------------------------------------------------------------------

    /// @dev A7-22: no whitelist entry may name the deployment's own mint currency as a component, off Ethereum too.
    ///      The check compared against Ethereum's USDC and USDT alone, so a testnet whitelist naming its tUSDC was
    ///      proposed.
    function test_A722_theDeploymentsMintCurrencyIsNeverAComponent() public {
        MockERC20 tUsdc = new MockERC20("Test USDC", "tUSDC", 6);
        address[] memory list = new address[](2);
        (list[0], list[1]) = (address(tUsdc), address(b));
        address[2] memory currencies = [address(tUsdc), HERE_USDT];
        (bytes[] memory calls,) = configure.safeCalldata(factory, list, list, _none(), currencies);
        assertEq(calls.length, 1, "only b is proposed");
        assertEq(calls[0], abi.encodeCall(WeightedIndexFactory.proposeListing, (address(b))));
        configure.propose(factory, list, list, _none(), currencies);
        assertEq(factory.listingEta(address(tUsdc)), 0, "nor through propose");
        assertGt(factory.listingEta(address(b)), 0);
    }

    /// @dev A7-22: off Ethereum the mint currencies are V5_USDC and V5_USDT, which only the deployment knows, and both
    ///      are required; on Ethereum they are the address book's, and another address is refused.
    function test_A722_theMintCurrenciesAreTheDeployments() public {
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.MintCurrencyRequired.selector, "V5_USDC"));
        configure.mintCurrencies(address(0), HERE_USDT);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.MintCurrencyRequired.selector, "V5_USDT"));
        configure.mintCurrencies(HERE_USDC, address(0));
        address[2] memory here = configure.mintCurrencies(HERE_USDC, HERE_USDT);
        assertEq(here[0], HERE_USDC);
        assertEq(here[1], HERE_USDT);

        vm.chainId(1);
        address[2] memory pinned = configure.mintCurrencies(address(0), address(0));
        assertEq(pinned[0], MainnetAddresses.USDC);
        assertEq(pinned[1], MainnetAddresses.USDT);
        pinned = configure.mintCurrencies(MainnetAddresses.USDC, MainnetAddresses.USDT);
        assertEq(pinned[1], MainnetAddresses.USDT, "naming the address book's own is no override");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.MintCurrencyOverride.selector, "V5_USDC", HERE_USDC));
        configure.mintCurrencies(HERE_USDC, address(0));
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.MintCurrencyOverride.selector, "V5_USDT", HERE_USDT));
        configure.mintCurrencies(address(0), HERE_USDT);

        // BNB Chain's are its own address book's, pinned the same way: Ethereum's are another address there.
        vm.chainId(BnbChainAddresses.CHAIN_ID);
        pinned = configure.mintCurrencies(address(0), address(0));
        assertEq(pinned[0], BnbChainAddresses.USDC);
        assertEq(pinned[1], BnbChainAddresses.USDT);
        pinned = configure.mintCurrencies(BnbChainAddresses.USDC, BnbChainAddresses.USDT);
        assertEq(pinned[0], BnbChainAddresses.USDC, "naming the address book's own is no override");
        vm.expectRevert(
            abi.encodeWithSelector(ConfigureWeighted.MintCurrencyOverride.selector, "V5_USDC", MainnetAddresses.USDC)
        );
        configure.mintCurrencies(MainnetAddresses.USDC, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(ConfigureWeighted.MintCurrencyOverride.selector, "V5_USDT", MainnetAddresses.USDT)
        );
        configure.mintCurrencies(address(0), MainnetAddresses.USDT);
    }

    /// @dev The script reads these variables, which only this test sets. A7-22: `run` takes the deployment's mint
    ///      currencies from V5_USDC and V5_USDT, here `b` and a token no list names, and proposes neither.
    function test_A722_run_readsEnvironment() public {
        string memory raw = string.concat(vm.toString(address(a)), ",", vm.toString(address(b)));
        vm.setEnv("V5_FACTORY", vm.toString(address(factory)));
        vm.setEnv("V5_WHITELIST", raw);
        vm.setEnv("V5_LIST", "all");
        vm.setEnv("V5_RELIST", "");
        vm.setEnv("V5_USDC", vm.toString(address(b)));
        vm.setEnv("V5_USDT", vm.toString(HERE_USDT));
        vm.setEnv("V5_MODE", "safe");
        configure.run();
        assertEq(factory.listingEta(address(a)), 0, "safe mode broadcasts nothing");
        vm.setEnv("V5_MODE", "propose");
        configure.run();
        assertGt(factory.listingEta(address(a)), 0);
        assertEq(factory.listingEta(address(b)), 0, "the deployment's mint currency is never proposed");
        vm.setEnv("V5_MODE", "status");
        configure.run();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.setEnv("V5_MODE", "execute");
        configure.run();
        assertTrue(factory.isWhitelisted(address(a)));
        assertFalse(factory.isWhitelisted(address(b)), "nor listed");
        vm.setEnv("V5_MODE", "sideways");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.UnknownMode.selector, "sideways"));
        configure.run();
    }

    // ---------------------------------------------------------------------
    // Base
    // ---------------------------------------------------------------------

    /// @dev The Base list is `BaseAddresses`' table, resolved on chain 8453 alone: WETH and AERO, issued there, then
    ///      ZRO and the thirteen copies Base's own bridge mints, each naming the coin of Ethereum's list it is a
    ///      copy of. No Ondo stock, no mint currency and no coin of another chain's list is on it.
    function test_theBaseListIsTheTable() public {
        vm.chainId(BaseAddresses.CHAIN_ID);
        address[] memory list = configure.resolveList("base");
        address[] memory tokens = BaseAddresses.all();
        assertEq(
            list.length, 32, "WETH, AERO, ZRO, the bridge's thirteen copies, and Coinbase's six coins and ten stocks"
        );
        assertEq(list, tokens);
        uint256[4] memory count;
        uint256 copies = 0;
        for (uint256 i = 0; i < tokens.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                assertTrue(tokens[i] != tokens[j], "one entry per token");
            }
            Listings.Tier tier = BaseAddresses.tierOf(tokens[i]);
            assertTrue(tier != Listings.Tier.Unrecorded, "every listed coin is recorded");
            ++count[uint256(tier)];
            address remote = BaseAddresses.remoteOf(tokens[i]);
            if (remote != address(0)) {
                ++copies;
                assertEq(uint8(tier), uint8(Listings.Tier.Bridged), "a copy of the bridge's is Bridged");
                assertTrue(Listings.tierOf(remote) != Listings.Tier.Unrecorded, "of a coin Ethereum's list holds");
                assertTrue(remote != tokens[i], "at another address than its coin's");
            }
        }
        assertEq(copies, 13);
        assertEq(list[0], BaseAddresses.WETH);
        assertEq(count[uint256(Listings.Tier.Native)], 2, "WETH and AERO");
        assertEq(count[uint256(Listings.Tier.Bridged)], 14, "ZRO and the thirteen copies");
        assertEq(count[uint256(Listings.Tier.Custodial)], 16, "the six Coinbase Wrapped coins and the ten stocks");
        address[10] memory stocks = BaseAddresses.stocks();
        for (uint256 i = 0; i < stocks.length; ++i) {
            assertEq(list[22 + i], stocks[i], "the stocks close the list");
            assertTrue(BaseAddresses.isStock(stocks[i]));
            assertFalse(BaseAddresses.isCoinbaseWrapped(stocks[i]));
            assertEq(bytes1(bytes20(stocks[i])), bytes1(0xb2), "a B20 token's address starts with 0xb2");
        }
        assertTrue(BaseAddresses.isCoinbaseWrapped(BaseAddresses.CBADA));
        assertFalse(BaseAddresses.isStock(BaseAddresses.CBBTC));
        assertFalse(BaseAddresses.isStock(BaseAddresses.WETH));
        assertFalse(BaseAddresses.isCoinbaseWrapped(BaseAddresses.WETH));
        assertEq(BaseAddresses.remoteOf(BaseAddresses.CBETH), address(0), "cbETH's coin is not on Ethereum's list");
        assertEq(configure.tierLabel(BaseAddresses.CBBTC), " (Custodial)");
        assertEq(configure.tierLabel(BaseAddresses.CBETH), " (Custodial)");
        assertEq(configure.tierLabel(BaseAddresses.NVDAC), " (Custodial)");
        assertEq(BaseAddresses.remoteOf(BaseAddresses.WETH), address(0));
        assertEq(BaseAddresses.remoteOf(BaseAddresses.AERO), address(0));
        assertEq(
            BaseAddresses.remoteOf(BaseAddresses.ZRO), address(0), "the issuer's own token, no copy of the bridge's"
        );
        assertEq(configure.tierLabel(BaseAddresses.AERO), " (Native)");
        assertEq(configure.tierLabel(BaseAddresses.UNI), " (Bridged)");
        assertEq(configure.tierLabel(BaseAddresses.ZRO), " (Bridged)");
        assertEq(configure.tierLabel(BaseAddresses.USDC), "", "a mint currency carries no tier");
        assertEq(uint8(BaseAddresses.tierOf(BaseAddresses.USDT)), uint8(Listings.Tier.Unrecorded));
        address[3] memory excluded = [
            0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196, // LINK: Chainlink's own cross-chain token, not the bridge's copy
            MainnetAddresses.AAPLON, // no Ondo stock stands on Base
            0xDEc933e2392AD908263e70A386fbF34e703Ffe8F // wbCOIN: Backed's wrapper of an older token, which stands there
        ];
        for (uint256 i = 0; i < excluded.length; ++i) {
            assertEq(uint8(BaseAddresses.tierOf(excluded[i])), uint8(Listings.Tier.Unrecorded));
        }

        // The list is Base's alone, and the other chains' lists are not Base's.
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.ListOffItsChain.selector, "wide", 8453));
        configure.resolveList("wide");
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.ListOffItsChain.selector, "bnb", 8453));
        configure.resolveList("bnb");
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.ListOffItsChain.selector, "base", 1));
        configure.resolveList("base");
        vm.chainId(BnbChainAddresses.CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(ScriptLists.ListOffItsChain.selector, "base", 56));
        configure.resolveList("base");
    }

    /// @dev CR-L08 for Base: the list is the release record, pinned against this table, written out by hand with the
    ///      Ethereum token each copy names, and so are the market's addresses.
    function test_CRL08_theBaseListIsTheReleaseRecord() public view {
        address[] memory list = configure.baseList();
        address[32] memory tokens = [
            0x4200000000000000000000000000000000000006, // WETH
            0x940181a94A35A4569E4529A3CDfB74e38FD98631, // AERO
            0x6985884C4392D348587B19cb9eAAf157F13271cd, // ZRO
            0xc3De830EA07524a0761646a6a4e4be0e114a3C83, // UNI
            0x63706e401c06ac8513145b7687A14804d17f814b, // AAVE
            0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842, // MORPHO
            0x74F804B4140ee70830B3Eef4e690325841575F89, // FET
            0x8Ee73c484A26e0A5df2Ee2a4960B789967dd0415, // CRV
            0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b, // VIRTUAL
            0xA99F6e6785Da0F5d6fB42495Fe424BCE029Eeb3E, // PENDLE
            0xB4fDe59a779991bfB6a52253B51947828b982be3, // PEPE
            0x0F4d237B09Cb37d207BA60353Dc254d4530D4dF1, // GRT
            0x9e1028F5F1D5eDE59748FFceE5532509976840E0, // COMP
            0x22e6966B799c4D5B13BE962E1D117b56327FDa66, // SNX
            0xc5fecC3a29Fb57B5024eEc8a2239d4621e111CBE, // 1INCH
            0xaB36452DbAC151bE02b16Ca17d8919826072f64a, // RSR
            0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf, // cbBTC
            0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22, // cbETH
            0xcb585250f852C6c6bf90434AB21A00f02833a4af, // cbXRP
            0xcbD06E5A2B0C65597161de254AA074E489dEb510, // cbDOGE
            0xcb17C9Db87B595717C857a08468793f5bAb6445F, // cbLTC
            0xcbADA732173e39521CDBE8bf59a6Dc85A9fc7b8c, // cbADA
            0xb20000000000000000000078ee7ce2fE4908108C, // NVDAc
            0xb2000000000000000000008bC8786B856E61707C, // METAc
            0xb200000000000000000000C2e324d24d7eEcd1fb, // AAPLc
            0xb2000000000000000000002D0BA3164cc74f58B7, // GOOGLc
            0xb200000000000000000000d9192b6B456483C2E8, // AMZNc
            0xB200000000000000000000Ab99cFa739E253872B, // MSFTc
            0xb2000000000000000000004884b426556b92883d, // MSTRc
            0xb200000000000000000000397293Cb8cda9a10c5, // SNDKc
            0xb2000000000000000000007b9fcbd005511aCBd5, // SPCXc
            0xb2000000000000000000001e800a7f5189430cD0 // TSLAc
        ];
        // The coin on Ethereum each copy of the bridge's names; zero for a token that is no such copy, the three
        // first and every coin and stock of Coinbase's, which the loop below reads past the table's end.
        address[16] memory remotes = [
            address(0),
            address(0),
            address(0),
            0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, // UNI
            0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9, // AAVE
            0x58D97B57BB95320F9a05dC918Aef65434969c2B2, // MORPHO
            0xaea46A60368A7bD060eec7DF8CBa43b7EF41Ad85, // FET
            0xD533a949740bb3306d119CC777fa900bA034cd52, // CRV
            0x44ff8620b8cA30902395A7bD3F2407e1A091BF73, // VIRTUAL
            0x808507121B80c02388fAd14726482e061B8da827, // PENDLE
            0x6982508145454Ce325dDbE47a25d4ec3d2311933, // PEPE
            0xc944E90C64B2c07662A292be6244BDf05Cda44a7, // GRT
            0xc00e94Cb662C3520282E6f5717214004A7f26888, // COMP
            0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F, // SNX
            0x111111111117dC0aa78b770fA6A738034120C302, // 1INCH
            0x320623b8E4fF03373931769A31Fc52A4E78B5d70 // RSR
        ];
        assertEq(list.length, tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(list[i], tokens[i]);
            assertEq(BaseAddresses.remoteOf(list[i]), i < remotes.length ? remotes[i] : address(0));
        }
        assertEq(BaseAddresses.STOCK_DECIMALS, 8);
        assertEq(BaseAddresses.remoteOf(address(this)), address(0), "a token off the list names nothing");
        assertEq(BaseAddresses.USDC, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(BaseAddresses.USDT, 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2);
        assertEq(BaseAddresses.UNIVERSAL_ROUTER, 0x6fF5693b99212Da76ad316178A184AB56D299b43);
        assertEq(BaseAddresses.POOL_MANAGER, 0x498581fF718922c3f8e6A244956aF099B2652b2b);
        assertEq(BaseAddresses.UNISWAP_V3_FACTORY, 0x33128a8fC17869897dcE68Ed026d694621f6FDfD);
        assertEq(BaseAddresses.STANDARD_BRIDGE, 0x4200000000000000000000000000000000000010);
        assertEq(BaseAddresses.L1_STANDARD_BRIDGE, 0x3154Cf16ccdb4C6d922629664174b904d80F2C35);
    }

    /// @dev One of Coinbase's stock tokens is a precompile of Base: its code is the byte 0xef, and in an EVM without
    ///      Base's precompiles, this one, a call to it fails. The listing script then takes its decimals from the
    ///      address book and builds the Safe's proposal all the same, on Base and for a stock only: another token
    ///      that answers no decimals is skipped, and so is a stock under any other chain's id.
    function test_aStockTheScriptCannotReadIsProposedOnBase() public {
        address[] memory list = new address[](2);
        list[0] = BaseAddresses.NVDAC;
        list[1] = makeAddr("another precompile");
        vm.etch(list[0], hex"ef");
        vm.etch(list[1], hex"ef");
        (bool answered,) = list[0].staticcall{gas: 100_000}(abi.encodeWithSignature("decimals()"));
        assertFalse(answered, "this EVM cannot execute the token");

        (bytes[] memory calls,) = configure.safeCalldata(factory, list, list, _none(), _currencies());
        assertEq(calls.length, 0, "off Base nothing vouches for its decimals");

        vm.chainId(BaseAddresses.CHAIN_ID);
        (calls,) = configure.safeCalldata(factory, list, list, _none(), _currencies());
        assertEq(calls.length, 1, "the stock is proposed, the other token skipped");
        assertEq(calls[0], abi.encodeCall(WeightedIndexFactory.proposeListing, (BaseAddresses.NVDAC)));
    }

    /// @dev Base's mint currencies are never components, whatever a list names and whatever the deployment's own are
    ///      (the whitelist policy, A7-22), and on Base they are its address book's, which may be named and not
    ///      replaced.
    function test_A722_theBaseMintCurrenciesAreNeverComponentsAndArePinned() public {
        address[2] memory stables = [BaseAddresses.USDT, BaseAddresses.USDC];
        for (uint256 i = 0; i < stables.length; ++i) {
            vm.etch(stables[i], hex"00");
            vm.mockCall(stables[i], abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
            address[] memory list = new address[](1);
            list[0] = stables[i];
            (bytes[] memory calls,) = configure.safeCalldata(factory, list, list, _none(), _currencies());
            assertEq(calls.length, 0, "a mint currency is skipped");
        }

        vm.chainId(BaseAddresses.CHAIN_ID);
        address[2] memory pinned = configure.mintCurrencies(address(0), address(0));
        assertEq(pinned[0], BaseAddresses.USDC);
        assertEq(pinned[1], BaseAddresses.USDT);
        pinned = configure.mintCurrencies(BaseAddresses.USDC, BaseAddresses.USDT);
        assertEq(pinned[1], BaseAddresses.USDT, "naming the address book's own is no override");
        vm.expectRevert(
            abi.encodeWithSelector(ConfigureWeighted.MintCurrencyOverride.selector, "V5_USDC", MainnetAddresses.USDC)
        );
        configure.mintCurrencies(MainnetAddresses.USDC, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(ConfigureWeighted.MintCurrencyOverride.selector, "V5_USDT", BnbChainAddresses.USDT)
        );
        configure.mintCurrencies(address(0), BnbChainAddresses.USDT);
    }

    // ---------------------------------------------------------------------
    // Price feeds
    // ---------------------------------------------------------------------

    /// @dev Each chain's feed table runs in its list's order and names a feed for every listed token: a vault for
    ///      every wrapped xStock, a multiplier for every Coinbase stock token, the token itself for every other coin.
    ///      A token off a chain's list, or any token on a chain without a table, has none. The Ethereum ids are the
    ///      keeper's catalogue's, which `keeper/test/unit/price-ids.test.mjs` pins entry by entry.
    function test_everyListedTokenHasAFeed() public pure {
        assertEq(PriceFeeds.ETHEREUM_COUNT, Listings.COUNT);
        assertEq(PriceFeeds.BNB_COUNT, BnbChainAddresses.COUNT);
        assertEq(PriceFeeds.BASE_COUNT, BaseAddresses.COUNT);
        _assertTable(1, Listings.all(), 0);
        _assertTable(BnbChainAddresses.CHAIN_ID, BnbChainAddresses.all(), 0);
        address[] memory base = BaseAddresses.all();
        _assertTable(BaseAddresses.CHAIN_ID, base, 0);
        for (uint256 i = 0; i < base.length; ++i) {
            IPythPrices.FeedKind kind = PriceFeeds.feedOf(BaseAddresses.CHAIN_ID, base[i]).kind;
            bool stock = BaseAddresses.isStock(base[i]);
            assertEq(kind == IPythPrices.FeedKind.Multiplier, stock, "a stock token's feed prices its share");
        }
        assertEq(PriceFeeds.feedOf(1, MainnetAddresses.WETH).id, PriceFeeds.feedOf(8453, BaseAddresses.WETH).id);
        assertEq(
            PriceFeeds.feedOf(8453, BaseAddresses.UNI).id,
            PriceFeeds.feedOf(1, MainnetAddresses.UNI).id,
            "a copy of the bridge's is priced as its Ethereum coin"
        );
        assertEq(uint8(PriceFeeds.feedOf(1, address(0xbeef)).kind), uint8(IPythPrices.FeedKind.None));
        assertEq(uint8(PriceFeeds.feedOf(11_155_111, MainnetAddresses.WETH).kind), uint8(IPythPrices.FeedKind.None));
    }

    /// @dev Every token of `list` has a feed on `chainId`, none zero, `vaults` of them vaults.
    function _assertTable(uint256 chainId, address[] memory list, uint256 vaults) internal pure {
        uint256 counted = 0;
        (address[] memory tokens, IPythPrices.PriceFeed[] memory feeds) = PriceFeeds.table(chainId);
        for (uint256 i = 0; i < list.length; ++i) {
            IPythPrices.PriceFeed memory feed = PriceFeeds.find(list[i], tokens, feeds);
            assertTrue(feed.id != bytes32(0), "every listed token has a feed");
            assertTrue(feed.kind != IPythPrices.FeedKind.None);
            if (feed.kind == IPythPrices.FeedKind.Vault) ++counted;
        }
        assertEq(counted, vaults, "no listed token is a vault since the xStocks left");
    }

    /// @dev On a factory with an oracle, the script proposes each listed token's feed once: not again while it is
    ///      pending, and not once the factory holds it; on a factory without one it proposes nothing. Safe mode's
    ///      calldata is the same proposals, each labelled with the token and the feed.
    function test_theScriptProposesEachFeedOnce() public {
        vm.chainId(BaseAddresses.CHAIN_ID);
        MockPyth pyth = new MockPyth();
        WeightedIndexFactory priced =
            new WeightedIndexFactory(DEFAULT_SENDER, guardian, address(pyth), address(new WeightedMath()));
        address[] memory list = new address[](2);
        (list[0], list[1]) = (BaseAddresses.CBBTC, BaseAddresses.NVDAC);
        for (uint256 i = 0; i < list.length; ++i) {
            vm.etch(list[i], hex"00");
            pyth.addFeed(PriceFeeds.feedOf(BaseAddresses.CHAIN_ID, list[i]).id);
        }

        (bytes[] memory calls, string[] memory labels) =
            configure.feedCalldata(IWeightedIndexFactory(address(priced)), list);
        assertEq(calls.length, 2);
        IPythPrices.PriceFeed memory stock = PriceFeeds.feedOf(BaseAddresses.CHAIN_ID, list[1]);
        assertEq(calls[1], abi.encodeCall(IWeightedIndexFactory.proposePriceFeed, (list[1], stock)));
        assertEq(labels[1], string.concat("proposePriceFeed ? ", vm.toString(list[1]), " ", vm.toString(stock.id)));

        configure.proposeFeeds(IWeightedIndexFactory(address(priced)), list);
        (calls,) = configure.feedCalldata(IWeightedIndexFactory(address(priced)), list);
        assertEq(calls.length, 0, "pending, so not proposed again");
        configure.executeFeeds(IWeightedIndexFactory(address(priced)), list);
        assertEq(uint8(priced.priceFeedOf(list[1]).kind), uint8(IPythPrices.FeedKind.None), "not yet due");

        vm.warp(block.timestamp + priced.LISTING_DELAY());
        configure.executeFeeds(IWeightedIndexFactory(address(priced)), list);
        assertEq(priced.priceFeedOf(list[1]).id, stock.id);
        assertEq(uint8(priced.priceFeedOf(list[1]).kind), uint8(IPythPrices.FeedKind.Multiplier));
        (calls,) = configure.feedCalldata(IWeightedIndexFactory(address(priced)), list);
        assertEq(calls.length, 0, "held, so not proposed again");

        // A proposal left past its window is proposed again; a factory without an oracle is asked nothing.
        vm.prank(DEFAULT_SENDER);
        priced.proposePriceFeed(list[0], IPythPrices.PriceFeed({id: bytes32(0), kind: IPythPrices.FeedKind.None}));
        vm.warp(block.timestamp + priced.LISTING_DELAY() + priced.PROPOSAL_WINDOW() + 1);
        configure.executeFeeds(IWeightedIndexFactory(address(priced)), list);
        assertEq(priced.priceFeedOf(list[0]).id, PriceFeeds.feedOf(BaseAddresses.CHAIN_ID, list[0]).id, "expired");
        (calls,) = configure.feedCalldata(IWeightedIndexFactory(address(factory)), list);
        assertEq(calls.length, 0);
        configure.executeFeeds(IWeightedIndexFactory(address(factory)), list);
    }
}
