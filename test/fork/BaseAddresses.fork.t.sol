// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../../src/WeightedHub.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {BasketBuilder} from "../../src/BasketBuilder.sol";
import {MintRequests} from "../../src/MintRequests.sol";
import {IWeightedIndexFactory} from "../../src/interfaces/IWeightedIndexFactory.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IIndexHub} from "../../src/interfaces/IIndexHub.sol";
import {IRebalanceExecutor} from "../../src/interfaces/IRebalanceExecutor.sol";
import {IUniversalRouterSwaps} from "../../src/interfaces/IUniversalRouterSwaps.sol";
import {IXindexErrors} from "../../src/interfaces/IXindexErrors.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {CheckToken} from "../../script/CheckToken.s.sol";
import {ConfigureWeighted} from "../../script/ConfigureWeighted.s.sol";
import {DeployWeighted} from "../../script/DeployWeighted.s.sol";
import {DeployChecks} from "../../script/DeployChecks.sol";
import {Listings} from "../../script/Listings.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {BnbChainAddresses} from "../../script/BnbChainAddresses.sol";
import {BaseAddresses as B} from "../../script/BaseAddresses.sol";

interface IBridgedToken {
    function remoteToken() external view returns (address);
    function bridge() external view returns (address);
}

interface IBaseRouterImmutables {
    function poolManager() external view returns (address);
}

