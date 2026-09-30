// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexHub} from "../../src/IndexHub.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {IIndexHub} from "../../src/interfaces/IIndexHub.sol";
import {Deploy} from "../../script/Deploy.s.sol";

interface IWbtcAdmin {
    function owner() external view returns (address);
    function pause() external;
    function unpause() external;
}

interface IUsdtAdmin {
    function owner() external view returns (address);
    function setParams(uint256 newBasisPoints, uint256 newMaxFee) external;
}

interface IWETH9 {
    function deposit() external payable;
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

    IndexFactory factory;
    IndexZap zap;
    address user = makeAddr("user");

    // 0.0001 WBTC + 0.001 WETH + 1 LINK per index token
    uint256 constant U_WBTC = 10_000;
    uint256 constant U_WETH = 1e15;
    uint256 constant U_LINK = 1e18;
    /// @dev With each component listed at its units as its supply, this scale gives exactly those units.
    uint256 constant K = 1e36;

    uint24 constant F500 = 500;
    uint24 constant F3000 = 3000;

    /// @dev Safe's own proxy factories and singletons, 1.3.0 and 1.4.1, as every Safe on mainnet is built from them.
    address constant SAFE_FACTORY_130 = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SAFE_130 = 0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552;
    address constant SAFE_FACTORY_141 = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address constant SAFE_141 = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    uint256 constant SIGNER_A = 0xA11CE;
    uint256 constant SIGNER_B = 0xB0B;

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
        factory = new IndexFactory(address(this), address(0));
        zap = new IndexZap(factory, IUniversalRouter(A.UNIVERSAL_ROUTER));

