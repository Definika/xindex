// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {CheckToken} from "../../script/CheckToken.s.sol";
import {ConfigureWeighted} from "../../script/ConfigureWeighted.s.sol";
import {DeployWeighted} from "../../script/DeployWeighted.s.sol";
import {DeployChecks} from "../../script/DeployChecks.sol";
import {Listings} from "../../script/Listings.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {BnbChainAddresses as B} from "../../script/BnbChainAddresses.sol";

interface IOwned {
    function owner() external view returns (address);
}

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
    ///      The suite passed whole here on 2026-11-21, its wrapped xStocks included; at the pin before it,
    ///      133,361,996 of 2026-11-13, no public node could show that every wrapper had been deployed.
    uint256 constant FORK_BLOCK = 134_768_771;
    /// @dev EIP-1967's admin and implementation slots, and Backed's wrapped-xStock proxies' values in them, read on
    ///      2026-11-21: the same contracts as on Ethereum (`test/fork/MainnetAddresses.fork.t.sol`), and every wrapper
    ///      here owned by the Safe that owns every xStock.
    bytes32 constant EIP1967_ADMIN = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 constant EIP1967_IMPLEMENTATION = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address constant WRAPPER_PROXY_ADMIN = 0xE39FfFFfB0795c99869ba4bCFE3fD1759d2f0Cc7;
    address constant WRAPPER_IMPLEMENTATION = 0x14f37168AB9eAFCD94d5b142a00E6e9B261Bad48;
    address constant XSTOCK_PROXY_ADMIN = 0x696C685a02A1Fc6E2AaCbe26CD6695F4f4a6a085;
    address constant XSTOCK_IMPLEMENTATION = 0x65c40D624Af3B18C109fBF87B7DEff34CdC5f19b;
    address constant XSTOCK_IMPLEMENTATION_V3 = 0xd865Ce1B07540b5edE20e8298f48da69770Fe22e;
    address constant BACKED_SAFE = 0x49754062E35f7591B93cc4F9915965be89643a65;

    uint24 constant F500 = 500;

    // 0.01 BNB + 0.0001 BTCB + 0.001 ETH per index token
    uint256 constant U_WBNB = 1e16;
    uint256 constant U_BTCB = 1e14;
    uint256 constant U_ETH = 1e15;

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
        _assertToken(B.USDT, "USDT", 18);
        _assertToken(B.USDC, "USDC", 18);
        _assertToken(B.WAAPLX, "wAAPLx", 18);
        _assertToken(B.WABBVX, "wABBVx", 18);
        _assertToken(B.WABTX, "wABTx", 18);
        _assertToken(B.WACNX, "wACNx", 18);
        _assertToken(B.WADBEX, "wADBEx", 18);
        _assertToken(B.WAMZNX, "wAMZNx", 18);
        _assertToken(B.WAPPX, "wAPPx", 18);
        _assertToken(B.WASMLX, "wASMLx", 18);
        _assertToken(B.WASTSX, "wASTSx", 18);
        _assertToken(B.WAVGOX, "wAVGOx", 18);
        _assertToken(B.WAXPX, "wAXPx", 18);
        _assertToken(B.WAZNX, "wAZNx", 18);
        _assertToken(B.WBACX, "wBACx", 18);
        _assertToken(B.WBKNGX, "wBKNGx", 18);
        _assertToken(B.WBLKX, "wBLKx", 18);
        _assertToken(B.WBLSHX, "wBLSHx", 18);
        _assertToken(B.WBMNRX, "wBMNRx", 18);
        _assertToken(B.WBRKBX, "wBRK.Bx", 18);
        _assertToken(B.WBTBTX, "wBTBTx", 18);
        _assertToken(B.WCLSKX, "wCLSKx", 18);
        _assertToken(B.WCMCSAX, "wCMCSAx", 18);
        _assertToken(B.WCOINX, "wCOINx", 18);
        _assertToken(B.WCORZX, "wCORZx", 18);
        _assertToken(B.WCOSTX, "wCOSTx", 18);
        _assertToken(B.WCRCLX, "wCRCLx", 18);
        _assertToken(B.WCRMX, "wCRMx", 18);
        _assertToken(B.WCRWDX, "wCRWDx", 18);
        _assertToken(B.WCSCOX, "wCSCOx", 18);
        _assertToken(B.WCVXX, "wCVXx", 18);
        _assertToken(B.WDHRX, "wDHRx", 18);
        _assertToken(B.WEBAYX, "wEBAYx", 18);
        _assertToken(B.WEXPEX, "wEXPEx", 18);
        _assertToken(B.WFIGX, "wFIGx", 18);
        _assertToken(B.WGLDX, "wGLDx", 18);
        _assertToken(B.WGLXYX, "wGLXYx", 18);
        _assertToken(B.WGMEX, "wGMEx", 18);
        _assertToken(B.WGOOGLX, "wGOOGLx", 18);
        _assertToken(B.WGSX, "wGSx", 18);
        _assertToken(B.WHDX, "wHDx", 18);
        _assertToken(B.WHONX, "wHONx", 18);
        _assertToken(B.WHOODX, "wHOODx", 18);
        _assertToken(B.WHSDTX, "wHSDTx", 18);
        _assertToken(B.WHUTX, "wHUTx", 18);
        _assertToken(B.WIBMX, "wIBMx", 18);
        _assertToken(B.WIEMGX, "wIEMGx", 18);
        _assertToken(B.WIJRX, "wIJRx", 18);
        _assertToken(B.WINTCX, "wINTCx", 18);
        _assertToken(B.WIWMX, "wIWMx", 18);
        _assertToken(B.WJNJX, "wJNJx", 18);
        _assertToken(B.WJPMX, "wJPMx", 18);
        _assertToken(B.WKOX, "wKOx", 18);
        _assertToken(B.WLINX, "wLINx", 18);
        _assertToken(B.WLLYX, "wLLYx", 18);
        _assertToken(B.WLULUX, "wLULUx", 18);
        _assertToken(B.WMAX, "wMAx", 18);
        _assertToken(B.WMCDX, "wMCDx", 18);
        _assertToken(B.WMDTX, "wMDTx", 18);
        _assertToken(B.WMETAX, "wMETAx", 18);
        _assertToken(B.WMNSTX, "wMNSTx", 18);
        _assertToken(B.WMRKX, "wMRKx", 18);
        _assertToken(B.WMRVLX, "wMRVLx", 18);
        _assertToken(B.WMSFTX, "wMSFTx", 18);
        _assertToken(B.WMSTRX, "wMSTRx", 18);
        _assertToken(B.WMUX, "wMUx", 18);
        _assertToken(B.WNFLXX, "wNFLXx", 18);
        _assertToken(B.WNVDAX, "wNVDAx", 18);
        _assertToken(B.WNVOX, "wNVOx", 18);
        _assertToken(B.WOPENX, "wOPENx", 18);
        _assertToken(B.WORCLX, "wORCLx", 18);
        _assertToken(B.WPANWX, "wPANWx", 18);
        _assertToken(B.WPEPX, "wPEPx", 18);
        _assertToken(B.WPFEX, "wPFEx", 18);
        _assertToken(B.WPGX, "wPGx", 18);
        _assertToken(B.WPLX, "wPLx", 18);
        _assertToken(B.WPLTRX, "wPLTRx", 18);
        _assertToken(B.WPMX, "wPMx", 18);
        _assertToken(B.WPYPLX, "wPYPLx", 18);
        _assertToken(B.WQQQX, "wQQQx", 18);
        _assertToken(B.WRBLXX, "wRBLXx", 18);
        _assertToken(B.WRIOTX, "wRIOTx", 18);
        _assertToken(B.WRKLBX, "wRKLBx", 18);
        _assertToken(B.WSBETX, "wSBETx", 18);
        _assertToken(B.WSCHFX, "wSCHFx", 18);
        _assertToken(B.WSPCEX, "wSPCEx", 18);
        _assertToken(B.WSPYX, "wSPYx", 18);
        _assertToken(B.WSTRCX, "wSTRCx", 18);
        _assertToken(B.WTX, "wTx", 18);
        _assertToken(B.WTEMX, "wTEMx", 18);
        _assertToken(B.WTGTX, "wTGTx", 18);
        _assertToken(B.WTMOX, "wTMOx", 18);
        _assertToken(B.WTMUSX, "wTMUSx", 18);
        _assertToken(B.WTQQQX, "wTQQQx", 18);
        _assertToken(B.WTSLAX, "wTSLAx", 18);
        _assertToken(B.WTSMX, "wTSMx", 18);
        _assertToken(B.WUBERX, "wUBERx", 18);
        _assertToken(B.WUNHX, "wUNHx", 18);
        _assertToken(B.WVX, "wVx", 18);
        _assertToken(B.WVSTX, "wVSTx", 18);
        _assertToken(B.WVTX, "wVTx", 18);
        _assertToken(B.WVTIX, "wVTIx", 18);
        _assertToken(B.WWENX, "wWENx", 18);
        _assertToken(B.WWMTX, "wWMTx", 18);
        _assertToken(B.WWULFX, "wWULFx", 18);
        _assertToken(B.WXOMX, "wXOMx", 18);
    }

    /// @dev Each wrapped xStock is Backed's ERC-4626 vault over the xStock written out here, both proxies under the
    ///      admins and implementations read on 2026-11-21: an upgrade of either fails this test until its new code has
    ///      been read.
    function _assertWrappedXStock(address wrapper, address xStock, string memory xSymbol) internal view {
        assertEq(IERC4626(wrapper).asset(), xStock, "the wrapper's xStock");
        assertEq(IERC20Metadata(xStock).symbol(), xSymbol);
        assertEq(IERC20Metadata(xStock).decimals(), 18);
        assertEq(IOwned(wrapper).owner(), BACKED_SAFE, "every wrapper here is the Safe's");
        assertEq(address(uint160(uint256(vm.load(wrapper, EIP1967_ADMIN)))), WRAPPER_PROXY_ADMIN, "wrapper admin");
        assertEq(address(uint160(uint256(vm.load(wrapper, EIP1967_IMPLEMENTATION)))), WRAPPER_IMPLEMENTATION);
        assertEq(address(uint160(uint256(vm.load(xStock, EIP1967_ADMIN)))), XSTOCK_PROXY_ADMIN, "xStock admin");
        address implementation = address(uint160(uint256(vm.load(xStock, EIP1967_IMPLEMENTATION))));
        assertTrue(implementation == XSTOCK_IMPLEMENTATION || implementation == XSTOCK_IMPLEMENTATION_V3, "xStock code");
    }

    function testFork_theWrappedXStocksAreBackeds() public view {
        _assertWrappedXStock(B.WAAPLX, 0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a, "AAPLx");
        _assertWrappedXStock(B.WABBVX, 0xfBF2398dF672cEE4aFcC2A4A733222331c742a6A, "ABBVx");
        _assertWrappedXStock(B.WABTX, 0x89233399708C18Ac6887F90A2B4Cd8Ba5fEdD06e, "ABTx");
        _assertWrappedXStock(B.WACNX, 0x03183Ce31b1656B72A55fa6056e287f50C35BbEB, "ACNx");
        _assertWrappedXStock(B.WADBEX, 0x16E0B579be45bAaE54cEddd52e742B6457A7fE12, "ADBEx");
        _assertWrappedXStock(B.WAMZNX, 0x3557Ba345B01EFa20A1bdDC61F573BFD87195081, "AMZNx");
        _assertWrappedXStock(B.WAPPX, 0x50a1291F69D9d3853Def8209cFb1AF0b46927BE1, "APPx");
        _assertWrappedXStock(B.WASMLX, 0xC0B417e7F83db438631Eb5E096684dd742E5294F, "ASMLx");
        _assertWrappedXStock(B.WASTSX, 0x89b2607878ae19baB8020b8140eD550Ef3E953bb, "ASTSx");
        _assertWrappedXStock(B.WAVGOX, 0x38BAC69cbBd28156796e4163B2B6dcb81E336565, "AVGOx");
        _assertWrappedXStock(B.WAXPX, 0xb23767492D0Ca6dC7221CBeA45689a0410f388c4, "AXPx");
        _assertWrappedXStock(B.WAZNX, 0x5D642505FE1a28897eb3BaBA665F454755D8daA2, "AZNx");
        _assertWrappedXStock(B.WBACX, 0x314938c596F5ce31C3f75307d2979338C346D7F2, "BACx");
        _assertWrappedXStock(B.WBKNGX, 0xa8A25DB6Cf17Fa097f1DBbc9c841892456898fF3, "BKNGx");
        _assertWrappedXStock(B.WBLKX, 0x5A6a0742cA689E7E8a91A38F5255589CB2191646, "BLKx");
        _assertWrappedXStock(B.WBLSHX, 0x38DE7b9FC733DeF81525E65C1Bf99722026489e2, "BLSHx");
        _assertWrappedXStock(B.WBMNRX, 0xaeB681B69E5094E04d11BCeF51A71358A374C3ED, "BMNRx");
        _assertWrappedXStock(B.WBRKBX, 0x12992613fDd35aBe95DEc5a4964331b1ee23B50d, "BRK.Bx");
        _assertWrappedXStock(B.WBTBTX, 0x22E1991e5f82736A2a990322a46aac0e95826c5B, "BTBTx");
        _assertWrappedXStock(B.WCLSKX, 0xD0194F0f077968DA8ca59811e9407f54AE6c9432, "CLSKx");
        _assertWrappedXStock(B.WCMCSAX, 0xBC7170a1280Be28513B4e940C681537EB25e39f4, "CMCSAx");
        _assertWrappedXStock(B.WCOINX, 0x364f210f430eC2448Fc68A49203040F6124096F0, "COINx");
        _assertWrappedXStock(B.WCORZX, 0x51eD5b74A05F256DbD9Ebb4e4f68Bb41ba10160b, "CORZx");
        _assertWrappedXStock(B.WCOSTX, 0x4720B5e6421e6879132aED52040d56Bb6e5CFeeF, "COSTx");
        _assertWrappedXStock(B.WCRCLX, 0xfEbDEd1B0986a8ee107f5AB1a1c5a813491DeCEB, "CRCLx");
        _assertWrappedXStock(B.WCRMX, 0x4A4073f2EAF299A1be22254DCD2C41727F6F54a2, "CRMx");
        _assertWrappedXStock(B.WCRWDX, 0x214151022C2a5E380aB80CdaC31f23Ae554a7345, "CRWDx");
        _assertWrappedXStock(B.WCSCOX, 0x053C784cD87B74f42e0c089f98643E79c1A3ff16, "CSCOx");
        _assertWrappedXStock(B.WCVXX, 0xad5cdc3340904285B8159089974A99a1A09EB4C0, "CVXx");
        _assertWrappedXStock(B.WDHRX, 0xdbA228936F4079DaF9Aa906fd48a87f2300405F4, "DHRx");
        _assertWrappedXStock(B.WEBAYX, 0x4c7610990cb63cdca174ce61822F7693B49FCe93, "EBAYx");
        _assertWrappedXStock(B.WEXPEX, 0xd1be5bA0c293997C7F69da707D14EB4ABCB13ddD, "EXPEx");
        _assertWrappedXStock(B.WFIGX, 0x3C313D234D0C6C876F6c21ba2EC1F26823247Be2, "FIGx");
        _assertWrappedXStock(B.WGLDX, 0x2380F2673C640fB67E2d6B55B44C62F0E0e69DA9, "GLDx");
        _assertWrappedXStock(B.WGLXYX, 0xf7F4fAC56f012dE7Dd6adFF54C761986B9E0655a, "GLXYx");
        _assertWrappedXStock(B.WGMEX, 0xE5f6d3b2405ABdfE6F660e63202B25D23763160d, "GMEx");
        _assertWrappedXStock(B.WGOOGLX, 0xe92f673Ca36C5E2Efd2DE7628f815f84807e803F, "GOOGLx");
        _assertWrappedXStock(B.WGSX, 0x3Ee7E9B3A992fD23CD1C363B0e296856B04ab149, "GSx");
        _assertWrappedXStock(B.WHDX, 0x766b0CD6ED6D90B5d49d2c36a3761E9728501BA9, "HDx");
        _assertWrappedXStock(B.WHONX, 0x62a48560861B0b451654bFffdb5be6E47aa8ff1B, "HONx");
        _assertWrappedXStock(B.WHOODX, 0xE1385FDd5ffB10081Cd52C56584F25EFa9084015, "HOODx");
        _assertWrappedXStock(B.WHSDTX, 0xd457b379801433EA5c3A8542b61902023AE39DcD, "HSDTx");
        _assertWrappedXStock(B.WHUTX, 0x560deb3D70Ac90064fF809349cDf9A771a06fd36, "HUTx");
        _assertWrappedXStock(B.WIBMX, 0xd9913208647671Fe0F48F7F260076B2C6F310Aac, "IBMx");
        _assertWrappedXStock(B.WIEMGX, 0x6a668332825450ACD2e449372057d31b3de16a1E, "IEMGx");
        _assertWrappedXStock(B.WIJRX, 0xAA28cB97D7f7E172f54deE950743886D2d65447d, "IJRx");
        _assertWrappedXStock(B.WINTCX, 0xf8A80D1cb9cFD70D03D655D9dF42339846F3B3C8, "INTCx");
        _assertWrappedXStock(B.WIWMX, 0xdadfb355c6110eda0908740d52c834d6C2BCDDc7, "IWMx");
        _assertWrappedXStock(B.WJNJX, 0xdb0482cfaD4789798623E64b15eebA01b16e917C, "JNJx");
        _assertWrappedXStock(B.WJPMX, 0xD9FC3E075d45254a1D834fEa18AF8041207DeA0A, "JPMx");
        _assertWrappedXStock(B.WKOX, 0xdCC1a2699441079dA889B1F49e12B69cC791129b, "KOx");
        _assertWrappedXStock(B.WLINX, 0x15059c599C16Fd8f70B633Ade165502D6402CD49, "LINx");
        _assertWrappedXStock(B.WLLYX, 0x19c41EA77b34BbDEe61c3A87A75D1ABDA2ED0be4, "LLYx");
        _assertWrappedXStock(B.WLULUX, 0x847dEB9c78fb00319bC7A006dFF729c11428E537, "LULUx");
        _assertWrappedXStock(B.WMAX, 0xb365Cd2588065F522D379AD19e903304f6B622C6, "MAx");
        _assertWrappedXStock(B.WMCDX, 0x80A77a372c1e12AcCdA84299492f404902E2DA67, "MCDx");
        _assertWrappedXStock(B.WMDTX, 0x0588e851ec0418d660BeE81230d6c678dAF21d46, "MDTx");
        _assertWrappedXStock(B.WMETAX, 0x96702be57Cd9777f835117a809C7124fe4ec989A, "METAx");
        _assertWrappedXStock(B.WMNSTX, 0x8499b26BBfC8c3830a37b92E47DF2d7cBc0154e9, "MNSTx");
        _assertWrappedXStock(B.WMRKX, 0x17D8186Ed8F68059124190D147174D0f6697dc40, "MRKx");
        _assertWrappedXStock(B.WMRVLX, 0xeAAd46F4146Ded5a47B55AA7F6c48c191dEAEC88, "MRVLx");
        _assertWrappedXStock(B.WMSFTX, 0x5621737f42dAE558b81269FcB9E9E70c19Aa6b35, "MSFTx");
        _assertWrappedXStock(B.WMSTRX, 0xAE2f842EF90C0d5213259Ab82639D5BBF649b08E, "MSTRx");
        _assertWrappedXStock(B.WMUX, 0xf6a873BAe4Ba1B304e45dF52A4b7D176E1C6a8c4, "MUx");
        _assertWrappedXStock(B.WNFLXX, 0xA6a65AC27E76cD53cB790473E4345c46e5eBf961, "NFLXx");
        _assertWrappedXStock(B.WNVDAX, 0xc845b2894dBddd03858fd2D643B4eF725fE0849d, "NVDAx");
        _assertWrappedXStock(B.WNVOX, 0xF9523E369c5f55ad72DbAA75B0a9b92B3D8b147e, "NVOx");
        _assertWrappedXStock(B.WOPENX, 0xbEe6b69345F376598Fe16AbD5592c6F844825E66, "OPENx");
        _assertWrappedXStock(B.WORCLX, 0x548308E91ec9F285C7bFf05295baDBD56a6e4971, "ORCLx");
        _assertWrappedXStock(B.WPANWX, 0xe12BB32D77BE4DB10DDC82088b230D35d097E9C5, "PANWx");
        _assertWrappedXStock(B.WPEPX, 0x36c424a6EC0e264b1616102Ad63eD2aD7857413e, "PEPx");
        _assertWrappedXStock(B.WPFEX, 0x1Ac765B5BEa23184802C7d2d497f7c33f1444A9e, "PFEx");
        _assertWrappedXStock(B.WPGX, 0xa90424D5D3E770e8644103AB503ed775dD1318FD, "PGx");
        _assertWrappedXStock(B.WPLX, 0x536825370F1159cBA953055f5c2F16DDc7B5a348, "PLx");
        _assertWrappedXStock(B.WPLTRX, 0x6d482CeC5f9dd1f05CCee9Fd3ff79B246170F8e2, "PLTRx");
        _assertWrappedXStock(B.WPMX, 0x02a6c1789c3B4FDb1a7a3DfA39F90e5d3c94F4F9, "PMx");
        _assertWrappedXStock(B.WPYPLX, 0xf706585e7e8900bE0267bEE3B9A2F70835EC6628, "PYPLx");
        _assertWrappedXStock(B.WQQQX, 0xa753A7395cAe905Cd615Da0B82A53E0560f250af, "QQQx");
        _assertWrappedXStock(B.WRBLXX, 0x5d8dA1417E3565eb02C9ca8cC588bE5D8F65b1c5, "RBLXx");
        _assertWrappedXStock(B.WRIOTX, 0x6Ac47387f0a2798dF4C4eE5bb31ab9517ac97cb8, "RIOTx");
        _assertWrappedXStock(B.WRKLBX, 0xE17ce7dD2afb6Da3488fD9ef2558523D569e17B4, "RKLBx");
        _assertWrappedXStock(B.WSBETX, 0x338791c58fdED314b81EAb139A1A2Fb7967D90d6, "SBETx");
        _assertWrappedXStock(B.WSCHFX, 0xF6D87E523512704C29E9b7cA3e9e6226bDCE3EA1, "SCHFx");
        _assertWrappedXStock(B.WSPCEX, 0x7F8ba411ECBC0A135d669d5EaE5D15b0Ca0b0ea1, "SPCEx");
        _assertWrappedXStock(B.WSPYX, 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48, "SPYx");
        _assertWrappedXStock(B.WSTRCX, 0x1Aad217B8F78dbA5E6693460e8470F8b1A3977f3, "STRCx");
        _assertWrappedXStock(B.WTX, 0x75639aE3A05079873D7189DcbDBc455898cAe904, "Tx");
        _assertWrappedXStock(B.WTEMX, 0x61AeE4f4e6B62806c26eafF921e7F41782cA2E03, "TEMx");
        _assertWrappedXStock(B.WTGTX, 0xAB6a44AD34D083f463fa6F64d0619F11eB2cb48D, "TGTx");
        _assertWrappedXStock(B.WTMOX, 0xAF072F109A2C173D822a4fe9af311A1B18F83d19, "TMOx");
        _assertWrappedXStock(B.WTMUSX, 0x68F3DDEE8BAE33691E7CD0372984fD857E842760, "TMUSx");
        _assertWrappedXStock(B.WTQQQX, 0xfDDDb57878eF9D6f681Ec4381DCB626b9E69AC86, "TQQQx");
        _assertWrappedXStock(B.WTSLAX, 0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0, "TSLAx");
        _assertWrappedXStock(B.WTSMX, 0x9e3bf4Ecfc44EeDD624F26656B6736a3F093b073, "TSMx");
        _assertWrappedXStock(B.WUBERX, 0xdb9783Ca04bBD64fe2c6d7B9503A979b3DE30729, "UBERx");
        _assertWrappedXStock(B.WUNHX, 0x167A6375DA1eFc4a5BE0f470E73eCEfd66245048, "UNHx");
        _assertWrappedXStock(B.WVX, 0x2363FD1235C1B6d3A5088DdF8dF3A0b3A30C5293, "Vx");
        _assertWrappedXStock(B.WVSTX, 0x7AB6C97f65e4227adc5090Bd31a376D1F36f39fa, "VSTx");
        _assertWrappedXStock(B.WVTX, 0x6d5edEEbBc6A4099Eb8bb289EB3b80D799f7b28C, "VTx");
        _assertWrappedXStock(B.WVTIX, 0xbD730E618bcD88C82dDeE52e10275CF2f88A4777, "VTIx");
        _assertWrappedXStock(B.WWENX, 0xfEEE18422F8F1cD6193C12aAfad7123DbfF15517, "WENx");
        _assertWrappedXStock(B.WWMTX, 0x7AEfc9965699fBea943e03264d96e50CD4A97b21, "WMTx");
        _assertWrappedXStock(B.WWULFX, 0xC0c2150cf0870E2d7aBc7cDe17C20A542faFBB9B, "WULFx");
        _assertWrappedXStock(B.WXOMX, 0xEEdb0273c5Af792745180e9fF568cD01550fFA13, "XOMx");
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
            address(this), address(new GuardianSafe()), address(0), address(0), address(0), address(this)
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

    /// @dev Lists `tokens` on `factory`, whose owner is this test.
    function _list(WeightedIndexFactory factory, address[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; ++i) {
            factory.proposeListing(tokens[i]);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < tokens.length; ++i) {
            factory.executeListing(tokens[i]);
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
        WeightedIndexFactory factory = new WeightedIndexFactory(address(this), address(0));
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

    /// @dev The wrapped xStocks of the BNB Chain list from `from` up to `to`, after its twelve coins: each passes the check
    ///      as listable, its transfers exact, with its one power the check reads, the upgrade of its proxy, behind
    ///      Backed's implementation and through the Safe. Two halves, since a check costs about twelve million gas and
    ///      the whole list would pass a test's limit of 2^30.
    function _checkWrapped(uint256 from, uint256 to) internal {
        CheckToken checker = new CheckToken();
        address[] memory list = new ConfigureWeighted().bnbList();
        assertEq(list.length, 12 + 104);
        for (uint256 i = 12 + from; i < 12 + to; ++i) {
            CheckToken.Report memory r = checker.check(list[i], address(0), checker.markets());
            checker.log(r);
            assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact), r.symbol);
            assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Listable), r.symbol);
            assertEq(r.powers & checker.UPGRADE(), checker.UPGRADE(), r.symbol);
            assertEq(r.implementation, WRAPPER_IMPLEMENTATION, r.symbol);
            assertEq(uint8(r.owner.kind), uint8(CheckToken.Kind.Safe), "every wrapper here is the Safe's");
        }
    }

    function testFork_theFirstWrappedXStocksPassTheCheck() public {
        _checkWrapped(0, 52);
    }

    function testFork_theOtherWrappedXStocksPassTheCheck() public {
        _checkWrapped(52, 104);
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

    /// @dev An index of the twelve coins of the BNB Chain list issues and redeems in kind: every coin moves by exactly
    ///      what the index asks, and a full redeem returns every coin.
    function testFork_anIndexOfTheTwelveCoinsIssuesAndRedeemsInKind() public {
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

    /// @dev An index of WBNB and five wrapped xStocks issues and redeems in kind on Backed's real contracts: issue's
    ///      probe sends each wrapper to the index itself (RW-8), and the wrappers' pause and sanctions checks pass every
    ///      move, so each coin moves by exactly what the index asks and a full redeem returns every one.
    function testFork_anIndexOfWrappedXStocksIssuesAndRedeemsInKind() public {
        (WeightedIndexFactory factory,,,) = _deploy();
        address[6] memory coins = [B.WBNB, B.WNVDAX, B.WTSLAX, B.WSPYX, B.WQQQX, B.WMSTRX];
        address[] memory list = new address[](coins.length);
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](coins.length);
        for (uint256 i = 0; i < coins.length; ++i) {
            list[i] = coins[i];
            // 6 coins: 1,670 for the first and 1,666 for each other is 10,000; a thousandth of each per share.
            specs[i] = IWeightedIndexFactory.ComponentSpec({token: coins[i], weight: i == 0 ? 1670 : 1666, units: 1e15});
        }
        _list(factory, list);
        factory.setApprovedCreator(address(this), true);
        WeightedHub index = WeightedHub(factory.createIndex("Wrapped xStocks", "WXS6", specs, _params()));

        uint256 shares = 100e18;
        uint256[] memory need = _issueInKind(index, alice, shares);
        assertEq(index.balanceOf(alice), shares);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(IERC20(list[i]).balanceOf(address(index)), need[i], "the index holds the wrapper itself");
        }
        vm.prank(alice);
        index.redeem(shares, alice);
        assertEq(index.totalSupply(), 0);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(IERC20(list[i]).balanceOf(alice), need[i], "every wrapper comes back in kind");
        }
    }

    /// @dev An index of the twelve coins the BNB Chain list starts with, before its wrapped xStocks, on a fresh
    ///      deployment, a thousandth of a coin of each per share.
    function _twelveCoinIndex() internal returns (WeightedHub index, address[] memory list) {
        (WeightedIndexFactory factory,,,) = _deploy();
        address[] memory all = B.all();
        list = new address[](12);
        for (uint256 i = 0; i < 12; ++i) {
            list[i] = all[i];
        }
        _list(factory, list);
        factory.setApprovedCreator(address(this), true);
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            // 12 coins: 837 for the first and 833 for each other is 10,000.
            specs[i] = IWeightedIndexFactory.ComponentSpec({token: list[i], weight: i == 0 ? 837 : 833, units: 1e15});
        }
        index = WeightedHub(factory.createIndex("BNB Chain Twelve", "BNB12", specs, _params()));
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
    function testFork_anIndexOfTheTwelveCoinsRebalancesWithRealTransfers() public {
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

    /// @dev An index of WBNB, BTCB and ETH on `factory`, the three coins Uniswap routes deepest on BNB Chain.
    function _majors(WeightedIndexFactory factory) internal returns (WeightedHub index) {
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (B.WBNB, B.BTCB, B.ETH);
        _list(factory, three);
        factory.setApprovedCreator(address(this), true);
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](3);
        specs[0] = IWeightedIndexFactory.ComponentSpec({token: B.WBNB, weight: 3334, units: U_WBNB});
        specs[1] = IWeightedIndexFactory.ComponentSpec({token: B.BTCB, weight: 3333, units: U_BTCB});
        specs[2] = IWeightedIndexFactory.ComponentSpec({token: B.ETH, weight: 3333, units: U_ETH});
        index = WeightedHub(factory.createIndex("BNB Chain Majors", "BMAJ", specs, _params()));
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
        assertEq(IERC20(B.WBNB).balanceOf(address(index)), shares * U_WBNB / 1e18, "the index holds BNB in kind");
        assertEq(IERC20(B.BTCB).balanceOf(address(index)), shares * U_BTCB / 1e18);
        assertEq(IERC20(B.ETH).balanceOf(address(index)), shares * U_ETH / 1e18);
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
}
