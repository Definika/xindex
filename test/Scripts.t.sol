// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {ConfigureWhitelist} from "../script/ConfigureWhitelist.s.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexHub} from "../src/IndexHub.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {MintRequests} from "../src/MintRequests.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {SetupTestMarket} from "../script/testnet/SetupTestMarket.s.sol";
import {FaucetToken} from "../script/testnet/FaucetToken.sol";
import {INonfungiblePositionManager} from "../script/interfaces/INonfungiblePositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./mocks/MockUniswapV3.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

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

    address[] internal _owners;

    function addOwner(address signer) external {
        _owners.push(signer);
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
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
        return 3;
    }

    function getModulesPaginated(address, uint256) external pure returns (address[] memory, address) {
        bytes memory data = abi.encode(new address[](0), address(1));
        assembly ("memory-safe") {
            revert(add(data, 32), mload(data))
        }
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

    Deploy deployer;
    ConfigureWhitelist configure;
    SetupTestMarket testMarket;
    MockUniversalRouter router;
    address usdc;
    address usdt;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");

    /// @dev No token named for listing or relisting.
    address[] none;

    function setUp() public {
        deployer = new Deploy();
        configure = new ConfigureWhitelist();
        testMarket = new SetupTestMarket();
        router = new MockUniversalRouter(makeAddr("poolManager"));
        usdc = address(new MockERC20("USD Coin", "USDC", 6));
        usdt = address(new MockUSDT());
    }

    function _factory(address owner_, address guardian_) internal returns (IndexFactory) {
        return new IndexFactory(owner_, guardian_);
    }

    /// @dev Two tokens with reference supplies: A with 18 decimals, B with 8.
    function _twoEntries() internal returns (ConfigureWhitelist.Entry[] memory list) {
        list = new ConfigureWhitelist.Entry[](2);
        list[0] = ConfigureWhitelist.Entry({token: address(new MockERC20("A", "A", 18)), referenceSupply: 1_000e18});
        list[1] = ConfigureWhitelist.Entry({token: address(new MockERC20("B", "B", 8)), referenceSupply: 21_000_000e8});
    }

    /// @dev Every token `list` names, as a LIST that lets each of them be proposed for a listing (RT-06).
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

    function _safeCalls(
        IndexFactory factory,
        ConfigureWhitelist.Entry[] memory list,
        address[] memory firstListings,
        address[] memory relist
    ) internal view returns (bytes[] memory calls) {
        (calls,) = configure.safeCalldata(factory, list, firstListings, relist);
    }

    /// @dev "List" when a one-entry run named in LIST would propose `entry`, "Skip" otherwise.
    function _actionFor(IndexFactory factory, ConfigureWhitelist.Entry memory entry, address[] memory relist)
        internal
        view
        returns (string memory)
    {
        ConfigureWhitelist.Entry[] memory one = new ConfigureWhitelist.Entry[](1);
        one[0] = entry;
        return _safeCalls(factory, one, _tokens(one), relist).length == 1 ? "List" : "Skip";
    }

    /// @dev A real ERC-20 put at `at` with `decimals`, and the entry that lists it with a million whole tokens.
    function _tokenAt(address at, uint8 decimals) internal returns (ConfigureWhitelist.Entry memory) {
        vm.etch(at, address(new MockERC20("T", "T", decimals)).code);
        MockERC20(at).setDecimals(decimals); // `vm.etch` copies code, not the storage the decimals live in
        return ConfigureWhitelist.Entry({token: at, referenceSupply: 1_000_000 * 10 ** uint256(decimals)});
    }

    /// @dev Lists `list` on a key-owned factory through the script, propose then execute.
    function _listed(IndexFactory factory, ConfigureWhitelist.Entry[] memory list) internal {
        configure.propose(factory, list, _tokens(list), none);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
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

        MockSafe twoOfN = new MockSafe(2);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerThresholdTooLow.selector, address(twoOfN), 2));
        deployer.checkOwner(address(twoOfN)); // two signatures no longer suffice (the owner's call on 2026-09-30)
        assertEq(deployer.MIN_OWNER_THRESHOLD(), 3);
        deployer.checkOwner(address(new MockSafe(3))); // a real multisig, as the design's 3-of-5
        deployer.checkOwner(address(router)); // a contract without getThreshold, such as a timelock
        deployer.checkOwner(address(new SilentFallback())); // an empty answer is not a threshold
    }

    function test_XA07_checkOwnerRejectsASafeWithModules() public {
        vm.chainId(1);
        MockSafe withModule = new MockSafe(3);
        address module = makeAddr("module");
        withModule.enableModule(module);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerHasModules.selector, address(withModule), module));
        deployer.checkOwner(address(withModule));

        address unknown = address(new ThresholdOnly(3));
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerModulesUnknown.selector, unknown));
        deployer.checkOwner(unknown);
        MockSafe malformed = new MockSafe(3);
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
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Deploy.GuardianIsBroadcaster.selector, guardian));
        deployer.checkGuardian(owner, guardian);
    }

    /// @dev SA-06. The guardian is the owner's veto, so a guardian that also signs for the owner Safe leaves one key
    ///      acting on both sides, and the broadcasting key, which holds no role, must not hold a share of the owner's
    ///      either. An owner that answers no signer list, a key or a timelock, is accepted as before.
    function test_SA06_neitherTheGuardianNorTheBroadcasterSignsForTheOwner() public {
        MockSafe safe = new MockSafe(3);
        safe.addOwner(makeAddr("signer"));
        deployer.checkGuardian(address(safe), guardian);

        safe.addOwner(guardian);
        vm.expectRevert(abi.encodeWithSelector(Deploy.GuardianSignsForOwner.selector, guardian));
        deployer.checkGuardian(address(safe), guardian);
        vm.expectRevert(abi.encodeWithSelector(Deploy.GuardianSignsForOwner.selector, guardian));
        deployer.deploy(address(safe), guardian, address(router), usdc, usdt);

        MockSafe other = new MockSafe(3);
        other.addOwner(address(this)); // the account calling the script, as the broadcasting key does
        vm.expectRevert(abi.encodeWithSelector(Deploy.BroadcasterSignsForOwner.selector, address(this)));
        deployer.checkGuardian(address(other), guardian);

        deployer.checkGuardian(owner, guardian); // a key answers no signer list
        deployer.checkGuardian(address(new SilentFallback()), guardian); // nor does a contract that is not a Safe
    }

    function test_XA39_rolesCannotBeMarketContracts() public {
        deployer.checkRolesAreNotMarket(owner, guardian, address(router));
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, address(router)));
        deployer.checkRolesAreNotMarket(owner, address(router), address(router));
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, address(router)));
        deployer.deploy(address(router), guardian, address(router), usdc, usdt); // the router pasted as OWNER
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, address(router)));
        deployer.deploy(owner, address(router), address(router), usdc, usdt);
    }

    function test_XA47_mainnetMarketCannotBeOverridden() public {
        vm.chainId(1);
        vm.etch(MAINNET_UNIVERSAL_ROUTER, hex"00");
        address other = address(router);
        vm.expectRevert(abi.encodeWithSelector(Deploy.MainnetOverride.selector, "UNIVERSAL_ROUTER", other));
        deployer.resolveRouter(other);
        assertEq(
            deployer.resolveRouter(MAINNET_UNIVERSAL_ROUTER), MAINNET_UNIVERSAL_ROUTER, "the default itself is fine"
        );
    }

    function test_deploy() public {
        (IndexFactory factory, IndexZap zap, MintRequests requests) =
            deployer.deploy(owner, guardian, address(router), usdc, usdt);
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(address(zap.FACTORY()), address(factory));
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(IndexHub(factory.IMPLEMENTATION()).FACTORY(), address(factory));
        assertEq(requests.FACTORY(), address(factory));
        assertEq(requests.USDC(), usdc);
        assertEq(requests.USDT(), usdt);
    }

    function test_deployRun_readsEnvironment() public {
        vm.setEnv("OWNER", vm.toString(owner));
        vm.setEnv("GUARDIAN", vm.toString(guardian));
        vm.setEnv("UNIVERSAL_ROUTER", vm.toString(address(router)));
        vm.setEnv("USDC", vm.toString(usdc));
        vm.setEnv("USDT", vm.toString(usdt));
        (IndexFactory factory, IndexZap zap, MintRequests requests) = deployer.run();
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(requests.USDC(), usdc);
        assertEq(requests.USDT(), usdt);
    }

    /// @dev The stablecoins MintRequests escrows resolve like the router: required off mainnet, mainnet's own on chain
    ///      1 and nothing else there, and never an address without code.
    function test_resolveStable() public {
        assertEq(deployer.resolveStable("USDC", usdc, MainnetAddresses.USDC), usdc);
        vm.expectRevert(abi.encodeWithSelector(Deploy.AddressRequired.selector, "USDT"));
        deployer.resolveStable("USDT", address(0), MainnetAddresses.USDT);
        vm.expectRevert(abi.encodeWithSelector(Deploy.AddressHasNoCode.selector, "USDC", owner));
        deployer.resolveStable("USDC", owner, MainnetAddresses.USDC);

        vm.chainId(1);
        vm.etch(MainnetAddresses.USDT, hex"00");
        assertEq(deployer.resolveStable("USDT", address(0), MainnetAddresses.USDT), MainnetAddresses.USDT);
        vm.expectRevert(abi.encodeWithSelector(Deploy.MainnetOverride.selector, "USDT", usdt));
        deployer.resolveStable("USDT", usdt, MainnetAddresses.USDT);
    }

    /// @dev XA-38: the release record freezes what was deployed, and the check proves a deployment is one build.
    function test_XA38_checkDeploymentFreezesTheCodeHashes() public {
        address safeOwner = address(new MockSafe(3));
        (IndexFactory factory, IndexZap zap, MintRequests requests) =
            deployer.deploy(safeOwner, guardian, address(router), usdc, usdt);

        bytes32[4] memory codehashes = deployer.checkDeployment(factory, zap, requests);
        assertEq(codehashes[0], keccak256(address(factory).code));
        assertEq(codehashes[1], keccak256(factory.IMPLEMENTATION().code));
        assertEq(codehashes[2], keccak256(address(zap).code));
        assertEq(codehashes[3], keccak256(address(requests).code));

        (IndexFactory other, IndexZap otherZap,) = deployer.deploy(safeOwner, guardian, address(router), usdc, usdt);
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.WrongWiring.selector, "IndexZap.FACTORY", address(other), address(factory))
        );
        deployer.checkDeployment(other, zap, requests);
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.WrongWiring.selector, "MintRequests.FACTORY", address(other), address(factory)
            )
        );
        deployer.checkDeployment(other, otherZap, requests);
    }

    /// @dev CR-I36. `deploy` itself runs every owner and guardian gate.
    function test_CRI36_deployItselfRefusesABadOwnerOrGuardian() public {
        vm.expectRevert(Deploy.OwnerRequired.selector);
        deployer.deploy(address(0), guardian, address(router), usdc, usdt);
        vm.expectRevert(Deploy.OwnerRequired.selector);
        deployer.deploy(DEFAULT_SENDER, guardian, address(router), usdc, usdt);
        vm.expectRevert(Deploy.GuardianRequired.selector);
        deployer.deploy(owner, owner, address(router), usdc, usdt);
        vm.expectRevert(Deploy.GuardianRequired.selector);
        deployer.deploy(owner, address(0), address(router), usdc, usdt);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Deploy.GuardianIsBroadcaster.selector, guardian));
        deployer.deploy(owner, guardian, address(router), usdc, usdt);

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerMustBeContract.selector, owner));
        deployer.deploy(owner, guardian, address(0), address(0), address(0));
        MockSafe singleSigner = new MockSafe(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerThresholdTooLow.selector, address(singleSigner), 1));
        deployer.deploy(address(singleSigner), guardian, address(0), address(0), address(0));
    }

    /// @dev CR-I36: a call that failed is not an answer.
    function test_CRI36_aFailedSafeCallIsNeverReadAsAnAnswer() public {
        vm.chainId(1);
        deployer.checkOwner(address(new RevertsOneWord())); // not a Safe, so accepted as a contract owner
        address unreadable = address(new ModuleListReverts());
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerModulesUnknown.selector, unreadable));
        deployer.checkOwner(unreadable);
    }

    /// @dev CR-I36. The module check pages from Safe's sentinel, as 1.3.0 answers.
    function test_CRI36_theModuleCheckPagesFromTheSentinel() public {
        assertEq(deployer.SENTINEL_MODULES(), address(1));
        MockSafe safe = new MockSafe(3);
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

    /// @dev CR-I36: only code starting 0xef01 marks a delegated key.
    function test_CRI36_onlyTheEf01PrefixMarksADelegatedKey() public {
        vm.chainId(1);
        address multisig = makeAddr("push-one multisig");
        vm.etch(multisig, hex"600160005260206000f3"); // PUSH1 1 PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerThresholdTooLow.selector, multisig, 1));
        deployer.checkOwner(multisig);
    }

    /// @dev XA-39 and CR-I37: no market contract can hold a role: the router and its PoolManager anywhere, and on chain
    ///      1 every token and mint currency in the address book.
    function test_XA39_CRI37_noMarketContractCanHoldARole() public {
        address pool = router.poolManager();
        address[] memory market = deployer.marketContracts(address(router));
        assertEq(market.length, 2);
        assertEq(market[0], address(router));
        assertEq(market[1], pool);
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, pool));
        deployer.checkRolesAreNotMarket(pool, guardian, address(router));
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, pool));
        deployer.checkRolesAreNotMarket(owner, pool, address(router));

        vm.chainId(1);
        vm.etch(MAINNET_UNIVERSAL_ROUTER, address(new MockUniversalRouter(MainnetAddresses.POOL_MANAGER)).code);
        address[8] memory expected = [
            MAINNET_UNIVERSAL_ROUTER,
            MainnetAddresses.POOL_MANAGER,
            MainnetAddresses.WETH,
            MainnetAddresses.WBTC,
            MainnetAddresses.UNI,
            MainnetAddresses.LINK,
            MainnetAddresses.USDC,
            MainnetAddresses.USDT
        ];
        market = deployer.marketContracts(MAINNET_UNIVERSAL_ROUTER);
        assertEq(market.length, expected.length);
        for (uint256 i = 0; i < expected.length; ++i) {
            assertEq(market[i], expected[i]);
            vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, expected[i]));
            deployer.checkRolesAreNotMarket(expected[i], guardian, MAINNET_UNIVERSAL_ROUTER);
            vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, expected[i]));
            deployer.checkRolesAreNotMarket(owner, expected[i], MAINNET_UNIVERSAL_ROUTER);
        }

        // Through `deploy` itself: WETH pasted as OWNER, a contract that answers no getThreshold.
        vm.etch(MainnetAddresses.WETH, address(new SilentFallback()).code);
        vm.etch(MainnetAddresses.USDC, hex"00");
        vm.etch(MainnetAddresses.USDT, hex"00");
        vm.expectRevert(abi.encodeWithSelector(Deploy.RoleIsMarketContract.selector, MainnetAddresses.WETH));
        deployer.deploy(MainnetAddresses.WETH, guardian, address(0), address(0), address(0));
    }

    // ---------------------------------------------------------------------
    // ConfigureWhitelist: entries and the default list
    // ---------------------------------------------------------------------

    function test_parseEntry() public {
        string memory token = vm.toString(address(router));
        ConfigureWhitelist.Entry memory e = configure.parseEntry(string.concat(token, ":120000000000000000000000000"));
        assertEq(e.token, address(router));
        assertEq(e.referenceSupply, 120_000_000e18);

        // CR-L03: the reference supply is not optional, and v3's feed fields are gone, so their shape is malformed.
        string memory noSupply = string.concat(token, ":");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, noSupply));
        configure.parseEntry(noSupply);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, token));
        configure.parseEntry(token);
        string memory v3Shape = string.concat(token, ":", vm.toString(owner), ":5400:7");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.MalformedEntry.selector, v3Shape));
        configure.parseEntry(v3Shape);
    }

    function test_resolveList() public {
        string memory raw = string.concat(vm.toString(address(router)), ":3, ", vm.toString(owner), ":5");
        ConfigureWhitelist.Entry[] memory list = configure.resolveList(raw);
        assertEq(list.length, 2);
        assertEq(list[0].token, address(router));
        assertEq(list[0].referenceSupply, 3);
        assertEq(list[1].token, owner);
        assertEq(list[1].referenceSupply, 5);

        vm.expectRevert(ConfigureWhitelist.DefaultListOnlyOnMainnet.selector);
        configure.resolveList("default");
        vm.chainId(1);
        list = configure.resolveList("default");
        assertEq(list.length, 4);
    }

    /// @dev CR-M01: every default entry carries a reference supply, since nothing reads a supply live.
    function test_CRM01_everyDefaultEntryCarriesAReferenceSupply() public view {
        ConfigureWhitelist.Entry[] memory l = configure.defaultMainnetList();
        for (uint256 i = 0; i < l.length; ++i) {
            assertGt(l[i].referenceSupply, 0);
        }
    }

    /// @dev CR-L08, re-targeted: the default list is the release record, pinned here against a table written out
    ///      independently of the list: the Stage A tokens and the supply each carries.
    function test_CRL08_theDefaultListIsTheReleaseRecord() public view {
        ConfigureWhitelist.Entry[] memory l = configure.defaultMainnetList();
        assertEq(l.length, 4);
        _assertEntry(l[0], 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, 122_070_499e18);
        _assertEntry(l[1], 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, 20_087_871e8);
        _assertEntry(l[2], 0x514910771AF9Ca656af840dff83E8264EcF986CA, 748_099_970e18);
        _assertEntry(l[3], 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, 620_716_422e18);
    }

    function _assertEntry(ConfigureWhitelist.Entry memory e, address token, uint256 referenceSupply) internal pure {
        assertEq(e.token, token, "token");
        assertEq(e.referenceSupply, referenceSupply, "reference supply");
    }

    /// @dev XA-24 and CR-I22: every default supply is a whole number of tokens between a million and a trillion, with
    ///      each token's decimals written out independently.
    function test_XA24_CRI22_everyDefaultSupplyIsAPlausibleCountOfWholeTokens() public view {
        ConfigureWhitelist.Entry[] memory l = configure.defaultMainnetList();
        uint8[4] memory decimals = [18, 8, 18, 18]; // WETH, WBTC, LINK, UNI
        for (uint256 i = 0; i < l.length; ++i) {
            uint256 one = 10 ** uint256(decimals[i]);
            assertEq(l[i].referenceSupply % one, 0, "rounded down to whole tokens, in raw units");
            assertGe(l[i].referenceSupply / one, 1e6, "at least a million tokens");
            assertLe(l[i].referenceSupply / one, 1e12, "at most a trillion");
        }
    }

    function test_parseAddresses() public view {
        assertEq(configure.parseAddresses("").length, 0);
        address[] memory parsed =
            configure.parseAddresses(string.concat(vm.toString(owner), " , ", vm.toString(guardian)));
        assertEq(parsed.length, 2);
        assertEq(parsed[0], owner);
        assertEq(parsed[1], guardian);
    }

    // ---------------------------------------------------------------------
    // ConfigureWhitelist: listings
    // ---------------------------------------------------------------------

    function test_XA18_proposeRefusesAContractOwner() public {
        MockSafe safe = new MockSafe(3);
        IndexFactory factory = _factory(address(safe), address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();

        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.OwnerIsContract.selector, address(safe)));
        configure.propose(factory, list, _tokens(list), none);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.OwnerIsContract.selector, address(safe)));
        configure.proposeSupplies(factory, list);

        bytes[] memory calls = _safeCalls(factory, list, _tokens(list), none);
        assertEq(calls.length, 2);
        assertEq(factory.listingEta(list[0].token), 0);
    }

    /// @dev DA-20, re-targeted. A delisted token named in RELIST while the live supply batch names it was still
    ///      proposed, and the factory refuses that listing (TokenInBatch): the run reverted whole, and safe mode handed the
    ///      Safe a batch whose call fails. It is now skipped with the reason logged until the batch is gone, and then
    ///      RELIST proposes it as it always meant to.
    function test_DA20_aRelistIsNotProposedIntoALiveBatch() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        _listed(factory, list);
        list[0].referenceSupply += list[0].referenceSupply / 400; // a quarter of a percent, inside the step
        configure.proposeSupplies(factory, list);
        vm.prank(guardian);
        factory.delist(list[0].token);

        address[] memory relist = new address[](1);
        relist[0] = list[0].token;
        assertEq(_safeCalls(factory, list, none, relist).length, 0, "nothing to propose while the batch names it");
        configure.propose(factory, list, none, relist);
        assertEq(factory.listingEta(list[0].token), 0, "and nothing is proposed");

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.executeSupplies(factory, list);
        bytes[] memory calls = _safeCalls(factory, list, none, relist);
        assertEq(calls.length, 1, "once the batch has executed, the relisting is proposed");
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeListing, (list[0].token, list[0].referenceSupply)));
        configure.propose(factory, list, none, relist);
        assertGt(factory.listingEta(list[0].token), 0);
    }

    /// @dev LR-07: a key that delegated its account under EIP-7702 still signs.
    function test_LR07_proposeAcceptsAnOwnerKeyDelegatedUnderEip7702() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        vm.etch(DEFAULT_SENDER, abi.encodePacked(hex"ef0100", address(this)));

        configure.propose(factory, list, _tokens(list), none);
        assertGt(factory.listingEta(list[0].token), 0, "the delegated key proposed");
        assertGt(factory.listingEta(list[1].token), 0);
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
        assertEq(factory.pendingReferenceSupply(list[1].token), 21_000_000e8);

        vm.warp(block.timestamp + 1 hours);
        configure.propose(factory, list, _tokens(list), none); // already pending: skipped, eta unchanged
        assertEq(factory.listingEta(list[0].token), eta);

        configure.execute(factory, list); // not ready yet: skipped
        assertFalse(factory.isWhitelisted(list[0].token));

        vm.warp(eta);
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token));
        assertTrue(factory.isWhitelisted(list[1].token));
        assertEq(factory.referenceSupply(list[0].token), list[0].referenceSupply);

        configure.propose(factory, list, _tokens(list), none); // listed: its supply changes only in a batch
        assertEq(factory.listingEta(list[0].token), 0);
        configure.execute(factory, list); // nothing pending: skipped
        assertEq(factory.whitelistedTokens().length, 2);
    }

    function test_FR05_executeWorksFromAnyAccountAndNeverReproposesACancelledListing() public {
        IndexFactory factory = _factory(owner, guardian); // the broadcaster is neither owner nor guardian
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        vm.startPrank(owner);
        factory.proposeListing(list[0].token, list[0].referenceSupply);
        factory.proposeListing(list[1].token, list[1].referenceSupply);
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
            assertEq(calls[i], abi.encodeCall(IIndexFactory.proposeListing, (list[i].token, list[i].referenceSupply)));
        }
        _sendAsOwner(factory, calls);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token));
        assertTrue(factory.isWhitelisted(list[1].token));
    }

    /// @dev XA-11: a routine run never relists a token the guardian delisted; RELIST names one, and the relisting stays
    ///      within a step of the supply the token carried.
    function test_XA11_proposeSkipsADelistedTokenUnlessNamedForRelisting() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        _listed(factory, list);
        vm.prank(guardian);
        factory.delist(list[0].token);

        configure.propose(factory, list, none, none); // a routine run with the same list must not undo the guardian
        assertEq(factory.listingEta(list[0].token), 0);
        assertEq(_safeCalls(factory, list, none, none).length, 0);

        address[] memory relist = new address[](2);
        (relist[0], relist[1]) = (list[1].token, list[0].token); // naming a listed token too changes nothing for it
        // A relisting takes the supply the token carries, whatever the entry says; a batch revises it (SA-02).
        list[0].referenceSupply = 1_010e18;
        bytes[] memory calls = _safeCalls(factory, list, none, relist);
        assertEq(calls.length, 1);
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeListing, (list[0].token, 1_000e18)));
        assertEq(configure.listingSupply(factory, list[0]), 1_000e18);
        configure.propose(factory, list, none, relist);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token));
        assertEq(factory.referenceSupply(list[0].token), 1_000e18, "relisted at the supply in force");
    }

    /// @dev RT-06. A first listing the guardian cancelled leaves nothing on chain, so it is proposed again only when
    ///      LIST names it, and a routine run leaves LIST unset.
    function test_RT06_aVetoedFirstListingIsNotProposedAgainByARoutineRun() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        _sendAsOwner(factory, _safeCalls(factory, list, _tokens(list), none));
        vm.prank(guardian);
        factory.cancelListing(list[1].token);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0].token));
        assertFalse(factory.isWhitelisted(list[1].token), "the veto holds at launch");

        vm.warp(block.timestamp + 30 days);
        assertEq(_safeCalls(factory, list, none, none).length, 0, "a routine run proposes no listing");
        address[] memory named = new address[](1);
        named[0] = list[1].token;
        assertEq(_safeCalls(factory, list, none, named).length, 0, "RELIST is not LIST");
    }

    /// @dev RT-06: a listing only for a token LIST names; `all` names every entry of the run and no other token.
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

        vm.prank(guardian);
        factory.cancelListing(list[1].token);
        configure.propose(factory, list, none, none);
        assertEq(factory.listingEta(list[1].token), 0, "a vetoed first listing stays vetoed");
        configure.propose(factory, list, second, none);
        assertGt(factory.listingEta(list[1].token), 0, "until the operator names it again");

        assertEq(configure.resolveFirstListings("all", list), _tokens(list));
        assertEq(configure.resolveFirstListings("", list).length, 0);
        address[] memory parsed =
            configure.resolveFirstListings(string.concat(vm.toString(list[0].token), ", ", vm.toString(owner)), list);
        assertEq(parsed.length, 2);
        assertEq(parsed[0], list[0].token);
        assertEq(parsed[1], owner, "an address outside the list is kept, and names nothing the run proposes");
    }

    /// @dev RT-06: every call of safe mode comes with the line printed above it: the call, the token's symbol and its
    ///      address.
    function test_RT06_safeModeLabelsEveryProposal() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        (bytes[] memory calls, string[] memory labels) = configure.safeCalldata(factory, list, _tokens(list), none);
        assertEq(calls.length, 2);
        assertEq(labels.length, 2, "one label per call");
        assertEq(labels[0], string.concat("proposeListing A ", vm.toString(list[0].token)));
        assertEq(labels[1], string.concat("proposeListing B ", vm.toString(list[1].token)));
    }

    /// @dev XA-06: execute runs only a pending listing that is exactly the entry.
    function test_XA06_executeSkipsAPendingSupplyThatDiffersFromTheEntry() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        vm.prank(owner);
        factory.proposeListing(list[1].token, 1); // not what the WHITELIST entry says
        vm.warp(block.timestamp + factory.LISTING_DELAY());

        configure.execute(factory, list);
        assertFalse(factory.isWhitelisted(list[1].token), "a supply the entry did not ask for is not executed");
        assertGt(factory.listingEta(list[1].token), 0);
        assertEq(_safeCalls(factory, list, _tokens(list), none).length, 1, "the other entry's calldata is produced");
    }

    /// @dev XA-40: entries outside the whitelist policy are skipped with their reason, never proposed.
    function test_XA40_proposeSkipsTokensOutsideTheWhitelistPolicy() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](5);
        list[0] = ConfigureWhitelist.Entry({token: address(new MockERC20("Two", "TWO", 2)), referenceSupply: 1e8});
        list[1] = ConfigureWhitelist.Entry({token: MainnetAddresses.USDC, referenceSupply: 1e8}); // a mint currency
        list[2] = ConfigureWhitelist.Entry({token: address(router), referenceSupply: 1e8}); // no decimals()
        list[3] = ConfigureWhitelist.Entry({token: address(new MockERC20("Z", "Z", 18)), referenceSupply: 0});
        list[4] = ConfigureWhitelist.Entry({
            token: address(new MockERC20("M", "M", 18)), referenceSupply: uint256(type(uint128).max) + 1
        });

        configure.propose(factory, list, _tokens(list), none);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(factory.listingEta(list[i].token), 0);
        }
        assertEq(_safeCalls(factory, list, _tokens(list), none).length, 0);
    }

    /// @dev A token without code is skipped with its reason: the factory refuses one.
    function test_propose_skipsATokenWithoutCode() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry memory e = ConfigureWhitelist.Entry({token: makeAddr("nothing"), referenceSupply: 1});
        assertEq(_actionFor(factory, e, none), "Skip");
    }

    /// @dev CR-I36: USDC and USDT are never components, even with a real token at their addresses.
    function test_CRI36_mintCurrenciesAreRefusedByThePolicyItself() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        assertEq(_actionFor(factory, _tokenAt(makeAddr("six decimals"), 6), none), "List", "control: listable");
        assertEq(_actionFor(factory, _tokenAt(MainnetAddresses.USDC, 6), none), "Skip", "USDC is never a component");
        assertEq(_actionFor(factory, _tokenAt(MainnetAddresses.USDT, 6), none), "Skip", "nor is USDT");
    }

    /// @dev CR-I36: the policy is 6 to 18 decimals inclusive.
    function test_CRI36_sixDecimalsIsInsideThePolicyAndFiveIsNot() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        assertEq(_actionFor(factory, _tokenAt(makeAddr("six"), 6), none), "List", "six decimals is the floor");
        assertEq(_actionFor(factory, _tokenAt(makeAddr("five"), 5), none), "Skip", "five is below it");
        assertEq(_actionFor(factory, _tokenAt(makeAddr("eighteen"), 18), none), "List", "eighteen the ceiling");
        assertEq(_actionFor(factory, _tokenAt(makeAddr("nineteen"), 19), none), "Skip", "nineteen above it");
    }

    /// @dev CR-I36: a proposal is live through the last second of its window: the script neither proposes it again
    ///      nor fails to execute it.
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

    /// @dev CR-I36: RELIST names only the tokens it names.
    function test_CRI36_relistNamesOnlyTheTokensItNames() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory two = new ConfigureWhitelist.Entry[](2);
        two[0] = _tokenAt(makeAddr("named"), 18);
        two[1] = _tokenAt(makeAddr("not named"), 18);
        _listed(factory, two);
        vm.startPrank(guardian);
        factory.delist(two[0].token);
        factory.delist(two[1].token);
        vm.stopPrank();

        address[] memory relist = new address[](1);
        relist[0] = two[0].token;
        bytes[] memory calls = _safeCalls(factory, two, _tokens(two), relist);
        assertEq(calls.length, 1, "only the named token is proposed");
        assertEq(calls[0], abi.encodeCall(IIndexFactory.proposeListing, (two[0].token, two[0].referenceSupply)));
    }

    /// @dev RT-24: a list naming a token twice is refused, whatever mode would run on it.
    function test_RT24_aListNamingATokenTwiceIsRefused() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory two = _twoEntries();
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](3);
        (list[0], list[1]) = (two[0], two[1]);
        list[2] = ConfigureWhitelist.Entry({token: two[0].token, referenceSupply: 1_100e18}); // an edited copy
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.DuplicateEntry.selector, two[0].token));
        configure.safeCalldata(factory, list, _tokens(list), none);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.DuplicateEntry.selector, two[0].token));
        configure.supplyBatch(factory, list);

        IndexFactory keyOwned = _factory(DEFAULT_SENDER, guardian);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.DuplicateEntry.selector, two[0].token));
        configure.propose(keyOwned, list, _tokens(list), none);
        assertEq(keyOwned.listingEta(two[1].token), 0, "nothing is proposed");

        string memory entry = string.concat(vm.toString(address(router)), ":");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.DuplicateEntry.selector, address(router)));
        configure.resolveList(string.concat(entry, "3, ", entry, "5"));

        bytes[] memory calls = _safeCalls(factory, two, _tokens(two), none);
        assertEq(calls.length, 2);
        _sendAsOwner(factory, calls);
    }

    /// @dev The line of a one-entry run's only proposal.
    function _labelOf(IndexFactory factory, address token) internal view returns (string memory) {
        ConfigureWhitelist.Entry[] memory one = new ConfigureWhitelist.Entry[](1);
        one[0] = ConfigureWhitelist.Entry({token: token, referenceSupply: 1_000e18});
        (bytes[] memory calls, string[] memory labels) = configure.safeCalldata(factory, one, _tokens(one), none);
        assertEq(calls.length, 1, "the entry is proposed whatever its symbol");
        return labels[0];
    }

    /// @dev RT-25. A symbol answered in another shape is "?", never a revert of the whole run.
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

    /// @dev RT-25: a decimals answer that is not a uint8 is no answer, and the entry is skipped, not fatal.
    function test_RT25_aDecimalsAnswerInAnotherShapeIsSkippedNotFatal() public {
        IndexFactory factory = _factory(owner, guardian);
        bytes[3] memory answers = [abi.encode(uint256(256 + 18)), bytes(hex"12"), abi.encode(uint256(18))];
        string[3] memory actions = ["Skip", "Skip", "List"];
        for (uint256 i = 0; i < answers.length; ++i) {
            address token = address(new RawAnswersToken(abi.encode("RAW"), answers[i]));
            assertEq(
                _actionFor(factory, ConfigureWhitelist.Entry({token: token, referenceSupply: 1e30}), none), actions[i]
            );
        }
    }

    /// @dev LR-05: `status` returns the report its log lines are written from.
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
            assertEq(reports[i].eta, block.timestamp + factory.LISTING_DELAY(), "a listing is pending");
            assertTrue(reports[i].pendingMatches, "as the entry says");
        }

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        list[1].referenceSupply += 1;
        configure.proposeSupplies(factory, list);
        list[1].referenceSupply -= 1; // the entries now say the supply in force, and the batch says otherwise
        reports = configure.status(factory, list);
        assertTrue(reports[0].listed);
        assertTrue(reports[0].inForce, "the first entry is in force");
        assertFalse(reports[0].inBatch, "and not in the batch");
        assertTrue(reports[1].inForce, "so is the second");
        assertTrue(reports[1].inBatch, "with a batch pending for it");

        // A pending listing whose supply differs from its entry, and a batch that has expired.
        MockERC20 later = new MockERC20("L", "L", 18);
        vm.prank(DEFAULT_SENDER);
        factory.proposeListing(address(later), 7);
        ConfigureWhitelist.Entry[] memory one = new ConfigureWhitelist.Entry[](1);
        one[0] = ConfigureWhitelist.Entry({token: address(later), referenceSupply: 8});
        reports = configure.status(factory, one);
        assertFalse(reports[0].pendingMatches, "a pending listing that differs from the entry");
        vm.warp(block.timestamp + 10 days);
        reports = configure.status(factory, list);
        assertFalse(reports[1].inBatch, "an expired batch names nothing");
    }

    // ---------------------------------------------------------------------
    // ConfigureWhitelist: supply batches
    // ---------------------------------------------------------------------

    /// @dev The weekly batch: sorted by address, only entries whose supply moved, skipping a token never listed and one
    ///      with a listing pending.
    function test_supplyBatch_sortsAndChoosesTheRevisions() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](4);
        for (uint256 i = 0; i < 4; ++i) {
            list[i] = _tokenAt(address(uint160(0x9000 - i * 0x100)), 18); // descending addresses
        }
        ConfigureWhitelist.Entry[] memory listed = new ConfigureWhitelist.Entry[](3);
        (listed[0], listed[1], listed[2]) = (list[0], list[1], list[2]);
        _listed(factory, listed);
        vm.prank(guardian);
        factory.delist(list[2].token);
        vm.prank(DEFAULT_SENDER);
        factory.proposeListing(list[2].token, list[2].referenceSupply); // a relisting is pending for the third

        list[0].referenceSupply += 1_000e18; // revised
        list[2].referenceSupply += 1_000e18; // revised, but a listing is pending: skipped
        list[3].referenceSupply += 1_000e18; // never listed: skipped
        // list[1] unchanged: not in the batch
        (address[] memory tokens, uint256[] memory supplies) = configure.supplyBatch(factory, list);
        assertEq(tokens.length, 1);
        assertEq(tokens[0], list[0].token);
        assertEq(supplies[0], list[0].referenceSupply);

        list[1].referenceSupply -= 1_000e18;
        (tokens,) = configure.supplyBatch(factory, list);
        assertEq(tokens.length, 2);
        assertLt(uint256(uint160(tokens[0])), uint256(uint160(tokens[1])), "ascending, as the factory requires");
    }

    /// @dev CR-I38 and RT-25, re-targeted: the script mirrors the factory's step, so a revision of exactly one step is
    ///      batched and one raw unit past it is skipped with its reason, rather than refusing the whole Safe batch.
    function test_CRI38_RT25_aRevisionOfExactlyOneStepIsBatchedAndOnePastIsSkipped() public {
        IndexFactory factory = _factory(owner, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        _sendAsOwner(factory, _safeCalls(factory, list, _tokens(list), none));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        uint256 stepA = list[0].referenceSupply / 200;
        uint256 stepB = list[1].referenceSupply / 200;

        list[0].referenceSupply += stepA + 1; // one past
        list[1].referenceSupply -= stepB; // exactly one step down
        (address[] memory tokens,) = configure.supplyBatch(factory, list);
        assertEq(tokens.length, 1, "the entry past the step is skipped");
        assertEq(tokens[0], list[1].token);

        list[0].referenceSupply -= 1; // exactly one step up
        bytes memory call = configure.supplyCalldata(factory, list);
        vm.prank(owner);
        (bool ok,) = address(factory).call(call);
        assertTrue(ok, "the factory takes both");
        (, uint256 eta, address[] memory pending,) = factory.pendingSupplies();
        assertEq(pending.length, 2);
        vm.warp(eta);
        configure.executeSupplies(factory, list);
        assertEq(factory.referenceSupply(list[0].token), list[0].referenceSupply);
        assertEq(factory.referenceSupply(list[1].token), list[1].referenceSupply);
    }

    /// @dev SA-05. With last week's batch still live, the batch modes built this week's against the supplies it was
    ///      about to replace and handed the Safe a `proposeSupplies` the factory refuses. They now stop with the live
    ///      batch's deadline, and build again once it has executed.
    function test_SA05_theBatchModesRefuseWhileABatchIsLive() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        _listed(factory, list);
        list[0].referenceSupply += list[0].referenceSupply / 400;
        configure.proposeSupplies(factory, list);
        (, uint256 eta,,) = factory.pendingSupplies();
        uint256 deadline = eta + factory.PROPOSAL_WINDOW();

        list[1].referenceSupply += list[1].referenceSupply / 400;
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.BatchStillLive.selector, deadline));
        configure.supplyBatch(factory, list);
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.BatchStillLive.selector, deadline));
        configure.supplyCalldata(factory, list);

        vm.warp(eta);
        configure.executeSupplies(factory, list);
        (address[] memory tokens,) = configure.supplyBatch(factory, list);
        assertEq(tokens.length, 1, "next week's batch names only what still moves");
        assertEq(tokens[0], list[1].token);
    }

    function test_supplyBatch_revertsWhenNothingMoves() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        vm.expectRevert(ConfigureWhitelist.NothingToBatch.selector);
        configure.supplyBatch(factory, list); // never listed
        _listed(factory, list);
        vm.expectRevert(ConfigureWhitelist.NothingToBatch.selector);
        configure.supplyBatch(factory, list); // listed at exactly these supplies
    }

    /// @dev Propose broadcasts the batch from an owner key; execute runs a due batch only when every one of its
    ///      supplies is what the entries say, and says why otherwise.
    function test_proposeAndExecuteSupplies() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, guardian);
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        configure.executeSupplies(factory, list); // nothing pending: logs and returns
        _listed(factory, list);

        list[0].referenceSupply += 1e18;
        configure.proposeSupplies(factory, list);
        (, uint256 eta,,) = factory.pendingSupplies();
        configure.executeSupplies(factory, list); // not ready yet
        vm.warp(eta);
        list[0].referenceSupply += 1e18; // the entries moved on since the proposal
        configure.executeSupplies(factory, list);
        assertEq(factory.referenceSupply(list[0].token), 1_000e18, "a batch the entries no longer name waits");
        list[0].referenceSupply -= 1e18;
        ConfigureWhitelist.Entry[] memory other = new ConfigureWhitelist.Entry[](1);
        other[0] = list[1];
        configure.executeSupplies(factory, other); // entries that do not name the batch's token
        assertEq(factory.referenceSupply(list[0].token), 1_000e18);
        configure.executeSupplies(factory, list);
        assertEq(factory.referenceSupply(list[0].token), 1_001e18, "executed");

        list[0].referenceSupply += 1e18;
        configure.proposeSupplies(factory, list);
        (, eta,,) = factory.pendingSupplies();
        vm.warp(eta + factory.PROPOSAL_WINDOW() + 1);
        configure.executeSupplies(factory, list); // expired
        assertEq(factory.referenceSupply(list[0].token), 1_001e18);
    }

    function test_configureRun_readsEnvironment() public {
        IndexFactory factory = _factory(DEFAULT_SENDER, address(0));
        ConfigureWhitelist.Entry[] memory list = _twoEntries();
        vm.setEnv("FACTORY", vm.toString(address(factory)));
        vm.setEnv("WHITELIST", string.concat(vm.toString(list[0].token), ":", vm.toString(list[0].referenceSupply)));

        vm.setEnv("RELIST", vm.toString(list[0].token)); // parsed by run; nothing here is delisted
        vm.setEnv("LIST", vm.toString(list[1].token)); // names no entry of this WHITELIST (RT-06)
        vm.setEnv("LISTING_MODE", "safe");
        configure.run();
        vm.setEnv("LISTING_MODE", "propose");
        configure.run();
        assertEq(factory.listingEta(list[0].token), 0, "a listing LIST does not name is not proposed");

        vm.setEnv("LIST", "all");
        vm.setEnv("LISTING_MODE", "safe");
        configure.run();
        assertEq(factory.listingEta(list[0].token), 0);
        vm.setEnv("LISTING_MODE", "propose");
        configure.run();
        assertEq(factory.listingEta(list[0].token), block.timestamp + factory.LISTING_DELAY());

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.setEnv("LISTING_MODE", "execute");
        configure.run();
        assertTrue(factory.isWhitelisted(list[0].token));

        vm.setEnv("WHITELIST", string.concat(vm.toString(list[0].token), ":", vm.toString(list[0].referenceSupply + 1)));
        vm.setEnv("LISTING_MODE", "supplies-safe"); // logs the batch's calldata, broadcasts nothing
        configure.run();
        assertFalse(factory.suppliesPending());
        vm.setEnv("LISTING_MODE", "supplies");
        configure.run();
        assertTrue(factory.suppliesPending());
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.setEnv("LISTING_MODE", "execute-supplies");
        configure.run();
        assertEq(factory.referenceSupply(list[0].token), list[0].referenceSupply + 1);

        vm.setEnv("LISTING_MODE", "status"); // read-only
        configure.run();

        vm.setEnv("LISTING_MODE", "sideways");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.UnknownMode.selector, "sideways"));
        configure.run();

        vm.setEnv("WHITELIST", "default");
        vm.expectRevert(ConfigureWhitelist.DefaultListOnlyOnMainnet.selector);
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
        assertEq(list.length, 4);
        assertEq(list[0].symbol, "tUSDC");
        assertEq(list[0].decimals, 6);
        assertEq(list[0].fee, 500);
        assertEq(list[0].referenceSupply, 0, "a currency, never listed");
        assertEq(list[1].symbol, "tWBTC");
        assertEq(list[2].symbol, "tLINK");
        assertEq(list[3].symbol, "tUNI");
        for (uint256 i = 1; i < list.length; ++i) {
            assertGt(list[i].referenceSupply, 0, "components list with a reference supply");
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
        (lower, upper) = testMarket.rangeAround(-32, 3000);
        assertEq(lower, -7020);
        assertEq(upper, 6900);
        (lower, upper) = testMarket.rangeAround(6932, 500);
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
        assertEq(DEFAULT_SENDER.balance, 0.4 ether, "0.3 + 3 * 0.1 ether wrapped");
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
        assertEq(MockWETH(uniswap.weth).balanceOf(uniswap.positionManager), 0.6 ether);
    }

    function test_XA26_seedRefusesAPoolWhosePriceMoved() public {
        SetupTestMarket.Uniswap memory uniswap = _uniswap();
        address[] memory tokens = testMarket.create(uniswap);
        SetupTestMarket.Spec[] memory list = testMarket.specs();
        MockUniswapV3Pool pool = _pool(uniswap, tokens[1], list[1].fee);
        uint160 expected = testMarket.sqrtPriceX96(tokens[1], uniswap.weth, list[1].decimals, list[1].wethPerToken);
        uint160 moved = expected + expected / 10;
        pool.setSqrtPriceX96(moved);
        vm.deal(DEFAULT_SENDER, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.PoolPriceMoved.selector, address(pool), moved, expected));
        testMarket.seed(uniswap, tokens, 0.3 ether, 0.1 ether);

        moved = expected - expected / 10;
        pool.setSqrtPriceX96(moved);
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.PoolPriceMoved.selector, address(pool), moved, expected));
        testMarket.seed(uniswap, tokens, 0.3 ether, 0.1 ether);
    }

    function test_seedTestMarket_rejectsTokensThatDoNotMatch() public {
        SetupTestMarket.Uniswap memory uniswap = _uniswap();
        address[] memory tokens = testMarket.create(uniswap);

        address[] memory short = new address[](3);
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.TokenCountMismatch.selector, 4, 3));
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

        ConfigureWhitelist.Entry[] memory entries = configure.resolveList(testMarket.whitelist(uniswap.weth, tokens));
        assertEq(entries.length, 4);
        assertEq(entries[0].token, tokens[1]);
        assertEq(entries[0].referenceSupply, list[1].referenceSupply);
        assertEq(entries[1].token, uniswap.weth);
        assertEq(entries[1].referenceSupply, testMarket.ETH_SUPPLY());
        for (uint256 i = 2; i < 4; ++i) {
            assertEq(entries[i].token, tokens[i]);
            assertEq(entries[i].referenceSupply, list[i].referenceSupply);
        }
    }

    function test_setupTestMarketRun_readsEnvironment() public {
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.NotSepolia.selector, block.chainid));
        testMarket.run();
        assertEq(testMarket.SEPOLIA_CHAIN_ID(), 11_155_111);
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.NotSepolia.selector, 1));
        testMarket.run();

        vm.etch(testMarket.SEPOLIA_UNISWAP_V3_FACTORY(), address(new MockUniswapV3Factory()).code);
        vm.etch(testMarket.SEPOLIA_POSITION_MANAGER(), address(new MockPositionManager()).code);
        vm.etch(testMarket.SEPOLIA_WETH(), address(new MockWETH()).code);
        vm.chainId(testMarket.SEPOLIA_CHAIN_ID());

        vm.setEnv("MARKET_MODE", "create");
        address[] memory tokens = testMarket.run();
        assertEq(tokens.length, 4);

        string memory joined = vm.toString(tokens[0]);
        for (uint256 i = 1; i < tokens.length; ++i) {
            joined = string.concat(joined, ",", vm.toString(tokens[i]));
        }
        vm.setEnv("MARKET_MODE", "seed");
        vm.setEnv("MARKET_TOKENS", joined);
        vm.setEnv("USD_POOL_WETH", "200000000000000000");
        vm.setEnv("TOKEN_POOL_WETH", "50000000000000000");
        vm.deal(DEFAULT_SENDER, 1 ether);
        address[] memory seeded = testMarket.run();
        assertEq(seeded, tokens);
        assertEq(MockPositionManager(testMarket.SEPOLIA_POSITION_MANAGER()).mints(), 4);
        assertEq(DEFAULT_SENDER.balance, 0.65 ether, "0.2 + 3 * 0.05 ether wrapped");

        vm.setEnv("MARKET_MODE", "upside-down");
        vm.expectRevert(abi.encodeWithSelector(SetupTestMarket.UnknownMode.selector, "upside-down"));
        testMarket.run();
    }
}
