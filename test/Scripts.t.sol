// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {DeployChecks} from "../script/DeployChecks.sol";
import {DeployWeighted} from "../script/DeployWeighted.s.sol";
import {PythIds} from "../script/PythIds.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {ConfigureWeighted} from "../script/ConfigureWeighted.s.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {BasketBuilder} from "../src/BasketBuilder.sol";
import {MintRequests} from "../src/MintRequests.sol";
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

/// @notice Answers what `DeployWeighted.checkDeployment` asks a factory, so a test can wire one wrong.
contract FakeWeightedFactory {
    address public immutable IMPLEMENTATION;
    address public immutable PYTH;

    constructor(address implementation, address pyth) {
        IMPLEMENTATION = implementation;
        PYTH = pyth;
    }
}

/// @notice DeployWeighted recording this very build, whatever it is, so a test can deploy on chain 1 from any build,
///         `forge coverage`'s unoptimized one included.
contract DeployWeightedThisBuild is DeployWeighted {
    function releaseInitCodeHashes() public pure override returns (bytes32[4] memory) {
        return buildInitCodeHashes();
    }
}

/// @notice DeployWeighted recording a build no compiler produces.
contract DeployWeightedOtherBuild is DeployWeighted {
    function releaseInitCodeHashes() public pure override returns (bytes32[4] memory released) {
        released = [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), bytes32(uint256(4))];
    }
}

