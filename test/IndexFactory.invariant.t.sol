// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

/// @notice Drives the factory's listing and guardian flows in any order, at any point in their windows.
/// @dev `fail_on_revert = true`, so every action checks its own precondition first. The handler mirrors what the
///      factory should hold in ghost state -- which token is listed, which config is in force, who the guardian is --
///      from the rules alone, never by reading the factory back, so the invariants compare two independent accounts.
contract FactoryHandler is Test {
    IndexFactory public factory;
    MockMarket public market;
    address public owner;
    address public guardian;
    MockERC20[] public tokens;

    /// @dev What the rules say must be true, tracked independently of the factory.
    mapping(address => bool) public ghostListed;
    mapping(address => bytes32) public ghostConfig;
    address public ghostGuardian;
    bytes32 public emptyConfig;

    uint256 public ghostListings;
    uint256 public ghostConfigChanges;
    uint256 public ghostCancels;
    uint256 public ghostDelists;
    uint256 public ghostExpiries;
    uint256 public ghostGuardianChanges;
    /// @dev Set if a proposal ever executed outside its window, which the timelock must make impossible, and if one
    ///      was ever refused inside it, which would strand a proposal the owner is entitled to have executed. The
    ///      handler attempts every execution whatever the clock says and records which way it went: a handler that
    ///      checked the window itself before calling could never observe either.
    bool public executedOutsideItsWindow;
    bool public refusedInsideItsWindow;
    uint256 public ghostOutOfWindowAttempts;

    constructor(IndexFactory factory_, MockMarket market_, address owner_, address guardian_, MockERC20[] memory t) {
        (factory, market, owner, guardian, ghostGuardian) = (factory_, market_, owner_, guardian_, guardian_);
        // An unconfigured token still hashes to something, so the ghost starts at the empty config's own hash.
        emptyConfig = hashConfig(IIndexFactory.TokenConfig(address(0), 0, 0, new address[](0)));
        for (uint256 i = 0; i < t.length; ++i) {
            tokens.push(t[i]);
            ghostConfig[address(t[i])] = emptyConfig;
        }
    }

    function _token(uint256 seed) internal view returns (address) {
        return address(tokens[seed % tokens.length]);
    }

    /// @dev A config the rule accepts. The two differ in their reference supply, which is part of the config; the
    ///      pool's tick is not, so varying that would leave `proposeConfig` proposing the config already in force.
    function _config(address token, bool alternate) internal returns (IIndexFactory.TokenConfig memory) {
        return market.configWith(token, 0, alternate ? 2e24 : 1e24, new address[](0));
    }

    /// @notice The identity of a config, as both the handler and the invariants compare them.
    function hashConfig(IIndexFactory.TokenConfig memory c) public pure returns (bytes32) {
        return keccak256(abi.encode(c.pool, c.minLiquidity, c.referenceSupply, c.excluded));
    }

    /// @dev Whoever currently holds the role. After a guardian change the original address is no longer authorised,
    ///      and a removal leaves the owner as the only caller.
    function _roleHolder(bool preferGuardian) internal view returns (address) {
        return preferGuardian && ghostGuardian != address(0) ? ghostGuardian : owner;
    }

    /// @dev A proposal is live from when it is made until PROPOSAL_WINDOW after it becomes executable.
    function _live(address token) internal view returns (bool) {
        uint256 eta = factory.listingEta(token);
        return eta != 0 && block.timestamp <= eta + factory.PROPOSAL_WINDOW();
    }

    // ---------------------------------------------------------------------
    // actions
    // ---------------------------------------------------------------------

    function proposeListing(uint256 seed, bool alternate) external {
        address token = _token(seed);
        if (_live(token)) return;
        IIndexFactory.TokenConfig memory config = _config(token, alternate);
        vm.prank(owner);
        factory.proposeListing(token, config);
    }

    function proposeConfig(uint256 seed, bool alternate) external {
        address token = _token(seed);
        // proposeConfig needs a config already in force, and no live proposal.
        if (_live(token) || ghostConfig[token] == emptyConfig) return;
        IIndexFactory.TokenConfig memory config = _config(token, alternate);
        vm.prank(owner);
        factory.proposeConfig(token, config);
    }

    function executeListing(uint256 seed) external {
        address token = _token(seed);
        uint256 eta = factory.listingEta(token);
        if (eta == 0) return; // nothing pending, so there is nothing for the timelock to be tested against
        bool inWindow = block.timestamp >= eta && block.timestamp <= eta + factory.PROPOSAL_WINDOW();
        if (!inWindow) {
            ghostOutOfWindowAttempts++;
            if (block.timestamp > eta + factory.PROPOSAL_WINDOW()) ghostExpiries++;
        }
        bool listing = factory.pendingIsListing(token);
        bytes32 pending = hashConfig(factory.pendingTokenConfig(token));

        try factory.executeListing(token) {
            // Recorded rather than branched on, the way the token's handler records its violations: the line runs on
            // every execution, so nothing here is only exercised by a broken contract.
            executedOutsideItsWindow = executedOutsideItsWindow || !inWindow;
            // Mirror the rules: the pending config takes effect, and a listing proposal whitelists the token.
            ghostConfig[token] = pending;
            if (listing) {
                if (!ghostListed[token]) ghostListings++;
                ghostListed[token] = true;
            } else {
                ghostConfigChanges++;
            }
        } catch {
            refusedInsideItsWindow = refusedInsideItsWindow || inWindow;
        }
    }

    function cancelListing(uint256 seed, bool byGuardian) external {
        address token = _token(seed);
        if (factory.listingEta(token) == 0) return;
        vm.prank(_roleHolder(byGuardian));
        factory.cancelListing(token);
        ghostCancels++;
    }

    function delist(uint256 seed, bool byGuardian) external {
        address token = _token(seed);
        if (!ghostListed[token]) return;
        vm.prank(_roleHolder(byGuardian));
        factory.delist(token);
        ghostListed[token] = false;
        ghostDelists++;
    }

    function proposeGuardian(uint256 seed) external {
        vm.prank(owner);
        factory.proposeGuardian(seed % 2 == 0 ? address(0) : _token(seed));
    }

    function cancelGuardianChange(bool byGuardian) external {
        if (factory.pendingGuardianEta() == 0) return;
        // The guardian may cancel only its own removal; the owner may cancel anything.
        bool guardianMayCancel = factory.pendingGuardian() == address(0) && ghostGuardian != address(0);
        vm.prank(byGuardian && guardianMayCancel ? ghostGuardian : owner);
        factory.cancelGuardianChange();
    }

    function executeGuardianChange() external {
        uint256 eta = factory.pendingGuardianEta();
        if (eta == 0) return;
        bool inWindow = block.timestamp >= eta && block.timestamp <= eta + factory.PROPOSAL_WINDOW();
        if (!inWindow) ghostOutOfWindowAttempts++;
        address next = factory.pendingGuardian();
        try factory.executeGuardianChange() {
            executedOutsideItsWindow = executedOutsideItsWindow || !inWindow;
            ghostGuardian = next;
            ghostGuardianChanges++;
        } catch {
            refusedInsideItsWindow = refusedInsideItsWindow || inWindow;
        }
    }

    /// @dev Lands anywhere in or past a window: before the delay, inside it, and past the expiry.
    function warp(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1 hours, 10 days));
    }
}

