// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IIndexHub} from "../../src/interfaces/IIndexHub.sol";
import {IWeightedHub} from "../../src/interfaces/IWeightedHub.sol";
import {IRebalanceExecutor} from "../../src/interfaces/IRebalanceExecutor.sol";

interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

/// @notice Fills a `WeightedHub` rebalance in tests by minting what the index asks for. `Short` delivers one raw unit
///         too little of a chosen component, `Noop` delivers nothing, and `Reentrant` tries every guarded entry point
///         from inside the callback and records how each call ended, then delivers honestly.
contract MockWeightedExecutor is IRebalanceExecutor {
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
    bytes[] internal _reentryErrors;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setShortComponent(uint256 i) external {
        shortComponent = i;
    }

    function execute(IWeightedHub index, bytes calldata data, bytes[] calldata priceUpdate) external payable {
        index.executeRebalance{value: msg.value}(data, priceUpdate);
    }

    function executeBounded(
        IWeightedHub index,
        bytes calldata data,
        bytes[] calldata priceUpdate,
        uint256[] calldata maxAmountsIn
    ) external payable {
        index.executeRebalance{value: msg.value}(data, priceUpdate, maxAmountsIn);
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

        IWeightedHub index = IWeightedHub(msg.sender);
        if (mode == Mode.Reentrant) _reenter(index);

        address[] memory tokens = index.componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 amount = amountsIn[i];
            if (mode == Mode.Short && i == shortComponent) amount -= 1;
            if (amount != 0) IMintableToken(tokens[i]).mint(msg.sender, amount);
        }
    }

    function _reenter(IWeightedHub index) internal {
        delete _reentryErrors;
        bytes[10] memory attempts = [
            abi.encodeWithSignature("issue(uint256,address)", 1, address(this)),
            abi.encodeWithSignature("issue(uint256,address,address)", 1, address(this), address(0)),
            abi.encodeCall(IWeightedHub.accrueFees, ()),
            abi.encodeCall(IIndexHub.redeem, (1, address(this))),
            abi.encodeCall(IWeightedHub.redeemSkipping, (1, address(this), 1)),
            abi.encodeCall(IWeightedHub.claim, (address(0), address(this))),
            abi.encodeCall(IWeightedHub.startRebalance, (0)),
            abi.encodeCall(IWeightedHub.cancelRebalance, ()),
            abi.encodeWithSignature("executeRebalance(bytes,bytes[])", "", new bytes[](0)),
            abi.encodeWithSignature("executeRebalance(bytes,bytes[],uint256[])", "", new bytes[](0), new uint256[](0))
        ];
        for (uint256 i = 0; i < attempts.length; ++i) {
            (, bytes memory result) = address(index).call(attempts[i]);
            _reentryErrors.push(result);
        }
    }
}