/// @notice Runs the deploy and test-market scripts in-process so they are compiled, executed and covered by CI.
/// @dev Environment variables are process-global and tests run in parallel, so each variable name is set by exactly one
///      test. In tests, script broadcasts come from DEFAULT_SENDER.
contract ScriptsTest is Test {
    address constant MAINNET_UNIVERSAL_ROUTER = MainnetAddresses.UNIVERSAL_ROUTER;

    DeployWeighted deployer;
    SetupTestMarket testMarket;
    MockUniversalRouter router;
    address pyth;
    address usdc;
    address usdt;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");

    function setUp() public {
        deployer = new DeployWeighted();
        testMarket = new SetupTestMarket();
        router = new MockUniversalRouter(makeAddr("poolManager"));
        pyth = address(new MockPyth());
        usdc = address(new MockERC20("USD Coin", "USDC", 6));
        usdt = address(new MockUSDT());
    }

    /// @dev A deployment with the test's market, as a testnet's.
    function _deploy(address owner_, address guardian_)
        internal
        returns (WeightedIndexFactory, IndexZap, BasketBuilder, MintRequests)
    {
        return deployer.deploy(owner_, guardian_, pyth, address(router), usdc, usdt);
    }

    // ---------------------------------------------------------------------
    // The role checks
    // ---------------------------------------------------------------------

    function test_L06_checkOwner() public {
        vm.expectRevert(DeployChecks.OwnerRequired.selector);
        deployer.checkOwner(address(0));
        vm.expectRevert(DeployChecks.OwnerRequired.selector);
        deployer.checkOwner(DEFAULT_SENDER);
        deployer.checkOwner(owner); // any account is accepted off mainnet

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerMustBeContract.selector, owner));
        deployer.checkOwner(owner);

        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(router))); // EIP-7702 delegated account
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerMustBeContract.selector, delegated));
        deployer.checkOwner(delegated);

        MockSafe singleSigner = new MockSafe(1);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerThresholdTooLow.selector, address(singleSigner), 1));
        deployer.checkOwner(address(singleSigner));

        MockSafe twoOfN = new MockSafe(2);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerThresholdTooLow.selector, address(twoOfN), 2));
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
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerHasModules.selector, address(withModule), module));
        deployer.checkOwner(address(withModule));

        address unknown = address(new ThresholdOnly(3));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerModulesUnknown.selector, unknown));
        deployer.checkOwner(unknown);
        MockSafe malformed = new MockSafe(3);
        malformed.setMalformedModules(true);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerModulesUnknown.selector, address(malformed)));
        deployer.checkOwner(address(malformed));
    }

    function test_FR06_checkGuardian() public {
        vm.expectRevert(DeployChecks.GuardianRequired.selector);
        deployer.checkGuardian(owner, address(0));
        vm.expectRevert(DeployChecks.GuardianRequired.selector);
        deployer.checkGuardian(owner, DEFAULT_SENDER);
        vm.expectRevert(DeployChecks.GuardianRequired.selector);
        deployer.checkGuardian(owner, owner);
        deployer.checkGuardian(owner, guardian);
    }

    function test_resolveRouter() public {
        assertEq(deployer.resolveRouter(address(router)), address(router));

        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressRequired.selector, "UNIVERSAL_ROUTER"));
        deployer.resolveRouter(address(0));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressHasNoCode.selector, "UNIVERSAL_ROUTER", owner));
        deployer.resolveRouter(owner);

        assertFalse(deployer.isPinnedChain(), "a local chain is not pinned");
        vm.etch(MAINNET_UNIVERSAL_ROUTER, hex"00");
        assertTrue(deployer.isPinnedChain(), "RX-23: Ethereum's state is pinned whatever the script's chain id says");
        vm.chainId(1);
        assertTrue(deployer.isPinnedChain());
        assertEq(deployer.pinnedRouter(), MAINNET_UNIVERSAL_ROUTER);
        assertEq(deployer.pinnedUsdc(), MainnetAddresses.USDC);
        assertEq(deployer.pinnedUsdt(), MainnetAddresses.USDT);
        assertEq(deployer.resolveRouter(address(0)), MAINNET_UNIVERSAL_ROUTER, "the mainnet default on chain 1");
    }

    function test_XA25_guardianCannotBeTheBroadcastingKey() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.GuardianIsBroadcaster.selector, guardian));
        deployer.checkGuardian(owner, guardian);

        // Nor a Safe the broadcasting key signs for, directly or through a signer Safe of its own.
        MockSafe guardianSafe = new MockSafe(1);
        guardianSafe.addOwner(address(this)); // the account calling the script, as the broadcasting key does
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.GuardianIsBroadcaster.selector, address(guardianSafe)));
        deployer.checkGuardian(owner, address(guardianSafe));
        MockSafe keyHolder = new MockSafe(1);
        keyHolder.addOwner(address(this));
        MockSafe outer = new MockSafe(2);
        outer.addOwner(makeAddr("other signer"));
        outer.addOwner(address(keyHolder));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.GuardianIsBroadcaster.selector, address(outer)));
        deployer.checkGuardian(owner, address(outer));
    }

    /// @dev SA-06. The guardian is the owner's veto, so a guardian that also signs for the owner Safe leaves one key
    ///      acting on both sides, and the broadcasting key, which holds no role, must not hold a share of the owner's
    ///      either. An owner that answers no signer list, a key or a timelock, is accepted as before.
    function test_SA06_neitherTheGuardianNorTheBroadcasterSignsForTheOwner() public {
        MockSafe safe = new MockSafe(3);
        safe.addOwner(makeAddr("signer"));
        deployer.checkGuardian(address(safe), guardian);

        safe.addOwner(guardian);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.GuardianSignsForOwner.selector, guardian));
        deployer.checkGuardian(address(safe), guardian);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.GuardianSignsForOwner.selector, guardian));
        _deploy(address(safe), guardian);

        MockSafe other = new MockSafe(3);
        other.addOwner(address(this)); // the account calling the script, as the broadcasting key does
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.BroadcasterSignsForOwner.selector, address(this)));
        deployer.checkGuardian(address(other), guardian);

        deployer.checkGuardian(owner, guardian); // a key answers no signer list
        deployer.checkGuardian(address(new SilentFallback()), guardian); // nor does a contract that is not a Safe
    }

    /// @dev SA-06, one level deep on each side. Comparing addresses alone let a key reach both roles through a Safe: a
    ///      guardian Safe controlled by one of the owner's signers, or a guardian key that signs for a treasury Safe
    ///      among the owner's signers. Each side's signers that are Safes bring in their own.
    function test_SA06_signersAreComparedOneLevelDeep() public {
        address a = makeAddr("signer a");
        address c = makeAddr("treasury signer c");
        MockSafe treasury = new MockSafe(1);
        treasury.addOwner(c);
        MockSafe safe = new MockSafe(3);
        safe.addOwner(a);
        safe.addOwner(makeAddr("signer b"));
        safe.addOwner(address(treasury));

        // A guardian Safe that one of the owner's signers controls.
        MockSafe guardianSafe = new MockSafe(1);
        guardianSafe.addOwner(a);
        vm.expectRevert(
            abi.encodeWithSelector(DeployChecks.GuardianSharesOwnerSigner.selector, address(guardianSafe), a)
        );
        deployer.checkGuardian(address(safe), address(guardianSafe));
        vm.expectRevert(
            abi.encodeWithSelector(DeployChecks.GuardianSharesOwnerSigner.selector, address(guardianSafe), a)
        );
        _deploy(address(safe), address(guardianSafe));

        // A guardian key that signs for the owner through the treasury.
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.GuardianSignsForOwner.selector, c));
        deployer.checkGuardian(address(safe), c);

        // A guardian Safe whose own signer Safe holds the treasury's key.
        MockSafe holder = new MockSafe(1);
        holder.addOwner(c);
        MockSafe outerGuardian = new MockSafe(1);
        outerGuardian.addOwner(address(holder));
        vm.expectRevert(
            abi.encodeWithSelector(DeployChecks.GuardianSharesOwnerSigner.selector, address(outerGuardian), c)
        );
        deployer.checkGuardian(address(safe), address(outerGuardian));

        // The broadcasting key, through a treasury among the owner's signers.
        MockSafe broadcasterTreasury = new MockSafe(1);
        broadcasterTreasury.addOwner(address(this));
        MockSafe other = new MockSafe(3);
        other.addOwner(a);
        other.addOwner(address(broadcasterTreasury));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.BroadcasterSignsForOwner.selector, address(this)));
        deployer.checkGuardian(address(other), guardian);

        // A guardian Safe of keys of its own passes.
        MockSafe separate = new MockSafe(2);
        separate.addOwner(makeAddr("guardian signer d"));
        separate.addOwner(makeAddr("guardian signer e"));
        deployer.checkGuardian(address(safe), address(separate));
    }

    function test_XA39_rolesCannotBeMarketContracts() public {
        deployer.checkRolesAreNotMarket(owner, guardian, address(router));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, address(router)));
        deployer.checkRolesAreNotMarket(owner, address(router), address(router));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, address(router)));
        _deploy(address(router), guardian); // the router pasted as OWNER
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, address(router)));
        _deploy(owner, address(router));
    }

    function test_XA47_mainnetMarketCannotBeOverridden() public {
        vm.chainId(1);
        vm.etch(MAINNET_UNIVERSAL_ROUTER, hex"00");
        address other = address(router);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "UNIVERSAL_ROUTER", other));
        deployer.resolveRouter(other);
        assertEq(
            deployer.resolveRouter(MAINNET_UNIVERSAL_ROUTER), MAINNET_UNIVERSAL_ROUTER, "the default itself is fine"
        );
    }

    // ---------------------------------------------------------------------
    // DeployWeighted
    // ---------------------------------------------------------------------

    function test_deployWeighted_wiresOneDeployment() public {
        address safeOwner = address(new MockSafe(3));
        (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests) =
            _deploy(safeOwner, guardian);
        assertEq(factory.owner(), safeOwner);
        assertEq(factory.guardian(), guardian);
        assertEq(factory.PYTH(), pyth);
        WeightedHub implementation = WeightedHub(factory.IMPLEMENTATION());
        assertEq(implementation.FACTORY(), address(factory));
        assertEq(implementation.PYTH(), pyth);
        assertEq(address(zap.FACTORY()), address(factory));
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(address(builder.FACTORY()), address(factory));
        assertEq(address(builder.ROUTER()), address(router));
        assertEq(requests.FACTORY(), address(factory));
        assertEq(requests.USDC(), usdc);
        assertEq(requests.USDT(), usdt);

        bytes32[5] memory codehashes = deployer.checkDeployment(factory, zap, builder, requests);
        assertEq(codehashes[0], keccak256(address(factory).code));
        assertEq(codehashes[1], keccak256(address(implementation).code));
        assertEq(codehashes[2], keccak256(address(zap).code));
        assertEq(codehashes[3], keccak256(address(builder).code));
        assertEq(codehashes[4], keccak256(address(requests).code));
    }

    /// @dev The owner and guardian pass every role gate, and neither may be the Pyth contract.
    function test_deployWeighted_checksTheRoles() public {
        vm.expectRevert(DeployChecks.OwnerRequired.selector);
        _deploy(address(0), guardian);
        vm.expectRevert(DeployChecks.GuardianRequired.selector);
        _deploy(owner, owner);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, address(router)));
        _deploy(address(router), guardian);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, pyth));
        _deploy(pyth, guardian);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, pyth));
        _deploy(owner, pyth);
    }

    /// @dev Pyth resolves like the router: required off mainnet, mainnet's own on chain 1 and nothing else there, and
    ///      never an address without code.
    function test_deployWeighted_resolvePyth() public {
        assertEq(deployer.resolvePyth(pyth), pyth);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressRequired.selector, "PYTH"));
        deployer.resolvePyth(address(0));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressHasNoCode.selector, "PYTH", owner));
        deployer.resolvePyth(owner);

        vm.chainId(1);
        vm.etch(MainnetAddresses.PYTH, hex"00");
        assertEq(deployer.pinnedPyth(), MainnetAddresses.PYTH);
        assertEq(deployer.resolvePyth(address(0)), MainnetAddresses.PYTH);
        assertEq(deployer.MAINNET_PYTH(), MainnetAddresses.PYTH);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "PYTH", pyth));
        deployer.resolvePyth(pyth);
    }

    function test_deployWeighted_checkDeploymentRefusesAnother() public {
        (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests) =
            _deploy(owner, guardian);
        (WeightedIndexFactory other, IndexZap otherZap, BasketBuilder otherBuilder, MintRequests otherRequests) =
            _deploy(owner, guardian);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector, "IndexZap.FACTORY", address(factory), address(other)
            )
        );
        deployer.checkDeployment(factory, otherZap, builder, requests);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector, "BasketBuilder.FACTORY", address(factory), address(other)
            )
        );
        deployer.checkDeployment(factory, zap, otherBuilder, requests);
        // A builder on this factory but another router.
        BasketBuilder otherRouter = new BasketBuilder(factory, new MockUniversalRouter(makeAddr("poolManager")));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector,
                "BasketBuilder.ROUTER",
                address(router),
                address(otherRouter.ROUTER())
            )
        );
        deployer.checkDeployment(factory, zap, otherRouter, requests);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector, "MintRequests.FACTORY", address(factory), address(other)
            )
        );
        deployer.checkDeployment(factory, zap, builder, otherRequests);

        // A factory claiming another's implementation, or a Pyth its implementation does not read.
        FakeWeightedFactory fake = new FakeWeightedFactory(other.IMPLEMENTATION(), other.PYTH());
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector, "WeightedHub.FACTORY", address(fake), address(other)
            )
        );
        deployer.checkDeployment(WeightedIndexFactory(address(fake)), zap, builder, requests);
        address read = factory.PYTH();
        FakeWeightedFactory repointed = new FakeWeightedFactory(factory.IMPLEMENTATION(), address(0xbeef));
        vm.etch(address(factory), address(repointed).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployChecks.WrongWiring.selector, "WeightedHub.PYTH", address(0xbeef), read)
        );
        deployer.checkDeployment(factory, zap, builder, requests);
    }

    /// @dev The deploy script reads these variables, which only this test sets.
    function test_deployRun_readsEnvironment() public {
        vm.setEnv("OWNER", vm.toString(owner));
        vm.setEnv("GUARDIAN", vm.toString(guardian));
        vm.setEnv("PYTH", vm.toString(pyth));
        vm.setEnv("UNIVERSAL_ROUTER", vm.toString(address(router)));
        vm.setEnv("USDC", vm.toString(usdc));
        vm.setEnv("USDT", vm.toString(usdt));
        (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests) = deployer.run();
        assertEq(address(builder.FACTORY()), address(factory));
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(factory.PYTH(), pyth);
        assertEq(address(zap.FACTORY()), address(factory));
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(requests.FACTORY(), address(factory));
        assertEq(requests.USDC(), usdc);
        assertEq(requests.USDT(), usdt);
    }

    /// @dev The stablecoins MintRequests escrows resolve like the router: required off mainnet, mainnet's own on chain
    ///      1 and nothing else there, and never an address without code.
    function test_resolveStable() public {
        assertEq(deployer.resolveStable("USDC", usdc, MainnetAddresses.USDC), usdc);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressRequired.selector, "USDT"));
        deployer.resolveStable("USDT", address(0), MainnetAddresses.USDT);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressHasNoCode.selector, "USDC", owner));
        deployer.resolveStable("USDC", owner, MainnetAddresses.USDC);

        vm.chainId(1);
        vm.etch(MainnetAddresses.USDT, hex"00");
        assertEq(deployer.resolveStable("USDT", address(0), MainnetAddresses.USDT), MainnetAddresses.USDT);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "USDT", usdt));
        deployer.resolveStable("USDT", usdt, MainnetAddresses.USDT);
    }

    /// @dev XA-38: the release record freezes what was deployed, and the check proves a deployment is one build.
    function test_XA38_checkDeploymentFreezesTheCodeHashes() public {
        address safeOwner = address(new MockSafe(3));
        (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests) =
            _deploy(safeOwner, guardian);

        bytes32[5] memory codehashes = deployer.checkDeployment(factory, zap, builder, requests);
        assertEq(codehashes[0], keccak256(address(factory).code));
        assertEq(codehashes[1], keccak256(factory.IMPLEMENTATION().code));
        assertEq(codehashes[2], keccak256(address(zap).code));
        assertEq(codehashes[3], keccak256(address(builder).code));
        assertEq(codehashes[4], keccak256(address(requests).code));

        (WeightedIndexFactory other, IndexZap otherZap, BasketBuilder otherBuilder,) = _deploy(safeOwner, guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector, "IndexZap.FACTORY", address(other), address(factory)
            )
        );
        deployer.checkDeployment(other, zap, builder, requests);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector, "MintRequests.FACTORY", address(other), address(factory)
            )
        );
        deployer.checkDeployment(other, otherZap, otherBuilder, requests);
    }

    /// @dev With `--account` and no `--sender`, a script's msg.sender is Foundry's default sender while the keystore
    ///      signs, and every check of the broadcasting key would compare the wrong address. On a pinned chain the
    ///      deploy refuses to run that way (RX-37); elsewhere it does not care.
    function test_RX37_aMainnetDeployNeedsItsSender() public {
        vm.chainId(1);
        vm.prank(DEFAULT_SENDER);
        vm.expectRevert(DeployChecks.BroadcasterRequired.selector);
        deployer.deploy(owner, guardian, pyth, address(router), usdc, usdt);
        deployer.checkBroadcaster();
        vm.chainId(31337);
        vm.prank(DEFAULT_SENDER);
        deployer.checkBroadcaster();
    }

    /// @dev CR-I36. `deploy` itself runs every owner and guardian gate.
    function test_CRI36_deployItselfRefusesABadOwnerOrGuardian() public {
        vm.expectRevert(DeployChecks.OwnerRequired.selector);
        _deploy(address(0), guardian);
        vm.expectRevert(DeployChecks.OwnerRequired.selector);
        _deploy(DEFAULT_SENDER, guardian);
        vm.expectRevert(DeployChecks.GuardianRequired.selector);
        _deploy(owner, owner);
        vm.expectRevert(DeployChecks.GuardianRequired.selector);
        _deploy(owner, address(0));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.GuardianIsBroadcaster.selector, guardian));
        _deploy(owner, guardian);

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerMustBeContract.selector, owner));
        deployer.deploy(owner, guardian, address(0), address(0), address(0), address(0));
        MockSafe singleSigner = new MockSafe(1);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerThresholdTooLow.selector, address(singleSigner), 1));
        deployer.deploy(address(singleSigner), guardian, address(0), address(0), address(0), address(0));
    }

    /// @dev CF-5. The constants are the release record: this build's init-code hashes. A change to src/, to a
    ///      dependency or to the compiler settings fails here until they are updated in the same reviewed commit, and
    ///      the failure prints the new values. `forge coverage` compiles without the optimizer, so it skips the pin.
    function test_CF5_theReleaseHashesAreThisBuilds() public view {
        bytes32[4] memory pinned = deployer.releaseInitCodeHashes();
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;
        bytes32[4] memory built = deployer.buildInitCodeHashes();
        assertEq(pinned[0], built[0], "FACTORY_INITCODE_HASH: set it to this build's WeightedIndexFactory hash");
        assertEq(pinned[1], built[1], "ZAP_INITCODE_HASH: set it to this build's IndexZap hash");
        assertEq(pinned[2], built[2], "BUILDER_INITCODE_HASH: set it to this build's BasketBuilder hash");
        assertEq(pinned[3], built[3], "REQUESTS_INITCODE_HASH: set it to this build's MintRequests hash");
        deployer.checkBuild(pinned);
    }

    /// @dev CF-5. On Ethereum, `deploy` broadcasts only the build its constants record; elsewhere it builds as before.
    function test_CF5_aMainnetDeployBroadcastsOnlyTheRecordedBuild() public {
        vm.chainId(1);
        vm.etch(MAINNET_UNIVERSAL_ROUTER, address(new MockUniversalRouter(MainnetAddresses.POOL_MANAGER)).code);
        vm.etch(MainnetAddresses.PYTH, hex"00");
        vm.etch(MainnetAddresses.USDC, hex"00");
        vm.etch(MainnetAddresses.USDT, hex"00");
        address safe = address(new MockSafe(3));

        DeployWeighted other = new DeployWeightedOtherBuild();
        bytes32[4] memory built = other.buildInitCodeHashes();
        assertEq(other.releaseInitCodeHashes()[0], bytes32(uint256(1)), "a record no build matches");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployWeighted.BuildNotReleased.selector, "WeightedIndexFactory", bytes32(uint256(1)), built[0]
            )
        );
        other.deploy(safe, guardian, address(0), address(0), address(0), address(0));

        bytes32[4] memory wrongZap = [built[0], bytes32(0), built[2], built[3]];
        vm.expectRevert(
            abi.encodeWithSelector(DeployWeighted.BuildNotReleased.selector, "IndexZap", bytes32(0), built[1])
        );
        other.checkBuild(wrongZap);
        bytes32[4] memory wrongBuilder = [built[0], built[1], bytes32(0), built[3]];
        vm.expectRevert(
            abi.encodeWithSelector(DeployWeighted.BuildNotReleased.selector, "BasketBuilder", bytes32(0), built[2])
        );
        other.checkBuild(wrongBuilder);
        bytes32[4] memory wrongRequests = [built[0], built[1], built[2], bytes32(0)];
        vm.expectRevert(
            abi.encodeWithSelector(DeployWeighted.BuildNotReleased.selector, "MintRequests", bytes32(0), built[3])
        );
        other.checkBuild(wrongRequests);

        DeployWeighted same = new DeployWeightedThisBuild();
        assertEq(same.releaseInitCodeHashes()[1], built[1], "a record of this build");
        (WeightedIndexFactory factory,,,) = same.deploy(safe, guardian, address(0), address(0), address(0), address(0));
        assertEq(factory.owner(), safe, "the recorded build broadcasts on chain 1");
    }

    /// @dev CR-I36: a call that failed is not an answer.
    function test_CRI36_aFailedSafeCallIsNeverReadAsAnAnswer() public {
        vm.chainId(1);
        deployer.checkOwner(address(new RevertsOneWord())); // not a Safe, so accepted as a contract owner
        address unreadable = address(new ModuleListReverts());
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerModulesUnknown.selector, unreadable));
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
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerHasModules.selector, address(safe), module));
        deployer.checkOwner(address(safe));
    }

    /// @dev CR-I36: only code starting 0xef01 marks a delegated key.
    function test_CRI36_onlyTheEf01PrefixMarksADelegatedKey() public {
        vm.chainId(1);
        address multisig = makeAddr("push-one multisig");
        vm.etch(multisig, hex"600160005260206000f3"); // PUSH1 1 PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerThresholdTooLow.selector, multisig, 1));
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
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, pool));
        deployer.checkRolesAreNotMarket(pool, guardian, address(router));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, pool));
        deployer.checkRolesAreNotMarket(owner, pool, address(router));

        // On Ethereum, every token of the address book, all of the PythIds table and not the `default` four alone, as an
        // earlier version had it, which let AAVE or any other listed token through as OWNER, then the mint currencies.
        vm.chainId(1);
        vm.etch(MAINNET_UNIVERSAL_ROUTER, address(new MockUniversalRouter(MainnetAddresses.POOL_MANAGER)).code);
        (address[] memory tokens,) = PythIds.all();
        address[] memory expected = new address[](tokens.length + 4);
        (expected[0], expected[1]) = (MAINNET_UNIVERSAL_ROUTER, MainnetAddresses.POOL_MANAGER);
        for (uint256 i = 0; i < tokens.length; ++i) {
            expected[i + 2] = tokens[i];
        }
        (expected[tokens.length + 2], expected[tokens.length + 3]) = (MainnetAddresses.USDC, MainnetAddresses.USDT);
        assertEq(expected.length, PythIds.COUNT + 4);
        market = deployer.marketContracts(MAINNET_UNIVERSAL_ROUTER);
        assertEq(market.length, expected.length);
        for (uint256 i = 0; i < expected.length; ++i) {
            assertEq(market[i], expected[i]);
            vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, expected[i]));
            deployer.checkRolesAreNotMarket(expected[i], guardian, MAINNET_UNIVERSAL_ROUTER);
            vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, expected[i]));
            deployer.checkRolesAreNotMarket(owner, expected[i], MAINNET_UNIVERSAL_ROUTER);
        }

        // Through `deploy` itself: WETH pasted as OWNER, a contract that answers no getThreshold.
        vm.etch(MainnetAddresses.WETH, address(new SilentFallback()).code);
        vm.etch(MainnetAddresses.PYTH, hex"00");
        vm.etch(MainnetAddresses.USDC, hex"00");
        vm.etch(MainnetAddresses.USDT, hex"00");
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, MainnetAddresses.WETH));
        deployer.deploy(MainnetAddresses.WETH, guardian, address(0), address(0), address(0), address(0));
    }

    // ---------------------------------------------------------------------
    // The listing script's labels
    // ---------------------------------------------------------------------

    /// @dev RT-25. A symbol answered in another shape is "?", never a revert of the whole run: safe mode labels every
    ///      proposal with `ScriptUtils.symbolOf`, which reads the answer's offset and length before trusting them.
    function test_RT25_aSymbolInAnotherShapeIsAQuestionMarkNotARevert() public {
        ConfigureWeighted configure = new ConfigureWeighted();
        WeightedIndexFactory factory = new WeightedIndexFactory(owner, guardian, pyth);
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
            assertEq(
                _labelOf(configure, factory, token),
                string.concat("proposeListing ", symbols[i], " ", vm.toString(token), " price id ", vm.toString(_ID))
            );
        }
        address genuine = address(new RawAnswersToken(abi.encode("RAW"), eighteen));
        assertEq(
            _labelOf(configure, factory, genuine),
            string.concat("proposeListing RAW ", vm.toString(genuine), " price id ", vm.toString(_ID))
        );
    }

    bytes32 constant _ID = bytes32(uint256(0xa11ce));

    /// @dev Safe mode's one label for a first listing of `token` under `_ID`.
    function _labelOf(ConfigureWeighted configure, WeightedIndexFactory factory, address token)
        internal
        view
        returns (string memory)
    {
        ConfigureWeighted.Entry[] memory list = new ConfigureWeighted.Entry[](1);
        list[0] = ConfigureWeighted.Entry({token: token, priceId: _ID});
        address[] memory first = new address[](1);
        first[0] = token;
        (bytes[] memory calls, string[] memory labels) =
            configure.safeCalldata(IWeightedIndexFactory(address(factory)), list, first, new address[](0));
        assertEq(calls.length, 1, "the token is proposed");
        return labels[0];
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
        assertEq(list[0].priceId, bytes32(0), "a currency, never listed");
        assertEq(list[1].symbol, "tWBTC");
        assertEq(list[2].symbol, "tLINK");
        assertEq(list[3].symbol, "tUNI");
        for (uint256 i = 1; i < list.length; ++i) {
            assertTrue(list[i].priceId != bytes32(0), "components list with a price id");
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

    function test_testMarketWhitelist_parsesAsConfigureWeightedEntries() public {
        SetupTestMarket.Uniswap memory uniswap = _uniswap();
        address[] memory tokens = testMarket.create(uniswap);
        SetupTestMarket.Spec[] memory list = testMarket.specs();

        ConfigureWeighted.Entry[] memory entries =
            new ConfigureWeighted().resolveList(testMarket.whitelist(uniswap.weth, tokens));
        assertEq(entries.length, 4);
        assertEq(entries[0].token, tokens[1]);
        assertEq(entries[0].priceId, list[1].priceId);
        assertEq(entries[1].token, uniswap.weth);
        assertEq(entries[1].priceId, PythIds.WETH);
        for (uint256 i = 2; i < 4; ++i) {
            assertEq(entries[i].token, tokens[i]);
            assertEq(entries[i].priceId, list[i].priceId);
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
