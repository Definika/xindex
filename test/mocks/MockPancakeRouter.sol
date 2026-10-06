// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPancakeUniversalRouter} from "../../src/interfaces/IPancakeUniversalRouter.sol";
import {MockRouterInventory} from "./MockUniversalRouter.sol";

interface IWethDeposit {
    function deposit() external payable;
}

/// @notice PancakeSwap v3 Universal Router stand-in that follows the deployed router's verified source
///         (0x65b382653f7C31bC0Af67f188122035461ec9C76: `UniversalRouter.sol`, `base/Dispatcher.sol`,
///         `modules/Payments.sol`, `modules/pancakeswap/V3SwapRouter.sol`) wherever the zap depends on it:
///         - V3 swaps take Uniswap's input layout and, with `payerIsUser` false, pay from the router's own balance;
///         - an exact-output swap delivers exactly what it was asked for or reverts, as the real router checks
///           `amountOutReceived == amountOut`;
///         - SWEEP sends the router's whole balance of a token, reverting below the minimum;
///         - WRAP_ETH wraps the amount asked, or the whole ether balance for `CONTRACT_BALANCE`, keeping the WETH for
///           `ADDRESS_THIS`;
///         - `receive` takes ether from anyone, and after the last command `execute` sends the router's whole ether
///           balance to its caller and reverts with solmate's "ETH_TRANSFER_FAILED" if that send fails (SV-1);
///         - the owner can pause it, and a paused router refuses every call with OpenZeppelin's message.
/// @dev Strict where the real router is permissive, so a test sees what the zap emitted: any other command (0x10 is
///      OWNER_CHECK_721 here, not Uniswap's V4_SWAP), a payer other than the router, or a sweep to anyone but the
///      caller reverts. Prices are fixed per token in dollars, as in `MockUniversalRouter`, and the tokens a swap pays
///      out sit in a separate inventory, so the router's own balance is only what the zap pre-funded.
contract MockPancakeRouter is IPancakeUniversalRouter {
    using SafeERC20 for IERC20;

    /// @notice How a swap should misbehave, for the tests that need it.
    enum Mode {
        Normal,
        /// @notice Consume only half the input of an exact-input swap, as a pool that reaches its price limit does.
        PartialFill
    }

    uint8 internal constant V3_SWAP_EXACT_IN = 0x00;
    uint8 internal constant V3_SWAP_EXACT_OUT = 0x01;
    uint8 internal constant SWEEP = 0x04;
    uint8 internal constant WRAP_ETH = 0x0b;
    address internal constant MSG_SENDER = address(1);
    address internal constant ADDRESS_THIS = address(2);
    uint256 internal constant CONTRACT_BALANCE = 1 << 255;

    error LengthMismatch();
    error InsufficientETH();

    MockRouterInventory public immutable inventory;
    /// @notice The router's WETH9, into which WRAP_ETH wraps.
    address public immutable weth;

    mapping(address token => uint256 price) public priceUsd;
    mapping(address token => uint8 decimals) public decimalsOf;
    Mode public mode;
    bool public paused;
    /// @notice The commands of the last `execute`, so a test can assert the bytes the zap emitted.
    bytes public lastCommands;
    bytes[] private _lastInputs;

    constructor(address weth_) {
        weth = weth_;
        inventory = new MockRouterInventory();
    }

    /// @notice Takes ether from anyone, as the real router's does ("To receive ETH from WETH and NFT protocols").
    receive() external payable {}

    function lastInput(uint256 i) external view returns (bytes memory) {
        return _lastInputs[i];
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setPrice(address token, uint256 price, uint8 tokenDecimals) external {
        priceUsd[token] = price;
        decimalsOf[token] = tokenDecimals;
    }

    function _quoteOut(address tokenIn, address tokenOut, uint256 amountIn) private view returns (uint256) {
        uint256 value = Math.mulDiv(amountIn, priceUsd[tokenIn], 10 ** decimalsOf[tokenIn]);
        return Math.mulDiv(value, 10 ** decimalsOf[tokenOut], priceUsd[tokenOut]);
    }

    function _quoteIn(address tokenIn, address tokenOut, uint256 amountOut) private view returns (uint256) {
        uint256 value = Math.mulDiv(amountOut, priceUsd[tokenOut], 10 ** decimalsOf[tokenOut], Math.Rounding.Ceil);
        return Math.mulDiv(value, 10 ** decimalsOf[tokenIn], priceUsd[tokenIn], Math.Rounding.Ceil);
    }

    /// @inheritdoc IPancakeUniversalRouter
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable {
        require(!paused, "Pausable: paused");
        if (inputs.length != commands.length) revert LengthMismatch();
        lastCommands = commands;
        delete _lastInputs;
        for (uint256 k = 0; k < inputs.length; ++k) {
            _lastInputs.push(inputs[k]);
        }
        for (uint256 i = 0; i < commands.length; ++i) {
            uint8 command = uint8(commands[i]);
            if (command == V3_SWAP_EXACT_IN) {
                _exactIn(inputs[i]);
            } else if (command == V3_SWAP_EXACT_OUT) {
                _exactOut(inputs[i]);
            } else if (command == SWEEP) {
                _sweep(inputs[i]);
            } else if (command == WRAP_ETH) {
                _wrap(inputs[i]);
            } else {
                revert("MockPancake: the zap emitted a command it should not");
            }
        }
        // As the real router: whatever ether it holds goes to the caller, and a caller that cannot take it reverts the
        // whole call.
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool ok,) = msg.sender.call{value: balance}("");
            require(ok, "ETH_TRANSFER_FAILED");
        }
    }

    function _exactIn(bytes calldata input) private {
        (address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path, bool payerIsUser) =
            abi.decode(input, (address, uint256, uint256, bytes, bool));
        require(!payerIsUser, "MockPancake: the zap pays from the router's balance");
        (address tokenIn, address tokenOut) = (_tokenAt(path, 0), _tokenAt(path, path.length - 20));
        uint256 taken = mode == Mode.PartialFill ? amountIn / 2 : amountIn;
        uint256 out = _quoteOut(tokenIn, tokenOut, taken);
        if (out < amountOutMin) _revert(abi.encodeWithSignature("V3TooLittleReceived()"));
        _spend(tokenIn, taken);
        inventory.pay(tokenOut, _map(recipient), out);
    }

    function _exactOut(bytes calldata input) private {
        (address recipient, uint256 amountOut, uint256 amountInMax, bytes memory path, bool payerIsUser) =
            abi.decode(input, (address, uint256, uint256, bytes, bool));
        require(!payerIsUser, "MockPancake: the zap pays from the router's balance");
        // Reversed: from the token bought back to the token spent.
        (address tokenOut, address tokenIn) = (_tokenAt(path, 0), _tokenAt(path, path.length - 20));
        uint256 needed = _quoteIn(tokenIn, tokenOut, amountOut);
        if (needed > amountInMax) _revert(abi.encodeWithSignature("V3TooMuchRequested()"));
        _spend(tokenIn, needed);
        inventory.pay(tokenOut, _map(recipient), amountOut);
    }

    function _sweep(bytes calldata input) private {
        (address token, address recipient, uint256 amountMin) = abi.decode(input, (address, address, uint256));
        require(recipient == msg.sender, "MockPancake: the zap names itself as the recipient");
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < uint160(amountMin)) _revert(abi.encodeWithSignature("InsufficientToken()"));
        if (balance > 0) IERC20(token).safeTransfer(recipient, balance);
    }

    function _wrap(bytes calldata input) private {
        (address recipient, uint256 amount) = abi.decode(input, (address, uint256));
        recipient = _map(recipient);
        if (amount == CONTRACT_BALANCE) {
            amount = address(this).balance;
        } else if (amount > address(this).balance) {
            revert InsufficientETH();
        }
        if (amount > 0) {
            IWethDeposit(weth).deposit{value: amount}();
            if (recipient != address(this)) IERC20(weth).safeTransfer(recipient, amount);
        }
    }

    function _map(address recipient) private view returns (address) {
        if (recipient == MSG_SENDER) return msg.sender;
        if (recipient == ADDRESS_THIS) return address(this);
        return recipient;
    }

    function _spend(address token, uint256 amount) private {
        require(IERC20(token).balanceOf(address(this)) >= amount, "MockPancake: not pre-funded");
        IERC20(token).safeTransfer(address(inventory), amount);
    }

    function _tokenAt(bytes memory path, uint256 offset) private pure returns (address) {
        bytes20 word;
        for (uint256 i = 0; i < 20; ++i) {
            word |= bytes20(path[offset + i]) >> (i * 8);
        }
        return address(word);
    }

    function _revert(bytes memory message) private pure {
        assembly {
            revert(add(message, 0x20), mload(message))
        }
    }
}
