// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {SetupTestMarket} from "../../script/testnet/SetupTestMarket.s.sol";
import {FaucetToken} from "../../script/testnet/FaucetToken.sol";
import {INonfungiblePositionManager} from "../../script/interfaces/INonfungiblePositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "../mocks/MockUniswapV3.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @notice Stand-in for a Safe: the deploy script only reads its signature threshold.
contract MockSafe {
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
contract PocRelist is Test {
    address constant MAINNET_SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant MAINNET_UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

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
        list[0] = ConfigureWhitelist.Entry({token: address(tokenA), fee: 3000, referenceSupply: 0, excluded: excluded});
        list[1] = ConfigureWhitelist.Entry({
            token: address(tokenB), fee: 3000, referenceSupply: 21_000_000e8, excluded: new address[](0)
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

    function test_checkOwner() public {
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

    function test_checkGuardian() public {
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

    function test_parseEntry() public {
        string memory token = vm.toString(address(router));
        address burnA = makeAddr("burnA");
        address burnB = makeAddr("burnB");

        ConfigureWhitelist.Entry memory e = configure.parseEntry(string.concat(token, ":3000"));
        assertEq(e.token, address(router));
        assertEq(e.fee, 3000);
        assertEq(e.referenceSupply, 0);
        assertEq(e.excluded.length, 0);

        e = configure.parseEntry(string.concat(token, ":0:120000000000000000000000000"));
        assertEq(e.fee, 0);
        assertEq(e.referenceSupply, 120_000_000e18);

        e = configure.parseEntry(string.concat(token, ":500::", vm.toString(burnA), "|", vm.toString(burnB)));
        assertEq(e.referenceSupply, 0);
        assertEq(e.excluded.length, 2);
        assertEq(e.excluded[0], burnA);
        assertEq(e.excluded[1], burnB);

        e = configure.parseEntry(string.concat(token, ":500:7:"));
        assertEq(e.referenceSupply, 7);
        assertEq(e.excluded.length, 0);

        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, token));
        configure.parseEntry(token);
        string memory tooMany = string.concat(token, ":1:2:3:4");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, tooMany));
        configure.parseEntry(tooMany);
    }

    function test_resolveList() public {
        string memory raw = string.concat(vm.toString(address(router)), ":3000, ", vm.toString(owner), ":0:5");
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
        assertEq(defaults.length, 5);
        for (uint256 i = 0; i < defaults.length; ++i) {
            assertEq(defaults[i].token, expected[i].token);
            assertEq(defaults[i].fee, expected[i].fee);
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
        assertEq(config.referenceSupply, 0);

        ConfigureWhitelist.Entry memory wethEntry = ConfigureWhitelist.Entry({
            token: address(market.weth()), fee: 0, referenceSupply: 1e27, excluded: new address[](0)
        });
        config = _configFor(wethEntry);
        assertEq(config.pool, address(0));
        assertEq(config.referenceSupply, 1e27);
    }

    function test_poc_relistAfterDelist() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        configure.propose(factory, list);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[1].token));
        vm.prank(guardian);
        factory.delist(list[1].token);
        assertFalse(factory.isWhitelisted(list[1].token));
        // identical config refresh run
        bytes[] memory calls = configure.safeCalldata(factory, list);
        emit log_named_uint("safe calls", calls.length);
        configure.propose(factory, list);
        emit log_named_uint("etaB", factory.listingEta(list[1].token));
        assertGt(factory.listingEta(list[1].token), 0);
        assertEq(factory.listingEta(list[0].token), 0);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[1].token));
    }
}
