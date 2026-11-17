// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice The second address of a {MockTwoAddressToken}. It keeps no balance of its own: it reads the token's, and
///         moves them for whoever calls it, out of that caller's balance or allowance on the token.
contract MockSecondAddress {
    address public immutable token;

    constructor() {
        token = msg.sender;
    }

    function balanceOf(address account) external view returns (uint256) {
        return IERC20(token).balanceOf(account);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _forward(abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        return _forward(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
    }

    /// @dev Makes the call on the token with this call's sender appended, whom the token then takes for its caller.
    function _forward(bytes memory data) private returns (bool) {
        return abi.decode(Address.functionCall(token, abi.encodePacked(data, msg.sender)), (bool));
    }
}

/// @notice A token with one balance behind two addresses, as a token has whose old address still forwards to its new
///         one. This address is a plain ERC-20 and {MockSecondAddress} is the other way in, over the same balances
///         and allowances. Moving the token through either address lowers the sender's balance at both, which is what
///         a swap measured against the two would count twice (RW-10).
contract MockTwoAddressToken is MockERC20 {
    MockSecondAddress public immutable second;

    constructor() MockERC20("Two Address", "TWO", 18) {
        second = new MockSecondAddress();
    }

    /// @dev A call that comes through the second address names its own caller in its last twenty bytes.
    function _msgSender() internal view override returns (address) {
        return msg.sender == address(second) ? address(bytes20(msg.data[msg.data.length - 20:])) : msg.sender;
    }
}
