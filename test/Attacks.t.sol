// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedMath} from "../src/WeightedMath.sol";
import {MintRequests} from "../src/MintRequests.sol";
import {IMintRequests} from "../src/interfaces/IMintRequests.sol";
import {IIndexHub} from "../src/interfaces/IIndexHub.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IPythPrices} from "../src/interfaces/IPythPrices.sol";
import {IRebalanceExecutor} from "../src/interfaces/IRebalanceExecutor.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {WeightedTest} from "./WeightedTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockVault} from "./mocks/MockPricedTokens.sol";

/// @notice Fills a rebalance honestly, and from inside the index's callback tries every other door of the protocol:
///         the factory's two calls that reach back into the index, and the request escrow, which calls no index
///         function at all on a fill. It records how each attempt ended and what the index's views said meanwhile.
contract RaidingExecutor is IRebalanceExecutor {
    struct Outcome {
        bool opened;
        bytes answer;
    }

    WeightedIndexFactory internal immutable FACTORY;
    MintRequests internal immutable REQUESTS;
    uint256 internal _mintRequest;
    uint256 internal _redeemRequest;
    Outcome[] internal _outcomes;
    uint256[] internal _redeemSeen;
    uint256 public nonceSeen;

    constructor(WeightedIndexFactory factory, MintRequests requests) {
        FACTORY = factory;
        REQUESTS = requests;
    }

    function aim(uint256 mintRequest, uint256 redeemRequest) external {
        _mintRequest = mintRequest;
        _redeemRequest = redeemRequest;
    }

    function execute(IWeightedHub index, uint256[] calldata newUnits) external {
        index.executeRebalance(newUnits, "");
    }

    function outcomes() external view returns (Outcome[] memory) {
        return _outcomes;
    }

    function redeemSeen() external view returns (uint256[] memory) {
        return _redeemSeen;
    }

    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address index = msg.sender;
        _raid(address(FACTORY), abi.encodeCall(WeightedIndexFactory.executeWeights, (index)));
        _raid(address(FACTORY), abi.encodeCall(WeightedIndexFactory.acceptCreator, (index)));
        _raid(address(REQUESTS), abi.encodeWithSignature("fill(uint256,uint256)", _mintRequest, 1e18));
        _raid(address(REQUESTS), abi.encodeWithSignature("fill(uint256,uint256)", _redeemRequest, 1e6));
        _redeemSeen = IIndexHub(index).previewRedeem(1e18);
        nonceSeen = IIndexHub(index).rebalanceNonce();

        address[] memory tokens = IIndexHub(index).componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsIn[i] != 0) MockERC20(tokens[i]).mint(index, amountsIn[i]);
        }
    }

    function _raid(address target, bytes memory data) private {
        (bool opened, bytes memory answer) = target.call(data);
        _outcomes.push(Outcome(opened, answer));
    }
}

/// @notice Sends three creations in one call, and so in one transaction, where transient storage lives on between
///         them: one the factory refuses for naming a token twice, then two of those same tokens. Foundry clears
///         transient storage between a test's own calls, so only a contract shows what one transaction carries over.
contract BatchCreator {
    function createAfterARefusal(
        WeightedIndexFactory factory,
        IWeightedIndexFactory.ComponentSpec[] calldata twice,
        IWeightedIndexFactory.ComponentSpec[] calldata specs,
        IWeightedIndexFactory.IndexParams calldata params
    ) external returns (bool accepted, bytes memory answer, address first, address second) {
        (accepted, answer) = address(factory).call(abi.encodeCall(factory.createIndex, ("Twice", "TWC", twice, params)));
        first = factory.createIndex("First", "ONE", specs, params);
        second = factory.createIndex("Second", "TWO", specs, params);
    }
}

