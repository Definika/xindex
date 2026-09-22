// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IXindexErrors} from "./interfaces/IXindexErrors.sol";

/// @title CompositeFeed
/// @notice Multiplies two Chainlink feeds into one, so a token whose USD price exists only as a product can be listed
///         with a single feed like every other.
/// @dev WBTC is the case this exists for: there is no WBTC/USD feed, so its price is BTC/USD times WBTC/BTC. The
///      product is also what catches a WBTC depeg, since the second leg is what a wrapped coin is worth against the
///      coin it wraps.
///
///      Immutable and ownerless: the legs, their staleness bounds and the arithmetic are fixed at construction, so
///      listing one of these is exactly as revocable as listing a feed directly, and no key can repoint it.
///
///      Each leg carries its own bound because the rule sees only one `maxStaleness` for the token, and that bound
///      has to admit the slower leg. WBTC/BTC updates on a 24-hour heartbeat and BTC/USD on a one-hour heartbeat, so
///      a single 24-hour bound over the reported timestamp would accept a BTC/USD answer that had been dead for
///      twenty hours. Bounding each leg where it is read is the only place that distinction survives.
///
///      The reported timestamp is the older of the two, so the rule's own bound still applies to the staler leg and
///      the two checks compose rather than shadow each other.
contract CompositeFeed is IAggregatorV3, IXindexErrors {
    /// @notice Longest either leg's bound may be, matching the rule's own ceiling on a token's staleness.
    uint32 public constant MAX_LEG_STALENESS = 2 days;

    /// @notice Feed whose decimals the product reports, for example BTC/USD.
    IAggregatorV3 public immutable FEED_A;
    /// @notice Feed the product divides out, for example WBTC/BTC.
    IAggregatorV3 public immutable FEED_B;
    /// @notice Oldest {FEED_A} answer this will serve.
    uint32 public immutable MAX_AGE_A;
    /// @notice Oldest {FEED_B} answer this will serve.
    uint32 public immutable MAX_AGE_B;

    /// @notice A leg reported an answer of zero or less, so no price can be formed from it.
    error NonPositiveAnswer(address feed, int256 answer);
    /// @notice A leg's newest answer is older than the bound this adapter was built with.
    error StaleLeg(address feed, uint256 updatedAt);
    /// @notice A leg's staleness bound is zero or above MAX_LEG_STALENESS.
    error InvalidLegStaleness(uint32 maxAge);

    constructor(IAggregatorV3 feedA, IAggregatorV3 feedB, uint32 maxAgeA, uint32 maxAgeB) {
        if (address(feedA) == address(0) || address(feedB) == address(0)) revert ZeroAddress();
        if (maxAgeA == 0 || maxAgeA > MAX_LEG_STALENESS) revert InvalidLegStaleness(maxAgeA);
        if (maxAgeB == 0 || maxAgeB > MAX_LEG_STALENESS) revert InvalidLegStaleness(maxAgeB);
        FEED_A = feedA;
        FEED_B = feedB;
        MAX_AGE_A = maxAgeA;
        MAX_AGE_B = maxAgeB;
    }

    /// @inheritdoc IAggregatorV3
    /// @dev The product keeps {FEED_A}'s decimals: dividing by 10 ** decimals(FEED_B) cancels the second leg's scale.
    function decimals() external view returns (uint8) {
        return FEED_A.decimals();
    }

    /// @inheritdoc IAggregatorV3
    function description() external view returns (string memory) {
        return string.concat(FEED_A.description(), " * ", FEED_B.description());
    }

    /// @inheritdoc IAggregatorV3
    /// @dev `roundId` and `answeredInRound` are zero: two legs have no common round, and nothing reads them.
    ///      `Math.mulDiv` carries the full 512-bit intermediate, so two legitimate answers never overflow on the way
    ///      to a product that fits.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 a, uint256 updatedA) = _leg(FEED_A, MAX_AGE_A);
        (uint256 b, uint256 updatedB) = _leg(FEED_B, MAX_AGE_B);
        uint256 answer = Math.mulDiv(a, b, 10 ** FEED_B.decimals());
        uint256 updatedAt = Math.min(updatedA, updatedB);
        return (0, SafeCast.toInt256(answer), updatedAt, updatedAt, 0);
    }

    /// @dev One leg's answer and timestamp, checked positive and fresh against its own bound. Read once per leg: a
    ///      second `latestRoundData` would double the calls for nothing.
    function _leg(IAggregatorV3 feed, uint32 maxAge) private view returns (uint256, uint256) {
        // Only the answer and its timestamp are read, as in the rule.
        // forge-lint: disable-next-line(unused-return)
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert NonPositiveAnswer(address(feed), answer);
        // A timestamp in the future is not a fresh answer, it is a broken one; fail closed rather than underflow.
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert StaleLeg(address(feed), updatedAt);
        }
        // Safe because `answer` was checked positive above, so the sign bit is clear.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(answer), updatedAt);
    }
}
