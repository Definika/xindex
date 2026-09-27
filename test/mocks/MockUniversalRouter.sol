// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {UniversalRouterCommands as Cmd} from "../../src/libraries/UniversalRouterCommands.sol";
import {
    PathKey,
    UniswapV4Types as V4,
    V4ExactInputParams,
    V4ExactOutputParams
} from "../../src/libraries/UniswapV4Types.sol";

/// @notice Holds the tokens a mock swap pays out, so the router's own balance is only ever what the zap pre-funded.
/// @dev The real router ends a call holding nothing and is swept by anyone between calls, so a sweep of its whole
///      balance returns exactly the unspent input. A mock that kept its inventory in the router would hand that
///      inventory to the zap on the first sweep, which the real one never does.
contract MockRouterInventory {
    using SafeERC20 for IERC20;

    address public immutable router;

    constructor() {
        router = msg.sender;
    }

    function pay(address token, address to, uint256 amount) external {
        require(msg.sender == router, "MockURInv: only the router pays out");
        IERC20(token).safeTransfer(to, amount);
    }
}

/// @notice Universal Router stand-in that decodes exactly what the real 2.0.0 router decodes.
/// @dev It is deliberately strict rather than permissive: the router refuses anything the zap is not supposed to emit,
///      such as a `payerIsUser` of true, a sweep to anyone but the caller, or the "whole balance" and "message sender"
///      sentinels. It pays from its own balance, as the zap's pre-funding expects, and wraps a failure the way the real
///      router does. What it cannot do is catch a layout slip the zap shares with it: it dispatches on the zap's own
///      command constants and decodes with the zap's own V4 structs, so a swapped command byte or struct field moves
///      both together. The CR-I36 tests in `test/IndexZap.t.sol` pin those against upstream's values, written out
///      independently of src, and the fork suites check them against the real router.
///
///      Prices are fixed per token in dollars, so a swap settles by value across the route's endpoints. The route's
///      middle is not simulated: what the middle is for is checked by the endpoint and hook rules in the zap, and on a
///      mainnet fork against real pools.
contract MockUniversalRouter is IUniversalRouter {
    using SafeERC20 for IERC20;

    /// @notice How a swap should misbehave, for the tests that need it.
    enum Mode {
        Normal,
        /// @notice Consume only half the input of a V3 hop, as a pool that reaches its price limit does.
        PartialFirstHop,
        /// @notice Deliver less than an exact-output swap promised, which the pinned V4 router does not check.
        UnderDeliverExactOut,
        /// @notice Refuse to settle, as the pool manager does when a hop leaves an unsettled delta.
        CurrencyNotSettled
    }

    /// @notice Raised in {Mode.CurrencyNotSettled}, named as the pool manager names it.
    error CurrencyNotSettledError();

    address public immutable poolManager;
    /// @notice Where the tokens a swap pays out are held; tests fund this rather than the router.
    MockRouterInventory public immutable inventory;

    /// @notice Dollars per whole token, 1e18 for a dollar.
    mapping(address token => uint256 price) public priceUsd;
    /// @notice Decimals per token, so a price can be turned into raw units.
    mapping(address token => uint8 decimals) public decimalsOf;
    Mode public mode;
    /// @notice The commands of the last `execute`, so a test can assert the bytes the zap emitted rather than only
    ///         the effect they had.
    bytes public lastCommands;
    bytes[] private _lastInputs;

    constructor(address poolManager_) {
        poolManager = poolManager_;
        inventory = new MockRouterInventory();
    }

    /// @notice The input of the last `execute`'s command at `i`.
    function lastInput(uint256 i) external view returns (bytes memory) {
        return _lastInputs[i];
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    /// @notice Prices `token` at `price` dollars per whole token (1e18 = one dollar).
    function setPrice(address token, uint256 price, uint8 tokenDecimals) external {
        priceUsd[token] = price;
        decimalsOf[token] = tokenDecimals;
    }

    /// @notice Raw units of `tokenOut` worth the same as `amountIn` raw units of `tokenIn`.
    function quoteOut(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        uint256 value = Math.mulDiv(amountIn, priceUsd[tokenIn], 10 ** decimalsOf[tokenIn]);
        return Math.mulDiv(value, 10 ** decimalsOf[tokenOut], priceUsd[tokenOut]);
    }

    /// @notice Raw units of `tokenIn` needed to buy `amountOut` raw units of `tokenOut`, rounded up.
    function quoteIn(address tokenIn, address tokenOut, uint256 amountOut) public view returns (uint256) {
        uint256 value = Math.mulDiv(amountOut, priceUsd[tokenOut], 10 ** decimalsOf[tokenOut], Math.Rounding.Ceil);
        return Math.mulDiv(value, 10 ** decimalsOf[tokenIn], priceUsd[tokenIn], Math.Rounding.Ceil);
    }

    /// @inheritdoc IUniversalRouter
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable {
        require(commands.length == inputs.length, "MockUR: length");
        lastCommands = commands;
        // Copied one at a time: a nested calldata array cannot be assigned to storage wholesale.
        delete _lastInputs;
        for (uint256 k = 0; k < inputs.length; ++k) {
            _lastInputs.push(inputs[k]);
        }
        for (uint256 i = 0; i < commands.length; ++i) {
            uint256 command = uint8(commands[i]);
            if (command == Cmd.V3_SWAP_EXACT_IN) {
                _v3ExactIn(inputs[i], i);
            } else if (command == Cmd.V3_SWAP_EXACT_OUT) {
                _v3ExactOut(inputs[i], i);
            } else if (command == Cmd.V4_SWAP) {
                _v4Swap(inputs[i], i);
            } else if (command == Cmd.SWEEP) {
                _sweep(inputs[i]);
            } else {
                revert("MockUR: the zap emitted a command it should not");
            }
        }
    }

    function _v3ExactIn(bytes calldata input, uint256 index) private {
        (address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path, bool payerIsUser) =
            abi.decode(input, (address, uint256, uint256, bytes, bool));
        _checkPayer(payerIsUser);
        (address tokenIn, address tokenOut) = (_firstToken(path), _lastToken(path));

        uint256 taken = mode == Mode.PartialFirstHop ? amountIn / 2 : amountIn;
        uint256 out = quoteOut(tokenIn, tokenOut, taken);
        if (out < amountOutMin) _fail(index, abi.encodeWithSignature("V3TooLittleReceived()"));
        _spend(tokenIn, taken);
        inventory.pay(tokenOut, recipient, out);
    }

    function _v3ExactOut(bytes calldata input, uint256 index) private {
        (address recipient, uint256 amountOut, uint256 amountInMax, bytes memory path, bool payerIsUser) =
            abi.decode(input, (address, uint256, uint256, bytes, bool));
        _checkPayer(payerIsUser);
        // An exact-output path is reversed: it runs from the token being bought back to the token being spent.
        (address tokenOut, address tokenIn) = (_firstToken(path), _lastToken(path));

        uint256 needed = quoteIn(tokenIn, tokenOut, amountOut);
        if (needed > amountInMax) _fail(index, abi.encodeWithSignature("V3TooMuchRequested()"));
        uint256 delivered = mode == Mode.UnderDeliverExactOut ? amountOut - 1 : amountOut;
        _spend(tokenIn, needed);
        inventory.pay(tokenOut, recipient, delivered);
    }

    function _v4Swap(bytes calldata input, uint256 index) private {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        require(actions.length == params.length, "MockUR: v4 length");
        require(actions.length == 3, "MockUR: the zap emits swap, settle, take");
        require(uint8(actions[1]) == V4.SETTLE, "MockUR: second action is settle");
        require(uint8(actions[2]) == V4.TAKE, "MockUR: third action is take");

        (address settleCurrency, uint256 settleAmount, bool payerIsUser) =
            abi.decode(params[1], (address, uint256, bool));
        _checkPayer(payerIsUser);
        require(settleAmount == V4.OPEN_DELTA, "MockUR: settle the whole debt");
        (address takeCurrency, address takeRecipient, uint256 takeAmount) =
            abi.decode(params[2], (address, address, uint256));
        require(takeAmount == V4.OPEN_DELTA, "MockUR: take the whole credit");
        _checkRecipient(takeRecipient);
        if (mode == Mode.CurrencyNotSettled) _fail(index, abi.encodeWithSelector(CurrencyNotSettledError.selector));

        if (uint8(actions[0]) == V4.SWAP_EXACT_IN) {
            V4ExactInputParams memory swap = abi.decode(params[0], (V4ExactInputParams));
            require(settleCurrency == swap.currencyIn, "MockUR: settle the input");
            _checkHookless(swap.path);
            address tokenOut = swap.path[swap.path.length - 1].intermediateCurrency;
            require(takeCurrency == tokenOut, "MockUR: take the output");
            uint256 taken = mode == Mode.PartialFirstHop ? uint256(swap.amountIn) / 2 : swap.amountIn;
            uint256 out = quoteOut(swap.currencyIn, tokenOut, taken);
            if (out < swap.amountOutMinimum) {
                _fail(
                    index, abi.encodeWithSignature("V4TooLittleReceived(uint256,uint256)", swap.amountOutMinimum, out)
                );
            }
            _spend(swap.currencyIn, taken);
            inventory.pay(tokenOut, takeRecipient, out);
        } else {
            require(uint8(actions[0]) == V4.SWAP_EXACT_OUT, "MockUR: first action is a swap");
            V4ExactOutputParams memory swap = abi.decode(params[0], (V4ExactOutputParams));
            _checkHookless(swap.path);
            // An exact-output route is walked backwards, so its first entry names the token being spent.
            address tokenIn = swap.path[0].intermediateCurrency;
            require(settleCurrency == tokenIn, "MockUR: settle the input");
            require(takeCurrency == swap.currencyOut, "MockUR: take the output");
            uint256 needed = quoteIn(tokenIn, swap.currencyOut, swap.amountOut);
            if (needed > swap.amountInMaximum) {
                _fail(
                    index, abi.encodeWithSignature("V4TooMuchRequested(uint256,uint256)", swap.amountInMaximum, needed)
                );
            }
            uint256 delivered = mode == Mode.UnderDeliverExactOut ? uint256(swap.amountOut) - 1 : swap.amountOut;
            _spend(tokenIn, needed);
            inventory.pay(swap.currencyOut, takeRecipient, delivered);
        }
    }

    function _sweep(bytes calldata input) private {
        (address token, address recipient, uint256 amountMin) = abi.decode(input, (address, address, uint256));
        _checkRecipient(recipient);
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= amountMin, "MockUR: sweep below minimum");
        if (balance != 0) IERC20(token).safeTransfer(recipient, balance);
    }

    /// @dev The zap pre-funds the router, so what a swap spends is already here. It goes to the inventory, standing
    ///      in for the pool that received it; whatever the swap did not spend stays for the sweep.
    function _spend(address token, uint256 amount) private {
        require(IERC20(token).balanceOf(address(this)) >= amount, "MockUR: not pre-funded");
        IERC20(token).safeTransfer(address(inventory), amount);
    }

    function _checkPayer(bool payerIsUser) private pure {
        require(!payerIsUser, "MockUR: the zap pays from the router's balance, never the caller's");
    }

    /// @dev The zap always names itself, which also settles the sentinels: `MSG_SENDER` and `ADDRESS_THIS` are
    ///      address(1) and address(2), neither of which can be the calling contract.
    function _checkRecipient(address recipient) private view {
        require(recipient == msg.sender, "MockUR: the zap names itself as the recipient");
    }

    function _checkHookless(PathKey[] memory path) private pure {
        for (uint256 i = 0; i < path.length; ++i) {
            require(path[i].hooks == address(0) && path[i].hookData.length == 0, "MockUR: the zap rejects hooks");
        }
    }

    /// @dev The first and last address of a packed V3 path. `PathLib` reads calldata; a decoded input is memory.
    function _firstToken(bytes memory path) private pure returns (address) {
        return _tokenAt(path, 0);
    }

    function _lastToken(bytes memory path) private pure returns (address) {
        return _tokenAt(path, path.length - 20);
    }

    function _tokenAt(bytes memory path, uint256 offset) private pure returns (address) {
        bytes20 word;
        for (uint256 i = 0; i < 20; ++i) {
            word |= bytes20(path[offset + i]) >> (i * 8);
        }
        return address(word);
    }

    /// @dev A swap's revert bubbles unchanged. The real router dispatches swaps as internal calls and only wraps the
    ///      commands it makes with a low-level call, so `ExecutionFailed` is not what a caller sees when a pool's own
    ///      slippage check fires. Verified against the pinned router on a mainnet fork.
    function _fail(uint256, bytes memory message) private pure {
        assembly {
            revert(add(message, 0x20), mload(message))
        }
    }
}
