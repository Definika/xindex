// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {IRebalanceExecutor} from "../../src/interfaces/IRebalanceExecutor.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Fills rebalance auctions in tests by minting what the index asks for. `Short` delivers one raw unit too
///         little of a chosen component, `Noop` delivers nothing, and `Reentrant` tries every guarded entry point from
///         inside the callback and records how each call ended, then delivers honestly.
contract MockRebalanceExecutor is IRebalanceExecutor {
    enum Mode {
        Honest,
        Short,
        Noop,
        Reentrant
    }

    Mode public mode;
    uint256 public shortComponent;
    uint256 public calls;
    bytes public lastData;
    uint256[] internal _lastAmountsOut;
    uint256[] internal _lastAmountsIn;

    /// @notice Revert data of each reentrant attempt, in the order issue, redeem, redeemSkipping, claim,
    ///         startRebalance, cancelRebalance, executeRebalance.
    bytes[] internal _reentryErrors;
    bool public indexTransferSucceeded;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setShortComponent(uint256 i) external {
        shortComponent = i;
    }

    function execute(IIndexToken index, bytes calldata data) external {
        index.executeRebalance(data);
    }

    function lastAmountsOut() external view returns (uint256[] memory) {
        return _lastAmountsOut;
    }

    function lastAmountsIn() external view returns (uint256[] memory) {
        return _lastAmountsIn;
    }

    function reentryErrors() external view returns (bytes[] memory) {
        return _reentryErrors;
    }

    function onXindexRebalance(uint256[] calldata amountsOut, uint256[] calldata amountsIn, bytes calldata data)
        external
    {
        ++calls;
        lastData = data;
        _lastAmountsOut = amountsOut;
        _lastAmountsIn = amountsIn;
        if (mode == Mode.Noop) return;

        IIndexToken index = IIndexToken(msg.sender);
        if (mode == Mode.Reentrant) _reenter(index);

        address[] memory tokens = index.componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 amount = amountsIn[i];
            if (mode == Mode.Short && i == shortComponent) amount -= 1;
            if (amount != 0) IMintable(tokens[i]).mint(msg.sender, amount);
        }
    }

    function _reenter(IIndexToken index) internal {
        delete _reentryErrors;
        bytes[7] memory attempts = [
            abi.encodeCall(IIndexToken.issue, (1, address(this))),
            abi.encodeCall(IIndexToken.redeem, (1, address(this))),
            abi.encodeCall(IIndexToken.redeemSkipping, (1, address(this), 1)),
            abi.encodeCall(IIndexToken.claim, (address(0), address(this))),
            abi.encodeCall(IIndexToken.startRebalance, (0)),
            abi.encodeCall(IIndexToken.cancelRebalance, ()),
            abi.encodeCall(IIndexToken.executeRebalance, (""))
        ];
        for (uint256 i = 0; i < attempts.length; ++i) {
            (, bytes memory result) = address(index).call(attempts[i]);
            _reentryErrors.push(result);
        }
        uint256 held = IERC20(address(index)).balanceOf(address(this));
        indexTransferSucceeded = held != 0 && IERC20(address(index)).transfer(address(0xdead), held);
    }
}
