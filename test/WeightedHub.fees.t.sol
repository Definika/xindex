// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {WeightedTest} from "./WeightedTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHubFactory} from "./mocks/MockHubFactory.sol";
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";

/// @notice The hub's fees in shares, its gate and its rebalance interval: what the website's creator fee, trading
///         fee, recommendator commission, private index and rebalance cadence come to on chain.
/// @dev The policy is the platform's cap, 25 bps, with half of it to a referrer, and the index charges the creator's
///      cap, 100 bps, so every fee path carries value. Expected figures are restated as integer arithmetic here, never
///      read back from the hub.
contract WeightedHubFeesTest is WeightedTest {
    uint256 constant BPS = 10_000;
    uint256 constant CREATOR_FEE = 100;
    uint256 constant PLATFORM_FEE = 25;
    uint256 constant REFERRAL_SHARE = 5000;
    uint256 constant FEE = CREATOR_FEE + PLATFORM_FEE;
    uint256 constant CREATOR_STREAMING = 500;
    uint256 constant PLATFORM_STREAMING = 100;
    uint256 constant STREAMING = CREATOR_STREAMING + PLATFORM_STREAMING;
    /// @dev A year of basis points: the streaming rate times the seconds elapsed, over this, is the share of the
    ///      index the fee takes.
    uint256 constant WHOLE = 365 days * BPS;

    address platform = makeAddr("platform");
    address referrer = makeAddr("referrer");
    address bob = makeAddr("bob");
    WeightedHub index;

    function setUp() public {
        _deploy();
        _listAll();
        vm.prank(owner);
        factory.setFeePolicy(uint16(PLATFORM_FEE), 0, uint16(REFERRAL_SHARE), platform, 0);
        index = _create(_defaultSpecs(), _feeParams(uint16(CREATOR_FEE), 7 days, false));
    }

    function _feeParams(uint16 creatorFeeBps, uint32 interval, bool gated)
        internal
        pure
        returns (IWeightedIndexFactory.IndexParams memory)
    {
        return IWeightedIndexFactory.IndexParams({
            creatorFeeBps: creatorFeeBps,
            creatorStreamingBps: 0,
            maxPlatformFeeBps: uint16(PLATFORM_FEE),
            maxPlatformStreamingBps: 100,
            rebalanceInterval: interval,
            gated: gated,
            listed: true
        });
    }

    /// @dev An index at both streaming caps, 500 bps a year to the creator and 100 to the platform, created under a
    ///      policy that streams and restored to the one that does not, which the other indexes stay on.
    function _streamingIndex() internal returns (WeightedHub streaming) {
        vm.prank(owner);
        factory.setFeePolicy(uint16(PLATFORM_FEE), uint16(PLATFORM_STREAMING), uint16(REFERRAL_SHARE), platform, 0);
        streaming = _create(_defaultSpecs(), _streamingParams());
        vm.prank(owner);
        factory.setFeePolicy(uint16(PLATFORM_FEE), 0, uint16(REFERRAL_SHARE), platform, 0);
    }

    function _streamingParams() internal pure returns (IWeightedIndexFactory.IndexParams memory params) {
        params = _feeParams(uint16(CREATOR_FEE), 7 days, false);
        params.creatorStreamingBps = uint16(CREATOR_STREAMING);
    }

    /// @dev What an accrual after `elapsed` seconds mints on `supply`, and the scale it leaves from `scale`: the
    ///      rate's share `f` of the index as `supply · f / (1 − f)` shares, the scale shrunk by `supply / (supply +
    ///      minted)`, both rounded down, with `f` capped just under one.
    function _expectedAccrual(uint256 supply, uint256 scale, uint256 elapsed)
        internal
        pure
        returns (uint256 feeShares, uint256 newScale)
    {
        uint256 part = STREAMING * elapsed;
        if (part >= WHOLE) part = WHOLE - 1;
        feeShares = Math.mulDiv(supply, part, WHOLE - part);
        newScale = Math.mulDiv(scale, supply, supply + feeShares);
    }

    /// @dev The index's balance of each component, as the test sees it.
    function _balances(WeightedHub idx, address who) internal view returns (uint256[] memory balances) {
        address[] memory tokens = idx.componentTokens();
        balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            balances[i] = MockERC20(tokens[i]).balanceOf(who);
        }
    }

    /// @dev Shares a deposit must back for `shares` to come out: the fee on top, rounded up.
    function _gross(uint256 shares) internal pure returns (uint256) {
        return (shares * BPS + (BPS - FEE) - 1) / (BPS - FEE);
    }

    /// @dev The platform's part of `feeShares`, before any referrer takes a share of it.
    function _platformPart(uint256 feeShares) internal pure returns (uint256) {
        return feeShares * PLATFORM_FEE / FEE;
    }

    /// @dev Mints the basket for `shares` to `to` and approves the index for it.
    function _fund(WeightedHub idx, address to, uint256 shares) internal {
        address[] memory tokens = idx.componentTokens();
        uint256[] memory amounts = idx.previewIssue(shares);
        vm.startPrank(to);
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(to, amounts[i]);
            MockERC20(tokens[i]).approve(address(idx), amounts[i]);
        }
        vm.stopPrank();
    }

    /// @dev Funds `to` and issues `shares` to it, naming `ref`.
    function _issueWith(WeightedHub idx, address to, uint256 shares, address ref) internal {
        _fund(idx, to, shares);
        vm.prank(to);
        idx.issue(shares, to, ref);
    }

    function _assertBacked(WeightedHub idx) internal view {
        (address[] memory tokens, uint256[] memory units) = idx.components();
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 required = Math.mulDiv(idx.totalSupply(), units[i], 1e18) + idx.totalClaims(tokens[i]);
            assertGe(MockERC20(tokens[i]).balanceOf(address(idx)), required, "backing");
        }
    }

    // ---------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------

    function test_theConfigIsTheCreatorsParamsAndThePolicy() public view {
        IWeightedHub.Config memory cfg = index.config();
        assertEq(cfg.creatorFeeBps, CREATOR_FEE);
        assertEq(cfg.platformFeeBps, PLATFORM_FEE);
        assertEq(cfg.referralShareBps, REFERRAL_SHARE);
        assertEq(cfg.rebalanceInterval, 7 days);

        assertEq(index.MIN_REBALANCE_INTERVAL(), factory.MIN_REBALANCE_INTERVAL());
    }

    function test_initializeChecksTheConfig() public {
        MockHubFactory mock = new MockHubFactory(address(pyth));
        IWeightedHub.ComponentInit[] memory inits = new IWeightedHub.ComponentInit[](2);
        inits[0] = IWeightedHub.ComponentInit(address(eth), ETH_UNITS, 5000, ETH_ID, 18);
        inits[1] = IWeightedHub.ComponentInit(address(btc), BTC_UNITS, 5000, BTC_ID, 8);

        IWeightedHub.Config memory cfg = IWeightedHub.Config(100, 26, 0, 0, 0, 7 days);
        vm.expectRevert(IWeightedHub.InvalidConfig.selector);
        mock.create(inits, cfg);
        cfg = IWeightedHub.Config(0, 0, 10_001, 0, 0, 7 days);
        vm.expectRevert(IWeightedHub.InvalidConfig.selector);
        mock.create(inits, cfg);
        cfg = IWeightedHub.Config(0, 0, 0, 0, 0, 7 days - 1);
        vm.expectRevert(IWeightedHub.InvalidConfig.selector);
        mock.create(inits, cfg);
        cfg = IWeightedHub.Config(0, 0, 0, 500, 101, 7 days);
        vm.expectRevert(IWeightedHub.InvalidConfig.selector);
        mock.create(inits, cfg);

        cfg = IWeightedHub.Config(100, 25, 10_000, 0, 0, 7 days);
        WeightedHub ok = mock.create(inits, cfg);
        assertEq(ok.config().referralShareBps, 10_000);
    }

    // ---------------------------------------------------------------------
    // Issue
    // ---------------------------------------------------------------------

    function test_issueChargesTheFeeInSharesAndSplitsIt() public {
        uint256 shares = 1e18;
        uint256 gross = _gross(shares);
        uint256 feeShares = gross - shares;
        uint256 platformShares = _platformPart(feeShares);
        uint256 referrerShares = platformShares * REFERRAL_SHARE / BPS;
        uint256 creatorShares = feeShares - platformShares;
        assertGt(referrerShares, 0);

        // The deposit backs the gross shares, rounded up per component.
        uint256[] memory need = index.previewIssue(shares);
        assertEq(need[0], (gross * ETH_UNITS + 1e18 - 1) / 1e18, "eth for the gross shares");
        assertEq(need[1], (gross * BTC_UNITS + 1e18 - 1) / 1e18, "btc for the gross shares");
        assertEq(need[2], (gross * USD_UNITS + 1e18 - 1) / 1e18, "usd for the gross shares");

        _fund(index, alice, shares);
        vm.prank(alice);
        vm.expectEmit(address(index));
        emit IWeightedHub.FeeSharesMinted(
            referrer, creator, platform, creatorShares, platformShares - referrerShares, referrerShares
        );
        index.issue(shares, alice, referrer);

        assertEq(index.balanceOf(alice), shares, "alice gets exactly what she asked for");
        assertEq(index.balanceOf(creator), creatorShares, "the creator's part");
        assertEq(index.balanceOf(platform), platformShares - referrerShares, "the platform's part, less the referral");
        assertEq(index.balanceOf(referrer), referrerShares, "the referrer's part");
        assertEq(index.totalSupply(), gross, "every fee share is minted, none twice");
        assertEq(eth.balanceOf(address(index)), need[0]);
        _assertBacked(index);
    }

    function test_issueWithoutAReferrerLeavesThePlatformWhole() public {
        uint256 gross = _gross(1e18);
        uint256 feeShares = gross - 1e18;
        _issue(index, alice, 1e18);
        assertEq(index.balanceOf(platform), _platformPart(feeShares));
        assertEq(index.balanceOf(creator), feeShares - _platformPart(feeShares));
        assertEq(index.balanceOf(referrer), 0);
    }

    function test_aSelfReferralDiscountsOnlyThePlatformsPart() public {
        uint256 gross = _gross(1e18);
        uint256 feeShares = gross - 1e18;
        uint256 platformShares = _platformPart(feeShares);
        _issueWith(index, alice, 1e18, alice);
        assertEq(index.balanceOf(alice), 1e18 + platformShares * REFERRAL_SHARE / BPS);
        assertEq(index.balanceOf(creator), feeShares - platformShares, "the creator loses nothing to a self-referral");
    }

    function test_aReferrerThatCouldNotHoldSharesIsNobody() public {
        uint256 gross = _gross(1e18);
        uint256 feeShares = gross - 1e18;
        _fund(index, alice, 1e18);
        vm.prank(alice);
        vm.expectEmit(address(index));
        emit IWeightedHub.FeeSharesMinted(
            address(0), creator, platform, feeShares - _platformPart(feeShares), _platformPart(feeShares), 0
        );
        index.issue(1e18, alice, address(index));
        _issueWith(index, alice, 1e18, address(factory));
        assertEq(index.balanceOf(platform), 2 * _platformPart(feeShares));
    }

    function test_aZeroFeeIndexMintsNoFeeShares() public {
        WeightedHub free = _create(_defaultSpecs(), _feeParams(0, 7 days, false));
        vm.prank(owner);
        factory.setFeePolicy(0, 0, 0, platform, 0);
        WeightedHub freer = _create(_defaultSpecs(), _feeParams(0, 7 days, false));
        assertEq(freer.previewIssue(1e18)[0], ETH_UNITS, "no fee on top of the basket");
        assertEq(free.previewIssue(1e18)[0], (_gross25(1e18) * ETH_UNITS + 1e18 - 1) / 1e18, "the platform's alone");
        _issueWith(free, alice, 1e18, referrer);
        _issueWith(freer, alice, 1e18, referrer);
        // A platform fee alone: the creator's part is zero and is not minted.
        assertEq(free.totalSupply(), _gross25(1e18));
        assertEq(free.balanceOf(creator), 0);
        assertEq(free.balanceOf(platform) + free.balanceOf(referrer), _gross25(1e18) - 1e18);
        assertEq(freer.totalSupply(), 1e18, "no fee at all");
        assertEq(freer.balanceOf(creator) + freer.balanceOf(platform) + freer.balanceOf(referrer), 0);
    }

    /// @dev Gross shares under the platform's 25 bps alone.
    function _gross25(uint256 shares) internal pure returns (uint256) {
        return (shares * BPS + (BPS - PLATFORM_FEE) - 1) / (BPS - PLATFORM_FEE);
    }

    function test_theRecipientsAreReadAtEachCall() public {
        address newCreator = makeAddr("newCreator");
        address newPlatform = makeAddr("newPlatform");
        vm.prank(creator);
        factory.transferCreator(address(index), newCreator);
        vm.prank(owner);
        factory.setFeePolicy(uint16(PLATFORM_FEE), 0, uint16(REFERRAL_SHARE), newPlatform, 0);
        uint256 feeShares = _gross(1e18) - 1e18;
        _issue(index, alice, 1e18);
        assertEq(index.balanceOf(newCreator), feeShares - _platformPart(feeShares));
        assertEq(index.balanceOf(newPlatform), _platformPart(feeShares));
        assertEq(index.balanceOf(creator) + index.balanceOf(platform), 0);
    }

    /// @dev The real factory never answers a zero or trap recipient; the hub still has to mint somewhere, so that no
    ///      recipient can block a mint or an exit: the creator's part to `to`, the platform's to the creator.
    function test_aRecipientThatCouldNotHoldSharesIsReplaced() public {
        MockHubFactory mock = new MockHubFactory(address(pyth));
        IWeightedHub.ComponentInit[] memory inits = new IWeightedHub.ComponentInit[](2);
        inits[0] = IWeightedHub.ComponentInit(address(eth), ETH_UNITS, 5000, ETH_ID, 18);
        inits[1] = IWeightedHub.ComponentInit(address(btc), BTC_UNITS, 5000, BTC_ID, 8);
        WeightedHub idx = mock.create(inits, IWeightedHub.Config(100, 25, 5000, 0, 0, 7 days));
        uint256 feeShares = _gross(1e18) - 1e18;
        uint256 platformShares = _platformPart(feeShares);

        // No creator at all: everything the platform does not take goes to the minter.
        mock.set(true, address(0), platform);
        _issueWith(idx, alice, 1e18, address(0));
        assertEq(idx.balanceOf(alice), 1e18 + feeShares - platformShares);
        assertEq(idx.balanceOf(platform), platformShares);

        // The index itself as platform: its part goes to the creator.
        mock.set(true, creator, address(idx));
        _issueWith(idx, alice, 1e18, address(0));
        assertEq(idx.balanceOf(creator), feeShares);

        // Both unusable: the minter keeps the whole fee, and the mint still goes through.
        mock.set(true, address(mock), address(0));
        _fund(idx, alice, 1e18);
        vm.prank(alice);
        vm.expectEmit(address(idx));
        emit IWeightedHub.FeeSharesMinted(address(0), alice, address(0), feeShares, 0, 0);
        idx.issue(1e18, alice, address(0));

        // And so does a redeem.
        vm.prank(alice);
        idx.redeem(1e18, alice);
        assertEq(idx.balanceOf(alice), 2e18 + 2 * feeShares - platformShares + 1e18 * FEE / BPS);
        _assertBacked(idx);
    }

    // ---------------------------------------------------------------------
    // Redeem
    // ---------------------------------------------------------------------

    function test_redeemChargesTheFeeOutOfTheBurn() public {
        _issue(index, alice, 1e18);
        uint256 supplyBefore = index.totalSupply();
        uint256 creatorBefore = index.balanceOf(creator);
        uint256 platformBefore = index.balanceOf(platform);

        uint256 feeShares = 1e18 * FEE / BPS;
        uint256 net = 1e18 - feeShares;
        uint256[] memory got = index.previewRedeem(1e18);
        assertEq(got[0], net * ETH_UNITS / 1e18, "eth for the net shares, rounded down");
        assertEq(got[1], net * BTC_UNITS / 1e18, "btc for the net shares");
        assertEq(got[2], net * USD_UNITS / 1e18, "usd for the net shares");

        vm.expectEmit(address(index));
        emit IWeightedHub.FeeSharesMinted(
            address(0), creator, platform, feeShares - _platformPart(feeShares), _platformPart(feeShares), 0
        );
        vm.prank(alice);
        index.redeem(1e18, alice);

        assertEq(index.balanceOf(alice), 0);
        assertEq(eth.balanceOf(alice), got[0]);
        assertEq(btc.balanceOf(alice), got[1]);
        assertEq(usd.balanceOf(alice), got[2]);
        assertEq(index.totalSupply(), supplyBefore - net, "the burn less the fee's shares");
        assertEq(index.balanceOf(creator) - creatorBefore, feeShares - _platformPart(feeShares));
        assertEq(index.balanceOf(platform) - platformBefore, _platformPart(feeShares));
        _assertBacked(index);
    }

    function test_redeemSkippingChargesTheFeeAndBooksNetClaims() public {
        _issue(index, alice, 1e18);
        uint256 net = 1e18 - 1e18 * FEE / BPS;
        vm.prank(alice);
        index.redeemSkipping(1e18, alice, 1);
        assertEq(index.claimOf(alice, address(eth)), net * ETH_UNITS / 1e18, "the claim is the net backing");
        assertEq(btc.balanceOf(alice), net * BTC_UNITS / 1e18);
        assertEq(index.balanceOf(creator) + index.balanceOf(platform), 1e18 * FEE / BPS + (_gross(1e18) - 1e18));
        _assertBacked(index);
    }

    function test_aDustRedeemChargesNothing() public {
        _issue(index, alice, 1e18);
        uint256 supply = index.totalSupply();
        vm.prank(alice);
        index.redeem(79, alice);
        assertEq(index.totalSupply(), supply - 79, "79 shares at 125 bps round to no fee share");
    }

    function test_feeSharesRedeemLikeAnyOthers() public {
        _issue(index, alice, 1e18);
        uint256 held = index.balanceOf(creator);
        uint256[] memory got = index.previewRedeem(held);
        vm.prank(creator);
        index.redeem(held, creator);
        assertEq(eth.balanceOf(creator), got[0]);
        assertGt(got[0], 0);
        _assertBacked(index);
    }

    // ---------------------------------------------------------------------
    // Gate
    // ---------------------------------------------------------------------

    function test_aGatedIndexIssuesOnlyToWhomTheCreatorAllows() public {
        WeightedHub gated = _create(_defaultSpecs(), _feeParams(0, 7 days, true));
        assertTrue(factory.isGated(address(gated)));
        (bool allowed,,) = factory.feeTerms(address(gated), alice);
        assertFalse(allowed);

        uint256[] memory amounts = gated.previewIssue(1e18);
        vm.startPrank(alice);
        for (uint256 i = 0; i < 3; ++i) {
            MockERC20(gated.componentTokens()[i]).mint(alice, amounts[i]);
            MockERC20(gated.componentTokens()[i]).approve(address(gated), amounts[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.NotAllowedMinter.selector, alice));
        gated.issue(1e18, alice);
        vm.stopPrank();

        vm.prank(creator);
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.MinterAllowed(address(gated), alice, true);
        factory.setAllowedMinter(address(gated), alice, true);
        assertTrue(factory.isAllowedMinter(address(gated), alice));
        vm.prank(alice);
        gated.issue(1e18, alice);
        assertEq(gated.balanceOf(alice), 1e18);

        // The gate is on the recipient: an allowed payer cannot mint to a stranger.
        vm.prank(creator);
        factory.setAllowedMinter(address(gated), alice, false);
        _issue(index, alice, 1); // unrelated index, still open
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.NotAllowedMinter.selector, stranger));
        gated.issue(1, stranger);

        // Burns never read the gate.
        vm.prank(alice);
        gated.redeem(1e18, stranger);
        assertEq(eth.balanceOf(stranger), (1e18 - 1e18 * PLATFORM_FEE / BPS) * ETH_UNITS / 1e18);
    }

    function test_theCreatorOpensAGatedIndexForGood() public {
        WeightedHub gated = _create(_defaultSpecs(), _feeParams(0, 7 days, true));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        factory.openMinting(address(gated));

        vm.prank(creator);
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.MintingOpened(address(gated));
        factory.openMinting(address(gated));
        assertFalse(factory.isGated(address(gated)));
        _issue(gated, stranger, 1e18);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NotGated.selector, address(gated)));
        factory.openMinting(address(gated));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NotGated.selector, address(index)));
        factory.openMinting(address(index));
    }

    function test_theGateIsNotPartOfTheAddress() public {
        IWeightedIndexFactory.IndexParams memory open = _feeParams(0, 7 days, false);
        IWeightedIndexFactory.IndexParams memory gated = _feeParams(0, 7 days, true);
        address predicted = factory.predictIndexAddress(creator, "Weighted", "WGT", _defaultSpecs(), open);
        assertEq(factory.predictIndexAddress(creator, "Weighted", "WGT", _defaultSpecs(), gated), predicted);
        _create(_defaultSpecs(), gated);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.IndexAlreadyExists.selector, predicted));
        factory.createIndex("Weighted", "WGT", _defaultSpecs(), open);
    }

    // ---------------------------------------------------------------------
    // Interval
    // ---------------------------------------------------------------------

    function test_theRebalanceIntervalIsTheIndexs() public {
        WeightedHub monthly = _create(_defaultSpecs(), _feeParams(0, 30 days, false));
        assertEq(monthly.config().rebalanceInterval, 30 days);
        uint256 earliest = monthly.lastRebalance() + 30 days;

        vm.warp(monthly.lastRebalance() + 7 days);
        assertTrue(index.canStartRebalance(), "the weekly index is ready");
        assertFalse(monthly.canStartRebalance(), "the monthly one is not");
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceTooSoon.selector, earliest));
        monthly.startRebalance(0);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceTooSoon.selector, earliest));
        monthly.startRebalance(0);

        vm.warp(earliest - 1);
        assertFalse(monthly.canStartRebalance());
        vm.warp(earliest);
        assertTrue(monthly.canStartRebalance());
        monthly.startRebalance(0);
        (uint256 eta,) = monthly.pendingRebalance();
        assertEq(eta, earliest + monthly.REBALANCE_DELAY());
    }

    // ---------------------------------------------------------------------
    // Streaming
    // ---------------------------------------------------------------------

    function test_theStreamingRatesAreTheCreatorsAndThePolicys() public {
        WeightedHub streaming = _streamingIndex();
        IWeightedHub.Config memory cfg = streaming.config();
        assertEq(cfg.creatorStreamingBps, CREATOR_STREAMING);
        assertEq(cfg.platformStreamingBps, PLATFORM_STREAMING);
        assertEq(cfg.creatorFeeBps, CREATOR_FEE);
        assertEq(factory.MAX_CREATOR_STREAMING_BPS(), CREATOR_STREAMING);
        assertEq(factory.MAX_PLATFORM_STREAMING_BPS(), PLATFORM_STREAMING);
        assertEq(index.config().platformStreamingBps, 0, "the policy reaches only later indexes");
        assertEq(factory.platformStreamingBps(), 0);
    }

    function test_theFactoryChecksTheStreamingRates() public {
        IWeightedIndexFactory.IndexParams memory params = _streamingParams();
        params.creatorStreamingBps = uint16(CREATOR_STREAMING + 1);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedIndexFactory.StreamingFeeTooHigh.selector, CREATOR_STREAMING + 1)
        );
        factory.createIndex("Weighted", "WGT", _defaultSpecs(), params);

        vm.prank(owner);
        vm.expectRevert(IWeightedIndexFactory.InvalidFeePolicy.selector);
        factory.setFeePolicy(uint16(PLATFORM_FEE), uint16(PLATFORM_STREAMING + 1), uint16(REFERRAL_SHARE), platform, 0);

        // A creator names the highest platform streaming fee it accepts, as it does for the platform's mint fee.
        vm.prank(owner);
        factory.setFeePolicy(uint16(PLATFORM_FEE), uint16(PLATFORM_STREAMING), uint16(REFERRAL_SHARE), platform, 0);
        params = _streamingParams();
        params.maxPlatformStreamingBps = uint16(PLATFORM_STREAMING - 1);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWeightedIndexFactory.PlatformStreamingFeeTooHigh.selector, PLATFORM_STREAMING, PLATFORM_STREAMING - 1
            )
        );
        factory.createIndex("Weighted", "WGT", _defaultSpecs(), params);
        params.maxPlatformStreamingBps = uint16(PLATFORM_STREAMING);
        assertEq(_create(_defaultSpecs(), params).config().platformStreamingBps, PLATFORM_STREAMING);
    }

    /// @dev Both streaming rates are terms of the index, so two indexes alike in all else live at different
    ///      addresses, unlike the gate.
    function test_theStreamingRatesArePartOfTheAddress() public {
        IWeightedIndexFactory.IndexParams memory flat = _feeParams(0, 7 days, false);
        IWeightedIndexFactory.IndexParams memory streaming = _feeParams(0, 7 days, false);
        streaming.creatorStreamingBps = 1;
        address flatAddress = factory.predictIndexAddress(creator, "Weighted", "WGT", _defaultSpecs(), flat);
        assertNotEq(factory.predictIndexAddress(creator, "Weighted", "WGT", _defaultSpecs(), streaming), flatAddress);
        assertEq(address(_create(_defaultSpecs(), flat)), flatAddress);
        _create(_defaultSpecs(), streaming);

        vm.prank(owner);
        factory.setFeePolicy(uint16(PLATFORM_FEE), 1, uint16(REFERRAL_SHARE), platform, 0);
        assertNotEq(factory.predictIndexAddress(creator, "Weighted", "WGT", _defaultSpecs(), flat), flatAddress);
        _create(_defaultSpecs(), flat);
    }

    /// @dev The clock starts at the first mint: an empty index accrues nothing, and the time before it is not charged
    ///      to whoever mints first.
    function test_nothingAccruesBeforeTheFirstMint() public {
        WeightedHub streaming = _streamingIndex();
        vm.warp(block.timestamp + 30 days);
        (uint256 feeShares, uint256 scale) = streaming.pendingStreamingFee();
        assertEq(feeShares, 0);
        assertEq(scale, 1e18);
        vm.recordLogs();
        streaming.accrueFees();
        assertEq(vm.getRecordedLogs().length, 0, "nothing to mint, nothing said");

        vm.warp(block.timestamp + 30 days);
        _issueWith(streaming, alice, 1e18, address(0));
        (feeShares, scale) = streaming.pendingStreamingFee();
        assertEq(feeShares, 0);
        assertEq(scale, 1e18);
        uint256 supply = streaming.totalSupply();
        vm.warp(block.timestamp + 1 days);
        (uint256 expected,) = _expectedAccrual(supply, 1e18, 1 days);
        (feeShares,) = streaming.pendingStreamingFee();
        assertEq(feeShares, expected, "a day's fee, not sixty-one days'");
    }

    function test_theStreamingFeeAccruesAsSharesAndShrinksEveryShare() public {
        WeightedHub streaming = _streamingIndex();
        _issueWith(streaming, alice, 1e18, address(0));
        uint256 supply = streaming.totalSupply();
        (, uint256[] memory units) = streaming.components();
        uint256 creatorBefore = streaming.balanceOf(creator);
        uint256 platformBefore = streaming.balanceOf(platform);

        vm.warp(block.timestamp + 30 days);
        (uint256 feeShares, uint256 scale) = _expectedAccrual(supply, 1e18, 30 days);
        assertGt(feeShares, 0);
        // The fee's shares are the rate's share of the index after them: 600 bps a year, thirty days of it.
        assertEq(feeShares, supply * (STREAMING * 30 days) / (WHOLE - STREAMING * 30 days));
        _assertPending(streaming, feeShares, scale);
        _assertScaled(streaming, units, scale);

        uint256 platformShares = feeShares * PLATFORM_STREAMING / STREAMING;
        vm.expectEmit(address(streaming));
        emit IWeightedHub.StreamingFeeAccrued(feeShares, scale);
        vm.expectEmit(address(streaming));
        emit IWeightedHub.FeeSharesMinted(address(0), creator, platform, feeShares - platformShares, platformShares, 0);
        vm.prank(stranger);
        streaming.accrueFees();
        assertEq(streaming.totalSupply(), supply + feeShares);
        assertEq(streaming.balanceOf(creator), creatorBefore + feeShares - platformShares);
        assertEq(streaming.balanceOf(platform), platformBefore + platformShares);
        _assertPending(streaming, 0, scale);
        _assertBackedWithin(streaming, units, scale, 2);
    }

    function _assertPending(WeightedHub idx, uint256 feeShares, uint256 scale) internal view {
        (uint256 pendingShares, uint256 pendingScale) = idx.pendingStreamingFee();
        assertEq(pendingShares, feeShares, "pending fee");
        assertEq(pendingScale, scale, "pending scale");
    }

    /// @dev Every share's units shrink by `scale`, and the views already say so.
    function _assertScaled(WeightedHub idx, uint256[] memory units, uint256 scale) internal view {
        (, uint256[] memory scaled) = idx.components();
        uint256[] memory out = idx.previewRedeem(1e18);
        for (uint256 i = 0; i < units.length; ++i) {
            assertEq(scaled[i], Math.mulDiv(units[i], scale, 1e18));
            assertEq(out[i], Math.mulDiv(1e18 - 1e18 * FEE / BPS, units[i] * scale, 1e36));
        }
    }

    /// @dev What the index holds backs every share at `scale`, the fee's included, to within `dust` raw units of
    ///      each component: the fee moves ownership, never tokens.
    function _assertBackedWithin(WeightedHub idx, uint256[] memory units, uint256 scale, uint256 dust) internal view {
        _assertBacked(idx);
        address[] memory tokens = idx.componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 required = Math.mulDiv(idx.totalSupply(), units[i] * scale, 1e36);
            uint256 held = MockERC20(tokens[i]).balanceOf(address(idx));
            assertGe(held, required);
            assertLe(held - required, dust);
        }
    }

    /// @dev An issue accrues before it mints: a minter's deposit is sized at the scale the accrual leaves, so it
    ///      pays nothing for the time before it.
    function test_anIssueAccruesFirst() public {
        WeightedHub streaming = _streamingIndex();
        _issueWith(streaming, alice, 1e18, address(0));
        uint256 supply = streaming.totalSupply();
        (, uint256[] memory units) = streaming.components();

        vm.warp(block.timestamp + 90 days);
        (uint256 feeShares, uint256 scale) = _expectedAccrual(supply, 1e18, 90 days);
        uint256[] memory need = streaming.previewIssue(3e18);
        for (uint256 i = 0; i < units.length; ++i) {
            assertEq(need[i], Math.mulDiv(_gross(3e18), units[i] * scale, 1e36, Math.Rounding.Ceil));
        }
        _fund(streaming, bob, 3e18);
        vm.expectEmit(address(streaming));
        emit IWeightedHub.StreamingFeeAccrued(feeShares, scale);
        vm.prank(bob);
        streaming.issue(3e18, bob, address(0));
        assertEq(streaming.totalSupply(), supply + feeShares + _gross(3e18), "the fee on the old supply, then bob");
        assertEq(streaming.balanceOf(bob), 3e18);
        (uint256 pendingShares, uint256 pendingScale) = streaming.pendingStreamingFee();
        assertEq(pendingShares, 0);
        assertEq(pendingScale, scale);
        _assertBacked(streaming);
    }

    /// @dev A redeem accrues before it burns: the burner is paid at the scale its preview showed.
    function test_aRedeemAccruesFirst() public {
        WeightedHub streaming = _streamingIndex();
        _issueWith(streaming, alice, 4e18, address(0));
        uint256 supply = streaming.totalSupply();
        (, uint256[] memory units) = streaming.components();

        vm.warp(block.timestamp + 91 days);
        (uint256 feeShares, uint256 scale) = _expectedAccrual(supply, 1e18, 91 days);
        uint256[] memory out = streaming.previewRedeem(1e18);
        for (uint256 i = 0; i < units.length; ++i) {
            assertEq(out[i], Math.mulDiv(1e18 - 1e18 * FEE / BPS, units[i] * scale, 1e36));
        }
        uint256[] memory before = _balances(streaming, alice);
        vm.expectEmit(address(streaming));
        emit IWeightedHub.StreamingFeeAccrued(feeShares, scale);
        vm.prank(alice);
        streaming.redeem(1e18, alice);
        uint256[] memory afterwards = _balances(streaming, alice);
        for (uint256 i = 0; i < units.length; ++i) {
            assertEq(afterwards[i] - before[i], out[i], "paid what the preview showed");
        }
        assertEq(streaming.totalSupply(), supply + feeShares - 1e18 + 1e18 * FEE / BPS);
        _assertBacked(streaming);
    }

    /// @dev A settlement accrues first, works on the units every share then carries, and records units that carry
    ///      the scale, so the scale starts from one again; its preview shows exactly that.
    function test_aSettlementAccruesFirstAndStartsTheScaleFromOne() public {
        WeightedHub streaming = _streamingIndex();
        _issueWith(streaming, alice, 100e18, address(0));
        uint256 since = block.timestamp;
        uint256 supply = streaming.totalSupply();
        (, uint256[] memory units) = streaming.components();

        _openMidAuction(streaming);
        (uint256 feeShares, uint256 scale) = _expectedAccrual(supply, 1e18, block.timestamp - since);
        assertGt(feeShares, 0);
        (uint256 mu, uint256[] memory previewUnits, uint256[] memory out, uint256[] memory in_) =
            streaming.previewRebalance(_structs3(2500e8, BTC_PRICE, USD_PRICE));
        assertEq(mu, 1e18);

        MockWeightedExecutor executor = new MockWeightedExecutor();
        vm.expectEmit(address(streaming));
        emit IWeightedHub.StreamingFeeAccrued(feeShares, scale);
        executor.execute(streaming, "", _updates(streaming, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE)));
        assertEq(executor.lastAmountsOut(), out);
        assertEq(executor.lastAmountsIn(), in_);
        assertEq(streaming.totalSupply(), supply + feeShares);
        _assertSettledAtScale(streaming, previewUnits, units, scale, out[0]);
    }

    /// @dev Starts a rebalance as soon as the interval allows and warps to the auction's midpoint, where μ is one.
    function _openMidAuction(WeightedHub idx) internal {
        vm.warp(idx.lastRebalance() + 7 days);
        idx.startRebalance(0);
        (uint256 eta,) = idx.pendingRebalance();
        vm.warp(eta + idx.AUCTION_DURATION() / 2);
    }

    /// @dev After the fill: the preview's units are the index's and carry no scale, ETH shrank and BTC grew from the
    ///      scaled units, and the executor was paid from those at the supply the accrual left.
    function _assertSettledAtScale(
        WeightedHub idx,
        uint256[] memory previewUnits,
        uint256[] memory units,
        uint256 scale,
        uint256 ethOut
    ) internal view {
        (, uint256[] memory afterwards) = idx.components();
        assertEq(afterwards, previewUnits);
        (uint256 pendingShares, uint256 pendingScale) = idx.pendingStreamingFee();
        assertEq(pendingShares, 0);
        assertEq(pendingScale, 1e18, "the new units carry the scale");
        uint256 scaledEth = Math.mulDiv(units[0], scale, 1e18);
        assertLt(afterwards[0], scaledEth);
        assertGt(afterwards[1], Math.mulDiv(units[1], scale, 1e18));
        assertEq(ethOut, Math.mulDiv(idx.totalSupply(), scaledEth - afterwards[0], 1e18));
        _assertBacked(idx);
    }

    /// @dev A supply too small for one share of fee keeps the clock, so the fee is not lost to rounding call by call.
    function test_aSupplyTooSmallForAFeeShareKeepsTheClock() public {
        WeightedHub streaming = _streamingIndex();
        _issueWith(streaming, alice, 4937, address(0));
        assertEq(streaming.totalSupply(), 5000);
        vm.warp(block.timestamp + 1 days);
        (uint256 feeShares,) = streaming.pendingStreamingFee();
        assertEq(feeShares, 0, "a day's fee on 5,000 wei rounds to nothing");
        vm.recordLogs();
        streaming.accrueFees();
        assertEq(vm.getRecordedLogs().length, 0);
        vm.warp(block.timestamp + 1 days);
        (uint256 expected,) = _expectedAccrual(5000, 1e18, 2 days);
        assertEq(expected, 1);
        (feeShares,) = streaming.pendingStreamingFee();
        assertEq(feeShares, 1, "two days' fee, the clock having kept the first");
    }

    /// @dev After a lifetime without an accrual the fee's share is capped just under the whole, so the arithmetic
    ///      answers and the last holder can still leave.
    function test_aGapOfALifetimeIsCappedJustUnderTheWhole() public {
        WeightedHub streaming = _streamingIndex();
        _issueWith(streaming, alice, 1e18, address(0));
        uint256 supply = streaming.totalSupply();
        vm.warp(block.timestamp + 20 * 365 days);
        (uint256 feeShares, uint256 scale) = _expectedAccrual(supply, 1e18, 20 * 365 days);
        assertEq(feeShares, supply * (WHOLE - 1));
        (uint256 pendingShares, uint256 pendingScale) = streaming.pendingStreamingFee();
        assertEq(pendingShares, feeShares);
        assertEq(pendingScale, scale);
        streaming.accrueFees();
        assertEq(streaming.totalSupply(), supply * WHOLE);
        uint256[] memory out = streaming.previewRedeem(1e18);
        assertGt(out[0], 0);
        vm.prank(alice);
        streaming.redeem(1e18, alice);
        assertEq(eth.balanceOf(alice), out[0]);
        _assertBacked(streaming);
    }

    function test_aZeroRateIndexNeverAccrues() public {
        _issueWith(index, alice, 1e18, address(0));
        vm.warp(block.timestamp + 365 days);
        (uint256 feeShares, uint256 scale) = index.pendingStreamingFee();
        assertEq(feeShares, 0);
        assertEq(scale, 1e18);
        vm.recordLogs();
        index.accrueFees();
        assertEq(vm.getRecordedLogs().length, 0);
        (, uint256[] memory units) = index.components();
        assertEq(units[0], ETH_UNITS);
        vm.prank(alice);
        index.redeem(1e18, alice);
        assertEq(eth.balanceOf(alice), Math.mulDiv(1e18 - 1e18 * FEE / BPS, ETH_UNITS, 1e18));
    }

    /// @dev A redeem too small for an exit fee still accrues the streaming fee first.
    function test_aDustRedeemStillAccruesTheStreamingFee() public {
        WeightedHub streaming = _streamingIndex();
        _issueWith(streaming, alice, 1e18, address(0));
        uint256 supply = streaming.totalSupply();
        vm.warp(block.timestamp + 10 days);
        (uint256 feeShares, uint256 scale) = _expectedAccrual(supply, 1e18, 10 days);
        vm.expectEmit(address(streaming));
        emit IWeightedHub.StreamingFeeAccrued(feeShares, scale);
        vm.prank(alice);
        streaming.redeem(10, alice);
        assertEq(streaming.totalSupply(), supply + feeShares - 10);
    }

    /// @dev The accrual's fallbacks are the mint's: a creator that could not hold shares hands its part to the
    ///      caller, and a platform that could not hands its part to the creator.
    function test_anAccrualsCreatorFallbackIsTheCaller() public {
        MockHubFactory mock = new MockHubFactory(address(pyth));
        IWeightedHub.ComponentInit[] memory inits = new IWeightedHub.ComponentInit[](2);
        inits[0] = IWeightedHub.ComponentInit(address(eth), ETH_UNITS, 5000, ETH_ID, 18);
        inits[1] = IWeightedHub.ComponentInit(address(btc), BTC_UNITS, 5000, BTC_ID, 8);
        WeightedHub idx = mock.create(inits, IWeightedHub.Config(0, 0, 0, 500, 100, 7 days));
        mock.set(true, creator, platform);
        _issueWith(idx, alice, 1e18, address(0));

        vm.warp(block.timestamp + 30 days);
        (uint256 feeShares,) = idx.pendingStreamingFee();
        assertGt(feeShares, 0);
        mock.set(true, address(idx), address(mock));
        vm.prank(stranger);
        vm.expectEmit(address(idx));
        emit IWeightedHub.FeeSharesMinted(address(0), stranger, address(0), feeShares, 0, 0);
        idx.accrueFees();
        assertEq(idx.balanceOf(stranger), feeShares);
        _assertBacked(idx);
    }
}
