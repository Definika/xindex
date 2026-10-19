// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMintRequests} from "./interfaces/IMintRequests.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";

/// @title MintRequests
/// @notice Escrowed requests to mint or redeem an index's shares for USDC or USDT.
///         - Mint: a stablecoin holder who cannot assemble a basket asks for shares at their own limit. Anyone who
///           holds shares, or can issue them in kind, fills the request and takes the stablecoins.
///         - Redeem: the mirror image.
///         Nothing here reads a price. The requester's limit is the only valuation; the app suggests it.
/// @dev - No owner, no upgrade, nothing to configure. Every entry point shares one reentrancy guard.
///      - The contract holds only open escrows. Each is measured as the balance increase its request caused, so a USDT
///        fee switched on at any time can never leave the last refund short.
///      - Stray tokens sent here stay here.
///      - A request is closed before any token moves. Fillers pay requesters directly. The contract never calls
///        `approve`.
contract MintRequests is IMintRequests, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @inheritdoc IMintRequests
    uint256 public constant MAX_REQUEST_DURATION = 30 days;

    /// @inheritdoc IMintRequests
    address public immutable FACTORY;
    /// @inheritdoc IMintRequests
    address public immutable USDC;
    /// @inheritdoc IMintRequests
    address public immutable USDT;

    /// @inheritdoc IMintRequests
    uint256 public requestCount;

    mapping(uint256 id => Request) private _requests;

    constructor(address factory, address usdc, address usdt) {
        if (factory == address(0) || usdc == address(0) || usdt == address(0)) revert ZeroAddress();
        if (usdc == usdt) revert NotAStable(usdt);
        FACTORY = factory;
        USDC = usdc;
        USDT = usdt;
    }

    // ---------------------------------------------------------------------
    // Requests
    // ---------------------------------------------------------------------

    /// @inheritdoc IMintRequests
    function requestMint(address index, address stable, uint256 amount, uint256 minShares, uint256 deadline)
        external
        nonReentrant
        returns (uint256 id)
    {
        _checkRequest(index, stable, amount, minShares, deadline);
        // Check that this contract can still send `stable` out, by sending itself nothing. Tether's `transferFrom`
        // checks only the sender, so a blacklisted contract would still receive an escrow that `cancel`, `refund` and
        // every fill could never pay out. The self-transfer fails when blacklisted or paused, so the deposit is
        // refused instead of trapped (SA-01).
        IERC20(stable).safeTransfer(address(this), 0);
        uint256 escrow = _pull(stable, amount);
        id = _openRequest(true, index, stable, escrow, minShares, deadline);
        emit MintRequested(id, msg.sender, index, stable, escrow, minShares, deadline);
    }

    /// @inheritdoc IMintRequests
    function requestRedeem(address index, uint256 shares, address stable, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 id)
    {
        _checkRequest(index, stable, shares, minOut, deadline);
        uint256 escrow = _pull(index, shares);
        id = _openRequest(false, index, stable, escrow, minOut, deadline);
        emit RedeemRequested(id, msg.sender, index, stable, escrow, minOut, deadline);
    }

    /// @inheritdoc IMintRequests
    function fill(uint256 id, uint256 amount) external nonReentrant {
        Request storage request = _requests[id];
        if (!request.open) revert RequestNotOpen(id);
        uint256 deadline = request.deadline;
        if (block.timestamp > deadline) revert RequestExpired(id, deadline);
        request.open = false;

        address requester = request.requester;
        (address delivered, address paid) =
            request.isMint ? (request.index, request.stable) : (request.stable, request.index);
        // Measure what the requester actually received, so a transfer fee cannot push it below their limit.
        uint256 before = IERC20(delivered).balanceOf(requester);
        IERC20(delivered).safeTransferFrom(msg.sender, requester, amount);
        uint256 balance = IERC20(delivered).balanceOf(requester);
        // A self-fill under a transfer fee lowers the balance: that is nothing received, not an underflow (RX-54).
        uint256 received = balance > before ? balance - before : 0;
        if (received < request.limit) revert BelowLimit(received, request.limit);
        emit RequestFilled(id, msg.sender, received);

        IERC20(paid).safeTransfer(msg.sender, request.escrow);
    }

    /// @inheritdoc IMintRequests
    function cancel(uint256 id) external nonReentrant {
        Request storage request = _requests[id];
        if (!request.open) revert RequestNotOpen(id);
        if (msg.sender != request.requester) revert Unauthorized(msg.sender);
        request.open = false;
        emit RequestCancelled(id);
        _refundEscrow(request);
    }

    /// @inheritdoc IMintRequests
    function refund(uint256 id) external nonReentrant {
        Request storage request = _requests[id];
        if (!request.open) revert RequestNotOpen(id);
        uint256 deadline = request.deadline;
        if (block.timestamp <= deadline) revert RequestNotExpired(id, deadline);
        request.open = false;
        emit RequestRefunded(id, msg.sender);
        _refundEscrow(request);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Checks a new request: a factory index, USDC or USDT, non-zero amounts, and a deadline in the future but at
    ///      most MAX_REQUEST_DURATION away.
    function _checkRequest(address index, address stable, uint256 amount, uint256 limit, uint256 deadline)
        private
        view
    {
        if (!IIndexFactory(FACTORY).isIndex(index)) revert NotIndex(index);
        if (stable != USDC && stable != USDT) revert NotAStable(stable);
        if (amount == 0 || limit == 0) revert ZeroAmount();
        if (deadline <= block.timestamp || deadline > block.timestamp + MAX_REQUEST_DURATION) {
            revert InvalidDeadline(deadline);
        }
    }

    /// @dev Takes `amount` of `token` from the caller and returns what actually arrived. Reverts if nothing arrived.
    function _pull(address token, uint256 amount) private returns (uint256 escrow) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        escrow = IERC20(token).balanceOf(address(this)) - before;
        if (escrow == 0) revert NothingEscrowed();
    }

    /// @dev Stores a new open request from the caller and returns its id.
    function _openRequest(bool isMint, address index, address stable, uint256 escrow, uint256 limit, uint256 deadline)
        private
        returns (uint256 id)
    {
        id = ++requestCount;
        _requests[id] = Request({
            requester: msg.sender,
            deadline: SafeCast.toUint40(deadline),
            isMint: isMint,
            open: true,
            index: index,
            stable: stable,
            escrow: escrow,
            limit: limit
        });
    }

    /// @dev Sends a closed request's escrow back to its requester.
    function _refundEscrow(Request storage request) private {
        IERC20(request.isMint ? request.stable : request.index).safeTransfer(request.requester, request.escrow);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IMintRequests
    function getRequest(uint256 id) external view returns (Request memory) {
        return _requests[id];
    }
}