        // Listed with their units as their supplies, so k = K gives exactly the units the suite's amounts use.
        factory.proposeListing(A.WBTC, U_WBTC);
        factory.proposeListing(A.WETH, U_WETH);
        factory.proposeListing(A.LINK, U_LINK);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(A.WBTC);
        factory.executeListing(A.WETH);
        factory.executeListing(A.LINK);
    }

    function _create(address a, address b) internal returns (IndexHub idx) {
        address[] memory t = new address[](2);
        t[0] = a;
        t[1] = b;
        idx = IndexHub(factory.createIndex("Fork Security", "FSEC", t, K));
    }

    function _issue(IndexHub idx, uint256 shares) internal {
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
        IndexHub idx = _create(A.WBTC, A.WETH);
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
        IndexHub idx = _create(A.WBTC, A.WETH);
        _issue(idx, 1e18);

        vm.prank(IUsdtAdmin(A.USDT).owner());
        IUsdtAdmin(A.USDT).setParams(10, 5); // Tether switches on a 0.10% transfer fee

        IIndexZap.BurnLeg[] memory burnLegs = new IIndexZap.BurnLeg[](2);
        burnLegs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDT), v4Path: new PathKey[](0), minAmountOut: 0
        });
        burnLegs[1] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDT), v4Path: new PathKey[](0), minAmountOut: 0
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
            v3Path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDT), v4Path: new PathKey[](0), maxAmountIn: 0
        });
        mintLegs[1] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDT), v4Path: new PathKey[](0), maxAmountIn: 0
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
        IndexHub idx = _create(A.WBTC, A.LINK);
        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](2);
        legs[0] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(A.WBTC, F500, A.WETH), v4Path: new PathKey[](0), maxAmountIn: 0
        });
        legs[1] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(A.LINK, F3000, A.WETH), v4Path: new PathKey[](0), maxAmountIn: 0
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
        IndexHub idx = _create(A.WBTC, A.WETH);
        _issue(idx, 1e18);

        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](2);
        legs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDC), v4Path: new PathKey[](0), minAmountOut: 0
        });
        legs[1] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDC), v4Path: new PathKey[](0), minAmountOut: 0
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

    function _burnToUsdc(IndexHub idx, IIndexZap.BurnLeg[] memory legs) internal returns (uint256 out) {
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
        IndexHub idx = _create(A.WBTC, A.WETH);
        _issue(idx, 1e18);
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](2);
        legs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDC), v4Path: new PathKey[](0), minAmountOut: 0
        });
        legs[1] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDC), v4Path: new PathKey[](0), minAmountOut: 0
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
        IndexHub idx = _create(A.LINK, A.WETH);
        _issue(idx, 1e18);
        PathKey[] memory route = new PathKey[](2);
        route[0] =
            PathKey({intermediateCurrency: address(0), fee: F3000, tickSpacing: 60, hooks: address(0), hookData: ""});
        route[1] = PathKey({intermediateCurrency: A.USDC, fee: F500, tickSpacing: 10, hooks: address(0), hookData: ""});
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](2);
        legs[0] = IIndexZap.BurnLeg({v3Path: "", v4Path: route, minAmountOut: 0});
        legs[1] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(A.WETH, F500, A.USDC), v4Path: new PathKey[](0), minAmountOut: 0
        });

        deal(A.LINK, A.UNIVERSAL_ROUTER, 3e18);
        uint256 out = _burnToUsdc(idx, legs);

        assertGt(out, 0);
        assertEq(IERC20(A.USDC).balanceOf(user), out, "the burn pays out");
        assertEq(IERC20(A.LINK).balanceOf(user), 3e18, "and the stray reaches the recipient");
        assertEq(IERC20(A.LINK).balanceOf(A.UNIVERSAL_ROUTER), 0, "the router is swept clean");
        assertEq(IERC20(A.LINK).balanceOf(address(zap)), 0, "and nothing stays in the zap");
    }

    /// @dev CR-M01. The v3 rule read a token's own live supply whenever its config carried no reference supply, and a
    ///      supply that anyone can move inside one transaction put the targets, and whether a stranger could start a
    ///      rebalance, up for sale. The hub now reads only the factory's reference supplies. WETH's own supply moves one
    ///      for one with every deposit, so wrapping a million ether around a start is the live test: the band a start
    ///      would take does not move by a wei, an index on its supplies still cannot be started, and after a revision
    ///      the band the start stores is the one read before the wrap.
    function test_CRM01_wrappingEtherAroundAStartMovesNothing() public {
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (A.WBTC, A.WETH, A.LINK);
        IndexHub idx = IndexHub(factory.createIndex("Wrapped", "WRP", t, K));
        _issue(idx, 10e18);
        vm.warp(block.timestamp + idx.MIN_REBALANCE_INTERVAL());
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.BandTooNarrow.selector, 1e18, 1e18));
        idx.startRebalance(0);

        _wrap(1_000_000 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.BandTooNarrow.selector, 1e18, 1e18));
        idx.startRebalance(0);

        address[] memory revised = new address[](1);
        uint256[] memory supplies = new uint256[](1);
        (revised[0], supplies[0]) = (A.WETH, U_WETH + U_WETH / 200);
        factory.proposeSupplies(revised, supplies);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeSupplies();
        (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax) = idx.previewBand(0);
        assertGt(lambdaMax, lambdaMin, "the revision opens a band");

        _wrap(1_000_000 ether);
        (uint256[] memory ratiosAfter, uint256 minAfter, uint256 maxAfter) = idx.previewBand(0);
        assertEq(ratiosAfter, ratios, "the wrap moves no ratio");
        assertEq(minAfter, lambdaMin);
        assertEq(maxAfter, lambdaMax);
        vm.prank(stranger);
        idx.startRebalance(0);
        (,, uint256 storedMin, uint256 storedMax, uint256[] memory stored) = idx.pendingRebalance();
        assertEq(stored, ratios, "the start stores the band read before the wrap");
        assertEq(storedMin, lambdaMin);
        assertEq(storedMax, lambdaMax);
    }

    /// @dev Wraps `amount` of fresh ether into WETH, which raises WETH's own total supply by exactly that.
    function _wrap(uint256 amount) internal {
        address wrapper = makeAddr("wrapper");
        uint256 before = IERC20(A.WETH).totalSupply();
        vm.deal(wrapper, amount);
        vm.prank(wrapper);
        IWETH9(A.WETH).deposit{value: amount}();
        assertEq(IERC20(A.WETH).totalSupply(), before + amount, "WETH's live supply moves with the wrap");
    }

    /// @dev XA-07, CR-I36. The module check reads the page of modules that starts at the sentinel, and the offline mock
    ///      only learned to honour `start` in this review, so the real Safe is the proof: a 2-of-2 Safe without modules
    ///      is accepted as an owner, and the same Safe with one module enabled is refused, on 1.3.0, which answers any
    ///      other start with an empty page, and on 1.4.1, which refuses one.
    function test_XA07_CRI36_aRealSafeWithAModuleIsRefused() public {
        Deploy deployer = new Deploy();
        address module = makeAddr("module");
        address[2] memory factories = [SAFE_FACTORY_130, SAFE_FACTORY_141];
        address[2] memory singletons = [SAFE_130, SAFE_141];
        for (uint256 i = 0; i < factories.length; ++i) {
            ISafe safe = _twoOfTwoSafe(factories[i], singletons[i]);
            deployer.checkOwner(address(safe));
            _enableModule(safe, module);
            vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerHasModules.selector, address(safe), module));
            deployer.checkOwner(address(safe));
        }
    }

    function _twoOfTwoSafe(address safeFactory, address singleton) internal returns (ISafe) {
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = (vm.addr(SIGNER_A), vm.addr(SIGNER_B));
        bytes memory init =
            abi.encodeCall(ISafe.setup, (owners, 2, address(0), "", address(0), address(0), 0, payable(address(0))));
        return ISafe(ISafeProxyFactory(safeFactory).createProxyWithNonce(singleton, init, 0));
    }

    /// @dev Enables `module` the way a real one is: a Safe transaction to itself, signed by both owners in the
    ///      ascending order the Safe requires.
    function _enableModule(ISafe safe, address module) internal {
        bytes memory data = abi.encodeCall(ISafe.enableModule, (module));
        bytes32 hash = safe.getTransactionHash(address(safe), 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        (uint256 first, uint256 second) =
            vm.addr(SIGNER_A) < vm.addr(SIGNER_B) ? (SIGNER_A, SIGNER_B) : (SIGNER_B, SIGNER_A);
        bytes memory signatures = abi.encodePacked(_signature(first, hash), _signature(second, hash));
        assertTrue(
            safe.execTransaction(address(safe), 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures)
        );
    }

    function _signature(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 sig) = vm.sign(key, hash);
        return abi.encodePacked(r, sig, v);
    }
}