/// @notice The factory's timelocks and its whitelist array, under any interleaving of the listing and guardian flows.
/// @dev Closes the two areas the 2026-09-21 verification review left uninspected: `IndexFactory`'s delays and windows,
///      and the swap-and-pop array behind `whitelistedTokens()`.
contract IndexFactoryInvariantTest is Test {
    IndexFactory factory;
    MockMarket market;
    FactoryHandler handler;
    MockERC20[] tokens;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(
            owner, guardian, address(market.weth()), address(market.uniswapV3Factory()), address(market.usdc())
        );
        for (uint256 i = 0; i < 6; ++i) {
            tokens.push(new MockERC20("Comp", "C", 18));
        }
        handler = new FactoryHandler(factory, market, owner, guardian, tokens);
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------------
    // invariants
    // ---------------------------------------------------------------------

    /// @dev The array behind `whitelistedTokens()` is exactly the set of whitelisted tokens: every entry is listed,
    ///      every listed token appears, and none appears twice. Swap-and-pop is the only thing that maintains it
    ///      (`_whitelistPos`), and a lost or duplicated entry would let a token be delisted twice or never.
    function invariant_whitelistArrayIsExactlyTheListedSet() public view {
        address[] memory list = factory.whitelistedTokens();
        for (uint256 i = 0; i < list.length; ++i) {
            assertTrue(factory.isWhitelisted(list[i]), "an entry that is not whitelisted");
            for (uint256 j = 0; j < i; ++j) {
                assertTrue(list[i] != list[j], "the same token twice");
            }
        }
        uint256 listed = 0;
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (!factory.isWhitelisted(address(tokens[i]))) continue;
            listed++;
            bool found = false;
            for (uint256 j = 0; j < list.length; ++j) {
                if (list[j] == address(tokens[i])) found = true;
            }
            assertTrue(found, "a whitelisted token missing from the array");
        }
        assertEq(list.length, listed, "the array and the flags disagree on how many are listed");
    }

    /// @dev The factory's own view of what is listed matches the rules applied independently by the handler.
    function invariant_listingsMatchTheRules() public view {
        for (uint256 i = 0; i < tokens.length; ++i) {
            address t = address(tokens[i]);
            assertEq(factory.isWhitelisted(t), handler.ghostListed(t), "listed state drifted from the rules");
        }
    }

    /// @dev The config in force is always the one the last executed proposal carried, and never an unexecuted one.
    function invariant_configInForceIsTheLastExecutedProposal() public view {
        for (uint256 i = 0; i < tokens.length; ++i) {
            address t = address(tokens[i]);
            bytes32 inForce = handler.hashConfig(factory.tokenConfig(t));
            assertEq(inForce, handler.ghostConfig(t), "a config took effect that no execution put there");
        }
    }

    /// @dev No proposal, listing or guardian, ever took effect outside `[eta, eta + PROPOSAL_WINDOW]`, and none was
    ///      ever refused inside it. The handler attempts execution whatever the clock says, so both directions are
    ///      observed rather than assumed, and `ghostOutOfWindowAttempts` proves the out-of-window case was reached.
    function invariant_nothingExecutesOutsideItsWindow() public view {
        assertFalse(handler.executedOutsideItsWindow(), "a proposal executed outside its window");
        assertFalse(handler.refusedInsideItsWindow(), "a proposal was refused inside its window");
    }

    /// @dev The guardian is whoever the last executed change named. A proposal never takes effect on its own, however
    ///      long it sits there: an expired guardian proposal stays recorded, exactly as an expired listing proposal
    ///      stays in `listingEta`, and only `executeGuardianChange` inside the window can move the role.
    function invariant_guardianIsTheLastExecutedChange() public view {
        assertEq(factory.guardian(), handler.ghostGuardian(), "the guardian drifted from the rules");
    }

    /// @dev A delisted token keeps the config the indexes still holding it rebalance with.
    function invariant_delistingNeverClearsAConfig() public view {
        for (uint256 i = 0; i < tokens.length; ++i) {
            address t = address(tokens[i]);
            if (handler.ghostConfig(t) == handler.emptyConfig()) continue;
            IIndexFactory.TokenConfig memory current = factory.tokenConfig(t);
            assertTrue(current.pool != address(0) || current.referenceSupply != 0, "a config was cleared by a delist");
        }
    }

    /// @dev Delisting a token that swap-and-pop has already moved. The array is maintained by `_whitelistPos`, and a
    ///      stale entry there makes the second delist pop the wrong slot or read past the end -- LR-05 found exactly
    ///      that. Driven through the handler so it is the same path the campaign takes, and asserted through the same
    ///      invariant, because a random campaign rarely lines four listings up against two delists in that order.
    function test_delistingAMovedTokenKeepsTheArrayConsistent() public {
        for (uint256 i = 0; i < 4; ++i) {
            handler.proposeListing(i, false);
        }
        handler.warp(3 days);
        for (uint256 i = 0; i < 4; ++i) {
            handler.executeListing(i);
        }
        assertEq(factory.whitelistedTokens().length, 4, "four listed");

        handler.delist(1, false); // the last entry, token 3, is swapped into slot 1
        assertEq(factory.whitelistedTokens()[1], address(tokens[3]), "the last entry moved into the hole");

        handler.delist(3, true); // now delist the token that moved
        invariant_whitelistArrayIsExactlyTheListedSet();
        invariant_listingsMatchTheRules();
        assertEq(factory.whitelistedTokens().length, 2, "two left");
    }

    /// @dev The campaign has to reach the states the invariants are about, or they assert nothing. Drives one token
    ///      through list, config change, delist, relist and an expiry, and the guardian through a full change.
    function test_handlerReachesEveryPath() public {
        handler.proposeListing(0, false);
        handler.proposeListing(0, false); // already live, skipped
        handler.executeListing(0); // not ready yet, skipped
        handler.warp(3 days);
        handler.executeListing(0);
        assertTrue(factory.isWhitelisted(address(tokens[0])), "listed");

        handler.proposeConfig(0, true);
        handler.warp(3 days);
        handler.executeListing(0);
        assertGt(handler.ghostConfigChanges(), 0, "a config change executed");

        handler.delist(0, true);
        handler.delist(0, true); // not listed, skipped
        assertFalse(factory.isWhitelisted(address(tokens[0])), "delisted");

        // Relisting takes a fresh proposal, and the array survives a swap-and-pop in the middle.
        handler.proposeListing(1, false);
        handler.proposeListing(2, false);
        handler.warp(3 days);
        handler.executeListing(1);
        handler.executeListing(2);
        handler.delist(1, false);
        handler.proposeListing(0, false);
        handler.warp(3 days);
        handler.executeListing(0);

        // An expiry, then a cancel.
        handler.proposeListing(3, false);
        handler.warp(10 days);
        handler.warp(10 days);
        handler.executeListing(3); // expired
        assertGt(handler.ghostExpiries(), 0, "an expiry was reached");
        handler.cancelListing(3, true);
        assertGt(handler.ghostCancels(), 0, "a cancel was reached");

        // The guardian flow end to end, including a cancelled removal.
        handler.proposeGuardian(0); // address(0): a removal
        handler.cancelGuardianChange(true); // the guardian cancels its own removal
        handler.proposeGuardian(1);
        handler.executeGuardianChange(); // not ready yet, skipped
        handler.warp(8 days);
        handler.executeGuardianChange();
        assertGt(handler.ghostGuardianChanges(), 0, "a guardian change executed");

        assertGt(handler.ghostOutOfWindowAttempts(), 0, "the campaign attempted an execution outside its window");
        invariant_whitelistArrayIsExactlyTheListedSet();
        invariant_listingsMatchTheRules();
        invariant_configInForceIsTheLastExecutedProposal();
        invariant_nothingExecutesOutsideItsWindow();
        invariant_delistingNeverClearsAConfig();
    }
}
