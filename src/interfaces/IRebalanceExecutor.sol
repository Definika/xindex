// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IRebalanceExecutor
/// @notice Callback for contracts that fill an index's rebalance auction through `IIndexToken.executeRebalance`.
interface IRebalanceExecutor {
    /// @notice Called on the `msg.sender` of `executeRebalance`, after the index has sent it `amountsOut`.
    /// @dev Before returning, the executor must leave the index holding enough of every component to back the new units
    ///      plus open claims; the index checks exactly that and reverts the whole rebalance otherwise. `amountsIn` is
    ///      what that takes when the index holds no surplus. Surplus from rounding or donations counts toward the
    ///      check, so an executor may send up to that surplus less; holders stay fully backed either way.
    /// @param amountsOut Component amounts already transferred to the executor, in component order.
    /// @param amountsIn Component amounts the index needs back, in component order.
    /// @param data Arbitrary data passed through from `executeRebalance`.
    function onXindexRebalance(uint256[] calldata amountsOut, uint256[] calldata amountsIn, bytes calldata data)
        external;
}
