// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {WeightedMath} from "../../src/WeightedMath.sol";
import {IPythPrices} from "../../src/interfaces/IPythPrices.sol";
import {IPythReader} from "../../src/interfaces/IPythReader.sol";
import {ISyntheticSharesOracle} from "../../src/interfaces/ISyntheticSharesOracle.sol";
import {PriceFeeds} from "../../script/PriceFeeds.sol";

/// @notice The Ondo half of a chain's fork suite: on a factory built on the chain's
///         Pyth and Ondo's `SyntheticSharesOracle` there, every token the feed table prices as `SharesOracle` is
///         valued at its share's price times the sValue Ondo's oracle holds for it at the fork, where that sValue is
///         settled, and refused by name where it is not. The share's price is a stand-in posted at the fork's time, a
///         hundred dollars: Pyth stores a price only when someone pays to post it, and what is under test is the sValue.
library OndoSValues {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The runtime code hash of Ondo's verified `SyntheticSharesOracle`, the same on Ethereum and BNB Chain
    ///: neither is a proxy, so the hash pins the source the reader was written against.
    bytes32 internal constant CODEHASH = 0x4c5b459e3538cd5f2bfdb7b02e82274eed5de2c913a709c40405e7213f52a462;

    /// @dev The stand-in share price: $100, at Pyth's usual exponent.
    int64 private constant SHARE_PRICE = 100e8;

    /// @notice Values each of chain `chainId`'s `SharesOracle` legs through a reader on `pyth` and `oracle`, and returns
    ///         how many it valued and how many it refused. Fails the test if a value is not the share's price times
    ///         the settled sValue, or if a leg whose sValue is not settled is not refused with `SValueUnavailable`.
    ///         `test/PythPrices.t.sol` runs it against mocks, so the fork suites' check is itself checked.
    function check(uint256 chainId, address pyth, address oracle) internal returns (uint256 valued, uint256 refused) {
        WeightedIndexFactory factory =
            new WeightedIndexFactory(address(this), address(0), pyth, address(new WeightedMath()), oracle);
        IPythPrices prices = IPythPrices(factory.PRICES());
        (address[] memory tokens, IPythPrices.PriceFeed[] memory feeds) = PriceFeeds.table(chainId);
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (feeds[i].kind != IPythPrices.FeedKind.SharesOracle) continue;
            if (_valueOrRefusal(prices, tokens[i], feeds[i], pyth, oracle)) ++valued;
            else ++refused;
        }
    }

    /// @dev Whether `token` was valued, at the stand-in price times its settled sValue; false if it was refused, as
    ///      its oracle entry says it must be.
    function _valueOrRefusal(
        IPythPrices prices,
        address token,
        IPythPrices.PriceFeed memory feed,
        address pyth,
        address oracle
    ) private returns (bool) {
        VM.mockCall(
            pyth,
            abi.encodeCall(IPythReader.getPriceUnsafe, (feed.id)),
            abi.encode(IPythReader.Price({price: SHARE_PRICE, conf: 0, expo: -8, publishTime: block.timestamp}))
        );
        (uint128 sValue,, uint256 lastUpdate, uint256 pauseStart,,) = ISyntheticSharesOracle(oracle).assetData(token);
        bool settled = sValue != 0 && pauseStart == 0 && lastUpdate + prices.MIN_SVALUE_AGE() <= block.timestamp;
        address[] memory one = new address[](1);
        one[0] = token;
        IPythPrices.PriceFeed[] memory oneFeed = new IPythPrices.PriceFeed[](1);
        oneFeed[0] = feed;
        uint8[] memory decimals = new uint8[](1);
        decimals[0] = 18; // every Ondo token's
        if (!settled) {
            VM.expectRevert(abi.encodeWithSelector(IPythPrices.SValueUnavailable.selector, token));
            prices.valuesWith(one, oneFeed, decimals, true);
            return false;
        }
        // $100 a share and 18 decimals: a raw unit is worth 100 * sValue / 1e18 dollars of a whole token's 1e18 raw
        // units, times the value scale of 1e36, which is 100 * sValue exactly, both ways.
        VM.assertEq(prices.valuesWith(one, oneFeed, decimals, true)[0], 100 * uint256(sValue), "share times sValue");
        return true;
    }
}
