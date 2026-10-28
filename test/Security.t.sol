// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {XindexTest} from "./XindexTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexZap} from "../src/interfaces/IIndexZap.sol";
import {IUniversalRouterSwaps} from "../src/interfaces/IUniversalRouterSwaps.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IRebalanceExecutor} from "../src/interfaces/IRebalanceExecutor.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockHookToken, ITokenReceiverHook} from "./mocks/MockHookToken.sol";
import {MockPausableToken} from "./mocks/MockPausableToken.sol";
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {PathKey} from "../src/libraries/UniswapV4Types.sol";
import {PythStructs} from "../src/interfaces/pyth/PythStructs.sol";

/// @notice Watches an index from inside a token callback, the way a third-party protocol could.
contract NavProbe is ITokenReceiverHook {
    WeightedHub public immutable index;
    ERC20 public immutable weth;

    uint256 public seenSupply;
    uint256 public seenWethInIndex;
    uint256 public seenWethPerShare;
    bool public issueReentryBlocked;
    bool public redeemReentryBlocked;

    constructor(WeightedHub index_, ERC20 weth_) {
        index = index_;
        weth = weth_;
    }

    function redeemAll() external {
        index.redeem(index.balanceOf(address(this)), address(this));
    }

    function onTokenReceived(address, uint256) external {
        seenSupply = index.totalSupply();
        seenWethInIndex = weth.balanceOf(address(index));
        seenWethPerShare = index.previewRedeem(1e18)[1];
        (bool issued, bytes memory issueError) =
            address(index).call(abi.encodeWithSignature("issue(uint256,address)", 1, address(this)));
        issueReentryBlocked = !issued && bytes4(issueError) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        (bool redeemed, bytes memory redeemError) =
            address(index).call(abi.encodeCall(WeightedHub.redeem, (1, address(this))));
        redeemReentryBlocked = !redeemed && bytes4(redeemError) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
    }
}

/// @notice Fills an auction after issuing extra shares in the same transaction and redeems them afterwards, to show
///         that a larger supply does not let an executor take more than the auction discount.
contract FlashFiller is IRebalanceExecutor {
    uint256 public spent;

    /// @return pnl Raw units the filler ends with minus raw units it minted, summed over the components.
    function fill(WeightedHub index, uint256 shares, bytes[] calldata priceUpdate) external returns (int256 pnl) {
        address[] memory t = index.componentTokens();
        if (shares != 0) {
            uint256[] memory need = index.previewIssue(shares);
            for (uint256 i = 0; i < t.length; ++i) {
                MockERC20(t[i]).mint(address(this), need[i]);
                MockERC20(t[i]).approve(address(index), need[i]);
                spent += need[i];
            }
            index.issue(shares, address(this));
        }
        index.executeRebalance("", priceUpdate);
        if (shares != 0) index.redeem(shares, address(this));
        uint256 held = 0;
        for (uint256 i = 0; i < t.length; ++i) {
            held += MockERC20(t[i]).balanceOf(address(this));
        }
        pnl = int256(held) - int256(spent);
    }

    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory t = WeightedHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (amountsIn[i] == 0) continue;
            MockERC20(t[i]).mint(msg.sender, amountsIn[i]);
            spent += amountsIn[i];
        }
    }
}

/// @notice XA-62: an integrator's single interface over the factory and the hub. It compiles only while the two
///         interfaces declare their common errors once, in a shared base, instead of each declaring them again.
interface IXindexCore is IWeightedIndexFactory, IWeightedHub {
    function MIN_COMPONENTS() external view override(IWeightedIndexFactory, IWeightedHub) returns (uint256);
    function MAX_COMPONENTS() external view override(IWeightedIndexFactory, IWeightedHub) returns (uint256);
    function TOTAL_WEIGHT() external view override(IWeightedIndexFactory, IWeightedHub) returns (uint256);
    function PYTH() external view override(IWeightedIndexFactory, IWeightedHub) returns (address);
    function MIN_REBALANCE_INTERVAL() external view override(IWeightedIndexFactory, IWeightedHub) returns (uint256);
}

