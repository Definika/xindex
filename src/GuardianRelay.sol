// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGuardianRelay} from "./interfaces/IGuardianRelay.sol";
import {IWeightedHub} from "./interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "./interfaces/IWeightedIndexFactory.sol";

/// @title GuardianRelay
/// @notice The factory's guardian, acting for `CONTROLLER`, the guardian's Safe (RZ-26); see {IGuardianRelay}.
/// @dev It keeps nothing but the authorized starts and holds no ether: `start` hands all of msg.value to the index,
///      which hands it to Pyth. It needs no factory address: a call the controller sends to a factory or index this
///      relay does not guard is refused there, and `start` sends only what the controller authorized.
// The one payable entry point, `start`, forwards all of msg.value to the index, which forwards it to Pyth, in the same
// call (`test_RZ26_theStartsFeeGoesToPyth`), so no ether stays here.
// aderyn-fp-next-line(contract-locks-ether)
contract GuardianRelay is IGuardianRelay {
    /// @inheritdoc IGuardianRelay
    address public immutable CONTROLLER;

    /// @inheritdoc IGuardianRelay
    mapping(address index => StartAuthorization) public authorizationOf;

    modifier onlyController() {
        _checkController();
        _;
    }

    /// @param controller The guardian's Safe.
    constructor(address controller) {
        if (controller == address(0)) revert ZeroController();
        CONTROLLER = controller;
    }

    /// @inheritdoc IGuardianRelay
    function authorizeStart(address index, uint256 keepMask, uint256 deadline) external onlyController {
        authorizationOf[index] = StartAuthorization({keepMask: keepMask, deadline: deadline});
        emit StartAuthorized(index, keepMask, deadline);
    }

    /// @inheritdoc IGuardianRelay
    function start(address index, bytes[] calldata priceUpdate) external payable {
        StartAuthorization memory authorization = authorizationOf[index];
        if (block.timestamp > authorization.deadline) revert NoAuthorizedStart(index);
        // Spent before the call, so it is sent once whatever the index does; a refused start reverts this too.
        delete authorizationOf[index];
        emit AuthorizedStartSent(index, authorization.keepMask, msg.sender);
        // The caller's own msg.value, to an index the controller authorized above, as Pyth's fee.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        IWeightedHub(index).startRebalance{value: msg.value}(authorization.keepMask, priceUpdate);
    }

    /// @inheritdoc IGuardianRelay
    function cancelRebalance(address index) external onlyController {
        IWeightedHub(index).cancelRebalance();
    }

    /// @inheritdoc IGuardianRelay
    function cancelListing(address factory, address token) external onlyController {
        IWeightedIndexFactory(factory).cancelListing(token);
    }

    /// @inheritdoc IGuardianRelay
    function delist(address factory, address token) external onlyController {
        IWeightedIndexFactory(factory).delist(token);
    }

    /// @inheritdoc IGuardianRelay
    function cancelGuardianChange(address factory) external onlyController {
        IWeightedIndexFactory(factory).cancelGuardianChange();
    }

    function _checkController() private view {
        if (msg.sender != CONTROLLER) revert NotController(msg.sender);
    }
}
