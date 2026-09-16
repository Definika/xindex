// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniswapV3Factory} from "../../src/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3FactorySetup} from "../interfaces/IUniswapV3FactorySetup.sol";
import {IUniswapV3PoolSetup} from "../interfaces/IUniswapV3PoolSetup.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {FaucetToken} from "./FaucetToken.sol";

/// @notice Builds a Sepolia test market for Xindex: faucet stand-ins for USDC, WBTC, LINK, UNI and AAVE, each with a
///         Uniswap V3 WETH pool at a mainnet-like price whose oracle can serve the rule's 30-minute average. Two runs,
///         from the same account, in separate blocks:
///
///   1. MARKET_MODE=create forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia \
///        --account <deployer> --broadcast
///      Deploys the tokens, creates and prices the pools, and reserves OBSERVATION_CARDINALITY oracle slots.
///   2. MARKET_MODE=seed MARKET_TOKENS=<addresses logged by create> forge script ... --broadcast
///      Adds liquidity from the deployer's ether. Being in a later block, this writes each pool's second observation,
///      which switches the pool to the reserved slots.
///
/// The Xindex factory can be deployed 30 minutes after `create`, once the pools hold that much history.
///
/// Env:
///   MARKET_MODE      `create` or `seed`.
///   MARKET_TOKENS    `seed` only: the comma-separated token addresses `create` logged, in the same order.
///   USD_POOL_WETH    `seed` only: WETH for the tUSDC pool, in wei. Default DEFAULT_USD_POOL_WETH.
///   TOKEN_POOL_WETH  `seed` only: WETH for each other pool, in wei. Default DEFAULT_TOKEN_POOL_WETH.
contract SetupTestMarket is Script {
    using SafeERC20 for IERC20;

    /// @notice A test token, its WETH pool and how the rule should see it.
    /// @param wethPerToken WETH wei per whole token at the starting price.
    /// @param supply Minted to the deployer at creation, for pool liquidity.
    /// @param dripAmount What each faucet drip mints.
    /// @param referenceSupply Supply to list the token with; zero for tUSDC, which is a currency and never listed.
    struct Spec {
        string name;
        string symbol;
        uint8 decimals;
        uint24 fee;
        uint256 wethPerToken;
        uint256 supply;
        uint256 dripAmount;
        uint256 referenceSupply;
    }

    /// @notice Uniswap V3 contracts and WETH the market is built on.
    struct Uniswap {
        address factory;
        address positionManager;
        address weth;
    }

    uint24 public constant POOL_FEE_LOW = 500;
    uint24 public constant POOL_FEE_MEDIUM = 3000;
    int24 public constant TICK_SPACING_LOW = 10;
    int24 public constant TICK_SPACING_MEDIUM = 60;
    uint8 public constant STANDARD_DECIMALS = 18;

    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    /// @dev Checked on Sepolia on 2026-09-16: the position manager's `factory()` and `WETH9()` return these, and so do
    ///      SwapRouter02 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E and QuoterV2 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3.
    address public constant SEPOLIA_UNISWAP_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address public constant SEPOLIA_POSITION_MANAGER = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address public constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    /// @notice Oracle slots each pool reserves, the rule's MIN_OBSERVATION_CARDINALITY.
    uint16 public constant OBSERVATION_CARDINALITY = 200;
    /// @notice Liquidity sits between half and double the starting price: 1.0001^6932 is just above 2.
    int24 public constant RANGE_TICKS = 6932;
    /// @notice Ether supply the WETH listing uses, as in the mainnet default whitelist.
    uint256 public constant ETH_SUPPLY = 122_050_160e18;
    uint256 public constant DEFAULT_USD_POOL_WETH = 0.3 ether;
    uint256 public constant DEFAULT_TOKEN_POOL_WETH = 0.1 ether;

    error NotSepolia(uint256 chainId);
    error UnknownMode(string mode);
    error TokenCountMismatch(uint256 expected, uint256 given);
    error UnexpectedToken(uint256 i, address token);
    error PoolMissing(address token);
    error UnsupportedFee(uint24 fee);

    /// @notice The market, tUSDC first. Prices are mainnet Uniswap time-weighted prices on 2026-09-16, rounded; the
    ///         reference supplies are the mainnet default whitelist's, and for AAVE its mainnet total supply that day.
    function specs() public pure returns (Spec[] memory list) {
        list = new Spec[](5);
        list[0] = Spec({
            name: "Xindex Test USDC",
            symbol: "tUSDC",
            decimals: 6,
            fee: POOL_FEE_LOW,
            wethPerToken: 0.0004167e18,
            supply: 1_000_000e6,
            dripAmount: 100e6,
            referenceSupply: 0
        });
        list[1] = Spec({
            name: "Xindex Test WBTC",
            symbol: "tWBTC",
            decimals: 8,
            fee: POOL_FEE_LOW,
            wethPerToken: 31.6e18,
            supply: 10e8,
            dripAmount: 0.001e8,
            referenceSupply: 20_084_784e8
        });
        list[2] = Spec({
            name: "Xindex Test LINK",
            symbol: "tLINK",
            decimals: STANDARD_DECIMALS,
            fee: POOL_FEE_MEDIUM,
            wethPerToken: 0.0045e18,
            supply: 100_000e18,
            dripAmount: 10e18,
            referenceSupply: 748_099_970e18
        });
        list[3] = Spec({
            name: "Xindex Test UNI",
            symbol: "tUNI",
            decimals: STANDARD_DECIMALS,
            fee: POOL_FEE_MEDIUM,
            wethPerToken: 0.00264e18,
            supply: 200_000e18,
            dripAmount: 20e18,
            referenceSupply: 623_212_423e18
        });
        list[4] = Spec({
            name: "Xindex Test AAVE",
            symbol: "tAAVE",
            decimals: STANDARD_DECIMALS,
            fee: POOL_FEE_MEDIUM,
            wethPerToken: 0.05e18,
            supply: 10_000e18,
            dripAmount: 1e18,
            referenceSupply: 16_000_000e18
        });
    }

    function sepoliaUniswap() public pure returns (Uniswap memory) {
        return
            Uniswap({
                factory: SEPOLIA_UNISWAP_V3_FACTORY, positionManager: SEPOLIA_POSITION_MANAGER, weth: SEPOLIA_WETH
            });
    }

    function run() external returns (address[] memory tokens) {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert NotSepolia(block.chainid);
        string memory mode = vm.envString("MARKET_MODE");
        if (_same(mode, "create")) {
            tokens = create(sepoliaUniswap());
        } else if (_same(mode, "seed")) {
            tokens = vm.envAddress("MARKET_TOKENS", ",");
            seed(
                sepoliaUniswap(),
                tokens,
                vm.envOr("USD_POOL_WETH", DEFAULT_USD_POOL_WETH),
                vm.envOr("TOKEN_POOL_WETH", DEFAULT_TOKEN_POOL_WETH)
            );
        } else {
            revert UnknownMode(mode);
        }
    }

    /// @notice Deploys every token in {specs}, creates its WETH pool at the spec price and reserves oracle slots.
    function create(Uniswap memory uniswap) public returns (address[] memory tokens) {
        Spec[] memory list = specs();
        tokens = new address[](list.length);
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            Spec memory spec = list[i];
            tokens[i] = address(new FaucetToken(spec.name, spec.symbol, spec.decimals, spec.dripAmount, spec.supply));
            address pool = IUniswapV3FactorySetup(uniswap.factory).createPool(tokens[i], uniswap.weth, spec.fee);
            IUniswapV3PoolSetup(pool)
                .initialize(sqrtPriceX96(tokens[i], uniswap.weth, spec.decimals, spec.wethPerToken));
            IUniswapV3PoolSetup(pool).increaseObservationCardinalityNext(OBSERVATION_CARDINALITY);
            console2.log(spec.symbol, tokens[i], "pool", pool);
        }
        vm.stopBroadcast();

        string memory joined = vm.toString(tokens[0]);
        for (uint256 i = 1; i < tokens.length; ++i) {
            joined = string.concat(joined, ",", vm.toString(tokens[i]));
        }
        console2.log("Next, in a later block: MARKET_MODE=seed MARKET_TOKENS=%s", joined);
    }

    /// @notice Wraps ether and adds each pool's liquidity between half and double its current price. The tUSDC pool
    ///         gets `usdPoolWeth` of WETH, every other pool `tokenPoolWeth`, each matched by up to twice that value of
    ///         the token. The positions go to msg.sender.
    function seed(Uniswap memory uniswap, address[] memory tokens, uint256 usdPoolWeth, uint256 tokenPoolWeth) public {
        Spec[] memory list = specs();
        if (tokens.length != list.length) revert TokenCountMismatch(list.length, tokens.length);
        address[] memory pools = new address[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            if (keccak256(bytes(IERC20Metadata(tokens[i]).symbol())) != keccak256(bytes(list[i].symbol))) {
                revert UnexpectedToken(i, tokens[i]);
            }
            pools[i] = IUniswapV3Factory(uniswap.factory).getPool(tokens[i], uniswap.weth, list[i].fee);
            if (pools[i] == address(0)) revert PoolMissing(tokens[i]);
        }

        vm.startBroadcast();
        // The script wraps its own ether into the WETH the caller names; tests name a mock.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        IWETH9(uniswap.weth).deposit{value: usdPoolWeth + tokenPoolWeth * (list.length - 1)}();
        for (uint256 i = 0; i < list.length; ++i) {
            uint256 wethAmount = i == 0 ? usdPoolWeth : tokenPoolWeth;
            _addLiquidity(uniswap, list[i], tokens[i], pools[i], wethAmount);
        }
        vm.stopBroadcast();

        console2.log("Deploy Xindex 30 minutes after `create` with:");
        console2.log("  USDC=%s WETH=%s", tokens[0], uniswap.weth);
        console2.log("  UNISWAP_V3_FACTORY=%s", uniswap.factory);
        console2.log("List the components with WHITELIST=%s", whitelist(tokens, uniswap.weth));
    }

    /// @notice `ConfigureWhitelist` entries for the market's components, in mainnet order: tWBTC, WETH, tLINK, tUNI,
    ///         tAAVE. tUSDC is a currency and is not listed.
    function whitelist(address[] memory tokens, address weth) public pure returns (string memory entries) {
        Spec[] memory list = specs();
        entries = _entry(tokens[1], list[1].fee, list[1].referenceSupply);
        entries = string.concat(entries, ",", _entry(weth, 0, ETH_SUPPLY));
        for (uint256 i = 2; i < list.length; ++i) {
            entries = string.concat(entries, ",", _entry(tokens[i], list[i].fee, list[i].referenceSupply));
        }
    }

    /// @notice Square root of the pool price, token1 raw units per token0 raw unit, in Q64.96, for `token` worth
    ///         `wethPerToken` WETH wei per whole token.
    function sqrtPriceX96(address token, address weth, uint8 decimals, uint256 wethPerToken)
        public
        pure
        returns (uint160)
    {
        uint256 oneToken = _wholeToken(decimals);
        uint256 priceX192 = token < weth
            ? Math.mulDiv(wethPerToken, 1 << 192, oneToken)
            : Math.mulDiv(oneToken, 1 << 192, wethPerToken);
        return SafeCast.toUint160(Math.sqrt(priceX192));
    }

    /// @notice Ticks from RANGE_TICKS below `tick` to RANGE_TICKS above it, widened to the fee tier's tick spacing.
    function rangeAround(int24 tick, uint24 fee) public pure returns (int24 lower, int24 upper) {
        int24 spacing;
        if (fee == POOL_FEE_LOW) {
            spacing = TICK_SPACING_LOW;
        } else if (fee == POOL_FEE_MEDIUM) {
            spacing = TICK_SPACING_MEDIUM;
        } else {
            revert UnsupportedFee(fee);
        }
        lower = _floorTick(tick - RANGE_TICKS, spacing);
        upper = _floorTick(tick + RANGE_TICKS, spacing);
        if (upper != tick + RANGE_TICKS) upper += spacing;
    }

    function _addLiquidity(Uniswap memory uniswap, Spec memory spec, address token, address pool, uint256 wethAmount)
        private
    {
        INonfungiblePositionManager.MintParams memory params = _mintParams(uniswap, spec, token, pool, wethAmount);
        IERC20(token)
            .forceApprove(
                uniswap.positionManager, token == params.token0 ? params.amount0Desired : params.amount1Desired
            );
        IERC20(uniswap.weth).forceApprove(uniswap.positionManager, wethAmount);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            INonfungiblePositionManager(uniswap.positionManager).mint(params);
        console2.log(spec.symbol, "position", tokenId);
        console2.log("  liquidity %s, raw amounts %s and %s", liquidity, amount0, amount1);
    }

    /// @dev A position between half and double the pool's current price, holding `wethAmount` and up to twice its value
    ///      in `token` at the spec price, owned by msg.sender.
    function _mintParams(Uniswap memory uniswap, Spec memory spec, address token, address pool, uint256 wethAmount)
        private
        view
        returns (INonfungiblePositionManager.MintParams memory params)
    {
        // Only the current tick matters here; the pool has no narrower getter for it.
        // forge-lint: disable-next-line(unused-return)
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        (params.tickLower, params.tickUpper) = rangeAround(tick, spec.fee);
        uint256 tokenAmount = Math.mulDiv(wethAmount * 2, _wholeToken(spec.decimals), spec.wethPerToken);
        bool tokenFirst = token < uniswap.weth;
        (params.token0, params.token1) = tokenFirst ? (token, uniswap.weth) : (uniswap.weth, token);
        (params.amount0Desired, params.amount1Desired) =
            tokenFirst ? (tokenAmount, wethAmount) : (wethAmount, tokenAmount);
        params.fee = spec.fee;
        params.recipient = msg.sender;
        params.deadline = block.timestamp + 1 hours;
    }

    function _entry(address token, uint24 fee, uint256 referenceSupply) private pure returns (string memory) {
        return string.concat(vm.toString(token), ":", vm.toString(fee), ":", vm.toString(referenceSupply));
    }

    function _wholeToken(uint8 decimals) private pure returns (uint256) {
        return 10 ** decimals;
    }

    /// @dev Rounds `tick` down to a multiple of `spacing`, toward negative infinity.
    function _floorTick(int24 tick, int24 spacing) private pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder < 0) remainder += spacing;
        return tick - remainder;
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
