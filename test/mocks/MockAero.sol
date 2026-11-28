// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAeroMetarouter} from "../../src/interfaces/IAeroMetarouter.sol";
import {AeroCommands as Aero} from "../../src/libraries/AeroCommands.sol";
import {MockRouterInventory} from "./MockUniversalRouter.sol";

/// @notice One of Aero's pools, as the Metarouter reads it: two tokens and a family.
contract MockAeroPool {
    address public immutable token0;
    address public immutable token1;
    /// @notice True for a concentrated-liquidity pool, false for a basic one.
    bool public immutable cl;

    constructor(address a, address b, bool cl_) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        cl = cl_;
    }
}

/// @notice Aero's CL factory: a pool per pair and tick spacing, found in either order.
contract MockAeroCLFactory {
    mapping(address a => mapping(address b => mapping(uint24 tickSpacing => address pool))) public getPool;
    mapping(address pool => bool made) public isPool;

    function create(address a, address b, uint24 tickSpacing) external returns (address pool) {
        pool = address(new MockAeroPool(a, b, true));
        (getPool[a][b][tickSpacing], getPool[b][a][tickSpacing], isPool[pool]) = (pool, pool, true);
    }
}

/// @notice One of Aero's basic-pool factories: a pool per pair, found in either order.
contract MockAeroPoolFactory {
    mapping(address a => mapping(address b => address pool)) public getPool;
    mapping(address pool => bool made) public isPool;

    function create(address a, address b) external returns (address pool) {
        pool = address(new MockAeroPool(a, b, false));
        (getPool[a][b], getPool[b][a], isPool[pool]) = (pool, pool, true);
    }
}

