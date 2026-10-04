// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "./XindexTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexHub} from "../src/IndexHub.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexZap} from "../src/interfaces/IIndexZap.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexHub} from "../src/interfaces/IIndexHub.sol";
import {IRebalanceExecutor} from "../src/interfaces/IRebalanceExecutor.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockHookToken, ITokenReceiverHook} from "./mocks/MockHookToken.sol";
import {MockPausableToken} from "./mocks/MockPausableToken.sol";
import {MockRebalanceExecutor} from "./mocks/MockRebalanceExecutor.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {PathKey} from "../src/libraries/UniswapV4Types.sol";

/// @notice Watches an index from inside a token callback, the way a third-party protocol could.
contract NavProbe is ITokenReceiverHook {
    IndexHub public immutable index;
    ERC20 public immutable weth;

    uint256 public seenSupply;
    uint256 public seenWethInIndex;
    uint256 public seenWethPerShare;
    bool public issueReentryBlocked;
    bool public redeemReentryBlocked;

    constructor(IndexHub index_, ERC20 weth_) {
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
        (bool issued, bytes memory issueError) = address(index).call(abi.encodeCall(IndexHub.issue, (1, address(this))));
        issueReentryBlocked = !issued && bytes4(issueError) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        (bool redeemed, bytes memory redeemError) =
            address(index).call(abi.encodeCall(IndexHub.redeem, (1, address(this))));
        redeemReentryBlocked = !redeemed && bytes4(redeemError) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
    }
}

/// @notice Fills an auction after issuing extra shares in the same transaction and redeems them afterwards, to show
///         that a larger supply does not let an executor take more than the auction discount.
contract FlashFiller is IRebalanceExecutor {
    uint256 public spent;

    /// @return pnl Raw units the filler ends with minus raw units it minted. Every component is worth one WETH per unit.
    function fill(IndexHub index, uint256 shares) external returns (int256 pnl) {
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
        address[] memory t = IndexHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (amountsIn[i] == 0) continue;
            MockERC20(t[i]).mint(msg.sender, amountsIn[i]);
            spent += amountsIn[i];
        }
    }
}

/// @notice XA-62: an integrator's single interface over the factory and the hub. It compiles only while the two
///         interfaces declare their common errors once, in a shared base, instead of each declaring them again.
interface IXindexCore is IIndexFactory, IIndexHub {
    function MAX_SUPPLY_STEP() external view override(IIndexFactory, IIndexHub) returns (uint256);
}

