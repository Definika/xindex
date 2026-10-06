// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../../src/WeightedHub.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IWeightedIndexFactory} from "../../src/interfaces/IWeightedIndexFactory.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IPancakeUniversalRouter} from "../../src/interfaces/IPancakeUniversalRouter.sol";
import {MintRequests} from "../../src/MintRequests.sol";
import {IMintRequests} from "../../src/interfaces/IMintRequests.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployChecks} from "../../script/DeployChecks.sol";

interface IWbtcAdmin {
    function owner() external view returns (address);
    function pause() external;
    function unpause() external;
}

interface IUsdtAdmin {
    function owner() external view returns (address);
    function setParams(uint256 newBasisPoints, uint256 newMaxFee) external;
    function addBlackList(address user) external;
    function removeBlackList(address user) external;
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/// @notice The Safe calls the module test makes, identical in 1.3.0 and 1.4.1.
interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);
    function nonce() external view returns (uint256);
    function enableModule(address module) external;
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
}

/// @notice Security-review regression tests against the real mainnet tokens and router.
///         Skips when MAINNET_RPC_URL is unset.
contract SecurityForkTest is Test {
    using SafeERC20 for IERC20;

    WeightedIndexFactory factory;
    IndexZap zap;
    address user = makeAddr("user");

    // 0.0001 WBTC + 0.001 WETH + 1 LINK per index token
    uint256 constant U_WBTC = 10_000;
    uint256 constant U_WETH = 1e15;
    uint256 constant U_LINK = 1e18;

    uint24 constant F500 = 500;
    uint24 constant F3000 = 3000;

    /// @dev Safe's own proxy factories and singletons, 1.3.0 and 1.4.1, as every Safe on mainnet is built from them.
    address constant SAFE_FACTORY_130 = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SAFE_130 = 0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552;
    address constant SAFE_FACTORY_141 = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address constant SAFE_141 = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    uint256 constant SIGNER_A = 0xA11CE;
    uint256 constant SIGNER_B = 0xB0B;
    uint256 constant SIGNER_C = 0xCA201;

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
        factory = new WeightedIndexFactory(address(this), address(0), A.PYTH);
        zap = new IndexZap(
            IIndexFactory(address(factory)), IUniversalRouter(A.UNIVERSAL_ROUTER), IPancakeUniversalRouter(address(0))
        );

        // Nothing here asks for a price, so each token is listed under a price id of its own making.
        factory.proposeListing(A.WBTC, keccak256(abi.encode(A.WBTC)));
        factory.proposeListing(A.WETH, keccak256(abi.encode(A.WETH)));
        factory.proposeListing(A.LINK, keccak256(abi.encode(A.LINK)));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(A.WBTC);
        factory.executeListing(A.WETH);
        factory.executeListing(A.LINK);
    }

    function _create(address a, address b) internal returns (WeightedHub idx) {
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = IWeightedIndexFactory.ComponentSpec({token: a, weight: 5000, units: _units(a)});
        specs[1] = IWeightedIndexFactory.ComponentSpec({token: b, weight: 5000, units: _units(b)});
        idx = WeightedHub(factory.createIndex("Fork Security", "FSEC", specs));
    }

    /// @dev The suite's units per index token for each of its components.
    function _units(address token) internal pure returns (uint256) {
        return token == A.WBTC ? U_WBTC : token == A.WETH ? U_WETH : U_LINK;
    }

    function _issue(WeightedHub idx, uint256 shares) internal {
        address[] memory t = idx.componentTokens();
        uint256[] memory need = idx.previewIssue(shares);
        for (uint256 i = 0; i < t.length; ++i) {
            deal(t[i], user, need[i]);
        }
        vm.startPrank(user);
        for (uint256 i = 0; i < t.length; ++i) {
            IERC20(t[i]).forceApprove(address(idx), need[i]);
        }
        idx.issue(shares, user);
        vm.stopPrank();
    }

    function test_M01_realWbtcPause_redeemSkippingFreesWethAndClaimPaysLater() public {
        WeightedHub idx = _create(A.WBTC, A.WETH);
        _issue(idx, 1e18);
        address wbtcController = IWbtcAdmin(A.WBTC).owner();
        vm.prank(wbtcController);
        IWbtcAdmin(A.WBTC).pause();

        vm.startPrank(user);
        vm.expectRevert(bytes("")); // WBTC's whenNotPaused reverts with no data
        idx.redeem(1e18, user);

        idx.redeemSkipping(1e18, user, 1 << 0);
        assertEq(IERC20(A.WETH).balanceOf(user), 1e15, "WETH comes out while WBTC is paused");
        assertEq(idx.claimOf(user, A.WBTC), 10_000);

        vm.expectRevert(bytes("")); // still paused
        idx.claim(A.WBTC, user);
        vm.stopPrank();

        vm.prank(wbtcController);
        IWbtcAdmin(A.WBTC).unpause();
        vm.prank(user);
        idx.claim(A.WBTC, user);
        assertEq(IERC20(A.WBTC).balanceOf(user), 10_000, "WBTC is paid once the custodian unpauses");
        assertEq(idx.totalClaims(A.WBTC), 0);
    }

    function test_I02_realUsdtFeeSwitch_zapRevertsWithTransferShortfall() public {
        WeightedHub idx = _create(A.WBTC, A.WETH);
        _issue(idx, 1e18);

        vm.prank(IUsdtAdmin(A.USDT).owner());
        IUsdtAdmin(A.USDT).setParams(10, 5); // Tether switches on a 0.10% transfer fee

        IIndexZap.BurnLeg[] memory burnLegs = new IIndexZap.BurnLeg[](2);
        burnLegs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDT),
            v4Path: new PathKey[](0),
            pancakePath: "",
            minAmountOut: 0
        });
        burnLegs[1] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDT), v4Path: new PathKey[](0), pancakePath: "", minAmountOut: 0
        });
        vm.startPrank(user);
        idx.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.TransferShortfall.selector, A.USDT));
        zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(idx),
                expectedNonce: 0,
                shares: 1e18,
                tokenOut: A.USDT,
                minAmountOut: 1,
                legs: burnLegs,
                to: user,
                deadline: block.timestamp
            })
        );
        idx.redeem(1e18, user); // the in-kind exit still works
        vm.stopPrank();
        assertEq(IERC20(A.WBTC).balanceOf(user), 10_000);

        // Minting with fee-charging USDT stops before any swap.
        deal(A.USDT, user, 100e6);
        IIndexZap.MintLeg[] memory mintLegs = new IIndexZap.MintLeg[](2);
        mintLegs[0] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDT),
            v4Path: new PathKey[](0),
            pancakePath: "",
            maxAmountIn: 0
        });
        mintLegs[1] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDT), v4Path: new PathKey[](0), pancakePath: "", maxAmountIn: 0
        });
        vm.startPrank(user);
        IERC20(A.USDT).forceApprove(address(zap), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.TransferShortfall.selector, A.USDT));
        zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(idx),
                expectedNonce: 0,
                tokenIn: A.USDT,
                maxAmountIn: 100e6,
                shares: 1e17,
                legs: mintLegs,
                to: user,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function test_I03_strayRouterEthIsRefundedNotLocked() public {
        WeightedHub idx = _create(A.WBTC, A.LINK);
        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](2);
        legs[0] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(A.WBTC, F500, A.WETH), v4Path: new PathKey[](0), pancakePath: "", maxAmountIn: 0
        });
        legs[1] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(A.LINK, F3000, A.WETH), v4Path: new PathKey[](0), pancakePath: "", maxAmountIn: 0
        });

        vm.deal(A.UNIVERSAL_ROUTER, 10 ether); // stray ether sitting in the router
        uint256 maxIn = 1 ether;
        deal(A.WETH, user, maxIn);
        vm.startPrank(user);
        IERC20(A.WETH).forceApprove(address(zap), maxIn);
        uint256 spent = zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(idx),
                expectedNonce: 0,
                tokenIn: A.WETH,
                maxAmountIn: maxIn,
                shares: 1e18,
                legs: legs,
                to: user,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertEq(idx.balanceOf(user), 1e18);
        assertGt(spent, 0, "the mint is paid for out of the user's own WETH");
        assertEq(IERC20(A.WETH).balanceOf(user), maxIn - spent, "and the rest comes back");
        assertEq(IERC20(A.WETH).balanceOf(address(zap)), 0, "nothing is left in the zap");
        assertEq(IERC20(A.WETH).balanceOf(A.UNIVERSAL_ROUTER), 0, "or in the router");
        assertEq(A.UNIVERSAL_ROUTER.balance, 10 ether, "and the stray ether is untouched: nothing here wraps it");
    }

    function test_FR01_strayRouterEthNoLongerBlocksBurns() public {
        WeightedHub idx = _create(A.WBTC, A.WETH);
        _issue(idx, 1e18);

        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](2);
        legs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDC),
            v4Path: new PathKey[](0),
            pancakePath: "",
            minAmountOut: 0
        });
        legs[1] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDC), v4Path: new PathKey[](0), pancakePath: "", minAmountOut: 0
        });

        vm.deal(A.UNIVERSAL_ROUTER, 10 ether); // a griefer, or a careless user, leaves ether in the router
        vm.startPrank(user);
        idx.approve(address(zap), 1e18);
        uint256 out = zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(idx),
                expectedNonce: 0,
                shares: 1e18,
                tokenOut: A.USDC,
                minAmountOut: 1,
                legs: legs,
                to: user,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertGt(out, 0);
        assertEq(IERC20(A.USDC).balanceOf(user), out);
        // Every hop is swapped on its own and the router is swept clean after each, so no intermediate WETH is left
        // there for anyone to take. Before the per-hop fix (XA-08) it stayed in the router.
        assertEq(IERC20(A.WETH).balanceOf(A.UNIVERSAL_ROUTER), 0, "no intermediate is left in the router");
        assertEq(IERC20(A.WETH).balanceOf(address(zap)), 0, "or in the zap");
        assertEq(A.UNIVERSAL_ROUTER.balance, 10 ether, "and the stray ether is untouched: nothing here wraps it");
    }

    function _burnToUsdc(WeightedHub idx, IIndexZap.BurnLeg[] memory legs) internal returns (uint256 out) {
        vm.startPrank(user);
        idx.approve(address(zap), 1e18);
        out = zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(idx),
                expectedNonce: 0,
                shares: 1e18,
                tokenOut: A.USDC,
                minAmountOut: 1,
                legs: legs,
                to: user,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    /// @dev FR-01, CR-L02. The sweep after a hop returns the router's whole balance of the hop's input, a stray balance
    ///      included, and the zap measured what came back as the shortfall of what it had sent: a stray larger than the
    ///      hop's spend underflowed that and reverted the burn, so one transfer to the router blocked every burn
    ///      through that token. What came back is now measured as the balance above what was left, and handed on with
    ///      the hop's unsold input.
    function test_FR01_CRL02_aStrayTokenInTheRouterNoLongerBlocksABurn() public {
        WeightedHub idx = _create(A.WBTC, A.WETH);
        _issue(idx, 1e18);
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](2);
        legs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDC),
            v4Path: new PathKey[](0),
            pancakePath: "",
            minAmountOut: 0
        });
        legs[1] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDC), v4Path: new PathKey[](0), pancakePath: "", minAmountOut: 0
        });

        // A griefer, or a user's slip, leaves a whole WETH in the router: far more than the WBTC leg's WETH hop sells.
        deal(A.WETH, A.UNIVERSAL_ROUTER, 1 ether);
        uint256 out = _burnToUsdc(idx, legs);

        assertGt(out, 0);
        assertEq(IERC20(A.USDC).balanceOf(user), out, "the burn pays out");
        assertEq(IERC20(A.WETH).balanceOf(user), 1 ether, "and the stray reaches the recipient with the unsold input");
        assertEq(IERC20(A.WETH).balanceOf(A.UNIVERSAL_ROUTER), 0, "the router is swept clean");
        assertEq(IERC20(A.WETH).balanceOf(address(zap)), 0, "and nothing stays in the zap");
    }

    /// @dev FR-01, CR-L02: the same for a V4 leg, whose sweep returns the component itself. The stray, 3 LINK, is more
    ///      than the leg's 1 LINK.
    function test_FR01_CRL02_aStrayComponentInTheRouterNoLongerBlocksAV4Burn() public {
        WeightedHub idx = _create(A.LINK, A.WETH);
        _issue(idx, 1e18);
        PathKey[] memory route = new PathKey[](2);
        route[0] =
            PathKey({intermediateCurrency: address(0), fee: F3000, tickSpacing: 60, hooks: address(0), hookData: ""});
        route[1] = PathKey({intermediateCurrency: A.USDC, fee: F500, tickSpacing: 10, hooks: address(0), hookData: ""});
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](2);
        legs[0] = IIndexZap.BurnLeg({v3Path: "", v4Path: route, pancakePath: "", minAmountOut: 0});
        legs[1] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDC), v4Path: new PathKey[](0), pancakePath: "", minAmountOut: 0
        });

        deal(A.LINK, A.UNIVERSAL_ROUTER, 3e18);
        uint256 out = _burnToUsdc(idx, legs);

        assertGt(out, 0);
        assertEq(IERC20(A.USDC).balanceOf(user), out, "the burn pays out");
        assertEq(IERC20(A.LINK).balanceOf(user), 3e18, "and the stray reaches the recipient");
        assertEq(IERC20(A.LINK).balanceOf(A.UNIVERSAL_ROUTER), 0, "the router is swept clean");
        assertEq(IERC20(A.LINK).balanceOf(address(zap)), 0, "and nothing stays in the zap");
    }

    /// @dev MintRequests against the real stablecoins. With Tether's fee switched on after a USDT request was made,
    ///      the escrow still leaves in full to its requester, less the fee on the way out, and a redemption filled in
    ///      USDT must deliver the requester's limit after the fee: a filler sending exactly the limit is refused. USDC's
    ///      request fills as it would on any day.
    function test_mintRequestsWithTheRealStablecoins() public {
        MintRequests requests = new MintRequests(address(factory), A.USDC, A.USDT);
        WeightedHub idx = _create(A.WBTC, A.WETH);
        _issue(idx, 2e18);
        address requester = makeAddr("requester");

        deal(A.USDC, requester, 500e6);
        deal(A.USDT, requester, 1_000e6);
        vm.startPrank(requester);
        IERC20(A.USDC).forceApprove(address(requests), 500e6);
        IERC20(A.USDT).forceApprove(address(requests), 1_000e6);
        uint256 usdcId = requests.requestMint(address(idx), A.USDC, 500e6, 1e18, block.timestamp + 1 days);
        uint256 usdtId = requests.requestMint(address(idx), A.USDT, 1_000e6, 1e18, block.timestamp + 1 days);
        vm.stopPrank();
        assertEq(requests.getRequest(usdtId).escrow, 1_000e6, "no fee yet, so the escrow is the whole amount");

        vm.startPrank(user);
        idx.approve(address(requests), 1e18);
        requests.fill(usdcId, 1e18);
        vm.stopPrank();
        assertEq(idx.balanceOf(requester), 1e18);
        assertEq(IERC20(A.USDC).balanceOf(user), 500e6, "the filler takes the USDC escrow");

        vm.prank(IUsdtAdmin(A.USDT).owner());
        IUsdtAdmin(A.USDT).setParams(10, 5); // Tether switches on a 0.10% transfer fee
        vm.prank(requester);
        requests.cancel(usdtId);
        assertEq(IERC20(A.USDT).balanceOf(requester), 999e6, "the whole escrow left, less the fee on the way out");
        assertEq(IERC20(A.USDT).balanceOf(address(requests)), 0, "and nothing is left short or behind");

        vm.startPrank(requester);
        idx.approve(address(requests), 1e18);
        uint256 redeemId = requests.requestRedeem(address(idx), 1e18, A.USDT, 400e6, block.timestamp + 1 days);
        vm.stopPrank();
        deal(A.USDT, user, 1_000e6);
        vm.startPrank(user);
        IERC20(A.USDT).forceApprove(address(requests), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.BelowLimit.selector, 399.6e6, 400e6));
        requests.fill(redeemId, 400e6);
        requests.fill(redeemId, 400.400401e6);
        vm.stopPrank();
        assertGe(IERC20(A.USDT).balanceOf(requester), 999e6 + 400e6, "the limit arrived after the fee");
        assertEq(idx.balanceOf(user), 2e18, "the filler holds the shares it sold and got back");
    }

    /// @dev SA-01 against mainnet Tether. Tether checks only the sender of a transfer and `from` of a transferFrom,
    ///      which is what the mock copies: a requester it has blacklisted is still paid by a fill, and a MintRequests it
    ///      has blacklisted would still take a USDT deposit it could never pay out, so a mint request refuses one.
    function test_SA01_realTetherFreezesAsTheMockDoes() public {
        MintRequests requests = new MintRequests(address(factory), A.USDC, A.USDT);
        WeightedHub idx = _create(A.WBTC, A.WETH);
        _issue(idx, 1e18);
        address requester = makeAddr("requester");
        address tether = IUsdtAdmin(A.USDT).owner();

        vm.prank(user);
        idx.transfer(requester, 1e18);
        vm.startPrank(requester);
        idx.approve(address(requests), 1e18);
        uint256 id = requests.requestRedeem(address(idx), 1e18, A.USDT, 100e6, block.timestamp + 1 days);
        vm.stopPrank();
        vm.prank(tether);
        IUsdtAdmin(A.USDT).addBlackList(requester);
        deal(A.USDT, user, 100e6);
        vm.startPrank(user);
        IERC20(A.USDT).forceApprove(address(requests), 100e6);
        requests.fill(id, 100e6);
        vm.stopPrank();
        assertEq(IERC20(A.USDT).balanceOf(requester), 100e6, "a blacklisted recipient is still paid");

        vm.prank(tether);
        IUsdtAdmin(A.USDT).addBlackList(address(requests));
        deal(A.USDT, requester, 0);
        address clean = makeAddr("clean");
        deal(A.USDT, clean, 100e6);
        vm.startPrank(clean);
        IERC20(A.USDT).forceApprove(address(requests), 100e6);
        vm.expectRevert(bytes("")); // Tether's `require` carries no message
        requests.requestMint(address(idx), A.USDT, 100e6, 1e17, block.timestamp + 1 days);
        vm.stopPrank();
        assertEq(IERC20(A.USDT).balanceOf(clean), 100e6, "the deposit was refused, not trapped");

        vm.prank(tether);
        IUsdtAdmin(A.USDT).removeBlackList(address(requests));
        vm.prank(clean);
        requests.requestMint(address(idx), A.USDT, 100e6, 1e17, block.timestamp + 1 days);
        assertEq(IERC20(A.USDT).balanceOf(address(requests)), 100e6);
    }

    /// @dev XA-07, CR-I36. The module check reads the page of modules that starts at the sentinel, and the offline mock
    ///      only learned to honour `start` in this review, so the real Safe is the proof: a 3-of-3 Safe without modules
    ///      is accepted as an owner, and the same Safe with one module enabled is refused, on 1.3.0, which answers any
    ///      other start with an empty page, and on 1.4.1, which refuses one. A real 2-of-3 is refused outright, since
    ///      the owner needs at least three signatures (the owner's call on 2026-09-30).
    function test_XA07_CRI36_aRealSafeWithAModuleIsRefused() public {
        Deploy deployer = new Deploy();
        address module = makeAddr("module");
        address[2] memory factories = [SAFE_FACTORY_130, SAFE_FACTORY_141];
        address[2] memory singletons = [SAFE_130, SAFE_141];
        for (uint256 i = 0; i < factories.length; ++i) {
            ISafe twoOfThree = _safe(factories[i], singletons[i], 2, 0);
            vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerThresholdTooLow.selector, address(twoOfThree), 2));
            deployer.checkOwner(address(twoOfThree));

            ISafe safe = _safe(factories[i], singletons[i], 3, 1);
            deployer.checkOwner(address(safe));
            _enableModule(safe, module);
            vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerHasModules.selector, address(safe), module));
            deployer.checkOwner(address(safe));
        }
    }

    function _safe(address safeFactory, address singleton, uint256 threshold, uint256 saltNonce)
        internal
        returns (ISafe)
    {
        address[] memory owners = new address[](3);
        (owners[0], owners[1], owners[2]) = (vm.addr(SIGNER_A), vm.addr(SIGNER_B), vm.addr(SIGNER_C));
        bytes memory init = abi.encodeCall(
            ISafe.setup, (owners, threshold, address(0), "", address(0), address(0), 0, payable(address(0)))
        );
        return ISafe(ISafeProxyFactory(safeFactory).createProxyWithNonce(singleton, init, saltNonce));
    }

    /// @dev Enables `module` the way a real one is: a Safe transaction to itself, signed by all three owners in the
    ///      ascending order of their addresses, as the Safe requires.
    function _enableModule(ISafe safe, address module) internal {
        bytes memory data = abi.encodeCall(ISafe.enableModule, (module));
        bytes32 hash = safe.getTransactionHash(address(safe), 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        uint256[3] memory keys = [SIGNER_A, SIGNER_B, SIGNER_C];
        for (uint256 i = 1; i < 3; ++i) {
            for (uint256 j = i; j > 0 && vm.addr(keys[j]) < vm.addr(keys[j - 1]); --j) {
                (keys[j], keys[j - 1]) = (keys[j - 1], keys[j]);
            }
        }
        bytes memory signatures =
            abi.encodePacked(_signature(keys[0], hash), _signature(keys[1], hash), _signature(keys[2], hash));
        assertTrue(
            safe.execTransaction(address(safe), 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures)
        );
    }

    function _signature(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 sig) = vm.sign(key, hash);
        return abi.encodePacked(r, sig, v);
    }
}
