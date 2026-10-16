// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {PythStructs} from "../src/interfaces/pyth/PythStructs.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice State and helpers the weighted factory and hub suites share.
/// @dev Three tokens shaped like the ones the product lists: ETH-like with 18 decimals at $2,000, BTC-like with 8 at
///      $60,000 and a dollar token with 6 at $1, each priced by Pyth with exponent -8. The default index holds them at
///      50%, 30% and 20% and is worth $100 per whole index token at those prices, so its starting units are exactly
///      on its weights.
abstract contract WeightedTest is Test {
    MockPyth pyth;
    WeightedIndexFactory factory;
    MockERC20 eth;
    MockERC20 btc;
    MockERC20 usd;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    bytes32 constant ETH_ID = keccak256("ETH/USD");
    bytes32 constant BTC_ID = keccak256("BTC/USD");
    bytes32 constant USD_ID = keccak256("USD/USD");
    int32 constant EXPO = -8;
    int64 constant ETH_PRICE = 2000e8;
    int64 constant BTC_PRICE = 60_000e8;
    int64 constant USD_PRICE = 1e8;
    /// @dev $100 of each component's weight: 0.025 ETH, 0.0005 BTC and 20 dollars per whole index token.
    uint256 constant ETH_UNITS = 0.025e18;
    uint256 constant BTC_UNITS = 0.0005e8;
    uint256 constant USD_UNITS = 20e6;

    function _deploy() internal {
        vm.warp(1_800_000_000);
        pyth = new MockPyth();
        factory = new WeightedIndexFactory(owner, guardian, address(pyth));
        eth = new MockERC20("Ether", "ETH", 18);
        btc = new MockERC20("Bitcoin", "BTC", 8);
        usd = new MockERC20("Dollar", "USD", 6);
    }

    /// @dev Lists `token` with `priceId`, through the full listing delay.
    function _list(address token, bytes32 priceId) internal {
        vm.prank(owner);
        factory.proposeListing(token, priceId);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    function _listAll() internal {
        _list(address(eth), ETH_ID);
        _list(address(btc), BTC_ID);
        _list(address(usd), USD_ID);
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

    /// @dev One update per id, published at the index's price time, each the first of its second.
    function _updates(WeightedHub index, bytes32[] memory ids, int64[] memory prices)
        internal
        view
        returns (bytes[] memory data)
    {
        uint64 time = uint64(index.priceTime());
        data = new bytes[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            data[i] = pyth.update(ids[i], prices[i], 0, EXPO, time, time - 1);
        }
    }

    function _ids3() internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](3);
        ids[0] = ETH_ID;
        ids[1] = BTC_ID;
        ids[2] = USD_ID;
    }

    function _prices3(int64 ethPrice, int64 btcPrice, int64 usdPrice) internal pure returns (int64[] memory prices) {
        prices = new int64[](3);
        prices[0] = ethPrice;
        prices[1] = btcPrice;
        prices[2] = usdPrice;
    }

    /// @dev The same prices as Pyth structs, for `previewRebalance`.
    function _structs3(int64 ethPrice, int64 btcPrice, int64 usdPrice)
        internal
        pure
        returns (PythStructs.Price[] memory prices)
    {
        prices = new PythStructs.Price[](3);
        prices[0] = PythStructs.Price({price: ethPrice, conf: 0, expo: EXPO, publishTime: 0});
        prices[1] = PythStructs.Price({price: btcPrice, conf: 0, expo: EXPO, publishTime: 0});
        prices[2] = PythStructs.Price({price: usdPrice, conf: 0, expo: EXPO, publishTime: 0});
    }
}