/// @notice One regression test per finding of the Xindex v1 security review and of the v2 rebalancing design review,
///         each asserting the fixed behaviour, plus the attacks that already failed before the fixes.
contract SecurityRegressionTest is XindexTest {
    MockUniversalRouter router;
    address poolManager;
    IndexZap zap;
    IndexHub index;

    MockERC20 wbtc; // 8
    MockERC20 weth; // 18
    MockERC20 link; // 18
    MockERC20 usdc; // 6

    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    uint24 constant FEE = 500;
    uint256 constant NAV_USD6 = 105e6; // 0.001 WBTC ($60) + 0.01 WETH ($30) + 1 LINK ($15)
    /// @dev With each component listed at its units as its supply, this scale gives exactly those units.
    uint256 constant K = 1e36;
    /// @dev A whole WETH per index token, from WETH's listed supply of 1e16.
    uint256 constant K_ONE_WETH = K * 100;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        poolManager = makeAddr("poolManager");
        router = new MockUniversalRouter(poolManager);
        zap = new IndexZap(factory, router);

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

        // Listed with the units the suite's indexes hold as their supplies, so k = K gives exactly those units.
        _listWith(address(wbtc), 100_000);
        _listWith(address(weth), 1e16);
        _listWith(address(link), 1e18);
        _listWith(address(usdc), 50e6);

        index = IndexHub(factory.createIndex("Blue Chip", "BLUE", _blueTokens(), K));
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

    function _mintLegs(address stable) internal view returns (IIndexZap.MintLeg[] memory legs) {
        legs = new IIndexZap.MintLeg[](3);
        legs[0] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(address(wbtc), FEE, address(weth), FEE, stable),
            v4Path: new PathKey[](0),
            maxAmountIn: 0
        });
        legs[1] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(address(weth), FEE, stable), v4Path: new PathKey[](0), maxAmountIn: 0
        });
        legs[2] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(address(link), FEE, address(weth), FEE, stable),
            v4Path: new PathKey[](0),
            maxAmountIn: 0
        });
    }

    function _burnLegs(address tokenOut) internal view returns (IIndexZap.BurnLeg[] memory legs) {
        legs = new IIndexZap.BurnLeg[](3);
        legs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(address(wbtc), FEE, address(weth), FEE, tokenOut),
            v4Path: new PathKey[](0),
            minAmountOut: 0
        });
        legs[1] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(address(weth), FEE, tokenOut), v4Path: new PathKey[](0), minAmountOut: 0
        });
        legs[2] = IIndexZap.BurnLeg({
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
        _listWith(address(pbtc), 100_000);
        address[] memory t = new address[](2);
        t[0] = address(pbtc);
        t[1] = address(weth);
        IndexHub idx = IndexHub(factory.createIndex("Half Paused", "HALF", t, K));

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
        IndexHub impl = IndexHub(factory.IMPLEMENTATION());
        IndexHub rogue = IndexHub(Clones.clone(address(impl)));
        vm.startPrank(attacker);
        vm.expectRevert(IIndexHub.NotInitialized.selector);
        impl.issue(1_000_000e18, attacker);
        vm.expectRevert(IIndexHub.NotInitialized.selector);
        rogue.issue(42e18, attacker);
        vm.stopPrank();
        assertEq(impl.totalSupply(), 0);
        assertEq(rogue.totalSupply(), 0);
    }

    function test_L02_reorgCannotSwapTheBasketBehindAnAddress() public {
        address[] memory t = _blueTokens();
        address creatorA = makeAddr("creatorA");
        address creatorB = makeAddr("creatorB");

        uint256 snap = vm.snapshotState();
        vm.prank(creatorA);
        address seen = factory.createIndex("Bitcoin Heavy", "BTCH", t, K);

        // Re-org: creator B's createIndex is included first on the canonical chain.
        vm.revertToState(snap);
        vm.prank(creatorB);
        address other = factory.createIndex("Ether Heavy", "ETHH", t, 2 * K);
        assertTrue(other != seen, "a different basket can never land at the address the user saw");

        // Nor can a supply batch re-ordered ahead of the creation: it changes the units, so it changes the address.
        uint256 batched = vm.snapshotState();
        _revise(address(wbtc), 100_000 + 500);
        vm.prank(creatorA);
        assertTrue(factory.createIndex("Bitcoin Heavy", "BTCH", t, K) != seen, "another basket, another address");
        vm.revertToState(batched);

        // Until creator A's transaction is included again, the user's mint to `seen` cannot execute.
        uint256 maxIn = NAV_USD6 + NAV_USD6 / 100;
        usdc.mint(alice, maxIn);
        vm.startPrank(alice);
        usdc.approve(address(zap), maxIn);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, seen));
        zap.mintWithToken(_mintParams(seen, address(usdc), maxIn, 1e18, _mintLegs(address(usdc)), alice));
        vm.stopPrank();

        vm.prank(creatorA);
        assertEq(factory.createIndex("Bitcoin Heavy", "BTCH", t, K), seen);
        assertEq(IndexHub(seen).symbol(), "BTCH");
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
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotAContract.selector, typo));
        factory.proposeListing(typo, 1e24);
    }

    function test_L07_hostileListingWaitsAndGuardianCanCancel() public {
        MockERC20 hostile = new MockERC20("Blue Chip Plus", "BLUE+", 18);
        vm.prank(owner);
        factory.proposeListing(address(hostile), 1e24);
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
        factory.proposeListing(address(hostile), 1e24);
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
        vm.prank(owner);
        factory.proposeListing(address(token), 1e24);
        uint256 deadline = factory.listingEta(address(token)) + factory.PROPOSAL_WINDOW();

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingExpired.selector, address(token), deadline));
        factory.executeListing(address(token));

        vm.prank(owner); // proposing again restarts the public delay
        factory.proposeListing(address(token), 1e24);
        assertEq(factory.listingEta(address(token)), block.timestamp + factory.LISTING_DELAY());
    }

    // ---------------------------------------------------------------------
    // Informational findings
    // ---------------------------------------------------------------------

    function test_I01_callbackTokenCannotReenter_andUnitValuationStaysExact() public {
        MockHookToken hook = new MockHookToken();
        _listWith(address(hook), 1e16); // deliberately breaks the whitelist policy to exercise the worst case

        address[] memory t = new address[](2);
        t[0] = address(hook);
        t[1] = address(weth);
        IndexHub idx = IndexHub(factory.createIndex("Hooked", "HOOKD", t, K_ONE_WETH)); // a whole unit of each

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
        t[0] = address(weth);
        t[1] = address(usdc);
        IndexHub idx = IndexHub(factory.createIndex("Mixed", "MIX", t, K));

        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](2);
        legs[0] = IIndexZap.MintLeg({
            v3Path: abi.encodePacked(address(weth), FEE, address(usdc)), v4Path: new PathKey[](0), maxAmountIn: 0
        });
        legs[1] = IIndexZap.MintLeg({v3Path: "", v4Path: new PathKey[](0), maxAmountIn: 0});

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

        vm.prank(copier); // front-runs with identical arguments
        address copy = factory.createIndex("Original", "ORIG", t, K);
        vm.prank(creator);
        address original = factory.createIndex("Original", "ORIG", t, K);

        assertTrue(copy != original);
        assertEq(factory.creatorOf(original), creator);
        assertEq(factory.creatorOf(copy), copier);
        assertEq(original, factory.predictIndexAddress(creator, "Original", "ORIG", t, K));
    }

    function test_I12_partialFillReturnsTheUnsoldPartToTheRecipient() public {
        router.setMode(MockUniversalRouter.Mode.PartialFirstHop);
        IndexZap halfZap = zap;

        address[] memory t = new address[](1);
        t[0] = address(weth);
        IndexHub idx = IndexHub(factory.createIndex("Ether", "ETH1", t, K_ONE_WETH));

        weth.mint(alice, 1e18);
        vm.startPrank(alice);
        weth.approve(address(idx), 1e18);
        idx.issue(1e18, alice);
        idx.approve(address(halfZap), 1e18);
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](1);
        legs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(address(weth), FEE, address(usdc)), v4Path: new PathKey[](0), minAmountOut: 0
        });
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
    // v2 rebalancing (design review of 2026-09-16), re-targeted to the λ band
    // ---------------------------------------------------------------------

    uint256 constant SUPPLY = 100e18;

    /// @dev Five fresh 18-decimal tokens, each listed with a supply of 100e18 and held at 100e18 units, so units are
    ///      exactly proportional to supplies; ten shares issued to alice.
    function _bandBasket() internal returns (IndexHub idx, address[] memory t) {
        t = new address[](5);
        for (uint256 i = 0; i < 5; ++i) {
            t[i] = address(new MockERC20("Band", "BAND", 18));
            _listWith(t[i], SUPPLY);
        }
        idx = IndexHub(factory.createIndex("Band Basket", "BAND", t, K));
        _issueBand(idx, alice, 10e18);
    }

    /// @dev Raises the first component's supply by the full step, so a fill buys it and sells the four others.
    function _raiseFirst(address[] memory t) internal {
        _revise(t[0], SUPPLY + SUPPLY / 200);
    }

    function _issueBand(IndexHub idx, address who, uint256 shares) internal {
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
    function _openAuction(IndexHub idx, uint256 keepMask, address caller) internal returns (uint256 eta) {
        uint256 earliest = idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL();
        if (idx.restartAllowedAt() > earliest) earliest = idx.restartAllowedAt();
        if (block.timestamp < earliest) vm.warp(earliest);
        vm.prank(caller);
        idx.startRebalance(keepMask);
        (eta,,,,) = idx.pendingRebalance();
        vm.warp(eta);
    }

    function _band(IndexHub idx) internal view returns (uint256 lambdaMin, uint256 lambdaMax) {
        (,, lambdaMin, lambdaMax,) = idx.pendingRebalance();
    }

    /// @dev R04, re-targeted: a lone executor who waits for the floor takes at most the band from the moving value.
    ///      At equal prices, which exist only in this test, what it takes out is at most (1 - λmin/λmax) of the
    ///      basket, 0.995% at the widest band.
    function test_R04_aLoneExecutorKeepsAtMostTheBand() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        _openAuction(idx, 0, attacker);
        vm.warp(block.timestamp + idx.AUCTION_DURATION()); // with no competition it waits for the floor
        (uint256 lambdaMin, uint256 lambdaMax) = _band(idx);
        (,, uint256[] memory out, uint256[] memory amountsIn) = idx.previewRebalance();
        new MockRebalanceExecutor().execute(idx, "");

        uint256 taken = 0;
        uint256 delivered = 0;
        for (uint256 i = 0; i < 5; ++i) {
            taken += out[i];
            delivered += amountsIn[i];
        }
        assertEq(delivered, 0, "at the floor nothing is bought");
        uint256 basket = 5 * 10 * SUPPLY; // ten shares of five components, all worth one per unit here
        assertLe(taken * lambdaMax, basket * (lambdaMax - lambdaMin), "at most the band of the basket");
        assertLe(taken * 10_000, basket * 100, "and under 1% of it");
    }

    /// @dev R07 and CR-L07, re-targeted: every token carries a reference supply, and it is the only supply anything
    ///      reads: a listing without one is refused, and minting the token itself moves no band.
    function test_R07_CRL07_everyTokenCarriesAReferenceSupplyAndMintingMovesNothing() public {
        MockERC20 wrapped = new MockERC20("Wrapped", "WRP", 18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.SupplyOutOfRange.selector, address(wrapped), 0));
        factory.proposeListing(address(wrapped), 0);

        (IndexHub idx, address[] memory t) = _bandBasket();
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        MockERC20(t[0]).mint(attacker, 1e30); // the issuer mints ten billion times the reference supply
        (, uint256 lambdaMin, uint256 lambdaMax) = idx.previewBand(0);
        assertEq(lambdaMin, lambdaMax, "the mint moves nothing the hub reads");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.BandTooNarrow.selector, lambdaMin, lambdaMax));
        idx.startRebalance(0);
    }

    /// @dev R08, re-targeted: a keep mask leaves the kept component exactly as it was, and a full fill anchors the
    ///      moving components' units to their supplies again, so the index's shape follows the supplies.
    function test_R08_aKeepMaskKeepsItsComponentAndAnchorsTheRest() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        _openAuction(idx, 1 << 1, guardian);
        vm.warp(block.timestamp + 6 hours);
        new MockRebalanceExecutor().execute(idx, "");

        (, uint256[] memory units) = idx.components();
        assertEq(units[1], SUPPLY, "the kept component never moved");
        uint256[] memory supplies = factory.referenceSupplies(t);
        // u_i / f_i is the same for every moving component, to the rounding of the ratios (a part in 1e15).
        for (uint256 i = 2; i < 5; ++i) {
            assertApproxEqRel(units[i] * supplies[0], units[0] * supplies[i], 1e3, "anchored to supplies");
        }
    }

    function test_R09_untouchedComponentsNeverMoveEvenWithDustOrDonations() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _issueBand(idx, attacker, 1e18 + 1);
        MockERC20(t[3]).mint(address(idx), 12_345);
        uint256 balanceBefore = MockERC20(t[3]).balanceOf(address(idx));
        _raiseFirst(t);

        _openAuction(idx, 1 << 3, guardian);
        vm.warp(block.timestamp + 12 hours);
        (,, uint256[] memory out, uint256[] memory amountsIn) = idx.previewRebalance();
        assertEq(out[3], 0);
        assertEq(amountsIn[3], 0);
        new MockRebalanceExecutor().execute(idx, "");
        assertEq(MockERC20(t[3]).balanceOf(address(idx)), balanceBefore);
    }

    function test_R10_anUnderfundedFillNeverSettles() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        _openAuction(idx, 0, attacker);
        (,,, uint256[] memory amountsIn) = idx.previewRebalance();
        uint256 required = 10 * SUPPLY + amountsIn[0];
        MockRebalanceExecutor short = new MockRebalanceExecutor();
        short.setMode(MockRebalanceExecutor.Mode.Short);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceUnderfunded.selector, t[0], required - 1, required));
        short.execute(idx, "");
        assertEq(idx.rebalanceNonce(), 0);
    }

    function test_R11_theExecutorCallbackCannotReenter() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        _openAuction(idx, 0, attacker);
        MockRebalanceExecutor reentrant = new MockRebalanceExecutor();
        reentrant.setMode(MockRebalanceExecutor.Mode.Reentrant);
        reentrant.execute(idx, "");

        bytes[] memory errors = reentrant.reentryErrors();
        assertEq(errors.length, 8, "both executeRebalance entry points are guarded too");
        for (uint256 i = 0; i < errors.length; ++i) {
            assertEq(bytes4(errors[i]), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        }
        assertFalse(reentrant.indexTransferSucceeded(), "it held no index tokens to move");
        assertEq(idx.rebalanceNonce(), 1);
    }

    function test_R12_flashIssuingAroundAFillExtractsNothing() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        _openAuction(idx, 0, attacker);
        vm.warp(block.timestamp + 18 hours);

        uint256 snapshot = vm.snapshotState();
        int256 plain = new FlashFiller().fill(idx, 0);
        vm.revertToState(snapshot);
        int256 withFlashShares = new FlashFiller().fill(idx, 1_000_000e18);
        // The extra shares bear exactly what they earn: the filler gains what it would without them, to the raw units
        // of rounding its issue and redemption take.
        assertApproxEqAbs(withFlashShares, plain, 10, "flash shares extract nothing");
    }

    function test_R13_claimsSurviveRebalancesInBothDirections() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        vm.prank(alice);
        idx.redeemSkipping(2e18, alice, (1 << 0) | (1 << 2)); // a growing and a shrinking component
        _raiseFirst(t);
        _openAuction(idx, 0, attacker);
        vm.warp(block.timestamp + 12 hours);
        new MockRebalanceExecutor().execute(idx, "");

        vm.startPrank(alice);
        assertEq(idx.claim(t[0], alice), 200e18);
        assertEq(idx.claim(t[2], alice), 200e18);
        vm.stopPrank();
    }

    /// @dev R14, re-targeted: an empty index settles at λmax, whatever the time of the fill.
    function test_R14_anEmptyIndexRebalancesAtTheTopOfTheBand() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        vm.prank(alice);
        idx.redeem(10e18, alice);
        _raiseFirst(t);
        _openAuction(idx, 0, attacker);
        vm.warp(block.timestamp + 20 hours);
        (, uint256 lambdaMax) = _band(idx);
        assertEq(idx.currentLambda(), lambdaMax);

        MockRebalanceExecutor noop = new MockRebalanceExecutor();
        noop.setMode(MockRebalanceExecutor.Mode.Noop);
        noop.execute(idx, "");
        (, uint256[] memory units) = idx.components();
        assertGt(units[0], SUPPLY, "the first component grows, as at the open");
        assertEq(units[1], SUPPLY, "and nothing shrinks, whatever the time of the fill");
    }

    function test_R15_cancelCooldownBindsStrangersOnly() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
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
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, attacker));
        idx.startRebalance(1 << 1);
    }

    function test_R20_zapRefusesAQuoteFromBeforeARebalance() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
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
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        _openAuction(idx, 0, attacker);
        vm.warp(block.timestamp + 12 hours);
        (,, uint256[] memory outBefore,) = idx.previewRebalance();
        MockERC20(t[2]).mint(address(idx), 1_000e18);
        (,, uint256[] memory outAfter,) = idx.previewRebalance();
        assertEq(outAfter[2], outBefore[2]);
        new MockRebalanceExecutor().execute(idx, "");
        assertEq(MockERC20(t[2]).balanceOf(address(idx)), 1_000e18 + 1_000e18 - outBefore[2]);
    }

    // ---------------------------------------------------------------------
    // Whole-repo audit of 2026-09-16 (XA ids, audit/2026-09-16-whole-repo-audit.md)
    // ---------------------------------------------------------------------

    /// @dev XA-03, re-targeted: relisting always takes a fresh proposal and delay. A whitelisted token cannot take a
    ///      listing proposal at all, so no proposal made while it was listed can relist it after a delist.
    function test_XA03_relistingAlwaysTakesAFreshProposal() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.AlreadyListed.selector, address(link)));
        factory.proposeListing(address(link), 1e18);

        vm.prank(guardian);
        factory.delist(address(link));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(link)));
        factory.executeListing(address(link));
        assertFalse(factory.isWhitelisted(address(link)));

        vm.prank(owner);
        factory.proposeListing(address(link), 1e18);
        assertEq(factory.listingEta(address(link)), block.timestamp + factory.LISTING_DELAY(), "a fresh delay");
    }

    function test_control_aFrozenComponentNeedsTheGuardianEachRebalance() public {
        MockPausableToken frozen = new MockPausableToken("Frozen", "FRZ", 18);
        address[] memory t = new address[](5);
        for (uint256 i = 0; i < 5; ++i) {
            t[i] = i == 1 ? address(frozen) : address(new MockERC20("Band", "BAND", 18));
            _listWith(t[i], SUPPLY);
        }
        IndexHub idx = IndexHub(factory.createIndex("Frozen", "FRZ", t, K));
        _issueBand(idx, alice, 10e18);
        _raiseFirst(t);
        frozen.setPaused(true);

        _openAuction(idx, 0, attacker);
        vm.warp(block.timestamp + idx.AUCTION_DURATION()); // the frozen component is sold at the floor
        MockRebalanceExecutor executor = new MockRebalanceExecutor();
        vm.expectRevert(bytes("paused"));
        executor.execute(idx, "");

        vm.prank(guardian);
        idx.cancelRebalance();
        _openAuction(idx, 1 << 1, guardian);
        vm.warp(block.timestamp + idx.AUCTION_DURATION());
        executor.execute(idx, "");
        assertEq(idx.rebalanceNonce(), 1, "the guardian's keep mask routes around the frozen component");
    }

    function test_XA02_aStrangerWaitsOutAnUnfilledAuctionBeforeRestarting() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        uint256 eta = _openAuction(idx, 0, attacker);
        uint256 deadline = eta + idx.AUCTION_DURATION();

        vm.warp(deadline + 1);
        assertFalse(idx.canStartRebalance());
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, attacker));
        idx.startRebalance(0);

        vm.prank(guardian);
        idx.startRebalance(0);
        (uint256 vetted,,,,) = idx.pendingRebalance();
        assertEq(vetted, block.timestamp + idx.REBALANCE_DELAY());

        vm.prank(guardian);
        idx.cancelRebalance();
        vm.warp(idx.restartAllowedAt());
        assertTrue(idx.canStartRebalance(), "a cancel holds strangers off for the same wait, not longer");
        vm.prank(attacker);
        idx.startRebalance(0);
        (eta,,,,) = idx.pendingRebalance();
        vm.warp(eta + idx.AUCTION_DURATION() + idx.REBALANCE_DELAY());
        assertTrue(idx.canStartRebalance());
        vm.prank(attacker);
        idx.startRebalance(0);
    }

    /// @dev A zap on its own router, which takes half the input of every hop and prices every hop one raw unit for
    ///      one, and a one-component index of a whole LINK.
    function _halfFilled() internal returns (IndexHub idx, IndexZap halfZap) {
        MockUniversalRouter half = new MockUniversalRouter(poolManager);
        half.setMode(MockUniversalRouter.Mode.PartialFirstHop);
        half.setPrice(address(link), 1e18, 18);
        half.setPrice(address(weth), 1e18, 18);
        half.setPrice(address(usdc), 1e18, 18);
        weth.mint(address(half.inventory()), 100e18);
        usdc.mint(address(half.inventory()), 100e18);
        halfZap = new IndexZap(factory, half);

        address[] memory t = new address[](1);
        t[0] = address(link);
        idx = IndexHub(factory.createIndex("Link One", "LNK1", t, K));

        link.mint(alice, 1e18);
        vm.startPrank(alice);
        link.approve(address(idx), 1e18);
        idx.issue(1e18, alice);
        idx.approve(address(halfZap), 1e18);
        vm.stopPrank();
    }

    function test_XA08_aLaterHopsUnsoldInputReachesTheRecipient() public {
        (IndexHub idx, IndexZap halfZap) = _halfFilled();
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](1);
        legs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(address(link), FEE, address(weth), FEE, address(usdc)),
            v4Path: new PathKey[](0),
            minAmountOut: 0
        });

        uint256 wethBefore = weth.balanceOf(alice);
        vm.prank(alice);
        uint256 out = halfZap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1, legs, alice));

        assertEq(out, 2.5e17, "the payout is what the last hop sold");
        assertEq(link.balanceOf(alice), 5e17, "the first hop's unsold input comes back");
        assertEq(weth.balanceOf(alice) - wethBefore, 2.5e17, "and so does the second hop's");
        assertEq(weth.balanceOf(address(halfZap)), 0);
        assertEq(link.balanceOf(address(halfZap)), 0);
    }

    function test_XA08_unsoldTokenOutIsPaidOutAndAnEmptyHopReverts() public {
        (IndexHub idx, IndexZap halfZap) = _halfFilled();
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](1);
        legs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(address(link), FEE, address(usdc), FEE, address(weth), FEE, address(usdc)),
            v4Path: new PathKey[](0),
            minAmountOut: 0
        });

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out = halfZap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1, legs, alice));

        assertEq(out, 3.75e17, "0.5 bought, 0.25 sold on, 0.125 bought back");
        assertEq(usdc.balanceOf(alice) - usdcBefore, 3.75e17);
        assertEq(usdc.balanceOf(address(halfZap)), 0);
        assertEq(weth.balanceOf(address(halfZap)), 0);

        legs[0] = IIndexZap.BurnLeg({
            v3Path: abi.encodePacked(address(link), FEE, address(weth), FEE, address(usdc)),
            v4Path: new PathKey[](0),
            minAmountOut: 0
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
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        assertFalse(idx.canStartRebalance(), "not due yet");
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        assertTrue(idx.canStartRebalance());

        uint256 eta = _openAuction(idx, 0, attacker);
        assertFalse(idx.canStartRebalance(), "an auction is live");
        vm.warp(eta + idx.AUCTION_DURATION() + idx.REBALANCE_DELAY());

        (uint256 stale,,,,) = idx.pendingRebalance();
        assertGt(stale, 0, "an unfilled auction keeps its eta");
        assertTrue(idx.canStartRebalance(), "and the index is due again");
        vm.prank(attacker);
        idx.startRebalance(0);
    }

    /// @dev XA-27, re-targeted: a settlement that sends nothing out is taken at λmax, so its units are the same
    ///      whoever executes and whenever. Each growing leg still asks for its change in backing rounded up, one raw
    ///      unit on a supply of one wei, so the executor pays that dust to the holders rather than the reverse (SA-07).
    function test_XA27_aSettlementThatSendsNothingOutIsTakenAtTheTopOfTheBand() public {
        (, address[] memory t) = _bandBasket();
        // Every unit at MIN_RAW_UNITS and one wei of shares: no leg's backing reaches a raw unit.
        vm.prank(attacker);
        IndexHub idx = IndexHub(factory.createIndex("Dust", "DUST", t, factory.MIN_RAW_UNITS() * K / SUPPLY));
        _issueBand(idx, alice, 1);
        _raiseFirst(t);

        (, uint256[] memory unitsBefore) = idx.components();
        uint256 eta = _openAuction(idx, 0, attacker);
        (uint256 lambda, uint256[] memory atOpen,,) = idx.previewRebalance();
        vm.warp(eta + idx.AUCTION_DURATION()); // where a lone executor would otherwise pick the floor
        (, uint256 lambdaMax) = _band(idx);
        assertEq(lambda, lambdaMax);
        assertEq(idx.currentLambda(), lambdaMax, "nothing leaves the index, so the auction has nothing to price");
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = idx.previewRebalance();
        new MockRebalanceExecutor().execute(idx, "");

        (, uint256[] memory units) = idx.components();
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(amountsOut[i], 0, "nothing leaves");
            assertEq(amountsIn[i], atOpen[i] > unitsBefore[i] ? 1 : 0, "a growing leg asks one raw unit");
            assertEq(units[i], atOpen[i], "the open's units, whoever executes and whenever");
        }
    }

    function test_XA27_aSupplyThatStillMovesUnitsKeepsTheAuction() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        uint256 eta = _openAuction(idx, 0, attacker);
        vm.warp(eta + idx.AUCTION_DURATION());
        (uint256 lambdaMin,) = _band(idx);
        assertEq(idx.currentLambda(), lambdaMin, "a live auction still decays");
    }

    function test_XA28_anExecutorCannotDeliverLessBecauseTheIndexHoldsASurplus() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        MockERC20 grown = MockERC20(t[0]); // the component the rebalance buys
        grown.mint(address(idx), 1e18); // a donation, or rounding dust the index kept
        _raiseFirst(t);

        _openAuction(idx, 0, attacker);
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = idx.previewRebalance();
        uint256 held = grown.balanceOf(address(idx));
        uint256 required = held - amountsOut[0] + amountsIn[0];

        MockRebalanceExecutor executor = new MockRebalanceExecutor();
        executor.setMode(MockRebalanceExecutor.Mode.Short);
        executor.setShortComponent(0);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexHub.RebalanceUnderfunded.selector, address(grown), required - 1, required)
        );
        executor.execute(idx, "");

        executor.setMode(MockRebalanceExecutor.Mode.Honest);
        executor.execute(idx, "");
        assertEq(grown.balanceOf(address(idx)), required, "the surplus is still in the index");
    }

    function test_XA59_everyProposalCarriesItsOwnId() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        uint256 eta = _openAuction(idx, 0, attacker);
        assertEq(idx.proposalCount(), 1);

        vm.prank(guardian);
        idx.cancelRebalance();
        vm.warp(idx.restartAllowedAt());
        (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax) = idx.previewBand(0);
        eta = block.timestamp + idx.REBALANCE_DELAY();
        vm.expectEmit(true, true, true, true, address(idx));
        emit IIndexHub.RebalanceStarted(2, 1, attacker, 0, lambdaMin, lambdaMax, ratios, eta);
        vm.prank(attacker);
        idx.startRebalance(0);

        // The third proposal follows the second's expiry, with no event of its own to mark it.
        vm.warp(eta + idx.AUCTION_DURATION() + idx.REBALANCE_DELAY());
        vm.prank(attacker);
        idx.startRebalance(0);
        assertEq(idx.proposalCount(), 3, "three attempts, all at rebalance nonce 1");
        assertEq(idx.rebalanceNonce(), 0);

        (eta,,,,) = idx.pendingRebalance();
        vm.warp(eta);
        vm.recordLogs();
        new MockRebalanceExecutor().execute(idx, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != IIndexHub.Rebalanced.selector) continue;
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

    // ---------------------------------------------------------------------
    // VR-03, re-targeted: a fill never takes more than the change in backing
    // ---------------------------------------------------------------------

    /// @dev VR-03. The rule once floored a target's share of value into units, so a fill could pay an executor with no
    ///      auction discount at all. Units now round up, and at the open no ratio exceeds λ: nothing is sold, so an
    ///      executor filling there only pays.
    function test_VR03_aFillAtTheOpenNeverPaysTheExecutor() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        _openAuction(idx, 0, attacker);
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = idx.previewRebalance();
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(amountsOut[i], 0, "nothing leaves at the open");
        }
        assertGt(amountsIn[0], 0, "the bought leg is paid for");
        new MockRebalanceExecutor().execute(idx, "");
        assertEq(idx.rebalanceNonce(), 1, "an honest fill still settles");
    }

    /// @dev VR-03, the other side: an executor whose callback delivers nothing cannot settle a fill that buys
    ///      anything, and on a dust supply every leg that is bought asks for at least a raw unit whenever its backing
    ///      moves.
    function test_VR03_anEmptyExecutorCannotSettleAFillThatBuysAnything() public {
        (IndexHub idx, address[] memory t) = _bandBasket();
        _raiseFirst(t);
        _openAuction(idx, 0, attacker);
        vm.warp(block.timestamp + 12 hours);
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = idx.previewRebalance();
        assertGt(amountsOut[1], 0, "a shrinking leg moves raw units");
        assertGt(amountsIn[0], 0, "so the growing leg is paid for, not floored to nothing");

        MockRebalanceExecutor noop = new MockRebalanceExecutor();
        noop.setMode(MockRebalanceExecutor.Mode.Noop);
        vm.expectPartialRevert(IIndexHub.RebalanceUnderfunded.selector);
        noop.execute(idx, "");
        assertEq(idx.rebalanceNonce(), 0, "nothing settled");
        assertEq(MockERC20(t[1]).balanceOf(address(noop)), 0, "and the executor took nothing");
    }
}
