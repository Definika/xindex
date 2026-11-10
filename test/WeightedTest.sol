// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice State and helpers the weighted factory and hub suites share.
/// @dev Three tokens shaped like the ones the product lists: ETH-like with 18 decimals at $2,000, BTC-like with 8 at
///      $60,000 and a dollar token with 6 at $1. No contract knows those prices: only a test's executor does, as a
///      market would. The default index holds the three at 50%, 30% and 20% and is worth $100 per whole index token at
///      those prices, so its starting units are exactly on its weights.
abstract contract WeightedTest is Test {
    WeightedIndexFactory factory;
    MockERC20 eth;
    MockERC20 btc;
    MockERC20 usd;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    /// @dev The market's starting prices, in dollars per whole token.
    uint256 constant ETH_PRICE = 2000;
    uint256 constant BTC_PRICE = 60_000;
    uint256 constant USD_PRICE = 1;
    /// @dev $100 of each component's weight: 0.025 ETH, 0.0005 BTC and 20 dollars per whole index token.
    uint256 constant ETH_UNITS = 0.025e18;
    uint256 constant BTC_UNITS = 0.0005e8;
    uint256 constant USD_UNITS = 20e6;

    function _deploy() internal {
        vm.warp(1_800_000_000);
        factory = new WeightedIndexFactory(owner, guardian);
        _approveCreator(creator);
        eth = new MockERC20("Ether", "ETH", 18);
        btc = new MockERC20("Bitcoin", "BTC", 8);
        usd = new MockERC20("Dollar", "USD", 6);
    }

    /// @dev The owner lets `account` create indexes; `_deploy` approves `creator`, whom `_create` creates from.
    function _approveCreator(address account) internal {
        vm.prank(owner);
        factory.setApprovedCreator(account, true);
    }

    /// @dev Lists `token`, through the full listing delay.
    function _list(address token) internal {
        vm.prank(owner);
        factory.proposeListing(token);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    function _listAll() internal {
        _list(address(eth));
        _list(address(btc));
        _list(address(usd));
    }

    function _spec(address token, uint256 weight, uint256 units)
        internal
        pure
        returns (IWeightedIndexFactory.ComponentSpec memory)
    {
        return IWeightedIndexFactory.ComponentSpec({token: token, weight: weight, units: units});
    }

    /// @dev ETH 50%, BTC 30%, USD 20%, on their weights at the default prices.
    function _defaultSpecs() internal view returns (IWeightedIndexFactory.ComponentSpec[] memory specs) {
        specs = new IWeightedIndexFactory.ComponentSpec[](3);
        specs[0] = _spec(address(eth), 5000, ETH_UNITS);
        specs[1] = _spec(address(btc), 3000, BTC_UNITS);
        specs[2] = _spec(address(usd), 2000, USD_UNITS);
    }

    /// @dev No creator fee, any platform fee the policy charges, the shortest interval, open and listed.
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

    function _create(IWeightedIndexFactory.ComponentSpec[] memory specs) internal returns (WeightedHub) {
        return _create(specs, _params());
    }

    function _create(
        IWeightedIndexFactory.ComponentSpec[] memory specs,
        IWeightedIndexFactory.IndexParams memory params
    ) internal returns (WeightedHub) {
        uint256 fee = factory.creationFee();
        vm.deal(creator, creator.balance + fee);
        vm.prank(creator);
        return WeightedHub(factory.createIndex{value: fee}("Weighted", "WGT", specs, params));
    }

    /// @dev Mints the basket for `shares` to `to` and issues them there.
    function _issue(WeightedHub index, address to, uint256 shares) internal {
        address[] memory tokens = index.componentTokens();
        uint256[] memory amounts = index.previewIssue(shares);
        vm.startPrank(to);
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(to, amounts[i]);
            MockERC20(tokens[i]).approve(address(index), amounts[i]);
        }
        index.issue(shares, to);
        vm.stopPrank();
    }

    /// @dev The market's price of each default component, in dollars per whole token: only tests name a price.
    function _market(uint256 ethPrice, uint256 btcPrice, uint256 usdPrice)
        internal
        pure
        returns (uint256[] memory prices)
    {
        prices = new uint256[](3);
        // Per raw unit, at one scale: ETH has 18 decimals, BTC 8 and USD 6.
        prices[0] = ethPrice;
        prices[1] = btcPrice * 1e10;
        prices[2] = usdPrice * 1e12;
    }

    /// @dev The units that put `index` on its weights at `prices` (per raw unit, any one scale) without changing its
    ///      value there: the fill a competitive executor names. Each is rounded up, in the holders' favour.
    function _onWeights(WeightedHub index, uint256[] memory prices) internal view returns (uint256[] memory) {
        return _onWeights(index, prices, 0);
    }

    /// @dev As above, moving only the components `keepMask` leaves: they share their own value by their own weights,
    ///      and a kept component keeps its units.
    function _onWeights(WeightedHub index, uint256[] memory prices, uint256 keepMask)
        internal
        view
        returns (uint256[] memory units)
    {
        units = index.recordedUnits();
        uint256[] memory weights = index.componentWeights();
        uint256 n = units.length;
        uint256 value = 0;
        uint256 weight = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask >> i) & 1 != 0) continue;
            value += units[i] * prices[i];
            weight += weights[i];
        }
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask >> i) & 1 != 0) continue;
            units[i] = Math.mulDiv(value, weights[i], weight * prices[i], Math.Rounding.Ceil);
        }
    }

    /// @dev Warps to the first second of the pending auction at which `newUnits` clear the bar. Reverts the test if
    ///      they never do.
    function _warpToFirstFill(WeightedHub index, uint256[] memory newUnits) internal {
        (uint256 eta,) = index.pendingRebalance();
        uint256 low = 0;
        uint256 high = index.AUCTION_DURATION();
        vm.warp(eta + high);
        // Reverts here, with the index's own error, if the fill never clears the bar.
        index.previewRebalance(newUnits);
        while (low < high) {
            uint256 mid = (low + high) / 2;
            vm.warp(eta + mid);
            try index.previewRebalance(newUnits) {
                high = mid;
            } catch {
                low = mid + 1;
            }
        }
        vm.warp(eta + low);
    }
}
