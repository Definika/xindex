// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice A bridged token behind a beacon proxy, the way Wormhole's wrapped SOL is deployed on mainnet
///         (0xD31a59c85aE9D8edEFeC411D448f90841571b89c is a BeaconProxy). 9 decimals, like wSOL.
contract BridgedToken is ERC20Upgradeable {
    uint8 private _dec;

    function initialize(string calldata name_, string calldata symbol_, uint8 dec_) external initializer {
        __ERC20_init(name_, symbol_);
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice The implementation a bridge incident leaves behind: every call reverts. It stands for a withdrawn or
///         broken implementation behind the proxy, the case `MockPausableToken.setReadsBroken` says it models -- but
///         where the mock breaks only `balanceOf`, a real withdrawn implementation breaks `decimals()` as well.
contract WithdrawnImplementation {
    fallback() external {
        revert("implementation withdrawn");
    }
}

/// @notice DA-14 promised that a keep mask routes around a component whose reads revert, not only one whose
///         transfers do. `IndexToken` keeps that promise at settlement, but `IndexRule._snapshotMarket` still prices a
///         kept component under the capped methodology, and `_price` calls the TOKEN's own `decimals()`
///         (src/IndexRule.sol:246). A component whose implementation is withdrawn therefore makes every snapshot of a
///         capped index revert, keep mask or not, and no config change can route around it either, because
///         `checkConfig` runs the same `_price` (src/IndexRule.sol:114). The uncapped twin of the same index, with
///         the same mask, rebalances fine: the gap is specific to the capped path.
contract CappedKeepMaskBrickedTokenTest is Test {
    MockMarket market;
    IndexFactory factory;
    MockRebalanceExecutor executor;
    UpgradeableBeacon beacon;
    address wsol; // the beacon-proxied component, index 1

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address[] tokens;
    uint256[] units;

    uint256 constant WSOL_INDEX = 1;
    uint256 constant SHARES = 1_000e18;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        executor = new MockRebalanceExecutor();

        // wSOL behind a beacon, 9 decimals, owned by "the bridge".
        address bridge = makeAddr("bridge");
        BridgedToken impl = new BridgedToken();
        beacon = new UpgradeableBeacon(address(impl), bridge);
        wsol = address(
            new BeaconProxy(address(beacon), abi.encodeCall(BridgedToken.initialize, ("Wrapped SOL", "SOL", 9)))
        );

        // Launch-list shapes: WETH $4,000, wSOL $200, LINK $20, UNI $8, AAVE $280, each with its mainnet reference
        // supply (script/MainnetAddresses.sol), so the capped weights are [0.30, 0.20, 0.20, ~0.16, ~0.14].
        address weth = address(market.weth());
        address link = address(new MockERC20("ChainLink", "LINK", 18));
        address uni = address(new MockERC20("Uniswap", "UNI", 18));
        address aave = address(new MockERC20("Aave", "AAVE", 18));
        tokens = [weth, wsol, link, uni, aave];
        int256[5] memory prices = [int256(4_000e8), 200e8, 20e8, 8e8, 280e8];
        uint256[5] memory supplies =
            [uint256(122_070_499e18), 587_507_739e9, 748_099_970e18, 620_716_422e18, 15_428_841e18];
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](5);
        for (uint256 i = 0; i < 5; ++i) {
            configs[i] = market.configWith(tokens[i], prices[i], supplies[i]);
        }
        vm.startPrank(owner);
        for (uint256 i = 0; i < 5; ++i) {
            factory.proposeListing(tokens[i], configs[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < 5; ++i) {
            factory.executeListing(tokens[i]);
        }

        // $20 of each component per index token: an equal-value start, off both methodologies.
        units = [uint256(5e15), 0.1e9, 1e18, 2.5e18, 0.0714285714e18];
    }

    function _create(uint8 methodology, string memory symbol) internal returns (IndexToken idx) {
        idx = IndexToken(factory.createIndex("Launch", symbol, tokens, units, methodology));
        uint256[] memory need = idx.previewIssue(SHARES);
        for (uint256 i = 0; i < 5; ++i) {
            if (tokens[i] == wsol) BridgedToken(wsol).mint(alice, need[i]);
            else MockERC20(tokens[i]).mint(alice, need[i]);
            vm.prank(alice);
            MockERC20(tokens[i]).approve(address(idx), need[i]);
        }
        vm.prank(alice);
        idx.issue(SHARES, alice);
    }

    function test_capped_keepMaskCannotRouteAroundAComponentWhoseReadsRevert() public {
        IndexToken capped = _create(1, "CAP");
        IndexToken uncapped = _create(0, "UNC");
        vm.warp(capped.lastRebalance() + capped.MIN_REBALANCE_INTERVAL());

        // Bridge incident: the beacon is pointed at an implementation that answers nothing. Transfers AND reads now
        // revert on wSOL, exactly the DA-14 case.
        address withdrawn = address(new WithdrawnImplementation());
        vm.prank(makeAddr("bridge"));
        beacon.upgradeTo(withdrawn);
        vm.expectRevert(bytes("implementation withdrawn"));
        IERC20Metadata(wsol).balanceOf(address(capped));
        vm.expectRevert(bytes("implementation withdrawn"));
        IERC20Metadata(wsol).decimals();

        uint256 keep = 1 << WSOL_INDEX;

        // Uncapped: the guardian keeps wSOL, the rest rebalances and settles. DA-14's escape works here.
        vm.prank(guardian);
        uncapped.startRebalance(keep);
        (uint256 eta,,) = uncapped.pendingRebalance();
        vm.warp(eta);
        executor.execute(uncapped, "");
        assertEq(uncapped.rebalanceNonce(), 1, "uncapped index rebalanced around the bricked component");

        // Capped: the same mask, from the guardian or the owner, reverts inside the rule, which reads the kept
        // component's token decimals to price its market cap. The index can never rebalance while wSOL is bricked.
        vm.prank(guardian);
        vm.expectRevert(bytes("implementation withdrawn"));
        capped.startRebalance(keep);
        vm.prank(owner);
        vm.expectRevert(bytes("implementation withdrawn"));
        capped.startRebalance(keep);
        // Even the view the app/guardian would use to plan a rebalance reverts.
        vm.expectRevert(bytes("implementation withdrawn"));
        capped.previewTarget(keep);

        // No recovery through governance either: any replacement config for wSOL runs checkConfig -> _price, which
        // calls wSOL.decimals() again. (The owner cannot even switch wSOL to a feed that "knows" its decimals.)
        IIndexFactory.TokenConfig memory fresh = factory.tokenConfig(wsol);
        vm.prank(owner);
        vm.expectRevert(bytes("implementation withdrawn"));
        factory.proposeConfig(wsol, fresh);

        // A month later, and another: still frozen. Delisting does not help (the config and the component stay).
        vm.prank(guardian);
        factory.delist(wsol);
        vm.warp(block.timestamp + 60 days);
        market.setPrice(tokens[0], 5_000e8); // markets drift; the capped index can no longer follow its rule
        vm.prank(guardian);
        vm.expectRevert(bytes("implementation withdrawn"));
        capped.startRebalance(keep);
        assertEq(capped.rebalanceNonce(), 0, "capped index is frozen off its methodology");

        // Holders are not trapped: redeemSkipping still pays out the other four components.
        vm.prank(alice);
        capped.redeemSkipping(SHARES / 2, alice, keep);
        assertGt(MockERC20(tokens[0]).balanceOf(alice), 0);
    }
}
