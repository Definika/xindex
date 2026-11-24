// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWeightedIndexFactory} from "xindex/src/interfaces/IWeightedIndexFactory.sol";
import {IMintRequests} from "xindex/src/interfaces/IMintRequests.sol";
import {WeightedIndexFactory} from "xindex/src/WeightedIndexFactory.sol";
import {WeightedMath} from "xindex/src/WeightedMath.sol";
import {MintRequests} from "xindex/src/MintRequests.sol";
import {BnbChainAddresses as B} from "xindex/script/BnbChainAddresses.sol";
import {BaseAddresses as C} from "xindex/script/BaseAddresses.sol";
import {KeeperExecutor} from "../src/KeeperExecutor.sol";
import {ITokenBridge} from "../src/interfaces/ITokenBridge.sol";
import {IV3SwapRouter} from "../src/interfaces/IV3SwapRouter.sol";

interface IV3FactoryView {
    function getPool(address, address, uint24) external view returns (address);
}

interface IPeripheryView {
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

interface ITokenBridgeChain {
    function chainId() external view returns (uint16);
}

interface IHubIssue {
    function balanceOf(address) external view returns (uint256);
    function previewIssue(uint256 shares) external view returns (uint256[] memory);
}

/// @dev The keeper's executor on BNB Chain and on Base, at a block of the chain's own (BNB_RPC_URL and BNB_FORK_BLOCK,
///      BASE_RPC_URL and BASE_FORK_BLOCK, as the root's fork suites; the head when the block is unset; skipped when
///      the URL is). Each chain's suite deploys the executor on the market the bot's chain table names
///      (`keeper/bot/config.mjs`, which it reads to check that every address there is the one used here), and fills
///      a real mint request by buying a two-coin basket through Uniswap V3 with that chain's USDC: eighteen decimals on
///      BNB Chain. The factory here has no oracle: a request fill reads no price, and the oracle's path is the root's.
abstract contract ChainForkTest is Test {
    address internal execOwner = makeAddr("execOwner");
    address internal keeper = makeAddr("keeper");
    address internal requester = makeAddr("requester");
    address internal creator = makeAddr("creator");

    WeightedIndexFactory internal factory;
    MintRequests internal requests;
    KeeperExecutor internal executor;
    address internal index;
    uint256 internal unit; // one dollar in the float's raw units

    // The chain, as the bot's table names it.
    function _rpcVar() internal pure virtual returns (string memory);
    function _blockVar() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);
    function _router() internal pure virtual returns (address);
    function _quoter() internal pure virtual returns (address);
    function _v3Factory() internal pure virtual returns (address);
    function _hub() internal pure virtual returns (address);
    function _usdc() internal pure virtual returns (address);
    function _usdt() internal pure virtual returns (address);
    function _bridge() internal pure virtual returns (address);
    function _wormholeId() internal pure virtual returns (uint16);
    function _pyth() internal pure virtual returns (address);
    function _usdcDecimals() internal pure virtual returns (uint8);
    /// @dev Two listed coins and each one's units per share, worth a few dollars a share.
    function _basket() internal pure virtual returns (address[2] memory coins, uint256[2] memory units);

