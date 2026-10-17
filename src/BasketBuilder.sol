// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBasketBuilder} from "./interfaces/IBasketBuilder.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexHub} from "./interfaces/IIndexHub.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";
import {UniversalRouterSwaps} from "./UniversalRouterSwaps.sol";

/// @title BasketBuilder
/// @notice Builds a basket too wide for the zap's single transaction. The legs are bought over several calls into an
///         escrow the caller owns here, then issued in one call. Selling works the same way in reverse. See
///         {IBasketBuilder}.
/// @dev Design notes
///      - Escrow: per caller and per token (`escrowOf`). A token in it moves only on its owner's call: into an issue,
///        a sale, or a withdrawal.
///      - The builder has no owner, no upgrade and nothing to configure. It holds only the escrows, plus whatever
///        strangers send it, which nothing may take (as in `MintRequests`).
///      - Every amount is measured where it lands:
///        - a deposit or a redeem credits the balance increase it caused;
///        - a buy credits what the engine measured as delivered;
///        - a sale debits what it gave the router, and credits back what the sweep returned.
///        So for every token, the builder's balance covers the sum of the escrows, whatever the token does on
///        transfer.
///      - Every swap runs through {UniversalRouterSwaps}, the engine shared with the zap. Its notes cover the pre-fund
///        and sweep, the spend bound, hookless V4 routes and hop-by-hop V3 sales.
///      - A buy is sized by the index's `previewIssue` at the call, minus what the escrow already holds. So a buy
///        repeated after a rebalance buys only what the new units add. A stale quote still reverts
///        `StaleRebalanceNonce`, since its routes and limits were chosen for the old basket.
///      - The mint pulls exactly `previewIssue(shares)` of each component from the escrow. The builder debits that
///        first, and approves the index for exactly that much. If a rebalance between the buys and the mint leaves a
///        leg short, the error names it, and one more buy completes it.
///      - The builder never calls `redeemSkipping` (a claim booked to it could not be collected) or
///        `executeRebalance` (it fills no auction).
///      - Every entry point shares the reentrancy guard, and state is written before any token leaves.
contract BasketBuilder is ReentrancyGuard, UniversalRouterSwaps, IBasketBuilder {
    using SafeERC20 for IERC20;

    /// @inheritdoc IBasketBuilder
    IIndexFactory public immutable FACTORY;

    /// @inheritdoc IBasketBuilder
    mapping(address user => mapping(address token => uint256 amount)) public escrowOf;

    constructor(IIndexFactory factory, IUniversalRouter router) UniversalRouterSwaps(router) {
        if (address(factory) == address(0)) revert ZeroAddress();
        FACTORY = factory;
    }

    // ---------------------------------------------------------------------
    // Escrow
    // ---------------------------------------------------------------------

    /// @inheritdoc IBasketBuilder
    function deposit(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 received = _pull(IERC20(token), amount);
        escrowOf[msg.sender][token] += received;
        _checkCanSendOut(IERC20(token));
        // Safe under the guard; the amount is only known once the token has answered.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Deposited(msg.sender, token, received);
    }

    /// @inheritdoc IBasketBuilder
    function withdraw(address token, uint256 amount, address to) external nonReentrant {
        _checkRecipient(to);
        uint256 held = escrowOf[msg.sender][token];
        if (amount == 0) amount = held;
        if (amount == 0) revert ZeroAmount();
        if (held < amount) revert InsufficientEscrow(token, held, amount);
        escrowOf[msg.sender][token] = held - amount;
        emit Withdrawn(msg.sender, token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------------
    // Buying and minting
    // ---------------------------------------------------------------------

    /// @inheritdoc IBasketBuilder
    function buy(BuyParams calldata p) external nonReentrant returns (uint256 amountSpent) {
        _checkIndex(p.index, p.expectedNonce, p.deadline);
        if (p.tokenIn == address(0)) revert ZeroAddress();
        if (p.shares == 0 || p.maxAmountIn == 0) revert ZeroAmount();
        if (p.legs.length != p.components.length) revert LengthMismatch();

        IERC20 tokenIn = IERC20(p.tokenIn);
        uint256 balanceBefore = tokenIn.balanceOf(address(this));
        uint256 received = _pull(tokenIn, p.maxAmountIn);
        if (received < p.maxAmountIn) revert TransferShortfall(p.tokenIn);
        uint256 reserved = _buyLegs(p);

        // Refund this call's tokenIn that the swaps did not take, except the part the basket itself holds, now in the
        // escrow. A balance the router already held arrives through the sweep and enlarges the refund; it cannot
        // underflow it.
        uint256 refund = Math.saturatingSub(tokenIn.balanceOf(address(this)) - balanceBefore, reserved);
        amountSpent = Math.saturatingSub(received, refund);
        // Safe under the guard; the amount is only known after the swaps.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Bought(msg.sender, p.index, p.tokenIn, amountSpent, p.shares);
        if (refund != 0) tokenIn.safeTransfer(msg.sender, refund);
    }

    /// @dev Buys each named leg up to what the basket still needs beyond the escrow, and credits the escrow. Returns
    ///      the amount of `tokenIn` the basket itself needs, which is kept out of the refund. Errors name a leg by its
    ///      position in the call.
    function _buyLegs(BuyParams calldata p) private returns (uint256 reserved) {
        address[] memory tokens = IIndexHub(p.index).componentTokens();
        uint256[] memory need = IIndexHub(p.index).previewIssue(p.shares);
        uint256 spent = 0;
        for (uint256 k = 0; k < p.legs.length; ++k) {
            (address component, uint256 amountOut) = _stillNeeded(p, tokens, need, k);
            if (amountOut == 0) continue;
            spent += _buyLeg(p, component, amountOut, p.maxAmountIn - spent, k);
            if (component == p.tokenIn) reserved += amountOut;
            escrowOf[msg.sender][component] += amountOut;
            _checkCanSendOut(IERC20(component));
        }
        return reserved;
    }

    /// @dev Leg `k`'s component, and how much more of it the basket needs beyond the escrow (zero if the escrow
    ///      already covers it).
    function _stillNeeded(BuyParams calldata p, address[] memory tokens, uint256[] memory need, uint256 k)
        private
        view
        returns (address component, uint256 amountOut)
    {
        uint256 i = p.components[k];
        if (i >= tokens.length) revert ComponentOutOfRange(i);
        component = tokens[i];
        uint256 held = escrowOf[msg.sender][component];
        amountOut = held < need[i] ? need[i] - held : 0;
    }

    /// @dev Buys `amountOut` of `component` for leg `k`, within `budget` and the leg's own cap, and returns the cost.
    ///      If the component is `tokenIn` itself, nothing is swapped: the amount is checked against both limits and
    ///      kept.
    function _buyLeg(BuyParams calldata p, address component, uint256 amountOut, uint256 budget, uint256 k)
        private
        returns (uint256 cost)
    {
        MintLeg calldata leg = p.legs[k];
        uint256 legCap = leg.maxAmountIn;
        if (component == p.tokenIn) {
            if (leg.v3Path.length != 0 || leg.v4Path.length != 0) revert BadRoute(k);
            // The pass-through leg carries no swap, but still honours its own limit and the overall one (DA-15).
            if (legCap != 0 && amountOut > legCap) revert InsufficientBudget(amountOut, legCap);
            if (amountOut > budget) revert InsufficientBudget(amountOut, budget);
            return amountOut;
        }
        uint256 cap = legCap != 0 && legCap < budget ? legCap : budget;
        return _buy(p.tokenIn, component, amountOut, cap, leg, k);
    }

    /// @inheritdoc IBasketBuilder
    function mint(address index, uint256 shares, address to, address referrer, uint256 deadline) external nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        // The three calls before the escrow is debited are views, by STATICCALL: nothing they reach can re-enter.
        // aderyn-fp-next-line(reentrancy-state-change)
        if (!FACTORY.isIndex(index)) revert NotIndex(index);
        _checkRecipient(to);
        if (shares == 0) revert ZeroAmount();

        // aderyn-fp-next-line(reentrancy-state-change)
        address[] memory tokens = IIndexHub(index).componentTokens();
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256[] memory need = IIndexHub(index).previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 held = escrowOf[msg.sender][tokens[i]];
            if (held < need[i]) revert InsufficientEscrow(tokens[i], held, need[i]);
            escrowOf[msg.sender][tokens[i]] = held - need[i];
            IERC20(tokens[i]).forceApprove(index, need[i]);
        }
        emit Minted(msg.sender, index, to, shares);
        IIndexHub(index).issue(shares, to, referrer);
    }

    // ---------------------------------------------------------------------
    // Redeeming and selling
    // ---------------------------------------------------------------------

    /// @inheritdoc IBasketBuilder
    function redeem(address index, uint256 shares) external nonReentrant {
        // The escrow is credited from what the redeem delivered, so every call here comes before the write: views by
        // STATICCALL, and the redeem itself, under the guard.
        // aderyn-fp-next-line(reentrancy-state-change)
        if (!FACTORY.isIndex(index)) revert NotIndex(index);
        if (shares == 0) revert ZeroAmount();
        // aderyn-fp-next-line(reentrancy-state-change)
        address[] memory tokens = IIndexHub(index).componentTokens();
        uint256 n = tokens.length;
        uint256[] memory before = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            // aderyn-fp-next-line(reentrancy-state-change)
            before[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
        IERC20(index).safeTransferFrom(msg.sender, address(this), shares);
        // The basket must arrive before it can be credited, so this cannot be the last interaction. It is safe: the
        // function is nonReentrant. Wake's reentrancy detector does not model the guard.
        // wake-disable-next-line reentrancy
        IIndexHub(index).redeem(shares, address(this)); // aderyn-fp(reentrancy-state-change)
        for (uint256 i = 0; i < n; ++i) {
            // A view under the guard, after the previous leg's probe. A failed probe reverts every credit.
            // aderyn-fp-next-line(reentrancy-state-change)
            uint256 got = IERC20(tokens[i]).balanceOf(address(this)) - before[i];
            if (got == 0) continue;
            escrowOf[msg.sender][tokens[i]] += got;
            _checkCanSendOut(IERC20(tokens[i]));
        }
        // Safe under the guard; the escrow is credited from what arrived.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, index, shares);
    }

    /// @inheritdoc IBasketBuilder
    function sell(SellParams calldata p) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > p.deadline) revert Expired();
        _checkRecipient(p.to);
        if (p.tokenOut == address(0)) revert ZeroAddress();
        if (p.minAmountOut == 0) revert ZeroAmount();
        if (p.legs.length != p.tokens.length || p.amounts.length != p.tokens.length) revert LengthMismatch();

        IERC20 tokenOut = IERC20(p.tokenOut);
        uint256 outBefore = tokenOut.balanceOf(address(this));
        uint256 passedThrough = _sellLegs(p);
        amountOut = tokenOut.balanceOf(address(this)) - outBefore + passedThrough;
        if (amountOut < p.minAmountOut) revert InsufficientOutput(amountOut, p.minAmountOut);

        // Safe under the guard; the amount is only known after the swaps.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Sold(msg.sender, p.to, p.tokenOut, amountOut);
        uint256 paidBefore = tokenOut.balanceOf(p.to);
        tokenOut.safeTransfer(p.to, amountOut);
        // Reject a fee-on-transfer payout: it would leave the recipient short of what this call reported paying.
        if (tokenOut.balanceOf(p.to) - paidBefore < amountOut) revert TransferShortfall(p.tokenOut);
    }

    /// @dev Debits each named leg from the escrow and sells it. A leg that is already `tokenOut` passes through and is
    ///      counted toward the payout. The proceeds stay here for {sell} to measure. Errors name a leg by its position
    ///      in the call.
    function _sellLegs(SellParams calldata p) private returns (uint256 passedThrough) {
        bytes memory ctx = abi.encode(msg.sender);
        for (uint256 k = 0; k < p.legs.length; ++k) {
            address token = p.tokens[k];
            uint256 held = escrowOf[msg.sender][token];
            uint256 amount = p.amounts[k] == 0 ? held : p.amounts[k];
            if (amount == 0) revert ZeroAmount();
            if (held < amount) revert InsufficientEscrow(token, held, amount);
            escrowOf[msg.sender][token] = held - amount;
            if (token == p.tokenOut) {
                if (p.legs[k].v3Path.length != 0 || p.legs[k].v4Path.length != 0) revert BadRoute(k);
                // The pass-through leg carries no swap, but its limit is still checked, as for every leg (DA-15).
                if (amount < p.legs[k].minAmountOut) revert InsufficientOutput(amount, p.legs[k].minAmountOut);
                passedThrough += amount;
                continue;
            }
            _sell(p.tokenOut, token, amount, p.legs[k], k, ctx);
        }
        return passedThrough;
    }

    /// @dev Credits what a hop did not sell (plus any balance of it the router already held) back to the seller's
    ///      escrow.
    function _onUnsold(address token, uint256 amount, bytes memory ctx) internal override {
        address user = abi.decode(ctx, (address));
        escrowOf[user][token] += amount;
        // forge-lint: disable-next-line(reentrancy-events)
        emit Unsold(user, token, amount);
    }

    // ---------------------------------------------------------------------
    // Checks
    // ---------------------------------------------------------------------

    /// @dev Pulls `amount` of `token` from the caller and returns what actually arrived. A fee-on-transfer token
    ///      delivers less: a deposit credits what arrived, and a buy refuses the shortfall.
    function _pull(IERC20 token, uint256 amount) private returns (uint256 received) {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - before;
    }

    /// @dev Checks that the builder can still send `token` out, by sending itself one raw unit. Called whenever an
    ///      escrow of `token` is credited; the credit is written first, and a failed probe reverts the whole call.
    ///      - Why: a token can let tokens in but block the builder from sending, e.g. after its issuer blacklists the
    ///        builder or pauses. Tether's blacklist checks only the sender, so deposits, sweeps and redeems still land.
    ///        An escrow nobody could withdraw, sell or mint would be trapped (XS-10, as SA-01 in `MintRequests`).
    ///      - One unit, not zero: a token need not accept a zero transfer.
    ///      - The probe is measured like every other movement. A token whose self-transfer costs the builder anything
    ///        is refused, so the builder's balance still covers the escrows.
    function _checkCanSendOut(IERC20 token) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransfer(address(this), 1);
        if (token.balanceOf(address(this)) < before) revert TransferShortfall(address(token));
    }

    /// @dev Reverts after `deadline`, for an address the factory did not deploy, or if a rebalance settled since the
    ///      caller's quote.
    function _checkIndex(address index, uint256 expectedNonce, uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (!FACTORY.isIndex(index)) revert NotIndex(index);
        uint256 nonce = IIndexHub(index).rebalanceNonce();
        if (nonce != expectedNonce) revert StaleRebalanceNonce(expectedNonce, nonce);
    }

    /// @dev Refuses a recipient that would lose what it is sent: anyone can sweep tokens left in the router, anything
    ///      sent to the pool manager is a donation, and the factory and an index can never move a token they receive
    ///      (RT-21).
    function _checkRecipient(address to) private view {
        if (to == address(0)) revert ZeroAddress();
        if (
            to == address(this) || to == address(ROUTER) || to == POOL_MANAGER || to == address(FACTORY)
                || FACTORY.isIndex(to)
        ) revert InvalidRecipient(to);
    }
}