/// @notice The guardian's Safe as the deploy checks read it: a contract that answers a threshold of two (CA-M4).
contract BaseGuardianSafe {
    function getThreshold() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Checks the scripts' `BaseAddresses` against Base, as `BnbChainAddresses.fork.t.sol` checks BNB Chain's:
///         tokens by symbol and decimals, each copy of the bridge's by the Ethereum token and the bridge it names,
///         the router, the PoolManager and Uniswap's V3 factory by their runtime code hashes, the Base list listed
///         on a fresh factory and through `CheckToken`, a whole deployment from the address book alone, and an index
///         of that deployment issued in kind, rebalanced with real transfers and redeemed, minted and burned through
///         the zap on Uniswap's real pools in USDC, ether refused, and bought and sold through `MintRequests` in
///         both stablecoins. Coinbase's ten stock tokens are precompiles of Base that this suite's EVM cannot
///         execute: every test here that runs a token leaves them out, and `BaseStocks.fork.t.sol` drives them on
///         Base's own node. Skips when BASE_RPC_URL is unset.
///         Run: BASE_RPC_URL=... forge test --match-path 'test/fork/BaseAddresses.fork.t.sol' -vvv
contract BaseAddressesForkTest is Test, IRebalanceExecutor {
    using SafeERC20 for IERC20;

    /// @dev Runtime code hashes read on Base on 2026-11-21 at block 60,490,874. The router has no proxy and its
    ///      immutables are part of its code, so the hash is the build and its wiring.
    bytes32 constant UNIVERSAL_ROUTER_CODEHASH = 0x27713951fb0660a1422b710122022d90723d883dc7b72949be79cb2957d234e0;
    bytes32 constant POOL_MANAGER_CODEHASH = 0x83b2af6e9f3158defc2811cbcb0db71ecf8b2ba2abea39c39e370ac5c6f43eb6;
    bytes32 constant UNISWAP_V3_FACTORY_CODEHASH = 0x95707a4ac71f20181a63ef7d180e3c625be5d20fc8f6f980befa966bad568132;
    /// @dev Ethereum's router and BNB Chain's, by their runtime code: the suites of those chains pin the same hashes
    ///      there, and both addresses carry that very code on Base.
    bytes32 constant ETHEREUM_ROUTER_CODEHASH = 0x6a5f46971b50c6e1b7eef97902311444e479d734e4f80ad88367783cf373fe7f;
    bytes32 constant BNB_ROUTER_CODEHASH = 0x4899c516cf2f0b82251ab88630a9b326d1a2668855c553f9f5a0ea2de993e63b;
    /// @dev Block the fork pins to; BASE_FORK_BLOCK overrides it for a non-archive RPC that only serves recent state.
    ///      The suite passed whole here on 2026-11-22.
    uint256 constant FORK_BLOCK = 60_529_140;

    uint24 constant F500 = 500;
    uint24 constant F3000 = 3000;

    // 0.001 WETH + 1 AERO + 1 VIRTUAL per index token
    uint256 constant U_WETH = 1e15;
    uint256 constant U_AERO = 1e18;
    uint256 constant U_VIRTUAL = 1e18;

    address alice = makeAddr("alice");

    function setUp() public {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "BASE_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set BASE_FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/fork/*'"
                )
            );
        }
        assertEq(block.chainid, B.CHAIN_ID, "BASE_RPC_URL is a Base node");
        // A well-known test address can carry code on a live chain; the suite is about the zap, not about its payer.
        vm.etch(alice, "");
    }

    function _assertToken(address token, string memory symbol, uint8 decimals) internal view {
        assertEq(IERC20Metadata(token).symbol(), symbol);
        assertEq(IERC20Metadata(token).decimals(), decimals);
    }

    /// @dev Every token of the address book this EVM can execute, by the symbol and decimals each answers on chain,
    ///      written out here rather than read from the list. Coinbase's ten stocks answer on Base's node alone:
    ///      `test/fork/BaseStocks.fork.t.sol` reads them there.
    function testFork_tokensAreWhatTheirNamesSay() public view {
        _assertToken(B.WETH, "WETH", 18);
        _assertToken(B.AERO, "AERO", 18);
        _assertToken(B.ZRO, "ZRO", 18);
        _assertToken(B.UNI, "UNI", 18);
        _assertToken(B.AAVE, "AAVE", 18);
        _assertToken(B.MORPHO, "MORPHO", 18);
        _assertToken(B.FET, "FET", 18);
        _assertToken(B.CRV, "CRV", 18);
        _assertToken(B.VIRTUAL, "VIRTUAL", 18);
        _assertToken(B.PENDLE, "PENDLE", 18);
        _assertToken(B.PEPE, "PEPE", 18);
        _assertToken(B.GRT, "GRT", 18);
        _assertToken(B.COMP, "COMP", 18);
        _assertToken(B.SNX, "SNX", 18);
        _assertToken(B.ONEINCH, "1INCH", 18);
        _assertToken(B.RSR, "RSR", 18);
        _assertToken(B.CBBTC, "cbBTC", 8);
        _assertToken(B.CBETH, "cbETH", 18);
        _assertToken(B.CBXRP, "cbXRP", 6);
        _assertToken(B.CBDOGE, "cbDOGE", 8);
        _assertToken(B.CBLTC, "cbLTC", 8);
        _assertToken(B.CBADA, "cbADA", 6);
        _assertToken(B.USDC, "USDC", 6);
        _assertToken(B.USDT, "USDT", 6);
    }

    /// @dev Each of the thirteen copies names, on chain, the coin of Ethereum's list it is a copy of and Base's
    ///      standard bridge as the one contract that mints and burns it. The other half of the proof, the backing the
    ///      bridge holds on Ethereum, is read there (`design/2026-11-21-base-deployment.md`). The three coins that
    ///      are no copy name no bridge of Base's.
    function testFork_everyCopyNamesItsEthereumCoinAndBasesBridge() public view {
        (address[13] memory copies, address[13] memory remotes) = B.bridged();
        for (uint256 i = 0; i < copies.length; ++i) {
            assertEq(IBridgedToken(copies[i]).remoteToken(), remotes[i], IERC20Metadata(copies[i]).symbol());
            assertEq(IBridgedToken(copies[i]).bridge(), B.STANDARD_BRIDGE, IERC20Metadata(copies[i]).symbol());
            assertTrue(Listings.tierOf(remotes[i]) != Listings.Tier.Unrecorded, "a coin Ethereum's list holds");
            assertEq(IERC20Metadata(copies[i]).decimals(), 18);
        }
        address[3] memory own = [B.WETH, B.AERO, B.ZRO];
        for (uint256 i = 0; i < own.length; ++i) {
            // A bounded call: WETH answers an unknown selector by trying to wrap, which a static call cannot.
            (bool answered, bytes memory data) =
                own[i].staticcall{gas: 100_000}(abi.encodeCall(IBridgedToken.bridge, ()));
            bool namesTheBridge = answered && data.length == 32 && abi.decode(data, (address)) == B.STANDARD_BRIDGE;
            assertFalse(namesTheBridge, "issued here, not minted by the bridge");
        }
    }

    /// @dev The list without Coinbase's ten stocks: what this EVM can execute. The stocks are precompiles of Base, and
    ///      their suite drives them on Base's node.
    function _evmList() internal pure returns (address[] memory list) {
        address[] memory all = B.all();
        list = new address[](B.COUNT - B.STOCKS);
        uint256 n = 0;
        for (uint256 i = 0; i < all.length; ++i) {
            if (!B.isStock(all[i])) list[n++] = all[i];
        }
        assertEq(n, list.length);
    }

    /// @dev Five of the six Coinbase Wrapped coins are issued on Base and name no bridge. cbETH is the copy Base's
    ///      bridge mints of Ethereum's cbETH, which is not on Ethereum's list: it names that token and the bridge.
    function testFork_theCoinbaseWrappedCoinsAreCoinbases() public view {
        assertEq(IBridgedToken(B.CBETH).remoteToken(), 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704, "Ethereum's cbETH");
        assertEq(IBridgedToken(B.CBETH).bridge(), B.STANDARD_BRIDGE);
        address[5] memory own = [B.CBBTC, B.CBXRP, B.CBDOGE, B.CBLTC, B.CBADA];
        string[5] memory names = [
            "Coinbase Wrapped BTC",
            "Coinbase Wrapped XRP",
            "Coinbase Wrapped DOGE",
            "Coinbase Wrapped LTC",
            "Coinbase Wrapped ADA"
        ];
        for (uint256 i = 0; i < own.length; ++i) {
            assertEq(IERC20Metadata(own[i]).name(), names[i]);
            (bool answered,) = own[i].staticcall{gas: 100_000}(abi.encodeCall(IBridgedToken.bridge, ()));
            assertFalse(answered, "issued here, not minted by the bridge");
            assertTrue(B.isCoinbaseWrapped(own[i]));
        }
        assertEq(IERC20Metadata(B.CBETH).name(), "Coinbase Wrapped Staked ETH");
    }

    /// @dev CR-I35 on Base: the router answers the PoolManager of the address book, and all three are the code read
    ///      on 2026-11-21.
    function testFork_CRI35_theRouterIsThePinnedBuild() public view {
        assertEq(IBaseRouterImmutables(B.UNIVERSAL_ROUTER).poolManager(), B.POOL_MANAGER);
        assertEq(B.UNIVERSAL_ROUTER.codehash, UNIVERSAL_ROUTER_CODEHASH, "Uniswap's router on Base");
        assertEq(B.POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH, "and the PoolManager it settles with");
        assertEq(B.UNISWAP_V3_FACTORY.codehash, UNISWAP_V3_FACTORY_CODEHASH, "the V3 factory is Uniswap's");
    }

    /// @dev Ethereum's router address and BNB Chain's both have code on Base: each chain's own router, byte for byte,
    ///      immutables included, so each names its own chain's PoolManager address and settles against no market
    ///      here. Until Base had an address book the deploy checks read BNB Chain's router having code as "this is BNB
    ///      Chain"; under Base's chain id they resolve Base's book, and refuse both other routers.
    function testFork_theOtherChainsRoutersHereAreReplaysThatNameNothing() public {
        assertEq(M.UNIVERSAL_ROUTER.codehash, ETHEREUM_ROUTER_CODEHASH, "Ethereum's router, replayed");
        assertEq(BnbChainAddresses.UNIVERSAL_ROUTER.codehash, BNB_ROUTER_CODEHASH, "BNB Chain's router, replayed");
        assertTrue(IBaseRouterImmutables(M.UNIVERSAL_ROUTER).poolManager() != B.POOL_MANAGER);
        assertTrue(IBaseRouterImmutables(BnbChainAddresses.UNIVERSAL_ROUTER).poolManager() != B.POOL_MANAGER);

        DeployWeighted deployer = new DeployWeighted();
        assertTrue(deployer.onBase());
        assertFalse(deployer.onBnbChain());
        assertEq(deployer.resolveRouter(address(0)), B.UNIVERSAL_ROUTER);
        assertEq(deployer.resolveStable("USDC", address(0), B.USDC), B.USDC);
        assertEq(deployer.resolveStable("USDT", address(0), B.USDT), B.USDT);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployChecks.MainnetOverride.selector, "UNIVERSAL_ROUTER", BnbChainAddresses.UNIVERSAL_ROUTER
            )
        );
        deployer.resolveRouter(BnbChainAddresses.UNIVERSAL_ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "UNIVERSAL_ROUTER", M.UNIVERSAL_ROUTER)
        );
        deployer.resolveRouter(M.UNIVERSAL_ROUTER);
    }

    /// @dev A whole deployment on Base from the book alone: a contract owner the operator acknowledges (this test,
    ///      which answers no Safe threshold, A7-08), a guardian's Safe of two signatures, which a mainnet asks for
    ///      (CA-M4), and zero for every market address.
    function _deploy()
        internal
        returns (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests)
    {
        DeployWeighted deployer = new DeployWeighted();
        (factory, zap, builder, requests) = deployer.deploy(
            address(this), address(new BaseGuardianSafe()), address(0), address(0), address(0), address(this)
        );
        deployer.checkDeployment(factory, zap, builder, requests);
    }

    function testFork_aDeploymentFromTheAddressBook() public {
        (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests) = _deploy();
        assertEq(factory.owner(), address(this));
        assertEq(address(zap.ROUTER()), B.UNIVERSAL_ROUTER);
        assertEq(zap.POOL_MANAGER(), B.POOL_MANAGER);
        assertEq(zap.USDC(), B.USDC, "the zap takes and pays Base's two stablecoins");
        assertEq(zap.USDT(), B.USDT);
        assertEq(address(builder.ROUTER()), B.UNIVERSAL_ROUTER);
        assertEq(builder.USDC(), B.USDC);
        assertEq(builder.USDT(), B.USDT);
        assertEq(requests.USDC(), B.USDC);
        assertEq(requests.USDT(), B.USDT);
    }

    /// @dev Lists `tokens` on `factory`, whose owner is this test.
    function _list(WeightedIndexFactory factory, address[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; ++i) {
            factory.proposeListing(tokens[i]);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < tokens.length; ++i) {
            factory.executeListing(tokens[i]);
        }
    }

    function _params() internal pure returns (IWeightedIndexFactory.IndexParams memory) {
        return IWeightedIndexFactory.IndexParams({
            creatorFeeBps: 0,
            creatorStreamingBps: 0,
            maxPlatformFeeBps: 25,
            maxPlatformStreamingBps: 100,
            rebalanceInterval: 7 days,
            gated: false,
            listed: true
        });
    }

    /// @dev Every entry of the Base list this EVM can execute, listed on a fresh factory, which records each token's
    ///      on-chain decimals. The list the listing script builds is these and the ten stocks, which their own suite
    ///      lists on Base's node.
    function testFork_theBaseListMatchesTheChain() public {
        assertEq(new ConfigureWeighted().resolveList("base").length, B.COUNT);
        address[] memory list = _evmList();
        WeightedIndexFactory factory = new WeightedIndexFactory(address(this), address(0));
        _list(factory, list);
        for (uint256 i = 0; i < list.length; ++i) {
            assertTrue(factory.isWhitelisted(list[i]));
            assertEq(factory.decimalsOf(list[i]), IERC20Metadata(list[i]).decimals());
        }
    }

    /// @dev Every coin of the Base list this EVM can execute passes `CheckToken` as listable, its transfers exact,
    ///      with its powers recorded for the signers. WETH has none and AERO its Minter's mint. A copy of the bridge's
    ///      can be minted, and burned out of any holder's balance, by the bridge alone, which is how a withdrawal to
    ///      Ethereum works and what trusting the bridge means; none has an owner but MORPHO's, a proxy its issuer's
    ///      Safe upgrades. Each of the five Coinbase Wrapped coins issued here is a proxy one key upgrades, with a
    ///      mint, a pause and a blocklist. The ten stocks come out for review, unread: precompiles of Base.
    function testFork_everyBaseTokenPassesTheCheck() public {
        CheckToken checker = new CheckToken();
        address[] memory list = new ConfigureWeighted().baseList();
        for (uint256 i = 0; i < list.length; ++i) {
            CheckToken.Report memory r = checker.check(list[i], address(0), checker.markets());
            checker.log(r);
            if (B.isStock(list[i])) {
                assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Review), "a precompile is not judged here");
                assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Untested));
                continue;
            }
            assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact), r.symbol);
            assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Listable), r.symbol);
            if (B.isCoinbaseWrapped(list[i]) && list[i] != B.CBETH) {
                uint256 coinbases = checker.MINT() | checker.PAUSE() | checker.BLACKLIST() | checker.UPGRADE();
                assertEq(r.powers & coinbases, coinbases, "Coinbase mints, pauses, blocks an address and upgrades");
                assertEq(r.powers & checker.DESTROY(), 0, "and destroys no holder's balance");
                assertEq(uint8(r.admin.kind), uint8(CheckToken.Kind.Key), "one key upgrades it");
                assertEq(uint8(r.owner.kind), uint8(CheckToken.Kind.Key), "and another owns it");
            }
            if (B.remoteOf(list[i]) != address(0)) {
                assertEq(r.powers & checker.MINT(), checker.MINT(), "the bridge mints a copy");
                if (list[i] != B.MORPHO) assertEq(r.implementation, address(0), "and no key can replace its code");
            }
        }
        CheckToken.Report memory weth = checker.check(B.WETH, address(0), checker.markets());
        assertEq(weth.powers, 0, "WETH has no power over a holder");
        CheckToken.Report memory morpho = checker.check(B.MORPHO, address(0), checker.markets());
        assertEq(morpho.powers & checker.UPGRADE(), checker.UPGRADE());
        assertEq(uint8(morpho.owner.kind), uint8(CheckToken.Kind.Safe), "MORPHO is upgraded through a Safe");
    }

    /// @dev An index of every coin of the Base list this EVM can execute, on a deployment from the book, the coins
    ///      weighted alike.
    function _wholeListIndex() internal returns (WeightedHub index, address[] memory list) {
        (WeightedIndexFactory factory,,,) = _deploy();
        list = _evmList();
        _list(factory, list);
        factory.setApprovedCreator(address(this), true);
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            // 22 coins: 455 for each of the first twelve and 454 for each other is 10,000. A thousandth of a coin of
            // 18 decimals a share, and 1e5 raw units of the Coinbase Wrapped coins, of 6 or 8.
            specs[i] = IWeightedIndexFactory.ComponentSpec({
                token: list[i], weight: i < 12 ? 455 : 454, units: IERC20Metadata(list[i]).decimals() == 18 ? 1e15 : 1e5
            });
        }
        index = WeightedHub(factory.createIndex("Base Twenty-Two", "BASE22", specs, _params()));
    }

    /// @dev Issues `shares` of `index` to `to` from coins dealt to it. Returns what the index took of each.
    function _issueInKind(WeightedHub index, address to, uint256 shares) internal returns (uint256[] memory need) {
        address[] memory tokens = index.componentTokens();
        need = index.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(tokens[i], to, need[i]);
            vm.prank(to);
            IERC20(tokens[i]).forceApprove(address(index), need[i]);
        }
        vm.prank(to);
        index.issue(shares, to);
    }

    /// @dev The executor's callback, which this test answers as the rebalance's executor: it pays the index what it
    ///      asks from its own balance.
    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory tokens = IIndexHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsIn[i] != 0) IERC20(tokens[i]).safeTransfer(msg.sender, amountsIn[i]);
        }
    }

    /// @dev An index of the whole Base list issues in kind, which probes that the index can send each coin (RW-8),
    ///      rebalances with real transfers, WETH leaving and each of the other twenty-one coins coming in, so every real
    ///      balance is read by the post-check, and the holder then leaves in kind at the new units.
    function testFork_anIndexOfTheWholeListIssuesRebalancesAndRedeemsInKind() public {
        (WeightedHub index, address[] memory list) = _wholeListIndex();
        uint256 shares = 100e18;
        uint256[] memory taken = _issueInKind(index, alice, shares);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(IERC20(list[i]).balanceOf(address(index)), taken[i], "the index holds every coin in kind");
        }

        _rebalanceWithRealTransfers(index, list);

        uint256[] memory back = index.previewRedeem(shares);
        vm.prank(alice);
        index.redeem(shares, alice);
        assertEq(index.totalSupply(), 0);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(IERC20(list[i]).balanceOf(alice), back[i], "the holder leaves in kind at the new units");
            assertGt(back[i], 0);
        }
    }

    /// @dev Starts a rebalance of `index`, names a tenth less WETH and a twentieth more of every other coin, and
    ///      fills it from this test's own balance: every balance moves by exactly the previewed amount.
    function _rebalanceWithRealTransfers(WeightedHub index, address[] memory list) internal {
        vm.warp(index.earliestRebalance() + 1);
        index.startRebalance(0);
        uint256[] memory newUnits = index.recordedUnits();
        newUnits[0] = newUnits[0] * 9 / 10;
        for (uint256 i = 1; i < list.length; ++i) {
            newUnits[i] = newUnits[i] * 21 / 20;
        }
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + 2 hours);
        uint256[] memory amountsOut;
        uint256[] memory amountsIn;
        {
            (uint256 bar, int256 gain, uint256[] memory out, uint256[] memory needed) = index.previewRebalance(newUnits);
            assertGt(bar, 0);
            assertGe(gain, int256(bar));
            (amountsOut, amountsIn) = (out, needed);
        }
        assertGt(amountsOut[0], 0, "WETH leaves");

        uint256[] memory held = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            held[i] = IERC20(list[i]).balanceOf(address(index));
            if (i != 0) {
                assertGt(amountsIn[i], 0, "every other coin comes in");
                deal(list[i], address(this), amountsIn[i]);
            }
        }
        uint256 wethBefore = IERC20(B.WETH).balanceOf(address(this));
        index.executeRebalance(newUnits, "");
        assertEq(IERC20(B.WETH).balanceOf(address(this)) - wethBefore, amountsOut[0], "the executor is paid in WETH");
        uint256[] memory units = index.recordedUnits();
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(units[i], newUnits[i], "the units are the ones named");
            assertEq(IERC20(list[i]).balanceOf(address(index)), held[i] + amountsIn[i] - amountsOut[i]);
        }
    }

    /// @dev An index of WETH, AERO and VIRTUAL on `factory`, three coins Uniswap routes on Base.
    function _three(WeightedIndexFactory factory) internal returns (WeightedHub index) {
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (B.WETH, B.AERO, B.VIRTUAL);
        _list(factory, three);
        factory.setApprovedCreator(address(this), true);
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](3);
        specs[0] = IWeightedIndexFactory.ComponentSpec({token: B.WETH, weight: 3334, units: U_WETH});
        specs[1] = IWeightedIndexFactory.ComponentSpec({token: B.AERO, weight: 3333, units: U_AERO});
        specs[2] = IWeightedIndexFactory.ComponentSpec({token: B.VIRTUAL, weight: 3333, units: U_VIRTUAL});
        index = WeightedHub(factory.createIndex("Base Three", "BASE3", specs, _params()));
    }

    /// @dev `MintRequests` on Base's deployment in each of its two stablecoins, six decimals each: a mint request
    ///      escrows the stablecoin and a filler's shares fill it, a redemption request escrows the shares and the
    ///      filler's stablecoin fills it, and a cancelled request returns its escrow. Every amount lands whole:
    ///      neither stablecoin charges a fee on transfer at this block.
    function testFork_requestsEscrowAndFillInBothStablecoins() public {
        (WeightedIndexFactory factory,,, MintRequests requests) = _deploy();
        WeightedHub index = _three(factory);
        address filler = makeAddr("filler");
        vm.etch(filler, "");
        uint256 shares = 1e18;
        uint256 pay = 500e6;
        _issueInKind(index, filler, shares);
        uint256 nonce = index.rebalanceNonce();

        address[2] memory stables = [B.USDC, B.USDT];
        for (uint256 s = 0; s < stables.length; ++s) {
            IERC20 stable = IERC20(stables[s]);
            deal(address(stable), alice, pay);
            deal(address(stable), filler, 0);
            uint256 deadline = block.timestamp + 1 days;

            vm.startPrank(alice);
            stable.forceApprove(address(requests), pay);
            uint256 id = requests.requestMint(address(index), address(stable), pay, shares, deadline, nonce);
            vm.stopPrank();
            assertEq(stable.balanceOf(address(requests)), pay, "the escrow is the whole amount");
            assertEq(requests.totalEscrow(address(stable)), pay);

            vm.startPrank(filler);
            index.approve(address(requests), shares);
            requests.fill(id, shares);
            vm.stopPrank();
            assertEq(index.balanceOf(alice), shares, "the requester has the shares");
            assertEq(stable.balanceOf(filler), pay, "and the filler the escrow");

            vm.startPrank(alice);
            index.approve(address(requests), shares);
            id = requests.requestRedeem(address(index), shares, address(stable), pay, deadline, nonce);
            vm.stopPrank();
            vm.startPrank(filler);
            stable.forceApprove(address(requests), pay);
            requests.fill(id, pay);
            vm.stopPrank();
            assertEq(stable.balanceOf(alice), pay, "the requester is paid its limit in full");
            assertEq(index.balanceOf(filler), shares, "and the filler has the shares back");

            vm.startPrank(alice);
            stable.forceApprove(address(requests), pay);
            id = requests.requestMint(address(index), address(stable), pay, shares, deadline, nonce);
            requests.cancel(id);
            vm.stopPrank();
            assertEq(stable.balanceOf(alice), pay, "a cancelled request returns its escrow whole");
            assertEq(stable.balanceOf(address(requests)), 0);
            assertEq(requests.totalEscrow(address(stable)), 0);
        }
    }

    function _mintLegs(bytes[3] memory paths) internal pure returns (IUniversalRouterSwaps.MintLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.MintLeg[](3);
        for (uint256 i = 0; i < 3; ++i) {
            legs[i] = IUniversalRouterSwaps.MintLeg({v3Path: paths[i], v4Path: new PathKey[](0), maxAmountIn: 0});
        }
    }

    function _burnLegs(bytes[3] memory paths) internal pure returns (IUniversalRouterSwaps.BurnLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.BurnLeg[](3);
        for (uint256 i = 0; i < 3; ++i) {
            legs[i] = IUniversalRouterSwaps.BurnLeg({v3Path: paths[i], v4Path: new PathKey[](0), minAmountOut: 0});
        }
    }

    /// @dev The zap mints an index of Base's deployment from USDC alone and burns it back to USDC, through Base's
    ///      Universal Router and Uniswap's real V3 pools, two of the three legs along two hops through WETH: the
    ///      command inputs the zap encodes for Ethereum's router hold on Base's, and the index receives every coin in
    ///      kind. The round trip costs the pools' fees and nothing else.
    function testFork_theZapMintsAndBurnsInUsdcThroughUniswap() public {
        (WeightedIndexFactory factory, IndexZap zap,,) = _deploy();
        WeightedHub index = _three(factory);
        uint256 shares = 10e18;
        uint256 budget = 1_000e6;
        deal(B.USDC, alice, budget);

        // Exact-output paths run from the component back to what the user pays with.
        bytes[3] memory mintPaths = [
            abi.encodePacked(B.WETH, F500, B.USDC),
            abi.encodePacked(B.AERO, F3000, B.WETH, F500, B.USDC),
            abi.encodePacked(B.VIRTUAL, F500, B.WETH, F500, B.USDC)
        ];
        vm.startPrank(alice);
        IERC20(B.USDC).forceApprove(address(zap), budget);
        uint256 spent = zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(index),
                expectedNonce: 0,
                tokenIn: B.USDC,
                maxAmountIn: budget,
                shares: shares,
                legs: _mintLegs(mintPaths),
                to: alice,
                deadline: block.timestamp,
                referrer: address(0)
            })
        );
        vm.stopPrank();
        assertEq(index.balanceOf(alice), shares);
        assertGt(spent, 0);
        assertEq(IERC20(B.USDC).balanceOf(alice), budget - spent, "what the swaps did not take came back");
        assertEq(IERC20(B.WETH).balanceOf(address(index)), shares * U_WETH / 1e18, "the index holds ether in kind");
        assertEq(IERC20(B.AERO).balanceOf(address(index)), shares * U_AERO / 1e18);
        assertEq(IERC20(B.VIRTUAL).balanceOf(address(index)), shares * U_VIRTUAL / 1e18);
        assertEq(IERC20(B.USDC).balanceOf(address(zap)), 0, "nothing stays in the zap");

        // Exact-input paths run from the component to what the user is paid in.
        bytes[3] memory burnPaths = [
            abi.encodePacked(B.WETH, F500, B.USDC),
            abi.encodePacked(B.AERO, F3000, B.WETH, F500, B.USDC),
            abi.encodePacked(B.VIRTUAL, F500, B.WETH, F500, B.USDC)
        ];
        vm.startPrank(alice);
        index.approve(address(zap), shares);
        uint256 out = zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(index),
                expectedNonce: 0,
                shares: shares,
                tokenOut: B.USDC,
                minAmountOut: spent * 97 / 100,
                legs: _burnLegs(burnPaths),
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertEq(index.totalSupply(), 0);
        assertEq(IERC20(B.USDC).balanceOf(alice), budget - spent + out);
        assertGe(out, spent * 97 / 100, "the zap held the burn to its floor: a round trip loses under 3%");
        assertLt(out, spent, "and gains nothing");
    }

    /// @dev The zap takes and pays only Base's USDC and USDT: a mint paid in WETH is refused before anything moves,
    ///      and no entry point takes ether.
    function testFork_theZapRefusesEther() public {
        (WeightedIndexFactory factory, IndexZap zap,,) = _deploy();
        WeightedHub index = _three(factory);
        bytes[3] memory paths =
            [bytes(""), abi.encodePacked(B.AERO, F3000, B.WETH), abi.encodePacked(B.VIRTUAL, F500, B.WETH)];
        deal(B.WETH, alice, 1 ether);
        vm.startPrank(alice);
        IERC20(B.WETH).forceApprove(address(zap), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotAStable.selector, B.WETH));
        zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(index),
                expectedNonce: 0,
                tokenIn: B.WETH,
                maxAmountIn: 1 ether,
                shares: 1e18,
                legs: _mintLegs(paths),
                to: alice,
                deadline: block.timestamp,
                referrer: address(0)
            })
        );
        vm.stopPrank();
        (bool sent,) = address(zap).call{value: 1}("");
        assertFalse(sent, "the zap takes no ether");
    }
}
