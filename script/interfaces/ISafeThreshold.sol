// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice The Safe functions the deploy script reads, to reject owners that a single key controls.
interface ISafeThreshold {
    /// @notice Owner signatures a Safe transaction needs.
    function getThreshold() external view returns (uint256);

    /// @notice The Safe's signers.
    function getOwners() external view returns (address[] memory);

    /// @notice Up to `pageSize` enabled modules after `start` (the sentinel 0x1 for the first page), and the next
    ///         cursor. A module executes as the Safe without any owner signature.
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
}
