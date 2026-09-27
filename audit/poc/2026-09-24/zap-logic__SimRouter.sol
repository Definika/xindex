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

/// @notice Token custody for the simulated V3 pools or the simulated V4 PoolManager.
contract SimVault {
    using SafeERC20 for IERC20;

    address public immutable router;

    constructor() {
        router = msg.sender;
    }

    function pay(address token, address to, uint256 amount) external {
        require(msg.sender == router, "SimVault: only router");
        IERC20(token).safeTransfer(to, amount);
    }
}

/// @notice A Universal Router 2.0.0 stand-in that simulates every hop the way the pinned router and v4-periphery do,
///         rather than only the route's endpoints:
///         - V3 exact-in walks hop by hop, the router custodying intermediates, and checks the minimum on the last
///           hop only. A pool with limited capacity fills partially and leaves the unsold input with the payer.
///         - V3 exact-out walks from the output back, and any hop that cannot deliver in full reverts (the router's
///           V3InvalidAmountOut on the first swap, the pool's IIA on an intermediate one).
///         - V4 keeps a per-currency delta for the locker. Exact-in and exact-out walk the path the way V4Router does,
///           exact-out checks `amountInMaximum` against the last hop it executed only (upstream #564), SETTLE and TAKE
///           resolve OPEN_DELTA as the full debt / full credit with DeltaNotNegative / DeltaNotPositive, and the unlock
///           reverts CurrencyNotSettled if any delta, native ether included, is left open.
///         - SWEEP sends the router's whole balance.
///         Prices are per token, a flat fee is taken on every hop, and each pool can be given a capacity in dollars
///         per swap, above which it fills partially.
contract SimRouter is IUniversalRouter {
    using SafeERC20 for IERC20;

    error V3TooLittleReceived();
    error V3TooMuchRequested();
    error V3InvalidAmountOut();
    error IIA();
    error NoPool(address a, address b);
    error PoolNotInitialized();
    error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived);
    error V4TooMuchRequested(uint256 maxAmountInRequested, uint256 amountRequested);
    error DeltaNotNegative(address currency);
    error DeltaNotPositive(address currency);
    error CurrencyNotSettled();
    error NativeNotSupported();
    error InsufficientToken();
    error RouterCannotPay(address token, uint256 balance, uint256 amount);

    address public immutable poolManager;
    SimVault public immutable v3Pools;
    SimVault public immutable pm;

    mapping(address => uint256) public px; // dollars per whole token, 1e18 = $1
    mapping(address => uint8) public dec;
    mapping(bytes32 => uint256) public capUsd; // 0 = unlimited
    uint256 public feeBps = 30;

    // Unrealistic misbehaviours, for the "no bystander loss whatever the router does" checks only.
    uint256 public overDeliver; // extra raw units an exact-out delivers
    uint256 public skimBps; // share of the router's balance a sweep keeps

    // V4 deltas, reset every V4_SWAP.
    address[] private _touched;
    mapping(address => int256) public delta;

    struct Exec {
        uint8 kind; // 1 V3 in, 2 V3 out, 3 V4 in, 4 V4 out
        address firstIn;
        address lastOut;
        uint256 lastHopOut; // output of the last hop executed (exact-in), or delivered amountOut (exact-out)
        uint256 minOut; // the minimum the caller encoded (exact-in)
        uint256 maxIn; // the maximum the caller encoded (exact-out)
        uint256 taken; // what TAKE paid (V4) or what the swap delivered to the recipient (V3)
        address sweptToken;
        uint256 swept;
        uint256 spentFromRouter; // of sweptToken, what the router paid out of its balance
    }

    Exec[] private _log;
    Exec private _cur;

    constructor(address poolManager_) {
        poolManager = poolManager_;
        v3Pools = new SimVault();
        pm = new SimVault();
    }

    // ------------------------------------------------------------------ config

    function setPrice(address token, uint256 price, uint8 decimals_) external {
        px[token] = price;
        dec[token] = decimals_;
    }

    function setCap(address a, address b, uint256 usd) external {
        capUsd[_pair(a, b)] = usd;
    }

    function setFeeBps(uint256 f) external {
        feeBps = f;
    }

    function setOverDeliver(uint256 x) external {
        overDeliver = x;
    }

    function setSkimBps(uint256 x) external {
        skimBps = x;
    }

    function clearLog() external {
        delete _log;
    }

    function logLength() external view returns (uint256) {
        return _log.length;
    }

    function logAt(uint256 i) external view returns (Exec memory) {
        return _log[i];
    }

    // ------------------------------------------------------------------ pricing

    function _pair(address a, address b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _exists(address a, address b) internal view returns (bool) {
        return a != b && px[a] != 0 && px[b] != 0;
    }

    function _valueOf(address t, uint256 raw, Math.Rounding r) internal view returns (uint256) {
        return Math.mulDiv(raw, px[t], 10 ** dec[t], r);
    }

    function _rawOf(address t, uint256 usd, Math.Rounding r) internal view returns (uint256) {
        return Math.mulDiv(usd, 10 ** dec[t], px[t], r);
    }

    /// @dev Output of selling `amountIn` of `a` for `b`, capped by the pool's capacity; `taken` is the input consumed.
    function quoteFill(address a, address b, uint256 amountIn) public view returns (uint256 taken, uint256 out) {
        uint256 v = _valueOf(a, amountIn, Math.Rounding.Floor);
        v = v * (10_000 - feeBps) / 10_000;
        out = _rawOf(b, v, Math.Rounding.Floor);
        taken = amountIn;
        uint256 cap = capUsd[_pair(a, b)];
        if (cap != 0) {
            uint256 capRaw = _rawOf(b, cap, Math.Rounding.Floor);
            if (out > capRaw) {
                out = capRaw;
                taken = quoteNeed(a, b, out);
                if (taken > amountIn) taken = amountIn;
            }
        }
    }

    /// @dev Input of `a` needed to buy exactly `out` of `b`, rounded up.
    function quoteNeed(address a, address b, uint256 out) public view returns (uint256) {
        uint256 v = _valueOf(b, out, Math.Rounding.Ceil);
        v = Math.mulDiv(v, 10_000, 10_000 - feeBps, Math.Rounding.Ceil);
        return _rawOf(a, v, Math.Rounding.Ceil);
    }

    /// @dev Most of `b` one swap through the pool can deliver.
    function capacityOut(address a, address b) public view returns (uint256) {
        uint256 cap = capUsd[_pair(a, b)];
        return cap == 0 ? type(uint256).max : _rawOf(b, cap, Math.Rounding.Floor);
    }

    // ------------------------------------------------------------------ execute

    function execute(bytes calldata commands, bytes[] calldata inputs) external payable {
        require(commands.length == inputs.length, "SimRouter: length");
        delete _cur;
        for (uint256 i = 0; i < commands.length; ++i) {
            uint8 c = uint8(commands[i]);
            if (c == Cmd.V3_SWAP_EXACT_IN) {
                _v3In(inputs[i]);
            } else if (c == Cmd.V3_SWAP_EXACT_OUT) {
                _v3Out(inputs[i]);
            } else if (c == Cmd.V4_SWAP) {
                _v4(inputs[i]);
            } else if (c == Cmd.SWEEP) {
                _sweep(inputs[i]);
            } else {
                revert("SimRouter: unexpected command");
            }
        }
        _log.push(_cur);
    }

    function _map(address r) internal view returns (address) {
        if (r == V4.MSG_SENDER) return msg.sender;
        if (r == V4.ADDRESS_THIS) return address(this);
        return r;
    }

    function _routerPay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < amount) revert RouterCannotPay(token, bal, amount);
        IERC20(token).safeTransfer(to, amount);
        _cur.spentFromRouter += amount; // the swept token is the only one the router ever holds in these flows
    }

    function _tokenAt(bytes memory path, uint256 offset) internal pure returns (address a) {
        assembly {
            a := shr(96, mload(add(add(path, 0x20), offset)))
        }
    }

    function _v3In(bytes calldata input) internal {
        (address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path, bool payerIsUser) =
            abi.decode(input, (address, uint256, uint256, bytes, bool));
        require(!payerIsUser, "SimRouter: payerIsUser");
        require(amountIn != (1 << 255), "SimRouter: CONTRACT_BALANCE");
        recipient = _map(recipient);
        uint256 hops = (path.length - 20) / 23;
        _cur.kind = 1;
        _cur.firstIn = _tokenAt(path, 0);
        _cur.minOut = amountOutMin;
        uint256 out;
        for (uint256 h = 0; h < hops; ++h) {
            address a = _tokenAt(path, h * 23);
            address b = _tokenAt(path, h * 23 + 23);
            if (a == address(0) || b == address(0) || !_exists(a, b)) revert NoPool(a, b);
            uint256 taken;
            (taken, out) = quoteFill(a, b, amountIn);
            // The router pays every hop from its own balance: the pre-fund, then its custody of intermediates.
            _routerPay(a, address(v3Pools), taken);
            v3Pools.pay(b, h + 1 == hops ? recipient : address(this), out);
            amountIn = out;
            _cur.lastOut = b;
        }
        if (out < amountOutMin) revert V3TooLittleReceived();
        _cur.lastHopOut = out;
        _cur.taken = out;
    }

    function _v3Out(bytes calldata input) internal {
        (address recipient, uint256 amountOut, uint256 amountInMax, bytes memory path, bool payerIsUser) =
            abi.decode(input, (address, uint256, uint256, bytes, bool));
        require(!payerIsUser, "SimRouter: payerIsUser");
        recipient = _map(recipient);
        uint256 hops = (path.length - 20) / 23;
        _cur.kind = 2;
        _cur.lastOut = _tokenAt(path, 0);
        _cur.maxIn = amountInMax;
        uint256 want = amountOut;
        address tIn;
        for (uint256 h = 0; h < hops; ++h) {
            address tOut = _tokenAt(path, h * 23);
            tIn = _tokenAt(path, h * 23 + 23);
            if (tIn == address(0) || tOut == address(0) || !_exists(tIn, tOut)) revert NoPool(tIn, tOut);
            if (capacityOut(tIn, tOut) < want) {
                if (h == 0) revert V3InvalidAmountOut();
                revert IIA();
            }
            want = quoteNeed(tIn, tOut, want);
        }
        _cur.firstIn = tIn;
        if (want > amountInMax) revert V3TooMuchRequested();
        _routerPay(tIn, address(v3Pools), want);
        uint256 delivered = amountOut + overDeliver;
        v3Pools.pay(_cur.lastOut, recipient, delivered);
        _cur.lastHopOut = delivered;
        _cur.taken = delivered;
    }

    function _touch(address c) internal {
        for (uint256 i = 0; i < _touched.length; ++i) {
            if (_touched[i] == c) return;
        }
        _touched.push(c);
    }

    function _add(address c, int256 d) internal {
        _touch(c);
        delta[c] += d;
    }

    function _hookless(PathKey memory k) internal pure {
        if (k.hooks != address(0) || k.hookData.length != 0) revert PoolNotInitialized();
    }

    function _v4(bytes calldata input) internal {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        require(actions.length == params.length, "SimRouter: v4 length");
        for (uint256 i = 0; i < _touched.length; ++i) {
            delta[_touched[i]] = 0;
        }
        delete _touched;
        for (uint256 i = 0; i < actions.length; ++i) {
            uint8 a = uint8(actions[i]);
            if (a == V4.SWAP_EXACT_IN) {
                _v4In(abi.decode(params[i], (V4ExactInputParams)));
            } else if (a == V4.SWAP_EXACT_OUT) {
                _v4Out(abi.decode(params[i], (V4ExactOutputParams)));
            } else if (a == V4.SETTLE) {
                (address c, uint256 amt, bool payerIsUser) = abi.decode(params[i], (address, uint256, bool));
                require(!payerIsUser, "SimRouter: payerIsUser");
                if (amt == V4.OPEN_DELTA) {
                    int256 d = delta[c];
                    if (d > 0) revert DeltaNotNegative(c);
                    amt = uint256(-d);
                }
                if (amt == 0) continue;
                if (c == address(0)) revert NativeNotSupported();
                _routerPay(c, address(pm), amt);
                _add(c, int256(amt));
            } else if (a == V4.TAKE) {
                (address c, address to, uint256 amt) = abi.decode(params[i], (address, address, uint256));
                if (amt == V4.OPEN_DELTA) {
                    int256 d = delta[c];
                    if (d < 0) revert DeltaNotPositive(c);
                    amt = uint256(d);
                }
                if (amt == 0) continue;
                if (c == address(0)) revert NativeNotSupported();
                pm.pay(c, _map(to), amt);
                _add(c, -int256(amt));
                _cur.taken += amt;
            } else {
                revert("SimRouter: unexpected action");
            }
        }
        for (uint256 i = 0; i < _touched.length; ++i) {
            if (delta[_touched[i]] != 0) revert CurrencyNotSettled();
        }
    }

    function _v4In(V4ExactInputParams memory p) internal {
        _cur.kind = 3;
        _cur.firstIn = p.currencyIn;
        _cur.minOut = p.amountOutMinimum;
        address cIn = p.currencyIn;
        uint256 amountIn = p.amountIn;
        if (amountIn == V4.OPEN_DELTA) {
            int256 d = delta[cIn];
            if (d < 0) revert DeltaNotPositive(cIn);
            amountIn = uint256(d);
        }
        uint256 out;
        for (uint256 h = 0; h < p.path.length; ++h) {
            PathKey memory k = p.path[h];
            _hookless(k);
            if (!_exists(cIn, k.intermediateCurrency)) revert PoolNotInitialized();
            uint256 taken;
            (taken, out) = quoteFill(cIn, k.intermediateCurrency, amountIn);
            _add(cIn, -int256(taken));
            _add(k.intermediateCurrency, int256(out));
            amountIn = out;
            cIn = k.intermediateCurrency;
        }
        _cur.lastOut = cIn;
        _cur.lastHopOut = out;
        if (out < p.amountOutMinimum) revert V4TooLittleReceived(p.amountOutMinimum, out);
    }

    function _v4Out(V4ExactOutputParams memory p) internal {
        _cur.kind = 4;
        _cur.lastOut = p.currencyOut;
        _cur.maxIn = p.amountInMaximum;
        address cOut = p.currencyOut;
        uint256 amountOut = p.amountOut;
        if (amountOut == V4.OPEN_DELTA) {
            int256 d = delta[cOut];
            if (d > 0) revert DeltaNotNegative(cOut);
            amountOut = uint256(-d);
        }
        uint256 amountIn;
        for (uint256 i = p.path.length; i > 0; --i) {
            PathKey memory k = p.path[i - 1];
            _hookless(k);
            if (!_exists(k.intermediateCurrency, cOut)) revert PoolNotInitialized();
            // An exact-output V4 swap delivers at most what was asked, and less when the pool runs out.
            uint256 deliver = Math.min(amountOut, capacityOut(k.intermediateCurrency, cOut));
            if (i == p.path.length) deliver += overDeliver;
            amountIn = quoteNeed(k.intermediateCurrency, cOut, deliver);
            _add(cOut, int256(deliver));
            _add(k.intermediateCurrency, -int256(amountIn));
            amountOut = amountIn;
            cOut = k.intermediateCurrency;
        }
        _cur.firstIn = cOut;
        _cur.lastHopOut = amountIn;
        // Upstream #564: only the last hop executed is compared with the maximum.
        if (amountIn > p.amountInMaximum) revert V4TooMuchRequested(p.amountInMaximum, amountIn);
    }

    function _sweep(bytes calldata input) internal {
        (address token, address recipient, uint256 amountMin) = abi.decode(input, (address, address, uint256));
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < amountMin) revert InsufficientToken();
        uint256 keep = bal * skimBps / 10_000;
        uint256 send = bal - keep;
        if (send > 0) IERC20(token).safeTransfer(_map(recipient), send);
        _cur.sweptToken = token;
        _cur.swept = send;
    }
}
