// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IWeightedHub} from "xindex/src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "xindex/src/interfaces/IWeightedIndexFactory.sol";
import {IMintRequests} from "xindex/src/interfaces/IMintRequests.sol";
import {IRebalanceExecutor} from "xindex/src/interfaces/IRebalanceExecutor.sol";
import {PathLib} from "xindex/src/libraries/PathLib.sol";
import {IV3SwapRouter} from "./interfaces/IV3SwapRouter.sol";
import {ITokenBridge} from "./interfaces/ITokenBridge.sol";

/// @title KeeperExecutor
/// @notice The keeper bot's executor for `WeightedHub` auctions and `MintRequests` requests. It sells what an index
///         sends out into USDC and buys what the index needs with USDC, through Uniswap V3 along the routes the bot
///         passes with each fill, and it serves a coin with no route from its own inventory: it delivers that coin
///         from stock and keeps that coin when the index sells it. A mint request is filled the same way, the basket
///         bought and issued to this contract and the shares delivered for the escrowed stablecoin; a redeem request
///         by paying the stablecoin, redeeming the escrowed shares here and selling the basket. Several requests on
///         one index are filled in one call ({fillBatch}): the shares the redeem requests escrowed go to the mint
///         requests, shares the executor holds as stock cover what they do not, and only the difference is issued
///         or redeemed, in one basket for the whole batch, so a small request does not pay for a basket of its own.
///         Every fill reverts
///         unless the USDC float ends at least `minUsdcDelta` above where it started, so a swap moved against the
///         bot's simulation cannot cost more than the bot accepted. A coin Ethereum has only as a Wormhole copy is
///         restocked through Wormhole's Token Bridge: the treasury bridges it in, what it bridges in is added to that
///         coin's stock allowance as far as the owner's restock allowance goes, and it bridges kept stock out to the
///         home-chain addresses the owner pinned.
/// @dev Three keys. The keeper, a hot key, only fills; the treasury, the restock service's hot key, only bridges stock
///      in and out and draws or repays USDC; and the owner, a cold key, withdraws, rotates the keeper, pins the
///      treasury and the home-chain recipients, and sets how much of each coin the keeper may still deliver from stock,
///      both directly and as restocked coins arrive. Anyone can create a factory index and hold all its shares, so a
///      fill can deliver to an index the keeper itself owns (CF-1): what bounds the stock a compromised keeper key can
///      move is that allowance, which every delivery from stock spends and only the owner raises, restocking included
///      (RS-1), not the factory check. The same key can trade the USDC float badly within the floor it sets. A stolen
///      treasury key can bridge stock only to the owner's pinned recipients and hold at most the owner's cap of USDC
///      off the float (RS-2), so the hot keys together can lose the working capital the owner handed the bot, and
///      nothing beyond it. The executor holds no role in the protocol: filling an auction is open to anyone.
contract KeeperExecutor is IRebalanceExecutor {
    /// @notice Uniswap's SwapRouter02.
    IV3SwapRouter public immutable ROUTER;
    /// @notice The float's currency, and the end of every route.
    address public immutable USDC;
    /// @notice The factory whose indexes this executor fills.
    IWeightedIndexFactory public immutable FACTORY;
    /// @notice The request escrow this executor fills, on the same factory.
    IMintRequests public immutable REQUESTS;
    /// @notice Wormhole's Token Bridge, through which the treasury restocks the coins Ethereum has only as its copies.
    ITokenBridge public immutable TOKEN_BRIDGE;
    /// @notice Withdraws and rotates the keeper.
    address public immutable OWNER;
    /// @notice The only account that fills.
    address public keeper;
    /// @notice How much of each coin the keeper may still deliver from stock, USDC aside, whose float the fill's floor
    ///         bounds. Only the owner sets it, and every delivery from stock spends it (CF-1). An index's own shares
    ///         are stock too: a batch that hands over more shares than it brings in spends the index's entry.
    mapping(address token => uint256 amount) public stockAllowance;
    /// @notice How much of the USDC float request fills may still turn into anything else: every request fill that
    ///         ends with less USDC than it started spends the difference. Nothing on chain checks a price, so a price
    ///         the bot got wrong, stale or forged, could otherwise spend the whole float (RX-1, RX-9). Only the owner
    ///         sets it.
    uint256 public requestUsdcAllowance;
    /// @notice The restock service's key, the only account that bridges stock and draws or repays USDC. The owner
    ///         sets it.
    address public treasury;
    /// @notice The most USDC the treasury may hold off the float, counting what it holds. Only the owner sets it.
    uint256 public treasuryUsdcCap;
    /// @notice The only recipient {bridgeOut} sends each coin to on each Wormhole chain, as the bridge encodes it: the
    ///         service's wallet on most chains, and on Solana, whose bridge pays a token account, the wallet's token
    ///         account for that coin. Only the owner sets it.
    mapping(uint16 chain => mapping(address token => bytes32 recipient)) public homeRecipient;
    /// @notice How much more of each coin arriving through the bridge may earn stock allowance: every credit spends it.
    ///         Only the owner sets it, so the stock a compromised keeper key can deliver stays within what the owner
    ///         allowed, restocking included (RS-1).
    mapping(address token => uint256 amount) public restockAllowance;
    /// @notice The USDC the treasury holds off the float: every draw adds to it, and every repayment takes off what
    ///         arrived, down to zero, so repaying more than was drawn raises nothing (RS-2).
    uint256 public treasuryUsdcOut;
    /// @dev The index being filled, for its callback only.
    address private transient _filling;

    /// @notice The keeper changed from `previous` to `next`.
    event KeeperSet(address indexed previous, address indexed next);
    /// @notice The keeper may now deliver up to `amount` of `token` from stock.
    event StockAllowanceSet(address indexed token, uint256 amount);
    /// @notice Request fills may now spend up to `amount` of the USDC float.
    event RequestUsdcAllowanceSet(uint256 amount);
    /// @notice The treasury changed from `previous` to `next`.
    event TreasurySet(address indexed previous, address indexed next);
    /// @notice The treasury may now hold up to `amount` of USDC off the float.
    event TreasuryUsdcAllowanceSet(uint256 amount);
    /// @notice {bridgeOut} now sends `token` to `recipient` on Wormhole chain `chain`.
    event HomeRecipientSet(uint16 indexed chain, address indexed token, bytes32 recipient);
    /// @notice `amount` of `token` arrived through the bridge, `credited` of it added to its stock allowance.
    event BridgedIn(address indexed token, uint256 amount, uint256 credited);
    /// @notice `amount` more of `token` arriving through the bridge may now earn stock allowance.
    event RestockAllowanceSet(address indexed token, uint256 amount);
    /// @notice `amount` of `token` left for `recipient` on Wormhole chain `chain`, as the bridge's message `sequence`.
    event BridgedOut(address indexed token, uint256 amount, uint16 indexed chain, bytes32 recipient, uint64 sequence);
    /// @notice The treasury drew `amount` of USDC from the float.
    event UsdcDrawn(uint256 amount);
    /// @notice The treasury repaid `amount` of USDC into the float.
    event UsdcRepaid(uint256 amount);

    /// @notice A request fill, for {fillMint} and {fillRedeem}.
    /// @param id The request.
    /// @param amount {fillMint}: the shares delivered; {fillRedeem}: the stablecoin paid.
    /// @param routes One per component of the request's index, as {fill}'s.
    /// @param legLimits Empty, or one per component, zero meaning no bound: {fillMint}'s most USDC a leg's purchase may
    ///        cost, {fillRedeem}'s least USDC a leg's sale must return. A pool pushed against the fill then stops it at
    ///        its own leg, before the rest of the basket trades (RX-10).
    /// @param stableRoute An exact-input path from the request's stablecoin to USDC; empty when that stablecoin is USDC.
    /// @param stableLimit Zero for no bound: {fillMint}'s least USDC the escrow's sale must return, {fillRedeem}'s most
    ///        USDC buying the stablecoin may cost.
    /// @param expectedNonce The index's rebalanceNonce the fill was simulated at: a settlement since then re-sizes the
    ///        basket, so the fill stops (RX-4).
    /// @param minUsdcDelta The least the USDC float may change by.
    /// @param deadline The latest block timestamp the fill may be mined at.
    struct RequestFill {
        uint256 id;
        uint256 amount;
        bytes[] routes;
        uint256[] legLimits;
        bytes stableRoute;
        uint256 stableLimit;
        uint256 expectedNonce;
        int256 minUsdcDelta;
        uint256 deadline;
    }

    /// @notice A batch of request fills on one index, in one stablecoin, for {fillBatch}.
    /// @param index The index every request of the batch names.
    /// @param stable The stablecoin every request of the batch names.
    /// @param mintIds The mint requests filled.
    /// @param mintShares The shares delivered to each, at least its limit.
    /// @param redeemIds The redeem requests filled.
    /// @param redeemPay The stablecoin paid to each, at least its limit.
    /// @param issue The shares issued here, their basket from stock and bought along `routes`: what the mint requests
    ///        take beyond the shares the redeem requests escrowed and the share stock delivers, and anything the bot
    ///        adds to that stock.
    /// @param redeem The shares redeemed here, their basket sold along `routes`: what the redeem requests escrowed
    ///        beyond what the mint requests take and the share stock keeps.
    /// @param routes One per component of the index, as {fill}'s.
    /// @param maxIn Empty, or one per component, zero meaning no bound: the most USDC a leg of the issue may cost
    ///        (RX-10).
    /// @param minOut Empty, or one per component, zero meaning no bound: the least USDC a leg of the redeem must
    ///        return (RX-10).
    /// @param stableRoute An exact-input path from `stable` to USDC; empty when `stable` is USDC.
    /// @param stableMaxIn Zero for no bound: the most USDC buying what the redeem requests are paid may cost.
    /// @param stableMinOut Zero for no bound: the least USDC selling what the mint requests escrowed must return.
    /// @param expectedNonce The index's rebalanceNonce the batch was simulated at (RX-4).
    /// @param minUsdcDelta The least the USDC float may change by.
    /// @param deadline The latest block timestamp the batch may be mined at.
    struct BatchFill {
        IWeightedHub index;
        address stable;
        uint256[] mintIds;
        uint256[] mintShares;
        uint256[] redeemIds;
        uint256[] redeemPay;
        uint256 issue;
        uint256 redeem;
        bytes[] routes;
        uint256[] maxIn;
        uint256[] minOut;
        bytes stableRoute;
        uint256 stableMaxIn;
        uint256 stableMinOut;
        uint256 expectedNonce;
        int256 minUsdcDelta;
        uint256 deadline;
    }

    /// @notice An address argument is zero.
    error ZeroAddress();
    /// @notice `caller` is not the owner.
    error NotOwner(address caller);
    /// @notice `caller` is not the keeper.
    error NotKeeper(address caller);
    /// @notice The fill was mined after `deadline`, the one block its price update is valid in.
    error Expired(uint256 deadline);
    /// @notice `index` was not created by the factory.
    error NotIndex(address index);
    /// @notice `requests` escrows requests for another factory's indexes.
    error RequestsMismatch(address requests);
    /// @notice Request `id` is not the side this call fills: a mint for {fillMint}, a redemption for {fillRedeem}.
    error WrongSide(uint256 id);
    /// @notice The routes do not number one per component.
    error LengthMismatch();
    /// @notice `token`'s route is not a path from `token` to USDC, or names USDC itself.
    error BadRoute(address token);
    /// @notice The index needs more of `token` than the executor may deliver from stock (what it holds, capped by the
    ///         owner's stock allowance), and `token` has no route to buy the rest.
    error NoRoute(address token);
    /// @notice `caller` called back outside a fill of its own.
    error UnexpectedCaller(address caller);
    /// @notice The fill changed the float by `usdcDelta`, below `minUsdcDelta`.
    error TooCostly(int256 usdcDelta, int256 minUsdcDelta);
    /// @notice The index's supply is `supply`, above the `maxSupply` the fill was quoted for: an issue since the quote
    ///         grew the settlement past what the bot accepts, so the fill stops before it reaches the hub (XS-4).
    error SupplyMovedOn(uint256 supply, uint256 maxSupply);
    /// @notice The index settled a rebalance since the fill's simulation: its nonce is `actual`, not `expected` (RX-4).
    error StaleRebalanceNonce(uint256 expected, uint256 actual);
    /// @notice A request fill would spend `spent` of the USDC float, above the `allowance` request fills have left.
    error OverRequestAllowance(uint256 spent, uint256 allowance);
    /// @notice Request `id` is on another index than its batch names.
    error WrongIndex(uint256 id);
    /// @notice Request `id` is in another stablecoin than its batch names.
    error WrongStable(uint256 id);
    /// @notice A batch would hand over `spent` more shares of `index` than it brings in, above the `allowance` the
    ///         owner left for delivering that index's shares from stock.
    error OverStockAllowance(address index, uint256 spent, uint256 allowance);
    /// @notice `caller` is not the treasury.
    error NotTreasury(address caller);
    /// @notice The owner pinned no recipient on Wormhole chain `chain`.
    error NoHomeRecipient(uint16 chain, address token);
    /// @notice USDC is the float, not stock: it does not cross the bridge.
    error NotStock(address token);
    /// @notice The bridged transfer carried `actual`, not the `expected` token.
    error WrongToken(address expected, address actual);
    /// @notice A draw of `amount` is above the `allowance` the treasury has left.
    error OverTreasuryAllowance(uint256 amount, uint256 allowance);

    constructor(
        IV3SwapRouter router,
        address usdc,
        IWeightedIndexFactory factory,
        IMintRequests requests,
        ITokenBridge tokenBridge,
        address owner,
        address keeper_
    ) {
        if (
            address(router) == address(0) || usdc == address(0) || address(factory) == address(0)
                || address(requests) == address(0) || address(tokenBridge) == address(0) || owner == address(0)
                || keeper_ == address(0)
        ) revert ZeroAddress();
        if (requests.FACTORY() != address(factory)) revert RequestsMismatch(address(requests));
        ROUTER = router;
        USDC = usdc;
        FACTORY = factory;
        REQUESTS = requests;
        TOKEN_BRIDGE = tokenBridge;
        OWNER = owner;
        keeper = keeper_;
        emit KeeperSet(address(0), keeper_);
        SafeERC20.forceApprove(IERC20(usdc), address(router), type(uint256).max);
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /// @notice Owner only. Makes `next` the keeper.
    function setKeeper(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        address previous = keeper;
        keeper = next;
        emit KeeperSet(previous, next);
    }

    /// @notice Owner only. Sends `amount` of `token`, float or inventory, to `to`. The stock allowance is then capped
    ///         at what is left, as {bridgeOut} caps it, so coins kept later cannot inherit an allowance the coins that
    ///         left had (RZ-23).
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        uint256 left = IERC20(token).balanceOf(address(this));
        if (stockAllowance[token] > left) {
            stockAllowance[token] = left;
            // What is left is known only after the transfer; only the owner calls.
            // forge-lint: disable-next-line(reentrancy-events)
            emit StockAllowanceSet(token, left);
        }
    }

    /// @notice Owner only. Lets the keeper deliver up to `amount` of `token` from stock from now on, replacing what was
    ///         left of the previous allowance.
    function setStockAllowance(address token, uint256 amount) external onlyOwner {
        stockAllowance[token] = amount;
        emit StockAllowanceSet(token, amount);
    }

    /// @notice Owner only. Lets request fills spend up to `amount` of the USDC float from now on, replacing what was
    ///         left of the previous allowance.
    function setRequestUsdcAllowance(uint256 amount) external onlyOwner {
        requestUsdcAllowance = amount;
        emit RequestUsdcAllowanceSet(amount);
    }

    /// @notice Owner only. Makes `next` the treasury.
    function setTreasury(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        address previous = treasury;
        treasury = next;
        emit TreasurySet(previous, next);
    }

    /// @notice Owner only. Lets the treasury hold at most `amount` of USDC off the float from now on, what it already
    ///         holds counted (RS-2).
    function setTreasuryUsdcAllowance(uint256 amount) external onlyOwner {
        treasuryUsdcCap = amount;
        emit TreasuryUsdcAllowanceSet(amount);
    }

    /// @notice How much more USDC the treasury may draw: the owner's cap less what it holds off the float.
    function treasuryUsdcAllowance() public view returns (uint256) {
        uint256 cap = treasuryUsdcCap;
        uint256 out = treasuryUsdcOut;
        return cap > out ? cap - out : 0;
    }

    /// @notice Owner only. Makes `recipient` the only address {bridgeOut} sends `token` to on Wormhole chain `chain`;
    ///         zero stops bridging that coin out to that chain.
    function setHomeRecipient(uint16 chain, address token, bytes32 recipient) external onlyOwner {
        homeRecipient[chain][token] = recipient;
        emit HomeRecipientSet(chain, token, recipient);
    }

    /// @notice Owner only. Lets `amount` more of `token` arriving through the bridge earn stock allowance from now on,
    ///         replacing what was left; zero stops crediting it (RS-1).
    function setRestockAllowance(address token, uint256 amount) external onlyOwner {
        restockAllowance[token] = amount;
        emit RestockAllowanceSet(token, amount);
    }

    /// @notice Keeper only. Fills `index`'s auction at the units the keeper names. The index reads no price: it
    ///         accepts the units when their weighted gain clears its auction's bar.
    /// @param newUnits The recorded units each component is to have, in component order, as `executeRebalance` takes
    ///        them. The bot chooses them from its own view of the market; the floor below is what protects the float.
    /// @param routes One per component: an exact-input Uniswap V3 path from the component to USDC, which read as an
    ///        exact-output path buys the component with USDC; empty for a coin served from inventory, and for USDC.
    /// @param maxAmountsIn Passed to the hub: the fill reverts if the index asks for more of any component.
    /// @param maxSupply The most shares the index may have when the fill runs. The settlement grows with the supply,
    ///        so an issue ahead of the fill that would break `maxAmountsIn` is refused here, for one read, rather than
    ///        by the hub after its own checks (XS-4).
    /// @param minUsdcDelta The least the USDC float may change by: negative accepts a cost, positive requires a gain.
    /// @param deadline The latest block timestamp the fill may be mined at.
    /// @return usdcDelta What the fill changed the float by.
    /// @return gasUsed The gas the call used inside this function, for the bot's simulation.
    function fill(
        IWeightedHub index,
        uint256[] calldata newUnits,
        bytes[] calldata routes,
        uint256[] calldata maxAmountsIn,
        uint256 maxSupply,
        int256 minUsdcDelta,
        uint256 deadline
    ) external returns (int256 usdcDelta, uint256 gasUsed) {
        uint256 gasStart = gasleft();
        _checkKeeper();
        if (block.timestamp > deadline) revert Expired(deadline);
        if (!FACTORY.isIndex(address(index))) revert NotIndex(address(index));
        _checkSupply(index, maxSupply);
        _checkRoutes(index.componentTokens(), routes);

        uint256 before = IERC20(USDC).balanceOf(address(this));
        _settle(index, newUnits, routes, maxAmountsIn);
        usdcDelta = SafeCast.toInt256(IERC20(USDC).balanceOf(address(this))) - SafeCast.toInt256(before);
        if (usdcDelta < minUsdcDelta) revert TooCostly(usdcDelta, minUsdcDelta);
        gasUsed = gasStart - gasleft();
    }

    /// @dev The hub's bounded settlement of `index`, with this contract marked as filling it for the callback.
    function _settle(
        IWeightedHub index,
        uint256[] calldata newUnits,
        bytes[] calldata routes,
        uint256[] calldata maxAmountsIn
    ) private {
        // Transient, for this transaction's callback only: an event per fill would say nothing the hub's does not.
        // forge-lint: disable-next-line(missing-events-access-control)
        _filling = address(index);
        // `index` is one the factory created, checked by {fill}.
        index.executeRebalance(newUnits, abi.encode(routes), maxAmountsIn);
        // forge-lint: disable-next-line(missing-events-access-control)
        _filling = address(0);
    }

    /// @inheritdoc IRebalanceExecutor
    /// @dev Sells each routed component the index sent out, keeps each unrouted one, then delivers each component the
    ///      index needs from stock, within the owner's stock allowance, buying only the rest. A USDC component, which no
    ///      listing allows today, comes out of and goes into the float itself, which the allowance does not cover.
    function onXindexRebalance(uint256[] calldata amountsOut, uint256[] calldata amountsIn, bytes calldata data)
        external
    {
        if (msg.sender != _filling) revert UnexpectedCaller(msg.sender);
        bytes[] memory routes = abi.decode(data, (bytes[]));
        address[] memory tokens = IWeightedHub(msg.sender).componentTokens();
        _sell(tokens, amountsOut, routes, new uint256[](0));
        _acquire(tokens, amountsIn, routes, new uint256[](0));
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsIn[i] != 0) SafeERC20.safeTransfer(IERC20(tokens[i]), msg.sender, amountsIn[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Requests
    // ---------------------------------------------------------------------

    /// @notice Keeper only. Fills mint request `f.id` with `f.amount` shares of its index, at least its limit: buys the
    ///         basket for them from stock and along `f.routes`, issues them here, delivers them to the requester and
    ///         takes the escrowed stablecoin, which `f.stableRoute` sells into USDC when it is not USDC itself.
    /// @return usdcDelta What the fill changed the float by.
    /// @return gasUsed The gas the call used inside this function, for the bot's simulation.
    function fillMint(RequestFill calldata f) external returns (int256 usdcDelta, uint256 gasUsed) {
        uint256 gasStart = gasleft();
        _checkKeeper();
        if (block.timestamp > f.deadline) revert Expired(f.deadline);
        uint256 before = IERC20(USDC).balanceOf(address(this));
        _mintFor(f);
        usdcDelta = _requestDelta(before, f.minUsdcDelta);
        gasUsed = gasStart - gasleft();
    }

    /// @dev The basket for `f.amount` shares of the request's index, from stock and along `f.routes`, issued here and
    ///      delivered for the escrow, which `f.stableRoute` turns into USDC when it is not.
    function _mintFor(RequestFill calldata f) private {
        (IMintRequests.Request memory request, IWeightedHub index, address[] memory tokens) = _openRequest(f, true);
        _checkMintable(index);

        _issueHere(index, tokens, f.amount, f.routes, f.legLimits);
        SafeERC20.forceApprove(IERC20(address(index)), address(REQUESTS), f.amount);
        uint256 stableBefore = IERC20(request.stable).balanceOf(address(this));
        REQUESTS.fill(f.id, f.amount);
        _sellStable(
            request.stable, IERC20(request.stable).balanceOf(address(this)) - stableBefore, f.stableRoute, f.stableLimit
        );
    }

    /// @notice Keeper only. Fills redeem request `f.id` by paying `f.amount` of its stablecoin, at least its limit,
    ///         bought with USDC along `f.stableRoute` when it is not USDC itself, taking the escrowed shares, redeeming
    ///         them here and selling the basket along `f.routes`; a component with no route is kept as stock.
    /// @return usdcDelta What the fill changed the float by.
    /// @return gasUsed The gas the call used inside this function, for the bot's simulation.
    function fillRedeem(RequestFill calldata f) external returns (int256 usdcDelta, uint256 gasUsed) {
        uint256 gasStart = gasleft();
        _checkKeeper();
        if (block.timestamp > f.deadline) revert Expired(f.deadline);
        uint256 before = IERC20(USDC).balanceOf(address(this));
        _redeemFor(f);
        usdcDelta = _requestDelta(before, f.minUsdcDelta);
        gasUsed = gasStart - gasleft();
    }

    /// @dev Pays `f.amount` of the request's stablecoin, bought along `f.stableRoute` when it is not USDC, for the
    ///      escrowed shares, which are redeemed here and sold along `f.routes`; what has no route stays as stock.
    function _redeemFor(RequestFill calldata f) private {
        (IMintRequests.Request memory request, IWeightedHub index, address[] memory tokens) = _openRequest(f, false);

        _buyStable(request.stable, f.amount, f.stableRoute, f.stableLimit);
        SafeERC20.forceApprove(IERC20(request.stable), address(REQUESTS), f.amount);
        REQUESTS.fill(f.id, f.amount);
        // Read after the fill paid the stablecoin out, so a component that is the stablecoin itself counts only what
        // the redeem brings in.
        uint256[] memory held = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            held[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
        index.redeem(request.escrow, address(this));
        uint256[] memory got = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            got[i] = IERC20(tokens[i]).balanceOf(address(this)) - held[i];
        }
        _sell(tokens, got, f.routes, f.legLimits);
    }

    /// @dev A request fill's change to the float, checked against its floor, with what it spent of the float taken
    ///      from {requestUsdcAllowance} (RX-1, RX-9).
    function _requestDelta(uint256 before, int256 minUsdcDelta) private returns (int256 usdcDelta) {
        uint256 afterwards = IERC20(USDC).balanceOf(address(this));
        usdcDelta = SafeCast.toInt256(afterwards) - SafeCast.toInt256(before);
        if (usdcDelta < minUsdcDelta) revert TooCostly(usdcDelta, minUsdcDelta);
        if (afterwards >= before) return usdcDelta;
        uint256 spent = before - afterwards;
        uint256 allowance = requestUsdcAllowance;
        if (spent > allowance) revert OverRequestAllowance(spent, allowance);
        // forge-lint: disable-next-line(missing-events-arithmetic)
        requestUsdcAllowance = allowance - spent;
    }

    /// @dev Request `f.id`, refused before any swap unless the escrow would still take a fill of it: open, and not past
    ///      its deadline. A request its requester cancelled, or another filler filled, between the bot's simulation and
    ///      this transaction then costs one read rather than the whole basket (XS-6); the escrow checks both again. Also
    ///      refused, as early: the other side's request, an index that settled a rebalance since the simulation (RX-4),
    ///      and routes or limits that do not fit the index.
    function _openRequest(RequestFill calldata f, bool isMint)
        private
        view
        returns (IMintRequests.Request memory request, IWeightedHub index, address[] memory tokens)
    {
        request = REQUESTS.getRequest(f.id);
        if (!request.open) revert IMintRequests.RequestNotOpen(f.id);
        if (block.timestamp > request.deadline) revert IMintRequests.RequestExpired(f.id, request.deadline);
        if (request.isMint != isMint) revert WrongSide(f.id);
        index = IWeightedHub(request.index);
        uint256 nonce = index.rebalanceNonce();
        if (nonce != f.expectedNonce) revert StaleRebalanceNonce(f.expectedNonce, nonce);
        tokens = index.componentTokens();
        _checkRoutes(tokens, f.routes);
        if (f.legLimits.length != 0 && f.legLimits.length != tokens.length) revert LengthMismatch();
        _checkStableRoute(request.stable, f.stableRoute);
    }

    /// @dev The gate the hub reads when it issues here, read first: a gated index whose creator has not allowed this
    ///      contract, or has just disallowed it ahead of the fill, refuses the issue only after every swap, so the fill
    ///      stops here instead, before any (XS-6).
    function _checkMintable(IWeightedHub index) private view {
        // The factory's `feeTerms` rule, which the hub applies: open, or this contract allowed.
        if (FACTORY.isGated(address(index)) && !FACTORY.isAllowedMinter(address(index), address(this))) {
            revert IWeightedHub.NotAllowedMinter(address(this));
        }
    }

    /// @notice Keeper only. Fills several requests on one index, in one stablecoin, in one call. `f.issue` shares are
    ///         issued here, their basket from stock and along `f.routes`; the redeem requests are paid and their
    ///         escrowed shares taken; the mint requests are delivered their shares and their escrows taken; and
    ///         `f.redeem` shares are redeemed here and their basket sold. So shares pass from the requests that
    ///         sell them to the requests that buy them, and one basket trades for the difference instead of one per
    ///         request. Shares left over stay here as stock; shares handed over beyond what the batch brought in
    ///         come out of that stock and spend the index's {stockAllowance}. With no request at all the call only
    ///         builds or runs down the share stock.
    /// @return usdcDelta What the batch changed the float by.
    /// @return gasUsed The gas the call used inside this function, for the bot's simulation.
    function fillBatch(BatchFill calldata f) external returns (int256 usdcDelta, uint256 gasUsed) {
        uint256 gasStart = gasleft();
        _checkKeeper();
        if (block.timestamp > f.deadline) revert Expired(f.deadline);
        uint256 before = IERC20(USDC).balanceOf(address(this));
        _batch(f);
        usdcDelta = _requestDelta(before, f.minUsdcDelta);
        gasUsed = gasStart - gasleft();
    }

    /// @dev {fillBatch}'s steps, after every check that can stop it before a swap (XS-6).
    function _batch(BatchFill calldata f) private {
        address[] memory tokens = _checkBatch(f);
        (uint256 pay, uint256 sharesIn) = _openSide(f, f.redeemIds, f.redeemPay, false);
        (uint256 deliver,) = _openSide(f, f.mintIds, f.mintShares, true);
        // Spent before anything moves. The index's shares are its own hub's, which transfers what it is asked to, so
        // what the batch brings in and hands over is known here.
        _spendShareStock(address(f.index), deliver + f.redeem, sharesIn + f.issue);

        // The issue first: it is the one step that spends a coin's stock allowance, and it runs before any call
        // into the escrow.
        if (f.issue != 0) _issueHere(f.index, tokens, f.issue, f.routes, f.maxIn);
        address stable = f.stable;
        uint256 stableBefore = IERC20(stable).balanceOf(address(this));
        if (pay != 0) {
            _buyStable(stable, pay, f.stableRoute, f.stableMaxIn);
            SafeERC20.forceApprove(IERC20(stable), address(REQUESTS), pay);
            for (uint256 i = 0; i < f.redeemIds.length; ++i) {
                REQUESTS.fill(f.redeemIds[i], f.redeemPay[i]);
            }
        }
        if (deliver != 0) {
            SafeERC20.forceApprove(IERC20(address(f.index)), address(REQUESTS), deliver);
            for (uint256 i = 0; i < f.mintIds.length; ++i) {
                REQUESTS.fill(f.mintIds[i], f.mintShares[i]);
            }
        }
        // What the mint requests escrowed, measured: the stablecoin bought above left with the redeem requests. Sold
        // before the redeem, so a stablecoin that is also a component counts here only as an escrow.
        uint256 stableAfter = IERC20(stable).balanceOf(address(this));
        if (stableAfter > stableBefore) _sellStable(stable, stableAfter - stableBefore, f.stableRoute, f.stableMinOut);
        if (f.redeem != 0) _redeemHere(f.index, tokens, f.redeem, f.routes, f.minOut);
    }

    /// @dev The checks of a batch that need no request: a factory index at the nonce the batch was simulated at
    ///      (RX-4), routes and limits that fit it, and a gate that lets this contract issue (XS-6). Returns the
    ///      index's components.
    function _checkBatch(BatchFill calldata f) private view returns (address[] memory tokens) {
        IWeightedHub index = f.index;
        if (!FACTORY.isIndex(address(index))) revert NotIndex(address(index));
        uint256 nonce = index.rebalanceNonce();
        if (nonce != f.expectedNonce) revert StaleRebalanceNonce(f.expectedNonce, nonce);
        tokens = index.componentTokens();
        _checkRoutes(tokens, f.routes);
        uint256 n = tokens.length;
        if ((f.maxIn.length != 0 && f.maxIn.length != n) || (f.minOut.length != 0 && f.minOut.length != n)) {
            revert LengthMismatch();
        }
        _checkStableRoute(f.stable, f.stableRoute);
        if (f.issue != 0) _checkMintable(index);
    }

    /// @dev One side of a batch, read before anything moves, so a request its requester cancelled or another filler
    ///      filled since the simulation costs these reads rather than a basket (XS-6): each request open, not past
    ///      its deadline, of the side named, and on the batch's index and stablecoin.
    /// @return handed What the fills hand the requesters: shares for mint requests, the stablecoin for redeem requests.
    /// @return escrowed What the fills take: the stablecoin for mint requests, shares for redeem requests.
    function _openSide(BatchFill calldata f, uint256[] calldata ids, uint256[] calldata amounts, bool isMint)
        private
        view
        returns (uint256 handed, uint256 escrowed)
    {
        if (ids.length != amounts.length) revert LengthMismatch();
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            IMintRequests.Request memory request = REQUESTS.getRequest(id);
            if (!request.open) revert IMintRequests.RequestNotOpen(id);
            if (block.timestamp > request.deadline) revert IMintRequests.RequestExpired(id, request.deadline);
            if (request.isMint != isMint) revert WrongSide(id);
            if (request.index != address(f.index)) revert WrongIndex(id);
            if (request.stable != f.stable) revert WrongStable(id);
            handed += amounts[i];
            escrowed += request.escrow;
        }
    }

    /// @dev Spends `index`'s stock allowance by the shares a batch hands over (`out`) beyond those it brings in
    ///      (`in_`): those come out of the shares held here before the call. Without it a compromised keeper key could
    ///      deliver the whole share stock to a request of its own, or redeem it and sell the basket into a pool it
    ///      moved, where the float's allowance sees no loss because the float does not fall (CF-1).
    function _spendShareStock(address index, uint256 out, uint256 in_) private {
        if (out <= in_) return;
        uint256 spent = out - in_;
        uint256 allowance = stockAllowance[index];
        if (spent > allowance) revert OverStockAllowance(index, spent, allowance);
        stockAllowance[index] = allowance - spent;
    }

    /// @dev Issues `shares` of `index` here, their basket from stock and bought along `routes`, a leg for at most
    ///      `maxIn`'s entry.
    function _issueHere(
        IWeightedHub index,
        address[] memory tokens,
        uint256 shares,
        bytes[] calldata routes,
        uint256[] calldata maxIn
    ) private {
        uint256[] memory need = index.previewIssue(shares);
        _acquire(tokens, need, routes, maxIn);
        for (uint256 i = 0; i < tokens.length; ++i) {
            SafeERC20.forceApprove(IERC20(tokens[i]), address(index), need[i]);
        }
        index.issue(shares, address(this));
    }

    /// @dev Redeems `shares` of `index` here and sells what the redeem brought in along `routes`, a leg for at least
    ///      `minOut`'s entry; a component with no route is kept as stock. The balances are read here, after the batch
    ///      paid its stablecoin out and took its escrows in, so a component that is the stablecoin itself counts only
    ///      what the redeem brings (AU-3).
    function _redeemHere(
        IWeightedHub index,
        address[] memory tokens,
        uint256 shares,
        bytes[] calldata routes,
        uint256[] calldata minOut
    ) private {
        uint256[] memory held = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            held[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
        index.redeem(shares, address(this));
        uint256[] memory got = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            got[i] = IERC20(tokens[i]).balanceOf(address(this)) - held[i];
        }
        _sell(tokens, got, routes, minOut);
    }

    // ---------------------------------------------------------------------
    // Restock
    // ---------------------------------------------------------------------

    /// @notice Treasury only. Completes the bridge's transfer `encodedVm` of `token` to this contract, and adds what
    ///         arrived to `token`'s stock allowance as far as the owner's restock allowance for it goes, which the
    ///         credit spends (RS-1), and as far as the stock allowance can still hold (RS-6). What arrives beyond it
    ///         stays here as stock the keeper cannot deliver until the owner allows it. The transfer must carry a
    ///         payload, which the bridge lets only its recipient complete, so no one can land the coins here first and
    ///         leave them without the allowance.
    /// @return amount What arrived, measured as this contract's balance increase.
    function redeemBridged(bytes calldata encodedVm, address token) external returns (uint256 amount) {
        _checkTreasury();
        uint256 before = IERC20(token).balanceOf(address(this));
        ITokenBridge.TransferWithPayload memory t =
            TOKEN_BRIDGE.parseTransferWithPayload(TOKEN_BRIDGE.completeTransferWithPayload(encodedVm));
        address carried = t.tokenChain == TOKEN_BRIDGE.chainId()
            ? address(uint160(uint256(t.tokenAddress)))
            : TOKEN_BRIDGE.wrappedAsset(t.tokenChain, t.tokenAddress);
        if (carried != token) revert WrongToken(token, carried);
        amount = IERC20(token).balanceOf(address(this)) - before;
        // The credit: what arrived, within what is left of the restock allowance (RS-1) and of what the stock allowance
        // can still hold, since it has no unlimited value and an overflow would refuse the coins (RS-6).
        uint256 room = restockAllowance[token];
        uint256 stock = stockAllowance[token];
        uint256 credited = amount < room ? amount : room;
        if (credited > type(uint256).max - stock) credited = type(uint256).max - stock;
        restockAllowance[token] = room - credited;
        stockAllowance[token] = stock + credited;
        // What arrived is known only after the bridge's transfer; only the treasury calls, through the immutable
        // bridge.
        // forge-lint: disable-next-line(reentrancy-events)
        emit BridgedIn(token, amount, credited);
    }

    /// @notice Treasury only. Bridges `amount` of `token` to the owner's pinned recipient for it on Wormhole
    ///         chain `chain`, forwarding all of msg.value to the bridge as Wormhole's message fee. What the bridge
    ///         cannot carry below its eight decimals stays here. The stock allowance is then capped at what is
    ///         left, so coins kept later cannot inherit an allowance the coins that left had.
    /// @return sequence The bridge's message sequence, by which the bot fetches the signed transfer.
    function bridgeOut(address token, uint256 amount, uint16 chain) external payable returns (uint64 sequence) {
        _checkTreasury();
        if (token == USDC) revert NotStock(token);
        bytes32 recipient = homeRecipient[chain][token];
        if (recipient == bytes32(0)) revert NoHomeRecipient(chain, token);
        SafeERC20.forceApprove(IERC20(token), address(TOKEN_BRIDGE), amount);
        // The recipient is the owner's, and msg.value is Wormhole's fee, which the bridge forwards to its core.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        sequence = TOKEN_BRIDGE.transferTokens{value: msg.value}(token, amount, chain, recipient, 0, 0);
        SafeERC20.forceApprove(IERC20(token), address(TOKEN_BRIDGE), 0);
        uint256 left = IERC20(token).balanceOf(address(this));
        if (stockAllowance[token] > left) {
            stockAllowance[token] = left;
            // What is left is known only after the bridge took its part; only the treasury calls.
            // forge-lint: disable-next-line(reentrancy-events)
            emit StockAllowanceSet(token, left);
        }
        // The sequence is the bridge's answer, by which the bot fetches the signed transfer; only the treasury calls.
        // forge-lint: disable-next-line(reentrancy-events)
        emit BridgedOut(token, amount, chain, recipient, sequence);
    }

    /// @notice Treasury only. Sends `amount` of the USDC float to the treasury, within the owner's cap on what it holds
    ///         off the float.
    function drawUsdc(uint256 amount) external {
        _checkTreasury();
        uint256 allowance = treasuryUsdcAllowance();
        if (amount > allowance) revert OverTreasuryAllowance(amount, allowance);
        treasuryUsdcOut += amount;
        emit UsdcDrawn(amount);
        SafeERC20.safeTransfer(IERC20(USDC), msg.sender, amount);
    }

    /// @notice Treasury only. Takes `amount` of USDC from the treasury, which approved it, into the float. What arrived
    ///         lowers what the treasury holds off the float, down to zero: what it repays beyond what it drew joins the
    ///         float and raises nothing (RS-2).
    function repayUsdc(uint256 amount) external {
        _checkTreasury();
        uint256 before = IERC20(USDC).balanceOf(address(this));
        SafeERC20.safeTransferFrom(IERC20(USDC), msg.sender, address(this), amount);
        uint256 arrived = IERC20(USDC).balanceOf(address(this)) - before;
        uint256 out = treasuryUsdcOut;
        treasuryUsdcOut = arrived < out ? out - arrived : 0;
        emit UsdcRepaid(arrived);
    }

    // ---------------------------------------------------------------------
    // Swaps and stock
    // ---------------------------------------------------------------------

    /// @dev Sells each routed component's `amounts` into USDC and keeps each unrouted one as stock. `minOut`, empty or
    ///      one per component, is the least each sale must return, zero for no bound.
    function _sell(address[] memory tokens, uint256[] memory amounts, bytes[] memory routes, uint256[] memory minOut)
        private
    {
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 out = amounts[i];
            // A zero amountIn would make the router swap its own balance instead.
            if (out == 0 || routes[i].length == 0) continue;
            SafeERC20.forceApprove(IERC20(tokens[i]), address(ROUTER), out);
            // What a swap returns is not needed: a fill measures the float as a whole against its floor.
            // forge-lint: disable-next-item(unused-return)
            ROUTER.exactInput(
                IV3SwapRouter.ExactInputParams({
                    path: routes[i], recipient: address(this), amountIn: out, amountOutMinimum: _limit(minOut, i, 0)
                })
            );
        }
    }

    /// @dev Entry `i` of `limits`, or `otherwise` when `limits` is empty or that entry is zero.
    function _limit(uint256[] memory limits, uint256 i, uint256 otherwise) private pure returns (uint256) {
        return limits.length != 0 && limits[i] != 0 ? limits[i] : otherwise;
    }

    /// @dev Makes sure this contract holds `amounts` of each component: from stock first, within the owner's stock
    ///      allowance, which every delivery from stock spends, then bought with USDC along the route, for at most
    ///      `maxIn`'s entry (empty, or zero, for the whole float). A USDC component comes out of the float itself, which
    ///      the allowance does not cover.
    function _acquire(address[] memory tokens, uint256[] memory amounts, bytes[] memory routes, uint256[] memory maxIn)
        private
    {
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 need = amounts[i];
            if (need == 0) continue;
            address token = tokens[i];
            bool stock = token != USDC;
            uint256 usable = IERC20(token).balanceOf(address(this));
            if (stock && usable > stockAllowance[token]) usable = stockAllowance[token];
            uint256 fromStock = usable < need ? usable : need;
            // Spent before the purchase below, so the swap runs with the allowance already written.
            if (stock && fromStock != 0) stockAllowance[token] -= fromStock;
            if (fromStock < need) {
                // USDC has no route, so a float too short for a USDC component also ends here.
                if (routes[i].length == 0) revert NoRoute(token);
                // forge-lint: disable-next-item(unused-return)
                ROUTER.exactOutput(
                    IV3SwapRouter.ExactOutputParams({
                        path: routes[i],
                        recipient: address(this),
                        amountOut: need - fromStock,
                        amountInMaximum: _limit(maxIn, i, IERC20(USDC).balanceOf(address(this)))
                    })
                );
            }
        }
    }

    /// @dev Sells `amount` of `stable` into USDC along `route`, for at least `minOut`; nothing to do when it is USDC
    ///      already.
    function _sellStable(address stable, uint256 amount, bytes calldata route, uint256 minOut) private {
        if (stable == USDC || amount == 0) return;
        SafeERC20.forceApprove(IERC20(stable), address(ROUTER), amount);
        // forge-lint: disable-next-item(unused-return)
        ROUTER.exactInput(
            IV3SwapRouter.ExactInputParams({
                path: route, recipient: address(this), amountIn: amount, amountOutMinimum: minOut
            })
        );
    }

    /// @dev Buys `amount` of `stable` with USDC along `route`, read backwards, for at most `maxIn` (zero for the
    ///      whole float); nothing to do when it is USDC already.
    function _buyStable(address stable, uint256 amount, bytes calldata route, uint256 maxIn) private {
        if (stable == USDC) return;
        uint256 float = IERC20(USDC).balanceOf(address(this));
        // forge-lint: disable-next-item(unused-return)
        ROUTER.exactOutput(
            IV3SwapRouter.ExactOutputParams({
                path: route, recipient: address(this), amountOut: amount, amountInMaximum: maxIn != 0 ? maxIn : float
            })
        );
    }

    /// @dev A stablecoin other than USDC needs a well-formed path from it to USDC; USDC takes none.
    function _checkStableRoute(address stable, bytes calldata route) private view {
        bool needed = stable != USDC;
        if (
            needed != (route.length != 0)
                || (needed
                    && (!PathLib.isValidShape(route)
                        || PathLib.firstToken(route) != stable
                        || PathLib.lastToken(route) != USDC))
        ) revert BadRoute(stable);
    }

    /// @dev One route per component, each empty or a well-formed path from its component to USDC; USDC takes none.
    function _checkRoutes(address[] memory tokens, bytes[] calldata routes) private view {
        uint256 n = tokens.length;
        if (routes.length != n) revert LengthMismatch();
        for (uint256 i = 0; i < n; ++i) {
            bytes calldata route = routes[i];
            if (route.length == 0) continue;
            if (
                tokens[i] == USDC || !PathLib.isValidShape(route) || PathLib.firstToken(route) != tokens[i]
                    || PathLib.lastToken(route) != USDC
            ) revert BadRoute(tokens[i]);
        }
    }

    /// @dev The fill's supply bound, before the hub is called (XS-4).
    function _checkSupply(IWeightedHub index, uint256 maxSupply) private view {
        uint256 supply = index.totalSupply();
        if (supply > maxSupply) revert SupplyMovedOn(supply, maxSupply);
    }

    function _checkOwner() private view {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
    }

    function _checkKeeper() private view {
        if (msg.sender != keeper) revert NotKeeper(msg.sender);
    }

    function _checkTreasury() private view {
        if (msg.sender != treasury) revert NotTreasury(msg.sender);
    }
}
