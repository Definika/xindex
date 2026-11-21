// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {ConfigureWeighted} from "../../script/ConfigureWeighted.s.sol";
import {DeployWeighted} from "../../script/DeployWeighted.s.sol";
import {DeployChecks} from "../../script/DeployChecks.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";

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
    /// @dev EIP-1967's admin and implementation slots, and Backed's wrapped-xStock proxies' values in them, read on
    ///      2026-11-21: every wrapper and every xStock under one ProxyAdmin each, on one implementation each.
    bytes32 constant EIP1967_ADMIN = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 constant EIP1967_IMPLEMENTATION = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address constant WRAPPER_PROXY_ADMIN = 0xE39FfFFfB0795c99869ba4bCFE3fD1759d2f0Cc7;
    address constant WRAPPER_IMPLEMENTATION = 0x14f37168AB9eAFCD94d5b142a00E6e9B261Bad48;
    address constant XSTOCK_PROXY_ADMIN = 0x696C685a02A1Fc6E2AaCbe26CD6695F4f4a6a085;
    /// @dev `BackedAutoFeeTokenImplementation` in its fourth version, which records every multiplier update, and the
    ///      one before it, which does not; burns and multipliers work alike in both.
    address constant XSTOCK_IMPLEMENTATION = 0x65c40D624Af3B18C109fBF87B7DEff34CdC5f19b;
    address constant XSTOCK_IMPLEMENTATION_V3 = 0xd865Ce1B07540b5edE20e8298f48da69770Fe22e;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        // FORK_BLOCK overrides the pin, for a non-archive RPC that only serves recent state. Forge loads .env
        // automatically, so a MAINNET_RPC_URL set there makes a plain `forge test` run these suites too.
        uint256 forkBlock = vm.envOr("FORK_BLOCK", A.FORK_BLOCK);
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
        _assertToken(M.XRP, "XRP", 18);
        _assertToken(M.ADA, "ADA", 18);
        _assertToken(M.LTC, "LTC", 18);
        _assertToken(M.AVAX, "WAVAX", 18);
        _assertToken(M.DOT, "DOT", 18);
        _assertToken(M.JUP, "JUP", 6);
        _assertToken(M.ALGO, "ALGO", 6);
        _assertToken(M.ATOM, "ATOM", 18);
        _assertToken(M.AERO, "AERO", 18);
        _assertToken(M.APT, "APT", 8);
        _assertToken(M.PYTH_TOKEN, "PYTH", 6);
        _assertToken(M.OP, "OP", 18);
        _assertToken(M.BNB, "WBNB", 18);
        _assertToken(M.SUI, "SUI", 9);
        _assertToken(M.WAAPLX, "wAAPLx", 18);
        _assertToken(M.WABBVX, "wABBVx", 18);
        _assertToken(M.WABTX, "wABTx", 18);
        _assertToken(M.WACNX, "wACNx", 18);
        _assertToken(M.WADBEX, "wADBEx", 18);
        _assertToken(M.WAMDX, "wAMDx", 18);
        _assertToken(M.WAMZNX, "wAMZNx", 18);
        _assertToken(M.WAPPX, "wAPPx", 18);
        _assertToken(M.WASMLX, "wASMLx", 18);
        _assertToken(M.WASTSX, "wASTSx", 18);
        _assertToken(M.WAVGOX, "wAVGOx", 18);
        _assertToken(M.WAXPX, "wAXPx", 18);
        _assertToken(M.WAZNX, "wAZNx", 18);
        _assertToken(M.WBACX, "wBACx", 18);
        _assertToken(M.WBKNGX, "wBKNGx", 18);
        _assertToken(M.WBLKX, "wBLKx", 18);
        _assertToken(M.WBLSHX, "wBLSHx", 18);
        _assertToken(M.WBMNRX, "wBMNRx", 18);
        _assertToken(M.WBRKBX, "wBRK.Bx", 18);
        _assertToken(M.WBTBTX, "wBTBTx", 18);
        _assertToken(M.WCLSKX, "wCLSKx", 18);
        _assertToken(M.WCMCSAX, "wCMCSAx", 18);
        _assertToken(M.WCOINX, "wCOINx", 18);
        _assertToken(M.WCORZX, "wCORZx", 18);
        _assertToken(M.WCOSTX, "wCOSTx", 18);
        _assertToken(M.WCRCLX, "wCRCLx", 18);
        _assertToken(M.WCRMX, "wCRMx", 18);
        _assertToken(M.WCRWDX, "wCRWDx", 18);
        _assertToken(M.WCSCOX, "wCSCOx", 18);
        _assertToken(M.WCVXX, "wCVXx", 18);
        _assertToken(M.WDHRX, "wDHRx", 18);
        _assertToken(M.WEBAYX, "wEBAYx", 18);
        _assertToken(M.WEXPEX, "wEXPEx", 18);
        _assertToken(M.WFIGX, "wFIGx", 18);
        _assertToken(M.WGLDX, "wGLDx", 18);
        _assertToken(M.WGLXYX, "wGLXYx", 18);
        _assertToken(M.WGMEX, "wGMEx", 18);
        _assertToken(M.WGOOGLX, "wGOOGLx", 18);
        _assertToken(M.WGSX, "wGSx", 18);
        _assertToken(M.WHDX, "wHDx", 18);
        _assertToken(M.WHONX, "wHONx", 18);
        _assertToken(M.WHOODX, "wHOODx", 18);
        _assertToken(M.WHSDTX, "wHSDTx", 18);
        _assertToken(M.WHUTX, "wHUTx", 18);
        _assertToken(M.WIBMX, "wIBMx", 18);
        _assertToken(M.WIEMGX, "wIEMGx", 18);
        _assertToken(M.WIJRX, "wIJRx", 18);
        _assertToken(M.WINTCX, "wINTCx", 18);
        _assertToken(M.WIWMX, "wIWMx", 18);
        _assertToken(M.WJNJX, "wJNJx", 18);
        _assertToken(M.WJPMX, "wJPMx", 18);
        _assertToken(M.WKOX, "wKOx", 18);
        _assertToken(M.WLINX, "wLINx", 18);
        _assertToken(M.WLLYX, "wLLYx", 18);
        _assertToken(M.WLULUX, "wLULUx", 18);
        _assertToken(M.WMAX, "wMAx", 18);
        _assertToken(M.WMARAX, "wMARAx", 18);
        _assertToken(M.WMCDX, "wMCDx", 18);
        _assertToken(M.WMDTX, "wMDTx", 18);
        _assertToken(M.WMETAX, "wMETAx", 18);
        _assertToken(M.WMNSTX, "wMNSTx", 18);
        _assertToken(M.WMRKX, "wMRKx", 18);
        _assertToken(M.WMRVLX, "wMRVLx", 18);
        _assertToken(M.WMSFTX, "wMSFTx", 18);
        _assertToken(M.WMSTRX, "wMSTRx", 18);
        _assertToken(M.WMUX, "wMUx", 18);
        _assertToken(M.WNFLXX, "wNFLXx", 18);
        _assertToken(M.WNVDAX, "wNVDAx", 18);
        _assertToken(M.WNVOX, "wNVOx", 18);
        _assertToken(M.WOKLOX, "wOKLOx", 18);
        _assertToken(M.WOPENX, "wOPENx", 18);
        _assertToken(M.WORCLX, "wORCLx", 18);
        _assertToken(M.WPANWX, "wPANWx", 18);
        _assertToken(M.WPEPX, "wPEPx", 18);
        _assertToken(M.WPFEX, "wPFEx", 18);
        _assertToken(M.WPGX, "wPGx", 18);
        _assertToken(M.WPLX, "wPLx", 18);
        _assertToken(M.WPLTRX, "wPLTRx", 18);
        _assertToken(M.WPMX, "wPMx", 18);
        _assertToken(M.WPYPLX, "wPYPLx", 18);
        _assertToken(M.WQQQX, "wQQQx", 18);
        _assertToken(M.WRBLXX, "wRBLXx", 18);
        _assertToken(M.WRIOTX, "wRIOTx", 18);
        _assertToken(M.WRKLBX, "wRKLBx", 18);
        _assertToken(M.WSBETX, "wSBETx", 18);
        _assertToken(M.WSCHFX, "wSCHFx", 18);
        _assertToken(M.WSLVX, "wSLVx", 18);
        _assertToken(M.WSPCEX, "wSPCEx", 18);
        _assertToken(M.WSPGIX, "wSPGIx", 18);
        _assertToken(M.WSPYX, "wSPYx", 18);
        _assertToken(M.WSTRCX, "wSTRCx", 18);
        _assertToken(M.WTX, "wTx", 18);
        _assertToken(M.WTEMX, "wTEMx", 18);
        _assertToken(M.WTGTX, "wTGTx", 18);
        _assertToken(M.WTMOX, "wTMOx", 18);
        _assertToken(M.WTMUSX, "wTMUSx", 18);
        _assertToken(M.WTQQQX, "wTQQQx", 18);
        _assertToken(M.WTSLAX, "wTSLAx", 18);
        _assertToken(M.WTSMX, "wTSMx", 18);
        _assertToken(M.WUBERX, "wUBERx", 18);
        _assertToken(M.WUNHX, "wUNHx", 18);
        _assertToken(M.WVX, "wVx", 18);
        _assertToken(M.WVSTX, "wVSTx", 18);
        _assertToken(M.WVTX, "wVTx", 18);
        _assertToken(M.WVTIX, "wVTIx", 18);
        _assertToken(M.WWENX, "wWENx", 18);
        _assertToken(M.WWMTX, "wWMTx", 18);
        _assertToken(M.WWULFX, "wWULFx", 18);
        _assertToken(M.WXOMX, "wXOMx", 18);
    }

    function _assertWrapped(address token, uint16 chain, bytes32 source) internal view {
        ITokenBridgeProbe bridge = ITokenBridgeProbe(M.WORMHOLE_TOKEN_BRIDGE);
        assertEq(bridge.wrappedAsset(chain, source), token, IERC20Metadata(token).symbol());
        assertTrue(bridge.isWrappedAsset(token), IERC20Metadata(token).symbol());
    }

    /// @dev Every Wormhole copy on the list is the one the bridge deployed for its source token, by the bridge's own
    ///      registry, with the source written out here: a Binance-Peg BEP-20's address on BNB Chain (Wormhole chain
    ///      4), a Solana mint (chain 1), Avalanche's WAVAX (chain 6), Algorand's ALGO (chain 8, asset 0), Aptos's APT
    ///      (chain 22, the hash of its coin type), Base's AERO (chain 30), Optimism's OP (chain 24), BNB Chain's WBNB
    ///      (chain 4), Sui's SUI (chain 21, its CoinMetadata object) and Sei's usei (chain 32, its keccak256 with the
    ///      first byte set to 1).
    function testFork_theWormholeCopiesAreTheBridges() public view {
        assertEq(M.WORMHOLE_TOKEN_BRIDGE.codehash, WORMHOLE_BRIDGE_PROXY_CODEHASH);
        _assertWrapped(M.SOL, 1, 0x069b8857feab8184fb687f634618c035dac439dc1aeb3b5598a0f00000000001); // SOL from Solana
        _assertWrapped(M.XRP, 4, 0x0000000000000000000000001d2f0da169ceb9fc7b3144628db156f3f6c60dbe); // XRP from BNB Chain
        _assertWrapped(M.ADA, 4, 0x0000000000000000000000003ee2200efb3400fabb9aacf31297cbdd1d435d47); // ADA from BNB Chain
        _assertWrapped(M.LTC, 4, 0x0000000000000000000000004338665cbb7b2485a8855a139b75d5e34ab0db94); // LTC from BNB Chain
        _assertWrapped(M.AVAX, 6, 0x000000000000000000000000b31f66aa3c1e785363f0875a1b74e27b85fd66c7); // AVAX from Avalanche
        _assertWrapped(M.DOT, 4, 0x0000000000000000000000007083609fce4d1d8dc0c979aab8c869ea2c873402); // DOT from BNB Chain
        _assertWrapped(M.JUP, 1, 0x0479d9c7cc1035de7211f99eb48c09d70b2bdf5bdf9e2e56b8a1fbb5a2ea3327); // JUP from Solana
        _assertWrapped(M.ALGO, 8, 0x0000000000000000000000000000000000000000000000000000000000000000); // ALGO from Algorand
        _assertWrapped(M.ATOM, 4, 0x0000000000000000000000000eb3a705fc54725037cc9e008bdede697f62f335); // ATOM from BNB Chain
        _assertWrapped(M.AERO, 30, 0x000000000000000000000000940181a94a35a4569e4529a3cdfb74e38fd98631); // AERO from Base
        _assertWrapped(M.APT, 22, 0xa867703f5395cb2965feb7ebff5cdf39b771fc6156085da3ae4147a00be91b38); // APT from Aptos
        _assertWrapped(M.PYTH_TOKEN, 1, 0xf5edec8471c75624ebc4079a634326d96a689e6157d79abe8f5a6f94472853bc); // PYTH from Solana
        _assertWrapped(M.OP, 24, 0x0000000000000000000000004200000000000000000000000000000000000042); // OP from Optimism
        _assertWrapped(M.BNB, 4, 0x000000000000000000000000bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c); // WBNB from BNB Chain
        _assertWrapped(M.SUI, 21, 0x9258181f5ceac8dbffb7030890243caed69a9599d2886d957a9cb7656af3bdb3); // SUI from Sui
    }

    /// @dev Each wrapped xStock is Backed's ERC-4626 vault over the xStock written out here, both proxies under the
    ///      admins and implementations read on 2026-11-21 (`MainnetAddresses`' wrapped-xStock section): an upgrade of
    ///      either fails this test until its new code has been read.
    function _assertWrappedXStock(address wrapper, address xStock, string memory xSymbol) internal view {
        assertEq(IERC4626(wrapper).asset(), xStock, "the wrapper's xStock");
        assertEq(IERC20Metadata(xStock).symbol(), xSymbol);
        assertEq(IERC20Metadata(xStock).decimals(), 18);
        assertEq(address(uint160(uint256(vm.load(wrapper, EIP1967_ADMIN)))), WRAPPER_PROXY_ADMIN, "wrapper admin");
        assertEq(address(uint160(uint256(vm.load(wrapper, EIP1967_IMPLEMENTATION)))), WRAPPER_IMPLEMENTATION);
        assertEq(address(uint160(uint256(vm.load(xStock, EIP1967_ADMIN)))), XSTOCK_PROXY_ADMIN, "xStock admin");
        address implementation = address(uint160(uint256(vm.load(xStock, EIP1967_IMPLEMENTATION))));
        assertTrue(implementation == XSTOCK_IMPLEMENTATION || implementation == XSTOCK_IMPLEMENTATION_V3, "xStock code");
    }

    function testFork_theWrappedXStocksAreBackeds() public view {
        _assertWrappedXStock(M.WAAPLX, 0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a, "AAPLx");
        _assertWrappedXStock(M.WABBVX, 0xfBF2398dF672cEE4aFcC2A4A733222331c742a6A, "ABBVx");
        _assertWrappedXStock(M.WABTX, 0x89233399708C18Ac6887F90A2B4Cd8Ba5fEdD06e, "ABTx");
        _assertWrappedXStock(M.WACNX, 0x03183Ce31b1656B72A55fa6056e287f50C35BbEB, "ACNx");
        _assertWrappedXStock(M.WADBEX, 0x16E0B579be45bAaE54cEddd52e742B6457A7fE12, "ADBEx");
        _assertWrappedXStock(M.WAMDX, 0x3522513E5F146a2006e2901b05f16B2821485E19, "AMDx");
        _assertWrappedXStock(M.WAMZNX, 0x3557Ba345B01EFa20A1bdDC61F573BFD87195081, "AMZNx");
        _assertWrappedXStock(M.WAPPX, 0x50a1291F69D9d3853Def8209cFb1AF0b46927BE1, "APPx");
        _assertWrappedXStock(M.WASMLX, 0xC0B417e7F83db438631Eb5E096684dd742E5294F, "ASMLx");
        _assertWrappedXStock(M.WASTSX, 0x89b2607878ae19baB8020b8140eD550Ef3E953bb, "ASTSx");
        _assertWrappedXStock(M.WAVGOX, 0x38BAC69cbBd28156796e4163B2B6dcb81E336565, "AVGOx");
        _assertWrappedXStock(M.WAXPX, 0xb23767492D0Ca6dC7221CBeA45689a0410f388c4, "AXPx");
        _assertWrappedXStock(M.WAZNX, 0x5D642505FE1a28897eb3BaBA665F454755D8daA2, "AZNx");
        _assertWrappedXStock(M.WBACX, 0x314938c596F5ce31C3f75307d2979338C346D7F2, "BACx");
        _assertWrappedXStock(M.WBKNGX, 0xa8A25DB6Cf17Fa097f1DBbc9c841892456898fF3, "BKNGx");
        _assertWrappedXStock(M.WBLKX, 0x5A6a0742cA689E7E8a91A38F5255589CB2191646, "BLKx");
        _assertWrappedXStock(M.WBLSHX, 0x38DE7b9FC733DeF81525E65C1Bf99722026489e2, "BLSHx");
        _assertWrappedXStock(M.WBMNRX, 0xaeB681B69E5094E04d11BCeF51A71358A374C3ED, "BMNRx");
        _assertWrappedXStock(M.WBRKBX, 0x12992613fDd35aBe95DEc5a4964331b1ee23B50d, "BRK.Bx");
        _assertWrappedXStock(M.WBTBTX, 0x22E1991e5f82736A2a990322a46aac0e95826c5B, "BTBTx");
        _assertWrappedXStock(M.WCLSKX, 0xD0194F0f077968DA8ca59811e9407f54AE6c9432, "CLSKx");
        _assertWrappedXStock(M.WCMCSAX, 0xBC7170a1280Be28513B4e940C681537EB25e39f4, "CMCSAx");
        _assertWrappedXStock(M.WCOINX, 0x364f210f430eC2448Fc68A49203040F6124096F0, "COINx");
        _assertWrappedXStock(M.WCORZX, 0x51eD5b74A05F256DbD9Ebb4e4f68Bb41ba10160b, "CORZx");
        _assertWrappedXStock(M.WCOSTX, 0x4720B5e6421e6879132aED52040d56Bb6e5CFeeF, "COSTx");
        _assertWrappedXStock(M.WCRCLX, 0xfEbDEd1B0986a8ee107f5AB1a1c5a813491DeCEB, "CRCLx");
        _assertWrappedXStock(M.WCRMX, 0x4A4073f2EAF299A1be22254DCD2C41727F6F54a2, "CRMx");
        _assertWrappedXStock(M.WCRWDX, 0x214151022C2a5E380aB80CdaC31f23Ae554a7345, "CRWDx");
        _assertWrappedXStock(M.WCSCOX, 0x053C784cD87B74f42e0c089f98643E79c1A3ff16, "CSCOx");
        _assertWrappedXStock(M.WCVXX, 0xad5cdc3340904285B8159089974A99a1A09EB4C0, "CVXx");
        _assertWrappedXStock(M.WDHRX, 0xdbA228936F4079DaF9Aa906fd48a87f2300405F4, "DHRx");
        _assertWrappedXStock(M.WEBAYX, 0x4c7610990cb63cdca174ce61822F7693B49FCe93, "EBAYx");
        _assertWrappedXStock(M.WEXPEX, 0xd1be5bA0c293997C7F69da707D14EB4ABCB13ddD, "EXPEx");
        _assertWrappedXStock(M.WFIGX, 0x3C313D234D0C6C876F6c21ba2EC1F26823247Be2, "FIGx");
        _assertWrappedXStock(M.WGLDX, 0x2380F2673C640fB67E2d6B55B44C62F0E0e69DA9, "GLDx");
        _assertWrappedXStock(M.WGLXYX, 0xf7F4fAC56f012dE7Dd6adFF54C761986B9E0655a, "GLXYx");
        _assertWrappedXStock(M.WGMEX, 0xE5f6d3b2405ABdfE6F660e63202B25D23763160d, "GMEx");
        _assertWrappedXStock(M.WGOOGLX, 0xe92f673Ca36C5E2Efd2DE7628f815f84807e803F, "GOOGLx");
        _assertWrappedXStock(M.WGSX, 0x3Ee7E9B3A992fD23CD1C363B0e296856B04ab149, "GSx");
        _assertWrappedXStock(M.WHDX, 0x766b0CD6ED6D90B5d49d2c36a3761E9728501BA9, "HDx");
        _assertWrappedXStock(M.WHONX, 0x62a48560861B0b451654bFffdb5be6E47aa8ff1B, "HONx");
        _assertWrappedXStock(M.WHOODX, 0xE1385FDd5ffB10081Cd52C56584F25EFa9084015, "HOODx");
        _assertWrappedXStock(M.WHSDTX, 0xd457b379801433EA5c3A8542b61902023AE39DcD, "HSDTx");
        _assertWrappedXStock(M.WHUTX, 0x560deb3D70Ac90064fF809349cDf9A771a06fd36, "HUTx");
        _assertWrappedXStock(M.WIBMX, 0xd9913208647671Fe0F48F7F260076B2C6F310Aac, "IBMx");
        _assertWrappedXStock(M.WIEMGX, 0x6a668332825450ACD2e449372057d31b3de16a1E, "IEMGx");
        _assertWrappedXStock(M.WIJRX, 0xAA28cB97D7f7E172f54deE950743886D2d65447d, "IJRx");
        _assertWrappedXStock(M.WINTCX, 0xf8A80D1cb9cFD70D03D655D9dF42339846F3B3C8, "INTCx");
        _assertWrappedXStock(M.WIWMX, 0xdadfb355c6110eda0908740d52c834d6C2BCDDc7, "IWMx");
        _assertWrappedXStock(M.WJNJX, 0xdb0482cfaD4789798623E64b15eebA01b16e917C, "JNJx");
        _assertWrappedXStock(M.WJPMX, 0xD9FC3E075d45254a1D834fEa18AF8041207DeA0A, "JPMx");
        _assertWrappedXStock(M.WKOX, 0xdCC1a2699441079dA889B1F49e12B69cC791129b, "KOx");
        _assertWrappedXStock(M.WLINX, 0x15059c599C16Fd8f70B633Ade165502D6402CD49, "LINx");
        _assertWrappedXStock(M.WLLYX, 0x19c41EA77b34BbDEe61c3A87A75D1ABDA2ED0be4, "LLYx");
        _assertWrappedXStock(M.WLULUX, 0x847dEB9c78fb00319bC7A006dFF729c11428E537, "LULUx");
        _assertWrappedXStock(M.WMAX, 0xb365Cd2588065F522D379AD19e903304f6B622C6, "MAx");
        _assertWrappedXStock(M.WMARAX, 0x9D692bffEf6f6BedF4274053ff9998EFE3B2539E, "MARAx");
        _assertWrappedXStock(M.WMCDX, 0x80A77a372c1e12AcCdA84299492f404902E2DA67, "MCDx");
        _assertWrappedXStock(M.WMDTX, 0x0588e851ec0418d660BeE81230d6c678dAF21d46, "MDTx");
        _assertWrappedXStock(M.WMETAX, 0x96702be57Cd9777f835117a809C7124fe4ec989A, "METAx");
        _assertWrappedXStock(M.WMNSTX, 0x8499b26BBfC8c3830a37b92E47DF2d7cBc0154e9, "MNSTx");
        _assertWrappedXStock(M.WMRKX, 0x17D8186Ed8F68059124190D147174D0f6697dc40, "MRKx");
        _assertWrappedXStock(M.WMRVLX, 0xeAAd46F4146Ded5a47B55AA7F6c48c191dEAEC88, "MRVLx");
        _assertWrappedXStock(M.WMSFTX, 0x5621737f42dAE558b81269FcB9E9E70c19Aa6b35, "MSFTx");
        _assertWrappedXStock(M.WMSTRX, 0xAE2f842EF90C0d5213259Ab82639D5BBF649b08E, "MSTRx");
        _assertWrappedXStock(M.WMUX, 0xf6a873BAe4Ba1B304e45dF52A4b7D176E1C6a8c4, "MUx");
        _assertWrappedXStock(M.WNFLXX, 0xA6a65AC27E76cD53cB790473E4345c46e5eBf961, "NFLXx");
        _assertWrappedXStock(M.WNVDAX, 0xc845b2894dBddd03858fd2D643B4eF725fE0849d, "NVDAx");
        _assertWrappedXStock(M.WNVOX, 0xF9523E369c5f55ad72DbAA75B0a9b92B3D8b147e, "NVOx");
        _assertWrappedXStock(M.WOKLOX, 0x4b0eE7C047D43cA403239f28f42115bEdB7c0076, "OKLOx");
        _assertWrappedXStock(M.WOPENX, 0xbEe6b69345F376598Fe16AbD5592c6F844825E66, "OPENx");
        _assertWrappedXStock(M.WORCLX, 0x548308E91ec9F285C7bFf05295baDBD56a6e4971, "ORCLx");
        _assertWrappedXStock(M.WPANWX, 0xe12BB32D77BE4DB10DDC82088b230D35d097E9C5, "PANWx");
        _assertWrappedXStock(M.WPEPX, 0x36c424a6EC0e264b1616102Ad63eD2aD7857413e, "PEPx");
        _assertWrappedXStock(M.WPFEX, 0x1Ac765B5BEa23184802C7d2d497f7c33f1444A9e, "PFEx");
        _assertWrappedXStock(M.WPGX, 0xa90424D5D3E770e8644103AB503ed775dD1318FD, "PGx");
        _assertWrappedXStock(M.WPLX, 0x536825370F1159cBA953055f5c2F16DDc7B5a348, "PLx");
        _assertWrappedXStock(M.WPLTRX, 0x6d482CeC5f9dd1f05CCee9Fd3ff79B246170F8e2, "PLTRx");
        _assertWrappedXStock(M.WPMX, 0x02a6c1789c3B4FDb1a7a3DfA39F90e5d3c94F4F9, "PMx");
        _assertWrappedXStock(M.WPYPLX, 0xf706585e7e8900bE0267bEE3B9A2F70835EC6628, "PYPLx");
        _assertWrappedXStock(M.WQQQX, 0xa753A7395cAe905Cd615Da0B82A53E0560f250af, "QQQx");
        _assertWrappedXStock(M.WRBLXX, 0x5d8dA1417E3565eb02C9ca8cC588bE5D8F65b1c5, "RBLXx");
        _assertWrappedXStock(M.WRIOTX, 0x6Ac47387f0a2798dF4C4eE5bb31ab9517ac97cb8, "RIOTx");
        _assertWrappedXStock(M.WRKLBX, 0xE17ce7dD2afb6Da3488fD9ef2558523D569e17B4, "RKLBx");
        _assertWrappedXStock(M.WSBETX, 0x338791c58fdED314b81EAb139A1A2Fb7967D90d6, "SBETx");
        _assertWrappedXStock(M.WSCHFX, 0xF6D87E523512704C29E9b7cA3e9e6226bDCE3EA1, "SCHFx");
        _assertWrappedXStock(M.WSLVX, 0x4833e7f4f0460f4B72A3a5879A6C9841bCC5B58B, "SLVx");
        _assertWrappedXStock(M.WSPCEX, 0x7F8ba411ECBC0A135d669d5EaE5D15b0Ca0b0ea1, "SPCEx");
        _assertWrappedXStock(M.WSPGIX, 0xD3c5Af6B2F0F754b2141f368cFc5ea99C3594d3a, "SPGIx");
        _assertWrappedXStock(M.WSPYX, 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48, "SPYx");
        _assertWrappedXStock(M.WSTRCX, 0x1Aad217B8F78dbA5E6693460e8470F8b1A3977f3, "STRCx");
        _assertWrappedXStock(M.WTX, 0x75639aE3A05079873D7189DcbDBc455898cAe904, "Tx");
        _assertWrappedXStock(M.WTEMX, 0x61AeE4f4e6B62806c26eafF921e7F41782cA2E03, "TEMx");
        _assertWrappedXStock(M.WTGTX, 0xAB6a44AD34D083f463fa6F64d0619F11eB2cb48D, "TGTx");
        _assertWrappedXStock(M.WTMOX, 0xAF072F109A2C173D822a4fe9af311A1B18F83d19, "TMOx");
        _assertWrappedXStock(M.WTMUSX, 0x68F3DDEE8BAE33691E7CD0372984fD857E842760, "TMUSx");
        _assertWrappedXStock(M.WTQQQX, 0xfDDDb57878eF9D6f681Ec4381DCB626b9E69AC86, "TQQQx");
        _assertWrappedXStock(M.WTSLAX, 0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0, "TSLAx");
        _assertWrappedXStock(M.WTSMX, 0x9e3bf4Ecfc44EeDD624F26656B6736a3F093b073, "TSMx");
        _assertWrappedXStock(M.WUBERX, 0xdb9783Ca04bBD64fe2c6d7B9503A979b3DE30729, "UBERx");
        _assertWrappedXStock(M.WUNHX, 0x167A6375DA1eFc4a5BE0f470E73eCEfd66245048, "UNHx");
        _assertWrappedXStock(M.WVX, 0x2363FD1235C1B6d3A5088DdF8dF3A0b3A30C5293, "Vx");
        _assertWrappedXStock(M.WVSTX, 0x7AB6C97f65e4227adc5090Bd31a376D1F36f39fa, "VSTx");
        _assertWrappedXStock(M.WVTX, 0x6d5edEEbBc6A4099Eb8bb289EB3b80D799f7b28C, "VTx");
        _assertWrappedXStock(M.WVTIX, 0xbD730E618bcD88C82dDeE52e10275CF2f88A4777, "VTIx");
        _assertWrappedXStock(M.WWENX, 0xfEEE18422F8F1cD6193C12aAfad7123DbfF15517, "WENx");
        _assertWrappedXStock(M.WWMTX, 0x7AEfc9965699fBea943e03264d96e50CD4A97b21, "WMTx");
        _assertWrappedXStock(M.WWULFX, 0xC0c2150cf0870E2d7aBc7cDe17C20A542faFBB9B, "WULFx");
        _assertWrappedXStock(M.WXOMX, 0xEEdb0273c5Af792745180e9fF568cD01550fFA13, "XOMx");
    }

    /// @dev Every entry, as the listing script builds it, listed on a fresh factory, which records each token's
    ///      on-chain decimals.
    function _listOnAFreshFactory(address[] memory list) internal {
        WeightedIndexFactory factory = new WeightedIndexFactory(address(this), address(0));
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
        assertEq(list.length, 167, "the 171 listed less the default four");
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
}
