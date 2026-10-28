// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IWeightedIndexFactory} from "xindex/src/interfaces/IWeightedIndexFactory.sol";
import {IMintRequests} from "xindex/src/interfaces/IMintRequests.sol";
import {MockERC20} from "xindex/test/mocks/MockERC20.sol";
import {KeeperExecutor} from "../src/KeeperExecutor.sol";
import {IV3SwapRouter} from "../src/interfaces/IV3SwapRouter.sol";
import {ITokenBridge} from "../src/interfaces/ITokenBridge.sol";
import {MockTokenBridge} from "./mocks/MockTokenBridge.sol";

/// @dev The executor's constructor checks its requests contract's factory; nothing else of either is called here.
contract RequestsStub {
    address public immutable FACTORY;

    constructor(address factory) {
        FACTORY = factory;
    }
}

/// @notice Drives the treasury's restocking (bridged arrivals of any size, bridging out, drawing and repaying USDC,
///         more than it drew when sales at home brought it more) and the owner's figures, any value up to the most a
///         uint256 holds, in any order, making only calls that must succeed. Each step is checked where it happens: no
///         call but the owner's raises what the keeper may deliver from stock and arrivals may still earn (RS-1), an
///         arrival earns exactly what arrived within what is left of both allowances (RS-6), and after every draw the
///         treasury holds no more USDC off the float than the owner's figure (RS-2).
contract RestockHandler is Test {
    uint16 internal constant HOME = 4;
    bytes32 internal constant SOURCE = bytes32(uint256(0x5c7));
    /// @dev The bridge's eight decimals, for an 18-decimal coin.
    uint256 internal constant UNIT = 1e10;

    KeeperExecutor internal immutable executor;
    MockTokenBridge internal immutable bridge;
    MockERC20 internal immutable usdc;
    MockERC20 internal immutable coin;
    address internal immutable owner;
    address internal immutable treasury;

    /// @notice What the keeper may deliver and arrivals may earn, as last measured: only the owner's calls raise it.
    uint256 public ceiling;
    /// @notice The most the owner ever let the treasury hold off the float.
    uint256 public maxCap;
    /// @notice Calls that went through, per path, and arrivals that met a full stock allowance.
    uint256 public redeemed;
    uint256 public bridgedOut;
    uint256 public drawn;
    uint256 public repaid;
    uint256 public filled;
    /// @dev The bridge completes each signed transfer once, so each carries its own amount.
    mapping(uint256 units => bool) internal used;

    constructor(
        KeeperExecutor executor_,
        MockTokenBridge bridge_,
        MockERC20 usdc_,
        MockERC20 coin_,
        address owner_,
        address treasury_
    ) {
        executor = executor_;
        bridge = bridge_;
        usdc = usdc_;
        coin = coin_;
        owner = owner_;
        treasury = treasury_;
        ceiling = potential();
        maxCap = executor_.treasuryUsdcCap();
    }

    /// @notice The stock allowance plus the restock allowance, at most the most a uint256 holds.
    function potential() public view returns (uint256) {
        uint256 stock = executor.stockAllowance(address(coin));
        uint256 room = executor.restockAllowance(address(coin));
        return stock > type(uint256).max - room ? type(uint256).max : stock + room;
    }

    /// @dev A signed transfer to the executor of `units` in the bridge's eight decimals and `dust` below them, which
    ///      the bridge does not carry, redeemed by the treasury.
    function redeem(uint256 units, uint256 dust) external {
        units = bound(units, 1, 1e24);
        while (used[units]) ++units;
        used[units] = true;
        uint256 amount = units * UNIT + bound(dust, 0, UNIT - 1);
        coin.mint(address(bridge), amount);
        bytes memory transfer = bridge.vm(HOME, SOURCE, address(coin), amount, address(executor));
        uint256 stock = executor.stockAllowance(address(coin));
        uint256 room = executor.restockAllowance(address(coin));
        uint256 before = potential();

        vm.prank(treasury);
        uint256 arrived = executor.redeemBridged(transfer, address(coin));

        assertEq(arrived, units * UNIT, "what arrived is what the bridge carried");
        uint256 credited = arrived < room ? arrived : room;
        if (credited > type(uint256).max - stock) {
            credited = type(uint256).max - stock;
            ++filled;
        }
        assertEq(executor.stockAllowance(address(coin)), stock + credited, "RS-6: the credit, within both allowances");
        assertEq(executor.restockAllowance(address(coin)), room - credited, "spends the restock allowance by as much");
        assertLe(potential(), before, "RS-1: an arrival raises nothing");
        ceiling = potential();
        ++redeemed;
    }

    /// @dev The treasury bridges `amount` of the executor's stock, at least one bridge unit, to the home wallet.
    function bridgeOut(uint256 amount) external {
        uint256 held = coin.balanceOf(address(executor));
        if (held < UNIT) return;
        amount = bound(amount, UNIT, held);
        uint256 before = potential();

        vm.prank(treasury);
        executor.bridgeOut(address(coin), amount, HOME);

        assertLe(executor.stockAllowance(address(coin)), coin.balanceOf(address(executor)), "capped at what is left");
        assertLe(potential(), before, "RS-1: bridging out raises nothing");
        ceiling = potential();
        ++bridgedOut;
    }

    /// @dev The treasury draws `amount`, within what it may still draw and what the float holds.
    function draw(uint256 amount) external {
        uint256 most = executor.treasuryUsdcAllowance();
        uint256 floatHeld = usdc.balanceOf(address(executor));
        if (floatHeld < most) most = floatHeld;
        if (most == 0) return;
        amount = bound(amount, 1, most);

        vm.prank(treasury);
        executor.drawUsdc(amount);

        assertLe(usdc.balanceOf(treasury), executor.treasuryUsdcCap(), "RS-2: no more held than the owner's figure");
        ++drawn;
    }

    /// @dev The treasury repays `amount`, topped up beyond what it holds by the proceeds of stock sold at home.
    function repay(uint256 amount) external {
        amount = bound(amount, 1, 1e15);
        uint256 has = usdc.balanceOf(treasury);
        if (has < amount) usdc.mint(treasury, amount - has);
        uint256 out = executor.treasuryUsdcOut();

        vm.startPrank(treasury);
        usdc.approve(address(executor), amount);
        executor.repayUsdc(amount);
        vm.stopPrank();

        assertEq(executor.treasuryUsdcOut(), amount < out ? out - amount : 0, "RS-2: what it holds falls by as much");
        ++repaid;
    }

    function setRestockAllowance(uint256 amount) external {
        vm.prank(owner);
        executor.setRestockAllowance(address(coin), amount);
        ceiling = potential();
    }

    function setStockAllowance(uint256 amount) external {
        vm.prank(owner);
        executor.setStockAllowance(address(coin), amount);
        ceiling = potential();
    }

    function setTreasuryUsdcAllowance(uint256 amount) external {
        amount = bound(amount, 0, 1e13);
        vm.prank(owner);
        executor.setTreasuryUsdcAllowance(amount);
        if (amount > maxCap) maxCap = amount;
    }
}

