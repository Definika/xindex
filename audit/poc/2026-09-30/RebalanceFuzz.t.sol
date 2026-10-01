// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexHub} from "../../src/IndexHub.sol";
import {IIndexHub} from "../../src/interfaces/IIndexHub.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice Adversarial property fuzz over the λ band auction: extreme supplies, random batches, keep masks, claims and
///         holder activity during notice and auction. Every cycle checks the invariant, the preview against the
///         settlement, the value bound at random prices, and that nothing reverts that should not.
contract RebalanceFuzzPoC is Test {
    uint256 constant WAD = 1e18;
    IndexFactory factory;
    MockRebalanceExecutor executor;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    address[] tokens;
    IndexHub index;

    function setUp() public {
        factory = new IndexFactory(owner, guardian);
        executor = new MockRebalanceExecutor();
    }

    function _list(address token, uint256 supply) internal {
        vm.prank(owner);
        factory.proposeListing(token, supply);
    }

    function _sorted() internal view returns (address[] memory s) {
        s = new address[](tokens.length);
        for (uint256 i = 0; i < s.length; ++i) {
            s[i] = tokens[i];
        }
        for (uint256 i = 1; i < s.length; ++i) {
            for (uint256 j = i; j > 0 && s[j - 1] > s[j]; --j) {
                (s[j - 1], s[j]) = (s[j], s[j - 1]);
            }
        }
    }

    function _batch(uint256 seed) internal {
        address[] memory s = _sorted();
        uint256[] memory sup = factory.referenceSupplies(s);
        bool any = false;
        for (uint256 i = 0; i < s.length; ++i) {
            uint256 step = sup[i] * 5e15 / WAD;
            uint256 pick = (seed >> (3 * i)) % 5;
            if (pick == 0) sup[i] += step;
            else if (pick == 1) sup[i] -= step;
            else if (pick == 2) sup[i] += step / 3;
            if (pick <= 2 && step != 0) any = true;
        }
        if (!any) return;
        vm.prank(owner);
        factory.proposeSupplies(s, sup);
        vm.warp(block.timestamp + 2 days);
        factory.executeSupplies();
    }

    function _issue(address who, uint256 shares) internal {
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(who, need[i]);
            vm.prank(who);
            MockERC20(tokens[i]).approve(address(index), need[i]);
        }
        vm.prank(who);
        index.issue(shares, who);
    }

    function _assertBacked() internal view {
        (address[] memory t, uint256[] memory u) = index.components();
        uint256 supply = index.totalSupply();
        for (uint256 i = 0; i < t.length; ++i) {
            uint256 required = Math.mulDiv(supply, u[i], WAD) + index.totalClaims(t[i]);
            assertGe(MockERC20(t[i]).balanceOf(address(index)), required, "under-backed");
        }
    }

    uint256 n;
    uint256 fills;

    function _setupIndex(uint256 seed, uint8 nSeed, uint256 spread) internal {
        n = 2 + uint256(nSeed) % 5;
        uint256 spreadDigits = bound(spread, 0, 21);
        for (uint256 i = 0; i < n; ++i) {
            tokens.push(address(new MockERC20("T", "T", 18)));
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            uint256 digits = h % (spreadDigits + 1);
            uint256 supply = (10 ** (4 + digits)) + (h >> 128) % (10 ** (4 + digits));
            _list(tokens[i], supply);
        }
        vm.warp(block.timestamp + 2 days);
        for (uint256 i = 0; i < n; ++i) {
            factory.executeListing(tokens[i]);
        }
        uint256[] memory sup = factory.referenceSupplies(tokens);
        uint256 fmin = type(uint256).max;
        uint256 fmax = 0;
        for (uint256 i = 0; i < n; ++i) {
            fmin = Math.min(fmin, sup[i]);
            fmax = Math.max(fmax, sup[i]);
        }
        uint256 k = Math.mulDiv(10_000, 1e36, fmin, Math.Rounding.Ceil);
        vm.assume(Math.mulDiv(k, fmax, 1e36) <= factory.MAX_UNITS());
        index = IndexHub(factory.createIndex("F", "F", tokens, k));
        _issue(alice, 1e18 + seed % 1e24);
        _issue(bob, 1e15 + (seed >> 64) % 1e20);
    }

    function _holders(uint256 r) internal {
        if ((r >> 10) & 1 == 1) _issue(bob, 1 + (r >> 20) % 1e21);
        if ((r >> 11) & 1 == 1) {
            uint256 bal = index.balanceOf(alice);
            uint256 mask = 1 + (r >> 30) % ((1 << n) - 1);
            vm.prank(alice);
            index.redeemSkipping(bal / 3 + 1, alice, mask);
        }
        if ((r >> 12) & 1 == 1) _batch(r >> 13);
    }

    function _checkPreview(uint256 r) internal view returns (uint256[] memory preview) {
        (, uint256 keepMask, uint256 lambdaMin, uint256 lambdaMax,) = index.pendingRebalance();
        (, uint256[] memory before) = index.components();
        uint256 lambda;
        (lambda, preview,,) = index.previewRebalance();
        assertEq(index.currentLambda(), lambda, "currentLambda disagrees");
        assertGe(lambda, lambdaMin);
        assertLe(lambda, lambdaMax);
        uint256 was = 0;
        uint256 will = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask >> i) & 1 == 1) {
                assertEq(preview[i], before[i], "kept moved");
                continue;
            }
            uint256 p = 1e12 + uint256(keccak256(abi.encode(r, i))) % 1e24;
            was += before[i] * p;
            will += preview[i] * p;
            assertLe(preview[i] * lambdaMin, before[i] * lambdaMax + lambdaMin, "grew past band");
            assertGe(preview[i] * lambdaMax, before[i] * lambdaMin, "shrank past band");
        }
        assertGe(will * lambdaMax, was * lambda, "value bound");
    }

    function _round(uint256 seed, uint256 round) internal {
        uint256 r = uint256(keccak256(abi.encode(seed, round)));
        _batch(r);
        vm.warp(Math.max(block.timestamp, index.lastRebalance() + 7 days));
        bool asGuardian = (r >> 200) % 3 == 0;
        uint256 mask = asGuardian ? (r >> 100) % ((1 << n) - 1) : 0;
        (, uint256 lo, uint256 hi) = index.previewBand(mask);
        if (hi * WAD < lo * (WAD + index.MIN_BAND())) {
            vm.prank(asGuardian ? guardian : stranger);
            vm.expectRevert(abi.encodeWithSelector(IIndexHub.BandTooNarrow.selector, lo, hi));
            index.startRebalance(mask);
            return;
        }
        if (!asGuardian) assertTrue(index.canStartRebalance(), "view disagrees");
        vm.prank(asGuardian ? guardian : stranger);
        index.startRebalance(mask);
        (uint256 eta,,,,) = index.pendingRebalance();
        _holders(r);
        vm.warp(eta + (r >> 40) % 1 days);
        uint256[] memory preview = _checkPreview(r);
        executor.execute(index, "");
        ++fills;
        (, uint256[] memory afterwards) = index.components();
        for (uint256 i = 0; i < n; ++i) {
            assertEq(afterwards[i], preview[i], "preview misled");
        }
        _assertBacked();
    }

    function testFuzz_cycles(uint256 seed, uint8 nSeed, uint256 spread) public {
        _setupIndex(seed, nSeed, spread);
        for (uint256 round = 0; round < 6; ++round) {
            _round(seed, round);
        }
        for (uint256 i = 0; i < n; ++i) {
            if (index.claimOf(alice, tokens[i]) != 0) {
                vm.prank(alice);
                index.claim(tokens[i], alice);
            }
        }
        _assertBacked();
        emit log_named_uint("fills", fills);
        uint256 a = index.balanceOf(alice);
        if (a != 0) {
            vm.prank(alice);
            index.redeem(a, alice);
        }
        uint256 b = index.balanceOf(bob);
        if (b != 0) {
            vm.prank(bob);
            index.redeem(b, bob);
        }
        _assertBacked();
    }
}
