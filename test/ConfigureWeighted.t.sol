// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConfigureWeighted} from "../script/ConfigureWeighted.s.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {BnbChainAddresses} from "../script/BnbChainAddresses.sol";
import {Listings} from "../script/Listings.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

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
        factory = new WeightedIndexFactory(DEFAULT_SENDER, guardian);
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
            91,
            "the list of 2026-10-06, 2026-10-10's additions, less DOGE (10-14), with BNB and SUI, less SAND, RLB, BTT, SEI"
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
    ///         custodial, eight bridged
    ///         copies, and the rest issued on Ethereum.
    function test_everyListedCoinHasItsTier() public view {
        address[] memory tokens = Listings.all();
        uint256[4] memory count;
        for (uint256 i = 0; i < tokens.length; ++i) {
            Listings.Tier tier = Listings.tierOf(tokens[i]);
            assertTrue(tier != Listings.Tier.Unrecorded, "every listed coin is recorded");
            ++count[uint256(tier)];
        }
        assertEq(count[uint256(Listings.Tier.Native)], 48, "22 of the wide list and 26 of the hundred-coin list");
        assertEq(count[uint256(Listings.Tier.Bridged)], 19, "8, ZK and W, and 9 Wormhole copies");
        assertEq(count[uint256(Listings.Tier.Custodial)], 24, "19, and 5 Wormhole copies of Binance-Peg coins");
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
        assertEq(uint8(Listings.tierOf(MainnetAddresses.JUP)), uint8(Listings.Tier.Bridged), "a Wormhole copy");
        assertEq(uint8(Listings.tierOf(MainnetAddresses.OP)), uint8(Listings.Tier.Bridged));
        assertEq(uint8(Listings.tierOf(MainnetAddresses.BNB)), uint8(Listings.Tier.Bridged), "WBNB, not Binance-Peg");
        assertEq(uint8(Listings.tierOf(MainnetAddresses.SUI)), uint8(Listings.Tier.Bridged));
        assertEq(
            uint8(Listings.tierOf(MainnetAddresses.XRP)),
            uint8(Listings.Tier.Custodial),
            "a Wormhole copy of a Binance-Peg coin carries Binance's custody"
        );
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
        assertEq(uint8(Listings.tierOf(MainnetAddresses.ATOM)), uint8(Listings.Tier.Custodial));
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
        assertEq(first.length, 4);
        assertEq(wide.length, 87);
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(i < 4 ? first[i] : wide[i - 4], tokens[i]);
        }
    }

    /// @dev Each named list resolves on its own chain only: Ethereum's two on chain 1, BNB Chain's on chain 56.
    function test_theNamedListsResolveOnlyOnTheirChain() public {
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.ListOffItsChain.selector, "default", block.chainid));
        configure.resolveList("default");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.ListOffItsChain.selector, "wide", block.chainid));
        configure.resolveList("wide");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.ListOffItsChain.selector, "bnb", block.chainid));
        configure.resolveList("bnb");
        vm.chainId(1);
        assertEq(configure.resolveList("default").length, configure.DEFAULT_COUNT());
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.ListOffItsChain.selector, "bnb", 1));
        configure.resolveList("bnb");
        vm.chainId(BnbChainAddresses.CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.ListOffItsChain.selector, "wide", 56));
        configure.resolveList("wide");
        assertEq(configure.resolveList("bnb").length, BnbChainAddresses.COUNT);
    }

    /// @dev The BNB Chain list is `BnbChainAddresses`' table: WBNB, BTCB and ETH first, one entry per token, every coin
    ///      carrying its tier, and none of the coins the owner's rulings exclude.
    function test_theBnbListIsTheTable() public {
        vm.chainId(BnbChainAddresses.CHAIN_ID);
        address[] memory list = configure.resolveList("bnb");
        address[] memory tokens = BnbChainAddresses.all();
        assertEq(list.length, 12, "the BNB Chain list of 2026-10-07, less SOL, DOGE, AVAX, FIL and TRX");
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
        assertEq(count[uint256(Listings.Tier.Custodial)], 9, "BTCB, ETH and the seven Binance-Peg coins");
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
        address[12] memory tokens = [
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
            0x011EBe7d75E2C9D1E0bD0be0bEf5C36f0A90075F // STABLE
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
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.DuplicateEntry.selector, address(a)));
        configure.safeCalldata(factory, list, _list(), _none(), _currencies());
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.DuplicateEntry.selector, address(a)));
        configure.propose(factory, list, _list(), _none(), _currencies());

        string memory raw = string.concat(vm.toString(address(a)), ",", vm.toString(address(a)));
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
        WeightedIndexFactory owned = new WeightedIndexFactory(address(configure), guardian);
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
        WeightedIndexFactory other = new WeightedIndexFactory(someoneElse, guardian);
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
}
