// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The views of VeChain's builtin Staker at `0x00000000000000000000000000005374616b6572` (`"Staker"` in ASCII),
///         as vechain/thor's `builtin/gen/staker.sol` declares them since Hayabusa (VIP-253). Amounts are in wei, each a
///         whole number of VET. Its native code keeps the validators VIP-220's finality weighs, which change only at
///         an epoch's first block, before its transactions run.
interface IVeChainStaker {
    /// @return totalVet The VET locked by the active validators and their delegators.
    /// @return totalWeight Their weight: the total VIP-220 takes two thirds of.
    function totalStake() external view returns (uint256 totalVet, uint256 totalWeight);

    /// @notice The head of the active validators' list; zero when it is empty.
    function firstActive() external view returns (address first);

    /// @notice The validator after `prev` in its list; zero after the last.
    function next(address prev) external view returns (address nextValidation);

    /// @return endorser The account that staked for the validator.
    /// @return stake Its own locked VET.
    /// @return weight Its weight, delegations included: what VIP-220 counts for a block it signs.
    /// @return queuedVet VET it queued for its next period.
    /// @return status Its status; 2 is active.
    /// @return offlineBlock The block it was marked offline at, or `type(uint32).max`.
    function getValidation(address validator)
        external
        view
        returns (address endorser, uint256 stake, uint256 weight, uint256 queuedVet, uint8 status, uint32 offlineBlock);
}
