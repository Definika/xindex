// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Drives the factory's listing, supply-batch and guardian flows in any order, at any point in their windows.
/// @dev `fail_on_revert = true`, so every action checks its own precondition first. The handler mirrors what the
///      factory should hold in ghost state -- which token is listed, which supply is in force, who the guardian is --
///      from the rules alone, never by reading the factory back, so the invariants compare two independent accounts.
contract FactoryHandler is Test {
    IndexFactory public factory;
    address public owner;
    address public guardian;
    MockERC20[] public tokens;

    /// @dev What the rules say must be true, tracked independently of the factory.
    mapping(address => bool) public ghostListed;
    mapping(address => uint256) public ghostSupply;
    address public ghostGuardian;

    uint256 public ghostListings;
    uint256 public ghostBatches;
    uint256 public ghostCancels;
    uint256 public ghostDelists;
    uint256 public ghostExpiries;
    uint256 public ghostGuardianChanges;
    /// @dev Set if a proposal ever executed outside its window, which the timelock must make impossible, and if one
    ///      was ever refused inside it, which would strand a proposal the owner is entitled to have executed. The
    ///      handler attempts every execution whatever the clock says and records which way it went.
    bool public executedOutsideItsWindow;
    bool public refusedInsideItsWindow;
    /// @dev Set if an executed change ever moved a supply that was in force by more than one step, or if a batch ever
    ///      came into force in part.
    bool public stepBroken;
    /// @notice Set if two batches ever executed less than MIN_SUPPLY_INTERVAL apart (SA-04).
    bool public cadenceBroken;
    uint256 public ghostLastBatch;
    bool public batchApplication;
    uint256 public ghostOutOfWindowAttempts;

    constructor(IndexFactory factory_, address owner_, address guardian_, MockERC20[] memory t) {
        (factory, owner, guardian, ghostGuardian) = (factory_, owner_, guardian_, guardian_);
        for (uint256 i = 0; i < t.length; ++i) {
            tokens.push(t[i]);
        }
    }

    function _token(uint256 seed) internal view returns (address) {
        return address(tokens[seed % tokens.length]);
    }

    /// @dev Whoever currently holds the role. After a guardian change the original address is no longer authorised,
    ///      and a removal leaves the owner as the only caller.
    function _roleHolder(bool preferGuardian) internal view returns (address) {
        return preferGuardian && ghostGuardian != address(0) ? ghostGuardian : owner;
    }

    function _listingLive(address token) internal view returns (bool) {
        uint256 eta = factory.listingEta(token);
        return eta != 0 && block.timestamp <= eta + factory.PROPOSAL_WINDOW();
    }

    function _inLiveBatch(address token) internal view returns (bool) {
        if (!factory.suppliesPending()) return false;
        (,, address[] memory batch,) = factory.pendingSupplies();
        for (uint256 i = 0; i < batch.length; ++i) {
            if (batch[i] == token) return true;
        }
        return false;
    }

    /// @dev A supply one step or less from `inForce`, up or down, or the same, as `seed` picks.
    function _revised(uint256 inForce, uint256 seed) internal view returns (uint256) {
        uint256 step = inForce * factory.MAX_SUPPLY_STEP() / 1e18;
        uint256 pick = seed % 3;
        return pick == 0 ? inForce + step : pick == 1 ? inForce - step : inForce;
    }

    function _withinStep(uint256 before, uint256 later) internal view returns (bool) {
        uint256 step = before * factory.MAX_SUPPLY_STEP() / 1e18;
        return later <= before + step && later + step >= before;
    }

    // ---------------------------------------------------------------------
    // actions
    // ---------------------------------------------------------------------

    function proposeListing(uint256 seed, bool alternate) external {
        address token = _token(seed);
        if (ghostListed[token] || _listingLive(token) || _inLiveBatch(token)) return;
        uint256 inForce = ghostSupply[token];
        // A first listing takes any supply; a relisting takes the supply the token carries (SA-02).
        uint256 supply = inForce == 0 ? (alternate ? 2e24 : 1e24) : inForce;
        vm.prank(owner);
        factory.proposeListing(token, supply);
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
        uint256 pending = factory.pendingReferenceSupply(token);

        try factory.executeListing(token) {
            // Recorded rather than branched on: the line runs on every execution, so nothing here is only exercised
            // by a broken contract.
            executedOutsideItsWindow = executedOutsideItsWindow || !inWindow;
            uint256 before = ghostSupply[token];
            stepBroken = stepBroken || (before != 0 && pending != before);
            ghostSupply[token] = pending;
            if (!ghostListed[token]) ghostListings++;
            ghostListed[token] = true;
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

    /// @dev A batch over every token that carries a supply and has no live listing, each revised by up to a step.
    function proposeSupplies(uint256 seed) external {
        if (factory.suppliesPending()) return;
        uint256 n = 0;
        address[] memory batch = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = address(tokens[i]);
            if (ghostSupply[token] != 0 && !_listingLive(token)) batch[n++] = token;
        }
        if (n == 0) return;
        address[] memory sorted = new address[](n);
        uint256[] memory supplies = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            sorted[i] = batch[i];
        }
        for (uint256 i = 1; i < n; ++i) {
            for (uint256 j = i; j > 0 && sorted[j - 1] > sorted[j]; --j) {
                (sorted[j - 1], sorted[j]) = (sorted[j], sorted[j - 1]);
            }
        }
        for (uint256 i = 0; i < n; ++i) {
            supplies[i] = _revised(ghostSupply[sorted[i]], seed >> i);
        }
        vm.prank(owner);
        factory.proposeSupplies(sorted, supplies);
    }

    function cancelSupplies(bool byGuardian) external {
        (, uint256 eta,,) = factory.pendingSupplies();
        if (eta == 0) return;
        vm.prank(_roleHolder(byGuardian));
        factory.cancelSupplies();
        ghostCancels++;
    }

    function executeSupplies() external {
        (, uint256 eta, address[] memory batch, uint256[] memory supplies) = factory.pendingSupplies();
        if (eta == 0) return;
        bool inWindow = block.timestamp >= eta && block.timestamp <= eta + factory.PROPOSAL_WINDOW();
        if (!inWindow) ghostOutOfWindowAttempts++;
        try factory.executeSupplies() {
            executedOutsideItsWindow = executedOutsideItsWindow || !inWindow;
            cadenceBroken = cadenceBroken
                || (ghostLastBatch != 0 && block.timestamp < ghostLastBatch + factory.MIN_SUPPLY_INTERVAL());
            ghostLastBatch = block.timestamp;
            for (uint256 i = 0; i < batch.length; ++i) {
                stepBroken = stepBroken || !_withinStep(ghostSupply[batch[i]], supplies[i]);
                ghostSupply[batch[i]] = supplies[i];
                // Every supply of the batch is in force together, straight after the one call.
                batchApplication = batchApplication || factory.referenceSupply(batch[i]) != supplies[i];
            }
            ghostBatches++;
        } catch {
            refusedInsideItsWindow = refusedInsideItsWindow || inWindow;
        }
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

/// @notice The factory's timelocks, its supply batches and its whitelist array, under any interleaving of the flows.
contract IndexFactoryInvariantTest is Test {
    IndexFactory factory;
    FactoryHandler handler;
    MockERC20[] tokens;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");

    function setUp() public {
        factory = new IndexFactory(owner, guardian);
        for (uint256 i = 0; i < 6; ++i) {
            tokens.push(new MockERC20("Comp", "C", 18));
        }
        handler = new FactoryHandler(factory, owner, guardian, tokens);
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------------
    // invariants
    // ---------------------------------------------------------------------

    /// @dev The array behind `whitelistedTokens()` is exactly the set of whitelisted tokens: every entry is listed,
    ///      every listed token appears, and none appears twice.
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

    /// @dev The supply in force is always the one the last executed listing or batch carried, never an unexecuted one,
    ///      and a delist never clears it.
    function invariant_supplyInForceIsTheLastExecutedChange() public view {
        for (uint256 i = 0; i < tokens.length; ++i) {
            address t = address(tokens[i]);
            assertEq(factory.referenceSupply(t), handler.ghostSupply(t), "a supply took effect no execution put there");
        }
    }

    /// @dev No executed batch ever moved a supply in force by more than MAX_SUPPLY_STEP, no two executed less than a
    ///      week apart (SA-04), no relisting moved one at all (SA-02), and a batch always came into force whole.
    function invariant_everyRevisionIsWithinAStepAndBatchesAreAtomic() public view {
        assertFalse(handler.stepBroken(), "a supply moved more than a step");
        assertFalse(handler.cadenceBroken(), "two batches executed less than a week apart");
        assertFalse(handler.batchApplication(), "a batch came into force in part");
    }

    /// @dev No proposal -- listing, batch or guardian -- ever took effect outside `[eta, eta + PROPOSAL_WINDOW]`, and
    ///      none was ever refused inside it.
    function invariant_nothingExecutesOutsideItsWindow() public view {
        assertFalse(handler.executedOutsideItsWindow(), "a proposal executed outside its window");
        assertFalse(handler.refusedInsideItsWindow(), "a proposal was refused inside its window");
    }

    /// @dev The guardian is whoever the last executed change named.
    function invariant_guardianIsTheLastExecutedChange() public view {
        assertEq(factory.guardian(), handler.ghostGuardian(), "the guardian drifted from the rules");
    }

    /// @dev Delisting a token that swap-and-pop has already moved (LR-05), driven through the handler.
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

    /// @dev A token delisted while a live batch names it cannot be proposed again until the batch is gone, so the
    ///      handler skips it rather than making a call that must revert; another token is proposed as usual.
    function test_aTokenInALiveBatchIsNotProposedAgain() public {
        address first = address(tokens[0]);
        handler.proposeListing(0, false);
        handler.warp(3 days);
        handler.executeListing(0);
        handler.proposeSupplies(1);
        handler.delist(0, true);

        handler.proposeListing(0, false);
        assertEq(factory.listingEta(first), 0, "skipped while the batch names it");
        uint256 supply = factory.referenceSupply(first);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.TokenInBatch.selector, first));
        factory.proposeListing(first, supply);
        handler.proposeListing(1, false);
        assertGt(factory.listingEta(address(tokens[1])), 0, "a token outside the batch is proposed");

        handler.warp(3 days);
        handler.executeSupplies();
        handler.proposeListing(0, false);
        assertGt(factory.listingEta(first), 0, "proposed once the batch has executed");
        invariant_supplyInForceIsTheLastExecutedChange();
        invariant_everyRevisionIsWithinAStepAndBatchesAreAtomic();
    }

    /// @dev The campaign has to reach the states the invariants are about, or they assert nothing.
    function test_handlerReachesEveryPath() public {
        handler.proposeListing(0, false);
        handler.proposeListing(0, false); // already live, skipped
        handler.executeListing(0); // not ready yet, refused
        handler.warp(3 days);
        handler.executeListing(0);
        assertTrue(factory.isWhitelisted(address(tokens[0])), "listed");

        // A batch, refused before its eta, executed inside its window.
        handler.proposeSupplies(1);
        handler.proposeSupplies(2); // one at a time, skipped
        handler.executeSupplies(); // not ready yet, refused
        handler.warp(3 days);
        handler.executeSupplies();
        assertGt(handler.ghostBatches(), 0, "a batch executed");

        handler.delist(0, true);
        handler.delist(0, true); // not listed, skipped
        assertFalse(factory.isWhitelisted(address(tokens[0])), "delisted");

        // A relisting within a step, and the array surviving a swap-and-pop in the middle.
        handler.proposeListing(1, false);
        handler.proposeListing(2, false);
        handler.warp(3 days);
        handler.executeListing(1);
        handler.executeListing(2);
        handler.delist(1, false);
        handler.proposeListing(0, false);
        handler.warp(3 days);
        handler.executeListing(0);
        assertTrue(factory.isWhitelisted(address(tokens[0])), "relisted");

        // An expiry, then a cancel, for a listing and for a batch.
        handler.proposeListing(3, false);
        handler.warp(10 days);
        handler.warp(10 days);
        handler.executeListing(3); // expired
        assertGt(handler.ghostExpiries(), 0, "an expiry was reached");
        handler.cancelListing(3, true);
        handler.proposeSupplies(3);
        handler.cancelSupplies(true);
        handler.cancelSupplies(true); // nothing pending, skipped
        assertGt(handler.ghostCancels(), 1, "cancels were reached");
        handler.proposeSupplies(4);
        handler.warp(10 days);
        handler.warp(10 days);
        handler.executeSupplies(); // expired

        // The guardian flow end to end, including a cancelled removal.
        handler.proposeGuardian(0); // address(0): a removal
        handler.cancelGuardianChange(true); // the guardian cancels its own removal
        handler.proposeGuardian(1);
        handler.executeGuardianChange(); // not ready yet, refused
        handler.warp(8 days);
        handler.executeGuardianChange();
        assertGt(handler.ghostGuardianChanges(), 0, "a guardian change executed");

        assertGt(handler.ghostOutOfWindowAttempts(), 0, "the campaign attempted an execution outside its window");
        invariant_whitelistArrayIsExactlyTheListedSet();
        invariant_listingsMatchTheRules();
        invariant_supplyInForceIsTheLastExecutedChange();
        invariant_everyRevisionIsWithinAStepAndBatchesAreAtomic();
        invariant_nothingExecutesOutsideItsWindow();
    }
}
