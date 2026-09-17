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
import {DEFAULT_MIN_LIQUIDITY, MockMarket} from "./mocks/MockMarket.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./mocks/MockUniswapV3.sol";
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
    address constant MAINNET_SWAP_ROUTER_02 = MainnetAddresses.SWAP_ROUTER_02;
    address constant MAINNET_WETH = MainnetAddresses.WETH;
    address constant MAINNET_UNISWAP_V3_FACTORY = MainnetAddresses.UNISWAP_V3_FACTORY;
    address constant MAINNET_USDC = MainnetAddresses.USDC;

    Deploy deployer;
    ConfigureWhitelist configure;
    SetupTestMarket testMarket;
    MockSwapRouter router;
    MockMarket market;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");

    function setUp() public {
        deployer = new Deploy();
        configure = new ConfigureWhitelist();
        testMarket = new SetupTestMarket();
        router = new MockSwapRouter();
        market = new MockMarket();
    }

    function _market() internal view returns (Deploy.Market memory) {
        return Deploy.Market({
            router: address(router),
            weth: address(market.weth()),
            uniswapV3Factory: address(market.uniswapV3Factory()),
            usdc: address(market.usdc())
        });
    }

    function _factory(address owner_, address guardian_) internal returns (IndexFactory) {
        return new IndexFactory(
            owner_, guardian_, address(market.weth()), address(market.uniswapV3Factory()), address(market.usdc())
        );
    }

    /// @dev Two tokens with 0.3% WETH pools: A on on-chain supply with one exclusion, B on a reference supply.
    function _twoEntries() internal returns (ConfigureWhitelist.Entry[] memory list) {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 8);
        tokenA.mint(address(this), 1_000e18);
        market.config(address(tokenA), 0);
        market.config(address(tokenB), 0);
        address[] memory excluded = new address[](1);
        excluded[0] = makeAddr("burn");
        list = new ConfigureWhitelist.Entry[](2);
        list[0] = ConfigureWhitelist.Entry({
            token: address(tokenA),
            fee: 3000,
            minLiquidity: DEFAULT_MIN_LIQUIDITY,
            referenceSupply: 0,
            excluded: excluded
        });
        list[1] = ConfigureWhitelist.Entry({
            token: address(tokenB),
            fee: 3000,
            minLiquidity: DEFAULT_MIN_LIQUIDITY,
            referenceSupply: 21_000_000e8,
            excluded: new address[](0)
        });
    }

    function _configFor(ConfigureWhitelist.Entry memory entry)
        internal
        view
        returns (IIndexFactory.TokenConfig memory)
    {
        return configure.configFor(entry, address(market.weth()), address(market.uniswapV3Factory()));
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

    function test_resolveMarket() public {
        Deploy.Market memory resolved = deployer.resolveMarket(_market());
        assertEq(resolved.router, address(router));
        assertEq(resolved.weth, address(market.weth()));
        assertEq(resolved.uniswapV3Factory, address(market.uniswapV3Factory()));
        assertEq(resolved.usdc, address(market.usdc()));

        Deploy.Market memory incomplete;
        vm.expectRevert(abi.encodeWithSelector(Deploy.AddressRequired.selector, "SWAP_ROUTER"));
        deployer.resolveMarket(incomplete);
        incomplete.router = address(router);
        vm.expectRevert(abi.encodeWithSelector(Deploy.AddressRequired.selector, "WETH"));
        deployer.resolveMarket(incomplete);
        incomplete.weth = owner;
        vm.expectRevert(abi.encodeWithSelector(Deploy.AddressHasNoCode.selector, "WETH", owner));
        deployer.resolveMarket(incomplete);
        incomplete.weth = address(market.weth());
        vm.expectRevert(abi.encodeWithSelector(Deploy.AddressRequired.selector, "UNISWAP_V3_FACTORY"));
        deployer.resolveMarket(incomplete);
        incomplete.uniswapV3Factory = address(market.uniswapV3Factory());
        vm.expectRevert(abi.encodeWithSelector(Deploy.AddressRequired.selector, "USDC"));
        deployer.resolveMarket(incomplete);

        vm.chainId(1);
        vm.etch(MAINNET_SWAP_ROUTER_02, hex"00");
        vm.etch(MAINNET_WETH, hex"00");
        vm.etch(MAINNET_UNISWAP_V3_FACTORY, hex"00");
        vm.etch(MAINNET_USDC, hex"00");
        Deploy.Market memory empty;
        Deploy.Market memory defaults = deployer.resolveMarket(empty);
        assertEq(defaults.router, MAINNET_SWAP_ROUTER_02);
        assertEq(defaults.weth, MAINNET_WETH);
        assertEq(defaults.uniswapV3Factory, MAINNET_UNISWAP_V3_FACTORY);
        assertEq(defaults.usdc, MAINNET_USDC);
    }

    function test_XA25_guardianCannotBeTheBroadcastingKey() public {
        // The deploy key is the most exposed key; it must hold no role in the factory.
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Deploy.GuardianIsBroadcaster.selector, guardian));
        deployer.checkGuardian(owner, guardian);
    }

    function test_XA39_rolesCannotBeMarketContracts() public {
        Deploy.Market memory given = _market(); // built before each expectRevert: it reads the market
        Deploy.Market memory resolved = deployer.resolveMarket(given);
        deployer.checkRolesAreNotMarket(owner, guardian, resolved);
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, resolved.router));
        deployer.checkRolesAreNotMarket(owner, resolved.router, resolved);
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, resolved.weth));
        deployer.deploy(resolved.weth, guardian, given); // a market address pasted as OWNER
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, resolved.usdc));
        deployer.deploy(owner, resolved.usdc, given);
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, resolved.uniswapV3Factory));
        deployer.deploy(owner, resolved.uniswapV3Factory, given);
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, resolved.router));
        deployer.deploy(resolved.router, guardian, given);
    }

    function test_XA47_mainnetMarketCannotBeOverridden() public {
        vm.chainId(1);
        vm.etch(MAINNET_SWAP_ROUTER_02, hex"00");
        vm.etch(MAINNET_WETH, hex"00");
        vm.etch(MAINNET_UNISWAP_V3_FACTORY, hex"00");
        vm.etch(MAINNET_USDC, hex"00");
        Deploy.Market memory overridden;
        address otherUsdc = address(market.usdc()); // a contract, but not mainnet USDC
        overridden.usdc = otherUsdc;
        vm.expectRevert(abi.encodeWithSelector(Deploy.MainnetOverride.selector, "USDC", otherUsdc));
        deployer.resolveMarket(overridden);
        overridden.usdc = MAINNET_USDC; // naming the default itself is fine
        assertEq(deployer.resolveMarket(overridden).usdc, MAINNET_USDC);
    }

    function test_deploy() public {
        (IndexFactory factory, IndexZap zap) = deployer.deploy(owner, guardian, _market());
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(address(zap.FACTORY()), address(factory));
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(IndexToken(factory.IMPLEMENTATION()).FACTORY(), address(factory));
        assertEq(IIndexRule(factory.RULE()).USD_POOL(), address(market.usdPool()));
    }

    function test_deployRun_readsEnvironment() public {
        vm.setEnv("OWNER", vm.toString(owner));
        vm.setEnv("GUARDIAN", vm.toString(guardian));
        vm.setEnv("SWAP_ROUTER", vm.toString(address(router)));
        vm.setEnv("WETH", vm.toString(address(market.weth())));
        vm.setEnv("UNISWAP_V3_FACTORY", vm.toString(address(market.uniswapV3Factory())));
        vm.setEnv("USDC", vm.toString(address(market.usdc())));
        (IndexFactory factory, IndexZap zap) = deployer.run();
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(IIndexRule(factory.RULE()).WETH(), address(market.weth()));
    }

    // ---------------------------------------------------------------------
    // ConfigureWhitelist
    // ---------------------------------------------------------------------

    /// @dev No token named for relisting.
    address[] none;

    function test_parseEntry() public {
        string memory token = vm.toString(address(router));
        address burnA = makeAddr("burnA");
        address burnB = makeAddr("burnB");

        ConfigureWhitelist.Entry memory e = configure.parseEntry(string.concat(token, ":3000:5"));
        assertEq(e.token, address(router));
        assertEq(e.fee, 3000);
        assertEq(e.minLiquidity, 5);
        assertEq(e.referenceSupply, 0);
        assertEq(e.excluded.length, 0);

        e = configure.parseEntry(string.concat(token, ":0:0:120000000000000000000000000"));
        assertEq(e.fee, 0);
        assertEq(e.minLiquidity, 0);
        assertEq(e.referenceSupply, 120_000_000e18);

        e = configure.parseEntry(string.concat(token, ":500:9::", vm.toString(burnA), "|", vm.toString(burnB)));
        assertEq(e.minLiquidity, 9);
        assertEq(e.referenceSupply, 0);
        assertEq(e.excluded.length, 2);
        assertEq(e.excluded[0], burnA);
        assertEq(e.excluded[1], burnB);

        e = configure.parseEntry(string.concat(token, ":500:9:7:"));
        assertEq(e.referenceSupply, 7);
        assertEq(e.excluded.length, 0);

        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, token));
        configure.parseEntry(token);
        string memory noMinimum = string.concat(token, ":3000");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, noMinimum));
        configure.parseEntry(noMinimum);
        string memory tooMany = string.concat(token, ":1:2:3:4:5");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, tooMany));
        configure.parseEntry(tooMany);
    }

    function test_resolveList() public {
        string memory raw = string.concat(vm.toString(address(router)), ":3000:1, ", vm.toString(owner), ":0:0:5");
        ConfigureWhitelist.Entry[] memory parsed = configure.resolveList(raw);
        assertEq(parsed.length, 2);
        assertEq(parsed[0].token, address(router));
        assertEq(parsed[1].token, owner);
        assertEq(parsed[1].referenceSupply, 5);

        vm.expectRevert(ConfigureWhitelist.DefaultListOnlyOnMainnet.selector);
        configure.resolveList("default");

        vm.chainId(1);
        ConfigureWhitelist.Entry[] memory defaults = configure.resolveList("default");
        ConfigureWhitelist.Entry[] memory expected = configure.defaultMainnetList();
        assertEq(defaults.length, 15);
        for (uint256 i = 0; i < defaults.length; ++i) {
            assertEq(defaults[i].token, expected[i].token);
            assertEq(defaults[i].fee, expected[i].fee);
            assertEq(defaults[i].minLiquidity, expected[i].minLiquidity);
            assertEq(defaults[i].referenceSupply, expected[i].referenceSupply);
        }
        assertEq(defaults[1].token, MAINNET_WETH);
        assertEq(defaults[1].fee, 0, "WETH has no pool");
    }

    function test_configFor() public {
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        IIndexFactory.TokenConfig memory config = _configFor(list[0]);
        assertEq(config.pool, address(market.tokenPool(list[0].token)));
        assertEq(config.excluded.length, 1);
        assertEq(config.minLiquidity, DEFAULT_MIN_LIQUIDITY);
        assertEq(config.referenceSupply, 0);

        ConfigureWhitelist.Entry memory wethEntry = ConfigureWhitelist.Entry({
            token: address(market.weth()), fee: 0, minLiquidity: 0, referenceSupply: 1e27, excluded: new address[](0)
        });
        config = _configFor(wethEntry);
        assertEq(config.pool, address(0));
        assertEq(config.referenceSupply, 1e27);
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

    /// @dev XA-38: the release record freezes what was deployed, and the check proves a deployment is one build.
    function test_XA38_checkDeploymentFreezesTheCodeHashes() public {
        address safeOwner = address(new MockSafe(2));
        (IndexFactory factory, IndexZap zap) = deployer.deploy(safeOwner, guardian, _market());

        bytes32[4] memory codehashes = deployer.checkDeployment(factory, zap);
        assertEq(codehashes[0], keccak256(address(factory).code));
        assertEq(codehashes[1], keccak256(factory.RULE().code));
        assertEq(codehashes[2], keccak256(factory.IMPLEMENTATION().code));
        assertEq(codehashes[3], keccak256(address(zap).code));

        // A zap from another deployment is not part of this one.
        (IndexFactory other,) = deployer.deploy(safeOwner, guardian, _market());
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
        assertEq(factory.tokenConfig(list[0].token).excluded[0], list[0].excluded[0]);

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
        market.tokenPool(list[0].token).setObservationCardinality(60); // a pool nobody has prepared
        list[1].fee = 500; // no 0.05% pool exists for B

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

        market.tokenPool(list[1].token).setObservationCardinality(60); // the rule rejects the second
        assertEq(configure.safeCalldata(factory, list, none).length, 0);
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
        list[0].minLiquidity = DEFAULT_MIN_LIQUIDITY / 2;
        bytes[] memory calls = configure.safeCalldata(factory, list, none);
        assertEq(calls.length, 1);
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeConfig, (list[0].token, _configFor(list[0]))));
        configure.propose(factory, list, none);
        assertFalse(factory.pendingIsListing(list[0].token));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertFalse(factory.isWhitelisted(list[0].token));
        assertEq(factory.tokenConfig(list[0].token).minLiquidity, DEFAULT_MIN_LIQUIDITY / 2);

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
        vm.prank(owner); // the Safe calldata for the other entry is still produced; this one waits for a cancel
        assertEq(configure.safeCalldata(factory, list, none).length, 1);
    }

    function test_XA40_proposeSkipsTokensOutsideTheWhitelistPolicy() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        MockERC20 twoDecimals = new MockERC20("Two", "TWO", 2);
        market.config(address(twoDecimals), 0);
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](3);
        list[0] = ConfigureWhitelist.Entry({
            token: address(twoDecimals),
            fee: 3000,
            minLiquidity: DEFAULT_MIN_LIQUIDITY,
            referenceSupply: 1_000_000e2,
            excluded: new address[](0)
        });
        list[1] = ConfigureWhitelist.Entry({
            token: MainnetAddresses.USDC, fee: 500, minLiquidity: 1, referenceSupply: 0, excluded: new address[](0)
        }); // a mint currency, never a component
        list[2] = ConfigureWhitelist.Entry({
            token: address(router), fee: 3000, minLiquidity: 1, referenceSupply: 0, excluded: new address[](0)
        }); // a contract without decimals()

        configure.propose(factory, list, none);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(factory.listingEta(list[i].token), 0);
        }
        assertEq(configure.safeCalldata(factory, list, none).length, 0);
    }

    function test_XA42_statusReportsListingsAndPendingProposals() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        configure.status(factory, list); // nothing listed or pending
        configure.propose(factory, list, none);
        configure.status(factory, list); // listings pending, as the entries say
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[1].token));

        IIndexFactory.TokenConfig memory other = _configFor(list[1]);
        other.referenceSupply = 1;
        vm.prank(DEFAULT_SENDER);
        factory.proposeConfig(list[1].token, other);
        configure.status(factory, list); // listed as the entry says, with a different config change pending
        assertFalse(factory.pendingIsListing(list[1].token));
    }

    function test_configureRun_readsEnvironment() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        vm.setEnv("FACTORY", vm.toString(address(factory)));
        vm.setEnv("WHITELIST", string.concat(vm.toString(list[0].token), ":3000:", vm.toString(DEFAULT_MIN_LIQUIDITY)));

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
        address[] memory tokens = testMarket.create(uniswap);
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
            assertEq(pool.observationCardinalityNext(), testMarket.OBSERVATION_CARDINALITY());
        }
    }

    function test_seedTestMarket() public {
        SetupTestMarket.Uniswap memory uniswap = _uniswap();
        address[] memory tokens = testMarket.create(uniswap);
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
        address[] memory tokens = testMarket.create(uniswap);
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
        address[] memory tokens = testMarket.create(uniswap);

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
        address[] memory tokens = testMarket.create(uniswap);
        SetupTestMarket.Spec[] memory list = testMarket.specs();

        ConfigureWhitelist.Entry[] memory entries = configure.resolveList(testMarket.whitelist(uniswap, tokens));
        assertEq(entries.length, 5);
        assertEq(entries[0].token, tokens[1]);
        assertEq(entries[0].fee, list[1].fee);
        assertEq(entries[0].minLiquidity, 1e17, "a tenth of the pool's liquidity");
        assertEq(entries[0].referenceSupply, list[1].referenceSupply);
        assertEq(entries[1].token, uniswap.weth);
        assertEq(entries[1].fee, 0);
        assertEq(entries[1].minLiquidity, 0);
        assertEq(entries[1].referenceSupply, testMarket.ETH_SUPPLY());
        for (uint256 i = 2; i < 5; ++i) {
            assertEq(entries[i].token, tokens[i]);
            assertEq(entries[i].fee, list[i].fee);
            assertEq(entries[i].minLiquidity, 1e17);
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
        address[] memory tokens = testMarket.run();
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
        assertEq(testMarket.run(), tokens);
        assertEq(MockPositionManager(testMarket.SEPOLIA_POSITION_MANAGER()).mints(), 5);
        assertEq(DEFAULT_SENDER.balance, 0.6 ether, "0.2 + 4 * 0.05 ether wrapped");

        vm.setEnv("MARKET_MODE", "upside-down");
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.UnknownMode.selector, "upside-down"));
        testMarket.run();
    }
}
