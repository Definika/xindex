// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPythPrices} from "./interfaces/IPythPrices.sol";
import {IPythReader} from "./interfaces/IPythReader.sol";
import {IWeightedIndexFactory} from "./interfaces/IWeightedIndexFactory.sol";
import {IXindexErrors} from "./interfaces/IXindexErrors.sol";
import {IMultiplierToken} from "./interfaces/IMultiplierToken.sol";

/// @title PythPrices
/// @notice Values a rebalance's legs at Pyth's prices, for the check that can only refuse a fill. See {IPythPrices}.
/// @dev The factory deploys it in its constructor, so `FACTORY` is the factory whose listings name each token's feed.
///      It holds nothing and writes nothing.
///      - A value is one raw unit's worth in dollars times 1e36: Pyth's price, moved by its confidence against the
///        executor, times ten to its exponent plus 36, times whole feed assets per raw unit of the token.
///      - A token's decimals are the ones its listing recorded (`decimalsOf`), never read from the token. A vault's
///        rate and its asset's decimals, and a stock token's multiplier, are read from the token at the fill: they
///        are what makes one unit worth more than one asset, and they move.
///      - A value that comes to nothing is refused like a price that is not positive (`UnusablePrice`): a multiplier
///        or a vault rate of zero, or a price too small for the scale, values no leg at zero, where one that leaves
///        would have counted as free.
///      - An empty vault's rate is anyone's to raise by leaving it a few raw units of its asset. That overvalues the
///        vault where it arrives, and so loosens the check on that leg toward the bar's alone; it never loosens the
///        bar, and where the vault leaves it only tightens the check.
contract PythPrices is IPythPrices {
    /// @inheritdoc IPythPrices
    uint256 public constant MAX_PRICE_AGE = 15;
    /// @inheritdoc IPythPrices
    uint256 public constant MAX_CREATION_PRICE_AGE = 60;
    /// @inheritdoc IPythPrices
    uint256 public constant VALUE_SCALE = 1e36;
    /// @dev The decimal digits of VALUE_SCALE.
    int256 private constant SCALE_DIGITS = 36;
    /// @dev The most digits a value's price may carry: an exponent of up to 18 on top of the scale's 36.
    int256 private constant MAX_DIGITS = 54;
    /// @dev The largest value: the math's checks multiply values by units of up to 96 bits and sum two hundred of them.
    uint256 private constant MAX_VALUE = type(uint128).max;
    /// @dev A multiplier's one.
    uint256 private constant WAD = 1e18;
    uint256 private constant DECIMAL_BASE = 10;

    /// @inheritdoc IPythPrices
    address public immutable PYTH;
    /// @inheritdoc IPythPrices
    address public immutable FACTORY;

    constructor(address pyth) {
        if (pyth == address(0)) revert IXindexErrors.ZeroAddress();
        PYTH = pyth;
        FACTORY = msg.sender;
    }

    /// @inheritdoc IPythPrices
    function legValues(address[] memory tokens, uint256[] memory currentUnits, uint256[] memory newUnits)
        external
        view
        returns (uint256[] memory values)
    {
        uint256 n = tokens.length;
        values = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 current = currentUnits[i];
            uint256 next = newUnits[i];
            if (next != current) values[i] = _value(tokens[i], next < current);
        }
    }

    /// @inheritdoc IPythPrices
    function valueOf(address token, bool leaving) external view returns (uint256) {
        return _value(token, leaving);
    }

    /// @inheritdoc IPythPrices
    function valuesWith(address[] calldata tokens, PriceFeed[] calldata feeds, uint8[] calldata decimals, bool leaving)
        external
        view
        returns (uint256[] memory values)
    {
        uint256 n = tokens.length;
        values = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            values[i] = _valueAt(tokens[i], feeds[i], decimals[i], leaving, MAX_CREATION_PRICE_AGE);
        }
    }

    /// @dev One raw unit of `token` at its feed's price, leaning against the executor: up for a leg that leaves, down
    ///      for one that arrives. The feed and the decimals are the factory's, and the price no older than a fill's
    ///      `MAX_PRICE_AGE`.
    function _value(address token, bool leaving) private view returns (uint256) {
        IWeightedIndexFactory factory = IWeightedIndexFactory(FACTORY);
        return _valueAt(token, factory.priceFeedOf(token), factory.decimalsOf(token), leaving, MAX_PRICE_AGE);
    }

    /// @dev {_value} at `feed` and `decimals`, of a price at most `maxAge` seconds old. The filler posts the update
    ///      itself, so it picks the price among those of the last `maxAge` seconds (HK-25): a fill's age is short.
    function _valueAt(address token, PriceFeed memory feed, uint8 decimals, bool leaving, uint256 maxAge)
        private
        view
        returns (uint256 value)
    {
        if (feed.kind == FeedKind.None) revert NoPriceFeed(token);
        IPythReader.Price memory p = IPythReader(PYTH).getPriceUnsafe(feed.id);
        if (p.publishTime + maxAge < block.timestamp) revert StalePrice(token, p.publishTime);
        int256 digits = SCALE_DIGITS + p.expo;
        if (p.price <= 0 || digits < 0 || digits > MAX_DIGITS) revert UnusablePrice(token);
        uint256 price = SafeCast.toUint256(p.price);
        if (price <= p.conf) revert UnusablePrice(token);
        uint256 edge = leaving ? price + p.conf : price - p.conf;
        (uint256 assets, uint256 perRaw) = _assetsPerRawUnit(token, feed.kind, decimals);
        value = Math.mulDiv(
            edge * DECIMAL_BASE ** SafeCast.toUint256(digits),
            assets,
            perRaw,
            leaving ? Math.Rounding.Ceil : Math.Rounding.Floor
        );
        // A value of nothing is no price. Where a leg leaves, it would make that leg free to take by this check's
        // measure: a stock token whose multiplier, or a vault whose rate, reads zero. Refused, as every other price
        // the check cannot use, so the fill that moves the leg waits.
        if (value == 0 || value > MAX_VALUE) revert UnusablePrice(token);
    }

    /// @dev How many whole units of what the feed prices one raw unit of `token` is: `assets / perRaw`.
    function _assetsPerRawUnit(address token, FeedKind kind, uint8 decimals)
        private
        view
        returns (uint256 assets, uint256 perRaw)
    {
        uint256 one = DECIMAL_BASE ** decimals;
        if (kind == FeedKind.Token) return (1, one);
        if (kind == FeedKind.Vault) {
            // One whole vault token redeems for `convertToAssets(one)` raw assets; the feed prices a whole asset.
            uint256 assetOne = DECIMAL_BASE ** IERC20Metadata(IERC4626(token).asset()).decimals();
            return (IERC4626(token).convertToAssets(one), assetOne * one);
        }
        // Multiplier: one raw unit stands for `multiplier / WAD` raw shares; the feed prices a whole share.
        return (IMultiplierToken(token).multiplier(), WAD * one);
    }
}