/// @notice One regression test per finding of the Xindex v1 security review and of the v2 rebalancing design review,
///         each asserting the fixed behaviour, plus the attacks that already failed before the fixes. Every index is a
///         `WeightedHub` (v5); `audit/2026-10-06-v4-retirement.md` says which ids went with v4's market-cap hub.
contract SecurityRegressionTest is XindexTest {
    MockUniversalRouter router;
    address poolManager;
    IndexZap zap;
    WeightedHub index;

    MockERC20 wbtc; // 8
    MockERC20 weth; // 18
    MockERC20 link; // 18
    MockERC20 usdc; // 6

    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    uint24 constant FEE = 500;
    uint256 constant NAV_USD6 = 105e6; // 0.001 WBTC ($60) + 0.01 WETH ($30) + 1 LINK ($15)
    /// @dev The smallest holding an index may start with, the factory's `MIN_RAW_UNITS`: 0.01 USDC beside a basket
    ///      that would otherwise be one component, since an index holds two at least.
    uint256 constant U_DUST = 1e4;

    function setUp() public {
        market = new MockMarket();
        _deployFactory(guardian);
        poolManager = makeAddr("poolManager");
        router = new MockUniversalRouter(poolManager);
        zap = new IndexZap(IIndexFactory(address(factory)), router);

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = market.weth();
        link = new MockERC20("Chainlink", "LINK", 18);
        usdc = market.usdc();

        router.setPrice(address(wbtc), 60_000e18, 8);
        router.setPrice(address(weth), 3_000e18, 18);
        router.setPrice(address(link), 15e18, 18);
        router.setPrice(address(usdc), 1e18, 6);
        wbtc.mint(address(router.inventory()), 1_000e8);
        weth.mint(address(router.inventory()), 100_000e18);
        link.mint(address(router.inventory()), 10_000_000e18);
        usdc.mint(address(router.inventory()), 1_000_000_000e6);

        _listWith(address(wbtc));
        _listWith(address(weth));
        _listWith(address(link));
        _listWith(address(usdc));

        index = _createIndex("Blue Chip", "BLUE", _blueTokens(), _blueUnits(1));
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _blueTokens() internal view returns (address[] memory t) {
        t = new address[](3);
        t[0] = address(wbtc);
        t[1] = address(weth);
        t[2] = address(link);
    }

    /// @dev 0.001 WBTC, 0.01 WETH and 1 LINK per index token, times `scale`.
    function _blueUnits(uint256 scale) internal pure returns (uint256[] memory u) {
        u = new uint256[](3);
        (u[0], u[1], u[2]) = (100_000 * scale, 1e16 * scale, 1e18 * scale);
    }

    function _mintLegs(address stable) internal view returns (IUniversalRouterSwaps.MintLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.MintLeg[](3);
        legs[0] = IUniversalRouterSwaps.MintLeg({
            v3Path: abi.encodePacked(address(wbtc), FEE, address(weth), FEE, stable),
            v4Path: new PathKey[](0),
            maxAmountIn: 0
        });
        legs[1] = IUniversalRouterSwaps.MintLeg({
            v3Path: abi.encodePacked(address(weth), FEE, stable), v4Path: new PathKey[](0), maxAmountIn: 0
        });
        legs[2] = IUniversalRouterSwaps.MintLeg({
            v3Path: abi.encodePacked(address(link), FEE, address(weth), FEE, stable),
            v4Path: new PathKey[](0),
            maxAmountIn: 0
        });
    }

    function _burnLegs(address tokenOut) internal view returns (IUniversalRouterSwaps.BurnLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.BurnLeg[](3);
        legs[0] = IUniversalRouterSwaps.BurnLeg({
            v3Path: abi.encodePacked(address(wbtc), FEE, address(weth), FEE, tokenOut),
            v4Path: new PathKey[](0),
            minAmountOut: 0
        });
        legs[1] = IUniversalRouterSwaps.BurnLeg({
            v3Path: abi.encodePacked(address(weth), FEE, tokenOut), v4Path: new PathKey[](0), minAmountOut: 0
        });
        legs[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: abi.encodePacked(address(link), FEE, address(weth), FEE, tokenOut),
            v4Path: new PathKey[](0),
            minAmountOut: 0
        });
    }

    function _mintParams(
        address idx,
        address tokenIn,
        uint256 maxIn,
        uint256 shares,
        IUniversalRouterSwaps.MintLeg[] memory legs,
        address to
    ) internal view returns (IIndexZap.MintParams memory) {
        return IIndexZap.MintParams({
            index: idx,
            expectedNonce: 0,
            tokenIn: tokenIn,
            maxAmountIn: maxIn,
            shares: shares,
            legs: legs,
            to: to,
            deadline: block.timestamp,
            referrer: address(0)
        });
    }

    function _burnParams(
        address idx,
        uint256 shares,
        address tokenOut,
        uint256 minOut,
        IUniversalRouterSwaps.BurnLeg[] memory legs,
        address to
    ) internal view returns (IIndexZap.BurnParams memory) {
        return IIndexZap.BurnParams({
            index: idx,
            expectedNonce: 0,
            shares: shares,
            tokenOut: tokenOut,
            minAmountOut: minOut,
            legs: legs,
            to: to,
            deadline: block.timestamp
        });
    }

    function _issueBlue(address who, uint256 shares) internal {
        uint256[] memory need = index.previewIssue(shares);
        wbtc.mint(who, need[0]);
        weth.mint(who, need[1]);
        link.mint(who, need[2]);
        vm.startPrank(who);
        wbtc.approve(address(index), need[0]);
        weth.approve(address(index), need[1]);
        link.approve(address(index), need[2]);
        index.issue(shares, who);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Medium and Low findings
    // ---------------------------------------------------------------------

    function test_M01_frozenComponentNoLongerLocksTheBasket() public {
        MockPausableToken pbtc = new MockPausableToken("Pausable BTC", "pBTC", 8);
        _listWith(address(pbtc));
        WeightedHub idx = _createIndex("Half Paused", "HALF", _pair(address(pbtc), address(weth)), _pair(100_000, 1e16));

        pbtc.mint(alice, 100_000);
        weth.mint(alice, 1e16);
        vm.startPrank(alice);
        pbtc.approve(address(idx), 100_000);
        weth.approve(address(idx), 1e16);
        idx.issue(1e18, alice);
        vm.stopPrank();

        pbtc.setPaused(true);

        vm.startPrank(alice);
        vm.expectRevert(bytes("paused"));
        idx.redeem(1e18, alice);

        idx.redeemSkipping(1e18, alice, 1 << 0);
        assertEq(weth.balanceOf(alice), 1e16, "the unpaused half comes out now");
        assertEq(idx.claimOf(alice, address(pbtc)), 100_000);

        vm.expectRevert(bytes("paused"));
        idx.claim(address(pbtc), alice);
        vm.stopPrank();

        pbtc.setPaused(false);
        vm.prank(alice);
        idx.claim(address(pbtc), alice);
        assertEq(pbtc.balanceOf(alice), 100_000, "the frozen half is paid once transfers resume");
        assertEq(idx.totalClaims(address(pbtc)), 0);
    }

    function test_L01_uninitializedInstancesCannotMint() public {
        WeightedHub impl = WeightedHub(factory.IMPLEMENTATION());
        WeightedHub rogue = WeightedHub(Clones.clone(address(impl)));
        vm.startPrank(attacker);
        vm.expectRevert(IWeightedHub.NotInitialized.selector);
        impl.issue(1_000_000e18, attacker);
        vm.expectRevert(IWeightedHub.NotInitialized.selector);
        rogue.issue(42e18, attacker);
        vm.stopPrank();
        assertEq(impl.totalSupply(), 0);
        assertEq(rogue.totalSupply(), 0);
    }

    function test_L02_reorgCannotSwapTheBasketBehindAnAddress() public {
        IWeightedIndexFactory.ComponentSpec[] memory specs = _specs(_blueTokens(), _blueUnits(1));
        address creatorA = makeAddr("creatorA");
        address creatorB = makeAddr("creatorB");

        uint256 snap = vm.snapshotState();
        vm.prank(creatorA);
        address seen = factory.createIndex("Bitcoin Heavy", "BTCH", specs, _params());

        // Re-org: creator B's createIndex is included first on the canonical chain.
        vm.revertToState(snap);
        vm.prank(creatorB);
        address other = factory.createIndex("Ether Heavy", "ETHH", _specs(_blueTokens(), _blueUnits(2)), _params());
        assertTrue(other != seen, "a different basket can never land at the address the user saw");

        // Until creator A's transaction is included again, the user's mint to `seen` cannot execute.
        uint256 maxIn = NAV_USD6 + NAV_USD6 / 100;
        usdc.mint(alice, maxIn);
        vm.startPrank(alice);
        usdc.approve(address(zap), maxIn);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, seen));
        zap.mintWithToken(_mintParams(seen, address(usdc), maxIn, 1e18, _mintLegs(address(usdc)), alice));
        vm.stopPrank();

        vm.prank(creatorA);
        assertEq(factory.createIndex("Bitcoin Heavy", "BTCH", specs, _params()), seen);
        assertEq(WeightedHub(seen).symbol(), "BTCH");
    }

    function test_L03_legLimitStopsASandwichOnOneLeg() public {
        uint256 maxIn = NAV_USD6 + NAV_USD6 / 100;
        IUniversalRouterSwaps.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[0].maxAmountIn = 60_600_000;
        legs[1].maxAmountIn = 30_300_000;
        legs[2].maxAmountIn = 15_150_000;
        usdc.mint(alice, maxIn);
        vm.prank(alice);
        usdc.approve(address(zap), maxIn);

        router.setPrice(address(link), 16.05e18, 18); // +7% on the thin LINK leg only

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("V3TooMuchRequested()"));
        zap.mintWithToken(_mintParams(address(index), address(usdc), maxIn, 1e18, legs, alice));
    }

    function test_L04_zeroOutputLimitRejected() public {
        _issueBlue(alice, 1e18);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 0, _burnLegs(address(usdc)), alice));
        vm.stopPrank();
    }

    function test_L05_listingRequiresContractCode() public {
        address typo = makeAddr("typo");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NotAContract.selector, typo));
        factory.proposeListing(typo, _priceId(typo));
    }

    function test_L07_hostileListingWaitsAndGuardianCanCancel() public {
        MockERC20 hostile = new MockERC20("Blue Chip Plus", "BLUE+", 18);
        vm.prank(owner);
        factory.proposeListing(address(hostile), _priceId(address(hostile)));
        uint256 eta = factory.listingEta(address(hostile));
        assertEq(eta, block.timestamp + 2 days);

        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.ListingNotReady.selector, address(hostile), eta));
        factory.executeListing(address(hostile));

        vm.prank(guardian);
        factory.cancelListing(address(hostile));
        vm.warp(eta);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NoPendingListing.selector, address(hostile)));
        factory.executeListing(address(hostile));
        assertFalse(factory.isWhitelisted(address(hostile)));
    }

    function test_FR02_guardianCannotBeSilencedWithoutAWeekOfNotice() public {
        MockERC20 hostile = new MockERC20("Blue Chip Plus", "BLUE+", 18);
        vm.startPrank(owner); // a compromised owner tries to remove the guardian and list at the same time
        factory.proposeGuardian(address(0));
        factory.proposeListing(address(hostile), _priceId(address(hostile)));
        vm.stopPrank();
        assertEq(factory.guardian(), guardian, "the guardian keeps its powers while its removal is pending");

        vm.prank(guardian);
        factory.cancelListing(address(hostile));

        uint256 guardianEta = factory.pendingGuardianEta();
        assertEq(guardianEta, block.timestamp + 7 days);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.GuardianChangeNotReady.selector, guardianEta));
        factory.executeGuardianChange();
        assertFalse(factory.isWhitelisted(address(hostile)));
    }

    function test_FR03_staleListingProposalsExpire() public {
        MockERC20 token = new MockERC20("Stale", "STALE", 18);
        vm.prank(owner);
        factory.proposeListing(address(token), _priceId(address(token)));
        uint256 deadline = factory.listingEta(address(token)) + factory.PROPOSAL_WINDOW();

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.ListingExpired.selector, address(token), deadline));
        factory.executeListing(address(token));

        vm.prank(owner); // proposing again restarts the public delay
        factory.proposeListing(address(token), _priceId(address(token)));
        assertEq(factory.listingEta(address(token)), block.timestamp + factory.LISTING_DELAY());
    }

    // ---------------------------------------------------------------------
    // Informational findings
    // ---------------------------------------------------------------------

    function test_I01_callbackTokenCannotReenter_andUnitValuationStaysExact() public {
        MockHookToken hook = new MockHookToken();
        _listWith(address(hook)); // deliberately breaks the whitelist policy to exercise the worst case

        // A whole unit of each.
        WeightedHub idx = _createIndex("Hooked", "HOOKD", _pair(address(hook), address(weth)), _pair(1e18, 1e18));

        hook.mint(alice, 2e18);
        weth.mint(alice, 2e18);
        vm.startPrank(alice);
        hook.approve(address(idx), 2e18);
        weth.approve(address(idx), 2e18);
        idx.issue(2e18, alice);
        NavProbe probe = new NavProbe(idx, weth);
        idx.transfer(address(probe), 1e18);
        vm.stopPrank();

        probe.redeemAll();

        assertTrue(probe.issueReentryBlocked());
        assertTrue(probe.redeemReentryBlocked());
        // Mid-call, balances and supply disagree, which is why integrators must not price from them...
        assertEq(probe.seenSupply(), 1e18);
        assertEq(probe.seenWethInIndex(), 2e18);
        // ...while the units-based view the docs prescribe is exact at every moment.
        assertEq(probe.seenWethPerShare(), 1e18);
    }

    function test_I02_feeChargingCurrenciesRevertEarlyWithAClearError() public {
        MockFeeToken fot = new MockFeeToken();
        router.setPrice(address(fot), 1e18, 18);
        fot.mint(address(router.inventory()), 1_000_000e18);
        fot.mint(alice, 200e18);

        vm.startPrank(alice);
        fot.approve(address(zap), 200e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.TransferShortfall.selector, address(fot)));
        zap.mintWithToken(_mintParams(address(index), address(fot), 200e18, 1e18, _mintLegs(address(fot)), alice));
        vm.stopPrank();

        _issueBlue(alice, 1e18);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.TransferShortfall.selector, address(fot)));
        zap.burnToToken(_burnParams(address(index), 1e18, address(fot), 1, _burnLegs(address(fot)), alice));
        index.redeem(1e18, alice); // the in-kind exit is unaffected
        vm.stopPrank();
        assertEq(wbtc.balanceOf(alice), 100_000);
    }

    function test_I04_indexAndZapRejectThemselvesAsRecipient() public {
        _issueBlue(alice, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        index.redeem(1e18, address(index));

        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(zap)));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), address(zap)));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), address(index)));
        vm.stopPrank();
    }

    function test_I05_shortBudgetRevertsWithANamedError() public {
        WeightedHub idx = _createIndex("Mixed", "MIX", _pair(address(weth), address(usdc)), _pair(1e16, 50e6));

        IUniversalRouterSwaps.MintLeg[] memory legs = new IUniversalRouterSwaps.MintLeg[](2);
        legs[0] = IUniversalRouterSwaps.MintLeg({
            v3Path: abi.encodePacked(address(weth), FEE, address(usdc)), v4Path: new PathKey[](0), maxAmountIn: 0
        });
        legs[1] = IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: new PathKey[](0), maxAmountIn: 0});

        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientBudget.selector, 50e6, 10e6));
        zap.mintWithToken(_mintParams(address(idx), address(usdc), 10e6, 1e18, legs, alice));
        vm.stopPrank();
    }

    function test_I06_ownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(IWeightedIndexFactory.RenounceDisabled.selector);
        factory.renounceOwnership();
        assertEq(factory.owner(), owner);
    }

    function test_I07_burnWithPermitInOneTransaction() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        _issueBlue(signer, 1e18);
        IIndexZap.BurnParams memory p =
            _burnParams(address(index), 1e18, address(usdc), NAV_USD6, _burnLegs(address(usdc)), signer);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(zap),
                1e18,
                index.nonces(signer),
                p.deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", index.DOMAIN_SEPARATOR(), structHash)));

        vm.prank(signer);
        assertEq(zap.burnToTokenWithPermit(p, v, r, s), NAV_USD6);
        assertEq(usdc.balanceOf(signer), NAV_USD6);
    }

    function test_I08_creatorIsRecordedAndCopiesLandElsewhere() public {
        address creator = makeAddr("creator");
        address copier = makeAddr("copier");
        IWeightedIndexFactory.ComponentSpec[] memory t = _specs(_blueTokens(), _blueUnits(1));

        vm.prank(copier); // front-runs with identical arguments
        address copy = factory.createIndex("Original", "ORIG", t, _params());
        vm.prank(creator);
        address original = factory.createIndex("Original", "ORIG", t, _params());

        assertTrue(copy != original);
        assertEq(factory.creatorOf(original), creator);
        assertEq(factory.creatorOf(copy), copier);
        assertEq(original, factory.predictIndexAddress(creator, "Original", "ORIG", t, _params()));
    }

    function test_I12_partialFillReturnsTheUnsoldPartToTheRecipient() public {
        router.setMode(MockUniversalRouter.Mode.PartialFirstHop);
        IndexZap halfZap = zap;

        // A whole WETH a token, and USDC's smallest holding, paid out as it is on a burn to USDC.
        WeightedHub idx = _createIndex("Ether", "ETH1", _pair(address(weth), address(usdc)), _pair(1e18, U_DUST));

        weth.mint(alice, 1e18);
        usdc.mint(alice, U_DUST);
        vm.startPrank(alice);
        weth.approve(address(idx), 1e18);
        usdc.approve(address(idx), U_DUST);
        idx.issue(1e18, alice);
        idx.approve(address(halfZap), 1e18);
        IUniversalRouterSwaps.BurnLeg[] memory legs = new IUniversalRouterSwaps.BurnLeg[](2);
        legs[0] = IUniversalRouterSwaps.BurnLeg({
            v3Path: abi.encodePacked(address(weth), FEE, address(usdc)), v4Path: new PathKey[](0), minAmountOut: 0
        });
        legs[1] = IUniversalRouterSwaps.BurnLeg({v3Path: "", v4Path: new PathKey[](0), minAmountOut: 0});
        uint256 out = halfZap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1_000e6, legs, alice));
        vm.stopPrank();

        assertEq(out, 1_500e6 + U_DUST);
        assertEq(weth.balanceOf(alice), 5e17, "the unsold half is returned, not stranded");
        assertEq(weth.balanceOf(address(halfZap)), 0);
        assertEq(idx.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------------
    // Controls that held before the fixes and must keep holding
    // ---------------------------------------------------------------------

    function test_control_approvalsToZapCannotBeSpentByOthers() public {
        _issueBlue(alice, 1e18);
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), type(uint256).max);
        index.approve(address(zap), type(uint256).max);
        vm.stopPrank();

        IIndexZap.MintParams memory mint =
            _mintParams(address(index), address(usdc), 1_000e6, 1e18, _mintLegs(address(usdc)), attacker);
        IIndexZap.BurnParams memory burn =
            _burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), attacker);
        vm.startPrank(attacker);
        // Alice's approvals let the zap pull only from whoever calls it: the attacker has approved nothing.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(zap), 0, 1_000e6)
        );
        zap.mintWithToken(mint);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(zap), 0, 1e18));
        zap.burnToToken(burn);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1_000e6);
        assertEq(index.balanceOf(alice), 1e18);
    }

    function test_control_donationsCannotMoveRedemptionValue() public {
        _issueBlue(alice, 1e18);
        uint256[] memory before = index.previewRedeem(1e18);

        wbtc.mint(address(index), 1_000e8); // $60M donation or manipulation attempt
        uint256[] memory afterDonation = index.previewRedeem(1e18);
        assertEq(afterDonation[0], before[0]);

        vm.prank(alice);
        index.redeem(1e18, alice);
        assertEq(wbtc.balanceOf(alice), 100_000, "redeem pays units, never balances");
    }

    function test_control_flashRoundTripExtractsNothing() public {
        _issueBlue(attacker, 1_000_000e18);
        uint256[] memory paid = index.previewIssue(1_000_000e18);
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 100; ++i) {
            index.redeem(10_000e18 - 1, attacker); // odd sizes to hunt rounding
        }
        index.redeem(index.balanceOf(attacker), attacker);
        vm.stopPrank();
        assertLe(wbtc.balanceOf(attacker), paid[0]);
        assertLe(weth.balanceOf(attacker), paid[1]);
        assertLe(link.balanceOf(attacker), paid[2]);
    }

    // ---------------------------------------------------------------------
    // v2 rebalancing (design review of 2026-09-16), re-targeted to the weighted auction. The ids whose v5 test lives
    // in the weighted hub's own suites, and those retired with the λ band, are listed in the v4 retirement record.
    // ---------------------------------------------------------------------

    uint256 constant UNITS = 100e18;

    /// @dev Five fresh 18-decimal tokens at 100e18 units and a fifth of the weight each, ten shares issued to alice. At
    ///      a dollar each the basket sits on its weights.
    function _basket() internal returns (WeightedHub idx, address[] memory t) {
        t = new address[](5);
        uint256[] memory u = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            t[i] = address(new MockERC20("Basket", "BSK", 18));
            u[i] = UNITS;
            _listWith(t[i]);
        }
        idx = _createIndex("Basket", "BSK", t, u);
        _issueBasket(idx, alice, 10e18);
    }

    function _issueBasket(WeightedHub idx, address who, uint256 shares) internal {
        address[] memory t = idx.componentTokens();
        uint256[] memory need = idx.previewIssue(shares);
        vm.startPrank(who);
        for (uint256 i = 0; i < t.length; ++i) {
            MockERC20(t[i]).mint(who, need[i]);
            MockERC20(t[i]).approve(address(idx), need[i]);
        }
        idx.issue(shares, who);
        vm.stopPrank();
    }

    /// @dev Starts a rebalance as `caller` at the first moment it may, and warps `into` seconds into its auction.
    function _openAuction(WeightedHub idx, uint256 keepMask, address caller, uint256 into)
        internal
        returns (uint256 eta)
    {
        uint256 earliest = idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL();
        if (idx.restartAllowedAt() > earliest) earliest = idx.restartAllowedAt();
        if (block.timestamp < earliest) vm.warp(earliest);
        bytes[] memory live = pyth.liveUpdates(idx, keepMask);
        vm.prank(caller);
        idx.startRebalance(keepMask, live);
        (eta,) = idx.pendingRebalance();
        vm.warp(eta + into);
    }

    /// @dev Pyth updates at the index's price time: the first component at 90 cents and the rest at a dollar, so a fill
    ///      buys the first and sells the others. Pyth ignores an update for a feed the hub does not ask for.
    function _cheapFirst(WeightedHub idx, address[] memory t) internal view returns (bytes[] memory data) {
        uint64 time = uint64(idx.priceTime());
        data = new bytes[](t.length);
        for (uint256 i = 0; i < t.length; ++i) {
            data[i] = pyth.update(_priceId(t[i]), i == 0 ? int64(0.9e8) : int64(1e8), 0, -8, time, time - 1);
        }
    }

    /// @dev The same prices as Pyth structs, for `previewRebalance`.
    function _cheapFirstStructs(address[] memory t) internal pure returns (PythStructs.Price[] memory prices) {
        prices = new PythStructs.Price[](t.length);
        for (uint256 i = 0; i < t.length; ++i) {
            prices[i] =
                PythStructs.Price({price: i == 0 ? int64(0.9e8) : int64(1e8), conf: 0, expo: -8, publishTime: 0});
        }
    }

    function test_R09_untouchedComponentsNeverMoveEvenWithDustOrDonations() public {
        (WeightedHub idx, address[] memory t) = _basket();
        _issueBasket(idx, attacker, 1e18 + 1);
        MockERC20(t[3]).mint(address(idx), 12_345);
        uint256 balanceBefore = MockERC20(t[3]).balanceOf(address(idx));

        _openAuction(idx, 1 << 3, guardian, idx.AUCTION_DURATION() / 2);
        (,, uint256[] memory out, uint256[] memory amountsIn) = idx.previewRebalance(_cheapFirstStructs(t));
        assertEq(out[3], 0);
        assertEq(amountsIn[3], 0);
        new MockWeightedExecutor().execute(idx, "", _cheapFirst(idx, t));
        assertEq(MockERC20(t[3]).balanceOf(address(idx)), balanceBefore);
        assertEq(idx.rebalanceNonce(), 1);
    }

    function test_R12_flashIssuingAroundAFillExtractsNothing() public {
        (WeightedHub idx, address[] memory t) = _basket();
        _openAuction(idx, 0, attacker, idx.AUCTION_DURATION() * 3 / 4);
        bytes[] memory updates = _cheapFirst(idx, t);

        uint256 snapshot = vm.snapshotState();
        int256 plain = new FlashFiller().fill(idx, 0, updates);
        vm.revertToState(snapshot);
        int256 withFlashShares = new FlashFiller().fill(idx, 1_000_000e18, updates);
        // The extra shares bear exactly what they earn: the filler gains what it would without them, to the raw units
        // of rounding its issue and redemption take.
        assertApproxEqAbs(withFlashShares, plain, 10, "flash shares extract nothing");
    }

    function test_R13_claimsSurviveRebalancesInBothDirections() public {
        (WeightedHub idx, address[] memory t) = _basket();
        vm.prank(alice);
        idx.redeemSkipping(2e18, alice, (1 << 0) | (1 << 2)); // a growing and a shrinking component
        _openAuction(idx, 0, attacker, idx.AUCTION_DURATION() / 2);
        new MockWeightedExecutor().execute(idx, "", _cheapFirst(idx, t));
        (, uint256[] memory units) = idx.components();
        assertGt(units[0], UNITS, "the first component grew");
        assertLt(units[2], UNITS, "and the third shrank");

        vm.startPrank(alice);
        assertEq(idx.claim(t[0], alice), 200e18);
        assertEq(idx.claim(t[2], alice), 200e18);
        vm.stopPrank();
    }

    function test_R20_zapRefusesAQuoteFromBeforeARebalance() public {
        (WeightedHub idx, address[] memory t) = _basket();
        _openAuction(idx, 0, attacker, 0);
        new MockWeightedExecutor().execute(idx, "", _cheapFirst(idx, t));

        IIndexZap.BurnParams memory p =
            _burnParams(address(idx), 1e18, address(usdc), 1, new IUniversalRouterSwaps.BurnLeg[](5), alice);
        vm.startPrank(alice);
        idx.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 0, 1));
        zap.burnToToken(p);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Whole-repo audit of 2026-09-16 (XA ids, audit/2026-09-16-whole-repo-audit.md)
    // ---------------------------------------------------------------------

    /// @dev XA-03, re-targeted: relisting always takes a fresh proposal and delay. A whitelisted token cannot take a
    ///      listing proposal at all, so no proposal made while it was listed can relist it after a delist.
    function test_XA03_relistingAlwaysTakesAFreshProposal() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.AlreadyListed.selector, address(link)));
        factory.proposeListing(address(link), _priceId(address(link)));

        vm.prank(guardian);
        factory.delist(address(link));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NoPendingListing.selector, address(link)));
        factory.executeListing(address(link));
        assertFalse(factory.isWhitelisted(address(link)));

        vm.prank(owner);
        factory.proposeListing(address(link), _priceId(address(link)));
        assertEq(factory.listingEta(address(link)), block.timestamp + factory.LISTING_DELAY(), "a fresh delay");
    }

    /// @dev A zap on its own router, which takes half the input of every hop and prices every hop one raw unit for
    ///      one, and an index of a whole LINK beside USDC's smallest holding, which a burn to USDC passes through.
    function _halfFilled() internal returns (WeightedHub idx, IndexZap halfZap) {
        MockUniversalRouter half = new MockUniversalRouter(poolManager);
        half.setMode(MockUniversalRouter.Mode.PartialFirstHop);
        half.setPrice(address(link), 1e18, 18);
        half.setPrice(address(weth), 1e18, 18);
        half.setPrice(address(usdc), 1e18, 18);
        weth.mint(address(half.inventory()), 100e18);
        usdc.mint(address(half.inventory()), 100e18);
        halfZap = new IndexZap(IIndexFactory(address(factory)), half);

        idx = _createIndex("Link One", "LNK1", _pair(address(link), address(usdc)), _pair(1e18, U_DUST));

        link.mint(alice, 1e18);
        usdc.mint(alice, U_DUST);
        vm.startPrank(alice);
        link.approve(address(idx), 1e18);
        usdc.approve(address(idx), U_DUST);
        idx.issue(1e18, alice);
        idx.approve(address(halfZap), 1e18);
        vm.stopPrank();
    }

    /// @dev Burn legs for `_halfFilled`'s index: LINK along `v3Path`, USDC passed through.
    function _halfLegs(bytes memory v3Path) internal pure returns (IUniversalRouterSwaps.BurnLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.BurnLeg[](2);
        legs[0] = IUniversalRouterSwaps.BurnLeg({v3Path: v3Path, v4Path: new PathKey[](0), minAmountOut: 0});
        legs[1] = IUniversalRouterSwaps.BurnLeg({v3Path: "", v4Path: new PathKey[](0), minAmountOut: 0});
    }

    function test_XA08_aLaterHopsUnsoldInputReachesTheRecipient() public {
        (WeightedHub idx, IndexZap halfZap) = _halfFilled();
        IUniversalRouterSwaps.BurnLeg[] memory legs =
            _halfLegs(abi.encodePacked(address(link), FEE, address(weth), FEE, address(usdc)));

        uint256 wethBefore = weth.balanceOf(alice);
        vm.prank(alice);
        uint256 out = halfZap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1, legs, alice));

        assertEq(out, 2.5e17 + U_DUST, "the payout is what the last hop sold, and the USDC held as it is");
        assertEq(link.balanceOf(alice), 5e17, "the first hop's unsold input comes back");
        assertEq(weth.balanceOf(alice) - wethBefore, 2.5e17, "and so does the second hop's");
        assertEq(weth.balanceOf(address(halfZap)), 0);
        assertEq(link.balanceOf(address(halfZap)), 0);
    }

    function test_XA08_unsoldTokenOutIsPaidOutAndAnEmptyHopReverts() public {
        (WeightedHub idx, IndexZap halfZap) = _halfFilled();
        IUniversalRouterSwaps.BurnLeg[] memory legs =
            _halfLegs(abi.encodePacked(address(link), FEE, address(usdc), FEE, address(weth), FEE, address(usdc)));

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out = halfZap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1, legs, alice));

        assertEq(out, 3.75e17 + U_DUST, "0.5 bought, 0.25 sold on, 0.125 bought back, and the USDC held as it is");
        assertEq(usdc.balanceOf(alice) - usdcBefore, 3.75e17 + U_DUST);
        assertEq(usdc.balanceOf(address(halfZap)), 0);
        assertEq(weth.balanceOf(address(halfZap)), 0);

        legs = _halfLegs(abi.encodePacked(address(link), FEE, address(weth), FEE, address(usdc)));
        link.mint(alice, 1);
        usdc.mint(alice, 1);
        vm.startPrank(alice);
        link.approve(address(idx), 1);
        usdc.approve(address(idx), 1);
        idx.issue(1, alice);
        idx.approve(address(halfZap), 1);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientOutput.selector, 0, 0));
        halfZap.burnToToken(_burnParams(address(idx), 1, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    function test_XA59_everyProposalCarriesItsOwnId() public {
        (WeightedHub idx, address[] memory t) = _basket();
        uint256 eta = _openAuction(idx, 0, attacker, 0);
        assertEq(idx.proposalCount(), 1);

        vm.prank(guardian);
        idx.cancelRebalance();
        vm.warp(idx.restartAllowedAt());
        eta = block.timestamp + idx.REBALANCE_DELAY();
        bytes[] memory live = pyth.liveUpdates(idx, 0);
        vm.expectEmit(true, true, true, true, address(idx));
        emit IWeightedHub.RebalanceStarted(2, 1, attacker, 0, eta);
        vm.prank(attacker);
        idx.startRebalance(0, live);

        // The third proposal follows the second's expiry, with no event of its own to mark it.
        vm.warp(eta + idx.AUCTION_DURATION() + idx.REBALANCE_DELAY());
        bytes[] memory live2 = pyth.liveUpdates(idx, 0);
        vm.prank(attacker);
        idx.startRebalance(0, live2);
        assertEq(idx.proposalCount(), 3, "three attempts, all at rebalance nonce 1");
        assertEq(idx.rebalanceNonce(), 0);

        (eta,) = idx.pendingRebalance();
        vm.warp(eta);
        vm.recordLogs();
        new MockWeightedExecutor().execute(idx, "", _cheapFirst(idx, t));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != IWeightedHub.Rebalanced.selector) continue;
            found = true;
            assertEq(uint256(logs[i].topics[1]), 3, "the settled proposal is the third");
            assertEq(uint256(logs[i].topics[2]), 1, "and it takes rebalance nonce 1");
        }
        assertTrue(found);
    }

    function test_XA62_oneInterfaceExtendsTheFactoryAndTheHub() public view {
        IXindexCore core = IXindexCore(address(index));
        assertEq(core.FACTORY(), address(factory), "the combined interface compiles and reads an index");
        assertEq(core.componentCount(), index.componentCount());
    }
}
