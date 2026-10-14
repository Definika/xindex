// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC1820Registry} from "@openzeppelin/contracts/interfaces/IERC1820Registry.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ConfigureWeighted} from "./ConfigureWeighted.s.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {ScriptUtils} from "./ScriptUtils.sol";
import {IAdminReads} from "./interfaces/IAdminReads.sol";
import {IPoolManagerStorage} from "./interfaces/IPoolManagerStorage.sol";
import {ISafeThreshold} from "./interfaces/ISafeThreshold.sol";
import {IUniswapV3FactoryRead} from "./interfaces/IUniswapV3FactoryRead.sol";
import {IUniswapV3PoolRead} from "./interfaces/IUniswapV3PoolRead.sol";

/// @notice The admission check of `design/2026-10-05-wide-asset-support.md`, section 2.1: one report per token for the
///         Safe's signers, run against an RPC before the token's listing is proposed. Read-only: it never broadcasts,
///         and what it simulates (a balance written into the token's storage, transfers between made-up accounts, a
///         day passing) is undone after each token.
///
///   CHECK=wide forge script script/CheckToken.s.sol --fork-url <mainnet rpc>
///   CHECK=<token,...> forge script script/CheckToken.s.sol --fork-url <any evm rpc>
///
/// What it checks, and what each finding does:
///   - Transfers: `transfer` and `transferFrom` on the fork, balances compared exactly, then a day later. A shortfall
///     or a surplus (fee-on-transfer, share rounding) refuses, and so does a balance that moves with time (rebasing).
///   - Hooks: an ERC777Token entry in the ERC-1820 registry, or ERC-1363 by ERC-165, refuses.
///   - Admin powers: the selectors of the token's runtime code and of its implementation's (EIP-1967, the older
///     zeppelinos and EIP-1822 slots, a beacon, an EIP-1167 clone), from the table in {powerOf}, and who holds them:
///     `owner()` or `getOwner()`, the proxy's admin or the beacon's owner, and an enumerable `DEFAULT_ADMIN_ROLE`,
///     each classified as a key, an EIP-7702 delegated key, a Safe, a timelock or another contract. All recorded; the
///     WBT rule refuses a token that can both blacklist a holder and destroy its balance
///     (design/2026-09-30-wbt-check.md). A blacklist with a burn from another account is left for review, because
///     OpenZeppelin's `burnFrom` spends the holder's allowance and only the source says whether this one does.
///   - Depth, on Ethereum: each Uniswap V3 pool against WETH and USDC at the four standard fees, and each hookless V4
///     pool against ether and USDC at the standard fee and tick spacing pairs, with the token within 2% of the pool's
///     price on either side from the liquidity active now. Recorded only. PancakeSwap's pools are not read.
///   - Supply: the token's symbol, decimals and on-chain `totalSupply`.
///
/// The selector scan is a heuristic: a power under a name the table does not list is missed, and a listed name says
/// nothing about who may call it. The depth figure is an approximation: it ignores the ticks between the price and the
/// band's edges, where liquidity can start or stop. Neither replaces reading the verified source before signing.
///
/// This script reads pool state off chain, to inform a human. No contract in src/ reads a price, and nothing here is
/// deployed.
///
/// Env:
///   CHECK          `default` or `wide`, the tokens of `ConfigureWeighted`'s Ethereum lists (chain 1 only), or
///                  comma-separated token addresses.
///   CHECK_HOLDERS  Optional comma-separated `token:holder` pairs: an account the transfer check may take the test
///                  balance from when the token's balance slot cannot be written (balances kept elsewhere, or shares).
///                  On Ethereum the token's own pools are tried after it.
contract CheckToken is Script {
    /// @notice What the transfer simulation found. The zero value is `Untested`, so a report never claims a check it
    ///         did not run.
    enum Transfers {
        Untested,
        Exact,
        Failed,
        Inexact,
        Rebases
    }

    /// @notice What kind of account holds a power.
    enum Kind {
        None,
        Key,
        DelegatedKey,
        Safe,
        Timelock,
        Contract
    }

    /// @notice The check's conclusion. The zero value is `Refused`, so nothing is listable by default.
    enum Verdict {
        Refused,
        Review,
        Listable
    }

    /// @notice An account that holds a power over the token, and what it is.
    /// @param account The account, or zero for none.
    /// @param kind What it is.
    /// @param threshold A Safe's signature threshold.
    /// @param signers A Safe's number of owners.
    /// @param delay A timelock's minimum delay, in seconds.
    struct Party {
        address account;
        Kind kind;
        uint256 threshold;
        uint256 signers;
        uint256 delay;
    }

    /// @notice Where depth is measured. All zero off Ethereum, where depth is skipped.
    struct Markets {
        address v3Factory;
        address poolManager;
        address weth;
        address usdc;
    }

    /// @notice One pool of the token, with its depth within 2% of its price.
    /// @param version 3 or 4.
    /// @param pair The other currency: WETH or USDC on V3, ether (zero) or USDC on V4.
    /// @param fee The pool's fee, in hundredths of a basis point.
    /// @param tickSpacing A V4 pool's tick spacing; zero on V3.
    /// @param at The V3 pool, or the PoolManager for a V4 pool.
    /// @param id A V4 pool's id; zero on V3.
    /// @param liquidity The liquidity active at the pool's price.
    /// @param tokenSide The token the pool holds within 2% of its price, in the token's raw units.
    /// @param bothSides Both currencies within 2% of the price, counted in the token's raw units at the pool's price.
    struct Pool {
        uint8 version;
        address pair;
        uint24 fee;
        int24 tickSpacing;
        address at;
        bytes32 id;
        uint128 liquidity;
        uint256 tokenSide;
        uint256 bothSides;
    }

    /// @notice Everything the check found for one token.
    struct Report {
        address token;
        string symbol;
        bool decimalsAnswered;
        uint8 decimals;
        uint256 totalSupply;
        Transfers transfers;
        bool registry;
        bool erc777;
        bool erc1363;
        address implementation;
        address upgrader;
        uint256 powers;
        Party owner;
        Party admin;
        Party roleAdmin;
        Pool[] pools;
        Verdict verdict;
        string reason;
    }

    // ---------------------------------------------------------------------
    // Admin powers, as bits of `Report.powers`
    // ---------------------------------------------------------------------

    uint256 public constant MINT = 1 << 0;
    uint256 public constant PAUSE = 1 << 1;
    uint256 public constant BLACKLIST = 1 << 2;
    uint256 public constant DESTROY = 1 << 3;
    uint256 public constant BURN_OTHERS = 1 << 4;
    uint256 public constant UPGRADE = 1 << 5;
    uint256 public constant CALLBACK = 1 << 6;
    uint256 public constant ROLES = 1 << 7;
    uint256 private constant POWER_COUNT = 8;

    // ---------------------------------------------------------------------
    // Where proxies keep their implementation and admin
    // ---------------------------------------------------------------------

    /// @dev EIP-1967: `keccak256("eip1967.proxy.implementation") - 1`, `...admin") - 1` and `...beacon") - 1`.
    bytes32 private constant EIP1967_IMPLEMENTATION =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant EIP1967_ADMIN = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 private constant EIP1967_BEACON = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    /// @dev OpenZeppelin's zeppelinos proxies before EIP-1967: `keccak256("org.zeppelinos.proxy.implementation")` and
    ///      `keccak256("org.zeppelinos.proxy.admin")`.
    bytes32 private constant ZOS_IMPLEMENTATION = 0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;
    bytes32 private constant ZOS_ADMIN = 0x10d6a54a4754c8869d6886b5f5d7fbfa5b4522237ea5c60d11bc4e7a1ff9390b;
    /// @dev EIP-1822: `keccak256("PROXIABLE")`.
    bytes32 private constant EIP1822_PROXIABLE = 0xc5f16f0fcc639fa48a6947836d9850f504798523bf8c9a3a87d5876cf622bcf7;
    /// @dev EIP-1167's minimal proxy: 10 bytes, the implementation's 20, then 15 more.
    bytes10 private constant EIP1167_PREFIX = 0x363d3d373d3d3d363d73;
    uint256 private constant EIP1167_LENGTH = 45;
    uint256 private constant EIP1167_TARGET_AT = 10;

    // ---------------------------------------------------------------------
    // Hook constants
    // ---------------------------------------------------------------------

    /// @notice The ERC-1820 registry, at the same address on every chain that has it (EIP-1820's keyless deployment).
    address public constant ERC1820_REGISTRY = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
    /// @dev `keccak256("ERC777Token")`, the interface an ERC-777 token registers for itself.
    bytes32 private constant ERC777_TOKEN = 0xac7fbab5f54a3ca8194167523c6753bfeb96a445279294b6125b68cce2177054;
    /// @dev ERC-1363's interface id, and ERC-165's own and its invalid one, which a compliant token answers false.
    bytes4 private constant ERC1363_INTERFACE = 0xb0202a11;
    bytes4 private constant ERC165_INTERFACE = 0x01ffc9a7;
    bytes4 private constant INVALID_INTERFACE = 0xffffffff;

    // ---------------------------------------------------------------------
    // Depth constants
    // ---------------------------------------------------------------------

    /// @dev Uniswap V4's PoolManager keeps its pools at this slot (StateLibrary's POOLS_SLOT), and a pool's liquidity
    ///      three slots after its packed slot0 (LIQUIDITY_OFFSET).
    uint256 private constant V4_POOLS_SLOT = 6;
    uint256 private constant V4_LIQUIDITY_OFFSET = 3;
    /// @dev Pools the check looks at: two pairs and four fee tiers on each version.
    uint256 private constant PAIRS = 2;
    uint256 private constant TIERS = 4;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant WAD = 1e18;
    /// @dev Per unit of liquidity, the token0 held from the price to 2% above it, in units of `L / sqrt(P)`:
    ///      `1 - 1 / sqrt(1.02)`, and the token1 held from 2% below it to the price, in units of `L * sqrt(P)`:
    ///      `1 - sqrt(0.98)`. Both to 18 decimals, rounded down.
    uint256 private constant UP_BAND = 9_852_457_023_325_690;
    uint256 private constant DOWN_BAND = 10_050_506_338_833_465;

    // ---------------------------------------------------------------------
    // The transfer simulation
    // ---------------------------------------------------------------------

    /// @notice The made-up accounts the transfer simulation moves the token between.
    address public constant SENDER = address(uint160(uint256(keccak256("xindex.check-token.sender"))));
    address public constant RECIPIENT = address(uint160(uint256(keccak256("xindex.check-token.recipient"))));
    address public constant SPENDER = address(uint160(uint256(keccak256("xindex.check-token.spender"))));
    address public constant PAYEE = address(uint160(uint256(keccak256("xindex.check-token.payee"))));
    /// @dev How long the simulation waits to see whether balances move on their own: a day, and its blocks.
    uint256 private constant WAIT = 1 days;
    uint256 private constant WAIT_BLOCKS = 7200;
    /// @dev The simulation moves one whole token, or this many raw units when the decimals are unknown or huge.
    uint256 private constant FALLBACK_AMOUNT = 1e18;
    uint8 private constant MAX_SCALED_DECIMALS = 36;
    uint256 private constant DECIMAL_BASE = 10;
    /// @dev Gas for each read and each simulated call; far more than any ERC-20 read or transfer needs.
    uint256 private constant READ_GAS = 300_000;
    uint256 private constant CALL_GAS = 1_000_000;
    /// @dev The answer bytes a read or a call keeps, in the scratch space below the free memory pointer.
    uint256 private constant ONE_WORD = 0x20;
    uint256 private constant TWO_WORDS = 0x40;
    /// @dev The listing policy's decimals, as ConfigureWeighted applies them.
    uint8 private constant MIN_DECIMALS = 6;
    uint8 private constant MAX_DECIMALS = 18;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice A CHECK_HOLDERS pair is not `token:holder`.
    error MalformedHolder(string pair);

    // ---------------------------------------------------------------------
    // Entry points
    // ---------------------------------------------------------------------

    /// @notice Reads CHECK and CHECK_HOLDERS, checks every token and logs its report, then the tokens the checks did
    ///         not refuse.
    function run() external {
        address[] memory tokens = resolveTokens(vm.envString("CHECK"));
        string memory holders = vm.envOr("CHECK_HOLDERS", string(""));
        Markets memory m = markets();
        string memory passed = "";
        for (uint256 i = 0; i < tokens.length; ++i) {
            Report memory r = check(tokens[i], holderFor(holders, tokens[i]), m);
            log(r);
            if (r.verdict == Verdict.Refused) continue;
            passed = string.concat(passed, bytes(passed).length == 0 ? "" : ",", vm.toString(r.token));
        }
        console2.log("Tokens the checks did not refuse (settle any marked REVIEW first):");
        console2.log(passed);
    }

    /// @notice CHECK's tokens: those of `ConfigureWeighted`'s `default` or `wide` list, which only chain 1 resolves, or
    ///         comma-separated addresses.
    function resolveTokens(string memory raw) public returns (address[] memory tokens) {
        ConfigureWeighted lists = new ConfigureWeighted();
        if (!ScriptUtils.same(raw, "default") && !ScriptUtils.same(raw, "wide")) {
            return lists.parseAddresses(raw);
        }
        ConfigureWeighted.Entry[] memory list = lists.resolveList(raw);
        tokens = new address[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            tokens[i] = list[i].token;
        }
    }

    /// @notice Where depth is measured on this chain: Uniswap on Ethereum, and nowhere elsewhere.
    function markets() public view returns (Markets memory m) {
        if (block.chainid == 1) {
            m = Markets({
                v3Factory: MainnetAddresses.UNISWAP_V3_FACTORY,
                poolManager: MainnetAddresses.POOL_MANAGER,
                weth: MainnetAddresses.WETH,
                usdc: MainnetAddresses.USDC
            });
        }
    }

    /// @notice The whole check of one token.
    /// @param token The token.
    /// @param holder An account the transfer check may take its test balance from, or zero.
    /// @param m Where to measure depth; all zero to skip it.
    /// @return r The report; `log` prints it.
    function check(address token, address holder, Markets memory m) public returns (Report memory r) {
        r.token = token;
        if (token.code.length == 0) {
            r.reason = "the token has no code";
            return r;
        }
        r.symbol = ScriptUtils.symbolOf(token);
        (r.decimalsAnswered, r.decimals) = ScriptUtils.decimalsOf(token);
        // forge-lint: disable-next-line(unused-return) a token with no total supply reports zero
        (, r.totalSupply) = _word(token, abi.encodeCall(IERC20.totalSupply, ()));
        (r.registry, r.erc777, r.erc1363) = hooksOf(token);
        (r.implementation, r.upgrader) = proxyOf(token);
        r.powers = powersOf(token.code) | powersOf(r.implementation.code);
        r.owner = classify(_ownerOf(token));
        r.admin = classify(r.upgrader);
        r.roleAdmin = classify(_roleAdminOf(token));
        r.pools = depth(token, m);
        uint256 amount =
            r.decimalsAnswered && r.decimals <= MAX_SCALED_DECIMALS ? DECIMAL_BASE ** r.decimals : FALLBACK_AMOUNT;
        r.transfers = transfersOf(token, amount, _holders(holder, r.pools));
        (r.verdict, r.reason) = verdictOf(r);
    }

    /// @notice The verdict of a report: refused for a token outside the whitelist policy's decimals, with transfers
    ///         that are not exact, with hooks, or under the WBT rule; for review when it can blacklist and burn from
    ///         another account; listable otherwise. Everything else a report holds is recorded, not judged.
    function verdictOf(Report memory r) public pure returns (Verdict, string memory) {
        if (!r.decimalsAnswered || r.decimals < MIN_DECIMALS || r.decimals > MAX_DECIMALS) {
            return (Verdict.Refused, "decimals outside the whitelist policy's 6 to 18");
        }
        if (r.transfers != Transfers.Exact) return (Verdict.Refused, transferText(r.transfers));
        if (r.erc777) return (Verdict.Refused, "registered as an ERC-777 token: transfer hooks");
        if (r.erc1363) return (Verdict.Refused, "ERC-1363 by ERC-165: transfer callbacks");
        bool blacklist = r.powers & BLACKLIST != 0;
        bool destroy = r.powers & DESTROY != 0;
        if (blacklist && destroy) {
            return (Verdict.Refused, "the WBT rule: it can blacklist a holder and destroy its balance");
        }
        if (destroy) {
            return (
                Verdict.Review,
                "it can destroy a holder's balance, though no blacklist was found: read the source for one under another name"
            );
        }
        if (blacklist && r.powers & BURN_OTHERS != 0) {
            return (
                Verdict.Review,
                "it can blacklist, and burn from another account: if that burn needs no allowance, the WBT rule refuses it"
            );
        }
        return (Verdict.Listable, "");
    }

    /// @notice The holder CHECK_HOLDERS names for `token`, or zero.
    /// @param raw Comma-separated `token:holder` pairs; empty for none.
    /// @param token The token to look up.
    function holderFor(string memory raw, address token) public pure returns (address) {
        if (bytes(raw).length == 0) return address(0);
        string[] memory pairs = vm.split(raw, ",");
        for (uint256 i = 0; i < pairs.length; ++i) {
            string[] memory fields = vm.split(vm.trim(pairs[i]), ":");
            if (fields.length != 2) revert MalformedHolder(pairs[i]);
            if (vm.parseAddress(fields[0]) == token) return vm.parseAddress(fields[1]);
        }
        return address(0);
    }

    // ---------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------

    /// @notice Simulates `transfer` and `transferFrom` and compares every balance exactly, then waits a day and
    ///         compares again. Everything it does to the chain's state is undone before it returns.
    /// @param token The token.
    /// @param amount The test balance to give SENDER.
    /// @param holders Accounts to take the test balance from, in order, when the token's balance slot cannot be written.
    function transfersOf(address token, uint256 amount, address[] memory holders) public returns (Transfers result) {
        uint256 snapshot = vm.snapshotState();
        result = _simulate(token, amount, holders);
        // forge-lint: disable-next-line(unused-return) the snapshot was taken above, so reverting to it cannot fail
        vm.revertToStateAndDelete(snapshot);
    }

    function _simulate(address token, uint256 amount, address[] memory holders) private returns (Transfers) {
        uint256 funded = _fund(token, amount, holders);
        uint256 half = funded / 2;
        if (half == 0) return Transfers.Untested;
        uint256 recipientBefore = _balance(token, RECIPIENT);
        uint256 payeeBefore = _balance(token, PAYEE);
        bool moved = _calls(SENDER, token, abi.encodeCall(IERC20.transfer, (RECIPIENT, half)))
            && _calls(SENDER, token, abi.encodeCall(IERC20.approve, (SPENDER, half)))
            && _calls(SPENDER, token, abi.encodeCall(IERC20.transferFrom, (SENDER, PAYEE, half)));
        if (!moved) return Transfers.Failed;
        if (!_exact(token, funded, half, recipientBefore, payeeBefore)) return Transfers.Inexact;
        vm.warp(block.timestamp + WAIT);
        vm.roll(block.number + WAIT_BLOCKS);
        if (!_exact(token, funded, half, recipientBefore, payeeBefore)) return Transfers.Rebases;
        return Transfers.Exact;
    }

    /// @dev Whether SENDER holds exactly `funded` less two halves, and RECIPIENT and PAYEE a half more each.
    function _exact(address token, uint256 funded, uint256 half, uint256 recipientBefore, uint256 payeeBefore)
        private
        view
        returns (bool)
    {
        return _balance(token, SENDER) + 2 * half == funded && _balance(token, RECIPIENT) == recipientBefore + half
            && _balance(token, PAYEE) == payeeBefore + half;
    }

    /// @dev Gives SENDER a test balance: `amount`, written into the token's balance slot, or what a holder sends.
    ///      Returns SENDER's balance, zero when neither worked.
    function _fund(address token, uint256 amount, address[] memory holders) private returns (uint256) {
        if (_writeBalance(token, SENDER, amount)) return amount;
        for (uint256 i = 0; i < holders.length; ++i) {
            uint256 has = _balance(token, holders[i]);
            bytes memory send = abi.encodeCall(IERC20.transfer, (SENDER, Math.min(has, amount)));
            if (has != 0 && _calls(holders[i], token, send)) return _balance(token, SENDER);
        }
        return 0;
    }

    /// @dev Finds the slot `balanceOf(account)` reads and writes `amount` there, as forge-std's `deal` does: each slot
    ///      the read touched is tried, and put back unless the balance then reads `amount`. Through a proxy the slots
    ///      are the proxy's own, so this works there too; it fails for balances kept in another contract or as shares.
    function _writeBalance(address token, address account, uint256 amount) private returns (bool) {
        vm.record();
        _balance(token, account);
        // forge-lint: disable-next-line(unused-return) a read finds the slot; the writes are none
        (bytes32[] memory reads,) = vm.accesses(token);
        vm.stopRecord();
        for (uint256 i = 0; i < reads.length; ++i) {
            bytes32 before = vm.load(token, reads[i]);
            vm.store(token, reads[i], bytes32(amount));
            if (_balance(token, account) == amount) return true;
            vm.store(token, reads[i], before);
        }
        return false;
    }

    /// @dev `token.balanceOf(account)`, or zero when the call fails or answers short.
    function _balance(address token, address account) private view returns (uint256 balance) {
        // forge-lint: disable-next-line(unused-return) a failed read is a zero balance
        (, balance) = _word(token, abi.encodeCall(IERC20.balanceOf, (account)));
    }

    /// @dev Calls `token` as `from`; true when the call succeeded and answered nothing (Tether's style) or true. The call
    ///      gets CALL_GAS and only its answer's first word is kept: an old token's failed `assert` or `throw` burns all
    ///      the gas it is given, which would otherwise end the whole run.
    function _calls(address from, address token, bytes memory data) private returns (bool) {
        bool ok;
        uint256 size;
        uint256 word;
        vm.prank(from);
        // Solidity copies a call's whole answer into memory; this keeps one word of it, in scratch space.
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            ok := call(CALL_GAS, token, 0, add(data, ONE_WORD), mload(data), 0, ONE_WORD)
            size := returndatasize()
            word := mload(0)
        }
        return ok && (size == 0 || (size >= ScriptUtils.WORD && word == 1));
    }

    /// @dev The holders to try: the one named, then every pool found, each of which holds the token.
    function _holders(address holder, Pool[] memory pools) private pure returns (address[] memory holders) {
        holders = new address[](pools.length + 1);
        holders[0] = holder;
        for (uint256 i = 0; i < pools.length; ++i) {
            holders[i + 1] = pools[i].at;
        }
    }

    // ---------------------------------------------------------------------
    // Hooks
    // ---------------------------------------------------------------------

    /// @notice Whether the ERC-1820 registry exists here, whether `token` registered itself as an ERC-777 token there,
    ///         and whether it declares ERC-1363 by ERC-165. The ERC-165 answer counts only from a token that answers
    ///         ERC-165 itself true and the invalid id false, as the standard's detection requires.
    function hooksOf(address token) public view returns (bool registry, bool erc777, bool erc1363) {
        registry = ERC1820_REGISTRY.code.length != 0;
        if (registry) {
            bytes memory query = abi.encodeCall(IERC1820Registry.getInterfaceImplementer, (token, ERC777_TOKEN));
            erc777 = _addressAnswer(ERC1820_REGISTRY, query) != address(0);
        }
        erc1363 = _supports(token, ERC165_INTERFACE) && !_supports(token, INVALID_INTERFACE)
            && _supports(token, ERC1363_INTERFACE);
    }

    function _supports(address token, bytes4 interfaceId) private view returns (bool) {
        (bool answered, uint256 word) = _word(token, abi.encodeCall(IERC165.supportsInterface, (interfaceId)));
        return answered && word == 1;
    }

    // ---------------------------------------------------------------------
    // Admin powers
    // ---------------------------------------------------------------------

    /// @notice The implementation behind `token` and the account that can upgrade it, or zeros for a token that is no
    ///         proxy this check knows. EIP-1967 first, then the zeppelinos slots, EIP-1822, a beacon (whose owner
    ///         upgrades), and an EIP-1167 clone (which nobody upgrades). A UUPS proxy has no admin slot: its upgrade is
    ///         the implementation's `upgradeTo`, held by the token's own owner or roles.
    function proxyOf(address token) public view returns (address implementation, address upgrader) {
        implementation = _slotAddress(token, EIP1967_IMPLEMENTATION);
        if (implementation != address(0)) return (implementation, _adminOf(token, EIP1967_ADMIN));
        implementation = _slotAddress(token, ZOS_IMPLEMENTATION);
        if (implementation != address(0)) return (implementation, _adminOf(token, ZOS_ADMIN));
        implementation = _slotAddress(token, EIP1822_PROXIABLE);
        if (implementation != address(0)) return (implementation, address(0));
        address beacon = _slotAddress(token, EIP1967_BEACON);
        if (beacon != address(0)) {
            return (
                _addressAnswer(beacon, abi.encodeCall(IAdminReads.implementation, ())),
                _addressAnswer(beacon, abi.encodeCall(IAdminReads.owner, ()))
            );
        }
        bytes memory code = token.code;
        if (code.length == EIP1167_LENGTH && _pushed(code, 0, EIP1167_TARGET_AT) == uint80(EIP1167_PREFIX)) {
            return (_addressIn(code, EIP1167_TARGET_AT), address(0));
        }
    }

    /// @dev A proxy's admin: the admin slot's, or the `proxyOwner()` of an OwnedUpgradeabilityProxy (OKB's), which
    ///      keeps its owner in a slot of its own.
    function _adminOf(address token, bytes32 adminSlot) private view returns (address admin) {
        admin = _slotAddress(token, adminSlot);
        if (admin == address(0)) admin = _addressAnswer(token, abi.encodeCall(IAdminReads.proxyOwner, ()));
    }

    /// @notice The admin powers whose selectors `code` pushes, as a dispatcher compares them (PUSH1 to PUSH4) or as a
    ///         bytes4 constant left-aligned in a PUSH32 (a `msg.sig` comparison, OpenZeppelin's transparent proxy).
    ///         Every push's data is skipped, so data never reads as an instruction.
    function powersOf(bytes memory code) public pure returns (uint256 powers) {
        for (uint256 i = 0; i < code.length; ++i) {
            uint256 op = uint8(code[i]);
            // PUSH1 is 0x60 and PUSH32 0x7f; nothing else carries data.
            if (op < 0x60 || op > 0x7f) continue;
            uint256 size = op - 0x5f;
            uint256 value = _pushed(code, i + 1, size);
            if (size == ScriptUtils.WORD && value << 32 == 0) value >>= 224;
            powers |= powerOf(value);
            i += size;
        }
    }

    /// @notice The power a selector names, or zero. This is the one selector table, and each line names the contract
    ///         the name comes from. It is a heuristic: a power under another name is missed, and a name here does not
    ///         prove who may call it. A selector the token calls out counts as well as one it answers: MiniMe's
    ///         `onTransfer` is a blacklist because the token asks its controller to approve every transfer, so a
    ///         controller can refuse any holder's.
    function powerOf(uint256 selector) public pure returns (uint256) {
        if (
            selector == 0x40c10f19 // mint(address,uint256): OpenZeppelin's minter pattern, most minting tokens
                || selector == 0xa0712d68 // mint(uint256): BEP-20 and Binance-Peg tokens, which mint to the owner
                || selector == 0xcc872b66 // issue(uint256): Tether (USDT)
                || selector == 0x449a52f8 // mintTo(address,uint256)
                || selector == 0xb921e163 // increaseSupply(uint256): Paxos (USDP, PAXG)
                || selector == 0x8c2a993e // bridgeMint(address,uint256): Arbitrum's standard gateway tokens
                || selector == 0x18bf5077 // crosschainMint(address,uint256): ERC-7802
                || selector == 0x827f32c0 // generateTokens(address,uint256): MiniMe tokens (LEO), by the controller
                || selector == 0xbe5ddb99 // mintInflation(address,uint256): Worldcoin (WLD)
                || selector == 0x085624ed // mintOnce(address[],uint256[]): Worldcoin (WLD)
                || selector == 0x4054b92b // voteForMinting(...): TON's bridge token, minted on its oracles' votes
        ) {
            return MINT;
        }
        if (
            selector == 0x8456cb59 // pause(): OpenZeppelin's Pausable, Tether, WBTC
                || selector == 0x3f4ba83a // unpause()
                || selector == 0x5c975abb // paused(): OpenZeppelin's Pausable reports it
                || selector == 0xf41e60c5 // enableTransfers(bool): MiniMe tokens (LEO)
                || selector == 0x967f1cc6 // ownerPause(): World Liberty Financial (WLFI)
                || selector == 0xd4593872 // guardianPause(): World Liberty Financial (WLFI)
                || selector == 0xe36c62a2 // resetMode(): GateChainToken (GT), which stops every transfer
        ) {
            return PAUSE;
        }
        if (
            selector == 0x0ecb93c0 // addBlackList(address): Tether
                || selector == 0xf9f92be4 // blacklist(address): Circle's FiatToken (USDC)
                || selector == 0x8d1fdf2f // freeze(address): Paxos
                || selector == 0x2d5a5d34 // blacklistAccount(address,bool): WhiteBIT's WBT
                || selector == 0x44337ea1 // addToBlacklist(address)
                || selector == 0x9cfe42da // addBlacklist(address)
                || selector == 0x417c73a7 // addToBlackList(address)
                || selector == 0x153b0d1e // setBlacklist(address,bool)
                || selector == 0x68092bd9 // setBlackList(address,bool)
                || selector == 0x9155e083 // updateBlacklist(address,bool)
                || selector == 0xf3290d75 // blacklistAddress(address)
                || selector == 0xf26c159f // freezeAccount(address)
                || selector == 0xe724529c // freezeAccount(address,bool)
                || selector == 0x51e946d5 // freezeAddress(address)
                || selector == 0x3c7c9b90 // addToBlockedList(address)
                || selector == 0x7c0a893d // blockAccount(address)
                || selector == 0x47a64f44 // lockAccount(address)
                || selector == 0xe1dfc884 // ownerSetBlacklistStatus(address,bool): World Liberty Financial (WLFI)
                || selector == 0x5aa42d12 // guardianSetBlacklistStatus(address,bool): World Liberty Financial (WLFI)
                || selector == 0x404e5129 // blacklist(address,bool): Pepe (PEPE), under a renounced owner
                || selector == 0xfe575a87 // isBlacklisted(address): a blacklist's view (WBT, WLFI)
                || selector == 0xe47d6060 // isBlackListed(address): a blacklist's view (Tether)
                || selector == 0x16c02129 // blacklists(address): a blacklist's view (PEPE)
                || selector == 0xe5839836 // isFrozen(address): a freeze list's view (Paxos)
                || selector == 0x4a393149 // onTransfer(address,address,uint256): MiniMe (LEO) asks its controller
        ) {
            return BLACKLIST;
        }
        if (
            selector == 0xf3bdc228 // destroyBlackFunds(address): Tether, WhiteBIT's WBT
                || selector == 0xe2f72f03 // wipeFrozenAddress(address): Paxos
                || selector == 0xbd7243f6 // wipeBlacklistedAccount(address): TrueUSD
                || selector == 0x0e27a385 // destroyBlockedFunds(address)
                || selector == 0x7c00899d // burnFrozen(address)
                || selector == 0x47298f82 // confiscate(address,uint256)
                || selector == 0xeb9253c0 // seize(address,uint256)
                || selector == 0x33bebb77 // forceTransfer(address,address,uint256)
                || selector == 0xd3ce77fe // destroyTokens(address,uint256): MiniMe (LEO), by the controller
                || selector == 0x7df9a674 // ownerReallocateFrom(address,address,uint256): WLFI, burns from any holder
                || selector == 0x7adf1239 // ownerBatchReallocateFrom(address[],address[],uint256[]): WLFI, the same
                || selector == 0xac9fe421 // setSuperOperator(address,bool): SAND, operators that need no allowance (CF-4)
        ) {
            return DESTROY;
        }
        if (
            selector == 0x79cc6790 // burnFrom(address,uint256): OpenZeppelin's spends an allowance; some need none
                || selector == 0x9dc29fac // burn(address,uint256): minter and bridge burns
                || selector == 0x74f4f547 // bridgeBurn(address,uint256): Arbitrum's standard gateway tokens
                || selector == 0x2b8c49e3 // crosschainBurn(address,uint256): ERC-7802
                || selector == 0x1dd319cb // burnFor(address,uint256): The Sandbox (SAND), a super operator's burn (CF-4)
        ) {
            return BURN_OTHERS;
        }
        if (
            selector == 0x3659cfe6 // upgradeTo(address): OpenZeppelin's proxies and UUPS
                || selector == 0x4f1ef286 // upgradeToAndCall(address,bytes): OpenZeppelin's proxies and UUPS
                || selector == 0x0753c30c // deprecate(address): Tether, which then forwards every call
        ) {
            return UPGRADE;
        }
        if (
            selector == 0x4000aea0 // transferAndCall(address,uint256,bytes): ERC-677 (LINK) and ERC-1363
                || selector == 0x1296ee62 // transferAndCall(address,uint256): ERC-1363
        ) {
            return CALLBACK;
        }
        if (selector == 0x91d14854) return ROLES; // hasRole(bytes32,address): OpenZeppelin's AccessControl
        return 0;
    }

    /// @notice What `account` is: none, a key, a key delegated under EIP-7702, a Safe (threshold and owners), a
    ///         timelock (OpenZeppelin's `getMinDelay`, or a `delay` as Compound's and Maker's have), or another contract.
    function classify(address account) public view returns (Party memory party) {
        party.account = account;
        if (account == address(0)) return party;
        bytes memory code = account.code;
        if (code.length == 0) {
            party.kind = Kind.Key;
            return party;
        }
        if (ScriptUtils.isDelegatedAccount(code)) {
            party.kind = Kind.DelegatedKey;
            return party;
        }
        (bool answered, uint256 word) = _word(account, abi.encodeCall(ISafeThreshold.getThreshold, ()));
        if (answered) {
            party.kind = Kind.Safe;
            party.threshold = word;
            party.signers = _arrayLength(account, abi.encodeCall(ISafeThreshold.getOwners, ()));
            return party;
        }
        (answered, word) = _word(account, abi.encodeCall(IAdminReads.getMinDelay, ()));
        if (!answered) (answered, word) = _word(account, abi.encodeCall(IAdminReads.delay, ()));
        party.kind = answered ? Kind.Timelock : Kind.Contract;
        party.delay = word;
    }

    /// @dev `owner()`, or BEP-20's `getOwner()`, or a MiniMe token's `controller()`, or The Sandbox's `getAdmin()`: the
    ///      first that answers. An admin behind a getter none of these names is reported as no owner (CF-4).
    function _ownerOf(address token) private view returns (address owner) {
        owner = _addressAnswer(token, abi.encodeCall(IAdminReads.owner, ()));
        if (owner == address(0)) owner = _addressAnswer(token, abi.encodeCall(IAdminReads.getOwner, ()));
        if (owner == address(0)) owner = _addressAnswer(token, abi.encodeCall(IAdminReads.controller, ()));
        if (owner == address(0)) owner = _addressAnswer(token, abi.encodeCall(IAdminReads.getAdmin, ()));
    }

    /// @dev The first holder of AccessControl's DEFAULT_ADMIN_ROLE, when the roles are enumerable.
    function _roleAdminOf(address token) private view returns (address) {
        return _addressAnswer(token, abi.encodeCall(IAdminReads.getRoleMember, (bytes32(0), 0)));
    }

    // ---------------------------------------------------------------------
    // Depth
    // ---------------------------------------------------------------------

    /// @notice Every initialized pool of `token` among the standard ones: V3 against WETH and USDC at fees of 0.01%,
    ///         0.05%, 0.3% and 1%, and hookless V4 against ether and USDC at the same fees with tick spacings of 1, 10,
    ///         60 and 200. None when `m` names no market.
    function depth(address token, Markets memory m) public view returns (Pool[] memory pools) {
        Pool[] memory found = new Pool[](2 * PAIRS * TIERS);
        uint256 count = _v3Pools(token, m, found);
        count = _v4Pools(token, m, found, count);
        pools = new Pool[](count);
        for (uint256 i = 0; i < count; ++i) {
            pools[i] = found[i];
        }
    }

    /// @dev Adds `token`'s initialized V3 pools to `found`; returns how many.
    function _v3Pools(address token, Markets memory m, Pool[] memory found) private view returns (uint256 count) {
        if (m.v3Factory == address(0)) return 0;
        address[PAIRS] memory pairs = [m.weth, m.usdc];
        for (uint256 p = 0; p < PAIRS; ++p) {
            for (uint256 f = 0; f < TIERS && pairs[p] != token; ++f) {
                address pool = IUniswapV3FactoryRead(m.v3Factory).getPool(token, pairs[p], _fee(f));
                if (pool == address(0)) continue;
                // forge-lint: disable-next-line(unused-return) only the price is needed
                (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolRead(pool).slot0();
                if (sqrtPriceX96 == 0) continue;
                Pool memory found3 = Pool({
                    version: 3,
                    pair: pairs[p],
                    fee: _fee(f),
                    tickSpacing: 0,
                    at: pool,
                    id: bytes32(0),
                    liquidity: IUniswapV3PoolRead(pool).liquidity(),
                    tokenSide: 0,
                    bothSides: 0
                });
                found[count++] = _withBand(found3, token, sqrtPriceX96);
            }
        }
    }

    /// @dev Adds `token`'s initialized hookless V4 pools to `found` after its first `count`; returns the new count.
    function _v4Pools(address token, Markets memory m, Pool[] memory found, uint256 count)
        private
        view
        returns (uint256)
    {
        if (m.poolManager == address(0)) return count;
        address[PAIRS] memory pairs = [address(0), m.usdc];
        for (uint256 p = 0; p < PAIRS; ++p) {
            for (uint256 f = 0; f < TIERS && pairs[p] != token; ++f) {
                Pool memory pool = _v4Pool(token, pairs[p], f, m.poolManager);
                if (pool.version != 0) found[count++] = pool;
            }
        }
        return count;
    }

    /// @dev The hookless V4 pool of `token` and `pair` at the standard tier `tier`, read as v4's StateLibrary reads
    ///      it; version zero when it is not initialized.
    function _v4Pool(address token, address pair, uint256 tier, address manager)
        private
        view
        returns (Pool memory pool)
    {
        (address currency0, address currency1) = token < pair ? (token, pair) : (pair, token);
        bytes32 id = keccak256(abi.encode(currency0, currency1, _fee(tier), _spacing(tier), address(0)));
        bytes32 state = keccak256(abi.encodePacked(id, V4_POOLS_SLOT));
        // The packed slot0 keeps the price in its low 160 bits, and the liquidity slot the liquidity in its low 128.
        uint160 sqrtPriceX96 = SafeCast.toUint160(uint256(IPoolManagerStorage(manager).extsload(state)) % (1 << 160));
        if (sqrtPriceX96 == 0) return pool;
        uint256 liquidityWord =
            uint256(IPoolManagerStorage(manager).extsload(bytes32(uint256(state) + V4_LIQUIDITY_OFFSET)));
        pool = Pool({
            version: 4,
            pair: pair,
            fee: _fee(tier),
            tickSpacing: _spacing(tier),
            at: manager,
            id: id,
            liquidity: SafeCast.toUint128(liquidityWord % (1 << 128)),
            tokenSide: 0,
            bothSides: 0
        });
        pool = _withBand(pool, token, sqrtPriceX96);
    }

    /// @dev The standard fee tiers, 0.01%, 0.05%, 0.3% and 1%, and V4's tick spacing for each.
    function _fee(uint256 tier) private pure returns (uint24) {
        return [uint24(100), 500, 3000, 10_000][tier];
    }

    function _spacing(uint256 tier) private pure returns (int24) {
        return [int24(1), int24(10), int24(60), int24(200)][tier];
    }

    /// @dev `pool` with its band amounts filled in.
    function _withBand(Pool memory pool, address token, uint160 sqrtPriceX96) private pure returns (Pool memory) {
        (pool.tokenSide, pool.bothSides) = bandAmounts(pool.liquidity, sqrtPriceX96, token < pool.pair);
        return pool;
    }

    /// @notice What `liquidity` holds within 2% of the price `sqrtPriceX96`, in the token's raw units: the token itself
    ///         (token0 above the price, token1 below it), and both sides, the other currency counted at the price. An
    ///         approximation: it assumes the liquidity active now spans the whole band.
    /// @param liquidity The liquidity active at the price.
    /// @param sqrtPriceX96 The square root of token1 per token0, in Q64.96; not zero.
    /// @param tokenIsToken0 Whether the token is the pool's token0.
    function bandAmounts(uint128 liquidity, uint160 sqrtPriceX96, bool tokenIsToken0)
        public
        pure
        returns (uint256 tokenSide, uint256 bothSides)
    {
        if (tokenIsToken0) {
            uint256 perUnit0 = Math.mulDiv(liquidity, Q96, sqrtPriceX96);
            return (Math.mulDiv(perUnit0, UP_BAND, WAD), Math.mulDiv(perUnit0, UP_BAND + DOWN_BAND, WAD));
        }
        uint256 perUnit1 = Math.mulDiv(liquidity, sqrtPriceX96, Q96);
        return (Math.mulDiv(perUnit1, DOWN_BAND, WAD), Math.mulDiv(perUnit1, UP_BAND + DOWN_BAND, WAD));
    }

    // ---------------------------------------------------------------------
    // The report
    // ---------------------------------------------------------------------

    /// @notice Logs `r` for the Safe's signers.
    function log(Report memory r) public view {
        console2.log(
            string.concat("==== ", r.symbol, " ", vm.toString(r.token), " on chain ", vm.toString(block.chainid))
        );
        if (r.token.code.length != 0) _logFindings(r);
        string memory reason = bytes(r.reason).length == 0 ? "" : string.concat(": ", r.reason);
        console2.log(string.concat("verdict: ", verdictText(r.verdict), reason));
    }

    function _logFindings(Report memory r) private view {
        console2.log(
            string.concat(
                "decimals ",
                r.decimalsAnswered ? vm.toString(r.decimals) : "unanswered",
                "; totalSupply ",
                _amount(r, r.totalSupply)
            )
        );
        console2.log(string.concat("transfers: ", transferText(r.transfers)));
        console2.log(
            string.concat(
                "hooks: ERC-777 ",
                r.registry ? _yesNo(r.erc777) : "unknown, no ERC-1820 registry here",
                "; ERC-1363 ",
                _yesNo(r.erc1363)
            )
        );
        if (r.implementation != address(0)) {
            string memory upgrader = r.upgrader == address(0)
                ? "no admin slot: a UUPS proxy's own owner or roles upgrade it, and a clone cannot be upgraded"
                : describe(r.admin);
            console2.log(
                string.concat("proxy: implementation ", vm.toString(r.implementation), "; upgraded by ", upgrader)
            );
        }
        console2.log(
            string.concat("powers (a selector scan, a heuristic: read the verified source): ", powersText(r.powers))
        );
        console2.log(string.concat("owner: ", describe(r.owner)));
        if (r.roleAdmin.account != address(0)) {
            console2.log(string.concat("DEFAULT_ADMIN_ROLE: ", describe(r.roleAdmin)));
        }
        _logDepth(r);
    }

    function _logDepth(Report memory r) private view {
        console2.log(
            "depth within 2 percent of each pool's price, from the liquidity active now (ignores tick crossings):"
        );
        if (r.pools.length == 0) {
            console2.log(
                block.chainid == 1 ? "  no standard V3 pool or hookless V4 pool" : "  measured on Ethereum only"
            );
        }
        for (uint256 i = 0; i < r.pools.length; ++i) {
            Pool memory p = r.pools[i];
            console2.log(
                string.concat(
                    "  V",
                    vm.toString(p.version),
                    " against ",
                    pairName(p.pair),
                    " fee ",
                    vm.toString(p.fee),
                    ": the token ",
                    _amount(r, p.tokenSide),
                    "; both sides ",
                    _amount(r, p.bothSides)
                )
            );
        }
    }

    /// @notice `party` in words, following a contract's `owner()` one step, as a ProxyAdmin's.
    function describe(Party memory party) public view returns (string memory text) {
        if (party.kind == Kind.None) return "none";
        text = string.concat(vm.toString(party.account), ", ", kindText(party));
        if (party.kind != Kind.Contract) return text;
        address next = _addressAnswer(party.account, abi.encodeCall(IAdminReads.owner, ()));
        if (next != address(0)) {
            text = string.concat(text, " whose owner() is ", vm.toString(next), ", ", kindText(classify(next)));
        }
    }

    /// @notice What kind of account `party` is, in words.
    function kindText(Party memory party) public pure returns (string memory) {
        if (party.kind == Kind.Key) return "an externally owned key";
        if (party.kind == Kind.DelegatedKey) return "a key delegated under EIP-7702";
        if (party.kind == Kind.Safe) {
            return string.concat("a Safe, ", vm.toString(party.threshold), " of ", vm.toString(party.signers));
        }
        if (party.kind == Kind.Timelock) {
            return string.concat("a timelock, minimum delay ", vm.toString(party.delay), " s");
        }
        if (party.kind == Kind.Contract) return "a contract";
        return "none";
    }

    /// @notice The powers in `powers`, in words.
    function powersText(uint256 powers) public pure returns (string memory text) {
        string[POWER_COUNT] memory names = [
            "mint",
            "pause",
            "blacklist",
            "destroy a holder's balance",
            "burn from another account",
            "upgrade",
            "transfer callback (transferAndCall)",
            "roles (AccessControl)"
        ];
        for (uint256 i = 0; i < POWER_COUNT; ++i) {
            if (powers & (1 << i) == 0) continue;
            text = bytes(text).length == 0 ? names[i] : string.concat(text, ", ", names[i]);
        }
        if (bytes(text).length == 0) text = "none found";
    }

    /// @notice What the transfer simulation found, in words.
    function transferText(Transfers transfers) public pure returns (string memory) {
        if (transfers == Transfers.Exact) return "exact, and unchanged a day later";
        if (transfers == Transfers.Failed) return "a transfer, approve or transferFrom failed";
        if (transfers == Transfers.Inexact) {
            return "moved another amount than asked: fee-on-transfer or share rounding";
        }
        if (transfers == Transfers.Rebases) return "balances moved by themselves within a day: rebasing";
        return "untested: no balance slot found and no holder paid; name one in CHECK_HOLDERS";
    }

    /// @notice The verdict, in words.
    function verdictText(Verdict verdict) public pure returns (string memory) {
        if (verdict == Verdict.Listable) return "listable";
        if (verdict == Verdict.Review) return "REVIEW";
        return "REFUSED";
    }

    /// @notice A pool's other currency, by name when it is ether or one of Ethereum's WETH and USDC.
    function pairName(address pair) public pure returns (string memory) {
        if (pair == address(0)) return "ether";
        if (pair == MainnetAddresses.WETH) return "WETH";
        if (pair == MainnetAddresses.USDC) return "USDC";
        return vm.toString(pair);
    }

    function _yesNo(bool yes) private pure returns (string memory) {
        return yes ? "yes" : "no";
    }

    /// @dev `raw` in raw units, and in whole tokens when the decimals are inside the policy's range.
    function _amount(Report memory r, uint256 raw) private pure returns (string memory) {
        if (!r.decimalsAnswered || r.decimals > 18) return vm.toString(raw);
        return string.concat(vm.toString(raw), " (", vm.toString(raw / DECIMAL_BASE ** r.decimals), " whole)");
    }

    // ---------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------

    /// @dev A static call of `target` with READ_GAS, keeping the first two words of its answer. The gas is bounded
    ///      because a failed static call into a fallback that writes (WETH's `deposit`) or an old token's `throw` burns
    ///      all it is given, which would end the run; the answer is bounded so no answer can be too large to copy.
    function _read(address target, bytes memory query)
        private
        view
        returns (bool ok, uint256 size, uint256 first, uint256 second)
    {
        // Solidity copies a call's whole answer into memory; this keeps two words of it, in scratch space.
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            mstore(0, 0)
            mstore(ONE_WORD, 0)
            ok := staticcall(READ_GAS, target, add(query, ONE_WORD), mload(query), 0, TWO_WORDS)
            size := returndatasize()
            first := mload(0)
            second := mload(ONE_WORD)
        }
    }

    /// @dev The first word `target` answers `query` with. The answer is checked before it is read, so a missing
    ///      function, a revert or a short answer is no answer rather than a revert of the run.
    function _word(address target, bytes memory query) private view returns (bool answered, uint256 word) {
        (bool ok, uint256 size, uint256 first,) = _read(target, query);
        answered = ok && size >= ScriptUtils.WORD;
        if (answered) word = first;
    }

    /// @dev The address `target` answers `query` with, or zero for no answer or a word that is not an address.
    function _addressAnswer(address target, bytes memory query) private view returns (address) {
        // forge-lint: disable-next-line(unused-return) no answer reads as a zero word, so as no address
        (, uint256 word) = _word(target, query);
        return _toAddress(word);
    }

    /// @dev The address in `target`'s storage `slot`, or zero for a word that is not an address.
    function _slotAddress(address target, bytes32 slot) private view returns (address) {
        return _toAddress(uint256(vm.load(target, slot)));
    }

    function _toAddress(uint256 word) private pure returns (address) {
        return word >> 160 == 0 ? address(SafeCast.toUint160(word)) : address(0);
    }

    /// @dev The length of the address array `target` answers `query` with, or zero for no answer.
    function _arrayLength(address target, bytes memory query) private view returns (uint256) {
        (bool ok, uint256 size,, uint256 second) = _read(target, query);
        return ok && size >= 2 * ScriptUtils.WORD ? second : 0;
    }

    /// @dev The `size` bytes of `code` from `at`, big-endian, stopping at its end (a push cut off by the end of the code).
    function _pushed(bytes memory code, uint256 at, uint256 size) private pure returns (uint256 value) {
        for (uint256 j = 0; j < size && at + j < code.length; ++j) {
            value = value << 8 | uint8(code[at + j]);
        }
    }

    /// @dev The address in `code`'s 20 bytes from `at`.
    function _addressIn(bytes memory code, uint256 at) private pure returns (address) {
        return address(SafeCast.toUint160(_pushed(code, at, 20)));
    }
}
