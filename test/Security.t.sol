// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "./XindexTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexZap} from "../src/interfaces/IIndexZap.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../src/interfaces/IIndexRule.sol";
import {IIndexToken} from "../src/interfaces/IIndexToken.sol";
import {IRebalanceExecutor} from "../src/interfaces/IRebalanceExecutor.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockHookToken, ITokenReceiverHook} from "./mocks/MockHookToken.sol";
import {MockPartialFillRouter} from "./mocks/MockPartialFillRouter.sol";
import {MockPausableToken} from "./mocks/MockPausableToken.sol";
import {MockRebalanceExecutor} from "./mocks/MockRebalanceExecutor.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3.sol";

/// @notice Watches an index from inside a token callback, the way a third-party protocol could.
contract NavProbe is ITokenReceiverHook {
    IndexToken public immutable index;
    ERC20 public immutable weth;

    uint256 public seenSupply;
    uint256 public seenWethInIndex;
    uint256 public seenWethPerShare;
    bool public issueReentryBlocked;
    bool public redeemReentryBlocked;

    constructor(IndexToken index_, ERC20 weth_) {
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
            address(index).call(abi.encodeCall(IndexToken.issue, (1, address(this))));
        issueReentryBlocked = !issued && bytes4(issueError) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        (bool redeemed, bytes memory redeemError) =
            address(index).call(abi.encodeCall(IndexToken.redeem, (1, address(this))));
        redeemReentryBlocked = !redeemed && bytes4(redeemError) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
    }
}

/// @notice Fills an auction after issuing extra shares in the same transaction and redeems them afterwards, to show
///         that a larger supply does not let an executor take more than the auction discount.
contract FlashFiller is IRebalanceExecutor {
    uint256 public spent;

    /// @return pnl Raw units the filler ends with minus raw units it minted. Every component is worth one WETH per unit.
    function fill(IndexToken index, uint256 shares) external returns (int256 pnl) {
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
        index.executeRebalance("");
        if (shares != 0) index.redeem(shares, address(this));
        uint256 held = 0;
        for (uint256 i = 0; i < t.length; ++i) {
            held += MockERC20(t[i]).balanceOf(address(this));
        }
        pnl = int256(held) - int256(spent);
    }

    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory t = IndexToken(msg.sender).componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (amountsIn[i] == 0) continue;
            MockERC20(t[i]).mint(msg.sender, amountsIn[i]);
            spent += amountsIn[i];
        }
    }
}

/// @notice XA-62: an integrator's single interface over the factory, rule and token. It compiles only while the three
///         interfaces declare their common errors once, in a shared base, instead of each declaring them again.
interface IXindexCore is IIndexFactory, IIndexRule, IIndexToken {
    function FACTORY() external view override(IIndexRule, IIndexToken) returns (address);
    function RULE() external view override(IIndexFactory, IIndexToken) returns (address);
}

