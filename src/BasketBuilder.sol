// SPDX-License-Identifier: BUSL-1.1
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
///      - A buy pays and a sale is paid in the builder's `USDC` or `USDT`, and nothing else, as at the zap. A deposit and a withdrawal take any token: they move legs in kind, not a payment.
///      - Every amount is measured where it lands:
///        - a deposit or a redeem credits the balance increase it caused;
///        - a buy credits what the basket needs, once the engine has measured at least that much delivered
///          (`ShortFill` otherwise); anything a route delivers beyond it stays here, in no escrow;
///        - a sale debits what it gave the router, and credits back what the sweep returned.
///        So for every token, the builder's balance covers the sum of the escrows (`totalEscrow`), whatever the token
///        does on transfer. Only the token's issuer can break that, by taking part of the balance away; while it is
///        broken, nothing new is credited in that token (`Underbacked`), since the deposit would pay the earlier
///        escrows, as an issue into an underbacked leg of an index would (CA-H2, RX-8 in the hub). Withdrawals and
///        sales of what is left go on, first come first served. This assumes one balance behind one address. A swap measured against a balance two addresses
///        share is refused (`SharedBalance`), but a redeem of an index naming both addresses would be credited
///        twice, so such a token is never listed.
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
    address public immutable USDC;
    /// @inheritdoc IBasketBuilder
    address public immutable USDT;

    /// @inheritdoc IBasketBuilder
    mapping(address user => mapping(address token => uint256 amount)) public escrowOf;

    /// @inheritdoc IBasketBuilder
    mapping(address token => uint256 amount) public totalEscrow;

    constructor(IIndexFactory factory, IUniversalRouter router, LocalVenue memory local, address usdc, address usdt)
        UniversalRouterSwaps(router, local)
    {
        if (address(factory) == address(0) || usdc == address(0) || usdt == address(0)) {
            revert ZeroAddress();
        }
        if (usdc == usdt) revert NotAStable(usdt);
        FACTORY = factory;
        USDC = usdc;
        USDT = usdt;
    }

    // ---------------------------------------------------------------------
    // Escrow
    // ---------------------------------------------------------------------

    /// @inheritdoc IBasketBuilder
    function deposit(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 received = _pull(IERC20(token), amount);
        // A transfer that delivered nothing would record a deposit of nothing (CA-R2-16).
        if (received == 0) revert TransferShortfall(token);
        _credit(msg.sender, token, received);
        _checkCanSendOut(IERC20(token));
        // Safe under the guard; the amount is only known once the token has answered.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Deposited(msg.sender, token, received);
    }

    /// @inheritdoc IBasketBuilder
    function withdraw(address token, uint256 amount, address to) external nonReentrant {
        _checkRecipient(to);
        // Nor the token's own contract, which would keep it, as the zap refuses for a payout (RY-1, CA-R2-15).
        if (to == token) revert InvalidRecipient(to);
        uint256 held = escrowOf[msg.sender][token];
        if (amount == 0) amount = held;
        if (amount == 0) revert ZeroAmount();
        _debit(token, held, amount);
        emit Withdrawn(msg.sender, token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------------
    // Buying and minting
    // ---------------------------------------------------------------------

    /// @inheritdoc IBasketBuilder
    function buy(BuyParams calldata p) external nonReentrant returns (uint256 amountSpent) {
        _checkIndex(p.index, p.expectedNonce, p.deadline);
        _checkStable(p.tokenIn);
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
        // The pass-through leg was credited while this call's unspent `tokenIn` still stood in the balance, which
        // could hide a shortfall from the check made then. It is made again here, once the refund has left (CA-H2).
        if (reserved != 0) _checkBacked(tokenIn, tokenIn.balanceOf(address(this)));
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
            _credit(msg.sender, component, amountOut);
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
            if (_namesRoute(leg.v3Path, leg.v4Path, leg.localRoute)) revert BadRoute(k);
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
            _debit(tokens[i], escrowOf[msg.sender][tokens[i]], need[i]);
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
            _credit(msg.sender, tokens[i], got);
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
        _checkStable(p.tokenOut);
        // The payout cannot go to `tokenOut`'s own contract, which would keep it (RY-1, CA-R2-15).
        if (p.to == p.tokenOut) revert InvalidRecipient(p.to);
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
            _debit(token, held, amount);
            if (token == p.tokenOut) {
                if (_namesRoute(p.legs[k].v3Path, p.legs[k].v4Path, p.legs[k].localRoute)) revert BadRoute(k);
                // The pass-through leg carries no swap, but its limit is still checked, as for every leg (DA-15).
                if (amount < p.legs[k].minAmountOut) revert InsufficientOutput(amount, p.legs[k].minAmountOut);
                passedThrough += amount;
                continue;
            }
            _sell(p.tokenOut, token, amount, p.legs[k], k, ctx);
        }
        return passedThrough;
    }

    /// @dev Credits what a hop did not sell, plus any balance of it the router already held, back to the seller's
    ///      escrow.
    function _onUnsold(address token, uint256 unsold, uint256 stray, bytes memory ctx) internal override {
        address user = abi.decode(ctx, (address));
        uint256 amount = unsold + stray;
        // Back into the escrow it left in this same call, so no backing check: nothing new is taken in.
        _credit(user, token, amount);
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

    /// @dev Adds `amount` of `token` to `user`'s escrow and to the token's total.
    function _credit(address user, address token, uint256 amount) private {
        escrowOf[user][token] += amount;
        totalEscrow[token] += amount;
    }

    /// @dev Takes `amount` of `token` out of the caller's escrow, which holds `held` of it, and off the token's total.
    function _debit(address token, uint256 held, uint256 amount) private {
        if (held < amount) revert InsufficientEscrow(token, held, amount);
        escrowOf[msg.sender][token] = held - amount;
        totalEscrow[token] -= amount;
    }

    /// @dev Reverts unless `balance`, the builder's of `token`, covers every escrow of it. After the token's issuer
    ///      took part of the balance, a new credit would be paid out to the earlier escrows (CA-H2).
    function _checkBacked(IERC20 token, uint256 balance) private view {
        uint256 owed = totalEscrow[address(token)];
        if (balance < owed) revert Underbacked(address(token), balance, owed);
    }

    /// @dev Checks that the builder can still send `token` out, by sending itself one raw unit, and that its balance
    ///      covers every escrow of the token. Called whenever a deposit, a buy or a redeem credits an escrow of
    ///      `token`; the credit is written first, and a failed check reverts the whole call.
    ///      - Why: a token can let tokens in but block the builder from sending, e.g. after its issuer blacklists the
    ///        builder or pauses. Tether's blacklist checks only the sender, so deposits, sweeps and redeems still land.
    ///        An escrow nobody could withdraw, sell or mint would be trapped (XS-10, as SA-01 in `MintRequests`).
    ///      - One unit, not zero: a token need not accept a zero transfer.
    ///      - The probe is measured like every other movement. A token whose self-transfer costs the builder anything
    ///        is refused, so the builder's balance still covers the escrows.
    function _checkCanSendOut(IERC20 token) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransfer(address(this), 1);
        uint256 balance = token.balanceOf(address(this));
        if (balance < before) revert TransferShortfall(address(token));
        _checkBacked(token, balance);
    }

    /// @dev Reverts unless `token` is the builder's USDC or USDT, the only currencies a buy pays and a sale is paid in.
    function _checkStable(address token) private view {
        if (token != USDC && token != USDT) revert NotAStable(token);
    }

    /// @dev Reverts after `deadline`, for an address the factory did not deploy, or if a rebalance settled since the
    ///      caller's quote.
    function _checkIndex(address index, uint256 expectedNonce, uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (!FACTORY.isIndex(index)) revert NotIndex(index);
        uint256 nonce = IIndexHub(index).rebalanceNonce();
        if (nonce != expectedNonce) revert StaleRebalanceNonce(expectedNonce, nonce);
    }

    /// @dev Refuses a recipient that would lose what it is sent: anyone can sweep tokens left in either router, anything
    ///      sent to the pool manager is a donation, and the factory and an index can never move a token they receive
    ///      (RT-21).
    function _checkRecipient(address to) private view {
        if (to == address(0)) revert ZeroAddress();
        if (
            to == address(this) || to == address(ROUTER) || to == POOL_MANAGER || to == LOCAL_ROUTER
                || to == address(FACTORY) || FACTORY.isIndex(to)
        ) revert InvalidRecipient(to);
    }
}
