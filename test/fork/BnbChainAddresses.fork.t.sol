// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {WeightedMath} from "../../src/WeightedMath.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../../src/WeightedHub.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {BasketBuilder} from "../../src/BasketBuilder.sol";
import {MintRequests} from "../../src/MintRequests.sol";
import {IWeightedIndexFactory} from "../../src/interfaces/IWeightedIndexFactory.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IIndexHub} from "../../src/interfaces/IIndexHub.sol";
import {IRebalanceExecutor} from "../../src/interfaces/IRebalanceExecutor.sol";
import {IUniversalRouterSwaps} from "../../src/interfaces/IUniversalRouterSwaps.sol";
import {IXindexErrors} from "../../src/interfaces/IXindexErrors.sol";
import {IWeightedHub} from "../../src/interfaces/IWeightedHub.sol";
import {IPythPrices} from "../../src/interfaces/IPythPrices.sol";
import {IPythReader} from "../../src/interfaces/IPythReader.sol";
import {PriceFeeds} from "../../script/PriceFeeds.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {CheckToken} from "../../script/CheckToken.s.sol";
import {ConfigureWeighted} from "../../script/ConfigureWeighted.s.sol";
import {DeployWeighted} from "../../script/DeployWeighted.s.sol";
import {DeployChecks} from "../../script/DeployChecks.sol";
import {Listings} from "../../script/Listings.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {BnbChainAddresses as B} from "../../script/BnbChainAddresses.sol";

interface IRouterImmutables {
    function poolManager() external view returns (address);
}

