// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {ConfigureWhitelist} from "../script/ConfigureWhitelist.s.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

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
contract ScriptsTest is Test {
    address constant MAINNET_SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    Deploy deployer;
    ConfigureWhitelist configure;
    MockSwapRouter router;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");

    function setUp() public {
        deployer = new Deploy();
        configure = new ConfigureWhitelist();
        router = new MockSwapRouter();
    }

    function _twoTokens() internal returns (address[] memory list) {
        list = new address[](2);
        list[0] = address(new MockERC20("A", "A", 18));
        list[1] = address(new MockERC20("B", "B", 8));
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

    function test_resolveRouter() public {
        vm.expectRevert(Deploy.RouterRequired.selector);
        deployer.resolveRouter(address(0));
        vm.expectRevert(abi.encodeWithSelector(Deploy.RouterHasNoCode.selector, owner));
        deployer.resolveRouter(owner);
        assertEq(deployer.resolveRouter(address(router)), address(router));

        vm.chainId(1);
        vm.etch(MAINNET_SWAP_ROUTER_02, hex"00");
        assertEq(deployer.resolveRouter(address(0)), MAINNET_SWAP_ROUTER_02);
    }

    function test_deploy() public {
        (IndexFactory factory, IndexZap zap) = deployer.deploy(owner, guardian, address(router));
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(address(zap.FACTORY()), address(factory));
        assertEq(address(zap.ROUTER()), address(router));
        assertEq(IndexToken(factory.IMPLEMENTATION()).FACTORY(), address(factory));
    }

    function test_deployRun_readsEnvironment() public {
        vm.setEnv("OWNER", vm.toString(owner));
        vm.setEnv("GUARDIAN", vm.toString(guardian));
        vm.setEnv("SWAP_ROUTER", vm.toString(address(router)));
        (IndexFactory factory, IndexZap zap) = deployer.run();
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(address(zap.ROUTER()), address(router));
    }

    // ---------------------------------------------------------------------
    // ConfigureWhitelist
    // ---------------------------------------------------------------------

    function test_resolveList() public {
        address[] memory parsed =
            configure.resolveList(string.concat(vm.toString(address(router)), ", ", vm.toString(owner)));
        assertEq(parsed.length, 2);
        assertEq(parsed[0], address(router));
        assertEq(parsed[1], owner);

        vm.expectRevert(ConfigureWhitelist.DefaultListOnlyOnMainnet.selector);
        configure.resolveList("default");

        vm.chainId(1);
        address[] memory defaults = configure.resolveList("default");
        address[] memory expected = configure.defaultMainnetList();
        assertEq(defaults.length, 5);
        for (uint256 i = 0; i < defaults.length; ++i) {
            assertEq(defaults[i], expected[i]);
        }
    }

    function test_proposeThenExecute() public {
        IndexFactory factory = new IndexFactory(DEFAULT_SENDER, address(0));
        address[] memory list = _twoTokens();

        configure.execute(factory, list); // nothing proposed yet: nothing happens
        assertEq(factory.listingEta(list[0]), 0);

        configure.propose(factory, list);
        uint256 eta = block.timestamp + factory.LISTING_DELAY();
        assertEq(factory.listingEta(list[0]), eta);
        assertEq(factory.listingEta(list[1]), eta);

        vm.warp(block.timestamp + 1 hours);
        configure.propose(factory, list); // already pending: skipped, eta unchanged
        assertEq(factory.listingEta(list[0]), eta);

        configure.execute(factory, list); // not ready yet: skipped
        assertFalse(factory.isWhitelisted(list[0]));

        vm.warp(eta);
        configure.execute(factory, list);
        assertTrue(factory.isWhitelisted(list[0]));
        assertTrue(factory.isWhitelisted(list[1]));

        configure.propose(factory, list); // already listed: skipped
        configure.execute(factory, list); // already listed: skipped
        assertEq(factory.whitelistedTokens().length, 2);
    }

    function test_execute_worksFromAnyAccount_andNeverReproposesACancelledListing() public {
        IndexFactory factory = new IndexFactory(owner, guardian); // the broadcaster is neither owner nor guardian
        address[] memory list = _twoTokens();
        vm.startPrank(owner);
        factory.proposeListing(list[0]);
        factory.proposeListing(list[1]);
        vm.stopPrank();
        vm.prank(guardian);
        factory.cancelListing(list[1]);

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        configure.execute(factory, list);

        assertTrue(factory.isWhitelisted(list[0]));
        assertFalse(factory.isWhitelisted(list[1]));
        assertEq(factory.listingEta(list[1]), 0, "a cancelled listing stays cancelled");
    }

    function test_expiredProposalsAreSkippedThenProposedAgain() public {
        IndexFactory factory = new IndexFactory(DEFAULT_SENDER, address(0));
        address[] memory list = _twoTokens();
        configure.propose(factory, list);
        uint256 eta = factory.listingEta(list[0]);

        vm.warp(eta + factory.PROPOSAL_WINDOW() + 1);
        configure.execute(factory, list); // expired: skipped
        assertFalse(factory.isWhitelisted(list[0]));

        configure.propose(factory, list); // proposed again with a fresh delay
        assertEq(factory.listingEta(list[0]), block.timestamp + factory.LISTING_DELAY());
    }

    function test_configureRun_readsEnvironment() public {
        IndexFactory factory = new IndexFactory(DEFAULT_SENDER, address(0));
        address token = address(new MockERC20("A", "A", 18));
        vm.setEnv("FACTORY", vm.toString(address(factory)));
        vm.setEnv("WHITELIST", vm.toString(token));

        vm.setEnv("LISTING_MODE", "propose");
        configure.run();
        assertEq(factory.listingEta(token), block.timestamp + factory.LISTING_DELAY());

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.setEnv("LISTING_MODE", "execute");
        configure.run();
        assertTrue(factory.isWhitelisted(token));

        vm.setEnv("LISTING_MODE", "sideways");
        vm.expectRevert(abi.encodeWithSelector(ConfigureWhitelist.UnknownMode.selector, "sideways"));
        configure.run();
    }
}
