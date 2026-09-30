// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {ConfigureWhitelist} from "../script/ConfigureWhitelist.s.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexHub} from "../src/IndexHub.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../src/interfaces/IIndexRule.sol";
import {SetupTestMarket} from "../script/testnet/SetupTestMarket.s.sol";
import {FaucetToken} from "../script/testnet/FaucetToken.sol";
import {INonfungiblePositionManager} from "../script/interfaces/INonfungiblePositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DEFAULT_STALENESS, MockMarket} from "./mocks/MockMarket.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./mocks/MockUniswapV3.sol";
import {CompositeFeed} from "../src/CompositeFeed.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {TestAggregator} from "../script/testnet/TestAggregator.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// @notice Stand-in for a Safe: the deploy script only reads its signature threshold and its module list.
contract MockSafe {
    /// @dev Safe's sentinel, which both starts and ends its module list.
    address internal constant SENTINEL = address(1);

    uint256 public getThreshold;
    address[] internal _modules;
    bool internal _malformedModules;

    constructor(uint256 threshold) {
        getThreshold = threshold;
    }

    function enableModule(address module) external {
        _modules.push(module);
    }

    function setMalformedModules(bool malformed) external {
        _malformedModules = malformed;
    }

    /// @notice Safe's module list, one page from `start`, walked as Safe 1.3.0's ModuleManager walks it: from the
    ///         sentinel or from an enabled module, and from any other start an empty page, whatever is enabled. A mock
    ///         that paged from the head whatever it was asked let a script asking from the wrong start pass (CR-I36).
    ///         A single word instead when set malformed.
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory page, address next)
    {
        if (_malformedModules) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 32)
            }
        }
        // Where the page starts: after the sentinel, after an enabled module, or nowhere.
        uint256 first = type(uint256).max;
        if (start == SENTINEL) first = 0;
        for (uint256 i = 0; i < _modules.length; ++i) {
            if (_modules[i] == start) first = i + 1;
        }
        if (first == type(uint256).max) return (new address[](0), address(0)); // 1.3.0 reads modules[start] as zero
        uint256 left = _modules.length - first;
        uint256 n = left < pageSize ? left : pageSize;
        page = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            page[i] = _modules[first + i];
        }
        next = first + n < _modules.length ? _modules[first + n] : SENTINEL;
    }
}

/// @notice A contract whose every call reverts with one word of data, which decodes as a threshold of 1 if a caller
///         forgets to check that the call succeeded.
contract RevertsOneWord {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            revert(0, 32)
        }
    }
}

/// @notice A 2-of-n multisig whose module-list call reverts, with data that would decode as an empty list if a caller
///         forgot to check that the call succeeded.
contract ModuleListReverts {
    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getModulesPaginated(address, uint256) external pure returns (address[] memory, address) {
        bytes memory data = abi.encode(new address[](0), address(1));
        assembly ("memory-safe") {
            revert(add(data, 32), mload(data))
        }
    }
}

