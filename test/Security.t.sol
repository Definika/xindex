// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexToken} from "../src/interfaces/IIndexToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockHookToken, ITokenReceiverHook} from "./mocks/MockHookToken.sol";
import {MockPartialFillRouter} from "./mocks/MockPartialFillRouter.sol";
import {MockPausableToken} from "./mocks/MockPausableToken.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

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

/// @notice One regression test per finding of the Xindex v1 security review, each asserting the fixed
///         behaviour, plus the attacks that already failed before the fixes.
contract SecurityRegressionTest is Test {
    IndexFactory factory;
    MockSwapRouter router;
    IndexZap zap;
    IndexToken index;

    MockERC20 wbtc; // 8
    MockERC20 weth; // 18
    MockERC20 link; // 18
    MockERC20 usdc; // 6

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    uint24 constant FEE = 500;
    uint256 constant NAV_USD6 = 105e6; // 0.001 WBTC ($60) + 0.01 WETH ($30) + 1 LINK ($15)

    function setUp() public {
        factory = new IndexFactory(owner, guardian);
        router = new MockSwapRouter();
        zap = new IndexZap(factory, router);

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        link = new MockERC20("Chainlink", "LINK", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

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

        index = IndexToken(factory.createIndex("Blue Chip", "BLUE", _blueTokens(), _units(100_000, 1e16, 1e18)));
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _list(address token) internal {
        vm.prank(owner);
        factory.proposeListing(token);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

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

    function _mintLegs(address stable) internal view returns (IndexZap.MintLeg[] memory legs) {
        legs = new IndexZap.MintLeg[](3);
        legs[0] =
            IndexZap.MintLeg({path: abi.encodePacked(address(wbtc), FEE, address(weth), FEE, stable), maxAmountIn: 0});
        legs[1] = IndexZap.MintLeg({path: abi.encodePacked(address(weth), FEE, stable), maxAmountIn: 0});
        legs[2] =
            IndexZap.MintLeg({path: abi.encodePacked(address(link), FEE, address(weth), FEE, stable), maxAmountIn: 0});
    }

    function _burnLegs(address tokenOut) internal view returns (IndexZap.BurnLeg[] memory legs) {
        legs = new IndexZap.BurnLeg[](3);
        legs[0] = IndexZap.BurnLeg({
            path: abi.encodePacked(address(wbtc), FEE, address(weth), FEE, tokenOut), minAmountOut: 0
        });
        legs[1] = IndexZap.BurnLeg({path: abi.encodePacked(address(weth), FEE, tokenOut), minAmountOut: 0});
        legs[2] = IndexZap.BurnLeg({
            path: abi.encodePacked(address(link), FEE, address(weth), FEE, tokenOut), minAmountOut: 0
        });
    }

    function _mintParams(
        address idx,
        address tokenIn,
        uint256 maxIn,
        uint256 shares,
        IndexZap.MintLeg[] memory legs,
        address to
    ) internal view returns (IndexZap.MintParams memory) {
        return IndexZap.MintParams({
            index: idx,
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
        IndexZap.BurnLeg[] memory legs,
        address to
    ) internal view returns (IndexZap.BurnParams memory) {
        return IndexZap.BurnParams({
            index: idx,
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
        IndexToken idx = IndexToken(factory.createIndex("Half Paused", "HALF", t, u));

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
        address seen = factory.createIndex("Bitcoin Heavy", "BTCH", t, btcHeavy);

        // Re-org: creator B's createIndex is included first on the canonical chain.
        vm.revertToState(snap);
        vm.prank(creatorB);
        address other = factory.createIndex("Ether Heavy", "ETHH", t, ethHeavy);
        assertTrue(other != seen, "a different basket can never land at the address the user saw");

        // Until creator A's transaction is included again, the user's mint to `seen` cannot execute.
        uint256 maxIn = NAV_USD6 + NAV_USD6 / 100;
        usdc.mint(alice, maxIn);
        vm.startPrank(alice);
        usdc.approve(address(zap), maxIn);
        vm.expectRevert(abi.encodeWithSelector(IndexZap.NotIndex.selector, seen));
        zap.mintWithToken(_mintParams(seen, address(usdc), maxIn, 1e18, _mintLegs(address(usdc)), alice));
        vm.stopPrank();

        vm.prank(creatorA);
        assertEq(factory.createIndex("Bitcoin Heavy", "BTCH", t, btcHeavy), seen);
        assertEq(IndexToken(seen).symbol(), "BTCH");
    }

    function test_L03_legLimitStopsASandwichOnOneLeg() public {
        uint256 maxIn = NAV_USD6 + NAV_USD6 / 100;
        IndexZap.MintLeg[] memory legs = _mintLegs(address(usdc));
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
        vm.expectRevert(IndexZap.ZeroAmount.selector);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 0, _burnLegs(address(usdc)), alice));
        vm.stopPrank();
    }

    function test_L05_listingRequiresContractCode() public {
        address typo = makeAddr("typo");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotAContract.selector, typo));
        factory.proposeListing(typo);
    }

    function test_L07_hostileListingWaitsAndGuardianCanCancel() public {
        MockERC20 hostile = new MockERC20("Blue Chip Plus", "BLUE+", 18);
        vm.prank(owner);
        factory.proposeListing(address(hostile));
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
        factory.proposeListing(address(hostile));
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
        factory.proposeListing(address(token));
        uint256 deadline = factory.listingEta(address(token)) + factory.PROPOSAL_WINDOW();

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingExpired.selector, address(token), deadline));
        factory.executeListing(address(token));

        vm.prank(owner); // proposing again restarts the public delay
        factory.proposeListing(address(token));
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
        IndexToken idx = IndexToken(factory.createIndex("Hooked", "HOOKD", t, u));

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
        vm.expectRevert(abi.encodeWithSelector(IndexZap.TransferShortfall.selector, address(fot)));
        zap.mintWithToken(_mintParams(address(index), address(fot), 200e18, 1e18, _mintLegs(address(fot)), alice));
        vm.stopPrank();

        _issueBlue(alice, 1e18);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IndexZap.TransferShortfall.selector, address(fot)));
        zap.burnToToken(_burnParams(address(index), 1e18, address(fot), 1, _burnLegs(address(fot)), alice));
        index.redeem(1e18, alice); // the in-kind exit is unaffected
        vm.stopPrank();
        assertEq(wbtc.balanceOf(alice), 100_000);
    }

    function test_I04_indexAndZapRejectThemselvesAsRecipient() public {
        _issueBlue(alice, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.InvalidRecipient.selector, address(index)));
        index.redeem(1e18, address(index));

        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IndexZap.InvalidRecipient.selector, address(zap)));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), address(zap)));
        vm.expectRevert(abi.encodeWithSelector(IndexZap.InvalidRecipient.selector, address(index)));
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
        IndexToken idx = IndexToken(factory.createIndex("Mixed", "MIX", t, u));

        IndexZap.MintLeg[] memory legs = new IndexZap.MintLeg[](2);
        legs[0] = IndexZap.MintLeg({path: abi.encodePacked(address(weth), FEE, address(usdc)), maxAmountIn: 0});
        legs[1] = IndexZap.MintLeg({path: "", maxAmountIn: 0});

        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IndexZap.InsufficientBudget.selector, 50e6, 10e6));
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
        IndexZap.BurnParams memory p =
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
        address copy = factory.createIndex("Original", "ORIG", t, u);
        vm.prank(creator);
        address original = factory.createIndex("Original", "ORIG", t, u);

        assertTrue(copy != original);
        assertEq(factory.creatorOf(original), creator);
        assertEq(factory.creatorOf(copy), copier);
        assertEq(original, factory.predictIndexAddress(creator, "Original", "ORIG", t, u));
    }

    function test_I12_partialFillReturnsTheUnsoldPartToTheRecipient() public {
        MockPartialFillRouter half = new MockPartialFillRouter(3_000e6);
        usdc.mint(address(half), 1_000_000e6);
        IndexZap halfZap = new IndexZap(factory, half);

        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(weth);
        u[0] = 1e18;
        IndexToken idx = IndexToken(factory.createIndex("Ether", "ETH1", t, u));

        weth.mint(alice, 1e18);
        vm.startPrank(alice);
        weth.approve(address(idx), 1e18);
        idx.issue(1e18, alice);
        idx.approve(address(halfZap), 1e18);
        IndexZap.BurnLeg[] memory legs = new IndexZap.BurnLeg[](1);
        legs[0] = IndexZap.BurnLeg({path: abi.encodePacked(address(weth), FEE, address(usdc)), minAmountOut: 0});
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

        vm.startPrank(attacker);
        vm.expectRevert();
        zap.mintWithToken(_mintParams(address(index), address(usdc), 1_000e6, 1e18, _mintLegs(address(usdc)), attacker));
        vm.expectRevert();
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), attacker));
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
}
