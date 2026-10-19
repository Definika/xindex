// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {PythStructs} from "../src/interfaces/pyth/PythStructs.sol";
import {WeightedTest} from "./WeightedTest.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockPausableToken} from "./mocks/MockPausableToken.sol";

/// @notice The weighted hub outside rebalancing: initialization, issue, redeem, claims, recipients and views. Issue and
///         redeem must never read a price, which `test_issueAndRedeemNeverCallPyth` pins.
contract WeightedHubTest is WeightedTest {
    WeightedHub index;

    function setUp() public {
        _deploy();
        _listAll();
        index = _create(_defaultSpecs());
    }

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    function _inits() internal view returns (IWeightedHub.ComponentInit[] memory inits) {
        inits = new IWeightedHub.ComponentInit[](3);
        inits[0] = IWeightedHub.ComponentInit(address(eth), ETH_UNITS, 5000, ETH_ID, 18);
        inits[1] = IWeightedHub.ComponentInit(address(btc), BTC_UNITS, 3000, BTC_ID, 8);
        inits[2] = IWeightedHub.ComponentInit(address(usd), USD_UNITS, 2000, USD_ID, 6);
    }

    /// @dev A valid config: no fee, the shortest interval.
    function _cfg() internal pure returns (IWeightedHub.Config memory) {
        return IWeightedHub.Config({
            creatorFeeBps: 0,
            platformFeeBps: 0,
            referralShareBps: 0,
            creatorStreamingBps: 0,
            platformStreamingBps: 0,
            rebalanceInterval: 7 days
        });
    }

    function _clone() internal returns (WeightedHub) {
        return WeightedHub(Clones.clone(factory.IMPLEMENTATION()));
    }

    function test_initializeIsFactoryOnly() public {
        WeightedHub clone = _clone();
        IWeightedHub.ComponentInit[] memory inits = _inits();
        vm.expectRevert(IWeightedHub.NotFactory.selector);
        clone.initialize("X", "X", inits, _cfg());
    }

    function test_theImplementationCannotBeInitialized() public {
        WeightedHub implementation = WeightedHub(factory.IMPLEMENTATION());
        IWeightedHub.ComponentInit[] memory inits = _inits();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(address(factory));
        implementation.initialize("X", "X", inits, _cfg());
    }

    function test_initializeRunsOnce() public {
        IWeightedHub.ComponentInit[] memory inits = _inits();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(address(factory));
        index.initialize("X", "X", inits, _cfg());
    }

    function _expectInvalid(IWeightedHub.ComponentInit[] memory inits) internal {
        WeightedHub clone = _clone();
        vm.expectRevert(IWeightedHub.InvalidComponents.selector);
        vm.prank(address(factory));
        clone.initialize("X", "X", inits, _cfg());
    }

    function test_initializeRefusesBadComponents() public {
        _expectInvalid(new IWeightedHub.ComponentInit[](0));
        _expectInvalid(new IWeightedHub.ComponentInit[](101));

        IWeightedHub.ComponentInit[] memory one = new IWeightedHub.ComponentInit[](1);
        one[0] = IWeightedHub.ComponentInit(address(eth), ETH_UNITS, 10_000, ETH_ID, 18);
        _expectInvalid(one);

        IWeightedHub.ComponentInit[] memory twice = _inits();
        twice[2].token = address(eth);
        _expectInvalid(twice);

        IWeightedHub.ComponentInit[] memory inits = _inits();
        inits[0].token = address(0);
        _expectInvalid(inits);

        inits = _inits();
        inits[1].units = 0;
        _expectInvalid(inits);

        inits = _inits();
        inits[2].weight = 0;
        inits[0].weight = 7000;
        _expectInvalid(inits);

        inits = _inits();
        inits[0].weight = 10_001;
        _expectInvalid(inits);

        inits = _inits();
        inits[0].priceId = bytes32(0);
        _expectInvalid(inits);

        inits = _inits();
        inits[1].decimals = 19;
        _expectInvalid(inits);

        inits = _inits();
        inits[2].weight = 1999;
        _expectInvalid(inits);
    }

    /// @dev V5-M1: Pyth fills only the first of two equal ids, so a clone whose components shared one could never
    ///      settle. The hub refuses it even from a factory that did not check.
    function test_V5M1_initializeRefusesTwoComponentsOnOneFeed() public {
        IWeightedHub.ComponentInit[] memory inits = _inits();
        inits[2].priceId = ETH_ID;
        _expectInvalid(inits);
    }

    function test_initializeRefusesUnitsBeyondUint96() public {
        IWeightedHub.ComponentInit[] memory inits = _inits();
        inits[0].units = uint256(type(uint96).max) + 1;
        WeightedHub clone = _clone();
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, inits[0].units));
        vm.prank(address(factory));
        clone.initialize("X", "X", inits, _cfg());
    }

    function test_DA22_CRI25_CRI33_anUninitializedCloneDoesNothing() public {
        WeightedHub clone = _clone();
        vm.expectRevert(IWeightedHub.NotInitialized.selector);
        clone.issue(1, alice);
        vm.expectRevert(IWeightedHub.NotInitialized.selector);
        clone.redeem(1, alice);
        vm.expectRevert(IWeightedHub.NotInitialized.selector);
        clone.redeemSkipping(1, alice, 1);
        vm.expectRevert(IWeightedHub.NotInitialized.selector);
        clone.startRebalance(0);
        vm.expectRevert(IWeightedHub.NotInitialized.selector);
        clone.cancelRebalance();
        vm.expectRevert(IWeightedHub.NotInitialized.selector);
        clone.executeRebalance("", new bytes[](0));
        vm.expectRevert(IWeightedHub.NotInitialized.selector);
        clone.executeRebalance("", new bytes[](0), new uint256[](0));
        assertFalse(clone.canStartRebalance());
        assertFalse(WeightedHub(factory.IMPLEMENTATION()).canStartRebalance());
    }

    // ---------------------------------------------------------------------
    // Issue / redeem / claim
    // ---------------------------------------------------------------------

    function test_issuePullsTheBasketRoundedUp() public {
        uint256 shares = 1e18 + 1;
        uint256[] memory amounts = index.previewIssue(shares);
        assertEq(amounts[0], ETH_UNITS + 1, "0.025e18 * (1e18 + 1) / 1e18, rounded up");
        assertEq(amounts[1], BTC_UNITS + 1);
        assertEq(amounts[2], USD_UNITS + 1);

        eth.mint(alice, amounts[0]);
        btc.mint(alice, amounts[1]);
        usd.mint(alice, amounts[2]);
        vm.startPrank(alice);
        eth.approve(address(index), amounts[0]);
        btc.approve(address(index), amounts[1]);
        usd.approve(address(index), amounts[2]);
        vm.expectEmit(address(index));
        emit IWeightedHub.Issued(alice, alice, shares, amounts);
        index.issue(shares, alice);
        vm.stopPrank();
        assertEq(index.balanceOf(alice), shares);
        assertEq(eth.balanceOf(address(index)), ETH_UNITS + 1);
    }

    function test_issueToAnother() public {
        eth.mint(alice, ETH_UNITS);
        btc.mint(alice, BTC_UNITS);
        usd.mint(alice, USD_UNITS);
        vm.startPrank(alice);
        eth.approve(address(index), ETH_UNITS);
        btc.approve(address(index), BTC_UNITS);
        usd.approve(address(index), USD_UNITS);
        index.issue(1e18, stranger);
        vm.stopPrank();
        assertEq(index.balanceOf(stranger), 1e18);
    }

    function test_issueChecksItsArguments() public {
        vm.expectRevert(IWeightedHub.ZeroShares.selector);
        index.issue(0, alice);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        index.issue(1, address(0));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        index.issue(1, address(index));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(factory)));
        index.issue(1, address(factory));
    }

    function test_issueRefusesAFeeOnTransferComponent() public {
        MockFeeToken fee = new MockFeeToken();
        _list(address(fee), keccak256("FEE/USD"));
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = _spec(address(eth), 5000, ETH_UNITS);
        specs[1] = _spec(address(fee), 5000, 1e18);
        vm.prank(creator);
        WeightedHub feeIndex = WeightedHub(factory.createIndex("Fee", "FEE", specs, _params()));
        fee.mint(alice, 10e18);
        eth.mint(alice, ETH_UNITS);
        vm.startPrank(alice);
        fee.approve(address(feeIndex), 10e18);
        eth.approve(address(feeIndex), ETH_UNITS);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.TransferAmountMismatch.selector, address(fee)));
        feeIndex.issue(1e18, alice);
        vm.stopPrank();
    }

    /// @dev RT-05. `issue` refuses a component that arrives short, measured as the change in the index's balance across
    ///      the pull. Tested only on an index holding none of the token, where the balance afterwards is the change
    ///      itself, a check that added the balance before the pull, or read the balance alone, would pass, and mint shares
    ///      short by the fee on every issue once the index holds some of a component that starts charging one. Here the
    ///      index already holds the fee token, from a donation, and only the change still shows the fee.
    function test_RT05_theFeeCheckMeasuresTheChangeWhenTheIndexAlreadyHoldsTheToken() public {
        MockFeeToken fee = new MockFeeToken();
        _list(address(fee), keccak256("FEE/USD"));
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = _spec(address(eth), 5000, ETH_UNITS);
        specs[1] = _spec(address(fee), 5000, 1e18);
        vm.prank(creator);
        WeightedHub feeIndex = WeightedHub(factory.createIndex("Fee", "FEE", specs, _params()));

        fee.mint(stranger, 10e18);
        vm.prank(stranger);
        fee.transfer(address(feeIndex), 10e18); // 1% burns on the way, so 9.9 arrive
        assertEq(fee.balanceOf(address(feeIndex)), 9.9e18, "the index already holds some of the token");

        fee.mint(alice, 1e18);
        eth.mint(alice, ETH_UNITS);
        vm.startPrank(alice);
        fee.approve(address(feeIndex), 1e18);
        eth.approve(address(feeIndex), ETH_UNITS);
        // A share needs 1e18 and 0.99e18 arrives. The balance afterwards, 10.89e18, would clear the check on its own.
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.TransferAmountMismatch.selector, address(fee)));
        feeIndex.issue(1e18, alice);
        vm.stopPrank();
        assertEq(feeIndex.totalSupply(), 0, "no share was minted against 0.99 of its basket");
        assertEq(fee.balanceOf(address(feeIndex)), 9.9e18, "and the index holds only the donation");
    }

    /// @dev An issuer burns part of the index's balance of a leg. Issue would refill the hole with the next minter's
    ///      deposit and earlier holders would redeem it, so it refuses while any leg is below the backing of the shares
    ///      already issued plus open claims (RX-8). Redeem still pays what is there.
    function test_RX8_issueRefusesALegBelowItsBacking() public {
        _issue(index, alice, 2e18);
        vm.prank(alice);
        index.redeemSkipping(1e18, alice, 2);
        uint256 required = BTC_UNITS + BTC_UNITS; // one share's backing plus the claim on the other's
        assertEq(btc.balanceOf(address(index)), required);

        deal(address(btc), address(index), required - 1);
        uint256[] memory amounts = index.previewIssue(1e18);
        vm.startPrank(stranger);
        eth.mint(stranger, amounts[0]);
        btc.mint(stranger, amounts[1]);
        usd.mint(stranger, amounts[2]);
        eth.approve(address(index), amounts[0]);
        btc.approve(address(index), amounts[1]);
        usd.approve(address(index), amounts[2]);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.Underbacked.selector, address(btc), required - 1, required));
        index.issue(1e18, stranger);
        vm.stopPrank();

        // Topped back up, the same issue goes through.
        btc.mint(address(index), 1);
        vm.prank(stranger);
        index.issue(1e18, stranger);
        assertEq(index.balanceOf(stranger), 1e18);
    }

    function test_redeemSendsTheBasketRoundedDown() public {
        _issue(index, alice, 3e18);
        uint256 shares = 1e18 - 1;
        uint256[] memory amounts = index.previewRedeem(shares);
        assertEq(amounts[0], ETH_UNITS - 1, "0.025e18 * (1e18 - 1) / 1e18, rounded down");

        vm.expectEmit(address(index));
        emit IWeightedHub.Redeemed(alice, stranger, shares, amounts);
        vm.prank(alice);
        index.redeem(shares, stranger);
        assertEq(eth.balanceOf(stranger), amounts[0]);
        assertEq(btc.balanceOf(stranger), amounts[1]);
        assertEq(usd.balanceOf(stranger), amounts[2]);
        assertEq(index.balanceOf(alice), 3e18 - shares);
    }

    function test_redeemChecksItsArguments() public {
        _issue(index, alice, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(IWeightedHub.ZeroShares.selector);
        index.redeem(0, alice);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        index.redeem(1, address(0));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        index.redeem(1, address(index));
        vm.stopPrank();
    }

    function test_aDustRedeemSendsNothingOfARoundedComponent() public {
        _issue(index, alice, 1e18);
        uint256[] memory amounts = index.previewRedeem(1);
        assertEq(amounts[1], 0, "0.0005e8 * 1 / 1e18 rounds to nothing");
        vm.prank(alice);
        index.redeem(1, alice);
        assertEq(btc.balanceOf(alice), 0);
    }

    function test_DA17_redeemSkippingBooksTheClaimToTheRecipient() public {
        _issue(index, alice, 2e18);
        vm.expectEmit(address(index));
        emit IWeightedHub.ClaimRecorded(stranger, address(btc), BTC_UNITS);
        vm.prank(alice);
        index.redeemSkipping(1e18, stranger, 2);

        assertEq(btc.balanceOf(stranger), 0);
        assertEq(eth.balanceOf(stranger), ETH_UNITS);
        assertEq(index.claimOf(stranger, address(btc)), BTC_UNITS);
        assertEq(index.totalClaims(address(btc)), BTC_UNITS);

        vm.expectEmit(address(index));
        emit IWeightedHub.Claimed(stranger, alice, address(btc), BTC_UNITS);
        vm.prank(stranger);
        assertEq(index.claim(address(btc), alice), BTC_UNITS);
        assertEq(btc.balanceOf(alice), BTC_UNITS);
        assertEq(index.claimOf(stranger, address(btc)), 0);
        assertEq(index.totalClaims(address(btc)), 0);
    }

    function test_redeemSkippingSkipsADustAmountWithoutAClaim() public {
        _issue(index, alice, 1e18);
        vm.prank(alice);
        index.redeemSkipping(1, alice, 2);
        assertEq(index.totalClaims(address(btc)), 0);
    }

    function test_redeemSkippingChecksTheMask() public {
        _issue(index, alice, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.InvalidSkipMask.selector, 0));
        index.redeemSkipping(1, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.InvalidSkipMask.selector, 8));
        index.redeemSkipping(1, alice, 8);
        vm.stopPrank();
    }

    function test_holdersLeaveWhileAComponentIsFrozen() public {
        MockPausableToken paused = new MockPausableToken("Paused", "PSD", 18);
        _list(address(paused), keccak256("PAUSED/USD"));
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = _spec(address(eth), 5000, ETH_UNITS);
        specs[1] = _spec(address(paused), 5000, 1e18);
        vm.prank(creator);
        WeightedHub two = WeightedHub(factory.createIndex("Two", "TWO", specs, _params()));
        _issue(two, alice, 1e18);

        paused.setPaused(true);
        vm.prank(alice);
        vm.expectRevert();
        two.redeem(1e18, alice);
        vm.prank(alice);
        two.redeemSkipping(1e18, alice, 2);
        assertEq(eth.balanceOf(alice), ETH_UNITS);

        vm.expectRevert();
        vm.prank(alice);
        two.claim(address(paused), alice);
        paused.setPaused(false);
        vm.prank(alice);
        two.claim(address(paused), alice);
        assertEq(paused.balanceOf(alice), 1e18);
    }

    function test_claimChecksItsArguments() public {
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.NothingToClaim.selector, address(btc)));
        index.claim(address(btc), alice);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        index.claim(address(btc), address(0));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(factory)));
        index.claim(address(btc), address(factory));
    }

    function test_CRI01_RT21_sharesCannotBeSentToTheIndexOrItsFactory() public {
        _issue(index, alice, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        index.transfer(address(index), 1);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(factory)));
        index.transfer(address(factory), 1);
        index.approve(stranger, 1);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        vm.prank(stranger);
        index.transferFrom(alice, address(index), 1);
        vm.prank(alice);
        index.transfer(stranger, 1);
        assertEq(index.balanceOf(stranger), 1);
    }

    /// @dev Issue and redeem read no price: Pyth is never called, so no feed can block an exit.
    function test_issueAndRedeemNeverCallPyth() public {
        vm.etch(address(pyth), hex"fe");
        _issue(index, alice, 1e18);
        vm.startPrank(alice);
        index.redeemSkipping(1e17, alice, 1);
        index.redeem(1e17, alice);
        index.claim(address(eth), alice);
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 8e17);
    }

    function test_permitNonces() public view {
        assertEq(index.nonces(alice), 0);
        assertTrue(index.DOMAIN_SEPARATOR() != bytes32(0));
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function test_views() public view {
        assertEq(index.componentCount(), 3);
        address[] memory tokens = index.componentTokens();
        assertEq(tokens[0], address(eth));
        assertEq(tokens[1], address(btc));
        assertEq(tokens[2], address(usd));
        (uint256 eta, uint256 keepMask) = index.pendingRebalance();
        assertEq(eta, 0);
        assertEq(keepMask, 0);
        assertEq(index.currentMu(), 0);
        assertEq(index.proposalCount(), 0);
        assertEq(index.rebalanceNonce(), 0);
        assertEq(index.restartAllowedAt(), 0);
        assertEq(index.SHARE_UNIT(), 1e18);
        assertEq(index.MIN_EXPO(), -18);
        assertEq(index.MAX_PRICE(), 1e45);
    }

    /// @dev V5-L1: one slot back, whatever the block's second: the executor sees its price at most a slot ahead.
    function test_V5L1_priceTimeIsOneSlotBack() public {
        assertEq(index.PRICE_LAG(), 12);
        vm.warp(1_800_000_011);
        assertEq(index.priceTime(), 1_799_999_999);
        vm.warp(1_800_000_023);
        assertEq(index.priceTime(), 1_800_000_011);
    }

    function test_previewRebalanceNeedsOnePricePerComponent() public {
        PythStructs.Price[] memory prices = new PythStructs.Price[](2);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.PriceCountMismatch.selector, 2));
        index.previewRebalance(prices);
    }
}
