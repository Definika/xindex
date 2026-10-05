// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployChecks} from "../script/DeployChecks.sol";
import {DeployWeighted} from "../script/DeployWeighted.s.sol";
import {PythIds} from "../script/PythIds.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {ConfigureWhitelist} from "../script/ConfigureWhitelist.s.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {HybridIndexFactory} from "../src/HybridIndexFactory.sol";
import {HybridHub} from "../src/HybridHub.sol";
import {HybridHubModule} from "../src/hybrid/HybridHubModule.sol";
import {HybridHubExtension} from "../src/hybrid/HybridHubExtension.sol";
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
import {DeployVault} from "../script/DeployVault.s.sol";
import {ConfigureChains} from "../script/ConfigureChains.s.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {DeployStateVerifier} from "../script/DeployStateVerifier.s.sol";
import {BnbStateVerifier} from "../src/verifiers/BnbStateVerifier.sol";
import {TronStateVerifier} from "../src/verifiers/TronStateVerifier.sol";
import {NearStateVerifier} from "../src/verifiers/NearStateVerifier.sol";
import {StellarStateVerifier} from "../src/verifiers/StellarStateVerifier.sol";
import {SuiStateVerifier} from "../src/verifiers/SuiStateVerifier.sol";
import {CometBftStateVerifier} from "../src/verifiers/CometBftStateVerifier.sol";
import {VeChainStateVerifier} from "../src/verifiers/VeChainStateVerifier.sol";
import {AptosStateVerifier} from "../src/verifiers/AptosStateVerifier.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";
import {ITronStateVerifier} from "../src/interfaces/ITronStateVerifier.sol";
import {IHybridIndexFactory} from "../src/interfaces/IHybridIndexFactory.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";
import {MockRiscZeroVerifier} from "./mocks/MockRiscZeroVerifier.sol";

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
/// @notice Answers what `DeployWeighted.checkDeployment` asks a factory, so a test can wire one wrong.
contract FakeWeightedFactory {
    address public immutable IMPLEMENTATION;
    address public immutable PYTH;

    constructor(address implementation, address pyth) {
        IMPLEMENTATION = implementation;
        PYTH = pyth;
    }
}

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

    /// @dev BNB Chain's id and a vault standing for its own, for the hybrid factory's scripts.
    uint256 constant BNB = 56;
    bytes32 constant BNB_VAULT = bytes32(uint256(0xB5C));

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

        vm.chainId(1);
        vm.etch(MAINNET_UNIVERSAL_ROUTER, hex"00");
        assertEq(deployer.resolveRouter(address(0)), MAINNET_UNIVERSAL_ROUTER, "the mainnet default on chain 1");
    }

    function test_XA25_guardianCannotBeTheBroadcastingKey() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.GuardianIsBroadcaster.selector, guardian));
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
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.GuardianSignsForOwner.selector, guardian));
        deployer.checkGuardian(address(safe), guardian);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.GuardianSignsForOwner.selector, guardian));
        deployer.deploy(address(safe), guardian, address(router), usdc, usdt);

        MockSafe other = new MockSafe(3);
        other.addOwner(address(this)); // the account calling the script, as the broadcasting key does
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.BroadcasterSignsForOwner.selector, address(this)));
        deployer.checkGuardian(address(other), guardian);

        deployer.checkGuardian(owner, guardian); // a key answers no signer list
        deployer.checkGuardian(address(new SilentFallback()), guardian); // nor does a contract that is not a Safe
    }

    function test_XA39_rolesCannotBeMarketContracts() public {
        deployer.checkRolesAreNotMarket(owner, guardian, address(router));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, address(router)));
        deployer.checkRolesAreNotMarket(owner, address(router), address(router));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, address(router)));
        deployer.deploy(address(router), guardian, address(router), usdc, usdt); // the router pasted as OWNER
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, address(router)));
        deployer.deploy(owner, address(router), address(router), usdc, usdt);
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

    /// @dev The one factory v4 launches on, with both templates and the template's parts all built for it.
    function test_deploy() public {
        (HybridIndexFactory factory, IndexZap zap, MintRequests requests) =
            deployer.deploy(owner, guardian, address(router), usdc, usdt);
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(address(zap.FACTORY()), address(factory));
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(IndexHub(factory.IMPLEMENTATION()).FACTORY(), address(factory));
        HybridHub template = HybridHub(factory.HYBRID_IMPLEMENTATION());
        HybridHubModule module = HybridHubModule(template.MODULE());
        assertEq(template.FACTORY(), address(factory));
        assertEq(module.FACTORY(), address(factory));
        assertEq(HybridHubExtension(module.EXTENSION()).FACTORY(), address(factory));
        assertEq(requests.FACTORY(), address(factory));
        assertEq(requests.USDC(), usdc);
        assertEq(requests.USDT(), usdt);
    }

    /// @dev The template is built for the factory's predicted address, so a broadcaster that has sent transactions
    ///      before deploys as well as a fresh one, and twice in a row.
    function test_deploy_predictsTheFactoryFromTheBroadcastersNonce() public {
        vm.setNonce(DEFAULT_SENDER, 41);
        (HybridIndexFactory first,,) = deployer.deploy(owner, guardian, address(router), usdc, usdt);
        assertEq(address(first), vm.computeCreateAddress(DEFAULT_SENDER, 44));
        (HybridIndexFactory second,,) = deployer.deploy(owner, guardian, address(router), usdc, usdt);
        assertEq(address(second), vm.computeCreateAddress(DEFAULT_SENDER, 50));
        assertEq(HybridHub(second.HYBRID_IMPLEMENTATION()).FACTORY(), address(second));
    }

    /// @dev Both deploy scripts read the same variables, which only this test sets; v5's also reads PYTH.
    function test_deployRun_readsEnvironment() public {
        vm.setEnv("OWNER", vm.toString(owner));
        vm.setEnv("GUARDIAN", vm.toString(guardian));
        vm.setEnv("UNIVERSAL_ROUTER", vm.toString(address(router)));
        vm.setEnv("USDC", vm.toString(usdc));
        vm.setEnv("USDT", vm.toString(usdt));
        (HybridIndexFactory factory, IndexZap zap, MintRequests requests) = deployer.run();
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(requests.USDC(), usdc);
        assertEq(requests.USDT(), usdt);

        address pyth = address(new MockPyth());
        vm.setEnv("PYTH", vm.toString(pyth));
        (WeightedIndexFactory weighted, IndexZap weightedZap, MintRequests weightedRequests) =
            new DeployWeighted().run();
        assertEq(weighted.owner(), owner);
        assertEq(weighted.guardian(), guardian);
        assertEq(weighted.PYTH(), pyth);
        assertEq(address(weightedZap.FACTORY()), address(weighted));
        assertEq(weightedRequests.FACTORY(), address(weighted));
    }

    // ---------------------------------------------------------------------
    // DeployWeighted (v5)
    // ---------------------------------------------------------------------

    function test_deployWeighted_wiresOneDeployment() public {
        DeployWeighted weightedDeployer = new DeployWeighted();
        address pyth = address(new MockPyth());
        address safeOwner = address(new MockSafe(3));
        (WeightedIndexFactory factory, IndexZap zap, MintRequests requests) =
            weightedDeployer.deploy(safeOwner, guardian, pyth, address(router), usdc, usdt);
        assertEq(factory.owner(), safeOwner);
        assertEq(factory.guardian(), guardian);
        assertEq(factory.PYTH(), pyth);
        WeightedHub implementation = WeightedHub(factory.IMPLEMENTATION());
        assertEq(implementation.FACTORY(), address(factory));
        assertEq(implementation.PYTH(), pyth);
        assertEq(address(zap.FACTORY()), address(factory));
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(requests.FACTORY(), address(factory));
        assertEq(requests.USDC(), usdc);
        assertEq(requests.USDT(), usdt);

        bytes32[4] memory codehashes = weightedDeployer.checkDeployment(factory, zap, requests);
        assertEq(codehashes[0], keccak256(address(factory).code));
        assertEq(codehashes[1], keccak256(address(implementation).code));
        assertEq(codehashes[2], keccak256(address(zap).code));
        assertEq(codehashes[3], keccak256(address(requests).code));
    }

    /// @dev The owner and guardian are checked as `Deploy` checks them, and neither may be the Pyth contract.
    function test_deployWeighted_checksTheRoles() public {
        DeployWeighted weightedDeployer = new DeployWeighted();
        address pyth = address(new MockPyth());
        vm.expectRevert(DeployChecks.OwnerRequired.selector);
        weightedDeployer.deploy(address(0), guardian, pyth, address(router), usdc, usdt);
        vm.expectRevert(DeployChecks.GuardianRequired.selector);
        weightedDeployer.deploy(owner, owner, pyth, address(router), usdc, usdt);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, address(router)));
        weightedDeployer.deploy(address(router), guardian, pyth, address(router), usdc, usdt);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, pyth));
        weightedDeployer.deploy(pyth, guardian, pyth, address(router), usdc, usdt);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, pyth));
        weightedDeployer.deploy(owner, pyth, pyth, address(router), usdc, usdt);
    }

    /// @dev Pyth resolves like the router: required off mainnet, mainnet's own on chain 1 and nothing else there, and
    ///      never an address without code.
    function test_deployWeighted_resolvePyth() public {
        DeployWeighted weightedDeployer = new DeployWeighted();
        address pyth = address(new MockPyth());
        assertEq(weightedDeployer.resolvePyth(pyth), pyth);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressRequired.selector, "PYTH"));
        weightedDeployer.resolvePyth(address(0));
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressHasNoCode.selector, "PYTH", owner));
        weightedDeployer.resolvePyth(owner);

        vm.chainId(1);
        vm.etch(MainnetAddresses.PYTH, hex"00");
        assertEq(weightedDeployer.resolvePyth(address(0)), MainnetAddresses.PYTH);
        assertEq(weightedDeployer.MAINNET_PYTH(), MainnetAddresses.PYTH);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "PYTH", pyth));
        weightedDeployer.resolvePyth(pyth);
    }

    /// @dev The price-id table covers the flagship's four and the wide list, GRAM aside until its feed is chosen, in
    ///      that order, with a distinct non-zero id each: two coins on one id could never share an index (V5-M1). The
    ///      ids are pinned against a few written out independently, from Pyth's catalogue on 2026-10-05.
    function test_pythIds_coverTheListBarGram() public view {
        (address[] memory tokens, bytes32[] memory ids) = PythIds.all();
        ConfigureWhitelist.Entry[] memory flagship = configure.defaultMainnetList();
        ConfigureWhitelist.Entry[] memory wide = configure.wideMainnetList();
        assertEq(tokens.length, flagship.length + wide.length - 1);
        uint256 k = 0;
        for (uint256 i = 0; i < flagship.length; ++i) {
            assertEq(tokens[k++], flagship[i].token);
        }
        for (uint256 i = 0; i < wide.length; ++i) {
            if (wide[i].token == MainnetAddresses.GRAM) continue;
            assertEq(tokens[k++], wide[i].token);
        }
        for (uint256 i = 0; i < ids.length; ++i) {
            assertTrue(ids[i] != bytes32(0));
            for (uint256 j = 0; j < i; ++j) {
                assertTrue(ids[i] != ids[j], "one id per coin");
            }
        }
        assertEq(ids[0], 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, "WETH on ETH/USD");
        assertEq(ids[1], 0xc9d8b075a5c69303365ae23633d4e085199bf5c520a3b90fed1322a0342ffc33, "WBTC on WBTC/USD");
        assertEq(ids[2], 0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221, "LINK on LINK/USD");
    }

    function test_deployWeighted_checkDeploymentRefusesAnother() public {
        DeployWeighted weightedDeployer = new DeployWeighted();
        (WeightedIndexFactory factory, IndexZap zap, MintRequests requests) =
            weightedDeployer.deploy(owner, guardian, address(new MockPyth()), address(router), usdc, usdt);
        (WeightedIndexFactory other, IndexZap otherZap, MintRequests otherRequests) =
            weightedDeployer.deploy(owner, guardian, address(new MockPyth()), address(router), usdc, usdt);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector, "IndexZap.FACTORY", address(factory), address(other)
            )
        );
        weightedDeployer.checkDeployment(factory, otherZap, requests);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector, "MintRequests.FACTORY", address(factory), address(other)
            )
        );
        weightedDeployer.checkDeployment(factory, zap, otherRequests);

        // A factory claiming another's implementation, or a Pyth its implementation does not read.
        FakeWeightedFactory fake = new FakeWeightedFactory(other.IMPLEMENTATION(), other.PYTH());
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector, "WeightedHub.FACTORY", address(fake), address(other)
            )
        );
        weightedDeployer.checkDeployment(WeightedIndexFactory(address(fake)), zap, requests);
        address read = factory.PYTH();
        FakeWeightedFactory repointed = new FakeWeightedFactory(factory.IMPLEMENTATION(), address(0xbeef));
        vm.etch(address(factory), address(repointed).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployChecks.WrongWiring.selector, "WeightedHub.PYTH", address(0xbeef), read)
        );
        weightedDeployer.checkDeployment(factory, zap, requests);
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
        (HybridIndexFactory factory, IndexZap zap, MintRequests requests) =
            deployer.deploy(safeOwner, guardian, address(router), usdc, usdt);

        bytes32[7] memory codehashes = deployer.checkDeployment(factory, zap, requests);
        HybridHubModule module = HybridHubModule(HybridHub(factory.HYBRID_IMPLEMENTATION()).MODULE());
        assertEq(codehashes[0], keccak256(address(factory).code));
        assertEq(codehashes[1], keccak256(factory.IMPLEMENTATION().code));
        assertEq(codehashes[2], keccak256(factory.HYBRID_IMPLEMENTATION().code));
        assertEq(codehashes[3], keccak256(address(module).code));
        assertEq(codehashes[4], keccak256(module.EXTENSION().code));
        assertEq(codehashes[5], keccak256(address(zap).code));
        assertEq(codehashes[6], keccak256(address(requests).code));

        (HybridIndexFactory other, IndexZap otherZap,) =
            deployer.deploy(safeOwner, guardian, address(router), usdc, usdt);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector, "IndexZap.FACTORY", address(other), address(factory)
            )
        );
        deployer.checkDeployment(other, zap, requests);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.WrongWiring.selector, "MintRequests.FACTORY", address(other), address(factory)
            )
        );
        deployer.checkDeployment(other, otherZap, requests);
    }

    /// @dev CR-I36. `deploy` itself runs every owner and guardian gate.
    function test_CRI36_deployItselfRefusesABadOwnerOrGuardian() public {
        vm.expectRevert(DeployChecks.OwnerRequired.selector);
        deployer.deploy(address(0), guardian, address(router), usdc, usdt);
        vm.expectRevert(DeployChecks.OwnerRequired.selector);
        deployer.deploy(DEFAULT_SENDER, guardian, address(router), usdc, usdt);
        vm.expectRevert(DeployChecks.GuardianRequired.selector);
        deployer.deploy(owner, owner, address(router), usdc, usdt);
        vm.expectRevert(DeployChecks.GuardianRequired.selector);
        deployer.deploy(owner, address(0), address(router), usdc, usdt);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.GuardianIsBroadcaster.selector, guardian));
        deployer.deploy(owner, guardian, address(router), usdc, usdt);

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerMustBeContract.selector, owner));
        deployer.deploy(owner, guardian, address(0), address(0), address(0));
        MockSafe singleSigner = new MockSafe(1);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.OwnerThresholdTooLow.selector, address(singleSigner), 1));
        deployer.deploy(address(singleSigner), guardian, address(0), address(0), address(0));
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
            vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, expected[i]));
            deployer.checkRolesAreNotMarket(expected[i], guardian, MAINNET_UNIVERSAL_ROUTER);
            vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, expected[i]));
            deployer.checkRolesAreNotMarket(owner, expected[i], MAINNET_UNIVERSAL_ROUTER);
        }

        // Through `deploy` itself: WETH pasted as OWNER, a contract that answers no getThreshold.
        vm.etch(MainnetAddresses.WETH, address(new SilentFallback()).code);
        vm.etch(MainnetAddresses.USDC, hex"00");
        vm.etch(MainnetAddresses.USDT, hex"00");
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.RoleIsMarketContract.selector, MainnetAddresses.WETH));
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
        vm.expectRevert(ConfigureWhitelist.WideListOnlyOnMainnet.selector);
        configure.resolveList("wide");
        vm.chainId(1);
        list = configure.resolveList("default");
        assertEq(list.length, 4);
        list = configure.resolveList("wide");
        assertEq(list.length, 27);
    }

    /// @dev The wide list is a release record too, pinned against a table written out independently of it: each
    ///      token, its reference supply, its decimals and its trust tier. Its tokens never repeat the default list's.
    function test_theWideListIsItsReleaseRecord() public view {
        ConfigureWhitelist.Entry[] memory l = configure.wideMainnetList();
        address[27] memory tokens = [
            0x4a220E6096B25EADb88358cb44068A3248254675, // QNT
            0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9, // AAVE
            0x75231F58b43240C9718Dd58B4967c5114342a86c, // OKB
            0x57e114B691Db790C35207b2e685D4A43181e6061, // ENA
            0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3, // ONDO
            0x56072C95FAA701256059aa122697B133aDEd9279, // SKY
            0x163f8C2467924be0ae7B5347228CABF260318753, // WLD
            0x3c3a81e81dc49A522A592e7622A7E711c06bf354, // MNT
            0x58D97B57BB95320F9a05dC918Aef65434969c2B2, // MORPHO
            0x54D2252757e1672EEaD234D27B1270728fF90581, // BGB
            0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6, // POL
            0xE66747a101bFF2dBA3697199DCcE5b743b454759, // GT
            0x232CE3bd40fCd6f80f3d55A522d03f25Df784Ee2, // LIT
            0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB, // ETHFI
            0xaea46A60368A7bD060eec7DF8CBa43b7EF41Ad85, // FET
            0xD533a949740bb3306d119CC777fa900bA034cd52, // CRV
            0xB62132e35a6c13ee1EE0f84dC5d40bad8d815206, // NEXO
            0x44ff8620b8cA30902395A7bD3F2407e1A091BF73, // VIRTUAL
            0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766, // STRK
            0x808507121B80c02388fAd14726482e061B8da827, // PENDLE
            0x582d872A1B094FC48F5DE31D3B73F2D9bE47def1, // TONCOIN (GRAM)
            0xA0b73E1Ff0B80914AB6fe0444E65848C4C34450b, // CRO
            0x00f3C42833C3170159af4E92dbb451Fb3F708917, // ICP
            0xB50721BCf8d664c30412Cfbc6cf7a15145234ad1, // ARB
            0x6De037ef9aD2725EB40118Bb1702EBb27e4Aeb24, // RNDR (RENDER)
            0x152649eA73beAb28c5b49B26eb48f7EAD6d4c898, // Cake
            0x6985884C4392D348587B19cb9eAAf157F13271cd // ZRO
        ];
        // Whole tokens, from CoinGecko's circulating supplies on 2026-10-05.
        uint256[27] memory wholeTokens = [
            uint256(14_544_176),
            15_435_383,
            21_000_000,
            10_362_500_000,
            4_869_330_647,
            23_430_551_390,
            3_798_073_016,
            3_302_003_382,
            700_036_111,
            699_992_029,
            10_626_317_704,
            104_663_958,
            250_000_000,
            965_350_000,
            2_311_508_384,
            1_571_278_819,
            1_000_000_000,
            658_385_841,
            7_421_949_505,
            173_634_059,
            2_819_616_021,
            49_533_969_069,
            557_202_382,
            6_785_574_605,
            518_776_241,
            376_261_104,
            353_313_325
        ];
        assertEq(l.length, tokens.length);
        ConfigureWhitelist.Entry[] memory flagship = configure.defaultMainnetList();
        for (uint256 i = 0; i < l.length; ++i) {
            // Read on chain: TONCOIN has 9 decimals, CRO and ICP 8, every other token 18.
            uint256 decimals = i == 20 ? 9 : (i == 21 || i == 22) ? 8 : 18;
            _assertEntry(l[i], tokens[i], wholeTokens[i] * 10 ** decimals);
            ConfigureWhitelist.Tier tier = i < 20 ? ConfigureWhitelist.Tier.Native : ConfigureWhitelist.Tier.Bridged;
            assertEq(uint8(configure.tierOf(tokens[i])), uint8(tier), "tier");
            for (uint256 j = 0; j < flagship.length; ++j) {
                assertTrue(flagship[j].token != tokens[i], "no token on both lists");
            }
            for (uint256 j = 0; j < i; ++j) {
                assertTrue(tokens[j] != tokens[i], "no token twice");
            }
        }
    }

    /// @dev The tiers of the flagship's list, and a token on neither list.
    function test_tierOf() public view {
        assertEq(uint8(configure.tierOf(MainnetAddresses.WETH)), uint8(ConfigureWhitelist.Tier.Native));
        assertEq(uint8(configure.tierOf(MainnetAddresses.WBTC)), uint8(ConfigureWhitelist.Tier.Custodial));
        assertEq(uint8(configure.tierOf(MainnetAddresses.LINK)), uint8(ConfigureWhitelist.Tier.Native));
        assertEq(uint8(configure.tierOf(MainnetAddresses.UNI)), uint8(ConfigureWhitelist.Tier.Native));
        assertEq(uint8(configure.tierOf(MainnetAddresses.USDC)), uint8(ConfigureWhitelist.Tier.Unrecorded));
        assertEq(configure.tierName(ConfigureWhitelist.Tier.Native), "Native");
        assertEq(configure.tierName(ConfigureWhitelist.Tier.Bridged), "Bridged");
        assertEq(configure.tierName(ConfigureWhitelist.Tier.Custodial), "Custodial");
        assertEq(configure.tierName(ConfigureWhitelist.Tier.Unrecorded), "Unrecorded");
    }

    /// @dev Every wide supply is a whole number of tokens between a million and a trillion, as the default list's are.
    function test_everyWideSupplyIsAPlausibleCountOfWholeTokens() public view {
        ConfigureWhitelist.Entry[] memory l = configure.wideMainnetList();
        for (uint256 i = 0; i < l.length; ++i) {
            uint256 one = 10 ** (i == 20 ? 9 : (i == 21 || i == 22) ? 8 : 18);
            assertEq(l[i].referenceSupply % one, 0, "rounded down to whole tokens, in raw units");
            assertGe(l[i].referenceSupply / one, 1e6, "at least a million tokens");
            assertLe(l[i].referenceSupply / one, 1e12, "at most a trillion");
        }
    }

    /// @dev Safe mode's label names a listed token's tier, so the signers see it beside the call.
    function test_safeModeLabelsCarryTheTier() public {
        IndexFactory factory = _factory(owner, guardian);
        address[3] memory tokens = [MainnetAddresses.AAVE, MainnetAddresses.GRAM, MainnetAddresses.WBTC];
        string[3] memory tiers = [" (Native)", " (Bridged)", " (Custodial)"];
        for (uint256 i = 0; i < tokens.length; ++i) {
            _tokenAt(tokens[i], 18);
            // `vm.etch` copies code, not the storage the symbol lives in, so the symbol reads empty.
            assertEq(_labelOf(factory, tokens[i]), string.concat("proposeListing  ", vm.toString(tokens[i]), tiers[i]));
        }
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

        vm.setEnv("WHITELIST", "wide");
        vm.expectRevert(ConfigureWhitelist.WideListOnlyOnMainnet.selector);
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

    // ---------------------------------------------------------------------
    // DeployVault
    // ---------------------------------------------------------------------

    /// @dev A vault chain's parameters with SP1's and RISC Zero's verifiers stood in for by mocks that name themselves
    ///      as the pinned versions do, and a recovery multisig with code.
    function _vaultParams() internal returns (DeployVault.Params memory p) {
        p = DeployVault.Params({
            sourceChainId: 1,
            factory: makeAddr("hybrid factory on Ethereum"),
            hubImplementation: makeAddr("its HybridHub template"),
            sp1Verifier: address(new MockSP1Verifier()),
            riscZeroVerifier: address(new MockRiscZeroVerifier()),
            p1ProgramKey: keccak256("P1"),
            p2ImageId: keccak256("P2"),
            anchor: keccak256("a finalized checkpoint"),
            anchorEpoch: 479_000,
            freezer: makeAddr("freezer"),
            recoveryProposer: address(new MockSafe(3)),
            nativeCap: 1_000e18,
            nativeFloor: 1e18
        });
    }

    /// @dev The vault, P1, P2 and the state reader, wired to each other and to the parameters, with their code hashes.
    function test_deployVault() public {
        DeployVault vaultDeployer = new DeployVault();
        DeployVault.Params memory p = _vaultParams();
        DeployVault.Deployment memory d = vaultDeployer.deploy(p);
        assertEq(address(d.vault.p1()), address(d.p1));
        assertEq(address(d.vault.p2()), address(d.p2));
        assertEq(d.vault.SOURCE_CHAIN_ID(), 1);
        assertEq(d.vault.FACTORY(), p.factory);
        assertEq(d.vault.HUB_IMPLEMENTATION(), p.hubImplementation);
        assertEq(d.vault.freezer(), p.freezer);
        assertEq(d.vault.RECOVERY_PROPOSER(), p.recoveryProposer);
        assertEq(d.vault.cap(address(0)), p.nativeCap);
        assertEq(d.vault.outflowFloor(address(0)), p.nativeFloor);
        assertEq(address(d.p1.SP1_VERIFIER()), p.sp1Verifier);
        assertEq(d.p1.PROGRAM_KEY(), p.p1ProgramKey);
        assertEq(address(d.p2.RISC_ZERO_VERIFIER()), p.riscZeroVerifier);
        assertEq(d.p2.IMAGE_ID(), p.p2ImageId);
        assertEq(d.p1.anchor(), p.anchor);
        assertEq(d.p2.anchor(), p.anchor);
        assertEq(d.p1.GENESIS_TIME(), vaultDeployer.MAINNET_GENESIS_TIME());
        assertEq(d.p2.GENESIS_TIME(), vaultDeployer.MAINNET_GENESIS_TIME());
        assertEq(d.p1.MAX_LAG(), vaultDeployer.VERIFIER_MAX_LAG());
        bytes32[4] memory codehashes = vaultDeployer.checkDeployment(d, p);
        assertEq(codehashes[0], keccak256(address(d.vault).code));
        assertEq(codehashes[3], keccak256(address(d.stateReader).code));
    }

    function test_deployVaultRun_readsEnvironment() public {
        DeployVault vaultDeployer = new DeployVault();
        DeployVault.Params memory p = _vaultParams();
        vm.setEnv("VAULT_FACTORY", vm.toString(p.factory));
        vm.setEnv("VAULT_HUB_TEMPLATE", vm.toString(p.hubImplementation));
        vm.setEnv("VAULT_SP1_VERIFIER", vm.toString(p.sp1Verifier));
        vm.setEnv("VAULT_RISC_ZERO_VERIFIER", vm.toString(p.riscZeroVerifier));
        vm.setEnv("VAULT_P1_KEY", vm.toString(p.p1ProgramKey));
        vm.setEnv("VAULT_P2_IMAGE_ID", vm.toString(p.p2ImageId));
        vm.setEnv("VAULT_ANCHOR", vm.toString(p.anchor));
        vm.setEnv("VAULT_ANCHOR_EPOCH", vm.toString(uint256(p.anchorEpoch)));
        vm.setEnv("VAULT_FREEZER", vm.toString(p.freezer));
        vm.setEnv("VAULT_RECOVERY", vm.toString(p.recoveryProposer));
        vm.setEnv("VAULT_NATIVE_CAP", vm.toString(p.nativeCap));
        vm.setEnv("VAULT_NATIVE_FLOOR", vm.toString(p.nativeFloor));
        DeployVault.Deployment memory d = vaultDeployer.run();
        assertEq(d.vault.SOURCE_CHAIN_ID(), 1, "the source defaults to Ethereum mainnet");
        assertEq(d.vault.FACTORY(), p.factory);
        assertEq(d.p2.IMAGE_ID(), p.p2ImageId);
    }

    /// @dev LG-4: P1 and P2 date their anchor from the indexes' chain's beacon genesis, mainnet's or Sepolia's and no
    ///      other, and the script refuses an anchor they could never advance from, a day after its epoch began.
    function test_LG4_deployVaultRefusesAnAnchorTheVerifiersCannotAdvance() public {
        DeployVault vaultDeployer = new DeployVault();
        DeployVault.Params memory p = _vaultParams();
        assertEq(vaultDeployer.genesisTime(1), 1_606_824_023);
        assertEq(vaultDeployer.genesisTime(11_155_111), 1_655_733_600);
        vm.expectRevert(abi.encodeWithSelector(DeployVault.UnknownSource.selector, 17_000));
        vaultDeployer.genesisTime(17_000);
        p.sourceChainId = 17_000;
        vm.expectRevert(abi.encodeWithSelector(DeployVault.UnknownSource.selector, 17_000));
        vaultDeployer.check(p);

        p = _vaultParams();
        uint256 lagEnds = 1_606_824_023 + uint256(p.anchorEpoch) * 384 + 1 days;
        vm.warp(lagEnds);
        vaultDeployer.check(p);
        vm.warp(lagEnds + 1);
        vm.expectRevert(abi.encodeWithSelector(DeployVault.AnchorTooOld.selector, p.anchorEpoch, lagEnds));
        vaultDeployer.check(p);
    }

    /// @dev Every parameter the vault depends on is checked before anything is broadcast.
    function test_deployVault_refusals() public {
        DeployVault vaultDeployer = new DeployVault();
        DeployVault.Params memory p = _vaultParams();

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployVault.SourceChain.selector, 1));
        vaultDeployer.check(p);
        vm.chainId(31_337);
        vaultDeployer.checkRoles(p.freezer, p.recoveryProposer); // a freezer key and a multisig, as the vault needs

        string[6] memory names = [
            "VAULT_FACTORY", "VAULT_HUB_TEMPLATE", "VAULT_P1_KEY", "VAULT_P2_IMAGE_ID", "VAULT_ANCHOR", "VAULT_FREEZER"
        ];
        for (uint256 i = 0; i < names.length; ++i) {
            DeployVault.Params memory q = _vaultParams();
            if (i == 0) q.factory = address(0);
            if (i == 1) q.hubImplementation = address(0);
            if (i == 2) q.p1ProgramKey = bytes32(0);
            if (i == 3) q.p2ImageId = bytes32(0);
            if (i == 4) q.anchor = bytes32(0);
            if (i == 5) q.freezer = address(0);
            vm.expectRevert(abi.encodeWithSelector(DeployVault.Required.selector, names[i]));
            vaultDeployer.check(q);
        }
        DeployVault.Params memory r = _vaultParams();
        r.recoveryProposer = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployVault.Required.selector, "VAULT_RECOVERY"));
        vaultDeployer.check(r);

        r = _vaultParams();
        r.freezer = r.recoveryProposer;
        vm.expectRevert(abi.encodeWithSelector(DeployVault.SameRole.selector, r.freezer));
        vaultDeployer.check(r);
        r = _vaultParams();
        r.freezer = address(this); // the broadcasting key, as this test calls the script
        vm.expectRevert(abi.encodeWithSelector(DeployVault.RoleIsBroadcaster.selector, "VAULT_FREEZER", address(this)));
        vaultDeployer.check(r);
        r = _vaultParams();
        r.recoveryProposer = address(this);
        vm.expectRevert(abi.encodeWithSelector(DeployVault.RoleIsBroadcaster.selector, "VAULT_RECOVERY", address(this)));
        vaultDeployer.check(r);
        r = _vaultParams();
        r.recoveryProposer = makeAddr("a key, not a multisig");
        vm.expectRevert(abi.encodeWithSelector(DeployVault.RecoveryMustBeContract.selector, r.recoveryProposer));
        vaultDeployer.check(r);
        address delegated = makeAddr("an EIP-7702 delegated key");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(r.factory)));
        r.recoveryProposer = delegated;
        vm.expectRevert(abi.encodeWithSelector(DeployVault.RecoveryMustBeContract.selector, delegated));
        vaultDeployer.check(r);

        r = _vaultParams();
        r.nativeFloor = r.nativeCap + 1;
        vm.expectRevert(abi.encodeWithSelector(DeployVault.FloorAboveCap.selector, r.nativeFloor, r.nativeCap));
        vaultDeployer.check(r);
    }

    /// @dev Only SP1's v6.0.0 verifier for P1 and RISC Zero's 3.0.0 verifier for P2: a contract that answers neither, a
    ///      wrong hash or selector, or a wrong version is refused, and so is an address with no code.
    function test_deployVault_onlyThePinnedVerifiers() public {
        DeployVault vaultDeployer = new DeployVault();
        DeployVault.Params memory p = _vaultParams();
        vaultDeployer.checkVerifiers(p.sp1Verifier, p.riscZeroVerifier);

        address[3] memory notSp1 = [makeAddr("no code"), address(router), p.riscZeroVerifier];
        for (uint256 i = 0; i < notSp1.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(DeployVault.WrongVerifier.selector, "VAULT_SP1_VERIFIER", notSp1[i]));
            vaultDeployer.checkVerifiers(notSp1[i], p.riscZeroVerifier);
        }
        address[3] memory notRiscZero = [makeAddr("no code either"), address(router), p.sp1Verifier];
        for (uint256 i = 0; i < notRiscZero.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(DeployVault.WrongVerifier.selector, "VAULT_RISC_ZERO_VERIFIER", notRiscZero[i])
            );
            vaultDeployer.checkVerifiers(p.sp1Verifier, notRiscZero[i]);
        }

        // Each identity field alone decides: the right hash at another version, the right selector at another version.
        vm.mockCall(p.sp1Verifier, abi.encodeWithSignature("VERSION()"), abi.encode("v5.0.0"));
        vm.expectRevert(abi.encodeWithSelector(DeployVault.WrongVerifier.selector, "VAULT_SP1_VERIFIER", p.sp1Verifier));
        vaultDeployer.checkVerifiers(p.sp1Verifier, p.riscZeroVerifier);
        vm.clearMockedCalls();
        vm.mockCall(p.riscZeroVerifier, abi.encodeWithSignature("VERSION()"), abi.encode("2.2.0"));
        vm.expectRevert(
            abi.encodeWithSelector(DeployVault.WrongVerifier.selector, "VAULT_RISC_ZERO_VERIFIER", p.riscZeroVerifier)
        );
        vaultDeployer.checkVerifiers(p.sp1Verifier, p.riscZeroVerifier);
        vm.clearMockedCalls();
        vm.mockCall(p.riscZeroVerifier, abi.encodeWithSignature("SELECTOR()"), abi.encode(bytes4(0x9f39696c)));
        vm.expectRevert(
            abi.encodeWithSelector(DeployVault.WrongVerifier.selector, "VAULT_RISC_ZERO_VERIFIER", p.riscZeroVerifier)
        );
        vaultDeployer.checkVerifiers(p.sp1Verifier, p.riscZeroVerifier);
    }

    /// @dev The release check refuses a deployment that is not the one the parameters describe: another deployment's P1
    ///      swapped in, or parameters naming another factory. Structs are copied by encoding, since assigning a memory
    ///      struct only aliases it.
    function test_deployVault_checkDeploymentRefusesAnother() public {
        DeployVault vaultDeployer = new DeployVault();
        DeployVault.Params memory p = _vaultParams();
        DeployVault.Deployment memory d = vaultDeployer.deploy(p);
        DeployVault.Deployment memory other = vaultDeployer.deploy(_vaultParams());

        DeployVault.Deployment memory mixed = abi.decode(abi.encode(d), (DeployVault.Deployment));
        mixed.p1 = other.p1;
        vm.expectRevert(
            abi.encodeWithSelector(DeployVault.WrongWiring.selector, "p1", address(other.p1), address(d.p1))
        );
        vaultDeployer.checkDeployment(mixed, p);

        DeployVault.Params memory q = abi.decode(abi.encode(p), (DeployVault.Params));
        q.factory = makeAddr("another factory");
        vm.expectRevert(abi.encodeWithSelector(DeployVault.WrongWiring.selector, "FACTORY", q.factory, p.factory));
        vaultDeployer.checkDeployment(d, q);
    }

    /// @dev A hybrid factory owned by DEFAULT_SENDER, the key script broadcasts come from in tests, with a vault chain
    ///      registered and its native coin listed: `vaultToken` is that coin's id on Ethereum.
    function _hybridWithVaultToken(uint256 supply) internal returns (HybridIndexFactory factory, address vaultToken) {
        factory = _hybridFactory(DEFAULT_SENDER);
        _registerBnb(factory);
        vm.prank(DEFAULT_SENDER);
        factory.proposeVaultListing(BNB, bytes32(0), supply);
        vaultToken = factory.vaultTokenId(BNB, bytes32(0));
    }

    /// @dev A hybrid factory owned by `owner_`, with no chain registered.
    function _hybridFactory(address owner_) internal returns (HybridIndexFactory factory) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        HybridHubExtension extension = new HybridHubExtension(predicted);
        HybridHubModule module = new HybridHubModule(predicted, address(extension));
        HybridHub template = new HybridHub(predicted, address(module));
        factory = new HybridIndexFactory(owner_, guardian, address(template));
    }

    /// @dev Registers BNB Chain on a factory owned by DEFAULT_SENDER; any contract stands for the state verifier.
    function _registerBnb(HybridIndexFactory factory) internal {
        vm.prank(DEFAULT_SENDER);
        factory.proposeChain(BNB, BNB_VAULT, address(router));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeChain(BNB);
    }

    /// @dev A vault token has no code on Ethereum, so the ERC-20 checks of the whitelist policy cannot apply to it. The
    ///      script executes its listing, includes it in the weekly batch on its supply alone, and never proposes its
    ///      first listing, which `proposeListing` would refuse: `proposeVaultListing` lists it.
    function test_vaultTokensRideTheWeeklyBatch() public {
        (HybridIndexFactory factory, address bnb) = _hybridWithVaultToken(140_000_000e18);
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](1);
        list[0] = ConfigureWhitelist.Entry({token: bnb, referenceSupply: 140_000_000e18});
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(bnb), "its listing executes as any other");

        list[0].referenceSupply = 140_500_000e18; // within MAX_SUPPLY_STEP
        configure.proposeSupplies(factory, list);
        (, uint256 eta,,) = factory.pendingSupplies();
        assertGt(eta, 0, "the batch names the vault token");
        vm.warp(eta);
        configure.executeSupplies(factory, list);
        assertEq(factory.referenceSupply(bnb), 140_500_000e18);

        // Delisted, it is not proposed again through proposeListing, even when named for relisting.
        vm.prank(guardian);
        factory.delist(bnb);
        address[] memory relist = new address[](1);
        relist[0] = bnb;
        configure.propose(factory, list, none, relist);
        assertEq(factory.listingEta(bnb), 0, "a vault token is never proposed through proposeListing");
        (bytes[] memory calls,) = configure.safeCalldata(factory, list, none, relist);
        assertEq(calls.length, 0, "nor offered to a Safe");

        // An out-of-range supply is still refused for a vault token.
        vm.warp(block.timestamp + 7 days);
        vm.prank(DEFAULT_SENDER);
        factory.proposeVaultListing(56, bytes32(0), 140_500_000e18);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);
        list[0].referenceSupply = 0;
        vm.expectRevert(ConfigureWhitelist.NothingToBatch.selector);
        configure.proposeSupplies(factory, list);
    }

    // ---------------------------------------------------------------------
    // ConfigureChains
    // ---------------------------------------------------------------------

    function _chainEntry(uint256 id, bytes32 vault, address verifier)
        internal
        pure
        returns (ConfigureChains.ChainEntry[] memory entries)
    {
        entries = new ConfigureChains.ChainEntry[](1);
        entries[0] = ConfigureChains.ChainEntry({chainId: id, vault: vault, stateVerifier: verifier});
    }

    function _tokenEntry(uint256 id, bytes32 tokenId, uint256 supply)
        internal
        pure
        returns (ConfigureChains.TokenEntry[] memory entries)
    {
        entries = new ConfigureChains.TokenEntry[](1);
        entries[0] = ConfigureChains.TokenEntry({chainId: id, tokenId: tokenId, supply: supply});
    }

    function _chainCalls(
        ConfigureChains script,
        HybridIndexFactory factory,
        ConfigureChains.ChainEntry[] memory chains,
        ConfigureChains.TokenEntry[] memory tokens,
        uint256[] memory rotate
    ) internal view returns (bytes[] memory calls) {
        (calls,) = script.safeCalldata(factory, chains, tokens, rotate);
    }

    function test_configureChains_parse() public {
        ConfigureChains script = new ConfigureChains();
        assertEq(script.parseChains("").length, 0);
        assertEq(script.parseTokens("").length, 0);
        assertEq(script.parseIds("").length, 0);
        assertEq(script.parseCaps("").length, 0);
        ConfigureChains.CapEntry[] memory caps = script.parseCaps("56:0x0:1000:10, 56:0xb5c:7:0");
        assertEq(caps.length, 2);
        assertEq(caps[0].chainId, 56);
        assertEq(caps[0].tokenId, bytes32(0));
        assertEq(caps[0].cap, 1000);
        assertEq(caps[0].floor, 10);
        assertEq(caps[1].tokenId, bytes32(uint256(0xb5c)));
        assertEq(caps[1].cap, 7);
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.MalformedEntry.selector, "56:0x0:1"));
        script.parseCaps("56:0x0:1");
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.MalformedEntry.selector, "56:7:1:0"));
        script.parseCaps("56:7:1:0");

        ConfigureChains.ChainEntry[] memory chains = script.parseChains(
            string.concat(
                "56:",
                vm.toString(BNB_VAULT),
                ":",
                vm.toString(address(router)),
                " , 728126428:0x41:",
                vm.toString(usdc)
            )
        );
        assertEq(chains.length, 2);
        assertEq(chains[0].chainId, BNB);
        assertEq(chains[0].vault, BNB_VAULT);
        assertEq(chains[0].stateVerifier, address(router));
        assertEq(chains[1].chainId, 728126428, "spaces around an entry are trimmed");
        assertEq(chains[1].vault, bytes32(uint256(0x41)), "a short vault is left-padded");
        assertEq(chains[1].stateVerifier, usdc);

        ConfigureChains.TokenEntry[] memory tokens = script.parseTokens("56:0x0:140000000000000000000000000, 56:0x1:7");
        assertEq(tokens.length, 2);
        assertEq(tokens[0].chainId, BNB);
        assertEq(tokens[0].tokenId, bytes32(0));
        assertEq(tokens[0].supply, 140_000_000e18);
        assertEq(tokens[1].tokenId, bytes32(uint256(1)));
        assertEq(tokens[1].supply, 7);

        uint256[] memory ids = script.parseIds("56, 728126428");
        assertEq(ids.length, 2);
        assertEq(ids[0], BNB);
        assertEq(ids[1], 728126428);

        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.MalformedEntry.selector, "56:0xb5c"));
        script.parseChains("56:0xb5c");
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.MalformedEntry.selector, "56:0x0:1:2"));
        script.parseTokens("56:0x0:1:2");
        // A word in decimal would read as another word, and "0x" alone as zero.
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.MalformedEntry.selector, "56:2908:0x01"));
        script.parseChains("56:2908:0x01");
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.MalformedEntry.selector, "56:0x:1"));
        script.parseTokens("56:0x:1");
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.MalformedEntry.selector, "56:1x0:1"));
        script.parseTokens("56:1x0:1");
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.MalformedEntry.selector, "56:00:1"));
        script.parseTokens("56:00:1");
    }

    /// @dev A chain first, then its coin: the coin waits for its chain's registration, each proposal executes once due,
    ///      a second run finds nothing to do, and the Safe's calls are exactly what an owner key proposes.
    function test_configureChains_addsAChainThenItsCoin() public {
        ConfigureChains script = new ConfigureChains();
        HybridIndexFactory factory = _hybridFactory(DEFAULT_SENDER);
        ConfigureChains.ChainEntry[] memory chains = _chainEntry(BNB, BNB_VAULT, address(router));
        ConfigureChains.TokenEntry[] memory tokens = _tokenEntry(BNB, bytes32(0), 140_000_000e18);
        uint256[] memory noRotation;
        address bnb = factory.vaultTokenId(BNB, bytes32(0));

        assertTrue(script.shouldProposeChain(factory, chains[0], noRotation));
        assertFalse(script.shouldListToken(factory, tokens[0]), "the coin waits for its chain");
        (bytes[] memory calls, string[] memory labels) = script.safeCalldata(factory, chains, tokens, noRotation);
        assertEq(calls.length, 1, "the coin waits for its chain");
        assertEq(calls[0], abi.encodeCall(IHybridIndexFactory.proposeChain, (BNB, BNB_VAULT, address(router))));
        assertEq(labels[0], "proposeChain 56");

        script.propose(factory, chains, tokens, noRotation);
        (bytes32 vault, address verifier, uint256 eta) = factory.chainProposal(BNB);
        assertEq(vault, BNB_VAULT);
        assertEq(verifier, address(router));
        assertEq(eta, block.timestamp + factory.LISTING_DELAY());
        assertEq(_chainCalls(script, factory, chains, tokens, noRotation).length, 0, "already pending");

        script.execute(factory, chains, tokens);
        assertEq(factory.chain(BNB).vault, bytes32(0), "not before its delay");
        vm.warp(eta);
        script.execute(factory, chains, tokens);
        assertEq(factory.chain(BNB).vault, BNB_VAULT, "registered");
        assertEq(factory.chain(BNB).stateVerifier, address(router));

        (calls, labels) = script.safeCalldata(factory, chains, tokens, noRotation);
        assertEq(calls.length, 1, "the registered chain is not proposed again; its coin is");
        assertEq(calls[0], abi.encodeCall(IHybridIndexFactory.proposeVaultListing, (BNB, bytes32(0), 140_000_000e18)));
        assertEq(labels[0], string.concat("proposeVaultListing 56 ", vm.toString(bytes32(0))));
        script.propose(factory, chains, tokens, noRotation);
        assertEq(factory.pendingReferenceSupply(bnb), 140_000_000e18);
        assertEq(_chainCalls(script, factory, chains, tokens, noRotation).length, 0, "already pending");

        script.execute(factory, chains, tokens);
        assertFalse(factory.isWhitelisted(bnb), "not before its delay");
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        script.execute(factory, chains, tokens);
        assertTrue(factory.isWhitelisted(bnb), "listed");
        assertEq(factory.referenceSupply(bnb), 140_000_000e18);
        assertEq(_chainCalls(script, factory, chains, tokens, noRotation).length, 0, "nothing left to do");
        script.execute(factory, chains, tokens); // and nothing to execute
    }

    /// @dev Every chain entry the factory would refuse, or that names nothing new, is skipped with its reason, so a Safe
    ///      batch never fails on one call (CR-I38): no chain id, this chain's own id, a zero vault, a verifier with no
    ///      code, another vault for a registered chain, the registered verifier again, and a new verifier for a chain
    ///      the run was not told to rotate.
    function test_configureChains_skipsAChainTheFactoryWouldRefuse() public {
        ConfigureChains script = new ConfigureChains();
        HybridIndexFactory factory = _hybridFactory(DEFAULT_SENDER);
        _registerBnb(factory);
        ConfigureChains.TokenEntry[] memory noTokens;
        uint256[] memory rotate = new uint256[](1);
        rotate[0] = BNB;

        ConfigureChains.ChainEntry[7] memory refused = [
            ConfigureChains.ChainEntry({chainId: 0, vault: BNB_VAULT, stateVerifier: address(router)}),
            ConfigureChains.ChainEntry({chainId: block.chainid, vault: BNB_VAULT, stateVerifier: address(router)}),
            ConfigureChains.ChainEntry({chainId: 43114, vault: bytes32(0), stateVerifier: address(router)}),
            ConfigureChains.ChainEntry({chainId: 43114, vault: BNB_VAULT, stateVerifier: makeAddr("no code")}),
            ConfigureChains.ChainEntry({chainId: BNB, vault: bytes32(uint256(1)), stateVerifier: address(router)}),
            ConfigureChains.ChainEntry({chainId: BNB, vault: BNB_VAULT, stateVerifier: address(router)}),
            ConfigureChains.ChainEntry({chainId: BNB, vault: BNB_VAULT, stateVerifier: usdc})
        ];
        for (uint256 i = 0; i < refused.length; ++i) {
            ConfigureChains.ChainEntry[] memory one =
                _chainEntry(refused[i].chainId, refused[i].vault, refused[i].stateVerifier);
            // The last is refused only because ROTATE does not name it; the others whatever ROTATE says.
            uint256[] memory named = i == refused.length - 1 ? new uint256[](0) : rotate;
            assertEq(_chainCalls(script, factory, one, noTokens, named).length, 0, vm.toString(i));
            script.propose(factory, one, noTokens, named);
            assertFalse(factory.chainPending(refused[i].chainId), vm.toString(i));
        }
        assertEq(factory.chain(BNB).stateVerifier, address(router), "nothing changed");
    }

    /// @dev FAC-1: a new state verifier for a registered chain is proposed only when ROTATE names the chain, and waits
    ///      ROTATION_DELAY. A different proposal pending is left alone in both modes, and an expired one is reported and
    ///      proposed again on the next run.
    function test_FAC1_configureChainsRotatesAVerifierOnlyWhenNamed() public {
        ConfigureChains script = new ConfigureChains();
        HybridIndexFactory factory = _hybridFactory(DEFAULT_SENDER);
        _registerBnb(factory);
        ConfigureChains.TokenEntry[] memory noTokens;
        uint256[] memory rotate = new uint256[](2);
        (rotate[0], rotate[1]) = (43114, BNB); // the chain need not come first

        ConfigureChains.ChainEntry[] memory toUsdc = _chainEntry(BNB, BNB_VAULT, usdc);
        script.propose(factory, toUsdc, noTokens, rotate);
        (, address verifier, uint256 eta) = factory.chainProposal(BNB);
        assertEq(verifier, usdc);
        assertEq(eta, block.timestamp + factory.ROTATION_DELAY(), "a rotation waits 30 days");

        ConfigureChains.ChainEntry[] memory toUsdt = _chainEntry(BNB, BNB_VAULT, usdt);
        assertEq(_chainCalls(script, factory, toUsdt, noTokens, rotate).length, 0, "a different proposal is pending");
        vm.warp(eta);
        script.execute(factory, toUsdt, noTokens);
        assertEq(factory.chain(BNB).stateVerifier, address(router), "a pending proposal unlike the entry is left");
        vm.warp(eta - 1);
        script.execute(factory, toUsdc, noTokens);
        assertEq(factory.chain(BNB).stateVerifier, address(router), "not before ROTATION_DELAY");
        vm.warp(eta + factory.PROPOSAL_WINDOW() + 1);
        script.execute(factory, toUsdc, noTokens);
        assertEq(factory.chain(BNB).stateVerifier, address(router), "nor after its window");

        script.propose(factory, toUsdc, noTokens, rotate);
        (,, eta) = factory.chainProposal(BNB);
        assertEq(eta, block.timestamp + factory.ROTATION_DELAY(), "an expired proposal is proposed again");
        vm.warp(eta);
        script.execute(factory, toUsdc, noTokens);
        assertEq(factory.chain(BNB).stateVerifier, usdc, "rotated");
        assertEq(factory.chain(BNB).vault, BNB_VAULT, "the vault is fixed");
    }

    /// @dev A coin entry the factory would refuse is skipped with its reason: a supply of zero or past MAX_SUPPLY, and a
    ///      delisted coin the live supply batch names (DA-20). A delisted coin is relisted at the supply in force,
    ///      whatever its entry says (SA-02), and execute leaves a pending listing whose supply is not the entry's, and
    ///      one past its window.
    function test_configureChains_skipsACoinTheFactoryWouldRefuse() public {
        ConfigureChains script = new ConfigureChains();
        HybridIndexFactory factory = _hybridFactory(DEFAULT_SENDER);
        _registerBnb(factory);
        ConfigureChains.ChainEntry[] memory noChains;
        uint256[] memory noRotation;

        assertEq(_chainCalls(script, factory, noChains, _tokenEntry(BNB, bytes32(0), 0), noRotation).length, 0);
        uint256 tooMuch = factory.MAX_SUPPLY() + 1;
        assertEq(_chainCalls(script, factory, noChains, _tokenEntry(BNB, bytes32(0), tooMuch), noRotation).length, 0);

        // Two coins listed, the first delisted and named by the live batch, the second delisted and not.
        ConfigureChains.TokenEntry[] memory both = new ConfigureChains.TokenEntry[](2);
        both[0] = ConfigureChains.TokenEntry({chainId: BNB, tokenId: bytes32(0), supply: 1_000e18});
        both[1] = ConfigureChains.TokenEntry({chainId: BNB, tokenId: bytes32(uint256(1)), supply: 2_000e18});
        script.propose(factory, noChains, both, noRotation);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        script.execute(factory, noChains, both);
        address first = factory.vaultTokenId(BNB, bytes32(0));
        address second = factory.vaultTokenId(BNB, bytes32(uint256(1)));
        assertTrue(factory.isWhitelisted(first) && factory.isWhitelisted(second));
        vm.startPrank(guardian);
        factory.delist(first);
        factory.delist(second);
        vm.stopPrank();
        address[] memory batch = new address[](1);
        uint256[] memory supplies = new uint256[](1);
        (batch[0], supplies[0]) = (first, 1_004e18);
        vm.prank(DEFAULT_SENDER);
        factory.proposeSupplies(batch, supplies);

        both[1].supply = 3_000e18; // the entry moved, the supply in force did not
        assertEq(script.listingSupply(factory, both[1]), 2_000e18, "a relisting proposes the supply in force");
        bytes[] memory calls = _chainCalls(script, factory, noChains, both, noRotation);
        assertEq(calls.length, 1, "the coin the batch names waits");
        assertEq(
            calls[0], abi.encodeCall(IHybridIndexFactory.proposeVaultListing, (BNB, bytes32(uint256(1)), 2_000e18))
        );
        script.propose(factory, noChains, both, noRotation);
        assertEq(factory.pendingReferenceSupply(second), 2_000e18, "relisted at the supply in force");
        assertEq(factory.listingEta(first), 0);

        // The first coin's listing is proposed once the batch is gone.
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeSupplies();
        script.execute(factory, noChains, both);
        assertTrue(factory.isWhitelisted(second));
        script.propose(factory, noChains, both, noRotation);
        assertEq(factory.pendingReferenceSupply(first), 1_004e18, "the batch's supply is the one in force");

        // A first listing executes only at its entry's supply, and only inside its window.
        ConfigureChains.TokenEntry[] memory third = _tokenEntry(BNB, bytes32(uint256(2)), 5e18);
        address coin = factory.vaultTokenId(BNB, bytes32(uint256(2)));
        script.propose(factory, noChains, third, noRotation);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        third[0].supply = 6e18;
        script.execute(factory, noChains, third);
        assertFalse(factory.isWhitelisted(coin), "the pending supply is not the entry's");
        third[0].supply = 5e18;
        vm.warp(block.timestamp + factory.PROPOSAL_WINDOW() + 1);
        script.execute(factory, noChains, third);
        assertFalse(factory.isWhitelisted(coin), "expired");
        assertFalse(factory.isWhitelisted(first), "expired too");
    }

    /// @dev RT-24 for chains and coins: safe mode decides every entry against the same state, so an entry named twice
    ///      would be proposed twice and the second call would revert the whole Safe batch. Both modes refuse it.
    function test_RT24_chainsAndCoinsNamedTwiceAreRefused() public {
        ConfigureChains script = new ConfigureChains();
        HybridIndexFactory factory = _hybridFactory(DEFAULT_SENDER);
        uint256[] memory noRotation;
        ConfigureChains.TokenEntry[] memory noTokens;
        ConfigureChains.ChainEntry[] memory noChains;

        ConfigureChains.ChainEntry[] memory chains = new ConfigureChains.ChainEntry[](3);
        chains[0] = ConfigureChains.ChainEntry({chainId: BNB, vault: BNB_VAULT, stateVerifier: address(router)});
        chains[1] = ConfigureChains.ChainEntry({chainId: 43114, vault: BNB_VAULT, stateVerifier: address(router)});
        chains[2] = ConfigureChains.ChainEntry({chainId: BNB, vault: bytes32(uint256(1)), stateVerifier: usdc});
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.DuplicateChain.selector, BNB));
        script.safeCalldata(factory, chains, noTokens, noRotation);
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.DuplicateChain.selector, BNB));
        script.propose(factory, chains, noTokens, noRotation);

        ConfigureChains.TokenEntry[] memory tokens = new ConfigureChains.TokenEntry[](3);
        tokens[0] = ConfigureChains.TokenEntry({chainId: BNB, tokenId: bytes32(0), supply: 1});
        tokens[1] = ConfigureChains.TokenEntry({chainId: 43114, tokenId: bytes32(0), supply: 1}); // another chain's coin
        tokens[2] = ConfigureChains.TokenEntry({chainId: BNB, tokenId: bytes32(0), supply: 2});
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.DuplicateToken.selector, BNB, bytes32(0)));
        script.safeCalldata(factory, noChains, tokens, noRotation);
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.DuplicateToken.selector, BNB, bytes32(0)));
        script.propose(factory, noChains, tokens, noRotation);

        chains[2].chainId = 1; // three distinct chains, and two distinct coins
        ConfigureChains.TokenEntry[] memory two = new ConfigureChains.TokenEntry[](2);
        (two[0], two[1]) = (tokens[0], tokens[1]);
        assertEq(_chainCalls(script, factory, chains, two, noRotation).length, 3, "every chain; no coin yet");
    }

    /// @dev XA-18 and LR-07 for chains: an owner that is a contract cannot sign, so `propose` refuses it and points to
    ///      safe mode, while a key delegated under EIP-7702 still signs.
    function test_configureChains_proposeNeedsAnOwnerKey() public {
        ConfigureChains script = new ConfigureChains();
        MockSafe safe = new MockSafe(3);
        HybridIndexFactory factory = _hybridFactory(address(safe));
        ConfigureChains.ChainEntry[] memory chains = _chainEntry(BNB, BNB_VAULT, address(router));
        ConfigureChains.TokenEntry[] memory noTokens;
        uint256[] memory noRotation;
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.OwnerIsContract.selector, address(safe)));
        script.propose(factory, chains, noTokens, noRotation);
        assertEq(_chainCalls(script, factory, chains, noTokens, noRotation).length, 1, "safe mode serves it");

        HybridIndexFactory keyed = _hybridFactory(DEFAULT_SENDER);
        vm.etch(DEFAULT_SENDER, abi.encodePacked(hex"ef0100", address(this)));
        script.propose(keyed, chains, noTokens, noRotation);
        assertTrue(keyed.chainPending(BNB), "the delegated key proposed");
    }

    function _capEntry(uint256 id, bytes32 tokenId, uint256 cap, uint256 floor)
        internal
        pure
        returns (ConfigureChains.CapEntry[] memory entries)
    {
        entries = new ConfigureChains.CapEntry[](1);
        entries[0] = ConfigureChains.CapEntry({chainId: id, tokenId: tokenId, cap: cap, floor: floor});
    }

    /// @dev Registers BNB Chain on `factory` through the script, as `test_configureChains_addsAChainThenItsCoin` does.
    function _registerBnb(ConfigureChains script, HybridIndexFactory factory) internal {
        ConfigureChains.ChainEntry[] memory chains = _chainEntry(BNB, BNB_VAULT, address(router));
        ConfigureChains.TokenEntry[] memory noTokens;
        uint256[] memory noRotation;
        script.propose(factory, chains, noTokens, noRotation);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        script.execute(factory, chains, noTokens);
    }

    /// @dev A token on a vault chain gets its cap through the factory's timelock: proposed once its chain is registered,
    ///      then sent as a CAP_UPDATE once due, and only as its entry says. An unregistered chain, a floor above the
    ///      cap and a live proposal, the entry's or another, are skipped with their reasons; an expired one is left.
    function test_configureChains_proposesAndSendsATokensCap() public {
        ConfigureChains script = new ConfigureChains();
        HybridIndexFactory factory = _hybridFactory(DEFAULT_SENDER);
        bytes32 peg = bytes32(uint256(uint160(makeAddr("Binance-Peg XRP Token"))));
        ConfigureChains.CapEntry[] memory caps = _capEntry(BNB, peg, 1_000_000e18, 1000e18);
        ConfigureChains.CapEntry[] memory other = _capEntry(BNB, peg, 2_000_000e18, 1000e18);
        assertFalse(script.shouldProposeCap(factory, caps[0]), "the cap waits for its chain");
        (bytes[] memory calls, string[] memory labels) = script.capCalldata(factory, caps);
        assertEq(calls.length, 0);
        script.proposeCaps(factory, caps);
        bytes32 id = script.capProposalId(factory, caps[0]);
        assertEq(id, factory.vaultProposalId(BNB, VaultMessages.CAP_UPDATE, peg));
        assertEq(factory.vaultProposal(id).eta, 0, "nothing proposed");

        _registerBnb(script, factory);
        assertFalse(script.shouldProposeCap(factory, _capEntry(BNB, peg, 1, 2)[0]), "a floor above the cap");
        (calls, labels) = script.capCalldata(factory, caps);
        assertEq(calls.length, 1);
        assertEq(calls[0], abi.encodeCall(IHybridIndexFactory.proposeCap, (BNB, peg, 1_000_000e18, 1000e18)));
        assertEq(labels[0], string.concat("proposeCap 56 ", vm.toString(peg)));
        script.proposeCaps(factory, caps);
        IHybridIndexFactory.VaultProposal memory p = factory.vaultProposal(id);
        assertEq(p.body, script.capBody(caps[0]));
        assertEq(p.eta, block.timestamp + factory.LISTING_DELAY());
        (calls,) = script.capCalldata(factory, caps);
        assertEq(calls.length, 0, "already pending");
        (calls,) = script.capCalldata(factory, other);
        assertEq(calls.length, 0, "another cap is pending");

        script.executeCaps(factory, caps);
        assertEq(factory.vaultProposal(id).eta, p.eta, "not before its delay");
        vm.warp(p.eta);
        script.executeCaps(factory, other);
        assertEq(factory.vaultProposal(id).eta, p.eta, "not as another entry says");
        vm.recordLogs();
        script.executeCaps(factory, caps);
        assertEq(factory.vaultProposal(id).eta, 0, "sent");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        VaultMessages.Message memory m;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == VaultMessages.EVENT_TOPIC) {
                m = VaultMessages.decode(abi.decode(logs[i].data, (bytes)));
            }
        }
        assertEq(m.kind, VaultMessages.CAP_UPDATE);
        assertEq(m.body, script.capBody(caps[0]));
        script.executeCaps(factory, caps); // nothing pending

        script.proposeCaps(factory, other);
        vm.warp(block.timestamp + factory.LISTING_DELAY() + factory.PROPOSAL_WINDOW() + 1);
        script.executeCaps(factory, other);
        assertTrue(factory.vaultProposal(id).eta != 0, "an expired proposal is left");
        assertTrue(script.shouldProposeCap(factory, other[0]), "and may be proposed again");
    }

    /// @dev RT-24 for caps: a coin named twice would be proposed twice and revert the whole Safe batch. And XA-18 for
    ///      caps: a contract owner cannot sign, so `proposeCaps` points to safe mode.
    function test_RT24_capsNamedTwiceAreRefused() public {
        ConfigureChains script = new ConfigureChains();
        HybridIndexFactory factory = _hybridFactory(DEFAULT_SENDER);
        ConfigureChains.CapEntry[] memory caps = new ConfigureChains.CapEntry[](3);
        caps[0] = ConfigureChains.CapEntry({chainId: BNB, tokenId: bytes32(uint256(7)), cap: 2, floor: 1});
        caps[1] = ConfigureChains.CapEntry({chainId: 43114, tokenId: bytes32(uint256(7)), cap: 2, floor: 1});
        caps[2] = ConfigureChains.CapEntry({chainId: BNB, tokenId: bytes32(uint256(7)), cap: 3, floor: 1});
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.DuplicateCap.selector, BNB, bytes32(uint256(7))));
        script.capCalldata(factory, caps);
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.DuplicateCap.selector, BNB, bytes32(uint256(7))));
        script.proposeCaps(factory, caps);

        MockSafe safe = new MockSafe(3);
        HybridIndexFactory owned = _hybridFactory(address(safe));
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.OwnerIsContract.selector, address(safe)));
        script.proposeCaps(owned, _capEntry(BNB, bytes32(uint256(7)), 2, 1));
    }

    /// @dev The BNB list is the admission report's record, written here independently of `BnbChainAddresses`: each
    ///      token's address on chain 56, read there by symbol and decimals on 2026-10-05, and its coin's supply in the
    ///      token's raw units (DOGE's 8 decimals). NIGHT is left out pending the owner. `bnb` names it on chain 1 only,
    ///      and a run proposes each listing once BNB Chain is registered.
    function test_theBnbListIsTheAdmissionRecord() public {
        ConfigureChains script = new ConfigureChains();
        address[13] memory tokens = [
            0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE, // XRP
            0x570A5D26f7765Ecb712C0924E4De545B89fD43dF, // SOL
            0x1Ba42e5193dfA8B03D15dd1B86a3113bbBEF8Eeb, // ZEC
            0xbA2aE424d960c26247Dd6c32edC70B295c744C43, // DOGE
            0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47, // ADA
            0x8fF795a6F4D97E7887C79beA79aba5cc76444aDf, // BCH
            0x4338665CBB7B2485A8855A139b75D5e34AB0DB94, // LTC
            0x1CE0c2827e2eF14D5C4f29a091d735A204794041, // AVAX
            0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402, // DOT
            0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153, // FIL
            0x0Eb3a705fc54725037CC9e008bDede697f62F335, // ATOM
            0x000Ae314E2A2172a039B26378814C252734f556A, // ASTER
            0x011EBe7d75E2C9D1E0bD0be0bEf5C36f0A90075F // STABLE
        ];
        uint256[13] memory supplies = [
            uint256(63_092_975_951) * 1e18,
            588_314_090 * 1e18,
            16_966_725 * 1e18,
            156_193_186_383 * 1e8,
            37_541_298_084 * 1e18,
            20_098_553 * 1e18,
            77_681_660 * 1e18,
            443_237_655 * 1e18,
            1_705_877_534 * 1e18,
            833_303_530 * 1e18,
            534_279_412 * 1e18,
            2_710_487_455 * 1e18,
            26_924_041_495 * 1e18
        ];
        ConfigureChains.TokenEntry[] memory list = script.bnbTokens();
        assertEq(list.length, tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(list[i].chainId, 56);
            assertEq(list[i].tokenId, bytes32(uint256(uint160(tokens[i]))), "listed by its address");
            assertEq(list[i].supply, supplies[i]);
            assertTrue(
                list[i].tokenId != bytes32(uint256(uint160(0xFe930c2d63AeD9b82fC4DBC801920dD2c1a3224F))), "NIGHT"
            );
        }

        vm.expectRevert(ConfigureChains.BnbListOnlyOnMainnet.selector);
        script.parseTokens("bnb");
        vm.chainId(1);
        assertEq(abi.encode(script.parseTokens("bnb")), abi.encode(list));
        HybridIndexFactory factory = _hybridFactory(DEFAULT_SENDER);
        _registerBnb(script, factory);
        ConfigureChains.ChainEntry[] memory noChains;
        uint256[] memory noRotation;
        bytes[] memory calls = _chainCalls(script, factory, noChains, list, noRotation);
        assertEq(calls.length, tokens.length, "every token's listing");
        assertEq(calls[3], abi.encodeCall(IHybridIndexFactory.proposeVaultListing, (56, list[3].tokenId, supplies[3])));
    }

    function test_configureChainsRun_readsEnvironment() public {
        ConfigureChains script = new ConfigureChains();
        HybridIndexFactory factory = _hybridFactory(DEFAULT_SENDER);
        vm.setEnv("CHAINS_FACTORY", vm.toString(address(factory)));
        vm.setEnv("CHAINS", string.concat("56:", vm.toString(BNB_VAULT), ":", vm.toString(address(router))));
        vm.setEnv("VAULT_TOKENS", "56:0x0:140000000000000000000000000");
        vm.setEnv("ROTATE", "56");
        vm.setEnv("VAULT_CAPS", "56:0x0:1000000000000000000000000:1000000000000000000");
        bytes32 capId = factory.vaultProposalId(BNB, VaultMessages.CAP_UPDATE, bytes32(0));

        vm.setEnv("CHAIN_MODE", "safe"); // logs the chain's calldata, broadcasts nothing
        script.run();
        assertFalse(factory.chainPending(BNB));
        vm.setEnv("CHAIN_MODE", "propose");
        script.run();
        assertTrue(factory.chainPending(BNB));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.setEnv("CHAIN_MODE", "execute");
        script.run();
        assertEq(factory.chain(BNB).vault, BNB_VAULT);

        vm.setEnv("CHAIN_MODE", "safe"); // now the coin's listing and its cap
        script.run();
        vm.setEnv("CHAIN_MODE", "propose");
        script.run();
        assertTrue(factory.vaultProposal(capId).eta != 0, "the cap proposed once the chain is registered");
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.setEnv("CHAIN_MODE", "execute");
        script.run();
        assertTrue(factory.isWhitelisted(factory.vaultTokenId(BNB, bytes32(0))));
        assertEq(factory.vaultProposal(capId).eta, 0, "the cap sent");

        vm.setEnv("CHAIN_MODE", "sideways");
        vm.expectRevert(abi.encodeWithSelector(ConfigureChains.UnknownMode.selector, "sideways"));
        script.run();
    }
}

