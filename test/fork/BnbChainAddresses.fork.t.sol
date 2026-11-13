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
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {CheckToken} from "../../script/CheckToken.s.sol";
import {ConfigureWeighted} from "../../script/ConfigureWeighted.s.sol";
import {DeployWeighted} from "../../script/DeployWeighted.s.sol";
import {DeployChecks} from "../../script/DeployChecks.sol";
import {Listings} from "../../script/Listings.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {BnbChainAddresses as B} from "../../script/BnbChainAddresses.sol";

interface IRouterImmutables {
    function poolManager() external view returns (address);
}

/// @notice Checks the scripts' `BnbChainAddresses` against BNB Chain, as `MainnetAddresses.fork.t.sol` checks
///         Ethereum's: tokens by symbol and decimals, the router, the PoolManager and Uniswap's V3 factory by their
///         runtime code hashes, the BNB Chain list listed on a fresh factory and through `CheckToken`, a whole
///         deployment from the address book alone, and an index of that deployment issued in kind, rebalanced with
///         real transfers, minted and burned through the zap on Uniswap's real pools, in USDT and in BNB, and bought
///         and sold through `MintRequests` in both stablecoins. Skips when BNB_RPC_URL is unset.
///         Run: BNB_RPC_URL=... forge test --match-path 'test/fork/BnbChainAddresses.fork.t.sol' -vvv
contract BnbChainAddressesForkTest is Test, IRebalanceExecutor {
    using SafeERC20 for IERC20;

    /// @dev Runtime code hashes read on BNB Chain on 2026-10-07 at block 126,305,003 and again on 2026-11-13. The
    ///      router has no proxy and its immutables are part of its code, so the hash is the build and its wiring; the
    ///      build is Ethereum's but for those immutables.
    bytes32 constant UNIVERSAL_ROUTER_CODEHASH = 0x4899c516cf2f0b82251ab88630a9b326d1a2668855c553f9f5a0ea2de993e63b;
    bytes32 constant POOL_MANAGER_CODEHASH = 0x48752321ee7abf0d2a17c30679df9a1ddd14dc75d28b26e2509b76396145a005;
    bytes32 constant UNISWAP_V3_FACTORY_CODEHASH = 0x34b1009d0f004e58da791225992645e2df7697ac71ac89dc5e80469c4ef7e322;
    /// @dev Ethereum's router, by its runtime code: `MainnetAddresses.fork.t.sol` pins the same hash on Ethereum.
    bytes32 constant ETHEREUM_ROUTER_CODEHASH = 0x6a5f46971b50c6e1b7eef97902311444e479d734e4f80ad88367783cf373fe7f;
    /// @dev Block the fork pins to; BNB_FORK_BLOCK overrides it for a non-archive RPC that only serves recent state.
    uint256 constant FORK_BLOCK = 133_361_996;

    uint24 constant F500 = 500;

    // 0.01 BNB + 0.0001 BTCB + 0.001 ETH per index token
    uint256 constant U_WBNB = 1e16;
    uint256 constant U_BTCB = 1e14;
    uint256 constant U_ETH = 1e15;

    address alice = makeAddr("alice");

    function setUp() public {
        string memory url = vm.envOr("BNB_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BNB_FORK_BLOCK", FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "BNB_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set BNB_FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/fork/*'"
                )
            );
        }
        assertEq(block.chainid, B.CHAIN_ID, "BNB_RPC_URL is a BNB Chain node");
        // A well-known test address can carry code on a live chain; the suite is about the zap, not about its payer.
        vm.etch(alice, "");
    }

    function _assertToken(address token, string memory symbol, uint8 decimals) internal view {
        assertEq(IERC20Metadata(token).symbol(), symbol);
        assertEq(IERC20Metadata(token).decimals(), decimals);
    }

    /// @dev Every token of the address book, by the symbol and decimals each answers on chain, written out here rather
    ///      than read from the list.
    function testFork_tokensAreWhatTheirNamesSay() public view {
        _assertToken(B.WBNB, "WBNB", 18);
        _assertToken(B.BTCB, "BTCB", 18);
        _assertToken(B.ETH, "ETH", 18);
        _assertToken(B.XRP, "XRP", 18);
        _assertToken(B.ZEC, "ZEC", 18);
        _assertToken(B.ADA, "ADA", 18);
        _assertToken(B.BCH, "BCH", 18);
        _assertToken(B.LTC, "LTC", 18);
        _assertToken(B.DOT, "DOT", 18);
        _assertToken(B.ATOM, "ATOM", 18);
        _assertToken(B.ASTER, "ASTER", 18);
        _assertToken(B.STABLE, "STABLE", 18);
        _assertToken(B.USDT, "USDT", 18);
        _assertToken(B.USDC, "USDC", 18);
    }

    /// @dev CR-I35 on BNB Chain: the router names the PoolManager the address book does, and the router, the
    ///      PoolManager and the V3 factory are pinned by their code to the builds the zap was verified against.
    function testFork_CRI35_theRouterIsThePinnedBuild() public view {
        assertEq(IRouterImmutables(B.UNIVERSAL_ROUTER).poolManager(), B.POOL_MANAGER);
        assertEq(B.UNIVERSAL_ROUTER.codehash, UNIVERSAL_ROUTER_CODEHASH, "Uniswap's router is the 2.0.0 build");
        assertEq(B.POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH, "and the PoolManager is the one it settles with");
        assertEq(B.UNISWAP_V3_FACTORY.codehash, UNISWAP_V3_FACTORY_CODEHASH, "the V3 factory is Uniswap's");
    }

    /// @dev Ethereum's router address has code on BNB Chain: Ethereum's own router, byte for byte, immutables
    ///      included, so it names Ethereum's PoolManager address and settles against no market here. The deploy
    ///      checks read that address having code as "this is Ethereum" until 2026-11-13; they resolve BNB Chain's
    ///      book here, under BNB Chain's chain id and under an overridden one (RX-23).
    function testFork_ethereumsRouterAddressHereIsAReplayThatNamesNothing() public {
        assertEq(M.UNIVERSAL_ROUTER.codehash, ETHEREUM_ROUTER_CODEHASH, "Ethereum's router, replayed on BNB Chain");
        assertEq(IRouterImmutables(M.UNIVERSAL_ROUTER).poolManager(), M.POOL_MANAGER, "wired to Ethereum's addresses");
        assertTrue(M.UNIVERSAL_ROUTER != B.UNIVERSAL_ROUTER);
        assertTrue(M.POOL_MANAGER != B.POOL_MANAGER);

        DeployWeighted deployer = new DeployWeighted();
        assertTrue(deployer.onBnbChain());
        assertEq(deployer.pinnedRouter(), B.UNIVERSAL_ROUTER);
        vm.expectRevert(
            abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "UNIVERSAL_ROUTER", M.UNIVERSAL_ROUTER)
        );
        deployer.resolveRouter(M.UNIVERSAL_ROUTER);
        vm.chainId(31_337);
        assertTrue(deployer.onBnbChain(), "the state is BNB Chain's whatever the chain id says");
        assertEq(deployer.resolveRouter(address(0)), B.UNIVERSAL_ROUTER);

        // Under an override to Ethereum's own id the id decides, as it must on the real chain 1, where anyone can
        // replay BNB Chain's router. The run stays pinned, resolves Ethereum's book, and stops at the first address
        // of it that is empty here: none of Ethereum's WETH, USDC and USDT has code on BNB Chain.
        vm.chainId(1);
        assertTrue(deployer.isPinnedChain());
        assertFalse(deployer.onBnbChain());
        assertEq(M.WETH.code.length, 0);
        assertEq(M.USDC.code.length, 0);
        assertEq(M.USDT.code.length, 0);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.AddressHasNoCode.selector, "WETH", M.WETH));
        deployer.resolveStable("WETH", address(0), M.WETH);
    }

    /// @dev On chain 56 the deploy script resolves every market address from the address book and refuses any other.
    function testFork_deployResolvesTheBnbChainMarket() public {
        DeployWeighted deployer = new DeployWeighted();
        assertEq(deployer.resolveRouter(address(0)), B.UNIVERSAL_ROUTER);
        assertEq(deployer.resolveStable("WETH", address(0), B.WBNB), B.WBNB);
        assertEq(deployer.resolveStable("USDC", address(0), B.USDC), B.USDC);
        assertEq(deployer.resolveStable("USDT", address(0), B.USDT), B.USDT);
        vm.expectRevert(abi.encodeWithSelector(DeployChecks.MainnetOverride.selector, "USDT", B.USDC));
        deployer.resolveStable("USDT", B.USDC, B.USDT);
    }

    /// @dev A whole deployment on BNB Chain from the book alone: a contract owner the operator acknowledges (this
    ///      test, which answers no Safe threshold, A7-08), a guardian, and zero for every market address.
    function _deploy()
        internal
        returns (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests)
    {
        DeployWeighted deployer = new DeployWeighted();
        (factory, zap, builder, requests) = deployer.deploy(
            address(this), makeAddr("guardian"), address(0), address(0), address(0), address(0), address(this)
        );
        deployer.checkDeployment(factory, zap, builder, requests);
    }

    function testFork_aDeploymentFromTheAddressBook() public {
        (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests) = _deploy();
        assertEq(factory.owner(), address(this));
        assertEq(address(zap.ROUTER()), B.UNIVERSAL_ROUTER);
        assertEq(zap.POOL_MANAGER(), B.POOL_MANAGER);
        assertEq(address(zap.WETH()), B.WBNB, "the zap's wrapped coin is WBNB");
        assertEq(address(builder.ROUTER()), B.UNIVERSAL_ROUTER);
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

    /// @dev Every entry of the BNB Chain list, as the listing script builds it, listed on a fresh factory, which
    ///      records each token's on-chain decimals.
    function testFork_theBnbListMatchesTheChain() public {
        address[] memory list = new ConfigureWeighted().resolveList("bnb");
        assertEq(list.length, B.COUNT);
        WeightedIndexFactory factory = new WeightedIndexFactory(address(this), address(0));
        _list(factory, list);
        for (uint256 i = 0; i < list.length; ++i) {
            assertTrue(factory.isWhitelisted(list[i]));
            assertEq(factory.decimalsOf(list[i]), IERC20Metadata(list[i]).decimals());
        }
    }

    /// @dev Every coin of the BNB Chain list passes `CheckToken` as listable, its transfers exact, with its powers
    ///      recorded for the signers: the Binance-Peg coins' single minting key, and STABLE's upgrade by a Safe.
    function testFork_everyBnbTokenPassesTheCheck() public {
        CheckToken checker = new CheckToken();
        address[] memory list = new ConfigureWeighted().bnbList();
        for (uint256 i = 0; i < list.length; ++i) {
            CheckToken.Report memory r = checker.check(list[i], address(0), checker.markets());
            checker.log(r);
            assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact), r.symbol);
            assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Listable), r.symbol);
            if (B.tierOf(list[i]) == Listings.Tier.Custodial) {
                assertEq(r.powers, checker.MINT(), "a Binance-Peg coin's one power is its mint");
                assertEq(uint8(r.owner.kind), uint8(CheckToken.Kind.Key), "which one key holds");
                assertEq(r.implementation, address(0), "and no key can replace its code");
            }
        }
        CheckToken.Report memory stable = checker.check(B.STABLE, address(0), checker.markets());
        assertEq(stable.powers & checker.UPGRADE(), checker.UPGRADE());
        assertEq(uint8(stable.owner.kind), uint8(CheckToken.Kind.Safe), "STABLE is upgraded through a Safe");
    }

    /// @dev The three coins the list leaves out for their proxy: one externally owned key can replace the code of
    ///      Binance-Peg DOGE, AVAX and FIL, the reason DOGE left Ethereum's list on 2026-10-14.
    function testFork_theLeftOutProxiesAnswerToOneKey() public {
        CheckToken checker = new CheckToken();
        address[3] memory proxies = [
            0xbA2aE424d960c26247Dd6c32edC70B295c744C43, // DOGE
            0x1CE0c2827e2eF14D5C4f29a091d735A204794041, // AVAX
            0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153 // FIL
        ];
        for (uint256 i = 0; i < proxies.length; ++i) {
            CheckToken.Report memory r = checker.check(proxies[i], address(0), checker.markets());
            assertEq(r.powers & checker.UPGRADE(), checker.UPGRADE(), r.symbol);
            assertTrue(r.implementation != address(0), r.symbol);
            assertEq(uint8(r.admin.kind), uint8(CheckToken.Kind.Key), "the proxy's admin is a key");
            assertEq(uint8(B.tierOf(proxies[i])), uint8(Listings.Tier.Unrecorded), "and the coin is off the list");
        }
    }

    /// @dev An index of the whole BNB Chain list issues and redeems in kind: every coin moves by exactly what the
    ///      index asks, and a full redeem returns every coin.
    function testFork_anIndexOfTheWholeListIssuesAndRedeemsInKind() public {
        (WeightedHub index, address[] memory list) = _twelveCoinIndex();
        uint256 shares = 100e18;
        uint256[] memory need = _issueInKind(index, alice, shares);
        assertEq(index.balanceOf(alice), shares);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(IERC20(list[i]).balanceOf(alice), 0);
            assertEq(IERC20(list[i]).balanceOf(address(index)), need[i], "the index holds the coin itself");
        }

        vm.prank(alice);
        index.redeem(shares, alice);
        assertEq(index.totalSupply(), 0);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(IERC20(list[i]).balanceOf(alice), need[i], "every coin comes back in kind");
        }
    }

    /// @dev An index of the whole BNB Chain list on a fresh deployment, a thousandth of a coin of each per share.
    function _twelveCoinIndex() internal returns (WeightedHub index, address[] memory list) {
        (WeightedIndexFactory factory,,,) = _deploy();
        list = B.all();
        _list(factory, list);
        factory.setApprovedCreator(address(this), true);
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            // 12 coins: 837 for the first and 833 for each other is 10,000.
            specs[i] = IWeightedIndexFactory.ComponentSpec({token: list[i], weight: i == 0 ? 837 : 833, units: 1e15});
        }
        index = WeightedHub(factory.createIndex("BNB Chain Twelve", "BNB12", specs, _params()));
    }

    /// @dev Issues `shares` of `index` to `to` from coins dealt to it. Returns what the index took of each.
    function _issueInKind(WeightedHub index, address to, uint256 shares) internal returns (uint256[] memory need) {
        address[] memory tokens = index.componentTokens();
        need = index.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            deal(tokens[i], to, need[i]);
            vm.prank(to);
            IERC20(tokens[i]).approve(address(index), need[i]);
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

    /// @dev An index of the whole BNB Chain list rebalances with real transfers: WBNB leaves and each of the other
    ///      eleven coins comes in, so the index probes that it can send every one of them (RX-12) and the post-check
    ///      reads every real balance. The units are the ones the executor named, every balance moved by exactly the
    ///      previewed amount, and the holder then leaves in kind at the new units.
    function testFork_anIndexOfTheWholeListRebalancesWithRealTransfers() public {
        (WeightedHub index, address[] memory list) = _twelveCoinIndex();
        uint256 shares = 100e18;
        _issueInKind(index, alice, shares);

        vm.warp(index.earliestRebalance() + 1);
        index.startRebalance(0);
        uint256[] memory newUnits = index.recordedUnits();
        newUnits[0] = newUnits[0] * 9 / 10;
        for (uint256 i = 1; i < list.length; ++i) {
            newUnits[i] = newUnits[i] * 21 / 20;
        }
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + 2 hours);
        (uint256 bar, int256 gain, uint256[] memory amountsOut, uint256[] memory amountsIn) =
            index.previewRebalance(newUnits);
        assertGt(bar, 0);
        assertGe(gain, int256(bar));
        assertGt(amountsOut[0], 0, "WBNB leaves");
        assertEq(amountsIn[0], 0);

        uint256[] memory held = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            held[i] = IERC20(list[i]).balanceOf(address(index));
            if (i != 0) {
                assertGt(amountsIn[i], 0, "every other coin comes in");
                assertEq(amountsOut[i], 0);
                deal(list[i], address(this), amountsIn[i]);
            }
        }
        uint256 wbnbBefore = IERC20(B.WBNB).balanceOf(address(this));
        index.executeRebalance(newUnits, "");

        assertEq(IERC20(B.WBNB).balanceOf(address(this)) - wbnbBefore, amountsOut[0], "the executor is paid in WBNB");
        uint256[] memory units = index.recordedUnits();
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(units[i], newUnits[i], "the units are the ones named");
            assertEq(IERC20(list[i]).balanceOf(address(index)), held[i] + amountsIn[i] - amountsOut[i]);
            if (i != 0) {
                assertEq(IERC20(list[i]).balanceOf(address(this)), 0, "the executor paid exactly what was asked");
            }
        }

        uint256[] memory back = index.previewRedeem(shares);
        vm.prank(alice);
        index.redeem(shares, alice);
        assertEq(index.totalSupply(), 0);
        for (uint256 i = 0; i < list.length; ++i) {
            assertEq(IERC20(list[i]).balanceOf(alice), back[i], "the holder leaves in kind at the new units");
            assertGt(back[i], 0);
        }
    }

    /// @dev `MintRequests` on BNB Chain's deployment in each of its two stablecoins, both of 18 decimals there and
    ///      USDC a proxy: a mint request escrows the stablecoin and a filler's shares fill it, a redemption request
    ///      escrows the shares and the filler's stablecoin fills it, and a cancelled request returns its escrow.
    ///      Every amount lands whole: neither stablecoin charges a fee on transfer at this block.
    function testFork_requestsEscrowAndFillInBothStablecoins() public {
        (WeightedIndexFactory factory,,, MintRequests requests) = _deploy();
        WeightedHub index = _majors(factory);
        address filler = makeAddr("filler");
        vm.etch(filler, "");
        uint256 shares = 1e18;
        uint256 pay = 500e18;
        _issueInKind(index, filler, shares);

        address[2] memory stables = [B.USDT, B.USDC];
        for (uint256 s = 0; s < stables.length; ++s) {
            IERC20 stable = IERC20(stables[s]);
            deal(address(stable), alice, pay);
            deal(address(stable), filler, 0);
            uint256 deadline = block.timestamp + 1 days;

            vm.startPrank(alice);
            stable.forceApprove(address(requests), pay);
            uint256 id = requests.requestMint(address(index), address(stable), pay, shares, deadline);
            vm.stopPrank();
            assertEq(stable.balanceOf(address(requests)), pay, "the escrow is the whole amount");
            assertEq(stable.balanceOf(alice), 0);

            vm.startPrank(filler);
            index.approve(address(requests), shares);
            requests.fill(id, shares);
            vm.stopPrank();
            assertEq(index.balanceOf(alice), shares, "the requester has the shares");
            assertEq(stable.balanceOf(filler), pay, "and the filler the escrow");
            assertEq(stable.balanceOf(address(requests)), 0);

            vm.startPrank(alice);
            index.approve(address(requests), shares);
            id = requests.requestRedeem(address(index), shares, address(stable), pay, deadline);
            vm.stopPrank();
            assertEq(index.balanceOf(address(requests)), shares);

            vm.startPrank(filler);
            stable.forceApprove(address(requests), pay);
            requests.fill(id, pay);
            vm.stopPrank();
            assertEq(stable.balanceOf(alice), pay, "the requester is paid its limit in full");
            assertEq(index.balanceOf(filler), shares, "and the filler has the shares back");
            assertEq(index.balanceOf(address(requests)), 0);

            vm.startPrank(alice);
            stable.forceApprove(address(requests), pay);
            id = requests.requestMint(address(index), address(stable), pay, shares, deadline);
            requests.cancel(id);
            vm.stopPrank();
            assertEq(stable.balanceOf(alice), pay, "a cancelled request returns its escrow whole");
            assertEq(stable.balanceOf(address(requests)), 0);
        }
    }

    /// @dev An index of WBNB, BTCB and ETH on `factory`, the three coins Uniswap routes deepest on BNB Chain.
    function _majors(WeightedIndexFactory factory) internal returns (WeightedHub index) {
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (B.WBNB, B.BTCB, B.ETH);
        _list(factory, three);
        factory.setApprovedCreator(address(this), true);
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](3);
        specs[0] = IWeightedIndexFactory.ComponentSpec({token: B.WBNB, weight: 3334, units: U_WBNB});
        specs[1] = IWeightedIndexFactory.ComponentSpec({token: B.BTCB, weight: 3333, units: U_BTCB});
        specs[2] = IWeightedIndexFactory.ComponentSpec({token: B.ETH, weight: 3333, units: U_ETH});
        index = WeightedHub(factory.createIndex("BNB Chain Majors", "BMAJ", specs, _params()));
    }

    function _threeCoinIndex() internal returns (IndexZap zap, WeightedHub index) {
        WeightedIndexFactory factory;
        (factory, zap,,) = _deploy();
        index = _majors(factory);
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

    /// @dev The zap mints an index of BNB Chain's deployment from USDT alone and burns it back to USDT, through the
    ///      pinned Universal Router and Uniswap's real V3 pools: the command inputs the zap encodes for Ethereum's
    ///      router hold on BNB Chain's, and the index receives every coin in kind. The round trip costs the pools'
    ///      fees and nothing else.
    function testFork_theZapMintsAndBurnsInUsdtThroughUniswap() public {
        (IndexZap zap, WeightedHub index) = _threeCoinIndex();
        uint256 shares = 10e18;
        uint256 budget = 10_000e18;
        deal(B.USDT, alice, budget);

        // Exact-output paths run from the component back to what the user pays with.
        bytes[3] memory mintPaths = [
            abi.encodePacked(B.WBNB, F500, B.USDT),
            abi.encodePacked(B.BTCB, F500, B.USDT),
            abi.encodePacked(B.ETH, F500, B.USDT)
        ];
        vm.startPrank(alice);
        IERC20(B.USDT).approve(address(zap), budget);
        uint256 spent = zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(index),
                expectedNonce: 0,
                tokenIn: B.USDT,
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
        assertEq(IERC20(B.USDT).balanceOf(alice), budget - spent, "what the swaps did not take came back");
        assertEq(IERC20(B.WBNB).balanceOf(address(index)), shares * U_WBNB / 1e18, "the index holds BNB in kind");
        assertEq(IERC20(B.BTCB).balanceOf(address(index)), shares * U_BTCB / 1e18);
        assertEq(IERC20(B.ETH).balanceOf(address(index)), shares * U_ETH / 1e18);
        assertEq(IERC20(B.USDT).balanceOf(address(zap)), 0, "nothing stays in the zap");

        bytes[3] memory burnPaths = [
            abi.encodePacked(B.WBNB, F500, B.USDT),
            abi.encodePacked(B.BTCB, F500, B.USDT),
            abi.encodePacked(B.ETH, F500, B.USDT)
        ];
        vm.startPrank(alice);
        index.approve(address(zap), shares);
        uint256 out = zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(index),
                expectedNonce: 0,
                shares: shares,
                tokenOut: B.USDT,
                minAmountOut: spent * 99 / 100,
                legs: _burnLegs(burnPaths),
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertEq(index.totalSupply(), 0);
        assertEq(IERC20(B.USDT).balanceOf(alice), budget - spent + out);
        assertGe(out, spent * 99 / 100, "the zap held the burn to its floor: a round trip loses under 1%");
        assertLt(out, spent, "and gains nothing");
    }

    /// @dev The zap's ether entry points take and pay BNB on BNB Chain: WBNB is its wrapped coin there, as WETH is
    ///      on Ethereum. The WBNB leg passes through, the other two swap from WBNB.
    function testFork_theZapMintsAndBurnsInBnb() public {
        (IndexZap zap, WeightedHub index) = _threeCoinIndex();
        uint256 shares = 10e18;
        uint256 budget = 5 ether;
        vm.deal(alice, budget);

        bytes[3] memory paths =
            [bytes(""), abi.encodePacked(B.BTCB, F500, B.WBNB), abi.encodePacked(B.ETH, F500, B.WBNB)];
        vm.startPrank(alice);
        uint256 spent = zap.mintWithEth{value: budget}(
            IIndexZap.MintParams({
                index: address(index),
                expectedNonce: 0,
                tokenIn: B.WBNB,
                maxAmountIn: budget,
                shares: shares,
                legs: _mintLegs(paths),
                to: alice,
                deadline: block.timestamp,
                referrer: address(0)
            })
        );
        assertEq(index.balanceOf(alice), shares);
        assertGt(spent, shares * U_WBNB / 1e18, "the BNB leg and two swaps");
        assertEq(alice.balance, budget - spent, "the rest of the BNB is refunded as BNB");

        index.approve(address(zap), shares);
        uint256 out = zap.burnToEth(
            IIndexZap.BurnParams({
                index: address(index),
                expectedNonce: 0,
                shares: shares,
                tokenOut: B.WBNB,
                minAmountOut: spent * 99 / 100,
                legs: _burnLegs(paths),
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertEq(alice.balance, budget - spent + out, "paid out as BNB");
        assertGe(out, spent * 99 / 100);
        assertLt(out, spent);
        assertEq(IERC20(B.WBNB).balanceOf(address(zap)), 0);
    }
}
