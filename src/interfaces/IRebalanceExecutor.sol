// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IRebalanceExecutor
/// @notice Callback for contracts that fill an index's rebalance auction through `IIndexToken.executeRebalance`.
interface IRebalanceExecutor {
    /// @notice Called on the `msg.sender` of `executeRebalance`, after the index has sent it `amountsOut`.
    /// @dev Before returning, the executor must send the index at least `amountsIn` of each component. The index then
    ///      checks that every component backs the new units and reverts the whole rebalance otherwise.
    /// @param amountsOut Component amounts already transferred to the executor, in component order.
    /// @param amountsIn Component amounts the index needs back, in component order.
    /// @param data Arbitrary data passed through from `executeRebalance`.
    function onXindexRebalance(uint256[] calldata amountsOut, uint256[] calldata amountsIn, bytes calldata data)
        external;
}