/// @notice `DeployStateVerifier` on the anchors its generators read from BNB Chain and TRON on 1 October 2026
///         (`test/fixtures/bnb/anchor.json`, `test/fixtures/tron/anchor.json`). The BNB verifier checks keys on the
///         curve with EIP-2537's precompiles, which exist from Prague on.
/// forge-config: default.evm_version = "prague"
contract StateVerifierScriptTest is Test {
    DeployStateVerifier script;
    string bnb;
    string tron;
    uint256 epoch;
    uint256 epochTime;
    bytes epochHeader;
    bytes[] keys;
    ITronStateVerifier.Producer[] list;
    uint64 nextMaintenance;

    function setUp() public {
        script = new DeployStateVerifier();
        bnb = vm.readFile("test/fixtures/bnb/anchor.json");
        tron = vm.readFile("test/fixtures/tron/anchor.json");
        epoch = vm.parseJsonUint(bnb, ".number");
        epochTime = vm.parseJsonUint(bnb, ".time");
        epochHeader = vm.parseJsonBytes(bnb, ".rlp");
        keys = vm.parseJsonBytesArray(bnb, ".keys");
        ITronStateVerifier.Producer[] memory producers = script.producers(tron);
        for (uint256 i = 0; i < producers.length; ++i) {
            list.push(producers[i]);
        }
        nextMaintenance = uint64(vm.parseJsonUint(tron, ".nextMaintenance"));
        vm.chainId(1);
    }

    function _bnbVerifier() internal returns (BnbStateVerifier) {
        vm.warp(epochTime + 10 minutes);
        return script.deployBnb(epochHeader, keys);
    }

    function _tronVerifier() internal returns (TronStateVerifier) {
        vm.warp(nextMaintenance / 1000 - 1 hours);
        return script.deployTron(list, nextMaintenance);
    }

    function test_deployBnb_fromARealAnchor() public {
        BnbStateVerifier verifier = _bnbVerifier();
        assertEq(verifier.latestEpoch(), epoch);
        assertEq(verifier.validatorSet(epoch).count, keys.length);
        assertEq(keccak256(epochHeader), vm.parseJsonBytes32(bnb, ".hash"), "the anchor's header is its block's");
        assertEq(script.checkBnb(address(verifier), epoch, keys), address(verifier).codehash);
    }

    function test_deployTron_fromARealAnchor() public {
        TronStateVerifier verifier = _tronVerifier();
        assertEq(verifier.producerList(0).count, list.length);
        assertEq(verifier.producerList(0).end, nextMaintenance);
        assertEq(script.checkTron(address(verifier), list, nextMaintenance), address(verifier).codehash);
    }

    /// @dev Only on Ethereum, mainnet or Sepolia, beside the hub: not on the chain the verifier reads, nor anywhere else.
    function test_deploy_onlyOnEthereum() public {
        vm.warp(epochTime + 10 minutes);
        uint256[3] memory elsewhere = [uint256(56), 728126428, 31337];
        for (uint256 i = 0; i < elsewhere.length; ++i) {
            vm.chainId(elsewhere[i]);
            vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotEthereum.selector, elsewhere[i]));
            script.deployBnb(epochHeader, keys);
            vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotEthereum.selector, elsewhere[i]));
            script.deployTron(list, nextMaintenance);
        }
        vm.chainId(11155111);
        script.deployBnb(epochHeader, keys);
    }

    /// @dev A BNB anchor more than an hour old leaves too little of MAX_LAG to advance the verifier, and one from the
    ///      future is not a block the chain has finalized. A TRON anchor must be the period in progress.
    function test_deploy_onlyAFreshAnchor() public {
        vm.warp(epochTime + script.MAX_ANCHOR_AGE());
        script.deployBnb(epochHeader, keys);
        vm.warp(epochTime + script.MAX_ANCHOR_AGE() + 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, epochTime, block.timestamp));
        script.deployBnb(epochHeader, keys);
        vm.warp(epochTime - 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, epochTime, block.timestamp));
        script.deployBnb(epochHeader, keys);

        uint256 end = nextMaintenance / 1000;
        vm.warp(end - 6 hours);
        script.deployTron(list, nextMaintenance);
        vm.warp(end);
        vm.expectRevert(
            abi.encodeWithSelector(DeployStateVerifier.NotThePeriodInProgress.selector, nextMaintenance, end * 1000)
        );
        script.deployTron(list, nextMaintenance);
        vm.warp(end - 6 hours - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStateVerifier.NotThePeriodInProgress.selector, nextMaintenance, (end - 6 hours - 1) * 1000
            )
        );
        script.deployTron(list, nextMaintenance);
    }

    /// @dev The review refuses a verifier that does not run this release's code, and one that did not start from the
    ///      anchor given: other keys, another epoch, or a set recorded before the anchor's.
    function test_checkBnb_refusesAnotherVerifierOrAnchor() public {
        BnbStateVerifier verifier = _bnbVerifier();
        TronStateVerifier other = _tronVerifier();
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongCode.selector, address(other)));
        script.checkBnb(address(other), epoch, keys);

        bytes[] memory fewer = new bytes[](keys.length - 1);
        for (uint256 i = 0; i < fewer.length; ++i) {
            fewer[i] = keys[i];
        }
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(verifier)));
        script.checkBnb(address(verifier), epoch, fewer);
        bytes[] memory swapped = keys;
        (swapped[0], swapped[1]) = (swapped[1], swapped[0]);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(verifier)));
        script.checkBnb(address(verifier), epoch, swapped);
        (swapped[0], swapped[1]) = (swapped[1], swapped[0]);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(verifier)));
        script.checkBnb(address(verifier), epoch + 1000, keys);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(verifier)));
        script.checkBnb(address(verifier), 0, keys); // before any epoch

        // A set recorded one epoch before the anchor's means the verifier started elsewhere.
        bytes32 slot = keccak256(abi.encode(epoch - 1000, uint256(1)));
        vm.store(address(verifier), slot, bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(verifier)));
        script.checkBnb(address(verifier), epoch, keys);
    }

    function test_checkTron_refusesAnotherVerifierOrAnchor() public {
        TronStateVerifier verifier = _tronVerifier();
        BnbStateVerifier other = _bnbVerifier();
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongCode.selector, address(other)));
        script.checkTron(address(other), list, nextMaintenance);

        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(verifier)));
        script.checkTron(address(verifier), list, nextMaintenance + 6 hours * 1000);
        ITronStateVerifier.Producer[] memory changed = list;
        changed[0].key = address(1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(verifier)));
        script.checkTron(address(verifier), changed, nextMaintenance);
    }

    // ---------------------------------------------------------------------
    // NEAR and Stellar
    // ---------------------------------------------------------------------

    string near = vm.readFile("test/fixtures/near/anchor.json");
    string stellar = vm.readFile("test/fixtures/stellar/anchor.json");

    function _deployNear(ISP1Verifier sp1, uint256 chainId) internal returns (NearStateVerifier) {
        bytes32 key = vm.parseJsonBytes32(near, ".programKey");
        string memory account = vm.parseJsonString(near, ".account");
        bytes32 epochId = vm.parseJsonBytes32(near, ".epochId");
        bytes32 producersHash = vm.parseJsonBytes32(near, ".producersHash");
        uint64 named = uint64(vm.parseJsonUint(near, ".namedAt"));
        return script.deployNear(sp1, key, chainId, account, epochId, producersHash, named);
    }

    function _deployStellar(ISP1Verifier sp1, bytes32 networkId, uint256 chainId)
        internal
        returns (StellarStateVerifier)
    {
        bytes32 key = vm.parseJsonBytes32(stellar, ".programKey");
        bytes memory quorumSet = vm.parseJsonBytes(stellar, ".quorumSet");
        bytes32 vaultId = vm.parseJsonBytes32(stellar, ".vaultId");
        return script.deployStellar(sp1, key, networkId, quorumSet, chainId, vaultId);
    }

    function _namedAt() internal view returns (uint256) {
        return vm.parseJsonUint(near, ".namedAt") / 1e9;
    }

    /// @dev NEAR's verifier, from a real mainnet epoch and its producers, for one vault: its id is the keccak of the
    ///      vault's account id (`design/2026-10-03-near-stellar-interfaces.md`), and it must be advanced within a day.
    function test_deployNear_fromARealAnchor() public {
        ISP1Verifier sp1 = new MockSP1Verifier();
        vm.warp(_namedAt() + 10 minutes);
        NearStateVerifier verifier = _deployNear(sp1, script.NEAR_MAINNET());
        assertEq(verifier.epochId(), vm.parseJsonBytes32(near, ".epochId"));
        assertEq(verifier.producersHash(), vm.parseJsonBytes32(near, ".producersHash"));
        assertEq(verifier.namedAt(), vm.parseJsonUint(near, ".namedAt"));
        assertEq(verifier.VAULT_ID(), keccak256(bytes(vm.parseJsonString(near, ".account"))));
        assertEq(verifier.CHAIN_ID(), 339_552_387_624_818_629, "keccak256('near:mainnet')'s first 8 bytes");
    }

    /// @dev Stellar's verifier pins the network and Tier 1's quorum set, by the hash its validators sign.
    function test_deployStellar_fromARealQuorumSet() public {
        ISP1Verifier sp1 = new MockSP1Verifier();
        StellarStateVerifier verifier = _deployStellar(sp1, script.STELLAR_PUBNET_ID(), script.STELLAR_PUBNET());
        assertEq(verifier.QUORUM_SET_HASH(), 0x040355b75766e6799d1ef69ce03f114530a06d922dd64b5e885da907a453841d);
        assertEq(verifier.NETWORK_ID(), sha256("Public Global Stellar Network ; September 2015"));
        assertEq(verifier.CHAIN_ID(), 839_718_837_228_939_926, "keccak256('stellar:pubnet')'s first 8 bytes");
        assertEq(verifier.VAULT_ID(), vm.parseJsonBytes32(stellar, ".vaultId"));
        assertEq(script.STELLAR_TESTNET_ID(), sha256("Test SDF Network ; September 2015"));
        assertEq(script.NEAR_TESTNET(), uint64(bytes8(keccak256("near:testnet"))));
        assertEq(script.STELLAR_TESTNET(), uint64(bytes8(keccak256("stellar:testnet"))));
    }

    /// @dev Only SP1's pinned verifier, only the chain's network that pairs with this one, Stellar's network by its
    ///      passphrase, a fresh NEAR anchor, and only on Ethereum.
    function test_deployNearAndStellar_refusals() public {
        ISP1Verifier sp1 = new MockSP1Verifier();
        ISP1Verifier other = ISP1Verifier(address(new MockRiscZeroVerifier()));
        uint256 named = _namedAt();
        vm.warp(named + 10 minutes);
        uint256 nearMain = script.NEAR_MAINNET();
        uint256 nearTest = script.NEAR_TESTNET();
        uint256 pubnet = script.STELLAR_PUBNET();
        uint256 testnet = script.STELLAR_TESTNET();
        bytes32 pubnetId = script.STELLAR_PUBNET_ID();
        bytes32 testnetId = script.STELLAR_TESTNET_ID();

        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotSp1Verifier.selector, address(other)));
        _deployNear(other, nearMain);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotSp1Verifier.selector, address(other)));
        _deployStellar(other, pubnetId, pubnet);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, nearTest));
        _deployNear(sp1, nearTest);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, testnet));
        _deployStellar(sp1, testnetId, testnet);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetworkId.selector, testnetId));
        _deployStellar(sp1, testnetId, pubnet);

        // On Sepolia, the testnets pair with it, and the mainnets do not.
        vm.chainId(11_155_111);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, nearMain));
        _deployNear(sp1, nearMain);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, pubnet));
        _deployStellar(sp1, pubnetId, pubnet);
        _deployNear(sp1, nearTest);
        _deployStellar(sp1, testnetId, testnet);

        vm.chainId(31_337);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotEthereum.selector, 31_337));
        _deployNear(sp1, nearMain);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotEthereum.selector, 31_337));
        _deployStellar(sp1, pubnetId, pubnet);
        vm.chainId(1);

        // A NEAR anchor named up to MAX_NEAR_ANCHOR_AGE ago, never later, never in the future.
        uint256 maxAge = script.MAX_NEAR_ANCHOR_AGE();
        vm.warp(named + maxAge);
        _deployNear(sp1, nearMain);
        vm.warp(named + maxAge + 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, named, block.timestamp));
        _deployNear(sp1, nearMain);
        vm.warp(named - 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, named, block.timestamp));
        _deployNear(sp1, nearMain);
    }

    function test_deployStateVerifierRun_readsEnvironment() public {
        vm.setEnv("STATE_CHAIN", "bnb");
        vm.setEnv("STATE_ANCHOR", "test/fixtures/bnb/anchor.json");
        vm.warp(epochTime + 10 minutes);
        address verifier = script.run();
        assertEq(BnbStateVerifier(verifier).latestEpoch(), epoch);

        vm.setEnv("STATE_CHAIN", "tron");
        vm.setEnv("STATE_ANCHOR", "test/fixtures/tron/anchor.json");
        vm.warp(nextMaintenance / 1000 - 1 hours);
        verifier = script.run();
        assertEq(TronStateVerifier(verifier).producerList(0).producersHash, keccak256(abi.encode(list)));

        vm.setEnv("STATE_SP1_VERIFIER", vm.toString(address(new MockSP1Verifier())));
        vm.setEnv("STATE_CHAIN", "near");
        vm.setEnv("STATE_ANCHOR", "test/fixtures/near/anchor.json");
        vm.warp(_namedAt() + 10 minutes);
        verifier = script.run();
        assertEq(NearStateVerifier(verifier).producersHash(), vm.parseJsonBytes32(near, ".producersHash"));

        vm.setEnv("STATE_CHAIN", "stellar");
        vm.setEnv("STATE_ANCHOR", "test/fixtures/stellar/anchor.json");
        verifier = script.run();
        assertEq(StellarStateVerifier(verifier).QUORUM_SET_HASH(), sha256(vm.parseJsonBytes(stellar, ".quorumSet")));

        vm.setEnv("STATE_CHAIN", "sui");
        vm.setEnv("STATE_ANCHOR", "test/fixtures/sui/anchor.json");
        vm.warp(_suiStart() + 10 minutes);
        verifier = script.run();
        assertEq(SuiStateVerifier(verifier).epoch(), vm.parseJsonUint(sui, ".epoch"));

        vm.setEnv("STATE_CHAIN", "injective");
        vm.setEnv("STATE_ANCHOR", "test/fixtures/injective/anchor.json");
        vm.warp(vm.parseJsonUint(injective, ".time") + 10 minutes);
        verifier = script.run();
        assertEq(CometBftStateVerifier(verifier).latestHash(), vm.parseJsonBytes32(injective, ".hash"));

        vm.setEnv("STATE_CHAIN", "vechain");
        vm.setEnv("STATE_ANCHOR", "test/fixtures/vechain/anchor.json");
        vm.warp(vm.parseJsonUint(vechain, ".time") + 10 minutes);
        verifier = script.run();
        assertEq(VeChainStateVerifier(verifier).latestId(), vm.parseJsonBytes32(vechain, ".id"));

        vm.setEnv("STATE_CHAIN", "aptos");
        vm.setEnv("STATE_ANCHOR", "test/fixtures/aptos/anchor.json");
        vm.warp(_aptosNamed() + 10 minutes);
        verifier = script.run();
        assertEq(AptosStateVerifier(verifier).latestEpoch(), vm.parseJsonUint(aptos, ".epoch"));

        vm.setEnv("STATE_CHAIN", "solana");
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.UnknownChain.selector, "solana"));
        script.run();
    }

    // ---------------------------------------------------------------------
    // Sui, Injective and VeChain
    // ---------------------------------------------------------------------

    string sui = vm.readFile("test/fixtures/sui/anchor.json");
    string injective = vm.readFile("test/fixtures/injective/anchor.json");
    string vechain = vm.readFile("test/fixtures/vechain/anchor.json");
    string aptos = vm.readFile("test/fixtures/aptos/anchor.json");

    function _aptosNamed() internal view returns (uint256) {
        return vm.parseJsonUint(aptos, ".time") / 1e6;
    }

    function _deployAptos(ISP1Verifier sp1, uint256 chainId) internal returns (AptosStateVerifier) {
        bytes32 key = vm.parseJsonBytes32(aptos, ".programKey");
        bytes32 package = vm.parseJsonBytes32(aptos, ".package");
        bytes32 vaultId = vm.parseJsonBytes32(aptos, ".vaultId");
        uint64 aptosEpoch = uint64(vm.parseJsonUint(aptos, ".epoch"));
        bytes32 set = vm.parseJsonBytes32(aptos, ".set");
        uint64 time = uint64(vm.parseJsonUint(aptos, ".time"));
        return script.deployAptos(sp1, key, chainId, package, vaultId, aptosEpoch, set, time);
    }

    /// @dev Aptos's verifier, from a real mainnet epoch's validator set, named by the epoch before's last ledger info.
    function test_deployAptos_fromARealSet() public {
        ISP1Verifier sp1 = new MockSP1Verifier();
        vm.warp(_aptosNamed() + 10 minutes);
        AptosStateVerifier verifier = _deployAptos(sp1, script.APTOS_MAINNET());
        uint64 aptosEpoch = uint64(vm.parseJsonUint(aptos, ".epoch"));
        assertEq(verifier.latestEpoch(), aptosEpoch);
        assertEq(verifier.trusted(aptosEpoch).set, vm.parseJsonBytes32(aptos, ".set"));
        assertEq(verifier.trusted(aptosEpoch).time, vm.parseJsonUint(aptos, ".time"));
        assertEq(script.APTOS_MAINNET(), uint64(bytes8(keccak256("aptos:1"))));
        assertEq(script.APTOS_TESTNET(), uint64(bytes8(keccak256("aptos:2"))));
    }

    /// @dev Only SP1's pinned verifier, only the network that pairs with this one, a set named within the age, never
    ///      in the future; and the review refuses another anchor.
    function test_deployAptos_refusalsAndReview() public {
        ISP1Verifier sp1 = new MockSP1Verifier();
        ISP1Verifier other = ISP1Verifier(address(new MockRiscZeroVerifier()));
        uint256 named = _aptosNamed();
        uint256 main = script.APTOS_MAINNET();
        uint256 test = script.APTOS_TESTNET();
        vm.warp(named + 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotSp1Verifier.selector, address(other)));
        _deployAptos(other, main);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, test));
        _deployAptos(sp1, test);
        vm.chainId(11_155_111);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, main));
        _deployAptos(sp1, main);
        _deployAptos(sp1, test);
        vm.chainId(31_337);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotEthereum.selector, 31_337));
        _deployAptos(sp1, main);
        vm.chainId(1);

        uint256 maxAge = script.MAX_APTOS_ANCHOR_AGE();
        vm.warp(named + maxAge);
        AptosStateVerifier verifier = _deployAptos(sp1, main);
        vm.warp(named + maxAge + 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, named, block.timestamp));
        _deployAptos(sp1, main);
        vm.warp(named - 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, named, block.timestamp));
        _deployAptos(sp1, main);

        uint64 aptosEpoch = uint64(vm.parseJsonUint(aptos, ".epoch"));
        bytes32 set = vm.parseJsonBytes32(aptos, ".set");
        uint64 time = uint64(vm.parseJsonUint(aptos, ".time"));
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(verifier)));
        script.checkAptos(address(verifier), aptosEpoch + 1, set, time);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(verifier)));
        script.checkAptos(address(verifier), aptosEpoch, keccak256("another set"), time);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(verifier)));
        script.checkAptos(address(verifier), aptosEpoch, set, time + 1);
    }

    function _suiStart() internal view returns (uint256) {
        return vm.parseJsonUint(sui, ".startMs") / 1000;
    }

    function _suiPowers() internal view returns (uint64[] memory powers) {
        uint256[] memory read = vm.parseJsonUintArray(sui, ".powers");
        powers = new uint64[](read.length);
        for (uint256 i = 0; i < read.length; ++i) {
            powers[i] = uint64(read[i]);
        }
    }

    function _deploySui(uint256 chainId, bytes memory suiKeys, bytes[] memory compressed, uint64[] memory powers)
        internal
        returns (SuiStateVerifier)
    {
        bytes32 vaultId = vm.parseJsonBytes32(sui, ".vaultId");
        bytes32 packageId = vm.parseJsonBytes32(sui, ".packageId");
        uint64 suiEpoch = uint64(vm.parseJsonUint(sui, ".epoch"));
        uint64 startMs = uint64(vm.parseJsonUint(sui, ".startMs"));
        return script.deploySui(chainId, vaultId, packageId, suiEpoch, suiKeys, compressed, powers, startMs);
    }

    function _deploySui(uint256 chainId) internal returns (SuiStateVerifier) {
        return
            _deploySui(
                chainId, vm.parseJsonBytes(sui, ".keys"), vm.parseJsonBytesArray(sui, ".compressed"), _suiPowers()
            );
    }

    function _deployInjective(ISP1Verifier sp1, uint256 chainId, string memory name)
        internal
        returns (CometBftStateVerifier)
    {
        bytes32 key = vm.parseJsonBytes32(injective, ".programKey");
        address vault = vm.parseJsonAddress(injective, ".vault");
        uint64 height = uint64(vm.parseJsonUint(injective, ".height"));
        bytes32 hash = vm.parseJsonBytes32(injective, ".hash");
        uint64 time = uint64(vm.parseJsonUint(injective, ".time"));
        return script.deployInjective(sp1, key, chainId, name, vault, height, hash, time);
    }

    function _deployVeChain(ISP1Verifier sp1, uint256 chainId, bytes32 id) internal returns (VeChainStateVerifier) {
        bytes32 key = vm.parseJsonBytes32(vechain, ".programKey");
        address vault = vm.parseJsonAddress(vechain, ".vault");
        address attester = vm.parseJsonAddress(vechain, ".attester");
        uint64 time = uint64(vm.parseJsonUint(vechain, ".time"));
        bytes32 table = vm.parseJsonBytes32(vechain, ".table");
        return script.deployVeChain(sp1, key, chainId, vault, attester, id, time, table);
    }

    /// @dev Sui's verifier, from a real mainnet epoch and its 127-member committee, by the hash of its keys and powers.
    function test_deploySui_fromARealCommittee() public {
        vm.warp(_suiStart() + 10 minutes);
        SuiStateVerifier verifier = _deploySui(script.SUI_MAINNET());
        bytes memory suiKeys = vm.parseJsonBytes(sui, ".keys");
        assertEq(suiKeys.length, 127 * 256);
        assertEq(verifier.committeeHash(), verifier.hashCommittee(suiKeys, _suiPowers()));
        assertEq(verifier.epoch(), vm.parseJsonUint(sui, ".epoch"));
        assertEq(verifier.epochStartMs(), vm.parseJsonUint(sui, ".startMs"));
        assertEq(verifier.CHAIN_ID(), 13_762_264_207_064_992_463, "keccak256('sui:mainnet')'s first 8 bytes");
        assertEq(verifier.VAULT_ID(), vm.parseJsonBytes32(sui, ".vaultId"));
        assertEq(verifier.PACKAGE_ID(), vm.parseJsonBytes32(sui, ".packageId"));
        assertEq(script.SUI_MAINNET(), uint64(bytes8(keccak256("sui:mainnet"))));
        assertEq(script.SUI_TESTNET(), uint64(bytes8(keccak256("sui:testnet"))));
    }

    /// @dev Injective's verifier, from a real mainnet header, and VeChain's, from a real staker table.
    function test_deployInjectiveAndVeChain_fromRealAnchors() public {
        ISP1Verifier sp1 = new MockSP1Verifier();
        vm.warp(vm.parseJsonUint(injective, ".time") + 10 minutes);
        CometBftStateVerifier inj = _deployInjective(sp1, script.INJECTIVE_MAINNET(), "injective-1");
        assertEq(inj.latestHash(), vm.parseJsonBytes32(injective, ".hash"));
        assertEq(inj.trusted(inj.latestHash()).height, vm.parseJsonUint(injective, ".height"));

        vm.warp(vm.parseJsonUint(vechain, ".time") + 10 minutes);
        bytes32 id = vm.parseJsonBytes32(vechain, ".id");
        VeChainStateVerifier vet = _deployVeChain(sp1, script.VECHAIN_MAINNET(), id);
        assertEq(vet.latestId(), id);
        assertEq(vet.trusted(id).table, vm.parseJsonBytes32(vechain, ".table"));
        assertEq(script.VECHAIN_MAINNET(), uint256(vm.parseJsonBytes32(vechain, ".chainId")), "the genesis id");
        assertEq(uint32(bytes4(id)), vm.parseJsonUint(vechain, ".number"), "a VeChain id begins with its number");
    }

    /// @dev Only Ethereum, only the networks that pair with it, only a fresh anchor, and a committee as Sui requires.
    function test_deploySui_refusals() public {
        uint256 start = _suiStart();
        vm.warp(start + 10 minutes);
        uint256 main = script.SUI_MAINNET();
        uint256 test = script.SUI_TESTNET();
        bytes memory suiKeys = vm.parseJsonBytes(sui, ".keys");
        bytes[] memory compressed = vm.parseJsonBytesArray(sui, ".compressed");
        uint64[] memory powers = _suiPowers();

        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, test));
        _deploySui(test);
        vm.chainId(11_155_111);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, main));
        _deploySui(main);
        _deploySui(test);
        vm.chainId(31_337);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotEthereum.selector, 31_337));
        _deploySui(main);
        vm.chainId(1);

        uint256 maxAge = script.MAX_SUI_ANCHOR_AGE();
        vm.warp(start + maxAge);
        _deploySui(main);
        vm.warp(start + maxAge + 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, start, block.timestamp));
        _deploySui(main);
        vm.warp(start - 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, start, block.timestamp));
        _deploySui(main);
        vm.warp(start + 10 minutes);

        // The lengths must agree, and there must be members.
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.BadCommittee.selector, 0));
        _deploySui(main, "", new bytes[](0), new uint64[](0));
        bytes[] memory short = new bytes[](compressed.length - 1);
        for (uint256 i = 0; i < short.length; ++i) {
            short[i] = compressed[i];
        }
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.BadCommittee.selector, powers.length));
        _deploySui(main, suiKeys, short, powers);
        // A compressed key that is not its uncompressed key's.
        bytes[] memory wrong = _copy(compressed);
        wrong[5] = compressed[6];
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.BadCommittee.selector, 5));
        _deploySui(main, suiKeys, wrong, powers);
        // Two members swapped: each key still matches, but the order is not Sui's.
        bytes[] memory swapped = _copy(compressed);
        (swapped[3], swapped[4]) = (compressed[4], compressed[3]);
        bytes memory swappedKeys = bytes.concat(suiKeys);
        for (uint256 b = 0; b < 256; ++b) {
            (swappedKeys[3 * 256 + b], swappedKeys[4 * 256 + b]) = (suiKeys[4 * 256 + b], suiKeys[3 * 256 + b]);
        }
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.BadCommittee.selector, 4));
        _deploySui(main, swappedKeys, swapped, powers);
        // A member named twice: each key matches, but equal is not ascending.
        bytes[] memory twice = _copy(compressed);
        twice[8] = compressed[7];
        bytes memory twiceKeys = bytes.concat(suiKeys);
        for (uint256 b = 0; b < 256; ++b) {
            twiceKeys[8 * 256 + b] = suiKeys[7 * 256 + b];
        }
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.BadCommittee.selector, 8));
        _deploySui(main, twiceKeys, twice, powers);
        // Powers that do not total 10,000.
        uint64[] memory more = new uint64[](powers.length);
        for (uint256 i = 0; i < powers.length; ++i) {
            more[i] = powers[i];
        }
        more[0] += 1;
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.BadCommittee.selector, powers.length));
        _deploySui(main, suiKeys, compressed, more);
    }

    /// @dev Only SP1's pinned verifier, only the networks that pair with this one, a fresh anchor, a real block.
    function test_deployInjectiveAndVeChain_refusals() public {
        ISP1Verifier sp1 = new MockSP1Verifier();
        ISP1Verifier other = ISP1Verifier(address(new MockRiscZeroVerifier()));
        uint256 injTime = vm.parseJsonUint(injective, ".time");
        uint256 vetTime = vm.parseJsonUint(vechain, ".time");
        bytes32 id = vm.parseJsonBytes32(vechain, ".id");
        uint256 injMain = script.INJECTIVE_MAINNET();
        uint256 injTest = script.INJECTIVE_TESTNET();
        uint256 vetMain = script.VECHAIN_MAINNET();
        uint256 vetTest = script.VECHAIN_TESTNET();

        vm.warp(injTime + 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotSp1Verifier.selector, address(other)));
        _deployInjective(other, injMain, "injective-1");
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, injTest));
        _deployInjective(sp1, injTest, "injective-1");
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongCosmosChain.selector, "injective-888"));
        _deployInjective(sp1, injMain, "injective-888");
        uint256 maxAge = script.MAX_ANCHOR_AGE();
        vm.warp(injTime + maxAge + 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, injTime, block.timestamp));
        _deployInjective(sp1, injMain, "injective-1");
        vm.warp(injTime - 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, injTime, block.timestamp));
        _deployInjective(sp1, injMain, "injective-1");

        vm.warp(vetTime + 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotSp1Verifier.selector, address(other)));
        _deployVeChain(other, vetMain, id);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, vetTest));
        _deployVeChain(sp1, vetTest, id);
        bytes32 zero = id & bytes32(uint256(type(uint224).max));
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.BadBlockId.selector, zero));
        _deployVeChain(sp1, vetMain, zero);
        uint256 vetAge = script.MAX_VECHAIN_ANCHOR_AGE();
        vm.warp(vetTime + vetAge);
        _deployVeChain(sp1, vetMain, id);
        vm.warp(vetTime + vetAge + 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, vetTime, block.timestamp));
        _deployVeChain(sp1, vetMain, id);
        vm.warp(vetTime - 1);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.StaleAnchor.selector, vetTime, block.timestamp));
        _deployVeChain(sp1, vetMain, id);

        // On Sepolia the testnets pair with it, and the mainnets do not; nowhere but Ethereum.
        vm.chainId(11_155_111);
        vm.warp(injTime + 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, injMain));
        _deployInjective(sp1, injMain, "injective-1");
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongCosmosChain.selector, "injective-1"));
        _deployInjective(sp1, injTest, "injective-1");
        _deployInjective(sp1, injTest, "injective-888");
        vm.warp(vetTime + 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongNetwork.selector, vetMain));
        _deployVeChain(sp1, vetMain, id);
        _deployVeChain(sp1, vetTest, id);
        vm.chainId(31_337);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotEthereum.selector, 31_337));
        _deployInjective(sp1, injMain, "injective-1");
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.NotEthereum.selector, 31_337));
        _deployVeChain(sp1, vetMain, id);
    }

    /// @dev The reviews refuse a verifier that holds another anchor than the file's.
    function test_checkSuiInjectiveAndVeChain_refuseAnotherAnchor() public {
        ISP1Verifier sp1 = new MockSP1Verifier();
        vm.warp(_suiStart() + 10 minutes);
        SuiStateVerifier s = _deploySui(script.SUI_MAINNET());
        uint64 suiEpoch = s.epoch();
        bytes32 committee = s.committeeHash();
        uint64 startMs = s.epochStartMs();
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(s)));
        script.checkSui(address(s), suiEpoch + 1, committee, startMs);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(s)));
        script.checkSui(address(s), suiEpoch, keccak256("another committee"), startMs);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(s)));
        script.checkSui(address(s), suiEpoch, committee, startMs + 1);

        vm.warp(vm.parseJsonUint(injective, ".time") + 10 minutes);
        CometBftStateVerifier inj = _deployInjective(sp1, script.INJECTIVE_MAINNET(), "injective-1");
        uint64 height = uint64(vm.parseJsonUint(injective, ".height"));
        bytes32 hash = vm.parseJsonBytes32(injective, ".hash");
        uint64 time = uint64(vm.parseJsonUint(injective, ".time"));
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(inj)));
        script.checkInjective(address(inj), height, keccak256("another header"), time);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(inj)));
        script.checkInjective(address(inj), height + 1, hash, time);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(inj)));
        script.checkInjective(address(inj), height, hash, time + 1);

        vm.warp(vm.parseJsonUint(vechain, ".time") + 10 minutes);
        bytes32 id = vm.parseJsonBytes32(vechain, ".id");
        VeChainStateVerifier vet = _deployVeChain(sp1, script.VECHAIN_MAINNET(), id);
        uint64 vetTime = uint64(vm.parseJsonUint(vechain, ".time"));
        bytes32 table = vm.parseJsonBytes32(vechain, ".table");
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(vet)));
        script.checkVeChain(address(vet), keccak256("another block"), vetTime, table);
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(vet)));
        script.checkVeChain(address(vet), id, vetTime, keccak256("another table"));
        vm.expectRevert(abi.encodeWithSelector(DeployStateVerifier.WrongAnchor.selector, address(vet)));
        script.checkVeChain(address(vet), id, vetTime + 1, table);
    }

    function _copy(bytes[] memory items) internal pure returns (bytes[] memory out) {
        out = new bytes[](items.length);
        for (uint256 i = 0; i < items.length; ++i) {
            out[i] = items[i];
        }
    }
}
