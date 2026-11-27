// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWeightedIndexFactory} from "./interfaces/IWeightedIndexFactory.sol";
import {IWeightedHub} from "./interfaces/IWeightedHub.sol";
import {IPythPrices} from "./interfaces/IPythPrices.sol";
import {WeightedHub} from "./WeightedHub.sol";
import {PythPrices} from "./PythPrices.sol";

/// @title WeightedIndexFactory
/// @notice An account the owner approved creates an index here, choosing each component's weight. Components come
///         from a curated whitelist. See {IWeightedIndexFactory}.
/// @dev Roles
///      - The owner proposes listings and guardian changes, approves who may create an index, delists, and hands over
///        ownership.
///      - A listing takes effect LISTING_DELAY after it is proposed; a guardian change, GUARDIAN_DELAY after. Either
///        must be executed within PROPOSAL_WINDOW of becoming ready, or proposed again.
///      - The guardian can cancel pending listings and delist. It keeps that power while its replacement is pending.
///        It can cancel its own removal, but the owner can still replace it with another address.
///      - Owner and guardian can cancel a pending rebalance on any index, and start one that leaves chosen components
///        untouched.
///      - Either role can pause the issue of new shares, on one index or on all, and only the owner resumes it: the
///        brake for an index or a build found to have a fault. It is read by an issue and by nothing else, so no
///        redeem, claim, transfer or rebalance can be paused, by anyone.
///      - Neither role can pause an exit, upgrade, set units or weights, or touch funds held by any index. Ownership cannot
///        be renounced.
///
///      Prices
///      - No issue, redeem or claim reads one. A rebalance fill is checked against Pyth's prices through `PRICES`,
///        which the constructor deploys with the chain's Pyth contract, at the feed {priceFeedOf} names for each
///        token, and that check can only refuse a fill the units accept.
///      - The owner sets a token's feed behind LISTING_DELAY, as a listing, and the guardian can cancel it. A feed
///        reaches every index from the moment it is set, unlike a listing: a wrong one can only stop fills that move
///        the token, or let one through that the units already accept, never take anything the units forbid.
///      - A listing records the token's decimals, which only bound the units an index may start with. An index's
///        components and weights are fixed at creation, so no later listing or delisting reaches it. Its units are
///        the creator's at creation and move afterwards: a settlement writes new ones, and a streaming fee scales
///        them down, so the units to value an index at are the hub's `components()`, never the creation's.
///
///      Addresses
///      - Each index is deployed with CREATE2. The salt covers the creator, the name, the symbol, every component's
///        token, starting units and weight, and the index's config (fee rates, referral share, rebalance interval).
///        The gate and the listed flag are not in it.
///      - So an address can never hold a different basket or different terms, even after a re-org. An app can show
///        the address before the transaction confirms, unless a policy change lands first: it changes the salt, and
///        the index deploys at another address (RZ-28).
///      - A creation may carry the index's first issue: creating the index is then buying it. The new index pulls
///        the basket from the creator, who approved that address before it existed. Only this factory can deploy
///        there, and only for that creator, since the salt names it, so nobody else can spend such an approval. The
///        first issue's shares and recipient are not terms of the index and not in the salt. The factory itself
///        still calls no token.
///
///      Fees
///      - The owner sets a policy: the platform's fee, the referrer's share of it, the recipient, and a creation fee
///        in ether.
///      - An index copies the rates in force at creation and keeps them. A later policy reaches only later indexes.
///      - A creator names the highest platform fee and streaming fee it accepts. So no higher rate can land between
///        its quote and its creation. The referral share is not bounded: it only splits the platform's part, so it
///        costs neither the creator nor a minter (RZ-28).
///      - The recipients are read live, through `feeTerms`, so changing a recipient strands nothing. A creator
///        handover accrues the streaming fee first, so each creator is paid for its own time. A change of the
///        platform's recipient does not: what an index has not accrued yet goes to the new one.
///      - The creation fee is forwarded to the recipient in the same call. The factory holds no ether.
///
///      Creators
///      - Only an account the owner approved creates an index. No contract reads a price, so none can tell whether
///        the units a creator names match its weights, and an index created off its weights loses that distance to
///        whoever fills its auctions: the approval is what keeps a stranger from creating one. It is read at creation
///        and nowhere else: an approved creator is bound by the whitelist and the fee caps, and withdrawing an
///        approval reaches no index that exists.
///      - The factory records each index's creator. The creator receives the creator's fee shares and can hand the
///        role on, to any account: taking the role needs no approval.
///      - On a gated index, the creator keeps the allowlist of who may receive new shares, and can open the index for
///        good. The creator has no power over components or rates.
///
///      Whitelist policy (enforced by the listing process, not on chain)
///      - Standard ERC-20s only: no fee-on-transfer, rebasing or callback (ERC-777 style) tokens; 6 to 18 decimals.
///      - Components an issuer can pause or blacklist, such as WBTC, must be labelled in the app. While one is frozen,
///        holders can still take the other components out with `WeightedHub.redeemSkipping`. While an index itself
///        is blocked as a sender, nothing can be issued into it (CannotSendOut).
///      - A holder must be able to send itself one raw unit of the token at no cost. Every issue and every fill
///        proves a component can leave that way, so a token that refuses a transfer to oneself, as a Compound cToken
///        does, can never be issued into an index.
///      - One balance, one address. A token whose balance is also reachable through a second address is never
///        listed: the basket builder keeps its ledger by address and refuses only the swaps that would count such a
///        balance twice, and an index naming both addresses would count one balance as backing two components.
// The two payable entry points, `createIndex` and `createAndIssue`, forward all of msg.value to the platform
// recipient in the same call (`test_theCreationFeeIsForwardedWhole`), so no ether stays here.
// aderyn-fp-next-line(contract-locks-ether)
contract WeightedIndexFactory is IWeightedIndexFactory, Ownable2Step, ReentrancyGuard {
    uint256 public constant MIN_COMPONENTS = 2;
    uint256 public constant MAX_COMPONENTS = 200;
    /// @inheritdoc IWeightedIndexFactory
    uint256 public constant MAX_WEIGHT_DEVIATION = 0.05e18;
    /// @inheritdoc IWeightedIndexFactory
    uint256 public constant WEIGHTS_DELAY = 7 days;
    uint256 public constant TOTAL_WEIGHT = 1e4;
    uint256 public constant MIN_RAW_UNITS = 1e4;
    uint256 public constant MAX_UNITS = type(uint96).max >> 10;
    uint256 public constant MAX_WHOLE_TOKENS = 1e9;
    uint256 public constant LISTING_DELAY = 2 days;
    uint256 public constant GUARDIAN_DELAY = 7 days;
    uint256 public constant PROPOSAL_WINDOW = 7 days;
    uint256 public constant MAX_CREATOR_FEE_BPS = 100;
    uint256 public constant MAX_PLATFORM_FEE_BPS = 25;
    uint256 public constant MAX_CREATOR_STREAMING_BPS = 500;
    uint256 public constant MAX_PLATFORM_STREAMING_BPS = 100;
    uint256 public constant MIN_REBALANCE_INTERVAL = 7 days;
    uint256 public constant MAX_REBALANCE_INTERVAL = 91 days;
    address public immutable IMPLEMENTATION;
    /// @inheritdoc IWeightedIndexFactory
    address public immutable PRICES;

    uint8 private constant MAX_DECIMALS = 18;
    uint256 private constant BPS = 1e4;

    address public guardian;
    address public pendingGuardian;
    uint256 public pendingGuardianEta;

    mapping(address => bool) public isWhitelisted;
    address[] private _whitelist;
    /// @dev Position in `_whitelist` plus one (0 = absent), for O(1) removal.
    mapping(address => uint256) private _whitelistPos;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address token => uint8 decimals) public decimalsOf;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address token => uint256 eta) public listingEta;
    /// @dev The decimals a pending listing read from its token when it was proposed.
    mapping(address token => uint8 decimals) private _pendingDecimals;
    mapping(address token => IPythPrices.PriceFeed feed) private _priceFeeds;
    /// @dev Each index's pending change of weights, and when it applies (`weightsEta`).
    mapping(address index => uint256[] weights) private _pendingWeights;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address index => uint256 eta) public weightsEta;
    mapping(address token => IPythPrices.PriceFeed feed) private _pendingPriceFeeds;
    mapping(address token => uint256 eta) private _priceFeedEta;

    /// @inheritdoc IWeightedIndexFactory
    mapping(address account => bool approved) public isApprovedCreator;
    mapping(address => bool) public isIndex;
    mapping(address => address) public creatorOf;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address index => address account) public pendingCreatorOf;
    address[] public allIndexes;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address index => bool gated) public isGated;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address index => mapping(address account => bool allowed)) public isAllowedMinter;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address index => bool paused) public mintingPaused;

    /// @inheritdoc IWeightedIndexFactory
    uint16 public platformFeeBps;
    /// @inheritdoc IWeightedIndexFactory
    uint16 public platformStreamingBps;
    /// @inheritdoc IWeightedIndexFactory
    uint16 public referralShareBps;
    /// @inheritdoc IWeightedIndexFactory
    address public platformFeeRecipient;
    /// @inheritdoc IWeightedIndexFactory
    uint256 public creationFee;

    modifier onlyOwnerOrGuardian() {
        _checkOwnerOrGuardian();
        _;
    }

    // A zero guardian is allowed on purpose: it means the factory starts without one.
    // forge-lint: disable-next-item(missing-zero-check)
    /// @param pyth Pyth's price contract on this chain, or zero for a factory whose fills no price checks: the deploy
    ///        script refuses zero, and any address but the chain's own, on every chain it pins.
    /// @param sharesOracle Ondo's `SyntheticSharesOracle` on this chain, from which `PRICES` reads an Ondo token's
    ///        sValue, or zero where Ondo has none: the deploy script takes the chain's own, on every chain it pins.
    constructor(address initialOwner, address initialGuardian, address pyth, address math, address sharesOracle)
        Ownable(initialOwner)
    {
        // A zero guardian is allowed on purpose, as above.
        // aderyn-fp-next-line(state-no-address-check)
        guardian = initialGuardian;
        emit GuardianSet(address(0), initialGuardian);
        // The math is deployed on its own, before the factory: deployed here as well, the factory's init code passed
        // EIP-3860's 49,152 bytes once weights could change. It is stateless, and the deploy script and
        // `checkDeployment` pin its code as they pin the factory's.
        if (math.code.length == 0) revert NotAContract(math);
        address prices = pyth == address(0) ? address(0) : address(new PythPrices(pyth, sharesOracle));
        PRICES = prices;
        IMPLEMENTATION = address(new WeightedHub(math, prices));
    }

    // ---------------------------------------------------------------------
    // Index creation
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function createIndex(
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components,
        IndexParams calldata params
    ) external payable nonReentrant returns (address index) {
        _checkApprovedCreator();
        return _createIndex(name, symbol, components, params, IWeightedHub.FirstIssue(address(0), 0, address(0)));
    }

    /// @inheritdoc IWeightedIndexFactory
    function createAndIssue(
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components,
        IndexParams calldata params,
        uint256 shares,
        address to
    ) external payable nonReentrant returns (address index) {
        _checkApprovedCreator();
        // Zero shares would create the index with none, which is {createIndex}'s to say.
        if (shares == 0) revert IWeightedHub.ZeroShares();
        // The payer is the caller and nobody else: the index pulls the first basket from the account named here.
        return _createIndex(name, symbol, components, params, IWeightedHub.FirstIssue(msg.sender, shares, to));
    }

    /// @dev Reverts unless the caller is an account the owner approved to create indexes. Both creation entry points
    ///      call it first.
    function _checkApprovedCreator() private view {
        if (!isApprovedCreator[msg.sender]) revert CreatorNotApproved(msg.sender);
    }

    /// @dev Creates an index for the caller, an approved creator, and, when `first` names shares, has the index issue
    ///      them in its initializer.
    function _createIndex(
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components,
        IndexParams calldata params,
        IWeightedHub.FirstIssue memory first
    ) private returns (address index) {
        // The reentrancy guard covers the two calls here into addresses the factory did not deploy: the creation
        // fee's transfer at the end, and, in a creation with a first issue, the components the new index pulls from
        // the creator. The factory itself calls no token. Validation only reads storage and Pyth's prices, and every
        // write of this creation is made before the clone is initialized.
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyString();
        if (msg.value != creationFee) revert WrongCreationFee(msg.value, creationFee);
        // Read before the clone is initialized, so no factory state is read after an external call.
        address recipient = platformFeeRecipient;
        IWeightedHub.ComponentInit[] memory inits = _componentInits(components);
        _validateComponents(components, inits);
        if (PRICES != address(0)) _checkOnWeights(inits);
        IWeightedHub.Config memory config = _checkedConfig(params);

        bytes32 salt = _salt(msg.sender, keccak256(bytes(name)), keccak256(bytes(symbol)), _contentsHash(inits, config));
        // Effects before interaction: register the clone, then initialize it in the same transaction.
        index = _deployClone(_template(components), salt);
        if (params.gated) isGated[index] = true;
        // Only the clone's CREATE2, which runs no code, precedes this.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IndexCreated(index, msg.sender, name, symbol, inits, config, params.listed);

        _initializeIndex(index, salt, name, symbol, inits, config, first);

        // Last, and only if the policy charges a fee. The owner picks the recipient. One that refuses ether
        // (OpenZeppelin's FailedCall) blocks only creation, until the owner names another.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        if (msg.value != 0) Address.sendValue(payable(recipient), msg.value);
    }

    /// @dev Deploys the clone at `salt` and registers it. Reverts if that address already holds one.
    function _deployClone(address template, bytes32 salt) private returns (address index) {
        address predicted = Clones.predictDeterministicAddress(template, salt);
        if (predicted.code.length != 0) revert IndexAlreadyExists(predicted);
        index = Clones.cloneDeterministic(template, salt);
        // IndexCreated, which createIndex emits next, records the new index and its creator.
        // forge-lint: disable-next-line(missing-events-access-control)
        isIndex[index] = true;
        // IndexCreated, as above.
        // forge-lint: disable-next-line(missing-events-access-control)
        creatorOf[index] = msg.sender;
        allIndexes.push(index);
    }

    /// @dev Builds the index's config from the creator's params and the current policy, checking each against its
    ///      bound.
    function _checkedConfig(IndexParams calldata params) private view returns (IWeightedHub.Config memory) {
        if (params.creatorFeeBps > MAX_CREATOR_FEE_BPS) revert CreatorFeeTooHigh(params.creatorFeeBps);
        if (params.creatorStreamingBps > MAX_CREATOR_STREAMING_BPS) {
            revert StreamingFeeTooHigh(params.creatorStreamingBps);
        }
        if (params.rebalanceInterval < MIN_REBALANCE_INTERVAL || params.rebalanceInterval > MAX_REBALANCE_INTERVAL) {
            revert IntervalOutOfRange(params.rebalanceInterval);
        }
        uint16 platform = platformFeeBps;
        if (platform > params.maxPlatformFeeBps) revert PlatformFeeTooHigh(platform, params.maxPlatformFeeBps);
        uint16 streaming = platformStreamingBps;
        if (streaming > params.maxPlatformStreamingBps) {
            revert PlatformStreamingFeeTooHigh(streaming, params.maxPlatformStreamingBps);
        }
        return IWeightedHub.Config({
            creatorFeeBps: params.creatorFeeBps,
            platformFeeBps: platform,
            referralShareBps: referralShareBps,
            creatorStreamingBps: params.creatorStreamingBps,
            platformStreamingBps: streaming,
            rebalanceInterval: params.rebalanceInterval
        });
    }

    // ---------------------------------------------------------------------
    // Creators
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function setApprovedCreator(address account, bool approved) external onlyOwner {
        // CreatorApprovalSet, on the next line, records the change the lint asks an event for.
        // forge-lint: disable-next-line(missing-events-access-control)
        isApprovedCreator[account] = approved;
        emit CreatorApprovalSet(account, approved);
    }

    /// @inheritdoc IWeightedIndexFactory
    function transferCreator(address index, address newCreator) external {
        _checkCreator(index);
        if (newCreator == address(0)) revert ZeroAddress();
        if (newCreator == address(this) || isIndex[newCreator]) revert InvalidRecipient(newCreator);
        // CreatorTransferStarted, two lines down, records the change the lint asks an event for.
        // forge-lint: disable-next-line(missing-events-access-control)
        pendingCreatorOf[index] = newCreator;
        emit CreatorTransferStarted(index, msg.sender, newCreator);
    }

    /// @inheritdoc IWeightedIndexFactory
    function acceptCreator(address index) external {
        // The new creator accepts, so creatorOf never names an account that did not agree to it (RX-22).
        if (pendingCreatorOf[index] != msg.sender) revert Unauthorized(msg.sender);
        address previous = creatorOf[index];
        // Settle the streaming fee owed so far while `feeTerms` still names the outgoing creator. Every accrual pays
        // whoever is creator when it runs, so without this the newcomer would collect what the other one earned.
        // - `index` is this factory's own clone: only {transferCreator} writes `pendingCreatorOf`, and it refuses an
        //   address the factory did not deploy. The call mints fee shares and reads `feeTerms` back by STATICCALL.
        // - The outgoing creator can always hold shares. The first is whoever called {createIndex}, never the
        //   factory or an index that did not exist yet, and {transferCreator} refuses the factory and every index
        //   for a later one. So the accrual never falls back to minting to its caller, which here is the factory.
        // - It reverts while the index is inside one of its own calls. The handover is then made after that call.
        // The write of `creatorOf` has to follow it, so the lints see a call before an effect. Nothing can re-enter:
        // the clone runs this factory's implementation, which calls no token and no account here. Wake's marker is
        // a block, since forge lint's has to sit directly above the call and Aderyn's at its end.
        // wake-disable reentrancy
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IWeightedHub(index).accrueFees(); // aderyn-fp(reentrancy-state-change)
        // wake-enable reentrancy
        // CreatorTransferred, two lines down, records the change the lint asks an event for.
        // forge-lint: disable-next-line(missing-events-access-control)
        creatorOf[index] = msg.sender;
        // CreatorTransferred, on the next line, records the offer taken.
        // forge-lint: disable-next-line(missing-events-access-control)
        delete pendingCreatorOf[index];
        // A change of weights the outgoing creator proposed goes with the role: left pending, it would take effect
        // under the new creator, who never proposed it and would have to notice it to cancel it (HK-16).
        if (weightsEta[index] != 0) {
            delete weightsEta[index];
            delete _pendingWeights[index];
            // forge-lint: disable-next-line(reentrancy-events)
            emit WeightsCancelled(index);
        }
        // Only the accrual on this factory's own clone precedes it, and that runs no other account's code.
        // forge-lint: disable-next-line(reentrancy-events)
        emit CreatorTransferred(index, previous, msg.sender);
    }

    /// @inheritdoc IWeightedIndexFactory
    function setAllowedMinter(address index, address account, bool allowed) external {
        _checkCreator(index);
        isAllowedMinter[index][account] = allowed;
        emit MinterAllowed(index, account, allowed);
    }

    /// @inheritdoc IWeightedIndexFactory
    function openMinting(address index) external {
        _checkCreator(index);
        if (!isGated[index]) revert NotGated(index);
        isGated[index] = false;
        emit MintingOpened(index);
    }

    /// @inheritdoc IWeightedIndexFactory
    function pauseMinting(address index) external onlyOwnerOrGuardian {
        // Zero names every index; anything else must be one of them, so a mistyped address pauses nothing unseen.
        if (index != address(0) && !isIndex[index]) revert NotIndex(index);
        mintingPaused[index] = true;
        emit MintingPaused(index, msg.sender);
    }

    /// @inheritdoc IWeightedIndexFactory
    function resumeMinting(address index) external onlyOwner {
        mintingPaused[index] = false;
        emit MintingResumed(index);
    }

    /// @dev Reverts unless the caller is `index`'s creator. An address the factory did not deploy has no creator, so it
    ///      is refused first.
    function _checkCreator(address index) private view {
        if (!isIndex[index]) revert NotIndex(index);
        if (msg.sender != creatorOf[index]) revert Unauthorized(msg.sender);
    }

    /// @inheritdoc IWeightedIndexFactory
    function feeTerms(address index, address to)
        external
        view
        returns (bool allowed, address creator, address platform)
    {
        creator = creatorOf[index];
        // No index issues while minting is paused, on it or on every index. A gated index's creator mints it without
        // an allowlist entry, which it could give itself anyway.
        allowed = !mintingPaused[address(0)] && !mintingPaused[index]
            && (!isGated[index] || to == creator || isAllowedMinter[index][to]);
        platform = platformFeeRecipient;
    }

    /// @inheritdoc IWeightedIndexFactory
    function setFeePolicy(
        uint16 platformFeeBps_,
        uint16 platformStreamingBps_,
        uint16 referralShareBps_,
        address recipient,
        uint256 creationFee_
    ) external onlyOwner {
        if (
            platformFeeBps_ > MAX_PLATFORM_FEE_BPS || platformStreamingBps_ > MAX_PLATFORM_STREAMING_BPS
                || referralShareBps_ > BPS || recipient == address(0) || recipient == address(this)
                || isIndex[recipient]
        ) revert InvalidFeePolicy();
        platformFeeBps = platformFeeBps_;
        platformStreamingBps = platformStreamingBps_;
        referralShareBps = referralShareBps_;
        platformFeeRecipient = recipient;
        creationFee = creationFee_;
        emit FeePolicySet(platformFeeBps_, platformStreamingBps_, referralShareBps_, recipient, creationFee_);
    }

    /// @dev The implementation an index of `components` clones: `WeightedHub`. A factory for another kind of component
    ///      would override this and `_initializeIndex`.
    function _template(ComponentSpec[] calldata) internal view virtual returns (address) {
        return IMPLEMENTATION;
    }

    /// @dev Initializes a fresh clone, which issues `first`'s shares if it names any. The salt is unused here; it is
    ///      kept for an override that records it.
    function _initializeIndex(
        address index,
        bytes32,
        string calldata name,
        string calldata symbol,
        IWeightedHub.ComponentInit[] memory inits,
        IWeightedHub.Config memory config,
        IWeightedHub.FirstIssue memory first
    ) internal virtual {
        // Safe: `createIndex` is nonReentrant, the clone runs this factory's own implementation, and the only later
        // interaction (the creation fee's transfer) reads no state. A first issue has the clone call the components,
        // under its own guard and after every write of the creation. Wake's reentrancy detector does not model the
        // guards.
        // wake-disable-next-line reentrancy
        IWeightedHub(index).initialize(name, symbol, inits, config, first);
    }

    /// @inheritdoc IWeightedIndexFactory
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components,
        IndexParams calldata params
    ) external view returns (address) {
        return _predictAddress(
            creator, keccak256(bytes(name)), keccak256(bytes(symbol)), components, _checkedConfig(params)
        );
    }

    /// @dev {predictIndexAddress} with the name and symbol already hashed, to save stack slots.
    function _predictAddress(
        address creator,
        bytes32 nameHash,
        bytes32 symbolHash,
        ComponentSpec[] calldata components,
        IWeightedHub.Config memory config
    ) private view returns (address) {
        bytes32 contents = _contentsHash(_componentInits(components), config);
        return Clones.predictDeterministicAddress(_template(components), _salt(creator, nameHash, symbolHash, contents));
    }

    /// @inheritdoc IWeightedIndexFactory
    function isOwnerOrGuardian(address account) public view returns (bool) {
        return account == owner() || (account == guardian && account != address(0));
    }

    function _checkOwnerOrGuardian() private view {
        if (!isOwnerOrGuardian(msg.sender)) revert Unauthorized(msg.sender);
    }

    /// @dev Validates `components` against the whitelist, the unit and weight bounds and the duplicate rule. The
    ///      duplicate check marks each token in transient storage (EIP-1153) and clears the marks before returning:
    ///      one pass, where comparing every pair cost 2.7M gas at two hundred components, gas the creation's price
    ///      check needs (MAX_WEIGHT_DEVIATION).
    function _validateComponents(ComponentSpec[] calldata components, IWeightedHub.ComponentInit[] memory inits)
        private
    {
        uint256 n = components.length;
        if (n < MIN_COMPONENTS || n > MAX_COMPONENTS) revert InvalidComponentCount(n);

        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            ComponentSpec calldata c = components[i];
            IWeightedHub.ComponentInit memory init = inits[i];
            address token = init.token;
            if (!isWhitelisted[token]) revert TokenNotWhitelisted(token);
            if (c.units < MIN_RAW_UNITS || c.units > _maxUnits(decimalsOf[token])) {
                revert UnitsOutOfRange(token, c.units);
            }
            if (c.weight == 0 || c.weight > TOTAL_WEIGHT) revert InvalidWeights();
            total += c.weight;
            if (_seen(token)) revert DuplicateToken(token);
        }
        if (total != TOTAL_WEIGHT) revert InvalidWeights();
        for (uint256 i = 0; i < n; ++i) {
            _unsee(inits[i].token);
        }
    }

    /// @dev Marks `token` as seen in this transaction and returns whether it already was. The mark lives in transient
    ///      storage at the token's address as its key; nothing else here uses transient storage, a revert undoes the
    ///      mark with the rest of the call, and {_unsee} clears it, so a second creation in one transaction starts
    ///      with none.
    function _seen(address token) private returns (bool already) {
        // Transient storage has no Solidity mapping in 0.8.28: tload and tstore only, keyed by the token's address.
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            already := tload(token)
            tstore(token, 1)
        }
    }

    /// @dev Clears {_seen}'s mark of `token`.
    function _unsee(address token) private {
        // As {_seen}: tstore, at the token's address.
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            tstore(token, 0)
        }
    }

    /// @dev Each component's share of the new index's value at Pyth's prices lies within MAX_WEIGHT_DEVIATION of its
    ///      weight, relative to the weight, or the creation reverts OffWeights: the units the creator names start the
    ///      index on its weights, as a price can show it. Each unit is valued as arriving, Pyth's price less its
    ///      confidence; a stale or missing price reverts, so a creator posts Pyth's update first. Exact in integers:
    ///      a value is at most 2^214 (MAX_UNITS times the reader's largest value), so the sums and products below fit.
    function _checkOnWeights(IWeightedHub.ComponentInit[] memory inits) private view {
        uint256 n = inits.length;
        address[] memory tokens = new address[](n);
        IPythPrices.PriceFeed[] memory feeds = new IPythPrices.PriceFeed[](n);
        uint8[] memory decimals = new uint8[](n);
        for (uint256 i = 0; i < n; ++i) {
            address token = inits[i].token;
            (tokens[i], feeds[i], decimals[i]) = (token, _priceFeeds[token], decimalsOf[token]);
        }
        uint256[] memory values = IPythPrices(PRICES).valuesWith(tokens, feeds, decimals, false);
        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            values[i] *= inits[i].units;
            total += values[i];
        }
        for (uint256 i = 0; i < n; ++i) {
            uint256 share = values[i] * TOTAL_WEIGHT;
            uint256 target = inits[i].weight * total;
            uint256 gap = share > target ? share - target : target - share;
            // the allowance rounds down, against the creator
            if (gap > Math.mulDiv(target, MAX_WEIGHT_DEVIATION, 1e18)) {
                revert OffWeights(inits[i].token, inits[i].weight, share / total);
            }
        }
    }

    /// @dev The most units a component of `decimals` may start with: MAX_WHOLE_TOKENS whole tokens per share, and never
    ///      above MAX_UNITS. So one wei-share backs a negligible amount of every component, and no fee's rounding to
    ///      whole wei-shares is worth anything (RX-5).
    function _maxUnits(uint8 decimals) private pure returns (uint256) {
        uint256 whole = MAX_WHOLE_TOKENS * 10 ** decimals;
        return whole < MAX_UNITS ? whole : MAX_UNITS;
    }

    /// @dev The components in the form the index's initializer takes.
    function _componentInits(ComponentSpec[] calldata components)
        private
        pure
        returns (IWeightedHub.ComponentInit[] memory inits)
    {
        uint256 n = components.length;
        inits = new IWeightedHub.ComponentInit[](n);
        for (uint256 i = 0; i < n; ++i) {
            ComponentSpec calldata c = components[i];
            inits[i] = IWeightedHub.ComponentInit({token: c.token, units: c.units, weight: c.weight});
        }
    }

    /// @dev The CREATE2 salt: a hash of the creator, the hashed name and symbol, and {_contentsHash}.
    function _salt(address creator, bytes32 nameHash, bytes32 symbolHash, bytes32 contents)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(creator, nameHash, symbolHash, contents));
    }

    /// @dev The hash of the index's terms: every component's token, units and weight, and the config (fee rates,
    ///      referral share, rebalance interval).
    function _contentsHash(IWeightedHub.ComponentInit[] memory inits, IWeightedHub.Config memory config)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(keccak256(abi.encode(inits)), keccak256(abi.encode(config))));
    }

    // ---------------------------------------------------------------------
    // Whitelist
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function proposeListing(address token) external onlyOwner {
        if (token.code.length == 0) revert NotAContract(token);
        // Read once, here, and never again: it bounds the units an index may start this token with, and the factory
        // calls no token after this (RT-01). The proposal's delay makes it public before it counts.
        // aderyn-fp-next-line(reentrancy-state-change)
        uint8 decimals = IERC20Metadata(token).decimals();
        if (decimals > MAX_DECIMALS) revert InvalidDecimals(token, decimals);
        _proposeListing(token, decimals);
    }

    /// @dev Records a listing proposal, with the decimals the caller just read from the token.
    function _proposeListing(address token, uint8 decimals) internal {
        if (isWhitelisted[token]) revert AlreadyListed(token);
        uint256 pending = listingEta[token];
        if (pending != 0 && block.timestamp <= pending + PROPOSAL_WINDOW) revert ListingPending(token, pending);

        uint256 eta = block.timestamp + LISTING_DELAY;
        listingEta[token] = eta;
        _pendingDecimals[token] = decimals;
        emit ListingProposed(token, eta, decimals);
    }

    /// @inheritdoc IWeightedIndexFactory
    function cancelListing(address token) external onlyOwnerOrGuardian {
        if (listingEta[token] == 0) revert NoPendingListing(token);
        delete listingEta[token];
        delete _pendingDecimals[token];
        emit ListingCancelled(token);
    }

    /// @inheritdoc IWeightedIndexFactory
    function executeListing(address token) external {
        uint256 eta = listingEta[token];
        if (eta == 0) revert NoPendingListing(token);
        if (block.timestamp < eta) revert ListingNotReady(token, eta);
        if (block.timestamp > eta + PROPOSAL_WINDOW) revert ListingExpired(token, eta + PROPOSAL_WINDOW);

        uint8 decimals = _pendingDecimals[token];
        delete listingEta[token];
        delete _pendingDecimals[token];
        decimalsOf[token] = decimals;
        emit TokenDecimalsSet(token, decimals);

        // The token is never already whitelisted here: a proposal is refused for a whitelisted token (AlreadyListed),
        // and only this function whitelists one, clearing its proposal as it does.
        isWhitelisted[token] = true;
        _whitelist.push(token);
        _whitelistPos[token] = _whitelist.length;
        emit TokenWhitelisted(token, true);
    }

    /// @inheritdoc IWeightedIndexFactory
    function delist(address token) external onlyOwnerOrGuardian {
        if (!isWhitelisted[token]) revert NotWhitelisted(token);

        isWhitelisted[token] = false;
        uint256 pos = _whitelistPos[token] - 1;
        uint256 last = _whitelist.length - 1;
        if (pos != last) {
            address moved = _whitelist[last];
            _whitelist[pos] = moved;
            _whitelistPos[moved] = pos + 1;
        }
        _whitelist.pop();
        delete _whitelistPos[token];
        emit TokenWhitelisted(token, false);
    }

    // ---------------------------------------------------------------------
    // Changing an index's weights
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function pendingWeights(address index) external view returns (uint256[] memory weights, uint256 eta) {
        return (_pendingWeights[index], weightsEta[index]);
    }

    /// @inheritdoc IWeightedIndexFactory
    /// @dev Only on a factory with an oracle: a change opens a distance between the units and the weights, which Pyth's
    ///      check on every fill bounds to its tolerance; on units alone the creator could take that distance through
    ///      its own auction (the design rule "An index is created on its weights").
    function proposeWeights(address index, uint256[] calldata weights) external {
        if (!isIndex[index]) revert NotIndex(index);
        if (msg.sender != creatorOf[index]) revert Unauthorized(msg.sender);
        if (PRICES == address(0)) revert NoOracle();
        // A view on our own clone, by STATICCALL: nothing it reaches can change state, so nothing re-enters.
        // aderyn-fp-next-line(reentrancy-state-change)
        if (weights.length != IWeightedHub(index).componentWeights().length) revert InvalidWeights();
        uint256 total = 0;
        for (uint256 i = 0; i < weights.length; ++i) {
            uint256 weight = weights[i];
            if (weight == 0 || weight > TOTAL_WEIGHT) revert InvalidWeights();
            total += weight;
        }
        if (total != TOTAL_WEIGHT) revert InvalidWeights();
        uint256 eta = block.timestamp + WEIGHTS_DELAY;
        _pendingWeights[index] = weights;
        weightsEta[index] = eta;
        emit WeightsProposed(index, weights, eta);
    }

    /// @inheritdoc IWeightedIndexFactory
    function cancelWeights(address index) external {
        if (msg.sender != creatorOf[index] && !isOwnerOrGuardian(msg.sender)) revert Unauthorized(msg.sender);
        if (weightsEta[index] == 0) revert NoPendingWeights(index);
        delete weightsEta[index];
        delete _pendingWeights[index];
        emit WeightsCancelled(index);
    }

    /// @inheritdoc IWeightedIndexFactory
    // The index emits WeightsChanged in the same call, as the one place the weights change.
    // aderyn-fp-next-line(state-change-without-event)
    function executeWeights(address index) external nonReentrant {
        uint256 eta = weightsEta[index];
        if (eta == 0) revert NoPendingWeights(index);
        if (block.timestamp < eta) revert WeightsNotReady(index, eta);
        if (block.timestamp > eta + PROPOSAL_WINDOW) revert WeightsExpired(index, eta + PROPOSAL_WINDOW);
        uint256[] memory weights = _pendingWeights[index];
        delete weightsEta[index];
        delete _pendingWeights[index];
        IWeightedHub(index).setWeights(weights);
    }

    // ---------------------------------------------------------------------
    // Price feeds
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function priceFeedOf(address token) external view returns (IPythPrices.PriceFeed memory) {
        return _priceFeeds[token];
    }

    /// @inheritdoc IWeightedIndexFactory
    function pendingPriceFeed(address token) external view returns (IPythPrices.PriceFeed memory feed, uint256 eta) {
        return (_pendingPriceFeeds[token], _priceFeedEta[token]);
    }

    /// @inheritdoc IWeightedIndexFactory
    function proposePriceFeed(address token, IPythPrices.PriceFeed calldata feed) external onlyOwner {
        address prices = PRICES;
        if (prices == address(0)) revert NoOracle();
        // Pyth's contract on a chain knows a feed only once someone has posted an update of it there, so the factory
        // does not ask: on BNB Chain 343 of the 364 feeds had never been posted, and a creation and a fill
        // each post their own. A wrong id can only refuse, as a missing price does.
        if ((feed.kind == IPythPrices.FeedKind.None) != (feed.id == bytes32(0))) revert InvalidPriceFeed(feed.id);
        uint256 pending = _priceFeedEta[token];
        if (pending != 0 && block.timestamp <= pending + PROPOSAL_WINDOW) revert PriceFeedPending(token, pending);

        uint256 eta = block.timestamp + LISTING_DELAY;
        _priceFeedEta[token] = eta;
        _pendingPriceFeeds[token] = feed;
        emit PriceFeedProposed(token, feed.id, feed.kind, eta);
    }

    /// @inheritdoc IWeightedIndexFactory
    function cancelPriceFeed(address token) external onlyOwnerOrGuardian {
        if (_priceFeedEta[token] == 0) revert NoPendingPriceFeed(token);
        delete _priceFeedEta[token];
        delete _pendingPriceFeeds[token];
        emit PriceFeedCancelled(token);
    }

    /// @inheritdoc IWeightedIndexFactory
    function executePriceFeed(address token) external {
        uint256 eta = _priceFeedEta[token];
        if (eta == 0) revert NoPendingPriceFeed(token);
        if (block.timestamp < eta) revert PriceFeedNotReady(token, eta);
        if (block.timestamp > eta + PROPOSAL_WINDOW) revert PriceFeedExpired(token, eta + PROPOSAL_WINDOW);

        IPythPrices.PriceFeed memory feed = _pendingPriceFeeds[token];
        delete _priceFeedEta[token];
        delete _pendingPriceFeeds[token];
        _priceFeeds[token] = feed;
        emit PriceFeedSet(token, feed.id, feed.kind);
    }

    // ---------------------------------------------------------------------
    // Guardian
    // ---------------------------------------------------------------------

    // Zero is allowed on purpose: once executed, it removes the guardian role.
    // forge-lint: disable-next-item(missing-zero-check)
    /// @inheritdoc IWeightedIndexFactory
    function proposeGuardian(address newGuardian) external onlyOwner {
        if (pendingGuardianEta != 0) emit GuardianChangeCancelled(pendingGuardian);
        uint256 eta = block.timestamp + GUARDIAN_DELAY;
        // Zero is allowed on purpose, as above.
        // aderyn-fp-next-line(state-no-address-check)
        pendingGuardian = newGuardian;
        pendingGuardianEta = eta;
        emit GuardianProposed(newGuardian, eta);
    }

    /// @inheritdoc IWeightedIndexFactory
    function cancelGuardianChange() external {
        if (pendingGuardianEta == 0) revert NoPendingGuardianChange();
        address cancelled = pendingGuardian;
        // The owner can cancel any guardian change. The guardian can cancel only its own removal. So the owner can
        // still replace a hostile or keyless guardian, but cannot leave the factory with no guardian over its
        // objection.
        if (msg.sender != owner() && !(cancelled == address(0) && msg.sender == guardian && msg.sender != address(0))) {
            revert Unauthorized(msg.sender);
        }
        delete pendingGuardian;
        delete pendingGuardianEta;
        emit GuardianChangeCancelled(cancelled);
    }

    /// @inheritdoc IWeightedIndexFactory
    function executeGuardianChange() external {
        uint256 eta = pendingGuardianEta;
        if (eta == 0) revert NoPendingGuardianChange();
        if (block.timestamp < eta) revert GuardianChangeNotReady(eta);
        if (block.timestamp > eta + PROPOSAL_WINDOW) revert GuardianChangeExpired(eta + PROPOSAL_WINDOW);

        address previous = guardian;
        address next = pendingGuardian;
        guardian = next;
        delete pendingGuardian;
        delete pendingGuardianEta;
        emit GuardianSet(previous, next);
    }

    /// @notice Disabled: without an owner, the whitelist could never change again.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function whitelistedTokens() external view returns (address[] memory) {
        return _whitelist;
    }

    /// @inheritdoc IWeightedIndexFactory
    function maxUnitsOf(address token) external view returns (uint256) {
        return _maxUnits(decimalsOf[token]);
    }

    /// @inheritdoc IWeightedIndexFactory
    function listingPending(address token) external view returns (bool) {
        uint256 eta = listingEta[token];
        return eta != 0 && block.timestamp <= eta + PROPOSAL_WINDOW;
    }

    /// @inheritdoc IWeightedIndexFactory
    function guardianChangePending() external view returns (bool) {
        uint256 eta = pendingGuardianEta;
        return eta != 0 && block.timestamp <= eta + PROPOSAL_WINDOW;
    }

    /// @inheritdoc IWeightedIndexFactory
    function allIndexesLength() external view returns (uint256) {
        return allIndexes.length;
    }
}
