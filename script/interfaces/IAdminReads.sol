// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The reads `CheckToken` makes to find who holds a token's admin powers and what kind of account it is. Every
///         one is a static call whose answer is checked before it is read, so a contract without the function is no
///         answer, never a revert.
interface IAdminReads {
    /// @notice Ownable's owner.
    function owner() external view returns (address);

    /// @notice BEP-20's owner, which Binance-Peg tokens name instead of, or beside, `owner`.
    function getOwner() external view returns (address);

    /// @notice A MiniMe token's controller, which mints, destroys and approves every transfer.
    function controller() external view returns (address);

    /// @notice An OwnedUpgradeabilityProxy's owner, who upgrades it.
    function proxyOwner() external view returns (address);

    /// @notice AccessControlEnumerable's `index`th holder of `role`.
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);

    /// @notice An UpgradeableBeacon's implementation.
    function implementation() external view returns (address);

    /// @notice OpenZeppelin's TimelockController's minimum delay, in seconds.
    function getMinDelay() external view returns (uint256);

    /// @notice Compound's Timelock's and Maker's DSPause's delay, in seconds.
    function delay() external view returns (uint256);
}