/// @notice Whatever the treasury and the owner do: the keeper may deliver no more than the owner allowed, restocked
///         coins included (RS-1, RS-6), and the treasury never holds more USDC off the float than the most the owner
///         ever let it (RS-2).
contract KeeperExecutorInvariantTest is Test {
    RestockHandler internal handler;
    KeeperExecutor internal executor;
    MockERC20 internal usdc;
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 coin = new MockERC20("XRP", "XRP", 18);
        MockTokenBridge bridge = new MockTokenBridge();
        bridge.setWrapped(4, bytes32(uint256(0x5c7)), address(coin));
        address factory = makeAddr("factory");
        executor = new KeeperExecutor(
            IV3SwapRouter(makeAddr("router")),
            address(usdc),
            IWeightedIndexFactory(factory),
            IMintRequests(address(new RequestsStub(factory))),
            ITokenBridge(address(bridge)),
            owner,
            makeAddr("keeper")
        );
        vm.startPrank(owner);
        executor.setTreasury(treasury);
        executor.setHomeRecipient(4, bytes32(uint256(0xbee)));
        executor.setTreasuryUsdcAllowance(1_000_000e6);
        executor.setRestockAllowance(address(coin), 1_000e18);
        vm.stopPrank();
        usdc.mint(address(executor), 10_000_000e6);

        handler = new RestockHandler(executor, bridge, usdc, coin, owner, treasury);
        targetContract(address(handler));
    }

    /// @dev RS-1: no call but the owner's raised the stock allowance and the restock allowance together.
    function invariant_RS1_theKeeperMayDeliverNoMoreThanTheOwnerAllowed() public view {
        assertLe(handler.potential(), handler.ceiling());
    }

    /// @dev RS-2: what the executor counts as held off the float covers what the treasury holds, and stays within the
    ///      most the owner ever let it hold.
    function invariant_RS2_theTreasuryHoldsNoMoreThanTheOwnersFigure() public view {
        assertLe(usdc.balanceOf(treasury), executor.treasuryUsdcOut());
        assertLe(executor.treasuryUsdcOut(), handler.maxCap());
    }

    /// @dev The campaign reaches every path the invariants are about, a full stock allowance among them.
    function test_handlerReachesEveryPath() public {
        handler.redeem(500e8, 1);
        handler.bridgeOut(100e18);
        handler.draw(600e6);
        handler.repay(900e6);
        handler.draw(type(uint256).max);
        handler.setStockAllowance(type(uint256).max - 1e18);
        handler.setRestockAllowance(type(uint256).max);
        handler.redeem(300e8, 0);
        handler.setTreasuryUsdcAllowance(0);
        handler.repay(1);
        assertEq(handler.redeemed(), 2);
        assertEq(handler.bridgedOut(), 1);
        assertEq(handler.drawn(), 2);
        assertEq(handler.repaid(), 2);
        assertEq(handler.filled(), 1, "the second arrival met the full allowance");
        assertEq(usdc.balanceOf(treasury), 1_000_000e6 - 1, "the 900 repaid covered the 600 drawn: the cap drawn anew");
        assertEq(executor.treasuryUsdcOut(), 1_000_000e6 - 1);
        assertEq(executor.treasuryUsdcAllowance(), 0, "the owner's figure lowered to zero");
    }
}