/// @notice The guardian's Safe as the deploy checks read it: a contract that answers a threshold of two (CA-M4).
contract GuardianSafe {
    function getThreshold() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Checks the scripts' `BnbChainAddresses` against BNB Chain, as `MainnetAddresses.fork.t.sol` checks
///         Ethereum's: tokens by symbol and decimals, the router, the PoolManager and Uniswap's V3 factory by their
///         runtime code hashes, the BNB Chain list listed on a fresh factory and through `CheckToken`, a whole
///         deployment from the address book alone, and an index of that deployment issued in kind, rebalanced with
///         real transfers, minted and burned through the zap on Uniswap's real pools in USDT, BNB refused, and bought
///         and sold through `MintRequests` in both stablecoins. Skips when BNB_RPC_URL is unset.
///         Run: BNB_RPC_URL=... forge test --match-path 'test/fork/BnbChainAddresses.fork.t.sol' -vvv
contract BnbChainAddressesForkTest is Test, IRebalanceExecutor {
    using SafeERC20 for IERC20;

    /// @dev Runtime code hashes read on BNB Chain on 2026-10-07 at block 126,305,003 and again on 2026-11-13. The
    ///      router has no proxy and its immutables are part of its code, so the hash is the build and its wiring; the
    ///      build is Ethereum's but for those immutables.
    bytes32 constant UNIVERSAL_ROUTER_CODEHASH = 0x4899c516cf2f0b82251ab88630a9b326d1a2668855c553f9f5a0ea2de993e63b;
    bytes32 constant POOL_MANAGER_CODEHASH = 0x48752321ee7abf0d2a17c30679df9a1ddd14dc75d28b26e2509b76396145a005;
    bytes32 constant UNISWAP_V3_FACTORY_CODEHASH = 0x34b1009d0f004e58da791225992645e2df7697ac71ac89dc5e80469c4ef7e322;
    /// @dev Ethereum's router, by its runtime code: `MainnetAddresses.fork.t.sol` pins the same hash on Ethereum.
    bytes32 constant ETHEREUM_ROUTER_CODEHASH = 0x6a5f46971b50c6e1b7eef97902311444e479d734e4f80ad88367783cf373fe7f;
    /// @dev Block the fork pins to; BNB_FORK_BLOCK overrides it for a non-archive RPC that only serves recent state.
    ///      2026-11-21's, after every Ondo token the list names had been deployed; 133,361,996 of 2026-11-13 came
    ///      before some of them.
    uint256 constant FORK_BLOCK = 134_768_771;

    uint24 constant F500 = 500;

    /// @dev What a share of the test's three-coin index is worth at Pyth's prices, in dollars: about what 0.01 BNB,
    ///      0.0001 BTCB and 0.001 ETH a share came to, before creation was checked against the weights.
    uint256 constant MAJORS_DOLLARS = 20;

    address alice = makeAddr("alice");

    function setUp() public {
        string memory url = vm.envOr("BNB_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BNB_FORK_BLOCK", FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "BNB_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set BNB_FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/fork/*'"
                )
            );
        }
        assertEq(block.chainid, B.CHAIN_ID, "BNB_RPC_URL is a BNB Chain node");
        // A well-known test address can carry code on a live chain; the suite is about the zap, not about its payer.
        vm.etch(alice, "");
    }

    function _assertToken(address token, string memory symbol, uint8 decimals) internal view {
        assertEq(IERC20Metadata(token).symbol(), symbol);
        assertEq(IERC20Metadata(token).decimals(), decimals);
    }

    /// @dev Every token of the address book, by the symbol and decimals each answers on chain, written out here rather
    ///      than read from the list.
    function testFork_tokensAreWhatTheirNamesSay() public view {
        _assertToken(B.WBNB, "WBNB", 18);
        _assertToken(B.BTCB, "BTCB", 18);
        _assertToken(B.ETH, "ETH", 18);
        _assertToken(B.XRP, "XRP", 18);
        _assertToken(B.ZEC, "ZEC", 18);
        _assertToken(B.ADA, "ADA", 18);
        _assertToken(B.BCH, "BCH", 18);
        _assertToken(B.LTC, "LTC", 18);
        _assertToken(B.DOT, "DOT", 18);
        _assertToken(B.ATOM, "ATOM", 18);
        _assertToken(B.ASTER, "ASTER", 18);
        _assertToken(B.STABLE, "STABLE", 18);
        _assertToken(B.AAPLON, "AAPLon", 18);
        _assertToken(B.MSFTON, "MSFTon", 18);
        _assertToken(B.NVDAON, "NVDAon", 18);
        _assertToken(B.GOOGLON, "GOOGLon", 18);
        _assertToken(B.GOOGON, "GOOGon", 18);
        _assertToken(B.AMZNON, "AMZNon", 18);
        _assertToken(B.SPCXON, "SPCXon", 18);
        _assertToken(B.TSMON, "TSMon", 18);
        _assertToken(B.AVGOON, "AVGOon", 18);
        _assertToken(B.METAON, "METAon", 18);
        _assertToken(B.TSLAON, "TSLAon", 18);
        _assertToken(B.LLYON, "LLYon", 18);
        _assertToken(B.WMTON, "WMTon", 18);
        _assertToken(B.SKHYON, "SKHYon", 18);
        _assertToken(B.JPMON, "JPMon", 18);
        _assertToken(B.IVVON, "IVVon", 18);
        _assertToken(B.MUON, "MUon", 18);
        _assertToken(B.AMDON, "AMDon", 18);
        _assertToken(B.SPYON, "SPYon", 18);
        _assertToken(B.VON, "Von", 18);
        _assertToken(B.VTION, "VTIon", 18);
        _assertToken(B.XOMON, "XOMon", 18);
        _assertToken(B.JNJON, "JNJon", 18);
        _assertToken(B.MAON, "MAon", 18);
        _assertToken(B.ASMLON, "ASMLon", 18);
        _assertToken(B.ABBVON, "ABBVon", 18);
        _assertToken(B.COSTON, "COSTon", 18);
        _assertToken(B.QQQON, "QQQon", 18);
        _assertToken(B.KOON, "KOon", 18);
        _assertToken(B.CVXON, "CVXon", 18);
        _assertToken(B.PGON, "PGon", 18);
        _assertToken(B.PLTRON, "PLTRon", 18);
        _assertToken(B.CSCOON, "CSCOon", 18);
        _assertToken(B.ORCLON, "ORCLon", 18);
        _assertToken(B.GEON, "GEon", 18);
        _assertToken(B.BACON, "BACon", 18);
        _assertToken(B.HDON, "HDon", 18);
        _assertToken(B.MRKON, "MRKon", 18);
        _assertToken(B.INTCON, "INTCon", 18);
        _assertToken(B.UNHON, "UNHon", 18);
        _assertToken(B.PANWON, "PANWon", 18);
        _assertToken(B.AMATON, "AMATon", 18);
        _assertToken(B.LRCXON, "LRCXon", 18);
        _assertToken(B.TXNON, "TXNon", 18);
        _assertToken(B.RTXON, "RTXon", 18);
        _assertToken(B.TMOON, "TMOon", 18);
        _assertToken(B.CRWDON, "CRWDon", 18);
        _assertToken(B.CATON, "CATon", 18);
        _assertToken(B.GSON, "GSon", 18);
        _assertToken(B.ANETON, "ANETon", 18);
        _assertToken(B.NFLXON, "NFLXon", 18);
        _assertToken(B.WFCON, "WFCon", 18);
        _assertToken(B.SAPON, "SAPon", 18);
        _assertToken(B.AMGNON, "AMGNon", 18);
        _assertToken(B.LINON, "LINon", 18);
        _assertToken(B.IBMON, "IBMon", 18);
        _assertToken(B.BABAON, "BABAon", 18);
        _assertToken(B.AXPON, "AXPon", 18);
        _assertToken(B.DISON, "DISon", 18);
        _assertToken(B.GEVON, "GEVon", 18);
        _assertToken(B.DELLON, "DELLon", 18);
        _assertToken(B.ARMON, "ARMon", 18);
        _assertToken(B.CON, "Con", 18);
        _assertToken(B.APHON, "APHon", 18);
        _assertToken(B.MCDON, "MCDon", 18);
        _assertToken(B.KLACON, "KLACon", 18);
        _assertToken(B.PEPON, "PEPon", 18);
        _assertToken(B.VTVON, "VTVon", 18);
        _assertToken(B.VZON, "VZon", 18);
        _assertToken(B.ADION, "ADIon", 18);
        _assertToken(B.IEFAON, "IEFAon", 18);
        _assertToken(B.ABTON, "ABTon", 18);
        _assertToken(B.BLKON, "BLKon", 18);
        _assertToken(B.QCOMON, "QCOMon", 18);
        _assertToken(B.SHOPON, "SHOPon", 18);
        _assertToken(B.NEEON, "NEEon", 18);
        _assertToken(B.UNPON, "UNPon", 18);
        _assertToken(B.NVOON, "NVOon", 18);
        _assertToken(B.TMUSON, "TMUSon", 18);
        _assertToken(B.DEON, "DEon", 18);
        _assertToken(B.SCHWON, "SCHWon", 18);
        _assertToken(B.COPON, "COPon", 18);
        _assertToken(B.PFEON, "PFEon", 18);
        _assertToken(B.CRMON, "CRMon", 18);
        _assertToken(B.TON, "Ton", 18);
        _assertToken(B.ISRGON, "ISRGon", 18);
        _assertToken(B.AGGON, "AGGon", 18);
        _assertToken(B.IEMGON, "IEMGon", 18);
        _assertToken(B.UBERON, "UBERon", 18);
        _assertToken(B.VRTXON, "VRTXon", 18);
        _assertToken(B.LMTON, "LMTon", 18);
        _assertToken(B.MRVLON, "MRVLon", 18);
        _assertToken(B.ETNON, "ETNon", 18);
        _assertToken(B.ACNON, "ACNon", 18);
        _assertToken(B.SPGION, "SPGIon", 18);
        _assertToken(B.APPON, "APPon", 18);
        _assertToken(B.BAON, "BAon", 18);
        _assertToken(B.STXON, "STXon", 18);
        _assertToken(B.SCCOON, "SCCOon", 18);
        _assertToken(B.PDDON, "PDDon", 18);
        _assertToken(B.GLDON, "GLDon", 18);
        _assertToken(B.LOWON, "LOWon", 18);
        _assertToken(B.SPOTON, "SPOTon", 18);
        _assertToken(B.SBUXON, "SBUXon", 18);
        _assertToken(B.IJHON, "IJHon", 18);
        _assertToken(B.SGOVON, "SGOVon", 18);
        _assertToken(B.WDCON, "WDCon", 18);
        _assertToken(B.SNDKON, "SNDKon", 18);
        _assertToken(B.IWFON, "IWFon", 18);
        _assertToken(B.NETON, "NETon", 18);
        _assertToken(B.COFON, "COFon", 18);
        _assertToken(B.SOON, "SOon", 18);
        _assertToken(B.PBRON, "PBRon", 18);
        _assertToken(B.NEMON, "NEMon", 18);
        _assertToken(B.ABNBON, "ABNBon", 18);
        _assertToken(B.ENBON, "ENBon", 18);
        _assertToken(B.EQIXON, "EQIXon", 18);
        _assertToken(B.SNOWON, "SNOWon", 18);
        _assertToken(B.REGNON, "REGNon", 18);
        _assertToken(B.NOWON, "NOWon", 18);
        _assertToken(B.GLWON, "GLWon", 18);
        _assertToken(B.WMON, "WMon", 18);
        _assertToken(B.GDON, "GDon", 18);
        _assertToken(B.ITOTON, "ITOTon", 18);
        _assertToken(B.CEGON, "CEGon", 18);
        _assertToken(B.PWRON, "PWRon", 18);
        _assertToken(B.TTON, "TTon", 18);
        _assertToken(B.EMRON, "EMRon", 18);
        _assertToken(B.ADBEON, "ADBEon", 18);
        _assertToken(B.INTUON, "INTUon", 18);
        _assertToken(B.WMBON, "WMBon", 18);
        _assertToken(B.CVNAON, "CVNAon", 18);
        _assertToken(B.MRNAON, "MRNAon", 18);
        _assertToken(B.NOCON, "NOCon", 18);
        _assertToken(B.VRTON, "VRTon", 18);
        _assertToken(B.EFAON, "EFAon", 18);
        _assertToken(B.IWMON, "IWMon", 18);
        _assertToken(B.FCXON, "FCXon", 18);
        _assertToken(B.SLBON, "SLBon", 18);
        _assertToken(B.DASHON, "DASHon", 18);
        _assertToken(B.APOON, "APOon", 18);
        _assertToken(B.MELION, "MELIon", 18);
        _assertToken(B.NTESON, "NTESon", 18);
        _assertToken(B.HOODON, "HOODon", 18);
        _assertToken(B.HPEON, "HPEon", 18);
        _assertToken(B.TELON, "TELon", 18);
        _assertToken(B.NUEON, "NUEon", 18);
        _assertToken(B.IAUON, "IAUon", 18);
        _assertToken(B.AMEON, "AMEon", 18);
        _assertToken(B.OXYON, "OXYon", 18);
        _assertToken(B.BEON, "BEon", 18);
        _assertToken(B.NKEON, "NKEon", 18);
        _assertToken(B.LITEON, "LITEon", 18);
        _assertToken(B.KEYSON, "KEYSon", 18);
        _assertToken(B.IBITON, "IBITon", 18);
        _assertToken(B.BILON, "BILon", 18);
        _assertToken(B.PYPLON, "PYPLon", 18);
        _assertToken(B.TLTON, "TLTon", 18);
        _assertToken(B.XYZON, "XYZon", 18);
        _assertToken(B.CMGON, "CMGon", 18);
        _assertToken(B.FON, "Fon", 18);
        _assertToken(B.COHRON, "COHRon", 18);
        _assertToken(B.NOKON, "NOKon", 18);
        _assertToken(B.NTRAON, "NTRAon", 18);
        _assertToken(B.IEFON, "IEFon", 18);
        _assertToken(B.VSTON, "VSTon", 18);
        _assertToken(B.ROKON, "ROKon", 18);
        _assertToken(B.SOXXON, "SOXXon", 18);
        _assertToken(B.DYNFON, "DYNFon", 18);
        _assertToken(B.STMON, "STMon", 18);
        _assertToken(B.TTWOON, "TTWOon", 18);
        _assertToken(B.CIENON, "CIENon", 18);
        _assertToken(B.ALABON, "ALABon", 18);
        _assertToken(B.MSTRON, "MSTRon", 18);
        _assertToken(B.VNQON, "VNQon", 18);
        _assertToken(B.TERON, "TERon", 18);
        _assertToken(B.RKLBON, "RKLBon", 18);
        _assertToken(B.UMCON, "UMCon", 18);
        _assertToken(B.JDON, "JDon", 18);
        _assertToken(B.JAAAON, "JAAAon", 18);
        _assertToken(B.CLSON, "CLSon", 18);
        _assertToken(B.STLDON, "STLDon", 18);
        _assertToken(B.EQTON, "EQTon", 18);
        _assertToken(B.NBISON, "NBISon", 18);
        _assertToken(B.INSMON, "INSMon", 18);
        _assertToken(B.PCGON, "PCGon", 18);
        _assertToken(B.COINON, "COINon", 18);
        _assertToken(B.TQQQON, "TQQQon", 18);
        _assertToken(B.EFVON, "EFVon", 18);
        _assertToken(B.FLEXON, "FLEXon", 18);
        _assertToken(B.SHYON, "SHYon", 18);
        _assertToken(B.VRSNON, "VRSNon", 18);
        _assertToken(B.CCJON, "CCJon", 18);
        _assertToken(B.CRWVON, "CRWVon", 18);
        _assertToken(B.TCOMON, "TCOMon", 18);
        _assertToken(B.EEMON, "EEMon", 18);
        _assertToken(B.ONON, "ONon", 18);
        _assertToken(B.HALON, "HALon", 18);
        _assertToken(B.CPNGON, "CPNGon", 18);
        _assertToken(B.JBLON, "JBLon", 18);
        _assertToken(B.BIDUON, "BIDUon", 18);
        _assertToken(B.CRDOON, "CRDOon", 18);
        _assertToken(B.CBRSON, "CBRSon", 18);
        _assertToken(B.SLVON, "SLVon", 18);
        _assertToken(B.HUBBON, "HUBBon", 18);
        _assertToken(B.IYWON, "IYWon", 18);
        _assertToken(B.EWJON, "EWJon", 18);
        _assertToken(B.GFSON, "GFSon", 18);
        _assertToken(B.ENTGON, "ENTGon", 18);
        _assertToken(B.USFRON, "USFRon", 18);
        _assertToken(B.EWYON, "EWYon", 18);
        _assertToken(B.SWKSON, "SWKSon", 18);
        _assertToken(B.SOFION, "SOFIon", 18);
        _assertToken(B.HYGON, "HYGon", 18);
        _assertToken(B.NVTON, "NVTon", 18);
        _assertToken(B.RDDTON, "RDDTon", 18);
        _assertToken(B.MTSION, "MTSIon", 18);
        _assertToken(B.RIVNON, "RIVNon", 18);
        _assertToken(B.LSCCON, "LSCCon", 18);
        _assertToken(B.SMCION, "SMCIon", 18);
        _assertToken(B.TLNON, "TLNon", 18);
        _assertToken(B.WCCON, "WCCon", 18);
        _assertToken(B.TSEMON, "TSEMon", 18);
        _assertToken(B.LECOON, "LECOon", 18);
        _assertToken(B.MKSION, "MKSIon", 18);
        _assertToken(B.TIPON, "TIPon", 18);
        _assertToken(B.CRCLON, "CRCLon", 18);
        _assertToken(B.MTZON, "MTZon", 18);
        _assertToken(B.IWNON, "IWNon", 18);
        _assertToken(B.GMEON, "GMEon", 18);
        _assertToken(B.SOXLON, "SOXLon", 18);
        _assertToken(B.PAVEON, "PAVEon", 18);
        _assertToken(B.FUTUON, "FUTUon", 18);
        _assertToken(B.IGVON, "IGVon", 18);
        _assertToken(B.GRABON, "GRABon", 18);
        _assertToken(B.GNRCON, "GNRCon", 18);
        _assertToken(B.FNON, "FNon", 18);
        _assertToken(B.ITAON, "ITAon", 18);
        _assertToken(B.HIION, "HIIon", 18);
        _assertToken(B.IONQON, "IONQon", 18);
        _assertToken(B.LION, "LIon", 18);
        _assertToken(B.ALBON, "ALBon", 18);
        _assertToken(B.ONTOON, "ONTOon", 18);
        _assertToken(B.PINSON, "PINSon", 18);
        _assertToken(B.NVMION, "NVMIon", 18);
        _assertToken(B.BMNRON, "BMNRon", 18);
        _assertToken(B.SNAPON, "SNAPon", 18);
        _assertToken(B.FIGON, "FIGon", 18);
        _assertToken(B.AIQON, "AIQon", 18);
        _assertToken(B.AMKRON, "AMKRon", 18);
        _assertToken(B.AALON, "AALon", 18);
        _assertToken(B.RMBSON, "RMBSon", 18);
        _assertToken(B.OSCRON, "OSCRon", 18);
        _assertToken(B.TWSTON, "TWSTon", 18);
        _assertToken(B.EWZON, "EWZon", 18);
        _assertToken(B.ASTSON, "ASTSon", 18);
        _assertToken(B.AURON, "AURon", 18);
        _assertToken(B.TTMION, "TTMIon", 18);
        _assertToken(B.HUTON, "HUTon", 18);
        _assertToken(B.VICRON, "VICRon", 18);
        _assertToken(B.INDAON, "INDAon", 18);
        _assertToken(B.CLFON, "CLFon", 18);
        _assertToken(B.NIOON, "NIOon", 18);
        _assertToken(B.RIOTON, "RIOTon", 18);
        _assertToken(B.MPON, "MPon", 18);
        _assertToken(B.FORMON, "FORMon", 18);
        _assertToken(B.IRENON, "IRENon", 18);
        _assertToken(B.WULFON, "WULFon", 18);
        _assertToken(B.FPSON, "FPSon", 18);
        _assertToken(B.FIGRON, "FIGRon", 18);
        _assertToken(B.POWLON, "POWLon", 18);
        _assertToken(B.SHLDON, "SHLDon", 18);
        _assertToken(B.AGON, "AGon", 18);
        _assertToken(B.CAION, "CAIon", 18);
        _assertToken(B.ETHAON, "ETHAon", 18);
        _assertToken(B.COPXON, "COPXon", 18);
        _assertToken(B.CORZON, "CORZon", 18);
        _assertToken(B.BILION, "BILIon", 18);
        _assertToken(B.MXLON, "MXLon", 18);
        _assertToken(B.APLDON, "APLDon", 18);
        _assertToken(B.PLON, "PLon", 18);
        _assertToken(B.KWEBON, "KWEBon", 18);
        _assertToken(B.OKLOON, "OKLOon", 18);
        _assertToken(B.URAON, "URAon", 18);
        _assertToken(B.VSHON, "VSHon", 18);
        _assertToken(B.HIMSON, "HIMSon", 18);
        _assertToken(B.AAOION, "AAOIon", 18);
        _assertToken(B.FXION, "FXIon", 18);
        _assertToken(B.PRIMON, "PRIMon", 18);
        _assertToken(B.CIFRON, "CIFRon", 18);
        _assertToken(B.ENPHON, "ENPHon", 18);
        _assertToken(B.BLSHON, "BLSHon", 18);
        _assertToken(B.QBTSON, "QBTSon", 18);
        _assertToken(B.UECON, "UECon", 18);
        _assertToken(B.RGTION, "RGTIon", 18);
        _assertToken(B.BOTZON, "BOTZon", 18);
        _assertToken(B.PENGON, "PENGon", 18);
        _assertToken(B.ONDSON, "ONDSon", 18);
        _assertToken(B.AMCON, "AMCon", 18);
        _assertToken(B.USARON, "USARon", 18);
        _assertToken(B.SOXQON, "SOXQon", 18);
        _assertToken(B.GRNDON, "GRNDon", 18);
        _assertToken(B.ACHRON, "ACHRon", 18);
        _assertToken(B.MARAON, "MARAon", 18);
        _assertToken(B.GLXYON, "GLXYon", 18);
        _assertToken(B.AXTION, "AXTIon", 18);
        _assertToken(B.OUSTON, "OUSTon", 18);
        _assertToken(B.NVTSON, "NVTSon", 18);
        _assertToken(B.USOON, "USOon", 18);
        _assertToken(B.SQQQON, "SQQQon", 18);
        _assertToken(B.RXRXON, "RXRXon", 18);
        _assertToken(B.SOXSON, "SOXSon", 18);
        _assertToken(B.LUNRON, "LUNRon", 18);
        _assertToken(B.OIHON, "OIHon", 18);
        _assertToken(B.RDWON, "RDWon", 18);
        _assertToken(B.PURRON, "PURRon", 18);
        _assertToken(B.DNNON, "DNNon", 18);
        _assertToken(B.AION, "AIon", 18);
        _assertToken(B.AEHRON, "AEHRon", 18);
        _assertToken(B.WENON, "WENon", 18);
        _assertToken(B.PPLTON, "PPLTon", 18);
        _assertToken(B.SMRON, "SMRon", 18);
        _assertToken(B.URNMON, "URNMon", 18);
        _assertToken(B.UUUUON, "UUUUon", 18);
        _assertToken(B.SOUNON, "SOUNon", 18);
        _assertToken(B.PLUGON, "PLUGon", 18);
        _assertToken(B.IGEBON, "IGEBon", 18);
        _assertToken(B.SEDGON, "SEDGon", 18);
        _assertToken(B.WOLFON, "WOLFon", 18);
        _assertToken(B.OPENON, "OPENon", 18);
        _assertToken(B.QUBTON, "QUBTon", 18);
        _assertToken(B.KEELON, "KEELon", 18);
        _assertToken(B.INODON, "INODon", 18);
        _assertToken(B.SBETON, "SBETon", 18);
        _assertToken(B.BTDRON, "BTDRon", 18);
        _assertToken(B.BBAION, "BBAIon", 18);
        _assertToken(B.BNOON, "BNOon", 18);
        _assertToken(B.PSQON, "PSQon", 18);
        _assertToken(B.CPERON, "CPERon", 18);
        _assertToken(B.FCELON, "FCELon", 18);
        _assertToken(B.FLNCON, "FLNCon", 18);
        _assertToken(B.NNEON, "NNEon", 18);
        _assertToken(B.BOTON, "BOTon", 18);
        _assertToken(B.PALLON, "PALLon", 18);
        _assertToken(B.BTGOON, "BTGOon", 18);
        _assertToken(B.LPTHON, "LPTHon", 18);
        _assertToken(B.EXODON, "EXODon", 18);
        _assertToken(B.BWETON, "BWETon", 18);
        _assertToken(B.BAION, "BAIon", 18);
        _assertToken(B.DRAMON, "DRAMon", 18);
        _assertToken(B.SATAON, "SATAon", 18);
        _assertToken(B.STRCON, "STRCon", 18);
        _assertToken(B.USDT, "USDT", 18);
        _assertToken(B.USDC, "USDC", 18);
    }

    /// @dev CR-I35 on BNB Chain: the router names the PoolManager the address book does, and the router, the
    ///      PoolManager and the V3 factory are pinned by their code to the builds the zap was verified against.
    function testFork_CRI35_theRouterIsThePinnedBuild() public view {
        assertEq(IRouterImmutables(B.UNIVERSAL_ROUTER).poolManager(), B.POOL_MANAGER);
        assertEq(B.UNIVERSAL_ROUTER.codehash, UNIVERSAL_ROUTER_CODEHASH, "Uniswap's router is the 2.0.0 build");
        assertEq(B.POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH, "and the PoolManager is the one it settles with");
        assertEq(B.UNISWAP_V3_FACTORY.codehash, UNISWAP_V3_FACTORY_CODEHASH, "the V3 factory is Uniswap's");
    }

    /// @dev Ethereum's router address has code on BNB Chain: Ethereum's own router, byte for byte, immutables
    ///      included, so it names Ethereum's PoolManager address and settles against no market here. The deploy
    ///      checks read that address having code as "this is Ethereum" until 2026-11-13; they resolve BNB Chain's
    ///      book here, under BNB Chain's chain id and under an overridden one (RX-23).
    function testFork_ethereumsRouterAddressHereIsAReplayThatNamesNothing() public {
        assertEq(M.UNIVERSAL_ROUTER.codehash, ETHEREUM_ROUTER_CODEHASH, "Ethereum's router, replayed on BNB Chain");
        assertEq(IRouterImmutables(M.UNIVERSAL_ROUTER).poolManager(), M.POOL_MANAGER, "wired to Ethereum's addresses");
        assertTrue(M.UNIVERSAL_ROUTER != B.UNIVERSAL_ROUTER);
        assertTrue(M.POOL_MANAGER != B.POOL_MANAGER);

        DeployWeighted deployer = new DeployWeighted();
        assertTrue(deployer.onBnbChain());
        assertEq(deployer.pinnedRouter(), B.UNIVERSAL_ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "UNIVERSAL_ROUTER", M.UNIVERSAL_ROUTER)
        );
        deployer.resolveRouter(M.UNIVERSAL_ROUTER);
        vm.chainId(31_337);
        assertTrue(deployer.onBnbChain(), "the state is BNB Chain's whatever the chain id says");
        assertEq(deployer.resolveRouter(address(0)), B.UNIVERSAL_ROUTER);

        // Under an override to Ethereum's own id the id decides, as it must on the real chain 1, where anyone can
        // replay BNB Chain's router. The run stays pinned, resolves Ethereum's book, and stops at the first address
        // of it that is empty here: neither of Ethereum's USDC and USDT has code on BNB Chain.
        vm.chainId(1);
        assertTrue(deployer.isPinnedChain());
        assertFalse(deployer.onBnbChain());
        assertEq(M.USDC.code.length, 0);
        assertEq(M.USDT.code.length, 0);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressHasNoCode.selector, "USDC", M.USDC));
        deployer.resolveStable("USDC", address(0), M.USDC);
    }

    /// @dev On chain 56 the deploy script resolves every market address from the address book and refuses any other.
    function testFork_deployResolvesTheBnbChainMarket() public {
        DeployWeighted deployer = new DeployWeighted();
        assertEq(deployer.resolveRouter(address(0)), B.UNIVERSAL_ROUTER);
        assertEq(deployer.resolveStable("USDC", address(0), B.USDC), B.USDC);
        assertEq(deployer.resolveStable("USDT", address(0), B.USDT), B.USDT);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "USDT", B.USDC));
        deployer.resolveStable("USDT", B.USDC, B.USDT);
    }

    /// @dev A whole deployment on BNB Chain from the book alone: a contract owner the operator acknowledges (this
    ///      test, which answers no Safe threshold, A7-08), a guardian's Safe of two signatures, which a mainnet asks
    ///      for (CA-M4), and zero for every market address.
    function _deploy()
        internal
        returns (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests)
    {
        DeployWeighted deployer = new DeployWeighted();
        (factory, zap, builder, requests) = deployer.deploy(
            address(this), address(new GuardianSafe()), address(0), address(0), address(0), address(0), address(this)
        );
        deployer.checkDeployment(factory, zap, builder, requests);
    }

    function testFork_aDeploymentFromTheAddressBook() public {
        (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests) = _deploy();
        assertEq(factory.owner(), address(this));
        assertEq(address(zap.ROUTER()), B.UNIVERSAL_ROUTER);
        assertEq(zap.POOL_MANAGER(), B.POOL_MANAGER);
        assertEq(zap.USDC(), B.USDC, "the zap takes and pays BNB Chain's two stablecoins");
        assertEq(zap.USDT(), B.USDT);
        assertEq(address(builder.ROUTER()), B.UNIVERSAL_ROUTER);
        assertEq(builder.USDC(), B.USDC);
        assertEq(builder.USDT(), B.USDT);
        assertEq(requests.USDC(), B.USDC);
        assertEq(requests.USDT(), B.USDT);
    }

    /// @dev Lists `tokens` on `factory`, whose owner is this test, and on a factory with an oracle gives each the feed
    ///      `script/PriceFeeds.sol` names for it, behind the same delay.
    function _list(WeightedIndexFactory factory, address[] memory tokens) internal {
        bool priced = factory.PRICES() != address(0);
        (address[] memory known, IPythPrices.PriceFeed[] memory feeds) = PriceFeeds.table(B.CHAIN_ID);
        for (uint256 i = 0; i < tokens.length; ++i) {
            factory.proposeListing(tokens[i]);
            if (priced) factory.proposePriceFeed(tokens[i], PriceFeeds.find(tokens[i], known, feeds));
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < tokens.length; ++i) {
            factory.executeListing(tokens[i]);
            if (priced) factory.executePriceFeed(tokens[i]);
        }
    }

    /// @dev Has BNB Chain's Pyth answer each of `tokens`' stored prices as if published at this block's time. Pyth is a
    ///      pull oracle: a creator or a filler posts an update Pyth's keys signed, which a test cannot sign, so the tests
    ///      that are not about prices date the stored price to their own clock. The tests of Pyth's check read the
    ///      stored prices as they are, at the time they were published. A feed nobody has posted on BNB Chain has no
    ///      stored price (ZEC's and STABLE's at the pin, of the twelve, and most of the Ondo stocks'): it gets a
    ///      stand-in of a dollar, as the creator's own update would post a price there.
    function _freshPrices(WeightedIndexFactory factory, address[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; ++i) {
            bytes32 id = factory.priceFeedOf(tokens[i]).id;
            IPythReader.Price memory p = IPythReader(B.PYTH).priceFeedExists(id)
                ? IPythReader(B.PYTH).getPriceUnsafe(id)
                : IPythReader.Price({price: 1e8, conf: 0, expo: -8, publishTime: 0});
            p.publishTime = block.timestamp;
            vm.mockCall(B.PYTH, abi.encodeCall(IPythReader.getPriceUnsafe, (id)), abi.encode(p));
        }
    }

    /// @dev Specs of `tokens` at `weights`, `dollars` a share at Pyth's prices as `createIndex` reads them, so the index
    ///      is created on its weights.
    function _onWeights(
        WeightedIndexFactory factory,
        address[] memory tokens,
        uint256[] memory weights,
        uint256 dollars
    ) internal view returns (IWeightedIndexFactory.ComponentSpec[] memory specs) {
        IPythPrices prices = IPythPrices(factory.PRICES());
        specs = new IWeightedIndexFactory.ComponentSpec[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 value = prices.valueOf(tokens[i], false);
            specs[i] = IWeightedIndexFactory.ComponentSpec({
                token: tokens[i], weight: weights[i], units: dollars * 1e36 * weights[i] / 10_000 / value
            });
        }
    }

    function _params() internal pure returns (IWeightedIndexFactory.IndexParams memory) {
        return IWeightedIndexFactory.IndexParams({
            creatorFeeBps: 0,
            creatorStreamingBps: 0,
            maxPlatformFeeBps: 25,
            maxPlatformStreamingBps: 100,
            rebalanceInterval: 7 days,
            gated: false,
            listed: true
        });
    }

    /// @dev Every entry of the BNB Chain list, as the listing script builds it, listed on a fresh factory, which
    ///      records each token's on-chain decimals.
    function testFork_theBnbListMatchesTheChain() public {
        address[] memory list = new ConfigureWeighted().resolveList("bnb");
        assertEq(list.length, B.COUNT);
        WeightedIndexFactory factory =
            new WeightedIndexFactory(address(this), address(0), address(0), address(new WeightedMath()));
        _list(factory, list);
        for (uint256 i = 0; i < list.length; ++i) {
            assertTrue(factory.isWhitelisted(list[i]));
            assertEq(factory.decimalsOf(list[i]), IERC20Metadata(list[i]).decimals());
        }
    }

    /// @dev Every coin of the BNB Chain list passes `CheckToken` as listable, its transfers exact, with its powers
    ///      recorded for the signers: the Binance-Peg coins' single minting key, and STABLE's upgrade by a Safe.
    function testFork_everyBnbTokenPassesTheCheck() public {
        CheckToken checker = new CheckToken();
        address[] memory list = new ConfigureWeighted().bnbList();
        // the list's twelve coins; its Ondo stocks and ETFs are checked below, a hundred a test
        for (uint256 i = 0; i < 12; ++i) {
            CheckToken.Report memory r = checker.check(list[i], address(0), checker.markets());
            checker.log(r);
            assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact), r.symbol);
            assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Listable), r.symbol);
            if (B.tierOf(list[i]) == Listings.Tier.Custodial) {
                assertEq(r.powers, checker.MINT(), "a Binance-Peg coin's one power is its mint");
                assertEq(uint8(r.owner.kind), uint8(CheckToken.Kind.Key), "which one key holds");
                assertEq(r.implementation, address(0), "and no key can replace its code");
            }
        }
        CheckToken.Report memory stable = checker.check(B.STABLE, address(0), checker.markets());
        assertEq(stable.powers & checker.UPGRADE(), checker.UPGRADE());
        assertEq(uint8(stable.owner.kind), uint8(CheckToken.Kind.Safe), "STABLE is upgraded through a Safe");
    }

    /// @dev Ondo's stocks and ETFs of the BNB Chain list, after its twelve coins: each passes the check as listable, its
    ///      transfers exact. A hundred a test, since a check reads each token's code and pools at length.
    function testFork_theOndoTokensPassTheCheck_0to99() public {
        _checkOndo(12, 112);
    }

    function testFork_theOndoTokensPassTheCheck_100to199() public {
        _checkOndo(112, 212);
    }

    function testFork_theOndoTokensPassTheCheck_200to299() public {
        _checkOndo(212, 312);
    }

    function testFork_theOndoTokensPassTheCheck_300toTheEnd() public {
        _checkOndo(312, type(uint256).max);
    }

    function _checkOndo(uint256 from, uint256 to) internal {
        CheckToken checker = new CheckToken();
        address[] memory list = new ConfigureWeighted().bnbList();
        assertEq(list.length, 12 + 352);
        if (to > list.length) to = list.length;
        for (uint256 i = from; i < to; ++i) {
            CheckToken.Report memory r = checker.check(list[i], address(0), checker.markets());
            assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact), r.symbol);
            assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Listable), r.symbol);
            assertEq(uint8(B.tierOf(list[i])), uint8(Listings.Tier.Custodial), r.symbol);
        }
    }

    /// @dev The three coins the list leaves out for their proxy: one externally owned key can replace the code of
    ///      Binance-Peg DOGE, AVAX and FIL, the reason DOGE left Ethereum's list on 2026-10-14.
    function testFork_theLeftOutProxiesAnswerToOneKey() public {
        CheckToken checker = new CheckToken();
        address[3] memory proxies = [
            0xbA2aE424d960c26247Dd6c32edC70B295c744C43, // DOGE
            0x1CE0c2827e2eF14D5C4f29a091d735A204794041, // AVAX
            0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153 // FIL
        ];
        for (uint256 i = 0; i < proxies.length; ++i) {
            CheckToken.Report memory r = checker.check(proxies[i], address(0), checker.markets());
            assertEq(r.powers & checker.UPGRADE(), checker.UPGRADE(), r.symbol);
            assertTrue(r.implementation != address(0), r.symbol);
            assertEq(uint8(r.admin.kind), uint8(CheckToken.Kind.Key), "the proxy's admin is a key");
            assertEq(uint8(B.tierOf(proxies[i])), uint8(Listings.Tier.Unrecorded), "and the coin is off the list");
        }
    }

    /// @dev An index of the whole BNB Chain list issues and redeems in kind: every coin moves by exactly what the
    ///      index asks, and a full redeem returns every coin.
    function testFork_anIndexOfTheWholeListIssuesAndRedeemsInKind() public {
        (WeightedHub index, address[] memory list) = _twelveCoinIndex();
        uint256 shares = 100e18;
        uint256[] memory need = _issueInKind(index, alice, shares);
        assertEq(index.balanceOf(alice), shares);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(IERC20(list[i]).balanceOf(alice), 0);
            assertEq(IERC20(list[i]).balanceOf(address(index)), need[i], "the index holds the coin itself");
        }

        vm.prank(alice);
        index.redeem(shares, alice);
        assertEq(index.totalSupply(), 0);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(IERC20(list[i]).balanceOf(alice), need[i], "every coin comes back in kind");
        }
    }

    /// @dev An index of the whole BNB Chain list on a fresh deployment, $120 a share, created on its weights.
    function _twelveCoinIndex() internal returns (WeightedHub index, address[] memory list) {
        (WeightedIndexFactory factory,,,) = _deploy();
        // the list's twelve coins, which come first; its Ondo stocks and ETFs are each checked on their own above
        address[] memory all = B.all();
        list = new address[](12);
        uint256[] memory weights = new uint256[](12);
        for (uint256 i = 0; i < 12; ++i) {
            list[i] = all[i];
            // 12 coins: 837 for the first and 833 for each other is 10,000.
            weights[i] = i == 0 ? 837 : 833;
        }
        _list(factory, list);
        _freshPrices(factory, list);
        factory.setApprovedCreator(address(this), true);
        index = WeightedHub(
            factory.createIndex("BNB Chain Twelve", "BNB12", _onWeights(factory, list, weights, 120), _params())
        );
    }

    /// @dev Issues `shares` of `index` to `to` from coins dealt to it. Returns what the index took of each.
    function _issueInKind(WeightedHub index, address to, uint256 shares) internal returns (uint256[] memory need) {
        address[] memory tokens = index.componentTokens();
        need = index.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(tokens[i], to, need[i]);
            vm.prank(to);
            IERC20(tokens[i]).approve(address(index), need[i]);
        }
        vm.prank(to);
        index.issue(shares, to);
    }

    /// @dev The executor's callback, which this test answers as the rebalance's executor: it pays the index what it
    ///      asks from its own balance.
    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory tokens = IIndexHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsIn[i] != 0) IERC20(tokens[i]).safeTransfer(msg.sender, amountsIn[i]);
        }
    }

    /// @dev An index of the whole BNB Chain list rebalances with real transfers: WBNB leaves and each of the other
    ///      eleven coins comes in, so the index probes that it can send every one of them (RX-12) and the post-check
    ///      reads every real balance. The units are the ones the executor named, every balance moved by exactly the
    ///      previewed amount, and the holder then leaves in kind at the new units.
    function testFork_anIndexOfTheWholeListRebalancesWithRealTransfers() public {
        (WeightedHub index, address[] memory list) = _twelveCoinIndex();
        uint256 shares = 100e18;
        _issueInKind(index, alice, shares);

        vm.warp(index.earliestRebalance() + 1);
        index.startRebalance(0);
        uint256[] memory newUnits = index.recordedUnits();
        newUnits[0] = newUnits[0] * 9 / 10;
        for (uint256 i = 1; i < list.length; ++i) {
            newUnits[i] = newUnits[i] * 21 / 20;
        }
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + 2 hours);
        _freshPrices(WeightedIndexFactory(index.FACTORY()), list);
        (uint256 bar, int256 gain, uint256[] memory amountsOut, uint256[] memory amountsIn) =
            index.previewRebalance(newUnits);
        assertGt(bar, 0);
        assertGe(gain, int256(bar));
        assertGt(amountsOut[0], 0, "WBNB leaves");
        assertEq(amountsIn[0], 0);

        uint256[] memory held = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            held[i] = IERC20(list[i]).balanceOf(address(index));
            if (i != 0) {
                assertGt(amountsIn[i], 0, "every other coin comes in");
                assertEq(amountsOut[i], 0);
                deal(list[i], address(this), amountsIn[i]);
            }
        }
        uint256 wbnbBefore = IERC20(B.WBNB).balanceOf(address(this));
        index.executeRebalance(newUnits, "");

        assertEq(IERC20(B.WBNB).balanceOf(address(this)) - wbnbBefore, amountsOut[0], "the executor is paid in WBNB");
        uint256[] memory units = index.recordedUnits();
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(units[i], newUnits[i], "the units are the ones named");
            assertEq(IERC20(list[i]).balanceOf(address(index)), held[i] + amountsIn[i] - amountsOut[i]);
            if (i != 0) {
                assertEq(IERC20(list[i]).balanceOf(address(this)), 0, "the executor paid exactly what was asked");
            }
        }

        uint256[] memory back = index.previewRedeem(shares);
        vm.prank(alice);
        index.redeem(shares, alice);
        assertEq(index.totalSupply(), 0);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(IERC20(list[i]).balanceOf(alice), back[i], "the holder leaves in kind at the new units");
            assertGt(back[i], 0);
        }
    }

    /// @dev `MintRequests` on BNB Chain's deployment in each of its two stablecoins, both of 18 decimals there and
    ///      USDC a proxy: a mint request escrows the stablecoin and a filler's shares fill it, a redemption request
    ///      escrows the shares and the filler's stablecoin fills it, and a cancelled request returns its escrow.
    ///      Every amount lands whole: neither stablecoin charges a fee on transfer at this block.
    function testFork_requestsEscrowAndFillInBothStablecoins() public {
        (WeightedIndexFactory factory,,, MintRequests requests) = _deploy();
        WeightedHub index = _majors(factory);
        address filler = makeAddr("filler");
        vm.etch(filler, "");
        uint256 shares = 1e18;
        uint256 pay = 500e18;
        _issueInKind(index, filler, shares);

        address[2] memory stables = [B.USDT, B.USDC];
        for (uint256 s = 0; s < stables.length; ++s) {
            IERC20 stable = IERC20(stables[s]);
            deal(address(stable), alice, pay);
            deal(address(stable), filler, 0);
            uint256 deadline = block.timestamp + 1 days;

            vm.startPrank(alice);
            stable.forceApprove(address(requests), pay);
            uint256 id = requests.requestMint(address(index), address(stable), pay, shares, deadline);
            vm.stopPrank();
            assertEq(stable.balanceOf(address(requests)), pay, "the escrow is the whole amount");
            assertEq(stable.balanceOf(alice), 0);

            vm.startPrank(filler);
            index.approve(address(requests), shares);
            requests.fill(id, shares);
            vm.stopPrank();
            assertEq(index.balanceOf(alice), shares, "the requester has the shares");
            assertEq(stable.balanceOf(filler), pay, "and the filler the escrow");
            assertEq(stable.balanceOf(address(requests)), 0);

            vm.startPrank(alice);
            index.approve(address(requests), shares);
            id = requests.requestRedeem(address(index), shares, address(stable), pay, deadline);
            vm.stopPrank();
            assertEq(index.balanceOf(address(requests)), shares);

            vm.startPrank(filler);
            stable.forceApprove(address(requests), pay);
            requests.fill(id, pay);
            vm.stopPrank();
            assertEq(stable.balanceOf(alice), pay, "the requester is paid its limit in full");
            assertEq(index.balanceOf(filler), shares, "and the filler has the shares back");
            assertEq(index.balanceOf(address(requests)), 0);

            vm.startPrank(alice);
            stable.forceApprove(address(requests), pay);
            id = requests.requestMint(address(index), address(stable), pay, shares, deadline);
            requests.cancel(id);
            vm.stopPrank();
            assertEq(stable.balanceOf(alice), pay, "a cancelled request returns its escrow whole");
            assertEq(stable.balanceOf(address(requests)), 0);
        }
    }

    /// @dev An index of WBNB, BTCB and ETH on `factory`, the three coins Uniswap routes deepest on BNB Chain, created
    ///      on its weights.
    function _majors(WeightedIndexFactory factory) internal returns (WeightedHub index) {
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (B.WBNB, B.BTCB, B.ETH);
        uint256[] memory weights = new uint256[](3);
        (weights[0], weights[1], weights[2]) = (3334, 3333, 3333);
        _list(factory, three);
        _freshPrices(factory, three);
        factory.setApprovedCreator(address(this), true);
        index = WeightedHub(
            factory.createIndex(
                "BNB Chain Majors", "BMAJ", _onWeights(factory, three, weights, MAJORS_DOLLARS), _params()
            )
        );
    }

    function _threeCoinIndex() internal returns (IndexZap zap, WeightedHub index) {
        WeightedIndexFactory factory;
        (factory, zap,,) = _deploy();
        index = _majors(factory);
    }

    function _mintLegs(bytes[3] memory paths) internal pure returns (IUniversalRouterSwaps.MintLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.MintLeg[](3);
        for (uint256 i = 0; i < 3; ++i) {
            legs[i] = IUniversalRouterSwaps.MintLeg({v3Path: paths[i], v4Path: new PathKey[](0), maxAmountIn: 0});
        }
    }

    function _burnLegs(bytes[3] memory paths) internal pure returns (IUniversalRouterSwaps.BurnLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.BurnLeg[](3);
        for (uint256 i = 0; i < 3; ++i) {
            legs[i] = IUniversalRouterSwaps.BurnLeg({v3Path: paths[i], v4Path: new PathKey[](0), minAmountOut: 0});
        }
    }

    /// @dev The zap mints an index of BNB Chain's deployment from USDT alone and burns it back to USDT, through the
    ///      pinned Universal Router and Uniswap's real V3 pools: the command inputs the zap encodes for Ethereum's
    ///      router hold on BNB Chain's, and the index receives every coin in kind. The round trip costs the pools'
    ///      fees and nothing else.
    function testFork_theZapMintsAndBurnsInUsdtThroughUniswap() public {
        (IndexZap zap, WeightedHub index) = _threeCoinIndex();
        uint256 shares = 10e18;
        uint256 budget = 10_000e18;
        deal(B.USDT, alice, budget);

        // Exact-output paths run from the component back to what the user pays with.
        bytes[3] memory mintPaths = [
            abi.encodePacked(B.WBNB, F500, B.USDT),
            abi.encodePacked(B.BTCB, F500, B.USDT),
            abi.encodePacked(B.ETH, F500, B.USDT)
        ];
        vm.startPrank(alice);
        IERC20(B.USDT).approve(address(zap), budget);
        uint256 spent = zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(index),
                expectedNonce: 0,
                tokenIn: B.USDT,
                maxAmountIn: budget,
                shares: shares,
                legs: _mintLegs(mintPaths),
                to: alice,
                deadline: block.timestamp,
                referrer: address(0)
            })
        );
        vm.stopPrank();
        assertEq(index.balanceOf(alice), shares);
        assertGt(spent, 0);
        assertEq(IERC20(B.USDT).balanceOf(alice), budget - spent, "what the swaps did not take came back");
        uint256[] memory units = index.recordedUnits();
        assertEq(IERC20(B.WBNB).balanceOf(address(index)), shares * units[0] / 1e18, "the index holds BNB in kind");
        assertEq(IERC20(B.BTCB).balanceOf(address(index)), shares * units[1] / 1e18);
        assertEq(IERC20(B.ETH).balanceOf(address(index)), shares * units[2] / 1e18);
        assertEq(IERC20(B.USDT).balanceOf(address(zap)), 0, "nothing stays in the zap");

        bytes[3] memory burnPaths = [
            abi.encodePacked(B.WBNB, F500, B.USDT),
            abi.encodePacked(B.BTCB, F500, B.USDT),
            abi.encodePacked(B.ETH, F500, B.USDT)
        ];
        vm.startPrank(alice);
        index.approve(address(zap), shares);
        uint256 out = zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(index),
                expectedNonce: 0,
                shares: shares,
                tokenOut: B.USDT,
                minAmountOut: spent * 99 / 100,
                legs: _burnLegs(burnPaths),
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertEq(index.totalSupply(), 0);
        assertEq(IERC20(B.USDT).balanceOf(alice), budget - spent + out);
        assertGe(out, spent * 99 / 100, "the zap held the burn to its floor: a round trip loses under 1%");
        assertLt(out, spent, "and gains nothing");
    }

    /// @dev The zap takes and pays only BNB Chain's USDC and USDT (the owner's call of 2026-11-18, which withdrew its
    ///      ether entry points): a mint paid in WBNB and a burn into it are refused before anything moves, and no entry
    ///      point takes BNB.
    function testFork_theZapRefusesBnb() public {
        (IndexZap zap, WeightedHub index) = _threeCoinIndex();
        bytes[3] memory paths =
            [bytes(""), abi.encodePacked(B.BTCB, F500, B.WBNB), abi.encodePacked(B.ETH, F500, B.WBNB)];
        deal(B.WBNB, alice, 5 ether);
        vm.startPrank(alice);
        IERC20(B.WBNB).forceApprove(address(zap), 5 ether);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotAStable.selector, B.WBNB));
        zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(index),
                expectedNonce: 0,
                tokenIn: B.WBNB,
                maxAmountIn: 5 ether,
                shares: 10e18,
                legs: _mintLegs(paths),
                to: alice,
                deadline: block.timestamp,
                referrer: address(0)
            })
        );
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotAStable.selector, B.WBNB));
        zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(index),
                expectedNonce: 0,
                shares: 1,
                tokenOut: B.WBNB,
                minAmountOut: 1,
                legs: _burnLegs(paths),
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.deal(alice, 1 ether);
        (bool ok,) = address(zap).call{value: 1 ether}("");
        assertFalse(ok, "the zap takes no BNB");
        vm.stopPrank();
        assertEq(IERC20(B.WBNB).balanceOf(alice), 5 ether, "nothing moved");
    }

    /// @dev The publish time of the batch Pyth's contract on BNB Chain last stored BNB's and ETH's prices in, read on
    ///      2026-11-22.
    uint256 constant BNB_BATCH = 1_794_228_600;

    /// @dev A deployment from the book checks its fills against BNB Chain's Pyth: an index of WBNB and ETH, created 4%
    ///      off its weights, within the 5% creation allows, fills on its weights at Pyth's stored prices and is refused
    ///      a fill that keeps 3% of what it should bring in, at a tolerance of 1.5%. The clock is moved back to the
    ///      batch's time, as in Base's suite: a filler posts its own update, which the test cannot sign.
    function testFork_aFillIsCheckedAgainstPythsOwnContract() public {
        (WeightedIndexFactory factory,,,) = _deploy();
        assertEq(IPythPrices(factory.PRICES()).PYTH(), B.PYTH, "the deployment reads the book's Pyth");
        address[] memory coins = new address[](2);
        (coins[0], coins[1]) = (B.WBNB, B.ETH);
        uint256 fill = BNB_BATCH + 30;
        vm.warp(fill - 2 days - 7 days - 2 hours - 3 hours);
        _list(factory, coins);
        uint256[] memory market = new uint256[](2);
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        for (uint256 i = 0; i < coins.length; ++i) {
            IPythReader.Price memory p = IPythReader(B.PYTH).getPriceUnsafe(factory.priceFeedOf(coins[i]).id);
            assertEq(p.publishTime, BNB_BATCH, "one batch");
            market[i] = uint256(int256(p.price)) * 1e28 / 1e18;
            // $52 of BNB and $48 of ether a share, against weights of a half each.
            specs[i] = IWeightedIndexFactory.ComponentSpec({
                token: coins[i], weight: 5000, units: uint256(i == 0 ? 52 : 48) * 1e36 / market[i]
            });
        }
        factory.setApprovedCreator(address(this), true);
        WeightedHub index = WeightedHub(factory.createIndex("BNB and ETH", "BE", specs, _params()));
        _issueInKind(index, alice, 100e18);

        vm.warp(index.earliestRebalance());
        index.startRebalance(0);
        vm.warp(fill);
        uint256[] memory fair = index.recordedUnits();
        uint256 value = fair[0] * market[0] + fair[1] * market[1];
        (fair[0], fair[1]) = ((value / 2 + market[0] - 1) / market[0], (value / 2 + market[1] - 1) / market[1]);
        uint256[] memory greedy = index.recordedUnits();
        greedy[0] = fair[0];
        greedy[1] = greedy[1] + (fair[1] - greedy[1]) * 97 / 100;
        vm.expectPartialRevert(IWeightedHub.BelowOracleValue.selector);
        index.previewRebalance(greedy);
        deal(B.ETH, address(this), 1e24);
        index.executeRebalance(fair, "");
        assertEq(index.recordedUnits(), fair);
    }
}
