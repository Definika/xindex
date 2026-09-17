// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";
import {ISwapRouter02} from "./ISwapRouter02.sol";
import {IXindexErrors} from "./IXindexErrors.sol";

/// @title IIndexZap
/// @notice Stateless convenience router: mint any index with a single token (USDC, USDT, ...) and burn any index
///         straight into a single token, using Uniswap V3 for the swaps. Apps encode calls against this interface.
/// @dev Of the shared errors, the zap raises NotIndex for an index the factory did not deploy, ZeroAddress for a zero
///      factory, router or recipient, and InvalidRecipient for a recipient that is the zap, the index or the router.
interface IIndexZap is IXindexErrors {
    /// @param path Exact-output Uniswap V3 path from the component back to `tokenIn`; empty when the component is
    ///        `tokenIn` itself.
    /// @param maxAmountIn Most `tokenIn` this leg may spend, or 0 for the overall limit only.
    struct MintLeg {
        bytes path;
        uint256 maxAmountIn;
    }

    /// @param path Exact-input Uniswap V3 path from the component to `tokenOut`; empty when the component is
    ///        `tokenOut` itself. Checked even when the component redeems to zero. Each hop is swapped on its own, so
    ///        the unsold input of any hop, not only the first, comes back to `to`; an intermediate hop that sells
    ///        nothing reverts with InsufficientOutput.
    /// @param minAmountOut Least `tokenOut` this leg must return, or 0 for the overall limit only. It applies to the
    ///        last hop's output. A non-zero minimum on a leg that sells nothing reverts.
    struct BurnLeg {
        bytes path;
        uint256 minAmountOut;
    }

    /// @param index Index to mint; must be registered in the factory.
    /// @param expectedNonce The index's `rebalanceNonce` when the legs were quoted.
    /// @param tokenIn Token the caller pays with. The full `maxAmountIn` is pulled first and the unspent part refunded.
    /// @param maxAmountIn Most `tokenIn` the whole mint may spend; non-zero.
    /// @param shares Exact index shares to mint (1e18 is one index token); non-zero.
    /// @param legs One entry per component, in component order.
    /// @param to Receives the shares; not zero, the zap, the index or the router.
    /// @param deadline Last timestamp at which the call is valid.
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

    /// @param index Index to burn; must be registered in the factory.
    /// @param expectedNonce The index's `rebalanceNonce` when the legs were quoted.
    /// @param shares Index shares to burn from the caller, who must have approved the zap (or signed a permit).
    /// @param tokenOut Token the caller receives.
    /// @param minAmountOut Least `tokenOut` the whole burn must return; non-zero.
    /// @param legs One entry per component, in component order.
    /// @param to Receives `tokenOut` and any unsold component; not zero, the zap, the index or the router.
    /// @param deadline Last timestamp at which the call is valid; also the permit's deadline.
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

    /// @notice `user` paid `amountSpent` of `tokenIn` and `to` received `shares` of `index`.
    /// @param user The caller who paid.
    /// @param to The recipient of the shares.
    /// @param amountSpent `tokenIn` spent, after the refund.
    event ZapMint(
        address indexed index,
        address indexed user,
        address indexed to,
        address tokenIn,
        uint256 amountSpent,
        uint256 shares
    );
    /// @notice The router sold less of `component` than the zap gave it; `amount` went to `to` instead. `component`
    ///         is the input of the hop that was not filled, so on a multi-hop leg it can be an intermediate token.
    ///         Unsold `tokenOut` raises the payout instead and is not reported here.
    event ComponentReturned(address indexed index, address indexed to, address indexed component, uint256 amount);
    /// @notice `user` burned `shares` of `index` and `to` received `amountOut` of `tokenOut`.
    /// @param user The caller whose shares were burned.
    /// @param amountOut `tokenOut` delivered to `to`.
    event ZapBurn(
        address indexed index,
        address indexed user,
        address indexed to,
        address tokenOut,
        uint256 shares,
        uint256 amountOut
    );

    /// @notice The index rebalanced since the legs were quoted; quote again.
    error StaleRebalanceNonce(uint256 expected, uint256 actual);
    /// @notice The deadline has passed.
    error Expired();
    /// @notice Zero shares, or a zero overall limit.
    error ZeroAmount();
    /// @notice `legs` does not have one entry per component.
    error LegCountMismatch();
    /// @notice Leg `i` has a malformed path, one with the wrong endpoints, or a path where none belongs.
    error BadPath(uint256 i);
    /// @notice The basket's own `tokenIn` component alone needs more than `maxAmountIn`.
    error InsufficientBudget(uint256 needed, uint256 available);
    /// @notice The burn, or a leg that sells nothing, returns less than its minimum.
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    /// @notice A transfer delivered less `token` than it should (a fee-on-transfer token).
    error TransferShortfall(address token);

    /// @notice Factory whose registry proves an address is an index.
    function FACTORY() external view returns (IIndexFactory);

    /// @notice Uniswap SwapRouter02 used for every swap.
    function ROUTER() external view returns (ISwapRouter02);

    /// @notice Buys exactly `p.shares` of `p.index` for `p.to`, spending at most `p.maxAmountIn` of `p.tokenIn`. The
    ///         whole `p.maxAmountIn` is pulled from msg.sender first, and the unspent part is refunded to it.
    /// @param p The mint; see {MintParams}. msg.sender must have approved the zap for `p.maxAmountIn` of `p.tokenIn`.
    /// @return amountSpent `tokenIn` used: the swaps' input plus any `tokenIn` the basket holds directly.
    function mintWithToken(MintParams calldata p) external returns (uint256 amountSpent);

    /// @notice Burns `p.shares` of `p.index` (pulled from msg.sender, which must have approved the zap) and delivers at
    ///         least `p.minAmountOut` of `p.tokenOut` to `p.to`. Any part of a hop's input the router did not take also
    ///         goes to `p.to`, with a ComponentReturned event.
    /// @param p The burn; see {BurnParams}.
    /// @return amountOut `tokenOut` delivered.
    function burnToToken(BurnParams calldata p) external returns (uint256 amountOut);

    /// @notice {burnToToken} in one transaction, using an EIP-2612 permit for exactly `p.shares` that expires at
    ///         `p.deadline`. A permit someone already submitted is accepted.
    /// @param p The burn; see {BurnParams}.
    /// @param v Signature recovery id.
    /// @param r Signature r value.
    /// @param s Signature s value.
    /// @return amountOut `tokenOut` delivered.
    function burnToTokenWithPermit(BurnParams calldata p, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 amountOut);
}