/// @notice An aggregator that prices but cannot name its pair: it has no `description()`.
contract NamelessFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice An upgradeable proxy. Put in front of a genuine `CompositeFeed` it answers every getter, the description and
///         the price exactly as the adapter does, because an implementation's immutables live in its own code, and it
///         can be pointed at anything afterwards. A real one restricts `upgradeTo` to its admin; who may call it changes
///         nothing a script can see.
contract UpgradeableFeedProxy {
    address public implementation;

    constructor(address implementation_) {
        implementation = implementation_;
    }

    function upgradeTo(address next) external {
        implementation = next;
    }

    fallback() external {
        address target = implementation;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @notice Not an adapter at all: it answers the four getters and the description an adapter over BTC/USD and
///         WBTC/BTC answers, and whatever price its deployer chose. The price is an immutable, so it answers the same
///         from behind a proxy.
contract LookalikeWbtcFeed {
    IAggregatorV3 public constant FEED_A = IAggregatorV3(MainnetAddresses.BTC_USD_FEED);
    IAggregatorV3 public constant FEED_B = IAggregatorV3(MainnetAddresses.WBTC_BTC_FEED);
    uint32 public constant MAX_AGE_A = MainnetAddresses.STALENESS_1H;
    uint32 public constant MAX_AGE_B = MainnetAddresses.STALENESS_24H;
    int256 public immutable ANSWER;

    constructor(int256 answer) {
        ANSWER = answer;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "BTC / USD * WBTC / BTC";
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, ANSWER, block.timestamp, block.timestamp, 0);
    }
}

/// @notice An ERC-20 whose `symbol()` and `decimals()` answer the raw bytes it was built with, in place of an ABI string
///         and a uint8: a bytes32 symbol, a string whose offset or length points past the answer, a decimals word that
///         no uint8 fits.
contract RawAnswersToken is ERC20 {
    bytes internal _symbolAnswer;
    bytes internal _decimalsAnswer;

    constructor(bytes memory symbolAnswer, bytes memory decimalsAnswer) ERC20("Raw", "RAW") {
        _symbolAnswer = symbolAnswer;
        _decimalsAnswer = decimalsAnswer;
    }

    function symbol() public view override returns (string memory) {
        _answer(_symbolAnswer);
    }

    function decimals() public view override returns (uint8) {
        _answer(_decimalsAnswer);
    }

    function _answer(bytes memory raw) private pure {
        assembly ("memory-safe") {
            return(add(raw, 32), mload(raw))
        }
    }
}

/// @notice A multisig that reports a threshold but no Safe module list.
contract ThresholdOnly {
    uint256 public getThreshold;

    constructor(uint256 threshold) {
        getThreshold = threshold;
    }
}

/// @notice Stand-in for a smart account whose fallback accepts any call and returns nothing.
contract SilentFallback {
    fallback() external {}
}

/// @notice Runs the deploy scripts in-process so they are compiled, executed and covered by CI.
/// @dev Environment variables are process-global and tests run in parallel, so each variable name is
///      set by exactly one test. In tests, script broadcasts come from DEFAULT_SENDER.
contract ScriptsTest is Test {
    address constant MAINNET_UNIVERSAL_ROUTER = MainnetAddresses.UNIVERSAL_ROUTER;
    /// @dev A dollar per whole token, in the eight decimals a feed answers in.
    int256 constant ONE_DOLLAR = 1e8;

    Deploy deployer;
    ConfigureWhitelist configure;
    SetupTestMarket testMarket;
    MockUniversalRouter router;
    MockMarket market;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");

    function setUp() public {
        deployer = new Deploy();
        configure = new ConfigureWhitelist();
        testMarket = new SetupTestMarket();
        router = new MockUniversalRouter(makeAddr("poolManager"));
        market = new MockMarket();
    }

    function _factory(address owner_, address guardian_) internal returns (IndexFactory) {
        return new IndexFactory(owner_, guardian_);
    }

    /// @dev Two tokens, each with a dollar feed and a reference supply: A with 18 decimals, B with 8.
    function _twoEntries() internal returns (ConfigureWhitelist.Entry[] memory list) {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 8);
        market.config(address(tokenA), ONE_DOLLAR);
        market.config(address(tokenB), ONE_DOLLAR);
        list = new ConfigureWhitelist.Entry[](2);
        list[0] = ConfigureWhitelist.Entry({
            token: address(tokenA),
            feed: address(market.feedOf(address(tokenA))),
            maxStaleness: DEFAULT_STALENESS,
            referenceSupply: 1_000e18
        });
        list[1] = ConfigureWhitelist.Entry({
            token: address(tokenB),
            feed: address(market.feedOf(address(tokenB))),
            maxStaleness: DEFAULT_STALENESS,
            referenceSupply: 21_000_000e8
        });
    }

    function _configFor(ConfigureWhitelist.Entry memory entry)
        internal
        view
        returns (IIndexFactory.TokenConfig memory)
    {
        return configure.configFor(entry);
    }

    /// @dev Every token `list` names, as a LIST that lets each of them be proposed for a first listing. A test that is
    ///      not about LIST passes it, so it keeps the meaning it had before a first listing needed naming (RT-06).
    function _tokens(ConfigureWhitelist.Entry[] memory list) internal pure returns (address[] memory tokens) {
        tokens = new address[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            tokens[i] = list[i].token;
        }
    }

    /// @dev What the Safe does with safe mode's output: every call, from the owner, in order. Each must succeed, because
    ///      the batch is one transaction.
    function _sendAsOwner(IndexFactory factory, bytes[] memory calls) internal {
        address factoryOwner = factory.owner();
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(factoryOwner);
            (bool ok,) = address(factory).call(calls[i]);
            assertTrue(ok, "the Safe batch executes");
        }
    }

    /// @dev The calls safe mode would print, without the labels above them.
    function _safeCalls(
        IndexFactory factory,
        ConfigureWhitelist.Entry[] memory list,
        address[] memory firstListings,
        address[] memory relist
    ) internal view returns (bytes[] memory calls) {
        (calls,) = configure.safeCalldata(factory, list, firstListings, relist);
    }

    // ---------------------------------------------------------------------
    // Deploy
    // ---------------------------------------------------------------------

    function test_L06_checkOwner() public {
        vm.expectRevert(Deploy.OwnerRequired.selector);
        deployer.checkOwner(address(0));
        vm.expectRevert(Deploy.OwnerRequired.selector);
        deployer.checkOwner(DEFAULT_SENDER);
        deployer.checkOwner(owner); // any account is accepted off mainnet

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerMustBeContract.selector, owner));
        deployer.checkOwner(owner);

        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(router))); // EIP-7702 delegated account
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerMustBeContract.selector, delegated));
        deployer.checkOwner(delegated);

        MockSafe singleSigner = new MockSafe(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerThresholdTooLow.selector, address(singleSigner), 1));
        deployer.checkOwner(address(singleSigner));

        deployer.checkOwner(address(new MockSafe(2))); // a real multisig
        deployer.checkOwner(address(router)); // a contract without getThreshold, such as a timelock
        deployer.checkOwner(address(new SilentFallback())); // an empty answer is not a threshold
    }

    function test_XA07_checkOwnerRejectsASafeWithModules() public {
        vm.chainId(1);
        // A module executes as the Safe without any signature, so the threshold would not protect the factory.
        MockSafe withModule = new MockSafe(2);
        address module = makeAddr("module");
        withModule.enableModule(module);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerHasModules.selector, address(withModule), module));
        deployer.checkOwner(address(withModule));

        // A multisig whose module list cannot be read is not accepted on faith.
        address unknown = address(new ThresholdOnly(2));
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerModulesUnknown.selector, unknown));
        deployer.checkOwner(unknown);
        MockSafe malformed = new MockSafe(2);
        malformed.setMalformedModules(true);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerModulesUnknown.selector, address(malformed)));
        deployer.checkOwner(address(malformed));
    }

    function test_FR06_checkGuardian() public {
        vm.expectRevert(Deploy.GuardianRequired.selector);
        deployer.checkGuardian(owner, address(0));
        vm.expectRevert(Deploy.GuardianRequired.selector);
        deployer.checkGuardian(owner, DEFAULT_SENDER);
        vm.expectRevert(Deploy.GuardianRequired.selector);
        deployer.checkGuardian(owner, owner);
        deployer.checkGuardian(owner, guardian);
    }

    function test_resolveRouter() public {
        assertEq(deployer.resolveRouter(address(router)), address(router));

        vm.expectRevert(abi.encodeWithSelector(Deploy.AddressRequired.selector, "UNIVERSAL_ROUTER"));
        deployer.resolveRouter(address(0));
        vm.expectRevert(abi.encodeWithSelector(Deploy.AddressHasNoCode.selector, "UNIVERSAL_ROUTER", owner));
        deployer.resolveRouter(owner);

        vm.chainId(1);
        vm.etch(MAINNET_UNIVERSAL_ROUTER, hex"00");
        assertEq(deployer.resolveRouter(address(0)), MAINNET_UNIVERSAL_ROUTER, "the mainnet default on chain 1");
    }

    function test_XA25_guardianCannotBeTheBroadcastingKey() public {
        // The deploy key is the most exposed key; it must hold no role in the factory.
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Deploy.GuardianIsBroadcaster.selector, guardian));
        deployer.checkGuardian(owner, guardian);
    }

    function test_XA39_rolesCannotBeMarketContracts() public {
        deployer.checkRolesAreNotMarket(owner, guardian, address(router));
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, address(router)));
        deployer.checkRolesAreNotMarket(owner, address(router), address(router));
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, address(router)));
        deployer.deploy(address(router), guardian, address(router)); // the router pasted as OWNER
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, address(router)));
        deployer.deploy(owner, address(router), address(router));
    }

    function test_XA47_mainnetMarketCannotBeOverridden() public {
        vm.chainId(1);
        vm.etch(MAINNET_UNIVERSAL_ROUTER, hex"00");
        address other = address(router); // a contract, but not the mainnet router
        vm.expectRevert(abi.encodeWithSelector(Deploy.MainnetOverride.selector, "UNIVERSAL_ROUTER", other));
        deployer.resolveRouter(other);
        assertEq(
            deployer.resolveRouter(MAINNET_UNIVERSAL_ROUTER), MAINNET_UNIVERSAL_ROUTER, "the default itself is fine"
        );
    }

    function test_deploy() public {
        (IndexFactory factory, IndexZap zap, CompositeFeed wbtcFeed) = deployer.deploy(owner, guardian, address(router));
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(address(zap.FACTORY()), address(factory));
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(IndexHub(factory.IMPLEMENTATION()).FACTORY(), address(factory));
        assertEq(IIndexRule(factory.RULE()).FACTORY(), address(factory));
        assertEq(address(wbtcFeed), address(0), "the composite feed is a chain-1 deployment");
    }

    /// @dev WBTC has no USD feed of its own, so `Deploy` puts the adapter that multiplies BTC/USD by WBTC/BTC on
    ///      chain, and `ConfigureWhitelist` refuses any other address in its place.
    function test_deploy_deploysTheCompositeFeedOnMainnet() public {
        vm.warp(30 days);
        vm.chainId(1);
        vm.etch(MAINNET_UNIVERSAL_ROUTER, address(router).code);
        _etchFeed(MainnetAddresses.BTC_USD_FEED, "BTC / USD", 86_000e8);
        _etchFeed(MainnetAddresses.WBTC_BTC_FEED, "WBTC / BTC", 0.9995e8);
        address safeOwner = address(new MockSafe(2)); // on chain 1 the owner must be a contract

        (,, CompositeFeed wbtcFeed) = deployer.deploy(safeOwner, guardian, address(0));
        assertEq(address(wbtcFeed.FEED_A()), MainnetAddresses.BTC_USD_FEED);
        assertEq(address(wbtcFeed.FEED_B()), MainnetAddresses.WBTC_BTC_FEED);
        assertEq(wbtcFeed.MAX_AGE_A(), MainnetAddresses.STALENESS_1H);
        assertEq(wbtcFeed.MAX_AGE_B(), MainnetAddresses.STALENESS_24H);
        (, int256 answer,,,) = wbtcFeed.latestRoundData();
        assertEq(answer, int256(86_000e8) * 0.9995e8 / 1e8, "the product of the two legs");

        configure.checkWbtcFeed(address(wbtcFeed));
    }

    /// @dev The adapter is deployed rather than constant, so the address an operator passes is checked against the
    ///      two feeds it is supposed to multiply before the default list is built from it.
    function test_checkWbtcFeed_rejectsAnAdapterOverTheWrongLegs() public {
        _etchFeed(MainnetAddresses.BTC_USD_FEED, "BTC / USD", 86_000e8);
        _etchFeed(MainnetAddresses.WBTC_BTC_FEED, "WBTC / BTC", 0.9995e8);
        TestAggregator wrong = new TestAggregator("ETH / USD", 8, 3_000e8);

        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.WrongCompositeFeed.selector, owner));
        configure.checkWbtcFeed(owner); // no code

        // A contract that has code but is not a composite feed at all.
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.WrongCompositeFeed.selector, address(wrong)));
        configure.checkWbtcFeed(address(wrong));

        CompositeFeed badA = new CompositeFeed(
            wrong,
            IAggregatorV3(MainnetAddresses.WBTC_BTC_FEED),
            MainnetAddresses.STALENESS_1H,
            MainnetAddresses.STALENESS_24H
        );
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.WrongCompositeFeed.selector, address(badA)));
        configure.checkWbtcFeed(address(badA));

        CompositeFeed badB = new CompositeFeed(
            IAggregatorV3(MainnetAddresses.BTC_USD_FEED),
            wrong,
            MainnetAddresses.STALENESS_1H,
            MainnetAddresses.STALENESS_24H
        );
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.WrongCompositeFeed.selector, address(badB)));
        configure.checkWbtcFeed(address(badB));

        CompositeFeed badAge = new CompositeFeed(
            IAggregatorV3(MainnetAddresses.BTC_USD_FEED),
            IAggregatorV3(MainnetAddresses.WBTC_BTC_FEED),
            MainnetAddresses.STALENESS_24H,
            MainnetAddresses.STALENESS_24H
        );
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.WrongCompositeFeed.selector, address(badAge)));
        configure.checkWbtcFeed(address(badAge));

        CompositeFeed badAgeB = new CompositeFeed(
            IAggregatorV3(MainnetAddresses.BTC_USD_FEED),
            IAggregatorV3(MainnetAddresses.WBTC_BTC_FEED),
            MainnetAddresses.STALENESS_1H,
            MainnetAddresses.STALENESS_1H
        );
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.WrongCompositeFeed.selector, address(badAgeB)));
        configure.checkWbtcFeed(address(badAgeB));
    }

    /// @dev Puts a settable aggregator at a mainnet feed's address, so a chain-1 test reads a live answer without a
    ///      fork.
    function _etchFeed(address at, string memory pair, int256 answer) private {
        TestAggregator feed = new TestAggregator(pair, 8, answer);
        // `vm.etch` copies code, not storage, so the etched feed starts with everything zeroed: the answer and the
        // freshness both have to be set through it.
        vm.etch(at, address(feed).code);
        TestAggregator(at).setAnswer(answer);
        TestAggregator(at).setDecimals(8);
        TestAggregator(at).setAge(0);
    }

    function test_deployRun_readsEnvironment() public {
        vm.setEnv("OWNER", vm.toString(owner));
        vm.setEnv("GUARDIAN", vm.toString(guardian));
        vm.setEnv("UNIVERSAL_ROUTER", vm.toString(address(router)));
        (IndexFactory factory, IndexZap zap,) = deployer.run();
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(IIndexRule(factory.RULE()).FACTORY(), address(factory));
    }

    // ---------------------------------------------------------------------
    // ConfigureWhitelist
    // ---------------------------------------------------------------------

    /// @dev No token named for relisting.
    address[] none;

    function test_parseEntry() public {
        string memory token = vm.toString(address(router));
        string memory feed = vm.toString(owner);

        ConfigureWhitelist.Entry memory e =
            configure.parseEntry(string.concat(token, ":", feed, ":88200:120000000000000000000000000"));
        assertEq(e.token, address(router));
        assertEq(e.feed, owner);
        assertEq(e.maxStaleness, 88_200);
        assertEq(e.referenceSupply, 120_000_000e18);

        e = configure.parseEntry(string.concat(token, ":", feed, ":9:7"));
        assertEq(e.maxStaleness, 9);
        assertEq(e.referenceSupply, 7);

        // CR-L03: the reference supply is no longer optional. A three-field entry, or one whose supply is empty, used
        // to parse as supply 0, which switched the token to its own live supply and stepped around DA-18's bound.
        string memory threeFields = string.concat(token, ":", feed, ":5400");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, threeFields));
        configure.parseEntry(threeFields);
        string memory emptySupply = string.concat(token, ":", feed, ":9:");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, emptySupply));
        configure.parseEntry(emptySupply);

        // DA-10 removed the exclusion field, so an entry that still carries one is malformed.
        string memory withExclusions = string.concat(token, ":", feed, ":9:7:", vm.toString(makeAddr("burn")));
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, withExclusions));
        configure.parseEntry(withExclusions);

        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, token));
        configure.parseEntry(token);
        string memory noStaleness = string.concat(token, ":", feed);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, noStaleness));
        configure.parseEntry(noStaleness);
    }

    function test_resolveList() public {
        string memory raw = string.concat(
            vm.toString(address(router)),
            ":",
            vm.toString(owner),
            ":5400:3, ",
            vm.toString(owner),
            ":",
            vm.toString(guardian),
            ":88200:5"
        );
        ConfigureWhitelist.Entry[] memory parsed = configure.resolveList(raw, address(0));
        assertEq(parsed.length, 2);
        assertEq(parsed[0].token, address(router));
        assertEq(parsed[1].token, owner);
        assertEq(parsed[1].referenceSupply, 5);

        vm.expectRevert(ConfigureWhitelist.DefaultListOnlyOnMainnet.selector);
        configure.resolveList("default", address(0));

        vm.chainId(1);
        _etchFeed(MainnetAddresses.BTC_USD_FEED, "BTC / USD", 86_000e8);
        _etchFeed(MainnetAddresses.WBTC_BTC_FEED, "WBTC / BTC", 0.9995e8);
        CompositeFeed wbtcFeed = new CompositeFeed(
            IAggregatorV3(MainnetAddresses.BTC_USD_FEED),
            IAggregatorV3(MainnetAddresses.WBTC_BTC_FEED),
            MainnetAddresses.STALENESS_1H,
            MainnetAddresses.STALENESS_24H
        );
        ConfigureWhitelist.Entry[] memory defaults = configure.resolveList("default", address(wbtcFeed));
        ConfigureWhitelist.Entry[] memory expected = configure.defaultMainnetList(address(wbtcFeed));
        assertEq(defaults.length, 7, "the launch list is seven components");
        for (uint256 i = 0; i < defaults.length; ++i) {
            assertEq(defaults[i].token, expected[i].token);
            assertEq(defaults[i].feed, expected[i].feed);
            assertEq(defaults[i].maxStaleness, expected[i].maxStaleness);
            assertEq(defaults[i].referenceSupply, expected[i].referenceSupply);
        }
        assertEq(defaults[0].token, MainnetAddresses.WETH);
        assertEq(defaults[2].feed, address(wbtcFeed), "WBTC is priced through the composite adapter");
        assertEq(defaults[1].referenceSupply, MainnetAddresses.WSTETH_SUPPLY, "wstETH counts a dated figure of its own");
    }

    /// @dev CR-M01. Every entry on the launch list carries a reference supply, wstETH included. wstETH shipped with
    ///      none, so the rule read its live total supply, which a stranger could cut by a third for free by unwrapping
    ///      flash-borrowed wstETH around `startRebalance`. The wrappers carry the supply of what they wrap, because
    ///      their own is only the wrapped or bridged float.
    function test_CRM01_everyDefaultEntryCarriesAReferenceSupply() public {
        vm.chainId(1);
        ConfigureWhitelist.Entry[] memory list = configure.defaultMainnetList(owner);
        for (uint256 i = 0; i < list.length; ++i) {
            assertGt(list[i].referenceSupply, 0, "no component is weighed on a supply read live");
        }
        assertEq(list[1].token, MainnetAddresses.WSTETH);
        assertEq(list[1].referenceSupply, 3_715_183e18, "wstETH's own supply on 2026-09-23, as a dated figure");
    }

    /// @dev Nothing is looked up: what an operator reads in WHITELIST is exactly what the factory is asked to store.
    function test_configFor() public {
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        IIndexFactory.TokenConfig memory config = _configFor(list[0]);
        assertEq(config.feed, list[0].feed);
        assertEq(config.maxStaleness, DEFAULT_STALENESS);
        assertEq(config.referenceSupply, 1_000e18);

        config = _configFor(list[1]);
        assertEq(config.feed, list[1].feed);
        assertEq(config.referenceSupply, 21_000_000e8);
    }

    /// @dev XA-18: propose mode broadcasts as the owner, so it cannot work for a contract owner such as the mainnet
    ///      Safe; safe mode logs the same calls as calldata instead.
    function test_XA18_proposeRefusesAContractOwner() public {
        MockSafe safe = new MockSafe(2);
        IndexFactory factory = _factory(address(safe), address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();

        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.OwnerIsContract.selector, address(safe)));
        configure.propose(factory, list, _tokens(list), none);

        // The same list in safe mode produces the calls for the Safe to sign, and nothing is proposed on chain.
        bytes[] memory calls = _safeCalls(factory, list, _tokens(list), none);
        assertEq(calls.length, 2);
        assertEq(factory.listingEta(list[0].token), 0);
    }

    /// @dev LR-07: propose mode refused every owner with code. A key that delegated its account under EIP-7702 has 23
    ///      bytes of code and still signs, which is the usual owner on a testnet or a local fork.
    function test_LR07_proposeAcceptsAnOwnerKeyDelegatedUnderEip7702() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        vm.etch(DEFAULT_SENDER, abi.encodePacked(hex"ef0100", address(this)));

        configure.propose(factory, list, _tokens(list), none);
        assertGt(factory.listingEta(list[0].token), 0, "the delegated key proposed");
        assertGt(factory.listingEta(list[1].token), 0);
    }

    /// @dev XA-38: the release record freezes what was deployed, and the check proves a deployment is one build.
    function test_XA38_checkDeploymentFreezesTheCodeHashes() public {
        address safeOwner = address(new MockSafe(2));
        (IndexFactory factory, IndexZap zap,) = deployer.deploy(safeOwner, guardian, address(router));

        bytes32[4] memory codehashes = deployer.checkDeployment(factory, zap);
        assertEq(codehashes[0], keccak256(address(factory).code));
        assertEq(codehashes[1], keccak256(factory.RULE().code));
        assertEq(codehashes[2], keccak256(factory.IMPLEMENTATION().code));
        assertEq(codehashes[3], keccak256(address(zap).code));

        // A zap from another deployment is not part of this one.
        (IndexFactory other,,) = deployer.deploy(safeOwner, guardian, address(router));
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.WrongWiring.selector, "IndexZap.FACTORY", address(other), address(factory))
        );
        deployer.checkDeployment(other, zap);
    }

    function test_FR05_proposeThenExecute() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();

        configure.execute(factory, list); // nothing proposed yet: nothing happens
        assertEq(factory.listingEta(list[0].token), 0);

        configure.propose(factory, list, _tokens(list), none);
        uint256 eta = block.timestamp + factory.LISTING_DELAY();
        assertEq(factory.listingEta(list[0].token), eta);
        assertEq(factory.listingEta(list[1].token), eta);
        assertEq(factory.pendingTokenConfig(list[1].token).referenceSupply, 21_000_000e8);

        vm.warp(block.timestamp + 1 hours);
        configure.propose(factory, list, _tokens(list), none); // already pending: skipped, eta unchanged
        assertEq(factory.listingEta(list[0].token), eta);

        configure.execute(factory, list); // not ready yet: skipped
        assertFalse(factory.isWhitelisted(list[0].token));

        vm.warp(eta);
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token));
        assertTrue(factory.isWhitelisted(list[1].token));
        assertEq(factory.tokenConfig(list[0].token).referenceSupply, list[0].referenceSupply);

        configure.propose(factory, list, _tokens(list), none); // listed with exactly this config: skipped
        assertEq(factory.listingEta(list[0].token), 0);
        configure.execute(factory, list); // nothing pending: skipped
        assertEq(factory.whitelistedTokens().length, 2);

        list[1].referenceSupply = 21_000_001e8; // a different config is proposed as a config change
        configure.propose(factory, list, _tokens(list), none);
        assertEq(factory.listingEta(list[0].token), 0);
        assertEq(factory.listingEta(list[1].token), block.timestamp + factory.LISTING_DELAY());
    }

    function test_propose_skipsConfigsTheRuleRejects() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        market.setPrice(list[0].token, 0); // a feed the rule will not price from
        list[1].feed = address(0); // and an entry that names no feed at all

        configure.propose(factory, list, _tokens(list), none);
        assertEq(factory.listingEta(list[0].token), 0);
        assertEq(factory.listingEta(list[1].token), 0);
    }

    function test_FR05_executeWorksFromAnyAccountAndNeverReproposesACancelledListing() public {
        IndexFactory factory = _factory(owner, guardian); // the broadcaster is neither owner nor guardian
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        IIndexFactory.TokenConfig memory configA = _configFor(list[0]);
        IIndexFactory.TokenConfig memory configB = _configFor(list[1]);
        vm.startPrank(owner);
        factory.proposeListing(list[0].token, configA);
        factory.proposeListing(list[1].token, configB);
        vm.stopPrank();
        vm.prank(guardian);
        factory.cancelListing(list[1].token);

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);

        assertTrue(factory.isWhitelisted(list[0].token));
        assertFalse(factory.isWhitelisted(list[1].token));
        assertEq(factory.listingEta(list[1].token), 0, "a cancelled listing stays cancelled");
    }

    function test_expiredProposalsAreSkippedThenProposedAgain() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        configure.propose(factory, list, _tokens(list), none);
        uint256 eta = factory.listingEta(list[0].token);

        vm.warp(eta + factory.PROPOSAL_WINDOW() + 1);
        configure.execute(factory, list); // expired: skipped
        assertFalse(factory.isWhitelisted(list[0].token));

        configure.propose(factory, list, _tokens(list), none); // proposed again with a fresh delay
        assertEq(factory.listingEta(list[0].token), block.timestamp + factory.LISTING_DELAY());
    }

    function test_safeCalldata_matchesProposeAndWorksWhenTheOwnerSendsIt() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();

        bytes[] memory calls = _safeCalls(factory, list, _tokens(list), none);
        assertEq(calls.length, 2);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(calls[i], abi.encodeCall(IIndexFactory.proposeListing, (list[i].token, _configFor(list[i]))));
        }

        vm.prank(owner);
        (bool ok,) = address(factory).call(calls[0]);
        assertTrue(ok);
        assertEq(factory.listingEta(list[0].token), block.timestamp + factory.LISTING_DELAY());

        calls = _safeCalls(factory, list, _tokens(list), none); // the first is pending now
        assertEq(calls.length, 1);
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeListing, (list[1].token, _configFor(list[1]))));

        market.setPrice(list[1].token, 0); // the rule rejects the second
        assertEq(_safeCalls(factory, list, _tokens(list), none).length, 0);
    }

    /// @dev DA-20. With a config-only proposal already pending for a delisted token, RELIST was silently dropped:
    ///      the entry was reported as "already pending" and the operator waited out the delay for a relisting that
    ///      was never proposed, while `execute` reported success and the token stayed delisted.
    function test_DA20_relistIsNotSwallowedByAPendingConfigChange() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        configure.propose(factory, list, _tokens(list), none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        vm.prank(guardian);
        factory.delist(list[0].token);

        // A config change is proposed for the delisted token, and only then is it named for relisting.
        list[0].maxStaleness = DEFAULT_STALENESS / 2;
        configure.propose(factory, list, none, none);
        assertFalse(factory.pendingIsListing(list[0].token), "a config change is pending");

        address[] memory relist = new address[](1);
        relist[0] = list[0].token;
        // The pending config change cannot relist, so nothing is proposed and the run says why.
        assertEq(_safeCalls(factory, list, none, relist).length, 0, "no listing can be proposed yet");
        configure.propose(factory, list, none, relist);
        assertFalse(factory.pendingIsListing(list[0].token), "still only a config change");

        // Executing it leaves the token delisted, as the log now states.
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertFalse(factory.isWhitelisted(list[0].token));

        // Once the proposal is out of the way, RELIST proposes the listing it always meant to.
        bytes[] memory calls = _safeCalls(factory, list, none, relist);
        assertEq(calls.length, 1);
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeListing, (list[0].token, _configFor(list[0]))));
        configure.propose(factory, list, none, relist);
        assertTrue(factory.pendingIsListing(list[0].token), "now it is a listing");
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token), "and the token is listed again");
    }

    // ---------------------------------------------------------------------
    // ConfigureWhitelist._action: one assertion per listing state
    // ---------------------------------------------------------------------

    /// @dev What `_action` decided, read back from the calldata `safeCalldata` emits for a one-entry list: nothing
    ///      means Skip, a `proposeListing` call means List and a `proposeConfig` call means ChangeConfig. `propose`
    ///      and `safeCalldata` take the same branch, which `test_safeCalldata_matchesProposeAndWorksWhenTheOwnerSendsIt`
    ///      pins, so reading the calldata reads the decision. The entry's token is named in LIST.
    function _actionFor(IndexFactory factory, ConfigureWhitelist.Entry memory entry, address[] memory relist)
        internal
        view
        returns (string memory)
    {
        address[] memory named = new address[](1);
        named[0] = entry.token;
        return _actionFor(factory, entry, named, relist);
    }

    /// @dev `_actionFor` with the LIST given.
    function _actionFor(
        IndexFactory factory,
        ConfigureWhitelist.Entry memory entry,
        address[] memory firstListings,
        address[] memory relist
    ) internal view returns (string memory) {
        ConfigureWhitelist.Entry[] memory one = new ConfigureWhitelist.Entry[](1);
        one[0] = entry;
        bytes[] memory calls = _safeCalls(factory, one, firstListings, relist);
        if (calls.length == 0) return "Skip";
        if (bytes4(calls[0]) == IIndexFactory.proposeListing.selector) return "List";
        if (bytes4(calls[0]) == IIndexFactory.proposeConfig.selector) return "ChangeConfig";
        return "Unknown";
    }

    function _entry(address token, address feed, uint32 maxStaleness, uint256 referenceSupply)
        internal
        pure
        returns (ConfigureWhitelist.Entry memory)
    {
        return ConfigureWhitelist.Entry({
            token: token, feed: feed, maxStaleness: maxStaleness, referenceSupply: referenceSupply
        });
    }

    /// @dev A fresh 18-decimal token with a dollar feed, and the entry that lists it.
    function _freshEntry() internal returns (ConfigureWhitelist.Entry memory) {
        MockERC20 token = new MockERC20("M", "M", 18);
        market.config(address(token), ONE_DOLLAR);
        return _entry(address(token), address(market.feedOf(address(token))), DEFAULT_STALENESS, 1_000e18);
    }

    /// @dev Lists an entry's token through the full flow.
    function _listEntry(IndexFactory factory, ConfigureWhitelist.Entry memory entry) internal {
        ConfigureWhitelist.Entry[] memory one = new ConfigureWhitelist.Entry[](1);
        one[0] = entry;
        configure.propose(factory, one, _tokens(one), none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, one);
    }

    /// @dev Every state `_action` distinguishes, each asserted to take the branch the state calls for. The individual
    ///      paths are covered by the tests above; this is the matrix, so a state that stops being distinguished shows
    ///      up here rather than silently taking a neighbour's branch. Closes the `ConfigureWhitelist._action` gap the
    ///      2026-09-21 verification review left open.
    function test_action_matchesEveryListingState() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        address[] memory relist = new address[](1);

        // One token, three configs that differ only in their staleness bound. Each state builds its own Entry:
        // `Entry memory b = a` would alias, not copy, and mutating b would silently change a.
        ConfigureWhitelist.Entry memory fresh = _freshEntry();
        address token = fresh.token;
        address feed = fresh.feed;
        ConfigureWhitelist.Entry memory inForce = _entry(token, feed, DEFAULT_STALENESS, 1_000e18);
        ConfigureWhitelist.Entry memory second = _entry(token, feed, DEFAULT_STALENESS / 2, 1_000e18);
        ConfigureWhitelist.Entry memory third = _entry(token, feed, DEFAULT_STALENESS / 4, 1_000e18);

        // 1. never configured -> List when named in LIST, and Skip otherwise (RT-06)
        assertEq(_actionFor(factory, inForce, none), "List", "never configured");
        assertEq(_actionFor(factory, inForce, none, none), "Skip", "never configured, not named in LIST");

        // 2. listed, config unchanged -> Skip
        _listEntry(factory, inForce);
        assertTrue(factory.isWhitelisted(token));
        assertEq(_actionFor(factory, inForce, none), "Skip", "listed, nothing to change");

        // 3. listed, config changed -> ChangeConfig
        assertEq(_actionFor(factory, second, none), "ChangeConfig", "listed, config differs");

        // 7. a live proposal carrying the entry's own config -> Skip
        ConfigureWhitelist.Entry[] memory one = new ConfigureWhitelist.Entry[](1);
        one[0] = second;
        configure.propose(factory, one, _tokens(one), none);
        assertEq(_actionFor(factory, second, none), "Skip", "the entry's own config is already pending");

        // 8. a live proposal carrying some other config -> Skip, and the pending one has to be cancelled first
        assertEq(_actionFor(factory, third, none), "Skip", "a different config is pending");

        // 9. once that proposal expires it no longer blocks
        vm.warp(block.timestamp + factory.LISTING_DELAY() + factory.PROPOSAL_WINDOW() + 1);
        assertEq(_actionFor(factory, third, none), "ChangeConfig", "an expired proposal no longer blocks");

        // 4/5/6. delisted: config changes only, and a listing only when named in RELIST
        vm.prank(guardian);
        factory.delist(token);
        assertEq(_actionFor(factory, inForce, none), "Skip", "delisted, config unchanged, not named");
        assertEq(_actionFor(factory, third, none), "ChangeConfig", "delisted, config differs, not named");
        relist[0] = token;
        assertEq(_actionFor(factory, inForce, relist), "List", "delisted and named in RELIST");

        // 10. a mint currency is never a component. The rule no longer knows what USDC is, so what refuses this is
        // the script's own policy check against the mainnet addresses, not a contract.
        assertEq(
            _actionFor(factory, _entry(MainnetAddresses.USDC, feed, DEFAULT_STALENESS, 1_000e6), none),
            "Skip",
            "USDC is a mint currency"
        );

        // 11. decimals outside the policy
        MockERC20 twoDecimals = new MockERC20("D", "D", 2);
        market.config(address(twoDecimals), ONE_DOLLAR);
        assertEq(
            _actionFor(
                factory,
                _entry(address(twoDecimals), address(market.feedOf(address(twoDecimals))), DEFAULT_STALENESS, 1_000e2),
                none
            ),
            "Skip",
            "2 decimals is outside 6-18"
        );

        // 12. a config the rule rejects: a staleness bound past MAX_FEED_STALENESS
        uint32 tooLong = IIndexRule(factory.RULE()).MAX_FEED_STALENESS() + 1;
        assertEq(
            _actionFor(factory, _entry(_freshEntry().token, feed, tooLong, 1_000e18), none),
            "Skip",
            "the rule rejects the config"
        );
    }

    function test_XA11_proposeSkipsADelistedTokenUnlessNamedForRelisting() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        configure.propose(factory, list, _tokens(list), none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        vm.prank(guardian);
        factory.delist(list[0].token);

        configure.propose(factory, list, none, none); // a routine run with the same list must not undo the guardian
        assertEq(factory.listingEta(list[0].token), 0);
        assertEq(_safeCalls(factory, list, none, none).length, 0);

        // A changed config for the delisted token is proposed as a config change, which leaves it delisted.
        list[0].maxStaleness = DEFAULT_STALENESS / 2;
        bytes[] memory calls = _safeCalls(factory, list, none, none);
        assertEq(calls.length, 1);
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeConfig, (list[0].token, _configFor(list[0]))));
        configure.propose(factory, list, none, none);
        assertFalse(factory.pendingIsListing(list[0].token));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertFalse(factory.isWhitelisted(list[0].token));
        assertEq(factory.tokenConfig(list[0].token).maxStaleness, DEFAULT_STALENESS / 2);

        // Named in the relist argument, it is proposed as a listing again.
        address[] memory relist = new address[](2);
        (relist[0], relist[1]) = (list[1].token, list[0].token); // naming a listed token too changes nothing for it
        calls = _safeCalls(factory, list, none, relist);
        assertEq(calls.length, 1);
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeListing, (list[0].token, _configFor(list[0]))));
        configure.propose(factory, list, none, relist);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token));
    }

    /// @dev RT-06. XA-11 kept a token the guardian delisted out of a routine run, but a first listing the guardian
    ///      cancelled leaves nothing on chain, so the next routine run with the same list proposed it again, among the
    ///      refreshes and unlabelled in safe mode, and one missed veto window let anyone's execute run list it. A token
    ///      never listed is now proposed only when LIST names it, and a routine run leaves LIST unset.
    function test_RT06_aVetoedFirstListingIsNotProposedAgainByARoutineRun() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        // Launch: the Safe's batch lists both, and the guardian vetoes the second during the notice.
        _sendAsOwner(factory, _safeCalls(factory, list, _tokens(list), none));
        vm.prank(guardian);
        factory.cancelListing(list[1].token);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token));
        assertFalse(factory.isWhitelisted(list[1].token), "the veto holds at launch");

        // A month later, the routine supply refresh: the same list, one supply revised, LIST unset.
        vm.warp(block.timestamp + 30 days);
        list[0].referenceSupply = 1_020e18;
        bytes[] memory calls = _safeCalls(factory, list, none, none);
        assertEq(calls.length, 1, "the refresh alone");
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeConfig, (list[0].token, _configFor(list[0]))));
        _sendAsOwner(factory, calls);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertEq(factory.tokenConfig(list[0].token).referenceSupply, 1_020e18);
        assertFalse(factory.isWhitelisted(list[1].token), "so no missed veto window can list it");

        // RELIST names delisted tokens; it does not stand in for LIST.
        address[] memory named = new address[](1);
        named[0] = list[1].token;
        assertEq(_safeCalls(factory, list, none, named).length, 0, "RELIST is not LIST");
    }

    /// @dev RT-06: propose mode proposes a first listing only for a token LIST names, `all` names every entry of the run
    ///      and no other token, and a vetoed first listing is proposed again only when the operator names it again.
    function test_RT06_aFirstListingIsProposedOnlyWhenNamedInList() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        address[] memory second = new address[](1);
        second[0] = list[1].token;

        configure.propose(factory, list, none, none); // nothing named, so nothing proposed
        assertEq(factory.listingEta(list[0].token), 0, "fail closed");
        assertEq(factory.listingEta(list[1].token), 0);

        configure.propose(factory, list, second, none);
        assertEq(factory.listingEta(list[0].token), 0, "the token LIST leaves out is left alone");
        assertGt(factory.listingEta(list[1].token), 0);
        assertTrue(factory.pendingIsListing(list[1].token), "the named one is proposed as a listing");

        vm.prank(guardian);
        factory.cancelListing(list[1].token);
        configure.propose(factory, list, none, none);
        assertEq(factory.listingEta(list[1].token), 0, "a vetoed first listing stays vetoed");
        configure.propose(factory, list, second, none);
        assertGt(factory.listingEta(list[1].token), 0, "until the operator names it again");

        // The LIST value: `all` is exactly this run's tokens, anything else is addresses, and unset is none.
        assertEq(configure.resolveFirstListings("all", list), _tokens(list));
        assertEq(configure.resolveFirstListings("", list).length, 0);
        address[] memory parsed =
            configure.resolveFirstListings(string.concat(vm.toString(list[0].token), ", ", vm.toString(owner)), list);
        assertEq(parsed.length, 2);
        assertEq(parsed[0], list[0].token);
        assertEq(parsed[1], owner, "an address outside the list is kept, and names nothing the run proposes");
    }

    /// @dev RT-06: safe mode printed bare calldata, so a signer could not tell a listing from a routine config change.
    ///      Each call now comes with the line printed above it: the call, the token's symbol and its address.
    function test_RT06_safeModeLabelsEveryProposal() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        IIndexFactory.TokenConfig memory configA = _configFor(list[0]);
        vm.prank(owner);
        factory.proposeListing(list[0].token, configA);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(list[0].token);

        list[0].referenceSupply = 1_020e18; // a refresh for A beside B's first listing
        (bytes[] memory calls, string[] memory labels) = configure.safeCalldata(factory, list, _tokens(list), none);
        assertEq(calls.length, 2);
        assertEq(labels.length, 2, "one label per call");
        assertEq(labels[0], string.concat("proposeConfig A ", vm.toString(list[0].token)));
        assertEq(bytes4(calls[0]), IIndexFactory.proposeConfig.selector, "and each label names its own call");
        assertEq(labels[1], string.concat("proposeListing B ", vm.toString(list[1].token)));
        assertEq(calls[1], abi.encodeCall(IIndexFactory.proposeListing, (list[1].token, _configFor(list[1]))));
    }

    function test_parseAddresses() public view {
        assertEq(configure.parseAddresses("").length, 0);
        address[] memory parsed =
            configure.parseAddresses(string.concat(vm.toString(owner), " , ", vm.toString(guardian)));
        assertEq(parsed.length, 2);
        assertEq(parsed[0], owner);
        assertEq(parsed[1], guardian);
    }

    function test_XA06_executeSkipsAPendingConfigThatDiffersFromTheEntry() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        IIndexFactory.TokenConfig memory other = _configFor(list[1]);
        other.referenceSupply = 1; // not what the WHITELIST entry says
        vm.prank(owner);
        factory.proposeListing(list[1].token, other);
        vm.warp(block.timestamp + factory.LISTING_DELAY());

        configure.execute(factory, list);
        assertFalse(factory.isWhitelisted(list[1].token), "a config the entry did not ask for is not executed");
        assertGt(factory.listingEta(list[1].token), 0);
        // The Safe calldata for the other entry is still produced; this one waits for a cancel.
        assertEq(_safeCalls(factory, list, _tokens(list), none).length, 1);
    }

    function test_XA40_proposeSkipsTokensOutsideTheWhitelistPolicy() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        MockERC20 twoDecimals = new MockERC20("Two", "TWO", 2);
        MockERC20 ordinary = new MockERC20("Ordinary", "ORD", 18);
        ordinary.mint(address(this), 1e18);
        MockERC20 another = new MockERC20("Another", "ANO", 18); // a list may not name a token twice (RT-24)
        market.config(address(twoDecimals), ONE_DOLLAR);
        address feed = address(market.feedOf(address(twoDecimals)));
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](5);
        list[0] = ConfigureWhitelist.Entry({
            token: address(twoDecimals), feed: feed, maxStaleness: DEFAULT_STALENESS, referenceSupply: 1_000_000e2
        }); // fewer than MIN_DECIMALS decimals
        list[1] = ConfigureWhitelist.Entry({
            token: MainnetAddresses.USDC, feed: feed, maxStaleness: DEFAULT_STALENESS, referenceSupply: 0
        }); // a mint currency, never a component
        list[2] = ConfigureWhitelist.Entry({
            token: address(router), feed: feed, maxStaleness: DEFAULT_STALENESS, referenceSupply: 0
        }); // a contract without decimals()
        list[3] = ConfigureWhitelist.Entry({
            token: address(ordinary), feed: address(router), maxStaleness: DEFAULT_STALENESS, referenceSupply: 1
        }); // a feed that has code but does not answer as an aggregator
        list[4] = ConfigureWhitelist.Entry({
            token: address(another), feed: makeAddr("nothing"), maxStaleness: DEFAULT_STALENESS, referenceSupply: 1
        }); // and one that names an address with no code at all

        configure.propose(factory, list, _tokens(list), none);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(factory.listingEta(list[i].token), 0);
        }
        assertEq(_safeCalls(factory, list, _tokens(list), none).length, 0);
    }

    /// @dev LR-05: `status` only logged, so this test could assert nothing about what it said; swapped messages passed.
    ///      It now returns the report its log lines are written from.
    function test_XA42_statusReportsListingsAndPendingProposals() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        ConfigureWhitelist.Report[] memory reports = configure.status(factory, list);
        assertEq(reports.length, 2);
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(reports[i].token, list[i].token);
            assertFalse(reports[i].listed, "nothing is listed yet");
            assertFalse(reports[i].inForce);
            assertEq(reports[i].eta, 0, "and nothing is pending");
        }

        configure.propose(factory, list, _tokens(list), none);
        reports = configure.status(factory, list);
        for (uint256 i = 0; i < 2; ++i) {
            assertFalse(reports[i].listed);
            assertEq(reports[i].eta, block.timestamp + factory.LISTING_DELAY(), "a proposal is pending");
            assertTrue(reports[i].pendingIsListing, "a listing");
            assertTrue(reports[i].pendingMatches, "as the entry says");
        }

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[1].token));

        IIndexFactory.TokenConfig memory other = _configFor(list[1]);
        other.referenceSupply += 1; // differs from the entry, and stays inside DA-18's bound
        vm.prank(DEFAULT_SENDER);
        factory.proposeConfig(list[1].token, other);
        reports = configure.status(factory, list);
        assertTrue(reports[0].listed);
        assertTrue(reports[0].inForce, "the first entry is in force with nothing pending");
        assertEq(reports[0].eta, 0);
        assertTrue(reports[1].listed);
        assertTrue(reports[1].inForce, "so is the second");
        assertEq(reports[1].eta, block.timestamp + factory.LISTING_DELAY());
        assertFalse(reports[1].pendingIsListing, "with a config change pending");
        assertFalse(reports[1].pendingMatches, "that differs from the entry");
    }

    function test_configureRun_readsEnvironment() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        vm.setEnv("FACTORY", vm.toString(address(factory)));
        vm.setEnv(
            "WHITELIST",
            string.concat(
                vm.toString(list[0].token),
                ":",
                vm.toString(list[0].feed),
                ":",
                vm.toString(DEFAULT_STALENESS),
                ":",
                vm.toString(list[0].referenceSupply)
            )
        );

        vm.setEnv("RELIST", vm.toString(list[0].token)); // parsed by run; nothing here is delisted
        // RT-06: LIST names no entry of this WHITELIST, so neither mode proposes its first listing, and RELIST naming
        // the token does not stand in for LIST.
        vm.setEnv("LIST", vm.toString(list[1].token));
        vm.setEnv("LISTING_MODE", "safe"); // logs each call under its label, broadcasts nothing
        configure.run();
        vm.setEnv("LISTING_MODE", "propose");
        configure.run();
        assertEq(factory.listingEta(list[0].token), 0, "a first listing LIST does not name is not proposed");

        vm.setEnv("LIST", "all"); // every entry of this WHITELIST
        vm.setEnv("LISTING_MODE", "safe"); // logs each call under its label, and still proposes nothing itself
        configure.run();
        assertEq(factory.listingEta(list[0].token), 0);

        vm.setEnv("LISTING_MODE", "propose");
        configure.run();
        assertEq(factory.listingEta(list[0].token), block.timestamp + factory.LISTING_DELAY());

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.setEnv("LISTING_MODE", "execute");
        configure.run();
        assertTrue(factory.isWhitelisted(list[0].token));

        vm.setEnv("LISTING_MODE", "status"); // read-only
        configure.run();

        vm.setEnv("LISTING_MODE", "sideways");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.UnknownMode.selector, "sideways"));
        configure.run();
    }

    // ---------------------------------------------------------------------
    // SetupTestMarket
    // ---------------------------------------------------------------------

    function _uniswap() internal returns (SetupTestMarket.Uniswap memory uniswap) {
        uniswap.factory = address(new MockUniswapV3Factory());
        uniswap.positionManager = address(new MockPositionManager());
        uniswap.weth = address(new MockWETH());
    }

    function _pool(SetupTestMarket.Uniswap memory uniswap, address token, uint24 fee)
        internal
        view
        returns (MockUniswapV3Pool)
    {
        return MockUniswapV3Pool(MockUniswapV3Factory(uniswap.factory).getPool(token, uniswap.weth, fee));
    }

    function test_testMarketSpecs() public view {
        SetupTestMarket.Spec[] memory list = testMarket.specs();
        assertEq(list.length, 5);
        assertEq(list[0].symbol, "tUSDC");
        assertEq(list[0].decimals, 6);
        assertEq(list[0].fee, 500, "the rule prices dollars from the 0.05% pool");
        assertEq(list[0].referenceSupply, 0, "a currency, never listed");
        assertEq(list[1].symbol, "tWBTC");
        assertEq(list[2].symbol, "tLINK");
        assertEq(list[3].symbol, "tUNI");
        assertEq(list[4].symbol, "tAAVE");
        for (uint256 i = 1; i < list.length; ++i) {
            assertGt(list[i].referenceSupply, 0, "faucet supply grows, so components list with a reference supply");
            assertGt(list[i].supply, list[i].dripAmount);
        }
    }

    function test_sepoliaUniswap() public view {
        SetupTestMarket.Uniswap memory uniswap = testMarket.sepoliaUniswap();
        assertEq(uniswap.factory, 0x0227628f3F023bb0B980b67D528571c95c6DaC1c);
        assertEq(uniswap.positionManager, 0x1238536071E1c677A632429e3655c799b22cDA52);
        assertEq(uniswap.weth, 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);
    }

    function test_sqrtPriceX96() public view {
        address low = address(0x1000);
        address high = address(0xF000);
        assertEq(testMarket.sqrtPriceX96(low, high, 18, 1e18), 1 << 96);
        assertEq(testMarket.sqrtPriceX96(high, low, 18, 1e18), 1 << 96);
        // 4e14 WETH wei per whole 6-decimal token is 4e8 raw WETH per raw token, whose square root is 2e4.
        assertEq(testMarket.sqrtPriceX96(low, high, 6, 4e14), 2e4 * (1 << 96));
        assertApproxEqAbs(uint256(testMarket.sqrtPriceX96(high, low, 6, 4e14)), uint256(1 << 96) / 2e4, 1);
    }

    function test_rangeAround() public {
        (int24 lower, int24 upper) = testMarket.rangeAround(0, 500);
        assertEq(lower, -6940);
        assertEq(upper, 6940);
        (lower, upper) = testMarket.rangeAround(68, 3000);
        assertEq(lower, -6900);
        assertEq(upper, 7020);
        (lower, upper) = testMarket.rangeAround(-32, 3000); // upper bound already on a multiple of the spacing
        assertEq(lower, -7020);
        assertEq(upper, 6900);
        (lower, upper) = testMarket.rangeAround(6932, 500); // lower bound already on a multiple of the spacing
        assertEq(lower, 0);
        assertEq(upper, 13_870);
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.UnsupportedFee.selector, 10_000));
        testMarket.rangeAround(0, 10_000);
    }

    function test_createTestMarket() public {
        SetupTestMarket.Uniswap memory uniswap = _uniswap();
        (address[] memory tokens, address[] memory feeds) = testMarket.create(uniswap);
        SetupTestMarket.Spec[] memory list = testMarket.specs();
        assertEq(tokens.length, list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            FaucetToken token = FaucetToken(tokens[i]);
            assertEq(token.symbol(), list[i].symbol);
            assertEq(token.decimals(), list[i].decimals);
            assertEq(token.DRIP_AMOUNT(), list[i].dripAmount);
            assertEq(token.balanceOf(DEFAULT_SENDER), list[i].supply, "the broadcaster holds the starting supply");

            MockUniswapV3Pool pool = _pool(uniswap, tokens[i], list[i].fee);
            assertTrue(address(pool) != address(0));
            assertEq(
                pool.sqrtPriceX96(),
                testMarket.sqrtPriceX96(tokens[i], uniswap.weth, list[i].decimals, list[i].wethPerToken)
            );
            assertEq(
                TestAggregator(feeds[i]).description(),
                string.concat(list[i].symbol, " / USD"),
                "each token gets its own test feed"
            );
            assertEq(TestAggregator(feeds[i]).answer(), list[i].priceUsd8);
            assertEq(TestAggregator(feeds[i]).decimals(), testMarket.FEED_DECIMALS());
        }
    }

    function test_seedTestMarket() public {
        SetupTestMarket.Uniswap memory uniswap = _uniswap();
        (address[] memory tokens,) = testMarket.create(uniswap);
        SetupTestMarket.Spec[] memory list = testMarket.specs();
        _pool(uniswap, tokens[0], list[0].fee).setTick(-198_481);
        _pool(uniswap, tokens[2], list[2].fee).setTick(54_045);
        vm.deal(DEFAULT_SENDER, 1 ether);

        testMarket.seed(uniswap, tokens, 0.3 ether, 0.1 ether);

        MockPositionManager positions = MockPositionManager(uniswap.positionManager);
        assertEq(positions.mints(), list.length);
        assertEq(DEFAULT_SENDER.balance, 0.3 ether, "0.3 + 4 * 0.1 ether wrapped");
        for (uint256 i = 0; i < list.length; ++i) {
            INonfungiblePositionManager.MintParams memory p = positions.position(i + 1);
            uint256 wethAmount = i == 0 ? 0.3 ether : 0.1 ether;
            uint256 tokenAmount = Math.mulDiv(wethAmount * 2, 10 ** list[i].decimals, list[i].wethPerToken);
            bool tokenFirst = tokens[i] < uniswap.weth;
            assertEq(p.token0, tokenFirst ? tokens[i] : uniswap.weth);
            assertEq(p.token1, tokenFirst ? uniswap.weth : tokens[i]);
            assertEq(p.fee, list[i].fee);
            assertEq(tokenFirst ? p.amount1Desired : p.amount0Desired, wethAmount);
            assertEq(tokenFirst ? p.amount0Desired : p.amount1Desired, tokenAmount);
            (int24 lower, int24 upper) = testMarket.rangeAround(_pool(uniswap, tokens[i], list[i].fee).tick(), p.fee);
            assertEq(p.tickLower, lower);
            assertEq(p.tickUpper, upper);
            assertEq(p.recipient, address(this), "positions go to the caller");
            assertEq(p.deadline, block.timestamp + 1 hours);
            assertEq(FaucetToken(tokens[i]).balanceOf(DEFAULT_SENDER), list[i].supply - tokenAmount);
        }
        assertEq(MockWETH(uniswap.weth).balanceOf(uniswap.positionManager), 0.7 ether);
    }

    function test_XA26_seedRefusesAPoolWhosePriceMoved() public {
        SetupTestMarket.Uniswap memory uniswap = _uniswap();
        (address[] memory tokens,) = testMarket.create(uniswap);
        SetupTestMarket.Spec[] memory list = testMarket.specs();
        MockUniswapV3Pool pool = _pool(uniswap, tokens[1], list[1].fee);
        uint160 expected = testMarket.sqrtPriceX96(tokens[1], uniswap.weth, list[1].decimals, list[1].wethPerToken);
        uint160 moved = expected + expected / 10; // anyone can swap dust through the empty pool between the two runs
        pool.setSqrtPriceX96(moved);
        vm.deal(DEFAULT_SENDER, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.PoolPriceMoved.selector, address(pool), moved, expected));
        testMarket.seed(uniswap, tokens, 0.3 ether, 0.1 ether);

        moved = expected - expected / 10; // and below
        pool.setSqrtPriceX96(moved);
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.PoolPriceMoved.selector, address(pool), moved, expected));
        testMarket.seed(uniswap, tokens, 0.3 ether, 0.1 ether);
    }

    function test_seedTestMarket_rejectsTokensThatDoNotMatch() public {
        SetupTestMarket.Uniswap memory uniswap = _uniswap();
        (address[] memory tokens,) = testMarket.create(uniswap);

        address[] memory short = new address[](4);
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.TokenCountMismatch.selector, 5, 4));
        testMarket.seed(uniswap, short, 1, 1);

        (tokens[1], tokens[2]) = (tokens[2], tokens[1]);
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.UnexpectedToken.selector, 1, tokens[1]));
        testMarket.seed(uniswap, tokens, 1, 1);
        (tokens[1], tokens[2]) = (tokens[2], tokens[1]);

        tokens[0] = address(new FaucetToken("Other", "tUSDC", 6, 1, 1)); // right symbol, no pool
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.PoolMissing.selector, tokens[0]));
        testMarket.seed(uniswap, tokens, 1, 1);
    }

    function test_testMarketWhitelist_parsesAsConfigureWhitelistEntries() public {
        SetupTestMarket.Uniswap memory uniswap = _uniswap();
        (address[] memory tokens, address[] memory feeds) = testMarket.create(uniswap);
        SetupTestMarket.Spec[] memory list = testMarket.specs();

        string memory raw = testMarket.whitelist(uniswap.weth, tokens, feeds);
        ConfigureWhitelist.Entry[] memory entries = configure.resolveList(raw, address(0));
        assertEq(entries.length, 5);
        assertEq(entries[0].token, tokens[1]);
        assertEq(entries[0].feed, feeds[1]);
        assertEq(entries[0].maxStaleness, testMarket.TEST_STALENESS());
        assertEq(entries[0].referenceSupply, list[1].referenceSupply);
        assertEq(entries[1].token, uniswap.weth);
        assertEq(entries[1].feed, testMarket.SEPOLIA_ETH_USD_FEED(), "WETH takes Sepolia's real ETH/USD feed");
        assertEq(entries[1].referenceSupply, testMarket.ETH_SUPPLY());
        for (uint256 i = 2; i < 5; ++i) {
            assertEq(entries[i].token, tokens[i]);
            assertEq(entries[i].feed, feeds[i]);
            assertEq(entries[i].referenceSupply, list[i].referenceSupply);
        }
    }

    function test_setupTestMarketRun_readsEnvironment() public {
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.NotSepolia.selector, block.chainid));
        testMarket.run();
        // The chain id is all that keeps the market's settable feeds off mainnet, so it is pinned to Sepolia's own
        // number rather than read back from the script, and chain 1 is refused by name.
        assertEq(testMarket.SEPOLIA_CHAIN_ID(), 11_155_111);
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.NotSepolia.selector, 1));
        testMarket.run();

        vm.etch(testMarket.SEPOLIA_UNISWAP_V3_FACTORY(), address(new MockUniswapV3Factory()).code);
        vm.etch(testMarket.SEPOLIA_POSITION_MANAGER(), address(new MockPositionManager()).code);
        vm.etch(testMarket.SEPOLIA_WETH(), address(new MockWETH()).code);
        vm.chainId(testMarket.SEPOLIA_CHAIN_ID());

        vm.setEnv("MARKET_MODE", "create");
        (address[] memory tokens,) = testMarket.run();
        assertEq(tokens.length, 5);

        string memory joined = vm.toString(tokens[0]);
        for (uint256 i = 1; i < tokens.length; ++i) {
            joined = string.concat(joined, ",", vm.toString(tokens[i]));
        }
        vm.setEnv("MARKET_MODE", "seed");
        vm.setEnv("MARKET_TOKENS", joined);
        vm.setEnv("USD_POOL_WETH", "200000000000000000");
        vm.setEnv("TOKEN_POOL_WETH", "50000000000000000");
        vm.deal(DEFAULT_SENDER, 1 ether);
        (address[] memory seeded,) = testMarket.run();
        assertEq(seeded, tokens);
        assertEq(MockPositionManager(testMarket.SEPOLIA_POSITION_MANAGER()).mints(), 5);
        assertEq(DEFAULT_SENDER.balance, 0.6 ether, "0.2 + 4 * 0.05 ether wrapped");

        vm.setEnv("MARKET_MODE", "upside-down");
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.UnknownMode.selector, "upside-down"));
        testMarket.run();
    }

    // ---------------------------------------------------------------------
    // CR: the security audit of 2026-09-23
    // ---------------------------------------------------------------------

    /// @dev The policy adapter this build deploys, as `Deploy` does on chain 1.
    function _policyWbtcFeed() internal returns (CompositeFeed) {
        return new CompositeFeed(
            IAggregatorV3(MainnetAddresses.BTC_USD_FEED),
            IAggregatorV3(MainnetAddresses.WBTC_BTC_FEED),
            MainnetAddresses.STALENESS_1H,
            MainnetAddresses.STALENESS_24H
        );
    }

    /// @dev CR-L04. `checkWbtcFeed` read four getters, so anything that answered them passed: an upgradeable proxy in
    ///      front of a genuine adapter answers every getter, the description and the price exactly as the adapter
    ///      does, and its admin can reprice WBTC for every index once it is listed. The check now compares the code a
    ///      WBTC_FEED runs with the code of an adapter the run builds itself.
    function test_CRL04_theWbtcFeedIsCheckedByItsCodeNotItsAnswers() public {
        vm.warp(30 days);
        _etchFeed(MainnetAddresses.BTC_USD_FEED, "BTC / USD", 86_000e8);
        _etchFeed(MainnetAddresses.WBTC_BTC_FEED, "WBTC / BTC", 0.9995e8);
        CompositeFeed genuine = _policyWbtcFeed();
        configure.checkWbtcFeed(address(genuine));

        UpgradeableFeedProxy proxy = new UpgradeableFeedProxy(address(_policyWbtcFeed()));
        CompositeFeed viaProxy = CompositeFeed(address(proxy));
        assertEq(address(viaProxy.FEED_A()), MainnetAddresses.BTC_USD_FEED, "every getter answers as the adapter's");
        assertEq(address(viaProxy.FEED_B()), MainnetAddresses.WBTC_BTC_FEED);
        assertEq(viaProxy.MAX_AGE_A(), MainnetAddresses.STALENESS_1H);
        assertEq(viaProxy.MAX_AGE_B(), MainnetAddresses.STALENESS_24H);
        assertEq(viaProxy.description(), genuine.description(), "and so does the string the script logs");
        (, int256 proxied,,,) = viaProxy.latestRoundData();
        (, int256 honest,,,) = genuine.latestRoundData();
        assertEq(proxied, honest, "and the price");
        TestAggregator(MainnetAddresses.BTC_USD_FEED).setAge(uint256(MainnetAddresses.STALENESS_1H) + 1);
        uint256 staleAt = block.timestamp - MainnetAddresses.STALENESS_1H - 1;
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.StaleLeg.selector, MainnetAddresses.BTC_USD_FEED, staleAt));
        viaProxy.latestRoundData(); // and it fails where the adapter fails
        TestAggregator(MainnetAddresses.BTC_USD_FEED).setAge(0);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.WrongCompositeFeed.selector, address(proxy)));
        configure.checkWbtcFeed(address(proxy));

        // What the check keeps out: once listed, the proxy can be pointed at a price of anyone's choosing.
        LookalikeWbtcFeed lookalike = new LookalikeWbtcFeed(1e8);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.WrongCompositeFeed.selector, address(lookalike)));
        configure.checkWbtcFeed(address(lookalike));
        proxy.upgradeTo(address(lookalike));
        assertEq(viaProxy.description(), "BTC / USD * WBTC / BTC", "still named as the adapter");
        assertEq(viaProxy.decimals(), 8);
        (, int256 repriced,,,) = viaProxy.latestRoundData();
        assertEq(repriced, 1e8, "a dollar a bitcoin");

        // The default list is refused the same way, whatever mode would run on it.
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.WrongCompositeFeed.selector, address(proxy)));
        configure.resolveList("default", address(proxy));
    }

    /// @dev CR-L04: what is compared is the executable code with its immutables, without the metadata the compiler
    ///      appends. A genuine adapter from another commit, whose metadata differs over nothing but a comment, still
    ///      matches; code with no room for metadata is hashed whole and can only match itself.
    function test_CRL04_theCodeHashLeavesOutOnlyTheMetadata() public {
        CompositeFeed genuine = _policyWbtcFeed();
        bytes memory code = address(genuine).code;
        uint256 length = code.length;
        uint256 metadata = (uint256(uint8(code[length - 2])) << 8 | uint8(code[length - 1])) + 2;
        assertGt(metadata, 5, "the compiler appends metadata");
        code[length - metadata / 2] ^= bytes1(0xff); // mid-metadata, in the source hash: another commit's build
        address otherBuild = makeAddr("the same adapter from another commit");
        vm.etch(otherBuild, code);
        assertTrue(otherBuild.codehash != address(genuine).codehash, "a different full code hash");
        assertEq(configure.executableCodeHash(otherBuild), configure.executableCodeHash(address(genuine)));
        configure.checkWbtcFeed(otherBuild);

        code[length - metadata - 1] ^= bytes1(0xff); // the last byte of the executable code itself
        address altered = makeAddr("an altered adapter");
        vm.etch(altered, code);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.WrongCompositeFeed.selector, altered));
        configure.checkWbtcFeed(altered);

        // Code too short to carry metadata, or claiming more than it has, is hashed whole.
        address eoa = makeAddr("an account without code");
        assertEq(configure.executableCodeHash(eoa), keccak256(""));
        address oneByte = makeAddr("one byte of code");
        vm.etch(oneByte, hex"fe");
        assertEq(configure.executableCodeHash(oneByte), keccak256(hex"fe"));
        address overclaiming = makeAddr("code claiming more metadata than it has");
        vm.etch(overclaiming, hex"00ffff");
        assertEq(configure.executableCodeHash(overclaiming), keccak256(hex"00ffff"));
        address trailing = makeAddr("one byte of code and one of metadata");
        vm.etch(trailing, hex"aabb0001");
        assertEq(configure.executableCodeHash(trailing), keccak256(hex"aa"), "the last two bytes give the length");
        address[3] memory refused = [eoa, oneByte, overclaiming];
        for (uint256 i = 0; i < refused.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.WrongCompositeFeed.selector, refused[i]));
            configure.checkWbtcFeed(refused[i]);
        }
    }

    /// @dev CR-L08. The fork test pins each feed constant to its pair, but nothing compared which constant, bound and
    ///      supply each default entry carries: `test_resolveList` compares the list with itself, so a UNI/AAVE feed swap
    ///      or a 24-hour bound on ETH/USD passed every test. These are the release record, written as literals so a
    ///      change to the list has to be made twice, in review.
    function test_CRL08_theDefaultListIsTheReleaseRecord() public {
        address wbtcFeed = makeAddr("wbtcFeed");
        ConfigureWhitelist.Entry[] memory l = configure.defaultMainnetList(wbtcFeed);
        assertEq(l.length, 7);
        _assertEntry(
            l[0],
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
            5_400,
            122_070_499e18
        );
        _assertEntry(
            l[1],
            0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0,
            0x164b276057258d81941e97B0a900D4C7B358bCe0,
            88_200,
            3_715_183e18
        );
        _assertEntry(l[2], 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, wbtcFeed, 88_200, 20_087_871e8);
        _assertEntry(
            l[3],
            0xD31a59c85aE9D8edEFeC411D448f90841571b89c,
            0x4ffC43a60e009B551865A93d232E33Fce9f01507,
            88_200,
            587_507_739e9
        );
        _assertEntry(
            l[4],
            0x514910771AF9Ca656af840dff83E8264EcF986CA,
            0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c,
            5_400,
            748_099_970e18
        );
        _assertEntry(
            l[5],
            0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984,
            0x553303d460EE0afB37EdFf9bE42922D8FF63220e,
            5_400,
            620_716_422e18
        );
        _assertEntry(
            l[6],
            0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9,
            0x547a514d5e3769680Ce22B2361c10Ea13619e8a9,
            5_400,
            15_428_841e18
        );
        // The bounds themselves: a heartbeat plus half an hour.
        assertEq(uint256(MainnetAddresses.STALENESS_1H), 1 hours + 30 minutes);
        assertEq(uint256(MainnetAddresses.STALENESS_24H), 24 hours + 30 minutes);
    }

    function _assertEntry(
        ConfigureWhitelist.Entry memory e,
        address token,
        address feed,
        uint32 maxStaleness,
        uint256 referenceSupply
    ) internal pure {
        assertEq(e.token, token, "token");
        assertEq(e.feed, feed, "feed");
        assertEq(uint256(e.maxStaleness), uint256(maxStaleness), "staleness bound");
        assertEq(e.referenceSupply, referenceSupply, "reference supply");
    }

    /// @dev XA-24, CR-I22. The fork test that carries XA-24's id lost its whole-token bound when pricing moved to
    ///      Chainlink, so a decimals slip in a shipped supply passed every test, and a first listing is exactly what
    ///      DA-18's bound does not cover. Offline, with each token's decimals written out independently: every default
    ///      supply is a whole number of tokens between a million and a trillion.
    function test_XA24_CRI22_everyDefaultSupplyIsAPlausibleCountOfWholeTokens() public {
        ConfigureWhitelist.Entry[] memory l = configure.defaultMainnetList(makeAddr("wbtcFeed"));
        uint8[7] memory decimals = [18, 18, 8, 9, 18, 18, 18]; // WETH, wstETH, WBTC, wSOL, LINK, UNI, AAVE
        for (uint256 i = 0; i < l.length; ++i) {
            uint256 one = 10 ** uint256(decimals[i]);
            assertEq(l[i].referenceSupply % one, 0, "rounded down to whole tokens, in raw units");
            assertGe(l[i].referenceSupply / one, 1e6, "at least a million tokens");
            assertLe(l[i].referenceSupply / one, 1e12, "at most a trillion");
        }
    }

    /// @dev CR-I36. Every owner and guardian gate was tested through the helper alone, and the factory takes any owner
    ///      and any guardian, so `deploy` could stop calling the checks with every test still green.
    function test_CRI36_deployItselfRefusesABadOwnerOrGuardian() public {
        vm.expectRevert(Deploy.OwnerRequired.selector);
        deployer.deploy(address(0), guardian, address(router));
        vm.expectRevert(Deploy.OwnerRequired.selector);
        deployer.deploy(DEFAULT_SENDER, guardian, address(router));
        vm.expectRevert(Deploy.GuardianRequired.selector);
        deployer.deploy(owner, owner, address(router));
        vm.expectRevert(Deploy.GuardianRequired.selector);
        deployer.deploy(owner, address(0), address(router));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Deploy.GuardianIsBroadcaster.selector, guardian));
        deployer.deploy(owner, guardian, address(router));

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerMustBeContract.selector, owner));
        deployer.deploy(owner, guardian, address(0));
        MockSafe singleSigner = new MockSafe(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerThresholdTooLow.selector, address(singleSigner), 1));
        deployer.deploy(address(singleSigner), guardian, address(0));
    }

    /// @dev CR-I36: a call that failed is not an answer. A getThreshold that reverts with one word is not a threshold
    ///      of 1, and a module list that reverts is unknown even when its revert data decodes as an empty list.
    function test_CRI36_aFailedSafeCallIsNeverReadAsAnAnswer() public {
        vm.chainId(1);
        deployer.checkOwner(address(new RevertsOneWord())); // not a Safe, so accepted as a contract owner
        address unreadable = address(new ModuleListReverts());
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerModulesUnknown.selector, unreadable));
        deployer.checkOwner(unreadable);
    }

    /// @dev CR-I36. A real Safe 1.3.0 answers a module page from any start other than the sentinel with an empty list,
    ///      even while a module is enabled, so asking from the wrong start would let a Safe with a module through. The
    ///      mock pages from `start` the same way now, which is what pins the script to the sentinel.
    function test_CRI36_theModuleCheckPagesFromTheSentinel() public {
        assertEq(deployer.SENTINEL_MODULES(), address(1));
        MockSafe safe = new MockSafe(2);
        address module = makeAddr("module");
        safe.enableModule(module);
        (address[] memory fromZero,) = safe.getModulesPaginated(address(0), 1);
        (address[] memory fromTwo,) = safe.getModulesPaginated(address(2), 1);
        assertEq(fromZero.length + fromTwo.length, 0, "the mock hides the module from any other start, as 1.3.0 does");
        (address[] memory fromModule, address next) = safe.getModulesPaginated(module, 1);
        assertEq(fromModule.length, 0, "and pages on from an enabled module to the end of the list");
        assertEq(next, address(1));

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerHasModules.selector, address(safe), module));
        deployer.checkOwner(address(safe));
    }

    /// @dev CR-I36: a delegation is code that starts 0xef01, and no contract can deploy code starting 0xef, but code
    ///      whose second byte alone is 0x01 is an ordinary contract. This one answers getThreshold with 1, so it must
    ///      fail as a single-signer Safe rather than be waved through as a key.
    function test_CRI36_onlyTheEf01PrefixMarksADelegatedKey() public {
        vm.chainId(1);
        address multisig = makeAddr("push-one multisig");
        vm.etch(multisig, hex"600160005260206000f3"); // PUSH1 1 PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerThresholdTooLow.selector, multisig, 1));
        deployer.checkOwner(multisig);
    }

    /// @dev A real ERC-20 put at `at` with `decimals` and a dollar feed, and the entry that lists it.
    function _tokenAt(address at, uint8 decimals) internal returns (ConfigureWhitelist.Entry memory) {
        vm.etch(at, address(new MockERC20("T", "T", decimals)).code);
        MockERC20(at).setDecimals(decimals); // `vm.etch` copies code, not the storage the decimals live in
        market.config(at, ONE_DOLLAR);
        return _entry(at, address(market.feedOf(at)), DEFAULT_STALENESS, 1_000_000 * 10 ** uint256(decimals));
    }

    /// @dev CR-I36. USDC and USDT are mint currencies and never components. Offline nothing lives at USDC's address, so
    ///      the existing "USDC is a mint currency" case is refused whether the policy check runs or not; with a real
    ///      token at each address, the policy check is the only thing left to refuse them, and USDT was never tried.
    function test_CRI36_mintCurrenciesAreRefusedByThePolicyItself() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        assertEq(_actionFor(factory, _tokenAt(makeAddr("six decimals"), 6), none), "List", "control: listable");
        assertEq(_actionFor(factory, _tokenAt(MainnetAddresses.USDC, 6), none), "Skip", "USDC is never a component");
        assertEq(_actionFor(factory, _tokenAt(MainnetAddresses.USDT, 6), none), "Skip", "nor is USDT");
    }

    /// @dev CR-I36: the policy is 6 to 18 decimals inclusive, and only 2, 8 and 18 were ever exercised.
    function test_CRI36_sixDecimalsIsInsideThePolicyAndFiveIsNot() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        assertEq(_actionFor(factory, _tokenAt(makeAddr("six"), 6), none), "List", "six decimals is the floor");
        assertEq(_actionFor(factory, _tokenAt(makeAddr("five"), 5), none), "Skip", "five is below it");
    }

    /// @dev CR-I36: the factory treats a proposal as pending and executable through the last second of its window, so
    ///      the script must too: not propose it again, which the factory would refuse, and still execute it.
    function test_CRI36_aProposalIsLiveThroughTheLastSecondOfItsWindow() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory one = new ConfigureWhitelist.Entry[](1);
        one[0] = _tokenAt(makeAddr("edge"), 18);
        configure.propose(factory, one, _tokens(one), none);
        vm.warp(factory.listingEta(one[0].token) + factory.PROPOSAL_WINDOW());
        assertTrue(factory.listingPending(one[0].token), "the factory still counts it");
        assertEq(_actionFor(factory, one[0], none), "Skip", "so the script does not propose it again");
        configure.execute(factory, one);
        assertTrue(factory.isWhitelisted(one[0].token), "and executes it");
    }

    /// @dev CR-I36: a config change that only moves a token to a new feed is a change, and a pending config naming
    ///      some other feed is not the entry's, so execute leaves it alone (XA-06).
    function test_CRI36_aFeedOnlyChangeIsAChange() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory one = new ConfigureWhitelist.Entry[](1);
        one[0] = _tokenAt(makeAddr("migrating"), 18);
        _listEntry(factory, one[0]);
        assertTrue(factory.isWhitelisted(one[0].token));

        TestAggregator newFeed = new TestAggregator("MOCK / USD", 8, ONE_DOLLAR);
        ConfigureWhitelist.Entry memory moved =
            _entry(one[0].token, address(newFeed), one[0].maxStaleness, one[0].referenceSupply);
        assertEq(_actionFor(factory, moved, none), "ChangeConfig", "a new feed is a config change");

        TestAggregator strangers = new TestAggregator("MOCK / USD", 8, ONE_DOLLAR);
        IIndexFactory.TokenConfig memory other = _configFor(one[0]);
        other.feed = address(strangers);
        vm.prank(DEFAULT_SENDER);
        factory.proposeConfig(one[0].token, other);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, one);
        assertEq(factory.tokenConfig(one[0].token).feed, one[0].feed, "a pending config on another feed stays pending");
    }

    /// @dev CR-I36: naming one delisted token in RELIST relists that token and no other the guardian delisted (XA-11).
    function test_CRI36_relistNamesOnlyTheTokensItNames() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory two = new ConfigureWhitelist.Entry[](2);
        two[0] = _tokenAt(makeAddr("named"), 18);
        two[1] = _tokenAt(makeAddr("not named"), 18);
        configure.propose(factory, two, _tokens(two), none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, two);
        vm.startPrank(guardian);
        factory.delist(two[0].token);
        factory.delist(two[1].token);
        vm.stopPrank();

        address[] memory relist = new address[](1);
        relist[0] = two[0].token;
        bytes[] memory calls = _safeCalls(factory, two, _tokens(two), relist);
        assertEq(calls.length, 1, "only the named token is proposed");
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeListing, (two[0].token, _configFor(two[0]))));
    }

    /// @dev CR-I36: a feed that cannot name its pair is skipped, since the description is what lets an operator see
    ///      which pair an address really is.
    function test_CRI36_aFeedThatCannotNameItsPairIsSkipped() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry memory e = _tokenAt(makeAddr("nameless"), 18);
        NamelessFeed nameless = new NamelessFeed();
        assertEq(nameless.decimals(), 8, "a feed in every other respect");
        (, int256 answer,,,) = nameless.latestRoundData();
        assertEq(answer, ONE_DOLLAR);
        e.feed = address(nameless);
        assertEq(_actionFor(factory, e, none), "Skip");
    }

    /// @dev CR-I36: a staleness bound past uint32 is refused, not wrapped around to a bound that looks sensible.
    function test_CRI36_anOversizedStalenessIsRefusedNotWrapped() public {
        uint256 wrapsTo5400 = uint256(type(uint32).max) + 1 + 5_400;
        string memory raw =
            string.concat(vm.toString(address(router)), ":", vm.toString(owner), ":", vm.toString(wrapsTo5400), ":1");
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, wrapsTo5400));
        configure.parseEntry(raw);
    }

    /// @dev XA-39, CR-I37. XA-39 refused a market contract pasted as OWNER, and v3 narrowed the check to the router
    ///      alone: WETH, USDC, the PoolManager, every feed and every token passed as owner or guardian again, and a
    ///      factory owned by one can never be administered. None of them answers getThreshold, so `checkOwner` takes any
    ///      of them for a timelock; this check is what stops them.
    function test_XA39_CRI37_noMarketContractCanHoldARole() public {
        // Anywhere: the router and the PoolManager it settles against.
        address pool = router.poolManager();
        address[] memory market_ = deployer.marketContracts(address(router));
        assertEq(market_.length, 2);
        assertEq(market_[0], address(router));
        assertEq(market_[1], pool);
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, pool));
        deployer.checkRolesAreNotMarket(pool, guardian, address(router));
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, pool));
        deployer.checkRolesAreNotMarket(owner, pool, address(router));

        // On chain 1, every token and feed in the address book as well.
        vm.chainId(1);
        vm.etch(MAINNET_UNIVERSAL_ROUTER, address(new MockUniversalRouter(MainnetAddresses.POOL_MANAGER)).code);
        address[19] memory expected = [
            MAINNET_UNIVERSAL_ROUTER,
            MainnetAddresses.POOL_MANAGER,
            MainnetAddresses.WETH,
            MainnetAddresses.WSTETH,
            MainnetAddresses.WBTC,
            MainnetAddresses.WSOL,
            MainnetAddresses.UNI,
            MainnetAddresses.LINK,
            MainnetAddresses.AAVE,
            MainnetAddresses.USDC,
            MainnetAddresses.USDT,
            MainnetAddresses.ETH_USD_FEED,
            MainnetAddresses.WSTETH_USD_FEED,
            MainnetAddresses.BTC_USD_FEED,
            MainnetAddresses.WBTC_BTC_FEED,
            MainnetAddresses.SOL_USD_FEED,
            MainnetAddresses.UNI_USD_FEED,
            MainnetAddresses.LINK_USD_FEED,
            MainnetAddresses.AAVE_USD_FEED
        ];
        market_ = deployer.marketContracts(MAINNET_UNIVERSAL_ROUTER);
        assertEq(market_.length, expected.length);
        for (uint256 i = 0; i < expected.length; ++i) {
            assertEq(market_[i], expected[i]);
            vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, expected[i]));
            deployer.checkRolesAreNotMarket(expected[i], guardian, MAINNET_UNIVERSAL_ROUTER);
            vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, expected[i]));
            deployer.checkRolesAreNotMarket(owner, expected[i], MAINNET_UNIVERSAL_ROUTER);
        }

        // Through `deploy` itself, the scenario XA-39 was written for: WETH pasted as OWNER, a contract that answers no
        // getThreshold and so passes `checkOwner` as a timelock.
        vm.etch(MainnetAddresses.WETH, address(new SilentFallback()).code);
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, MainnetAddresses.WETH));
        deployer.deploy(MainnetAddresses.WETH, guardian, address(0));
    }

    /// @dev CR-I38. The factory's DA-18 bound was not mirrored in the script, so an entry that moved a reference supply
    ///      past it was proposed rather than skipped: propose mode reverted at that entry, and in a Safe batch, one
    ///      transaction, the refused call took every other proposal down with it. It is skipped with its reason now.
    function test_CRI38_anEntryPastTheSupplyBoundIsSkippedNotBatched() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        configure.propose(factory, list, _tokens(list), none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);

        list[0].referenceSupply *= 100; // a decimals slip, past the factory's order-of-magnitude bound
        list[1].referenceSupply *= 2; // a routine refresh beside it
        bytes[] memory calls = _safeCalls(factory, list, _tokens(list), none);
        assertEq(calls.length, 1, "only the refresh goes into the batch");
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeConfig, (list[1].token, _configFor(list[1]))));

        IndexFactory fresh = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory again = _twoEntries();
        configure.propose(fresh, again, _tokens(again), none);
        vm.warp(block.timestamp + fresh.LISTING_DELAY());
        configure.execute(fresh, again);
        again[0].referenceSupply /= 100;
        again[1].referenceSupply /= 2;
        configure.propose(fresh, again, _tokens(again), none); // propose mode no longer stops at the slip
        assertEq(fresh.listingEta(again[0].token), 0, "the slip is skipped");
        assertGt(fresh.listingEta(again[1].token), 0, "and the refresh after it is proposed");
    }

    /// @dev CR-I38. `executeListing` checks a config again (DA-11), so one entry whose feed had gone stale since its
    ///      proposal reverted the whole execute run and left every other due proposal unexecuted.
    function test_CRI38_executeRunsEveryDueEntryTheRuleStillAccepts() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        configure.propose(factory, list, _tokens(list), none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        market.setAge(list[0].token, uint256(DEFAULT_STALENESS) + 1); // the first entry's feed stops publishing

        configure.execute(factory, list);
        assertFalse(factory.isWhitelisted(list[0].token), "the stale entry is skipped");
        assertGt(factory.listingEta(list[0].token), 0, "and its proposal waits for the feed");
        assertTrue(factory.isWhitelisted(list[1].token), "while the entry after it still executes");

        market.setAge(list[0].token, 0);
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token), "and it executes once the feed publishes again");
    }

    /// @dev CR-M01: every entry needs a reference supply, since the rule reads no other. The rule refuses zero too,
    ///      so the script's own check changes no decision; it logs the reason instead of a raw revert.
    function test_CRM01_theScriptSkipsAnEntryWithoutASupply() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry memory e = _freshEntry();
        e.referenceSupply = 0;
        assertEq(_actionFor(factory, e, none), "Skip", "an entry needs a reference supply");
        e.referenceSupply = 1;
        assertEq(_actionFor(factory, e, none), "List", "and one raw unit is one");
    }

    /// @dev A token without code is skipped with its reason: the factory refuses one, and reading its decimals would
    ///      stop the whole run on an answer that cannot be decoded rather than skip the entry.
    function test_propose_skipsATokenWithoutCode() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry memory e = _freshEntry();
        e.token = makeAddr("no token here");
        assertEq(_actionFor(factory, e, none), "Skip");
    }

    /// @dev CR-I41. The test feeds were converted at 3,000 dollars an ether while the pools were priced at 2,400, so
    ///      the rule's index price sat about a quarter above what the basket cost. Every feed now answers its pool's
    ///      price at one ether price, written out here: tUSDC comes out at a dollar.
    function test_CRI41_everyTestFeedAnswersItsPoolsPriceAtOneEtherPrice() public view {
        assertEq(testMarket.ETH_USD8(), 2_400e8, "mainnet ETH/USD on 2026-09-16, rounded");
        SetupTestMarket.Spec[] memory list = testMarket.specs();
        int256[5] memory expected = [int256(1.00008e8), 75_840e8, 10.8e8, 6.336e8, 120e8];
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(list[i].priceUsd8, expected[i], "the pool's price at 2,400 dollars an ether");
            assertEq(list[i].priceUsd8, testMarket.usd8(list[i].wethPerToken));
        }
        assertApproxEqRel(list[0].priceUsd8, 1e8, 1e14, "tUSDC is a dollar, to its pool price's rounding");
    }

    // ---------------------------------------------------------------------
    // RT: the red team of 2026-09-24 (RT-06 sits beside XA-11)
    // ---------------------------------------------------------------------

    /// @dev RT-22, and the review of its fix. The documented recourse for a token whose decimals changed is its config
    ///      in force proposed again, which the script skipped as already in force. It proposes it now, but only when the
    ///      operator names the token in LIST: no entry field asks for it, and nothing on chain records that the guardian
    ///      vetoed the last one, so, as with a first listing (RT-06), a vetoed refresh otherwise came back on every run
    ///      labelled like a routine supply refresh. Its label says which decimals it records.
    function test_RT22_aTokenWhoseDecimalsMovedGetsItsConfigProposedAgainWhenNamed() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        IIndexRule rule = IIndexRule(factory.RULE());
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        configure.propose(factory, list, _tokens(list), none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        MockERC20 upgraded = MockERC20(list[0].token);
        assertEq(factory.tokenDecimals(address(upgraded)), 18);
        uint256 recordedPrice = rule.price(address(upgraded));
        address[] memory named = new address[](1);
        named[0] = address(upgraded);

        upgraded.setDecimals(17); // its admin changes what it answers; the rule keeps pricing it with the record
        assertEq(rule.price(address(upgraded)), recordedPrice, "a power of ten off the token's own decimals");
        assertEq(_actionFor(factory, list[0], none, none), "Skip", "a routine run does not propose it");
        assertEq(_actionFor(factory, list[0], named, none), "ChangeConfig", "named, the config in force again");
        (bytes[] memory calls, string[] memory labels) = configure.safeCalldata(factory, list, named, none);
        assertEq(calls.length, 1, "for the moved token alone");
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeConfig, (list[0].token, _configFor(list[0]))));
        assertEq(
            labels[0],
            string.concat("proposeConfig (records decimals 18 -> 17) A ", vm.toString(address(upgraded))),
            "labelled for what it records"
        );

        // The guardian vetoes it; the next routine run leaves it vetoed.
        configure.propose(factory, list, named, none);
        vm.prank(guardian);
        factory.cancelListing(address(upgraded));
        vm.warp(block.timestamp + 30 days);
        assertEq(_safeCalls(factory, list, none, none).length, 0, "a vetoed refresh does not come back on its own");

        configure.propose(factory, list, named, none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertEq(factory.tokenDecimals(address(upgraded)), 17, "the record caught up");
        assertEq(rule.price(address(upgraded)), recordedPrice * 10, "and the price with it");
        assertEq(_actionFor(factory, list[0], named, none), "Skip", "after which nothing is left to do");

        // A delisted token still prices the indexes that hold it, so it gets the same refresh, as a config change.
        vm.prank(guardian);
        factory.delist(address(upgraded));
        upgraded.setDecimals(18);
        assertEq(_actionFor(factory, list[0], named, none), "ChangeConfig", "delisted, its decimals moved");
        assertEq(_actionFor(factory, list[0], none, none), "Skip", "and not unless named");
        upgraded.setDecimals(17);
        assertEq(_actionFor(factory, list[0], named, none), "Skip", "delisted, nothing moved");
    }

    /// @dev RT-22: `status` compared the config fields only, so it reported a token priced a power of ten off as
    ///      listed with the entry's config in force. It reports the decimals the rule prices with beside the token's.
    function test_RT22_statusReportsTheRecordedAndTheLiveDecimals() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        ConfigureWhitelist.Report[] memory reports = configure.status(factory, list);
        assertEq(reports[0].recordedDecimals, 0, "nothing is recorded before a listing");
        assertEq(reports[0].liveDecimals, 18);
        assertEq(reports[1].liveDecimals, 8);

        configure.propose(factory, list, _tokens(list), none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        MockERC20(list[1].token).setDecimals(6);
        reports = configure.status(factory, list);
        assertTrue(reports[1].listed && reports[1].inForce && reports[1].eta == 0, "every config field matches");
        assertEq(reports[1].recordedDecimals, 8, "while the rule prices it at 8 decimals");
        assertEq(reports[1].liveDecimals, 6, "and the token answers 6");
        assertEq(reports[0].recordedDecimals, 18);
        assertEq(reports[0].liveDecimals, 18, "the other one is in order");

        // A token that stops answering is reported as 0 rather than stopping the run.
        vm.mockCallRevert(list[0].token, abi.encodeCall(IERC20Metadata.decimals, ()), "");
        reports = configure.status(factory, list);
        assertEq(reports[0].recordedDecimals, 18);
        assertEq(reports[0].liveDecimals, 0);
    }

    /// @dev RT-22, RT-23. The factory refuses to execute a proposal whose token changed its decimals since it was made,
    ///      so execute mode reverted at that entry and left every due proposal after it unexecuted, which CR-I38 had
    ///      stopped a rule rejection from doing. It is skipped with its reason now, and the rest execute.
    function test_RT22_executeSkipsADueProposalWhoseDecimalsChanged() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        configure.propose(factory, list, _tokens(list), none);
        MockERC20(list[0].token).setDecimals(17); // during the notice
        // Propose and safe mode no longer call it "already pending", and status shows the pinned decimals beside the
        // token's own, since the factory can never execute that proposal.
        assertEq(_actionFor(factory, list[0], _tokens(list), none), "Skip", "pending, though it can never execute");
        ConfigureWhitelist.Report[] memory reports = configure.status(factory, list);
        assertEq(reports[0].pendingDecimals, 18, "the proposal pinned 18");
        assertEq(reports[0].liveDecimals, 17, "the token answers 17");
        assertEq(reports[1].pendingDecimals, reports[1].liveDecimals, "the other proposal is in order");
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.DecimalsChanged.selector, list[0].token, 18, 17));
        factory.executeListing(list[0].token);

        configure.execute(factory, list);
        assertFalse(factory.isWhitelisted(list[0].token), "the moved token is skipped");
        assertGt(factory.listingEta(list[0].token), 0, "and its proposal waits to be cancelled");
        assertTrue(factory.isWhitelisted(list[1].token), "while the entry after it executes");

        // The recourse the log names: cancel it and propose it again, with the new decimals on show.
        vm.prank(DEFAULT_SENDER);
        factory.cancelListing(list[0].token);
        configure.propose(factory, list, _tokens(list), none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token));
        assertEq(factory.tokenDecimals(list[0].token), 17);
    }

    /// @dev RT-24. Safe mode decides every entry against the same state, so a token named twice got a proposal for each
    ///      copy, and the Safe batch, one transaction, always reverted at the second with ListingPending. A list that
    ///      names a token twice is refused before anything is printed or proposed.
    function test_RT24_aListNamingATokenTwiceIsRefused() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory two = _twoEntries();
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](3);
        (list[0], list[1]) = (two[0], two[1]);
        list[2] = _entry(two[0].token, two[0].feed, DEFAULT_STALENESS, 1_100e18); // an edited copy, appended
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.DuplicateEntry.selector, two[0].token));
        configure.safeCalldata(factory, list, _tokens(list), none);

        IndexFactory keyOwned = _factory(DEFAULT_SENDER, guardian);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.DuplicateEntry.selector, two[0].token));
        configure.propose(keyOwned, list, _tokens(list), none);
        assertEq(keyOwned.listingEta(two[1].token), 0, "nothing is proposed");

        string memory entry = string.concat(vm.toString(address(router)), ":", vm.toString(owner), ":5400:");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.DuplicateEntry.selector, address(router)));
        configure.resolveList(string.concat(entry, "3, ", entry, "5"), address(0));

        // Without the copy, the batch is the two proposals and executes.
        bytes[] memory calls = _safeCalls(factory, two, _tokens(two), none);
        assertEq(calls.length, 2);
        _sendAsOwner(factory, calls);
    }

    /// @dev The line of a one-entry run's only proposal, a first listing of a token with a dollar feed.
    function _labelOf(IndexFactory factory, address token) internal returns (string memory) {
        market.config(token, ONE_DOLLAR);
        ConfigureWhitelist.Entry[] memory one = new ConfigureWhitelist.Entry[](1);
        one[0] = _entry(token, address(market.feedOf(token)), DEFAULT_STALENESS, 1_000e18);
        (bytes[] memory calls, string[] memory labels) = configure.safeCalldata(factory, one, _tokens(one), none);
        assertEq(calls.length, 1, "the entry is proposed whatever its symbol");
        return labels[0];
    }

    /// @dev RT-25. `_symbolOf` promised that a token answering `symbol()` in another shape could not stop the run, but
    ///      it only turned away answers under 64 bytes: a longer one whose offset or length pointed past its end
    ///      reached `abi.decode` and reverted the whole safe, propose or execute run. Every shape is "?" now, and the
    ///      boundaries of both checks are pinned with the shortest answers that are and are not strings.
    function test_RT25_aSymbolInAnotherShapeIsAQuestionMarkNotARevert() public {
        IndexFactory factory = _factory(owner, guardian);
        bytes memory eighteen = abi.encode(uint256(18));
        bytes[7] memory answers = [
            abi.encode(bytes32("MKR")), // a bytes32 symbol, as MKR's
            abi.encode(bytes32(0)), // an unset one, which would decode as an empty string if read as a string
            abi.encode(uint256(0x40), uint256(3)), // an offset past the end
            abi.encode(uint256(0x20), type(uint256).max), // a length past the end, the red team's shape
            abi.encode(uint256(0x20), uint256(1)), // a length one byte past the end
            abi.encode(""), // the shortest string: offset 0x20, length 0
            abi.encode(uint256(0x40), uint256(0), uint256(0)) // the last word as the length, the furthest offset allowed
        ];
        string[7] memory symbols = ["?", "?", "?", "?", "?", "", ""];
        for (uint256 i = 0; i < answers.length; ++i) {
            address token = address(new RawAnswersToken(answers[i], eighteen));
            assertEq(_labelOf(factory, token), string.concat("proposeListing ", symbols[i], " ", vm.toString(token)));
        }
        address genuine = address(new RawAnswersToken(abi.encode("RAW"), eighteen));
        assertEq(_labelOf(factory, genuine), string.concat("proposeListing RAW ", vm.toString(genuine)));
    }

    /// @dev RT-25, for the decimals the script now reads once for the policy, the RT-22 check and `status`: an answer
    ///      that is not a uint8 is no answer. A `try` call reverted the whole run on one, since its answer is decoded
    ///      in the caller, where no `catch` reaches, and a plain cast would have read 274 as 18.
    function test_RT25_aDecimalsAnswerInAnotherShapeIsSkippedNotFatal() public {
        IndexFactory factory = _factory(owner, guardian);
        bytes[3] memory answers = [abi.encode(uint256(256 + 18)), bytes(hex"12"), abi.encode(uint256(18))];
        string[3] memory actions = ["Skip", "Skip", "List"];
        uint8[3] memory reported = [0, 0, 18];
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](3);
        for (uint256 i = 0; i < answers.length; ++i) {
            address token = address(new RawAnswersToken(abi.encode("RAW"), answers[i]));
            market.config(token, ONE_DOLLAR);
            list[i] = _entry(token, address(market.feedOf(token)), DEFAULT_STALENESS, 1e30);
            assertEq(_actionFor(factory, list[i], none), actions[i]);
        }
        ConfigureWhitelist.Report[] memory reports = configure.status(factory, list);
        for (uint256 i = 0; i < answers.length; ++i) {
            assertEq(reports[i].liveDecimals, reported[i], "status reads the same answer the same way");
        }
    }

    /// @dev RT-25 (mutant N16). The factory takes a reference supply revision of exactly MAX_SUPPLY_CHANGE either way
    ///      (CR-I29), and the script's mirror of that bound must too: with `<` for `<=` it skipped every exactly tenfold
    ///      revision from the Safe batch, and every test still passed. The first step past it either way is skipped.
    function test_RT25_aRevisionOfExactlyMaxSupplyChangeIsProposed() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        _sendAsOwner(factory, _safeCalls(factory, list, _tokens(list), none));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        uint256 bound = factory.MAX_SUPPLY_CHANGE();
        assertEq(bound, 10);
        (address a, address b) = (list[0].token, list[1].token);
        uint256 supplyA = list[0].referenceSupply;
        uint256 supplyB = list[1].referenceSupply;
        assertEq(supplyB % bound, 0, "B's supply divides exactly");

        assertEq(_actionFor(factory, _entry(a, list[0].feed, DEFAULT_STALENESS, supplyA * bound + bound), none), "Skip");
        assertEq(_actionFor(factory, _entry(b, list[1].feed, DEFAULT_STALENESS, supplyB / bound - 1), none), "Skip");

        list[0].referenceSupply = supplyA * bound; // exactly tenfold up
        list[1].referenceSupply = supplyB / bound; // and exactly tenfold down
        bytes[] memory calls = _safeCalls(factory, list, none, none);
        assertEq(calls.length, 2, "both are inside the bound");
        _sendAsOwner(factory, calls); // and the factory takes both
        assertEq(factory.pendingTokenConfig(a).referenceSupply, supplyA * bound);
        assertEq(factory.pendingTokenConfig(b).referenceSupply, supplyB / bound);
    }
}
