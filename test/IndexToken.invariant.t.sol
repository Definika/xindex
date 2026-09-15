// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract IndexHandler is Test {
    IndexToken public index;
    MockERC20[] public comps;
    address[] public actors;

    uint256 public ghostIssued;
    uint256 public ghostRedeemed;

    constructor(IndexToken index_, MockERC20[] memory comps_, address[] memory actors_) {
        index = index_;
        comps = comps_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function issue(uint256 seed, uint256 toSeed, uint256 shares) external {
        address from = _actor(seed);
        shares = bound(shares, 1, 1_000_000e18);
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 i = 0; i < comps.length; ++i) {
            comps[i].mint(from, need[i]);
            vm.prank(from);
            comps[i].approve(address(index), need[i]);
        }
        vm.prank(from);
        index.issue(shares, _actor(toSeed));
        ghostIssued += shares;
    }

    function redeem(uint256 seed, uint256 toSeed, uint256 shares) external {
        address from = _actor(seed);
        uint256 bal = index.balanceOf(from);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(from);
        index.redeem(shares, _actor(toSeed));
        ghostRedeemed += shares;
    }

    function redeemSkipping(uint256 seed, uint256 toSeed, uint256 shares, uint256 mask) external {
        address from = _actor(seed);
        uint256 bal = index.balanceOf(from);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        mask = bound(mask, 1, (1 << comps.length) - 1);
        vm.prank(from);
        index.redeemSkipping(shares, _actor(toSeed), mask);
        ghostRedeemed += shares;
    }

    function claim(uint256 seed, uint256 compSeed, uint256 toSeed) external {
        address from = _actor(seed);
        address token = address(comps[compSeed % comps.length]);
        if (index.claimOf(from, token) == 0) return;
        vm.prank(from);
        index.claim(token, _actor(toSeed));
    }

    function transfer(uint256 seed, uint256 toSeed, uint256 amount) external {
        address from = _actor(seed);
        uint256 bal = index.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        vm.prank(from);
        index.transfer(_actor(toSeed), amount);
    }

    function donate(uint256 compSeed, uint256 amount) external {
        amount = bound(amount, 0, 1e30);
        comps[compSeed % comps.length].mint(address(index), amount);
    }
}

contract IndexTokenInvariantTest is Test {
    IndexFactory factory;
    IndexToken index;
    IndexHandler handler;
    MockERC20[] comps;
    uint256[] units;
    address[] actors;

    function setUp() public {
        address owner = makeAddr("owner");
        factory = new IndexFactory(owner, address(0));

        comps.push(new MockERC20("WBTC", "WBTC", 8));
        comps.push(new MockERC20("WETH", "WETH", 18));
        comps.push(new MockERC20("USDC", "USDC", 6));
        comps.push(new MockERC20("ODD", "ODD", 13));
        units.push(100_000);
        units.push(1e16);
        units.push(10e6);
        units.push(7); // deliberately tiny so rounding matters

        address[] memory t = new address[](comps.length);
        for (uint256 i = 0; i < comps.length; ++i) {
            t[i] = address(comps[i]);
            vm.prank(owner);
            factory.proposeListing(t[i]);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < comps.length; ++i) {
            factory.executeListing(t[i]);
        }
        index = IndexToken(factory.createIndex("Inv", "INV", t, units));

        for (uint256 i = 0; i < 5; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
        handler = new IndexHandler(index, comps, actors);
        targetContract(address(handler));
    }

    function invariant_everyComponentBackedIncludingClaims() public view {
        uint256 supply = index.totalSupply();
        for (uint256 i = 0; i < comps.length; ++i) {
            uint256 required = Math.mulDiv(supply, units[i], 1e18) + index.totalClaims(address(comps[i]));
            assertGe(comps[i].balanceOf(address(index)), required, "component under-backed");
        }
    }

    function invariant_supplyMatchesGhostAndHolders() public view {
        assertEq(index.totalSupply(), handler.ghostIssued() - handler.ghostRedeemed());
        uint256 sum = 0;
        for (uint256 i = 0; i < actors.length; ++i) {
            sum += index.balanceOf(actors[i]);
        }
        assertEq(sum, index.totalSupply());
    }

    function invariant_claimsAddUp() public view {
        for (uint256 c = 0; c < comps.length; ++c) {
            uint256 sum = 0;
            for (uint256 i = 0; i < actors.length; ++i) {
                sum += index.claimOf(actors[i], address(comps[c]));
            }
            assertEq(sum, index.totalClaims(address(comps[c])));
        }
    }
}
