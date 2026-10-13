// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IRebalanceExecutor
/// @notice Callback for contracts that fill an index's rebalance auction through `IWeightedHub.executeRebalance`.
interface IRebalanceExecutor {
    /// @notice Called on the `msg.sender` of `executeRebalance`, after the index has sent it `amountsOut`.
    /// @dev Before returning, the executor must send the index the whole of `amountsIn`, and the index must end up
    ///      holding enough of every component to back the new units plus open claims; it checks both and reverts the
    ///      whole rebalance otherwise. Surplus the index already held, from rounding or a donation, does not count
    ///      toward `amountsIn`: it stays with the holders.
    /// @dev The index writes the new units and bumps `rebalanceNonce` before it moves any token, so for the length of
    ///      the payout and this callback an outside reader sees units the index does not yet back. Nothing can act on
    ///      it: every function that mints, burns, pays a claim or touches a rebalance shares the index's guard for the
    ///      whole call. Never price an index off `balanceOf(index)` (VR-05).
    /// @param amountsOut Component amounts already transferred to the executor, in component order.
    /// @param amountsIn Component amounts the index needs back, in component order.
    /// @param data Arbitrary data passed through from `executeRebalance`.
    function onXindexRebalance(uint256[] calldata amountsOut, uint256[] calldata amountsIn, bytes calldata data)
        external;
}
