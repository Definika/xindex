// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IXindexErrors} from "./IXindexErrors.sol";

/// @notice Escrowed requests to mint or redeem an index's shares for USDC or USDT. Anyone who holds the other side can
///         fill one. A requester names their own limit; nothing reads a price. The contract has no owner and nothing
///         to configure. Every escrow leaves with its request, unless the stablecoin's issuer freezes or destroys it,
///         and after a destruction no new request is taken in that token until the open ones are covered again.
///         Tokens sent here outside a request stay here.
interface IMintRequests is IXindexErrors {
    /// @notice A request.
    ///         - `escrow`: what the contract holds for it, measured as the balance increase when it was made. In
    ///           `stable` for a mint, in `index` shares for a redemption.
    ///         - `limit`: the least the requester must receive. In shares for a mint, in `stable` for a redemption.
    ///         - `rebalanceNonce`: the index's `rebalanceNonce` when the request was made. A settlement changes what a
    ///           share is backed by, so the request can be filled only while the index still reads this value.
    struct Request {
        address requester;
        uint40 deadline;
        bool isMint;
        bool open;
        uint40 rebalanceNonce;
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
    /// @notice Request `id` is open, but it is not the request the filler priced: its terms differ.
    error RequestChanged(uint256 id);

    /// @notice The longest a request may stay fillable: 30 days.
    function MAX_REQUEST_DURATION() external view returns (uint256);

    /// @notice The factory whose indexes requests may name.
    function FACTORY() external view returns (address);

    /// @notice USDC, one of the two stablecoins a request may name.
    function USDC() external view returns (address);

    /// @notice USDT, the other.
    function USDT() external view returns (address);

    /// @notice The sum of the open requests' escrows in `token`: a stablecoin's for mint requests, an index's shares
    ///         for redeem requests. The contract's balance of `token` covers it unless the token's issuer took some
    ///         away, and while it does not, no new request escrows `token` (Underbacked, CA-H2).
    function totalEscrow(address token) external view returns (uint256);

    /// @notice Number of requests ever made, which is the last one's id; ids start at 1.
    function requestCount() external view returns (uint256);

    /// @notice Request `id`; all zero for one never made.
    function getRequest(uint256 id) external view returns (Request memory);

    /// @notice The hash of request `id` as {getRequest} returns it: `keccak256(abi.encode(request))`, nine 32-byte
    ///         words, not packed. A filler computes it from the very request it priced: the struct it read, or for a
    ///         request still pending its terms, with `open` true and the index's current `rebalanceNonce`. Reading
    ///         this view by id in another call, or at another block, proves nothing: it hashes whatever then sits
    ///         behind the id.
    function requestHash(uint256 id) external view returns (bytes32);

    /// @notice Escrows `amount` of `stable` (USDC or USDT) from the caller, for at least `minShares` shares of the
    ///         factory index `index`, fillable until `deadline`. The escrow is the balance increase this transfer
    ///         caused: less than `amount` if USDT charges a fee. Needs an allowance of `amount` on `stable`.
    ///         Reverts Underbacked while the contract holds less of `stable` than its open requests escrowed, as
    ///         after the issuer destroyed part of it: the deposit would pay those requests (CA-H2).
    ///         The request records the index's `rebalanceNonce` when this call lands, which may not be the one the
    ///         caller set `minShares` at: a caller that priced a basket uses the bound overload below.
    /// @return id The new request's id.
    function requestMint(address index, address stable, uint256 amount, uint256 minShares, uint256 deadline)
        external
        returns (uint256 id);

    /// @notice As {requestMint}, and only while `index` still reads `expectedNonce`, the `rebalanceNonce` the caller
    ///         set its limit at. A settlement between the caller's quote and this call changed what a share is
    ///         backed by, and the request would open on the new basket at the old limit: it reverts
    ///         StaleRebalanceNonce instead, before anything is escrowed (CA-M1).
    function requestMint(
        address index,
        address stable,
        uint256 amount,
        uint256 minShares,
        uint256 deadline,
        uint256 expectedNonce
    ) external returns (uint256 id);

    /// @notice Escrows `shares` of the factory index `index` from the caller, for at least `minOut` of `stable`
    ///         (USDC or USDT), fillable until `deadline`. Needs an allowance of `shares` on `index`.
    /// @return id The new request's id.
    function requestRedeem(address index, uint256 shares, address stable, uint256 minOut, uint256 deadline)
        external
        returns (uint256 id);

    /// @notice As {requestRedeem}, and only while `index` still reads `expectedNonce`, as the bound {requestMint}
    ///         (CA-M1).
    function requestRedeem(
        address index,
        uint256 shares,
        address stable,
        uint256 minOut,
        uint256 deadline,
        uint256 expectedNonce
    ) external returns (uint256 id);

    /// @notice Anyone, until the deadline. Fills request `id`, whichever request that id names when the call lands.
    ///         An id is only a counter: after a re-org, or for a request that was still pending when the caller
    ///         priced it, it may name another request. A caller that has not read the request in this same
    ///         transaction uses the bound {fill} below.
    ///         - Mint: sends `amount` shares of the index from the caller to the requester, and pays the caller the
    ///           escrowed stablecoin.
    ///         - Redemption: sends `amount` of the stablecoin from the caller to the requester, and pays the caller the
    ///           escrowed shares.
    ///         The requester must receive at least the request's limit, after any fee. The request is closed before
    ///         any token moves. Needs the caller's allowance of `amount` on what it sends.
    ///         Reverts StaleRebalanceNonce if the index rebalanced since the request was made. Its limit and its
    ///         escrow were set for the old basket, so the requester cancels it and asks again.
    function fill(uint256 id, uint256 amount) external;

    /// @notice As {fill}, and only if request `id` is still exactly the one the caller priced: `expected` is its hash
    ///         ({requestHash}), and the fill reverts RequestChanged otherwise. So a filler never delivers against
    ///         another request's escrow, kind, index or stablecoin.
    function fill(uint256 id, uint256 amount, bytes32 expected) external;

    /// @notice The requester only, at any time while the request is open: closes it and returns the escrow.
    function cancel(uint256 id) external;

    /// @notice Anyone, after the deadline: closes an open request and returns the escrow to its requester.
    function refund(uint256 id) external;
}
