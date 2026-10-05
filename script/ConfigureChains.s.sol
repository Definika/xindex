// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHybridIndexFactory} from "../src/interfaces/IHybridIndexFactory.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {BnbChainAddresses} from "./BnbChainAddresses.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice Adds vault chains and their coins to the hybrid factory through its timelock: first a chain with its vault
///         and state verifier (`proposeChain`), then, once the chain is registered, each coin it holds
///         (`proposeVaultListing`). Every entry is checked against the factory first, and anything the factory would
///         refuse is skipped with its reason, so a Safe batch never fails on one call (CR-I38). A registered chain's
///         vault is fixed, and a new state verifier for it is a 30-day rotation (FAC-1), proposed only for a chain
///         named in ROTATE: a routine run never rotates a verifier. A token on a vault chain, a Binance-Peg coin on BNB
///         Chain say, also needs a cap on its vault (`proposeCap`, from VAULT_CAPS), which the vault refuses it without:
///         executing the proposal emits the CAP_UPDATE, which a relayer delivers to the vault, where a raise waits
///         GOVERNANCE_DELAY before anyone applies it.
///
///   For a Safe owner (mainnet): logs each call to sign in the Safe app, to the factory with no value. Nothing is
///   broadcast:
///     CHAIN_MODE=safe CHAINS_FACTORY=0x... CHAINS=<entries> VAULT_TOKENS=<entries> \
///       forge script script/ConfigureChains.s.sol --rpc-url mainnet
///   For an owner key (testnets and local forks), the same calls broadcast: CHAIN_MODE=propose ... --broadcast.
///   Execute, from any account, between LISTING_DELAY (ROTATION_DELAY for a rotation) and PROPOSAL_WINDOW later:
///     CHAIN_MODE=execute CHAINS_FACTORY=0x... CHAINS=<entries> VAULT_TOKENS=<entries> forge script ... --broadcast
///
/// Env:
///   CHAIN_MODE      `safe`, `propose` or `execute`.
///   CHAINS_FACTORY  The HybridIndexFactory.
///   CHAINS          Comma-separated `chainId:vault:stateVerifier`. The vault is a 32-byte word in hex, left-padded: an
///                   EVM vault's address, or a Solana vault's config account.
///   VAULT_TOKENS    Comma-separated `chainId:tokenId:supply`: tokenId in hex, 0x0 for the chain's native coin and a
///                   token's address for a token, and the supply in the coin's smallest unit. A coin's chain must be
///                   registered first, two days after its proposal. `bnb` (chain 1 only) names BNB Chain's tokens in
///                   `BnbChainAddresses`, the Binance-Peg coins among them.
///   VAULT_CAPS      Optional. Comma-separated `chainId:tokenId:cap:floor`: a coin's quantity cap across all indexes
///                   and its outflow floor on the vault, in its smallest unit. The native coin's first cap comes with the
///                   vault's deployment; every token needs one here.
///   ROTATE          Optional. Comma-separated chain ids whose registered state verifier may be replaced by the entry's.
contract ConfigureChains is Script {
    /// @notice A vault chain: its id, its vault, and the verifier of its state on Ethereum.
    struct ChainEntry {
        uint256 chainId;
        bytes32 vault;
        address stateVerifier;
    }

    /// @notice A coin held in a chain's vault, and its reference supply in the chain's smallest unit.
    struct TokenEntry {
        uint256 chainId;
        bytes32 tokenId;
        uint256 supply;
    }

    /// @notice A coin's quantity cap across all indexes and its outflow floor on its chain's vault.
    struct CapEntry {
        uint256 chainId;
        bytes32 tokenId;
        uint256 cap;
        uint256 floor;
    }

    uint256 private constant CHAIN_FIELDS = 3;
    uint256 private constant TOKEN_FIELDS = 3;
    uint256 private constant CAP_FIELDS = 4;
    /// @dev Tokens in `bnbTokens`.
    uint256 private constant BNB_TOKENS = 13;

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
    /// @notice The cap entries name coin `tokenId` of chain `chainId` twice (RT-24).
    error DuplicateCap(uint256 chainId, bytes32 tokenId);
    /// @notice VAULT_TOKENS=bnb off chain 1, whose factory is the one BNB Chain's vault serves.
    error BnbListOnlyOnMainnet();

    /// @notice Reads the mode, the factory and the entries from the environment and runs the mode.
    function run() external {
        IHybridIndexFactory factory = IHybridIndexFactory(vm.envAddress("CHAINS_FACTORY"));
        ChainEntry[] memory chains = parseChains(vm.envOr("CHAINS", string("")));
        TokenEntry[] memory tokens = parseTokens(vm.envOr("VAULT_TOKENS", string("")));
        uint256[] memory rotate = parseIds(vm.envOr("ROTATE", string("")));
        CapEntry[] memory caps = parseCaps(vm.envOr("VAULT_CAPS", string("")));
        string memory mode = vm.envString("CHAIN_MODE");
        if (ScriptUtils.same(mode, "safe")) {
            (bytes[] memory calls, string[] memory labels) = safeCalldata(factory, chains, tokens, rotate);
            _log(calls, labels);
            (calls, labels) = capCalldata(factory, caps);
            _log(calls, labels);
        } else if (ScriptUtils.same(mode, "propose")) {
            propose(factory, chains, tokens, rotate);
            proposeCaps(factory, caps);
        } else if (ScriptUtils.same(mode, "execute")) {
            execute(factory, chains, tokens);
            executeCaps(factory, caps);
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
                chainId: vm.parseUint(f[0]), vault: _word(f[1], parts[i]), stateVerifier: vm.parseAddress(f[2])
            });
        }
    }

    /// @notice VAULT_TOKENS, parsed: `bnb` for `bnbTokens`, on chain 1 only, and entries otherwise.
    function parseTokens(string memory raw) public view returns (TokenEntry[] memory entries) {
        if (bytes(raw).length == 0) return entries;
        if (ScriptUtils.same(raw, "bnb")) {
            if (block.chainid != 1) revert BnbListOnlyOnMainnet();
            return bnbTokens();
        }
        string[] memory parts = vm.split(raw, ",");
        entries = new TokenEntry[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            string[] memory f = vm.split(vm.trim(parts[i]), ":");
            if (f.length != TOKEN_FIELDS) revert MalformedEntry(parts[i]);
            entries[i] =
                TokenEntry({chainId: vm.parseUint(f[0]), tokenId: _word(f[1], parts[i]), supply: vm.parseUint(f[2])});
        }
    }

    /// @notice BNB Chain's tokens (design/2026-10-05-wide-asset-support.md, section 3), each listed by its address, with
    ///         its coin's dated circulating supply: the ten Binance-Peg coins and ATOM's, custodial, then ASTER and
    ///         STABLE. Each needs its cap too (VAULT_CAPS), which the owner sets at the listing.
    function bnbTokens() public pure returns (TokenEntry[] memory list) {
        address[BNB_TOKENS] memory tokens = [
            BnbChainAddresses.XRP,
            BnbChainAddresses.SOL,
            BnbChainAddresses.ZEC,
            BnbChainAddresses.DOGE,
            BnbChainAddresses.ADA,
            BnbChainAddresses.BCH,
            BnbChainAddresses.LTC,
            BnbChainAddresses.AVAX,
            BnbChainAddresses.DOT,
            BnbChainAddresses.FIL,
            BnbChainAddresses.ATOM,
            BnbChainAddresses.ASTER,
            BnbChainAddresses.STABLE
        ];
        uint256[BNB_TOKENS] memory supplies = [
            BnbChainAddresses.XRP_SUPPLY,
            BnbChainAddresses.SOL_SUPPLY,
            BnbChainAddresses.ZEC_SUPPLY,
            BnbChainAddresses.DOGE_SUPPLY,
            BnbChainAddresses.ADA_SUPPLY,
            BnbChainAddresses.BCH_SUPPLY,
            BnbChainAddresses.LTC_SUPPLY,
            BnbChainAddresses.AVAX_SUPPLY,
            BnbChainAddresses.DOT_SUPPLY,
            BnbChainAddresses.FIL_SUPPLY,
            BnbChainAddresses.ATOM_SUPPLY,
            BnbChainAddresses.ASTER_SUPPLY,
            BnbChainAddresses.STABLE_SUPPLY
        ];
        list = new TokenEntry[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            list[i] = TokenEntry({
                chainId: BnbChainAddresses.CHAIN_ID, tokenId: bytes32(uint256(uint160(tokens[i]))), supply: supplies[i]
            });
        }
    }

    /// @notice VAULT_CAPS, parsed.
    function parseCaps(string memory raw) public pure returns (CapEntry[] memory entries) {
        if (bytes(raw).length == 0) return entries;
        string[] memory parts = vm.split(raw, ",");
        entries = new CapEntry[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            string[] memory f = vm.split(vm.trim(parts[i]), ":");
            if (f.length != CAP_FIELDS) revert MalformedEntry(parts[i]);
            entries[i] = CapEntry({
                chainId: vm.parseUint(f[0]),
                tokenId: _word(f[1], parts[i]),
                cap: vm.parseUint(f[2]),
                floor: vm.parseUint(f[3])
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

    // ---------------------------------------------------------------------
    // Proposals
    // ---------------------------------------------------------------------

    /// @notice Whether to propose `e`: false, with the reason logged, when there is nothing to propose or the factory
    ///         would refuse it.
    function shouldProposeChain(IHybridIndexFactory factory, ChainEntry memory e, uint256[] memory rotate)
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
            if (!_contains(rotate, e.chainId)) {
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
        return true;
    }

    /// @notice Whether to propose listing `e`'s coin: false, with the reason logged, when it is listed or pending, its
    ///         chain is not registered, the live supply batch names it, or its supply is out of range.
    function shouldListToken(IHybridIndexFactory factory, TokenEntry memory e) public view returns (bool) {
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
        if (_inLiveBatch(f, token)) {
            console2.log("skipped, the pending supply batch names it; list it once the batch is gone", token);
            return false;
        }
        uint256 supply = listingSupply(factory, e);
        if (supply == 0 || supply > f.MAX_SUPPLY()) {
            console2.log("skipped, the reference supply must be from 1 to MAX_SUPPLY", token);
            return false;
        }
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

    /// @notice Every call to sign, in order, each labelled for the Safe app. Reverts at an entry named twice, which
    ///         would otherwise be proposed twice and revert the whole Safe batch (RT-24).
    function safeCalldata(
        IHybridIndexFactory factory,
        ChainEntry[] memory chains,
        TokenEntry[] memory tokens,
        uint256[] memory rotate
    ) public view returns (bytes[] memory calls, string[] memory labels) {
        _requireDistinct(chains, tokens);
        bytes[] memory all = new bytes[](chains.length + tokens.length);
        string[] memory names = new string[](all.length);
        uint256 n = 0;
        for (uint256 i = 0; i < chains.length; ++i) {
            ChainEntry memory e = chains[i];
            if (!shouldProposeChain(factory, e, rotate)) continue;
            names[n] = string.concat("proposeChain ", vm.toString(e.chainId));
            all[n++] = abi.encodeCall(IHybridIndexFactory.proposeChain, (e.chainId, e.vault, e.stateVerifier));
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            TokenEntry memory e = tokens[i];
            if (!shouldListToken(factory, e)) continue;
            names[n] = string.concat("proposeVaultListing ", vm.toString(e.chainId), " ", vm.toString(e.tokenId));
            all[n++] = abi.encodeCall(
                IHybridIndexFactory.proposeVaultListing, (e.chainId, e.tokenId, listingSupply(factory, e))
            );
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
        uint256[] memory rotate
    ) public {
        _requireOwnerKey(factory);
        _requireDistinct(chains, tokens);
        vm.startBroadcast();
        for (uint256 i = 0; i < chains.length; ++i) {
            ChainEntry memory e = chains[i];
            if (!shouldProposeChain(factory, e, rotate)) continue;
            factory.proposeChain(e.chainId, e.vault, e.stateVerifier);
            console2.log("proposed chain", e.chainId);
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            TokenEntry memory e = tokens[i];
            if (!shouldListToken(factory, e)) continue;
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

    // ---------------------------------------------------------------------
    // Caps
    // ---------------------------------------------------------------------

    /// @notice Whether to propose `e`'s cap: false, with the reason logged, when its chain is not registered, its floor
    ///         is above its cap, or a cap proposal for the coin is live. The vault's own cap is on another chain, out of
    ///         this script's sight; proposing the cap in force again changes nothing there.
    function shouldProposeCap(IHybridIndexFactory factory, CapEntry memory e) public view returns (bool) {
        if (factory.chain(e.chainId).vault == bytes32(0)) {
            console2.log("skipped, the chain is not registered yet", e.chainId);
            return false;
        }
        if (e.floor > e.cap) {
            console2.log("skipped, the floor is above the cap", vm.toString(e.tokenId));
            return false;
        }
        IHybridIndexFactory.VaultProposal memory p = factory.vaultProposal(capProposalId(factory, e));
        if (p.eta != 0 && block.timestamp <= p.eta + IIndexFactory(address(factory)).PROPOSAL_WINDOW()) {
            console2.log(
                keccak256(p.body) == keccak256(capBody(e))
                    ? "already pending"
                    : "skipped, a different cap is pending; it must run or expire first",
                vm.toString(e.tokenId)
            );
            return false;
        }
        return true;
    }

    /// @notice The factory's id of the one live cap proposal for `e`'s coin.
    function capProposalId(IHybridIndexFactory factory, CapEntry memory e) public pure returns (bytes32) {
        return factory.vaultProposalId(e.chainId, VaultMessages.CAP_UPDATE, e.tokenId);
    }

    /// @notice The CAP_UPDATE body `e` proposes, as the factory stores it.
    function capBody(CapEntry memory e) public pure returns (bytes memory) {
        return abi.encode(e.tokenId, e.cap, e.floor);
    }

    /// @notice Every cap proposal to sign, in order, each labelled for the Safe app. Reverts at a coin named twice.
    function capCalldata(IHybridIndexFactory factory, CapEntry[] memory caps)
        public
        view
        returns (bytes[] memory calls, string[] memory labels)
    {
        _requireDistinctCaps(caps);
        bytes[] memory all = new bytes[](caps.length);
        string[] memory names = new string[](caps.length);
        uint256 n = 0;
        for (uint256 i = 0; i < caps.length; ++i) {
            CapEntry memory e = caps[i];
            if (!shouldProposeCap(factory, e)) continue;
            names[n] = string.concat("proposeCap ", vm.toString(e.chainId), " ", vm.toString(e.tokenId));
            all[n++] = abi.encodeCall(IHybridIndexFactory.proposeCap, (e.chainId, e.tokenId, e.cap, e.floor));
        }
        calls = new bytes[](n);
        labels = new string[](n);
        for (uint256 i = 0; i < n; ++i) {
            (calls[i], labels[i]) = (all[i], names[i]);
        }
    }

    /// @notice Owner key only: proposes every cap `capCalldata` would list.
    function proposeCaps(IHybridIndexFactory factory, CapEntry[] memory caps) public {
        if (caps.length == 0) return;
        _requireOwnerKey(factory);
        _requireDistinctCaps(caps);
        vm.startBroadcast();
        for (uint256 i = 0; i < caps.length; ++i) {
            CapEntry memory e = caps[i];
            if (!shouldProposeCap(factory, e)) continue;
            // forge-lint: disable-next-line(unused-return) the id is `capProposalId`, logged below
            factory.proposeCap(e.chainId, e.tokenId, e.cap, e.floor);
            console2.log("proposed a cap", vm.toString(e.tokenId));
        }
        vm.stopBroadcast();
    }

    /// @notice Any account: sends every cap proposal that is due and exactly what its entry says. Each emits its
    ///         CAP_UPDATE, for a relayer to deliver to the vault; anything else is left, with the reason logged.
    function executeCaps(IHybridIndexFactory factory, CapEntry[] memory caps) public {
        uint256 window = IIndexFactory(address(factory)).PROPOSAL_WINDOW();
        vm.startBroadcast();
        for (uint256 i = 0; i < caps.length; ++i) {
            CapEntry memory e = caps[i];
            bytes32 id = capProposalId(factory, e);
            IHybridIndexFactory.VaultProposal memory p = factory.vaultProposal(id);
            if (p.eta == 0) continue; // nothing pending
            if (keccak256(p.body) != keccak256(capBody(e))) {
                console2.log("not executed, the pending cap differs from the entry", vm.toString(e.tokenId));
            } else if (block.timestamp < p.eta) {
                console2.log("not ready yet", vm.toString(e.tokenId));
            } else if (block.timestamp > p.eta + window) {
                console2.log("expired, propose again", vm.toString(e.tokenId));
            } else {
                factory.executeVaultProposal(id);
                console2.log("cap sent; deliver it to the vault, and apply a raise there after its delay", e.chainId);
            }
        }
        vm.stopBroadcast();
    }

    /// @dev Reverts OwnerIsContract for a contract owner, which cannot sign: on mainnet, use `safe`. A key that
    ///      delegated its account under EIP-7702 has code and still signs, so it is not a contract owner.
    function _requireOwnerKey(IHybridIndexFactory factory) private view {
        address owner = Ownable(address(factory)).owner();
        bytes memory ownerCode = owner.code;
        if (ownerCode.length != 0 && !ScriptUtils.isDelegatedAccount(ownerCode)) revert OwnerIsContract(owner);
    }

    /// @dev Reverts DuplicateCap at the first coin named twice (RT-24).
    function _requireDistinctCaps(CapEntry[] memory caps) private pure {
        for (uint256 i = 0; i < caps.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                if (caps[j].chainId == caps[i].chainId && caps[j].tokenId == caps[i].tokenId) {
                    revert DuplicateCap(caps[i].chainId, caps[i].tokenId);
                }
            }
        }
    }

    function _log(bytes[] memory calls, string[] memory labels) private pure {
        for (uint256 i = 0; i < calls.length; ++i) {
            console2.log(labels[i]);
            console2.logBytes(calls[i]);
        }
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

    /// @dev A 32-byte word in hex of any length, left-padded: a vault's address, a Solana account, or a coin id such as
    ///      0x0. Decimal is refused, since it would read as another word.
    function _word(string memory raw, string memory entry) private pure returns (bytes32) {
        bytes memory b = bytes(raw);
        if (b.length < 3 || b[0] != "0" || b[1] != "x") revert MalformedEntry(entry);
        return bytes32(vm.parseUint(raw));
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
}
