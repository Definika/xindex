// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConfigureWeighted} from "../script/ConfigureWeighted.s.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {PythIds} from "../script/PythIds.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice A contract with no `decimals`, so the policy check finds no answer.
contract NoDecimals {}

/// @notice v5's listing script against a real `WeightedIndexFactory`. Broadcasts come from DEFAULT_SENDER, the
///         factory's owner here. The V5_ variables are set by `test_run_readsEnvironment` alone.
contract ConfigureWeightedTest is Test {
    ConfigureWeighted configure;
    WeightedIndexFactory factory;
    MockERC20 a;
    MockERC20 b;
    address guardian = makeAddr("guardian");

    bytes32 constant A_ID = keccak256("A/USD");
    bytes32 constant B_ID = keccak256("B/USD");

    function setUp() public {
        configure = new ConfigureWeighted();
        factory = new WeightedIndexFactory(DEFAULT_SENDER, guardian, address(new MockPyth()));
        a = new MockERC20("Alpha", "A", 18);
        b = new MockERC20("Beta", "B", 8);
    }

    function _list() internal view returns (ConfigureWeighted.Entry[] memory list) {
        list = new ConfigureWeighted.Entry[](2);
        list[0] = ConfigureWeighted.Entry({token: address(a), priceId: A_ID});
        list[1] = ConfigureWeighted.Entry({token: address(b), priceId: B_ID});
    }

    function _all() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(a), address(b));
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    // ---------------------------------------------------------------------
    // Lists and parsing
    // ---------------------------------------------------------------------

    function test_theMainnetListsAreTheTable() public {
        vm.chainId(1);
        ConfigureWeighted.Entry[] memory first = configure.resolveList("default");
        ConfigureWeighted.Entry[] memory wide = configure.resolveList("wide");
        (address[] memory tokens, bytes32[] memory ids) = PythIds.all();
        assertEq(first.length, configure.DEFAULT_COUNT());
        assertEq(first.length + wide.length, tokens.length);
        assertEq(tokens.length, 27, "the owner's list of 2026-10-06");
        for (uint256 i = 0; i < tokens.length; ++i) {
            ConfigureWeighted.Entry memory entry = i < 4 ? first[i] : wide[i - 4];
            assertEq(entry.token, tokens[i]);
            assertEq(entry.priceId, ids[i]);
        }
        assertEq(first[0].token, MainnetAddresses.WETH);
    }

    function test_theMainnetListsOnlyOnMainnet() public {
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.MainnetListOffMainnet.selector, "default"));
        configure.resolveList("default");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.MainnetListOffMainnet.selector, "wide"));
        configure.resolveList("wide");
    }

    function test_entriesParse() public view {
        string memory raw = string.concat(
            vm.toString(address(a)), ":", vm.toString(A_ID), " , ", vm.toString(address(b)), ":", vm.toString(B_ID)
        );
        ConfigureWeighted.Entry[] memory list = configure.resolveList(raw);
        assertEq(list.length, 2);
        assertEq(list[0].token, address(a));
        assertEq(list[0].priceId, A_ID);
        assertEq(list[1].token, address(b));
        assertEq(list[1].priceId, B_ID);
    }

    function test_malformedEntriesAreRefused() public {
        string memory token = vm.toString(address(a));
        string[4] memory bad = [
            token,
            string.concat(token, ":"),
            string.concat(token, ":", vm.toString(A_ID), ":x"),
            string.concat(token, ":", vm.toString(bytes32(0)))
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.MalformedEntry.selector, bad[i]));
            configure.parseEntry(bad[i]);
        }
    }

    /// @dev A token or a price id named twice is refused before anything runs (RT-24, V5-M1).
    function test_RT24_V5M1_aListNamingATokenOrAnIdTwiceIsRefused() public {
        ConfigureWeighted.Entry[] memory list = _list();
        list[1].token = address(a);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.DuplicateEntry.selector, address(a)));
        configure.safeCalldata(factory, list, _all(), _none());

        list = _list();
        list[1].priceId = A_ID;
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.DuplicatePriceId.selector, A_ID));
        configure.propose(factory, list, _all(), _none());

        string memory raw = string.concat(
            vm.toString(address(a)), ":", vm.toString(A_ID), ",", vm.toString(address(a)), ":", vm.toString(B_ID)
        );
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.DuplicateEntry.selector, address(a)));
        configure.resolveList(raw);
    }

    function test_addressListsParse() public view {
        assertEq(configure.parseAddresses("").length, 0);
        address[] memory parsed =
            configure.parseAddresses(string.concat(vm.toString(address(a)), ", ", vm.toString(address(b))));
        assertEq(parsed.length, 2);
        assertEq(parsed[1], address(b));
        address[] memory all = configure.resolveFirstListings("all", _list());
        assertEq(all.length, 2);
        assertEq(all[0], address(a));
        assertEq(configure.resolveFirstListings(vm.toString(address(b)), _list())[0], address(b));
    }

    // ---------------------------------------------------------------------
    // Proposals
    // ---------------------------------------------------------------------

    /// @dev RT-06: a token never listed gets a proposal only when named in V5_LIST.
    function test_RT06_aFirstListingIsProposedOnlyWhenNamed() public {
        configure.propose(factory, _list(), _none(), _none());
        assertEq(factory.listingEta(address(a)), 0, "not named, not proposed");

        address[] memory onlyA = new address[](1);
        onlyA[0] = address(a);
        configure.propose(factory, _list(), onlyA, _none());
        assertGt(factory.listingEta(address(a)), 0);
        assertEq(factory.listingEta(address(b)), 0);
        (bytes32 id,) = factory.pendingTerms(address(a));
        assertEq(id, A_ID);
    }

    /// @dev RT-06: a listing the guardian cancelled is not proposed again by a routine run, and a delisted token comes
    ///      back only when named in V5_RELIST.
    function test_RT06_aVetoedOrDelistedTokenStaysOutUnlessNamed() public {
        configure.propose(factory, _list(), _all(), _none());
        vm.prank(guardian);
        factory.cancelListing(address(a));
        configure.propose(factory, _list(), _none(), _none());
        assertEq(factory.listingEta(address(a)), 0, "a routine run does not repropose the vetoed listing");

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, _list());
        assertTrue(factory.isWhitelisted(address(b)));
        vm.prank(guardian);
        factory.delist(address(b));
        configure.propose(factory, _list(), _all(), _none());
        assertEq(factory.listingEta(address(b)), 0, "delisted, and only V5_LIST named it");
        configure.propose(factory, _list(), _none(), _all());
        assertGt(factory.listingEta(address(b)), 0, "named in V5_RELIST");
    }

    function test_proposeSkipsWhatThePolicyOrTheFactoryWouldRefuse() public {
        configure.propose(factory, _list(), _all(), _none());
        // Already pending with the entry's id, or with another: both skipped.
        ConfigureWeighted.Entry[] memory changed = _list();
        changed[0].priceId = keccak256("A, another feed");
        configure.propose(factory, changed, _all(), _none());
        configure.propose(factory, _list(), _all(), _none());
        (bytes32 id,) = factory.pendingTerms(address(a));
        assertEq(id, A_ID);
        // Listed: skipped.
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, _list());
        configure.propose(factory, _list(), _all(), _all());
        assertEq(factory.listingEta(address(a)), 0);

        // The policy: a mint currency, a token with no code, no decimals, and decimals outside 6 to 18.
        ConfigureWeighted.Entry[] memory odd = new ConfigureWeighted.Entry[](6);
        odd[0] = ConfigureWeighted.Entry({token: MainnetAddresses.USDC, priceId: keccak256("1")});
        odd[1] = ConfigureWeighted.Entry({token: MainnetAddresses.USDT, priceId: keccak256("2")});
        odd[2] = ConfigureWeighted.Entry({token: makeAddr("no code"), priceId: keccak256("3")});
        odd[3] = ConfigureWeighted.Entry({token: address(new NoDecimals()), priceId: keccak256("4")});
        odd[4] = ConfigureWeighted.Entry({token: address(new MockERC20("Five", "FIVE", 5)), priceId: keccak256("5")});
        odd[5] = ConfigureWeighted.Entry({token: address(new MockERC20("Wide", "WIDE", 19)), priceId: keccak256("6")});
        address[] memory named = new address[](6);
        for (uint256 i = 0; i < 6; ++i) {
            named[i] = odd[i].token;
        }
        (bytes[] memory calls,) = configure.safeCalldata(factory, odd, named, _none());
        assertEq(calls.length, 0, "the policy skips every one");
    }

    function test_proposeNeedsAnOwnerThatSigns() public {
        WeightedIndexFactory owned = new WeightedIndexFactory(address(configure), guardian, address(new MockPyth()));
        ConfigureWeighted.Entry[] memory list = _list();
        address[] memory all = _all();
        address[] memory none = _none();
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.OwnerIsContract.selector, address(configure)));
        configure.propose(owned, list, all, none);

        // A key delegated under EIP-7702 has code but still signs.
        vm.etch(DEFAULT_SENDER, abi.encodePacked(hex"ef0100", address(0x1234)));
        configure.propose(factory, list, all, none);
        assertGt(factory.listingEta(address(a)), 0);
    }

    function test_safeModeLabelsEveryProposal() public view {
        (bytes[] memory calls, string[] memory labels) = configure.safeCalldata(factory, _list(), _all(), _none());
        assertEq(calls.length, 2);
        assertEq(calls[0], abi.encodeCall(factory.proposeListing, (address(a), A_ID)));
        assertEq(
            labels[1], string.concat("proposeListing B ", vm.toString(address(b)), " price id ", vm.toString(B_ID))
        );
    }

    // ---------------------------------------------------------------------
    // Execution and status
    // ---------------------------------------------------------------------

    function test_executeRunsOnlyWhatIsDueAndTheEntrys() public {
        configure.execute(factory, _list()); // nothing pending
        configure.propose(factory, _list(), _all(), _none());
        configure.execute(factory, _list()); // not ready
        assertFalse(factory.isWhitelisted(address(a)));

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        ConfigureWeighted.Entry[] memory changed = _list();
        changed[0].priceId = keccak256("A, another feed");
        configure.execute(factory, changed);
        assertFalse(factory.isWhitelisted(address(a)), "the pending id is not the entry's");
        assertTrue(factory.isWhitelisted(address(b)));

        vm.warp(block.timestamp + factory.PROPOSAL_WINDOW() + 1);
        configure.execute(factory, _list());
        assertFalse(factory.isWhitelisted(address(a)), "expired");
    }

    function test_statusReportsListingsAndPendingProposals() public {
        configure.propose(factory, _list(), _all(), _none());
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        ConfigureWeighted.Entry[] memory onlyB = new ConfigureWeighted.Entry[](1);
        onlyB[0] = _list()[1];
        configure.execute(factory, onlyB);

        ConfigureWeighted.Entry[] memory changed = _list();
        changed[0].priceId = keccak256("A, another feed");
        ConfigureWeighted.Report[] memory reports = configure.status(factory, changed);
        assertFalse(reports[0].listed);
        assertFalse(reports[0].idInForce);
        assertGt(reports[0].eta, 0);
        assertFalse(reports[0].pendingMatches);
        assertTrue(reports[1].listed);
        assertTrue(reports[1].idInForce);
        assertEq(reports[1].eta, 0);

        reports = configure.status(factory, _list());
        assertTrue(reports[0].pendingMatches);
    }

    // ---------------------------------------------------------------------
    // run
    // ---------------------------------------------------------------------

    function test_run_readsEnvironment() public {
        string memory raw = string.concat(
            vm.toString(address(a)), ":", vm.toString(A_ID), ",", vm.toString(address(b)), ":", vm.toString(B_ID)
        );
        vm.setEnv("V5_FACTORY", vm.toString(address(factory)));
        vm.setEnv("V5_WHITELIST", raw);
        vm.setEnv("V5_LIST", "all");
        vm.setEnv("V5_RELIST", "");
        vm.setEnv("V5_MODE", "safe");
        configure.run();
        assertEq(factory.listingEta(address(a)), 0, "safe mode broadcasts nothing");
        vm.setEnv("V5_MODE", "propose");
        configure.run();
        assertGt(factory.listingEta(address(a)), 0);
        vm.setEnv("V5_MODE", "status");
        configure.run();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.setEnv("V5_MODE", "execute");
        configure.run();
        assertTrue(factory.isWhitelisted(address(a)));
        assertTrue(factory.isWhitelisted(address(b)));
        vm.setEnv("V5_MODE", "sideways");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.UnknownMode.selector, "sideways"));
        configure.run();
    }
}
