// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {ConfigureWhitelist} from "../script/ConfigureWhitelist.s.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../src/interfaces/IIndexRule.sol";
import {SetupTestMarket} from "../script/testnet/SetupTestMarket.s.sol";
import {FaucetToken} from "../script/testnet/FaucetToken.sol";
import {INonfungiblePositionManager} from "../script/interfaces/INonfungiblePositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DEFAULT_STALENESS, MockMarket} from "./mocks/MockMarket.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./mocks/MockUniswapV3.sol";
import {CompositeFeed} from "../src/CompositeFeed.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {TestAggregator} from "../script/testnet/TestAggregator.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// @notice Stand-in for a Safe: the deploy script only reads its signature threshold.
contract MockSafe {
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

    /// @notice Safe's module list, one page from the sentinel; a single word instead when set malformed.
    function getModulesPaginated(address, uint256 pageSize)
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
        uint256 n = _modules.length < pageSize ? _modules.length : pageSize;
        page = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            page[i] = _modules[i];
        }
        next = n < _modules.length ? _modules[n] : address(1);
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

    /// @dev Two tokens with 0.3% WETH pools: A on its own total supply, B on a reference supply.
    function _twoEntries() internal returns (ConfigureWhitelist.Entry[] memory list) {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 8);
        tokenA.mint(address(this), 1_000e18);
        market.config(address(tokenA), ONE_DOLLAR);
        market.config(address(tokenB), ONE_DOLLAR);
        list = new ConfigureWhitelist.Entry[](2);
        list[0] = ConfigureWhitelist.Entry({
            token: address(tokenA),
            feed: address(market.feedOf(address(tokenA))),
            maxStaleness: DEFAULT_STALENESS,
            referenceSupply: 0
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
        assertEq(IndexToken(factory.IMPLEMENTATION()).FACTORY(), address(factory));
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

        ConfigureWhitelist.Entry memory e = configure.parseEntry(string.concat(token, ":", feed, ":5400"));
        assertEq(e.token, address(router));
        assertEq(e.feed, owner);
        assertEq(e.maxStaleness, 5_400);
        assertEq(e.referenceSupply, 0);

        e = configure.parseEntry(string.concat(token, ":", feed, ":88200:120000000000000000000000000"));
        assertEq(e.maxStaleness, 88_200);
        assertEq(e.referenceSupply, 120_000_000e18);

        e = configure.parseEntry(string.concat(token, ":", feed, ":9:"));
        assertEq(e.maxStaleness, 9);
        assertEq(e.referenceSupply, 0, "an empty reference supply field means on-chain supply");

        e = configure.parseEntry(string.concat(token, ":", feed, ":9:7"));
        assertEq(e.referenceSupply, 7);

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
            ":5400, ",
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
        assertEq(defaults[1].referenceSupply, 0, "wstETH counts its own total supply");
    }

    /// @dev Every wrapper on the launch list carries the supply of what it wraps, because its own is only the wrapped
    ///      or bridged float. A missing one would silently shrink that component's market cap to the float.
    function test_default_listCarriesReferenceSuppliesForWrappers() public {
        vm.chainId(1);
        ConfigureWhitelist.Entry[] memory list = configure.defaultMainnetList(owner);
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i].token == MainnetAddresses.WSTETH) continue;
            assertGt(list[i].referenceSupply, 0, "every component but wstETH carries a reference supply");
        }
    }

    /// @dev Nothing is looked up: what an operator reads in WHITELIST is exactly what the factory is asked to store.
    function test_configFor() public {
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        IIndexFactory.TokenConfig memory config = _configFor(list[0]);
        assertEq(config.feed, list[0].feed);
        assertEq(config.maxStaleness, DEFAULT_STALENESS);
        assertEq(config.referenceSupply, 0);

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
        configure.propose(factory, list, none);

        // The same list in safe mode produces the calls for the Safe to sign, and nothing is proposed on chain.
        bytes[] memory calls = configure.safeCalldata(factory, list, none);
        assertEq(calls.length, 2);
        assertEq(factory.listingEta(list[0].token), 0);
    }

    /// @dev LR-07: propose mode refused every owner with code. A key that delegated its account under EIP-7702 has 23
    ///      bytes of code and still signs, which is the usual owner on a testnet or a local fork.
    function test_LR07_proposeAcceptsAnOwnerKeyDelegatedUnderEip7702() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        vm.etch(DEFAULT_SENDER, abi.encodePacked(hex"ef0100", address(this)));

        configure.propose(factory, list, none);
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

        configure.propose(factory, list, none);
        uint256 eta = block.timestamp + factory.LISTING_DELAY();
        assertEq(factory.listingEta(list[0].token), eta);
        assertEq(factory.listingEta(list[1].token), eta);
        assertEq(factory.pendingTokenConfig(list[1].token).referenceSupply, 21_000_000e8);

        vm.warp(block.timestamp + 1 hours);
        configure.propose(factory, list, none); // already pending: skipped, eta unchanged
        assertEq(factory.listingEta(list[0].token), eta);

        configure.execute(factory, list); // not ready yet: skipped
        assertFalse(factory.isWhitelisted(list[0].token));

        vm.warp(eta);
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token));
        assertTrue(factory.isWhitelisted(list[1].token));
        assertEq(factory.tokenConfig(list[0].token).referenceSupply, list[0].referenceSupply);

        configure.propose(factory, list, none); // listed with exactly this config: skipped
        assertEq(factory.listingEta(list[0].token), 0);
        configure.execute(factory, list); // nothing pending: skipped
        assertEq(factory.whitelistedTokens().length, 2);

        list[1].referenceSupply = 21_000_001e8; // a different config is proposed as a config change
        configure.propose(factory, list, none);
        assertEq(factory.listingEta(list[0].token), 0);
        assertEq(factory.listingEta(list[1].token), block.timestamp + factory.LISTING_DELAY());
    }

    function test_propose_skipsConfigsTheRuleRejects() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        market.setPrice(list[0].token, 0); // a feed the rule will not price from
        list[1].feed = address(0); // and an entry that names no feed at all

        configure.propose(factory, list, none);
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
        configure.propose(factory, list, none);
        uint256 eta = factory.listingEta(list[0].token);

        vm.warp(eta + factory.PROPOSAL_WINDOW() + 1);
        configure.execute(factory, list); // expired: skipped
        assertFalse(factory.isWhitelisted(list[0].token));

        configure.propose(factory, list, none); // proposed again with a fresh delay
        assertEq(factory.listingEta(list[0].token), block.timestamp + factory.LISTING_DELAY());
    }

    function test_safeCalldata_matchesProposeAndWorksWhenTheOwnerSendsIt() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();

        bytes[] memory calls = configure.safeCalldata(factory, list, none);
        assertEq(calls.length, 2);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(calls[i], abi.encodeCall(IIndexFactory.proposeListing, (list[i].token, _configFor(list[i]))));
        }

        vm.prank(owner);
        (bool ok,) = address(factory).call(calls[0]);
        assertTrue(ok);
        assertEq(factory.listingEta(list[0].token), block.timestamp + factory.LISTING_DELAY());

        calls = configure.safeCalldata(factory, list, none); // the first is pending now
        assertEq(calls.length, 1);
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeListing, (list[1].token, _configFor(list[1]))));

        market.setPrice(list[1].token, 0); // the rule rejects the second
        assertEq(configure.safeCalldata(factory, list, none).length, 0);
    }

    /// @dev DA-20. With a config-only proposal already pending for a delisted token, RELIST was silently dropped:
    ///      the entry was reported as "already pending" and the operator waited out the delay for a relisting that
    ///      was never proposed, while `execute` reported success and the token stayed delisted.
    function test_DA20_relistIsNotSwallowedByAPendingConfigChange() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        configure.propose(factory, list, none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        vm.prank(guardian);
        factory.delist(list[0].token);

        // A config change is proposed for the delisted token, and only then is it named for relisting.
        list[0].maxStaleness = DEFAULT_STALENESS / 2;
        configure.propose(factory, list, none);
        assertFalse(factory.pendingIsListing(list[0].token), "a config change is pending");

        address[] memory relist = new address[](1);
        relist[0] = list[0].token;
        // The pending config change cannot relist, so nothing is proposed and the run says why.
        assertEq(configure.safeCalldata(factory, list, relist).length, 0, "no listing can be proposed yet");
        configure.propose(factory, list, relist);
        assertFalse(factory.pendingIsListing(list[0].token), "still only a config change");

        // Executing it leaves the token delisted, as the log now states.
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertFalse(factory.isWhitelisted(list[0].token));

        // Once the proposal is out of the way, RELIST proposes the listing it always meant to.
        bytes[] memory calls = configure.safeCalldata(factory, list, relist);
        assertEq(calls.length, 1);
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeListing, (list[0].token, _configFor(list[0]))));
        configure.propose(factory, list, relist);
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
    ///      pins, so reading the calldata reads the decision.
    function _actionFor(IndexFactory factory, ConfigureWhitelist.Entry memory entry, address[] memory relist)
        internal
        view
        returns (string memory)
    {
        ConfigureWhitelist.Entry[] memory one = new ConfigureWhitelist.Entry[](1);
        one[0] = entry;
        bytes[] memory calls = configure.safeCalldata(factory, one, relist);
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
        configure.propose(factory, one, none);
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

        // 1. never configured -> List
        assertEq(_actionFor(factory, inForce, none), "List", "never configured");

        // 2. listed, config unchanged -> Skip
        _listEntry(factory, inForce);
        assertTrue(factory.isWhitelisted(token));
        assertEq(_actionFor(factory, inForce, none), "Skip", "listed, nothing to change");

        // 3. listed, config changed -> ChangeConfig
        assertEq(_actionFor(factory, second, none), "ChangeConfig", "listed, config differs");

        // 7. a live proposal carrying the entry's own config -> Skip
        ConfigureWhitelist.Entry[] memory one = new ConfigureWhitelist.Entry[](1);
        one[0] = second;
        configure.propose(factory, one, none);
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
        configure.propose(factory, list, none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        vm.prank(guardian);
        factory.delist(list[0].token);

        configure.propose(factory, list, none); // a routine run with the same list must not undo the guardian
        assertEq(factory.listingEta(list[0].token), 0);
        assertEq(configure.safeCalldata(factory, list, none).length, 0);

        // A changed config for the delisted token is proposed as a config change, which leaves it delisted.
        list[0].maxStaleness = DEFAULT_STALENESS / 2;
        bytes[] memory calls = configure.safeCalldata(factory, list, none);
        assertEq(calls.length, 1);
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeConfig, (list[0].token, _configFor(list[0]))));
        configure.propose(factory, list, none);
        assertFalse(factory.pendingIsListing(list[0].token));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertFalse(factory.isWhitelisted(list[0].token));
        assertEq(factory.tokenConfig(list[0].token).maxStaleness, DEFAULT_STALENESS / 2);

        // Named in the relist argument, it is proposed as a listing again.
        address[] memory relist = new address[](2);
        (relist[0], relist[1]) = (list[1].token, list[0].token); // naming a listed token too changes nothing for it
        calls = configure.safeCalldata(factory, list, relist);
        assertEq(calls.length, 1);
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeListing, (list[0].token, _configFor(list[0]))));
        configure.propose(factory, list, relist);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token));
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
        assertEq(configure.safeCalldata(factory, list, none).length, 1);
    }

    function test_XA40_proposeSkipsTokensOutsideTheWhitelistPolicy() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        MockERC20 twoDecimals = new MockERC20("Two", "TWO", 2);
        MockERC20 ordinary = new MockERC20("Ordinary", "ORD", 18);
        ordinary.mint(address(this), 1e18);
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
            token: address(ordinary), feed: makeAddr("nothing"), maxStaleness: DEFAULT_STALENESS, referenceSupply: 1
        }); // and one that names an address with no code at all

        configure.propose(factory, list, none);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(factory.listingEta(list[i].token), 0);
        }
        assertEq(configure.safeCalldata(factory, list, none).length, 0);
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

        configure.propose(factory, list, none);
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
                vm.toString(list[0].token), ":", vm.toString(list[0].feed), ":", vm.toString(DEFAULT_STALENESS)
            )
        );

        vm.setEnv("RELIST", vm.toString(list[0].token)); // parsed by run; nothing here is delisted
        vm.setEnv("LISTING_MODE", "safe"); // logs the calldata only
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
        (address[] memory tokens, address[] memory feeds) = testMarket.create(uniswap);
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
        (address[] memory tokens, address[] memory feeds) = testMarket.create(uniswap);
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
        (address[] memory tokens, address[] memory feeds) = testMarket.create(uniswap);

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
}
