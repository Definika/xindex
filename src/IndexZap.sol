// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexHub} from "./interfaces/IIndexHub.sol";
import {IIndexZap} from "./interfaces/IIndexZap.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";
import {UniversalRouterSwaps} from "./UniversalRouterSwaps.sol";

/// @title IndexZap
/// @notice Stateless convenience router: mint any index with a single token (USDC, USDT, ...) and burn any index
///         straight into a single token, swapping through Uniswap's Universal Router.
/// @dev Design notes
///      - The contract holds no state and no funds between transactions. Anyone can deploy a competing zap; the index
///        contracts do not know or care about this one.
///      - Every swap runs through {UniversalRouterSwaps}, the engine it shares with `BasketBuilder` since 2026-10-16,
///        whose notes cover the venues, the commands, the pre-fund and sweep, the spend bound, the measurement, the
///        hookless V4 routes and the hop-by-hop V3 sales. The zap's own rules follow.
///      - Minting uses exact-output swaps so the zap buys precisely the basket for `shares` and the only leftover is
///        `tokenIn`, refunded in one transfer.
///      - Each leg can carry its own limit on top of the overall `maxAmountIn` / `minAmountOut`, so a sandwich cannot
///        spend the whole tolerance on one thin pool. A zero leg limit means "overall limit only". The overall burn
///        limit must be non-zero.
///      - What the user pays and receives is measured as balance changes inside the call, so tokens already sitting in
///        the zap are never used. A fee-on-transfer currency reverts with `TransferShortfall`. What a burn hop did not
///        sell goes to the recipient with a ComponentReturned event; unsold `tokenOut` is paid out with the rest.
///      - The zap never calls `redeemSkipping`: a claim recorded for the zap could never be collected. While a
///        component is frozen, holders exit directly through the index.
///      - Every call names the index's `rebalanceNonce` its quote was taken at. A rebalance changes the units, so a
///        stale quote reverts with `StaleRebalanceNonce` instead of buying or selling a different basket.
///      - The zap never calls `executeRebalance`.
contract IndexZap is ReentrancyGuard, UniversalRouterSwaps, IIndexZap {
    using SafeERC20 for IERC20;

    /// @inheritdoc IIndexZap
    IIndexFactory public immutable FACTORY;

    constructor(IIndexFactory factory, IUniversalRouter router) UniversalRouterSwaps(router) {
        if (address(factory) == address(0)) revert ZeroAddress();
        FACTORY = factory;
    }

    // ---------------------------------------------------------------------
    // Mint
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexZap
    function mintWithToken(MintParams calldata p) external nonReentrant returns (uint256 amountSpent) {
        _checkCommon(p.index, p.expectedNonce, p.to, p.deadline);
        if (p.tokenIn == address(0)) revert ZeroAddress();
        if (p.shares == 0 || p.maxAmountIn == 0) revert ZeroAmount();

        IERC20 tokenIn = IERC20(p.tokenIn);
        uint256 balanceBefore = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), p.maxAmountIn);
        uint256 received = tokenIn.balanceOf(address(this)) - balanceBefore;
        if (received < p.maxAmountIn) revert TransferShortfall(p.tokenIn);

        uint256 reserved = _buyBasket(p);

        // Whatever of this call's tokenIn the swaps did not take goes back, except the part the basket itself holds,
        // which issue() pulls below. A balance the router happened to hold arrives through the sweep and enlarges the
        // refund rather than underflowing it.
        uint256 refund = Math.saturatingSub(tokenIn.balanceOf(address(this)) - balanceBefore, reserved);
        amountSpent = Math.saturatingSub(received, refund);
        if (refund != 0) tokenIn.safeTransfer(msg.sender, refund);

        // The amount is only known after the swaps; the function is nonReentrant so the log cannot
        // be reordered by a reentrant call.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ZapMint(p.index, msg.sender, p.to, p.tokenIn, amountSpent, p.shares);

        // The swaps and the refund run outside the index's guard, so a token callback could have settled a rebalance
        // since the check on entry; issuing then would buy a basket the legs were not quoted for.
        _checkNonce(p.index, p.expectedNonce);
        IIndexHub(p.index).issue(p.shares, p.to, p.referrer);
    }

    /// @dev Buys every component that is not `tokenIn`, approves the index for the whole basket and
    ///      returns the amount of `tokenIn` that the basket holds directly.
    function _buyBasket(MintParams calldata p) private returns (uint256) {
        address[] memory tokens = IIndexHub(p.index).componentTokens();
        uint256 n = tokens.length;
        if (p.legs.length != n) revert LegCountMismatch();
        uint256[] memory need = IIndexHub(p.index).previewIssue(p.shares);

        uint256 reserved = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (tokens[i] == p.tokenIn) reserved = need[i];
        }
        if (reserved > p.maxAmountIn) revert InsufficientBudget(reserved, p.maxAmountIn);

        uint256 spent = reserved;
        for (uint256 i = 0; i < n; ++i) {
            address component = tokens[i];
            if (component == p.tokenIn) {
                if (p.legs[i].v3Path.length != 0 || p.legs[i].v4Path.length != 0) revert BadRoute(i);
                // As on the burn side, the leg that carries no swap still honours its own limit (DA-15).
                uint256 legCap = p.legs[i].maxAmountIn;
                if (legCap != 0 && need[i] > legCap) revert InsufficientBudget(need[i], legCap);
            } else {
                MintLeg calldata leg = p.legs[i];
                uint256 budget = p.maxAmountIn - spent;
                uint256 cap = leg.maxAmountIn != 0 && leg.maxAmountIn < budget ? leg.maxAmountIn : budget;
                spent += _buy(p.tokenIn, component, need[i], cap, leg, i);
            }
            IERC20(component).forceApprove(p.index, need[i]);
        }
        return reserved;
    }

    // ---------------------------------------------------------------------
    // Burn
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexZap
    function burnToToken(BurnParams calldata p) external nonReentrant returns (uint256 amountOut) {
        _checkBurn(p);
        return _burnBasket(p);
    }

    /// @inheritdoc IIndexZap
    function burnToTokenWithPermit(BurnParams calldata p, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        _checkBurn(p);
        // A permit front-run by someone else leaves the allowance already set, which is the state this needed anyway,
        // so a failed permit is not a failed burn. The transfer below is what actually enforces the approval, and the
        // checks above have already run.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        // wake-disable-next-line reentrancy
        try IERC20Permit(p.index).permit(msg.sender, address(this), p.shares, p.deadline, v, r, s) {} catch {}
        return _burnBasket(p);
    }

    function _burnBasket(BurnParams calldata p) private returns (uint256 amountOut) {
        address[] memory tokens = IIndexHub(p.index).componentTokens();
        if (p.legs.length != tokens.length) revert LegCountMismatch();

        IERC20 tokenOut = IERC20(p.tokenOut);
        uint256 outBefore = tokenOut.balanceOf(address(this));
        IERC20(p.index).safeTransferFrom(msg.sender, address(this), p.shares);
        // redeem() rounds down deterministically, so the preview is the exact amount received.
        uint256[] memory got = IIndexHub(p.index).previewRedeem(p.shares);
        // The basket has to be in hand before it can be sold, so this interaction cannot be the last
        // one. The function is nonReentrant and the zap keeps no state; Wake's reentrancy detector
        // does not model reentrancy guards, hence the suppression.
        // wake-disable-next-line reentrancy
        IIndexHub(p.index).redeem(p.shares, address(this));

        _sellBasket(p, tokens, got);
        amountOut = tokenOut.balanceOf(address(this)) - outBefore;
        if (amountOut < p.minAmountOut) revert InsufficientOutput(amountOut, p.minAmountOut);

        // forge-lint: disable-next-line(reentrancy-events)
        emit ZapBurn(p.index, msg.sender, p.to, p.tokenOut, p.shares, amountOut);
        uint256 paidBefore = tokenOut.balanceOf(p.to);
        tokenOut.safeTransfer(p.to, amountOut);
        // A fee-on-transfer payout would leave the recipient short of what this call reported paying them.
        if (tokenOut.balanceOf(p.to) - paidBefore < amountOut) revert TransferShortfall(p.tokenOut);
    }

    /// @dev Sells every component held by this contract into `tokenOut`, counting components that already are
    ///      `tokenOut`. Nothing is returned: the payout is the contract's own `tokenOut` balance change.
    function _sellBasket(BurnParams calldata p, address[] memory tokens, uint256[] memory got) private {
        uint256 n = tokens.length;
        bytes memory ctx = abi.encode(p.index, p.to);
        for (uint256 i = 0; i < n; ++i) {
            address component = tokens[i];
            if (component == p.tokenOut) {
                if (p.legs[i].v3Path.length != 0 || p.legs[i].v4Path.length != 0) revert BadRoute(i);
                // The pass-through leg carries no swap, but its limit is still the caller's and is still checked, so
                // every leg honours the limit its NatSpec promises (DA-15).
                if (got[i] < p.legs[i].minAmountOut) revert InsufficientOutput(got[i], p.legs[i].minAmountOut);
                continue;
            }
            // Every leg is validated, including one that sells nothing, whose minimum then cannot be met.
            _sell(p.tokenOut, component, got[i], p.legs[i], i, ctx);
        }
    }

    /// @dev What a hop did not sell goes to the burn's recipient, with any balance of it the router already held.
    function _unsold(address token, uint256 amount, bytes memory ctx) internal override {
        (address index, address to) = abi.decode(ctx, (address, address));
        // forge-lint: disable-next-line(reentrancy-events)
        emit ComponentReturned(index, to, token, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------------
    // Checks
    // ---------------------------------------------------------------------

    function _checkBurn(BurnParams calldata p) private view {
        _checkCommon(p.index, p.expectedNonce, p.to, p.deadline);
        if (p.tokenOut == address(0)) revert ZeroAddress();
        if (p.shares == 0 || p.minAmountOut == 0) revert ZeroAmount();
    }

    function _checkCommon(address index, uint256 expectedNonce, address to, uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (!FACTORY.isIndex(index)) revert NotIndex(index);
        _checkNonce(index, expectedNonce);
        if (to == address(0)) revert ZeroAddress();
        // Tokens left in the router can be swept by anyone, and anything sent to the pool manager is a donation. The
        // factory can never move a token on either, so a burn paid to it is lost (RT-21).
        if (to == address(this) || to == index || to == address(ROUTER) || to == POOL_MANAGER || to == address(FACTORY))
        {
            revert InvalidRecipient(to);
        }
    }

    function _checkNonce(address index, uint256 expectedNonce) private view {
        uint256 nonce = IIndexHub(index).rebalanceNonce();
        if (nonce != expectedNonce) revert StaleRebalanceNonce(expectedNonce, nonce);
    }
}
