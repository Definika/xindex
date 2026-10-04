// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHybridIndexFactory} from "../src/interfaces/IHybridIndexFactory.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice Adds vault chains and their coins to the hybrid factory through its timelock: first a chain with its vault
///         and state verifier (`proposeChain`), then, once the chain is registered, each coin it holds
///         (`proposeVaultListing`). Every entry is checked against the factory first, and anything the factory would
///         refuse is skipped with its reason, so a Safe batch never fails on one call (CR-I38). A proposal that nothing
///         on chain says was vetoed is made only when named, as `ConfigureWhitelist` does (RT-06, XA-11): a chain never
///         registered only when LIST_CHAINS names it, a coin never listed only when LIST_COINS names it, a delisted coin
///         only when RELIST_COINS names it, and a registered chain's new state verifier, a 30-day rotation (FAC-1), only
///         when ROTATE names it. A routine run therefore never proposes again what the guardian cancelled or delisted
///         (A7-03).
///
///   For a Safe owner (mainnet): logs each call to sign in the Safe app, to the factory with no value. Nothing is
///   broadcast:
///     CHAIN_MODE=safe CHAINS_FACTORY=0x... CHAINS=<entries> LIST_CHAINS=all VAULT_TOKENS=<entries> LIST_COINS=all \
///       forge script script/ConfigureChains.s.sol --rpc-url mainnet
///   For an owner key (testnets and local forks), the same calls broadcast: CHAIN_MODE=propose ... --broadcast.
///   Execute, from any account, between LISTING_DELAY (ROTATION_DELAY for a rotation) and PROPOSAL_WINDOW later:
///     CHAIN_MODE=execute CHAINS_FACTORY=0x... CHAINS=<entries> VAULT_TOKENS=<entries> forge script ... --broadcast
///
/// Env:
///   CHAIN_MODE      `safe`, `propose` or `execute`.
///   CHAINS_FACTORY  The HybridIndexFactory.
///   CHAINS          Comma-separated `chainId:vault:stateVerifier`. The vault is a hex word of exactly 40 or 64 digits,
///                   left-padded to 32 bytes: an EVM vault's 20-byte address (TRON's without its 0x41 prefix), or a 32-byte
///                   id such as a Solana vault's config account. A chain's vault is fixed once registered, so any other
///                   length is refused as a slip that would burn the chain id (A7-04).
///   VAULT_TOKENS    Comma-separated `chainId:tokenId:supply:decimals`: tokenId in hex, 0x0 for the chain's native coin, the
///                   supply in the coin's smallest unit and its decimals. A coin's chain must be registered first, two days
///                   after its proposal. The listing is skipped unless the supply is between a million and a trillion whole
///                   units, so a slip in the decimals cannot list a figure a thousand times too large (A7-05).
///   LIST_CHAINS     Optional. Chains never registered that propose and safe mode may propose: comma-separated chain ids, or
///                   `all` for every entry of CHAINS. Leave it unset on a routine run.
///   LIST_COINS      Optional. Coins never listed that may get a listing: comma-separated `chainId:tokenId`, or `all` for
///                   every entry of VAULT_TOKENS. Leave it unset on a routine run.
///   RELIST_COINS    Optional. Comma-separated `chainId:tokenId` of delisted coins that may be listed again.
///   ROTATE          Optional. Comma-separated chain ids whose registered state verifier may be replaced by the entry's.
contract ConfigureChains is Script {
    /// @notice A vault chain: its id, its vault, and the verifier of its state on Ethereum.
    struct ChainEntry {
        uint256 chainId;
        bytes32 vault;
        address stateVerifier;
    }

    /// @notice A coin held in a chain's vault, its reference supply in the chain's smallest unit and that unit's decimals,
    ///         by which the supply is shown and bounded in whole units.
    struct TokenEntry {
        uint256 chainId;
        bytes32 tokenId;
        uint256 supply;
        uint8 decimals;
    }

    /// @notice A coin by its chain and id: how LIST_COINS and RELIST_COINS name one.
    struct CoinKey {
        uint256 chainId;
        bytes32 tokenId;
    }

    /// @notice What the operator named, so that a routine run proposes nothing it was not asked to (RT-06).
    /// @param rotate Registered chains whose state verifier may be replaced (ROTATE).
    /// @param listChains Chains never registered that may be proposed (LIST_CHAINS).
    /// @param listCoins Coins never listed that may get a listing (LIST_COINS).
    /// @param relistCoins Delisted coins that may be listed again (RELIST_COINS).
    struct Named {
        uint256[] rotate;
        uint256[] listChains;
        CoinKey[] listCoins;
        CoinKey[] relistCoins;
    }

    uint256 private constant CHAIN_FIELDS = 3;
    uint256 private constant TOKEN_FIELDS = 4;
    /// @dev Hex digits of a vault word: an address, or a 32-byte id.
    uint256 private constant ADDRESS_DIGITS = 40;
    uint256 private constant WORD_DIGITS = 64;
    /// @notice Fewest and most whole units of a vault coin a first listing may carry: the bounds the default list keeps
    ///         (XA-24, CR-I22). Coins differ in decimals from 6 to 24, so a slip is likely, and a first figure that is a
    ///         thousand times too large takes about 460 weekly batches to walk back and every index made meanwhile
    ///         carries the wrong weight.
    uint256 public constant MIN_WHOLE_SUPPLY = 1e6;
    uint256 public constant MAX_WHOLE_SUPPLY = 1e12;
    /// @notice Most decimals an entry may name: more would make no coin, and 10 ** decimals must not overflow.
    uint8 public constant MAX_DECIMALS = 36;

    /// @notice CHAIN_MODE is none of the modes.
    error UnknownMode(string mode);
    /// @notice An entry has the wrong number of fields.
    error MalformedEntry(string entry);
    /// @notice `propose` was asked of a factory whose owner is a contract, which cannot sign: use `safe`.
    error OwnerIsContract(address owner);
    /// @notice The entries name chain `chainId` twice. Safe mode decides every entry against the same state, so it
    ///         would propose each copy, and the second would revert the whole Safe batch (RT-24).
    error DuplicateChain(uint256 chainId);
    /// @notice The entries name coin `tokenId` of chain `chainId` twice (RT-24).
    error DuplicateToken(uint256 chainId, bytes32 tokenId);

    /// @notice Reads the mode, the factory, the entries and what they may propose from the environment and runs the mode.
    function run() external {
        IHybridIndexFactory factory = IHybridIndexFactory(vm.envAddress("CHAINS_FACTORY"));
        ChainEntry[] memory chains = parseChains(vm.envOr("CHAINS", string("")));
        TokenEntry[] memory tokens = parseTokens(vm.envOr("VAULT_TOKENS", string("")));
        Named memory named = Named({
            rotate: parseIds(vm.envOr("ROTATE", string(""))),
            listChains: resolveListChains(vm.envOr("LIST_CHAINS", string("")), chains),
            listCoins: resolveListCoins(vm.envOr("LIST_COINS", string("")), tokens),
            relistCoins: parseCoins(vm.envOr("RELIST_COINS", string("")))
        });
        string memory mode = vm.envString("CHAIN_MODE");
        if (ScriptUtils.same(mode, "safe")) {
            (bytes[] memory calls, string[] memory labels) = safeCalldata(factory, chains, tokens, named);
            for (uint256 i = 0; i < calls.length; ++i) {
                console2.log(labels[i]);
                console2.logBytes(calls[i]);
            }
        } else if (ScriptUtils.same(mode, "propose")) {
            propose(factory, chains, tokens, named);
        } else if (ScriptUtils.same(mode, "execute")) {
            execute(factory, chains, tokens);
        } else {
            revert UnknownMode(mode);
        }
    }

    // ---------------------------------------------------------------------
    // Entries
    // ---------------------------------------------------------------------

    /// @notice CHAINS, parsed.
    function parseChains(string memory raw) public pure returns (ChainEntry[] memory entries) {
        if (bytes(raw).length == 0) return entries;
        string[] memory parts = vm.split(raw, ",");
        entries = new ChainEntry[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            string[] memory f = vm.split(vm.trim(parts[i]), ":");
            if (f.length != CHAIN_FIELDS) revert MalformedEntry(parts[i]);
            entries[i] = ChainEntry({
                chainId: vm.parseUint(f[0]), vault: _vaultWord(f[1], parts[i]), stateVerifier: vm.parseAddress(f[2])
            });
        }
    }

    /// @notice VAULT_TOKENS, parsed.
    function parseTokens(string memory raw) public pure returns (TokenEntry[] memory entries) {
        if (bytes(raw).length == 0) return entries;
        string[] memory parts = vm.split(raw, ",");
        entries = new TokenEntry[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            string[] memory f = vm.split(vm.trim(parts[i]), ":");
            if (f.length != TOKEN_FIELDS) revert MalformedEntry(parts[i]);
            uint256 decimals = vm.parseUint(f[3]);
            if (decimals > MAX_DECIMALS) revert MalformedEntry(parts[i]);
            entries[i] = TokenEntry({
                chainId: vm.parseUint(f[0]),
                tokenId: _word(f[1], parts[i]),
                supply: vm.parseUint(f[2]),
                decimals: SafeCast.toUint8(decimals)
            });
        }
    }

    /// @notice ROTATE, parsed.
    function parseIds(string memory raw) public pure returns (uint256[] memory ids) {
        if (bytes(raw).length == 0) return ids;
        string[] memory parts = vm.split(raw, ",");
        ids = new uint256[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            ids[i] = vm.parseUint(vm.trim(parts[i]));
        }
    }

    /// @notice LIST_COINS or RELIST_COINS, parsed: comma-separated `chainId:tokenId`.
    function parseCoins(string memory raw) public pure returns (CoinKey[] memory coins) {
        if (bytes(raw).length == 0) return coins;
        string[] memory parts = vm.split(raw, ",");
        coins = new CoinKey[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            string[] memory f = vm.split(vm.trim(parts[i]), ":");
            if (f.length != 2) revert MalformedEntry(parts[i]);
            coins[i] = CoinKey({chainId: vm.parseUint(f[0]), tokenId: _word(f[1], parts[i])});
        }
    }

    /// @notice The LIST_CHAINS value: `all` names the chain of every entry in `chains`, and anything else is parsed as
    ///         comma-separated chain ids, so an empty value names none and no chain is proposed unless the operator asks
    ///         for it (A7-03).
    function resolveListChains(string memory raw, ChainEntry[] memory chains)
        public
        pure
        returns (uint256[] memory ids)
    {
        if (!ScriptUtils.same(raw, "all")) return parseIds(raw);
        ids = new uint256[](chains.length);
        for (uint256 i = 0; i < chains.length; ++i) {
            ids[i] = chains[i].chainId;
        }
    }

    /// @notice The LIST_COINS value: `all` names every coin of `tokens`, and anything else is parsed as comma-separated
    ///         `chainId:tokenId`, so an empty value names none (A7-03).
    function resolveListCoins(string memory raw, TokenEntry[] memory tokens)
        public
        pure
        returns (CoinKey[] memory coins)
    {
        if (!ScriptUtils.same(raw, "all")) return parseCoins(raw);
        coins = new CoinKey[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            coins[i] = CoinKey({chainId: tokens[i].chainId, tokenId: tokens[i].tokenId});
        }
    }

    // ---------------------------------------------------------------------
    // Proposals
    // ---------------------------------------------------------------------

    /// @notice Whether to propose `e`: false, with the reason logged, when there is nothing to propose, the factory
    ///         would refuse it, or it is a chain never registered that LIST_CHAINS does not name (nothing on chain records
    ///         that the guardian cancelled its proposal) or a rotation that ROTATE does not name.
    function shouldProposeChain(IHybridIndexFactory factory, ChainEntry memory e, Named memory named)
        public
        view
        returns (bool)
    {
        if (e.chainId == 0 || e.chainId == block.chainid) {
            console2.log("skipped, not a vault chain's id", e.chainId);
            return false;
        }
        if (e.vault == bytes32(0) || e.stateVerifier.code.length == 0) {
            console2.log("skipped, the vault is zero or the state verifier has no code", e.chainId);
            return false;
        }
        IHybridIndexFactory.Chain memory registered = factory.chain(e.chainId);
        if (registered.vault != bytes32(0)) {
            if (registered.vault != e.vault) {
                console2.log("skipped, the chain's vault is fixed: a different vault is a different chain", e.chainId);
                return false;
            }
            if (registered.stateVerifier == e.stateVerifier) return false; // registered as the entry says
            if (!_contains(named.rotate, e.chainId)) {
                console2.log("skipped, a new state verifier is a 30-day rotation: name the chain in ROTATE", e.chainId);
                return false;
            }
        }
        if (factory.chainPending(e.chainId)) {
            // forge-lint: disable-next-line(unused-return) a pending proposal's eta does not decide what to log
            (bytes32 vault, address verifier,) = factory.chainProposal(e.chainId);
            console2.log(
                vault == e.vault && verifier == e.stateVerifier
                    ? "already pending"
                    : "skipped, a different proposal is pending; cancel it first",
                e.chainId
            );
            return false;
        }
        if (registered.vault == bytes32(0) && !_contains(named.listChains, e.chainId)) {
            console2.log("skipped, never registered; name it in LIST_CHAINS to propose it", e.chainId);
            return false;
        }
        return true;
    }

    /// @notice Whether to propose listing `e`'s coin: false, with the reason logged, when it is listed or pending, its
    ///         chain is not registered, it is a coin never listed that LIST_COINS does not name or a delisted one that
    ///         RELIST_COINS does not name, the live supply batch names it, its supply is out of range, or in whole units
    ///         it is implausible.
    function shouldListToken(IHybridIndexFactory factory, TokenEntry memory e, Named memory named)
        public
        view
        returns (bool)
    {
        if (factory.chain(e.chainId).vault == bytes32(0)) {
            console2.log("skipped, the chain is not registered yet", e.chainId);
            return false;
        }
        IIndexFactory f = IIndexFactory(address(factory));
        address token = factory.vaultTokenId(e.chainId, e.tokenId);
        // A listed coin's supply changes only in the weekly batch (ConfigureWhitelist's supplies mode).
        if (f.isWhitelisted(token)) return false;
        if (f.listingPending(token)) {
            console2.log("already pending", token);
            return false;
        }
        // Nothing on chain records that the guardian cancelled a first listing or delisted a coin, so neither is
        // proposed again unless named (RT-06, XA-11).
        bool delisted = f.referenceSupply(token) != 0;
        if (!delisted && !_hasCoin(named.listCoins, e)) {
            console2.log("skipped, never listed; name it in LIST_COINS to propose its listing", token);
            return false;
        }
        if (delisted && !_hasCoin(named.relistCoins, e)) {
            console2.log("skipped, delisted; name it in RELIST_COINS to list it again", token);
            return false;
        }
        if (_inLiveBatch(f, token)) {
            console2.log("skipped, the pending supply batch names it; list it once the batch is gone", token);
            return false;
        }
        uint256 supply = listingSupply(factory, e);
        if (supply == 0 || supply > f.MAX_SUPPLY()) {
            console2.log("skipped, the reference supply must be from 1 to MAX_SUPPLY", token);
            return false;
        }
        uint256 whole = wholeUnits(e, supply);
        if (whole < MIN_WHOLE_SUPPLY || whole > MAX_WHOLE_SUPPLY) {
            console2.log("skipped, implausible supply in whole units", whole);
            return false;
        }
        console2.log("reference supply in whole units", whole);
        if (supply != e.supply) {
            console2.log("relisted at the supply in force; supplies mode revises it once it is listed (SA-02)", token);
        }
        return true;
    }

    /// @notice The supply a listing of `e` proposes: the entry's for a first listing, and the one in force for a
    ///         relisting, which the factory requires; a batch then revises it (SA-02).
    function listingSupply(IHybridIndexFactory factory, TokenEntry memory e) public view returns (uint256) {
        uint256 inForce = IIndexFactory(address(factory)).referenceSupply(factory.vaultTokenId(e.chainId, e.tokenId));
        return inForce != 0 ? inForce : e.supply;
    }

    /// @notice `supply` in whole units of `e`'s coin, where a decimals slip shows.
    function wholeUnits(TokenEntry memory e, uint256 supply) public pure returns (uint256) {
        return supply / 10 ** uint256(e.decimals);
    }

    /// @notice Every call to sign, in order, each labelled for the Safe app, with a coin's supply in whole units. Reverts
    ///         at an entry named twice, which would otherwise be proposed twice and revert the whole Safe batch (RT-24).
    function safeCalldata(
        IHybridIndexFactory factory,
        ChainEntry[] memory chains,
        TokenEntry[] memory tokens,
        Named memory named
    ) public view returns (bytes[] memory calls, string[] memory labels) {
        _requireDistinct(chains, tokens);
        bytes[] memory all = new bytes[](chains.length + tokens.length);
        string[] memory names = new string[](all.length);
        uint256 n = 0;
        for (uint256 i = 0; i < chains.length; ++i) {
            ChainEntry memory e = chains[i];
            if (!shouldProposeChain(factory, e, named)) continue;
            names[n] = string.concat("proposeChain ", vm.toString(e.chainId));
            all[n++] = abi.encodeCall(IHybridIndexFactory.proposeChain, (e.chainId, e.vault, e.stateVerifier));
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            TokenEntry memory e = tokens[i];
            if (!shouldListToken(factory, e, named)) continue;
            uint256 supply = listingSupply(factory, e);
            names[n] = string.concat(
                "proposeVaultListing ",
                vm.toString(e.chainId),
                " ",
                vm.toString(e.tokenId),
                ", ",
                vm.toString(wholeUnits(e, supply)),
                " whole units"
            );
            all[n++] = abi.encodeCall(IHybridIndexFactory.proposeVaultListing, (e.chainId, e.tokenId, supply));
        }
        calls = new bytes[](n);
        labels = new string[](n);
        for (uint256 i = 0; i < n; ++i) {
            (calls[i], labels[i]) = (all[i], names[i]);
        }
    }

    /// @notice Owner key only: proposes every entry `safeCalldata` would list. Reverts OwnerIsContract for a contract
    ///         owner, which cannot sign: on mainnet, use `safe`.
    function propose(
        IHybridIndexFactory factory,
        ChainEntry[] memory chains,
        TokenEntry[] memory tokens,
        Named memory named
    ) public {
        address owner = Ownable(address(factory)).owner();
        // A key that delegated its account under EIP-7702 has code and still signs, so it is not a contract owner.
        bytes memory ownerCode = owner.code;
        if (ownerCode.length != 0 && !ScriptUtils.isDelegatedAccount(ownerCode)) revert OwnerIsContract(owner);
        _requireDistinct(chains, tokens);
        vm.startBroadcast();
        for (uint256 i = 0; i < chains.length; ++i) {
            ChainEntry memory e = chains[i];
            if (!shouldProposeChain(factory, e, named)) continue;
            factory.proposeChain(e.chainId, e.vault, e.stateVerifier);
            console2.log("proposed chain", e.chainId);
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            TokenEntry memory e = tokens[i];
            if (!shouldListToken(factory, e, named)) continue;
            factory.proposeVaultListing(e.chainId, e.tokenId, listingSupply(factory, e));
            console2.log("proposed a listing", factory.vaultTokenId(e.chainId, e.tokenId));
        }
        vm.stopBroadcast();
    }

    /// @notice Any account: executes every chain proposal and coin listing that is due and exactly what its entry says;
    ///         anything else is left, with the reason logged.
    function execute(IHybridIndexFactory factory, ChainEntry[] memory chains, TokenEntry[] memory tokens) public {
        IIndexFactory f = IIndexFactory(address(factory));
        uint256 window = f.PROPOSAL_WINDOW();
        vm.startBroadcast();
        for (uint256 i = 0; i < chains.length; ++i) {
            ChainEntry memory e = chains[i];
            (bytes32 vault, address verifier, uint256 eta) = factory.chainProposal(e.chainId);
            if (eta == 0) continue; // nothing pending
            if (vault != e.vault || verifier != e.stateVerifier) {
                console2.log("not executed, the pending proposal differs from the entry", e.chainId);
            } else if (block.timestamp < eta) {
                console2.log("not ready yet", e.chainId);
            } else if (block.timestamp > eta + window) {
                console2.log("expired, propose again", e.chainId);
            } else {
                factory.executeChain(e.chainId);
                console2.log("chain registered", e.chainId);
            }
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = factory.vaultTokenId(tokens[i].chainId, tokens[i].tokenId);
            uint256 eta = f.listingEta(token);
            if (eta == 0) continue; // nothing pending
            if (f.pendingReferenceSupply(token) != listingSupply(factory, tokens[i])) {
                console2.log("not executed, the pending supply differs from the entry", token);
            } else if (block.timestamp < eta) {
                console2.log("not ready yet", token);
            } else if (block.timestamp > eta + window) {
                console2.log("expired, propose again", token);
            } else {
                f.executeListing(token);
                console2.log("listed", token);
            }
        }
        vm.stopBroadcast();
    }

    /// @dev Reverts DuplicateChain or DuplicateToken at the first entry named twice (RT-24).
    function _requireDistinct(ChainEntry[] memory chains, TokenEntry[] memory tokens) private pure {
        for (uint256 i = 0; i < chains.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                if (chains[j].chainId == chains[i].chainId) revert DuplicateChain(chains[i].chainId);
            }
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                if (tokens[j].chainId == tokens[i].chainId && tokens[j].tokenId == tokens[i].tokenId) {
                    revert DuplicateToken(tokens[i].chainId, tokens[i].tokenId);
                }
            }
        }
    }

    /// @dev A 32-byte word in hex of any length, left-padded: a coin id such as 0x0. Decimal is refused, since it would
    ///      read as another word.
    function _word(string memory raw, string memory entry) private pure returns (bytes32) {
        bytes memory b = bytes(raw);
        if (b.length < 3 || b[0] != "0" || b[1] != "x") revert MalformedEntry(entry);
        return bytes32(vm.parseUint(raw));
    }

    /// @dev A vault's word: exactly 40 hex digits, an EVM address (or TRON's without its 0x41 prefix), or 64, a 32-byte
    ///      id. A registered chain's vault is fixed, so the chain id is burned by any other length, such as TRON's 21-byte
    ///      form, a truncated address or a short slip, which `_word` would left-pad into a word no vault has (A7-04).
    function _vaultWord(string memory raw, string memory entry) private pure returns (bytes32) {
        uint256 digits = bytes(raw).length;
        if (digits != ADDRESS_DIGITS + 2 && digits != WORD_DIGITS + 2) revert MalformedEntry(entry);
        return _word(raw, entry);
    }

    function _inLiveBatch(IIndexFactory factory, address token) private view returns (bool) {
        if (!factory.suppliesPending()) return false;
        // forge-lint: disable-next-line(unused-return) only the batch's tokens matter here
        (,, address[] memory batch,) = factory.pendingSupplies();
        for (uint256 i = 0; i < batch.length; ++i) {
            if (batch[i] == token) return true;
        }
        return false;
    }

    function _contains(uint256[] memory ids, uint256 id) private pure returns (bool) {
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == id) return true;
        }
        return false;
    }

    function _hasCoin(CoinKey[] memory coins, TokenEntry memory e) private pure returns (bool) {
        for (uint256 i = 0; i < coins.length; ++i) {
            if (coins[i].chainId == e.chainId && coins[i].tokenId == e.tokenId) return true;
        }
        return false;
    }
}
