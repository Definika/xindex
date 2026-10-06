// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CheckToken} from "../script/CheckToken.s.sol";
import {ConfigureWeighted} from "../script/ConfigureWeighted.s.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockRebasingToken} from "./mocks/MockRebasingToken.sol";
import {MockERC1820Registry, MockERC1363Token} from "./mocks/MockHookRegistries.sol";
import {
    MockBlacklistToken,
    MockSeizableToken,
    MockBep20Token,
    MockTokenController,
    MockMiniMeToken,
    MockRolesToken
} from "./mocks/MockAdminTokens.sol";
import {MockSafeOwner, MockTimelockOwner, MockDelayOwner} from "./mocks/MockOwners.sol";
import {MockLegacyProxy} from "./mocks/MockLegacyProxy.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./mocks/MockUniswapV3.sol";

/// @notice The admission check (`script/CheckToken.s.sol`), run against mocks of every kind of token, proxy, owner and
///         pool it classifies. `test/fork/CheckToken.fork.t.sol` runs it on real tokens.
/// @dev Environment variables are process-global and tests run in parallel, so each name is set by exactly one test:
///      CHECK and CHECK_HOLDERS by `test_run_readsTheEnvironment`.
contract CheckTokenTest is Test {
    CheckToken checker;
    CheckToken.Markets none;
    address key = makeAddr("key");

    /// @dev The slots CheckToken reads, written out here from their definitions rather than copied from the script.
    bytes32 constant EIP1967_IMPLEMENTATION = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 constant ZOS_IMPLEMENTATION = keccak256("org.zeppelinos.proxy.implementation");
    bytes32 constant ZOS_ADMIN = keccak256("org.zeppelinos.proxy.admin");
    bytes32 constant EIP1822_PROXIABLE = keccak256("PROXIABLE");
    bytes32 constant ERC777_TOKEN = keccak256("ERC777Token");

    /// @dev The band per unit of liquidity, from `1 - 1 / sqrt(1.02)` and `1 - sqrt(0.98)` computed to 50 digits
    ///      off chain and floored to 18 decimals.
    uint256 constant UP = 9_852_457_023_325_690;
    uint256 constant DOWN = 10_050_506_338_833_465;

    function setUp() public {
        checker = new CheckToken();
    }

    function _token(uint8 decimals) internal returns (MockERC20 token) {
        token = new MockERC20("Token", "TKN", decimals);
        token.mint(address(this), 1_000_000 * 10 ** uint256(decimals));
    }

    function _check(address token) internal returns (CheckToken.Report memory) {
        return checker.check(token, address(0), none);
    }

    // ---------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------

    function test_aStandardTokenIsListable() public {
        MockERC20 token = _token(18);
        CheckToken.Report memory r = _check(address(token));
        assertEq(r.token, address(token));
        assertEq(r.symbol, "TKN");
        assertTrue(r.decimalsAnswered);
        assertEq(r.decimals, 18);
        assertEq(r.totalSupply, 1_000_000e18);
        assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact), "the balance slot is written and moves exactly");
        assertFalse(r.registry, "no ERC-1820 registry on a bare chain");
        assertEq(r.powers, checker.MINT() | checker.BURN_OTHERS(), "mint(address,uint256) and burn(address,uint256)");
        assertEq(uint8(r.owner.kind), uint8(CheckToken.Kind.None));
        assertEq(r.pools.length, 0, "no market named, so no depth");
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Listable));
        assertEq(r.reason, "");
        assertEq(token.balanceOf(checker.SENDER()), 0, "the simulation is undone");
    }

    function test_feeOnTransferIsRefused() public {
        MockFeeToken token = new MockFeeToken();
        CheckToken.Report memory r = _check(address(token));
        assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Inexact));
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Refused));
        assertEq(r.reason, checker.transferText(CheckToken.Transfers.Inexact));
    }

    /// @dev A share token's balance slot cannot be written, so the test balance comes from a holder: exact when its
    ///      shares divide evenly, inexact when they round, rebasing when its rate grows, untested with no holder.
    function test_shareTokensAreTestedFromAHolder() public {
        address holder = makeAddr("holder");
        MockRebasingToken even = new MockRebasingToken(2e18, 0);
        even.mintShares(holder, 10e18);
        MockRebasingToken rounding = new MockRebasingToken(3e18, 0);
        rounding.mintShares(holder, 10e18);
        MockRebasingToken growing = new MockRebasingToken(2e18, 1e12);
        growing.mintShares(holder, 10e18);
        assertEq(growing.rate(), 2e18, "the rate starts where it was built");

        address[] memory holders = new address[](2);
        holders[0] = makeAddr("empty"); // holds nothing, so the next is tried
        holders[1] = holder;
        assertEq(uint8(checker.transfersOf(address(even), 1e18, holders)), uint8(CheckToken.Transfers.Exact));
        assertEq(uint8(checker.transfersOf(address(rounding), 1e18, holders)), uint8(CheckToken.Transfers.Inexact));
        assertEq(uint8(checker.transfersOf(address(growing), 1e18, holders)), uint8(CheckToken.Transfers.Rebases));
        assertEq(
            uint8(checker.transfersOf(address(even), 1e18, new address[](0))), uint8(CheckToken.Transfers.Untested)
        );
        assertEq(even.balanceOf(holder), 20e18, "the holder's balance is put back");

        CheckToken.Report memory r = checker.check(address(even), holder, none);
        assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact), "the named holder pays");
        r = checker.check(address(growing), holder, none);
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Refused));
        assertEq(r.reason, checker.transferText(CheckToken.Transfers.Rebases));
    }

    function test_aPausedTokenFailsItsTransfers() public {
        MockBlacklistToken token = new MockBlacklistToken(key);
        token.mint(address(this), 1e24);
        token.pause();
        assertEq(uint8(_check(address(token)).transfers), uint8(CheckToken.Transfers.Failed));
        token.unpause();
        CheckToken.Report memory r = _check(address(token));
        assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact));
        assertEq(r.powers, checker.MINT() | checker.PAUSE() | checker.BLACKLIST(), "recorded, not refused");
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Listable), "a blacklist alone is no reason to refuse");
        assertEq(uint8(r.owner.kind), uint8(CheckToken.Kind.Key));
        assertEq(r.owner.account, key);

        token.addBlackList(checker.PAYEE());
        assertEq(uint8(_check(address(token)).transfers), uint8(CheckToken.Transfers.Failed), "transferFrom is refused");
    }

    function test_oddDecimalsAreRefusedAndStillTested() public {
        MockERC20 token = _token(40); // more than one whole token could be written: the fallback amount is moved
        CheckToken.Report memory r = _check(address(token));
        assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact));
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Refused));
        assertEq(r.reason, "decimals outside the whitelist policy's 6 to 18");
        checker.log(r);
    }

    function test_aTokenWithoutCodeIsRefused() public {
        CheckToken.Report memory r = checker.check(makeAddr("nothing"), address(0), none);
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Refused));
        assertEq(r.reason, "the token has no code");
        assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Untested));
        checker.log(r);
    }

    // ---------------------------------------------------------------------
    // Hooks
    // ---------------------------------------------------------------------

    function test_anERC777TokenIsRefused() public {
        MockERC20 token = _token(18);
        vm.etch(checker.ERC1820_REGISTRY(), address(new MockERC1820Registry()).code);
        CheckToken.Report memory r = _check(address(token));
        assertTrue(r.registry);
        assertFalse(r.erc777, "not registered");
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Listable));

        MockERC1820Registry(checker.ERC1820_REGISTRY())
            .setInterfaceImplementer(address(token), ERC777_TOKEN, address(token));
        r = _check(address(token));
        assertTrue(r.erc777);
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Refused));
        assertEq(r.reason, "registered as an ERC-777 token: transfer hooks");
    }

    function test_anERC1363TokenIsRefusedAndAnAnswerToEverythingIsNot() public {
        MockERC1363Token callback = new MockERC1363Token(false);
        deal(address(callback), address(this), 1e24);
        CheckToken.Report memory r = _check(address(callback));
        assertTrue(r.erc1363);
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Refused));
        assertEq(r.reason, "ERC-1363 by ERC-165: transfer callbacks");

        (,, bool erc1363) = checker.hooksOf(address(new MockERC1363Token(true)));
        assertFalse(erc1363, "a token answering true to the invalid id has no meaningful ERC-165");
        (,, erc1363) = checker.hooksOf(address(new MockRolesToken(key)));
        assertFalse(erc1363, "ERC-165 without ERC-1363");
    }

    // ---------------------------------------------------------------------
    // Admin powers
    // ---------------------------------------------------------------------

    function test_theWbtRuleRefusesABlacklistThatCanDestroy() public {
        MockSeizableToken token = new MockSeizableToken(key);
        token.mint(address(this), 1e24);
        CheckToken.Report memory r = _check(address(token));
        assertEq(r.powers & (checker.BLACKLIST() | checker.DESTROY()), checker.BLACKLIST() | checker.DESTROY());
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Refused));
        assertEq(r.reason, "the WBT rule: it can blacklist a holder and destroy its balance");

        // The mock's power is real: a blacklisted holder's balance goes.
        address victim = makeAddr("victim");
        token.mint(victim, 5);
        token.addBlackList(victim);
        token.destroyBlackFunds(victim);
        assertEq(token.balanceOf(victim), 0);
    }

    /// @dev LEO's shape: the controller destroys any balance and approves every transfer, so it can refuse any.
    function test_theWbtRuleRefusesAMiniMeController() public {
        MockTokenController controller = new MockTokenController(key);
        MockMiniMeToken token = new MockMiniMeToken(address(controller));
        token.generateTokens(address(this), 1e24);
        CheckToken.Report memory r = _check(address(token));
        assertEq(r.powers, checker.MINT() | checker.BLACKLIST() | checker.DESTROY());
        assertEq(r.owner.account, address(controller), "the controller is the owner");
        assertEq(uint8(r.owner.kind), uint8(CheckToken.Kind.Contract));
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Refused));
        assertEq(
            checker.describe(r.owner),
            string.concat(
                vm.toString(address(controller)),
                ", a contract whose owner() is ",
                vm.toString(key),
                ", an externally owned key"
            )
        );
        token.destroyTokens(address(this), 1);
        assertEq(token.balanceOf(address(this)), 1e24 - 1);
    }

    function test_ownersAreReadFromOwnerGetOwnerOrRoles() public {
        MockBep20Token peg = new MockBep20Token(key);
        peg.mint(1e24);
        CheckToken.Report memory r = _check(address(peg));
        assertEq(r.owner.account, key, "BEP-20's getOwner");
        assertEq(r.powers, checker.MINT(), "mint(uint256)");

        MockRolesToken roles = new MockRolesToken(key);
        vm.prank(key);
        roles.mint(address(this), 1e24);
        r = _check(address(roles));
        assertEq(r.roleAdmin.account, key, "the enumerable DEFAULT_ADMIN_ROLE");
        assertEq(r.powers, checker.MINT() | checker.ROLES());
        checker.log(r);
    }

    function test_classify() public {
        CheckToken.Party memory p = checker.classify(address(0));
        assertEq(uint8(p.kind), uint8(CheckToken.Kind.None));
        assertEq(checker.describe(p), "none");

        p = checker.classify(key);
        assertEq(uint8(p.kind), uint8(CheckToken.Kind.Key));

        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", key));
        p = checker.classify(delegated);
        assertEq(uint8(p.kind), uint8(CheckToken.Kind.DelegatedKey));
        assertEq(checker.kindText(p), "a key delegated under EIP-7702");

        p = checker.classify(address(new MockSafeOwner(3, 5, true)));
        assertEq(uint8(p.kind), uint8(CheckToken.Kind.Safe));
        assertEq(p.threshold, 3);
        assertEq(p.signers, 5);
        assertEq(checker.kindText(p), "a Safe, 3 of 5");
        p = checker.classify(address(new MockSafeOwner(2, 4, false)));
        assertEq(p.signers, 0, "a multisig that lists no owners");

        p = checker.classify(address(new MockTimelockOwner(2 days)));
        assertEq(uint8(p.kind), uint8(CheckToken.Kind.Timelock));
        assertEq(p.delay, 2 days);
        assertEq(checker.kindText(p), "a timelock, minimum delay 172800 s");
        p = checker.classify(address(new MockDelayOwner(1 days)));
        assertEq(uint8(p.kind), uint8(CheckToken.Kind.Timelock));
        assertEq(p.delay, 1 days);

        MockERC20 other = _token(18);
        p = checker.classify(address(other));
        assertEq(uint8(p.kind), uint8(CheckToken.Kind.Contract));
        assertEq(
            checker.describe(p), string.concat(vm.toString(address(other)), ", a contract"), "no owner() to follow"
        );
        assertEq(checker.kindText(CheckToken.Party(address(0), CheckToken.Kind.None, 0, 0, 0)), "none");
    }

    // ---------------------------------------------------------------------
    // Proxies
    // ---------------------------------------------------------------------

    /// @dev A MockERC20 implementation behind `proxy`, set to 18 decimals and funded through it.
    /// @dev The call OpenZeppelin's proxies now require at construction: set the decimals.
    function _init() internal pure returns (bytes memory) {
        return abi.encodeCall(MockERC20.setDecimals, (18));
    }

    function _behind(address proxy) internal returns (address) {
        MockERC20(proxy).setDecimals(18);
        MockERC20(proxy).mint(address(this), 1e24);
        return proxy;
    }

    function test_proxiesAreFollowedToTheirImplementation() public {
        MockERC20 impl = new MockERC20("Impl", "IMPL", 18);

        // UUPS-style EIP-1967: an implementation slot and no admin.
        address uups = _behind(address(new ERC1967Proxy(address(impl), _init())));
        CheckToken.Report memory r = _check(uups);
        assertEq(r.implementation, address(impl));
        assertEq(r.upgrader, address(0));
        assertEq(r.powers & checker.MINT(), checker.MINT(), "the implementation's powers count");
        assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact), "the proxy's own slot is written");
        checker.log(r);

        // Transparent: the admin slot holds a ProxyAdmin whose owner is a key.
        address transparent = _behind(address(new TransparentUpgradeableProxy(address(impl), key, _init())));
        r = _check(transparent);
        assertEq(r.implementation, address(impl));
        assertEq(uint8(r.admin.kind), uint8(CheckToken.Kind.Contract));
        assertEq(r.powers & checker.UPGRADE(), checker.UPGRADE(), "upgradeToAndCall in the proxy");
        assertEq(
            checker.describe(r.admin),
            string.concat(
                vm.toString(r.upgrader), ", a contract whose owner() is ", vm.toString(key), ", an externally owned key"
            )
        );
        checker.log(r);

        // A beacon, whose owner upgrades.
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), key);
        (address implementation, address upgrader) = checker.proxyOf(address(new BeaconProxy(address(beacon), _init())));
        assertEq(implementation, address(impl));
        assertEq(upgrader, key);

        // An EIP-1167 clone, which nobody upgrades.
        (implementation, upgrader) = checker.proxyOf(Clones.clone(address(impl)));
        assertEq(implementation, address(impl));
        assertEq(upgrader, address(0));

        // The zeppelinos slots, with an admin, and without one but with an OwnedUpgradeabilityProxy's owner (OKB's).
        address admin = makeAddr("admin");
        (implementation, upgrader) =
            checker.proxyOf(address(new MockLegacyProxy(ZOS_IMPLEMENTATION, address(impl), ZOS_ADMIN, admin, key)));
        assertEq(implementation, address(impl));
        assertEq(upgrader, admin);
        MockLegacyProxy owned = new MockLegacyProxy(ZOS_IMPLEMENTATION, address(impl), bytes32(0), address(0), key);
        r = _check(_behind(address(owned)));
        assertEq(r.implementation, address(impl));
        assertEq(r.upgrader, key, "proxyOwner()");

        // EIP-1822.
        (implementation, upgrader) = checker.proxyOf(
            address(new MockLegacyProxy(EIP1822_PROXIABLE, address(impl), bytes32(0), address(0), address(0)))
        );
        assertEq(implementation, address(impl));
        assertEq(upgrader, address(0));
    }

    function test_aSlotThatHoldsNoAddressIsNoProxy() public {
        MockERC20 token = _token(18);
        vm.store(address(token), EIP1967_IMPLEMENTATION, bytes32(type(uint256).max));
        (address implementation, address upgrader) = checker.proxyOf(address(token));
        assertEq(implementation, address(0));
        assertEq(upgrader, address(0));
    }

    // ---------------------------------------------------------------------
    // The selector scan
    // ---------------------------------------------------------------------

    function test_powersOf_readsPushedSelectorsAndSkipsPushData() public view {
        // PUSH4 destroyBlackFunds; PUSH3 0x0ecb93, which is not addBlackList; a PUSH32 whose data holds pause()'s
        // selector off its left edge, so not as a bytes4 constant; a PUSH4 cut off by the end of the code.
        bytes memory code =
            abi.encodePacked(hex"63f3bdc228", hex"620ecb93", hex"7f", bytes32(uint256(0x8456cb59) << 8), hex"6340c10f");
        assertEq(checker.powersOf(code), checker.DESTROY(), "only the whole PUSH4 counts");
        assertEq(checker.powersOf(hex"630ecb93c0"), checker.BLACKLIST());
        // A bytes4 constant, left-aligned in a PUSH32: upgradeToAndCall, as OpenZeppelin's transparent proxy holds it.
        assertEq(checker.powersOf(abi.encodePacked(hex"7f", bytes32(bytes4(0x4f1ef286)))), checker.UPGRADE());
        assertEq(checker.powersOf(hex"00"), 0);
        assertEq(checker.powersOf(""), 0);
    }

    function test_powerOf_everyCategory() public view {
        assertEq(checker.powerOf(0x40c10f19), checker.MINT());
        assertEq(checker.powerOf(0x8456cb59), checker.PAUSE());
        assertEq(checker.powerOf(0xf9f92be4), checker.BLACKLIST());
        assertEq(checker.powerOf(0xf3bdc228), checker.DESTROY());
        assertEq(checker.powerOf(0x79cc6790), checker.BURN_OTHERS());
        assertEq(checker.powerOf(0x3659cfe6), checker.UPGRADE());
        assertEq(checker.powerOf(0x4000aea0), checker.CALLBACK());
        assertEq(checker.powerOf(0x91d14854), checker.ROLES());
        assertEq(checker.powerOf(0xa9059cbb), 0, "transfer is no power");
    }

    /// @dev Every selector in the table is the hash of the signature its comment names, pinned here independently.
    function test_powerOf_theTableMatchesItsSignatures() public view {
        string[11] memory mints = [
            "mint(address,uint256)",
            "mint(uint256)",
            "issue(uint256)",
            "mintTo(address,uint256)",
            "increaseSupply(uint256)",
            "bridgeMint(address,uint256)",
            "crosschainMint(address,uint256)",
            "generateTokens(address,uint256)",
            "mintInflation(address,uint256)",
            "mintOnce(address[],uint256[])",
            "voteForMinting((address,uint64,((int8,bytes32),bytes32,uint64)),(address,bytes)[])"
        ];
        for (uint256 i = 0; i < mints.length; ++i) {
            _assertPower(mints[i], checker.MINT());
        }
        string[7] memory pauses = [
            "pause()",
            "unpause()",
            "paused()",
            "enableTransfers(bool)",
            "ownerPause()",
            "guardianPause()",
            "resetMode()"
        ];
        for (uint256 i = 0; i < pauses.length; ++i) {
            _assertPower(pauses[i], checker.PAUSE());
        }
        string[23] memory blacklists = [
            "addBlackList(address)",
            "blacklist(address)",
            "freeze(address)",
            "blacklistAccount(address,bool)",
            "addToBlacklist(address)",
            "addBlacklist(address)",
            "addToBlackList(address)",
            "setBlacklist(address,bool)",
            "setBlackList(address,bool)",
            "updateBlacklist(address,bool)",
            "blacklistAddress(address)",
            "freezeAccount(address)",
            "freezeAccount(address,bool)",
            "freezeAddress(address)",
            "addToBlockedList(address)",
            "blockAccount(address)",
            "lockAccount(address)",
            "ownerSetBlacklistStatus(address,bool)",
            "guardianSetBlacklistStatus(address,bool)",
            "isBlacklisted(address)",
            "isBlackListed(address)",
            "isFrozen(address)",
            "onTransfer(address,address,uint256)"
        ];
        for (uint256 i = 0; i < blacklists.length; ++i) {
            _assertPower(blacklists[i], checker.BLACKLIST());
        }
        string[11] memory destroys = [
            "destroyBlackFunds(address)",
            "wipeFrozenAddress(address)",
            "wipeBlacklistedAccount(address)",
            "destroyBlockedFunds(address)",
            "burnFrozen(address)",
            "confiscate(address,uint256)",
            "seize(address,uint256)",
            "forceTransfer(address,address,uint256)",
            "destroyTokens(address,uint256)",
            "ownerReallocateFrom(address,address,uint256)",
            "ownerBatchReallocateFrom(address[],address[],uint256[])"
        ];
        for (uint256 i = 0; i < destroys.length; ++i) {
            _assertPower(destroys[i], checker.DESTROY());
        }
        string[4] memory burns = [
            "burnFrom(address,uint256)",
            "burn(address,uint256)",
            "bridgeBurn(address,uint256)",
            "crosschainBurn(address,uint256)"
        ];
        for (uint256 i = 0; i < burns.length; ++i) {
            _assertPower(burns[i], checker.BURN_OTHERS());
        }
        _assertPower("upgradeTo(address)", checker.UPGRADE());
        _assertPower("upgradeToAndCall(address,bytes)", checker.UPGRADE());
        _assertPower("deprecate(address)", checker.UPGRADE());
        _assertPower("transferAndCall(address,uint256,bytes)", checker.CALLBACK());
        _assertPower("transferAndCall(address,uint256)", checker.CALLBACK());
        _assertPower("hasRole(bytes32,address)", checker.ROLES());
    }

    function _assertPower(string memory signature, uint256 power) internal view {
        assertEq(checker.powerOf(uint32(bytes4(keccak256(bytes(signature))))), power, signature);
    }

    // ---------------------------------------------------------------------
    // Depth
    // ---------------------------------------------------------------------

    function test_bandAmounts() public view {
        uint160 one = uint160(1 << 96); // a price of 1
        (uint256 tokenSide, uint256 bothSides) = checker.bandAmounts(1e18, one, true);
        assertEq(tokenSide, UP, "token0 above the price");
        assertEq(bothSides, UP + DOWN);
        (tokenSide, bothSides) = checker.bandAmounts(1e18, one, false);
        assertEq(tokenSide, DOWN, "token1 below the price");
        assertEq(bothSides, UP + DOWN);

        uint160 two = uint160(2 << 96); // a price of 4: L / sqrt(P) = 0.5e18 and L * sqrt(P) = 2e18
        (tokenSide, bothSides) = checker.bandAmounts(1e18, two, true);
        assertEq(tokenSide, 4_926_228_511_662_845);
        assertEq(bothSides, 9_951_481_681_079_577);
        (tokenSide, bothSides) = checker.bandAmounts(1e18, two, false);
        assertEq(tokenSide, 20_101_012_677_666_930);
        assertEq(bothSides, 39_805_926_724_318_310);
    }

    function _markets() internal returns (CheckToken.Markets memory m, MockUniswapV3Factory factory) {
        factory = new MockUniswapV3Factory();
        m = CheckToken.Markets({
            v3Factory: address(factory),
            poolManager: address(new MockPoolManager()),
            weth: address(new MockERC20("Wrapped Ether", "WETH", 18)),
            usdc: address(new MockERC20("USD Coin", "USDC", 6))
        });
    }

    function test_depthReadsV3AndHooklessV4Pools() public {
        (CheckToken.Markets memory m, MockUniswapV3Factory factory) = _markets();
        MockRebasingToken token = new MockRebasingToken(2e18, 0); // its slot cannot be written: the pools pay
        MockUniswapV3Pool wethPool = MockUniswapV3Pool(factory.createPool(address(token), m.weth, 3000));
        wethPool.initialize(uint160(1 << 96));
        wethPool.setLiquidity(1e18);
        factory.createPool(address(token), m.usdc, 500); // created, never initialized: skipped
        token.mintShares(address(wethPool), 10e18);
        MockPoolManager manager = MockPoolManager(m.poolManager);
        manager.setPool(address(0), address(token), 500, 10, uint160(2 << 96), -5, 500, 1e18);
        (address c0, address c1) = address(token) < m.usdc ? (address(token), m.usdc) : (m.usdc, address(token));
        manager.setPool(c0, c1, 10_000, 200, uint160(1 << 96), 7, 10_000, 0);

        CheckToken.Report memory r = checker.check(address(token), address(0), m);
        assertEq(r.pools.length, 3);
        CheckToken.Pool memory v3 = r.pools[0];
        assertEq(v3.version, 3);
        assertEq(v3.pair, m.weth);
        assertEq(v3.fee, 3000);
        assertEq(v3.at, address(wethPool));
        assertEq(v3.liquidity, 1e18);
        assertEq(v3.tokenSide, address(token) < m.weth ? UP : DOWN);
        assertEq(v3.bothSides, UP + DOWN);

        CheckToken.Pool memory ether_ = r.pools[1];
        assertEq(ether_.version, 4);
        assertEq(ether_.pair, address(0));
        assertEq(ether_.fee, 500);
        assertEq(ether_.tickSpacing, 10);
        assertEq(ether_.at, m.poolManager);
        assertEq(ether_.id, keccak256(abi.encode(address(0), address(token), uint24(500), int24(10), address(0))));
        assertEq(ether_.tokenSide, 20_101_012_677_666_930, "token1 against ether, the tick and fee bits masked off");

        assertEq(r.pools[2].pair, m.usdc);
        assertEq(r.pools[2].liquidity, 0, "an empty pool is recorded with no depth");
        assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact), "the V3 pool paid the test balance");
        checker.log(r);

        assertEq(checker.depth(m.weth, m).length, 0, "WETH is not paired with itself, and has no pool here");
        assertEq(checker.depth(address(token), none).length, 0);
    }

    function test_marketsAreEthereumsOnly() public {
        CheckToken.Markets memory m = checker.markets();
        assertEq(m.v3Factory, address(0));
        vm.chainId(1);
        m = checker.markets();
        assertEq(m.v3Factory, MainnetAddresses.UNISWAP_V3_FACTORY);
        assertEq(m.poolManager, MainnetAddresses.POOL_MANAGER);
        assertEq(m.weth, MainnetAddresses.WETH);
        assertEq(m.usdc, MainnetAddresses.USDC);
    }

    // ---------------------------------------------------------------------
    // Verdicts and the report
    // ---------------------------------------------------------------------

    function _listable() internal pure returns (CheckToken.Report memory r) {
        r.decimalsAnswered = true;
        r.decimals = 18;
        r.transfers = CheckToken.Transfers.Exact;
    }

    function _verdict(CheckToken.Report memory r) internal view returns (CheckToken.Verdict verdict, string memory) {
        return checker.verdictOf(r);
    }

    function test_verdictOf() public view {
        CheckToken.Report memory r = _listable();
        (CheckToken.Verdict v,) = _verdict(r);
        assertEq(uint8(v), uint8(CheckToken.Verdict.Listable));

        r.decimals = 5;
        (v,) = _verdict(r);
        assertEq(uint8(v), uint8(CheckToken.Verdict.Refused));
        r.decimals = 19;
        (v,) = _verdict(r);
        assertEq(uint8(v), uint8(CheckToken.Verdict.Refused));
        r.decimals = 6;
        r.decimalsAnswered = false;
        (v,) = _verdict(r);
        assertEq(uint8(v), uint8(CheckToken.Verdict.Refused));

        CheckToken.Transfers[4] memory bad = [
            CheckToken.Transfers.Untested,
            CheckToken.Transfers.Failed,
            CheckToken.Transfers.Inexact,
            CheckToken.Transfers.Rebases
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            r = _listable();
            r.transfers = bad[i];
            string memory reason;
            (v, reason) = _verdict(r);
            assertEq(uint8(v), uint8(CheckToken.Verdict.Refused));
            assertEq(reason, checker.transferText(bad[i]));
        }

        r = _listable();
        r.powers = checker.DESTROY();
        string memory why;
        (v, why) = _verdict(r);
        assertEq(uint8(v), uint8(CheckToken.Verdict.Review), "a destroy without a blacklist is read by a person");
        assertEq(
            why,
            "it can destroy a holder's balance, though no blacklist was found: read the source for one under another name"
        );
        r.powers = checker.BLACKLIST() | checker.BURN_OTHERS();
        (v, why) = _verdict(r);
        assertEq(uint8(v), uint8(CheckToken.Verdict.Review), "a burnFrom may or may not need an allowance");
        r.powers = checker.BURN_OTHERS() | checker.MINT() | checker.PAUSE() | checker.UPGRADE();
        (v,) = _verdict(r);
        assertEq(uint8(v), uint8(CheckToken.Verdict.Listable), "everything else is recorded, not judged");
    }

    function test_texts() public view {
        assertEq(checker.powersText(0), "none found");
        assertEq(
            checker.powersText(type(uint256).max),
            "mint, pause, blacklist, destroy a holder's balance, burn from another account, upgrade, transfer callback (transferAndCall), roles (AccessControl)"
        );
        assertEq(checker.transferText(CheckToken.Transfers.Exact), "exact, and unchanged a day later");
        assertEq(checker.transferText(CheckToken.Transfers.Failed), "a transfer, approve or transferFrom failed");
        assertEq(checker.verdictText(CheckToken.Verdict.Listable), "listable");
        assertEq(checker.verdictText(CheckToken.Verdict.Review), "REVIEW");
        assertEq(checker.verdictText(CheckToken.Verdict.Refused), "REFUSED");
        assertEq(checker.pairName(address(0)), "ether");
        assertEq(checker.pairName(MainnetAddresses.WETH), "WETH");
        assertEq(checker.pairName(MainnetAddresses.USDC), "USDC");
        assertEq(checker.pairName(key), vm.toString(key));
    }

    /// @dev Every line `log` can print, from reports built to reach each.
    function test_logPrintsEveryKindOfReport() public {
        MockERC20 token = _token(18);
        CheckToken.Report memory r = _check(address(token));
        r.implementation = address(token);
        r.upgrader = key;
        r.admin = checker.classify(key);
        r.roleAdmin = checker.classify(address(new MockSafeOwner(3, 5, true)));
        r.registry = true;
        r.erc777 = true;
        r.erc1363 = true;
        r.pools = new CheckToken.Pool[](3);
        r.pools[0].pair = MainnetAddresses.WETH;
        r.pools[1].pair = address(0);
        r.pools[2].pair = MainnetAddresses.USDC;
        r.verdict = CheckToken.Verdict.Review;
        r.reason = "a reason";
        checker.log(r);
        r.decimalsAnswered = false;
        r.pools = new CheckToken.Pool[](0);
        checker.log(r);
        vm.chainId(1);
        checker.log(r);
    }

    // ---------------------------------------------------------------------
    // Holders and run
    // ---------------------------------------------------------------------

    function test_holderFor() public {
        address token = makeAddr("token");
        address other = makeAddr("other");
        string memory raw = string.concat(
            vm.toString(other), ":", vm.toString(key), " , ", vm.toString(token), ":", vm.toString(other)
        );
        assertEq(checker.holderFor("", token), address(0));
        assertEq(checker.holderFor(raw, token), other);
        assertEq(checker.holderFor(raw, key), address(0));
        string memory bad = vm.toString(token);
        vm.expectRevert(abi.encodeWithSelector(CheckToken.MalformedHolder.selector, bad));
        checker.holderFor(bad, token);
    }

    /// @dev CHECK names `ConfigureWeighted`'s lists, on chain 1 only, or addresses.
    function test_resolveTokens() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address[] memory parsed = checker.resolveTokens(string.concat(vm.toString(a), ", ", vm.toString(b)));
        assertEq(parsed.length, 2);
        assertEq(parsed[1], b);

        vm.expectRevert(abi.encodeWithSelector(ConfigureWeighted.MainnetListOffMainnet.selector, "wide"));
        checker.resolveTokens("wide");
        vm.chainId(1);
        ConfigureWeighted lists = new ConfigureWeighted();
        address[] memory first = checker.resolveTokens("default");
        address[] memory wide = checker.resolveTokens("wide");
        assertEq(first.length, lists.DEFAULT_COUNT());
        assertEq(first[0], MainnetAddresses.WETH);
        ConfigureWeighted.Entry[] memory entries = lists.wideMainnetList();
        assertEq(wide.length, entries.length);
        for (uint256 i = 0; i < wide.length; ++i) {
            assertEq(wide[i], entries[i].token);
        }
    }

    function test_run_readsTheEnvironment() public {
        MockERC20 listable = _token(18);
        MockFeeToken refused = new MockFeeToken();
        refused.mint(address(this), 1e24);
        address holder = makeAddr("holder");
        MockRebasingToken shares = new MockRebasingToken(2e18, 0);
        shares.mintShares(holder, 10e18);
        vm.setEnv(
            "CHECK",
            string.concat(
                vm.toString(address(listable)), ",", vm.toString(address(refused)), ",", vm.toString(address(shares))
            )
        );
        vm.setEnv("CHECK_HOLDERS", string.concat(vm.toString(address(shares)), ":", vm.toString(holder)));
        checker.run();
        assertEq(listable.balanceOf(checker.SENDER()), 0, "nothing the run simulated is left behind");
    }
}