    function setUp() public {
        string memory url = vm.envOr(_rpcVar(), string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr(_blockVar(), uint256(0));
        if (forkBlock == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, forkBlock);
        assertEq(block.chainid, _chainId(), "the RPC serves the chain this suite is for");
        unit = 10 ** _usdcDecimals();

        factory = new WeightedIndexFactory(execOwner, makeAddr("guardian"), address(0), address(new WeightedMath()));
        requests = new MintRequests(address(factory), _usdc(), _usdt());
        executor = new KeeperExecutor(
            IV3SwapRouter(_router()),
            _usdc(),
            IWeightedIndexFactory(address(factory)),
            IMintRequests(address(requests)),
            ITokenBridge(_bridge()),
            execOwner,
            keeper
        );

        (address[2] memory coins, uint256[2] memory units) = _basket();
        vm.startPrank(execOwner);
        for (uint256 i = 0; i < 2; ++i) {
            factory.proposeListing(coins[i]);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY() + 1);
        for (uint256 i = 0; i < 2; ++i) {
            factory.executeListing(coins[i]);
        }
        factory.setApprovedCreator(creator, true);
        executor.setRequestUsdcAllowance(type(uint256).max);
        vm.stopPrank();

        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        for (uint256 i = 0; i < 2; ++i) {
            specs[i] = IWeightedIndexFactory.ComponentSpec({token: coins[i], weight: 5000, units: units[i]});
        }
        IWeightedIndexFactory.IndexParams memory params = IWeightedIndexFactory.IndexParams({
            creatorFeeBps: 0,
            creatorStreamingBps: 0,
            maxPlatformFeeBps: 25,
            maxPlatformStreamingBps: 100,
            rebalanceInterval: 7 days,
            gated: false,
            listed: true
        });
        vm.prank(creator);
        index = factory.createIndex("Chain", "CHN", specs, params);
        deal(_usdc(), address(executor), 1000 * unit);
    }

    /// @dev Every address this suite deploys on is the one the bot's chain table names, and each answers as the
    ///      chain's: the router and the quoter with the address book's Uniswap V3 factory and the wrapped gas coin,
    ///      the bridge with Wormhole's id for the chain, the float with the decimals the table states.
    function testFork_theChainTableIsTheChains() public view {
        string memory table = vm.readFile("./bot/config.mjs");
        address[6] memory named = [_router(), _quoter(), _v3Factory(), _usdc(), _bridge(), _pyth()];
        for (uint256 i = 0; i < named.length; ++i) {
            assertTrue(vm.indexOf(table, vm.toString(named[i])) != type(uint256).max, "the bot's table names it");
            assertGt(named[i].code.length, 0, "and it has code here");
        }
        assertEq(IPeripheryView(_router()).factory(), _v3Factory());
        assertEq(IPeripheryView(_router()).WETH9(), _hub());
        assertEq(IPeripheryView(_quoter()).factory(), _v3Factory());
        assertEq(IPeripheryView(_quoter()).WETH9(), _hub());
        assertEq(ITokenBridgeChain(_bridge()).chainId(), _wormholeId());
        assertEq(IERC20Metadata(_usdc()).decimals(), _usdcDecimals());
        assertEq(address(executor.ROUTER()), _router());
        assertEq(executor.USDC(), _usdc());
        assertEq(
            IERC20(_usdc()).allowance(address(executor), _router()), type(uint256).max, "the router may spend the float"
        );
    }

    /// @dev A mint request in the chain's USDC, filled by the keeper through Uniswap V3: the basket bought along the
    ///      deepest pool of each coin, the shares issued to the requester, the escrow into the float.
    function testFork_aMintRequestIsFilledThroughUniswap() public {
        uint256 escrow = 100 * unit;
        deal(_usdc(), requester, escrow);
        vm.startPrank(requester);
        IERC20(_usdc()).approve(address(requests), escrow);
        uint256 id = requests.requestMint(index, _usdc(), escrow, 1e18, block.timestamp + 1 days);
        vm.stopPrank();

        (address[2] memory coins,) = _basket();
        bytes[] memory routes = new bytes[](2);
        for (uint256 i = 0; i < 2; ++i) {
            routes[i] = _route(coins[i]);
        }
        KeeperExecutor.RequestFill memory f = KeeperExecutor.RequestFill({
            id: id,
            amount: 1e18,
            routes: routes,
            legLimits: new uint256[](0),
            stableRoute: "",
            stableLimit: 0,
            expectedNonce: 0,
            expected: requests.requestHash(id),
            minUsdcDelta: type(int256).min,
            deadline: block.timestamp
        });
        uint256 floatBefore = IERC20(_usdc()).balanceOf(address(executor));
        vm.prank(keeper);
        (int256 usdcDelta,) = executor.fillMint(f);

        assertEq(IHubIssue(index).balanceOf(requester), 1e18, "the requester holds the share it asked for");
        uint256 floatAfter = IERC20(_usdc()).balanceOf(address(executor));
        assertEq(int256(floatAfter) - int256(floatBefore), usdcDelta, "the float moved by what the fill reports");
        assertGt(usdcDelta, 0, "the escrow paid for the basket");
        assertLt(uint256(usdcDelta), escrow, "and the basket cost something: it was bought");
        uint256[] memory need = IHubIssue(index).previewIssue(1e18);
        for (uint256 i = 0; i < 2; ++i) {
            assertGe(IERC20(coins[i]).balanceOf(index), need[i], "the index holds the share's basket");
            assertEq(IERC20(coins[i]).balanceOf(address(executor)), 0, "and the executor keeps none of it");
        }
    }

    /// @dev The deepest Uniswap V3 pool of `token` against the float, by the float it holds, or, when no direct pool
    ///      holds a thousand dollars, the deepest path through the wrapped gas coin: an exact-input path from the coin
    ///      to the float, which read as an exact-output path buys the coin (the bot's own route rule).
    function _route(address token) internal view returns (bytes memory) {
        (uint24 fee, uint256 depth) = _deepest(token, _usdc());
        if (depth >= 1000 * unit || token == _hub()) {
            require(depth > 0, "no pool against the float");
            return abi.encodePacked(token, fee, _usdc());
        }
        (uint24 toHub, uint256 hubDepth) = _deepest(token, _hub());
        (uint24 hubToUsdc,) = _deepest(_hub(), _usdc());
        require(hubDepth > 0, "no pool against the wrapped gas coin");
        return abi.encodePacked(token, toHub, _hub(), hubToUsdc, _usdc());
    }

    function _deepest(address token, address quote) internal view returns (uint24 best, uint256 depth) {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        for (uint256 i = 0; i < fees.length; ++i) {
            address pool = IV3FactoryView(_v3Factory()).getPool(token, quote, fees[i]);
            if (pool == address(0)) continue;
            uint256 held = IERC20(quote).balanceOf(pool);
            if (held > depth) (best, depth) = (fees[i], held);
        }
    }
}

/// @dev BNB Chain: a basket of WBNB and Binance-Peg ETH, bought with Binance-Peg USDC, eighteen decimals.
contract KeeperExecutorBnbChainForkTest is ChainForkTest {
    function _rpcVar() internal pure override returns (string memory) {
        return "BNB_RPC_URL";
    }

    function _blockVar() internal pure override returns (string memory) {
        return "BNB_FORK_BLOCK";
    }

    function _chainId() internal pure override returns (uint256) {
        return B.CHAIN_ID;
    }

    function _router() internal pure override returns (address) {
        return 0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2;
    }

    function _quoter() internal pure override returns (address) {
        return 0x78D78E420Da98ad378D7799bE8f4AF69033EB077;
    }

    function _v3Factory() internal pure override returns (address) {
        return B.UNISWAP_V3_FACTORY;
    }

    function _hub() internal pure override returns (address) {
        return B.WBNB;
    }

    function _usdc() internal pure override returns (address) {
        return B.USDC;
    }

    function _usdt() internal pure override returns (address) {
        return B.USDT;
    }

    function _bridge() internal pure override returns (address) {
        return 0xB6F6D86a8f9879A9c87f643768d9efc38c1Da6E7;
    }

    function _wormholeId() internal pure override returns (uint16) {
        return 4;
    }

    function _pyth() internal pure override returns (address) {
        return B.PYTH;
    }

    function _usdcDecimals() internal pure override returns (uint8) {
        return 18;
    }

    function _basket() internal pure override returns (address[2] memory coins, uint256[2] memory units) {
        coins = [B.WBNB, B.ETH];
        units = [uint256(5e15), uint256(1e15)];
    }
}

/// @dev Base: a basket of WETH and cbBTC, bought with USDC, six decimals.
contract KeeperExecutorBaseForkTest is ChainForkTest {
    function _rpcVar() internal pure override returns (string memory) {
        return "BASE_RPC_URL";
    }

    function _blockVar() internal pure override returns (string memory) {
        return "BASE_FORK_BLOCK";
    }

    function _chainId() internal pure override returns (uint256) {
        return C.CHAIN_ID;
    }

    function _router() internal pure override returns (address) {
        return 0x2626664c2603336E57B271c5C0b26F421741e481;
    }

    function _quoter() internal pure override returns (address) {
        return 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    }

    function _v3Factory() internal pure override returns (address) {
        return C.UNISWAP_V3_FACTORY;
    }

    function _hub() internal pure override returns (address) {
        return C.WETH;
    }

    function _usdc() internal pure override returns (address) {
        return C.USDC;
    }

    function _usdt() internal pure override returns (address) {
        return C.USDT;
    }

    function _bridge() internal pure override returns (address) {
        return 0x8d2de8d2f73F1F4cAB472AC9A881C9b123C79627;
    }

    function _wormholeId() internal pure override returns (uint16) {
        return 30;
    }

    function _pyth() internal pure override returns (address) {
        return C.PYTH;
    }

    function _usdcDecimals() internal pure override returns (uint8) {
        return 6;
    }

    function _basket() internal pure override returns (address[2] memory coins, uint256[2] memory units) {
        coins = [C.WETH, C.CBBTC];
        units = [uint256(1e15), uint256(1e4)];
    }
}
