// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The factory's guardian, acting for a controller, the guardian's Safe (RZ-26). Since RX-3 every start of a
///         rebalance carries a Pyth update valid for one slot, which a Safe, collecting its signatures over minutes,
///         cannot land in time. The controller authorizes a start instead, of one index with one keep mask until a
///         deadline, and anyone sends it with an update of their own, once. The guardian's other powers the controller
///         uses through the relay directly. The relay holds no funds and adds no power: it does only what a guardian
///         may, and only on the controller's word.
interface IGuardianRelay {
    /// @notice A start the controller authorized: the index's `keepMask`, sendable by anyone until `deadline`.
    struct StartAuthorization {
        uint256 keepMask;
        uint256 deadline;
    }

    /// @notice The controller authorized a start of `index` with `keepMask` until `deadline`. A deadline already past
    ///         withdraws the index's earlier authorization.
    event StartAuthorized(address indexed index, uint256 keepMask, uint256 deadline);

    /// @notice `sender` sent the start the controller authorized for `index`.
    event AuthorizedStartSent(address indexed index, uint256 keepMask, address indexed sender);

    /// @notice The controller is the zero address.
    error ZeroController();

    /// @notice `caller` is not the controller.
    error NotController(address caller);

    /// @notice No start of `index` is authorized now: none was, the last was sent, or its deadline passed.
    error NoAuthorizedStart(address index);

    /// @notice The guardian's Safe: the only account that authorizes a start or uses the guardian's other powers.
    function CONTROLLER() external view returns (address);

    /// @notice The start authorized for `index`, if its deadline has not passed and it was not sent.
    function authorizationOf(address index) external view returns (uint256 keepMask, uint256 deadline);

    /// @notice Controller only. Authorizes one start of `index` with `keepMask`, sendable by anyone until `deadline`
    ///         inclusive, and replaces the index's earlier authorization. The index checks the mask and its clock when
    ///         the start is sent, as for any start; a deadline already past withdraws the authorization.
    function authorizeStart(address index, uint256 keepMask, uint256 deadline) external;

    /// @notice Anyone. Sends the start the controller authorized for `index`, with the keep mask it named and the
    ///         caller's `priceUpdate`, and spends the authorization. A start the index refuses reverts, and the
    ///         authorization stays.
    /// @dev All of msg.value goes to the index, which gives it to Pyth as its update fee.
    function start(address index, bytes[] calldata priceUpdate) external payable;

    /// @notice Controller only. Cancels the pending rebalance of `index`, as its guardian.
    function cancelRebalance(address index) external;

    /// @notice Controller only. Cancels the pending listing of `token` on `factory`, as its guardian.
    function cancelListing(address factory, address token) external;

    /// @notice Controller only. Delists `token` on `factory`, as its guardian.
    function delist(address factory, address token) external;

    /// @notice Controller only. Cancels the pending change of `factory`'s guardian, which the guardian may only when
    ///         the change would leave the factory with none.
    function cancelGuardianChange(address factory) external;
}
