// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The one Safe function the deploy script reads, to reject owners that a single key controls.
interface ISafeThreshold {
    function getThreshold() external view returns (uint256);
}
