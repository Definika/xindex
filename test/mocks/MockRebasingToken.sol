// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A token that keeps shares and reports balances as shares times a rate, as rebasing and share tokens do (stETH,
///         aTokens). The rate starts at `startRate` and grows by `growth` a second. A balance written into its storage
///         reads back scaled by the rate, so the admission check cannot write one and takes it from a holder; a transfer
///         moves the shares its amount rounds down to. Used to prove `CheckToken` refuses share rounding and rebasing,
///         and accepts a share token that moves exact amounts.
contract MockRebasingToken {
    uint256 private constant ONE = 1e18;

    string public constant symbol = "REB";
    uint8 public constant decimals = 18;

    uint256 public immutable START;
    uint256 public immutable START_RATE;
    uint256 public immutable GROWTH;

    mapping(address account => uint256) public sharesOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;
    uint256 public totalShares;

    constructor(uint256 startRate, uint256 growth) {
        START = block.timestamp;
        START_RATE = startRate;
        GROWTH = growth;
    }

    /// @notice Balance units per share, to 18 decimals.
    function rate() public view returns (uint256) {
        return START_RATE + (block.timestamp - START) * GROWTH;
    }

    function balanceOf(address account) public view returns (uint256) {
        return sharesOf[account] * rate() / ONE;
    }

    function totalSupply() external view returns (uint256) {
        return totalShares * rate() / ONE;
    }

    /// @notice Gives `to` this many shares.
    function mintShares(address to, uint256 shares) external {
        sharesOf[to] += shares;
        totalShares += shares;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 shares = amount * ONE / rate();
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
    }
}