/// @notice Aero's Metarouter stand-in, decoding what the real one decodes and settling by price.
/// @dev Strict where the real router is, and where the engine must be: a pool must be one of the three factories',
///      of the command's family, and each hop's input one of its tokens; the payer is never the user; an exact-output
///      swap delivers exactly what it was asked; a sweep never goes to the router; and after the last command the
///      whole balance of every token a swap spent goes back to the caller, as the real batch's closure does. It pays
///      from an inventory, so its own balance is only ever what the engine pre-funded and what a test left as a stray.
contract MockMetarouter is IAeroMetarouter {
    using SafeERC20 for IERC20;

    /// @notice Raised as the Metarouter raises it for a pool none of Aero's factories made, or of the wrong family.
    error InvalidPool(address pool);
    /// @notice Raised for a pool that holds neither hop token.
    error InvalidPath();
    /// @notice Raised when a swap needs more than its limit, or delivers less than its minimum.
    error TooMuchRequested();
    error TooLittleReceived(uint256 minAmountOut, uint256 amountOut);
    /// @notice Raised past the deadline.
    error Expired();

    MockAeroCLFactory public immutable CL;
    MockAeroPoolFactory public immutable VOLATILE;
    MockAeroPoolFactory public immutable STABLE;
    MockRouterInventory public immutable inventory;

    mapping(address token => uint256 price) public priceUsd;
    mapping(address token => uint8 decimals) public decimalsOf;
    /// @notice Consume only half the input of an exact-input CL swap, as a pool that runs out of liquidity does.
    bool public partialFill;
    bytes public lastCommands;
    uint256 public lastDeadline;
    bytes[] private _lastInputs;
    address[] private _touched;

    constructor() {
        CL = new MockAeroCLFactory();
        VOLATILE = new MockAeroPoolFactory();
        STABLE = new MockAeroPoolFactory();
        inventory = new MockRouterInventory();
    }

    function lastInput(uint256 i) external view returns (bytes memory) {
        return _lastInputs[i];
    }

    function setPrice(address token, uint256 price, uint8 tokenDecimals) external {
        priceUsd[token] = price;
        decimalsOf[token] = tokenDecimals;
    }

    function setPartialFill(bool on) external {
        partialFill = on;
    }

    /// @inheritdoc IAeroMetarouter
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        require(commands.length == inputs.length, "MockAero: length");
        if (block.timestamp > deadline) revert Expired();
        (lastCommands, lastDeadline) = (commands, deadline);
        delete _lastInputs;
        for (uint256 k = 0; k < inputs.length; ++k) {
            _lastInputs.push(inputs[k]);
        }
        for (uint256 i = 0; i < commands.length; ++i) {
            uint256 command = uint8(commands[i]);
            if (command == Aero.CL_SWAP_EXACT_IN || command == Aero.V2_SWAP_EXACT_IN) {
                _exactIn(abi.decode(inputs[i], (SwapExactInParams)), command == Aero.CL_SWAP_EXACT_IN);
            } else if (command == Aero.CL_SWAP_EXACT_OUT || command == Aero.V2_SWAP_EXACT_OUT) {
                _exactOut(abi.decode(inputs[i], (SwapExactOutParams)), command == Aero.CL_SWAP_EXACT_OUT);
            } else {
                require(command == Aero.SWEEP, "MockAero: the engine emitted a command it should not");
                (address token, address recipient, uint256 amountMin) =
                    abi.decode(inputs[i], (address, address, uint256));
                require(recipient != address(this), "MockAero: InvalidRecipient");
                _pay(token, recipient, amountMin);
            }
        }
        // The batch's closure: every token a swap spent goes back to the caller, whole.
        for (uint256 k = 0; k < _touched.length; ++k) {
            _pay(_touched[k], msg.sender, 0);
        }
        delete _touched;
    }

    function _exactIn(SwapExactInParams memory p, bool cl) private {
        require(!p.payerIsUser, "MockAero: the engine pays from the router's balance");
        require(p.amountIn.mode == SpendMode.Amount, "MockAero: the engine spends an exact amount");
        address tokenOut = _route(p.pools, p.tokenIn, cl);
        uint256 taken = partialFill && cl ? p.amountIn.value / 2 : p.amountIn.value;
        uint256 out = _quote(p.tokenIn, tokenOut, taken, Math.Rounding.Floor);
        if (out < p.minAmountOut) revert TooLittleReceived(p.minAmountOut, out);
        _spend(p.tokenIn, taken);
        inventory.pay(tokenOut, p.recipient, out);
    }

    function _exactOut(SwapExactOutParams memory p, bool cl) private {
        require(!p.payerIsUser, "MockAero: the engine pays from the router's balance");
        address tokenOut = _route(p.pools, p.tokenIn, cl);
        uint256 needed = _quote(tokenOut, p.tokenIn, p.amountOut, Math.Rounding.Ceil);
        if (needed > p.maxAmountIn) revert TooMuchRequested();
        _spend(p.tokenIn, needed);
        inventory.pay(tokenOut, p.recipient, p.amountOut);
    }

    /// @dev Walks `pools` forward from `tokenIn` as the Metarouter does, and returns the route's output token.
    function _route(address[] memory pools, address tokenIn, bool cl) private view returns (address token) {
        require(pools.length != 0, "MockAero: InvalidPath");
        token = tokenIn;
        for (uint256 h = 0; h < pools.length; ++h) {
            MockAeroPool pool = MockAeroPool(pools[h]);
            if (!_isAeros(pools[h]) || pool.cl() != cl) revert InvalidPool(pools[h]);
            if (token == pool.token0()) token = pool.token1();
            else if (token == pool.token1()) token = pool.token0();
            else revert InvalidPath();
        }
    }

    /// @dev Whether one of the three factories made `pool`: the registry check the real router makes.
    function _isAeros(address pool) private view returns (bool) {
        return CL.isPool(pool) || VOLATILE.isPool(pool) || STABLE.isPool(pool);
    }

    /// @dev `amount` of `from` in `to`, at the tokens' prices.
    function _quote(address from, address to, uint256 amount, Math.Rounding r) private view returns (uint256) {
        uint256 value = Math.mulDiv(amount, priceUsd[from], 10 ** decimalsOf[from], r);
        return Math.mulDiv(value, 10 ** decimalsOf[to], priceUsd[to], r);
    }

    function _spend(address token, uint256 amount) private {
        require(IERC20(token).balanceOf(address(this)) >= amount, "MockAero: not pre-funded");
        IERC20(token).safeTransfer(address(inventory), amount);
        _touched.push(token);
    }

    function _pay(address token, address to, uint256 amountMin) private {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= amountMin, "MockAero: InsufficientBalance");
        if (balance != 0) IERC20(token).safeTransfer(to, balance);
    }
}