/// @notice One regression test per finding of the Xindex v1 security review and of the v2 rebalancing design review,
///         each asserting the fixed behaviour, plus the attacks that already failed before the fixes.
contract SecurityRegressionTest is XindexTest {
    MockSwapRouter router;
    IndexZap zap;
    IndexToken index;

    MockERC20 wbtc; // 8
    MockERC20 weth; // 18
    MockERC20 link; // 18
    MockERC20 usdc; // 6

    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    uint24 constant FEE = 500;
    uint256 constant NAV_USD6 = 105e6; // 0.001 WBTC ($60) + 0.01 WETH ($30) + 1 LINK ($15)

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(
            owner, guardian, address(market.weth()), address(market.uniswapV3Factory()), address(market.usdc())
        );
        router = new MockSwapRouter();
        zap = new IndexZap(factory, router);

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = market.weth();
        link = new MockERC20("Chainlink", "LINK", 18);
        usdc = market.usdc();

        router.setPrice(address(wbtc), 60_000e18);
        router.setPrice(address(weth), 3_000e18);
        router.setPrice(address(link), 15e18);
        router.setPrice(address(usdc), 1e18);
        wbtc.mint(address(router), 1_000e8);
        weth.mint(address(router), 100_000e18);
        link.mint(address(router), 10_000_000e18);
        usdc.mint(address(router), 1_000_000_000e6);

        _list(address(wbtc));
        _list(address(weth));
        _list(address(link));
        _list(address(usdc));

        index = IndexToken(factory.createIndex("Blue Chip", "BLUE", _blueTokens(), _units(100_000, 1e16, 1e18), 0));
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

    function _units(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory u) {
        u = new uint256[](3);
        u[0] = a;
        u[1] = b;
        u[2] = c;
    }

    function _mintLegs(address stable) internal view returns (IIndexZap.MintLeg[] memory legs) {
        legs = new IIndexZap.MintLeg[](3);
        legs[0] =
            IIndexZap.MintLeg({path: abi.encodePacked(address(wbtc), FEE, address(weth), FEE, stable), maxAmountIn: 0});
        legs[1] = IIndexZap.MintLeg({path: abi.encodePacked(address(weth), FEE, stable), maxAmountIn: 0});
        legs[2] =
            IIndexZap.MintLeg({path: abi.encodePacked(address(link), FEE, address(weth), FEE, stable), maxAmountIn: 0});
    }

    function _burnLegs(address tokenOut) internal view returns (IIndexZap.BurnLeg[] memory legs) {
        legs = new IIndexZap.BurnLeg[](3);
        legs[0] = IIndexZap.BurnLeg({
            path: abi.encodePacked(address(wbtc), FEE, address(weth), FEE, tokenOut), minAmountOut: 0
        });
        legs[1] = IIndexZap.BurnLeg({path: abi.encodePacked(address(weth), FEE, tokenOut), minAmountOut: 0});
        legs[2] = IIndexZap.BurnLeg({
            path: abi.encodePacked(address(link), FEE, address(weth), FEE, tokenOut), minAmountOut: 0
        });
    }

    function _mintParams(
        address idx,
        address tokenIn,
        uint256 maxIn,
        uint256 shares,
        IIndexZap.MintLeg[] memory legs,
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
            deadline: block.timestamp
        });
    }

    function _burnParams(
        address idx,
        uint256 shares,
        address tokenOut,
        uint256 minOut,
        IIndexZap.BurnLeg[] memory legs,
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
        _list(address(pbtc));
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        t[0] = address(pbtc);
        t[1] = address(weth);
        u[0] = 100_000;
        u[1] = 1e16;
        IndexToken idx = IndexToken(factory.createIndex("Half Paused", "HALF", t, u, 0));

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
        IndexToken impl = IndexToken(factory.IMPLEMENTATION());
        IndexToken rogue = IndexToken(Clones.clone(address(impl)));
        vm.startPrank(attacker);
        vm.expectRevert(IIndexToken.NotInitialized.selector);
        impl.issue(1_000_000e18, attacker);
        vm.expectRevert(IIndexToken.NotInitialized.selector);
        rogue.issue(42e18, attacker);
        vm.stopPrank();
        assertEq(impl.totalSupply(), 0);
        assertEq(rogue.totalSupply(), 0);
    }

    function test_L02_reorgCannotSwapTheBasketBehindAnAddress() public {
        address[] memory t = _blueTokens();
        uint256[] memory btcHeavy = _units(100_000, 1e16, 1e18);
        uint256[] memory ethHeavy = _units(50_000, 2e16, 1e18);
        address creatorA = makeAddr("creatorA");
        address creatorB = makeAddr("creatorB");

        uint256 snap = vm.snapshotState();
        vm.prank(creatorA);
        address seen = factory.createIndex("Bitcoin Heavy", "BTCH", t, btcHeavy, 0);

        // Re-org: creator B's createIndex is included first on the canonical chain.
        vm.revertToState(snap);
        vm.prank(creatorB);
        address other = factory.createIndex("Ether Heavy", "ETHH", t, ethHeavy, 0);
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
        assertEq(factory.createIndex("Bitcoin Heavy", "BTCH", t, btcHeavy, 0), seen);
        assertEq(IndexToken(seen).symbol(), "BTCH");
    }

    function test_L03_legLimitStopsASandwichOnOneLeg() public {
        uint256 maxIn = NAV_USD6 + NAV_USD6 / 100;
        IIndexZap.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[0].maxAmountIn = 60_600_000;
        legs[1].maxAmountIn = 30_300_000;
        legs[2].maxAmountIn = 15_150_000;
        usdc.mint(alice, maxIn);
        vm.prank(alice);
        usdc.approve(address(zap), maxIn);

        router.setPrice(address(link), 16.05e18); // +7% on the thin LINK leg only

        vm.prank(alice);
        vm.expectRevert("Too much requested");
        zap.mintWithToken(_mintParams(address(index), address(usdc), maxIn, 1e18, legs, alice));
    }

    function test_L04_zeroOutputLimitRejected() public {
        _issueBlue(alice, 1e18);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(IIndexZap.ZeroAmount.selector);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 0, _burnLegs(address(usdc)), alice));
        vm.stopPrank();
    }

    function test_L05_listingRequiresContractCode() public {
        address typo = makeAddr("typo");
        IIndexFactory.TokenConfig memory config;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotAContract.selector, typo));
        factory.proposeListing(typo, config);
    }

    function test_L07_hostileListingWaitsAndGuardianCanCancel() public {
        MockERC20 hostile = new MockERC20("Blue Chip Plus", "BLUE+", 18);
        IIndexFactory.TokenConfig memory config = market.config(address(hostile), 0);
        vm.prank(owner);
        factory.proposeListing(address(hostile), config);
        uint256 eta = factory.listingEta(address(hostile));
        assertEq(eta, block.timestamp + 2 days);

        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingNotReady.selector, address(hostile), eta));
        factory.executeListing(address(hostile));

        vm.prank(guardian);
        factory.cancelListing(address(hostile));
        vm.warp(eta);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(hostile)));
        factory.executeListing(address(hostile));
        assertFalse(factory.isWhitelisted(address(hostile)));
    }

    function test_FR02_guardianCannotBeSilencedWithoutAWeekOfNotice() public {
        MockERC20 hostile = new MockERC20("Blue Chip Plus", "BLUE+", 18);
        vm.startPrank(owner); // a compromised owner tries to remove the guardian and list at the same time
        factory.proposeGuardian(address(0));
        factory.proposeListing(address(hostile), market.config(address(hostile), 0));
        vm.stopPrank();
        assertEq(factory.guardian(), guardian, "the guardian keeps its powers while its removal is pending");

        vm.prank(guardian);
        factory.cancelListing(address(hostile));

        uint256 guardianEta = factory.pendingGuardianEta();
        assertEq(guardianEta, block.timestamp + 7 days);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.GuardianChangeNotReady.selector, guardianEta));
        factory.executeGuardianChange();
        assertFalse(factory.isWhitelisted(address(hostile)));
    }

    function test_FR03_staleListingProposalsExpire() public {
        MockERC20 token = new MockERC20("Stale", "STALE", 18);
        IIndexFactory.TokenConfig memory config = market.config(address(token), 0);
        vm.prank(owner);
        factory.proposeListing(address(token), config);
        uint256 deadline = factory.listingEta(address(token)) + factory.PROPOSAL_WINDOW();

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingExpired.selector, address(token), deadline));
        factory.executeListing(address(token));

        vm.prank(owner); // proposing again restarts the public delay
        factory.proposeListing(address(token), config);
        assertEq(factory.listingEta(address(token)), block.timestamp + factory.LISTING_DELAY());
    }

    // ---------------------------------------------------------------------
    // Informational findings
    // ---------------------------------------------------------------------

    function test_I01_callbackTokenCannotReenter_andUnitValuationStaysExact() public {
        MockHookToken hook = new MockHookToken();
        _list(address(hook)); // deliberately breaks the whitelist policy to exercise the worst case

        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        t[0] = address(hook);
        t[1] = address(weth);
        u[0] = 1e18;
        u[1] = 1e18;
        IndexToken idx = IndexToken(factory.createIndex("Hooked", "HOOKD", t, u, 0));

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
        router.setPrice(address(fot), 1e18);
        fot.mint(address(router), 1_000_000e18);
        fot.mint(alice, 200e18);

        vm.startPrank(alice);
        fot.approve(address(zap), 200e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.TransferShortfall.selector, address(fot)));
        zap.mintWithToken(_mintParams(address(index), address(fot), 200e18, 1e18, _mintLegs(address(fot)), alice));
        vm.stopPrank();

        _issueBlue(alice, 1e18);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.TransferShortfall.selector, address(fot)));
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
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        t[0] = address(weth);
        t[1] = address(usdc);
        u[0] = 1e16;
        u[1] = 50e6;
        IndexToken idx = IndexToken(factory.createIndex("Mixed", "MIX", t, u, 0));

        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](2);
        legs[0] = IIndexZap.MintLeg({path: abi.encodePacked(address(weth), FEE, address(usdc)), maxAmountIn: 0});
        legs[1] = IIndexZap.MintLeg({path: "", maxAmountIn: 0});

        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.InsufficientBudget.selector, 50e6, 10e6));
        zap.mintWithToken(_mintParams(address(idx), address(usdc), 10e6, 1e18, legs, alice));
        vm.stopPrank();
    }

    function test_I06_ownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(IIndexFactory.RenounceDisabled.selector);
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
        address[] memory t = _blueTokens();
        uint256[] memory u = _units(100_000, 1e16, 1e18);

        vm.prank(copier); // front-runs with identical arguments
        address copy = factory.createIndex("Original", "ORIG", t, u, 0);
        vm.prank(creator);
        address original = factory.createIndex("Original", "ORIG", t, u, 0);

        assertTrue(copy != original);
        assertEq(factory.creatorOf(original), creator);
        assertEq(factory.creatorOf(copy), copier);
        assertEq(original, factory.predictIndexAddress(creator, "Original", "ORIG", t, u, 0));
    }

    function test_I12_partialFillReturnsTheUnsoldPartToTheRecipient() public {
        MockPartialFillRouter half = new MockPartialFillRouter(3_000e6);
        usdc.mint(address(half), 1_000_000e6);
        IndexZap halfZap = new IndexZap(factory, half);

        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(weth);
        u[0] = 1e18;
        IndexToken idx = IndexToken(factory.createIndex("Ether", "ETH1", t, u, 0));

        weth.mint(alice, 1e18);
        vm.startPrank(alice);
        weth.approve(address(idx), 1e18);
        idx.issue(1e18, alice);
        idx.approve(address(halfZap), 1e18);
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](1);
        legs[0] = IIndexZap.BurnLeg({path: abi.encodePacked(address(weth), FEE, address(usdc)), minAmountOut: 0});
        uint256 out = halfZap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1_000e6, legs, alice));
        vm.stopPrank();

        assertEq(out, 1_500e6);
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
    // v2: rule-based rebalancing (design review of 2026-09-16)
    // ---------------------------------------------------------------------

    function _five(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[] memory r) {
        r = new uint256[](5);
        (r[0], r[1], r[2], r[3], r[4]) = (a, b, c, d, e);
    }

    function _hundreds() internal pure returns (uint256[] memory) {
        return _five(100e18, 100e18, 100e18, 100e18, 100e18);
    }

    /// @dev Lists `t` with `configs`, creates an uncapped index holding `units`, and issues 10 shares to alice.
    function _ruleBasketOf(address[] memory t, IIndexFactory.TokenConfig[] memory configs, uint256[] memory units)
        internal
        returns (IndexToken idx)
    {
        vm.startPrank(owner);
        for (uint256 i = 0; i < t.length; ++i) {
            factory.proposeListing(t[i], configs[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < t.length; ++i) {
            factory.executeListing(t[i]);
        }
        idx = IndexToken(factory.createIndex("Rule Basket", "RULE", t, units, 0));
        _issueRule(idx, alice, 10e18);
    }

    /// @dev Five fresh 18-decimal tokens worth one WETH each, with reference supplies in the ratio `parts`.
    function _ruleBasket(uint256[] memory parts, uint256[] memory units)
        internal
        returns (IndexToken idx, address[] memory t)
    {
        t = new address[](5);
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](5);
        for (uint256 i = 0; i < 5; ++i) {
            t[i] = address(new MockERC20("Rule", "RULE", 18));
            configs[i] = market.configWith(t[i], 0, parts[i] * 1e24, new address[](0));
        }
        idx = _ruleBasketOf(t, configs, units);
    }

    /// @dev 100 units each while the rule wants the first at 60%: it grows to 200 units and the rest shrink to 75.
    function _surgeBasket() internal returns (IndexToken, address[] memory) {
        return _ruleBasket(_five(6, 1, 1, 1, 1), _hundreds());
    }

    function _issueRule(IndexToken idx, address who, uint256 shares) internal {
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

    /// @dev Starts a rebalance as `caller` at the first allowed moment and warps to the auction's opening.
    function _openAuction(IndexToken idx, uint256 keepMask, address caller) internal returns (uint256 eta) {
        uint256 earliest = idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL();
        if (idx.restartAllowedAt() > earliest) earliest = idx.restartAllowedAt();
        if (block.timestamp < earliest) vm.warp(earliest);
        vm.prank(caller);
        idx.startRebalance(keepMask);
        (eta,,) = idx.pendingRebalance();
        vm.warp(eta);
    }

    function test_R01_meanTickRoundsTowardNegativeInfinity() public {
        MockERC20 token = new MockERC20("Tick", "TICK", 18);
        _list(address(token));
        IIndexRule rule = IIndexRule(factory.RULE());
        bool token0 = address(token) < address(weth);

        market.setPriceTick(address(token), token0 ? int24(-2) : int24(2));
        uint256 floored = rule.price(address(token));
        market.setPriceTick(address(token), token0 ? int24(-1) : int24(1));
        uint256 truncated = rule.price(address(token));

        market.tokenPool(address(token)).setCumulatives(0, -1801); // a mean pool tick of -1.0006
        assertEq(rule.price(address(token)), floored);
        assertTrue(floored != truncated);
    }

    function test_R02_lookAlikePoolIsRejected() public {
        MockERC20 token = new MockERC20("Look", "LOOK", 18);
        market.config(address(token), 0); // the genuine pool exists
        address lookAlike = address(new MockUniswapV3Pool(address(token), address(weth), 3000));
        IIndexFactory.TokenConfig memory config;
        config.pool = lookAlike;
        config.minLiquidity = market.MIN_LIQUIDITY();
        config.referenceSupply = 1e24;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPool.selector, address(token), lookAlike));
        factory.proposeListing(address(token), config);
    }

    function test_R03_poolWithShortPriceHistoryIsRejected() public {
        MockERC20 token = new MockERC20("Short", "SHORT", 18);
        IIndexFactory.TokenConfig memory config = market.config(address(token), 0);
        MockUniswapV3Pool(config.pool).setObservationCardinality(60);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.PoolHistoryTooShort.selector, config.pool, 60));
        factory.proposeListing(address(token), config);
    }

    function test_R04_aLoneExecutorKeepsAtMostTheFloorOfTheBoughtValue() public {
        (IndexToken idx,) = _surgeBasket();
        _openAuction(idx, 0, attacker);
        vm.warp(block.timestamp + idx.AUCTION_DURATION()); // with no competition it waits for the floor
        (,, uint256[] memory out, uint256[] memory amountsIn) = idx.previewRebalance();
        new MockRebalanceExecutor().execute(idx, "");

        // Every component is worth one WETH per unit at the snapshot, so values are plain sums of units.
        uint256 taken = 0;
        uint256 delivered = 0;
        for (uint256 i = 0; i < 5; ++i) {
            taken += out[i];
            delivered += amountsIn[i];
        }
        uint256 boughtAtPar = 1_000e18; // 10 shares times the 100 extra units of the growing component
        assertEq(taken, boughtAtPar, "the value sold equals the value bought at par");
        assertEq(taken - delivered, boughtAtPar / 10, "the executor keeps 10% of the bought value");
        assertLt(taken - delivered, 5_000e18 / 20, "far less than 5% of the whole basket");
    }

    function test_R05_clippedTargetsKeepTheBasketValue() public {
        (IndexToken idx,) = _ruleBasket(_five(2, 3, 5, 8, 89), _five(10e18, 10e18, 160e18, 10e18, 10e18));
        (uint256[] memory targets, uint256 turnover) = idx.previewTarget(0);
        uint256 value = 0;
        for (uint256 i = 0; i < 5; ++i) {
            value += targets[i];
        }
        assertEq(value, 200e18, "four redistribution passes, no value lost to the clips");
        assertEq(targets[2], 120e18);
        assertEq(turnover, 0.2e18);
    }

    function test_R06_cappedMethodologyNeedsFiveComponents() public {
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.TooFewComponentsForCapped.selector, 3));
        factory.createIndex("Capped", "CAP", _blueTokens(), _units(100_000, 1e16, 1e18), 1);
    }

    function test_R07_wrappedAssetsCarryAReferenceSupply() public {
        IIndexRule rule = IIndexRule(factory.RULE());
        IIndexFactory.TokenConfig memory onChain;
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidSupplyConfig.selector, address(weth)));
        rule.checkConfig(address(weth), onChain);

        MockERC20 wrapped = new MockERC20("Wrapped Coin", "WCOIN", 8);
        wrapped.mint(alice, 116_132e8); // the wrapped float
        IIndexFactory.TokenConfig memory config = market.configWith(address(wrapped), 0, 20_084_784e8, new address[](0));
        vm.prank(owner);
        factory.proposeListing(address(wrapped), config);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(wrapped));
        assertEq(rule.supply(address(wrapped)), 20_084_784e8, "the whole underlying supply, not the float");
    }

    function test_R08_keepMaskKeepsTheRulesProportions() public {
        (IndexToken idx,) = _ruleBasket(_five(2, 1, 1, 1, 1), _hundreds());
        (uint256[] memory targets,) = idx.previewTarget(1 << 1);
        assertEq(targets[1], 100e18);
        // The four active components share their 400 units of value in the rule's own 2:1:1:1 proportions.
        assertApproxEqRel(targets[0], 2 * targets[2], 1e3);
        assertEq(targets[2], targets[4]);
        assertApproxEqAbs(targets[0] + targets[2] + targets[3] + targets[4], 400e18, 10);
    }

    function test_R09_untouchedComponentsNeverMoveEvenWithDustOrDonations() public {
        uint256 odd = 100e18 + 1; // units that do not divide evenly, so issuing rounds up
        (IndexToken idx, address[] memory t) = _ruleBasket(_five(6, 1, 1, 1, 1), _five(odd, odd, odd, odd, odd));
        _issueRule(idx, attacker, 1e18 + 1);
        uint256 required = idx.totalSupply() * odd / 1e18;
        assertGt(MockERC20(t[3]).balanceOf(address(idx)), required, "issuing rounded up and left dust");
        MockERC20(t[3]).mint(address(idx), 12_345);
        uint256 balanceBefore = MockERC20(t[3]).balanceOf(address(idx));

        _openAuction(idx, 1 << 3, guardian);
        (,, uint256[] memory out, uint256[] memory amountsIn) = idx.previewRebalance();
        assertEq(out[3], 0);
        assertEq(amountsIn[3], 0);
        new MockRebalanceExecutor().execute(idx, "");
        assertEq(MockERC20(t[3]).balanceOf(address(idx)), balanceBefore);
    }

    function test_R10_anUnderfundedFillNeverSettles() public {
        (IndexToken idx, address[] memory t) = _surgeBasket();
        _openAuction(idx, 0, attacker);
        MockRebalanceExecutor short = new MockRebalanceExecutor();
        short.setMode(MockRebalanceExecutor.Mode.Short);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.RebalanceUnderfunded.selector, t[0], 2_500e18 - 1, 2_500e18));
        short.execute(idx, "");
        assertEq(idx.rebalanceNonce(), 0);
    }

    function test_R11_theExecutorCallbackCannotReenter() public {
        (IndexToken idx,) = _surgeBasket();
        _openAuction(idx, 0, attacker);
        MockRebalanceExecutor reentrant = new MockRebalanceExecutor();
        reentrant.setMode(MockRebalanceExecutor.Mode.Reentrant);
        reentrant.execute(idx, "");

        bytes[] memory errors = reentrant.reentryErrors();
        assertEq(errors.length, 7);
        for (uint256 i = 0; i < errors.length; ++i) {
            assertEq(bytes4(errors[i]), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        }
        assertFalse(reentrant.indexTransferSucceeded(), "it held no index tokens to move");
        assertEq(idx.rebalanceNonce(), 1);
    }

    function test_R12_flashIssuingAroundAFillExtractsNothing() public {
        (IndexToken idx,) = _surgeBasket();
        _openAuction(idx, 0, attacker);
        vm.warp(block.timestamp + 18 hours); // multiplier 1.05

        uint256 snapshot = vm.snapshotState();
        int256 plain = new FlashFiller().fill(idx, 0);
        vm.revertToState(snapshot);
        int256 withFlashShares = new FlashFiller().fill(idx, 1_000_000e18);
        assertEq(withFlashShares, plain, "the extra shares bear exactly what they earn");
    }

    function test_R13_claimsSurviveRebalancesInBothDirections() public {
        (IndexToken idx, address[] memory t) = _surgeBasket();
        vm.prank(alice);
        idx.redeemSkipping(2e18, alice, (1 << 0) | (1 << 2)); // a growing and a shrinking component
        _openAuction(idx, 0, attacker);
        new MockRebalanceExecutor().execute(idx, "");

        vm.startPrank(alice);
        assertEq(idx.claim(t[0], alice), 200e18);
        assertEq(idx.claim(t[2], alice), 200e18);
        vm.stopPrank();
    }

    function test_R14_anEmptyIndexRebalancesAtParity() public {
        (IndexToken idx,) = _surgeBasket();
        vm.prank(alice);
        idx.redeem(10e18, alice);
        _openAuction(idx, 0, attacker);
        vm.warp(block.timestamp + 1 hours);
        assertEq(idx.currentMultiplier(), 1e18);

        MockRebalanceExecutor noop = new MockRebalanceExecutor();
        noop.setMode(MockRebalanceExecutor.Mode.Noop);
        noop.execute(idx, "");
        (, uint256[] memory units) = idx.components();
        assertEq(units[0], 200e18, "exactly the snapshot target, whatever the time of the fill");
        assertEq(units[1], 75e18);
    }

    function test_R15_cancelCooldownBindsStrangersOnly() public {
        (IndexToken idx,) = _surgeBasket();
        _openAuction(idx, 0, attacker);
        vm.prank(guardian);
        idx.cancelRebalance();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, attacker));
        idx.startRebalance(0);
        vm.prank(guardian);
        idx.startRebalance(0);
    }

    function test_R16_onlyOwnerOrGuardianCanKeepComponents() public {
        (IndexToken idx,) = _surgeBasket();
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, attacker));
        idx.startRebalance(1 << 0);
    }

    function test_R17_supplyInflationClipsTheTargetAtDouble() public {
        MockERC20 inflating = new MockERC20("Inflating", "INF", 18);
        inflating.mint(attacker, 1e24);
        address[] memory t = new address[](5);
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](5);
        t[0] = address(inflating);
        configs[0] = market.configWith(t[0], 0, 0, new address[](0)); // on-chain supply
        for (uint256 i = 1; i < 5; ++i) {
            t[i] = address(new MockERC20("Fixed", "FIX", 18));
            configs[i] = market.configWith(t[i], 0, 1e24, new address[](0));
        }
        IndexToken idx = _ruleBasketOf(t, configs, _hundreds());

        inflating.mint(attacker, 9e24); // the issuer mints ten times the supply
        (uint256[] memory targets,) = idx.previewTarget(0);
        assertEq(targets[0], 200e18, "the rule would want 3.6x; one rebalance targets at most 2x");

        // A fill at the 1.5 opening multiplier settles the growth at 1.5 times the target's extra units: 2.5x at most.
        uint256 eta = _openAuction(idx, 0, attacker);
        assertEq(block.timestamp, eta);
        new MockRebalanceExecutor().execute(idx, "");
        (, uint256[] memory units) = idx.components();
        assertEq(units[0], 250e18);
    }

    function test_R18_priceReadingsOnlyShapeTargetsWithinBounds() public {
        (IndexToken idx, address[] memory t) = _ruleBasket(_five(1, 1, 1, 1, 1), _hundreds());
        market.setPriceTick(t[0], 46_000); // a hundredfold spike in one component's time-weighted price

        (uint256[] memory targets, uint256 turnover) = idx.previewTarget(0);
        for (uint256 i = 0; i < 5; ++i) {
            assertApproxEqAbs(
                targets[i], 100e18, 1e6, "an uncapped index on target ignores prices, up to weight rounding"
            );
        }
        assertLt(turnover, 1e3);

        vm.prank(attacker);
        IndexToken capped = IndexToken(factory.createIndex("Capped", "CAP", t, _hundreds(), 1));
        (targets,) = capped.previewTarget(0);
        for (uint256 i = 0; i < 5; ++i) {
            assertGe(targets[i], 50e18, "a capped index reacts, but never below half");
            assertLe(targets[i], 200e18, "or above double");
        }
    }

    function test_R19_aRebalanceWithNothingToTradeCannotStart() public {
        (IndexToken idx,) = _ruleBasket(_five(1, 1, 1, 1, 1), _hundreds());
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.TurnoverTooLow.selector, 0));
        idx.startRebalance(0);
    }

    function test_R20_zapRefusesAQuoteFromBeforeARebalance() public {
        (IndexToken idx,) = _surgeBasket();
        _openAuction(idx, 0, attacker);
        new MockRebalanceExecutor().execute(idx, "");

        IIndexZap.BurnParams memory p =
            _burnParams(address(idx), 1e18, address(usdc), 1, new IIndexZap.BurnLeg[](5), alice);
        vm.startPrank(alice);
        idx.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.StaleRebalanceNonce.selector, 0, 1));
        zap.burnToToken(p);
        vm.stopPrank();
    }

    function test_R21_donationsBeforeAFillStayInTheIndex() public {
        (IndexToken idx, address[] memory t) = _surgeBasket();
        _openAuction(idx, 0, attacker);
        (,, uint256[] memory outBefore,) = idx.previewRebalance();
        MockERC20(t[2]).mint(address(idx), 1_000e18);
        (,, uint256[] memory outAfter,) = idx.previewRebalance();
        assertEq(outAfter[2], outBefore[2]);
        new MockRebalanceExecutor().execute(idx, "");
        assertEq(MockERC20(t[2]).balanceOf(address(idx)), 750e18 + 1_000e18);
    }

    function test_R22_noPriceReadingChangesIssueRedeemOrSettlementAmounts() public {
        (IndexToken idx, address[] memory t) = _surgeBasket();
        _openAuction(idx, 0, attacker);
        vm.warp(block.timestamp + 1 hours);
        bytes32 holders = keccak256(abi.encode(idx.previewIssue(3e18), idx.previewRedeem(3e18)));
        bytes32 settlement = keccak256(abi.encode(_preview(idx)));

        for (uint256 i = 0; i < 5; ++i) {
            market.setPriceTick(t[i], int24(int256(i) * 10_000 - 20_000));
        }
        market.setUsdcTick(150_000);

        assertEq(keccak256(abi.encode(idx.previewIssue(3e18), idx.previewRedeem(3e18))), holders);
        assertEq(keccak256(abi.encode(_preview(idx))), settlement);
    }

    function _preview(IndexToken idx) internal view returns (bytes memory) {
        (uint256 m, uint256[] memory units, uint256[] memory out, uint256[] memory amountsIn) = idx.previewRebalance();
        return abi.encode(m, units, out, amountsIn);
    }

    function test_R23_aZeroWeightComponentCannotHandTheFirstExecutorAWindfall() public {
        address[] memory t = new address[](2);
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](2);
        t[0] = address(new MockERC20("Heavy", "HEAVY", 18));
        t[1] = address(new MockERC20("Dust Cap", "DUST", 18));
        configs[0] = market.configWith(t[0], 0, 1e30, new address[](0));
        configs[1] = market.configWith(t[1], 0, 1, new address[](0)); // its weight rounds to zero
        uint256[] memory units = new uint256[](2);
        (units[0], units[1]) = (10e18, 100e18);
        IndexToken idx = _ruleBasketOf(t, configs, units);

        _openAuction(idx, 0, attacker);
        (,, uint256[] memory out, uint256[] memory amountsIn) = idx.previewRebalance();
        // Dropping the value the heavy component could not absorb would have sent out 500 units against 150 returned.
        assertEq(out[1], 100e18, "only what the heavy component can absorb leaves");
        assertEq(amountsIn[0], 150e18);
        assertGe(amountsIn[0], out[1], "at the opening an executor delivers more than it takes");
    }

    // ---------------------------------------------------------------------
    // Whole-repo audit of 2026-09-16 (XA ids, audit/2026-09-16-whole-repo-audit.md)
    // ---------------------------------------------------------------------

    /// @dev One 12-second block at the extreme tick that makes `token` look cheapest, in the last third of the
    ///      30-minute window, with the true tick 0 everywhere else. With `emptyRange` the block sat past every
    ///      position, where Uniswap counts liquidity as one.
    function _extremeBlock(address token, bool emptyRange) internal returns (MockUniswapV3Pool pool, uint256 delta) {
        pool = market.tokenPool(token);
        int56 outlier = (token < address(weth) ? int56(-887_272) : int56(887_272)) * 12;
        uint256 perSecond = (uint256(1) << 128) / pool.liquidity();
        delta = 1788 * perSecond + (emptyRange ? uint256(12) << 128 : 12 * perSecond);
        pool.setObservation(1800, 0, 0);
        pool.setObservation(1200, 0, uint160(600 * perSecond));
        pool.setObservation(600, 0, uint160(1200 * perSecond));
        pool.setObservation(0, outlier, uint160(delta));
    }

    /// @dev The distorted snapshot of the finding: this basket lost 248 bps to the first executor at the opening.
    function _offTargetBasket() internal returns (IndexToken idx, address[] memory t) {
        (idx, t) = _ruleBasket(_five(1, 1, 1, 1, 1), _five(200e18, 100e18, 100e18, 100e18, 100e18));
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
    }

    function test_XA01_aSnapshotThroughAnEmptyRangeCannotStart() public {
        (IndexToken idx, address[] memory t) = _offTargetBasket();
        (MockUniswapV3Pool pool, uint256 delta) = _extremeBlock(t[0], true);
        uint256 harmonic = uint256(1800) * type(uint160).max / (delta << 32);
        assertLt(harmonic, 200, "twelve seconds at liquidity one dominate the harmonic mean");
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndexRule.ThinPriceHistory.selector, address(pool), harmonic, market.MIN_LIQUIDITY()
            )
        );
        vm.prank(attacker);
        idx.startRebalance(0);
    }

    function test_XA01_aOneBlockOutlierThroughLiquidityCannotStart() public {
        (IndexToken idx, address[] memory t) = _offTargetBasket();
        (MockUniswapV3Pool pool,) = _extremeBlock(t[0], false);
        // The last third's mean tick is 887,272 * 12 / 600, rounded toward negative infinity.
        uint256 spread = t[0] < address(weth) ? 17_746 : 17_745;
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.PriceHistoryDeviates.selector, address(pool), spread));
        vm.prank(attacker);
        idx.startRebalance(0);
    }

    function test_XA02_anUnfillableSnapshotThroughAnEmptyRangeCannotStart() public {
        // On the original rule this snapshot started, and even at the 0.9 floor an executor had to deliver more than it
        // received, so nobody filled and a griefer could restart it at every expiry.
        (IndexToken idx, address[] memory t) = _offTargetBasket();
        (MockUniswapV3Pool pool, uint256 delta) = _extremeBlock(t[1], true); // a component the rebalance buys
        uint256 harmonic = uint256(1800) * type(uint160).max / (delta << 32);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndexRule.ThinPriceHistory.selector, address(pool), harmonic, market.MIN_LIQUIDITY()
            )
        );
        vm.prank(attacker);
        idx.startRebalance(0);
    }

    function test_XA03_delistCancelsAPendingListingProposal() public {
        // A config change proposed while LINK was listed must not relist it once the guardian delists it.
        IIndexFactory.TokenConfig memory next = market.config(address(link), 0);
        vm.prank(owner);
        factory.proposeListing(address(link), next);
        uint256 eta = factory.listingEta(address(link));
        vm.prank(guardian);
        factory.delist(address(link));

        vm.warp(eta);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(link)));
        factory.executeListing(address(link));
        assertFalse(factory.isWhitelisted(address(link)));
    }

    function test_XA03_aConfigRefreshOfADelistedTokenKeepsItDelisted() public {
        vm.prank(guardian);
        factory.delist(address(link));
        IIndexFactory.TokenConfig memory refresh = market.configWith(address(link), 0, 2e30, new address[](0));
        vm.prank(owner);
        factory.proposeConfig(address(link), refresh);
        vm.warp(factory.listingEta(address(link)));
        vm.prank(attacker);
        factory.executeListing(address(link));
        assertEq(factory.tokenConfig(address(link)).referenceSupply, 2e30, "existing indexes rebalance with it");
        assertFalse(factory.isWhitelisted(address(link)), "a refresh does not relist");
    }

    function test_control_aWindfallNeedsTheFairMultiplierAboveTheStart() public {
        (IndexToken idx,) = _surgeBasket();
        _openAuction(idx, 0, attacker);
        (uint256 m,, uint256[] memory out, uint256[] memory amountsIn) = idx.previewRebalance();
        assertEq(m, 1.5e18);
        // Suppose the growing component's market price halved after the snapshot, so the fair multiplier is 2. At the
        // opening, the first executor takes 1,000 worth of shrinking components and delivers 1,500 units worth 750.
        uint256 taken = out[1] + out[2] + out[3] + out[4];
        assertEq(taken - amountsIn[0] / 2, 250e18, "the gap is (fair - start) times the bought value at current prices");
    }

    function test_control_aFrozenComponentNeedsTheGuardianEachRebalance() public {
        MockPausableToken frozen = new MockPausableToken("Frozen", "FRZ", 18);
        address[] memory t = new address[](5);
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](5);
        uint256[5] memory parts = [uint256(6), 1, 1, 1, 1];
        for (uint256 i = 0; i < 5; ++i) {
            t[i] = i == 1 ? address(frozen) : address(new MockERC20("Rule", "RULE", 18));
            configs[i] = market.configWith(t[i], 0, parts[i] * 1e24, new address[](0));
        }
        IndexToken idx = _ruleBasketOf(t, configs, _hundreds());
        frozen.setPaused(true);

        _openAuction(idx, 0, attacker);
        MockRebalanceExecutor executor = new MockRebalanceExecutor();
        vm.expectRevert(bytes("paused"));
        executor.execute(idx, "");

        vm.prank(guardian);
        idx.cancelRebalance();
        _openAuction(idx, 1 << 1, guardian);
        executor.execute(idx, "");
        assertEq(idx.rebalanceNonce(), 1, "the guardian's keep mask routes around the frozen component");
    }

    function test_XA02_aStrangerWaitsOutAnUnfilledAuctionBeforeRestarting() public {
        (IndexToken idx,) = _surgeBasket();
        uint256 eta = _openAuction(idx, 0, attacker);
        uint256 deadline = eta + idx.AUCTION_DURATION();

        // Nobody fills. Before the fix the griefer could restart at once, at every expiry, with a snapshot built so no
        // executor would fill it either.
        vm.warp(deadline + 1);
        assertFalse(idx.canStartRebalance());
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, attacker));
        idx.startRebalance(0);

        // The guardian is never held off, so it takes the first restart after an expiry.
        vm.prank(guardian);
        idx.startRebalance(0);
        (uint256 vetted,,) = idx.pendingRebalance();
        assertEq(vetted, block.timestamp + idx.REBALANCE_DELAY());

        // And the trigger stays permissionless: REBALANCE_DELAY after an expiry anyone can start again.
        vm.prank(guardian);
        idx.cancelRebalance();
        vm.warp(idx.restartAllowedAt());
        assertTrue(idx.canStartRebalance(), "a cancel holds strangers off for the same wait, not longer");
        vm.prank(attacker);
        idx.startRebalance(0);
        (eta,,) = idx.pendingRebalance();
        vm.warp(eta + idx.AUCTION_DURATION() + idx.REBALANCE_DELAY());
        assertTrue(idx.canStartRebalance());
        vm.prank(attacker);
        idx.startRebalance(0);
    }

    /// @dev A one-component index of LINK and a router that fills every hop halfway, so each hop of a multi-hop burn
    ///      leg leaves something unsold.
    function _halfFilled() internal returns (IndexToken idx, IndexZap halfZap) {
        MockPartialFillRouter half = new MockPartialFillRouter(1e18); // one output unit per input unit, per hop
        weth.mint(address(half), 100e18);
        usdc.mint(address(half), 100e18); // raw units: the mock prices every hop one for one
        halfZap = new IndexZap(factory, half);

        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(link);
        u[0] = 1e18;
        idx = IndexToken(factory.createIndex("Link One", "LNK1", t, u, 0));

        link.mint(alice, 1e18);
        vm.startPrank(alice);
        link.approve(address(idx), 1e18);
        idx.issue(1e18, alice);
        idx.approve(address(halfZap), 1e18);
        vm.stopPrank();
    }

    function test_XA08_aLaterHopsUnsoldInputReachesTheRecipient() public {
        (IndexToken idx, IndexZap halfZap) = _halfFilled();
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](1);
        legs[0] = IIndexZap.BurnLeg({
            path: abi.encodePacked(address(link), FEE, address(weth), FEE, address(usdc)), minAmountOut: 0
        });

        uint256 wethBefore = weth.balanceOf(alice);
        vm.prank(alice);
        uint256 out = halfZap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1, legs, alice));

        // Half the LINK is sold; of the WETH that buys, half is sold on. Before the fix the second half stayed in the
        // router, where anyone could sweep it.
        assertEq(out, 2.5e17, "the payout is what the last hop sold");
        assertEq(link.balanceOf(alice), 5e17, "the first hop's unsold input comes back");
        assertEq(weth.balanceOf(alice) - wethBefore, 2.5e17, "and so does the second hop's");
        assertEq(weth.balanceOf(address(halfZap)), 0);
        assertEq(link.balanceOf(address(halfZap)), 0);
    }

    function test_XA08_unsoldTokenOutIsPaidOutAndAnEmptyHopReverts() public {
        (IndexToken idx, IndexZap halfZap) = _halfFilled();
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](1);
        // A path whose intermediate token is the payout token itself.
        legs[0] = IIndexZap.BurnLeg({
            path: abi.encodePacked(address(link), FEE, address(usdc), FEE, address(weth), FEE, address(usdc)),
            minAmountOut: 0
        });

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out = halfZap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1, legs, alice));

        // The 0.25 of USDC the second hop did not sell stays in the zap and is paid out, not returned twice.
        assertEq(out, 3.75e17, "0.5 bought, 0.25 sold on, 0.125 bought back");
        assertEq(usdc.balanceOf(alice) - usdcBefore, 3.75e17);
        assertEq(usdc.balanceOf(address(halfZap)), 0);
        assertEq(weth.balanceOf(address(halfZap)), 0);

        // A hop that sells nothing would leave the next hop with SwapRouter02's "spend my whole balance" sentinel.
        legs[0] = IIndexZap.BurnLeg({
            path: abi.encodePacked(address(link), FEE, address(weth), FEE, address(usdc)), minAmountOut: 0
        });
        link.mint(alice, 1);
        vm.startPrank(alice);
        link.approve(address(idx), 1);
        idx.issue(1, alice);
        idx.approve(address(halfZap), 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.InsufficientOutput.selector, 0, 0));
        halfZap.burnToToken(_burnParams(address(idx), 1, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    function test_XA16_theRebalanceDuePredicateSurvivesAnUnfilledAuction() public {
        (IndexToken idx,) = _surgeBasket();
        assertFalse(idx.canStartRebalance(), "not due yet");
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        assertTrue(idx.canStartRebalance());

        uint256 eta = _openAuction(idx, 0, attacker);
        assertFalse(idx.canStartRebalance(), "an auction is live");
        vm.warp(eta + idx.AUCTION_DURATION() + idx.REBALANCE_DELAY());

        // The stale eta is what an app reading `pendingRebalance().eta == 0` would trip over.
        (uint256 stale,,) = idx.pendingRebalance();
        assertGt(stale, 0, "an unfilled auction keeps its eta");
        assertTrue(idx.canStartRebalance(), "and the index is due again");
        vm.prank(attacker);
        idx.startRebalance(0);
    }

    function test_XA27_aSettlementThatSendsNothingOutIsPricedAtParity() public {
        // Units small enough that a dust supply moves no raw unit at all.
        (IndexToken idx,) = _ruleBasket(_five(6, 1, 1, 1, 1), _five(1e6, 1e6, 1e6, 1e6, 1e6));
        uint256 dusted = idx.totalSupply() - 1;
        vm.prank(alice);
        idx.redeem(dusted, alice);
        assertEq(idx.totalSupply(), 1);

        uint256 eta = _openAuction(idx, 0, attacker);
        (uint256[] memory targets,) = idx.previewTarget(0);
        vm.warp(eta + idx.AUCTION_DURATION()); // where a lone executor would otherwise pick the 0.9 floor
        assertEq(idx.currentMultiplier(), 1e18, "nothing leaves the index, so the auction has nothing to price");
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = idx.previewRebalance();
        new MockRebalanceExecutor().execute(idx, "");

        (, uint256[] memory units) = idx.components();
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(amountsOut[i], 0);
            assertEq(amountsIn[i], 0);
            assertEq(units[i], targets[i], "the units are the rule's targets, whoever executes and whenever");
        }
    }

    function test_XA27_aSupplyThatStillMovesUnitsKeepsTheAuction() public {
        (IndexToken idx,) = _surgeBasket();
        uint256 eta = _openAuction(idx, 0, attacker);
        vm.warp(eta + idx.AUCTION_DURATION());
        assertEq(idx.currentMultiplier(), idx.AUCTION_END_MULTIPLIER(), "a live auction still decays");
    }

    function test_XA28_anExecutorCannotDeliverLessBecauseTheIndexHoldsASurplus() public {
        (IndexToken idx, address[] memory t) = _surgeBasket();
        MockERC20 grown = MockERC20(t[0]); // the component the rebalance buys
        grown.mint(address(idx), 1e18); // a donation, or rounding dust the index kept

        _openAuction(idx, 0, attacker);
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = idx.previewRebalance();
        uint256 held = grown.balanceOf(address(idx));
        uint256 required = held - amountsOut[0] + amountsIn[0];

        MockRebalanceExecutor executor = new MockRebalanceExecutor();
        executor.setMode(MockRebalanceExecutor.Mode.Short);
        executor.setShortComponent(0);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexToken.RebalanceUnderfunded.selector, address(grown), required - 1, required)
        );
        executor.execute(idx, "");

        executor.setMode(MockRebalanceExecutor.Mode.Honest);
        executor.execute(idx, "");
        assertEq(grown.balanceOf(address(idx)), required, "the surplus is still in the index");
    }

    function test_XA59_everyProposalCarriesItsOwnId() public {
        (IndexToken idx,) = _surgeBasket();
        uint256 eta = _openAuction(idx, 0, attacker);
        assertEq(idx.proposalCount(), 1);

        vm.prank(guardian);
        idx.cancelRebalance();
        vm.warp(idx.restartAllowedAt());
        (uint256[] memory targets,) = idx.previewTarget(0);
        eta = block.timestamp + idx.REBALANCE_DELAY();
        vm.expectEmit(true, true, true, true, address(idx));
        emit IIndexToken.RebalanceStarted(2, 1, attacker, targets, 0, eta);
        vm.prank(attacker);
        idx.startRebalance(0);

        // The third proposal follows the second's expiry, with no event of its own to mark it.
        vm.warp(eta + idx.AUCTION_DURATION() + idx.REBALANCE_DELAY());
        vm.prank(attacker);
        idx.startRebalance(0);
        assertEq(idx.proposalCount(), 3, "three attempts, all at rebalance nonce 1");
        assertEq(idx.rebalanceNonce(), 0);

        (eta,,) = idx.pendingRebalance();
        vm.warp(eta);
        vm.recordLogs();
        new MockRebalanceExecutor().execute(idx, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != IIndexToken.Rebalanced.selector) continue;
            found = true;
            assertEq(uint256(logs[i].topics[1]), 3, "the settled proposal is the third");
            assertEq(uint256(logs[i].topics[2]), 1, "and it takes rebalance nonce 1");
        }
        assertTrue(found);
    }

    function test_XA62_oneInterfaceExtendsTheFactoryRuleAndToken() public view {
        IXindexCore core = IXindexCore(address(index));
        assertEq(core.FACTORY(), address(factory), "the combined interface compiles and reads an index");
        assertEq(core.RULE(), factory.RULE());
        assertEq(core.componentCount(), index.componentCount());
    }
}
