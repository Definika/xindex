// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexToken} from "./interfaces/IIndexToken.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {PathLib} from "./libraries/PathLib.sol";

/// @title IndexZap
/// @notice Stateless convenience router: mint any index with a single token (USDC, USDT, ...) and
///         burn any index straight into a single token, using Uniswap V3 for the swaps.
/// @dev Design notes
///      - The contract holds no state and no funds between transactions. Anyone can deploy a
///        competing zap; the index contracts do not know or care about this one.
///      - Minting uses exact-output swaps so the zap buys precisely the basket for `shares` and
///        the only leftover is `tokenIn`, refunded in one transfer.
///      - Every swap path is checked to start at the component and end at the user's token, so a
///        malformed path cannot leave funds in a third token.
///      - Each leg can carry its own limit on top of the overall `maxAmountIn` / `minAmountOut`, so a
///        sandwich cannot spend the whole tolerance on one thin pool. A zero leg limit means "overall
///        limit only". The overall burn limit must be non-zero.
///      - What the user pays and receives is measured as balance changes inside the call, so tokens
///        already sitting in the zap are never used. A fee-on-transfer currency reverts with
///        `TransferShortfall`. When the router takes less of a component than it was given, because a pool
///        reached its price limit or the router paid WETH from ETH it was holding, the unsold part goes to
///        the recipient instead of being stranded or blocking the burn.
///      - The zap never calls `redeemSkipping`: a claim recorded for the zap could never be collected.
///        While a component is frozen, holders exit directly through the index.
///      - Every call names the index's `rebalanceNonce` its quote was taken at. A rebalance changes the units, so a
///        stale quote reverts with `StaleRebalanceNonce` instead of buying or selling a different basket.
///      - The zap never calls `executeRebalance`.
contract IndexZap is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PathLib for bytes;

    /// @param path Exact-output Uniswap V3 path from the component back to `tokenIn`; empty when the
    ///             component is `tokenIn` itself.
    /// @param maxAmountIn Most `tokenIn` this leg may spend, or 0 for the overall limit only.
    struct MintLeg {
        bytes path;
        uint256 maxAmountIn;
    }

    /// @param path Exact-input Uniswap V3 path from the component to `tokenOut`; empty when the component
    ///             is `tokenOut` itself.
    /// @param minAmountOut Least `tokenOut` this leg must return, or 0 for the overall limit only.
    struct BurnLeg {
        bytes path;
        uint256 minAmountOut;
    }

    /// @param expectedNonce The index's `rebalanceNonce` when the legs were quoted.
    /// @param legs One entry per component, in component order.
    struct MintParams {
        address index;
        uint256 expectedNonce;
        address tokenIn;
        uint256 maxAmountIn;
        uint256 shares;
        MintLeg[] legs;
        address to;
        uint256 deadline;
    }

    /// @param expectedNonce The index's `rebalanceNonce` when the legs were quoted.
    /// @param legs One entry per component, in component order.
    struct BurnParams {
        address index;
        uint256 expectedNonce;
        uint256 shares;
        address tokenOut;
        uint256 minAmountOut;
        BurnLeg[] legs;
        address to;
        uint256 deadline;
    }

    IIndexFactory public immutable FACTORY;
    ISwapRouter02 public immutable ROUTER;

    event ZapMint(
        address indexed index,
        address indexed user,
        address indexed to,
        address tokenIn,
        uint256 amountSpent,
        uint256 shares
    );
    event ComponentReturned(address indexed index, address indexed to, address indexed component, uint256 amount);
    event ZapBurn(
        address indexed index,
        address indexed user,
        address indexed to,
        address tokenOut,
        uint256 shares,
        uint256 amountOut
    );

    error NotIndex(address index);
    error StaleRebalanceNonce(uint256 expected, uint256 actual);
    error Expired();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRecipient(address to);
    error LegCountMismatch();
    error BadPath(uint256 i);
    error InsufficientBudget(uint256 needed, uint256 available);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error TransferShortfall(address token);

    constructor(IIndexFactory factory, ISwapRouter02 router) {
        if (address(factory) == address(0) || address(router) == address(0)) revert ZeroAddress();
        FACTORY = factory;
        ROUTER = router;
    }

    // ---------------------------------------------------------------------
    // Mint
    // ---------------------------------------------------------------------

    /// @notice Buys exactly `p.shares` of `p.index` spending at most `p.maxAmountIn` of `p.tokenIn`.
    ///         Unspent `tokenIn` is refunded to msg.sender.
    function mintWithToken(MintParams calldata p) external nonReentrant returns (uint256 amountSpent) {
        _checkCommon(p.index, p.expectedNonce, p.to, p.deadline);
        if (p.shares == 0 || p.maxAmountIn == 0) revert ZeroAmount();

        IERC20 tokenIn = IERC20(p.tokenIn);
        uint256 balanceBefore = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), p.maxAmountIn);
        uint256 received = tokenIn.balanceOf(address(this)) - balanceBefore;
        if (received < p.maxAmountIn) revert TransferShortfall(p.tokenIn);
        tokenIn.forceApprove(address(ROUTER), p.maxAmountIn);

        uint256 reserved = _buyBasket(p);

        // Whatever of this call's tokenIn the swaps did not take goes back, except the part the basket
        // itself holds, which issue() pulls below.
        uint256 refund = tokenIn.balanceOf(address(this)) - balanceBefore - reserved;
        amountSpent = received - refund;
        tokenIn.forceApprove(address(ROUTER), 0);
        if (refund != 0) tokenIn.safeTransfer(msg.sender, refund);

        // The amount is only known after the swaps; the function is nonReentrant so the log cannot
        // be reordered by a reentrant call.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ZapMint(p.index, msg.sender, p.to, p.tokenIn, amountSpent, p.shares);

        IIndexToken(p.index).issue(p.shares, p.to);
    }

    /// @dev Buys every component that is not `tokenIn`, approves the index for the whole basket and
    ///      returns the amount of `tokenIn` that the basket holds directly.
    function _buyBasket(MintParams calldata p) private returns (uint256) {
        address[] memory tokens = IIndexToken(p.index).componentTokens();
        uint256 n = tokens.length;
        if (p.legs.length != n) revert LegCountMismatch();
        uint256[] memory need = IIndexToken(p.index).previewIssue(p.shares);

        uint256 reserved = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (tokens[i] == p.tokenIn) reserved = need[i];
        }
        if (reserved > p.maxAmountIn) revert InsufficientBudget(reserved, p.maxAmountIn);

        uint256 spent = reserved;
        for (uint256 i = 0; i < n; ++i) {
            address component = tokens[i];
            if (component == p.tokenIn) {
                if (p.legs[i].path.length != 0) revert BadPath(i);
            } else {
                spent += _buy(p.legs[i], component, p.tokenIn, need[i], p.maxAmountIn - spent, i);
            }
            IERC20(component).forceApprove(p.index, need[i]);
        }
        return reserved;
    }

    function _buy(
        MintLeg calldata leg,
        address component,
        address tokenIn,
        uint256 amountOut,
        uint256 budget,
        uint256 i
    ) private returns (uint256 amountIn) {
        _checkPath(leg.path, component, tokenIn, i);
        uint256 cap = leg.maxAmountIn != 0 && leg.maxAmountIn < budget ? leg.maxAmountIn : budget;
        amountIn = ROUTER.exactOutput(
            ISwapRouter02.ExactOutputParams({
                path: leg.path, recipient: address(this), amountOut: amountOut, amountInMaximum: cap
            })
        );
    }

    // ---------------------------------------------------------------------
    // Burn
    // ---------------------------------------------------------------------

    /// @notice Burns `p.shares` of `p.index` (pulled from msg.sender, which must have approved the zap)
    ///         and delivers at least `p.minAmountOut` of `p.tokenOut` to `p.to`.
    function burnToToken(BurnParams calldata p) external nonReentrant returns (uint256 amountOut) {
        _checkBurn(p);
        amountOut = _burnBasket(p);
    }

    /// @notice {burnToToken} in one transaction, using an EIP-2612 permit for exactly `p.shares` that expires
    ///         at `p.deadline`.
    function burnToTokenWithPermit(BurnParams calldata p, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        _checkBurn(p);
        // If someone already submitted this permit, the allowance is in place and the burn can proceed.
        // Any other failure shows up as a transfer revert in _burnBasket. `p.index` is a verified index and the
        // function is nonReentrant; Wake's reentrancy detector does not model the guard, hence the suppression.
        // wake-disable-next-line reentrancy
        try IERC20Permit(p.index).permit(msg.sender, address(this), p.shares, p.deadline, v, r, s) {} catch {}
        amountOut = _burnBasket(p);
    }

    function _burnBasket(BurnParams calldata p) private returns (uint256 amountOut) {
        address[] memory tokens = IIndexToken(p.index).componentTokens();
        if (p.legs.length != tokens.length) revert LegCountMismatch();

        IERC20 tokenOut = IERC20(p.tokenOut);
        uint256 outBefore = tokenOut.balanceOf(address(this));
        IERC20(p.index).safeTransferFrom(msg.sender, address(this), p.shares);
        // redeem() rounds down deterministically, so the preview is the exact amount received.
        uint256[] memory got = IIndexToken(p.index).previewRedeem(p.shares);
        // The basket has to be in hand before it can be sold, so this interaction cannot be the last
        // one. The function is nonReentrant and the zap keeps no state; Wake's reentrancy detector
        // does not model reentrancy guards, hence the suppression.
        // wake-disable-next-line reentrancy
        IIndexToken(p.index).redeem(p.shares, address(this));

        uint256 reported = _sellBasket(p, tokens, got);
        amountOut = tokenOut.balanceOf(address(this)) - outBefore;
        if (amountOut < reported) revert TransferShortfall(p.tokenOut);
        if (amountOut < p.minAmountOut) revert InsufficientOutput(amountOut, p.minAmountOut);

        // forge-lint: disable-next-line(reentrancy-events)
        emit ZapBurn(p.index, msg.sender, p.to, p.tokenOut, p.shares, amountOut);
        tokenOut.safeTransfer(p.to, amountOut);
    }

    /// @dev Sells every component held by this contract into `tokenOut` and returns the `tokenOut` the
    ///      router reported, counting components that already are `tokenOut`.
    function _sellBasket(BurnParams calldata p, address[] memory tokens, uint256[] memory got)
        private
        returns (uint256)
    {
        uint256 reported = 0;
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            address component = tokens[i];
            if (component == p.tokenOut) {
                if (p.legs[i].path.length != 0) revert BadPath(i);
                reported += got[i];
            } else if (got[i] != 0) {
                reported += _sell(p, component, got[i], i);
            }
        }
        return reported;
    }

    function _sell(BurnParams calldata p, address component, uint256 amountIn, uint256 i)
        private
        returns (uint256 amountOut)
    {
        BurnLeg calldata leg = p.legs[i];
        _checkPath(leg.path, component, p.tokenOut, i);
        IERC20 token = IERC20(component);
        uint256 before = token.balanceOf(address(this));
        token.forceApprove(address(ROUTER), amountIn);
        amountOut = ROUTER.exactInput(
            ISwapRouter02.ExactInputParams({
                path: leg.path, recipient: address(this), amountIn: amountIn, amountOutMinimum: leg.minAmountOut
            })
        );

        // SwapRouter02 can take less than amountIn: a pool can stop at its price limit, and the router pays WETH
        // from any ETH it holds instead of pulling it. The per-leg and overall minimums still bound the price of
        // what was sold; whatever was not sold goes to the recipient.
        uint256 unsold = amountIn - (before - token.balanceOf(address(this)));
        if (unsold != 0) {
            token.forceApprove(address(ROUTER), 0);
            // forge-lint: disable-next-line(reentrancy-events)
            emit ComponentReturned(p.index, p.to, component, unsold);
            token.safeTransfer(p.to, unsold);
        }
    }

    // ---------------------------------------------------------------------
    // Checks
    // ---------------------------------------------------------------------

    function _checkBurn(BurnParams calldata p) private view {
        _checkCommon(p.index, p.expectedNonce, p.to, p.deadline);
        if (p.shares == 0 || p.minAmountOut == 0) revert ZeroAmount();
    }

    function _checkCommon(address index, uint256 expectedNonce, address to, uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (!FACTORY.isIndex(index)) revert NotIndex(index);
        uint256 nonce = IIndexToken(index).rebalanceNonce();
        if (nonce != expectedNonce) revert StaleRebalanceNonce(expectedNonce, nonce);
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this) || to == index) revert InvalidRecipient(to);
    }

    /// @dev A path must be well formed, start at `first` and end at `last`. For exact-output paths
    ///      (mint) "first" is the component being bought and "last" is the token being spent; for
    ///      exact-input paths (burn) "first" is the component being sold and "last" is the payout.
    function _checkPath(bytes calldata path, address first, address last, uint256 i) private pure {
        if (!path.isValidShape() || path.firstToken() != first || path.lastToken() != last) {
            revert BadPath(i);
        }
    }
}
