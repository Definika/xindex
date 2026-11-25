// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {WeightedMath} from "../../src/WeightedMath.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {ConfigureWeighted} from "../../script/ConfigureWeighted.s.sol";
import {DeployWeighted} from "../../script/DeployWeighted.s.sol";
import {DeployChecks} from "../../script/DeployChecks.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {PriceFeeds} from "../../script/PriceFeeds.sol";
import {IPythPrices} from "../../src/interfaces/IPythPrices.sol";
import {IPythReader} from "../../src/interfaces/IPythReader.sol";

interface IRouterImmutables {
    function poolManager() external view returns (address);
}

/// @dev What the fork test asks Wormhole's token bridge: the copy it deployed for a source token, and whether a token
///      is one of its copies.
interface ITokenBridgeProbe {
    function wrappedAsset(uint16 tokenChainId, bytes32 tokenAddress) external view returns (address);

    function isWrappedAsset(address token) external view returns (bool);
}

/// @notice Checks the scripts' `MainnetAddresses` against mainnet, as CLAUDE.md requires before addresses are
///         committed: tokens by symbol and decimals, the router by the PoolManager it names and both by their runtime
///         code hashes, and every entry of the lists listed on a fresh factory with its token's own decimals. Skips
///         when MAINNET_RPC_URL is unset.
contract MainnetAddressesForkTest is Test {
    /// @dev Runtime code hash of Universal Router 2.0.0 at `MainnetAddresses.UNIVERSAL_ROUTER`, read on 2026-09-23. The
    ///      router has no proxy, and its immutables are part of its code, so the hash is the build and its wiring.
    bytes32 constant UNIVERSAL_ROUTER_CODEHASH = 0x6a5f46971b50c6e1b7eef97902311444e479d734e4f80ad88367783cf373fe7f;
    /// @dev Runtime code hash of the V4 PoolManager at `MainnetAddresses.POOL_MANAGER`, read on 2026-09-23.
    bytes32 constant POOL_MANAGER_CODEHASH = 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;
    /// @dev Runtime code hash of Uniswap V3's factory at `MainnetAddresses.UNISWAP_V3_FACTORY`, read on 2026-10-05.
    bytes32 constant UNISWAP_V3_FACTORY_CODEHASH = 0x4d7b8525cd5d14343fa67a732fba5b24cddba11620ca88392f4ec6c52f91fd69;
    /// @dev Runtime code hash of Wormhole's token bridge proxy at `MainnetAddresses.WORMHOLE_TOKEN_BRIDGE`, read on
    ///      2026-10-10. The guardians' governance upgrades the implementation behind it, so only the proxy is pinned.
    bytes32 constant WORMHOLE_BRIDGE_PROXY_CODEHASH =
        0x26aeb96c4320b04eeda9660276adf5920d056be2e1bee7f038255950e60d0a27;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        // FORK_BLOCK overrides the pin, for a non-archive RPC that only serves recent state. Forge loads .env
        // automatically, so a MAINNET_RPC_URL set there makes a plain `forge test` run these suites too.
        uint256 forkBlock = vm.envOr("FORK_BLOCK", A.LIST_FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "MAINNET_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/fork/*'"
                )
            );
        }
    }

    function _assertToken(address token, string memory symbol, uint8 decimals) internal view {
        assertEq(IERC20Metadata(token).symbol(), symbol);
        assertEq(IERC20Metadata(token).decimals(), decimals);
    }

    function testFork_XA13_tokensAreWhatTheirNamesSay() public view {
        _assertToken(M.WETH, "WETH", 18);
        _assertToken(M.USDC, "USDC", 6);
        _assertToken(M.USDT, "USDT", 6);
        _assertToken(M.WBTC, "WBTC", 8);
        _assertToken(M.LINK, "LINK", 18);
        _assertToken(M.UNI, "UNI", 18);
    }

    /// @dev The wide list's tokens, by the symbol and decimals each answers on chain, written out here rather than read
    ///      from the list. RNDR is Render and Cake is PancakeSwap's.
    function testFork_wideTokensAreWhatTheirNamesSay() public view {
        _assertToken(M.QNT, "QNT", 18);
        _assertToken(M.AAVE, "AAVE", 18);
        _assertToken(M.ENA, "ENA", 18);
        _assertToken(M.ONDO, "ONDO", 18);
        _assertToken(M.SKY, "SKY", 18);
        _assertToken(M.WLD, "WLD", 18);
        _assertToken(M.MNT, "MNT", 18);
        _assertToken(M.MORPHO, "MORPHO", 18);
        _assertToken(M.POL, "POL", 18);
        _assertToken(M.LIT, "LIT", 18);
        _assertToken(M.ETHFI, "ETHFI", 18);
        _assertToken(M.FET, "FET", 18);
        _assertToken(M.CRV, "CRV", 18);
        _assertToken(M.NEXO, "NEXO", 18);
        _assertToken(M.VIRTUAL, "VIRTUAL", 18);
        _assertToken(M.STRK, "STRK", 18);
        _assertToken(M.PENDLE, "PENDLE", 18);
        _assertToken(M.CRO, "CRO", 8);
        _assertToken(M.ICP, "ICP", 8);
        _assertToken(M.ARB, "ARB", 18);
        _assertToken(M.RENDER, "RNDR", 18);
        _assertToken(M.CAKE, "Cake", 18);
        _assertToken(M.ZRO, "ZRO", 18);
        _assertToken(M.INJ, "INJ", 18);
        _assertToken(M.SHIB, "SHIB", 18);
        _assertToken(M.PEPE, "PEPE", 18);
        _assertToken(M.SOL, "SOL", 9);
        _assertToken(M.XAUT, "XAUt", 6);
        _assertToken(M.NVDAON, "NVDAon", 18);
        _assertToken(M.AAPLON, "AAPLon", 18);
        _assertToken(M.GOOGLON, "GOOGLon", 18);
        _assertToken(M.MSFTON, "MSFTon", 18);
        _assertToken(M.AMZNON, "AMZNon", 18);
        _assertToken(M.TSMON, "TSMon", 18);
        _assertToken(M.SPCXON, "SPCXon", 18);
        _assertToken(M.METAON, "METAon", 18);
        _assertToken(M.AVGOON, "AVGOon", 18);
        _assertToken(M.TSLAON, "TSLAon", 18);
        _assertToken(M.SKHYON, "SKHYon", 18);
        _assertToken(M.MUON, "MUon", 18);
        _assertToken(M.LLYON, "LLYon", 18);
        _assertToken(M.AMDON, "AMDon", 18);
        _assertToken(M.JPMON, "JPMon", 18);
        _assertToken(M.WMTON, "WMTon", 18);
        _assertToken(M.VON, "Von", 18);
        _assertToken(M.GOOGON, "GOOGon", 18);
        _assertToken(M.IVVON, "IVVon", 18);
        _assertToken(M.SPYON, "SPYon", 18);
        _assertToken(M.VTION, "VTIon", 18);
        _assertToken(M.XOMON, "XOMon", 18);
        _assertToken(M.JNJON, "JNJon", 18);
        _assertToken(M.MAON, "MAon", 18);
        _assertToken(M.ASMLON, "ASMLon", 18);
        _assertToken(M.ABBVON, "ABBVon", 18);
        _assertToken(M.COSTON, "COSTon", 18);
        _assertToken(M.QQQON, "QQQon", 18);
        _assertToken(M.KOON, "KOon", 18);
        _assertToken(M.CVXON, "CVXon", 18);
        _assertToken(M.PGON, "PGon", 18);
        _assertToken(M.PLTRON, "PLTRon", 18);
        _assertToken(M.CSCOON, "CSCOon", 18);
        _assertToken(M.ORCLON, "ORCLon", 18);
        _assertToken(M.GEON, "GEon", 18);
        _assertToken(M.BACON, "BACon", 18);
        _assertToken(M.HDON, "HDon", 18);
        _assertToken(M.MRKON, "MRKon", 18);
        _assertToken(M.INTCON, "INTCon", 18);
        _assertToken(M.UNHON, "UNHon", 18);
        _assertToken(M.PANWON, "PANWon", 18);
        _assertToken(M.AMATON, "AMATon", 18);
        _assertToken(M.LRCXON, "LRCXon", 18);
        _assertToken(M.TXNON, "TXNon", 18);
        _assertToken(M.RTXON, "RTXon", 18);
        _assertToken(M.TMOON, "TMOon", 18);
        _assertToken(M.CRWDON, "CRWDon", 18);
        _assertToken(M.CATON, "CATon", 18);
        _assertToken(M.GSON, "GSon", 18);
        _assertToken(M.ANETON, "ANETon", 18);
        _assertToken(M.NFLXON, "NFLXon", 18);
        _assertToken(M.WFCON, "WFCon", 18);
        _assertToken(M.SAPON, "SAPon", 18);
        _assertToken(M.AMGNON, "AMGNon", 18);
        _assertToken(M.LINON, "LINon", 18);
        _assertToken(M.IBMON, "IBMon", 18);
        _assertToken(M.BABAON, "BABAon", 18);
        _assertToken(M.AXPON, "AXPon", 18);
        _assertToken(M.DISON, "DISon", 18);
        _assertToken(M.GEVON, "GEVon", 18);
        _assertToken(M.DELLON, "DELLon", 18);
        _assertToken(M.ARMON, "ARMon", 18);
        _assertToken(M.CON, "Con", 18);
        _assertToken(M.APHON, "APHon", 18);
        _assertToken(M.MCDON, "MCDon", 18);
        _assertToken(M.KLACON, "KLACon", 18);
        _assertToken(M.PEPON, "PEPon", 18);
        _assertToken(M.VTVON, "VTVon", 18);
        _assertToken(M.VZON, "VZon", 18);
        _assertToken(M.ADION, "ADIon", 18);
        _assertToken(M.IEFAON, "IEFAon", 18);
        _assertToken(M.ABTON, "ABTon", 18);
        _assertToken(M.BLKON, "BLKon", 18);
        _assertToken(M.QCOMON, "QCOMon", 18);
        _assertToken(M.SHOPON, "SHOPon", 18);
        _assertToken(M.NEEON, "NEEon", 18);
        _assertToken(M.UNPON, "UNPon", 18);
        _assertToken(M.NVOON, "NVOon", 18);
        _assertToken(M.TMUSON, "TMUSon", 18);
        _assertToken(M.DEON, "DEon", 18);
        _assertToken(M.SCHWON, "SCHWon", 18);
        _assertToken(M.COPON, "COPon", 18);
        _assertToken(M.PFEON, "PFEon", 18);
        _assertToken(M.CRMON, "CRMon", 18);
        _assertToken(M.TON, "Ton", 18);
        _assertToken(M.ISRGON, "ISRGon", 18);
        _assertToken(M.AGGON, "AGGon", 18);
        _assertToken(M.IEMGON, "IEMGon", 18);
        _assertToken(M.UBERON, "UBERon", 18);
        _assertToken(M.VRTXON, "VRTXon", 18);
        _assertToken(M.LMTON, "LMTon", 18);
        _assertToken(M.MRVLON, "MRVLon", 18);
        _assertToken(M.ETNON, "ETNon", 18);
        _assertToken(M.ACNON, "ACNon", 18);
        _assertToken(M.SPGION, "SPGIon", 18);
        _assertToken(M.APPON, "APPon", 18);
        _assertToken(M.BAON, "BAon", 18);
        _assertToken(M.STXON, "STXon", 18);
        _assertToken(M.SCCOON, "SCCOon", 18);
        _assertToken(M.PDDON, "PDDon", 18);
        _assertToken(M.GLDON, "GLDon", 18);
        _assertToken(M.LOWON, "LOWon", 18);
        _assertToken(M.SPOTON, "SPOTon", 18);
        _assertToken(M.SBUXON, "SBUXon", 18);
        _assertToken(M.IJHON, "IJHon", 18);
        _assertToken(M.SGOVON, "SGOVon", 18);
        _assertToken(M.WDCON, "WDCon", 18);
        _assertToken(M.SNDKON, "SNDKon", 18);
        _assertToken(M.IWFON, "IWFon", 18);
        _assertToken(M.NETON, "NETon", 18);
        _assertToken(M.COFON, "COFon", 18);
        _assertToken(M.SOON, "SOon", 18);
        _assertToken(M.PBRON, "PBRon", 18);
        _assertToken(M.NEMON, "NEMon", 18);
        _assertToken(M.ABNBON, "ABNBon", 18);
        _assertToken(M.ENBON, "ENBon", 18);
        _assertToken(M.EQIXON, "EQIXon", 18);
        _assertToken(M.SNOWON, "SNOWon", 18);
        _assertToken(M.REGNON, "REGNon", 18);
        _assertToken(M.NOWON, "NOWon", 18);
        _assertToken(M.GLWON, "GLWon", 18);
        _assertToken(M.WMON, "WMon", 18);
        _assertToken(M.GDON, "GDon", 18);
        _assertToken(M.ITOTON, "ITOTon", 18);
        _assertToken(M.CEGON, "CEGon", 18);
        _assertToken(M.PWRON, "PWRon", 18);
        _assertToken(M.TTON, "TTon", 18);
        _assertToken(M.EMRON, "EMRon", 18);
        _assertToken(M.ADBEON, "ADBEon", 18);
        _assertToken(M.INTUON, "INTUon", 18);
        _assertToken(M.WMBON, "WMBon", 18);
        _assertToken(M.CVNAON, "CVNAon", 18);
        _assertToken(M.MRNAON, "MRNAon", 18);
        _assertToken(M.NOCON, "NOCon", 18);
        _assertToken(M.VRTON, "VRTon", 18);
        _assertToken(M.EFAON, "EFAon", 18);
        _assertToken(M.IWMON, "IWMon", 18);
        _assertToken(M.FCXON, "FCXon", 18);
        _assertToken(M.SLBON, "SLBon", 18);
        _assertToken(M.DASHON, "DASHon", 18);
        _assertToken(M.APOON, "APOon", 18);
        _assertToken(M.MELION, "MELIon", 18);
        _assertToken(M.NTESON, "NTESon", 18);
        _assertToken(M.HOODON, "HOODon", 18);
        _assertToken(M.HPEON, "HPEon", 18);
        _assertToken(M.TELON, "TELon", 18);
        _assertToken(M.NUEON, "NUEon", 18);
        _assertToken(M.IAUON, "IAUon", 18);
        _assertToken(M.AMEON, "AMEon", 18);
        _assertToken(M.OXYON, "OXYon", 18);
        _assertToken(M.BEON, "BEon", 18);
        _assertToken(M.NKEON, "NKEon", 18);
        _assertToken(M.LITEON, "LITEon", 18);
        _assertToken(M.KEYSON, "KEYSon", 18);
        _assertToken(M.IBITON, "IBITon", 18);
        _assertToken(M.BILON, "BILon", 18);
        _assertToken(M.PYPLON, "PYPLon", 18);
        _assertToken(M.TLTON, "TLTon", 18);
        _assertToken(M.XYZON, "XYZon", 18);
        _assertToken(M.CMGON, "CMGon", 18);
        _assertToken(M.FON, "Fon", 18);
        _assertToken(M.COHRON, "COHRon", 18);
        _assertToken(M.NOKON, "NOKon", 18);
        _assertToken(M.NTRAON, "NTRAon", 18);
        _assertToken(M.IEFON, "IEFon", 18);
        _assertToken(M.VSTON, "VSTon", 18);
        _assertToken(M.ROKON, "ROKon", 18);
        _assertToken(M.SOXXON, "SOXXon", 18);
        _assertToken(M.DYNFON, "DYNFon", 18);
        _assertToken(M.STMON, "STMon", 18);
        _assertToken(M.TTWOON, "TTWOon", 18);
        _assertToken(M.CIENON, "CIENon", 18);
        _assertToken(M.ALABON, "ALABon", 18);
        _assertToken(M.MSTRON, "MSTRon", 18);
        _assertToken(M.VNQON, "VNQon", 18);
        _assertToken(M.TERON, "TERon", 18);
        _assertToken(M.RKLBON, "RKLBon", 18);
        _assertToken(M.UMCON, "UMCon", 18);
        _assertToken(M.JDON, "JDon", 18);
        _assertToken(M.JAAAON, "JAAAon", 18);
        _assertToken(M.CLSON, "CLSon", 18);
        _assertToken(M.STLDON, "STLDon", 18);
        _assertToken(M.EQTON, "EQTon", 18);
        _assertToken(M.NBISON, "NBISon", 18);
        _assertToken(M.INSMON, "INSMon", 18);
        _assertToken(M.PCGON, "PCGon", 18);
        _assertToken(M.COINON, "COINon", 18);
        _assertToken(M.TQQQON, "TQQQon", 18);
        _assertToken(M.EFVON, "EFVon", 18);
        _assertToken(M.FLEXON, "FLEXon", 18);
        _assertToken(M.SHYON, "SHYon", 18);
        _assertToken(M.VRSNON, "VRSNon", 18);
        _assertToken(M.CCJON, "CCJon", 18);
        _assertToken(M.CRWVON, "CRWVon", 18);
        _assertToken(M.TCOMON, "TCOMon", 18);
        _assertToken(M.EEMON, "EEMon", 18);
        _assertToken(M.ONON, "ONon", 18);
        _assertToken(M.HALON, "HALon", 18);
        _assertToken(M.CPNGON, "CPNGon", 18);
        _assertToken(M.JBLON, "JBLon", 18);
        _assertToken(M.BIDUON, "BIDUon", 18);
        _assertToken(M.CRDOON, "CRDOon", 18);
        _assertToken(M.CBRSON, "CBRSon", 18);
        _assertToken(M.SLVON, "SLVon", 18);
        _assertToken(M.HUBBON, "HUBBon", 18);
        _assertToken(M.IYWON, "IYWon", 18);
        _assertToken(M.EWJON, "EWJon", 18);
        _assertToken(M.GFSON, "GFSon", 18);
        _assertToken(M.ENTGON, "ENTGon", 18);
        _assertToken(M.USFRON, "USFRon", 18);
        _assertToken(M.EWYON, "EWYon", 18);
        _assertToken(M.SWKSON, "SWKSon", 18);
        _assertToken(M.SOFION, "SOFIon", 18);
        _assertToken(M.HYGON, "HYGon", 18);
        _assertToken(M.NVTON, "NVTon", 18);
        _assertToken(M.RDDTON, "RDDTon", 18);
        _assertToken(M.MTSION, "MTSIon", 18);
        _assertToken(M.RIVNON, "RIVNon", 18);
        _assertToken(M.LSCCON, "LSCCon", 18);
        _assertToken(M.SMCION, "SMCIon", 18);
        _assertToken(M.TLNON, "TLNon", 18);
        _assertToken(M.WCCON, "WCCon", 18);
        _assertToken(M.TSEMON, "TSEMon", 18);
        _assertToken(M.LECOON, "LECOon", 18);
        _assertToken(M.MKSION, "MKSIon", 18);
        _assertToken(M.TIPON, "TIPon", 18);
        _assertToken(M.CRCLON, "CRCLon", 18);
        _assertToken(M.MTZON, "MTZon", 18);
        _assertToken(M.IWNON, "IWNon", 18);
        _assertToken(M.GMEON, "GMEon", 18);
        _assertToken(M.SOXLON, "SOXLon", 18);
        _assertToken(M.PAVEON, "PAVEon", 18);
        _assertToken(M.FUTUON, "FUTUon", 18);
        _assertToken(M.IGVON, "IGVon", 18);
        _assertToken(M.GRABON, "GRABon", 18);
        _assertToken(M.GNRCON, "GNRCon", 18);
        _assertToken(M.FNON, "FNon", 18);
        _assertToken(M.ITAON, "ITAon", 18);
        _assertToken(M.HIION, "HIIon", 18);
        _assertToken(M.IONQON, "IONQon", 18);
        _assertToken(M.LION, "LIon", 18);
        _assertToken(M.ALBON, "ALBon", 18);
        _assertToken(M.ONTOON, "ONTOon", 18);
        _assertToken(M.PINSON, "PINSon", 18);
        _assertToken(M.NVMION, "NVMIon", 18);
        _assertToken(M.BMNRON, "BMNRon", 18);
        _assertToken(M.SNAPON, "SNAPon", 18);
        _assertToken(M.FIGON, "FIGon", 18);
        _assertToken(M.AIQON, "AIQon", 18);
        _assertToken(M.AMKRON, "AMKRon", 18);
        _assertToken(M.AALON, "AALon", 18);
        _assertToken(M.RMBSON, "RMBSon", 18);
        _assertToken(M.OSCRON, "OSCRon", 18);
        _assertToken(M.TWSTON, "TWSTon", 18);
        _assertToken(M.EWZON, "EWZon", 18);
        _assertToken(M.ASTSON, "ASTSon", 18);
        _assertToken(M.AURON, "AURon", 18);
        _assertToken(M.TTMION, "TTMIon", 18);
        _assertToken(M.HUTON, "HUTon", 18);
        _assertToken(M.VICRON, "VICRon", 18);
        _assertToken(M.INDAON, "INDAon", 18);
        _assertToken(M.CLFON, "CLFon", 18);
        _assertToken(M.NIOON, "NIOon", 18);
        _assertToken(M.RIOTON, "RIOTon", 18);
        _assertToken(M.MPON, "MPon", 18);
        _assertToken(M.FORMON, "FORMon", 18);
        _assertToken(M.IRENON, "IRENon", 18);
        _assertToken(M.WULFON, "WULFon", 18);
        _assertToken(M.FPSON, "FPSon", 18);
        _assertToken(M.FIGRON, "FIGRon", 18);
        _assertToken(M.POWLON, "POWLon", 18);
        _assertToken(M.SHLDON, "SHLDon", 18);
        _assertToken(M.AGON, "AGon", 18);
        _assertToken(M.CAION, "CAIon", 18);
        _assertToken(M.ETHAON, "ETHAon", 18);
        _assertToken(M.COPXON, "COPXon", 18);
        _assertToken(M.CORZON, "CORZon", 18);
        _assertToken(M.BILION, "BILIon", 18);
        _assertToken(M.MXLON, "MXLon", 18);
        _assertToken(M.APLDON, "APLDon", 18);
        _assertToken(M.PLON, "PLon", 18);
        _assertToken(M.KWEBON, "KWEBon", 18);
        _assertToken(M.OKLOON, "OKLOon", 18);
        _assertToken(M.URAON, "URAon", 18);
        _assertToken(M.VSHON, "VSHon", 18);
        _assertToken(M.HIMSON, "HIMSon", 18);
        _assertToken(M.AAOION, "AAOIon", 18);
        _assertToken(M.FXION, "FXIon", 18);
        _assertToken(M.PRIMON, "PRIMon", 18);
        _assertToken(M.CIFRON, "CIFRon", 18);
        _assertToken(M.ENPHON, "ENPHon", 18);
        _assertToken(M.BLSHON, "BLSHon", 18);
        _assertToken(M.QBTSON, "QBTSon", 18);
        _assertToken(M.UECON, "UECon", 18);
        _assertToken(M.RGTION, "RGTIon", 18);
        _assertToken(M.BOTZON, "BOTZon", 18);
        _assertToken(M.PENGON, "PENGon", 18);
        _assertToken(M.ONDSON, "ONDSon", 18);
        _assertToken(M.AMCON, "AMCon", 18);
        _assertToken(M.USARON, "USARon", 18);
        _assertToken(M.SOXQON, "SOXQon", 18);
        _assertToken(M.GRNDON, "GRNDon", 18);
        _assertToken(M.ACHRON, "ACHRon", 18);
        _assertToken(M.MARAON, "MARAon", 18);
        _assertToken(M.GLXYON, "GLXYon", 18);
        _assertToken(M.AXTION, "AXTIon", 18);
        _assertToken(M.OUSTON, "OUSTon", 18);
        _assertToken(M.NVTSON, "NVTSon", 18);
        _assertToken(M.USOON, "USOon", 18);
        _assertToken(M.SQQQON, "SQQQon", 18);
        _assertToken(M.RXRXON, "RXRXon", 18);
        _assertToken(M.SOXSON, "SOXSon", 18);
        _assertToken(M.LUNRON, "LUNRon", 18);
        _assertToken(M.OIHON, "OIHon", 18);
        _assertToken(M.RDWON, "RDWon", 18);
        _assertToken(M.PURRON, "PURRon", 18);
        _assertToken(M.DNNON, "DNNon", 18);
        _assertToken(M.AION, "AIon", 18);
        _assertToken(M.AEHRON, "AEHRon", 18);
        _assertToken(M.WENON, "WENon", 18);
        _assertToken(M.PPLTON, "PPLTon", 18);
        _assertToken(M.SMRON, "SMRon", 18);
        _assertToken(M.URNMON, "URNMon", 18);
        _assertToken(M.UUUUON, "UUUUon", 18);
        _assertToken(M.SOUNON, "SOUNon", 18);
        _assertToken(M.PLUGON, "PLUGon", 18);
        _assertToken(M.IGEBON, "IGEBon", 18);
        _assertToken(M.SEDGON, "SEDGon", 18);
        _assertToken(M.WOLFON, "WOLFon", 18);
        _assertToken(M.OPENON, "OPENon", 18);
        _assertToken(M.QUBTON, "QUBTon", 18);
        _assertToken(M.KEELON, "KEELon", 18);
        _assertToken(M.INODON, "INODon", 18);
        _assertToken(M.SBETON, "SBETon", 18);
        _assertToken(M.BTDRON, "BTDRon", 18);
        _assertToken(M.BBAION, "BBAIon", 18);
        _assertToken(M.BNOON, "BNOon", 18);
        _assertToken(M.PSQON, "PSQon", 18);
        _assertToken(M.CPERON, "CPERon", 18);
        _assertToken(M.FCELON, "FCELon", 18);
        _assertToken(M.FLNCON, "FLNCon", 18);
        _assertToken(M.NNEON, "NNEon", 18);
        _assertToken(M.BOTON, "BOTon", 18);
        _assertToken(M.PALLON, "PALLon", 18);
        _assertToken(M.BTGOON, "BTGOon", 18);
        _assertToken(M.LPTHON, "LPTHon", 18);
        _assertToken(M.EXODON, "EXODon", 18);
        _assertToken(M.BWETON, "BWETon", 18);
        _assertToken(M.BAION, "BAIon", 18);
        _assertToken(M.DRAMON, "DRAMon", 18);
        _assertToken(M.SATAON, "SATAon", 18);
        _assertToken(M.STRCON, "STRCon", 18);
        _assertToken(M.ANTON, "ANTon", 18);
        _assertToken(M.FF, "FF", 18);
        _assertToken(M.GNO, "GNO", 18);
        _assertToken(M.OHM, "OHM", 9);
        _assertToken(M.GRT, "GRT", 18);
        _assertToken(M.SYRUP, "SYRUP", 18);
        _assertToken(M.ENS, "ENS", 18);
        _assertToken(M.JASMY, "JASMY", 18);
        _assertToken(M.COMP, "COMP", 18);
        _assertToken(M.EIGEN, "EIGEN", 18);
        _assertToken(M.AXS, "AXS", 18);
        _assertToken(M.BAT, "BAT", 18);
        _assertToken(M.CVX, "CVX", 18);
        _assertToken(M.MANA, "MANA", 18);
        _assertToken(M.IMX, "IMX", 18);
        _assertToken(M.FLUID, "FLUID", 18);
        _assertToken(M.CHZ, "CHZ", 18);
        _assertToken(M.ZK, "ZK", 18);
        _assertToken(M.APE, "APE", 18);
        _assertToken(M.SENT, "SENT", 18);
        _assertToken(M.SNX, "SNX", 18);
        _assertToken(M.ONEINCH, "1INCH", 18);
        _assertToken(M.GLM, "GLM", 18);
        _assertToken(M.ATH, "ATH", 18);
        _assertToken(M.H, "H", 18);
        _assertToken(M.PLUME, "PLUME", 18);
        _assertToken(M.GALA, "GALA", 8);
        _assertToken(M.W, "W", 18);
        _assertToken(M.RSR, "RSR", 18);
        _assertToken(M.AVAX, "WAVAX", 18);
        _assertToken(M.AERO, "AERO", 18);
        _assertToken(M.OP, "OP", 18);
    }

    function _assertWrapped(address token, uint16 chain, bytes32 source) internal view {
        ITokenBridgeProbe bridge = ITokenBridgeProbe(M.WORMHOLE_TOKEN_BRIDGE);
        assertEq(bridge.wrappedAsset(chain, source), token, IERC20Metadata(token).symbol());
        assertTrue(bridge.isWrappedAsset(token), IERC20Metadata(token).symbol());
    }

    /// @dev Every Wormhole copy the book holds is the one the bridge deployed for its source token, by the bridge's own
    ///      registry, with the source written out here: a Solana mint (chain 1), Avalanche's WAVAX (chain 6), Base's
    ///      AERO (chain 30) and Optimism's OP (chain 24).
    function testFork_theWormholeCopiesAreTheBridges() public view {
        assertEq(M.WORMHOLE_TOKEN_BRIDGE.codehash, WORMHOLE_BRIDGE_PROXY_CODEHASH);
        _assertWrapped(M.SOL, 1, 0x069b8857feab8184fb687f634618c035dac439dc1aeb3b5598a0f00000000001); // SOL from Solana
        _assertWrapped(M.AVAX, 6, 0x000000000000000000000000b31f66aa3c1e785363f0875a1b74e27b85fd66c7); // AVAX from Avalanche
        _assertWrapped(M.AERO, 30, 0x000000000000000000000000940181a94a35a4569e4529a3cdfb74e38fd98631); // AERO from Base
        _assertWrapped(M.OP, 24, 0x0000000000000000000000004200000000000000000000000000000000000042); // OP from Optimism
    }

    /// @dev Every entry, as the listing script builds it, listed on a fresh factory, which records each token's
    ///      on-chain decimals.
    function _listOnAFreshFactory(address[] memory list) internal {
        WeightedIndexFactory factory =
            new WeightedIndexFactory(address(this), address(0), address(0), address(new WeightedMath()));
        for (uint256 i = 0; i < list.length; ++i) {
            factory.proposeListing(list[i]);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < list.length; ++i) {
            factory.executeListing(list[i]);
            assertTrue(factory.isWhitelisted(list[i]));
            assertEq(factory.decimalsOf(list[i]), IERC20Metadata(list[i]).decimals());
        }
    }

    /// @dev Every wide entry lists on a fresh factory with its token's own decimals.
    function testFork_wideWhitelistMatchesMainnet() public {
        address[] memory list = new ConfigureWeighted().wideMainnetList();
        assertEq(list.length, 411, "the 415 listed less the default four");
        _listOnAFreshFactory(list);
    }

    /// @dev XA-13, CR-I35. The zap reads the pool manager off the router, so the pinned router has to name the pool
    ///      manager the address book does, and both are pinned by their code hashes to the builds the zap was verified
    ///      against: every Universal Router build answers `poolManager()` the same way.
    function testFork_XA13_CRI35_uniswapContractsAgree() public view {
        assertEq(IRouterImmutables(M.UNIVERSAL_ROUTER).poolManager(), M.POOL_MANAGER);
        assertEq(M.UNIVERSAL_ROUTER.codehash, UNIVERSAL_ROUTER_CODEHASH, "the pinned router is the 2.0.0 build");
        assertEq(M.POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH, "and the PoolManager is the one it settles with");
    }

    /// @dev The V3 factory `CheckToken` reads depth from is Uniswap's own, by its code.
    function testFork_theV3FactoryIsUniswaps() public view {
        assertEq(M.UNISWAP_V3_FACTORY.codehash, UNISWAP_V3_FACTORY_CODEHASH);
    }

    function testFork_XA13_deployResolvesTheMainnetMarket() public {
        DeployWeighted deployer = new DeployWeighted();
        assertEq(deployer.resolveRouter(address(0)), M.UNIVERSAL_ROUTER);
        assertEq(deployer.resolveStable("USDC", address(0), M.USDC), M.USDC);
        assertEq(deployer.resolveStable("USDT", address(0), M.USDT), M.USDT);
    }

    /// @dev Every default entry, the four checked above by address, lists on a fresh factory.
    function testFork_XA13_theDefaultListMatchesMainnet() public {
        address[] memory list = new ConfigureWeighted().defaultMainnetList();
        address[4] memory four = [M.WETH, M.WBTC, M.LINK, M.UNI];
        assertEq(list.length, four.length);
        for (uint256 i = 0; i < four.length; ++i) {
            assertEq(list[i], four[i]);
        }
        _listOnAFreshFactory(list);
    }

    /// @dev The book's Pyth is Pyth's contract on Ethereum: it knows ETH/USD, and a factory built on it values WETH at
    ///      the price it stores, its confidence leaning against the executor, while that price is under a minute
    ///      old, and refuses it after. The clock is moved to the stored price's publish time: on Ethereum a price is
    ///      stored only when someone pays to post it, a filler in its own transaction.
    function testFork_aFactoryOnTheBooksPythValuesAtItsStoredPrice() public {
        IPythPrices.PriceFeed memory feed = PriceFeeds.feedOf(1, M.WETH);
        assertTrue(IPythReader(M.PYTH).priceFeedExists(feed.id), "Pyth's contract knows ETH/USD");
        IPythReader.Price memory p = IPythReader(M.PYTH).getPriceUnsafe(feed.id);
        WeightedIndexFactory factory =
            new WeightedIndexFactory(address(this), address(0), M.PYTH, address(new WeightedMath()));
        factory.proposeListing(M.WETH);
        factory.proposePriceFeed(M.WETH, feed);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(M.WETH);
        factory.executePriceFeed(M.WETH);

        IPythPrices prices = IPythPrices(factory.PRICES());
        vm.warp(p.publishTime + 60);
        uint256 price = uint256(int256(p.price));
        assertEq(prices.valueOf(M.WETH, true), (price + p.conf) * 1e28 / 1e18, "leaving: up by the confidence");
        assertEq(prices.valueOf(M.WETH, false), (price - p.conf) * 1e28 / 1e18, "arriving: down by it");
        vm.warp(p.publishTime + 61);
        vm.expectRevert(abi.encodeWithSelector(IPythPrices.StalePrice.selector, M.WETH, p.publishTime));
        prices.valueOf(M.WETH, true);
    }
}
