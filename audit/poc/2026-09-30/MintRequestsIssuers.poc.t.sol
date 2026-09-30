// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexHub} from "../../src/IndexHub.sol";
import {MintRequests} from "../../src/MintRequests.sol";
import {XindexTest} from "../XindexTest.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

/// @notice Mainnet TetherToken's (0xdAC17F958D2ee523a2206206994597C13D831ec7, solc 0.4.17) freeze semantics, copied
///         line for line where it matters:
///           transfer:      whenNotPaused, require(!isBlackListed[msg.sender])        -- the recipient is NOT checked
///           transferFrom:  whenNotPaused, require(!isBlackListed[_from])             -- neither msg.sender nor _to
///           destroyBlackFunds(user): onlyOwner, require(isBlackListed[user]), balances[user] = 0
///         No return values, 6 decimals. The fee switch is left off; MockUSDT covers it.
contract TetherLike {
    uint8 public constant decimals = 6;
    address public immutable owner = msg.sender;
    bool public paused;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isBlackListed;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function addBlackList(address user) external {
        require(msg.sender == owner);
        isBlackListed[user] = true;
    }

    function removeBlackList(address user) external {
        require(msg.sender == owner);
        isBlackListed[user] = false;
    }

    function destroyBlackFunds(address user) external {
        require(msg.sender == owner);
        require(isBlackListed[user]);
        balanceOf[user] = 0;
    }

    function pause() external {
        require(msg.sender == owner);
        paused = true;
    }

    function approve(address spender, uint256 value) external {
        require(!(value != 0 && allowance[msg.sender][spender] != 0));
        allowance[msg.sender][spender] = value;
    }

    function transfer(address to, uint256 value) external {
        require(!paused);
        require(!isBlackListed[msg.sender]);
        _move(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external {
        require(!paused);
        require(!isBlackListed[from]);
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value);
        if (allowed < type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _move(from, to, value);
    }

    function _move(address from, address to, uint256 value) private {
        require(balanceOf[from] >= value);
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}

/// @notice Circle's FiatTokenV2_2 freeze semantics: transfer checks msg.sender and to; transferFrom checks msg.sender,
///         from and to. Returns true.
contract CircleLike {
    uint8 public constant decimals = 6;
    address public immutable blacklister = msg.sender;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isBlacklisted;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function blacklist(address user) external {
        require(msg.sender == blacklister);
        isBlacklisted[user] = true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        require(!isBlacklisted[msg.sender] && !isBlacklisted[spender]);
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(!isBlacklisted[msg.sender] && !isBlacklisted[to], "Blacklistable: account is blacklisted");
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(
            !isBlacklisted[msg.sender] && !isBlacklisted[from] && !isBlacklisted[to],
            "Blacklistable: account is blacklisted"
        );
        require(allowance[from][msg.sender] >= value);
        allowance[from][msg.sender] -= value;
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) private {
        require(balanceOf[from] >= value);
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}

/// @notice PoCs for how MintRequests behaves when Tether or Circle freezes a party, against what README.md ("An issuer
///         can freeze a request") and the spec (section 5) promise.
contract MintRequestsIssuersPoC is XindexTest {
    MintRequests requests;
    IndexHub index;
    TetherLike usdt;
    CircleLike usdc;
    address[] components;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address minter = makeAddr("minter");
    address stranger = makeAddr("stranger");

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, makeAddr("guardian"));
        usdt = new TetherLike();
        usdc = new CircleLike();
        requests = new MintRequests(address(factory), address(usdc), address(usdt));
        for (uint256 i = 0; i < 2; ++i) {
            components.push(address(new MockERC20("C", "C", 18)));
            _listWith(components[i], 100e18);
        }
        index = IndexHub(factory.createIndex("Requested", "REQ", components, 1e36));
        _issueTo(minter, 10e18);
    }

    function _issueTo(address who, uint256 shares) internal {
        uint256[] memory need = index.previewIssue(shares);
        vm.startPrank(who);
        for (uint256 i = 0; i < components.length; ++i) {
            MockERC20(components[i]).mint(who, need[i]);
            MockERC20(components[i]).approve(address(index), need[i]);
        }
        index.issue(shares, who);
        vm.stopPrank();
    }

    function _redeemRequest(address who, uint256 shares, address stable, uint256 minOut) internal returns (uint256 id) {
        vm.prank(minter);
        index.transfer(who, shares);
        vm.startPrank(who);
        index.approve(address(requests), shares);
        id = requests.requestRedeem(address(index), shares, stable, minOut, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function _usdtMintRequest(address who, uint256 amount) internal returns (uint256 id) {
        usdt.mint(who, amount);
        vm.startPrank(who);
        usdt.approve(address(requests), amount);
        id = requests.requestMint(address(index), address(usdt), amount, 1e18, block.timestamp + 1 days);
        vm.stopPrank();
    }

    /// README: "If Circle or Tether blacklists a requester, a fill that pays them ... revert[s] until the issuer lifts
    /// it". Mainnet Tether never checks the recipient, so the fill goes through: the filler takes the requester's
    /// escrowed shares (which no issuer can freeze) and pays USDT into a frozen balance Tether can then destroy. The
    /// requester's documented recourse, cancelling for their shares, is gone the moment any filler moves first.
    function test_poc_tetherBlacklistedRequesterIsStillFilled() public {
        uint256 id = _redeemRequest(alice, 2e18, address(usdt), 500e6);
        usdt.addBlackList(alice);

        usdt.mint(minter, 500e6);
        vm.startPrank(minter);
        usdt.approve(address(requests), 500e6);
        requests.fill(id, 500e6); // documented to revert; it does not
        vm.stopPrank();

        assertEq(index.balanceOf(minter), 10e18, "the filler took alice's escrowed shares");
        assertEq(index.balanceOf(alice), 0, "alice has no shares left");
        assertEq(usdt.balanceOf(alice), 500e6, "alice holds USDT she cannot move");
        vm.prank(alice);
        vm.expectRevert();
        usdt.transfer(bob, 1);

        usdt.destroyBlackFunds(alice);
        assertEq(usdt.balanceOf(alice), 0, "and Tether can burn it: alice ends with nothing");
    }

    /// README: "... and a refund of their stablecoin escrow both revert until the issuer lifts it". With Tether, anyone
    /// can push a blacklisted requester's USDT escrow into their frozen balance once the deadline passes.
    function test_poc_tetherBlacklistedRequesterRefundGoesThrough() public {
        uint256 id = _usdtMintRequest(alice, 1_000e6);
        usdt.addBlackList(alice);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(stranger);
        requests.refund(id); // documented to revert; it does not
        assertEq(usdt.balanceOf(alice), 1_000e6);
        usdt.destroyBlackFunds(alice);
        assertEq(usdt.balanceOf(alice), 0);
    }

    /// README: "if one blacklists MintRequests itself, every open escrow in that stablecoin waits with it". With Tether,
    /// new USDT requests are still accepted after the blacklist (transferFrom checks only `_from`), so fresh deposits
    /// walk into a contract that cannot pay them out, and destroyBlackFunds zeroes every escrow for good: after the
    /// blacklist is lifted the escrows are recorded but the balance is gone, so every cancel and refund reverts.
    function test_poc_tetherBlacklistedContractAcceptsNewEscrowsAndCanLoseThemAll() public {
        uint256 bobId = _usdtMintRequest(bob, 1_000e6);
        usdt.addBlackList(address(requests));

        uint256 aliceId = _usdtMintRequest(alice, 500e6); // accepted after the blacklist
        assertEq(requests.getRequest(aliceId).escrow, 500e6);
        vm.prank(alice);
        vm.expectRevert();
        requests.cancel(aliceId); // but it can never leave

        usdt.destroyBlackFunds(address(requests));
        usdt.removeBlackList(address(requests));
        vm.prank(alice);
        vm.expectRevert();
        requests.cancel(aliceId);
        vm.prank(bob);
        vm.expectRevert();
        requests.cancel(bobId);
        assertTrue(requests.getRequest(aliceId).open && requests.getRequest(bobId).open, "open, recorded, unbacked");
    }

    /// A requester Circle blacklists after escrowing USDC cannot cancel (Circle checks `to`), but any filler, including
    /// an accomplice, can still take that USDC out through a fill at the limit the requester set beforehand. Circle's
    /// only lever over funds parked in the shared escrow is to blacklist MintRequests itself, which freezes every
    /// other requester's USDC with it.
    function test_poc_circleBlacklistedRequesterEscrowStillLeavesThroughAFill() public {
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(requests), 1_000e6);
        uint256 id = requests.requestMint(address(index), address(usdc), 1_000e6, 1, block.timestamp + 30 days);
        vm.stopPrank();
        usdc.blacklist(alice);

        vm.prank(alice);
        vm.expectRevert("Blacklistable: account is blacklisted");
        requests.cancel(id);

        address accomplice = makeAddr("accomplice");
        vm.prank(minter);
        index.transfer(accomplice, 1);
        vm.startPrank(accomplice);
        index.approve(address(requests), 1);
        requests.fill(id, 1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(accomplice), 1_000e6, "the blacklisted requester's USDC walked out to a clean address");
    }

    /// Circle checks msg.sender in transferFrom, so a USDC blacklist on MintRequests also stops fills of USDC
    /// *redemption* requests, whose escrow is shares and whose parties are both clean. The escrow itself is safe:
    /// cancel returns the shares.
    function test_poc_circleBlacklistOnTheContractStopsUsdcRedeemFills() public {
        uint256 id = _redeemRequest(alice, 1e18, address(usdc), 300e6);
        usdc.mint(minter, 300e6);
        vm.prank(minter);
        usdc.approve(address(requests), 300e6); // approved before the blacklist (FiatToken's approve checks spender)
        usdc.blacklist(address(requests));
        vm.startPrank(minter);
        vm.expectRevert("Blacklistable: account is blacklisted");
        requests.fill(id, 300e6);
        vm.stopPrank();
        vm.prank(alice);
        requests.cancel(id);
        assertEq(index.balanceOf(alice), 1e18);
    }
}