/// @notice The hacks of 2016 to 2026, replayed against this build (`audits/internal/attack-replay.md`, ids `HK-…`).
///         Each test is one class of attack that took funds somewhere, aimed at the contract here that it would hit.
///         A class another suite already replays is named in the record with that suite's test, not repeated here.
/// @dev The factory has its oracle, so both of a fill's checks are live, as on a mainnet.
contract AttacksTest is WeightedTest {
    uint256 constant SHARES = 100e18;
    bytes32 constant ETH_FEED = keccak256("ETH/USD");
    bytes32 constant BTC_FEED = keccak256("BTC/USD");
    bytes32 constant USD_FEED = keccak256("USD/USD");

    /// @dev The selectors of errors declared in OpenZeppelin's contracts, by their signatures.
    bytes4 constant REENTERED = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
    bytes4 constant NOT_OWNER = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
    bytes4 constant INITIALIZED = bytes4(keccak256("InvalidInitialization()"));
    bytes4 constant NO_ALLOWANCE = bytes4(keccak256("ERC20InsufficientAllowance(address,uint256,uint256)"));
    bytes4 constant NO_BALANCE = bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)"));
    bytes4 constant BAD_SIGNER = bytes4(keccak256("ERC2612InvalidSigner(address,address)"));
    bytes4 constant BAD_SIGNATURE = bytes4(keccak256("ECDSAInvalidSignature()"));
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @dev One state-changing function, called by an account with no role, and the error that must refuse it.
    struct Door {
        bytes data;
        bytes4 refusal;
    }

    MockPyth pyth;
    IPythPrices prices;
    WeightedMath math;
    WeightedHub index;
    MintRequests requests;
    MockERC20 usdc;
    MockERC20 usdt;
    address mallory = makeAddr("mallory");

    function setUp() public {
        vm.warp(1_800_000_000);
        pyth = new MockPyth();
        factory = new WeightedIndexFactory(owner, guardian, address(pyth), address(new WeightedMath()), address(0));
        prices = IPythPrices(factory.PRICES());
        _approveCreator(creator);
        eth = new MockERC20("Ether", "ETH", 18);
        btc = new MockERC20("Bitcoin", "BTC", 8);
        usd = new MockERC20("Dollar", "USD", 6);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 6);
        _listAll();
        _post(ETH_PRICE, BTC_PRICE, USD_PRICE);
        _setFeed(address(eth), ETH_FEED, IPythPrices.FeedKind.Token);
        _setFeed(address(btc), BTC_FEED, IPythPrices.FeedKind.Token);
        _setFeed(address(usd), USD_FEED, IPythPrices.FeedKind.Token);
        index = _create(_defaultSpecs());
        math = WeightedMath(index.MATH());
        _issue(index, alice, SHARES);
        requests = new MintRequests(address(factory), address(usdc), address(usdt));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Sets `token`'s feed through the factory's timelock.
    function _setFeed(address token, bytes32 id, IPythPrices.FeedKind kind) internal {
        vm.prank(owner);
        factory.proposePriceFeed(token, IPythPrices.PriceFeed({id: id, kind: kind}));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executePriceFeed(token);
    }

    /// @dev Posts the three default coins' prices, in dollars per whole token, as fresh at every block.
    function _post(uint256 ethDollars, uint256 btcDollars, uint256 usdDollars) internal {
        pyth.setLivePrice(ETH_FEED, int64(int256(ethDollars * 1e8)), 0, -8);
        pyth.setLivePrice(BTC_FEED, int64(int256(btcDollars * 1e8)), 0, -8);
        pyth.setLivePrice(USD_FEED, int64(int256(usdDollars * 1e8)), 0, -8);
    }

    /// @dev Starts a rebalance of `target` as soon as anyone may and moves `into` seconds into its auction.
    function _open(WeightedHub target, uint256 into) internal {
        vm.warp(target.earliestRebalance());
        target.startRebalance(0);
        (uint256 eta,) = target.pendingRebalance();
        vm.warp(eta + into);
    }

    function _three(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory list) {
        list = new uint256[](3);
        (list[0], list[1], list[2]) = (a, b, c);
    }

    /// @dev `target`'s balance of each of its components.
    function _held(WeightedHub target) internal view returns (uint256[] memory held) {
        return _balances(target, address(target));
    }

    /// @dev `account`'s balance of each of `target`'s components.
    function _balances(WeightedHub target, address account) internal view returns (uint256[] memory balances) {
        address[] memory tokens = target.componentTokens();
        balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            balances[i] = MockERC20(tokens[i]).balanceOf(account);
        }
    }

    /// @dev The backing invariant, at the scale an accrual now would leave: every component covers the shares that
    ///      exist, the pending fee's among them, and the open claims.
    function _assertBacked(WeightedHub target) internal view {
        address[] memory tokens = target.componentTokens();
        uint256[] memory units = target.recordedUnits();
        (uint256 feeShares, uint256 scale) = target.pendingStreamingFee();
        uint256 supply = target.totalSupply() + feeShares;
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 owed = Math.mulDiv(supply, units[i] * scale, 1e36) + target.totalClaims(tokens[i]);
            assertGe(MockERC20(tokens[i]).balanceOf(address(target)), owed, "a leg is short of its backing");
        }
    }

    /// @dev How many times `needle` occurs in the file at `path`, by forge's own string split.
    function _occurrences(string memory path, string memory needle) internal view returns (uint256) {
        return vm.split(vm.readFile(path), needle).length - 1;
    }

    /// @dev Calls `target` with each door's calldata from `stranger`, and requires each call to be refused with that
    ///      door's error.
    function _knock(address target, Door[] memory doors) internal {
        for (uint256 i = 0; i < doors.length; ++i) {
            vm.prank(stranger);
            (bool opened, bytes memory answer) = target.call(doors[i].data);
            assertFalse(opened, "a door opened to a stranger");
            assertEq(bytes4(answer), doors[i].refusal, "refused for another reason");
        }
    }

    /// @dev An index with every fee at its cap: 1% and 0.25% on a mint and a burn, 5% and 1% a year, the whole of the
    ///      platform's part to a referrer.
    function _feeIndex() internal returns (WeightedHub) {
        vm.prank(owner);
        factory.setFeePolicy(25, 100, 10_000, makeAddr("platform"), 0);
        IWeightedIndexFactory.IndexParams memory params = _params();
        params.creatorFeeBps = 100;
        params.creatorStreamingBps = 500;
        return _create(_defaultSpecs(), params);
    }

    /// @dev A permit of `value` from `signer` to `spender` on `target`, signed with `key` for `target`'s own domain.
    function _signPermit(WeightedHub target, uint256 key, address signer, address spender, uint256 value)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, signer, spender, value, target.nonces(signer), type(uint256).max)
        );
        return vm.sign(key, keccak256(abi.encodePacked("\x19\x01", target.DOMAIN_SEPARATOR(), structHash)));
    }

    // ---------------------------------------------------------------------
    // HK-02: a transient mark left behind (SIR.trading, March 2025)
    // ---------------------------------------------------------------------

    /// @dev SIR.trading kept its swap callback's caller in a transient slot that a later step of the same transaction
    ///      overwrote with an amount the attacker chose. Here the factory keeps one transient mark per token while it
    ///      looks for a duplicate. Nothing else in the factory uses transient storage, so no mark can stand for
    ///      anything but a token seen; and no mark outlives its creation: a refused one dies with its revert, an
    ///      accepted one is cleared, so a later creation in the same transaction is judged on its own tokens alone.
    function test_HK02_noMarkOfOneCreationReachesTheNext() public {
        BatchCreator batch = new BatchCreator();
        _approveCreator(address(batch));
        IWeightedIndexFactory.ComponentSpec[] memory twice = _defaultSpecs();
        twice[2] = _spec(address(eth), 2000, ETH_UNITS);

        (bool accepted, bytes memory answer, address first, address second) =
            batch.createAfterARefusal(factory, twice, _defaultSpecs(), _params());
        assertFalse(accepted, "a token named twice made an index");
        assertEq(answer, abi.encodeWithSelector(IWeightedIndexFactory.DuplicateToken.selector, address(eth)));
        assertTrue(factory.isIndex(first) && factory.isIndex(second), "a mark outlived its creation");

        // And the marks are the factory's only transient storage, with its only assembly: two blocks, a read and
        // two writes.
        assertEq(_occurrences("src/WeightedIndexFactory.sol", "assembly ("), 2);
        assertEq(_occurrences("src/WeightedIndexFactory.sol", "tload("), 1);
        assertEq(_occurrences("src/WeightedIndexFactory.sol", "tstore("), 2);
    }

    // ---------------------------------------------------------------------
    // HK-03: a standing approval spent by someone else (SwapNet and Aperture, January 2026; Ekubo, May 2026)
    // ---------------------------------------------------------------------

    /// @dev Those contracts held users' approvals and could be made to call a token with a `from` the caller chose.
    ///      A creator approves its index before the index exists, at the address the factory predicts. The address
    ///      commits to the creator, so another approved creator sending the same creation gets another address and
    ///      pays for its own first issue; the approval is spent by its owner's creation and by nothing else.
    function test_HK03_anApprovalGivenToAnIndexToBeIsSpentByItsOwnCreationAlone() public {
        _approveCreator(mallory);
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        address predicted = factory.predictIndexAddress(creator, "Fund", "FND", specs, _params());
        uint256[] memory basket = _three(ETH_UNITS * 10, BTC_UNITS * 10, USD_UNITS * 10);
        eth.mint(creator, basket[0]);
        btc.mint(creator, basket[1]);
        usd.mint(creator, basket[2]);
        vm.startPrank(creator);
        eth.approve(predicted, basket[0]);
        btc.approve(predicted, basket[1]);
        usd.approve(predicted, basket[2]);
        vm.stopPrank();

        // The same creation from another approved creator pulls from that creator, who has approved nothing.
        vm.expectPartialRevert(NO_ALLOWANCE);
        vm.prank(mallory);
        factory.createAndIssue("Fund", "FND", specs, _params(), 10e18, mallory);

        // Without a first issue it lands, at another address, and the creator's is still free.
        vm.prank(mallory);
        address copy = factory.createIndex("Fund", "FND", specs, _params());
        assertTrue(copy != predicted, "the copy took the creator's address");
        assertEq(predicted.code.length, 0);
        assertEq(eth.balanceOf(creator), basket[0], "the creator paid for someone else's index");

        vm.prank(creator);
        address fund = factory.createAndIssue("Fund", "FND", specs, _params(), 10e18, creator);
        assertEq(fund, predicted);
        assertEq(WeightedHub(fund).balanceOf(creator), 10e18);
        assertEq(_held(WeightedHub(fund)), basket, "the creation pulled exactly its basket");
        assertEq(eth.allowance(creator, predicted), 0);
    }

    /// @dev The same class, read off the source: every pull in `src/` names the caller as its payer, with one
    ///      exception, the index's own issue, whose payer is the caller or, in a creation, the creator the factory
    ///      names, which is the factory's own caller.
    function test_HK03_everyPullIsFromTheCaller() public view {
        string[3] memory callers = ["src/IndexZap.sol", "src/BasketBuilder.sol", "src/MintRequests.sol"];
        for (uint256 i = 0; i < callers.length; ++i) {
            assertEq(_occurrences(callers[i], "safeTransferFrom("), 2);
            assertEq(_occurrences(callers[i], "safeTransferFrom(msg.sender,"), 2);
        }
        string[4] memory none = [
            "src/WeightedIndexFactory.sol", "src/WeightedMath.sol", "src/PythPrices.sol", "src/UniversalRouterSwaps.sol"
        ];
        for (uint256 i = 0; i < none.length; ++i) {
            assertEq(_occurrences(none[i], "ransferFrom("), 0);
        }
        // The index: one pull, of the payer {_issue} was given, which every caller but the initializer gives as
        // itself; and the initializer's comes from the factory, which names its own caller.
        assertEq(_occurrences("src/WeightedHub.sol", "ransferFrom("), 1);
        assertEq(_occurrences("src/WeightedHub.sol", "safeTransferFrom(from, address(this), amounts[i])"), 1);
        assertEq(_occurrences("src/WeightedHub.sol", "_pullBasket("), 2, "its definition and its one call");
        assertEq(_occurrences("src/WeightedHub.sol", "_pullBasket(from, amounts, supply, scale)"), 1);
        assertEq(_occurrences("src/WeightedHub.sol", "_issue(msg.sender,"), 2);
        assertEq(_occurrences("src/WeightedHub.sol", "_issue(first_.from,"), 1);
        assertEq(_occurrences("src/WeightedHub.sol", "_issue("), 4, "three calls and the definition");
        assertEq(_occurrences("src/WeightedIndexFactory.sol", "IWeightedHub.FirstIssue("), 2);
        assertEq(_occurrences("src/WeightedIndexFactory.sol", "IWeightedHub.FirstIssue(msg.sender, shares, to)"), 1);
        assertEq(_occurrences("src/WeightedIndexFactory.sol", "IWeightedHub.FirstIssue(address(0), 0, address(0))"), 1);
    }

    // ---------------------------------------------------------------------
    // HK-04: a stolen key (Bybit, February 2025; Resolv, IoTeX and Step, 2026; KelpDAO and Drift, April 2026)
    // ---------------------------------------------------------------------

    /// @dev In those, a key that could upgrade a contract or mint without a bound took everything at once. Here the
    ///      owner's key, the guardian's and the index's creator's are all stolen together and every power of the
    ///      three is used. Not one token leaves the index, its terms stay what they were, and its holder leaves with
    ///      the whole basket. What the keys do change: minting stops, and the weights change behind seven days.
    function test_HK04_everyStolenKeyTogetherMovesNoTokenAndBlocksNoExit() public {
        address thief = makeAddr("thief");
        uint256[] memory held = _held(index);
        uint256[] memory units = index.recordedUnits();
        bytes memory terms = abi.encode(index.config());
        MockERC20 planted = new MockERC20("Planted", "PLANT", 18);

        vm.prank(creator);
        factory.transferCreator(address(index), thief);
        vm.startPrank(thief);
        factory.acceptCreator(address(index));
        factory.proposeWeights(address(index), _three(9998, 1, 1));
        vm.stopPrank();

        vm.startPrank(owner);
        factory.setFeePolicy(25, 100, 10_000, thief, 1 ether);
        factory.setApprovedCreator(thief, true);
        factory.pauseMinting(address(0));
        factory.proposeGuardian(thief);
        factory.proposeListing(address(planted));
        factory.proposePriceFeed(address(eth), IPythPrices.PriceFeed(keccak256("PLANTED"), IPythPrices.FeedKind.Token));
        factory.transferOwnership(thief);
        vm.stopPrank();
        vm.prank(thief);
        factory.acceptOwnership();

        vm.startPrank(guardian);
        factory.delist(address(eth));
        factory.delist(address(btc));
        factory.delist(address(usd));
        vm.stopPrank();

        // Every timelock runs out, and the thief holds all three roles.
        vm.warp(block.timestamp + factory.GUARDIAN_DELAY());
        factory.executeGuardianChange();
        factory.executeListing(address(planted));
        factory.executePriceFeed(address(eth));
        factory.executeWeights(address(index));
        assertEq(factory.owner(), thief);
        assertEq(factory.guardian(), thief);
        assertEq(factory.creatorOf(address(index)), thief);

        assertEq(_held(index), held, "a key moved a token");
        assertEq(index.recordedUnits(), units, "a key moved the units");
        assertEq(abi.encode(index.config()), terms, "a key changed the index's terms");
        assertEq(
            index.componentWeights(), _three(9998, 1, 1), "the creator's key changes the weights, after its notice"
        );
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.NotAllowedMinter.selector, alice));
        vm.prank(alice);
        index.issue(1e18, alice);

        uint256[] memory due = index.previewRedeem(SHARES);
        vm.prank(alice);
        index.redeem(SHARES, alice);
        assertEq(_balances(index, alice), due);
        assertEq(due, held, "the last holder leaves with everything the index held");
    }

    /// @dev The worst the three keys do together, shown rather than left to a reader: seven days after a public change
    ///      of weights, with a feed the thief planted, the thief fills its own auction at the last second and takes a
    ///      fifth of two legs for next to nothing. A fifth is the cap: one unit more is refused on units alone, which
    ///      no key and no price can widen. The holder who left during the notice lost nothing (the test above).
    function test_HK04_theWorstEveryKeyTogetherTakesIsAFifthOfALegAfterAWeeksNotice() public {
        address thief = makeAddr("thief");
        RaidingExecutor raider = new RaidingExecutor(factory, requests);
        bytes32 plantedFeed = keccak256("PLANTED");
        vm.startPrank(creator);
        factory.proposeWeights(address(index), _three(9998, 1, 1));
        vm.stopPrank();
        vm.prank(owner);
        factory.proposePriceFeed(address(eth), IPythPrices.PriceFeed(plantedFeed, IPythPrices.FeedKind.Token));
        vm.warp(block.timestamp + factory.WEIGHTS_DELAY());
        factory.executeWeights(address(index));
        factory.executePriceFeed(address(eth));
        // The planted feed calls one ETH twenty billion dollars, so a sliver of it outweighs what the fill takes.
        pyth.setLivePrice(plantedFeed, 2e18, 0, -8);

        vm.prank(thief);
        index.startRebalance(0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());
        uint256[] memory units = index.recordedUnits();
        uint256[] memory greedy = _three(units[0] + units[0] / 20_000, units[1] * 4 / 5, units[2] * 4 / 5);

        uint256[] memory tooGreedy = _three(greedy[0], greedy[1] - 1, greedy[2]);
        vm.expectPartialRevert(IWeightedHub.LegOutOfBounds.selector);
        raider.execute(index, tooGreedy);

        uint256[] memory held = _held(index);
        raider.execute(index, greedy);
        uint256[] memory left = _held(index);
        assertEq(left[1], held[1] - held[1] / 5, "a fifth of the BTC, and no more");
        assertEq(left[2], held[2] - held[2] / 5, "a fifth of the dollars, and no more");
        assertGt(left[0], held[0], "the fill still had to add to the leg the weights favour");
        _assertBacked(index);

        // What is left is the holder's, whole.
        uint256[] memory due = index.previewRedeem(SHARES);
        vm.prank(alice);
        index.redeem(SHARES, alice);
        assertEq(_balances(index, alice), due);
        assertEq(due, left);
    }

    /// @dev No contract here can be upgraded, destroyed or pointed elsewhere, and none makes a call whose target or
    ///      bytes a caller chooses: the source of every contract that holds funds has no delegatecall, no
    ///      self-destruct, no low-level call, no `tx.origin` and no signature recovery of its own. An index is 45
    ///      bytes that forward to one implementation, whose address is part of those bytes.
    function test_HK04_noContractCanBeUpgradedOrAimed() public view {
        string[8] memory sources = [
            "src/WeightedHub.sol",
            "src/WeightedIndexFactory.sol",
            "src/WeightedMath.sol",
            "src/PythPrices.sol",
            "src/IndexZap.sol",
            "src/BasketBuilder.sol",
            "src/MintRequests.sol",
            "src/UniversalRouterSwaps.sol"
        ];
        string[9] memory banned = [
            "delegatecall",
            "selfdestruct",
            "callcode",
            "tx.origin",
            "ecrecover",
            ".call(",
            ".call{",
            "upgradeTo",
            "sstore("
        ];
        for (uint256 i = 0; i < sources.length; ++i) {
            for (uint256 j = 0; j < banned.length; ++j) {
                assertEq(_occurrences(sources[i], banned[j]), 0, string.concat(sources[i], " has ", banned[j]));
            }
        }
        bytes memory forwarder =
            abi.encodePacked(hex"363d3d373d3d3d363d73", factory.IMPLEMENTATION(), hex"5af43d82803e903d91602b57fd5bf3");
        assertEq(address(index).code, forwarder);
    }

    // ---------------------------------------------------------------------
    // HK-05: rounding that pays the attacker (Balancer V2, November 2025; Thetanuts, June 2026)
    // ---------------------------------------------------------------------

    /// @dev Balancer's pools lost over a hundred million dollars to a rounding direction that favoured the trader on
    ///      amounts of a few wei, repeated. Here an attacker mints and burns dust, whole shares and odd amounts, two
    ///      hundred times, through both exits, while the streaming fee moves the scale under it: it never ends a
    ///      round with a wei more of any coin than it began with, and the index never holds a wei less.
    function test_HK05_cyclingDustThroughEveryRoundingTakesNothing() public {
        _cycleDust(index, 200);
        _cycleDust(_feeIndex(), 200);
    }

    function _cycleDust(WeightedHub target, uint256 rounds) internal {
        address[] memory tokens = target.componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(mallory, 1e30);
            vm.prank(mallory);
            MockERC20(tokens[i]).approve(address(target), type(uint256).max);
        }
        uint256[] memory hadIndex = _held(target);
        uint256[] memory hadMallory = _balances(target, mallory);

        vm.startPrank(mallory);
        for (uint256 round = 0; round < rounds; ++round) {
            uint256 shares = 1 + (round * 7919) % 1e9 + (round % 7 == 0 ? round * 1e15 : 0);
            target.issue(shares, mallory);
            vm.warp(block.timestamp + 1 hours);
            uint256 all = target.balanceOf(mallory);
            if (round % 2 == 0) {
                target.redeem(all, mallory);
            } else {
                target.redeemSkipping(all, mallory, 1);
                if (target.claimOf(mallory, tokens[0]) != 0) target.claim(tokens[0], mallory);
            }
            uint256[] memory hasIndex = _held(target);
            uint256[] memory hasMallory = _balances(target, mallory);
            for (uint256 i = 0; i < tokens.length; ++i) {
                assertGe(hasIndex[i], hadIndex[i], "the index paid out more than it took in");
                assertLe(hasMallory[i], hadMallory[i], "a round of dust paid");
            }
        }
        vm.stopPrank();
        _assertBacked(target);
    }

    // ---------------------------------------------------------------------
    // HK-06: the first depositor's inflation (Hundred, Sonne and Onyx, 2023 to 2024)
    // ---------------------------------------------------------------------

    /// @dev Those markets priced a share by dividing the balance they held by the shares they had issued, so a first
    ///      deposit of one wei and a donation made the next depositor's shares round to nothing. A creation that is
    ///      its own first buy invites exactly that opening. Here a share's price is its units, never a balance: after
    ///      a first mint of one wei and a donation of a thousand coins, the next minter pays what it would have paid,
    ///      gets every share, and leaves with every coin. The donation is nobody's, the attacker's wei least of all.
    function test_HK06_aFirstMintOfOneWeiAndADonationTakeNothingFromTheNextMinter() public {
        _approveCreator(mallory);
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        address predicted = factory.predictIndexAddress(mallory, "Bait", "BAIT", specs, _params());
        vm.startPrank(mallory);
        for (uint256 i = 0; i < specs.length; ++i) {
            MockERC20(specs[i].token).mint(mallory, 1);
            MockERC20(specs[i].token).approve(predicted, 1);
        }
        WeightedHub bait = WeightedHub(factory.createAndIssue("Bait", "BAIT", specs, _params(), 1, mallory));
        vm.stopPrank();
        eth.mint(address(bait), 1000e18);
        btc.mint(address(bait), 1000e8);
        usd.mint(address(bait), 1000e6);

        address bob = makeAddr("bob");
        uint256[] memory quote = bait.previewIssue(10e18);
        assertEq(quote, _three(ETH_UNITS * 10, BTC_UNITS * 10, USD_UNITS * 10), "the donation moved the price");
        _issue(bait, bob, 10e18);
        assertEq(bait.balanceOf(bob), 10e18);
        vm.prank(bob);
        bait.redeem(10e18, bob);
        assertEq(_balances(bait, bob), quote, "the next minter left with less than it brought");

        vm.prank(mallory);
        bait.redeem(1, mallory);
        assertEq(_balances(bait, mallory), _three(0, 0, 0), "the attacker's wei redeemed for part of the donation");
        assertGe(eth.balanceOf(address(bait)), 1000e18);
    }

    // ---------------------------------------------------------------------
    // HK-08: reentrancy through a callback, across contracts and through views (The DAO, 2016, to Penpie, 2024)
    // ---------------------------------------------------------------------

    /// @dev The index calls its executor while it has paid out and not yet been paid. From inside that call the
    ///      executor tries what the index's own guard does not see directly: the factory's change of weights and its
    ///      handover of the creator role, which both call back into the index, and the request escrow, where a fill
    ///      calls no function of the index at all and would buy escrowed shares at a limit set for the basket the
    ///      fill has just replaced. All four are refused, and what the index's views say meanwhile is what they say
    ///      once the fill is over, so nothing reading them from another contract is told a stale price.
    function test_HK08_fromInsideAFillNoOtherDoorOpens() public {
        RaidingExecutor raider = new RaidingExecutor(factory, requests);
        uint256[] memory weights = _three(4000, 4000, 2000);
        vm.startPrank(creator);
        factory.proposeWeights(address(index), weights);
        factory.transferCreator(address(index), address(raider));
        vm.stopPrank();

        address bob = makeAddr("bob");
        uint256 deadline = block.timestamp + 20 days;
        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(requests), 1000e6);
        uint256 mintRequest = requests.requestMint(address(index), address(usdc), 1000e6, 5e18, deadline);
        vm.stopPrank();
        vm.startPrank(alice);
        index.approve(address(requests), 10e18);
        uint256 redeemRequest = requests.requestRedeem(address(index), 10e18, address(usdc), 900e6, deadline);
        vm.stopPrank();
        raider.aim(mintRequest, redeemRequest);

        _post(2600, BTC_PRICE, USD_PRICE);
        _open(index, 0);
        uint256[] memory fair = _onWeights(index, _market(2600, BTC_PRICE, USD_PRICE));
        _warpToFirstFill(index, fair);
        raider.execute(index, fair);

        RaidingExecutor.Outcome[] memory outcomes = raider.outcomes();
        bytes memory stale = abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 0, 1);
        assertEq(outcomes.length, 4);
        assertFalse(outcomes[0].opened || outcomes[1].opened || outcomes[2].opened || outcomes[3].opened);
        assertEq(outcomes[0].answer, abi.encodeWithSelector(REENTERED), "the weights changed inside a fill");
        assertEq(outcomes[1].answer, abi.encodeWithSelector(REENTERED), "the creator role moved inside a fill");
        assertEq(outcomes[2].answer, stale, "a mint request filled at the basket the fill replaced");
        assertEq(outcomes[3].answer, stale, "a redeem request filled at the basket the fill replaced");
        assertEq(raider.nonceSeen(), 1);
        assertEq(
            raider.redeemSeen(), index.previewRedeem(1e18), "a view said one thing inside the fill and another after"
        );

        // Nothing the raid aimed at moved: the role, the escrows, the weights. Each is still its owner's to move.
        assertEq(factory.creatorOf(address(index)), creator);
        assertEq(usdc.balanceOf(address(requests)), 1000e6);
        assertEq(index.balanceOf(address(requests)), 10e18);
        vm.prank(bob);
        requests.cancel(mintRequest);
        vm.prank(alice);
        requests.cancel(redeemRequest);
        assertEq(usdc.balanceOf(bob), 1000e6);
        assertEq(index.balanceOf(alice), SHARES);
        factory.executeWeights(address(index));
        assertEq(index.componentWeights(), weights);
    }

    // ---------------------------------------------------------------------
    // HK-09: a default that passes for a real value (Nomad, August 2022)
    // ---------------------------------------------------------------------

    /// @dev Nomad's bridge accepted every message because the root it compared with was zero, and zero was "proven".
    ///      Here nothing treats an empty slot as an answer: the request that was never made is not open, even to a
    ///      filler that names the hash of nothing; the proposal that was never made cannot be cancelled or executed;
    ///      and proposal zero, which an index never started reads as its latest, is no rebalance.
    function test_HK09_noEmptySlotPassesForARealOne() public {
        bytes32 hashOfNothing = requests.requestHash(0);
        assertEq(hashOfNothing, requests.requestHash(7), "an empty request hashes as any other empty one");
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, 0));
        requests.fill(0, 1, hashOfNothing);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, 7));
        requests.fill(7, 1);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, 0));
        requests.cancel(0);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, 0));
        requests.refund(0);

        assertEq(index.proposalCount(), 0);
        vm.expectRevert(IWeightedHub.NoPendingRebalance.selector);
        vm.prank(guardian);
        index.cancelRebalance(0);
        uint256[] memory units = index.recordedUnits();
        vm.expectRevert(IWeightedHub.NoPendingRebalance.selector);
        index.executeRebalance(units, "");
        (uint256[] memory quoted,) = index.rebalanceQuote();
        assertEq(quoted.length, 0, "an index never started reports a quote");

        // An address the factory never created has no creator, no pending creator and no pending weights.
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, address(this)));
        factory.acceptCreator(address(0));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(0)));
        factory.proposeWeights(address(0), _three(1, 1, 9998));
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NoPendingWeights.selector, address(0)));
        factory.executeWeights(address(0));
    }

    // ---------------------------------------------------------------------
    // HK-10: a signed message accepted a second time, by another contract or another chain
    // ---------------------------------------------------------------------

    /// @dev The replay class: a signature made for one contract on one chain is good on another. Two indexes can
    ///      carry the same name
    ///      and symbol, and every index runs the same code: a permit signed for one is worth nothing on its twin,
    ///      nothing a second time on its own index, and nothing on a chain that copied this one's state.
    function test_HK10_aPermitIsGoodOnceOnOneIndexOnOneChain() public {
        (address signer, uint256 key) = makeAddrAndKey("signer");
        _approveCreator(mallory);
        vm.prank(mallory);
        WeightedHub twin = WeightedHub(factory.createIndex("Weighted", "WGT", _defaultSpecs(), _params()));
        assertEq(twin.name(), index.name());
        assertTrue(twin.DOMAIN_SEPARATOR() != index.DOMAIN_SEPARATOR());

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(index, key, signer, mallory, 5e18);
        vm.expectPartialRevert(BAD_SIGNER);
        twin.permit(signer, mallory, 5e18, type(uint256).max, v, r, s);

        index.permit(signer, mallory, 5e18, type(uint256).max, v, r, s);
        assertEq(index.allowance(signer, mallory), 5e18);
        vm.expectPartialRevert(BAD_SIGNER);
        index.permit(signer, mallory, 5e18, type(uint256).max, v, r, s);

        (v, r, s) = _signPermit(index, key, signer, mallory, 7e18);
        vm.chainId(56);
        vm.expectPartialRevert(BAD_SIGNER);
        index.permit(signer, mallory, 7e18, type(uint256).max, v, r, s);
        assertEq(index.allowance(signer, mallory), 5e18);
    }

    // ---------------------------------------------------------------------
    // HK-12: a function anyone could call (Poly Network, 2021, to the takeovers of 2026)
    // ---------------------------------------------------------------------

    /// @dev Two thirds of what was taken in April 2026 went through a function that should have asked who was
    ///      calling. Every function of the factory and of an index that changes state is called here by an account
    ///      with no role, no shares and no coins, and each is refused with the error that names why. The two tables
    ///      are held to the ABIs: a function added to either contract fails this test until it is given its row.
    function test_HK12_aStrangerOpensNoDoor() public {
        bytes memory terms = abi.encode(index.config(), index.recordedUnits(), index.componentWeights());
        uint256[] memory held = _held(index);

        Door[] memory doors = _factoryDoors();
        _knock(address(factory), doors);
        assertEq(
            doors.length,
            _occurrences("abi/WeightedIndexFactory.json", '"stateMutability": "nonpayable"')
                + _occurrences("abi/WeightedIndexFactory.json", '"stateMutability": "payable"') - 1,
            "a function of the factory has no row here"
        );

        doors = _indexDoors();
        _knock(address(index), doors);
        // Two more are anyone's to call and move nothing of anyone else's: an accrual, and an approval of one's own.
        vm.startPrank(stranger);
        index.accrueFees();
        index.approve(mallory, 1e18);
        vm.stopPrank();
        assertEq(
            doors.length + 2,
            _occurrences("abi/WeightedHub.json", '"stateMutability": "nonpayable"') - 1,
            "a function of the index has no row here"
        );
        assertEq(_occurrences("abi/WeightedHub.json", '"stateMutability": "payable"'), 0, "the index takes ether");

        assertEq(abi.encode(index.config(), index.recordedUnits(), index.componentWeights()), terms);
        assertEq(_held(index), held);
        assertEq(index.balanceOf(alice), SHARES);
        assertEq(index.totalSupply(), SHARES);
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(factory.creatorOf(address(index)), creator);
    }

    /// @dev Every state-changing function of the factory, as a stranger calls it. The three that anyone may call
    ///      execute a proposal only a role can make, and none is pending.
    function _factoryDoors() internal view returns (Door[] memory doors) {
        address target = address(index);
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        IPythPrices.PriceFeed memory feed = IPythPrices.PriceFeed(ETH_FEED, IPythPrices.FeedKind.Token);
        bytes4 unauthorized = IXindexErrors.Unauthorized.selector;
        bytes4 notApproved = IWeightedIndexFactory.CreatorNotApproved.selector;
        doors = new Door[](25);
        doors[0] = Door(abi.encodeCall(factory.setApprovedCreator, (stranger, true)), NOT_OWNER);
        doors[1] = Door(abi.encodeCall(factory.transferCreator, (target, stranger)), unauthorized);
        doors[2] = Door(abi.encodeCall(factory.acceptCreator, (target)), unauthorized);
        doors[3] = Door(abi.encodeCall(factory.setAllowedMinter, (target, stranger, true)), unauthorized);
        doors[4] = Door(abi.encodeCall(factory.openMinting, (target)), unauthorized);
        doors[5] = Door(abi.encodeCall(factory.pauseMinting, (target)), unauthorized);
        doors[6] = Door(abi.encodeCall(factory.resumeMinting, (target)), NOT_OWNER);
        doors[7] = Door(abi.encodeCall(factory.setFeePolicy, (0, 0, 0, stranger, 0)), NOT_OWNER);
        doors[8] = Door(abi.encodeCall(factory.createIndex, ("Mine", "MINE", specs, _params())), notApproved);
        doors[9] = Door(
            abi.encodeCall(factory.createAndIssue, ("Mine", "MINE", specs, _params(), 1e18, stranger)), notApproved
        );
        doors[10] = Door(abi.encodeCall(factory.proposeListing, (address(usdc))), NOT_OWNER);
        doors[11] = Door(abi.encodeCall(factory.cancelListing, (address(usdc))), unauthorized);
        doors[12] = Door(
            abi.encodeCall(factory.executeListing, (address(usdc))), IWeightedIndexFactory.NoPendingListing.selector
        );
        doors[13] = Door(abi.encodeCall(factory.delist, (address(eth))), unauthorized);
        doors[14] = Door(abi.encodeCall(factory.proposeWeights, (target, _three(9998, 1, 1))), unauthorized);
        doors[15] = Door(abi.encodeCall(factory.cancelWeights, (target)), unauthorized);
        doors[16] =
            Door(abi.encodeCall(factory.executeWeights, (target)), IWeightedIndexFactory.NoPendingWeights.selector);
        doors[17] = Door(abi.encodeCall(factory.proposePriceFeed, (address(eth), feed)), NOT_OWNER);
        doors[18] = Door(abi.encodeCall(factory.cancelPriceFeed, (address(eth))), unauthorized);
        doors[19] = Door(
            abi.encodeCall(factory.executePriceFeed, (address(eth))), IWeightedIndexFactory.NoPendingPriceFeed.selector
        );
        doors[20] = Door(abi.encodeCall(factory.proposeGuardian, (stranger)), NOT_OWNER);
        doors[21] = Door(
            abi.encodeCall(factory.cancelGuardianChange, ()), IWeightedIndexFactory.NoPendingGuardianChange.selector
        );
        doors[22] = Door(
            abi.encodeCall(factory.executeGuardianChange, ()), IWeightedIndexFactory.NoPendingGuardianChange.selector
        );
        doors[23] = Door(abi.encodeCall(factory.transferOwnership, (stranger)), NOT_OWNER);
        doors[24] = Door(abi.encodeCall(factory.acceptOwnership, ()), NOT_OWNER);
    }

    /// @dev Every state-changing function of an index but the two anyone may call for itself, as a stranger with no
    ///      shares and no coins calls it on an index nothing is pending on.
    function _indexDoors() internal view returns (Door[] memory doors) {
        uint256[] memory units = index.recordedUnits();
        uint256[] memory none = new uint256[](0);
        IWeightedHub.ComponentInit[] memory inits = new IWeightedHub.ComponentInit[](0);
        IWeightedHub.FirstIssue memory first = IWeightedHub.FirstIssue(alice, 1e18, stranger);
        bytes4 nothingPending = IWeightedHub.NoPendingRebalance.selector;
        doors = new Door[](17);
        doors[0] = Door(abi.encodeCall(index.initialize, ("Mine", "MINE", inits, index.config(), first)), INITIALIZED);
        doors[1] = Door(abi.encodeWithSignature("issue(uint256,address)", 1e18, stranger), NO_ALLOWANCE);
        doors[2] =
            Door(abi.encodeWithSignature("issue(uint256,address,address)", 1e18, stranger, stranger), NO_ALLOWANCE);
        doors[3] = Door(abi.encodeCall(index.redeem, (1e18, stranger)), NO_BALANCE);
        doors[4] = Door(abi.encodeCall(index.redeemSkipping, (1e18, stranger, 1)), NO_BALANCE);
        doors[5] = Door(
            abi.encodeWithSignature("claim(address,address)", eth, stranger), IWeightedHub.NothingToClaim.selector
        );
        doors[6] = Door(
            abi.encodeWithSignature("claim(address,address,uint256)", eth, stranger, 1),
            IWeightedHub.ClaimTooLarge.selector
        );
        doors[7] = Door(abi.encodeWithSignature("startRebalance(uint256)", 0), IWeightedHub.RebalanceTooSoon.selector);
        doors[8] = Door(
            abi.encodeWithSignature("startRebalance(uint256,uint256[],uint256)", 0, units, 0),
            IXindexErrors.Unauthorized.selector
        );
        doors[9] = Door(abi.encodeWithSignature("cancelRebalance()"), nothingPending);
        doors[10] = Door(abi.encodeWithSignature("cancelRebalance(uint256)", 0), nothingPending);
        doors[11] = Door(abi.encodeWithSignature("executeRebalance(uint256[],bytes)", units, ""), nothingPending);
        doors[12] = Door(
            abi.encodeWithSignature("executeRebalance(uint256[],bytes,uint256[])", units, "", none), nothingPending
        );
        doors[13] = Door(abi.encodeCall(index.setWeights, (_three(9998, 1, 1))), IWeightedHub.NotFactory.selector);
        doors[14] = Door(abi.encodeCall(index.transfer, (stranger, 1)), NO_BALANCE);
        doors[15] = Door(abi.encodeCall(index.transferFrom, (alice, stranger, 1)), NO_ALLOWANCE);
        doors[16] = Door(
            abi.encodeCall(index.permit, (alice, stranger, 1e18, type(uint256).max, 0, bytes32(0), bytes32(0))),
            BAD_SIGNATURE
        );
    }

    // ---------------------------------------------------------------------
    // HK-13: shares minted that nothing backs (Resolv, March 2026; TesseraDAO, June 2026)
    // ---------------------------------------------------------------------

    /// @dev Those protocols let a key or a path mint with no bound on what stood behind it. An index mints in three
    ///      places, and none is a key's: an issue, which pulls the basket of every share it mints, the fee's
    ///      included; a redeem's fee, minted out of the shares burned; and the streaming fee, whose shares come with
    ///      a scale lowered by the same factor, so what all shares together can claim never grows. Held here at
    ///      every fee's cap, over one year and then over sixty idle ones, where the fee is capped just under the
    ///      whole.
    function test_HK13_noShareIsMintedThatADepositOrTheScaleDoesNotBack() public {
        WeightedHub fund = _feeIndex();
        uint256[] memory quote = fund.previewIssue(50e18);
        _issue(fund, alice, 50e18);
        uint256 gross = fund.totalSupply();
        assertGt(gross, 50e18, "the entry fee minted no share");
        uint256[] memory held = _held(fund);
        assertEq(held, quote, "the deposit is the basket of every share minted, the fee's among them");
        uint256[] memory units = fund.recordedUnits();
        for (uint256 i = 0; i < units.length; ++i) {
            assertGe(held[i], Math.mulDiv(gross, units[i], 1e18, Math.Rounding.Ceil));
        }

        uint256[2] memory gaps = [uint256(365 days), 60 * 365 days];
        for (uint256 i = 0; i < gaps.length; ++i) {
            (, uint256 scaleBefore) = fund.pendingStreamingFee();
            uint256 supplyBefore = fund.totalSupply();
            vm.warp(block.timestamp + gaps[i]);
            fund.accrueFees();
            (uint256 pending, uint256 scale) = fund.pendingStreamingFee();
            assertEq(pending, 0);
            assertGt(fund.totalSupply(), supplyBefore, "the streaming fee minted no share");
            assertGt(scale, 0, "the fee took the whole index");
            assertLe(fund.totalSupply() * scale, supplyBefore * scaleBefore, "the shares claim more than they did");
            assertEq(_held(fund), held, "a fee moved a token");
            _assertBacked(fund);
        }

        // The holder still leaves, with what the fees left it, and the index covers every share that remains.
        vm.prank(alice);
        fund.redeem(50e18, alice);
        assertGt(eth.balanceOf(alice), 0);
        _assertBacked(fund);
    }

    // ---------------------------------------------------------------------
    // HK-14: ether pushed into a contract that counts it (the forced-ether class)
    // ---------------------------------------------------------------------

    /// @dev A contract that reads its own ether balance can be moved by ether it never asked for, which a
    ///      self-destructing contract can push into any address. Here the only ether in the protocol is a creation's
    ///      fee, and it is the call's own value that is checked and forwarded, never a balance: ether forced into the
    ///      factory, an index, the price reader or the request escrow changes nothing, and stays where it fell.
    function test_HK14_etherForcedIntoAContractChangesNothing() public {
        address payable recipient = payable(makeAddr("platform"));
        vm.prank(owner);
        factory.setFeePolicy(0, 0, 0, recipient, 1 ether);
        vm.deal(address(factory), 5 ether);
        vm.deal(address(index), 5 ether);
        vm.deal(address(prices), 5 ether);
        vm.deal(address(requests), 5 ether);

        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.WrongCreationFee.selector, 0, 1 ether));
        vm.prank(creator);
        factory.createIndex("Free", "FREE", _defaultSpecs(), _params());

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        WeightedHub paid = WeightedHub(factory.createIndex{value: 1 ether}("Paid", "PAID", _defaultSpecs(), _params()));
        assertEq(recipient.balance, 1 ether, "the recipient was paid a balance, not the fee");
        assertEq(address(factory).balance, 5 ether);

        uint256[] memory quote = index.previewRedeem(SHARES);
        _issue(paid, alice, 1e18);
        vm.prank(alice);
        index.redeem(SHARES, alice);
        assertEq(eth.balanceOf(alice), quote[0]);
        assertEq(address(index).balance, 5 ether);
    }

    // ---------------------------------------------------------------------
    // HK-15: a vault's rate raised by a donation (the ERC-4626 class, 2023 to 2025)
    // ---------------------------------------------------------------------

    /// @dev Protocols that priced a vault token by its rate were drained by raising the rate with a donation. A
    ///      wrapped stock is a vault, and Pyth's check values it at its rate, read at the fill. An attacker multiplies
    ///      the rate a thousand times and names a fill that takes a fifth of the other leg for a sliver of the vault:
    ///      by Pyth's measure the sliver is worth more than what leaves, so that check passes. The fill is refused all
    ///      the same, on units alone, where no rate is read. A raised rate can only loosen Pyth's check toward the
    ///      bar's; it never loosens the bar.
    function test_HK15_aVaultRateRaisedByADonationPassesNoFillTheUnitsRefuse() public {
        MockERC20 share = new MockERC20("Share", "SHR", 18);
        MockVault vault = new MockVault(share);
        _list(address(vault));
        bytes32 shareFeed = keccak256("SHR/USD");
        pyth.setLivePrice(shareFeed, 100e8, 0, -8);
        _setFeed(address(vault), shareFeed, IPythPrices.FeedKind.Vault);
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = _spec(address(eth), 5000, ETH_UNITS);
        specs[1] = _spec(address(vault), 5000, 0.5e18);
        vault.mint(address(this), 1e18);
        WeightedHub wrapped = _create(specs);
        _issue(wrapped, alice, SHARES);

        share.mint(address(vault), vault.totalAssets() * 1000);
        _open(wrapped, wrapped.AUCTION_DURATION());
        uint256[] memory units = wrapped.recordedUnits();
        uint256[] memory greedy = new uint256[](2);
        greedy[0] = units[0] * 4 / 5;
        greedy[1] = units[1] + units[1] / 4000;

        // Pyth's check alone, at the rate the donation left: it passes.
        address[] memory tokens = wrapped.componentTokens();
        uint256[] memory values = prices.legValues(tokens, units, greedy);
        math.oracleCheck(units, greedy, values, wrapped.AUCTION_DURATION());

        vm.expectPartialRevert(IWeightedHub.GainBelowBar.selector);
        wrapped.previewRebalance(greedy);
        RaidingExecutor raider = new RaidingExecutor(factory, requests);
        vm.expectPartialRevert(IWeightedHub.GainBelowBar.selector);
        raider.execute(wrapped, greedy);
    }

    // ---------------------------------------------------------------------
    // HK-16: a pending change that outlives the role that made it
    // ---------------------------------------------------------------------

    /// @dev Found by this replay. A creator's proposal of new weights stayed pending when the creator role moved, so
    ///      the outgoing creator's weights took effect under the incoming one, who had seven days to notice and
    ///      cancel them. The handover clears it: a role's pending change goes with the role.
    function test_HK16_aHandoverClearsTheOutgoingCreatorsWeights() public {
        vm.startPrank(creator);
        factory.proposeWeights(address(index), _three(9998, 1, 1));
        factory.transferCreator(address(index), mallory);
        vm.stopPrank();
        (uint256[] memory pending, uint256 eta) = factory.pendingWeights(address(index));
        assertEq(pending.length, 3);
        assertGt(eta, 0, "the offer alone cleared the proposal");

        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.WeightsCancelled(address(index));
        vm.prank(mallory);
        factory.acceptCreator(address(index));
        (pending, eta) = factory.pendingWeights(address(index));
        assertEq(pending.length, 0);
        assertEq(eta, 0);
        vm.warp(block.timestamp + factory.WEIGHTS_DELAY());
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NoPendingWeights.selector, address(index)));
        factory.executeWeights(address(index));
        assertEq(index.componentWeights(), _three(5000, 3000, 2000));

        // A handover with nothing pending cancels nothing, and the new creator's own proposal stands.
        vm.startPrank(mallory);
        factory.proposeWeights(address(index), _three(4000, 4000, 2000));
        factory.transferCreator(address(index), creator);
        factory.cancelWeights(address(index));
        vm.stopPrank();
        vm.recordLogs();
        vm.prank(creator);
        factory.acceptCreator(address(index));
        assertEq(vm.getRecordedLogs().length, 1, "a handover with nothing pending emitted a cancel");
    }

    // ---------------------------------------------------------------------
    // HK-24: a public recompute between an issue and a redeem (Set's RebalancingSetTokenV3, October 2026)
    // ---------------------------------------------------------------------

    /// @dev Set's token let anyone call `actualizeFee()`, which recomputed every share's backing and rounded it up even
    ///      when no fee was due; a flash-funded loop of issue, recompute and redeem took $50K. Here anyone may call
    ///      `accrueFees`, and an index charging no entry or exit fee leaves only the streaming fee's scale to work on.
    ///      Three hundred rounds, in one block and across a second, each recomputing up to twice between the issue
    ///      and the redeem, never pay the attacker a wei, never cost the index one, never raise the scale, and leave
    ///      every share backed: a redeem pays at the scale its own accrual left (mutant HK10).
    function test_HK24_recomputingTheFeeBetweenAnIssueAndARedeemPaysNothing() public {
        vm.prank(owner);
        factory.setFeePolicy(0, 100, 0, makeAddr("platform"), 0);
        IWeightedIndexFactory.IndexParams memory params = _params();
        params.creatorStreamingBps = 500;
        WeightedHub target = _create(_defaultSpecs(), params);
        address[] memory tokens = target.componentTokens();
        address bob = makeAddr("bob");
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(mallory, 1e30);
            MockERC20(tokens[i]).mint(bob, 1e30);
            vm.prank(mallory);
            MockERC20(tokens[i]).approve(address(target), type(uint256).max);
            vm.prank(bob);
            MockERC20(tokens[i]).approve(address(target), type(uint256).max);
        }
        vm.prank(bob);
        target.issue(1000e18, bob); // a holder whose backing the loop would have to take

        uint256[] memory hadIndex = _held(target);
        uint256[] memory hadMallory = _balances(target, mallory);
        (, uint256 scale) = target.pendingStreamingFee();
        vm.startPrank(mallory);
        for (uint256 round = 0; round < 300; ++round) {
            // Dust one round in five, and otherwise up to a thousand whole shares with an odd tail.
            target.issue(round % 5 == 0 ? 1 + round : (round + 1) * 3e18 + round, mallory);
            // Every other round lets a second pass between the issue and the redeem, so a fee is due there.
            if (round % 2 == 0) vm.warp(block.timestamp + 1);
            for (uint256 r = 0; r < round % 3; ++r) {
                target.accrueFees();
            }
            target.redeem(target.balanceOf(mallory), mallory);

            (, uint256 now_) = target.pendingStreamingFee();
            assertLe(now_, scale, "the scale rose");
            scale = now_;
            uint256[] memory hasIndex = _held(target);
            uint256[] memory hasMallory = _balances(target, mallory);
            for (uint256 i = 0; i < tokens.length; ++i) {
                assertGe(hasIndex[i], hadIndex[i], "the index paid out more than it took in");
                assertLe(hasMallory[i], hadMallory[i], "a round paid the attacker");
            }
        }
        vm.stopPrank();
        _assertBacked(target);
    }
}
