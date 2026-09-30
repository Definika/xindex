// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IXindexErrors} from "./IXindexErrors.sol";

/// @notice Escrowed requests to mint or redeem an index's shares for USDC or USDT, filled by anyone who holds the other
///         side. A requester names their own limit; nothing reads a price. The contract has no owner and nothing to
///         configure. Every escrow leaves with its request, unless the stablecoin's issuer freezes or destroys it;
///         tokens sent here outside a request stay here.
interface IMintRequests is IXindexErrors {
    /// @notice A request: `escrow` is what the contract holds for it, measured as the balance increase when it was
    ///         made, in `stable` for a mint and in `index` shares for a redemption; `limit` is the least the requester
    ///         must receive, in shares for a mint and in `stable` for a redemption.
    struct Request {
        address requester;
        uint40 deadline;
        bool isMint;
        bool open;
        address index;
        address stable;
        uint256 escrow;
        uint256 limit;
    }

    /// @notice `requester` escrowed `escrow` of `stable` for at least `minShares` shares of `index`, fillable until
    ///         `deadline`.
    event MintRequested(
        uint256 indexed id,
        address indexed requester,
        address indexed index,
        address stable,
        uint256 escrow,
        uint256 minShares,
        uint256 deadline
    );
    /// @notice `requester` escrowed `escrow` shares of `index` for at least `minOut` of `stable`, fillable until
    ///         `deadline`.
    event RedeemRequested(
        uint256 indexed id,
        address indexed requester,
        address indexed index,
        address stable,
        uint256 escrow,
        uint256 minOut,
        uint256 deadline
    );
    /// @notice `filler` delivered `delivered` to the requester, measured at the requester, and took the escrow.
    event RequestFilled(uint256 indexed id, address indexed filler, uint256 delivered);
    /// @notice The requester closed the request; its escrow went back to them.
    event RequestCancelled(uint256 indexed id);
    /// @notice `caller` returned the escrow of a request whose deadline had passed.
    event RequestRefunded(uint256 indexed id, address indexed caller);

    /// @notice `token` is neither of the two stablecoins.
    error NotAStable(address token);
    /// @notice An amount or a limit is zero.
    error ZeroAmount();
    /// @notice `deadline` is not after now, or more than MAX_REQUEST_DURATION away.
    error InvalidDeadline(uint256 deadline);
    /// @notice The transfer into escrow left the contract's balance unchanged.
    error NothingEscrowed();
    /// @notice Request `id` does not exist, or was filled, cancelled or refunded.
    error RequestNotOpen(uint256 id);
    /// @notice Request `id` can no longer be filled; its deadline passed.
    error RequestExpired(uint256 id, uint256 deadline);
    /// @notice Request `id` cannot be refunded before its deadline; its requester can cancel it.
    error RequestNotExpired(uint256 id, uint256 deadline);
    /// @notice The requester received `delivered`, less than their `limit`.
    error BelowLimit(uint256 delivered, uint256 limit);

    /// @notice The longest a request may stay fillable: 30 days.
    function MAX_REQUEST_DURATION() external view returns (uint256);

    /// @notice The factory whose indexes requests may name.
    function FACTORY() external view returns (address);

    /// @notice USDC, one of the two stablecoins a request may name.
    function USDC() external view returns (address);

    /// @notice USDT, the other.
    function USDT() external view returns (address);

    /// @notice Number of requests ever made, which is the last one's id; ids start at 1.
    function requestCount() external view returns (uint256);

    /// @notice Request `id`; all zero for one never made.
    function getRequest(uint256 id) external view returns (Request memory);

    /// @notice Escrows `amount` of `stable` (USDC or USDT) from the caller for at least `minShares` shares of `index`,
    ///         a factory index, fillable until `deadline`. The escrow is the balance increase this transfer caused,
    ///         which is less than `amount` when USDT charges a fee. Needs an allowance of `amount` on `stable`.
    /// @return id The new request's id.
    function requestMint(address index, address stable, uint256 amount, uint256 minShares, uint256 deadline)
        external
        returns (uint256 id);

    /// @notice Escrows `shares` of `index`, a factory index, from the caller for at least `minOut` of `stable`
    ///         (USDC or USDT), fillable until `deadline`. Needs an allowance of `shares` on `index`.
    /// @return id The new request's id.
    function requestRedeem(address index, uint256 shares, address stable, uint256 minOut, uint256 deadline)
        external
        returns (uint256 id);

    /// @notice Anyone, before the deadline. For a mint, sends `amount` shares of the index from the caller to the
    ///         requester, who must receive at least the request's limit, and pays the caller the escrowed stablecoin.
    ///         For a redemption, sends `amount` of the stablecoin from the caller to the requester, who must receive at
    ///         least the limit after any fee, and pays the caller the escrowed shares. The request is closed before
    ///         any token moves. Needs the caller's allowance of `amount` on what it sends.
    function fill(uint256 id, uint256 amount) external;

    /// @notice The requester only, at any time while the request is open: closes it and returns the escrow.
    function cancel(uint256 id) external;

    /// @notice Anyone, after the deadline: closes an open request and returns the escrow to its requester.
    function refund(uint256 id) external;
}
