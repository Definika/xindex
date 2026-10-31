// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {PythStructs} from "../src/interfaces/pyth/PythStructs.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";

/// @dev Temporary audit fuzzer. Delete after the review.
contract RogueTest is Test {
    uint256 constant WAD = 1e18;
    MockPyth pyth;
    WeightedIndexFactory factory;
    MockWeightedExecutor executor;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address platform = makeAddr("platform");

    MockERC20[] tokens;
    bytes32[] ids;
    int64[] prices;
    uint8[] decs;

    struct P {
        uint8 n;
        uint256 seed;
        uint16 creatorFee;
        uint16 platformFee;
        uint16 creatorStream;
        uint16 platformStream;
        uint256 shares1;
        uint256 shares2;
        uint256 gap1;
        uint256 gap2;
        uint256 into;
        uint256 mask;
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        pyth = new MockPyth();
        factory = new WeightedIndexFactory(owner, guardian, address(pyth));
        executor = new MockWeightedExecutor();
    }

    function _rand(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    function _build(P memory p) internal returns (WeightedHub index) {
        uint256 n = p.n;
        delete tokens;
        delete ids;
        delete prices;
        delete decs;
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](n);
        uint256 left = 10_000;
        for (uint256 i = 0; i < n; ++i) {
            uint8 d = [6, 8, 18][_rand(p.seed, 100 + i) % 3];
            MockERC20 t = new MockERC20("T", "T", d);
            bytes32 id = keccak256(abi.encode("id", p.seed, i));
            vm.prank(owner);
            factory.proposeListing(address(t), id);
            tokens.push(t);
            ids.push(id);
            decs.push(d);
            // $0.0001 .. $100,000 at expo -8
            int64 price = int64(int256(bound(_rand(p.seed, 200 + i), 1e4, 1e13)));
            prices.push(price);
            uint256 w = i == n - 1 ? left : bound(_rand(p.seed, 300 + i), 1, left - (n - 1 - i));
            left -= w;
            // units: between MIN_RAW_UNITS and the factory max for these decimals, log-distributed
            uint256 maxU = Math.min(1e9 * 10 ** d, type(uint96).max >> 10);
            uint256 u = bound(_rand(p.seed, 400 + i), 1e4, maxU);
            u = 1e4 + (u - 1e4) / (1 + _rand(p.seed, 500 + i) % 1e9);
            specs[i] = IWeightedIndexFactory.ComponentSpec({token: address(t), weight: w, units: u});
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < n; ++i) {
            factory.executeListing(address(tokens[i]));
        }
        vm.prank(owner);
        factory.setFeePolicy(p.platformFee, p.platformStream, 5000, platform, 0);
        IWeightedIndexFactory.IndexParams memory params = IWeightedIndexFactory.IndexParams({
            creatorFeeBps: p.creatorFee,
            creatorStreamingBps: p.creatorStream,
            maxPlatformFeeBps: 25,
            maxPlatformStreamingBps: 100,
            rebalanceInterval: 7 days,
            gated: false,
            listed: true
        });
        vm.prank(creator);
        index = WeightedHub(factory.createIndex("R", "R", specs, params));
    }

    function _issue(WeightedHub index, address to, uint256 shares) internal {
        uint256[] memory amounts = index.previewIssue(shares);
        vm.startPrank(to);
        for (uint256 i = 0; i < tokens.length; ++i) {
            tokens[i].mint(to, amounts[i]);
            tokens[i].approve(address(index), amounts[i]);
        }
        index.issue(shares, to);
        vm.stopPrank();
    }

    function _q(int64 price, uint8 d) internal pure returns (uint256) {
        return uint256(uint64(price)) * 10 ** (36 - 8 - d);
    }

    function _updates(WeightedHub index, uint256 mask) internal view returns (bytes[] memory data) {
        uint64 time = uint64(index.priceTime());
        uint256 n = ids.length;
        uint256 k = 0;
        data = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            if ((mask >> i) & 1 == 1) continue;
            data[k++] = pyth.update(ids[i], prices[i], 0, -8, time, time - 1);
        }
        assembly {
            mstore(data, k)
        }
    }

    function _structs() internal view returns (PythStructs.PriceFeed[] memory s) {
        s = new PythStructs.PriceFeed[](ids.length);
        for (uint256 i = 0; i < s.length; ++i) {
            PythStructs.Price memory q = PythStructs.Price({price: prices[i], conf: 0, expo: -8, publishTime: 0});
            s[i] = PythStructs.PriceFeed({id: ids[i], price: q, emaPrice: q});
        }
    }

    function _checkInvariant(WeightedHub index, string memory tag) internal view {
        (, uint256 scale) = index.pendingStreamingFee();
        // The stored scale: pendingStreamingFee reports the scale an accrual now would leave; use the stricter
        // comparison with recorded units at that scale after an accrual has just happened (call sites ensure it).
        uint256 supply = index.totalSupply();
        (address[] memory t,) = index.components();
        for (uint256 i = 0; i < t.length; ++i) {
            uint256 units = _rawUnits(index, i);
            uint256 required = Math.mulDiv(supply, units * scale, 1e36) + index.totalClaims(t[i]);
            assertGe(MockERC20(t[i]).balanceOf(address(index)), required, string.concat("backing ", tag));
        }
    }

    function _rawUnits(WeightedHub index, uint256 i) internal view returns (uint256) {
        // slot 1 is _components (dynamic array); element i at keccak(1)+i packs token (160) | units (96)
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(uint256(0)))) + i);
        uint256 word = uint256(vm.load(address(index), slot));
        return word >> 160;
    }

    function testFuzz_rogue(P memory p) public {
        p.n = uint8(bound(p.n, 2, 8));
        p.creatorFee = uint16(bound(p.creatorFee, 0, 100));
        p.platformFee = uint16(bound(p.platformFee, 0, 25));
        p.creatorStream = uint16(bound(p.creatorStream, 0, 500));
        p.platformStream = uint16(bound(p.platformStream, 0, 100));
        p.shares1 = bound(p.shares1, 1, 1e24);
        p.shares2 = bound(p.shares2, 1, 1e24);
        p.gap1 = bound(p.gap1, 0, 400 days);
        p.gap2 = bound(p.gap2, 0, 30 days);
        p.into = bound(p.into, 0, 4 hours);
        WeightedHub index = _build(p);
        uint256 n = p.n;

        // Two issues with a gap, then the preview must equal what issue pulls.
        _issue(index, alice, p.shares1);
        vm.warp(block.timestamp + p.gap1);
        index.accrueFees();
        _checkInvariant(index, "after accrual");
        _issue(index, bob, p.shares2);
        _checkInvariant(index, "after issue 2");

        // Move prices and open an auction.
        vm.warp(block.timestamp + 7 days + p.gap2);
        for (uint256 i = 0; i < n; ++i) {
            uint256 f = bound(_rand(p.seed, 600 + i), 50, 200); // x0.5 .. x2
            prices[i] = int64(int256(uint256(uint64(prices[i])) * f / 100));
            if (prices[i] == 0) prices[i] = 1;
        }
        uint256 mask = n <= 2 ? 0 : (p.mask & ((1 << n) - 1));
        uint256 bits = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((mask >> i) & 1 == 1) ++bits;
        }
        if (n - bits < 2) mask = 0;
        bytes[] memory startData = _updates(index, mask);
        vm.prank(mask == 0 ? bob : guardian);
        index.startRebalance(mask, startData);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + p.into);

        uint256 mu;
        uint256[] memory out;
        uint256[] memory in_;
        try index.previewRebalance(_structs()) returns (
            uint256 m, uint256[] memory, uint256[] memory o, uint256[] memory i_
        ) {
            (mu, out, in_) = (m, o, i_);
        } catch (bytes memory reason) {
            if (bytes4(reason) == IWeightedHub.NothingToRebalance.selector) return;
            // The uint96 overflow revert is documented (RX-61); anything else is a finding.
            assertEq(
                bytes4(reason),
                bytes4(keccak256("SafeCastOverflowedUintDowncast(uint8,uint256)")),
                "preview reverted unexpectedly"
            );
            return;
        }

        _fillAndVerify(index, mask, mu, out, in_);
        assertEq(index.rebalanceNonce(), 1);

        // Everyone exits; the previews must match and the index must stay backed throughout.
        _exit(index, alice, p.seed);
        _exit(index, bob, p.seed ^ 1);
        _checkInvariant(index, "after exits");
    }

    function _fillAndVerify(WeightedHub index, uint256 mask, uint256 mu, uint256[] memory out, uint256[] memory in_)
        internal
    {
        uint256 n = tokens.length;
        uint256[] memory before = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            before[i] = tokens[i].balanceOf(address(index));
        }
        // An honest fill must never revert once the preview settles.
        bytes[] memory fillData = _updates(index, mask);
        executor.execute(index, "", fillData);
        _checkInvariant(index, "after fill");

        uint256 valueOut;
        uint256 valueIn;
        for (uint256 i = 0; i < n; ++i) {
            uint256 after_ = tokens[i].balanceOf(address(index));
            if ((mask >> i) & 1 == 1) {
                assertEq(after_, before[i], "kept leg moved");
                continue;
            }
            assertTrue(out[i] == 0 || in_[i] == 0, "a leg both in and out");
            if (out[i] != 0) assertEq(before[i] - after_, out[i], "out differs from preview");
            if (in_[i] != 0) assertEq(after_ - before[i], in_[i], "in differs from preview");
            uint256 q = _q(prices[i], decs[i]);
            valueOut += out[i] * q;
            valueIn += in_[i] * q;
        }
        assertGe(valueIn * WAD, valueOut * mu, "executor delivered less than mu times what it took");
    }

    function _exit(WeightedHub index, address who, uint256 seed) internal {
        uint256 bal = index.balanceOf(who);
        if (bal == 0) return;
        uint256 n = tokens.length;
        uint256 skip = _rand(seed, 7) & ((1 << n) - 1);
        uint256[] memory expect = index.previewRedeem(bal);
        uint256[] memory held = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            held[i] = tokens[i].balanceOf(who);
        }
        vm.prank(who);
        if (skip == 0) index.redeem(bal, who);
        else index.redeemSkipping(bal, who, skip);
        for (uint256 i = 0; i < n; ++i) {
            if ((skip >> i) & 1 == 1) {
                assertEq(index.claimOf(who, address(tokens[i])), expect[i], "claim differs from preview");
                if (expect[i] != 0) {
                    vm.prank(who);
                    index.claim(address(tokens[i]), who);
                }
            }
            assertEq(tokens[i].balanceOf(who) - held[i], expect[i], "redeem differs from preview");
        }
    }
}
