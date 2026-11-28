// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPythReader
/// @notice The two reads `PythPrices` makes of Pyth's price contract, declared here rather than copied: the layout of
///         `getPriceUnsafe`'s answer is Pyth's `PythStructs.Price`, a signed price and its confidence, both scaled by
///         `10^expo`, and the time it was published. `getPriceUnsafe` returns whatever price is stored, however old:
///         the caller checks `publishTime`. A price reaches the contract only through an update someone posts and pays
///         for, a filler in its own transaction.
interface IPythReader {
    /// @notice A price as Pyth stores it.
    /// @param price The price, scaled by `10^expo`.
    /// @param conf Pyth's confidence interval around it, at the same scale.
    /// @param expo The power of ten both are scaled by.
    /// @param publishTime When the price was published, in seconds.
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    /// @notice The stored price of feed `id`, however old. Reverts when the feed has never been updated here.
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);

    /// @notice Whether feed `id` exists on this contract.
    function priceFeedExists(bytes32 id) external view returns (bool exists);
}
